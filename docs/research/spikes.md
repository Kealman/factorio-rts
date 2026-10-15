# Phase 0 spikes — summary (2026-10-15)

Detailed evidence lives in each spike's `RESULTS.md` under `spikes/`. This page records the verdicts and the design decisions taken from them.

| # | Question | Verdict | Evidence |
|---|---|---|---|
| 1 | Player can stay in `remote` controller with no character | **CONFIRMED** | GUI run, 62 s session, no respawn, no character; leaving remote view is caught by the controller-changed event and reverted next tick (`spikes/camera-input/RESULTS.md`) |
| 2 | Mouse-button custom inputs and selection-area events fire in remote view with positions | **OPEN — needs mouse input** | Test mod + 20-step protocol ready (`spikes/camera-input/TEST-PROTOCOL.md`). Codex computer-use was denied access to the Factorio app; a human run takes ~5 min |
| 3 | `spider-unit` as primary controllable unit: orders, hold, groups, combat, UPS | **CONFIRMED** | 48/48 `go_to_location` completions, cross-force combat resolves in ~25 s, 400 walkers fighting at 60 UPS (`spikes/units/RESULTS.md`) |
| 4 | Barracks pattern: assembler output → spawned unit | **CONFIRMED** | 20/20 kits → units, 0-tick latency with predicted-completion scheduling, ~6 µs per barracks per poll (`spikes/economy/RESULTS.md`) |
| 5 | AI base built by script for a force with no players, production runs | **CONFIRMED** | 22/22 ghosts from a 573-char blueprint string, revived in 210 ticks, 34.0 plates/min vs 33.75 theoretical |
| 6 | `on_gui_click` on minimap/camera GUI elements | **OPEN — needs mouse input** | Elements render and update in remote view (screenshot); click delivery untested |

## Decisions taken

1. **Camera = remote view over a characterless god body.** On join: freeplay crash site/intro off via remote interface in `on_init`, character destroyed, `set_controller{remote}`. Guard with a stored "desired controller" and re-apply on the controller-changed event (it is delayed and merged, so do not use re-entry flags). Set `player.zoom` explicitly (default varies between 0.2 and 0.133). Hide the vanilla remote-view frame, quickbar and shortcut bar later via `GameViewSettings`/permission groups.
2. **Units = `spider-unit`, with Space Age optional.** When Space Age is loaded, pentapod-based prototypes; otherwise spider-units assembled from base spidertron graphics. Pentapod hit/death particles cost up to 3.3 ms/tick at 400 units, so the real mod trims those effects.
3. **Hold position = `defines.command.stop`.** Works for both unit classes (spider-units coast up to 3 tiles first). `wander{radius=0}` only works for plain `unit`. Units with no command wander 8–12 tiles, so every idle unit must get `stop`.
4. **Unit groups do not need `ai_controllable`.** `create_unit_group` works with it off, so player forces keep `ai_controllable = false` (no engine expansion). Watch for the engine occasionally creating its own groups in large fights.
5. **Attack-move re-targets the nearest enemy.** `attack_area` aimed at an enemy centroid stalls once armies split; the real mod re-issues attack commands toward the nearest enemy entity.
6. **`set_multi_command` is not usable for walkers** (only picks idle `unit`-type entities). AI waves use explicit groups.
7. **Barracks: predictive scheduling.** Compute the completion tick from `crafting_progress`, recipe energy and `crafting_speed`; check at that tick, with a slow fallback sweep. No engine event exists for "assembler finished a craft".
8. **AI construction: blueprint strings + calibrated layout + paced revive.** `build_blueprint{force, build_mode=defines.build_mode.*}` needs no player; mining-drill ghosts are silently skipped without ore, so verify ghost counts. Blocking trees must be removed by script before revive. `clone_area` (7 ms for 51 entities, exact copy) is reserved for identical match-start bases.
9. **Team colour** uses `apply_runtime_tint` layers on spider-unit torso/leg masks (confirmed read by the prototype checker; visual confirmation pending a GUI run). `LuaEntity.color` is nil for units.

## Open items carried into Phase 1

- Spikes #2 and #6 (input mechanism and GUI clicks). Until resolved, the input layer is built with both candidates behind a switch: selection-tool `reverse_select` for orders vs. `mouse-button-2` custom input.
- Visual check of force tint and of hiding the vanilla remote-view chrome.
- `set_zoom_limits{furthest_game_view}` effect on `render_mode` (only `chart_zoomed_in`/`chart` observed in remote view).
- Real power for barracks (spike used a void energy source) and burst spawns.

## Tooling gotchas (now handled in `tools/`)

- The Steam build exits with "Steam requires game restart" unless `SteamAppId=427520 SteamGameId=427520` are set; Steam must be running for the GUI client.
- Factorio holds an exclusive `.lock` in its write-data dir and binds a UDP port; parallel runs need a per-run `-c config.ini` (own `write-data`) and `--port`. `tools/headless-run.sh` and `tools/gui-run.sh` do both automatically.
- The server overwrites its save on exit; benchmarks need a fresh `--create` save each time.
- `take_screenshot` is a no-op headless, and in the GUI it renders at its own zoom (though it includes the GUI).
- `game.forces` is userdata (`pairs` only); `storage` replaces `global`; `helpers.write_file` replaces `game.write_file`.
