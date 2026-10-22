-- Phase 5 M3 integration probe (docs/qa/phase5-m3-integration-notes.md, work items B): collateral damage, the rail
-- planner over a fort belt, the human flag of diplomacy. 1v1 Nation, at war with rts-ai-1, lanes near the player's
-- capital (as tools/probes/m2_targeting.lua):
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m3_integ.lua STOP_ON=RTS_M3I_DONE SEED=501 \
--     tools/autotest-run.sh m3i-integ '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048,
--     enemy_brain = "ai"}' 900
-- Each lane: an enemy row (3 belts, an inserter, a factory, an extractor, a stockpile, a house) with 3 enemy walkers
-- standing inside it:
--   A orders.attack_move, 8 walkers, through the row        expect: walkers dead, nothing of the row lost
--   B divisions.order attack_move, 8 walkers, through it     expect: the same
--   C orders.attack on the factory, 6 walkers                expect: the factory destroyed (explicit attack)
--   D divisions.order attack_move ON the factory, 8 walkers  expect: the factory destroyed (strike), belts intact
--   R 6 raiders, attack_move through the row                 info: raiders may sabotage (no check)
-- W: two own depots 80 tiles apart with an own wall line (31 walls) between them; rails.plan_line must cross it and
--    turn the walls under the track into gates.
-- H: diplomacy.is_human: false for both nations of a headless match (no player at the start).
-- Log: "m3i: ..." and "m3i check <name>: PASS|FAIL ...", "m3i summary P/N", "RTS_M3I_DONE".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local units = require("scripts.units")
local orders = require("scripts.orders")
local buildings = require("scripts.buildings")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")
local rails = require("scripts.rails")

local F, E = "rts-player", "rts-ai-1"
local function S() storage.m3i = storage.m3i or {step = "wait", pass = 0, fail = 0} return storage.m3i end
local LANES = {"A", "B", "C", "D", "R"}

local function check(name, ok, fmt, ...)
  local s = S()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("m3i check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

local function clear(surface, x0, y0, w, h)
  local tiles = {}
  for x = x0 - w, x0 + w do
    for y = y0 - h, y0 + h do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true)
  for _, e in pairs(surface.find_entities_filtered({area = {{x0 - w, y0 - h}, {x0 + w, y0 + h}},
      type = {"tree", "simple-entity", "cliff", "fish"}})) do
    if e.valid then e.destroy() end
  end
end

local function row(surface, x0, y0)
  local list = {}
  local function add(spec, register)
    spec.force = E
    local e = surface.create_entity(spec)
    if e then
      list[#list + 1] = {e = e, name = e.name}
      if register then buildings.register(e) end
    else
      util.log("m3i: could not create %s at %s", spec.name, util.pos_str(spec.position))
    end
  end
  for i = 0, 2 do add({name = "transport-belt", position = {x0 - 9.5 + i, y0 - 3.5}, direction = defines.direction.east}) end
  add({name = "inserter", position = {x0 - 5.5, y0 - 3.5}})
  add({name = "rts-factory", position = {x0, y0}}, true)
  add({name = "rts-extractor", position = {x0 + 8, y0}}, true)
  add({name = "rts-stockpile", position = {x0 - 8, y0 + 3}}, true)
  if prototypes.entity["rts-house"] then add({name = "rts-house", position = {x0 + 1, y0 + 8}}, true) end
  return list
end

local function spawn(surface, name, force, x0, y, n)
  local list = {}
  for k = 1, n do
    local e = units.spawn(name, {x0 - 4 + (k % 4) * 2, y + math.floor((k - 1) / 4) * 2}, force, nil, surface)
    if e then list[#list + 1] = e end
  end
  return list
end

local function lane_state(L)
  local dead, parts = {}, {}
  for _, it in ipairs(L.row) do
    if not it.e.valid then
      dead[it.name] = true
      parts[#parts + 1] = it.name .. " DEAD"
    elseif it.e.health < it.e.max_health then
      parts[#parts + 1] = string.format("%s %.0f/%.0f", it.name, it.e.health, it.e.max_health)
    end
  end
  local alive = 0
  for _, u in ipairs(L.enemies or {}) do if u.valid then alive = alive + 1 end end
  return dead, alive, parts
end

local function wall_plan(s, surface, home, dy)
  local x0, y0 = math.floor(home.x) + 120, math.floor(home.y + dy * 0.6)
  clear(surface, x0, y0, 70, 30)
  local a = surface.create_entity({name = "rts-depot", position = {x0 - 40, y0}, force = F, raise_built = true})
  local b = surface.create_entity({name = "rts-depot", position = {x0 + 40, y0}, force = F, raise_built = true})
  local walls = 0
  for y = y0 - 15, y0 + 15 do
    local w = surface.create_entity({name = "rts-wall", position = {x0 + 0.5, y + 0.5}, force = F, raise_built = true})
    if w then walls = walls + 1 end
  end
  s.W = {x0 = x0, y0 = y0, a = a and a.unit_number, b = b and b.unit_number, walls = walls}
  local id, why = rails.plan_line(F, s.W.a, s.W.b)
  s.W.line = id
  util.log("m3i: wall lane at (%d, %d): depots #%s #%s, %d walls, line %s (%s)", x0, y0, tostring(s.W.a),
    tostring(s.W.b), walls, tostring(id), tostring(why))
end

local function wall_check(s, surface)
  local W = s.W
  local line = W.line and storage.rails.lines[W.line]
  local crossing, gates = 0, 0
  for _, p in ipairs(line and line.pieces or {}) do
    if math.abs(p.x - (W.x0 + 0.5)) <= 1.5 and p.name == "straight-rail" then crossing = crossing + 1 end
  end
  local area = {{W.x0 - 1, W.y0 - 16}, {W.x0 + 2, W.y0 + 16}}
  gates = surface.count_entities_filtered({area = area, name = "rts-gate", force = F})
  local walls = surface.count_entities_filtered({area = area, name = "rts-wall", force = F})
  check("wall_cross", line ~= nil and line.state ~= "failed" and line.state ~= "surveying" and crossing > 0 and gates > 0,
    "line #%s %s, %d pieces, %d straight piece(s) across the wall column, %d gates and %d walls there (built %d walls)",
    tostring(W.line), line and line.state or "-", line and line.pieces and #line.pieces or 0, crossing, gates, walls,
    W.walls)
end

-- every hit on a lane's row (the first 80): what hit it and what it was doing
events.on(defines.events.on_entity_damaged, function(e)
  local s = storage.m3i
  local ent = e.entity
  if not (s and s.lanes and ent and ent.valid) then return end
  if ent.force.name ~= E or ent.type == "spider-unit" or ent.type == "unit" then return end
  local lane, bd
  for _, L in ipairs(s.lanes) do
    local d = math.abs(ent.position.x - L.x0)
    if not bd or d < bd then lane, bd = L, d end
  end
  if not lane or bd > 60 then return end
  lane.hits = (lane.hits or 0) + 1
  if lane.hits > 25 then return end
  local c = e.cause
  local info = "-"
  if c and c.valid then
    local rec = storage.units and c.unit_number and storage.units[c.unit_number]
    local cm = c.commandable
    local cmd = cm and cm.has_command and cm.command
    local dc = cm and cm.distraction_command
    info = string.format("%s #%s order %s target %s cmd %s dist %s", c.name, tostring(c.unit_number),
      rec and tostring(rec.order) or "-", rec and rec.target and rec.target.valid and rec.target.name or "-",
      cmd and tostring(cmd.type) or "-", dc and string.format("%s->%s", tostring(dc.type),
      dc.target and dc.target.valid and dc.target.name or "-") or "-")
  end
  util.log("m3i hit: lane %s %s at %s %.0f (hp %.0f) by %s | undone %d", lane.id, ent.name, util.pos_str(ent.position),
    e.final_damage_amount, ent.health, info, storage.targeting and storage.targeting.collateral or 0)
end)

events.on_nth_tick(60, function(ev)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = S()
  if s.step == "wait" then
    if ev.tick - m.tick_started < 600 then return end
    check("human_flag", diplomacy.is_human(F) == false and diplomacy.is_human(E) == false,
      "is_human: %s %s, %s %s (headless: nobody plays)", F, tostring(diplomacy.is_human(F)), E,
      tostring(diplomacy.is_human(E)))
    ai.stop_force(F) ai.stop_force(E)
    diplomacy.set_state(F, E, "war", "probe")
    local surface = game.surfaces[m.surface]
    local home = m.spawns[F]
    local dy = home.y > 0 and -170 or 170
    s.lanes = {}
    for i, id in ipairs(LANES) do
      local lim = (m.config.world_size or 2048) / 2 - 60
      local x0 = math.max(-lim, math.min(lim, math.floor(home.x + (i - 3) * 170)))
      local y0 = math.floor(home.y + dy)
      clear(surface, x0, y0, 40, 50)
      local L = {id = id, row = row(surface, x0, y0), x0 = x0, y0 = y0}
      if id == "A" or id == "B" or id == "R" then L.enemies = spawn(surface, "rts-walker", E, x0 + 2, y0 + 4, 3) end
      local start_y = y0 + (dy > 0 and -30 or 30)
      local beyond = {x = x0, y = y0 + (dy > 0 and 35 or -35)}
      if id == "A" then
        L.units = spawn(surface, "rts-walker", F, x0, start_y, 8)
        orders.attack_move(L.units, beyond)
      elseif id == "B" then
        L.units = spawn(surface, "rts-walker", F, x0, start_y, 8)
        L.div = divisions.create(F, L.units)
        divisions.order(L.div, "attack_move", beyond)
      elseif id == "C" then
        L.units = spawn(surface, "rts-walker", F, x0, start_y, 6)
        L.factory = L.row[5].e
        orders.attack(L.units, L.factory)
      elseif id == "D" then
        L.units = spawn(surface, "rts-walker", F, x0, start_y, 8)
        L.div = divisions.create(F, L.units)
        divisions.order(L.div, "attack_move", {x = x0, y = y0})
      elseif id == "R" then
        L.units = spawn(surface, "rts-raider", F, x0, start_y, 6)
        orders.attack_move(L.units, beyond)
      end
      s.lanes[#s.lanes + 1] = L
    end
    wall_plan(s, surface, home, dy)
    s.t = ev.tick
    s.step = "observe"
    util.log("m3i: started %d lanes (capital %s)", #s.lanes, util.pos_str(home))
  elseif s.step == "observe" then
    local age = ev.tick - s.t
    if age % 600 ~= 0 then return end
    for _, L in ipairs(s.lanes) do
      local dead, alive, parts = lane_state(L)
      util.log("m3i: t=%ds lane %s: enemies alive %d, [%s]", age / 60, L.id, alive, table.concat(parts, ", "))
    end
    if age < 90 * 60 then return end
    local by = {}
    for _, L in ipairs(s.lanes) do by[L.id] = L end
    local undone = storage.targeting and storage.targeting.collateral or 0
    for _, id in ipairs({"A", "B"}) do
      local dead, alive, parts = lane_state(by[id])
      check("collateral_" .. id, next(dead) == nil and alive == 0, "row lost [%s], enemy walkers alive %d (want none, "
        .. "0); collateral hits undone so far %d", table.concat(parts, ", "), alive, undone)
    end
    local dc = lane_state(by.C)
    check("explicit_C", dc["rts-factory"] == true, "factory %s", dc["rts-factory"] and "destroyed" or "standing")
    local dd = lane_state(by.D)
    -- the strike and the re-targets after it may take the registered buildings within 12 tiles of the point (M2 rule:
    -- an attack-move takes the buildings at its point); belts and inserters are no targets, only collateral
    check("strike_D", dd["rts-factory"] == true and not dd["transport-belt"] and not dd.inserter,
      "factory %s, belts %s, inserter %s", dd["rts-factory"] and "destroyed" or "standing",
      dd["transport-belt"] and "lost" or "intact", dd.inserter and "lost" or "intact")
    local dr, ar, pr = lane_state(by.R)
    util.log("m3i: raiders lane R: enemies alive %d, [%s] (info)", ar, table.concat(pr, ", "))
    wall_check(s, game.surfaces[m.surface])
    util.log("m3i summary %d/%d", s.pass, s.pass + s.fail)
    s.step = "done"
    log("RTS_M3I_DONE")
  end
end)
