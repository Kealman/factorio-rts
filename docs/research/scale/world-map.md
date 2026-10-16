# The world at mini-state scale: huge maps, geography, regions and scarcity

Research study for the "mini-state" direction: a Rise of Nations (RoN) and Workers & Resources (W&R) scale game on a
map shaped by economics and geography. Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam) on an Apple M3 Pro
(12 cores, 18 GB). Sibling studies in this folder: `territory-cities.md`, `deep-economy.md`, `rails-trade.md`,
`war-ai-performance.md`. Today's generator: `docs/qa/phase4-mapgen-notes.md`. API facts come from `runtime-api.json`,
`prototype-api.json` and `auxiliary/noise-expressions.html` of the installed game. Probe: `build/scale-probe-world/`.

## 0. Summary

- **Recommended approach: hybrid.** Lua plans the strategic skeleton of the world: coasts, mountain ranges and their
  passes, rivers and their fords, climate regions, and the protected sites. It writes the skeleton into
  `MapGenSettings.property_expression_names` as numeric constants. Our named noise expressions read those constants,
  and the engine paints organic terrain from them. Script then places ore regions, spawns, city-states, ruins and
  ports from the plan, exactly as `mapgen.lua` places patches today.
- **The plan is checked before a single chunk exists.** `LuaSurface.calculate_tile_properties` evaluates the engine's
  own noise at any point of an ungenerated surface. 4,096 samples cost 3–13 ms. Spawn scoring, connectivity and
  fairness checks run on samples, and a failing plan is fixed and re-injected.
- **Barriers our units respect.** Spider units step over cliffs and rock rows (Phase 4 probe). Water stopped them,
  and their legs collide with tiles that carry the `player` layer. So mountains are a custom impassable tile with that
  layer, and rivers are water. Passes and fords (walkable shallow water) are the chokepoints. Cliffs only decorate
  mountain rims.
- **The engine handles 4096 × 4096.** Generation takes 42 s, an idle map costs 0.17 ms per tick, and a save is 23 MB.
  The real limit is pacing: at 4096 a heavy walker needs 7.5 minutes to reach the nearest enemy. The default should be
  **2048 × 2048 for 3–4 nations**, scaled down for 2 and up for 6–8.
- **Effort: about 19 agent-days in three phases, about 23 with a 20 % buffer.** Phase W1, a playable 2048 world, is
  6 days and can start now.

Probe numbers. Base game only, no RTS code, `helpers.create_profiler` and `factorio --benchmark`.

| Map | Terrain | `force_generate_chunk_requests` | Peak server RSS | Save | Update time, idle |
|---|---|---|---|---|---|
| 2048² (4,225 chunks) | ours (rivers, mountain tile, cliffs on rims, no ore) | 10.8 s | 413 MB | 6.5 MB | 0.172 ms/tick |
| 2048² | vanilla Nauvis | 10.8 s | 406 MB | 6.8 MB | – |
| 4096² (16,641 chunks) | ours | 42.5 s | 728 MB | 22.7 MB | 0.168 ms/tick |
| 4096² | vanilla Nauvis | 41.8 s | 806 MB | 20.1 MB | 0.176 ms/tick |
| 4096² | ours, no trees, decoratives or rocks | 40.0 s | 583 MB | 8.8 MB | 0.171 ms/tick |
| 4096² | lab tiles (today's arena path) | 2.4 s, plus about 16–24 s of `set_tiles` and the Lua tile function | 658 MB | 3.2 MB | – |

## 1. What makes geography matter in the reference games

| Game | What geography does | Principle we take |
|---|---|---|
| **Rise of Nations** | Map types (Highlands, Mediterranean, Large Continents) change the whole game. Mountains block movement except at passes. Rivers and coasts separate fronts. Rare resources (horses, silk, salt and others) give nation-wide bonuses and sit on neutral ground. Borders grow from cities and forts, and attrition punishes deep raids. | Few, large, readable barriers with named crossings. Rare deposits pull expansion. Map types are presets of one generator. |
| **Civilization** | Hills defend, mountains block, rivers give fresh water and slow crossings. Strategic resources gate units, and late ones (oil, uranium) appear only after a tech. Map options balance starts so every civilization gets a workable one. | Guarantee a fair start kit, then let the rest of the map be uneven. Some deposits are usable only after research. |
| **Workers & Resources** | Deposits exist only where geology puts them. Building on slopes costs more, and every road, rail and bridge is paid for. The world market is reachable only at border crossings. | Distance and terrain are real costs. Trade happens at fixed edge sites. Infrastructure across rivers and mountains is a strategic investment. |
| **Anno** | Each island has fertilities, so a crop grows only on some islands. Island size limits building space. Trade routes link specialized settlements, and some goods exist only in one region. | Regions differ by kind, not just by amount. Building space is a resource. Specialization forces a network. |
| **Factorio itself** | Patches grow richer with distance from spawn, water decides where steam goes, cliffs and biters shape bases. | Contested ground is richer. Terrain blocks building, not just movement. |

Principles for our map, each with its Factorio form:

1. **A few big barriers instead of many small ones.** Two or three mountain ranges, two or three river systems, one
   coast. Each barrier is at least 24 tiles thick, and each crossing is 30–60 tiles wide and has a name.
2. **Regions with identity.** A player who sees a region knows what it gives: Iron Hills, Saltmarsh, Red Desert.
   Identity comes from tiles, trees, map colour, the resources and a name label.
3. **Fair start, unfair world.** Every nation gets the same start kit within 150 tiles. Beyond it, nations get
   different home specialties of equal value, and the scarce things lie between them.
4. **Distance is a cost that rises with scale.** Belts serve inside a base, haulers within regions and trains between
   them, as `rails-trade.md` derives. The map must put the key regions 400–1500 tiles apart so that trains pay.
5. **Chokepoints come from geography.** Fights happen at fords, passes and land bridges between lakes because the
   terrain makes them, not because a moat was drawn in front of a base.
6. **Engineering changes geography.** Bridges, causeways and blasted passes cost resources and time, and they shift
   the strategic map.
7. **Neutral sites are objectives.** City-states sit on scarce resources and crossroads. Ruins reward exploration.
   Trade ports sit at the map edge.
8. **One generator, many map types.** Presets change parameters (more sea, more mountains, desert world), not code.

## 2. Map scale and anatomy

### 2.1 Size per number of nations

Speeds: walker 10.7 tiles/s, heavy about 5.9 (×0.55), hauler 21.6 (logistics autotest). Path lengths for 2048 and
4096 are measured probe paths between spawns at 30 % of the map size from the centre. The other rows are estimates.

| Nations | City-states | Map | Chunks | Generation, blocking | Spawn to nearest spawn, path | Walker | Heavy | Hauler |
|---|---|---|---|---|---|---|---|---|
| 2 | 2–3 | 1536² | 2,304 | about 6 s | about 1,000 tiles | 1.6 min | 2.8 min | 46 s |
| 3–4 | 4–6 | **2048² (default)** | 4,096 | 10.8 s, measured | 1,351, measured | 2.1 min | 3.8 min | 63 s |
| 4–6 | 6–9 | 3072² | 9,216 | about 24 s | about 2,000 | 3.1 min | 5.6 min | 93 s |
| 4–8, "huge" | 8–12 | 4096² | 16,384 | 42.5 s, measured; or a 2 s core plus 7 min in the background (4.3) | 2,643, measured | 4.1 min | 7.5 min | 2.0 min |

- **Why 2048 is the default.** It keeps a march to the nearest neighbour at 2–4 minutes for walkers and heavies.
  Rails pay from about 400–800 tiles (`rails-trade.md`), and 2048 has room for several such links per nation. A 4096
  map has the same idle cost but empty land, slow armies and long path latency for many units
  (`war-ai-performance.md`).
- **Land per nation.** 2048² with 4 nations is about 1 million tiles per nation, roughly 1,000 × 1,000. Ten cities
  claim about a fifth of it (`territory-cities.md`, probe). The world fixes this by making 30–40 % of the land
  low-value: mountains, swamp, desert and dense forest. Good land then becomes contested by mid-game.
- **Huge maps** (4096) are for 6–8 sides or many city-states, with lazy generation (section 4.3).

### 2.2 Region types

A 2048 map holds about 14–20 regions, each 150–300 tiles across. A 4096 map holds 35–50.

| Region | Ground and look | Resources | Building and movement | Strategic role | Natural city |
|---|---|---|---|---|---|
| **Highlands** | dirt and red-desert tiles, rocks, mountain spurs with cliff rims | iron, copper, coal and stone, richer than lowland ore | building space broken into pockets; defensible | ore, the industrial heart | mining town |
| **Plains** | grass-1 to grass-4, scattered trees | little ore; fertile tiles hold farm slots | open, fast to build; rail-friendly; hard to defend | food and space for cities | capital, farming town |
| **Lakeland** | grass, lakes, sand shores | fresh water, farms | lakes cut the land into lanes | water for steam and chemistry, farms | farming town, chemical works |
| **Coast** | sand, deepwater sea along 1–2 map edges | trade ports, fish later | shore blocks building; offshore pumps | trade with the world market | port city |
| **Swamp** | water-mud and water-shallow pools, dense trees | crude oil, coal | pools are walkable but not buildable, so bases are fragmented | oil; armies are channelled | oil town |
| **Desert** | sand and red desert, almost no trees | rare deposits, some stone; no water | open and fast to cross; no water for steam | rare bonuses; raiding ground | outpost |
| **Forest** | dense trees on grass or dirt | wood if the economy adds it | trees block building and rails until cleared | screens and slows expansion | none |
| **Mountains** | impassable `rts-mountain` tile, cliffs on the rim | rare deposits on the rim (quartz, tungsten) | blocks everything except at passes | the barrier; passes are the chokes | none; forts at passes |

`deep-economy.md` asks for one oil field within every nation's reach, uranium only on contested ground, 4–8 rare
deposits, and at least one region per nation without ore. The scarcity model in 2.4 places them.

### 2.3 Barriers and crossings

Phase 4 measured what stops our units. Spider units and haulers stepped over cliff lines and rock rows. Drones went
around cliffs and got stuck on rock rows. Water 14 tiles or wider stopped all of them, and spider units cut 6 tiles
off a barrier's end. Legs collide with the `player` and `rail` layers (`collision-mask-defaults.lua`), and water tiles
carry `player`. A tile with the `player` layer should therefore stop legs like water does.

| Barrier | How it is made | Who crosses | Crossing points | Engineering |
|---|---|---|---|---|
| **Mountain range** | `rts-mountain` tile: layers `player`, `item`, `object`, `doodad`, `resource`, `floor`. At least 24 tiles thick. Cliffs on the outer rim. | nobody (assumed from the water result; to measure in W1) | passes 30–60 tiles wide, 1–3 per range | Phase W2 "Demolition" research: script turns a 16-tile corridor of mountain into ground, for explosives, over minutes |
| **River** | deepwater core, water rim, sand banks; 24–40 tiles wide | nobody | fords: `water-shallow` tiles, which units walk on and nobody builds on; every 300–500 tiles | landfill causeway (tile ghosts built by robots); elevated rail bridge with Space Age (`rails-trade.md`) |
| **Lake, sea** | elevation below 0 | nobody | land bridges between lakes | causeways |
| **Swamp pools** | `water-mud`, `water-shallow` | everybody, slowly for units that use tile speed | – | landfill |
| **Forest** | vanilla tree autoplace from moisture | everybody | – | robots clear trees |

- **Fords are army crossings, not rail crossings.** Shallow water lacks the `player` layer, so units and haulers walk
  through. It has `water_tile`, so no rail or building can be placed there. A rail needs a bridge or a causeway, which
  makes bridges strategic targets.
- **Unit speed on terrain.** `UnitPrototype.affected_by_tiles` lets drones slow down in swamps and speed up on roads.
  Whether spider-unit legs react to `walking_speed_modifier` is unverified.

### 2.4 Scarcity: who has what

All totals are relative to today's main patch. The final volumes come from `deep-economy.md`.

| Tier | Where | What | Rule |
|---|---|---|---|
| **Start kit** | within 150 tiles of every spawn, on clean land | iron, copper, stone, coal; about 3× today's main patch | identical for every nation, placed by script like today's main patches |
| **Home specialty** | 300–700 path tiles from its spawn, closer to it than to any other spawn | one major region per nation; kinds differ (iron highlands, copper hills, coal and oil swamp, lakeland farms) | equal value, different kind; the specialties of all nations together cover every basic ore |
| **Contested majors** | between nations, at equal path distance from 2 or more spawns | **only 2 large copper regions on a 4-nation map**, 1–2 large iron regions, 1 large oil swamp | richer than home regions, like Factorio's distance richness |
| **Strategic** | contested ground | uranium: 1–2 per map | minable only with an extractor unlocked by "Geology" research, as Civilization gates strategic resources by tech |
| **Rare deposits** | desert, mountain rims, city-state land | 4–8 per map, kinds from `deep-economy.md` 3.7 | most of them inside or next to a city-state |
| **Ports** | coast or map edge | 2–4 trade ports | captured like the ruin |

- **Why it works.** The start kit lasts 15–25 minutes. Then every nation lacks something: a copper-poor nation must
  trade, raid or take one of the two copper regions. Two copper regions for four nations means two pairs of
  neighbours fight over them.
- **Balancing value instead of kind.** Region value = sum over its ore of total ore × chain weight. The planner
  assigns specialties to spawns by trying permutations and keeping the one with the lowest spread of nation value.
  Nation value counts reachable regions as value / (path distance / 500).

### 2.5 Readability

- **Map colours.** The map preview at 4 tiles per pixel showed the vanilla palette as uniform brown and green. A
  20-tile river is a 5-pixel line, which reads. Mountains need a contrasting `TilePrototype.map_color` (light grey).
  Regions get a faint chart-mode tint and a name.
- **Names.** Every region, pass, ford, river and range gets a generated name from locale word lists ("Iron Hills",
  "Gate of Kerr", "Ford of Ash").
- **Sizes that survive zooming out.** Barriers at least 24 tiles thick, crossings 30–60 tiles wide, patches at least
  16 × 16 tiles. Anything smaller vanishes in the strategic view.

## 3. Generation approach

### 3.1 Three options

| | (a) Engine generator, tuned `MapGenSettings` only | (b) Scripted generator (today: lab tiles plus `set_tiles`) | (c) Hybrid: skeleton in Lua, terrain from engine noise, sites by script |
|---|---|---|---|
| Cost at 2048² | 10.8 s | about 6 s (16 × today's 380 ms for the 512² arena), without trees, cliffs or biomes | 10.8 s plus about 0.3 s of planning |
| Cost at 4096² | 42 s, or async in the background | about 24 s (64 ×) plus 2.4 s of lab chunks, still without trees, cliffs or biomes | 42 s, or a 2 s core plus async |
| Looks | rich: transitions, trees, decoratives, cliffs | flat and synthetic unless we rewrite biomes in Lua | rich |
| Strategic control | low: rivers and passes land wherever the noise puts them | full | full: the plan fixes ranges, rivers, crossings and sites |
| Fairness | none beyond `starting_points` | full | full: the plan is checked on engine samples |
| Lazy generation | free (engine) | needs chunk-sliced Lua | free for terrain; sites placed in `on_chunk_generated` |
| Code | data stage only | all in Lua | data-stage noise plus Lua planner (an evolution of `mapgen.lua`) |

**Recommendation: (c).** (a) cannot guarantee a fair start or a crossing. (b) is a little faster on bare tiles, but it
looks synthetic, and every biome, tree or cliff rule adds Lua time per tile on one thread. Lazy maps would also need
all of it sliced per chunk. (c) gets the engine's multi-threaded generation and looks, and keeps every strategic
decision in Lua where it can be tested.

### 3.2 The pipeline

1. **Plan the skeleton in Lua** (deterministic per seed, `game.create_random_generator` with `mapgen.mix_seed`).
   - Coasts: which map edges are sea, and the coast line's mean depth.
   - Mountain ranges as polylines of 2–5 segments, with passes on them.
   - Rivers as polylines from a range or lake to the sea or the map edge, with fords on them.
   - Climate anchors: points that push moisture up (swamp, lakeland) or down (desert).
   - Protected sites: spawns, start kits, city-states, ports, ore regions, ruins.
2. **Write the skeleton into `MapGenSettings`.** Start from `game.surfaces.nauvis.map_gen_settings`, set `width`,
   `height`, `seed`, ores and enemies off, `starting_points` = every protected site, and
   `property_expression_names` = elevation, moisture, aux, cliff expressions plus all skeleton constants, as strings.
   Add `rts-mountain` and the ford tile to `autoplace_settings.tile.settings`.
3. **Create the surface without generating it**, then sample. `calculate_tile_properties({"elevation",
   "rts_mountain", "moisture", "aux"}, points)` on an 8-tile grid gives 65,536 points at 2048, an estimated 30–60 ms
   scaled from the probe.
4. **Validate and score on a coarse grid.** Make a passability grid of 8-tile cells from the samples. Then:
   - flood-fill: every spawn reaches every other spawn, every contested region and every city-state on land;
   - start kits: each fits on buildable land within 150 tiles;
   - spawn scores (5.1) and value spread (2.4);
   - chokepoints (5.4).
   On failure, move a pass, add a ford, shift a site, and write the settings again. `LuaSurface.map_gen_settings` is
   writable before any chunk is generated.
5. **Generate.** At 2048, all chunks at match start (11 s, behind a "Generating world" screen). At 4096, a core of
   chunks around every site with `force_generate_chunk_requests`, then the rest in the background (4.3).
6. **Place script content.** Ore regions with exact totals (today's patch code, sliced per chunk for lazy maps), oil
   (`crude-oil` entities), city-states, ruins, ports, labels. Each item belongs to a chunk, so it can be placed in
   `on_chunk_generated`.
7. **Post-check on real tiles.** `count_tiles_filtered` per site and `get_connected_tiles` over the 8-tile grid,
   like today's land connectivity flood. Log the world summary.

### 3.3 Noise design

Data stage (`prototypes/world-noise.lua`):

```lua
-- one constant slot per skeleton number; runtime overrides it via property_expression_names = {rts_rng1_ax = "812"}
for i = 1, 16 do for _, k in pairs{"ax", "ay", "bx", "by", "w"} do
  data:extend{{type = "noise-expression", name = "rts_rng" .. i .. "_" .. k, expression = "0"}}
end end
data:extend{
  {type = "noise-function", name = "rts_seg", parameters = {"ax", "ay", "bx", "by", "w"},
   expression = "w - sqrt((wx - ax - t * dx)^2 + (wy - ay - t * dy)^2)",   -- > 0 inside the band
   local_expressions = {dx = "bx - ax", dy = "by - ay",
     t = "clamp(((wx - ax) * dx + (wy - ay) * dy) / max(dx * dx + dy * dy, 1), 0, 1)"}},
  -- wx, wy: x and y warped by about 60 tiles of basis_noise, so straight segments come out organic
  {type = "noise-expression", name = "rts_mountain",
   expression = "min(max(rts_seg(rts_rng1_ax, ...), rts_seg(rts_rng2_ax, ...), ...) - rts_pass_cut, site_clear)"},
}
```

- **Constants work.** The probe set `rts_probe_const = "42"` in `property_expression_names`, and
  `calculate_tile_properties` returned 42 at all 4,096 points. The noise docs list `property_expression_names` before
  global prototype names in name resolution.
- **Lists.** The only list input is `starting_positions`, filled from `MapGenSettings.starting_points`. It carries all
  protected sites, and `distance_from_nearest_point` keeps land flat and free of rivers and mountains around them.
  Everything else uses fixed slots: 16 range segments, 16 river segments, 12 passes, 16 fords and 12 climate anchors,
  about 300 constants. `max` takes up to 255 arguments.
- **Mountain tile.** `if(rts_mountain > 0, 300, -inf)` as its probability beats water, whose probability is at most
  200 (`water_base(-2, 200)`).
- **Rivers** use the same segment function on elevation: elevation drops below −2 in the core. Fords raise the river
  bed to a shallow band where a ford tile with probability 400 wins.
- **Climate.** Moisture and aux wrap the vanilla Nauvis expressions and add the anchors' cones. Vanilla tile and tree
  autoplace then makes deserts, swamps and forests by itself.
- **Cliffs.** `cliff_elevation` = 30 + 4 × `rts_mountain` and `cliffiness` = 1 near ranges put one cliff contour on
  each rim, and by construction nowhere else. The probe made 9,313 cliffs at 4096².
- **Engine-chosen regions are the alternative.** `voronoi_cell_id` and `voronoi_facet_noise` cut the map into cells
  with a random value each, and Space Age planets build their biomes from such fields (`vulcanus_biome_contrast`).
  The planner could read those cells by sampling instead of choosing regions. We choose anchors instead, because
  fairness needs control over where each region type lands. `spot_noise` is the engine's ore-patch tool and is not
  needed, because script places ore with exact totals.
- **Cost.** Our noise added no measurable time: custom 42.5 s against vanilla 41.8 s at 4096². Without trees,
  decoratives and rocks it was still 40.0 s, so the terrain noise programs dominate, not the trees. A leaner tile set,
  with fewer than the 21 Nauvis tiles, may cut generation time; that is unmeasured.

### 3.4 Gotchas found by the probe

1. **`multioctave_noise` is not zero-mean at map scale.** With `input_scale = 1/800` and 4 octaves it returned
   −1.31 to −0.46 over a whole 2048 map, so a ridge on its zero line never appeared. Its extra octaves appear to be
   coarser than `input_scale`. Sums of `basis_noise` at chosen scales behaved: −1.94 to 1.97, half below zero.
2. **A headless server never charts.** `is_chunk_charted` stayed false for every chunk after a whole-map
   `LuaForce.chart`. This matches the Phase 3 notes and every `fog:` line in our autotest logs ("charted 0").
3. **`--generate-map-preview` did not draw the mod tile.** Its cliff rims showed where the ranges were. A preview is
   no proof of a tile.
4. **`request_to_generate_chunks({0, 0}, 32)` generates 65 × 65 chunks**, one ring past a 2048 map.
5. **A `.zip` in the mod directory is loaded as a mod**, and `game.server_save` fails if the write directory has no
   `saves/` folder (a non-recoverable error).

## 4. Chunk generation cost and timing (measured)

### 4.1 Method

`build/scale-probe-world/run.sh <rts|vanilla|bare|lab> <size>` copies the probe mod (`src/rts-world-probe/`) into
its own mod directory, base game only, creates a map and runs a headless server. The script steps are: sample, force
generation, count terrain, chart, lazy generation, three long paths, overlays, save. RSS is sampled every 2 s. Update
time is `factorio --benchmark <save> --benchmark-ticks 600`. Other agents may have run probes on the same machine at
the same time; three runs of the 2048 generation agreed within 2 % (10.70–10.86 s).

### 4.2 Results

| Measure | 2048² | 4096² |
|---|---|---|
| `calculate_tile_properties`, 4,096 points × 6–12 properties, before generation | 3.4–12.2 ms | 5.2–12.6 ms |
| `force_generate_chunk_requests`, ours | 10.8 s | 42.5 s |
| Per chunk, effective on 12 cores | 2.6 ms | 2.6 ms |
| Terrain, ours: water / mountain / trees / cliffs | 1.5 % / 5.9 % / 145k / 3,583 | 1.8 % / 5.3 % / 592k / 9,313 |
| Terrain, vanilla: water / trees / cliffs / resource tiles | 12.0 % / 136k / 2,858 / 37,738 | 27.4 % / 447k / 13,953 / 130,510 |
| Peak server RSS | 406–413 MB | 728–806 MB |
| Save (`level.dat` uncompressed) | 6.5 MB (14.7 MB) | 22.7 MB (48.3 MB) |
| Update time of the idle map | 0.172 ms/tick | 0.168–0.176 ms/tick |
| Script path, 3×3 box, tiles only, spawn to nearest spawn | 1,351 tiles in 36 ticks (0.6 s) | 2,643 tiles in 77 ticks (1.3 s) |
| Script path, spawn to opposite spawn | 2,078 tiles in 39 ticks | 3,988 tiles in 83 ticks (1.4 s) |
| 600 chart-mode texts + 4,000 chart-mode lines, creation | 8–16 ms | 18–25 ms |
| 200 chart tags | 0.3–0.5 ms | 0.8 ms |
| `LuaForce.chart` call for the whole map | 0.02 ms | 0.06–0.07 ms |

- **Map size costs nothing per tick.** An idle 4096 world updates as fast as a 2048 one, with or without trees.
  Update cost comes from units, pathing and production, which `war-ai-performance.md` measures.
- **Trees and decoratives** cost save size (22.7 against 8.8 MB at 4096²) and about 6 % of generation time, but no
  update time.
- **Long paths resolve.** A 4,000-tile script path takes 1.4 s. Many units on long paths queue in the pathfinder
  (`war-ai-performance.md`), so long marches should go through the chokepoint graph in legs of at most 500 tiles.

### 4.3 Lazy generation

- **The engine generates in the background for free.** `request_to_generate_chunks({0, 0}, 8)` without forcing
  generated 289 chunks in 444 ticks in every run, which is about 39 chunks per second. Wall time was 7.39 s for
  444 ticks, so the game held 60 UPS. The fixed rate across terrains suggests a fixed background budget; at 2.6 ms per
  chunk on 12 cores, about one core's worth.
- **What it means.** A 2048 map fills in about 105 s and a 4096 map in about 7 minutes. Units take 2–4 minutes to
  leave home. So a 4096 match can start after a 2-second core and fill the rest while players open.
- **The core.** The chunks within 5 chunks (160 tiles) of each spawn and within 3 chunks of every other site: about
  780 chunks for 4 nations and 6 city-states, about 2 s blocking. Then request the rest from the spawns outwards.
- **Script content on lazy chunks.** Every planned feature is assigned to chunks. `on_chunk_generated` places what
  belongs to that chunk: ore tiles, oil, labels, ruins. The plan is in `storage`, so a save mid-generation resumes.
- **Charting needs generated chunks.** A chunk that does not exist cannot be charted, so a "survey" start (section 6)
  charts what exists and the rest as it arrives. In fog-of-war play this is invisible, because nobody looks that far.
- **Not chosen:** generating only where nations expand. The planner and the AI need the whole terrain anyway, and
  the background fill is free.

### 4.4 Charting and overlays

- **Charting is client work.** A headless server charts nothing, so its cost never reaches the simulation.
- **GUI client, 4096² base game.** The client charted the queued whole-map chart at about 680 chunks per second:
  7,181 chunks in 634 ticks. Heartbeats arrived every 5.0 s per 300 ticks, so the game held 60 UPS while charting.
  The whole map would chart in about 25 s, and a 2048 map in about 6 s.
- **Open item.** In both GUI runs the single-player client stopped advancing ticks about 10 s after loading, with or
  without Lua polling. A window that lost focus is the likely cause, but it was not isolated. W1 repeats this with a
  screenshot-capable GUI run. `war-ai-performance.md` measured `chart_all` of 4,900 chunks in the GUI at +0.03 ms per
  tick, and 40 radars with fog re-charting at +0.2 ms per tick on 2000².
- **Rules.** Never chart the whole map during play, except once for a survey start. Keep `fog.lua`'s re-chart of
  squares around own units and buildings. Count `on_chunk_charted` events instead of polling `is_chunk_charted` over
  thousands of chunks.
- **Overlays are cheap.** Render objects do not tick (`territory-cities.md`: 55,000 objects with no measurable update
  cost). Creating a world's labels and borders takes under 25 ms.

## 5. Spawns, fairness and objectives

### 5.1 Scoring a spawn

Candidates lie on a 64-tile grid on land, at least 250 tiles from the map edge. Each score is computed from the
8-tile passability grid (prefix sums make the window sums cheap):

| Term | Weight | Measure |
|---|---|---|
| Buildable land | 0.35 | fraction of cells within 150 tiles that are land, not mountain, not a river bank; forest counts half |
| Water | 0.15 | fresh water (lake or river) within 200 tiles, needed for steam |
| Defensibility | 0.20 | land corridors at least 30 tiles wide crossing the ring at 300 tiles: 2–3 is best, 1 is a turtle fortress, 5 or more is exposed |
| Expansion value | 0.30 | value of the regions closer to this site than to other spawns, each divided by path distance / 500 |

**Selection.** Choose N sites that maximise the minimum score, under these constraints:
- every spawn pair is at least 0.45 × map size apart by path;
- every nation's nearest-enemy path distance is within ±12 % of the others;
- for every scarce type, the nearest deposit's path distance is within ±15 % across nations, or the deposits come in
  designed pairs between neighbours.

With a few thousand candidates at most and N ≤ 8, a greedy pick with a few hundred random restarts should take well
under a second in Lua.

### 5.2 The start kit

Today's main patches, scaled by `deep-economy.md`, sit on clean land within 150 tiles. The planner reserves their
boxes before any terrain is drawn: they are protected sites with a clear radius. The AI's base layout keeps its
assumptions (`scripts/ai/layout.lua` plans inside the base ring and finds resources within 100 tiles). Nothing in the
base ring is terrain, exactly as today's `BASE_RING` rule.

### 5.3 City-states, ruins and ports

| Site | Count at 2048, 4 nations | Placement rule | Role |
|---|---|---|---|
| City-state | 5–6 | at a scarce region (each contested copper region gets one), a major ford or pass, the coast, the oil swamp | capture or trade (`territory-cities.md` capture; `deep-economy.md` prices); today's ruin grows into this |
| Ruin | 8–12 | in low-value regions: desert, swamp, mountain rims, far corners; at least 300 tiles from spawns | exploration reward, like today's ruin and RoN's ruins: steel, circuits, a hauler, a research kit bundle |
| Trade port | 2–4 | on the coast or at the map edge, as far from spawns as possible and fair by path | the world market (`deep-economy.md` 4.4) |
| Rare deposit | 4–8 | desert, mountain rims, city-state land | nation-wide bonus |

City sites for founding new cities (`territory-cities.md` 3.1: flat land near ore, water or farmland, at least 96
tiles apart) are scored from the same samples and stored as a list, about 25–40 on a 2048 map.

### 5.4 Chokepoints from geography

- **Planned crossings are chokes by construction.** Every pass and ford is in the plan with its position and width.
- **Emergent chokes are found on the grid.** A distance transform on the 8-tile passability grid gives each land cell
  its clearance. A choke is a clearance minimum on the land skeleton between two regions, with a width under 80
  tiles. Two passes over 262,000 cells at 4096 should take about 0.5 s in Lua (estimate).
- **They are named and stored.** `storage.world.chokes = {{kind, position, width, name, regions = {a, b}}}`. The AI
  uses them as defence rally points and attack routes, like `storage.mapgen.gaps` today. The HUD labels them.
- **Moats become a preset.** The Chokepoints arena keeps its moats for skirmish maps. The world map has no drawn moats.

## 6. Camera and awareness at this scale

| Need | Mechanism | Notes |
|---|---|---|
| Strategic zoom | `LuaPlayer.set_zoom_limits(remote, {closest, furthest, furthest_game_view})`: `furthest` far out (`ZoomSpecification` by `distance`, for example 2,500 tiles), `furthest_game_view` at 0.15 as today | Beyond `furthest_game_view` the remote view draws the chart: terrain colours, rails, buildings and tags. That chart view is the strategic layer. |
| Labels by zoom level | `rendering.draw_text{render_mode = "chart", scale_with_zoom = true}` for region, range, river and choke names; `render_mode = "game"` for labels in the world | Chart-mode objects show only in the map view, which gives two zoom levels for free. A third level toggles `LuaRenderObject.visible` from the zoom that `camera.lua` already samples every 10 ticks. |
| Borders, routes, fronts | `draw_line` in chart mode (`territory-cities.md`: about 2,600 merged runs on 2048); dashed lines for trade and rail routes; `draw_sprite` for city icons and divisions, attached to entities | measured: 600 texts and 4,000 lines in 8–25 ms |
| Minimap | the HUD `minimap` element (220 px, 1 GUI pixel per tile at zoom 1) | The whole 4096 map needs zoom 0.054, which is 19 tiles per pixel and too coarse. Make it regional, about 1,000 tiles around the camera, with a world toggle. Click-to-jump already works. The lowest minimap zoom is untested. |
| Map pins | `LuaForce.add_chart_tag` for cities, ports and ruins; existing pings | 200 tags in under 1 ms; a tag needs a charted chunk |
| Alerts | the existing alert list plus F3, with the region name in the text and grouping per region ("Iron Hills: 3 haulers lost") | `LuaPlayer.add_custom_alert(entity, icon, message, show_on_map)` adds vanilla alert icons on the map |
| Fog | per-force chart as today; option **Survey** charts all generated terrain at the start, option **Explore** starts black | Survey takes about 6 s at 2048 and 25 s at 4096 on the client. The chart freezes what it saw, so enemy bases built later stay hidden until scouted. |
| World overview | a "World" panel listing regions with owner, resources and status; clicking a row jumps the camera | GUI only; no new engine needs |

`LuaForce.get_chunk_chart` returns a chunk's chart as RGB565 pixels. A custom overview picture could be built from
it, but the chart view already shows the same thing.

## 7. Feasibility

### 7.1 API used

| Need | API (2.0.77) | Status |
|---|---|---|
| Custom terrain functions | `noise-expression` (NamedNoiseExpression), `noise-function` (NamedNoiseFunction) with `local_expressions` | documented; used by the probe |
| Runtime constants into noise | `MapGenSettings.property_expression_names` (values are names or numbers as strings) | **measured working** |
| Site list in noise | `MapGenSettings.starting_points`, noise `starting_positions`, `distance_from_nearest_point` | measured working with 4 points; behaviour with about 60 points untested |
| Impassable tile | `TilePrototype{collision_mask, autoplace, map_color, tint}`; `CollisionLayerPrototype` for a custom layer if needed | measured: 888,799 mountain tiles at 4096²; stopping units is untested |
| Ford tile | vanilla `water-shallow` (layers `water_tile`, `resource`, `floor`) | collision from `tile-collision-masks.lua` |
| Cliffs on rims | `CliffPlacementSettings{cliff_elevation_0, cliff_elevation_interval, richness}`, properties `cliff_elevation` and `cliffiness` | measured: 9,313 rim cliffs |
| Sampling before generation | `LuaSurface.calculate_tile_properties(property_names, positions)` | **measured working**; 4,096 points in 3–13 ms |
| Generation | `LuaGameScript.create_surface`, `LuaSurface.request_to_generate_chunks`, `force_generate_chunk_requests`, `is_chunk_generated`, `on_chunk_generated`, `map_gen_settings` (RW) | measured |
| Real-tile checks | `count_tiles_filtered`, `find_tiles_filtered`, `get_connected_tiles`, `count_entities_filtered` | measured |
| Long paths | `LuaSurface.request_path` and `on_script_path_request_finished` | measured up to 3,988 tiles |
| Fog and pins | `LuaForce.chart`, `is_chunk_charted`, `on_chunk_charted`, `add_chart_tag`, `get_chunk_chart` | headless never charts; GUI measured partly |
| Camera | `LuaPlayer.set_zoom_limits`, `ZoomLimits`, `render_mode`; `minimap` GUI element | documented; the zoom-out range is untested |
| Overlays | `rendering.draw_text`, `draw_line`, `draw_sprite` with `render_mode = "chart"` | measured |

### 7.2 Risks

1. **Pacing and empty land (largest).** The engine copes with 4096, but the game may not: a heavy walks 7.5 minutes
   to the nearest enemy, and ten cities cover a small share of the land. Mitigation: 2048 by default, size scaled by
   nation count, 30–40 % low-value land, city-states and ruins filling the gaps.
2. **The mountain tile might not stop every unit.** It is assumed from the water result, because legs collide with
   `player`. The W1 crossing test checks it. Fallback: deepwater-like "chasm" tiles.
3. **Skeleton and noise can disagree.** Domain warp can close a pass or merge two rivers. Sample-based validation and
   a minimum width with margin, 24 tiles for barriers and 30 for passes, catch it before generation.
4. **Long-range pathing for many units** (`war-ai-performance.md`). Route through the chokepoint graph in legs.
5. **The GUI client stopped ticking** in the 4096 chart runs (4.4). It is unexplained, probably the environment, and
   W1 rechecks it.
6. **Multiplayer start.** Blocking generation runs on every peer. At 2048 this is 11 s, acceptable. At 4096 use the
   lazy core.

## 8. Plan

| Phase | Content | Agent-days |
|---|---|---|
| **W1. A playable world (2048)** | Data stage: mountain tile, ford tile, segment noise functions, constant slots, sea, rivers, ranges, climate anchors, rim cliffs. Lua: skeleton planner, sampling validator, coarse grid, spawn scoring and selection, start kits, generation at match start with a progress line. Lobby map type "World" with size by nation count. `match.create_arena` uses engine terrain instead of lab tiles plus `set_tiles`. A unit crossing probe for the mountain tile, fords and rivers. | 6 |
| **W2. Geography that matters** | Region types and names, the scarcity portfolio (start kit, home specialties, two copper regions, oil swamp, uranium behind Geology, rare deposits), sites for city-states, ruins, ports and cities (handed to the cities and economy work), chokepoint detection and `storage.world`, the strategic layer (chart-mode labels, choke markers, regional minimap, zoom limits, region names in alerts), Survey and Explore fog options, Demolition research and landfill causeways. | 7 |
| **W3. Huge maps** | 3072 and 4096 presets, the blocking core plus background generation with `on_chunk_generated` placement and save/load mid-fill, a leaner tile set (measure), long marches through the chokepoint graph, GUI chart check, performance runs with 4 AI nations. | 6 |
| | **Total** (about 23 with a 20 % buffer) | **19** |

**Acceptance tests**

- **W1.** 20 seeds × 2, 3 and 4 nations, headless:
  - generation ≤ 15 s at 2048;
  - land connectivity 100 %: every spawn reaches every other spawn and every contested region;
  - every start kit within 150 tiles on clean land;
  - spawn score spread ≤ 15 % and nearest-enemy path spread ≤ 12 %.

  The crossing probe: walkers, heavies, raiders, artillery, drones and haulers ordered across a range and a river
  never cross mid-span, and cross at passes and fords. The AI autotest 1v1 on a World map ends with 0 errors, and both
  AIs build and attack.
- **W2.** On 20 seeds of 4 nations:
  - each nation lacks at least one basic ore beyond its start kit;
  - each scarce type is reachable by at least 2 nations within ±15 % path distance;
  - 5 or more named chokes exist, and the AI rallies at its nearest choke;
  - a blasted pass and a causeway change the path length the planner reports.

  A GUI QA pass with a Russian client and screenshots checks that region names read at strategic zoom, and that the
  regional minimap and alert jumps work.
- **W3.** A 4096 match with 4 AI nations and 6 city-states:
  - playable 5 s after Start;
  - the background fill completes in ≤ 8 minutes with benchmark max tick under 16.7 ms;
  - a save at minute 3 and a reload give identical per-region ore totals;
  - 60 minutes at 60 UPS within the war study's unit budget.

  A GUI run charts the 4096 survey map without stalling.

## Appendix: probe files

| Path | Content |
|---|---|
| `build/scale-probe-world/src/rts-world-probe/` | the probe mod: `data.lua` (mountain tile; noise for rivers with land-bridge fords, ranges with passes, rim cliffs), `control.lua` (step machine) |
| `build/scale-probe-world/run.sh` | runner; arguments: scenario (rts, vanilla, bare or lab), map size, time cap |
| `build/scale-probe-world/out-spw-*/server.log`, `rss.txt` | logs and RSS samples per run |
| `build/runs/spw-*/saves/probe-*.zip` | the saves used for `--benchmark` |
| `build/scale-probe-world/spw-gui-4096/`, `out-gui*-4096.log` | the GUI chart runs |
| `build/scale-probe-world/preview-rts-4096-small.png`, `mgs-rts-4096.json` | the map preview (without the mountain tile, see gotcha 3) and its settings |
