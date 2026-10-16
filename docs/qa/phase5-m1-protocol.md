# Phase 5 M1 GUI QA protocol: a Nation match

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age enabled. Mod `factorio-rts` 0.1.0 with the commit "M1 integration: m1-docs findings"
(right after 3f33f4c): the city panel's Demolish button, no Demolish for rolling stock, the build grid refilled at a Nation
match start, the factory's category tabs hidden on pages without recipes, the hauler's coal tank in the hauler panel,
`/rts-research` and `RTS_QA_END` typed in the console. Integration notes: `docs/qa/phase5-m1-integration-notes.md`.

**Updated after QA round 1** (`docs/qa/phase5-m1-qa-results.md`, fixes in the integration notes, section "QA round 1
fixes"): the make targets are picked in the mod's own item picker (steps 15 and 43), a click on a number field selects
its text, a division's attack-move walks to the point (step 33), "Enemies seen" reads 0 with no enemy in sight, the City
charter keeps its name in the build menu and the factory, the ledger hides its Start button once the Charter is started
(Start moved to ≈686, 314), and clicks next to a train or a depot no longer select it.

This protocol plays one Nation match on a 1536×1536 world against one Normal AI. It covers:

- the lobby's Mode and World size;
- the capital, the Nation HUD (age badge, Land button, city list), borders and fog;
- the build menu and the factory's category tabs;
- founding a city with a City charter, the city panel (make targets, rename);
- hauler fuel in Nation mode;
- depots, laying a rail line, the construction train, a freight train, its route and cargo;
- rolling stock and Demolish;
- divisions;
- Age II through the Railway Charter, the Age II build tab, a district, the city ledger;
- the army surcharge, demolishing a building and a City Center, and the end marker.

The tester is an automated agent with computer use. It sees only the screen and uses only the mouse and the keyboard.
Unlike Phase 4, it also types a few QA shortcuts into the game console; every step that needs one gives the exact
text. Every step gives the input, what must be visible afterwards, and how to judge PASS or FAIL from the screen. The
"Log check (lead)" lines are for the lead, who greps the log after the run; the tester ignores them.

**Coordinates.** They were measured on 2026-10-16 from screenshots of an English client in the same 1280×800 window
(`tools/probes/m1_docs_gui.lua`, screenshots in `build/shots-m1d-gui/`). The few marked "(code)" are derived from the
GUI code (frame sizes, margins, UI scale 0.75). The world is generated anew for every run: the capital's place on the
minimap, the terrain around it and the direction of the AI differ from run to run, so map positions are given relative
to your Command Center.

Background: `README.md` (section "Nation mode"), `docs/PHASE5-M1.md` and `docs/qa/phase5-*-notes.md`.

## Launch (lead)

```sh
cd /Users/evgeniyivanov/Projects/home/games/factorio_rts
rm -rf build/qa-p5m1 && mkdir -p build/qa-p5m1 && cp -R mods/factorio-rts mods/mod-list.json build/qa-p5m1/
RTS_LOCALE=en tools/gui-run.sh build/qa-p5m1 3600 'RTS_QA_END'
```

- **Frozen copy.** The copy keeps other agents' edits out of the run. The log is `build/qa-p5m1-gui.log`. The script
  stops when the log contains `RTS_QA_END` (step 48), or after one hour. Steam must be running.
- **Language.** `RTS_LOCALE=en` makes the client English. Without it the client follows the system language, which is
  Russian on this Mac. The steps name the English labels, and the glossary below gives the Russian ones.
- **No self-test.** The GUI self-test is off: no script clicks anything, and the game opens in the lobby.
- **Console.** `tools/gui-run.sh` writes a config that binds F9 to the console, so it opens with any input source. The
  tester is the admin of a local game, so the admin commands work.
- **Log checks.** Use `grep -nE 'PATTERN' build/qa-p5m1-gui.log`. Every mod line contains `[rts]`. Where a step lists
  several patterns, each must match. Console replies are logged too (`rts-give: …`, `rts-spawn: …`, `rts-research: …`).
- **World.** `grep -E 'world: planned' build/qa-p5m1-gui.log` prints the world's seed; the world differs per run.
- **AI doctrine.** `grep -E 'ai rts-ai-1: doctrine' build/qa-p5m1-gui.log`. The AI is about 900 tiles away, so its
  attacks arrive minutes after they start.

## Tester setup

- **Coordinates.** They are game-area coordinates of the 1280×800 game window at UI scale 0.75, the automatic scale. On
  screen, the macOS title bar adds about 28 px to y. Every coordinate is approximate (≈). If an element is not exactly
  there, find it in a screenshot by its description. If the window is larger than 1280×800, for example 1920×1080,
  multiply x by the window width / 1280 and y by the window height / 800 (1.5 and 1.35 there); the HUD panels keep to
  the same window edges, so look for an element by its description when the scaled point misses it.
- **Inputs.** You have the mouse (left click, right click, Shift + click, Shift + right click, wheel), the keyboard and
  the console for the QA shortcuts in the table below. Do not use the console for anything else.
- **The console.** Press F9 (on a Mac keyboard where F9 is a media key, Fn + F9), or the backtick key (`` ` ``) with
  the English input source. An input line opens at the bottom left. Type the text exactly as given, then press Enter. The
  reply appears as a chat line at the bottom left, above the selection panel. If the input line is still open after
  Enter, press Escape once to close it. Keys typed into the console do not reach the game.
- **Keyboard.** Use the English (ABC or US) input source. Every Ctrl chord also works with Cmd: Ctrl+A or Cmd+A,
  Ctrl+Shift+E or Cmd+Shift+E. If a Ctrl chord shows no effect, use the Cmd chord and say so in the report.
- **Function keys.** macOS may take F3, F9, F10 or F11. If one does something outside the game, or nothing, use the
  alternative the step names (an alert line, the Menu button, Fn + the key, the backtick key) and report it. Then click
  the game window once on empty ground to give it focus again.
- **Drags.** A drag often registers as a click. No step needs a drag.
- **Time.** The game runs in real time and does not pause while you work. "Wait 20 s" means: watch the timer at the top
  of the screen advance by 20 s.
- **Camera.** The map coordinates assume the camera centred on your Command Center (CC) at the start zoom. SPACE
  centres the camera on the CC and keeps the zoom. A click on a name in the city list centres the camera on that city.
  Steps 6, 12, 13, 25 and 47 zoom out by **exactly 5 wheel notches** (towards you, one at a time) and back by 5 notches
  (away from you). At the start zoom the CC's left and right stockpiles are 112 px apart; zoomed out, a tile is ≈5 px.
- **Empty ground** (to deselect): any spot with no unit and no building; ≈(1000, 600) or ≈(200, 200) after SPACE,
  whichever is bare.
- **Escape.** Press Escape only to close the ledger, the research panel, "How to play", the menu or an open console
  line. If the Factorio game menu opens instead, press Escape once more.
- **Text fields** (city panel, hub panel, ledger). Click the field, type the number or name, press Enter. Keys typed
  into a field do not reach the game.
- **Evidence.** Take a screenshot after every step. Report one of these, with one line on what the screenshot shows:
  - **PASS:** everything under "Expect" is seen.
  - **PARTIAL:** the main effect is there, but a detail differs. Say which.
  - **FAIL:** the main effect is missing.
  - **SKIP:** a precondition is missing. Say which.
- **Survival.** Step 7 adds 30 walkers by console; they guard the capital while the Commander is away founding a city.
  The AI's attacks come from far away and lose health deep in your land (attrition).
- **Time budget.** The session closes after one hour of wall time, and the steps take about 45 minutes. If the strip
  timer passes 45:00, or you have been testing for 50 minutes, go to step 46 and finish.

### QA shortcuts (console)

The economy that earns these takes much longer than a QA session; the shortcuts give the result so the steps can test
what comes after it. Type each line exactly, one per console opening.

| Step | Text | Why |
|---|---|---|
| 7 | `/rts-spawn rts-walker 30` | an army beyond 30 units for the surcharge check (step 45), and a guard for the capital |
| 11 | `/rts-give stone 40` | the City charter takes 40 stone; the start stock has none |
| 17 | `/rts-give electronic-circuit 10` | the hauler kit; circuits need a copper and cable chain |
| 19 | `/rts-give coal 200` | hauler and train fuel; the start stock has no coal |
| 21 | `/rts-research rts-railways` | Railways needs 15 basic science kits from labs |
| 21 | `/rts-give rts-depot 2`, `/rts-give rts-locomotive-kit 4`, `/rts-give rts-cargo-wagon-kit 2`, `/rts-give rts-construction-wagon-kit 1`, `/rts-give rail 400`, `/rts-give iron-plate 300` | depots, kits and rails need steel; the iron is for the train's cargo |
| 36 | `/rts-research rts-industrialisation` | Industrialisation needs 20 advanced kits |
| 38 | `/rts-give steel-plate 100`, `/rts-give electronic-circuit 115`, `/rts-give iron-gear-wheel 100`, `/rts-give stone 190` | the Railway Charter's goods, plus one district |
| 45 | `/rts-give copper-plate 2`, later `/rts-give copper-plate 50` | 2 copper make exactly one walker kit that then waits for its surcharge |
| 48 | `RTS_QA_END` (no slash) | the end marker |

### Where things are on the HUD

| Element | Location (game area) | Contents |
|---|---|---|
| Top strip | x 370–910, y 6–78 | **Row 1** (y≈22): timer, "Army N", "vs", "Enemies seen: N", "Supply used/cap", then the buttons **Research [T]** (≈710), **?** (≈758), **Land N%** (≈803, Nation mode only) and **Menu** (≈862). They shift a little with the text. **Row 2** (y≈44): iron, copper, steel, circuits, explosives, stone, magazines, power, robots. **Row 3** (y≈62): the message line. |
| Age badge | x 251–364, y 6 to ≈118 | Nation mode only. A button **Age I** / **Age II** (≈302, 21); under it 2–5 lines of small text on the national project. A click opens the city ledger. |
| Alert lines | x 445–835, y 81–135 | Up to 3 lines, newest on top (y≈94, 110, 126), each with an icon and "N s ago"; a click jumps the camera there. |
| Kill feed | x 6–200, y 6–60 | Up to 5 lines of unit deaths. |
| City list | x 6–201, from y 96 | Nation mode only. Header "Cities" with "Land N%" (y≈109); one row per city (y≈127, ≈146): a **name button** (≈36, 127 / ≈38, 146) that jumps the camera to the city, "Town, N cells", and a **magnifier** (≈185) that opens the city panel. The Land button on the strip hides and shows it. |
| Division panel | x 6–231, top y≈150 (one city in the list) or ≈170 (two cities) | While divisions exist, 2+ combat units are selected or a barracks is selected. With two cities: header "Divisions (N)" and **Form division** (≈187, 186); with a barracks selected a row "Reinforces:" with a drop-down (≈120, 209). A card: name button (≈44, 211), "36/36", a health bar, "Idle … Hold"; when the whole division is selected also **Hold** (≈50, 253), **Advance** (≈116, 253), **Screen** (≈184, 253), a **Reinforce** checkbox (≈22, 274), a pencil (≈183, 274) and a bin (≈208, 274). |
| Minimap | x 1106–1271, y 9–174 | The whole 1536-tile world, ≈0.1 px per tile. Black where never seen. Your land: a blue outline and tint; the AI's land: red. A left click moves the camera there. |
| Selection panel, units page | x 6–396, y 699–794 | As in Phase 4: "37 units selected", cards at y≈736 (Commander ≈22, walker ≈47, …), groups, command buttons at y≈763. |
| Selection panel, building page | same | **Title line** (y≈714): "Factory #N", HP, **Demolish** (≈361, 714). A factory in Nation mode also has 5 small **category tabs** in the title line: Buildings (≈92), Logistics (≈112), Intermediates (≈132), Science (≈152), Age II (≈172). **Barracks:** recipe buttons at y≈737 (a second row at y≈762), text to the right (lines at y≈731, ≈747, ≈764). **Factory and district:** recipe buttons at y≈737 and ≈762, button x = 27 + 26 × index; the status line under them (y≈785 with two rows, ≈759 with one). |
| Build menu | x 1043–1274, y 678–794 in Nation mode (two rows for every tab, so the tabs never move; Skirmish: one row, y 710–794, tabs y≈744, buttons y≈772) | Tabs at y≈712; buttons in row 1 at y≈740 and row 2 at y≈772. Tabs: **Economy** (≈1077), **Production** (≈1131), **Defence** (≈1183) and a small **Age II** icon tab (≈1216, a blue science-kit icon; Nation mode only). Buttons at x≈1066, 1097, 1128, 1159, 1190, 1221, 1252, each with the count in your network. |
| Ability bar | x 461–820, y 729–794 | The Commander portrait (486, 753): a click selects the Commander. |
| City panel | x 788–1013, y 183 to ≈470 | Nation mode, while an own City Center or the CC is selected (or from the magnifier). Title "Capital: Town" and × (≈994, 198); a name field (≈886, 221) and a pencil (≈991, 221); lines at y≈242 (tier), 260 (nation age), 278 (land), 296 (supply), 314–329 (next tier), 348 (networks), 366 ("Make targets"); one row per make target (y≈391: icon ≈812, field ≈861, × ≈903); the **+** button (≈812, 394 with no targets, one row lower per target) and a hint; **Demolish** at the bottom right (≈978, 421 with no targets; ≈978, 453 with one). |
| Item picker "Pick a good to make" | from the city panel: left of it, x 461–781, y 183 to ≈510; from the ledger: centred over it, x 480–800 | The **+** button of the city panel or the ledger's item button opens it. Title and × (≈764, 198 next to the city panel); a hint; "Can make now" and "After research", each a grid of item icons 30 px apart (10 per row; first row y≈281 next to the city panel, y≈334 over the ledger). Every icon's tooltip names the good. A click picks the good and closes the picker. In Age I next to the city panel, Iron gear wheel is the 4th icon of the first row (≈574, 281); in Age II over the ledger, Plastic bar is the 10th icon of the first row (≈773, 334). |
| Hub panel (stockpile policy) | x 1019–1273, y 183 to ≈495 | While a hub, City Center, depot or the CC is selected. Title "…: stockpile policy" and × (≈1256, 198); "Network #K, N hubs" (y≈218); for a hub, City Center or depot a **Demolish** button (≈1053, 289) above the table, rows iron y≈336, copper ≈369, steel ≈402, stone ≈435, coal ≈468; for the CC no Demolish, rows y≈314, 347, 380, 413, 446. **Keep** fields x≈1146, **Export above** x≈1200. |
| Depot rail panel | x 765–1012, y 183 to ≈405 | Left of the hub panel while a depot is selected: "Rails: Depot N", "Platform: 40 tiles, 2 stops" (y≈218), the kits line (y≈236–251), the line (y≈269–284) and its detail (y≈287), **Deploy freight train** (≈821, 307), a hint, "Rail lines" (y≈375) and the list (y≈393). |
| Train panel | x 1026–1273, y 183 to ≈385 | While a locomotive or wagon is selected: "Freight train N" and ×, HP and coal (y≈218), route, state, cargo, trips, the line, **Resume** (≈1058, 328–343), hint. |
| Hauler panel | x 1019–1273, y 183 to ≈360 | **Auto** (≈1073, 220), **Route** (≈1114, 220), "HP 400/400"; home or route (y≈240), state (≈257), cargo (≈276), trips (≈295); **Return home** (≈1062, 314), **Resume** (≈1124, 314); hint. |
| City ledger | centred, x≈355–925; y≈244–553 with 4 goods rows | L or the age badge. Title "City ledger" and × (≈907, 259); "City:" drop-down (≈461, 293) and the age (≈581, 293); the project line (≈476, 314) with **Start the Railway Charter** (≈686, 314; hidden once the Charter is started, a progress bar in its place); the goods line (y≈332); the table (header y≈374, rows from ≈393, 20 px apart); under it "New target:", an item button (≈440), a number field (≈481) and **Set** (≈547); the footer. With more rows the frame grows taller around the same centre, so these y values move up. |
| Console | bottom left | F9; the replies appear as chat lines above the selection panel. |

**Factory recipe buttons in Nation mode** (x = 27 + 26 × index, row 1 y≈737, row 2 y≈762):

| Tab | Index: recipe |
|---|---|
| Buildings | row 1: 0 Pause, 1 **Auto**, 2 Hub, 3 Rail depot (grey until Railways), 4 **City charter**, 5 Stockpile, 6 Extractor, 7 Smelter, 8 Solar array, 9 Factory, 10 Lab, 11 Steam plant (grey), 12 Accumulator, 13 Barracks; row 2: 0 Turret, 1 Fort, 2 Laser turret (grey), 3 Wall, 4 Radar |
| Logistics | 0 Pause, 1 Auto, 2 Rails, 3 Transport belts, 4 Fast inserters, 5 Medium electric poles, 6 **Hauler kit**, 7 Locomotive kit, 8 Cargo wagon kit, 9 Construction wagon kit (2, 7, 8, 9 grey until Railways), 10 Firearm magazines |
| Intermediates | 0 Pause, 1 Auto, 2 Iron gear wheel, 3 **Copper cable**, 4 Electronic circuit, 5 Explosives, 6 Engine, 7 Advanced circuit, 8 Steel beam, 9 Concrete (6–9 grey until Age II) |
| Science | 0 Pause, 1 Auto, 2 Basic science kit, 3 Advanced science kit, 4 Industrial science kit (grey until Age II) |
| Age II | row 1: 0 Pause, 1 Auto, 2 Oil well, 3 Refinery, 4 Chemical plant, 5 Smelting works, 6 **Steel works**, 7 Circuit works, 8 Electronics plant, 9 Petrochemical works, 10 Engine works, 11 Munitions works, 12 Rail works, 13 Construction works; row 2: 0 Science campus, 1 Bunker (all grey until Age II) |

**Barracks recipe buttons** (y≈737): 0 Pause (27), 1 Walker kit (53), 2 Heavy walker kit (79, grey), 3 Drone kit (105),
4 Raider kit (131, grey), 5 Artillery walker kit (157, grey); row 2 (y≈762): Armoured car kit (27, grey until Age II).

**Build menu tabs in Nation mode** (button order):

- **Economy** (two rows): Extractor, Smelter, Stockpile, Transport belt, Fast inserter, Medium electric pole, Hub;
  row 2: Rail depot.
- **Production** (one row): Barracks, Factory, Lab, City charter, Fort.
- **Defence** (one row): Turret, Laser turret, Wall, Solar array, Steam plant, Accumulator, Radar.
- **Age II** (two rows): Oil well, Refinery, Chemical plant, Smelting works, Steel works, Circuit works, Electronics
  plant; row 2: Petrochemical works, Engine works, Munitions works, Rail works, Construction works, Science campus,
  Bunker.

### Where things are on the map

After SPACE the camera is centred on your CC, and a tile is 16 px at the start zoom (≈5 px after 5 notches out):

```
screen x = 640 + 16 × (tiles right of the CC)        screen y = 400 + 16 × (tiles below the CC)
```

| Thing | Where (after SPACE, start zoom) |
|---|---|
| Your CC, 4×4, with 4 small stockpiles | (640, 400); stockpiles (584, 376), (584, 424), (696, 376), (696, 424) |
| The Commander at the start (big blue spider-tank) | right next to the CC, on the walkers' side |
| 6 walkers at the start | 14–18 tiles from the CC on one side (the side facing the middle of the world) |
| 30 walkers from step 7 | three rows of 10 below the CC: feet x≈424–928, y≈592–704 (bodies 48 px higher) (code) |
| Hauler waiting spot | just below the CC, ≈(640, 456) |
| **Sites used below:** factory / barracks | (448, 304) / (832, 304): 12 tiles left / right of the CC and 6 up |
| Depot 1 | (288, 400): 22 tiles left of the CC; the game lays its 40-tile platform beside it, usually 8 tiles below |
| Steel works (step 41) | (640, 208): 12 tiles above the CC |
| Railway Charter site | placed by the game 12–20 tiles from the CC, on the side away from the walkers |
| City site (step 12, zoomed out 5 notches) | ≈(87, 400) or ≈(1193, 400): about 110 tiles left or right of the CC (code) |
| After a click on the new city in the city list | its City Center at (640, 400), stockpiles (584, 407) and (696, 407) |
| Depot 2 (step 23) | (832, 432): 12 tiles right of the City Center and 2 down |

- Every site is a suggestion: any bare ground nearby works (no water, no grey rock, no building). Ore is fine.
- Your land reaches about 96 tiles around the CC (480 px when zoomed out). A new City Center needs 96 tiles to every
  other City Center or capital, and nothing can be built on the AI's land.
- The CC's robots build ghosts up to 40 tiles out, from the CC's network. A City Center's robots build up to 30 tiles
  out, but only from its own network, which starts empty. Further out, or at a new city, the **Commander** builds every
  ghost within 15 tiles of it, with items taken from the CC's network.
- A depot within about 39 tiles of the CC joins the CC's logistic network; a depot within about 28 tiles of a City
  Center joins that city's network.

### Glossary (English → Russian)

| English | Russian |
|---|---|
| Factorio RTS: new match; Mode; Skirmish; Nation; Opponents; Difficulty; Normal | Factorio RTS: новый матч; Режим; Схватка; Держава; Противники; Сложность; Нормальная |
| Map size; World (1536×1536); Map; World; Start match | Размер карты; Мир (1536×1536); Карта; Мир; Начать матч |
| Army 7; Enemies seen: 0; Supply 6/40; Research [T]; Land 1.2%; Menu | Армия: 7; Врагов видно: 0; Снабжение 6/40; Исследования [T]; Земля 1.2%; Меню |
| Pick a good to make; Can make now; After research | Выберите товар; Можно делать сейчас; После исследований |
| Age I; Age II; Age I: Settlement; Age II: Industry | Эпоха I; Эпоха II; I эпоха: поселение; II эпоха: индустрия |
| Research Industrialisation (advanced kits) to start the Railway Charter. | Исследуйте Индустриализацию (продвинутые наборы), чтобы начать Железнодорожную хартию. |
| Industrialisation is done: start the Railway Charter. | Индустриализация изучена: начните Железнодорожную хартию. |
| Railway Charter: N % delivered from the capital's network. | Железнодорожная хартия: доставлено N % из сети столицы. |
| Railway Charter complete: Age II in N s.; Railway Charter: Age II in N s | Железнодорожная хартия готова: II эпоха через N с.; Железнодорожная хартия: II эпоха через N с |
| Railway Charter N %; Start the Railway Charter; Railway Charter site | Железнодорожная хартия N %; Начать Железнодорожную хартию; Стройка Железнодорожной хартии |
| Railway Charter started next to the capital; A new age for your nation: Age II: Industry | Железнодорожная хартия: стройка начата рядом со столицей; Новая эпоха для вашей державы: II эпоха: индустрия |
| Cities; Capital; Town, 441 cells; Village; City; Ironford | Города; Столица; Посёлок, ячеек: 441; Деревня; Город; Железноброд |
| City founded: Ironford; City lost: Outpost; Territory lost near Capital (N cells) | Основан город: Железноброд; Город потерян: Outpost; Потеряна земля у города Столица (клеток: N) |
| Capital: Town; Tier: Town, land radius 96 tiles (capital); Nation age: 1 | Столица: Посёлок; Уровень: Посёлок, радиус земли 96 клеток (столица); Эпоха державы: 1 |
| Land: N cells, M% of your nation; Supply: 40 | Земля: N ячеек, M% вашей державы; Снабжение: 40 |
| Next tier, City: buildings on its land 2/25, goods delivered to its market 0/2000 | Следующий уровень, Город: зданий на его земле 2/25, доставлено товаров на рынок 0/2000 |
| Logistic networks on its land: 1 (#1); Make targets | Логистические сети на его земле: 1 (#1); Цели производства |
| Factories without a fixed recipe make the largest shortfall. | Заводы без закреплённого рецепта делают то, чего не хватает больше всего. |
| Demolish; Press again; Demolish 1 building(s)? Press again within 3 seconds. | Снести; Нажмите ещё раз; Снести зданий: 1? Нажмите ещё раз в течение 3 секунд. |
| The Command Center and the capital cannot be demolished. | Командный центр и столицу снести нельзя. |
| Command Center cannot be demolished.; Locomotive cannot be demolished. | Командный центр: снести нельзя.; Локомотив: снести нельзя. |
| Demolished Barracks; Demolished City Center | Снесено: Казармы; Снесено: Городской центр |
| Command Center; City Center; City charter; Fort; Factory; Barracks | Командный центр; Городской центр; Городская грамота; Форт; Завод; Казармы |
| Build [B]; Economy; Production; Defence; Q / right-click: done | Стройка [B]; Экономика; Производство; Оборона; Q / ПКМ: готово |
| Placing City charter: left-click the map. R rotates. Q or right-click: done. | Городская грамота: ЛКМ по карте — поставить, R — повернуть, Q или ПКМ — готово. |
| Requires research: Railways (T); Age II (Railway Charter) | Нужно исследование: Железные дороги (T); II эпоха (Железнодорожная хартия) |
| Factory tabs: Buildings; Logistics: …; Intermediates: …; Science kits; Age II buildings: … | Здания; Логистика: …; Полуфабрикаты: …; Научные наборы; Здания II эпохи: … |
| Auto; Auto: Paused: pick a recipe.; Auto: Iron gear wheel: running; waiting for | Авто; Авто: Пауза: выберите рецепт.; Авто: Железная шестерня: работает; ждёт |
| Crafted 1 · to network 1 | Сделано 1 · в сеть 1 |
| Command Center: stockpile policy; Network #1, 2 hubs; In network; Keep; Export above | Командный центр: правила склада; Сеть №1, хабов в ней: 2; В сети; Держать; Вывоз от |
| Hauler #N; Mode: Auto / Route; Home: Command Center; Route: Outpost → Command Center | Транспортёр №N; Режим: Авто / Маршрут; Дом: Командный центр; Маршрут: Outpost → Командный центр |
| State: Waiting, nothing to carry; no coal for the trip in the hub network | Состояние: ждёт, нечего везти; в сети хаба нет угля на рейс |
| To pickup; Going home; Cargo: empty; Tank: [coal] 4; Return home; Resume | к погрузке; домой; Груз: пусто; Бак: [уголь] 4; Домой; Продолжить |
| Hauler N: no fuel at Command Center | Транспортёр N стоит без угля: Командный центр |
| Railways; Industrialisation; Research complete: Railways | Железные дороги; Индустриализация; Исследование завершено: Железные дороги |
| Rail depot; Depot 1; Rails: Depot 1; Platform: 40 tiles, 2 stops | Ж/д депо; Депо 1; Ж/д: Депо 1; Платформа: 40 клеток, 2 остановки |
| Kits: locomotive 4, wagon 2, construction 1 \| rails 400, coal N | Комплекты: локомотив 4, вагон 2, путеукладчик 1 \| рельсы 400, уголь N |
| No line. Select this depot and right-click another depot to lay one. | Линии нет. Выберите это депо и щёлкните ПКМ по другому депо. |
| Depot 1 → Depot 2: surveying / building / open, N tiles, M rails | Депо 1 → Депо 2: изыскания / строится / открыта, N клеток, M рельсов |
| P pieces, Q missing, 0 supports, S signals | участков P, не хватает Q, опор 0, сигналов S |
| Deploy freight train; Rail lines; No rail lines yet; Rail line open | Собрать грузовой поезд; Ж/д линии; Ж/д линий пока нет; Ж/д линия открыта |
| Freight train N; Construction train N; HP 1000/1000, coal 20 | Грузовой поезд N; Путеукладчик N; Прочность 1000/1000, уголь 20 |
| No route: right-click a depot (pickup), Shift + right-click a depot (drop-off) | Нет маршрута: ПКМ по депо (погрузка), Shift + ПКМ по депо (разгрузка) |
| Route: Depot 1 → Depot 2; idle (no route); to the pickup; loading; to the drop-off; unloading | Маршрут: Депо 1 → Депо 2; стоит (нет маршрута); едет на погрузку; погрузка; едет на разгрузку; разгрузка |
| waiting: nothing to carry; Trips: 1, delivered: …; Cannot deploy a train: out of coal | ждёт: нечего везти; Рейсов: 1, доставлено: …; Нельзя собрать поезд: кончился уголь |
| Locomotive; Cargo wagon; Construction wagon | Локомотив; Грузовой вагон; Путеукладочный вагон |
| Divisions (1); Form division; Division 1; Idle; Moving; Attack-moving | Дивизии (1); Создать дивизию; Дивизия 1; Ожидает; Движется; Движется с атакой |
| Hold; Advance; Screen; Reinforce; Reinforces:; Rally point only | Стоять; Наступать; Прикрывать; Пополнять; Пополняет:; Только точка сбора |
| City ledger; City:; Good; Stock; Made/min; Used/min; Make; Short; Hint | Городской реестр; Город:; Товар; Запас; Выпуск/мин; Расход/мин; Цель; Нехватка; Подсказка |
| New target:; Set; needs [crude oil]: made nowhere | Новая цель:; Задать; нужно [нефть]: нигде не делают |
| Steel works; Steel from plates; Steel from ore | Сталелитейный комбинат; Сталь из пластин; Сталь из руды |
| Army surcharge +10 %: waiting for [copper] (Walker) | Армейская надбавка +10 %: ждёт [медь] (Шагоход) |
| Units from here: N · all barracks: M · army surcharge +10 % | Юнитов отсюда: N · из всех казарм: M · армейская надбавка +10 % |
| Walker kit; Hauler kit; Copper cable; Armoured car kit | Комплект шагохода; Комплект транспортёра; Медный провод; Комплект бронеавтомобиля |

## If an AI attack interrupts

The Normal AI attacks with about 8 to 11 units. On a 1536 world its base lies about 900 tiles away, so its first attack
reaches you several minutes after it starts. Its units lose health while they stand deep inside your land.

**Signs:**

- a red "Base under attack: …" line under the strip, with a sound;
- a red mark on the minimap;
- "Enemies seen" above 0;
- red spiders near your base, and lines in the kill feed.

Nothing has to happen fast: your 36 walkers fire by themselves. When you notice an attack:

1. Finish or abandon the current click. If a ghost is on the cursor, press Q. Close the ledger if it is open.
2. Press F3, or click the red alert line. The camera jumps to the attack.
3. Press Ctrl+A. It selects the combat units and the Commander (after step 31, the whole division).
4. Press F, then right-click on the enemies or on the ground next to them.
5. Wait until "Enemies seen" shows 0 again.
6. Press SPACE and redo the interrupted step from its start.

Note in the report the strip time, what was attacked and what you lost. If the attack wrecks the factory or a depot
before its part is done, see Recovery.

## Steps

### Part A: lobby and start

1. **The start dialog.**
   - *Input:* none. Wait until the window shows a dialog in the middle of a black screen.
   - *Expect:*
     - a dialog "Factorio RTS: new match" with five drop-downs: **Mode** "Skirmish" (≈601, 314), Opponents "1"
       (≈601, 341), Difficulty "Normal" (≈601, 368), Map size "Small (256×256)" (≈618, 395) and Map "Chokepoints"
       (≈601, 422);
     - a grey hint, and a green **Start match** button (≈739, 513);
     - the strip with "--:--", "Army 0", "Supply 0/0" and the message "Choose the match settings and press Start match.
       F11: how to play."; no age badge, no Land button, no city list.
   - *Pass/Fail:* PASS if the five drop-downs are there. If Mode already reads Nation (a dialog left from an earlier
     match), go on with step 3.
   - *Log check (lead):* `lobby: dialog shown to player 1 \(1 opponent\(s\), normal, [a-z]+, [a-z]+, skirmish\)`

2. **Mode: Nation.**
   - *Input:* hover Mode (≈601, 314) for 2 s and take a screenshot of the tooltip. Click Mode; a list opens below it.
     Click "Nation".
   - *Expect:*
     - The tooltip has two paragraphs: "Skirmish: the arena maps, 15 to 30 minutes." and "Nation: a generated world
       with mountain ranges, rivers, regions, ruins and ports; you and the AI found cities and connect them. …".
     - After the click, Mode reads "Nation", Map size reads "**World (1536×1536)**" (the drop-down gets a little wider,
       ≈620, 395), and Map reads "World" and is greyed out.
   - *Pass/Fail:* PASS if Map size shows World (1536×1536) and Map is a greyed "World".
   - *Log check (lead):* `lobby: player 1 set mode -> 1 opponent\(s\), normal, nation, world default`

3. **World size.**
   - *Input:* click Map size (≈620, 395) and take a screenshot of the open list. Click "World (1536×1536)". Then click
     Map (≈601, 422).
   - *Expect:* the list has three lines: World (1536×1536), World (2048×2048) and World (3072×3072). Map size reads
     World (1536×1536), the default for 2 nations. The greyed Map drop-down does not open.
   - *Pass/Fail:* PASS if there are three sizes and 1536 is selected.
   - *Log check (lead):* `lobby: player 1 set world_size -> 1 opponent\(s\), normal, nation, world default`

4. **Start the Nation match.**
   - *Input:* check that Opponents shows 1 and Difficulty Normal. Click **Start match**. Wait up to 10 s.
   - *Expect:*
     - **The base.** After a few seconds the dialog closes and the camera is on your capital: the CC at (640, 400) with
       4 stockpiles at (584, 376), (584, 424), (696, 376) and (696, 424); the Commander, a big blue spider-tank, right
       next to it; 6 walkers 14–18 tiles away on one side. The ground around the base is bare (no trees); ore patches
       lie nearby.
     - **Strip.** The timer counts from 00:00, with "Army 7", "Enemies seen: 0", "Supply 6/40", iron 400 and copper
       150. The buttons read Research [T], ?, **Land 1.2%** (≈803, 22) and Menu. The message reads "Destroy the enemy
       base and army."
     - **Age badge** left of the strip: a button "Age I" (≈302, 21) and under it "Research Industrialisation (advanced
       kits) to start the Railway Charter."
     - **City list** at the top left: "Cities  Land 1.2%" and one row: a "Capital" button (≈36, 127), "Town, N cells"
       (N about 440) and a magnifier (≈183, 127).
     - **Build menu** on its Economy tab, **two rows high** (y 678–794): extractor 2, smelter 2, stockpile 2, belt 60,
       inserter 16, pole 16 and the hub; in row 2 a greyed **Rail depot** (≈1066, 772). Tabs at y≈712: Economy,
       Production, Defence and a small blue icon tab (≈1216, 712).
     - Bottom left "No units selected"; bottom centre the ability bar.
   - *Pass/Fail:* PASS if the age badge, the Land button, the city list and the greyed depot in row 2 of the Economy
     tab are all there without any click. FAIL if the Economy tab has one row only (the Nation-only items were not
     refilled at the start).
   - *Log check (lead):*
     - `lobby click start player=1`
     - `match: starting match [0-9]+: 1 opponent\(s\), normal, nation, world 1536x1536, brain ai`
     - `cities: capital city [0-9]+ of rts-player at .* \(tier 2, radius 96\) \(CC\)`
     - `fog: match start on rts-arena-[0-9]+, charted rts-player [0-9]+ chunks`
     - `hud: built for player 1 .*build menu 8 items\)`
     - `lobby: match [0-9]+ started by player 1 .*: 1 opponent\(s\), normal, nation, world 1536x1536, brain ai`

### Part B: the capital and the Nation HUD

5. **Land button, age badge, city list.**
   - *Input:*
     1. Hover "Land 1.2%" on the strip for 2 s (screenshot the tooltip). Click it and take a screenshot. Click it again.
     2. Hover the age badge's "Age I" button for 2 s.
     3. Click the magnifier in the city list (≈183, 127). Take a screenshot. Click the × of the panel that opened
        (≈994, 198).
   - *Expect:*
     - The Land tooltip: "Share of the map your nation owns. Cities, forts, hubs and radars claim land. Economic
       buildings stand only on your own land; enemy units deep in your land suffer attrition." and "Click: show or hide
       the list of your cities."
     - The first click hides the city list; the second shows it again.
     - The badge tooltip: "Your nation's age and its national project. Click (or L) for the city ledger."
     - The magnifier opens the city panel "Capital: Town" (x 788–1013, from y 183); step 14 checks its lines. The ×
       closes it.
   - *Log check (lead):* `citygui: city list hidden player=1`, `citygui: city list shown player=1`,
     `citygui: city panel [0-9]+ \(pin:[0-9]+\) player=1`

6. **Borders, the minimap and fog.**
   - *Input:* press SPACE. With the mouse over the map centre, scroll the wheel down (towards you) 5 notches, one at a
     time. Take a screenshot. Look at the minimap. Then scroll up 5 notches.
   - *Expect:*
     - **Zoomed out** (≈5 px per tile): a dashed blue line about 480 px left and right of the screen centre (x≈160 and
       ≈1120), stepping in 8-tile cells: the border of your land, about 96 tiles from the CC. Above and below it runs
       beyond the screen edge.
     - **Minimap:** mostly black. A lit square (the charted start area, about 320 tiles across) holds a blue outline
       and a light blue tint (your land). Somewhere else on the black lies a red outline: the AI's land (borders are
       public).
     - After scrolling back, the CC's stockpiles are again 112 px apart.
   - *Pass/Fail:* PASS if the dashed border and the blue and red outlines on the minimap are seen. Report where on the
     minimap your outline and the red one are.
   - *Log check (lead):* `camera zoom player=1 0\.500 -> 0\.[0-4]`, `camera zoom player=1 0\.[0-9]+ -> 0\.500`

7. **QA shortcut: an army.**
   - *Input:* press SPACE. Open the console (F9), type `/rts-spawn rts-walker 30` and press Enter. Wait 3 s.
   - *Expect:* a chat line "rts-spawn: 30 x rts-walker for rts-player near (x, y)". 30 walkers appear in three rows of
     10 below the CC (feet at x≈424–928, y≈592–704). The strip reads "Army 37" and "Supply 36/40", the supply in
     yellow (90 % of the cap).
   - *Pass/Fail:* PASS if the 30 walkers stand there. If the reply says fewer, report the number.
   - *Log check (lead):* `rts-spawn: 30 x rts-walker for rts-player near`

### Part C: build menu and factory

8. **The build menu in Nation mode.**
   - *Input:*
     1. Hover the greyed Rail depot (≈1066, 772) for 2 s.
     2. Click **Production** (≈1131, 712). Hover City charter (≈1159, 740) and Fort (≈1190, 740) for 2 s each.
     3. Click **Defence** (≈1183, 712).
     4. Click the small icon tab (≈1216, 712). Hover the tab for 2 s and then its first button (≈1066, 740).
     5. Click **Economy** (≈1077, 712).
   - *Expect:*
     - **Depot tooltip:** "Rail depot", "In stock: 0. Factory recipe: … gives 1 in 10 s." and in red "Requires
       research: Railways (T)".
     - **Production:** five buttons: barracks 1, factory 1, lab, **City charter** and **Fort**, the last two without a
       number, all in row 1 (the menu keeps its two-row height, so the tabs stay at y≈712). City charter's tooltip: "City
       charter", "In stock: 0. Factory recipe: [3 icons] gives 1 in 20 s." and, last, "Builds a [icon] City Center."
       (QA round 1: before, the tooltip's title read "City Center"). Fort: "… gives 1 in 6 s."
     - **Defence:** 7 buttons; laser turret and steam plant greyed.
     - **Age II icon tab:** tooltip "Age II: oil well, refinery, chemical plant, the ten districts and the Bunker
       (Nation mode)". Two rows of 7 greyed buttons. The first button's
       tooltip ends in red "Requires research: Age II (Railway Charter) (T)".
     - **Economy** again: two rows with the depot.
   - *Pass/Fail:* PASS if City charter and Fort are in the Production tab on its first visit and the Age II tab shows
     14 greyed buttons.
   - *Log check (lead):*
     - `hud build tab production player=1: rts-barracks rts-factory rts-lab rts-city-charter rts-fort`
     - `hud build tab age2 player=1: rts-pumpjack rts-refinery rts-chemical-plant rts-district-smelting .* rts-bunker`
     - `hud build tab economy player=1: .* rts-hub rts-depot`

9. **Place the factory and the barracks.**
   - *Input:*
     1. Click **Production** (≈1131, 712).
     2. Click **Factory** (≈1097, 740), then left-click the map at (448, 304).
     3. Click **Barracks** (≈1066, 740), then left-click (832, 304).
     4. Press Q. Wait 15 s. Click **Economy** (≈1077, 712).
   - *Expect:* the message line reads in green "Placing Factory: left-click the map. R rotates. Q or right-click: done."
     Each click leaves a ghost, and the CC's robots build both within about 15 s. The counts on both buttons drop to 0.
   - *Log check (lead):* `build ghost rts-factory player=1 at`, `build ghost rts-barracks player=1 at`,
     `robot built rts-factory #[0-9]+`, `robot built rts-barracks #[0-9]+`

10. **The factory page: category tabs and Auto.**
    - *Input:*
      1. Click the factory (448, 304). Take a screenshot.
      2. Hover each of the five small icons in the panel's title line (≈92, 112, 132, 152 and 172; y≈714) for 2 s.
      3. Click the Logistics icon (≈112, 714) and take a screenshot. Click the Science icon (≈152, 714). Click the Age II
         icon (≈172, 714) and hover one of its greyed buttons. Click the Buildings icon (≈92, 714).
      4. Click empty ground.
    - *Expect:*
      - **Title line:** "Factory #N", five small icons (the first pressed), "HP 1000/1000" and Demolish (≈361, 714).
      - **Buildings tab:** row 1 (y≈737): Pause and **Auto** (≈53), both highlighted (no recipe, and in Nation mode a
        new factory starts on Auto), Hub, Rail depot (grey), **City charter** (≈131), Stockpile, Extractor, Smelter, Solar array, Factory, Lab,
        Steam plant (grey), Accumulator, Barracks; row 2 (y≈762): Turret, **Fort**, Laser turret (grey), Wall, Radar.
        The status line (y≈785) reads "Auto: Paused: pick a recipe." and "Crafted 0 · to network 0".
      - **Tooltips:** "Buildings", "Logistics: belts, inserters, poles, ammo, haulers, rails and train kits",
        "Intermediates: gears, cable, circuits, explosives, engines, advanced circuits, steel beams, concrete", "Science
        kits", "Age II buildings: oil well, refinery, chemical plant, districts, Bunker".
      - **Logistics:** one row: Pause, Auto, Rails (grey), Transport belts, Fast inserters, Medium electric poles,
        **Hauler kit** (≈183), Locomotive kit, Cargo wagon kit, Construction wagon kit (the three kits grey), Firearm
        magazines. The status line moves up to y≈759.
      - **Science:** basic kit, advanced kit, industrial kit (grey). **Age II:** 14 greyed buttons whose tooltips end
        "Requires research: Age II (Railway Charter) (T)".
    - *Pass/Fail:* PASS if the five icons switch the grid and the Buildings tab holds City charter and Fort.
    - *Log check (lead):*
      - `hud: recipe buttons factory#[0-9]+ player=1: pause rts-hub rts-depot rts-city-charter .*, tab buildings`
      - `hud factory tab logistics player=1`
      - `hud: recipe buttons factory#[0-9]+ player=1: pause rts-rail rts-belt rts-inserter rts-pole rts-hauler-kit .*, tab logistics`

### Part D: found a city

11. **Make a City charter.**
    - *Input:*
      1. Open the console, type `/rts-give stone 40`, press Enter. (Why: the charter needs 40 stone, and the start stock
         has none; a stone line takes minutes to set up.)
      2. Click the factory (448, 304). On the Buildings tab click **City charter** (≈131, 737).
      3. Wait about 25 s, until the status line reads "Crafted 1 · to network 1".
      4. Click **Auto** (≈53, 737). Click empty ground.
    - *Expect:*
      - The reply "rts-give: 40 x stone into the rts-player pool"; the strip's stone reads 40.
      - The City charter button turns yellow, and the status reads "[icon] City charter: running" with a progress bar.
        Iron drops by 80, copper by 30 and stone to 0.
      - After about 20 s: "Crafted 1 · to network 1", then the status turns yellow "… City charter: waiting for
        [stone]" (no stone left for a second one).
      - After Auto: Auto is highlighted again and the status reads "Auto: Paused: pick a recipe."
      - The charter is now in your stock: the build menu's Production tab shows 1 on City charter (seen in step 12).
    - *Log check (lead):*
      - `rts-give: 40 x stone into the rts-player pool`
      - `recipe set factory#[0-9]+ rts-city-charter ok=true now=rts-city-charter player=1`
      - `production: factory #[0-9]+ \(rts-player\) moved 1 rts-city-charter into the network`
      - `recipe auto factory#[0-9]+ on ok=true player=1`

12. **Place the City Center far out; the Commander builds it.**
    - *Input:*
      1. Click empty ground, so that nothing is selected, and press SPACE.
      2. Scroll down 5 notches.
      3. Click **Production** (≈1131, 712), then **City charter** (≈1159, 740).
      4. Left-click the map at ≈(87, 400) or ≈(1193, 400): about 110 tiles left or right of the CC and 15 tiles beyond
         the dashed border. Take the side away from the red AI outline on the minimap, on open ground (no water, no grey
         rock, no dense forest). Any spot at least 500 px from the screen centre works. Press Q.
      5. Click the Commander portrait (486, 753). Right-click bare ground about 20 px beside the ghost. Wait until the
         Commander stands there (10–15 s), then 10 s more.
      6. Scroll up 5 notches. Press SPACE.
    - *Expect:*
      - **Placing.** The message reads "Placing City charter: left-click the map. R rotates. Q or right-click: done." A
        small ghost (a 4×4 building with a stockpile on each side) stays where you clicked. If the game refuses it, a
        flying text says why, for example "Too close to another city: City Centers need 96 tiles between them"; then
        place it further out.
      - **Walk.** The panel reads "Commander ×1" and "Order: Commander"; the Commander walks there.
      - **Build.** A few seconds after it arrives, small robots fly out of it and build the City Center (a green-tinted
        roboport).
      - **Founded.** A green alert "City founded: Ironford"; a second row in the city list, "Ironford  Village, N
        cells" (N about 100–110); Land rises to about 1.5 %; the supply cap rises by 10 ("Supply 36/50"). Zoomed out,
        a second dashed outline about 48 tiles around the new city joins your land.
    - *Pass/Fail:* PASS if the alert and the second list row appear. FAIL if the ghost is still a ghost 30 s after the
      Commander arrived; then check that it stands within 15 tiles (75 px zoomed out) of the ghost and report.
    - *Log check (lead):*
      - `hud click build rts-city-charter player=1 in_network=1 ghost=true`
      - `build ghost rts-city-center player=1 at`
      - `order commander-move n=1 unit=#[0-9]+`
      - `commander: field supply for rts-player at .* stocked \[rts-city-charter x1\]`
      - `cities: new city [0-9]+ of rts-player at .* \(tier 1, radius 48\) \(City Center\)`
      - `territory: source city #[0-9]+ of rts-player at .* radius 48 tiles`

13. **The new city on the map.**
    - *Input:* click the second name button in the city list, "Ironford" (≈38, 146). Take a screenshot. Scroll down 5
      notches, take a screenshot, scroll up 5 notches.
    - *Expect:* the camera jumps to the new City Center at the screen centre (640, 400), with its two stockpiles at
      (584, 407) and (696, 407) and the Commander nearby. Zoomed out, a dashed outline about 240 px (48 tiles) around it,
      open towards the capital's land where the two meet.
    - *Log check (lead):* `camera jump player=1 ->`

### Part E: city panels

14. **The capital's city panel.**
    - *Input:*
      1. Press SPACE. Click the CC (640, 400). Take a screenshot.
      2. Hover the city panel's **Demolish** (≈978, 421) for 2 s, then click it once.
      3. Hover the building page's **Demolish** (≈361, 714) for 2 s and click it once. Then press Delete once.
    - *Expect:*
      - **Three panels:** the building page "Command Center #N", "HP 3000/3000" and Demolish; the city panel; the hub
        panel "Command Center: stockpile policy", "Network #K, 1 hub", with no Demolish button.
      - **City panel lines:** "Capital: Town" and ×; an empty name field with a pencil; "Tier: Town, land radius 96
        tiles (capital)"; "Nation age: 1"; "Land: N cells, M% of your nation" (M about 80); "Supply: 40"; "Next tier,
        City: buildings on its land B/25, goods delivered to its market 0/2000" (B about 2: the factory and the
        barracks); "Logistic networks on its land: 1 (#K)"; "Make targets"; a **+** button with "Factories without a fixed
        recipe make the largest shortfall."; and **Demolish**, greyed, at the bottom right.
      - The city panel's Demolish tooltip reads "The Command Center and the capital cannot be demolished."; the click
        does nothing.
      - The building page's Demolish is greyed too, with the same tooltip. The Delete key shows a flying text and a
        chat line "Command Center cannot be demolished."; nothing changes.
    - *Pass/Fail:* PASS if the lines read as above, both Demolish buttons are greyed and nothing is demolished.
    - *Log check (lead):* `citygui: city panel [0-9]+ \(sel:[0-9]+\) player=1`,
      `demolish: blocked player=1 cc #[0-9]+ \(protected\)`

15. **A make target.**
    - *Input:*
      1. With the CC still selected, click the **+** button under "Make targets" (≈812, 394). Take a screenshot.
      2. The mod's item picker "Pick a good to make" opens left of the city panel (x 461–781). Hover the 4th icon of
         its first row (≈574, 281) for 2 s: the tooltip reads "Iron gear wheel". Click it.
      3. The new row's number field (≈861, 391) has the keyboard focus: type 20 and press Enter. (If it lost the focus,
         click the field first: a click selects its text, so typing replaces it.)
      4. Click the factory (448, 304) and watch its status line for 10 s.
    - *Expect:*
      - **The picker:** title "Pick a good to make" with ×, the hint "Goods your factories and districts can make. Click
        one to make it a target of this city.", then "Can make now" (3 rows of icons: belts, inserters, poles, gears,
        cable, circuits, …, the buildings and kits) and "After research" (4 rows, greyed tooltips "Its recipe is not
        researched yet."). There is no RTS cursor icon, and your cursor still holds the RTS cursor. QA round 1: before,
        this button was a vanilla item chooser that put the RTS cursor in as the target.
      - The click closes the picker. A new row: the gear icon, a field with 20 and a ×; the hint and Demolish move down
        one row (Demolish ≈978, 453).
      - The factory, which had no recipe, starts on its own within 2 s: "Auto: [gear] Iron gear wheel: running", and
        "Crafted" rises. When the network holds 20 gears (after about 20 s) it reads "Auto: Paused: pick a recipe."
        again. Iron drops by 2 per gear.
    - *Pass/Fail:* PASS if the factory makes gears without a recipe click.
    - *Log check (lead):*
      - `itempicker: opened owner=citygui ctx=\{city = [0-9]+\} player=1`
      - `itempicker: pick iron-gear-wheel owner=citygui ok=true player=1`
      - `citygui add target city=[0-9]+ item=iron-gear-wheel player=1`
      - `citygui target city=[0-9]+ iron-gear-wheel=20 ok=true player=1`; no `rts-cursor` in any `cities: make target`
        line
      - `production: auto factory #[0-9]+ \(rts-player\) recipe .* -> rts-gear`

16. **The new city's panel; rename it.**
    - *Input:*
      1. Click "Ironford" in the city list (≈38, 146). Click the City Center (640, 400). Take a screenshot.
      2. Hover the city panel's **Demolish** (≈978, 421) for 2 s. Do not click it.
      3. Click the name field (≈886, 221), type `Outpost` and press Enter.
      4. Click empty ground, then the City Center again.
    - *Expect:*
      - **Building page:** "City Center #N", "HP 1800/1800", "Status: Working", "Supply +10. Own power and robots; own
        network unless its area touches the Command Center's or another hub's." and "Set what it keeps and exports in
        the panel on the right."
      - **City panel** "Ironford: Village": "Tier: Village, land radius 48 tiles"; "Nation age: 1"; "Land: N cells, M% of
        your nation" (M about 20); "Supply: 10"; "Next tier, Town: buildings on its land 0/10, goods delivered to its
        market 0/400"; "Logistic networks on its land: 1 (#K)"; no make targets; Demolish enabled. Its tooltip: "Demolish
        the selected building (Delete or Backspace). The first press arms, a second press within 3 seconds demolishes. 50
        % of the cost is refunded to the nearest stockpile of its logistic network; …"
      - **Hub panel** "Ironford: stockpile policy", "Network #K, 1 hub", a Demolish button (≈1053, 289), Keep 50 for iron
        and 20 for copper.
      - After Enter: the panel title reads "Outpost: Village" and the list row "Outpost". After you select it again the
        hub panel reads "Outpost: stockpile policy".
    - *Log check (lead):* `citygui click rename city=[0-9]+ name=Outpost player=1`,
      `cities: city [0-9]+ of rts-player renamed to Outpost`

### Part F: hauler fuel

17. **A hauler.**
    - *Input:*
      1. Press SPACE. Open the console, type `/rts-give electronic-circuit 10`, press Enter.
      2. Click the factory (448, 304), then the Logistics icon (≈112, 714), then **Hauler kit** (≈183, 737).
      3. Wait until a small blue spider appears right of the factory and the status turns yellow "waiting for
         [circuit]" (about 15 s). Click **Auto** (≈53, 737).
      4. Wait 10 s.
    - *Expect:* the reply "rts-give: 10 x electronic-circuit into the rts-player pool". The hauler appears about 6
      tiles right of the factory; "Army" rises by 1 and "Supply" does not. Within a few seconds it walks to the CC and
      stops just below it (≈640, 456).
    - *Log check (lead):* `recipe set factory#[0-9]+ rts-hauler-kit ok=true`,
      `logistics: factory #[0-9]+ \(rts-player\) deployed hauler #[0-9]+, home hub #[0-9]+`

18. **No coal: the hauler waits.**
    - *Input:*
      1. Click the hauler (just below the CC). Take a screenshot.
      2. Click "Outpost" in the city list (≈38, 146), then right-click the City Center (640, 400).
      3. Click "Capital" (≈36, 127), then hold Shift and right-click the CC (640, 400).
      4. Watch the hauler panel for 5 s.
    - *Expect:*
      - **First:** the hauler panel "Hauler #N" with **Auto** pressed and **Route**, "HP 400/400", "Home: Command
        Center", "State: Waiting, nothing to carry" (yellow), "Cargo: empty", "Trips: 0. Delivered: -", **Return home**,
        **Resume** (greyed), and the hint.
      - **After the right click:** a blue circle on the City Center; Route is pressed.
      - **After the Shift + right click:** a green circle on the CC; "Route: Outpost → Command Center"; "**State: Waiting,
        no coal for the trip in the hub network**" in yellow; a yellow alert line with a coal icon "**Hauler N: no fuel
        at Command Center**". The hauler does not move.
    - *Pass/Fail:* PASS if the no-coal state and the alert appear.
    - *Log check (lead):*
      - `order route-pickup n=1 hub=#[0-9]+ \(hub\) player=1`
      - `order route-dropoff n=1 hub=#[0-9]+ \(cc\) player=1`
      - `logistics: hauler #[0-9]+ \(rts-player, manual\) waiting \(no-fuel\)`
      - `logistics: alert hauler-no-fuel for rts-player`

19. **Coal: the hauler leaves with a tank.**
    - *Input:* open the console, type `/rts-give coal 200`, press Enter. Watch the hauler panel (the hauler stays
      selected) for 20 s.
    - *Expect:* within 2 s the state reads "State: To pickup: Outpost (N tiles)" in white, and the cargo line "Cargo:
      empty   **Tank: [coal] M**". M is the coal for the way back, 1 per 40 tiles of the trip (×1.1, rounded up): about 4
      for a city 110 tiles away. The hauler walks off towards Outpost.
    - *Log check (lead):* `rts-give: 200 x coal into the rts-player pool`,
      `logistics: hauler #[0-9]+ \(rts-player, manual\) to_pickup`

20. **At the far end, the tank pays the way back.**
    - *Input:* wait until the state reads "Waiting, nothing to carry" (about 10 s after it left). Take a screenshot.
      Click **Return home** (≈1062, 314). Watch 5 s, take a screenshot. Wait until the hauler is back below the CC.
      Click empty ground.
    - *Expect:*
      - At Outpost: "State: Waiting, nothing to carry" and "Tank: [coal] M", unchanged. Outpost exports nothing and holds
        no coal.
      - After Return home: **Auto** is pressed, "Home: Command Center", "State: Going home: Command Center (N tiles)",
        and the tank drops to "Tank: [coal] 0" (or a smaller number): the trip home is paid from the tank, so the
        hauler leaves although Outpost has no coal.
      - Back home: "Waiting, nothing to carry".
    - *Pass/Fail:* PASS if the hauler leaves Outpost and the tank drops.
    - *Log check (lead):* `hubgui click return_home haulers=1 player=1`,
      `logistics: hauler #[0-9]+ returns home to hub #[0-9]+`, `logistics: hauler #[0-9]+ \(rts-player, auto\) to_home`

### Part G: rails

21. **Railways and the rail stock.**
    - *Input:* open the console once per line and type, each followed by Enter:
      `/rts-research rts-railways`, `/rts-give rts-depot 2`, `/rts-give rts-locomotive-kit 4`,
      `/rts-give rts-cargo-wagon-kit 2`, `/rts-give rts-construction-wagon-kit 1`, `/rts-give rail 400`,
      `/rts-give iron-plate 300`. Then click **Economy** in the build menu (≈1077, 712).
    - *Why:* Railways needs 15 basic science kits from labs, and depots, kits and rails need a steel chain.
    - *Expect:* a green alert "Research complete: Railways" and the chat lines "rts-research: rts-railways researched
      for rts-player" and six "rts-give: …" replies. In the Economy tab the Rail depot (≈1066, 772) is no longer greyed
      and shows 2. Iron rises by 300.
    - *Log check (lead):* `rts-research: rts-railways researched for rts-player`,
      `research: rts-player finished rts-railways \(by script\)`, `rts-give: 4 x rts-locomotive-kit`,
      `rts-give: 400 x rail into the rts-player pool`

22. **Depot 1 next to the capital.**
    - *Input:* press SPACE. In the Economy tab click **Rail depot** (≈1066, 772) and left-click (288, 400), 22 tiles
      left of the CC (any bare ground 18–30 tiles from the CC, away from your buildings, works). Press Q. Wait 15 s.
      Click the new depot. Take a screenshot.
    - *Expect:*
      - The CC's robots build a blue-tinted roboport. Next to it, usually 8 tiles below, a straight 40-tile track with a
        train stop at each end appears: the platform.
      - **Building page:** "Rail depot #N", "Status: Working", and the hub lines.
      - **Rail panel** (x 765–1012): "Rails: Depot 1"; "Platform: 40 tiles, 2 stops"; "Kits: locomotive 4, wagon 2,
        construction 1 | rails 400, coal C" (C about 190); "No line. Select this depot and right-click another depot to
        lay one."; **Deploy freight train** (≈821, 307); "Right-click another depot to lay a rail line to it. A
        construction train (2 locomotive kits + 1 construction wagon kit and rails in this network) builds it."; "Rail
        lines" and "No rail lines yet".
      - **Hub panel:** "Depot 1: stockpile policy", "Network #K, 2 hubs" (it joined the CC's network), Demolish, and Keep
        50 for coal.
    - *Pass/Fail:* PASS if the platform stands and both panels read as above. If the alert "Rail depot: no room for a
      platform" appears, see Recovery.
    - *Log check (lead):* `build ghost rts-depot player=1 at`,
      `rails: depot #[0-9]+ \(.*\) of rts-player at .*: platform .*, 20 rails, 2 stops`,
      `railgui: depot panel for [0-9]+ player=1`

23. **Depot 2 at Outpost; the Commander builds it.**
    - *Input:* click empty ground. Click "Outpost" (≈38, 146). In the Economy tab click **Rail depot** (≈1066, 772) and
      left-click (832, 432), 12 tiles right of the City Center. Press Q. Click the Commander portrait (486, 753) and
      right-click bare ground just above the ghost, ≈(832, 360). Wait until the Commander stands there, then 10 s more.
      Click the new depot.
    - *Expect:* the Commander's robots build it, with its platform. Rail panel "Rails: Depot 2", "Platform: 40 tiles, 2
      stops", "Kits: locomotive 0, wagon 0, construction 0 | rails 0, coal 0", "No line. …". Hub panel "Depot 2:
      stockpile policy", "Network #K, 2 hubs": it shares Outpost's network.
    - *Pass/Fail:* PASS if it stands with a platform and reads "2 hubs". If it reads "1 hub", report it (the train
      delivers to the depot either way, but step 47's refund then has nowhere to go).
    - *Log check (lead):* `commander: field supply for rts-player at .* stocked \[rts-depot x1\]`,
      `rails: depot #[0-9]+ \(.*\) of rts-player at .*: platform`

24. **Lay the line.**
    - *Input:*
      1. Click empty ground. Click "Capital" (≈36, 127). Click Depot 1 (288, 400).
      2. Click "Outpost" (≈38, 146), then right-click Depot 2 (832, 432).
      3. Click "Capital". Watch Depot 1's rail panel and its platform for 30 s, with a screenshot every 10 s.
    - *Expect:*
      - The line caption of the rail panel (y≈269) reads "Depot 1 → Depot 2: surveying, …" in yellow (perhaps only for a
        second), then "**Depot 1 → Depot 2: building, N tiles, M rails**" in yellow, with "P pieces, Q missing, 0
        supports, S signals" under it. The "Rail lines" list repeats it.
      - The planned track appears as light-blue ghost rails from the platform towards Outpost.
      - A **construction train**, two locomotives with an orange wagon between them, appears on Depot 1's platform and
        drives along the ghosts, turning them into track. The kits line drops to "locomotive 2, wagon 2, construction 0".
    - *Pass/Fail:* PASS if the line reaches "building" and the construction train lays track. FAIL if the chat says
      "Cannot lay a rail line: …" (report the reason), or if the detail line ends with a reason such as "no train kits in
      the depot network" for more than 30 s.
    - *Log check (lead):*
      - `order lay-rail depot=#[0-9]+ -> #[0-9]+ line=[0-9]+ \(nil\) player=1`
      - `rails: line #[0-9]+ of rts-player: survey`
      - `rails: survey #[0-9]+ done in`
      - `rails: line #[0-9]+: construction train [0-9]+ from depot #[0-9]+`

25. **The line opens.**
    - *Input:* keep Depot 1 selected and wait up to 60 s. Optional: click a carriage of the construction train while it
      works, read its panel, then click Depot 1 again. Then scroll down 5 notches, take a screenshot and scroll back.
    - *Expect:*
      - A green alert "**Rail line open**". The rail panel: "Depot 1 → Depot 2: **open**, N tiles, M rails" in green and
        "P pieces, 0 missing, 0 supports, S signals".
      - Optional panel: "Construction train N", "Home depot: Depot 1", "Pieces laid: X, still missing: Y".
      - Zoomed out: a track from Depot 1's platform to Outpost. The construction train parks at Depot 2 and disappears
        (it turns back into kits there).
    - *Log check (lead):* `rails: line #[0-9]+ of rts-player open: [0-9]+ pieces`, `logistics: alert line-open for rts-player`

26. **A freight train; the train panel.**
    - *Input:* with Depot 1 selected, click **Deploy freight train** (≈821, 307). Click one of the new train's
      carriages on the platform. Take a screenshot.
    - *Expect:*
      - A blue train appears on Depot 1's platform: locomotive, two cargo wagons, locomotive. The kits line reads
        "locomotive 0, wagon 0".
      - The click selects the train: building page "Locomotive #N" (or "Cargo wagon #N"), "HP 1000/1000" (a wagon
        600/600), "Status: …", and **no Demolish button**.
      - **Train panel** (x 1026–1273): "Freight train N", "HP 1000/1000, coal 20", "No route: right-click a depot
        (pickup), Shift + right-click a depot (drop-off)", "idle (no route)", "Cargo: empty", "Trips: 0, delivered: -",
        "Depot 1 → Depot 2: open, N tiles, M rails", Resume (greyed) and "Right-click a depot: pickup. Shift + right-click
        a depot: drop-off."
    - *Pass/Fail:* PASS if the train and its panel appear. If the chat says "Cannot deploy a train: out of coal", type
      `/rts-give coal 50`, click again and report it.
    - *Log check (lead):*
      - `railgui click deploy depot=#[0-9]+ train=[0-9]+ \(nil\) player=1`
      - `rails: depot #[0-9]+ \(rts-player\) deployed cargo train [0-9]+: 4 carriages`
      - `select building train unit=[0-9]+ player=1`
      - `railgui: train panel for [0-9]+ player=1`

27. **The drop-off's Keep.**
    - *Input:* click "Outpost" (≈38, 146), then Depot 2 (832, 432). In the hub panel on the right click the **Keep**
      field of the iron row (≈1146, 336), type 200 and press Enter. Take a screenshot.
    - *Expect:* the iron row reads Keep 200 with "In network" 0 in yellow (below Keep). The train will carry what the
      pickup exports (the CC: iron, copper and steel above 100) and the drop-off keeps (now 200 iron; 20 copper from the
      City Center).
    - *Log check (lead):* `hubgui policy hub=#[0-9]+ iron-plate keep=200 ok=true player=1`

28. **Route by right-click; cargo arrives.**
    - *Input:*
      1. Click "Capital" (≈36, 127). Click a carriage of the freight train on Depot 1's platform.
      2. Right-click Depot 1 (288, 400).
      3. Click "Outpost", then hold Shift and right-click Depot 2 (832, 432).
      4. Watch the train panel for 60 s. Then click Depot 2 and read its hub panel; click the City Center and read its
         city panel.
    - *Expect:*
      - A blue circle flashes on Depot 1 and a green one on Depot 2. The panel reads "Route: Depot 1 → Depot 2".
      - The state goes "to the pickup", "loading", "to the drop-off", "unloading"; the train runs at about 30 tiles/s.
      - While it travels: "Cargo: [copper] 20 [iron] N" with N up to 200. Afterwards "**Trips: 1, delivered: [copper] 20
        [iron] N**", and "waiting: nothing to carry" in yellow back at Depot 1.
      - Depot 2's hub panel: iron "In network" about N, copper 20. Outpost's city panel: "goods delivered to its market
        D/400" with D above 0.
    - *Pass/Fail:* PASS if Trips reaches 1 with iron delivered.
    - *Log check (lead):*
      - `order train-pickup train=[0-9]+ depot=#[0-9]+ ok=true player=1`
      - `order train-dropoff train=[0-9]+ depot=#[0-9]+ ok=true player=1`
      - `rails: train [0-9]+ \(rts-player\) route depot #[0-9]+ -> depot #[0-9]+`
      - `rails: train [0-9]+ delivered [0-9]+ items to depot #[0-9]+ \(trip 1,`

### Part H: rolling stock

29. **No Demolish for a train.**
    - *Input:* click "Capital". Click a locomotive of the freight train (on Depot 1's platform; if it is on the line,
      follow the track). Look at the building page's title line. Press Delete. Press Backspace. Click a cargo wagon and
      press Delete.
    - *Expect:* the title line reads "Locomotive #N" and "HP 1000/1000" with no Demolish button. Delete and Backspace
      each show a flying text and a chat line "**Locomotive cannot be demolished.**"; for the wagon "Cargo wagon cannot be
      demolished." Nothing is removed, and the train keeps its route.
    - *Log check (lead):* `demolish: blocked player=1 train #[0-9]+ \(rolling-stock\)`

30. **No factory tabs on other pages.**
    - *Input:* click a locomotive of the freight train and look at the building page's title line. Click Depot 1 (288,
      400) and look again. Click empty ground.
    - *Expect:* the title lines read only "Locomotive #N  HP 1000/1000" and "Rail depot #N  HP 1500/1500  Demolish":
      no small icons between the name and the HP. The five category icons belong to the factory page only.
    - *Pass/Fail:* PASS if no icons show. FAIL if the five factory icons (x≈92–172, y≈714) appear on these pages (the
      icons stayed from the last factory page on every page without recipes before the integration fix of
      2026-10-16). Do not click them.

### Part I: divisions

31. **Form a division.**
    - *Input:* click empty ground and press SPACE. Press Ctrl+A. Click the walker card (≈47, 736). Take a screenshot.
      Click **Form division** (≈187, 186).
    - *Expect:*
      - Ctrl+A: "37 units selected" (36 walkers and the Commander). The card click: "Walker ×36".
      - The division panel at the top left, under the city list: "Divisions (0)" and an enabled **Form division**.
      - After the click: "Divisions (1)" and a card: a pressed "Division 1" button and "36/36", a green bar, "Idle" left
        and "Hold" right, the stance buttons **Hold** (pressed, ≈50, 253), **Advance** (≈116, 253) and **Screen** (≈184,
        253), a ticked "Reinforce" checkbox (≈22, 274), a pencil (≈183, 274) and a bin (≈208, 274).
    - *Log check (lead):* `select all n=[0-9]+ player=1`,
      `divisions: created #[0-9]+ Division [0-9]+ \(rts-player, player\) with [0-9]+ units \[rts-walker=[0-9]+\] stance hold`,
      `divisiongui: player 1 formed division`

32. **Stances.**
    - *Input:* hover **Advance** for 2 s. Click **Advance**, then **Screen**, then **Hold**.
    - *Expect:* the tooltip "Stance Advance: when idle, the division attacks enemies that come within 40 tiles." Each
      click presses that button, and the card's right-hand word follows: "Advance", "Screen", "Hold".
    - *Log check (lead):* `divisions: #[0-9]+ Division [0-9]+ stance -> advance`, `… stance -> screen`,
      `… stance -> hold`

33. **Move and attack-move.**
    - *Input:* right-click bare ground at ≈(1050, 450). Watch 10 s. Press F, then right-click ≈(1050, 250). Watch 10 s.
    - *Expect:* one green circle, and the 36 walkers set off together; the card reads "Moving", then "Idle" when they
      stand in formation around the point. After F the message line reads "Attack-move armed: …"; the right click shows
      an amber circle, and the card reads "Attack-moving" while the walkers walk to the second point (also when it lies
      close to the formation: QA round 1 fixed a division that stood still), then "Idle" when they stand in formation
      around it.
    - *Pass/Fail:* PASS if the whole division follows each order and ends around each point (the lead checks that each
      was one group order).
    - *Log check (lead):*
      - `order move n=[0-9]+ .*divisions=[0-9]+ player=1`
      - `divisions: #[0-9]+ Division [0-9]+ order move -> .* n=[0-9]+ group #[0-9]+`
      - `divisions: #[0-9]+ Division [0-9]+ order attack_move -> .* group #[0-9]+`
      - `divisions: #[0-9]+ Division [0-9]+ arrived \(attack_move .*, in formation\) after [0-9.]+ s at` a position
        within a few tiles of the attack-move's point

34. **One click selects the whole division.**
    - *Input:* click empty ground ≈(200, 200). Then left-click one walker of the division (near (1050, 250)).
    - *Expect:* the empty click: "No units selected". The walker click: "Walker ×36" with every walker boxed, and the
      card's "Division 1" button pressed.
    - *Log check (lead):* `select mode=replace click n=[0-9]+ .* divisions=1`

35. **Barracks: Reinforces.**
    - *Input:* click empty ground. Click the barracks (832, 304). Click the "Reinforces:" drop-down in the division
      panel (≈120, 209) and pick "Division 1". Click empty ground.
    - *Expect:* with the barracks selected the division panel shows "Reinforces: [Rally point only ▾]" above the card
      (tooltip: "New units from this barracks join the chosen division while it accepts reinforcements and is below its
      strength target; otherwise they go to the rally point."). After the pick it reads "Division 1". The division is
      full (36/36), so new units would still go to the rally point.
    - *Log check (lead):* `divisions: barracks #[0-9]+ \(rts-player\) reinforces division #[0-9]+ Division [0-9]+`

### Part J: Age II

36. **Industrialisation.**
    - *Input:* open the console, type `/rts-research rts-industrialisation`, press Enter. (Why: it needs 20 advanced
      kits.)
    - *Expect:* a green alert "Research complete: Industrialisation"; the age badge's text changes to "Industrialisation
      is done: start the Railway Charter."
    - *Log check (lead):* `rts-research: rts-industrialisation researched for rts-player`,
      `research: rts-player finished rts-industrialisation \(by script\)`

37. **The city ledger; start the Railway Charter.**
    - *Input:* press L. Take a screenshot. Press L again. Click the age badge's "Age I" button (≈302, 21). Click **Start
      the Railway Charter** (≈686, 314). Take a screenshot.
    - *Expect:*
      - **L** opens "City ledger" in the middle of the screen; L again closes it; the badge click opens it again.
      - **Top block:** "City: [Capital ▾]" and "Age I: Settlement"; "Industrialisation is done: start the Railway
        Charter." with an enabled **Start the Railway Charter** button; the goods line "[circuit] 100 [gear] 100 [steel]
        100 [stone] 150".
      - **Table:** "Good, Stock, Made/min, Used/min, Make, Short, Hint", with rows such as Iron plate, Copper plate, Coal
        and Iron gear wheel (its Make field shows 20, the target of step 15); under it "New target:", an empty item
        button, a field "50" and **Set**.
      - **Footer:** "Factories and districts on Auto (1) make the good with the largest shortfall that their inputs
        allow; fixed ones (0) keep the recipe you chose. Toggle with the Auto button in a building's panel."
      - **After Start:** a yellow alert "Railway Charter started next to the capital"; the Start button disappears and
        the project line "Railway Charter: 0 % delivered from the capital's network." gets a progress bar; the goods line
        turns into "[circuit] 0/100 [gear] N/100 [steel] 0/100 [stone] 0/150"; the badge shows the same text. Nothing in
        the top block is cut off at its right edge.
    - *Log check (lead):* `ledger: opened by player 1 \(rts-player\), city [0-9]+`,
      `ledger: player 1 start project: building`,
      `ages: rts-player started railway-charter at .* \(in a logistic network, delivered so far 0%\)`

38. **Deliveries to the site.**
    - *Input:* open the console once per line: `/rts-give steel-plate 100`, `/rts-give electronic-circuit 115`,
      `/rts-give iron-gear-wheel 100`, `/rts-give stone 190`. Close the ledger (× at ≈907, 259, or L). Press SPACE and
      find the site: a 6×6 grey ring-shaped building 12–20 tiles from the CC. Take a screenshot. Watch the badge for
      20 s.
    - *Why:* an Age I economy needs 15–20 minutes to gather these goods. The extra 15 circuits and 40 stone are for
      step 40.
    - *Expect:* a label "**Railway Charter N %**" with a yellow progress bar above the site; N rises every second (the
      site takes up to 10 of each good per second from the capital's network). The badge reads "Railway Charter: N %
      delivered from the capital's network."
    - *Log check (lead):* `rts-give: 100 x steel-plate into the rts-player pool`,
      `ages: rts-player railway-charter: everything delivered at tick [0-9]+, 20 s to Age II`

39. **Age II.**
    - *Input:* watch the site and the badge for 25 s.
    - *Expect:* the label reads "Railway Charter: Age II in N s" with a full green bar, counting down from 20; the badge
      "Railway Charter complete: Age II in N s." Then an alert and a chat line "**A new age for your nation: Age II:
      Industry**"; the badge button reads "**Age II**" with "Age II: the Mk2 line for every unit, the Armoured car, the
      Bunker, oil, plastics, engines and districts."; the label over the site disappears.
    - *Log check (lead):* `ages: rts-player age 1 -> 2 \(railway-charter\) at [0-9]+:[0-9]+ match time`

### Part K: Age II content and the ledger

40. **The factory makes a district.**
    - *Input:* click the factory (448, 304), then the Age II icon (≈172, 714). Take a screenshot. Click **Steel works**
      (row 1, index 6, ≈183, 737). Wait until "Crafted 1" (about 15 s). Click **Auto** (≈53, 737). Click empty ground.
    - *Expect:* the 14 Age II buttons are no longer greyed. "[icon] Steel works: running", then "Crafted 1 · to network
      1", then the status turns yellow "waiting for [circuit] [stone]" (the goods for one district are used up). After
      Auto: "Auto: Paused: pick a recipe."
    - *Log check (lead):* `recipe set factory#[0-9]+ rts-district-steel ok=true now=rts-district-steel player=1`,
      `production: factory #[0-9]+ \(rts-player\) moved 1 rts-district-steel into the network`

41. **The Age II build tab; place the district.**
    - *Input:* in the build menu click the Age II icon tab (≈1216, 712). Click **Steel works** (row 1, 5th button,
      ≈1190, 740; it shows 1). Left-click (640, 208), 12 tiles above the CC (any bare ground within 15 tiles of the CC,
      not on the Charter site). Press Q. Wait 15 s.
    - *Expect:* the tab shows its 14 buttons in two rows, no longer greyed, Steel works with 1. A 5×5 ghost; the CC's
      robots build an orange furnace-like building.
    - *Log check (lead):* `hud build tab age2 player=1`, `build ghost rts-district-steel player=1 at`,
      `robot built rts-district-steel #[0-9]+`

42. **The district page and Auto.**
    - *Input:* click the steel works. Take a screenshot. Click **Auto** (≈53, 737). Take a screenshot. Click **Pause**
      (≈27, 737). Click empty ground.
    - *Expect:*
      - "Steel works #N", "HP 2500/2500" and Demolish; no category icons. One row of buttons: Pause, **Auto**
        (highlighted), Steel from plates (≈79), Steel from ore (≈105). The status line (y≈759) reads "**Auto: [steel]
        Steel from plates: running**" (a district without a target runs the first recipe it can feed).
      - After Auto: Auto is no longer highlighted; "[steel] Steel from plates: running" (a fixed recipe).
      - After Pause: "Paused: pick a recipe."
    - *Log check (lead):*
      - `hud: recipe buttons district#[0-9]+ player=1: pause rts-dst-steel rts-dst-steel-ore`
      - `production: auto district #[0-9]+ \(rts-player\) recipe .* -> rts-dst-steel`
      - `recipe auto district#[0-9]+ off ok=true player=1`

43. **The ledger: rows, a target, a hint.**
    - *Input:*
      1. Press L. Take a screenshot.
      2. Click the empty item button after "New target:". The item picker "Pick a good to make" opens over the middle of
         the ledger. Hover the last (10th) icon of its first row (≈773, 334) for 2 s: the tooltip reads "Plastic bar"
         (if not, find the white bar by its tooltip). Click it. The picker closes, the item button shows the plastic
         bar, and the number field next to it has the focus with its text selected: type 10 (if it lost the focus,
         click it once: a click selects its text). Click **Set**. Wait 2 s. If the Plastic bar row is not in view,
         scroll down over the table. Take a screenshot.
      3. Pick "Outpost" in the City drop-down (top left of the ledger), take a screenshot, pick "Capital" again. Press
         L.
    - *Expect:*
      - "Age II: Industry" at the top; the project line "Age II: the Mk2 line for every unit, …"; no Start button and no
        bar.
      - The picker lists no RTS cursor; your cursor still holds the RTS cursor (QA round 1: before, the item button was a
        vanilla chooser that put the RTS cursor in as the target, and typing into the field gave "5010").
      - A row "Plastic bar" with Make 10, Short 10 in red and the Hint "**needs [crude oil]: made nowhere**".
      - Outpost's rows: its stock (iron about 200, copper 20) and no targets.
      - The footer counts the factory on Auto and the steel works as fixed: "on Auto (1) … fixed ones (1)".
    - *Pass/Fail:* PASS if the target row and a "needs …" hint appear. Report the hint's item if it is not crude oil.
    - *Log check (lead):* `itempicker: pick plastic-bar owner=ledger ok=true player=1`,
      `ledger: player 1 picked plastic-bar for city [0-9]+`, `ledger: player 1 target [0-9]+ plastic-bar = 10`

### Part L: the army surcharge

44. **Drain the copper.**
    - *Input:* click the factory (448, 304), then the Intermediates icon (≈132, 714), then **Copper cable** (≈105,
      737). Watch the strip's copper until it reads 0 (at most a minute). Click **Pause** (≈27, 737).
    - *Expect:* "[cable] Copper cable: running"; copper drops by about 2 per second to 0; then the status turns yellow
      "waiting for [copper]". Pause stops it.
    - *Log check (lead):* `recipe set factory#[0-9]+ rts-cable ok=true`, `recipe set factory#[0-9]+ none ok=true`

45. **The surcharge on the barracks.**
    - *Input:*
      1. Check the strip: "Army" must be 32 or more (36 walkers, the Commander and the hauler make 38). If it is lower,
         type `/rts-spawn rts-walker 10` first.
      2. Click the barracks (832, 304), then **Walker kit** (≈53, 737). It waits for copper: "Walker kit: waiting for
         [copper]" in yellow.
      3. Type `/rts-give copper-plate 2`. Wait 5 s and take a screenshot. Hover the red line for 2 s.
      4. Hover the Armoured car kit (row 2, ≈27, 762) for 2 s.
      5. Type `/rts-give copper-plate 50`. Wait 10 s. Click **Pause** (≈27, 737).
    - *Expect:*
      - With 2 copper the barracks makes one kit and then holds it: the second text line turns red "**Army surcharge
        +10 %: waiting for [copper] (Walker)**" (+20 % once the army counts 40 or more). Its tooltip: "Every 10 units
        beyond 20 make Age I kits 10 % dearer (now +10 %): the barracks takes the extra plates from its network before
        Walker deploys. Age II units (Armoured car) pay none."
      - The Armoured car kit is no longer greyed; its tooltip lists 2 engines, 2 steel beams and 10 iron.
      - With 50 copper the walker deploys, and the line turns yellow: "Units from here: N · all barracks: M · army
        surcharge +10 %" (tooltip: the rule and the current share). Each walker then takes 1 more iron and 1 more copper
        than the kit.
    - *Pass/Fail:* PASS if the red surcharge line appears. If "Supply cap N/M: Walker waits" appears instead, report it.
    - *Log check (lead):* `rts-give: 2 x copper-plate`,
      `production: barracks #[0-9]+ \(rts-player\) holds rts-walker-kit: army surcharge x1\.[0-9], network short of 1 copper-plate`,
      `production: barracks #[0-9]+ \(rts-player\) spawned rts-walker`

### Part M: demolish

46. **Demolish the barracks with the keyboard.**
    - *Input:* the barracks stays selected. Note iron and copper on the strip. Press Delete once and take a screenshot.
      Wait 4 s and take a screenshot. Then press Delete, and within 3 s press Delete again.
    - *Expect:*
      - First press: a flying text and a chat line "Demolish 1 building(s)? Press again within 3 seconds."; the page's
        Demolish turns red and reads "Press again".
      - After 4 s it is grey "Demolish" again (disarmed).
      - The second pair: the barracks disappears; an alert "**Demolished [icon] Barracks**"; the panel reads "No units
        selected"; iron rises by at least 30 and copper by at least 10 (50 % of 60 iron and 20 copper, plus what the
        barracks held).
    - *Log check (lead):*
      - `demolish: armed player=1 buildings=1`
      - `buildings: demolished rts-barracks #[0-9]+ \(barracks\) of rts-player at .*: refund \[10 copper-plate, 30 iron-plate\]`
      - `demolish: done player=1 buildings=1 refund \[10 copper-plate, 30 iron-plate\]`

47. **Demolish Outpost's City Center from the city panel.**
    - *Input:*
      1. Click "Outpost" (≈38, 146). Click Depot 2 (832, 432) and note its stone and iron "In network".
      2. Click the City Center (640, 400). Click the city panel's **Demolish** (≈978, 421) once. Take a screenshot.
      3. Within 3 s click the same button again.
      4. Click Depot 2 again. Scroll down 5 notches, take a screenshot, scroll back.
    - *Expect:*
      - After the first click, the city panel's button, the hub panel's and the building page's all turn red "Press
        again", with the chat line.
      - The second click removes the City Center and its two stockpiles; the panels close. Alerts: "**City lost:
        Outpost**" (red), "Demolished [icon] City Center" and "Territory lost near Capital (N cells)" (yellow). The city
        list has one row; Land drops back to about 1.2 %; the supply cap drops by 10.
      - Depot 2's hub panel: "Network #K, 1 hub"; stone up by 20 and iron up by about 40 (50 % of the charter's 80 iron,
        30 copper and 40 stone), plus what the City Center's stockpiles held.
      - Zoomed out: Outpost's border is gone; Depot 2 and the track remain.
    - *Pass/Fail:* PASS if the city is gone with the alerts and the refund shows in Depot 2.
    - *Log check (lead):*
      - `citygui click demolish city=[0-9]+ result=armed player=1`
      - `citygui click demolish city=[0-9]+ result=done player=1`
      - `cities: city [0-9]+ of rts-player at .* lost`
      - `buildings: demolished rts-city-center #[0-9]+ \(hub\) of rts-player at .*: refund \[15 copper-plate, 20 stone, 40 iron-plate\]`

### Part N: end

48. **End the session.**
    - *Input:* open the console (F9, or Fn + F9, or the backtick key), type `RTS_QA_END` (no slash) and press Enter. If
      the window does not close within 10 s, press Ctrl+Shift+E (or Cmd+Shift+E).
    - *Expect:* the typed line appears in the chat, and a few seconds later the game window closes.
    - *Pass/Fail:* PASS if the window closes. If neither the console line nor the chord does anything, report FAIL; the
      lead's script stops after one hour anyway.
    - *Log check (lead):* `RTS_QA_END by player=1 at tick [0-9]+ \(console chat\)`; after the chord instead:
      `qa hotkey /rts-qa-end player=1`, `RTS_QA_END by player=1 at tick`

**The AI meanwhile (lead).** Informational; the autotests measure these:

- `ai rts-ai-1: town site` (its mining town, 170–560 tiles out), `cities: new city [0-9]+ of rts-ai-1`
- `rails: AI rts-ai-1 (plans a line|placed depot|runs freight train)`
- `ai rts-ai-1: age-up: Railway Charter started`, `ages: rts-ai-1 age 1 -> 2`
- `divisions: created #[0-9]+ .*\(rts-ai-1, ai\)`

## Recovery

- **The camera is somewhere else.** Press SPACE, or click a name in the city list.
- **The scale differs.** Scroll the wheel one notch at a time until the CC's stockpiles are 112 px apart. After a zoom
  to the limit the wheel steps may not land exactly on the start zoom; 107 px is close enough.
- **Clicks select nothing.** Press F1: it gives the RTS cursor back.
- **A ghost is stuck on the cursor.** Press Q, right-click, or press F1.
- **A console line was mistyped.** The reply says so (for example "rts-give: unknown item …"); type it again.
- **The City Center ghost is refused** (a flying text) or stays a ghost. Place it on open ground at least 500 px from
  the screen centre when zoomed out, and walk the Commander next to it. The build menu's City charter count must be 1.
- **"Rail depot: no room for a platform".** Select the depot, press Delete twice, and place a new ghost 10 tiles further
  out on open ground.
- **The line waits** (a reason after "S signals" in the detail line): "no train kits in the depot network" or "no rails
  in the depot network" means Depot 1 is not in the CC's network ("1 hub"): demolish it and place it closer to the CC.
  "out of coal": type `/rts-give coal 50`.
- **"Cannot lay a rail line: no route between the depots".** Report it with a zoomed-out screenshot (water or mountains
  between the depots).
- **The Railway Charter does not finish** within a minute of step 38. Read the goods line in the ledger, give what is
  missing, and report it. As a last resort type `/rts-age rts-player 2` (it sets Age II) and report it.
- **The factory makes something unwanted** (a second charter, hauler or district). Click Pause (≈27, 737) and report it.
- **A panel hides what you need to click.** Close it with its ×, or with Escape for the ledger and the menus.
- **A key does nothing.** Make sure no text field or console line has focus (press Enter or click empty ground); for a
  Ctrl chord try the Cmd chord.
- **The RTS view is gone** (you see a character, vanilla Factorio menus or no HUD). Wait 2 s: the mod restores the view.
  If it does not, report FAIL with a screenshot.
- **The state is broken** (the base or a depot lost, units gone). Press Ctrl+Shift+R: it starts the same Nation match
  again on a **new world**. Then redo what the next step needs: steps 7, 9 (factory, barracks), 11–12 (city), 21–23
  (rails), and report the restart.

## Results to report

- One line per step: PASS, PARTIAL, FAIL or SKIP, with what the screenshot shows.
- Every AI attack: its strip time, what it hit, and the outcome.
- Every console line typed, in order, and its reply.
- Where on the minimap your capital and the AI's land were (step 6), and which side the city went to (step 12).
- The hauler's tank number (steps 19–20), the line's length and rails (step 25), and the train's first delivery
  (step 28).
- Any text that is clipped, overlaps, shows a raw key (`rts.…`, "Unknown key") or is in the wrong language.
- Any element more than about 30 px from its given coordinates.
- Which function keys or Ctrl chords failed, and whether the alternative worked.

## Not covered

- **The economy itself.** Mining, smelting, steel, science kits and research by labs are replaced by console shortcuts;
  Phase 4's protocol and the autotests cover them.
- **Line cuts and repairs, Bridges, junctions.** The rails autotest cuts a line and checks the repair; Bridges need
  Space Age's elevated rails and tier-2 research.
- **Territory rules in detail:** refused ghosts on enemy or neutral land, forts, attrition numbers, tier-ups (10 and 25
  buildings, 400 and 2,000 goods). The territory autotest covers them.
- **Oil:** oil wells, the refinery, the chemical plant, plastic, the Armoured car and the Bunker in combat, Age II
  research (Supply III and the rest).
- **Haulers carrying cargo between cities** (Phase 4 covers hauler cargo), and an auto hauler serving a city.
- **Ruins and ports, 2048 and 3072 worlds, 3 or 4 nations, the AI's town and rail line beyond the log lines above.**
- **Divisions at scale,** retreat, rename and disband, control groups with divisions; the divisions probes cover them.
- **Save and load,** multiplayer.
