# Scale vision: from a skirmish to a small state (v0.2, 2026-10-16)

Owner's direction (2026-10-16 morning): make the game much bigger and more interesting economically. Trains must have
a reason to exist; the player should build "cities" and complex interaction between them for production chains; the
map should be huge and shaped by economy and geography rather than drawn like a symmetric RTS arena. Reference points:
Rise of Nations (borders, ages, attrition, rare resources, cities as the unit of expansion) and Workers & Resources:
Soviet Republic (every good is physical and must be moved, labor and housing, infrastructure as the state's spine).
Target feel: run a small nation that builds, trades and fights.

This document is the lead's synthesis. The per-topic studies are in `research/scale/`:

| Study | File | Status |
|---|---|---|
| Territory, cities, population | `research/scale/territory-cities.md` | done, probe measured |
| Railways, trade, diplomacy | `research/scale/rails-trade.md` | done, probe measured |
| The world: huge map, regions, scarcity | `research/scale/world-map.md` | done, probe measured |
| Deep economy: tiers, money, labor | `research/scale/deep-economy.md` | done, probe measured |
| War at state scale, nation AI, performance | `research/scale/war-ai-performance.md` | done, probe measured |

## 1. What changes, in one paragraph

Today a match is one base per side on a 512-tile arena, won by destroying the enemy's buildings in 15–30 minutes.
The new game is a **nation**: several cities spread over a 2000–4000 tile world, each city a Factorio production
site with a role (mining town, steel works, capital), linked by **rails** that carry intermediate goods, growing a
**territory** that decides where you may build and where your enemy bleeds. The economy has **ages**: the state that
reaches the oil age first fields better units, but only if its refinery city gets crude by train from a region it may
not own. **Trade** with neutral city-states and with rival nations fills the gaps that geography leaves. **War** is
fought by divisions along borders and supply lines, and ends by capturing cities, not by hunting the last inserter.
A match lasts 1–3 hours and can be saved and resumed.

## 2. Pillars (what every feature must serve)

1. **Goods are physical.** Nothing teleports. Belts inside a city, haulers inside a region, trains between regions.
   Distance is the main cost, so geography and rails decide the economy (Workers & Resources).
2. **Cities are the unit of the state.** You found cities, give each a role, staff it, feed it and connect it. The
   player manages cities and lines, not inserters: districts are placed as composites and auto-wired.
3. **Scarcity forces interaction.** No region has everything. Trade, alliance or conquest is the only way to the
   next age (Rise of Nations' rare resources, Anno's island specialisation).
4. **Territory is the map's language.** Borders show reach, growth, pressure. Enemy land hurts your army.
5. **War is logistics.** Divisions out of ammo and fuel lose; rails, depots and power are the real targets. Cities
   are captured, and capturing is how you win.
6. **Readable at every zoom.** A strategic layer (ownership, lines, flows, fronts) over the Factorio world; the
   StarCraft controls stay for the tactical layer.
7. **Keep what works.** Phase 4's RTS controls, chains, hubs and haulers, research, abilities, Commander, doctrine
   AI all remain as the local and regional tiers.

## 3. Core loop of a nation (hypothesis, to be validated by the studies)

```
found city (City Center) → territory grows → claim regional resources (extractors, hubs, haulers)
→ build districts (smelting, assembly, housing, farms) staffed by workers
→ connect cities by rail (Depot ↔ Depot, script-laid rails, policy-driven schedules)
→ ship intermediates between specialised cities → research + national project → next age
→ trade surplus with city-states or rivals for what geography denied you
→ raise divisions in barracks cities, supply them from depots, hold the border, take enemy cities
→ win by capital capture / N cities held / economic dominance
```

## 4. Key design decisions to make (the studies feed these)

| Decision | Options | Lead's leaning |
|---|---|---|
| Map generation | engine mapgen with tuned noise; scripted; hybrid | hybrid: engine terrain and water, script regions, resources, cities, starts |
| Territory model | chunk ownership; cell grid 8×8; influence field | 8×8 cells with influence from cities/forts, recomputed incrementally |
| Population | item in a city chest; script number; both | script number per city with needs met from city stockpiles |
| Money | none (pure goods); currency item; script ledger | script ledger ("treasury") earned by exports and taxes; goods still physical |
| Ages | 3 ages gated by research + national project | yes; Age 3 includes nuclear and artillery trains |
| Rails | fully manual (vanilla); click A→B auto-lay | auto-lay with manual override; signals automatic |
| Armies | individual units; formations/divisions | divisions as the default command object, micro still possible |
| Victory | annihilation; capital capture; score | capital capture or hold N cities, with annihilation as fallback |
| Match length | 20 min; 1–3 h with saves | 1–3 h, save/load first-class |

## 5. What the studies found (verdicts)

The engine is not the limit; design and the AI are. Every study ran a headless probe on the real game.

| Question | Answer | Evidence |
|---|---|---|
| Territory on a 2048² map | cheap: full recompute 4–5 ms, borders as 2,600 line runs, drawn objects add no update cost | `territory-cities.md` §5 |
| A world of 2048–4096 tiles | engine generates 2048² in 11 s and 4096² in 42 s; idle cost 0.17 ms/tick; 4096 is too big for pacing (7.5 min march), default 2048 for 3–4 nations | `world-map.md` §4 |
| Script-laid 2.0 rails | yes: geometry learned from the engine (32 end states), A* line around a lake, elevated bridge over 40 tiles of water, train runs a scripted schedule at 28 tiles/s | `rails-trade.md` §8 |
| Labor throttling vanilla machines | yes: a hidden module with −40 % speed gives exactly 0.60 output; zero staff needs `disabled_by_script`; per-force recipe productivity works on any recipe | `deep-economy.md` §8 |
| Unit counts | 2,000 moving spider-units 4.6 ms/tick; 4,000 drones 2.9 ms; 1,000 vs 1,000 battle 5.1 ms mean with 27 ms spikes; one order to 1,000 units costs a 25 ms tick (pathfinder) | `war-ai-performance.md` §1 |
| Factories and trains | 20,000 production entities 0.31 ms/tick, 81,000 1.2 ms; 160 trains on 40 km 0.3 ms | same |
| City capture | writing `force` works for every RTS entity; 5,000 entities flip in 18.6 ms (slice to 500/tick) | same |
| Air units | a `unit` with no collision crosses walls and water | same |
| Fog | AI forces are never charted, so AI vision stays script-based (as today); one human force on 2000² costs +0.2 ms | same |

Open items the probes did not settle: client-side draw cost of thousands of border lines and whether chart-mode
render objects appear on the HUD minimap (GUI check), the mountain tile against every unit class (crossing probe),
rail planning on real terrain with trees and cliffs (one day of probes before any rail GUI work), and a GUI client
that stopped ticking in the world probe (likely window focus).

## 6. Synthesis: the design, with overlaps resolved

Five studies proposed overlapping mechanisms. These are the single versions we build.

**One ownership lookup.** An 8×8-cell grid stores `force` and `city` per cell (`territory.lua`). Sources: City
Centers (radius by tier), forts, hubs, radars. Everything reads it: build rules (economic buildings only on own land,
forts on neutral land, nothing on enemy land), which city staffs a building, which market a need is delivered to,
attrition, capture, victory, AI region scoring. Borders are drawn once per change, chart lines at strategic zoom.

**One city entity.** The City Center replaces today's CC as the unit of the state. The capital is the first one. Tiers
village → town → city raise land radius, building slots, supply and recruits. Population is a script number per city
with needs (rations, goods, power, later luxury) expressed as *keep* targets on the city's market network, so food
and goods arrive by the existing haulers, robots and later trains. Staffing: a building draws workers from the city
whose land it stands on; shortfalls switch off the lowest-priority buildings ("No workers"); partial staffing throttles
through hidden labor modules. Units cost **recruits** drawn from population, so war bleeds the economy.

**One policy language.** *Keep / make / export* per good per node (city market, hub, depot). It drives factory
auto-recipes, hauler dispatch (regional), the train dispatcher (national), trade at ports and the AI. The player sets a
handful of numbers per city; defaults come from city archetypes (mining town, steel works, capital).

**Three logistics tiers with a real cost curve.** Belts inside a city; haulers inside a region (in Nation mode they
burn 1 coal per 40 tiles and carry 10 slots, so they lose beyond ~300 tiles); trains between regions. A **Depot** is a
hub plus a train stop. Rails are laid by clicking Depot A → Depot B: the planner (coarse grid, then A* on the learned
rail geometry, time-sliced over ticks) produces ghosts incl. elevated spans, and a **construction train** builds and
repairs them. The AI uses the same code. Cut rails leave ghosts, so sabotage is repairable.

**Districts, ages and national projects.** Today's content is Age I. Age II (oil → plastics, sulfur, engines, trains,
advanced circuits) and Age III (processing units, nuclear, robots, high-tech units) reuse vanilla's recipe graph. A
*district* is one large machine with a compressed multi-stage recipe, fed from the city network and staffed; hand-built
Factorio lines remain and need fewer workers, so Factorio skill still pays. Each age needs research plus a **national
project** site in the capital that trains must feed (Railway Charter → Industrialisation → Space Program). Science
kits of Age II need goods from three cities, so research becomes logistics.

**Scarcity portfolio.** Every nation gets the same start kit within 150 tiles and a home specialty of equal value but
different kind. Only two large copper regions on a 4-nation map; oil in swamps; uranium on contested ground behind
research; rare deposits give nation-wide productivity bonuses while held. City-states and trade ports sit on the scarce
sites: trade, ally or conquer.

**Money as a treasury, trade as goods.** A script-side treasury per nation. Nothing is built with money; it pays
upkeep, soldiers and imports. Income from taxes (by resident tier and happiness) and exports delivered to trade ports.
A shared world market prices goods by supply (p = p₀·(S₀/S)^0.6), moved by AI nations too; a commerce cap limits trade;
debt has three recoverable stages (deficit → strike → unrest). Payment settles on physical delivery, so raids hit
cargo. Fallback if playtests reject money: goods-only upkeep and barter.

**Diplomacy.** States: war, ceasefire, peace, alliance (engine `set_cease_fire`/`set_friend`/shared charts). Relations
move with trade, border pressure and war score; AI nations declare war past relation and power thresholds and accept
ceasefire past weariness. Contracts, embargoes, border exchange depots.

**War is divisions and supply.** A division is one engine unit group with a template, a stance and a **supply meter**;
it paths once instead of 16 times, and an order queue caps path requests at ~100 per tick. Supply is refilled at depots
from factory-made crates that trains or haulers deliver; out of supply means −40–60 % damage and attrition, and enemy
land deep beyond your supply sources bleeds 18 % HP/min. Garrisons and troops on trains exist as records, not entities.
Fronts and fortification belts along borders, troop/supply/artillery/armoured trains, air units (scout plane, bomber,
anti-air). **Cities are captured, not destroyed:** a City Center cannot die; subdued below 10 % HP, a 20-second contest
(the ruin rule) flips the city, its land, its economic buildings and 70 % of its population. Victory: capture the
capitals, hold 60 % of claimable land for 3 minutes, Space Program, or annihilation as fallback.

**Readable at scale.** Remote view switches to the chart past the furthest game zoom; chart-mode render objects carry
region names, borders, rail lines, trade flows, fronts and choke markers; the minimap becomes regional (~1,000 tiles)
with a world toggle; alerts name regions. The StarCraft controls remain for the tactical layer; map-view and minimap
right-click give strategic orders.

**One nation AI.** Layered: strategist (every 10 s: expansion, age-up, war/peace, trade), a governor per city (today's
doctrine commander generalised to city templates), a war council and a controller per division (today's `army.lua`),
plus the rail planner on prefabs. It runs on a deterministic work-unit scheduler at ≤ 0.5 ms/tick per nation with
resumable state machines in `storage`. The AI and the player share the same automation (districts, policies, dispatch,
labor priorities), so the AI only sets about ten knobs per city.

**Two modes stay.** *Skirmish* is today's game (arena, 15–30 minutes). *Nation* is the new mode (world map, 1–3 hours,
save/load first-class). Shared code, separate balance tables.

## 7. Plan: three milestones

Total effort across the studies is about 165 agent-days before removing overlaps; de-duplicated and sequenced it is
about 135–145 agent-days, run 4–6 agents in parallel per wave with a lead integrating, so roughly 8–10 working
sessions of the kind that built Phase 4. Each milestone ends playable, headless-validated and Codex-QA'd.

### M1: "Two cities and a railway" (≈ 45 agent-days)

Goal: found a second city at a far ore region on a real 2048 world, connect it by rail, reach Age II. The AI does the
same on normal.

| Work package | From study | Days |
|---|---|---|
| W1 playable 2048 world: terrain skeleton, mountains and fords our units respect, spawn scoring, start kits, lobby "World" map; crossing probe | world | 6 |
| T1 territory grid, borders, build rules, attrition, forts | cities | 5 |
| C2-lite City Center tiers, founding, land, city panel (population and needs deferred) | cities | 4 |
| R1 rail backbone: depot, rails/locomotive/wagon kits, planner, construction train, train panel; terrain probes first | rails | 7 |
| E1 Age II districts, ages and the Railway Charter project, make targets and auto-recipe, city ledger | economy | 12 |
| Divisions and the order queue (W1 part): division model, stances, reinforcement flow, division HUD | war | 5 |
| Nation-mode hauler costs, two-mode balance tables, lobby, save/load matrix | lead/integration | 3 |
| Integration, QA protocol, Codex run | integration | 3 |

Acceptance: a 60-minute headless 1v1 on a 2048 world with 0 errors at 60 UPS where both sides found a second city,
lay ≥ 1 rail line, move ≥ 20,000 items by train and reach Age II; the GUI protocol covers founding, rail laying,
districts and a division order.

### M2: "People, money and war goals" (≈ 50 agent-days)

Population, needs, housing tiers, labor and recruits (C2 rest); treasury, taxes, upkeep, trade ports, world market,
contracts and diplomacy (E2, R3); dispatcher and military trains (R2); supply crates, depots, attrition, capture,
garrisons, fronts, war goals, treaties, victory modes (war W1 rest + W2 part); regions, scarcity portfolio,
city-states, chokes, strategic layer (world W2); AI governor for cities and trade (cities C2 AI + economy E2 AI).

Acceptance: a 4-nation 60-minute AI-vs-AI match with trade, one war declared and one peace signed, at least one city
changing hands, no nation starving in > 10 % of seeds; save/load at 20 and 40 minutes.

### M3: "A state at war" (≈ 45 agent-days)

Age III and the Space Program (E3), rare resources and nation-wide bonuses, air units and anti-air, artillery and
armoured trains, fort belt planner (war W2 rest), the full layered nation AI with the rail planner and difficulty
without cheats (war W3 + economy E3 AI), huge maps with background generation (world W3), performance pass to the
budget: 4 nations, 16 cities, 600 units, 40 trains at 60 UPS; a two-client LAN desync check.

## 8. Risks, ranked

1. **Nation AI competence** (all five studies): mitigated by making the AI and the player share one automation layer,
   prefab templates on a coarse grid, resumable planners, and a planner-first validation harness before GUI work.
2. **Player overload**: districts, archetype defaults, one city ledger, alerts with region names, an auto-governor the
   player can delegate a city to.
3. **Rail planning on real terrain**: one day of probes on generated maps before R1 GUI work; coarse pre-pass and
   time slicing (a lake made one plan take 367 ms in a single tick).
4. **Pathfinder spikes**: divisions and the order queue; division size 12–16; garrisons as records.
5. **Pacing and empty land**: 2048 default, size scaled by nation count, 30–40 % low-value land, trains and divisions
   make distance a decision rather than a wait.
6. **Hauler economics**: if haulers stay as cheap as today, trains are decorative; the Nation-mode cost change is a
   prerequisite, not a tuning detail.
7. **Unmeasured client costs**: border lines and chart objects on screen and on the minimap; checked in the first GUI
   run of M1 with a fallback of chart-only lines.

## 9. Decisions requested from the owner

1. Approve the two-mode structure (Skirmish kept, Nation added) and the 1–3 hour match with saves.
2. Approve money as a treasury (recommended) rather than a goods-only economy.
3. Approve capture-not-destroy and the victory set (capitals, 60 % land, Space Program).
4. Space Age stays optional but recommended (bridges and spoiling food need it; the base game gets landfill causeways
   and non-spoiling rations).
5. Start with M1 as scoped above.
