# Phase 5 M3: scheduler, performance and determinism (m3-perf)

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m3-perf` (wave A). Contract:
`docs/PHASE5-M3.md` (D7 scheduler, D9, section 3 "sched.lua", section 4 "Perf / determinism"). Study:
`docs/research/scale/war-ai-performance.md` 1, 4.6, 5. Work copy: `build/p5m3-perf/factorio-rts` (base:
`build/p5m3-perf-orig/factorio-rts`, the `mods/` tree when the package started); sync: `build/p5m3-perf/sync.sh`.

## Summary

| D9 / section 4 criterion | Result |
|---|---|
| Budget scene (4 nations, 16 cities, 600 units, 40 trains) at 60 UPS, speed 1 | **60 UPS** (60.0 s per game minute, 4 minutes on a server; machine shared, load 10-12); per tick 1.80 ms mean, p99 6.5 ms, 2 ticks over 16.67 ms in 5 minutes (base tree: 33) |
| AI <= 0.5 ms/tick per nation (mean) | 0.08 per nation in the scene, 0.03-0.08 in a 20-minute 4-nation match (loaded figures) |
| AI <= 3 ms any tick | **not everywhere**: AI p99 per AI tick 6.8 ms loaded (~3 ms quiet), down from 28 ms; ticks with more than 3 ms of AI (quiet-equivalent) 770 -> 150 in 20 minutes. What remains is synchronous planning inside a slice (match start, forward hubs, towns, crowded district spots): open issue 1, for m3-ai's planners on the scheduler |
| M2 + M3 modules <= 1 ms together | 0.034 + 0.0004 ms/tick in the scene, 0.014 + 0.001 in the M1 acceptance |
| Two runs of the same seed log the same city sites, wars and treaties | **701 and 702: identical** (68 and 78 event lines, 30 minutes each) |
| Save and load mid-match change nothing | **identical** state checksums and every log line after the save (minutes 5-12 and 20-28; section 4.3) |
| Heavy mode 10 minutes / LAN with two GUI clients | **no desync**: heavy mode 10 min of wall clock at two moments (1,109 and 838 ticks compared); LAN: 0 desync lines, every client checksum equal to the server's; the second client joins mid-match by hand-over (one Steam account allows one player name at a time: section 4.4) |
| Skirmish byte-identical, smoke 65/65 | **0 differing lines in 6 scenarios; smoke 65/65** |
| M1 acceptance seed 501 | **53/53** (base 53/53 side by side), 60 UPS at speed 1 |
| `scripts/sched.lua` per the contract | done, work-conserving (tick cap 2,000); functional probe 18/18 (1v1) and 28/28 (4 nations), resumes across a save |
| Two heaviest synchronous computations as scheduler jobs | the rail survey (per-nation units; a 473-tile survey in 1.7 s, <= ~0.6 ms per tick); the AI layout A* made resumable (`layout.route_init/step`, job kind `layout_route`) and its callers' costs cut instead (section 2): converting the planners themselves needs them as state machines (open issue 1) |
| Chunk-bucketed reservations | done (`C.reserved`, `C.avoid`, `C.belt_tiles`) |

## 0. Measuring on a shared machine

Dev Mac: Apple M3 Pro, 12 cores (the study's machine). While this package ran, other agents' acceptance batches
kept 7-16 Factorio processes busy (load average 7-19 on 12 cores). Every timing here is wall clock and grows with that
load, the engine's own columns as much as the script's. Three rules keep the numbers comparable:

- **Quiet reference.** The first baseline benchmark (`pb-base701`) ran at a quiet moment: its mean entityUpdate,
  0.157-0.162 ms per tick for the same 20-minute match, is the reference. A run's **load factor** = its mean
  entityUpdate / 0.160 (the engine work is the same game in every paired run). Divide a loaded run's ms by its factor
  for an estimate of the quiet figure.
- **Paired runs.** Before and after are two benchmarks of the same seed started together (`pz-*`, final), so both see
  the same load; with the M3 hunks that do not change play turned on alone (`tools/probes/perf_noslice.lua`) the two
  runs play the identical game (section 2.1), so call-by-call comparisons are exact.
- **Benchmarks, not servers.** `tools/perf-bench.sh` runs `--benchmark --benchmark-verbose all`: the engine times every
  tick (whole, script, entity, path, trains), which a server cannot report (LuaProfiler values cannot be read as
  numbers); a server's wall clock per game minute (UPS) is reported where a server ran.

## 1. Baseline (before any change)

### 1.1 A 4-nation match at speed 1 (server, PERF=1)

`PERF=1 KEEP_TREE=build/p5m3-perf-orig/factorio-rts DURATION_MIN=20 SEED=701 tools/autotest-run.sh p5m3perf-base701
'{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1800`, read with
`tools/perf-log.sh build/p5m3perf-base701-server.log 17 21` (the last five game minutes):

| Module (ms per tick, mean of the last 5 minutes) | ms | worst minute |
|---|---|---|
| ai/init (the four AI commanders) | 0.269 | 0.335 |
| production | 0.047 | 0.055 |
| logistics | 0.037 | 0.045 |
| rails | 0.009 | 0.023 |
| mapgen | 0.007 | 0.008 |
| fog | 0.006 | 0.009 |
| labor, orders, territory, research, population, warsupply, districts, ... | <= 0.004 each | |
| **all modules** | **0.412** | 0.490 |
| AI (ai/*) | 0.273 (0.07 per nation) | 0.339 |
| M2 modules (population, labor, treasury, market, diplomacy, wars, warsupply, capture, garrison, strategic, world, targeting, panels) | 0.015 | 0.020 |

AI parts (ms per tick, all four nations): army 0.069, build_order 0.039, production 0.034, age_up 0.031, barracks
0.029, construction 0.022, governor 0.014, scout 0.008, nation 0.002, tech 0.001. UPS at speed 1: 60.0 in every
minute (59.8 in minutes 1 and 10, 59.9 in minute 20). The minute of the match start (minute 2 of the log) holds
1.36 ms/tick of "debug": the autotest starts the match there (world generation and the AI's start planning).

**The means are far inside D9** (AI 0.07 of 0.5 ms per nation, M2 0.015 of 0.5 ms). What breaks the budget is single
ticks, which a server cannot show.

### 1.2 The same match, every tick (benchmark)

`KEEP_TREE=build/p5m3-perf-orig/factorio-rts SEED=701 tools/perf-bench.sh match pb-base701 '<same table>' 20`
(quiet machine, load factor 1.0):

| Per tick, ms | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| wholeUpdate | 0.659 | 0.378 | 1.976 | 4.527 | 5173 (tick 120) |
| scriptUpdate | 0.262 | 0.015 | 1.342 | 4.006 | 5170 (tick 120) |
| entityUpdate | 0.157 | 0.170 | 0.226 | 0.263 | 6.0 |

52 ticks over 16.67 ms (dropped frames at 60 UPS), **1,355 ticks with more than 3 ms of script**. What ran in them
(`tools/probes/perf_marks.lua` times the planning functions and every commander run with its parts):

| Cause | Ticks / calls | Cost |
|---|---|---|
| The match start (tick 120): world.apply 2.95 s, world.plan 0.54 s, the four AI commanders' start planning (commander.start 4 x 400 ms, max 528: 57 layout.plan_line calls, 303 A* routes = 995 ms, plan_satellite 34 calls = 567 ms of candidate building and sorting) | 1 tick | 5.17 s |
| Two commanders running in the same tick: the stagger `(slot * 20) % 60` gives the 4th nation the 1st one's slot | 780 of the 1,351 ticks over 3 ms (all at tick % 60 = 10) | 2 x 1.9 ms |
| One commander run over 3 ms (mean run 1.87 ms, growing from 0.6 ms in minute 0 to 3.3 ms in minute 19: army 0.49, factories 0.40, build order 0.27, scout 0.22, barracks 0.21, age-up 0.13, construction 0.12, governor 0.11 mean per run) | 274 runs | up to 57 ms |
| layout.find_spot (age-up districts: up to 400 candidates, each tile-checked and then engine-checked; a district that does not fit is retried every minute) | 78 calls, 19 over 3 ms | mean 7.2, max 57 ms (growing with the base) |
| layout.plan_line mid-game (town line, forward hubs, the coal hub) | 10 calls | 10-25 ms |
| hubs.plan / towns.pick_site / hub_site | 6 / 4 / 13 calls | max 15 / 9 / 8 ms |
| fog's minute stats line (is_chunk_charted + is_chunk_visible over 4,096 chunks x 4 forces) | 1 tick a minute | ~15-20 ms |
| mapgen's depletion check (find_entities_filtered over every recorded patch, every 600 ticks) | 121 calls | mean ~2 ms, up to ~7 ms |
| rails.create_train | 38 ticks | up to 8.6 ms |
| the rail survey on its own driver (150 fine A* expansions per tick, one survey at a time) | 10-38 ticks per survey | median ~1.5, worst 8-20 ms per tick |

(`territory.attrition_pass` showed up in the first attribution only because it shares its 300-tick period with others:
it costs 0.04-0.68 ms.)

### 1.3 The budget scene: 4 nations, 16 cities, 600 units, 40 trains

`KEEP_TREE=build/p5m3-perf-orig/factorio-rts SEED=701 SCENE_AT=8 SCENE_SPEED=10 tools/perf-bench.sh scene pbs-orig 5`:
the scene of section 5 (16 cities of the 4 nations, 605 units of which 464 moving, 40 freight trains all moving), five
minutes benchmarked. The before/after comparison (section 2.3) benchmarks this very save with both trees at the same
time; on its own, at the time it was built:

| Per tick, ms | mean | p95 | p99 | max |
|---|---|---|---|---|
| wholeUpdate | 2.707 | 9.386 | 20.401 | 173.5 |
| scriptUpdate | 0.736 | 5.675 | 13.969 | 108.9 |
| entityUpdate | 1.315 | 2.689 | 6.394 | 162.3 |
| trains | 0.041 | 0.128 | 0.402 | 34.3 |

276 ticks over 16.67 ms; 1,204 script ticks over 3 ms, most of them a whole commander run (mean 7.4 ms with 150 units
per nation: every run over 3 ms) with army.step (mean 3.1, worst 87 ms) and build_order (hubs.plan 49 ms).

## 2. Changes, with before and after

Every change is marked `-- Phase 5 M3 perf` in its file. "Exact" means the same result for the same input: the
Skirmish matrix stays line-identical (2.1) and, with only the exact changes on, a Nation match too.

| # | Change | Where | Mode | Kind |
|---|---|---|---|---|
| 1 | The work-unit scheduler (section 3) | `scripts/sched.lua` (new), `control.lua` (require), `balance.lua` (`nation.ai3.budget = 400`), `events.lua` (`events.profiling()`) | Nation | new |
| 2 | **Rail survey on the scheduler**: each nation's survey spends its own work units per tick (`rails.SURVEY_UNITS`: a scored cell 25, a coarse expansion 4, a fine expansion 6 + 12 per new placement check, a corridor cell 3, a piece 2, a ghost 20) instead of the global per-tick counts; several nations survey at once; a step runs on through its phases until its units are spent (so it takes the scheduler's spare units). The 473-tile survey of seed 701 (148,822 units): **1.7 s of game time** (base driver 0.6 s; first scheduler version 7.0 s), at most ~2,000 units (~0.6 ms) per tick instead of 2-20 ms; the 278- and 313-tile surveys 0.2 s (base 0.2 s) | `scripts/rails.lua` | Nation (the rails autotest outside a match keeps the old driver) | conversion 1 |
| 3 | **Sliced AI runs**: a commander's run (every 60 ticks) is three slices 5 ticks apart (1 economy and planning, 2 research, age-up, barracks, factories, 3 governor, strategist, army, scouting), driven every tick in Nation mode; start offsets {0, 30, 15, 45, 7, 37} by creation order put every slice of up to six nations on a tick of its own (the Phase 4 stagger gave the 4th nation the 1st one's tick). A save from before M3 is re-staggered once | `scripts/ai/init.lua`, `scripts/ai/commander.lua` | Nation | timing |
| 4 | **The A* router resumable** (`layout.route_init` / `layout.route_step`: heap arrays and maps of numbers, no per-state tables, the box clipped to the arena once) and exposed as the scheduler kind `layout_route` | `scripts/ai/layout.lua` | both | exact; conversion 2 (the primitive) |
| 5 | **Pocket test**: a route still open after 3,000 expansions first flood-fills (at most 1,500 tiles) around its goal and its start; a closed pocket proves there is no route, so the full failing search (up to 60,000 states) is skipped | `scripts/ai/layout.lua` | Nation (the "tiles expanded" count in a failure log line differs) | same result |
| 6 | plan_satellite: its 1,800 candidates are ordered by buckets of their distance instead of being built (with slot tables) and sorted every call | `scripts/ai/layout.lua` | both | exact |
| 7 | find_spot / find_spot_in / hub_site: a summed-area table of reserved, avoided and off-arena tiles (after 24 candidates), an area scan of blocking entities and ore that skips candidates the engine counts would reject (after 6 engine rejections), the static candidate lists cached per prototype and anchor, the powered-district pole test on a pole grid instead of every pole for every margin tile | `scripts/ai/layout.lua` | both | exact |
| 8 | **Chunk-bucketed tile sets**: C.reserved, C.avoid, C.belt_tiles are `{[chunk key] = {[tile key] = value}}` behind `layout.tget/tset/...`; plan_line undoes a failed attempt from a journal of its writes instead of copying all of C.reserved first; snapshots copy buckets | `scripts/ai/layout.lua`, `hubs.lua`, `towns.lua`, `commander.lua`, `init.lua` (migration) | both | exact |
| 9 | free(): the arena test with the context's arena half (was a storage read per call) | `scripts/ai/layout.lua` | both | exact |
| 10 | army.step: the defence and home-guard sorts read each unit's position once (decorated sort) instead of twice per comparison | `scripts/ai/army.lua` | both | exact |
| 11 | fog's minute stats line swept over 512 chunks per tick | `scripts/fog.lua` | Nation | same line, ~1 s later |
| 12 | mapgen's depletion recount in 10 slices (one every 60 ticks) | `scripts/mapgen.lua` | Nation | each patch still every 600 ticks |
| 13 | Determinism: AI sight without chart state (`scout.sees`), the HUD kill feed and enemy count by sight instead of `is_chunk_visible` (section 4) | `scripts/ai/scout.lua`, `scripts/hud.lua`, `scripts/match.lua` | both (headless results unchanged) | determinism |
| 14 | Test facilities: `events.trace_nth(period)` (logs every on_nth_tick handler call's time; only `tools/probes/perf_marks.lua` turns it on) | `scripts/events.lua` | tests | - |
| 15 | The AI autotest keeps its force list in `storage.ai_autotest.forces` (it was a module variable: after a load only 2 of 4 nations were tested and reported) | `scripts/ai/autotest.lua` | tests | determinism |
| 16 | The treaty-cede hook of capture.lua is registered in `on_init`/`on_load` as well (it waited for the first 60-tick step after a load) | `scripts/capture.lua` | Nation | determinism |

### 2.1 Exactness and acceptances

- **Skirmish byte-identity.** `KEEP_TREE=<base> TREE_B=<M3> WHAT=all PARALLEL=1 tools/determinism-compare.sh` compares
  every `[rts]` line (timing lines dropped) of the same Skirmish match on both trees: the final tree against the base, six scenarios (legacy units seed 9090, 6 min; 1v1 normal medium, 1v3 normal small,
  1v2 normal medium, 1v1 hard medium, 1v1 easy medium, seed 777, 9 min each): **0 differing lines** (566 / 3,900 /
  4,677 / 5,257 / 4,490 / 1,138 lines), autotest summaries identical (65/65, 23/23, -, 31/31, 20/23, -: the hard
  scenario's 3 failures and the two unfinished summaries are the base's too).
- **Nation exactness of the exact changes.** The M3 tree with `tools/probes/perf_noslice.lua` (unsliced AI, the M2 survey
  driver) against the base, 4 nations, seed 701, 20 minutes: 20,271 `[rts]` lines each, the only differences are the
  fog stats lines, logged a second later by the sweep (`t=63s` -> `t=64s`, 19 lines x 2). The AI's start planning
  reserves the same 519 / 564 / 594 / 599 tiles. Per call on the identical game (paired, load factor 2-3):
  plan_satellite x0.23, plan_line x0.67, commander.start x0.66, context_at x0.60, find_spot x0.85 (before the pole grid).
- **M1 acceptance**, 60-minute 1v1 Nation, seed 501 (`EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN=60 SEED=501
  SPEED=6`), base and M3 run side by side: **53/53 both**; UPS at speed 1 in the last five minutes 60.0 / 60.0 / 60.0 /
  60.0 / 59.9 (both); all modules 0.61 -> 0.55 ms/tick, AI 0.148 -> 0.129 (two nations), M2 0.011 -> 0.014, M3
  (sched) 0.001; first rail lines open at 19:53 / 23:10 (base) and 20:35 / 26:20 (M3), 26,612 / 24,048 items by train
  (goal 20,000). (An earlier, intermediate M3 copy failed `produce_rts-player` once, 52/53: the player AI's barracks
  idled 16 minutes at the end of that particular game; the final tree passes.)
- **Skirmish smoke** (`tools/autotest-run.sh smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain =
  "waves"}' 240`): **65/65**, 0 errors (final tree, seed 9090).

### 2.2 Per tick, the 4-nation match (paired benchmarks, seed 701, 20 minutes, load factor 2.2)

`tools/perf-bench.sh match pz-a701 / pz-b701 '<4-nation table>' 20`, base and M3 started together (load factor 2.26 /
2.23: the engine's own entityUpdate ran 2.2x its quiet time on both, so divide by ~2.2 for quiet-machine figures).

| Per tick | Base | M3 |
|---|---|---|
| script mean (ms) | 0.432 | 0.495 |
| script p95 / p99 (ms) | 2.48 / 8.77 | 2.42 / **5.20** |
| script worst after the match start (ms) | 188 | **112** |
| match-start tick (t120) script (ms) | 6,433 | 5,270 |
| script ticks over 3 / 6 / 10 ms | 3,145 / 1,427 / 544 | 2,317 / **543** / **162** |
| ticks over 16.67 ms (whole) | 355 | **218** |
| AI (all commander work) ms/tick, 4 nations | 0.270 | 0.303 (0.076 per nation; ~0.035 quiet) |
| AI per tick that runs AI: p50 / p95 / p99 / max (ms) | 3.73 / 13.5 / 28.0 / 188 | **1.08 / 3.55 / 6.84 / 58.7** |
| ticks with more than 3 ms of AI on a quiet machine (> 3 x load factor) | 770 | **150** |

Per call (same functions, different games because the slicing changes the AI's timing):

| Function | Base mean / p99 / max (ms) | M3 mean / p99 / max (ms) |
|---|---|---|
| commander.start (4 calls, match start) | 703 / 964 / 964 | 422 / 629 / 629 |
| layout.plan_line (67) | 42.1 / 294 / 294 | 24.9 / 169 / 169 |
| layout.plan_satellite (34) | 28.8 / 73.6 / 73.6 | 7.0 / 60.6 / 60.6 |
| layout.find_spot (78-79) | 16.4 / 181 / 181 | **5.6 / 55.8 / 55.8** |
| layout.hub_site (13) / hubs.plan (6) | 9.5 / 24 / 24 ; 20.8 / 45 / 45 | 9.1 / 20 / 20 ; 20.5 / 31 / 31 |
| army.step (4,804) | 1.02 / 4.60 / 44.2 | 0.88 / 3.46 / 20.9 |

The mean script time is a little higher (+0.06 ms/tick, the per-tick Nation driver and the scheduler's survey being
spread over more ticks); every tail figure is lower, the AI's p99 by 4x. What still exceeds 3 ms in single ticks is
planning (open issue 1).

### 2.3 The budget scene

The scene save of 1.3 (built by the base tree: 605 units, 40 trains, 16 cities) benchmarked for five minutes by the base
copy and the M3 copy at the same time (load factor equal: entityUpdate mean 0.932 / 0.927 ms). The M3 copy loads a
save from before M3: its tile tables are converted on the first run and its commanders re-staggered once.

| Per tick | Base | M3 |
|---|---|---|
| whole mean / p95 / p99 / max (ms) | 1.846 / 6.549 / 12.632 / 52.0 | 1.796 / **3.530 / 6.455 / 27.9** |
| script mean / p95 / p99 / max (ms) | 0.570 / 5.134 / 11.030 / 50.4 | 0.525 / **2.098 / 4.887 / 20.1** |
| ticks over 16.67 ms (whole) | 33 | **2** |
| script ticks over 3 ms | 1,181 | **401** |
| UPS capacity at the mean tick | 542 | 557 |
| AI (ai/*) ms/tick, 4 nations | 0.395 | 0.336 (0.084 per nation) |
| M2 modules / M3 modules ms/tick | 0.034 / - | 0.034 / 0.0004 |

What fills the 401 slower ticks of the M3 run: logistics' 60-tick network work (139 ticks, worst 8.8 ms; the scene's 80
depots), strategic's division labels (86, worst 9.6 ms), find_spot_in (27, 10.4 ms), treasury's census (25, 9.2 ms),
army.step (38, 4.2 ms).

**Realtime.** The M3 tree's own scene (`tools/perf-bench.sh scene pbs-final 5`: 606 units of which 460 moving, 40 trains,
16 cities, then 17 when an AI founded one) played on a headless server at speed 1 (`tools/perf-bench.sh realtime
pbs-final build/pbs-final-out/scene.zip 5`): **60.0 s of wall clock per game minute in every minute (60,003 / 60,007 /
59,991 / 60,000 ms): 60 UPS**, all modules 0.64 ms/tick, AI 0.41 (four nations), M2 0.042, M3 0.0008, with the machine
at load average 10-12 from other agents' runs. (The trains spend about two thirds of each 64 s round trip loading and
unloading at the platforms, so a census tick can catch none of them moving.)

## 3. The scheduler (`scripts/sched.lua`)

The work-unit scheduler of D7: long computations are resumable jobs whose whole state is plain data in
`storage.sched.jobs[id]`; one `on_tick` loop gives every nation a budget of work units per tick. Factorio's Lua has no
coroutines and `storage` cannot hold closures, so a job is a state machine and its step function is looked up by kind
(registered at load, identical on every peer). The file header is the reference (API, rules, an example job).

```
sched.register(kind, step_fn [, finish_fn])     -- file level, once per kind
  step_fn(job, units) -> used, done             -- job.state is the caller's; spend at most ~units deterministic units
  finish_fn(job, status)                        -- once: "done" | "cancelled" | "failed" (a step raised: logged, dropped)
sched.submit(force, kind, state, priority) -> job_id | nil, "not-nation" | "unknown-kind"
sched.cancel(job_id) -> bool;  sched.status(job_id);  sched.get(job_id) -> job (also sched.RETAIN ticks after it ended)
sched.run_sync(kind, state, force) -> job       -- the same step function to the end now (Skirmish path, tests)
sched.budget(force) -> units per tick           -- balance.nation.ai3.budget (400) x ai3.difficulty[level].budget_factor
sched.stats() -> {[force] = {jobs, units_last_minute, ms_last_minute = LuaProfiler (PERF=1 only) | nil}}
sched.enabled() -> true while a Nation match runs (Skirmish never schedules: submit refuses)
```

Rules as implemented:

- **Budgets.** Every nation with live jobs gets its whole budget every tick; the nations are served round-robin by
  index (the first one served moves on by one each tick). A nation's jobs run by priority (higher first:
  `sched.URGENT` 100, `NORMAL` 50, `BACKGROUND` 10), then by id. A step that spends fewer units than offered and is not
  done *yields*: the next job of the nation gets the rest (a job that waits for something returns `0, false`). Unused
  units are not carried over; an overrun is (the nation's next ticks are skipped until the debt is paid), so the mean
  stays honest when one step is indivisible.
- **Work-conserving** (lead request after review): once every nation had its budget, what `sched.tick_cap()`
  (`balance.nation.ai3.tick_cap`, 2,000 units) leaves goes to the nations whose job spent all it was offered and is not
  done, in the same order, shared equally; a nation in debt gets none. A lone job (a rail survey while no planner runs)
  so moves at up to 2,000 units per tick (about 0.6 ms); four busy nations stay at their 4 x 400.
- **Units, never wall clock.** A unit is about 1 microsecond of script time on the dev Mac (section 3.2). A step counts
  what it did: states expanded, cells scored, entities examined.
- **State.** Everything a job needs is in `job.state` (arrays and maps of numbers and strings, LuaObjects are allowed);
  a save in the middle of a job resumes it after the load (tested, section 3.1). The owner of a result is named in the
  state (a force, a line id), never a closure; `finish_fn` hands the result over.
- **Teardown.** A match teardown cancels every job (`finish_fn(job, "cancelled")`) and clears `storage.sched`.
- **Log.** Once a minute, per nation with activity: `[rts] sched: minute N <force>: L live, E ended, U units (u per
  tick, budget B) | kinds: <kind> <units> (<n> ended), ...`; with PERF=1 also `[rts] sched: minute N time <force>
  <profiler> | <kind> <profiler> ...` (measured script time per nation and kind: the unit calibration).

Kinds registered now: `rails_survey` (scripts/rails.lua, section 2), `layout_route` (scripts/ai/layout.lua: the belt
router as a job, `layout.submit_route(force, {sx, sy, sdir, gx, gy, max, blocked = {[tile key] = true}, ore})`, the
blocked tiles as a set so no closure crosses a tick; the result is `sched.get(id).state.R.path`).

For the planners of `m3-ai`: a resumable search keeps its open set as heap arrays (`layout.route_init` /
`layout.route_step` show the pattern: `R.f`, `R.q`, `R.s` heap arrays, `R.g` and `R.parent` maps keyed by state
numbers), checks `sched.enabled()` and keeps a synchronous path for Skirmish (`sched.run_sync` runs the same step
function to the end, or call the step with `math.huge`).

### 3.1 Tests

`tools/probes/perf_sched.lua` on a 1v1 Nation match (seed 501), five seconds after the start, for every force:

```sh
EXTRA_LUA=tools/probes/perf_sched.lua STOP_ON="perf sched summary" KEEP_TREE=build/p5m3-perf/factorio-rts SEED=501 \
  tools/autotest-run.sh ps-2 '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 400
EXTRA_LUA=tools/probes/perf_sched.lua SAVE_MINUTE=1 KEEP_TREE=build/p5m3-perf/factorio-rts SEED=501 \
  tools/saveload-check.sh ps-sl '<same table>' 90
```

**18/18** (28/28 on 4 nations): an URGENT count of 1,000 units ends before a NORMAL one of 4,000 submitted earlier
(with spare units given out, the 5,000 units end within 4 ticks; at the bare budget of 400 they would take 13); results and statuses; a cancelled job never ran and its finish callback
saw "cancelled"; no force spent more than the tick cap in a tick and all forces together never more than max(cap, sum
of budgets) (worst 2,000), with spare units handed out (tick_cap check); a step that overruns 3x is called every
third tick (debt); a job that yields hands its units to the next job (114 yielding calls while the others ran); a step
that raises ends "failed" with an "[rts] sched: Error ..." line (on purpose, the only error in the log); `run_sync` runs
5,000 units in one call and stores nothing; `stats()` after a minute; a `layout_route` job returns the same 37-tile
path as the synchronous `layout.route` on the same maze (1,870 units, 6 steps). **Across a save and load:** the long
jobs (sized for about 90 s; 2,160,000 units at the bare budget in that run) were in flight when the server quit at
minute 1 and saved; the loaded game finished them at tick 5,833 / 5,842 with exactly 2,160,000 units in 5,401 steps,
0 errors after the load.
In Skirmish `sched.submit` refuses ("not-nation"); every Skirmish run of 2.1 logs no `sched:` line.

### 3.2 Unit calibration

A unit is meant to be about 1 microsecond. The minute lines with PERF=1 give units and measured time per kind; the only
kind with work in the 20-minute 4-nation runs is `rails_survey`: 147,802 units in 91 ms (load factor 2.0), 22,917
units in 35 ms (load factor 2.1), and on a quieter machine 148,822 units in 43 ms and 27,072 in 10 ms, i.e. about
0.3-0.8 microseconds per unit. The budget of 400 units
is therefore at most ~0.3 ms per nation per tick, the safe side of D9's 0.5 ms. The scoring of coarse cells is the
heaviest per unit (five area counts); `rails.SURVEY_UNITS.cell` may go up from 25 once a quiet machine confirms it.

## 4. Determinism

### 4.1 Audit (scripts/, scripts/ai/)

| Rule (war-ai-performance.md 5) | Finding | Action |
|---|---|---|
| `pairs` order never decides what a reload rebuilds | Factorio's `next` iterates in insertion order (`doc-html/auxiliary/libraries.html`, "pairs() / next()": "Factorio's iteration order when using next() (which pairs() uses for iteration) depends on the insertion order: Keys inserted first are iterated first", the first 1,024 integer keys in key order), and a save keeps that order, so a `storage` table iterates the same on every peer and after a load. The risk is a table that is *rebuilt* (module-local state filled again after a load or on a joining client). The file-level runtime tables are static prototype data (`districts.makers_cache`, `production.machine_recipes`, `orders.width_cache`, `hud.counters_cache`, `layout.spot_cands`) or per-tick memos (`diplomacy` engine memo, `hud.supply_cache`); none decides across ticks. | none needed |
| No closures, coroutines, `math.random`, `os` | none in `scripts/` (the metatables in `match.lua` and `production.lua` are module-level helpers, not in `storage`) | none |
| `storage` read-only in `on_load` | the only handler (`rails.bind`) reads `storage.rails.lines` into a module field | none |
| Registration at load only | every `events.on*` call runs while control.lua loads; the new handlers (sched, `ai.nation_tick`, fog sweep, mapgen slices, `events.trace_nth`) too | none |
| LuaProfiler never decides | profilers only reach `log()` (world, territory, strategic, ai/init, ai/autotest, commander, hubs, match, rails, mapgen, sched; `events.profiling()` only tells sched whether to create its log profilers) | none |
| **No chart state in decisions** | **`ai/scout.lua` `scout.sees` returned true when `force.is_chunk_visible` held**: false everywhere on a headless server (it charts nothing), true on a GUI peer for a charted force (rts-player, which the autotest's AI commands in the LAN check, and any AI allied with a human, whose chart it shares) - an AI decision that differs between the server and a client is a desync. `hud.lua` kill feed: `seen[force]` from `is_chunk_visible` went into `storage.hud.kills` and the kill-feed GUI; `match.enemy_units_seen` (HUD enemy count) from `is_chunk_visible` | sight only in `scout.sees`; the kill feed's `seen` = an own entity within 40 tiles; the enemy count = enemy units in chunks next to an own entity. Headless runs never had a chart, so their results are unchanged (2.1) |
| Per-player client state | `display_resolution` / `display_scale` only place GUIs (synchronised player properties with their own events) | none |
| Hooks registered at run time | **`capture.lua` registered its treaty-cede hook (`wars.on_cede`) at its first 60-tick step after a load** (wars.lua loads later): a city ceded by treaty in the first ticks after a client joined flipped on the server only (found by the read-only audit subagent) | registered in `on_init` and `on_load` too (both run after every module loaded) |
| Test harness state | `ai/autotest.lua` kept its force list in a module variable (2 of 4 nations tested after a load) | `storage.ai_autotest.forces` |

**LAN-critical (each one would desync a client from the server or from a reloaded game):** `ai/scout.lua` `scout.sees`
(AI sight from `is_chunk_visible`), the HUD kill feed (`hud.lua`, `seen` from `is_chunk_visible` into `storage.hud.kills`
and the GUI), `match.enemy_units_seen` (HUD enemy count from `is_chunk_visible`), the AI autotest's force list
(`ai/autotest.lua`, module state that a load reset) and capture.lua's treaty-cede hook (registered only at the first
60-tick step after a load). All five are fixed in this package; any new code must keep chart state, module-local
runtime state and run-time hook registration out of decisions.

A read-only audit of every `pairs`/`next` site (about 1,970, by a subagent with nine sub-audits) sorted the loops whose
order decides something into tables only built by the same code on every peer (class B: about 40 sites, e.g. shared
resources handed out in `pairs` order in production.lua:610, research.lua:636, economy.lua:81; ties under a strict `<`
in scout, army, logistics, market) and tables whose keys are deleted and re-added, where only a save that does not
keep insertion order would diverge (class C: `ai/init.lua` `pairs(storage.ai)` when two commanders share a tick,
`population.lua:229` loose-building resolution under a 200 budget, `selection.lua:549`, `ai/governor.lua:462`,
`ai/construction.lua:299`, and `logistics.lua:1503` inserting while it iterates at init). The docs promise insertion
order but say nothing about saves; the save/load equivalence runs below (12,400 lines after a load identical to the
continuous game) and the LAN client's checksums show the order surviving a save in practice. Sorting those loops would
change Skirmish results (the Skirmish 1v3 runs two commanders on one tick in creation order, not name order), so they
are listed for the owners instead (open issue 9).

### 4.2 Two runs of the same seed

`PARALLEL=1 WHAT=events KEEP_TREE=build/p5m3-perf/factorio-rts tools/determinism-compare.sh det-<seed> '{opponents = 3,
difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 30 <seed>` (two fresh saves of the seed,
30 minutes each, the M3 tree with every change):

| Seed | Event lines per run | Differing | What happened (identical in both runs) |
|---|---|---|---|
| 701 | 68 (cities 20, wars 8, rails 9, other 31) | 0 (the 2 lines the first comparison flagged were a world-planning line with its timings; timings are now normalised) | 4 ports taken at ticks 9,600 / 9,930 / 11,100 / 16,890; second cities of all four nations at the same sites; war rts-ai-1 / rts-ai-2 at 1,250 s, cease-fire, peace by treaty at 1,748 s (white peace after 8.3 min) |
| 702 | 78 (cities 28, wars 5, rails 14, other 31) | 0 | 4 ports; war rts-ai-1 / rts-ai-2 at 1,250 s, city 14 captured by rts-ai-1, peace by a cession treaty at 1,338 s; rts-ai-1 declares war on rts-player at 1,730 s |

### 4.3 Save and load in the middle of a match (headless equivalence)

`SAVELOAD=1 SAVE_MIN=5 END_MIN=12 tools/heavy-mode.sh sl2-701` (M3 tree, 4 nations, seed 701): run A plays on a server
at speed 8 and saves at tick 18,000 (`game.server_save`, `tools/probes/perf_lan.lua`); run B is a benchmark of that save
to tick 43,200. **PASS: all 42 state checksums equal, and all 6,236 `[rts]` lines after the save are identical, in the
same order** (AI decisions of the sliced runs included). The first attempt found one difference, in the test harness:
`ai/autotest.lua` kept its force list in a module variable, so after a load the AI autotest reported 2 of 4 nations;
it now keeps the list in `storage.ai_autotest.forces` and restores the module variable in `on_load` (marked
`-- Phase 5 M3 perf`). A second window, saved at tick 72,600
(match minute 20) and compared to tick 100,800 (`SAVE_MIN=20 END_MIN=28`), covers a war declared after the load and
two rail surveys on the scheduler: **47 checksums and 12,429 lines identical**. The only extra line in the loaded run is
`rails: geometry read: 32 end states ...`: rails.lua re-reads its module-local rail geometry (read-only, documented in
its header) on the first survey after a load; the comparator ignores that line. Two harness lessons: a
`game.server_save` on the tick of a server autosave (every 10 game minutes in `tools/server-settings.json`) is dropped
silently (`heavy-mode.sh` moves such a save tick by 600), and `game.server_save` needs the write-data `saves/`
directory to exist (the scripts create it).

### 4.4 Heavy mode and the LAN session

Run with GUI clients after the Codex GUI QA ended (one window at a time, closed after each run).

**LAN** (`tools/lan-check.sh`, M3 tree, 4-nation normal match, `perf_lan.lua` checksums every 10 s on every peer):

| Run | Seed | Clients | Desync lines (server / clients) | Checksum lines equal to the server's | Lua errors |
|---|---|---|---|---|---|
| `lan-1` | 701 | client 1 from tick 1,611 for 13 minutes; client 2 refused (see below) | 0 / 0 | 76 of 76 | 0 |
| `lan-2` | 702 | client 1 from tick 1,555 to minute 5.5; client 2 joined the running match at tick 22,655 and played 4 minutes | 0 / 0 / 0 | 33 of 33, 25 of 25 | 0 |

Two clients at once are not possible on this Mac: both run under its one Steam account, whose player name comes from
Steam Cloud's player-data.json (empty here; a local player-data.json in the client's write-data is reported
"unavailable" and not read), so the server refuses the second ("UserWithThatNameAlreadyInGame"). The script then hands
over: client 1 quits and a fresh client 2 joins mid-match, which is the join path the check is about (map download, load,
sync while the AI keeps playing). A concurrent second client needs a second account or machine.

**Heavy mode** (`tools/heavy-mode.sh`, GUI client with `--heavy`: save, load and compare every tick):

| Run | Start | Ticks checked in 10 minutes of wall clock | Result |
|---|---|---|---|
| `heavy-1` | a fresh 4-nation match saved 60 s after its start (tick 3,756) | 1,109 (ticks 3,756-4,864) | no mismatch, no desync report, 0 errors |
| `heavy-2` | the minute-20 save of section 4.3 (tick 72,600: war, rail surveys on the scheduler, sliced AI) | 838 (ticks 72,601-73,438) | no mismatch, no desync report, no Lua error (the client logged "Failed to load player data" at start: its Steam Cloud profile, not the game) |

Heavy mode takes about 0.54 s per tick on a 2048 world, so "10 minutes of a match" means about 5.4 hours of wall
clock; the runs here cover 10 minutes of wall clock each, at two moments of the match. The headless save/load
equivalence of 4.3 covers whole minutes (7 and 8 game minutes) of the same property, one save/load each.

## 5. Tools

| Tool | What |
|---|---|
| `tools/perf-bench.sh match <name> '<match>' <min>` | a match from a fresh `--create` (SEED, default 701) under `--benchmark --benchmark-verbose all`: per-tick mean/p50/p95/p99/max of wholeUpdate, scriptUpdate, entityUpdate, pathFinder, trains; ticks over 16.67 ms and script ticks over 3 ms with the work that ran in them; per-minute script mean/worst; the PERF per-module table |
| `tools/perf-bench.sh scene <name> [min=5]` | the D9 budget scene (4 nations, 16 cities, 600 units, 40 trains; `tools/probes/perf_scene.lua`): a server plays to minute SCENE_AT (8-10) at SCENE_SPEED, the fixture builds the scene, settles a minute at speed 1, saves `perf-scene`; the benchmark runs that save; REALTIME=<min> also plays it on a server at speed 1 and prints the wall clock per game minute |
| `tools/perf-bench.sh bench <name> <save> [min]` | benchmark any save with an earlier run's copy |
| `tools/perf-log.sh <log> [first] [last]` | the PERF lines of any run log (server or benchmark): per-module mean and worst minute, groups (all, AI, M2, M3), AI parts, wall clock and UPS per minute, `sched:` lines |
| `tools/probes/perf_marks.lua` | (added by perf-bench unless MARKS=0) times calls of planning functions (`[rts] perf call t<tick> d<depth> <fn> <force>: <time>`) and, through `events.trace_nth(60)`, every on_nth_tick handler of period >= 60 (`d0 nth<period> <module>`); ROUTE_MARKS=1 also every A* route |
| `tools/determinism-compare.sh <name> '<match>' <min> [seed]` | two runs from fresh saves with the same seed (benchmarks, PERF and marks off), compared line by line: WHAT=events (city sites and foundings, captures, wars, ceasefires, peaces, treaties, planned lines, rail surveys) or WHAT=all (every `[rts]` line but timing); TREE_B compares two trees (Skirmish byte-identity), EXTRA_A/EXTRA_B add a test module to one side, PARALLEL=1 runs both at once |
| `tools/heavy-mode.sh <name> [min=10]` | a 4-nation match saved by a headless server WARMUP s after its start (or START_SAVE), loaded in the GUI client with `--heavy` (save, load and compare every tick) for MINUTES of wall clock; desync lines or a desync report fail it. DRY_RUN=1: the save and a headless load check only. SAVELOAD=1: the headless counterpart, see section 4.3 |
| `tools/lan-check.sh <name> [min=10] [join2=5]` | a headless server with a 4-nation match, GUI client 1 joins (`--mp-connect`), client 2 joins JOIN2 minutes later (or, refused for the same player name, takes over from client 1); desync lines, desync reports and the per-peer state checksums of `tools/probes/perf_lan.lua` decide, FAIL when client 2 never joined; DRY_RUN=1 runs the server half |
| `tools/probes/perf_lan.lua` | every 10 s on every peer: `[rts] lan check t<tick>: players, units N sum S, cities, buildings N sum S, jobs, state` (integer, order-independent sums); `save_at` saves `perf-lan-<tick>` |
| `tools/probes/perf_sched.lua` | the scheduler's functional test (section 3.1) |
| `tools/probes/perf_noslice.lua` | test module: the Nation AI unsliced and the rail survey on the M2 driver, so the M3 tree plays the M2 game (exactness of every other hunk) |

Dry runs (the GUI halves wait for the lead's go: a Codex GUI QA run had the screen):

- `DRY_RUN=1 tools/lan-check.sh lan-dry` (final tree): the server took the 4-nation match (match start 8 s after the
  server), listened on UDP 34371, logged a checksum every 10 s (`lan check t4200 ... t7200`: units 42 -> 70, 10 cities
  with the city-states, buildings 107 -> 134), no desync line, no error; it printed the two client command lines
  (`--mp-connect 127.0.0.1:<port>`, write-data dirs `build/runs/lan-dry-client{1,2}` with player names rts-lan-1/2).
- `DRY_RUN=1 tools/heavy-mode.sh heavy-dry`: the server saved the running 4-nation match at t3,600 (`start.zip`), and that
  save loads and runs headless with the same mods (600 updates in 488 ms, no error); the GUI command line it would run
  is `factorio -c build/runs/heavy-dry-client/config.ini --mod-directory build/heavy-dry --load-game
  build/heavy-dry-out/start.zip --heavy --window-size 1280x800 --disable-audio`.

## 6. Shared files touched

Line numbers in `build/p5m3-perf/factorio-rts` (each hunk carries `-- Phase 5 M3 perf`). `build/p5m3-perf/sync.sh`
three-way merges every changed file against the base (`git merge-file`), so other agents' hunks stay; `--dry-run` lists
what it would do; `--to <dir>` merges into a staging copy instead. Where both sides only *added* lines at the same
place (balance.lua's end, fog.lua's constants: m3-air's hunks), it keeps both. At the time of writing `mods/` had
m3-air's sync in balance.lua, control.lua, fog.lua and hud.lua and another change in rails.lua; the staging merge
(`build/p5m3-perf-merged`, current `mods/` + this package) passes the Skirmish smoke 65/65 and the scheduler probe on a
4-nation match 27/27 with 0 errors.

| File | Lines | What | Owner row in PHASE5-M3 section 2 (told by message) |
|---|---|---|---|
| `scripts/sched.lua` | new | the scheduler | m3-perf |
| `control.lua` | 20 | `require("scripts.sched")` after match | - |
| `balance.lua` | 920 | `balance.nation.ai3.budget = 400` (m3-ai owns the rest of ai3) | m3-ai (wave B) |
| `scripts/events.lua` | 62, 111, 146 | `trace_nth` (tests), `nth_dispatcher`, `events.profiling()` | m3-perf |
| `scripts/rails.lua` | 66, 108, 1202, 1288, 2956 | survey on the scheduler | m3-war2 (sent) |
| `scripts/fog.lua` | 39, 189, 198 | Nation stats sweep | m3-air, m3-world3 (sent) |
| `scripts/mapgen.lua` | 985, 1020, 1039 | Nation depletion slices | m3-world3 (sent) |
| `scripts/hud.lua` | 2445, 2461 | kill feed by sight | m3-air, m3-war2 (sent) |
| `scripts/match.lua` | 275, 291 | enemy count by sight | m3-age3, m3-world3 (sent) |
| `scripts/ai/init.lua` | 35, 61, 93, 157, 171, 220 | Nation offsets, `ai.nation_tick`, tile-set migration | ai/* (m3-ai in wave B) |
| `scripts/ai/commander.lua` | 126, 185, 687, 696 | sliced runs, tile-set snapshots, `tiles_v` | ai/* |
| `scripts/ai/layout.lua` | 88-1820 (29 hunks) | tile sets, journal, resumable router, pocket test, `layout_route` job, satellites, spot/site searches, pole grid, `free()` | ai/* |
| `scripts/ai/hubs.lua`, `towns.lua` | 55, 152 / 176, 297, 343, 412, 515 | tile-set writes and snapshots | ai/* |
| `scripts/ai/army.lua` | 452, 533, 601 | decorated distance sorts | ai/* |
| `scripts/ai/scout.lua` | 35 | sight without chart state | ai/* |
| `scripts/ai/autotest.lua` | 86, 197 | the force list in storage | ai/* |
| `scripts/capture.lua` | 298 | cede hook at init and load | - |

## 6a. The sync into mods/ (on top of the air, Age III and war2 snapshots, HEAD 5b938f0)

`build/p5m3-perf/sync.sh` merged every changed file three-way (base: the tree this package started from): sched.lua
new; balance.lua and fog.lua with both sides' additions kept (air's constants next to mine, my ai3 lines after war2's
block); control.lua, hud.lua, match.lua and rails.lua merged cleanly onto air/age3/war2 (`require("scripts.sched")`
right after match, before every M3 module); the AI files, capture.lua, events.lua and mapgen.lua were unchanged since
the base and copied. Afterwards in mods/ only: the sweep copies its force list (`fog.lua`), and the survey step runs on
through its phases (`rails.lua`), applied to the copy too. Final hunk lines in `mods/factorio-rts`: balance.lua 1258;
control.lua 20; events.lua 62, 111, 146; fog.lua 40, 190, 201; hud.lua 2500, 2516; match.lua 276, 292; mapgen.lua 985,
1020, 1039; rails.lua 68, 121, 1243, 1337, 3236; capture.lua 298; ai/army.lua 452, 533, 601; ai/autotest.lua 86, 197;
ai/commander.lua 126, 185, 687, 696; ai/hubs.lua 55, 152; ai/init.lua 35, 61, 93, 157, 171, 220; ai/layout.lua 88-1820
(29); ai/scout.lua 35; ai/towns.lua 176, 297, 343, 412, 515; sched.lua new.

Tests on mods/ after the sync (0 Lua errors in each; the sched probe's one "Error" line is its deliberate failing job):

| Test | Result |
|---|---|
| Skirmish smoke (seed 9090) | 65/65 |
| Skirmish 1v1 normal medium, seed 777, 9 minutes, against `git archive HEAD` | 0 differing lines of 3,900 |
| scheduler probe, 4 nations | 28/28 |
| rails autotest | 12/12 (one run during a 4-server wave failed `rails_hauler_no_fuel_alert`, 11/12; HEAD and the rerun 12/12) |
| M2 war autotest | 27/27 |
| air autotest | 14/14 |
| Age III fixture | 35/35 |
| war2 autotest | 22/22 |

Before/after on the merged tree: `git archive HEAD` against the synced mods/, paired 20-minute 4-nation benchmarks,
seed 701, on a nearly quiet machine (load factor 1.08 / 1.03):

| Per tick | HEAD | HEAD + m3-perf |
|---|---|---|
| script mean (ms) | 0.215 | 0.219 |
| script p95 / p99 (ms) | 1.53 / 4.42 | **0.90 / 2.41** |
| script ticks over 3 / 6 / 10 ms | 1,677 / 205 / 49 | **364 / 47 / 20** |
| ticks over 16.67 ms (whole) | 28 | **6** |
| worst script tick after the start / the start tick (ms) | 60.9 / 5,323 | 44.3 / 4,604 |
| AI ms/tick, 4 nations | 0.138 | 0.131 (0.033 per nation) |
| AI per tick that runs AI: p50 / p95 / p99 / max (ms) | 2.23 / 5.57 / 9.25 / 60.9 | **0.62 / 1.03 / 2.35 / 19.7** |
| ticks with more than 3 ms of AI | 1,052 | **118** |
| M2 / M3 modules ms/tick | 0.0074 / 0.0020 | 0.0071 / 0.0024 |

Periodic handlers on the synced tree (per call): treasury census slices (m3-age3's) 0.058 ms mean, 0.15 worst; mapgen
depletion slices 0.23 / 1.50; fog re-chart 0.20 / 0.74; logistics 0.14 / 1.29.

The budget scene on the merged tree: built by HEAD (605 units of which 464 moving, 40 trains, 16 cities), the save
benchmarked for five minutes by HEAD and by the synced tree at the same time (entityUpdate 0.816 / 0.819 ms: same load):

| Per tick | HEAD | HEAD + m3-perf |
|---|---|---|
| whole mean / p95 / p99 / max (ms) | 1.613 / 5.749 / 11.548 / 50.1 | 1.552 / **2.981 / 5.699 / 33.2** |
| script mean / p95 / p99 / max (ms) | 0.517 / 4.613 / 10.274 / 48.9 | 0.455 / **1.789 / 4.420 / 31.7** |
| ticks over 16.67 ms (whole) | 24 | **2** |
| script ticks over 3 ms | 1,163 | **362** |
| UPS capacity at the mean tick | 620 | 644 |
| AI ms/tick (4 nations) / M2 / M3 modules | 0.363 / 0.030 / 0.003 | 0.287 / 0.030 / 0.003 |

## 7. Open issues

1. **AI planning is still synchronous inside a slice** (m3-ai, wave B). What remains over 3 ms in single ticks are the
   planners: the match-start planning of every commander (about 170-300 ms each on a quiet machine, in the match-start
   tick together with world generation), forward hubs (hubs.plan + hub_site, 25-60 ms once per hub), the town line and
   site (15-30 ms), district spots (find_spot) in a crowded capital, and army.step at war or with a large pool. A
   faithful conversion needs the planners as state machines; a replay harness (re-running plan_line on each step with
   cached routes) was evaluated and rejected: each replay repeats the non-A* work (5-60 ms), so steps would not fit
   3 ms either. The primitives are ready: `layout.route_init` / `layout.route_step` (resumable, identical expansion
   order), the `layout_route` job kind, `sched.run_sync` for Skirmish.
2. `buildings.for_force` and `units.for_force` iterate every record of every force (with a `.valid` call per match) on
   each call; many modules call them per tick or per run. A per-force index would cut this, but it must keep today's
   iteration order (captures move records between forces), so it is a design change, not a hot-loop hunk.
3. logistics' network recompute (every 60 ticks, per force: every building, `get_contents` per network) grows with
   depots: 80 depots in the budget scene made single calls of 20-70 ms (loaded). A normal 4-nation game has a fraction
   of that.
4. treasury's 600-tick census (every building, 3-5 API calls each): mean 0.6 ms, single calls up to ~8 ms quiet
   (told m3-age3).
5. The rail survey on the scheduler takes 1.7 s instead of 0.6 s for a 473-tile line (2,000 units per tick at most);
   raise `balance.nation.ai3.tick_cap` if players notice (a unit measured ~0.3 us in that survey).
6. All timings were taken on a machine shared with other agents' runs (load factor 2-3); the realtime 60-UPS run of
   the budget scene should be repeated on a quiet machine (`REALTIME=5 tools/perf-bench.sh scene ...`).
7. A LAN session with two clients connected at the same time needs a second Steam/Factorio account (or machine); here
   the second client takes over from the first (section 4.4). A full 10 game minutes of heavy mode is ~5 hours.
8. The match-start tick itself (world.apply 2.6-3.1 s, world.plan 0.5-0.6 s, AI start planning) belongs to D8's
   "core <= 3 s blocking" (m3-world3) and item 1.
9. Determinism, not changed here (audit subagent, section 4.1): the class-C loops listed there (sort or tie-break by key
   when their owners next touch them; `population.lua:229` also never reaches loose buildings past the first 200: the
   walk restarts each tick); `debug.lua` starts its autotest match on any server with nobody connected at tick 120 (a
   real dedicated server too); `strategic.lua:484` writes `player.zoom` into storage (visual only);
   `diplomacy.is_human` counts connected players, so a disconnect hands a nation to the AI mid-match; `research.lua:164`
   sorts techs by order without a name tie-break.
