# Results: camera and input spike (spikes #1, #2, #6)

Date: 2026-10-15. Factorio 2.0.77 (build 84539, mac-arm64, Steam), with space-age, quality and
elevated-rails enabled because a fresh mods directory turns them on by default.

| Spike | Question | Verdict |
|---|---|---|
| #1 | Can a player stay in the `remote` controller with no character? Does respawn logic interfere? | **CONFIRMED** (GUI run with one player, 62 s session) |
| #2 | Do `custom-input` mouse buttons and selection-tool area events fire in remote view, with correct positions? | **CONFIRMED** by a Codex computer-use run, see `CODEX-HUMAN-TEST.md` and `docs/research/spikes.md` decisions 10–13. |
| #6 | Does `on_gui_click` fire on `minimap` / `camera` elements? | **CONFIRMED** by the same run: left/right clicks on minimap, camera and button all arrive in `on_gui_click`. |

## How it was tested

- **Headless:** `tools/headless-run.sh 8 '\[rts-camera' spikes/camera-input` reports zero errors in the
  data and control stages. The run has no players, so it only proves loading.
- **GUI client:** `spikes/camera-input/gui-run.sh` creates `build/camera-spike.zip`, launches the
  client with a 1280x800 window and stops it after the scripted self-tests. The log is
  `build/camera-gui.log`. There were no human inputs, so every action came from the script.
- The first GUI attempt failed. See the first gotcha. The second attempt ran 90 s in total, with
  25 s of loading and 62 s in game.

Screenshots, copied from `~/Library/Application Support/factorio/script-output/`:
- `build/rts-camera-120.png`: 2 s after join.
- `build/rts-camera-3000.png`: 50 s after join.
- `build/rts-camera-3400-god.png`: during the god-controller self-test.

## Spike #1: remote controller without a character — CONFIRMED

Setup on `on_player_created` (single player, freeplay scenario):

```
SETUP (created) player=1 tick=0 controller=character physical=character character=true position={0.00, 0.00} multiplayer=false
freeplay state at created: init_ran=true disable_crashsite=true skip_intro=true
player.character = nil -> ok=true err=nil controller_now=god
character.destroy() -> ok=true result=true
set_zoom_limits(remote, {furthest_game_view = {distance = 300, max_distance = 600}}) ok=true err=nil
set_controller{remote} (setup/created) ok=true err=nil target={6.00, 6.00} -> controller=remote physical=god position={6.00, 6.00} physical_position={0.00, 0.00}
give_cursor (setup/created): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
```

Persistence: there were 52 STATUS lines from tick 0 to tick 3060, one per second, all identical
apart from the tick:

```
STATUS tick=60   ... controller=remote physical=god desired=remote position={6.00, 6.00} physical_position={0.00, 0.00} character=false render_mode=chart_zoomed_in zoom=0.200 ...
STATUS tick=3060 ... controller=remote physical=god desired=remote position={6.00, 6.00} physical_position={0.00, 0.00} character=false render_mode=chart_zoomed_in zoom=0.200 ...
```

- **Controller:** it stayed `remote` with no forced change. The watchdog never fired, and no
  respawn, death or character-creation event was raised.
- **Session total:** the player was in `remote` for the whole 62 s session, apart from two scripted
  exits. One lasted a single tick, and the other was 1.7 s of god mode.
- **Errors:** the game logged none. The only Exception line in the log is a crop-cache version
  notice.

Recovery from leaving remote view, which the script simulated with `exit_remote_view()`, the same
path as M, Escape or the close button:

```
SELFTEST exit_remote_view() ok=true result=nil -> controller=god
EVENT on_player_controller_changed old=remote new=god physical=god desired=remote ...
CONTROLLER CHANGED (event): remote -> god while desired=remote; re-applying next tick
set_controller{remote} (reapply/event) ok=true ... -> controller=remote physical=god position={6.00, 6.00}
```

The re-apply happens one tick later, about 15 ms. The camera goes back to its last remote position
`{6, 6}`, not to the god body at `{0, 0}`. Whether the player sees a flicker is part of the human
test.

The god toggle, which uses the same code as F2, also works:
`set_controller{god}` returns `ok=true`, the teleport returns `ok=true`, and then
`set_controller{remote}` returns `ok=true`.

Screenshots:
- **2 s and 50 s:** the window shows the vanilla remote-view frame, titled "Remote view" in the
  client's locale, with search, rotate, back/forward and close buttons. The world shows the 10
  biters and the car, and there is no character. The right side has the research hint and the
  remote-view minimap with "Add tag" and "Add ping" buttons. The quickbar and shortcut bar are at
  the bottom. The spike frame with the help text, minimap, camera and "Control button" is at the
  top left. Between the two screenshots the biters wandered, and the camera element shows them
  live.
- **God self-test:** the remote-view frame is gone. The plain game HUD remains, the minimap has no
  tag or ping buttons, and there is no character at the god position.

## Spike #2: mouse custom inputs and selection events — READY FOR HUMAN TEST

Confirmed without a human:
- The data-stage prototypes are valid as written: the selection tool with all four modes, the
  shortcut, and the custom inputs on `mouse-button-1/2/3`, `CONTROL + 1`, `1`, `F1` and `F2`, plus
  two linked to `toggle-map` and `clear-cursor`.
- A selection tool can live in the cursor of a `remote` controller.
  `cursor_stack.set_stack{name="rts-cursor"}` works and `cursor_stack_temporary` is false.
- The re-insert path works. The cursor emptied by a controller switch was refilled by the
  `on_player_cursor_stack_changed` handler.

Not tested: every mouse-driven event. `spikes/camera-input/TEST-PROTOCOL.md` lists 20 steps with
the expected log lines. The most important open points are listed below.
- Do the four `on_player_*selected_area` events fire in remote view with world coordinates?
- Does a plain right click with no drag fire `reverse_select`, and with what area?
- Does `CustomInputEvent.cursor_position` hold the world position under the mouse in remote view?
- Does `consuming = "game-only"` on a mouse button suppress vanilla remote-view actions?
- Does Ctrl or Cmd plus a digit reach Lua on macOS?

## Spike #6: clicks on minimap and camera elements — READY FOR HUMAN TEST

Confirmed: a `screen` frame with a `minimap` (200x200, zoom 0.5) and a `camera` (200x200, zoom
0.25, centered on the units) renders in remote view and in god view. The camera updates live. Both
elements accept `raise_hover_events = true`.

Not tested: `on_gui_click` on these elements. The mod also logs `on_gui_hover`, `on_gui_leave` and a
left-click custom input with `in_gui` and `element`. If `on_gui_click` does not fire, the custom
input's `element` and `cursor_display_location` still give a click-to-jump fallback.

## Gotchas found (API or behaviour different from expectations)

1. **The Steam build will not start with arguments.** Launching the binary directly prints
   "Steam requires game restart, restarting..." and exits within 1 s. Steam does not relaunch it,
   so the arguments are lost. The fix is to set the environment variables
   `SteamAppId=427520 SteamGameId=427520`, which needs no file in the game install.
   `tools/` should adopt this for any GUI run.
2. **The scenario's handlers run before the mod's.** When our `on_player_created` ran, freeplay had
   already run its own (`init_ran=true`). Crash site and intro must therefore be disabled in
   `on_init`. These calls all returned `ok=true`:
   - `remote.call("freeplay", "set_disable_crashsite", true)`
   - `set_skip_intro`
   - `set_created_items({})`
   - `set_respawn_items({})`
3. **`--create` runs `on_init` but no ticks.** "On first tick" logic runs in whichever session loads
   the save next.
4. **`player.character = nil` switches character to god immediately.** After that,
   `character.destroy()` returns true. This is the sandbox pattern, and it works in freeplay.
5. **`on_player_controller_changed` is deferred and coalesced.** Setup switched character, then
   god, then remote. That produced a single event, `old=character new=remote`, raised after
   `on_tick` of that tick, not inside `set_controller`. A re-entrancy flag around `set_controller`
   is useless. Compare the new type to a stored "desired" controller instead.
6. **The two ways back to god differ:**
   - `exit_remote_view()` returns to the existing physical god at its old position `{0, 0}` and keeps
     the cursor.
   - `set_controller{type = god}` from remote creates a new god at the camera position with an
     empty cursor. No cursor event fires at that moment. It fired only after returning to remote.
   - `teleport` works on a characterless god.
7. **Remote view never reports `render_mode = game`.** It was `chart_zoomed_in` at zoom 0.2 and
   0.133, and `chart` at 0.08. `game` appears only in god mode. The docs give no description for
   these values. `chart_zoomed_in` is the 1.x "zoom to world" mode, which renders world graphics.
8. **`furthest_game_view` is not proven to work.** The switch to `chart` fell between about 300
   and 500 tiles across, which matches our setting of 300 tiles. The engine default was not
   recorded, so this does not prove the setting had an effect. The mod now logs
   `default zoom_limits` before overriding.
9. **The zoom on entering remote is chosen by the engine.** It was 0.2 on the first entry. After
   re-entry from god it was 0.133, which is exactly 1280 px / (32 px × 300 tiles). Set
   `player.zoom` explicitly after `set_controller`.
10. **Default remote zoom limits** read back as `closest = {zoom = 3}` and
    `furthest = {zoom = 0.00390625}`.
11. **`set_zoom_limits` takes two positional arguments**, `(controller_type, zoom_limits)`, not a
    table.
12. **`take_screenshot` does not show the player's view.** It renders at its own `zoom`, which
    defaults to 1. With `show_gui = true` it does include the real GUI, including the remote-view
    frame. The files land in `~/Library/Application Support/factorio/script-output/`. The mod now
    adds a screenshot that passes the player's zoom.
13. **`always_include_tiles` belongs to the tool, not to each mode.** It is a field of
    `SelectionToolPrototype`, not of `SelectionModeData`, and the docs call it "a visual only
    setting".
14. **Digit keys are valid key names.** `"1"` and `"0"` work in `key_sequence`. On macOS `COMMAND`
    is a separate modifier from `CONTROL`, so bind both, using `alternative_key_sequence` for one.
15. **The vanilla remote-view chrome is the main thing breaking the RTS look.** It has a title bar,
    a close button, a surface search, the quickbar and the shortcut bar. A `GameViewSettings` pass
    is needed, and the close button is one more way out of remote view.
16. **Idle units wander.** The `small-biter` units with no command moved several tiles in 50 s, as
    the design doc expects.

## Recommendations for the real mod

- **Use `remote` over a characterless `god` physical controller as the RTS camera.** It persisted
  with no interference and recovers in one tick. Keep the `god` fallback in reserve. It works too,
  with `set_controller{god}` plus `teleport`, and it renders in `game` mode, but its zoom-out is
  limited.
- **Controller guard:** store a desired controller per player. On `on_player_controller_changed`,
  if the type differs, re-apply on the next tick at the last remote position. Keep a cheap
  60-tick watchdog as a backstop.
- **Re-give the RTS Cursor after every controller change** and on `on_player_cursor_stack_changed`
  when the cursor is empty. Use the `only-in-cursor` and `spawnable` flags plus a `spawn-item`
  shortcut as the manual fallback.
- **On entering remote, set `player.zoom` explicitly.** Treat `furthest_game_view` as unverified
  until the default is compared.
- **Hide the vanilla remote-view HUD** with `game_view_settings`: tool bar, quickbar, shortcut bar
  and surface list. Then check in the human test which parts of the remote-view frame remain.
- **Freeplay setup:** do it in `on_init` through the `freeplay` remote interface, or ship a custom
  scenario so that no level script runs before ours.
- **Input mechanism:** wait for the human test before committing. The current plan is selection-tool
  events for select and order, with a `mouse-button-2` custom input using `consuming = "none"` as
  a second source of point positions. Use `consuming = "game-only"` on mouse buttons only if the
  test shows vanilla remote-view actions interfering.

## Files

- `spikes/camera-input/rts-spike-camera_0.0.1/`: the spike mod, made of `info.json`, `data.lua`,
  `control.lua` and the English locale.
- `spikes/camera-input/TEST-PROTOCOL.md`: the human test, with expected log lines per step.
- `spikes/camera-input/gui-run.sh`: the automated GUI run. It opens a window for about 85 s.
- `spikes/camera-input/mod-list.json`: generated by Factorio for this mods directory.
- Under `build/`:
  - `camera-gui.log`, the GUI client log.
  - `camera-spike-create.log`, the save-creation log.
  - `camera-input-server.log`, the headless log.
  - The three screenshots.

Changes made to `control.lua` after the GUI run, so they have not been run with a player yet:
- It logs the default remote zoom limits before overriding them.
- It re-gives the cursor in the `on_player_controller_changed` handler.
- It takes an extra screenshot at the player's own zoom 3 s after join.
- The headless run still loads with zero errors.
