-- Phase 5 M2 war prototypes (docs/PHASE5-M2.md section 3 "warsupply.lua / capture.lua / garrison.lua";
-- docs/qa/phase5-war-notes.md). Nation mode only: every recipe starts disabled and scripts/warsupply.lua enables it per
-- force in a Nation match (the troop wagon kit with the Railways technology); in Skirmish the HUD hides them
-- (scripts/hud.lua P4.NATION_ONLY).
--
--   rts-supply-crate       the item divisions are resupplied with (1 crate = 10 supply points). Two factory recipes:
--                          rts-supply-crate (Age I: 4 iron plates + 2 coal) and rts-supply-crate-ii (Age II, replaces
--                          it: also 1 explosives); both make the same crate.
--   rts-field-depot        a small forward depot the Commander builds (roboport clone, a hub subtype: logistics.lua
--                          completes it with power, a pole and the pair of stockpiles that hold its crates; it keeps 20
--                          crates by default, so haulers and trains feed it like any hub)
--   rts-troop-wagon        cargo wagon clone with one slot: its troops travel as records (scripts/garrison.lua);
--                          made from rts-troop-wagon-kit (factory, Railways)
--   rts-garrison-turret    hidden gun turret around a City Center, one enabled per 4 garrison points
--                          (scripts/garrison.lua); invisible, not selectable, no collision, ammo topped up by script
local balance = require("balance")
local W = balance.nation and balance.nation.war
assert(W, "factorio-rts: balance.nation.war is missing")

local CRATE_TINT = {r = 0.75, g = 0.85, b = 0.45, a = 1}
-- 0.1.1 (issue #11): violet; the olive of before read as the City Center's green next to it (both are roboports)
local FIELD_TINT = {r = 0.88, g = 0.7, b = 1, a = 1}
local TROOP_TINT = {r = 0.55, g = 0.75, b = 0.4, a = 1}
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}
local RAID_MASK
if data.raw["trigger-target-type"] and data.raw["trigger-target-type"][balance.raid_target_type] then
  RAID_MASK = {"common", balance.raid_target_type}
end

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

local function recipe(name, spec, result, subgroup, order)
  local ingredients = {}
  for item, amount in pairs(spec.cost) do ingredients[#ingredients + 1] = {type = "item", name = item, amount = amount} end
  table.sort(ingredients, function(a, b) return a.name < b.name end)
  return {
    type = "recipe",
    name = name,
    categories = {"rts-buildings"}, -- 2.1: RecipePrototype::category -> categories
    subgroup = subgroup,
    order = order,
    enabled = false, -- scripts/warsupply.lua enables them per force in Nation mode
    hide_from_player_crafting = true,
    auto_recycle = false,
    energy_required = spec.time,
    ingredients = ingredients,
    results = {{type = "item", name = result or name, amount = spec.count or 1}},
  }
end

-------------------------------------------------------------------------------
-- Supply crate
-------------------------------------------------------------------------------
local crate = {
  type = "item",
  name = "rts-supply-crate",
  icons = {{icon = "__base__/graphics/icons/wooden-chest.png", icon_size = 64, tint = CRATE_TINT}},
  subgroup = "rts-war",
  order = "a[crate]",
  stack_size = 50,
  auto_recycle = false,
}
-- Own subgroup: the hub panel lists the items of its POLICY_SUBGROUPS in every mode; a crate shows there only once a
-- network holds some (Nation mode)
local subgroup = {type = "item-subgroup", name = "rts-war", group = "rts", order = "g"}
local crate_recipe = recipe("rts-supply-crate", W.crate, "rts-supply-crate", "rts-war", "a")
local crate2_recipe = recipe("rts-supply-crate-ii", W.crate2, "rts-supply-crate", "rts-war", "b")
crate2_recipe.icons = {{icon = "__base__/graphics/icons/wooden-chest.png", icon_size = 64, tint = CRATE_TINT},
                       {icon = "__base__/graphics/icons/explosives.png", icon_size = 64, scale = 0.25,
                        shift = {8, 8}}}
crate2_recipe.localised_name = {"recipe-name.rts-supply-crate-ii"}

-------------------------------------------------------------------------------
-- Field depot (a hub subtype)
-------------------------------------------------------------------------------
local field = table.deepcopy(data.raw.roboport.roboport)
field.name = "rts-field-depot"
field.localised_name = nil
field.localised_description = nil
field.icons = tinted_icons(data.raw.roboport.roboport, FIELD_TINT)
field.icon = nil
field.icon_size = nil
field.max_health = W.field_depot.health
field.map_color = {r = 0.6, g = 0.8, b = 0.35}
field.enemy_map_color = ENEMY_MAP_COLOR
field.next_upgrade = nil
field.fast_replaceable_group = nil
field.factoriopedia_simulation = nil
field.surface_conditions = nil
field.minable = {mining_time = 0.5, result = "rts-field-depot"}
field.flags = {"placeable-player", "player-creation", "not-deconstructable", "not-upgradable"}
field.is_military_target = true
field.trigger_target_mask = RAID_MASK and table.deepcopy(RAID_MASK) or nil
field.logistics_radius = 8
field.logistics_connection_distance = nil
field.construction_radius = 12
field.radar_range = 1
field.energy_source = {type = "electric", usage_priority = "secondary-input", input_flow_limit = "100kW",
                       buffer_capacity = "10MJ"}
field.recharge_minimum = "2MJ"
field.energy_usage = "10kW"
field.charging_energy = "50kW"
for _, key in pairs({"base", "base_patch", "base_animation", "door_animation_up", "door_animation_down"}) do
  tint_layers(field[key], FIELD_TINT)
end

local field_item = table.deepcopy(data.raw.item.roboport)
field_item.name = "rts-field-depot"
field_item.localised_name = nil
field_item.localised_description = {"entity-description.rts-field-depot"}
field_item.icons = table.deepcopy(field.icons)
field_item.icon = nil
field_item.icon_size = nil
field_item.place_result = "rts-field-depot"
field_item.subgroup = "rts-economy"
field_item.order = "a-e[field-depot]"
field_item.stack_size = 10
field_item.auto_recycle = false

-------------------------------------------------------------------------------
-- Troop wagon
-------------------------------------------------------------------------------
local wagon = table.deepcopy(data.raw["cargo-wagon"]["cargo-wagon"])
wagon.name = "rts-troop-wagon"
wagon.localised_name = nil
wagon.localised_description = nil
wagon.icons = tinted_icons(data.raw["cargo-wagon"]["cargo-wagon"], TROOP_TINT)
wagon.icon = nil
wagon.icon_size = nil
wagon.minable = nil -- rolling stock comes from kits and goes back into kits by script (scripts/rails.lua)
wagon.next_upgrade = nil
wagon.fast_replaceable_group = nil
wagon.factoriopedia_simulation = nil
wagon.is_military_target = true
wagon.trigger_target_mask = RAID_MASK and table.deepcopy(RAID_MASK) or nil
wagon.chunk_exploration_radius = 1
wagon.allow_manual_color = true
wagon.color = {r = 0.45, g = 0.65, b = 0.3, a = 0.9}
wagon.map_color = {r = 0.45, g = 0.7, b = 1}
wagon.enemy_map_color = ENEMY_MAP_COLOR
wagon.max_health = W.troop_wagon.health
wagon.inventory_size = 1

local wagon_kit = {
  type = "item",
  name = "rts-troop-wagon-kit",
  icons = {{icon = "__base__/graphics/icons/cargo-wagon.png", icon_size = 64, tint = TROOP_TINT}},
  subgroup = "rts-war",
  order = "k[train]-d",
  stack_size = 10,
  auto_recycle = false,
}
local wagon_kit_recipe = recipe("rts-troop-wagon-kit", W.troop_wagon_kit, "rts-troop-wagon-kit", "rts-war", "k-d")

-------------------------------------------------------------------------------
-- Hidden garrison turret
-------------------------------------------------------------------------------
local EMPTY = {filename = "__core__/graphics/empty.png", size = 1, direction_count = 1, frame_count = 1}
local G = W.garrison
local turret = table.deepcopy(data.raw["ammo-turret"]["gun-turret"])
turret.name = "rts-garrison-turret"
turret.localised_name = nil
turret.localised_description = nil
turret.icons = tinted_icons(data.raw["ammo-turret"]["gun-turret"], FIELD_TINT)
turret.icon = nil
turret.icon_size = nil
turret.hidden = true
turret.hidden_in_factoriopedia = true
turret.flags = {"placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-upgradable",
                "not-in-kill-statistics", "no-automated-item-removal", "no-automated-item-insertion"}
turret.selectable_in_game = false
turret.collision_mask = {layers = {}}
turret.collision_box = {{-0.2, -0.2}, {0.2, 0.2}}
turret.selection_box = {{-0.2, -0.2}, {0.2, 0.2}}
turret.minable = nil
turret.next_upgrade = nil
turret.fast_replaceable_group = nil
turret.factoriopedia_simulation = nil
turret.is_military_target = false
turret.corpse = nil
turret.dying_explosion = nil
turret.max_health = 5000
turret.map_color = nil
turret.graphics_set = {}
for _, key in pairs({"folded_animation", "preparing_animation", "prepared_animation", "prepared_alternative_animation",
                     "starting_attack_animation", "attacking_animation", "ending_attack_animation", "folding_animation",
                     "energy_glow_animation", "resource_indicator_animation"}) do
  if turret[key] ~= nil or key == "folded_animation" then turret[key] = table.deepcopy(EMPTY) end
end
turret.integration = nil
turret.water_reflection = nil
-- the RTS turret's balance (prototypes/buildings.lua): a round every 36 ticks at 5x damage
turret.attack_parameters.cooldown = 36
turret.attack_parameters.damage_modifier = 5
turret.attack_parameters.range = (balance.buildings["rts-turret"] and balance.buildings["rts-turret"].range or 21)
turret.call_for_help_radius = 0

data:extend({
  subgroup, crate, crate_recipe, crate2_recipe,
  field, field_item, recipe("rts-field-depot", W.field_depot, "rts-field-depot", "rts-economy", "a-e"),
  wagon, wagon_kit, wagon_kit_recipe,
  turret,
})
