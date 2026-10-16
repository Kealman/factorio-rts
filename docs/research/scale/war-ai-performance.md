# War at state scale, a nation-running AI, and the engine's limits

Study for the "mini-state" direction: Rise of Nations and Workers & Resources scale, maps of 2000–4000 tiles, 2–4
nations with several cities each, rail logistics, trade and war between states. Date: 2026-10-16. Factorio 2.0.77
(build 84539, mac-arm64, Steam, Space Age on). Inputs: `README.md`, `docs/DESIGN.md`, `docs/PHASE3.md`,
`docs/PHASE4.md`, `docs/qa/phase3-ai-notes.md`, `docs/qa/phase4-integration-notes.md`,
`docs/research/api-capabilities-2.0.77.md`, `scripts/ai/*`, `scripts/units.lua`, `scripts/orders.lua`. Sibling studies
in this folder cover cities, the economy, rails and world generation; this one covers warfare, the nation AI and the
performance envelope. API names are quoted from `runtime-api.json` and `prototype-api.json` of the installed game
(`doc-html/`). Probes and raw results: `build/scale-probe-war/` (appendix).

## Summary

**Verdict.** State-scale war fits in Factorio 2.0.77. Production, trains and charting are not the limit: 20,000
active production entities cost 0.31 ms per tick and 40 trains 0.04 ms. Moving units are the limit, and above all
the pathfinder. 2,000 moving spider-units cost 4.6 ms per tick, and one order to 1,000 spider-units in the same tick
costs a 25 ms tick. Armies therefore have to be a few large objects (divisions) that path once, and everything that is
not fighting right now (garrisons, troops on trains, population) should exist as numbers, not entities.

Measured on an Apple M3 Pro, headless `--benchmark`, after the first 300 ticks (60 UPS = 16.67 ms per tick):

| Probe | Mean ms/tick | p95 | Worst tick | Sustainable UPS |
|---|---|---|---|---|
| Empty map (baseline) | 0.18 | 0.24 | 0.44 | 5,500 |
| 2,000 spider-units (`rts-walker`) moving under commands, 4 forces | 4.58 | 7.14 | 11.7 (28.2 in the order burst) | 218 |
| 2,000 `unit`s (`rts-drone`) moving | 1.50 | 2.37 | 6.0 | 665 |
| 4,000 `unit`s moving | 2.86 | 3.32 | 3.9 | 350 |
| Battle, 1,000 vs 1,000 mixed (walkers, heavies, drones), whole fight | 5.13 | 9.24 | 27.2 | 195 |
| 20,284 production entities in 4 bases (belts, inserters, assemblers, chests, substations) | 0.31 | 0.52 | 0.95 | 3,200 |
| 81,124 production entities | 1.17 | 2.65 | 4.15 | 855 |
| 40 trains on 10 km of track, 320 signals, 80 stops | 0.20 (trains 0.037) | 0.25 | 1.0 | 5,000 |
| 160 trains on 40 km | 0.30 (trains 0.13) | 0.38 | 3.6 | 3,350 |
| Chart, 4 AI forces on 2000×2000 | 0 (AI forces are never charted) | – | – | – |
| Chart, 1 human force on 2000×2000, 40 radars + fog.lua-style re-chart (GUI client) | +0.2 | – | – | – |

**The five strongest ideas.**

1. **Divisions as engine unit groups.** A division is one `LuaCommandable` group (`LuaSurface.create_unit_group`) with
   a template, a stance and a supply meter. It asks the pathfinder for one path instead of 16, which is the measured
   bottleneck.
2. **Units leave the map when they do not fight.** Garrisons are records inside a City Hall, and troop trains carry
   unit records, not entities. Both cost 0 µs per tick and re-create the units with their stored health.
3. **Supply is an abstract per-division meter paid with real items.** Depots turn supply crates (factory-made from
   iron and coal) into supply points, and trains or haulers fill the depots. Out of supply means attrition, which
   ties every war to the economy and the rails.
4. **Capture instead of destruction.** A City Hall cannot die. At 10 % health it is subdued, a 20-second contest
   follows (the ruin rule that already exists), and the whole city flips force. Writing `LuaControl.force` works for
   every RTS building and unit (probe); 5,000 entities flip in 18.6 ms, sliced to 500 per tick.
5. **A layered nation AI on a deterministic work-unit scheduler.** A strategist (every 10 s), a governor per city
   (today's commander), a war council per nation and a controller per division (today's `army.lua`). Each nation
   gets 0.5 ms per tick, counted in work units, never in wall time. Long plans are resumable state machines in
   `storage` (no coroutines exist in Factorio's Lua).

**Biggest risk: the nation AI's planning competence.** The engine has headroom, but a state-scale match is only
playable if the AI can found cities, lay rails and supply a front on an asymmetric map by script. Today's planner
already fails one expansion on a 256×256 arena (A* gives up after about 17,700 states, `phase3-ai-notes.md`). The
mitigations are prefab city and rail templates on a coarse chunk grid, resumable planners and a planner-first
validation harness (phase W3). The biggest engine-side risk is pathfinder spikes from mass orders, which divisions
and an order queue contain.

**Effort:** about 46 agent-days in three phases (W1 14, W2 14, W3 18), plus about 4 days of computer-use QA.

## 1. Performance envelope (measured)

### 1.1 Method

- **Copy.** `build/scale-probe-war/mods/` holds a copy of `factorio-rts` whose `control.lua` is replaced by a stub,
  so only the prototypes are live (`rts-walker` is the Space Age small-strafer pentapod spider-unit, `rts-drone` a
  `unit`). The probe mod `rts-scale-probe` builds one scenario in `on_init`, so `--create` saves it, and keeps it
  busy while `--benchmark` runs the save. `rts-scale-probe-air` adds two flyer prototypes at the data stage.
- **Runner.** `run.sh <name> '<lua cfg>' <ticks>` creates the save with `--map-gen-seed 4242`, then runs
  `--benchmark <save> --benchmark-ticks N --benchmark-verbose all`. `parse.py` turns the per-tick columns
  (nanoseconds) into mean, p50, p95 and max for `wholeUpdate`, `entityUpdate`, `pathFinder`, `trains`, `chartUpdate`,
  `scriptUpdate` and the rest.
- **Scenarios.** Bounded lab-tile surfaces. The unit probes add four 8-tile water bands with a 16-tile ford every
  128 tiles, so paths are not straight lines. Every unit walks to a random land point and gets a new one on
  `on_ai_command_completed`. The 4 forces are at cease-fire, so units only move. The battle puts two hostile blocks
  of 1,000 units 160 tiles apart, and every unit re-issues `attack_area` on each completion, as `orders.lua` does.
- **Hardware.** Apple M3 Pro, 12 cores, 18 GB. No other Factorio process was running when the runs started, and the
  runs were sequential. Another agent's world-generation probes may have run on the same machine later in the
  session; repeated runs agreed within about 7 % (the two battle runs: 5.13 and 4.78 ms). A mid-range player PC is assumed to be 1.5–2× slower per tick; that factor is an assumption,
  not a measurement. The design target is therefore **≤ 8 ms mean per tick on this machine**.
- **Charting.** A headless server charts nothing, as the Phase 3 notes found (`is_chunk_charted` stayed false after
  49,000 `LuaForce.chart` calls and `chart_all`). The fog probe was repeated in the GUI client with `--load-game`,
  `game.speed = 100` and a wall-clock profiler per 600 ticks: first with the player in the default force, then
  moved into one probe force.
- **Time.** About 55 minutes of probe work, 10 minutes over the 45-minute target; the extra went into the GUI chart
  measurement.

### 1.2 Results in detail

| Probe | Mean | p95 | Max | First 300 ticks max | Dominant columns (mean ms) |
|---|---|---|---|---|---|
| 500 spider-units moving | 1.11 | 1.33 | 1.68 | 27.1 | entity 0.85, pathFinder 0.06 |
| 1,000 spider-units | 2.14 | 2.61 | 5.18 | 25.2 | entity 1.74, pathFinder 0.17 |
| 2,000 spider-units | 4.58 | 7.14 | 11.7 | 28.2 | entity 3.43, pathFinder 0.90 (p95 4.2) |
| 2,000 drones | 1.50 | 2.37 | 5.96 | 5.96 | entity 0.59, pathFinder 0.69 |
| 4,000 drones | 2.86 | 3.32 | 3.86 | 3.9 | entity 1.10, pathFinder 1.51 (saturated) |
| Battle 2 × (600 walkers, 100 heavies, 300 drones), 2,400 ticks | 5.13 | 9.24 | 27.2 | 8.5 | entity 3.32, pathFinder 1.35, particles 0.20 |
| Same battle, second run with damage counters | 4.78 | 8.67 | 21.5 | – | – |
| 20,284 production entities | 0.31 | 0.52 | 0.95 | – | entity 0.11, transport lines 0.09 |
| 81,124 production entities | 1.17 | 2.65 | 4.15 | – | entity 0.81, transport lines 0.23 |
| 40 trains, 10 km, 320 signals | 0.20 | 0.25 | 1.00 | – | trains 0.037 |
| 160 trains, 40 km, 1,280 signals | 0.30 | 0.38 | 3.59 | – | trains 0.13 |
| Fog, 4 AI forces, 2000², 160 radars, 600 drones, scripted re-chart | 0.56 | 1.48 | 18.3 (probe's own chunk count) | – | pathFinder 0.19, entity 0.17, chart 0 |
| Fog in the GUI, player in force 1: units only / + radars and re-chart / + `chart_all` | 0.45–0.52 / 0.66–0.75 / 0.73–0.76 (wall clock) | – | – | – | charted chunks 0 / 2,846 / 4,900 |

Marginal cost per entity, from the means minus the 0.18 ms baseline:

| Entity | µs per tick |
|---|---|
| Moving spider-unit (5 legs), pathfinding included | 1.9–2.2 (entity update alone 1.7) |
| Moving `unit` | 0.66 |
| Unit in battle (mixed army, average over the fight) | 2.4 |
| Train (5 carriages, shuttling with signals) | 0.8–0.9 |
| Active production entity (belt, inserter, assembler mix) | 0.006–0.012 |
| Force change of one entity (capture) | 3.7 (one-off) |

Other probe facts:

- **Capture.** `entity.force = other` succeeded for `assembling-machine-2`, `roboport`, `storage-chest`,
  `gun-turret`, `fast-inserter`, `transport-belt`, `substation`, `radar`, `stone-wall`, `rts-walker`, `rts-drone`,
  `rts-hub`, `rts-stockpile`, `rts-barracks` and `rts-command-center`. A block of 5,000 belts, inserters and
  assemblers was found and flipped in 18.6 ms.
- **Air units.** A `unit` with `collision_mask = {layers = {}}` (`probe-flyer`) crossed a wall line and a 40-tile water
  band: 5 of 5 within 10 s. A spider-unit whose legs have an empty mask (`probe-spider-flyer`) crossed too, 5 of 5
  within 20 s. `rts-drone` and `rts-walker` got failed commands and stayed put.
- **Damage events.** The 2,000-unit battle peaked at 4.5 `on_entity_damaged` events per tick (deaths 1,216 in
  40 s). A per-hit Lua rule such as Armor II/III or Shield costs well under 0.05 ms per tick at this size.
- **Order churn.** The battle produced 37,000 `attack_area` completions in 30 s, about 20 per tick, and each
  re-issue is a path request. That is where its 1.35 ms of pathfinding came from.
- **Trains.** Train stops and signals were placed by script. A rail signal's `direction` faces the oncoming train
  (an eastbound train is guarded by a west-facing signal on the south side), and a one-sided pair makes the line
  one-way, which shows up as `no_path`.

### 1.3 What the numbers mean

1. **The pathfinder is the ceiling, not the entity count.** Spider-unit path requests are not smoothed: the first
   tick after 1,000–2,000 simultaneous orders cost 24–26 ms in `pathFinder` alone, and the next two ticks 14 and 9 ms.
   The `unit` pathfinder spreads its work but saturates near 1.5 ms per tick (`PathFinderMapSettings.max_work_done_per_tick`).
   Then units wait for paths: sampled units covered 56 tiles in the first 10 s instead of 115. Path latency, not
   frame time, is what a player feels in mass orders.
2. **A spider-unit costs three `unit`s.** Legs are simulated. Cheap mass units (drones, planes) should be `unit`;
   the iconic mechs stay spider-units, in smaller numbers.
3. **Battles hitch.** The mean stays near 5 ms, but 7 of 2,400 battle ticks exceeded 16.7 ms, up to 27 ms, all in
   `entityUpdate` (mass deaths, corpses, re-targeting). On a 2× slower PC a 2,000-unit battle would hitch visibly; one
   of 800 would not.
4. **Production is nearly free.** 81,000 working entities cost 1.2 ms. Cities can be real factories; UPS is not the
   reason to abstract them. The player's attention and the AI's ability to build them are.
5. **Trains are nearly free.** About 0.9 µs per train per tick, 0 ms when parked. Rail-heavy logistics and wars over
   rails are affordable. A junction-heavy network (train pathfinder load) was not measured; `trainPathFinder` stayed
   at 0 on straight shuttles.
6. **Chart cost exists only for forces with players.** AI nations are never charted, on a server or a client. They
   cost nothing, but `LuaForce.is_chunk_charted` and `is_chunk_visible` tell an AI nothing, so AI vision must stay
   script-based, as `scout.lua` is today. One human force on a 2000² map with 40 radars and a `fog.lua`-style
   re-chart costs 0.2 ms per tick. `chart_all` of all 4,900 chunks finished within 600 ticks for 0.03 ms more. Four
   human nations would cost at most 0.8 ms per peer if every peer charts every player force; multiplayer was not
   measured.

### 1.4 Budget and design consequences

Budget for a 4-nation match on the M3 Pro (target ≤ 8 ms mean, no order-burst tick above 16 ms):

| Item | Assumption | ms per tick |
|---|---|---|
| Engine baseline | – | 0.2 |
| Field armies moving | 1,200 units: 60 % spider-units, 40 % `unit`s (300 per nation) | 1.9 |
| One large battle on top | 800 units engaged, about 2.5 µs each | 2.0 (hitches up to about 8–10) |
| Production | 4 nations × 15,000 entities | 0.6–0.8 |
| Trains | 80 trains | 0.07 |
| Nation AI | 4 × 0.5 ms cap | ≤ 2.0 |
| Rest of the mod | today 0.15–0.30 ms; ×2 for divisions, territory, supply | 0.5 |
| Chart (clients only) | 1 human force | 0.2 |
| **Total** | | **about 7.5** |

Consequences:

- **Units per nation.** A field-army cap of about 300 supply (about 200–300 units) per nation in a 4-nation match,
  about 500 in a 1v1. Scale the cap as 1,200 field units divided by the number of nations. Garrisons and troops in
  transit do not count against the UPS budget, because they are not entities.
- **Division size.** 16 units by default, between 8 and 24. That gives about 12–18 divisions per nation and one
  path request per division move.
- **Order pacing.** A path-request queue in `orders.lua`: at most about 100 spider-unit requests per tick, ordered by
  division, plus re-targeting at most once a second per division instead of on every completion. A 1,000-unit order
  then costs about 10 ticks of 2.5 ms instead of one 25 ms tick.
- **Battle size.** The war AI keeps engagements to about 800 units, and wide fronts break into several fights.
- **Cities.** Production, logistics, power, rails and defences are real entities (15,000 per nation are cheap).
  Population, housing, services, garrisons, unit transit, supply and morale are numbers per city or per division,
  updated every 1–5 s.
- **Map size.** 2000×2000 is the recommended default: about 4,000 chunks, 1.1 MB save on lab tiles. 4000×4000 has
  4 times the chunks; chart work stays proportional to radars and units, but generation time and save size with
  real terrain were not measured here (see the world study).

## 2. Warfare at state scale

### 2.1 Divisions: formations commanded as one object

**Data (in `storage.divisions`).**

```lua
storage.divisions[id] = {
  id = 7, nation = "rts-ai-2", name = "7th Line", template = "line",
  members = {[unit_number] = true}, group = LuaCommandable,  -- engine unit group
  stance = "aggressive",           -- aggressive | defensive | hold | skirmish | evade
  order = {kind = "attack_move", target = {x, y}, front = 3},
  supply = 82,                     -- supply points 0..100 (2.2)
  home = city_id, reinforce = true, strength = 0.9, engaged_tick = 123456,
}
DIVISION_TEMPLATES = {             -- data, like balance.lua
  line     = {walker = 10, heavy = 4, artillery = 2},
  mobile   = {raider = 8, drone = 8},
  siege    = {artillery = 6, heavy = 4, walker = 6},
  air_wing = {scout_plane = 2, bomber = 6},
}
```

**Engine side.** Each division owns one script-driven group: `LuaSurface.create_unit_group{position, force}`,
`LuaCommandable.add_member`, `set_command` with `go_to_location` or `attack_area`, and `start_moving()` so the group
does not wait for stragglers. The group plans one path, and members fight individually when distracted
(`defines.distraction.by_enemy`). `on_unit_group_finished_gathering` and `on_ai_command_completed` (with the group
number) drive the controller. Groups need no `ai_controllable` (spike decision 4). `UnitGroupMapSettings.max_unit_group_size`
only limits automatic groups. RTS units already carry `UnitAISettings.join_attacks = false` (`prototypes/units.lua`),
so the engine does not pull them into groups of its own.

**Fallback (risk M).** Spider-units in groups were created in the spikes (decision 4) but their movement quality was never
checked. If it is poor: leader-follower. Only the division's leader paths to the target; every 60 ticks the others get
a short `go_to_location` to the leader's position plus their formation slot (`orders.lua` already computes slots).
Short paths are cheap and use the path cache (`PathfinderFlags.cache`).

**Arrival.** When the group completes, members move to formation slots (`line`, `column`, `wedge`) around the
target, facing the enemy, and then get `stop` (hold, still returns fire). That uses `orders.lua` formation code with
entity lists, which is how the AI already commands units.

**Stances** map to engine behaviour without per-unit scripts:

| Stance | Engine behaviour | Script (per division, every 60 ticks) |
|---|---|---|
| Aggressive | `attack_area` legs, distraction by enemy, pursuit from the prototype (`max_pursue_distance` 50) | re-target the nearest enemy group |
| Defensive | as aggressive inside the anchor radius | members farther than 30 tiles from the anchor are called back |
| Hold | `stop` at the slots | none |
| Skirmish (raiders) | `go_to_location`, distraction by enemy | fall back 20 tiles when a heavier division engages |
| Evade (supply, scouts) | distraction `none` | re-route away from known enemies |

**Reinforcement.** Each division keeps its template. Each city's barracks queue serves the nation's divisions with
the largest deficit within that city's supply area. A new unit joins the city's replacement pool, and replacements
travel to their division as a small group, or by troop train (2.6). With `reinforce = false` a division keeps its
losses. The SC-style barracks rally stays for units that belong to no division.

### 2.2 Supply lines and depots

- **Supply points (SP)** per division, 0–100. Consumption per minute: 0 when idle in own territory, 2 when moving,
  8 when engaged, +2 in enemy territory.
- **Depot** (`rts-depot`): a stockpile with a small roboport like a hub, buildable in own territory or within 3 chunks
  of it. Within 2 chunks of a depot with stock, a division regains 20 SP per minute and the depot's network pays real
  items: 1 supply crate per 10 SP. The factory makes a crate from iron plates and coal (a `balance.lua` recipe), so a
  war costs the economy every minute it lasts.
- **Feeding depots.** Supply trains to a depot station (a train stop next to it) or haulers on a route. Both already
  have a cost model: trains 0.9 µs per tick, haulers are existing `rts-hauler` spider-vehicles.
- **Supply wagon.** A hauler attached to a division carries crates in its trunk, feeds the division in the field and
  cancels territory attrition. It is the Rise of Nations supply wagon, built from what exists.
- **States and penalties.**
  - *Supplied* (≥ 50 SP): normal.
  - *Low* (1–49): no Armor II/III healing, the HUD bar turns amber, and the AI starts no offensive with the division.
  - *Out* (0): attrition of 1.5 % of max health every 10 s (a `LuaEntity.health` write, `die()` at 0). Units of the
    `unit` class also get a slowdown sticker (`StickerPrototype.target_movement_modifier`).
  - Stickers do not attach to spider-units and `LuaEntity.speed` is not writable for them (abilities notes). So
    spider-units out of supply get attrition and an order lock (attack orders refused, as `orders.locked_reason` does
    after the match). A damage penalty would need "exhausted" prototype variants swapped in once, after 60 s at 0 SP.
    Swapping a spider-unit re-creates its legs. Keep this optional and decide in playtests.
- **Cost.** All of this runs per division every 60 ticks: about 15 divisions × 4 nations × a few µs.

### 2.3 Territory and attrition

- **Territory grid.** `storage.territory[cx * 4096 + cy] = nation`, one entry per chunk: about 4,000 chunks at
  2000², 16,000 at 4000². Sources are a City Hall (radius 4 chunks, growing with city size), forts and depots
  (radius 2) and captured cities. Where sources overlap, the stronger influence wins (Rise of Nations borders). The grid
  is recomputed only when a source changes, never per tick.
- **Rendering.** Border edges are merged into runs and drawn with `rendering.draw_line` with `render_mode = "chart"`
  for the map view and `"game"` for the world, in the nation's colour. That is a few hundred objects per nation, not
  one per chunk.
- **Attrition.** A division whose centre lies in enemy territory, without a supply wagon and more than 2 chunks from
  its own depot, loses 1 % of max health per 10 s (Rise of Nations rule). A Logistics technology halves it.
- **Building rule.** Buildings go only into own territory or within 2 chunks of a forward depot. Fronts then mean
  something, and turret creep across the map is impossible.

### 2.4 Fronts and fortification belts

- **Fronts.** For each pair of nations at war, the border edges where their territories touch, split into segments of
  4–6 chunks (128–192 tiles). Segments are recomputed with the territory.
- **Holding a segment.** A division with the order `hold_line` spreads its formation slots along the segment's
  chord, stance hold or defensive. The player assigns by dragging along the border on the map (section 3); the AI's
  war council assigns by threat (4.4).
- **Fortification belt tool.** Two clicks or a drag on the map define a polyline inside own territory. The planner lays
  out a belt as ghosts: a stone-wall line with gates where rails and roads cross, a turret every 12 tiles 3 tiles
  behind the wall, an artillery emplacement every 60 tiles and a depot behind the middle. The ghosts are built like
  any other: CC or hub robots, the Commander's field construction, or an **engineer** (a Commander-like spider-vehicle
  with a personal roboport, one or two per nation). The cost is real bricks, iron and magazines.
- **Turret focus.** 2.0 turret priority lists (`LuaEntity.set_priority_target`, `ignore_unprioritised_targets`) let a
  belt shoot artillery walkers and siege units first.
- **The AI** uses the same belt planner on segments whose threat score stays high for 2 minutes.

### 2.5 Cities: siege and capture

- **A city** is a City Hall (the CC's successor: roboport, stockpiles, power core, high health), its territory, its
  districts (real production) and its numbers (population, garrison, unrest). City health is the City Hall's health;
  other buildings take damage normally.
- **Garrison as numbers.** Units ordered into a city (right-click the City Hall with a division) are destroyed as
  entities and stored as records (prototype, health fraction, division). A garrison costs 0 µs per tick. It adds
  defence through hidden turret entities around the City Hall: one turret is enabled per 4 garrison points
  (`LuaEntity.disabled_by_script`). On a sortie, or automatically when the City Hall drops below 50 %, the units are
  re-created from their records at the City Hall.
- **Subdue.** An `on_entity_damaged` handler filtered to the City Hall name (a few events) clamps its health at 10 %
  and marks the city subdued. The City Hall cannot die.
- **Capture.** A subdued city is captured after 20 s with attacking military units within 24 tiles of the City Hall
  and no defending ones. The ruin already runs exactly this contest (`README.md`, "The ruin"). On capture:
  1. find the defender's entities in the city's territory (`find_entities_filtered{area, force}`) and flip
     `entity.force` in slices of 500 per tick (measured 3.7 µs each, so about 1.9 ms per tick);
  2. destroy the old owner's ghosts and item-request proxies there;
  3. unrest: production is off for 60 s (`disabled_by_script` on assemblers, labs and barracks), and the City Hall
     restarts at 25 % health;
  4. the garrison is lost; the stockpiles' contents change hands with the chests.
- **Capitals.** Capturing a capital is the biggest war-score item. The loser moves its capital to its largest city
  and loses research speed for 5 minutes.
- **Razing.** The attacker may raze instead (every city building dies over 30 s): less war score, no ownership, and
  the territory becomes free.
- **Not tested:** robots in flight, logistic requests and construction orders of a roboport that changes force;
  trains standing in a captured station.

### 2.6 Trains at war

- **Troop trains.** Units at a station *embark*: their records go into a troop wagon (a cargo-wagon variant), and the
  entities are destroyed. At the destination they *disembark*: they are re-created with their stored health and
  rejoin their division. A wagon holds 16 supply. Units in transit cost 0 µs. A destroyed wagon kills its cargo.
  This is strategic mobility at no UPS cost.
- **Supply trains** carry crates to depot stations. The probe ran 40 such trains for 0.04 ms per tick.
- **Artillery trains.** The vanilla `artillery-wagon` (`ArtilleryWagonPrototype.gun`, `disable_automatic_firing`)
  with RTS shells. Targeting goes through the existing Artillery strike code (scripted projectiles), so it does not
  depend on vanilla auto-targeting rules between player forces (`LuaEntity.artillery_auto_targeting` exists, its
  behaviour against a player force is untested).
- **Armoured trains.** Locomotive and wagon variants with high `max_health` and resistances. They hit units on the
  track with vanilla train impact damage, which makes rail lines dangerous to stand on.
- **Sabotage and repair.** Rails are not military targets: units attack them only on an explicit order. Raiders get a
  "sabotage" order that targets rails and signals in an area. `LuaForce.create_ghost_on_entity_death` makes rebuild
  ghosts. Cut rails reroute trains; train pathfinder cost on large networks is not measured yet.

### 2.7 Air units and scouting

- **Feasibility: verified.** A `unit` with an empty collision mask flies over walls and water (1.2). Use the `unit`
  class: 0.66 µs instead of 2.2, stickers work and `LuaEntity.speed` is writable.
- **Prototype.** `UnitPrototype.render_layer = "air-object"`, combat-robot graphics (defender or destroyer
  animations) with a shadow, `radar_range` 2 for scouts, `affected_by_tiles = false`.
- **Anti-air.** A `trigger-target-type` "air" (`TriggerTargetType`) in each plane's `trigger_target_mask`. Ground
  turrets exclude it (`TurretPrototype.ignore_target_mask`), an AA turret targets only it
  (`TurretPrototype.attack_target_mask`). Mobile units have no target mask: walkers will shoot planes and drones will
  chase them. Balance it with resistances, or give ground weapons' damage triggers a mask without "air" (risk M:
  wasted shots).
- **Roles.** Scout plane (fast, unarmed, reveals), bomber (×2 against buildings, slow), interceptor (×3 against air).
  An airfield building rearms and supplies them; a plane more than N seconds from an airfield returns, or crashes when
  its supply runs out.
- **Scouting.** Radars (`RadarPrototype.max_distance_of_sector_revealed`, `max_distance_of_nearby_sector_revealed`),
  Scanner sweep, scout planes, raiders as cavalry. Human forces see through the chart; the AI sees through script
  sight checks (`scout.lua` generalised), because AI forces are never charted (1.3).
- **Naval:** out of scope; water stays a barrier, crossed by fords and bridges.

### 2.8 War goals, war score and peace

- **Declaring war** names goals: *conquest* (capture named cities), *capital* (hold the enemy capital for 10 min),
  *tribute* (force a payment), *border* (take a region).
- **War score** per war: + city captured (by size), + capital held per minute, + enemy divisions destroyed (by supply
  cost), + enemy production lost; − the same for own losses. **War weariness** grows with losses and duration.
- **Peace.** Treaties are white peace, ceding a city (a force flip as in 2.5), tribute (items per minute delivered to
  a border trade station) or vassalage. A treaty sets `LuaForce.set_cease_fire` both ways. An alliance adds
  `set_friend` and `share_chart`.
- **Match victory (lobby):** *Conquest* (every capital captured or every rival surrendered), *Territory* (70 % of the
  map for 10 min), *Economic* (a wealth score, or a megaproject chain finished first), *Score* at a time limit.
  Annihilation is no longer the only end.

## 3. Command UX at state scale

- **Selection hierarchy.** A click selects a unit; a double click selects its division; a division card in the HUD
  shows the template, strength and supply bars, stance and order. Ctrl+1..5 bind divisions, not loose units.
- **Division orders.** Move, attack-move, hold line, garrison, siege, embark, set stance, set formation, reinforce on
  or off. Orders apply to the group (2.1); micro stays possible: *detach* turns a division into SC-style loose units,
  *rejoin* takes them back.
- **Strategic map.** In the map view the RTS cursor still works: selection tools work in map view (changelog 1.1.0,
  and map view is the remote controller in 2.0). Right-click on the map orders the selected divisions. The minimap
  already jumps the camera (spike #6: `on_gui_click` on `minimap` elements); a right click on it can order divisions by
  converting the element's click position with its `position` and `zoom` (risk L–M).
- **Front assignment.** Drag along a border on the map with divisions selected: they split the segment between them,
  stance hold.
- **Map icons.** Division icons, arrows for current orders and front lines are drawn with `render_mode = "chart"`,
  updated every 60 ticks.
- **Production to divisions.** Each city has "reinforces: nearest / named division / pool". New units join the
  division with the largest deficit in range, otherwise the city's pool.
- **Alerts.** Grouped by kind and priority: city under siege, front breached, division out of supply, train or depot
  lost, research done. F3 cycles all alerts; Shift+F3 cycles the top category. One alert per division or city, never
  per unit. Map pings use chart-mode rendering.
- **Single player:** pause-and-order (`game.tick_paused`) and game speed in the F10 menu.

## 4. The nation AI

### 4.1 Architecture

| Layer | One per | Cadence | Decides | Built from |
|---|---|---|---|---|
| Strategist | nation | 600 ticks | war and peace, alliances, research direction, expansion targets, budget split (economy, military, research) | new; doctrine becomes a national character |
| Economic planner | nation | sliced jobs | city sites, chain plans, rail network, trade | new + `layout.lua` planners |
| Governor | city | 60–120 ticks, round robin | the city's build order, production, research feed | today's `commander.lua`, `build_order.lua`, `construction.lua`, `mix.lua`, `tech.lua`, `hubs.lua` |
| War council | nation | 120 ticks | fronts, threats, division allocation, operations | `army.lua` (pool, attack, defend) generalised |
| Division controller | division | 30–60 ticks | stance, re-targeting, retreat, resupply | `army.lua` groups + `orders.lua` |
| Intelligence | nation | 300 ticks | known cities, divisions, rails; decay; estimates | `scout.lua` generalised |

A nation's state is a blackboard in `storage.nations[force]`: cities, territory, stock and flows per city, divisions,
fronts, intelligence, treaties. The layers read it and write orders into it; only governors and division controllers
touch entities.

Today's doctrines (economic, aggressive, turtle) become **national characters**: weights for aggression, expansion,
trade affinity, fortification bias and risk tolerance, drawn by the same seeded draw (`doctrine.lua`).

### 4.2 Data-driven plans

All plans are Lua tables, as `orders_data.lua` is today:

- **City templates** by role (capital, mining town, industrial, fortress, trade post): districts as calibrated layouts
  relative to the City Hall, with build orders per stage (village → town → city).
- **Chains** from `balance.lua` recipes, so the planner knows what a city needs and produces.
- **Division templates** (2.1) and their production cost.
- **Operations**: phases with conditions and timeouts (concentrate, advance, siege, capture, consolidate).
- **Utility weights** per national character and difficulty.

### 4.3 Region scoring, city sites and rails on asymmetric maps

- **Grid.** At match start, a coarse grid of chunk cells (63×63 at 2000²) is scored in a sliced job: ore by type and
  amount (from the map generator's patch list, at no query cost), buildable fraction (`count_tiles_filtered` for
  water), passability, and the distance from the capital by Dijkstra with rail-cost weights.
- **Site score** for a city at cell *c*:
  `S = Σ_ore w_ore × need_ore × min(amount, cap) × decay(dist) + w_build × buildable − w_rail × rail_cost(c)
  − w_front × exposure(c) + w_choke × choke(c) − w_overlap × overlap(c)`.
  The need vector comes from planned chains: a nation short of copper weights copper double. Exposure is the distance
  to rival capitals and territory. Sites are taken greedily with a spacing of at least twice the territory radius.
  Aggressive characters weight contested central regions; turtles weight compact, closed territory.
- **Claims.** A site claim is intent, not a lock: the first City Hall wins, as `patch_claims` works today between AI
  commanders.
- **Rails.** A trunk tree (minimum spanning tree over cities and mining outposts), each edge routed by A* on the cell
  grid (water impassable, cliffs and forests costly, rival territory very costly), then refined to tiles with
  Manhattan prefabs: straight rails, a 90° curve blueprint, a T-junction blueprint and a station blueprint. Single
  track with passing sidings every 400 tiles first; double track for the capital trunk later. Prefabs are placed as
  ghosts and revived with item debit by the existing construction code. The rail study owns the rail mechanics; the
  AI consumes them.

### 4.4 Military AI

- **Threat per front segment:** the estimated enemy strength near it (intelligence) times the value of what lies
  behind it (cities, depots, rails). Defensive divisions are allocated in proportion, with a reserve of 25 %.
- **Offensive operations.** The objective is the city with the best value-to-cost ratio. Value: size, production,
  capital bonus. Cost: estimated defence, distance and supply feasibility. Preconditions: a force ratio of at least
  1.5 (character-dependent) and a supply route (a depot within 3 chunks of the path, or a rail spur to build).
  Phases with timeouts; abort when the force ratio drops below 1.
- **Raids** (aggressive characters): fast divisions against rails, depots and haulers, extending today's harass.
- **Air:** scout patrols over fronts; bombers against depots before an offensive.
- **Siege:** artillery division plus line divisions; garrison sorties are expected and answered.
- **Battle size:** an operation never commits more than 800 units in one area (1.4).

### 4.5 Diplomacy

- A relation score per pair: + trade value, + common enemy, − border friction (border length and incidents),
  − fear (power ratio), plus character.
- **War** when the target's value is high, the power ratio is above 1.3 and no bigger threat exists elsewhere.
- **Peace:** offered when war score is negative or weariness passes a threshold; accepted when the terms are better
  than the expected outcome of fighting on.
- **Balance of power:** when one nation exceeds 40 % of total power, the others ally against it.
- **Trade:** surplus items for deficit items at scarcity-based rates, delivered by train to a border trade station.
- Every decision derives from game state and seeded generators, so a replay with the same seed repeats it (section 5).

### 4.6 Time slicing and the 0.5 ms budget

- **Scheduler.** One `on_tick` loop gives each nation a budget of work units per tick (about 400; one unit is
  calibrated offline at about 1 µs with `PERF=1`). A job is `{kind, state, cost}` in `storage`. Long jobs (A*,
  region scoring, city layout, rail routing) keep their open and closed sets as plain arrays and resume next tick.
  Factorio's Lua has no `coroutine`, and closures cannot be saved, so state machines are the only resumable form.
- **Never budget by wall clock.** Profilers differ between peers. `LuaProfiler` cannot be read as a number anyway, only
  logged. Budgets are counted in deterministic units: A* states, entities examined, cells scored.
- **Cadence staggering** by nation index, as today (20 ticks per force).
- **Expected costs.** Strategist about 50 µs per run (600 ticks). Governors as today, about 0.05 ms per tick per
  city-commander. War council and controllers about 0.05 ms per tick. Planners take what remains of the 0.5 ms cap.
  Today's four commanders use 0.20 ms per tick in total (`phase4-integration-notes.md`).

### 4.7 Difficulty without cheating

| Knob | Easy | Normal | Hard |
|---|---|---|---|
| Intelligence age before acting | 60 s | 30 s | 10 s |
| Concurrent operations | 1 | 2 | 4 |
| Site candidates and A* state caps | low | medium | high |
| Build pace (exists today) | 6 s | 3 s | 2 s |
| Micro: focus fire, retreat, kiting | off | basic | full |
| Orders per minute per division | 2 | 6 | 12 |

Vision stays honest at every level. Today's hard bonuses (+50 % stock, +25 % mining, a free unit every 4th spawn,
full vision) move to an optional, clearly labelled "Brutal" level.

## 5. Save/load, multiplayer and determinism

**Rules for script-heavy designs** (from `doc-html/auxiliary/libraries.html` and `storage.html`):

1. All game-affecting state lives in `storage`: plain data, tables and LuaObjects only. No functions or closures, and
   `storage` must not be written in `on_load`.
2. Event and `on_nth_tick` registration happens while `control.lua` loads, identically on every load. `events.lua`
   already enforces this.
3. Randomness: `math.random` is deterministic but shares the map's generator with the game and every mod, so a
   replay drifts. Each subsystem uses `game.create_random_generator(seed)` with a seed derived from the map seed,
   match id and nation (as `doctrine.lua` does), or a seed and LCG state kept in `storage` (as the probe does).
4. No decision depends on wall time (`LuaProfiler`), on per-player client state (zoom, resolution, render mode), or
   on chart state (`is_chunk_charted` and `is_chunk_visible` are empty for AI forces and differ by which forces have
   players).
5. Module-local caches only memoise values derived from game state within one tick, so a client that joins starts
   with an empty cache and computes the same.
6. `pairs` order is deterministic (insertion order) but depends on history; sort before a decision that iterates
   unrelated keys if the iteration order changes the outcome after a reload rebuilds a table.
7. Time-sliced jobs keep their whole state in `storage` and resume after a load in the middle of a job.
8. Save size: chunk-level grids (4,000–16,000 entries) are fine; per-tile tables over a 2000² map (4 million) are not.
   Today's per-tile reservation table per commander (`C.reserved`) must become chunk-bucketed before it is multiplied
   by a dozen cities.

**How the current code holds up.**

- **Good.** One static event bus (`events.lua`) with profiling that only reaches the log. Every module keeps its
  state in `storage`. Module caches are per-tick memos derived from game state (`hud.lua` `supply_cache`,
  `construction.have`) or from static data (`supply.lua` `cost_cache`). The doctrine draw is seeded. There is no
  `math.random` in `scripts/`. The save/load check, the restart audit (484 → 94 LuaObjects in `storage`, none
  invalid) and two validation matrices passed with zero errors.
- **Watch.** The AI's A* runs synchronously with state caps (up to 0.3 s once in a 7-minute game); at state scale it
  must become resumable. `fog.lua` charts only forces with players, which is right, and must stay out of any game
  decision.
- **Not tested.** No multiplayer session has been run; desyncs are untested in practice.
- **Test to add.** A heavy-mode run (`/toggle-heavy-mode` in a GUI session: save, load and compare every tick) during
  a 10-minute AI-vs-AI state match, plus a two-client LAN session in the computer-use QA wave.

## 6. Feasibility and risk register

| Mechanic | API (runtime / prototype) | Evidence | Risk |
|---|---|---|---|
| Divisions as groups | `LuaSurface.create_unit_group`, `LuaCommandable.add_member`, `set_command`, `start_moving`, `defines.command.group`, `on_unit_group_finished_gathering`, `UnitAISettings.join_attacks` | docs; spike decision 4: groups created without `ai_controllable` | M: spider-unit group movement untested; leader-follower fallback |
| Order queue against spikes | `LuaCommandable.set_command`, `PathFinderMapSettings.max_work_done_per_tick`, `PathfinderFlags.cache` | probe: 25 ms tick per 1,000 spider orders | L once queued |
| Supply penalties | `LuaEntity.health` (RW), `LuaEntity.die`, `StickerPrototype.target_movement_modifier` (units only), `LuaEntity.speed` (units only) | docs; abilities notes (no stickers on spider-units) | M for spider-units |
| Territory display | `LuaRendering.draw_line` with `render_mode = "chart"`, `LuaForce.add_chart_tag` | docs; chart rendering used by the mod | L |
| Capture | `LuaControl.force` (RW), `LuaSurface.find_entities_filtered{force}`, `LuaEntity.disabled_by_script` | probe: 15 entity types flip; 5,000 in 18.6 ms | L; M for robots in flight |
| Garrisons, troop trains | `LuaSurface.create_entity`, `LuaEntity.destroy`, records in `storage` | pattern used by barracks spawns | L |
| Fort belts | `LuaSurface.create_entity{name = "entity-ghost"}`, `LuaItemCommon.build_blueprint`, `LuaEntity.set_priority_target` | AI construction in use since Phase 3 | L |
| Trains | `straight-rail`, `train-stop`, `rail-signal`, `LuaTrain.schedule` (`TrainSchedule`, `ScheduleRecord.station`/`rail`), `LuaTrain.manual_mode` | probe: 160 trains, stops and signals by script | L |
| Artillery trains | `ArtilleryWagonPrototype.gun`, `disable_automatic_firing`, `LuaEntity.artillery_auto_targeting` | docs only | M |
| Air units | `UnitPrototype.collision_mask = {layers = {}}`, `render_layer`, `TriggerTargetType`, `EntityPrototype.trigger_target_mask`, `TurretPrototype.attack_target_mask` / `ignore_target_mask` | probe: flyers cross walls and water | L to fly; M for ground units wasting shots |
| Human fog | `LuaForce.chart`, `chart_all`, `RadarPrototype` ranges | GUI probe: +0.2 ms per human force | L |
| AI vision | script sight checks (`scout.lua`) | AI forces are never charted (probe) | L |
| Diplomacy | `LuaForce.set_cease_fire`, `set_friend`, `share_chart`, `on_force_cease_fire_changed` | docs; cease-fire used by `match.lua` | L |
| Resumable planners | `storage`, no `coroutine` (`libraries.html`) | design | M: engineering effort |
| Determinism | `game.create_random_generator`, deterministic `pairs`, `math.random` | docs; save/load checks pass | M until multiplayer is tested |
| 4000² maps | `LuaSurface.request_to_generate_chunks`, chunk grids | 2000² probed (0.5 s on lab tiles) | M: real-terrain generation not measured |
| Nation AI competence | all of the above | Phase 3/4 AI on 256²–512² | **H**: biggest risk |

## 7. Phased plan

### Phase W1: armies as divisions on a big map (about 14 agent-days)

Scope: divisions (groups plus the leader-follower fallback), templates, stances, reinforcement flow, the division HUD
and orders, the path-request queue, the territory grid and its rendering, supply (depots, crates, supply points,
attrition, supply wagons), City Hall, garrison records, subdue and capture, and a state-scale stress scenario in
`tools/autotest-run.sh`.

| Work | Agent-days |
|---|---|
| Division model, groups, controller, stances, fallback | 4 |
| Path-request queue and re-target throttle in `orders.lua` | 1 |
| Territory grid, rendering, building rule, attrition | 2 |
| Supply: depot, crate recipe, supply points, supply wagon | 2 |
| City Hall, garrison, subdue, capture with sliced force flip | 3 |
| Division HUD and orders, stress scenario, profiling | 2 |

Acceptance:

1. 4 nations × 12 divisions × 16 units on a 2000² map, all moving: mean ≤ 6 ms per tick and no tick above 20 ms
   from orders (`--benchmark` of a saved stress match on the M3 Pro).
2. An order to 1,000 units issues at most 100 path requests per tick (queue log).
3. A division at 0 SP loses 1.5 % health per 10 s; a depot resupplies it and its network loses the crates.
4. A 3,000-entity city flips within 8 ticks; no entity of the old force remains in its territory; production resumes
   after 60 s; a save during the capture loads and finishes it.
5. 40 units garrisoned means 40 fewer unit entities; a sortie re-creates them with their stored health.
6. `saveload-check.sh` and the restart audit pass; the validation matrix has 0 Lua errors.

### Phase W2: fronts, trains at war, air and war goals (about 14 agent-days)

Scope: fronts, the front HUD and front assignment; the fortification belt planner and engineers; troop trains
(embark and disembark), supply trains to depots, artillery and armoured trains; air units (flyer prototypes,
anti-air, airfield, scout plane, bomber); war declaration, goals, war score, weariness, treaties and match victory
modes; strategic map orders (map view and minimap right-click); alert routing.

| Work | Agent-days |
|---|---|
| Fronts, front HUD, assignment by drag | 2 |
| Fort belt planner, engineer unit | 3 |
| Troop, supply, artillery and armoured trains | 3 |
| Air units, anti-air, airfield | 2 |
| War goals, war score, treaties, victory modes | 2 |
| Map and minimap orders, alerts | 2 |

Acceptance:

1. Headless: a troop train carries 2 divisions 1,500 tiles; the unit entity count drops by 32 in transit and the
   units come back with the same health.
2. A scout plane crosses water and walls in the mod (the probe repeated with the real prototype); an AA turret hits
   planes and a gun turret does not.
3. A fort belt along a 200-tile border is built within 3 minutes with the right item debit.
4. A war with the goal "capture 2 cities" ends in a treaty when the goal is met; cease-fire state matches the treaty;
   the results window shows the war score.
5. Map-view orders, front drag and minimap right-click pass new steps in the computer-use GUI protocol.

### Phase W3: the nation AI (about 18 agent-days)

Scope: the work-unit scheduler and resumable jobs; region scoring and city sites; governors per city (the commander
generalised to city templates); the rail network planner on prefabs; trade; the war council, operations and division
controllers; diplomacy; difficulty knobs; a state-scale AI-vs-AI autotest.

| Work | Agent-days |
|---|---|
| Scheduler, resumable A*, chunk-bucketed reservations | 3 |
| Region scoring, site choice, city templates, governors | 5 |
| Rail planner on prefabs, stations, trade routes | 4 |
| War council, operations, controllers | 3 |
| Diplomacy, characters, difficulty knobs | 1 |
| State-scale autotest, tuning across seeds | 2 |

Acceptance:

1. AI vs AI, 4 nations, 3 seeds of an asymmetric 2000² map: every nation founds at least 3 cities and links them by
   rail by minute 30; at least one war is declared and one peace signed by minute 60; 0 Lua errors.
2. AI time ≤ 0.5 ms per tick per nation on average and ≤ 3 ms in any tick (`PERF=1`).
3. Saves at minutes 10, 30 and 50 load and continue without errors. Two runs with the same seed log the same city
   sites, wars and treaties.
4. Heavy mode for 10 minutes of a state match shows no desync.
5. Difficulty levels differ without resource bonuses: hard beats normal in at least 7 of 10 seeded AI-vs-AI matches.

**Total:** about 46 agent-days, plus about 4 for a computer-use QA wave (GUI protocol, two-client LAN session).
W1 does not depend on the sibling studies; W2 needs the rail mechanics; W3 needs the city and economy designs.

## Appendix: probe files and how to rerun

| File | What it is |
|---|---|
| `build/scale-probe-war/run.sh` | `run.sh <name> '<lua cfg table>' <ticks> [air]`: writes `cfg.lua`, creates the save, runs `--benchmark --benchmark-verbose all`, prints the probe lines |
| `build/scale-probe-war/parse.py` | `python3 parse.py results/<name>-bench.out [skip-ticks]`: mean, p50, p95, max per timing column |
| `build/scale-probe-war/mods/rts-scale-probe/control.lua` | Scenarios `units`, `combat`, `static`, `trains`, `fog`, `air`, `capture`, `empty` |
| `build/scale-probe-war/mods/rts-scale-probe-air/data.lua` | `probe-flyer` (`unit`, empty collision mask), `probe-spider-flyer` (legs with empty masks) |
| `build/scale-probe-war/results/` | Saves, create and benchmark logs, per-tick CSV output of every run |

Configurations used:

```sh
cd build/scale-probe-war
./run.sh spider2000 '{scenario="units", n=2000, protos={"rts-walker"}, forces=4, half=400}' 1800
./run.sh drone4000 '{scenario="units", n=4000, protos={"rts-drone"}, forces=4, half=400}' 1800
./run.sh combat1000 '{scenario="combat", half=256, comp={{"rts-walker",600},{"rts-walker-heavy",100},{"rts-drone",300}}}' 2400
./run.sh static20k '{scenario="static", half=512, cols=13, rows=13}' 1800
./run.sh trains40 '{scenario="trains", half=512, lines=40, len=250, wagons=3, signals=50, wait=120, signal_side=-1}' 3600
./run.sh fog4 '{scenario="fog", half=1000, radars=40, radar_entities=true, units=150, script_chart=true}' 3600
./run.sh air '{scenario="air"}' 1800 air
./run.sh capture '{scenario="capture", half=128}' 300
python3 parse.py results/spider2000-bench.out 300
```

The GUI chart measurement creates `foggui` with `phases=true, speed=100, player_force="pf1"` and loads it in the
client with `--load-game`; the `[probe] gui tick` lines in the client log give wall-clock ms per tick per phase.
