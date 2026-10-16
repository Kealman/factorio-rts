# Phase 5 M1, package E1: ages, districts, the Railway Charter, make targets and the city ledger

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`. Agent: `m1-economy`.
Contract: `docs/PHASE5-M1.md` (package row E1, section 3 "ages.lua / districts.lua / ledgergui.lua", section 4
"Economy"). Study: `docs/research/scale/deep-economy.md` sections 2, 3, 7 and 8. Everything here is Nation mode only;
a Skirmish match runs exactly as before (paired same-seed runs below are line-for-line identical). Round 2 (section 10)
answers the owner's constraint "the economy must be the only road to victory": Age II gives a decisive military
payoff, Age I armies get dearer as they grow, and districts are the efficient way to make Age II goods.

## 1. What a player sees

1. **Age I** is today's game. The research panel (T) gets *Industrialisation* (20 advanced kits) in Nation mode.
2. Once it is researched, the **age badge** (top, left of the HUD strip) and the **city ledger** (L, or a click on the
   badge) offer **Start the Railway Charter**. A 6x6 site appears next to the capital. Every second it takes up to 10
   of each good it still needs from the logistic network it stands in: 100 steel, 100 circuits, 100 gears, 150 stone.
   A progress bar and "Railway Charter 46 %" float over it for every force. Haulers and trains feed that network.
3. When everything is delivered a 20 s countdown runs, then the nation enters **Age II**: an alert and a chat line
   for the force, a line for its rivals, and the badge changes. Only that force gets the Age II recipes. A destroyed
   site loses half of its deliveries; starting it again resumes with the rest.
4. **Age II** opens the oil well, refinery, chemical plant, ten districts, engines, advanced circuits, plastic,
   sulfur, steel beams, concrete, the industrial science kit and four Age II technologies (tier 3 column in T). The
   build menu gets an icon tab (industrial kit) with the 13 Age II buildings, in Nation mode only.
5. **Make targets** per city (ledger: a number per good; or the city panel of `citygui.lua`, which writes the same
   table). A factory or district on **Auto** makes the good with the largest shortfall that its inputs allow; a met
   target switches it to the next shortfall on the next pass (measured 1.6 s). New factories and districts start on
   Auto in Nation mode; choosing a recipe or Pause in the building panel fixes it; the Auto button (refresh icon,
   highlighted while on) switches back.
6. **Oil travels as goods.** An oil well pumps crude into the logistic network it stands in as `rts-crude-oil` items
   (one item = 10 units). No pipe is ever needed, and crude, petroleum, plastic and sulfur move by hauler or train like
   plates. The ledger shows where a short good's missing input is made: "needs [plastic]: made in <city>".

## 2. Files

| File | Status | What it does |
|---|---|---|
| `prototypes/age2.lua` | new | Items (`rts-crude-oil`, `rts-petroleum`, `rts-steel-beam`, `rts-science-industrial`), recipe categories (`rts-age2` on the factory, `rts-oil`, `rts-chemistry`), `rts-pumpjack`, `rts-refinery`, `rts-chemical-plant`, Age II recipes (all disabled), the five age technologies, the lab's third kit, custom input `rts-ledger` (L); helpers for districts.lua |
| `prototypes/districts.lua` | new | The ten 5x5 districts (vanilla or Space Age machines scaled and tinted), one recipe category each, their compressed recipes, building items and recipes, and `rts-project-site` |
| `scripts/ages.lua` | new | `storage.ages`, ages, the Railway Charter site and its deliveries, Age II recipe unlock per force, alerts, rendering, `/rts-age` |
| `scripts/districts.lua` | new | Registry kinds, pumpjack drain, the city layer (cities.lua or a one-city shim), make targets, flow counters, ledger rows and hints, `staffing_factor` (M2 hook) |
| `scripts/ledgergui.lua` | new | The age badge and the city ledger panel |
| `scripts/ai/age_up.lua` | new | AI hooks: works factory on Auto, capital make targets per age, starting the Charter, districts in Age II |
| `locale/en/economy.cfg`, `locale/ru/economy.cfg` | new | 116 keys, the same in both |
| `tools/probes/economy_e1.lua` | new | Headless fixture (section 6) |
| `tools/probes/economy_gui.lua` | new | GUI probe with screenshots (section 6), including the factory tabs |
| `tools/probes/economy_gui_skirmish.lua` | new | GUI probe: the Skirmish factory page is unchanged (no tabs, no Age II recipes) |
| `tools/balance-sim/balancesim.lua`, `run.sh` | hunks | Age II army scenarios and the Bunker scenario on force `sim-age2`; `SIM_TREE` (section 10) |
| `scripts/ai/mix.lua` | 2 hunks | The Armoured car kind; its weight for a Nation-mode force in Age II |
| `balance.lua` | appended | `balance.nation.economy` (section 4); Age II buildings and the site copied into `balance.buildings` |
| `data-updates.lua` | +2 lines | Requires the two prototype files after `prototypes.research` |
| `control.lua` | +3 lines | `scripts.ages`, `scripts.districts`, `scripts.ledgergui` after `scripts.techgui` |
| `scripts/production.lua` | hunks | Districts as crafters, recipe modes, `set_auto` / `is_auto`, the auto-recipe pass, flow hook, the Armoured car kit, the army soft cap (`army_size`, `army_multiplier`, the surcharge) |
| `scripts/research.lua` | hunks | Nation-only technologies, age requirements (status "age", barracks gate reason "age", `is_unlocked`; Nation mode only), tier 3, `list_all`, `max_tier`, Age II lock label, the Age II Mk2 line in `research.apply`, the surcharge block in `block_of`, lab flow hook |
| `scripts/hud.lua` | hunks | Districts use the factory page, the Auto button, the Age II build tab (grows to two rows), the factory category tabs (Nation mode), Age II recipes hidden in Skirmish, surcharge and age block lines |
| `scripts/techgui.lua` | 1 line | One column per tier (3 in Nation mode) |
| `scripts/ai/commander.lua` | 3 hunks | Calls `age_up.step`; a factory on Auto is not managed as builder or workshop |
| `scripts/ai/tech.lua` | 3 hunks | Industrialisation first in Nation mode; industrial-kit technologies only with kits at hand; the tier cache covers both modes |
| `scripts/ai/autotest.lua` | 3 hunks | Nation minute line, `age2_<force>` and `districts_<force>` checks |

The shared-file line numbers are in the lead report (they move with every package's sync).

## 3. Design decisions

| Question | Decision | Why |
|---|---|---|
| Fluids | Items. A pumpjack's crude oil is drained into its network as `rts-crude-oil`; the refinery and chemical plant have no fluid boxes and run item recipes; petroleum is the item `rts-petroleum`. | The study keeps fluids inside one city; items go one step further: no pipes for the player or the AI, and crude oil can be hauled to the city that refines it. Vanilla plastic, sulfur, engines, advanced circuits and concrete are reused as items. |
| Water for sulfur and concrete | Dropped from the recipes. | Offshore pumps would need lakes in every city and a fluid network; the M1 chains do not need it. |
| District kind | `"district"`, not `"factory"`. | The AI's factory management walks `"factory"`; a district would be taken as a workshop. Production, the HUD and the ledger treat both as crafters. |
| What "no fixed recipe" means | `rec.recipe_mode`: `nil` = Auto in Nation mode, `"auto"`, `"fixed"`. A player or AI `set_recipe` (also Pause) fixes it. | The AI pauses factories on purpose; a paused machine must not start making targets. |
| Auto rules | See section 5. Hysteresis (resume below 90 % of a target), a craft that ends within 3 s finishes once, a still-short recipe keeps 30 s before a much larger shortfall (+25 % of target) takes over. | Without hysteresis a district at its target toggled every 5 s while a hauler drained it, dropping the craft in progress each time. |
| Charter goods | Age I goods only (steel, circuits, gears, stone). | The contract locks Age II recipes until Age II, so the Charter cannot ask for engines or advanced circuits. Numbers are in `balance.nation.economy.charter`. |
| Rails | The Rail works district makes vanilla `rail`, m1-rails' rail item (their factory recipe is `rts-rail`). | Coordinated with m1-rails. |
| Age II gating | Recipe enable flags per force (ages.lua) plus `research.AGE_REQUIRED` for technologies and units. | `production.set_recipe` already refuses disabled recipes; the HUD greys them out with "Age II (Railway Charter)". |
| Cities | `cities.lua` when loaded (`cities.of_entity`, `make_targets`, `set_make_target`, `for_force`, `display_name`); a shim before it (one city per force). | Contract; the shim is gone from the code path as soon as `scripts.cities` is in `package.loaded`. |

## 4. Balance tables (`balance.nation.economy`)

| Key | Value |
|---|---|
| `crude_per_item`, `pumpjack_period` | 10 fluid units per item, drained every 60 ticks |
| `auto_period`, `auto_dwell`, `auto_margin` | 60 ticks, 30 s, 0.25 (resume below 0.9 of a target and the 3 s finish rule are `production.AUTO_RESUME`, `AUTO_FINISH`) |
| `charter` | tech `rts-industrialisation`; required steel 100, circuits 100, gears 100, stone 150; 10 per item and second; 20 s countdown; razing loses 50 %; site 4000 hp |
| `techs` | Industrialisation (20 advanced kits, flag), Supply III (+15), Mining III (+25 %), Hauler capacity II (+10 slots), Attack IV (+15 %); the last four need Age II and 15-25 industrial kits |
| `buildings` | oil well 30 iron, 5 steel, 5 circuits (mining speed 0.5: 5 crude/s on a 100 % field, no power); refinery 60/15/10, 300 kW; chemical plant 30/5/5, 200 kW; each district 80 iron, 40 stone, 15 circuits (science campus +40 copper, 25 circuits; round 1 had 20 steel and no stone: the AI never had 20 steel at once), 400 kW, 2500 hp, 12 s |
| `recipes` | Age II intermediates (refinery: 4 crude -> 3 petroleum, 3 s; chemical plant: petroleum + coal -> 2 plastic, petroleum -> 2 sulfur; factory: engine = steel + gear + 2 iron, 6 s; advanced circuit = 2 circuits + 2 plastic + 3 cable, 6 s; 2 steel beams from 3 steel; 4 concrete from 4 bricks + 2 stone; 2 industrial kits from engine + advanced circuit + sulfur, 12 s) and 20 district recipes (about twice the output of the machines they replace, intermediate steps skipped) |
| `ai` | works factory at 300 s; capital targets Age I gears 20, circuits 30 (plus what the Charter still needs, at most 50 each, from the start of Industrialisation); Age II gears 20, circuits 40, steel 40, engines 10, steel beams 10 (engines and beams once the first district stands); districts steel works, engine works, rail works, 60 s apart; Armoured car weight 3; no Age I unit beyond 40 army units unless threatened |

The ten districts and their recipes:

| District | Graphics (Space Age / base) | Recipes |
|---|---|---|
| Smelting works | electric furnace | 10 ore -> 10 iron or copper plates (8 s); 10 stone -> 5 bricks |
| Steel works | foundry / steel furnace | 8 iron plates -> 4 steel (8 s); 8 iron ore + coal -> 4 steel (10 s) |
| Circuit works | electromagnetic plant / assembler 2 | 2 iron + 3 copper -> 2 circuits (3 s); 5 copper -> 10 cable |
| Electronics plant | assembler 3 | 2 circuits + 2 plastic + 2 copper -> advanced circuit (4 s) |
| Petrochemical works | oil refinery | 4 crude + coal -> 4 plastic + sulfur (4 s); 3 crude -> 3 sulfur |
| Engine works | centrifuge | 2 steel + 6 iron -> 2 engines (8 s) |
| Munitions works | assembler 2 | 10 iron -> 15 magazines; 4 coal + 2 iron -> 4 explosives |
| Rail works | assembler 1 | 4 steel + 2 stone -> 5 rails; 3 steel -> 3 steel beams |
| Construction works | cryogenic plant / chemical plant | 5 bricks + 2 stone -> 6 concrete; 8 bricks -> 10 walls |
| Science campus | lab | basic, advanced and industrial kits in batches of 3 / 3 / 6 |

## 5. API for the other packages

```
ages.is_nation(); ages.of(force) -> 1 | 2; ages.project(force) -> {name, site, required, delivered, state, ...}
ages.can_start(force) -> ok, reason; ages.start_project(force, position?) -> project | nil, reason
ages.set_age(force, age, why); ages.on_age_changed(fn(force, age)); ages.capital(force); ages.required()
storage.ages[force] = {age, project}; storage.nations[force].age is kept in step
districts.city_of(entity); districts.cities(force); districts.make_targets(city); districts.set_make_target(city, item, n)
districts.flows(city) -> {made, used} (last 60 s); districts.ledger(city); districts.hint(city, item)
districts.staffing_factor(entity) -> 1   (M2 labor hook)
production.set_recipe(target, recipe, {auto = true}?); production.set_auto(target, on); production.is_auto(rec)
production.auto_active / targets_of / on_flow   (hooks, set by districts.lua)
research.NATION_ONLY, research.AGE_REQUIRED, research.AGE_LOCKS, research.list_all(), research.max_tier()
```

Auto rules (`production.lua` `auto_choose`, every 60 ticks over every factory and district on Auto): shortfall of a
recipe = the largest `(target - stock) / target` over its products that have a target, stock = the machine's own
logistic network. 0. a met recipe whose craft ends within 3 s finishes it, once; 1. a still-short recipe is kept
while it can run, unless it ran 30 s and another feasible recipe is short by 0.25 more; 2. else the feasible recipe
with the largest shortfall (a recipe that is not running needs a shortfall of at least 0.1); 3. else a feasible recipe
that makes a missing ingredient of the most short one; 4. else a district with no target on any of its products runs
its first feasible recipe (built for its goods, it works without targets); everything else idles.

## 6. Tests

| Test | Command | Result |
|---|---|---|
| Data stage, Space Age and base only | map creation with the tree, `VARIANT` sa / base | both load, 0 errors |
| Economy fixture (world map, Nation 1v1) | `EXTRA_LUA=tools/probes/economy_e1.lua STOP_ON=RTS_ECONOMY_E1_DONE DURATION_MIN=30 SEED=202 tools/autotest-run.sh p5e4-fixture '{opponents = 1, difficulty = "normal", size = "large", enemy_brain = "ai", mode = "nation"}' 900` | 12/12 (section 7) |
| AI age-up, 5 seeds | `DURATION_MIN=21 SEED=<401..405> PERF=1 tools/autotest-run.sh p5e3-ai-s<seed> '{opponents = 1, difficulty = "normal", size = "large", enemy_brain = "ai", mode = "nation"}' 1800` | 10/10 AIs in Age II by 20:00 (section 7) |
| Skirmish unchanged | `KEEP_TREE=<tree before / after E1> SEED=11` 1v1 normal medium and the legacy units autotest, logs compared | identical (section 7) |
| Save / load in Nation mode | `EXTRA_LUA=tools/probes/economy_e1.lua DURATION_MIN=30 SEED=202 tools/saveload-check.sh p5e3-saveload '{..., mode = "nation"}' 200` | 0 errors before and after the load (section 7) |
| GUI | `tools/gui-run.sh build/p5e-gui 300 RTS_E1_GUI_DONE` with `tools/probes/economy_gui.lua` copied into the copy's `scripts/` and required from its `control.lua` | 8/8 on the world map, Skirmish probe 1/1; screenshots `build/shots-p5e-gui-nation/` (site, badge, districts at zoom 0.5 and 1, ledger, Age II build tab, district panel with Auto on and off, factory tabs) and `build/shots-p5e-gui-skirmish/` |

## 7. Results

All runs: 0 Lua errors, 0 "Unknown key", 0 missing locale keys.

**Economy fixture** (world map 1536, Nation 1v1, `scripts/cities.lua` loaded; the same 11 checks also pass under the
one-city shim on the 512 arena, Space Age and base only): 12/12.

| Check | Result |
|---|---|
| charter_age2 | everything delivered from the capital's network, 20 s countdown: Age II 34 s after the start |
| charter_force_only | enemy still Age I; petrochemical works and advanced circuit recipes enabled for the player only |
| charter_age_tech | Supply III "available" for the player, "age" for the enemy |
| switch_5s | gears 20 / explosives 30: gears first; switched to explosives 1.6 s after the gear stock reached 20 |
| oil_no_plastic_no_circuit | city A (capital): 0 advanced circuits and its factory never picked them in 60 s without plastic |
| oil_ledger_hint | A's ledger row for advanced circuits: "needs plastic: made in city 3" (city B) |
| oil_b_makes_plastic | city B: two oil wells, a petrochemical works on Auto: 40 plastic (its target), 10 sulfur |
| oil_route_circuit_3min | hauler route B -> A: plastic in A after 4.7 s, an advanced circuit after 11.8 s |

**AI age-up** (world map 1536, Nation 1v1, normal vs normal, economic (rts-player) vs aggressive (rts-ai-1) doctrine,
21-minute autotest, the shared tree after the rails sync, `build/p5e3-ai-s<seed>*`):

| Seed | rts-player: Industrialisation, Age II | rts-ai-1: Industrialisation, Age II | Districts (player / AI) |
|---|---|---|---|
| 401 | 11:14, **15:02** | 11:29, **14:11** | 3 / 3 |
| 402 | 10:08, **13:30** | 13:07, **16:03** | 3 / 1 |
| 403 | 9:49, **13:49** | 16:15, **19:03** | 3 / 2 |
| 404 | 10:26, **15:58** | 10:30, **13:55** | 3 / 3 |
| 405 | 9:58, **13:48** | 11:49, **14:33** | 3 / 3 |

10 of 10 AIs reached Age II by 20:00 (13:30-19:03); the Charter takes 2.7-5.5 minutes after Industrialisation. The
`age2_<force>` check passes in every seed; `districts_<force>` (2 districts within 5 minutes of Age II) too.
The run before the last AI change (the Charter stockpile started at minute 4, `build/p5e2-ai-s<seed>*`) gave 13:45 to
18:07 for the 8 AIs that kept their capital (two were destroyed before 20:00). On the 512 arena (seeds 301-305) 1v1
matches ended at 9-16 minutes, so the arena is not a fair place for this test.

Other autotest checks in these runs: `hub_rts-player` fails in 5 of 5 seeds since the rails sync (the economic AI's
haulers wait for coal: Nation-mode hauler fuel in `logistics.lua`; the same seeds passed 5 of 5 just before it; reported
to m1-rails), and `kinds_8min_rts-player` fails in seed 401 in both runs (the third unit kind came after 8:00). Every
other check passes.

**Skirmish unchanged.** The tree before and after E1 (both with the other M1 packages), same seed: 1v1 normal medium
23/23 and legacy units 65/65 in both, and the production, autotest and minute lines are identical (2147 and 329
lines).

**Performance** (world, 2 nations, PERF=1, per-minute averages over the five 21-minute runs): districts.lua mean
0.0012 ms/tick (max 0.0025), ages.lua mean 0.0005 (max 0.0023), ledgergui.lua below 0.0001, production.lua mean
0.025-0.08 (max 0.34 in the minutes of heaviest unit production; the module's time includes the `on_spawned` callbacks
of other modules, and the auto-recipe pass switched at most 17 times a minute). Each 21-minute run took 1268 s of wall
time for 1260 s of game time while other servers ran on the machine: 60 UPS.

**Save / load** (world, Nation): `tools/saveload-check.sh` with the fixture (saved at minute 3 after 12/12, loaded,
200 s on): no errors on either side, the Auto petrochemical works kept following its target after the load. A second
save taken while the Charter site was taking its deliveries (render objects in `storage.ages`) loaded cleanly and the
site finished the Charter after the load (Age II at 0:36).

## 8. Gotchas

1. **LuaEntity is userdata in 2.0.** `type(entity) == "table"` is false; test `entity.object_name == "LuaEntity"`.
2. **A recipe with several products needs an icon or a main product.** `main_product = ""` fails at load ("Key icon
   not found"); the first product is the main product here, the name comes from `recipe-name.*`.
3. **`set_recipe` drops the craft in progress.** Without the finish rule and the hysteresis an Auto district at its
   target lost a craft every time a hauler took its output.
4. **A take_screenshot renders at the end of the tick.** A GUI change in the same tick shows in the picture.
5. **Russian vanilla names the steel plate "Стальная балка"**, so the steel beam is "Стальной двутавр" in ru.
6. **`previous_recipe` of a furnace is `{name = LuaRecipePrototype, quality}`**, not a string.

## 9. Open issues

- The AI builds no oil chain in M1 (no oil well, refinery or petrochemical district); `world.oil_fields()` gives it
  the fields for M3. Its Age II districts are circuits, steel and the science campus.
- Labor: `districts.staffing_factor` is the M2 hook (hidden labor modules, study section 5.5).
- The ledger counts flows where the script moves goods (pull, hand-off, labs, the site, oil wells) and smelter crafts;
  extractors, belts and robots between buildings are not counted (stock shows them).
- Hard and easy AIs use the normal AI's age-up hooks unchanged; only normal was measured.
- In Nation mode the AI researches Industrialisation as soon as it can make advanced kits; the Phase 4 check
  `kinds_8min` failed for the economic AI in 1 of 5 seeds (third unit kind after 8:00).
- The AI builds no Bunker and makes no Armoured car before its first district; it caps its Age I army at 40 and
  saves for district items (balance.nation.economy.ai). The full economy planner is M3.
- The surcharge cannot be paid by a barracks outside every logistic network: its Age I kits wait once the army is
  beyond 20 (belt-fed barracks are rare in this RTS; the HUD shows the wait).

## 10. Round 2: Age II must beat walker spam (owner's constraint, 2026-10-16)

Owner's feedback after a real match: "the whole game is: build basic extraction fast and spam walkers; there is no
reason to build complex systems." The lead's constraint: the economy must be the only road to victory. In Nation mode:

| Lever | What it does | Where |
|---|---|---|
| **Age II Mk2 line** | Every unit of a force in Age II deals +25 % damage (unit ammo categories, turrets excluded) and takes 1/1.4 of the damage it is hit by (an armor share of 0.2857, healed back like Armor II/III): the mk2 numbers for every unit kind, the Armoured car included. Applied as deltas in `research.apply`, re-applied on the age-up. Armor I (mk2 walkers and heavies) waits for Age II in Nation mode, so no mk2 arrives before it. | `balance.nation.economy.age2_bonus`, `scripts/research.lua`, `scripts/ages.lua` |
| **Armoured car** | Age II unit (kind `car`, supply 3): 2 engines + 2 steel beams + 10 iron, 8 s. 800 hp, 30 % physical and impact resistance, armored tag (artillery's bonus), speed x1.6 of the walker, range 18, 12 damage every 12 ticks. A `unit` with the vanilla tank hull, so orders, divisions and the AI army drive it unchanged. Its kit unlocks at Age II, it pays no army surcharge, Skirmish never sees it. | `balance.units["rts-armoured-car"]`, `prototypes/age2.lua`, `production.KITS` |
| **Bunker** | Age II turret: the turret's gun on a 3x3 emplacement, 3000 hp, range 26 (walkers have 20), 2.4x the turret's damage per magazine, fed like the turret; 8 steel beams + 20 concrete + 20 iron. | `balance.nation.economy.buildings["rts-bunker"]`, `prototypes/age2.lua`, Age II build tab |
| **Army soft cap** | Every 10 army units beyond 20 make Age I kits 10 % dearer: when a kit becomes a unit, the barracks takes (multiplier - 1) of each kit ingredient, rounded up, from its logistic network; the kit waits while the network cannot pay (the barracks page says "Army surcharge +20 %: waiting for [iron]"). Haulers and the Commander do not count; Age II kits pay nothing. | `balance.nation.economy.army_softcap`, `production.army_multiplier`, `scripts/production.lua` |
| **Efficient districts** | District recipes give more per input than the hand-built machines: Age II goods at least 1.5x per raw plate (engines 2.0x, steel beams 2.7x, advanced circuits 3.3x, plastic 2.3x, sulfur 3.3x, concrete 2.4x, industrial kits 4.0x, rails 2.5x), Age I goods 1.2-1.5x, about twice the throughput. An Armoured car kit costs 28 raw plates through hand-built machines and 18.3 through districts. | `balance.nation.economy.recipes`, `district_efficiency` |
| **AI** | In Age II the Armoured car joins the barracks mix (weight 3); the capital's Age II targets are engines and steel beams (once the first district stands); its districts are steel works, engine works and rail works (beams). A Nation-mode AI makes no Age I unit beyond 40 army units unless a base threat is fresh, and while a district's item is not made it saves: no unit kits and no works-factory targets (at most 3 minutes at a stretch). District items need 80 iron, 40 stone and 15 circuits at once; between unit kits they never gathered. | `scripts/ai/mix.lua`, `scripts/ai/age_up.lua`, `balance.nation.economy.ai` |
| **Factory tabs** | The factory page in Nation mode has a tab row in its header (Buildings, Logistics, Intermediates, Science, Age II); each tab shows one category in the 28-button grid. Skirmish keeps one grid without tabs, and every recipe an age locks is hidden there. | `scripts/hud.lua` |

### Results

**Balance simulator** (`tools/balance-sim/run.sh`, 8 reps per scenario, Space Age and base only; the Age II side is
force `sim-age2` with the Age II Mk2 line; Age II goods priced at the hand-built line, so a district-made army costs
about a third less again):

| Scenario | Space Age | Base only |
|---|---|---|
| Armoured cars at **70 %** of the walkers' cost | Age II wins 8/8, 46 % health left | 8/8, 41 % |
| 60 % cars + 40 % walkers at 70 % | 8/8, 27 % | 8/8, 21 % |
| Age II walkers at equal cost (the Mk2 line alone) | 8/8, 51 % | 8/8, 51 % |
| Armoured cars at 50 % | walkers win 8/8 (not a mismatch) | walkers win 8/8 |
| Bunker with 30 magazines vs 8 walkers | Bunker survives 8/8, 54 % | 8/8, 50 % |

The Phase 4 counter scenarios keep their winners (they leave `nation_only` units out); their health-left averages
move between runs of identical code as before.

**Fixture** (`tools/probes/economy_e1.lua`, world map, Space Age and base only): 18/18. New checks:
`district_efficiency` (every Age II good at least 1.5x), `softcap_surcharge` (army 42: multiplier 1.2, a walker kit
took 2 iron and 1 copper), `softcap_wait` (no iron: the kit waits, reason "surcharge"), `softcap_resume`,
`car_needs_age2` (Age I: the car kit is held, reason "age") and `age2_military` (after the Charter the held kit deploys
an Armoured car; the player's walker damage modifier 0.25 and armor share 0.286, the enemy's 0).

**GUI** (`tools/gui-run.sh`, 8/8 checks): the Nation factory page shows the tabs; Buildings 19 buttons, Age II 16,
Intermediates 10. The Skirmish factory page has the same 26 buttons as before E1: no tab row and no Age II recipe
(`tools/probes/economy_gui_skirmish.lua`).

**AI with round 2** (world map, Nation 1v1, normal, 21 minutes, seeds 401-405, the final tree: `build/p5e14-ai-s<seed>*`):

| Seed | rts-player (economic): Age II, districts, first car | rts-ai-1 (aggressive): Age II, districts, first car |
|---|---|---|
| 401 | 16:19, 3, by 21:00 | 17:28, 3, by 21:00 |
| 402 | 14:03, 3, by 16:00 | 17:58, 2, none yet |
| 403 | 14:40, 3, by 19:00 | Age I at 22:00: under attack, iron at 0, Charter at 72 % |
| 404 | 15:55, 1, by 20:00 | 18:36, 2, none yet |
| 405 | 15:43, 2, by 20:00 | 17:01, 2, by 20:00 |

9 of 10 AIs reach Age II by 20:00 (14:03-18:36), each builds its districts in Age II, and armies stay near the 40-unit
cap instead of 60-100. AI tuning took four batches; the three changes that mattered: the
AI stops making Age I units beyond 40 (earlier runs had armies of 60-100 paying a surcharge on every kit and starving
everything else), it saves for a district item (80 plates at once never gathered between unit kits), and districts
cost stone instead of steel (the AI's network never held 20 steel: research kits and heavies took it all). Before
these changes the same seeds built no district at all. The Age I `produce` check now allows up to two idle minutes in
a row in Nation mode (surcharge waits, saving); the remaining failure is the collapsing side of seed 403.
`hub_rts-player` fails in every seed since the rails package's hauler fuel (reported to m1-rails);
`kinds_8min_rts-player` fails in seed 404 (third unit kind after 8:00).

**Skirmish unchanged**: 1v1 normal medium (23/23) and legacy units (65/65) at the same seed give the same production,
autotest and minute lines before and after round 2. Only the lines logged after the stop marker differ.
