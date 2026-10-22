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
cities.NAMES = 24                  -- default names rts.city-name-1 .. 24 (Phase 5 M2 integration: 12 -> 24)
-- Phase 5 M2 integration: one name counter for every nation (each nation's first town was "Ironford"); city-states
-- keep their own titles and counter
local function name_key(force_name) return force_name == "rts-neutral" and force_name or "*" end
cities.LOST_ALERT_PERIOD = 30 * 60 -- "territory lost" at most this often per force
cities.LOST_ALERT_MIN = 4          -- cells
cities.SKIP_KINDS = {wall = true, stockpile = true} -- not counted for the tier-up
cities.TIER_KEYS = {"rts.city-tier-1", "rts.city-tier-2", "rts.city-tier-3"}
-- Phase 5 M3 ai: cities.ai_step waits for a "pending" town site search (ai/towns.lua runs it as a planning job only
-- when this is set; synchronous it cost up to 9 ms in one tick)
cities.TOWN_PENDING_OK = true
-- Phase 5 M2 people: "population" when scripts/population.lua decides the tiers (cities.set_tier); M1's buildings +
-- delivered rule in cities.check then only measures (the panel's land networks)
cities.tier_rule = nil

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
  if city.title and not (city.name and city.name ~= "") then return city.title end -- Phase 5 M2 world: city-states
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
  -- Phase 5 M2 war: after a capture a capital can be a City Center and a Command Center a plain city
  local e = city.entity
  local is_cc = e ~= nil and e.valid and e.name ~= cities.CENTER
  if city.capital and is_cc then return s - (CB.supply[CB.capital_tier] or 0) end
  if is_cc then return s end -- a captured Command Center is no hub: its tier supply counts in full
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

--- Set (n > 0) or clear (nil or 0) a make target. Returns true when the city and the item exist. QA round 1: a hidden
--- item or a cursor-only tool (the rts-cursor) is refused; clearing such a target still works.
function cities.set_make_target(city_id, item, n)
  local c = cities.get(city_id)
  local proto = item and prototypes.item[item]
  if not (c and proto) then return false end
  if (proto.hidden or item == util.CURSOR_ITEM) and (tonumber(n) or 0) > 0 then
    util.log("cities: make target %s #%d %s refused (not a good)", c.force, c.id, item)
    return false
  end
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

-- Phase 5 M2 world: the options of a script founding (cities.found without an entity). Its City Center's raise_built
-- registers it (buildings.on_added below) before cities.found regains control, so the options wait here.
local founding_opts

local function register(entity, opts)
  local S = cstate()
  local un = entity.unit_number
  local id = S.by_center[un]
  if id then return cities.get(id) end
  local force_name = entity.force.name
  local nation = storage.nations[force_name]
  -- Phase 5 M2 world: a city-state (archetype "city_state", force rts-neutral) is never a capital and no nation
  local city_state = opts.archetype == "city_state"
  local capital = not city_state and (opts.capital or (nation == nil or nation.capital == nil))
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
    local k = name_key(force_name)
    S.names[k] = (S.names[k] or 0) + 1
    name_index = S.names[k]
  end
  local p = entity.position
  local c = {id = id, force = force_name, name_index = name_index, capital = capital or nil,
             position = {x = p.x, y = p.y}, center = un, entity = entity, tier = tier,
             radius = cities.radius_of(tier, capital),
             archetype = opts.archetype or (capital and "capital" or "city"), founded = game.tick, buildings = 0,
             delivered = 0, last_total = nil, networks = {}, make = {}, title = opts.title} -- Phase 5 M2 world: title
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
  founding_opts = opts -- Phase 5 M2 world (see founding_opts)
  entity = surface and surface.create_entity({name = cities.CENTER, position = {math.floor(x + 0.5),
    math.floor(y + 0.5)}, force = force_name, raise_built = true})
  founding_opts = nil
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

---------------------------------------------------------------------------
-- Phase 5 M2 war: cities change hands (scripts/capture.lua, docs/PHASE5-M2.md D4)
---------------------------------------------------------------------------
--- Make city `city_id` the capital of `force_name` (its land radius and strength follow; the old capital becomes a
--- plain city). Returns true when it is the capital now.
function cities.set_capital(force_name, city_id)
  local c = cities.get(city_id)
  if not (c and c.force == force_name) then return false end
  local nation = storage.nations[force_name]
  if not nation then
    nation = {age = 1}
    storage.nations[force_name] = nation
  end
  local cur = nation.capital and cities.get(nation.capital)
  if cur and cur.id ~= city_id and cur.force == force_name and cur.capital then
    cur.capital = nil
    cur.radius = cities.radius_of(cur.tier, false)
    territory.update_source(cur.center, cur.radius, strength_of(cur))
  end
  nation.capital = city_id
  c.capital = true
  c.radius = cities.radius_of(c.tier, true)
  territory.update_source(c.center, c.radius, strength_of(c))
  util.log("cities: city %d is the capital of %s now (tier %d, radius %d)", city_id, force_name, c.tier, c.radius)
  events.emit("rts_capital_moved", {force = force_name, city = city_id})
  return true
end

--- The city changes hands. The record, the land source (force, radius, strength) and the capital flags follow: the new
--- owner makes it its capital only when it has none; when it was the old owner's capital, the old owner's capital
--- moves to opts.new_capital (else its first remaining city). Returns the old owner, or nil when nothing changed.
--- Signal "rts_city_owner_changed" {city, from, to}.
function cities.change_owner(city_id, force_name, opts)
  opts = opts or {}
  local c = cities.get(city_id)
  if not c or c.force == force_name then return nil end
  local old = c.force
  local was_capital = c.capital
  c.force = force_name
  c.capital = nil
  if c.archetype == "capital" then c.archetype = "city" end
  if was_capital or (c.name_index or 0) == 0 then -- a capital has no city name of its own: it gets one of the winner
    local S = cstate()
    local k = name_key(force_name)
    S.names[k] = (S.names[k] or 0) + 1
    c.name_index = S.names[k]
  end
  local nation = storage.nations[force_name]
  if not (nation and nation.capital and cities.get(nation.capital)) then
    if not nation then
      nation = {age = 1}
      storage.nations[force_name] = nation
    end
    nation.capital = city_id
    c.capital = true
  end
  -- a captured capital keeps the land it had (its outer ring would otherwise fall out of the capture)
  c.radius = math.max(c.radius or 0, cities.radius_of(c.tier, c.capital))
  c.last_total = nil
  territory.set_source_force(c.center, force_name)
  territory.update_source(c.center, c.radius, strength_of(c))
  local onation = storage.nations[old]
  if onation and onation.capital == city_id then
    onation.capital = nil
    local pick = opts.new_capital and cities.get(opts.new_capital)
    if not (pick and pick.force == old) then pick = cities.for_force(old)[1] end
    if pick then cities.set_capital(old, pick.id) end
  end
  util.log("cities: city %d changed hands %s -> %s%s (tier %d, radius %d)", city_id, old, force_name,
    was_capital and " (was the capital)" or "", c.tier, c.radius)
  events.emit("rts_city_owner_changed", {city = city_id, from = old, to = force_name})
  return old
end

buildings.on_added(function(un, rec)
  if not territory.nation() then return end
  local e = rec.entity
  if rec.kind == "cc" then
    -- Phase 5 M1 integration: the nation's inserter bonus (balance.nation.cities.inserter_bonus; reset at teardown)
    local force = game.forces[rec.force]
    if force and CB.inserter_bonus then force.inserter_stack_size_bonus = CB.inserter_bonus end
    local nation = storage.nations[rec.force]
    if not (nation and nation.capital and cities.get(nation.capital)) then register(e, {capital = true, why = "(CC)"}) end
  elseif e.name == cities.CENTER then
    register(e, founding_opts or {why = "(City Center)"}) -- Phase 5 M2 world: a script founding's options
  end
end)

buildings.on_removed(function(un)
  if cstate().by_center[un] then lose(un) end
end)

-- Phase 5 M1 integration: the capital's centre (CC or City Center) heals back balance.nation.cities.capital_armor of
-- every hit (the shared on_entity_damaged filter of scripts/research.lua lists every RTS building).
-- Phase 5 M2 integration: a city-state's centre (archetype "city_state" while rts-neutral holds it) heals back
-- balance.nation.world.city_state.armor (2x effective HP): 2-3 passing units took them before.
local CS_ARMOR = balance.nation.world and balance.nation.world.city_state and balance.nation.world.city_state.armor
events.on(defines.events.on_entity_damaged, function(e)
  local entity = e.entity
  if not (entity and entity.valid and e.final_health > 0 and storage.cities) then return end
  if e.damage_type.name == "rts-attrition" then return end
  local un = entity.unit_number
  local id = un and storage.city_state and storage.city_state.by_center[un]
  local c = id and storage.cities[id]
  if not c then return end
  local share
  if c.capital then
    share = CB.capital_armor
  elseif c.archetype == "city_state" and c.force == "rts-neutral" then
    share = CS_ARMOR
  end
  if not share or share <= 0 then return end
  entity.health = entity.health + e.final_damage_amount * share
end)

-- Phase 5 M2 integration: attacks on a city (the city panel's "under attack" line and the list, the AI's relief). An own
-- registered building on the city's land damaged by another force records {tick, position, by} at most every
-- ATTACK_THROTTLE ticks per city. storage.city_attacks = {[city_id] = {tick, position, by}}, cleared at teardown.
cities.ATTACK_THROTTLE = 30
events.on(defines.events.on_entity_damaged, function(e)
  local entity = e.entity
  local by = e.force
  if not (entity and entity.valid and by and storage.cities and buildings.KIND_BY_NAME[entity.name]) then return end
  if by.name == entity.force.name or e.damage_type.name == "rts-attrition" then return end
  local id = territory.city_at(entity.position)
  local c = id and storage.cities[id]
  if not (c and c.force == entity.force.name) then return end
  local A = storage.city_attacks
  if not A then
    A = {}
    storage.city_attacks = A
  end
  local last = A[id]
  if last and game.tick - last.tick < cities.ATTACK_THROTTLE then return end
  local p = entity.position
  A[id] = {tick = game.tick, position = {x = p.x, y = p.y}, by = by.name, owner = c.force}
end)

--- The last attack on a city within `window` ticks (default 30 s): {tick, position, by, owner} or nil. An attack on the
--- city's previous owner (before a capture) does not count.
function cities.under_attack(city_id, window)
  local a = storage.city_attacks and storage.city_attacks[city_id]
  if not a or game.tick - a.tick > (window or 1800) then return nil end
  local c = storage.cities and storage.cities[city_id]
  if not c or a.owner ~= c.force then return nil end
  return a
end

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
  -- Phase 5 M2 people: with tiers by population only the land networks are measured (the building count walked every
  -- building of the force per city: 40 cities x 2,000 buildings)
  if cities.tier_rule then
    c.networks = land_networks(c)
    return false
  end
  local total = network_total(c)
  if total then
    if c.last_total and total > c.last_total then c.delivered = c.delivered + (total - c.last_total) end
    c.last_total = total
  end
  c.buildings = count_buildings(c)
  c.networks = land_networks(c)
  local req = cities.next_tier(c)
  if not (req and c.buildings >= req.buildings and c.delivered >= req.delivered) then return false end
  return cities.set_tier(c, c.tier + 1, string.format("%d buildings, %d delivered", c.buildings, c.delivered))
end

-- Phase 5 M2 people: one tier change (up or down): land radius, territory source, alert, signal "rts_city_tier".
--- Set a city's tier (1..3). Returns true when it changed.
function cities.set_tier(c, tier, why)
  tier = math.max(1, math.min(#cities.TIER_KEYS, tier))
  if not c or c.tier == tier then return false end
  local up = tier > c.tier
  c.tier = tier
  c.radius = cities.radius_of(c.tier, c.capital)
  territory.update_source(c.center, c.radius, strength_of(c))
  util.log("cities: city %d of %s %s tier %d (%s): radius %d", c.id, c.force, up and "reached" or "dropped to", c.tier,
    why or "-", c.radius)
  if up then
    alert(c.force, "city-tier", "rts.alert-city-tier", {cities.display_name(c), {cities.TIER_KEYS[c.tier]}}, c.position)
  else
    alert(c.force, "city-tier", "rts-people.alert-city-shrank", {cities.display_name(c), {cities.TIER_KEYS[c.tier]}},
      c.position)
  end
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
local ai_deps -- scripts/ai/deps.lua (load time; deps.towns is read at run time)
do
  local ok, mod = pcall(require, "scripts.ai.deps")
  if ok and type(mod) == "table" then ai_deps = mod end
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

-- Phase 5 M3 integration: required at load, not in pick_site (Factorio refuses require outside control.lua parsing:
-- "Require can't be used outside of control.lua parsing" ended every Nation match whose AI fell back to this function,
-- seed 701 at 5:00); match.lua loads it before this file
local WORLDGEN = require("scripts.worldgen")

local function pick_site(C, surface, home)
  local half = match.arena_half()
  local world = storage.world
  if world and type(world.size) == "number" then half = world.size / 2 end
  local worldgen = WORLDGEN -- Phase 5 M3 integration
  for _, cand in ipairs(site_candidates(C, home)) do
    -- Phase 5 M3 integration (world3 notes open issue 4): a candidate on ground that is not generated yet (a 4096
    -- world fills in the background) is asked for and skipped this time
    local p
    if world and world.surface and not worldgen.generated(cand) then
      local n = worldgen.request_area(C.force, {{cand.x - 64, cand.y - 64}, {cand.x + 64, cand.y + 64}})
      util.log("ai %s: city site %s (%s) not generated yet: %d chunks requested", C.force, util.pos_str(cand), cand.why, n)
    else
      p = surface.find_non_colliding_position(cities.CENTER, {cand.x, cand.y}, 24, 1, true)
    end
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
  -- Phase 5 M1 integration: on a world map the AI's second city is a mining town next to an ore patch
  -- (scripts/ai/towns.lua); the world's city sites are the fallback
  local towns = ai_deps and ai_deps.towns or nil
  local site, why
  if towns and storage.world then site, why = towns.pick_site(C, surface, home) end
  if why == "pending" then -- Phase 5 M3 ai (perf): the town site search runs as a planning job; this was no try
    A.tries = A.tries - 1
    return
  end
  if not site then site, why = pick_site(C, surface, home) end
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
  for _, force in pairs(game.forces) do
    if string.sub(force.name, 1, 4) == "rts-" and force.inserter_stack_size_bonus ~= 0 then
      force.inserter_stack_size_bonus = 0
    end
  end
  storage.cities = {}
  storage.nations = {}
  storage.city_state = nil
  storage.city_attacks = nil -- Phase 5 M2 integration
  cstate()
end)

return cities
