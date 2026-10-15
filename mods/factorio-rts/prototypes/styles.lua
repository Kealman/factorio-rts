-- GUI styles and fonts for scripts/hud.lua.
--
-- Sizes that the HUD's screen placement depends on (panel width and height, minimap size) are also set
-- from hud.lua at runtime, so the numbers that matter live in one place.
local styles = data.raw["gui-style"].default

-- "default-mono" is a locale font family (NotoMono, DejaVuSansMono fallback) declared by the core
-- locale; locales without a font section fall back to English, so it exists for every language.
data:extend({
  {type = "font", name = "rts-mono", from = "default-mono", size = 14},
  {type = "font", name = "rts-mono-large", from = "default-mono", size = 18},
})

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

-- Slim panel: the vanilla frame graphics, no title bar, tight padding and spacing.
styles.rts_hud_frame = {
  type = "frame_style",
  parent = "frame",
  top_padding = 6,
  right_padding = 8,
  bottom_padding = 6,
  left_padding = 8,
  vertical_flow_style = {type = "vertical_flow_style", vertical_spacing = 4},
  horizontal_flow_style = {type = "horizontal_flow_style", horizontal_spacing = 8},
}

-- Decorative frame behind the minimap (the minimap itself is a separate `screen` element on top).
styles.rts_hud_minimap_frame = {
  type = "frame_style",
  parent = "frame",
  padding = 0,
}

styles.rts_hud_minimap = {
  type = "minimap_style",
  parent = "minimap",
  size = 220, -- the vanilla style's minimal size is 256
}

-- Horizontal row inside a panel: children vertically centred.
styles.rts_hud_row = {
  type = "horizontal_flow_style",
  vertical_align = "center",
  horizontal_spacing = 6,
}

-- Same, centred horizontally (top strip).
styles.rts_hud_centered_row = {
  type = "horizontal_flow_style",
  parent = "rts_hud_row",
  horizontal_align = "center",
  horizontally_stretchable = "on",
  horizontal_spacing = 10,
}

styles.rts_hud_filler = {
  type = "empty_widget_style",
  horizontally_stretchable = "on",
}

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------

-- Small text button: vanilla button graphics, smaller font, no 108 px minimum width.
styles.rts_hud_button = {
  type = "button_style",
  parent = "button",
  font = "default-semibold",
  minimal_width = 0,
  height = 26,
  left_padding = 6,
  right_padding = 6,
}

-- Control-group indicator: "1  12".
styles.rts_hud_group_button = {
  type = "button_style",
  parent = "rts_hud_button",
  font = "default-small-bold",
  width = 54,
  height = 24,
  left_padding = 2,
  right_padding = 2,
}

---------------------------------------------------------------------------
-- Labels
---------------------------------------------------------------------------

styles.rts_hud_label = {
  type = "label_style",
  parent = "label",
  font = "default-semibold",
}

styles.rts_hud_dim_label = {
  type = "label_style",
  parent = "label",
  font = "default-small-semibold",
  font_color = {0.72, 0.72, 0.72},
}

styles.rts_hud_heading_label = {
  type = "label_style",
  parent = "label",
  font = "default-bold",
  font_color = {1, 0.84, 0.6}, -- vanilla caption orange
}

-- Numbers that change every refresh (counts, health): monospaced so the row does not jitter.
styles.rts_hud_mono_label = {
  type = "label_style",
  parent = "label",
  font = "rts-mono",
}

styles.rts_hud_timer_label = {
  type = "label_style",
  parent = "label",
  font = "rts-mono-large",
  font_color = {1, 0.92, 0.7},
}

styles.rts_hud_message_label = {
  type = "label_style",
  parent = "label",
  font = "default-semibold",
  font_color = {1, 0.85, 0.3},
}
