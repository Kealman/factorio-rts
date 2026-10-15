-- Plain `unit` prototypes copied from small-biter, for comparison with spider-units.
-- LuaEntity.color does not exist for units, so team colors need one prototype per team
-- (hard-coded mask tint). rts-swarm additionally tests apply_runtime_tint on a unit.
local common = require("prototypes.common")
local TAG = common.TAG

local TEAM_TINTS = {
  red = {r = 0.95, g = 0.1, b = 0.1, a = 1},
  blue = {r = 0.1, g = 0.35, b = 0.95, a = 1},
}

local function make_swarm(name, color)
  local b = table.deepcopy(data.raw.unit["small-biter"])
  b.name = name
  b.localised_name = {"entity-name." .. name}
  b.max_health = 60
  b.healing_per_tick = 0
  b.factoriopedia_simulation = nil
  b.absorptions_to_join_attack = nil
  b.ai_settings = table.deepcopy(common.RTS_AI)
  b.radar_range = 1
  b.vision_distance = 30
  b.order = "z[rts]-" .. name
  local n = common.tint_masks(b.run_animation, color) + common.tint_masks(b.attack_parameters.animation, color)
  data:extend({b})
  log(TAG .. string.format("%s <- small-biter: hp=%d speed=%.3f tint=%s layers changed=%d", name,
    b.max_health, b.movement_speed, color and serpent.line(color) or "runtime (apply_runtime_tint)", n))
end

for team, color in pairs(TEAM_TINTS) do
  make_swarm("rts-swarm-" .. team, color)
end
make_swarm("rts-swarm", nil)
