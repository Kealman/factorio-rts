-- Probe (m2-integ, work item B1): Nation-mode targeting through the real order paths (scripts/targeting.lua).
-- At war with rts-ai-1, five lanes far apart near the player's capital, each with the same enemy row (rails, a rail
-- signal, a pole, a belt, an inserter, three registered buildings: factory, extractor, stockpile, and two enemy walkers):
--   A orders.attack_move, 4 walkers, through the row            expect: the enemy walkers dead, rails/signal/pole intact
--   B divisions.order attack_move, 8 walkers, through the row   expect: the same (a division's fight may hit buildings)
--   C orders.attack_move, 4 raiders, through the row            expect: poles, signal, belt hit (raider sabotage)
--   D orders.attack_move, 4 walkers, destination ON the rails   expect: rails intact, buildings near the point struck
--   E an own rts-turret (magazines) 8 tiles from the row        expect: the enemy walkers dead, rails intact
-- Log: "m2tp: lane X ..." every 10 s, "m2tp check <name>: PASS|FAIL ...", "RTS_M2TP_DONE".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local units = require("scripts.units")
local orders = require("scripts.orders")
local buildings = require("scripts.buildings")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")

local F, E = "rts-player", "rts-ai-1"
local function S() storage.m2tp = storage.m2tp or {step = "wait"} return storage.m2tp end
local LANES = {"A", "B", "C", "D", "E"}
local INFRA = {["straight-rail"] = true, ["rail-signal"] = true, ["medium-electric-pole"] = true,
               ["transport-belt"] = false, inserter = false} -- belts and inserters are not protected: not counted

local function row(surface, x0, y0)
  local list = {}
  local function add(spec, register)
    spec.force = E
    local e = surface.create_entity(spec)
    if e then
      list[#list + 1] = {e = e, name = e.name}
      if register then buildings.register(e) end
    else
      util.log("m2tp: could not create %s at %s", spec.name, util.pos_str(spec.position))
    end
  end
  for i = -4, 4 do add({name = "straight-rail", position = {x0 + i * 2 + 1, y0 + 1}, direction = defines.direction.east}) end
  add({name = "rail-signal", position = {x0 + 0.5, y0 - 1.5}, direction = defines.direction.west})
  add({name = "medium-electric-pole", position = {x0 - 6.5, y0 - 4.5}})
  add({name = "transport-belt", position = {x0 + 6.5, y0 - 4.5}})
  add({name = "inserter", position = {x0 + 7.5, y0 - 4.5}})
  add({name = "rts-factory", position = {x0 - 8, y0 + 8}}, true)
  add({name = "rts-extractor", position = {x0 + 8, y0 + 8}}, true)
  add({name = "rts-stockpile", position = {x0, y0 + 8}}, true)
  return list
end

-- two enemy walkers on the approach, 15 tiles before the row (out of splash reach of it)
local function enemies(surface, x0, y)
  local list = {}
  for i = 1, 2 do
    local e = units.spawn("rts-walker", {x0 + i * 2, y}, E, nil, surface)
    if e then list[#list + 1] = e end
  end
  return list
end

local function clear(surface, x0, y0)
  local tiles = {}
  for x = x0 - 40, x0 + 40 do
    for y = y0 - 50, y0 + 50 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true)
  for _, e in pairs(surface.find_entities_filtered({area = {{x0 - 40, y0 - 50}, {x0 + 40, y0 + 50}},
      type = {"tree", "simple-entity", "cliff", "fish"}})) do
    if e.valid then e.destroy() end
  end
end

local function walkers(surface, name, x0, y, n)
  local list = {}
  for k = 1, n do
    local e = units.spawn(name, {x0 - 4 + (k % 4) * 2, y + math.floor((k - 1) / 4) * 2}, F, nil, surface)
    if e then list[#list + 1] = e end
  end
  return list
end

local function report(s, final)
  for _, L in ipairs(s.lanes) do
    local dead_infra, dead_bld, hit_infra, parts = 0, 0, 0, {}
    for _, it in ipairs(L.row) do
      local e = it.e
      if not e.valid then
        if INFRA[it.name] then dead_infra = dead_infra + 1 else dead_bld = dead_bld + 1 end
        parts[#parts + 1] = it.name .. " DEAD"
      elseif e.health < e.max_health then
        if INFRA[it.name] then hit_infra = hit_infra + 1 end
        parts[#parts + 1] = string.format("%s %.0f/%.0f", it.name, e.health, e.max_health)
      end
    end
    L.dead_infra, L.dead_bld, L.hit_infra = dead_infra, dead_bld, hit_infra
    local dead_units = 0
    for _, u in ipairs(L.enemies or {}) do if not u.valid then dead_units = dead_units + 1 end end
    L.dead_units = dead_units
    util.log("m2tp: t=%ds lane %s: infra dead %d hit %d, buildings dead %d, enemy walkers dead %d [%s]",
      (game.tick - s.t) / 60, L.id, dead_infra, hit_infra, dead_bld, dead_units, table.concat(parts, ", "))
  end
  if not final then return end
  local by = {}
  for _, L in ipairs(s.lanes) do by[L.id] = L end
  local function check(name, ok, detail)
    util.log("m2tp check %s: %s %s", name, ok and "PASS" or "FAIL", detail)
  end
  for _, id in ipairs({"A", "B"}) do
    local L = by[id]
    -- buildings near the fight may fall to its area attacks (engine combat); rails, signals and poles must not
    check("lane_" .. id, L.dead_infra == 0 and L.hit_infra <= 1 and L.dead_units == 2,
      string.format("infra dead %d hit %d, buildings dead %d, enemy walkers dead %d (want infra 0, walkers 2; undone "
        .. "hits so far %d)", L.dead_infra, L.hit_infra, L.dead_bld, L.dead_units,
        storage.targeting and storage.targeting.undone or 0))
  end
  local D = by.D
  check("lane_D", D.dead_infra == 0 and D.hit_infra == 0 and D.dead_bld >= 1 and D.dead_units == 2,
    string.format("infra dead %d hit %d, buildings dead %d, enemy walkers dead %d (want 0, 0, >= 1, 2)", D.dead_infra,
      D.hit_infra, D.dead_bld, D.dead_units))
  local C = by.C
  check("lane_C_raiders", C.dead_infra + C.hit_infra >= 1,
    string.format("infra dead %d hit %d (raiders sabotage: want >= 1)", C.dead_infra, C.hit_infra))
  local Ln = by.E
  check("lane_E_turret", Ln.dead_infra == 0 and Ln.hit_infra == 0 and Ln.dead_units == 2,
    string.format("infra dead %d hit %d, buildings dead %d, enemy walkers dead %d (want infra 0, walkers 2)",
      Ln.dead_infra, Ln.hit_infra, Ln.dead_bld, Ln.dead_units))
end

-- every hit on a row entity: what hit it (the first 40)
events.on(defines.events.on_entity_damaged, function(e)
  local s = storage.m2tp
  if not (s and s.lanes and e.entity and e.entity.valid) or (s.hits or 0) >= 40 then return end
  if e.entity.force.name ~= E or e.entity.type == "spider-unit" then return end
  s.hits = (s.hits or 0) + 1
  local c = e.cause
  util.log("m2tp hit: %s at %s %.0f %s by %s%s", e.entity.name, util.pos_str(e.entity.position), e.final_damage_amount,
    e.damage_type.name, c and c.valid and (c.name .. " #" .. tostring(c.unit_number)) or "-",
    c and c.valid and c.commandable and c.commandable.command and (" cmd " .. tostring(c.commandable.command.type)) or "")
end)

events.on_nth_tick(60, function(ev)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = S()
  if s.step == "wait" then
    if ev.tick - m.tick_started < 600 then return end
    ai.stop_force(F) ai.stop_force(E)
    diplomacy.set_state(F, E, "war", "probe")
    local surface = game.surfaces[m.surface]
    local home = m.spawns[F]
    -- lanes 170 tiles apart on the side of the capital that faces the map centre
    local dy = home.y > 0 and -170 or 170
    s.lanes, s.registered, s.flagged = {}, 0, 0
    for i, id in ipairs(LANES) do
      local x0 = math.floor(home.x + (i - 3) * 170)
      local y0 = math.floor(home.y + dy)
      local lim = (m.config.world_size or 2048) / 2 - 60
      x0 = math.max(-lim, math.min(lim, x0))
      clear(surface, x0, y0)
      local L = {id = id, row = row(surface, x0, y0), x0 = x0, y0 = y0}
      L.enemies = enemies(surface, x0, y0 + (dy > 0 and -15 or 15))
      local start_y = y0 + (dy > 0 and -30 or 30)
      local beyond = {x = x0, y = y0 + (dy > 0 and 35 or -35)}
      if id == "A" then
        L.units = walkers(surface, "rts-walker", x0, start_y, 4)
        orders.attack_move(L.units, beyond)
      elseif id == "B" then
        L.units = walkers(surface, "rts-walker", x0, start_y, 8)
        local did = divisions.create(F, L.units)
        L.div = did
        util.log("m2tp: lane B division %s order %s", tostring(did), tostring(did and divisions.order(did, "attack_move", beyond)))
      elseif id == "C" then
        L.units = walkers(surface, "rts-raider", x0, start_y, 4)
        orders.attack_move(L.units, beyond)
      elseif id == "D" then
        L.units = walkers(surface, "rts-walker", x0, start_y, 4)
        orders.attack_move(L.units, {x = x0, y = y0 + 1})
      elseif id == "E" then
        local t = surface.create_entity({name = "rts-turret", position = {x0, y0 + (dy > 0 and -9 or 9)}, force = F,
                                         raise_built = true})
        if t then
          local inv = t.get_inventory(defines.inventory.turret_ammo)
          if inv then inv.insert({name = "firearm-magazine", count = 50}) end
        end
        util.log("m2tp: lane E turret %s", tostring(t and t.valid))
        L.units = {}
      end
      s.lanes[#s.lanes + 1] = L
    end
    s.t = ev.tick
    s.step = "observe"
    util.log("m2tp: started %d lanes (capital %s, nation=%s)", #s.lanes, util.pos_str(home), tostring(m.config.mode))
  elseif s.step == "observe" then
    local age = ev.tick - s.t
    if age % 600 ~= 0 then return end
    local final = age >= 75 * 60
    report(s, final)
    if final then
      log("RTS_M2TP_DONE")
      s.step = "done"
    end
  end
end)
