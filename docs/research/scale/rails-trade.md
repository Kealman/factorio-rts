# Rails, trade and diplomacy at mini-state scale

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age and `elevated-rails` enabled. Research study only; no mod
code changed. The headless probe lives in `build/scale-probe-rails/` (section 8).

Inputs: `README.md`, `docs/DESIGN.md`, `docs/PHASE4.md`, `docs/qa/phase4-logistics-notes.md`,
`docs/research/api-capabilities-2.0.77.md`, `mods/factorio-rts/scripts/logistics.lua`. API names below come from
`doc-html/runtime-api.json` and `doc-html/prototype-api.json` of the installed game (`application_version` 2.0.77,
`api_version` 6). Vanilla values come from `data/base/prototypes` and `data/elevated-rails/prototypes`. "Probe" means
measured in this study's headless run; "estimate" means reasoned, not measured.

Target: a Rise of Nations / Workers & Resources style "mini-state" layer on top of today's RTS. The map is large,
cities and resource regions sit 300 to 1500 tiles apart, and trains, trade and war decide the match.

## 0. Summary

- **Trains only matter if the numbers change.** With today's hauler (20 stacks, 21.5 tiles/s, no running cost), three
  haulers move 40 plates/s over 1500 tiles for 90 iron and 30 circuits, and a railway never pays off. Three levers fix
  this together: about ten times the national flow volume, hauler fuel that grows with distance, and smaller hauler
  cargo. With the proposed constants the hauler/train crossover lands near 300 tiles at 30 items/s and near 800 tiles
  at 10 items/s (section 1).
- **"Click depot A, click depot B, the script lays the line" is feasible, and the probe proved it.** The planner learns
  the 2.0 rail geometry from `LuaRailEnd.get_rail_extensions` (a table of 32 end states, translation-invariant). It
  plans with A* in pure Lua and builds the route as `entity-ghost`s that robots, or a script, revive. The probe
  routed 414 tiles around a lake and a train ran it four times. A second line bridged a 40-tile water band with ramps,
  elevated rails and supports, and its train crossed seven times.
- **Schedules are fully scriptable.** The probe used `LuaTrain.get_schedule()` → `LuaSchedule.add_record` and
  `add_interrupt`, with `go_to_station`. A Cybersyn-style dispatcher can drive trains from the same keep/export
  policies that haulers use, so one policy language covers the regional tier (haulers) and the national tier (trains).
- **Trade is script-side.** The vanilla market needs a player to buy. Our trade uses a treasury number, physical goods
  delivered by train, and dynamic prices at neutral cities. Diplomacy maps onto `LuaForce.set_cease_fire`, `set_friend`
  and `share_chart`, plus a script relation model for the AI.
- **Effort:** 3 phases, about 22 agent-days, with a range of 19 to 26 (section 9).

## 1. Why trains must matter

### 1.1 Today's numbers make trains pointless

| Fact (today) | Value | Source |
|---|---|---|
| Hauler cargo | 20 slots (+10 with research) × 100 plates = 2,000 to 3,000 plates | logistics notes |
| Hauler speed | 21.5 tiles/s, about 2× a walker | logistics autotest |
| Hauler cost | 30 iron + 10 circuits, supply 0, no fuel | balance.lua |
| Smelter output | 0.625 plates/s; a mid-game base runs 10 to 20 smelters (6 to 12 plates/s) | README |
| Vanilla locomotive | 1,000 HP, `max_speed` 1.2 tiles/tick (72 tiles/s), `max_power` 600 kW, burner | `trains.lua` |
| Cargo wagon | 40 slots, `max_speed` 1.5 | `trains.lua` |

A hauler moves 2,000 / (2d / 21.5 + 6 s) items per second. At 1,500 tiles that is 13.7 plates/s, so three haulers carry
more than a whole mid-game base produces. They need no infrastructure and burn nothing. A railway of the same length
needs about 750 rail items. No sane player builds it, and no AI should.

### 1.2 Three levers, all needed

1. **Volume.** A mini-state region runs 20 to 60 smelters, and cities consume goods. National flows become 30 to 150
   items/s, not 5. This comes from the scale/cities work: bigger patches, regional specialisation, city demand.
2. **Running cost that grows with distance.** A hauler burns 1 coal per 40 tiles travelled, taken from the hub it
   departs. A train uses the vanilla burner locomotive and is about 100 times cheaper per item-tile (1.4). Coal is a
   Factorio cost to mine and move, not an abstract tax.
3. **Cargo.** Haulers drop to 10 slots: about 1,000 plates, or 500 ore at the vanilla ore stack of 50. A cargo wagon
   holds 40 slots and a 1-2 train 80 slots (8,000 plates). Trucks carry little, trains carry a lot.

Exposure adds to this for free: haulers cross open country every trip, while trains stay on defended corridors.

### 1.3 The tiers

| Tier | Tool | Sweet spot | Capital | Running cost | Throughput | Weakness |
|---|---|---|---|---|---|---|
| Local | Belts, inserters, robots inside one network | 0 to 80 tiles | 1 iron per belt tile (our recipe) | power for inserters | 15 items/s per belt | latency 0.53 s/tile; every tile raidable |
| Regional | Hubs + haulers (today's system) | 80 to 400 tiles, or low volume | 30 Fe + 10 circuits per hauler | fuel ∝ distance (new) | ≈ 1,000 / (2d/21.5 + 6) per hauler | open-country exposure; count grows with d |
| National | Depots + trains | 400 to 1,500+ tiles, sustained volume | rails ≈ 1 Fe + 0.25 stone per tile, depots, rolling stock | small fuel | 8,000 items per trip per 1-2 train | rail cuts stop every train on the line |
| International | Trade trains to cities and allies | any | trade post platform | tariffs, fees | contract-limited | war closes routes |

### 1.4 Cost curve with the proposed constants

Case: a sustained 30 plates/s one way for 20 minutes (36,000 items). Proposed constants:

- Belts: our recipe, 1 Fe per tile, so two belts cost 2 Fe per tile. Hauler: 10 slots, 6 s dwell, 1 coal per 40 tiles.
- Rails: `rts-rail` = 2 steel + 1 stone → 2 rails (≈ 1 Fe-equivalent per tile). Two depots plus a 1-2 train: ≈ 240 Fe.
- Train speed: probe averages (20 tiles/s over 215 tiles, 28 over 467), 35 to 38 assumed beyond. Fuel: at most
  600 kW for the whole running time, 4 MJ per coal.

| Distance | Belts (2 lanes): Fe, transit | Haulers: count, Fe + circuits, coal | Train: Fe (rails + fixed), coal | Cheapest (coal = 1 Fe, circuit = 4 Fe) |
|---|---|---|---|---|
| 100 | 200 Fe, 53 s | 1, 30 + 10c, 180 | 340, 8 | belts / haulers |
| 300 | 600 Fe, 2.7 min | 2, 60 + 20c, 540 | 540, 18 | train ≈ belts < haulers |
| 600 | 1,200 Fe, 5.3 min | 2, 60 + 20c, 1,080 | 840, 32 | train |
| 1,000 | 2,000 Fe, 8.9 min | 3, 90 + 30c, 1,800 | 1,240, 43 | train |
| 1,500 | 3,000 Fe, 13.3 min | 5, 150 + 50c, 2,700 | 1,740, 59 | train, by far |

- **Volume moves the crossover.** At 10 items/s hauler fuel is a third, so the crossover moves out to about 800
  tiles. At 100 items/s it moves in to about 150 tiles.
- **Rails and fuel scale differently.** A rail is paid once and serves every good in both directions. Hauler fuel
  recurs for every trip.
- **Belts are only cheap on paper.** They compete on capital up to about 300 tiles, but a 5-minute transit and a
  raidable line of that length are a bad trade.

The constants belong in `balance.lua` and should be tuned with a headless "logistics sim" like the unit balance sim.

## 2. RTS-friendly rail building

### 2.1 Player flow

1. Place two **Depots** (2.6), or pick existing ones.
2. Select the source depot, press **L** ("Lay rail") and right-click the target depot. The **survey** runs for 1 to 5
   s with a progress line. It draws the route preview with `rendering.draw_line` for the own force and shows the bill:
   rails, supports, signals, steel, stone and build time.
3. **Confirm** places the ghosts, and the builder (2.3) works from the railhead at robot prices.
4. When `LuaTrainManager.request_train_path{type = "any-goal-accessible"}` finds the target, the line is **open**, an
   alert fires and trains can be assigned.
5. Variants: a spur to a clicked position, a branch from existing track (multi-start A*, 2.5), double track (R2).

### 2.2 The planner

**Geometry from the engine, not hand-written.** Every 2.0 rail piece connects rail ends. A rail end is a
`RailLocation {position, direction (16-way), rail_layer}`.
`LuaRailEnd.get_rail_extensions(planner_item)` returns `RailExtensionData {name, position, direction, goal}` for
every piece that can extend that end. `goal` is the new outward end.

At `on_init` the module builds a table on a hidden scratch surface. It places a seed rail, calls
`get_rail_extensions("rail")` for every new end state, places each extension in its own slot and repeats. The probe
needed 104 scratch rails and found 32 end states (16 directions × ground/elevated). All 32 were seen again from a
second rail with **0 mismatches**: the table holds offsets relative to the end and is translation-invariant. From a
ground end facing east the options are:

| Piece | Entity position | New end | Length |
|---|---|---|---|
| `straight-rail` (east) | +(1, 0) | +(2, 0), east | 2.00 |
| `curved-rail-a` (east) | +(2, 0) | +(5, −1), east-north-east | 5.13 |
| `curved-rail-a` (south-east) | +(2, 0) | +(5, 1), east-south-east | 5.13 |
| `rail-ramp` (east) | +(8, 0) | +(16, 0), east, **elevated** | 16.76 |

Other measured lengths: `curved-rail-b` 5.08, `half-diagonal-rail` 4.47, diagonal `straight-rail` 2.83, elevated
pieces equal to their ground twins.

**Search.**

- **State and moves:** a node is (x, y, direction, layer); moves come from the table.
- **Cost:** piece length, +1 per curve, elevated × 1.5, +20 per ramp. Proposed extras: +50 % in another nation's
  territory, +5 per tile next to ore, +40 for an at-grade crossing, so the planner prefers to fly over.
- **Heuristic:** Euclidean distance × 1.3 (weighted A*).
- **Checks:** `LuaSurface.can_place_entity` with `build_check_type = manual` for ground pieces and ramps, `script` for
  elevated ones. The probe found why: `script` and `script_ghost` accept a ground rail on water, and that ghost never
  revives. `manual` rejects water, but also any elevated rail without a support yet.
- **Trees and rocks:** when `manual` fails, a second query (`find_entities_filtered` over the piece's box) tells
  whether only trees or rocks block. The piece is then allowed at +3 cost, and the builder clears them.

**Cost of the search (probe):**

| Route | Pieces | Length vs straight | Expanded | `can_place` checks | Time in one tick |
|---|---|---|---|---|---|
| 400 tiles, open ground (a run whose check ignored water) | 172 | 408 / 379 | 192 | 573 | 2.6 ms |
| 400 tiles around a 100 × 160 lake | 169 | 414 / 379 | 27,536 | 27,057 | 367 ms |
| 160 tiles across a 40-tile water band (bridge) | 66 | 162 / 160 | 7,617 | 24,264 | 129 to 258 ms |

One expansion with its checks costs about 13 µs. Obstacles blow the search up, so the shipped planner needs:

- **Time slicing.** Run 100 expansions per tick (≈ 1.3 ms) and keep the open set in `storage` between ticks. The lake
  route then takes 4.6 s of survey time, which reads as "surveyors at work".
- **A coarse pre-pass.** A* on a 16 × 16-tile grid scores each cell from `count_tiles_filtered{name = water tiles}`
  and from cliffs, buildings and borders. The fine A* then runs only inside a corridor 32 tiles wide around the coarse
  path. Expected: 3 to 10 times fewer expansions on routes with obstacles (estimate).
- **A cache of `can_place` answers** per survey, which the probe already used.

### 2.3 The builder

- **Ghosts.** `create_entity{name = "entity-ghost", inner_name = piece, position, direction, force}` worked for every
  piece, elevated rails, ramps and supports included. `ghost.revive{raise_revive = true}` built all 169 pieces of the
  lake route. `revive` returns `(collided_items, entity, proxy)`, so `ok and ghost.revive{}` loses the entity.
- **Who builds.** Inside a construction area (CC, hub, depot), vanilla robots build from the network. Outside, a
  **construction train** does: a locomotive plus a wagon of rails, supports and signals. It drives to the railhead with
  `AddRecordData{rail = <last built rail>, temporary = true}`, since a record can target a rail, not only a stop. The
  script revives the ghosts within 24 tiles ahead at 2 pieces/s from the wagon, and the train returns to its depot
  when empty. This reads like W&R's track crews, is deterministic, and the AI uses the same code. Robots from a wagon
  would need a rolling-stock `equipment_grid` with a roboport and no driver, which is unverified.
- **Supports.** Elevated rails need a `rail-support` (`support_range` 11) or a ramp end (9) close enough. In the probe,
  two support ghosts every 8 tiles of span left 4 of 8 elevated pieces unrevivable. A brute-force search fixed all 4:
  try positions within ±6 by ±2 tiles and three directions, place a support where `manual` allows it, keep it if the
  rail ghost then revives. Spots that worked: (696, 1), (701, 1), (704, −1) for pieces at x = 701 to 707. The exact
  rule (flag `snap-to-rail-support-spot`, `snap_to_spots_distance` 3) needs a one-hour probe. `rail-support` passes
  both `manual` and `script` on water, so supports stand in lakes.
- **Signals.** `LuaRailEnd.in_signal_location`, `out_signal_location` and their `alternative_*` twins return the exact
  `RailLocation` of a signal at a rail end. The builder drops a `rail-signal` every 60 to 80 tiles of one-way track
  and a `rail-chain-signal` before every junction entry and single-track section. Unverified; a Phase R1 probe item.
- **Layouts.** Phase R1: single track with one double-headed train per line; the block is the whole line, so no
  signals (the probe's layout). Phase R2: double track (a second one-way line, penalised for straying more than 6 tiles
  from the first, never crossing it) or passing sidings every 300 tiles, plus terminus loops.
- **Repair.** Set `LuaForce.create_ghost_on_entity_death = true` for every nation, so a destroyed rail leaves a ghost
  and the next builder pass or robot repairs it.

### 2.4 Bridges and grade separation

- **Probe result.** The planner, allowed to go elevated, chose ramp up, 8 elevated straights and ramp down to cross a
  40-tile band. The path was 162 tiles for a 160-tile gap. With supports in place,
  `request_train_path` found 215 tiles end to end. The train crossed seven times in 90 s at an average 19.7 to 20.2
  tiles/s, including acceleration and braking.
- **Prerequisites:** `script.feature_flags.rail_bridges` is true, and `LuaForce.rail_planner_allow_elevated_rails`
  must be set (vanilla gates it behind a technology). A ramp is 16.76 tiles long; in the probe the ramps stood partly
  over water, passed `manual` and revived.
- **Cost.** A support costs 10 steel + 10 bricks and elevated pieces 2× rails, so a 40-tile bridge costs about 150
  tiles of ground track.
- **Grade separation for free.** Elevated track collides only on the `elevated_rail` layer, so it crosses rails and
  units' paths. Flying over another nation's line avoids shared blocks and the question of whose train waits.
- **Base game without Space Age.** `elevated-rails` is a Space Age dependency. Without it the planner has no ramps and
  either routes around water or pays for landfill, done as script `set_tiles` with an item cost. The table builder
  learns only 16 ground states there, automatically.

### 2.5 Junctions

- **Branch.** The A* start set is every rail end along an existing line (each 2-tile boundary, curve extensions only),
  so the search picks the tap-off point itself. `LuaEntity.get_rail_segment_rails` enumerates a line quickly.
- **Join into a depot.** The goal is the depot platform's outer end. Several depots served by one trunk form a tree,
  with a chain signal before each split and a rail signal after it.
- **Out of scope:** full intersections (four-way, roundabouts). The planner builds trees and loops. A player who wants
  more can place vanilla rails by hand.

### 2.6 The Depot composite (station as an RTS building)

| Part | Entity | Notes |
|---|---|---|
| Core | `rts-depot`, a roboport variant like `rts-hub` | logistic radius 14, construction radius 22, 8 + 4 robots, +10 supply like a hub, raid target |
| Platform | straight rails laid by script | length 7 × cars + 4 tiles; 40 tiles for a 1-4 train |
| Stop | `train-stop`, `backer_name` = "<force> <depot name>" | a stop beside an east-west track at y = Y sits at (x, Y + 2) facing east or (x, Y − 2) facing west (probe) |
| Stockpiles | 4 × `rts-stockpile` along the platform | in the depot's logistic network, so the hub policies apply |
| Yard (optional) | a 30-tile spur with a stop named "<depot> yard" and `trains_limit` | idle trains wait and refuel here |
| Power | hidden pole + 300 kW core as in the hub | |

- **Transfer is script-driven, like haulers.** `logistics.transfer` already moves items between a
  `LuaLogisticNetwork` and a `LuaInventory`; the probe moved 400 plates from a wagon into a chest in one call. At 100
  items/s per wagon a 1-2 train dwells 40 to 80 s, so platform time stays a cost without inserter chains.
- **Refuel.** At every stop the script tops the locomotives up to 10 coal from the network (`get_fuel_inventory()`).
- **One policy language.** A depot is a hub kind with a stop. Keep and export-above thresholds, the hub panel and the
  network cache all work unchanged.

### 2.7 Schedules generated from policies

| Need | API (2.0.77) |
|---|---|
| Edit a schedule | `LuaTrain.get_schedule()` → `LuaSchedule`: `add_record(AddRecordData)`, `remove_record`, `set_records`, `clear_records`, `go_to_station(i)`, `set_stopped` |
| A record | `AddRecordData {station? or rail?, rail_direction?, temporary?, allows_unloading?, wait_conditions?, index?}` |
| Wait conditions | `WaitConditionType`: time, full, empty, item_count, inactivity, fuel_item_count_any, passenger_present, destination_full_or_no_path, damage_taken, at_station … |
| Interrupts | `add_interrupt(ScheduleInterrupt {name, conditions, targets, inside_interrupt})`, `get_interrupts`, `activate_interrupt` |
| Shared schedules | `LuaTrain.group` (assigning a group applies its schedule) |
| Queries | `LuaTrainManager.get_trains(TrainFilter)`, `get_train_stops(TrainStopFilter)`, `get_train_by_id`, `request_train_path{goals, train or starts, type = path / any-goal-accessible / all-goals-accessible / all-goals-penalties}` |
| Stops | `LuaEntity.trains_limit`, `train_stop_priority`, `get_stopped_train()`, `get_train_stop_trains()`, `connected_rail` |
| Events | `on_train_changed_state` (states in `defines.train_state`), `on_train_created`, `on_train_schedule_changed` |

The probe used `add_record` with `time` waits, `add_interrupt` with a `fuel_item_count_any < 5` refuel condition,
`manual_mode = false`, `go_to_station`, and `request_train_path` to a stop entity (3 or 4 pathfinder steps).

**The dispatcher** works like Cybersyn or LTN, per force, every 60 ticks:

1. **Collect.** For every depot network: `logistics.requests(entry)` and `logistics.exports(entry)`, from the existing
   30-tick cache.
2. **Match.** For each requested item, rank the depots that export it by rail path penalty, using
   `request_train_path{type = "all-goals-penalties"}` once per depot pair, cached for 60 s. Subtract reservations
   exactly as hauler plans do.
3. **Pick a train.** Take an idle train from the nearest yard, or the requester's yard.
4. **Write the job** as temporary records: supplier, then requester, then home yard. Each record has a long `time` wait
   (3,600 ticks) as a safety net. The script loads or unloads and then calls `go_to_station(next)`, so the train
   leaves as soon as the transfer ends.
5. **Release and fallback.** Arrival at the yard frees the train. A requester with no rail-connected supplier stays
   with the hauler logic; haulers remain the last mile.

**Manual routes** use the same UX as haulers. Select trains, right-click the pickup depot, Shift + right-click the
drop-off depot. The script writes two persistent records and sets `train.group = "Iron Hills → Capital"`, so a new
train joins the route with one assignment.

### 2.8 Raidable rails and trains

- **Targets.** Vanilla HP: straight rail 200, locomotive 1,000, artillery wagon 600. Rails, stops and rolling stock
  get the `rts-raid-target` trigger target (raiders deal 2.5×). Rails are not military targets, so units hit them
  only on an explicit order.
- **Sabotage.** Raiders get a "Demolition charge" (3 s channel, destroys rails within 3 tiles). Trains on the line
  switch to `no_path`, `on_entity_died` of the rail raises "Line cut at (x, y)", the dispatcher holds trains until
  `any-goal-accessible` succeeds again, and the ghost-on-death rule plus the construction train repair the cut.
- **Ambush.** Trains are fast but predictable; units parked at a choke hit every train, and armoured trains escort.
- **Trains hit units.** Whether rolling stock collides with our spider-units is unverified (Phase R1 probe). If it
  does, keep the rule and draw a hazard overlay on tracks.

## 3. Train types

| Type | Composition | Prototype basis | Role | Proposed cost | Supply |
|---|---|---|---|---|---|
| Freight | 1 loco + 1 to 4 wagons | `rts-locomotive` (vanilla loco clone, team colour via `LuaEntity.color`), `rts-cargo-wagon` (40 slots) | national logistics | loco 40 Fe + 10 steel + 10 circuits; wagon 20 Fe + 5 steel | 0 |
| Armoured | armoured loco + gun wagon | loco clone with HP 3,000, 40 % physical, 30 % explosion; gun wagon = `ArtilleryWagonPrototype` with our own `gun` (range 30, magazine ammo) | escort, line clearing | 80 Fe + 30 steel + 10 circuits | 4 |
| Artillery | loco + artillery wagon | vanilla `artillery-wagon` with its gun's range cut from 224 to 60 tiles and `manual_range_modifier` 1 | siege along your own track | 40 Fe + 20 steel + 10 explosives | 6 |
| Troop | loco + troop wagons | `rts-troop-wagon` (cargo-wagon clone, 1 slot, own graphics tint) | move an army 1,000 tiles in 30 s | 30 Fe + 10 steel | 0 (units keep theirs) |
| Construction | loco + construction wagon | cargo-wagon clone, 20 slots for rails, supports, signals | lays and repairs track (2.3) | 30 Fe + 10 steel | 0 |

**Troop transport.**

- **Why not teleport.** `LuaControl.teleport` crosses surfaces only for "players, cars, and spidertrons". Our units
  are `spider-unit` and `unit`, so a hidden hold surface does not work.
- **The manifest.** Units ordered to "Board" walk to the troop platform. Within 4 tiles of a troop wagon they despawn
  into `storage.rails.manifests[wagon unit_number]` (name, health ratio, kills, Commander level, control group).
  `supply.used` adds the manifest costs, a one-function change. On `wait_station` at the named stop they respawn in a
  ring around the wagon with health and ranks and go to the rally point. Capacity: 16 supply per wagon.
- **A destroyed wagon** kills its occupants; proposed: 25 % spill out wounded, so an ambush is a real battle.

**Artillery note.** The vanilla artillery wagon outranges everything in this game by a factor of five, so it needs its
own gun prototype. It must stay a siege tool along your own track, like a railway gun.

## 4. Trade

### 4.1 Actors

Nations (players and AI forces) trade with **city-states**: neutral, one force each (`rts-city-<n>`), at cease-fire
with every nation; the cities study defines their growth and demand. This study needs a **Trade Post** per city (a
depot of the city's force with one platform per trading nation, built on first trade) and a stock and price book per
good. Nations also trade with each other under **contracts** (4.6).

### 4.2 Currency

- **A script number.** `storage.trade.treasury[force]` holds "crowns", shown in the resource strip. Goods are
  physical and payment settles on delivery, so a raided train costs the seller its cargo, the buyer pays nothing, and
  money cannot be stolen. Raids stay about logistics.
- **Not the vanilla market.** `MarketPrototype` with `LuaEntity.add_market_item` works only through a player GUI
  (`on_market_item_purchased` carries `player_index`) and trades item for item. Trains and AIs are script actors, so the
  Trade Post panel is our own GUI.
- **What crowns buy:** goods at cities, mercenary units at a city's barracks (an optional sink), contract payments,
  tariffs, and diplomacy gifts. Crowns never replace production. Units and buildings still need chains.

### 4.3 Dynamic prices

Each good has a base value from its recipe cost:

| Good | Iron ore | Copper ore | Coal | Stone | Iron plate | Copper plate | Steel | Circuit | Brick | Explosives | Science kit (basic / adv.) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Base value (crowns) | 0.6 | 0.6 | 0.5 | 0.4 | 1 | 1 | 2.5 | 3.5 | 0.9 | 3 | 4 / 12 |

Per city and good:

- **State:** a stock `S` and a target `T`; consumption and production drift `S` every minute with city size.
- **Price:** `p = value × clamp((T / max(S, 1)) ^ 0.6, 0.3, 3.0)`.
- **Spread:** a city sells at `p × (1 + fee)` and buys at `p × (1 − fee)`. The fee is 10 % at neutral reputation,
  5 % when friendly and 25 % when hostile (4.7).
- **Updates:** every 60 s, and after every trade. Each delivery moves `S`, so dumping 20,000 iron into one city crashes
  its iron price. Players and AIs spread sales across cities.
- **Shocks:** city events every 5 to 8 minutes, such as "Ravenford builds a cathedral: brick target × 3 for 6
  minutes". They create temporary trade routes worth a detour.

### 4.4 Trade routes and commerce income

Rise of Nations pays caravans by route length. Here a delivery to a city pays the goods' price plus a commerce bonus
of `0.02 × goods value × (rail distance / 100) ^ 0.8`, capped at +30 %, which rewards rails into the wild. The bonus
needs at least 2,000 crowns of cargo per train, so empty shuttles earn nothing.

### 4.5 Scarcity by design

The map generator gives each region one or two major ores and leaves others thin. For example, the western highlands
have iron and coal but almost no copper.

A copper-poor nation can conquer a copper region, build a long line to a distant patch, or buy copper from a city
or a rival. It has a reason to trade, to make peace with a copper-rich neighbour, or to go to war for the patch: the
Workers & Resources tension, expressed with Factorio goods.

### 4.6 Contracts

A contract is `{seller, buyer, item, amount_per_delivery, deliveries, interval, price_per_unit, penalty}`, proposed
in the diplomacy panel or by an AI.

- **Execution and payment.** The seller's dispatcher treats the contract as a request at the buyer's nominated border
  depot. It settles per delivery; a delivery late by 2 minutes pays the penalty and costs reputation.
- **Trains on foreign track.** Whether a train of force A paths over rails owned by force B, and stops at B's stops,
  is unverified. The design avoids the question: each side builds track to a **border exchange**, two depots
  facing each other with a shared stockpile pair. The script moves goods across on settlement. Interchange yards are a
  real historical solution and need no engine assumption.

### 4.7 Tariffs, fees and embargoes

- **City fees** depend on reputation with that city (4.3).
- **National tariffs.** A nation sets an import tariff (0 to 50 %) on goods that cross its border exchanges. It is
  paid into its treasury, so a nation sitting between two others profits from transit.
- **Embargo.** A nation can forbid all trade with another, through contracts and border exchanges. Allied cities, at
  friendly reputation with the embargoing nation, raise their fee for the target to hostile.

## 5. Diplomacy

### 5.1 States and their engine mapping

| State | `set_cease_fire` (both ways) | `set_friend` | `share_chart` | Trade | Units in their territory |
|---|---|---|---|---|---|
| War | false | false | false | embargoed by default | fight |
| Ceasefire (at least 3 min, then Peace unless renewed) | true | false | false | allowed | border incident (−5 relation per minute per 10 supply) |
| Peace | true | false | false | allowed | border incident |
| Alliance | true | true | true | allowed, fees −50 % | allowed; shared vision; shared victory |

- **Engine.** `LuaForce.set_cease_fire` stops automatic targeting. `set_friend` plus `share_chart` gives shared vision.
  `on_force_cease_fire_changed` and `on_force_friends_changed` let the HUD react.
- **Audit (Phase R3).** Today `match.lua` sets every pair hostile, and `fog.lua` forces `share_chart = false`. Every
  script that picks targets must ask `force.is_enemy(other)` instead of "a force other than mine": `orders.lua`
  attack and attack-move, AI `army.lua`, `raids.lua`, abilities and the victory check. Attack orders against a
  non-enemy are refused with a message, and declaring war is one button.

### 5.2 Reputation

Relation `r[a][b]` runs from −100 to 100 and starts at 0; each AI also keeps one per city. It changes by:

| Event | Δ relation |
|---|---|
| Trade with them (per 1,000 crowns) | +1 (cap +10 per minute) |
| Contract delivered / missed | +3 / −8 |
| Common enemy at war | +2 per minute |
| Their units in my territory (per 10 supply per minute) | −5 |
| They attacked my units or buildings | −20 (first hit), −1 per 1,000 damage after |
| Embargo against me | −15 |
| Gift (per 1,000 crowns) | +4, diminishing |

Relations decay 1 point per minute toward a doctrine baseline: economic +10, turtle +5, aggressive −10.

### 5.3 How AI nations decide

Every 60 s each AI evaluates every other nation. `power(x)` is the supply of live units, plus 2 per turret, plus
production value per minute / 500 (`LuaForce.get_item_production_statistics`). `ratio = power(me) / power(them)`;
`weariness` is the share of supply lost in the last 5 minutes. Doctrine thresholds:

| Decision | Economic | Aggressive | Turtle |
|---|---|---|---|
| Declare war when r < … and ratio > … | −50, 1.4 | −20, 1.0 | −60, 1.6 |
| Accept or offer ceasefire when ratio < … or weariness > … | 0.8, 30 % | 0.5, 50 % | 0.9, 25 % |
| Offer alliance when r > … and there is a common enemy | 40 | 60 | 30 |
| Embargo when r < … and they depend on my exports | −30 | −20 | −40 |
| Accept a player's contract when its margin ≥ … over city prices | 0 % | 10 % | 5 % |

- **Stability and replies.** No betrayal within 10 minutes of an alliance. Proposals are answered after 10 to 20 s
  with a reason line, for example "Declined: you have 40 walkers inside our border".
- **Trade.** The AI economy reads its own keep thresholds. A shortfall it cannot fill within 3 minutes from its own
  regions becomes a buy order at the cheapest reachable city, or a contract proposal to the nation with the best
  relation that exports the good. A surplus above the export threshold sells when the city price exceeds 0.9 × value.

### 5.4 Player UX

A diplomacy panel (F4) has one row per nation and city: state, relation bar, trade volume, and buttons for war,
ceasefire, peace, alliance, embargo, gift and contract. AI proposals arrive as alerts with Accept and Decline (F3
cycles them). The minimap tints borders by state and draws trade routes.

## 6. Interaction with the existing systems

| System | Change |
|---|---|
| Hubs | Unchanged; the regional tier. A depot is a hub kind with a platform, so `logistics.networks`, policies and the hub panel cover depots. |
| Haulers | Unchanged code paths. New: fuel per tile (1 coal per 40 tiles from the departure network) and 10 cargo slots at mini-state scale. They feed depots, serve hubs with no rail, and are the fallback when a line is cut. |
| Supply cap | Freight, construction and troop trains cost 0. Armoured costs 4, artillery 6. Embarked units still count (manifest). A depot adds +10 like a hub. |
| Raiders | Bonus vs rails, stops and rolling stock (trigger target). New Demolition charge ability. AI `raids.lua` gets a target class "rail line": the nearest unguarded track segment on the route between two enemy depots. |
| Research | Railways (rails, depot, freight train), Bridges (elevated rails, sets `rail_planner_allow_elevated_rails`), Signalling (double track, junctions), Armoured trains, Rail artillery, Troop trains, Trade charter (city trade, contracts). |
| Fog | Rolling stock gets `chunk_exploration_radius` 1, so trains reveal their corridor. Allies share charts. |
| AI construction | The AI calls the same planner and builder: a line to its far region once its keep shortfall persists. The planner is deterministic, so multiplayer is safe. |
| Victory | Unchanged for skirmish. Mini-state victory rules (capitals, cities, score) belong to the cities study. |

## 7. Feasibility

### 7.1 API and prototype map

| Need | Runtime API | Prototype | Status |
|---|---|---|---|
| Learn rail geometry | `LuaEntity.get_rail_end(direction)`, `LuaRailEnd.get_rail_extensions(planner_item)` → `RailExtensionData`, `RailLocation` | `RailPlannerPrototype.rails` / `support` | **Probe: works** |
| Place check | `LuaSurface.can_place_entity{build_check_type}`, `defines.build_check_type.manual / script / script_ghost` | | **Probe: manual for ground, script for elevated** |
| Ghosts, build | `create_entity{name = "entity-ghost", inner_name}`, `LuaEntity.revive` | | **Probe: works, incl. elevated and supports** |
| Pieces | | `straight-rail`, `half-diagonal-rail`, `curved-rail-a`, `curved-rail-b`, `elevated-*` twins, `rail-ramp` (`support_range` 9), `rail-support` (`support_range` 11) | **Probe** |
| Signals | `LuaRailEnd.in_signal_location`, `out_signal_location`, `alternative_*` | `rail-signal`, `rail-chain-signal` | documented, not run |
| Trains | `LuaEntity.train`, `connect_rolling_stock`, `LuaTrain.manual_mode / state / path / has_path / get_contents / insert / remove_item`, `get_fuel_inventory` | `LocomotivePrototype`, `CargoWagonPrototype.inventory_size`, `ArtilleryWagonPrototype.gun` | **Probe: works** |
| Schedules | `LuaTrain.get_schedule()` → `LuaSchedule`, `AddRecordData`, `WaitCondition`, `ScheduleInterrupt`, `LuaTrain.group` | | **Probe: works** |
| Rail pathfinding | `LuaTrainManager.request_train_path`, `get_trains`, `get_train_stops`, `get_train_by_id` | | **Probe: works** |
| Events | `on_train_changed_state`, `on_train_created`, `on_train_schedule_changed`, `on_entity_died` | | **Probe** (state events) |
| Bridges | `LuaForce.rail_planner_allow_elevated_rails`, `script.feature_flags.rail_bridges` | `elevated-rails` mod | **Probe: works** |
| Repair | `LuaForce.create_ghost_on_entity_death` | | documented |
| Troops | `LuaControl.teleport` (cross-surface: players, cars, spidertrons only) | | documented; manifest needed |
| Diplomacy | `LuaForce.set_cease_fire / get_cease_fire / set_friend / get_friend / is_enemy / is_friend / share_chart`, `on_force_cease_fire_changed`, `on_force_friends_changed` | | documented (`set_cease_fire` already used in `match.lua`) |
| Market (not used) | `LuaEntity.add_market_item`, `on_market_item_purchased` (player only) | `MarketPrototype` | documented |
| Team colours | `LuaEntity.color` on rolling stock and train stops | | documented |
| Economy reads | `LuaForce.get_item_production_statistics(surface)` | | documented |

### 7.2 Per-tick cost at 4 nations, 30 trains, 60 stations

| Load | Frequency | Cost | Basis |
|---|---|---|---|
| Engine: 30 moving trains | every tick | < 0.1 ms | estimate; vanilla bases run hundreds of trains at 60 UPS. The probe's 2 trains ran beside a full RTS autotest match with no errors. |
| Engine: ≈ 12,000 rail pieces (4 nations × 6,000 tiles) | static | ≈ 0 | rails have no update; blocks change only when trains enter |
| `on_train_changed_state` handler | ≈ 8 events per round trip → about 4 per second | < 0.01 ms/tick | event-driven |
| Depot transfer | every 10 ticks while a train dwells; ≤ 10 trains at platforms × ≤ 4 wagons × ≤ 5 goods | 0.05 to 0.1 ms/tick averaged | ≈ 200 API calls per 10 ticks |
| Dispatcher | every 60 ticks per force; 60 depots × ~20 goods from the existing cache; path penalties cached 60 s | < 0.01 ms/tick averaged | |
| Planner (survey) | only while a survey runs; one per force at a time | 1.3 ms/tick at 100 expansions per tick | probe: 13 µs per expansion |
| Construction train | every 30 ticks; ≤ 4 builders × ≤ 1 revive | < 0.02 ms/tick | |
| Trade prices, contracts, diplomacy AI | every 60 ticks | < 0.01 ms/tick | arithmetic only |
| **Total steady state** | | **≈ 0.2 to 0.3 ms/tick**, plus 1.3 ms per active survey | |

**Map size.** A 3,000 × 3,000-tile map has about 8,800 chunks; generation, save size and charting are the real scale
costs (map and cities study). Rails add little.

### 7.3 Risks

| Risk | Rating | Mitigation |
|---|---|---|
| **Automated construction on real terrain:** trees, cliffs, ore, other nations' buildings, junctions, signals at curves, support spots | **High** | Coarse pre-pass. Tree clearing by the builder. Brute-force support search. Phase R1 starts single-track with no signals. A probe on a real generated map before any GUI work. |
| Economy scale mismatch: trains decorative unless volumes ×10 and hauler costs change | High (design) | Section 1.2 levers, tuned with a logistics sim. Keep the three levers in one balance table. |
| Planner cost spikes | Medium | Time slicing, corridor search, cache, one survey per force |
| Trains vs our units (collisions, units blocking crossings) | Medium | Phase R1 probe. Hazard overlay. Grade separation preferred. |
| Foreign track and stops (A's train on B's rails) | Medium | Avoided by border exchanges (4.6) |
| Troop manifest edge cases: save/load, death in transit, supply | Medium | All in `storage`; the autotest kills a loaded wagon and save-loads mid-trip |
| Targeting audit for ceasefire and alliance across all modules | Medium | One helper `diplomacy.hostile(a, b)` and a grep audit; autotest "no damage between ceasefire forces for 2 minutes" |
| Base game without `elevated-rails` | Low | The table learns ground-only; landfill fallback |
| UPS from trains | Low | Estimate above; benchmark in Phase R2 |
| Artillery wagon balance | Low | Own gun prototype with range 60 |

## 8. Probe

**Setup.** `build/scale-probe-rails/` holds a copy of `factorio-rts`, the repo `mod-list.json` and a test-only mod
`rts-rail-probe/` (code in its `control.lua`). The probe works on its own lab-tile surface and force, so the RTS
autotest match ran alongside without errors. Run: `tools/headless-run.sh 100 '\[railprobe\]' build/scale-probe-rails`;
log: `build/scale-probe-rails-server.log`. Five runs: four to fix the probe, the last to confirm.

| Question | Verdict | Evidence |
|---|---|---|
| Q1: learn 2.0 rail geometry by script | **Yes** | 32 end states (16 directions × 2 layers) from 104 scratch rails, 0 mismatches across 32 re-observations, in ≈ 2 ms at init |
| Q2: plan with A* and build as ghosts + revive; does the train path? | **Yes** | Lake route: 169 pieces (155 straight, 6 curved-a, 8 curved-b), 414 tiles for a 379-tile gap. All 169 ghosts revived. `request_train_path` found 467 tiles in 4 steps. |
| Q3: scripted schedule and interrupt move a train A → B → A | **Yes** | Double-headed 1-1-1 train on coal. 467 tiles in 16.6 to 16.8 s (28 tiles/s average incl. acceleration and braking), 4 arrivals in 75 s. 400 plates unloaded by script at B. The interrupt was accepted. |
| Q4: bridge a 40-tile water band | **Yes, with a support search** | Ramp, 8 elevated straights, ramp. The first support guess left 4 pieces unsupported; the search placed supports that let all 4 revive. 215-tile path. Train crossed 7 times, 10.7 to 10.9 s per leg. |

**Gotchas:**

1. **Build checks.** `script` and `script_ghost` accept ground rails on water, and `revive` then fails. Use `manual`
   for ground pieces and ramps. `manual` rejects unsupported elevated rails, so use `script` for elevated pieces.
2. **`revive` returns three values.** In `ok and ghost.revive{}`, the entity is lost.
3. **Zero inserts error.** `LuaInventory.insert{count = 0}` raises an error.
4. **Diagonal straights are longer.** `straight-rail` placed diagonally is 2.83 tiles long. Take lengths per
   extension from the scratch entity, not per prototype name.
5. **Rolling stock connects itself.** Stock created 7 tiles apart on the same rail joined into one train
   (3 carriages) without `connect_rolling_stock`.
6. **Supports.** A support at a piece position every 8 tiles did not always carry the span. `rail-support` passes
   `manual` on water, and two supports with different directions can share one position. The spot rule needs a probe.
7. **Open-ground A\* is fast, obstacles are not.** On open ground it expanded only about 1.1 nodes per piece; the
   lake made it about 140 times more.

**Not measured:** UPS of 30 trains, signal placement from `out_signal_location`, trains colliding with spider-units,
foreign-force track use, vanilla robots from a rolling-stock equipment grid.

## 9. Phased plan

### Phase R1: rail backbone (7 agent-days, range 6 to 8)

- Prototypes: `rts-rail` (2 steel + 1 stone → 2), the `rts-depot` composite, `rts-locomotive` and `rts-cargo-wagon`
  kits from the factory, the construction wagon, research Railways and Bridges.
- `scripts/rails.lua`: extension table at init; time-sliced A* with coarse pre-pass and tree handling; ghosts, support
  search, construction-train builder; depot platform and stop layout, script transfer and refuel.
- Manual train routes with the hauler UX; a train panel (state, cargo, route); alerts for line open and line cut.
- Probes first, about 1 day: support-spot rule, signal placement from `RailLocation`, spider-unit vs train collision,
  and a planner run on a real generated map with trees and cliffs.

**Acceptance (headless autotest):**

- Two depots 800 tiles apart with a lake between: the survey finishes in ≤ 10 s of game time, the construction train
  lays the line within ±5 % of the billed rails, and a 1-2 train then delivers ≥ 4,000 iron in 3 minutes.
- Destroying 3 rails sets the train to `no_path` and raises "line cut". The builder repairs the cut, and deliveries
  resume within 60 s.
- Save and load mid-survey and mid-trip give no errors; PERF shows the rail module ≤ 0.3 ms/tick with no survey.

### Phase R2: dispatcher and military trains (7 agent-days, range 6 to 8)

- Policy-driven dispatcher (2.7) with yards, refuel interrupt and train groups.
- Double track or sidings with automatic signals.
- Armoured train, rail artillery, troop wagon with the manifest.
- Hauler fuel and slot changes behind a mini-state switch.
- AI: builds one line to its far region, runs 2 trains, repairs cuts, raids enemy lines with Demolition charge.

**Acceptance:**

- A 20-minute 4-nation large-map AI autotest: every AI opens ≥ 1 line and moves ≥ 20,000 items by train, and at least
  one line is cut by an AI raid and repaired.
- A troop train carries 12 walkers 600 tiles. They disembark within 10 s of arrival with health within 1 % of
  boarding, and supply stays constant.
- A loaded troop wagon destroyed in transit removes its units and raises an alert.
- UPS benchmark with 30 trains: total ≤ 1 ms/tick above the same map without trains.

### Phase R3: trade and diplomacy (8 agent-days, range 7 to 10)

- Treasury in the resource strip; Trade Posts at cities (from the cities work), price book and city events.
- Contracts, border exchanges, tariffs and embargoes.
- Diplomacy states and engine mapping, the targeting audit (`diplomacy.hostile`), the relation model and AI decision
  table, the diplomacy panel with proposals and alerts, minimap borders and route lines.

**Acceptance (40-minute 4-nation headless match plus a GUI pass):**

- Prices stay within [0.3, 3] × value. A 10,000-iron dump at one city lowers its iron price by ≥ 30 %, and the price
  recovers within 10 minutes.
- At least one AI–AI contract is signed and fulfilled by train.
- An AI declares war past its relation and power thresholds; another accepts a ceasefire past its weariness threshold.
- Ceasefire forces deal no damage over 2 minutes with armies 30 tiles apart. An embargo blocks a contract. Allies see
  each other's charts.
- Save/load at minute 20 preserves treasury, relations, contracts and manifests.

**Total: 22 agent-days, with a range of 19 to 26.** Phase R1 depends on nothing new. R2 needs R1. R3 needs the cities
study's city entities and map; its diplomacy half can start in parallel with R2.

## 10. Decisions for the lead

1. Accept the hauler changes at mini-state scale (fuel per tile, 10 slots); without them trains are decorative.
2. Treasury as a script number (recommended) or a physical `coin` item that trains can lose to raids.
3. Rail building by construction train (recommended; deterministic, the AI shares it) or by robots in networks only.
4. Phase R1 layout: single track with one double-headed train per line (probe-proven), or double track from day one.
5. Whether base game without Space Age is a mini-state target; without it there are no bridges, only landfill.
