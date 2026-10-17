# Phase 5, milestone M3: "A state at war"

Owner direction 2026-10-16 evening: continue through every milestone without pausing for approval. The lead decides;
decisions are listed in §0 and reported after the fact.

Goal of M3: a **nation** can be built, defended and broken at full scale. Age III closes the economy (chemistry,
nuclear power, automation that replaces people) and opens a second road to victory, the **Space Program**; rare
resources give nation-wide bonuses that must be held and shipped; wars get **fronts, fort belts, air units,
artillery and armoured trains**; the AI becomes the full layered nation AI of the war study with **difficulty without
cheats**; the world grows to 3072 and 4096 with background generation and up to six nations; the whole game holds
the budget of 4 nations, 16 cities, 600 units and 40 trains at 60 UPS, saves and loads at any point, and runs a
two-client LAN session without a desync. Every Skirmish behaviour stays exactly as in Phase 4; every M1 and M2 Nation
acceptance keeps passing.

Studies: `research/scale/*.md` (`deep-economy.md` §2.6, §3.7, §5.6, §9.3; `war-ai-performance.md` §2.4, §2.6–2.8,
§4, §5, W2/W3; `world-map.md` §4.3; `rails-trade.md` R2). Contracts of the earlier milestones: `PHASE5-M1.md`,
`PHASE5-M2.md` (their APIs are the base). Open issues folded in: `qa/phase5-m2-integration-notes.md` §6 and
`qa/phase5-ai-notes.md` §6. This document is the contract between the M3 work packages.

## 0. Decisions (lead)

| # | Decision | Why |
|---|---|---|
| D1 | **Age III is a national project again**: research *Electrification* (Age II lab science) lets a nation start the **Space Program** at a 8×8 *Launch complex* site in the capital. The project has three stages, each a delivery list of Age III goods (stage 1 structure: steel, concrete, advanced circuits; stage 2 systems: processing units, batteries, engines; stage 3 fuel: rocket fuel, sulfur, light oil in barrels). Stage 1 complete = **Age III** for the nation (districts and kits unlock). Stage 3 complete = **Space Program victory** when the lobby's victory mode is *Conquest+Space* (default) or *Any*. Base content only; Space Age swaps graphics as today. | `deep-economy.md` §9.3 wants a second, economic road to victory; the Railway Charter flow (`ages.lua`) exists and is QA-tested. |
| D2 | **Age III economy**: chemistry district (oil → plastic, sulfur, rocket fuel, batteries), electronics II district (advanced circuits, processing units), nuclear plant composite (uranium → 40 MW), concrete works. **Automation kits** (vanilla module recipe: 5 advanced + 5 electronic circuits) go into slot 2 of a family's districts when the city policy says "automate <family>", each cuts the building's jobs by 30 % (labor module variant). Oil fields exist since M1 (`world.lua` regions); the oil town is the natural third city. | §5.6: automation is the late answer to the labor cap; freed people become soldiers and scientists. |
| D3 | **Rare resources** (six kinds placed by M2 world: saltpetre, quartz, tungsten, diamonds, rare earths, gold) are worked by a **rare extractor** whose trickle (1 item/10 s) must reach the **capital's network**; the bonus is active while ≥ 1 item arrived in the last 90 s, and is lost within 90 s of the flow stopping. Bonuses per `deep-economy.md` §3.7 (recipe productivity via `LuaRecipe.productivity_bonus`, mining productivity, lab speed, +15 % tax for gold), applied as deltas with the research bookkeeping. **Uranium** feeds the nuclear plant and (Age III) uranium rounds for heavy walkers. | Makes a bonus a logistics problem and a raid target instead of a flag on ownership. |
| D4 | **Air**: `unit`-class flyers with an empty collision mask and `render_layer = "air-object"`: **scout plane** (Age II, *Aviation*; fast, unarmed, radar 2), **bomber** (Age III; ×2 vs buildings, slow), **interceptor** (Age III; ×3 vs air). An **airfield** building (one per city, 6×6) is where planes are made (kits in the barracks need an airfield in the city), rearm and refuel: a plane has a supply of 100, loses 1/s in flight away from an airfield, returns on its own at 20 and crashes at 0. **Anti-air turret** (Age II, *Aviation*) targets only `trigger-target-type` "air"; gun and laser turrets ignore it; ground units may shoot planes (accepted; planes get 60 % physical resistance). Planes join divisions like other units but ignore terrain. | Verified feasible in `war-ai-performance.md` §1.2 and §2.7; the unit class costs 0.66 µs. Naval stays out of scope. |
| D5 | **Fronts and fort belts.** For each war, the border where the two territories touch is split into **segments** of 128–192 tiles, recomputed with the territory every 30 s. A division ordered `hold_line` on a segment spreads along its chord. The **fort belt tool** (F key in the division/strategic panel, or the build menu) takes a 2–6 point polyline inside own land and lays out ghosts: wall line with gates where rails cross, a turret every 12 tiles 3 tiles behind, an AA turret every 36 tiles from Age II, a field depot behind the middle; the ghosts are built through the existing build pipeline (cost debited from the nearest city network, built by its hub robots; the Commander's field build works too). Turret priority lists (`set_priority_target`) make belts shoot artillery and siege first. | `war-ai-performance.md` §2.4; fronts give the war council and the player the same objects. |
| D6 | **Artillery and armoured trains.** *Military railways* (Age II) unlocks the **artillery wagon kit** (vanilla `artillery-wagon` with RTS shells, `disable_automatic_firing`; a train with the stance *bombard* fires at hostile buildings within 120 tiles every 10 s through the existing artillery projectile code, 1 shell per shot from the wagon) and the **armoured locomotive/wagon kits** (3× health, 40 % physical/explosion resistance, train impact damage as vanilla). An armoured troop train is the M2 troop train with armoured stock. Trains at war obey `diplomacy.hostile`. | `rails-trade.md` R2, `war-ai-performance.md` §2.6. |
| D7 | **Full layered nation AI without cheats** (`war-ai-performance.md` §4): strategist (exists) → **economic planner** (city sites by region scoring with the need vector, the third/fourth city, the rail trunk tree, oil and rare targets) → governors (exist) → **war council** (fronts, threat per segment, division allocation with 25 % reserve, operations with phases and timeouts, air patrols, bombers before an offensive, siege with artillery) → **division controllers** (stance, retarget, retreat at force ratio < 1, resupply) → **intelligence** (`scout.lua` generalised: known cities, divisions, rails, decay). All AI work runs through a **work-unit scheduler** (deterministic units, ~400/tick/nation, resumable jobs in `storage`, no `coroutine`). **Difficulty in Nation mode** is the knob table of §4.7 (intelligence age 60/30/10 s, concurrent operations 1/2/4, A* and candidate caps, build pace, micro, orders per minute); the M2 "hard = +20 % tax" cheat goes; Skirmish keeps its Phase 4 bonuses untouched. Hard must beat normal in ≥ 7 of 10 seeded AI-vs-AI 1v1 matches. | D9 of M2 promised the full AI in M3; the acceptance is measurable. |
| D8 | **Huge worlds**: lobby world sizes 2048 (default), 3072, 4096; nations up to 6 on ≥ 3072. Generation: the **core** (chunks within 5 chunks of every spawn and 3 of every site, ≤ 3 s blocking) is forced; the rest is requested from the spawns outwards and filled in the background (~39 chunks/s, 2048 in ~105 s, 4096 in ~7 min). Every planned feature (ore, oil, rare, ruins, city-states, ports, labels) is assigned to chunks in `storage.world.plan` and placed in `on_chunk_generated`; a save mid-generation resumes. The survey charts what exists and the rest as it arrives. AI planners only consider generated cells (and request the chunks they want). | `world-map.md` §4.3: background fill is free and 4096 costs nothing per tick. |
| D9 | **Performance and determinism pass**: budget 4 nations, 16 cities, 600 units, 40 trains at 60 UPS on the dev Mac (speed 1, PERF=1 per-module breakdown); AI ≤ 0.5 ms/tick per nation mean, ≤ 3 ms any tick; M2 modules ≤ 0.5 ms together; chunk-bucketed reservations; no per-tile tables over the map; `pairs` order never decides anything that a reload rebuilds. **Heavy mode** 10 minutes of a 4-nation match, and a **two-client LAN session** (headless server + GUI client on this Mac, 10 minutes, then a second GUI client joins mid-match) show no desync. | `war-ai-performance.md` §5; nothing multiplayer has been tested yet. |
| D10 | **Money gets sinks and hysteresis** (M2 open 6 and ai-notes 3): *Rush* a national project or a research (crowns per missing item/second, 2× speed), *Hire garrison* (crowns → garrison points at a city, decays), *Mercenary division* at a trade port (crowns → a small division of the port's region, 10-min cooldown); tax and deficit mode switch with a hysteresis band; **city-states trade** (their City Center is a port for its region's goods at a 1.3× price; buying raises relation, capturing a city-state at peace costs −10 relation with every nation). | Money must matter; D7 of M2 deferred city-state trade. |
| D11 | **Not in M3**: naval, vassalage, tariffs and embargoes, Space Age-only goods, a second planet. Razing stays out (capture only). | Scope. |

## 1. Shared rules (in addition to `PHASE5-M1.md` §1 and `PHASE5-M2.md` §1)

- Everything here is **Nation mode only** except the scheduler (`scripts/sched.lua`), which the Skirmish AI may *not*
  use in M3 (Skirmish stays byte-identical in autotest results at the same seeds).
- `storage.nations[force]` grows under each module's own key: `age3`, `rare`, `air`, `fronts`, `planner`, `council`,
  `intel`; each module clears its key in `on_match_teardown`.
- New balance tables: `balance.nation.age3`, `.rare`, `.air`, `.fronts`, `.trains_war`, `.sinks`, `.world3`,
  `.ai3` (pure data). Difficulty knobs live in `balance.nation.ai3.difficulty[level]`.
- Every long computation is a **resumable job** on the scheduler: `{kind, state, cost}` in `storage`, open/closed sets
  as arrays, no closures. Budgets are counted in work units, never wall clock.
- Forces: no new forces. Planes, trains and belts belong to their nation's force. `diplomacy.hostile(a, b)` stays the
  only relation test.
- Log prefixes: `age3:`, `rare:`, `air:`, `front:`, `belt:`, `train:`, `sched:`, `planner:`, `council:`, `intel:`,
  `world:`, `sinks:`; autotests grep the log.
- GUI: new hotkeys go into `hud.lua`'s `P4.KEYS` (F = fort belt tool, B = bombard stance on a train, H = hold line,
  Y = airfield panel) and into the Nation help page (F11); both locales; no raw keys; 1280×800 fits.

## 2. Work packages, owners and files

| Package | Agent | New files (owner edits freely) | Shared files it may touch (small hunks marked `-- Phase 5 M3 <pkg>`) |
|---|---|---|---|
| Age III, Space Program, rare bonuses, money sinks (E3, D1–D3, D10) | `m3-age3` | `scripts/age3.lua` (Launch complex project, stages, victory), `scripts/rare.lua` (extractors, trickle, bonuses), `scripts/sinks.lua` (rush, hire, mercenaries, city-state trade), `prototypes/age3.lua` (districts, nuclear plant, concrete works, automation kit, rare extractor, Age III items and recipes, Electrification/Chemistry/Nuclear techs), `locale/*/age3.cfg` | `ages.lua` (`MAX_AGE = 3`, project by age), `districts.lua` (families, automation slot), `labor.lua` (kit job cut), `research.lua` (techs, bonus deltas), `market.lua` (hysteresis, city-state prices), `treasury.lua` (sinks, gold), `marketgui.lua`/`citygui.lua` (buttons), `match.lua` (Space victory), `lobby.lua` (victory list), `world.lua` (rare entities → extractor spots) |
| Air units, anti-air, airfield (D4) | `m3-air` | `scripts/air.lua` (supply, return, crash, airfield rearm, patrol), `prototypes/air.lua` (scout plane, bomber, interceptor, airfield, AA turret, Aviation/Air Force techs, "air" trigger target type), `locale/*/air.cfg` | `units.lua`/`supply.lua` (kinds, costs), `production.lua` (airfield gate), `divisions.lua` (planes in divisions, terrain-free movement), `orders.lua` (patrol), `targeting.lua` (turret masks), `buildings.lua` (airfield), `hud.lua` (airfield panel Y), `fog.lua` (scout reveal) |
| Fronts, hold line, fort belts, artillery and armoured trains (W2 rest, D5–D6) | `m3-war2` | `scripts/fronts.lua` (segments per war, threat), `scripts/belts.lua` (polyline → ghosts, gates, priorities), `scripts/trainswar.lua` (bombard stance, shells, armoured stock), `prototypes/war3.lua` (artillery wagon, shells, armoured loco/wagon kits, gate, Military railways/Fortification techs), `locale/*/war3.cfg` | `divisions.lua`/`divisiongui.lua` (`hold_line`, front card), `strategic.lua` (front lines on the map, belt tool), `rails.lua` (new kits, train stances, `railgui.lua` Bombard button), `territory.lua` (border edges), `buildings.lua` (build pipeline for belt ghosts), `orders.lua` (sabotage stays), `hud.lua` (F, B, H keys) |
| Huge worlds, background generation, up to six nations (D8) | `m3-world3` | `scripts/worldgen.lua` (plan → chunks, core, `on_chunk_generated` placement, survey), `locale/*/world3.cfg` | `world.lua` (plan tables, sizes 3072/4096, 5–6 spawns), `mapgen.lua`, `match.lua` (nation count, start sequence), `lobby.lua` (size and nations drop-downs), `fog.lua`/`strategic.lua` (chart as chunks arrive), `ai/towns.lua` only via `m3-ai` |
| Scheduler, performance, determinism tooling (D9) | `m3-perf` | `scripts/sched.lua` (work units, jobs, per-nation budgets), `tools/perf-bench.sh` (the 4/16/600/40 fixture from a scripted save), `tools/lan-check.sh` (headless server + GUI client(s), desync grep), `tools/heavy-mode.sh`, `tools/probes/perf_*.lua` | every module's hot loops, with the owner's agreement when the owner is active (measured hunk by hunk, `PERF=1` before/after in the notes); `ai/layout.lua` reservations chunk-bucketed; `events.lua` profiling per module in the PERF summary |
| Full nation AI (D7), wave B | `m3-ai` | `scripts/ai/planner.lua`, `scripts/ai/council.lua`, `scripts/ai/controller.lua`, `scripts/ai/intel.lua`, `scripts/ai/difficulty.lua` | `ai/*` only (`nation.lua`, `governor.lua`, `army.lua`, `scout.lua`, `towns.lua`, `autotest.lua`), `balance.nation.ai3` |
| Integration, wave B | `m3-integ` | `docs/qa/phase5-m3-protocol.md`, `docs/qa/phase5-m3-integration-notes.md`, README | everything except `ai/*` while `m3-ai` runs |

Each wave-A agent works in a copy under `build/p5m3-<name>/` (the M2 QA fix agent may still be editing `mods/`),
validates headless, and syncs **its own files** into `mods/factorio-rts/` only after the lead opens syncing;
shared-file hunks are applied after re-reading the current file; nobody reverts another agent's hunk; the lead
commits snapshots after smoke tests. `m3-perf` is special: it measures first (notes with numbers before any change),
changes only what the numbers justify, and sends hot-loop hunks of files another wave-A agent owns to that agent.

## 3. Contracts (public API per module)

### age3.lua / rare.lua / sinks.lua (`m3-age3`)

```
age3.project(force) -> {stage = 1|2|3, required = {[item] = n}, delivered = {...}, site} | nil
age3.can_start(force) -> ok, reason           -- Electrification researched, Age II, no running site
age3.start(force, position) -> project | nil, reason
age3.stage_done(force, stage)                 -- internal; stage 1 fires events.raise("rts_age_up", {force, age = 3})
                                              -- stage 3 fires "rts_space_victory" {force}; match.lua ends the match
                                              -- when the lobby victory mode allows it
age3.automate(city_id, family, on)            -- policy: insert/remove automation kits in the family's districts
age3.automation(city_id) -> {[family] = {kits = n, jobs_cut = share}}
rare.deposits(force) -> {{kind, position, extractor, flowing = bool, last_tick}}
rare.bonuses(force) -> {[kind] = {active = bool, since}}   -- applied bonus set
rare.apply(force)                             -- recompute deltas (research bookkeeping); called on flow change
sinks.rush(force, what) -> ok, reason         -- what = "project" | tech name; cost per missing item·s from balance
sinks.hire_garrison(force, city_id, points) -> ok, reason
sinks.mercenaries(force, port_site) -> division_id | nil, reason
market.trade_with_city_state(force, city_id, item, count, buy) -> ok, reason   -- 1.3× price, relation +1 per 100 cr
```

Balance: `balance.nation.age3` (project stages, district recipes, nuclear plant, kit job cut 0.3),
`.rare` (trickle 1/10 s, grace 90 s, bonus table), `.sinks` (rush cr per item·s, hire cr per point and decay,
mercenary template per region, cooldown 600 s, city-state markup 1.3, capture penalty −10). Market hysteresis:
`balance.nation.market.ai.hysteresis = {enter = floor, leave = floor * 1.4}`.

### air.lua (`m3-air`)

```
air.is_plane(entity) -> bool
air.supply(unit_number) -> 0..100
air.airfields(force) -> {entity}             -- one per city, kind "airfield"
air.order_patrol(division_id, position, radius)
air.order_return(division_id)
air.state(unit_number) -> "flying" | "returning" | "rearming" | "crashed"
```

Rules: a plane kit requires an airfield in the barracks' city (`production` gate "no airfield"); planes spawn at the
airfield; supply −1/s in flight away from any own airfield (within 24 tiles of one: +10/s); return at 20, crash at 0
(dies, alert); planes never trigger ground `on_entity_damaged` penalties of warsupply (they have their own supply).
AA turret: `attack_target_mask = {"air"}`; gun/laser turrets and garrison turrets: `ignore_target_mask = {"air"}`.
Walkers and drones may shoot planes (no mask). Balance: `balance.nation.air` (kinds, speeds, costs, supply, masks).

### fronts.lua / belts.lua / trainswar.lua (`m3-war2`)

```
fronts.of(force) -> {[war_id] = {segments = {{id, a, b, chord, threat, holder = division_id | nil}}}}
fronts.refresh(force)                         -- every 30 s, from territory border edges (sliced job)
fronts.threat(segment) -> number             -- intel strength near × value behind (cities, depots, rails)
divisions.order(id, "hold_line", segment_id) -- spreads formation slots along the chord; stance hold
belts.plan(force, points, opts) -> plan_id | nil, reason  -- polyline inside own land; opts.aa, opts.depot
belts.ghosts(plan_id) -> n                   -- ghosts placed; built through buildings' pipeline
belts.cancel(plan_id)
trainswar.set_stance(train_id, "bombard" | "none")
trainswar.targets(train_id) -> {entity}      -- hostile buildings within range by diplomacy.hostile
trainswar.fire(train_id)                     -- every 10 s in bombard: 1 shell, the artillery projectile code
rails.KITS += artillery_wagon_kit, armoured_locomotive_kit, armoured_wagon_kit
```

Balance: `balance.nation.fronts` (segment 128–192, refresh 1800 ticks), `.belts` (turret every 12, AA every 36,
gate on rail crossings, depot behind the middle, cost = real items), `.trains_war` (range 120, period 600 ticks,
shell cost, armoured health ×3, resistances).

### worldgen.lua (`m3-world3`)

```
worldgen.plan(seed, size, nations) -> plan   -- regions, sites, ore, oil, rare, labels per chunk; in storage.world.plan
worldgen.core_chunks(plan) -> {chunk}        -- within 5 of spawns, 3 of sites
worldgen.generate_core()                      -- force_generate_chunk_requests on the core; ≤ 3 s at 4096
worldgen.request_rest()                       -- request_to_generate_chunks from spawns outwards, ring by ring
worldgen.on_chunk_generated(event)            -- places the plan's content for that chunk; idempotent
worldgen.progress() -> {generated, planned, share}
world.sizes = {2048, 3072, 4096}; match.config().nations ∈ 2..6 (≤ 4 at 2048)
```

Rules: no module may assume a chunk exists; `world.region_at` answers from the plan (not from tiles); AI planners ask
`worldgen.progress()` and request chunks they need. Survey start charts generated chunks and continues in
`on_chunk_charted`. Balance: `balance.nation.world3` (core radii, ring rate, spawn count per size).

### sched.lua (`m3-perf`)

```
sched.register(kind, step_fn)                -- step_fn(job, units) -> units_used, done; registered at load
sched.submit(force, kind, state, priority) -> job_id
sched.cancel(job_id); sched.status(job_id) -> "queued" | "running" | "done" | "cancelled"
sched.budget(force) -> units_per_tick          -- balance.nation.ai3.budget (default 400) × difficulty factor
sched.stats() -> {[force] = {jobs, units_last_minute, ms_last_minute}}
```

Rules: one `on_tick` loop; nations round-robin by index; a job keeps its whole state in `storage.sched.jobs[id]`;
`PERF=1` prints `sched:` per nation and per kind in the minute summary. Skirmish never submits a job.

### ai/planner.lua, council.lua, controller.lua, intel.lua, difficulty.lua (`m3-ai`, wave B)

```
planner.sites(force) -> {{cell, score, role = "mining"|"oil"|"industrial"|"fortress"|"trade"|"rare", claimed}}
planner.next_city(force) -> site | nil         -- by need vector (world.scarcity, chains), exposure, rail cost
planner.trunk(force) -> {{from_city, to_city, state}}   -- MST over cities; rails.plan_line consumes edges
council.step(force)                            -- every 120 ticks: fronts threat → division allocation, operations
council.operations(force) -> {{kind = "capture"|"siege"|"relief"|"raid"|"bomb", target, phase, since, divisions}}
controller.step(division_id)                   -- every 30–60 ticks: retarget, retreat (ratio < 1), resupply, air return
intel.known(force) -> {cities = {...}, divisions = {...}, rails = {...}, age_ticks}
difficulty.knobs(force) -> {intel_age, ops, caps, pace, micro, opm}   -- from balance.nation.ai3.difficulty
```

Rules: every AI decision reads the blackboard `storage.nations[force]` and game state through `intel` (sight checks,
never charts); seeded generators only; no wall clock; all long work on `sched`. The M2 strategist and governors keep
their contracts and call the planner and council instead of their own ad-hoc rules.

## 4. Autotests and acceptance (headless, `mode = "nation"`)

Each package adds its checks to `scripts/ai/autotest.lua` or a `debug.lua` fixture and must pass them with 0 Lua
errors at 60 UPS, plus the Skirmish smoke (65/65), the M1 acceptance (seed 501, 53/53) and the M2 fixtures
(`tools/probes/m2_acceptance.lua` on seeds 701–705 keeps its results within the stated tolerances).

- **Age III / rare / sinks:** a scripted nation that delivers stage 1 reaches Age III and its districts unlock;
  stage 3 ends the match with Space victory when the mode allows and not otherwise; an automated family at 2 kits per
  district shows jobs ×0.49 and the same output; delivering saltpetre raises explosives productivity by 0.25 within
  90 s and losing the flow removes it within 90 s; the nuclear plant yields 40 MW from uranium; rush doubles a
  project's pull speed and charges per item·s; hired garrison points decay; a mercenary division spawns at a port and
  the cooldown holds; tax switches ≤ 2 times per nation-hour in a 60-minute 4-nation run; city-state trade changes
  relation; the normal AI reaches Age III by 40:00 in 3 of 5 seeds (with `m3-ai`).
- **Air:** a scout plane crosses a lake and a wall; an AA turret hits a plane and a gun turret does not fire at it; a
  plane at supply 20 returns to its airfield and rearms; a plane at 0 crashes with an alert; a bomber division
  destroys a depot ×2 faster than the same cost in walkers; 60 planes cost ≤ 0.1 ms/tick.
- **Fronts / belts / trains:** a war between two nations with touching land yields ≥ 2 segments with threat values;
  `hold_line` spreads a 24-unit division along a 160-tile chord within 20 s; a 200-tile belt is planned and built
  within 3 minutes with the right item debit, gates where the rail crosses; an artillery train in bombard destroys a
  turret at 100 tiles within 60 s and spends shells; an armoured train survives 3× the damage of a plain one.
- **World 3:** 4096 with 6 nations: core generated in ≤ 3 s, the rest within 8 minutes while the match runs at
  60 UPS; every planned site exists once it is generated; save at 2 minutes (mid-generation) loads and finishes
  generating; 3072 with 4 nations passes the M2 world checks (ores lacking, chokes, city-states, ports); M1 and M2
  acceptances at 2048 unchanged.
- **Perf / determinism:** `tools/perf-bench.sh` on the 4/16/600/40 fixture holds 60 UPS at speed 1 for 5 minutes
  with the PERF breakdown in the notes (AI ≤ 0.5 ms/tick/nation mean, ≤ 3 ms any tick; M2+M3 modules ≤ 1 ms
  together); two runs of the same seed log the same city sites, wars and treaties; heavy mode 10 minutes of a
  4-nation match: no desync; `tools/lan-check.sh`: a GUI client joins a headless 4-nation match, plays 10 minutes,
  a second client joins at minute 5, no desync in either log.
- **AI (wave B):** 4 normal AIs, 60 min, 2048, seeds 801–805: every nation founds ≥ 3 cities and links them by rail
  by minute 35; ≥ 1 operation with phases logged per nation; air patrols fly; a belt is built on a threatened segment;
  Age III by 40:00 in ≥ 3/5; wars and peaces as in M2; 0 errors; AI budget as above. **Difficulty:** hard beats
  normal in ≥ 7 of 10 seeded 1v1 Nation matches at 2048 (score at 60 min), with no resource bonus anywhere.
- **M3 end-to-end (integration):** the M2 end-to-end criteria plus the AI criteria above on seeds 801–805; save/load
  at 20 and 40 minutes; the Skirmish matrix unchanged vs `m2-ready`; the GUI protocol (Codex) covers: Space Program
  site and stages, an automation policy, a rare extractor and its bonus line in the ledger, an airfield and a scout
  plane, an AA turret firing, a front segment and `hold_line`, the fort belt tool, an artillery train in bombard,
  rush and hire buttons, a city-state purchase, the 4096 lobby and the generation progress line, and the LAN join.

## 5. Shared-file etiquette

As `PHASE5-M2.md` §5, with the hunk marker `-- Phase 5 M3 <pkg>`. In addition: no module may use `coroutine`,
closures in `storage`, `LuaProfiler` values in a decision, or chart state for an AI force; every long loop is a
`sched` job (wave B may convert wave-A loops with the owner's hunks); `m3-perf`'s numbers are the arbiter of
performance hunks; GUI additions register in `P4.KEYS` and the F11 help page in both locales; report to the lead:
files changed, shared hunks (file:line), autotest results, open issues, measured ms/tick before and after.
