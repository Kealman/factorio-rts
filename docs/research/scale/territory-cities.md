# Territory, cities and population at grand-strategy scale

Research study for the "mini-state" direction: a 2000×2000-tile map, 4 nations with about 10 cities each, trains, trade and war, in the spirit of *Rise of Nations* (RoN) and *Workers & Resources: Soviet Republic* (W&R).
Scope of this study: national territory, cities, population, labor and needs, and how they plug into the existing mod (Phase 4: CC, hubs, haulers, supply, research, AI).
Date: 2026-10-16. Game: Factorio 2.0.77. API names below are from `runtime-api.json` and `prototype-api.json` in the installed `doc-html/`.

## 0. Verdict in one paragraph

Territory and cities are cheap for the engine and expensive for design. A per-force ownership grid of 8×8-tile cells on a 2048×2048 map (65,536 cells) recomputes from 72 sources in 4 ms, its borders render as about 2,600 merged line runs, and render objects add **no measurable update cost** even at 55,000 objects (headless benchmark below). The work is in the city simulation, labor, and an AI that can found and feed cities. The recommended model ties everything to one lookup: every cell knows its **force and its city**. A building's city is the city whose land it stands on. That city supplies its workers, its needs are delivered to that city's market, and capturing that city flips its land and buildings. Effort: about 21 agent-days in three phases, plus integration buffer.

## 1. What made the two games work, and what transfers

### 1.1 Rise of Nations (2003)

- **Borders are the scoreboard.** Cities and forts push national borders; Civics research widens them. Who is winning is visible on the minimap as coloured land.
- **You build inside your borders.** Expansion means founding a city first, with a minimum spacing between cities and a city limit raised by Civics research. Expansion is a deliberate, capped act.
- **Attrition.** Enemy units inside your borders slowly lose HP. A supply wagon next to the army stops it. Deep raids are possible but have a clock, and big invasions need a logistics tail.
- **The economy scales with cities.** Each city supports a fixed number of farms, and the Commerce cap limits gathering per resource. More output means more cities, not denser spam.
- **Cities are captured, not erased.** A captured city flips with its land. The loser can retake it, which creates comebacks and front lines.
- **Place matters.** Rare resources inside your borders grant bonuses, and trade caravans between your cities earn more over longer routes.

### 1.2 Workers & Resources: Soviet Republic

- **People are a produced good.** Citizens live in housing and need food, clothes, alcohol, electronics and services. If those are delivered, the population grows and stays loyal.
- **Labor is the binding constraint.** Every factory needs workers who live within reach. Housing placement decides which factories can run.
- **Everything is physical.** Food, goods and even construction material travel by truck, conveyor or train. A food shortage starts on a broken supply line.
- **Shortage is visible and gradual.** Shops run empty, buildings show missing workers, people leave. The player sees the cause and has time to react.
- **Geography drives specialisation.** Mining towns sit on ore, ports on water and farm towns on fertile land.

### 1.3 Principles that transfer to a Factorio RTS

| # | Principle | Source | Our form |
|---|---|---|---|
| P1 | Land is the scoreboard: power must read as coloured territory | RoN borders | ownership grid, border lines in game and map view, territory share in the HUD |
| P2 | Expansion is a deliberate, capped act | RoN city limit, spacing | a City Center needs a charter (colonists + materials), 96-tile spacing, a city limit raised by Civics research |
| P3 | Output scales with settlements, not with free placement | RoN farm slots, W&R labor | every production building needs workers from the city whose land it stands on; farm slots per city tier |
| P4 | Deep strikes cost something unless you bring logistics | RoN attrition and supply wagon | attrition deep in enemy land; hubs, forts and haulers carrying rations stop it |
| P5 | People are produced from physical goods | W&R | population grows from rations, goods and power delivered to the city market by belts, robots and haulers |
| P6 | Shortage degrades gracefully and visibly | W&R | staffing by priority, a "No workers" status on idle buildings, decline with hysteresis, no death spiral |
| P7 | Conquest transfers instead of erasing | RoN capture | a captured city flips with its land and economic buildings and loses part of its population |
| P8 | Geography decides specialisation | RoN rare resources, W&R regions | city specialisations unlock special buildings that can only stand in that city's land |

The common thread is that **space gets an owner**. Today our map is a neutral board with ore on it. With territory, every tile belongs to a nation and to a city, and that owner decides who may build there, who feeds the buildings, and who pays attrition.

## 2. Territory

### 2.1 Ownership model

- **Grid.** Cells of 8×8 tiles. A 2048×2048 map has 256×256 = 65,536 cells. Each cell stores `force` (0 = neutral) and `city` (the source that claims it). A chunk grid (32×32) is too coarse: a base edge cuts through chunks and the borders step in 32-tile stairs. A 4×4 grid quadruples every cost for little gain.
- **Sources.** Each claiming entity has a radius `r` in cells and a strength `s`.

| Source | r (cells / tiles) | s | Notes |
|---|---|---|---|
| Capital (the old CC) | 15 / 120 | 6 | one per nation |
| City Center, village | 6 / 48 | 3 | tier from population (section 3.4) |
| City Center, town | 9 / 72 | 4 | |
| City Center, city | 12 / 96 | 5 | |
| Fort | 5 / 40 | 2 | built at the border; garrison point; attrition supply source |
| Hub | 4 / 32 | 1.5 | keeps its logistics role; supply source |
| Radar / watchtower | 3 / 24 | 1 | small claim plus vision |
| Civics research | +1 cell per level for cities and forts | | 3 levels |

- **Score.** A source scores `s × (1 − d² / (r+1)²)` on every cell within `r`. The highest score wins the cell. A cell already owned keeps its owner unless a challenger beats it by 15 %. This stickiness stops borders from flickering when two cities grow side by side.
- **Supplied sources only.** A city claims land only while it has power and its food satisfaction is at least 25 %. A starving city's land shrinks back towards its centre, which is the first visible sign of a supply problem.
- **City of a cell.** The winning source's city id is stored with the cell. Forts, hubs and radars hand their cells to the nearest own city, so every own cell belongs to exactly one city. That one value drives labor (section 3.3), needs, specialised buildings and capture.
- **Recompute on events, never per tick.** Sources change when a city changes tier, a fort or hub is built or destroyed, a city is captured, or a city starts or stops starving. Each change recomputes only the bounding box of the old and new disk. The work goes into a job queue that spends at most 1 ms per tick.
- **Storage.** Two flat arrays of 65,536 small integers are large in `storage`. Store each row as a 256-byte string, read with `string.byte`, which totals 2 × 64 KB per save. Rewrite only the rows a job touched.

### 2.2 Build rules

Players build ghosts in remote view, so `on_built_entity` fires with an `entity-ghost`. The handler checks the cells under the ghost's footprint. If the rule fails, it calls `LuaEntity.destroy()` on the ghost and shows `LuaPlayer.create_local_flying_text` with the reason. `on_pre_build` exists but cannot cancel a build, so destroy-after is the pattern. `on_robot_built_entity` and `script_raised_built` re-check, because a border can move between ghost and construction. The AI planner (`scripts/ai/layout.lua`) asks `territory.can_build(force, name, box)` before it places anything.

| Building | Own land | Neutral land | Enemy land |
|---|---|---|---|
| City Center (needs a charter) | yes, at least 12 cells from every City Center | yes, same spacing, within 20 cells of own land | no |
| Fort, hub, radar, turret | yes | within 3 cells of own land | no |
| Belt, pole, rail, wall, pipe | yes | yes (infrastructure corridors) | no |
| Farm | yes, within the city's farm slots (3 / 6 / 10 by tier) | no | no |
| Specialised building (section 3.6) | only in land of a city with that specialisation | no | no |
| Everything else | yes | no | no |

When land under an existing building flips to another nation, the building becomes **occupied**. It is switched off with `LuaEntity.disabled_by_script = true` and shows `custom_status = {diode = defines.entity_status_diode.red, label = {"rts.status-occupied"}}`. It works again if the land returns. Roboports ignore `disabled_by_script` (documented), so hubs keep their robots.

### 2.3 Attrition

- **Who.** Enemy units, haulers and the Commander inside a nation's land, when every cell within 2 cells is owned by that nation. In other words, the unit is at least 16 tiles deep. Border skirmishes cost nothing.
- **How much.** 1.5 % of max HP every 5 s, about 18 % per minute. Civics research raises it ×1.5 and ×2. The Commander takes half.
- **Supply stops it.** No attrition within 24 tiles of an own supply source: City Center, hub, fort, or a hauler in *supply* mode with rations in its trunk. A supply hauler uses 1 ration per 10 supplied units per minute. This makes the existing haulers the RoN supply wagon, and it gives raiders a target that matters.
- **API.** `LuaEntity.damage(amount, force, "rts-attrition")` with a new `damage-type` prototype that no resistance lists. The Armor II/III heal-back handler in `scripts/research.lua` skips that type. The unit registry already lists every unit, so the pass needs no surface search.
- **Cost.** The depth test is a 5×5 window of cell reads per unit inside hostile land. No global distance field is needed. The probe's full depth BFS took 10 ms, so the window test is the one to use.

### 2.4 Rendering the borders

| Option | API | Verdict |
|---|---|---|
| Line per merged border run, per owning side, offset 0.5 tiles inward | `rendering.draw_line{from, to, color, width, dash_length, gap_length, draw_on_ground, render_mode}` | **use**; one set with `render_mode = "game"` and one with `"chart"` |
| Filled tint per row run of owned cells | `rendering.draw_rectangle{filled = true, render_mode = "chart"}` | **use in map view only** (RoN-style coloured map); in game view it would tint the whole base |
| One polygon per region | `rendering.draw_polygon{vertices}` takes a triangle strip | no: regions are concave with holes, and triangulating them on every change is work for no gain over lines |
| Tile overlay | `LuaSurface.set_tiles` | no: tiles are global, not per force; they replace terrain and change walking speed and buildability. It is cheap (1,824 tiles in 0.44 ms) and could pave city cores as decoration |
| Chart tags | `LuaForce.add_chart_tag` | city names on the map only |

Visibility. Borders are public, as in RoN, so the objects get no `forces` filter. Line width is in pixels at 32 per tile, so it scales with zoom. Our camera allows zoom out to 0.15 in game view (`scripts/camera.lua`), where a 3-pixel line is under half a screen pixel. Use dashed lines 12 to 16 pixels wide in game view and 2 to 3 pixels in chart view.

Incremental redraw. Render objects are kept per boundary row and per boundary column. A territory job destroys and redraws only the rows and columns its box touches.

### 2.5 Probe results

A standalone probe mod (`build/scale-probe-cities/rts-scale-probe/control.lua`) ran headless on Factorio 2.0.77. The map had 4 nations, each with a capital, 10 cities of random tier, 5 forts and 3 radars, so 72 sources on a 2048×2048 grid of 8×8 cells. Timings come from `helpers.create_profiler()`. Update cost comes from `factorio --benchmark` on saves written at each stage, replayed through a script-free copy of the mod so only the engine runs.

| Operation | Size | Time |
|---|---|---|
| Full ownership recompute | 65,536 cells, 72 sources | 3.6–4.9 ms |
| Border extraction, whole map | 3,835 cell edges merged into 2,601 runs | 6.3–7.4 ms |
| Depth BFS over all owned cells (not needed, see 2.3) | 13,261 cells, max depth 16 | 10.1–11.1 ms |
| Attrition lookup | 800 units | 0.12 ms per pass |
| Draw all borders, game view | 2,601 lines, extraction included | 22 ms |
| Redraw game and chart views | 5,202 lines created, 2,601 destroyed | 23.5 ms |
| Destroy all border objects | 5,202 | 3.0 ms |
| Filled chart tint, row runs | 953 rectangles | 7.6 ms |
| Incremental city resize: box recompute plus full-width row and column redraw | box 19–25 cells, mean of 30 | 4.4 ms (3.0–4.6) |
| Create 50,000 extra lines | 50,000 | 108 ms (2.2 µs each) |
| `set_tiles` of a border ring | 1,824 tiles | 0.44 ms; restore with correction 0.62 ms |

| Save (benchmark, 1,200 ticks × 3 runs) | Render objects | Avg update per tick | Save size |
|---|---|---|---|
| probe-A | 0 | 0.157–0.180 ms | 768 KB |
| probe-B | 5,202 border lines | 0.155–0.159 ms | 844 KB |
| probe-C | 6,155 (borders + tint) | 0.162–0.173 ms | 861 KB |
| probe-D | 55,246 (stress) | 0.152–0.157 ms | 1,722 KB |

What this settles:
- **Render objects cost nothing per tick.** Avg update time is flat from 0 to 55,000 objects. Each object adds about 15–18 bytes to the compressed save.
- **The full pipeline is a one-off 35 ms.** That is recompute, extraction and drawing both views. It belongs in match setup, not in play.
- **An incremental change costs about 4.4 ms.** The probe redrew whole 256-cell rows and columns. Clipping the redraw to the box plus the runs that cross it should bring this under 1.5 ms. With the 1 ms per tick job queue, a change finishes within a few ticks and never spikes.
- **Ten cities per nation do not fill a 2048 map.** With the radii above, the 4 nations owned 20 % of all cells (2,635 / 3,299 / 3,917 / 3,410). Land is plentiful early and contested only where nations grow towards each other. The world study should size the map or the radii with this in mind.

What it does not settle:
- **Client draw cost is unmeasured.** `--benchmark-frame` crashed with SIGSEGV in `~ScenarioExecutionContext` when loading a save from the headless server, which has no player. Phase 1 must open probe-B and probe-D in a GUI client, at zoom 1, at zoom 0.15 and in map view.
- **Minimap support is unknown.** It is not documented whether `render_mode = "chart"` objects appear on a `LuaGuiElement` of type `minimap`, which is our HUD minimap. Phase 1 checks this in the same GUI run.

Rerun: `tools/headless-run.sh 50 '\[probe' build/scale-probe-cities` (the saves land in `build/runs/scale-probe-cities/saves/`; create that folder first). For the benchmark, run `factorio --benchmark <save> --benchmark-ticks 1200 --benchmark-runs 3 --mod-directory build/scale-probe-cities-bench`.

### 2.6 Charting and fog

`scripts/fog.lua` re-charts squares around own units and buildings every 300 ticks. Territory adds one rule: **a nation sees its own land**. A nation with 3,300 owned cells covers about 200 chunks. Re-charting all of them every 300 ticks repeats what fog.lua does for buildings, at a larger scale. A cheaper variant charts the frontier chunks every 300 ticks and the interior every 1,800 ticks. Borders themselves are render objects and are visible through fog, as in RoN.

## 3. Cities

### 3.1 Founding a city

- **City Center** (`rts-city-center-1/2/3`): a 6×6 roboport composite like the hub. It has a logistic radius of 16 and a construction radius of 24, two stockpiles that form the **city market**, and a hidden `electric-energy-interface` that draws the city's power need. The three prototypes differ in robot ranges and HP. A tier change replaces the entity with `create_entity{fast_replace = true}` and moves its items.
- **Charter.** Founding costs a *City charter* item from the factory (100 iron, 50 stone bricks, 20 rations), plus 20 *colonist* items. Colonists come out of an existing town or larger city, whose population drops by 20. Haulers or the Commander's trunk carry them. The Commander places the ghost through its existing field construction (`scripts/commander.lua`). A new city starts as a village of 20 people.
- **Limit.** Each nation may have 3 cities plus 2 per Civics level, up to 10 at Civics III. The capital counts as one.
- **Sites.** Map generation marks city sites: flat land near ore, water or farmland, at least 96 tiles apart. The AI founds cities on those sites. Players may found anywhere the rules allow.

### 3.2 Population: what it is and where it lives

| Option | How | Verdict |
|---|---|---|
| Script number | `storage.cities[id] = {pop, housing, food, goods, power, tier, ...}` | **use** for population: exact, cheap, saves well; shown in our city panel |
| Items in the market | `rts-colonist` and `rts-recruit` items | **use** for people who move: settlers for new cities and recruits for the army, carried by haulers like any cargo |
| Hidden container per house | items in hidden chests | no: entities with no gain |
| Walking citizens | `unit` entities | no: thousands of pathing entities for flavour |

**Housing** is a building, the RTS analogue of pylons and farms. A small house (3×3, 20 people) and an apartment block (5×5, 80 people, town or larger) cost stone bricks, iron and goods. They count only on that city's land. The City Center gives 40 places of its own. Raiders that burn houses lower a city's ceiling, so housing districts become targets.

### 3.3 Labor

- **Workforce** = 60 % of a city's population, minus people under unrest after a capture.
- **Demand.** Each production building needs workers from **the city of the cell it stands on**:

| Building | Workers | Building | Workers |
|---|---|---|---|
| Extractor | 4 | Factory | 12 |
| Smelter | 4 | Barracks | 12 |
| Farm | 6 | Lab | 8 |
| Bakery | 6 | Steam plant | 4 |
| Turret, wall, pole, belt, inserter, stockpile, hub | 0 | City Center, houses | 0 |

- **Staffing.** If demand exceeds the workforce, buildings are staffed in priority order: food, then military, power, mining and smelting, industry, research. The player can reorder the categories in the city panel. Buildings that do not get staffed are switched off with `disabled_by_script = true` and show `custom_status` "No workers". This is discrete and readable: the player sees which smelter stopped and why. It is also cheap, because staffing is recomputed only when a building, a city's population band or a priority changes. A half-speed scheme would need a hidden beacon per building, and `LuaEntity.effects` is read-only, so it was rejected.
- **Starting numbers.** The capital starts at 120 people, which gives 72 workers. The Phase 4 opening (2 extractors, 2 smelters, factory, barracks) uses 40. Labs, farms and more lines take the rest, so the first real decision is to grow the capital or found a city.

### 3.4 Tiers and needs

| Tier | Population | Land radius | Farm slots | Supply | Needs to grow | Unlocks |
|---|---|---|---|---|---|---|
| Village | 20–99 | 6 cells | 3 | +4 | rations | houses |
| Town | 100–399 | 9 cells | 6 | +8 | rations, goods, 1 MW | apartments, specialisation, colonists |
| City | 400+ | 12 cells | 10 | +15 | rations, goods, 2 MW, luxury goods above 600 | special buildings tier 2 |
| Capital | any | +3 cells | +2 | +30 | as its tier | the old CC features |

- **Consumption.** 1 ration per 10 people per minute. From town tier, 1 goods per 25 people per minute. The city takes them from its market network with `LuaLogisticNetwork.get_item_count` and `remove_item`, the same way labs pull kits in `scripts/research.lua`. It logs negative flow with `LuaForce.get_item_production_statistics(surface).on_flow`, so vanilla production statistics show what cities eat.
- **Power.** The hidden interface's `power_usage` is set to the tier's need. Satisfaction is the fill of its buffer.
- **Growth.** Every 10 s per city, staggered across ticks: if every current need is met at 90 % or more and housing has room, population grows 4 % per minute. Between 50 % and 90 %, it holds. Below 50 % rations, it falls 3 % per minute, and without power at town tier or higher it falls 1 % per minute.
- **Hysteresis.** A city drops a tier only after 2 minutes below 80 % of the threshold. Land and supply shrink with the tier, never faster.
- **Needs are keep policies.** The city market is a hub network, so its needs are ordinary *Keep* amounts: by default rations 50 and goods 20, and the panel can raise them. Auto haulers already fill *Keep* amounts from networks that export (`scripts/logistics.lua`). Feeding a city therefore needs **no new transport code**, and the AI's existing hub logic feeds AI cities.

### 3.5 Food and goods chains

Base game (works without Space Age):

```
farm (5x5, 150 kW, 6 workers, farm slots)      -> 1 grain / 4 s (15 per minute)
bakery (3x3, 200 kW, 6 workers)                -> 2 grain  -> 3 rations, 3 s
fishing hut (on a coast, 4 workers)            -> 6 rations per minute, no input
factory recipe "goods"                         -> 1 iron plate + 2 copper cable + 1 stone brick -> 2 goods, 4 s
factory recipe "luxury goods"                  -> 2 goods + 1 circuit -> 1 luxury, 6 s
```

One farm and two-thirds of a bakery feed about 220 people. A town of 300 needs 2 farms, a bakery, and a factory line for goods. That is a visible district, which is what we want.

Farms are `assembling-machine` prototypes with a fixed recipe and no ingredients, limited by farm slots. They are not Space Age agricultural towers. `AgriculturalTowerPrototype` and `PlantPrototype` exist in the engine and are not behind a feature flag, but their art lives in the Space Age mod and plants are tied to Gleba tiles. They are a candidate for a Space Age skin in Phase 3, not the base mechanic.

**Spoilage is optional.** `ItemPrototype.spoil_ticks` and `spoil_result` need the *spoiling* feature flag, and `spoiling_required` in `info.json` requires Space Age ownership. The mod supports the base game, so it must not require that. Instead, `data.lua` checks `feature_flags["spoiling"]`, the data-stage global. When it is on, rations spoil in 15 minutes into nothing, which makes food logistics time-critical, a Gleba-style pressure. Without Space Age, rations keep.

### 3.6 Specialisation

At town tier a city picks one specialisation. It can change it after a 10-minute cooldown. A specialisation gives a labor discount and unlocks one special building that may only stand on that city's land. Placement uses the same cell lookup as everything else, so no per-entity effects are needed.

| Specialisation | Labor discount | Special building | Placement condition |
|---|---|---|---|
| Mining town | extractors and smelters −40 % | Deep extractor (1.5× speed) | ore in the city's land |
| Industrial | factory and barracks −40 % | Assembly works (factory ×1.5 speed) | none |
| Farming | farms and bakeries −40 % | Granary farm (×1.5 yield) | none |
| Port | haulers loaded here cost no labor | Docks / trade post (for the trade study) | water cells in the city's land |
| Garrison | barracks −40 % | Fortress (fort r 7, s 3) | border city |
| Science | labs −40 % | University (lab ×2 speed) | none |

## 4. How this fits the existing design

| Today (Phase 4) | With territory and cities |
|---|---|
| Command Center (roboport, 4 MW core, 4 stockpiles, supply 40) | **Capital City Center**: keeps all of that, adds population 120, land radius +3, supply +30 |
| Hub (forward logistics, +10 supply) | **Stays** as the logistics node; claims a small area; is an attrition supply source; its supply moves to cities |
| Supply cap (CC 40, hub +10, research +20) | **Stays** as the unit budget, now from city tiers plus research. Unit kits also take *recruits* (below) |
| Stockpile policies (keep / export above) | **Stay**; city needs are keep policies on the city market |
| Haulers (auto and manual routes) | **Stay**; they also carry rations, goods, colonists and recruits; new *supply* mode follows an army and stops attrition |
| Commander (field construction) | **Stays**; founds cities by placing City Center ghosts |
| Research (Supply, Attack, Armor, Mining, Logistics…) | **Stays**; adds a Civics branch: land radius, city limit, attrition and labor efficiency, 3 levels each where it makes sense |
| Fog (charts around own units and buildings) | **Stays**; nations also see their own land |
| Out rule: no CC, barracks or factory and no units | **Replaced**: out when a nation has no city and no army. Win by holding every rival capital for 3 minutes, or 60 % of claimable land for 3 minutes |
| Ruin in the middle | **Becomes** a neutral free city to capture |
| AI layout and build order | **Stay**; add `territory.can_build`, city sites and a city governor (Phase 2) |

**Recruits connect population to war.** Every unit kit recipe gets `rts-recruit` items equal to the unit's supply cost. A city with its draft switched on turns 1 person per 10 per minute into a recruit item in its market, and its population drops by one. Barracks already pull kit ingredients from their network (`scripts/production.lua`), so this is a recipe change plus an insert into the city network. Losses now cost people, a long war bleeds the cities that feed it, and recruits can be hauled to a front-line barracks. This is the strongest link between the RoN and W&R halves.

**Interfaces for the sibling studies.** `territory.owner_at(pos)`, `territory.city_at(pos)`, `territory.can_build(force, name, box)` and an `on_territory_changed(box)` callback. Rails and trade stations can use them for placement rules and for route value by distance across own land, which echoes RoN caravans.

## 5. Feasibility

Cost is for 4 nations × 10 cities on a 2048 map: about 2,000 production buildings, 800 units and 40 City Centers. "Measured" means the probe above. Everything else is an estimate from the operation counts.

| Mechanic | Runtime API | Average cost per tick | Peak | Risk |
|---|---|---|---|---|
| Ownership grid, incremental recompute | Lua only (`storage`), job queue on `script.on_nth_tick` | about 0.02 ms at 1 change per 5 s (measured 4.4 ms per change, spread) | 1 ms (queue cap) | Low |
| Border lines and chart tint | `rendering.draw_line`, `rendering.draw_rectangle`, `LuaRenderObject.destroy`, `render_mode = "chart"` | 0 update cost (measured) | creation inside the queue | **Medium**: client draw cost and minimap support unmeasured |
| Build rules | `on_built_entity`, `on_robot_built_entity`, `script_raised_built`, `LuaEntity.destroy`, `LuaPlayer.create_local_flying_text` | per build only, µs | none | Low; the AI planner must call the check too |
| Occupied buildings | `LuaEntity.disabled_by_script`, `LuaEntity.custom_status` | on border change only | a few hundred writes | Low |
| Attrition | unit registry, cell reads, `LuaEntity.damage` with a custom `damage-type` | 0.002 ms (0.12 ms per pass of 800 units every 60 ticks, measured) | about 0.5 ms if 100 units are damaged | Low |
| Supply sources | `LuaControl.get_inventory` on the hauler trunk, distance checks | under 0.01 ms | none | Low |
| City simulation | `LuaLogisticNetwork.get_item_count`, `remove_item`, `insert`, `LuaEntity.power_usage`, `LuaFlowStatistics.on_flow` | under 0.01 ms (40 cities every 600 ticks, staggered) | 0.1 ms | Low |
| Labor staffing | `disabled_by_script`, `custom_status`, building registry | on change only | up to 2,000 writes on a famine, spread over ticks | Low–Medium: balance |
| Tier change | `LuaSurface.create_entity{fast_replace = true}`, item transfer | rare | 1 ms | Medium: the roboport swap may drop robots in flight |
| Capture | `LuaControl.force` (writable), `LuaEntity.destructible`, `LuaSurface.find_entities_filtered` over the city's cells | contested cities only | about 2 ms per flip | **Medium**: logistic networks and robots re-form after a force change |
| Own-land charting | `LuaForce.chart` | about 0.05 ms (frontier only) | 200 chart calls | Low–Medium |
| Spoiling rations (Space Age only) | `ItemPrototype.spoil_ticks`, `feature_flags["spoiling"]` | engine side | none | Low |
| Agricultural-tower farms (optional skin) | `AgriculturalTowerPrototype`, `PlantPrototype`, `on_tower_mined_plant` | engine side | none | Medium: Gleba art and tiles, base-game fallback needed |
| AI city governor | everything above, plus city sites | under 0.05 ms | none | **High**: design, not UPS (section 7) |

The whole territory and city layer should average **under 0.1 ms per tick** with peaks capped at 1 ms by the job queue. Units, pathing and production dominate UPS at this scale, and those belong to the war and economy studies.

## 6. Phased plan

Effort is in agent-days for one Opus or Sonnet implementation agent with headless validation. Each phase ends with a GUI check through `tools/gui-run.sh` or a Codex computer-use run.

### Phase T1: Territory (5 agent-days)

| Work | Days |
|---|---|
| `scripts/territory.lua`: grid as row strings, sources from CC, hubs, forts and radars, stickiness, job queue, `owner_at` / `city_at` / `can_build`, save and load | 1.5 |
| Border rendering: game and chart lines, chart tint, row and column object tables, clipped incremental redraw | 1.0 |
| Build rules for player ghosts, robot builds and the AI layout hook; occupied buildings | 1.0 |
| Attrition, the `rts-attrition` damage type, supply sources (hubs, forts, City Center, supply haulers) | 0.5 |
| Fort and watchtower prototypes, HUD territory share, debug commands, autotest | 1.0 |

Acceptance:
1. A headless autotest places ghosts in own, neutral and enemy land for each building class. Every result matches the table in 2.2.
2. Six walkers parked 40 tiles inside AI land lose 15–25 % HP in 60 s. Next to their own hub, they lose 0 %.
3. In a 20-minute 1v3 large match with `PERF=1`, the territory handlers average under 0.1 ms per tick with no tick over 2 ms.
4. A save at minute 10, when reloaded, gives the same render object count and the same grid checksum.
5. A GUI run shows borders at zoom 1, at zoom 0.15 and in map view, and records whether the HUD minimap shows chart objects. If the client frame time rises by more than 1 ms with probe-D, cut the line count by merging runs or by drawing chart lines only.

### Phase C2: Cities and population (9 agent-days)

| Work | Days |
|---|---|
| Prototypes: City Center tiers, houses, apartments, farm, bakery, fishing hut; items: rations, goods, luxury goods, colonist, recruit, charter; recipes and balance entries | 1.5 |
| `scripts/cities.lua`: population, needs from the market network, power interface, growth, tiers with hysteresis, production statistics | 2.0 |
| Labor: assignment by cell, priority staffing, "No workers" status, panel priorities | 1.5 |
| CC becomes the capital, supply from tiers, recruits in kit recipes and the draft | 1.0 |
| City panel (population, needs bars, workforce, draft, priorities) and HUD summary | 1.5 |
| AI city governor: found 2–4 cities on city sites, keep policies for rations and goods, default priorities, draft by doctrine | 1.5 |

Acceptance:
1. In a 30-minute headless 1v1 on a large map, a scripted player city that is fed grows from village to town by 10:00 and to city by 25:00.
2. A city whose food line is cut falls below its rations threshold. Its lowest-priority buildings show "No workers" within 2 minutes, and it recovers after the line is restored.
3. Each AI founds at least 2 cities by 20:00, and no AI city stays below 50 % rations for more than 3 minutes.
4. A stress fixture with 40 cities and 2,000 staffed buildings keeps the city and labor handlers under 0.2 ms per tick on average.
5. Units are refused without recruits, and losses lower population.

### Phase W3: War over land, specialisation, victory (7 agent-days)

| Work | Days |
|---|---|
| Capture: City Center becomes indestructible below 25 % HP, capture progress like the ruin (`mapgen.capture_step`), flip of land and economic buildings, population −30 %, 5 minutes of unrest | 2.0 |
| Specialisations and the six special buildings | 1.5 |
| Civics research branch | 0.5 |
| Victory: capitals or 60 % of claimable land for 3 minutes; results window | 0.5 |
| AI: target enemy cities, defend its own, supply haulers with attack groups | 1.5 |
| Space Age option for spoiling rations; balance batch on the 2048 map | 1.0 |

Acceptance:
1. A scripted capture flips the City Center, its land and every economic building in it within one job-queue cycle. Turrets in it are destroyed, and population falls 30 %.
2. A 60-minute headless run with 4 nations and up to 10 cities each on a 2048 map averages under 8 ms per tick in total, with the mod's script under 1.5 ms.
3. A territory victory fires when one nation holds 60 % of claimable cells for 3 minutes.
4. In a 20-run balance batch, no nation starves in more than 10 % of runs, and at least one city changes hands in more than half of the runs.
5. A save and reload during a capture produces no errors.

**Total: about 21 agent-days, or about 25 with a 20 % integration buffer.** Phase T1 does not depend on cities and can start as soon as the world study fixes the map size.

## 7. Risks

1. **The AI must play a city economy (biggest risk).** The AI is 5,900 lines of build orders, layout and army logic built around one CC. Founding cities, keeping them fed, managing labor and choosing a specialisation is a new brain. Mitigations:
   - The city simulation regulates itself: needs are keep policies, so existing haulers and hub logic do the feeding.
   - Staffing priorities have sensible defaults.
   - The AI governor and a player "auto-governor" button share one code path.
   - Phase C2 gates on AI cities not starving, not on AI brilliance.
2. **Readability.** Population, labor, needs and attrition add four new reasons for things to stop. Every stop must show on the building (`custom_status`), in the city panel and as an alert with a jump, as the hauler-lost alerts do today.
3. **Client draw cost and the minimap.** Both are unmeasured (section 2.5). The fallback is to draw chart lines only and rely on map view for borders.
4. **Force flips on capture.** Changing `LuaControl.force` on roboports and stockpiles splits and re-forms logistic networks, and robots in flight may be lost. This must be probed early in Phase W3.
5. **Pacing on a big map.** The probe's ten cities per nation claimed only 20 % of the map. Without tuning, land will not be contested until late. The world study should size the map, the radii or the number of nations together.

## 8. The five strongest ideas

1. **One lookup for everything.** Every cell stores its force and its city. Build rules, labor, needs, specialised buildings and capture all read that one value.
2. **Recruits.** Units cost people drawn from cities. War bleeds the economy, and the economy limits war, which binds the RoN and W&R halves.
3. **Needs as keep policies.** A city's market is a hub network, so rations and goods arrive through the existing haulers, robots and AI hub logic. No new transport code is needed.
4. **Attrition with supply sources.** Hubs, forts and haulers carrying rations stop attrition. Haulers become the supply wagon, and fronts and supply lines appear on their own.
5. **Staffing by priority with a visible status.** Buildings switched off with `disabled_by_script` and labelled "No workers" make shortages readable, cost almost nothing, and give the player a lever in the priority list.

Runner-up: capture instead of destroy, and specialised buildings that may only stand on a specialised city's land.
