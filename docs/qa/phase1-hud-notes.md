# Phase 1 HUD: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Files: `mods/factorio-rts/scripts/hud.lua` and
`mods/factorio-rts/prototypes/styles.lua`. No other file was changed. `control.lua` needs no change, because it
already requires `scripts.hud` after `scripts.camera`, so the HUD is built after the camera setup.

## What the HUD shows

There are three areas, all in `player.gui.screen`. Every size is in GUI units, multiplied by `player.display_scale`
on screen.

| Area | Position | Size (GUI units) | Content |
|---|---|---|---|
| Selection panel | bottom-left, 8 from the edges | 420 × 122 | Count ("24 units selected"); kinds ("Walker ×20   Heavy ×4"); average health ("HP 100%", green/yellow/red); order ("Order: Idle", or the two most common orders, as in "Move 8, Idle 4"). Four buttons: Attack-move [F], Stop [X], Hold [H], Select all [Ctrl+A], each with a tooltip. Group indicators 1–5 ("1: 24"). |
| Match strip | top-centre, 8 from the top | 420 × 64 | Timer mm:ss from `storage.match.tick_started`, frozen when the match ends. Then "Army N vs N Enemy" from `units.count`, and a message line. |
| Minimap | top-right, 8 from the edges | 220 × 220 inside a 228 × 228 frame | The 160-tile arena plus an 8-tile rim, centred on {0, 0}. |

The message line shows one of these:

- "Preparing the arena...", until the match is running.
- "Enemy wave N in m:ss", from `enemy_next_wave`.
- "Enemy wave N is attacking!" in red, for 10 s after `storage.match.wave` goes up.
- Victory in green, or Defeat or Draw in red or yellow, once `phase == "ended"`.

Placement at 1280×800, computed by `place()` and matching the screenshots:

| UI scale | Panel | Strip | Minimap element |
|---|---|---|---|
| 0.75 (what `tools/gui-run.sh` gets: automatic UI scale) | (6, 702), 315 × 92 px | (483, 6), 315 × 48 px | (1106, 9), 165 px |
| 1.25 (custom scale, separate run) | (10, 637), 525 × 153 px | (378, 10), 525 × 80 px | (990, 15), 275 px |

Nothing overlaps at either scale, and the text is readable at 0.75. Screenshots:

- `build/shots-mods/rts-hud-600.png` and `rts-hud-720.png`: the final run on `mods/`.
- `build/shots-mods-hud-s1.25/`: the 1.25 scale run.
- `build/shots-mods-hud/rts-hud-600.png` and `rts-hud-3000.png`: the calibration and map-colour experiment, described below.

Refresh:

- **On change.** `hud.refresh(player_index)` is called by selection.lua after each change and by the HUD's own buttons.
- **Every 30 ticks.** A refresh for every connected player covers counts, dead units (skipped, never removed from another module's set) and the timer.
- **Missing HUD.** A refresh rebuilds the HUD when any of its elements is missing.
- **Display changes.** `on_player_display_resolution_changed` and `on_player_display_scale_changed` re-place the three areas.

## API (scripts/hud.lua)

- `hud.init()` is called on `on_init` and `on_configuration_changed`. It creates `storage.hud` and rebuilds the HUD of every player.
- `hud.build(player)` destroys and rebuilds the HUD. It is idempotent and runs on `on_player_created` and `on_player_joined_game`.
- `hud.refresh(player_index)` is cheap. It ignores unknown or disconnected indices, for example the autotest's index 0.
- `hud.destroy(player)`.
- Owned state:
  - `storage.players[i].hud`: element references.
  - `storage.hud = {wave_seen, wave_tick, ended_tick}`: match-event tracking, because `storage.match` has no tick for a wave launch or for the end of the match.

## What the HUD calls in selection.lua and orders.lua

Every call is optional. A missing function makes the button do nothing except a `player.print` and a log line.

| HUD control | Calls (the first one that exists) |
|---|---|
| Attack-move [F] | `orders.attack_move_pending(pi)`, then `orders.arm_attack_move(pi)` (toggle). The button shows as toggled while `orders.is_armed(pi)` is true. |
| Stop [X] | `orders.stop(pi)` |
| Hold [H] | `orders.hold(pi)` |
| Select all [Ctrl+A] | `selection.select_all(pi)` |
| Group button n | `selection.group_recall(pi, n)`, else `selection.recall_group(pi, n)`. Empty groups are disabled. A group equal to the current selection shows as toggled. |

The HUD reads `storage.players[i].selection` and `.groups[1..5]` (sets of unit numbers) and `storage.units`, read only.
The key labels F, X, H and Ctrl+A are plain strings in `COMMANDS` in `hud.lua`. They match `prototypes/inputs.lua` as of today.

Verified in the GUI run: Select all through the button path selected 24 units. `selection.group_set(1)` then showed
"1: 24" as toggled. The armed attack-move state and the Stop and Hold buttons were not clicked in any run.

## Minimap click: maths and accuracy

The minimap element is a direct child of `screen`, with a decorative frame behind it, so `minimap.location` is its own
top-left corner. In display pixels, the space of both `GuiLocation` and `cursor_display_location`:

```
s      = player.display_scale
centre = minimap.location + (220 * s) / 2
ppt    = K * minimap.zoom * s            -- display pixels per tile, K = 1.0
world  = minimap.position + (cursor_display_location - centre) / ppt
```

`camera.jump_to(player, world)` is then called, and the click is logged, for example:
`hud: minimap click player 1 button=left display=(1235, 92) minimap at (1106, 9) offset from centre=(46.5, 0.5) px -> world (49.6, 0.5)`.
Left and right clicks both jump.

**Calibration.** K is the GUI pixels per tile at minimap zoom 1. It came from screenshots with chart tags at known
positions (`HUD_CALIBRATE`), measured against the arena edges and the tags:

| Run | Minimap zoom | UI scale | Predicted px/tile | Measured | Centre predicted → measured |
|---|---|---|---|---|---|
| 1 | 0.25 | 0.75 | 0.1875 if K = 1 | arena 30 px / 160 tiles = 0.1875; tags 24 px / 128 tiles | n/a |
| 2 | 1.25 | 0.75 | 0.9375 | arena 150 px / 160 tiles = 0.9375 | (1188.5, 91.5) → (1189, 92) |
| 3 | 1.25 | 1.25 | 1.5625 | arena 250 px / 160 tiles = 1.5625 | (1127.5, 152.5) → (1128, 153) |

The minimap content scales with `display_scale`, so the same arena is shown at any UI scale. The own walker block
was predicted at x = 1133–1142 px and found at about 1132–1143 px.

**Error margin.** The screenshot measurements agree with the maths to within 1 display pixel. At 0.75 scale that is
±1.1 tiles; at 1.25 it is ±0.65 tiles. `cursor_display_location` is an integer, which adds ±0.5 px. The synthetic
round trip, world to pixel to world, is 0.4–0.7 tiles. Both are far below what matters for a camera jump.

**Not verified.** No real mouse click was made in these runs. The synthetic click calls the same handler with a
computed `cursor_display_location`, and the camera jumped to the enemy army (`rts-hud-720.png`). Two pieces of
evidence say that `cursor_display_location` and `GuiLocation` share an origin, the top-left of the game's client
area:

- The spike #6 human test: Codex clicked at screen (90, 335) and the event reported (90, 307). The 28 px difference is the macOS title bar.
- Screenshots and click coordinates in that test line up.

A real click on a known minimap point, for example a calibration tag, belongs in the Codex QA protocol.

## Gotchas found

1. **`require()` fails inside event handlers.** "require() can not be used in the console, in event listeners or during a remote.call" (`doc-html/auxiliary/libraries.html`). The lead's suggested `pcall(require, "scripts.orders")` inside a handler always fails. The HUD looks modules up in `package.loaded` instead.
2. **`package.loaded` is keyed by the resolved file, not by the `require()` argument.** It holds `"__factorio-rts__/scripts/orders.lua"`, not `"scripts.orders"`; this was logged from `on_init`. `hud.lua` tries both keys. selection.lua's `hud_module()` used `loaded["scripts.hud"]` and so would never reach `hud.refresh`. I told the selection/orders agent. The HUD still updates every 30 ticks without it.
3. **The automatic UI scale is 0.75 in `tools/gui-run.sh`.** The isolated config has no `[interface]` section, so the automatic scale gives 0.75 at 1280×800. The user's own config has `automatic-ui-scale=false`, which means 1.0. For a fixed scale in a test, add `[interface] automatic-ui-scale=false, custom-ui-scale=<s>` to the run's `config.ini`.
4. **Display values are placeholders in `on_player_created`.** `display_resolution` reads 1920×1080 and `display_scale` reads 1 there. The real values arrive about 17 ms later in the same session start, through `on_player_display_resolution_changed` and then `on_player_display_scale_changed`. The HUD re-places itself on both.
5. **A minimap inside a frame did not sit where the frame's padding said.** With `padding = 4`, and also with all four paddings explicit plus `style.padding = 4` at runtime, the style read back 4. Yet the minimap was drawn about 8.7 GUI px in from the frame's location and overflowed the right edge. Putting the minimap directly in `screen` removed the guesswork.
6. **The vanilla `minimap` style has a minimal size of 256.** `rts_hud_minimap` sets `size = 220`.
7. **A label style with `horizontally_stretchable = "on"` cannot be centred.** It fills its row and its text stays left-aligned. The message label is now natural width, inside a centred flow.
8. **Own units are not drawn on the minimap.** The enemy army is drawn as red dots, with no prototype change. `friendly_map_color` alone did not help. Adding `map_color` (together with `friendly_map_color`) on both unit prototypes drew the own army in blue, and moving units left no trails. This was tested in a private copy (`build/shots-mods-hud/rts-hud-600.png` and `rts-hud-3000.png`), not in `mods/`. See the action for `prototypes/units.lua` below.
9. **Enemy units stay visible on the minimap.** At tick 3000, 50 s in and 5 s into wave 1, the wave was drawn live as it moved toward the player army. This closes the skeleton's open item about whether the arena chart keeps the enemy visible, at least for 50 s.
10. **The minimap shows the player's name at the god body, not at the camera.** The orange "SayJay" marker sits at {0, 0}, which is where the god body is, and not where the remote-view camera looks. Players may read it as "you are here".
11. **Chart tags appear on `minimap` elements.** Both the icon and the text show. That is what made the calibration possible.
12. **`default-mono` is a locale font family.** It is NotoMono with a DejaVuSansMono fallback, in `core/locale/en/info.json`. A `font` prototype with `from = "default-mono"` works, and is used for the counts and the timer.

## For the lead

- **`prototypes/units.lua` (not mine): own units on the minimap.** Add map colours to both unit prototypes. Acceptance item 5 needs this to show both armies:
  ```lua
  map_color = {0.35, 0.65, 1}, friendly_map_color = {0.35, 0.65, 1}, enemy_map_color = {1, 0.15, 0.1},
  ```
- **Dev flags at the top of `hud.lua`.** All three run at fixed game ticks; turn them off before a human QA session.
  - `HUD_DEBUG_SHOT = true`: screenshots at ticks 600, 720 and 3000, then the `RTS_HUD_DONE` marker. Harmless.
  - `HUD_SELFTEST = true`: intrusive. At tick 540 it selects the whole army and assigns group 1. At tick 660 the camera jumps to the enemy spawn, and at tick 780 it jumps back home.
  - `HUD_CALIBRATE = false`: when on, adds 4 chart tags at tick 180.
- **The minimap frame's 4 px rim lets clicks through to the world.** It has `ignored_by_interaction = true`, so that it can never steal clicks from the minimap drawn over it.
- **Chat lines may overlap the selection panel.** `game.print` and `player.print` lines appear at the bottom-left, over the panel; this was not checked in a screenshot.
- **Not exercised in any run:**
  - Victory, Defeat and Draw messages, because no match ended within the 60 s runs.
  - Tooltips.
  - Stop, Hold and Attack-move clicks.
  - Multiplayer.
  - A real minimap click.
- **The Codex QA protocol should cover these.** Click the minimap at a visible unit cluster and compare the logged world position with where the camera lands. Click each button. Press F and check that the Attack-move button shows as toggled.

## Validation

| Check | Result |
|---|---|
| `tools/headless-run.sh 40 '\[rts' mods` | 0 errors. With no players the HUD handlers idle. This run was one edit before the final code; the last edit only touched a GUI self-test step. |
| Same script on a snapshot of the final `mods/` under its own run ID (`build/mods-hudfinal`) | 0 errors in the create and server logs, selection and orders autotest checks PASS. The snapshot was needed because the selection/orders agent's runs on `mods` held the write-data lock. |
| `tools/gui-run.sh mods 60 'RTS_GUI_READY'` (final code) | 0 errors in `build/mods-gui.log`. Screenshots `build/shots-mods/rts-hud-600.png` and `rts-hud-720.png`. |
| Private copy `build/mods-hud` with the map-colour experiment, run to tick 3000 | 0 errors. Both armies on the minimap; the enemy wave tracked live. |
| Private copy at custom UI scale 1.25 (scratch script, `[interface]` override) | 0 errors. Layout and minimap maths confirmed. |
