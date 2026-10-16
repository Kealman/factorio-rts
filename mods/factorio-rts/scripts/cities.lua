-- Phase 5 M1 cities (docs/PHASE5-M1.md section 3 "cities.lua"; study docs/research/scale/territory-cities.md section 3).
-- Nation mode only (storage.match.config.mode == "nation"); in Skirmish no city is ever registered.
--
-- A city is a City Center plus the land it claims (scripts/territory.lua). The starting Command Center of every force
-- is its capital (city 1 of that force, tier balance.nation.cities.capital_tier = 2). New cities stand on an
-- rts-city-center: the factory makes a City charter (its item), the player places the ghost from the build menu and
-- the Commander builds it like a hub (scripts/commander.lua field supply) or the force's robots do. A City Center is a
-- hub subtype: scripts/logistics.lua completes its composite (hub power, pole, 2 stockpiles, 10 + 6 robots), so it is a
-- logistics node with its own network and stockpile policy; this module adds rts-city-power (700 kW, a 1 MW core in
-- all), registers the city and its land, and names it in the hub panel (logistics.NAME_HOOKS).
--
-- Tiers: village (1) -> town (2) -> city (3). Land radius 48 / 72 / 96 tiles (the capital claims
-- balance.nation.territory.capital_bonus = 24 tiles more, the study's "+3 cells": 96 at tier 2), supply 10 / 20 / 30
-- (balance.nation.cities.supply; the capital adds its tier's supply minus the tier-2 20 on top of the CC's 40, a City
-- Center's hub cap counts as part of its tier supply). Tier-up (every CHECK_PERIOD): `buildings` registered buildings of
-- the force stand on the city's land (walls and stockpiles do not count) and `delivered` goods arrived in its market
-- (the City Center's logistic network: the sum of positive changes of its item total between checks).
--
-- Owns storage.cities = {[id] = {id, force, name (custom string or nil), name_index, capital, position, center
--   (unit_number), entity, tier, radius, archetype ("capital" | "city"), founded (tick), buildings, delivered,
--   last_total, networks = {network ids on its land}, make = {[item] = n}, power (LuaEntity)}},
-- storage.nations = {[force] = {capital = city id, age = 1}} and storage.city_state = {next_id, by_center = {[unit
-- number] = id}, names = {[force] = n}, ai = {[force] = {key, site, tries, retry_at, stands, done}}, last_lost = {[force] =
-- tick}}; all cleared by match teardown. Signals: "rts_city_founded" {city}, "rts_city_tier" {city, tier},
-- "rts_city_lost" {city}, "rts_make_targets_changed" {city, item, n}. Alerts (storage.alerts, supply.alert):
-- "city-founded", "city-tier", "city-lost", "territory-lost". Log lines "[rts] cities: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local supply = require("scripts.supply")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local balance = require("balance")

local cities = {}

local CB = balance.nation.cities
local TB = balance.nation.territory

cities.CENTER = "rts-city-center"
cities.POWER = "rts-city-power"
cities.CHARTER = "rts-city-charter"
cities.CHECK_PERIOD = 600          -- ticks between the tier checks of one city
cities.NAMES = 12                  -- default names rts.city-name-1 .. 12
cities.LOST_ALERT_PERIOD = 30 * 60 -- "territory lost" at most this often per force
cities.LOST_ALERT_MIN = 4          -- cells
cities.SKIP_KINDS = {wall = true, stockpile = true} -- not counted for the tier-up
cities.TIER_KEYS = {"rts.city-tier-1", "rts.city-tier-2", "rts.city-tier-3"}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function cstate()
  local S = storage.city_state
  if not S then
    S = {}
    storage.city_state = S
  end
  S.next_id = S.next_id or 1
  S.by_center = S.by_center or {}
  S.names = S.names or {}
  S.ai = S.ai or {}
  S.last_lost = S.last_lost or {}
  return S
end

function cities.init()
  storage.cities = storage.cities or {}
  storage.nations = storage.nations or {}
  cstate()
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
--- A city record ({id, force, name, position, center, tier, radius, archetype, networks, ...}), or nil.
function cities.get(city_id)
  return storage.cities and storage.cities[city_id] or nil
end

--- The city whose City Center (or capital CC) has this unit number, or nil.
function cities.of_center(unit_number)
  local id = cstate().by_center[unit_number]
  return id and cities.get(id) or nil
end

--- The city whose land the entity (or position) stands on, or nil.
function cities.of_entity(entity)
  local pos = entity.position or entity
  local id = territory.city_at(pos)
  return id and cities.get(id) or nil
end

--- The cities of a force, by id.
function cities.for_force(force_name)
  local list = {}
  for _, c in pairs(storage.cities or {}) do
    if c.force == force_name then list[#list + 1] = c end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

--- Localised display name of a city.
function cities.display_name(city)
  if not city then return {"rts.city-none"} end
  if city.name and city.name ~= "" then return city.name end
  if city.capital then return {"rts.city-capital-name"} end
  return {"rts.city-name-" .. (((city.name_index or 1) - 1) % cities.NAMES + 1)}
end

--- Land radius in tiles of a tier (the capital claims balance.nation.territory.capital_bonus more).
function cities.radius_of(tier, capital)
  return (TB.radius.city[tier] or TB.radius.city[1]) + (capital and TB.capital_bonus or 0)
end

local function strength_of(city)
  return (TB.strength.city[city.tier] or 1) + (city.capital and TB.strength.capital or 0)
end

--- Supply a city adds (see the header): tier supply, minus the hub cap of a City Center, minus 20 for the capital.
function cities.supply_of(city)
  local s = CB.supply[city.tier] or 0
  if city.capital then return s - (CB.supply[CB.capital_tier] or 0) end
  return s - supply.HUB_CAP
end

--- Supply cap the city stands for in all: a City Center's tier supply, the capital's CC cap plus its tier bonus.
function cities.supply_total(city)
  if city.capital then return supply.CC_CAP + cities.supply_of(city) end
  return CB.supply[city.tier] or 0
end

supply.on_cap(function(force_name)
  if not storage.cities or not territory.nation() then return 0 end
  local n = 0
  for _, c in pairs(storage.cities) do
    if c.force == force_name and c.entity and c.entity.valid then n = n + cities.supply_of(c) end
  end
  return n
end)

--- Make targets of a city: {[item] = n} (read-only for callers; cities.set_make_target writes).
function cities.make_targets(city_id)
  local c = cities.get(city_id)
  return c and c.make or {}
end

--- Set (n > 0) or clear (nil or 0) a make target. Returns true when the city and the item exist.
function cities.set_make_target(city_id, item, n)
  local c = cities.get(city_id)
  if not (c and item and prototypes.item[item]) then return false end
  n = n and math.floor(tonumber(n) or 0) or 0
  n = math.max(0, math.min(1000000, n))
  local value = n > 0 and n or nil
  if c.make[item] == value then return true end
  c.make[item] = value
  util.log("cities: make target %s #%d %s = %s", c.force, c.id, item, tostring(value))
  events.emit("rts_make_targets_changed", {city = c.id, item = item, n = value})
  return true
end

--- Rename a city (empty = the default name).
function cities.rename(city_id, name)
  local c = cities.get(city_id)
  if not c then return false end
  name = name and string.gsub(string.gsub(tostring(name), "^%s+", ""), "%s+$", "") or ""
  if #name > 40 then name = string.sub(name, 1, 40) end
  c.name = name ~= "" and name or nil
  util.log("cities: city %d of %s renamed to %s", c.id, c.force, tostring(c.name))
  return true
end

--- Tier-up requirements of the next tier, or nil at the top.
function cities.next_tier(city)
  return CB.tier_up[city.tier + 1]
end

---------------------------------------------------------------------------
-- Founding and losing
---------------------------------------------------------------------------
local function alert(force_name, kind, text, params, position)
  supply.alert(force_name, kind, text, params, position)
end

local function register(entity, opts)
  local S = cstate()
  local un = entity.unit_number
  local id = S.by_center[un]
  if id then return cities.get(id) end
  local force_name = entity.force.name
  local nation = storage.nations[force_name]
  local capital = opts.capital or (nation == nil or nation.capital == nil)
  id = S.next_id
  if id > 255 then
    util.log("cities: city limit of the grid reached (255), %s at %s not registered", force_name,
      util.pos_str(entity.position))
    return nil
  end
  S.next_id = id + 1
  local tier = opts.tier or (capital and CB.capital_tier or 1)
  local name_index = 0
  if not capital then
    S.names[force_name] = (S.names[force_name] or 0) + 1
    name_index = S.names[force_name]
  end
  local p = entity.position
  local c = {id = id, force = force_name, name_index = name_index, capital = capital or nil,
             position = {x = p.x, y = p.y}, center = un, entity = entity, tier = tier,
             radius = cities.radius_of(tier, capital),
             archetype = capital and "capital" or "city", founded = game.tick, buildings = 0, delivered = 0,
             last_total = nil, networks = {}, make = {}}
  storage.cities[id] = c
  S.by_center[un] = id
  if capital then
    storage.nations[force_name] = storage.nations[force_name] or {age = 1}
    storage.nations[force_name].capital = id
  end
  if entity.name == cities.CENTER then
    local power = entity.surface.find_entities_filtered({position = p, radius = 1, name = cities.POWER,
                                                          force = entity.force})[1]
    c.power = power or entity.surface.create_entity({name = cities.POWER, position = p, force = force_name})
  end
  territory.add_source(entity, c.radius, {kind = "city", strength = strength_of(c), city = id})
  util.log("cities: %s city %d of %s at %s (tier %d, radius %d)%s", capital and "capital" or "new", id, force_name,
    util.pos_str(p), tier, c.radius, opts.why and (" " .. opts.why) or "")
  local m = storage.match
  if not (m and m.placing) then
    alert(force_name, "city-founded", "rts.alert-city-founded", {cities.display_name(c)}, p)
  end
  events.emit("rts_city_founded", {city = id})
  return c
end

--- Found a city for `force` at `position`: opts.entity = an existing City Center or CC to register (the build path);
--- without it a City Center is placed there by script (tests, debug). opts.capital, opts.tier. Returns the city id.
function cities.found(force, position, opts)
  opts = opts or {}
  if not territory.nation() then return nil end
  local entity = opts.entity
  if entity then
    local c = register(entity, opts)
    return c and c.id
  end
  local force_name = type(force) == "string" and force or force.name
  local surface = match.surface()
  local x, y = util.xy(position)
  entity = surface and surface.create_entity({name = cities.CENTER, position = {math.floor(x + 0.5),
    math.floor(y + 0.5)}, force = force_name, raise_built = true})
  if not entity then
    util.log("cities: found for %s at %s failed: no room", force_name, util.pos_str(position))
    return nil
  end
  local c = cities.of_center(entity.unit_number) or register(entity, opts)
  return c and c.id
end

local function lose(un)
  local S = cstate()
  local id = S.by_center[un]
  local c = id and storage.cities[id]
  if not c then return end
  S.by_center[un] = nil
  storage.cities[id] = nil
  if c.power and c.power.valid then c.power.destroy() end
  territory.remove_source(un)
  local nation = storage.nations[c.force]
  if nation and nation.capital == id then
    local rest = cities.for_force(c.force)
    nation.capital = rest[1] and rest[1].id or nil
    if rest[1] then
      local nc = rest[1]
      nc.capital = true
      nc.radius = cities.radius_of(nc.tier, true)
      territory.update_source(nc.center, nc.radius, strength_of(nc))
    end
  end
  util.log("cities: city %d of %s at %s lost", id, c.force, util.pos_str(c.position))
  alert(c.force, "city-lost", "rts.alert-city-lost", {cities.display_name(c)}, c.position)
  events.emit("rts_city_lost", {city = id, force = c.force})
end

buildings.on_added(function(un, rec)
  if not territory.nation() then return end
  local e = rec.entity
  if rec.kind == "cc" then
    local nation = storage.nations[rec.force]
    if not (nation and nation.capital and cities.get(nation.capital)) then register(e, {capital = true, why = "(CC)"}) end
  elseif e.name == cities.CENTER then
    register(e, {why = "(City Center)"})
  end
end)

buildings.on_removed(function(un)
  if cstate().by_center[un] then lose(un) end
end)

logistics.NAME_HOOKS[cities.CENTER] = function(un)
  local c = cities.of_center(un)
  return c and cities.display_name(c) or {"entity-name." .. cities.CENTER}
end

---------------------------------------------------------------------------
-- Tiers
---------------------------------------------------------------------------
local function network_total(c)
  local net = c.entity.valid and c.entity.logistic_network
  if not (net and net.valid) then return nil end
  local n = 0
  for _, item in pairs(net.get_contents()) do n = n + item.count end
  return n, net.network_id
end

local function count_buildings(c)
  local n = 0
  for _, rec in buildings.for_force(c.force) do
    if not cities.SKIP_KINDS[rec.kind] and rec.entity.unit_number ~= c.center
       and territory.city_at(rec.position) == c.id then
      n = n + 1
    end
  end
  return n
end

local function land_networks(c)
  local seen, list = {}, {}
  for _, entry in ipairs(logistics.networks(c.force)) do
    if territory.city_at(entry.position) == c.id and not seen[entry.id] then
      seen[entry.id] = true
      list[#list + 1] = entry.id
    end
  end
  local own = c.entity.valid and c.entity.logistic_network
  if own and own.valid and not seen[own.network_id] then table.insert(list, 1, own.network_id) end
  return list
end

--- Re-measure one city and raise its tier when the next tier's requirements are met. Returns true on a tier-up.
function cities.check(c)
  if not (c.entity and c.entity.valid) then return false end
  local total = network_total(c)
  if total then
    if c.last_total and total > c.last_total then c.delivered = c.delivered + (total - c.last_total) end
    c.last_total = total
  end
  c.buildings = count_buildings(c)
  c.networks = land_networks(c)
  local req = cities.next_tier(c)
  if not (req and c.buildings >= req.buildings and c.delivered >= req.delivered) then return false end
  c.tier = c.tier + 1
  c.radius = cities.radius_of(c.tier, c.capital)
  territory.update_source(c.center, c.radius, strength_of(c))
  util.log("cities: city %d of %s reached tier %d (%d buildings, %d delivered): radius %d", c.id, c.force, c.tier,
    c.buildings, c.delivered, c.radius)
  alert(c.force, "city-tier", "rts.alert-city-tier", {cities.display_name(c), {cities.TIER_KEYS[c.tier]}}, c.position)
  events.emit("rts_city_tier", {city = c.id, tier = c.tier})
  return true
end

events.on_nth_tick(60, function(e)
  if not (storage.cities and next(storage.cities)) then return end
  local slot = (e.tick / 60) % (cities.CHECK_PERIOD / 60)
  for id, c in pairs(storage.cities) do
    if id % (cities.CHECK_PERIOD / 60) == slot then cities.check(c) end
  end
end)

---------------------------------------------------------------------------
-- Territory signals: "territory lost near X"
---------------------------------------------------------------------------
events.on_signal(territory.SIGNAL, function(d)
  if not (d.lost and d.lost >= cities.LOST_ALERT_MIN and d.lost_at) then return end
  local S = cstate()
  local last = S.last_lost[d.force]
  if last and game.tick - last < cities.LOST_ALERT_PERIOD then return end
  local c = d.lost_city and cities.get(d.lost_city)
  if not c then
    local best, bd = nil, math.huge
    for _, city in ipairs(cities.for_force(d.force)) do
      local dist = util.distance(city.position, d.lost_at)
      if dist < bd then best, bd = city, dist end
    end
    c = best
  end
  if not c then return end
  S.last_lost[d.force] = game.tick
  alert(d.force, "territory-lost", "rts.alert-territory-lost", {d.lost, cities.display_name(c)}, d.lost_at)
end)

---------------------------------------------------------------------------
-- AI: one second city (docs/PHASE5-M1.md section 2: "found a city: one hook"; the governor is M2)
---------------------------------------------------------------------------
-- The AI factory makes the charter like any construction item (ai/commander.lua construction_want).
do
  local ok, data = pcall(require, "scripts.ai.orders_data")
  if ok and type(data) == "table" and data.FACTORY_RECIPE then data.FACTORY_RECIPE[cities.CHARTER] = cities.CHARTER end
end
local ai_construction
do
  local ok, mod = pcall(require, "scripts.ai.construction")
  if ok and type(mod) == "table" then ai_construction = mod end
end

-- Candidate sites, best first: the world's city sites (nearest first), else points AI_SITE_DISTANCE tiles from the
-- capital towards its first expansion (its natural) or the arena centre.
local function site_candidates(C, home)
  local list = {}
  local world = storage.world
  if world and type(world.sites) == "table" and #world.sites > 0 then
    for _, s in ipairs(world.sites) do
      if s.kind == "city_site" and s.position then
        list[#list + 1] = {x = s.position.x or s.position[1], y = s.position.y or s.position[2], why = "world site"}
      end
    end
    table.sort(list, function(a, b)
      local da, db = util.distance_sq(a, home), util.distance_sq(b, home)
      if da ~= db then return da < db end
      return a.x < b.x
    end)
    return list
  end
  local target = {x = 0, y = 0}
  for _, X in pairs(C.expansions or {}) do
    if X.pos then
      target = X.pos
      break
    end
  end
  local dx, dy = target.x - home.x, target.y - home.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then dx, dy, len = -home.x, -home.y, math.sqrt(home.x * home.x + home.y * home.y) end
  if len < 1 then dx, dy, len = 1, 0, 1 end
  dx, dy = dx / len, dy / len
  local d = CB.ai_site_distance
  for _, deg in ipairs({0, 25, -25, 50, -50, 75, -75}) do
    local a = math.rad(deg)
    local rx, ry = dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a)
    list[#list + 1] = {x = home.x + rx * d, y = home.y + ry * d, why = string.format("natural side %+d deg", deg)}
  end
  return list
end

local function pick_site(C, surface, home)
  local half = match.arena_half()
  local world = storage.world
  if world and type(world.size) == "number" then half = world.size / 2 end
  for _, cand in ipairs(site_candidates(C, home)) do
    local p = surface.find_non_colliding_position(cities.CENTER, {cand.x, cand.y}, 24, 1, true)
    if p then
      p = {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5)}
      local inside = math.abs(p.x) < half - 12 and math.abs(p.y) < half - 12
      local ok, reason = territory.can_build(C.force, cities.CENTER, p)
      if inside and ok and util.distance(p, home) >= CB.spacing then
        return p, cand.why
      end
      util.log("ai %s: city site %s (%s) rejected: %s", C.force, util.pos_str(p), cand.why,
        not inside and "outside the map" or (reason or "too close to the capital"))
    end
  end
  return nil
end

--- One AI commander run (scripts/ai/commander.lua): from ai_found_at on, plan one City Center on a site and queue it
--- in the commander's construction plan; the factory makes the charter and construction revives the ghost.
function cities.ai_step(C, surface)
  if not (ai_construction and territory.nation()) then return end
  local S = cstate()
  local A = S.ai[C.force]
  if not A then
    A = {tries = 0}
    S.ai[C.force] = A
  end
  local count = #cities.for_force(C.force)
  if A.stands then
    if count >= 2 then return end
    -- the second city was lost: plan a new one after a pause (at most 4 sites in all)
    A.stands, A.key, A.retry_at = nil, nil, game.tick + 120 * 60
    util.log("ai %s: second city lost, a new site in 120 s", C.force)
  end
  if A.done then return end
  local m = storage.match
  if not (m and m.tick_started) or (game.tick - m.tick_started) < CB.ai_found_at * 60 then return end
  if count >= 2 then
    A.stands = true
    util.log("ai %s: second city stands (%d cities)", C.force, count)
    return
  end
  if A.key then
    local e = C.plan[A.key]
    if e and e.status ~= "bad" then
      if e.status == "planned" then ai_construction.queue(C, A.key) end
      return
    end
    util.log("ai %s: city site %s given up (%s)", C.force, util.pos_str(A.site), e and e.status or "no entry")
    A.key, A.retry_at = nil, game.tick + 60 * 60
  end
  if A.retry_at and game.tick < A.retry_at then return end
  if A.tries >= 4 then
    A.done = true
    util.log("ai %s: no second city after %d sites", C.force, A.tries)
    return
  end
  A.tries = A.tries + 1
  local nation = storage.nations[C.force]
  local cap = nation and cities.get(nation.capital)
  local home = cap and cap.position or match.home(C.force)
  local site, why = pick_site(C, surface, home)
  if not site then
    A.retry_at = game.tick + 60 * 60
    util.log("ai %s: no city site yet (try %d)", C.force, A.tries)
    return
  end
  A.site = site
  A.key = ai_construction.add(C, {name = cities.CENTER, x = site.x, y = site.y, line = "city"})
  ai_construction.queue(C, A.key)
  util.log("ai %s: second city planned at %s (%s, %.0f tiles from the capital)", C.force, util.pos_str(site), why,
    util.distance(site, home))
end
do
  local ok, deps = pcall(require, "scripts.ai.deps")
  if ok and type(deps) == "table" then
    deps.cities = cities
    deps.territory = territory
  end
end

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------
match.on_teardown(function()
  for _, c in pairs(storage.cities or {}) do
    if c.power and c.power.valid then c.power.destroy() end
  end
  storage.cities = {}
  storage.nations = {}
  storage.city_state = nil
  cstate()
end)

return cities
