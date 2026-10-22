# Phase 5 M3 integration (wave B): balance, fixes, HUD, acceptance, docs

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on unless noted. Agent: `m3-integ`. Contract:
`docs/PHASE5-M3.md` (§4 "M3 end-to-end" is this package's acceptance). Starting point: HEAD 80bcdbe (tag
`m3-wave-a` = m2-ready + the five M3 wave A snapshots). Package notes: `docs/qa/phase5-{air,age3,war2,perf,world3}-notes.md`;
the AI of wave B is `m3-ai`'s. Everything below is Nation mode only unless it says otherwise.

(Work in progress: sections are filled as the package goes.)

## 1. Verdict

TBD

## 2. What changed

### A. Balance

Method: 4 normal AIs, 2048, 60 minutes, `tools/probes/m3_acceptance.lua` (per nation the first open line, Age II and
III, the lowest balance, the highest debt stage, minutes in debt, the credit line), seeds 801-805. Three trees: the
wave A tree (HEAD 80bcdbe, the M2 AI; `m3i-base-*`), the integration tree with m3-ai's AI as of 2026-10-22 morning
(`m3i-live2-*`), then the same with this pass's changes (`m3i-live3-*` and later).

| Run set | Nations in a debt stage (seeds) | At the credit line | First lines at or after 25:00 | Age III by 40:00 |
|---|---|---|---|---|
| wave A AI (`m3i-base-801..805`) | none (0 of 5 seeds); lowest balances ₡ 439-1,500, the AI imports down to its ₡ 500 reserve | none | 6 of 20 (801: 2, 803: 2, 804: 1) | no Age III road in that AI |
| m3-ai's AI before this pass (`m3i-live2-801..804`) | 6 nations in 3 of 4 seeds, all stage 3 | **4 nations** (801, 802, 804 x2) at 50:19-57:59 | 7 of 16 incl. 2 nations without a line | 2 of 4 seeds (36:36, 38:30) |
| + rush rule, debt tax, credit decay, Railways 10 (`m3i-live3-801..804`) | 2 nations in 2 of 4 seeds (801, 803; stage 3 for 5-8 min) | none | 11 of 16 (25:16-43:46) | 2 of 4 (38:18, 35:40) |
| + Electrification 25 (`m3i-live4-801..804`) | 2 nations in 2 of 4 seeds (802, 804; stage 2 in the last minute) | none | 8 of 16 (25:00-48:27) | 2 of 4 (35:34, 38:15); Electrification done at 27-35 min, then stage 1 took 10-24 min (advanced circuits last: 21 of 100 after 9 minutes) |

What drove the debts (treasury minute lines): (1) "other" expenses of 176-186 cr a minute for ten minutes and more:
the research Rush on Electrification while both labs stood idle (no industrial kits); (2) a spiral: stage 3 (-25
happiness) put the AI's banded tax on low below happiness 40, the tax income fell to a third, and the credit line (10
minutes of gross income) shrank with it, so a balance of -773 was "at the credit line" of 743; (3) armies of 155-280
supply (army upkeep at the same number of crowns a minute) that grow at war and do not shrink in debt (m3-ai's).

| Change | Why | Where |
|---|---|---|
| A rush pays only while it speeds something up: a project stage whose goods came in during the last 3 s (or its countdown), a research while a lab works | (1); age3 notes open issue 6 | `scripts/sinks.lua`, `scripts/age3.lua`, `scripts/ages.lua` (`pulled_at`) |
| In debt (stage >= 1) an unhappy AI keeps the normal tax instead of the low one | (2) | `scripts/market.lua` (banded tax) |
| The credit line falls at most 1 % per treasury step (about 6 % a minute) when the income falls | (2): a credit line that halves in a minute makes a temporary tax drop a bankruptcy | `scripts/treasury.lua`, `balance.nation.treasury.credit.decay = 0.99` |
| Railways 10 basic kits (was 15) | first lines at 21-36 minutes; the labs waited for basic kits after Industrialisation | `prototypes/rails.lua` |
| Electrification 25 industrial kits (was 40) | the labs waited for industrial kits 12-30 minutes after Age II; the Space Program started at 29:44-47:59 | `balance.nation.age3.techs` |
| Space Program stage 1: 200 steel, 150 concrete, 60 advanced circuits (was 200 / 200 / 100) | stage 1 took the AIs 10-24 minutes, the advanced circuits last; stages 2 and 3 (the Space victory) unchanged | `balance.nation.age3.stages` |

TBD: the runs after the changes.

### B. Fixes carried from M2 and wave A

| Item | Cause | Fix | Where | Evidence |
|---|---|---|---|---|
| Fights razed belts, inserters and plain buildings (M2 integration open issue 2) | A unit distracted by an enemy gets an engine `attack_area` distraction (no target) and a division's group the same; both attack every enemy entity in the area, military or not, until none is left (probe: loose walkers with command go_to + distraction attack_area hit the inserter, factory, stockpile and house of the row; division members with command `group` the belts and the extractor) | Damage to an entity that is not a military target (walls, gates, units and rolling stock excepted) is undone when it comes from a careful unit (not a raider, not a plane) that is fighting something else: its distraction (with or without a target), its attack command, or its group's; explicit attacks (`rec.target`), re-target strikes and division strikes (`D.order.strike`, `D.strike`) still destroy, and so do area commands without a fight. The entity turns indestructible for 10 s (the rails' rule), so the area attack drops it and the units walk on; an explicit attack exposes it at once. Belts, splitters, loaders, inserters and pipes join the shared damage filter | `scripts/targeting.lua` | `tools/probes/m3_integ.lua` lanes A-D (below) |
| A player's trains stayed stopped when a lost depot came back (M2 integration open issue 12) | `buildings.on_force_changed` cleared the lost half of the route and only the AI's rail program routed its trains again | The lost half is remembered (`lost_pickup`, `lost_dropoff`); when the depot comes back to the train's force, every train without an AI line mark (`rec.ai_line`) gets its route again (`rails.set_route`), log `rails: train N (force) routed again: depot #D is back`; a new route by hand forgets the lost half | `scripts/rails.lua` | `tools/probes/m3_reroute.lua` |
| Raw stop names on the map ("rts-player depot 504", M2 integration open issue 8) | Train stops carry unique script names for the schedules; the engine draws them on the map | The stop names stay (schedules), the map view setting `show-train-station-names` is off for every player in a Nation match (restored at teardown), and each depot draws a localised chart label "Depot N" (the depot panel's name) for its owner, redrawn on capture | `scripts/rails.lua` | GUI audit |
| Dead code `population.ai_step` / `ai_describe` (M2 open issue 11, ai notes 10) | m2-ai's governor took the rules over | Removed (313 lines) | `scripts/population.lua` | smoke, fixtures |
| Research panel: "Needs Age II" for Air Force (air notes open issue 3) | one status text for every age gate | "Needs Age III" for techs gated by Age III (`rts.tech-status-age-3`) | `scripts/techgui.lua`, `locale/*/economy.cfg` | GUI audit |
| F11 Nation page reached 695 of 800 px in Russian and lacked the M3 keys (air notes open issue 7) | a plain flow | The page scrolls inside 80 % of the window height; an "Age III and money" paragraph; the air paragraph before the keys; the keys paragraph names Y, and F / B / H in context; the victory paragraph names Space and the world sizes; the supply paragraph says attack-moves spare the buildings around a fight | `scripts/hud.lua`, `locale/*/hud.cfg`, `locale/*/age3.cfg` | GUI audit |
| «Нация» / «Держава» in the Russian diplomacy texts | M2 diplomacy used «Нация» while the mode is «Держава» | every «Нация»/нация of `diplomacy.cfg`, `hud.cfg`, `cities.cfg` (and the city-state tooltip that said trade "comes later") | `locale/ru/*.cfg`, `locale/en/diplomacy.cfg` | GUI audit |
| Airfield art placeholder (air notes open issue 5) | the cargo landing pad's graphics read as a large machine | A refined-concrete apron with a hazard-striped rim and a centre line, a small roboport hangar in one corner (base-game textures; the roboport icon) | `prototypes/air.lua` | GUI audit |
| The headless autotest started on any dedicated server with nobody connected at tick 120 (perf notes open issue 9) | `debug.lua` decided by the player count only | Opt-in: `local AUTOTEST_ENABLED = false` in `scripts/debug.lua`; `tools/autotest-run.sh`, `perf-bench.sh`, `heavy-mode.sh` and `lan-check.sh` set it to true in their copies (older trees without the line run as before) | `scripts/debug.lua`, `tools/*.sh` | every run of this package |
| `diplomacy.is_human` counted connected players (a disconnect handed a nation's diplomacy to the AI; perf notes open issue 9) | | A flag per nation set at the match start for forces with connected players and when a player joins a nation later (`on_player_joined_game`, `on_player_changed_force`), never cleared; outside a Nation match (and in saves from before) the old rule | `scripts/diplomacy.lua` | `m3_integ.lua` human_flag |
| Order-dependent loops (perf notes open issue 9) | | `population.lua` loose-building pass: a sorted snapshot walked RESOLVE_BUDGET per tick (the old walk restarted at the first key every tick and never got past 200 loose buildings); `selection.get` in unit-number order in Nation matches (Skirmish keeps its order: the legacy autotest compares it); `logistics.init` walks a sorted snapshot (it inserted into the table it traversed); `warsupply` sums supply in unit-number order; `strategic.lua`'s zoom tier reads `LuaPlayer.zoom`, synchronised player state, and only scales chart texts: kept, covered by the LAN and heavy-mode runs | `scripts/population.lua`, `selection.lua`, `logistics.lua`, `warsupply.lua` | smoke, matrix, determinism |
| The fronts refresh ran on its own on_tick driver (war2 notes open issue 9) | wave A had no scheduler hook | A scheduler job (kind `fronts_refresh`, BACKGROUND priority, on the budget of the match's first nation; a job step = 300 units: 24 rows / 600 cells or one side's segments); `fronts.flush()` takes a running job off the scheduler; the old driver stays for a job of a save from before | `scripts/fronts.lua` | war2 autotest 22/22 |
| The rail planner went around fort belts (war2 notes open issue 4) | walls and gates were blockers | Own walls and gates no longer count as blockers of a coarse cell; a straight orthogonal piece whose only obstacles are own walls or gates costs +6 (`rails.WALL_CROSS_COST`), and when its ghost is laid the walls under it become `rts-gate` across the track (health share kept; log `rails: survey #N: K wall(s) at (x, y) turned into gates`) | `scripts/rails.lua` | `m3_integ.lua` wall_cross |
| A city site on ungenerated ground (world3 notes open issue 4) | `cities.lua` picked candidates without asking whether their chunk exists | A candidate on a chunk that does not exist yet is requested (`worldgen.request_area`) and skipped this time; `ai/towns.lua` got the same proposal through m3-ai | `scripts/cities.lua` | 4096 runs |
| The M2 fixture's upkeep check failed after m3-age3's sliced census | a new building counts after the next full census, up to 1,200 ticks later | the fixture waits 1,210 ticks | `tools/probes/m2_integ.lua` | 11/11 |

### C. HUD and UX

A GUI audit of every M3 panel in English and Russian at 1280x800 (a helper of this package; probe
`tools/probes/m3_docs_gui.lua`, which plays the M3 protocol's steps in order with real clicks, keys and right clicks
through `tools/gui-drive.sh` and checks each one 1.5 s later: English 53/53 PASS, Russian 48/53 with the 5 misses only
English coordinates of the Russian layout; screenshots `build/shots-m3i-{en,ru}/`, window captures
`build/shots-m3i-{en,ru}-window/`, earlier passes `-run1`..`-run3`). No raw key anywhere, no raw station name on the map.

| Finding | Fix | Where |
|---|---|---|
| F10 menu and the results window cut the Nation config line ("...Conquest + Spac...") | the line wraps | `scripts/lobby.lua` |
| The air panel (Y) covered the "World: N % generated" line under the minimap | the panel starts below it (`airgui.TOP` 282 GUI units) | `scripts/airgui.lua` |
| The market's Trade at drop-down cut the city-state entries | 280 wide | `scripts/marketgui.lua` |
| The staffing box after automation read "7.8 of 7.84 workers" | jobs rounded to one decimal | `scripts/citygui.lua` |
| The Russian goal line on the strip was cut | shorter Russian goal texts (conquest_space, any, territory) | `locale/ru/age3.cfg`, `diplomacy.cfg` |
| "Mercenaries (Port of X)" cut on the division card | name button 220 (Russian long region names still cut: open issue) | `scripts/divisiongui.lua` |
| An artillery train's gun line before its first shot read "last target: none (0 tiles)" | "looking for a target, next shot in N s" | `scripts/trainswar.lua`, `locale/*/war3.cfg` |
| The depot panel's shared reason "Cannot deploy a train: ..." stood above an enabled Deploy artillery train | "Freight and troop trains: ..." | `scripts/railgui.lua`, `locale/*/rails.cfg` |
| Russian wording: нации/страны/вольный город/Эпоха II/отряды/комплекты/семья | державы, город-государство, II эпоха, юниты, наборы, семейство (item names unchanged) | `locale/ru/*.cfg` |
| A fort belt laid across a rare extractor's drop tile stopped it and its bonus ran out | the belt layout leaves the drop tile of every own mining drill near the line free | `scripts/belts.lua` |
| The "Depot N" chart labels were unreadable at map zoom (world-sized scale 1.6) | screen-sized (`scale_with_zoom`, 1.2), like the engine's station names | `scripts/rails.lua` |

Checked and unchanged: the F11 page in its scroll pane (fits y 74-722, 11 paragraphs, Y/F/B/H in the keys, Russian
reads well), "Needs Age III" for Chemistry, Nuclear power and Air Force, the lobby (Nations 2-6, 2048/3072/4096,
Explore/Survey, the victory list, the generation line) in both languages, the 4096 progress line, the front lines and
labels, and the airfield picture (it reads as an airfield at game zoom).

### D. Acceptance tooling

| Tool | What |
|---|---|
| `tools/probes/m3_acceptance.lua` | EXTRA_LUA for the 4-AI end-to-end runs: the M2 criteria (trade, war, peace, capture, starving; the last 5 minutes at speed 1) and per nation Age II and III, the first open line, items by train, the lowest balance, the highest debt stage, minutes in debt, the credit line, tax switches, capital depots destroyed, and every 10 minutes the M3 modules' describe lines (Space Program, rare, sinks, air, belts, war trains, fronts) |
| `tools/probes/m3_integ.lua` | collateral damage (lanes A-D, raiders as info), the rail planner over a fort belt, the human flag |
| `tools/probes/m3_reroute.lua` | a train routed by hand comes back to its route when its lost depot returns |
| `build/m3i-tools/mktree.sh` | frozen test trees: `mods/` with `scripts/ai/` from HEAD (or live) |

## 3. Shared code touched

Every file except `scripts/ai/*` (m3-ai's) and m3-ai's sub-tables of `balance.lua`. Hunks are marked `-- Phase 5 M3
integration`; m3-ai's hunks applied here are marked `-- Phase 5 M3 ai`.

| File | What |
|---|---|
| `scripts/targeting.lua` | collateral damage undone and the entity protected for 10 s; belts, inserters, pipes in the damage filter; `targeting.expose` for any protected entity |
| `scripts/rails.lua` | re-route of trains routed by hand when a depot returns; "Depot N" chart labels and hidden station names; own walls and gates crossed (cost, gates); m3-ai's `A.pay` (H1) and the freight trains of a line only ahead of its crew (H4, adapted: freight records carry no `line`) |
| `scripts/fronts.lua` | the refresh job on the scheduler (`fronts_refresh`) |
| `scripts/population.lua` | the dead AI governor removed; the loose-building pass sorted and budgeted |
| `scripts/selection.lua`, `logistics.lua`, `warsupply.lua` | deterministic orders (Nation sort, init snapshot, sorted sums) |
| `scripts/diplomacy.lua` | the human flag |
| `scripts/debug.lua` | `AUTOTEST_ENABLED`; `/rts-front`, `/rts-deposit` |
| `scripts/cities.lua` | worldgen required at load (the crash), ungenerated sites skipped and requested; m3-ai's "pending" no-try rule |
| `scripts/hud.lua` | the help page in a scroll pane, its paragraphs and keys |
| `scripts/techgui.lua` | "Needs Age III" |
| `scripts/sinks.lua`, `age3.lua`, `ages.lua` | a rush pays only while it speeds something up |
| `scripts/market.lua` | no low tax in debt; m3-ai's `no_buy` (H5) |
| `scripts/treasury.lua` | the credit line decays; m3-ai's H2 (no hard tax bonus) |
| `scripts/belts.lua` | drill drop tiles left free |
| `scripts/lobby.lua`, `airgui.lua`, `marketgui.lua`, `citygui.lua`, `divisiongui.lua`, `railgui.lua`, `trainswar.lua` | the GUI audit's fixes (C); `/rts-match` help lists conquest_space and any |
| `prototypes/air.lua` | the airfield picture and icon |
| `prototypes/rails.lua` | Railways 10 kits |
| `balance.lua` | `treasury.credit.decay`, `age3.techs` Electrification 25, `age3.stages[1]` |
| `locale/{en,ru}/*.cfg` | help paragraphs and keys, "Needs Age III", the держава wording, the GUI audit's keys and texts |
| `tools/autotest-run.sh`, `perf-bench.sh`, `heavy-mode.sh`, `lan-check.sh` | `AUTOTEST_ENABLED` set in the test copy |
| `tools/probes/m2_integ.lua`, `age3_fixture.lua` | census wait; the research rush charge rule |

## 4. Acceptance in detail

TBD

## 5. Checks of this package

### 5.1 Skirmish unchanged

`KEEP_TREE=<tree> SEED=777 build/m3i-tools/matrix-batched.sh <tag>` (the ten scenarios of `tools/autotest-matrix.sh`,
four at a time) on `m2-ready` (497cb1c, `m3i-m2ready`) and on the integration HEADs, compared with
`tools/matrix-compare.sh` (it now also drops the Nation-only plane ammo categories and the AA turret from the static
research line, as it did for the garrison gun):

| Scenario | m2-ready | HEAD 4de0bc6 (`m3i-h4de0`) | `[rts]` lines | Differing |
|---|---|---|---|---|
| 1v1-easy-medium | 23/23 | 23/23 | 1,211 | 0 |
| 1v1-hard-medium | 20/23 | 20/23 | 4,037 | 0 |
| 1v1-normal-medium | 23/23 | 23/23 | 3,240 | 0 |
| 1v1-normal-small-nosa | 23/23 | 23/23 | 3,294 | 0 |
| 1v1-normal-small-restart | 22/23 | 22/23 | 4,450 | 0 |
| 1v2-normal-medium | 31/31 | 31/31 | 4,491 | 0 |
| 1v3-normal-small | 39/39 | 39/39 | 5,024 | 0 |
| 1v3-normal-small-stress | 34/38 | 34/38 | 3,333 | 0 |
| legacy-units, legacy-units-nosa | 65/65, 65/65 | 65/65, 65/65 | 468, 469 | 0 |

The hard, restart and stress failures are m2-ready's own (as in the M2 integration).

### 5.2 Fixtures

| Fixture | Result |
|---|---|
| `m3_integ.lua` (collateral lanes A-D, wall crossing, human flag), 1v1 Nation seed 501 | 6/6 (collateral hits undone 12; lanes A and B lose nothing; an explicit attack and a division strike destroy their factory, the belts beside the strike survive) |
| `m3_reroute.lua` (seed 501, 45 min) | 2/2 |
| `m2_targeting.lua` | 5/5 |
| `m2_integ.lua` | 11/11 (the census wait) |
| `war_autotest.lua` (M2) | 27/27 |
| `war2_autotest.lua` (fronts on the scheduler) | 22/22 |
| `air_autotest.lua` | 14/14 |
| `age3_fixture.lua` | 35/35 (the research rush charge rule) |
| Skirmish smoke | 65/65 before every commit |

### 5.3 LAN and heavy mode

`KEEP_TREE=<HEAD 1851531> SEED=701 tools/lan-check.sh m3i-lan1 10 5`: a headless 4-nation server, GUI client 1 from
tick 1,716, client 2 at minute 5 by hand-over (one Steam account: the server refuses the same player name twice); 0
desync lines on the server and both clients, 34 and 24 checksum lines equal to the server's, no Lua error (the clients'
"Steam API could not be initialized" is the environment). The joining player made rts-player a human nation
(`diplomacy: rts-player is played by a human from tick 1716`), the same on every peer.

`KEEP_TREE=<HEAD 1851531> SEED=701 tools/heavy-mode.sh m3i-heavy1 10`: the 4-nation match saved 60 s after its start
(tick 3,600) and loaded in the GUI client with `--heavy` (save, load and compare every tick) for 10 minutes of wall
clock: ticks 3,600-4,200+, 0 desync lines, no desync report, no Lua error. Heavy mode runs about one tick a second on a
2048 world, so 10 minutes of wall clock are 10 s of game; the headless save/load equivalence (section 4) covers whole
minutes.

## 6. Performance

TBD. m3-perf's measurement of m3-age3's sliced treasury census (perf notes §6a, synced tree): a slice costs 0.058 ms on
average and 0.15 ms at worst, the treasury step 0.79 ms; the 600-tick census it replaced cost up to ~8 ms in one tick.

## 7. Open issues

(Draft; finalised with the acceptance.)

1. **First rail lines after 25:00** for about half of the AI nations in the 4-nation runs (25-48 minutes): the AI's
   rail program pays its locomotive and construction wagon kits from the capital's network, which held 1-54 iron plates
   for most of the match (seed 804, rts-ai-1: survey done at 19:30, "waits for a construction train: no-kits" until
   29:30). Railways at 10 kits moved research earlier; the iron allocation is m3-ai's (sent).
2. **AI armies do not shrink in debt**: army upkeep of 160-280 cr a minute against 200-340 of tax; stage 2 stops the
   kits but no unit leaves, so a nation in debt late in the match runs towards its credit line (m3-ai: disband in
   debt, sent). The treasury rules themselves are unchanged (stage 2 unpaid wages, stage 3 unrest).
3. **Air, holds, artillery trains unused by the AI** in every run so far (patrols, interceptors, bombers, artillery,
   holds 0): the balance of air kits, AA, belts, artillery and armoured stock stays at wave A's first guesses until
   the AI uses them (m3-ai).
4. **The research Rush can still be started with no industrial kits in stock**; it costs nothing until a lab works.
5. **Mercenary division names** ("Mercenaries (Port of <Region>)") are cut on the division card in Russian for long
   region names (GUI audit).
6. **Air panel counts**: planes idle on the apron count as "Flying" (GUI audit; m3-air's wording).
7. **Train panel**: a train standing on its own depot's platform reads "No position yet" (GUI audit).
8. **4096 x 6 start**: planning 2.5-3.2 s and the forced core 2.6-2.9 s are world3's (core <= 3 s holds); the AIs'
   first layouts are m3-ai's resumable planner now (planjob).
