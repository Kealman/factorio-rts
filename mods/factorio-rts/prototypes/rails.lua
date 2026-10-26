-- Phase 5 M1 rails prototypes (docs/PHASE5-M1.md section 3 "rails.lua"; docs/qa/phase5-rails-notes.md).
--
--   rts-depot               roboport clone (a hub subtype: scripts/logistics.lua registers it as kind "hub", so keep /
--                           export policies, the hub panel and haulers work for it). scripts/rails.lua adds a 40-tile
--                           platform of straight rails and two train stops when one is built.
--   rts-depot-stop          train-stop clone used by depot platforms (not minable, not blueprintable)
--   rts-locomotive          vanilla locomotive clone (team colour through LuaEntity.color, raid target)
--   rts-cargo-wagon         vanilla cargo wagon clone (40 slots)
--   rts-construction-wagon  cargo wagon clone with 20 slots: carries the rails a construction train lays
-- Items: rts-depot (placeable), rts-locomotive-kit, rts-cargo-wagon-kit, rts-construction-wagon-kit. scripts/rails.lua
-- turns kits found in a depot network into trains (rails.create_train); rolling stock is never placed by hand.
-- Recipes (category rts-buildings, the factory), all disabled until the Railways technology: rts-depot, the three
-- kits and rts-rail (2 steel + 1 stone -> 2 vanilla "rail" items, so depot robots can build rail ghosts too).
-- 0.1.2 (#31 part A): rts-station (a small roboport hub with a 10-tile logistic area: scripts/rails.lua puts two
-- rts-depot-stop on the own straight track next to it), its item and recipe, and the recipes rts-rail-signal and
-- rts-rail-chain-signal (vanilla items: robots build signal ghosts from the network). All with Railways.
-- Technologies: rts-railways (tier 1, basic kits) and, only with the elevated-rails mod (Space Age), rts-bridges
-- (tier 2): elevated spans for the planner. Effects live in scripts/rails.lua (research.EFFECTS). Both are Nation-only
-- (research.NATION_ONLY), so Skirmish never shows them.
local balance = require("balance")
local R = balance.nation and balance.nation.rails
assert(R, "factorio-rts: balance.nation.rails is missing")

local RAID_MASK
if data.raw["trigger-target-type"] and data.raw["trigger-target-type"][balance.raid_target_type] then
  RAID_MASK = {"common", balance.raid_target_type}
end

local DEPOT_TINT = {r = 0.62, g = 0.82, b = 1.0, a = 1}    -- cool blue: reads apart from the warm hub
local ICON_TINT = {r = 0.62, g = 0.82, b = 1.0, a = 1}
local KIT_TINT = {r = 1.0, g = 0.85, b = 0.4, a = 1}
local CONSTRUCTION_TINT = {r = 1.0, g = 0.7, b = 0.25, a = 1}
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}

local function tinted_icons(src, tint)
  if src.icons then
    local icons = table.deepcopy(src.icons)
    for _, layer in pairs(icons) do layer.tint = tint end
    return icons
  end
  return {{icon = src.icon, icon_size = src.icon_size or 64, tint = tint}}
end

local function tint_layers(t, tint)
  if type(t) ~= "table" then return end
  if (t.filename or t.filenames or t.stripes) and not t.draw_as_shadow then t.tint = tint end
  for _, v in pairs(t) do
    if type(v) == "table" then tint_layers(v, tint) end
  end
end

-------------------------------------------------------------------------------
-- Depot (a hub subtype)
-------------------------------------------------------------------------------
local depot = table.deepcopy(data.raw.roboport.roboport)
depot.name = "rts-depot"
depot.localised_name = nil
depot.localised_description = nil
depot.icons = tinted_icons(data.raw.roboport.roboport, ICON_TINT)
depot.icon = nil
depot.icon_size = nil
depot.max_health = R.depot.health
depot.map_color = {r = 0.45, g = 0.7, b = 1}
depot.enemy_map_color = ENEMY_MAP_COLOR
depot.next_upgrade = nil
depot.fast_replaceable_group = nil
depot.factoriopedia_simulation = nil
depot.surface_conditions = nil
depot.minable = {mining_time = 0.5, result = "rts-depot"}
depot.flags = {"placeable-player", "player-creation", "not-deconstructable", "not-upgradable"}
depot.is_military_target = true
depot.trigger_target_mask = RAID_MASK and table.deepcopy(RAID_MASK) or nil
depot.logistics_radius = 14
depot.logistics_connection_distance = nil
depot.construction_radius = 22
depot.radar_range = 1
depot.energy_source = {type = "electric", usage_priority = "secondary-input", input_flow_limit = "200kW",
                       buffer_capacity = "20MJ"}
depot.recharge_minimum = "4MJ"
depot.energy_usage = "20kW"
depot.charging_energy = "50kW"
for _, key in pairs({"base", "base_patch", "base_animation", "door_animation_up", "door_animation_down"}) do
  tint_layers(depot[key], DEPOT_TINT)
end

-- 0.1.2 (#31 part A): the Station, a small depot without a platform
local STATION_TINT = {r = 0.55, g = 1.0, b = 0.6, a = 1}
local station = table.deepcopy(depot)
station.name = "rts-station"
station.icons = tinted_icons(data.raw.roboport.roboport, STATION_TINT)
station.max_health = R.station.health
station.map_color = {r = 0.45, g = 0.9, b = 0.55}
station.minable = {mining_time = 0.5, result = "rts-station"}
station.logistics_radius = 10
station.construction_radius = 14
for _, key in pairs({"base", "base_patch", "base_animation", "door_animation_up", "door_animation_down"}) do
  tint_layers(station[key], STATION_TINT)
end

local stop = table.deepcopy(data.raw["train-stop"]["train-stop"])
stop.name = "rts-depot-stop"
stop.localised_name = nil
stop.localised_description = nil
stop.icons = tinted_icons(data.raw["train-stop"]["train-stop"], ICON_TINT)
stop.icon = nil
stop.icon_size = nil
stop.minable = nil
stop.flags = {"placeable-neutral", "player-creation", "filter-directions", "not-blueprintable", "not-deconstructable",
              "not-upgradable"}
stop.next_upgrade = nil
stop.fast_replaceable_group = nil
stop.factoriopedia_simulation = nil
stop.max_health = 1000

-------------------------------------------------------------------------------
-- Rolling stock
-------------------------------------------------------------------------------
local function stock(type_name, source, name, spec)
  local e = table.deepcopy(data.raw[type_name][source])
  assert(e, "factorio-rts: missing vanilla " .. type_name .. " " .. source)
  e.name = name
  e.localised_name = nil
  e.localised_description = nil
  e.icons = tinted_icons(data.raw[type_name][source], spec.icon_tint or ICON_TINT)
  e.icon = nil
  e.icon_size = nil
  e.minable = nil -- rolling stock comes from kits and goes back into kits by script (scripts/rails.lua)
  e.next_upgrade = nil
  e.fast_replaceable_group = nil
  e.factoriopedia_simulation = nil
  e.is_military_target = true
  e.trigger_target_mask = RAID_MASK and table.deepcopy(RAID_MASK) or nil
  e.chunk_exploration_radius = 1 -- trains reveal their corridor (fog)
  e.allow_manual_color = true
  e.map_color = {r = 0.45, g = 0.7, b = 1}
  e.enemy_map_color = ENEMY_MAP_COLOR
  for k, v in pairs(spec) do
    if k ~= "icon_tint" then e[k] = v end
  end
  return e
end

local locomotive = stock("locomotive", "locomotive", "rts-locomotive", {max_health = 1000})
local wagon = stock("cargo-wagon", "cargo-wagon", "rts-cargo-wagon", {max_health = 600, inventory_size = 40})
local cwagon = stock("cargo-wagon", "cargo-wagon", "rts-construction-wagon",
                     {max_health = 600, inventory_size = 20, icon_tint = CONSTRUCTION_TINT,
                      color = {r = 1, g = 0.62, b = 0.12, a = 0.9}})

-------------------------------------------------------------------------------
-- Items and recipes
-------------------------------------------------------------------------------
local depot_item = table.deepcopy(data.raw.item.roboport)
depot_item.name = "rts-depot"
depot_item.localised_name = nil
depot_item.localised_description = {"entity-description.rts-depot"}
depot_item.icons = table.deepcopy(depot.icons)
depot_item.icon = nil
depot_item.icon_size = nil
depot_item.place_result = "rts-depot"
depot_item.subgroup = "rts-economy"
depot_item.order = "a-c[depot]"
depot_item.stack_size = 10
depot_item.auto_recycle = false

local function kit(name, icon, order, tint)
  return {
    type = "item",
    name = name,
    icons = {{icon = icon, icon_size = 64, tint = tint or KIT_TINT}},
    subgroup = "rts-units",
    order = order,
    stack_size = 10,
    auto_recycle = false,
  }
end

local function recipe(name, spec, result, count)
  local ingredients = {}
  for item, amount in pairs(spec.cost) do ingredients[#ingredients + 1] = {type = "item", name = item, amount = amount} end
  table.sort(ingredients, function(a, b) return a.name < b.name end)
  return {
    type = "recipe",
    name = name,
    categories = {"rts-buildings"}, -- 2.1: RecipePrototype::category -> categories
    subgroup = spec.subgroup or "rts-economy",
    order = spec.order,
    enabled = false, -- the Railways technology enables these per force (scripts/research.lua, rails.lua EFFECTS)
    hide_from_player_crafting = true,
    auto_recycle = false,
    energy_required = spec.time,
    ingredients = ingredients,
    results = {{type = "item", name = result or name, amount = count or 1}},
  }
end

local with_order = function(spec, subgroup, order)
  local s = {}
  for k, v in pairs(spec) do s[k] = v end
  s.subgroup, s.order = subgroup, order
  return s
end

local station_item = table.deepcopy(depot_item)
station_item.name = "rts-station"
station_item.localised_description = {"entity-description.rts-station"}
station_item.icons = table.deepcopy(station.icons)
station_item.place_result = "rts-station"
station_item.order = "a-c[depot]-b[station]"

data:extend({
  depot, stop, locomotive, wagon, cwagon, depot_item, station, station_item,
  recipe("rts-station", with_order(R.station, "rts-economy", "a-c-b")),
  recipe("rts-rail-signal", with_order(R.signal, "rts-economy", "a-e"), "rail-signal", 1),
  recipe("rts-rail-chain-signal", with_order(R.chain_signal, "rts-economy", "a-f"), "rail-chain-signal", 1),
  kit("rts-locomotive-kit", "__base__/graphics/icons/locomotive.png", "k[train]-a"),
  kit("rts-cargo-wagon-kit", "__base__/graphics/icons/cargo-wagon.png", "k[train]-b"),
  kit("rts-construction-wagon-kit", "__base__/graphics/icons/cargo-wagon.png", "k[train]-c", CONSTRUCTION_TINT),
  recipe("rts-depot", with_order(R.depot, "rts-economy", "a-c")),
  recipe("rts-rail", with_order(R.rail, "rts-economy", "a-d"), "rail", R.rail.count),
  recipe("rts-locomotive-kit", with_order(R.locomotive_kit, "rts-units", "k-a")),
  recipe("rts-cargo-wagon-kit", with_order(R.cargo_wagon_kit, "rts-units", "k-b")),
  recipe("rts-construction-wagon-kit", with_order(R.construction_wagon_kit, "rts-units", "k-c")),
})

-------------------------------------------------------------------------------
-- Technologies (effects: scripts/rails.lua). Tier 1 = basic science kits, tier 2 = advanced (prototypes/research.lua
-- defines the kits in data-updates; references resolve after the data stage).
-------------------------------------------------------------------------------
local TECH_ICON = "__base__/graphics/technology/"
local techs = {
  {
    type = "technology",
    name = "rts-railways",
    localised_name = {"technology-name.rts-railways"},
    localised_description = {"technology-description.rts-railways"},
    icons = {{icon = TECH_ICON .. "railway.png", icon_size = 256}},
    -- Phase 5 M3 integration (balance pass): 10 kits (was 15); first rail lines opened at 20-36 minutes
    unit = {count = 10, ingredients = {{"rts-science-basic", 1}}, time = 10},
    order = "z[rts]-1-30",
  },
}
if mods["elevated-rails"] and data.raw["rail-ramp"] and data.raw["rail-ramp"]["rail-ramp"] then
  techs[#techs + 1] = {
    type = "technology",
    name = "rts-bridges",
    localised_name = {"technology-name.rts-bridges"},
    localised_description = {"technology-description.rts-bridges"},
    icons = {{icon = "__elevated-rails__/graphics/technology/elevated-rail.png", icon_size = 256}},
    prerequisites = {"rts-railways"},
    unit = {count = 20, ingredients = {{"rts-science-advanced", 1}}, time = 10},
    order = "z[rts]-2-30",
  }
end
data:extend(techs)
