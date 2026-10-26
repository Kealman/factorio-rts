-- 0.1.2 (issue #30): the player's manual in the game. One table keyed by entity name: the family of the entity and,
-- in locale/<lang>/help.cfg [rts-help], a "how it works" text (<name>-how) and a tip (<name>-tip). Everything with a
-- number comes from balance.lua and the prototypes (help.facts), so it never goes stale: costs, health, power, radii,
-- recipes of a machine's crafting categories (what it takes and makes), the unit stats.
--
-- Pure data and queries; scripts/helpgui.lua draws the card. help.missing() lists the visible rts-* entities that have
-- no entry (the headless check: "[rts] help: N entries, 0 entities without help text" at init and in the debug probe);
-- tools/locale-probe/help-check.py checks that every entry has its EN and RU texts.
--
-- Families: base (robot bases and storage), building, housing, power, defence, district, train, unit, resource, part
-- (invisible helper pieces), piece (belts, inserters, poles, rails: vanilla entities the player builds).
local balance = require("balance")
local util = require("scripts.util")

local help = {}

local ENTRIES = {
  ["fast-inserter"] = "piece",
  ["long-handed-inserter"] = "piece",
  ["medium-electric-pole"] = "piece",
  ["rts-aa-turret"] = "defence",
  ["rts-accumulator"] = "power",
  ["rts-airfield"] = "building",
  ["rts-apartment"] = "housing",
  ["rts-armoured-car"] = "unit",
  ["rts-armoured-locomotive"] = "train",
  ["rts-armoured-wagon"] = "train",
  ["rts-artillery"] = "unit",
  ["rts-artillery-wagon"] = "train",
  ["rts-bakery"] = "building",
  ["rts-barracks"] = "building",
  ["rts-bomber"] = "unit",
  ["rts-bunker"] = "defence",
  ["rts-cargo-wagon"] = "train",
  ["rts-chemical-plant"] = "building",
  ["rts-city-center"] = "base",
  ["rts-command-center"] = "base",
  ["rts-commander"] = "unit",
  ["rts-construction-wagon"] = "train",
  ["rts-depot"] = "base",
  ["rts-depot-stop"] = "part",
  ["rts-district-chemistry"] = "district",
  ["rts-district-circuits"] = "district",
  ["rts-district-concrete"] = "district",
  ["rts-district-construction"] = "district",
  ["rts-district-electronics"] = "district",
  ["rts-district-electronics2"] = "district",
  ["rts-district-engines"] = "district",
  ["rts-district-munitions"] = "district",
  ["rts-district-petrochem"] = "district",
  ["rts-district-rails"] = "district",
  ["rts-district-science"] = "district",
  ["rts-district-smelting"] = "district",
  ["rts-district-steel"] = "district",
  ["rts-drone"] = "unit",
  ["rts-extractor"] = "building",
  ["rts-factory"] = "building",
  ["rts-farm"] = "building",
  ["rts-field-depot"] = "base",
  ["rts-fishing-hut"] = "building",
  ["rts-fort"] = "defence",
  ["rts-gate"] = "defence",
  ["rts-hauler"] = "unit",
  ["rts-heavy-mk2"] = "unit",
  ["rts-house"] = "housing",
  ["rts-hub"] = "base",
  ["rts-interceptor"] = "unit",
  ["rts-lab"] = "building",
  ["rts-laser-turret"] = "defence",
  ["rts-launch-complex"] = "building",
  ["rts-locomotive"] = "train",
  ["rts-nuclear-plant"] = "power",
  ["rts-project-site"] = "building",
  ["rts-pumpjack"] = "building",
  ["rts-radar"] = "building",
  ["rts-raider"] = "unit",
  ["rts-rail"] = "piece",
  ["rts-rare-diamonds"] = "resource",
  ["rts-rare-extractor"] = "building",
  ["rts-rare-gold"] = "resource",
  ["rts-rare-quartz"] = "resource",
  ["rts-rare-rare-earths"] = "resource",
  ["rts-rare-saltpetre"] = "resource",
  ["rts-rare-tungsten"] = "resource",
  ["rts-refinery"] = "building",
  ["rts-scout-plane"] = "unit",
  ["rts-smelter"] = "building",
  ["rts-solar-array"] = "power",
  ["rts-steam-plant"] = "power",
  ["rts-stockpile"] = "base",
  ["rts-trade-post"] = "building",
  ["rts-troop-wagon"] = "train",
  ["rts-turret"] = "defence",
  ["rts-uranium-ore"] = "resource",
  ["rts-walker"] = "unit",
  ["rts-walker-heavy"] = "unit",
  ["rts-walker-mk2"] = "unit",
  ["rts-wall"] = "defence",
  ["splitter"] = "piece",
  ["straight-rail"] = "piece",
  ["transport-belt"] = "piece",
  ["underground-belt"] = "piece",
}

help.ENTRIES = ENTRIES

-- The five abilities (scripts/abilitygui.lua already carries their full texts in rts.ability-<id>-desc)
help.ABILITIES = {"stim", "shield", "scanner", "artillery", "overcharge"}

-- Prototype names that are never shown to the player and need no card
local function needs_card(name, proto)
  if string.sub(name, 1, 4) ~= "rts-" then return false end
  if proto.hidden then return false end
  local t = proto.type
  return t ~= "spider-leg" and t ~= "projectile" and t ~= "sticker" and t ~= "electric-energy-interface"
end

--- Family of an entity (or ghost) name, or nil when there is no help entry for it.
function help.family(name) return ENTRIES[name] end

--- The visible rts-* entities without a help entry (sorted names).
function help.missing()
  local out = {}
  for name, proto in pairs(prototypes.entity) do
    if needs_card(name, proto) and not ENTRIES[name] then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

--- Log the headless check once per load: "[rts] help: N entries, M entities without help text: ...".
function help.check()
  local missing = help.missing()
  local n = 0
  for _ in pairs(ENTRIES) do n = n + 1 end
  util.log("help: %d entries, %d entities without help text%s", n, #missing,
    #missing > 0 and (": " .. table.concat(missing, ", ")) or "")
  return missing
end

---------------------------------------------------------------------------
-- Generated facts
---------------------------------------------------------------------------
local function item_list(list)
  local parts = {}
  for _, ing in ipairs(list) do
    parts[#parts + 1] = string.format("[%s=%s] %d", ing.type == "fluid" and "fluid" or "item", ing.name,
      ing.amount or ing.amount_min or 1)
  end
  return table.concat(parts, "  ")
end

local function recipe_in_category(recipe, category)
  local ok, yes = pcall(recipe.has_category, category)
  return ok and yes
end

local MAX_ICONS = 8     -- icons in a Takes / Makes line
local MAX_RECIPES = 8   -- a machine with more recipes (factory, barracks) is described by its text, not listed

--- The recipes a machine of this prototype can make (its crafting categories), hidden ones skipped, sorted by order
--- then name.
local function machine_recipes(proto)
  local categories = proto.crafting_categories
  if not categories then return {} end
  local list = {}
  for _, recipe in pairs(prototypes.recipe) do
    if not recipe.hidden then
      for category in pairs(categories) do
        if recipe_in_category(recipe, category) then
          list[#list + 1] = recipe
          break
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  return list
end

--- "[item=a] [item=b]" of the distinct ingredient (or product) names of the recipes, in first-seen order.
local function distinct_icons(recipes, products)
  local seen, parts = {}, {}
  for _, r in ipairs(recipes) do
    for _, x in ipairs(products and r.products or r.ingredients) do
      local key = x.type .. "=" .. x.name
      if not seen[key] and #parts < MAX_ICONS then
        seen[key] = true
        parts[#parts + 1] = string.format("[%s=%s]", x.type == "fluid" and "fluid" or "item", x.name)
      end
    end
  end
  return table.concat(parts, " ")
end

--- The generated lines of the card for entity `name`: {takes = {localised...}, makes = {...}, ranges = {...},
--- needs = {...}, stats = {...}} (each a list of localised strings). Numbers come from balance and the prototype.
function help.facts(name)
  local f = {takes = {}, makes = {}, ranges = {}, needs = {}, stats = {}}
  local proto = prototypes.entity[name]
  if not proto then return f end
  local family = ENTRIES[name]
  local B = balance.buildings[name] or (balance.nation and balance.nation.economy and balance.nation.economy.buildings
    and balance.nation.economy.buildings[name]) or {}
  local U = balance.units[name]
  local recipe = prototypes.recipe[name]
  if U then
    local hp = U.health and math.floor(U.health + 0.5)
    if U.damage and U.range then
      f.stats[#f.stats + 1] = {"rts-help.card-unit", hp or "?", U.damage, string.format("%.1f", (U.cooldown or 60) / 60),
        U.range, U.supply or 0}
    else
      f.stats[#f.stats + 1] = {"rts-help.card-unit-noattack", hp or "?", U.supply or 0}
    end
    if U.cost then
      local list = {}
      for item, n in pairs(U.cost) do list[#list + 1] = {type = "item", name = item, amount = n} end
      table.sort(list, function(a, b) return a.name < b.name end)
      f.stats[#f.stats + 1] = {"", {"rts-help.card-cost"}, ": ", item_list(list)}
    end
    return f
  end
  if recipe and family ~= "resource" then
    f.stats[#f.stats + 1] = {"", {"rts-help.card-cost"}, ": ", item_list(recipe.ingredients)}
  end
  local ok, hp = pcall(proto.get_max_health)
  if ok and hp and hp > 0 and family ~= "resource" and family ~= "piece" then
    f.stats[#f.stats + 1] = {"", {"rts-help.card-health"}, ": ", math.floor(hp + 0.5)}
  end
  -- ranges
  if proto.logistic_radius and proto.logistic_radius > 0 then
    f.ranges[#f.ranges + 1] = {"rts-help.card-logistic-radius", proto.logistic_radius, proto.construction_radius or 0}
  end
  local range = proto.attack_parameters and proto.attack_parameters.range
  if range and range > 0 and proto.type ~= "unit" then
    f.ranges[#f.ranges + 1] = {"rts-help.card-turret-range", math.floor(range + 0.5)}
  elseif B.range then
    f.ranges[#f.ranges + 1] = {"rts-help.card-turret-range", B.range}
  end
  -- power
  local okp, usage = pcall(proto.get_max_energy_usage)
  if okp and usage and usage > 0 then
    f.needs[#f.needs + 1] = {"rts-help.card-power-use", string.format("%d", math.floor(usage * 60 / 1000 + 0.5))}
  end
  local okm, make = pcall(proto.get_max_energy_production)
  if okm and make and make > 0 and (family == "power") then
    f.ranges[#f.ranges + 1] = {"rts-help.card-power-make", string.format("%d", math.floor(make * 60 / 1000 + 0.5))}
  end
  -- network and workers
  if family == "building" or family == "district" or family == "power" or family == "defence" or family == "housing"
     or family == "base" then
    f.needs[#f.needs + 1] = {"rts-help.card-needs-network"}
  end
  local jobs = balance.nation and balance.nation.people and balance.nation.people.jobs
  local kind = B.kind
  local n = jobs and ((kind and jobs.kind and jobs.kind[kind]) or (jobs.building and jobs.building[name])
    or (family == "district" and jobs.kind and jobs.kind.district))
  if n and n > 0 then f.needs[#f.needs + 1] = {"rts-help.card-workers", n} end
  -- mining
  if proto.type == "mining-drill" and proto.mining_speed and name == "rts-extractor" then
    f.makes[#f.makes + 1] = {"rts-help.card-mining", string.format("%.1f", proto.mining_speed)}
  end
  -- crafting machines: what they take and make (machines with many recipes are described by their text)
  if proto.crafting_categories and family ~= "unit" then
    local list = machine_recipes(proto)
    if #list > 0 and #list <= MAX_RECIPES then
      f.takes[#f.takes + 1] = distinct_icons(list, false)
      f.makes[#f.makes + 1] = distinct_icons(list, true)
    end
  end
  return f
end

return help
