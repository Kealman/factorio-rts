# Release 0.1.2, agent r3-rails: multi-stop schedules (#31 B), the train builder (#32), player-built railways (#31 A)

Date: 2026-10-26. Branch `r3-rails` from `main` 43a8581 (0.1.1). Factorio 2.1.23 (Steam, mac-arm64), Space Age on.
Plan: `docs/qa/release-0-1-2-plan.md`. Issues: #31 (epic, parts B then A) and #32. Everything here is Nation-only:
`rails.nation()` gates stay, Skirmish never sees rails.

## 1. Part B: multi-stop schedules (#31 items 5-9)

### 1.1 Design as built

- **New module `scripts/railroutes.lua`** (required right after rails.lua). A train record with `rec.stops` runs a
  **native engine schedule**: one `add_record` per stop (the depot's unique stop name, or a `rail` record for a rail
  stop) with the stop's vanilla wait condition. A -> B -> C -> B loops by itself; the script never sends it on. rails.lua
  calls the module through `rails.routes = {step, click, refresh, resume, serves}` and leaves its own legacy paths
  (`dwell_step`, the two-record route, `on_train_changed_state`) to trains without `rec.stops`.
- **The AI keeps `rails.set_route`** (two script-driven records, unchanged code). Its trains never get `rec.stops`;
  `set_route` on a train with a stop list drops the list. `create_train(depot, kind)` and `kit_list` are unchanged.
- **Stop** = `{target = depot un | rail = LuaEntity, unload, unload_items, load, load_items, troops, bombard, wait}`.
  Policies at a depot stop (goods move between the depot network and the **cargo wagons** at `transfer_rate` = 200 items
  per second per wagon through `logistics.transfer`, unload first, then load):

  | Policy | Rule |
  |---|---|
  | Unload to Keep | what the network's Keep still lacks; a network without any Keep takes everything (0.1.1 drop-off) |
  | Unload everything | all cargo |
  | Unload items... | the listed items, up to n each per visit (0 = all of it) |
  | Load exports | what the network exports above its threshold; when the next unloading stop is "to Keep" with Keep thresholds, only what that network lacks minus cargo aboard and on its way (0.1.1 pickup rule); when it is "items", only those items |
  | Load items... | the listed items until the train holds n (0 = as much as fits), from what the network holds above its own Keep |
  | Troops: board / get off | troop wagons: divisions told to embark board while it stands there (garrison.lua); every soldier gets off on arrival |
  | Bombard here | an artillery wagon fires (trainswar.lua) while the train stands at this stop |

- **Wait conditions** are the engine's: cargo idle N s (`inactivity`, the default, 10 s), full, empty, N seconds
  (`time`), item count >= / <= n (`item_count`). The script writes `LuaSchedule.tick_of_last_activity` whenever it moves
  goods (and while divisions walk to a "board" stop), so "cargo idle" counts its transfers like inserters. A bombard
  stop defaults to 60 s.
- Locomotives refuel at every depot stop (as before); the unload plan is made once on arrival and retried every second
  while the network is full; loading starts after the first unload pass and plans again every second once done (new
  exports keep flowing while the train waits, as inserters would).
- Loop on by default; loop off halts the train after its last stop (Resume starts over at stop 1).
- Depots removed or captured: lists that name them are written again without them (`rails.routes.refresh`), and with
  them again when the depot comes back. A train whose id changes (coupling) gets its schedule written again.
- Rail stops: trains with troop or artillery wagons only (troops get off at a rail; an artillery wagon bombards from
  it). The record is a non-temporary `rail` record (probe: it stays in the schedule and loops).
- `logistics.served_by_train` and the line crews' "train in the way" rule (`on_line`) understand stop lists; garrison
  counts a depot on a troop train's list as "coming" for the embark order.

### 1.2 UX

- **Right-click** a depot with a train selected: the depot becomes the **last stop**; **Shift + right-click** inserts
  it after the stop selected in the panel. Troop and artillery trains also take a rail. The first stop of a new list
  loads exports (cargo) and boards troops; later stops unload to Keep and let troops off; the same depot twice in a row
  is refused with a flying text.
- **Train panel** (railgui.lua): ordered stop rows ("→ 1. Depot 1" marks the stop the train heads to or stands at) with a
  summary line each; Loop checkbox and Clear; a click on a row opens its editor: Up / Down / Remove, Unload and Load
  drop-downs (item rows with counts and "Add item" through the item picker), Troops, Bombard here, "Leave when" with the
  seconds, item and at least / at most fields; the status line "Stop 3 of 4: Depot 2, loading [iron] 120 / 400". The
  rows are rebuilt only when the list's structure changes, so a number being typed keeps its focus.
- `scripts/itempicker.lua`: `open(..., opts)` takes a custom item list (`opts.items`, title): the stop editor offers the
  depot network's contents, the hub panel's policy items, raw resources and the goods cities make.

### 1.3 Migration of 0.1.1 saves

`railroutes.init` (idempotent, `storage.rails.routes_v = 1`): every train of a force with players that had a 0.1.1
two-record route (`pickup`, `dropoff`, not an AI line train) becomes a two-stop list: pickup "Load exports" (troop
trains: board), drop-off "Unload to Keep" (troops: get off), wait "cargo idle 10 s". AI trains keep their routes.

### 1.4 Tests (part B)

| Test | Command | Result |
|---|---|---|
| Schedule fixture, 20 game minutes, no script restart | `SPEED=8 DURATION_MIN=40 EXTRA_LUA=tools/probes/r3_rails_schedule.lua STOP_ON='r3 schedule summary' tools/autotest-run.sh r3-sched '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' 900` | **8/8**: 4 records (inactivity / inactivity / time / inactivity); visits 1 2 3 4 1 2 3 4 ... in order, 7 loops; train 1 delivered 7,400 iron and 1,000 stone to B and 59,762 copper to C; the script wrote each schedule once (setup) and never again; junction crossed 15 times by train 1 and 29 by train 2 (15 loops), longest stand at a signal 0 s; status "stop 1 of 4, load iron-plate 396 / 2000"; the artillery train's non-temporary rail record looped 22 times with bombard active at the rail. 0 Lua errors |
| Skirmish smoke | `tools/autotest-run.sh r3r-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65, 0 errors |
| Owner's Age II save (copy, version bumped to 0.1.2 so `on_configuration_changed` runs every init) | headless server 130 s | 0 errors, 797 `[rts]` lines; "the 0.1.1 route depot #2153 -> depot #2124 is now a two-stop list" (train 46, rts-player); the train then loaded at stop 1 and unloaded 78 coal + 5 goods at stop 2 on the native schedule. Without the version bump (same 0.1.1 version) the init does not run and train 46 keeps its 0.1.1 route on the legacy path, also without errors |
| GUI probe, real client EN and RU (`tools/probes/r3_rails_gui.lua`) | test copy + `tools/gui-run.sh <copy> 150 RTS_R3_GUI_DONE` (RTS_LOCALE=ru) | **6/6 in both**: right clicks on A, B, C, B make 4 stops (4 rows); Shift + right click with stop 1 selected inserts C as stop 2; the editor of stop 2; unload "items..." + Add item + a pick gives an iron row; the wait drop-down on "item count" writes `{type = "item_count", condition = {comparator = "≤", ...}}`; the train ran and delivered 2,000 iron. Screenshots `build/shots-r3rails-gui-en/`, `build/shots-r3rails-gui-ru/` (the panel fits 1280x800 at UI scale 0.75 in both languages) |
| AI identity, M1 seed 501 (`SEED=501 SPEED=8 DURATION_MIN=60 EXTRA_LUA=tools/probes/m1_acceptance.lua`, Nation 1v1 2048) | 43a8581 (0.1.1) vs 48372d4 | identical: 51/53, train items 19,101 (rts-player 10,881 in 60 trips, rts-ai-1 8,220 in 39), linked 3 and 2 at minute 61; the first 69,193 `[rts]` lines equal (timings normalised) apart from the event bus's stagger line, which listed railroutes' own period-10 handler: 59263ab drives the stop-list dwell from rails.lua's transfer handler instead |

## 2. The train builder (#32)

### 2.1 Design as built

- **Composition** = carriages front to back, `{name = carriage entity, reversed = bool}`; every carriage is its kit from
  the depot network (`rails.KIT_OF`). `rails.compose_check(depot, cars)` names why it cannot be deployed now and what
  the panel shows (kits needed and missing, locomotives, coal = 2 per locomotive, platform tiles and the carriages they
  hold, forwards-only, troop capacity); `rails.create_composed(depot, cars, opts)` assembles it (the platform slots,
  stepping aside and joining are `create_train`'s, factored out into `spawn`; the AI's `create_train(depot, kind)` runs
  the same code as before). The record gets `composed`, `caps` (cargo, troop, artillery, construction wagons,
  locomotives) and `cars`; `kind` is the dominant one (most wagons of cargo, troop or artillery; "cargo" for
  locomotives and construction wagons only), so old panels and the AI read it as before.
- **Rules shown, not guessed**: the first carriage must be a locomotive facing forwards; a composition longer than
  the platform holds is refused with the reason ("6 carriages do not fit: a 40-tile platform holds 5"); no
  locomotive facing back flags "this train can only leave forwards" (a warning: player track may have loops).
- **Platform length**: `rails.set_platform_length(force, 40 | 60 | 80)` sets what a force's next depots lay (the
  depot panel's "Platform of new depots" drop-down); 40 tiles hold 5 carriages, 60 hold 8, 80 hold 11
  (`rails.max_carriages`). A longer platform that fits nowhere falls back to 40. AI forces never set it.
- **Presets** (the old Deploy buttons): Freight, Construction (work train), Troop (1 wagon), Troop (3 wagons),
  Artillery, Armoured freight, Armoured troop, Mixed: cargo and troops, Mixed: armoured siege. **Templates**: up to 5
  per force in `storage.rails.templates[force]` (a name replaces the template of that name), in the same drop-down.
- **Mixed trains per carriage**: cargo wagons follow the stop policies (railroutes.lua moves goods only into
  `rts-cargo-wagon`s), troop wagons board and unload (garrison.lua: a train carries troops when its kind is troop or
  its caps have troop wagons), an artillery wagon bombards (trainswar.lua; a composed train takes its starting shells
  through `rails.on_deployed`).
- **Edit a standing train** (train panel, on an own depot platform): a palette couples a carriage at the rear (its kit
  from that depot's network; the rear is the end farther from the platform end trains leave by), "Remove rear" takes
  the rear carriage off (cargo, coal and shells back into the network; half its kit back as a per-force credit:
  every second carriage of a kind gives one kit). The last locomotive and a wagon with troops aboard stay.

### 2.2 Tests (#32)

| Test | Command | Result |
|---|---|---|
| Builder fixture (`tools/probes/r3_rails_builder.lua`, beside a Nation 1v1 2048 match, seed 501, speed 4) | `SEED=501 SPEED=4 EXTRA_LUA=tools/probes/r3_rails_builder.lua STOP_ON='r3 builder summary' tools/autotest-run.sh r3-build '{... mode = "nation" ...}' 900` | **8/8**: platforms 80/40/80/40 tiles (11 and 5 carriages); 9 carriages refused at a 40-tile depot ("too-long"), accepted at 80; empty / wagon in front / reversed front refused, forwards-only flagged; loco + 3 cargo + loco at the 80-tile depot delivered 4,000 iron; loco + cargo + troop wagon + loco (kind cargo, caps cargo 1 troop 1) took 8 walkers aboard at C and carried 2,000 copper, the walkers got off at D; armoured loco + artillery + armoured troop wagon + armoured loco destroyed an enemy turret from a rail stop marked bombard with its stance "none"; 3 -> 4 -> 5 carriages, the 6th refused, 5 -> 4 -> 3 with one cargo wagon kit back; 5 templates, the 6th refused, one deleted, one replaced |
| Skirmish smoke | as above | 65/65, 0 errors |
| Owner's Age II save, 130 s | as above | 0 errors; train 46 keeps its two-stop list |
| GUI probe EN and RU (the same probe, steps composer to deploy) | as above | **10/10 in both**: the builder in the depot panel; the siege preset fills 4 carriages and names the missing kits; a palette click puts a cargo wagon in front of the rear locomotive; a reversed front locomotive is refused; a template "Probe" shows in the drop-down; the Freight preset deployed and the train panel coupled a fifth carriage. Screenshots `rts-r3-composer*.png`, `rts-r3-train-carriages.png`, `rts-r3-train-coupled.png` |

## 3. Player-built railways (#31 part A)

### 3.1 The rail planner finding (day 1)

Real-input GUI probe `tools/probes/r3_rails_planner_gui.lua` (gui-drive clicks and drags in the 1280x800 client):

| Input | Result |
|---|---|
| `cursor.give_ghost(player, "rail")` under the remote controller | the "rail" ghost sits in the cursor (HUD: "Placing Rail") |
| a single click | one straight rail ghost |
| click, move, click | two separate straight pieces: no planner path between them |
| a straight north-south drag | a row of 26 straight ghosts (drag-build); the CC's robots built 28 of them within 60 s |
| a diagonal drag | a staircase of disconnected straight pieces (19 ghosts no robot could finish) |
| a real `rail` item in the cursor stack | it vanishes at once in remote view; the RTS cursor comes back |

So on 2.1 the vanilla rail planner does not run under the RTS remote view: a rail cursor ghost behaves like any entity
ghost. The lead approved the fallback: a script-side Rail tool.

### 3.2 Design as built

- **Rail tool** (`scripts/railtool.lua`, the Economy tab's Rail button; Nation only, Railways researched): left click
  = waypoint (the first one: an own rail = branch, or free ground), every further click plans a segment with the line
  planner (`rails.plan_segment`: the fine A* over rail end states, curves and diagonals, bridges with Space Age; a click
  on an own rail joins it), its ghosts appear at once and the bill shows as flying text ("Track: 34 pieces, 52 rails,
  4 signals, 0 pieces of your track reused"); right click or Backspace undo the last segment (ghosts go, built pieces
  stay; the first undo returns to the start point); Q or Done end the tool. A small panel shows the state, Undo and
  Done. Left clicks reach the tool through `selection.area_hook`, right clicks through a first-place
  `orders.on_right_click` hook. A segment over another nation's land is refused with the territory message
  (`territory.can_build`, the rule of all infrastructure: own or neutral land).
- **Manual lines**: each segment is a `kind = "manual"` line in `rails.lines` (not listed with the auto lines). Robots
  of depot, hub and city networks in range build its ghosts; a construction crew comes from the nearest own depot that
  reaches the segment's start by track (`dispatch_manual`, one crew at a time per force on its own track) and lays it
  in order; for a branch the crew first parks `CREW_RUNOUT` (36) tiles behind the junction so it passes the junction
  heading into the branch. Segments continue each other: a segment's crew waits until the track before it stands.
- **Signals**: player track is single and runs both ways, so it is signalled with **chain signals only**: a pair every
  `signal_spacing` (80) tiles and a pair on every track that meets at a junction (a segment starting on or joining
  existing track, or an auto survey leaving own track), placed when the junction piece is built. A train then enters
  a stretch only when its path to its next stop is free: two trains never meet head-on. Why no rail signals: a rail
  signal frees the block behind it as soon as the train has passed, so on single track two trains heading towards
  each other can each enter the stretch between two junctions from its own end and stand nose to nose with no way out.
  The price of chain signals is one train at a time per stretch of single track; two-way traffic wants a second track
  (the player lays it with the Rail tool and may signal it with the rail signals from the build menu).
- **Junctions turn one way.** A branch that leaves eastward cannot be entered by a train heading west; the planner
  picks the cheaper side (it may run a few pieces along the clicked track first, at `REUSE_COST`). A wye needs a
  second segment from the main track onto the branch from the other side. Auto lines plan their own connecting
  curves where they leave or join own track, so they are not limited by it (fixture: the A - C line cut the corner
  with 5 new pieces to turn from segment 1 into segment 2).
- **Track nothing reaches** (`track_waits`): a segment without a crew and without a piece built by robots for 60 s
  raises "Track not built: no depot reaches it by rail and no robot network covers it" (or "... the nearest depot
  lacks rails, kits or coal"), once per reason. A segment started on free ground takes crews once other track ends
  where its first piece starts (`manual_anchor`). Ghosts of a segment mark the trees and rocks under them for
  deconstruction, as a player's ghosts do, so robots can build them (a crew clears them itself).
- **Auto lines reuse own track** (human forces: `rails.human`, a force with players): the survey's cells with own
  rails are cheap (`2 x REUSE_COST` per tile) for the coarse route, the corridor and the flow field (the coarse A*'s
  distance estimate is scaled by the same factor for these surveys so that it stays below the cost; the fixture's
  A - C line reused 9 % of its pieces without the cheap cells, 69 % with them and the plain estimate, which still
  headed straight for the goal, and 98 % now), and the fine
  search runs along own track at `REUSE_COST` (0.2) per tile instead of placing ghosts; reused pieces cost no rails and
  no crew time; where the route leaves own track, the new piece next to it marks a junction (chain signals when it is
  built). A player's survey also runs closer to the shortest route (`HUMAN_WEIGHT` 1.05 instead of 1.3) and pays
  `HUMAN_CURVE_COST` (4) per curved piece, so it prefers straight runs. The AI's surveys are unchanged (no reuse, the
  old weight and costs).
- **Depots with any number of lines** (human forces): `plan_line` no longer refuses "depot-busy"; the first line stays
  `depot.line`, further ones go into `depot.lines`, and a removed depot loses them all. The AI keeps one line per depot.
- **Station** (`rts-station`, a small hub: 2 stockpiles, logistic radius 10, 800 HP, 20 iron + 4 steel + 4 copper):
  its two `rts-depot-stop`s (one per direction, one name) go on the nearest own straight track within 8 tiles; without
  track it raises "Rail station: no track next to it yet" and looks again every second. It is a stop target like a
  depot (stop lists, policies, troops boarding), takes no deploys and no auto lines, and adds **no supply cap**
  (`supply.hub_discount`). Panel: stops on the track or the hint.
- **Signals in the build menu**: rail signal and chain signal (vanilla items, factory recipes `rts-rail-signal` and
  `rts-rail-chain-signal`, 5 iron + 1 circuit each) are single-click vanilla ghosts that robots build.
- **Crews and deploys on player track** (human forces only; found in fixture runs, where three crews of three lines
  met on the single track near depot A and each stood 120 s until the stuck rule sent it home): a force's crews go
  out **one at a time**, segments' and lines' alike (`dispatch_builder` waits with "crew-out", `dispatch_manual` as
  before); and a platform counts as busy while any train of the force has a path ending on it (`platform_free`:
  `path_end_stop` / `path_end_rail`), because a train spawned there would meet one that has the track to it reserved.
  The AI keeps its rules (one line per depot, a crew per line, rail signals).
- **Saves from before**: `rails.init` re-applies research for a force whose Railways unlocks lack the Station (the
  research module recomputes unlocks only when a technology finishes), so a 0.1.1 save gets the Station and the
  signals in its build menu.
- **Crews coming home** (human forces): a crew with no path back to its depot (a branch whose junction faces away
  from it) goes to the nearest own depot it can reach instead; a crew tops its locomotives up from the wagon on the
  way home as it does while building. Both only for players' crews.

### 3.3 Tests (part A)

| Test | Command | Result |
|---|---|---|
| Manual track fixture (`tools/probes/r3_rails_manual.lua`, beside a Nation 1v1 2048 match, seed 501, speed 6; lab surface, rts-ai-2 played as a human) | `SEED=501 SPEED=6 EXTRA_LUA=tools/probes/r3_rails_manual.lua STOP_ON='r3 manual summary' tools/autotest-run.sh r3-manual '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 2400` | **12/12** (with the single-track hint check `platform_held`, see 5.1), see 3.4 for the numbers: segment 1 (A to B, 280 pieces) built by a crew; the Station next to it took its 2 stops; segment 2 branched off segment 1 to C with 8 chain signals and no rail signal around its junction; segment 3 (Rail tool states: a click on a rail, then free ground) built with 6 chain signals at its junction; the auto lines A - C and A - B ran along the track (98 % and 100 % of their pieces reused, bills 17 and 0 rails); A - D left the track and was finished by a crew; depot A holds 3 lines; a segment into rts-ai-1's capital land failed "land-enemy"; a segment far from everything raised the "Track not built" alert after 61 s; two trains on stop lists shared the single track for 20 minutes (10 and 11 loops, stop order kept, longest stand at a signal 49 s). 0 Lua errors |
| Rail tool GUI probe, real client EN and RU (`tools/probes/r3_rails_tool_gui.lua`; the clicks go through the handlers the inputs call) | test copy + `tools/gui-run.sh <copy> 400 RTS_R3T_DONE` (RTS_LOCALE=ru) | **6/6 in both**: the Rail button opens the tool and its panel; three clicks plan two segments, the second with 4 curved or diagonal pieces (32 ghosts); a right click and Backspace take both back (0 ghosts); planned again, the CC's robots built 14 rails in 7 s; a click on a built rail, then one 36 tiles away plans a branch whose junction got 6 chain signals once robots built its first piece; Q closes the tool and the RTS cursor comes back. Screenshots `build/shots-r3rails-tool-en/`, `build/shots-r3rails-tool-ru/` (the panel fits in both languages; the last piece of the branch stayed a ghost, outside the CC's construction area, as a Skirmish map has no depot for a crew) |
| Rail planner finding (`tools/probes/r3_rails_planner_gui.lua`, real input) | see 3.1 | the vanilla planner does not run in the RTS view |
| Skirmish smoke | `tools/autotest-run.sh r3r-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65, 0 errors (the first run of the part A tree crashed at tick 900: the Rail tool's right-click hook asked `game.get_player(0)` for the autotest's script orders; fixed by `tool_player`) |
| Skirmish identity matrix (10 runs, seed 777) | `KEEP_TREE=<frozen tree> SEED=777 JOBS=2 tools/autotest-matrix.sh pa; tools/matrix-compare.sh base0111 pa` | **0 differing lines** in all 10 runs against base0111 (0 Lua errors; summaries as base: 1v3 stress 36/38, the rest all passed). Run on the tree before the last human-only changes (crews one at a time, platform busy while a train comes, crews' new home, Station unlock for old saves), which Skirmish never reaches (no rails outside Nation mode) |
| Owner's Age II save (copy, version bumped), 130 s | headless server | 0 errors, 804 `[rts]` lines; "rts-player has Railways from an older save: the Station and the signals unlocked"; train 46 became a two-stop list and ran stop 1 -> 2 -> 1 (37 coal loaded, 78 coal + 5 goods unloaded) |
| AI identity, M1 seed 501 | as in 1.4, 26026ae (main) vs the part A tree | **identical**: the first 57,243 `[rts]` lines (all of main's run, timings normalised) equal line for line; 50/53, train items 7,784 (rts-ai-1 in 34 trips) as on main. In headless runs no force has players, so `rails.human` is false for rts-player too and every human-only rule stays off |

### 3.4 Numbers (fixture, seed 501)

| What | Number |
|---|---|
| Segment 1, A (20, 7) to B (582, 7), 562 tiles | 280 pieces, bill 304 rails (12 signals), built by one crew in 189 s |
| Segment 2, from a rail of segment 1 at x 305 to C's platform end | 207 pieces (12 of them segment 1's track, run along before the branch), 231 rails, 193 s |
| Segment 3, free-point branch 110 tiles south | 58 pieces, 65 rails, 60 s (170 s while segment 2's crew, with no way back to A past segment 2's junction, stood 120 s until the stuck rule recalled it; now it goes to C) |
| Auto line A - C | 311 pieces, 306 reused, 17 rails (5 new pieces: a corner from segment 1 into segment 2, as segment 2's junction faces B) |
| Auto line A - B | 280 pieces, all reused, 0 rails, open in one check |
| Auto line A - D (leaves the track) | 237 pieces, 210 reused, built by crews with 92 rails; open 221 s after it was planned (576 s before crews went one at a time: three crews blocked each other on the single track) |
| Two trains, 20 min | train 1 (A -> B -> C -> B) 10 loops, delivered 8,000 copper, 2,000 iron and 1,000 stone; train 2 (A -> C) 11 loops; longest stand at a signal 49 s |
| Detour factor of a fresh survey | the AI's lines on M1 seed 501: 1.10, 0.98, 1.25, 1.15, 1.05, 1.09 (track length over straight distance, overall 1.09); a player's survey uses weight 1.05 and +4 per curve, so it is at most that |

## 4. Identity and the owner's save, all parts

| Part | Skirmish | AI (M1 seed 501, 60 min) | Owner's Age II save, 130 s |
|---|---|---|---|
| B (48372d4, 59263ab) | smoke 65/65 | identical to 43a8581 (51/53, train items 19,101) | 0 errors; train 46 became a two-stop list and ran |
| #32 (f113831) | smoke 65/65 | identical to main 26026ae (the first 57,243 `[rts]` lines, timings normalised; 50/53 there and here) | 0 errors; train 46 keeps its two-stop list |
| A | smoke 65/65; matrix 0 differing lines in 10 runs | identical to main 26026ae (57,243 lines) | 0 errors; Station and signals unlocked; train 46 runs its two-stop list |

Main itself moved from 0.1.1's M1 seed 501 numbers: 26026ae has train items 7,784 (rts-player 0 trips, rts-ai-1 7,784
in 34) against 0.1.1's 19,101; reported to the lead on day 1 as not this branch's (the #32 tree and main give the same
log line for line).

**Final, with main merged** (main 7b8b809 into r3-rails at 3fcf623): smoke 65/65, 0 errors; the owner's Age II save
130 s, 0 errors, 806 `[rts]` lines (Station and signals unlocked, train 46 on its two-stop list); manual track fixture
12/12.

**M3 end-to-end, seed 801** (4 normal AIs, 2048, 60 min; `PERF=1 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m3_acceptance.lua
DURATION_MIN=60 SEED=801 SPEED=8 tools/autotest-run.sh r3r-m3-801 '{opponents = 3, difficulty = "normal", mode =
"nation", world_size = 2048, enemy_brain = "ai"}' 12000`; the row computed with `tools/release-check.py`'s own
`acceptance` / `acc_table`), next to the 0.1.1 release check (`build/release-check/2026-10-25_1305/REPORT.md`, tree
615854f):

| Tree | AI autotest | Trade / war / peace / capture | Starving | Debt (stage) | Credit line | Lowest ₡ | First Age III | Cities ≥ 3 | Linked by 35:00 | Aggressive first line | Ops / belts / air patrols / interceptors+bombs / artillery / holds | Speed-1 minutes (s) | Errors |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.1.1 (615854f) | 80/83 (3 FAILED) | P/P/P/P | FAIL | none | none | 500 | 38:15 | 4 of 4 | 1 of 4 | ai-1 31:27 | 4/4 nations, 2 / 12 / 0 / 0 / 0 | 60.0 60.0 60.0 60.0 60.0 | 0 |
| r3-rails part A (aded01b's mod tree) | 81/83 (2 FAILED) | P/P/P/P | PASS | none | none | 1045 | 38:01 | 4 of 4 | 3 of 4 | ai-1 30:37 | 4/4 nations, 4 / 6 / 0 / 0 / 0 | 60.0 60.0 60.0 60.0 60.0 | 0 |

The two failed AI checks are rts-ai-1's (Age II at 32:56, no armoured car); the acceptance's "debt" (no nation in a
debt stage) and "lines" (first lines at 25:09 and 30:37) seed checks fail as they may per seed. The differences from
0.1.1 come from main's other 0.1.2 work (main already differs from 0.1.1 on M1 501, see above), not from this branch:
on M1 501 the part A tree and main 26026ae are line-identical, and no AI force is human in a headless run. Nations:
rts-player Age II 17:57, Age III 45:07, first line 25:09, 4 lines, 15,049 items by train; rts-ai-1 32:55 / 56:34 /
30:37 / 2 / 4,746; rts-ai-2 17:34 / 42:57 / 23:02 / 4 / 14,782; rts-ai-3 17:20 / 38:01 / 23:36 / 3 / 18,197.

## 5. Open items

1. **Single track and stub platforms.** Two trains that each want the other's platform wait for each other forever
   (each holds its own platform; chain signals keep them from meeting, not from this). The fixture's routes never
   swap ends at the same moment; a player with two or more trains between two depots needs a passing loop or a second
   track (both layable with the Rail tool). Accepted for 0.1.2 with a visible hint: a train on a stop list that has
   waited 60 s at a signal for a platform another train holds (`railroutes.step`: its `path_end_stop` is on a depot or
   station platform with another train's carriage on it) shows "Waiting for a platform held by another train: single
   track needs a passing loop or a second track (Rail tool)" as its panel's state line (EN/RU); the README rail
   section has the same sentence. Fixture check `platform_held`: train 2 kept on C's platform, train 1 bound for C
   carried the hint after 60 s.
2. **Junctions turn one way**, as in vanilla. Nothing tells the player when a stop on a train's list cannot be
   reached from the stop before it except the train's "no path" state; a check in the stop editor ("no track leads
   here from stop 2") would help.
3. A crew that cannot reach its frontier goes home after 120 s and the next one tries again every few minutes (as for
   the AI). Seen once (a line leaving a dead-end branch 4 tiles before its end; the fixture's diag hook dumps the
   track if it comes back), not reproduced after the coarse-estimate fix changed that route.
4. Two auto lines surveyed at the same time can plan new pieces over the same ground; the second one's crew then
   meets the first one's rails, the piece "will not revive", and the line takes a detour after two minutes (fixture:
   A - D around A - C's corner). Surveys could see each other's planned pieces as reserved. The crew sent home for
   that detour stood 127 s at (236, 7) with 37 coal in its locomotives, 50 in the wagon, a path to A and speed 0.05,
   until the stuck rule recalled it; the cause is not found (it stood where A - D's first new pieces meet A - C's
   corner).
5. A platform is busy while any train of the force has a path ending on it, so a busy depot (many trains on lists
   through it) may deploy rarely; the deploy line says "the platform is occupied or a train is on its way in".
6. The Rail tool has no "cancel the whole track" of its own: undo works while the tool is open, otherwise the ghosts
   go like other ghosts (r3-build's #27).

## 6. Proposed changelog lines (0.1.2)

Features:
- Trains run stop lists: right-click depots to add stops, each with its own orders (unload to Keep, everything or
  chosen items; load exports or chosen items; troops board or get off; bombard here) and the vanilla wait conditions;
  the list loops by itself. 0.1.1 trains keep their pickup and drop-off as a two-stop list. (#31)
- The train builder composes trains carriage by carriage from presets or up to 5 saved templates: mixed cargo, troop
  and artillery trains, armoured ones, longer trains on 60- or 80-tile platforms; a standing train couples or drops a
  carriage at its depot. (#32)
- The Rail tool lays your own track: click waypoints, curves and branches included, with a bill per segment and undo;
  robots and construction trains build it, chain signals keep trains on the single track from meeting head-on. (#31)
- Rail stations: small depots without a platform that put their stops on your track. Rail signals and chain signals
  are in the build menu. (#31)
- Auto lines run along your own track where it helps, and a depot takes any number of lines. (#31)

No fixes of 0.1.1 behaviour from this branch; the AI's trains and lines behave as before.
