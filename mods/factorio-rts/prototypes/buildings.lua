-- Phase 2 building prototypes: the Command Center composite and the economy/military buildings.
-- Each building is a deep copy of a vanilla entity with an rts- name, vanilla graphics, its own stats and
-- an icon tinted to tell it apart from the vanilla original. Items are in items.lua, recipes in recipes.lua.
-- Belts, inserters and poles are not cloned: the vanilla transport-belt, fast-inserter and
-- medium-electric-pole (entities and items) are reused, and the factory crafts their vanilla items.
-- See docs/PHASE2.md ("Economic model") and docs/qa/phase2-prototypes-notes.md.
-- Phase 4 adds the laser turret, wall, steam plant, accumulator and radar (docs/qa/phase4-content-notes.md).
-- Health comes from balance.lua (balance.buildings[name].health).
local balance = require("balance")
local RAID_MASK = {"common", balance.raid_target_type} -- "common" is every building's default mask

local ICON_TINT = {r = 1.0, g = 0.8, b = 0.55, a = 1}
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}

local function tinted_icons(src)
  if src.icons then
    local icons = table.deepcopy(src.icons)
    for _, layer in pairs(icons) do layer.tint = ICON_TINT end
    return icons
  end
  return {{icon = src.icon, icon_size = src.icon_size, tint = ICON_TINT}}
end

-- spec: type, source (vanilla name), name, health (default balance.buildings[name].health), map_color,
--       minable (default true: mined into the rts item of the same name),
--       raid_target (true: raiders deal bonus damage to it, see balance.raid_target_type).
-- Names and descriptions come from the locale (entity-name.<name>, entity-description.<name> in
-- locale/*/factorio-rts.cfg): both are reset to the defaults so nothing is inherited from the vanilla source.
local function clone(spec)
  local src = data.raw[spec.type][spec.source]
  assert(src, "factorio-rts: missing vanilla " .. spec.type .. " " .. spec.source)
  local e = table.deepcopy(src)
  e.name = spec.name
  e.localised_name = nil
  e.localised_description = nil
  e.icons = tinted_icons(src)
  e.icon = nil
  e.icon_size = nil
  local bal = balance.buildings[spec.name]
  e.max_health = spec.health or (bal and bal.health) or e.max_health
  e.map_color = spec.map_color
  e.enemy_map_color = ENEMY_MAP_COLOR
  -- Keep RTS buildings out of vanilla upgrade/fast-replace chains (e.g. assembler-2 -> assembler-3).
  e.next_upgrade = nil
  e.fast_replaceable_group = nil
  e.factoriopedia_simulation = nil -- vanilla simulations place the vanilla entity
  if spec.raid_target then e.trigger_target_mask = table.deepcopy(RAID_MASK) end
  if spec.minable == false then
    e.minable = nil
  else
    e.minable = {mining_time = src.minable and src.minable.mining_time or 0.5, result = spec.name}
  end
  return e
end

-- Immune to every damage type: splash damage aimed at the CC must not kill the invisible parts under it.
-- The match script removes them when the CC dies.
local function immune(e)
  e.resistances = {}
  for damage_type in pairs(data.raw["damage-type"]) do
    e.resistances[#e.resistances + 1] = {type = damage_type, percent = 100}
  end
  e.hide_resistances = true
end

-------------------------------------------------------------------------------
-- Command Center composite: rts-command-center + rts-core-power + rts-core-pole, all at the same position.
-- The match script creates all three; the power core and pole are invisible and sit under the CC.
-------------------------------------------------------------------------------
local CC_MAP_COLOR = {r = 0.2, g = 0.85, b = 1.0}

local cc = clone({
  type = "roboport", source = "roboport", name = "rts-command-center",
  raid_target = true, map_color = CC_MAP_COLOR,
})
-- Not markable by the deconstruction or upgrade planner, so bots never take it down by accident.
cc.flags = {"placeable-player", "player-creation", "not-deconstructable", "not-upgradable"}
cc.is_military_target = true
cc.logistics_radius = 25
-- Beyond this reach (the natural pair lies 48-84 tiles out) the Commander builds ghosts next to it from the CC pool
-- (scripts/commander.lua field supply; lead decision 2026-10-16, instead of a larger radius).
cc.construction_radius = 40
-- Large buffer, but the input is capped so filling it never takes more than half of the core's 4 MW.
cc.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  input_flow_limit = "2MW",
  buffer_capacity = "200MJ",
}
cc.recharge_minimum = "40MJ"
-- 8 charging stations on a circle (the vanilla roboport has 4 fixed charging_offsets, which the engine
-- only reads when charging_station_count is 0).
cc.charging_station_count = 8
cc.charging_distance = 1.6
cc.charging_offsets = nil
cc.surface_conditions = nil -- Space Age adds a pressure condition to the vanilla roboport

-- Free power: an invisible electric-energy-interface under the CC. Cloned from base's
-- hidden-electric-energy-interface, which already has an empty sprite and no selection box.
local core_power = clone({
  type = "electric-energy-interface", source = "hidden-electric-energy-interface", name = "rts-core-power",
  map_color = CC_MAP_COLOR, minable = false,
})
core_power.hidden = true
core_power.hidden_in_factoriopedia = true
core_power.flags = {"placeable-player", "not-blueprintable", "not-deconstructable", "not-upgradable",
                    "not-in-kill-statistics"}
core_power.selectable_in_game = false
core_power.collision_mask = {layers = {}}
core_power.energy_source = {
  type = "electric",
  -- secondary-output: solar ("solar" priority, same tier as primary-output) is drawn first and the
  -- core covers the rest; with primary-output the two would share load in proportion to capacity.
  usage_priority = "secondary-output",
  buffer_capacity = "4MJ",
  input_flow_limit = "0W",   -- never charges from the network
  output_flow_limit = "4MW", -- a steady 4 MW, no burst from the buffer
}
core_power.energy_production = "4MW"
core_power.energy_usage = "0W"
core_power.gui_mode = "none"
immune(core_power)

-- Invisible substation under the CC that carries the core's power: 36x36 supply area. Player poles
-- placed within their own wire reach (9 tiles for a medium pole) auto-connect to it.
local core_pole = clone({
  type = "electric-pole", source = "substation", name = "rts-core-pole",
  map_color = CC_MAP_COLOR, minable = false,
})
core_pole.hidden = true
core_pole.hidden_in_factoriopedia = true
core_pole.flags = {"placeable-player", "not-blueprintable", "not-deconstructable", "not-upgradable",
                   "not-in-kill-statistics"}
core_pole.selectable_in_game = false
core_pole.collision_mask = {layers = {}}
core_pole.supply_area_distance = 18
core_pole.maximum_wire_distance = 30
core_pole.pictures = nil -- no sprite; copper wires still attach at the vanilla connection points
core_pole.water_reflection = nil
immune(core_pole)

-------------------------------------------------------------------------------
-- Economy
-------------------------------------------------------------------------------
local stockpile = clone({
  type = "logistic-container", source = "storage-chest", name = "rts-stockpile",
  raid_target = true, map_color = {r = 0.6, g = 0.6, b = 0.85},
})
stockpile.logistic_mode = "storage"
stockpile.inventory_size = 48

local extractor = clone({
  type = "mining-drill", source = "electric-mining-drill", name = "rts-extractor",
  raid_target = true, map_color = {r = 0.3, g = 0.65, b = 0.45},
})
extractor.mining_speed = 1.0
extractor.energy_usage = "90kW"
extractor.module_slots = 0

local smelter = clone({
  type = "furnace", source = "electric-furnace", name = "rts-smelter",
  raid_target = true, map_color = {r = 0.8, g = 0.55, b = 0.3},
})
smelter.crafting_speed = 2
smelter.energy_usage = "180kW"
smelter.module_slots = 0

local solar = clone({
  type = "solar-panel", source = "solar-panel", name = "rts-solar-array",
  raid_target = true, map_color = {r = 0.25, g = 0.4, b = 0.7},
})
solar.production = "400kW"

-- Assembler clones with their own crafting categories only, no modules and no fluid boxes.
local function rts_assembler(spec, categories)
  local a = clone(spec)
  a.crafting_categories = categories
  a.crafting_speed = 1
  a.module_slots = 0
  a.fluid_boxes = nil
  a.fluid_boxes_off_when_no_fluid_recipe = nil
  return a
end

local factory = rts_assembler({
  type = "assembling-machine", source = "assembling-machine-2", name = "rts-factory",
  raid_target = true, map_color = {r = 0.45, g = 0.55, b = 0.8},
}, {"rts-buildings", "rts-intermediates"}) -- Phase 4: gears, cable, circuits, explosives

-------------------------------------------------------------------------------
-- Military and defense
-------------------------------------------------------------------------------
local barracks = rts_assembler({
  type = "assembling-machine", source = "assembling-machine-2", name = "rts-barracks",
  raid_target = true, map_color = {r = 0.9, g = 0.8, b = 0.25},
}, {"rts-units"})
barracks.is_military_target = true

local turret = clone({
  type = "ammo-turret", source = "gun-turret", name = "rts-turret",
  map_color = {r = 0.95, g = 0.55, b = 0.15},
})
turret.is_military_target = true
-- Balance (2026-10-15, docs/qa/phase2-prototypes-notes.md "Turret balance"): ammo_category stays "bullet" (vanilla
-- firearm-magazine, 5 physical damage per round, 10 rounds per magazine). Vanilla fires every 6 ticks, so 10
-- magazines lasted 10 s. Here a round every 36 ticks (100 rounds = 60 s of continuous fire) at 5x damage
-- (25 per round, ~42 damage/s): 8 rounds kill a 200 hp walker (~4.2 s), 24 rounds a 600 hp heavy (~14 s).
turret.attack_parameters.cooldown = 36
turret.attack_parameters.damage_modifier = 5
-- Balance pass (docs/qa/phase4-balance-notes.md): range 21 (vanilla 18), so walkers (range 20) cannot outrange it.
turret.attack_parameters.range = balance.buildings["rts-turret"].range

-------------------------------------------------------------------------------
-- Phase 4: defence and power
-------------------------------------------------------------------------------
-- Laser turret: power-hungry (800 kJ per shot, 2 MW peak input, 24 kW drain), no ammo. The vanilla beam deals
-- 10 laser damage per shot, so damage_modifier = damage / 10.
local LASER = balance.buildings["rts-laser-turret"]
local laser = clone({
  type = "electric-turret", source = "laser-turret", name = "rts-laser-turret",
  map_color = {r = 0.95, g = 0.3, b = 0.35},
})
laser.is_military_target = true
laser.energy_source = {
  type = "electric",
  usage_priority = "primary-input",
  buffer_capacity = "801kJ", -- one shot
  input_flow_limit = LASER.power,
  drain = "24kW",
}
laser.attack_parameters.range = LASER.range
laser.attack_parameters.cooldown = LASER.cooldown
laser.attack_parameters.damage_modifier = LASER.damage / 10
laser.attack_parameters.ammo_type.action.action_delivery.max_length = LASER.range + 2

-- Stone wall: 1 brick each (the recipe makes 5 from 5 bricks). No resistances: the vanilla wall's (explosion
-- decrease 10 / 30 %, physical 3 / 20 %, acid 80 %) made it nearly immune to raiders (0.2 per 8-damage shot) and
-- heavies; with 500 health a walker breaks a segment in 25 s and artillery in 5 shells.
local wall = clone({
  type = "wall", source = "stone-wall", name = "rts-wall",
  map_color = {r = 0.55, g = 0.55, b = 0.5},
})
wall.resistances = nil

-- Steam plant: one burner generator (vanilla hidden burner-generator with steam-engine graphics, 3x5) that burns
-- coal (any chemical fuel) from its fuel slots and outputs 1.8 MW. Fed by inserter or by script; 1.8 MW at 100 %
-- effectivity burns 0.45 coal/s.
local STEAM = balance.buildings["rts-steam-plant"]
local steam = clone({
  type = "burner-generator", source = "burner-generator", name = "rts-steam-plant",
  raid_target = true, map_color = {r = 0.55, g = 0.45, b = 0.35},
})
steam.hidden = nil
steam.hidden_in_factoriopedia = nil
steam.max_power_output = STEAM.power
steam.burner.fuel_categories = {"chemical"}
steam.burner.effectivity = 1
steam.burner.fuel_inventory_size = 2
steam.burner.emissions_per_minute = nil -- no pollution cloud (enemies are off; it would only cost UPS)
steam.energy_source = {type = "electric", usage_priority = "secondary-output"} -- same tier as the CC core

local accumulator = clone({
  type = "accumulator", source = "accumulator", name = "rts-accumulator",
  raid_target = true, map_color = {r = 0.4, g = 0.5, b = 0.6},
})

-- Radar: keeps a square of (2 * reveal_chunks + 1)^2 chunks around it charted and visible; no slow far scan.
local RADAR = balance.buildings["rts-radar"]
local radar = clone({
  type = "radar", source = "radar", name = "rts-radar",
  raid_target = true, map_color = {r = 0.5, g = 0.75, b = 0.55},
})
radar.max_distance_of_nearby_sector_revealed = RADAR.reveal_chunks
radar.max_distance_of_sector_revealed = RADAR.reveal_chunks
radar.connects_to_other_radars = false
radar.is_military_target = true

-- Raiders also deal bonus damage to the vanilla medium electric pole, which the RTS reuses as its pole.
data.raw["electric-pole"]["medium-electric-pole"].trigger_target_mask = table.deepcopy(RAID_MASK)

data:extend({cc, core_power, core_pole, stockpile, extractor, smelter, solar, factory, barracks, turret,
             laser, wall, steam, accumulator, radar})
