# Phase 4 GUI QA protocol: one full match

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age enabled. Mod `factorio-rts` 0.1.0, working tree after
commit fb19129.

This protocol plays one Phase 4 match on a Medium Chokepoints map against one Normal AI. It covers:

- the camera, selection and orders;
- the build menu, with an iron line and a hub;
- hub policies, a hauler route and research;
- abilities, the Commander and supply;
- alerts, control groups and a fight;
- the match menu, Concede, the results window and the end marker.

The tester is an automated agent with computer use. It sees only the screen and uses only the mouse and the keyboard: no
console, no log, no shell. Every step gives the input, what must be visible afterwards, and how to judge PASS or FAIL from
the screen. The "Log check (lead)" lines are for the lead, who greps the log after the run; the tester ignores them.

Background: `README.md` (controls, economy, hubs) and `docs/qa/phase4-*-notes.md`.

## Launch (lead)

```sh
cd /Users/evgeniyivanov/Projects/home/games/factorio_rts
rm -rf build/qa-p4 && mkdir -p build/qa-p4 && cp -R mods/factorio-rts mods/mod-list.json build/qa-p4/
RTS_LOCALE=en tools/gui-run.sh build/qa-p4 3600 'RTS_QA_END'
```

- **Frozen copy.** The copy keeps other agents' edits out of the run. The log is `build/qa-p4-gui.log`. The script stops
  when the log contains `RTS_QA_END` (step 62), or after one hour. Steam must be running.
- **Language.** `RTS_LOCALE=en` makes the client English. Without it the client follows the system language, which is
  Russian on this Mac; the screenshots in `build/shots-integ-gui/` are Russian for that reason. The steps name the
  English labels, and the glossary below gives the Russian ones.
- **No self-test.** The GUI self-test is off: no script clicks anything, and the game opens in the lobby.
- **Log checks.** Use `grep -nE 'PATTERN' build/qa-p4-gui.log`. Every mod line contains `[rts]`. Where a step lists
  several patterns, each must match.
- **AI doctrine.** It sets when the AI attacks first: `grep -E 'ai rts-ai-1: doctrine' build/qa-p4-gui.log`. On Normal
  that is 3:00 for aggressive, 5:06 for economic and 6:36 for turtle.

## Tester setup

- **Coordinates.** They are game-area coordinates of the 1280×800 game window at UI scale 0.75, the automatic scale.
  On screen, the macOS title bar adds about 28 px to y. Every coordinate is approximate. If an element is not exactly
  there, find it in a screenshot by its description.
- **Inputs.** You have the mouse (left click, right click, Shift + click, Shift + right click, wheel) and the keyboard.
  There is no console and no log. Do not open the console (F9 or backtick).
- **Keyboard.** Use the English (ABC or US) input source. Every Ctrl chord also works with Cmd: Ctrl+A or Cmd+A,
  Ctrl+1 or Cmd+1, Ctrl+Shift+R or Cmd+Shift+R, Ctrl+Shift+E or Cmd+Shift+E. If a Ctrl chord shows no effect, use the
  Cmd chord and say so in the report.
- **Function keys.** macOS may take F3, F10 or F11 (Mission Control, volume, Show Desktop). If one does something
  outside the game, or nothing, use the on-screen alternative the step names (an alert line, the Menu button, the ?
  button) and report it. Then click the game window once on empty ground at (500, 620) to give it focus again.
- **Drags.** A drag often registers as a click. No step needs a drag; step 9 is optional.
- **Time.** The game runs in real time and does not pause while you work. "Wait 20 s" means: watch the timer at the top
  of the screen advance by 20 s. No step needs a fast reaction.
- **Camera.** The map coordinates assume the camera centred on your Command Center at the start zoom. SPACE centres the
  camera but keeps the zoom. Only step 6 zooms, and step 6 restores the zoom.
- **Escape.** Press Escape only to close the research panel, "How to play", the menu or the results window. If the
  Factorio game menu opens instead, press Escape once more.
- **Text fields** (hub panel). Click the field, type the number, press Enter. Keys typed into a field do not reach the
  game.
- **Evidence.** Take a screenshot after every step. Report one of these, with one line on what the screenshot shows:
  - **PASS:** everything under "Expect" is seen.
  - **PARTIAL:** the main effect is there, but a detail differs. Say which.
  - **FAIL:** the main effect is missing.
  - **SKIP:** a precondition is missing. Say which.
- **Time budget.** The session closes after one hour of wall time, and the steps take about 45 minutes. If the strip
  timer passes 45:00, or you have been testing for 50 minutes, go to step 57 and finish.

### Where things are on the HUD

| Element | Location (game area) | Contents |
|---|---|---|
| Top strip | x 370–910, y 6–78 | **Row 1** (y≈22): timer, "Army N", "vs", "Enemies seen: N" ("?" = none in sight), "Supply used/cap", then the buttons **Research [T]** (≈ x 720), **?** (≈ x 790) and **Menu** (≈ x 825). They shift a little with the text. **Row 2** (y≈43): icons with counts for iron, copper, steel, circuits (green chip), explosives, stone and magazines; power "used/available MW" and %; robots idle/total. **Row 3** (y≈62): the message line. |
| Alert lines | x 445–835, y 81–135 | Only while an alert is younger than 15 s. Up to 3 lines, newest on top (y≈94, 110, 126), e.g. red "Base under attack: Command Center  3 s ago". Click a line: the camera jumps there. |
| Kill feed | x 6–200, y 6–60 | Up to 5 lines, e.g. "Walker ✕ (AI 1)" in green (enemy loss) or "Walker ✕ (yours)" in red. |
| Minimap | x 1106–1271, y 9–174 | Centre (1188, 92) is the arena centre, 0.41 px per tile on Medium. Your CC is at ≈(1126, 92), your natural expansion at ≈(1155, 92), your moat's gap at ≈(1162, 92) and the AI's CC at ≈(1251, 92). Black = never seen. A left click moves the camera there. |
| Selection panel, units page | x 6–396, y 699–794 | **Line 1** (y≈713): "No units selected", "Walker ×6" (one type) or "7 units selected"; on the right "HP 100%" and "Order: …". **Line 2** (y≈736): unit cards (icon, count, HP bar) at x≈22, 47, 71, 96, 120, 144; "Groups" and the group buttons 1–5 at x≈231, 266, 301, 336, 371. **Line 3** (y≈763): **Attack-move [F]** (≈56), **Stop [X]** (≈124), **Hold [H]** (≈176), **Select all [Ctrl+A]** (≈250). **Line 4**: a grey hint. |
| Selection panel, building page | same | **Line 1**: name and number ("Barracks #123"), HP on the right. **Barracks:** one row of recipe buttons at y≈735, with text to the right. **Factory:** two rows of recipe buttons at y≈735 and y≈761, 14 per row. Under the grid, a status line at y≈783: the recipe and its state on the left, "Crafted N · to network M" on the right. In both grids, button x = 27 + 26 × index. |
| Build menu | x 1043–1274, y 710–794 | **Header** (y≈724): "Build [B]" … "Q / right-click: done". **Tabs** (y≈744): **Economy** (≈1080), **Production** (≈1150), **Defence** (≈1218). **Slot buttons** (y≈772) at x≈1066, 1097, 1128, 1159, 1190, 1221, 1252, each with the count in your network in its corner. |
| Ability bar | x 461–820, y 729–794 | **Card:** the Commander icon (486, 753), "Commander · Lv 1", a health bar, "Kills: 0 / 5". **Buttons** (y≈752): **Stim** 641, **Shield** 678, **Scanner sweep** 715, **Artillery strike** 752, **Overcharge** 789. Under each button is a thin recharge bar and its key Z, C, V, G or "–", or "27 s" while it recharges. A greyed button cannot be used now. |
| Hub / hauler panel | x 1019–1273, y 183 to ≈470 | Open while a hub or the CC is the selected building, or while only haulers are selected. Close × at (1256, 198). |
| Research panel | centred, x≈248–1032, y≈198–604 | T or Research [T]. Close × at (1013, 211). Tier-1 rows at y≈335 + 24 × row, **Research** buttons at x≈596. |
| How to play | centred, x≈400–880 | F11 or ?. Close × at the window's top right (≈862, 217). |
| Menu | centred, x≈482–797 | F10 or Menu. **Restart** (≈533, 438), **Concede** (red, ≈622, 438; after the match **Results** there), **Resume** (≈745, 438). |
| Results | centred, x≈415–865 | Only when the match ends. **Restart** (≈466, 504), **Continue** (≈810, 504). |

**Factory recipe buttons** (x = 27 + 26 × index):

| Row | Index: recipe |
|---|---|
| 1 (y≈735) | 0 Pause, 1 Hub, 2 Stockpile, 3 Extractor, 4 Smelter, 5 Solar array, 6 Factory, 7 Transport belts, 8 Fast inserters, 9 Medium electric poles, 10 Hauler kit, 11 Lab, 12 Steam plant (grey, locked), 13 Accumulator |
| 2 (y≈761) | 0 Barracks, 1 Turret, 2 Firearm magazines, 3 Laser turret (grey, locked), 4 Wall, 5 Radar, 6 Basic science kit, 7 Advanced science kit, 8 Iron gear wheel, 9 Copper cable, 10 Electronic circuit, 11 Explosives |

**Barracks recipe buttons** (y≈735): 0 Pause (27), 1 Walker kit (53), 2 Heavy walker kit (79, grey), 3 Drone kit (105),
4 Raider kit (131, grey), 5 Artillery kit (157, grey).

**Build menu tabs** (slot index 0–6):

- **Economy:** Extractor, Smelter, Stockpile, Transport belt, Fast inserter, Medium electric pole, Hub.
- **Production:** Barracks, Factory, Lab.
- **Defence:** Turret, Laser turret (grey), Wall, Solar array, Steam plant (grey), Accumulator, Radar.

### Where things are on the map

After SPACE, the camera is centred on your CC at world (−152, 0), and a tile is 16 px:

```
screen x = 640 + 16 × (world x + 152)        screen y = 400 + 16 × world y
```

| Thing | World | Screen (after SPACE) |
|---|---|---|
| Your CC, 4×4, with 4 small stockpiles | (−152, 0) | (640, 400); stockpiles (584, 376), (584, 424), (696, 376), (696, 424) |
| The Commander at the start (big blue spider-tank) | (−146, 0) | body ≈ (736, 368) |
| 6 walkers at the start | x −141.5 and −138; y −3.5, 0, 3.5 | bodies ≈ x 808 and 864, y 296, 350, 407 |
| Iron ore (blue-grey), 12×12 | x −141…−129, y 4…16 | x 816–1008, y 464–656 |
| Copper ore (orange), 8×8 | x −139…−131, y −14…−6 | x 848–976, y 176–304 |
| Stone (beige), coal (black) | (−124, 16), (−116, 16) | (1088, 656), (1216, 656) |
| The CC's power area (dark square while placing) | 36×36 tiles | x 352–928, y 112–688 |
| **Sites used below:** factory / barracks / lab | (−146.5, 8.5) / (−146.5, −8.5) / (−158.5, −8.5) | (728, 536) / (728, 264) / (536, 264) |
| Extractor / smelter / inserter / stockpile | (−139.5, 5.5) / (−138.5, 2.5) / (−137.5, 4.5) / (−137.5, 5.5) | (840, 488) / (856, 440) / (872, 472) / (872, 488) |
| Hub 1, 4×4 (step 23, at the natural iron) | (−91, 13) | off screen: click the minimap at (1153, 98), then the hub is ≈144 px left of the iron patch's centre |
| Barracks rally point / army parking spot | (−132, −5) / (−130, −2) | (960, 320) / (992, 368) |
| Empty ground (to deselect) | (−160.75, 13.75) | (500, 620) |

Robots build only within 40 tiles of the CC and 22 tiles of a hub; beyond that the Commander builds the ghosts within
15 tiles of it, with items from the CC's pool.
The CC's logistic network reaches 25 tiles, so a hub more than 39 tiles away has its own network.

**The natural expansion** (Medium, 1 opponent): your natural iron is a 10×10 blue-grey patch centred at world (−82, 13),
70 tiles in front of the CC, and the natural copper 8×8 at (−82, −13). On the minimap the iron is at ≈(1153, 98). A
minimap click there centres the camera on it within about 2 tiles (32 px).

### Glossary (English → Russian)

| English | Russian |
|---|---|
| Factorio RTS: new match; Opponents; Difficulty; Map size; Map | Factorio RTS: новый матч; Противники; Сложность; Размер карты; Карта |
| Normal; Medium (384×384); Chokepoints; Start match | Нормальная; Средняя (384×384); Узкие проходы; Начать матч |
| Army 7; Enemies seen: ?; Supply 6/40; Research [T]; Menu | Армия: 7; Врагов видно: ?; Снабжение 6/40; Исследования [T]; Меню |
| Destroy the enemy base and army. | Уничтожьте базу и армию противника. |
| No units selected; 7 units selected; Walker ×6 | Юниты не выбраны; Выбрано юнитов: 7; Шагоход ×6 |
| Order: Idle / Move / Hold / Attack-move / Commander / Hauling | Приказ: ожидание / движение / на месте / атака с ходу / Командир / Перевозка |
| Attack-move [F]; Stop [X]; Hold [H]; Select all [Ctrl+A]; Groups | Атака с ходу [F]; Стоп [X]; Стоять [H]; Выбрать всех [Ctrl+A]; Группы |
| Build [B]; Economy; Production; Defence; Q / right-click: done | Стройка [B]; Экономика; Производство; Оборона; Q / ПКМ: готово |
| Placing Factory: left-click the map. R rotates. Q or right-click: done. | Завод: ЛКМ по карте — поставить, R — повернуть, Q или ПКМ — готово. |
| Command Center; Hub; Factory; Barracks; Lab | Командный центр; Хаб; Завод; Казармы; Лаборатория |
| Extractor; Smelter; Stockpile; Walker; Commander; Hauler | Экстрактор; Плавильня; Склад; Шагоход; Командир; Транспортёр |
| Walker kit; Hauler kit; Copper cable; Electronic circuit | Комплект шагохода; Комплект транспортёра; Медный провод; Электронная схема |
| Iron gear wheel; Basic science kit | Железная шестерня; Базовый научный набор |
| Paused: pick a recipe.; running; waiting for; Status: Working | Пауза: выберите рецепт.; работает; ждёт; Состояние: Работает |
| Rally; Rally point …; No rally point … | Сбор; Точка сбора …; Нет точки сбора … |
| Hub 1: stockpile policy; Network #K, 1 hub | Хаб 1: правила склада; Сеть №K, хабов в ней: 1 |
| In network; Keep; Export above | В сети; Держать; Вывоз от |
| Hauler #N; Mode: Auto / Route; Home; Route; State | Транспортёр №N; Режим: Авто / Маршрут; Дом; Маршрут; Состояние |
| Waiting, nothing to carry; pickup and drop-off share one network | ждёт, нечего везти; погрузка и разгрузка в одной сети |
| Parked; Going home; Return home; Resume | стоит; домой; Домой; Продолжить |
| Research; Tier 1: basic kits; Research (button); Cancel | Исследования; Уровень 1: базовые наборы; Изучить; Отмена |
| Available; Queued; Researching N %; Done; Locked | Доступно; В очереди; Идёт: N %; Готово; Закрыто |
| Supply I; Attack I | Снабжение I; Атака I |
| Commander · Lv 1; Kills: 0 / 5 | Командир · ур. 1; Убийств: 0 / 5 |
| Stim; Shield; Scanner sweep; Artillery strike; Overcharge | Стимулятор; Щит; Сканирование; Артудар; Перегрузка |
| The selected units are at full health; Needs research: …; No artillery walker | Выбранные юниты не ранены; Нужно исследование: …; Нет артиллерийских шагоходов |
| Base under attack; Research complete; Commander down | База атакована; Исследование завершено; Командир погиб |
| Menu; Restart; Resume | Меню; Заново; Продолжить |
| Concede; Really concede?; Results; Conceded at mm:ss | Сдаться; Точно сдаться?; Итоги; Сдался на mm:ss |
| Match over; Victory; Defeat; Continue | Матч окончен; Победа; Поражение; Осмотреться |
| How to play | Как играть |

## If an AI attack interrupts

The Normal AI attacks with about 8 to 11 units. The first attack comes at 3:00 on the strip timer at the earliest; it can
also come at 5:06 or 6:36, depending on the AI's doctrine. After that it attacks whenever its army is big enough.

**Signs:**

- a red "Base under attack: …" line under the strip, with a sound;
- a red mark on the minimap;
- "Enemies seen" above 0;
- red spiders near your base, and lines in the kill feed.

Nothing has to happen fast: your units and the Commander shoot back by themselves. When you notice an attack:

1. Finish or abandon the current click. If a building ghost is on the cursor, press Q. Close the research panel or "How
   to play" if one is open.
2. Press F3, or click the red alert line. The camera jumps to the attack.
3. Press Ctrl+A. It selects the combat units and the Commander, never the haulers.
4. Press F, then right-click on the enemies or on the ground next to them. Optional: press C (Shield) while the
   Commander is near the fight.
5. Wait until "Enemies seen" shows "?" again. The AI pulls back after heavy losses.
6. Press SPACE and redo the interrupted step from its start.

Note in the report the strip time, what was attacked and what you lost. Do not restart the paused barracks for this
before step 40: the factory steps need that iron.

## Steps

### Part A: lobby and start

1. **The start dialog.**
   - *Input:* none. Wait until the window shows a dialog in the middle of a black screen.
   - *Expect:*
     - a dialog "Factorio RTS: new match" with four drop-downs: Opponents "1" (≈600, 327), Difficulty "Normal"
       (≈603, 354), Map size "Small (256×256)" (≈620, 381), Map "Chokepoints" (≈610, 408);
     - a grey text on when a side is out, and a green **Start match** button (≈738, 499);
     - at the top, the strip with "--:--", "Army 0", "Supply 0/0" and the message "Choose the match settings and
       press Start match. F11: how to play.";
     - no selection panel, no build menu, no ability bar, and a black minimap.
   - *Pass/Fail:* PASS if the dialog shows the four drop-downs and no match HUD is visible besides the strip and the
     minimap.
   - *Log check (lead):* `lobby: dialog shown to player 1 \(1 opponent\(s\), normal, small, chokes\)`

2. **Choose a Medium map.**
   - *Input:*
     1. Check that Opponents shows 1 and Difficulty shows Normal. If not, click that drop-down and pick the line.
     2. Click the Map size drop-down (≈620, 381). A list opens below it. Click "Medium (384×384)".
     3. Leave Map at Chokepoints.
     4. Optional: hover the Map drop-down for 2 s and take a screenshot of its tooltip.
   - *Expect:* Map size reads "Medium (384×384)", and the other drop-downs are unchanged.
   - *Pass/Fail:* PASS if the drop-downs read 1, Normal, Medium (384×384) and Chokepoints.
   - *Log check (lead):* `lobby: player 1 set size -> 1 opponent\(s\), normal, medium, chokes`

3. **Start the match.**
   - *Input:* click **Start match**. Wait 5 s.
   - *Expect:*
     - **The base.** The dialog closes and the camera is on your base. The Command Center (CC) is at the screen centre
       (640, 400), with 4 small stockpiles at (584, 376), (584, 424), (696, 376) and (696, 424).
     - **Units.** The Commander, a big blue spider-tank, stands just right of the CC, body at ≈(736, 368). The 6
       walkers stand further right, bodies at ≈ x 808 and 864, y 296, 350 and 407.
     - **Ore.** Iron (blue-grey) at x 816–1008, y 464–656; copper (orange) at x 848–976, y 176–304; stone and coal at
       the bottom right.
     - **Strip.** The timer counts from 00:00, with "Army 7" (6 walkers + the Commander), "Enemies seen: ?" and
       "Supply 6/40" (the Commander needs no supply). Iron reads 400 and copper 150. The message reads "Destroy the
       enemy base and army."
     - **Panels.** Bottom left "No units selected"; bottom right the build menu on its Economy tab; bottom centre the
       ability bar with "Commander · Lv 1" and "Kills: 0 / 5".
     - **Minimap.** A lit area on the left with your base at ≈(1126, 92); the rest is black.
   - *Pass/Fail:* PASS if all of this is there. FAIL if the Commander or the ability bar is missing 5 s after the start.
   - *Log check (lead):*
     - `lobby click start player=1`
     - `match: starting match [0-9]+: 1 opponent\(s\), normal, medium \(384x384\), map chokes, brain ai`
     - `mapgen: chokes medium on rts-arena-[0-9]+: moats 2`
     - `match: rts-player CC at \(-152\.0, 0\.0\) facing \+1, starting stock: iron-plate=400 copper-plate=150`
     - `ai rts-ai-1: commander started, difficulty normal`
     - `commander: spawned #[0-9]+ for rts-player at \(-146\.0, 0\.0\) \(spawn 1, level 1`
     - `abilitygui: built for player 1 \(full\) at \(461, 729\)`
     - `minimap zoom 0\.5500`

### Part B: camera

4. **Pan with WASD.**
   - *Input:* move the mouse to the map centre without clicking. Hold D for about 1 s, then release it. Then hold A
     for about 1 s, W for 0.5 s and S for 0.5 s.
   - *Expect:* while D is held, the view scrolls right (the base slides left), and it stops on release. A scrolls left,
     W up and S down.
   - *Pass/Fail:* PASS if each key moves the view its way and the view stops on release. Report how far one second of
     D moved the view, in screen widths.
   - *Log check (lead):* `camera pan player=1 .* d=\(`

5. **SPACE: back to the CC.**
   - *Input:* press SPACE.
   - *Expect:* the CC is back at the screen centre (640, 400).
   - *Log check (lead):* `camera home player=1 -> \(-152\.0, 0\.0\)`

6. **Zoom with the wheel, then back.**
   - *Input:* with the mouse over empty ground near the centre, scroll the wheel down (towards you) 3 notches, one at a
     time. Take a screenshot. Then scroll up the same 3 notches.
   - *Expect:* scrolling down zooms out (everything smaller, more of the map visible), and scrolling up zooms back in.
     At the end, the CC's left and right stockpiles are again about 112 px apart, at x ≈ 584 and 696.
   - *Pass/Fail:* PASS if both directions zoom and the start scale is back. If it is not, scroll one notch at a time
     until the stockpiles are 112 px apart, and report it. Every later map coordinate needs this scale.
   - *Log check (lead):* `camera zoom player=1 0\.500 -> 0\.`, then `camera zoom player=1 .* -> 0\.500`

7. **Minimap jump.**
   - *Input:* left-click the minimap at (1151, 92), inside the lit area and to the right of your base. Take a
     screenshot. Then press SPACE.
   - *Expect:*
     - The camera jumps about 60 tiles east of the CC, to your natural expansion. A 10×10 iron patch is at about
       (784, 592) and an 8×8 copper patch at about (784, 176), give or take 40 px.
     - At the right edge there may be blue water (the moat) above and below a land gap at mid-height, then black.
     - SPACE brings the CC back to the centre.
   - *Pass/Fail:* PASS if the camera jumps and SPACE returns it. The two patches only confirm the place.
   - *Log check (lead):* `hud click minimap player=1 source=mouse .* -> world \(-9[0-9]\.[0-9], `, `camera jump player=1`,
     `camera home player=1`

### Part C: selection

8. **Click, then Shift + click.**
   - *Input:* left-click the body of the top-left walker (≈808, 296). Then hold Shift and left-click the body of the
     bottom-right walker (≈864, 407).
   - *Expect:*
     - After the click, a light-blue box surrounds that walker. The panel reads "Walker ×1", "HP 100%" and "Order:
       Idle", with one card: the walker icon, the number 1 and a green bar.
     - After the Shift + click, two walkers have boxes and the panel reads "Walker ×2".
   - *Log check (lead):* `select mode=replace click n=1 `, `select mode=add click n=2 `

9. **Optional: a short drag.**
   - *Input:* drag with the left button from (760, 270) to (900, 440).
   - *Expect:* all 6 walkers have boxes and the panel reads "Walker ×6". The Commander is outside the drag and stays
     unselected.
   - *Pass/Fail:* PASS as described. If the drag became a click (one walker or none selected), report "drag registered
     as a click", not FAIL.
   - *Log check (lead):* `select mode=replace drag n=6 `

10. **Select all.**
    - *Input:* press Ctrl+A.
    - *Expect:* the 6 walkers and the Commander have boxes. The panel reads "7 units selected" and "Order: Idle 6,
      Commander 1", with two cards: the Commander (number 1, its level) and the walker (number 6). The view does not
      move.
    - *Log check (lead):* `select all n=7 player=1`

11. **Unit cards.**
    - *Input:* left-click the walker card, the second card (≈47, 736). Then press Ctrl+A, hold Shift and click the
      walker card again. Hover a card for 2 s.
    - *Expect:*
      - The click keeps only the walkers selected: "Walker ×6".
      - After Ctrl+A and the Shift + click, only the Commander stays selected: "Commander ×1", "Order: Commander".
      - A card's tooltip lists HP, supply and "Strong vs / Weak vs".
    - *Log check (lead):* `hud click card rts-walker player=1 shift=false -> selected=6`,
      `hud click card rts-walker player=1 shift=true -> selected=1`

12. **Empty click, the CC, deselect.**
    - *Input:* left-click empty ground at (500, 620). Then left-click the CC (640, 400). Then left-click (500, 620)
      again.
    - *Expect:*
      - **First click:** "No units selected".
      - **CC click, selection panel:** an outline around the CC, and the lines "Command Center #N", "HP 3000/3000",
        "Robots idle: construction 20/20, logistic 10/10", "Power: … / 4.00 MW used, machines at 100%" and "Robots
        build ghosts within 40 tiles; the network reaches 25 tiles."
      - **CC click, right edge:** a panel under the minimap, "Command Center: stockpile policy", "Network #N, 1 hub",
        and an item table. Iron 400 and copper 150 are green, and "Export above" reads 100 for iron, copper and steel.
      - **Last click:** the outline and the right panel are gone; "No units selected".
    - *Log check (lead):* `select mode=replace click n=0 `, `select building cc unit=[0-9]+ player=1`,
      `hubgui: hub panel for #[0-9]+ player=1`

### Part D: orders

13. **Move.**
    - *Input:* press Ctrl+A, then right-click empty ground at (480, 560). Wait 10 s.
    - *Expect:* a green circle flashes at the click. The walkers walk there and stop in a loose grid, and the Commander
      walks there too. The order line reads "Move 6, Commander 1", then "Idle 6, Commander 1".
    - *Log check (lead):* `order commander-move n=1 unit=#[0-9]+ dest=\(-16[0-9]\.[0-9], `,
      `order move n=6 dest=\(-16[0-9]\.[0-9], `

14. **Attack-move with F.**
    - *Input:* with the army still selected, press F and take a screenshot. Then right-click ground at (400, 420).
      Wait 10 s.
    - *Expect:*
      - After F, the **Attack-move [F]** button turns red, and the strip's message reads in red "Attack-move armed:
        right-click where to go. F or X cancels."
      - The right click shows an amber circle, and the army walks there. The button turns grey again, and the message
        is back to the match goal.
    - *Log check (lead):* `attack-move armed player=1`, `order commander-attack-move n=1`,
      `order attack-move n=6 dest=\(-16[0-9]\.[0-9], `

15. **Stop.**
    - *Input:* right-click ground far to the left at (120, 600), and press X as your very next action.
    - *Expect:* if the units were still walking, they halt where they are. Either way, the panel shows "Order: Idle 6,
      Commander 1" after X.
    - *Pass/Fail:* PASS if the order line reads Idle and nobody walks on after X. Report whether they stopped halfway
      or had already arrived.
    - *Log check (lead):* `order move n=6 dest=\(-18[0-9]\.[0-9], `, `order stop n=6 player=1`, `order commander-stop n=1`

16. **Hold, and the Stop button.**
    - *Input:* press H and take a screenshot. Then click the **Stop [X]** button (≈124, 763).
    - *Expect:* after H, the panel reads "Order: Hold 6, Commander 1" and nobody moves. After the button, it reads
      "Order: Idle 6, Commander 1".
    - *Log check (lead):* `order hold n=6 player=1`, `hud click stop player=1 result=7 \(rts-stop handlers\)`

17. **Shift + right-click, then park the army.**
    - *Input:*
      1. Hold Shift and right-click ground at (400, 420). Wait 5 s.
      2. Press Ctrl+A and right-click ground at (992, 368). Wait 10 s.
      3. Click empty ground at (500, 620).
    - *Expect:*
      - The Shift + right click shows an amber circle (attack-move), and the army walks there.
      - The second order moves everyone right of the base, onto free ground between the copper and the iron, clear of
        the building sites of Part E.
      - At the end, nothing is selected.
    - *Pass/Fail:* PASS if both orders are followed and the army ends up near (992, 368), outside x 700–900.
    - *Log check (lead):* `order attack-move n=6 dest=\(-16[0-9]`, `order move n=6 dest=\(-13[0-9]\.[0-9], -[0-9]\.[0-9]\)`

### Part E: build menu and production

Before each step of this part, press SPACE if the camera has moved.

18. **Build menu tour.**
    - *Input:*
      1. Hover the 7th Economy button (≈1252, 772) for 2 s.
      2. Click the **Production** tab (≈1150, 744).
      3. Click the **Defence** tab (≈1218, 744), and hover its 2nd button (laser turret, ≈1097, 772).
      4. Click **Economy** again.
      5. Press B, take a screenshot, press B again.
    - *Expect:*
      - **Economy:** 7 buttons with counts: extractor 2, smelter 2, stockpile 2, belt 60, inserter 16, pole 16, and the
        hub with no number. The hub's tooltip reads "Hub … In stock: 0. Factory recipe: [iron] 32 [copper] 10 gives 1
        in 8 s …".
      - **Production:** barracks 1, factory 1, and the lab with no number.
      - **Defence:** 7 buttons. The laser turret and the steam plant are greyed, and their tooltips end "Requires
        research: Laser turrets (T)" and "… Steam power (T)".
      - **B:** the first press hides the whole build menu, and the second shows it again.
    - *Log check (lead):* `hud build tab production player=1: rts-barracks rts-factory rts-lab`,
      `hud build tab defence player=1: rts-turret rts-laser-turret rts-wall rts-solar-array rts-steam-plant rts-accumulator rts-radar`,
      `hud build menu hidden player=1 \(B\)`, `hud build menu shown player=1 \(B\)`

19. **Place the factory, the barracks and a lab.**
    - *Input:*
      1. Open the Production tab.
      2. Click **Factory** (≈1097, 772), then left-click the map at (728, 536).
      3. Click **Barracks** (≈1066, 772), then left-click (728, 264).
      4. Click **Lab** (≈1128, 772), then left-click (536, 264).
      5. Press Q. Wait 20 s.
    - *Expect:*
      - **Placing.** After the Factory button, the button looks pressed, and the message line reads in green "Placing
        Factory: left-click the map. R rotates. Q or right-click: done." A ghost follows the cursor, and a dark
        36×36-tile square shows the CC's power area.
      - **Ghosts.** Each left click leaves a transparent ghost.
      - **Q.** Q ends placing: the message line is back to normal, and no button looks pressed.
      - **Robots.** Within about 20 s, construction robots fly out of the CC and build the factory (below right of the
        CC) and the barracks (above right of the CC).
      - **The lab** stays a ghost: there is no lab in stock yet. Step 24 makes one.
    - *Log check (lead):*
      - `hud click build rts-factory player=1 in_network=1 ghost=true`
      - `build ghost rts-factory player=1 at \(-146\.5, 8\.5\)`
      - `build ghost rts-barracks player=1 at \(-146\.5, -8\.5\)`
      - `build ghost rts-lab player=1 at \(-158\.5, -8\.5\)`
      - `cursor clear \(Q\) player=1`
      - `robot built rts-factory #[0-9]+ at \(-146\.5, 8\.5\)`
      - `robot built rts-barracks #[0-9]+ at \(-146\.5, -8\.5\)`

20. **Place an iron line.**
    - *Input:*
      1. Open the Economy tab.
      2. Click **Extractor** (≈1066, 772), then left-click (840, 488).
      3. Click **Smelter** (≈1097, 772), then left-click (856, 440).
      4. Click **Fast inserter** (≈1190, 772), then left-click (872, 472).
      5. Click **Stockpile** (≈1128, 772), then left-click (872, 488).
      6. Right-click empty ground at (500, 620). Wait 20 s.
    - *Expect:*
      - **Ghosts.** The extractor sits on the top-left corner of the iron ore, and the smelter just above it, shifted
        one tile right. A 1-tile inserter is at the smelter's lower right, with a 1-tile stockpile right below it.
      - **Right click.** It ends placing without ordering anything.
      - **Robots** build all four within about 20 s.
      - **How it works.** The extractor drops ore up into the smelter. The inserter takes plates from the smelter
        above it and puts them into the stockpile below it. All four stand inside the CC's power area, so they need no
        poles.
    - *Log check (lead):*
      - `build ghost rts-extractor player=1 at \(-139\.5, 5\.5\) direction=north`
      - `build ghost rts-smelter player=1 at \(-138\.5, 2\.5\)`
      - `build ghost fast-inserter player=1 at \(-137\.5, 4\.5\) direction=north`
      - `build ghost rts-stockpile player=1 at \(-137\.5, 5\.5\)`
      - `build mode ended item=rts-stockpile player=1 \(right click\)`
      - `robot built rts-extractor #[0-9]+ at \(-139\.5, 5\.5\) direction=north .* drop=\(-139\.5, 3\.[0-9]\)`

21. **Check the iron line.**
    - *Input:* wait another 40 s. Left-click the extractor (840, 488), then the smelter (856, 440), then the
      stockpile (872, 488). Then click empty ground at (500, 620).
    - *Expect:*
      - **Extractor:** "Extractor #N", "Status: Working", "Mining: Iron ore".
      - **Smelter:** "Smelting: Iron plate".
      - **Stockpile:** "Holds N items. Part of the logistic network.", with N above 0 and growing.
    - *Pass/Fail:* PASS if the stockpile holds plates. If it still holds 0 after 60 s, hover the inserter (872, 472)
      and press R, wait 20 s and check again. Repeat up to 3 times, and report how many R presses it took.
    - *Log check (lead):* `select building extractor`, `select building smelter`, `select building stockpile`,
      `robot built fast-inserter #[0-9]+ at \(-137\.5, 4\.5\) direction=north .* pickup=\(-137\.5, 3\.5\) drop=\(-137\.5, 5\.[0-9]\)`

22. **Barracks: recipe, rally point, a first batch.**
    - *Input:*
      1. Left-click the barracks (728, 264).
      2. Hover the greyed third recipe button (heavy walker kit, ≈79, 735) for 2 s.
      3. Click the walker kit button (≈53, 735).
      4. Right-click ground at (960, 320).
      5. Wait 30 s.
      6. Click the Pause button (≈27, 735).
    - *Expect:*
      - **Panel.** "Barracks #N", "HP 1500/1500", and six recipe buttons: Pause (highlighted), walker kit, heavy walker
        kit (grey), drone kit, raider kit (grey) and artillery kit (grey). Then "Paused: pick a recipe." and "No rally
        point. Right-click the ground to set one." A grey flag stands right of the barracks.
      - **Tooltip.** The greyed button's tooltip ends "Requires research: Heavy walkers (T)".
      - **Walker kit.** The button turns yellow, and the panel shows "Walker kit: running" with a progress bar.
      - **Right click.** A green circle; the flag moves there and turns green, with a "Rally" label and a dashed line
        from the barracks. The panel reads "Rally point (-132.0, -5.0). Right-click to move it."
      - **The batch.** In 30 s, about 8 to 10 walkers come out at the barracks' right side and walk to the flag.
        "Army" and "Supply" rise, and iron drops by 10 per walker.
      - **Pause.** "Paused: pick a recipe."; no more walkers come out.
    - *Why pause:* the factory needs the iron for the hub, the lab, the hauler and the science kits. Step 40 starts the
      barracks again.
    - *Log check (lead):*
      - `select building barracks unit=[0-9]+ player=1 at \(-146\.5, -8\.5\)`
      - `hud: recipe buttons barracks#[0-9]+ player=1: pause rts-walker-kit rts-walker-heavy-kit rts-drone-kit rts-raider-kit rts-artillery-kit`
      - `recipe set barracks#[0-9]+ rts-walker-kit ok=true now=rts-walker-kit player=1`
      - `rally set barracks #[0-9]+ -> \(-132\.0, -5\.0\) ok=true player=1`
      - `production: barracks #[0-9]+ \(rts-player\) spawned rts-walker`
      - `recipe set barracks#[0-9]+ none ok=true now=none player=1`

23. **The Commander goes to the natural expansion; a hub ghost next to it.**
    - *Input:*
      1. Click the Commander icon on the ability bar (486, 753) once: only the Commander is selected ("Commander ×1").
      2. Click the minimap at (1153, 98): the camera jumps to your natural iron, a 10×10 blue-grey ore patch near the
         screen centre (about 160 px wide). The Commander stays selected.
      3. Right-click bare ground about 200 px (12 tiles) left of the iron patch's centre. Wait until the Commander
         stands there (it walks about 60 tiles, 5 s; water and trees may make it go around).
      4. In the Economy tab, click **Hub** (≈1252, 772). Left-click the map about 144 px (9 tiles) left of the iron
         patch's centre, at the same height: on bare ground, with about 2 tiles of grass between the ghost and the ore,
         and within 15 tiles (240 px) of the Commander.
      5. Press Q. Leave the Commander there until step 25.
    - *Expect:* the Commander walks to the natural and stops. A 4×4 hub ghost stands just left of the natural iron. It
      stays a ghost for now: there is no hub in stock yet.
    - *Why this way:* the CC's robots build only 40 tiles out, and the natural lies 70 tiles out. The Commander's own
      robots build every ghost within 15 tiles of it, and its trunk is filled from the CC's pool with the items those
      ghosts need. The CC's logistic area (25) and the hub's (14) do not touch at that distance, so Hub 1 gets its own
      network, and step 34 moves cargo between the two networks.
    - *Log check (lead):* `order commander-move n=1 unit=#[0-9]+`, `hud click build rts-hub player=1 in_network=0 ghost=true`,
      `build ghost rts-hub player=1 at \(-9[0-9]\.0, 1[0-9]\.0\)`

24. **Factory: a hub, then a lab.**
    - *Input:*
      1. Left-click the factory (728, 536).
      2. Click the Hub recipe (row 1, index 1, ≈53, 735). Wait until the hub is crafted, about 10 s: the "Crafted"
         number on the status line goes up by 1.
      3. Click the Lab recipe (row 1, index 11, ≈313, 735). Wait 8 s.
      4. Click Pause (≈27, 735).
    - *Expect:*
      - **Panel.** "Factory #N", "HP 1000/1000", and 26 recipe buttons in two rows of 14 and 12. Laser turret (row 2,
        index 3) and Steam plant (row 1, index 12) are greyed. The status line reads "Paused: pick a recipe."
      - **Recipes.** Each recipe click turns that button yellow, and the status reads "[icon] Hub: running" or "[icon]
        Lab: running", with a progress bar.
      - **Pause.** The status reads "Paused: pick a recipe." again.
    - *Pass/Fail:* PASS if both recipes ran. A second hub or lab made before you paused is fine: optional step 56 can
      use a spare hub.
    - *Log check (lead):*
      - `select building factory unit=[0-9]+ player=1 at \(-146\.5, 8\.5\)`
      - `hud: recipe buttons factory#[0-9]+ player=1: pause rts-hub rts-stockpile rts-extractor`
      - `recipe set factory#[0-9]+ rts-hub ok=true now=rts-hub`
      - `recipe set factory#[0-9]+ rts-lab ok=true now=rts-lab`
      - `recipe set factory#[0-9]+ none ok=true`

25. **The hub and the lab get built.**
    - *Input:*
      1. Click empty ground at (500, 620), press SPACE and wait 20 s.
      2. Click the minimap at (1153, 98) and take a screenshot.
      3. Bring the Commander home: click its icon on the ability bar (486, 753), press SPACE, right-click ground near
         the army at (992, 368). Then click empty ground at (500, 620).
    - *Expect:*
      - **Lab.** A lab at (536, 264), built by the CC's robots.
      - **Hub.** At the natural: a real hub (a warm-tinted roboport) where the ghost was, with a small stockpile on each
        side. A few seconds after the factory made the hub, small robots flew out of the Commander and built it.
      - **Strip.** "Supply N/50" instead of /40. Power reads "…/4.3 MW", because the hub adds 300 kW. The robot count
        stays about 30: the strip counts the robots of the CC's network, and the hub's 16 work in its own network.
    - *Log check (lead):*
      - `production: factory #[0-9]+ \(rts-player\) moved 1 rts-hub into the network`
      - `commander: field supply for rts-player at .* stocked \[rts-hub x1\]`
      - `logistics: hub #[0-9]+ \(Hub 1\) of rts-player at \(-9[0-9]\.0, 1[0-9]\.0\): power=true pole=true stockpiles=2 robots=16`
      - `robot built rts-lab #[0-9]+ at \(-158\.5, -8\.5\)`
      - `hud resources player=1 .* supply=[0-9]+/50`

### Part F: hub panel and policies

26. **Select the hub.**
    - *Input:* click the minimap at (1153, 98). Left-click the hub (≈144 px left of the iron patch's centre).
    - *Expect:*
      - **Building page:** "Hub #N", "HP 1200/1200", "Status: Working", "Supply +10. Its own power and robots; its
        own logistic network unless its area touches the Command Center's or another hub's." and "Set what it keeps
        and exports in the panel on the right."
      - **Right panel:** "Hub 1: stockpile policy", "Network #K, 1 hub", "Auto haulers based here: 0. Arriving with
        cargo: 0." and a grey hint.
      - **Item table:** "In network | Keep | Export above", with rows iron (Keep 50), copper (Keep 20), steel, stone,
        coal, and more further down (scroll).
    - *Pass/Fail:* PASS if the panel opens and reads "1 hub" (its own network). FAIL if no panel opens. If it reads
      "2 hubs", report it: the hub then shares the CC's network and step 34 cannot move cargo.
    - *Log check (lead):* `select building hub unit=[0-9]+ player=1 at \(-9[0-9]\.0, 1[0-9]\.0\)`,
      `hubgui: hub panel for #[0-9]+ player=1`

27. **Edit two policies.**
    - *Input:* click the Keep field of the stone row (4th row, ≈1146, 413), type 30 and press Enter. Click the Export
      above field of the coal row (5th row, ≈1200, 446), type 10 and press Enter.
    - *Expect:*
      - The fields show 30 and 10.
      - The stone count (0) turns yellow, because it is below Keep. The coal count stays white, because 0 is not above
        10.
      - The typed digits do nothing else: no control group is recalled.
    - *Log check (lead):* `hubgui policy hub=#[0-9]+ stone keep=30 ok=true`,
      `hubgui policy hub=#[0-9]+ coal export_above=10 ok=true`

28. **Close and reopen the panel.**
    - *Input:* click the panel's × (1256, 198). Click empty ground left of the hub. Click the hub again.
    - *Expect:* × closes the panel while the hub stays selected. After you deselect and select the hub again, the panel
      opens with Keep 30 for stone and Export above 10 for coal.
    - *Log check (lead):* `hubgui click close hub:[0-9]+ player=1`

29. **The CC's policy: a second network; export iron.**
    - *Input:* press SPACE and click the CC (640, 400). Click the **Export above** field of the iron row (1st row,
      ≈1200, 314), select its text, type 0 and press Enter. Then click empty ground at (500, 620).
    - *Expect:*
      - "Command Center: stockpile policy" and "Network #M, 1 hub", with M different from Hub 1's K in step 26: two
        networks.
      - Export above read 100 for iron, copper and steel, with no Keep values. After the edit, iron reads 0 and its
        count turns green: everything above 0 is offered to haulers.
      - The stone count is not yellow here: Hub 1's Keep 30 belongs to Hub 1's network only.
    - *Log check (lead):* `select building cc unit=[0-9]+ player=1`, `hubgui policy hub=#[0-9]+ iron-plate export_above=0 ok=true`

### Part G: hauler

30. **Factory: copper cable, then circuits.**
    - *Input:*
      1. Click the factory (728, 536).
      2. Click Copper cable (row 2, index 9, ≈261, 761). Wait 12 s.
      3. Click Electronic circuit (row 2, index 10, ≈287, 761).
      4. Wait until the strip's circuit count (the green chip, 4th icon of row 2) reads 10 or more, about 25 s.
    - *Expect:* "Copper cable: running", then "Electronic circuit: running", and the circuit count rises. When the
      cable runs out, the status turns yellow with "waiting for [cable]": that is expected.
    - *Pass/Fail:* PASS at 10 circuits. If the count stops below 10, run Copper cable for another 8 s, then Electronic
      circuit again.
    - *Log check (lead):* `recipe set factory#[0-9]+ rts-cable ok=true`, `recipe set factory#[0-9]+ rts-circuit ok=true`,
      `production: factory #[0-9]+ \(rts-player\) moved [0-9]+ electronic-circuit into the network`

31. **Factory: a hauler.**
    - *Input:* still on the factory page, click Hauler kit (row 1, index 10, ≈287, 735). Wait 12 s. Click Pause
      (≈27, 735). Click empty ground at (500, 620).
    - *Expect:* a small blue spider, smaller than a walker, appears right of the factory at about (824, 530). On the
      strip, circuits drop by 10 and iron by 30. "Army" rises by 1 while "Supply" stays the same: haulers need no
      supply.
    - *Log check (lead):* `recipe set factory#[0-9]+ rts-hauler-kit ok=true`,
      `logistics: factory #[0-9]+ \(rts-player\) deployed hauler #[0-9]+, home hub #[0-9]+`

32. **Select the hauler.**
    - *Input:* left-click the hauler's body.
    - *Expect:*
      - A box surrounds it. The panel reads "Hauler ×1" and "Order: Hauling".
      - The right panel "Hauler #N" shows:
        - Mode **Auto** (pressed) and **Route**, and "HP 400/400";
        - "Home: Command Center";
        - "State: Waiting, nothing to carry" in yellow (it may show "Going home: Command Center (N tiles)" first);
        - "Cargo: empty" and "Trips: 0. Delivered: -";
        - the buttons **Return home** and **Resume** (greyed);
        - the hint "Right-click a hub: pickup. Shift + right-click: drop-off. Right-click the ground: move and park."
    - *Log check (lead):* `select mode=replace click n=1 `, `hubgui: hauler panel for #[0-9]+ player=1`

33. **Pickup: right-click the CC.**
    - *Input:* with the hauler still selected, right-click the CC (640, 400).
    - *Expect:* **Route** is pressed. The panel reads "Route: Command Center → Command Center" or "Route: Command
      Center → …" with the state "Waiting, set a pickup … and a drop-off …" or "Idle": the drop-off is still missing.
    - *Log check (lead):* `order route-pickup n=1 hub=#[0-9]+ \(cc\) player=1`

34. **Drop-off: Shift + right-click Hub 1; cargo moves.**
    - *Input:*
      1. Click the minimap at (1153, 98). The hauler stays selected.
      2. Hold Shift and right-click Hub 1 (≈144 px left of the iron patch's centre).
      3. Wait 20 s and watch the hauler panel. Then left-click Hub 1 and look at its iron row.
    - *Expect:*
      - The panel reads "Route: Command Center → Hub 1". The state goes "To pickup", "To drop-off: Hub 1 (N tiles)",
        and after the hauler arrives (it walks about 60 tiles in a few seconds, around the water if needed),
        "Trips: 1. Delivered: [iron] N" with N up to 50.
      - Hub 1's panel shows iron "In network" N (yellow while below its Keep 50). The strip's iron, which counts only
        the CC's network, went down by N.
      - Afterwards the hauler goes back to the CC and waits there with "Waiting, nothing to carry" once Hub 1 holds 50.
    - *Pass/Fail:* PASS when Hub 1's network holds the delivered iron. FAIL if the state stays "Waiting, pickup and
      drop-off share one network" (the hub joined the CC's network) or nothing moves within 60 s.
    - *Log check (lead):* `order route-dropoff n=1 hub=#[0-9]+ \(hub\) player=1`,
      `logistics: hauler #[0-9]+ delivered [0-9]+ iron-plate to hub #[0-9]+ \(trip 1\)`

35. **Auto mode.**
    - *Input:* select the hauler again (click it, wherever it is: press SPACE if it went back to the CC). Click
      **Auto** in the hauler panel (≈1083, 220). Wait 20 s.
    - *Expect:* Auto is pressed, and the panel reads "Home: Hub 1": the drop-off became home. The hauler walks to Hub 1
      and stops just below it. The state reads "Going home: Hub 1 (N tiles)", then it serves Hub 1's Keep from the
      CC's exports ("To pickup …"), or "Waiting, nothing to carry" when Hub 1 already holds 50 iron and 20 copper.
    - *Log check (lead):* `hubgui click mode auto haulers=1 player=1`, `logistics: hauler #[0-9]+ mode auto`

36. **Park, Resume, Return home.**
    - *Input:*
      1. Click the minimap at (1153, 98). Right-click ground about 100 px left of Hub 1. Wait 5 s.
      2. Click **Resume** (≈1130, 329). Wait 5 s.
      3. Right-click the same ground again and wait 5 s.
      4. Click **Return home** (≈1062, 329). Wait 10 s.
      5. Click empty ground and press SPACE.
    - *Expect:*
      - After each ground right click, the hauler walks there and stops. The panel reads "State: Parked" in yellow, and
        Resume is enabled.
      - Resume ends the parked state: the hauler goes home or waits.
      - Return home shows "Going home: Hub 1 (N tiles)", and the hauler walks back to the hub.
      - At the end, nothing is selected.
    - *Log check (lead):* `order hauler-move n=1 dest=\(`, `hubgui click resume haulers=1`,
      `hubgui click return_home haulers=1`, `logistics: hauler #[0-9]+ returns home to hub #[0-9]+`

### Part H: research

37. **The research panel.**
    - *Input:* press T.
    - *Expect:*
      - **Window.** "Research", in the middle of the screen.
      - **Top block.** "No research running. Pick one below.", "Labs: 1 (working: 0)", "In the network: [red kit] 0
        [green kit] 0" and a grey hint.
      - **Left column,** "Tier 1: basic kits": 8 rows, each "Available" with a **Research** button. The rows and their
        kit counts are Attack I 15, Armor I 15, Mining I 11, Logistics I 11, Supply I 8, Heavy walkers 11, Raiders 15
        and Hauler capacity I 11.
      - **Right column,** "Tier 2: advanced kits": 11 rows, some "Available" and others "Locked" with a greyed button.
      - **Tooltip.** Hovering a Locked name shows a tooltip that ends "Requires: …".
    - *Pass/Fail:* PASS if both columns and the top block are there. "Labs: 0" means the lab of step 25 is missing:
      report it.
    - *Log check (lead):* `techgui: rts-tech \(T\) player=1`, `techgui: opened by player 1 \(rts-player\): 19 technologies`

38. **Queue, cancel, close.**
    - *Input:*
      1. Click **Research** on Supply I (≈596, 431).
      2. Click **Research** on Attack I (≈596, 335).
      3. Click **Cancel** on Attack I, in the same place.
      4. Press Escape.
    - *Expect:*
      - Supply I reads "Researching 0 %", its button now reads **Cancel**, and the top line reads "Researching:
        Supply I (0 %)".
      - Attack I reads "Queued" with **Cancel**, then "Available" with **Research** again.
      - Escape closes the window. T or its × close it too.
    - *Log check (lead):*
      - `research: rts-player queued rts-supply-1: true`
      - `research: rts-player queued rts-attack-1: true`
      - `research: rts-player cancelled rts-attack-1: true`
      - `techgui: closed by player 1`

39. **Science kits.**
    - *Input:*
      1. Click the factory (728, 536).
      2. Click Iron gear wheel (row 2, index 8, ≈235, 761). Wait 10 s.
      3. Click Basic science kit (row 2, index 6, ≈183, 761). Wait 60 s.
      4. Click empty ground.
    - *Expect:* "Iron gear wheel: running", then "Basic science kit: running", with one kit every 5 s. When the gears run
      out, the status turns yellow with "waiting for [gear]". That is expected: by then the factory has made about 10
      kits.
    - *Log check (lead):* `recipe set factory#[0-9]+ rts-gear ok=true`, `recipe set factory#[0-9]+ rts-science-basic ok=true`,
      `production: factory #[0-9]+ \(rts-player\) moved 1 rts-science-basic into the network`

40. **The lab at work; the barracks back on.**
    - *Input:*
      1. Click the lab (536, 264) and take a screenshot.
      2. Click the barracks (728, 264), then the walker kit (≈53, 735).
      3. Click empty ground at (500, 620).
    - *Expect:*
      - **Lab page:** "Lab #N" and "Researching Supply I: N%", with N rising. The third line reads "Takes science kits
        from its logistic network. More labs research faster.", or "Waiting for [kit] in its logistic network" while
        the lab has none.
      - **Barracks:** it makes walkers again, and they gather at the flag. Keep it running from now on: these walkers
        are the army for Part N.
      - Supply I needs 8 kits × 10 s, about 80 s with one lab. Go on with Part I meanwhile.
    - *Log check (lead):* `select building lab unit=[0-9]+`, `research: lab #[0-9]+ \(rts-player\) researching`,
      `recipe set barracks#[0-9]+ rts-walker-kit ok=true`

### Part I: abilities

41. **The ability bar.**
    - *Input:* hover each of the five ability buttons for 2 s, and take a screenshot of each tooltip.
    - *Expect:*
      - **States.** Stim (Z) is greyed while nothing is selected, and Shield (C) is available. Scanner sweep (V),
        Artillery strike (G) and Overcharge are greyed. The label under Overcharge is "–".
      - **Tooltips.** Each has the name, "Hotkey: Z" (Overcharge: "No hotkey: click the button"), a description and
        "Cooldown: N s". Scanner sweep and Overcharge add "Needs research: …". A greyed button shows its reason in red,
        e.g. "Select units first" or "No artillery walker".
    - *Pass/Fail:* PASS if the five tooltips match this.

42. **Stim refused on healthy walkers.**
    - *Input:* press Ctrl+A, then click the walker card (≈47, 736), so only walkers stay selected. Press Z.
    - *Expect:* a short floating text at the mouse, "The selected units are at full health". Nothing else changes, and
      there is no countdown under Stim. If an earlier attack damaged a walker, Stim works instead: green rings, iron −10
      per damaged unit and "30 s" under Stim. Report which happened.
    - *Log check (lead):* `ability stim refused player=1 force=rts-player: [0-9]+ units at full health`, or
      `ability stim player=1 .* healed=[1-9]`

43. **Stim on the Commander.**
    - *Input:* click the Commander icon on the ability bar (486, 753). Press Z.
    - *Expect:* the click selects the Commander ("Commander ×1"). Z flashes a green ring around it, the label under Stim
      counts down from "30 s", and the button stays greyed until ready. Stim on the Commander costs no iron and speeds
      it up for 8 s.
    - *Log check (lead):* `commander: selected #[0-9]+ player=1`,
      `ability stim player=1 force=rts-player selected=1 healed=0 .* sped=1`

44. **Shield.**
    - *Input:* press C.
    - *Expect:* for 10 s a blue ring shows on the Commander and on each of your units within 8 tiles of it, with a faint
      blue circle around the Commander. "45 s" counts down under Shield.
    - *Log check (lead):* `ability shield player=1 force=rts-player commander=#[0-9]+ units=[0-9]+ radius=8`

45. **Locked abilities.**
    - *Input:* press V. Press G. Click the Overcharge button (789, 752).
    - *Expect:*
      - V shows the floating text "Needs research: Scanner sweep". G shows "No artillery walker".
      - The Overcharge click does nothing: the button stays disabled until the Overcharge research, a tier-2 technology
        that needs advanced kits.
      - No ability is armed: the card line does not change to "Target: …".
    - *Pass/Fail:* PASS if both messages appear and the Overcharge click does nothing.
    - *Log check (lead):* `ability scanner refused player=1`, `ability artillery refused player=1`; no
      `abilitygui: click overcharge` line

### Part J: the Commander

46. **Card: select, then jump.**
    - *Input:* press Ctrl+A. Click the Commander icon (486, 753) once and take a screenshot. Then click it again.
    - *Expect:* the first click selects only the Commander ("Commander ×1", HP, "Order: Commander"). The second click
      centres the camera on it.
    - *Log check (lead):* `commander: selected #[0-9]+ player=1`, `commander: camera to #[0-9]+ player=1`

47. **Move and stop.**
    - *Input:* right-click ground about 10 tiles left of the Commander (≈480, 400). Wait 5 s. Right-click ground far
      away (≈100, 650), and press X as your next action.
    - *Expect:* a green circle, and the Commander walks to the first point. After the second order and X, it stops where
      it is, if it was still walking.
    - *Log check (lead):* `order commander-move n=1 unit=#[0-9]+`, `order commander-stop n=1 unit=#[0-9]+ player=1`

48. **Attack-move, then back to the army.**
    - *Input:*
      1. Hold Shift and right-click ground at ≈(800, 400). Wait 5 s.
      2. Press F, then right-click ground at ≈(640, 300). Wait 5 s.
      3. Press SPACE, right-click near the army at (992, 368), then click empty ground at (500, 620).
    - *Expect:* the Commander walks to each point, firing by itself at enemies in range on the way. After the F order,
      the Attack-move button is grey again. It ends next to the army.
    - *Log check (lead):* `order commander-attack-move n=1` (twice), then `order commander-move n=1`

### Part K: supply

49. **Supply display.**
    - *Input:*
      1. Press SPACE.
      2. Press T, check the Supply I row and press T again. If Supply I is not done yet, go on with Part L and check
         later.
      3. Hover "Supply N/M" on the strip for 2 s.
    - *Expect:*
      - **Research.** Supply I reads "Done" in green.
      - **Strip.** "Supply N/60": 40 from the CC, 10 from the hub and 10 from Supply I. N is the number of walkers,
        that is, "Army" minus the Commander and the hauler.
      - **Colour.** The text is white, yellow from 90 % of the cap and red at the cap.
      - **Tooltip.** "Supply used / cap. Walker and drone 1, raider 2, heavy 3, artillery 4; haulers and the Commander
        are free. Cap: 40 with a Command Center, +10 per hub, +10 per Supply research. At the cap the barracks wait."
      - **At the cap** (if you got there): the barracks page shows in red "Supply cap N/M: Walker waits", and a yellow
        alert "Supply blocked …" appears.
    - *Log check (lead):* `research: rts-player finished rts-supply-1`, `hud resources player=1 .* supply=[0-9]+/60`

### Part L: alerts

50. **Alert lines.**
    - *Input:* none. Watch the area under the strip whenever something happens, and use any screenshot from the moment
      Supply I finished or from an attack.
    - *Expect:*
      - **Research.** When Supply I finished, a green line "Research complete: Supply I  N s ago" appeared under the
        strip and faded after 15 s, with a chat line too.
      - **Attacks.** During an AI attack, a red line "Base under attack: [icon] <building>" appears, with a sound and a
        red mark on the minimap for 10 s.
    - *Pass/Fail:* PASS if you saw the research line. Report every other alert you saw, with its strip time.
    - *Log check (lead):* `research: rts-player finished rts-supply-1`, `hud: alert base-attacked for rts-player`,
      `hud: minimap ping base-attacked`

51. **F3 and alert clicks.**
    - *Input:* press SPACE, then F3, and take a screenshot. Press F3 again as your next action. If a red alert line is
      visible at any later time, click it.
    - *Expect:*
      - F3 moves the camera to the newest alert that has a place: base under attack, Commander down or supply blocked.
        The research line has no place.
      - F3 again soon after moves to the next older one.
      - A click on an alert line also jumps there.
    - *Pass/Fail:* PASS if the camera moved to an attack site. SKIP if no alert with a place has happened yet; then
      repeat this step after step 54.
    - *Log check (lead):* `hud alert jump player=1 source=F3 kind=`, or
      `hud alert jump player=1 source=F3: no alert with a position`; `hud alert jump player=1 source=click line=`

### Part M: control groups

52. **Assign groups.**
    - *Input:*
      1. Press SPACE, then Ctrl+A.
      2. Shift + click the hauler card (the last card, ≈71, 736) to drop the hauler.
      3. Press Ctrl+1.
      4. Click the Commander icon (486, 753), then press Ctrl+2.
    - *Expect:* after Ctrl+1, group button 1 reads "1: N" (the army, Commander included) and looks pressed. After
      Ctrl+2, button 2 reads "2: 1" and looks pressed. Buttons 3 to 5 stay greyed.
    - *Log check (lead):* `hud click card rts-hauler player=1 shift=true`, `group set 1 n=[0-9]+ player=1`,
      `group set 2 n=1 player=1`

53. **Recall.**
    - *Input:*
      1. Press 1, then 2.
      2. Press SPACE, then press 1 twice in quick succession (as one "1 1" key action if your tool allows).
      3. Click the group button "1: N" (≈231, 737).
      4. Press 3.
    - *Expect:*
      - 1 selects the army ("N units selected", with boxes), and 2 only the Commander.
      - The double press also moves the camera to the army.
      - The button click selects the army, like 1.
      - 3 does nothing: the group is empty, and the selection stays.
    - *Pass/Fail:* PASS if 1, 2 and the button recall their groups. Report whether the double press moved the camera:
      it needs two presses within a third of a second.
    - *Log check (lead):* `group recall 1 n=`, `group recall 2 n=1`, `double-tap camera ->`,
      `hud click group 1 player=1 selected=`, `group recall 3 empty player=1`

### Part N: a fight

54. **Fight an attack.**
    - *Input:*
      1. Press 1 to select the army.
      2. If enemies are at your base now, press F and right-click on them.
      3. Otherwise wait at the base for up to 3 minutes of strip time, pressing SPACE now and then.
      4. If no attack comes, go and meet it. Click the minimap at (1158, 92), just west of your moat's gap, then press
         1, press F and right-click the screen centre (640, 400). The army attack-moves to the land in front of the
         gap. Wait there for up to 3 more minutes. When red units appear, press F and right-click on them.
    - *Expect:*
      - The army fights. Enemy losses show green kill-feed lines at the top left, such as "Walker ✕ (AI 1)", and your
        losses red "(yours)" lines.
      - "Enemies seen" counts the enemies in sight.
      - The Commander hits from range, and "Kills: k / 5" rises when its rockets kill.
    - *Pass/Fail:* PASS if a fight happened and the kill feed and the counts reacted. Report the strip time, the losses
      on each side, and whether the base took damage.
    - *Log check (lead):* `order attack-move n=[0-9]+`, `commander: #[0-9]+ of rts-player killed`,
      `ai rts-ai-1: (attack|harass) #[0-9]+`

55. **During and after the fight: Shield, Stim, levels.**
    - *Input:* during the fight, when the Commander is near the enemies, press C if Shield is ready. After the fight,
      press 1 and then Z. Then press SPACE, press 1 and right-click (992, 368).
    - *Expect:*
      - **C:** as in step 44.
      - **Z after the fight:** damaged units get a green ring and heal 30 %. Iron drops by 10 per healed unit, and
        "30 s" counts down under Stim.
      - **Level 2:** if the Commander reached 5 kills, the card reads "Commander · Lv 2", with the chat line "Commander
        reached level 2: shield +400".
      - **Death:** if the Commander died, the card reads "Down: back in N s", with a red alert "Commander down: back in
        60 s". 60 s later it reappears next to the CC, with a green alert "The Commander is back at the Command
        Center".
    - *Pass/Fail:* PASS if Stim healed damaged units; report "no damaged survivors" otherwise. Report the Commander's
      level, kills and deaths.
    - *Log check (lead):* `ability shield player=1`, `ability stim player=1 .* healed=[1-9]`, `commander: rts-player level 2`,
      `commander: #[0-9]+ of rts-player died`

56. **Optional: a hub at the middle iron, built by the Commander.** Only if the strip timer is below 35:00.
    - *Input:*
      1. Click the barracks and click Pause, so that the factory gets the iron.
      2. If the Hub button in the Economy tab shows no number, click the factory and the Hub recipe, wait until the Hub
         button shows 1, then click Pause.
      3. Click the Commander icon on the ability bar (486, 753) once, so that only the Commander is selected.
      4. Click the minimap at your moat's gap (≈1162, 92): the land between two water bands in front of your base.
         Right-click that land. Wait until the Commander stands there (water stops it, so it goes through the gap).
      5. Click the minimap at the middle iron (≈1188, 82): a 14×14 blue-grey patch north of the ruin in the arena centre.
         In the Economy tab, click **Hub** and left-click the map about 3 tiles (≈48 px) left of the patch's left edge.
         Press Q. The ghost stays a ghost: it is 140 tiles from the CC and 90 from Hub 1.
      6. Right-click the ground right next to the ghost. Wait until the Commander stands there, then wait 20 s more.
      7. Press SPACE, click the barracks and click the walker kit again.
    - *Expect:*
      - **Build.** A few seconds after the Commander arrives, small robots fly out of it and build the hub. The Hub
        count in the build menu goes down by 1: the CC's pool paid for it.
      - **Supply.** The strip's supply cap rises by 10.
      - **Panel.** Left-click the new hub: "Hub 2: stockpile policy", "Network #…, 1 hub".
    - *Pass/Fail:* PASS if the hub is built within 30 s of the Commander's arrival. FAIL if it stays a ghost. SKIP if the
      Commander cannot reach the patch; say where it stopped.
    - *Log check (lead):* `commander: field supply for rts-player at .* stocked \[rts-hub x1\]`,
      `logistics: hub #[0-9]+ \(Hub 2\) of rts-player`

### Part O: menu, help, results, end

57. **The match menu.**
    - *Input:*
      1. Press F10, or click **Menu** on the strip if F10 does nothing. Take a screenshot.
      2. Click **Resume**.
      3. Click **Menu** on the strip, then press Escape.
    - *Expect:*
      - A dialog "Menu" with "1 opponent · Normal · Medium (384×384) · Chokepoints", "Match time: mm:ss", and the
        buttons **Restart** (left), **Concede** (red, middle) and **Resume** (right).
      - Resume and Escape close the dialog, and the camera does not move. Do not click Concede yet (step 59).
    - *Log check (lead):*
      - `lobby: rts-menu \(F10\) player=1`
      - `lobby: menu opened by player 1`
      - `lobby click resume player=1`
      - `hud click menu player=1`
      - `lobby: menu closed by player 1 \(Escape\)`

58. **How to play.**
    - *Input:* press F11, or click **?** on the strip. Take a screenshot. Press F11 again, or Escape, or the window's ×.
    - *Expect:* a centred window "How to play" with 10 paragraphs headed Goal, Controls, Economy, Build order, Hubs,
      Haulers, Research, Supply, Counters and Alerts. It closes again.
    - *Pass/Fail:* PASS if it opens and closes. Report any clipped text.
    - *Log check (lead):* `hud help opened player=1 \((F11|\? button)\): 10 lines`, `hud help closed player=1`

59. **Concede, the results window, Results again.**
    - *Input:*
      1. Click **Menu** on the strip (or press F10). Click **Concede** (red, ≈622, 438) once. Take a screenshot.
      2. Click the same button, which now reads **Really concede?**, within 5 s.
      3. Take a screenshot of the "Match over" window, then click **Continue**.
      4. Click **Menu** again. Click **Results** (middle button). Take a screenshot, then click **Continue**.
    - *Expect:*
      - **First click.** The match goes on; the button turns into "Really concede?". A second click more than 5 s
        later only asks again.
      - **Second click.** The menu closes and a centred window "Match over" opens: a big red "Defeat", "Defeat. You
        conceded the match.", "Match time: mm:ss" and the settings line. The table has the columns Side, Units built /
        lost, Buildings built / lost and Status; "You" reads "Conceded at mm:ss" and "AI 1 (Normal)" reads "Winner".
        The strip's message line reads "Defeat. You conceded the match." in red. Buttons: **Restart** and **Continue**.
      - **Continue** closes the window; the arena stays visible.
      - **Menu after the match** has **Restart**, **Results** and **Resume**, and no Concede. **Results** opens the same
        window again.
    - *Log check (lead):* `lobby: concede armed by player 1`, `match: rts-player concedes at`,
      `match: ended at tick [0-9]+ .* winner=rts-ai-1, result for rts-player=defeat`,
      `lobby: results shown to player 1: defeat` (twice), `lobby click results player=1`

60. **Restart with Ctrl+Shift+R.**
    - *Input:* press Ctrl+Shift+R. Wait 5 s.
    - *Expect:*
      - A new match with the same settings: the camera on a fresh base, the timer from 00:00, "Army 7", "Supply 6/40"
        and iron 400.
      - No factory or barracks is placed, and the Commander is "Lv 1".
      - T shows Supply I "Available" again; close the panel with T.
    - *Log check (lead):* `qa hotkey /rts-qa-reset nowaves player=1`,
      `match: starting match [0-9]+: 1 opponent\(s\), normal, medium \(384x384\)`, `qa-reset by player=1: match [0-9]+ -> [0-9]+`

61. **Menu → Restart → lobby → Start.**
    - *Input:* click **Menu**, then **Restart**. Take a screenshot of the dialog. Click **Start match** and wait 5 s.
    - *Expect:* Restart leaves the match and shows the start dialog over black, already set to 1, Normal, Medium
      (384×384) and Chokepoints. Start match begins a new match, as in step 3.
    - *Log check (lead):*
      - `lobby click restart player=1`
      - `lobby: back in the lobby \(restart by player 1\)`
      - `lobby: dialog shown to player 1 \(1 opponent\(s\), normal, medium, chokes\)`
      - `lobby click start player=1`

62. **End the session.**
    - *Input:* press Ctrl+Shift+E (or Cmd+Shift+E).
    - *Expect:* a few chat lines with a state summary at the bottom left, then the game window closes about 3 s later.
    - *Pass/Fail:* PASS if the window closes. If neither chord does anything, report FAIL; the lead's script stops after
      one hour anyway.
    - *Log check (lead):* `qa hotkey /rts-qa-end player=1`, `RTS_QA_END by player=1`

## Recovery

- **The camera is somewhere else.** Press SPACE.
- **The scale differs** from step 6: scroll the wheel one notch at a time until the CC's stockpiles are 112 px apart.
- **Clicks select nothing.** Press F1: it gives the RTS cursor back.
- **A ghost is stuck on the cursor.** Press Q, right-click, or press F1.
- **A ghost is in the wrong place.** Leave it and place a correct one. Robots build a ghost only when the network holds
  its item.
- **A panel hides what you need to click.** Close it with its ×, or with Escape for the research panel, "How to play" and
  the menu.
- **A key does nothing.**
  - Make sure no text field has focus: press Enter, or click empty ground at (500, 620).
  - For a Ctrl chord, try the Cmd chord.
  - For F3, F10 or F11, use the alert line, the Menu button or the ? button.
- **The RTS view is gone** (you see a character, vanilla Factorio menus or no HUD). Wait 2 s: the mod restores the view.
  If it does not, report FAIL with a screenshot.
- **The factory waits for iron for more than a minute.** Pause the barracks (barracks page, Pause button) until the
  factory step is done, then set the walker kit again.
- **The hauler walked off or is parked.** Select it and click **Resume** or **Return home**.
- **The state is broken** (most of the base lost, units gone). Press Ctrl+Shift+R: it starts the same match again on a
  new arena. Then redo what the next step needs:
  - 19–22: factory, barracks, iron line;
  - 23–25: the hub;
  - 30–31: the hauler;
  - 37–39: research.

  Report the restart.

## Results to report

- One line per step: PASS, PARTIAL, FAIL or SKIP, with what the screenshot shows.
- Every AI attack: its strip time, what it hit, and the outcome.
- The Commander: its highest level, kills and deaths.
- The final strip values before step 60: Army, Supply and iron, and which research is done.
- Any text that is clipped, overlaps, shows a raw key (`rts.…`, "Unknown key") or is in the wrong language.
- Any element more than about 30 px from its given coordinates.
- Which function keys or Ctrl chords failed, and whether the Cmd chord or the on-screen alternative worked.

## Not covered

- **A mining outpost at the natural.** Step 34 moves iron from the CC to Hub 1; extractors and smelters at Hub 1
  with an export policy that ships their plates home take several more minutes. The headless logistics autotest and
  the economic AI cover that loop and the moat routes.
- **Tier-2 research and what it unlocks.** Advanced kits need steel from a second smelter fed with plates. That includes
  Scanner sweep and Overcharge casts, the targeted-ability arm and cancel, laser turrets, steam power and artillery.
  Heavy walkers and raiders are tier 1 but are not researched here. The headless research and abilities probes cover
  these.
- **Other buildings:** turrets, walls, radar, solar arrays, accumulators, belts and poles.
- **Other map features and setups:** the ruin capture, depletion alerts, the Large map, 2 or 3 opponents, Open field.
- **A real victory:** destroying a Normal AI takes far longer than this session; step 59 covers the defeat path.
- **Multiplayer and save/load.**
