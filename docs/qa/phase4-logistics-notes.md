# Phase 4 logistics: hubs, stockpile policies, haulers

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE4.md` sections 2.1 and 2.2 (wave A2). Economy background: `docs/qa/phase2-economy-notes.md`.
GUI conventions: `docs/qa/phase2-hud-notes.md`, `docs/qa/phase2-polish-notes.md`.

## Files

| File | Status | What it does |
|---|---|---|
| `prototypes/logistics.lua` | new | Hub composite (`rts-hub`, `rts-hub-power`, `rts-hub-pole`), the hauler (`rts-hauler` and its legs), the items `rts-hub` and `rts-hauler-kit`, their factory recipes, and `spider-vehicle` in the RTS cursor's select filters |
| `scripts/logistics.lua` | new | Hub placement and parts, policies, the network graph, haulers (state machine, routes, kits, deaths), alerts, the right-click hook, the headless autotest |
| `scripts/hubgui.lua` | new | Hub panel and hauler panel, GUI self-test steps |
| `scripts/orders.lua` | 2 small edits | `orders.on_right_click(fn)` hook list, called first in the plain and the Shift right-click paths |
| `scripts/production.lua` | 1 line | The factory hand-off leaves `rts-hauler-kit` in the output |
| `control.lua`, `data.lua` | 1-2 lines | Require the new modules |
| `locale/en`, `locale/ru` | appended | 5 entity names, 4 descriptions, 2 items, 1 item description, 2 recipes, 49 `[rts]` keys |

`selection.lua` needed no change: haulers are registered in `storage.units`, so it selects them like units once the
cursor's select filters include `spider-vehicle`. `hud.lua`, `match.lua`, `scripts/ai`, `prototypes/units.lua` and
`prototypes/buildings.lua` were not touched.

## Prototypes

| Prototype | Base | Numbers |
|---|---|---|
| `rts-hub` (roboport) | vanilla roboport, base sprites tinted warm so it reads apart from the CC | 1200 hp, logistic radius 14, construction radius 22, buffer 20 MJ, input 200 kW, idle 20 kW, charging 50 kW per station, radar 1 chunk, not deconstructable, military target, raid target |
| `rts-hub-power` (electric-energy-interface) | `hidden-electric-energy-interface` | hidden, immune, 300 kW `secondary-output` (solar is used first, as with `rts-core-power`) |
| `rts-hub-pole` (electric-pole) | `medium-electric-pole`, no sprite | hidden, immune, supply area 16×16 (`supply_area_distance = 8`), wire reach 9, so player poles connect to it |
| `rts-hauler` (spider-vehicle) | base `create_spidertron{scale = 0.6, leg_movement_speed = HAULER_LEG_SPEED}`; the full vanilla spidertron if base ever stops exporting that function | 400 hp, no resistances, no guns, no equipment grid, no trash slots, no passengers, no remote driving, trunk 40 slots of which the script uses 20 plus research, radar 1 chunk, military target, raid target, team colour via `LuaEntity.color` |
| item `rts-hub` | roboport item, tinted icon | subgroup `rts-economy`, stack 10 |
| item `rts-hauler-kit` | spidertron icon, tinted | subgroup `rts-units`, stack 10 |
| recipe `rts-hub` | category `rts-buildings` (factory) | 40 iron plate, 10 copper plate, 8 s |
| recipe `rts-hauler-kit` | category `rts-buildings` (factory) | 30 iron plate, 10 electronic circuit, 8 s |

The raid trigger target type comes from `balance.raid_target_type`. The hub and the hauler opt in only when that
`trigger-target-type` prototype exists, so the file loads without the content agent's work too.

## Hub composite

A hub is a building of kind `"hub"`: `scripts/logistics.lua` adds `buildings.KIND_BY_NAME["rts-hub"] = "hub"` at
load time. Any registration path completes it: robots building a ghost, `create_entity{..., raise_built = true}`,
`script_raised_revive`, a clone, or `buildings.register(entity)`.

| Part | Where | Notes |
|---|---|---|
| `rts-hub-power`, `rts-hub-pole` | under the hub | Reused when a clone brought them along. Destroyed with the hub. |
| 2 × `rts-stockpile` | (−3.5, 0.5) and (3.5, 0.5) from the hub centre | `find_non_colliding_position` within 4 tiles when the spot is taken. They stay when the hub dies. |
| Robots | hub robot inventory | 10 construction and 6 logistic robots, only when the inventory is empty. Research `robots_per_hub_bonus` adds logistic robots to every hub on the 60-tick sweep. |
| Buffer | `energy = electric_buffer_size` | The 300 kW core never has to fill it from zero. |

Log line: `logistics: hub #157 (Hub 1) of rts-player at (-87.0, 61.0): power=true pole=true stockpiles=2 robots=16 buffer 20.0 MJ`.

## Storage

```
storage.logistics = {
  hubs = {[unit_number] = {kind = "hub" | "cc", force, index (hubs: "Hub n" per force),
                           keep = {[item] = n}, export_above = {[item] = n},
                           parts = {power, pole, stockpiles = {...}}, setup_done, bonus_bots}},
  haulers = {[unit_number] = {entity, force, mode = "auto" | "manual", home, pickup, dropoff,
                              state, reason, target, dest, plan, plan_src, cargo, delivered, trips, created, leg,
                              at_hub, route = {n, length, source}, path_req, repath_at, progress, stalls}},
  path_requests = {[request id] = {un, dest, key, tick, from, retries}},
  path_cache = {["<from hub>><to hub>"] = {tick, waypoints}},
  net_cache = {[force] = {tick, list, by_id = {[network_id] = i}, by_hub = {[unit_number] = i}}},
  stats = {[force] = {trips, delivered = {[item] = n}, lost, deployed}},
  hub_counter = {[force] = n},
  autotest = {...},           -- headless autotest only
}
storage.alerts = {{tick, force, kind, position, text = locale key, params?}, ...}   -- newest last, at most 100
storage.units[hauler unit_number] = {entity, force, kind = "hauler", order = "haul", issuer = "logistics"}
```

`storage.alerts` is shared: `scripts/supply.lua` writes `supply-blocked`, `unit-locked` and `research-complete` in the
same format with `params`. This module writes `hauler-lost` with `text = "rts.alert-hauler-lost"` and no params.

## Policies

Every hub and every Command Center has a policy. The CC is the root hub.

| Field | Meaning | Default |
|---|---|---|
| `keep[item]` | Import until the network holds this many | Hub: 50 iron plate, 20 copper plate. CC: none. |
| `export_above[item]` | Offer what the network holds above this many | CC: 100 iron, copper and steel plate. Hub: none. |

- **Per network.** Hubs whose 28×28 logistic areas touch share one vanilla logistic network, and with it the
  counts. The network's keep is the largest keep of its hubs. Its export threshold is the largest `export_above`,
  and never below its own keep.
- **No `export_above`, no export.** A network exports only items some hub in it has a threshold for.
- **Units.** Thresholds are whole numbers from 0 to 100000; nil switches the threshold off.

## Haulers

### State machine

Every 30 ticks for every hauler, and at once on `on_spider_command_completed`:

| State | Meaning | Next |
|---|---|---|
| `idle` | Decide (below) | any |
| `to_pickup` | Walking to the pickup hub (manual) or the source hub (auto) | arrives: load, then `to_dropoff` |
| `to_dropoff` | Walking to the drop-off (manual) or home (auto) with cargo | arrives: unload, then `idle` |
| `to_home` | Auto: going home, empty or to unload | arrives: unload, then `idle` |
| `waiting` | Nothing to do here; `reason` says why | re-decided every step |
| `parked` | A move order sent it somewhere; the route is suspended | a route order or Resume |

Arrival is within 4 tiles of the hub's approach point, 2.5 tiles below its selection box. While walking, a hauler
whose autopilot destination got cleared gets it again; the third re-issue logs "may be stuck". Each arrival logs the
leg's distance, time and speed.

### Manual route

1. With cargo: go to the drop-off and unload everything into its network. What does not fit stays aboard, and the
   hauler waits there (`full`).
2. Empty: go to the pickup. There, load for every item the pickup exports: min(export surplus minus other haulers'
   reservations, what the drop-off still wants). "Wants" is keep minus count minus cargo already on its way. A
   drop-off with no keep threshold at all takes every export (a feeder route).
3. Nothing to carry: wait at the pickup and re-check every step (`nothing`).

Pickup and drop-off in one network: `same-network`. A missing end: `no-route`.

### Auto mode

1. With cargo: go home and unload.
2. Empty: the home network's requests are keep minus count minus cargo on its way. Every other network of the force
   that exports a requested item is a source. The source hub nearest to home wins, and the hauler reserves the plan
   (`plan`, `plan_src`) so a second hauler does not fetch the same surplus.
3. At the source: load min(plan, surplus now, still needed), then go home.
4. No request or no source: wait at home (`nothing`). A hauler whose home died is re-homed to the nearest hub.

### Land routes

Spider-vehicle autopilot walks a straight line and stops at water wider than about 10 tiles, such as the Chokepoints
map's 16-tile moats. Every trip, and every ground move order, therefore asks the pathfinder for a land route first:

- **Request.** `surface.request_path` from the hauler to the destination runs with a 3×3 box and the mask
  `{layers = {doodad = true}, colliding_with_tiles_only = true}`. The flags are `allow_paths_through_own_entities`
  and `prefer_straight_paths`, with the engine cache off.
  - Water, deep water and out-of-map tiles carry the `doodad` layer; shallow water does not.
  - Cliffs, trees and buildings do not carry it, so routes ignore them; spider legs step over them (gotcha 10).
  - The hauler stands still until the answer comes, usually in 0 to 3 ticks.
- **Waypoints.** The answer is simplified in two passes and then goes into `autopilot_destinations`.
  - Douglas-Peucker at 0.75 tiles keeps only the turns.
  - String pulling drops every turn whose straight shortcut has a 1.5-tile corridor free of water and out-of-map
    tiles, checked every 0.5 tiles with `count_tiles_filtered`.
  - Both passes matter, because every queued waypoint slows the spider down. Routes thinned to every 4th waypoint,
    about 15 per 60 tiles, made a 60-tile leg take 4 s instead of 3.
  - The engine's long-range search also bends open-ground paths through chunk-level nodes. The first hub-to-CC leg
    came back 80 tiles long via x = −64.5, next to a chunk edge, against 61 straight. After string pulling it is one
    waypoint and 61 tiles.
- **Cache.** A trip that starts at the hub where the hauler last arrived is cached as `"<from hub>><to hub>"` for
  60 s (`storage.logistics.path_cache`). The next hauler on that leg starts at once.
- **No path.** With no path, or no answer within 180 ticks, the hauler walks the straight line and logs
  `[rts] hauler no path #N ...`. When the pathfinder is busy (`try_again_later`) it asks again 60 ticks later, at
  most 3 times.
- **Stalls.** A travelling hauler that moves less than 1 tile in 180 ticks asks for a new route from where it
  stands, at most 3 times per leg. So does one whose autopilot queue ran out short of the target. These log
  `stalled ... re-routing (n)` and `may be stuck`.
- **Logs.** Each route logs `route to (x, y): K of N waypoints, L tiles (pathfinder P, straight S), found in T ticks
  [cached as A>B]`. Each arrival logs the route source (`path`, `cache` or `straight`), its waypoints and length.

### Capacity

The trunk has 40 slots. Loading is capped at `logistics.capacity(force)`, which is `BASE_SLOTS` (20) plus
`research.hauler_slots(force)` (Hauler capacity I: +10). Planning counts free stacks and room in partial stacks.

### Kits and spawning

- **Factory.** The factory recipe `rts-hauler-kit` produces a kit. production.lua's hand-off leaves it in the output,
  and the 60-tick sweep turns it into a hauler at the factory's default exit, 6 tiles towards the arena centre. The
  new hauler is in auto mode, with home = the hub of the factory's network nearest to the factory, else the nearest
  hub or CC.
- **Network.** A kit found in a hub network, for example from `/rts-give rts-hauler-kit 1`, is deployed at that
  network's first hub.
- **Script.** `logistics.spawn_hauler(surface, position, force, home_un)` does the same registration.

### Deaths

`on_entity_died` of a hauler logs
`logistics: hauler lost #162 of rts-player at (-87.0, 66.6) (auto, waiting), cargo [...], killed by <entity> (<force>)`.
It adds the alert `{kind = "hauler-lost", text = "rts.alert-hauler-lost"}` and counts `stats.lost`. The cargo is
lost with the vehicle. units.lua drops the `storage.units` record as for any unit.

## Orders

`orders.lua` now calls `orders.on_right_click` hooks before its own decision, in the plain and in the Shift
right-click path. `logistics.right_click` is the only hook. It does nothing unless haulers are selected.

| Input, haulers selected | Effect | QA log line |
|---|---|---|
| Right click on an own hub or CC | Pickup = that hub, mode manual. From auto, a missing drop-off becomes the home hub. | `order route-pickup n=N hub=#H (hub\|cc) player=P` |
| Shift + right click on an own hub or CC | Drop-off = that hub, mode manual. From auto, a missing pickup becomes the home hub. | `order route-dropoff n=N hub=#H (...) player=P` |
| Right click on the ground | Walk there (a golden-angle spiral for several haulers) and park | `order hauler-move n=N dest=(x, y) player=P` |

- **The hub under the click.** The hook takes the hub from the reverse-select entity list. Without one, it uses
  `selection.building_at`, the same 1-tile pick radius as building selection.
- **Mixed selections.** When units are selected too, the haulers get the route or move and the click is not
  consumed. The units then get their normal order. orders.lua skips the haulers, because they are claimed (order
  `haul`, issuer `logistics`).
- **Other keys.** X, H and F do nothing to haulers, for the same reason.

## GUI (`scripts/hubgui.lua`)

One frame, `rts_hubgui_frame`, in `player.gui.screen`: 340 GUI units wide, at the right edge just below the HUD
minimap. It is open while a hub or the CC is the selected building, or while the selection holds only haulers. The
module polls the selection every 10 ticks, so no selection.lua hook is needed, and refreshes the values every 30
ticks. The close button hides it until the selection changes.

| Panel | Content |
|---|---|
| Hub / CC | Title "Hub 1: stockpile policy". Network line: "Network #4, 1 hub". Haulers line: auto haulers based here and haulers arriving with cargo. A hint. Then a scrolling table (250 GUI units high): item icon with its name as tooltip, count in the network, a Keep field and an Export above field. Counts are yellow below keep and green above the export threshold. |
| Hauler | Title "Hauler #N" (+M selected), Auto / Route toggle buttons, HP. Home or route line, state line with the target hub and distance or the waiting reason, cargo as item icons, trips and deliveries. Buttons Return home and Resume. A hint line. The buttons act on every selected hauler. |

- **Item rows.** `logistics.POLICY_ITEMS` that exist: plates, stone, coal, brick, gear, cable, circuit,
  `rts-explosives` and magazines. Then the items of `logistics.POLICY_SUBGROUPS` in item order: `rts-intermediates`,
  `rts-science` (the lab kits) and `rts-units` (the unit kits). Then anything else in the network or in a policy.
- **Fields.** Numeric text fields, an empty field = off. Every edit calls `logistics.set_policy` and logs
  `hubgui policy hub=#H <item> keep|export_above=<n|nil> ok=true player=P`. Fields are not rewritten on refresh, so
  typing is never overwritten. A policy changed by script shows after the panel is reopened.
- **Return home** sets auto mode and walks home. **Resume** leaves the parked state. The mode buttons call
  `logistics.set_mode`. Auto makes the drop-off the new home when one is set.

## API (`scripts/logistics.lua`)

| Function | Returns / does |
|---|---|
| `logistics.networks(force)` | Cached list of the force's networks that contain a hub or CC: `{network, id, hubs, cc?, contents, keep, export, position}`. `export` holds the effective thresholds. At most 30 ticks old. |
| `logistics.entry_for_hub(un)`, `logistics.entry_by_id(force, id)` | One entry of that list |
| `logistics.exports(entry)`, `logistics.requests(entry)` | `{[item] = surplus}`, `{[item] = shortfall}` from the cached counts |
| `logistics.transfer(from, to, item, count)` | Moves items between any two of LuaLogisticNetwork, LuaInventory and LuaEntity. What the target refuses goes back. Returns the number moved. |
| `logistics.policy(un)`, `logistics.set_policy(un, "keep" \| "export_above", item, n \| nil)` | Read and write a policy. Writing logs and invalidates the cache. |
| `logistics.hub_rec(un)`, `logistics.hub_name(un)`, `logistics.hub_network(un)`, `logistics.approach_point(un)` | Hub or CC helpers. `hub_name` is a localised string, "Command Center" or "Hub n". |
| `logistics.spawn_hauler(surface, position, force, home_un?)` | Places and registers a hauler, auto mode. Returns entity, record. |
| `logistics.hauler(un)`, `logistics.haulers_of(force)` | Live record, iterator |
| `logistics.set_pickup(un, hub)`, `set_dropoff(un, hub)`, `set_home(un, hub)`, `set_mode(un, "auto" \| "manual")`, `return_home(un)`, `move_hauler(un, pos)`, `resume(un)` | Hauler control; each logs one line |
| `logistics.capacity(force)` | Cargo slots a hauler may fill |
| `logistics.stats(force)` | `{trips, delivered, lost, deployed}` |
| `logistics.alert(force, kind, position, text_key)` | Appends to `storage.alerts` and logs it |
| `logistics.right_click(player_index, position, entities, alt)` | The orders hook; also usable by tests |

Constants: `HUB_STOCKPILES`, `HUB_BOTS`, `BONUS_BOT`, `BASE_SLOTS`, `DEFAULT_CC`, `DEFAULT_HUB`, `STEP_PERIOD` (30),
`DEPLOY_PERIOD` (60), `CACHE_TICKS` (30), `ARRIVE_RADIUS` (4), `APPROACH_GAP` (2.5), `POLICY_ITEMS`, `POLICY_SUBGROUPS`.
Land routes: `PATH_BOX` (3×3), `PATH_MASK` (`doodad`, tiles only), `PATH_EPSILON` (0.75), `PATH_CLEARANCE` (1.5),
`PATH_SAMPLE` (0.5), `PATH_CACHE_TICKS` (3600), `PATH_TIMEOUT` (180), `PATH_RETRY_TICKS` (60), `STALL_TICKS` (180),
`STALL_DIST` (1).

## What the AI agent needs

- **Place a hub.** Use `surface.create_entity{name = "rts-hub", position, force, raise_built = true}`, or revive a
  ghost with `raise_revive = true`, or call `buildings.register(entity)` after a silent create. The composite
  completes itself. Keep it more than 39 tiles from the CC (CC radius 25 + hub radius 14) for a separate network.
- **Robots.** A hub comes with 16 robots, and vanilla robots then build ghosts and move items inside its network.
  The commander takes robots out of CCs at start; if it does not want bots, it should empty
  `defines.inventory.roboport_robot` of its hubs as well.
- **Policies.** `logistics.set_policy(hub, "keep", "iron-plate", 100)` on a forward hub, and an
  `export_above` on the CC, which defaults to 100 for plates.
- **Haulers.**
  - Make them with the factory recipe `rts-hauler-kit`, or call `logistics.spawn_hauler` directly.
  - `balance.units["rts-hauler"]` has `made_by = "factory"`. Lists of barracks kits built from `balance.units` must
    skip entries that set `made_by`.
  - Then `set_home` for auto service, or `set_pickup` and `set_dropoff` for a route.
  - `logistics.haulers_of(force)` lists them; `logistics.stats(force)` counts trips and losses.
- **Exclude haulers from the army.** They are in `storage.units`, so `units.for_force` and `units.count` include
  them. `army.lua`'s pool takes every own unit that is in no group. A hauler is never moved by `orders.*`, because it
  is claimed, but it would become a group member and count towards pool strength. Filter on
  `rec.kind == "hauler"` (`logistics.KIND`).
- **Raid haulers.** Enemy haulers are ordinary targets: `storage.units` entries with kind `hauler`. A hauler line
  is visible as states `to_pickup` and `to_dropoff` between two hubs.

## For the HUD agent

- **Build menu.** `hud.lua`'s `BUILD_ITEMS` is a fixed list without `rts-hub`. Until it is added, a player can make
  hub items in the factory but has no button to place one. The factory grid already lists `rts-hub` and
  `rts-hauler-kit`.
- **Labels.** The keys `rts.kind-hauler` ("Hauler") and `rts.order-haul` ("Hauling") exist for `KIND_KEYS` and
  `ORDER_KEYS`. Today the unit page shows the raw strings `hauler` and `haul`.
- **Counts.** The army count (`units.count`) includes haulers. Supply does not charge for them:
  `balance.units["rts-hauler"].supply = 0`, which supply.lua reads.
- **Alerts.** `storage.alerts` entries `hauler-lost` carry a position for the jump key.
- **Strip.** The resource strip shows the CC networks only (`economy.snapshot`). Hub networks are separate pools;
  `logistics.networks(force)` has their contents.

## Headless autotest

It is off by default. It runs in a headless autotest game, where `storage.debug.autotest` is true, when
`logistics.AUTOTEST_DEFAULT` is true or `storage.debug.logistics_autotest` is set. The test copy flips the constant:

```sh
rm -rf build/p4-logistics && mkdir -p build/p4-logistics && cp -R mods/factorio-rts mods/mod-list.json build/p4-logistics/
sed -i '' 's/^logistics.AUTOTEST_DEFAULT = false/logistics.AUTOTEST_DEFAULT = true/' build/p4-logistics/factorio-rts/scripts/logistics.lua
tools/headless-run.sh 240 '\[rts\] (logistics|order route|order hauler)' build/p4-logistics
```

It works with any `AUTOTEST_MATCH`; the default AI match was used. It acts for `rts-player`, which has an AI
commander in that match. Steps, from the first 60-tick sweep with the match running:

1. **Setup.**
   - A hub 60 tiles south of the player CC with `raise_built`. The test removes the hub's copper keep, so the
     auto stage moves iron only.
   - 300 iron into the CC network.
   - An auto hauler at the hub.
   - A factory 9 tiles from the hub, inside its network and power area, with the `rts-hauler-kit` recipe and one
     craft of ingredients.
   - Speed probe: a claimed walker and a parked hauler, each sent 60 tiles east.
2. **Auto stage.** The hauler must deliver at least 50 iron within 90 s. The factory's kit must become a hauler
   within 60 s.
3. **Orders stage**, through `orders.handle_reverse_area` with the fake player index 0, as in the Phase 1 tests:
   - A right click on the ground parks the kit hauler.
   - Shift + right click on the hub, then a right click on the CC, make it a manual CC → hub hauler.
   - The first hauler is killed with `die()`.
4. **Manual stage.** The CC exports copper above 0, and the hub keeps 60 copper. The manual hauler must carry at
   least 20 copper within 90 s.
5. **Moat stage.**
   - `set_tiles` lays a water band 16 rows high, at 70 to 86 tiles north of the CC. It runs from the arena's west
     edge to 60 tiles east of the CC, with a 14-tile land gap 20 to 34 tiles east of the CC.
   - A source hub 50 tiles north exports iron above 0 and holds 200 iron. A target hub 108 tiles north keeps 50
     iron.
   - An auto hauler at the target must fetch 50 iron through the gap within 90 s. Every tick, the test records
     where the hauler is while it is inside the band's interior rows, 2 tiles in from each edge.

| Check | Expects |
|---|---|
| `logistics_hub_composite` | kind `hub`, power and pole valid, 2 stockpiles within 5 tiles, 10 + 6 robots, buffer > 0 |
| `logistics_networks` | the hub has its own network, different from the CC's |
| `logistics_policy_defaults` | hub keep 50 / 20, CC export 100 / 100 / 100 |
| `logistics_hauler_speed` | hauler at least 1.8× the walker over 60 tiles from a standing start |
| `logistics_auto_delivery` | ≥ 50 iron delivered by the auto hauler, hub network holds ≥ 50 |
| `logistics_kit_deploy` | a hauler within 12 tiles of the factory, no kit left in its output or network |
| `logistics_move_order` | `hauler-move`, state `parked`, destination at the click, route requested or set |
| `logistics_route_orders` | `route-dropoff`, `route-pickup`, mode manual, pickup CC, drop-off hub, state `to_pickup` |
| `logistics_hauler_lost` | one new `hauler-lost` alert this tick, hauler gone from both registries, `stats.lost` ≥ 1 |
| `logistics_manual_route` | ≥ 20 copper delivered CC → hub |
| `logistics_moat_route` | the trip to the moat source used a pathfinder route longer than the straight line |
| `logistics_moat_gap` | every tick the hauler spent in the band's interior rows, it was within the 14-tile gap's columns |
| `logistics_moat_delivery` | ≥ 50 iron delivered across the moat within 90 s |

The last line is `[rts] logistics autotest summary N/M`.

## Validation

All runs used copies of `mods/` plus `mods/mod-list.json`, with Space Age on. Other agents edited `balance.lua`,
`prototypes/units.lua`, `prototypes/buildings.lua`, research and supply while these runs happened. Each copy holds
the tree as it was at that moment. The AI and legacy copies predate three later changes of mine: the hauler leg
speed, the policy item list and the land routes. None matters there, because those tests spawn no hub and no hauler.

| Run | Copy | Result | Errors |
|---|---|---|---|
| Logistics autotest with land routes and the moat stage, 240 s, final code (2026-10-16), Chokepoints map with mapgen moats | `build/p4-haulpath` | `logistics autotest summary 13/13 (all passed)`; moat crossed inside the gap at x −63.1 to −62.5; 50 iron across the moat in 9 s | 0 |
| Logistics autotest, 240 s, before land routes | `build/p4-logistics` | `logistics autotest summary 10/10 (all passed)`; hauler 21.4 tiles/s vs walker 10.8 | 0 |
| Same, before the policy item list got the content agent's subgroups | `build/p4-logistics-run3-server.log` | `logistics autotest summary 10/10 (all passed)` | 0 |
| Same, first version (leg speed 1.6, no speed probe) | `build/p4-logistics-run1-server.log` | 9/9 | 0 |
| AI autotest, 420 s, logistics loaded, its test off | `build/p4-logistics-ai` | `ai autotest summary 14/14 (all passed), result=both alive (time)` | 0 |
| Legacy waves autotest, 240 s, logistics loaded | `build/p4-logistics-legacy`, `build/p4-logistics-legacy2` | 64/65: `eco_shared_pool` FAIL | 0 |
| Same, control copy with every logistics file and require removed | `build/p4-legacy-control` | 64/65: the same `eco_shared_pool` FAIL | 0 |
| GUI self-test, Russian (system language), before land routes | `build/p4-logistics-gui` | Marker `RTS_LOGISTICS_GUI_DONE`, screenshots in `build/shots-p4-logistics-gui/` | 0 |
| GUI self-test, English (scratch runner with `locale=en`), before the item list change | `build/p4-logistics-gui-en` | Same, `build/shots-p4-logistics-gui-en/` | 0 |

**Why the legacy test fails, and why it is not this work.** The Phase 1 attack-move walkers razed the template
enemy base. The match ended with a player victory at tick 5220 (85 s) in both the control copy and the repeat
logistics copy, and at 96 s in the first logistics copy. The autotest then runs its QA reset early, the economy
checks lose their base, and the barracks make no more kits after 75 s. The control copy has no logistics code at
all and fails the same way. The cause is in the current tree, probably the Phase 4 unit balance, which makes the
walkers stronger. The Phase 2 notes describe the same effect as gotcha 8.

Excerpt from the 10/10 logistics run (`build/p4-logistics-run3-server.log`):

```
[rts] logistics autotest check logistics_hub_composite: PASS hub #173 at (-87.0, 61.0) (61 tiles from the CC): kind=hub power=true pole=true stockpiles=2 robots=10+6 buffer 20.0 MJ
[rts] logistics autotest check logistics_networks: PASS 2 networks; hub network 4, CC network 1
[rts] logistics autotest check logistics_hauler_speed: PASS 60 tiles from a standing start: walker 5.58 s = 10.7 tiles/s, hauler 2.78 s = 21.6 tiles/s, ratio 2.01
[rts] logistics autotest check logistics_auto_delivery: PASS hauler #178 delivered 50 iron to hub #173 after 7.0 s, hub network iron 50
[rts] logistics autotest check logistics_kit_deploy: PASS hauler #242 deployed 6.0 tiles from factory #187 after 9.0 s, home hub #173, kits left in output 0
[rts] logistics autotest check logistics_route_orders: PASS orders route-dropoff, route-pickup -> mode=manual pickup=#21 dropoff=#173 state=to_pickup
[rts] logistics autotest check logistics_hauler_lost: PASS alerts 0 -> 1, last kind=hauler-lost force=rts-player at (-87.0, 68.4); hauler record gone=true, unit record gone=true
[rts] logistics autotest check logistics_manual_route: PASS hauler #242 carried 60 copper CC -> hub in 6.0 s (hub copper 60)
[rts] logistics autotest summary 10/10 (all passed)
```

The create log confirms the cursor filter and the raid masks:

```
[rts] logistics: rts-cursor select type filters: spider-unit spider-vehicle unit
[rts] logistics: trigger target masks rts-hub=[common rts-raid-target] rts-hauler=[common rts-raid-target]
```

### GUI self-test

The steps run while the self-test is on, between the HUD steps and the match-flow steps:

| Tick after setup | Step |
|---|---|
| 1000 | A hub 45 tiles south of the CC, keep stone 30, export coal above 10, 200 iron into the CC network, an auto hauler. The camera goes there and the hub is selected. |
| 1050 | Screenshot of the hub panel: `rts-p1-1050.png` |
| 1080 | The hauler is selected. Shift + right click on the hub, then a right click on the CC, through `orders.handle_reverse_area`. |
| 1140 | The camera goes to the hauler. Screenshot of the hauler panel: `rts-p1-1140.png` |
| 1170 | Selection cleared, camera home, marker `RTS_LOGISTICS_GUI_DONE` |

What the screenshots show, in both languages:

- **Hub panel** (`rts-p1-1050.png`): "Hub 1: stockpile policy", "Network #5, 1 hub", "Auto haulers based here: 1.
  Arriving with cargo: 0.", the hint, and the item table with Keep 50 / 20 / – / 30 and Export above 10 for coal.
  Counts are yellow where they are below keep. The hub stands with its two stockpiles and the small blue hauler.
  The HUD's building page reads "Hub #269, HP 1200/1200, Status: Working" in the English run.
- **Hauler panel** (`rts-p1-1140.png`): "Hauler #274", Route toggled, HP 400/400, "Route: Command Center → Hub 1",
  "State: To pickup: Command Center (6 tiles)", "Cargo: empty", "Trips: 0. Delivered: -", Return home, and Resume
  greyed out. The HUD unit page shows "hauler ×1" and "Order: haul", the raw strings (see "For the HUD agent").
- **Fit.** Nothing is clipped in either language. The panel sits under the minimap and over the map's right edge,
  clear of the build menu.

The first Russian GUI run kept going a few seconds past the marker, and its log shows the route working:
`loaded 50 iron-plate at hub #172`, then `delivered 50 iron-plate to hub #289`.

## Measured numbers

| What | Value |
|---|---|
| Hauler speed, 60 tiles from a standing start, leg speed 4.4 | 21.4 to 21.6 tiles/s against the walker's 10.7 to 10.8: ratio 1.98 to 2.01 over two runs |
| Leg speed against hauler speed, same probe | 1.6: 14.2, 2.2: 15.7, 2.7: 17.5, 3.2: 19.0, 4.0: 21.2, 4.8: 21.8 tiles/s. Leg scale 1.3 at 3.2: 19.6. |
| Auto delivery, hub 61 tiles from the CC | 50 iron 7 s after the hauler appeared (two 60-tile legs plus planning) |
| Kit to hauler | 9 s from the recipe being set: the 8 s craft, then the next 60-tick sweep |
| Manual CC → hub copper | 60 copper 6 s after the route order |
| Moat, source hub to target hub, 58 tiles apart in a straight line | Route 80 tiles through the gap in 3 waypoints, found in 2 to 3 ticks. Legs 4.0 and 4.5 s; 50 iron delivered 9 s after the hauler appeared. |
| Route answer time | 0 to 3 ticks for routes up to 90 tiles |

## Gotchas

1. **`create_spidertron` is a global of base's data stage.** It is defined in `base/prototypes/entity/entities.lua`,
   and a later mod can call it to get a scaled spidertron with its own legs. It sets `minable.result` to the entity
   name, which is not an item here, so the file clears `minable` right after the call.
2. **A spider-vehicle has no speed field.** The legs set the pace, and the speed grows much slower than
   `leg_movement_speed` (see the table). Re-measure with the probe after any leg change.
3. **A spider-vehicle is not commandable.** `entity.commandable` is nil, so `units.stop` and orders.lua's `command`
   silently do nothing. An unclaimed hauler would be "moved" by `orders.move`, claimed as `move` and never released.
   Haulers are therefore claimed (`order = "haul"`, `issuer = "logistics"`), and the right-click hook handles them
   first.
4. **The RTS cursor did not pick up spider-vehicles.** Its select filters were `spider-unit` and `unit`. The data
   stage adds `spider-vehicle` (`prototypes/logistics.lua`, after `prototypes/cursor.lua`), and selection.lua stays
   unchanged.
5. **A 1×1 hidden pole under a 4×4 hub snaps to a tile centre.** The hub centre is a tile corner, so the pole ends up
   0.7 tiles away. The part lookup uses radius 1, not 0.5.
6. **The trunk size is fixed at runtime.** Research capacity cannot resize the inventory, so the prototype has 40
   slots and the script caps loading. Nobody can open the trunk: there are no passengers and no character.
7. **`die()` raises `on_entity_died` synchronously.** The check right after `die()` already sees the alert and both
   registries cleaned up.
8. **`on_init` log lines go to the create log.** `headless-run.sh` creates the map in a separate process, so
   `logistics.init`'s cursor-filter line is in `build/<run>-create.log`, not in the server log.
9. **Two runs of one copy directory collide.** The second fails at map creation: "Couldn't acquire exclusive lock
   ... Is another instance already running?". Give parallel runs their own directories.
10. **Cliffs, trees and buildings carry the `water_tile` collision layer.** That is `building()` and `cliff` in
    `core/lualib/collision-mask-defaults.lua`. Whether `colliding_with_tiles_only` keeps the pathfinder from treating
    them as obstacles was not verified. The route mask uses `doodad` instead, which only water, deep water and
    out-of-map tiles carry.
11. **Every queued autopilot waypoint costs speed.** A 60-tile leg through about 15 waypoints took 4 s instead of 3,
    so routes keep only their turns.
12. **The pathfinder's long paths detour on open ground.** Its long-range search goes through chunk-level nodes. A
    61-tile leg with nothing in the way came back 80 tiles long, and a diagnostic found no blocking tile or entity in
    the corridor. Only that direction detoured; the reverse leg was straight. String pulling fixes it.
13. **Testing a crossing needs a margin.** A route 1.5 tiles from the band's edge still let the spider's centre dip
    into the edge rows on a turn. The moat check counts only the band's interior rows, 2 tiles in from each edge.

## Open items and decisions for the lead

- **No hub button in the build menu.** The player cannot place a hub until `hud.lua`'s `BUILD_ITEMS` gets
  `rts-hub`. That file belongs to the HUD agent. Until then a hub can only be placed by script, for example
  `surface.create_entity{name = "rts-hub", position = ..., force = ..., raise_built = true}`.
- **Haulers count as units.**
  - `units.count` includes them, so the HUD army number counts them. Supply charges 0 for them
    (`balance.units["rts-hauler"]`).
  - `match.is_out` sees a force with only haulers left as still in the game.
  - The AI army should filter them (see "What the AI agent needs").
- **Not tested with real input.** These still need an interactive QA pass:
  - A real left click or box drag on a hauler. The filter is verified through the prototype API.
  - A real right click and Shift + right click on a hub, and the policy text fields.
- **X and H do not stop haulers**, because they are claimed. The panel's Return home and a ground right click cover
  that.
- **A policy changed by script** (AI, console) shows in an open hub panel only after it is reopened. Typing is never
  overwritten.
- **Legacy waves autotest is at 64/65** in the current tree. It is not caused by this work; see Validation.
