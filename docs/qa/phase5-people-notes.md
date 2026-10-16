# Phase 5 M2: people and labor (population.lua, labor.lua)

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age on unless noted. Agent: `m2-people`. Contract:
`docs/PHASE5-M2.md` (D2, D3; section 3 "population.lua / labor.lua"; section 4 "People"). Studies:
`docs/research/scale/deep-economy.md` sections 5 and 8.2, `docs/research/scale/territory-cities.md` sections 3.2-3.5.
Work copy: `build/p5m2-people/factorio-rts` (HEAD 22d2dd0 plus this package). Everything here is Nation mode only; a
Skirmish match runs exactly as before (section 7).

## 1. What a player sees

1. **Every city has residents.** The capital starts with 200, a new city with the 40 settlers its founding takes from
   the nearest own city that can spare them. The city panel shows residents and housing, growth per minute, happiness
   and power, one bar per need, the workforce (jobs filled, free workers, recruits), the draft and the labor priorities.
2. **Housing.** The capital's centre houses 200 and a City Center 40. A small house (3x3, 20 residents, 15 stone, 5 iron)
   and an apartment block (5x5, 80, Age II, town and up) add theirs on the land of the city they stand on. Both are in
   the build menu's Production tab with the food buildings.
3. **Needs.** A city eats 1 ration per 10 residents a minute; from town tier it also uses 1 household good per 25. The
   City Center's network holds them: its Keep policy asks for rations 50 and goods 20, so haulers bring them like any
   good. Rations come from a farm (5x5, 1 grain every 4 s with no input, 3/6/10 per city by tier) and a bakery (3x3, 2
   grain to 3 rations in 3 s), or a fishing hut (3x3, 6 rations a minute, next to water). Goods are a factory recipe (1
   iron, 2 copper cable, 1 stone brick to 2 goods, 4 s); the factory can also make bricks from stone. With Space Age,
   rations spoil after 15 minutes.
4. **Growth.** A city whose needs are all met at 90 % or more, with free housing and (town and up) power, grows by 4 %
   of its housing a minute (more when happy). Below 50 % rations it loses 3 % of its residents a minute and only half of
   its workers work. Tiers follow the residents: town from 100, city from 400; a city falls back a tier only after two
   minutes below 80 % of its threshold.
5. **Workers.** 60 % of the residents work. Every building with jobs takes its workers from the city whose land it
   stands on, in the order of the nation's labor priorities (military, power, food, extraction, metallurgy, chemistry,
   electronics, research, services; up/down buttons in the city panel) with pinned buildings first. A building with
   60 % of its workers runs at 60 % speed; one with none stops and shows "No workers". Selecting a staffed building shows
   a staffing box above the building page: "Staff 60 %: 7.2 of 12 workers, Ironford, Metallurgy" and a Pin button.
6. **Recruits.** A unit takes one resident per supply point from the barracks' city when its kit becomes a unit. The
   barracks waits with "No recruits" when the city has none: recruits are the unemployed workers plus the draft share
   (0/10/20/30/50 %, city panel) of the employed ones.

## 2. Files

| File | Status | What it does |
|---|---|---|
| `scripts/population.lua` | new | Residents, needs, growth, happiness, power check, tiers by population, housing, founding settlers, the building index by city, build rules (farm slots, water, apartments), the AI governor's people part, per-minute log |
| `scripts/labor.lua` | new | Jobs, families, priorities, pins, the staffing pass, labor modules and "No workers", recruits and the kit gate, release and disband, module safety on demolish and mining |
| `prototypes/people.lua` | new | Labor module category and modules, the labor slot on every staffed machine, grain/rations/goods, house, apartment, farm, bakery, fishing hut, the hidden power-demand probe, recipes |
| `locale/en/people.cfg`, `locale/ru/people.cfg` | new | 75 keys each, the same in both |
| `tools/probes/people_m2.lua` | new | Acceptance fixture (section 6.1) |
| `tools/probes/people_stress.lua` | new | 40 cities x 2,000 staffed buildings (section 6.2) |
| `tools/probes/people_gui.lua` | new | GUI probe: city panel, staffing box, recruits line, build menu (section 6.5) |

### Shared hunks (all marked `-- Phase 5 M2 people`)

| File | Line (work copy) | Hunk |
|---|---|---|
| `control.lua` | 53-56 | require `scripts.population`, `scripts.labor` after `scripts.ledgergui` |
| `data-updates.lua` | 16-18 | require `prototypes.people` last (after the districts: they get the labor slot) |
| `balance.lua` | 465-end | `balance.nation.people` (new table) and its buildings copied into `balance.buildings` |
| `scripts/cities.lua` | 50-52 | `cities.tier_rule` (population.lua sets "population") |
| `scripts/cities.lua` | 360-401 | `cities.check` only measures land networks under the population rule; new `cities.set_tier(c, tier, why)` (up and down, alert, signal) used by the M1 rule too |
| `scripts/production.lua` | 51-53 | `production.PRODUCER_KINDS` (farm, bakery, fishing hut are fed and emptied like factories) |
| `scripts/production.lua` | 90-95 | `production.recruit_gate`, `production.staffing` hooks |
| `scripts/production.lua` | 199 | `production.status(...).staffing` |
| `scripts/production.lua` | 472-480 | the recruit gate in `check_barracks` (refusal kept in `rec.surcharge_block`, reason "recruits") |
| `scripts/districts.lua` | 82-86 | `districts.staffing_factor` returns `production.staffing(entity)` |
| `scripts/citygui.lua` | 41-50, 110-274, 299, 338-350, 355, 490-498, 537-551, 591-602, 608, 619 | people section, priorities, draft drop-down, staffing box (see section 3.6) |
| `scripts/hud.lua` | 148-150 | `P4.NATION_ONLY`: houses, food buildings, goods and brick recipes |
| `scripts/hud.lua` | 268-269 | Production build tab: house, apartment, farm, bakery, fishing hut |
| `scripts/hud.lua` | 1352-1353 | the status line shows an entity's custom status ("No workers") |
| `scripts/hud.lua` | 1377-1379 | barracks block reason "recruits" |
| `scripts/ai/commander.lua` | 596 | `deps.population.ai_step(C, surface)` after `age_up.step` |
| `scripts/ai/hubs.lua` | 341, 381 | `C.want_haulers` adds `C.people_haulers` (a supply hauler per other city) |

hud.lua is not in this package's row of the contract table; the four hunks above are the smallest way to show the
new buildings, the "No workers" status and the "no recruits" reason. supply.lua needed no change.

## 3. Design as built

### 3.1 Residents, needs, growth (`scripts/population.lua`)

- **Records.** `storage.population[city_id]` is created on the `rts_city_founded` signal (every founding path goes through
  `cities.lua`'s registration): the capital with `start.capital`, a city-state (`archetype = "city_state"` or force
  `rts-neutral`) with `start.city_state`, a new city with the settlers `population.settle` moves from the nearest own
  city that keeps `min_pop` (20) after giving all 40, else from the largest; a city that got fewer than 20 starts with
  20. The founding signal is the hook the contract's "cities.found calls population.settle" asks for: no `cities.lua`
  hunk was needed. At its first growth pass a city gets its start stock in its market network (capital: 300 rations,
  100 goods; a new city: 40 rations), and its centre's hub policy keeps rations 50 and goods 20.
- **Needs** every 60 s per city (`needs_period`): due = residents / per (rations 10 from village, goods 25 from town) plus
  the carried fraction; `remove_item` on the centre's network; met = removed / due. The removal is negative flow in the
  force's item statistics (`on_flow`) and "used" in the city ledger (`districts.record`).
- **Growth pass** every 10 s per city, staggered by city id (`on_nth_tick(60)` in 10 slots). Per minute: growth =
  `growth` (4 %) x housing x mood while every current need is met at 90 %, there is free housing and (town and up)
  power; decline = 3 % of the residents below 50 % rations, 1 % without power at town and up, 10 % of the excess over
  the housing. Between 50 and 90 % nothing changes. The new residents never exceed the housing.
- **Happiness** 0..100 = 50 + 25 x rations (-1..+1 between 50 % and 100 % met) + 15 x goods (town and up) +/- 10 power
  (town and up) - 10 crowded - 25 during unrest + external moods (`population.set_mood(city_or_force, key, delta)`,
  for the treasury's tax and debt). mood = happiness / 75, at most 1.25: a fed village grows at 1.0, a fully supplied
  town at 1.25.
- **Hunger.** Below 50 % rations only `starving_work` (half) of the workforce works. Without it a starving city only
  lost 3 % of its residents a minute and its buildings kept running for minutes; with it the lowest-priority buildings
  stop within one staffing pass (acceptance "its lowest-priority buildings stop").
- **Power.** A hidden 1 kW consumer `rts-city-demand` (2 kJ buffer, 2 kW input) sits under every centre. It may draw
  twice its use, so its buffer stays full while the network meets at least half of the demand; a buffer below half full
  at the growth pass means no power (satisfaction under 50 %). With a 1 kW input any small brownout read as "no power",
  and the AI's Age II capitals lost 1 % a minute for good. It is recreated when the centre's force changes (capture).
- **Tiers.** Town from 100 residents, city from 400, taken at the next growth pass; down after 2 minutes below 80 % of
  the tier's threshold. `cities.set_tier` changes radius, territory source, alert ("X grew into a town" / "X shrank to a
  village") and emits `rts_city_tier`. M1's building-and-delivery rule is off in Nation mode (`cities.tier_rule`).

### 3.2 Housing and the food chain

- `rts-house` (3x3, 20) and `rts-apartment` (5x5, 80) are simple entities with an owner (no GUI, no power, no status)
  drawn with the vanilla market stall. They count for the city whose land they stand on (the index below).
- `rts-farm` (5x5; Space Age: agricultural tower graphics, base game: a tinted assembler), `rts-bakery` (3x3, the
  stone furnace drawn larger) and `rts-fishing-hut` (3x3, the market stall in blue) are assembling machines with fixed
  recipes and no electricity: their cost is labor (the study's 150 and 200 kW pushed the AI capitals into brownouts,
  which stop growth). `production.lua` treats their kinds as producers: inputs pulled from and outputs handed to
  their logistic network like a factory, never on Auto.
- Build rules (`buildings.on_build_check`, players' ghosts and robot builds, as territory.lua): a farm beyond the city's
  farm slots (3/6/10 by tier), a fishing hut with no water tile within 3 tiles of its edge, an apartment on village land
  are removed with a flying text and the item goes back to the pool. The AI respects the slots itself (its ghosts are
  script placements).
- Goods (factory, `rts-intermediates`): 1 iron + 2 cable + 1 brick -> 2 goods, 4 s. Bricks from stone at the factory
  (`rts-brick`, 2 stone -> 1 brick, 2 s) because the AI makes no bricks in Age I and the goods need one.
- Rations spoil after 15 minutes only when the data stage has `feature_flags["spoiling"]` (Space Age); the base game
  keeps them.

### 3.3 Labor (`scripts/labor.lua`)

- **Index.** population.lua keeps every house and every building with jobs indexed by the city of the land it stands
  on (`population.members(city)`, `population.city_of_building(un)`). New buildings are resolved when registered;
  buildings on land without a live city wait in a loose set that is re-resolved after territory and city signals; each
  staffing pass checks its own members and moves the ones whose land changed city.
- **Staffing pass** every 5 s per city (`on_nth_tick(15)` in 20 slots). The members with jobs are sorted: pinned first
  (pin order), then by the rank of their family in the nation's priorities, then by unit number. The workforce is handed
  out in that order; a building's step = floor(share x 5) / 5 and it consumes exactly step x jobs workers, so the
  fractions flow on to the next building. A step change is the only write: module swap (clear and insert one
  `rts-labor-NN`), or `disabled_by_script` plus `custom_status` {red, "No workers"}, or back to normal. Signal
  `rts_staffing_changed` {unit_number, step}.
- **Families** (`balance.nation.people.families`): military = barracks and the Munitions works; power = steam plant;
  food = farm, bakery, fishing hut; extraction = extractor, oil well; metallurgy = smelter and the Smelting, Steel,
  Engine and Rail works; chemistry = refinery, chemical plant, Petrochemical works; electronics = Circuit works,
  Electronics plant; research = lab, Science campus; services = factory, Construction works.
- **Machines without a module slot** (the steam plant, a burner generator) run at any step above 0.
- **Recruits.** `production.recruit_gate` (called after the research gate, before the surcharge) needs supply-cost
  recruits from the barracks' city: recruits = free workers + draft x employed workers, at most residents - 20. A refusal
  is kept in `rec.surcharge_block` with reason "recruits" (the HUD shows "No recruits: Walker waits (0 of 1)"); a kit
  that becomes a unit drafts its recruits (`production.on_spawned`) and the unit remembers its home city
  (`storage.labor.soldiers`). A dead unit's recruits are gone; `labor.release(city, n)` and `labor.disband(unit_number)`
  (returns the recruits to the home city, else the nearest own city, and removes the unit) give them back.
- **Module safety.** `buildings.demolish` is wrapped so a building's labor module is cleared before its contents are
  collected (the demolish refund collects `furnace_modules`, which is the crafter module inventory); a mined building's
  buffer loses its labor modules.

### 3.4 Prototype changes on existing buildings

Factory, barracks, smelter, extractor, lab, oil well, refinery, chemical plant and the ten districts get `module_slots =
1`, `allowed_module_categories = {"rts-labor"}`, `quality_affects_module_slots = false` and "speed" and "consumption"
added to their allowed effects. Nothing else fits the slot and no beacon exists, so a Skirmish building behaves as before
(the slot is empty; section 7 shows identical Skirmish runs).

### 3.5 AI governor (`population.ai_step`, every 5 s per AI commander, Nation mode; houses from 2:30, the rest from 5:00)

| Knob | Rule |
|---|---|
| Labor priorities | power, food, extraction, metallurgy, research, military, services, electronics, chemistry (`ai.priorities`) |
| Pins | the builder and workshop factories (the two lowest fixed ones), the works factory (Auto) and the first lab |
| Draft | once per city: economic 10 %, turtle 20 %, aggressive 30 % (`draft.doctrine`) |
| Needs | every city's keep: rations and goods for 2 minutes of need (at least 50 / 20); the capital exports both above keep + 50 when the nation has another city |
| Goods | capital make targets: goods = 2 minutes of the nation's need (at least 20), stone bricks 20 (the works factory on Auto makes them) |
| Food | farms at the capital: one per 150 residents of the nation (within its farm slots), a bakery per 2.5 farms (at least one), one order at a time |
| Goods works | a second factory on Auto at the capital (goods and bricks took the works factory's circuits) |
| Houses | in the fed city (rations at 50 % or more) whose housing is most short. Before 5:00: free housing below 20. From 5:00: housing below the residents its jobs need plus 80 for recruits (jobs / 0.6 + 80); the free-housing rule alone grew an AI capital to 1,077 residents by 59:00 and its goods ate the iron its rail depot needed. A spot within 24/40/56 tiles behind its centre on its own land; at most 3 pending, 10 s apart; a small construction job (batched up to 5 like belts); the Auto factories keep 3 houses in stock (make target) |
| Queue | houses, farms, bakeries and the goods works go to the front of the AI's construction queue |
| Supply haulers | one manual hauler from the capital to every other city (`C.people_haulers` raises `C.want_haulers` in ai/hubs.lua; an auto hauler is switched to the route) |

### 3.6 City panel and staffing box (`scripts/citygui.lua`)

- People section under the supply line: residents / housing (growth per minute; tooltip: free housing, grown, lost,
  drafted, moved), happiness and power, one progress bar per need (met %, need per minute), workforce line (jobs filled,
  free, recruits; yellow while jobs are unfilled, red while starving or in unrest), the draft drop-down and a Priorities
  toggle that lists the nine families with up/down buttons (own nation only).
- The "next tier" line follows the residents: "Next tier: City at 400 residents (263 now)".
- Staffing box: selecting an own building with jobs shows a one-line frame above the HUD's building page: staff %,
  workers of jobs, the city, the family and a Pin / Unpin button.
- The HUD's status line shows "No workers" for a building at 0 % (its custom status), and the barracks line says "No
  recruits: <unit> waits (have of need)".

## 4. Numbers (`balance.nation.people`) and where they differ from the contract

| Key | Value | Contract / study |
|---|---|---|
| `start` | capital 200, new city = the settlers moved (40), city-state 120 | capital 120 (study) |
| `housing` | capital centre 200, City Center 40 | capital 120, new city 40 |
| `start_stock` | capital 300 rations + 100 goods, new city 40 rations | not in the contract |
| `settlers`, `min_pop` | 40; a source city keeps 20 | 40 |
| `workforce` | 0.6 | 0.6 |
| `tiers`, `down_share`, `down_ticks` | 20 / 100 / 400; 80 %; 2 minutes | as the contract |
| `growth`, `grow_at`, `hold_at` | 4 % of the housing a minute; 90 %; 50 % | "+4 %/min" (of the residents in the study) |
| `starve`, `dark`, `homeless` | 3 %, 1 % of the residents; 10 % of the excess a minute | 3 %, 1 %; homeless not in the contract |
| `starving_work` | 0.5 | not in the contract |
| `mood_base`, `mood_max` | 75, 1.25 | "happiness drives growth" |
| `needs` | rations 1 per 10 from village, keep 50; goods 1 per 25 from town, keep 20; every 60 s | as the contract |
| `houses` | small house 20, apartment 80 (town and up, Age II) | as the contract |
| small house cost | 15 stone + 5 iron, 4 s | "stone brick + iron" |
| farm, bakery cost | farm 20 iron + 30 stone, 6 s; bakery 20 iron + 10 copper + 15 stone, 6 s | not in the contract |
| apartment cost | 30 bricks + 10 steel + 10 goods, 8 s | "brick + steel + goods" |
| farm, bakery, fishing hut | 1 grain / 4 s, slots 3/6/10; 2 grain -> 3 rations in 3 s; 6 rations a minute within 3 tiles of water; no electricity | as the contract (power not specified; the study had 150 / 200 kW) |
| goods | 1 iron + 2 cable + 1 brick -> 2 goods, 4 s; factory bricks 2 stone -> 1, 2 s | goods as the contract; factory bricks are new |
| `spoil_minutes` | 15 (Space Age only) | 15 |
| `jobs` | extractor 4, smelter 4, factory 12, barracks 12, lab 8, farm 6, bakery 6, fishing hut 4, district 16, steam plant 4, oil well 4, refinery 8, chemical plant 8 | as the contract (oil well, refinery, chemical plant, fishing hut added) |
| `priorities` | military, power, food, extraction, metallurgy, chemistry, electronics, research, services | as the contract |
| `steps`, `staffing_period` | 5 (20 %), 5 s | as the contract |
| `draft` | levels 0/10/20/30/50 %, default 20 %; AI economic 10, turtle 20, aggressive 30 | "draft by doctrine" |
| `ai` | see section 3.5; governor from 5:00 | "keep 2 minutes of need, farms/bakery per 150, houses when free housing < 20" |

Why the differences:

- **Capital 200, start stock, governor from 5:00.** With the contract's 120 residents (72 workers) the AI's Nation opening
  (3-4 factories, 2 labs, 11 extractors and smelters: 108 jobs at 5:00, 168 at 10:00) left its labs and factories
  empty: no technology by 6:00 and no Age II by 21:00 (run `p5p-ai1`, 22/39). With no food at the start every city
  starved at its first needs tick. A farm, bakery and houses built at 2:00 cost the aggressive AI a minute of its first
  iron. 200 residents, the start stock and a governor that starts at 5:00 keep the AI's early pace (section 6.4).
- **Growth of the housing.** A literal 4 % of the residents takes 23 minutes from 40 to 100, so "a fed city grows village
  -> town by 10:00 and -> city by 25:00" cannot pass. 4 % of the housing fills an empty city in 25 minutes and makes
  houses the lever: the fixture's city with 24 houses is a town at 3:01 and a city at 14:31.
- **Hunger.** Without `starving_work` a starving city's buildings ran for minutes; with it the lowest-priority ones stop
  at the next staffing pass.
- **Stone for the small house, factory bricks.** The AI mines stone but makes no bricks in Age I (the City charter made
  the same choice); the goods need a brick, so the factory can make one from stone.

## 5. API for the other packages

```
population.of(city_id) -> {pop, housing, workforce, free, employed, jobs, recruits, happiness, needs = {[item] =
  {need, met}}, power, growth, draft, tier, tier_progress, next_at, free_housing, unrest, starving, born, lost, drafted,
  settled}
population.add(city_id, n, why) / population.remove(city_id, n, why) -> n      clamped to [0, housing] / [0, residents]
population.settle(from_city, to_city, n) -> moved                               the source keeps min_pop
population.needs(city_id) -> {[item] = per_minute}
population.workforce(city_id), population.housing(city_id), population.total(force), population.get(city_id)
population.set_draft(city_id, share)                                            0..1
population.set_mood(city_id | force_name, key, delta)                           external happiness (nil/0 clears)
population.set_unrest(city_id, ticks)                                           no worker works meanwhile (capture)
population.members(city_id), population.city_of_building(unit_number), population.jobs_of(name, kind)
population.describe(city_id)                                                    one log line
labor.jobs(entity_name), labor.family(entity_name), labor.staffing(entity) -> 0 | 0.2 | ... | 1
labor.priorities(force) / labor.set_priorities(force, list) / labor.move_priority(force, family, -1 | 1)
labor.pin(entity, on) / labor.pinned(entity)
labor.recruit(city_id, n) -> ok, "no recruits" | "no city"; labor.recruits(city_id); labor.release(city_id, n)
labor.disband(unit_number) -> ok                                                recruits back home, unit removed
labor.set_penalty(force, steps, why)                                            every building `steps` steps lower
labor.city_stats(city_id) -> {workforce, jobs, employed, free, recruits, unfilled, buildings, stopped, partial, order}
signals: "rts_city_population" {city_id, pop, tier}, "rts_staffing_changed" {unit_number, step}
storage.population[city_id], storage.people (index, AI state), storage.labor ({[force] = {priorities, pins,
  next_pin, penalty}, steps, stats, soldiers, changes})
```

Notes for the sibling packages:

- **m2-war (capture).** `capture.flip` can call `population.remove(city, 0.3 * pop, "capture")` and
  `population.set_unrest(city, 60 * 60)`: during unrest the city's workforce is 0, so every building on its land stops
  with "No workers" and resumes at the first staffing pass after it ends (that is D4's "production resumes after
  60 s"). The city record keeps its id; the power probe under the centre is recreated for the new force at the next
  growth pass. Buildings keep their staffing steps through a force write. Troop trains that destroy and recreate units
  lose the units' home city (`labor.home_of`); keep `storage.labor.soldiers[old]` under the new unit number if that
  matters.
- **m2-treasury.** Taxes read `population.of(city).happiness` (0..100) and `.workforce`; tax level and debt stage 3 go
  through `population.set_mood(force, "tax" | "debt", delta)`; stage 2 (unpaid wages) is
  `labor.set_penalty(force, 1, "unpaid")`.
- **m2-world.** A city-state founded for `rts-neutral` (or with `archetype = "city_state"`) starts with 120 residents
  that neither eat nor grow.
- **m2-ai (wave B).** `population.ai_step` is the people part of the governor (section 3.5); `ai/governor.lua` can call
  it or take its rules over. The AI state is `storage.people.ai[force]`.

## 6. Tests

All runs on the work copy `build/p5m2-people/factorio-rts` (Space Age), 2048 world, 1v1 Nation unless noted.

### 6.1 Acceptance fixture (`tools/probes/people_m2.lua`)

```sh
KEEP_TREE=build/p5m2-people/factorio-rts EXTRA_LUA=tools/probes/people_m2.lua STOP_ON=RTS_PEOPLE_M2_DONE \
  DURATION_MIN=30 SEED=501 SPEED=8 tools/autotest-run.sh p5p-fix3 '{opponents = 1, difficulty = "normal",
  mode = "nation", world_size = 2048, enemy_brain = "ai"}' 2400
```

14/14, 0 Lua errors (`p5p-fix3`):

| Check | Result |
|---|---|
| founding_40 | capital 120 -> 80, the new city (260 tiles out) has 40 residents |
| steps | a pinned Circuit works at 80/60/40/20 %: crafting speed 0.800/0.600/0.400/0.200, module rts-labor-80/60/40/20, consumption -0.20/-0.40/-0.60/-0.80 |
| clamp_80 | a vanilla assembling machine 2 with two rts-labor-20 (-1.6): speed bonus -0.800, crafting speed 0.150 (0.75 x 0.2): the engine floor holds, as in the probe of deep-economy.md 8.2 |
| staffing_60 | 60 s on cable: A (100 %) 30.00 crafts, B (60 %) 18.00 crafts, ratio **0.600** (target 0.60 +- 0.02) |
| no_workers_0 | a lab without workers: disabled by script, custom status "No workers", entity status disabled_by_script |
| no_recruits | draft 0, 0.4 free workers: the walker kit stays in the barracks, block reason "recruits" |
| recruit_ok | draft 50 %: the kit deploys, residents 44.17 -> 43.17, drafted 1 |
| disband_release | `labor.disband` on that walker: home city 1, one recruit, residents 43.17 -> 44.17 |
| starve_residents | rations cut (network emptied, no more top-ups): residents 137.0 -> 131.2, first one lost 46 s after the cut |
| starve_stop | the lowest-priority running building (a factory) stopped 20 s after the cut; stopped buildings 0 -> 3 |
| starve_recover | food back: that factory runs again 20 s later, residents 131.2 -> 153.9 |
| growth_town | the fed city with 24 houses (housing 520) is a town at **3:01** match time (deadline 10:00) |
| growth_city | ... and a city at **14:31** (deadline 25:00) |

The same fixture with the base game only (`VARIANT=base`, `p5p-fix-base`): 14/14, 0 Lua errors (the farm is the tinted
assembler there; rations do not spoil).

### 6.2 Stress (`tools/probes/people_stress.lua`, PERF=1)

40 cities (20 per force) on a 112-tile grid, 2,110 staffed buildings (factories, labs, smelters, extractors: about 340
jobs a city), residents for 55-85 % of the jobs, a quarter of the cities changing their residents every 30 s: 488 step
changes in 5 minutes. Per-module handler time, ms per tick averaged per minute (`p5p-stress2`):

| Module | Minutes 1-6 |
|---|---|
| labor | 0.020, 0.021, 0.030, 0.039, 0.022, 0.023 |
| population | 0.0022, 0.0014, 0.0026, 0.0041, 0.0019, 0.0020 |
| cities | 0.0010, 0.0010, 0.0013, 0.0026, 0.0010, 0.0011 |
| **together** | **0.024 - 0.046** (target < 0.2) |

One staffing pass over all 40 cities takes 4.8-8.4 ms (profiler around `labor.step_city` for every city), spread
over 5 s; one growth pass of every city 0.6-0.9 ms, spread over 10 s. The minutes at 0.03-0.04 ran while five other
agents' servers shared the machine. Not part of this package but visible in the same run: `production.lua`'s network
pull costs 0.11-0.23 ms per tick with 2,110 producers (every 30 ticks over every building).

### 6.3 The normal AI, 1v1 Nation, seed 501, 21-minute AI autotest

```sh
KEEP_TREE=build/p5m2-people/factorio-rts DURATION_MIN=21 SEED=501 SPEED=8 tools/autotest-run.sh p5p-ai11 \
  '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 2400
```

How the calibration went (same seed; HEAD = the tree before this package, `p5p-base21`):

| Run | Change | Autotest | Age II player / AI | Notes |
|---|---|---|---|---|
| HEAD | - | 39/39 | 14:46 / 13:19 | |
| ai1 | contract numbers, capital 120, no start food | 22/39 | none / none | every city starved at its first needs tick; half the workforce idle |
| ai2 | start stock, job-driven houses | 34/39 | none / none | labs and factories (services) without workers |
| ai3 | capital 200, pins, AI priorities | 36/39 | 16:56 / none (charter 79 %) | farm, bakery, houses at 2:00 cost the aggressive AI its opening |
| ai4 | governor from 5:00 | 36/39 | 20:28 / 18:45 | mid-game at 67-80 % staffing |
| ai5 | houses from 2:30, front of the queue | 36/39 | after 21:00 / 16:08 | goods took the works factory's circuits: Industrialisation in 7.5 min |
| ai9 | goods works, house stock, power probe at 50 %, unpowered farms | 38/39 | 16:57 / 16:25 | only `cars_rts-player` (car window ends at 20:57, the run at 21:00); over 60 minutes (37/39) its capital grew to 1,077 residents and the aggressive AI never paid for a rail depot |
| ai10 | houses only by job need, from 2:30 | 36/39 | 17:34 / 17:03 | |
| ai11 (final) | free housing before 5:00, then jobs / 0.6 + 80; houses 15 stone + 5 iron, farm and bakery less iron | **38/39** | **17:30 / 16:34** | only `cars_rts-player` (21-minute cut-off) |

### 6.4 M1 Nation acceptance, 60 minutes, seed 501 (`p5p-m1acc2`, the final tree)

```sh
PERF=1 KEEP_TREE=build/p5m2-people/factorio-rts EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN=60 SEED=501 \
  SPEED=6 tools/autotest-run.sh p5p-m1acc2 '{opponents = 1, difficulty = "normal", mode = "nation",
  world_size = 2048, enemy_brain = "ai"}' 6000
```

| Criterion | rts-player (economic) | rts-ai-1 (aggressive) | HEAD (`m1i-a14`) |
|---|---|---|---|
| Autotest | **39/39**, both alive at 60:00, 0 Lua errors | | 39/39 |
| Town founded | 13:00, copper | 9:00, iron | 7:54 / 7:03 |
| Age II | 17:30 | 16:34 | 14:46 / 13:19 |
| First rail line open | 23:51 | 26:31 | 19:56 / 27:20 |
| Items moved by train | 8,508 | 12,271 (20,779 together, goal 20,000) | 27,822 |
| Rations | 100 % in every city every minute | 100 % | |
| Wall clock of minutes 56-60 at speed 1 | 60.004, 59.996, 60.006, 59.998, 60.112 s: 60 UPS | | |
| population.lua / labor.lua (PERF, last 5 minutes) | 0.0013-0.0014 / 0.0016-0.0019 ms per tick | | |

Per city (residents/housing, tier, rations/goods met, staffing = employed / jobs):

| City | 10:00 | 20:00 | 30:00 | 40:00 | 60:00 |
|---|---|---|---|---|---|
| player capital | 287/360 t2, 100/100 %, 100 % | 390/520 t2, 100/100 %, 90 % | 566/620 **t3**, 100 % | 617/620 t3, 100 % | 614/620 t3, 100 % |
| player town (13:00) | | 75/140 t1, 100 % | 102/140 t2, goods 0 % | 102/140 | 102/140 |
| AI capital | 255/360 t2, 100/100 %, 94 % | 442/520 **t3**, 97 % | 599/620 t3, 100 % | 591/700 t3, 100 % | 697/700 t3, 100 % |
| AI town (9:00) | 44/80 t1, 100 % | 93/140 t1, 100 % | 101/140 t2, goods 0 % | 101/140 | 101/140 |

Both capitals become cities (400+) around 20-30 minutes; the towns stop at 101-102 residents once they need goods
(section 9).

### 6.5 GUI (`tools/probes/people_gui.lua`, `tools/gui-run.sh`, Russian client, 1280x800)

The probe starts a Nation match, sets the capital to 60 residents (36 workers for more jobs than that), opens the
capital's panel with the priorities, dispatches a click on Military's down arrow and a draft change through the real
GUI events, selects a factory (staffing box 20 %), presses Pin through the box (100 %), then selects a barracks with a
kit and no recruits. 0 Lua errors; every step logged. Screenshots: `docs/qa/phase5-screenshots/people-panel.png`
(people section, needs bars, workforce, draft, priorities), `people-staff.png` and `people-pinned.png` (staffing box),
`people-recruits.png` ("Нет рекрутов: Шагоход ждёт (0 из 1)" on the barracks page), `people-buildmenu.png` (Production
tab with the five new buildings).

### 6.6 Save and load

`SAVE_MINUTE=12 SPEED=8 DURATION_MIN=30 SEED=501 tools/saveload-check.sh p5p-saveload2 '{..., mode = "nation", ...}'
120` with the final work copy: saved at minute 12 (both towns founded, staffing steps and modules, soldiers, pins, the AI
governor's plan keys), 0 errors before and after the load; the loaded match ran to minute 28 with the per-minute people
lines going on. An earlier copy saved at minute 10 (`p5p-saveload`) loaded and ran to minute 29, also with 0 errors.

### 6.7 M1 economy fixture

`EXTRA_LUA=tools/probes/economy_e1.lua STOP_ON=RTS_ECONOMY_E1_DONE DURATION_MIN=30 SEED=202` on the work copy
(`p5p-econ`, large arena, Nation): 18/18, 0 Lua errors (the capital's 120 workers staff the fixture's districts).

## 7. Skirmish unchanged

Same seed (99), the HEAD tree (`build/p5p-baseline`) against the work copy:

| Scenario | HEAD | Work copy | Lines compared (AI minute, checks, production) |
|---|---|---|---|
| legacy units (smoke) | 65/65 | 65/65 | 486 of 486 identical |
| 1v1 normal medium | 23/23 | 23/23 | 2,088 identical; 3 more lines logged after the stop marker |

In Skirmish no city exists, so population.lua and labor.lua never act; the only visible trace is the empty labor slot in
the staffed machines' GUI.

## 8. Gotchas

1. **An assembling machine without a recipe has no output slot.** Inserting a kit into a barracks with no recipe does
   nothing; the fixture sets the kit recipe first (the barracks has no workers, so it makes no more).
2. **`furnace_modules` is the crafter module inventory** (a deprecated alias of `crafter_modules`), so the demolish
   refund collects every assembler's and furnace's modules: labor.lua wraps `buildings.demolish` to drop the labor module
   first. Mining drills and labs have their own module inventories, which the refund does not collect.
3. **Data-stage localised strings take string parameters only**: `{"item-name.rts-labor", 60}` fails at load
   ("Value must be a string in property tree"); `tostring(60)` works.
4. **CraftingMachinePrototype `allowed_effects` defaults to none** (mining drills and labs default to all): the districts,
   refinery and chemical plant had `nil`, so the labor slot needs "speed" and "consumption" added explicitly.
5. **The AI's ghosts are script placements**, so the build checks (farm slots) never see them; the governor counts
   farm slots itself.
6. **Founding takes 40 residents from a capital that is still growing**: the AI's town at 7-8 minutes cut its capital's
   workforce by 24 just as its jobs grew fastest; the governor's houses from 2:30 are what lets it recover.

## 9. Open issues

- **Contract deviations** (section 4): accepted by the lead on 2026-10-16 (capital 200 / housing 200, start stock,
  growth of the housing, hunger, stone houses and factory bricks, unpowered farms and bakeries, the power probe's 50 %
  threshold); `docs/PHASE5-M2.md` §3 now states the as-built rules.
- **AI pace.** The normal AI reaches Age II 2.7-3.3 minutes later than at HEAD on seed 501 (16:34 / 17:30 against
  13:19 / 14:46), founds its town 2-5 minutes later and moves fewer items by train (20,779 against 27,822): houses,
  farms, a bakery and the goods works cost it plates and builder time, and its capital runs at 90-100 % staffing. The
  M1 acceptance still passes 39/39. The full governor (m2-ai, wave B) can do better: houses by forecast, towns making
  their own goods, apartments in Age II. Only seed 501 was measured.
- **Towns stay at 100 residents.** At town tier they need goods, and the capital exports goods only above its keep + 50,
  which it rarely holds; growth stops (no decline). The governor's goods target could include the towns' need.
- **No player-facing unit disband.** `labor.disband(unit_number)` and `labor.release` exist and are tested; neither the
  Delete key nor the division panel calls them (the division panel's Disband dissolves the group only).
- **Founding source.** The 40 settlers come from the nearest own city that can spare them, not from the city whose
  factory made the charter (the charter item does not remember its maker).
- **The AI builds small houses only** (apartments need bricks and Age II), and its farms stay at the capital.
- **hud.lua hunks** sit outside this package's contract row (section 2).
- **production.lua's network pull** is the expensive handler once a nation has thousands of producers
  (0.11-0.23 ms per tick at 2,110 in the stress run); not part of this package.

## 10. Sync into mods/

Procedure (after the lead's "sync open"): copy the own files (`scripts/population.lua`, `scripts/labor.lua`,
`prototypes/people.lua`, `locale/*/people.cfg`); merge every shared file with
`git merge-file -p --union <work copy> <HEAD 22d2dd0> <mods>` (HEAD is the base the work copy started from), re-read the
result, then run the smoke, this package's fixture and the economy fixture on `mods/`.

**Synced 2026-10-16** (after the lead's "sync open", onto `mods/` at 0abb79b plus the treasury and diplomacy syncs): every
shared file re-read and merged as above; the only lines replaced are this package's own (the M1 tier-up tail in
cities.lua, the next-tier lines and the poll condition in citygui.lua, `districts.staffing_factor`, the two
`C.want_haulers` lines in ai/hubs.lua, the Production tab line in hud.lua). Hunks in `mods/` (line numbers at the
sync): control.lua 54-57; data-updates.lua 16-18; balance.lua 465-591; cities.lua 50-52, 368-407; citygui.lua 44-53,
114-278, 303, 342-354, 359, 494-502, 552-566, 608-619, 625, 636; production.lua 51-53, 90-95, 199, 472-480; districts.lua
82-86; hud.lua 148-150, 268-269, 1386-1387, 1411-1413; ai/commander.lua 597; ai/hubs.lua 341, 381. Checks on `mods/`
right after the sync: smoke (legacy units, seed 99) 65/65, people fixture 14/14, economy fixture 18/18, 0 Lua errors.

Dry run on `build/p5p-premerge` (current `mods/` with the treasury and diplomacy packages already in, plus this
package): control.lua, balance.lua and hud.lua had adjacent insertions next to theirs (kept both), the other seven files
merged cleanly. Results on that tree: smoke 65/65, people fixture 14/14, economy fixture 18/18, 21-minute Nation AI
(seed 501) 41/43 with Age II at 16:22 / 17:20 and every city at 100 % rations (the two failures: `cars_<force>` at the
21-minute cut-off), 0 Lua errors. The treasury's `production.kit_gate` wrapper ("unpaid") and this package's
`production.recruit_gate` ("recruits") coexist.
