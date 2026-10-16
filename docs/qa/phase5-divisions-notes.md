# Phase 5 M1: divisions and the order queue

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam, Space Age on). Mod: `mods/factorio-rts/`.
Contract: `docs/PHASE5-M1.md` section 3 "divisions.lua / orders.lua" and section 4 "Divisions". Study:
`docs/research/scale/war-ai-performance.md` sections 1–3 and phase W1. Package agent: `m1-divisions`. Working copy:
`build/p5-divisions/factorio-rts/`; probes under `build/p5-divisions/probe/`.

## Verdict: engine unit groups, no fallback

A division is one engine unit group (`LuaSurface.create_unit_group`). Spider-units join groups, march and fight in
them, and `force.ai_controllable` is not needed (Phase 1 spike #3 already said so; `docs/DESIGN.md` hard limit 3 is
out of date). The leader-follower fallback was built in the probe and measured. It was rejected: twice the per-tick
cost and no cohesion.

Probe: 4 forces × 12 divisions × 16 units (10 walkers, 3 heavies, 3 raiders unless noted), 1,024-tile lab arena with
four water bands and a 16-tile ford every 128 tiles, legs of 200 tiles, `--benchmark` 3,600 ticks (M3 Pro).

| Mode | Mean ms/tick | pathFinder mean | Worst tick | Speed (straight line) | Units > 25 tiles from their division |
|---|---|---|---|---|---|
| Unit groups, mixed | 1.55 | 0.04 | 21.2 (48 group orders in one tick) | 4.2 tiles/s (heavies set the pace) | 1–8 of 768 |
| Unit groups, walkers only | 1.53 | 0.03 | 18.8 (same burst) | 9.1 tiles/s | 2 of 768 |
| Groups, 4 group orders per tick | 1.56 | 0.04 | 6.5 | 4.2 tiles/s | 17 of 768 |
| Every unit ordered, 100 per tick | 1.27 | 0.09 | 10.4 | 9.4 tiles/s (first 80 % in) | 170–263 of 768 |
| Leader-follower (re-path every 60 ticks) | 3.17 | 1.93 | 15.5 | 11–12 tiles/s (the leader) | 486–575 of 768 |

Engine facts found by the probes (`build/p5-divisions/probe/mods/rts-div-probe/{combat,member}.lua`), which the code
relies on:

- A `unit` (drone) joins a group of spider-units. A unit added to a marching group catches up with it.
- A direct `set_command` on a member takes it out of its group. `add_member` moves a unit from another group.
- `group.destroy()` fires `on_ai_command_completed` (fail) for the group and leaves the members with `wander`.
- A group completes `go_to_location` with an event (success). After `attack_area` it only switches to state
  `finished`, without an event, so the controller polls the state.
- Members of a finished group keep the command `group`, stand still and fire back (an enemy placed next to them died).
- Deaths raise no `on_unit_removed_from_group`. A group whose members all died becomes invalid without an event.
- A group "arrives" when its expected position arrives, while slow members can trail 15–20 tiles behind (functional
  test). After a move the members therefore walk to formation slots and stop ("settling", below).
- Each long group path is a pathfinder job that runs for several ticks and costs about 5 ms per tick on a 400-tile leg.
  The cost adds up over the jobs running at once, so the queue limits group paths in flight, not only per tick.

## Files

| File | Status | What it does |
|---|---|---|
| `scripts/divisions.lua` | new | The division model, orders, controller, stances, reinforcement hook, order router, selection hooks, teardown |
| `scripts/divisiongui.lua` | new | Division panel: cards, Form division, stance buttons, reinforce, rename, disband, barracks drop-down |
| `locale/en/divisions.cfg`, `locale/ru/divisions.cfg` | new | `[rts-div]`, 30 keys, the same in both |
| `scripts/orders.lua` | shared, Phase 5 hunks | Path-request queue, division router, re-target throttle, faster formation maths |
| `scripts/selection.lua` | shared, Phase 5 hunks | Whole-division selection, control groups that remember divisions |
| `scripts/hud.lua` | shared, 1 hunk | `hud.on_refresh(fn)` hook list |
| `scripts/ai/army.lua` | shared, Phase 5 hunks | Attack and defence groups are divisions |
| `scripts/ai/autotest.lua` | shared, 1 hunk | The `divisions` check |
| `control.lua` | shared, 2 lines | Requires `divisions` (after orders) and `divisiongui` (after the HUD) |
| `tools/divisions-bench.sh` | new | Stress benchmark runner (`--create` + `--benchmark`), PASS/FAIL lines |
| `tools/probes/divisions_stress.lua` | new | Stress scenarios: march, 1,000-unit order, 1,000 units as divisions |
| `tools/probes/divisions_func.lua` | new | Headless functional test, 18 checks |
| `tools/probes/divisions_march.lua` | new | Divisions marching for `tools/saveload-check.sh` |
| `tools/probes/divisions_gui.lua` | new | GUI client probe with screenshots |

`production.lua` needed no change: reinforcement uses its existing `production.on_spawned` hook. `match.lua` needed no
change: `divisions.lua` registers through `match.on_teardown`.

### Shared hunks (line numbers in `mods/factorio-rts/` after the sync)

| File | Lines | Hunk |
|---|---|---|
| `scripts/orders.lua` | 13, 23–24, 42–54 | header: `retarget_tick`, `storage.orders.queue`, Phase 5 section |
| `scripts/orders.lua` | 71–73 | `RETARGET_MIN_TICKS` |
| `scripts/orders.lua` | 124–349 | queue (`orders.QUEUE`, `queue_command`, `cancel_queued`, `queue_stats`, `queue_reset_max`, pump on `on_tick`), router (`set_division_router`) |
| `scripts/orders.lua` | 361–375 | `resolve(who, kind, target)` calls the router |
| `scripts/orders.lua` | 377–391, 406–414 | prototype width cache; the formation reads each position once |
| `scripts/orders.lua` | 453–471 | `claim` / `release` clear `retarget_tick`, `release` cancels a queued command, `command` goes through the queue |
| `scripts/orders.lua` | 515–616 | `log_order` "divisions=N"; `move`, `attack`, `attack_move`, `stop`, `hold` count division units |
| `scripts/orders.lua` | 627–649 | `retarget` throttle |
| `scripts/orders.lua` | 932 | `orders.reset` drops the queue |
| `scripts/selection.lua` | 24–29, 355–441 | header; hooks, `expand_divisions`, `whole_divisions`, `division_joined` |
| `scripts/selection.lua` | 476, 536–545, 566–573, 663–673 | `reset`, `group_set`, `group_recall`, `handle_area` |
| `scripts/hud.lua` | 1761–1777 | `hud.refresh_hooks`, `hud.on_refresh`, called at the end of `hud.refresh` |
| `scripts/ai/army.lua` | 23–27, 31, 51, 131, 146–188, 371–378, 406–408 | header, require, `DIVISION_STATES`, `disband`, `form`, `division_of`, `outside`, `order_attack`, `send_home`, idle check, `describe` |
| `scripts/ai/autotest.lua` | 26–27, 43–44, 396–415 | header, requires, the `divisions` check |
| `control.lua` | 29–31, 44 | requires |

## Order queue (`orders.lua`)

`orders.queue_command(target, command, opts)` takes a unit (`LuaEntity` or its `LuaCommandable`) or a unit group.
Defaults in `orders.QUEUE`:

| Setting | Value | Why |
|---|---|---|
| `unit_budget` | 100 unit commands per tick | contract; 100 short unit paths cost at most 8–10 ms |
| `group_budget` | 4 group commands per tick | 48 group paths of 200 tiles in one tick cost a 19 ms pathFinder tick, 4 per tick 6.5 ms |
| `group_inflight` | 2 group paths in flight | 2048-tile map, 400-tile legs: 4 per tick → 21.3 ms, 4 in flight → 19.7 ms, 2 → 13.1 ms |

- A command is issued at once while nothing of its class waits and the tick's budget lasts, so orders to 100 units or
  fewer behave as before (legacy autotest 65/65 unchanged).
- Otherwise it waits in a FIFO (units and groups apart) and the `on_tick` pump issues it on a later tick.
- A unit or group has at most one queued command. A newer one replaces it in place. `release`, `hold` and division
  orders cancel it, so a Stop right after a 1,000-unit move is not undone by the backlog.
- A group whose path is still searched (state `pathfinding`, at most 300 ticks) holds an in-flight slot.
- QA line when a backlog drains:
  `orders queue: drained 900 queued commands in 10 ticks (1000 commands in the burst, max 100 unit + 0 group commands
  per tick, budgets 100 / 4, at most 2 group paths in flight, peak backlog 900)`.

Re-target throttle: a division re-targets at most once per second (`divisions.lua`: end of an attack-move, stance
advance). A loose attack-move unit searches for its next enemy at most once per second (`RETARGET_MIN_TICKS`); a
completion sooner keeps attacking the enemy it found last while that one lives. Path requests from completions are
capped by the queue anyway.

`orders.move` of 1,000 units costs 5.3 ms of script time in the order tick (formation, claims, 100 commands, 900
enqueued). Reading each position once and caching prototype widths took it down from 7.2 ms.

## Divisions (`divisions.lua`)

API as in the contract, plus helpers the GUI and the AI use:

```
divisions.create(force, units, template, opts) -> id      template = {name?, composition?, stance?}; opts.owner
divisions.get(id), divisions.for_force(force), divisions.of_unit(un), divisions.members(id), divisions.live_members(D)
divisions.add_units(id, units, why), divisions.remove_units(units), divisions.disband(id, why)
divisions.order(id, kind, target, opts)    -- move | attack_move | attack | retreat | hold | stop
divisions.set_stance(id, s), rename(id, text), set_reinforce(id, on), set_rally(id, pos)
divisions.set_barracks(barracks_un, id | nil), divisions.barracks_division(barracks_un)
divisions.strength(D) -> n, N, hp_ratio; divisions.is_idle(id); divisions.on_changed(fn); divisions.stats()
storage.divisions[id] = {force, units = {[unit_number] = true}, template, stance, group_id, group, rally, reinforce,
                         state, order, ...}      (full list in the file header)
storage.division_meta = {next_id, member, by_group, barracks, counter, stats}
```

- `units` is a set of unit numbers.
- Every order except hold and stop builds a new group of every live member at their centroid and sends one group
  command through the queue (`start_moving`, so nobody waits for gathering).
  - move and retreat: `go_to_location`, distraction none, radius 3 + √n.
  - attack_move and attack: `attack_area`, distraction `by_anything`, radius 10 + 1.5√n (max 24).
- While a division drives its members, their `storage.units` records carry `issuer = "divisions"`. The HUD shows the
  order: retreat shows as Move. Idle members are `idle`, so the units.lua idle rule applies.
- Arrival of a move or retreat: the members walk to `orders.formation` slots around the target and stop ("settling",
  at most 20 s). A heavy that trailed 17 tiles behind its group ends in formation.
- End of an attack-move: re-target the nearest enemy within 40 tiles (at most once per second), else idle where the
  fight ended.
- Controller every 15 ticks, each division every 60 ticks:
  - disband when empty;
  - a vanished group is ordered again after 5 s;
  - a finished group arrives;
  - members that dropped out of the group rejoin every 5 s;
  - idle members that lost their group are stopped;
  - stances act.
- Stances act only while idle:
  - hold: stand and fire back;
  - advance: attack-move an enemy within 40 tiles;
  - screen: fall back 20 tiles from an enemy within 25 tiles.
- Unit deaths update membership through `units.on_removed`; the last death disbands the division.
- Reinforcement: a barracks set to a division (`divisions.set_barracks`, the panel's drop-down) sends each new unit to
  it while the division accepts reinforcements and is below its template strength. A moving division takes the unit
  into its group; otherwise the unit walks to the division. A full division refuses; the unit goes to the rally point.
- Teardown (`match.on_teardown`): groups destroyed, `storage.divisions` and `division_meta` reset.

## UX

Selection rule (`selection.lua`):

- A plain click or drag that hits any member of a division selects the whole division.
- Shift + click or drag (alt_select, add) adds exactly the units hit. So a single member is picked by deselecting
  (click the ground) and Shift + clicking it.
- An order to every live member of a division is one division order. An order to only some members detaches them: they
  take the order as loose units and stay counted in the division. The next whole-division order takes them back.
- Control groups remember the divisions that were whole in the selection when Ctrl+N was pressed. A recall selects the
  divisions' current members, and a reinforcement joins the group (and a selection that holds the whole division).

Division panel (`divisiongui.lua`): a `screen` frame 300 GUI units wide at (8, 140), under the kill feed. In Nation
mode, while the city list (`rts_citygui_list`, m1-cities, at 8, 128) is open, the panel stacks under it.

- It is shown while the match runs and the force has divisions, 2+ combat units are selected, or an own barracks is
  selected.
- Header: "Divisions (N)" and Form division (enabled for 2+ combat units that are not exactly one whole division).
- Barracks row (while an own barracks is selected): Reinforces: [Rally point only | division names].
- Card: name button (click selects, Shift + click adds, right click jumps the camera), strength n/N, HP bar (green /
  amber / red), order line, stance.
- A division whose every member is selected also gets the detail rows: Hold / Advance / Screen buttons, the Reinforce
  checkbox, rename (pencil icon: a text field, Enter confirms, empty restores the default name) and disband (trash
  icon).
- Refresh: hud.lua's refresh hook (selection changes and every 30 ticks). The panel is rebuilt only when its
  signature changes.
- Screenshots: `build/shots-p5div-gui/rts-divgui-{1-selected,2-formed,3-moving,4-barracks}.png` (Russian client, 1280×800).

## AI (`ai/army.lua`)

`form()` creates a division (stance advance, owner ai) for groups in state attack or defend. `order_attack` and
`send_home` order it through `divisions.order`: attack_move, retreat, or move to the rally point. `disband()` disbands
it, and the 10-second re-target treats the group as idle when its division is. Guard, patrol and harass groups
(`ai/raids.lua`) stay loose units. Measured: `divisions` 0.002 ms/tick and `orders` 0.003 ms/tick in a 1v1 normal
medium AI match (PERF=1).

## Tests and numbers

All on the M3 Pro, with 5–10 Factorio servers of other agents running (load average about 6 of 12 cores). One
preempted tick was seen in an early run: 20.1 ms, of which 17.8 ms sat in `controlBehaviorUpdate` on a map with no
circuits. The runner prints such ticks apart from order ticks.

Stress (`tools/divisions-bench.sh`, final settings):

| Scenario | Mean ms/tick | p95 | Worst order tick | Commands per tick | Mass order drained |
|---|---|---|---|---|---|
| 4 × 12 × 16 march, 1,024-tile arena (half 512), 200-tile legs, 5,400 ticks, 2 mass orders | 1.71 | 2.06 | 7.8 | ≤ 2 group, ≤ 32 unit (settling) | 48 divisions in 47 ticks |
| Same on 2,048 tiles (half 1,024), 400-tile legs, 7,200 ticks | 1.66 | 1.96 | 13.1 | ≤ 2 group | 48 in 47 ticks |
| `orders.move` of 1,000 loose walkers | 2.11 | 2.65 | 14.4 (script 5.7, path 7.9) | 100 unit | 900 in 10 ticks |
| 1,008 walkers in 63 divisions, one order through the router | 2.09 | 2.50 | 12.1 | 2 group | 61 in 63 ticks |

Contract limits: mean ≤ 6 ms and no order tick > 20 ms (PASS in every row); an order to 1,000 units issues ≤ 100 path
requests per tick (PASS: 100). Rerun:

```sh
tools/divisions-bench.sh div-march '{mode = "march", forces = 4, divs = 12, half = 1024, leg = 400, start = 120, burst = 3600,
  comp = {{"rts-walker", 10}, {"rts-walker-heavy", 3}, {"rts-raider", 3}}}' 7200
tools/divisions-bench.sh div-mass '{mode = "mass", n = 1000, half = 512, start = 120}' 1800
tools/divisions-bench.sh div-massdiv '{mode = "mass_div", n = 1008, half = 512, start = 120}' 1800
MODULE=divisions_func tools/divisions-bench.sh div-func '{}' 9000 99 99
EXTRA_LUA=tools/probes/divisions_march.lua tools/saveload-check.sh div-saveload \
  '{opponents = 1, difficulty = "normal", size = "medium", enemy_brain = "ai"}' 150
```

Functional (`divisions_func`, headless): 18/18.

- Click selects the whole division (16); Shift + click selects 1.
- The control group remembers the division.
- A whole-division move is one group and arrives in formation (centroid 0.2 tiles from the target, every member idle).
- A partial order detaches 2 members; the next division order takes them back.
- Barracks reinforcement adds 2 units to the division and its control group; the 3rd is refused as full.
- An attack-move beats 6 enemy walkers and ends idle.
- Hold and stop work.
- Stance advance engages within 0.2 s; stance screen falls back within 0.1 s.
- Queue budgets hold.
- The division disbands when its last member dies, and the barracks link is cleared.

GUI client probe (`divisions_gui`): 9/9 checks pass.

- Form is offered, and a click creates the card with its detail rows.
- The Advance click toggles the stance.
- Rename works through the text field and Enter.
- A move order shows Moving, and a plain click on one member selects all 20.
- The barracks drop-down lists the division and choosing it sets the reinforcement.

Matrix and regression (Skirmish behaviour with AI armies in divisions):

| Run | Result |
|---|---|
| Legacy units (waves), Space Age / base only | 65/65, 65/65 |
| 1v1 normal medium | 22/22 (working copy and synced tree), rts-ai-1 launched 4 attacks |
| 1v3 normal small, seed 1111 | pristine tree 38/38, divisions 38/38 |
| 1v3 normal small, seed 2222 | pristine tree 38/39 (outcome FAIL), divisions 38/38 |
| 1v3 normal small, clock seed | divisions 38/39: outcome FAIL, three AIs lost their CCs and rts-ai-2 kept 4 units, so the match did not end |
| 1v1 normal small restart (RESTART_AT 240, speed 3) | 22/22; audit after the restart 94 LuaObjects, 0 invalid |
| Save/load, 1v1 normal medium + 2 marching divisions | 0 errors in both halves; the groups saved mid-march (#1031, #1037) went on after the load, arrivals 4 → 9 |

The 1v3 small "outcome" failure is the matrix's known flakiness, not a divisions regression: the pristine tree fails it
the same way on seed 2222 (`build/matrix-final2` had 37/39 there too).

## Open issues

1. **Long group paths on a slow PC.** A 400-tile group path costs about 5 ms per tick while it is searched. Two in
   flight keep the worst order tick at 13 ms on the M3 Pro, which can reach about 25 ms on a 2× slower PC.
   - Next: measure on the real 2048 world (m1-world).
   - If needed, lower `group_inflight` to 1 (a 48-division order would then take about 1.6 s), or cap
     `PathFinderMapSettings.max_work_done_per_tick` in Nation mode only.
2. **Cease-fire is not enough between marching armies.** In the stress scenario, units of cease-fire (not friend)
   forces that blocked each other at a crowded ford attacked each other as obstacles (3 deaths in 20 s); friends never
   did. This matters for M2 diplomacy, where a ceasefire should probably also set friend.
3. **Mixed divisions march at the slowest member's speed** (heavies 0.55 of a walker, so 4.2 tiles/s on the probe).
   This is the engine group behaviour and is intended; the card does not show the speed yet.
4. **Not in M1:** supply meter, formation shapes (line, column, wedge), division icons on the map, map-view and minimap
   orders, detach and rejoin buttons, division templates as data (the composition is captured when a division is
   formed).
5. **Retreat in the selection panel.** The HUD's selection panel shows a retreating division's units as "Move"; the
   division card says "Retreating".
6. **City list overlap in Nation mode.** The panel's position under the city list uses an estimated height (row count ×
   26). If m1-cities changes the list's frame name or top, `divisiongui.lua`'s `CITY_LIST*` constants must follow.
7. **The 2,048-tile numbers come from lab tiles with water bands,** not the generated world. Trees, cliffs and
   mountain passes will make paths more expensive.
