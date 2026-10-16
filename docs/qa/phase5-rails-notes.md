# Phase 5 M1 rails (R1): depots, line planner, construction and freight trains

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age and `elevated-rails` on unless noted. Package R1 of
`docs/PHASE5-M1.md` (agent m1-rails). Study: `docs/research/scale/rails-trade.md`; its probe (`build/scale-probe-rails/`)
supplied the geometry learning, the A* and the schedule code that this package grew from.

Everything here is Nation-mode only. In Skirmish the module is inert: Railways and Bridges are hidden from the
research panel, the depot, rail and kit recipes from the build menu and the factory, and no hauler rule changes.

## 1. Results

| Check (`[rts] rails autotest check ...`) | Result | Evidence (run `p5m-1`, live tree + this package, game speed 4) |
|---|---|---|
| `rails_depot_composite` | PASS | Depot = hub + 2 stockpiles + 40-tile platform (20 straight rails) + 2 stops; kind `hub`; default keep `{coal = 50}` |
| `rails_survey`: 800 tiles, lake between, survey ≤ 10 s | PASS | 1.0 s game time (25 ticks of work), 266 pieces, 887 tiles of track for 800 straight |
| `rails_route_avoids` | PASS | 0 pieces in the lake (120 × 300 tiles), 0 in a block of foreign buildings on the straight line |
| `rails_line_built` within ±5 % of billed rails | PASS | Bill 493 rails; net from the depots 496 (loaded 493, returned 0, robots 3): 0.6 %; open after 250 s |
| `rails_deliver`: ≥ 4,000 iron in 3 minutes | PASS | 6,000 iron loaded, 887 tiles in 27.6 s, 4,092 counted 53 s after departure, 6,000 at 60 s |
| `rails_cut`: 3 rails destroyed → no_path + "Line cut" | PASS | Train `no_path` 1.0 s after the cut; line state `cut`; alert `rts.alert-line-cut` |
| `rails_repair` within 60 s | PASS | Crew from the far depot, line open again 14.0 s after the cut |
| `rails_resume` within 60 s | PASS | Next delivery 24.0 s after the repair |
| `rails_bridge` (elevated spans, Space Age) | PASS | 70-tile water band, 2 ramps, 33-49 elevated pieces, 11-14 supports standing, built in 75 s |
| `rails_ai` (AI rail program) | PASS | rts-ai-2: two depots, 387-tile line, freight train, first delivery 168 s after the start |
| `rails_hauler_rules` (Nation hauler fuel and slots) | PASS | 1,000 iron per trip (10 slots), 14 coal for 2 × 220-tile legs (7 per leg) |

Summary line: `[rts] rails autotest summary 11/11 (all passed)`, 0 Lua errors. Further results: section 9.

## 2. Day-1 probes

Probe mod `build/p5-rails-probe/rts-rail-probe2/` (P1 on a generated Nauvis surface, P2-P4 on lab tiles) and the
autotest's census of its own generated map (seed 4242: 19,829 trees, 511 rocks, 351 cliffs, 4,682 ore entities and
30,325 water tiles in the 1056 × 512-tile main box).

| Question | Verdict | Evidence |
|---|---|---|
| P1: which build check lets the planner treat trees and rocks as clearable, but not water or buildings? | `build_check_type = manual_ghost` with `forced = true` | Ground rail over a tree or a rock: `manual` false, `manual_ghost` false, `manual_ghost + forced` **true**. Over water: false (but `script` and `script_ghost` true, the trap from the study). Own or foreign building: false. Ore: true for all checks. A ghost over a tree or rock does not revive; after the builder clears them it does. |
| P1b: cliffs | Blocked by every check | `manual_ghost + forced` is false on cliffs too. The planner allows a ground piece whose 6×6 box holds only cliffs, trees and rocks (no water, buildings or rails) at +15 cost, and the crew blows the cliff up (7 cliffs on the 887-tile main line). |
| P1c: cost of the coarse-grid queries | about 2 µs each | Per 16 × 16 cell: `count_tiles_filtered` (water_tile) 2.1 µs, cliffs 1.4 µs, trees and rocks 2.1 µs; `can_place_entity` 1.3-1.8 µs |
| P2: support-spot rule for elevated spans | **A `rail-support` must stand exactly on an elevated rail end, oriented along the rail (either way); build in order with one every ≤ 12 tiles** | Brute force over 29 × 7 positions × 16 directions for one elevated piece: only its two end positions, directions east or west, made it placeable. Spans built in order from a ramp: supports every 6, 10 and 12 tiles carried all 28 pieces; every 16, 20 and 22 tiles failed at the piece 11-12 tiles from the last support. A ramp's elevated end carries the first ~10 tiles. The planner puts one every 10 tiles; the builder tries both ends of a piece that still will not revive. |
| P3: signals from `RailLocation` | **Works; a bidirectional pair = `in_signal_location` + `out_signal_location` of one rail end** | `create_entity{name = "rail-signal", position = loc.position, direction = loc.direction}` at both; a double-headed train ran 5 legs both ways on single track. `alternative_*` locations are nil on straight track. |
| P4: trains vs our units | **Trains kill spider-units and units, haulers pass through** | At ~0.3 tiles/tick: rts-walker killed (462 impact damage), rts-drone killed (527), rts-walker-heavy pushed and killed after 475 + 2/tick; trains take no damage and slow down while pushing a heavy. rts-hauler (spider-vehicle) is not hit. Our units' collision masks: walker/heavy/hauler `trigger_target` only, drone `is_object player train`. |
| P5: planner cost on real terrain, time-sliced | **≤ 5 ms per tick** | Coarse pre-pass + corridor + flow-field heuristic: 460 fine expansions and 1,318 placement checks for the 800-tile lake route (the study's unguided A* needed 27,536 expansions for 400 tiles). Per survey tick (run `p5r-perf`, game speed 1, a busy machine): scoring 1.6 ms, coarse 2.7 ms, corridor 1.9 ms, fine 4.9 ms at 220 expansions per tick, so the shipped budget is 150 (about 3.4 ms on that machine, 2.5 ms in `p5m-1`). |

## 3. Files

| File | Status | What it does |
|---|---|---|
| `scripts/rails.lua` | new | Geometry, depots and platforms, survey (planner), lines, construction and freight trains, right-click hook, AI program, autotest |
| `scripts/railgui.lua` | new | Train panel, depot rail panel with the line list |
| `prototypes/rails.lua` | new | `rts-depot`, `rts-depot-stop`, rolling stock, kits, recipes, Railways and Bridges technologies |
| `locale/en/rails.cfg`, `locale/ru/rails.cfg` | new | Same 119 keys in both |
| `tools/probes/rails_autotest*.lua`, `rails_saveload_*.lua`, `rails_gui.lua` | new (test only) | Switches for the autotest stages, save/load timing, the GUI probe |
| Shared hunks | small, marked `Phase 5 M1 (m1-rails)` | Listed in section 10 with file:line |

## 4. Prototypes

| Prototype | Base | Numbers |
|---|---|---|
| `rts-depot` (roboport) | vanilla roboport, tinted blue | 1,500 HP, logistic radius 14, construction radius 22, own 20 MJ buffer, raid target, military target. Kind `hub` in buildings.lua: logistics.lua builds the hub composite (hidden 300 kW power, pole, 2 stockpiles, 10 + 6 robots) |
| `rts-depot-stop` | train-stop | not minable, not blueprintable, team colour |
| `rts-locomotive` | locomotive | 1,000 HP, not minable, team colour (`LuaEntity.color`), raid target, `chunk_exploration_radius` 1 |
| `rts-cargo-wagon` | cargo-wagon | 600 HP, 40 slots |
| `rts-construction-wagon` | cargo-wagon | 600 HP, 20 slots, orange |
| item `rts-depot` | roboport item | subgroup `rts-economy`, build menu Economy tab (Nation only) |
| items `rts-locomotive-kit`, `rts-cargo-wagon-kit`, `rts-construction-wagon-kit` | | subgroup `rts-units`, stack 10 |
| recipe `rts-depot` (factory) | | 40 iron + 10 steel + 10 copper, 10 s |
| recipe `rts-rail` (factory) | | 2 steel + 1 stone → 2 vanilla `rail`, 2 s (vanilla item, so depot robots can revive rail ghosts too) |
| recipe `rts-locomotive-kit` | | 40 iron + 10 steel + 10 circuits, 10 s |
| recipe `rts-cargo-wagon-kit` | | 20 iron + 5 steel, 6 s |
| recipe `rts-construction-wagon-kit` | | 30 iron + 10 steel, 8 s |
| technology `rts-railways` | tier 1, 15 basic kits | unlocks the five recipes (they start disabled) |
| technology `rts-bridges` | tier 2, 20 advanced kits, needs Railways; only when `elevated-rails` is loaded | flag `bridges`: the planner may use ramps and elevated pieces |

All numbers live in `balance.nation.rails` (balance.lua).

## 5. How it works

### 5.1 Geometry (contract: learned at init, not in storage)

`on_init` builds a hidden lab-tile surface `rts-rails-geometry` and places one scratch rail per extension of every rail
end state (`LuaRailEnd.get_rail_extensions("rail")`): 105 rails, 32 end states (16 directions × ground and elevated),
in about 2 ms. The extension table is module-local. After every load it is re-read from those scratch rails on first
use; that is a read-only operation, so every peer gets the same table and nothing is written in `on_load`. Without
`elevated-rails` the same code learns the 16 ground states and the planner never offers bridges.

### 5.2 Depot

A depot is a hub subtype: `buildings.KIND_BY_NAME["rts-depot"] = "hub"`, named "Depot n" through m1-cities'
`logistics.NAME_HOOKS`, so keep / export policies, the hub panel, haulers and the supply cap (+10) work unchanged. Its
default policy keeps 50 coal instead of the hub's plates. On registration rails.lua lays the platform:

- 20 straight rails (40 tiles) 7 tiles off the depot centre: south, north, east or west, whichever fits first. Trees,
  rocks and cliffs in the strip are cleared; water or buildings rule a side out.
- Two `rts-depot-stop` with the same name (`"<force> depot <unit number>"`), one at each end facing inward. A train
  that enters through the east end runs west and stops at the west stop, and vice versa, so a dead-end platform works
  whichever end the line joins.
- A platform that does not fit raises the alert "no room for a platform"; the depot still works as a hub.

### 5.3 Survey (`rails.plan_line`)

One job per line, run on `on_tick` with per-tick budgets (`SURVEY_CELLS` 120, `SURVEY_COARSE` 400,
`SURVEY_EXPANSIONS` 150, `SURVEY_GHOSTS` 50), one job at a time:

1. **score**: 16 × 16 cells in the box around both depots (margin max(96, distance/4)). Per cell: water (and void),
   cliffs, trees and rocks, buildings (`BLOCKER_TYPES`), foreign land (territory.lua when loaded). Blocked: half void,
   24+ buildings, or > 75 % water without Bridges. Cost = 16 × (multiplier + 3 × water share); with Bridges, water
   cells cost 16 × (multiplier + 3).
2. **coarse**: A* over cells. No route: the box margin doubles (up to 1,024 tiles).
3. **corridor**: cells within R = 1 of the coarse path (plus 2 around both depots) and a flow field: cost-to-go per
   cell by Dijkstra from the goal cells.
4. **fine**: weighted A* (× 1.3) over rail end states (position, 16-way direction, layer) with the learned
   extensions, only inside the corridor. Heuristic: distance to the centre of the best neighbouring cell plus that
   cell's cost-to-go. Piece cost = length × (1.5 elevated) + 20 per ramp + 1 per curve, times the cell's multiplier.
   Checks: ground pieces and ramps `manual_ghost + forced`, elevated pieces `script`; cliff-only spots +15 (P1b);
   cached per job. No route: R → 2 → 3, then "failed" (alert "No route for the rail line").
5. **extract**: supports on elevated rail ends every 10 tiles (P2), signal pairs at both station entries and every
   80 tiles of ground track (P3), the bill.
6. **ghosts**: `entity-ghost` of every piece and support. The planned line is visible to the owner.

Bill, in `rail` items: vanilla rail count per piece (straight 1, half-diagonal 2, curves 3), 20 per ramp, 10 per
support, 2 per signal. A construction wagon therefore only carries rails (and its coal).

### 5.4 Construction train

- **Dispatch**, every 60 ticks for a line with missing pieces and no crew: 2 locomotive kits + 1 construction wagon
  kit and rails from a depot network. The crew spawns on that depot's platform, loads the rails the work needs (up to
  20 stacks) and 50 coal, and gets 10 coal per locomotive.
- **Which depot.** The initial build starts at depot A. A repair comes from the side of the cut that the line's
  freight train is not on; when that depot has no kits or rails, the line waits ("waits for a construction train: ...").
- **Work.** Every 30 ticks it lays up to `build_rate` × 0.5 s pieces (10 per second) within `build_reach` (48 tiles)
  of a locomotive, in line order: supports due first, then trees, rocks and cliffs under the piece are destroyed, then
  the ghost is revived. When the next piece is out of reach the train hops to the last built rail (a temporary rail
  record), so it stops and starts once per ~45 tiles, not every step. It tops its locomotives up from the wagon's coal.
- **Done.** A crew that laid the piece next to the far platform parks at that depot; any other crew (a repair, out of
  rails) returns the way it came, so it never meets the freight train head-on. At its depot the train goes back into
  kits; leftover rails and coal return to the network.
- **Blocked.** A piece that will not revive 20 times raises "Rail line blocked" at its position; the crew keeps
  retrying (a unit standing there moves on, a new building has to go).
- Measured: 887 tiles in 250 s (initial build), 3 pieces in 14 s round trip (repair), 334-tile bridge line in 75 s.

### 5.5 Freight train

- `rails.create_train(depot, "cargo")`: 2 locomotive kits + 2 cargo wagon kits → locomotive + 2 wagons + locomotive
  (double-headed: single track, terminus platforms) facing the line's end of the platform; 10 coal per locomotive.
- `rails.set_route(train, pickup, dropoff)` writes two records (the two depot stop names) with a 1-hour `time` wait as
  a safety net and starts the train. The script sends it on with `go_to_station`.
- **Pickup**: cargo = per item min(pickup network count − export threshold, drop-off keep − drop-off count − cargo on
  other trains heading there − cargo aboard); a drop-off without keep thresholds takes every export (hauler rule).
  Loading runs at 200 items per second per wagon (`transfer_rate`) through `logistics.transfer`; the train leaves when
  the plan is loaded or nothing more moves. Nothing to carry: it waits and re-plans every second.
- **Drop-off**: unloads everything at the same rate; a full network leaves the train waiting ("full").
- **Fuel**: at every stop each locomotive is topped up to 20 coal from the depot network.
- Measured on the 887-tile line: 6,000 iron loaded in 3.8 s, travel 27.6 s (32 tiles/s average), unloaded in 15 s.

### 5.6 Line states, cuts and alerts

`surveying` → `building` → `open` (all pieces and supports stand and `request_train_path` finds depot B's stop from
depot A's platform) ↔ `cut` (a line rail died); `failed` when no route exists.

- **Deviation from the contract: script ghosts instead of the force setting.** `LuaForce.create_ghost_on_entity_death`
  would make every destroyed building of a nation leave a ghost that its robots rebuild, which changes Nation combat
  far beyond rails. Instead `on_entity_died` of a rail that belongs to a line (a position index) creates the ghost
  itself and marks the piece missing. Destroyed platform rails get a ghost for the depot's robots.
- Alerts (logistics.alert, HUD styles added): `line-open` "Rail line open" (green), `line-cut` "Rail line cut" (red,
  sound), `line-blocked`, `line-failed`, `train-lost`, `depot-no-platform`.
- Trains of a line that lost its path recalculate when the line opens again.

### 5.7 Nation balance

| Key | Value | Effect (Nation mode only) |
|---|---|---|
| `balance.nation.hauler_slots` | 10 | `logistics.capacity` base (research still adds its bonus) |
| `balance.nation.hauler_tiles_per_coal` | 40 | a hauler leaving a hub takes ceil(1.1 × distance / 40) coal from that hub's network; without it it waits ("no-fuel", shown in the hauler panel) |
| `balance.nation.rails.*` | see section 4 and 5 | recipe costs, bill, build rate and reach, transfer rate, fuel, train length, signal spacing, AI distance |

### 5.8 Research and Skirmish gating

- `research.EFFECTS["rts-railways"]` unlocks the five recipes; `research.EFFECTS["rts-bridges"]` sets flag `bridges`.
- New shared helper in research.lua: `research.NATION_ONLY = {}` and `research.hidden_for_mode(name)`. Nation-only
  technologies are disabled in Skirmish (`init_force`, and again at every new match in `reset_force`), and the
  research panel (techgui.lua) does not list them. Other M1 packages can add their technology names.
- The HUD build menu and factory grid use m1-cities' `P4.NATION_ONLY` filter; rails adds the depot item and its five
  recipes to it.

### 5.9 AI hook

`scripts/ai/commander.lua` calls `deps.rails.ai_step(C)` after `hubs.step(C)` (rails.lua sets `deps.rails`). Nation
mode only, every 600 ticks: a hub or city (cities.lua capital when loaded, else the main CC) at least 300 tiles from
the capital gets a depot next to each end (a site where the depot and a platform fit, 26-74 tiles out), one line, a
crew and rails at the capital end, then a freight train from the far depot to the capital depot with export 100 /
keep 3,000 for iron, copper and steel plates, and a spare crew and 60 rails at both ends for repairs. The AI pays the
factory recipes' ingredients from the anchor's network, one recipe per 5 s, instead of queueing factory work (the
full planner is M3). Repairs use the same dispatch as the player's.

### 5.10 Orders and GUI

- **Trains are selected by a click**, like buildings (rolling stock is kind `train` in buildings.lua; box selection
  and Ctrl+A stay unit-only).
- orders.lua hook (`orders.on_right_click`, no orders.lua change needed): with a freight train selected, right click on
  an own depot (or its platform) = pickup, Shift + right click = drop-off; the route starts when both are set. With a
  depot selected, right click on another own depot = lay a line (`rails.plan_line`); a refusal prints the reason.
- `railgui.lua`, polling like hubgui.lua:
  - Train panel (where the hub panel sits): kind and number, HP and coal, route, state with reason, cargo, trips and
    deliveries, the line, Resume, the route hint.
  - Depot rail panel (left of the hub panel): platform, kits / rails / coal in the network, the depot's line (state,
    length, bill, missing pieces, supports, signals, what it waits for), "Deploy freight train", the force's line list,
    the "right-click another depot" hint.

## 6. Storage

```
storage.rails = {
  version = 1, test_nation?, test_bridges? (autotest), profile_survey? (autotest), next_id, depot_index = {[force] = n},
  depots   = {[depot un] = {un, force, surface, entity, index, stop_name, line,
                            platform = {axis, side, track, rails = {LuaEntity}, ends = {{x, y, d, l}, ...}, stops, area, spec}}},
  lines    = {[id] = {id, force, a, b, state, surface, created, surveyed, opened, reopened, cut_tick, cut_at, a_end, b_end,
                      pieces = {{name, x, y, d, l, rails, len, elev, ramp, sx, sy, sd, gx, gy, gd, sig, e, g, fails}},
                      supports = {{x, y, d, before, e, g}}, signals = {LuaEntity}, bill, rails, length, missing, used,
                      loaded, returned, robot, cleared, builder, wait, blocked, survey}},
  jobs     = {[id] = survey job (phase, box, cells, coarse heap, corridor, flow, fine heap / g / came / closed, cache)},
  trains   = {[train id] = {id, kind, force, home, loco, stock, state, reason, pickup, dropoff, dwell, delivered, trips,
                            line, dir, wagon, target, scan, built, last_built, ai_line}},
  dwelling = {[train id] = true}, index = {[surface] = {[piece key] = line * 100000 + piece | -depot}},
  stops    = {[stop un] = depot un}, stats = {[force] = {delivered, trips, items, lost, lines_open}},
  ai       = {[force] = {state, anchor, far, depot_a, depot_b, line, policies, next, next_craft, retry}},
}
```

Everything is cleared in `match.on_teardown` (rails.lua registers it; match.lua is unchanged). The geometry surface
stays.

## 7. Performance

| Load | ms per tick | Source |
|---|---|---|
| rails.lua handlers, no survey (building, trains running, AI program) | 0.006-0.010 | PERF=1 minutes 2-10 of `p5r-perf` (game speed 1), label `rails` (includes the autotest driver) |
| A survey tick | 1-3.4 (budgeted, at most ~5) | section 2, P5 |
| Minute with the autotest's map generation | 0.53 | test setup only: 528 chunks generated in 1.75 s |

Contract limit 0.3 ms per tick idle: met by a factor of 30.

## 8. Running the tests

```sh
# full rails autotest (11 checks) beside a 1v1 Skirmish AI autotest; build/p5-rails/run.sh wraps this
KEEP_TREE=mods/factorio-rts EXTRA_LUA=tools/probes/rails_autotest.lua STOP_ON='rails autotest summary' SPEED=4 \
  tools/autotest-run.sh rails-at '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' 1200
# per-module timings: add PERF=1 and SPEED=1
# save/load mid-survey and mid-trip
EXTRA_LUA=tools/probes/rails_saveload_survey.lua SPEED=2 tools/saveload-check.sh rails-sl-survey '{...}' 300
EXTRA_LUA=tools/probes/rails_saveload_trip.lua SPEED=2 tools/saveload-check.sh rails-sl-trip '{...}' 300
# GUI probe (opens a window): append require("scripts.rails_gui") to a test copy's control.lua, tools/gui-run.sh
```

The autotest uses its own surface `rts-railtest` (vanilla terrain, seed 4242) and the non-participating forces
rts-ai-3 (lines) and rts-ai-2 (AI program), with `storage.rails.test_nation` standing in for Nation mode. Stages:
`main` (survey, build, deliver, cut, repair, resume, an idle minute), `bridge`, `ai`, `hauler`;
`rails.AUTOTEST_STAGES` limits them, `rails.AUTOTEST_CONFIG` moves the depots or the lake.

## 9. Further results

| Run | Result |
|---|---|
| Rails autotest on the synced live tree (`p5live-rails`, `tools/probes/rails_autotest.lua`) | 11/11, 0 errors |
| Save/load mid-survey (`tools/saveload-check.sh`, `rails_saveload_survey.lua`: survey throttled to 2 expansions per tick so it spans the save at AI minute 3) | Saved in phase `score`; 0 errors in both halves; after the load the survey finished with the same route (266 pieces, bill 493) and 8/8 checks passed |
| Save/load mid-trip (`rails_saveload_trip.lua`: 300-tile line started at minute 1) | Saved with the freight train on its rounds (to the pickup at 0.61 tiles/tick right after the load); 0 errors; 8/8 after the load, including cut, repair in 7 s and resume in 13 s |
| Skirmish matrix subset on the rebased tree (`tools/autotest-matrix.sh`, KEEP_TREE) | 1v1-normal-medium 23/23 (live tree without rails: 23/23), legacy-units 65/65, legacy-units-nosa 65/65; on the earlier work tree also 1v1-normal-small-nosa 22/22. The base game (no Space Age) loads: 16 ground end states, no Bridges technology |
| GUI probe in the real client (`tools/probes/rails_gui.lua`, Russian client locale) | 6/6: depot in the build menu only in Nation rules; depot rail panel left of the hub panel; right-click on the second depot laid an 81-tile line, open in 10 s; "Deploy freight train" button; train panel, route by right-click and Shift + right-click; 1,000 iron delivered. Screenshots: `build/shots-p5-rails-gui/` |
| 1v1 Nation match (m1-world's 1536 world, 25 minutes, game speed 4) | Rails handlers 0.0007-0.0009 ms per tick before any depot exists. The AI hook stayed idle: both AIs' second cities stand 183 tiles from their capitals, below the 300-tile trigger (open issue 1) |

## 10. Shared hunks (live tree after the sync, `build/p5-rails/sync.py`)

| File:line | Lines | What |
|---|---|---|
| `balance.lua:378` | 29 | `balance.nation.hauler_slots`, `hauler_tiles_per_coal`, `balance.nation.rails`, `balance.buildings["rts-depot"]` |
| `control.lua:34` | 4 | require `scripts.rails` and `scripts.railgui` after hubgui |
| `data.lua:15` | 2 | require `prototypes.rails` after prototypes.logistics |
| `scripts/logistics.lua:61` | 1 | `local balance = require("balance")` |
| `scripts/logistics.lua:123` | 8 | `nation_mode()` (match mode, or the rails autotest flag) |
| `scripts/logistics.lua:680` | 15 | hauler fuel in `go()`: 1 coal per 40 tiles from the departure hub, else waiting "no-fuel" |
| `scripts/logistics.lua:775` | 3 | `logistics.capacity`: base 10 slots in Nation mode |
| `scripts/hubgui.lua:230` | 1 | hauler reason "no-fuel" in the hauler panel |
| `scripts/hud.lua:146` | 2 | rail item and recipes added to m1-cities' `P4.NATION_ONLY` |
| `scripts/hud.lua:238` | 1 | `rts-depot` in the Economy build tab |
| `scripts/hud.lua:285` | 7 | alert styles `line-open`, `line-cut`, `line-blocked`, `line-failed`, `train-lost` |
| `scripts/ai/commander.lua:518` | 1 | `deps.rails.ai_step(C)` after `hubs.step(C)` |
| `scripts/ai/deps.lua:9` | 1 | comment: `deps.rails` |

No change to orders.lua (the right-click hook registers itself), production.lua (factory outputs already go to the
network), match.lua (`match.on_teardown` hook), research.lua and techgui.lua (m1-economy's `research.NATION_ONLY`
already filters the research list and disables the technologies in Skirmish; rails.lua adds Railways and Bridges to it
and its unlocks to `research.EFFECTS` / `research.LOCKS` at load), buildings.lua (rails.lua adds its kinds to
`buildings.KIND_BY_NAME`) or logistics.lua's naming (m1-cities' `logistics.NAME_HOOKS`).

## 11. Open issues

1. **The AI line never triggers in today's Nation match.** The contract trigger is a hub or city ≥ 300 tiles from the
   capital; cities.lua puts the AI's second city on a world site 183 tiles out. Either cities choose a site ≥ 300 tiles
   away or `balance.nation.rails.ai_min_distance` goes down (a test run with 150 is reported to the lead separately).
   The M1 end-to-end goal ("open ≥ 1 rail line, move ≥ 20,000 items by train") depends on this choice.
2. **Nation hauler fuel stalls the AI's haulers.** In the 1v1 Nation match the AI kept no coal in its CC and hub
   networks, so 3 haulers waited "no-fuel" and the AI autotest check `hub_rts-player` failed (31/32). The rule is the
   contract's (1 coal per 40 tiles from the departing hub); the Nation AI economy needs a coal supply or a coal keep at
   its hubs. Locomotives burn coal from depot networks too.
3. **Factory grid in Nation mode.** Rails adds 5 factory recipes (cities 2, economy more) to the 25 Skirmish ones; the
   factory grid holds 2 rows of 14. The HUD layout in Nation mode needs a look (integration).
4. **Build grid built in the lobby.** `P4.NATION_ONLY` filters the build grid when it is filled; the GUI probe needed a
   tab switch after the mode changed. The HUD should refill the grid when a Nation match starts (cities' items too).
5. **Demolish on rolling stock.** The HUD building page offers m1's "Demolish" for a selected locomotive or wagon
   (kind `train`). Demolishing one breaks the train. demolish.lua should skip kind `train`, or call a rails function
   that puts the whole train back into kits.
6. **Trains kill units on the track (probe P4).** No hazard overlay yet; armies that cross a line can lose units.
7. **One line per depot in M1** ("depot-busy" otherwise); junctions, double track, yards and the dispatcher are R2.
8. **Crews live in depot networks.** A repair comes from the depot on the free side of the cut and needs a crew (2
   locomotive kits + 1 construction wagon kit) and rails there. The AI keeps a crew at both ends; a player has to.
9. **The AI pays recipe ingredients directly** from its capital's network (one recipe per 5 s; the products go to
   the depot that needs them) instead of queueing factory work.
10. **Build speed** (887 tiles in 250 s, 10 pieces per second within 48 tiles) is a tuning value in
   `balance.nation.rails`.
11. `logistics.lua`'s `nation_mode()` also honours `storage.rails.test_nation`, so the rails autotest's haulers follow
    Nation rules; the flag is test-only.
