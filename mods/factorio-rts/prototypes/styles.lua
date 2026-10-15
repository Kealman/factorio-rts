-- GUI styles. hud.lua will add its styles here; Phase 1 only defines the bottom panel frame.
local styles = data.raw["gui-style"].default

styles.rts_hud_frame = {
  type = "frame_style",
  parent = "frame",
}
