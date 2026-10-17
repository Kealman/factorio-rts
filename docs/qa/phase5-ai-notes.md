# Phase 5 M2, wave B: the nation AI (ai/nation.lua, ai/governor.lua) and the AI regressions of wave A

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m2-ai`. Contract: `docs/PHASE5-M2.md` (D9,
§3 "ai/nation.lua / ai/governor.lua", §4 end-to-end acceptance). Inputs: the wave A notes
(`docs/qa/phase5-{people,treasury,diplomacy,war,world2}-notes.md`, their "open issues" and "handed to wave B") and
`docs/qa/phase5-m1-integration-notes.md`. Base: `mods/factorio-rts` at 792206e (tag m2-wave-a), with m2-integ's
uncommitted wave B hunks in the tree while this package was tested. Everything here is Nation mode only; Skirmish runs
exactly as before.

## 1. Verdict

The package acceptance (§4 "M2 end-to-end", run by m2-ai before the hand-over) passes on all five seeds except one
criterion in one seed: every nation trades, wars and peaces happen in 5 of 5 seeds, cities change hands in 5 of 5,
no city starves in any seed, every AI founds a town, and 19 of the 20 AIs open a rail line (the twentieth lost its
town to a war one minute before its finished line could open). The strategist and the governors together cost
0.022-0.025 ms per tick for four nations; the whole AI 0.41-0.48 ms per tick on a machine running ten servers. The M1
acceptance (1v1, seed 501, 60 minutes) passes 53/53 with 26,492 items by train (wave A: 20,125) and 60 UPS in
minutes 56-60. The Skirmish smoke is 65/65 and the 1v1 Skirmish AI run on seed 777 logs the same 3,279 `[rts]` lines as
HEAD. 0 Lua errors in every run.

| Seed (4 normal AIs, 2048, 60 min, SPEED 10, PERF 1) | Wars declared | Peaces | Cities changed hands | Starving cities | Towns | Rail lines | Trade per nation (cr) |
|---|---|---|---|---|---|---|---|
| 701 | 3 | 2 | 5 (3 city-states) | 0 | 4/4 | 4/4 | 6,972 / 8,687 / 9,119 / 9,123 |
| 702 | 5 | 4 | 4 (2 city-states) | 0 | 4/4 | 4/4 | 6,594 / 9,035 / 9,632 / 7,348 |
| 703 | 5 | 4 | 7 (1 city-state) | 0 | 4/4 | 3/4 | 4,532 / 9,164 / 6,812 / 4,856 |
| 704 | 4 | 3 | 7 (5 city-states) | 0 | 4/4 | 4/4 | 6,154 / 9,012 / 8,003 / 6,882 |
| 705 | 4 | 3 | 4 (2 city-states) | 0 | 4/4 | 4/4 | 6,669 / 7,434 / 3,519 / 9,105 |
| Criterion | >= 1 in >= 4 of 5: 5/5 | >= 1 in >= 4 of 5: 5/5 | >= 1 in >= 3 of 5: 5/5 | in <= 1 seed: 0 seeds | every AI | every AI: 19/20 | > 0 for every nation |

Run: `KEEP_TREE=<HEAD 311a5b5 + scripts/ai> PERF=1 DURATION_MIN=60 SEED=<701..705> SPEED=10 tools/autotest-run.sh
p5m2ai-n6-<seed> '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}'
4800`; the numbers are the autotest's "ai autotest m2ai summary" line (wars from `storage.wars`, peaces from
diplomacy's stats, captures from the `rts_city_captured` signal, starving = a city below 50 % rations for more than 3
minutes in a row). The doctrines are the autotest's: rts-player economic, rts-ai-1 aggressive, the other two drawn
(turtle and economic on these seeds). m2-integ's own probe (`tools/probes/m2_acceptance.lua`) records the same
criteria for the integration run.

On the same seeds wave A (HEAD 792206e) had no war and no capture on 701, no coal for 2-3 forces per seed (0 hauler
trips, no train), and no town or rail line for some AIs.


## 2. Design as built

### 2.1 Where the AI runs

`ai/commander.lua` runs every AI commander every 60 ticks (staggered). The order of a run is unchanged up to the
production part; the M2 parts sit at its end and have their own profilers (`ai perf minute N parts`):

| Part | Every | What |
|---|---|---|
| `build_order` | run | the build order, then `build_order.bootstrap` (2.4) |
| `construction` | run | revives, `hubs.step`, `rails.ai_step`, `cities.ai_step`, `towns.step`, `market.ai_step` (envoy, route, wanted, buy) |
| `tech`, `age_up`, `barracks`, `production` | run | research, the age-up program, the barracks mix, the factories (split out of the old "production" part) |
| `governor` | each city every 300 ticks | `ai/governor.lua` (2.3) |
| `nation` | 600 ticks per nation | `ai/nation.lua` (2.2) |
| `army` | run | `ai/army.lua` incl. warsupply's crate policy, capture operations and town relief (2.5) |

`population.ai_step` (m2-people's first governor) is no longer called: the governor takes its rules over.
`market.AI.taxes` and `market.AI.sell` are switched off (the strategist runs taxes and sales), `diplomacy.AI_SELF_SCHEDULE
= false` (the strategist calls the doctrine table once a minute) and `army.capture_ok` is the strategist's.

### 2.2 The strategist (`scripts/ai/nation.lua`, every 10 s per AI nation)

| Part | Rule |
|---|---|
| Taxes | `market.ai_taxes`: low below happiness 40, high at war (`wars.active`) or while losing money below the deficit floor, normal otherwise |
| Sales | every good at its ports, most valuable first, until the commerce cap; a good waits while its price is below `sell_floor` (0.75) x p0; coal above `coal_reserve` (300: the haulers' fuel home) only; goods a contract owes stay at the port; goods bought by contract are not sold again for 20 minutes |
| Purchases | `market.lua`'s `ai_buy` (a capital shortfall it cannot fill in 3 minutes) and `ai_wanted` (port goods the capital lacks are hauled home) |
| Contracts | from minute 10, at most one at a time, a new proposal at most every 3 minutes: for an ore of `world.scarcity()[force].lacks`, 5 x 100 every 120 s at the market price from the nation at peace it likes best (relation >= 0) whose port holds at least 200 of it; proposed through `diplomacy.propose(..., "contract", ...)`, the seller's AI answers; the buyer cancels a contract after its first missed delivery (each miss costs 8 relation) |
| War and peace | `diplomacy.ai_step` (the doctrine table) once a minute; easy AIs never declare war (diplomacy.lua) |
| Opportunity wars | matches of 3+ nations, from minute 20, at most one per 20 minutes and AI: in Age II, at peace with everyone and with an idle army of `pool` units, a rival town within 1,400 tiles of the capital holding at most `defenders` defence points (units within 40 tiles, garrison points, 4 per gun turret within 30 tiles), relation below `r`, power ratio above `ratio`: war with the goal "conquest" of that town (aggressive r 0, ratio 0.8, 8 points, 12 units; economic -25, 1.2, 4, 16; turtle -30, 1.3, 4, 20). A met goal ends the war in a cession (wars.lua), so a won opportunity war is a war, a capture and a peace |
| Garrison | when a war starts: `garrison_share` (25 %) of the idle army, 4-8 units nearest the capital, enter its garrison (hidden turrets, `garrison.enter_units`); at peace they sortie and the division is disbanded back into the army |
| Capture operations | `army.capture_ok`: a war with goal cities (`wars.targets`), or (not easy) Age II, minute 20+, at peace, no rival division within 400 tiles of the capital: city-state operations (2.5) |
| Found, age | unchanged (`cities.ai_step` with `ai/towns.lua`, `ai/age_up.lua`) |

### 2.3 The governor (`scripts/ai/governor.lua`, every 5 s per city)

| City | Rule |
|---|---|
| every city | needs keeps (rations, goods: 2 minutes of need, at least 50 / 20); the doctrine's draft once; a house while the housing is short (before 5:00 free housing below 20, then the residents its jobs need / 0.6 + 80), at most 3 pending, 10 s apart |
| capital | labor priorities (power, food, extraction, metallurgy, research, military, services, electronics, chemistry); pins: builder, workshop, the age-up works factory, the first lab; goods make target = its keep + every town's keep + 10, bricks 20, 3 houses in stock; ships rations and goods above its keep + 10; the first farm (and the first bakery with it) when the rations run out within 6 minutes, then one per 200 residents of the nation fed from the capital (a bakery per 2.5 farms); the goods works (an Auto factory) when the goods run out within 6 minutes, a second one when a town stalls at its goods need while the capital has none to ship; a supply hauler to every town; magazines above 20 shipped while towns have turrets |
| town | its extractors and smelters pinned (extraction first); 2 gun turrets towards the nearest rival inside its logistic area, 20 magazines kept; its own farm and bakery from 60 residents or when its rations run short (both at once when short: a captured town or city-state); its two stockpiles rebuilt when they were razed (a captured city-state could store nothing and starved); an export hauler to the nation's port while the town holds more than 1,500 ore and plates (released below 300); crates are `warsupply.ai_step`'s (every non-capital hub, City Center and depot keeps 20) |
| raw lines | once the steel flows, one more stone extractor when stone falls below 100, one more copper extractor (and slot) when copper falls below 30, at most every 2 minutes; houses wait while the rail line is built and stone is below 150 |

Before the capital's steel flows (or Age II): town houses and turrets wait, the goods works waits unless the goods last
less than 2 minutes, the supply haulers wait unless a town holds less than 4 minutes of rations, and the town's mining
line waits up to 4 minutes (`ai/towns.lua`). Nothing that costs copper is queued while the start copper line does not run.
While Industrialisation is researched or the Charter is built, the goods make target is one minute of the nation's need
(the copper goes to the advanced kits' circuits). **Food emergency**: while no bakery stands and the capital's rations
last less than 3 minutes, the goods and the age-up make targets pause so that the bakery gets its copper. The first
bakery is queued with the first farm.

### 2.4 Build order, start lines and the town (`ai/build_order.lua`, `ai/commander.lua`, `ai/towns.lua`)

- **Copper bootstrap** (`build_order.bootstrap`, Nation): while the copper line has no running drill and slot and the
  network holds fewer than 40 copper plates, its first drill and slot are queued and moved to the front of the queue,
  and nothing else takes copper meanwhile (`C.boot`: the age-up make targets and the goods works pause, the workshops
  and barracks skip recipes with copper, cable or circuits).
- **Copper at the start**: when the first plan finds no slot for the copper line, two more passes plan copper first
  (then iron or stone); kept when iron keeps its slots but one and its steel chain.
- **Coal at the start**: the coal-first passes are kept when copper and stone keep their slots, iron loses at most one
  and keeps its steel chain slot; otherwise the coal hub (now tried on the three nearest coal patches); then the
  cheapest "relaxed" pass (copper and stone in other slots of the same kind, at most 40 more belts on the other lines,
  stone keeps its drill spots but one, the steel chain kept); then a **coal pit**: a hub next to the coal patch whose
  network joins the CC's and two extractors that drop straight into stockpiles inside its logistic area, powered by a
  short pole chain from the hub (no belt to route). A fourth pass routes stone and copper before iron.
- **Town site**: no patch within 140 tiles of another force's city (city-states included).
- **Town line in Age I** waits for the capital's steel (at most 4 minutes).
- **Research**: Railways right after Industrialisation (it unlocks the Rail works since m2-integ's wave B change).
- **Age-up** (`ai/age_up.lua`): the first district whose recipe the force has (a locked Rail works no longer blocks the
  list); a district, Bunker or warehouse stockpile without a spot is looked for again after 60 s, not every 5 s; the
  make targets pause during a food emergency or the copper bootstrap.

### 2.5 Army (`ai/army.lua`)

- **Relief**: damage to an own building on a town's land (far from the capital) records `army.town_threat[city]`; a
  relief group of half the idle pool (at least 6) goes there as a "defend" group, follows the town's latest threat for
  20 s after the last hit and then returns. Base defence never takes over a relief group.
- **City-state operations** (with `army.capture_ok`): only city-states at most 0.8 x as far from the capital as from the
  nearest rival capital, with no rival division within 150 tiles, plus the existing rules (group >= 1.5 x the garrison
  points, supplied, one operation per 15 minutes).
- **Barracks** (`ai/mix.lua`, Nation): a unit kind that made no unit for 3 minutes rests like a starved one (an Armoured
  car kit waited 8 minutes for engines that trickled in, and the economic AI made no unit with an army of 16).

### 2.6 Difficulty

| Difficulty | Nation mode |
|---|---|
| easy | never declares war (diplomacy.lua) and no opportunity war; sells at any price and its capital ships to the port from half the surplus thresholds (it trades at a loss); no city-state operations |
| normal | the tables above |
| hard | +20 % tax income (`balance.nation.treasury.tax.hard_bonus`, treasury.lua) and nothing else: the Skirmish cheats (extra stock, mining bonus, a free unit per 4, full vision) are off in Nation mode (`commander.NATION_NO_CHEATS`) |

## 3. Wave A regressions: causes and fixes

| Regression (brief) | Cause (AI side unless noted) | Fix |
|---|---|---|
| (a) 1v3 Nation seed 611: rts-ai-1 iron-starved from minute 4, no copper line, no Age II, no town | At 5:00 m2-people's governor put its goods works (20 copper) and a bakery (10 copper) at the front of the construction queue. The aggressive AI's copper extractor (build step 14, queued at 1:35) was still waiting; the builder then waited for copper that no line made. Iron piled up behind the same queue. | Copper bootstrap (2.4); the governor queues nothing that costs copper before the copper line runs |
| (b) 1v1 seeds 402-404: rts-ai-1 without a copper line / Age II after 20:00 | The same deadlock (402, 403: copper 0 from minute 7 for 60 minutes) | as (a) |
| (c) Age II about 3 minutes later than at M1 | People costs in minutes 5-12, all on the road to Industrialisation: farms, a bakery and the goods works queued at the front at 5:00 (about 200 iron), the town's 90 parts queued ahead of the steel chain, the goods works' copper cable competing with the circuits of Industrialisation's 20 advanced kits, the goods works pinned ahead of the labs | Food and goods by forecast, town line and town extras after the steel chain, goods held to one minute of need on the road to Age II, only the age-up works factory pinned (2.3, 2.4) |
| (4) 4-nation 60-minute runs: economic AIs make 0 hauler trips and open no rail line | No coal: on M2 worlds the start coal line found no slot for about one force in three and the coal-first passes were rejected by an exact-slot rule; the coal hub then failed too. Haulers stood "no-fuel" and trains were never deployed (2 coal needed). Also: a town line routed onto a rival's land (seed 702, 220 parts given up) | Coal planning passes, coal hub on three patches, coal pit fallback (2.4); town sites away from other forces' cities |
| Found on the way: a force with no copper line at all (seed 704) | The copper line found no hub slot in the first plan | Copper-first passes (2.4) |
| Found on the way: Industrialisation never researched (seeds 403, 404, 701) | A coal pass that kept the slot count but dropped or moved the iron line's steel chain slot: no steel all match | Passes keep the first plan's steel chain slot |
| Found on the way: the builder asked 600 times for a locked district item | m2-integ moved the Rail works to the Railways technology (Age I); the age-up program still queued it as an Age II district | Age-up skips locked districts; Railways right after Industrialisation |
| Found on the way: capitals starving (seeds 704, 705) | The bakery waited for copper while the Auto factories took it, or never came at all (no copper) | First bakery with the first farm, food emergency (2.3) |
| Found on the way: a rail line stuck at 143 of 166 pieces (seed 703) | Houses took the stone the rails need (1 stone per 2 rails since m2-integ's rail cost) | Houses wait for the rail line below 150 stone; one more stone extractor when stone runs short |

## 5. Files

| File | Status | What |
|---|---|---|
| `scripts/ai/nation.lua` | new | the strategist (2.2), `nation.capture_ok`, `nation.describe` |
| `scripts/ai/governor.lua` | new | the city governors (2.3), `governor.describe` |
| `scripts/ai/commander.lua` | changed | calls `governor.step` / `nation.step` instead of `population.ai_step`, switches `market.AI.taxes/sell` off, profiler parts (tech, age_up, barracks, governor, nation), start-line passes for copper and coal, Nation-mode hard without Skirmish cheats, workshops skip copper recipes in the bootstrap |
| `scripts/ai/build_order.lua` | changed | `build_order.bootstrap`, `build_order.line_running` |
| `scripts/ai/towns.lua` | changed | coal hub on three patches, coal pit, town site away from other cities, town line waits for steel |
| `scripts/ai/army.lua` | changed | town threats and relief groups, city-state filters |
| `scripts/ai/age_up.lua` | changed | locked districts skipped, placement retry, make targets pause in a food emergency or the bootstrap |
| `scripts/ai/mix.lua` | changed | barracks skip copper kits in the bootstrap |
| `scripts/ai/tech.lua` | changed | Railways right after Industrialisation |
| `scripts/ai/hubs.lua` | changed | `C.route_haulers` (export routes) in the hauler target |
| `scripts/ai/autotest.lua` | changed | minute line "m2ai", the summary line "ai autotest m2ai summary" (metrics only, no new checks) |
| `balance.lua` | `*.ai` sub-tables only | `balance.nation.people.ai` (governor knobs), `balance.nation.diplomacy.ai` (new: the strategist), `balance.nation.market.ai` (town export), `balance.nation.war.ai` (town defence, relief, city-state filters) |

Nothing outside `scripts/ai/` and those balance sub-tables was edited. For m2-integ: `population.ai_step` and
`population.ai_describe` are no longer called (dead code in `scripts/population.lua`).
