# Phase 5 M2 integration (wave B): balance, gameplay fixes, HUD, acceptance, docs

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on unless noted. Agent: `m2-integ`. Contract:
`docs/PHASE5-M2.md` (§4 end-to-end acceptance, the GUI protocol list). Starting point: HEAD 792206e (tag m2-wave-a).
Package notes: `docs/qa/phase5-{people,treasury,diplomacy,war,world2}-notes.md`; the AI of wave B is `m2-ai`'s
(`docs/qa/phase5-ai-notes.md`). Everything below is Nation mode only unless it says otherwise; the Skirmish matrix at
seed 777 is line-identical to m1-ready (section 5.1).

## 1. Verdict

The M2 end-to-end acceptance passes on HEAD dc3218e (m2-ai's final AI 1fa6fcb, this package, and the rail and market
fixes after m2-ai's hand-over; the tree taken from git): four normal AIs, 60 minutes, 2048 worlds, seeds 701-705,
PERF=1, every criterion in every seed:

| Criterion | Needed | Result |
|---|---|---|
| Lua errors | 0 | 0 in every run |
| UPS at speed 1, last 5 minutes | 60 | 60.0-60.2 s of wall clock per game minute in every seed |
| Every nation trades | every seed | 5 of 5 (the lowest nation ₡ 3,286-6,309 of volume) |
| At least one war declared | 4 of 5 seeds | 5 of 5 (20 wars) |
| At least one peace signed | 4 of 5 | 5 of 5 (14 treaties: 8 cessions, 2 tributes, 4 white) |
| At least one city changes hands | 3 of 5 | 5 of 5 (22 captures: 14 between nations, 8 city-states) |
| No nation starving (a city below 50 % rations for more than 3 minutes) | in at most 1 seed | 0 seeds |
| Save and load at minutes 20 and 40 (4 nations, seed 702) | 0 errors | 0 errors in both halves of both (loaded runs to minute 46 and 60) |
| M1 acceptance, 1v1 seed 501, 60 minutes | passes | 53/53, 26,612 items by train, 60 UPS |
| Skirmish matrix | unchanged | 0 differing lines against m1-ready (10 scenarios, seed 777) |
| M2 modules' cost | ≤ 0.5 ms/tick | 0.016-0.049 ms/tick in the last 5 minutes (4 nations) |

Not met: rail lines do not all open before minute 20 (the 1v1 at 20 and 24, the 4-nation AIs at 21-36; section 6).
The GUI protocol for Codex is `docs/qa/phase5-m2-protocol.md`; Codex has not run it yet.

## 2. What changed

### A. Balance

| Item | Change | Where |
|---|---|---|
| Homes and food pay no upkeep | houses, apartments, farms, bakeries and fishing huts join the upkeep's `skip_names` (the residents already cost rations and goods; a farm is labor) | `balance.nation.treasury.upkeep` |
| Treasury curve | measured, no change needed beyond the exemption: no nation entered a debt stage in 60 minutes, neither the 20 nations of the final 4-nation runs nor those of the wave A and first-pass runs, nor either side of the 1v1 seed 501; the final runs' lowest balances were ₡ 340-1,530 (section 4) | - |
| Territory victory | 60 % of the claimable cells was about 53 % of a 2048 map, while four nations of ten cities own about 20 %. Now: 45 % of the claimable cells, **or** twice the land of the next coalition with at least 3 % of the claimable cells (a capital and about five towns), for 3 minutes. Lobby tooltip, goal line and result texts in both languages; the contract (D6, §4) | `balance.nation.diplomacy.victory`, `scripts/wars.lua`, `locale/*/diplomacy.cfg` |
| Rails | factory recipe 1 steel + 1 stone → 2 rails (was 2 steel); the Rail works district (4 steel + 4 stone → 12 rails, was 4 + 2 → 8) is unlocked by Railways in Age I instead of Age II, and sits in the build menu's Economy tab after the depot | `balance.lua`, `scripts/ages.lua` (`RAILWAYS_EARLY`), `scripts/rails.lua` (unlocks), `scripts/hud.lua` |
| City-states | 6 garrison turrets at the start, +1 every 8 minutes (at most 10; was 4, +1 per 10 minutes); their City Center heals back half of every hit (2× effective health; the capital's armour rule) | `balance.nation.world.city_state`, `scripts/cities.lua` |
| Nation hauler check | not needed: no `hub_<force>` failure in any of the runs below (the wave A failures came from the M1 economic AI, which m2-ai's governors replace) | - |

### B. Gameplay fixes

**Attack-moves and rail lines** (`scripts/targeting.lua`, `orders.lua`, `divisions.lua`). Probes first
(`tools/probes/rail_targeting.lua`, one lane per run: enemy rails, a signal, a pole, a belt, an inserter, a factory, an
extractor and a stockpile crossed by four walkers):

| Lane | Command | Lost in 50 s |
|---|---|---|
| 1 | attack_area + by_anything (the Skirmish attack-move), point beyond the row | signal, pole, belt, inserter |
| 2 | attack_area + by_enemy, point beyond the row | nothing |
| 3 | as 2, the buildings `is_military_target` at run time | the three buildings |
| 4 | attack_area + by_enemy centred on the row | three rails and the pole |
| 5 | as 4, buildings military | the buildings, then the rails |

Rule as built (Nation mode; Skirmish keeps every command):

- An attack-move leg is `go_to_location` with distraction `by_enemy`: on the way units fight military targets (units,
  turrets, Command and City Centers, barracks, hubs, depots, districts, radars, rolling stock) and nothing else. At the
  end the unit re-targets the nearest military enemy, else the nearest enemy building within 12 tiles, and strikes it
  alone (an area of radius 2 around it). A division whose order point has an enemy building within 3 tiles strikes it
  after the march. Raiders keep the Skirmish legs (sabotage), and explicit attack orders work as before.
- **Rail protection.** A unit distracted by an enemy *unit* fights with an area attack and splash that also hits
  everything around the fight: with two enemy walkers 15 tiles before the row, lane A (4 loose walkers) lost 4 rails,
  signals and poles and lane B (a division of 8) lost 13. So rails, rail signals, rail supports and ramps and electric
  poles take no damage in Nation mode unless it comes from a raider or from a unit whose explicit attack order targets
  exactly that entity: the damage is undone and the entity is indestructible for 10 s, so the engine's target selection
  drops it (units never pick an indestructible target); then it is destructible again. An explicit attack order makes
  its target destructible at once. The rail and pole types join the shared `on_entity_damaged` filter in `control.lua`
  after every module set its part (Skirmish has no rails, and every other handler ignores poles).
- Rejected on the way: making every building a military target at run time kept the rails but made the besieging army
  raze the city's factory before the capture (the war autotest's `capture_unrest` lost its factory), against D4.
- Probe `tools/probes/m2_targeting.lua` (five lanes through the real order paths, 1v1 Nation 1536, at war): orders
  attack-move 0 rails, signals or poles lost (14 stray hits undone), a division 0 lost, a point on the rails 0 lost and
  the buildings at the point struck, raiders hit 2 pieces (sabotage), an own turret beside the row shoots the enemy
  walkers and no rail.

**City-states** fell to 2-3 passing units: see A (6 turrets, faster growth, 2× centre).

**Disband** (`scripts/demolish.lua`, `hud.lua`). A red bin at the right end of the units page's first line (Nation mode
only), and Delete with units but no building selected: two presses like Demolish ("Disband N unit(s)? Press again within
3 seconds."), then `labor.disband` per unit (its recruits go back to its home city, or the nearest own city), nothing
else refunded; the Commander stays ("The Commander cannot be disbanded."). Log lines `disband: armed|done player=N`.

**Under attack** (`scripts/cities.lua`, `citygui.lua`). `cities.under_attack(city_id, window)` records the last hit on
an own registered building on a city's land by another force ({tick, position, by, owner}; at most every 30 ticks per
city; a record of the previous owner is ignored after a capture). The city panel shows a red line under the title
while a hit is less than 30 s old or the centre is subdued or being captured: "Under attack (12 s ago)", "Under attack:
the centre is subdued", "Under attack: AI 1 captures it, 45 %", with a **Jump** button to the last hit; the city list
puts a warning icon before the city's name and its jump goes to the attack. Town defence itself (relief, turrets) is
m2-ai's and uses the same API.

**A bug from M1: Railways never enabled its factory recipes.** `research.apply` enabled the locked recipes from a list
cached before `scripts/rails.lua` added its unlocks, so after Railways the depot, rail and kit recipes stayed disabled
for every force (probe: `research.is_unlocked` true, the force recipe false; the AI pays rails and kits from plates and
the M1 protocol gave them by console, so nobody noticed). `research.apply` now walks `research.LOCKS` as it is.

**Rail lines and a lost city** (`scripts/rails.lua`; m2-ai's seed 703: the town fell at 25:00 with its line at 107/131,
and after the town was retaken at 37:28 the line stayed closed). A depot that comes back to the owner of a line it lost
restores the line ("cut" once it had opened, so repair crews finish it, else "building") when the other end is the
owner's too. An AI rail program that loses a building is kept (`R.ai_lost`) and taken up again when its far city comes
back (`rails.ai_revive` on `rts_city_captured`): as the main program when the AI has none, else beside the new one
(`R.ai_more`, serviced by `rails.ai_step`); its freight train is routed again, and a line that stayed lost (a depot gone)
is re-planned. A depot that dies takes its line with it ("lost"; seed 703's line stood "building" with 131/131 pieces
and no path to the depot that died in the fight for the town): the line remembers where the depot stood and its
platform track, the AI re-binds it to a new depot on that same track, else plans a new line, and first scraps the old
line's freight trains that stand without a route (half of their kits back into the capital-side depot: one blocked the
new line's crew, "freight train ahead"). Probe `tools/probes/m2_rails_retake.lua` (1v1, seed 501, the player AI's far
city flipped to rts-ai-1 and back 60 s later), 5/5 in each of three modes: an open line (lost, then open again at once,
its freight train routed again), a line still being built (open 2 minutes after the city came back), and the far depot
destroyed while the city was lost (the stranded freight train scrapped, a new line open 3.7 minutes after the city came
back, a new freight train on it); every construction train left with 40 coal. Rails autotest 12/12.

**Construction trains leave fuelled.** A construction train refuels only from its wagon, and an AI crew left with 2 coal
(the old minimum) and stood at piece 36 for half an hour. It now deploys only with 2 × `fuel_target` (40) coal in its
depot network, and both locomotives take `fuel_target` each.

**AI tax and deficit hysteresis** (`scripts/market.lua`, m2-ai's count: the tax switched 17 and the deficit mode 22 times
per nation-hour). Deficit starts below the floor with a negative net and lasts until the balance is 300 above the floor
or the net above +10 per minute; a tax level holds 2 minutes unless a war starts or ends or happiness falls below 40.

### C. HUD and UX

- **GUI audit** (`tools/probes/m2_docs_gui.lua`, English and Russian clients at 1280×800, screenshots
  `build/shots-m2d-*`): no raw locale keys on any M2 panel; every panel fits; positioned alerts carry the region name
  ("Ashunka Fields: Port captured: …"). Fixed in locale: the capture label ("Capture by You: 25 %"), three alerts cut
  off by the region prefix (city subdued, out of supply, war declared), the Russian war goal and the tier name in the
  people texts. Fixed in Lua: the Nation lobby hint (no Skirmish "no CC, barracks..."), city-state names in the
  diplomacy panel (width 150), a captured city's pinned panel closes, the city list's attack mark, "· low supply N" /
  "· OUT OF SUPPLY" on the division card (amber / red: the bar's state was only in its tooltip), troop wagon kits in the
  depot panel's kits line, the labor priorities in two columns with one up button each (nine rows pushed the panel over the ability bar;
  with up and down buttons the Russian names were cut and the right column stuck out of the panel), one
  city-name counter for every nation and 24 names (every nation's first town was "Ironford"), and the city list 300
  wide (Russian names and the attack mark pushed the magnifier out of a 260-wide list).
- **Hotkeys.** `P4.KEYS` holds the M2 panel keys (M market, F4 diplomacy, N minimap mode); every other key has its own
  handler. F11 in a Nation match (or in the lobby with Mode = Nation) shows a Nation page instead of the Skirmish one:
  the victory rules, controls, people, treasury, diplomacy and war, supply and capture, rails and ages, and every
  hotkey (M, F4, N, L, T, B, Delete for buildings and units, F3, F10, F11).
- **QA console commands** for the protocol (`scripts/debug.lua`): `/rts-supply <sp> [division]`,
  `/rts-goto city-state|port|ai`, `/rts-diplomacy [propose <from> <to> peace|ceasefire|alliance]`.
- **The info box under the minimap** (M1 check) is step 29 of the protocol: place a ghost from the build menu, press Q,
  watch 60 s.

### D. Acceptance tooling

| Tool | What |
|---|---|
| `tools/probes/m2_acceptance.lua` | EXTRA_LUA for the 4-AI end-to-end runs: the last 5 minutes at speed 1 (UPS lines), and per seed trade volume per nation, wars declared, pairs back to peace, wars ended, cities that changed hands (between nations, city-states), starving cities (below 50 % rations for more than 3 minutes); "[rts] m2 acceptance check trade|war|peace|capture|starving" and a summary with the event list |
| `tools/probes/m2_integ.lua` | the integration's rules, 10 checks (section 5.2) |
| `tools/probes/m2_targeting.lua`, `rail_targeting.lua` | the targeting probes above |
| `tools/probes/m2_rails_retake.lua` | a line whose far city is lost and retaken, three modes (5 checks each) |
| `tools/matrix-compare.sh` | two matrix runs line by line: every `[rts]` line up to the stop marker, timings, run-time durations and static prototype counts normalised |

## 3. Shared code touched

Every file except `scripts/ai/*` (m2-ai's). Hunks are marked `-- Phase 5 M2 integration`.

| File | What |
|---|---|
| `scripts/targeting.lua` | new: attack-move legs and re-targets, rail protection, the damage filter |
| `control.lua` | `targeting.install_damage_filters()` after the module list |
| `scripts/orders.lua`, `scripts/divisions.lua` | Nation legs, re-target fallback, the sweep keeps a unit striking a building, explicit attacks expose a protected target |
| `scripts/research.lua` | `research.apply` walks `research.LOCKS` |
| `scripts/ages.lua`, `scripts/rails.lua`, `scripts/hud.lua` (build tabs, `NATION_ONLY`) | Rail works with Railways |
| `scripts/cities.lua` | city-state armour, `cities.under_attack`, shared name counter, 24 names |
| `scripts/citygui.lua` | under-attack row and Jump, list mark, pinned panel of a lost city, two-column priorities |
| `scripts/demolish.lua`, `scripts/hud.lua` | Disband; the Nation help page |
| `scripts/rails.lua` | lines restored when their depot comes back or lost with a dead depot, AI programs taken up again (`rails.ai_revive`), re-bound or re-planned lines, stranded trains scrapped (`rails.disband_train(train, fallback)`), fuelled construction trains |
| `scripts/market.lua` | the AI's deficit and tax hysteresis |
| `scripts/world.lua` | a captured city-state's granary |
| `scripts/wars.lua` | the Territory lead rule |
| `scripts/debug.lua` | `/rts-supply`, `/rts-goto`, `/rts-diplomacy` |
| `scripts/lobby.lua`, `scripts/diplomacygui.lua`, `scripts/divisiongui.lua`, `scripts/railgui.lua` | the GUI audit's fixes |
| `balance.lua` | rails, Rail works recipe, upkeep exemptions, territory victory, city-state garrison and armour |
| `locale/{en,ru}/{cities,demolish,diplomacy,hud,war,people}.cfg` | new and fixed texts (keys identical in both languages) |

## 4. Acceptance in detail

### 4.1 M2 end-to-end: 4 normal AIs, 60 minutes, 2048, seeds 701-705

```sh
PERF=1 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m2_acceptance.lua DURATION_MIN=60 SEED=701 SPEED=8 \
  tools/autotest-run.sh m2acc-t16-701 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
  enemy_brain = "ai"}' 10000
```

The tree is `mods/factorio-rts` at dc3218e (from `git archive`). The fixture switches the game to speed 1 for the last 5
minutes.

| Seed | AI autotest | Lowest nation's trade (₡) | Wars / back to peace / ended | Cities changed hands (nations, city-states) | Starving | Speed-1 minutes (s) |
|---|---|---|---|---|---|---|
| 701 | 81/82 | 4,015 | 3 / 2 / 2 | 4 (2, 2) | none | 60.0 60.0 60.0 60.1 60.0 |
| 702 | 81/83 | 5,810 | 6 / 3 / 3 | 4 (3, 1) | none | 60.0 60.0 60.0 60.2 60.0 |
| 703 | 83/83 | 4,813 | 4 / 3 / 3 | 7 (6, 1) | none | 60.0 60.0 60.0 60.2 60.0 |
| 704 | 80/83 | 6,309 | 3 / 3 / 3 | 2 (1, 1) | none | 60.0 60.0 60.0 60.1 60.0 |
| 705 | 79/83 | 3,286 | 4 / 3 / 3 | 5 (2, 3) | none | 60.0 60.0 60.0 60.1 60.0 |

Lines lost and taken up again in these runs: four AI programs took up a line after their city came back, and 13 lines
were lost with a dead depot (section 2.B). Per nation (Age II, first line open, items by train, the treasury's lowest
balance):

| Seed | rts-player | rts-ai-1 | rts-ai-2 | rts-ai-3 |
|---|---|---|---|---|
| 701 | 14:37, 21 min, 0, ₡ 1,353 | 18:37, 31, 6,969, ₡ 1,107 | 16:26, 28, 10,000, ₡ 578 | 14:28, 23, 9,700, ₡ 435 |
| 702 | 18:30, 25, 4,633, ₡ 368 | 18:24, 27, 8,595, ₡ 503 | 20:07, 27, 8,765, ₡ 821 | 17:15, 21, 13,892, ₡ 651 |
| 703 | 17:30, 31, 3,334, ₡ 1,275 | 16:51, 34, 3,131, ₡ 577 | 17:44, 23, 5,896, ₡ 386 | 17:35, 21, 13,619, ₡ 534 |
| 704 | 21:30, 36, 11,239, ₡ 561 | 19:59, 32, 6,893, ₡ 1,160 | 20:24, 21, 10,485, ₡ 663 | 18:46, 26, 11,668, ₡ 578 |
| 705 | 17:50, 22, 5,340, ₡ 816 | 21:41, 23, 3,357, ₡ 540 | 15:28, 23, 0, ₡ 1,530 | 20:35, 23, 11,648, ₡ 1,230 |

Every one of the 20 nations opened a line; in 703 rts-player's new line opened at 31:00 after its first town fell at
25:00 (on 1fa6fcb its crew stalled with 2 coal and the line never opened). No nation entered a debt stage. The AI
autotest's remaining failures are M1-era checks under four nations: Age II after 20:00 (`age2_<force>`, 5 nations),
`no_bad_spam` (2), `produce`, `kinds_8min`, `techs_6min` (1 each).

**Earlier runs of the same set** (the integration tree with an older AI or before the last fixes):

| Tree | War | Peace | Capture | Starving seeds | Notes |
|---|---|---|---|---|---|
| wave A AI (792206e's AI), `m2acc-t3-*` | 4/5 | 4/5 | 4/5 | 5 of 5 | new towns at minute 16-26 eating their 40 start rations with nothing arriving, a capital at minute 18, freshly captured city-states; 704 ended at 39:00 when rts-player lost its only city |
| m2-ai's first pass (c71c4ef), `m2acc-t7-*` | 4/5 | 4/5 | 4/5 | 1 of 5 | 701 stayed at peace |
| m2-ai's final AI (1fa6fcb), `m2acc-t8-*` | 5/5 | 5/5 | 5/5 | 0 | 20 wars, 26 captures; 703 rts-player never reopened its lost town line |
| aacfc5d (rail retake, fuelled crews, tax hysteresis), `m2acc-t12-*` | 5/5 | 5/5 | 5/5 | 0 | 15 wars, 17 captures |
| final (dc3218e, lines lost with a dead depot), `m2acc-t16-*` | 5/5 | 5/5 | 5/5 | 0 | the table above |

### 4.2 M1 acceptance, 1v1 seed 501, 60 minutes (`m2i-t16-501`, `tools/probes/m1_acceptance.lua`)

53/53 checks, 0 Lua errors, both nations alive at 60:00, 60.0 s of wall clock per minute at speed 1 in minutes 56-60.

| | rts-player | rts-ai-1 | wave A HEAD (`m2i-base-501`) |
|---|---|---|---|
| Age II | 16:59 | 17:40 | 17:20 / 16:22 |
| First line open (minute line) | by 20 | by 24 | by 26 / 27 |
| Items by train | 14,010 | 12,602 | 7,589 / 12,536 |
| Treasury low | ₡ 544 | ₡ 528 | ₡ 483 / 494 |

26,612 items by train together (goal 20,000; wave A HEAD 20,125).

### 4.3 Save and load

`SAVE_MINUTE=20` and `SAVE_MINUTE=40 SPEED=8 DURATION_MIN=60 SEED=702 KEEP_TREE=<dc3218e tree> tools/saveload-check.sh
m2i-t16-sl20|40 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 300`:
saved at minute 20 (towns, lines building, the first war) and 40 (wars, captures, contracts, troop and freight trains),
loaded and run on to minute 46 and 60; 0 errors in both halves of both runs. The same on aacfc5d (`m2i-t12-sl*`),
1fa6fcb (`m2i-t8-sl*`) and an earlier tree (`m2i-sl*`).

## 5. Checks of this package

### 5.1 Skirmish unchanged

`SEED=777 tools/autotest-matrix.sh` on wave A HEAD (`m2i-head`) and on the final tree (`m2i-t16`, dc3218e; also `m2i-t12` aacfc5d and `m2i-t8` 1fa6fcb), compared with
`tools/matrix-compare.sh` (and wave A HEAD against the M1 diplomacy agent's m1-ready run `p5m2dipl-base0abb`):

| Scenario | Result (both trees) | `[rts]` lines | Differing |
|---|---|---|---|
| 1v1-easy-medium | 23/23 | 1,211 | 0 |
| 1v1-hard-medium | 20/23 | 4,037 | 0 |
| 1v1-normal-medium | 23/23 | 3,240 | 0 |
| 1v1-normal-small-nosa | 23/23 | 3,294 | 0 |
| 1v1-normal-small-restart | 22/23 | 4,450 | 0 |
| 1v2-normal-medium | 31/31 | 4,491 | 0 |
| 1v3-normal-small | 39/39 | 5,024 | 0 |
| 1v3-normal-small-stress | 34/38 | 3,333 | 0 |
| legacy-units, legacy-units-nosa | 65/65, 65/65 | 468, 469 | 0 |

The hard, restart and stress failures are m1-ready's own. The comparison normalises the run-time durations, the count
of defined technologies (Commerce and Geology are Nation-only) and the hidden garrison gun in the derived turret list.

### 5.2 Fixtures (on 1fa6fcb plus this package; m2_integ, m2_rails_retake, the rails autotest and the smoke again after the last rail change; 0 Lua errors)

| Fixture | Result |
|---|---|
| `m2_integ.lua` (1v1 Nation 2048, victory Territory, seed 501) | 11/11: upkeep (a house and a farm +0, a factory +0.5), 6 turrets per city-state, a city-state centre loses 50.0 of a 100 hit, a captured city-state's granary (212 rations), rails 1 + 1 → 2 and the Rail works and depot recipes enabled by Railways in Age I, under attack after a hit on a capital barracks, Disband (armed, done, 3 walkers gone, residents +3), `/rts-supply` and `/rts-diplomacy propose`, a stray hit on a rail undone and an explicit attack destroying it, the territory floor (2.5 % vs 1 %: no count) and lead (3.5 % vs 1.5 %: victory after 181 s) |
| `m2_targeting.lua` | 5/5 (section 2.B) |
| `m2_rails_retake.lua` (1v1, seed 501) | 5/5 in each of three modes (section 2.B) |
| `rails_autotest.lua` (M1) | 12/12 |
| wave A fixtures on the integration tree | war autotest 27/27, diplomacy acceptance 12/12, people 14/14, treasury 12/12, world2 7/7 |
| Skirmish smoke (seed 9090) | 65/65 before every commit |

### 5.3 Performance (PERF=1, last 5 minutes at speed 1)

M2 modules (population, labor, treasury, market, diplomacy, wars, warsupply, capture, garrison, strategic, world,
targeting and their panels) together: 0.024, 0.024, 0.030, 0.016, 0.049 ms/tick in seeds 701-705 (the busiest: warsupply
0.002-0.016, capture up to 0.012, labor 0.004), 0.010 in the 1v1. Every module together: 0.88-1.39 ms/tick, most of it
`production` and the AI.


## 6. Open issues

1. **Rail lines open at minute 20-36, not all before 20.** Cheaper rails and the Rail works in Age I took the 1v1 seed
   501 from minute 26 / 27 (wave A) to 20 / 24 (player / AI); in the final 4-nation runs the first lines opened at
   21-36. The AI's rail program pays rails from plates (`rails.ai_step`), so the Rail works
   matters only when the AI builds it; what still sets the date is when the AI founds its town and researches Railways,
   and its steel in Age I.
2. **Fights near rails still hit buildings.** Rails, signals, rail supports and poles are protected; belts, inserters and
   plain buildings around a fight take the engine's area damage (a division's group combat lost 5 buildings, belts and
   inserters in the probe). Belts and inserters exist in Skirmish too, so protecting them would need the same
   Nation-only rule.
3. **A stray hit makes a rail indestructible for 10 s.** An explicit attack order on it lifts that at once; a raider that
   arrives within those 10 s finds it indestructible and moves on.
4. **City-states fall often**: 13 of the 26 captures in the final runs were city-states (each AI in Age II and at peace
   goes for one on its side of the map). With 6+ turrets and a 2× centre they no longer fall to passing units; they fall
   to deliberate operations, which is the design (D7).
5. **M1-era autotest checks under four nations**: Age II after 20:00 for 5 of 20 nations, `produce` (2), `no_bad_spam`,
   `kinds_8min`, `techs_6min` (1 each). They pass in the 1v1 acceptance.
6. **Money is not yet tight.** No nation of 20 entered a debt stage; the lowest balances were ₡ 340-1,530. Imports are
   capped by the commerce cap, so most nations sit on their treasury. Sinks (mercenaries, bribes, faster projects)
   would make it matter (M3).
7. **The Territory lead rule is untested with AIs**: no AI aims at territory, and a 4-nation 60-minute match ends with
   2-5 cities per nation (a capital's land is about 0.8 % of the claimable cells of a 2048 world, a town's about
   0.45 %). The rule is tested by the fixture with patched shares.
8. **Cosmetic, from the GUI audit:** train stops show on the map as "rts-player depot 504"; a troop train standing at
   its pickup with nobody to board reads "waiting: nothing to carry".
9. **Codex GUI run** of `docs/qa/phase5-m2-protocol.md` is the lead's next step; the GUI probe walked every step's
   panels in English and Russian (screenshots `build/shots-m2d-*`).
10. **`P4.KEYS` holds only the M2 panel keys** (M, F4, N); the older keys keep their own handlers. The Nation help page
    lists all of them.
11. **Dead code:** `population.ai_step` and `population.ai_describe` are no longer called (m2-ai's governor took their
    rules over); kept for now.
12. **A human player's trains** of a line that comes back are not re-routed (the AI's are): the player routes them
    again. A player's line whose depot dies is lost (the other depot is free for a new line).
13. **M2 QA round 1** (`docs/qa/phase5-m2-qa-results.md`, Codex on 80c05d2): 27 PASS, 3 FAIL (step 20 "the train does
    not fit on the platform", step 29 the vanilla info box, step 31 the window after RTS_QA_END), 1 SKIPPED (21, after
    20). Not part of this package's fixes; section 7 has them.

## 7. QA round 1 fixes

Date: 2026-10-17. Agent: `m2-qafix`. Input: the Codex GUI run `docs/qa/phase5-m2-qa-results.md` (27 PASS, 3 FAIL: steps
20, 29 and 31; step 21 SKIPPED) and its log `build/qa-p5m2-gui.log`. Every finding was reproduced first: the troop train
headless on the QA geometry, the info box in a real client with real clicks and keys.

| # | QA finding | Cause | Fix | Where |
|---|---|---|---|---|
| 1 | Step 20: Deploy troop train enabled, the click refused "the train does not fit on the platform" (40-tile platforms, a 28-tile train) | Not the length. The log shows `rts-locomotive 1 of 4 could not be placed`: the division, brought back by the step 16 right click 6 tiles below the CC, stood across the platform track, which runs 8 tiles below the CC, right where the train's head goes (the end the line joins, under the CC for both depots). A walker is a spider-unit whose legs reach several tiles from its body; legs on the rails keep rolling stock from being placed. The same walkers had made the construction train wait (`no-room` at 503 s; robots then laid the 4 tiles). Repro `tools/probes/m2_qafix_deploy.lua`: walkers across the track, Deploy fails on the base tree (`rts-troop-wagon 2 of 4 could not be placed`), works on the fixed one. At 710 s the train appeared because the raid had pulled the walkers away. | Before the carriages are placed, own units whose body or legs (`get_spider_legs`) stand on the train's stretch of the platform track (the train's box plus 3 tiles at each end: the engine snaps rolling stock up to 2 tiles along the rail) step off it, teleported to the side away from the depot (where troops board) with their legs 2 tiles clear; a carriage that still cannot be placed gets a second step-aside. Log `rails: depot #N: K own unit(s) stepped off the platform track for a <kind> train`. (A step-aside per carriage only, the first version, left one GUI run with a carriage that did not couple: "rolling stock did not join into one train"; that log line now lists the carriage positions.) Failure reasons now say what is wrong: `no-track` (a platform rail is gone, checked over the whole train), `enemy-on-track`, `no-room` ("something blocks the platform track"). An open line drops its last construction train reason (the panel had shown "the train does not fit on the platform" under an open line). | `rails.lua` (`train_slots`, `step_aside`, `slot_problem`, `track_whole`, `rails.deploy_check`, `create_train`, `open_line`), `locale/*/rails.cfg` |
| 2 | Enabled Deploy despite a known problem; the reason only in chat | The buttons checked kit counts only. | `rails.deploy_check(depot, kind)` (platform, a train already on it, network, kits, coal, the whole track, enemies; own units do not count) enables each button; a yellow line under the buttons says why: "Freight train: no train kits in the depot network", "Troop train: the platform is occupied", "Cannot deploy a train: …" when both share the reason. | `railgui.lua`, `locale/*/rails.cfg`, `locale/*/war.cfg` |
| 3 | Step 21: "Boarding a train" for a minute with no train; the walkers walked onto the platform | `garrison.embark` set the boarding state and walked the division to the platform whether or not a train had been deployed. | An embark is taken when a troop train stands at the depot, one can be deployed there now, or one is routed through it (pickup or drop-off; the division waits for it). Otherwise it is refused: the division keeps its order, its card reads "No troop train" in amber for 10 s (the reason in the tooltip), the right click shows a flying text "No troop train to board: <reason>", and loose units are not formed into a division. | `garrison.lua` (`garrison.can_embark`, `embark`, `right_click`), `divisiongui.lua`, `divisions.lua`, `locale/*/war.cfg` |
| 4 | A right click "visually below the rails" made both divisions board and formed Division 2 from the 28 loose walkers | The log: Ctrl+A, F (`attack-move armed`), right click at (479, 29), 4 tiles below the track at y = 25. The garrison hook runs before the armed attack-move and counted the whole platform area (4 tiles each side of the track) as the depot, so the attack-move became an embark, and an embark forms loose units into a division. | With F armed the right click is an attack-move (the hook steps aside); a click counts as "on the platform" within 2.5 tiles of its track only. | `garrison.lua` |
| 5 | Step 29: the vanilla Lab box stayed under the minimap for 72 s with nothing selected (M1 finding 5 again) | A GUI probe with real clicks and keys (`tools/gui-drive.sh`, `build/shots-qf-ib1-window/`) reproduced it: the box appears when the ghost is placed from the cursor and stays after Q, with `player.selected` nil the whole time. It is not the selected entity's tooltip: `clear_selected_entity()` (the M1 fix), `selected = nil` and `update_selected_entity(empty ground)` left it; `update_entity_selection` on for one tick removed it, with the mouse over empty ground and over a ghost alike (`build/shots-qf-ib2-window/`). While the cursor still holds the ghost the box stays whatever is done (the building in hand). | `camera.hover_pulse`: hover selection on for one tick, then off, and a selection it made is cleared at once. It runs whenever the RTS cursor comes back (Q, right click, F1, the build button again: `cursor.on_tool_given`), so the box goes when build mode ends. The M1 2-second `clear_selected_entity` window is gone; a selection the engine makes by itself is still cleared every 10 ticks. Order targeting does not read `player.selected` (`selection.building_at`, the reverse-select area). | `camera.lua`, `cursor.lua` |
| 6 | The offer countdown read "119 s" for 90 s; the ceasefire offer stayed after white peace | `update_offers` returned early while the set of offers was unchanged, so the frame built at the first offer was never refreshed. A pending proposal that became pointless stayed until it expired. | The countdown labels are updated in place every 0.5 s. A pending proposal that `diplomacy.invalid` now refuses (a ceasefire or peace offer without a war, an alliance offer at war, an eliminated nation) is voided within a second (log `diplomacy: proposal #N … void (reason)`). | `diplomacygui.lua`, `diplomacy.lua` |
| 7 | The Capital name field looked blank | The field shows a custom name only; "Capital" (and "Free City of X") are localised strings, and a textfield takes plain text. | The field gets the default name from the player's client (`request_translation`, `on_string_translated`); confirming it unchanged keeps the default (no fixed name), an emptied field shows it again after the rename. | `citygui.lua` |
| 8 | Step 31: "window closure not observed", a different 00:00 match appeared | Not a game defect: `tools/gui-run.sh` kills the client 3 s after the marker, and another agent's client opened at the same place with the same title. | Protocol: the criterion is the QA match going away; a window that appears after it belongs to another session and gets no input. | protocol |

Protocol (`docs/qa/phase5-m2-protocol.md`), measured with `tools/probes/m2_qafix_gui.lua` (screenshots
`build/shots-qf-v3/`): the diplomacy panel (x 263–1017; War at ≈736, the other actions at ≈778 / 822 / 865 / 912 / 968,
Accept / Decline at ≈918 / 972, 538), the offers frame (a row per offer, 20 px apart; the peace offer's Accept at ≈(744, 173)
when an AI ceasefire offer waits above it), the depot panel (Deploy troop train stays at ≈(818, 329); the QA's y = 344
came from the stale two-line reason; the new yellow reason line), step 18 (Deploy freight train is greyed: no cargo wagon
kits), step 19 (close the rail panel, which covers Depot 2), steps 20 and 21 (walkers step off the track; "No troop train"
is a FAIL), step 25 (Accept in the peace row), step 29 (empty ground at ≈(1000, 250), 22 tiles right of the CC and 9 up,
where no step places anything; the QA's (300, 600) hit the Commander), step 31, the glossary and the recovery for a
greyed Deploy.

Checks:

| Check | Result |
|---|---|
| `tools/probes/m2_qafix_deploy.lua` (headless, 1v1 Nation 1536), on the synced tree | 9/9 on seeds 501 and 777: line open without a wait reason; Deploy with walkers across the track (6-8 bodies on it, 0 after; 24-25 units step aside); a second train "busy"; embark with a train; embark at a depot without kits refused, division idle, `no_train` set; a missing platform rail `no-track`; enemy walkers `enemy-on-track`. The same geometry on the base tree: Deploy `no-room` (`rts-troop-wagon 2 of 4 could not be placed`), the embark "boards" with no train |
| `tools/probes/m2_qafix_gui.lua`, real client, real input (`tools/gui-drive.sh`), English, on the synced tree | all checks PASS: (A) lab ghost placed with a real click, real Q, a click on (1000, 250) (`hover pulse … under the mouse: nothing`): no info box at 10, 30, 60 s in the window captures; (B) Deploy troop train enabled and the freight button greyed with its reason, the train placed with 24 walkers stepping aside, a real right click on Depot 2 without kits: "No troop train" on the card, no boarding, no new division; F and a real right click 4 tiles below the track: attack-move, no boarding; (C) countdown 118 → 107 s after 10 s, the ceasefire offer void after the white peace and the frame gone; (D) the name field reads "Capital" |
| Same, Russian client (on the work copy before the sync; the later change is the placement order only) | all checks PASS; the name field reads "Столица", the card "Нет войскового поезда", the reason line "Нельзя собрать поезд: в сети депо нет комплектов поезда" wraps inside the panel (`build/shots-qf-v3ru/`) |
| Skirmish smoke on `mods/` after the sync (`tools/autotest-run.sh smoke …` small, waves, 240) | 65/65, 0 errors |
| War autotest (`war_autotest.lua`, seed 501, speed 4), on `mods/` after the sync | 27/27, 0 errors |
| Rails autotest (`rails_autotest.lua`), on `mods/` after the sync | 12/12 beside the Skirmish AI autotest 23/23, 0 errors (one earlier run had the AI autotest at 21/22, `produce_rts-player`, a match the AI won early; the rerun and the base tree give 23/23) |
| Diplomacy acceptance (`diplomacy_accept.lua`, 4 nations, Territory), work copy | 12/12, 0 errors (the AI autotest beside it: 79/80, `cars_rts-ai-2`: no Armoured car when the Territory victory ended the match at minute 25; unrelated) |
| Divisions functional probe (`MODULE=divisions_func tools/divisions-bench.sh`), work copy | 25/25 (orders, attack-moves, right-click paths unchanged) |
| M1 acceptance, 1v1 seed 501, 60 minutes, speed 6 (`m1_acceptance.lua`, `qf-m1acc`), work copy | 53/53, 0 errors, 26,612 items by train (player 14,010 in 65 trips, AI 12,602 in 66) |

New test tooling: `tools/gui-drive.sh` and `tools/gui-input/fdrive.swift` (real clicks, keys and window captures for GUI
probes; the shell running it needs the macOS Accessibility permission; a lone synthetic mouse move is not always seen
by the game, a click is), `tools/probes/m2_qafix_gui.lua` (the GUI check above, its run lines in the header) and
`tools/probes/m2_qafix_deploy.lua` (the headless repro). Not done here: the strategic map's raw stop names ("rts-player
depot 1127", open issue 8) and the icon-only build menus noted by the tester.
