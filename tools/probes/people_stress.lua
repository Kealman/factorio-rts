-- Phase 5 M2 people stress fixture (test copy only; docs/qa/phase5-people-notes.md):
--   KEEP_TREE=build/p5m2-people/factorio-rts EXTRA_LUA=tools/probes/people_stress.lua STOP_ON=RTS_PEOPLE_STRESS_DONE \
--     PERF=1 SEED=501 tools/autotest-run.sh p5p-stress '{opponents = 1, difficulty = "normal", mode = "nation",
--     world_size = 2048, enemy_brain = "ai"}' 900
-- Two seconds into a Nation match both AI commanders stop; the probe founds CITIES cities by script (half per force) on a
-- grid, places PER_CITY staffed buildings on each city's land (factories, labs, smelters, extractors: 320 jobs a city)
-- and gives every city residents for about 70 % of its jobs. Every CHURN ticks a quarter of the cities change their
-- residents by up to +-15 %, so staffing steps and labor modules keep changing. After WARMUP the probe times one full
-- staffing pass and one growth pass of every city with a profiler, and the PERF=1 per-module lines give the per-tick
-- averages of population.lua and labor.lua over MEASURE minutes. Log: "[rts] people stress ...", stop marker
-- RTS_PEOPLE_STRESS_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local match = require("scripts.match")
local cities = require("scripts.cities")
local territory = require("scripts.territory")
local population = require("scripts.population")
local labor = require("scripts.labor")

local CITIES = 40
local PER_CITY = 54
local SPACING = 112
local CHURN = 30 * 60
local WARMUP = 60 * 60
local MEASURE = 5 * 60 * 60
local MIX = {{"rts-factory", 10}, {"rts-lab", 10}, {"rts-smelter", 17}, {"rts-extractor", 17}}

local function S()
  storage.pstress = storage.pstress or {step = "wait"}
  return storage.pstress
end

local function setup(s)
  local surface = match.surface()
  local forces = {util.PLAYER_FORCE, util.ENEMY_FORCE}
  local half = (storage.world and storage.world.size or 2048) / 2 - 120
  local slots = {}
  for gy = -4, 4 do
    for gx = -5, 5 do
      local x, y = gx * SPACING, gy * SPACING
      if math.abs(x) < half and math.abs(y) < half then slots[#slots + 1] = {x = x, y = y} end
    end
  end
  table.sort(slots, function(a, b)
    local da, db = a.x * a.x + a.y * a.y, b.x * b.x + b.y * b.y
    if da ~= db then return da < db end
    return a.x < b.x
  end)
  local made, placed = {}, 0
  for _, slot in ipairs(slots) do
    if #made >= CITIES then break end
    local force = forces[#made % 2 + 1]
    local p = surface.find_non_colliding_position("rts-city-center", slot, 20, 1, true)
    if p and not territory.city_at(p) then
      for _, e in pairs(surface.find_entities_filtered({area = {{p.x - 40, p.y - 40}, {p.x + 40, p.y + 40}},
                                                        type = {"tree", "simple-entity", "cliff"}})) do
        e.destroy()
      end
      local id = cities.found(force, p, {why = "(stress)"})
      if id then made[#made + 1] = {id = id, x = p.x, y = p.y, force = force} end
    end
  end
  territory.flush()
  for _, c in ipairs(made) do
    local k = 0
    for _, spec in ipairs(MIX) do
      for _ = 1, spec[2] do
        local col, row = k % 10, math.floor(k / 10)
        k = k + 1
        local want = {x = c.x - 30 + col * 6.5, y = c.y + (row < 2 and -18 + row * 6.5 or -2 + row * 6.5)}
        local pos = surface.find_non_colliding_position(spec[1], want, 4, 1, true)
        if pos and territory.city_at(pos) == c.id then
          local e = surface.create_entity({name = spec[1], position = pos, force = c.force, raise_built = true})
          if e then placed = placed + 1 end
        end
      end
    end
  end
  for _, c in ipairs(made) do
    local P = population.get(c.id)
    local st = labor.step_city(c.id) or {}
    P.pop = (st.jobs or 0) * 0.7 / 0.6
    P.base = math.max(P.base, P.pop * 1.2)
    local center = cities.get(c.id).entity
    local net = center and center.valid and center.logistic_network
    if net then net.insert({name = "rts-rations", count = 500}) end
  end
  s.cities = made
  s.placed = placed
  util.log("people stress: %d cities, %d staffed buildings placed", #made, placed)
end

local function churn(s, tick)
  local n = 0
  for i, c in ipairs(s.cities) do
    if (i + math.floor(tick / CHURN)) % 4 == 0 then
      local P = population.get(c.id)
      if P then
        local st = labor.city_stats(c.id)
        local jobs = st.jobs or 0
        local f = 0.55 + ((i * 7919 + math.floor(tick / CHURN) * 104729) % 31) / 100 -- 0.55 .. 0.85 of the jobs
        P.pop = jobs * f / 0.6
        P.base = math.max(P.base, P.pop * 1.2)
        n = n + 1
      end
    end
  end
  return n
end

local function time_passes(s)
  local prof = helpers.create_profiler()
  local buildings, changes0 = 0, storage.labor.changes
  for _, c in ipairs(s.cities) do
    local st = labor.step_city(c.id)
    buildings = buildings + (st and st.buildings or 0)
  end
  prof.stop()
  local prof2 = helpers.create_profiler()
  for _, c in ipairs(s.cities) do population.step(c.id) end
  prof2.stop()
  log({"", string.format("[rts] people stress: one staffing pass of %d cities (%d staffed buildings, %d step changes): ",
    #s.cities, buildings, storage.labor.changes - changes0), prof, " ; one growth pass of every city: ", prof2})
end

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = S()
  local tick = e.tick
  if s.step == "wait" then
    if tick - m.tick_started < 120 then return end
    ai.stop_force(util.PLAYER_FORCE)
    ai.stop_force(util.ENEMY_FORCE)
    setup(s)
    s.step, s.t0 = "warmup", tick
    return
  end
  if s.cities and tick % CHURN == 0 then
    local n = churn(s, tick)
    if s.step == "measure" then s.churned = (s.churned or 0) + n end
  end
  if s.step == "warmup" and tick - s.t0 >= WARMUP then
    time_passes(s)
    s.step, s.t1, s.changes0 = "measure", tick, storage.labor.changes
    util.log("people stress: measuring from tick %d", tick)
  elseif s.step == "measure" and tick - s.t1 >= MEASURE then
    time_passes(s)
    local stopped, partial, full = 0, 0, 0
    for _, c in ipairs(s.cities) do
      local st = labor.city_stats(c.id)
      stopped, partial = stopped + (st.stopped or 0), partial + (st.partial or 0)
      full = full + (st.buildings or 0) - (st.stopped or 0) - (st.partial or 0)
    end
    util.log("people stress summary: %d cities, %d staffed buildings, %d step changes in %d min (%d churns), now %d full, "
      .. "%d partial, %d stopped", #s.cities, s.placed, storage.labor.changes - s.changes0, MEASURE / 3600,
      s.churned or 0, full, partial, stopped)
    s.step = "done"
    log("RTS_PEOPLE_STRESS_DONE")
  end
end)
