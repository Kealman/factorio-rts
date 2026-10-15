-- spider-unit prototypes: rts-walker (ranged line unit) and rts-walker-heavy (slow brawler).
local util = require("util")
local common = require("prototypes.common")
local TAG = common.TAG

local has_space_age = mods["space-age"] ~= nil
log(TAG .. "space-age loaded: " .. tostring(has_space_age))

-------------------------------------------------------------------------------
-- Variant A (Space Age present): copies of the Gleba pentapods.
-------------------------------------------------------------------------------
local function pentapod_walker(spec)
  local src = data.raw["spider-unit"][spec.source]
  assert(src, "missing vanilla spider-unit " .. spec.source)
  local u = table.deepcopy(src)
  u.name = spec.name
  u.localised_name = {"entity-name." .. spec.name}
  u.localised_description = nil
  u.max_health = spec.max_health
  u.healing_per_tick = 0
  u.factoriopedia_simulation = nil
  u.absorptions_to_join_attack = nil -- "spores" based attack joining; irrelevant for scripted units
  u.dying_trigger_effect = nil       -- vanilla spawns wrigglers / stomper shells on death
  u.vision_distance = 30             -- <= 100; >= 50 is documented to cause self-grouping for units
  u.radar_range = 1                  -- chunks charted around the unit for its force
  u.order = "z[rts]-" .. spec.name
  u.ai_settings = common.merge(common.RTS_AI, {
    strafe_settings = spec.strafe_settings or (src.ai_settings and src.ai_settings.strafe_settings),
  })
  spec.adjust_attack(u.attack_parameters)

  -- Own leg prototype so that the walking speed can be tuned (spider-units have no movement_speed;
  -- speed comes from SpiderLegPrototype.initial_movement_speed / movement_acceleration).
  local legs = u.spider_engine.legs
  if legs.leg then legs = {legs}; u.spider_engine.legs = legs end
  local leg = table.deepcopy(data.raw["spider-leg"][legs[1].leg])
  leg.name = spec.name .. "-leg"
  leg.localised_name = {"entity-name." .. leg.name}
  leg.initial_movement_speed = 0.06 * spec.leg_speed
  leg.movement_acceleration = 0.03 * spec.leg_speed
  for _, l in pairs(legs) do l.leg = leg.name end

  -- Team colors: mask layers take the force color at runtime.
  local n_torso = common.tint_masks(u.graphics_set)
  local n_leg = common.tint_masks(leg.graphics_set)
  data:extend({leg, u})
  log(TAG .. string.format("%s <- %s: hp=%d legs=%d leg_speed=%.3f/%.3f attack=%s range=%s cooldown=%s "
    .. "runtime-tinted layers torso=%d leg=%d", spec.name, spec.source, u.max_health, #legs,
    leg.initial_movement_speed, leg.movement_acceleration, u.attack_parameters.type,
    tostring(u.attack_parameters.range), tostring(u.attack_parameters.cooldown), n_torso, n_leg))
end

local function define_pentapod_walkers()
  -- Projectile without the wriggler spawn / slowdown sticker of the vanilla strafer projectile.
  local proj = table.deepcopy(data.raw.projectile["small-strafer-projectile"])
  proj.name = "rts-walker-projectile"
  common.clean_effects(proj.action, 20)
  data:extend({proj})

  pentapod_walker({
    name = "rts-walker",
    source = "small-strafer-pentapod",
    max_health = 200,
    leg_speed = 1.2, -- small strafer uses 3.75; 2.5 measured ~13 tiles/s, too fast for a line unit
    strafe_settings = {
      max_distance = 22, ideal_distance = 16, ideal_distance_tolerance = 2, ideal_distance_variance = 1,
      ideal_distance_importance = 0.25, ideal_distance_importance_variance = 0.1, face_target = true,
    },
    adjust_attack = function(ap)
      ap.range = 20
      ap.cooldown = 60
      local delivery = ap.ammo_type.action.action_delivery
      delivery.projectile = "rts-walker-projectile"
      delivery.max_range = 30
    end,
  })

  pentapod_walker({
    name = "rts-walker-heavy",
    source = "small-stomper-pentapod",
    max_health = 600,
    leg_speed = 0.6, -- small stomper uses 1.8
    adjust_attack = function(ap)
      ap.range = 10            -- acid stream; vanilla small stomper ~5.85
      ap.damage_modifier = 2.0 -- vanilla small stomper 0.5
    end,
  })
end

-------------------------------------------------------------------------------
-- Variant B (no Space Age): spider-units built from base-game spidertron graphics.
-- Uses the base global helpers make_spidertron_leg() and spidertron_torso_graphics_set().
-------------------------------------------------------------------------------
local SPIDERTRON_LEG_LAYOUT = { -- {mount px, ground tiles, walking group}, from base create_spidertron()
  {{15, -22}, {2.25, -2.5}, 1}, {{23, -10}, {3, -1}, 2}, {{25, 4}, {3, 1}, 1}, {{15, 17}, {2.25, 2.5}, 2},
  {{-15, -22}, {-2.25, -2.5}, 2}, {{-23, -10}, {-3, -1}, 1}, {{-25, 4}, {-3, 1}, 2}, {{-15, 17}, {-2.25, 2.5}, 1},
}

local function mech_walker(spec)
  assert(make_spidertron_leg and spidertron_torso_graphics_set, "base spidertron helpers not available")
  local scale = spec.scale
  local leg_scale = scale * spec.leg_scale
  local legs = {}
  for i, l in ipairs(SPIDERTRON_LEG_LAYOUT) do
    local leg = make_spidertron_leg(spec.name, leg_scale, 1, spec.leg_speed, i, {})
    data:extend({leg})
    legs[i] = {
      leg = leg.name,
      mount_position = util.by_pixel(l[1][1] * scale, l[1][2] * scale),
      ground_position = {l[2][1] * leg_scale, l[2][2] * leg_scale},
      walking_group = l[3],
    }
  end
  local gs = spidertron_torso_graphics_set(scale)
  local torso = {}
  for _, k in pairs({"base_animation", "shadow_base_animation", "animation", "shadow_animation",
                     "water_reflection", "render_layer", "base_render_layer"}) do
    torso[k] = gs[k]
  end
  local u = {
    type = "spider-unit",
    name = spec.name,
    localised_name = {"entity-name." .. spec.name},
    icon = "__base__/graphics/icons/spidertron.png",
    flags = {"placeable-player", "placeable-enemy", "placeable-off-grid", "breaths-air", "not-repairable"},
    subgroup = "enemies",
    order = "z[rts]-" .. spec.name,
    max_health = spec.max_health,
    collision_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    selection_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    sticker_box = {{-1.5 * scale, -1.5 * scale}, {1.5 * scale, 1.5 * scale}},
    drawing_box_vertical_extension = 3 * scale,
    height = 1.5 * scale * leg_scale,
    torso_rotation_speed = 0.01,
    distraction_cooldown = 30,
    min_pursue_time = 600,
    max_pursue_distance = 50,
    vision_distance = 30,
    radar_range = 1,
    ai_settings = table.deepcopy(common.RTS_AI),
    attack_parameters = common.hitscan_attack(spec.range, spec.cooldown, spec.damage, spec.damage_type),
    graphics_set = torso, -- spidertron mask layers already use apply_runtime_tint = true
    spider_engine = {legs = legs},
    corpse = "spidertron-remnants",
    dying_explosion = "spidertron-explosion",
    is_military_target = true,
    impact_category = "metal",
  }
  data:extend({u})
  log(TAG .. string.format("%s <- base spidertron graphics: hp=%d legs=%d scale=%.2f leg_scale=%.2f range=%d",
    spec.name, spec.max_health, #legs, scale, leg_scale, spec.range))
end

local function define_mech_walkers()
  mech_walker({name = "rts-walker", max_health = 200, scale = 0.5, leg_scale = 1.0, leg_speed = 1.2,
               range = 20, cooldown = 60, damage = 20, damage_type = "physical"})
  mech_walker({name = "rts-walker-heavy", max_health = 600, scale = 0.8, leg_scale = 1.0, leg_speed = 0.8,
               range = 12, cooldown = 90, damage = 60, damage_type = "explosion"})
end

if has_space_age then
  define_pentapod_walkers()
else
  define_mech_walkers()
end
