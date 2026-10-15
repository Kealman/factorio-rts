-- Custom inputs (docs/PHASE1.md "Input map"). Letter and digit keys use consuming = "game-only" so the
-- vanilla binding on the same key (quickbar slot, WASD move, ...) does not also fire (spike decision 11).
-- macOS: COMMAND is a separate modifier from CONTROL, so CONTROL bindings get a COMMAND alternative.
local inputs = {
  {name = "rts-lclick", key_sequence = "mouse-button-1", consuming = "none", include_selected_prototype = true},
  {name = "rts-rclick", key_sequence = "mouse-button-2", consuming = "none", include_selected_prototype = true},
  {name = "rts-attack-move", key_sequence = "A", consuming = "game-only"},
  {name = "rts-stop", key_sequence = "S", consuming = "game-only"},
  {name = "rts-hold", key_sequence = "H", consuming = "game-only"},
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

for i, input in ipairs(inputs) do
  input.type = "custom-input"
  input.order = string.format("z[rts]-%02d", i)
end

data:extend(inputs)
