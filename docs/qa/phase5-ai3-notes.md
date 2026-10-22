# Phase 5 M3, wave B: the full nation AI (ai/planner, council, controller, intel, difficulty)

Date: 2026-10-17 (design), 2026-10-22 (acceptance runs). Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m3-ai`. Contract: `docs/PHASE5-M3.md` (D7,
§3 "ai/planner.lua, council.lua, controller.lua, intel.lua, difficulty.lua", §4 "AI (wave B)"). Study:
`docs/research/scale/war-ai-performance.md` §4. Inputs: `docs/qa/phase5-perf-notes.md` (scheduler, open issue 1),
`docs/qa/phase5-ai-notes.md` §6 (M2 AI open issues), the wave A notes of age3, air, war2, world3. Base: `mods/factorio-rts`
at 80bcdbe (tag m3-wave-a) with m3-integ's wave B work in the same tree. Everything here is Nation mode only; Skirmish
runs exactly as before.

## 1. Verdict

**Partly met.** On the final tree 903a7b1, 4 normal AIs, seeds 801-805:

| Criterion | Result |
|---|---|
| Phased operations, 1 or more per nation | met: 20 of 20 nations |
| A fort belt built on a threatened approach | met: 5 of 5 seeds |
| Age III by 40:00 in 3 or more of 5 seeds | met: 3 of 5 (batch G, the same AI on df6736c's base: 4 of 5) |
| Wars and peaces as in M2 | met: every seed |
| 0 errors | met |
| AI time 0.5 ms or less per tick per nation on average | met: 0.03 |
| Every nation's 3 cities linked by rail by 35:00 | **not met**: 8 of 20 nations (batch G: 12 of 20) |
| Air patrols fly | **not met**: 3 of 5 seeds (batch G: 5 of 5) |
| No AI tick over 3 ms | **not met**: 10 of 72,180 ticks, worst 21.9 ms |
| Hard beats normal in 7 or more of 10 1v1 matches | **not met**: 5 of 10 |

Regressions:

- **Skirmish:** byte-identical, smoke 65/65.
- **M1 seed 501:** 51/53. It moves between 51 and 53 from run to run; HEAD without this tuning also gave 52/53.
- **M2 seeds 701-705:** trade, war, peace and capture pass. Starving fails in 701 and 702.

Section 6 lists the causes and the next steps.

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
| city-state operations: from (x `city_state_from`) / margin (x the city-state's points) | 1.3 / 1.8 | 1 / 1.5 | 0.75 / 1.6 |
| goods works at the capital | people.ai rule (1, a 2nd when a town stalls) | same | one per 12 goods/min of need, at most 4 |

Vision is honest at every level (sight checks only, never chart state); hard's Skirmish bonuses stay off in Nation mode
(`commander.NATION_NO_CHEATS`), and the M2 "+20 % tax for hard" goes (treasury.lua hunk H2, m3-integ). The goods works
are a planning rule, not a resource: from tier 3 every AI capital ran short of goods (0-40 % met, 62-70 % happy, no
growth) and the market AI imported them at 15-17 cr a piece in minutes of 380-500 cr, which took the balance below the
tax hysteresis' `enter` (1,500) and held a high tax until 2,100. Hard's governor plans one goods works per 12 goods a
minute of need (`C.cfg.goods_per_works`, at most 4), its second and further works fixed on the goods recipe (in auto
mode three works made the capital's other targets and its goods stayed at 0 %); normal keeps the M2 rule and buys. (Tried and dropped: an import
reserve of 2,200 for hard kept its tax normal but left its capital at 0 % goods; batch B, section 4.)

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
  included). (Tried and dropped: the City Center at the front of the construction queue; behind 100 build-order jobs a
  site planned at 7:30 was built at 15:46, but in front of them the new town's farm, turrets and houses held up the
  capital's copper smelters by 2 minutes and M1 seed 501's Age II by 5. Also dropped: the third city from 7:00 and
  Industrialisation and Railways wanted once it is under way; the aggressive AI's capital then ran out of copper in Age
  I and its town line never got its second depot in M1 seed 501, and no nation linked its cities earlier.) A trunk edge takes no depot kit while rails.lua's own capital-town line still waits
  for its depots (both are paid from the capital's plates; in M1 seed 501 the aggressive AI's town line stayed at one
  depot for 53 minutes while its oil-town edge crafted its own). The third is the **oil town**: its City Center stands where its 16-tile logistic area covers the most wells
  of the nation's home oil field (off every well's pumpjack footprint); from Age II pumpjacks on the covered wells put
  crude oil into its network. A site on ground not generated yet is requested (worldgen.request_area) and skipped.
- **Trunk.** Prim's minimum spanning tree over own cities from the capital; every city that rails.lua's own program
  (the capital - town line, and its retaken-line programs) does not serve gets a `rails.ai_program` of the planner's
  (`A.pay` = the capital's centre: H1), at most 3 lines building at once (the main program counts), stepped every 300
  ticks. Every edge carries plates and the Age III goods (`export_goods`), and every non-capital city exports those goods
  (auto haulers bring them before a line opens); the capital keeps the planner's targets of them. While a trunk line
  waits for its depots or is being built and three cities are not linked yet, the barracks save steel and iron for it
  (`planner.saving_rail`, read by ai/age_up.lua as for rails.lua's own line). A survey that fails twice re-anchors the
  edge at the nearest linked city; an edge longer than 480 tiles waits. In Age I the trunk waits until the capital holds
  40 circuits (the Charter's).
- **Age III road.** Technologies first (`ai/tech.lua` tech.wants, preempting a running one; progress kept):
  Fortification at war (the council's urgent want), Electrification in Age II, then the council's (Aviation, Air Force),
  Geology for a rare deposit in reach. The industrial kit's parts (20 engines, advanced circuits, sulfur and 40 plastic)
  are capital make targets from Industrialisation on and while a wanted technology needs industrial kits; the planner
  buys what the nation cannot make from city-states at peace (an oil city-state sells plastic and sulfur), or at its port
  when that lies within 450 tiles of the capital (a far port's haulers take minutes: the first runs bought plastic at a
  port 966 tiles away and the strategist sold it back), at most 35 % of the balance above 1,200 per minute; purchases are
  not sold back (ai/nation.lua). From Age II the Electronics, Petrochemical and Construction works and a second
  Steel works go into the age-up list right after the first Steel works, and an Engines works once three cities are
  linked. The Space Program starts as soon as `age3.can_start`; the running stage's goods are
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
  held while the difficulty's `ops` run. A nation that has run no operation by 25:00 (x the difficulty's `cs_from`; at
  peace, Age II) pushes a city-state operation (army.lua relaxes the reach to 1.05 and the margin to 1.2 x the
  city-state's points); every further push (10 minutes apart) reaches 0.25 further, up to 2, and from the second one a
  rival division near the city-state no longer rules it out (a 100-unit army pushed four times without a target).
- **Fronts.** A front segment (fronts.lua) with at least 4 enemy supply near it (intel) gets a holding division of 1.5 x
  that strength (6-16 units) from idle units, at most 75 % of them (the 25 % reserve); its units leave the army pool
  (C.army.held); the hold is released when the segment is gone or quiet for 5 minutes. A segment whose threat stays at
  or above 30 for 3 minutes gets a fort belt (belts.plan_front). Without any front segment (the lands do not touch,
  which is the usual case on 2048 worlds) a city with hostile strength of at least 4 known within 250 tiles for 2
  minutes gets a 40-tile belt of walls and turrets across the approach (belts.plan), without AA turrets and field depot:
  every entry is paid from the city's network and the AI makes them as make targets only (64-tile plans with AA turrets
  and a depot waited 9-13 minutes or for ever in batch A). With no such city, a nation at war for 2 minutes fortifies
  its city nearest to a known city (else unit cluster) of a nation it is at war with, across the way to it: raids of 2-4
  units never made a sustained strength of 4. At most 2 belts.
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
| (H6, withdrawn) | `scripts/market.lua` `ai_buy` | a per-commander import reserve (`C.cfg.import_reserve`) | announced to m3-integ on 2026-10-22 and withdrawn the same hour: hard's capital ran out of goods without imports (section 2.2) |

## 4. Measurements

### 4.1 Commands

The runs use a snapshot of the tree (`build/m3ai-tools/mktree.sh <dir>` copies `mods/factorio-rts`) and
`build/m3ai-tools/lane.sh kind:seed:tag ...` (one run after the other, `TREE=<dir>`), at most 4 servers at a time:

```sh
# 4 normal AIs (kind n4): PERF=1, the ai3 checks of tools/probes/ai3_acceptance.lua
PERF=1 KEEP_TREE=<tree>/factorio-rts EXTRA_LUA=tools/probes/ai3_acceptance.lua DURATION_MIN=60 SEED=801 SPEED=10 \
  tools/autotest-run.sh m3ai-G-801 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
  enemy_brain = "ai"}' 5000
# 1v1 hard against normal (kind dif): tools/probes/ai3_difficulty.lua gives the player's AI the other level and logs
# "ai3 difficulty: ... winner" (score = wars.nation_score: pop + treasury/10 + land + supply) at 60:00; odd seeds: the
# rts-ai-1 AI is hard, even seeds: the player's
KEEP_TREE=<tree>/factorio-rts EXTRA_LUA=tools/probes/ai3_difficulty.lua DURATION_MIN=60 SEED=901 SPEED=10 \
  tools/autotest-run.sh m3ai-F-901 '{opponents = 1, difficulty = "hard", mode = "nation", world_size = 2048,
  enemy_brain = "ai"}' 5000
# M1 (kind m1): EXTRA_LUA=tools/probes/m1_acceptance.lua, 1 normal opponent, SPEED=6; M2 (kind m2):
# EXTRA_LUA=tools/probes/m2_acceptance.lua, 3 opponents, PERF=1
```

Skirmish: `tools/determinism-compare.sh` with `KEEP_TREE=<git archive HEAD> TREE_B=mods/factorio-rts WHAT=all`
(`{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}`, 10 minutes, seed 501) and the smoke
`tools/autotest-run.sh <name> '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240`.

### 4.2 The AI acceptance, 4 normal AIs, 60 minutes, 2048, seeds 801-805

Final tree **903a7b1** (this tuning on m3-integ's aaa8061: army upkeep 1.2, rail survey backoff), batch H:

| Seed | 3 cities linked by rail by 35:00 (player, ai-1, ai-2, ai-3) | phased operations per nation | air patrols ordered | fort belts built | first Age III | wars / ended / peaces | errors |
|---|---|---|---|---|---|---|---|
| 801 | 2 of 4 (39, 42, 32, 34) | 11, 16, 1, 1 | **0** | 4 | 34:00 | 2 / 1 / 1 | 0 |
| 802 | 3 of 4 (30, 47, 34, 31) | 3, 12, 1, 8 | **0** | 4 | 42:00 | 3 / 2 / 2 | 0 |
| 803 | 1 of 4 (35, -, 39, 50) | 6, 30, 5, 9 | 18 | 7 | 36:00 | 9 / 8 / 8 | 0 |
| 804 | 1 of 4 (43, 38, 27, 47) | 6, 31, 6, 12 | 32 | 8 | 38:00 | 8 / 6 / 6 | 0 |
| 805 | 1 of 4 (30, 45, 36, 39) | 10, 27, 7, 4 | 27 | 6 | 42:00 | 6 / 5 / 5 | 0 |

- Cities linked by rail by 35:00: **8 of 20 nations (fails)**. Every nation founds its third city (12:00-20:00) and
  has 3-8 cities at 60:00; most misses link at 36-50, and the aggressive rts-ai-1 misses in 5 of 5.
- Phased operations: 20 of 20 nations. Fort belts: 5 of 5 seeds. Wars and peaces: every seed. Errors: 0.
- Air patrols: **3 of 5 (fails)**. In 801 and 802, Aviation came at 41-48 and no airfield was finished by 60:00.
- Age III by 40:00: **3 of 5 (passes)**.
- AI time (PERF=1, all four nations together, means of 60 game minutes): 0.24-0.35 ms per tick, worst minute
  0.34-0.57 ms (0.06-0.14 ms per nation).

The same AI on df6736c's base, without m3-integ's three commits (batch G, tree7) did better:

| Seed | linked (player, ai-1, ai-2, ai-3) | air patrols | belts | first Age III |
|---|---|---|---|---|
| 801 | 2 of 4 (35, 42, 30, 37) | 11 | 4 | 35:00 |
| 802 | 2 of 4 (-, 44, 35, 32) | 4 | 7 | 34:00 |
| 803 | 2 of 4 (34, 58, 46, 33) | 15 | 8 | 37:00 |
| 804 | 4 of 4 (26, 35, 28, 34) | 17 | 4 | 37:00 |
| 805 | 2 of 4 (30, 39, 31, 44) | 25 | 6 | 42:00 |

That is 12 of 20 linked, air 5 of 5, belts 5 of 5, Age III 4 of 5. Two things may account for the gap: army upkeep
at 1.2 cr per supply point (20 % more) makes money tighter, and one run per seed is noisy (section 6, item 8).

### 4.3 How the batches moved

| Batch (tree) | What changed | linked by 35 | belts (seeds) | air (seeds) | Age III by 40 (seeds) | M1 seed 501 |
|---|---|---|---|---|---|---|
| A (df6736c) | the committed wave B AI | 11/20 | 2/5 | 4/5 | 2/5 | 53/53 |
| B (tree2), 3 seeds | trunk saving, third city from 7:00, sector belts 40 tiles from strength 4 without AA and depot, the second Steel works in the oil districts | 7/12 | 2/3 | 3/3 | 2/3 | - |
| C (tree3) | + City Centers first in the queue, Industrialisation and Railways wanted, belts at war towards the nearest enemy | 10/20 | 5/5 | 4/5 | 5/5 | 50/53 (Age II 22:50) |
| E (tree5), 4 seeds | - the queue change | 7/16 | 4/4 | 4/4 | 3/4 | 51/53 (ai-1's town line) |
| F (tree6), 4 seeds | + trunk edges wait for the town line's depots, push escalation, hard's goods works fixed on goods | 8/16 | 4/4 | 4/4 | 3/4 | 51/53 (ai-1's town line) |
| G (tree7) | - third city from 7:00, - Industrialisation and Railways wanted (committed as 903a7b1) | 12/20 | 5/5 | 5/5 | 4/5 | 51/53 (the player's town line blocked at a piece) |
| H (903a7b1 = G on aaa8061) | m3-integ's army upkeep 1.2, survey backoff, oil well ring | 8/20 | 5/5 | 3/5 | 3/5 | 51/53 (produce_rts-ai-1, train_items) |

### 4.4 Difficulty: hard against normal, 1v1, 2048, 60 minutes, seeds 901-910

| Seed | A (df6736c) | F (tree6: hard's goods works) |
|---|---|---|
| 901 (ai-1 hard) | hard +151 | hard +37 |
| 902 (player hard) | hard +214 | normal +331 |
| 903 (ai-1 hard) | normal +324 | normal +26 |
| 904 (player hard) | hard +255 | normal +86 |
| 905 (ai-1 hard) | normal +204 | hard +273 |
| 906 (player hard) | normal +581 | normal +357 |
| 907 (ai-1 hard) | hard +102 | hard +486 |
| 908 (player hard) | normal +531 | hard +209 |
| 909 (ai-1 hard) | normal +324 | hard +296 |
| 910 (player hard) | hard +221 | normal +14 |
| hard wins | **5 of 10** | **5 of 10** |

The goal (hard wins 7 of 10) **is not met**. Batch B (an import reserve of 2,200 for hard) won 3 of 4, C (that and goods
works by need) 1 of 3. What decides these matches:

- **The city-state race.** A captured city-state is about +250 land and its residents. In 11 of the 20 runs above
  one side ended with more land (a city more), and that side won 10 of them. Both sides go for the same city-states (army.city_state_target picks the
  nearest on its side of the map), and the first to get its army there takes the city. Hard's earlier push (cs_from
  0.75) does not help when its army is not yet 1.2 x the city-state's points. With cs_ratio 1.0 (batch A), hard's
  38-unit attacks were beaten back twice, and the normal AI took the softened city a few minutes later.
- **Population is goods-bound.** From tier 3 every capital ran at 0-40 % goods and 62-70 % happiness and stopped
  growing at 500-700 residents. Whoever imported goods (the market AI) or made them grew. The imports took balances
  into the tax hysteresis' high band (section 2.2).
- **Drafted residents.** Hard's larger army drafts residents (its capital had 170-180 drafted by 50:00 in seeds 901C
  and 904E, normal's 110-145), and the score counts them as supply (1 per point), not as population.
- **The side.** In batch F the player-side AI won 2 of 10, as hard and as normal alike. In batch A it won 6 of 10. The
  start positions of a seed weigh more than the knobs.

### 4.5 Performance

`KEEP_TREE=<903a7b1> SEED=701 tools/perf-bench.sh match m3ai-pb-701 '{opponents = 3, difficulty = "normal",
mode = "nation", world_size = 2048, enemy_brain = "ai"}' 20` (4 nations, benchmark mode, 72,180 ticks, output
`build/m3ai-pb-701-out`):

- The AI commanders (ai/init profiler), all four nations together: **0.113 ms per tick on average**, worst minute
  0.179 ms. That is 0.03 ms per nation against the 0.5 ms budget. Of that, army 0.027, build order 0.018, construction
  0.016, factories 0.016, barracks 0.014, governor 0.005, age-up 0.003, tech 0.001, planner 0.0009, council 0.0006 (intel
  and the controllers are not broken out); the scheduler jobs (ai3_intel, ai3_sites, ai_find_spot, rails_survey) come to 0.022 ms per tick on
  average.
- Script time per tick: mean 0.266 ms, p99 2.1 ms. 299 ticks went over 3 ms. Most are not AI: 230 production (nth60,
  worst 6.2), 20 ai/autotest (the test fixture), 14 logistics, 5 mapgen (background generation, worst 21.5), and the
  match start (3.6 s, once).
- **AI ticks over 3 ms: 10.**
  - 4 in commander.run. The worst, 21.9 ms at t59211 (rts-player, slice 2), is outside the marked parts (age_up 0.03,
    barracks 0.22), so it is tech.step or the factory pass.
  - 3 in towns.pick_site (worst 9.0 ms). The second-city site search still runs synchronously: cities.ai_step does
    not declare `TOWN_PENDING_OK`.
  - 3 in army.step (worst 3.8 ms).

  The "at most 3 ms in any tick" goal **is not met**; the mean budget is.

## 5. Regressions

- **Skirmish:** byte-identical vs aaa8061 (`tools/determinism-compare.sh`, WHAT=all, seed 501, 10 minutes: 4,518 lines
  each, 0 differing). The smoke passes 65/65 with 0 errors (`m3ai-smoke7`). Every change here is Nation-only: the
  planner, council and difficulty run in Nation mode only; governor goods works read `C.cfg.goods_per_works`, which
  only difficulty.apply sets (Nation); army.lua's push escalation reads `C.army.cs_push`, which only the council sets.
- **M1 seed 501** (1 normal opponent, 60 minutes): **51/53** on 903a7b1 (produce_rts-ai-1, and train_items: 14,789 of
  20,000). Single runs vary:
  - df6736c, batch A: 53/53.
  - c1c920d (m3-integ's head without this tuning): 52/53, failing produce_rts-ai-1.
  - Four variants of the pre-commit tree: 51-52, failing train_items, rail_line_rts-player (a blocked piece) or
    rail_line_rts-ai-1 (a town line that never got its second depot).

  The failing checks are those about whether each nation's single town line opens in time.
- **M2 seeds 701-705** on 903a7b1: trade, war, peace and capture pass 5/5. **Starving fails in 701 and 702.**
  - 701: rts-ai-1's town 12 at 36:00, 0 % rations for 4 minutes.
  - 702: rts-ai-2's planner trade city 23 at 40:00. It is 543 tiles out and has no farm spot.
  - df6736c failed 702 the same way, at 55:00.

| Seed | AI autotest (M2 ref.) | lowest trade (ref.) | wars / back to peace / ended | captures (nations, city-states) |
|---|---|---|---|---|
| 701 | 79/82 (81/82) | 3,520 (4,015) | 3 / 2 / 2 | 4 (2, 2) |
| 702 | 82/83 (81/83) | 5,943 (5,810) | 4 / 4 / 4 | 5 (3, 2) |
| 703 | 79/83 (83/83) | 5,196 (4,813) | 8 / 5 / 5 | 7 (6, 1) |
| 704 | 81/83 (80/83) | 5,293 (6,309) | 5 / 4 / 4 | 6 (3, 3) |
| 705 | 80/83 (79/83) | 5,221 (3,286) | 7 / 5 / 5 | 9 (5, 4) |

  The reference is `docs/qa/phase5-m2-integration-notes.md` §4.1 (dc3218e). Its remaining AI autotest failures were M1-era
  checks under four nations (age2_<force>, no_bad_spam, produce, kinds_8min, techs_6min). Here: techs_6min, age2 (4), no_bad_spam,
  produce (2), rail_line_rts-ai-1 (701, 704) and train_items (goal 20,000 items by train; 701, 703, 705).

## 6. Open issues

1. **Three cities linked by rail by 35:00: 12 of 20 nations.**
   - Every nation founds its third city. The lines are slow: in Age I the capital-town line and a ~300-tile trunk edge
     need about 400 rails (200 steel) and four depots (10 steel, 40 iron and 10 copper each). That comes on top of the
     Charter's 100 steel, at 19 steel a minute.
   - The aggressive AI (rts-ai-1) spends its plates on the army. Once at war it loses depots, and a line with a lost
     depot is lost.
   - Next: a steel smelter per pending trunk edge in Age I (build order), third-city sites within 250 tiles, and a
     make target for the depot kit instead of rails.lua's all-at-once craft (40 iron + 10 steel + 10 copper at one
     check; the aggressive AI's capital had 0 copper from 13:00 to 20:00 in M1 seed 501, batch F).
2. **Hard beats normal in 5 of 10, not 7** (section 4.4).
   - The score follows land (a city-state taken) and population (goods). The knobs (pace, micro, intel, council
     period, opm) do not change either.
   - Next: a goods chain at every level (fixed goods works with their copper cable and bricks), so the capitals grow
     past tier 3. A hard-only city-state plan: a first army sized to the city-state's points plus artillery, sent
     before the rival's.
3. **M1 seed 501 is 51-53 of 53 from run to run** (section 5). It fails rail_line_<force>, train_items (goal 20,000),
   produce or age2 depending on which line opens. scripts/rails.lua gives up on a blocked piece after MAX_PIECE_FAILS
   and never retries: the player's town line in batch G stayed at piece 24 from minute 26 (sent to m3-integ).
4. **M2 seed 702 starving** (df6736c): the planner's trade city 23, 543 tiles from the capital, had no farm spot within
   13 tiles of its City Center (governor town_food). Its rations came by hauler and by the trunk line, and stopped for
   4 minutes at 52-55 during a war. Next: farm spots in a wider ring with a supply hauler for the town, or no trade
   city beyond 450 tiles.
5. **Never triggered in the acceptance runs:** holding divisions (no front segment on 2048 worlds), interceptors (Air
   Force), bombers, artillery trains at sieges (Military railways and a depot within 110 tiles), mercenaries (1 in
   five seeds). The code paths ran in targeted probes only (wave B design runs). They need a 3072/4096 run with
   touching lands, or a scripted war probe.
6. **Uranium and nuclear** (deliverable 1) are not planned by the AI: no uranium extractor or nuclear plant
   placement. Rare extractors and the Age III districts are.
7. **AI ticks over 3 ms** (section 4.5):
   - one 21.9 ms commander slice 2 (tech.step or the factory pass, not marked);
   - the synchronous second-city site search (towns.pick_site, up to 9 ms; it goes to the scheduler once
     cities.ai_step sets `cities.TOWN_PENDING_OK`, asked of m3-integ);
   - army.step, up to 3.8 ms.

   Next: perf marks inside slice 2, and army.step's target scan in steps.
8. **One run per seed says little.** The autotest server runs (SPEED 6-10) did not reproduce from run to run (M1
   seed 501 above), so a single run cannot judge a small AI change. Skirmish identity was checked in benchmark mode
   (`tools/determinism-compare.sh`), where it holds line for line.

## 7. Commits

| Commit | What |
|---|---|
| a03e09f | first pass: planner, council, controller, intel, difficulty, resumable layout planners (with m3ai-perf) |
| df6736c | tuning 1: Age III road, air, belts, operations, rails |
| 903a7b1 | tuning 2: fort belts at war, trunk lines wait for the town line's depots and make the barracks save, the push escalation, hard's goods works (section 2) |
| (this) | these notes, filled in with the acceptance runs |

Hunks in other owners' files: H1-H5 (section 3, applied by m3-integ in 3edd55b); H6 withdrawn. Nothing pending.
