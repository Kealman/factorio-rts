# Phase 5 M2 integration (wave B): balance, gameplay fixes, HUD, acceptance, docs

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on unless noted. Agent: `m2-integ`. Contract:
`docs/PHASE5-M2.md` (§4 end-to-end acceptance, the GUI protocol list). Starting point: HEAD 792206e (tag m2-wave-a).
Package notes: `docs/qa/phase5-{people,treasury,diplomacy,war,world2}-notes.md`; the AI of wave B is `m2-ai`'s
(`docs/qa/phase5-ai-notes.md`). Everything below is Nation mode only unless it says otherwise; the Skirmish matrix at
seed 777 is line-identical to m1-ready (section 5.1).

## 1. Verdict

The M2 end-to-end acceptance passes on HEAD 1fa6fcb (m2-ai's final AI on top of this package): four normal AIs, 60
minutes, 2048 worlds, seeds 701-705, PERF=1, every criterion in every seed:

| Criterion | Needed | Result |
|---|---|---|
| Lua errors | 0 | 0 in every run |
| UPS at speed 1, last 5 minutes | 60 | 60.0-60.2 s of wall clock per game minute in every seed |
| Every nation trades | every seed | 5 of 5 (the lowest nation ₡ 4,479-6,614 of volume) |
| At least one war declared | 4 of 5 seeds | 5 of 5 (20 wars) |
| At least one peace signed | 4 of 5 | 5 of 5 (16 treaties: 8 cessions, 3 tributes, 5 white) |
| At least one city changes hands | 3 of 5 | 5 of 5 (26 captures: 13 between nations, 13 city-states) |
| No nation starving (a city below 50 % rations for more than 3 minutes) | in at most 1 seed | 0 seeds |
| Save and load at minutes 20 and 40 (4 nations, seed 702) | 0 errors | 0 errors in both halves of both (loaded runs to minute 60 and 61) |
| M1 acceptance, 1v1 seed 501, 60 minutes | passes | 53/53, 26,492 items by train, 60 UPS |
| Skirmish matrix | unchanged | 0 differing lines against m1-ready (10 scenarios, seed 777) |
| M2 modules' cost | ≤ 0.5 ms/tick | 0.024-0.038 ms/tick in the last 5 minutes (4 nations) |

Not met: rail lines do not all open before minute 20 (the 1v1 at 20 and 24, the 4-nation AIs at 21-48; section 6).
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
  city-name counter for every nation and 24 names (every nation's first town was "Ironford").
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
| `scripts/wars.lua` | the Territory lead rule |
| `scripts/debug.lua` | `/rts-supply`, `/rts-goto`, `/rts-diplomacy` |
| `scripts/lobby.lua`, `scripts/diplomacygui.lua`, `scripts/divisiongui.lua`, `scripts/railgui.lua` | the GUI audit's fixes |
| `balance.lua` | rails, Rail works recipe, upkeep exemptions, territory victory, city-state garrison and armour |
| `locale/{en,ru}/{cities,demolish,diplomacy,hud,war,people}.cfg` | new and fixed texts (keys identical in both languages) |

## 4. Acceptance in detail

### 4.1 M2 end-to-end: 4 normal AIs, 60 minutes, 2048, seeds 701-705

```sh
PERF=1 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m2_acceptance.lua DURATION_MIN=60 SEED=701 SPEED=8 \
  tools/autotest-run.sh m2acc-t8-701 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
  enemy_brain = "ai"}' 10000
```

The tree is `mods/factorio-rts` at 1fa6fcb. The fixture switches the game to speed 1 for the last 5 minutes.

| Seed | AI autotest | Lowest nation's trade (₡) | Wars / back to peace / ended | Cities changed hands (nations, city-states) | Starving | Speed-1 minutes (s) |
|---|---|---|---|---|---|---|
| 701 | 81/82 | 4,846 | 4 / 3 / 3 | 7 (3, 4) | none | 60.0 60.0 60.0 60.1 60.0 |
| 702 | 81/83 | 6,614 | 4 / 4 / 4 | 4 (2, 2) | none | 60.0 60.0 60.0 60.2 60.0 |
| 703 | 82/83 | 4,532 | 5 / 4 / 4 | 7 (6, 1) | none | 60.0 60.0 60.0 60.1 60.0 |
| 704 | 80/83 | 6,179 | 4 / 3 / 3 | 6 (2, 4) | none | 60.0 60.0 60.0 60.2 60.0 |
| 705 | 79/83 | 4,479 | 3 / 2 / 2 | 2 (0, 2) | none | 60.0 60.0 60.0 60.1 60.0 |

Seed 703, for example: war at 17:00, the player's town ceded at 25:00 with peace, a new war at once, a city-state taken
at 32:00, a third war at 35:00 in which the player takes its town back at 37:00. Per nation (Age II, first line open,
items by train, the treasury's lowest balance):

| Seed | rts-player | rts-ai-1 | rts-ai-2 | rts-ai-3 |
|---|---|---|---|---|
| 701 | 14:37, 21 min, 0, ₡ 1,405 | 18:37, 31, 3,772, ₡ 1,370 | 16:26, 28, 10,551, ₡ 540 | 14:28, 23, 9,890, ₡ 401 |
| 702 | 18:30, 25, 4,819, ₡ 437 | 18:24, 29, 10,625, ₡ 586 | 20:07, 48, 0, ₡ 1,148 | 17:15, 21, 13,146, ₡ 662 |
| 703 | 17:30, no line, 0, ₡ 1,253 | 16:51, 35, 3,063, ₡ 930 | 17:44, 23, 9,639, ₡ 340 | 17:35, 21, 13,779, ₡ 511 |
| 704 | 21:30, 36, 7,172, ₡ 483 | 19:59, 32, 10,275, ₡ 1,530 | 20:24, 21, 10,335, ₡ 802 | 18:46, 26, 11,856, ₡ 641 |
| 705 | 17:50, 22, 6,420, ₡ 509 | 21:41, 23, 7,937, ₡ 1,211 | 15:28, 23, 0, ₡ 1,478 | 20:35, 23, 11,854, ₡ 1,156 |

No nation entered a debt stage. The AI autotest's remaining failures are M1-era checks under four nations: Age II
after 20:00 (`age2_<force>`, 5 nations), `produce` (2), `no_bad_spam`, `kinds_8min`, `techs_6min` and
`rail_line_rts-player` in 703 (its town was fought over; m2-ai's notes).

**Earlier runs of the same set** (the integration tree with an older AI):

| AI | War | Peace | Capture | Starving seeds | Notes |
|---|---|---|---|---|---|
| wave A (792206e's AI), `m2acc-t3-*` | 4/5 | 4/5 | 4/5 | 5 of 5 | new towns at minute 16-26 eating their 40 start rations with nothing arriving, a capital at minute 18, freshly captured city-states; 704 ended at 39:00 when rts-player lost its only city |
| m2-ai's first pass (c71c4ef), `m2acc-t7-*` | 4/5 | 4/5 | 4/5 | 1 of 5 | 701 stayed at peace |
| final (1fa6fcb), `m2acc-t8-*` | 5/5 | 5/5 | 5/5 | 0 | the table above |

The city-state granary (2.A) came from the wave A baseline's starving captured city-states.

### 4.2 M1 acceptance, 1v1 seed 501, 60 minutes (`m2i-t8-501`, `tools/probes/m1_acceptance.lua`)

53/53 checks, 0 Lua errors, both nations alive at 60:00, 60.0 s of wall clock per minute at speed 1 in minutes 56-60.

| | rts-player | rts-ai-1 | wave A HEAD (`m2i-base-501`) |
|---|---|---|---|
| Age II | 16:59 | 17:40 | 17:20 / 16:22 |
| First line open (minute line) | by 20 | by 24 | by 26 / 27 |
| Items by train | 13,890 | 12,602 | 7,589 / 12,536 |
| Treasury low | ₡ 603 | ₡ 511 | ₡ 483 / 494 |

26,492 items by train together (goal 20,000; wave A HEAD 20,125).

### 4.3 Save and load

`SAVE_MINUTE=20` and `SAVE_MINUTE=40 SPEED=8 DURATION_MIN=60 SEED=702 KEEP_TREE=<1fa6fcb tree> tools/saveload-check.sh
m2i-t8-sl20|40 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 300`:
saved at minute 20 (towns, lines building, the first war) and 40 (wars, captures, contracts, troop and freight trains),
loaded and run on to minute 60 and 61; 0 errors in both halves of both runs. An earlier tree (m2-ai's WIP, `m2i-sl20|40`)
gave the same.

## 5. Checks of this package

### 5.1 Skirmish unchanged

`SEED=777 tools/autotest-matrix.sh` on wave A HEAD (`m2i-head`) and on the final tree (`m2i-t8`, 1fa6fcb), compared with
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

### 5.2 Fixtures (on the final tree, 1fa6fcb; 0 Lua errors in every run)

| Fixture | Result |
|---|---|
| `m2_integ.lua` (1v1 Nation 2048, victory Territory, seed 501) | 11/11: upkeep (a house and a farm +0, a factory +0.5), 6 turrets per city-state, a city-state centre loses 50.0 of a 100 hit, a captured city-state's granary (212 rations), rails 1 + 1 → 2 and the Rail works and depot recipes enabled by Railways in Age I, under attack after a hit on a capital barracks, Disband (armed, done, 3 walkers gone, residents +3), `/rts-supply` and `/rts-diplomacy propose`, a stray hit on a rail undone and an explicit attack destroying it, the territory floor (2.5 % vs 1 %: no count) and lead (3.5 % vs 1.5 %: victory after 181 s) |
| `m2_targeting.lua` | 5/5 (section 2.B) |
| wave A fixtures on the integration tree | war autotest 27/27, diplomacy acceptance 12/12, people 14/14, treasury 12/12, world2 7/7 |
| Skirmish smoke (seed 9090) | 65/65 before every commit |

### 5.3 Performance (PERF=1, last 5 minutes at speed 1)

M2 modules (population, labor, treasury, market, diplomacy, wars, warsupply, capture, garrison, strategic, world,
targeting and their panels) together: 0.024, 0.034, 0.034, 0.038, 0.028 ms/tick in seeds 701-705 (the busiest: warsupply
0.008-0.016, market up to 0.008, labor 0.005), 0.010 in the 1v1. Every module together: 0.57-1.29 ms/tick, most of it
`production` and the AI.


## 6. Open issues

1. **Rail lines open at minute 20-48, not all before 20.** Cheaper rails and the Rail works in Age I took the 1v1 seed
   501 from minute 26 / 27 (wave A) to 20 / 24 (player / AI); in the 4-nation runs the first lines opened at 21-48 and
   one nation of 20 opened none. The AI's rail program pays rails from plates (`rails.ai_step`), so the Rail works
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
