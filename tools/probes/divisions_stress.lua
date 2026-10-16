-- Divisions stress scenario (test copy only: tools/divisions-bench.sh copies it into scripts/ and requires it last).
-- docs/PHASE5-M1.md section 4 "Divisions": 4 forces x 12 divisions x 16 units moving on a large arena, mean <= 6 ms per
-- tick, no order tick > 20 ms; an order to 1,000 units issues <= 100 path requests per tick.
--
-- The scenario is built in on_init (so --create saves it) on its own lab-tile surface with four 8-tile water bands
-- (16-tile fords every 128 tiles), and the normal autotest is switched off. Everything runs through the real
-- scripts/divisions.lua, scripts/orders.lua and units.lua. Config: scripts/div_stress_cfg.lua (written by the runner):
--   mode     "march": cfg.forces x cfg.divs divisions of cfg.comp march to random points cfg.leg tiles away; every
--            cfg.burst ticks every division gets a new order in the same tick (a mass order through the queue)
--            "mass":  cfg.n loose walkers of one force; at cfg.start one orders.move of all of them (a 1,000-unit order)
--            "mass_div": the same units as cfg.n / 16 divisions; one order through the division router
--   half, leg, start, burst, comp = {{name, n}, ...}
-- Log lines: "[rts] div stress ..." (setup, every 10 s, queue drains come from orders.lua).
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local cfg = require("scripts.div_stress_cfg")

local SURFACE = "div-stress"

local function rnd()
  local S = storage.div_stress
  S.seed = (S.seed * 1103515245 + 12345) % 2147483648
  return S.seed / 2147483648
end

local function is_water(s, x, y) return s.get_tile(x, y).name == "water" end

local function land_point(s, half, near, dist)
  for _ = 1, 80 do
    local x, y
    if near then
      local a = rnd() * 2 * math.pi
      x, y = math.floor(near.x + math.cos(a) * dist), math.floor(near.y + math.sin(a) * dist)
    else
      x = math.floor((rnd() * 2 - 1) * (half - 32))
      y = math.floor((rnd() * 2 - 1) * (half - 32))
    end
    if math.abs(x) < half - 24 and math.abs(y) < half - 24 and not is_water(s, x, y)
       and not is_water(s, x + 4, y + 4) and not is_water(s, x - 4, y - 4) then
      return {x = x, y = y}
    end
  end
  return {x = 0, y = 0}
end

local function build_surface(half)
  local s = game.create_surface(SURFACE, {width = half * 2, height = half * 2, seed = 12345,
    default_enable_all_autoplace_controls = false, no_enemies_mode = true, peaceful_mode = true})
  s.generate_with_lab_tiles = true
  s.always_day = true
  s.request_to_generate_chunks({0, 0}, math.ceil(half / 32) + 1)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered({})) do e.destroy() end
  local tiles = {}
  for _, f in ipairs({-0.6, -0.2, 0.2, 0.6}) do
    local y0 = math.floor(half * f)
    for x = -half, half - 1 do
      if (x + half) % 128 >= 16 then
        for dy = 0, 7 do tiles[#tiles + 1] = {name = "water", position = {x, y0 + dy}} end
      end
    end
  end
  s.set_tiles(tiles)
  return s
end

local function make_forces(n)
  local names = {}
  for i = 1, n do
    local name = "rts-stress-" .. i
    if not game.forces[name] then game.create_force(name) end
    names[i] = name
  end
  for i = 1, n do
    for j = 1, n do
      -- friends, not only cease-fire: units of a cease-fire force that block a crowded ford get attacked as obstacles
      -- (seen in this scenario: 3 units in 20 s); friends never do
      if i ~= j then
        game.forces[names[i]].set_cease_fire(names[j], true)
        game.forces[names[i]].set_friend(names[j], true)
      end
    end
  end
  return names
end

local function spawn_block(s, force, at, comp, total)
  local list, k = {}, 0
  local cols = math.ceil(math.sqrt(total))
  for _, c in ipairs(comp) do
    for _ = 1, c[2] do
      k = k + 1
      local pos = {x = at.x + ((k - 1) % cols) * 3, y = at.y + math.floor((k - 1) / cols) * 3}
      local e = units.spawn(c[1], pos, force, nil, s)
      if e then list[#list + 1] = e end
    end
  end
  return list
end

events.on_init(function()
  storage.debug = storage.debug or {}
  storage.debug.autotest = false -- the stress scenario replaces the headless autotest
  local S = {seed = 4242, next_order = {}, arrivals = 0, ordered = 0, started = false}
  storage.div_stress = S
  local half = cfg.half or 512
  local s = build_surface(half)
  local prof = helpers.create_profiler()
  if cfg.mode == "march" then
    local forces = make_forces(cfg.forces or 4)
    local per = 0
    for _, c in ipairs(cfg.comp) do per = per + c[2] end
    local n = 0
    for _, f in ipairs(forces) do
      for _ = 1, cfg.divs or 12 do
        local list = spawn_block(s, f, land_point(s, half), cfg.comp, per)
        n = n + #list
        divisions.create(f, list, {stance = "hold"}, {owner = "ai"})
      end
    end
    prof.stop()
    log({"", string.format("[rts] div stress setup: march, %d units in %d divisions, %d forces, half %d, in ", n,
      table_size(storage.divisions), #forces, half), prof})
  else
    local forces = make_forces(1)
    local list = spawn_block(s, forces[1], {x = -60, y = -half * 0.4 + 20}, {{"rts-walker", cfg.n or 1000}},
      cfg.n or 1000)
    if cfg.mode == "mass_div" then
      for i = 1, #list, 16 do
        local part = {}
        for j = i, math.min(i + 15, #list) do part[#part + 1] = list[j] end
        divisions.create(forces[1], part, {stance = "hold"}, {owner = "ai"})
      end
    end
    S.mass = list
    prof.stop()
    log({"", string.format("[rts] div stress setup: %s, %d walkers, %d divisions, half %d, in ", cfg.mode, #list,
      table_size(storage.divisions), half), prof})
  end
end)

local function order_division(D, s)
  local S = storage.div_stress
  local from = D.pos or {x = 0, y = 0}
  local dest = land_point(s, cfg.half or 512, from, cfg.leg or 200)
  divisions.order(D.id, "move", dest)
  S.ordered = S.ordered + 1
end

-- an arrived division gets its next order on the next tick (never from inside divisions' own handler)
divisions.on_changed(function(D, what)
  local S = storage.div_stress
  if S and S.started and cfg.mode == "march" and what == "state" and D.state == "idle" then
    S.arrivals = S.arrivals + 1
    S.next_order[#S.next_order + 1] = D.id
  end
end)

events.on(defines.events.on_tick, function(e)
  local S = storage.div_stress
  if not S then return end
  local s = game.surfaces[SURFACE]
  local start = cfg.start or 120
  if cfg.mode == "march" then
    if e.tick == start or (S.started and cfg.burst and (e.tick - start) % cfg.burst == 0) then
      S.started = true
      S.next_order = {}
      local prof = helpers.create_profiler()
      local ids = {}
      for id in pairs(storage.divisions) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do order_division(storage.divisions[id], s) end
      prof.stop()
      log({"", string.format("[rts] div stress: tick %d mass order of %d divisions (script time ", e.tick, #ids), prof,
        ")"})
    elseif #S.next_order > 0 then
      for _, id in ipairs(S.next_order) do
        local D = storage.divisions[id]
        if D then order_division(D, s) end
      end
      S.next_order = {}
    end
  elseif e.tick == start then
    orders.queue_reset_max()
    local prof = helpers.create_profiler()
    local n = orders.move(S.mass, {x = 60, y = (cfg.half or 512) * 0.4 + 40})
    prof.stop()
    local q = orders.queue_stats()
    log({"", string.format("[rts] div stress: tick %d orders.move of %d units -> %d ordered, backlog %d (script time ",
      e.tick, #S.mass, n, q.backlog), prof, ")"})
  end
  if e.tick % 600 == 0 and e.tick > 0 then
    local q = orders.queue_stats()
    local moving, idle, far, total = 0, 0, 0, 0
    for _, D in pairs(storage.divisions or {}) do
      if D.state == "moving" then moving = moving + 1 else idle = idle + 1 end
      local recs = divisions.live_members(D)
      local c = util.centroid((function()
        local l = {}
        for i, r in ipairs(recs) do l[i] = r.entity end
        return l
      end)())
      for _, r in ipairs(recs) do
        total = total + 1
        if c and util.distance(r.entity, c) > 25 then far = far + 1 end
      end
    end
    local st = divisions.stats()
    util.log("div stress t=%ds: divisions moving %d idle %d, arrivals %d, orders %d, units %d (farther than 25 tiles "
      .. "from their division: %d) | queue: immediate %d queued %d max/tick unit %d group %d peak backlog %d | "
      .. "division stats: regroups %d rejoined %d group_fails %d", e.tick / 60, moving, idle, st.arrivals, S.ordered,
      total, far, q.immediate, q.queued, q.max_u, q.max_g, q.peak, st.regroups, st.rejoined, st.group_fails)
  end
end)

-- Losses: a stress unit should never die (cease-fire, no enemies); log why if one does.
events.on(defines.events.on_entity_died, function(e)
  local ent = e.entity
  if not (ent.valid and ent.surface.name == SURFACE) then return end
  local S = storage.div_stress
  S.deaths = (S.deaths or 0) + 1
  if S.deaths <= 10 then
    util.log("div stress: %s #%s of %s died at %s (cause %s #%s of %s, killing force %s, damage %s)", ent.name,
      tostring(ent.unit_number), ent.force.name, util.pos_str(ent.position),
      e.cause and e.cause.valid and e.cause.name or "-", e.cause and e.cause.valid and tostring(e.cause.unit_number)
      or "-", e.cause and e.cause.valid and e.cause.force.name or "-", e.force and e.force.name or "-",
      e.damage_type and e.damage_type.name or "-")
  end
end)
