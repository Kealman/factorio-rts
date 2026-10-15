# Phase 1 skeleton: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/` (name `factorio-rts`, 0.1.0).
Plan: `docs/PHASE1.md`. Verified facts used: `docs/research/spikes.md` decisions 1–13.

## What is implemented

| File | Status | What it does |
|---|---|---|
| `info.json`, `data.lua` | done | `base >= 2.0`, `? space-age` |
| `prototypes/units.lua` | done | `rts-walker` (200 hp, range 20) and `rts-walker-heavy` (600 hp, range 10/12) as `spider-unit`. With Space Age they are pentapod copies with wriggler spawns, stickers and leg-death particles removed. Without it they use base spidertron graphics. Mask layers use `apply_runtime_tint`, so units take the force colour. |
| `prototypes/cursor.lua` | done | `rts-cursor` selection tool with the four modes from PHASE1, and the `rts-give-cursor-shortcut` (`spawn-item`) |
| `prototypes/inputs.lua` | done | Every input from the PHASE1 table. Letters and digits use `consuming = "game-only"`. CONTROL bindings have a COMMAND alternative for macOS. |
| `prototypes/map-settings.lua` | done | `max_failed_behavior_count = 1000000`, enemy expansion and evolution off |
| `prototypes/styles.lua` | placeholder | `rts_hud_frame` (parent `frame`) |
| `locale/en/factorio-rts.cfg` | done | Names for entities, the item, the shortcut and every control |
| `control.lua` | done | Requires the modules in dispatch order and wires each module's idempotent `init()` to `on_init` and `on_configuration_changed` |
| `scripts/events.lua` | done | Multi-handler bus: `on`, `on_nth_tick`, `on_init`, `on_load`, `on_configuration_changed` |
| `scripts/util.lua` | done | `log`, `pstorage`, `surface`, `define_name`, `xy`, `pos_str`, `distance(_sq)`, `centroid`, `is_rts_unit`, force-name constants |
| `scripts/camera.lua` | done | Remote view over a characterless god body, controller guard, zoom, chrome hiding, `rts` permission group, home on SPACE, freeplay setup, dev GUI self-test |
| `scripts/cursor.lua` | done | Gives the tool after setup, re-inserts it when the cursor empties or the controller changes, F1 forces it back |
| `scripts/units.lua` | done | Registry, spawn, death and destroy cleanup, idle rule (`stop`), `on_removed` callbacks |
| `scripts/match.lua` | done | Forces, 160×160 arena, 24 units per side, enemy waves, win/lose |
| `scripts/debug.lua` | done | `/rts-spawn`, `/rts-dump`, `/rts-autotest`, headless autotest, one-off chart probe |
| `scripts/selection.lua`, `orders.lua`, `hud.lua` | stubs | `init()` logs `[rts] <module>: stub` |

Match rules as built:

- **Armies.** Each side gets 20 walkers in a 4×5 block and 4 heavies in a column in front of them, facing the enemy. The player side is at x = -50 and the enemy at x = +50.
- **Enemy waves.** The first wave goes 45 s after the armies spawn, then one every 90 s. Each wave is one `create_unit_group` holding every enemy unit, sent with `attack_area` (radius 16, `distraction = by_anything`) to the centroid of the player units.
- **Re-targeting.** When the group's command completes, it is sent to the nearest player unit. When the group dies, any surviving members go back to `idle` and `stop`.
- **End of match.** A 1 s check prints Victory, Defeat or Draw when a side has 0 units.

The 45 s first wave is a deviation from "every 90 s". It lets the 70 s headless run exercise the enemy brain.

## Validation

| Check | Result |
|---|---|
| `tools/headless-run.sh 70 '\[rts' mods` (Space Age, quality and elevated-rails enabled by default) | 0 errors in the data, create and server stages |
| Same run with Space Age, quality and elevated-rails disabled (copy in `build/rts-nosa/`) | 0 errors |
| `--check-unused-prototype-data` | No "was not used" warnings for our prototypes |
| `tools/gui-run.sh mods 75 'RTS_GUI_READY'` | Ran in this session; the sandbox did not block it. 4 runs, 0 errors in `build/mods-gui.log`. |

Headless autotest, final code (excerpt from `build/mods-server.log`):

```
[rts] autotest: on (0 connected players at tick 120)
[rts] rts-spawn: 2 x rts-walker for rts-player near (-50.0, 0.0)          <- console command path
[rts] rts-player: 26 units [heavy=4 walker=22] orders [idle=26]
[rts] autotest: started at tick 120, go_to_location (0.0, 0.0) issued to 5 walkers [17,23,29,35,41]
[rts] autotest: move completed by #41 result=success at (-1.7, -0.1), 2.7 tiles from its destination [5/5]
[rts] autotest: attack-move issued to 5 units (all moves completed)
[rts] autotest t=30s player=25 (walker 21, heavy 4) enemy=23 (walker 19, heavy 4) autotest_alive=4 ...
[rts] match: enemy wave 1: group #317 with 21 units from (41.8, -4.4) -> attack_area (-53.6, 2.4)
[rts] autotest t=60s player=3 (walker 3, heavy 0) enemy=11 (walker 7, heavy 4) ...
[rts] match: ended at tick 4140, winner=rts-enemy (player units=0, enemy units=10)
```

The base-only run also ended with `winner=rts-enemy`. In both, all 5 moves completed with `success`, 2.1–2.8 tiles short of the destination. That matches spike #3's coasting.

## What the GUI run showed

The log line at setup (`build/mods-gui.log`):

```
camera: setup (created) player 1: controller=remote physical=god character=false position=(-52.9, 0.0) zoom=0.500
        render_mode=game cursor=rts-cursor force=rts-player group=rts chrome_still_shown=[]
```

Screenshots are in `build/shots-mods/rts-p1-120.png` and `rts-p1-900.png`, at the player's zoom and position with `show_gui = true`:

- **Remote view, no character.** The camera is centred on the own army: 20 walkers and 4 heavies, blue-tinted pentapods, on the grass arena. The arena edge and trees show at the left.
- **Vanilla chrome is all hidden.** No quickbar, shortcut bar, minimap, research info, side menu or alert icons are visible. The vanilla "Remote view" frame (title bar, search, close button), which the camera spike's screenshots showed, is also gone. Nothing from vanilla remains in the screenshot.
- **Controller guard, event path.** `exit_remote_view()` at tick 330 is followed by `re-applied remote ... (controller changed, was god)` one tick later, with zoom 0.5 restored and the cursor kept.
- **Home jump.** `camera.home` moved the camera from (-52.9, 0) to (-50, 0) and kept zoom 0.5.
- **Force tint.** It reads as a blue-grey tint on the torsos. That is subtle at zoom 0.5, but the two sides should be distinguishable. The enemy side was not on screen.
- **Not checkable from screenshots.** The mouse cursor is not drawn, so the selection-tool cursor icon was not visually checked. The log shows `cursor=rts-cursor`.

## Exact settings used

`player.game_view_settings` fields set to `false` (all verified in `runtime-api.json` `GameViewSettings`):
`show_controller_gui`, `show_minimap`, `show_research_info`, `show_alert_gui`, `show_crafting_queue`, `show_tool_bar`,
`show_quickbar`, `show_shortcut_bar`, `show_side_menu`, `show_map_view_options`, `show_surface_list`,
`show_hotkey_suggestions`.
These are left at their defaults: `show_entity_info` (alt mode), `show_entity_tooltip`, `show_rail_block_visualisation` and `update_entity_selection`. Hover must keep working, so `update_entity_selection` stays on.
Writing the fields on the struct returned by `player.game_view_settings` takes effect directly; no write-back was needed.

Permission group `rts` (created in `camera.init`, players added in `camera.setup`). These 24 `defines.input_action` values are blocked:
`toggle_map_editor`, `open_character_gui`, `craft`, `cancel_craft`, `toggle_driving`, `change_shooting_state`,
`begin_mining`, `begin_mining_terrain`, `pipette`, `quick_bar_pick_slot`, `quick_bar_set_slot`,
`quick_bar_set_selected_page`, `change_active_quick_bar`, `open_blueprint_library_gui`, `open_production_gui`,
`open_logistics_gui`, `open_trains_gui`, `open_achievements_gui`, `open_bonus_gui`, `toggle_personal_roboport`,
`toggle_personal_logistic_requests`, `toggle_equipment_movement_bonus`, `drop_item`, `use_item`.

These actions are deliberately allowed:

- `start_walking`. Remote-view WASD panning is server-side state and may use this action. Blocking it could freeze the camera, and there is no character to walk anyway.
- `clear_cursor`. Q clears the cursor and the re-insert handler refills it.
- The four `*select_area` actions, `remote_view_*`, all `gui_*`, `build`, `custom_input`, `lua_shortcut`, `spawn_item` (the cursor shortcut) and `write_to_console`.

Zoom: `player.set_zoom_limits(defines.controllers.remote, {closest = {zoom = 2}, furthest = {zoom = 0.15}, furthest_game_view = {zoom = 0.15}})`, then `player.zoom = 0.5`, which is about 80 tiles across at 1280 px.

## API gotchas found in this phase

1. **`table.deepcopy` is nil in the control stage.** It comes from the core `util` lualib, which control does not load by default. The first `on_init` crashed on it. The mod now copies tables explicitly.
2. **The starting chunks exist before `on_init`.** In `--create`, chunk (0,0) is already generated when `on_init` runs. Setting `map_gen_settings.autoplace_controls["enemy-base"].size/frequency = 0` therefore only affects chunks generated later; the read-back confirms 0/0. `match.init` destroys `enemy`-force entities that map gen had already placed: 5–16 per run, even in the starting area. `peaceful_mode` is not used.
3. **A chart requested in `on_init` of `--create` never happens.** The arena chart now runs in the first second of a ticking session (`storage.match.charted`).
4. **A headless server with no players never charts.** At tick 600 both spawn chunks read `charted=false visible=false`, even with units carrying `radar_range = 1`. With a GUI player both chunks read `charted=true visible=true` at tick 600. This includes the enemy spawn chunk, which is far from any player unit, so the arena chart gives vision too. Whether that visibility lasts is untested; see the open items.
5. **`render_mode` is stale in the setter's tick.** It reads `game` in the same tick as `set_controller{remote}` and `chart_zoomed_in` afterwards. Decision 12 still holds.
6. **Nth-tick handlers of different periods run in the same tick.** In the first GUI runs the self-test exited remote view at tick 300, and the 60-tick watchdog re-applied it in the same tick, before the event path. The exit was moved to tick 330 to prove the event path; it re-applies in one tick.
7. **The wave group's `attack_area` never completed.** This matches spike #3: the group stays in `attacking_distraction` while enemies remain. The re-target-on-completion branch and the "group gone, release orphans" branch therefore did not run in these tests.
8. **`take_screenshot` needs the player's view passed in.** It needs `position = player.position` and `zoom = player.zoom` to show what the player sees. It renders at zoom 1 around the player otherwise (spike #1 gotcha 12).
9. **Stopped units lose to a moving wave.** Units on `stop` (default `distraction = by_enemy`) do fight back, but the stationary player army lost 21 units to 10 against a wave with `distraction = by_anything`. This is a balance note, not a bug.

## Known issues and decisions for the lead

- **A and S block WASD panning.** `rts-attack-move` (A) and `rts-stop` (S) use `consuming = "game-only"` as the brief and PHASE1 require. That blocks the vanilla `move-left` and `move-down` bindings, which pan the remote camera. Expect the camera to pan only up and right with WASD. The GUI run sent no keyboard input, so this is unverified. One option is `consuming = "none"` for A and S, which lets panning happen as well. The other is moving attack-move and stop to keys that do not collide with WASD.
- **The cursor shortcut is not clickable.** `show_shortcut_bar = false` hides it. F1 is the only way to get the cursor back if the re-insert ever fails.
- **The GUI self-test runs for every human player.** `GUI_SELFTEST = true` in `camera.lua` exits remote view 5.5 s after join, re-enters it, jumps home at 10 s and writes two screenshots to `script-output`. Turn it off, or move it behind a setting, before a release or the Codex QA protocol. The one-off chart probe in `debug.lua` (a single log line at tick 600) is harmless.
- **The engine can create its own unit groups.** Spike #3 gotcha 6 saw it for non-AI forces in big fights; it did not happen here. There is no mitigation in Phase 1.

## Hooks for the selection, orders and HUD agents

General rules:

- **Register through the bus at module top level.** Use `events.on(defines.events.X or "rts-input-name", fn)` and `events.on_nth_tick(n, fn)`, never `script.on_event`. Handlers run in the order modules are first required; `control.lua` lists selection, orders, hud, debug after units, match, camera and cursor.
- **Expose an idempotent `init()`.** `control.lua` calls it on `on_init` and on `on_configuration_changed`. Create your storage tables there, with `storage.x = storage.x or {}`.
- **Use `util.pstorage(player_index)` for per-player state.** Add only your own fields: `selection`, `groups` and `boxes` for selection.lua, `hud` for hud.lua.
- **Log with `util.log(fmt, ...)`.** It adds the "[rts]" prefix, and `tools/headless-run.sh` picks those lines up.

`scripts/units.lua` (registry, `storage.units[unit_number] = {entity, force, kind, order, target?, dest?}`):

- `units.get(unit_number)` returns the record or nil, and drops stale records.
- `units.for_force(force_name)` is an iterator over `(unit_number, record)` for live units.
- `units.count(force_name, kind?)` and `units.centroid(force_name)`.
- `units.spawn(name, position, force_name, kind?, surface?)` returns `entity, record`. A new unit starts as `order = "idle"` with a `stop` command.
- `units.stop(entity)` issues `defines.command.stop`.
- `units.on_removed(fn(unit_number, record))` is called when a unit dies or is destroyed. Register it at load time. Selection uses it to drop units from selections and groups; rendering objects attached to the entity are destroyed by the engine.
- `units.IDLE == "idle"`. **Claim rule:** a record whose `order ~= "idle"` belongs to whoever set it, and that module handles its `on_ai_command_completed`. On completion of an unclaimed unit, units.lua issues `stop`. orders.lua owns `order`, `target` and `dest` for player orders, and must set `order = "idle"` and call `units.stop` when an order ends.
- Other writers of `order`:
  - match.lua sets `"attack_move"` on `rts-enemy` wave members, which are in a unit group.
  - debug.lua sets `"autotest"`. orders.lua should ignore units with that value.

`scripts/camera.lua`:

- `camera.jump_to(player, position)` keeps the zoom. Use it for minimap click-to-jump.
- `camera.home(player)` jumps to the player's spawn. SPACE is already bound to it.
- `camera.setup(player, reason)` is the full setup; the join handlers already call it.
- Owned fields: `storage.players[i].desired_controller` (always `"remote"`), `last_remote_pos`, `last_zoom`, `setup_done`.

`scripts/cursor.lua`: `cursor.ensure(player, force_replace?)`. F1 is already handled.

`scripts/match.lua`:

- `match.home(force_name)` and `match.spawn_armies()`, which only spawns a force that has no units.
- `match.assign_player(player)`.
- `storage.match` fields: `phase`, `wave`, `enemy_next_wave`, `enemy_group`, `winner`. hud.lua can show the wave countdown from `enemy_next_wave - game.tick`.

`scripts/debug.lua`:

- `debug_tools.dump_lines()` returns the state summary.
- `debug_tools.run_command(name, parameter)` runs an `/rts-*` command from script.
- `debug_tools.start_autotest()`. When orders.lua exists, switch the autotest to call `orders.move` and `orders.attack_move` instead of raw `set_command`, so the headless run exercises orders.lua as PHASE1 asks.

Events the stub modules should handle (all registered as custom inputs, all unhandled today):

- **selection.lua:**
  - The four selection events: `on_player_selected_area` (select), `on_player_alt_selected_area` (add), `on_player_reverse_selected_area` (order) and `on_player_alt_reverse_selected_area` (attack-move). Each has `e.item == "rts-cursor"`.
  - Control groups: `rts-group-set-1..5` and `rts-group-1..5`.
  - `rts-select-all`.
- **orders.lua:**
  - The reverse-select events.
  - `rts-attack-move` (arms the next right click), `rts-stop` and `rts-hold`.
  - `rts-rclick` for modifier variants. `e.cursor_position` is the world position, and `e.in_gui` and `e.element` mark clicks over the HUD.
  - `on_ai_command_completed` for its claimed units.
- **hud.lua:**
  - `on_gui_click` on a `minimap` element. This fires (spike #6). Map `e.cursor_display_location` to a world position and call `camera.jump_to`.
  - `rts-lclick` with `in_gui = true` as a fallback.
  - The vanilla minimap is hidden, so the HUD minimap is the only one.

## Open items

- Whether the arena chart keeps the enemy side visible after the initial reveal. The minimap needs to show the enemy army: acceptance item 5. If it does not stay visible, re-chart the arena periodically or give `rts-player` a hidden radar.
- The force-tint contrast between the two sides at normal zoom. Only the player army was on screen.
- WASD panning versus the game-only A and S bindings. This needs a keyboard test in the Codex QA protocol.
