-- Phase 5 M3 war2 prototypes (docs/PHASE5-M3.md D5, D6, section 3 "fronts.lua / belts.lua / trainswar.lua";
-- docs/qa/phase5-war2-notes.md). Nation mode only: every recipe starts disabled and research enables it per force
-- (scripts/belts.lua and scripts/trainswar.lua register the effects); Skirmish never shows them (hud.lua
-- P4.NATION_ONLY, research.NATION_ONLY).
--
--   rts-gate                   vanilla gate clone; the fort belt tool puts one on every straight rail its wall crosses
--                              (Fortification)
--   rts-artillery-wagon        vanilla artillery wagon clone that never fires by itself (disable_automatic_firing): its
--                              shells (rts-rail-shell, ammo category rts-rail-shell) sit in its ammo slot and
--                              scripts/trainswar.lua fires them in stance Bombard as rts-rail-shell-projectile, the
--                              artillery strike's projectile class (a grenade-style projectile thrown at a position)
--   rts-armoured-locomotive    rts-locomotive with 3x health and 40 % physical / explosion resistance
--   rts-armoured-wagon         rts-troop-wagon with 3x health and 40 % physical / explosion resistance: an armoured
--                              troop train carries its troops like the M2 troop train (scripts/garrison.lua)
-- Items and factory recipes: rts-gate, rts-artillery-wagon-kit, rts-armoured-locomotive-kit, rts-armoured-wagon-kit,
-- rts-rail-shell. Technologies: rts-fortification (Age I, basic kits: the gate and the fort belt tool) and
-- rts-military-railways (Age II, industrial kits: the artillery wagon, rail shells and armoured stock).
local balance = require("balance")
local TW = balance.nation and balance.nation.trains_war
assert(TW, "factorio-rts: balance.nation.trains_war is missing")

local ARMOUR_TINT = {r = 0.55, g = 0.58, b = 0.62, a = 1}
local ARTY_TINT = {r = 0.85, g = 0.5, b = 0.35, a = 1}
local GATE_TINT = {r = 1.0, g = 0.8, b = 0.55, a = 1} -- the building tint of prototypes/buildings.lua
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

local function recipe(name, spec, subgroup, order, result)
  local ingredients = {}
  for item, amount in pairs(spec.cost) do ingredients[#ingredients + 1] = {type = "item", name = item, amount = amount} end
  table.sort(ingredients, function(a, b) return a.name < b.name end)
  return {
    type = "recipe",
    name = name,
    categories = {"rts-buildings"}, -- 2.1: RecipePrototype::category -> categories
    subgroup = subgroup,
    order = order,
    enabled = false, -- research enables it per force (scripts/belts.lua, scripts/trainswar.lua: research.EFFECTS)
    hide_from_player_crafting = true,
    auto_recycle = false,
    energy_required = spec.time,
    ingredients = ingredients,
    results = {{type = "item", name = result or name, amount = spec.count or 1}},
  }
end

local function kit(name, icon, tint, order, subgroup)
  return {
    type = "item",
    name = name,
    icons = {{icon = icon, icon_size = 64, tint = tint}},
    subgroup = subgroup or "rts-units",
    order = order,
    stack_size = 10,
    auto_recycle = false,
  }
end

-- 40 % physical and explosion resistance (at least), keeping the stock's flat decrease (vanilla rolling stock: 15)
-- and its other resistances. Probe: a plain locomotive takes 59.5 of 100 physical, without the decrease the armoured
-- one took 60.
local function armour(e)
  local out, have = {}, {}
  for _, r in ipairs(e.resistances or {}) do
    if r.type == "physical" or r.type == "explosion" then
      out[#out + 1] = {type = r.type, decrease = r.decrease, percent = math.max(r.percent or 0, TW.resist)}
      have[r.type] = true
    else
      out[#out + 1] = r
    end
  end
  for _, t in ipairs({"physical", "explosion"}) do
    if not have[t] then out[#out + 1] = {type = t, percent = TW.resist} end
  end
  e.resistances = out
end

-------------------------------------------------------------------------------
-- Gate
-------------------------------------------------------------------------------
local gate = table.deepcopy(data.raw.gate.gate)
gate.name = "rts-gate"
gate.localised_name = nil
gate.localised_description = nil
gate.icons = tinted_icons(data.raw.gate.gate, GATE_TINT)
gate.icon = nil
gate.icon_size = nil
gate.max_health = TW.gate.health
gate.minable = {mining_time = 0.1, result = "rts-gate"}
gate.fast_replaceable_group = nil
gate.next_upgrade = nil
gate.factoriopedia_simulation = nil
gate.map_color = {r = 0.55, g = 0.55, b = 0.5}
gate.enemy_map_color = ENEMY_MAP_COLOR

local gate_item = table.deepcopy(data.raw.item.gate)
gate_item.name = "rts-gate"
gate_item.localised_name = nil
gate_item.localised_description = {"entity-description.rts-gate"}
gate_item.icons = table.deepcopy(gate.icons)
gate_item.icon = nil
gate_item.icon_size = nil
gate_item.place_result = "rts-gate"
gate_item.subgroup = "rts-defense"
gate_item.order = "d[wall]-b[gate]"
gate_item.stack_size = 50
gate_item.auto_recycle = false

-------------------------------------------------------------------------------
-- Artillery wagon, its gun, shells and the projectile the script fires
-------------------------------------------------------------------------------
local ammo_category = {type = "ammo-category", name = "rts-rail-shell", hidden = true}

local gun = table.deepcopy(data.raw.gun["artillery-wagon-cannon"])
gun.name = "rts-rail-cannon"
gun.localised_name = nil
gun.attack_parameters.ammo_category = "rts-rail-shell"
gun.attack_parameters.range = TW.range
gun.attack_parameters.min_range = TW.min_range

local shell = table.deepcopy(data.raw.ammo["artillery-shell"])
shell.name = "rts-rail-shell"
shell.localised_name = nil
shell.localised_description = nil
shell.ammo_category = "rts-rail-shell"
shell.subgroup = "rts-war"
shell.order = "k[train]-h[shell]"
shell.stack_size = 50
shell.auto_recycle = false
shell.weight = nil
shell.spoil_result = nil

-- Thrown at a position like the artillery strike's rts-artillery-shell (prototypes/units.lua). Its blast hurts hostile
-- forces only (force "enemy": war is cease-fire off) and only entities whose collision mask has the player, is_object
-- or trigger_target layer: buildings, units and spider-units, but not ground rails and signals (floor, item, object,
-- rail, ...) or belts, so the rails under a bombarded town take nothing (scripts/targeting.lua would undo it and make
-- them indestructible for 10 s; docs/qa/phase5-m2-integration-notes.md section 6 items 2-3). Probe: with the object
-- layer in the mask the rails next to the turret were hit (ground rails collide with "object").
local projectile = table.deepcopy(data.raw.projectile["grenade"])
projectile.name = "rts-rail-shell-projectile"
projectile.localised_name = nil
projectile.acceleration = 0.005
projectile.action = {
  {
    type = "direct",
    action_delivery = {
      type = "instant",
      target_effects = {
        {type = "create-entity", entity_name = "big-explosion"},
        {type = "create-entity", entity_name = "medium-scorchmark-tintable", check_buildability = true},
        {type = "invoke-tile-trigger", repeat_count = 1},
      },
    },
  },
  {
    type = "area",
    radius = TW.shell_radius,
    force = "enemy",
    collision_mask = {layers = {player = true, is_object = true, trigger_target = true}},
    action_delivery = {
      type = "instant",
      target_effects = {
        {type = "damage", damage = {amount = TW.shell_damage, type = "explosion"}},
        {type = "create-entity", entity_name = "explosion"},
      },
    },
  },
}

local function stock_common(e, health)
  e.localised_name = nil
  e.localised_description = nil
  e.minable = nil -- rolling stock comes from kits and goes back into kits by script (scripts/rails.lua)
  e.next_upgrade = nil
  e.fast_replaceable_group = nil
  e.factoriopedia_simulation = nil
  e.is_military_target = true
  e.trigger_target_mask = RAID_MASK and table.deepcopy(RAID_MASK) or nil
  e.chunk_exploration_radius = 1
  e.allow_manual_color = true
  e.map_color = {r = 0.45, g = 0.7, b = 1}
  e.enemy_map_color = ENEMY_MAP_COLOR
  e.max_health = health
end

local wagon = table.deepcopy(data.raw["artillery-wagon"]["artillery-wagon"])
wagon.name = "rts-artillery-wagon"
stock_common(wagon, TW.artillery_wagon_health)
wagon.icons = tinted_icons(data.raw["artillery-wagon"]["artillery-wagon"], ARTY_TINT)
wagon.icon = nil
wagon.icon_size = nil
wagon.gun = "rts-rail-cannon"
wagon.disable_automatic_firing = true
wagon.manual_range_modifier = 1
wagon.inventory_size = 1
wagon.ammo_stack_limit = 50

-------------------------------------------------------------------------------
-- Armoured stock
-------------------------------------------------------------------------------
local loco_src = data.raw.locomotive["rts-locomotive"]
assert(loco_src, "factorio-rts: rts-locomotive must exist before prototypes/war3.lua (prototypes/rails.lua)")
local aloco = table.deepcopy(loco_src)
aloco.name = "rts-armoured-locomotive"
stock_common(aloco, TW.locomotive_health * TW.health_factor)
aloco.icons = tinted_icons(data.raw.locomotive.locomotive, ARMOUR_TINT)
aloco.icon = nil
aloco.icon_size = nil
armour(aloco)
tint_layers(aloco.pictures, ARMOUR_TINT)

local twagon_src = data.raw["cargo-wagon"]["rts-troop-wagon"]
assert(twagon_src, "factorio-rts: rts-troop-wagon must exist before prototypes/war3.lua (prototypes/war.lua)")
local awagon = table.deepcopy(twagon_src)
awagon.name = "rts-armoured-wagon"
stock_common(awagon, TW.troop_wagon_health * TW.health_factor)
awagon.icons = tinted_icons(data.raw["cargo-wagon"]["cargo-wagon"], ARMOUR_TINT)
awagon.icon = nil
awagon.icon_size = nil
awagon.inventory_size = 1
armour(awagon)
tint_layers(awagon.pictures, ARMOUR_TINT)

-------------------------------------------------------------------------------
-- Technologies (effects: scripts/belts.lua and scripts/trainswar.lua through research.EFFECTS)
-------------------------------------------------------------------------------
local TECH_ICON = "__base__/graphics/technology/"
local F, M = TW.techs.fortification, TW.techs.military_railways
local techs = {
  {
    type = "technology",
    name = "rts-fortification",
    localised_name = {"technology-name.rts-fortification"},
    localised_description = {"technology-description.rts-fortification"},
    icons = {{icon = TECH_ICON .. "gate.png", icon_size = 256}},
    unit = {count = F.count, ingredients = {{F.kit, 1}}, time = 10},
    order = "z[rts]-1-40",
  },
  {
    type = "technology",
    name = "rts-military-railways",
    localised_name = {"technology-name.rts-military-railways"},
    localised_description = {"technology-description.rts-military-railways"},
    icons = {{icon = TECH_ICON .. "artillery.png", icon_size = 256}},
    prerequisites = M.prerequisites,
    unit = {count = M.count, ingredients = {{M.kit, 1}}, time = 10},
    order = "z[rts]-3-40",
  },
}

data:extend({
  gate, gate_item, recipe("rts-gate", TW.gate, "rts-defense", "d-b"),
  ammo_category, gun, shell, projectile, wagon, aloco, awagon,
  kit("rts-artillery-wagon-kit", "__base__/graphics/icons/artillery-wagon.png", ARTY_TINT, "k[train]-e"),
  kit("rts-armoured-locomotive-kit", "__base__/graphics/icons/locomotive.png", ARMOUR_TINT, "k[train]-f"),
  kit("rts-armoured-wagon-kit", "__base__/graphics/icons/cargo-wagon.png", ARMOUR_TINT, "k[train]-g"),
  recipe("rts-artillery-wagon-kit", TW.artillery_wagon_kit, "rts-units", "k-e"),
  recipe("rts-armoured-locomotive-kit", TW.armoured_locomotive_kit, "rts-units", "k-f"),
  recipe("rts-armoured-wagon-kit", TW.armoured_wagon_kit, "rts-units", "k-g"),
  recipe("rts-rail-shell", TW.rail_shell, "rts-war", "k-h"),
})
data:extend(techs)
