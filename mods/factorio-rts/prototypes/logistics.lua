-- Phase 4 logistics prototypes (docs/PHASE4.md 2.1-2.2): the hub composite and the hauler.
--
--   rts-hub        roboport clone: logistic radius 14, construction radius 22, tinted base, own small buffer.
--                  scripts/logistics.lua places the rest of the composite when one is built:
--   rts-hub-power  hidden electric-energy-interface under the hub, 300 kW (the hub plus about two extractors)
--   rts-hub-pole   hidden pole under the hub, 16x16 supply area, wire reach 9 (player poles connect to it)
--                  plus 2 rts-stockpile next to it and 10 construction + 6 logistic robots in it.
--   rts-hauler     small spider-vehicle (create_spidertron at scale 0.6 when base exposes it), 20 usable cargo slots,
--                  no guns, no equipment grid, 400 hp, full damage from everything (raidable), team colour
--                  through LuaEntity.color. Spawned by script from an rts-hauler-kit (factory recipe).
-- Items: rts-hub (placeable), rts-hauler-kit. Recipes (category rts-buildings, the factory): rts-hub 32 iron
-- 10 copper, rts-hauler-kit 30 iron 10 electronic-circuit.
-- Names come from the locale (entity-name.*, item-name.*, recipe-name.* in locale/*/factorio-rts.cfg).
-- The RTS cursor's select filters gain "spider-vehicle" here, so haulers can be box-selected like units.

-- Raiders deal bonus damage to entities with the raid trigger target type (balance.lua, prototypes/categories.lua);
-- the hub and the hauler opt in when that type exists.
local RAID_MASK
do
  local ok, balance = pcall(require, "balance")
  local name = ok and type(balance) == "table" and balance.raid_target_type
  if name and data.raw["trigger-target-type"] and data.raw["trigger-target-type"][name] then
    RAID_MASK = {"common", name}
  end
end

local ICON_TINT = {r = 1.0, g = 0.8, b = 0.55, a = 1}
local HUB_TINT = {r = 1.0, g = 0.86, b = 0.62, a = 1}   -- the hub reads warmer than the grey Command Center
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}
local HUB_MAP_COLOR = {r = 0.35, g = 0.8, b = 0.95}

local function tinted_icons(src, tint)
  if src.icons then
    local icons = table.deepcopy(src.icons)
    for _, layer in pairs(icons) do layer.tint = tint end
    return icons
  end
  return {{icon = src.icon, icon_size = src.icon_size, tint = tint}}
end

-- Tint every sprite layer below `t` that is not a shadow (draw_as_shadow) and has a file.
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

local function hidden_part(e)
  e.hidden = true
  e.hidden_in_factoriopedia = true
  e.flags = {"placeable-player", "not-blueprintable", "not-deconstructable", "not-upgradable", "not-in-kill-statistics"}
  e.selectable_in_game = false
  e.collision_mask = {layers = {}}
  e.minable = nil
  e.next_upgrade = nil
  e.fast_replaceable_group = nil
  e.factoriopedia_simulation = nil
  e.localised_name = nil
  e.localised_description = nil
  immune(e)
end

-------------------------------------------------------------------------------
-- Hub
-------------------------------------------------------------------------------
local hub = table.deepcopy(data.raw.roboport.roboport)
hub.name = "rts-hub"
hub.localised_name = nil
hub.localised_description = nil
hub.icons = tinted_icons(data.raw.roboport.roboport, ICON_TINT)
hub.icon = nil
hub.icon_size = nil
hub.max_health = 1200
hub.map_color = HUB_MAP_COLOR
hub.enemy_map_color = ENEMY_MAP_COLOR
hub.next_upgrade = nil
hub.fast_replaceable_group = nil
hub.factoriopedia_simulation = nil
hub.surface_conditions = nil
hub.minable = {mining_time = 0.5, result = "rts-hub"}
-- Like the CC: not markable by the deconstruction or upgrade planner.
hub.flags = {"placeable-player", "player-creation", "not-deconstructable", "not-upgradable"}
hub.is_military_target = true
hub.trigger_target_mask = RAID_MASK and table.deepcopy(RAID_MASK) or nil
hub.logistics_radius = 14
hub.logistics_connection_distance = nil -- = logistics_radius: two hubs join only when their 28x28 areas touch
hub.construction_radius = 22
hub.radar_range = 1
-- Runs on its own 300 kW core: small buffer, pre-charged by the script on placement, slow robot charging.
hub.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  input_flow_limit = "200kW",
  buffer_capacity = "20MJ",
}
hub.recharge_minimum = "4MJ"
hub.energy_usage = "20kW"
hub.charging_energy = "50kW"
for _, key in pairs({"base", "base_patch", "base_animation", "door_animation_up", "door_animation_down"}) do
  tint_layers(hub[key], HUB_TINT)
end

local hub_power = table.deepcopy(data.raw["electric-energy-interface"]["hidden-electric-energy-interface"])
hub_power.name = "rts-hub-power"
hub_power.icons = tinted_icons(data.raw.roboport.roboport, ICON_TINT)
hub_power.icon = nil
hub_power.icon_size = nil
hub_power.map_color = HUB_MAP_COLOR
hidden_part(hub_power)
hub_power.energy_source = {
  type = "electric",
  usage_priority = "secondary-output", -- solar first, the core covers the rest (as rts-core-power)
  buffer_capacity = "300kJ",
  input_flow_limit = "0W",
  output_flow_limit = "300kW",
}
hub_power.energy_production = "300kW"
hub_power.energy_usage = "0W"
hub_power.gui_mode = "none"

local hub_pole = table.deepcopy(data.raw["electric-pole"]["medium-electric-pole"])
hub_pole.name = "rts-hub-pole"
hub_pole.icons = tinted_icons(data.raw.roboport.roboport, ICON_TINT)
hub_pole.icon = nil
hub_pole.icon_size = nil
hub_pole.map_color = HUB_MAP_COLOR
hidden_part(hub_pole)
hub_pole.supply_area_distance = 8
hub_pole.maximum_wire_distance = 9
hub_pole.pictures = nil
hub_pole.water_reflection = nil
hub_pole.active_picture = nil
hub_pole.light = nil

-------------------------------------------------------------------------------
-- Hauler
-------------------------------------------------------------------------------
local HAULER_SCALE = 0.6
-- Leg speed multiplier (create_spidertron's leg_movement_speed). Spider-vehicles have no speed field: the legs set
-- the pace, and the speed grows slower than the multiplier. Measured over 60 tiles from a standing start against an
-- rts-walker (10.7-10.9 tiles/s) in the logistics autotest (logistics_hauler_speed): 1.6 -> 14.2 tiles/s,
-- 2.7 -> 17.5, 3.2 -> 19.0, 4.0 -> 21.2, 4.8 -> 21.8. 4.4 gives about 2x the walker (docs/PHASE4.md 2.2).
local HAULER_LEG_SPEED = 4.4

if type(create_spidertron) == "function" then
  create_spidertron({name = "rts-hauler", scale = HAULER_SCALE, leg_scale = 1, leg_thickness = 1,
                     leg_movement_speed = HAULER_LEG_SPEED})
else
  -- Fallback: the full-size vanilla spidertron with its own legs.
  local copy = table.deepcopy(data.raw["spider-vehicle"].spidertron)
  copy.name = "rts-hauler"
  data:extend({copy})
end

local hauler = data.raw["spider-vehicle"]["rts-hauler"]
hauler.localised_name = nil
hauler.localised_description = nil
hauler.icons = {{icon = "__base__/graphics/icons/spidertron.png", icon_size = 64, tint = ICON_TINT}}
hauler.icon = nil
hauler.icon_size = nil
hauler.minable = nil
hauler.guns = nil
hauler.equipment_grid = nil
hauler.trash_inventory_size = 0
-- 20 usable slots; scripts/logistics.lua caps loading at BASE_SLOTS plus research (Hauler capacity I: +10).
hauler.inventory_size = 40
hauler.max_health = 400
hauler.resistances = nil -- full damage: raiders and walkers must be able to kill haulers
hauler.healing_per_tick = 0
hauler.chunk_exploration_radius = 1
hauler.allow_remote_driving = false
hauler.allow_passengers = false
hauler.is_military_target = true
hauler.trigger_target_mask = RAID_MASK and table.deepcopy(RAID_MASK) or nil
hauler.factoriopedia_simulation = nil
hauler.corpse = "spidertron-remnants"
hauler.order = "z[rts]-hauler"
hauler.map_color = {r = 0.35, g = 0.65, b = 1}
hauler.friendly_map_color = {r = 0.35, g = 0.65, b = 1}
hauler.enemy_map_color = {r = 1, g = 0.15, b = 0.1}
for _, key in pairs({"minimap_representation", "selected_minimap_representation"}) do
  if hauler[key] then hauler[key].scale = 0.3 end
end
-- Leg names for the locale (entity-name.rts-hauler-leg) and no vanilla leg resistances.
for _, leg in pairs(hauler.spider_engine.legs) do
  local proto = data.raw["spider-leg"][leg.leg]
  if proto and proto.name:find("^rts%-hauler%-leg") then
    proto.localised_name = {"entity-name.rts-hauler-leg"}
    proto.resistances = nil
  end
end

-------------------------------------------------------------------------------
-- Items and recipes
-------------------------------------------------------------------------------
local hub_item = table.deepcopy(data.raw.item.roboport)
hub_item.name = "rts-hub"
hub_item.localised_name = nil
hub_item.localised_description = {"entity-description.rts-hub"}
hub_item.icons = table.deepcopy(hub.icons)
hub_item.icon = nil
hub_item.icon_size = nil
hub_item.place_result = "rts-hub"
hub_item.subgroup = "rts-economy"
hub_item.order = "a-b[hub]"
hub_item.stack_size = 10
hub_item.auto_recycle = false

local hauler_kit = {
  type = "item",
  name = "rts-hauler-kit",
  icons = {{icon = "__base__/graphics/icons/spidertron.png", icon_size = 64, tint = {r = 1, g = 0.85, b = 0.4, a = 1}}},
  subgroup = "rts-units",
  order = "h[hauler-kit]",
  stack_size = 10,
  auto_recycle = false,
}

local function recipe(spec)
  local ingredients = {}
  for name, amount in pairs(spec.cost) do ingredients[#ingredients + 1] = {type = "item", name = name, amount = amount} end
  table.sort(ingredients, function(a, b) return a.name < b.name end)
  return {
    type = "recipe",
    name = spec.name,
    categories = {"rts-buildings"}, -- 2.1: RecipePrototype::category -> categories
    subgroup = spec.subgroup,
    order = spec.order,
    enabled = true,
    hide_from_player_crafting = true,
    auto_recycle = false,
    energy_required = spec.time,
    ingredients = ingredients,
    results = {{type = "item", name = spec.name, amount = 1}},
  }
end

data:extend({
  hub, hub_power, hub_pole, hub_item, hauler_kit,
  recipe({name = "rts-hub", subgroup = "rts-economy", order = "a", time = 8, -- Wave C economy pass: was 40 iron
          cost = {["iron-plate"] = 32, ["copper-plate"] = 10}}),
  recipe({name = "rts-hauler-kit", subgroup = "rts-economy", order = "j", time = 8,
          cost = {["iron-plate"] = 30, ["electronic-circuit"] = 10}}),
})

-------------------------------------------------------------------------------
-- RTS cursor: haulers (spider-vehicles) are selected like units (scripts/selection.lua takes only entities
-- registered in storage.units, so other spider-vehicles stay unselectable).
-------------------------------------------------------------------------------
local cursor = data.raw["selection-tool"]["rts-cursor"]
if cursor then
  for _, mode in pairs({"select", "alt_select"}) do
    local filters = cursor[mode] and cursor[mode].entity_type_filters
    if filters then
      local present = false
      for _, t in pairs(filters) do
        if t == "spider-vehicle" then present = true end
      end
      if not present then filters[#filters + 1] = "spider-vehicle" end
    end
  end
end
