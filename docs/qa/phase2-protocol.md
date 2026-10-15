# Phase 2 interactive QA protocol

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam), Space Age enabled. Mod `factorio-rts` 0.1.0.
Covers the Phase 1 controls on live units (the first QA run could not test them, see `phase1-qa-results.md`) and the
Phase 2 player interaction in `docs/PHASE2.md`. The tester is an automated agent with computer use. It clicks in a
1280×800 game window and runs shell commands to read the game log. Implementation details:
`docs/qa/phase2-hud-notes.md`.

## Launch (lead)

Run the session from a frozen copy of the mods dir, so other agents' runs and edits cannot change it. The log is named
after the copy: `build/qa-p2-gui.log`.

```sh
cd /Users/evgeniyivanov/Projects/home/games/factorio_rts
rm -rf build/qa-p2 && mkdir -p build/qa-p2 && cp -R mods/factorio-rts mods/mod-list.json build/qa-p2/
tools/gui-run.sh build/qa-p2 3600 'RTS_QA_END'
```

The script blocks until the log contains `RTS_QA_END`, which step 40 writes, or for at most one hour. Steam must be
running. The GUI self-test is off by default, so no scripted step moves the camera or changes the selection.

## Tester setup

- **Window.** The game area is 1280×800. All coordinates below are game-area coordinates. On screen, the macOS title
  bar adds about 28 px to y.
- **Keyboard.** Use the English (ABC or US) input source if possible. The console opens with **F9**, which works with
  any input source, or with the backtick `` ` `` on an English layout. Enter runs the command and closes the console.
  Keys typed into the open console do not trigger game hotkeys.
- **macOS modifiers.** Every Ctrl chord also has a Cmd alternative. If a Ctrl chord logs nothing, use Cmd instead.
- **Start.** Wait until the arena and the HUD are visible and the log has `RTS_GUI_READY`, about 16 s after start.
  The first enemy wave comes 3 minutes after the start, so do step 1 right away.
- **Zoom.** Do not use the mouse wheel. Every map coordinate below assumes the start zoom 0.5.
- **Reading the log.** Note the line count before each step, then search only the new lines:

  ```sh
  LOG=/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/qa-p2-gui.log
  wc -l < "$LOG"                                  # before the step: note the number N
  tail -n +$((N+1)) "$LOG" | grep -E 'PATTERN'    # after the step
  ```

  Every mod line contains `[rts]`. The patterns below are `grep -E` patterns. Where a step lists several patterns,
  each must match.
- **Evidence.** Take a screenshot after every step. Report each step as PASS or FAIL with the matching log lines, or
  with the last 20 new `[rts]` lines when nothing matched.
- **Chat.** Console replies appear at the bottom-left for a few seconds, over the selection panel. Wait until they fade
  before clicking panel buttons.

### Where things are on the HUD (UI scale 0.75, the automatic scale at 1280×800)

| Element | Location |
|---|---|
| Selection panel | x 6–321, y 689–794. First line: "No units selected", "N units selected" or a building name. |
| Unit buttons | y 741: Attack-move [F] x 56, Stop [X] x 124, Hold [H] x 176, Select all [Ctrl+A] x 249 |
| Group buttons 1–5 | y 763: x 66, 110, 153, 197, 241 |
| Building recipe buttons | y 744, x = 27 + 26 × index (index 0 is the leftmost). Barracks: walker kit (27), heavy kit (53), pause (79). Factory, in this order: barracks, turret, ammo, extractor (105), smelter, solar array, factory, belt, inserter, pole, pause (287). The `hud: recipe buttons` log line gives the order. |
| Build menu | x 1070–1274, y 702–794. Row 1 at y 741: extractor 1093, smelter 1124, solar array 1155, belt 1186, inserter 1217, pole 1248. Row 2 at y 772: factory 1093, barracks 1124, turret 1155, stockpile 1186 (greyed out while you have none). Small numbers in the corners are the counts in your network. |
| Match strip | x 415–865, y 6–78. Row 1: timer, "Army N vs N Enemy". Row 2: iron, copper, steel, stone, magazines, power "used/available MW" and satisfaction %, robots idle/total. Row 3: the message line. |
| Minimap | x 1106–1271, y 9–174, centre (1188.5, 91.5), 0.9375 px per tile. Own CC at (1132, 92), enemy CC at (1245, 92). |

### Where things are on the map

After SPACE the camera is centred on your Command Center (CC) at world (−60, 0), and at zoom 0.5 a tile is 16 px:

```
screen x = 640 + 16 × (world x + 60)        screen y = 400 + 16 × world y
```

| Thing | World | Screen (after SPACE) |
|---|---|---|
| Your CC, 4×4, with 4 small stockpiles left and right of it | (−60, 0) | (640, 400); stockpiles at (584, 376), (584, 424), (696, 376), (696, 424) |
| Your army after the reset: 6 walkers in 2 columns and 3 rows | x −46 and −49.5, y −3.5, 0 and 3.5 | bodies at x 864 and 808, y 316, 372 and 428 (the legs reach lower) |
| Iron ore patch (blue-grey), 12×12 | x −36 to −24, y −6 to 6 | x 1024–1216, y 304–496 |
| Copper ore (orange-red), stone (beige), coal (black) | (−32, −16), (−32, 16), (−24, 16) | (1088, 144), (1088, 656), (1216, 656) |
| Dark square while placing a building | the CC's power area, 36×36 tiles | x 352–928, y 112–688. Buildings inside it get power without poles. |

Robots build only inside 40 tiles of the CC, and the network reaches 25 tiles. Every position used below is inside
both.

## Steps

### Part A: reset and Phase 1 controls on live units

| # | Action | What should visibly happen | Expected log lines (`grep -E`) |
|---|---|---|---|
| 0 | No input. Inspect the screenshot. | Top-down view, no character. The HUD has four areas: the selection panel at the bottom-left, the build menu at the bottom-right, the strip at the top and the minimap at the top-right. No vanilla quickbar, shortcut bar or research panel. The strip's resource row shows iron 200 and copper 100. The CC with its 4 stockpiles is left of the screen centre, and the 6 blue walkers are to its right. | Search the whole log: `RTS_GUI_READY player 1: controller=remote` and `hud: layout player=1 display 1280x800 scale 0.75` |
| 1 | Press Ctrl+Shift+R. | A chat line "qa-reset by player=1 ... enemy waves off". The camera jumps to the CC at the screen centre. The strip timer restarts at 00:00 and the message line reads "Enemy waves off (QA reset). /rts-qa-reset turns them back on." | `qa hotkey /rts-qa-reset nowaves player=1`, then `qa-reset by player=1: .*spawned player=6 enemy=6.*enemy waves off`. If nothing appears, open the console with F9, type `/rts-qa-reset nowaves` and press Enter, then report the hotkey as FAIL. |
| 2 | Hold D for about 1 s, then press SPACE. | The view scrolls right, then jumps back to the CC. The scroll should feel controlled, not a jump off the arena. | `camera pan player=1 .* d=\([0-9.]+, ` and then `camera home player=1 -> \(-60\.0, 0\.0\)`. Report every `d=` x value. Phase 1 logged about 86 tiles per 0.5 s sample; the new pan speed should give about 30 or less. |
| 3 | Box select: a short left drag from (760, 290) to (920, 480). | A light-blue box around each of the 6 walkers. Panel: "6 units selected", "Walker ×6", "Order: Idle". | `select mode=replace drag n=6 ` |
| 4 | Left click on the body of the top-right walker at (864, 316). | Only that walker keeps a box. Panel: "1 unit selected". | `select mode=replace click n=1 ` |
| 5 | Shift + left click on the body of the bottom-left walker at (808, 428). | Two boxes. Panel: "2 units selected". | `select mode=add click n=2 ` |
| 6 | Press Ctrl+1. | Group button 1 reads "1: 2" and shows as pressed. | `group set 1 n=2 player=1` |
| 7 | Press Ctrl+A. | All 6 walkers have boxes. Panel: "6 units selected". The view does not pan left. | `select all n=6 player=1` |
| 8 | Press 1. | The selection drops to the 2 units of group 1. No quickbar appears. | `group recall 1 n=2 player=1` |
| 9 | Left click empty grass at (640, 600). | All boxes disappear. Panel: "No units selected". | `select mode=replace click n=0 ` |
| 10 | Press Ctrl+A, then right click empty ground at (1000, 560). | A green circle flashes at the click. The army walks there and stops in a spread grid. Panel: "Order: Move", then "Order: Idle". | `order move n=6 dest=\(` |
| 11 | Wait until the army stops. Press F. | The Attack-move button turns red. The strip's message line reads "Attack-move armed: right-click where to go. F or X cancels." in red. No text appears at the mouse cursor. | `attack-move armed player=1` |
| 12 | Right click ground at (500, 560). | An amber circle. The army walks left. The button turns grey again and the message line returns to "Enemy waves off ...". | `order attack-move n=6 dest=\(` |
| 13 | Right click ground at (1100, 650). Within 1 s, while the army walks, press X. | The army halts where it is. Panel: "Order: Idle". | `order move n=6 ` and then `order stop n=6 player=1` |
| 14 | Press H. | The units stay put. Panel: "Order: Hold". | `order hold n=6 player=1` |
| 15 | Left click the minimap at (1160, 129). | The camera jumps to empty grass south-east of the base. The selection is kept: the panel still reads "6 units selected". | `hud click minimap player=1 source=mouse .* -> world \(` with a world x between −34 and −27 and a world y between 36 and 44 |
| 16 | Press F9, type `/rts-spawn rts-walker 1 rts-enemy` and press Enter. | One red enemy walker appears below and left of the screen centre, at about (424, 570). | `rts-spawn: 1 x rts-walker for rts-enemy near \(` |
| 17 | Right click on the body of that enemy walker. | A red circle on the enemy. Panel: "Order: Attack". The blue army walks in from the upper left, about 10–20 s, and kills it. | `order attack n=6 target=#[0-9]+ rts-walker.* \(rts-enemy\)`, then within 60 s `order attack done unit=#[0-9]+ \(target gone\)` |
| 18 | Press SPACE. Press Ctrl+A. Right click ground at (448, 624). | The army walks to the lower left of the CC, out of the area where you will build. | `order move n=[56] dest=\(-7[0-9]\.[0-9], 1[0-9]\.[0-9]\)`: the destination is near (−72, 14), and n=5 is fine if a walker died in step 17 |

### Part B: economy

Do every step of part B with the camera at the CC: press SPACE first if you moved it.

| # | Action | What should visibly happen | Expected log lines (`grep -E`) |
|---|---|---|---|
| 19 | Click the build menu's Extractor button at (1093, 741). | The button looks pressed. The message line reads "Placing Extractor: left-click the map. R rotates. Q or right-click: done." in green. A ghost extractor follows the mouse, and a dark square shows the CC's power area. | `hud click build rts-extractor player=1 in_network=2 ghost=true` |
| 20 | Left click on the iron patch at (1064, 408). | A ghost extractor stays there, 1.5 tiles in from the patch's left edge. Within about 20 s a construction robot flies over from the CC and builds it. | `build ghost rts-extractor player=1 at \(-33\.5, 0\.5\)`, then within 40 s `robot built rts-extractor #[0-9]+ at \(-33\.5, 0\.5\) direction=north` with a `drop=` of about (−33.5, −1.4), the tile above it. Note the logged direction if it is not north. |
| 21 | Click the Pole button at (1248, 741). Then left click at (776, 392), (904, 392) and (1016, 392). | Three pole ghosts in a line from the CC towards the extractor. Robots build them, and copper wires connect each pole to the next. | `hud click build medium-electric-pole`, three `build ghost medium-electric-pole player=1 at \(-51\.5, -0\.5\)`, `\(-43\.5, -0\.5\)` and `\(-36\.5, -0\.5\)`, then three `robot built medium-electric-pole` |
| 22 | Click the Smelter button at (1124, 741). Then left click at (1064, 360). | A smelter ghost directly above the extractor, touching it. Robots build it. | `build ghost rts-smelter player=1 at \(-33\.5, -2\.5\)`, then `robot built rts-smelter #[0-9]+` |
| 23 | Click the Belt button at (1186, 741). Then left click at (1112, 456), (1128, 456) and (1144, 456). | Three belt ghosts in a row below and right of the extractor. Robots build them. | Three `build ghost transport-belt player=1 at \(-3[0-9]\.5, 3\.5\)` lines (x −30.5, −29.5 and −28.5), then `robot built transport-belt` |
| 24 | Press Q. | Placing ends. The RTS cursor is back and the message line returns to "Enemy waves off ...". The Belt button no longer looks pressed. | `cursor clear \(Q\) player=1 ghost=transport-belt` and `cursor given player=1 reason=` |
| 25 | Wait until every robot is back at the CC, about 20 s. Left click the extractor at (1064, 408). | Outline around the extractor. Panel: "Extractor #N", "Status: working", "Mining: iron-ore". | `select building extractor unit=[0-9]+ player=1` |
| 26 | Left click the smelter at (1064, 360). | Panel: "Smelter #N", "Status: working", "Smelting: iron-plate". The extractor feeds ore straight into it. | `select building smelter unit=[0-9]+ player=1` |
| 27 | Click the Barracks button at (1124, 772). Left click at (728, 264). Then right click empty grass at (500, 200). | A barracks ghost above and right of the CC. The right click only ends placing: the cursor is the RTS cursor again and no unit moves. Robots build the barracks within about 10 s. | `build ghost rts-barracks player=1 at \(-54\.5, -8\.5\)` and `build mode ended item=rts-barracks player=1 \(right click\)`, no new `order move` line, then `robot built rts-barracks #[0-9]+` |
| 28 | Left click the barracks at (728, 264). | Outline around the barracks, a grey flag about 6 tiles to its right with a dashed line to it. Panel: "Barracks #N", "HP 1500/1500", "Paused: pick a recipe below.", three buttons with the pause button highlighted, "No rally point: new units wait at the exit. ..." | `select building barracks unit=[0-9]+ player=1 at \(-54\.5, -8\.5\)` and `hud: recipe buttons barracks#[0-9]+ player=1: rts-walker-kit rts-walker-heavy-kit pause` |
| 29 | Click the walker kit button at (27, 744). | The button turns yellow. Line 1 reads "Walker kit: running", and the bar next to it fills every 3 s. | `recipe set barracks#[0-9]+ rts-walker-kit ok=true now=rts-walker-kit player=1` |
| 30 | Right click empty ground at (896, 240). | A green circle there. The flag moves there and turns white; the dashed line follows it. Panel: "Rally point (-44.0, -10.0). Right-click the ground to move it." | `rally set barracks #[0-9]+ -> \(-44\.0, -10\.0\) ok=true player=1` |
| 31 | Wait 15 s. | New walkers come out on the right side of the barracks and walk to the flag. The strip's "Army" count rises above 6. Iron drops by 20 at a time (200, 180, 160, ...) and copper by 4. The panel counts "Units from this barracks: N". | `production: barracks #[0-9]+ \(rts-player\) spawned rts-walker #[0-9]+ at .* -> rally`, and a `hud resources player=1 iron=1[0-9][0-9] ` line |
| 32 | Left click the CC at (640, 400). | Panel: "Command Center #N", "Robots idle: construction 20/20, logistic 10/10", "Power: x.xx / 4.00 MW used, machines at 100%". The used power is above 0.2 MW now. | `select building cc unit=[0-9]+ player=1` |
| 33 | Click the Factory button at (1093, 772). Left click at (728, 536). Press Q. | A factory ghost below and right of the CC; robots build it. | `build ghost rts-factory player=1 at \(-54\.5, 8\.5\)`, then `robot built rts-factory #[0-9]+` |
| 34 | Left click the factory at (728, 536). Then click its extractor recipe button at (105, 744). | Panel: "Factory #N" with 11 buttons; after the click, the fourth button is yellow and line 1 reads "Extractor: running". After about 6 s the build menu's Extractor count goes up by one. | `hud: recipe buttons factory#[0-9]+ player=1: rts-barracks rts-turret rts-ammo rts-extractor`, `recipe set factory#[0-9]+ rts-extractor ok=true now=rts-extractor`, then within 20 s `production: factory #[0-9]+ \(rts-player\) moved 1 rts-extractor into the network` |
| 35 | Click the pause button at (287, 744). | The pause button turns yellow, line 1 reads "Paused: pick a recipe below." and the bar disappears. | `recipe set factory#[0-9]+ none ok=true now=none player=1` |
| 36 | Press B. Then press B again. | The build menu disappears, then comes back. | `hud build menu hidden player=1 \(B\)`, then `hud build menu shown player=1 \(B\)` |
| 37 | Click the Pole button at (1248, 741). Press F1. | The ghost leaves the cursor, and the RTS cursor is back. | `cursor F1 player=1 tool_in_hand=true \(ended build mode, ghost medium-electric-pole\)` |
| 38 | Optional: full production loop. Press F9, type `/rts-give rts-stockpile 2` and press Enter. Click the now-enabled Stockpile button at (1186, 772) and left click at (1016, 360). Click the Inserter button at (1217, 741), left click at (1032, 360) and press Q. | A stockpile left of the smelter and an inserter between them. The inserter must take plates from the smelter and drop them into the stockpile. Over a minute the iron count on the strip rises between barracks pulls. | `build ghost rts-stockpile player=1 at \(-36\.5, -2\.5\)`, `build ghost fast-inserter player=1 at \(-35\.5, -2\.5\)`, then `robot built fast-inserter .* pickup=\(-34\.5, -2\.5\) drop=\(-36\.[5-9], -2\.5\)` (an inserter drops about 1.2 tiles out). If pickup and drop are the other way round or vertical, hover the inserter and press R until a `rotated fast-inserter .* pickup=\(-34\.5, -2\.5\) drop=\(-36\.[5-9], -2\.5\)` line appears. |
| 39 | Press F9, type `/rts-eco` and press Enter. | Two chat lines per force: resources, robots, power, and production counters. | `rts-player: iron [0-9]+, copper [0-9]+` and `rts-player production: kits=[1-9]` |
| 40 | Press Ctrl+Shift+E. | The state summary is printed, and the game closes about 3 s later. | `qa hotkey /rts-qa-end player=1` and `RTS_QA_END by player=1`. If nothing appears, use F9 and `/rts-qa-end`, and report the hotkey as FAIL. |

## Recovery

- **Lost the camera.** Press SPACE: the camera returns to the CC, and the map coordinates above apply again.
- **Lost the cursor.** Drags do nothing and no `select mode=` line appears. Press F1.
- **A ghost is stuck in the cursor.** Press Q, F1 or right click. Each one ends placing.
- **A ghost landed in the wrong place.** Leave it, and place a correct one. The tester does not need to remove ghosts.
- **The extractor faces the wrong way.** The `robot built rts-extractor` line shows `direction` and `drop`. Hover the
  extractor and press R until a `rotated rts-extractor .* direction=north` line appears.
- **The army or the units are gone.** Press Ctrl+Shift+R. It respawns 6 walkers per side and keeps every building.
- **The view left remote mode** (a character, the vanilla GUI, or no HUD). Wait 2 s for `camera: re-applied remote`.
  If it does not come, report a FAIL with a screenshot.
- **A key does nothing.** Check that the console is closed (Escape) and that the game window has focus. Then click once
  on empty grass; that also clears the selection.

## Not covered

- Multiplayer.
- Fights against a whole enemy wave. Waves stay off. For a wave, type `/rts-qa-reset` without an argument in the
  console; the first wave then comes after the configured delay.
- The heavy walker kit. It needs steel, and the starting stock has none.
- Turrets: placing one works like any other building, and the factory's ammo recipe feeds it. The headless autotest
  covers the feeding.
- Tooltips. Hover over a build button for a second if time allows. Each tooltip shows the recipe cost and the
  network count.
