-- RTS unit prototypes. Numbers (health, damage, range, cooldown) come from balance.lua.
--
--   rts-walker, rts-walker-mk2        ranged line unit (spider-unit)
--   rts-walker-heavy, rts-heavy-mk2   slow brawler (spider-unit)
--   rts-raider                        fast, short range, x3 damage against raid targets (spider-unit)
--   rts-artillery                     slow siege unit: range 40, min range 8, 4-tile splash (spider-unit)
--   rts-drone                         cheap fast melee swarm (unit, medium-biter sprites, neutral tint)
--   rts-commander                     hero spidertron (spider-vehicle), spawned by script; own guns and rockets
--
-- With Space Age loaded the spider-units are copies of the Gleba pentapods (walker / heavy: small strafer / stomper,
-- raider: medium strafer, artillery: medium stomper); without it they are built from the base-game spidertron
-- graphics, so Space Age stays an optional dependency. The drone and the commander use base-game assets only.
-- Ported from spikes/units (spike #3); see docs/research/spikes.md decisions 2, 3 and 9 and
-- docs/qa/phase4-content-notes.md.
local util = require("util")
local balance = require("balance")
local B = balance.units
local RAID = balance.raid_target_type

-- Vision covers the attack range, so a unit acquires targets as far as it can shoot (artillery: 42). It stays below
-- 50: UnitPrototype documents self-grouping of units at vision_distance >= 50.
local function vision(stats) return math.max(30, stats.range + 2) end

-- Spider legs forward the damage they take to the torso, after their own resistances (probe, 2026-10-15).
--  * Base-game mech units: their legs stand 1-3 tiles from the torso, so a 4-tile artillery shell hit one unit once
--    per leg in range (3 hits of 100). Their legs ignore explosions like the vanilla spidertron legs; every other
--    type (drone bites) passes in full. Their own hitscan attacks hit the torso directly.
--  * Pentapods: legs stand 4-8 tiles out and the strafer projectile mostly lands on a leg, so legs must pass
--    explosions on. They get no resistances at all (the originals carry the creature's: drones biting a strafer leg
--    did 7.2 instead of 10).
local MECH_LEG_RESISTANCES = {{type = "explosion", percent = 100}}

-- AI settings for player-like units. The vanilla Gleba settings enable destroy_when_commands_fail and
-- allow_try_return_to_spawner, both wrong for RTS units.
local RTS_AI = {
  destroy_when_commands_fail = false,
  allow_try_return_to_spawner = false,
  do_separation = true,
  join_attacks = false, -- never get pulled into engine-made attack groups
  path_resolution_modifier = 0,
  size_in_group = 1,
}

-- Minimap colours (docs/qa/phase1-hud-notes.md gotcha 8): without map_color the own army is not drawn on
-- the minimap at all; friendly_map_color alone did not help. Own units blue, enemy units red.
local MAP_COLORS = {
  map_color = {0.35, 0.65, 1},
  friendly_map_color = {0.35, 0.65, 1},
  enemy_map_color = {1, 0.15, 0.1},
}

local function set_map_colors(proto)
  for k, v in pairs(MAP_COLORS) do proto[k] = table.deepcopy(v) end
end

local function merge(a, b)
  local r = table.deepcopy(a)
  for k, v in pairs(b or {}) do r[k] = table.deepcopy(v) end
  return r
end

local function file_of(t)
  if type(t.filename) == "string" then return t.filename end
  if type(t.filenames) == "table" and type(t.filenames[1]) == "string" then return t.filenames[1] end
  return nil
end

-- Switch every sprite layer whose file name contains "mask" to the runtime tint, which is the force
-- colour for spider-units (changelog 2.0.63). Returns the number of layers changed.
local function tint_masks(t)
  if type(t) ~= "table" then return 0 end
  local n = 0
  local file = file_of(t)
  if file and file:find("mask", 1, true) then
    t.apply_runtime_tint = true
    t.tint = nil
    t.tint_as_overlay = nil
    n = n + 1
  end
  for _, v in pairs(t) do
    if type(v) == "table" then n = n + tint_masks(v) end
  end
  return n
end

-- Strip trigger effects that spawn wrigglers or apply stickers; optionally override damage amounts.
local function clean_effects(t, damage)
  if type(t) ~= "table" then return end
  for _, key in pairs({"target_effects", "source_effects"}) do
    local eff = t[key]
    if type(eff) == "table" then
      if eff.type then eff = {eff}; t[key] = eff end
      for i = #eff, 1, -1 do
        local e = eff[i]
        if (e.type == "create-entity" and tostring(e.entity_name):find("wriggler", 1, true))
          or e.type == "create-sticker" then
          table.remove(eff, i)
        elseif e.type == "damage" and damage then
          e.damage.amount = damage
        end
      end
    end
  end
  for _, v in pairs(t) do
    if type(v) == "table" then clean_effects(v, damage) end
  end
end

-- A trigger (or list of triggers) as a list.
local function as_list(action)
  if action.type then return {action} end
  return action
end

-- Extra damage that only entities with the raid trigger target type take. Added next to the normal damage, so the
-- total against a raid target is damage * raid_multiplier. It is an "area" trigger around the hit position (radius
-- 1 for projectiles, which explode next to the target; 0.5 for hitscan, which hits its centre): a "direct" trigger
-- ignores trigger_target_mask (probe: walkers and turrets took the bonus too).
local function raid_bonus(spec, damage_type, radius)
  local bonus = spec.damage * ((spec.raid_multiplier or 1) - 1)
  if bonus <= 0 then return nil end
  return {
    type = "area",
    radius = radius,
    force = "enemy",
    ignore_collision_condition = true,
    trigger_target_mask = {RAID},
    action_delivery = {
      type = "instant",
      target_effects = {{type = "damage", damage = {amount = bonus, type = damage_type}}},
    },
  }
end

-- Hitscan ranged attack built from base-game effects only (no Space Age assets).
local function hitscan_attack(spec, damage_type)
  local target_effects = {
    {type = "create-entity", entity_name = "explosion-hit", offsets = {{0, 1}},
     offset_deviation = {{-0.5, -0.5}, {0.5, 0.5}}},
    {type = "damage", damage = {amount = spec.damage, type = damage_type}},
  }
  local bonus = raid_bonus(spec, damage_type, 0.5)
  if bonus then target_effects[#target_effects + 1] = {type = "nested-result", action = bonus} end
  local action = {
    type = "direct",
    action_delivery = {
      type = "instant",
      source_effects = {{type = "create-explosion", entity_name = "explosion-gunshot"}},
      target_effects = target_effects,
    },
  }
  return {
    type = "projectile",
    ammo_category = spec.ammo_category,
    cooldown = spec.cooldown,
    range = spec.range,
    ammo_type = {action = action},
  }
end

-------------------------------------------------------------------------------
-- Artillery shell (both variants): a grenade-style projectile thrown at the target's position, 4-tile splash that
-- spares its own force.
-------------------------------------------------------------------------------
local function define_artillery_shell()
  local spec = B["rts-artillery"]
  local shell = table.deepcopy(data.raw.projectile["grenade"])
  assert(shell, "factorio-rts: missing vanilla projectile grenade")
  shell.name = "rts-artillery-shell"
  shell.localised_name = nil
  shell.acceleration = 0.005
  shell.action = {
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
      radius = spec.splash,
      force = "not-same", -- no friendly fire
      action_delivery = {
        type = "instant",
        target_effects = {
          {type = "damage", damage = {amount = spec.damage, type = spec.damage_type}},
          {type = "create-entity", entity_name = "explosion"},
        },
      },
    },
  }
  data:extend({shell})
end

local function artillery_attack(spec)
  local cannon = data.raw.gun["artillery-wagon-cannon"]
  return {
    type = "projectile",
    ammo_category = spec.ammo_category,
    cooldown = spec.cooldown,
    range = spec.range,
    min_range = spec.min_range,           -- never fires at targets closer than this; the unit backs off instead
    min_attack_distance = spec.range - 6, -- attacks from 34-40 tiles
    sound = cannon and cannon.attack_parameters and table.deepcopy(cannon.attack_parameters.sound) or nil,
    ammo_type = {
      action = {
        type = "direct",
        action_delivery = {
          type = "projectile",
          projectile = "rts-artillery-shell",
          starting_speed = 0.6,
          max_range = spec.range + 10,
        },
      },
    },
  }
end

local ARTILLERY_STRAFE = {
  max_distance = 40, ideal_distance = 32, ideal_distance_tolerance = 4, ideal_distance_variance = 2,
  ideal_distance_importance = 0.5, ideal_distance_importance_variance = 0.1, face_target = true,
}
local RAIDER_STRAFE = {
  max_distance = 14, ideal_distance = 9, ideal_distance_tolerance = 2, ideal_distance_variance = 1,
  ideal_distance_importance = 0.25, ideal_distance_importance_variance = 0.1, face_target = true,
}

-------------------------------------------------------------------------------
-- Variant A (Space Age present): copies of the Gleba pentapods.
-------------------------------------------------------------------------------
local function pentapod_walker(spec)
  local src = data.raw["spider-unit"][spec.source]
  assert(src, "factorio-rts: missing vanilla spider-unit " .. spec.source)
  local stats = B[spec.name]
  local u = table.deepcopy(src)
  u.name = spec.name
  u.localised_name = {"entity-name." .. spec.name}
  u.localised_description = nil
  u.max_health = stats.health
  u.healing_per_tick = 0
  u.factoriopedia_simulation = nil
  u.absorptions_to_join_attack = nil -- spore-based attack joining; irrelevant for scripted units
  u.dying_trigger_effect = nil       -- vanilla spawns wrigglers / stomper shells on death
  -- Full damage from every type, like the base-game variant. The Gleba originals carry physical resistance
  -- (strafer: decrease 2 and 10 %, stomper: decrease 2 and 50 %) plus laser / impact, which turned the turret's
  -- 5-damage bullets into 2.7 / 1.5 per round. The units' own attacks deal explosion / acid damage, so unit-vs-unit
  -- fights are not affected.
  u.resistances = nil
  u.vision_distance = vision(stats)
  u.radar_range = 1                  -- chunks charted around the unit for its force
  u.order = "z[rts]-" .. spec.name
  u.ai_settings = merge(RTS_AI, {
    strafe_settings = spec.strafe_settings or (src.ai_settings and src.ai_settings.strafe_settings),
  })
  if spec.attack then
    u.attack_parameters = spec.attack
  else
    spec.adjust_attack(u.attack_parameters, stats)
    u.attack_parameters.ammo_category = stats.ammo_category
  end

  -- Own leg prototype so the walking speed can be tuned: spider-units have no movement_speed, speed
  -- comes from SpiderLegPrototype.initial_movement_speed / movement_acceleration.
  local legs = u.spider_engine.legs
  if legs.leg then legs = {legs}; u.spider_engine.legs = legs end
  local leg = table.deepcopy(data.raw["spider-leg"][legs[1].leg])
  leg.name = spec.name .. "-leg"
  leg.localised_name = {"entity-name." .. leg.name}
  leg.initial_movement_speed = 0.06 * spec.leg_speed
  leg.movement_acceleration = 0.03 * spec.leg_speed
  -- Leg death particles were the main per-tick cost at 400 units (spike #3, particleUpdate up to 3.3 ms).
  leg.upper_leg_dying_trigger_effects = nil
  leg.lower_leg_dying_trigger_effects = nil
  leg.resistances = nil -- the originals carry the creature's resistances (see MECH_LEG_RESISTANCES)
  for _, l in pairs(legs) do
    l.leg = leg.name
    -- Stompers damage everything under a foot while attacking (small 43.75 impact, medium 87.5). The heavy keeps
    -- its stomp (docs/PHASE4.md "splash stomp"); the artillery must not, or it crushes what its min range spares.
    if spec.no_stomp then l.leg_hit_the_ground_when_attacking_trigger = nil end
  end

  set_map_colors(u)
  tint_masks(u.graphics_set)
  tint_masks(leg.graphics_set)
  data:extend({leg, u})
end

-- Copy of a pentapod projectile without the wriggler spawn / slowdown sticker, with the given damage.
local function pentapod_projectile(name, source, stats)
  local proj = table.deepcopy(data.raw.projectile[source])
  assert(proj, "factorio-rts: missing vanilla projectile " .. source)
  proj.name = name
  clean_effects(proj.action, stats.damage)
  local bonus = raid_bonus(stats, "explosion", 1)
  if bonus then
    local action = as_list(proj.action)
    action[#action + 1] = bonus
    proj.action = action
  end
  data:extend({proj})
end

local WALKER_STRAFE = {
  max_distance = 22, ideal_distance = 16, ideal_distance_tolerance = 2, ideal_distance_variance = 1,
  ideal_distance_importance = 0.25, ideal_distance_importance_variance = 0.1, face_target = true,
}

local function strafer_attack(projectile)
  return function(ap, stats)
    ap.range = stats.range
    ap.cooldown = stats.cooldown
    local delivery = ap.ammo_type.action.action_delivery
    delivery.projectile = projectile
    delivery.max_range = stats.range + 10
  end
end

local function stomper_attack(ap, stats)
  ap.range = 10                         -- acid stream; vanilla small stomper ~5.85
  ap.damage_modifier = stats.damage_modifier -- vanilla small stomper 0.5
end

local function define_pentapod_units()
  -- Projectiles without the wriggler spawn / slowdown sticker of the vanilla strafer projectiles.
  pentapod_projectile("rts-walker-projectile", "small-strafer-projectile", B["rts-walker"])
  pentapod_projectile("rts-walker-mk2-projectile", "small-strafer-projectile", B["rts-walker-mk2"])
  pentapod_projectile("rts-raider-projectile", "medium-strafer-projectile", B["rts-raider"])

  pentapod_walker({
    name = "rts-walker", source = "small-strafer-pentapod",
    leg_speed = 1.2, -- small strafer uses 3.75
    strafe_settings = WALKER_STRAFE,
    adjust_attack = strafer_attack("rts-walker-projectile"),
  })
  pentapod_walker({
    name = "rts-walker-mk2", source = "small-strafer-pentapod",
    leg_speed = 1.2,
    strafe_settings = WALKER_STRAFE,
    adjust_attack = strafer_attack("rts-walker-mk2-projectile"),
  })
  pentapod_walker({
    name = "rts-walker-heavy", source = "small-stomper-pentapod",
    leg_speed = 0.6, -- small stomper uses 1.8
    adjust_attack = stomper_attack,
  })
  pentapod_walker({
    name = "rts-heavy-mk2", source = "small-stomper-pentapod",
    leg_speed = 0.6,
    adjust_attack = stomper_attack,
  })
  pentapod_walker({
    name = "rts-raider", source = "medium-strafer-pentapod",
    leg_speed = 1.8, -- medium strafer uses 4.5; tuned for walker x1.3 (notes)
    strafe_settings = RAIDER_STRAFE,
    adjust_attack = strafer_attack("rts-raider-projectile"),
  })
  pentapod_walker({
    name = "rts-artillery", source = "medium-stomper-pentapod",
    leg_speed = 0.35, -- medium stomper uses 2.3; tuned for walker x0.6 (notes)
    no_stomp = true,
    strafe_settings = ARTILLERY_STRAFE,
    attack = artillery_attack(B["rts-artillery"]),
  })
end

-------------------------------------------------------------------------------
-- Variant B (no Space Age): spider-units built from base-game spidertron graphics, using the base
-- data-stage globals make_spidertron_leg() and spidertron_torso_graphics_set(). They are not a stable
-- API; if a base update removes them, deep-copy the spidertron torso/legs instead.
-------------------------------------------------------------------------------
local SPIDERTRON_LEG_LAYOUT = { -- {mount px, ground tiles, walking group}, from base create_spidertron()
  {{15, -22}, {2.25, -2.5}, 1}, {{23, -10}, {3, -1}, 2}, {{25, 4}, {3, 1}, 1}, {{15, 17}, {2.25, 2.5}, 2},
  {{-15, -22}, {-2.25, -2.5}, 2}, {{-23, -10}, {-3, -1}, 1}, {{-25, 4}, {-3, 1}, 2}, {{-15, 17}, {-2.25, 2.5}, 1},
}

local function mech_walker(spec)
  assert(make_spidertron_leg and spidertron_torso_graphics_set,
    "factorio-rts: base spidertron helpers not available")
  local stats = B[spec.name]
  local scale = spec.scale
  local legs = {}
  for i, l in ipairs(SPIDERTRON_LEG_LAYOUT) do
    local leg = make_spidertron_leg(spec.name, scale, 1, spec.leg_speed, i, MECH_LEG_RESISTANCES)
    data:extend({leg})
    legs[i] = {
      leg = leg.name,
      mount_position = util.by_pixel(l[1][1] * scale, l[1][2] * scale),
      ground_position = {l[2][1] * scale, l[2][2] * scale},
      walking_group = l[3],
    }
  end
  local gs = spidertron_torso_graphics_set(scale)
  local torso = {}
  for _, k in pairs({"base_animation", "shadow_base_animation", "animation", "shadow_animation",
                     "water_reflection", "render_layer", "base_render_layer"}) do
    torso[k] = gs[k]
  end
  local unit = {
    type = "spider-unit",
    name = spec.name,
    localised_name = {"entity-name." .. spec.name},
    icon = "__base__/graphics/icons/spidertron.png",
    flags = {"placeable-player", "placeable-enemy", "placeable-off-grid", "breaths-air", "not-repairable"},
    subgroup = "enemies",
    order = "z[rts]-" .. spec.name,
    max_health = stats.health,
    collision_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    selection_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    sticker_box = {{-1.5 * scale, -1.5 * scale}, {1.5 * scale, 1.5 * scale}},
    drawing_box_vertical_extension = 3 * scale,
    height = 1.5 * scale * scale, -- base formula 1.5 * scale * leg_scale, legs scaled with the body
    torso_rotation_speed = 0.01,
    distraction_cooldown = 30,
    min_pursue_time = 600,
    max_pursue_distance = 50,
    vision_distance = vision(stats),
    radar_range = 1,
    ai_settings = merge(RTS_AI, {strafe_settings = spec.strafe_settings}),
    attack_parameters = spec.attack or hitscan_attack(stats, spec.damage_type),
    graphics_set = torso, -- spidertron mask layers already use apply_runtime_tint = true
    spider_engine = {legs = legs},
    corpse = "spidertron-remnants",
    dying_explosion = "spidertron-explosion",
    is_military_target = true,
    impact_category = "metal",
  }
  set_map_colors(unit)
  data:extend({unit})
end

local function define_mech_units()
  mech_walker({name = "rts-walker", scale = 0.5, leg_speed = 1.2, damage_type = "physical"})
  mech_walker({name = "rts-walker-mk2", scale = 0.5, leg_speed = 1.2, damage_type = "physical"})
  -- leg_speed is tuned per variant against the measured walker (docs/qa/phase4-content-notes.md "Speeds"). The heavy
  -- was 0.8, which made it x0.95 of the walker here; 0.5 aims at the Space Age heavy's x0.75.
  mech_walker({name = "rts-walker-heavy", scale = 0.8, leg_speed = 0.5, damage_type = "explosion"})
  mech_walker({name = "rts-heavy-mk2", scale = 0.8, leg_speed = 0.5, damage_type = "explosion"})
  mech_walker({name = "rts-raider", scale = 0.6, leg_speed = 2.2, damage_type = "physical",
               strafe_settings = RAIDER_STRAFE})
  mech_walker({name = "rts-artillery", scale = 1.0, leg_speed = 0.27, strafe_settings = ARTILLERY_STRAFE,
               attack = artillery_attack(B["rts-artillery"])})
end

-------------------------------------------------------------------------------
-- Drone (both variants): a medium-biter copy. Units cannot take the force colour at runtime the way spider-units
-- do, so the drone has one neutral steel-blue tint for every force (team colour is out of scope; see the notes).
-------------------------------------------------------------------------------
local DRONE_BODY = {0.52, 0.58, 0.64, 1}
local DRONE_ACCENT = {0.3, 0.55, 0.75, 0.7}
local DRONE_SPEED = 0.28 -- tiles per tick (16.8 tiles/s); medium biter 0.24; walker x1.45-1.55 (notes)

local function has_flag(t, flag)
  if type(t.flags) ~= "table" then return false end
  for _, f in pairs(t.flags) do if f == flag then return true end end
  return false
end

-- Replace the colour of every biter mask layer: mask1 (body) and mask2 (tint_as_overlay accents).
local function retint_masks(t)
  if type(t) ~= "table" then return end
  if has_flag(t, "mask") and t.tint then
    t.tint = table.deepcopy(t.tint_as_overlay and DRONE_ACCENT or DRONE_BODY)
  end
  for _, v in pairs(t) do retint_masks(v) end
end

local function define_drone()
  local stats = B["rts-drone"]
  local src = data.raw.unit["medium-biter"]
  assert(src, "factorio-rts: missing vanilla unit medium-biter")
  local u = table.deepcopy(src)
  u.name = "rts-drone"
  u.localised_name = nil
  u.localised_description = nil
  u.icons = {{icon = src.icon, icon_size = src.icon_size, tint = DRONE_BODY}}
  u.icon = nil
  u.icon_size = nil
  u.order = "z[rts]-rts-drone"
  u.max_health = stats.health
  u.healing_per_tick = 0
  u.resistances = nil
  u.factoriopedia_simulation = nil
  u.absorptions_to_join_attack = nil
  u.working_sound = nil -- ambient biter calls
  u.movement_speed = DRONE_SPEED
  u.vision_distance = 30
  u.radar_range = 1
  u.ai_settings = table.deepcopy(RTS_AI)
  local ap = u.attack_parameters
  ap.ammo_category = stats.ammo_category
  ap.range = stats.range
  ap.cooldown = stats.cooldown
  ap.ammo_type = {
    target_type = "entity",
    action = {
      type = "direct",
      action_delivery = {
        type = "instant",
        target_effects = {type = "damage", damage = {amount = stats.damage, type = stats.damage_type}},
      },
    },
  }
  retint_masks(u.run_animation)
  retint_masks(ap.animation)
  set_map_colors(u)
  data:extend({u})
end

-------------------------------------------------------------------------------
-- Commander (both variants): a spidertron copy with its own legs (x1.2 speed), grid, launchers and rockets.
-- Spawned by script (no recipe, not minable). Needs rts-commander-rocket in its ammo inventory to fire.
-------------------------------------------------------------------------------
-- Leg speed factor that gives the commander x1.2 of the vanilla spidertron's speed (balance speed); legs at x1.2
-- measured only x1.09-1.10 (probe).
local COMMANDER_LEG_FACTOR = 1.55

local function define_commander()
  local stats = B["rts-commander"]
  local src = data.raw["spider-vehicle"]["spidertron"]
  assert(src, "factorio-rts: missing vanilla spider-vehicle spidertron")

  data:extend({{
    type = "equipment-grid",
    name = "rts-commander-grid",
    width = 4,
    height = 4,
    equipment_categories = {"armor"}, -- personal roboport, batteries, generators, shields
  }})

  -- Rockets: the vanilla rocket with this unit's damage and ammo category.
  local proj = table.deepcopy(data.raw.projectile["rocket"])
  proj.name = "rts-commander-rocket"
  clean_effects(proj.action, stats.damage)
  local ammo = table.deepcopy(data.raw.ammo["rocket"])
  ammo.name = "rts-commander-rocket"
  ammo.localised_name = nil
  ammo.localised_description = nil
  ammo.ammo_category = stats.ammo_category
  ammo.ammo_type.action.action_delivery.projectile = proj.name
  ammo.subgroup = "rts-units"
  ammo.order = "z[commander]-b[rocket]"
  ammo.hidden = true
  ammo.auto_recycle = false
  data:extend({proj, ammo})

  local guns = {}
  for i = 1, 2 do
    local gun = table.deepcopy(data.raw.gun["spidertron-rocket-launcher-" .. i])
    gun.name = "rts-commander-launcher-" .. i
    gun.localised_name = {"item-name.rts-commander-launcher"}
    gun.subgroup = "rts-units"
    gun.order = "z[commander]-a[launcher]"
    gun.attack_parameters.ammo_category = stats.ammo_category
    gun.attack_parameters.range = stats.range
    gun.attack_parameters.cooldown = stats.cooldown
    data:extend({gun})
    guns[i] = gun.name
  end

  local c = table.deepcopy(src)
  c.name = "rts-commander"
  c.localised_name = nil
  c.localised_description = nil
  c.order = "z[rts]-rts-commander"
  c.max_health = stats.health
  c.resistances = nil -- the spidertron's 60-80 % resistances would make it immune to walker fire
  c.minable = nil
  c.flags = {"placeable-neutral", "player-creation", "placeable-off-grid", "not-deconstructable",
             "not-blueprintable"}
  c.factoriopedia_simulation = nil
  c.equipment_grid = "rts-commander-grid"
  c.inventory_size = 20
  c.trash_inventory_size = 0
  c.guns = guns
  c.chunk_exploration_radius = 1
  c.is_military_target = true
  set_map_colors(c)

  for i, l in pairs(c.spider_engine.legs) do
    local leg = table.deepcopy(data.raw["spider-leg"][l.leg])
    assert(leg, "factorio-rts: missing vanilla spider-leg " .. tostring(l.leg))
    leg.name = "rts-commander-leg-" .. i
    leg.initial_movement_speed = leg.initial_movement_speed * COMMANDER_LEG_FACTOR
    leg.movement_acceleration = leg.movement_acceleration * COMMANDER_LEG_FACTOR
    l.leg = leg.name
    data:extend({leg})
  end
  data:extend({c})
end

-------------------------------------------------------------------------------
define_artillery_shell()
if mods["space-age"] then
  define_pentapod_units()
else
  define_mech_units()
end
define_drone()
define_commander()
