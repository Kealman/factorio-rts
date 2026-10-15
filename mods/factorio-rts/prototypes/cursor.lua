-- The RTS cursor: one selection tool that lives in the cursor of the remote-view camera, plus a
-- shortcut that re-spawns it. See docs/research/spikes.md decision 10 for the input model:
--   left drag            = select              (own units, replaces the selection)
--   shift + left drag    = alt_select          (own units, added to the selection)
--   right click / drag   = reverse_select      (any entity: 0x0 area on ground = move, on enemy = attack)
--   shift + right drag   = alt_reverse_select  (attack-move)
local UNIT_TYPES = {"spider-unit", "unit"}
local ICON = "__base__/graphics/icons/spidertron-remote.png"

data:extend({
  {
    type = "selection-tool",
    name = "rts-cursor",
    icon = ICON,
    icon_size = 64,
    -- only-in-cursor: vanishes when the cursor is cleared instead of going to an inventory.
    -- spawnable: allows the shortcut's spawn-item path.
    flags = {"only-in-cursor", "not-stackable", "spawnable"},
    subgroup = "spawnables",
    order = "z[rts]-a[cursor]",
    stack_size = 1,
    select = {
      mode = {"any-entity", "same-force"},
      border_color = {r = 0.2, g = 1, b = 0.2},
      cursor_box_type = "entity",
      entity_type_filters = UNIT_TYPES,
    },
    alt_select = {
      mode = {"any-entity", "same-force"},
      border_color = {r = 0.2, g = 0.6, b = 1},
      cursor_box_type = "copy",
      entity_type_filters = UNIT_TYPES,
    },
    reverse_select = {
      mode = {"any-entity"},
      border_color = {r = 1, g = 0.3, b = 0.2},
      cursor_box_type = "not-allowed",
    },
    alt_reverse_select = {
      mode = {"any-entity"},
      border_color = {r = 1, g = 0.8, b = 0.1},
      cursor_box_type = "pair",
    },
  },
  {
    type = "shortcut",
    name = "rts-give-cursor-shortcut",
    action = "spawn-item",
    item_to_spawn = "rts-cursor",
    associated_control_input = "rts-give-cursor",
    icon = ICON,
    icon_size = 64,
    small_icon = ICON,
    small_icon_size = 64,
    order = "z[rts]-a[cursor]",
  },
})
