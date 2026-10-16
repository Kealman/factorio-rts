# Phase 5 M2, package "Treasury and market": treasury, world market, trade ports, contracts

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m2-treasury`. Contract:
`docs/PHASE5-M2.md` (decisions D1 and D5, section 3 "treasury.lua / market.lua", section 4 "Treasury/market").
Studies: `docs/research/scale/deep-economy.md` sections 4.1-4.5 and 9.2, `rails-trade.md` sections 4.2-4.6. Built and
tested in `build/p5m2-treasury/` (a copy of `mods/` at HEAD 22d2dd0). Everything here is Nation mode only; Skirmish
runs exactly as before (smoke 65/65, check lines identical to the baseline tree).

## 1. What a player sees

1. **The treasury** in the HUD strip's resource row: "₡ 1,500 (+35/min)". White while the net of the last minute is
   positive, yellow while it is negative, red below zero. The tooltip splits the last minute into tax, exports,
   buildings, army, transport, imports and interest. A click (or M) opens the market.
2. **Trade ports.** Every world port site (2 on a 2-nation map, 3-4 otherwise; `world.lua`) holds a gold
   **Trade port**: a hub subtype with two stockpiles and its own logistic network, owned by the neutral force
   `rts-neutral`, labelled "Port of <region>" in the game view and on the map. It starts with 300 steel, 100 circuits
   and 100 coal. It cannot be damaged, demolished or mined. A force takes it like the ruin: one of its military units
   within 4 tiles of the post or its stockpiles for 10 s, while no unit of the owner is there and no other force
   contests it. The whole composite changes hands; the old owner's haulers routed to it go home.
3. **The market panel (M).** Treasury line with the tax drop-down (Low / Normal / High) and the debt stage; last
   minute's flows, the credit line and the residents; the commerce cap bar ("₡ 448 / 450 per minute, Commerce 0") and
   the port the buttons trade at; one row per tradeable good: price (green above its base price, red below), a
   10-minute sparkline, the count at the selected port, an amount and Sell / Buy (the tooltips quote the amount now);
   the force's contracts and the imports on their way.
4. **Selling** takes goods from the port's network now and pays 0.9 x the curve price. Goods must be hauled to the port
   first (a hauler route home -> port, or a train to a depot whose network touches the port).
5. **Buying** costs 1.1 x the curve price at once; the goods appear in the port's stockpiles 30 s later and nowhere
   else. Imports are blocked while the treasury is below zero.
6. **Debt.** Below zero: stage 1 (imports blocked, interest). 60 s below zero: stage 2, unpaid wages (barracks hold
   their kits: "Wages unpaid: no Walker until the treasury is positive"; the labor module takes one staffing step off
   every building). 180 s below zero, or at the credit line: stage 3, unrest (the people module takes 25 happiness).
   Each stage raises an alert; back at zero or more everything clears at once ("Treasury recovered").
7. **M** toggles the panel through hud.lua's key table `P4.KEYS`.
8. **Research:** Commerce I (20 basic kits) and Commerce II (30 advanced kits), +25 % commerce cap each, Nation only.

## 2. Files

| File | Status | What it does |
|---|---|---|
| `scripts/treasury.lua` | new | `storage.treasury`, flows, census, credit line, interest, debt stages, the "unpaid" kit gate, `on_stage` hooks, HUD strip text, `/rts-treasury` |
| `scripts/market.lua` | new | `storage.market`, price derivation, the curve, drift and history, commerce cap, sell / buy / imports, contracts and their events, trade ports (placement, capture, ownership), the normal AI's trade pass, `/rts-market` |
| `scripts/marketgui.lua` | new | The market panel (M) |
| `prototypes/trade.lua` | new | `rts-trade-post` (gold roboport clone), Commerce I / II |
| `locale/en/treasury.cfg`, `locale/ru/treasury.cfg` | new | 73 keys each, the same in both |
| `balance.lua` | appended | `balance.nation.treasury`, `balance.nation.market`, `balance.buildings["rts-trade-post"]` |
| `data.lua` | +1 line | `require("prototypes.trade")` |
| `control.lua` | +6 lines | `scripts.treasury`, `scripts.market`, `scripts.marketgui` after `scripts.ledgergui` |
| `prototypes/inputs.lua` | 1 hunk | custom input `rts-market` (M) |
| `scripts/hud.lua` | 6 hunks | alert styles, the treasury label in the resource row, its update, the "market" click action, the barracks "unpaid" line, the M entry of the key table `P4.KEYS` |
| `scripts/logistics.lua` | 1 hunk | `logistics.change_owner(un, force)`: a hub subtype changes hands (policy and network caches) |
| `scripts/world.lua` | 2 hunks | `world.place_port` hook; port sites become trade posts |
| `scripts/rails.lua` | 1 line | the rail AI never picks a trade post as the far end of its line |
| `scripts/ai/commander.lua` | 1 line | `deps.market.ai_step(C)` after `towns.step` |
| `scripts/ai/army.lua` | 1 line | units claimed by the market (envoys) stay out of the pool |
| `scripts/ai/scout.lua` | 2 hunks | indestructible buildings are never known targets; `beaten_enemy` looks at match forces only (merged with m2-world's identical fix) |
| `scripts/ai/autotest.lua` | 4 hunks | `TRADE_DEADLINE`, the `trade_<force>` checks, the "m2" minute line, trade posts left out of the doctrine hub check |
| `tools/probes/treasury_fixture.lua` | new | Headless fixture (section 6) |
| `tools/probes/market_gui.lua` | new | GUI probe with screenshots (section 6) |
| `tools/probes/neutral_target.lua` | new | The targeting probe (section 7) |

## 3. Treasury (`scripts/treasury.lua`)

```
treasury.get(force) -> {balance, income = {tax, exports, other}, expenses = {buildings, army, transport, imports,
                        interest, other}, stage = 0..3, tax, net, credit, rates, counts, pop, happiness, totals}
treasury.add(force, cr, why) / treasury.charge(force, cr, why) -> ok   (charge: refused below the credit line)
treasury.pay(force, cr, why)            mandatory payment, paid down to the credit line (upkeep, interest)
treasury.set_tax(force, "low"|"normal"|"high"), treasury.tax_of(force), treasury.balance(force), treasury.stage(force)
treasury.score(force) -> net cr per minute
treasury.on_stage(fn)                   fn(force, stage, old_stage) on every change (load time); signal "rts_treasury_stage"
treasury.strip(force) -> caption, color, tooltip   (the HUD)
storage.treasury = {[force] = {match_id, balance, tax, stage, below_since, rates, counts, buckets, totals,
                               next_interest, credit, pop, happiness, stage_log}}
```

Income and expenses are a rolling minute (six 10-s buckets). Every 600 ticks one pass over the building registry,
the unit registry, the rail lines and the cities computes the rates, and a sixth of each per-minute rate is booked.

| Flow | Rule (balance.nation.treasury) |
|---|---|
| Tax | residents x 0.2 x tax level (0.6 / 1.0 / 1.4) x happiness factor (0.5 at 0 ... 1.2 at 100; 0.99 at the default 70); hard AI +20 % |
| Residents | `population.of(city).pop` (scripts/population.lua, M2 people) or `storage.population[city].pop`; without that module a fallback by city tier: 40 / 120 / 400, the capital at least 120 |
| Exports | 0.9 x the curve price (market.sell) |
| Buildings | 1 per Age I building, 4 per Age II building (names in `balance.nation.economy.buildings`), half for a crafting machine without a recipe or disabled by script. Free: walls, stockpiles, solar, accumulators, rolling stock, project sites, the Command Center, City Centers, trade posts |
| Army | 1 per supply point of military units (haulers and the Commander excluded); `army.free` = 0 |
| Transport | 2 per locomotive + 1 per 100 tiles of the force's lines in state building / open / cut |
| Imports | 1.1 x the curve price (market.buy) |
| Interest | 5 % of the debt every 5 minutes |
| Credit line | 10 minutes of gross income (tax + exports of the last minute), at least 500 |
| Start | 1,500 cr |

Stages are checked every 60 ticks and after every change of the balance, so stage 1 starts in the tick the balance
drops below zero and stages 2 and 3 start within one second of 60 s and 180 s.

**M2 people.** When `scripts/population.lua` and `scripts/labor.lua` are loaded (looked up through `package.loaded`,
so a copy without them still runs): the tax level sets `population.set_mood(force, "tax", n)` (low +8, normal 0, high
-8; `balance.nation.treasury.tax.mood`), stage 2 and 3 set `labor.set_penalty(force, 1, "unpaid")` (one staffing step
off every building; 0 clears it), stage 3 sets `population.set_mood(force, "debt", -25)` (nil clears it). Residents
are `population.of(city).pop`. The fallback without the module gives the capital 200, like M2 people's start.

**The kit gate.** `treasury.lua` loads after `research.lua` and wraps `production.kit_gate`: at stage 2 or 3 a finished
kit stays in the barracks output with `rec.research_block = {reason = "unpaid", unit, kit}` (the HUD's barracks line
reads it); otherwise the inner gate (research, supply) decides. M2 people's "no recruits" gate can wrap it again.

## 4. Market (`scripts/market.lua`)

```
market.price(item), market.p0(item), market.stock(item) -> S, S0, market.items(), market.history(item)
market.quote(item, n, "sell"|"buy") -> cr
market.sell(force, port_un, item, n) -> cr, reason      ("none", "cap", "no-port", "item")
market.buy(force, port_un, item, n) -> ok, cr | reason   ("deficit", "funds", "cap", "stock", "no-port", "item")
market.pending(force) -> imports on their way
market.contract(seller, buyer, item, n_per, deliveries, interval_seconds, price) -> id | nil, reason
market.cancel_contract(id, why), market.contracts(force?)
market.on_contract_event(fn)  fn{kind = created|delivered|late|missed|completed|cancelled, id, seller, buyer, item, n,
                              delivery, deliveries, price, value, fault = "seller"|"buyer"}; signal "rts_contract_event"
market.ports(force) -> {port un, nearest to the capital first}, market.port(un), market.all_ports(), market.port_contents(un)
market.cap(force), market.cap_used(force), market.volume(force) -> {sold, bought, contract_sold, contract_bought, total}
market.place_port(surface, position), market.set_owner(port_un, force|nil), market.capture_step()
market.ai_step(C); market.AI = {taxes, envoy, route, sell, buy}; market.ai_taxes / ai_envoy / ai_sell / ai_buy (C)
storage.market = {match_id, p0, S0, stock, items, history, ports, parts, pending, contracts, next_id, trades, volume,
                  ai, next_drift, cap_override}
```

**Prices.** Anchors (`balance.nation.market.p0`, the study's table): ores 0.4, coal 0.5, stone 0.3, plates 1, steel
3.3, circuit 4, plastic 3, sulfur 2, engine 14, advanced circuit 18, processing unit 70, LDS 40, explosives 2, crude
0.5, stone brick 0.7 (bricks and concrete trade although they place tiles), and the M2 people goods (rations 1.5, goods 15, grain 0.4) when they exist. Every other good is
derived at match start: `1.1 x (sum of ingredient p0 x amount + 0.1 x recipe seconds) / products`, the cheapest
non-district recipe first (district recipes only when nothing else makes it). Placeable items (buildings, rails), unit
kits and hidden items are not traded. With Space Age on the market opens with 26 goods, for example gear 2.31, cable
0.58, magazine 1.13, basic kit 4.19, advanced kit 13.53, industrial kit 19.36, petroleum 0.84, steel beam 5.67.

**The curve.** `p = p0 x (S0 / S) ^ 0.6`, clamped to 0.4-3 x p0. `S0 = 10,000 / p0` clamped to 200-20,000 (steel 3,000
by override). A sale of n adds n to S and pays 0.9 x the integral of p over [S, S + n] (closed form, piecewise with the
clamps); a purchase removes n and costs 1.1 x the integral over [S - n, S]. Every 60 s, S moves 5 % back towards S0
and the price is sampled (10 samples: the panel's sparkline).

**Commerce cap.** cr sold + bought in the last 60 s (per trade, rolling) <= (300 + 150 x ports held) x (1 + 0.25 x
Commerce level). A sale or purchase is cut to what still fits (binary search on the curve); with nothing left it
returns "cap". Contracts do not count.

**Imports.** `market.buy` charges at once and queues `{due = now + 30 s, port, item, n}`; every 10 ticks due imports go
into the port's stockpiles. A port lost meanwhile sends them to another own port, else they are refunded; a full port
keeps the rest waiting.

**Contracts (D5).** At each due time (checked every 10 ticks) `n` goods must be at one of the seller's ports and the
buyer must hold a port and pay `n x price` (treasury.charge). Then the goods leave the seller's port, the seller is
paid, and they appear at the buyer's port 30 s later. Otherwise the delivery is "late" (one event, with the fault);
two minutes later it is "missed" (event) and the next one is due one interval after the missed one. When every slot is
done the contract is "completed" (any delivery made) or "failed". Reputation is diplomacy's (`on_contract_event`).

**Trade ports.** `world.lua` calls `market.place_port` for every port site once its chunks exist (about 7-20 s after
the start at 2048). The post is created under `rts-neutral` (`game.forces["rts-neutral"] or game.create_force(...)`;
relations are diplomacy's), registered as a building, so `logistics.lua` builds its composite; then every part is made
indestructible and unminable, the default hub keeps are cleared and the loot goes into the stockpiles. A held post adds
no supply (a `supply.on_cap` hook subtracts the hub's +10) and claims no land. The capture step runs every 30 ticks
(one `find_entities_filtered` per port, radius 7.5); progress accumulates only while one challenger is there alone, so
a capture takes 10.0-10.5 s after the unit arrives. A port held by a nation changes hands only to a force at war with
it (`diplomacy.hostile`, when scripts/diplomacy.lua is loaded); a neutral port is open to everyone.

## 5. Normal AI (`market.ai_step`, every 600 ticks per AI, from `ai/commander.lua`)

1. **Taxes:** low while happiness < 40; high while at war (`wars.active(force)` when scripts/wars.lua exists, else an
   own attack or defence group or a base threat in the last 2 minutes); high while the balance is below 1,500 and the
   net is negative; normal otherwise.
2. **Envoy:** once the world fill is done (or 3 minutes in), with no port held: the idle army unit (raider, drone or
   walker, in that order, outside every group) nearest to the capital goes to the nearest neutral port that no other
   AI's envoy is walking to (claim: order "port", issuer "market"; `ai/army.lua` leaves it alone). It stands there
   until the port is taken, then goes back to the pool. A failed path is re-issued up to 3 times; a port taken by
   someone else, a lost unit or 5 minutes release it; the next envoy leaves a minute later and is a different unit.
3. **Route:** the capital exports the surplus goods it had no export threshold for (stone 300, coal 500, ores 800,
   bricks 200; plates and steel keep the capital's own thresholds) and the port keeps 400 of each (coal 400, of which
   60 stay as the haulers' fuel). One spare auto hauler becomes a manual route capital -> port. The force asks for one
   more hauler kit for it once it wants haulers anyway or from minute 12 (earlier, the kit's circuits took the copper an
   AI still needed for its copper line). In deficit mode (balance < 1,500 and a negative net) the capital exports from
   half the thresholds.
4. **Wanted goods:** a good at the port the capital's ledger is short of (the loot's circuits, typically) is hauled
   home instead of sold: the port exports it from 0 and the capital keeps its count + the shortfall for 10 minutes.
5. **Sell:** everything else at its ports, most valuable first, until the cap (coal down to 60).
6. **Buy:** a capital ledger shortfall that cannot be filled in 3 minutes (made 0, or short > 3 x made per minute, and
   no other own city makes it) for 3 minutes: buy the shortfall (or the missing ingredient the ledger names) at the
   port, at most 25 % of the balance and never below 500; not while the balance is below 1,500 with a negative net.
   The goods are hauled home as in 4.

`market.AI` lets the M2 nation strategist (`ai/nation.lua`, wave B) switch any part off and call
`market.ai_taxes / ai_envoy / ai_sell / ai_buy` itself.

## 6. Tests

| Test | Command | Result |
|---|---|---|
| Fixture | `KEEP_TREE=build/p5m2-treasury/factorio-rts EXTRA_LUA=tools/probes/treasury_fixture.lua STOP_ON=RTS_TREASURY_DONE SPEED=4 SEED=501 tools/autotest-run.sh p5m2t-fx '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1500` | 12/12, 0 errors (below) |
| AI trade, 5 seeds | `PERF=1 DURATION_MIN=21 SPEED=6 SEED=<501..505> tools/autotest-run.sh p5m2t-ai3-<seed> '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1800` | 10 of 10 AIs traded by 20:00 (table below), 0 errors |
| Skirmish smoke | `SEED=9090 tools/autotest-run.sh p5m2t-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 400` | 65/65, check lines identical to the baseline tree |
| M1 Nation acceptance | `PERF=1 EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN=60 SEED=501 SPEED=6 tools/autotest-run.sh p5m2t-m1acc3 '{...nation...}' 4800` | 41/41 (the 39 M1 checks and the 2 trade checks; the baseline tree 39/39), 0 errors, 23,854 items by train, 60 UPS at speed 1 in minutes 56-60 |
| Save / load at minute 8 | `SAVE_MINUTE=8 SPEED=6 DURATION_MIN=30 SEED=501 tools/saveload-check.sh p5m2t-sl '{...nation...}' 200` | 0 errors before and after the load; balances, ports and volumes carry on |
| GUI probe (Russian client) | `tools/gui-run.sh <copy with scripts/market_gui.lua required> 240 RTS_MARKET_GUI_DONE` | 3/3: M opens the panel, Sell pays, the strip turns red; screenshots `build/shots-p5m2t-gui/` |

**After the sync** (`mods/factorio-rts` = 0abb79b + m2-diplomacy + this package; default KEEP_TREE): Skirmish smoke
65/65; treasury fixture 12/12; economy fixture (`tools/probes/economy_e1.lua`, seed 202) 18/18; rails autotest
(`tools/probes/rails_autotest.lua`) 12/12 beside the Skirmish AI autotest 23/23; Nation 1v1 seed 501, 21 minutes
(`p5m2t-sync-ai501`) 43/43 with diplomacy's checks, both AIs trading from 3:10 / 3:20; GUI probe 3/3 (M now goes
through `P4.KEYS`, log "hud: hotkey rts-market (M)"); 0 Lua errors in every run.

**Fixture checks** (`[rts] treasury fixture <check>`):

| Check | Measured |
|---|---|
| ports | three posts placed by `market.place_port`: kind hub, 2 stockpiles, own network, rts-neutral, indestructible, loot 300 steel / 100 circuits / 100 coal; holding one leaves the supply cap at 40 |
| capture | a walker next to the neutral post takes it in 10.17 s; post, power, pole, stockpiles, their building records and the hub policy change force |
| price | selling 1,000 steel at S = S0 = 3,000 pays 2,716.551 cr = quote = a 2,000-step numeric integral of 0.9 x p; S 3,000 -> 4,000; price 3.3000 -> 2.7768 = 3.3 x (3000 / 4000) ^ 0.6 |
| drift_1, drift_2 | at the next two minute ticks S 4,000 -> 3,950 -> 3,902.5 (5 % of the gap each), price 2.7979 -> 2.8183 |
| stages | balance -200: stage 1 at 0.00 s, 2 at 60.83 s, 3 at 180.83 s, 0 at the recovery (185.00 s); the on_stage hook saw 1, 2, 3, 0 |
| stage_effects | stage 1: a purchase is refused "deficit"; stage 2: the barracks' kit gate returns nil with reason "unpaid" |
| import | 100 plastic for 333.02 cr (the quote, charged at once); at the port 0 at 29 s, 100 at 31 s; the force's networks hold 100 in all |
| cap_blocks | cap 600 (2 ports): five sales of 50 steel take 598.3 cr, the next sale and a purchase return "cap" |
| cap_frees | 61 s later a sale goes through (126 cr) |
| contract_settles | 2 x 50 steel at 2.5: deliveries at 30.0 s and 60.0 s, 125 cr each, the buyer's port +50 31 s after each, one "completed" |
| contract_missed | a seller without goods: "late" at 30.0 s, "missed" at 150.0 s (due + 2 min, fault seller), contract "failed" |

**AI trade, 5 seeds** (1v1 Nation 2048, normal, 21 minutes, the final tree; baseline = the same seed on the tree
without this package):

| Seed | First trade rts-player / rts-ai-1 | Traded by 21:00 (cr) | Autotest | Baseline |
|---|---|---|---|---|
| 501 | 3:10 / 3:20 | 963 / 1,387 | 41/41 | (60 min: 39/39) |
| 502 | 2:50 / 5:50 | 1,611 / 1,372 | 41/41 | 39/39 |
| 503 | 3:20 / 5:10 | 1,108 / 1,200 | 40/41: `hub_rts-player` | 38/39: `hub_rts-player` (haulers wait for coal) |
| 504 | 3:50 / 3:30 | 1,018 / 1,018 | 41/41 | 39/39 |
| 505 | 3:50 / 2:50 | 1,134 / 1,155 | 41/41 | 39/39 |

The first trades are the port loot (steel, coal) sold right after the capture; later ones are the stone the route
hauler brings and imports (502, 503, 505).

**The treasury over 60 minutes** (M1 acceptance run, seed 501, M1 population: no people module): both nations hold
2,200-2,400 cr at 20:00 (net +25/min at tax high, army 31-40 supply). From Age II the armies grow to 100-130 supply
(100-130 cr/min) against 144 cr/min of tax: 1,337 / 1,409 cr at 30:00, 730 / 953 at 40:00, 233 / 396 at 50:00.
rts-player first dips below zero at 56:28 and stays there from 56:48 (stage 2 at 57:48, stage 3 at 59:48); rts-ai-1
ends at 92 cr. The AIs switch to high tax while at war or losing money and enter deficit mode in the second half.

**Performance** (PERF=1, the five 21-minute runs, per-minute averages): `treasury` 0.0003-0.0007 ms/tick, `market`
0.0007-0.0012, `marketgui` 0.0000-0.0002 (panel closed). The AI pass (`market.ai_step`, booked to `ai/init`; timed by
`build/p5m2-treasury/probes/market_ai_perf.lua`, seed 503) 0.0002-0.0012 ms/tick for both AIs together. Everything
together stays below 0.003 ms/tick (budget 0.1).

## 7. Notes and gotchas

1. **Units never target an indestructible entity of a hostile force** (probe `tools/probes/neutral_target.lua`: walkers
   with stop, attack-area by_anything and go-to by_enemy next to an indestructible rts-neutral roboport: none picked it
   as a distraction target; a destructible one beside it died in 5 s). The API says the same for `destructible`. So the
   trade post can sit under `rts-neutral` at war with everyone without stalling armies.
2. **The AI scout must skip indestructible buildings and non-match forces.** Before the fix an AI sent its first attack
   to the rival's trade port and `scout.beaten_enemy` could return `rts-neutral` (buildings, no CC, no barracks).
3. **An early hauler kit starves a copper-poor AI.** The +1 hauler want made the workshop make circuits at minute 4,
   and on seed 504 the aggressive AI never built its copper line (35/41). The route's hauler now waits until the AI
   wants haulers anyway or minute 12, and takes only a spare one.
4. **The world places ports late**: a port is placed when its chunks exist (7-20 s at 2048). The first envoy waits for
   `world.ready()` or 3 minutes; before that, both AIs once raced for the only placed port.
5. The vanilla map (M) moves to zooming out of the remote view: `rts-market` consumes M (`game-only`).

## 8. Open issues

1. **Balance needs the people module and the integration pass.** With M1 population (the fallback, 120-520 residents)
   and the contract's upkeep, a normal AI's treasury falls from minute ~25 by 15-66 cr/min; seed 501 reached stage 3
   at 59:48 for one side. M2 people's residents (tax base), better exports and `m2-integ`'s pass decide the curve. The
   knobs are all in `balance.nation.treasury` (start, army.free, fallback_pop, upkeep) and `.market.ai`.
2. **The AI exports little (handed over to wave B).** The capital rarely holds goods above the surplus thresholds
   (stone mostly), so after the loot most volume is imports. Routing the mining town's ore or plates to a port (or a
   depot next to it) is the governor's (`ai/governor.lua`, m2-ai, wave B); `market.AI.route` can then be switched off.
3. **Port fairness** is the world's: on seed 502 rts-ai-1's nearest free port was 1,672 tiles away across the rival's
   land (its first envoy's path failed at once, the second died on the way; the third took it at 5:50).
4. **The AI only takes neutral ports.** Retaking a lost port or taking a rival's is a war goal (m2-diplomacy / m2-ai).
5. **Contracts are created through the diplomacy panel** (m2-diplomacy calls `market.contract`); the market panel
   lists them. Interval is in seconds.
6. **Commerce I / II are researched last by the AI** (research.list order, after every other technology).
7. **M opens the market** (`consuming = "game-only"`); the vanilla map stays reachable by zooming out.
8. The trade post keeps the hub's 10 construction robots: the owner's ghosts within 22 tiles are built from its
   network like at any hub.

## 9. Shared-file hunks (in `mods/factorio-rts` after the sync onto 0abb79b + m2-diplomacy, marked `-- Phase 5 M2 treasury`)

| File:line | Hunk |
|---|---|
| `balance.lua:542-634` | `balance.nation.treasury`, `balance.nation.market`, `balance.buildings["rts-trade-post"]` (appended before `return balance`) |
| `data.lua:19` | `require("prototypes.trade")` |
| `control.lua:54-59` | requires `scripts.treasury`, `scripts.market`, `scripts.marketgui` after `scripts.ledgergui` |
| `prototypes/inputs.lua:72` | custom input `rts-market` (M) |
| `scripts/hud.lua:325` | `P4.ALERT_STYLE`: treasury-stage, treasury-recovered, port-captured, port-lost, import-arrived, import-lost |
| `scripts/hud.lua:906` | `el.treasury` label in the strip's resource row (tags `rts_hud = "market"`) |
| `scripts/hud.lua:1405` | `block_text`: reason "unpaid" |
| `scripts/hud.lua:1721` | `update_strip`: caption, colour and tooltip from `treasury.strip` (Nation mode) |
| `scripts/hud.lua:2249` | click action "market" -> `marketgui.toggle` |
| `scripts/hud.lua:2328` | `P4.KEYS`: `{input = "rts-market", key = "M", module = "scripts.marketgui", fn = "toggle"}` |
| `scripts/logistics.lua:261` | `logistics.change_owner(unit_number, new_force)` |
| `scripts/world.lua:91` | `world.place_port = nil` (set by market.lua) |
| `scripts/world.lua:1497` | `place_feature`: port sites -> `world.place_port` |
| `scripts/rails.lua:2593` | `rails.ai_step`: the far end is never a trade post |
| `scripts/ai/commander.lua:589` | `deps.market.ai_step(C)` |
| `scripts/ai/army.lua:243` | the pool skips units with issuer "market" |
| `scripts/ai/scout.lua:75` | known targets: destructible buildings only |
| `scripts/ai/scout.lua:260` | `beaten_enemy`: match forces only (the merged treasury / world hunk) |
| `scripts/ai/autotest.lua:71, 313, 534, 615` | `TRADE_DEADLINE`; "m2" minute line; `trade_<force>` checks; hub check without trade posts |
