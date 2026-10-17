# Phase 5 M3 war2: fronts, hold line, fort belts, artillery and armoured trains

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m3-war2` (wave A). Contract:
`docs/PHASE5-M3.md` (D5, D6; section 3 "fronts.lua / belts.lua / trainswar.lua"; section 4 "Fronts / belts /
trains"). Studies: `docs/research/scale/war-ai-performance.md` 2.4 and 2.6, `docs/research/scale/rails-trade.md` R2.
Work copy: `build/p5m3-war2/factorio-rts`, first taken from `mods/factorio-rts` at HEAD 9263e69, rebased onto dc3218e
plus the M2 QA round 1 edits (`rails.create_train` was refactored there, so the rails hunk was re-applied by hand) and
then onto d27417c (the M3 air snapshot: the add-add conflicts in `control.lua`, `balance.lua`, `hud.lua` and the
`create_train` comment kept both sides, `build/p5m3-war2/merge3.py`). The untouched trees are
`build/p5m3-war2/base/factorio-rts` (d27417c, the base of `sync.sh`), `base-dc3218e` and `base-9263e69`; the earlier work
copies are `factorio-rts-dc3218e` and `factorio-rts-pre-rebase`. `build/p5m3-war2/sync.sh [target]` merges the shared
hunks three-way and copies the own files.

**Synced into `mods/factorio-rts` on 2026-10-17** (lead's "sync open", on 26ad517 = air + Age III snapshots, clean): the
three-way merge (`build/p5m3-war2/merge3.py`) kept every air and Age III line; the only conflict was the require list
in `control.lua` (both sides added lines at the same place: kept both, war2 after age3). The work copy is now the
synced tree (`build/p5m3-war2/factorio-rts`, base `base` = 26ad517; the d27417c copy is `factorio-rts-d27417c`).
On `mods/` after the sync, 0 Lua errors in every run: Skirmish smoke 65/65, war2 autotest 22/22, M2 war fixture 27/27,
air autotest 14/14, Age III fixture 35/35. Everything is Nation mode only; Skirmish runs as before.

## 1. Results (0 Lua errors in every run; on the d27417c work copy unless marked)

| Check (contract section 4 and the lead's list) | Result | Evidence |
|---|---|---|
| A war between two nations with touching land yields >= 2 segments with threat values | PASS | rig of 2 + 2 tier-3 cities, war declared: rts-player 2 segments (chords 160 and 152 tiles, threat 56), rts-ai-1 2 segments (threat 58) |
| `hold_line` spreads a 24-unit division along a 160-tile chord within 20 s | PASS | arrived in formation after 8.5 s, worst member 1.6 tiles from its slot, members cover 97 % of the chord, stance hold, segment holder set |
| A 200-tile belt is planned and built within 3 minutes with the right item debit, gates where the rail crosses | PASS | 219 pieces (199 walls, 2 gates, 17 turrets, 1 field depot) built in 54.5 s; both gates stand on the rail's tiles; the rig cities' networks lost exactly the built pieces (199 / 2 / 17 / 1) and the 170 magazines debited for the turrets; 17 of 17 turrets carry the priority list; a point on the enemy's land is refused (`not-own`) |
| An artillery train in bombard destroys a turret at 100 tiles within 60 s and spends shells | PASS | turret (1,200 HP) destroyed after 22 s with 3 shells (420 explosion damage each); wagon + depot shells 40 -> 37 = 3 fired; the train disbanded at its depot returned its 20 shells |
| An armoured train survives 3x the damage of a plain one | PASS | 50-point physical hits: a plain locomotive died after 2,050, the armoured one took 6,150 and stood at 417 / 3,000; troop wagon 1,650 vs 4,950 (321 / 2,400 left) |
| Armoured troop train from armoured kits, troops ride in it | PASS | `rails.create_train(depot, "troop", {armoured = true})`: armoured locomotive, 2 armoured troop wagons, armoured locomotive; `garrison.TWAGONS` holds the armoured wagon |
| A division ordered to attack an enemy rail depot destroys it (m3-air's `divdiag_depot`, lead's item) | PASS | 8 walkers: the group stalled at the depot after 7 hits, the watchdog switched to member strikes after 5 s, depot destroyed after 20.5 s (before: the group stood 18 tiles away for 40+ s, firing at the depot's immune hidden pole and power entity) |
| AA turrets in a belt (m3-air's `rts-aa-turret`) | PASS | the 200-tile layout: none in Age I, 6 in Age II with Aviation |
| Artillery needs a spotter | PASS | no target without an own entity within 48 tiles of the turret; a walker 35 tiles from it (outside its range) makes it a target |
| GUI probe `tools/probes/war2_gui.lua` (real client, 1280x800), English and Russian | 10/10 each | front card and Hold line, hold_line in the game view (front line and label), the fort belt button and tool panel with the preview, Build, the depot panel (kits, Deploy artillery train, Armoured), the artillery train panel and B, the help page; every panel fits at 1280x800 in both languages; screenshots `build/shots-p5m3w2-gui-en/`, `build/shots-p5m3w2-gui-ru/` |
| Skirmish smoke (seed 9090, `{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}`) | 65/65 | on every copy; `build/p5m3w2-smoke5-server.log` |
| M1 Nation acceptance, seed 501, 60 minutes (`tools/probes/m1_acceptance.lua`, speed 6, last 5 minutes at speed 1, PERF=1) | 53/53 | before the division fix: Age II 16:59 / 17:40, 26,612 items by train, 60 UPS in minutes 56-60; with it (dc3218e copy): 53/53, 20,163 items (see open issue 2); d27417c copy: 53/53, Age II 16:59 / 17:40, 20,163 items, 60 UPS (60.12 s wall per game minute in minute 60) |
| M2 war fixture (`tools/probes/war_autotest.lua`, seed 501, speed 4) | 27/27 | with the probe change of deviation 12 (`build/p5m3w2-m2war5-server.log`) |
| Save/load (`tools/saveload-check.sh`, 4 nations, the load probe below, save at minute 1) | PASS | saved with 4 belts mid-build, the fronts job running, 8 holding divisions and 4 bombarding trains; after the load the belts finished (24-26.5 s), refreshes 3-7 ran, the holders were kept, 0 errors in both halves |

The scripted autotest: `tools/probes/war2_autotest.lua` (22 checks; 22/22 on the final copy). Engine probe:
`tools/probes/war2_engine.lua`. Load probe: `tools/probes/war2_perf.lua`. GUI probe: `tools/probes/war2_gui.lua`
(`build/p5m3-war2/gui-copy.sh` makes the test copy).

```sh
# autotest (about 2 minutes)
KEEP_TREE=build/p5m3-war2/factorio-rts EXTRA_LUA=tools/probes/war2_autotest.lua SEED=501 STOP_ON='war2 autotest summary' \
  tools/autotest-run.sh p5m3w2-at '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 900
# 4-nation load (8 minutes, per-module ms in the minute perf lines, "front: step" lines for every refresh job tick)
PERF=1 DURATION_MIN=8 KEEP_TREE=build/p5m3-war2/factorio-rts EXTRA_LUA=tools/probes/war2_perf.lua SEED=802 \
  tools/autotest-run.sh p5m3w2-perf '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1200
# save/load
SAVE_MINUTE=1 KEEP_TREE=build/p5m3-war2/factorio-rts EXTRA_LUA=tools/probes/war2_perf.lua SEED=802 \
  tools/saveload-check.sh p5m3w2-sl '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 150
# GUI (only while `ps -axo command | grep "[M]acOS/factorio" | grep -c window-size` prints 0; RTS_LOCALE=en or ru)
build/p5m3-war2/gui-copy.sh build/p5m3w2-gui && RTS_LOCALE=en tools/gui-run.sh build/p5m3w2-gui 420 RTS_WAR2_GUI_PROBE_DONE
```

## 2. Performance (PERF=1, speed 1, ms per tick averaged over each minute)

| Run | fronts | belts | trainswar |
|---|---|---|---|
| 1v1 autotest, minute 1 (1 war, 4 segments, a 219-piece belt built, 1 artillery train) | 0.002 | 0.007 | 0.0003 |
| 4 nations, 6 wars, 34 segments, 8 holding divisions, 4 belts, 4 bombarding trains (minutes 1-9, two runs) | 0.005-0.023 (mean 0.007) | 0.002-0.021 (mean 0.005) | 0.003-0.014 (mean 0.007) |
| M1 acceptance, 60 minutes (one war without a front) | < 0.001 | 0.002-0.004 | < 0.001 |

The refresh job (every 30 s), 4 nations, 6 wars, 48 rows and 1,500 cells per tick: 49-55 ticks per refresh; scan ticks
mean 0.12-0.15 ms, build ticks (one side's segments with strength and value) mean 0.13-0.22 ms; the worst ticks were
1.2 ms (scan) and 0.96 ms (build) on a quiet machine, 5.2 and 1.9 ms with the machine at load 8-12 (other agents'
servers; the profiler reads wall time): 8 of 783 steps above 1 ms. Before the row pruning (a side's row is read only
when the other side owns a cell in it or next to it) a scan tick reached 2.26 ms. The final budgets are 24 rows and 600
cells per tick (`balance.nation.fronts.rows_per_tick`, `cell_budget`): the 1v1 refresh takes 15 ticks instead of 9.
Laying a belt places 40 ghosts per tick (a 219-piece belt in 6 ticks); its crew revives 4 pieces per second. An artillery train looks for targets once per 10 s shot
(`find_entities_filtered` with the registered building names in a 120-tile circle). All three modules together stay
under 0.04 ms per tick in the 4-nation probe.

## 3. Design

### 3.1 Fronts (`scripts/fronts.lua`)

- **Segments.** For every war going on (`wars.all`, status not ended), each side's border cells that touch the other
  side's land (4-neighbours on the territory grid, 8-tile cells) are joined into 8-connected pieces (at least 4 cells);
  a piece is walked from one end (nearest unwalked cell, looked up through a cell index within 2 cells, a scan of the
  piece only at gaps) and cut into k parts: k keeps the lengths inside 128-192 tiles when possible, else as close to
  that range as possible, then as close to 160 as possible (`fronts.pieces`). A segment carries `id, war, enemy, a, b,
  mid, chord (|b - a|), length (walk), cells, back` (unit vector into own land: away from the enemy cells it touches),
  `strength, value, threat, name` (region), `holder`.
- **Threat** = value x (1 + strength / 16). Strength: supply of the enemy's registered units within 160 tiles of the
  middle (`fronts.STRENGTH`, replaceable by m3-ai's intel). Value: own cities within 400 tiles (tier x 10 + residents /
  10, +20 for the capital, falling off linearly) and own hubs, depots and centres within 200 tiles (8 each, through
  `warsupply.depots`).
- **Refresh job.** Every 1,800 ticks, on `rts_war_declared` / `rts_war_ended`, and `fronts.refresh(force)`: a job in
  `storage.fronts.job` scans 24 territory rows (at most about 600 visited cells) per tick per war, then builds one
  side per tick; the commit gives a new segment the id and holder of the nearest old segment of the same war within 96
  tiles. `fronts.flush()` finishes it at once (tests). The first refresh of a match comes a minute after its start.
- **Map.** Each force sees its own segments: a line along the chord coloured by threat (green, yellow, red relative to
  its most threatened segment) and "Front N · threat T" (· "held by <division>") in the chart view, and the same as a
  thin dashed line with a small label in the game view (where H holds the line).
- **hold_line** (`divisions.order(id, "hold_line", segment_id, opts)` through `divisions.ORDER_HOOKS`): slots along the
  chord (members matched by their projection on it), 4 tiles behind it on own land (pushed further back where the
  border bulges); the members walk there with `divisions.lua`'s settling state (each stops at its slot); stance hold.
  A division farther than 96 tiles from the chord marches to it as a group first. When the settling ends the members
  stay claimed "hold" (state "holding": re-stopped whenever a command ends, like the hold order), because an idle unit
  is taken by the M2 AI army pool (the autotest's division lost members to the AI's rally moves before). Every 600 ticks
  members that drifted more than 10 tiles from their slot with no enemy within 30 tiles walk back, and a division whose
  member count or segment changed is spread again. `opts.part = {i, k}` holds the i-th of k parts of the chord. Any
  other order ends the line.
- **Keys and panel.** H with whole divisions selected and the cursor within 64 tiles of an own segment's chord holds it
  (several divisions share the chord in the order of their centroids along it); otherwise H is the plain hold. The
  division card of a selected division shows "Front N · threat T · D tiles" (the nearest segment) and a Hold line
  button while its force has a front; the card's state reads "Holding the line (front N)".

### 3.2 Fort belts (`scripts/belts.lua`)

- **`belts.layout` / `belts.plan(force, points, opts)`**: 2-6 points, every one on own land, at most 640 tiles, a city
  to pay, Fortification researched. The points snap to tile centres; the wall line is rasterised 4-connected (no
  diagonal gaps). On every own-land tile: a wall, or a gate where a straight orthogonal rail runs (a horizontal track
  takes a gate with direction north, a vertical one east: engine probe); curved and diagonal track, ramps and rail
  supports leave a gap; water and buildings are skipped (can_place manual_ghost + forced, so trees and rocks pass and
  are cleared before the revive). Behind the line ("behind" = the back side of the force's front segment nearest the
  belt within 600 tiles, else towards the nearest City Center): a turret every 12 tiles, 3 tiles back; from Age II an
  AA turret every 36 tiles, 7 tiles back, when `rts-aa-turret` exists and the force's recipe for it is enabled (m3-air's
  prototype, looked up by name, and only while `research.is_unlocked(force, "rts-aa-turret")`, i.e. Aviation;
  `balance.nation.belts.aa_turret`); a field depot 12 tiles behind the middle.
- **Building.** Ghosts are laid 40 per tick. The belt crew revives 4 per second in plan order (depot, turrets, AA,
  gates, walls), each one paid with its item from the network of the nearest own city (then the next nearest); an
  entry whose item is missing waits (alert "Fort belt N waits for X", once per item) and the crew takes the next entry
  it can pay. Robots of a covering network and the Commander's field construction build the same ghosts with their own
  items; the crew counts those as built (a removed ghost as skipped). A new turret gets 10 magazines from the same
  network and the priority list artillery walker, heavy walker, heavy mk2, armoured car
  (`LuaEntity.set_priority_target`, unprioritised targets still shot); the belt's field depot keeps 100 magazines
  (logistics policy) and tops its turrets up every 10 s. `belts.cancel(id)` removes the ghosts not built yet.
- **Tool.** F with no unit selected (Nation mode), or the gate button at the right of the build menu's header, opens
  the tool panel (centred under the HUD strip and its alerts): points, length, the bill, AA and Field depot
  checkboxes, Undo point, Build, Cancel, and up to 3 belts under way with their progress, what they wait for and Stop.
  Right clicks inside own land add points (the right-click hook runs before the others); the line, the points and the
  planned turrets, AA, gates and depot are drawn for the player in the game and map views.

### 3.3 Artillery and armoured trains (`scripts/trainswar.lua`, `rails.lua` hunks)

- **Prototypes** (`prototypes/war3.lua`): `rts-artillery-wagon` (vanilla artillery wagon, `disable_automatic_firing`,
  gun `rts-rail-cannon` of the hidden ammo category `rts-rail-shell`, range 120, 1,500 HP), `rts-rail-shell` (its ammo),
  `rts-rail-shell-projectile` (a grenade-style projectile like the Artillery strike's: 420 explosion damage in 3.5
  tiles, force "enemy" only, collision mask player / is_object / trigger_target so ground rails, signals and belts
  under the target take nothing), `rts-armoured-locomotive` (3,000 HP), `rts-armoured-wagon` (an armoured troop wagon,
  2,400 HP), both with physical and explosion resistance raised to 40 % on top of the stock's flat decrease of 15
  (100 physical: plain 59.5 taken, armoured 51), `rts-gate`, the kits and their factory recipes, the technologies
  Fortification (Age I, 15 basic kits: gate, fort belt tool) and Military railways (Age II, 25 industrial kits, after
  Railways and Industrialisation: artillery wagon kit, rail shells, armoured locomotive and wagon kits).
- **Artillery train** = 2 locomotives (armoured ones with the Armoured box) + 1 artillery wagon, deployed by the depot
  panel's "Deploy artillery train" or `trainswar.deploy(depot, "artillery", armoured)`; it takes 20 shells from the
  depot. With the train selected, a right click on an own depot sends it there and a right click on a rail stops it on
  that rail (`rails.KIND_HOOKS.artillery`). Stance Bombard (B, or the train panel's stance row): one shell every 10 s
  (`trainswar.fire`, the first at once) at the best hostile building within 120 tiles: turrets, forts and bunkers
  first, then barracks, then hubs and centres, then factories and the rest, the nearest first; walls and rolling stock
  are no targets. Only forces `diplomacy.hostile` names; the force must see the target: an own entity of any kind within
  48 tiles of it or an own radar within 96 (`trainswar.KNOWN`, replaceable; the same rule for players and AIs and no
  chart state, which differs between a headless server and a GUI peer: m3-perf's determinism rule). Standing at an own depot (at its stop or on its platform) the train refuels and
  tops its shells up to 20; "Out of shells" alerts once a minute. Disbanding returns its shells to the depot.
- **Armoured stock**: `rails.create_train(depot, kind, {armoured = true})` uses armoured locomotive kits (and armoured
  troop wagon kits for a troop train); the depot panel's Armoured checkbox (per player) applies it to every Deploy
  button. The armoured troop wagon carries troops like the troop wagon (`garrison.TWAGONS`).
- **Train panel**: title "Artillery train N (armoured)", the position line (depot, rail or none), stance buttons Hold
  fire / Bombard [B], the gun line (shells, next shot, last target and its distance, or why it does not fire), the
  artillery hint. **Depot panel**: artillery and armoured kits and shells in the network, Deploy artillery train,
  Armoured.

### 3.4 Division strikes and the hidden helpers (`divisions.lua`, lead's item from m3-air's probe)

- **The cause** (`build/p5m3-war2/divdiag_indestr.lua`, HP of every entity near the depot each second): the immune hidden
  entities under hubs, depots, City Centers and the CC (`rts-hub-power`, `rts-hub-pole`, `rts-core-power`,
  `rts-core-pole`, `rts-city-power`, `rts-city-demand`; 100 % resistances) are valid targets: after a few hits on the
  depot the group shot them for ever. In Nation mode they are now made indestructible (units never pick an
  indestructible target): `buildings.on_added` queues every cc and hub, the next 15-tick pass sets `destructible =
  false` on those parts within 3 tiles (their composites are built by later modules' callbacks). With that alone the
  depot died after 33 s, but the group still spent 15 s on the depot's stockpiles and platform rails.
- **The watchdog**: a Nation attack whose group strikes a building (`D.order.strike`, the building the careful
  attack-move or attack aims at) and stands within 40 tiles of it without lowering its health for 5 s turns into
  member strikes: the group is dropped, every ground member gets an `attack_area` over the building's footprint
  (re-issued when it ends, as orders.lua does for attacks), state "striking" until the building is gone or 60 s have
  passed, then the attack ends as an arrival (re-target or settle). Planes keep their own flight (m3-air's
  `split_air`). Skirmish never records a strike target, so nothing changes there.

### 3.5 Territory job merge (`territory.lua`, found with the GUI probe)

A territory job that had not started yet took a later source's box by growing its rows upwards but kept its first row:
the new rows above were never computed. Two cities founded in the same tick, the second north of the first (the GUI
probe's rig in the south-east corner), left the second without land, so the war had no front. The merged job now starts
at its new top row (`j.row = j.y0`).

## 4. Deviations (with reasons)

1. **F, B and H already had meanings** (attack-move, build menu, hold; `prototypes/inputs.lua`). The new meanings are
   contextual and Nation-only: F with no unit selected (attack-move needs units) toggles the belt tool; B with an own
   train selected sets Bombard (the build menu is not needed then); H with whole divisions selected and the cursor at
   an own front holds the line. `orders.lua` asks `orders.f_claim` / `orders.h_claim` before arming attack-move or
   holding, `hud.lua`'s build-menu handler asks `trainswar.claims_b`; the actions run from `P4.KEYS` entries on the same
   inputs (the handler now passes the event, for the cursor position). Skirmish keeps every key as it was.
2. **The belt is built by a belt crew** (scripted revives paid from the nearest city network) besides robots and the
   Commander: a border belt usually lies outside every construction area (CC 40, hub 22 tiles), and the contract wants
   a 200-tile belt built in 3 minutes with a real debit.
3. **Fortification gates the tool as well as the gate** (the contract lists the technology without its effect).
   An AI that wants belts must research it (`rts-fortification`, Age I).
4. **The armoured wagon is an armoured troop wagon** ("an armoured troop train is the M2 troop train with armoured
   stock"); a cargo train gets armoured locomotives only. `scripts/garrison.lua` (an M2 file, not in the M3 table)
   needed a 3-line hunk to take troops in it (`garrison.TWAGONS`).
5. **Artillery fires at what the force sees** (an own entity within 48 tiles of the target, or an own radar within 96)
   instead of everything in 120 tiles: siege needs spotters. (The first version read the chart for charted forces;
   m3-perf found chart state to differ between a headless server and a GUI peer, so no decision may read it.)
6. **The shell hurts no rails** (collision mask), which keeps bombardment from feeding the rail protection of
   `targeting.lua` (M2 integration open issue 3: a protected rail turns indestructible for 10 s).
7. **hold_line members stay claimed** "hold" after arriving (state "holding"): see 3.1. A player's order to some (not
   all) members of a holding division reaches none of them, as for the existing hold order.
8. **Front lines are drawn along the chord**, not along the ragged cell border (one line per segment; the territory
   border is drawn already).
9. **`fronts.refresh(force)` refreshes every war** (one job covers all; the argument is accepted for the contract).
10. **Division strikes and indestructible hidden helpers** (3.4): `divisions.lua` hunks, as the lead asked. AI attacks on
    buildings now finish what they start, which makes AI wars more destructive (open issue 2).
11. **Territory merge fix** (3.5): a one-line hunk in `territory.lua` (an M1 bug, not this package's feature).
12. **M2 war fixture probe** (`tools/probes/war_autotest.lua`, m2-war's test): "a destroyed loaded wagon removes its
    units" destroyed one wagon and expected the whole division gone; after the changes above the six walkers boarded two
    wagons of the train (butterfly effect: no rule changed for boarding), so the probe now destroys every loaded wagon
    (the original is `build/p5m3-war2/war_autotest.lua.orig`).

## 5. Files

| File | Status | What it does |
|---|---|---|
| `scripts/fronts.lua` | new | Segments per war, threat, refresh job, map lines, `hold_line`, H |
| `scripts/belts.lua` | new | Layout, plans, ghosts, belt crew, turret priorities and feed, the tool panel, F, Fortification effects |
| `scripts/trainswar.lua` | new | Stances, targets, fire, rearm, deploy, artillery right clicks, panels, B, Military railways effects |
| `prototypes/war3.lua` | new | Gate, artillery wagon and gun, shells and projectile, armoured stock, kits, recipes, two technologies |
| `locale/en/war3.cfg`, `locale/ru/war3.cfg` | new | 107 lines each, the same keys |
| `tools/probes/war2_autotest.lua`, `war2_engine.lua`, `war2_perf.lua`, `war2_gui.lua` | new (tests) | see section 1 |
| `build/p5m3-war2/sync.sh` | tool | Three-way merge of the shared hunks, copy of the own files |

### Shared hunks (marked `-- Phase 5 M3 war2`; line numbers in `mods/factorio-rts` after the sync, 26ad517 + war2)

| File | Lines | Hunk |
|---|---|---|
| `control.lua` | 88-93 | require fronts, belts, trainswar after age3's sinks (before debug) |
| `data.lua` | 22-24 | require `prototypes.war3` after `prototypes.war` |
| `balance.lua` | 1199-1257 | `balance.nation.fronts`, `.belts`, `.trains_war`, `balance.buildings["rts-gate"]` |
| `scripts/rails.lua` | 92-102, 146-147, 190, 194-197, 1309-1317, 1347-1362, 1369, 1378-1384, 1492-1495, 1502, 1507, 1519-1524, 1531, 1538, 1594-1598, 2493-2495, 3300 | names, `KIND_HOOKS`, `KITS`, stock and kit sets; `kit_list(kind, n, armoured)`, `kits_for(kind, net, armoured)`, `train_kind`, `armoured_of`; `train_slots(..., armoured)` with the artillery wagon; `deploy_check(depot, kind, opts)` and `create_train(depot, kind, opts)` with "artillery" and armoured stock; the record's `armoured`; right clicks of other modules' kinds; armoured locomotive losses |
| `scripts/railgui.lua` | 31-35, 115-120, 127-128, 135-136, 171-172, 186, 214-215, 252-255, 272-273, 342-344 | trainswar lookup; title (artillery, armoured); stance rows; artillery hint; state keys; panel update; depot rows; `deploy_check` and Deploy with the Armoured option |
| `scripts/garrison.lua` | 53-54, 441, 763 | `garrison.TWAGONS` (the armoured troop wagon carries troops) |
| `scripts/orders.lua` | 922-934 | F and H claims before attack-move and hold |
| `scripts/hud.lua` | 136-138, 165-168, 188-190, 304-305, 392-395, 1024-1031, 1858, 2354-2356, 2423-2425, 2440-2444, 2451 | help line; Nation-only items; logistics tab kits; gate in the defence tab (after air's AA turret); 3 alert styles; fort belt button in the build menu header and its visibility by mode; its click; B claim; P4.KEYS F/B/H (after air's Y); the event passed to P4.KEYS functions |
| `scripts/divisiongui.lua` | 55-61, 133-134, 187-188, 263-274, 353-359, 472-478 | fronts lookup; signature with fronts; "Holding the line" caption; front row with Hold line; its update; its click |
| `scripts/divisions.lua` | 56-59, 99-102, 620-621, 657, 680, 888-932, 953-957, 973-980, 995-1034, 1096-1104 | header; strike constants; `D.strike` reset and the strike target of a careful attack; `strike_cmd`, `strike_stalled`, `begin_strike`; the watchdog in `check` (ground members only: air's `split_air`); state "striking"; hidden helpers made indestructible; re-strike on command completion (not planes) |
| `scripts/territory.lua` | 301-304 | a merged job starts at its new top row |
| `tools/probes/war_autotest.lua` (m2-war's test) | 613-624 | destroy every loaded troop wagon (deviation 12) |

`strategic.lua` needed no hunk (the map lines are this module's render objects); `hold_line` goes through
`divisions.ORDER_HOOKS` and `divisions.on_changed`, the border scan reads `territory.ensure_grid()`'s rows. m3-perf's
`rails.lua` hunk (the survey on `sched.lua`) touches other functions and merges at its sync.

## 6. Engine facts (probe `tools/probes/war2_engine.lua`)

| Question | Answer |
|---|---|
| Gate on a straight rail | horizontal track (direction east/west): gate direction north only; vertical track: east only (all 4 tiles of the rail); can_place manual_ghost + forced, a ghost there revives, a direct create works |
| Trigger collision mask | ground rails collide with `object` (`floor, item, object, rail, water_tile, is_lower_object`): a blast masked to `object` hit the rails beside the turret (2 events); masked to `player, is_object, trigger_target` it hit the turret only (0 rail events) |
| Rolling stock resistances | vanilla locomotive / wagon: physical and explosion decrease 15, 30 % (100 physical takes 59.5); a percent-only 40 % armour took 60, more than plain stock against small hits, so the decrease stays |
| `set_priority_target` on `rts-turret` | accepted for unit prototypes, read back by `get_priority_target(i)` (1-based); `ignore_unprioritised_targets` false by default |
| Artillery wagon | ammo inventory of 1 slot takes 30+ `rts-rail-shell`; locomotive + artillery wagon + locomotive at 7-tile spacing form one train |

## 7. Storage

```
storage.fronts = {next_id, job = {wars, w, row, phase, side, cells, out, started, cell, x0, y0}, pending, next_refresh,
  lines = {[division id] = {segment, part, phase = "march" | "hold", target, slots = {[un] = {x, y}}, a, b, n, tick,
  held}}, objs = {[force] = {LuaRenderObject}}, stats = {refreshes, segments, holds}}
storage.nations[force].fronts = {[war id] = {enemy, tick, segments = {{id, war, enemy, a, b, mid, chord, length, cells,
  back, strength, value, threat, name, holder}}}}
storage.belts = {next_id, laying, plans = {[id] = {id, force, points, opts, mid, length, entries = {{kind, name, item, x,
  y, dir, status, ghost, entity, fails}}, placed, built, skipped, cursor, lay_i, credit, nets, need, debited, state,
  created, done, waiting, alerted, depot}}, tools = {[player index] = {points, aa, depot, objs, layout, reason, el}},
  stats}
storage.trainswar = {prefs = {[player index] = {armoured}}, stats = {[force] = {shots, rearmed, deployed}},
  alerted = {[train id] = tick}}
storage.rails.trains[id] += {armoured, stance, next_shot, shots, last_target, war_reason, position_rail}
storage.divisions[id].order = {kind = "hold_line", target, tick, segment}; D.state "holding"
```

Each module clears its tables in `match.on_teardown` (and destroys its render objects and tool panels). Log prefixes:
`front:`, `belt:`, `train:` (and `order hold_line`, `order train-artillery-*`).

## 8. Open issues

1. **GUI run overlap.** The Russian GUI pass on the dc3218e copy started while another agent's window was open (the
   check printed 2; screenshots are rendered per player, so mine were unaffected, the other run may have lost focus for
   about 70 s). Later passes waited for a free screen.
2. **AI wars are more destructive.** With member strikes AI attack groups finish the buildings they go for instead of
   standing in "attacking_target" (10 strikes in the 60-minute M1 run). On both copies rts-player's depot at the capital
   was destroyed in minute 36 by rts-ai-1's attack group, its line was lost and it moved 7,531 items by train instead of 14,010; the
   M1 total was 20,163 of the 20,000 needed (53/53). m3-ai's council (operations, relief) is where this belongs now.
3. **For m3-ai (wave B):** the M2 army pools every own unit that is not in one of its groups (a holding division too;
   idle members are walked to the rally point), so a council that orders `hold_line` must keep that division out of
   the pool; belts need Fortification researched; `fronts.threat`, `fronts.of`, `fronts.STRENGTH` and
   `trainswar.KNOWN` are the hooks for intel; no AI deploys artillery or armoured trains yet.
4. **Rails and belts.** The rail planner counts walls and gates as blockers (`rails.lua` BLOCKER_TYPES), so a new line
   does not cross an existing belt; a belt laid over existing track gets gates on straight track and gaps elsewhere.
5. **Belts are not rebuilt.** A destroyed belt piece leaves whatever ghost the force's settings make; the plan stays
   "built".
6. **Fronts follow the land.** Cities that shrink a tier (population) can end a front (the 4-nation probe's tier-3 test
   cities with 40 residents dropped after two minutes and their borders vanished); a holding division then keeps
   standing with its order.
7. **Threat is omniscient by default** (unit registry within 160 tiles); it is a replaceable function for m3-ai's
   intel, like `trainswar.KNOWN`.
8. **AA turrets** are placed in layouts (6 on 200 tiles in Age II with Aviation, autotest); a belt with them was not
   built in a test (the crew builds them like turrets; air.lua feeds them).
9. **No scheduler yet** (lead: wave B may convert it). The fronts refresh is its own resumable job (state in
   `storage.fronts.job`, no closures, one chunk per tick). The hook: register a `sched` kind `fronts_refresh` in
   `fronts.lua` whose step calls the module-local `job_step(job)` (it returns true when done; one chunk is at most 24
   rows / 600 cells, or one side's segments: count it as about 300 units), submit it where `fronts.refresh` and the
   on_tick driver now create `storage.fronts.job` (`new_job(T)`), and drop the on_tick driver for Nation matches. Belts lay and build in bounded slices (40 ghosts, 4 revives per second).
10. **AI council helper.** `belts.plan_front(force, segment_id, opts)` lays a belt 16 tiles behind a segment's chord
   (autotest: 149 pieces on a 136-tile segment).
