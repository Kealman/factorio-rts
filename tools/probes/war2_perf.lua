-- Phase 5 M3 war2 load probe (test copy only, EXTRA_LUA with PERF=1; docs/qa/phase5-war2-notes.md "Performance").
-- A 4-nation Nation match (opponents = 3) whose four nations all go to war. Away from the spawns, a 4 x 3 grid of
-- tier-3 test cities 150 tiles apart, no two neighbours of the same nation (three per nation), so every nation has
-- borders with the three others. Then, per nation: two 16-walker divisions hold its two most threatened segments,
-- one 120-tile fort belt is built in one of its rig cities, and an artillery train deployed at a depot in another rig
-- city bombards whatever hostile building lies within 120 tiles. The AIs keep playing. fronts.PROFILE_STEPS logs every
-- refresh job tick. Log lines "[rts] war2 perf ..."; the minute perf lines carry fronts, belts and trainswar.
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local rails = require("scripts.rails")
local wars = require("scripts.wars")
local diplomacy = require("scripts.diplomacy")
local fronts = require("scripts.fronts")
local belts = require("scripts.belts")
local trainswar = require("scripts.trainswar")
local buildings = require("scripts.buildings")

fronts.PROFILE_STEPS = true

local START = 300
local GRID = {{"rts-player", "rts-ai-1", "rts-ai-2", "rts-ai-3"},
              {"rts-ai-2", "rts-ai-3", "rts-player", "rts-ai-1"},
              {"rts-player", "rts-ai-1", "rts-ai-2", "rts-ai-3"}}
local STEP = 150

local function log(fmt, ...) util.log("war2 perf " .. fmt, ...) end

local function flatten(surface, area)
  local tiles = {}
  for x = area[1][1], area[2][1] - 1 do
    for y = area[1][2], area[2][2] - 1 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, true, true, false)
  for _, e in ipairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "resource",
                                                                          "fish", "corpse"}})) do
    if e.valid then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
end

-- The grid origin: the candidate point farthest from every spawn whose whole grid stays on the map.
local function origin()
  local half = (storage.world and storage.world.size or 2048) / 2
  local w, h = 3 * STEP + 200, 2 * STEP + 200
  local best, bd
  for gx = -half + 120, half - w, 64 do
    for gy = -half + 120, half - h, 64 do
      local md
      for _, p in pairs(storage.match.spawns or {}) do
        local d = util.distance(p, {x = gx + w / 2, y = gy + h / 2})
        if not md or d < md then md = d end
      end
      if md and (not bd or md > bd) then best, bd = {x = gx + 100, y = gy + 100}, md end
    end
  end
  return best, bd
end

local function setup(P)
  local surface = game.surfaces[storage.match.surface]
  local O, md = origin()
  local area = {{O.x - 110, O.y - 110}, {O.x + 3 * STEP + 110, O.y + 2 * STEP + 110}}
  for cx = math.floor(area[1][1] / 32), math.floor(area[2][1] / 32) do
    for cy = math.floor(area[1][2] / 32), math.floor(area[2][2] / 32) do
      surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
    end
  end
  surface.force_generate_chunk_requests()
  flatten(surface, area)
  P.cities = {}
  for r, row in ipairs(GRID) do
    for c, f in ipairs(row) do
      local pos = {x = O.x + (c - 1) * STEP, y = O.y + (r - 1) * STEP}
      local id = cities.found(f, pos, {why = "(war2 perf)"})
      local city = id and cities.get(id)
      if city then cities.set_tier(city, 3, "war2 perf") end
      P.cities[f] = P.cities[f] or {}
      table.insert(P.cities[f], {id = id, pos = pos})
    end
  end
  territory.flush()
  local nations = diplomacy.nations()
  local n = 0
  for i = 1, #nations do
    for j = i + 1, #nations do
      if diplomacy.state(nations[i], nations[j]) ~= "war" and wars.declare(nations[i], nations[j], {kind = "border"}) then
        n = n + 1
      end
    end
  end
  fronts.flush()
  local segs = 0
  for _, f in ipairs(nations) do segs = segs + #fronts.segments(f) end
  log("setup: grid at %s (nearest spawn %.0f), %d wars declared, %d segments", util.pos_str(O), md, n, segs)
  -- per nation: divisions on its two most threatened segments, a belt, an artillery train
  for _, f in ipairs(nations) do
    game.forces[f].technologies["rts-fortification"].researched = true
    local list = fronts.segments(f)
    table.sort(list, function(a, b) return a.threat > b.threat or (a.threat == b.threat and a.id < b.id) end)
    for k = 1, math.min(2, #list) do
      local seg = list[k]
      local at = {x = seg.mid.x + seg.back.x * 30, y = seg.mid.y + seg.back.y * 30}
      local us = {}
      for q = 1, 16 do
        local e = units.spawn("rts-walker", {x = at.x + (q % 4) * 3, y = at.y + math.floor(q / 4) * 3}, f, nil, surface)
        if e then us[#us + 1] = e end
      end
      local id = divisions.create(f, us, {name = f .. " line " .. k}, {owner = "ai"})
      if id then divisions.order(id, "hold_line", seg.id) end
    end
    local mine = P.cities[f]
    local c1 = mine[1] and cities.get(mine[1].id)
    local net = c1 and buildings.get(c1.center).entity.logistic_network
    if net then
      for item, cnt in pairs({["rts-wall"] = 400, ["rts-turret"] = 40, ["rts-gate"] = 10, ["rts-field-depot"] = 4,
                              ["firearm-magazine"] = 800}) do net.insert({name = item, count = cnt}) end
      local p0 = mine[1].pos
      local id = belts.plan(f, {{x = p0.x - 60, y = p0.y - 40}, {x = p0.x + 60, y = p0.y - 40}}, {why = "war2 perf"})
      log("%s: belt %s", f, tostring(id))
    end
    local c2 = mine[2] and mine[2].pos
    if c2 then
      local dep = surface.create_entity({name = "rts-depot", position = {c2.x + 20, c2.y + 20}, force = f,
                                         raise_built = true})
      local dnet = dep and logistics.hub_network(dep.unit_number)
      if dnet then
        for item, cnt in pairs({coal = 100, ["rts-locomotive-kit"] = 2, ["rts-artillery-wagon-kit"] = 1,
                                ["rts-rail-shell"] = 60}) do dnet.insert({name = item, count = cnt}) end
        local train, why = trainswar.deploy(dep.unit_number, "artillery", false)
        if train then trainswar.set_stance(train.id, "bombard") end
        log("%s: artillery train %s (%s)", f, tostring(train and train.id), tostring(why))
      else
        log("%s: no depot network (%s)", f, tostring(dep))
      end
    end
  end
end

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local P = storage.war2_perf
  if not P then
    if game.tick - m.tick_started < START then return end
    P = {started = game.tick}
    storage.war2_perf = P
    setup(P)
    return
  end
  -- a second belt per nation at 40 s: still being built at minute 1 (the save of tools/saveload-check.sh SAVE_MINUTE=1)
  if e.tick - P.started == 2400 then
    for _, f in ipairs(diplomacy.nations()) do
      local p0 = P.cities[f] and P.cities[f][1] and P.cities[f][1].pos
      if p0 then
        local id, why = belts.plan(f, {{x = p0.x - 50, y = p0.y + 25}, {x = p0.x + 50, y = p0.y + 25}},
          {why = "war2 perf 2"})
        if not id then log("%s: second belt refused (%s)", f, tostring(why)) end
        log("%s: second belt %s", f, tostring(id))
      end
    end
  end
  if (e.tick - P.started) % 3600 == 0 then
    local parts = {}
    for _, f in ipairs(diplomacy.nations()) do
      parts[#parts + 1] = string.format("%s; %s; %s", fronts.describe(f), belts.describe(f), trainswar.describe(f))
    end
    log("minute %d: %s", (e.tick - P.started) / 3600, table.concat(parts, " | "))
  end
end)
