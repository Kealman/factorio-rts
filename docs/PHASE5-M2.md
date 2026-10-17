# Phase 5, milestone M2: "People, money and war goals"

Owner direction 2026-10-16 evening: continue through every milestone without pausing for approval. The lead decides;
decisions are listed in §0 and reported after the fact.

Goal of M2: a **nation** has people, a treasury and a reason to fight. Cities grow from supplied population and
staff their buildings; a treasury pays upkeep, soldiers and imports and earns taxes and exports through trade ports on
a shared world market; nations keep relations, declare wars with goals, sign peace, and **capture cities instead of
razing them**; divisions need supply crates from depots and can ride troop trains; the world gets regions with names, a
scarcity portfolio, city-states and a readable strategic layer. Four normal AIs play a 60-minute match against each
other with trade, at least one war and one peace, and at least one city changing hands. Every Skirmish behaviour stays
exactly as in Phase 4; every M1 Nation acceptance keeps passing.

Studies: `research/scale/*.md` (sections cited below). M1 contract: `PHASE5-M1.md` (its APIs are the base). This
document is the contract between the M2 work packages.

## 0. Decisions (lead)

| # | Decision | Why |
|---|---|---|
| D1 | **Treasury is a script number** per nation ("crowns", cr). Nothing is built with money; money pays upkeep, soldiers and imports and comes from taxes and exports. Imports arrive as goods at a trade port after 30 s. Debt has three recoverable stages. | `deep-economy.md` §4.1 design C; coins as items would clutter every network. |
| D2 | **Population, settlers and recruits are numbers**, not items. Founding a city moves 40 settlers out of the source city (the charter kit already represents them); a kit drafts `supply` workers from the barracks' city. | Fewer failure modes than person-items; the charter flow exists. |
| D3 | **Staffing acts through hidden labor modules** in 20 % steps (speed and consumption −0.2 … −0.8), `disabled_by_script` plus `custom_status` "No workers" at 0 %. Districts, factories, extractors, smelters, barracks, labs, farms get one hidden module slot restricted to the `rts-labor` category. | Probe-verified in `deep-economy.md` §5.5 and §8.2; output is smooth and nothing is written per tick. |
| D4 | **Cities are captured, not destroyed.** A City Center (and the Nation-mode CC) cannot die: below 10 % HP it is *subdued*; 20 s with attacking military units within 24 tiles and no defenders flips the city, its land, every economic building on it and 70 % of its population; 60 s of unrest; the loser's capital moves to its largest remaining city; a nation with no city left is eliminated. No razing in M2. | `war-ai-performance.md` §2.5, `territory-cities.md` W3; the ruin already runs the contest. |
| D5 | **Trade is a shared world market reached through trade ports** (world sites of kind `port`, captured like the ruin). Prices `p = p0·(S0/S)^0.6` clamped 0.4–3×, 5 % drift per minute, commerce cap 300 cr/min + 150 per port + 25 % per Commerce level. **Contracts between nations** are a fixed-price scheduled sale settled at the two nations' ports (goods leave the seller's port stock, appear at the buyer's port after 30 s). No border exchanges, tariffs or embargoes in M2. | Avoids the unverified "trains on foreign track" question (`rails-trade.md` §4.6). |
| D6 | **Victory in Nation mode:** *Conquest* (every rival capital captured or every rival eliminated), *Territory* (45 % of the claimable cells, or twice the land of the next coalition with at least 3 % of the claimable cells, for 3 minutes; wave B integration: 60 % was about 53 % of a 2048 map while 4 nations of 10 cities own about 20 %), *Score* at the lobby time limit (60/90/120 min/unlimited; score = population + treasury/10 + land cells + units' supply). Annihilation stays as the fallback (no City Center left). | `SCALE-VISION.md` §6. |
| D7 | **City-states** are 5–6 neutral cities (force `rts-neutral`) on scarce sites with a City Center, a stock of their region's goods and a turret garrison that grows with time. They can be captured (D4) and their land counts as claimable. Trading with city-states is M3. Ruins stay as today (8–12 on low-value land). | `world-map.md` §5.3. |
| D8 | **Troop and supply trains in M2**; armoured and artillery trains, fronts, fort belts and air units move to M3. | Gives trains a military role at low risk (`rails-trade.md` §3 manifest). |
| D9 | **AI in M2** is a *nation strategist* (every 10 s: taxes, trade orders, found/age decisions it already has, war and peace by the doctrine table) over the M1 governors; the full layered AI with difficulty-without-cheats is M3. | Keeps the AI package bounded; the acceptance only needs trade, one war, one peace, one capture. |

## 1. Shared rules (in addition to `PHASE5-M1.md` §1)

- Everything in this milestone is **Nation mode only** (`match.config().mode == "nation"`), except the diplomacy
  targeting audit, which must keep Skirmish behaviour identical (all pairs at war, as today).
- `storage.nations[force]` grows: `{capital, age, treasury, tax = "normal", relations = {[other] = r}, wars = {...},
  score}`. Each module adds its own fields under its own key and clears them in its `on_match_teardown`.
- New forces: `rts-neutral` (city-states; `set_cease_fire` false with everyone, never attacks beyond its turrets).
  `match.lua` creates it in Nation mode; `fog.lua` keeps it uncharted.
- New balance: `balance.nation.people`, `.treasury`, `.market`, `.war`, `.diplomacy`, `.world` tables (pure data).
- Every new per-minute loop runs on `events.on_nth_tick` staggered per city/nation (one city every few ticks), budget
  ≤ 0.5 ms/tick for all M2 modules together at 4 nations × 4 cities.
- Logging prefix per module (`util.log("people: …")`, `treasury:`, `market:`, `diplomacy:`, `war:`, `capture:`,
  `world:`), as autotests grep the log.

## 2. Work packages, owners and files

| Package | Agent | New files (owner edits freely) | Shared files it may touch (small hunks marked `-- Phase 5 M2 <pkg>`) |
|---|---|---|---|
| People and labor (C2 rest, E2 labor) | `m2-people` | `scripts/population.lua`, `scripts/labor.lua`, `prototypes/people.lua` (houses, farm, bakery, fishing hut, labor modules, rations/goods items), `locale/*/people.cfg` | `cities.lua` (tier rule by population, found moves settlers), `citygui.lua` (population, needs, workforce, priorities), `production.lua` (kit gate "no recruits", staffing factor), `districts.lua` (`staffing_factor`), `supply.lua` (recruits), `ai/*` (governor keeps rations/goods, draft by doctrine) |
| Treasury and market (E2 money, R3 trade half) | `m2-treasury` | `scripts/treasury.lua`, `scripts/market.lua`, `scripts/marketgui.lua`, `prototypes/trade.lua` (trade post composite at ports), `locale/*/treasury.cfg` | `hud.lua` (treasury in the strip, balance colour), `logistics.lua` (port = hub subtype), `world.lua` (port sites → entities), `research.lua` (Commerce I/II), `ai/*` (sell surplus, buy shortfalls, tax level) |
| Diplomacy, wars and victory (R3 diplomacy, W2 war goals) | `m2-diplomacy` | `scripts/diplomacy.lua`, `scripts/wars.lua`, `scripts/diplomacygui.lua`, `locale/*/diplomacy.cfg` | `match.lua` (victory modes, time limit, `rts-neutral`), `lobby.lua` (victory/time limit drop-downs, Nation only), `orders.lua`, `ai/army.lua`, `raids.lua`, `abilities.lua`, `fog.lua` (targeting audit: `diplomacy.hostile(a, b)` instead of "other force"), `hud.lua` (alerts with Accept/Decline, results window war score), `ai/*` (decision table) |
| Supply, capture, garrison, military trains (W1 rest, R2 part) | `m2-war` | `scripts/warsupply.lua`, `scripts/capture.lua`, `scripts/garrison.lua`, `prototypes/war.lua` (supply crate, field depot, troop wagon kit, hidden garrison turret), `locale/*/war.cfg` | `divisions.lua` (supply meter, penalties, garrison/embark orders), `divisiongui.lua` (supply bar), `rails.lua` (troop wagon, manifests, "disband train → 50 % kits"), `territory.lua` (flip city cells), `cities.lua` (owner change hook), `buildings.lua` (City Center indestructible), `orders.lua` (right-click City Center = garrison, troop platform = embark), `ai/army.lua` (supply-aware offensives, target cities) |
| Regions, scarcity, city-states, strategic layer (world W2) | `m2-world` | `scripts/strategic.lua` (chart labels, choke markers, regional minimap toggle, region names in alerts), `prototypes/world2.lua` (uranium, rare deposit entities, Geology research), `locale/*/world.cfg` | `world.lua` (region names and kinds, scarcity portfolio, city-state/ruin/port sites, `storage.world.chokes` filled), `mapgen.lua` (ruin placement from sites), `hud.lua` (minimap toggle, alert region names), `research.lua` (Geology), `cities.lua` (found a city-state at match start for `rts-neutral`) |
| Nation AI (D9), wave B | `m2-ai` | `scripts/ai/nation.lua` (strategist), `scripts/ai/governor.lua` (per-city knobs, generalises `cities.ai_step`) | `ai/*` only; one hook in `ai/init` |
| Integration, wave B | `m2-integ` | `docs/qa/phase5-m2-protocol.md`, `docs/qa/phase5-m2-integration-notes.md`, README | everything except `ai/*` while `m2-ai` runs |

Each wave-A agent works in a copy under `build/p5m2-<name>/`, validates headless, and syncs **its own files** into
`mods/factorio-rts/` only after the lead opens syncing (the M1 QA fix agent may still be editing shared files);
shared-file hunks are applied after re-reading the current file. Agents never revert another agent's hunk. The lead
commits snapshots after smoke tests. M1 open issues folded into M2: copper towns ship little (market: export copper),
AI hoards bulk goods after Age II (market: sell surplus; upkeep), lines open late because steel is scarce (`m2-integ`
balance pass: rail cost 1 steel + 1 stone → 2 rails, Rail works earlier), rolling stock cannot be re-kitted (`m2-war`).

## 3. Contracts (public API per module)

### population.lua / labor.lua (`m2-people`)
```
population.of(city_id) -> {pop, housing, workforce, free, happiness, needs = {[item] = {need, met}}, tier_progress}
population.add(city_id, n, why) / population.remove(city_id, n, why)   -- clamps to housing; logs "people: city N +n (why)"
population.settle(from_city, to_city, n)                               -- founding moves 40 settlers (cities.found calls it)
population.needs(city_id) -> {[item] = per_minute}                     -- rations 1 per 10 pop/min; goods 1 per 25 pop/min from town tier
labor.jobs(entity_name) -> n                                           -- table in balance.nation.people.jobs (extractor 4, smelter 4, factory 12, barracks 12, lab 8, farm 6, bakery 6, district 16, steam 4; turrets/walls/poles/stockpiles/rails/hubs/depots 0)
labor.staffing(entity) -> 0 | 0.2 | 0.4 | 0.6 | 0.8 | 1               -- read by districts.staffing_factor and production.lua
labor.priorities(force) -> {"military","power","food","extraction","metallurgy","chemistry","electronics","research","services"}
labor.set_priorities(force, list) / labor.pin(entity, on)
labor.recruit(city_id, n) -> ok, reason                                -- kit gate: production.kit_gate adds "no recruits"
labor.release(city_id, n)                                             -- disbanded units return workers; dead units do not
events: "rts_city_population" {city_id, pop, tier}, "rts_staffing_changed" {unit_number, step}
storage.population = {[city_id] = ...}, storage.labor = {[force] = {priorities, pins}, steps = {[unit_number] = step}}
```
Rules as built (balance.nation.people; the seven deviations from the first draft were accepted by the lead, see
`docs/qa/phase5-people-notes.md` §4): workforce = 60 % of pop, and below 50 % rations only half of it works; growth
+4 % **of the housing** per minute (× mood = happiness / 75, at most 1.25) when every need ≥ 90 %, housing has room and
(town+) the city has power, hold between 50–90 %, −3 %/min of the residents below 50 % rations, −1 %/min without power
at town tier+ (power = a hidden 1 kW probe under the centre, "no power" below 50 % satisfaction), −10 %/min of any excess
over the housing; tier thresholds village 20–99, town 100–399, city 400+, up at the next growth pass, down after 2 minutes
below 80 % of the threshold (replaces M1's simple tier-up; land radius/supply per tier unchanged from M1); happiness
0–100 drives growth and taxes only. Needs are *keep* policies on the city's market network (defaults rations 50, goods
20) consumed every 60 s with `remove_item` and `on_flow` statistics. Start: the capital has **200 residents** in a
**200-resident centre** and a start stock of 300 rations + 100 goods; a new city gets the 40 settlers its founding moves
(and 40 rations); a city-state (`rts-neutral`) 120 static residents. Housing: City Center 40; small house 3×3 20 (Age I,
**15 stone + 5 iron**), apartment 5×5 80 (Age II, town+, 30 bricks + 10 steel + 10 goods). Food chain base-game, **no
electricity**: farm 5×5 (fixed recipe → 1 grain / 4 s, limited by tier farm slots 3/6/10; 20 iron + 30 stone), bakery
3×3 (2 grain → 3 rations, 3 s; 20 iron + 10 copper + 15 stone), fishing hut (6 rations/min, water within 3 tiles); goods
recipe at the factory (1 iron plate + 2 copper cable + 1 stone brick → 2 goods, 4 s) and **factory bricks** (2 stone → 1
brick, 2 s); rations spoil in 15 min only when `feature_flags.spoiling` (Space Age). Staffing: a building draws from the
city whose land it stands on (`territory.city_at`); recomputed every 5 s per city, staggered; a step change swaps the
hidden module (`rts-labor-80` … `rts-labor-20`) or toggles `disabled_by_script`. Recruits = unemployed + draft share
(0/10/20/30/50 %) of the employed workers. AI governor (`population.ai_step`): keeps rations/goods at 2 minutes of need,
farms at the capital per 150 pop (a bakery per 2.5 farms), a goods works (second Auto factory), houses from 2:30 while
free housing < 20 and from 5:00 while housing < jobs / 0.6 + 80 (front of its construction queue), labor priorities and
pins, draft by doctrine (economic 10 %, turtle 20 %, aggressive 30 %), a supply hauler from the capital to every town.

### treasury.lua / market.lua (`m2-treasury`)
```
treasury.get(force) -> {balance, income = {tax, exports}, expenses = {buildings, army, transport, imports, interest}, stage = 0|1|2|3}
treasury.add(force, cr, why) / treasury.charge(force, cr, why) -> ok  -- never below the credit line (10 min of gross income); logs "treasury: …"
treasury.set_tax(force, "low"|"normal"|"high")
treasury.score(force) -> cr per minute net (for the Score victory and the AI)
market.price(item) -> cr                                              -- p0 table in balance.nation.market, derived prices at init
market.sell(force, port_un, item, n) -> cr                            -- goods removed from the port's network, stock S += n, capped by commerce cap
market.buy(force, port_un, item, n) -> ok, cr                         -- charged now, goods appear in the port's network after 30 s
market.contract(seller, buyer, item, n_per, deliveries, interval, price) -> id   -- D5; settles per delivery; late = −reputation (diplomacy hook)
market.ports(force) -> {port_un, ...}; market.cap(force) -> cr per minute
market.history(item) -> last 10 minutes of prices
storage.treasury = {[force] = ...}, storage.market = {stock = {[item] = S}, S0, contracts, pending = {...}}
```
Rules (balance.nation.treasury/market): tax per resident per minute 0.2 (workers) × tax level 0.6/1.0/1.4 × happiness
0.5–1.2; exports at 0.9 × price, imports at 1.1 ×; upkeep per minute: Age I building 1, Age II 4 (paused half), army 1
per supply point, transport 2 per locomotive + 1 per 100 rail tiles; debt interest 5 % per 5 min; stages: 1 deficit
(imports blocked, red balance), 2 unpaid wages after 60 s (every building −1 staffing step, barracks refuse "unpaid"),
3 unrest after 180 s (happiness −25). Trade ports: `rts-trade-post` composite (hub subtype with its own network and
2 stockpiles) created on world `port` sites at match start under `rts-neutral`; captured like the ruin (unit within 4
tiles for 10 s). Market panel (M key): prices, history, cap use, sell/buy rows, contracts. Strip shows "₡ 1,240 (+35/min)".
AI: sells what lies above export thresholds at its ports (a hauler/train route to the port is the governor's job),
buys shortfalls it cannot fill in 3 minutes, tax high when at war, low when happiness < 40.

### diplomacy.lua / wars.lua (`m2-diplomacy`)
```
diplomacy.state(a, b) -> "war" | "ceasefire" | "peace" | "alliance"      -- Skirmish: always "war"
diplomacy.hostile(a, b) -> bool                                         -- the ONLY question every targeting script may ask
diplomacy.relation(a, b) -> -100..100; diplomacy.adjust(a, b, delta, why)
diplomacy.propose(from, to, kind, terms) -> id        -- kind: war {goals}, ceasefire, peace {terms}, alliance, contract (market.contract), gift {cr}
diplomacy.answer(id, accept)                          -- AI answers in 10–20 s with a reason key; players via alert buttons / F4 panel
wars.declare(a, b, goals) -> war_id                   -- goals: {kind = "capital"|"conquest"|"tribute"|"border", cities = {...}, cr = n}
wars.score(war_id) -> {a = n, b = n, weariness = {a = %, b = %}}
wars.active(force) -> {war_id, ...}; wars.end_war(war_id, treaty)       -- treaty: white | cede {city_ids} | tribute {cr per min, minutes}
events: "rts_diplomacy_changed" {a, b, state}, "rts_war_declared" {war_id}, "rts_war_ended" {war_id, treaty}
storage.diplomacy = {relations, proposals, states}, storage.wars = {[id] = ...}
```
Engine mapping (`rails-trade.md` §5.1): war = `set_cease_fire(false)`; ceasefire/peace = `set_cease_fire(true)` both
ways; alliance adds `set_friend(true)` and `share_chart` (fog.lua must allow it for allies). Relation events per the
study table (trade +1/1,000 cr, contract +3/−8, common enemy +2/min, units in my land −5 per 10 supply/min, attacked
−20 then −1/1,000 dmg, gift +4/1,000 cr); decay 1/min toward the doctrine baseline (economic +10, turtle +5,
aggressive −10). AI decision table per doctrine (declare war when r < −50/−20/−60 and power ratio > 1.4/1.0/1.6;
ceasefire when ratio < 0.8/0.5/0.9 or weariness > 30/50/25 %; alliance when r > 40/60/30 with a common enemy; no
betrayal within 10 min of an alliance). War score: + city captured (by pop), + capital held per min, + enemy supply
destroyed, + enemy production lost; − own. Victory (D6) is checked by `wars.victory_step` every 10 s and reported
through `match.lua`'s existing end-of-match flow with the war score in the results window. Lobby (Nation only):
Victory = Conquest | Territory | Score, Time limit = 60 | 90 | 120 | ∞. Diplomacy panel (F4): one row per nation and
city-state: state, relation bar, trade volume, buttons war / ceasefire / peace / alliance / gift / contract; AI
proposals arrive as alerts with Accept / Decline (F3 cycles). The targeting audit replaces every "force ~= mine" test
in `orders.lua`, `ai/army.lua`, `raids.lua`, `abilities.lua`, turrets' force relations and `match.lua` victory with
`diplomacy.hostile`; attack orders on a non-hostile target are refused with a message.

### warsupply.lua / capture.lua / garrison.lua (`m2-war`)
```
warsupply.sp(division_id) -> 0..100                    -- supply points; stored in storage.divisions[id].sp
warsupply.state(division_id) -> "supplied" (≥50) | "low" (1–49) | "out" (0)
warsupply.depots(force) -> {unit_number, ...}         -- CC, City Centers, hubs, depots (rts-depot), field depots (rts-field-depot, Commander-built, 1 crate slot pair)
warsupply.refill_step()                               -- every 60 ticks per division: within 2 chunks of a depot whose network holds rts-supply-crate: +20 SP/min, 1 crate per 10 SP
capture.subdue(center_entity)                          -- on_entity_damaged clamp at 10 % HP → city.subdued = tick
capture.step()                                        -- every 60 ticks: contest (attackers within 24 tiles, no defenders, 20 s) → capture.flip(city_id, new_force)
capture.flip(city_id, force) -> job                   -- territory cells, entities in slices of 500/tick (force write), ghosts/proxies destroyed, pop ×0.7, unrest 60 s, capital move
garrison.enter(division_id, city_id) / garrison.sortie(city_id) -> division_id
garrison.of(city_id) -> {records = {{name, health, kills, …}}, points}   -- 1 hidden turret enabled per 4 garrison points around the City Center
rails: troop wagon (`rts-troop-wagon-kit`, 16 supply per wagon): divisions.order(id, "embark", depot_un) → manifests in storage.rails.manifests[wagon]; disembark on arrival at the route's drop-off; destroyed wagon kills its manifest (alert)
rails.disband_train(train) -> kits                    -- 50 % of the kits back to the depot's network
storage.warsupply = {...}, storage.capture = {[city_id] = {subdued, attackers, progress}}, storage.garrison = {[city_id] = ...}
```
Rules (balance.nation.war): SP consumption per minute 0 idle in own land, 2 moving, 8 engaged, +2 in enemy land; low:
no Armor II/III healing, amber bar, AI starts no offensive; out: 1.5 % max HP per 10 s and attack orders refused
(`orders.locked_reason`); supply crate recipe at the factory 4 iron plate + 2 coal → 1 crate (Age I), Age II crate
also 1 explosives (both count). Divisions without a division (loose units) use the nearest division's rule only if
within 24 tiles, else they are always "supplied" (Skirmish untouched). Capture: City Center and Nation CC get
`capture.subdue`; the 20-s contest reuses `mapgen.capture_step`'s rule; AI: `ai/army.lua` targets the nearest enemy
city whose defenders < 60 % of its attack group and stops offensives when the division is "low".

### world.lua additions / strategic.lua (`m2-world`)
```
world.region_at(position) -> {id, name, kind = "highland"|"plain"|"lakeland"|"coast"|"swamp"|"desert"|"forest"|"mountain", resources, owner_share}
world.sites(kind) for kind = "city_site" | "ruin" | "port" | "city_state" | "rare" | "uranium"
world.chokes() -> {{kind, position, width, name, regions = {a, b}}}       -- filled (distance transform on the passability grid)
world.scarcity() -> {[force] = {home_specialty = region_id, lacks = {ore, ...}}}
strategic.label(kind, position, text, opts) / strategic.refresh(force)    -- chart-mode render objects: region names, choke markers, city names, trade routes, war fronts (division positions)
strategic.minimap_mode(player) -> "regional" | "world"; toggle key N
storage.world.regions[id] = {name, kind, bbox, resources, sites}
```
Portfolio (`world-map.md` §2.4): identical start kit within 150 tiles; one home specialty per nation (300–700 path
tiles, closer than any other spawn, equal value by permutation search); contested majors: on a 4-nation map **only two
large copper regions**, 1–2 large iron, 1 large oil swamp; uranium 1–2 on contested ground, minable only after
*Geology*; rare deposits 4–8 on desert/mountain rims/city-state land (entities only; bonuses are M3). City-states 5–6
(each contested copper region gets one, major fords/passes, the coast, the oil swamp) founded for `rts-neutral` at
match start via `cities.found` with `archetype = "city_state"` and a garrison of 4 turrets +1 per 10 minutes; ruins
8–12 on low-value land ≥ 300 tiles from spawns; ports 2–4 on the coast/edge, fair by path. Region names come from a
syllable table seeded by the world seed; alerts say "Iron Hills: hauler lost". Acceptance checks are listed in §4.

### ai/nation.lua / ai/governor.lua (`m2-ai`, wave B)
```
nation.step(force)            -- every 10 s: tax level, sell/buy orders, contracts with the best-relation exporter, war/peace by the diplomacy table, found/age decisions (existing), garrison the capital when a war starts
governor.step(city)           -- every 5 s per city: keep rations/goods/crates, farms and houses, labor priorities by archetype (mining town → extraction first), export routes to the nearest port
```
Difficulty: easy AI never declares war and trades at a loss; normal as the tables; hard gets +20 % tax income (the
only cheat allowed in M2).

## 4. Autotests and acceptance (headless, `mode = "nation"`)

Each package adds its checks to `scripts/ai/autotest.lua` or a `debug.lua` fixture and must pass them with 0 Lua
errors at 60 UPS on a 2048 world, plus the Skirmish smoke (65/65) and the M1 Nation acceptance (seed 501, 39/39).

- **People:** a district at 60 % staffing makes 0.60 ± 0.02 of full output; at 0 % it shows "No workers"; a fed scripted
  city grows village → town by 10:00 and → city by 25:00; a city whose rations stop loses residents within 2 minutes
  and its lowest-priority buildings stop, recovering after food returns; a barracks refuses a kit with "no recruits"
  when the city has no free workers; founding moves 40 settlers; 40 cities × 2,000 staffed buildings < 0.2 ms/tick.
- **Treasury/market:** selling 1,000 steel moves the price along the formula and it drifts back 5 %/min; the debt
  stages trigger at 0, 60 and 180 s and clear on recovery; an import appears at the port after 30 s and never
  elsewhere; the commerce cap blocks the next sale; a contract settles per delivery and a missed one costs −8 relation;
  the normal AI has positive trade volume by 20:00 in 4 of 5 seeds.
- **Diplomacy/wars:** Skirmish: `diplomacy.hostile` is true for every pair and the full matrix is unchanged; Nation:
  ceasefire forces deal no damage over 2 minutes with armies 30 tiles apart; an AI declares war past its thresholds and
  another accepts a ceasefire past its weariness; a war with goal "capture 1 city" ends in a treaty when met; Territory
  victory fires at the share or the lead rule for 3 minutes (wave B: 45 %, or 2x the next coalition with at least 3 %;
  the diplomacy probe tests the share, `tools/probes/m2_integ.lua` the lead and its floor); Score victory at the time
  limit; allies see each other's charts.
- **War:** a division at 0 SP loses 1.5 % HP per 10 s and refuses attack orders; a depot with crates refills it and
  its network loses the crates; a scripted capture flips a 3,000-entity city within 8 ticks of slices, no entity of
  the old force remains on its land, production resumes after 60 s, pop ×0.7, the capital moves; a troop train carries
  12 walkers 600 tiles and they disembark within 10 s with health within 1 %; a destroyed loaded wagon removes its
  units and alerts; save/load during a capture and with manifests in transit loads with 0 errors; disbanding a train
  returns 50 % of its kits.
- **World:** 20 seeds × 4 nations: each nation lacks ≥ 1 basic ore beyond its start kit; each scarce type is reachable
  by ≥ 2 nations within ±15 % path distance; ≥ 5 named chokes; 5–6 city-states each with a City Center and land; ports
  2–4 fair by path; region names resolve for every spawn; chart labels exist for every region (object count logged).
- **M2 end-to-end (integration + ai):** 4 normal AIs, 60 minutes, 2048, 5 seeds: 0 errors, 60 UPS at speed 1 in the
  last 5 minutes, every nation has trade volume > 0, ≥ 1 war declared and ≥ 1 peace signed in ≥ 4 of 5 seeds, ≥ 1 city
  changes hands in ≥ 3 of 5 seeds, no nation starving (a city below 50 % rations for > 3 minutes) in more than 1 seed;
  save/load at 20 and 40 minutes; the M1 acceptance still passes; the Skirmish matrix is unchanged; the GUI protocol
  (Codex) covers the population panel and priorities, treasury strip and market panel, a trade port sale, the
  diplomacy panel (declare war, accept peace), a city capture, a division out of supply and resupplied at a depot, a
  troop train, the regional minimap and region labels.

## 5. Shared-file etiquette

As `PHASE5-M1.md` §5, with the hunk marker `-- Phase 5 M2 <pkg>`. In addition: `diplomacy.hostile` is the only
force-relation test allowed in new or touched code; every new HUD panel registers its hotkey in `hud.lua`'s key table
(M market, F4 diplomacy, N minimap mode) and its locale keys in both languages; no agent syncs into `mods/` before the
lead's "sync open" message; report to the lead: files changed, shared hunks (file:line), autotest results, open
issues, measured ms/tick.
