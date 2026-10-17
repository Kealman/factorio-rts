-- Phase 5 M3 air performance fixture (test copy only, tools/autotest-run.sh EXTRA_LUA with PERF=1; docs/qa/
-- phase5-air-notes.md section 5). Beside a Nation-mode AI match: a city of rts-ai-3 with an airfield in the corner
-- farthest from the spawns (Age III, Aviation and Air Force researched), then
--   +60 s   save p5m3air-perf0 (no planes)
--   +70 s   60 planes (20 scouts, 20 bombers, 20 interceptors) in one division on patrol 100 tiles from the airfield,
--           radius 70: they fly, drain, turn back at bingo / 20, rearm and resume the patrol
--   +130 s  save p5m3air-perf60
--   then PERF=1's per-minute lines carry the "air" module's share; at +DURATION the planes' state is logged and
--   "[rts] air perf done" ends the run.
-- The saves go to the run's write-data dir (build/runs/<run>/saves; create it before the run) for
-- `factorio --benchmark` (with and without the planes). Everything here is inert when the game is not multiplayer, so
-- a benchmark of those saves measures the match and the planes only.
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local research = require("scripts.research")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local air = require("scripts.air")
local balance = require("balance")

local HOME = "rts-ai-3"
local START = 300
local DURATION = 6 * 60 * 60
local A = balance.nation.air

local function surface() return game.surfaces[storage.match.surface] end

local function corner()
  local half = (storage.world and storage.world.size or 2048) / 2
  local spawns = storage.match.spawns or {}
  local best, bd
  local r = half - 230
  for _, c in ipairs({{r, r}, {-r, r}, {r, -r}, {-r, -r}}) do
    local md
    for _, p in pairs(spawns) do
      local d = util.distance(p, {x = c[1], y = c[2]})
      if not md or d < md then md = d end
    end
    md = md or 0
    if not bd or md > bd then best, bd = {x = c[1], y = c[2]}, md end
  end
  return best
end

local function setup(P)
  local s = surface()
  local c = corner()
  c = {x = math.floor(c.x), y = math.floor(c.y)}
  for cx = math.floor((c.x - 200) / 32), math.floor((c.x + 200) / 32) do
    for cy = math.floor((c.y - 200) / 32), math.floor((c.y + 200) / 32) do
      s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
    end
  end
  s.force_generate_chunk_requests()
  P.city = cities.found(HOME, c, {why = "(air perf)"})
  territory.flush()
  local fpos = s.find_non_colliding_position("rts-airfield", {c.x, c.y + 30}, 20, 1, true)
  P.field = fpos and s.create_entity({name = "rts-airfield", position = fpos, force = HOME, raise_built = true})
  storage.ages = storage.ages or {}
  storage.ages[HOME] = {age = 3}
  for _, t in ipairs(A.techs) do game.forces[HOME].technologies[t.name].researched = true end
  research.apply(game.forces[HOME])
  P.c = c
  -- the patrol point: 100 tiles from the airfield towards the world centre
  local dx, dy = -c.x, -c.y
  local len = math.max(1, math.sqrt(dx * dx + dy * dy))
  P.patrol = {x = c.x + dx / len * 100, y = c.y + dy / len * 100}
  util.log("air perf: city %s at %s, airfield %s, patrol point %s", tostring(P.city), util.pos_str(c),
    P.field and util.pos_str(P.field.position) or "-", util.pos_str(P.patrol))
end

events.on_nth_tick(60, function()
  if not game.is_multiplayer() then return end -- a --benchmark of the saves: the fixture stays still
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local P = storage.air_perf
  if not P then
    if game.tick - m.tick_started < START then return end
    if not game.forces[HOME] then game.create_force(HOME) end
    P = {t0 = game.tick, phase = "wait0"}
    storage.air_perf = P
    setup(P)
    return
  end
  local el = game.tick - P.t0
  if P.phase == "wait0" and el >= 60 * 60 then
    game.server_save("p5m3air-perf0")
    util.log("air perf: saved p5m3air-perf0 at tick %d", game.tick)
    P.phase = "spawn"
  elseif P.phase == "spawn" and el >= 70 * 60 then
    local list = {}
    local base = P.field.position
    for k, name in ipairs(A.planes) do
      for i = 1, 20 do
        local e = units.spawn(name, {x = base.x - 30 + i * 3, y = base.y - 10 + k * 6}, HOME, nil, surface())
        if e then list[#list + 1] = e end
      end
    end
    P.div = divisions.create(HOME, list, {name = "Air wing"})
    local n = air.order_patrol(P.div, P.patrol, 70)
    util.log("air perf: %d planes spawned, %d on patrol at tick %d", #list, n, game.tick)
    P.phase = "save60"
  elseif P.phase == "save60" and el >= 130 * 60 then
    game.server_save("p5m3air-perf60")
    util.log("air perf: saved p5m3air-perf60 at tick %d; %s", game.tick, air.describe(HOME))
    P.phase = "run"
  elseif P.phase == "run" and el % 3600 == 0 then
    util.log("air perf: %s", air.describe(HOME))
    if el >= DURATION then
      P.phase = "done"
      util.log("air perf done")
    end
  end
end)
