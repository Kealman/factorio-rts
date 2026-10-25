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
way), `dtap CODE` (a double tap), `wheel N` and `sleep MS`; `tools/gui-drive.sh` passes every argument of an
`RTS_DRIVE` line through (b2e3021).

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
| `build/r2-i5` | HEAD (2bde7e7 and later), the repository's `tools/gui-drive.sh` | 28/29: the two presses of the double tap came 21 ticks apart (each "key" line first brings the window to the front), one tick over the double-tap window |
| `build/r2-i7en`, `build/r2-i7ru` | HEAD 214a05d, the repository's driver; the double tap as one `dtap` command, the walkers stopped before the group checks | **29/29** and **29/29**, 0 Lua errors |
| `build/r2-smoke12b` | HEAD + fixes + the help text | Skirmish smoke 65/65, 0 errors |

Screenshots: `build/shots-r2-i4-{en,ru}/` (game area) and `build/shots-r2-i4-{en,ru}-window/` (with the title bar); the
game menu after Escape is `r2i-e02-escape.png`.

## 2. Issue #11: the look of the RTS buildings on 2.1

Every RTS building copies a vanilla sprite, and 2.1 shipped new assembling-machine and oil-refinery art. The probe
`tools/probes/r2_look_gui.lua` starts a Nation match (2048, one AI, Survey), lays a grass yard next to the capital and
places one of every RTS building prototype (each `rts-*` entity of a building type that is not hidden: 50) and 15
vanilla sources, then takes a close-up of each at zoom 1 and line-ups at the play zooms 0.5 and 0.25 (the mod's render
objects, land borders and labels, are hidden for the shots). Nothing is registered or powered, so every building shows
its idle frame.

Evidence (all under `docs/qa/phase5-screenshots/`, `git add -f`):

- `r2-look-all-1.png`, `r2-look-all-2.png`: the 50 RTS buildings at zoom 1, after the changes below.
- `r2-look-vanilla-2.1.png`: the 15 vanilla sources on 2.1.
- `r2-look-lineups.png`: seven line-ups at zoom 0.5 (Age I, factory and barracks next to the vanilla assembling machine
  2 and the lab, the ten Age II districts, the Age II machines next to their sources, Age III, the Nation buildings,
  defence and power).
- `r2-look-changed.png`: the eight changed buildings, 0.1.0 above and 0.1.1 below.

Raw shots: `build/shots-r2-l1-en/` (0.1.0), `build/shots-r2-l4-en/` (0.1.1). Skirmish smoke on the changed tree: 65/65,
0 errors (`build/r2-smoke11b`).

### 2.1 Verdicts

**The 2.1 art itself reads well.** No layer is misaligned, no shadow detached, and the machines rescaled by
`age2.rescale` (the 5×5 districts from 3×3 and 4×4 sources) keep their proportions. The problem was telling buildings
apart: 2.1's assembling machine 3 is green, its assembling machine 2 has a blue trim, and several RTS tints on top of
them landed on the same hue.

| Building | Look (vanilla source, tint) | On 2.1 | 0.1.1 |
|---|---|---|---|
| Factory | assembling machine 2 | reads, but the barracks is the same picture | unchanged (blue trim) |
| **Barracks** | assembling machine 2, no tint | **identical to the factory** (and to the vanilla machine), pixel for pixel | khaki on the machine layers (its map colour), the icon too |
| **Electronics plant** (district) | assembling machine 3, pale red | reads as the orange **Munitions works** next to it | teal |
| **Electronics II plant** (Age III) | assembling machine 3, pale blue | on the green 2.1 machine it reads as the Electronics plant | deep blue |
| **Petrochemical works** (district) | oil refinery 5×5, pale violet | **the Refinery** next to it, at play zoom | deep blue-violet |
| Munitions works, Concrete works, Rail works | assembling machine 2 / 2 / 1, orange / tan / grey | read (and are 5×5 against the 3×3 factory and barracks) | unchanged |
| Refinery, Chemical plant, Oil well | the vanilla oil refinery, chemical plant, pumpjack | read: they are the vanilla machines | unchanged |
| Smelting, Steel, Circuits, Engines, Construction, Science, Chemistry districts | electric furnace, foundry, electromagnetic plant, centrifuge, cryogenic plant, lab, chemical plant | read: each has its own shape | unchanged |
| **Field depot** | roboport, olive | **the City Center** (roboport, green) at any zoom | violet |
| Command Center, hub, rail depot, City Center, trade post | roboport: grey, warm, blue, green, gold | read | unchanged |
| **Fishing hut** | market stall, pale blue | **the house** (the same stall, 3×3) | strong teal |
| House, apartment, farm, bakery | market stall warm / 5×5 blue, agricultural tower, stone furnace | read | unchanged |
| **AA turret** | gun turret, pale blue | **the gun turret**: the force colour on both masks hid the tint | strong cyan |
| **Fort** | gun turret, pale tan | **the gun turret**, for the same reason | strong earth orange |
| Gun turret, laser turret, bunker (3×3), wall, gate | vanilla | read | unchanged |
| Extractor, rare extractor (violet), smelter, stockpile, lab, solar array, accumulator, steam plant, radar | vanilla | read | unchanged |
| Airfield, nuclear plant, Launch complex (8×8), Railway Charter site (6×6), depot stop | own picture, reactor, rocket silo platform, train stop | read | unchanged |

Only tints changed: no sprite file, size, collision box or behaviour. Every change is a tint of the non-shadow layers
(shadows, glows and lights keep theirs) and of the icon where the building had its own icon tint.

### 2.2 Release screenshots to regenerate

The changed buildings stand in these release shots of `docs/media/` (scenes in `tools/probes/showcase_*.lua`):

| Shot | What changed in it |
|---|---|
| 02-capital, 03-rail-line, 08-space-program, 15-city-panel | the capital's barracks (the AI-baked capital), districts |
| 05-front-fort-belt | the fort belt's field depots and AA turrets (the scene gives 3 and 8) |
| 06-air | the AA turret in the middle of the frame |
| 07-artillery-train | the barracks of the dressed enemy town |
| 13-commander-abilities, 14-skirmish-base | the Skirmish base's barracks |

01-lobby changes with issue #16 (the lobby's "Guided objectives" switch), and every in-match shot would show the
objective strip in a fresh save's first match: the showcase scenes must switch it off first (section 3).

## 3. Issue #16: guided objectives

`scripts/objectives.lua` (new, registered in `control.lua` after the HUD, the lobby and every module whose events tick a
step) shows an **objective strip** at the top edge between the match strip and the minimap: "Objectives 2/7", the
current step in yellow with a hint under it, an arrow that shows or hides the list of all seven steps (remembered per
player) and a × that hides the strip for the rest of the match. A step done early ticks off at once; the current step is
the first one not done. When all seven are done the strip says so ("All objectives done" and what wins the match) and
goes after 45 s.

**The switch.** The lobby has a "Guided objectives" checkbox at the left of its button row, so the dialog keeps its
size and every lobby coordinate of the protocols holds (`lobby.on_dialog`, a hook of `scripts/lobby.lua`). Until a player
touches it, the strip is on for that player's first Skirmish match and first Nation match and off afterwards; once
touched, the choice is remembered in `storage.objectives.players[i].pref`. `objectives.set_pref(i, false)` does the
same from script (the showcase scenes need it, see below).

| Mode | Step | Ticks when |
|---|---|---|
| Skirmish | Select your walkers | the player has a unit selected |
| | Build an extractor | the force places an extractor (`buildings.on_added`) |
| | Place the barracks | the force places a barracks |
| | Train a unit | a barracks of the force turns a kit into a unit (`production.on_spawned`) |
| | Research a technology | a technology of the force is researched (`on_research_finished`) |
| | Build a hub at the next ore | the force places a hub |
| | Destroy an enemy unit or building | the force kills a unit or building of another match force (`on_entity_died`) |
| Nation | Open your capital's panel | the player's city panel is open |
| | Feed your people | the force has placed a fishing hut, or a farm and a bakery |
| | Build a house | the force places a house or an apartment |
| | Found a town | a city of the force that is not the capital is founded (`rts_city_founded`) |
| | Open a rail line | a line of the force is open (`rails.lines_of`) |
| | Reach Age II | the force is in Age II or later |
| | Sign a treaty or go to war | any diplomatic state of the nation changes, or a contract with it is created |

**Determinism.** The module only reads game state and writes its own storage and GUI. Steps tick from game events,
script signals and synchronised GUI state (the selection, an open city panel), never from client-side state, and only for
forces with a player whose strip is on; buildings placed while a match is being set up do not count. The Skirmish smoke
is unchanged: 65/65, 0 errors (`build/r2-smoke16`), and the module writes no log line without a connected player.

**Help and texts.** The F11 page mentions the strip in both modes (Skirmish "Alerts" paragraph, Nation "Keys"
paragraph). Texts are in `locale/{en,ru}/objectives.cfg` (`[rts-objectives]`).

**Layout.** At 1280×800 (UI scale 0.75) the strip is x 916–1096 from y 6: about 105 px tall with the hint, about 210
with the list. It never covers the strip, the minimap, the world generation line or the alerts. The right-hand panels
(city, depot, hub, train) start at y 183 and open over it when the list is shown. A window narrower than the strip plus
the minimap puts it under the minimap instead.

### 3.1 GUI probe

`tools/probes/r2_objectives_gui.lua` (27 checks; the lobby switch, the list arrow, the × and the first selection by
real clicks and drags, the other steps by script the way the game does them, each checked on the strip a moment later):

| Part | Checks |
|---|---|
| A, lobby of a fresh save | the switch is on (auto); a real click turns it off, a second one on (remembered) |
| B, Skirmish | Start; the strip 0/7; a box select ticks "select"; extractor, barracks, a walker from the barracks, a research, a hub, an enemy walker killed; 7/7 and the done text; the arrow shows the list; the × hides the strip |
| C, Nation | after Restart with the switch back on auto: Skirmish off, Nation on, the Nation dialog's switch on; Start; 0/7; the city panel, a farm and a bakery, a house, a town, an open line (`rails.lines_of` answers one open line for that check: laying a real line takes minutes), Age II, a war; 7/7 |
| D, Skirmish again | the switch is off (auto), and the second Skirmish match has no strip |

Coordinates per locale are in the probe (`LAYOUT`): the lobby switch (≈499, 513), the arrow (≈1056, 21) and the ×
(≈1078, 21) in English, (≈1047, 21) and (≈1070, 21) in Russian.

| Run | Result |
|---|---|
| `build/r2-o1-en` | 25/27: the kill did not tick (the unit registry drops a dead unit before this module's handler runs; the step now reads the entity's type and force) |
| `build/r2-o2-ru` | 26/27: the × of the Russian layout sits 8 px further left |
| `build/r2-o4-en`, `build/r2-o4-ru` | **27/27** and **27/27**, 0 Lua errors |
| `build/r2-smoke16` | Skirmish smoke 65/65, 0 errors |

Screenshots: `docs/qa/phase5-screenshots/r2-objectives-lobby-en.png` (the switch),
`r2-objectives-skirmish-en.png` (6/7 with the list), `r2-objectives-nation-ru.png` (7/7 with the list, Russian); all
shots in `build/shots-r2-o4-{en,ru}/` and `build/shots-r2-o4-{en,ru}-window/`.

### 3.2 Other GUI probes and the showcase

A fresh save's first match of each mode shows the strip, so it appears in the first match of every GUI probe and of the
showcase. None of the M3 protocol's coordinates lies under it (`docs/qa/phase5-m3-protocol.md` lists it with the HUD).
The showcase scenes must keep it out of the release shots: before the first Start, call

```lua
require("scripts.objectives").set_pref(player.index, false)
```

## 4. Issue #17: Russian localisation review

A full read of `locale/ru` (21 files, 1,886 keys after #16) against the English texts and the vanilla Russian names the
player sees on items and buildings. Key parity is complete: every English key has a Russian one and the reverse, and
every string keeps the parameters of its English twin (`__1__`, `__2__`, …). The only identical strings are names and
rich-text templates ("Factorio RTS", "[img=…] __1__").

### 4.1 Glossary (decided and applied)

| English | Russian | Notes |
|---|---|---|
| Nation (the mode, a player's state) | **держава** | "Держава" in the lobby, "держав" for the count; the noun "нация" is gone (the mod description said "Нация"). The national project stays **национальный проект**, the usual Russian phrase |
| Skirmish | схватка | |
| Command Center, City Center, capital | командный центр, городской центр, столица | |
| Hub | хаб | |
| Rail depot; field depot | **ж/д депо** («Депо N» on the map); **полевой склад** | "депо" is only the rail depot; the fort belt panel called the field depot "полевое депо", the building itself "полевой склад" |
| Division; units; troops | дивизия; юниты; войска | the division panel said "боевые единицы", the war trains "отряды" |
| Barracks | казармы (plural noun: «из казарм») | |
| Kit (unit, train, hauler) / science or automation kit | **комплект** / **набор** | several unit kits were "наборы" (barracks page, army surcharge, treasury stages, Armor I) |
| Construction and logistic robots; roboport | **дроны** (строительные, логистические); **дронстанция** | as in vanilla 2.x Russian; the hub and the Commander were a "робопорт" with "роботами"; the combat Drone stays «Дрон» |
| Extractor | экстрактор | Mining I/II and the labor family said "добытчики" |
| Factory | завод | science kits, laser turret and steam research said "фабрика" |
| Plates; steel plate; stone brick; copper cable; electronic circuit | плиты; **стальная балка**; **каменный блок**; **медный кабель**; электросхема | vanilla item names; the texts said "пластины", "кирпич", "медный провод", "электронная схема" |
| Steel beam (Age II item) | стальной двутавр | apart from the vanilla steel plate |
| Age II | **II эпоха** | the age badge said "Эпоха II" |
| Town tier names | деревня, посёлок, город | "городок" in three texts |
| Land cells / tiles | ячейки земли / клетки (кл.) | the score said "клетки земли"; "тайлы" only in comments |
| Attack-move | атака с ходу | the Nation help said "атака с движением", the division state "движется с атакой" |
| Railway Charter; Space Program; city ledger | Железнодорожная хартия; Космическая программа; городской реестр | the Nation keys said "реестр городов" |
| Ceasefire, peace, alliance, contract, city-state | перемирие, мир, союз, контракт, город-государство | a city-state's proper name stays «Вольный город X» |

### 4.2 Other fixes

- Districts and families: the labor family tooltips now use the district names ("металлургический и сталелитейный
  комбинаты", "комбинат схем", "научный городок", "стройкомбинат"), and "Armoured cars" is «бронеавтомобили», not
  «броневики».
- The drone's "bites ignore heavy armour" reads «Укусы пробивают тяжёлую броню».
- "Rare earths" is «Редкие земли» everywhere (one line said «Редкоземельные металлы»); "8x8" became "8×8".
- A rival's launch no longer guesses a grammatical gender («__1__: ракета запущена, …»).
- Mid-sentence «командир» is lower case.

### 4.3 Lengths in the panels

From the Russian screenshots of the M3 GUI pass (`build/shots-m3i-p21b-ru/`) next to the English ones:

| Where | Russian before | Fix |
|---|---|---|
| City panel | "Уровень: Посёлок, радиус земли 96 клеток (столица)" and "Следующий уровень: Город с 400 жителей (сейчас 200)" wrapped, so the panel was two lines taller and Hire sat 27 px lower than in English | «Уровень: Посёлок, радиус 96 кл. (столица)», «Далее: Город с 400 жителей (сейчас 200)» |
| Alert lines | "Космическая программа начата рядом со столицей (этап 1)" was cut | «Космическая программа начата (этап 1)» |
| Age badge | «Эпоха II» | «II эпоха» |

Everything else fits: the lobby, the help page (a scroll pane), the ledger, the market, the diplomacy panel (long
city-state names are cut with "…" in English too), the train, depot, air and fort belt panels, the objective strip.

### 4.4 GUI pass with per-layout coordinates

`tools/probes/m3_docs_gui.lua` (the M3 protocol's 53 checks with real clicks and keys) now keeps the coordinates that
differ between the layouts in a `LAYOUT` table chosen by the client's locale: the build menu's four tabs (wider
Russian captions push them right) and the air panel's ×. Hire, which was 27 px lower in Russian, needs no own
coordinate any more: the shorter city panel lines give it the English place. The AA check also holds the Commander's
fire while the bomber flies in: in the first Russian run the Commander's rockets shot the bomber down before the AA
turret did, which failed the check by luck of the race.

| Run | Tree | Result |
|---|---|---|
| `build/m3i-p21b-ru` (before) | 0.1.0 on 2.1 | 48/53: the tabs (Steel works, rare extractor, AA turret), the air panel's ×, Hire |
| `build/r2-m3a-ru` | the Russian review, per-layout coordinates | 52/53: every coordinate passes; the AA check lost the race to the Commander |
| `build/r2-m3b-ru` | + the Commander holds fire for the AA check | **53/53**, 0 Lua errors |
| `build/r2-m3b-en` | the same tree in English | **53/53**, 0 Lua errors |
| `build/r2-smoke17` | the Russian review | Skirmish smoke 65/65, 0 errors |

No raw key can show: the two locales have the same keys, and every literal locale key in `scripts/` exists in them (a
static scan; the keys built from a prefix, such as `rts.results-victory-` and the victory mode, were checked by hand).
The screenshots looked at (lobby, ledger, city, hub, market, diplomacy, belt, train and air panels, help, menu) show
none either (`build/shots-r2-m3b-{en,ru}/`, `build/shots-r2-m3b-{en,ru}-window/`). The objective strip of #16 shows in these passes' first (Nation) match and covers
none of the protocol's coordinates.

## 5. Final GUI pass on the release tree (issue #18)

On HEAD fd75b4d (the 0.1.1 release tree), one GUI client at a time, the repository's `tools/gui-drive.sh`, a 1280×800
window at UI scale 0.75:

| Probe | English | Russian |
|---|---|---|
| `tools/probes/m3_docs_gui.lua` (the M3 protocol's checks) | **53/53** (`build/r2-f18c-en`) | **53/53** (`build/r2-f18c-ru`) |
| `tools/probes/r2_inputs_gui.lua` | **29/29** (`build/r2-f18i-en`) | – |
| `tools/probes/r2_objectives_gui.lua` | **27/27** (`build/r2-f18o-en`) | – |

0 Lua errors in every run. The first passes on this tree had three misses, all from the world of that run rather than
from the mod, and the probe now handles each:

- **The AA check lost the bomber to other shooters**: the division of part D in English (52/53), the capital's six
  start walkers in Russian. Every own ground unit (and the Commander) now holds fire (`disabled_by_script`) until the
  check is done, so only the AA turret can shoot the bomber down.
- **The Launch complex stood on the airfield's site** (Russian): the airfield goes to the protocol's mirror site
  (448, 304) when the complex overlaps (832, 304).
- **A unit stood on the Steel works** (Russian): a click picks an own unit before a building, so own units within 5
  tiles of the district move 9 tiles away before the click.
