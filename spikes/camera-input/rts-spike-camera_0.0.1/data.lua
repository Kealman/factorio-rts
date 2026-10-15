-- Spike data stage: one selection tool (the "RTS Cursor"), a shortcut that spawns it,
-- and custom inputs that probe mouse and keyboard handling in remote view.

-- Entity types the RTS Cursor can pick up with select / alt_select.
local UNIT_TYPES = {"unit", "spider-unit", "spider-vehicle", "character", "car"}

data:extend({
  {
    type = "selection-tool",
    name = "rts-cursor",
    icon = "__base__/graphics/icons/spidertron-remote.png",
    icon_size = 64,
    -- only-in-cursor: the item vanishes when the cursor is cleared instead of going to an inventory.
    -- spawnable: allows the shortcut / custom input "spawn-item" path.
    flags = {"only-in-cursor", "not-stackable", "spawnable"},
    subgroup = "spawnables",
    order = "z[rts]-a[cursor]",
    stack_size = 1,
    -- Tool-level flag (not per mode). The docs call it "a visual only setting".
    always_include_tiles = true,
    -- Left drag: replace selection with own units.
    select = {
      mode = {"any-entity", "same-force"},
      border_color = {r = 0.2, g = 1, b = 0.2},
      cursor_box_type = "entity",
      entity_type_filters = UNIT_TYPES,
    },
    -- Shift + left drag: add to selection.
    alt_select = {
      mode = {"any-entity", "same-force"},
      border_color = {r = 0.2, g = 0.6, b = 1},
      cursor_box_type = "copy",
      entity_type_filters = UNIT_TYPES,
    },
    -- Right click / drag: order target (anything in the box, any force).
    reverse_select = {
      mode = {"any-entity"},
      border_color = {r = 1, g = 0.3, b = 0.2},
      cursor_box_type = "not-allowed",
    },
    -- Shift + right drag: attack-move.
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
    icon = "__base__/graphics/icons/spidertron-remote.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/spidertron-remote.png",
    small_icon_size = 64,
    order = "z[rts]-a[cursor]",
  },

  -- Keyboard / mouse probes. include_selected_prototype adds event.selected_prototype.
  {type = "custom-input", name = "rts-give-cursor", key_sequence = "F1", consuming = "none",
   include_selected_prototype = true},
  {type = "custom-input", name = "rts-rclick", key_sequence = "mouse-button-2", consuming = "none",
   include_selected_prototype = true},
  {type = "custom-input", name = "rts-rclick-consuming", key_sequence = "mouse-button-3", consuming = "game-only",
   include_selected_prototype = true},
  -- Extra probe (not in the original brief): left click, to see cursor_position / element / in_gui
  -- when clicking the world and the minimap/camera GUI elements.
  {type = "custom-input", name = "rts-lclick", key_sequence = "mouse-button-1", consuming = "none",
   include_selected_prototype = true},
  -- macOS: CONTROL is the Control key; COMMAND is a separate modifier there, so bind both.
  {type = "custom-input", name = "rts-cg-1", key_sequence = "CONTROL + 1", alternative_key_sequence = "COMMAND + 1",
   consuming = "none"},
  {type = "custom-input", name = "rts-recall-1", key_sequence = "1", consuming = "none"},
  {type = "custom-input", name = "rts-toggle-controller", key_sequence = "F2", consuming = "none"},
  -- Linked probes: fire whenever the vanilla control fires (hidden from the controls GUI).
  -- toggle-map (M) is how a player leaves remote view; clear-cursor (Q) drops the RTS Cursor.
  {type = "custom-input", name = "rts-linked-toggle-map", key_sequence = "", linked_game_control = "toggle-map"},
  {type = "custom-input", name = "rts-linked-clear-cursor", key_sequence = "", linked_game_control = "clear-cursor"},
})
