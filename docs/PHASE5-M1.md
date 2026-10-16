# Phase 5, milestone M1: "Two cities and a railway"

Approved by the owner 2026-10-16 together with the five decisions in `SCALE-VISION.md` §9: two modes (Skirmish kept,
Nation added), 1–3 hour matches with saves, treasury money (M2), capture-not-destroy (M2), Space Age optional but
recommended, start with M1.

Goal of M1: in **Nation mode** on a real 2048×2048 world, a player founds a second city at a far ore region, connects
it to the capital by rail, ships intermediates between them and reaches Age II. The normal AI does the same. Every
Skirmish behaviour stays exactly as in Phase 4.

Studies: `research/scale/*.md`. This document is the **contract** between the M1 work packages: module names,
storage, public functions, hooks into shared files. Agents build against it; the integration agent resolves the rest.

## 1. Mode switch and shared rules

- `storage.match.config.mode` is `"skirmish"` (default) or `"nation"`. `match.normalize_config` accepts it; the lobby
  gets a **Mode** drop-down. Nation mode fixes the map type to **World** and the size by nation count (2 nations 1536,
  3–4 nations 2048; `world.size_for(nations)`), ignores the Skirmish size/map drop-downs (greyed).
- Every new module checks `match.config().mode == "nation"` at match start and stays inert in Skirmish unless this
  document says otherwise (divisions and the order queue are available in both modes).
- Balance: `balance.lua` gains `balance.nation = {...}` overrides (hauler fuel per tile, hauler slots 10, costs of new
  content). `balance.get(path)` style access is not required; modules read `balance.nation.<key>` when in Nation mode.
- Match length: nation matches have no wave timer, no 8-minute autotest cut-off; `saveload-check.sh` must pass.
- Forces: unchanged (`rts-player`, `rts-ai-1..3`). A nation is a force. `storage.nations[force_name]` is created by
  `cities.lua` at match start: `{capital = city_id, age = 1}`.
- Everything in the match goes through `scripts/events.lua`; all new state lives in `storage.<module>` and is cleared
  in the module's `on_match_teardown` hook (see `match.lua` teardown list) so restart stays clean.

## 2. Work packages, owners and files

| Package | Agent | New files (owner edits freely) | Shared files it may touch (small, marked hunks) |
|---|---|---|---|
| World (W1) | `m1-world` | `scripts/world.lua`, `prototypes/world.lua` (tiles, noise expressions), `locale/*/world.cfg` | `mapgen.lua` (delegate when mode == nation), `match.lua` (surface creation uses engine mapgen), `lobby.lua` (Mode + World), `data.lua` |
| Territory + City Centers (T1 + C2-lite) | `m1-cities` | `scripts/territory.lua`, `scripts/cities.lua`, `scripts/citygui.lua`, `prototypes/cities.lua`, `locale/*/cities.cfg` | `buildings.lua` (KIND registry, build rule hook), `supply.lua` (cap from cities), `hud.lua` (territory share, city list), `ai/*` (found a city: one hook) |
| Rails (R1) | `m1-rails` | `scripts/rails.lua`, `scripts/railgui.lua`, `prototypes/rails.lua`, `locale/*/rails.cfg` | `logistics.lua` (depot = hub subtype, policies), `orders.lua` (right-click on a depot with a train selected), `production.lua` (train kits), `ai/*` (one line: build a line to the second city) |
| Divisions + order queue | `m1-divisions` | `scripts/divisions.lua`, `scripts/divisiongui.lua`, `locale/*/divisions.cfg` | `orders.lua` (path-request queue, re-target throttle), `selection.lua` (division selection), `hud.lua` (division card), `ai/army.lua` (use divisions) |
| Ages, districts, projects, make targets (E1) | `m1-economy` | `scripts/ages.lua`, `scripts/districts.lua`, `scripts/ledgergui.lua`, `prototypes/age2.lua`, `prototypes/districts.lua`, `locale/*/economy.cfg` | `production.lua` (auto-recipe from make targets, age gate), `research.lua` (age technologies), `recipes.lua`/`items.lua` (Age II items), `ai/*` (age-up and make targets) |
| Integration | `m1-integ` (wave B) | `docs/qa/phase5-m1-protocol.md`, README | everything |

Each agent works in a copy under `build/p5-<name>/` (`tools/autotest-run.sh` with `KEEP_TREE`), validates headless,
then syncs **its own files** back into `mods/factorio-rts/` and applies its shared-file hunks there after re-reading
the current file (another agent may have changed it). Agents never revert another agent's hunk. The lead commits.

## 3. Contracts (public API per module)

### world.lua
```
world.size_for(nations) -> tiles (1536 | 2048)
world.plan(config, seed) -> plan            -- skeleton: coasts, ranges+passes, rivers+fords, climate, regions, spawns, sites
world.apply(surface, plan)                  -- map_gen_settings + property_expression_names, request chunks, place ore/sites
world.region_at(position) -> region          -- {id, name, kind = "highland"|"plain"|"swamp"|"coast", resources = {...}}
world.spawns() -> {position, ...}            -- one per nation, scored and fair (start kit within 150 tiles)
world.sites() -> {kind = "city_site"|"ruin"|"port", position, region}
storage.world = {size, seed, plan, regions, spawns, sites, chokes = {}}
```
Tiles: `rts-mountain` (collides with the `player` layer and water-like for spider legs; verified by a crossing probe for
every unit class and haulers), `rts-ford` (walkable shallow water, not buildable). Cliffs only on mountain rims.
Ore placement reuses `mapgen.place_patch` with exact totals. Match start must be playable ≤ 15 s after Start at 2048.

### territory.lua
```
territory.owner_at(position) -> force_name | nil
territory.city_at(position) -> city_id | nil
territory.can_build(force, entity_name, position) -> ok, reason   -- economic buildings: own land; forts: own or neutral; nothing on enemy land
territory.add_source(entity, radius_tiles)   -- City Center (radius by tier), fort, hub (small), radar (small)
territory.remove_source(unit_number)
territory.share(force) -> fraction of claimable cells
events: "rts_territory_changed" {force, cells}   (events.raise/emit pattern in events.lua)
storage.territory = {cell = 8, w, h, owner = {row strings}, city = {...}, sources = {[unit_number] = ...}, dirty queue}
```
Borders: `rendering.draw_line` in game view and chart view per player's force view; incremental redraw through a
≤ 1 ms/tick job queue. Attrition: enemy units ≥ 16 tiles inside foreign land lose ~18 % HP/min via damage type
`rts-attrition`, suppressed within 24 tiles of an own City Center, hub or fort. Nation mode only.

### cities.lua / citygui.lua
```
cities.found(force, position, opts) -> city_id      -- places/registers a City Center; first one = capital
cities.get(city_id) -> {id, force, name, position, center (unit_number), tier = 1|2|3, radius, archetype, networks}
cities.of_entity(entity) -> city | nil             -- by territory.city_at(entity.position)
cities.for_force(force_name) -> {city, ...}
cities.make_targets(city_id) -> {[item] = n}       -- owned here, written by ledgergui, read by production.lua
cities.set_make_target(city_id, item, n)
storage.cities = {[id] = ...}, storage.nations[force] = {capital = id, age = 1}
```
The Skirmish CC prototype `rts-command-center` stays; in Nation mode the starting CC **is** the capital's City Center
(registered as city 1, tier 2). New cities use `rts-city-center` (a CC-composite clone with smaller power/robots), made
by the factory from a *City charter* kit and placed by the Commander like a hub. Tiers: village (1) → town (2) → city
(3) raise land radius (48/72/96 tiles), supply (+10/+20/+30) and building slots; tier-up condition in M1 is simple
(buildings count + delivered goods), population arrives in M2. The city panel shows tier, land, networks, make targets.

### rails.lua / railgui.lua
```
rails.plan_line(force, depot_a, depot_b) -> job_id   -- time-sliced planner (coarse grid, then A* on the learned rail geometry), ghosts incl. elevated spans
rails.lines[job_id] = {force, a, b, state = "surveying"|"building"|"open"|"cut", rails = n, length}
rails.create_train(depot, kind = "cargo"|"construction") -> LuaTrain     -- from kits in the depot's network
rails.set_route(train, pickup_depot, dropoff_depot)                       -- schedule written by script; cargo = depot export/keep policies
storage.rails = {geometry (learned at init, not saved), lines, trains = {[train_id] = {...}}, jobs}
```
`rts-depot` is a hub subtype (logistics.lua registers it with the same keep/export policies) plus a train stop and a
loading platform; kits: `rts-rail` (2 steel + 1 stone → 2 rails), `rts-locomotive-kit`, `rts-cargo-wagon-kit`,
`rts-construction-wagon-kit`; research *Railways* (Age I, basic kits) and *Bridges* (elevated spans; Space Age only).
Rails are built and repaired by a construction train; destroyed rails leave ghosts. Hauler UX for routes: select a
train → right-click depot (pickup) → Shift+right-click depot (drop-off). Probes on generated terrain (trees, cliffs,
ore, water) come first, one day max.

### divisions.lua / orders.lua
```
divisions.create(force, units, template) -> id       -- template = {name, composition = {[unit] = n}, stance = "hold"|"advance"|"screen"}
divisions.get(id), divisions.for_force(force), divisions.add_units(id, units), divisions.disband(id)
divisions.order(id, kind, target)                    -- move | attack_move | hold | retreat; one path request per division (unit group) with leader-follower fallback
orders.queue_command(entity_or_group, command)       -- ≤ 100 path requests per tick, re-target throttle
storage.divisions = {[id] = {force, units = {unit_numbers}, template, stance, group_id, rally, reinforce = bool}}
```
Available in both modes. New units from a barracks with "reinforce division N" set auto-join. Selecting a division
card selects its units; HUD shows division cards. AI `army.lua` creates divisions for its attack groups.

### ages.lua / districts.lua / ledgergui.lua
```
ages.of(force) -> 1 | 2 | 3
ages.project(force) -> {name = "railway-charter", site (entity), required = {[item] = n}, delivered = {...}} | nil
ages.start_project(force, position)                 -- places rts-project-site (stockpile composite); completes when deliveries arrive → age 2 for that force
districts: prototypes rts-district-* (large assembling machines, compressed multi-stage recipes, 10 Age II districts), fed by network pull like factories; staffing hook left as a no-op function `districts.staffing_factor(entity) -> 1` for M2
production.lua: auto-recipe: a factory/district with no fixed recipe makes the largest shortfall among its city's make targets
storage.ages[force] = {age, project}, storage.districts = {...}
```
Age II content reuses vanilla recipes (crude oil → petroleum → plastic, sulfur, engines, advanced circuits, steel beams,
concrete) with RTS buildings cloned from pumpjack, refinery, chemical plant. Age II science kit needs goods from ≥ 3
production stages. Research tree: *Industrialisation* (unlocks the Railway Charter project); Age II technologies use
the advanced kit. The ledger panel (per city): production/consumption per good, make targets, shortfalls, "needs X from
city Y" hints.

## 4. Autotests and acceptance (headless, `tools/autotest-run.sh` with `mode = "nation"` in the match table)

Each package adds its checks to `scripts/ai/autotest.lua` (or `debug.lua` fixtures) and must pass its own list plus
0 Lua errors at 60 UPS on a 2048 world with 2 nations:

- World: 20 seeds × 2/3/4 nations: generation ≤ 15 s, land connectivity 100 %, start kit within 150 tiles, spawn score
  spread ≤ 15 %; crossing probe: no unit class crosses a range or river mid-span, all cross at passes and fords.
- Territory/cities: ghost placement table (own/neutral/enemy × building class); attrition 15–25 % in 60 s at 40 tiles
  inside; founding a city 300 tiles out registers land and its own network; territory handlers < 0.1 ms/tick.
- Rails: two depots 800 tiles apart with a lake between: survey ≤ 10 s, line built, a train delivers ≥ 4,000 iron in
  3 minutes; 3 destroyed rails → "line cut", repaired within 60 s; rail module ≤ 0.3 ms/tick idle.
- Divisions: 4 forces × 12 divisions × 16 units moving on 2048²: mean ≤ 6 ms/tick, no order tick > 20 ms; an order to
  1,000 units issues ≤ 100 path requests per tick.
- Economy: city B has oil, city A none: A makes no advanced circuits until plastic arrives by route, then within 3 min;
  Railway Charter completes from deliveries and unlocks Age II for that force only; a factory whose target is met
  switches to the next shortfall within 5 s; the normal AI reaches Age II by 20:00 in 4 of 5 seeds.
- M1 end-to-end (integration): 60-minute 1v1 nation match, 0 errors, 60 UPS, both sides found a second city, open
  ≥ 1 rail line, move ≥ 20,000 items by train, reach Age II; GUI protocol (Codex) covers founding, rail laying, a
  district, a division order; Skirmish validation matrix unchanged (`tools/autotest-matrix.sh`).

## 5. Shared-file etiquette

- Hooks into `control.lua` require list: add your module after the modules it depends on; comment why.
- `match.lua`: add your teardown to the existing teardown list; never reorder others.
- `lobby.lua`: only `m1-world` adds the Mode drop-down; others read `match.config().mode`.
- `hud.lua`: add panels through the existing layout table `P4`; keep the 200-locals limit in mind.
- Locale: one new `.cfg` per package in `en` and `ru`, same keys in both.
- Report to the lead: files changed, shared hunks (file:line), autotest results, open issues, measured ms/tick.
