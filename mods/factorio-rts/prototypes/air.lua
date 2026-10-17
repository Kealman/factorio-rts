-- Phase 5 M3 air (docs/PHASE5-M3.md D4, section 3 "air.lua"; docs/qa/phase5-air-notes.md): planes, the airfield, the
-- anti-air turret, their kits, items and recipes, the Aviation and Air Force technologies, the Y key, and the target
-- masks that make planes air units. Nation mode only: every recipe starts disabled and the technologies exist in Nation
-- mode only (scripts/air.lua registers them with scripts/research.lua, which enables the recipes when they are
-- researched); the HUD hides the items outside Nation mode (scripts/hud.lua P4.NATION_ONLY). Loaded from
-- data-updates.lua after prototypes/age2.lua (its helpers) and after every data.lua turret and building, because it
-- edits their masks.
--
--   rts-scout-plane, rts-bomber, rts-interceptor
--       `unit`s with an empty collision mask (they fly over water, cliffs and walls: docs/research/scale/
--       war-ai-performance.md 1.2), drawn on the air-object layer with combat-robot graphics (base game, both variants)
--       lifted 1.5 tiles over their shadow, not slowed by tiles, 60 % physical resistance (and immune to territory
--       attrition, rts-attrition: they have their own supply), trigger target types
--       "common" and "air" (balance.target_types.air). Numbers from balance.units[name]. The scout is unarmed (its
--       attack never hurts and its vision is 1 tile, so it is never distracted); the bomber drops bombs (x2 against
--       "structure", every RTS building); the interceptor's gun deals x3 against "air".
--   rts-airfield     6x6 simple-entity-with-owner (the cargo landing pad's graphics at 0.75) made by the factory
--   rts-aa-turret    the RTS gun turret on magazines, attack_target_mask = {"air"}: it shoots planes and nothing else
--   masks            every other rts-* turret (gun, laser, bunker, fort, garrison and any later one) gets
--                    ignore_target_mask = {"air"}; every entity named in balance.buildings carries "structure"
local balance = require("balance")
local age2 = require("prototypes.age2")
local A = balance.nation.air
local TT = balance.target_types
local U = balance.units

local AIR, STRUCTURE = TT.air, TT.structure
local RAID = balance.raid_target_type
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}
local WALKER_SPEED = 0.19 -- tiles per tick of the walker (11.5 tiles/s); balance speeds are relative to it
local LIFT = 1.5          -- tiles the plane's body is drawn above its position (the shadow stays on the ground)

local function by_pixel(x, y) return {x / 32, y / 32} end

-------------------------------------------------------------------------------
-- Planes
-------------------------------------------------------------------------------
-- {robot graphics source, scale factor, tint of the body, tint of the mask layer}
local LOOKS = {
  ["rts-scout-plane"] = {robot = "defender", scale = 1.25, body = {r = 0.85, g = 0.95, b = 1, a = 1},
                         mask = {r = 0.35, g = 0.75, b = 1, a = 1}},
  ["rts-bomber"] = {robot = "destroyer", scale = 1.5, body = {r = 0.75, g = 0.75, b = 0.65, a = 1},
                    mask = {r = 0.9, g = 0.6, b = 0.2, a = 1}},
  ["rts-interceptor"] = {robot = "destroyer", scale = 1.0, body = {r = 1, g = 0.85, b = 0.85, a = 1},
                         mask = {r = 0.95, g = 0.3, b = 0.25, a = 1}},
}

-- Copy of a combat robot's rotated animation, scaled, lifted (non-shadow layers) and tinted.
local function robot_layers(anim, look, shadow)
  local out = {}
  for _, layer in ipairs(anim.layers or {anim}) do
    local l = table.deepcopy(layer)
    l.scale = (l.scale or 1) * look.scale
    local s = l.shift or {0, 0}
    local sx, sy = (s[1] or s.x or 0) * look.scale, (s[2] or s.y or 0) * look.scale
    if shadow then
      l.shift = {sx + LIFT * 0.6, sy + LIFT * 0.3}
    else
      l.shift = {sx, sy - LIFT}
      local file = l.filename or ""
      if l.apply_runtime_tint or file:find("mask", 1, true) then
        l.apply_runtime_tint = nil -- units take no force colour at run time (prototypes/units.lua, the drone)
        l.tint = look.mask
      else
        l.tint = look.body
      end
    end
    out[#out + 1] = l
  end
  return out
end

local function plane_animation(look)
  local robot = data.raw["combat-robot"][look.robot]
  assert(robot, "factorio-rts: missing vanilla combat robot " .. look.robot)
  local layers = robot_layers(robot.in_motion, look, false)
  for _, l in ipairs(robot_layers(robot.shadow_in_motion, look, true)) do layers[#layers + 1] = l end
  return {layers = layers}
end

local function resistances(stats)
  local r = {}
  for damage_type, percent in pairs(stats.resist or {}) do r[#r + 1] = {type = damage_type, percent = percent} end
  table.sort(r, function(a, b) return a.type < b.type end)
  return r
end

-- x mult damage against entities carrying a target type: a nested area of radius 0.5 around the hit (a "direct" trigger
-- ignores trigger_target_mask; the same construction as prototypes/units.lua's bonus_effects)
local function bonus_effects(stats, effects)
  local keys = {}
  for key in pairs(stats.bonus or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local mult = stats.bonus[key]
    if mult > 1 then
      effects[#effects + 1] = {type = "nested-result", action = {
        type = "area", radius = 0.5, force = "enemy", ignore_collision_condition = true,
        trigger_target_mask = {(assert(TT[key], "unknown target type " .. key))},
        action_delivery = {type = "instant", target_effects = {{type = "damage",
          damage = {amount = stats.damage * (mult - 1), type = stats.damage_type}}}},
      }}
    end
  end
  return effects
end

local function plane_attack(name, anim)
  local stats = U[name]
  if (stats.range or 0) <= 0 then
    -- the scout: unarmed. A unit needs an attack; this one reaches 0.5 tiles, fires once in 10 s and does nothing.
    return {type = "projectile", range = 0.5, cooldown = 600, ammo_category = "rts-interceptor", animation = anim,
            ammo_type = {target_type = "entity", action = {type = "direct", action_delivery = {
              type = "instant", target_effects = {{type = "create-entity", entity_name = "explosion-hit"}}}}}}
  end
  local effects
  if name == "rts-bomber" then
    effects = {
      {type = "create-entity", entity_name = "big-explosion"},
      {type = "damage", damage = {amount = stats.damage, type = stats.damage_type}},
      {type = "nested-result", action = {type = "area", radius = stats.splash, force = "enemy", action_delivery = {
        type = "instant", target_effects = {{type = "damage", damage = {amount = stats.splash_damage,
                                                                        type = stats.damage_type}}}}}},
    }
  else
    effects = {
      {type = "create-entity", entity_name = "explosion-hit", offset_deviation = {{-0.3, -0.3}, {0.3, 0.3}}},
      {type = "damage", damage = {amount = stats.damage, type = stats.damage_type}},
    }
  end
  bonus_effects(stats, effects)
  local gun = data.raw.gun["submachine-gun"]
  return {
    type = "projectile",
    ammo_category = stats.ammo_category,
    cooldown = stats.cooldown,
    range = stats.range,
    animation = anim,
    sound = name == "rts-interceptor" and gun and table.deepcopy(gun.attack_parameters.sound) or nil,
    ammo_type = {target_type = "entity", action = {type = "direct", action_delivery = {
      type = "instant",
      source_effects = name == "rts-interceptor" and {{type = "create-explosion", entity_name = "explosion-gunshot"}}
        or nil,
      target_effects = effects,
    }}},
  }
end

local function define_plane(name)
  local stats = U[name]
  local look = LOOKS[name]
  local robot = data.raw["combat-robot"][look.robot]
  local src = data.raw.unit["rts-drone"]
  assert(src, "factorio-rts: rts-drone must exist before prototypes/air.lua")
  local p = table.deepcopy(src)
  p.name = name
  p.localised_name = {"entity-name." .. name}
  p.localised_description = {"entity-description." .. name}
  p.icons = {{icon = robot.icon, icon_size = robot.icon_size or 64, tint = look.mask}}
  p.icon = nil
  p.icon_size = nil
  p.order = "z[rts]-" .. name
  p.max_health = stats.health
  p.healing_per_tick = 0
  p.resistances = resistances(stats)
  -- planes have their own supply: territory attrition (scripts/territory.lua, a ground rule) does not touch them
  if data.raw["damage-type"]["rts-attrition"] then p.resistances[#p.resistances + 1] = {type = "rts-attrition", percent = 100} end
  p.trigger_target_mask = {"common", AIR}
  local s = stats.size
  p.collision_box = {{-s, -s}, {s, s}}
  p.collision_mask = {layers = {}} -- flies: nothing on the ground blocks it (and planes never block each other)
  p.selection_box = {{-s - 0.2, -s - 0.2 - LIFT}, {s + 0.2, s + 0.2 - LIFT}}
  p.sticker_box = {{-s, -s - LIFT}, {s, s - LIFT}}
  p.hit_visualization_box = {{-0.1, -0.1 - LIFT}, {0.1, 0.1 - LIFT}}
  p.render_layer = "air-object"
  p.affected_by_tiles = false
  p.has_belt_immunity = true
  p.movement_speed = WALKER_SPEED * stats.speed
  p.distance_per_frame = 0.5
  p.rotation_speed = 0.04
  p.vision_distance = (stats.range or 0) > 0 and math.max(30, stats.range + 10) or 1
  p.radar_range = name == "rts-scout-plane" and 2 or 1 -- chunks charted around it (players' forces)
  p.distraction_cooldown = 30
  p.min_pursue_time = 300
  p.max_pursue_distance = 40
  p.is_military_target = true
  local anim = plane_animation(look)
  p.run_animation = anim
  p.attack_parameters = plane_attack(name, table.deepcopy(anim))
  p.alternative_attacking_frame_sequence = nil
  p.running_sound_animation_positions = nil
  p.walking_sound = nil
  p.warcry = nil
  p.working_sound = robot.working_sound and table.deepcopy(robot.working_sound) or nil
  p.dying_sound = nil
  p.water_reflection = nil
  p.damaged_trigger_effect = robot.damaged_trigger_effect and table.deepcopy(robot.damaged_trigger_effect) or nil
  p.dying_explosion = robot.dying_explosion or "explosion"
  p.corpse = nil
  p.loot = nil
  p.absorptions_to_join_attack = nil
  p.ai_settings = {destroy_when_commands_fail = false, allow_try_return_to_spawner = false, do_separation = true,
                   join_attacks = false, path_resolution_modifier = 0, size_in_group = 1}
  p.map_color = {0.35, 0.65, 1}
  p.friendly_map_color = {0.35, 0.65, 1}
  p.enemy_map_color = {1, 0.15, 0.1}
  local kit = {
    type = "item",
    name = stats.kit,
    localised_name = {"item-name." .. stats.kit},
    localised_description = {"item-description." .. stats.kit},
    icons = table.deepcopy(p.icons),
    subgroup = "rts-units",
    order = "i[air]-" .. name,
    stack_size = 10,
    auto_recycle = false,
  }
  local recipe = age2.recipe(stats.kit, {category = "rts-units", cost = stats.cost, results = {[stats.kit] = 1},
                                         time = stats.time, order = "i-" .. name}, "rts-units")
  data:extend({p, kit, recipe})
end

for _, name in ipairs(A.planes) do define_plane(name) end

-------------------------------------------------------------------------------
-- Airfield
-------------------------------------------------------------------------------
local AF = A.airfield
local AF_TINT = {r = 0.85, g = 0.9, b = 0.8, a = 1}
local AF_SCALE = AF.size / 8 -- the cargo landing pad is 8x8

local function airfield_picture()
  local pad = data.raw["cargo-landing-pad"] and data.raw["cargo-landing-pad"]["cargo-landing-pad"]
  local parts = pad and pad.graphics_set and pad.graphics_set.picture
  local layers = {}
  for _, part in ipairs(parts or {}) do
    for _, layer in ipairs(part.layers or {part}) do
      if layer.filename or layer.filenames then
        local l = table.deepcopy(layer)
        l.scale = (l.scale or 1) * AF_SCALE
        local s = l.shift or {0, 0}
        l.shift = {(s[1] or s.x or 0) * AF_SCALE, (s[2] or s.y or 0) * AF_SCALE}
        if not (l.draw_as_shadow or l.draw_as_glow or l.draw_as_light) then l.tint = AF_TINT end
        layers[#layers + 1] = l
      end
    end
  end
  if #layers == 0 then -- fallback: the rocket silo's platform, as the project site
    layers[1] = {filename = "__base__/graphics/entity/rocket-silo/06-rocket-silo.png", width = 608, height = 596,
                 scale = 0.3, tint = AF_TINT}
  end
  return {layers = layers}
end

local half = AF.size / 2
local airfield = {
  type = "simple-entity-with-owner",
  name = "rts-airfield",
  localised_name = {"entity-name.rts-airfield"},
  localised_description = {"entity-description.rts-airfield"},
  icons = {{icon = "__base__/graphics/icons/cargo-landing-pad.png", icon_size = 64, tint = AF_TINT}},
  flags = {"placeable-neutral", "placeable-player", "player-creation", "not-upgradable"},
  minable = {mining_time = 1, result = "rts-airfield"},
  max_health = AF.health,
  is_military_target = true,
  collision_box = {{-half + 0.1, -half + 0.1}, {half - 0.1, half - 0.1}},
  selection_box = {{-half, -half}, {half, half}},
  render_layer = "lower-object-above-shadow",
  map_color = {r = 0.55, g = 0.7, b = 0.85},
  enemy_map_color = ENEMY_MAP_COLOR,
  trigger_target_mask = {"common", RAID},
  corpse = "big-remnants",
  dying_explosion = "big-explosion",
  picture = airfield_picture(),
}
local airfield_item = age2.building_item(airfield, "cargo-landing-pad", "rts-districts", "g[airfield]", 5)
airfield_item.icons = table.deepcopy(airfield.icons)

-------------------------------------------------------------------------------
-- Anti-air turret
-------------------------------------------------------------------------------
local AA = A.aa_turret
local AA_TINT = {r = 0.6, g = 0.8, b = 1, a = 1}
local tsrc = data.raw["ammo-turret"]["rts-turret"]
assert(tsrc, "factorio-rts: rts-turret must exist before prototypes/air.lua")
local aa = table.deepcopy(tsrc)
aa.name = "rts-aa-turret"
aa.localised_name = {"entity-name.rts-aa-turret"}
aa.localised_description = {"entity-description.rts-aa-turret"}
age2.rescale(aa, 1, AA_TINT)
aa.icons = age2.icon_layers(tsrc, AA_TINT)
aa.icon = nil
aa.icon_size = nil
aa.max_health = AA.health
aa.minable = {mining_time = 0.5, result = "rts-aa-turret"}
aa.attack_target_mask = {AIR}
aa.ignore_target_mask = nil
aa.attack_parameters.range = AA.range
aa.attack_parameters.cooldown = AA.cooldown
aa.attack_parameters.damage_modifier = AA.damage_modifier
aa.map_color = {r = 0.45, g = 0.7, b = 0.95}
aa.next_upgrade = nil
aa.fast_replaceable_group = nil
aa.circuit_connector = nil
aa.circuit_wire_max_distance = nil
aa.is_military_target = true
local aa_item = age2.building_item(aa, "gun-turret", "rts-districts", "h[aa-turret]", 10)
aa_item.icons = table.deepcopy(aa.icons)

local function building_recipe(name, spec, order)
  local ingredients = {}
  for item, amount in pairs(spec.cost) do ingredients[#ingredients + 1] = {type = "item", name = item, amount = amount} end
  table.sort(ingredients, function(a, b) return a.name < b.name end)
  return {type = "recipe", name = name, category = "rts-buildings", subgroup = "rts-districts", order = order,
          enabled = false, hide_from_player_crafting = true, auto_recycle = false, energy_required = spec.time,
          ingredients = ingredients, results = {{type = "item", name = name, amount = 1}}}
end

data:extend({airfield, airfield_item, building_recipe("rts-airfield", AF, "g"),
             aa, aa_item, building_recipe("rts-aa-turret", AA, "h")})

-------------------------------------------------------------------------------
-- Technologies (Nation mode only; scripts/air.lua registers effects, unlocks and the required age)
-------------------------------------------------------------------------------
local techs = {}
for i, t in ipairs(A.techs) do
  techs[#techs + 1] = {
    type = "technology",
    name = t.name,
    localised_name = {"technology-name." .. t.name},
    localised_description = {"technology-description." .. t.name},
    icons = {{icon = "__base__/graphics/technology/" .. t.icon .. ".png", icon_size = 256}},
    prerequisites = t.prerequisites,
    unit = {count = t.count, ingredients = {{t.kit, 1}}, time = 10},
    -- last in tree order: the AI researches "the rest in tree order" (ai/tech.lua) and never builds an airfield
    order = string.format("z[rts]-9-air-%d", i),
  }
end
data:extend(techs)

-- Y: the airfield panel (scripts/airgui.lua through scripts/hud.lua's P4.KEYS)
data:extend({{type = "custom-input", name = "rts-airfield-panel", key_sequence = "Y", consuming = "game-only",
              order = "z[rts]-m3-air"}})

-------------------------------------------------------------------------------
-- Masks
-------------------------------------------------------------------------------
-- Ground turrets never aim at planes: every rts-* turret but the AA turret ignores "air".
for _, type_name in ipairs({"ammo-turret", "electric-turret", "fluid-turret", "turret"}) do
  local names = {}
  for name in pairs(data.raw[type_name] or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if name:sub(1, 4) == "rts-" and name ~= "rts-aa-turret" then
      local t = data.raw[type_name][name]
      local mask = {}
      for _, m in ipairs(t.ignore_target_mask or {}) do if m ~= AIR then mask[#mask + 1] = m end end
      mask[#mask + 1] = AIR
      t.ignore_target_mask = mask
    end
  end
end

-- Every RTS building carries "structure" (the bomber's x2). An entity without a mask has its type's default, which is
-- {"common"} for every building type (core/prototypes/utility-constants.lua default_trigger_target_mask_by_type).
local ENTITY_TYPES = {}
if defines and defines.prototypes and defines.prototypes.entity then
  for type_name in pairs(defines.prototypes.entity) do ENTITY_TYPES[#ENTITY_TYPES + 1] = type_name end
else -- the building types RTS buildings use
  ENTITY_TYPES = {"accumulator", "ammo-turret", "assembling-machine", "container", "electric-energy-interface",
    "electric-turret", "furnace", "generator", "lab", "logistic-container", "mining-drill", "radar", "roboport",
    "simple-entity-with-owner", "solar-panel", "train-stop", "wall"}
end
table.sort(ENTITY_TYPES)
local building_names = {}
for name in pairs(balance.buildings) do building_names[#building_names + 1] = name end
table.sort(building_names)
for _, name in ipairs(building_names) do
  for _, type_name in ipairs(ENTITY_TYPES) do
    local e = data.raw[type_name] and data.raw[type_name][name]
    if e then
      local mask, seen = {}, {}
      for _, m in ipairs(e.trigger_target_mask or {"common"}) do
        if not seen[m] then
          seen[m] = true
          mask[#mask + 1] = m
        end
      end
      if not seen[STRUCTURE] then mask[#mask + 1] = STRUCTURE end
      e.trigger_target_mask = mask
    end
  end
end
