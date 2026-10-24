# Phase 5 M3 GUI QA protocol: Age III, money sinks, air, fronts, fort belts, war trains and huge worlds

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age enabled. Mod `factorio-rts` 0.1.0 after the M3
integration: Age III through the Space Program (three stages, Rush), automation kits, rare extractors and their
nation-wide bonuses, money sinks (Rush, Hire, Mercenaries) and city-state trade, air units (airfield, scout plane, the
Y panel with Patrol and Return, the AA turret), fronts and Hold line, the fort belt tool, artillery trains in Bombard,
worlds of 2048 to 4096 tiles with 2 to 6 nations and background generation, the Nation help page (F11) in a scroll
pane, and the map's "Depot N" labels. Integration notes: `docs/qa/phase5-m3-integration-notes.md`. Contract:
`docs/PHASE5-M3.md` (section 4, "M3 end-to-end").

This protocol plays one Nation match on a 2048×2048 world against one Normal AI, then a short check of the lobby and
the start of a 4096 world. It covers:

- the lobby: Nations 2–6, World size 2048/3072/4096, Start map Explore/Survey, the Victory list and the generation
  line; the Nation help page with the new paragraphs and keys (Y, F, B, H);
- the Space Program: the research panel's Age III gate, the ledger's Start, the stage goods, Rush, a stage completing
  and Age III;
- an automation policy (the ledger's automation row) and a district's jobs shrinking (staffing box, city panel);
- a rare deposit, a rare extractor on it and the bonus line in the ledger;
- war, a front segment next to the capital (game view and map), a division's front row, Hold line and H;
- the fort belt tool (F, right-click points, the bill, Build);
- an airfield, scout planes, the Y panel with Patrol and Return; an AA turret shooting down an enemy bomber;
- an artillery train: Deploy artillery train, the train panel, B for Bombard, shells fired at an enemy building;
- Hire in the city panel; Mercenaries at an own port; a city-state in the market's port drop-down and a Buy there;
  Rush in the research panel;
- the map: front lines and labels, depot labels;
- the F10 menu back to the lobby; 6 nations, 4096, Survey, Start, and the "World: N % generated" line; the end marker.

The tester is an automated agent with computer use. It sees only the screen and uses only the mouse and the keyboard.
It types a few QA shortcuts into the game console; every step that needs one gives the exact text. Every step gives the
input, what must be visible afterwards, and how to judge PASS or FAIL from the screen. The "Log check (lead)" lines are
for the lead, who greps the log after the run; the tester ignores them. **The tester cannot hover**: every check below
reads text that is on the screen or appears after a click; tooltips are not part of any PASS. Every button is named by
its caption.

**Coordinates.** They were measured on 2026-10-17 from screenshots of an English client in a 1280×800 window, UI scale
0.75: `tools/probes/m3_docs_gui.lua` (with `tools/probes/m3_qa_cmds.lua`) on the working tree of the M3 integration
plus the GUI hunks of this audit. The probe plays these steps in this order on a 2048 world and presses the buttons,
the build menu, the map points, the keys and the lobby lists below with real mouse clicks and keys
(`tools/gui-drive.sh`), each one checked a moment later (log lines `m3d real <name>: PASS|FAIL`). Final runs: English
`build/m3i-en` (game-area screenshots `build/shots-m3i-en/`, window captures with the title bar
`build/shots-m3i-en-window/`, log `build/m3i-en-run-final-gui.log`), Russian `build/m3i-ru` (`build/shots-m3i-ru/`,
`build/m3i-ru-final-gui.log`); the earlier passes are kept as `build/shots-m3i-{en,ru}-run1`, `-run2`, `-run3`. The
world is generated anew for every run: the capital's place, the terrain around it and the direction of the AI differ
from run to run, so map positions are given relative to your Command Center (CC). Panels that grow with their content
give their rows in order; when a row is not exactly at its coordinate, find it by its text one or two rows away.

**Factorio 2.1.** The coordinates hold on 2.1.23: the probe's pass on 2.1 is English 53/53
(`build/m3i-p21b-en`), and 2.1 adds no vanilla side button or panel to the screen (`docs/qa/phase5-r2-ux-notes.md`
section 1). One input changed in 0.1.1: with no panel open, Escape opens the Factorio game menu (it used to leave the
remote view for a tick).

Background: `README.md` ("Nation mode"), `docs/PHASE5-M3.md`, `docs/qa/phase5-m2-protocol.md` (the M1 and M2 parts of
the HUD are unchanged except the build menu, which is one row taller: see below) and `docs/qa/phase5-*-notes.md`.

## Launch (lead)

```sh
cd "$(git rev-parse --show-toplevel)"   # the repository root
rm -rf build/qa-p5m3 && mkdir -p build/qa-p5m3 \
  && git archive HEAD mods/factorio-rts | tar -x -C build/qa-p5m3 --strip-components=1 \
  && cp mods/mod-list.json build/qa-p5m3/
ls build/qa-p5m3   # factorio-rts  mod-list.json
pgrep -f '^/Users/.*/MacOS/factorio .*--window-size' || RTS_LOCALE=en tools/gui-run.sh build/qa-p5m3 3600 'RTS_QA_END'
```

- **Frozen tree.** `git archive HEAD` takes the committed tree only: commit the M3 integration (and the shortcuts
  `/rts-front` and `/rts-deposit`, see "QA shortcuts") before the launch. `--strip-components=1` drops the leading
  `mods/`, so the copy is `build/qa-p5m3/factorio-rts` next to `mod-list.json`, the layout `tools/gui-run.sh` expects
  (`<mods-dir>` with the mod folder and the mod list). The run id is the directory's name: the log is
  `build/qa-p5m3-gui.log`, the save `build/qa-p5m3-gui.zip`. The script stops 3 s after the log contains `RTS_QA_END`
  (step 30), or after one hour. Steam must be running.
- **Other clients.** All Factorio windows share the title and the position, so Codex clicks would land in another game.
  The `pgrep` line above starts the client only when no other GUI client runs (it prints the other client's pid
  otherwise: wait and start again). A plain `pgrep -fl 'MacOS/factorio' | grep window-size` also matches the shell
  that runs it.
- **Language.** `RTS_LOCALE=en` makes the client English. The glossary below gives the Russian labels.
- **No self-test.** The GUI self-test is off: no script clicks anything, and the game opens in the lobby.
- **Console.** `tools/gui-run.sh` writes a config that binds F9 to the console. The tester is the admin of a local game.
- **Log checks.** Use `grep -nE 'PATTERN' build/qa-p5m3-gui.log`. Every mod line contains `[rts]`.
- **AI.** The Normal AI keeps running. Its capital lies about 900 tiles away; every nation starts at peace, and after
  the war of step 12 its first army needs minutes to walk over. The AI town of step 13 is a QA town 115 tiles from your
  capital (the shortcut founds it): it has no army of its own at first.

## Tester setup

- **Coordinates** are game-area coordinates of the 1280×800 game window at UI scale 0.75, the automatic scale. On
  screen, the macOS title bar adds about 28 px to y. Every coordinate is approximate (≈). If an element is not exactly
  there, find it in a screenshot by its caption. If the window is larger than 1280×800, multiply x by the window width
  / 1280 and y by the window height / 800; the panels keep to the same window edges.
- **Inputs.** You have the mouse (left click, right click, moving the pointer, wheel), the keyboard and the console for
  the QA shortcuts in the table below. Do not use the console for anything else.
- **The console.** Press F9 (on a Mac keyboard Fn + F9), or the backtick key (`` ` ``) with the English input source.
  An input line opens at the bottom left. Type the text exactly as given, then press Enter. The reply appears as a chat
  line at the bottom left. If the input line is still open after Enter, press Escape once. Keys typed into the console
  do not reach the game.
- **Keyboard.** Use the English (ABC or US) input source. Every Ctrl chord also works with Cmd.
- **Function keys.** macOS may take F4, F9, F10 or F11. If one does something outside the game, or nothing, use the
  alternative the step names (a button, Fn + the key) and report it. Then click the game window once on empty ground.
- **Drags.** A drag often registers as a click. No step needs a drag.
- **Time.** The game runs in real time and does not pause while you work. "Wait 20 s" means: watch the timer at the top
  of the screen advance by 20 s.
- **Camera.** SPACE centres the camera on your CC and keeps the zoom. At the start zoom a tile is 16 px and the CC's
  left and right stockpiles are 112 px apart. A click on the minimap moves the camera there.
- **Empty ground** (to deselect): ≈(1000, 250) after SPACE, 22 tiles right of the CC and 9 up. No step places anything
  there except, when the AI town lies north, the depot of step 20 (from then on use ≈(300, 200)).
- **Escape** closes the market, the diplomacy panel, the research panel, the ledger, the help page and an open console
  line. With nothing open it opens the Factorio game menu (Resume, Restart, Load game, Save game, Settings, Exit); press
  Escape once more, or click **Resume**, to close it. Never click its Restart or Exit.
- **Evidence.** Take a screenshot after every step. Report one of PASS, PARTIAL (the main effect is there, a detail
  differs: say which), FAIL (the main effect is missing) or SKIP (a precondition is missing: say which), with one line
  on what the screenshot shows.
- **Independence.** Each part starts from SPACE and its own shortcuts. If a step fails, do its "If it fails" line (or
  the Recovery section) and go on with the next step; a later step names what it needs from an earlier one.
- **Time budget.** The session closes after one hour of wall time, and the steps take about 45 minutes. If the strip
  timer passes 40:00, or you have been testing for 50 minutes, go to step 28 (the 4096 lobby) and finish.

### QA shortcuts (console)

The economy that earns these takes much longer than a QA session; the shortcuts give the result so the steps can test
what comes after it. Type each line exactly, one per console opening. `/rts-age` takes the force name first.

| Step | Text | Why |
|---|---|---|
| 5 | `/rts-age rts-player 2`, `/rts-research rts-industrialisation`, `/rts-research rts-electrification`, `/rts-treasury add 20000` | Age II, the Space Program's research, crowns for Rush, Hire, Mercenaries and trade |
| 7 | `/rts-give steel-plate 200`, `/rts-give concrete 100`, `/rts-give advanced-circuit 60` | the goods of stage 1 (structure) |
| 9 | `/rts-give rts-district-steel 1` | a Steel works to automate |
| 10 | `/rts-give rts-automation-kit 4` | two kits for the Steel works (and two spare) |
| 11 | `/rts-research rts-geology`, `/rts-deposit saltpetre`, `/rts-give rts-rare-extractor 1` | rare deposits lie far out, most on city-state land; **`/rts-deposit` is new** (see below) |
| 13 | `/rts-front` | an AI town next to your land, so the war has a front; **new** (see below) |
| 14 | `/rts-spawn rts-walker 16` | a division for the front |
| 16 | `/rts-research rts-fortification`, `/rts-give rts-wall 100`, `/rts-give rts-turret 10`, `/rts-give rts-field-depot 1`, `/rts-give firearm-magazine 100` | the fort belt tool and its pieces |
| 17 | `/rts-research rts-aviation`, `/rts-research rts-air-force`, `/rts-give rts-airfield 1`, `/rts-spawn rts-scout-plane 3` | the airfield and three planes (kits take a barracks and minutes) |
| 19 | `/rts-give rts-aa-turret 1`, `/rts-spawn rts-bomber 1 rts-ai-1` | an AA turret and an enemy plane over it |
| 20 | `/rts-research rts-railways`, `/rts-research rts-military-railways`, `/rts-give rts-depot 1`, `/rts-give rts-locomotive-kit 2`, `/rts-give rts-artillery-wagon-kit 1`, `/rts-give rts-rail-shell 40`, `/rts-give coal 100` | an artillery train |
| 23 | `/rts-market ports`, then `/rts-market capture N` (N = the first port number of the reply) | Mercenaries need an own trade port; ports lie 300+ tiles out |
| 30 | `RTS_QA_END` (no slash) | the end marker |

`/rts-front` and `/rts-deposit` are written for `scripts/debug.lua` (`tools/probes/m3_qa_cmds.lua`, checked headless:
`build/m3i-qacmds-server.log`). Replies:

- `/rts-front` → "rts-front: rts-ai-1 town N at (x, y), 115 tiles east of your capital; rts-player: 1 segments [#2 80
  t52]". It founds a town of the first rival 110–130 tiles east, west, south or north of your capital (the first free
  spot; **note the direction word**), refreshes the land and the fronts at once and moves your camera 24 tiles behind
  the new front, so the front line runs through the screen 384 px from the centre towards the town (east: x≈1024).
  Without a war it says "(no war: declare it in F4 to see the fronts)".
- `/rts-deposit saltpetre` → "rts-deposit: saltpetre deposit (6x6, 36 tiles) at (x, y), 18 tiles north-east of your
  capital: place a Rare extractor on it". A pink 6×6 patch on bare ground inside your capital's network, 14–26 tiles
  from the CC in the direction it names.

### Where things are on the HUD

The M1 and M2 rows (`docs/qa/phase5-m2-protocol.md`, "Where things are on the HUD") still hold, except the build menu
(below). New and changed in M3:

| Element | Location (game area) | Contents |
|---|---|---|
| Lobby, Nation mode | dialog x 482–797, y 191–606 | Title "Factorio RTS: new match". **Mode** (≈596, 240), **Nations** (≈596, 267), Difficulty (≈596, 294), **Map size** (≈615, 321), Map "World" greyed (≈596, 348), **Start map** (≈596, 375), **Victory** (≈607, 402), Time limit (≈596, 429); a dim **generation line** (y≈453–498) "World 2048×2048 (4096 chunks): the land around every capital, city-state and port is ready when the match starts; the rest is generated in the background in about 2 min, …"; the hint (y≈519–549); **Start match** (≈732, 586). In the Skirmish dialog Mode is at (≈596, 314) and its list shows Skirmish (≈596, 335), Nation (≈596, 356). |
| Lobby lists | open below their drop-down, 21 px per entry | Nations: 2 (≈620, 288), 3 (309), 4 (330), 5 (351), 6 (372). Map size: World (2048×2048) (≈640, 342), (3072×3072) (363), (4096×4096) (384). Start map: Explore (≈620, 396), Survey (417). Victory: Conquest + Space (≈640, 423), Conquest (444), Territory (465), Score (486), Any (507). |
| Help page "How to play" | x 400–880, y 74–722 | × (≈861, 89). A scroll pane (scroll bar at x≈857): the wheel over the text scrolls it. Nation page: 11 paragraphs, "Nation mode:", "Controls:", "Cities and people:", "Treasury:", "Diplomacy and war:", "Supply:", "Rails and ages:", **"Age III and money:"**, **"Fronts and fortifications:"**, **"Air:"**, **"Keys:"** (the last one ends at y≈700 when scrolled down). |
| World generation line | x 1103–1273, y≈180–207, right under the minimap | "World: 8 % generated", counting up while the far land is generated (2048: about 2 minutes; 4096: about 7); it goes when the world is complete. |
| Age badge | x 251–363, y 6–100 | **Age I / Age II / Age III** (≈303, 22) and under it the national project: "Electrification is done: start the Space Program.", "Space Program stage 1/3: 18 % delivered from the capital's network.", "Space Program stage 2/3: …". |
| Strip, row 3 | y≈62 | "Conquest (every rival capital held or every rival out) or a launched Space Program. Time limit: unlimited" |
| Build menu | x 1043–1273, y 647–797 (three rows now) | "Build [B]" (≈1070, 663); the **gate button** (fort belt tool) at the right of the title (≈1256, 663). Tabs (y≈684): **Economy** (≈1077), **Production** (≈1131), **Defence** (≈1183), the **Age II** icon tab (≈1216). Items at x≈1067, 1098, 1129, 1160, 1191, 1222, 1253; row 1 y≈711, row 2 y≈742, row 3 y≈773. |
| Research panel (T) | x 55–1225, from y 145 | Top: "Researching: Chemistry (0 %)" (≈95, 194) with the bar and **Rush** (≈1155, 194; only while a research runs; then "Stop rush (₡ N/min)"). Third column "Ages II-III: industrial kits": Military railways (y≈287), Supply III, Mining III, Hauler capacity II, Attack IV, Electrification (≈407), **Chemistry (≈431)**, Nuclear power (≈455), Aviation (≈479), **Air Force (≈503)**; status at x≈1090 ("Needs Age III" in Age II), **Research** at x≈1175. |
| City ledger (L) | x 355–925 | Opened before the Space Program starts (2 goods): y 242–557, **Start the Space Program** (≈683, 312), × (≈907, 257). After the Start the panel stays where it opened and grows down: the Space Program line (y≈309–324), the bar (≈663, 316) and **Rush** (≈748, 316), the stage goods (y≈339), the rare line (y≈354–369), **Automation:** (y≈386). Closed and opened again (5 goods) it sits at y 205–594: × (≈907, 220), **Rush** (≈748, 279), stage goods (y≈302), rare line (y≈317–332, one line y≈317 once a bonus is on), **Automation:** row y≈349 with Metallurgy (≈458), Chemistry (≈515), Electronics (≈572), Military (≈624), Services (≈670), Research (≈722); an automated family shows a green check before its name ("✓ Metallurgy", ≈470). |
| City panel (click the CC) | x 788–1013, from y 183 | As in M2; the people block shows "Workforce 120: 16 of 16 jobs filled, 104 free · recruits 107" (y≈484–499); the footer **Hire +4 (₡ 160)** (≈837, 588) and Demolish (≈978, 588). With the "Under attack" row every row is 21 px lower. |
| Staffing box | x 6–320, y≈671–698 | "Staff 100 %: 16.0 of 16 workers · Capital · Metallurgy" and Pin (≈298, 686). |
| Building page | x 6–396, y 699–797 | Airfield: "Airfield #N", "Airfield of Capital", "Planes within 24 tiles: N (M rearming)", "Plane kits of this city's barracks take off here. Y: air panel.". AA turret: "Magazines: N", "Shoots only planes; magazines come from its network.". Rare extractor: "Rare extractor #N", "Status: Working". |
| Division card, front row | division panel; with one city and one division: name button (≈50, 191), bars (y≈204/211), state line (y≈224), Hold / Advance / Screen (≈50 / 116 / 184, 241), Reinforce, pencil, bin (y≈260), **front row** (y≈282) | Only while the division is selected and your nation has a front: "Front 2 · threat 52 · 31 tiles" (the nearest segment, its threat and distance) and **Hold line** (≈194, 282). Holding: the state line reads "Holding the line (front 2)". |
| Fort belt panel | x 497–782, from y 147, centred under the alerts | Title "Fort belt", × (≈762, 162); the hint "Right-click inside your land to set 2 to 6 points. …"; "Points: 2 of 6 · 16 tiles" (y≈230); "Bill: [field depot] 1 [turret] 1 [wall] 17" (y≈248); AA turrets / Field depot checkboxes (y≈266); **Undo point** (≈535, 286), **Build** (≈710, 286), **Cancel** (≈752, 286); then one line per belt under way "Belt 1: 4 of 19 built · waits for [icon]" with **Stop** (≈755, 308). |
| Air panel (Y) | x≈899–1255, from y 211, under the world generation line | Title "Air force", × (≈1243, 226). "Airfields: 1", a row "[icon] Capital   N plane(s) within 24 tiles   Show"; "Planes": Plane, Total, Ready, Returning, Rearming, Supply for Scout plane, Bomber, Interceptor; "Selected: 3 plane(s), supply 100-100"; **Patrol** (≈957, 413) and **Return to airfield** (≈1047, 413); the supply hint. After Patrol the button reads "Right-click the patrol point" (orange) and Return moves to ≈(1100, 413) until the right click. |
| Depot panel, artillery | x 765–1012, from y 183 (the hub panel opens right of it, x 1019–1270) | As in M2, then "Artillery wagon kits: 1 · armoured locomotive kits: 0 · armoured wagon kits: 0 · rail shells: 40" (y≈383–398), **Deploy artillery train** (≈825, 417), Armoured (≈782, 437), the hint, Rail lines. |
| Train panel, artillery | x 1026–1273, y 183–375 | "Artillery train N", "HP 1000/1000, coal 20", the position line, the state, "Stance:" **Hold fire** (≈1096, 274) and **Bombard [B]** (≈1162, 274; yellow when on), the gun line "Shells: 19 · next shot in 10 s · last target: City Center (86 tiles)" (y≈294–309), Resume (≈1058, 328), Disband (≈1110, 328), the hint. |
| Market panel | x 310–970, from y 180 | As in M2 (× ≈951, 195; Tax ≈517, 227); row 3 (y≈265): Commerce bar and **Trade at** drop-down (≈800, 265). With an own port selected: **Mercenaries (₡ 600)** (≈370, 285), then "Mercenaries again in 600 s."; goods rows from y≈351, 22 px apart, Sell (≈770), **Buy** (≈821). The drop-down list opens under it: your port (≈800, 286), then every city-state, "Free City of Mardor (×1.30, +0)" from (≈800, 307), 21 px per entry. With a city-state selected a yellow hint "City-state Free City of Mardor: relation +0, its goods at ×1.30. …" (two lines) replaces the Mercenaries row; goods rows from y≈360; "At port" shows what the city-state sells. |
| F10 menu | dialog x 482–797 | "Menu", the match line (two lines), "Match time: mm:ss", **Restart** (≈533, 445), Concede, Resume. In a Skirmish match the line is one line and Restart is at (≈533, 438). |

**Build menu, Nation mode, M3** (x≈1067, 1098, 1129, 1160, 1191, 1222, 1253; row 1 y≈711, row 2 y≈742, row 3 y≈773):

- **Economy:** Extractor, Smelter, Stockpile, Transport belt, Fast inserter, Medium electric pole, Hub; row 2: **Rail
  depot** (≈1067, 742), Rail works (≈1098, 742).
- **Production:** Barracks, Factory, Lab, City charter, Fort, House, Apartment; row 2: Farm, Bakery, Fishing hut, Field
  depot, **Airfield** (≈1191, 742; greyed until Aviation).
- **Defence:** Turret, Laser turret, Wall, Solar array, Steam plant, Accumulator, Radar; row 2: **AA turret** (≈1067,
  742; greyed until Aviation), **Gate** (≈1098, 742; greyed until Fortification).
- **Age II** (icon tab): Oil well, Refinery, Chemical plant, Smelting works, **Steel works** (≈1191, 711), Circuit
  works, Electronics plant; row 2: Petrochemical works, Engine works, Munitions works, Construction works, Science
  campus, Bunker, **Rare extractor** (≈1253, 742; greyed until Geology); row 3: Chemistry district, Electronics II
  plant, Concrete works, Nuclear plant (Age III).

A greyed icon still places a building while the network holds one (the shortcuts give them).

### Where things are on the map

After SPACE the camera is centred on your CC; a tile is 16 px at the start zoom:

```
screen x = 640 + 16 × (tiles right of the CC)        screen y = 400 + 16 × (tiles below the CC)
```

| Thing | Where (after SPACE, start zoom) |
|---|---|
| Your CC with 4 stockpiles | (640, 400); stockpiles (584, 376), (584, 424), (696, 376), (696, 424) |
| Launch complex (step 6) | 8×8, placed by Start 15–28 tiles from the CC on one side (in the runs (432, 272), (512, 192), (896, 368)), with a label "Space Program 1/3: N %" above it |
| Steel works (step 9) | (448, 496): 12 tiles left of the CC and 6 down (5×5) |
| Saltpetre deposit (step 11) | a pink 6×6 patch 14–26 tiles from the CC, in the direction `/rts-deposit` names (north-east: about (850, 190)) |
| Front line (step 13) | after `/rts-front` the camera is 24 tiles behind the front: a dashed red/blue line through the screen 384 px from the centre towards the AI town (east: x≈1024) with the label "Front N · threat T" at its middle |
| Belt points (step 16) | (320, 272) and (320, 528): 20 tiles left of the CC, 16 tiles apart; (960, 272) and (960, 528) when the AI town is west. Never across the Rare extractor or the tile just above it (its output) |
| Airfield (step 17) | (832, 304): 12 tiles right of the CC and 6 up (6×6); (448, 304) when the Launch complex is in the way |
| AA turret (step 19) | (512, 528): 8 tiles left of the CC and 8 down; the bomber of `/rts-spawn` appears about (424, 592) |
| Rail depot (step 20) | towards the AI town: east (992, 400) and west (288, 400), 22 tiles out; south (640, 640), 15 tiles down; north (992, 250), 22 right and 9 up (straight north is under the strip). Its 40-tile platform appears beside it (usually 8 tiles below) |
| Planes (step 17) | `/rts-spawn` puts units in a row 12 tiles below the camera, from 13.5 tiles left of it |

Every site is a suggestion: any bare ground nearby works (no water, no grey rock, no building, no unit). The Launch
complex can take a suggested site: then use the mirror site on the other side of the CC.

### Glossary (English → Russian)

| English | Russian |
|---|---|
| Factorio RTS: new match; Mode; Nation; Nations; Map size; World (2048×2048); Start map; Explore; Survey | Factorio RTS: новый матч; Режим; Держава; Держав; Размер карты; Мир (2048×2048); Карта на старте; Разведка; Съёмка |
| Victory; Conquest + Space; Conquest; Territory; Score; Any; Time limit; unlimited; Start match | Победа; Завоевание + космос; Завоевание; Территория; Счёт; Любая; Лимит времени; без лимита; Начать матч |
| World 2048×2048 (4096 chunks): the land around every capital, city-state and port is ready … | Мир 2048×2048 (чанков: 4096): земля вокруг каждой столицы, города-государства и порта готова к началу матча … |
| World: 8 % generated | Мир: создано 8 % |
| How to play; Age III and money; Fronts and fortifications; Air; Keys | Как играть; III эпоха и деньги; Фронты и укрепления; Авиация; Клавиши |
| Age II; Age III; A new age for your nation: Age III: Modern | Эпоха II; Эпоха III; Новая эпоха для вашей державы: III эпоха: современность |
| Research; Needs Age III; Researching: Chemistry (0 %); Rush; Stop rush (₡ 174/min) | Изучить; Нужна III эпоха; Исследуется: Химия (0 %); Ускорить; Не ускорять (₡ 174/мин) |
| City ledger; Start the Space Program; Space Program stage 1/3: 42 % delivered from the capital's network.; Stage 1/3 | Городской реестр; Начать Космическую программу; Космическая программа, этап 1/3: доставлено 42 % из сети столицы.; Этап 1/3 |
| Space Program 1/3: 54 % (label on the map); Space Program stage 1 of 3 complete | Космическая программа 1/3: 54 %; Этап 1 из 3 Космической программы завершён |
| Automation:; Metallurgy; Chemistry; Electronics; Military; Services; Research | Автоматизация:; Металлургия; Химия; Электроника; Армия; Услуги; Наука |
| Staff 100 %: 16.0 of 16 workers · Capital · Metallurgy; Workforce 120: 16 of 16 jobs filled | Персонал 100 %: 16.0 из 16 · Столица · Металлургия; Рабочие 120: занято 16 из 16 мест |
| Rare resources: none reaches the capital. …; Rare: +25 % explosives and munitions (87 s); Saltpetre reaches the capital: +25 % explosives and munitions | Редкие ресурсы: до столицы ничего не доходит. …; Редкие ресурсы: +25 % взрывчатки и боеприпасов (87 с); Селитра доходит до столицы: +25 % взрывчатки и боеприпасов |
| Steel works; Rare extractor; Airfield; AA turret; Gate; Rail depot; Launch complex; City Center | Сталелитейный комбинат; Экстрактор редких ресурсов; Аэродром; Зенитная турель; Ворота; Ж/д депо; Стартовый комплекс; Городской центр |
| Diplomacy; War; War on AI 1. Our goal: capture Capital | Дипломатия; Война; Война с ИИ 1, цель: захват города Столица |
| Front 2 · threat 52 · 85 tiles; Hold line; Holding the line (front 2); Front 2 · threat 52 · held by Division 1 | Фронт 2 · угроза 52 · 85 кл.; Держать линию; Держит линию (фронт 2); Фронт 2 · угроза 52 · держит Дивизия 1 |
| Fort belt; Points: 2 of 6 · 16 tiles; Bill:; AA turrets; Field depot; Undo point; Build; Cancel; Belt 1: 4 of 19 built; Stop | Оборонительная линия; Точек: 2 из 6 · 16 клеток; Смета:; Зенитки; Полевое депо; Убрать точку; Построить; Отмена; Линия 1: построено 4 из 19; Стоп |
| Fort belt 1 is built (19 pieces) | Оборонительная линия 1 построена (19 шт.) |
| Air force; Airfields: 1; Show; Planes; Scout plane; Patrol; Right-click the patrol point; Return to airfield; Selected: 3 plane(s), supply 100-100 | Авиация; Аэродромы: 1; Показать; Самолёты; Самолёт-разведчик; Патруль; Правый щелчок по точке патруля; На аэродром; Выбрано самолётов: 3, запас 100-100 |
| Airfield of Capital; Planes within 24 tiles: 3 (0 rearming); Magazines: 20 | Аэродром: Столица; Самолётов в 24 клетках: 3 (на заправке: 0); Магазинов: 20 |
| Freight and troop trains: no train kits in the depot network | Грузовой и войсковой поезда: в сети депо нет комплектов поезда |
| Deploy artillery train; Armoured; Artillery train 6; Stance:; Hold fire; Bombard [B]; Shells: 19 · next shot in 10 s · last target: City Center (86 tiles); Shells: 20 · looking for a target, next shot in 0 s | Выпустить артиллерийский поезд; Бронированный; Артиллерийский поезд 6; Стойка:; Не стрелять; Обстрел [B]; Снарядов: 19 · выстрел через 10 с · цель: Городской центр (86 кл.); Снарядов: 20 · ищет цель, выстрел через 0 с |
| Hire +4 (₡ 160); Mercenaries (₡ 600); Mercenaries again in 600 s.; 7 mercenaries hired (Port of X) | Нанять +4 (₡ 160); Наёмники (₡ 600); Наёмники снова через 600 с.; Нанято наёмников: 7 (Порт X) |
| Trade at:; Free City of Mardor (×1.30, +0); City-state Free City of Mardor: relation +0, its goods at ×1.30.; Buy; At port | Порт:; Вольный город Мардор (×1.30, +0); Город-государство Вольный город Мардор: отношения +0, его товары по ×1.30.; Купить; В порту |
| Depot 1 (map label) | Депо 1 |
| Menu; Restart; Concede; Resume | Меню; Заново; Сдаться; Продолжить |
| rts-front: …; rts-deposit: …; rts-spawn: …; rts-give: … | the same (console replies are not translated) |

In a Russian client the wider captions move a few buttons (measured in `build/shots-m3i-ru/`): the build menu tabs
Экономика ≈1083, Производство ≈1153, Оборона ≈1214 and the Age II icon tab ≈1249 (y≈684); the city panel's footer
«Нанять +4 (₡ 160)» ≈(847, 618) (two more wrapped lines above it); the air panel's × ≈(1256, 226). Everything else
is within a few pixels of the English coordinates.

## If an AI attack interrupts

From step 12 on you are at war with AI 1. Its capital is about 900 tiles away and its first army needs several minutes;
the QA town of step 13 has no army. Signs of an attack: a red "<Region>: Base under attack: …" line, a red mark on the
minimap, "Enemies seen" above 0. Your division (step 14) and the turrets fire by themselves. If an attack reaches the
capital: finish the current click, press Q if a ghost is on the cursor, press F3 (the camera jumps there), press Ctrl+A,
press F and right-click the enemies. When "Enemies seen" shows 0 again press SPACE and redo the interrupted step. Note
the strip time and what was hit. The bomber of step 19 attacks your buildings by design: that is not an AI attack.

## Steps

### Part A: lobby and start

1. **The start dialog, Mode Nation.**
   - *Input:* wait until the window shows a dialog in the middle of a black screen. Click **Mode** (≈596, 314); a list
     opens below it. Click "Nation" (≈596, 356). Take a screenshot.
   - *Expect:* the dialog grows (x 482–797, y 191–606): Mode "Nation" (≈596, 240), **Nations "2"** (≈596, 267),
     Difficulty "Normal", **Map size "World (2048×2048)"** (≈615, 321), Map "World" greyed, **Start map "Explore"**
     (≈596, 375), **Victory "Conquest + Space"** (≈607, 402), Time limit "unlimited"; under the grid a dim
     **generation line** "World 2048×2048 (4096 chunks): the land around every capital, city-state and port is ready
     when the match starts; the rest is generated in the background in about 2 min, and every deposit, ruin and label
     appears with its ground."; the hint "Every nation starts at peace …"; **Start match** (≈732, 586).
   - *Pass/Fail:* PASS if Nations, Start map, Victory "Conquest + Space" and the generation line are there.
   - *Log check (lead):* `lobby: player 1 set mode -> 1 opponent\(s\), normal, nation, world default`,
     `lobby: dialog shown to player 1 \(1 opponent\(s\), normal, nation, world default, victory conquest_space, time limit 0\)`

2. **The lists.**
   - *Input:* click **Nations** (≈596, 267), take a screenshot of the open list, click "2" (≈620, 288). Click **Map
     size** (≈615, 321), screenshot, click "World (2048×2048)" (≈640, 342). Click **Start map** (≈596, 375), screenshot,
     click "Explore" (≈620, 396). Click **Victory** (≈607, 402), screenshot, click "Conquest + Space" (≈640, 423).
   - *Expect:* Nations lists 2, 3, 4, 5, 6; Map size lists World (2048×2048), World (3072×3072), World (4096×4096);
     Start map lists Explore, Survey; Victory lists Conquest + Space, Conquest, Territory, Score, Any. Every row keeps
     its value; the generation line still names 2048.
   - *Pass/Fail:* PASS if the four lists show these entries.
   - *Log check (lead):* none (picking the value that is already set fires no change); the start line of step 4 names
     the settings.

3. **The Nation help page in the lobby.**
   - *Input:* press F11 (or click **?** on the strip, ≈786, 22). Take a screenshot. Move the pointer over the text
     (≈640, 400) and turn the wheel towards you about 15 notches, until the text stops moving. Take a screenshot.
     Click the × (≈861, 89).
   - *Expect:* "How to play" (x 400–880, y 74–722) with a scroll bar at its right edge. First screen: "Nation mode:
     win by Conquest …, by Space (launch the Space Program: Conquest + Space, the default, or Any), by Territory …
     Worlds of 2048 to 4096 tiles hold 2 to 6 nations; …", "Controls:", "Cities and people:", "Treasury:", …. Scrolled
     to the end: **"Age III and money:"** (Electrification, the Space Program, automation kits, the rare extractor,
     Rush, Hire, Mercenaries, city-state trade), **"Fronts and fortifications:"** (fronts, H, F, the fort belt tool,
     Military railways, B), **"Air:"** (Aviation, the airfield, the AA turret, Air Force, supply, Y), **"Keys:"** naming
     M, F4, N, L, T, B, **Y air panel**, Delete, F3, F10, F11 and "In context: **F** with no unit selected opens the fort
     belt tool, **B** with a train selected sets Bombard, **H** with divisions selected at a front holds the line." No
     line is cut at the right edge.
   - *Pass/Fail:* PASS if the page scrolls to the Keys paragraph with Y, F, B and H. FAIL if the page has no scroll bar
     and its bottom is cut off by the window.
   - *Log check (lead):* `hud help opened player=1 \((F11|\? button)\): 11 lines \(nation\)`

4. **Start.**
   - *Input:* click **Start match** (≈732, 586). Wait up to 10 s.
   - *Expect:* the camera on your capital: the CC at (640, 400) with 4 stockpiles, the Commander and 6 walkers. Strip:
     timer from 00:00, row 3 "Conquest (every rival capital held or every rival out) or a launched Space Program. Time
     limit: unlimited"; the age badge "Age I"; under the minimap a line **"World: N % generated"** (≈1188, 194) that
     counts up for about two minutes and then goes; the build menu with three rows of space (rows 2 and 3 mostly empty
     on the Economy tab).
   - *Pass/Fail:* PASS if the goal line names the Space Program and the generation line counts up.
   - *Log check (lead):* `match: starting match [0-9]+: 1 opponent\(s\), normal, nation, world 2048x2048, brain ai`,
     `world: background generation done: 4096 chunks` (about 2 minutes later)

### Part B: the Space Program and Age III

5. **QA shortcuts: Age II; the research panel's Age III gate.**
   - *Input:* open the console once per line and type, each followed by Enter: `/rts-age rts-player 2`,
     `/rts-research rts-industrialisation`, `/rts-research rts-electrification`, `/rts-treasury add 20000`. Press T.
     Take a screenshot. Press T again (or Escape).
   - *Expect:* the replies "rts-player: age 2, …", "rts-research: rts-industrialisation researched for rts-player",
     "rts-research: rts-electrification researched for rts-player" and a treasury line "rts-player: balance 21,5xx …";
     alerts "A new age for your nation: Age II: Industry", "Research complete: Electrification"; the badge "Age II" with
     "Electrification is done: start the Space Program.". The research panel (x 55–1225): in the third column "Ages
     II-III: industrial kits" Electrification "Done", Aviation "Available", and **Chemistry, Nuclear power and Air Force
     "Needs Age III"** (status column x≈1090, rows y≈431, 455, 503).
   - *Pass/Fail:* PASS if the three Age III techs read "Needs Age III" (not "Needs Age II", not a raw key).
   - *Log check (lead):* `ages: rts-player age 1 -> 2 \(console\)`, `rts-research: rts-electrification researched`,
     `treasury: rts-player: balance`, `techgui: opened by player 1`

6. **Start the Space Program in the ledger.**
   - *Input:* press L. Take a screenshot. Click **Start the Space Program** (≈683, 312). Wait 3 s. Take a screenshot.
     Leave the ledger open.
   - *Expect:* before the click the City ledger (x 355–925, y 242–557): "City: Capital", "Age II: Industry",
     "Electrification is done: start the Space Program.", the button, "Stage 1/3: [advanced circuit] 60 [concrete] 100
     [steel] 200", "Rare resources: none reaches the capital. …", **"Automation:"** with six greyed buttons (Metallurgy,
     Chemistry, Electronics, Military, Services, Research: Age III only). After the click: the button becomes **Rush**
     (≈748, 316) with a bar left of it, the line reads "Space Program stage 1/3: 0 % delivered from the capital's
     network.", the goods "Stage 1/3: [icon] 0/60 [icon] 0/100 [icon] 0/200"; a green alert "<Region>: Space Program
     started next to the capital (stage 1)"; the 8×8 **Launch complex** (a round silo platform) appears 15–28 tiles
     from the CC with a blue bar and the label **"Space Program 1/3: 0 %"** above it (often behind the ledger).
   - *Pass/Fail:* PASS if the complex and its label appear. FAIL if the chat says "Space Program cannot start now: …"
     (report the reason).
   - *Log check (lead):* `age3: player 1 start Space Program: building`,
     `age3: rts-player started the Space Program \(stage 1\) at .* \(in a logistic network`

7. **The stage goods and Rush.**
   - *Input:* open the console once per line: `/rts-give steel-plate 200`, `/rts-give concrete 100`,
     `/rts-give advanced-circuit 60`. Wait 5 s, take a screenshot of the ledger. Click **Rush** (≈748, 316; if you
     closed and reopened the ledger: ≈748, 279). Take a screenshot.
   - *Expect:* three replies "rts-give: 200 x steel-plate into the rts-player pool" etc.; the ledger's goods count up
     (10 of each per second: "30/60 … 30/150 … 30/200") and the bar fills; the goods table lists Steel plate, Advanced
     circuit and Concrete with "Used/min". After Rush the button reads **"Stop rush (₡ N/min)"** and the counts climb
     twice as fast.
   - *Pass/Fail:* PASS if the deliveries count up and Rush turns into "Stop rush".
   - *Log check (lead):* `rts-give: 200 x steel-plate into the rts-player pool`,
     `sinks: rts-player rushes project space-program \(x2\)`

8. **Stage 1 completes: Age III.**
   - *Input:* press L to close the ledger. Watch the Launch complex (or its label) and the badge for up to 40 s. Take a
     screenshot when the badge changes.
   - *Expect:* the label counts up to "Space Program 1/3: 100 %", then a countdown "Space Program stage 1/3 done in N s"
     (the badge sub-line too); within about 25 s alerts "<Region>: Space Program stage 1 of 3 complete" and "A new age
     for your nation: Age III: Modern"; the badge reads **"Age III"** and "Space Program stage 2/3: 0 % delivered from
     the capital's network."; the label "Space Program 2/3: 0 %".
   - *Pass/Fail:* PASS if the badge reads Age III.
   - *Log check (lead):* `age3: rts-player Space Program stage 1: everything delivered at`,
     `age3: rts-player Space Program stage 1 \(structure\) complete at`, `ages: rts-player age 2 -> 3 \(space-program\)`,
     `sinks: rts-player rush of space-program ended \(done\)`

### Part C: automation and a rare extractor

9. **A Steel works and its jobs.**
   - *Input:* press SPACE. Open the console: `/rts-give rts-district-steel 1`. Click the **Age II** icon tab (≈1216,
     684), then **Steel works** (≈1191, 711; row 1, fifth), left-click the map at (448, 496), press Q. Wait 20 s (the
     CC's robots build it). Click the Steel works. Take a screenshot. Click the CC (640, 400). Take a screenshot.
   - *Expect:* a 5×5 Steel works (a red smelter block) at about (456, 504). Its building page "Steel works #N" with
     the recipe buttons and, above it, the staffing box **"Staff 100 %: 16.0 of 16 workers · Capital · Metallurgy"**.
     The city panel's people block "Workforce 120: **16 of 16** jobs filled, … free · recruits …".
   - *Pass/Fail:* PASS if the staffing box shows 16 workers.
   - *Log check (lead):* `rts-give: 1 x rts-district-steel`, `build ghost rts-district-steel player=1 at`

10. **The automation policy.**
    - *Input:* click empty ground ≈(1000, 250). Open the console: `/rts-give rts-automation-kit 4`. Press L. Take a
      screenshot. Click **Metallurgy** in the "Automation:" row (≈458, 349). Wait 6 s. Take a screenshot. Press L.
      Click the Steel works (≈456, 504), take a screenshot; click the CC (640, 400), take a screenshot.
    - *Expect:* the ledger in Age III (y 205–594): "Age III: Modern", **Rush** (≈748, 279) for stage 2, "Stage 2/3:
      [battery] 0/100 [engine] 0/80 [processing unit] 0/40", the Automation buttons no longer greyed. After the click
      the button reads **"✓ Metallurgy"** (a green check before the name). The Steel works' staffing box: **"Staff 100
      %: 7.8 of 7.8 workers · Capital · Metallurgy"** (two kits cut the jobs by 30 % each: 16 × 0.49). The city panel:
      "Workforce 120: **8 of 8** jobs filled, …" (it was 16).
    - *Pass/Fail:* PASS if the check mark shows and the Steel works' workers drop from 16 to about 7.8.
    - *Log check (lead):* `age3: rts-player city [0-9]+ automate metallurgy on`,
      `age3: rts-district-steel #[0-9]+ \(rts-player, city [0-9]+\): automation kits 0 -> 2 \(want 2\)`

11. **A rare deposit, a rare extractor and its bonus.**
    - *Input:* click empty ground ≈(1000, 250). Open the console once per line: `/rts-research rts-geology`,
      `/rts-deposit saltpetre`, `/rts-give rts-rare-extractor 1`. Note the direction in the reply. Find the pink 6×6
      patch in that direction, 14–26 tiles from the CC (north-east: about (850, 190)). Click the **Age II** icon tab
      (≈1216, 684), then **Rare extractor** (≈1253, 742; row 2, last), left-click the middle of the pink patch, press Q.
      Wait 25 s. Click the extractor, take a screenshot. Click empty ground, press L, take a screenshot, press L.
    - *Expect:* the reply "rts-deposit: saltpetre deposit (6x6, 36 tiles) at (x, y), 18 tiles north-east of your
      capital: place a Rare extractor on it"; the extractor (3×3) is built on the patch; within about 15 s a green
      alert **"Saltpetre reaches the capital: +25 % explosives and munitions"**. Its building page "Rare extractor #N",
      "Status: Working" and the staffing box "Staff 100 %: 4.0 of 4 workers · Capital · Extraction". The ledger's rare
      line: **"Rare: [saltpetre] +25 % explosives and munitions (87 s)"** (the seconds count down and refill while
      items arrive).
    - *Pass/Fail:* PASS if the alert and the ledger's bonus line show. PARTIAL if only the extractor stands (report the
      ledger line).
    - *If it fails:* `/rts-deposit` unknown (not merged): type `/rts-rare give saltpetre 3`; the ledger line shows the
      bonus without an extractor (PARTIAL).
    - *Log check (lead):* `rts-deposit: saltpetre deposit`, `rare: extractor #[0-9]+ \(rts-player, saltpetre\) at .*: items go into its network`,
      `rare: rts-player saltpetre bonus ON at tick`

### Part D: war, a front, Hold line

12. **Declare war.**
    - *Input:* press SPACE. Press F4. Take a screenshot. Click **War** in the AI 1 row (≈736, 365). Take a screenshot.
      Press F4.
    - *Expect:* as in M2: "Diplomacy" (x 263–1017), the AI 1 row State "Peace" → **"War"** in red, opinion about −30;
      "Our wars: AI 1 (we declared), …"; a red alert "<Region>: War on AI 1. Our goal: capture Capital". City-state
      rows "Free City of X" are not cut.
    - *Pass/Fail:* PASS if the state reads War.
    - *Log check (lead):* `diplomacygui: player 1 war -> rts-ai-1: proposal #[0-9]+`, `war: #[0-9]+ declared rts-player -> rts-ai-1`

13. **A front next to the capital.**
    - *Input:* open the console: `/rts-front`. Take a screenshot. Note the direction word in the reply.
    - *Expect:* the reply "rts-front: rts-ai-1 town N at (x, y), 115 tiles east of your capital; rts-player: 1 segments
      [#2 80 t52]" and a yellow alert "<Region>: Territory lost near Capital (N cells)"; the camera moves; about 384 px
      from the centre towards the town (east: x≈1024, top to bottom) run the borders of the two lands (thick dashes,
      blue for yours, red for the town's) and the front, with the small red label **"Front 2 · threat 52"** at its
      middle (≈1024, 400 for an east town); the minimap shows a red land patch next to yours. There is one label: no
      large copy of it at the screen edge (the map shows the front as a coloured line without a label).
    - *Pass/Fail:* PASS if the dashed front line and its label show. FAIL if the reply says "no room for a town …" or
      "0 segments".
    - *If it fails:* `/rts-front` unknown (not merged): SKIP steps 13–15 and 20's target (the artillery train then has
      no target: report its gun line).
    - *Log check (lead):* `rts-front: rts-ai-1 town [0-9]+ at`, `cities: new city [0-9]+ of rts-ai-1 at .* \(QA /rts-front\)`,
      `front: refresh [0-9]+: 1 wars, [0-9]+ segments`

14. **A division at the front: the card's front row and Hold line.**
    - *Input:* open the console: `/rts-spawn rts-walker 16` (they appear at the camera). Press Ctrl+A. Click the walker
      card (≈47, 736; the second card, after the Commander). Click **Form division** (≈187, 166). Take a screenshot.
      Click **Hold line** (≈194, 282). Wait 15 s. Take a screenshot.
    - *Expect:* "Divisions (1)", the card "Division 1 22/22" (the 16 new walkers and the 6 of the start) with its stance
      buttons and, at its bottom, the **front row "Front 2 · threat 52 · N tiles"** and **Hold line**. After the click the walkers walk to the dashed line and
      spread along it, one every few tiles; the card's state line reads **"Holding the line (front 2)"** and the label
      at the line reads "Front 2 · threat 52 · held by Division 1".
    - *Pass/Fail:* PASS if the division spreads along the line and the card says Holding the line.
    - *Log check (lead):* `rts-spawn: 16 x rts-walker for rts-player near`, `divisiongui: player 1 formed division #[0-9]+`,
      `divisiongui: player 1 hold line division #[0-9]+ ok=true`,
      `front: division #[0-9]+ .* holds segment [0-9]+ of rts-player: [0-9]+ slots along`

15. **H at the front.**
    - *Input:* the division is still selected (if not, click its name button ≈50, 191). Press X (Stop). Move the mouse
      pointer onto the front's label or just below it (do not click; H takes the front within 64 tiles of the pointer,
      so any point between the screen centre and the line works). Press H. Wait 10 s. Take a screenshot.
      (A computer-use agent without a pointer-move action: a scroll of 0.001 page at the point moves the pointer there
      without zooming.)
    - *Expect:* after X the card's state reads "Idle"; after H it reads **"Holding the line (front 2)"** again and the
      walkers keep (or take back) their places along the line. H with the pointer far from any front only sets the
      Hold stance (no change of place).
    - *Pass/Fail:* PASS if H brings back "Holding the line". PARTIAL if only the stance button "Hold" lights up (the
      pointer was not on the line: report where it was).
    - *Log check (lead):* `order hold_line segment=[0-9]+ divisions=1 player=1`

### Part E: the fort belt tool

16. **F, two points, the bill, Build.**
    - *Input:* press SPACE. Open the console once per line: `/rts-research rts-fortification`, `/rts-give rts-wall 100`,
      `/rts-give rts-turret 10`, `/rts-give rts-field-depot 1`, `/rts-give firearm-magazine 100`. Click empty ground
      ≈(1000, 250) (nothing selected). Press F. Take a screenshot. Right-click (320, 272), then right-click (320, 528)
      (20 tiles left of the CC, 8 up and 8 down). If the AI town of step 13 lies **west**, or a building or the pink
      deposit is there, use (960, 272) and (960, 528) instead (the depot of step 20 goes where the belt would be).
      Take a screenshot. Click **Build** (≈710, 286). Watch for up to 90 s; take a screenshot when the plan line
      changes. Click the × of the panel (≈762, 162).
    - *Expect:* F opens the **"Fort belt"** panel centred under the alerts (x 497–782, y 147–305): the hint, "Points: 0
      of 6 · 0 tiles", "Bill: -", the checkboxes "AA turrets" and "Field depot", **Undo point**, **Build**, **Cancel**.
      After the right clicks: two yellow dots joined by a dashed yellow line on the map with circles for the planned
      turret and depot (a green circle 3 tiles behind for the turret, an orange one 12 tiles behind for the depot); "Points:
      2 of 6 · 16 tiles", "Bill: [field depot] 1 [turret] 1 [wall] 17" ("AA turrets" stays greyed: no Aviation yet).
      After Build: a flying text "Fort belt 1: 19 pieces planned", ghosts along the line, a line "Belt 1: N of 19 built" with
      **Stop**; the CC's robots and the belt crew build a wall with a turret behind it and a field depot; finally a green
      alert "<Region>: Fort belt 1 is built (19 pieces)". The same panel opens with the gate button at
      the right of the build menu's title (≈1256, 663).
    - *Pass/Fail:* PASS if the bill shows and the wall is built. PARTIAL if the plan line stops at "waits for [icon]"
      (report the icon).
    - *Log check (lead):* `belt: tool opened player=1`, `belt: tool point 2 at`,
      `belt: plan 1 of rts-player: 2 points, [0-9]+ tiles, [0-9]+ entries`, `belt: click build player=1 plan=1`,
      `belt: plan 1 of rts-player built in`

### Part F: air

17. **An airfield, three scout planes, the Y panel.**
    - *Input:* press SPACE. Open the console once per line: `/rts-research rts-aviation`, `/rts-research rts-air-force`,
      `/rts-give rts-airfield 1`. Click **Production** (≈1131, 684), then **Airfield** (≈1191, 742; row 2, fifth),
      left-click (832, 304) (if the ghost turns red there, the Launch complex is in the way: click (448, 304) instead),
      press Q. Wait 20 s. Click the airfield. Take a screenshot (zoom in a little with the wheel
      for a second screenshot of the airfield itself, then press SPACE and zoom back). Open the console:
      `/rts-spawn rts-scout-plane 3`. Press Ctrl+A, click the third card (≈72, 736; after the Commander and the walker).
      Press Y. Take a screenshot.
    - *Expect:* a 6×6 airfield: a grey concrete apron with a yellow-black hazard rim, a dashed hazard centre line and a
      small robot hangar in one corner. Its building page "Airfield #N", **"Airfield of Capital"**, "Planes within 24
      tiles: 0 (0 rearming)", "Plane kits of this city's barracks take off here. Y: air panel.". Three planes appear in
      a row about 12 tiles below the CC. Y opens the **"Air force"** panel at the right edge under the world line (x
      ≈899–1255, from y 211): "Airfields: 1", "Capital   0 plane(s) within 24 tiles   Show", the table with "Scout plane
      3 3 0 0 100" (Total, Ready: neither returning nor rearming, Returning, Rearming, Supply), Bomber and Interceptor rows
      with 0, "Selected: 3 plane(s), supply 100-100", **Patrol** and **Return to
      airfield**, the supply hint. The panel does not cover the minimap or the world line.
    - *Pass/Fail:* PASS if the airfield page and the Y panel show with the three planes.
    - *Log check (lead):* `air: airfield #[0-9]+ of rts-player at`, `rts-spawn: 3 x rts-scout-plane for rts-player near`,
      `hud: hotkey rts-airfield-panel \(Y\) player=1`, `air: panel opened player=1`

18. **Patrol and Return.**
    - *Input:* click **Patrol** (≈957, 413). Take a screenshot. Right-click the map at ≈(400, 250). Wait 5 s, take a
      screenshot. Click **Return to airfield** (≈1047, 413). Wait 15 s, take a screenshot. Close the panel with its ×
      (≈1243, 226) or Y.
    - *Expect:* after Patrol the button reads **"Right-click the patrol point"** (orange) and a flying text says the
      same; the wider button pushes Return to airfield to ≈(1100, 413) until the right click. After the right click the planes fly a circle around that point; the selection panel reads "Order: Patrol";
      "Ready 3". After Return they fly to the airfield and stand on or next to it; the panel's airfield row reads "3
      plane(s) within 24 tiles" and the supply column climbs to 100.
    - *Pass/Fail:* PASS if the planes patrol and come back.
    - *Log check (lead):* `air: patrol armed player=1`, `order patrol n=3 dest=`, `air: 3 plane\(s\) of rts-player patrol`,
      `order return-to-airfield n=3 player=1`, `air: rts-scout-plane #[0-9]+ \(rts-player\) rearmed at`

19. **An AA turret shoots down an enemy bomber.**
    - *Input:* press SPACE. Click empty ground ≈(1000, 250). Open the console: `/rts-give rts-aa-turret 1`. Click
      **Defence** (≈1183, 684), then **AA turret** (≈1067, 742; row 2, first), left-click (512, 528), press Q. Wait 15
      s. Click the AA turret, take a screenshot. Click empty ground. Open the console: `/rts-spawn rts-bomber 1
      rts-ai-1 -70` when the AI town of step 13 is east, `/rts-spawn rts-bomber 1 rts-ai-1 70` otherwise (the bomber
      appears 70 tiles west, or east, of the screen centre, away from the front's division, and flies in to attack the
      turret's area). Take a screenshot at once, another after 10 s and one after 20 s.
    - *Expect:* the AA turret (2×2) built; its page "AA turret #N", **"Magazines: N"** (it takes magazines from the
      network within seconds), "Shoots only planes; magazines come from its network.". The reply "rts-spawn: 1 x
      rts-bomber for rts-ai-1 near (x, y), attack-moving to (x, y)"; the bomber comes in from the screen edge, the AA
      turret fires at it (tracers, hit sparks) from 30 tiles and it falls; the kill feed (top left) shows **"[icon] AA
      turret › [icon] Bomber ✕ (AI 1)"**. A bomber the Commander or a unit finishes shows their icon instead.
    - *Pass/Fail:* PASS if the kill feed line names the AA turret. PARTIAL if the bomber dies by another killer (report
      the line).
    - *Log check (lead):* `rts-spawn: 1 x rts-bomber for rts-ai-1 near .* attack-moving to`,
      `build ghost rts-aa-turret player=1 at`, `aa: AA turret #[0-9]+ \(rts-player\) fires at rts-bomber`,
      `aa: AA turret #[0-9]+ \(rts-player\) shot down rts-bomber`

### Part G: an artillery train

20. **A depot and Deploy artillery train.**
    - *Input:* press SPACE. Open the console once per line: `/rts-research rts-railways`,
      `/rts-research rts-military-railways`, `/rts-give rts-depot 1`, `/rts-give rts-locomotive-kit 2`,
      `/rts-give rts-artillery-wagon-kit 1`, `/rts-give rts-rail-shell 40`, `/rts-give coal 100`. Click **Economy**
      (≈1077, 684), then **Rail depot** (≈1067, 742; row 2, first). Left-click the depot site towards the AI town of
      step 13: east (992, 400), west (288, 400), south (640, 640), north (992, 250). Press Q. Wait 20 s. Click the depot.
      Take a screenshot. Click **Deploy artillery train** (≈825, 417).
    - *Expect:* the depot with its 40-tile platform (a straight track beside it). The rail panel "Rails: Depot 1",
      "Platform: 40 tiles, 2 stops", "Kits: locomotive 2, wagon 0, construction 0 | rails 0, coal 100 | troop wagons 0",
      "No line. …", Deploy freight train and Deploy troop train greyed with the yellow line "Freight and troop trains: no
      train kits in the depot network" (no cargo or troop wagon kits: expected), then "Artillery wagon
      kits: 1 · armoured locomotive kits: 0 · armoured wagon kits: 0 · rail shells: 40", **Deploy artillery train**
      enabled, the Armoured checkbox. The hub panel "Depot 1: stockpile policy" opens right of it.
      After the click a train of two locomotives and an artillery wagon stands on the platform.
    - *Pass/Fail:* PASS if the artillery train appears. If **Deploy artillery train** is greyed, the yellow line under
      it says what is missing ("Artillery train needs: 2 × Locomotive kit (1 here), …"): report it (FAIL).
    - *Log check (lead):* `rails: depot #[0-9]+ .* of rts-player at .*: platform`,
      `train: artillery train [0-9]+ \(rts-player\) deployed at depot #[0-9]+ with 20 shells`,
      `train: click deploy artillery depot=#[0-9]+ armoured=false train=[0-9]+`

21. **The train panel and B: Bombard.**
    - *Input:* click one of the train's carriages on the platform (east depot: about (1000, 528), the first locomotive).
      Take a screenshot. Press B. Watch 30 s; take a
      screenshot. (Optional: click the minimap on the red patch of the AI town to see the shells land; press SPACE.)
    - *Expect:* the train panel (x 1026–1273, y 183–375): **"Artillery train N"**, "HP 1000/1000, coal 20", "Position:
      Depot 1", "Stance:" **Hold fire** (lit) and **Bombard [B]**, "Shells: 20 · fired 0",
      Resume, Disband, the hint. After B the build menu does not toggle; **Bombard [B]** is lit (yellow); the gun line
      reads "Shells: 20 · looking for a target, next shot in N s" until the first shot, then **"Shells: 19 · next shot in
      N s · last target: City Center (86 tiles)"**; a shell flies every 10 s (the depot tops the wagon up to 20).
    - *Pass/Fail:* PASS if Bombard lights up and the gun line names a target. FAIL if it reads "no hostile building
      within 120 tiles" (out of range: report the depot site) or "no hostile building seen within 120 tiles: scout it
      first" (in range but no own land, unit, building, plane, radar or held front within 48 tiles of it). After a
      right-click on another depot the position reads "At Depot 1 → Depot 2" (": no path" without a line between them).
    - *Log check (lead):* `train: key B train=[0-9]+ -> bombard ok=true`, `train: [0-9]+ \(rts-player\) stance bombard`,
      `train: [0-9]+ \(rts-player\) fires 1 shell\(s\) at rts-city-center #[0-9]+ of rts-ai-1`

### Part H: money sinks and city-states

22. **Hire in the city panel.**
    - *Input:* press SPACE. Click the CC (640, 400). Take a screenshot. Click **Hire +4 (₡ 160)** (≈837, 588; ≈837, 609
      while the red "Under attack" row shows). Take a screenshot.
    - *Expect:* the city panel's footer: **Hire +4 (₡ 160)** left of Demolish; after the click the treasury drops by
      160 (strip row 2); the button stays (up to 32 points per city).
    - *Pass/Fail:* PASS if the click takes 160 crowns.
    - *Log check (lead):* `sinks: rts-player hires 4 garrison points at city [0-9]+ for 160 cr`

23. **A trade port and Mercenaries.**
    - *Input:* click empty ground. Open the console: `/rts-market ports`; note the number after "port #" in the first
      reply line; open the console: `/rts-market capture N`. Press M. Take a screenshot. Click **Mercenaries (₡ 600)**
      (≈370, 285). Take a screenshot.
    - *Expect:* "market: capture -> true" and a green alert "<Region>: Port captured: Port of <Region>". The market (x
      310–970): **Trade at** "Port of <Region>", under it **Mercenaries (₡ 600)**. After the click: the treasury drops by
      600, a green alert "<Region>: 7 mercenaries hired (Port of <Region>)" (the count depends on the port's region),
      the line "Mercenaries again in 600 s." next to the button, and a new card "Mercenaries (<name>)" (the port region's proper name) in the
      division panel (the division stands at the port, far away).
    - *Pass/Fail:* PASS if the mercenary division appears.
    - *Log check (lead):* `market: port #[0-9]+ \(.*\) captured by rts-player`,
      `sinks: rts-player hires mercenaries at port #[0-9]+ .*: [0-9]+ units, division #[0-9]+, 600 cr`

24. **A city-state in the port drop-down; a Buy there.**
    - *Input:* click **Trade at** (≈800, 265). Take a screenshot of the open list. Click the second entry (≈800, 307),
      the first "Free City of …" (the first entry, ≈800, 286, is your port). Take a screenshot. In the goods table find a row whose "At port" is not 0 (e.g. Copper
      plate 400, Copper cable 400, Stone 300: the city-state's region goods; scroll with the wheel). Its Amount reads 100.
      Click its **Buy** (≈821). Take a screenshot.
    - *Expect:* the list: your port, then four or five entries **"Free City of X (×1.30, +0)"**, each fully readable.
      Selected: the yellow hint "City-state Free City of X: relation +0, its goods at ×1.30. A city-state sells its
      region's goods at a markup …"; the prices are 1.3 × the market's; "At port" shows its stock. After Buy: the
      treasury drops by about 100 × the price, "At port" drops by 100, and the drop-down entry reads "(×1.30, +1)" (or
      more); after 30 s the goods arrive in your capital (a "delivery" line in the log).
    - *Pass/Fail:* PASS if the city-states are in the list and a Buy raises the relation.
    - *Log check (lead):* `market: player 1 buy 100 .* with partner [0-9]+: true`,
      `sinks: rts-player buys 100 .* from city-state [0-9]+ at`, `sinks: rts-player city-state delivery of 100`

25. **Rush in the research panel.**
    - *Input:* press M (or Escape). Press T. Click **Research** in the Chemistry row (≈1175, 431). Take a screenshot.
      Hover **Rush** (≈1155, 194) for 2 s and take a screenshot; click it; take a screenshot. Press T.
    - *Expect:* "Researching: Chemistry (0 %)" with a bar and, at its right, **Rush**: grey, because this base has no
      working lab (a rush only pays while a lab works); its tooltip ends "Rush refused: no lab is working: the labs need
      this research's kits", and the click starts nothing. (With a lab working on kits the button is lit and turns into
      **"Stop rush (₡ N/min)"**.) Chemistry, Nuclear power and Air Force (if not researched) no longer read "Needs Age
      III".
    - *Pass/Fail:* PASS if Rush is grey with that tooltip (or, with a working lab, turns into "Stop rush").
    - *Log check (lead):* `research: rts-player queued rts-chemistry: true`; no `sinks: rts-player rushes research` line

### Part I: the map and the help page

26. **Front lines and depot labels on the map.**
    - *Input:* press SPACE. Scroll the wheel towards you one notch at a time until the view turns into the map (about
      10–15 notches). Take a screenshot. Scroll in until the depot and its platform are large, still in the map view;
      take a screenshot. Scroll back in until the game view returns, then press SPACE.
    - *Expect:* your land outlined in blue, the AI town's land in red next to it; between them a thick coloured **front
      line** with the label **"Front 2 · threat N · held by Division 1"**; the capital's name "Capital", the region
      name, your port "Port of X (You)"; the depot's two stop markers (white dots in dark rings) with a label
      "Depot 1" above the depot (map text like the city names: readable when the map is zoomed in on the capital,
      small when zoomed out). No raw names like "rts-player depot 601" anywhere on the map.
    - *Pass/Fail:* PASS if the front line and its label show, "Depot 1" is readable at some map zoom and no raw station
      name shows. PARTIAL if "Depot 1" is missing or unreadable at every zoom.
    - *Log check (lead):* `camera zoom player=1`

27. **The help page in the match.**
    - *Input:* press F11 (or click **?**, ≈760, 22). Scroll to the end with the wheel over the text. Take a screenshot.
      Click the × (≈861, 89).
    - *Expect:* the same 11 Nation paragraphs as in step 3; the page stays inside the window (y 74–722) and scrolls.
    - *Pass/Fail:* PASS if the Keys paragraph is reachable.
    - *Log check (lead):* `hud help opened player=1 \((F11|\? button)\): 11 lines \(nation\)`

### Part J: the 4096 lobby

28. **Back to the lobby: 6 nations, 4096, Survey.**
    - *Input:* press F10 (or click **Menu** on the strip, ≈868, 22). Take a screenshot. Click **Restart** (≈533, 445).
      Wait 5 s. Click **Nations** (≈596, 267), then "6" (≈620, 372). Click **Map size** (≈615, 321), then "World
      (4096×4096)" (≈640, 384). Click **Start map** (≈596, 375), then "Survey" (≈620, 417). Take a screenshot.
    - *Expect:* the menu "Menu" with "Nation · 2 nations · Normal · World 2048×2048 · Conquest + Space · unlimited" (two
      lines, not cut), "Match time: mm:ss", Restart, Concede, Resume. Restart opens the start dialog again, Mode still
      Nation. After the clicks: Nations "6", Map size "World (4096×4096)" (6 nations on 2048 would move it to 3072),
      Start map "Survey", and the generation line **"World 4096×4096 (16384 chunks): … in about 7 min, …"**.
    - *Pass/Fail:* PASS if the dialog shows 6, 4096, Survey and the 4096 generation line.
    - *Log check (lead):* `lobby: back in the lobby \(restart by player 1\)`,
      `lobby: player 1 set opponents -> 5 opponent\(s\), normal, nation`,
      `lobby: player 1 set world_size -> 5 opponent\(s\), normal, nation, world 4096`, `lobby: player 1 set survey`

29. **Start the 4096 world: the generation line.**
    - *Input:* click **Start match** (≈732, 586). Wait up to 15 s (the start of a 4096 world with 6 nations takes about
      8 s). Take a screenshot. Wait 30 s. Take a screenshot.
    - *Expect:* a new capital at 00:00 with "Age I"; under the minimap **"World: N % generated"** (≈1188, 194), N about
      3 % at first and growing (about 10–17 % after 30 s); the minimap shows the charted land around the capital
      (Survey charts what exists). The strip, the city list and the build menu as in step 4.
    - *Pass/Fail:* PASS if the line shows and its percentage grows.
    - *Log check (lead):* `match: starting match [0-9]+: 5 opponent\(s\), normal, nation, world 4096x4096, brain ai`,
      `world: survey: [0-9]+ generated chunks charted for rts-player`

### Part K: end

30. **End the session.**
    - *Input:* open the console, type `RTS_QA_END` (no slash) and press Enter. If the window does not close within 10 s,
      press Ctrl+Shift+E (or Cmd+Shift+E).
    - *Expect:* the typed line appears in the chat, and within about 5 s the game window closes: the lead's launch
      script stops the client when the log shows the marker. Other agents use this machine too, and their Factorio
      windows open at the same place with the same title: a loading screen or a new match at 00:00 that appears after
      the QA match went is not this session. Do not send it any input; take one screenshot and stop.
    - *Pass/Fail:* PASS if the line appears in the chat and the QA match is gone within about 10 s. A screenshot request
      that times out after the marker means the window is gone (expected), not a failure.
    - *Log check (lead):* `RTS_QA_END by player=1 at tick [0-9]+ \(console chat\)`

**The AI meanwhile (lead).** Informational; the autotests measure these: `council:`, `planner:` and `air:` lines of
rts-ai-1 (an AI at war may send planes and a belt to the new front), `capture: city [0-9]+ of rts-player .* subdued by rts-ai-1`.

## Recovery

- **The camera is somewhere else.** Press SPACE, or click a name in the city list.
- **Clicks select nothing.** Press F1: it gives the RTS cursor back.
- **A ghost is stuck on the cursor.** Press Q, right-click, or press F1.
- **A console line was mistyped.** The reply says so; type it again.
- **A ghost cannot be placed** (it stays on the cursor in red): something is in the way (often the Launch complex);
  click 6 tiles further away, or at the mirror site on the other side of the CC.
- **A building does not get built** (a ghost stays): the network lacks the item (repeat the step's `/rts-give`) or the
  site is outside the CC's network (place it within 25 tiles of the CC).
- **The ledger or a panel hides what you need.** Close it with its × or Escape (or the key that opened it: L, M, T, Y,
  F4, F11), or click empty ground (city and building panels).
- **"Space Program cannot start now: no spot …"**: the land around the capital is full; demolish a building near the CC
  (select it, Delete twice) and click Start again.
- **The stage does not finish** (the goods stop counting): repeat the three `/rts-give` lines of step 7.
- **F opens nothing** (step 16): a unit was selected (F is attack-move then). Click empty ground and press F again, or
  click the gate button at the right of the build menu's title (≈1256, 663).
- **The fort belt plan waits** ("waits for [icon]"): give 10 more of that item (wall, turret, field depot, AA turret).
- **The Y panel says "Select planes …"**: press Ctrl+A and click the plane card (the last card).
- **Deploy artillery train greyed:** read the yellow line under the train buttons; "no train kits": repeat the
  `/rts-give` lines of step 20; "the platform is occupied": click the train there and press Disband.
- **The artillery gun line says "no hostile building within 120 tiles"**: the depot is on the wrong side; place a second
  depot (`/rts-give rts-depot 1`) 22 tiles towards the AI town and click the train, then right-click the new depot (the
  train drives there along a line only; if there is none, Disband and Deploy at the new depot).
- **The RTS view is gone** (a character, vanilla menus or no HUD). Wait 2 s. If it does not come back, report FAIL.
- **The state is broken.** Press Ctrl+Shift+R: it starts the same Nation match again on a new world. Then redo steps 5
  and 12 before the step you were on, and report the restart.

## Results to report

- One line per step: PASS, PARTIAL, FAIL or SKIP, with what the screenshot shows.
- Every console line typed, in order, and its reply.
- The workers of the Steel works before and after automation (steps 9–10), the rare line (step 11), the direction words
  of `/rts-front` and `/rts-deposit`, the gun line of the artillery train (step 21), the relation in the drop-down before
  and after the Buy (step 24), the percentages of the world line at the start and after 30 s (step 29).
- Every AI attack: its strip time, what it hit, and the outcome.
- Any text that is clipped (ends in "…"), overlaps, shows a raw key (`rts-…`, "Unknown key") or is in the wrong
  language; any panel that covers another, the minimap or the world line.
- Any element more than about 30 px from its given coordinates.
- Which function keys failed, and whether the alternative worked.

## Not covered

- **The LAN join** (the lead's separate check, `tools/lan-check.sh`).
- **Stages 2 and 3, the launch and the Space victory**, a razed Launch complex (the Age III fixture
  `tools/probes/age3_fixture.lua`); the AI's own Space Program.
- **The nuclear plant, the Age III districts at work, uranium rounds** (the fixture).
- **A rare bonus lost** after its flow stops (90 s; the fixture), rare deposits on city-state land.
- **Plane kits from a barracks, bombers and interceptors in combat, a crash at supply 0** (`tools/probes/air_autotest.lua`).
- **Gates where a belt crosses rails, belts on a threatened segment by the AI, armoured trains, a train sent to a rail**
  (`tools/probes/war2_autotest.lua`).
- **The mercenary cooldown, hired garrison decay, city-state selling and the capture penalty** (the fixture).
- **3072 worlds, 3–5 nations, a save in the middle of generation** (`tools/probes/world3_autotest.lua`).
