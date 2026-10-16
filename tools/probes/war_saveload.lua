-- Phase 5 M2 war save/load probe (test copy only: tools/saveload-check.sh with EXTRA_LUA; docs/PHASE5-M2.md section 4
-- "save/load during a capture and with manifests in transit"). Beside a Nation-mode AI match:
--   * at AI autotest minute 2:00 a capital city of rts-ai-3 with ~3,000 entities is built (as in war_autotest.lua) and a
--     troop line of 1,000 tiles on a lab surface; 12 walkers of rts-ai-2 embark at 2:30 and the train leaves for the far
--     depot (about 36 s of travel);
--   * at 2:55 capture.flip gives the city to rts-ai-2 with capture.SLICE = 3 (about 17 s of slices);
--   the save (saveload-check.sh: at the "ai minute 3" line) therefore falls inside the flip job and the ride.
-- After the load the probe logs the state it finds, then "war saveload: capture finished after the load ..." and
-- "war saveload: troops disembarked after the load ...", and "war saveload summary ...".
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local rails = require("scripts.rails")
local capture = require("scripts.capture")
local garrison = require("scripts.garrison")

capture.SLICE = 3 -- the flip job spans the save

local DEF, ATT = "rts-ai-3", "rts-ai-2"
local LAB = "war-sl"
local MIN = 3600
local after_load = false -- module-local, logging only: true in a session that started from the save

local function st() return storage.war_sl end

local function lab()
  local s = game.surfaces[LAB]
  if s then return s end
  s = game.create_surface(LAB, {width = 4000, height = 600, peaceful_mode = true, no_enemies_mode = true})
  s.always_day = true
  for cx = 29, 66 do for cy = 6, 12 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = 960, 2120 do for y = 220, 380 do tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}} end end
  s.set_tiles(tiles, true, false, false, false)
  return s
end

local function spawn_n(surface, n, force, at, cols)
  local list = {}
  for k = 1, n do
    local e = units.spawn("rts-walker", {x = at.x + ((k - 1) % cols) * 3, y = at.y + math.floor((k - 1) / cols) * 3},
      force, nil, surface)
    if e then list[#list + 1] = e end
  end
  return list
end

local function setup_city(S)
  local surface = game.surfaces[storage.match.surface]
  local half = (storage.world and storage.world.size or 1536) / 2
  local best, bd
  for _, c in ipairs({{half - 200, half - 200}, {200 - half, half - 200}, {half - 200, 200 - half},
                      {200 - half, 200 - half}}) do
    local md
    for _, p in pairs(storage.match.spawns or {}) do
      local d = util.distance(p, {x = c[1], y = c[2]})
      if not md or d < md then md = d end
    end
    if not bd or (md or 0) > bd then best, bd = {x = c[1], y = c[2]}, md or 0 end
  end
  local p1 = {x = best.x, y = best.y}
  local sx = best.x > 0 and -1 or 1
  local p2 = {x = best.x + sx * 150, y = best.y}
  local area = {{math.min(p1.x, p2.x) - 110, p1.y - 110}, {math.max(p1.x, p2.x) + 110, p1.y + 110}}
  for cx = math.floor(area[1][1] / 32), math.floor(area[2][1] / 32) do
    for cy = math.floor(area[1][2] / 32), math.floor(area[2][2] / 32) do
      surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
    end
  end
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x = area[1][1], area[2][1] - 1 do for y = area[1][2], area[2][2] - 1 do tiles[#tiles + 1] = {name = "grass-1",
    position = {x, y}} end end
  surface.set_tiles(tiles, true, true, true, false)
  for _, e in ipairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "resource",
                                                                          "fish"}})) do
    if e.valid then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
  S.city = cities.found(DEF, p1, {why = "(war saveload)"})
  S.city2 = cities.found(DEF, p2, {why = "(war saveload)"})
  territory.flush()
  local side = -sx
  local n = 0
  local kinds = {{"rts-stockpile", 600}, {"transport-belt", 1300}, {"fast-inserter", 600}, {"medium-electric-pole", 300},
                 {"rts-wall", 300}}
  local k = 0
  for _, kd in ipairs(kinds) do
    for _ = 1, kd[2] do
      local i, j = k % 62, math.floor(k / 62)
      k = k + 1
      local e = surface.create_entity({name = kd[1], position = {p1.x + side * (20 + i) + 0.5, p1.y - 25 + j + 0.5},
        force = DEF, raise_built = kd[1] == "rts-stockpile" or kd[1] == "rts-wall"})
      if e then n = n + 1 end
    end
  end
  storage.population = storage.population or {}
  if storage.population[S.city] then storage.population[S.city].pop = 100 else storage.population[S.city] = {pop = 100} end
  util.log("war saveload: city %s of %s at %s with %d entities, second city %s", tostring(S.city), DEF,
    util.pos_str(p1), n, tostring(S.city2))
end

local function setup_rail(S)
  local s = lab()
  local A = s.create_entity({name = "rts-depot", position = {x = 1000, y = 300}, force = ATT, raise_built = true})
  local B = s.create_entity({name = "rts-depot", position = {x = 2000, y = 300}, force = ATT, raise_built = true})
  local dA, dB = rails.depot(A.unit_number), rails.depot(B.unit_number)
  local ty = dA.platform.track
  for x = dA.platform.ends[2].x + 1, dB.platform.ends[1].x - 1, 2 do
    s.create_entity({name = "straight-rail", position = {x, ty}, direction = defines.direction.east, force = ATT})
  end
  S.A, S.B = A.unit_number, B.unit_number
  logistics.hub_network(S.A).insert({name = "coal", count = 200})
  logistics.hub_network(S.B).insert({name = "coal", count = 200})
  logistics.hub_network(S.A).insert({name = "rts-locomotive-kit", count = 2})
  logistics.hub_network(S.A).insert({name = "rts-troop-wagon-kit", count = 1})
  local list = spawn_n(s, 12, ATT, {x = 995, y = 330}, 6)
  for i, e in ipairs(list) do if i % 2 == 0 then e.health = e.max_health * 0.7 end end
  S.div = divisions.create(ATT, list, {name = "Travellers", stance = "hold"}, {owner = "ai"})
  util.log("war saveload: troop line %d tiles, division #%d of %d walkers", dB.platform.ends[1].x - dA.platform.ends[2].x,
    S.div, #list)
end

local function describe(S)
  local cs = storage.capture
  local job
  for _, j in pairs(cs and cs.jobs or {}) do job = j end
  local M = storage.rails and storage.rails.manifests or {}
  local nm, nu = 0, 0
  for _, m in pairs(M) do
    nm = nm + 1
    nu = nu + #m.records
  end
  local D = divisions.get(S.div)
  local train = S.train_id and storage.rails.trains[S.train_id] and rails.train_of(storage.rails.trains[S.train_id])
  return string.format("capture job %s (phase %s, %s of %s, %d flipped), manifests %d (%d units), division #%s aboard %s "
    .. "on the map %d, troop train %s at x=%s speed %s", job and job.id or "-", job and job.phase or "-",
    job and tostring(job.i) or "-", job and job.list and tostring(#job.list) or "-", job and job.flipped or 0, nm, nu,
    tostring(S.div), tostring(D and D.aboard), D and #divisions.live_members(D) or 0,
    train and tostring(train.id) or "-", train and train.valid and string.format("%.0f", train.front_stock.position.x)
    or "-", train and train.valid and string.format("%.2f", train.speed) or "-")
end

events.on_load(function() after_load = true end)

events.on_nth_tick(1, function(e)
  local a = storage.ai_autotest
  if not (a and a.started and storage.match and storage.match.phase == "running") then return end
  if not storage.war_sl then storage.war_sl = {phase = "wait"} end
  local S = st()
  local age = e.tick - a.started
  if after_load and not S.load_logged then
    S.load_logged = true
    S.loaded_tick = e.tick
    util.log("war saveload: after the load at tick %d (AI minute %.2f): %s", e.tick, age / MIN, describe(S))
  end
  if S.phase == "wait" and age >= 2 * MIN then
    for _, f in ipairs({DEF, ATT}) do if not game.forces[f] then game.create_force(f) end end
    setup_city(S)
    setup_rail(S)
    S.phase = "embark"
  elseif S.phase == "embark" and age >= 2.65 * MIN then
    divisions.order(S.div, "embark", S.A)
    local rec = garrison.troop_train_at(ATT, S.A)
    local train = rec and rails.train_of(rec)
    if train then
      S.train_id = train.id
      rails.set_route(train, S.A, S.B)
    end
    util.log("war saveload: embark ordered, troop train %s", tostring(S.train_id))
    S.phase = "flip"
  elseif S.phase == "flip" and age >= 2.92 * MIN then
    S.pop_before = storage.population[S.city] and storage.population[S.city].pop or 100
    S.job = capture.flip(S.city, ATT, "war saveload")
    util.log("war saveload: capture.flip job %s with %d entities per tick", tostring(S.job), capture.SLICE)
    S.phase = "running"
  elseif S.phase == "running" then
    if age == 3 * MIN then util.log("war saveload: at AI minute 3 (the save follows): %s", describe(S)) end
    local cs = storage.capture
    if not S.cap_done and cs and cs.last and cs.last.city == S.city then
      S.cap_done = true
      local land = 0
      local box = territory.city_box(S.city)
      local surface = game.surfaces[storage.match.surface]
      for _, ent in ipairs(surface.find_entities_filtered({area = {{box.x0, box.y0}, {box.x1, box.y1}}, force = DEF})) do
        if ent.valid and not capture.KEEP_TYPES[ent.type] and territory.city_at(ent.position) == S.city then
          land = land + 1
        end
      end
      local pop = storage.population[S.city].pop
      util.log("war saveload: capture finished%s at tick %d: %d entities flipped in %d slices, %d of %s left on the "
        .. "land, population %.1f -> %.1f, %s capital city %s", after_load and " after the load" or " BEFORE the save",
        e.tick, cs.last.flipped, cs.last.slices, land, DEF, S.pop_before, pop, DEF, tostring(storage.nations[DEF].capital))
      -- x0.7 at the end of the job (scripts/population.lua may grow or starve the city a little meanwhile)
      S.cap_ok = after_load and land == 0 and math.abs(pop - 0.7 * S.pop_before) <= 0.05 * S.pop_before + 1
    end
    local D = divisions.get(S.div)
    if not S.troop_done and D and (D.aboard or 0) == 0 and S.boarded and #divisions.live_members(D) == 12 then
      S.troop_done = true
      local c = {x = 0, y = 0}
      for _, rec in ipairs(divisions.live_members(D)) do
        c.x, c.y = c.x + rec.entity.position.x / 12, c.y + rec.entity.position.y / 12
      end
      local hp = 0
      for _, rec in ipairs(divisions.live_members(D)) do hp = hp + rec.entity.health / rec.entity.max_health end
      util.log("war saveload: troops disembarked%s at tick %d: 12 units of division #%d at %s, mean health %.3f",
        after_load and " after the load" or " BEFORE the save", e.tick, S.div, util.pos_str(c), hp / 12)
      S.troop_ok = after_load and c.x > 1900
    end
    if D and (D.aboard or 0) == 12 then S.boarded = true end
    if S.cap_done and S.troop_done and not S.summary then
      S.summary = true
      util.log("war saveload summary %s (capture across the save %s, troops across the save %s)",
        (S.cap_ok and S.troop_ok) and "PASS" or "FAIL", tostring(S.cap_ok), tostring(S.troop_ok))
    end
  end
end)
