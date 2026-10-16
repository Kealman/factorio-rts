-- Phase 5 M1 (docs/PHASE5-M1.md "Territory + City Centers"): Nation-mode prototypes.
--
--   rts-attrition      damage type of territory attrition (scripts/territory.lua). No resistance lists it.
--   rts-city-center    City Center of a new city: a roboport like the hub, CC-grey with a green tint, 1800 HP,
--                      logistic radius 16, construction radius 30. It is a hub subtype (buildings kind "hub"), so
--                      scripts/logistics.lua completes it like a hub (rts-hub-power 300 kW, rts-hub-pole, 2 stockpiles,
--                      10 construction + 6 logistic robots, a full buffer); scripts/cities.lua adds rts-city-power
--                      (700 kW) under it, so the city core gives 1 MW.
--   rts-city-power     hidden electric-energy-interface, 700 kW secondary output (as rts-hub-power)
--   rts-city-charter   the City Center's item ("City charter"), made by the factory (Age I recipe), placed as a ghost
--                      and built by the Commander or robots like a hub.
--   rts-fort           cheap strongpoint: a gun turret (firearm magazines) with 600 HP; a small territory source.
-- Costs and health come from balance.lua (balance.nation.cities.charter, balance.buildings["rts-fort" / "rts-city-
-- center"]). Names: locale/*/cities.cfg. The recipes are enabled for every force; in Skirmish the HUD hides them (the
-- build menu and the factory grid show them in Nation mode only, scripts/hud.lua P4.NATION_ONLY).
local balance = require("balance")

local CITY_TINT = {r = 0.78, g = 1.0, b = 0.7, a = 1}
local ICON_TINT = {r = 0.7, g = 1.0, b = 0.6, a = 1}
local FORT_TINT = {r = 0.85, g = 0.75, b = 0.55, a = 1}
local CITY_MAP_COLOR = {r = 0.45, g = 1.0, b = 0.5}
local FORT_MAP_COLOR = {r = 0.75, g = 0.6, b = 0.35}
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}
local RAID_MASK = {"common", balance.raid_target_type}

local function tinted_icons(src, tint)
  if src.icons then
    local icons = table.deepcopy(src.icons)
    for _, layer in pairs(icons) do layer.tint = tint end
    return icons
  end
  return {{icon = src.icon, icon_size = src.icon_size, tint = tint}}
end

local function tint_layers(t, tint)
  if type(t) ~= "table" then return end
  if (t.filename or t.filenames or t.stripes) and not t.draw_as_shadow then t.tint = tint end
  for _, v in pairs(t) do
    if type(v) == "table" then tint_layers(v, tint) end
  end
end

local function immune(e)
  e.resistances = {}
  for damage_type in pairs(data.raw["damage-type"]) do
    e.resistances[#e.resistances + 1] = {type = damage_type, percent = 100}
  end
  e.hide_resistances = true
end

local function recipe(name, cost, time, order)
  local ingredients = {}
  for item, amount in pairs(cost) do ingredients[#ingredients + 1] = {type = "item", name = item, amount = amount} end
  table.sort(ingredients, function(a, b) return a.name < b.name end)
  return {
    type = "recipe",
    name = name,
    category = "rts-buildings",
    subgroup = "rts-economy",
    order = order,
    enabled = true,
    hide_from_player_crafting = true,
    auto_recycle = false,
    energy_required = time,
    ingredients = ingredients,
    results = {{type = "item", name = name, amount = 1}},
  }
end

data:extend({{type = "damage-type", name = "rts-attrition"}})

-------------------------------------------------------------------------------
-- City Center
-------------------------------------------------------------------------------
local CITY = balance.buildings["rts-city-center"]
local city = table.deepcopy(data.raw.roboport.roboport)
city.name = "rts-city-center"
city.localised_name = nil
city.localised_description = nil
city.icons = tinted_icons(data.raw.roboport.roboport, ICON_TINT)
city.icon = nil
city.icon_size = nil
city.max_health = CITY.health
city.map_color = CITY_MAP_COLOR
city.enemy_map_color = ENEMY_MAP_COLOR
city.next_upgrade = nil
city.fast_replaceable_group = nil
city.factoriopedia_simulation = nil
city.surface_conditions = nil
city.minable = {mining_time = 1, result = "rts-city-charter"}
city.flags = {"placeable-player", "player-creation", "not-deconstructable", "not-upgradable"}
city.is_military_target = true
city.trigger_target_mask = table.deepcopy(RAID_MASK)
city.logistics_radius = 16
city.logistics_connection_distance = nil
city.construction_radius = 30
city.radar_range = 2
city.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  input_flow_limit = "500kW",
  buffer_capacity = "40MJ",
}
city.recharge_minimum = "8MJ"
city.energy_usage = "40kW"
city.charging_energy = "100kW"
for _, key in pairs({"base", "base_patch", "base_animation", "door_animation_up", "door_animation_down"}) do
  tint_layers(city[key], CITY_TINT)
end

local city_power = table.deepcopy(data.raw["electric-energy-interface"]["hidden-electric-energy-interface"])
city_power.name = "rts-city-power"
city_power.icons = tinted_icons(data.raw.roboport.roboport, ICON_TINT)
city_power.icon = nil
city_power.icon_size = nil
city_power.map_color = CITY_MAP_COLOR
city_power.hidden = true
city_power.hidden_in_factoriopedia = true
city_power.flags = {"placeable-player", "not-blueprintable", "not-deconstructable", "not-upgradable",
                    "not-in-kill-statistics"}
city_power.selectable_in_game = false
city_power.collision_mask = {layers = {}}
city_power.minable = nil
city_power.localised_name = nil
city_power.localised_description = nil
city_power.factoriopedia_simulation = nil
city_power.energy_source = {
  type = "electric",
  usage_priority = "secondary-output",
  buffer_capacity = "700kJ",
  input_flow_limit = "0W",
  output_flow_limit = "700kW",
}
city_power.energy_production = "700kW"
city_power.energy_usage = "0W"
city_power.gui_mode = "none"
immune(city_power)

local charter = table.deepcopy(data.raw.item.roboport)
charter.name = "rts-city-charter"
charter.localised_name = nil
charter.localised_description = {"item-description.rts-city-charter"}
charter.icons = table.deepcopy(city.icons)
charter.icon = nil
charter.icon_size = nil
charter.place_result = "rts-city-center"
charter.subgroup = "rts-economy"
charter.order = "a-c[city-charter]"
charter.stack_size = 5
charter.auto_recycle = false

local C = balance.nation.cities.charter

-------------------------------------------------------------------------------
-- Fort
-------------------------------------------------------------------------------
local FORT = balance.buildings["rts-fort"]
local fort = table.deepcopy(data.raw["ammo-turret"]["gun-turret"])
fort.name = "rts-fort"
fort.localised_name = nil
fort.localised_description = nil
fort.icons = tinted_icons(data.raw["ammo-turret"]["gun-turret"], FORT_TINT)
fort.icon = nil
fort.icon_size = nil
fort.max_health = FORT.health
fort.map_color = FORT_MAP_COLOR
fort.enemy_map_color = ENEMY_MAP_COLOR
fort.next_upgrade = nil
fort.fast_replaceable_group = nil
fort.factoriopedia_simulation = nil
fort.minable = {mining_time = 0.5, result = "rts-fort"}
fort.trigger_target_mask = nil
fort.attack_parameters = table.deepcopy(fort.attack_parameters)
fort.attack_parameters.range = FORT.range
for _, key in pairs({"folded_animation", "preparing_animation", "prepared_animation", "attacking_animation",
                     "folding_animation", "graphics_set"}) do
  tint_layers(fort[key], FORT_TINT)
end

local fort_item = table.deepcopy(data.raw.item["gun-turret"])
fort_item.name = "rts-fort"
fort_item.localised_name = nil
fort_item.localised_description = {"entity-description.rts-fort"}
fort_item.icons = table.deepcopy(fort.icons)
fort_item.icon = nil
fort_item.icon_size = nil
fort_item.place_result = "rts-fort"
fort_item.subgroup = "rts-defense"
fort_item.order = "a-b[fort]"
fort_item.stack_size = 10
fort_item.auto_recycle = false

data:extend({
  city, city_power, charter, fort, fort_item,
  recipe("rts-city-charter", C.cost, C.time, "a-c[city-charter]"),
  recipe("rts-fort", FORT.cost, FORT.time, "a-b[fort]"),
})
data.raw.recipe["rts-fort"].subgroup = "rts-defense"
