# Deep economy for the mini-state scale: ages, chains, money and labor

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Research study: nothing in `mods/` was changed.

**Brief.** The next leap is a "mini-state" game in the spirit of Rise of Nations and Workers & Resources: Soviet
Republic. The player runs several cities joined by trains, and the economy is the star. This study covers the deep
economy: production tiers and ages, money, labor, and the chains that force cities to cooperate.

**Sources.** The project docs and code, the installed game's `runtime-api.json` and `prototype-api.json` (every API
name below was read there), vanilla `data/base/prototypes/recipe.lua`, and a headless probe in
`build/scale-probe-economy/` (section 8.2). The sibling studies in `docs/research/scale/` cover cities, rails and the
world map; section 9.4 lists what this study assumes from them.

## 0. Summary

- **Ages.** Today's whole skirmish content becomes Age I. Age II (industrial: oil, plastics, engines, trains) and
  Age III (modern: processing units, nuclear power, robots) reuse vanilla's recipe graph almost unchanged. Each age
  needs research plus a *national project*: a construction site in the capital that trains must feed.
- **Districts, not inserters.** A district is one large crafting machine with a compressed recipe. It is fed from
  the city's logistic network and staffed by workers. Hand-built Factorio lines stay available and need fewer
  workers per output, so Factorio skill still pays at state scale.
- **Cooperation from geography and labor.** Oil, water, fertile land and uranium sit in different regions. Housing
  and food cap every city's workforce. Age II and III goods need 4 to 6 stages, more than one city can staff.
- **Money is a script-side treasury, and trade is physical.** Money pays upkeep, soldiers and imports. It comes
  from taxes and from goods delivered to a trade port, where a world market that AI nations also move sets prices.
- **Labor.** Housing tiers in the style of Anno supply workers, engineers and scientists when their needs are met.
  Staffing sets a machine's speed through hidden labor modules. Soldiers are drafted out of the workforce.
- **Supply.** Units carry a supply level that depots refill from munitions. Unsupplied units deal less damage and
  suffer attrition in enemy land. Rails, power lines, depots and trade ports become the raid targets that matter.
- **The probe settled the main technical doubt.** A script-inserted negative-speed module throttles a machine
  exactly and cuts its power. Per-force recipe productivity works on any recipe. Each write costs microseconds.
- **Plan.** Three phases, about 57 agent-days, on top of the city and rail work. The biggest risk is an AI that can
  run this economy, so every economic decision goes through policies that the player and the AI set the same way.

## 1. Principles from the reference games

1. **Everything is a physical good** (Workers & Resources). Every brick and worker moves in a vehicle, and a site
   waits for its materials. *Rule:* goods never teleport between cities, and robots build ghosts from network items
   as they do today. Money is the one abstraction, and it buys goods only at a physical trade port.
2. **Distance is the price** (Factorio, W&R). Link throughput limits growth, not ore. *Rule:* every link has a
   capacity the player can see and raise, and cutting a link is economic warfare.
3. **Chains serve people, not only armies** (Anno). Anno ties each chain to a population tier whose satisfied needs
   unlock better citizens. *Rule:* three housing tiers consume food, household goods and consumer electronics.
   Satisfied tiers supply the engineers and scientists that Age II and III buildings need.
4. **Uneven land makes trade** (Anno islands, Rise of Nations rare resources). *Rule:* oil, water, fertile land,
   uranium and rare deposits sit in different regions. A rare deposit grants a nation-wide bonus while its output
   reaches the capital.
5. **Ages are expensive, visible milestones** (Rise of Nations). An age costs knowledge plus a pile of other
   resources and changes the whole roster. *Rule:* an age needs research plus a national project, a site that
   consumes hundreds of delivered goods and that an enemy can raze.
6. **Caps grow with the economy** (RoN commerce cap and population cap). *Rule:* trade volume per minute is capped
   by trade ports and research. Army size is capped by supply and by free workers.
7. **Labor has a place** (W&R). Workers live somewhere and work nearby. *Rule:* a building draws workers only from
   its own city, so a city's housing and food cap its industry.
8. **Manage the state, not the inserter** (RoN versus Factorio). RoN gives a city one click per building; Factorio
   asks for every belt. *Rule:* districts are single buildings with compressed recipes and no inserters. Hand-built
   lines are optional and save labor.
9. **Infrastructure is the target** (W&R, Factorio). *Rule:* rails, power lines, depots, project sites and trade
   ports carry the raid target type. Cutting one starves a city a few minutes later, and its ledger shows when.
10. **Every flow is visible** (Factorio production statistics, Anno need bars). *Rule:* each city has a ledger of
    produced, consumed, imported and exported goods per minute, plus labor and needs. Script-side consumption such
    as food eaten is written into the vanilla production statistics with `LuaFlowStatistics.on_flow`.

## 2. Ages and production tiers

### 2.1 The age ladder

| | Age I: Settlement | Age II: Industrial | Age III: Modern |
|---|---|---|---|
| Typical span at normal pace | 0–14 min | 14–32 min | 32 min on |
| Power | CC core, solar, steam plant | coal power station, power lines between cities | nuclear plant, solar fields, accumulators |
| New raw resources | iron, copper, stone, coal, fish | crude oil, water | uranium; rare deposits pay off |
| Key goods | plates, steel, gears, cable, circuits, bricks, coal explosives, rations | plastic, sulfur, sulfuric acid, vanilla explosives, advanced circuits, engines, concrete, rails, piercing ammo, household goods | processing units, batteries, low-density structures (LDS), electric engines, robot frames, modules, fuel cells, rocket fuel, consumer electronics |
| Links between cities | haulers | trains with cargo wagons | trains, power lines; logistic robots inside cities |
| Units | today's roster | assault walker (needs engines), artillery Mk2, armoured train (rails study) | laser walker, colossus (spidertron class), artillery fortress |
| Science kit | basic and advanced (today) | industrial kit | modern kit |
| Housing tier | tenement: workers | apartment block: engineers | modern apartments: scientists |
| Project for the next age | Railway Charter | Polytechnic University | Space Program (victory) |

Today's two research tiers both live inside Age I. The whole current skirmish is the first age of the state game, so
nothing that works today has to change. A "Skirmish" match mode keeps today's game, and a "State" mode adds Ages II
and III, cities and money.

The science kits copy the vanilla pattern that makes Factorio's packs a logistics test. The industrial kit follows
the vanilla chemical science pack (2 engines, 3 advanced circuits, 1 sulfur per 2 packs). Its inputs come from three
places: steel from the mining town, plastic and sulfur from the oil town, circuits from the industrial city. The
modern kit follows the vanilla utility pack (3 LDS, 2 processing units, 1 robot frame per 3 packs).

### 2.2 How deep the chains get

| Final good | Age | Stages | Raw inputs | Cities a typical nation needs |
|---|---|---|---|---|
| Walker kit | I | 2: ore, plate, kit | iron, copper | 1 |
| Advanced kit | I | 4: ore, plate, cable, circuit, plus steel | iron, copper | 1 |
| Household goods | II | 4 | iron, copper, coal, oil | 2–3 |
| Industrial kit | II | 5 | iron, copper, coal, oil, water | 3 |
| Assault walker kit | II | 5, plus munitions to keep it fighting | iron, copper, coal, oil | 3 |
| Modern kit | III | 6 | iron, copper, coal, oil, water | 3 |
| Uranium fuel cell | III | 4 | uranium, iron | 2, one of them on contested ground |
| Rocket part | III | 7 | all of the above | 3 or more |

### 2.3 What vanilla gives for free and what we author

**Free.** The vanilla recipes for plastic bar, sulfur, sulfuric acid, explosives, advanced circuit, processing unit,
engine unit, electric engine unit, battery, LDS, flying robot frame, concrete, rail, solid fuel, rocket fuel, uranium
processing, uranium fuel cell, the nine modules, piercing rounds and barrels. With them come the items, icons, fluids,
machine graphics and sounds, the production statistics GUI and the whole train system. Their ingredient structure is
kept. Amounts and times are scaled down the way `balance.smelting` already scales steel (2 plates in 6.4 s instead of
5 plates in 16 s), because vanilla sizes them for a 100-hour factory.

**Authored.** One compressed recipe per district (section 3.4); the consumer goods (rations, household goods,
consumer electronics) with tinted vanilla icons; the industrial and modern kits as tinted copies of the vanilla
chemical and utility packs; project items and sites; hidden labor and automation modules; a munitions item per age;
rare resources cloned from stone and uranium ore; and `balance.lua` tables for districts (jobs, upkeep, family),
goods (base price) and housing (capacity, tier, needs).

### 2.4 Vanilla prototypes to clone as RTS buildings

| Vanilla prototype | RTS building | Age | Notes |
|---|---|---|---|
| `assembling-machine-1/2/3` | workshop, factory (exists), advanced factory | I, I, II | Generic recipe machines and hand-built lines |
| `stone-furnace`, `steel-furnace`, `electric-furnace` | smelter (exists), steel works | I, II | Steel works: scaled-up furnace graphics, compressed recipe |
| `electric-mining-drill` | extractor (exists) | I | |
| `pumpjack` | oil well | II | Oil regions only; crude goes into a pipe |
| `oil-refinery` | refinery complex | II | Crude (fluid) plus coal gives plastic and sulfur as items |
| `chemical-plant` | chemical works | II | Sulfuric acid, explosives, batteries |
| `offshore-pump`, `storage-tank`, `pipe` | water works | II | Fluids stay inside one city |
| `boiler` and `steam-engine` | coal power station | II | A composite like today's steam plant, about 5 MW |
| `centrifuge` | enrichment plant | III | Uranium region |
| `nuclear-reactor`, `heat-exchanger`, `steam-turbine` | nuclear plant | III | One composite with hidden parts, like the hub |
| `lab` | university, research institute | II, III | Jobs for engineers and scientists |
| `roboport` | CC and hub (exist), robotics centre | I–III | |
| `artillery-turret` | artillery fortress | III | |
| `rocket-silo` | Space Program site | III | Victory project |
| `locomotive`, `cargo-wagon`, `train-stop` | trains and stations | II | Rails study |
| `container` | project site, trade port depot | I | |
| Space Age `foundry`, `electromagnetic-plant`, `cryogenic-plant` | graphics for steel works, chip fab, chemical works | II, III | Only when Space Age is loaded; base-only gets tinted clones |

Districts are `assembling-machine` prototypes. `AssemblingMachinePrototype.fixed_recipe` pins a single-recipe
district, and `CraftingMachinePrototype.allowed_module_categories` limits the module slots to the hidden labor and
automation modules (section 5.5).

### 2.5 National projects

| Project | Unlocks | Deliveries to the site | Other conditions |
|---|---|---|---|
| Railway Charter | Age II | 300 steel, 200 circuits, 400 bricks, 150 rations | Research *Industrialisation* (30 advanced kits); 2 cities founded |
| Polytechnic University | Age III | 200 advanced circuits, 100 engines, 500 concrete, 200 household goods | Research *Modernisation* (40 industrial kits); 40 engineers employed |
| Space Program | Victory | 20 rocket parts (each 5 processing units, 5 LDS, 5 rocket fuel) and 1 satellite | Age III; the silo survives a 3-minute countdown |

The vanilla rocket needs 100 parts of 10 processing units, 10 LDS and 10 rocket fuel each. That is fifty times too
much for a match, so the RTS part is authored.

**Site mechanics.** A site is a building of kind `project` with a large inventory and its own train stop or hub.
Every 60 ticks the script reads the delivered counts, consumes them as progress and draws a progress bar with
`rendering`. When everything is delivered, a 60–90 s build countdown runs. An enemy that razes the site destroys half
of the goods delivered so far. A project is a visible, raidable bet, and the map shows every nation's site.

### 2.6 Space Age content

The economy runs on base content, and Space Age only swaps graphics, as it does for units today. The data shows the
foundry, electromagnetic plant, cryogenic plant and recycler have no entity surface conditions. Only their vanilla
*recipes* do, along with the quantum processor, turbo belts and a few others. Our own building recipes would make
them buildable on Nauvis. Lava for the foundry's molten metal would need lava tiles in a "volcanic region". That is
possible but not worth a base-only gap. Recommendation: no Space Age-only good in any core chain.

## 3. Why cities must cooperate

### 3.1 Uneven geography

| Region type | Resources | Frequency | Natural city |
|---|---|---|---|
| Ore valley | iron, copper, coal, stone | common | mining town |
| Oil field | crude oil, coal, sometimes water | at least one within each nation's reach | oil and chemical town |
| Lakeland | water, fish, fertile plains | common near lakes | farming town, concrete works, capital |
| Uranium | uranium ore | 1–2 per map, in contested ground | fortified outpost |
| Rare deposit | one rare resource (section 3.7) | 4–8 per map | outpost |

The world study decides placement. This study needs one oil field inside each nation's reach, uranium only on
contested ground, and at least one region per nation that lacks ore, so the capital must import.

### 3.2 A chain too large for one city

The Age II assault walker, from ground to front:

1. **Extraction.** Iron and copper ore and coal in the mining town; crude oil in the oil town.
2. **Refining.** Plates and steel in the mining town; plastic and sulfur in the oil town's refinery complex.
3. **Intermediates.** Circuits from the mining town's plates, made in the industrial city; gears and pipes.
4. **Components.** Engines (steel, gear, pipes) and advanced circuits (circuits, plastic, cable).
5. **Assembly.** The kit in the capital's arsenal: 2 engines, 10 steel, 4 advanced circuits, 20 iron.
6. **Sustainment.** Munitions (piercing rounds and explosives) to the front depots, or the walker fights at reduced
   strength (section 6).

No single stage is hard. The difficulty is that stages 1, 2 and 3 sit in three places, and every link is a train or
a hauler line that an enemy can cut.

### 3.3 Four pressures that split production

1. **Resources.** From Age II on, no region has every raw input.
2. **Labor.** Housing and food cap a city's workforce. A full Age II chain for one assault walker per minute needs
   about 250 workers and 40 engineers. A mid-game city has 150–400 residents.
3. **Land and power.** A city's catchment (assumed radius about 48 tiles, set by the cities study) holds about 12–20
   districts plus housing.
4. **Specialisation.** A city running 3 or more districts of one family (metallurgy, chemistry, electronics,
   military) earns a *tradition* bonus of +15 % speed for that family. The bonus rides on the labor module (section
   5.5). Concentrating a family in one city beats copying it everywhere.

### 3.4 Complexity budget: districts and hand-built lines

A **district** is one entity: a 5×5 to 9×9 assembling machine with a fixed recipe or 2–4 recipes. It has no
inserters. Today's network pull in `production.lua` fills its input from the city's logistic network, and the
factory hand-off moves its output back. A district carries jobs, upkeep and a family tag in `balance.lua`.

| District | Age | Compressed recipe (per craft) | Replaces |
|---|---|---|---|
| Steel works | II | 10 iron ore, 1 coal: 4 steel, 12 s | 4 smelters, 2 steel smelters, belts |
| Electronics plant | II | 2 iron, 3 copper: 2 circuits, 4 s | cable and circuit machines |
| Refinery complex | II | 100 crude (fluid), 2 coal: 4 plastic, 2 sulfur, 6 s | refinery and 2 chemical plants |
| Chemical works | II | sulfur, iron, water: acid, explosives or batteries | chemical plants |
| Engine works | II | 2 steel, 2 iron: 1 engine, 8 s | gear, pipe and engine assemblers |
| Concrete works | II | 5 bricks, 1 iron ore, water: 10 concrete | assembler and pump |
| Chip fab | III | 10 circuits, 2 advanced circuits, acid: 2 processing units | assemblers and acid line |
| Aerospace plant | III | steel, copper, plastic: LDS; or engines, batteries: robot frames | assemblers |

The numbers are first guesses for the balance pass. Only the structure matters here.

**Hand-built lines** are today's extractor, belt, smelter, inserter and stockpile layouts, plus generic factories.
A district needs about 18 workers for six machines' worth of output. The same output from hand-built machines needs
about 1–2 workers per machine, plus space, belts and layout skill. Districts are the easy path that the AI also takes.
Hand-built lines are the expert path, and they free workers for the army.

**Budget rules.**
1. No belt or inserter is ever required. Every district works from its city network.
2. Every recurring decision has an automation: recipes (section 3.6), labor (section 5.3), dispatch (rails study).
3. A city fits on one panel: inputs, outputs, labor, needs and its balance in money.
4. Alerts are grouped per city, such as "Kessel: steel short for 2 min", not per building.

### 3.5 What the player clicks and what runs itself

| Layer | The player decides | Runs by itself |
|---|---|---|
| Nation | Age-ups, research, tax level, labor priorities, trade, war | Treasury, market prices, rare-resource bonuses, debt stages |
| City | Site, districts and housing, keep / make / export per good, tradition family | Labor allocation, needs, growth, recipe choice for generic factories, robots |
| Link | Rail line and stations, train count, optional goods filter | Dispatch from exports to keeps, loading, unloading, rerouting |
| Building | Optional recipe override, pause | Staffing, inputs, output, power throttling |
| Army | Orders, depots, supply routes | Resupply, attrition, recruits drawn from the city |

### 3.6 City targets and trade policies

Today's hub policy has two numbers per item: *keep N* (import until N) and *export above N*. A city gets a third
one: **make N**, which means produce until N. Every 5 s the city walks its generic factories. An idle factory, or one
whose product is already above its make target, switches to the good with the largest shortfall that it can craft
and whose inputs the network holds. It switches with `production.set_recipe`, which already refuses locked recipes.
A district with a fixed recipe whose output is above its make target pauses (`disabled_by_script`). It then releases
its workers to other buildings and pays half upkeep.

Between cities, the rails study's dispatcher reads the same keep and export thresholds that haulers read today. That
is the provider and requester pattern of the LTN and Cybersyn mods. One policy language then drives haulers, trains,
the AI and the market (section 4).

### 3.7 Rare resources

A rare deposit is worked by a rare extractor. Its bonus holds while the deposit's output, a trickle of 1 item per
10 s, reaches the capital's network. The trickle makes the bonus a logistics problem and a raid target. Rise of
Nations simply grants it on ownership.

| Rare resource | Nation-wide bonus | Mechanism |
|---|---|---|
| Saltpetre | +25 % productivity for explosives and munitions | `LuaRecipe.productivity_bonus` on those recipes, per force |
| Quartz | +20 % productivity for circuits and advanced circuits | the same |
| Tungsten | +20 % productivity for steel | the same |
| Industrial diamonds | +15 % mining productivity | `LuaForce.mining_drill_productivity_bonus` |
| Rare earths | +10 % research speed and productivity | `LuaForce.laboratory_speed_modifier`, `laboratory_productivity_bonus` |
| Gold | +15 % tax income | script |

The probe showed that `LuaRecipe.productivity_bonus` applies even to a recipe with `allow_productivity = false`. The
bonus is capped by `RecipePrototype.maximum_productivity`, which defaults to 3.0. Research already applies force
modifiers as deltas (research notes, gotcha 4), and rare resources must use the same bookkeeping.

## 4. Money and markets

### 4.1 Three designs compared

| | A. No money (today) | B. Coin item | C. Treasury number plus physical trade |
|---|---|---|---|
| What money is | nothing | vanilla `coin` items in networks and trains | one number per nation in `storage` |
| Taxes | impossible | coins appear in housing and are hauled to the capital | computed per minute |
| Upkeep | goods only (ammo, food) | coins hauled to every building | deducted per minute |
| Trade with AI nations | barter at a trade port | coins move by train | priced by a shared market |
| Macro decisions | implicit | buried in logistics | explicit: tax, army size, imports |
| Raid targets | goods | coin trains | trade ports and the goods moving there |
| Build cost | none | high: coin logistics everywhere | low: script only |
| Main risk | no common unit, so AI trade and state choices stay vague | busywork and cluttered networks | money replacing production |

**Recommendation: C, with three guardrails.**
1. **Nothing is built with money.** Buildings, units, kits and projects cost goods only, as today.
2. **Money never creates goods in place.** A purchase arrives as goods at a trade port after a delay and must be
   shipped from there like anything else.
3. **Money pays for recurring costs:** upkeep, soldiers and imports. The treasury therefore measures how big a
   state and army the economy can carry.

Design A is the fallback if C fails playtests. It would keep goods-based upkeep (rations, munitions) and barter at
trade ports.

### 4.2 Income and expenses

The currency is the crown (cr). The base prices below are hand-set anchors in `balance.lua`, close to the
iron-equivalent costs the balance simulator uses (iron and copper 1, steel 3, circuit 4, explosives 2). Every good
without an anchor is derived at load time: `p0 = 1.1 × (sum of the ingredients' p0 + 0.1 × recipe seconds)`.

| Good | p0 | Good | p0 | Good | p0 |
|---|---|---|---|---|---|
| iron or copper ore | 0.4 | steel | 3.3 | advanced circuit | 18 |
| coal | 0.5 | circuit | 4 | household goods | 15 |
| stone | 0.3 | plastic | 3 | processing unit | 70 |
| iron or copper plate | 1 | sulfur | 2 | LDS | 40 |
| rations | 1.5 | engine | 14 | consumer electronics | 45 |

| Flow | Rule (first guess) |
|---|---|
| Tax | Per resident per minute: worker 0.2, engineer 0.6, scientist 1.2. Multiplied by the tax level (low 0.6, normal 1.0, high 1.4) and by happiness (0.5–1.2). |
| Exports | Market price × 0.9 for goods delivered to a trade port, up to the commerce cap |
| Imports | Market price × 1.1; the goods arrive at the trade port after 30 s |
| Building upkeep | Per minute: Age I building 1, Age II 4, Age III 8. A paused building pays half. |
| Army upkeep | 1 per supply point per minute |
| Transport upkeep | 2 per locomotive per minute, 1 per 100 rail tiles per minute |
| Debt interest | 5 % of the debt every 5 minutes |

Taxes from happy, high-tier citizens and exports pay for districts and armies. The treasury is the bridge from the
economy to the army: a richer state can field more supply.

### 4.3 The world market

- A virtual world stock `S` per good starts at a reference `S0` of about an hour of world trade (steel 3000).
- Price `p = p0 × (S0 / S) ^ 0.6`, clamped to 0.4–3 × `p0`. Sales add to `S`, purchases remove from it, and a bulk
  trade is priced along the curve, so dumping 5000 coal earns less per unit.
- Every 60 s, `S` moves 5 % back towards `S0`. Optional events shift `S0` for a while ("a foreign war doubles
  explosives demand").
- Every nation, the AI included, trades on this market. An AI at war buys munitions and steel, and the player sees
  those prices climb. The market panel shows prices, 10-minute history and commerce cap use.

### 4.4 Trade ports and the commerce cap

Trade ports are 2–4 neutral sites at map edges, placed by the world study. They are captured like today's ruin: a
unit stands within 4 tiles for 10 s. Goods reach a port by train or hauler. Exports are sold and imports appear there.
The **commerce cap**, as in Rise of Nations, limits the money traded per minute to 300 cr, plus 150 per port held,
plus 25 % per *Commerce* research level (two levels). Ports are rich targets: holding two of them doubles a nation's
trade.

AI nations sell what lies above their export thresholds and buy their shortfalls. Direct deals between nations,
such as "500 steel for 1800 cr, delivered at your port", are a later diplomacy feature that reuses the same pricing.

### 4.5 Debt and bankruptcy

The treasury can go below zero down to a credit line of 10 minutes of gross income. Interest accrues on the debt.

| Stage | Trigger | Effect |
|---|---|---|
| 1. Deficit | Treasury below 0 | Imports blocked, the HUD balance turns red, interest accrues |
| 2. Unpaid wages | Below 0 for 60 s | Workers strike: every building drops one staffing step (−20 %). Barracks refuse kits with reason "unpaid". |
| 3. Unrest | Below 0 for 180 s, or below the credit line | Happiness −25, so residents emigrate. Unpaid units get no resupply and soon fight at −40 %. |

Recovery tools are selling stock, raising taxes, disbanding units and pausing districts. Each stage clears as soon as
the treasury is positive again. Bankruptcy hurts and is visible, but a player can recover from it, and it never
deletes buildings.

## 5. Labor and population

### 5.1 Residents and housing tiers

| Housing | Age | Residents | Resident type | Needs per 100 residents per minute |
|---|---|---|---|---|
| Tenement | I | 40 | workers | 4 rations |
| Apartment block | II | 100 | engineers if the city has a school and needs are met at 80 % or more; otherwise workers | 5 rations, 1 household goods |
| Modern apartments | III | 160 | scientists if the city has a university and needs are met; otherwise as an apartment block | 5 rations, 1 household goods, 0.5 consumer electronics |

This is Anno's mechanism: education is a building plus satisfied needs. A tier falls back one step when its needs
fail, so an engineer shortage traces straight back to a household goods shortage in the ledger.

- **Growth and decline.** A housing block gains 3 residents per minute while food is at 100 % and happiness at least
  50. Below 50 % food, the city loses 5 % of its residents per minute.
- **Needs.** Every 60 s the city removes its needs from its logistic network (`LuaLogisticNetwork.remove_item`). It
  records the consumption with `LuaFlowStatistics.on_flow`, so food shows in the vanilla production graph.
- **Happiness** runs from 0 to 100. Needs met and services raise it. High taxes, debt and enemy fire nearby lower it.
  It only drives growth and taxes, never machine speed. One knob per effect keeps the loops readable.
- **Founding a city** moves 40–60 settlers out of an existing city, so expansion costs people. A CC houses 120
  workers and a new town hall 40.

### 5.2 Jobs

| Building | Workers | Engineers | Scientists |
|---|---|---|---|
| Extractor, oil well | 3 | | |
| Smelter | 2 | | |
| Factory (generic) | 5 | | |
| Barracks | 6 | | |
| Lab (Age I) | 2 | | |
| Farm | 6 | | |
| Steel works | 16 | 2 | |
| Electronics plant, engine works | 12 | 4 | |
| Refinery complex | 10 | 6 | |
| Chemical works | 8 | 4 | |
| University | 4 | 6 | 10 |
| Chip fab | 6 | 8 | 4 |
| Nuclear plant | 4 | 10 | 4 |
| Turrets, walls, poles, stockpiles, rails | 0 | | |

A higher tier can fill a lower job: an engineer can work as a worker, and a scientist as either. A building's
**staffing** is its scarcest skill: the minimum of filled divided by required, over its job types. It is rounded down
to a 20 % step.

### 5.3 Allocation

Every 5 s, staggered so that one city runs every few ticks, each city fills jobs in the order of the nation's
**labor priorities**. The default order is military, power, food, extraction, metallurgy, chemistry, electronics,
research, services. The player reorders families, and can pin a single building to the top. When a building's step
changes, its labor module is swapped. Nothing else is written.

### 5.4 Soldiers come from the workforce

A finished kit drafts `supply` workers from the barracks' city. Today's barracks gate (`production.kit_gate`) gets a
third refusal reason next to "locked" and "supply": **"no recruits"**. A dead unit's workers are gone for good. A
disbanded unit returns them to its home city. Today's supply cap stays as the nation-wide limit. The new trade-off is
stark: 40 more supply in the field leaves the mining town at 80 % staffing and cuts iron by a fifth.

### 5.5 Staffing on vanilla machines (probe-verified)

`LuaEntity.crafting_speed` is read-only, so staffing must act through effects or by disabling the machine. The probe
(section 8.2) compared every option on vanilla assemblers. The recommended mapping:

| Staffing step | Hidden labor module in slot 1 | Machine speed | Power use |
|---|---|---|---|
| 100 % | none | 1.0 | 1.0 |
| 80 % | speed −0.2, consumption −0.2 | 0.8 | about 0.8 |
| 60 % | speed −0.4, consumption −0.4 | 0.600 (probe) | 0.613 (probe) |
| 40 % | speed −0.6, consumption −0.6 | 0.4 | about 0.4 |
| 20 % | speed −0.8, consumption −0.8 | 0.200 (probe: the engine clamps at −80 %) | about 0.2 |
| 0 % | `disabled_by_script = true`, `custom_status` "No workers" | 0 | close to 0 |

- **Why modules.** Output is smooth, nothing is written per tick, the tooltip shows the effect, and power scales.
  A `disabled_by_script` duty cycle is exact too (50 % output at 51.6 % power) but needs constant writes.
- **Why not beacons.** A hidden beacon gave identical numbers, but it reaches every machine in its radius,
  a neighbour's included. The per-building module is just as cheap.
- **Bonuses.** Tradition (+15 %) goes into the same module as positive speed, before the engine's −80 % floor.
- **Safety.** Districts get `module_slots = 2` and `allowed_module_categories = {"rts-labor", "rts-automation"}`.
  Labor modules have no recipe, and a player in the remote controller "can't move/change items".
- **Costs.** A module swap costs about 3 µs, only when a step changes; a `disabled_by_script` write about 0.26 µs.

### 5.6 Automation replaces labor (Age III)

Age III turns the vanilla module recipes (5 advanced circuits and 5 circuits, 15 s) into **automation kits**. When a
city's policy says "automate metallurgy", the script inserts kits from the city network into slot 2 of that family's
districts. Each kit cuts the building's job requirement by 30 %. This is the late-game answer to the labor cap, as in
W&R: robots and modules replace people, and the freed people become soldiers or scientists.

## 6. Upkeep, attrition and supply

### 6.1 Army supply

- **Munitions** are one item per age, made from that age's ammunition chain. Age I uses today's firearm magazine.
  Age II uses a crate of 2 piercing rounds and 1 explosives. Age III adds batteries for laser units.
- **Supply level.** Every unit has a supply level from 0 to 100, kept in `storage`. A unit within 32 tiles of a
  **depot** whose network holds munitions regains 25 points every 5 s. A depot is the CC, a hub, or a cheap field
  depot that the Commander can build. A refill costs 1 munition per 25 points × the unit's supply cost.
- **Drain.** A unit that hit or was hit in the last 5 s loses 5 points per 5 s; an idle one out of range loses 1.
- **Effect.** Below 25 points a unit deals 40 % less damage, and at 0 it deals 60 % less. As with Armor II/III, an
  `on_entity_damaged` handler heals the target by that share when the `cause` is unsupplied (1–3 µs per hit).

### 6.2 Attrition

A unit inside an enemy city's catchment (the cities study's territory map) with supply at 0 loses 1 % of its maximum
health every 5 s. This is Rise of Nations' attrition. Deep raids then need a field depot or a supply hauler behind
them. A lone raider can still hit an extractor and leave.

### 6.3 Supply lines

A depot is an ordinary policy endpoint, such as "keep 200 munitions", so haulers and trains serve it through the
normal dispatcher. A *supply train* is just a train on a route that ends at a depot. The arsenal city's munitions
output therefore sets how many fronts the nation can hold.

### 6.4 Infrastructure is the target

Rails, train stops, big poles, pipes, project sites and trade ports get the `raid` target type, so raiders deal 2.5×
damage to them. A destroyed rail leaves trains without a path. The rails study turns `on_train_changed_state` into an
alert such as "Line Ironford–Kessel cut at (x, y)". Construction robots rebuild ghosts inside hub or CC range. Outside
that range, the Commander or a repair train rebuilds them. Power lines between cities are the same: a cut line browns
out the city behind it. The ledger then shows the damage spreading: the mining town's exports stop at once, the
industrial city's buffers drain over a few minutes, and the capital's labs stall last.

## 7. Worked example: one nation, minutes 0 to 40

**Setup.** The numbers are illustrative starting points, not balance. **Aurora** is the capital, in lakeland with
small ore patches, fish and fertile plains. **Ironford** is a mining town in an ore valley 260 tiles north.
**Kessel** is an oil and industry town 220 tiles east of Aurora. Line L1 runs from Ironford to Kessel (200 tiles) and
line L2 from Kessel to Aurora (220 tiles), so Kessel is the junction. The AI nation Red lies to the west, and a trade
port sits on the south edge, a hauler run from Aurora.

| Time | Aurora | Ironford | Kessel | Nation |
|---|---|---|---|---|
| 0–6 | Today's opening; a farm and 2 tenements take the CC's 120 residents to 200 | | | Age I research |
| 6–10 | Sends 40 settlers | The Commander founds the town; 6 extractors, 8 smelters, steel | | Haulers carry plates home |
| 10–14 | Circuits and rations for the project | Steel and bricks for the project | | Railway Charter done at 14:00: Age II |
| 14–20 | Sends 60 settlers | Rail yard: 210 rails cost 210 steel | Founded; oil wells, refinery complex, water works | L1 and L2 laid |
| 20–26 | Apartment blocks and a school: engineers | Coal goes to the port through Aurora | Electronics plant, engine works, chemical works | Industrial kits flow to Aurora's labs |
| 26–32 | Labs stall at 31:00 | Red raiders cut L1 at a river bridge at 27:00 | Steel buffer runs out at 29:30; engines stop | Depot and turrets at the bridge; L1 repaired at 30:30 |
| 32–40 | Polytechnic University done at 33:00: Age III | Drafts 40 recruits: staffing 80 % | Assault walkers and munitions | Push for the contested uranium, taken at 38:00 |

**Flows at minute 30, per minute.**

| Good | Made in | Made | Shipped | Main uses |
|---|---|---|---|---|
| Iron plate | Ironford | 600 | 260 to Kessel, 100 to Aurora | steel, circuits, engines, kits |
| Copper plate | Ironford | 300 | 220 to Kessel | cable and circuits |
| Coal | Ironford | 300 | 80 to Kessel, 200 to the trade port | power, plastic, exports |
| Steel | Ironford | 60 | 30 to Kessel, 30 to Aurora | engines, kits, project |
| Plastic and sulfur | Kessel | 40 and 20, plus 30 sulfur imported | 10 plastic to Aurora | advanced circuits, household goods, explosives |
| Circuits | Kessel | 70 | 20 to Aurora | advanced circuits, kits |
| Engines | Kessel | 8 | 6 to Aurora | assault walkers, industrial kits, locomotives |
| Advanced circuits | Kessel | 10 | 10 to Aurora | industrial kits, the project |
| Household goods | Kessel | 3 | 3 to Aurora | engineers' needs |
| Rations | Aurora | 40 | 12 to Ironford, 10 to Kessel | residents |

L1 carries about 920 items per minute. A vanilla wagon (40 slots, so 4,000 plates) would need one train every few
minutes. The rails study should size the RTS wagon (8–10 slots) and train speed so that a busy line needs 2–3
trains, and each train is an asset worth guarding.

**Ledger at minute 30, in cr per minute.** The nation has 760 workers and 180 engineers, at normal tax and happiness.

| Income | | Expenses | |
|---|---|---|---|
| Taxes | +260 | Building upkeep (40 Age I, 24 Age II) | −136 |
| Exports (coal, steel) | +180 | Army (90 supply) | −90 |
| | | Imports (sulfur) | −66 |
| | | Locomotives and rails | −12 |
| **Net** | | | **+136** |

At 150 supply the net falls to +76. A lost trade port or a cut coal line pushes it below zero within minutes.

**The "aha" moments.**
1. Founding Ironford costs 40 of Aurora's 200 people. Expansion has a price paid in people.
2. The first industrial kit needs goods from all three cities. Science turns into logistics.
3. The cut at the bridge shows up first as an empty line in Ironford's ledger at 27:00, and as idle labs in Aurora
   at 31:00. The delay between the two is the lesson.
4. Red's war pushes coal to 2.5× its base price. Selling 1,000 coal pays for 40 more supply for about 20 minutes.
5. Drafting 40 recruits drops Ironford to 80 % staffing, and iron output falls by a fifth.
6. Assault walkers that outran their depot hit at 60 % strength. A field depot fed by a supply hauler fixes it.

## 8. Feasibility

### 8.1 API map

| Mechanic | API (2.0.77) | Evidence |
|---|---|---|
| Labor throttle | `ModulePrototype.effect` (speed, consumption), `CraftingMachinePrototype.module_slots`, `allowed_module_categories`, `LuaEntity.get_module_inventory`, `LuaInventory.insert` / `clear` | probe |
| Zero staffing | `LuaEntity.disabled_by_script` (RW), `LuaEntity.custom_status` (RW) | probe |
| Reading the effect | `LuaEntity.crafting_speed`, `speed_bonus`, `consumption_bonus`, `productivity_bonus` (all read-only) | probe |
| Effect floor | `Effect.speed` and `consumption` sum to at least −80 %; productivity to at least 0 | docs and probe |
| Nation-wide bonuses | `LuaRecipe.productivity_bonus` (RW per force, capped by `RecipePrototype.maximum_productivity`); `LuaForce.mining_drill_productivity_bonus`, `laboratory_speed_modifier`, `laboratory_productivity_bonus` | probe; docs, already used by `research.lua` |
| Not usable | `LuaSurface.global_effect` is per surface, so it cannot differ by nation on a shared surface. `LuaSurface.create_entities_from_blueprint_string` only works in simulations. | docs |
| Districts | `AssemblingMachinePrototype.fixed_recipe`, `production.set_recipe` (existing), `LuaEntity.recipe_locked` | docs, existing code |
| City stock and needs | `LuaSurface.find_logistic_network_by_position`, `LuaLogisticNetwork.get_item_count` / `get_contents` / `remove_item` / `insert` | existing code |
| Statistics | `LuaForce.get_item_production_statistics(surface)`, `LuaFlowStatistics.get_flow_count` / `on_flow` | probe (reads) and docs |
| Project sites | container prototypes, `LuaEntity.get_inventory`, `rendering.draw_text` / `draw_sprite` | existing patterns |
| Trains (rails study) | `LuaTrain.get_contents` / `insert` / `remove_item` / `get_schedule`, `LuaSchedule.add_record` / `set_records` / `add_interrupt` / `go_to_station`, `game.train_manager.get_train_stops` / `get_trains`, `LuaEntity.trains_limit`, `CargoWagonPrototype.inventory_size` | docs |
| Supply effects | `on_entity_damaged` (`cause`, `final_damage_amount`), with the existing filter union in `research.lua` | existing code (1–3 µs per hit) |

Per-city flows are not in the engine statistics, which are per force and per surface. The city ledger counts flows
in script at the points where goods already pass: network pull, hand-off, haulers, train loading, needs and the
market.

### 8.2 Probe results

The probe is in `build/scale-probe-economy/scale-probe-economy-mods/econ-probe/` and its log is
`build/scale-probe-economy/probe-server.log`. It is a standalone base-only mod. It builds 9 groups of 10 assemblers,
each group on its own electric network, runs a 1-second, 1-plate gear recipe for 3,600 ticks with inputs topped up,
then times the writes on 1,000 machines. Rerun it with:

```sh
tools/headless-run.sh 40 '\[econ\]' build/scale-probe-economy/scale-probe-economy-mods
```

| Group | Setup | Output vs baseline | Crafting speed | Power vs baseline |
|---|---|---|---|---|
| A | none | 1.000 (600 crafts) | 1.000 | 1.000 |
| B | 1 module: speed −0.4, consumption −0.4 | 0.600 | 0.600 | 0.613 |
| C | 2 modules: speed −0.5 each | 0.200 | 0.200 (clamped at −80 %) | 1.000 (no consumption effect) |
| D | `disabled_by_script` half of every second | 0.500 | 1.000 | 0.516 |
| E | hidden beacon with the −0.4 module | 0.600 | 0.600 | 0.613 |
| F | force recipe productivity +0.5, `allow_productivity = true` | 1.500 | 1.000 | 1.000 |
| G | force recipe productivity +0.5, `allow_productivity = false` | 1.500 | 1.000 | 1.000 |
| H | productivity module +0.2, `allow_productivity = true` | 1.200 | 1.000 | 1.000 |
| I | the same module on a recipe with `allow_productivity = false` (and +0.5 force bonus) | 1.500 | 1.000 | 1.000 (module ignored) |

| Operation on 1,000 machines | Time |
|---|---|
| Module swap (clear and insert) | 3.03 ms |
| 2,000 `disabled_by_script` writes | 0.52 ms |
| `products_finished` reads | 0.29 ms |
| `custom_status` writes | 0.93 ms |
| 1,000 `get_flow_count` reads | 1.05 ms |

**Findings.**
- Labor modules and labor beacons throttle exactly, and their consumption effect scales power with them.
- The −80 % floor holds, so zero staffing needs `disabled_by_script`. A disabled machine draws almost no power.
- Per-force recipe productivity ignores `allow_productivity`. A module's productivity respects it.
- `products_finished` counts productivity bonus products: group F reported 900 for 600 crafts' worth of time. Any
  counter built on it, such as the barracks kit count, includes bonus items.
- Side effect: `tools/headless-run.sh` names a run after its mods folder. The probe's first folder was `mods`, so it
  overwrote the generated `build/mods-server.log`, `mods-create.log` and `mods-headless.zip`. It is renamed now.

### 8.3 Script cost estimate

The estimate assumes 4 nations, 16 cities, about 1,000 economy buildings and 600 units.

| Job | Cadence | Estimated cost |
|---|---|---|
| Labor allocation | every city every 5 s, staggered | under 0.1 ms per city pass; 3 µs per changed module |
| Needs and growth | every city every 60 s | under 0.05 ms per city |
| Auto-recipe | every city every 5 s | about 0.1 ms per city |
| Market and treasury | every 60 s | under 0.1 ms |
| Project sites | every 60 ticks | under 0.01 ms |
| Supply and attrition | every unit every 5 s, in slices | about 1 ms per full sweep, under 0.01 ms per tick |
| Unsupplied damage | per hit | 1–3 µs |

The economy script averages well under 0.2 ms per tick. Trains, pathing and the entity count are the real UPS risks,
and they belong to the rails and world studies.

### 8.4 Risks

| Risk | Rating | Mitigation |
|---|---|---|
| The AI cannot play a deep economy | High | The player and the AI use the same automation: districts, targets, dispatch, labor priorities. The AI only sets about ten knobs from city archetype templates: mining town, oil town, industrial city, capital. |
| Player overload | High | Districts, defaults for every knob, a one-panel city ledger, alerts grouped per city, a tutorial scenario. GUI QA target: a new player reaches Age II by minute 18. |
| Feedback loops interact in surprising ways (labor, food, money, army) | Medium | One knob per effect; a headless economy simulation that logs every city's ledger per minute; all numbers in `balance.lua`. |
| UPS with trains and many entities | Medium | Owned by the rails and world studies; the economy script itself is cheap (section 8.3). |
| Match length grows from 15 to 40+ minutes | Medium | Keep the Skirmish mode; ages give natural pacing. |
| Fluids add pipe busywork | Low | Fluids stay inside one city; only items travel between cities. |
| Base-only and Space Age drift apart | Low | Space Age changes graphics only. |
| Script state across save and load | Low | Plain `storage` tables; `tools/saveload-check.sh` in every phase. |

## 9. Phased plan

### 9.1 Phase E1: cities that need each other (about 17 agent-days)

**Deliverables.** `balance.lua` tables for districts and goods; ten Age II districts with compressed recipes and
vanilla graphics; an age state per force, *Industrialisation* and the Railway Charter site; oil and water regions
(with the world study); city make targets and the auto-recipe; the city ledger panel; an AI that founds a second city
from an archetype template and reaches Age II.

**Acceptance tests.**
- In a headless two-city nation where only city B has oil, city A makes no advanced circuits until plastic arrives.
  After a hauler or train route starts, city A makes some within 3 minutes.
- The Railway Charter completes from delivered goods. Age II recipes then unlock for that force only.
- A factory whose make target is met switches to the next shortfall within 5 s.
- The normal AI reaches Age II by 20:00 in 4 of 5 seeds.
- A 1v3 game with 3 cities per nation holds 60 UPS, in both Space Age and base-only.

### 9.2 Phase E2: money and people (about 20 agent-days)

**Deliverables.** Treasury, taxes, upkeep, trade ports, the world market, the commerce cap and the debt stages;
housing tiers, needs, growth, schools and universities; labor allocation with labor modules, and recruits drafted
from the workforce; nation, city labor and market panels; an AI that trades and sets its tax level.

**Acceptance tests.**
- A district at 60 % staffing makes 0.60 ± 0.02 of full output, measured the probe's way. At 0 % it shows "No
  workers".
- A city whose rations stop loses residents within 2 minutes and its staffing falls. Restoring food recovers both.
- Selling 1,000 steel moves its price along the formula, and the price drifts back 5 % per minute.
- The debt stages trigger at 0, 60 and 180 s and clear on recovery.
- A barracks refuses a kit with "no recruits" when its city has no free workers.
- Treasury, market and labor state survive a save and load at minute 20.

### 9.3 Phase E3: Age III, war economy and AI (about 20 agent-days)

**Deliverables.** Age III districts and the nuclear plant composite; automation kits; rare resources with
nation-wide bonuses; munitions, depots, supply levels and attrition; raid targets on infrastructure; the Space Program
victory; an AI economy planner for city sites, age-up timing and trade.

**Acceptance tests.**
- In paired balance-simulator runs, unsupplied units deal 40 % less damage.
- Delivering saltpetre to the capital raises the force's explosives productivity by 0.25. Losing the deposit removes
  the bonus within 60 s.
- Cutting a rail line raises an alert, and the downstream city's ledger shows the shortfall.
- The normal AI reaches Age III by 40:00 in 3 of 5 seeds.
- A scripted player can win by Space Program in 60 minutes or less.
- 4 nations, 16 cities, 600 units and 40 trains hold 60 UPS.

The total is about 57 agent-days. It does not include the city, rail and world work of the sibling studies.

### 9.4 Interfaces with the sibling studies and existing code

- **Cities study.** A city record (id, centre, catchment, town hall, logistic networks), a territory lookup by chunk,
  and the rule that founding a city moves settlers.
- **Rails study.** A dispatcher that reads keep, make and export per city; the RTS wagon size; rail damage events;
  supply and armoured trains.
- **World study.** Region types within each nation's reach, uranium and rare deposits on contested ground, trade
  ports at the edges, and map sizes for 3–4 cities per nation.
- **Existing code to reuse.** `production.lua` (network pull, hand-off, `set_recipe`, the kit gate), `logistics.lua`
  (keep and export policies, haulers, alerts), `research.lua` (age technologies, delta-applied force modifiers),
  `supply.lua` (recruits, the supply cap) and `balance.lua` (all the new numbers).
