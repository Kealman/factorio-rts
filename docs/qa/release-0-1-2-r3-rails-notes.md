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
