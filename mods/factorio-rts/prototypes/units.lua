-- RTS unit prototypes. Every number (health, damage, range, cooldown, armour, collision size) comes from balance.lua.
--
--   rts-walker, rts-walker-mk2        ranged line unit (spider-unit)
--   rts-walker-heavy, rts-heavy-mk2   armoured brawler with splash (spider-unit)
--   rts-raider                        fast, short range, bonus damage against raid targets (spider-unit)
--   rts-artillery                     slow siege unit: range 40, min range 8, 4-tile splash, bonus vs armour
--   rts-drone                         cheap fast melee swarm (unit, medium-biter sprites, neutral tint)
--   rts-commander                     hero spidertron (spider-vehicle), spawned by script; own guns and rockets
--
-- With Space Age loaded the spider-units use the Gleba pentapod graphics (walker: small strafer, heavy: small stomper,
-- raider: medium strafer, artillery: medium stomper); without it they are built from the base-game spidertron
-- graphics, so Space Age stays an optional dependency. The drone and the commander use base-game assets only.
--
-- Balance pass (docs/qa/phase4-balance-notes.md): a role behaves the same in both variants. Attack, damage type,
-- strafe settings, collision box, armour and trigger masks come from one place (role()); only the graphics, the legs
-- and the walker / raider projectile visuals differ. Ported from spikes/units (spike #3); see
-- docs/research/spikes.md decisions 2, 3 and 9 and docs/qa/phase4-content-notes.md.
local util = require("util")
local balance = require("balance")
local B = balance.units
local TT = balance.target_types

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

-- Strafing while attacking: the unit circles its target at about ideal_distance (inside its range). The same for
-- both variants (the base-game units had none, the pentapods the Gleba values).
local function strafe(ideal, max, tolerance, importance)
  return {max_distance = max, ideal_distance = ideal, ideal_distance_tolerance = tolerance, ideal_distance_variance = 1,
          ideal_distance_importance = importance or 0.25, ideal_distance_importance_variance = 0.1, face_target = true}
end
local STRAFE = {
  walker = strafe(16, 22, 2),
  heavy = strafe(13, 18, 2),
  raider = strafe(14, 20, 2),
  -- artillery: none. It stands where it fired from (34-40 tiles, min_attack_distance); an orbit (32 +- 4, or 34 +- 3
  -- with importance 0.75) drifted it inside the range of the turret it was shelling.
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

-- Set every damage amount in a trigger tree (the commander's rocket).
local function set_damage(t, damage)
  if type(t) ~= "table" then return end
  if t.type == "damage" and type(t.damage) == "table" then t.damage.amount = damage end
  for _, v in pairs(t) do set_damage(v, damage) end
end

-------------------------------------------------------------------------------
-- Shared role settings
-------------------------------------------------------------------------------
-- Vision covers the attack range, so a unit acquires targets as far as it can shoot (artillery: 46). It stays below
-- 50: UnitPrototype documents self-grouping of units at vision_distance >= 50.
local function vision(stats) return math.max(30, stats.range + 2) end

local function resistances(stats, extra)
  local r = {}
  for damage_type, percent in pairs(stats.resist or {}) do r[#r + 1] = {type = damage_type, percent = percent} end
  for _, e in pairs(extra or {}) do
    local found
    for _, x in pairs(r) do if x.type == e.type then x.percent = e.percent; found = true end end
    if not found then r[#r + 1] = table.deepcopy(e) end
  end
  table.sort(r, function(a, b) return a.type < b.type end)
  return #r > 0 and r or nil
end

-- Spider legs pass the damage they take on to the torso, after the leg's own resistances (probe, 2026-10-15): a
-- 4-tile shell hit a base-game mech once per leg in range, and drones biting a strafer leg did 7.2 instead of 10.
-- Every unit attack damages the targeted entity directly, so legs only meet melee bites (impact, which they pass on
-- through the torso's armour) and area damage (explosions, which they ignore: an area attack counts once).
local LEG_EXPLOSION = {{type = "explosion", percent = 100}}

local function role(u, stats)
  u.max_health = stats.health
  u.healing_per_tick = 0
  u.resistances = resistances(stats)
  local mask = {"common"}
  for _, tag in ipairs(stats.tags or {}) do mask[#mask + 1] = assert(TT[tag], "unknown target type " .. tag) end
  u.trigger_target_mask = #mask > 1 and mask or nil
  if stats.size then
    u.collision_box = {{-stats.size, -stats.size}, {stats.size, stats.size}}
  end
  u.vision_distance = vision(stats)
  u.radar_range = 1 -- chunks charted around the unit for its force
  -- How soon a unit may pick a new target. The stompers had 300 ticks, the strafers and the base mechs 30: with 300,
  -- stomper-based heavies first fired 3-5 s into a fight instead of 0.3-1 s, and artillery fired one volley per 5 s.
  u.distraction_cooldown = 30
  u.min_pursue_time = 600
  u.max_pursue_distance = 50
  u.order = "z[rts]-" .. u.name
  u.ai_settings = merge(RTS_AI, {strafe_settings = STRAFE[stats.kind]})
  set_map_colors(u)
end

-- Bonus damage (stats.bonus): extra damage that only entities carrying a target type take, so the total against them
-- is damage * multiplier. An "area" trigger nested in the hit, radius 0.5 around the target: a "direct" trigger
-- ignores trigger_target_mask (probe). Sorted, so the prototype data is the same on every load.
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

-- Heavies: splash_damage to every enemy within `splash` of the target (the target included), also a nested area.
local function hit_effects(stats, visual)
  local effects = {
    {type = "create-entity", entity_name = visual, offset_deviation = {{-0.3, -0.3}, {0.3, 0.3}}},
    {type = "damage", damage = {amount = stats.damage, type = stats.damage_type}},
  }
  bonus_effects(stats, effects)
  if stats.splash and stats.splash_damage then
    effects[#effects + 1] = {type = "nested-result", action = {
      type = "area", radius = stats.splash, force = "enemy",
      action_delivery = {type = "instant", target_effects = {{type = "damage",
        damage = {amount = stats.splash_damage, type = stats.damage_type}}}},
    }}
  end
  return effects
end

-- Hitscan attack (base-game effects only): the damage lands on the attacked entity in the same tick.
local function direct_attack(stats, visual)
  return {
    type = "projectile",
    ammo_category = stats.ammo_category,
    cooldown = stats.cooldown,
    range = stats.range,
    ammo_type = {action = {
      type = "direct",
      action_delivery = {
        type = "instant",
        source_effects = {{type = "create-explosion", entity_name = "explosion-gunshot"}},
        target_effects = hit_effects(stats, visual),
      },
    }},
  }
end

-------------------------------------------------------------------------------
-- Artillery shell (both variants): a grenade-style projectile thrown at the target's position. `splash` radius that
-- spares its own force; bonus x damage to tagged targets (armored: heavies) within `bonus_radius` of the impact.
-------------------------------------------------------------------------------
local function define_artillery_shell()
  local spec = B["rts-artillery"]
  local shell = table.deepcopy(data.raw.projectile["grenade"])
  assert(shell, "factorio-rts: missing vanilla projectile grenade")
  shell.name = "rts-artillery-shell"
  shell.localised_name = nil
  shell.acceleration = 0.005
  local function area(damage, mask)
    return {
      type = "area",
      radius = mask and spec.bonus_radius or spec.splash,
      force = "not-same", -- no friendly fire
      trigger_target_mask = mask,
      action_delivery = {
        type = "instant",
        target_effects = {
          {type = "damage", damage = {amount = damage, type = spec.damage_type}},
          not mask and {type = "create-entity", entity_name = "explosion"} or nil,
        },
      },
    }
  end
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
    area(spec.damage),
  }
  local keys = {}
  for key in pairs(spec.bonus or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if spec.bonus[key] > 1 then
      shell.action[#shell.action + 1] = area(spec.damage * (spec.bonus[key] - 1), {TT[key]})
    end
  end
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
    -- Picks a firing distance between attack_from and range (32-44 tiles) when it closes in, so it shells a gun turret
    -- (21) from outside its range: closest 30-36 tiles in the simulator. With 24-40 and the old slow shell it drifted
    -- to 17-22 tiles over a long siege and took hits (balance notes).
    min_attack_distance = spec.attack_from,
    lead_target_for_projectile_speed = 2, -- aims where a moving target will be when the shell lands
    sound = cannon and cannon.attack_parameters and table.deepcopy(cannon.attack_parameters.sound) or nil,
    ammo_type = {
      action = {
        type = "direct",
        action_delivery = {
          type = "projectile",
          projectile = "rts-artillery-shell",
          starting_speed = 2, -- 40 tiles in 20 ticks: a heavy moves under 2 tiles meanwhile, a drone about 5
          max_range = spec.range + 10,
        },
      },
    },
  }
end

-- The attack of a role, shared by both variants (the pentapod walker and raider swap in a projectile visual).
local function attack_of(name)
  local stats = B[name]
  if stats.kind == "artillery" then return artillery_attack(stats) end
  if stats.kind == "heavy" then return direct_attack(stats, "explosion") end
  return direct_attack(stats, "explosion-hit")
end

-------------------------------------------------------------------------------
-- Variant A (Space Age present): Gleba pentapod graphics.
-------------------------------------------------------------------------------
-- Walker and raider keep the strafer's projectile as the visible shot. It damages the targeted entity directly:
-- the vanilla one fired along the torso's facing (use_shooter_direction), turned at 0.002 per tick and exploded in a
-- 1-tile area wherever it collided, so most shots landed beside the target or on a leg (27 impacts, 10 hits on a
-- target that never moved). This one flies straight at the target, homes at 0.05 per tick, collides with nothing on
-- the way (empty hit_collision_mask) and applies hit_effects() to the target it was fired at.
local function pentapod_projectile_attack(name, source)
  local stats = B[name]
  local proj = table.deepcopy(data.raw.projectile[source])
  assert(proj, "factorio-rts: missing vanilla projectile " .. source)
  proj.name = name .. "-projectile"
  proj.turn_speed = 0.05
  proj.hit_collision_mask = {layers = {}}
  proj.action = {type = "direct",
                 action_delivery = {type = "instant", target_effects = hit_effects(stats, "explosion-hit")}}
  data:extend({proj})
  local ap = direct_attack(stats, "explosion-hit")
  ap.ammo_type.action.action_delivery = {
    type = "projectile",
    projectile = proj.name,
    starting_speed = 1, -- the vanilla max speed: 20 tiles in 20 ticks, close to the base-game hitscan
    max_range = stats.range + 10,
  }
  return ap
end

local function pentapod_walker(spec)
  local src = data.raw["spider-unit"][spec.source]
  assert(src, "factorio-rts: missing vanilla spider-unit " .. spec.source)
  local stats = B[spec.name]
  local u = table.deepcopy(src)
  u.name = spec.name
  u.localised_name = {"entity-name." .. spec.name}
  u.localised_description = nil
  u.factoriopedia_simulation = nil
  u.absorptions_to_join_attack = nil -- spore-based attack joining; irrelevant for scripted units
  u.dying_trigger_effect = nil       -- vanilla spawns wrigglers / stomper shells on death
  role(u, stats)
  u.attack_parameters = spec.attack

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
  leg.resistances = resistances(stats, LEG_EXPLOSION)
  -- Legs carry the torso's target types: a drone biting a raider's leg gets its bonus against "light" (the bonus is
  -- an area around the bitten entity). Area bonuses that are explosions (artillery) cannot multiply through the legs,
  -- which ignore explosions.
  leg.trigger_target_mask = u.trigger_target_mask
  for _, l in pairs(legs) do
    l.leg = leg.name
    -- Long pentapod legs (the medium strafer's and the stompers' stand 6-8 tiles out) give drones far more to bite
    -- than the base-game mechs' 1-3 tiles: Space Age raiders lost to drones that base-game raiders beat. reach < 1
    -- pulls the feet in.
    if spec.reach then
      local g = l.ground_position
      l.ground_position = {(g[1] or g.x) * spec.reach, (g[2] or g.y) * spec.reach}
    end
    -- Stompers damage everything under a foot while attacking (small 43.75 impact, medium 87.5): no unit keeps it,
    -- so the heavy splash is the same in both variants and the artillery cannot crush what its min range spares.
    l.leg_hit_the_ground_when_attacking_trigger = nil
  end

  tint_masks(u.graphics_set)
  tint_masks(leg.graphics_set)
  data:extend({leg, u})
end

local function define_pentapod_units()
  local function unit(name, source, leg_speed, projectile, reach)
    pentapod_walker({name = name, source = source, leg_speed = leg_speed, reach = reach,
                     attack = projectile and pentapod_projectile_attack(name, projectile) or attack_of(name)})
  end
  -- leg_speed is tuned per unit against the measured walker (docs/qa/phase4-content-notes.md "Speeds").
  unit("rts-walker", "small-strafer-pentapod", 1.3, "small-strafer-projectile")         -- small strafer uses 3.75
  unit("rts-walker-mk2", "small-strafer-pentapod", 1.3, "small-strafer-projectile")
  unit("rts-walker-heavy", "small-stomper-pentapod", 0.28, nil, 0.5)                     -- small stomper uses 1.8
  unit("rts-heavy-mk2", "small-stomper-pentapod", 0.28, nil, 0.5)
  unit("rts-raider", "medium-strafer-pentapod", 1.95, "medium-strafer-projectile", 0.5) -- medium strafer uses 4.5
  unit("rts-artillery", "medium-stomper-pentapod", 0.33, nil, 0.5)                       -- medium stomper uses 2.3
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
  local legs, legs_protos = {}, {}
  for i, l in ipairs(SPIDERTRON_LEG_LAYOUT) do
    local leg = make_spidertron_leg(spec.name, scale, 1, spec.leg_speed, i, resistances(stats, LEG_EXPLOSION))
    legs_protos[i] = leg
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
    collision_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    selection_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    sticker_box = {{-1.5 * scale, -1.5 * scale}, {1.5 * scale, 1.5 * scale}},
    drawing_box_vertical_extension = 3 * scale,
    height = 1.5 * scale * scale, -- base formula 1.5 * scale * leg_scale, legs scaled with the body
    torso_rotation_speed = 0.01,
    distraction_cooldown = 30,
    min_pursue_time = 600,
    max_pursue_distance = 50,
    attack_parameters = attack_of(spec.name),
    graphics_set = torso, -- spidertron mask layers already use apply_runtime_tint = true
    spider_engine = {legs = legs},
    corpse = "spidertron-remnants",
    dying_explosion = "spidertron-explosion",
    is_military_target = true,
    impact_category = "metal",
  }
  role(unit, stats)
  for _, leg in pairs(legs_protos) do leg.trigger_target_mask = unit.trigger_target_mask end -- see pentapod_walker
  data:extend({unit})
end

local function define_mech_units()
  -- leg_speed is tuned per variant against the measured walker (docs/qa/phase4-content-notes.md "Speeds"). The heavy
  -- was 0.8, which made it x0.95 of the walker here; 0.5 matches the Space Age heavy's x0.75.
  mech_walker({name = "rts-walker", scale = 0.5, leg_speed = 1.2})
  mech_walker({name = "rts-walker-mk2", scale = 0.5, leg_speed = 1.2})
  mech_walker({name = "rts-walker-heavy", scale = 0.8, leg_speed = 0.24})
  mech_walker({name = "rts-heavy-mk2", scale = 0.8, leg_speed = 0.24})
  mech_walker({name = "rts-raider", scale = 0.6, leg_speed = 2.2})
  mech_walker({name = "rts-artillery", scale = 1.0, leg_speed = 0.28})
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
        target_effects = bonus_effects(stats,
          {{type = "damage", damage = {amount = stats.damage, type = stats.damage_type}}}),
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
  set_damage(proj.action, stats.damage)
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
