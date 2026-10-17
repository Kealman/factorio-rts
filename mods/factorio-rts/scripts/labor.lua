-- Phase 5 M2 people: labor (docs/PHASE5-M2.md section 3 "population.lua / labor.lua", D2, D3; study
-- docs/research/scale/deep-economy.md 5.2-5.5 and 8.2; notes docs/qa/phase5-people-notes.md). Nation mode only.
--
-- Jobs. Every building with jobs (balance.nation.people.jobs: extractor 4, smelter 4, factory 12, barracks 12, lab 8,
-- farm 6, bakery 6, fishing hut 4, district 16, steam plant 4, oil well 4, refinery and chemical plant 8; everything
-- else 0) draws its workers from the city whose land it stands on (population.lua's index, territory.city_at).
--
-- Staffing. Every staffing_period (5 s) per city, staggered by city id: the city's workforce (population.workforce)
-- fills its buildings in order: pinned buildings first (the order they were pinned in), then by the nation's labor
-- priorities (families: military, power, food, extraction, metallurgy, chemistry, electronics, research, services by
-- default), then by unit number. A building's step is the share it got, rounded down to 1 / steps (20 %), and it uses
-- exactly step x jobs workers, so the rest flows on to the next building. A step change (only then) writes:
--   1     no labor module, enabled
--   0.8 .. 0.2  the hidden module rts-labor-80 .. rts-labor-20 in its single labor slot (speed and consumption -20 ..
--               -80 %; the engine's floor is -80 %, so 20 % is the lowest step a module can make)
--   0     disabled_by_script and the custom status "No workers"
-- A machine without a module slot (the steam plant) runs at any step above 0. Signal "rts_staffing_changed"
-- {unit_number, step}. Buildings on land without a live city keep full staffing (they are re-resolved after territory
-- and city changes).
--
-- Recruits (D2). A barracks' kit drafts supply-cost residents of the barracks' city when it becomes a unit
-- (production.recruit_gate refuses with reason "recruits" first: "no recruits"). Recruits available = the unemployed
-- workers + draft share x the employed ones (population.set_draft; AI by doctrine), never taking the city below
-- min_pop residents. A dead unit's recruits are gone; labor.release / labor.disband return them to their home city.
--
-- API (contract):
--   labor.jobs(entity_name) -> n
--   labor.staffing(entity) -> 0 | 0.2 | 0.4 | 0.6 | 0.8 | 1          (districts.staffing_factor, production.lua)
--   labor.priorities(force) -> {family, ...}; labor.set_priorities(force, list); labor.pin(entity, on)
--   labor.recruit(city_id, n) -> ok, reason ("no recruits" | "no city")
--   labor.release(city_id, n)
-- More: labor.family(name), labor.recruits(city_id), labor.city_stats(city_id) -> {workforce, jobs, employed, free,
-- recruits, unfilled, buildings, stopped, partial, order}, labor.step_city(city_id), labor.home_of(unit_number),
-- labor.disband(unit_number) -> ok, labor.pinned(entity), labor.move_priority(force, family, -1 | 1),
-- labor.set_penalty(force, steps, why) (unpaid wages), labor.describe(city_id).
--
-- Owns storage.labor = {[force] = {priorities = {family...}, pins = {[unit_number] = order}, next_pin},
--   steps = {[unit_number] = step}, stats = {[city_id] = {...}}, soldiers = {[unit_number] = {city, n}},
--   changes = n (module and disable writes, for the stress fixture)}. Cleared by match teardown.
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local units = require("scripts.units")
local match = require("scripts.match")
local supply = require("scripts.supply")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local population = require("scripts.population")
local balance = require("balance")

local PB = balance.nation.people

local labor = {}
population.labor = labor
cities.labor = labor -- the city panel (scripts/citygui.lua loads before this module)

labor.SIGNAL = "rts_staffing_changed"
labor.FAMILIES = PB.priorities
labor.STEPS = PB.steps
labor.SLOTS = PB.staffing_period / 15  -- the staffing pass runs on_nth_tick(15) in this many slots
labor.MODULES = {}                      -- [step] = module name (0 < step < 1)
for i = 1, PB.steps - 1 do labor.MODULES[i / PB.steps] = "rts-labor-" .. math.floor(i * 100 / PB.steps + 0.5) end
labor.MODULE_NAMES = {}
for _, name in pairs(labor.MODULES) do labor.MODULE_NAMES[name] = true end
labor.NO_WORKERS = {diode = defines.entity_status_diode.red, label = {"rts-people.status-no-workers"}}
labor.job_factor = nil -- Phase 5 M3 age3: fn(entity) -> share of its jobs (automation kits, scripts/age3.lua)

local FAMILY_SET = {}
for _, f in ipairs(labor.FAMILIES) do FAMILY_SET[f] = true end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function L()
  local s = storage.labor
  if not s then
    s = {}
    storage.labor = s
  end
  s.steps = s.steps or {}
  s.stats = s.stats or {}
  s.soldiers = s.soldiers or {}
  s.changes = s.changes or 0
  return s
end

local function F(force_name)
  local s = L()
  local f = s[force_name]
  if not f then
    f = {priorities = {}, pins = {}, next_pin = 1}
    for i, fam in ipairs(labor.FAMILIES) do f.priorities[i] = fam end
    s[force_name] = f
  end
  return f
end

function labor.init()
  L()
end

---------------------------------------------------------------------------
-- Jobs and families
---------------------------------------------------------------------------
function labor.jobs(entity_name)
  return population.jobs_of(entity_name)
end

--- Labor family of a building name (balance.nation.people.families), "services" when none is listed.
function labor.family(entity_name, kind)
  local fams = PB.families
  return fams.name[entity_name] or fams.kind[kind or buildings.KIND_BY_NAME[entity_name] or ""] or "services"
end

--- The staffing step of a building (1 when it has no record: full staff, Skirmish, no jobs).
function labor.staffing(entity)
  local s = storage.labor
  if not (s and entity and entity.valid) then return 1 end
  local un = entity.unit_number
  return (un and s.steps[un]) or 1
end

--- The nation's labor priorities, a copy (families, first = staffed first).
function labor.priorities(force_name)
  local out = {}
  for i, fam in ipairs(F(force_name).priorities) do out[i] = fam end
  return out
end

--- Set the labor priorities: a list of families (unknown ones are dropped, missing ones appended in default order).
function labor.set_priorities(force_name, list)
  local f = F(force_name)
  local seen, new = {}, {}
  for _, fam in ipairs(list or {}) do
    if FAMILY_SET[fam] and not seen[fam] then
      seen[fam] = true
      new[#new + 1] = fam
    end
  end
  for _, fam in ipairs(labor.FAMILIES) do
    if not seen[fam] then new[#new + 1] = fam end
  end
  f.priorities = new
  util.log("people: labor priorities of %s: %s", force_name, table.concat(new, " > "))
  return true
end

--- A penalty in staffing steps for every building of a force (m2-treasury: unpaid wages -1 step); 0 or nil clears.
--- The allocation is unchanged; each building runs `steps` steps below what it got (never below 0).
function labor.set_penalty(force_name, steps, why)
  local f = F(force_name)
  steps = math.max(0, math.floor(tonumber(steps) or 0))
  if (f.penalty or 0) == steps then return true end
  f.penalty = steps > 0 and steps or nil
  util.log("people: %s staffing penalty %d step(s) (%s)", force_name, steps, why or "-")
  return true
end

--- Move one family up (-1) or down (+1) in a force's priorities.
function labor.move_priority(force_name, family, dir)
  local list = labor.priorities(force_name)
  for i, fam in ipairs(list) do
    if fam == family then
      local j = i + dir
      if j >= 1 and j <= #list then
        list[i], list[j] = list[j], list[i]
        return labor.set_priorities(force_name, list)
      end
      return false
    end
  end
  return false
end

--- Pin (on) or unpin a building: pinned buildings are staffed before every family.
function labor.pin(entity, on)
  if not (entity and entity.valid and entity.unit_number) then return false end
  local f = F(entity.force.name)
  local un = entity.unit_number
  if on then
    if not f.pins[un] then
      f.pins[un] = f.next_pin
      f.next_pin = f.next_pin + 1
    end
  else
    f.pins[un] = nil
  end
  util.log("people: %s #%d %s", entity.name, un, on and "pinned" or "unpinned")
  return true
end

function labor.pinned(entity)
  if not (entity and entity.valid and entity.unit_number) then return false end
  local s = storage.labor
  local f = s and s[entity.force.name]
  return f ~= nil and f.pins[entity.unit_number] ~= nil
end

---------------------------------------------------------------------------
-- Applying a step
---------------------------------------------------------------------------
local function set_module(e, name)
  local inv = e.get_module_inventory()
  if not inv then return false end
  local cur
  for i = 1, #inv do
    local stack = inv[i]
    -- Phase 5 M3 age3: only labor modules are ours (districts hold automation kits in their other slots)
    if stack.valid_for_read and labor.MODULE_NAMES[stack.name] then
      if stack.name == name and not cur then cur = true else stack.clear() end
    end
  end
  if name and not cur then
    if inv.insert({name = name, count = 1}) < 1 then return false end
  end
  return true
end

local function apply(un, rec, step)
  local s = L()
  local old = s.steps[un] or 1
  if old == step then return false end
  local e = rec.entity
  if step <= 0 then
    if not e.disabled_by_script then e.disabled_by_script = true end
    e.custom_status = labor.NO_WORKERS
    set_module(e, nil)
  else
    if e.disabled_by_script then e.disabled_by_script = false end
    if old <= 0 then e.custom_status = nil end
    set_module(e, step < 1 and labor.MODULES[step] or nil)
  end
  if step >= 1 then s.steps[un] = nil else s.steps[un] = step end
  s.changes = s.changes + 1
  events.emit(labor.SIGNAL, {unit_number = un, step = step})
  return true
end

--- Put a building back to full staffing (its city is gone, the match ends, the building leaves the index).
local function restore(un, rec)
  local s = storage.labor
  if not (s and s.steps[un]) then return end
  if rec and rec.entity.valid then
    apply(un, rec, 1)
  else
    s.steps[un] = nil
  end
end

---------------------------------------------------------------------------
-- The staffing pass
---------------------------------------------------------------------------
local function rank_table(force_name)
  local ranks = {}
  for i, fam in ipairs(F(force_name).priorities) do ranks[fam] = i end
  return ranks
end

--- Recompute one city's staffing. Returns its stats.
function labor.step_city(city_id)
  local c = cities.get(city_id)
  if not c then return nil end
  local P = population.get(city_id)
  if not P then return nil end
  local s = L()
  local members = population.members(city_id)
  local f = F(c.force)
  local ranks = rank_table(c.force)
  local list = {}
  local moved = nil
  for un in pairs(members) do
    local rec = storage.buildings[un]
    if rec and rec.entity.valid then
      if population.city_at(rec.position) ~= city_id then
        moved = moved or {}
        moved[#moved + 1] = un
      else
        local jobs = population.jobs_of(rec.entity.name, rec.kind)
        -- Phase 5 M3 age3: automation kits cut a building's jobs (scripts/age3.lua sets labor.job_factor)
        if jobs > 0 and labor.job_factor then jobs = jobs * labor.job_factor(rec.entity) end
        if jobs > 0 then
          local pin = f.pins[un]
          list[#list + 1] = {un = un, rec = rec, jobs = jobs, pin = pin or math.huge,
                             rank = ranks[labor.family(rec.entity.name, rec.kind)] or #labor.FAMILIES + 1}
        end
      end
    end
  end
  if moved then
    for _, un in ipairs(moved) do
      local id = population.resolve(un)
      if not id then restore(un, storage.buildings[un]) end
    end
  end
  table.sort(list, function(a, b)
    if a.pin ~= b.pin then return a.pin < b.pin end
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.un < b.un
  end)
  local workforce = population.workforce(city_id)
  local left = workforce
  local jobs, stopped, partial = 0, 0, 0
  local n = labor.STEPS
  local penalty = f.penalty or 0
  local order = {}
  for i = 1, #list do
    local b = list[i]
    order[i] = b.un
    jobs = jobs + b.jobs
    local share = left / b.jobs
    local k = math.floor(share * n + 1e-6)
    if k > n then k = n end
    local step = k / n
    left = left - step * b.jobs
    if penalty > 0 then step = math.max(0, k - penalty) / n end
    if step <= 0 then stopped = stopped + 1 elseif step < 1 then partial = partial + 1 end
    apply(b.un, b.rec, step)
  end
  if left < 0 then left = 0 end
  local employed = workforce - left
  local st = s.stats[city_id] or {}
  s.stats[city_id] = st
  st.workforce, st.jobs, st.employed, st.free = workforce, jobs, employed, left
  st.unfilled = math.max(0, jobs - employed)
  st.buildings, st.stopped, st.partial = #list, stopped, partial
  st.order = order -- unit numbers in staffing order (tests, the panel)
  st.tick = game.tick
  st.taken = 0
  st.recruits = labor.recruits(city_id, st)
  return st
end

events.on_nth_tick(15, function(e)
  local all = storage.population
  if not (all and next(all)) then return end
  local slot = (e.tick / 15) % labor.SLOTS
  for id in pairs(all) do
    if id % labor.SLOTS == slot then labor.step_city(id) end
  end
end)

--- Stats of a city's last staffing pass (see the header), computed now when it has none.
function labor.city_stats(city_id)
  local s = storage.labor
  local st = s and s.stats[city_id]
  if st then return st end
  if not cities.get(city_id) then return {} end
  return labor.step_city(city_id) or {}
end

-- A building leaves the registry: forget its step (its entity is gone or no longer ours to manage)
buildings.on_removed(function(un)
  local s = storage.labor
  if not s then return end
  s.steps[un] = nil
  for force, f in pairs(s) do
    if type(f) == "table" and f.pins and f.pins[un] then f.pins[un] = nil end
  end
end)

-- A lost city: its buildings (population.lua moved them to the loose set) run at full staff until they belong to
-- another city
events.on_signal("rts_city_lost", function(d)
  local s = storage.labor
  if not s then return end
  s.stats[d.city] = nil
  local people = storage.people
  for un in pairs(people and people.loose or {}) do
    if s.steps[un] then restore(un, storage.buildings[un]) end
  end
end)

---------------------------------------------------------------------------
-- Recruits
---------------------------------------------------------------------------
--- Recruits a city can give now: unemployed + draft x employed, at most residents - min_pop.
function labor.recruits(city_id, st)
  local P = population.get(city_id)
  if not P then return 0 end
  st = st or labor.city_stats(city_id)
  local n = (st.free or 0) + P.draft * (st.employed or 0) - (st.taken or 0)
  n = math.min(n, P.pop - PB.min_pop)
  return math.max(0, math.floor(n + 1e-6))
end

--- Draft n recruits from a city (they leave its residents). Returns ok, reason.
function labor.recruit(city_id, n)
  if not (city_id and cities.get(city_id)) then return false, "no city" end
  n = n or 1
  if n <= 0 then return true end
  local st = labor.city_stats(city_id)
  if labor.recruits(city_id, st) < n then return false, "no recruits" end
  population.remove(city_id, n, "draft")
  local P = population.get(city_id)
  P.drafted = P.drafted + n
  st.taken = (st.taken or 0) + n -- until the next staffing pass recounts
  return true
end

--- Return n workers to a city (a disbanded unit). Returns the number that found housing.
function labor.release(city_id, n)
  if not (city_id and cities.get(city_id)) then return 0 end
  return population.add(city_id, n, "released")
end

--- Home city and recruits of a unit: city_id, n (nil when it was not drafted).
function labor.home_of(unit_number)
  local s = storage.labor
  local r = s and s.soldiers[unit_number]
  if not r then return nil end
  return r.city, r.n
end

--- Disband an own unit: its recruits return to their home city (or the nearest city of its force), the unit goes.
function labor.disband(unit_number)
  local urec = units.get(unit_number)
  if not urec then return false end
  local s = L()
  local r = s.soldiers[unit_number]
  local back = 0
  if r then
    local city = r.city
    if not cities.get(city) then
      local best, bd
      for _, c in ipairs(cities.for_force(urec.force)) do
        local d = util.distance(c.position, urec.entity.position)
        if not bd or d < bd then best, bd = c.id, d end
      end
      city = best
    end
    if city then back = labor.release(city, r.n) end
    s.soldiers[unit_number] = nil
  end
  util.log("people: unit #%d (%s) disbanded, %d recruits back", unit_number, urec.entity.name, math.floor(back + 0.5))
  urec.entity.destroy({raise_destroy = true})
  return true
end

local function recruit_gate(rec, kit, spawn)
  if not territory.nation() then return true end
  local cost = supply.cost(spawn.unit)
  if cost <= 0 then return true end
  local city = population.city_of_building(rec.entity.unit_number) or population.city_at(rec.position)
  if not city then return true end -- no city (a loose building): the old rules
  local have = labor.recruits(city)
  if have >= cost then return true end
  local old = rec.surcharge_block
  if not (old and old.reason == "recruits") then
    util.log("people: barracks #%d (%s) holds %s: no recruits in city %d (%d of %d)", rec.entity.unit_number, rec.force,
      kit, city, have, cost)
  end
  return false, {reason = "recruits", unit = spawn.unit, kit = kit, city = city, have = have, need = cost,
                 tick = game.tick}
end
production.recruit_gate = recruit_gate
production.staffing = labor.staffing

production.on_spawned(function(unit, rec, kit)
  if not territory.nation() then return end
  local cost = supply.cost(unit.name)
  if cost <= 0 then return end
  local city = population.city_of_building(rec.entity.unit_number) or population.city_at(rec.position)
  if not city then return end
  local ok = labor.recruit(city, cost)
  if ok then L().soldiers[unit.unit_number] = {city = city, n = cost} end
end)

units.on_removed(function(un)
  local s = storage.labor
  if s and s.soldiers[un] then s.soldiers[un] = nil end
end)

---------------------------------------------------------------------------
-- Labor modules must not leave their machines
---------------------------------------------------------------------------
-- Demolish (buildings.demolish) and mining collect a machine's module inventory: drop the labor module first.
local raw_demolish = buildings.demolish
function buildings.demolish(entity, opts)
  if entity and entity.valid and entity.type ~= "entity-ghost" and storage.labor and entity.unit_number
     and storage.labor.steps[entity.unit_number] then
    set_module(entity, nil)
  end
  return raw_demolish(entity, opts)
end

local function strip_buffer(e)
  local buffer = e.buffer
  if not (buffer and buffer.valid) then return end
  for name in pairs(labor.MODULE_NAMES) do
    local n = buffer.get_item_count(name)
    if n > 0 then buffer.remove({name = name, count = n}) end
  end
end
events.on(defines.events.on_player_mined_entity, strip_buffer)
events.on(defines.events.on_robot_mined_entity, strip_buffer)

---------------------------------------------------------------------------
-- Debug
---------------------------------------------------------------------------
function labor.describe(city_id)
  local st = labor.city_stats(city_id)
  return string.format("city %s: workforce %d, jobs %d, employed %.1f, free %.1f, recruits %d, buildings %d "
    .. "(%d partial, %d stopped)", tostring(city_id), st.workforce or 0, st.jobs or 0, st.employed or 0, st.free or 0,
    st.recruits or 0, st.buildings or 0, st.partial or 0, st.stopped or 0)
end

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------
match.on_teardown(function()
  local s = storage.labor
  if s then
    for un in pairs(s.steps) do
      local rec = storage.buildings and storage.buildings[un]
      if rec and rec.entity.valid then
        rec.entity.disabled_by_script = false
        rec.entity.custom_status = nil
        set_module(rec.entity, nil)
      end
    end
  end
  storage.labor = nil
  L()
end)

return labor
