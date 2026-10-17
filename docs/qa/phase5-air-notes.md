# Phase 5 M3: air units, anti-air and the airfield (air.lua, airgui.lua, prototypes/air.lua)

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on unless noted. Agent: `m3-air` (wave A). Contract:
`docs/PHASE5-M3.md` (D4; section 1; section 2 "Air units, anti-air, airfield"; section 3 "air.lua"; section 4 "Air";
section 5). Study: `docs/research/scale/war-ai-performance.md` sections 1.2 and 2.7. Work copy:
`build/p5m3-air/factorio-rts`, made from `mods/factorio-rts` at HEAD 2a3740a plus the uncommitted M2 QA-fix edits of
that moment (balance.lua, citygui.lua, market.lua, rails.lua); that tree is kept as the merge base in
`build/p5m3-air/base`. `build/p5m3-air/sync.sh` merges the shared hunks three-way into a target tree. **Synced into
`mods/factorio-rts` on HEAD 497cb1c (m2-ready)** after a dry run against the live tree (the M2 QA fixes had changed
`divisions.lua` and `divisiongui.lua`): every file merged without a conflict. On `mods/` after the sync: Skirmish smoke
65/65, air autotest 14/14, Skirmish no-air check 3/3, GUI probe 8/8 in English and 8/8 in Russian; 0 Lua errors.

Everything here is Nation mode only: Skirmish has no plane, kit, airfield or AA turret (checked below), and its smoke
stays 65/65.

## 1. Results

| Check (section 4 "Air" and the brief) | Result | Evidence |
|---|---|---|
| A scout plane crosses a lake and a wall | PASS | a division of 3 scouts over a 30-tile lake band and a 121-tile wall line, 150 tiles in 7.1 s; never in a unit group |
| An AA turret hits a plane and a gun turret does not fire at it | PASS | a hovering bomber (600 HP) dies in 5.4 s; the gun turret beside it keeps 20 of 20 magazines, then kills a drone (control) |
| A plane at supply 20 returns to its airfield and rearms | PASS | an interceptor at 21, 160 tiles out: returning after 0.4 s, on the apron after 7.6 s, full and let go after 15.4 s, 9.7 tiles from the airfield, idle |
| A plane at 0 crashes with an alert | PASS | a plane of a force without an airfield at supply 3: "no airfield" alert, crashed after 3.0 s, `air.state` = "crashed", "plane-crashed" alert and chat line |
| A bomber division destroys a depot x2 faster than the same cost in walkers | PASS | rail depot (1,500 HP), 40 tiles out: 2 bombers (cost 128) destroy theirs 1.5 s after the first hit and 4.1 s after the order, 11 walkers (cost 132) 5.3 s and 9.2 s: x3.5 from the first hit, x2.3 from the order (the check requires both) |
| 60 planes cost <= 0.1 ms/tick | PASS | +0.026 ms/tick wholeUpdate in `--benchmark` (with vs without 60 patrolling planes, two interleaved pairs of 3,540 ticks); the `air` module 0.005-0.007 ms/tick under PERF=1 (section 5) |
| Aviation needs Age II, Air Force Age III | PASS | `research.status`: Aviation "available" at Age II, Air Force "age" until Age III; a bomber is locked before; kit recipes enabled by the research |
| Plane kits need an airfield in the barracks' city; planes appear there | PASS | a scout kit waits with the block "airfield" (HUD line "Waiting: no airfield in this city"); 1 s after the airfield is placed the scout stands 2.5 tiles from it |
| One airfield per city | PASS | a second in the city "one-per-city"; outside the city "not-own" (players' ghosts and robot builds are refused with a flying text) |
| Planes in divisions, terrain-free | PASS | 2 scouts + 4 walkers in one division: the planes never join the unit group, all 6 arrive, the division ends idle |
| Patrol order | PASS | 3 interceptors: state "patrolling", all 3 move on along the circle, at most 30.8 tiles from the centre (r = 30) |
| Planes return on order; held planes sit division orders out | PASS | `air.order_return`: 3 of 3 returning; a move order to that division is refused ("planes at an airfield"), the 3 keep their return |
| An all-plane division keeps its war supply points | PASS | 100.0 SP after 30 s of patrol (planes have their own supply) |
| Scout reveal (fog.lua) | PASS | fog charts 45 chunks for the test force with a scout at a far point, 26 with a walker there (64 vs 24 tiles) |
| Panel logic (headless) | PASS | an armed patrol takes the fake player's right click (2 planes on patrol), a player move order then takes both patrolling planes; the HUD lines of an airfield and an AA turret |
| GUI in the real client (`tools/probes/air_gui.lua`, 1280x800, English and Russian, on `mods/`) | 8/8 each | the airfield's building page ("Airfield of Capital", "Planes within 24 tiles: 8 (0 rearming)"); Y opens the panel (right edge under the minimap, the Russian table fits at 500 units); Patrol arms (button and cursor text), a right click sends 8 planes on patrol; the 3 interceptors' division card says "Patrol" and the selection line "Order: Patrol"; an enemy bomber over the AA turret dies (1-3 magazines used); Return to airfield sends all 8 home and the division is idle again; F11 shows the "Air:" line (the Russian page ends at about 695 of 800 px). Fixed on the way: the panel covered the map centre, counted planes only after the supply step had registered them, the Russian table overflowed, plane orders showed raw ("patrol") in the selection line, a division sent home stayed "patrolling". Screenshots `build/shots-p5m3air-mods-en/`, `build/shots-p5m3air-mods-ru/` (`rts-air-gui-1-airfield-page` ... `7-help`) |
| Skirmish smoke | 65/65 | `tools/autotest-run.sh smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` on the copy (intermediate and final tree) |
| Skirmish gets no planes or AA | 3/3 | `air_skirmish.lua` beside a Skirmish AI match (1v1 small), minutes 1-3: both techs disabled and unresearched, the 5 recipes disabled, no plane, airfield or AA turret, no plane record (intermediate and final tree) |
| Base game (no Space Age) | loads | map creation with `VARIANT=base`: every prototype loads (the planes, airfield and AA turret use base-game graphics only) |
| M1 Nation acceptance, seed 501, 60 minutes | 53/53 | twice (an intermediate tree and the final one), identical: 0 errors; Age II 16:59 / 17:40 (as the M2 integration run); 26,612 items by train (M2: 26,492); minutes 56-60 at speed 1: 60.0-60.1 s of wall clock per game minute |
| Lua errors | 0 | in every run listed here |

Scripted autotest: `tools/probes/air_autotest.lua`, 14/14 on the final tree (`air autotest summary 14/14`, run
`p5m3air-at8`; the first runs found two bugs of the test itself and the bombers' crash of deviation 2). Command:

```sh
mkdir -p build/runs/<run>/saves   # only air_perf.lua saves
STOP_ON="air autotest summary" SPEED=4 SEED=501 KEEP_TREE=build/p5m3-air/factorio-rts \
  EXTRA_LUA=build/p5m3-air/tools/probes/air_autotest.lua tools/autotest-run.sh p5m3air-at \
  '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1500
```

## 2. Engine probe (`tools/probes/air_engine_probe.lua`, before the module was written)

| Question | Answer |
|---|---|
| A `unit` with `collision_mask = {layers = {}}` over water and walls | 5 of 5 scouts crossed a 40-tile water band and a wall line within 15 s, 25.2 tiles/s |
| A unit group of such units | 5 interceptors in one group crossed too (the group paths with its members' mask). A mixed group moves at its slowest member's speed (M1 divisions notes) and was not probed with planes: divisions fly their planes outside the group |
| `render_layer = "air-object"`, `affected_by_tiles = false` on `UnitPrototype` | accepted; in the client the planes float above the airfield with their shadows on the ground and their selection boxes on the lifted bodies (GUI probe screenshots) |
| `LuaEntity.speed` of a plane | readable (0.456 for the scout) and writable |
| AA turret `attack_target_mask = {"rts-air"}` | fires at planes only: 76 hits on a hovering bomber |
| Gun turret `ignore_target_mask = {"rts-air"}` | never fires at a plane (magazines untouched), still kills a drone |
| Walkers and drones vs a plane | both hit it (walker 8 per shot after 60 % physical, drone bite 11) |
| Bomber hit on a building with "rts-structure" | 180 + 180 bonus + 30 splash per bomb; on a heavy 180 + 30 (no bonus) |
| Interceptor hit on a plane | 4 + 8 bonus per shot after resistance (x3), on a drone 10 (no bonus) |
| Area triggers on a plane | an artillery shell aimed at a hovering interceptor did not damage it: area attacks without `ignore_collision_condition` (artillery, heavy splash, the bomber's splash) miss planes; the bonus areas set the flag and reach them |
| `create_entity` / `find_non_colliding_position` over water | both return the requested position |

## 3. Design

**Prototypes** (`prototypes/air.lua`, loaded last in `data-updates.lua`).
- Planes are `unit`s cloned from `rts-drone` with an empty collision mask, `render_layer = "air-object"`, combat-robot
  graphics (defender for the scout, destroyer for the bomber at x1.5 and the interceptor) lifted 1.5 tiles above their
  shadow, fixed tints (units take no force colour), 60 % physical resistance and 100 % against `rts-attrition`,
  trigger target mask `{"common", "rts-air"}`. Numbers in `balance.units[...]` (kind, supply, cost, health, speed,
  attack) and `balance.nation.air`.

| Plane | Unlock | Supply | Cost | HP | Speed (walker = 1) | Attack |
|---|---|---|---|---|---|---|
| Scout plane | Aviation (Age II) | 1 | 1 engine, 4 circuits, 10 iron | 150 | 2.4 (25 tiles/s) | none (vision 1: never distracted); reveals 64 tiles |
| Bomber | Air Force (Age III) | 3 | 2 engines, 6 steel, 8 explosives, 4 circuits | 600 | 1.2 | 180 explosion per 1.5 s at 6 tiles, splash 30 within 2; x2 against "structure" |
| Interceptor | Air Force (Age III) | 2 | 2 engines, 4 steel, 2 advanced circuits | 300 | 2.0 | 10 physical every 10 ticks at 16 tiles; x3 against "air" |

- Airfield: 6x6 `simple-entity-with-owner` with the cargo landing pad's graphics at 0.75 (base game), 2,500 HP, factory
  recipe 20 steel + 40 concrete + 10 circuits (Aviation). AA turret: the RTS gun turret tinted, 1,000 HP, range 30, a
  round every 6 ticks at 6x magazine damage (120 damage/s against a plane after its resistance), factory recipe 30 iron
  + 10 steel + 5 circuits (Aviation). Both in the "Age II" factory tab; the build menu has the airfield in Production
  and the AA turret in Defence (Nation only).
- Masks: every other `rts-*` turret (`rts-turret`, `rts-laser-turret`, `rts-bunker`, `rts-fort`, `rts-garrison-turret`
  and any later one) gets `ignore_target_mask = {"rts-air"}`; every entity named in `balance.buildings` carries
  "rts-structure" for the bomber's bonus. Technologies Aviation (30 industrial kits) and Air Force (50, after Aviation)
  are last in tree order, so the Phase 4 AI, which researches "the rest in tree order", reaches them after everything
  else and never builds an airfield.

**Supply** (`scripts/air.lua`, every 60 ticks over all planes): +10/s within 24 tiles of an own airfield, -1/s
elsewhere; a flying plane turns back at 20, or earlier when the flight home needs more (bingo: distance / speed x
drain x 1.25 + 5); it flies to a slot on the airfield's apron (claim issuer "air", order "return"), waits until full
("rearm"), and is let go (idle; a patrolling plane resumes its patrol unless a later division order replaced it). At 0
it dies with an alert and a chat line. A plane whose airfield is destroyed or captured goes to the nearest other one,
or is let go when there is none (one "no airfield" alert, then it crashes at 0). Planes from a barracks register when
they spawn; any other plane (console, scripts) within 10 steps.

**Production.** The kit gate (wrapped like `treasury.lua` does) holds a plane kit with the block "airfield" while the
barracks' city (territory, else the force's nearest city) has none; `production.exit_of` puts the plane on that city's
airfield, where it stays (the barracks' rally is for ground units) unless a division takes it as a reinforcement.
Plane kits enter `production.KITS` from `air.lua`, after `ai/mix.lua` built its kit table: the M1/M2 AI never chooses
one (wave B's air AI decides).

**Divisions and orders.** A division order flies its planes to their formation slots by direct commands (an attack on
a point with an enemy building strikes it); with ground members the planes are kept out of the group's rejoin pass and
stop at their slots, an all-plane division "settles" (done when every plane arrived, or 20 s after the slowest one's
flight time). Planes that return or rearm sit division and player orders out. `air.order_patrol(division, pos, r)`:
the planes circle six waypoints, engaging what they meet (scouts never engage); an all-plane division on patrol has the
state "patrolling", which the division controller leaves alone; any division order ends it, and a player order takes a
patrolling plane (`units.yields`). Loose planes get the same through `air.patrol_units` / `air.return_units`.

**War supply.** Planes have their own supply (`warsupply.exempt`): an all-plane division neither uses nor refills
supply points, a plane's hits (given or taken) do not make its division "engaged", the out-of-supply wear skips planes,
and no attack order is refused to a plane. Planes are immune to territory attrition (resistance).

**Panel (Y, `scripts/airgui.lua`).** Airfields (city, planes within 24 tiles, Show), planes per kind (total, flying,
returning, rearming, mean supply), the selected planes' supply range and two buttons: Patrol (arms it; the next right
click is the centre, radius 40) and Return to airfield; the supply rule as a hint. 500 GUI units wide, at the right edge under the minimap. The HUD's
building page of an airfield and an AA turret gets lines from `airgui.building_lines`; the Nation help page (F11) a line
"Air:"; the key Y is in `P4.KEYS`; the selection line and the division card name the planes' orders (patrol, returning,
rearming). Both locales (`locale/en|ru/air.cfg`, the same 65 keys).

**API for wave B and the other packages:** `air.is_plane`, `air.supply`, `air.state`, `air.airfields`,
`air.airfield_of_city`, `air.can_build_airfield(force, position)`, `air.order_patrol`, `air.order_return`,
`air.patrol_units`, `air.return_units`, `air.planes(force)`, the blackboard `storage.nations[force].air = {planes,
by_kind, airfields, returning, rearming, crashed}`, console `/rts-air [force]`. The fort belt (`m3-war2`) places
`rts-aa-turret` (2x2, kind "aa-turret", territory class "outpost").

## 4. Deviations from the contract, with reasons

1. **Trigger target type "rts-air", not "air".** Every RTS target type has the prefix (`balance.target_types`, made by
   `prototypes/categories.lua`); the key is `air`. A second type "rts-structure" (key `structure`) marks every RTS
   building for the bomber's x2 (a building carries only "common" by default, which units carry too).
2. **Bingo return.** The contract says "returns on its own at 20". In the first autotest run two bombers 200 tiles out
   turned back at 20 and crashed 35 tiles short of the airfield. A plane now turns back at 20 or when the flight home
   needs more.
3. **Planes ignore territory attrition** (100 % `rts-attrition` resistance): attrition is the ground units' supply
   rule; planes have their own.
4. **Area attacks miss planes** (engine behaviour of an empty collision mask, probe H): artillery shells, the heavy's
   splash and the bomber's splash do not hit them. Direct attacks (walkers, drones, AA turrets, interceptors) do; the
   Commander's rockets were not tried. The contract accepted ground fire on planes; the 60 % physical resistance
   stands.
5. **The AA turret's kind is "aa-turret", not "turret"**: kind "turret" means a ground defence to the rest of the code
   (`production.lua` feeds it, the AI budgets magazines per turret and counts build-order steps by kind,
   `scripts/buildings.lua`'s registry notes). `air.lua` feeds AA turrets with magazines the same way (below 5, 10 at a
   time, every 120 ticks).
6. **Patrol is the planes' order.** In a mixed division only its planes patrol (the ground part keeps its order) and
   the division panel shows no "patrolling" state (open issue 2).
7. **Bomber speed 1.2 (0.9 in the first runs).** With 0.9 the bombers destroyed the depot 3.5x faster than the
   walkers from the first hit but only 1.9x from the order (their 6-tile range makes them fly 34 tiles where walkers
   walk 20); at 1.2 it is x2.3 from the order, and the bomber is still by far the slowest plane (2.0 and 2.4 for the
   others).
8. **Tests set Age III directly** (`storage.ages[force].age = 3`): `ages.MAX_AGE` is 2 until `m3-age3` lands. Air
   Force uses the industrial kit; switch it to an Age III kit if `m3-age3` adds one (`balance.nation.air.techs`).

## 5. Performance

- `--benchmark` of two saves of the same Nation match (1v1, 2048, seed 501, minutes 1-2), the second with 60 planes
  (20 per kind) of one division patrolling 100 tiles from their airfield (they drain, turn back, rearm and resume), two
  interleaved pairs of 3,540 ticks each on the final tree, while other agents' servers ran on the machine:

  | Column (mean ms) | No planes | 60 planes | Difference |
  |---|---|---|---|
  | wholeUpdate | 0.396 / 0.394 | 0.420 / 0.422 | +0.026 |
  | entityUpdate | 0.061 / 0.060 | 0.078 / 0.078 | +0.017 |
  | scriptUpdate | 0.056 / 0.054 | 0.067 / 0.067 | +0.012 |
  | pathFinder | 0.023 / 0.023 | 0.023 / 0.023 | 0 |

  A first pair on the intermediate tree gave +0.012 ms (0.325 -> 0.337). Saves:
  `build/runs/p5m3air-perf2/saves/p5m3air-perf0|60.zip` (the fixture is inert in a single-player benchmark; the planes
  keep flying there, so the load of a save with planes mid-patrol works).
- PERF=1 (`tools/probes/air_perf.lua`, the same fixture over 6 minutes at speed 3: 180 returns, 178 rearms, no crash):
  the `air` module 0.0050, 0.0070, 0.0073, 0.0071, 0.0069 ms per tick in minutes 2-6, 0.0002 before the planes. Its
  supply step over 60 planes costs about 0.1 ms (20 steps profiled: 2.0-2.4 ms), once per 60 ticks.
- Without planes: 0.0002 ms/tick at minute 60 of the M1 acceptance on the final tree (0.0028 on the intermediate tree,
  before the scan of the unit registry for planes that did not come from a barracks was cut to every 10th step).

## 6. Shared hunks (marked `-- Phase 5 M3 air`; line numbers in `mods/factorio-rts` after the sync)

| File | Line(s) | Hunk |
|---|---|---|
| `control.lua` | 77-81 | `require("scripts.air")`, `require("scripts.airgui")` after diplomacygui, before debug |
| `data-updates.lua` | 19-21 | `require("prototypes.air")` last |
| `balance.lua` | 920-991 | `target_types.air` / `.structure`, `balance.units` of the 3 planes, `balance.nation.air`, `balance.buildings` of the airfield and the AA turret |
| `scripts/units.lua` | 36-39 | `units.yields` hook (nil by default) |
| `scripts/orders.lua` | 399-402 | `resolve`: a unit whose claim yields (`units.yields`) takes a player order |
| `scripts/production.lua` | 96-98, 434 | `production.exit_of` hook; `spawn_from_kit` uses it |
| `scripts/divisions.lua` | 74-80, 227-228, 294-348, 485, 608-610, 618, 659-666, 672, 674-675, 810, 975-976 | hooks `flying`, `held`, `air_strike`; `eligible` honours `units.yields`; `split_air`, `movers`, `fly`; `order` splits the planes off (hold/stop include them, no group for an all-plane division, log `planes=N`); `add_units` keeps planes out of the group; `arrive` uses `movers`; a joining plane stays out of the group |
| `scripts/warsupply.lua` | 58-62, 315-325, 541, 556, 580, 588, 631 | `warsupply.exempt` hook and its five uses |
| `scripts/fog.lua` | 39, 110 | `fog.RADIUS_BY_KIND`, used per unit in `update_force` |
| `scripts/hud.lua` | 159-162, 228-230, 235-238, 292-293, 296, 1460-1461, 1620-1622, 2407 | Nation-only items and the help line; plane kinds in `KIND_KEYS`; the planes' orders in `ORDER_KEYS`; the airfield (Production tab) and the AA turret (Defence tab); the barracks block "airfield"; airfield / AA building lines; `P4.KEYS` Y |
| `scripts/divisiongui.lua` | 72 | `ORDER_KEYS.patrol`: a division on patrol says "Patrol" on its card |

Own files: `scripts/air.lua`, `scripts/airgui.lua`, `prototypes/air.lua`, `locale/en/air.cfg`, `locale/ru/air.cfg`;
tests `tools/probes/air_autotest.lua`, `air_perf.lua`, `air_skirmish.lua`, `air_engine_probe.lua`, `air_gui.lua`
(GUI: copy into `scripts/` of a test copy and append `require("scripts.air_gui")` to its `control.lua`, then
`RTS_LOCALE=en|ru tools/gui-run.sh <copy> 300 RTS_AIR_GUI_PROBE_DONE`)
(in `build/p5m3-air/tools/probes/` until the sync).

## 7. Open issues

1. **Ground divisions do not destroy a rail depot** (pre-existing, not air): a division of 8 walkers ordered to attack an
   enemy `rts-depot` in Nation mode hits it 3 times (60 HP) and then stands about 18 tiles off in group state
   "attacking_target" for 40+ s. Reproduced on the base tree (`build/p5m3-air/base`, no air code) with a lab-surface
   probe (`build/p5m3-air/tools/divdiag_depot.lua`, EXTRA_LUA, Nation 1v1); 11 loose walkers (`orders.attack`) destroy
   one in 5.3 s from the first hit. Likely the M2 Nation attack (compound go_to + attack_area of radius 2 at the depot,
   whose composite parts and protected rails and poles surround it). Forwarded to `m3-war2` by the lead.
2. (Fixed at the lead's request: `divisiongui.lua` line 72 names the patrol on the division card.)
3. The research panel's "Needs Age II" (`rts.tech-status-age`, economy.cfg) is also shown for Air Force (Age III):
   `m3-age3`'s Age III work.
4. No AI uses air yet: wave B (`m3-ai`) gets the API above. AI forces see nothing through a scout (AI sight is
   scripted, `ai/scout.lua` / `intel`); fog.lua's reveal is for charted (human) forces, and no AI decision may read
   chart state (m3-perf: it desyncs a LAN game).
5. The GUI probe drives the panel through events (the button clicks are dispatched, the right click goes through
   `orders.handle_reverse_area`); the Codex GUI protocol should still click Y, Patrol, a map point, Return and the
   airfield by hand. The cargo landing pad's graphics read as a large machine more than a runway; better art is open.
6. Planes have no ammunition of their own: "rearm" is the supply number.
7. The Nation help page (F11) is near its height limit in Russian (about 695 of 800 px with the "Air:" line); further
   M3 lines may need a scroll pane.
