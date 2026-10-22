-- Phase 5 M2 people: population (docs/PHASE5-M2.md section 3 "population.lua / labor.lua", D2; study
-- docs/research/scale/territory-cities.md 3.2-3.5 and deep-economy.md 5.1; notes docs/qa/phase5-people-notes.md).
-- Nation mode only: in Skirmish no city exists, so nothing here runs.
--
-- Residents are a script number per city (D2). Every city (scripts/cities.lua) gets a record when it is founded: the
-- capital starts with balance.nation.people.start.capital residents, a city-state with start.city_state, a new city
-- with the settlers a founding moves out of the source city (population.settle: the nearest own city that can spare
-- them).
--
-- Housing: the capital's centre houses housing.capital, a City Center housing.city; houses (rts-house 20, rts-apartment
-- 80) add theirs on the land of the city they stand on (territory.city_at). Apartments need Age II (their recipe is an
-- Age II recipe, ages.AGE2_RECIPES) and town tier (build check). Farms are limited per city by farm_slots[tier]; a
-- fishing hut needs water within fishing_water tiles (build checks, like territory.lua's).
--
-- Needs are keep policies on the city's market network (the City Center's or the capital CC's hub policy: rations 50,
-- goods 20 by default). Every needs_period (60 s) per city: 1 ration per 10 residents (from village), 1 goods per 25
-- (from town) are removed from that network (fractions carried over); met = removed / due. The removals are recorded as
-- consumption in the force's item statistics (LuaFlowStatistics.on_flow) and in the city ledger (districts.record).
--
-- Growth (every growth_period = 10 s per city, staggered by city id), per minute:
--   + growth x housing x mood       while every current need is met at grow_at (90 %) or more, housing has room and
--                                   (town tier and above) the city has power; never beyond the housing
--   - starve x residents            below hold_at (50 %) rations
--   - dark x residents              without power at town tier and above
--   - homeless x (residents - housing) when residents exceed the housing (houses lost)
-- mood = happiness / mood_base clamped to [0, mood_max]. Happiness 0..100 = base + rations + goods + power + crowding
-- + external moods (population.set_mood: treasury taxes and debt, capture unrest). It drives growth and taxes only.
-- Below hold_at rations only starving_work of the workforce works (labor.lua staffs the rest out: the lowest-priority
-- buildings stop). Unrest (population.set_unrest, a capture): no worker works until it ends.
--
-- Tiers by population (replaces M1's buildings + delivered rule; cities.tier_rule = "population"): village from 20,
-- town from 100, city from 400. A higher tier is taken at the next growth pass; a city drops a tier only after
-- down_ticks (2 min) below down_share (80 %) of its tier's threshold. cities.set_tier does the rest (land radius,
-- supply, alert, "rts_city_tier"). Power: a hidden 1 kW consumer (rts-city-demand) under every centre; its buffer below
-- power_ok = no power.
--
-- Index of the buildings that matter here (houses, and every building with jobs, for labor.lua): their city by the land
-- they stand on. Resolved when a building is registered; labor.lua's city pass re-checks its members and moves those
-- whose land changed city; buildings without a city ("loose") are re-resolved after every territory or city signal.
--
-- API (contract):
--   population.of(city_id) -> {pop, housing, workforce, free, happiness, needs = {[item] = {need, met}}, tier_progress,
--                              free_housing, employed, jobs, recruits, growth, power, draft, tier, unrest}
--   population.add(city_id, n, why) / population.remove(city_id, n, why)   (clamped to [0, housing] / [0, pop])
--   population.settle(from_city, to_city, n) -> moved
--   population.needs(city_id) -> {[item] = per_minute}
-- More: population.get(id) (raw record), workforce(id), housing(id), total(force), set_draft(id, share),
-- set_mood(city_id | force, key, delta), set_unrest(id, ticks), members(id), city_of_building(un), jobs_of(name, kind),
-- describe(id). The AI's people rules are scripts/ai/governor.lua's (m2-ai; the first governor here was removed in M3).
-- Signal "rts_city_population" {city_id, pop, tier} after every growth pass that changed the whole-number population.
-- Log lines "[rts] people: ...".
--
-- Owns storage.population = {[city_id] = {id, force, pop, base, housing, needs = {[item] = {need, met, carry, due}},
--   happiness, mood, power, low_since, draft, moods = {[key] = delta}, unrest_until, born, lost, drafted, settled,
--   growth (per minute, last pass), last_needs, demand (LuaEntity), shown (whole number last emitted)}} and
-- storage.people = {city_of = {[unit_number] = city_id}, members = {[city_id] = {[unit_number] = true}},
--   loose = {[unit_number] = true}, resolve = bool, force_moods = {[force] = {[key] = delta}}, ai = {[force] = {...}}}.
-- Both are cleared by match teardown.
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local match = require("scripts.match")
local supply = require("scripts.supply")
local economy = require("scripts.economy")
local logistics = require("scripts.logistics")
local research = require("scripts.research")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local ages = require("scripts.ages")
local districts = require("scripts.districts")
local balance = require("balance")

local PB = balance.nation.people

local population = {}

population.SIGNAL = "rts_city_population"
population.DEMAND = "rts-city-demand"
population.RATIONS = "rts-rations"
population.GOODS = "rts-goods"
population.HOUSE_KIND = "house"
population.NEUTRAL = "rts-neutral"                  -- city-states: static residents (no needs, no growth)
population.GROWTH_SLOTS = PB.growth_period / 60     -- the growth pass runs on_nth_tick(60) in this many slots
population.RESOLVE_BUDGET = 200                     -- loose buildings resolved per tick
population.labor = nil                              -- scripts/labor.lua sets itself here (free workers, recruits)

-- Registry kinds of the new buildings (prototypes/people.lua)
for name, b in pairs(PB.buildings) do buildings.KIND_BY_NAME[name] = b.kind end
-- Farms, bakeries and fishing huts are fed from and emptied into their logistic network like factories
-- (production.lua's producer kinds; their recipes are fixed, so the auto-recipe pass never touches them)
if production.PRODUCER_KINDS then
  for _, kind in ipairs({"farm", "bakery", "fishing"}) do production.PRODUCER_KINDS[kind] = true end
end
-- Tiers follow the population (cities.check only measures; population.step calls cities.set_tier)
cities.tier_rule = "population"
cities.people = population -- the city panel (scripts/citygui.lua loads before this module)
-- The apartment is an Age II building: ages.lua enables its recipe at Age II, the HUD greys it until then
table.insert(ages.AGE2_RECIPES, "rts-apartment")
research.AGE_LOCKS["rts-apartment"] = "rts-age-2"

local NEEDS = PB.needs

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.people
  if not s then
    s = {}
    storage.people = s
  end
  s.city_of = s.city_of or {}
  s.members = s.members or {}
  s.loose = s.loose or {}
  s.force_moods = s.force_moods or {}
  return s
end

function population.init()
  storage.population = storage.population or {}
  S()
end

function population.active()
  return territory.nation()
end

--- Jobs of a building (balance.nation.people.jobs: entity name first, then registry kind). 0 = no workers.
function population.jobs_of(name, kind)
  local n = PB.jobs.name[name]
  if n == nil then n = PB.jobs.kind[kind or buildings.KIND_BY_NAME[name] or ""] end
  return n or 0
end

local function indexed(rec)
  return rec.kind == population.HOUSE_KIND or population.jobs_of(rec.entity.name, rec.kind) > 0
end

---------------------------------------------------------------------------
-- Index: buildings by city
---------------------------------------------------------------------------
local function unlink(s, un)
  local old = s.city_of[un]
  if old then
    local m = s.members[old]
    if m then m[un] = nil end
    s.city_of[un] = nil
  end
  s.loose[un] = nil
end

local function link(s, un, city_id)
  local old = s.city_of[un]
  if old == city_id then return end
  if old then
    local m = s.members[old]
    if m then m[un] = nil end
  end
  if city_id then
    s.city_of[un] = city_id
    local m = s.members[city_id]
    if not m then
      m = {}
      s.members[city_id] = m
    end
    m[un] = true
    s.loose[un] = nil
  else
    s.city_of[un] = nil
    s.loose[un] = true
  end
end

-- The city whose land a position is on (a live city), or nil.
local function city_at(position)
  local id = territory.city_at(position)
  if id and storage.cities and storage.cities[id] then return id end
  return nil
end
population.city_at = city_at

--- Move a building to the city of its land (or to the loose set). Returns the city id.
function population.resolve(un, rec)
  rec = rec or storage.buildings[un]
  local s = S()
  if not (rec and rec.entity.valid) then
    unlink(s, un)
    return nil
  end
  local id = city_at(rec.position)
  link(s, un, id)
  return id
end

--- {[unit_number] = true} of the indexed buildings on a city's land (read-only).
function population.members(city_id)
  return S().members[city_id] or {}
end

--- City id of an indexed building, or nil.
function population.city_of_building(un)
  return S().city_of[un]
end

buildings.on_added(function(un, rec)
  if not territory.nation() or not indexed(rec) then return end
  population.resolve(un, rec)
end)

buildings.on_removed(function(un)
  local s = storage.people
  if s and (s.city_of[un] or s.loose[un]) then unlink(s, un) end
end)

local function resolve_later()
  local s = storage.people
  if s and next(s.loose) then
    s.resolve = true
    if s.resolve_list then s.resolve_more = true end -- Phase 5 M3 integration: one more pass after this one
  end
end
events.on_signal(territory.SIGNAL, resolve_later)
events.on_signal("rts_city_founded", resolve_later)
events.on_signal("rts_city_tier", resolve_later)

-- Phase 5 M3 integration (perf notes open issue 9): a pass looks at every loose building once, in unit-number order,
-- RESOLVE_BUDGET per tick, from a snapshot of the keys. The walk over pairs(s.loose) began at the first key every tick,
-- so past the budget it never got further (and its order was the insertion order).
events.on(defines.events.on_tick, function()
  local s = storage.people
  if not (s and s.resolve) then return end
  local list = s.resolve_list
  if not list then
    list = {}
    for un in pairs(s.loose) do list[#list + 1] = un end
    table.sort(list)
    s.resolve_list, s.resolve_i, s.resolve_more = list, 0, nil
  end
  local i, n = s.resolve_i, 0
  while i < #list and n < population.RESOLVE_BUDGET do
    i = i + 1
    local un = list[i]
    if s.loose[un] then
      population.resolve(un)
      n = n + 1
    end
  end
  s.resolve_i = i
  if i < #list then return end
  -- every loose building was looked at once (those still without a city stay loose)
  s.resolve_list, s.resolve_i = nil, nil
  if not (s.resolve_more and next(s.loose)) then s.resolve = nil end
  s.resolve_more = nil
end)

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------
local function center_entity(c)
  return c and c.entity and c.entity.valid and c.entity or nil
end

local function market(c)
  local e = center_entity(c)
  local net = e and e.logistic_network
  if net and net.valid then return net end
  return nil
end

local function new_record(c, pop, why)
  local P = {id = c.id, force = c.force, pop = pop, base = c.capital and PB.housing.capital or PB.housing.city,
             housing = 0, needs = {}, happiness = 50, mood = 1, power = true, draft = PB.draft.default, moods = {},
             born = 0, lost = 0, drafted = 0, settled = 0, growth = 0, last_needs = game.tick, shown = math.floor(pop)}
  for _, spec in ipairs(NEEDS) do P.needs[spec.item] = {need = 0, met = 1, carry = 0, due = 0} end
  storage.population[c.id] = P
  util.log("people: city %d of %s registered with %d residents (%s)", c.id, c.force, math.floor(pop), why or "-")
  return P
end

--- The raw record of a city (created on first use for a city that has none: a save from before this module).
function population.get(city_id)
  local all = storage.population
  if not all then
    population.init()
    all = storage.population
  end
  local P = all[city_id]
  if P then return P end
  local c = cities.get(city_id)
  if not c then return nil end
  return new_record(c, c.capital and PB.start.capital or PB.start.city, "late")
end

local function demand_entity(P, c)
  local e = P.demand
  local center = center_entity(c)
  if e and e.valid and center and e.force == center.force then return e end
  if e and e.valid then e.destroy() end
  P.demand = nil
  if not center then return nil end
  P.demand = center.surface.create_entity({name = population.DEMAND, position = center.position, force = center.force})
  if P.demand then P.demand.energy = P.demand.electric_buffer_size or 0 end
  return P.demand
end

--- Housing capacity of a city (its centre plus the houses on its land).
function population.housing(city_id)
  local P = population.get(city_id)
  if not P then return 0 end
  local n = P.base
  local houses = PB.houses
  for un in pairs(population.members(city_id)) do
    local rec = storage.buildings[un]
    if rec and rec.kind == population.HOUSE_KIND and rec.entity.valid then n = n + (houses[rec.entity.name] or 0) end
  end
  P.housing = n
  return n
end

local function tier_of(city_id)
  local c = cities.get(city_id)
  return c and c.tier or 1
end

--- Needs per minute of a city at its tier: {[item] = n}.
function population.needs(city_id)
  local P = population.get(city_id)
  local out = {}
  if not P then return out end
  local tier = tier_of(city_id)
  for _, spec in ipairs(NEEDS) do
    if tier >= spec.from then out[spec.item] = P.pop / spec.per end
  end
  return out
end

local function starving(P)
  local r = P.needs[population.RATIONS]
  return r ~= nil and r.met < PB.hold_at
end

--- Workers of a city: workforce share of the residents, only starving_work of them while it starves, none in unrest.
function population.workforce(city_id)
  local P = population.get(city_id)
  if not P then return 0 end
  if P.unrest_until and game.tick < P.unrest_until then return 0 end
  local w = P.pop * PB.workforce
  if starving(P) then w = w * PB.starving_work end
  return math.floor(w + 1e-6)
end

--- Total residents of a force.
function population.total(force_name)
  local n = 0
  for _, P in pairs(storage.population or {}) do
    if P.force == force_name then n = n + P.pop end
  end
  return n
end

local function emit_pop(P)
  local whole = math.floor(P.pop + 1e-6)
  if whole == P.shown then return end
  P.shown = whole
  events.emit(population.SIGNAL, {city_id = P.id, pop = whole, tier = tier_of(P.id)})
end

--- Add residents (clamped to the housing). Returns the number added.
function population.add(city_id, n, why)
  local P = population.get(city_id)
  if not (P and n and n > 0) then return 0 end
  local room = math.max(0, population.housing(city_id) - P.pop)
  local add = math.min(n, room)
  if add <= 0 then return 0 end
  P.pop = P.pop + add
  util.log("people: city %d +%d (%s): %d residents", city_id, math.floor(add + 0.5), why or "-", math.floor(P.pop))
  emit_pop(P)
  return add
end

--- Remove residents (clamped to the residents). Returns the number removed.
function population.remove(city_id, n, why)
  local P = population.get(city_id)
  if not (P and n and n > 0) then return 0 end
  local take = math.min(n, P.pop)
  if take <= 0 then return 0 end
  P.pop = P.pop - take
  util.log("people: city %d -%d (%s): %d residents", city_id, math.floor(take + 0.5), why or "-", math.floor(P.pop))
  emit_pop(P)
  return take
end

--- Move up to n residents from one city to another (founding). The source keeps min_pop. Returns the number moved.
function population.settle(from_city, to_city, n)
  local A, B = from_city and population.get(from_city), population.get(to_city)
  if not B then return 0 end
  local moved = 0
  if A then
    moved = math.max(0, math.min(n, math.floor(A.pop - PB.min_pop)))
    if moved > 0 then
      A.pop = A.pop - moved
      A.settled = A.settled + moved
      emit_pop(A)
    end
  end
  B.pop = B.pop + moved
  util.log("people: %d settlers from city %s to city %d (%d asked): %s %d, new city %d residents", moved,
    tostring(from_city), to_city, n, tostring(from_city), A and math.floor(A.pop) or -1, math.floor(B.pop))
  emit_pop(B)
  return moved
end

--- Draft share of a city (recruits = unemployed + share x employed; labor.lua). Returns true when set.
function population.set_draft(city_id, share)
  local P = population.get(city_id)
  share = tonumber(share)
  if not (P and share) then return false end
  share = math.max(0, math.min(1, share))
  if P.draft ~= share then
    P.draft = share
    util.log("people: city %d draft %d %%", city_id, math.floor(share * 100 + 0.5))
  end
  return true
end

--- External happiness modifier (key = "tax", "debt", "unrest", ...): a city id or a force name; nil/0 clears.
function population.set_mood(target, key, delta)
  local t
  if type(target) == "number" then
    local P = population.get(target)
    t = P and P.moods
  else
    local s = S()
    s.force_moods[target] = s.force_moods[target] or {}
    t = s.force_moods[target]
  end
  if not t then return false end
  t[key] = (delta ~= nil and delta ~= 0) and delta or nil
  return true
end

--- Unrest (a capture): no worker works for `ticks` (labor.lua staffs every building at 0 %).
function population.set_unrest(city_id, ticks)
  local P = population.get(city_id)
  if not P then return false end
  P.unrest_until = game.tick + math.max(0, ticks or 0)
  util.log("people: city %d unrest for %d s", city_id, math.floor((ticks or 0) / 60))
  return true
end

---------------------------------------------------------------------------
-- Founding and losing
---------------------------------------------------------------------------
-- The own city that gives the settlers: the nearest with residents to spare for all of them, else the largest.
local function settler_source(c)
  local best, bd, big, bp
  for _, other in ipairs(cities.for_force(c.force)) do
    if other.id ~= c.id then
      local P = population.get(other.id)
      if P then
        local spare = P.pop - PB.min_pop
        if spare >= PB.settlers then
          local d = util.distance(other.position, c.position)
          if not bd or d < bd then best, bd = other.id, d end
        end
        if not bp or P.pop > bp then big, bp = other.id, P.pop end
      end
    end
  end
  return best or big
end

local function setup_city(c)
  local P = storage.population[c.id]
  if P then return P end
  if c.capital and #cities.for_force(c.force) <= 1 then
    P = new_record(c, PB.start.capital, "capital")
  elseif c.archetype == "city_state" or c.force == "rts-neutral" then
    P = new_record(c, PB.start.city_state, "city-state")
  else
    P = new_record(c, 0, "founded")
    local from = settler_source(c)
    local moved = population.settle(from, c.id, PB.settlers)
    if moved < PB.min_pop then
      -- no city could spare enough: a village needs its minimum (the charter's settlers)
      P.pop = PB.min_pop
      util.log("people: city %d got only %d settlers, starts with %d", c.id, moved, PB.min_pop)
    end
  end
  P.housing = population.housing(c.id)
  -- needs are keep policies of the city's market (the centre's hub policy)
  for _, spec in ipairs(NEEDS) do
    if logistics.policy(c.center) then logistics.set_policy(c.center, "keep", spec.item, spec.keep) end
  end
  demand_entity(P, c)
  return P
end

events.on_signal("rts_city_founded", function(d)
  if not territory.nation() then return end
  local c = cities.get(d.city)
  if c then setup_city(c) end
end)

events.on_signal("rts_city_lost", function(d)
  local P = storage.population and storage.population[d.city]
  if P then
    if P.demand and P.demand.valid then P.demand.destroy() end
    storage.population[d.city] = nil
    util.log("people: city %d lost with %d residents", d.city, math.floor(P.pop))
  end
  local s = storage.people
  local m = s and s.members[d.city]
  if m then
    for un in pairs(m) do
      s.city_of[un] = nil
      s.loose[un] = true
    end
    s.members[d.city] = nil
    s.resolve = true
    if s.resolve_list then s.resolve_more = true end -- Phase 5 M3 integration: one more pass after this one
  end
end)

---------------------------------------------------------------------------
-- Needs, growth, tiers
---------------------------------------------------------------------------
local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function stats_of(force_name, surface)
  local force = game.forces[force_name]
  if not (force and surface) then return nil end
  return force.get_item_production_statistics(surface)
end

-- Remove one period of needs from the market network. Returns nothing; sets need/met per item.
local function consume(P, c)
  local net = market(c)
  local tier = c.tier
  local minutes = PB.needs_period / 3600
  local center = center_entity(c)
  local stats = center and stats_of(c.force, center.surface)
  for _, spec in ipairs(NEEDS) do
    local N = P.needs[spec.item]
    if tier >= spec.from then
      local want = P.pop / spec.per * minutes + N.carry
      local due = math.floor(want)
      N.carry = want - due
      N.need = P.pop / spec.per
      local got = 0
      if due > 0 and net then got = net.remove_item({name = spec.item, count = due}) end
      if due > 0 then
        N.met = got / due
        N.due = due
      elseif N.need <= 0 then
        N.met = 1
      end
      if got > 0 then
        if stats then stats.on_flow(spec.item, -got) end
        districts.record(c.id, spec.item, got, "used")
      end
    else
      N.need, N.met, N.carry, N.due = 0, 1, 0, 0
    end
  end
  P.last_needs = game.tick
end

local function powered(P, c)
  local e = demand_entity(P, c)
  if not e then return true end
  local size = e.electric_buffer_size or 0
  if size <= 0 then return true end
  return e.energy >= size * PB.power_ok
end

local function moods_sum(P)
  local n = 0
  for _, d in pairs(P.moods) do n = n + d end
  local fm = S().force_moods[P.force]
  if fm then
    for _, d in pairs(fm) do n = n + d end
  end
  return n
end

local function happiness_of(P, tier)
  local H = PB.happiness
  local h = H.base
  local r = P.needs[population.RATIONS]
  if r then h = h + H.rations * clamp((r.met - PB.hold_at) / (1 - PB.hold_at), -1, 1) end
  if tier >= 2 then
    local g = P.needs[population.GOODS]
    if g then h = h + H.goods * clamp((g.met - PB.hold_at) / (1 - PB.hold_at), -1, 1) end
    h = h + (P.power and H.power or -H.power)
  end
  if P.pop > P.housing + 0.5 then h = h + H.crowded end
  if P.unrest_until and game.tick < P.unrest_until then h = h - 25 end
  h = h + moods_sum(P)
  return clamp(h, 0, 100)
end

local function all_met(P, tier)
  for _, spec in ipairs(NEEDS) do
    if tier >= spec.from then
      local N = P.needs[spec.item]
      if N.met < PB.grow_at then return false end
    end
  end
  return true
end

-- The tier a population asks for (1..3).
local function wanted_tier(pop)
  local t = 1
  for i = 2, #PB.tiers do
    if pop >= PB.tiers[i] then t = i end
  end
  return t
end

local function check_tier(P, c)
  local want = wanted_tier(P.pop)
  if want > c.tier then
    P.low_since = nil
    if cities.set_tier then cities.set_tier(c, want, string.format("%d residents", math.floor(P.pop))) end
    return
  end
  if want < c.tier and P.pop < PB.down_share * PB.tiers[c.tier] then
    P.low_since = P.low_since or game.tick
    if game.tick - P.low_since >= PB.down_ticks then
      P.low_since = nil
      if cities.set_tier then
        cities.set_tier(c, c.tier - 1, string.format("%d residents for 2 minutes", math.floor(P.pop)))
      end
    end
  else
    P.low_since = nil
  end
end

--- One growth pass of a city (and its needs when due).
function population.step(city_id)
  local c = cities.get(city_id)
  if not c then return end
  local P = population.get(city_id)
  if not P then return end
  if P.force ~= c.force then P.force = c.force end
  if not P.stocked then
    -- the start stock (the market network exists once the centre's composite stands)
    local net = market(c)
    if net then
      P.stocked = true
      local kit = c.capital and PB.start_stock.capital or PB.start_stock.city
      for item, n in pairs(kit or {}) do
        if (c.capital and P.settled == 0) or not c.capital then net.insert({name = item, count = n}) end
      end
    end
  end
  if P.force == population.NEUTRAL then
    -- city-states (m2-world) have no governor: their residents neither eat nor grow, their tier stays
    P.housing = population.housing(city_id)
    return
  end
  if game.tick - P.last_needs >= PB.needs_period then consume(P, c) end
  local tier = c.tier
  local housing = population.housing(city_id)
  P.power = powered(P, c)
  P.happiness = happiness_of(P, tier)
  P.mood = clamp(P.happiness / PB.mood_base, 0, PB.mood_max)
  local per_min = 0
  local pop = P.pop
  local r = P.needs[population.RATIONS]
  if r and r.met < PB.hold_at then per_min = per_min - PB.starve * pop end
  if tier >= 2 and not P.power then per_min = per_min - PB.dark * pop end
  if pop > housing then per_min = per_min - PB.homeless * (pop - housing) end
  local grow = 0
  if per_min >= 0 and pop < housing and all_met(P, tier) and (tier < 2 or P.power) then
    grow = PB.growth * housing * P.mood
  end
  local dt = PB.growth_period / 3600
  local delta = (per_min + grow) * dt
  if grow > 0 then delta = math.min(delta, housing - pop) end
  local new = math.max(0, pop + delta)
  if new > pop then P.born = P.born + (new - pop) elseif new < pop then P.lost = P.lost + (pop - new) end
  P.pop = new
  P.growth = (new - pop) / dt
  check_tier(P, c)
  emit_pop(P)
end

events.on_nth_tick(60, function(e)
  local all = storage.population
  if not (all and next(all)) then return end
  local slot = (e.tick / 60) % population.GROWTH_SLOTS
  for id in pairs(all) do
    if id % population.GROWTH_SLOTS == slot then population.step(id) end
  end
end)

---------------------------------------------------------------------------
-- Build rules: farm slots, fishing huts by the water, apartments in towns
---------------------------------------------------------------------------
local BUILD_EVENTS = {[defines.events.on_built_entity] = "player", [defines.events.on_robot_built_entity] = "robot"}

local function farms_of(city_id, except)
  local n = 0
  for un in pairs(population.members(city_id)) do
    local rec = storage.buildings[un]
    if un ~= except and rec and rec.kind == "farm" and rec.entity.valid then n = n + 1 end
  end
  return n
end

local function water_near(surface, box, r)
  local area = {{box.left_top.x - r, box.left_top.y - r}, {box.right_bottom.x + r, box.right_bottom.y + r}}
  return surface.count_tiles_filtered({area = area, collision_mask = "water_tile", limit = 1}) > 0
end

--- Why `name` may not stand at that spot (box) for `force`, or nil. Reasons: "farm-slots", "water", "town".
function population.build_reason(force_name, name, surface, box, except_un)
  if name == "rts-fishing-hut" then
    if not water_near(surface, box, PB.fishing_water) then return "water" end
    return nil
  end
  if name ~= "rts-farm" and name ~= "rts-apartment" then return nil end
  local cx = (box.left_top.x + box.right_bottom.x) / 2
  local cy = (box.left_top.y + box.right_bottom.y) / 2
  local id = city_at({x = cx, y = cy})
  local c = id and cities.get(id)
  if not c then return nil end -- territory.lua refuses land without a city of the force
  if name == "rts-farm" then
    local slots = PB.farm_slots[c.tier] or PB.farm_slots[1]
    if farms_of(id, except_un) >= slots then return "farm-slots", slots, c end
  elseif name == "rts-apartment" and c.tier < PB.apartment_tier then
    return "town", nil, c
  end
  return nil
end

local REASON_KEYS = {["farm-slots"] = "rts-people.refused-farm-slots", water = "rts-people.refused-water",
                     town = "rts-people.refused-town"}

buildings.on_build_check(function(entity, e)
  local who = BUILD_EVENTS[e.name]
  if not who or not territory.nation() then return true end
  local ghost = entity.type == "entity-ghost"
  local name = ghost and entity.ghost_name or entity.name
  if not PB.buildings[name] then return true end
  local reason, n = population.build_reason(entity.force.name, name, entity.surface, entity.bounding_box,
    not ghost and entity.unit_number or nil)
  if not reason then return true end
  local pos, surface, force_name = entity.position, entity.surface, entity.force.name
  local item
  if not ghost then
    local items = entity.prototype.items_to_place_this
    item = items and items[1]
  end
  entity.destroy()
  if item then economy.give(force_name, item.name, item.count or 1) end
  local player = (e.player_index or 0) > 0 and game.get_player(e.player_index)
  if player and player.valid then
    player.create_local_flying_text({text = {REASON_KEYS[reason], n or ""}, position = pos, surface = surface,
                                     color = {1, 0.4, 0.3}})
  end
  util.log("people: refused %s%s of %s at %s (%s, by %s)", name, ghost and " ghost" or "", force_name,
    util.pos_str(pos), reason, who)
  return false
end)

---------------------------------------------------------------------------
-- Queries for the GUI and other packages
---------------------------------------------------------------------------
--- A snapshot of a city's people (see the header). nil for an unknown city.
function population.of(city_id)
  local P = population.get(city_id)
  local c = cities.get(city_id)
  if not (P and c) then return nil end
  local tier = c.tier
  local needs = {}
  for _, spec in ipairs(NEEDS) do
    local N = P.needs[spec.item]
    if tier >= spec.from then needs[spec.item] = {need = P.pop / spec.per, met = N.met} end
  end
  local L = population.labor
  local st = L and L.city_stats(city_id) or {}
  local next_at = PB.tiers[tier + 1]
  return {
    pop = math.floor(P.pop + 1e-6), housing = P.housing, workforce = population.workforce(city_id),
    free = st.free or 0, employed = st.employed or 0, jobs = st.jobs or 0, recruits = st.recruits or 0,
    happiness = math.floor(P.happiness + 0.5), needs = needs, power = P.power, growth = P.growth, draft = P.draft,
    tier = tier, tier_progress = next_at and math.min(1, P.pop / next_at) or 1, next_at = next_at,
    free_housing = math.max(0, P.housing - math.floor(P.pop)), unrest = P.unrest_until and game.tick < P.unrest_until,
    starving = starving(P), born = P.born, lost = P.lost, drafted = P.drafted, settled = P.settled,
  }
end

--- One debug line: "city 3 (rts-player, town): 132/160 (+5.3/min) rations 100% goods 80% power ok happy 82 ...".
function population.describe(city_id)
  local P = population.get(city_id)
  local c = cities.get(city_id)
  if not (P and c) then return string.format("city %s: -", tostring(city_id)) end
  local parts = {}
  for _, spec in ipairs(NEEDS) do
    if c.tier >= spec.from then
      parts[#parts + 1] = string.format("%s %d%%", spec.item, math.floor(P.needs[spec.item].met * 100 + 0.5))
    end
  end
  local L = population.labor
  local st = L and L.city_stats(city_id) or {}
  return string.format("city %d (%s, tier %d): %d/%d (%+.1f/min) %s power %s happy %d | workforce %d, jobs %d, "
    .. "employed %.0f, free %.0f, recruits %d, drafted %d", c.id, c.force, c.tier, math.floor(P.pop), P.housing,
    P.growth, table.concat(parts, " "), P.power and "ok" or "NO", math.floor(P.happiness + 0.5),
    population.workforce(city_id), st.jobs or 0, st.employed or 0, st.free or 0, st.recruits or 0, P.drafted)
end

-- One log line per city and minute ("[rts] people minute N: ..."): the tests and the balance passes read it.
events.on_nth_tick(3600, function(e)
  local all = storage.population
  local m = storage.match
  if not (all and next(all) and m and m.tick_started) then return end
  local minute = math.floor((e.tick - m.tick_started) / 3600 + 0.5)
  local ids = {}
  for id in pairs(all) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do util.log("people minute %d: %s", minute, population.describe(id)) end
end)

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------
match.on_teardown(function()
  for _, P in pairs(storage.population or {}) do
    if P.demand and P.demand.valid then P.demand.destroy() end
  end
  storage.population = {}
  storage.people = nil
  S()
end)

return population
