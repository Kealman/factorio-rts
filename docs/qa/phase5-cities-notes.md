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
| `locale/en/cities.cfg`, `locale/ru/cities.cfg` | new | 63 keys each, same keys and parameters |
| `tools/probes/territory_autotest.lua` | new | Headless autotest of this package (`EXTRA_LUA`) |
| `tools/probes/territory_saveload.lua` | new | Grid checksum and render object count before the save and after the load |
| `tools/probes/territory_grid2048.lua` | new | A 2048-tile grid on any arena, plus a log line with the time of every job-queue tick |
| `tools/probes/territory_worldsites.lua` | new | A stand-in `storage.world` with city sites, for the AI's world-site path |
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
| `scripts/hud.lua` | `P4.NATION_ONLY`, `P4.nation()`; Production tab gets `rts-city-charter`, `rts-fort`; nation-only build items and factory recipes are skipped in Skirmish; strip: territory share label and a Cities button; click action `cities`; alert styles `city-founded`, `city-tier`, `city-lost`, `territory-lost` |
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

- City Center: at least 96 tiles from every City Center and capital of any force, at most 4 cities per nation. Own land
  always lies within 96 tiles of the capital, so in practice a city goes on neutral land.
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
- **Strip.** In Nation mode: "Land N%" (territory share) and a "Cities" button that shows or hides the city list.
- **City list** (top left, under the kill feed). One row per own city: a jump button with its name, then tier and
  land cells, and a magnifier that opens the city panel.
- **City panel** (left of the hub panel). It opens while an own City Center or the capital is selected, or from the
  list. It shows name and tier, a rename field, tier and radius, land cells and their share of the nation, supply, the
  next tier's requirements, the logistic networks on its land, and the make-target table with a choose-item button.

PLACEHOLDER_GUI

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

PLACEHOLDER_VALIDATION
