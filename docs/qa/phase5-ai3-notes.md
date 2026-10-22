# Phase 5 M3, wave B: the full nation AI (ai/planner, council, controller, intel, difficulty)

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m3-ai`. Contract: `docs/PHASE5-M3.md` (D7,
§3 "ai/planner.lua, council.lua, controller.lua, intel.lua, difficulty.lua", §4 "AI (wave B)"). Study:
`docs/research/scale/war-ai-performance.md` §4. Inputs: `docs/qa/phase5-perf-notes.md` (scheduler, open issue 1),
`docs/qa/phase5-ai-notes.md` §6 (M2 AI open issues), the wave A notes of age3, air, war2, world3. Base: `mods/factorio-rts`
at 80bcdbe (tag m3-wave-a) with m3-integ's wave B work in the same tree. Everything here is Nation mode only; Skirmish
runs exactly as before.

(Sections 1 and 4-7 are filled in with the acceptance runs.)

## 2. Design as built

### 2.1 Layers and where they run

| Layer | File | Runs | Decides |
|---|---|---|---|
| Strategist | `ai/nation.lua` (M2) | commander slice 3, every 10 s | taxes, sales, contracts, war and peace (doctrine table), opportunity wars, the capital's garrison at war |
| Economic planner | `ai/planner.lua` (new) | slice 1, every 300 ticks; site scoring as the scheduler job `ai3_sites` | city sites (scored), the third and fourth city, the oil town and its pumpjacks, the rail trunk, the Age III road (research wants, make targets, purchases, rushes, the Space Program), rare extractors, automation |
| Governors | `ai/governor.lua` (M2), `ai/age_up.lua`, build order | slices 1-3 | per city: people, food, goods, defence, export routes; districts (now also the planner's), make targets (merged with the planner's and the council's) |
| Intelligence | `ai/intel.lua` (new) | slice 3; the scan is the scheduler job `ai3_intel` every difficulty `intel_age` | known cities, divisions, depots, planes, unit clusters by sight; fronts.STRENGTH for AI nations |
| War council | `ai/council.lua` (new) | slice 3 after the army, every difficulty `council` ticks | fronts -> holding divisions (25 % reserve), fort belts (front segments, else the approach to a threatened city), operations with phases and timeouts, the offensive limit, field targets, air (airfield, scout patrols, interceptors, bombers), artillery trains at sieges, hired garrisons and mercenaries |
| Division controllers | `ai/controller.lua` (new) | slice 3, 6 divisions per run in turn, each at most every 60 ticks | stance, retreat at force ratio < 1, resupply walk, planes home |
| Difficulty | `ai/difficulty.lua` (new) | at commander creation and doctrine/difficulty changes | the knobs of `balance.nation.ai3.difficulty` |

The army (`ai/army.lua`) keeps executing attacks, defence, relief and capture groups; the council observes and steers it
through hooks (`army.launch_ok`, `army.field_target`, `army.recall`, `C.army.held`).

### 2.2 Difficulty without cheats

`balance.nation.ai3.difficulty[level]`:

| Knob | easy | normal | hard |
|---|---|---|---|
| intel_age (scan period, s) | 60 | 30 | 10 |
| concurrent offensive operations | 1 | 2 | 4 |
| site candidates scored | 8 | 16 | 32 |
| A* state cap | 20,000 | 40,000 | 60,000 |
| build pace (ticks per construction job) | 360 | 180 | 120 |
| buildings in flight | 2 | 3 | 4 |
| micro | off | basic (retreat by ratio, resupply) | full |
| orders per minute per division | 2 | 6 | 12 |
| scheduler budget factor | 0.75 | 1 | 1.5 |
| city timing factor (expand) / cities | 1.3 / 3 | 1 / 4 | 0.8 / 4 |
| council period (ticks) | 240 | 120 | 60 |
| first attack factor | 1.5 | 1 | 0.8 |

Vision is honest at every level (sight checks only, never chart state); hard's Skirmish bonuses stay off in Nation mode
(`commander.NATION_NO_CHEATS`), and the M2 "+20 % tax for hard" goes (treasury.lua hunk H2, m3-integ).

### 2.3 Economic planner (`ai/planner.lua`)

- **Sites.** A scheduler job (`ai3_sites`, 40 units per candidate, every 3 minutes, at most the difficulty's `sites`
  kept) scores the world's city sites, the oil fields the nation may use (its home field and the contested centre) and
  the rare deposits: need-weighted region ore within 70 tiles (an ore the nation lacks counts double, coal 0.8, stone
  0.5), oil wells within 45 (the home field x1.5), rare deposits within 40, chokes within 120 that lie between us and a
  rival, ports within 150; minus the rail cost (tiles to the nearest own city / 100) and the exposure (rival capitals
  within 700 tiles). Sites closer than 150 tiles to any city or outside 180-700 tiles of the capital are not candidates.
  The role is the strongest part (oil, rare, fortress, trade, mining).
- **Cities.** The second city stays ai/towns.lua's mining town (`cities.ai_step`). The planner founds the third from
  9:00 (or once Industrialisation is researched) and the fourth from 18:00 (or Age II), times the difficulty's `expand`
  (x0.7 with a Territory victory), up to the difficulty's `cities` and `balance.nation.cities.limit` (4, capital
  included). The third is the **oil town**: its City Center stands where its 16-tile logistic area covers the most wells
  of the nation's home oil field (off every well's pumpjack footprint); from Age II pumpjacks on the covered wells put
  crude oil into its network. A site on ground not generated yet is requested (worldgen.request_area) and skipped.
- **Trunk.** Prim's minimum spanning tree over own cities from the capital; every city that rails.lua's own program
  (the capital - town line, and its retaken-line programs) does not serve gets a `rails.ai_program` of the planner's
  (`A.pay` = the capital's centre: H1), at most 3 lines building at once (the main program counts), stepped every 300
  ticks. Every edge carries plates and the Age III goods (`export_goods`), and every non-capital city exports those goods
  (auto haulers bring them before a line opens); the capital keeps the planner's targets of them.
- **Age III road.** Technologies first (`ai/tech.lua` tech.wants, preempting a running one; progress kept):
  Fortification at war (the council's urgent want), Electrification in Age II, then the council's (Aviation, Air Force),
  Geology for a rare deposit in reach. The industrial kit's parts (20 engines, advanced circuits, sulfur and 40 plastic)
  are capital make targets from Industrialisation on and while a wanted technology needs industrial kits; the planner
  buys what the nation cannot make from city-states at peace (an oil city-state sells plastic and sulfur), or at its port
  when that lies within 450 tiles of the capital (a far port's haulers take minutes: the first runs bought plastic at a
  port 966 tiles away and the strategist sold it back), at most 35 % of the balance above 1,200 per minute; purchases are
  not sold back (ai/nation.lua). From Age II the Electronics, Petrochemical and Construction works go into the age-up
  list right after the Steel works. The Space Program starts as soon as `age3.can_start`; the running stage's goods are
  make targets (and purchases: concrete, the plastic of its advanced circuits, half of them and half the steel when
  rich). A rush (sinks.rush) of the running project (the Railway Charter in Age I too) when the balance is above 2,200
  and 60 % is delivered, and of Electrification while it runs. In Age III the Age III districts follow, and the capital
  automates metallurgy, electronics and chemistry once it holds 4 automation kits. Rare extractors go on deposits inside
  own land within 15 tiles of a city.

### 2.4 War council (`ai/council.lua`)

- **Operations.** Every attack, defence, relief and harass group of ai/army.lua and ai/raids.lua becomes an operation
  (`council.operations`) with phases: capture (assemble -> advance -> siege at 90 tiles -> capture while the centre is
  subdued -> consolidate when the city is ours), raid (assemble -> advance -> strike), relief and defend (move ->
  engage), bomb (fly -> strike -> return); "return" when the group heads home, "done" when it is gone. A reinforcement
  group with the target of an operation under way joins it. Each phase has a timeout (`balance.nation.ai3.council.timeouts`)
  after which the groups are recalled (army.recall). New offensives (capture, siege, army raids; not raider harass) are
  held while the difficulty's `ops` run. A nation that has run no operation by 25:00 (at peace, Age II) pushes a
  city-state operation (army.lua relaxes the reach to 1.05 and the margin to 1.2 x the city-state's points).
- **Fronts.** A front segment (fronts.lua) with at least 4 enemy supply near it (intel) gets a holding division of 1.5 x
  that strength (6-16 units) from idle units, at most 75 % of them (the 25 % reserve); its units leave the army pool
  (C.army.held); the hold is released when the segment is gone or quiet for 5 minutes. A segment whose threat stays at
  or above 30 for 3 minutes gets a fort belt (belts.plan_front, AA turrets from Age II). Without any front segment (the
  lands do not touch, which is the usual case on 2048 worlds) a city with hostile strength of at least 6 known within
  250 tiles for 3 minutes gets a 64-tile belt across the approach (belts.plan). At most 2 belts.
- **Sieges.** A capture or siege reaching its siege phase deploys an artillery train (Military railways) at an own depot
  within 110 tiles of the target, in bombard stance.
- **Air.** Aviation in Age II at war or from 25:00; an airfield at the capital (its concrete and steel are make
  targets); 2 scout planes (the first barracks makes the kits) in an all-plane division patrolling the most threatened
  front segment, else 40 % of the way to the nearest rival capital; interceptors patrolling the capital when enemy planes
  were seen (Air Force); bombers flying a bomb operation at the target of a capture in its advance or siege phase.
- **Field targets, depots.** An attack with no city to take goes for the nearest known hostile division within 220 tiles
  (seen within two scans) before buildings; hubs and depots carry target penalty 150 (were 20, aggressive 0); damage to an
  own depot calls a relief group even on the capital's land.
- **Money.** A city under attack hires 8 garrison points (balance above 2,500, every 2 minutes); the capital attacked
  with fewer than 12 idle units hires mercenaries at the port.

### 2.5 Division controllers (`ai/controller.lua`)

Each AI division (owner "ai") at most every 60 ticks, 6 per run in turn: stance (attack -> advance, home -> screen,
holding -> hold); with micro basic or full an attacking group whose own supply x health against the hostile supply in
sight within 50 tiles falls below 1 is recalled ("retreat"); a division that is not attacking and is out of supply walks
to the nearest own depot when no enemy is within 40; an all-plane division whose planes average below 35 supply flies
home. Orders count against the difficulty's orders per minute.

### 2.6 Intelligence (`ai/intel.lua`)

A scheduler job (`ai3_intel`, 15 units per sight check) every difficulty `intel_age` (60/30/10 s): rival and city-state
cities (tier, defenders in 40 tiles, turrets in 30, garrison points), divisions, depots, planes, and unit clusters (64
tiles) of every other force, each by sight (an own entity within 30 tiles, an own scout plane within 64). Divisions,
clusters and planes are forgotten after 10 minutes unseen; cities and depots when their spot is seen without them.
`fronts.STRENGTH` reads intel for AI nations (installed in on_init and on_load, so a joining client has it too).

### 2.7 Resumable planners (`ai/planjob.lua`, helper sub-agent "m3ai-perf")

The layout planners are state machines over an explicit call stack (`planjob.define(name, phases)`, frames of plain
data): the start planning with its copper and coal passes, plan_line with its satellites and A* routes, forward hubs,
the mining town's site and line, the spot searches (find_spot, find_spot_in), the planning context (64x16 cells per
step). `planjob.sync` runs them to the end (Skirmish: byte-identical results); in Nation mode `planjob.submit` runs them as
scheduler jobs (kinds ai_start_plan, ai_layout_plan, ai_hub_plan, ai_town_plan, ai_find_spot) with one planning job per
commander at a time (C.planning: the job alone writes the tile sets; commander.run holds the build order meanwhile and the
whole economy slice while the start lines are planned). Units: 4 per A* expansion, 250 per hub slot candidate, 33 per
satellite candidate, 0.45 per grid tile, 40 per surface check (0.875 us per unit measured).

## 3. Hunks for other owners (sent to m3-integ, all applied in 3edd55b)

| # | File | Hunk | Why |
|---|---|---|---|
| H1 | `scripts/rails.lua` | `rails.AI_PAY = true`; `A.pay or A.anchor` pays depots, kits and rails in `ai_depot`, `rails.ai_program` (`ai_kits`, `ai_supplies`) | a trunk edge between two towns is paid from the capital (a town's network is nearly empty) |
| H2 | `scripts/treasury.lua` | the hard AI's +20 % tax is gone | D7: difficulty without cheats |
| H3 | `scripts/cities.lua` | `pick_site` skips and requests ungenerated candidates (worldgen); the run-time `require("scripts.worldgen")` hoisted to load time (it raised "Require can't be used outside of control.lua parsing" and ended every Nation match whose AI found no town site); `why == "pending"` from `towns.pick_site` is no try | 4096 worlds; a crash; the resumable town-site search |
| H4 | `scripts/rails.lua` `cargo_positions` | only this line's freight trains stand "ahead" of its construction crew | with several lines per nation a crew turned back for 20 minutes because another line's freight train waited within 20 tiles of its track (seed 801, rts-ai-3, line #3 stuck at 121/128) |
| H5 | `scripts/market.lua` `ai_buy` | goods in `balance.nation.market.ai.no_buy` (plates, ores) are never bought | the market AI bought 350-670 iron plates every few minutes for a 2,000-plate make target that only keeps the Smelting works on the town's ore |
| (asked) | `scripts/cities.lua` | `cities.TOWN_PENDING_OK = true` | ai/towns.lua runs the town-site search as a job only when cities.ai_step understands "pending" (synchronous until then) |
