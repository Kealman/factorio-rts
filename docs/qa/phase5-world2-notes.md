# Phase 5 M2 world (W2): regions, scarcity, city-states, strategic layer

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m2-world`. Contract:
`docs/PHASE5-M2.md` §0 D7, §2, §3 "world.lua additions / strategic.lua", §4 "World". Studies:
`docs/research/scale/world-map.md` §2.2, §2.4, §2.5, §5.3, §5.4, §6, §8 (W2) and `territory-cities.md` §2.4, §2.6.
Base: `docs/qa/phase5-world-notes.md` (W1). Work copy: `build/p5m2-world/factorio-rts/` (HEAD 22d2dd0).

Everything here is **Nation mode only**. Skirmish keeps its maps, its minimap and its zoom limits; the new
prototypes are never autoplaced and Geology is a Nation-only technology.

## Status

| Contract item | As built |
|---|---|
| Region kinds and generated names | 8 kinds (highland, plain, lakeland, coast, swamp, desert, forest, mountain); names from a syllable table drawn by a random stream seeded by the world seed, localised syllable by syllable (en, ru) |
| `world.region_at` | `{id, name, label, kind, climate, role, center, bbox, resources, sites, owner?, owner_share}` |
| Scarcity portfolio | start kit unchanged; one home specialty per nation by permutation search; contested majors as in W1 (4 nations: 2 copper, 2 iron, 1 oil swamp); uranium 1–2 inside the oil swamp, mined only after **Geology**; 4–8 rare deposits on city-state land and mountain rims |
| Sites | `world.sites(kind)` for `city_site`, `ruin`, `port`, `oil`, `city_state`, `rare`, `uranium` |
| City-states | 4 / 5 / 6 for 2 / 3 / 4 nations, founded for `rts-neutral` through `cities.found(..., {archetype = "city_state"})` as soon as their ground exists; region goods and 200 magazines in the City Center's stockpiles; garrison of 4 turrets, +1 per 10 minutes, at most 10 |
| Ruins | 8 / 10 / 12 at 1536 / 2048 / 3072 on low-value land, at least 300 tiles from every spawn |
| Ports | 2–4 on the coast or the map edge, chosen for the lowest spread of the nations' path distance to their nearest port; sites only (m2-treasury builds the trade post) |
| Chokes | planned passes and fords plus "gap" chokes from a distance transform of the passability grid; all named, with `regions = {a, b}` and a width measured on the grid |
| `strategic.lua` | chart-mode region names (with resource icons), choke markers, city and city-state names, port names, division markers; `strategic.label` for other modules; per-force object count log |
| Minimap | regional (1,000 tiles around the camera, following it) by default in Nation mode; **N** switches to the whole world |
| Strategic zoom | the remote view zooms out into the map view to 1.1 world widths (the game view still stops at 0.15) |
| Region names in alerts | `world.place_name(position)`; the HUD prefixes every positioned alert: "Branost Vale: Hauler lost" |
| `balance.nation.world` | added (pure data) |
| Claimable cells (lead's addition) | `world.claimable(cx, cy)`, `world.claimable_count()`; `territory.share` divides by the claimable count (88–94 % of a 2048 map); the Territory victory fires at 60 % of them |

## Files

| File | Status | What it does |
|---|---|---|
| `scripts/world.lua` | changed (owner) | M2 planning steps, city-states and their garrison, the Geology gate, the new queries and checks |
| `scripts/strategic.lua` | new | chart labels, zoom tiers, minimap mode, strategic zoom, `/rts-strategic` |
| `prototypes/world2.lua` | new | `rts-uranium-ore`, six `rts-rare-<kind>` resources and items (category `rts-rare`), technology `rts-geology`, custom input `rts-minimap-mode` (N) |
| `locale/en/world.cfg`, `locale/ru/world.cfg` | changed (owner) | 132 keys each, same keys: nouns of 8 kinds, 66 syllables, choke, city-state, port, chart and alert keys, tech, items, the N control. The W1 `proper-<n>` keys are gone |
| `tools/probes/world_seeds.lua` | changed | runs `world.w2_checks` after the fill (optional requires, so it still runs on a tree without this package) |
| `tools/probes/world2_autotest.lua` | new | functional checks: Geology gate, garrison growth, city-state record, region record, scarcity, label API, refresh |
| `tools/probes/world2_gui.lua` | new | GUI probe: strategic zoom, region, city-state, choke, regional and world minimap, an alert |
| `tools/probes/world2_territory.lua` | new | Territory victory over claimable cells: forts give rts-ai-1 >= 60 % of the claimable cells; share against a recount; the victory 3 minutes later |

### Shared hunks (marker `-- Phase 5 M2 world`), as synced into `mods/factorio-rts/` (on 412a5bf)

| File:line in `mods/` | Hunk |
|---|---|
| `scripts/cities.lua:111` | `display_name` returns `city.title` (city-states) unless a player renamed the city |
| `scripts/cities.lua:197-210` | `founding_opts`; `register` makes an `archetype = "city_state"` city neither a capital nor a nation |
| `scripts/cities.lua:228-229` | the record keeps `archetype = opts.archetype` and `title = opts.title` |
| `scripts/cities.lua:265-268` | `cities.found` passes its options to the registration triggered by `raise_built` |
| `scripts/cities.lua:312` | `buildings.on_added` registers a City Center with the pending options |
| `scripts/hud.lua:152` | `P4.place_name = require("scripts.world").place_name` |
| `scripts/hud.lua:1820-1833` | `alert_text` wraps a positioned Nation alert as `{"rts-world.alert-place", region, text}` |
| `scripts/hud.lua:2344` | the N entry in the M2 key table `P4.KEYS` (`{input = "rts-minimap-mode", key = "N", module = "scripts.strategic", fn = "toggle_minimap"}`) |
| `scripts/research.lua:99` | `EFFECTS["rts-geology"] = {flag = "geology"}` |
| `scripts/research.lua:108` | `NATION_ONLY["rts-geology"] = true` |
| `scripts/ai/scout.lua:59-67` | `rival(f)`: a match force (true outside a match) |
| `scripts/ai/scout.lua:79-82` | `scout.step`: only rivals' buildings become known (`is_enemy(force, f) and rival(f)`). On top of m2-diplomacy's `is_enemy` = `diplomacy.hostile` and the merged participants-only `beaten_enemy` ("Phase 5 M2 treasury / world") |
| `scripts/territory.lua:61` | `local world = require("scripts.world")` |
| `scripts/territory.lua:232-250` | `territory.claimable_cells(force)`; `territory.share` divides by `world.claimable_count()` |
| `scripts/territory.lua:360-362` | `compute`: `T.claim[fid]`, the force's claimable cells |
| `scripts/territory.lua:397`, `:410` | `T.claim` follows every ownership change of a claimable cell |
| `data.lua:19` | `require("prototypes.world2")` |
| `control.lua:54` | `require("scripts.strategic")` after `scripts.ledgergui` |
| `balance.lua:763-796` | `balance.nation.world` |

`scripts/world.lua` in `mods/` is this package's file plus m2-treasury's two hunks (`world.place_port = nil` at 102,
the trade-post branch of `place_feature` at 2656-2657). m2-diplomacy's attrition hunk in `territory.lua` is untouched.

`mapgen.lua` needed no hunk: ruins and ports are placed from the world's sites through `mapgen.add_ruin`, as in W1.
`match.lua` is untouched: `world.neutral_force()` creates `rts-neutral` idempotently
(`game.forces["rts-neutral"] or game.create_force("rts-neutral")`), at war with every match force and at peace with
the vanilla forces, its chart not shared.

## Design as built

### Planning order

W1's skeleton, thickness check, sampling and validation are unchanged. Every M2 step runs afterwards on the sampled
8-tile grid with its own random streams (`new_rng(seed, 1000 + attempt)` for sites, `3000 + attempt` for names). For a
given seed the terrain therefore stays the W1 terrain, except where the specialty search moves the coal swamp. The
2-nation worlds of seeds 20261017 and 20261018 have identical mountain, water, ford, marsh and cliff counts on both
trees.

| Step | What |
|---|---|
| context | candidate cells (every 4th land cell), octile path fields from every spawn, prefix sums of land, water and mountain cells |
| regions | the 32-tile Voronoi grid, kinds, bounding boxes, names; barrier names |
| chokes | planned crossings (plain coordinates, regions on both sides, grid width), then the distance-transform search |
| uranium | 1 (2–3 nations) or 2 (4 nations) patches inside the oil swamp's disc |
| ports | greedy search for the fairest set |
| city-states | anchors in priority order |
| ruins, city sites, oil sites, rare deposits | as below |
| regions again, scarcity | resources and sites per region; the scarcity record and the fairness measures |

### Path distances

W1's breadth-first field is 4-connected and counts a diagonal approach up to 41 % longer than a straight one. Two
nations approaching a contested deposit from mirrored directions then differed by 20–27 % on a fair map. The M2
measures use an octile field instead. It runs on a 16-tile grid, where a cell is passable when 3 of its 4 cells are,
with chamfer weights 3 and 4 and a bucket queue, and it never reports less than the straight line.

### Regions

- Kinds: a home region is plain; deposit regions take their deposit's kind (highland or swamp).
- Frontier regions: coast near a sea edge; mountain when at least 6 % of their cells are mountain; else desert,
  forest or lakeland by climate; highland near a range or massif; else plain.
- Names: "<syllables> <noun>". The noun is one of three per kind; the syllables are A + C, or A + B + C (30 %).
  In-game names are localised strings built from the syllable keys, so a Russian client reads "Холмы Кардун".
- `owner_share` samples `territory.owner_at` at every 32-tile cell of the region. It is cached until the territory
  module finishes its next job.

### Scarcity

- **Specialties.** The skeleton dry-runs the specialty and home-oil placement, which draws no random numbers, to get
  their positions. `world.assign_specialties` then values every assignment of the drawn kinds to the spawns:
  - a nation's value is every deposit's value shared by inverse square distance and divided by max(1, distance / 500);
  - basic ores missing from a nation's specialty count 1.5×.
  - The lowest spread wins; ties keep the drawn order, so 2-nation worlds keep their W1 random stream.
- **Lacks.** Every nation lacks at least one basic ore beyond its start kit: mixed lacks coal, iron lacks copper and
  coal, copper lacks iron and coal, coal lacks iron, copper and stone.
- **Contested ground.** As in W1: copper and iron majors on the bisectors, the oil swamp in the middle.
- **Uranium.** 20,000 per patch, at 0.45 of the swamp's radius along a bisector, kept 12 tiles from the wells.
  - It uses the ordinary extractor (`rts-uranium-ore`, category basic-solid, no acid).
  - A build check (`world.geology_check`) refuses any mining drill whose mining area reaches uranium until the force
    has researched `rts-geology` (30 advanced kits, last in tree order).
  - The check covers players' ghosts and robot builds; script placements are trusted, as in `territory.lua`.
- **Rare deposits.** 6 × 6 patches of 3,000 in category `rts-rare`, which no drill mines yet (the rare extractor and
  the bonuses are M3). 60 % lie 20–36 tiles from a city-state's centre, the rest on mountain rims, desert and mountain
  regions first.

### City-states

| Anchor | Spot |
|---|---|
| each contested copper region | the deposit's centre (its patches ring it), else the nearest clear spot |
| the oil swamp | the swamp's edge: the spot farthest from the spawn-to-centre lines, up to 90 tiles, then the nearest to the swamp |
| the coast | the most contested coastal spot (equal path distance to its two nearest nations) |
| passes and fords | 60–90 tiles beside the crossing, inner crossings first: the path through it stays out of turret reach (ring 10 + range 21) |
| contested iron | fallback |

- **Placement rules.** Each city-state needs a buildable 29 × 29 box and stays 300 tiles from every spawn, 200 from
  other city-states and 150 from ports.
- **Founding.** It is founded when its chunks exist. `world.apply` requests their chunks before the background fill,
  so they appear about 13–14 s after Start at speed 1 (4-nation save/load run, seed 611), long before the rest of the map (93 s).
- **Land and stock.** Village tier: 48 tiles of land; a town's 72 would reach the marching lines. Goods by anchor:
  copper plates and cable; plastic and sulfur; fish and stone bricks; stone bricks and gears; stone and coal. Plus 200
  magazines, topped up when the network holds fewer than 100.
- **Garrison.** `rts-turret` on a ring of 10 tiles, fed by `production.lua` from the City Center's network.
  - Growth: 4, then +1 every 10 minutes up to 10. A destroyed turret is not replaced, so a siege can win.
  - Only for city-states that `rts-neutral` still holds, so a captured one stops growing.
- `cities.lua` registers the city with `archetype = "city_state"` and `title = "Free City of X"`. It is not a capital
  and `storage.nations["rts-neutral"]` stays nil.

### Ports, ruins, city sites

- **Ports.** Candidates are coastal cells (sea within 5 cells) or cells 30–70 tiles from a dry map edge, at least 300
  tiles from every spawn. The search starts greedily from 24 candidates, adds the candidate that keeps the
  nearest-port spread lowest (500 tiles apart; a dry edge costs a little on a map with sea), and keeps the best set.
- **Ruins.** Ranked by distance from the spawns plus a random term, then −250 in deposit regions, +150 in desert,
  swamp or mountain regions, +120 on a mountain rim and +80 near a map corner. They keep 140 tiles from city-states and
  100 from ports.
- **City sites.** W1's rule, minus every site within 96 tiles of a city-state (the City Center spacing).

### Chokes

- **Planned crossings.** Every pass and ford is a choke, as in W1. It gets `regions` from points 40 tiles beyond the
  barrier on both sides and `measured_width` from the distance field.
- **Distance field.** It is a chamfer field of every passable cell's distance to water, mountain or the map border.
- **Ridge cells.** A cell is a ridge cell when the field falls on both sides along some axis and a blocked cell
  follows within its clearance on both sides. The width limits are 16–80 tiles (the study's limit).
- **Gap chokes.** The narrowest cells of each 8-connected cluster of ridge cells get a bottleneck test: cut a disc of
  radius D + 1 around the cell and flood a 49 × 49-cell window from the rim. Two or more separate sides of at least
  40 cells make a "gap" choke ("Narrows of X"). The test skips cells within 140 tiles of a spawn, near the map edge,
  and near a planned crossing or another gap.
- **Results.** By design the W1 skeleton keeps obstacles far apart, so gaps are rare: 3 in 20 four-nation worlds, and
  1–2 in some 2-nation worlds. A 4-nation 2048 world has 8–10 named chokes. A 2-nation world has the 4 planned
  crossings; the check asks for every crossing to be named there, and for 5 on 4-nation maps.

### Claimable cells (Territory victory)

`territory.share` used to divide by every grid cell, so the Territory victory's 60 % was out of reach. The world now
defines the claimable cells:
- **Which cells.** Land and marsh cells of the sampled 8-tile grid. Mountain, water and ford cells and a 2-cell
  (16-tile) rim at the map border are left out. The territory grid has the same cells.
- **Storage.** A bitmap of row strings in `storage.world.plan.claimable`, built at planning, read by
  `world.claimable(cx, cy)` and `world.claimable_count()`.
- **Counting.** `territory.lua` keeps `T.claim[fid]` with `T.counts`: one test per ownership change, not per scan.
  `territory.share` = `territory.claimable_cells(force) / world.claimable_count()`.
- **Log line.** "world: claimable 88 % of 65,536 cells (57,356 cells: land and marsh, 2-cell rim left out)".
- **Measured share.** 88–94 % of the map on 2048 worlds and 89–93 % on 1536 (16 worlds). The worlds are about 92 %
  land, so the lead's expected 40–80 % does not hold. The check `world_claimable` accepts 40–95 % and compares every
  force's `T.claim` with a recount of the grid.

### Strategic layer (`strategic.lua`)

- Per force, chart-mode objects (`forces = {force}`):
  - region names with a resource line of rich-text icons;
  - a dashed circle and a name per choke;
  - the name of every city: capitals and city-states get an icon, in the owner's colour;
  - port names;
  - one marker per own division, moved every 2 s.
- **Rebuild.** A new match refreshes every match force. City signals, renames and captures redraw the city names.
- **Size.** Text has a fixed world size, scaled at a 2048 map so a region name is about 16 tiles tall. A zoom tier
  scales the force's texts in place: × 1.7 below zoom 0.045 and × 1.3 below 0.09.
- **Cost.** About 61–69 objects per force on a 4-nation 2048 world; a refresh takes 0.3–2.4 ms.
- **Minimap.** `strategic.minimap_mode(player)` defaults to regional: the HUD minimap (`rts_hud_minimap`) shows 1,000
  tiles (zoom 0.22) centred on the camera, clamped to the map, and is updated every 15 ticks. **N** (`P4.KEYS` in
  `hud.lua`) switches to world (zoom 220 / (size + 16), centred) and prints the mode. Click-to-jump keeps working
  because the HUD reads the element's position and zoom.
- **Zoom.** Nation players get `set_zoom_limits(remote, {closest = 2, furthest = {distance = 1.1 × size,
  max_distance = same}, furthest_game_view = 0.15})`, re-applied whenever the camera resets them. Without
  `max_distance` the engine caps the distance at 500 tiles. A Skirmish match restores the camera's limits.

## Measurements

The machine ran other agents' tests the whole time: load average 8–14.

### World matrix: 20 seeds × 4 nations, 2048 (`IMAGES=1 SEED=20261016 tools/world-seeds.sh p5m2w-final4 20 '4' 2048`)

**240/240 checks, 0 errors.** Every run passed the 7 W1 checks and the 9 M2 checks: lacks, specialty, scarce fair,
chokes, city-states, ports, sites, region names, chart labels.

| Measure | Result |
|---|---|
| Start (plan + core + kits): min / median / max | 3.60 / 4.23 / 5.07 s (W1 tree, same seeds, same hour: 3.39 / 4.12 / 4.97 s) |
| Forced fill of the rest | 8.3–8.8 s; `world_generation_15s` 20/20 |
| M2 planning | median 241 ms, max 267 ms (context 75, regions 24, chokes 54, uranium + ports 33, city-states 7, ruins 29, city sites 28, rare + scarcity 8; one 4-seed run) |
| Sites per world | 6 city-states, 4 ports, 10 ruins, 2 uranium, 6 rare, 32 city sites, 6 oil |
| City-state anchors (120) | copper 40, oil 20, coast 13, pass 24, ford 23 |
| Chokes per world | 8–10 (3 gap chokes in 20 worlds) |
| Nearest-port path spread | median 0.021, max 0.069 (limit 0.15) |
| Scarce deposits: two nearest nations' path difference | copper median 3.0 %, max 7.6 %; iron 3.1 % / 9.6 %; oil 1.2 % / 3.3 %; uranium 1.7 % / 5.7 % (limit 15 %) |
| Specialty search | value spread median 0.146 (drawn order 0.208); reassigned in 18 of 20 |
| Specialty path from its capital | 310–400 tiles; nearest rival at least 763 |
| Region kinds (20 worlds) | highland 147, swamp 120, plain 85, lakeland 12, coast 11, desert 8, forest 5 (mountain threshold 15 % then; at 6 % 1–2 mountain regions per map appear, below) |

Other sizes:

| Run | Checks | Start |
|---|---|---|
| 3 seeds × 2 nations (1536) and 3 nations (2048), `SEED=31337` | 72/72 | 1.8–2.0 s (2), 2.9–3.8 s (3) |
| 2 seeds × 4 nations, 3072, `SEED=30724` | 24/24 | 5.2 s and 8.8 s (the second under a load spike: its W1 planning alone took 3.5 s); fill 22.5–25.4 s |

Mountain regions at 6 %: 1–2 per map in all 8 worlds of the last two runs.

### 60-minute 1v1 Nation, 2048, seed 501 (the M1 acceptance; `KEEP_TREE=build/p5m2-world/factorio-rts PERF=1 EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN=60 SEED=501 SPEED=6 tools/autotest-run.sh ...`)

| Run | Result |
|---|---|
| 1st (before the scout fix) | 46/48. Both AIs razed all 4 city-states by minute 20 (Open issues 1). `train_items` failed: 13,869 |
| 2nd (scout fix) | **47/48, 0 errors.** Every M1 check passed: second city 7:56 / 7:03, Age II 14:45 / 13:19, lines 24:45 / 23:00, 23,561 items by train, both capitals at 60:00. Game minutes 56–60 at speed 1: 59.998–60.135 s of wall clock, i.e. 60 UPS. The one failure was mine: the old oil-swamp city-state, 55 tiles from the centre, was razed by a division marching to the enemy capital through the centre (minute 17). The anchor moved off the marching lines afterwards |
| 3rd (final tree, `p5m2w-m1acc3`) | **48/48, 0 errors.** Second city 7:55 / 7:03, Age II 14:45 / 13:19, lines 22:15 / 24:01, 23,490 items by train (14,122 + 9,368), both capitals at 60:00. All 4 city-states alive at 60:00 with 9 turrets each (4 + 5 by the garrison growth); the oil-swamp city-state at (-24, 113), 115 tiles from the centre. Game minutes 56–60 at speed 1: 59.994–60.097 s of wall clock (60 UPS) |

M1 baseline (`docs/qa/phase5-m1-integration-notes.md` §4.1): towns 7:54 / 7:03, Age II 14:46 / 13:19, lines 19:56 /
27:20, 27,822 items. The 2nd run matches it within run-to-run variance.

Script cost (PERF, minute 60 of the final run): `world` 0.0008 ms/tick, `strategic` 0.0009 ms/tick, `cities` 0.0012 ms/tick, `territory` 0.0010 ms/tick (the AI commanders 0.053, production 0.136).

### Other runs on the work copy

| Run | Result |
|---|---|
| Functional probe (`EXTRA_LUA=tools/probes/world2_autotest.lua`, 4 nations, seed 4242) | 7/7: an extractor ghost over uranium refused without Geology and kept with it (and kept away from uranium); a city-state founded "21 minutes ago" grows from 4 to 6 turrets in two garrison steps and refills its magazines; the city-state record (archetype, no capital, no nation, radius 48); the home region's owner share and resources; the scarcity record; a route label (line and text) counted and removed; refresh counts |
| Save/load (`SAVE_MINUTE=3 tools/saveload-check.sh`, 4 nations, seed 611) | 0 errors before and after the load; the match runs on (minutes 4–5) |
| Skirmish smoke (legacy units, seed 9090) | 65/65, 0 errors (twice: before and after the final changes) |

### Trial merge onto the current `mods/` tree (people, treasury and diplomacy synced; before "sync open")

`sync_world2.py` (session scratchpad) applies this package to a copy of `mods/` (`build/p5m2w-merge/`) by anchors on
the current files:
- It copies the own files.
- It takes `world.lua` from the work copy and re-applies m2-treasury's two `world.place_port` hunks. The script stops
  on any other foreign hunk in `world.lua`.
- It adds the N entry to the list-style `P4.KEYS` that diplomacy and treasury created in `hud.lua`, instead of my own
  key table.
- It leaves out my `ai/scout.lua` hunk: `mods/` already restricts `scout.beaten_enemy` to match forces ("Phase 5 M2
  treasury / world"), and `is_enemy` there asks `diplomacy.hostile`.

| Run on the merged copy | Result |
|---|---|
| Skirmish smoke (legacy units, seed 9090) | 65/65, 0 errors |
| World matrix, 4 seeds x 4 nations | 48/48; m2-treasury's trade posts stand on the port sites and take their names from the regions ("Eldwyn Coast", "Ulven Waters") |
| Functional probe | 7/7 |
| 25-minute 4-nation AI match (seed 611, speed 4) | 76/80, 0 errors; the 4 failures are rts-ai-1's lines, Age II and second city and rts-ai-3's districts |
| The same match on `mods/` without this package | 66/71, the same AI failures plus rts-player's Age II deadline: they come from the packages already in `mods/` (rts-ai-1 is starved of iron plates from minute 4) |

### Synced into `mods/factorio-rts/` (sync open, 412a5bf plus this package)

| Run on `mods/` | Result |
|---|---|
| Skirmish smoke (legacy units, seed 9090) | 65/65, 0 errors (twice) |
| Functional probe, 4 nations, seeds 4242, 611, 9001 | 7/7 each |
| World matrix, 6 seeds x 4 nations, 2048 (`SEED=20261016`) | 78/78 (13 checks each, `world_claimable` included); start 3.60 / 4.47 / 4.99 s |
| World matrix, 4 seeds each of 2, 3, 4 nations (before the claimable range was widened) | every check but `world_claimable` passed (claimable 87.8–93.1 % against the then 40–80 % range) |
| Territory victory (`tools/probes/world2_territory.lua`, 4 nations, seed 611, victory "territory") | 2/2: five strong forts give rts-ai-1 63.2 % of the claimable cells (36,274 of 57,356), only 56.5 % of all cells. `territory.share` equals the recount. `wars.lua` logs "territory rts-ai-1 holds 63.2 %" and ends the match by a Territory victory 180 s later; the probe saw it 188 s after setup |

### GUI check (`tools/probes/world2_gui.lua`, `RTS_LOCALE=en`, window capture by `screencapture -l`)

5/5 checks: labels (20 regions, 8 chokes, 10 cities, 4 ports for rts-player), zoom limits (furthest 2,252.8 tiles),
strategic view (zoom 0.028 in the map view), regional minimap (zoom 0.22, following the camera, clamped to the map),
world minimap (zoom 0.1066). Captures in `docs/qa/phase5-screenshots/`:

| File | Shows |
|---|---|
| `world2-strategic.png` | the whole middle of a 4-nation world at zoom 0.028: region names with resource icons, city-states with their land, both capitals |
| `world2-strategic-regional-minimap.png` | the same view, the regional minimap and the alert "Lindun Plains: Hauler lost" |
| `world2-home-region.png` | the player's home region in the map view |
| `world2-city-state.png` | a copper city-state in the middle of its deposit |
| `world2-choke.png` | a pass with its marker and the city-state that guards it |
| `world2-minimap-regional.jpg`, `world2-minimap-world.jpg` | the game view with the minimap in each mode |

`game.take_screenshot` cannot render the map view (W1 gotcha); the probe logs `W2GUI_CAPTURE <tag>` and the driver
grabs the window. The driver (a Swift window-id helper and a log watcher) is in the session scratchpad, not in the
repo.

## Gotchas

1. **`ZoomSpecification.distance` without `max_distance` is capped at 500 tiles.** The limits read back as
   `{distance = 2252.8, max_distance = 500}` and the view stopped at zoom 0.08.
2. **`game.take_screenshot` refuses zoom below 1/32.**
3. **A bucket queue must not keep empty buckets.** The first version created buckets ahead of the queue on every step
   and never ended (the server hung in planning).
4. **`cities.found` with `raise_built`.** The City Center registers inside `create_entity`, before `found` regains
   control, so options must travel through a module variable (`founding_opts`).
5. **4-connected BFS distances are not fair distances.** See Path distances.
6. **Any non-participant force with buildings looks "beaten" to the AI.** See Open issues 1.

## Open issues

1. **AI and `rts-neutral`.** `ai/scout.lua` treated any enemy force with buildings but no CC or barracks as a beaten
   rival, so both AIs "finished" the city-states from minute 6, skipping the Age I reach and parity rules. Scout
   knowledge also made city-states raider-harass and attack targets. In `mods/`:
   - `beaten_enemy` counts match forces only (one merged hunk with m2-treasury);
   - my `scout.step` hunk keeps `rts-neutral` buildings out of `C.known`.
   The deliberate decision to attack or capture a city-state belongs to m2-war's army targeting and the M2 AI.
2. **Armies on attack-move still engage city-states they pass.** The engine's unit AI does this. The oil-swamp and
   choke city-states therefore sit off the marching lines. Without `m2-war`'s capture (City Center indestructible,
   subdued, flipped), a city-state that is fought is razed.
3. **Start time.** The M2 planning adds about 0.1–0.25 s. Under load 9–11 the 4-nation start reached 5.07 s once in
   20 runs (the W1 tree: 4.97 s in the same hour).
4. **Gap chokes are rare.** The W1 skeleton keeps lakes, massifs and spurs at least 140 tiles from barriers, wider
   than the study's 80-tile choke. If more chokes are wanted, W3 can add secondary barriers inside sectors.
5. **Region variety on 4-nation maps.** 17 of the 20 region slots go to homes and deposits, so frontier kinds (desert,
   forest, lakeland, mountain, coast) are rare there. 2-nation maps show all of them.
6. **Uranium and rare items have no use yet.** Uranium ore piles up once mined; rare deposits are unmineable until
   M3's rare extractor.
7. **Territory victory reach.** 60 % of the claimable cells is still about 53 % of a 2048 map. The territory study
   measured 4 nations with 10 cities each owning about 20 % of the cells. Unless the war goals or the AI expand much
   further, Conquest and Score will decide matches; the share threshold is m2-diplomacy's balance.
8. **The N key** is defined in `prototypes/world2.lua`, not in `prototypes/inputs.lua` where diplomacy and treasury put
   F4 and M; the `P4.KEYS` entry is the same kind.
