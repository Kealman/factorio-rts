# Test protocol: camera and input spike (spikes #1, #2, #6)

Mod: `spikes/camera-input/rts-spike-camera_0.0.1/`. Every finding is written to the game log with the
prefix `[rts-camera]`. The game log is the launching terminal's stdout, or
`~/Library/Application Support/factorio/factorio-current.log`.

## Setup (about 2 minutes)

Steam must be running. The `SteamAppId` and `SteamGameId` variables are required. Without them the
Steam build prints "Steam requires game restart, restarting..." and exits without loading the save.

```sh
cd ~/Projects/home/games/factorio_rts
source tools/factorio-env.sh
"$FACTORIO_BIN" --mod-directory spikes/camera-input --create build/camera-spike.zip
SteamAppId=427520 SteamGameId=427520 "$FACTORIO_BIN" --mod-directory spikes/camera-input \
  --load-game build/camera-spike.zip --window-size 1280x800 --disable-audio | tee build/camera-human.log
```

Create a fresh save for every session: the mod's self-tests run once per join and the save is never
written back.

The automated self-tests run between about 50 and 59 seconds after the save loads. They briefly
leave remote view, zoom out twice, switch to god mode and back. Wait until the chat shows nothing
new, or the log shows `SELFTEST done`, before you start. You can also start right away and ignore the
camera jumps in that window.

After loading you should see:
- The map in remote view centered near {6, 6}, with 10 small biters and a car around {10, 10}. There
  is no engineer and no crash site.
- An "RTS spike: minimap / camera" frame on the left with help text, a minimap, a camera view of the
  biters, and a "Control button".
- The RTS Cursor (spidertron remote icon) in the cursor.

## Steps and expected log lines

Each step lists the expected line, or the line whose absence is the finding. Note what actually
happened next to each step.

| # | Action | Expected log line(s) | Answers |
|---|---|---|---|
| 1 | Wait 60 s without input. | One `STATUS ... controller=remote ... character=false` per second. There should be no `CONTROLLER CHANGED`. | #1 |
| 2 | Left-drag a box over the biters. | `INPUT rts-lclick ... cursor_position={x, y}`, then `SELECT on_player_selected_area item=rts-cursor ... entities=N [unit:small-biter@player, ...] controller=remote` | #2 |
| 3 | Left-drag over empty ground. | `SELECT on_player_selected_area ... entities=0`. If nothing is logged, empty selections do not fire. | #2 |
| 4 | Shift + left-drag over the biters. | `SELECT on_player_alt_selected_area ... entities=N` | #2 |
| 5 | Right-click (no drag) on empty ground. | `INPUT rts-rclick ... cursor_position=...`, and possibly `SELECT on_player_reverse_selected_area ... (0.00x0.00)` or a tiny area. Record whether a plain click fires the reverse selection. | #2 |
| 6 | Right-drag over the biters and some trees. | `SELECT on_player_reverse_selected_area ... entities=N [...]` with biters and trees | #2 |
| 7 | Right-click directly on one biter. | `INPUT rts-rclick ... selected_prototype=entity/unit/small-biter`, plus a reverse selection containing that biter | #2 |
| 8 | Shift + right-drag. | `SELECT on_player_alt_reverse_selected_area ...` | #2 |
| 9 | Middle-click on the map. | `INPUT rts-rclick-consuming ...` (middle button, `consuming="game-only"`). Note any vanilla action that still happened. | #2 |
| 10 | Press Ctrl+1, then Cmd+1 (macOS), then 1. | `INPUT rts-cg-1` for each modifier that works, `INPUT rts-recall-1` for 1. Note whether the vanilla quickbar also reacted. | #2 |
| 11 | Press F2, wait 3 s, press F2 again. | `TOGGLE (F2): remote -> god`, `set_controller{god} ... ok=true`, `teleport god ...`, and `give_cursor (after controller change)`, because a new god controller starts with an empty cursor. Then `TOGGLE (F2): god -> remote`. Note whether the camera jumped and whether WASD moves the god camera. | #1 |
| 12 | Press M (map toggle), then Escape. | `INPUT rts-linked-toggle-map`, `EVENT on_player_controller_changed old=remote new=god`, `CONTROLLER CHANGED (event)`, then on the next tick `set_controller{remote} (reapply/event) ok=true`. Note whether the view flickered. | #1 |
| 13 | Scroll the wheel all the way out, then back in. | `STATUS ... render_mode=game` until roughly 300 tiles across, then `chart` or `chart_zoomed_in`. Note the zoom value at the switch. | #1 |
| 14 | Click the minimap with the left button, then the right button. | `GUI_HOVER element=minimap:rts_minimap`, `GUI_CLICK element=minimap:rts_minimap button=left ...`. A missing `GUI_CLICK` refutes #6 for the minimap. Also check `INPUT rts-lclick ... in_gui=true element=minimap:rts_minimap`. | #6 |
| 15 | Click the camera element. | Same as step 14 with `camera:rts_camera` | #6 |
| 16 | Click "Control button". | `GUI_CLICK element=button:rts_button button=left` (control case) | #6 |
| 17 | Press Q to clear the cursor. | `INPUT rts-linked-clear-cursor`, `EVENT on_player_cursor_stack_changed cursor=empty`, `give_cursor (re-insert after cursor emptied): set_stack ok=true ... cursor=rts-cursor` | #2 |
| 18 | Press F1. | `INPUT rts-give-cursor`, `give_cursor (F1): ... cursor=rts-cursor` | #2 |
| 19 | Click the RTS Cursor shortcut in the shortcut bar, if it is shown. | The cursor shows the tool again. `EVENT on_lua_shortcut` is not expected, because spawn-item shortcuts are handled by the engine. | #2 |
| 20 | Hover the mouse over a biter. | `HOVER selected=unit:small-biter at {...}` | input model |

## What to send back

- `build/camera-human.log`, or just the output of the grep below.
- The `default zoom_limits` line from the log. Compare its `furthest_game_view` with the zoom at which step 13 switched to `chart`.
- A one-line note per step: whether it worked and anything odd, such as a vanilla action also firing
  or the camera jumping.

```sh
grep "\[rts-camera\]" build/camera-human.log | grep -v STATUS
```
