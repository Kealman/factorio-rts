# Phase 1 interactive QA protocol

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam), Space Age enabled. Mod `factorio-rts` 0.1.0.
Covers the acceptance checklist in `docs/PHASE1.md`. The tester is an automated agent with computer use that clicks in
a 1280×800 game window and can run shell commands to read the game log.

## Launch (lead)

The session runs from a frozen copy of the mods dir, so other agents' runs and edits cannot change or overwrite it.
`tools/gui-run.sh` names its log after the mods dir, so the log is `build/qa-p1-gui.log`.

```sh
cd "$(git rev-parse --show-toplevel)"   # the repository root
tools/gui-run.sh build/qa-p1 3600 'RTS_QA_END'
```

`build/qa-p1/` is a copy of `mods/` taken at 17:43 on 2026-10-15. It also holds the Phase 2 data prototypes
(`prototypes/buildings.lua`, `categories.lua`, `items.lua`, `recipes.lua`) that another agent was adding at that time.
It was validated headless with Space Age (34 of 34 autotest checks, zero errors) and in the GUI (zero errors).
To test the current `mods/` instead, refresh it:
`rm -rf build/qa-p1 && mkdir -p build/qa-p1 && cp -R mods/factorio-rts mods/mod-list.json build/qa-p1/`.

The script blocks until the log contains `RTS_QA_END`, which the last step writes, or for at most one hour. Steam
must be running. The GUI self-test is off by default, so no scripted step moves the camera during the session.

## Tester setup

- **Window.** The game window is 1280×800. All coordinates below are in the game's drawing area. Its top-left corner
  is below the macOS title bar, which adds about 28 px on screen.
- **Keyboard.** Use the English (US) input source. The console key is the backtick ``` ` ```. Typing in the console does
  not trigger game hotkeys.
- **Start.** Wait until the arena with the blue army and the HUD is visible, and the log has `RTS_GUI_READY` (about 16 s
  after the game starts).
- **Reading the log.** Note the line count before each step, then search only the new lines:

  ```sh
  LOG=build/qa-p1-gui.log   # relative to the repository root
  wc -l < "$LOG"                                  # before the step: note the number N
  tail -n +$((N+1)) "$LOG" | grep -E 'PATTERN'    # after the step
  ```

  Every mod line contains `[rts]`. The patterns below are `grep -E` patterns and use no `|`.
- **Evidence.** Take a screenshot after every step. Report each step as PASS or FAIL with the matching log line, or
  with the last 20 new `[rts]` lines when nothing matched.
- **Chat.** Console replies and `/rts-dump` output appear at the bottom-left for a few seconds, over the HUD panel.
  Wait until the text fades before clicking HUD buttons.

### Where things are (UI scale 0.75, the automatic scale at 1280×800)

| Element | Location |
|---|---|
| Selection panel | x 6–321, y 702–794. First line: "No units selected" or "N units selected". |
| Buttons | centres at y ≈ 754: Attack-move [F] x ≈ 56, Stop [X] x ≈ 122, Hold [H] x ≈ 176, Select all [Ctrl+A] x ≈ 249 |
| Group buttons 1–5 | centres at y ≈ 776: x ≈ 66, 110, 154, 198, 242 |
| Match strip | x 483–798, y 6–54: timer, "Army N vs N Enemy", message line |
| Minimap | x 1106–1271, y 9–174, centre (1188, 92). Own army (blue) at about (1142, 92); enemy army (red) at about (1235, 92). |
| Camera view | 16 px per tile at the start zoom 0.5; the screen centre (640, 400) is the camera position |

After `/rts-qa-reset` the camera is at the own spawn (-50, 0). The army fills about x 480–760, y 260–520: 20 walkers in
a 4×5 block and 4 heavies in a column on its right side. The enemy army mirrors it at (50, 0), out of view.
Orders take the unit's body (the raised torso), not its legs.

## Steps

| # | Action | What should visibly happen | Expected log line (`grep -E`) |
|---|---|---|---|
| 0 | No input. Inspect the screenshot. | Top-down view of the arena with no character. The HUD has three areas: the selection panel, the strip and the minimap. There is no vanilla quickbar, shortcut bar, vanilla minimap or research panel. The minimap shows a blue block on the left and a red block on the right. | Search the whole log, not only new lines: `RTS_GUI_READY player 1: controller=remote` |
| 1 | Press `` ` ``, type `/rts-qa-reset nowaves`, press Enter. Do this before the first enemy wave (45 s after the game starts); if the wave already came, the reset still recovers. | Chat line "qa-reset by player=1 ... enemy waves off". Camera over the full blue army. HUD: "No units selected"; strip message "Enemy waves off (/rts-qa-reset nowaves)". | `qa-reset by player=1: .*spawned player=24 enemy=24.*enemy waves off` |
| 2 | Hold W for about 1 s (or tap W 5 times) | The view scrolls up: the army moves down on screen. | `camera pan player=1 .* d=\([-0-9.]+, -[0-9.]+\)` (second number negative) |
| 3 | Hold S for about 1 s | The view scrolls down. | `camera pan player=1 .* d=\([-0-9.]+, [0-9.]+\)` (second number positive) |
| 4 | Hold A for about 1 s | The view scrolls left. A must not trigger select-all or any order. | `camera pan player=1 .* d=\(-[0-9.]+, ` (first number negative) |
| 5 | Hold D for about 1 s | The view scrolls right. | `camera pan player=1 .* d=\([0-9.]+, ` (first number positive) |
| 6 | Mouse wheel up 3 notches over the arena, wait 1 s, then down 3 notches | Zooms in (units bigger), then back out | `camera zoom player=1 [0-9.]+ -> [0-9.]+` at least twice: the value grows, then shrinks |
| 7 | Press SPACE | The camera snaps back to the own army at the screen centre. | `camera home player=1 -> \(-50\.0, 0\.0\)` |
| 8 | Box select: a short left drag from (440, 230) to (800, 540), over the whole army | A light-blue box around every unit. Panel: "24 units selected", "Walker ×20 Heavy ×4", "Order: Idle". | `select mode=replace drag n=24 ` (n ≥ 20 is acceptable if the drag missed a corner) |
| 9 | Left click on the body of one walker, e.g. the top-left one | Only that unit keeps a box. Panel: "1 unit selected". | `select mode=replace click n=1 ` |
| 10 | Shift + left click on a different walker | Two boxes. Panel: "2 units selected". | `select mode=add click n=2 ` |
| 11 | Press Ctrl+1. If no line appears, press Cmd+1. | Group button 1 reads "1: 2" and shows as pressed. | `group set 1 n=2 player=1` |
| 12 | Press Ctrl+A (Cmd+A on macOS also works) | Every unit gets a box. Panel: "24 units selected". Note in the report whether the view also panned left; that is a finding, not a FAIL. | `select all n=24 player=1` |
| 13 | Press 1 | The selection drops to the 2 units of group 1. No quickbar appears and the cursor is unchanged. | `group recall 1 n=2 player=1` and no `cursor given` line in the same new lines |
| 14 | Optional: pan away with D (1 s), then press 1 twice within 0.3 s | The camera jumps to the 2 units of group 1. | `group recall 1 n=2 player=1 double-tap camera -> ` |
| 15 | Press SPACE, then left click on empty grass, away from all units | All boxes disappear. Panel: "No units selected". | `select mode=replace click n=0 ` |
| 16 | Press Ctrl+A, then right click on empty ground at (1000, 400) | A green circle flashes at the click. The army walks right and stops in a spread grid around that point, not in a pile. Panel: "Order: Move", then "Order: Idle". | `order move n=24 dest=\(` and no `without a reverse-select event` line |
| 17 | Wait for the army to stop. Press F, then right click on ground at (300, 400). | After F, the text "Attack-move: right-click the target" appears near the cursor and the Attack-move button shows as pressed. After the click, an amber circle appears, the army walks left and the button is no longer pressed. Panel: "Order: Attack-move", then "Order: Idle" after arrival. | `attack-move armed player=1`, then `order attack-move n=24 dest=\(` |
| 18 | Right click on ground at (1150, 600). Within 1 s, while the army walks, press X. | The army halts where it is. Panel: "Order: Idle". | `order stop n=24 player=1` |
| 19 | Press H | The units stay put. Panel: "Order: Hold". | `order hold n=24 player=1` |
| 20 | Left click the red block on the minimap at about (1235, 92) | The camera jumps to the red-tinted enemy army. The selection (own units, now off-screen) is kept. | `hud click minimap player=1 source=mouse .* -> world \(` with a world x between 40 and 60, and `camera jump player=1 -> ` |
| 21 | Right click on the body of an enemy walker near the screen centre | A red circle appears on that enemy. After about 10 s the blue army arrives from the left and fires at it; the fight spreads to nearby enemies. Panel: "Order: Attack". | `order attack n=24 target=#[0-9]+ rts-walker.* \(rts-enemy\)` |
| 22 | Press `` ` ``, type `/rts-qa-reset nowaves`, press Enter | Fresh armies at both spawns and the camera back at the own army. Panel: "No units selected"; all group buttons empty. | `qa-reset by player=1: .*spawned player=24 enemy=24` |
| 23 | Press Q | The cursor is emptied and immediately refilled with the RTS cursor. Nothing else changes. | `cursor given player=1 reason=cursor emptied ok=true` |
| 24 | Press F1, then do the step 8 drag again | Boxes on the whole army: the tool still works. | `cursor F1 player=1 tool_in_hand=true`, then `select mode=replace drag n=` |
| 25 | Press M, wait 2 s, then press Escape. If the game menu opens, press Escape once more. | The map or a zoomed-out view may show briefly. Within about 1 s of Escape, the view is again the remote view over the arena: the HUD is visible, there is no character and no vanilla GUI. | Either `camera render_mode player=1 ` or `camera: re-applied remote for player 1` may appear; none is required. Step 26 decides. |
| 26 | Press `` ` ``, type `/rts-dump`, press Enter | Chat shows the state summary. | `player 1 \(.*\): desired=remote controller=remote setup_done=true` |
| 27 | Click the HUD button "Select all [Ctrl+A]" | Boxes on every unit. Panel: "24 units selected". | `hud click select-all player=1 result=24` |
| 28 | Click the HUD button "Attack-move [F]" | The button shows as pressed; the text "Attack-move: right-click the target" appears. | `hud click attack-move player=1 result=true` |
| 29 | Click "Attack-move [F]" again | The button is no longer pressed; the text "Attack-move cancelled" appears. | `hud click attack-move player=1 result=false` |
| 30 | Click the HUD button "Stop [X]" | Panel: "Order: Idle". | `hud click stop player=1 result=24` |
| 31 | Click the HUD button "Hold [H]" | Panel: "Order: Hold". | `hud click hold player=1 result=24` |
| 32 | Press Ctrl+2, click empty grass to clear the selection, then click group button 2 at about (110, 776) | After Ctrl+2 the button reads "2: 24". The click on grass clears the boxes. The click on the button selects all 24 again and shows it as pressed. | `group set 2 n=24`, then `hud click group 2 player=1 selected=24` |
| 33 | Press `` ` ``, type `/rts-qa-reset` (no argument), press Enter. Wait 50 s. | The strip counts down "Enemy wave 1 in 00:45". After 45 s it reads "Enemy wave 1 is attacking!" in red, and the red block on the minimap moves left toward the blue one. | `enemy waves on, next in 45s`, then `match: enemy wave 1: group #[0-9]+ with 24 units` |
| 34 | Optional: press Ctrl+A, click the minimap on the red dots, then right click an enemy. Wait up to 90 s. | Fights resolve with explosions and dying units. When one side has no units left, the strip shows Victory, Defeat or Draw, and a chat line repeats it. | `match: ended at tick [0-9]+, winner=` |
| 35 | Press `` ` ``, type `/rts-qa-end`, press Enter | The state summary is printed, and the game closes about 3 s later. | `RTS_QA_END by player=1` |

## Recovery

- **Lost the army or the camera.** Press SPACE, or run `/rts-qa-reset nowaves`. Both armies are re-spawned, every
  selection and group is cleared, an armed attack-move is cancelled and the camera goes home.
- **Lost the cursor.** Drags then do nothing and no `select mode=` line appears. Press F1.
- **The view left remote mode** (a character, the vanilla GUI, or no HUD). Wait 2 s; the controller guard should
  restore it and log `camera: re-applied remote`. If not, report a FAIL with a screenshot.
- **A key does nothing.** Check that the console is closed (Escape) and that the game window has focus. Click once
  on empty grass first; that also clears the selection.

## Not covered

- Multiplayer.
- Tooltips. Hover over a HUD button for a second if time allows; each has one.
- The exact minimap accuracy. Step 20 checks only that the click lands near the enemy army. The maths is in
  `docs/qa/phase1-hud-notes.md`.
- Shift + right drag, the second attack-move path. The headless autotest covers it.
