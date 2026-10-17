# Phase 5 M2 GUI QA protocol: people, money, diplomacy and war in a Nation match

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age enabled. Mod `factorio-rts` 0.1.0 after the M2
integration (wave B): people and labor, the treasury and the world market, diplomacy and wars, supply, capture,
garrisons and troop trains, regions and the strategic layer, plus the integration's Disband bin, the city panel's
"Under attack" row, the Nation help page (F11) and attack-moves that spare rails and poles. Integration notes:
`docs/qa/phase5-m2-integration-notes.md`. Contract: `docs/PHASE5-M2.md`.

This protocol plays one Nation match on a 1536×1536 world against one Normal AI. It covers:

- the lobby's Victory and Time limit, and the Nation help page with every hotkey;
- the treasury in the strip, the market panel, taking a trade port and a sale there;
- the city panel's people section, the labor priorities and the draft, the staffing box and Pin;
- the build menu's Nation buildings (houses, food, field depot, Rail works);
- the diplomacy panel: declaring war, and accepting the AI's peace offer from the alert;
- a division's supply bar: low, out of supply (attack orders refused), resupply at the capital;
- a troop train: two depots, a line, Deploy troop train, embark, the ride and the drop-off;
- capturing a city-state with the capture progress over its centre; an own city under attack with Jump;
- the regional and world minimap (N), region and city labels at strategic zoom, region names in alerts;
- Disband on the units page, the info-box check, and the end marker.

The tester is an automated agent with computer use. It sees only the screen and uses only the mouse and the keyboard.
It types a few QA shortcuts into the game console; every step that needs one gives the exact text. Every step gives the
input, what must be visible afterwards, and how to judge PASS or FAIL from the screen. The "Log check (lead)" lines are
for the lead, who greps the log after the run; the tester ignores them. **The tester cannot hover**: every check below
reads text that is on the screen or appears after a click; tooltips are not part of any PASS.

**Coordinates.** They were measured on 2026-10-17 from screenshots of an English client in a 1280×800 window
(`tools/probes/m2_docs_gui.lua` on the tree after commit 9263e69 with the wider city list: screenshots in
`build/shots-m2d-en6/`, map-view window captures in `build/shots-m2d-en6-window/`; the Russian run is
`build/shots-m2d-ru4/`). The world is generated anew for every run:
the capital's place, the terrain around it and the direction of the AI differ from run to run, so map positions are
given relative to your Command Center (CC). Panels that grow with their content (the city panel, the depot panel) give
the rows in order; when a row is not exactly at its coordinate, find it by its text one or two rows away.

Background: `README.md` (section "Nation mode"), `docs/PHASE5-M2.md`, `docs/qa/phase5-m1-protocol.md` (the M1 parts of
the HUD are unchanged) and `docs/qa/phase5-*-notes.md`.

## Launch (lead)

```sh
cd /Users/evgeniyivanov/Projects/home/games/factorio_rts
rm -rf build/qa-p5m2 && mkdir -p build/qa-p5m2 && cp -R mods/factorio-rts mods/mod-list.json build/qa-p5m2/
RTS_LOCALE=en tools/gui-run.sh build/qa-p5m2 3600 'RTS_QA_END'
```

- **Frozen copy.** The copy keeps other agents' edits out of the run. The log is `build/qa-p5m2-gui.log`. The script
  stops when the log contains `RTS_QA_END` (step 31), or after one hour. Steam must be running.
- **Other clients.** Before the launch check that no other agent's Factorio window is open:
  `pgrep -fl 'MacOS/factorio' | grep window-size` must print nothing. All windows share the title and the position,
  so Codex clicks would land in another game.
- **Language.** `RTS_LOCALE=en` makes the client English. The glossary below gives the Russian labels.
- **No self-test.** The GUI self-test is off: no script clicks anything, and the game opens in the lobby.
- **Console.** `tools/gui-run.sh` writes a config that binds F9 to the console. The tester is the admin of a local game.
- **Log checks.** Use `grep -nE 'PATTERN' build/qa-p5m2-gui.log`. Every mod line contains `[rts]`.
- **AI.** The Normal AI keeps running. Its capital lies about 900 tiles away; at the start every nation is at peace, so
  it does not attack before step 13 declares the war, and its first army needs minutes to walk over.

## Tester setup

- **Coordinates** are game-area coordinates of the 1280×800 game window at UI scale 0.75, the automatic scale. On
  screen, the macOS title bar adds about 28 px to y. Every coordinate is approximate (≈). If an element is not exactly
  there, find it in a screenshot by its description. If the window is larger than 1280×800, multiply x by the window
  width / 1280 and y by the window height / 800; the panels keep to the same window edges.
- **Inputs.** You have the mouse (left click, right click, Shift + click, Shift + right click, wheel), the keyboard and
  the console for the QA shortcuts in the table below. Do not use the console for anything else.
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
- **Camera.** SPACE centres the camera on your CC and keeps the zoom. A click on a name in the city list centres the
  camera on that city. A click on the minimap moves the camera there. At the start zoom the CC's left and right
  stockpiles are 112 px apart and a tile is 16 px.
- **Empty ground** (to deselect): any spot with no unit and no building; ≈(1000, 600) or ≈(200, 600) after SPACE.
- **Escape** closes the market, the diplomacy panel, the help page and an open console line. If the Factorio game menu
  opens instead, press Escape once more.
- **Evidence.** Take a screenshot after every step. Report one of PASS, PARTIAL (the main effect is there, a detail
  differs: say which), FAIL (the main effect is missing) or SKIP (a precondition is missing: say which), with one line
  on what the screenshot shows.
- **Time budget.** The session closes after one hour of wall time, and the steps take about 45 minutes. If the strip
  timer passes 45:00, or you have been testing for 50 minutes, go to step 31 and finish.

### QA shortcuts (console)

The economy that earns these takes much longer than a QA session; the shortcuts give the result so the steps can test
what comes after it. Type each line exactly, one per console opening.

| Step | Text | Why |
|---|---|---|
| 6 | `/rts-spawn rts-walker 30` | an army for the supply, troop train and capture steps |
| 9 | `/rts-market ports`, then `/rts-market capture N` (N = the first port number of the reply) | ports lie 300+ tiles out; walking a unit there takes minutes (a unit next to a port for 10 s takes it the same way) |
| 16 | `/rts-supply 30`, `/rts-supply 0`, `/rts-give rts-supply-crate 20` | supply drains 2 per minute on the march; 0 takes 50 minutes |
| 18 | `/rts-research rts-railways`, `/rts-give rts-depot 2`, `/rts-give rts-locomotive-kit 4`, `/rts-give rts-troop-wagon-kit 2`, `/rts-give rts-construction-wagon-kit 1`, `/rts-give rail 300`, `/rts-give coal 200` | Railways needs labs and kits; depots, kits and rails need a steel chain |
| 22 | `/rts-goto city-state`, then `/rts-spawn rts-walker 40` | the camera to the nearest city-state (they lie 300+ tiles out and are only small labels on the map); an army there |
| 24 | `/rts-spawn rts-walker 4 rts-ai-1` | an enemy raid on your new city |
| 25 | `/rts-diplomacy propose rts-ai-1 rts-player peace` | the AI offers peace when it is weary or losing, which takes long |
| 28 | `/rts-spawn rts-raider 3` | units to disband |
| 29 | `/rts-give rts-lab 1` | a building to place for the info-box check |
| 31 | `RTS_QA_END` (no slash) | the end marker |

### Where things are on the HUD

The M1 rows (`docs/qa/phase5-m1-protocol.md`, "Where things are on the HUD") still hold: strip, age badge, alert
lines, kill feed, city list, division panel, minimap, selection panel, build menu, ability bar, hub panel, depot rail
panel, train panel. The city list is wider than in M1: x 6–231 (right edge ≈231, the same width as the division panel
under it), rows at y≈127, 146, 165, the name buttons where they were (left edge x≈15), the magnifier of each row at
x≈212 (≈217 on a row whose name carries the warning icon of an attack). New and changed in M2:

| Element | Location (game area) | Contents |
|---|---|---|
| Strip, row 2 right end | x≈760–905, y≈44 | The treasury "₡ 1,505 (+5/min)" (the glyph may render like ¢). White while the last minute's net is positive, yellow below, red under zero. A click opens the market. Row 3 (y≈62): the victory goal, e.g. "Conquest: hold every rival capital or eliminate every rival. Time limit: unlimited". |
| Alert lines | x 445–835, y 81–135 | Up to 3 lines. An alert with a position starts with its region: "Ashunka Fields: Port captured: Port of Ashunka Fields". |
| Offers frame | x 445–835, y≈140–166, right under the alert lines | While an AI proposal waits: "AI 1 proposes a white peace (120 s)", **Accept** (≈744, 153), **Decline** (≈800, 153). |
| Lobby, Nation mode | dialog x 482–797, y 238–561 | Mode (≈601, 287), Opponents (≈601, 314), Difficulty (≈601, 341), Map size (≈620, 368), Map (greyed, ≈601, 395), **Victory** (≈601, 422), **Time limit** (≈601, 449), the hint, **Start match** (≈739, 540). In Skirmish the dialog is shorter and Mode sits at ≈(601, 314). |
| Help page "How to play" | x 400–880, y 170–628 | × (≈861, 185). In Nation mode (or the lobby with Mode = Nation): 8 paragraphs, Nation mode, Controls, Cities and people, Treasury, Diplomacy and war, Supply, Rails and ages, **Keys**. |
| City panel (people) | x 788–1013, from y 183 | Title and × (≈994, 198). **Under attack row** (only while the city was hit in the last 30 s or is subdued): red text and **Jump** (≈986, 219); every row below then moves 21 px down. Name field and pencil (≈886 / 991, 221), tier, age, land, supply, next tier (y≈242–314), **People** (y≈332), "Residents R / H housing (+N/min)" (≈350), "Happiness N · power ok" (≈368), two need bars: rations (≈395), goods (≈428), "Workforce …" (≈452–469), **Draft** drop-down (≈865, 490), **Priorities** (≈977, 490), networks, Make targets, **+**, Demolish (≈978, 588). With Priorities open, nine families in two columns, five rows 18 px apart from y≈512, each with one ▲ button (it moves the family one place up): left "1. Military", "3. Food", "5. Metallurgy", "7. Electronics", "9. Services" with ▲ at x≈890; right "2. Power", "4. Extraction", "6. Chemistry", "8. Research" with ▲ at x≈994; Demolish moves to ≈(978, 678). |
| Staffing box | x 6–320, y≈672–698, right above the building page | "Staff 100 %: 12.0 of 12 workers · Capital · Services" and **Pin** (≈298, 686), "Unpin" once pinned. |
| Market panel | centred, x 310–970, y 191–607 | Title "Market" and × (≈951, 205). Top: balance and net (≈380, 239), **Tax** drop-down (≈505, 239; it shifts a few px with the balance), the stage ("Solvent"); "Last minute: …"; **Commerce** bar (≈440, 275) and "₡ N / 450 per minute"; **Trade at** drop-down (≈780, 275). Goods table (scrolls), rows 22 px apart from y≈340: Stone brick, Concrete, Coal (384), Stone (406), Iron ore, Copper ore, Iron plate, Copper plate, **Steel plate (≈516)**, …; columns Price, 10 minutes, At port (≈660), Amount field (≈716), **Sell** (≈770), **Buy** (≈821). Bottom: Contracts. |
| Diplomacy panel | centred, x 271–1007, y≈243–556 | Title and × (≈990, 257); "Victory: … · Our score: N"; **War goal** drop-down (≈398, 306). Table: Nation, State, Their opinion (bar and number), Trade ₡, War, Actions. Row "AI 1" (y≈360; ≈365 at war): **War** (≈698), **Ceasefire** (≈740), **Peace** (≈785), **Alliance** (≈827), **Gift 100 ₡** (≈879), **Contract** (≈931). Then one row per city-state ("Free City o…", War, "Can be captured"). "Our wars"; "Proposals to us" with **Accept** (≈909, 538) and **Decline** (≈964, 538) when one waits. |
| Division card supply bar | division panel; with one city in the list: name button (≈50, 191), health bar (y≈204), **supply bar** (y≈211), state line (y≈224), stance buttons Hold / Advance / Screen (≈50 / 116 / 184, 241), Reinforce, pencil, bin (y≈260); everything 20 px lower with two cities in the list | A thin second bar: blue = supplied (50+), amber = low, empty = out of supply. The state line: "Idle", "Moving", "Boarding a train", "On a troop train (N)", followed by " · low supply N" in amber or " · OUT OF SUPPLY" in red. |
| Depot rail panel, troop train | x 765–1012, from y 183 | "Rails: Depot N", platform, kits ("Kits: locomotive 2, wagon 0, construction 0 \| rails 0, coal 100 \| troop wagons 1", two lines), the line (one or two lines), **Deploy freight train** (≈821, 307), **Deploy troop train** right under it (≈818, 329; one row lower when the line has a detail line), the hint, Rail lines. |
| Train panel, troop train | x 1026–1273, y 183–392 | "Troop train N", HP and coal, Route, state, "Troops: N units, S / C supply", trips, the line, **Resume** (≈1058, 343), **Disband** (≈1110, 343). |
| Units page, Disband bin | selection panel title line, right end (≈378, 714) | A red bin, Nation mode only. First click: chat "Disband N unit(s)? Press again within 3 seconds." and the bin turns yellow; a second click within 3 s disbands. |
| Minimap | x 1106–1271, y 9–174 | Regional (default in Nation mode): about 1,000 tiles around the camera. N: the whole world. Dashed circles mark the chokes (passes and fords), coloured circles the capitals; city, city-state and port names are tiny labels. A left click moves the camera there. |

**Build menu, Nation mode** (button order, x≈1066, 1097, 1128, 1159, 1190, 1221, 1252; row 1 y≈740, row 2 y≈772):

- **Economy:** Extractor, Smelter, Stockpile, Transport belt, Fast inserter, Medium electric pole, Hub; row 2: **Rail
  depot**, **Rail works** (both greyed until Railways; Rail works is a 5×5 district that makes 12 rails from 4 steel and
  4 stone).
- **Production:** Barracks, Factory, Lab, City charter, Fort, **House**, **Apartment** (greyed until Age II); row 2:
  **Farm**, **Bakery**, **Fishing hut**, **Field depot**.
- **Defence** and the **Age II** icon tab as in M1 (the Age II tab no longer holds the Rail works).

**Factory recipe buttons, Nation mode, M2** (x = 27 + 26 × index; row 1 y≈737, row 2 y≈762):

| Tab | Index: recipe |
|---|---|
| Buildings | row 1: 0 Pause, 1 Auto, 2 Hub, 3 Rail depot, 4 City charter, 5 Field depot, 6 Stockpile, 7 Extractor, 8 Smelter, 9 Solar array, 10 Factory, 11 Lab, 12 Steam plant, 13 Accumulator; row 2: 0 House, 1 Apartment, 2 Farm, 3 Bakery, 4 Fishing hut, 5 Barracks, 6 Turret, 7 Fort, 8 Laser turret, 9 Wall, 10 Radar |
| Logistics | 0 Pause, 1 Auto, 2 Rails, 3 Transport belts, 4 Fast inserters, 5 Medium electric poles, 6 Hauler kit, 7 Locomotive kit, 8 Cargo wagon kit, 9 Construction wagon kit, 10 Firearm magazines, 11 **Supply crate** (≈313), 12 Supply crate II (grey until Age II), 13 **Troop wagon kit** (≈365). Rails and the four kits are greyed until Railways and clickable after it. |

### Where things are on the map

After SPACE the camera is centred on your CC; a tile is 16 px at the start zoom:

```
screen x = 640 + 16 × (tiles right of the CC)        screen y = 400 + 16 × (tiles below the CC)
```

| Thing | Where (after SPACE, start zoom) |
|---|---|
| Your CC with 4 stockpiles | (640, 400); stockpiles (584, 376), (584, 424), (696, 376), (696, 424) |
| 30 walkers from step 6 | three rows of 10 below the CC, feet x≈424–928, y≈592–704 |
| Factory (step 7) | (448, 304): 12 tiles left of the CC and 6 up |
| Depot 1 / Depot 2 (step 19) | (288, 400) and (992, 400): 22 tiles left / right of the CC; each platform appears about 8 tiles below its depot |
| Lab ghost (step 29) | (832, 304): 12 tiles right of the CC and 6 up |

Every site is a suggestion: any bare ground nearby works (no water, no grey rock, no building, no unit).

### Glossary (English → Russian)

| English | Russian |
|---|---|
| Victory; Conquest; Territory; Score; Time limit; unlimited; 60 min | Победа; Завоевание; Территория; Счёт; Лимит времени; без лимита; 60 мин |
| How to play; Nation mode; Keys | Как играть; Режим «Держава»; Клавиши |
| ₡ 1,505 (+5/min); Market; Tax:; Low; Normal; High; Solvent | ₡ 1,505 (+5/мин); Рынок; Налоги:; Низкие; Обычные; Высокие; Казна в порядке |
| Commerce:; Trade at:; Sell; Buy; At port; Amount; Contracts | Торговля:; Порт:; Продать; Купить; В порту; Количество; Контракты |
| Port captured: Port of X | Порт захвачен: Порт X |
| People; Residents 200 / 200 housing (+0.0/min); Happiness 100 · power ok | Население; Жители 200 / 200 мест (+0.0/мин); Довольство 100 · энергия есть |
| Workforce N: J of K jobs filled, F free · recruits R | Рабочие N: занято J из K мест, свободно F · рекрутов R |
| Draft; Priorities; 1. Military; Power; Food; Extraction; Metallurgy; Services | Призыв; Приоритеты; 1. Армия; Энергия; Еда; Добыча; Металлургия; Услуги |
| Staff 100 %: 12.0 of 12 workers · Capital · Services; Pin; Unpin | Персонал 100 %: 12.0 из 12 · Столица · Услуги; Закрепить; Открепить |
| House; Apartment; Farm; Bakery; Fishing hut; Field depot; Rail works | Дом; Многоквартирный дом; Ферма; Пекарня; Рыбацкая хижина; Полевой склад; Рельсовый комбинат |
| Diplomacy; War goal; Capture the nearest city; War; Ceasefire; Peace; Alliance; Gift 100 ₡; Contract | Дипломатия; Цель войны; Захватить ближайший город; Война; Перемирие; Мир; Союз; Дар 100 ₡; Контракт |
| Their opinion; Our wars; Proposals to us; Accept; Decline; Can be captured | Их мнение; Наши войны; Предложения нам; Принять; Отклонить; Можно захватить |
| War on AI 1. Our goal: capture …; AI 1 proposes peace: accept below or in F4 | Война с ИИ 1, цель: захват города …; ИИ 1 предлагает мир: примите ниже или в F4 |
| The war with AI 1 is over: white peace | Война с ИИ 1 окончена: белый мир |
| Supply Test / Division 1; Boarding a train; On a troop train | Дивизия 1; Посадка в поезд; В войсковом поезде |
| Idle · low supply 30; Idle · OUT OF SUPPLY | Ожидает · мало снабжения 30; Ожидает · НЕТ СНАБЖЕНИЯ |
| Kits: … \| troop wagons 2 | Комплекты: … \| войсковых вагонов 2 |
| rts-supply: 1 division(s) of rts-player set to 0 SP; rts-goto: city-state at (x, y) (N tiles); rts-diplomacy: proposal #N peace rts-ai-1 -> rts-player | the same (console replies are not translated) |
| N unit(s) out of supply take no attack order: … | Без снабжения (N): приказ атаковать не принят, … |
| Deploy troop train; Troop train N; Troops: N units, S / C supply | Собрать войсковой поезд; Войсковой поезд N; Войска: N ед., снабжение S / C |
| Subdued; Capture by You: N %; City captured: X; X subdued: drive the attackers off | Подавлен; Захват (Вы): N %; Город захвачен: X; X подавлен: отгоните врага |
| Under attack (N s ago); Under attack: AI 1 captures it, N %; Jump | Под атакой (N с назад); Под атакой: ИИ 1 захватывает, N %; К атаке |
| Minimap: the whole world (N: region); Minimap: the region around the camera (N: whole world) | Миникарта: весь мир (N — регион); Миникарта: регион вокруг камеры (N — весь мир) |
| Disband N unit(s)? Press again within 3 seconds.; Disbanded N unit(s): R recruits went home. | Распустить юнитов: N? Нажмите ещё раз в течение 3 секунд.; Распущено юнитов: N, рекрутов вернулось домой: R. |
| Free City of X | Вольный город X |

## If an AI attack interrupts

From step 13 on you are at war with AI 1. Its first attack needs several minutes to walk 900 tiles and loses health
deep in your land. Signs: a red "<Region>: Base under attack: …" line, a red mark on the minimap, "Enemies seen" above
0. Your 30 walkers (from step 15 a division) fire by themselves. If an attack reaches the capital: finish the current
click, press Q if a ghost is on the cursor, press F3 (the camera jumps there), press Ctrl+A, press F and right-click
the enemies. When "Enemies seen" shows 0 again press SPACE and redo the interrupted step. Note the strip time and what
was hit. Attack-moves no longer shoot rails, signals, poles or belts on the way (only raiders and explicit attacks do):
if your units shoot your own or enemy rails during an attack-move, report it.

## Steps

### Part A: lobby and start

1. **The start dialog, Mode Nation.**
   - *Input:* wait until the window shows a dialog in the middle of a black screen. Click **Mode** (≈601, 314); a list
     opens below it. Click "Nation". Take a screenshot.
   - *Expect:* the dialog grows: Mode "Nation" (≈601, 287), Opponents 1, Difficulty Normal, Map size "World
     (1536×1536)", Map "World" greyed, and two new rows **Victory** "Conquest" (≈601, 422) and **Time limit**
     "unlimited" (≈601, 449); the hint under them; **Start match** (≈739, 540).
   - *Expect (hint):* "Every nation starts at peace with a capital, the same stock and 6 walkers on a generated world. A
     nation with no city left is out; win by the Victory rule above."
   - *Pass/Fail:* PASS if Victory, Time limit and the Nation hint are there. PARTIAL if the hint is the Skirmish one
     ("Everyone starts with a Command Center … no Command Center, barracks, factory or units left").
   - *Log check (lead):* `lobby: player 1 set mode -> 1 opponent\(s\), normal, nation, world default`

2. **Victory and Time limit.**
   - *Input:* click **Victory** (≈601, 422) and take a screenshot of the open list; click "Conquest". Click **Time
     limit** (≈601, 449) and take a screenshot; click "unlimited".
   - *Expect:* Victory lists Conquest, Territory, Score; Time limit lists 60 min, 90 min, 120 min, unlimited. Both keep
     their values.
   - *Log check (lead):* `lobby: player 1 set victory`, `lobby: player 1 set time_limit`

3. **The Nation help page in the lobby.**
   - *Input:* press F11 (or click **?** on the strip, ≈765, 22). Take a screenshot. Click the × (≈861, 185).
   - *Expect:* "How to play" with 8 paragraphs starting "Nation mode:", "Controls:", "Cities and people:",
     "Treasury:", "Diplomacy and war:", "Supply:", "Rails and ages:", "Keys:". The Keys paragraph names M market, F4
     diplomacy, N minimap, L city ledger, T research, B build menu, Delete (demolish or disband, press twice), F3, F10,
     F11. The page fits the window (bottom edge ≈628) without a scroll bar. The × closes it.
   - *Pass/Fail:* PASS if the Nation page with the Keys paragraph shows. FAIL if the page starts with "Goal: destroy
     every enemy Command Center" (the Skirmish page).
   - *Log check (lead):* `hud help opened player=1 \(.*\): 8 lines \(nation\)`

4. **Start.**
   - *Input:* click **Start match** (≈739, 540). Wait up to 10 s.
   - *Expect:* the camera on your capital: the CC at (640, 400) with 4 stockpiles, the Commander and 6 walkers. Strip:
     timer from 00:00, "Army 7", "Supply 6/40", Research [T], ?, **Land 1.3%**, Menu; row 2 ends with the treasury
     **"₡ 1,50x (+N/min)"**; row 3 "Conquest: hold every rival capital or eliminate every rival. Time limit: unlimited".
     Age badge "Age I", city list "Capital  Town, N cells", minimap in regional mode (your land in the middle, white
     dashed circles mark passes and fords), build menu Economy with a greyed Rail depot and Rail works in row 2.
   - *Pass/Fail:* PASS if the treasury and the goal line are on the strip.
   - *Log check (lead):* `match: starting match [0-9]+: 1 opponent\(s\), normal, nation, world 1536x1536`,
     `treasury: rts-player opens with 1,500 cr`, `war: Nation match: victory conquest, time limit none`

### Part B: the capital and its people

5. **The treasury opens the market.**
   - *Input:* click the treasury on the strip (≈840, 44). Take a screenshot. Click the market's × (≈951, 205). Press M,
     take a screenshot, press M again.
   - *Expect:* the click and the first M open the **Market** panel in the middle (x 310–970): "₡ 1,5xx (+N/min)", Tax
     "Normal", "Solvent", a "Last minute: tax +N, exports +0, …" line, Commerce "₡ 0 / 300 per minute, Commerce 0", an
     empty **Trade at** drop-down and a yellow line saying you hold no port; the goods table with Price and Sell / Buy
     buttons; "Contracts: No contracts. …". The second M closes it.
   - *Pass/Fail:* PASS if the click and M both open the panel.
   - *Log check (lead):* `market: panel opened by player 1 \(rts-player\)`, `hud: hotkey rts-market \(M\) player=1`

6. **QA shortcut: an army.**
   - *Input:* press SPACE. Open the console (F9), type `/rts-spawn rts-walker 30`, press Enter. Wait 3 s.
   - *Expect:* the reply "rts-spawn: 30 x rts-walker for rts-player near (x, y)"; 30 walkers in three rows below the
     CC; "Army 37", "Supply 36/40".
   - *Log check (lead):* `rts-spawn: 30 x rts-walker for rts-player near`

7. **The city panel's people section and the labor priorities.**
   - *Input:*
     1. Click the CC (640, 400). Take a screenshot.
     2. Click **Priorities** (≈977, 490). Take a screenshot.
     3. Click the ▲ of "2. Power" (≈994, 512; the right column, top row). Take a screenshot.
     4. Click the **Draft** drop-down (≈865, 490) and take a screenshot of the list; click "30 %".
     5. Click **Priorities** again.
   - *Expect:*
     - **Panel** "Capital: Town": … "Next tier: City at 400 residents (N now)", a yellow heading **People**, "Residents
       N / 200 housing (+x/min)", "Happiness N · power ok", two bars with a rations and a goods icon ("100 % of
       20.0/min", "100 % of 8.0/min"), "Workforce N: J of K jobs filled, F free · recruits R", **Draft** "20 %" and
       **Priorities**.
     - **Priorities open:** nine families in two columns, read left to right: "1. Military", "2. Power" / "3. Food",
       "4. Extraction" / "5. Metallurgy", "6. Chemistry" / "7. Electronics", "8. Research" / "9. Services", each with one
       ▲ button (the first one greyed). The panel now reaches y≈693; Demolish ≈(978, 678).
     - **After ▲:** "1. Power" top left, "2. Military" top right.
     - **Draft list:** 0 %, 10 %, 20 %, 30 %, 50 %. After the click Draft reads "30 %".
   - *Pass/Fail:* PASS if the people lines, the nine families and the swapped Power and Military show.
   - *Log check (lead):* `citygui click prio_toggle city=[0-9]+ player=1`,
     `people: labor priorities of rts-player: power > military > food`, `people: city [0-9]+ draft 30 %`

8. **The staffing box and Pin.**
   - *Input:* click empty ground. Click **Production** (≈1131, 712), then **Factory** (≈1097, 740), left-click the map at
     (448, 304), press Q. Wait 20 s (the CC's robots build it). Click the factory. Take a screenshot. Click **Pin**
     (≈298, 686). Wait 6 s. Take a screenshot. Click empty ground.
   - *Expect:* above the building page a one-line box: "Staff 100 %: 12.0 of 12 workers · Capital · Services" (or less
     than 100 % when the capital has fewer free workers) and **Pin**. After the click the button reads **Unpin**.
   - *Pass/Fail:* PASS if the box shows and Pin turns into Unpin.
   - *Log check (lead):* `build ghost rts-factory player=1 at`, `people: rts-factory #[0-9]+ pinned`

### Part C: build menu, port and market

9. **The Nation buildings in the build menu.**
   - *Input:* look at the Production tab (still open). Take a screenshot. Click **Economy** (≈1077, 712). Take a
     screenshot.
   - *Expect:* Production: row 1 Barracks, Factory, Lab, City charter, Fort, **House**, **Apartment** (greyed); row 2
     **Farm**, **Bakery**, **Fishing hut**, **Field depot**. Economy row 2: **Rail depot** and **Rail works**, both
     greyed (Railways is not researched).
   - *Pass/Fail:* PASS if the four people buildings, the field depot and the Rail works are there.
   - *Log check (lead):* `hud build tab production player=1: .*rts-house rts-apartment rts-farm rts-bakery rts-fishing-hut rts-field-depot`,
     `hud build tab economy player=1: .* rts-depot rts-district-rails`

10. **QA shortcut: take a trade port.**
    - *Input:* open the console, type `/rts-market ports`, press Enter. Note the number after "port #" in the first
      reply line. Open the console again and type `/rts-market capture N` with that number. Press Enter.
    - *Expect:* replies "market: port #N at (x, y) owner nil …" (2 or 3 lines, one per port, and one line per nation);
      then "market: capture -> true". A green alert "**<Region>: Port captured: Port of <Region>**".
    - *Pass/Fail:* PASS if the alert names a region before the colon.
    - *Log check (lead):* `market: port #[0-9]+ \(.*\) captured by rts-player \(from rts-neutral\)`

11. **A sale at the port.**
    - *Input:* press M. Take a screenshot. In the goods table find **Steel plate** (≈516; scroll the table with the
      wheel if it is not visible). Its Amount field reads 100. Click its **Sell** (≈770, 516). Take a screenshot. Click
      the **Tax** drop-down (≈505, 239), click "High", take a screenshot, then set it back to "Normal". Press M.
    - *Expect:* **Trade at** names "Port of <Region>"; Steel plate's "At port" reads 300 (the port's loot; Coal 100).
      After Sell: the balance rises by about 290 ₡ and the net shows a large plus, Steel's "At port" drops to 200 and
      its price a little, the Commerce bar fills to about "₡ 294 / 450 per minute". Tax High: the strip's net rises
      within 10 s (the next tax step).
    - *Pass/Fail:* PASS if the balance rises after Sell.
    - *Log check (lead):* `market: player 1 sells 100 steel-plate: [0-9.]+ cr`,
      `market: rts-player sold 100 steel-plate at port #[0-9]+`, `market: player 1 sets tax high`

### Part D: diplomacy and war

12. **The diplomacy panel at peace.**
    - *Input:* press F4. Take a screenshot.
    - *Expect:* "Diplomacy" in the middle: "Victory: Conquest · Time limit: unlimited · Our score: N"; **War goal**
      "Capture the nearest city"; the row **AI 1** in red: State "Peace", a yellow opinion bar "+0", Trade 0, and the
      buttons War, Ceasefire, Peace, Alliance, Gift 100 ₡, Contract; four or five rows "Free City o…" in State "War" with
      "Can be captured"; "Our wars: We are at war with no nation."; "Proposals to us: No proposal waits for an answer."
    - *Pass/Fail:* PASS if the AI row and the city-state rows show. Report whether the city-state names are cut off
      ("Free City o…").
    - *Log check (lead):* `hud: hotkey rts-diplomacy \(F4\) player=1`, `diplomacygui: opened by player 1`

13. **Declare war.**
    - *Input:* click **War** in the AI 1 row (≈698, 360). Take a screenshot. Press F4 to close.
    - *Expect:* the AI 1 row: State "War" in red, the opinion drops (about −30) with a red bar, the War column "Score +0,
      weariness 0%"; "Our wars: AI 1 (we declared), 00:mm: capture …". A red alert "<Region>: War on AI 1. Our goal:
      capture <city>".
    - *Pass/Fail:* PASS if the state reads War and the alert appears.
    - *Log check (lead):* `diplomacygui: player 1 war -> rts-ai-1: proposal #[0-9]+`,
      `war: #[0-9]+ declared rts-player -> rts-ai-1`

### Part E: supply

14. **Form a division.**
    - *Input:* press SPACE. Press Ctrl+A. Click the walker card (≈47, 736). Click **Form division** (≈187, 166 with one
      city in the list; ≈187, 186 with two). Take a screenshot.
    - *Expect:* "Divisions (1)" and a card "Division 1", "36/36", a green health bar and **a second thin bar under it,
      blue and full** (the supply points), "Idle … Hold", the stance buttons, Reinforce, pencil and bin.
    - *Pass/Fail:* PASS if the card has the second (supply) bar.
    - *Log check (lead):* `divisions: created #[0-9]+ Division [0-9]+ \(rts-player, player\) with [0-9]+ units`

15. **Low and out of supply.**
    - *Input:* open the console, type `/rts-supply 30`, press Enter. Wait 3 s, take a screenshot of the card. Open the
      console, type `/rts-supply 0`, press Enter. Wait 3 s, take a screenshot. The division stays selected: press F and
      right-click bare ground about 300 px right of the walkers.
    - *Expect:* the replies "rts-supply: 1 division(s) of rts-player set to 30 SP" and "rts-supply: 1 division(s) of
      rts-player set to 0 SP". At 30 the supply bar is amber and about a third long and the card's state line reads
      "Idle · low supply 30" in amber; at 0 the bar is empty and the state line reads "**Idle · OUT OF SUPPLY**" in red.
      An alert "<Region>: Division 1 is out of supply". The attack-move does nothing: the walkers stay, and a flying text
      says "36 unit(s) out of supply take no attack order: resupply them near a depot with supply crates".
    - *Pass/Fail:* PASS if the card reads OUT OF SUPPLY and the attack-move is refused.
    - *Log check (lead):* `rts-supply: 1 division`, `war: division #[0-9]+ Division [0-9]+ \(rts-player\) supply .* -> out`,
      `divisions: #[0-9]+ Division [0-9]+ order attack_move refused`

16. **Resupply at the capital.**
    - *Input:* open the console, type `/rts-give rts-supply-crate 20`, press Enter. The division stands next to the CC,
      a depot with crates now. Watch the card for 70 s; take a screenshot at the end. Press F and right-click the same
      spot again.
    - *Expect:* the reply "rts-give: 20 x rts-supply-crate into the rts-player pool". The supply bar grows (20 points a
      minute, 1 crate per 10 points): after about 60 s it is amber about a fifth long and the state line reads "Idle ·
      low supply 20" in amber instead of the red OUT OF SUPPLY.
      The attack-move now works: the division walks off ("Attack-moving"). Right-click near the CC to bring it back.
    - *Pass/Fail:* PASS if the bar grows and the second attack-move goes through.
    - *Log check (lead):* `war: division #[0-9]+ Division [0-9]+ \(rts-player\) supply out -> low`,
      `divisions: #[0-9]+ Division [0-9]+ order attack_move -> `

### Part F: a troop train

17. **Railways and the rail stock.**
    - *Input:* open the console once per line and type, each followed by Enter: `/rts-research rts-railways`,
      `/rts-give rts-depot 2`, `/rts-give rts-locomotive-kit 4`, `/rts-give rts-troop-wagon-kit 2`,
      `/rts-give rts-construction-wagon-kit 1`, `/rts-give rail 300`, `/rts-give coal 200`.
    - *Expect:* a green alert "Research complete: Railways", seven replies. In the Economy tab Rail depot shows 2 and Rail
      works is no longer greyed. (Optional: click the factory (448, 304) and its Logistics icon (≈112, 714): Rails, the
      locomotive, cargo, construction and troop wagon kits are no longer greyed; click empty ground.)
    - *Log check (lead):* `rts-research: rts-railways researched for rts-player`, `rts-give: 2 x rts-troop-wagon-kit`

18. **Two depots.**
    - *Input:* press SPACE. In the Economy tab click **Rail depot** (≈1066, 772), left-click (288, 400), then left-click
      (992, 400). Press Q. Wait 20 s. Click the left depot. Take a screenshot.
    - *Expect:* the CC's robots build both depots; a 40-tile platform appears next to each (usually 8 tiles below).
      The left depot's rail panel "Rails: Depot 1", "Platform: 40 tiles, 2 stops", "Kits: locomotive 4, wagon 0,
      construction 1 | rails 300, coal C | troop wagons 2", "No line. …", **Deploy freight train** and **Deploy troop
      train** (enabled).
    - *Pass/Fail:* PASS if both depots stand with platforms. If "Rail depot: no room for a platform" appears, place it
      10 tiles further out (Recovery).
    - *Log check (lead):* `rails: depot #[0-9]+ \(.*\) of rts-player at .*: platform`

19. **Lay the line.**
    - *Input:* with Depot 1 selected, right-click Depot 2 (992, 400). Watch the rail panel for up to 90 s.
    - *Expect:* "Depot 1 → Depot 2: building, …" in yellow, a construction train lays the track, then "**open**" in
      green and the alert "Rail line open".
    - *Log check (lead):* `order lay-rail depot=#[0-9]+ -> #[0-9]+`, `rails: line #[0-9]+ of rts-player open`

20. **Deploy the troop train and route it.**
    - *Input:* click Depot 1 (288, 400). Click **Deploy troop train** (≈818, 329; the button under Deploy freight train).
      Click one of the new train's carriages on Depot 1's platform. Take a screenshot. Right-click Depot 1 (pickup),
      then hold Shift and right-click Depot 2 (drop-off).
    - *Expect:* a train of locomotive, two troop wagons, locomotive on the platform. Train panel: "**Troop train N**",
      "HP 1000/1000, coal …", "**Troops: 0 units, 0 / 32 supply**", Resume, **Disband**. After the right clicks: "Route:
      Depot 1 → Depot 2".
    - *Pass/Fail:* PASS if the troop train and "Troops: 0 units" show.
    - *Log check (lead):* `rails: depot #[0-9]+ \(rts-player\) deployed troop train [0-9]+`,
      `rails: train [0-9]+ \(rts-player\) route depot #[0-9]+ -> depot #[0-9]+`

21. **Embark, ride, disembark.**
    - *Input:* click the division's name button in the division panel (≈50, 191 with one city in the list) to select it.
      Right-click Depot 1
      (288, 400). Watch 60 s, with a screenshot every 15 s; when the train leaves, follow it (or click Depot 2 at (992,
      400) after SPACE).
    - *Expect:* the card reads "**Boarding a train**"; the walkers walk beside the track to the wagons and vanish into
      them; the card then reads "On a troop train (N)" and the train leaves for Depot 2 within 30 s of the last
      boarding. At Depot 2 the walkers reappear beside the track within a few seconds with the same health, the card
      reads "Idle", and the train goes back to Depot 1.
    - *Pass/Fail:* PASS if the walkers get out at Depot 2. Report how many rode (32 supply fit; 36 walkers leave 4 at
      Depot 1, which is fine).
    - *Log check (lead):* `order embark depot=#[0-9]+ n=[0-9]+ divisions=1 player=1`,
      `war: [0-9]+ unit\(s\) of division #[0-9]+ .* boarded troop train`, `war: troop train [0-9]+ leaves depot`,
      `war: troop train [0-9]+: [0-9]+ unit\(s\) disembarked at`

### Part G: capture a city-state; an own city under attack

22. **The world minimap; a city-state; an army there.**
    - *Input:* press N. Take a screenshot of the minimap. Press N again. Open the console, type `/rts-goto city-state`,
      press Enter. Take a screenshot. Open the console, type `/rts-spawn rts-walker 40`, press Enter.
    - *Expect:* N: the chat line "Minimap: the whole world (N: region)"; the minimap shows the whole 1536-tile world:
      your land in blue, the AI capital's circle in red, dashed circles on passes and fords. The second N: "Minimap: the
      region around the camera (N: whole world)". `/rts-goto`: the reply "rts-goto: city-state at (x, y) (N tiles)" and
      the camera on a green-tinted City Center with two stockpiles and up to 6 turrets on a ring around it. 40 walkers
      appear next to it and the turrets fire at them.
    - *Pass/Fail:* PASS if both minimap modes show and the 40 walkers stand at a city-state.
    - *Log check (lead):* `strategic: minimap of player 1 -> world`, `strategic: minimap of player 1 -> regional`,
      `rts-goto: city-state at`, `rts-spawn: 40 x rts-walker for rts-player near`

23. **Capture it.**
    - *Input:* press Ctrl+A. Press F and right-click the City Center. Watch up to 3 minutes, with a screenshot every 20 s
      while the label over the centre changes.
    - *Expect:* the turrets die; the City Center's health drops but it never dies (a city-state's centre heals back half
      of every hit, so it takes a while): at 10 % a label "**Subdued**" appears over it; while your walkers stand within
      24 tiles and no defender is there, the label reads "**Capture by You: N %**" and counts up for 20 s. Then a green
      alert "<Region>: City captured: Free City of X", the label goes, the land outline turns blue, and the city list
      gets a new row. Your capital's units, walking over from far away, do not matter.
    - *Pass/Fail:* PASS if the capture label counts and the city joins your list. FAIL if the City Center is destroyed.
    - *Log check (lead):* `capture: city [0-9]+ of rts-neutral at .* subdued by rts-player`,
      `capture: city [0-9]+ of rts-neutral: rts-player starts the capture`,
      `capture: city [0-9]+ \(.*\) captured by rts-player from rts-neutral`

24. **An enemy raid on your capital: "Under attack" and Jump.**
    - *Input:*
      1. Press SPACE. Click the CC (640, 400): the city panel "Capital: Town" opens.
      2. Open the console, type `/rts-spawn rts-walker 4 rts-ai-1`, press Enter. Wait 5 s, take a screenshot.
      3. Click the minimap well away from your land (the camera moves there; the CC stays selected and its panel open).
         Click **Jump** in the city panel (≈986, 219). Take a screenshot.
      4. Press Ctrl+A, press F and right-click the red walkers next to the CC. Wait until they are dead, then 30 s more.
    - *Expect:* 4 red walkers appear next to the CC and shoot it and its stockpiles. The city panel shows a red row
      "**Under attack (N s ago)**" with **Jump** right under its title (every row below moves down by one), and the
      "Capital" button in the city list shows a warning icon (a red triangle) before its name. Jump brings the camera
      back to the place of the last hit, next to the CC. The CC never falls (it heals back half of every hit). 30 s after
      the last hit the row and the icon disappear.
    - *Pass/Fail:* PASS if the row, the icon in the list and Jump work.
    - *Log check (lead):* `rts-spawn: 4 x rts-walker for rts-ai-1 near`, `hud: alert base-attacked for rts-player`,
      `citygui click attack_jump city=[0-9]+ player=1`

### Part H: peace from an AI offer

25. **The AI offers peace; accept it from the alert.**
    - *Input:* open the console, type `/rts-diplomacy propose rts-ai-1 rts-player peace`, press Enter. Take a screenshot.
      Click **Accept** in the small frame under the alert lines (≈744, 153). Press F4, take a screenshot, press F4.
    - *Expect:* the reply "rts-diplomacy: proposal #N peace rts-ai-1 -> rts-player"; a yellow alert "<Region>: AI 1
      proposes peace: accept below or in F4" and, under the alert lines, a frame
      "AI 1 proposes a white peace (120 s)" with **Accept** and **Decline** (the same proposal is in F4 under "Proposals to
      us"). After Accept: the frame goes, a green alert "<Region>: The war with AI 1 is over: white peace", and F4 shows
      AI 1 in State "Peace".
    - *Pass/Fail:* PASS if Accept ends the war.
    - *Log check (lead):* `diplomacy: proposal #[0-9]+ peace rts-ai-1 -> rts-player`,
      `diplomacygui: player 1 accept proposal #[0-9]+: true`, `war: #[0-9]+ rts-player / rts-ai-1 ended .* treaty \{kind = "white"\}`

### Part I: the map

26. **Region labels at strategic zoom.**
    - *Input:* press SPACE. Scroll the wheel down (towards you) one notch at a time until the view turns into the map
      (about 10–15 notches). Take a screenshot. Scroll further out 5 notches, take a screenshot. Scroll back in until
      the game view returns, then press SPACE.
    - *Expect:* in the map view large region names (for example "Ashunka Fields", "Kararnia Lakes", "… Heights") with
      resource icons, your cities' names in blue, the AI's in red, city-states as "Free City of X" with an icon, port
      names ("Port of X (You)" for yours), your land outlined in blue, the city-states' land outlined; further out,
      choke markers (dashed circles with names) on passes and fords.
    - *Pass/Fail:* PASS if region names are readable on the map.
    - *Log check (lead):* `camera zoom player=1`

27. **Alerts name their region.**
    - *Input:* look at the alert lines now and in your earlier screenshots (steps 10, 13, 23, 25).
    - *Expect:* every alert that belongs to a place starts with a region name and a colon ("Ashunka Fields: Port
      captured: …"); research and treasury alerts have none.
    - *Pass/Fail:* PASS if the place alerts carry a region. Report any alert line cut off with "…" at its right end.

### Part J: Disband and the info box

28. **Disband three raiders.**
    - *Input:* press SPACE. Open the console, type `/rts-spawn rts-raider 3`, press Enter. Press Ctrl+A. Click the raider
      card in the selection panel: the third card (≈72, 736), after the Commander and the walker. Take a screenshot.
      Click the red bin at the right end of the panel's title line (≈378, 714). Take a screenshot. Within 3 s click it
      again.
    - *Expect:* after the card click the panel reads "Raider ×3"; the first bin click: the chat line "Disband 3 unit(s)?
      Press again within 3 seconds." and the bin turns yellow; the second: the raiders vanish, "Disbanded 3 unit(s): 0
      recruits went home." (spawned units were never drafted) and "Army" drops by 3. The bin is never shown in Skirmish.
    - *Pass/Fail:* PASS if exactly the three raiders are gone.
    - *Log check (lead):* `disband: armed player=1 units=3`, `disband: done player=1 units=3`

29. **The info box under the minimap (place a ghost, press Q, watch 60 s).**
    - *Input:* open the console, type `/rts-give rts-lab 1`, press Enter. Click empty ground. Click **Production**
      (≈1131, 712), then **Lab** (≈1128, 740). Left-click the map at (832, 304). Press Q. Move the mouse to empty
      ground ≈(300, 600) and do not touch anything for 60 s; take a screenshot at 10 s, 30 s and 60 s.
    - *Expect:* a lab ghost, then the CC's robots build the lab within about 15 s. At no time does a vanilla info box
      (a dark box with the entity's name, health and description) stay below the minimap at the top right (x≈1106–1271,
      y≈180–400). A box that appears while the mouse is over the lab and goes when it leaves is fine.
    - *Pass/Fail:* PASS if no box stays under the minimap for 60 s. FAIL with the screenshot if one stays.
    - *Log check (lead):* `build ghost rts-lab player=1 at`, `cursor clear \(Q\) player=1`,
      `camera: cleared the hover selection` (any number of times is fine)

30. **Delete disbands too.**
    - *Input:* press SPACE. Click one walker of the division (it selects the whole division; the panel reads "Walker
      ×N"). Press Delete once. Wait 4 s. Click empty ground.
    - *Expect:* the chat line "Disband N unit(s)? Press again within 3 seconds."; after 4 s nothing has happened (the
      press expired). Do not press Delete twice.
    - *Pass/Fail:* PASS if the single press only arms.
    - *Log check (lead):* `disband: armed player=1 units=[0-9]+` with no `disband: done` after it

### Part K: end

31. **End the session.**
    - *Input:* open the console, type `RTS_QA_END` (no slash) and press Enter. If the window does not close within 10 s,
      press Ctrl+Shift+E (or Cmd+Shift+E).
    - *Expect:* the typed line appears in the chat, and a few seconds later the game window closes.
    - *Pass/Fail:* PASS if the window closes.
    - *Log check (lead):* `RTS_QA_END by player=1 at tick [0-9]+ \(console chat\)`

**The AI meanwhile (lead).** Informational; the autotests measure these:

- `market: AI rts-ai-1 sends .* to port`, `market: rts-ai-1 sold`
- `diplomacy: ai rts-ai-1 .* (declares war|wants out of the war)`
- `capture: city [0-9]+ of rts-player .* subdued by rts-ai-1` (an AI attack on your towns after step 13)

## Recovery

- **The camera is somewhere else.** Press SPACE, or click a name in the city list.
- **Clicks select nothing.** Press F1: it gives the RTS cursor back.
- **A ghost is stuck on the cursor.** Press Q, right-click, or press F1.
- **A console line was mistyped.** The reply says so; type it again.
- **"Rail depot: no room for a platform".** Select the depot, press Delete twice, and place a new ghost 10 tiles further
  out on open ground.
- **The line waits** ("no train kits", "no rails" or "out of coal" after the detail line): the depot is not in the CC's
  network; demolish it and place it closer (within 30 tiles) to the CC, or type `/rts-give coal 50`.
- **Deploy troop train stays greyed:** the depot's network lacks 2 locomotive kits or a troop wagon kit; repeat the
  `/rts-give` lines of step 17 and check that the depot's hub panel reads "Network #K, 2 hubs" (it shares the CC's).
- **`/rts-goto city-state` says "no city-state found"**: every city-state was taken already (the AI takes them from
  minute 20 at the earliest); type `/rts-goto ai` for the nearest AI town instead and capture that one (you are at war).
- **The walkers do not attack the city-state** (step 23): select them again with Ctrl+A, press F and right-click the
  City Center itself, not the ground beside it.
- **A panel hides what you need to click.** Close it with its × or Escape (market, diplomacy, help), or click empty
  ground (city and building panels).
- **The RTS view is gone** (a character, vanilla menus or no HUD). Wait 2 s. If it does not come back, report FAIL.
- **The state is broken.** Press Ctrl+Shift+R: it starts the same Nation match again on a new world. Then redo steps 6
  and 13 before the step you were on, and report the restart.

## Results to report

- One line per step: PASS, PARTIAL, FAIL or SKIP, with what the screenshot shows.
- Every console line typed, in order, and its reply.
- The balance before and after the sale (step 11), the supply bar's length at 30 and after the refill (steps 15–16), how
  many walkers rode the troop train (step 21), the capture label's readings (step 23).
- Every AI attack: its strip time, what it hit, and the outcome.
- Any text that is clipped (ends in "…"), overlaps, shows a raw key (`rts.…`, `rts-war.…`, "Unknown key") or is in the
  wrong language; any panel that covers another or the minimap.
- Any element more than about 30 px from its given coordinates.
- Which function keys failed, and whether the alternative worked.

## Not covered

- **Walking a unit to a trade port** and the AI's own port envoys (the treasury fixture and the AI autotests cover the
  capture by presence); imports, contracts (Contract button), the commerce cap and the debt stages (treasury fixture).
- **Growth and hunger** over minutes, houses and the food chain at work, the tier change by population, "No workers"
  and "No recruits" (the people fixture `tools/probes/people_m2.lua`).
- **Ceasefire, alliance, gifts, war goals met, tributes, Territory and Score victories** (the diplomacy fixture
  `tools/probes/diplomacy_accept.lua`).
- **Garrison and sortie, a field depot, a destroyed troop wagon, a train disbanded into kits** (the war autotest and
  `tools/probes/war_gui.lua`).
- **The AI capturing your cities in a real war, the capital moving, elimination** (the 60-minute AI matches).
- **Rails, signals and poles are not shot by attack-moves.** Your own rails cannot be attacked at all (own force), so
  the protocol has no step for it; the headless probe `tools/probes/m2_targeting.lua` checks it against an enemy row of
  rails, a signal, a pole, a belt and three buildings (walkers and a division spare the infrastructure and destroy the
  buildings; raiders sabotage; a turret shoots buildings only).
- **Save and load,** 3 or 4 nations, 2048 and 3072 worlds.
