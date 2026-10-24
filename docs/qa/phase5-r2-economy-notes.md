# Release 0.1.1: hauler fuel, rail freight, tick budget and the hub panels (r2-econ)

Date: 2026-10-24 to 2026-10-25. Engine: Factorio 2.1.23 (mac-arm64, Steam), Space Age on. Agent: `r2-econ`. Issues:
#6 (the hauler fuel rule), #7 (rail freight in the 1v1 acceptance), #8 (script ticks over 3 ms), #9 (hauler lines on
the map), #10 (the stockpile panel's colours). Every run used a frozen tree: `git archive HEAD` of `mods/factorio-rts`
plus this agent's changed files, so other agents' work in progress never reached a run. "Stranded" below means a
hauler waiting "no-fuel" for at least a game minute at a hub that is neither its route's pickup (manual) nor its home
(auto), measured from the server log's state lines.

## 1. Results

| Issue | Commit | Acceptance | Result |
|---|---|---|---|
| #10 | edc680a | colour against the hub's own Keep, or say which Keep; fixture | met: yellow below this hub's Keep, the count's tooltip names the network's levels; the hub panel's self-test logs the colour; a headless check 4/4 |
| #9 | 9dcbc49 | the vanilla lines suppressed or replaced; toggle if cheap; the map's GUI step passes | engine-limited (section 4): the line cannot be hidden on 2.1; it is drawn at the 1 px minimum without destination markers, and the mod draws the selected haulers' routes; no toggle; the M3 GUI pass's map steps pass |
| #6 | 61dd208 | no hauler strands at a remote hub in M1 501 and M2 701-705; the return coal reserved; rails autotest 12/12 | met (section 2) |
| #8 | e9ba46c | the lead's 0.1.1 reading: market.ai_step in 0 ticks over 3 ms, at most 60 script ticks over 3 ms, p99 at most 3 ms, no whole tick over 16.67 ms | met (section 3); the count is at 35-60 and its spread is army.step's |
| #7 | (this notes file's commit) | M1 501 train_items >= 20,000 in two identical runs, lines open before 30:00, the divergence explained | met: 24,225 in two line-identical runs, the player's first line at 24:28 (section 5) |

Every commit: Skirmish smoke 65/65 with the `[rts]` lines identical to HEAD's (seed 777, `build/m3i-tools/runcmp.py`
normalisation: 470 lines, 0 differing).

## 2. Issue #6: the hauler fuel rule

**What stranded haulers on HEAD.** The rule of 552ee2c (a route hauler leaving its pickup waits until both legs are in
its tank when the drop-off's network holds less coal than the way back) had four holes:

1. it read the drop-off's coal at departure, and that coal could be spent before the hauler arrived (rts-ai-1's #2951,
   M1 501: 61 s later, then 22 game minutes dry at port 674);
2. auto haulers had no rule at all: they left home with one leg's coal whenever home lacked both, and stood at the
   outpost or town they fetched from (the player's #2900, 40 minutes);
3. a leg started between hubs paid nothing and checked nothing. The AI's town supply and export routes re-route
   haulers that are driving (#2900, #3411, #2951 again on the first fix);
4. a hauler handed a route while standing at a coal-less hub could never leave (#2481, a town export route given to a
   hauler at an outpost).

On the p21b acceptance logs (scripts identical to HEAD's) 9-16 haulers per run stood dry at a remote hub for at least
two game minutes: M1 501 9, M2 701-705 9, 16, 16, 10, 13.

**The rule now** (Nation mode, `scripts/logistics.lua` go()):

- A leg to a stop without a sure refill requires its way back: a route hauler leaving for its drop-off (back to its
  pickup) and an auto hauler leaving for a source (back home). The way back is paid from the tank, then the departure
  network, then the destination's network, taken at departure so nothing there spends it first. What none of them
  covers keeps the hauler waiting where it stands. Other legs tank what the network spares, as before.
- A leg started between hubs stays free. A hauler re-routed while driving takes its way back from the destination's
  network, or else drives to refuel first: a route hauler to its pickup, an auto hauler home.
- One end of a route with coal is enough: after `FUEL_RESCUE_TICKS` (30 s) dry at a hub, the stop the hauler drives
  to pays the leg (and a required way back) when its network holds the coal.

**Trips worth their coal.** With the holes closed, haulers that used to strand kept driving. In M1 501, 288 of the
player's 301 auto trips carried under 20 items (median 8 plates, 4 coal a round trip to an outpost 56 tiles away).
That traffic burnt the capitals' coal, and the trains need the same coal: in the first version's M1 run the player's
first freight train left a town depot with 2 coal and stood there, and train_items fell to 3,856. Auto trips now wait
at home (`small-load`), up to `balance.nation.hauler_batch_wait` (60 s), for a load of `hauler_items_per_coal` (25)
items per coal of the round trip, then take what there is. In M1 501 the player's haulers made 137 deliveries
instead of HEAD's 353.

Hauler coal by mode in M1 501 (`tools/probes/r2e_coal_by_mode.py`: every arrival leg at ceil(tiles x 1.1 / 40), an
upper bound since legs inside one network are free):

| M1 501 | auto: coal, deliveries (under 20 items), items, items per coal | manual (AI routes): coal, items per coal |
|---|---|---|
| HEAD p21b, rts-player | 1,445, 301 (288), 8,640, 6.0 | 1,928, 4.6 |
| HEAD p21b, rts-ai-1 | 657, 159 (155), 2,755, 4.2 | 1,484, 2.0 |
| 9ed9f92's tree, rts-player | 555, 116 (17), 8,671, 15.6 | 2,526, 4.4 |
| 9ed9f92's tree, rts-ai-1 | 284, 26 (1), 4,146, 14.6 | 1,645, 2.7 |

The player's auto haulers move the same goods on 62 % less coal. The coal now goes to the AI's manual routes (the
port, town supply and town export routes, up to 1,270 tiles a leg), which still leave with small loads: 46 of the
player's 77 manual deliveries carried under 20 items. A minimum load there is the next lever. It needs the governor's
consent, because a town's rations must not wait (sent to r2-ai).

**Results** (61dd208's code; M2 runs `tools/probes/m2_acceptance.lua`, 4 normal AIs, 2048, 60 minutes):

| Run | HEAD p21b: stranded haulers (>= 2 min) | 61dd208: stranded haulers (>= 1 min) | 61dd208: checks |
|---|---|---|---|
| M1 501 | 9 | 0 | 52/53 (train_items 13,111; HEAD 13,506) |
| M2 701 | 9 | 0 | trade, war, peace, capture, starving: PASS |
| M2 702 | 16 | 0 | all PASS |
| M2 703 | 16 | 0 | all PASS |
| M2 704 | 10 | 1: a hauler built in the last minutes waited 1.2 minutes for its first trip, with no coal in its hub's network or the capital's | all PASS |
| M2 705 | 13 | 0 | all PASS |

0 Lua errors in every run; rails autotest 12/12 (the hauler stage: 1,000 iron over 220 tiles per leg, 20 coal).
Haulers still wait at their pickup or home when the coal there is short (the AI's supply haulers at a capital
without coal); that wait is by design and the AI's coal imports answer it.

## 3. Issue #8: script ticks over 3 ms

**Where the time went.** In `tools/perf-bench.sh`'s scene on HEAD, 300 of the 340-425 script ticks over 3 ms were
the ticks with `tick % 60 == 0`, and every one of the 300 such ticks in the five benchmarked minutes was over 3 ms.
About 25 `on_nth_tick(60)` handlers fired together, plus every shorter period dividing 60: production 0.75 ms,
logistics 0.47, strategic 0.34, mapgen 0.23, research, rare, districts, and about 2.3 ms the trace did not attribute.
The same save benchmarked without PERF or marks gave 373 ticks over 3 ms. market.ai_step's ledger slice (the issue's
title) caused 3-4 ticks: the capital's ledger read with its hints cost 1.5-3.0 ms inside commander.run.

**Changes** (e9ba46c):

- `scripts/events.lua`: in a running Nation match the handlers of each period of at least 10 ticks run on a phase of
  their own (registration order, step 37). Where the period is a multiple of 5, the phases avoid the AI commanders'
  slice ticks (`next_tick % 5`). Handlers get the nominal tick as `event.tick`. The phases are re-derived from storage
  at every staggered dispatch, so joining and loading peers agree. Skirmish and the lobby keep the old dispatch.
- `scripts/market.lua`, `districts.lua`: `districts.ledger_rows` plus the hints; the market AI reads the capital's
  ledger in a `market_ledger` scheduler job (about 2,000 units a pass, 8-11 ms a minute per nation, spread over ticks).
- `scripts/production.lua`: the Nation auto-recipe pass runs one group of forces every 15 ticks.
- `scripts/logistics.lua`: the Nation hauler-kit sweep asks each hub network for its kits instead of rebuilding the
  network cache.

**Before and after** (seed 701, 5 benchmarked minutes, PERF=1 and marks; the first two columns ran together):

| | HEAD f524d8f | e9ba46c | e9ba46c, an earlier scene |
|---|---|---|---|
| script ticks over 3 ms | 387 | 60 | 35 |
| script p99 / max (ms) | 5.42 / 23.9 | 2.35 / 10.7 | 2.07 / 10.0 |
| whole ticks over 16.67 ms | 5 | 0 | 0 |
| market.ai_step worst (ms) / ticks over 3 ms it caused | 2.28 / 3 (4 on 61dd208) | 0.30 / 0 | 0.24 / 0 |
| UPS capacity at the mean tick | 612 | 649 | 733 |

The ticks still over 3 ms are mostly army.step (33 in one scene, 15 in the other) and commander.run (5), plus the
autotest's minute report (5, about 10 ms each). The rest are single ticks. army.step's slicing (r2-ai) is what moves
the count clear of the 60 limit.

Script time per tick, the paired runs (18,000 ticks each):

| ms | 0-3 | 3-4 | 4-5 | 5-7 | 7-10 | 10-16.67 | over 16.67 |
|---|---|---|---|---|---|---|---|
| HEAD f524d8f | 17,613 | 65 | 92 | 168 | 48 | 9 | 5 |
| e9ba46c | 17,940 | 46 | 8 | 1 | 0 | 5 | 0 |

Per handler, the same runs (`tools/probes/perf_marks.lua` timings; "culprit" = script ticks over 3 ms in which the
handler was the heaviest timed call; production's 60-tick count halves because its auto-recipe pass moved to period
15, which the marks do not time):

| handler | HEAD: calls, mean ms, worst ms, culprit | e9ba46c: calls, mean ms, worst ms, culprit |
|---|---|---|
| nth60 production | 600, 0.384, 2.61, 129 | 300, 0.124, 0.82, 0 |
| nth60 strategic | 300, 0.342, 1.28, 115 | 300, 0.343, 2.17, 0 |
| commander.run (army.step inside) | 3,600, 1.478, 5.78, 86 | 3,600, 1.523, 5.00, 40 |
| nth60 logistics | 600, 0.223, 3.14, 22 | 600, 0.362, 1.06, 0 |
| nth300 territory | 60, 0.672, 3.06, 21 | 60, 0.620, 1.68, 0 |
| nth60 ai/autotest (minute report) | 300, 0.401, 11.50, 5 | 300, 0.406, 10.48, 5 |
| nth60 perf_scene (test fixture) | 300, 0.095, 4.11, 5 | 300, 0.003, 0.01, 0 |
| nth300 fog | 60, 0.600, 1.32, 2 | 60, 0.556, 0.90, 0 |
| nth600 treasury | 30, 0.164, 1.48, 1 | 30, 0.136, 0.38, 0 |
| nth60 rails, capture, commander, warsupply, sinks, age3, diplomacy; nth120 production | 0.002-0.12 mean, 0 | the same; 15 ticks between them, each with untimed work (periods under 60) |

**Tick arithmetic under the stagger.** A staggered handler gets the nominal tick (a multiple of its period) as
`event.tick`. game.tick is the real tick, up to one period later. A grep over `scripts/` for `game.tick %`,
`[e.tick]`, `[game.tick]` and `e.tick ==` found nothing that breaks:
- `districts.lua` buckets by the real tick.
- production's exact-tick schedule is read in a plain on_tick handler, and `production.schedule_check` moves a tick
  in the past to the next one.
- `debug.lua`'s `e.tick == CHART_PROBE_TICK` runs before the match, where nothing is staggered.
- sched's minute report uses `e.tick`.

**Determinism of the stagger** (e9ba46c plus #7's rails change, seed 701):

- Heavy mode (`tools/heavy-mode.sh`, the GUI client with `--heavy`, which saves, loads and compares the whole state
  every tick): ticks 3,000-3,808 of a running 4-nation match, 0 desyncs. M3's acceptance run reached the same range.
- Save and load (`SAVELOAD=1 SAVE_MIN=5 END_MIN=12 tools/heavy-mode.sh`): over the window both runs cover
  (t18000-t42600), 41 equal state checksums and 5,752 identical `[rts]` lines. The tool itself prints FAIL: the probe
  `tools/probes/perf_lan.lua` saves and logs its checksums from two period-600 handlers, which now sit on different
  phases, so run B's benchmark ends before the nominal t43200 check. r2-platform's a79620e makes the tool compare up
  to the last checksum both runs logged.
- M1 501 at SPEED 8 and 10: 68,104 lines, 0 differing (section 5).

## 4. Issue #9: hauler lines on the map

The engine draws a line on the map from every spider vehicle with an autopilot destination to that destination, up
to 1,000 tiles for a hauler. GUI runs on a 2048 Nation map with eight haulers driving 250-600 tiles out, each with the
map view at zoom 0.07 and a window capture:

- `SpiderVehicleGraphicsSet.autopilot_path_visualisation_on_map_line_width` 0 and -1: the line is drawn at 1 px
  (vanilla 2 px), on the main map and the HUD minimap;
- `entity.color` with alpha 0: the line is drawn in the colour's RGB; a yellow colour draws it yellow, and tints the
  hauler's body yellow;
- `map_view_settings`, `render_player` and `render_to_forces` have nothing for spider vehicles; short autopilot hops
  would shorten the line but change the haulers' movement and the Skirmish log.

9dcbc49 draws the line at the 1 px minimum and drops the on-map destination markers. While the hauler panel is
open, the mod draws the way of each selected hauler to its next stop (2 px, map view only, for that player only, at
most 25 haulers). No help-page toggle: the vanilla line cannot be switched off. The M3 GUI pass (EN) on that tree is
52/53 with the map steps passing (depot_label, the d07, g05 and g06 map captures). Its miss is the AA step: the
Commander shot the bomber 3 s after the AA turret opened fire, the race recorded in the M3 QA round. The finding is
on the issue.

## 5. Issue #7: rail freight in M1 501

**Why the match diverges at minute 21.** m3-fuel's comparison (`phase5-m3-integration-notes.md` section 10) holds:
5a2cdcc (no fuel rule) and 552ee2c (the rule) are line-identical up to minute 21. There the rule first held a hauler
(rts-ai-1's #2951). From then on the wars, captures and towns differ, and train freight follows the war, as any small
change does (section 7 item 11 of those notes). The freight figure itself was low on HEAD for logistics reasons, all
in the HEAD run (p21b, 13,506 items):

1. **Late lines.** The player's capital held 0-60 iron plates from minute 15 to minute 35 while copper piled past
   1,000. The rail program pays its kits through an escrow that leaves `AI_RESERVE + AI_ESCROW_FLOOR` = 100 iron for
   the barracks, so line #3 waited "no-kits" from 21:53 to 31:53. Line #2's capital depot was destroyed in the war at
   23:41, and the program placed a new one at 31:41. First lines: 32:55 (player) and 38:18 (rts-ai-1).
2. **Coal.** Stranded haulers and tiny auto trips (section 2) burnt and parked the coal that trains and depots need.
   A train refuels from its depot's network, and a town depot gets its coal from the capital (`ai_supplies`). With
   the fuel holes closed but no batching, the player's first train left with 2 coal and stood at the town (3,856
   items).
3. **Trains capped by the capital's Keep.** A freight train loads what the drop-off's network keeps, less what it
   holds. The capital keeps 3,000 of its town's ore (`ai/towns.lua` ORE_KEEP). Once it held that, a trip carried
   only what the capital had used since (6-184 copper ore a trip for the player), and the governor's town export
   route took the town's surplus 1,000 tiles to the port by hauler: 5,289 copper ore of the player's and 1,200 iron
   ore of rts-ai-1's on HEAD, 6,000 and 1,600 with #6. With #6 alone the lines opened at 25:43 and 30:31, but
   train_items stayed at 13,111.
4. **No freight train in some runs.** In m3-fuel's run without the rule, the player's train stood at a town depot
   whose network offered nothing the capital kept, and it never loaded.

**The change** (`scripts/rails.lua` cargo_plan): an AI rail program's freight train carries everything its town
offers, not only the capital's Keep deficit. The capital's port route sells what it holds above its export level, so
the surplus now goes town to capital by train and capital to port by hauler. An AI program's train no longer stands
idle at a town that offers goods the capital does not keep. Lines a human player builds keep the Keep rule.

**M1 501 on HEAD e9ba46c plus this change** (`tools/probes/m1_acceptance.lua`, two runs):

| | HEAD p21b (scripts as 55cbc46) | 61dd208 (#6 only) | e9ba46c + this change, SPEED 8 | the same, SPEED 10 |
|---|---|---|---|---|
| autotest | 52/53 | 52/53 | **53/53** | **53/53** |
| train_items | 13,506 | 13,111 | **24,225** | 24,225 |
| rts-player by train | 4,130 in 16 trips | 4,276 in 41 trips | 11,032 in 57 trips | the same |
| rts-ai-1 by train | 9,376 in 35 trips | 8,835 in 88 trips | 13,193 in 97 trips | the same |
| first line open: player / rts-ai-1 | 32:55 / 38:18 | 25:43 / 30:31 | **24:28** / 22:21 | the same |
| haulers stranded at a remote hub | 9 | 0 | 0 | 0 |

The two runs are line-identical: 68,104 `[rts]` lines up to the autotest summary, 0 differing. 0 Lua errors. The
same change on 61dd208 plus the market part of #8 gave 21,145 (player 10,264, rts-ai-1 10,881, first line 25:30); the
stagger of #8 moved the match, as any change does, and the freight stayed above the goal.

**Nation checks on the same tree** (e9ba46c plus this change; these also cover #8's stagger in Nation play):

| Run | Checks | Stranded haulers | Lua errors |
|---|---|---|---|
| M2 701 | trade, war, peace, capture, starving: PASS | 0 | 0 |
| M2 702 | all PASS | 0 | 0 |
| M2 703 | all PASS | 0 (one re-homed hauler waited 1.0 minute until the rescue rule paid its trip) | 0 |
| M2 704 | all PASS | 0 | 0 |
| M2 705 | all PASS | 0 (one hauler, given a town export route at its capital at 58:20, waited there for coal until the end) | 0 |
| Rails autotest | 12/12 (rails_ai: line #3 open, freight train 43) | | 0 |
| Skirmish smoke | 65/65, 470 lines identical to HEAD (seed 777) | | 0 |

Heavy mode and the save/load comparison are in section 3.

**What is left.** The rail program's escrow (`rails.lua` AI_RESERVE + AI_ESCROW_FLOOR, 100 iron left for the
barracks) still keeps a starved capital's kits waiting; whether the rails or the army get the iron is a balance call,
left as it is. For the AI (r2-ai, sent by message): the governor's town export route still starts when a town holds more
than 1,500 ore and plates (with the trains taking the town's whole offer it now starts rarely), and a line to a town
that offers nothing runs an idle train.

## 6. Measurement tools (`tools/probes/r2e_*`; the commands are in each file's header)

- `r2e_strand.py`: no-fuel waits per hauler and hub from a server log (state, arrival, route, home and mode lines),
  interpolated to game minutes from the AI minute lines; "remote" as defined at the top.
- `r2e_coal_by_mode.py`: hauler legs, coal, deliveries and items per force and mode from a server log.
- `r2e_prof.lua` (EXTRA_LUA for perf-bench): times market.ai_step and, inside it, the ledger parts.
- `r2e_map_gui.lua` (GUI probe, ask r2-ux for a screen slot): the #9 map captures and route-line checks.
- `r2e_hubgui_colour.lua` (EXTRA_LUA, Skirmish): the #10 check with two hubs in one network.
