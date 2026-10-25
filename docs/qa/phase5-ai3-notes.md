# Phase 5 M3, wave B: the full nation AI (ai/planner, council, controller, intel, difficulty)

Date: 2026-10-17 (design), 2026-10-22 (acceptance runs). Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m3-ai`. Contract: `docs/PHASE5-M3.md` (D7,
§3 "ai/planner.lua, council.lua, controller.lua, intel.lua, difficulty.lua", §4 "AI (wave B)"). Study:
`docs/research/scale/war-ai-performance.md` §4. Inputs: `docs/qa/phase5-perf-notes.md` (scheduler, open issue 1),
`docs/qa/phase5-ai-notes.md` §6 (M2 AI open issues), the wave A notes of age3, air, war2, world3. Base: `mods/factorio-rts`
at 80bcdbe (tag m3-wave-a) with m3-integ's wave B work in the same tree. Everything here is Nation mode only; Skirmish
runs exactly as before.

## 1. Verdict

### Wave B.2 (3ea458e + 5a06781), the tree frozen for QA

| Criterion | Result |
|---|---|
| Operations with phases, ≥1 per nation | met: 20/20 nations |
| A fort belt built on a threatened approach | met: 5/5 seeds |
| Age III by 40:00 in ≥3/5 seeds | met: 3/5 |
| Wars and peaces as in M2 | met: every seed |
| 0 errors | met |
| AI time ≤0.5 ms/tick/nation on average | met: about 0.03 |
| Hard beats normal in ≥7/10 1v1 matches | **not met: 3/10** with the sides swapped per seed (section 4.7; the cause is documented there). The alternating-side batch J gave 7/10. |
| Never-triggered paths: holding division, interceptors, bombers, artillery train, mercenaries | met: 6/6 paths pass in the scripted war probe (two seeds, 0 errors) |
| Uranium and nuclear | minimal plan in place: outposts ran in 7 of 13 attempts; no nuclear plant finished by 60:00 |
| Every nation's 3 cities linked by rail by 35:00 | **not met: 12/20** (target 16) |
| Air patrols fly | met: 5/5 seeds (batch M; 4/5 in batch K) |
| No AI tick over 3 ms | **not met**: 16 commander runs of 21,612 over 3 ms on the committed tree (seed 802, 30 min), worst 8.5 ms. That worst is the town-site search, gone with TOWN_PENDING_OK; the 25.8 ms ore scan is gone (section 4.7) |
| M1 seed 501 | 52/53 on 5a06781; 53/53 on 705a33a with the held QA fix (section 4.8) |
| M2 seeds 701-705 | trade, war, peace and capture 5/5; starving 4/5 (701: towns at war) |

Skirmish is byte-identical; smoke 65/65.

### 903a7b1 (before wave B.2)

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
- **M1 seed 501:** 51/53. The result moves between 51 and 53 from tree to tree; HEAD without this tuning also gave
  52/53.
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
| goods works at the capital (wave B.2) | one per 20 goods/min of need, at most 2 | one per 12, at most 4 | one per 12, at most 4 |
| first city-state plan (army sized for it, artillery, early push) | - | - | yes |

Vision is honest at every level (sight checks only, never chart state); hard's Skirmish bonuses stay off in Nation mode
(`commander.NATION_NO_CHEATS`), and the M2 "+20 % tax for hard" goes (treasury.lua hunk H2, m3-integ). The goods works
are a planning rule, not a resource: from tier 3 every AI capital ran short of goods (0-40 % met, 62-70 % happy, no
growth) and the market AI imported them at 15-17 cr a piece in minutes of 380-500 cr, which took the balance below the
tax hysteresis' `enter` (1,500) and held a high tax until 2,100. Since wave B.2 every level's governor plans
the goods works by need (`C.cfg.goods_per_works`: one per 12 goods a minute of need, at most 4; easy one per 20, at most
2), the second and further works fixed on the goods recipe (in auto mode three works made the capital's other targets
and its goods stayed at 0 %), and the capital keeps 40 copper cable for them. (Tried and dropped: an import reserve of
2,200 for hard kept its tax normal but left its capital at 0 % goods; batch B, section 4.)

Hard's first city-state (`cs_plan`, wave B.2; council.cs_plan_step): from Age II at peace, before any operation, the
council sizes the army for the nearest city-state of the world plan (1.2 x its turret and garrison points, the push's
margin, counted as army.city_state_target counts them), the barracks weigh artillery x3, and the push goes out as soon
as the idle army's supply reaches that size instead of at push_after. In seeds 901-910 it sized the army (28-32 points,
38 supply wanted) but never fired: hard's regular push (at 0.75 x push_after) came first with the same army.

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
  included). Site rules (wave B.2):
  - The third city goes to a site within 250 tiles of an own city when one is left (`third_link`: a short trunk edge),
    else to the best site.
  - No city but the oil town lies farther than 450 tiles from the capital (`far_city`; a trade city 543 tiles out
    starved in M2 seed 702).
  - A site needs room for a farm within 15 tiles of its City Center, inside its 16-tile logistic area; a planned city
    gets its farm at once (ai/governor.lua town_food, a 13- then a 15-tile ring).

  The oil town's City Center stands where its 16-tile logistic area covers the most wells of the nation's home oil field
  (off every well's pumpjack footprint); from Age II pumpjacks on the covered wells put crude oil into its network. A
  site on ground not generated yet is requested (worldgen.request_area) and skipped.

  Tried and dropped:
  - The City Center at the front of the construction queue. Behind 100 build-order jobs a site planned at 7:30 was built
    at 15:46, but in front of them the new town's farm, turrets and houses held up the capital's copper smelters by 2
    minutes and M1 seed 501's Age II by 5.
  - The third city from 7:00, with Industrialisation and Railways wanted once it is under way. The aggressive AI's capital
    then ran out of copper in Age I and its town line never got its second depot in M1 seed 501, and no nation linked its
    cities earlier.
- **Trunk.** Prim's minimum spanning tree over own cities from the capital; every city that rails.lua's own program
  (the capital - town line, and its retaken-line programs) does not serve gets a `rails.ai_program` of the planner's
  (`A.pay` = the capital's centre: H1), at most 3 lines building at once (the main program counts), stepped every 300
  ticks. Every edge carries plates and the Age III goods (`export_goods`), and every non-capital city exports those goods
  (auto haulers bring them before a line opens); the capital keeps the planner's targets of them. While a trunk line
  waits for its depots or is being built and three cities are not linked yet, the barracks save steel and iron for it
  (`planner.saving_rail`, read by ai/age_up.lua as for rails.lua's own line). A survey that fails twice re-anchors the
  edge at the nearest linked city; an edge longer than 480 tiles waits. In Age I the trunk waits until the capital holds
  40 circuits (the Charter's). A trunk edge takes no depot kit while rails.lua's own capital-town line still waits for its
  depots (both are paid from the capital's plates; in M1 seed 501 the aggressive AI's town line stayed at one depot for
  53 minutes while its oil-town edge crafted its own). While three cities are not linked, the second Steel works is
  the first Age II district. Only a city with an open rail line and no supply hauler exports the Age III goods (on every
  city a town's ration hauler carried batteries 725 tiles instead and the town starved, M2 seed 701).
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
- **Uranium and the nuclear plant** (wave B.2, a minimal plan). In Age III, the nearest uranium deposit of the world plan
  within 260 tiles of an own city (not on a rival's land) gets an outpost once Geology is researched. The outpost is an
  rts-hub 10 tiles south of the ore for network and power, one extractor on the ore, and a stockpile at the extractor's
  output; the hub exports the ore and the capital keeps 40. With Nuclear power researched and the outpost running, the
  nuclear plant joins the capital's district list and 2 fuel rods become a make target (Chemistry works).

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

- **Perf (wave B.2, Nation only).** scout.best_target keeps its result for 300 ticks per commander while the target
  building stands, so army.step's scan over every known enemy building does not run every pass. scout.patch_list (the
  raiders' fallback target) reads the world plan's recorded ore patches instead of scanning the whole arena; that scan
  took 25 ms in one tick on a 2048 world. The commander's factory pass and its helpers are called through the module
  table, so the bench's perf marks can time them (tools/probes/ai3_marks.lua).

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
at 1.2 cr per supply point (20 % more) makes money tighter, and one seed's outcome turns on small differences (section 6, item 8).

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

### 4.6 Wave B.2 (3ea458e on cb909ac, with m3-integ's uncommitted `cities.TOWN_PENDING_OK`)

The test tree is HEAD cb909ac plus the B.2 AI plus m3-integ's one-line TOWN_PENDING_OK. m3-integ's work in progress in
rails.lua, market.lua, diplomacy.lua, garrison.lua and sinks.lua is not in it. Batches J (tree9) and K (tree10) give
the same numbers for the normal AIs; K is listed. Every run reproduces: K repeated J's 1v1 scores to the point.

4 normal AIs, seeds 801-805 (batch K):

| Seed | 3 cities linked by 35:00 (player, ai-1, ai-2, ai-3) | phased operations | air patrols | fort belts | first Age III | wars / ended / peaces | AI ms/tick (mean / worst minute, 4 nations) |
|---|---|---|---|---|---|---|---|
| 801 | 2 of 4 (37, 53, 33, 30) | 7, 21, 4, 1 | **0** | 4 | 40:00 | 4 / 3 / 3 | 0.29 / 0.48 |
| 802 | 3 of 4 (33, -, 30, 28) | 5, 23, 5, 1 | 21 | 6 | 38:00 | 3 / 3 / 3 | 0.26 / 0.44 |
| 803 | 1 of 4 (31, -, -, -) | 8, 30, 5, 3 | 3 | 8 | 51:00 | 9 / 8 / 8 | 0.25 / 0.43 |
| 804 | 4 of 4 (35, 34, 32, 33) | 7, 27, 6, 3 | 3 | 6 | 40:00 | 3 / 3 / 3 | 0.30 / 0.51 |
| 805 | 2 of 4 (31, 41, 30, 37) | 7, 26, 7, 1 | 9 | 4 | 52:00 | 5 / 4 / 4 | 0.26 / 0.41 |

- **Linked by rail by 35:00: 12 of 20 nations, against a target of 16.**
  - The 903a7b1 batch had 8 of 20; the same AI on df6736c's base, batch G, had 12.
  - In 803, the aggressive rts-ai-1 took a town from rts-ai-2 at 23:00 and one from rts-ai-3 at 26:00, and neither of
    them linked three cities afterwards.
  - rts-ai-1 itself misses in 4 of 5 seeds: it is at war from 18-25 minutes and loses depots.
  - The 250-tile rule set the third city in 6 of 20 nations. The others had no site that close and took the oil town
    at about 300 tiles.
  - The Age I steel smelter per trunk edge is not built: the capital's hub has no free slot for a second steel chain
    (orders_data.lua: the four CC stockpiles cap it). The second Steel works heads the Age II districts instead.
- Phased operations 20 of 20; fort belts 5 of 5; wars and peaces every seed; 0 errors.
- Air patrols 4 of 5. In 801 no nation had a finished airfield by 60:00; Aviation came at 41-48.
- Age III by 40:00: 3 of 5.

**M2 seeds 701-705** (batch K):
- trade, war, peace and capture pass 5/5;
- **starving passes 4/5**;
- 701 fails: rts-ai-1's mining town 12 had its own farm and bakery from 14:00 and was at war with rts-player from 21:50. Its rations fell from 100 % to 0 within two minutes at 35:00, it was taken at 44:00, and then starved as rts-player's;
- 702 (the far trade city) now passes, under the 450-tile rule and the farm-room rule;
- AI autotest 79/82, 81/83, 78/83, 81/83, 79/83.

**M1 seed 501** (batch K): **52/53**. train_items fails: rts-player's town line never opened, so 6,269 items of the
20,000 goal moved, all by rts-ai-1. m3-integ's work in progress on rails.lua (a detour around a blocked piece; depots
kept off surveyed pieces) addresses that line.

**Hard against normal, seeds 901-910** (batch J; K identical): **hard wins 7 of 10**.

| Seed | 901 | 902 | 903 | 904 | 905 | 906 | 907 | 908 | 909 | 910 |
|---|---|---|---|---|---|---|---|---|---|---|
| hard side | ai-1 | player | ai-1 | player | ai-1 | player | ai-1 | player | ai-1 | player |
| winner (margin) | hard +434 | hard +601 | hard +576 | normal +286 | normal +137 | hard +58 | hard +427 | hard +381 | hard +357 | normal +463 |

The city-state plan never fired (section 2.2), and the goods chain runs at every level. So the 7 of 10 does not come
from a hard-only rule. It comes from hard's knobs on a changed economy (pace, intel, micro), and the side still weighs:
the player-side AI won 4 of 10.

**Perf bench** (tree9, 20 minutes, 4 nations, seed 701, benchmark mode):
- AI commanders 0.115 ms per tick for all four together;
- towns.pick_site is gone (the async site search);
- AI calls over 3 ms: 8 commander runs of 14,412.
  - The worst was one army.step at 25.8 ms: scout.patch_list scanned the whole arena for ore, 8.3 ms of clustering plus
    the scan. 3ea458e reads the recorded patches instead; not benched after the change.
  - One 7 ms mix.manage_barracks (not attributed).
  - The rest are 3.1-5.1 ms runs summed over several parts.
- The 21.9 ms slice-2 spike of the 903a7b1 bench did not come back at that tick with the extra marks
  (tools/probes/ai3_marks.lua: the factory pass took 0.38 ms there). It was not the AI's work; most likely a GC step.

**Uranium and nuclear** (batch J, 21 runs):
- 13 nations planned an outpost, and 7 of those outposts ran (ore exported);
- 27 nations in Age III found no deposit within 260 tiles;
- the nuclear plant entered a capital's district list once by 60:00 and was not finished.

**War paths: the M3 acceptance for these council paths** (accepted by the lead; tools/probes/ai3_war_paths.lua, written
by a helper sub-agent):

```sh
KEEP_TREE=build/m3ai-tree9/factorio-rts EXTRA_LUA=tools/probes/ai3_war_paths.lua STOP_ON=RTS_WARPATHS_DONE \
  DURATION_MIN=50 SEED=<811|806|805> SPEED=10 tools/autotest-run.sh m3ai-war-<seed> '{opponents = 1,
  difficulty = "hard", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 3000
```

The subject is rts-player's running hard AI with the aggressive doctrine; rts-ai-1's commander is stopped.

What the probe sets up 8 s in:
- Fortification, Military railways, Aviation and Air Force researched, and 6,000 cr (topped up below 3,000);
- two towns of the rival: one 180 tiles out without a shared border (the war goal), one 118 tiles out with touching land
  (a front);
- war with those goals;
- an airfield, and a depot within artillery range of the goal, kept stocked.

What it spawns:
- enemy waves on the capital;
- an enemy scout plane;
- once the plane is seen, the subject's interceptors and bombers;
- two scout planes of the subject and 10 enemy walkers beyond the front.

The AI's own council does the rest; the file's header documents every step.

Results (seconds after the setup, seeds 811 / 806 / 805), **6/6 paths PASS on all three seeds, 0 errors**:

| Path | 811 | 806 | 805 | Evidence (log) |
|---|---|---|---|---|
| hired garrison | 2 | 2 | 4 | `council: rts-player hires 8 garrison points at attacked city 1` |
| interceptors | 6 | 6 | 6 | `interceptors (division #3, 3 planes) patrol the capital: enemy planes seen 1 s ago` |
| holding division | 61 | 31 | 91 | `division #4 (15 units) holds front segment 2 (..., threat 89, enemy strength 10)` |
| bombers | 262 | 527 | 292 | `operation #3 bomb -> city ... phase fly`, then `fly -> strike`, `strike -> return` |
| artillery train | 269 | 534 | 297 | `advance -> siege (89 tiles)`, `artillery train 6 ... deployed at depot #527 with 20 shells`, 3 shots |
| mercenaries | 301 | 528 | 293 | `sinks: rts-player hires mercenaries at port #504 ...: 8 units`, `council: ... hires mercenaries (division #9)` |

Bugs it found, fixed in 5a06781 (council.lua):
1. A reinforcement did not join a capture whose artillery train had made it a "siege", and started a second operation.
2. Mercenaries hired at a port 790-1,160 tiles out walked into an attack group and kept its centre out of siege range,
   so no siege phase and no artillery train. Now half the group within siege_range counts as there, and mercenaries
   come from the nearest own port within port_reach (450).
3. A mercenary hire at the supply cap was refused, and the retry waited 2 minutes. Now up to 8 idle walkers retire and
   the hire comes again in 10 s.
4. Front segment names logged as "table".

Bug 5 (a ceasefire on weariness alone, scripts/diplomacy.lua:850) went to m3-integ through the lead.

**The player slot** (a helper's read-only study of batches A and F, then batch J):
- No code path treats rts-player's AI differently. It loses the same way rts-ai-1 does, and hard won 10 of 20 there.
- What decides a match is the city-state race: the side left without a city-state loses about 250 land and 100
  residents, about 350 points, which beat the margin in every such match.
- The loser of the race used to pile onto the rival's siege (push level 2 switched the clear-of-rivals rule off),
  arrive after the capture, and never try again: the push was gated on "no operation yet", and the capture cooldown
  is 15 minutes.
- Fixed in 5a06781:
  - push until a city-state is held (and no offensive runs);
  - never target a city-state a rival is capturing;
  - from the second push only a rival division within 100 tiles keeps an AI off a city-state;
  - losing the target city-state ends the capture cooldown.
- One real slot asymmetry, measured in A and F: rts-ai-1 sold its captured port's 100 starting circuits in 20 of 20
  runs, the player in 6 of 20 (a race of the strategist's sale against the market AI's haul, staggered by slot). It is
  fixed in m3-integ's market.lua (the haul only while a hauler serves the port) and did not change who won.

### 4.7 Wave B.2, final round (5a06781: war-probe fixes and the city-state race)

Test tree build/m3ai-tree12 = HEAD a8d398e + 5a06781's AI + m3-integ's TOWN_PENDING_OK line (batch M).

**Hard against normal, the lead's protocol: seeds 901-905, each played twice with the levels swapped between the
slots** (`difh`: rts-ai-1 hard; `difn`: the player hard), so every map is played both ways:

| Seed | difh: winner (margin) | difn: winner (margin) | land, difh (player / ai-1) | land, difn (player / ai-1) |
|---|---|---|---|---|
| 901 | normal +170 | normal +292 | 1721 / 1721 | 1468 / 1721 |
| 902 | normal +155 | hard +429 | 1721 / 1721 | 1721 / 1581 |
| 903 | hard +88 | normal +146 | 1734 / 1581 | 1721 / 1721 |
| 904 | hard +255 | normal +5 | 1721 / 1721 | 1721 / 1721 |
| 905 | normal +119 | normal +576 | 1721 / 1468 | 1468 / 1721 |

**Hard wins 3 of 10. The goal (7 of 10) is not met**; this was the one attempt (goods chain at every level plus hard's
city-state plan), and by the lead's rule the measurement stands with its cause:
- **The knobs do not touch what the score counts.** The score is about 1,000 population, 1,470-1,730 land, 50-230
  supply and a little treasury. Hard's knobs are fresher intelligence, more operations at once, full micro, a faster
  council, more orders, a faster build pace and the city-state plan; they change how its army fights, not how fast its
  cities grow.
- **The economy is the same at both levels.** It is goods- and ration-bound, and since wave B.2 every level runs the
  same goods chain. Hard's earlier 7 of 10 (batch J) was on alternating sides with the goods chain also at every level;
  with the sides swapped on the same maps it is 3 of 10.
- **With the race fixes both sides usually take a city-state.** Land was equal in 5 of the 10 matches, and hard won 1
  of those 5 (904 difh). Where land differed, the side with more land won 4 of 5.
- **Hard's own city-state plan fired** (`army ready for city-state ...: pushes`), but an earlier push does not win the
  race when the rival's first army is as large.
- **Without resource bonuses**, a stronger hard needs economic skill that normal lacks, for example a hard-only
  district or goods plan. Wave B.2 gave the goods chain to every level, as the lead's item 4 asked.

**4 normal AIs, seeds 801-805:**

| Seed | linked by 35:00 (player, ai-1, ai-2, ai-3) | air patrols | fort belts | first Age III | errors |
|---|---|---|---|---|---|
| 801 | 2 of 4 (37, 59, 33, 30) | 1 | 4 | 40:00 | 0 |
| 802 | 3 of 4 (33, 57, 30, 28) | 18 | 6 | 38:00 | 0 |
| 803 | 1 of 4 (31, -, -, -) | 7 | 8 | 46:00 | 0 |
| 804 | 4 of 4 (35, 34, 32, 33) | 3 | 6 | 40:00 | 0 |
| 805 | 2 of 4 (31, 41, 30, 37) | 7 | 4 | 54:00 | 0 |

Linked 12 of 20 (not met); air patrols 5 of 5 (met); belts 5 of 5; Age III by 40:00 3 of 5 (met); phased operations in
every nation; 0 errors.

**M2 seeds 701-705:** trade, war, peace and capture pass 5/5. Starving passes 4/5: in 701, rts-ai-1's town 12 at war
starves at 38:00, and rts-ai-2's city 23 at 55:00. City-state captures rose to 2-4 per seed (were 1-3) with the race
fixes. AI autotest 79/82, 81/83, 79/83, 81/83, 78/83.

**M1 seed 501:** 52/53. train_items fails: the player's town line never opens; m3-integ's rails fixes (a detour around a
blocked piece, depots kept off planned pieces) are not in this tree, and on their tree train_items passes.

**Re-bench of the committed tree** (cb4c563, without m3-integ's uncommitted TOWN_PENDING_OK; seed 802, 30 minutes, 4
nations, benchmark mode, `EXTRA_LUA=tools/probes/ai3_marks.lua`, output build/m3ai-pb13-802-out). 0 errors. AI
commanders 0.143 ms per tick for all four nations (0.036 per nation), worst minute 0.222.

**AI ticks over 3 ms: 16 commander runs of 21,612, worst 8.49 ms.**
- 3 are the synchronous second-city site search (towns.pick_site, 7.4-8.2 ms). It goes away once
  cities.TOWN_PENDING_OK is committed.
- 3 are market.ai_step (m3-integ's, 2.3-3.2 ms within the run).
- 1 each: army.step 5.5 ms, the factory pass 5.6 ms, planner.step 3.8 ms, the factory pass plus barracks at 3.1-3.3 ms.
- 3 runs (8.1, 6.6 and 3.9 ms) have no marked part over 0.8 ms (a GC step most likely).

The arena-wide ore scan is gone. The raiders' patch fallback ran: 6 raids went for ore patches, and scout.step's worst
call was 2.1 ms.

### 4.8 QA fix round: M1 seed 501 on 705a33a (build/m3ai-tools/m1-fix.patch)

On m3-integ's 705a33a (their rails fixes, escrow, tax cap, async town site), M1 seed 501 was 51/53, with 0 errors and no
blocked line. Both failures were AI economy:
- **produce_rts-player.** From minute 13 to 29 the economic AI's barracks chose heavies and cars, which were short of
  iron and steel together. A consumer short of two items reserves nothing (production.lua), so it made 0-1 kits a
  minute.
- **train_items 17,433.** Wave B.2's second Steel works took the capital's last district spot from the Smelting works.
  Nothing consumed the town's ore, so the capital's 3,000-ore keep filled, and the player's freight train stood empty
  from minute 38 (4,000 items in 6 trips).
- **produce_rts-ai-1** came up under a first fix: both barracks stood `disabled_by_script` by labor for 12 minutes. In
  the Age II priorities the army comes 9th of 11, and there were more jobs than workers.

The fix (Nation only):
- **Barracks heartbeat.** After 3 minutes without a unit (mix.HEARTBEAT 4 → 3 minutes) the barracks stop yielding, and
  the first one makes drones until a unit comes out. A drone takes iron only, so production can reserve it.
- **Barracks pin.** The capital's first barracks is pinned for workers while it stands labor-disabled and no unit came
  for 3 minutes. A permanent pin took Age I workers and delayed the line's depots by 8 minutes.
- **Smelting works.** It joins the planner's districts right after the second Steel works when a town ships ore.

| Check | 705a33a | with the fix |
|---|---|---|
| M1 seed 501 | 51/53 (produce_rts-player, train_items 17,433) | 53/53 (train_items 20,273) |
| Skirmish | - | byte-identical (4,518 lines, 0 differing); smoke 65/65 |
| 801-805: linked by 35:00 | 15/20 | 11/20 |
| air patrols / belts / Age III by 40:00 / phased ops / errors | 5/5, 5/5, 0/5, 20/20, 0 | 4/5, 5/5, 0/5, 20/20, 0 |

- **Linking.** 11/20 is inside the 8-15 range my 801-805 batches gave on close trees; 705a33a's 15/20 is the top of
  that range.
- **train_items is fragile.** Five close variants gave 16,963-20,375:
  - the Smelting works only after the line opens: 51/53;
  - the heartbeat only outside the rail and district saving: 52/53;
  - the second Steel works back after linking: 52/53, and linking 11/20.

### 4.9 Hard's economic plan: adopted as hard-only behaviour; "hard beats normal 7/10" not met

Hard (`goods_chain`) gives the goods works' inputs works of their own, fixed on their recipe:
- one copper-cable works per 6 goods works beyond the first, and one brick works per 2;
- one goods works per 10 goods a minute of need, at most 5 (was 12 and 4).

The reason: at 40-50 minutes the capitals held 3,000-4,600 iron and 2,200 stone, while goods stood at 0 % and happiness
at 62.

Seeds 901-905, each played with the levels swapped:

| Seed | 5a06781 base: difh / difn | 705a33a + M1 fix: difh / difn |
|---|---|---|
| 901 | hard +23 / normal +160 | hard +241 / hard +64 |
| 902 | hard +351 / hard +104 | normal +107 / hard +415 |
| 903 | hard +142 / normal +383 | normal +32 / hard +295 |
| 904 | hard +109 / normal +111 | normal +69 / hard +236 |
| 905 | hard +17 / hard +51 | normal +149 / normal +507 |
| hard wins | 7/10 | **5/10** |

On the tree it ships with, hard wins 5 of 10: the criterion "hard beats normal in 7 of 10" is **not met**. The cause
is the side, not the level:
- On 5a06781 the rts-ai-1 side won 8 of 10 (as hard 5 of 5); on 705a33a + the fix the player side won 8 of 10 (as
  hard 4 of 5).
- With the city-state race fixed, land was equal in 8 of 10 matches there, and population decided by margins of 32-507.
- Which side's economy pulls ahead in a seed swings with any change of the tree, and that swing is larger than what the
  goods chain adds.
- Without resource bonuses, a measurable hard needs an economic edge larger than this side swing, or the measurement
  needs more seeds than 5 played both ways.

The lead's decision: the plan goes in anyway, as a hard-only economic behaviour, not as proof of the criterion. A
human facing hard meets a stronger economy (the goods chain's input works), and normal AIs are untouched: the 4-nation
runs on 801-805 are all normal, so their logs are the same line for line with and without the plan.

### 4.10 Age III by 40:00 on 705a33a: 0/5 against 3/5

The lead asked whether Age III by 40:00 fell from 3/5 to 0/5 because of m3-integ's B.2 or because of my run setup. It
is neither a setup difference nor a broad regression:
- Batch M (my tree on the old base) and batch P (705a33a) used the same lane.sh, seeds, maps and probes. Their logs
  are identical through minute 3.
- The trees differ only in m3-integ's five B.2 files: diplomacy, garrison, market, rails and sinks.

| 801-805 | old base (batch M) | 705a33a (batch P) | 73f045b (batch S4) |
|---|---|---|---|
| first Electrification, mean | 32.7 min | 34.9 min | 35.8 min |
| first Age III per seed | 39:29 37:42 45:12 39:29 53:11 | 40:10 43:19 44:40 41:46 47:27 | 42:10 43:05 45:05 46:03 46:37 |
| first Age III, mean / by 40:00 | 43.0 min / 3/5 | 43.5 min / 0/5 | 44.6 min / 0/5 |
| by 60:00: Electrification / Age III | 16/20, 11/20 | 19/20, 14/20 | 15/20, 11/20 |
| stage 1 delivery (start to Age III), median | 8.1 min | 3.0 min | 10.3 min |

**Threshold effect.** The drop from 3/5 to 0/5 is mostly the 40:00 line:
- two of the old hits came at 39:29;
- P-801 misses the line by 10 s;
- 705a33a brings more nations to Age III by 60:00, not fewer.

**What is later.** The front-runner's Electrification. On seed 802, rts-ai-2's Age III moved from 37:42 to 43:19:
1. **Port loot (market.ai_wanted gate, minute 3).** On the old base ai-2 sent neutral port #463's 100 circuits home:
   30 arrived by minute 9 and the rest were sold at minute 13. On 705a33a no hauler serves the route, so it sells all
   100 at minute 3 for 348 cr. Industrialisation (20 advanced science: circuits and steel) finishes at 815 s instead of
   720 s, the Railway Charter starts 95 s later, and Age II comes at 18:24 instead of 17:52.
2. **Rail work pulled forward into the research window.** The Electrification research takes 1,045 s instead of 660 s.
   The labs wait for industrial science (engine, advanced circuit, sulfur), and advanced circuits stay at 6 from
   minute 24 to 30 (old base: 24-50). From minute 18 to 37:
   - ai-2 makes 412 steel plates instead of 564;
   - its districts report steel starvation 55 times instead of 17;
   - all six AI depots are paid through the escrow and placed at minutes 24-25 (old base: minutes 23-34). Each costs
     40 iron, 10 steel and 10 copper, and the escrow has no steel floor;
   - rail tiles at minute 30 are 805 instead of 513, and the rails district makes 504 rails instead of 366.
3. **Armoured cars (AI side).** ai-2's 7th district finishes at minute 34 (old base: 31), which ends its saving. The
   barracks then make 14 Armoured cars, 28 engines, while the research still waits for engines. On the old base the
   switch came after Electrification.

The tax cap plays no part: ai-2 switched tax once, and on 705a33a it held more money (2,795 against 2,176 at minute
35).

Two fixes:
- **(a) m3-integ:** the escrow leaves 50 steel, and stage 1's concrete goes from 150 to 100. They are testing it.
- **(b) AI side, in this commit:** `mix.available` refuses any kit that takes engines (the Armoured car) while the
  current research is the Age III road's (`planner.research_first`: Electrification), its science kit takes engines,
  and the capital holds fewer engines than the remaining kits need (`mix.research_engines`).
  - A first version blocked engine kits during any research. On seed 802 the player slot's Aviation then waited 19
    minutes for engines, the nation made no Armoured car in 60 minutes, and `cars_rts-player` failed.

Seed 802 on 73f045b + hard's plan + (b), against 73f045b (the 4 AIs are normal, so hard's plan changes nothing here):

| Seed 802 | 73f045b (S4) | + (b), any research (W1) | + (b), research_first (W2) |
|---|---|---|---|
| ai-2 Electrification (after the previous research) | 1,040 s, 6 cars during it | 1,005 s, 1 car | 1,005 s, 1 car |
| Age III: ai-2 / player / ai-3 | 51:54 / 59:30 / 43:05 | - | 45:54 / 52:54 / 43:05 |
| autotest | 88/93 | 87/93 (+ `cars_rts-player`) | 88/93 (the same 5 failures as S4) |

(b) shortens ai-2's Electrification by only 35 s. Its gain comes later: the engines it keeps bring ai-2's Age III
6 minutes earlier and the player's 6.6 minutes earlier. The research still takes about 1,000 s against 660 s on the old
base: the rest of the delay is steel and circuits, which is (a).

**Cost of the M1 fix.** On 801-805, 73f045b (S4) reaches Age III by 60:00 in 11/20 against 14/20, and links 11/20
against 15/20. With five seeds that is within the swings seen between close trees, but it is recorded here.

### 4.11 QA fix 2: the aggressive AI's rail lines under the M1 fix's heartbeat

m3-integ found that on 73f045b plus their market slicing, rts-ai-1 (aggressive) opened no rail line by 45:00 in 3 of
4 runs. Its lines waited for a construction train on no-kits, no-rails and no-fuel. My own runs showed the same
pattern on 801-805: ai-1 linked its three cities at 51/43/51/58/58 min, against 35/31/56/37/43 on 705a33a.

**Cause.** ai-1's army sits at the Age I cap (40) from minute 9: 41-49 units on seed 802. The M1 fix's 3-minute
heartbeat still fired every 3 minutes. Each beat lifted the rail saving and the cap for every barracks and added 1-3
units (41 -> 44 -> 47 -> 49). Iron, copper and steel went into the army instead of the rail program's kits.

**The fix (Nation only, `ai/mix.lua`, `ai/governor.lua`):**
- The M1 fix's beat (3 minutes, the first barracks makes drones) fires only below the Age I army cap and never while
  the rail program saves (`C.nation.saving_rail`). The produce check does not count minutes at the cap or while
  saving, so the beat is never needed there.
- At the cap, only wave B.2's 4-minute bypass remains (`mix.HEARTBEAT_THREAT`), as on 705a33a.
- The capital's barracks pin applies only under the same two conditions, so it is released while the rail program
  saves.

A first version also turned the B.2 bypass off during rail saving. ai-1's rails then paid its second depot at minutes
10-12, which took the steel Industrialisation needed: Age II came at 21:56, and M1 501 fell to 51/53 (age2_rts-ai-1,
train_items 17,847).

| ai-1: first line / three cities linked | 705a33a | 73f045b | aaf8764 | aaf8764 + fix |
|---|---|---|---|---|
| seed 804 | 30 / 37:00 | 52 / 58:00 | - | 27 / 37:00 |
| seed 802 | 28 / 31:00 | 32 / 43:00 | none / - (CC lost at 28:48) | none / - (its line destroyed in a war) |

- **Seed 802 on aaf8764.** It is decided by ai-1's war with the player, not by the heartbeat. ai-1 loses its rail line
  with the fix and loses its capital without it. On 1f28ccb the first version opened ai-1's first line at 28 and
  linked at 29:00.
- **M1 501 on aaf8764 + fix: 52/52, all passed.** The match ended at 59:19 when rts-ai-1 took the player's capital, so
  harass_rts-ai-1 was not checked. train_items stood at 19,285 and was not yet due. Age II came for the player at
  16:55 and for ai-1 at 19:15.
- **Skirmish** is byte-identical against aaf8764 (4,518 lines, 0 differing). Smoke 65/65, 0 errors.

### 4.12 QA fix 3: starving towns, supply haulers without coal (Factorio 2.1, on f37d073)

**The regression.** m3-integ found M2 starving on dad7a40 in seeds 701 and 703, city 12; 705a33a, 1f28ccb and aaf8764
had none. In both seeds the town's supply hauler stood at the capital "waiting (no-fuel)". A hauler takes its coal from
the network of the hub it leaves (1 per 40 tiles), and the Steel works, plastic, explosives and supply crates use the
same coal.
- **701.** rts-ai-1 went into the war with the player with 49-64 units, against 81 on aaf8764: the beat at the cap no
  longer fired (section 4.11). A raid at 23:11 destroyed the hub that collects one of its two coal pits. Coal intake
  fell from 120 to 60 a minute, and the rebuild waited 35 minutes behind 18 jobs. The hauler had no fuel from minute
  25, and the town's rations ran out at 37:00.
- **703.** Supply haulers left the capital with fuel for the outbound leg only and stood out of fuel at the town,
  which holds no coal: three of rts-ai-2's in turn on the first 2.1 runs. The governor also picked haulers that stood
  out of fuel at far hubs as supply haulers.

**The fix:**
- **Tank first.** `ai/governor.lua` `supply_fuel`: while a supply hauler stands at the capital, its tank (`h.fuel`) is
  filled from the capital's network, ahead of the other coal users, up to `fuel_trips` round trips. 3 round trips took
  the coal of rts-ai-1's construction trains on 703, so it is 1.
- **Import.** After `fuel_buy_after` (1 minute) of a supply hauler waiting for fuel at the capital, the capital gets a
  make target of `fuel_buy` (200) coal. The market AI imports a target's shortfall the nation does not make. In an
  earlier round on 703, rts-ai-1 bought 198 coal twice; in the final runs no supply hauler waited that long at the
  capital.
- **Stranded haulers.** A supply hauler that waits as long out of fuel at another hub goes back to auto, and another
  is sent. No auto hauler that stands out of fuel away from the capital is picked.
- **Hubs first.** `ai/construction.lua` `repair`: a destroyed hub is re-queued at the front of the queue, so its item is
  made first.
- **Route rule (m3-integ's `logistics.lua`, my hunk; committed by m3-integ in 552ee2c).** A route hauler leaving its
  pickup for a drop-off that cannot refuel the way back takes the way back too before it leaves. Applied to every
  hauler, the aggressive AI opened no rail line in 703 and 704, so auto haulers keep the old rule.
- **Counters.** The minute line gets the tank coal and the swaps: `supply haulers N (tank coal N, swaps N)`.

All runs below are on Factorio 2.1 (f37d073 + the fix): M2 = 4 normal AIs, `m3_acceptance.lua`, 60 min, speed 8.

| Run | Starving | Summary | Failures |
|---|---|---|---|
| M2 701 | PASS | 81/82 | techs_6min_rts-ai-1 |
| M2 702 | PASS | 81/83 | age2_rts-player, cars_rts-ai-2 |
| M2 703 | PASS | 79/83 | no_bad_spam (player, ai-3), age2_rts-player, train_items 18,825 |
| M2 704 | PASS | 82/83 | rail_line_rts-ai-1 (also on f37d073 alone: 82/83, the same failure) |
| M2 705 | PASS | 82/83 | train_items 19,333 |
| M1 501 | - | 51/53 | age2_rts-ai-1, train_items 10,411 (the 2.1 base: 51/53, train_items 19,397; with the route rule alone 14,949) |
| 4-nation 802 (`ai3_acceptance`) | - | 90/93 | ai-1: first line 37:49, linked 43:00 (dad7a40 on 2.0: no line) |
| 4-nation 804 | - | 90/93 | ai-1: first line 23:23, linked 30:00 (dad7a40: 27 / 37:00) |
| Skirmish | - | byte-identical against f37d073 and against 552ee2c (4,363 lines, 0 differing) | smoke 65/65 |

**The cost: train_items in M1 501.** The check count is unchanged, but items moved by train fall:
- 19,397 on the 2.1 base (5a2cdcc, m3-integ's base21-m1), 14,949 with the route rule alone (fuel21-m1), and 10,411
  with the rule and this fix.
- rts-ai-1 opens only its town line (the base opens 2 more by 50:00). Its haulers burn more coal for fewer trips:
  2,100 coal in 173 trips on the base, 2,552 in 115 here. The player: 3,463 in 556, then 3,553 in 279.
- Supply haulers that no longer strand keep running the long town routes, and that coal used to go to outposts and
  trains.
- In the 4-nation M2 runs train_items stays in the base's range: 18,825-28,514, and f37d073 704 alone has 26,117.

**Narrowed (the lead's option 2).** The tank comes first only while the town is short of rations (below
`town_rations_minutes` of its need). Otherwise the supply hauler competes for coal like any other. The import target
and the stranded-hauler replacement are unchanged.

| HEAD 33eb037 + narrowing | Result |
|---|---|
| M2 701 | starving PASS, 81/82 (techs_6min_rts-ai-1); 6 stranded haulers replaced |
| M2 703 | starving PASS, 77/82 (no_bad_spam x2, age2_rts-player, cars_rts-ai-3, train_items 18,125); 6 replaced, 3 coal imports |
| M1 501 | 51/53, train_items **13,506** (player 4,130 in 16 trips, rts-ai-1 9,376 in 35); 10,411 before the narrowing |
| Skirmish / smoke | byte-identical against e098e28 (4,363 lines); 65/65 |

Tanks now take almost nothing: 0-18 coal per nation in 60 minutes, against 182-797. The rest of the gap to 19,397 is
the route rule's return-leg estimate (14,949 with the rule alone), which m3-integ is calibrating.

**Supply hauler fuel on 2.1.**
- Per run: 6-11 swaps of stranded haulers, and 182-797 coal per nation put into supply hauler tanks over 60 minutes.
- The no_bad_spam failures on 703 (belts whose revive kept failing) failed on dad7a40's 703 too.
- **Formation and spacing on 2.1.** The port restored the 2.0 unit steering. The AI's thresholds are distances of tens
  of tiles to a target (siege 100, relief 40). Over 701-705 the operations' phase changes are in the 2.0 proportions:
  raids 95 assemble -> advance, 46 advance -> strike; captures 44 assemble -> advance, 26 advance -> siege. No retune.
- **2.1 tooling.** One M2 702 server died at 81 s on the shared autosave in build/ (fixed by m3-integ in dd8c4f2:
  autosave off).

## 5. Regressions

- **Skirmish:** byte-identical vs aaa8061 (`tools/determinism-compare.sh`, WHAT=all, seed 501, 10 minutes: 4,518 lines
  each, 0 differing). The smoke passes 65/65 with 0 errors (`m3ai-smoke7`). Every change here is Nation-only: the
  planner, council and difficulty run in Nation mode only; governor goods works read `C.cfg.goods_per_works`, which
  only difficulty.apply sets (Nation); army.lua's push escalation reads `C.army.cs_push`, which only the council sets.
- **M1 seed 501** (1 normal opponent, 60 minutes): **51/53** on 903a7b1 (produce_rts-ai-1, and train_items: 14,789 of
  20,000). The result moves with small changes of the tree:
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
2. **Hard beats normal in 5 of 10, not 7** (sections 4.4 and 4.9; the goods chain and the city-state plan are in, the
   criterion is still not met: the side swing is larger than the level's edge, and 5 seeds played both ways are too few).
   - The score follows land (a city-state taken) and population (goods). The knobs (pace, micro, intel, council
     period, opm) do not change either.
   - Next: a goods chain at every level (fixed goods works with their copper cable and bricks), so the capitals grow
     past tier 3. A hard-only city-state plan: a first army sized to the city-state's points plus artillery, sent
     before the rival's.
3. **M1 seed 501 is 51-53 of 53 from tree to tree** (section 5). It fails rail_line_<force>, train_items (goal 20,000),
   produce or age2 depending on which line opens. scripts/rails.lua gives up on a blocked piece after MAX_PIECE_FAILS
   and never retries: the player's town line in batch G stayed at piece 24 from minute 26 (sent to m3-integ).
4. **M2 starving in 701 and 702** (df6736c, c1c920d and 903a7b1).
   - 702: the planner's trade city 23, 543 tiles from the capital, had no farm spot within 13 tiles of its City Center
     (governor town_food). Its rations came by hauler and by the trunk line, and stopped for 4 minutes during a war.
   - 701 (m3-integ's diagnosis, c1c920d): rts-ai-1's mining town 12 lived on its capital supply hauler. From about
     33:00 that hauler carried batteries over 725 tiles instead. The likely cause is the planner's export policies: every
     non-capital city exports `export_goods` above 0 (planner.lua goods_policies), and the route hauler serves them.
   - Next: export policies only on cities with an open trunk line and never on a hauler-supplied town; farm spots in a
     wider ring; no trade city beyond 450 tiles.
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
8. **One seed says little about a small change.** The runs themselves are reproducible: batch K repeated batch J's
   1v1 scores to the point on seeds 901-904, where the two trees differ only in code that did not fire there. (An
   earlier version of these notes said the runs did not reproduce; the M1 differences it cited came from different
   trees.) But one seed's outcome turns on small differences (which line opens, who reaches a city-state first), so a
   single seed cannot judge a small AI change.

## 7. Commits

| Commit | What |
|---|---|
| a03e09f | first pass: planner, council, controller, intel, difficulty, resumable layout planners (with m3ai-perf) |
| df6736c | tuning 1: Age III road, air, belts, operations, rails |
| 903a7b1 | tuning 2: fort belts at war, trunk lines wait for the town line's depots and make the barracks save, the push escalation, hard's goods works (section 2) |
| a6ab6b4, cb909ac | wave B notes: acceptance runs; the starving towns in M2 701/702 |
| 3ea458e, a8d398e | wave B.2: site and farm rules, exports only from linked towns, goods chain, hard's city-state plan, uranium outpost, perf, war-paths probe; notes |
| 5a06781, cb4c563, e59259f | wave B.2 final: war-probe fixes, the city-state race; notes, re-bench |
| 73f045b | QA fix: M1 seed 501 (barracks heartbeat, labor-disabled barracks pinned, Smelting works after the second Steel works) (section 4.8) |
| 1f28ccb | hard's economic plan (section 4.9); no engine kits while the research lacks engines (section 4.10) |
| dad7a40 | QA fix 2: the heartbeat's beat and the barracks pin only below the Age I army cap and outside rail saving (section 4.11) |
| 33eb037, e098e28 | QA fix 3 on Factorio 2.1: supply haulers' coal (tank first, import, stranded haulers replaced), destroyed hubs rebuilt first (section 4.12); its M1 cost |
| (this) | QA fix 3 narrowed: the tank first only while the town is short of rations (section 4.12) |

Hunks in other owners' files: H1-H5 (section 3, applied by m3-integ in 3edd55b); H6 withdrawn. Nothing pending.

## 8. Release 0.1.1 (r2-ai: GitHub issues #1-#5 and the AI part of #7)

Date: 2026-10-24/25. Factorio 2.1.23 (Steam, mac-arm64). Agent: `r2-ai`. Base: the final 2.1 HEAD of the M3 integration
(1127c7b; its acceptance runs `m3i-p21b-*` are the "before" of every table below) and the release commits on top.

Method. Every run takes a frozen tree: `git archive HEAD` of `mods/factorio-rts` plus one **stage** of the AI work
(the AI files and `balance.lua` built from HEAD with the hunks of the issues done so far; stage 1 = #1, 2 = +#2,
3 = +#5, 4 = +#4, 5 = +#3), so a commit's measurement is exactly the committed code. 4-nation runs: 4 normal AIs,
2048, 60 minutes, seeds 801-805, `tools/probes/m3_acceptance.lua` at SPEED 8 (as the integration's e2e runs). On 2.1
the same seed diverges between trees from minute 3, and one seed's outcome turns on small differences (which nation
reaches a city-state first, which line loses a depot in a war), so the criteria are judged over the five seeds.

### 8.1 Issue #1: Age III by 40:00

**Causes** (the integration's 2.1 runs `m3i-p21b-801..805`; tools in my scratchpad: a per-nation timeline of Age II,
Electrification, Space Program and Age III, the stage-1 detail every 10 minutes, a capital-area probe):
- **Concrete** was the last good of Space Program stage 1 in 14 of 16 stage snapshots, arriving at 2-4 a minute; the
  803 and 804 players stood at 91 % and 81 % from minute 31 to the end. The Construction works rarely got a district
  spot, and the works factory on Auto loses every tie to engines, advanced circuits and beams (recipe order "g").
- **District space.** A capital fits 2-9 districts (the CC's 46x46 area holds 600-1,000 tiles of buildings, 15-22
  houses, ore and belts by minute 30; 8-11 free 7x7 boxes at minute 16, 0-6 at minute 30). The planner's list put the
  second Steel works first, so the Electronics and Petrochemical works missed out; the Petrochemical works was queued
  even without crude.
- **Electrification took 6-31 minutes** (two labs need about 2 minutes for its 25 kits). Engines sat at 0-6 for 12
  minutes while the rail programs' crafts took the steel; an aggressive or turtle AI put Aviation first.
- **No oil town** in 3 of 20 nations: the 250-tile third-city rule put a city 80 tiles from the home oil field, which
  then lay inside that city's 150-tile spacing.
- **Purchases waited in towns.** A city-state sale arrives in the own city nearest the city-state; without an open line
  the goods stayed there (the 801 leader's plastic and sulfur bought at 19-25 reached its capital at 32).
- **A branch line's keep held the oil town's crude** in the town between it and the capital (a network exports only
  above max(export_above, keep); the trunk set a keep of 3,000 at every line's near end).
- **After Electrification** the labs went on to Aviation and the like, and their industrial kits took the advanced
  circuits stage 1 waited for (801 rts-ai-3 at 93 % from minute 37 to the end).
- **The Launch complex found no spot** in one run ("no-spot", 802 player) once the area was full.
- **The commander's factory pass took every fixed factory but the builder as a workshop**: the governor's fixed goods
  works (normal and hard) and hard's goods-chain works switched recipes about 1,000 times per match (801 rts-ai-2
  #6406: 1,034) and made little. This hit every Nation AI's goods (growth) and the planner's own fixed factories.

**Changes** (stage 1 = commit for #1):
- `ai/planner.lua`: the **concrete chain** (two factories from Age II, on Auto until Electrification starts, then fixed
  on bricks and on concrete while the capital holds less than 140 concrete; pinned for workers); the **Age II district
  order** Electronics, Smelting (town ore), Petrochemical (only with an oil town or crude), the second Steel works; no
  Construction works; the Petrochemical works moved to the front once the nation has an oil town; the **oil town
  protected** from the 250-tile rule; **city-state purchases forwarded** from a town without a line and without a
  supply hauler; **a keep only where a trunk edge ends at the capital**; the **Launch complex spot reserved** from Age
  II; **engine focus** (while Electrification's remaining kits need more engines than the capital holds, the works
  factory makes engines and the rail programs pause, at most 3 of every 5 minutes); **science hold** (no research with
  industrial kits while stage 1 lacks advanced circuits or engines); stage 1's missing goods bought down to 400 cr.
- `ai/commander.lua`: factories held by the governor or the planner (`C.fixed_works`) are not workshops; the rail step
  pauses during the engine focus. `ai/governor.lua`: `hold_factory`, the planner's pins. `ai/age_up.lua`: urgent
  districts, the works factory left fixed while the planner holds it. `ai/tech.lua`: the science hold.

**Results.** First nation in Age III per seed (4 normal AIs, 2048, 60 minutes, `m3_acceptance`, SPEED 8). "Stage 1" is
this commit's code alone (batch `r2ai-a8`), "all" is stage 5, every 0.1.1 AI change (batch `r2ai-c8`); both on
a79620e.

| Seed | before (`m3i-p21b`) | stage 1 | all |
|---|---|---|---|
| 801 | 42:44 | 38:03 | 38:26 |
| 802 | 36:24 | 29:55 | 30:48 |
| 803 | 48:17 | 39:44 | 37:45 |
| 804 | 42:58 | 31:52 | 36:55 |
| 805 | 47:08 | 33:50 | 33:31 |
| **Age III by 40:00** | **1/5** | **5/5** | **5/5** |
| nations in Age III by 40:00 / by 60:00 | 1 / 14 of 20 | 7 / 19 | 6 / 17 |
| nations done with Electrification by 60:00 | 18 of 20 | 20 | 19 |

Rail linking (three cities linked by 35:00): before 12/20, stage 1 10/20, all 10/20 (per seed in section 8.2). The
earlier stage-1 batches of this round (a2, a6, a7 on 2-4 seeds each, with earlier versions of the same changes) linked
20 of 28, so over all 48 nation-runs 30/48 (62 %) against 60 % before; the misses are mostly lines lost in wars (a
town captured, a depot destroyed). One miss is this stage's: in 805 the player started Electrification at 20:00, the
engine focus paused its rail programs, and its first line's crew waited 28 minutes for its kits (opened 50:00). Stage 2
(issue #2) has the works factory make the kits: in the same seed with every change the line opened at 26:00 and the
player linked three cities at 29:00.
