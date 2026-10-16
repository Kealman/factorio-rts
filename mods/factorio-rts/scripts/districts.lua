-- Phase 5 E1: districts, oil, make targets and the city ledger data (docs/PHASE5-M1.md section 3,
-- docs/research/scale/deep-economy.md sections 3.4-3.6, docs/qa/phase5-economy-notes.md).
--
-- Buildings (kinds registered here): the ten rts-district-*, rts-refinery and rts-chemical-plant are "district"
-- (production.lua feeds them from their logistic network and hands their products back, like the factory; auto
-- recipe from make targets in Nation mode); rts-pumpjack is "pumpjack": every PUMP_PERIOD ticks its crude oil goes
-- into the logistic network it stands in as rts-crude-oil items (CRUDE_PER_ITEM fluid units each), so oil is hauled
-- like any good. districts.staffing_factor(entity) -> 1 is the M2 labor hook.
--
-- Cities and make targets (cities.lua is m1-cities'; until it is loaded a shim runs: one city per force, the capital,
-- id = force name):
--   districts.city_of(entity_or_position, force) -> city_id | nil
--   districts.cities(force) -> {{id, name, position}, ...}
--   districts.make_targets(city_id) -> {[item] = n}        (cities.make_targets when loaded)
--   districts.set_make_target(city_id, item, n | nil)     (cities.set_make_target when loaded)
-- production.targets_of(entity) = the make targets of the entity's city; production.auto_active() = Nation mode.
--
-- Ledger (scripts/ledgergui.lua reads it): items made and used per city over the last minute, counted where goods
-- pass the script: production hand-off and pull (factories, districts, barracks), labs, the project site, pumpjacks,
-- and smelters (products_finished deltas every SMELTER_PERIOD). 12 buckets of 5 s per city.
--   districts.flows(city_id) -> {made = {[item] = n}, used = {[item] = n}}   (last 60 s)
--   districts.ledger(city_id) -> rows {item, stock, made, used, target, short, hint}
--   districts.hint(city_id, item) -> nil | {item = missing ingredient, city = city_id | nil (nowhere)}
--
-- Owns storage.districts = {targets = {[city_id] = {[item] = n}} (shim only), flows = {[city_id] = {[bucket] =
-- {start, made, used}}}, smelters = {[unit_number] = products_finished}, stats = {[force] = {crude}}}. Cleared on
-- match teardown.
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local match = require("scripts.match")
local ages = require("scripts.ages")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local E = balance.nation.economy

local districts = {}

districts.PUMP_PERIOD = E.pumpjack_period
districts.CRUDE_PER_ITEM = E.crude_per_item
districts.CRUDE = "crude-oil"
districts.CRUDE_ITEM = "rts-crude-oil"
districts.SMELTER_PERIOD = 300
districts.BUCKET_TICKS = 300
districts.BUCKETS = 12
-- Goods the ledger always lists (when they exist), in this order; then make targets, then anything that flowed.
districts.LEDGER_ITEMS = {
  "iron-plate", "copper-plate", "steel-plate", "stone", "stone-brick", "coal", "iron-gear-wheel", "copper-cable",
  "electronic-circuit", "rts-explosives", "rts-science-basic", "rts-science-advanced",
}
districts.LEDGER_ITEMS_AGE2 = {
  "rts-crude-oil", "rts-petroleum", "plastic-bar", "sulfur", "engine-unit", "advanced-circuit", "rts-steel-beam",
  "concrete", "rail", "rts-science-industrial",
}

-- Registry kinds of the Age II buildings (balance.nation.economy.buildings).
for name, b in pairs(E.buildings) do buildings.KIND_BY_NAME[name] = b.kind end
districts.NAMES = {}
for name, b in pairs(E.buildings) do
  if b.kind == "district" then districts.NAMES[#districts.NAMES + 1] = name end
end
table.sort(districts.NAMES)

deps.districts = districts

function districts.init()
  local D = storage.districts or {}
  storage.districts = D
  D.targets = D.targets or {}
  D.flows = D.flows or {}
  D.smelters = D.smelters or {}
  D.stats = D.stats or {}
end

local function D()
  if not storage.districts then districts.init() end
  return storage.districts
end

--- M2 labor hook: the share of its workers a district has (1 = full speed). No labor in M1.
function districts.staffing_factor(entity) return 1 end

---------------------------------------------------------------------------
-- Cities (cities.lua or the shim)
---------------------------------------------------------------------------
--- City id of an entity (or a position with a force name), or nil.
function districts.city_of(target, force_name)
  local cities = ages.cities()
  local entity = target and target.object_name == "LuaEntity" and target or nil
  if cities and cities.of_entity and entity then
    local c = cities.of_entity(entity)
    return c and c.id or nil
  end
  if cities then return nil end
  return entity and entity.force.name or force_name
end

--- Cities of a force: {{id, name (LocalisedString), position}, ...} (the capital first).
function districts.cities(force_name)
  local cities = ages.cities()
  local list = {}
  if cities and cities.for_force then
    for _, c in pairs(cities.for_force(force_name) or {}) do
      local name = cities.display_name and cities.display_name(c) or c.name or {"rts.city-unnamed", c.id}
      list[#list + 1] = {id = c.id, name = name, position = c.position}
    end
    local n = storage.nations and storage.nations[force_name]
    local capital = n and n.capital
    table.sort(list, function(a, b)
      if (a.id == capital) ~= (b.id == capital) then return a.id == capital end
      return tostring(a.id) < tostring(b.id)
    end)
    return list
  end
  local cap = ages.capital(force_name)
  list[1] = {id = force_name, name = {"rts.city-capital"}, position = cap and cap.position}
  return list
end

--- Force of a city id.
function districts.city_force(city_id)
  local cities = ages.cities()
  if cities and cities.get then
    local c = cities.get(city_id)
    return c and c.force
  end
  return city_id
end

function districts.make_targets(city_id)
  if city_id == nil then return {} end
  local cities = ages.cities()
  if cities then return cities.make_targets(city_id) or {} end
  local t = D().targets[city_id]
  if not t then
    t = {}
    for item, n in pairs(E.default_targets) do t[item] = n end
    D().targets[city_id] = t
  end
  return t
end

--- Set (n > 0) or clear (nil / 0) a make target. Returns true when the item exists.
function districts.set_make_target(city_id, item, n)
  if city_id == nil or not (item and prototypes.item[item]) then return false end
  n = n and math.max(0, math.min(100000, math.floor(tonumber(n) or 0))) or nil
  if n == 0 then n = nil end
  local cities = ages.cities()
  if cities and cities.set_make_target then
    if not cities.set_make_target(city_id, item, n) then return false end
  else
    districts.make_targets(city_id)[item] = n
  end
  util.log("districts: make target %s %s = %s", tostring(city_id), item, tostring(n))
  return true
end

production.auto_active = ages.is_nation
production.targets_of = function(entity)
  local id = districts.city_of(entity)
  return id ~= nil and districts.make_targets(id) or nil
end

---------------------------------------------------------------------------
-- Flows (ledger)
---------------------------------------------------------------------------
local function bucket(city_id)
  local flows = D().flows
  local list = flows[city_id]
  if not list then
    list = {}
    flows[city_id] = list
  end
  local start = game.tick - game.tick % districts.BUCKET_TICKS
  local i = (start / districts.BUCKET_TICKS) % districts.BUCKETS + 1
  local b = list[i]
  if not b or b.start ~= start then
    b = {start = start, made = {}, used = {}}
    list[i] = b
  end
  return b
end

--- Count `count` of `item` made or used ("made" | "used") in a city.
function districts.record(city_id, item, count, dir)
  if city_id == nil or count <= 0 then return end
  local side = bucket(city_id)[dir]
  side[item] = (side[item] or 0) + count
end

production.on_flow = function(rec, item, count, dir)
  if not ages.is_nation() then return end
  local e = rec.entity
  if not (e and e.valid) then return end
  districts.record(districts.city_of(e), item, count, dir)
end

function districts.flows(city_id)
  local out = {made = {}, used = {}}
  local list = D().flows[city_id]
  if not list then return out end
  local from = game.tick - districts.BUCKET_TICKS * districts.BUCKETS
  for _, b in pairs(list) do
    if b.start > from then
      for item, n in pairs(b.made) do out.made[item] = (out.made[item] or 0) + n end
      for item, n in pairs(b.used) do out.used[item] = (out.used[item] or 0) + n end
    end
  end
  return out
end

-- Smelters are belt-fed (no network pull): their crafts are counted from products_finished.
local function sample_smelters()
  local seen = D().smelters
  for un, rec in buildings.all("smelter") do
    local e = rec.entity
    local pf = e.products_finished
    local last = seen[un]
    seen[un] = pf
    if last and pf > last then
      local recipe = e.get_recipe() or e.previous_recipe
      local rname = recipe and recipe.name
      if rname and type(rname) ~= "string" then rname = rname.name end
      local r = rname and prototypes.recipe[rname]
      if r then
        local city = districts.city_of(e)
        local n = pf - last
        for _, p in ipairs(r.products) do
          if p.type == "item" then districts.record(city, p.name, (p.amount or 1) * n, "made") end
        end
        for _, ing in ipairs(r.ingredients) do
          if ing.type == "item" then districts.record(city, ing.name, ing.amount * n, "used") end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Pumpjacks
---------------------------------------------------------------------------
local function drain(rec)
  local e = rec.entity
  local amount = e.get_fluid_count(districts.CRUDE)
  local n = math.floor(amount / districts.CRUDE_PER_ITEM)
  if n <= 0 then return end
  local net = production.network_for(e)
  if not net then
    if rec.pump_state ~= "no network" then
      rec.pump_state = "no network"
      util.log("districts: pumpjack #%d (%s) at %s has no logistic network", e.unit_number, rec.force,
        util.pos_str(e.position))
    end
    return
  end
  local put = net.insert({name = districts.CRUDE_ITEM, count = n})
  if put > 0 then
    e.remove_fluid({name = districts.CRUDE, amount = put * districts.CRUDE_PER_ITEM})
    rec.pump_state = "pumping"
    rec.pumped = (rec.pumped or 0) + put
    local st = D().stats[rec.force] or {crude = 0}
    D().stats[rec.force] = st
    st.crude = st.crude + put
    if production.on_flow then production.on_flow(rec, districts.CRUDE_ITEM, put, "made") end
  end
end

events.on_nth_tick(districts.PUMP_PERIOD, function()
  if not storage.buildings then return end
  for _, rec in buildings.all("pumpjack") do drain(rec) end
end)

events.on_nth_tick(districts.SMELTER_PERIOD, function()
  if not (storage.buildings and ages.is_nation()) then return end
  sample_smelters()
end)

buildings.on_removed(function(un)
  local st = storage.districts
  if st and st.smelters then st.smelters[un] = nil end
end)

match.on_teardown(function()
  local st = D()
  st.targets, st.flows, st.smelters, st.stats = {}, {}, {}, {}
end)

---------------------------------------------------------------------------
-- Ledger rows and hints
---------------------------------------------------------------------------
-- {[item] = count} of the logistic networks of a city (the shim: every CC and hub network of the force).
function districts.stock(city_id)
  local out = {}
  local force_name = districts.city_force(city_id)
  if not force_name then return out end
  local seen = {}
  local cities = ages.cities()
  local function add(net)
    if net and net.valid and not seen[net.network_id] then
      seen[net.network_id] = true
      for _, item in pairs(net.get_contents()) do out[item.name] = (out[item.name] or 0) + item.count end
    end
  end
  for _, rec in buildings.for_force(force_name) do
    if rec.kind == "cc" or rec.kind == "hub" then
      local e = rec.entity
      if not cities or districts.city_of(e) == city_id then add(e.logistic_network) end
    end
  end
  return out
end

-- Recipes (rts-*) that make an item: {LuaRecipePrototype, ...} (static, cached).
local makers_cache = {}
local function makers(item)
  local list = makers_cache[item]
  if list then return list end
  list = {}
  for _, r in pairs(prototypes.recipe) do
    if string.sub(r.name, 1, 4) == "rts-" and not r.hidden then
      for _, p in ipairs(r.products) do
        if p.name == item then list[#list + 1] = r break end
      end
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  makers_cache[item] = list
  return list
end

-- Phase 5 M1 integration: the city could make `name` itself from its stock (an enabled recipe whose ingredients it
-- holds, or could make in turn one level down): such an ingredient is not what it lacks (an advanced-circuit row said
-- "needs [copper cable]: made nowhere" while copper plates lay in stock).
local function can_make(force, stock, name, depth)
  for _, r in ipairs(makers(name)) do
    local fr = force.recipes[r.name]
    if fr and fr.enabled then
      local ok = true
      for _, ing in ipairs(r.ingredients) do
        if ing.type == "item" and (stock[ing.name] or 0) < ing.amount
           and not (depth < 1 and can_make(force, stock, ing.name, depth + 1)) then
          ok = false
          break
        end
      end
      if ok then return true end
    end
  end
  return false
end

-- Phase 5 M1 integration: {[item] = true} made by the current recipes of the city's factories and districts.
local function city_products(city_id, force_name)
  local out = {}
  for _, rec in buildings.for_force(force_name) do
    if (rec.kind == "factory" or rec.kind == "district") and rec.entity.valid then
      local r = rec.entity.get_recipe()
      if r and districts.city_of(rec.entity, force_name) == city_id then
        for _, p in ipairs(r.products) do out[p.name] = true end
      end
    end
  end
  return out
end

--- Why a city cannot make enough of `item`: the first ingredient of its recipes that the city neither holds nor
--- makes nor could make from its stock, nor has a make target or a producer's recipe for, and the other city of the
--- force that made or holds it (nil = nowhere). nil when nothing is missing.
function districts.hint(city_id, item, stock, flows)
  stock = stock or districts.stock(city_id)
  flows = flows or districts.flows(city_id)
  local force_name = districts.city_force(city_id)
  local force = force_name and game.forces[force_name]
  if not force then return nil end
  local targets, products = districts.make_targets(city_id), nil
  local function planned(name) -- the city already plans to make it: a make target or a producer set to it
    if (targets[name] or 0) > 0 then return true end
    products = products or city_products(city_id, force_name)
    return products[name] == true
  end
  for _, r in ipairs(makers(item)) do
    local fr = force.recipes[r.name]
    if fr and fr.enabled then
      for _, ing in ipairs(r.ingredients) do
        if ing.type == "item" and (stock[ing.name] or 0) < ing.amount and (flows.made[ing.name] or 0) == 0
           and not can_make(force, stock, ing.name, 0) and not planned(ing.name) then
          for _, c in ipairs(districts.cities(force_name)) do
            if c.id ~= city_id then
              local other = districts.flows(c.id)
              local ostock = districts.stock(c.id)
              if (other.made[ing.name] or 0) > 0 or (ostock[ing.name] or 0) > 0 then
                return {item = ing.name, city = c.id}
              end
            end
          end
          return {item = ing.name, city = nil}
        end
      end
      return nil
    end
  end
  return nil
end

--- Ledger rows of a city: {item, stock, made, used, target, short, hint} for the listed goods.
function districts.ledger(city_id)
  local stock = districts.stock(city_id)
  local flows = districts.flows(city_id)
  local targets = districts.make_targets(city_id)
  local force_name = districts.city_force(city_id)
  local items, seen = {}, {}
  local function add(item)
    if not seen[item] and prototypes.item[item] then
      seen[item] = true
      items[#items + 1] = item
    end
  end
  for _, item in ipairs(districts.LEDGER_ITEMS) do add(item) end
  if force_name and ages.of(force_name) >= 2 then
    for _, item in ipairs(districts.LEDGER_ITEMS_AGE2) do add(item) end
  end
  local extra = {}
  for item in pairs(targets) do extra[#extra + 1] = item end
  for item in pairs(flows.made) do extra[#extra + 1] = item end
  for item in pairs(flows.used) do extra[#extra + 1] = item end
  table.sort(extra)
  for _, item in ipairs(extra) do add(item) end
  local rows = {}
  for _, item in ipairs(items) do
    local t = targets[item]
    local short = t and math.max(0, t - (stock[item] or 0)) or 0
    local row = {item = item, stock = stock[item] or 0, made = flows.made[item] or 0, used = flows.used[item] or 0,
                 target = t, short = short}
    if short > 0 and (flows.made[item] or 0) == 0 then row.hint = districts.hint(city_id, item, stock, flows) end
    if t or row.stock > 0 or row.made > 0 or row.used > 0 then rows[#rows + 1] = row end
  end
  return rows
end

--- Debug line: "<city>: targets [...] made/min [...] used/min [...]".
function districts.describe(city_id)
  local f = districts.flows(city_id)
  local function fmt(t)
    local parts = {}
    for item, n in pairs(t) do parts[#parts + 1] = string.format("%s=%d", item, n) end
    table.sort(parts)
    return table.concat(parts, " ")
  end
  return string.format("city %s: targets [%s] made/min [%s] used/min [%s]", tostring(city_id),
    fmt(districts.make_targets(city_id)), fmt(f.made), fmt(f.used))
end

return districts
