-- Custom inputs (docs/PHASE1.md "Input map"). Letter and digit keys use consuming = "game-only" so the
-- vanilla binding on the same key (quickbar slot, pick up items, ...) does not also fire (spike decision 11).
-- No input may sit on W, A, S or D: a game-only input there blocks the vanilla move-* control, which pans
-- the remote-view camera. Hence attack-move = F and stop = X (not the classic A / S).
-- macOS: COMMAND is a separate modifier from CONTROL, so CONTROL bindings get a COMMAND alternative.
local inputs = {
  {name = "rts-lclick", key_sequence = "mouse-button-1", consuming = "none", include_selected_prototype = true},
  {name = "rts-rclick", key_sequence = "mouse-button-2", consuming = "none", include_selected_prototype = true},
  {name = "rts-attack-move", key_sequence = "F", consuming = "game-only"},
  {name = "rts-stop", key_sequence = "X", consuming = "game-only"},
  {name = "rts-hold", key_sequence = "H", consuming = "game-only"},
  -- CONTROL + A only consumes the chord; plain A still reaches the vanilla move-left control.
  {name = "rts-select-all", key_sequence = "CONTROL + A", alternative_key_sequence = "COMMAND + A",
   consuming = "game-only"},
  {name = "rts-camera-home", key_sequence = "SPACE", consuming = "game-only"},
  {name = "rts-give-cursor", key_sequence = "F1", consuming = "none"},
}

for n = 1, 5 do
  inputs[#inputs + 1] = {name = "rts-group-set-" .. n, key_sequence = "CONTROL + " .. n,
                         alternative_key_sequence = "COMMAND + " .. n, consuming = "game-only"}
  inputs[#inputs + 1] = {name = "rts-group-" .. n, key_sequence = tostring(n), consuming = "game-only"}
end

-- Phase 2. Names are controls.<name> in locale/*/factorio-rts.cfg, like every input above.
-- B: build menu (vanilla B is the blueprint library, which the rts permission group blocks anyway).
-- CONTROL + SHIFT + R / E: console-free QA controls (docs/qa/phase1-followups.md item 3); they run the same code
-- as /rts-qa-reset nowaves and /rts-qa-end (debug.run_command).
-- rts-clear-cursor follows the vanilla "clear-cursor" control (Q by default, whatever the player bound it to):
-- it ends ghost placement and brings the RTS cursor back without waiting for the cursor watchdog.
local phase2 = {
  {name = "rts-build-menu", key_sequence = "B", consuming = "game-only"},
  {name = "rts-qa-reset", key_sequence = "CONTROL + SHIFT + R", alternative_key_sequence = "COMMAND + SHIFT + R",
   consuming = "game-only"},
  {name = "rts-qa-end", key_sequence = "CONTROL + SHIFT + E", alternative_key_sequence = "COMMAND + SHIFT + E",
   consuming = "game-only"},
  {name = "rts-clear-cursor", key_sequence = "", linked_game_control = "clear-cursor", consuming = "none"},
  -- Wave C: hover selection is off (camera.lua), so the vanilla R / Shift + R no longer reach a placed entity;
  -- selection.lua rotates the own entity under the cursor itself (the cursor ghost still rotates the vanilla way).
  {name = "rts-rotate", key_sequence = "", linked_game_control = "rotate", consuming = "none"},
  {name = "rts-reverse-rotate", key_sequence = "", linked_game_control = "reverse-rotate", consuming = "none"},
}
for _, input in ipairs(phase2) do inputs[#inputs + 1] = input end

-- Phase 3: the match menu (lobby.lua). Escape is taken by the remote-view controller guard, hence F10.
inputs[#inputs + 1] = {name = "rts-menu", key_sequence = "F10", consuming = "game-only"}

-- Phase 4: the research panel (scripts/techgui.lua). T is the vanilla technology screen, which the RTS forces do not
-- use (their vanilla technologies are disabled), so the input consumes it.
inputs[#inputs + 1] = {name = "rts-tech", key_sequence = "T", consuming = "game-only"}

-- Phase 4 HUD (scripts/hud.lua): F3 jumps the camera to the newest alert (again: the next older one), F11 toggles
-- "How to play". Both are free in vanilla 2.0 (F4/F5 are the debug keys).
inputs[#inputs + 1] = {name = "rts-alert-jump", key_sequence = "F3", consuming = "game-only"}
inputs[#inputs + 1] = {name = "rts-help", key_sequence = "F11", consuming = "game-only"}
-- 0.1.2 (#30, scripts/helpgui.lua): Shift over a building or unit shows its help card. consuming = "none": Shift+click
-- selection and Shift+right-click routes keep working. Shift+F11 / Shift+/ show the same card at once.
inputs[#inputs + 1] = {name = "rts-help-hover", key_sequence = "LSHIFT", alternative_key_sequence = "RSHIFT", consuming = "none"}
inputs[#inputs + 1] = {name = "rts-help-card", key_sequence = "SHIFT + F11", alternative_key_sequence = "SHIFT + SLASH",
                       consuming = "none"}

-- Phase 4: abilities (scripts/abilities.lua). Z Stim, C Shield, V Scanner sweep, G Artillery strike; Overcharge is a
-- button only. Away from WASD, Q/E/R/T, B, F, X, H, M and space, which other inputs or vanilla controls use.
for i, key in ipairs({"Z", "C", "V", "G"}) do
  inputs[#inputs + 1] = {name = "rts-ability-" .. i, key_sequence = key, consuming = "game-only"}
end

-- Phase 5: demolish the selected own building (scripts/demolish.lua; the first press arms, the second within 3 s
-- executes). Delete, or Backspace for keyboards without a Delete key (a Mac laptop's "delete" key sends Backspace).
inputs[#inputs + 1] = {name = "rts-demolish", key_sequence = "DELETE", alternative_key_sequence = "BACKSPACE",
                       consuming = "game-only"}

-- Phase 5 M2 diplomacy: F4 toggles the diplomacy panel (scripts/diplomacygui.lua via hud.lua's key table P4.KEYS).
-- Vanilla F4 is the debug settings window, which the RTS game does not need.
inputs[#inputs + 1] = {name = "rts-diplomacy", key_sequence = "F4", consuming = "game-only"}

-- Phase 5 M2 treasury: M toggles the market panel (scripts/marketgui.lua via hud.lua's key table P4.KEYS). Vanilla M
-- (the map) stays reachable by zooming out of the remote view.
inputs[#inputs + 1] = {name = "rts-market", key_sequence = "M", consuming = "game-only"}

for i, input in ipairs(inputs) do
  input.type = "custom-input"
  input.order = string.format("z[rts]-%02d", i)
end

data:extend(inputs)
