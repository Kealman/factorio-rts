# Release 0.1.1: interface, inputs, onboarding and the 2.1 look (r2-ux)

Date: 2026-10-24. Engine: Factorio 2.1.23 (mac-arm64, Steam), Space Age on. Agent: `r2-ux`. Issues: #11 (the look of
RTS buildings on 2.1), #12 (custom mouse inputs and the remote view on 2.1), #16 (guided objectives), #17 (Russian
localisation review). GUI runs used a 1280×800 window at UI scale 0.75 on a frozen tree: `git archive HEAD` of
`mods/factorio-rts` plus this agent's changed files, so other agents' work in progress never reached a run.

## 1. Issue #12: custom mouse inputs and the remote view on 2.1

2.1 changed three things under the RTS input path (`docs/qa/phase5-port21-notes.md` section 6): 2.1.7 removed the extra
custom-input event for inputs that collide with the map-drag control, `LuaPlayer::teleport` no longer leaves the remote
view, and the new `LuaPlayer::toggle_menu_leaves_remote_view` decides what the toggle-menu key (Escape) does in the
remote view. The probe below drives the GUI client with real mouse and keyboard input and checks each input a moment
later.

### 1.1 The probe

`tools/probes/r2_inputs_gui.lua` plays a Skirmish match (lobby defaults: 1 opponent, normal, small) and logs
`[rts] r2i real <name>: PASS|FAIL <detail>` for each of 28 real inputs, then the check `remote_never_left`. A watcher logs
every controller change ("r2i probe: controller remote -> god ..."); the last check fails if the player ever left the
remote view after the probe started. When an input misses, the probe does the same thing through the handler, so one
miss does not cascade. The header of the probe has the commands for a run.

| Part | Real inputs (checked by) |
|---|---|
| Lobby | a focus click, **Start match** (the match runs, the view is remote), SPACE (camera on the CC) |
| Selection | a left drag over the six walkers (all selected), a click on empty ground (none), a click on one walker (one), Shift + click on another (two), Shift + left drag (all six) |
| Orders | right click on the ground (six `move`), right click on an enemy walker's body (`attack` on it), right click on its farthest leg (`attack` on the walker, see 1.2), F then a right drag (`attack_move` from the reverse-select event), Shift + right drag and Shift + right click (`attack_move`), X (idle) |
| Camera | D held 0.8 s (the camera pans east), a right click while D is held (a `move` and the pan), Ctrl+1, 1, a double tap of 1 (the camera jumps to the group), a click on the HUD minimap at the enemy CC (the camera jumps there), SPACE |
| Menus | F10 (the RTS menu opens), Escape (it closes, the view stays remote), F10 twice (open, closed), Escape with nothing open (the game menu opens and the view stays remote; a second Escape closes it) |
| Match flow | F10, the menu's **Restart** (back to the lobby, the view remote on the lobby surface), **Start match** again (match 2), Ctrl+Shift+R (match 3, the camera on the CC) |

The probe needs the driver commands added to `tools/gui-input/fdrive.swift` for this issue (all backwards compatible):
`click X Y [shift|ctrl|cmd|alt|a+b]`, `rclick X Y [mods]`, `drag X1 Y1 X2 Y2 [left|right] [mods]`, `key CODE [mods]`,
`keydown CODE`, `keyup CODE`, `hold CODE MS [click|rclick X Y]` (a held key with auto-repeat, optionally a click half
way), `wheel N` and `sleep MS`; `tools/gui-drive.sh` passes every argument of an `RTS_DRIVE` line through.

### 1.2 Findings and fixes

| # | Finding (real input on 2.1) | Fix | Where |
|---|---|---|---|
| 1 | **Escape left the remote view.** With no panel open, Escape switched the player to the god controller on the lobby surface; the camera guard re-entered the remote view on the next tick (`camera: re-applied remote for player 1 (controller changed, was god)`), so the empty lobby flashed for one tick, and the vanilla game menu (save, load, settings, exit) could never be opened with Escape. | `toggle_menu_leaves_remote_view = false` for every player at setup, on join and on init (saves from 0.1.0). Escape now closes an open panel first and otherwise opens the game menu; the view stays remote (0 controller changes in every later run). | `scripts/camera.lua` |
| 2 | **A right click on a pentapod's leg attacked the leg.** When the click misses the body, the reverse selection holds only one of its long legs (type `spider-leg`, with its own unit number and force), and the attack order went to it: `order attack n=6 target=#315 rts-walker-leg (rts-ai-1)`. The Commander's hook skipped legs and walked to the point instead. | `orders.handle_reverse_area` replaces each leg with the spider it belongs to (its `get_spider_legs` among the spiders of the leg's force within 12 tiles, else the nearest of them), once per spider, before any order or hook sees the list. A click 4.5 tiles from the body now gives `attack` on the walker. Only real reverse-select events carry legs, so the Skirmish autotests are unchanged (smoke 65/65). | `scripts/orders.lua` |

Checked and unchanged on 2.1:

- **Every right click and right drag arrived as a reverse-select event** (`fallbacks +0` in every check). The removed
  map-drag custom-input event does not touch the RTS path: `rts-lclick` has no handler, and `rts-rclick` only parks a
  fallback that runs when no reverse-select event follows.
- **Box select, click select, Shift + click, Shift + drag, attack-move by F, Shift + right drag and Shift + right
  click, X, WASD, control groups, the minimap and SPACE** work as on 2.0. A right click while the camera pans with D
  gives its order and the pan goes on.
- **Teleports.** The join flow, the menu's Restart (lobby), the second Start and Ctrl+Shift+R kept the remote view:
  `camera.lua` switches to the god controller before it moves the god body, so the 2.1 change to `teleport` does not
  matter. The Nation flow agrees: the M3 GUI pass on 2.1 (`build/m3i-p21b-{en,ru}-gui.log`) has no
  "re-applied remote" line.
- **Vanilla UI on 2.1.** No side button, alert button or pins panel appears in the window captures of the lobby, the
  HUD, the RTS menu or the game menu (`build/shots-r2-i4-{en,ru}-window/`); `GameViewSettings::show_pins_gui` is
  already off. The protocol coordinates of `docs/qa/phase5-m3-protocol.md` hold on 2.1 (its GUI pass EN 53/53 on 2.1).
  The icon that sometimes shows at the mouse pointer in captures is the RTS cursor (the spidertron remote icon).

Coordinates measured for the Skirmish layout (English and Russian alike): **Start match** (≈740, 513), the F10 menu's
**Restart** (≈533, 438); the Nation menu's Restart is ≈(533, 445) because its match line wraps.

The first real click into a window that has just opened was lost once (the window takes the focus with it): the probe
clicks empty ground of the lobby first.

### 1.3 Runs

| Run | Tree | Result |
|---|---|---|
| `build/r2-i1-en` | HEAD | 20/28: the drag and sequence checks came before the input (waits), the leg attack (finding 2), Escape (finding 1) |
| `build/r2-i3-en` | HEAD + fixes | 28/29: the first lobby click lost (focus) |
| `build/r2-i4-en`, `build/r2-i4-ru` | HEAD + fixes, final probe | **29/29** and **29/29**, 0 Lua errors, 0 remote-view exits |
| `build/r2-smoke12b` | HEAD + fixes + the help text | Skirmish smoke 65/65, 0 errors |

Screenshots: `build/shots-r2-i4-{en,ru}/` (game area) and `build/shots-r2-i4-{en,ru}-window/` (with the title bar); the
game menu after Escape is `r2i-e02-escape.png`.
