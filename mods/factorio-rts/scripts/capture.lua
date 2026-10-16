-- Phase 5 M2 war: cities are captured, not destroyed (docs/PHASE5-M2.md D4 and section 3 "capture.lua"; study
-- docs/research/scale/war-ai-performance.md section 2.5; notes docs/qa/phase5-war-notes.md). Nation mode only.
--
-- Subdue. A City Center (rts-city-center) or the Nation-mode Command Center of a registered city cannot die: an
-- on_entity_damaged handler (the shared filter of scripts/research.lua lists both names) clamps its health at
-- capture.subdue (10 %) of the maximum, even when one hit would kill it (probe: an entity whose handler restores its
-- health survives final_health 0), and marks the city subdued. The capital's armor (scripts/cities.lua) still applies
-- before the clamp.
-- Contest (every capture.period ticks, the ruin's rule from scripts/mapgen.lua capture_step): around a subdued city's
-- centre, registered units within capture.radius (24) tiles are counted (haulers do not count): the owner's and its
-- allies' are defenders, those of forces hostile to the owner attackers. Exactly one attacking force and no defender:
-- progress; capture.ticks (20 s) of it captures the city. Nobody there: the progress resets. Contested: it holds. A
-- city repaired above release_health or left alone for siege_timeout is no longer subdued. A label over the centre
-- shows the contest to everyone.
-- Flip (capture.flip, also the API for treaties): at once the centre and its hidden parts change force
-- (buildings.set_force, so territory, logistics and depot records follow), the centre restarts at restart_health, the
-- city record changes owner (cities.change_owner; the loser's capital moves to its largest remaining city: population,
-- then tier, then land) and the garrison is lost (scripts/garrison.lua). Then a job collects the old owner's entities on
-- the city's land (territory.city_box, then territory.city_at per entity) and flips them in slices of capture.slice
-- (500) per tick: ghosts, tile ghosts and item-request proxies are destroyed; units, haulers, the Commander and rolling
-- stock are left alone (they are not the city's); everything else changes force. Producers (factories, barracks,
-- districts, smelters, extractors, labs) are disabled_by_script for unrest_ticks (60 s) unless something else had
-- disabled them already. A last sweep after the slices catches what the new land took in. Then the population keeps
-- pop_keep (70 %) (scripts/population.lua when it exists, else storage.population[city].pop), the old owner's AI plan
-- forgets the lost buildings, "rts_city_captured" {city_id, from, to} is emitted and both sides get an alert. A nation
-- with no city left is eliminated through match.lua's path: its remaining units and producers die, so match.is_out
-- holds at its next check.
--
-- Owns storage.capture = {cities = {[city_id] = {subdued, progress, capturing, attackers, defenders, last_attack,
--   label}}, jobs = {[id] = job}, next_job, unrest = {[city_id] = {until_tick, entities = {LuaEntity}}}, stats =
--   {captures, flipped, ghosts, max_slice_ticks}}, cleared by match teardown. Log lines "[rts] capture: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local supply = require("scripts.supply")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local balance = require("balance")

local capture = {}

local W = balance.nation.war
local CP = W.capture
capture.SLICE = CP.slice           -- entities flipped per tick (tests may lower it to span a save)
capture.CENTERS = {["rts-city-center"] = true, ["rts-command-center"] = true}
capture.UNIT_TYPES = {"unit", "spider-unit", "spider-vehicle"}
capture.SIGNAL = "rts_city_captured"
-- left alone by a flip: mobile things are not the city's
capture.KEEP_TYPES = {unit = true, ["spider-unit"] = true, ["spider-vehicle"] = true, character = true, car = true,
                      locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
                      ["construction-robot"] = false, ["logistic-robot"] = false}
capture.DESTROY_TYPES = {["entity-ghost"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true}
-- producers that stop during unrest (buildings kinds)
capture.UNREST_KINDS = {factory = true, barracks = true, district = true, smelter = true, extractor = true, lab = true}
capture.SKIP_NAMES = {["rts-garrison-turret"] = true} -- scripts/garrison.lua destroys and rebuilds those

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.capture
  if not s then
    s = {}
    storage.capture = s
  end
  s.cities = s.cities or {}
  s.jobs = s.jobs or {}
  s.next_job = s.next_job or 1
  s.unrest = s.unrest or {}
  s.stats = s.stats or {captures = 0, flipped = 0, ghosts = 0, max_slice_ticks = 0, subdued = 0}
  return s
end

function capture.init() S() end

local function nation()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation" and m.surface ~= nil
end

local function loaded(module_name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

--- Force relation for the contest: diplomacy.hostile (scripts/diplomacy.lua, M2) when it exists, else engine enemies.
local function hostile(a, b)
  if a == b then return false end
  local dip = loaded("scripts.diplomacy")
  if dip and dip.hostile then return dip.hostile(a, b) end
  local fa, fb = game.forces[a], game.forces[b]
  return fa ~= nil and fb ~= nil and fa.is_enemy(fb)
end
capture.hostile = hostile

local function allied(a, b)
  if a == b then return true end
  local dip = loaded("scripts.diplomacy")
  if dip and dip.state then return dip.state(a, b) == "alliance" end
  local fa, fb = game.forces[a], game.forces[b]
  return fa ~= nil and fb ~= nil and fa.is_friend(fb)
end

local function label_of(force_name)
  return match.label and match.label(force_name) or force_name
end

local function garrison_mod() return loaded("scripts.garrison") end

--- The contest record of a city (nil when it never was subdued).
function capture.of(city_id) return S().cities[city_id] end

--- True while a flip job of the city runs.
function capture.flipping(city_id)
  for _, j in pairs(S().jobs) do
    if j.city == city_id then return true end
  end
  return false
end

--- True while the city's producers are stopped by unrest.
function capture.in_unrest(city_id)
  local u = S().unrest[city_id]
  return u ~= nil and game.tick < u.until_tick
end

---------------------------------------------------------------------------
-- Labels
---------------------------------------------------------------------------
local function set_label(c, city, text, color)
  local e = city.entity
  if not (e and e.valid) then return end
  if c.label and c.label.valid then
    c.label.text = text
    if color then c.label.color = color end
    return
  end
  c.label = rendering.draw_text({text = text, surface = e.surface, target = {entity = e, offset = {0, -3.5}},
                                 color = color or {1, 0.8, 0.3}, scale = 1.6, alignment = "center",
                                 use_rich_text = true})
end

local function clear_label(c)
  if c.label and c.label.valid then c.label.destroy() end
  c.label = nil
end

---------------------------------------------------------------------------
-- Subdue
---------------------------------------------------------------------------
--- Mark the city of a centre subdued (the damage handler calls it at the 10 % clamp). Returns the contest record.
function capture.subdue(center, by_force)
  if not (center and center.valid) then return nil end
  local city = cities.of_center(center.unit_number)
  if not city then return nil end
  local s = S()
  local c = s.cities[city.id]
  if not c then
    c = {progress = 0}
    s.cities[city.id] = c
  end
  c.last_attack = game.tick
  if not c.subdued then
    c.subdued = game.tick
    s.stats.subdued = s.stats.subdued + 1
    util.log("capture: city %d of %s at %s subdued%s", city.id, city.force, util.pos_str(city.position),
      by_force and (" by " .. by_force) or "")
    supply.alert(city.force, "city-subdued", "rts-war.alert-city-subdued", {cities.display_name(city)}, city.position)
    set_label(c, city, {"rts-war.label-subdued"}, {1, 0.5, 0.3})
  end
  return c
end

events.on(defines.events.on_entity_damaged, function(e)
  local ent = e.entity
  if not (ent and ent.valid and capture.CENTERS[ent.name]) then return end
  if not nation() then return end
  local cs = storage.city_state
  local id = cs and cs.by_center and cs.by_center[ent.unit_number]
  if not id then return end
  local max = ent.max_health
  local floor_hp = max * CP.subdue
  local by = e.force and e.force.name or nil
  -- only a hostile force subdues and besieges a city (the owner's own splash or shells in flight after a capture do not)
  local enemy = by ~= nil and hostile(by, ent.force.name)
  if ent.health < floor_hp then
    ent.health = floor_hp -- a centre never dies
    if enemy then capture.subdue(ent, by) end
  end
  local c = enemy and storage.capture and storage.capture.cities[id]
  if c then c.last_attack = game.tick end
  local g = garrison_mod()
  if g and g.on_center_damaged then g.on_center_damaged(id, ent) end
end)

---------------------------------------------------------------------------
-- Contest
---------------------------------------------------------------------------
local function count_around(city, surface)
  local attackers, defenders, nd = {}, 0, 0
  local owner = city.force
  for _, e in ipairs(surface.find_entities_filtered({position = city.entity.position, radius = CP.radius,
                                                     type = capture.UNIT_TYPES})) do
    local un = e.unit_number
    local rec = un and storage.units[un]
    if rec and rec.kind ~= "hauler" then
      local f = e.force.name
      if allied(f, owner) then
        defenders = defenders + 1
      elseif hostile(f, owner) then
        attackers[f] = (attackers[f] or 0) + 1
        nd = nd + 1
      end
    end
  end
  return attackers, defenders, nd
end

local function contest(city_id, c, dt)
  local city = cities.get(city_id)
  local e = city and city.entity
  if not (e and e.valid) or capture.flipping(city_id) then
    clear_label(c)
    S().cities[city_id] = nil
    return
  end
  if e.health >= e.max_health * CP.release_health
     or game.tick - (c.last_attack or c.subdued) >= CP.siege_timeout then
    util.log("capture: city %d of %s no longer subdued (%s)", city_id, city.force,
      e.health >= e.max_health * CP.release_health and "repaired" or "siege lifted")
    clear_label(c)
    S().cities[city_id] = nil
    return
  end
  local attackers, defenders, n = count_around(city, e.surface)
  c.defenders, c.attackers = defenders, n
  local forces = {}
  for f in pairs(attackers) do forces[#forces + 1] = f end
  table.sort(forces)
  if n == 0 then
    if c.capturing then
      c.capturing, c.progress = nil, 0
      set_label(c, city, {"rts-war.label-subdued"}, {1, 0.5, 0.3})
    end
    return
  end
  c.last_attack = game.tick
  if defenders > 0 or #forces > 1 then
    set_label(c, city, {"rts-war.label-contested", defenders, n}, {1, 0.85, 0.3})
    return
  end
  local f = forces[1]
  if c.capturing ~= f then
    -- the 20 s count from this first sighting
    c.capturing, c.progress = f, 0
    util.log("capture: city %d of %s: %s starts the capture with %d units", city_id, city.force, f, n)
    set_label(c, city, {"rts-war.label-capturing", label_of(f), 0}, {1, 0.4, 0.3})
    return
  end
  c.progress = c.progress + dt
  if c.progress >= CP.ticks then
    capture.flip(city_id, f, "contest")
  else
    set_label(c, city, {"rts-war.label-capturing", label_of(f), math.floor(100 * c.progress / CP.ticks)},
      {1, 0.4, 0.3})
  end
end

--- One contest step over every subdued city (every capture.period ticks).
function capture.step(dt)
  if not nation() then return end
  local s = S()
  local ids = {}
  for id in pairs(s.cities) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local c = s.cities[id]
    if c and c.subdued then contest(id, c, dt or CP.period) end
  end
end

-- m2-diplomacy (scripts/wars.lua): a treaty that cedes a city calls its on_cede hooks; capture.flip hands it over.
-- Registered at load when wars.lua loaded before this module, else at the first contest step (module-local flag: the
-- hook lists of both modules are rebuilt on every load, so every peer registers it the same way).
local cede_registered = false
local function register_cede()
  if cede_registered then return end
  local wars = loaded("scripts.wars")
  if wars and wars.on_cede then
    wars.on_cede(function(city_id, to, from) return capture.flip(city_id, to, "ceded by treaty") end)
    cede_registered = true
  end
end
register_cede()

events.on_nth_tick(CP.period, function()
  register_cede()
  capture.step(CP.period)
end)

---------------------------------------------------------------------------
-- Flip
---------------------------------------------------------------------------
-- The city of the old owner with most people (storage.population / scripts/population.lua), then tier, then land.
local function largest_city(force, except_id)
  local pop_mod = loaded("scripts.population")
  local best, bk
  for _, c in ipairs(cities.for_force(force)) do
    if c.id ~= except_id then
      local pop = 0
      if pop_mod and pop_mod.of then
        local ok, p = pcall(pop_mod.of, c.id)
        pop = ok and type(p) == "table" and p.pop or 0
      elseif storage.population and type(storage.population[c.id]) == "table" then
        pop = storage.population[c.id].pop or 0
      end
      local key = {pop, c.tier or 1, territory.city_cells(c.id), -c.id}
      local better = not bk
      if bk then
        for i = 1, 4 do
          if key[i] ~= bk[i] then
            better = key[i] > bk[i]
            break
          end
        end
      end
      if better then best, bk = c, key end
    end
  end
  return best
end
capture.largest_city = largest_city

-- Hidden parts of a centre: CC core power and pole, hub power and pole, the city power.
local function center_parts(city, rec)
  local list = {}
  if city.power and city.power.valid then list[#list + 1] = city.power end
  if rec and rec.kind == "cc" then
    local parts = buildings.core_parts(rec)
    for _, p in pairs(parts) do
      if p.valid then list[#list + 1] = p end
    end
  end
  local L = storage.logistics
  local pol = L and L.hubs and L.hubs[city.center]
  for _, key in ipairs({"power", "pole"}) do
    local p = pol and pol.parts and pol.parts[key]
    if p and p.valid then list[#list + 1] = p end
  end
  return list
end

--- Capture city `city_id` for `force_name` (contest, treaty or test). The centre, the city record and the land flip
--- now; a job flips the rest in slices. Returns the job id, or nil when nothing changed.
function capture.flip(city_id, force_name, why)
  local city = cities.get(city_id)
  if not (city and city.entity and city.entity.valid) or city.force == force_name then return nil end
  local s = S()
  for id, j in pairs(s.jobs) do
    if j.city == city_id then return id end
  end
  local old = city.force
  local center = city.entity
  local surface = center.surface
  local box = territory.city_box(city_id)
  local new_capital = largest_city(old, city_id)
  local cc_rec = buildings.get(center.unit_number)
  local parts = center_parts(city, cc_rec)
  buildings.set_force(center, force_name)
  for _, p in ipairs(parts) do p.force = force_name end
  center.health = center.max_health * CP.restart_health
  cities.change_owner(city_id, force_name, {new_capital = new_capital and new_capital.id or nil})
  local g = garrison_mod()
  if g and g.on_captured then g.on_captured(city_id, old, force_name) end
  local c = s.cities[city_id]
  if c then clear_label(c) end
  s.cities[city_id] = nil
  local id = s.next_job
  s.next_job = id + 1
  local p = city.position
  box = box or {x0 = p.x - city.radius, y0 = p.y - city.radius, x1 = p.x + city.radius, y1 = p.y + city.radius}
  local pop_mod = loaded("scripts.population")
  local people_unrest = pop_mod ~= nil and pop_mod.set_unrest ~= nil
  s.jobs[id] = {id = id, city = city_id, from = old, to = force_name, why = why or "-", surface = surface.index,
                box = box, phase = "collect", i = 1, started = game.tick, flipped = 1 + #parts, ghosts = 0,
                kept = 0, unrest = {}, slices = 0, sweeps = 0, capital = city.capital == true,
                people_unrest = people_unrest or nil}
  if people_unrest then
    pcall(pop_mod.set_unrest, city_id, CP.unrest_ticks)
    local lab = loaded("scripts.labor") -- staff the city at 0 % now, not at its next staffing pass
    if lab and lab.step_city then pcall(lab.step_city, city_id) end
  end
  s.stats.captures = s.stats.captures + 1
  util.log("capture: city %d (%s) captured by %s from %s (%s): centre flipped, land box (%d, %d)-(%d, %d), "
    .. "job %d starts", city_id, util.pos_str(p), force_name, old, why or "-", box.x0, box.y0, box.x1, box.y1, id)
  return id
end

local function collect(job)
  local surface = game.surfaces[job.surface]
  local b = job.box
  local list = surface and surface.find_entities_filtered({area = {{b.x0, b.y0}, {b.x1, b.y1}}, force = job.from})
    or {}
  local out = {}
  for _, e in ipairs(list) do
    if e.valid and not capture.KEEP_TYPES[e.type] and not capture.SKIP_NAMES[e.name]
       and territory.city_at(e.position) == job.city then
      out[#out + 1] = e
    end
  end
  return out
end

local function flip_one(job, e)
  local t = e.type
  if capture.DESTROY_TYPES[t] then
    e.destroy()
    job.ghosts = job.ghosts + 1
    return
  end
  local rec = buildings.set_force(e, job.to)
  job.flipped = job.flipped + 1
  -- with scripts/population.lua the unrest is its (population.set_unrest: no worker works); this is the fallback
  if rec and not job.people_unrest and capture.UNREST_KINDS[rec.kind] and not e.disabled_by_script then
    e.disabled_by_script = true
    job.unrest[#job.unrest + 1] = e
  end
end

local function eliminate_if_empty(force, by)
  if #cities.for_force(force) > 0 then return end
  local m = storage.match
  if not (m and m.phase == "running" and match.is_participant(force)) then return end
  local killed, razed = 0, 0
  local list = {}
  for un, rec in units.for_force(force) do list[#list + 1] = rec.entity end
  for _, e in ipairs(list) do
    if e.valid then
      e.die(by)
      killed = killed + 1
    end
  end
  local blist = {}
  for _, rec in buildings.for_force(force) do
    if rec.kind == "cc" or rec.kind == "barracks" or rec.kind == "factory" then blist[#blist + 1] = rec.entity end
  end
  for _, e in ipairs(blist) do
    if e.valid then
      e.die(by)
      razed = razed + 1
    end
  end
  util.log("capture: %s has no city left: eliminated (%d units and %d producers died, match.lua decides at its next "
    .. "check)", force, killed, razed)
  supply.alert(force, "city-lost", "rts-war.alert-nation-eliminated", {}, nil)
end

-- The old owner's AI forgets the buildings it lost (they stand on enemy land now and cannot be rebuilt there).
local function ai_forget(force)
  local ai = loaded("scripts.ai.init")
  local C = ai and ai.get and ai.get(force)
  if not (C and C.plan) then return 0 end
  local n = 0
  for _, e in pairs(C.plan) do
    if e.status == "built" and e.entity and e.entity.valid and e.entity.force.name ~= force then
      e.status, e.entity = "bad", nil
      n = n + 1
    end
  end
  return n
end

local function finish(job)
  local s = S()
  local city = cities.get(job.city)
  -- population keeps pop_keep
  local pop_txt = "no population data"
  local pop_mod = loaded("scripts.population")
  if pop_mod and pop_mod.of and pop_mod.remove then
    local ok, p = pcall(pop_mod.of, job.city)
    local pop = ok and type(p) == "table" and p.pop or 0
    local lose = math.floor(pop * (1 - CP.pop_keep) + 0.5)
    if lose > 0 then pcall(pop_mod.remove, job.city, lose, "capture") end
    pop_txt = string.format("population %d -> %d", pop, pop - lose)
  elseif storage.population and type(storage.population[job.city]) == "table"
         and type(storage.population[job.city].pop) == "number" then
    local P = storage.population[job.city]
    local before = P.pop
    P.pop = math.floor(before * CP.pop_keep + 0.5)
    pop_txt = string.format("population %d -> %d", before, P.pop)
  end
  s.unrest[job.city] = {until_tick = game.tick + CP.unrest_ticks, entities = job.unrest, from = job.from,
                        to = job.to}
  if job.people_unrest then -- the flipped buildings are staffed at 0 % now (scripts/labor.lua)
    local lab = loaded("scripts.labor")
    if lab and lab.step_city then pcall(lab.step_city, job.city) end
  end
  local forgot = ai_forget(job.from)
  local name = city and cities.display_name(city) or {"rts.city-none"}
  local pos = city and city.position
  util.log("capture: city %d %s -> %s done in %d ticks (%d slices, %d sweeps): %d entities flipped, %d ghosts and "
    .. "proxies destroyed, %s for %d s, %s, %d AI plan entries dropped", job.city, job.from, job.to,
    game.tick - job.started, job.slices, job.sweeps, job.flipped, job.ghosts,
    job.people_unrest and "unrest through population.set_unrest" or string.format("%d producers in unrest", #job.unrest),
    CP.unrest_ticks / 60, pop_txt, forgot)
  supply.alert(job.to, "city-captured", "rts-war.alert-city-captured", {name}, pos)
  supply.alert(job.from, "city-lost", "rts-war.alert-city-captured-by", {name, label_of(job.to)}, pos)
  s.stats.flipped = s.stats.flipped + job.flipped
  s.stats.ghosts = s.stats.ghosts + job.ghosts
  s.stats.max_slice_ticks = math.max(s.stats.max_slice_ticks, job.slices)
  s.last = {city = job.city, from = job.from, to = job.to, ticks = game.tick - job.started, slices = job.slices,
            flipped = job.flipped, ghosts = job.ghosts, unrest = #job.unrest, capital = job.capital, tick = game.tick}
  events.emit(capture.SIGNAL, {city_id = job.city, from = job.from, to = job.to})
  eliminate_if_empty(job.from, job.to)
end

capture.MAX_SWEEPS = 3 -- re-reads of the land after the slices (something the slices missed); then the job ends

-- One tick of a flip job: "collect" reads the old owner's entities on the land and flips the first slice; "slices"
-- flips SLICE per tick; "sweep" reads the land again: nothing left ends the job, else its slices follow.
local function job_tick(job)
  local s = S()
  if job.phase == "collect" or job.phase == "sweep" then
    local sweep = job.phase == "sweep"
    job.list, job.i = collect(job), 1
    if sweep then
      job.sweeps = job.sweeps + 1
      if #job.list == 0 or job.sweeps > capture.MAX_SWEEPS then
        if #job.list > 0 then
          util.log("capture: job %d (city %d): %d entities of %s still on the land after %d sweeps", job.id, job.city,
            #job.list, job.from, job.sweeps - 1)
        end
        job.list = nil
        s.jobs[job.id] = nil
        finish(job)
        return
      end
    end
    job.phase = "slices"
    util.log("capture: job %d (city %d): %d entities of %s on the land%s", job.id, job.city, #job.list, job.from,
      sweep and " after the slices" or "")
  end
  local list = job.list
  local n = 0
  local limit = capture.SLICE
  while n < limit and job.i <= #list do
    local e = list[job.i]
    job.i = job.i + 1
    if e.valid and e.force.name == job.from then
      flip_one(job, e)
      n = n + 1
    end
  end
  job.slices = job.slices + 1
  if job.i > #list then
    job.list = nil
    job.phase = "sweep"
  end
end

events.on(defines.events.on_tick, function()
  local s = storage.capture
  if not (s and next(s.jobs)) then return end
  local ids = {}
  for id in pairs(s.jobs) do ids[#ids + 1] = id end
  table.sort(ids)
  local job = s.jobs[ids[1]] -- one job at a time, oldest first
  job_tick(job)
end)

-- Unrest ends: the producers this module stopped run again (signal "rts_city_unrest_ended" {city_id} for modules
-- that keep their own disabled state, e.g. labor).
events.on_nth_tick(60, function()
  local s = storage.capture
  if not (s and next(s.unrest)) then return end
  local ids = {}
  for id, u in pairs(s.unrest) do
    if game.tick >= u.until_tick then ids[#ids + 1] = id end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local u = s.unrest[id]
    s.unrest[id] = nil
    local n = 0
    for _, e in ipairs(u.entities) do
      if e.valid and e.disabled_by_script then
        e.disabled_by_script = false
        n = n + 1
      end
    end
    util.log("capture: unrest in city %d over: %d producers run again", id, n)
    events.emit("rts_city_unrest_ended", {city_id = id})
  end
end)

---------------------------------------------------------------------------
-- Force changes of buildings (buildings.set_force): territory, logistics, haulers
---------------------------------------------------------------------------
buildings.on_force_changed(function(un, rec, old)
  territory.set_source_force(un, rec.force)
  local L = storage.logistics
  local pol = L and L.hubs and L.hubs[un]
  if pol then
    pol.force = rec.force
    if L.net_cache then
      L.net_cache[old] = nil
      L.net_cache[rec.force] = nil
    end
    -- haulers of the old owner bound to this hub serve their own hubs again
    local list = {}
    for hun, h in logistics.haulers_of(old) do
      if h.home == un or h.pickup == un or h.dropoff == un then list[#list + 1] = hun end
    end
    table.sort(list)
    for _, hun in ipairs(list) do
      local h = logistics.hauler(hun)
      if h then
        if h.pickup == un then h.pickup = nil end
        if h.dropoff == un then h.dropoff = nil end
        if h.home == un then h.home = nil end
        if h.mode == "manual" and not (h.pickup and h.dropoff) then h.mode = "auto" end
        logistics.return_home(hun)
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------
match.on_teardown(function()
  local s = storage.capture
  for _, c in pairs(s and s.cities or {}) do clear_label(c) end
  storage.capture = nil
  S()
end)

--- One line for logs: "capture: 2 cities subdued, 1 job, 3 captures (3,000 entities flipped)".
function capture.describe()
  local s = S()
  local nsub = 0
  for _, c in pairs(s.cities) do
    if c.subdued then nsub = nsub + 1 end
  end
  return string.format("capture: %d cities subdued, %d jobs, %d captures (%d entities flipped, %d ghosts)", nsub,
    table_size(s.jobs), s.stats.captures, s.stats.flipped, s.stats.ghosts)
end

return capture
