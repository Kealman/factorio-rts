-- RTS unit prototypes: rts-walker (ranged line unit) and rts-walker-heavy (slow brawler), both spider-units.
-- With Space Age loaded they are copies of the Gleba pentapods (strafer / stomper); without it they are
-- built from the base-game spidertron graphics, so Space Age stays an optional dependency.
-- Ported from spikes/units (spike #3); see docs/research/spikes.md decisions 2, 3 and 9.
local util = require("util")

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

-- Hitscan ranged attack built from base-game effects only (no Space Age assets).
local function hitscan_attack(range, cooldown, damage, damage_type)
  return {
    type = "projectile",
    ammo_category = "bullet",
    cooldown = cooldown,
    range = range,
    ammo_type = {
      action = {
        type = "direct",
        action_delivery = {
          type = "instant",
          source_effects = {{type = "create-explosion", entity_name = "explosion-gunshot"}},
          target_effects = {
            {type = "create-entity", entity_name = "explosion-hit", offsets = {{0, 1}},
             offset_deviation = {{-0.5, -0.5}, {0.5, 0.5}}},
            {type = "damage", damage = {amount = damage, type = damage_type}},
          },
        },
      },
    },
  }
end

-------------------------------------------------------------------------------
-- Variant A (Space Age present): copies of the Gleba pentapods.
-------------------------------------------------------------------------------
local function pentapod_walker(spec)
  local src = data.raw["spider-unit"][spec.source]
  assert(src, "factorio-rts: missing vanilla spider-unit " .. spec.source)
  local u = table.deepcopy(src)
  u.name = spec.name
  u.localised_name = {"entity-name." .. spec.name}
  u.localised_description = nil
  u.max_health = spec.max_health
  u.healing_per_tick = 0
  u.factoriopedia_simulation = nil
  u.absorptions_to_join_attack = nil -- spore-based attack joining; irrelevant for scripted units
  u.dying_trigger_effect = nil       -- vanilla spawns wrigglers / stomper shells on death
  u.vision_distance = 30             -- <= 100; >= 50 is documented to cause self-grouping for units
  u.radar_range = 1                  -- chunks charted around the unit for its force
  u.order = "z[rts]-" .. spec.name
  u.ai_settings = merge(RTS_AI, {
    strafe_settings = spec.strafe_settings or (src.ai_settings and src.ai_settings.strafe_settings),
  })
  spec.adjust_attack(u.attack_parameters)

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
  for _, l in pairs(legs) do l.leg = leg.name end

  set_map_colors(u)
  tint_masks(u.graphics_set)
  tint_masks(leg.graphics_set)
  data:extend({leg, u})
end

local function define_pentapod_walkers()
  -- Projectile without the wriggler spawn / slowdown sticker of the vanilla strafer projectile.
  local proj = table.deepcopy(data.raw.projectile["small-strafer-projectile"])
  proj.name = "rts-walker-projectile"
  clean_effects(proj.action, 20)
  data:extend({proj})

  pentapod_walker({
    name = "rts-walker",
    source = "small-strafer-pentapod",
    max_health = 200,
    leg_speed = 1.2, -- small strafer uses 3.75; 1.2 gives ~8.6 tiles/s
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
    leg_speed = 0.6, -- small stomper uses 1.8; 0.6 gives ~5.7 tiles/s
    adjust_attack = function(ap)
      ap.range = 10            -- acid stream; vanilla small stomper ~5.85
      ap.damage_modifier = 2.0 -- vanilla small stomper 0.5
    end,
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
  local scale = spec.scale
  local legs = {}
  for i, l in ipairs(SPIDERTRON_LEG_LAYOUT) do
    local leg = make_spidertron_leg(spec.name, scale, 1, spec.leg_speed, i, {})
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
    max_health = spec.max_health,
    collision_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    selection_box = {{-1 * scale, -1 * scale}, {1 * scale, 1 * scale}},
    sticker_box = {{-1.5 * scale, -1.5 * scale}, {1.5 * scale, 1.5 * scale}},
    drawing_box_vertical_extension = 3 * scale,
    height = 1.5 * scale * scale, -- base formula 1.5 * scale * leg_scale, legs scaled with the body
    torso_rotation_speed = 0.01,
    distraction_cooldown = 30,
    min_pursue_time = 600,
    max_pursue_distance = 50,
    vision_distance = 30,
    radar_range = 1,
    ai_settings = table.deepcopy(RTS_AI),
    attack_parameters = hitscan_attack(spec.range, spec.cooldown, spec.damage, spec.damage_type),
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

local function define_mech_walkers()
  mech_walker({name = "rts-walker", max_health = 200, scale = 0.5, leg_speed = 1.2,
               range = 20, cooldown = 60, damage = 20, damage_type = "physical"})
  mech_walker({name = "rts-walker-heavy", max_health = 600, scale = 0.8, leg_speed = 0.8,
               range = 12, cooldown = 90, damage = 60, damage_type = "explosion"})
end

if mods["space-age"] then
  define_pentapod_walkers()
else
  define_mech_walkers()
end
