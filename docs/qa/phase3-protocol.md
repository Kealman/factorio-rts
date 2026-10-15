# Phase 3 interactive QA protocol: match flow

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam), Space Age enabled. Mod `factorio-rts` 0.1.0.

This protocol covers the Phase 3 match flow: the start dialog, starting a match, the first 5 minutes against a live
AI with fog of war, the menu, restarts and the results screen. The tester is an automated agent with computer use. It
clicks in a 1280×800 game window and reads the game log with shell commands. Implementation details are in
`docs/qa/phase3-matchflow-notes.md`.

## Launch (lead)

```sh
cd /Users/evgeniyivanov/Projects/home/games/factorio_rts
rm -rf build/qa-p3 && mkdir -p build/qa-p3 && cp -R mods/factorio-rts mods/mod-list.json build/qa-p3/
tools/gui-run.sh build/qa-p3 3600 'RTS_QA_END'
```

The log is `build/qa-p3-gui.log`. The script stops when the log contains `RTS_QA_END` (step 16), or after one hour. The
GUI self-test is off, so no scripted step clicks anything.

## Tester setup

- **Coordinates.** All of them are game-area coordinates at UI scale 0.75, the automatic scale at 1280×800. On screen,
  the macOS title bar adds about 28 px to y. Where English and Russian differ, both are given (EN / RU); the game uses
  the system language.
- **Console.** It opens with **F9** on any input source, or with the backtick on an English layout. Enter runs the
  command and closes the console.
- **Keyboard.** Every Ctrl chord also has a Cmd alternative. If a Ctrl chord logs nothing, use Cmd.
- **Zoom.** Do not use the mouse wheel. Map coordinates assume the start zoom 0.5, where 1 tile is 16 px.
- **Reading the log.** Note the line count before a step, then search only the new lines. Every mod line contains
  `[rts]`, and patterns are `grep -E`. Where a step lists several patterns, each must match.

  ```sh
  LOG=/Users/evgeniyivanov/Projects/home/games/factorio_rts/build/qa-p3-gui.log
  wc -l < "$LOG"                                  # before the step: N
  tail -n +$((N+1)) "$LOG" | grep -E 'PATTERN'    # after the step
  ```

- **Reporting.** Take a screenshot after every step. Report PASS or FAIL with the matching lines, or with the last 20
  new `[rts]` lines when nothing matched. Also describe anything odd you see.

### Where things are

| Element | Location |
|---|---|
| Start dialog | Centre of the screen, title "Factorio RTS: new match" / "Factorio RTS: новый матч". Drop-downs: Opponents (601, 341) / (615, 341), Difficulty (601, 368) / (618, 368), Map size (617, 395) / (634, 395). **Start match** (739, 486) / (735, 486). |
| Drop-down list | Clicking a drop-down opens its list just below it. Click the wanted line; take a screenshot first to see the rows. |
| HUD strip | x 415–865, y 6–78. Row 1: timer, "Army N vs Enemies seen: N", then the **Menu** button at about (721, 22). It moves a few pixels with the counts; use the screenshot. Row 3: the message line. |
| Menu dialog | Centre. **Restart** (533, 438), **Resume** (745, 438) / (737, 438) |
| Results dialog | Centre, title "Match over" / "Матч окончен". **Restart** (466, 504), **Continue** (813, 504) / **Осмотреться** (805, 504). With 2 opponents the table has one more row and the buttons sit at y 516 instead of 504; use the screenshot. |
| Minimap | x 1106–1271, y 9–174. Small map: centre (1188.5, 91.5), 0.61 px per tile. Your CC is at (1135, 92). With 1 opponent the AI's CC is at (1242, 92). |

**Map after SPACE.** The camera is centred on your Command Center (CC) at world (−88, 0):

```
screen x = 640 + 16 × (world x + 88)        screen y = 400 + 16 × world y
```

| Thing | Screen |
|---|---|
| Your CC with 4 small stockpiles | (640, 400); stockpiles (584, 376), (584, 424), (696, 376), (696, 424) |
| Your 6 walkers | x 808 and 864, y 344, 400 and 456 |
| Iron ore (blue-grey, 12×12) | x 816–1008, y 464–656 |
| Copper (orange), stone (beige), coal (black) | (912, 240), (1088, 656), (1216, 656) |

## Steps

1. **Start dialog on join.** Wait for the window. Check what is shown:
   - the start dialog in the centre, over a black background;
   - no selection panel at the bottom left and no build menu at the bottom right: both appear when the match starts;
   - the minimap black;
   - the strip message "Choose the match settings and press Start match." / "Выберите настройки и нажмите «Начать
     матч».".

   Patterns: `lobby: dialog shown to player 1 \(1 opponent\(s\), normal, small\)` and
   `camera: god body of player 1 moved to rts-lobby: true`.
2. **Escape in the lobby.** Press Escape once. If the game menu opens, press Escape once more. Expect the start
   dialog to stay, and the view to stay black. Possible pattern: `camera: re-applied remote for player 1`, if Escape
   left the remote view and the controller guard restored it. Report what Escape did.
3. **Drop-downs.** Make these changes in order. Each logs one line.

   | Change | Pattern |
   |---|---|
   | Opponents to 2 | `lobby: player 1 set opponents -> 2 opponent\(s\), normal, small` |
   | Opponents back to 1 | `set opponents -> 1 opponent\(s\)` |
   | Map size to Medium | `set size -> 1 opponent\(s\), normal, medium` |
   | Map size back to Small | `set size -> 1 opponent\(s\), normal, small` |

   Leave Difficulty at Normal. Hover it and screenshot the tooltip, which lists the three difficulties.
4. **Start.** Click **Start match**. Expect:
   - the dialog to close;
   - your CC in the centre, 6 walkers to its right, 4 ore patches;
   - the timer running and "Army 6 vs Enemies seen: ?" ("?" = no enemy unit in sight; Russian "Врагов видно: ?");
   - on the minimap, only a lit area around your base on the left; the rest black.

   Patterns: `lobby click start player=1`, `match: match 1 running on rts-arena-1`,
   `ai rts-ai-1: commander started, difficulty normal`, `fog: match start on rts-arena-1`,
   `hud: built for player 1 .*minimap zoom 0.8088`.
5. **Fog in the world view.** Click the minimap at (1200, 92), just right of the arena centre. The camera jumps to
   about world (20, 0). There, world x 0 is at screen x 320. Expect:
   - left of screen x 320: the area charted at the start; no live entities after about 10 s;
   - right of it: black (uncharted).

   Take a screenshot and describe both parts. Patterns: `hud click minimap player=1` and `camera jump player=1`.
   Press SPACE to come back (pattern `camera home player=1`).
6. **Fog via the minimap.** Click the minimap at (1242, 92), the enemy CC. Expect the camera there and the view black:
   no enemy base. Patterns: `hud click minimap player=1` and `camera jump player=1`. Press SPACE.
7. **First minutes: the army moves out.** Press Ctrl+A, then F, then right-click at (1200, 400), about 35 tiles in
   front of your base. Expect the walkers to march right. The area around them stays lit on the minimap and in the
   view, because units reveal what they see. Pattern: `order attack_move`.
8. **The AI builds and attacks.** Do nothing for about 60 s, watching the strip timer. The AI's base is in the fog, so
   check its progress in the log.

   | Pattern | Expected by |
   |---|---|
   | `ai rts-ai-1: built rts-barracks` | 0:30 |
   | `ai rts-ai-1: step 5 done: recipe rts-barracks -> rts-walker-kit` | 0:30 |
   | `ai rts-ai-1: attack #1: group #1 with [0-9]+ units` | 1:20 |

   Note the strip time of the attack line.
9. **Contact.** Keep the camera on your walkers; press 1 to select all and SPACE for home if needed. When the AI group
   arrives, enemy walkers appear out of the fog near your units. Take a screenshot during the fight. Report:
   - whether the enemy units were visible before they came close;
   - the strip's "Enemies seen" count during the fight. It should count only enemies in sight, and go back to "?"
     when they leave.

   Patterns, any of: `ai rts-ai-1: group #1 retreats`, `order attack done`, `match: rts-player is out`.
10. **Play to 5:00.**
    - Optional: use the build menu as in Phase 2, for example a barracks on walker kits next to the CC.
    - At strip time 3:00 and again at 5:00, screenshot the minimap. It should still be black except where your
      buildings and units are or were.
    - At 5:00, open the console and run `/rts-dump`. Pattern: `tick [0-9]+, match 1 phase=running on rts-arena-1`.
      Report the `rts-ai-1:` line: its units and counters.
    - **If you are defeated before 5:00**, the results dialog opens (title "Defeat"). Screenshot it, click
      **Continue**, and go on with step 11.
11. **Menu via the HUD button.** Click **Menu** on the strip. Expect a dialog with "1 opponent · Normal · Small
    (256×256)" and the match time. Click **Resume**; the dialog closes.
    Patterns: `hud click menu player=1`, `lobby: menu opened by player 1` and `lobby click resume player=1`.
12. **Menu via F10 and Escape.** Press F10; the menu opens. Press Escape; it closes, and the camera does not move.
    Patterns: `lobby: rts-menu \(F10\) player=1` and `lobby: menu closed by player 1 \(Escape\)`.
13. **QA reset restarts the match.** Press Ctrl+Shift+R. Expect a fresh base and army, the timer back at 00:0x, and
    the minimap fog reset to your base area. Patterns: `qa hotkey /rts-qa-reset nowaves player=1`,
    `qa-reset by player=1: match 1 -> 2 on rts-arena-2` and `match: arena rts-arena-1 queued for deletion: true`.
14. **Console start, 1v2 easy.** Run `/rts-match 2 easy small`. Expect "Army 6 vs Enemies seen: ?": 12 enemy units exist, none in sight. Patterns:
    `rts-match: match 3, 2 opponent\(s\), easy, small`, `match: match 3 running on rts-arena-3` and
    `ai rts-ai-2: commander started, difficulty easy`.
15. **Scripted victory, results, restart.**
    1. Run `/rts-kill-force ai`. Expect the results dialog: "Victory", the match time, and a table with rows You,
       AI 1 (Easy) and AI 2 (Easy). The AI rows read "Out at mm:ss". Patterns: `rts-kill-force: rts-ai-1: [0-9]+ units`,
       `match: ended at tick [0-9]+ .*winner=rts-player` and `lobby: results shown to player 1: victory`.
    2. Click **Continue**. The dialog closes, and the minimap now shows the whole arena. Pattern:
       `lobby click continue player=1`.
    3. Click **Menu**, then **Restart**. Expect the start dialog over black. Patterns: `lobby click restart player=1`,
       `lobby: back in the lobby` and `match: arena rts-arena-3 queued for deletion: true`.
16. **End.** Click **Start match** (pattern `match: match 4 running on rts-arena-4`), then press Ctrl+Shift+E.
    Pattern: `RTS_QA_END by player=1`. The game window closes a few seconds later.

## Results to report

- One line per step: PASS or FAIL, plus the evidence.
- The strip time of the AI's first attack.
- Whether enemies were ever visible far from your units, before they came close.
- Anything in the dialogs that is clipped, overlaps, or is in the wrong language.
- Any `Error` lines in the log: `grep -nE 'Error|rror while' "$LOG"`.
