-- Divisions functional test (test copy only: tools/divisions-bench.sh <name> '{mode = "func"}' 7200 0 99 runs it; the
-- scenario config is ignored). Drives scripts/divisions.lua, selection.lua and orders.lua through the autotest's fake
-- player index 0 (force rts-player) on its own lab-tile surface, the normal autotest switched off:
--   create, click selects the whole division, Shift + click one unit, control group remembers the division, a move of
--   the whole division is one group order and arrives, a partial selection detaches and the next division order takes
--   the units back, barracks reinforcement joins the division and its control group, attack-move beats an enemy
--   division and ends idle, hold / stop, stance advance engages, stance screen falls back, queue budgets, disband when
--   the last member dies. Phase 5 M1 QA round 1 (protocol step 33): a second division of 30 walkers moves 60 tiles,
--   then attack-moves 60 tiles elsewhere (its centroid must move within 30 s and end at the point), then attack-moves
--   12.5 tiles (inside the group's attack radius: before the fix the group finished at once and stood still).
-- Log lines "[rts] div func check <name>: PASS|FAIL ..." and "[rts] div func summary <pass>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local orders = require("scripts.orders")
local selection = require("scripts.selection")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local divisions = require("scripts.divisions")

local SURFACE = "div-func"
local P = 0 -- the autotest's fake player index (rts-player)
local ME, FOE = "rts-player", "rts-div-foe"
local TIMEOUT = 60 * 60

local function S() return storage.div_func end

local function check(name, ok, fmt, ...)
  local s = S()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("div func check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function surface() return game.surfaces[SURFACE] end

local function spawn(name, n, force, at)
  local list = {}
  for k = 1, n do
    local e = units.spawn(name, {x = at.x + ((k - 1) % 4) * 3, y = at.y + math.floor((k - 1) / 4) * 3}, force, nil,
      surface())
    if e then list[#list + 1] = e end
  end
  return list
end

local function click_area(e)
  local p = e.position
  return {left_top = {x = p.x, y = p.y}, right_bottom = {x = p.x, y = p.y}}
end

local function D() return divisions.get(S().id) end

local function members() return divisions.live_members(D()) end

local function all_recs(pred)
  for _, rec in ipairs(members()) do
    if not pred(rec) then return false, rec end
  end
  return true
end

local function centroid()
  local l = {}
  for i, rec in ipairs(members()) do l[i] = rec.entity end
  return util.centroid(l)
end

-- The second (QA round 1) division and its centroid.
local function AM() return divisions.get(S().am_id) end
local function am_centroid()
  local l = {}
  for i, rec in ipairs(divisions.live_members(AM())) do l[i] = rec.entity end
  return util.centroid(l)
end

local function next_stage(name)
  local s = S()
  s.stage, s.stage_tick = name, game.tick
  util.log("div func: stage %s at tick %d", name, game.tick)
end

events.on_init(function()
  storage.debug = storage.debug or {}
  storage.debug.autotest = false
  storage.div_func = {pass = 0, fail = 0, stage = "setup", stage_tick = 0}
  local s = game.create_surface(SURFACE, {width = 320, height = 320, seed = 7, default_enable_all_autoplace_controls = false,
    no_enemies_mode = true, peaceful_mode = true})
  s.generate_with_lab_tiles = true
  s.always_day = true
  s.request_to_generate_chunks({0, 0}, 6)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered({})) do e.destroy() end
  if not game.forces[FOE] then game.create_force(FOE) end
  if not game.forces[ME] then game.create_force(ME) end
  game.forces[FOE].set_cease_fire(ME, false)
  game.forces[ME].set_cease_fire(FOE, false)
end)

local function stage_tick(tick)
  local s = S()
  local age = tick - s.stage_tick
  local st = s.stage
  if st == "setup" then
    if tick < 60 then return end
    local list = {}
    for _, e in ipairs(spawn("rts-walker", 12, ME, {x = -70, y = -6})) do list[#list + 1] = e end
    for _, e in ipairs(spawn("rts-walker-heavy", 2, ME, {x = -70, y = 8})) do list[#list + 1] = e end
    for _, e in ipairs(spawn("rts-drone", 2, ME, {x = -60, y = 8})) do list[#list + 1] = e end
    s.id = divisions.create(ME, list, {stance = "hold"})
    local d = D()
    check("create", d ~= nil and table_size(d.units) == 16 and divisions.target_size(d) == 16 and d.stance == "hold"
      and d.force == ME and d.reinforce == true and storage.divisions[s.id] == d,
      "division #%s: %d units, target %d, stance %s, force %s, reinforce %s", tostring(s.id), d and table_size(d.units)
      or -1, d and divisions.target_size(d) or -1, d and d.stance or "-", d and d.force or "-", tostring(d and d.reinforce))
    s.one = list[1]
    -- a plain click on one member selects the whole division; Shift + click adds exactly one unit
    selection.clear(P)
    local n1 = selection.handle_area(P, {s.one}, click_area(s.one), false, surface())
    selection.clear(P)
    local n2 = selection.handle_area(P, {s.one}, click_area(s.one), true, surface())
    check("select_click_whole_division", n1 == 16, "plain click -> %d selected (want 16)", n1)
    check("select_shift_one_unit", n2 == 1, "Shift + click -> %d selected (want 1)", n2)
    -- control group 1 holds the whole division
    selection.handle_area(P, {s.one}, click_area(s.one), false, surface())
    selection.group_set(P, 1)
    local p = util.pstorage(P)
    check("group_remembers_division", p.group_divisions and p.group_divisions[1] and p.group_divisions[1][s.id] == true,
      "group 1 divisions: %s", serpent.line(p.group_divisions and p.group_divisions[1]))
    -- a move of the whole division is one division order (one unit group)
    s.dest = {x = -20, y = 0}
    local n = orders.move(P, s.dest)
    local d2 = D()
    local ok, bad = all_recs(function(rec) return rec.issuer == divisions.ISSUER and rec.order == "move" end)
    check("router_whole_division", n == 16 and d2.state == "moving" and d2.group ~= nil and d2.group.valid and ok,
      "orders.move -> %d units, state %s, group %s, members claimed %s%s", n, d2.state,
      tostring(d2.group_id), tostring(ok), bad and (" (#" .. bad.entity.unit_number .. " " .. tostring(bad.issuer) .. ")") or "")
    next_stage("arrive")
  elseif st == "arrive" then
    local d = D()
    if d.state == "idle" or age > TIMEOUT then
      local c = centroid()
      local ok = all_recs(function(rec)
        local cmd = rec.entity.commandable.command
        return rec.order == units.IDLE and rec.issuer == nil and cmd ~= nil
          and (cmd.type == defines.command.group or cmd.type == defines.command.stop)
      end)
      check("move_arrives_idle", d.state == "idle" and c and util.distance(c, s.dest) < 12 and ok,
        "state %s after %.1f s, centroid %s (%.1f from the target), members idle in the group or stopped: %s", d.state,
        age / 60, util.pos_str(c), c and util.distance(c, s.dest) or -1, tostring(ok))
      -- partial selection: two members are detached and move alone
      local recs = members()
      selection.clear(P)
      selection.handle_area(P, {recs[1].entity}, click_area(recs[1].entity), true, surface())
      selection.handle_area(P, {recs[2].entity}, click_area(recs[2].entity), true, surface())
      local n = orders.move(P, {x = -20, y = 24})
      local det = table_size(d.detached)
      check("router_partial_detaches", n == 2 and det == 2 and recs[1].issuer == orders.ISSUER and d.state == "idle",
        "orders.move of 2 members -> %d, detached %d, issuer %s, division state %s", n, det, tostring(recs[1].issuer),
        d.state)
      next_stage("rejoin")
    end
  elseif st == "rejoin" then
    if age < 180 then return end
    local d = D()
    selection.handle_area(P, {s.one}, click_area(s.one), false, surface())
    local n = orders.move(P, {x = -30, y = 0})
    local ok = all_recs(function(rec) return rec.issuer == divisions.ISSUER end)
    check("division_order_rejoins_detached", n == 16 and table_size(d.detached) == 0 and ok,
      "whole-division order -> %d units, detached %d, all claimed %s", n, table_size(d.detached), tostring(ok))
    -- reinforcement: a barracks set to reinforce the division; strength target raised to 18
    local b = surface().create_entity({name = "rts-barracks", position = {x = -60, y = -40}, force = ME})
    buildings.register(b)
    s.barracks = b
    d.template.composition["rts-walker"] = d.template.composition["rts-walker"] + 2
    local set = divisions.set_barracks(b.unit_number, s.id)
    s.gate = production.kit_gate
    production.kit_gate = nil -- no CC on this surface, so the supply cap would hold the kits
    production.set_recipe(b.unit_number, "rts-walker-kit") -- a crafting machine without a recipe has no output slot
    s.kits_in = b.get_output_inventory().insert({name = "rts-walker-kit", count = 3})
    check("barracks_set", set and divisions.barracks_division(b.unit_number) == s.id and s.kits_in == 3,
      "barracks #%d -> division %s, %d kits in its output", b.unit_number,
      tostring(divisions.barracks_division(b.unit_number)), s.kits_in)
    next_stage("reinforce")
  elseif st == "reinforce" then
    local d = D()
    if table_size(d.units) >= 18 and age >= 240 or age > 20 * 60 then
      production.kit_gate = s.gate
      local p = util.pstorage(P)
      local g = p.groups[1] or {}
      check("reinforcement_joins", table_size(d.units) == 18 and table_size(g) == 18
        and divisions.stats().reinforce_full >= 1,
        "division has %d units (target %d), control group 1 has %d, full-division refusals %d", table_size(d.units),
        divisions.target_size(d), table_size(g), divisions.stats().reinforce_full)
      -- attack-move into an enemy group
      s.foes = spawn("rts-walker", 6, FOE, {x = 40, y = -4})
      selection.handle_area(P, {s.one}, click_area(s.one), false, surface())
      local n = orders.attack_move(P, {x = 44, y = 0})
      check("attack_move_order", n == 18 and d.order.kind == "attack_move" and d.state == "moving",
        "orders.attack_move -> %d, order %s, state %s", n, d.order.kind, d.state)
      next_stage("fight")
    end
  elseif st == "fight" then
    local d = D()
    local alive = 0
    for _, e in ipairs(s.foes) do if e.valid then alive = alive + 1 end end
    if (alive == 0 and d.state == "idle") or age > TIMEOUT then
      check("attack_move_wins_and_idles", alive == 0 and d.state == "idle" and table_size(d.units) > 0,
        "enemies alive %d, division state %s with %d units after %.1f s, re-targets %d", alive, d.state,
        table_size(d.units), age / 60, divisions.stats().retargets)
      local n = orders.hold(P)
      local ok = all_recs(function(rec) return rec.order == "hold" and rec.issuer == divisions.ISSUER end)
      check("hold", n == table_size(d.units) and d.state == "holding" and ok and d.group == nil,
        "orders.hold -> %d, state %s, members hold %s", n, d.state, tostring(ok))
      n = orders.stop(P)
      ok = all_recs(function(rec) return rec.order == units.IDLE end)
      check("stop", d.state == "idle" and ok, "orders.stop -> %d, state %s, members idle %s", n, d.state, tostring(ok))
      divisions.set_stance(s.id, "advance")
      local c = centroid()
      s.lure = spawn("rts-walker", 1, FOE, {x = c.x + 30, y = c.y})
      next_stage("advance")
    end
  elseif st == "advance" then
    local d = D()
    local engaged = d.order and d.order.auto == "stance advance"
    if engaged or age > 10 * 60 then
      check("stance_advance_engages", engaged, "order %s (%s) %.1f s after an enemy came within 30 tiles",
        d.order and d.order.kind or "-", d.order and tostring(d.order.auto) or "-", age / 60)
      next_stage("advance_done")
    end
  elseif st == "advance_done" then
    local d = D()
    local lure_alive = s.lure[1] and s.lure[1].valid
    if (not lure_alive and d.state == "idle") or age > TIMEOUT then
      if lure_alive then s.lure[1].destroy() end
      divisions.set_stance(s.id, "screen")
      local c = centroid()
      s.screen_from = c
      s.threat = spawn("rts-walker-heavy", 1, FOE, {x = c.x + 18, y = c.y})
      next_stage("screen")
    end
  elseif st == "screen" then
    local d = D()
    local fell_back = d.order and d.order.auto == "stance screen"
    if fell_back or age > 10 * 60 then
      check("stance_screen_falls_back", fell_back, "order %s (%s) %.1f s after a heavy came within 18 tiles",
        d.order and d.order.kind or "-", d.order and tostring(d.order.auto) or "-", age / 60)
      for _, e in ipairs(s.threat) do if e.valid then e.destroy() end end
      local q = orders.queue_stats()
      check("queue_budgets", q.max_u <= orders.QUEUE.unit_budget and q.max_g <= orders.QUEUE.group_budget,
        "max %d unit / %d group commands per tick (budgets %d / %d), %d immediate, %d queued", q.max_u, q.max_g,
        orders.QUEUE.unit_budget, orders.QUEUE.group_budget, q.immediate, q.queued)
      next_stage("am_setup")
    end
  elseif st == "am_setup" then
    -- QA round 1: 30 walkers, a 60-tile move, then attack-moves (long, then short)
    local list = spawn("rts-walker", 30, ME, {x = -130, y = 30})
    s.am_id = divisions.create(ME, list, {stance = "hold"})
    s.am_dest = {x = -70, y = 40}
    local ok = divisions.order(s.am_id, "move", s.am_dest)
    check("am_division_move_order", s.am_id ~= nil and #list == 30 and ok, "division #%s of %d walkers, move -> %s",
      tostring(s.am_id), #list, util.pos_str(s.am_dest))
    next_stage("am_move")
  elseif st == "am_move" then
    local d = AM()
    if d.state == "idle" or age > TIMEOUT then
      local c = am_centroid()
      check("am_move_arrives", d.state == "idle" and c and util.distance(c, s.am_dest) < 12,
        "state %s after %.1f s, centroid %s (%.1f from the target)", d.state, age / 60, util.pos_str(c),
        c and util.distance(c, s.am_dest) or -1)
      s.am_from = c
      s.am_dest = {x = -70, y = 100}
      local ok = divisions.order(s.am_id, "attack_move", s.am_dest)
      check("am_long_order", ok and d.state == "moving", "attack_move -> %s, state %s", util.pos_str(s.am_dest), d.state)
      next_stage("am_long")
    end
  elseif st == "am_long" then
    local d = AM()
    local c = am_centroid()
    if not s.am_moved and c and util.distance(c, s.am_from) >= 30 then
      s.am_moved = age
    end
    if age == 30 * 60 then
      check("am_long_moves_within_30s", s.am_moved ~= nil, "centroid moved 30 tiles after %s s (from %s, now %s)",
        s.am_moved and string.format("%.1f", s.am_moved / 60) or "never", util.pos_str(s.am_from), util.pos_str(c))
    end
    if (age > 30 * 60 and d.state == "idle") or age > TIMEOUT then
      check("am_long_arrives", d.state == "idle" and c and util.distance(c, s.am_dest) < 12,
        "state %s after %.1f s, centroid %s (%.1f from the target)", d.state, age / 60, util.pos_str(c),
        c and util.distance(c, s.am_dest) or -1)
      s.am_from = c
      s.am_dest = {x = c.x, y = c.y - 12.5} -- the QA run: 12.5 tiles, inside the attack radius of 30 walkers
      local ok = divisions.order(s.am_id, "attack_move", s.am_dest)
      check("am_short_order", ok and d.state == "moving", "attack_move -> %s (12.5 tiles), state %s",
        util.pos_str(s.am_dest), d.state)
      next_stage("am_short")
    end
  elseif st == "am_short" then
    local d = AM()
    if (age >= 120 and d.state == "idle") or age > 30 * 60 then
      local c = am_centroid()
      local moved = c and util.distance(c, s.am_from) or 0
      check("am_short_moves", d.state == "idle" and moved >= 8 and util.distance(c, s.am_dest) < 6,
        "state %s after %.1f s, centroid %s moved %.1f tiles, %.1f from the target", d.state, age / 60,
        util.pos_str(c), moved, c and util.distance(c, s.am_dest) or -1)
      next_stage("disband")
    end
  elseif st == "disband" then
    if age < 120 then return end
    local id = s.id
    local list = members()
    for _, rec in ipairs(list) do rec.entity.die() end
    local gone = divisions.get(id) == nil
    local stale = 0
    for _, rec in ipairs(list) do
      if storage.division_meta.member[rec.entity.valid and rec.entity.unit_number or -1] then stale = stale + 1 end
    end
    check("disband_when_empty", gone and stale == 0 and divisions.barracks_division(s.barracks.unit_number) == nil,
      "division #%d gone %s after %d members died; barracks reinforce cleared %s", id, tostring(gone), #list,
      tostring(divisions.barracks_division(s.barracks.unit_number) == nil))
    next_stage("done")
    util.log("div func summary %d/%d%s", s.pass, s.pass + s.fail, s.fail == 0 and " (all passed)"
      or string.format(" (%d FAILED)", s.fail))
  end
end

events.on(defines.events.on_tick, function(e)
  local s = S()
  if s and s.stage ~= "done" then stage_tick(e.tick) end
end)
