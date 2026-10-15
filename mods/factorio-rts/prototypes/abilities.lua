-- Phase 4 abilities and the Commander (docs/qa/phase4-abilities-notes.md): data-stage parts.
--
--   rts-commander-core     generator equipment (2x2, free power): powers the Commander's grid. The vanilla fission
--                          reactor is 4x4, too big for the 4x4 rts-commander-grid next to a roboport and two shields.
--   rts-commander-shield   energy shield equipment (2x2): the Commander's level reward. Each one holds 20 % of the
--                          Commander's max health (balance.units["rts-commander"].health), so "+20 % HP per level"
--                          becomes a regenerating shield (LuaEntity.max_health is read-only).
--   rts-stim-sticker       Stim's speed burst for units that can carry stickers (StickerPrototype: unit, character,
--                          car, spider-vehicle; not spider-unit): drones and the Commander.
-- Each equipment has a hidden item of the same name (place_as_equipment_result / take_result), so the grid GUI and
-- LuaEquipmentGrid.put have the usual item behind them. Grid layout at level 3 (scripts/commander.lua):
--   roboport (0,0) | shield (2,0)
--   shield   (0,2) | core   (2,2)
local balance = require("balance")

local COMMANDER_HEALTH = (balance.units["rts-commander"] or {}).health or 2000
local SHIELD_SHARE = 0.2            -- shield points per shield equipment, as a share of the Commander's max health
local CORE_POWER = "300kW"          -- free power of the core
local SHIELD_ENERGY_PER_POINT = "50kJ"
local SHIELD_INPUT = "250kW"        -- 5 shield points per second per shield at most; the core's 300 kW is shared
local STIM_TICKS = 8 * 60
local STIM_SPEED = 1.5

local function hidden_item(name, icon, order)
  return {
    type = "item",
    name = name,
    icon = icon,
    icon_size = 64,
    place_as_equipment_result = name,
    subgroup = "rts-units",
    order = order,
    stack_size = 10,
    hidden = true,
    hidden_in_factoriopedia = true,
    auto_recycle = false,
  }
end

-- Core: the vanilla fission reactor's sprite and energy source, at 2x2.
local reactor = data.raw["generator-equipment"]["fission-reactor-equipment"]
assert(reactor, "factorio-rts: missing vanilla fission-reactor-equipment")
local core = table.deepcopy(reactor)
core.name = "rts-commander-core"
core.take_result = "rts-commander-core"
core.shape = {width = 2, height = 2, type = "full"}
core.sprite.scale = (core.sprite.scale or 0.5) / 2
core.power = CORE_POWER
core.burner = nil
core.categories = {"armor"}

-- Shield: the vanilla mk2 shield with the Commander's numbers.
local mk2 = data.raw["energy-shield-equipment"]["energy-shield-mk2-equipment"]
assert(mk2, "factorio-rts: missing vanilla energy-shield-mk2-equipment")
local shield = table.deepcopy(mk2)
shield.name = "rts-commander-shield"
shield.take_result = "rts-commander-shield"
shield.max_shield_value = math.floor(COMMANDER_HEALTH * SHIELD_SHARE + 0.5)
shield.energy_per_shield = SHIELD_ENERGY_PER_POINT
shield.energy_source = {type = "electric", buffer_capacity = "250kJ", input_flow_limit = SHIELD_INPUT,
                        usage_priority = "primary-input"}
shield.categories = {"armor"}

-- Stim: a green copy of the slowdown sticker that speeds up instead.
local slow = data.raw.sticker["slowdown-sticker"]
local stim = {
  type = "sticker",
  name = "rts-stim-sticker",
  flags = {"not-on-map"},
  hidden = true,
  duration_in_ticks = STIM_TICKS,
  target_movement_modifier = STIM_SPEED,
  vehicle_speed_modifier = STIM_SPEED,
}
if slow and slow.animation then
  stim.animation = table.deepcopy(slow.animation)
  stim.animation.tint = {r = 0.2, g = 1.0, b = 0.3, a = 0.6}
end

data:extend({
  core,
  shield,
  stim,
  hidden_item("rts-commander-core", "__base__/graphics/icons/fission-reactor-equipment.png", "z[commander]-c[core]"),
  hidden_item("rts-commander-shield", "__base__/graphics/icons/energy-shield-mk2-equipment.png",
    "z[commander]-d[shield]"),
})

-- Ability bar styles (scripts/abilitygui.lua). Sizes in GUI units; abilitygui.lua's BUTTON matches the button size.
local styles = data.raw["gui-style"].default
styles.rts_ability_button = {type = "button_style", parent = "slot_sized_button", size = 44}
styles.rts_ability_button_armed = {type = "button_style", parent = "slot_sized_button_green", size = 44}
styles.rts_ability_cooldown_bar = {type = "progressbar_style", parent = "progressbar", width = 44, bar_width = 4,
                                   color = {r = 0.35, g = 0.75, b = 1}}
styles.rts_ability_hp_bar = {type = "progressbar_style", parent = "progressbar", width = 150, bar_width = 8,
                             color = {r = 0.3, g = 0.85, b = 0.3}}
styles.rts_ability_key_label = {type = "label_style", parent = "label", font = "default-small-semibold",
                                width = 44, horizontal_align = "center"}
