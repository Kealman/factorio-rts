# Phase 5 M1: territory and City Centers (T1 + C2-lite)

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Contract: `docs/PHASE5-M1.md` (package "Territory + City Centers", section 3 `territory.lua` and `cities.lua`).
Study: `docs/research/scale/territory-cities.md`. Work copy: `build/p5-cities/factorio-rts/`.

Everything here is **Nation mode only** (`storage.match.config.mode == "nation"`). In Skirmish no grid is built, no
city is registered, the build rules return true, the supply hook adds 0, the AI hooks return at once and the HUD hides
the new buttons and recipes. The Skirmish runs in "Validation" behave exactly as the tree before this package.

## Files

| File | Status | What it does |
|---|---|---|
| `scripts/territory.lua` | new | Ownership grid, sources, job queue, borders, build rules, attrition, fort upkeep |
| `scripts/cities.lua` | new | Cities and nations, founding, losing, tiers, supply hook, make targets, alerts, the AI's second city |
| `scripts/citygui.lua` | new | City panel and city list |
| `prototypes/cities.lua` | new | `rts-attrition` damage type, `rts-city-center`, `rts-city-power`, `rts-city-charter`, `rts-fort`, recipes |
| `locale/en/cities.cfg`, `locale/ru/cities.cfg` | new | 61 keys each, same keys and parameters |
| `tools/probes/territory_autotest.lua` | new | Headless autotest of this package (`EXTRA_LUA`) |
| `tools/probes/territory_saveload.lua` | new | Grid checksum and render object count before the save and after the load |
| `tools/probes/territory_grid2048.lua` | new | A 2048-tile grid on any arena, plus a log line with the time of every job-queue tick |
| `tools/probes/territory_worldsites.lua` | new | A stand-in `storage.world` with city sites, for the AI's world-site path |
| `tools/probes/territory_noattrition.lua` | new | Attrition off, for A/B balance runs |
| `tools/probes/territory_gui.lua` | new | GUI probe: borders at zoom 1, 0.15 and in the map view, the panels, a frame-cost comparison |

### Shared hunks

Every hunk is marked "Phase 5 M1" in the code.

| File | Hunk |
|---|---|
| `control.lua` | require `scripts.territory`, `scripts.cities`, `scripts.citygui` after `scripts.commander` |
| `data.lua` | require `prototypes.cities` last |
| `balance.lua` | `balance.buildings["rts-city-center" / "rts-fort"]`; `balance.nation.territory`, `balance.nation.cities` |
| `scripts/buildings.lua` | `KIND_BY_NAME["rts-city-center"] = "hub"`, `["rts-fort"] = "fort"`; `buildings.on_build_check(fn)` and the check loop at the top of `on_built` |
| `scripts/supply.lua` | `supply.on_cap(fn)`: hooks add to the cap (cities: tier supply) |
| `scripts/logistics.lua` | `logistics.NAME_HOOKS[entity name]`: hub subtypes name themselves and get no "Hub n" number |
| `scripts/research.lua` | Armor II/III heal-back skips damage type `rts-attrition` |
| `scripts/events.lua` | `events.on_signal(name, fn)`, `events.emit(name, data)` (alias `events.raise`): script signals between modules |
| `scripts/hud.lua` | `P4.NATION_ONLY`, `P4.nation()`; Production tab gets `rts-city-charter`, `rts-fort`; nation-only build items and factory recipes are skipped in Skirmish; strip: a "Land N%" button (territory share) that shows or hides the city list, click action `cities`; alert styles `city-founded`, `city-tier`, `city-lost`, `territory-lost` |
| `scripts/ai/commander.lua` | one line after `hubs.step(C)`: `deps.cities.ai_step(C, surface)` |
| `scripts/ai/construction.lua` | `place_ghost` asks `deps.territory.can_build` first; a refused spot waits `TERRITORY_GRACE` (120 s) longer than a blocked one |
| `scripts/match.lua` | **not synced**: the test copy keeps `config.mode` in `normalize_config`; that field is m1-world's |

`commander.lua` needed no change: a City Center ghost is stocked and built by the Commander's field construction exactly
like a hub ghost. Teardown: both modules register `match.on_teardown` callbacks (the existing list), so `match.lua` has
no hunk of mine.

## Prototypes

| Prototype | Numbers |
|---|---|
| `rts-city-center` (roboport) | Vanilla roboport, CC grey with a green tint. 1800 HP, logistic radius 16, construction radius 30, buffer 40 MJ, input 500 kW, radar 2 chunks, military target, raid target, not deconstructable. Mined into `rts-city-charter`. |
| `rts-city-power` | Hidden `electric-energy-interface`, 700 kW secondary output, immune. With the hub core of the composite the city core gives 1 MW. |
| `rts-city-charter` (item) | Places `rts-city-center`. Stack 5, subgroup `rts-economy`. Factory recipe, enabled (Age I): 80 iron, 30 copper, 40 stone, 20 s. Stone instead of stone brick, because the AI mines stone but never smelts bricks. |
| `rts-fort` (ammo-turret) | Gun turret tinted brown, 600 HP, range 18, firearm magazines. Item and factory recipe: 30 iron, 20 stone, 6 s. A new fort gets 20 free magazines, then the network covering it feeds it like a turret. |
| `rts-attrition` (damage-type) | No resistance lists it. |

## Territory (`scripts/territory.lua`)

### Grid and sources

- Cells of 8×8 tiles. The side is `storage.world.size` when the world module wrote it, else `2 * arena_half`, centred on
  (0, 0). The large arena gives 64×64 cells; a 2048 world gives 256×256.
- Two layers of row strings: `owner` (force id byte, 0 neutral) and `city` (city id byte, 0 none).
- Sources, in tiles (`balance.nation.territory`):

| Source | Radius | Strength |
|---|---|---|
| Capital (the starting CC) | tier radius + 24 (96 at tier 2) | tier strength + 1 |
| City Center village / town / city | 48 / 72 / 96 | 3 / 4 / 5 |
| Fort | 24 | 2 |
| Hub (`rts-hub`) | 16 | 1.5 |
| Radar | 16 | 1 |

- Score `s × (1 − d² / (r + 1)²)` in cells. The highest score wins; the current owner keeps a cell unless a
  challenger beats its own best score by 15 %.
- The city of a cell is the winning source's city; forts, hubs and radars give their cells to the nearest city of their
  force.
- **Capital bonus.** The contract gives the capital tier 2 (72 tiles). The first Nation AI runs showed the AI's natural
  ore lines at 72 to 80 tiles refused, so the capital claims 24 tiles more, the study's "+3 cells" for the capital.

### Job queue

A source change queues the bounding box of its old and new disk. A queued job that has not started absorbs an
overlapping new box. Each tick: at most 3000 cells recomputed, then at most 16 render segments redrawn. A finished job
emits `"rts_territory_changed"` per force whose land changed. `territory.flush()` runs the queue to the end (tests).

### Borders

- Render segments of 16 cells: horizontal boundaries, vertical boundaries and a per-row chart tint.
- Each border edge between different owners gets a line on each owned side, 0.5 tiles inside, in the force colour
  (`match.FORCE_COLORS`, premultiplied alpha 0.9).
  - Game view: dashed 12 px line (dash 1.5, gap 0.75 tiles) on the ground.
  - Chart view: solid 3 px line, plus a filled rectangle per owned row run at alpha 0.16.
- Borders are public: no `forces` filter.
- Only the segments touched by changed cells are redrawn.

### Build rules

| Class | Members | Own | Neutral | Enemy |
|---|---|---|---|---|
| economic | extractor, smelter, factory, barracks, lab, solar, steam plant, accumulator, anything not listed | yes | no | no |
| outpost | fort, hub, radar, turret, laser turret, depot | yes | yes | no |
| infra | belts, inserters, poles, pipes, walls, gates, rails, signals, train stops, rolling stock, stockpile | yes | yes | no |
| city | City Center | no (spacing) | yes | no |

- City Center: at least 96 tiles from every City Center and capital of any force, at most 4 cities per nation. The
  capital's land lies within 96 tiles of it, so a new city goes on neutral land or on far own land (a fort's, a hub's).
- Players: `on_built_entity` with a ghost or an entity. A refused ghost is removed and the player gets a flying text
  ("Enemy land: nothing can be built here", "Smelter can only be built on your own land", "Too close to another
  city ...", "City limit reached ..."). The check runs inside `buildings.lua`'s build handler, before registration.
- Robots: the same check on `on_robot_built_entity`. A refused entity is removed and its item goes back to the force's
  pool.
- Script placements (`script_raised_built`, `script_raised_revive`) are trusted.
- AI: `construction.place_ghost` asks `territory.can_build` and waits while refused.

### Attrition

- Every 300 ticks, every unit in `storage.units` on another force's land is checked.
- A unit is hit when its 5×5 cell window is all that force's land (at least 16 tiles deep) and no own City Center,
  capital, hub or fort is within 24 tiles.
- Damage: 1.5 % of max health, type `rts-attrition`, dealt by the land's owner. The Commander takes half.
- Measured: 18.0 % in 60 s at 40 tiles inside, 0 % next to an own hub (see Validation).

## Cities (`scripts/cities.lua`)

- **Capital.** In Nation mode `buildings.on_added` of the starting CC registers it as the force's capital: tier 2,
  radius 96, `storage.nations[force] = {capital = id, age = 1}`.
- **Founding.** A City Center registered by any path (robots, the Commander, AI revive, `cities.found`) becomes a
  village: radius 48, its `rts-city-power`, a territory source, a "City founded: X" alert, the signal
  `"rts_city_founded"`. It is a hub subtype, so `logistics.lua` builds its hub composite: 2 stockpiles, 10 + 6 robots,
  its own logistic network with the hub defaults (keep 50 iron, 20 copper). The hub panel shows it under the city's name.
- **Losing.** A City Center that dies or is removed: the city, its power and its land go; "City lost: X". A lost
  capital passes to the force's lowest remaining city, which gets the capital bonus.
- **Tiers.** Every 600 ticks per city: the buildings of the force on its land (walls and stockpiles excluded) and the
  goods delivered to its market (the sum of rises of its network's item total between checks).

| Tier | Radius | Supply | To reach it |
|---|---|---|---|
| Village (1) | 48 | 10 (its hub cap) | founding |
| Town (2) | 72 | 20 | 10 buildings, 400 delivered |
| City (3) | 96 | 30 | 25 buildings, 2000 delivered |

  The capital starts at town and adds its tier supply minus 20 to the CC's 40, so 40 at tier 2 and 50 at tier 3.
- **Make targets.** `cities.make_targets(id)` returns `{[item] = n}`; `cities.set_make_target(id, item, n)` writes one
  (0 or nil clears) and emits `"rts_make_targets_changed"` {city, item, n}. The city panel edits them too.
- **Territory lost.** A finished territory job that took 4 or more cells from a force gives "Territory lost near X
  (N cells)", at most once per 30 s per force.

### API

```
cities.found(force, position, opts) -> city_id      opts.entity = existing City Center / CC; else one is placed by script
cities.get(city_id) -> {id, force, name, position, center, tier, radius, archetype, networks, make, ...}
cities.of_center(unit_number), cities.of_entity(entity_or_position), cities.for_force(force_name)
cities.make_targets(city_id), cities.set_make_target(city_id, item, n), cities.rename(city_id, name)
cities.display_name(city), cities.radius_of(tier, capital), cities.supply_total(city), cities.next_tier(city)
cities.ai_step(C, surface)                          AI hook (scripts/ai/commander.lua)
territory.owner_at(position), territory.city_at(position), territory.share(force), territory.cells(force)
territory.city_cells(city_id), territory.can_build(force, name, position_or_box, direction) -> ok, reason, class
territory.add_source(entity, radius_tiles, {strength, kind, city}), territory.update_source(un, radius, strength)
territory.remove_source(un), territory.flush(), territory.pending(), territory.checksum(), territory.object_count()
signals: "rts_territory_changed" {force, cells, delta, lost, lost_at, lost_city, box}, "rts_city_founded" {city},
         "rts_city_tier" {city, tier}, "rts_city_lost" {city, force}, "rts_make_targets_changed" {city, item, n}
```

## GUI

- **Build menu.** In Nation mode the Production tab adds City charter and Fort; the factory's recipe grid adds both
  recipes. Both are hidden in Skirmish.
- **Strip.** In Nation mode: a "Land N%" button (territory share); a click shows or hides the city list.
- **City list** (top left, under the kill feed). One row per own city: a jump button with its name, then tier and
  land cells, and a magnifier that opens the city panel.
- **City panel** (left of the hub panel). It opens while an own City Center or the capital is selected, or from the
  list. It shows name and tier, a rename field, tier and radius, land cells and their share of the nation, supply, the
  next tier's requirements, the logistic networks on its land, and the make-target table with a choose-item button.

### GUI check

`tools/gui-run.sh` with `tools/probes/territory_gui.lua` (1280×800 window, Russian client). It starts a Nation match,
adds a second city, a fort and a hub for the player, and captures the window with `screencapture` at each view.
Captures: `docs/qa/phase5-screenshots/cities-*.png`.

| View | Result |
|---|---|
| Zoom 1 (`cities-zoom1.png`) | Dashed blue border lines, clearly visible across grass and water |
| Zoom 0.15 (`cities-zoom015.png`) | Dashed lines still clear; the joined land of the capital and the second city outlined in 8-tile cell steps |
| Map view, zoom 0.06 (`cities-chart.png`) | Chart lines (solid) and the filled tint: blue own land, red AI land. The AI's land shows on black uncharted map too: borders are public, as designed. |
| HUD minimap | **Chart objects appear on the HUD minimap** (lines and tint, both forces), in every capture |
| City panel (`cities-citypanel.png`) | Capital panel next to the CC's stockpile panel: tier, radius 96 (capital), land 354 cells (76 % of the nation), supply 40, next tier 2/25 buildings and 0/2000 goods, 2 networks, make targets |
| Second city (`cities-secondcity.png`) | Village panel: radius 48, 113 cells, supply 10, next tier 0/10 and 0/400 |
| City list | Top left: "Capital, town, 354 cells" and "Ironford, village, 113 cells", jump and magnifier buttons |
| Strip | "Land 11.4%" button between Research/? and Menu; everything fits in Russian |

- Render mode. In the RTS camera's remote view `player.render_mode` reports `chart_zoomed_in` at zoom 1 and 0.15,
  and the "game" render objects (dashed lines) are drawn there.
- Map view. With the zoom limit lowered to 0.02, zoom 0.06 switches to `chart`, and only the chart objects show.
  The RTS camera normally stops at 0.15 in the game view, so players see the chart borders on the HUD minimap.
- `game.take_screenshot` always renders the game view. At zoom 0.06 it still shows the dashed lines
  (`cities-zoom006-gameview.png`).
- The first GUI run showed two problems, both fixed:
  - The strip overflowed in Russian ("Мен"), with a separate share label and a Cities button. They are now one button.
  - The panel's "Переименовать" button was clipped. It is now an icon button.

Frame cost: the client's CPU time over 15 s each with all 331 border objects visible, hidden (`visible = false`) and
visible again, at zoom 0.15 over the capital's border:

| Phase | Client CPU |
|---|---|
| visible | 25.1 % |
| hidden | 23.7 % |
| visible again | 19.2 % |

The difference is inside the run's noise (the client also simulates the AI match), so no cost is measurable: below
about 0.5 ms per frame. The study's 55,000-object stress case was not repeated in the GUI.

## AI

- `cities.ai_step(C, surface)` runs in every commander run after `hubs.step`.
- From 5:00 of match time, a force with one city picks a site and adds a `rts-city-center` entry to its construction
  plan. The builder factory makes the charter (`orders_data.FACTORY_RECIPE["rts-city-charter"]`, set by
  `cities.lua`), and construction revives the ghost like any building.
- Sites:
  - With `storage.world.sites`: the nearest `city_site` that passes `territory.can_build` and lies at least 96 tiles
    from the capital.
  - Without a world: 110 tiles from the capital, towards its first expansion or the arena centre, then ±25°, ±50°,
    ±75°.
- A second city that is lost is planned again after 120 s, at most 4 sites per match.

## Validation

All Nation runs use the large arena (512 tiles, 1 AI, "chokes" map) with `mode = "nation"` in the match table; the test
copies add `out.mode` to `match.normalize_config` until m1-world's hunk lands. "Work copy" is
`build/p5-cities/factorio-rts` before the sync, "merged" is `mods/factorio-rts` after the sync (with the demolish
work another agent added meanwhile) plus the same stand-in, in `build/p5-cities-val/`.

### Territory autotest (`tools/probes/territory_autotest.lua`)

```sh
KEEP_TREE=build/p5-cities-val/factorio-rts EXTRA_LUA=tools/probes/territory_autotest.lua \
  STOP_ON='territory autotest summary' SEED=1234 tools/autotest-run.sh p5v-terr \
  '{opponents = 1, difficulty = "normal", size = "large", enemy_brain = "ai", mode = "nation"}' 300
```

| Run | Result | Errors |
|---|---|---|
| Work copy, arena grid 64×64 (`p5c-terr2`) | 32/32 | 0 |
| Work copy, 2048-tile grid 256×256 on the same arena (`p5c-terr2048`) | 32/32 | 0 |
| Merged tree (`p5v-terr`) | 32/32 | 0 |
| Merged tree after the divisions package synced (`p5v2-terr`) | 32/32 | 0 |

The 32 checks:

- `grid_ready`: both capitals are cities (tier 2, radius 96) and own their spot; 346 / 325 cells; 232 border objects.
- 24 placement checks: 8 buildings × own, neutral and enemy land, through the real `on_built_entity` handler. Every
  result matches the class table, including the City Center refused on own land by the spacing.
- `robot_refused`: a robot-built smelter on neutral land is removed and the pool gets the smelter back.
- `attrition_deep`: 6 walkers 40 tiles inside AI land, cease-fire both ways, lost 18.0 % each in 60 s.
- `attrition_supplied`: 6 walkers as deep, next to an own hub, lost 0.0 %.
- `found_far`: a City Center ghost 301 tiles from the capital, a charter in the pool, and the Commander walking there.
  The city was built 20 s later: tier 1, radius 48, own land, city cells 112, its own network (#7 vs the capital's
  #2) with its hub entry, power part valid, supply 50 → 60, one "city-founded" alert.
- `make_targets`: set, read, clear, two signals.
- `tier_up`: 10 solar arrays on its land and 500 plates into its market made it a town in 18 s: radius 72, cells
  112 → 232.
- `city_lost`: its City Center dies. The city is gone, its centre is neutral, one "city-lost" and one
  "territory-lost" alert, supply back to 50.

### Performance

`PERF=1` (per-module handler time, `scripts/events.lua`), 10-minute Nation AI autotests, ms per tick averaged per
minute:

| Run | territory | cities | citygui |
|---|---|---|---|
| Arena grid (`p5c-ai-nation`) | 0.0017–0.0033 | 0.0002–0.0006 | 0.0002–0.0003 |
| 2048-tile grid (`p5c-ai-2048`) | 0.0017–0.0035 | 0.0003–0.0005 | 0.0001–0.0003 |

- Contract limit: < 0.1 ms per tick. Build checks run inside `buildings`' handler, and its whole cost stays at
  0.0001–0.0003 ms.
- Job-queue ticks on the 2048 grid (`PROFILE_STEPS`):
  - The worst tick took 0.87 ms with 24 segments.
  - The segment budget is now 16, so the worst case stays near 0.6 ms.
  - A capital's first claim takes 3 to 6 ticks; a city's claim 3 to 4 ticks.

### Save and load (`tools/saveload-check.sh` with `tools/probes/territory_saveload.lua`)

The probe adds a second city, a fort and a hub 5 s into the match, so the save holds 5 sources and 3 cities.

| Run | Before the save (last line) | After the load | Errors |
|---|---|---|---|
| Work copy (`p5c-saveload2`) | checksum 748209388, 342 objects (342 valid), cells {374, 204} | identical | 0 / 0 |
| Merged (`p5v-saveload`) | checksum 1128215713, 341 objects (341 valid), cells {479, 325} | identical | 0 / 0 |

### Skirmish unchanged

Same seed (99), work copy against the tree before this package (`build/p5-cities-baseline`):

| Scenario | This package | Before | Log diff (timings and the research turret list normalised) |
|---|---|---|---|
| 1v1 normal medium | 21/22, `outcome` FAIL | 21/22, the same `outcome` FAIL | 0 of 3259 lines |
| Legacy waves (`legacy-units`) | 65/65 | 65/65 | 0 of 486 lines |
| Merged tree, 1v1 normal medium | 21/22, the same FAIL | | 0 lines apart from 5 lines logged after the stop |
| Merged tree, legacy | 65/65 | | |

- The `outcome` failure comes from seed 99 itself: one AI stops producing at minute 9 in both trees.
- The only Skirmish-visible trace of this package: research's turret list now names `rts-fort`, a prototype no
  Skirmish map contains.

### Nation AI (10-minute AI autotests, both forces AI commanders)

| Run | Autotest | Second cities |
|---|---|---|
| `p5c-ai-nation` (seed 1234, capital radius 72) | 22/22, both alive | both founded at about 6:10, 110 tiles out; rts-ai-1's was destroyed and rebuilt by its repair pass |
| `p5c-ai-2048` (seed 4321, 2048 grid, radius 72) | 22/22, both alive | both founded; rts-player's destroyed and rebuilt |
| `p5c-ai-nation2` (seed 4321, radius 96) | 22/22, both alive | both founded; rts-ai-1 lost its second city and then its capital |
| `p5c-ai-sites` (seed 1234, radius 96, stand-in world sites) | 21/21, rts-player won at 8:07 | both planned on world sites 160 tiles out; rts-player's built; rts-ai-1 lost its capital at 6:24 first |

| `p5v-ai-att` (merged, seed 4321) | 22/22, both alive | both founded; rts-ai-1 lost its second city, then its capital |
| `p5v-ai-noatt` (merged, seed 4321, attrition off) | 21/21, rts-player won at 10:23 | rts-player founded; rts-ai-1 lost its second city and its capital |

- **The AI founds its second city.** Every force in every run planned one at 5:00 and built it within about 1:15. The
  charter costs 80 iron, and the builder factory competes with the barracks for it.
- **Attrition is not why rts-ai-1 falls.** In the A/B pair (same seed), attrition took 41 hp from rts-ai-1 and 811 hp
  from rts-player, whose attacks go deep into AI land. Without attrition rts-ai-1 was out earlier (10:23).
- **The economic doctrine gains most in Nation mode.** It expands through hubs, and those are no longer cut off by the
  land rule. With the 72-tile capital, both AIs kept their capitals to minute 10 on both seeds. With the 96-tile
  capital, rts-ai-1 (aggressive) lost its capital in 4 of 4 runs.
- **Open question for the integration agent:** AI-versus-AI balance in Nation mode. See the Skirmish large runs with
  the same seeds below.

Skirmish (no territory at all) on the same large arena and seeds, merged tree:

| Seed | Skirmish | Nation, capital 96 |
|---|---|---|
| 1234 | rts-ai-1 lost its CC at 6:39, out at 8:31 (21/21) | rts-ai-1 lost its capital at 6:24 (`p5c-ai-sites`) |
| 4321 | both alive at 10:00 (22/22) | rts-ai-1 lost its capital after 8:00 (`p5c-ai-nation2`, `p5v-ai-att`) |

On seed 1234 the aggressive AI falls in Skirmish too. On seed 4321 it falls only in Nation mode. The economic side
gains more from the Nation rules than the aggressive one, and the effect is worth a balance pass in the integration
batch.

## Gotchas

1. **The remote view reports `render_mode = chart_zoomed_in`, but "game" render objects are drawn there.** Only the
   real chart view (below the game-view zoom limit) switches to the "chart" objects. The RTS camera never goes below
   0.15, so in play the chart borders show only on the HUD minimap. That is enough, because the minimap draws them.
2. **`game.take_screenshot` cannot capture the chart view.** The map-view capture needs an OS screenshot of the
   window: `screencapture -l <window id>`. The driver used for the GUI check is in the session scratchpad and is not
   part of the repo.
3. **`events.dispatch(on_built_entity)` in tests needs `player_index`.** `hud.lua`'s build log formats it with `%d`.
   The probes pass 0, and the build check treats 0 as "no player".
4. **`require` inside a handler fails** ("Require can't be used outside of control.lua parsing"). The GUI probe's
   first run hit it; modules are required at the top.
5. **A City Center is a hub to `buildings.count(force, "hub")`.** The AI autotest's `hub_<force>` check and
   `ai/hubs.lua`'s keep-away list count it. That is intended: it is a logistics node.
6. **A lost city's id stays in the grid's city layer until its removal job has run** (a few ticks). Code that needs
   to know whether a city is alive should ask `cities.get(id)`, not `territory.city_at`.

## Open items and decisions for the lead

- **Mode field.** `match.normalize_config` drops `config.mode` today. m1-world adds it, so this package did not sync
  its test-copy line. Until that lands, Nation mode cannot be started from `mods/`.
- **World geometry.** The grid assumes the world is centred on (0, 0) with side `storage.world.size`. I asked m1-world
  and got no reply. `storage.world.sites` entries are read as `{kind = "city_site", position = {x, y}}`.
- **Capital radius.** The capital claims tier radius + 24 tiles (96 at tier 2), the study's "+3 cells", instead of the
  contract's 72. At 72 the AI's natural ore lines (72–80 tiles out) were refused. On the 2048 world the start kit may
  lie up to 150 tiles out (world contract), which is beyond any capital land. Players then need a hub or fort there;
  the AI's natural hub claims 16 tiles, and its extractors outside wait 3 minutes and are then given up.
  `balance.nation.territory.capital_bonus` is the knob.
- **Charter cost.** 80 iron, 30 copper and 40 **stone**. The lead's example used stone bricks, but the AI never smelts
  bricks.
- **Claimable land.** `territory.share` divides by every grid cell (water and mountains included). Refine it once
  `world.lua` exposes regions.
- **Public borders on the uncharted map.** Enemy land is visible as an outline on black map areas (Rise of Nations
  style). If that leaks too much, pass `forces` to the chart objects of other forces once they are charted.
- **Factory grid.** In Nation mode the factory shows 27 of its 28 recipe slots. The rails and economy packages'
  recipes will need a third row (`P4.FACTORY_COLUMNS` grid in `hud.lua`).
- **Not in M1:** occupied buildings when land flips (study 2.2), supply haulers against attrition, population,
  capture. Buildings on land that becomes enemy keep working.
- **Fort and research.** The fort is a turret prototype, so research's turret upgrades include it (the research log's
  turret list names it).
- **AI balance in Nation mode** (see Validation): the aggressive AI lost its capital in every 96-tile run on both
  seeds, before or after its second city.
