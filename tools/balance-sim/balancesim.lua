-- Headless battle simulator for the Phase 4 balance pass (docs/qa/phase4-balance-notes.md).
-- Test copies only: tools/balance-sim/run.sh copies the mod, puts this file at scripts/balancesim.lua and appends
-- require("scripts.balancesim") to the copy's control.lua. Guarded by storage.debug.balancesim, which on_init sets;
-- it also turns the match autotest off (storage.debug.autotest = false), so no match starts.
--
-- Every scenario runs in its own arena on a lab-tile surface, all arenas of a round at once, REPS rounds:
--   army      equal-cost armies of unit a (force sim-a) and unit b (sim-b), fronts GAP tiles apart, both sides
--             attack-move through orders.attack_move (the player's order). Expectation "a" (a counter: a must win
--             with 40-70 % of its army left) or "mirror". Cost = iron-equivalent of the kit recipe (WEIGHT).
--   turret    3 walkers attack-move onto an rts-turret with 20 magazines: the turret must survive.
--   laser     6 drones attack-move onto a powered rts-laser-turret: the laser must survive.
--   siege     3 artillery attack-move onto an rts-turret 45 tiles away: the turret dies, the artillery takes no damage.
--   block     2 walkers 2.5 tiles apart move 40 tiles (orders.move): both arrive within 10 s.
-- Log lines: "[rts] bsim result ..." per scenario and rep, "[rts] bsim summary ..." per scenario, "[rts] bsim done".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local orders = require("scripts.orders")
local balance = require("balance")

local sim = {}
sim.SPEED = 8
sim.REPS = 8
sim.BUDGET = 360
sim.GAP = 30
sim.TIMEOUT = 120 * 60
sim.ARENA = 320
sim.COLS = 6
sim.TRACE = false
sim.ONLY = nil -- Lua pattern: run only the scenarios whose id matches (run.sh sets it from SIM_ONLY)
local FA, FB = "sim-a", "sim-b"
local WEIGHT = {["iron-plate"] = 1, ["copper-plate"] = 1, ["steel-plate"] = 3, ["electronic-circuit"] = 4,
                ["rts-explosives"] = 2}

local function plog(fmt, ...) util.log("bsim " .. fmt, ...) end
local function bs() return storage.debug and storage.debug.balancesim end

function sim.cost(name)
  local c = 0
  for item, n in pairs(balance.units[name].cost) do c = c + n * assert(WEIGHT[item], "no weight for " .. item) end
  return c
end

-- tier-1 unit of each kind (barracks kits only)
local KIND_UNIT = {}
for name, u in pairs(balance.units) do
  if u.tier == 1 and u.kit and not u.made_by then KIND_UNIT[u.kind] = name end
end

-- Army sizes with equal cost: na * ca ~ nb * cb near BUDGET.
local function sizes(a, b)
  local ca, cb = sim.cost(a), sim.cost(b)
  local best
  for na = 1, 200 do
    local va = na * ca
    if va >= sim.BUDGET * 0.75 and va <= sim.BUDGET * 1.3 then
      local nb = math.max(1, math.floor(va / cb + 0.5))
      local mis = math.abs(va - nb * cb) / va
      local score = mis + math.abs(va - sim.BUDGET) / sim.BUDGET * 0.2
      if not best or score < best.score then best = {na = na, nb = nb, score = score, va = va, vb = nb * cb} end
    end
  end
  return best
end

local function scenarios()
  local list = {}
  local names = {}
  for kind, name in pairs(KIND_UNIT) do names[#names + 1] = name end
  table.sort(names)
  for _, a in ipairs(names) do
    for _, kind in ipairs(balance.units[a].counters or {}) do
      local b = KIND_UNIT[kind]
      if b then list[#list + 1] = {id = a .. ">" .. b, type = "army", a = a, b = b, expect = "a"} end
    end
  end
  for _, a in ipairs(names) do list[#list + 1] = {id = a .. "=" .. a, type = "army", a = a, b = a, expect = "mirror"} end
  list[#list + 1] = {id = "turret-vs-3-walkers", type = "turret"}
  list[#list + 1] = {id = "laser-vs-6-drones", type = "laser"}
  list[#list + 1] = {id = "3-artillery-vs-turret", type = "siege"}
  list[#list + 1] = {id = "2-walkers-spread-2.5", type = "block"}
  if sim.ONLY then
    local only = {}
    for _, sc in ipairs(list) do if sc.id:find(sim.ONLY) then only[#only + 1] = sc end end
    list = only
  end
  return list
end

local function S() return game.surfaces["bsim"] end

local function spacing(name)
  local box = prototypes.entity[name].collision_box
  local w = math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y)
  return math.max(2.5, w + 0.75)
end

-- n units in a grid, front row at front_x, rows going back in direction dir (-1 left, +1 right). Positions get a
-- small per-rep jitter (the game is deterministic: identical starts give identical fights).
local function place(name, n, force, front_x, cy, dir, rng)
  local sp = spacing(name)
  local cols = math.ceil(math.sqrt(n))
  local list = {}
  for i = 0, n - 1 do
    local row, col = math.floor(i / cols), i % cols
    local in_row = math.min(cols, n - row * cols)
    local jx, jy = (rng() - 0.5) * 0.8, (rng() - 0.5) * 0.8
    local e = units.spawn(name, {x = front_x + dir * row * sp + jx, y = cy + (col - (in_row - 1) / 2) * sp + jy},
      force, nil, S())
    if e then list[#list + 1] = e end
  end
  return list
end

local function build(name, x, y, force)
  return S().create_entity({name = name, position = {x, y}, force = force})
end

local function side_state(list)
  local alive, hp, maxhp = 0, 0, 0
  for _, e in pairs(list) do
    if e.valid then
      alive = alive + 1
      hp = hp + e.health
    end
  end
  return alive, hp
end

local function hp_total(list)
  local t = 0
  for _, e in pairs(list) do if e.valid then t = t + e.max_health end end
  return t
end

local function setup_scenario(sc, i, rep)
  local col, row = (i - 1) % sim.COLS, math.floor((i - 1) / sim.COLS)
  local cx, cy = col * sim.ARENA, row * sim.ARENA
  sc.cx, sc.cy = cx, cy
  local h = sim.GAP / 2
  local gen = game.create_random_generator(rep * 7919 + i)
  local rng = function() return gen() end
  -- even reps swap the sides (a on the right), so a side or order-of-issue bias shows as a split result
  local side = rep % 2 == 0 and -1 or 1
  sc.side = side
  if sc.type == "army" then
    local sz = sizes(sc.a, sc.b)
    sc.na, sc.nb, sc.va, sc.vb = sz.na, sz.nb, sz.va, sz.vb
    sc.A = place(sc.a, sz.na, FA, cx - side * h, cy, -side, rng)
    sc.B = place(sc.b, sz.nb, FB, cx + side * h, cy, side, rng)
  elseif sc.type == "turret" then
    sc.A = place("rts-walker", 3, FA, cx - h, cy, -1, rng)
    sc.T = build("rts-turret", cx + h, cy, FB)
    sc.T.insert({name = "firearm-magazine", count = 20})
  elseif sc.type == "laser" then
    sc.A = place("rts-drone", 6, FA, cx - h, cy, -1, rng)
    sc.T = build("rts-laser-turret", cx + h, cy, FB)
    build("rts-core-power", cx + h + 4, cy, FB)
    build("rts-core-pole", cx + h + 4, cy, FB)
  elseif sc.type == "siege" then
    sc.A = place("rts-artillery", 3, FA, cx - 20, cy, -1, rng)
    sc.T = build("rts-turret", cx + 25, cy, FB)
    sc.T.insert({name = "firearm-magazine", count = 20})
    sc.min_d = math.huge
  elseif sc.type == "block" then
    sc.A = {}
    sc.A[1] = units.spawn("rts-walker", {x = cx - 20, y = cy}, FA, nil, S())
    sc.A[2] = units.spawn("rts-walker", {x = cx - 20, y = cy + 2.5}, FA, nil, S())
  end
  sc.A = sc.A or {}
  sc.B = sc.B or {}
  local owner = bs().owner
  for _, list in pairs({sc.A, sc.B, {sc.T}}) do
    for _, e in pairs(list) do if e and e.valid and e.unit_number then owner[e.unit_number] = sc end end
  end
  sc.na0, sc.nb0 = #sc.A, #sc.B
  sc.hpa0, sc.hpb0 = hp_total(sc.A), hp_total(sc.B)
  sc.t_hp0 = sc.T and sc.T.valid and sc.T.health or nil
end

local function start_scenario(sc)
  game.forces[FA].set_cease_fire(FB, false)
  game.forces[FB].set_cease_fire(FA, false)
  local h = sim.GAP / 2
  local target = sc.T and sc.T.valid and sc.T.position
  if sc.type == "army" then
    -- the side issued first alternates with the rep as well
    local first, second = {sc.A, sc.cx + sc.side * h}, {sc.B, sc.cx - sc.side * h}
    if sc.side < 0 then first, second = second, first end
    orders.attack_move(first[1], {x = first[2], y = sc.cy})
    orders.attack_move(second[1], {x = second[2], y = sc.cy})
  elseif sc.type == "block" then
    sc.dest = {x = sc.cx + 20, y = sc.cy + 1.25}
    orders.move(sc.A, sc.dest)
    sc.arrived = {}
  else
    orders.attack_move(sc.A, target)
  end
  sc.t0 = game.tick
end

local function pct(x, y) return y > 0 and 100 * x / y or 0 end

-- Returns true when the scenario is over and fills sc.result.
local function check_scenario(sc)
  local t = game.tick - sc.t0
  if sim.TRACE and sc.type == "army" and bs().round == 1 and t % 30 == 0 then
    local function side(list)
      local alive, hp = 0, 0
      for _, e in pairs(list) do if e.valid then alive = alive + 1; hp = hp + e.health end end
      return alive, hp
    end
    local aa, ah = side(sc.A)
    local ba, bh = side(sc.B)
    local dmin = math.huge
    for _, a in pairs(sc.A) do
      if a.valid then
        for _, b in pairs(sc.B) do if b.valid then dmin = math.min(dmin, util.distance(a, b)) end end
      end
    end
    plog("trace %s t=%.1f A %d (%.0f hp, %d shots) B %d (%.0f hp, %d shots) closest %.1f", sc.id, t / 60, aa, ah,
      sc.shots_a or 0, ba, bh, sc.shots_b or 0, dmin)
  end
  local a_alive, a_hp = side_state(sc.A)
  local b_alive, b_hp = side_state(sc.B)
  sc.a_alive, sc.a_hp, sc.b_alive, sc.b_hp = a_alive, a_hp, b_alive, b_hp
  local timeout = t >= sim.TIMEOUT
  if sc.type == "army" then
    if a_alive == 0 or b_alive == 0 or timeout then
      sc.winner = (a_alive > 0 and b_alive == 0) and "A" or (b_alive > 0 and a_alive == 0) and "B" or "none"
      if timeout and a_alive > 0 and b_alive > 0 then sc.winner = "timeout" end
      sc.time = t / 60
      return true
    end
  elseif sc.type == "turret" or sc.type == "laser" or sc.type == "siege" then
    if sc.type == "siege" and sc.T.valid then
      for _, e in pairs(sc.A) do
        if e.valid then sc.min_d = math.min(sc.min_d, util.distance(e, sc.T)) end
      end
      if sim.TRACE and bs().round == 1 then
        local parts = {}
        for i, e in ipairs(sc.A) do
          if e.valid then
            local rec = units.get(e.unit_number)
            local cmd = e.commandable and e.commandable.command
            parts[#parts + 1] = string.format("#%d d=%.1f %s/%s", i, util.distance(e, sc.T), rec and rec.order or "-",
              cmd and util.define_name(defines.command, cmd.type) or "-")
          end
        end
        plog("trace t=%.1f turret hp %.0f | %s", t / 60, sc.T.health, table.concat(parts, " | "))
      end
    end
    if a_alive == 0 or not sc.T.valid or timeout then
      sc.winner = not sc.T.valid and "A" or (a_alive == 0 and "T" or "timeout")
      sc.time = t / 60
      return true
    end
  elseif sc.type == "block" then
    for i, e in pairs(sc.A) do
      local rec = e.valid and units.get(e.unit_number)
      if rec and not sc.arrived[i] and rec.order == units.IDLE and util.distance(e, sc.dest) < 4 then
        sc.arrived[i] = t / 60
      end
    end
    if (sc.arrived[1] and sc.arrived[2]) or t >= 20 * 60 then
      sc.time = t / 60
      sc.winner = (sc.arrived[1] and sc.arrived[2]) and "arrived" or "stuck"
      return true
    end
  end
  return false
end

local function pass_of(sc)
  if sc.type == "army" then
    if sc.expect == "a" then
      -- army left = health left (units never heal, so damage is permanent loss); the unit count is logged too
      local left = pct(sc.a_hp, sc.hpa0)
      return sc.winner == "A" and left >= 40 and left <= 70, left
    end
    return sc.winner ~= "timeout", math.max(pct(sc.a_alive, sc.na0), pct(sc.b_alive, sc.nb0))
  elseif sc.type == "turret" or sc.type == "laser" then
    return sc.winner == "T", sc.T.valid and pct(sc.T.health, sc.T.max_health) or 0
  elseif sc.type == "siege" then
    return sc.winner == "A" and sc.a_hp >= sc.hpa0 - 0.01, sc.min_d
  elseif sc.type == "block" then
    local ok = sc.arrived[1] and sc.arrived[2] and math.max(sc.arrived[1], sc.arrived[2]) <= 10
    return ok, math.max(sc.arrived[1] or 99, sc.arrived[2] or 99)
  end
end

local function log_result(sc, rep)
  local ok, metric = pass_of(sc)
  sc.ok, sc.metric = ok, metric
  if sc.type == "army" then
    plog("result %s rep=%d %s expect=%s winner=%s a=%s %d/%d (hp %.0f%%) b=%s %d/%d (hp %.0f%%) cost %d vs %d first hit %.1fs t=%.1fs %s",
      script.active_mods["space-age"] and "sa" or "base", rep, sc.id, sc.expect, sc.winner, sc.a, sc.a_alive, sc.na0,
      pct(sc.a_hp, sc.hpa0), sc.b, sc.b_alive, sc.nb0, pct(sc.b_hp, sc.hpb0), sc.va, sc.vb,
      sc.first_hit and (sc.first_hit - sc.t0) / 60 or -1, sc.time,
      ok and "PASS" or "FAIL")
  elseif sc.type == "block" then
    plog("result %s rep=%d %s arrived %s / %s s t=%.1fs %s", script.active_mods["space-age"] and "sa" or "base", rep,
      sc.id, tostring(sc.arrived[1]), tostring(sc.arrived[2]), sc.time, ok and "PASS" or "FAIL")
  else
    plog("result %s rep=%d %s winner=%s attackers %d/%d (hp %.0f%%) building %s t=%.1fs%s %s",
      script.active_mods["space-age"] and "sa" or "base", rep, sc.id, sc.winner, sc.a_alive, sc.na0,
      pct(sc.a_hp, sc.hpa0), sc.T.valid and string.format("%.0f/%.0f hp", sc.T.health, sc.T.max_health) or "destroyed",
      sc.time, sc.type == "siege" and string.format(" closest artillery %.1f tiles", sc.min_d) or "",
      ok and "PASS" or "FAIL")
  end
end

local function cleanup()
  units.despawn_all()
  for _, e in pairs(S().find_entities_filtered({force = {FA, FB}})) do
    if e.valid then e.destroy() end
  end
end

events.on_init(function()
  storage.debug = storage.debug or {}
  storage.debug.autotest = false -- no match: the simulator owns the game
  storage.debug.balancesim = {round = 0, phase = "init", results = {}, owner = {}}
  for _, f in ipairs({FA, FB}) do if not game.forces[f] then game.create_force(f) end end
  local s = game.create_surface("bsim")
  s.generate_with_lab_tiles = true
  s.always_day = true
  local n = #scenarios()
  for i = 1, n do
    local col, row = (i - 1) % sim.COLS, math.floor((i - 1) / sim.COLS)
    s.request_to_generate_chunks({col * sim.ARENA, row * sim.ARENA}, 5)
  end
  s.force_generate_chunk_requests()
  game.speed = sim.SPEED
  local costs = {}
  for kind, name in pairs(KIND_UNIT) do costs[#costs + 1] = string.format("%s=%d", name, sim.cost(name)) end
  table.sort(costs)
  plog("init: %d scenarios x %d reps, budget %d, gap %d, speed %d, costs %s", n, sim.REPS, sim.BUDGET, sim.GAP,
    sim.SPEED, table.concat(costs, " "))
end)

events.on(defines.events.on_script_trigger_effect, function(e)
  local d = bs()
  local src = e.source_entity or e.cause_entity
  local un = src and src.valid and src.unit_number
  local sc = d and un and d.owner[un]
  if not (sc and e.effect_id:find("^shot")) then return end
  if src.force.name == FA then sc.shots_a = (sc.shots_a or 0) + 1 else sc.shots_b = (sc.shots_b or 0) + 1 end
end)

events.on(defines.events.on_entity_damaged, function(e)
  local d = bs()
  local un = e.entity.unit_number
  local sc = d and un and d.owner[un]
  if sc and sc.t0 and not sc.first_hit and e.final_damage_amount > 0 then sc.first_hit = game.tick end
end)

events.on_nth_tick(30, function(e)
  local d = bs()
  if not d then return end
  if d.phase == "init" or d.phase == "next" then
    d.round = d.round + 1
    if d.round > sim.REPS then
      d.phase = "done"
      -- summary
      for id, rs in pairs(d.results) do
        local wins, pass, metric, time = {}, 0, 0, 0
        for _, r in ipairs(rs) do
          wins[r.winner] = (wins[r.winner] or 0) + 1
          if r.ok then pass = pass + 1 end
          metric = metric + (r.metric or 0)
          time = time + (r.time or 0)
        end
        local w = {}
        for k, v in pairs(wins) do w[#w + 1] = k .. "=" .. v end
        table.sort(w)
        plog("summary %s %s: winners %s, metric avg %.1f, time avg %.1fs, pass %d/%d",
          script.active_mods["space-age"] and "sa" or "base", id, table.concat(w, " "), metric / #rs, time / #rs,
          pass, #rs)
      end
      plog("done")
      return
    end
    d.list = scenarios()
    -- no shots before the start: units spawn in range of each other (artillery: 40 tiles)
    game.forces[FA].set_cease_fire(FB, true)
    game.forces[FB].set_cease_fire(FA, true)
    for i, sc in ipairs(d.list) do setup_scenario(sc, i, d.round) end
    d.phase = "settle"
    d.settle_tick = e.tick + 60
    return
  end
  if d.phase == "settle" and e.tick >= d.settle_tick then
    for _, sc in ipairs(d.list) do start_scenario(sc) end
    d.phase = "run"
    return
  end
  if d.phase == "run" then
    local all = true
    for _, sc in ipairs(d.list) do
      if not sc.done then
        if check_scenario(sc) then
          sc.done = true
          log_result(sc, d.round)
          d.results[sc.id] = d.results[sc.id] or {}
          table.insert(d.results[sc.id], {winner = sc.winner, ok = sc.ok, metric = sc.metric, time = sc.time})
        else
          all = false
        end
      end
    end
    if all then
      d.owner = {}
      cleanup()
      d.phase = "next"
    end
  end
end)

return sim
