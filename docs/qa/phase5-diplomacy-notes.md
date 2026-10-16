# Phase 5 M2: diplomacy, wars and victory (package notes)

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age on. Agent: `m2-diplomacy`. Contract:
`docs/PHASE5-M2.md` §2, §3 "diplomacy.lua / wars.lua", decisions D6, D7, D9, acceptance §4 "Diplomacy/wars". Studies:
`docs/research/scale/rails-trade.md` §5, `war-ai-performance.md` §2.8 and §4.5. Built in `build/p5m2-diplomacy/` from
HEAD 22d2dd0; not synced into `mods/` (waits for the lead's "sync open").

## 1. Verdict

Every acceptance item of §4 "Diplomacy/wars" passes headless (and the two that need a client pass in a GUI run):

| Item | Result | Run |
|---|---|---|
| Skirmish: `diplomacy.hostile` true for every pair | PASS (1v3: 12 of 12 pairs hostile, state "war", engine agrees; no `rts-neutral`) | `p5dipl-smoke-sk` |
| Skirmish matrix unchanged | 10 of 10 scenarios: same summaries as HEAD, and every `[rts]` line before the stop marker identical (timings aside) | `matrix-p5m2dipl-head` vs `-wt2`, seed 777 |
| Ceasefire: no damage over 2 minutes, armies 30 tiles apart | PASS: 8 + 8 walkers 30 tiles apart sent at each other (they march through each other), 1600 / 1600 hp before and after; control: the same armies at war fall from 3200 to 120 hp in 30 s; an explicit attack order is refused (0 units) | `p5dipl-acc-main2` |
| An AI declares war past its thresholds | PASS nudged (relation -90, Age II, +30 walkers: declared at its next AI step) and natural (seeds 702, 703 and the M1 seed 501: the aggressive AI at 15:36 / 17:36 / 15:36, e.g. relation -21 < -20 and ratio 1.01 > 1.0) | `p5dipl-acc-main2`, `p5dipl-nat-702/703`, `p5dipl-m1acc` |
| Another AI accepts a ceasefire past its weariness | PASS nudged (60 % > 30 %, "accept-weary" after 17 s; the same AI declines while winning) and natural (seed 702: 50 % > 30 %; seed 703: 30.3 % > 30 %; seed 501: the economic side) | same |
| A war with goal "capture 1 city" ends in a treaty when met | PASS: not met before; "rts_city_captured" names the goal city, the war ends within 10 s in "cede {city}" and peace | `p5dipl-acc-main2` |
| Territory victory at 60 % for 3 minutes | PASS: 188 s after the share reached 61 % (checked every 10 s), winners {rts-ai-1} | `p5dipl-acc-main2` |
| Score victory at the time limit | PASS: the clock moved past the 60-minute limit, the top scorer wins with its ally ({rts-ai-1, rts-player}), result texts "victory-score"; a GUI run shows the results window | `p5dipl-acc-score2`, `p5dipl-pgui` |
| Allies see each other's charts | PASS in a GUI client: 0 of the ally capital's chunks charted for the player before the alliance, 18 of 25 after | `p5dipl-gui` (tools/gui-run.sh) |
| 0 Lua errors | every run above, three natural 60-minute runs, save/load, the M1 acceptance (41/41), two GUI runs | |
| <= 0.1 ms/tick idle | diplomacy 0.0007-0.0009 ms/tick mean (worst minute 0.0038), wars 0.0001, the panel 0.0001 | `p5dipl-nat-701/702/703`, PERF=1 |

## 2. Design as built

### States and the engine

`storage.diplomacy.states[a][b]` is symmetric: `war | ceasefire | peace | alliance`. `diplomacy.set_state` writes both
directions and the engine mapping of `rails-trade.md` §5.1: war = `set_cease_fire(false)` both ways and no friends;
ceasefire and peace = `set_cease_fire(true)` both ways; alliance adds `set_friend(true)` both ways and `share_chart` on
each force while it has an ally. Every change logs `diplomacy: a / b: old -> new (why)`, raises the signal
`rts_diplomacy_changed {a, b, state, old, why}` and alerts the human sides.

**Start state (confirmed by the lead).** A Nation match starts with every pair of nations at **peace**
(`balance.nation.diplomacy.start_state`; `"war"` restores the M1 free-for-all). The contract's "an AI declares war past
its thresholds" needs a state without war, and starting at peace gives the economy room first (the owner's "economy
must matter" feedback). The M1 autotest's `attack_<force>` and `harass_<force>` checks therefore excuse a force that
spent less than 10 minutes at war (`autotest.PEACE_WAR_MINUTES`); they print "at peace: N minutes at war".

**City-states (D7).** `match.lua` creates `rts-neutral` idempotently in Nation mode (`game.forces["rts-neutral"] or
game.create_force`), grey, `ai_controllable = false`, `share_chart = false`, at war with every nation both ways and at
cease-fire with the vanilla forces. It has no commander, so only its turrets fight. Its state with everyone is "war"
for the whole match (`set_state` refuses anything else for it; trading with city-states is M3). After the match it
ceases fire like the nations. `fog.lua` never charts it.

### hostile(a, b)

The only force-relation question for targeting. Nation mode: the state table (war = hostile; nothing is hostile after
the end, matching `match.lua`'s calm). Skirmish, and pairs the table does not know: `LuaForce.is_enemy`, memoised per
tick and match phase and dropped on `on_force_cease_fire_changed` / `on_force_friends_changed` (a probe showed both are
raised synchronously for script changes). The memo returns exactly what a fresh `is_enemy` would, so it is safe for
multiplayer; everything else that AI decisions read (the power cache) lives in `storage`.

`diplomacy.refuses_attack(attacker, target_force)` is true when the target belongs to a nation (or the city-states)
that is not at war with the attacker; `orders.lua` refuses such an attack with a flying text ("AI 1: Peace, not war.
Declare war first (F4)").

### Relations

`r[a][b]` is a's opinion of b, -100..100, start 0, per `balance.nation.diplomacy.relation`:

| Event | Change | Where |
|---|---|---|
| Trade | +1 per 1,000 cr, at most +10 per minute | `diplomacy.note_trade(a, b, cr)` (market) |
| Contract delivered / missed | +3 both ways / -8 from the wronged side | signal `rts_contract_event` (market.lua) or `diplomacy.contract_event(seller, buyer, ok, cr, fault)` |
| Common enemy | +2 per minute | minute step |
| Their units on my land (not allies, not at war) | -5 per 10 supply per minute | border step (one nation per slot) |
| Attacked | -20 on the first hit of a war, then -1 per 1,000 damage | `on_entity_damaged` (shared filter) and the deaths of RTS units |
| Gift | +4 per 1,000 cr, halved for every gift of the last 10 minutes | accepted gift |
| War declared on me / on someone else | -30 / -5 the aggressor | `wars.declare` |
| A ceasefire broken / an alliance left | -20 / -20 | `wars.declare`, the Leave button, the AI |
| Decay | 1 per minute towards the doctrine baseline: economic +10, turtle +5, aggressive -10, human 0 | minute step |
| Rivalry (design addition) | per minute, times the doctrine factor (aggressive 2, economic and turtle 0.5, human 0): nearest neighbour by capital distance 1, any other within 1.5 times that distance 0.5, any nation it out-powers and can reach 1 | minute step |

The rivalry is `war-ai-performance.md` §4.5's "border friction"; without it no relation ever crosses a war threshold
at peace (the contract's events all need contact first). With decay pulling back by 1 per minute, only the aggressive
doctrine drifts below its baseline: about -1 per minute towards its nearest neighbour, so it reaches -20 around minute
10-15, when Age II lets its army reach.

### Proposals and the AI

`diplomacy.propose(from, to, kind, terms) -> id | nil, reason`; kinds `war {goals}` (declares at once),
`ceasefire`, `peace {kind = white | tribute | cede, ...}`, `alliance`, `contract {item, n_per, deliveries, interval,
price, seller, buyer}` (passes to `market.contract`), `gift {cr}` (moves crowns with `treasury.charge` / `treasury.add`).
An AI answers after 10-20 s (deterministic hash of id and tick) with a reason key (`rts.diplomacy-reason-<key>`, e.g.
"decline-border": "you have 12 supply of units inside our border"); a human answers through the offers under the
alert lines or the panel, and an unanswered proposal expires after 2 minutes. `diplomacy.answer(id, accept)` applies
it. A proposal that became impossible is void.

The AI step (every 60 s per AI nation, staggered: slot 30 + 6 (i - 1) of the minute; `diplomacy.ai_step(force)` for
`m2-ai`'s strategist, which can set `diplomacy.AI_SELF_SCHEDULE = false`) uses the contract's table:

| Doctrine | Declare war when r < and ratio > | Ceasefire when ratio < or weariness > | Alliance when r > (common enemy) |
|---|---|---|---|
| economic | -50, 1.4 | 0.8, 30 % | 40 |
| aggressive | -20, 1.0 | 0.5, 50 % | 60 |
| turtle | -60, 1.6 | 0.9, 25 % | 30 |

Extra rules: easy AIs never declare war; one offensive war at a time; no war during a 10-minute truce after a treaty;
a war only on a nation its army can reach (Age II, or a city within `ai/army.lua` NATION_AGE1_REACH); a ceasefire
offer only after 5 minutes of war; after two declined offers a weary AI (1.5 times its threshold) offers peace with a
tribute (40 cr per minute for 10 minutes); no betrayal: an alliance younger than 10 minutes is never left, an older one
is left below relation -10. Answers: a ceasefire or white peace is accepted past the doctrine's weariness, below its
power ratio, after 30 minutes unless the war score is above +20, during a ceasefire above relation -60, or when its own
goals are met; terms are accepted when they favour the AI, or past 1.5 times its weariness; an alliance needs peace,
relation >= ally_r - 10, a common enemy and fewer than 10 supply of the proposer's units on its land; a contract needs
the market, no war and relation >= 0; a gift needs the treasury. `power(x)` = supply of live units (not haulers or the
Commander) + 2 per turret + production value per minute (iron, copper, steel, circuits, explosives, plastic at market
prices when `scripts/market.lua` exists) / 500, cached 300 ticks in `storage.diplomacy.power`.

### Wars (`scripts/wars.lua`)

`wars.declare(a, b, goals)` normalises goals: `conquest {cities}` (default: b's city nearest to a's capital), `capital`
(b's capital, held 10 minutes), `tribute {cr_per_min, minutes}` (war score 30), `border {cities}` (or war score 25).
Declaring on a pair in its ceasefire resumes that war. War score per side (balance `wars`): 1 per supply point of enemy
units destroyed, buildings by kind (cc 10, district 6, factory and barracks 4, ...), a captured city 20 + 0.1 per
resident (signal `rts_city_captured {city_id, from, to}`, which m2-war's `capture.flip` emits), 5 per minute holding
the other side's original capital; `wars.score(id)` gives net scores (gains minus the other side's). Weariness = supply
lost to this enemy in the last 5 minutes / (army + that loss) + 1 % per minute past 10 minutes + 15 % per city lost +
20 % while the enemy holds the own capital.

A war ends (`wars.end_war(id, treaty)`) when its goals are met (treaty by goal: `cede {city_ids}` or `tribute`), a
ceasefire held 3 minutes (white), an accepted peace proposal, a side is eliminated, or after 45 minutes (white). A
cession of a city the receiver does not hold yet calls every `wars.on_cede(fn)` hook (m2-war's `capture.flip`); with no
hook it is only logged. A tribute is paid every minute through `treasury.charge` / `treasury.add`; with no treasury it
is logged ("war: tribute a -> b 40 cr (no treasury: logged only)"). Peace after a treaty starts the truce.
`wars.targets(force)` lists the goal cities of its offensive wars that it does not hold yet (for m2-war's army).

### Victory (D6)

`wars.victory_step` every 10 s, Nation only, reported through `match.finish_by(winners, how, detail)` into
`match.lua`'s end flow (calm, fog, results); `match.result` gives "victory" to every listed winner (allies share a
victory) and `match.result_text_key` returns `rts.match-<result>-<how>`.

- **Conquest** (always on): every nation outside x's alliance is eliminated (out, or no city left) or its original
  capital is held by the alliance. An alliance of every remaining nation wins together ("alliance").
- **Territory** (lobby Victory = Territory): an alliance's summed `territory.share` >= 60 % for 3 minutes.
- **Score**: at the time limit the highest D6 score (population + treasury / 10 + land cells + army supply; without
  `scripts/population.lua` a city counts 40 / 150 / 400 residents by tier) wins with its allies; a tie with a
  non-ally is a draw. Victory = Score with an unlimited time limit becomes 60 minutes.
- Annihilation stays `match.lua`'s fallback (`check_out`).

Lobby (Nation only): **Victory** Conquest | Territory | Score and **Time limit** 60 | 90 | 120 min | unlimited
(defaults Conquest, unlimited); `/rts-match ... nation territory t90` does the same. The config line and the strip's
goal line name them ("Hold 60 % of the land for 3 minutes, or conquer. Time limit: 87:12"). The results window of a
Nation match names the victory ("Score victory at the time limit: You, AI 2") and adds Score (tooltip: its four parts)
and War score columns.

### Panel and alerts (`scripts/diplomacygui.lua`)

F4 (custom input `rts-diplomacy`, dispatched through hud.lua's new key table `P4.KEYS`) toggles a centred panel:
victory mode, time left, our score; a War goal drop-down (nearest city | capital | tribute); one row per nation (name
in its colour, state, their opinion as a bar and number with both opinions and the last reason in the tooltip, trade
volume, war score and weariness, buttons War / Ceasefire / Peace / Alliance (Leave while allied) / Gift 100 cr (needs
the treasury) / Contract (opens `marketgui.open_contract(player, force)` when m2-treasury provides it)); one row per
city-state; our wars (goals, time, score, weariness, ceasefire countdown); proposals to us with Accept / Decline.
Proposals to a human also arrive as an alert (kinds `diplomacy-*`, styled in hud.lua; the position is the proposer's
capital, so F3 cycles to them) and in a small offers frame centred under the alert lines with Accept / Decline. Answers
to our proposals come back as alerts with the reason. The panel refreshes every second and at once on a state change.
Escape closes it. Outside Nation mode F4 says "Diplomacy exists in Nation mode only".

## 3. The targeting audit

Every force test that decides whom to attack now asks `diplomacy.hostile` (marker `-- Phase 5 M2 diplomacy`):

| File:line (copy) | Was | Now |
|---|---|---|
| `scripts/orders.lua:731` `pick_enemy` (right click) | `force.is_enemy(e.force)` | `diplomacy.hostile(force.name, e.force.name)` |
| `scripts/orders.lua:579-582` `orders.attack` | attacked any entity | refused (0 units, flying text for a player) when the target's nation is not at war with the ordering force |
| `scripts/orders.lua:788` right click | a click on a peaceful nation's unit or building was a move | refused with the message (Nation only) |
| `scripts/ai/scout.lua:47` `is_enemy` (building scan, unit counts, visible units, beaten enemy) | `force.is_enemy(other)` | `diplomacy.hostile` |
| `scripts/ai/scout.lua:187, 194, 207` harass targets | seen haulers and known buildings of any force once seen | only of hostile nations (a peace since the sighting ends them) |
| `scripts/ai/scout.lua:212` harass poles | `p.force.name ~= C.force and is_enemy` | `diplomacy.hostile` |
| `scripts/ai/scout.lua:222` patches near enemy spawns | `f ~= C.force and is_enemy` | `diplomacy.hostile` |
| `scripts/ai/scout.lua:302` `best_target` | every known building and spawn guess | hostile ones only; targets carry `force` |
| `scripts/ai/army.lua:408` attack and defence groups | kept a target until the 10 s re-target | re-target at once when the target's nation is no longer hostile |
| `scripts/ai/raids.lua:257` harass groups | target gone only when dead | also gone when its nation made peace |
| `scripts/abilities.lua:353` `enemy_near` (artillery follow-up) | `e.force ~= force and force.is_enemy(e.force)` | `diplomacy.hostile` |
| `scripts/abilities.lua:378` artillery strike | shells hit every other force ("not-same") | refused near a unit or building of a nation at peace or an ally (Nation only) |
| `scripts/commander.lua:280` kill credit | `killer.force.is_enemy(victim.force)` | `diplomacy.hostile` |
| `scripts/commander.lua:450` Commander right click | `force.is_enemy(e.force)` | `diplomacy.hostile` |
| `scripts/territory.lua:890` attrition | units of any other force deep in foreign land | units hostile to the land's owner only (no attrition at peace or between allies) |
| `scripts/mapgen.lua:1116` ruin and port capture | any force other than the owner | a force at war with the owner (an unowned ruin: anyone) |
| `scripts/match.lua:255-283` enemy unit counts (HUD "vs") | every other participant | hostile participants while the match runs; every other participant after the end, as before |
| `scripts/match.lua` victory | annihilation only | `check_out` kept as the fallback; Nation victory modes in `wars.victory_step` (alliance-aware) |
| turrets | engine | engine: the state mapping sets cease-fire and friends, so turrets follow it |
| `scripts/fog.lua:59` charted forces | rts-player and forces with players | plus their allies; never rts-neutral |

Kept on purpose (not targeting; engine queries already follow the mapping):

| File | Test | Why kept |
|---|---|---|
| `orders.lua` retarget and sweep, `divisions.lua` arrive and stances, `match.lua` wave retarget | `surface.find_nearest_enemy` | the engine's enemy relation, set by the mapping (peace and alliance are never found) |
| `ai/army.lua` `army.init` rally, `ai/commander.lua` facing, `mapgen.lua` spawn geometry | `f ~= C.force` over spawns | geometry of the own base, not targets |
| `ai/hubs.lua` candidates, `ai/build_order.lua` hostile_positions, `scout.lua` `enemy_bases`, `scout.seed` | `rec.force ~= C.force` | expansion avoidance and harass safety: foreign land is foreign at peace too; guesses are filtered at use |
| `hud.lua` base-attacked, kill feed | damage source | not a target choice |
| `ages.lua` age-up print, `selection.lua`, `citygui.lua`, `buildings.lua`, `rails.lua` foreign depot, `divisions.lua` reinforce | ownership | own vs not own |

## 4. Numbers

### 4.1 Skirmish unchanged

`SEED=777 KEEP_TREE=... tools/autotest-matrix.sh` on HEAD 22d2dd0 (pristine `git archive` copy) and on this copy:

| Scenario | HEAD | Copy | `[rts]` lines compared | Differing (non-timing) |
|---|---|---|---|---|
| 1v1-easy-medium | 23/23 | 23/23 | 1243 | 0 |
| 1v1-hard-medium | 20/23 | 20/23 | 3939 | 0 |
| 1v1-normal-medium | 23/23 | 23/23 | 3308 | 0 |
| 1v1-normal-small-nosa | 23/23 | 23/23 | 3395 | 0 |
| 1v1-normal-small-restart | 23/23 | 23/23 | 4487 | 0 |
| 1v2-normal-medium | 31/31 | 31/31 | 4634 | 0 |
| 1v3-normal-small-stress | 36/38 | 36/38 | 4117 | 0 |
| 1v3-normal-small | 39/39 | 39/39 | 5016 | 0 |
| legacy-units, legacy-units-nosa | 65/65, 65/65 | 65/65, 65/65 | 468, 469 | 0 |

The hard and stress failures are the same at HEAD. The table is the final tree (`matrix-p5m2dipl-wt2`); an earlier
tree (`-wt1`) gave the same result.

### 4.2 Natural 60-minute matches (4 nations, 2048, normal, SPEED=10, PERF=1)

Two seeds on the tree before the last two tuning changes (the rivalry towards weaker neighbours and the offer cooldown),
one on the final tree; HEAD 22d2dd0 (free-for-all from the first second) on the same seeds for comparison.

| Seed, doctrines | Diplomacy | Autotest (copy / HEAD) |
|---|---|---|
| 702, seeded (aggressive, economic, economic; the player AI economic) | 15:36 rts-ai-1 (aggressive) declares war on its nearest neighbour rts-ai-2 (relation -21 < -20, power ratio 1.01 > 1.0); 20:54 rts-ai-1 offers a ceasefire (weariness 56 % > 50 %), rts-ai-2 accepts after 18 s ("accept-weary", 50 % > 30 %), peace at 23:58 (white); 34:36 the second war (relation -68 after the first); rts-ai-2 offers a ceasefire twice, declined ("decline-winning"), then peace with a tribute of 40 cr per minute for 10 minutes, accepted ("accept-terms") at 42:00 | 63/67 / 65/66 |
| 701, aggressive, turtle, aggressive (the player AI economic) | no war: both aggressive AIs drift to relation -51 towards the turtle between them (their nearest neighbour), but the turtle out-powers them (ratio < 1.0) all match long, so the doctrine table holds them. The rivalry towards weaker reachable neighbours was added after this run | 64/66 / 61/65 |
| 703, seeded (aggressive, economic, economic; the player AI economic), final tree | 17:36 rts-ai-1 (aggressive) declares war on rts-player (relation -25, ratio 1.20); the economic side offers ceasefires twice (ratio 0.60 < 0.8), declined while the aggressor wins; 26:49 the aggressor offers one (weariness 60 % > 50 %), rts-player accepts ("accept-weary", 30.3 % > 30 %), white peace at 29:58. No second war: the aggressor stays the weakest nation (118-128 against 138-140) | 69/69 / not run |

The copy's failures are M1 economy checks that HEAD hides by war: in 702 the two economic AIs build hubs whose haulers
make 0 trips and open no rail line in 60 minutes (`hub_rts-ai-2/3`, `rail_line_rts-ai-2/3`); at HEAD the same AIs show
the same 0 trips, but they lose their capitals at 35:03 and 53:23, which excuses the checks. In 701 `rail_line_rts-ai-1`
fails in both, and HEAD also fails `rail_line_rts-ai-2`, `train_items` (2,917) and `no_bad_spam_rts-ai-2`. One copy
failure in 701, `harass_rts-ai-3` (an aggressive AI at peace all match has nobody to harass), is excused by the final
tree.

### 4.3 Performance

| Module (PERF=1 label) | Mean ms/tick over 61 minutes | Worst minute |
|---|---|---|
| diplomacy | 0.0007 (701), 0.0009 (702), 0.0009 (703) | 0.0038 |
| wars | 0.0001 | 0.0016 |
| diplomacygui (no client: offers poll only) | 0.0001 | 0.0011 |

`diplomacy.hostile` calls from orders, scout and territory count under those modules; in Nation mode they are a table
lookup.

### 4.4 Save and load, M1 acceptance

- **Save and load** (`SAVE_MINUTE=3 tools/saveload-check.sh p5dipl-sl`, 4 nations, seed 611, probe
  `diplomacy_saveload.lua`): before the save a war (rts-ai-1 on rts-ai-2) goes on, rts-player and rts-ai-3 are allied, a
  tribute runs (rts-ai-1 pays rts-ai-3 10 cr per minute) and a ceasefire proposal waits for its answer (due at 185 s,
  the save is at 180 s). After the load the proposal is answered ("decline-winning"), the tribute keeps paying (4, 3, 2
  minutes left), every state is the same, 0 errors in both halves.
- **M1 acceptance** (seed 501, 1v1, 60 minutes, `m1_acceptance.lua`, PERF=1): 41/41 (the 39 M1 checks plus
  `diplomacy_engine` and `diplomacy_summary`), 0 errors, 26,852 items by train, the last five minutes at speed 1 in
  60.007 / 60.000 / 59.997 / 59.999 / 60.098 s of wall clock (60 UPS). The match starts at peace; the aggressive AI
  declares war at 15:36, the economic one offers ceasefires from minute 21 (four times, declined while the aggressor wins), the aggressor
  offers one at 30:50 and the economic side accepts ("accept-weary"), peace at 33:58. Both sides attack during the war
  (3 attacks each), so `attack_<force>` passes without the peace excuse.

### 4.5 GUI runs (`tools/gui-run.sh`, real client, Russian locale)

- `diplomacy_charts_gui.lua` (1v2 Nation, 1536): the player's force has 0 chunks around rts-ai-1's capital charted
  before the alliance and 18 of 25 ten seconds after it (`share_chart` plus `fog.lua` charting the ally). A 1v1 run of
  the same probe ended at once in an allied victory: two nations allied are every remaining nation.
- `diplomacy_panel_gui.lua` (1v2 Nation): the lobby shows Victory and Time limit rows; F4 opens the panel through the
  key table; War on rts-ai-1 (goal: its nearest city) declares; Ceasefire is answered "declined: they are winning the
  war" after 18 s; rts-ai-2's alliance offer appears as an alert and in the offers frame under the alert lines, Accept
  makes the alliance; at the time limit the results window shows "Score victory at the time limit: You, AI 2" with
  Score and War score columns. Screenshots: `build/shots-p5dipl-pgui/` (lobby, panel-peace, offers, panel-answers,
  results). The first run found the action buttons cut off in Russian (the panel now grows with its buttons), the
  Skirmish texts "both sides are destroyed" / "the enemy base and army destroyed" after a Nation draw or victory and the
  Skirmish goal in the strip (both now name the victory mode).

## 5. Shared hunks (all marked `-- Phase 5 M2 diplomacy`)

| File | Lines (copy) | What |
|---|---|---|
| `control.lua` | 53-59 | require diplomacy, wars, diplomacygui after ledgergui |
| `prototypes/inputs.lua` | 68-70 | custom input `rts-diplomacy` (F4) |
| `balance.lua` | 465-end | `balance.nation.diplomacy` (relations, doctrine table, power, wars, victory) |
| `scripts/match.lua` | 44, 53, 154-157, 188-197, 255-285, 510-528, 709, 781, 819, 1012, 1022, 1111-1126 | balance require; `match.NEUTRAL`; `match.on_started`; victory and time limit in `normalize_config`; hostile enemy counts; `rts-neutral` in `setup_forces`; winners reset; on_started call; result texts by victory; shared winners; `match.finish_by` |
| `scripts/lobby.lua` | 29-30, 52-53, 74-79, 165-181, 194, 272-330, 381, 421, 467-470, 551-552 | Victory and Time limit rows, pending fields, config line, results window (victory line, Score and War score columns, width 720), start config, selection handler, console args |
| `scripts/fog.lua` | 9-12, 26-31, 47-72, 132 | allies charted, rts-neutral never, its share_chart off |
| `scripts/orders.lua` | 60, 550-582, 731, 787-797 | hostile pick, attack refusal |
| `scripts/hud.lua` | 325-333, 1627-1628, 1638-1643, 2283-2295 | alert styles `diplomacy-*`, victory / draw texts, Nation goal line, key table `P4.KEYS` |
| `scripts/ai/scout.lua` | 23, 47, 187, 194, 207, 212, 222, 302-322 | the audit above |
| `scripts/ai/army.lua` | 35, 407-412 | stale target re-target |
| `scripts/ai/raids.lua` | 20, 257 | harass target gone at peace |
| `scripts/ai/autotest.lua` | 48, 95, 434-442, 452-464, 555 | peace excuses for attack and harass, Nation diplomacy checks |
| `scripts/abilities.lua` | 48, 69, 353, 378-390 | hostile follow-up, artillery refusal |
| `scripts/commander.lua` | 54, 280, 450 | hostile kill credit and right click |
| `scripts/territory.lua` | 60, 890 | attrition hostile only |
| `scripts/mapgen.lua` | 1116-1123 | ruin capture needs war with the owner |

Own files: `scripts/diplomacy.lua`, `scripts/wars.lua`, `scripts/diplomacygui.lua`, `locale/{en,ru}/diplomacy.cfg`.
Test probes: `tools/probes/diplomacy_smoke.lua`, `diplomacy_accept.lua` (PROBE_MODE main | score),
`diplomacy_saveload.lua`, `diplomacy_charts_gui.lua`, `diplomacy_panel_gui.lua` (the last two for `tools/gui-run.sh`:
copy the mod, append `require("scripts.<probe>")` to control.lua).

## 6. Interfaces for the other M2 packages

- **m2-war**: emit `events.emit("rts_city_captured", {city_id, from, to})` from `capture.flip`; register
  `wars.on_cede(function(city_id, to, from) capture.flip(city_id, to) end)`; `wars.targets(force)` for army targets;
  `diplomacy.hostile` for every new target test (garrison turrets follow the engine mapping).
- **m2-treasury**: `treasury.charge/add/get` are looked up at call time (gift, tribute, D6 score). Diplomacy listens
  to `market.lua`'s signal `rts_contract_event`: "delivered" counts +3 both ways and its `value` as trade between the
  pair, "missed" -8 from the wronged side (`fault` = "seller" | "buyer"). A contract proposal passes its terms to
  `market.contract(seller, buyer, item, n_per, deliveries, interval_seconds, price_per_unit)`.
  `marketgui.open_contract(player, other_force)` makes the panel's Contract button work; `market.price(item)` feeds the
  power estimate. Both modules create `rts-neutral` idempotently; neither changes the other's use of it.
- **m2-people**: `population.of(city_id).pop` feeds city capture points and the D6 score.
- **m2-world**: city-states are cities of `rts-neutral` (rows in the panel); a "claimable" `territory.share` (water and
  mountains excluded, city-state land included) is what Territory victory reads.
- **m2-ai**: `diplomacy.ai_step(force)` is the doctrine table; set `diplomacy.AI_SELF_SCHEDULE = false` to call it
  from the strategist; `diplomacy.ratio`, `wars.weariness`, `wars.active` for its own decisions.

## 7. Open issues

1. **Start state: confirmed by the lead (2026-10-16).** Nation matches start at peace (`start_state = "peace"`) with the
   rivalry term; `"war"` stays as the balance override for the M1 free-for-all. At peace the AI armies have no target until a war, so the M1 Age I reach logic
   rarely matters, and the aggressive doctrine fights from Age II (minute 15-18 in the runs above).
2. **War frequency is the doctrine table plus power.** In seed 701 both aggressive AIs reached relation -51 towards the
   turtle between them but were weaker than it all match (ratio < 1.0), so no war; the rivalry towards weaker reachable
   neighbours (added after that run) gives them other targets when one exists. Seeds 702, 703 and 501 had a war each;
   in 701 the aggressive AIs never out-powered their neighbour. The end-to-end "≥ 1 war in ≥ 4 of 5 seeds" is for `m2-ai` /
   `m2-integ` to tune (for example an aggressive AI that builds towards a winning ratio); every knob is in
   `balance.nation.diplomacy`.
3. **Economic AIs at peace show M1 economy gaps (handed over to wave B, `m2-ai`).** In 4-nation 60-minute matches the
   economic AIs' hubs make 0 hauler trips and some AIs open no rail line (`hub_<force>`, `rail_line_<force>`). HEAD has
   the same 0 trips on the same seed but hides the checks because those AIs lose their capitals in the free-for-all.
4. **Territory victory needs claimable cells (handed over to `m2-world`).** `territory.share` still divides by every
   grid cell (M1), so 60 % of a 2048 world (water and mountains included) is out of reach in practice. `m2-world` owns
   `world.claimable` and the `territory.share` denominator (water and mountains out, city-state land in);
   `wars.victory_step` reads `territory.share` and needs no change.
5. **City-states are targets.** By D7 `rts-neutral` is at war with every nation, so an AI's scouting records seen
   city-state buildings and its army may pick them as targets even while every nation is at peace (with turrets that
   can be a costly attack). `m2-war` (city targets, capture) and `m2-ai` should decide when that is wanted.
6. **Weariness without captures.** Until `m2-war` emits `rts_city_captured`, wars end by weariness from unit losses,
   by duration (+1 % per minute after 10 minutes) or after 45 minutes; the city and capital terms of weariness and war
   score are only exercised by the probe's simulated capture.
7. **Gift and Contract** stay disabled until `scripts/treasury.lua` and `scripts/marketgui.lua` (`open_contract`) exist;
   tribute and cession are logged only without the treasury and the `wars.on_cede` hook.
8. **Allied victory.** When every remaining nation is in one alliance the match ends in a shared victory, so a human who
   allies with the only other nation left ends the match at once. AI nations ally only with a common enemy, so in a
   1v1 the AI never accepts.
9. **Chart sharing detail.** In the GUI run the ally's area counts as charted for the player, while
   `is_chunk_charted` of the ally force itself stays false around its own capital (the engine seems to keep the shared
   chart on one side). The player sees the ally's base, which is the requirement; the Codex GUI protocol should still
   look at the map view of an alliance.
10. **F4** replaces vanilla's F4 (debug settings) while the RTS mod runs.

## 8. Sync into mods/factorio-rts (after the lead's "sync open")

- 21:52: `mods/factorio-rts` was clean at 0abb79b (M1 QA round 1). The 16 shared files took the 65 hunks of
  `build/p5m2-diplomacy/shared-hunks.patch` without conflict (`control.lua` and `hud.lua` at an offset after the QA
  round's changes). The own files were copied. No other M2 package had synced yet. The two `.orig` backups from
  `patch` were removed.
- Before the sync, `diplomacy.lua` got m2-treasury's contract events (signal `rts_contract_event`, section 6).
- The synced tree was snapshotted (`build/p5dipl-sync-tree`) and tested at seed 777 against a clean 0abb79b
  (`build/p5dipl-base-0abb`):

| Scenario | 0abb79b | Synced | `[rts]` lines compared | Differing |
|---|---|---|---|---|
| 1v1-easy-medium | 23/23 | 23/23 | 1238 | 0 |
| 1v1-hard-medium | 20/23 | 20/23 | 4064 | 0 |
| 1v1-normal-medium | 23/23 | 23/23 | 3267 | 0 |
| 1v1-normal-small-nosa | 23/23 | 23/23 | 3321 | 0 |
| 1v1-normal-small-restart | 22/23 | 22/23 | 4492 | 0 |
| 1v2-normal-medium | 31/31 | 31/31 | 4519 | 0 |
| 1v3-normal-small-stress | 34/38 | 34/38 | 3383 | 0 |
| 1v3-normal-small | 39/39 | 39/39 | 5054 | 0 |
| legacy-units (smoke), legacy-units-nosa | 65/65, 65/65 | 65/65, 65/65 | 468, 469 | 0 |

  0abb79b's own failures (restart 22/23 and stress 34/38, compared with 23/23 and 36/38 at 22d2dd0) come from the M1 QA round
  and show the same in both trees. The 4-nation acceptance probe on the synced tree is 12/12 (`p5dipl-acc-sync`), with
  0 Lua errors everywhere.
- Afterwards m2-treasury synced its own hunks. They include `rts-market` (M) in hud.lua's `P4.KEYS` next to `rts-diplomacy`,
  and every diplomacy hunk is still in place.
- The lead's rule on scouting: `scout.beaten_enemy` and `C.known` stay restricted to match participants even though
  `diplomacy.hostile(ai, "rts-neutral")` is true. "Hostile" means the AI may fight, not that the city-states are a
  rival to finish. The `beaten_enemy` part is in `mods/` already: m2-treasury's hunk "M2 treasury / world" sits next
  to the diplomacy lines in `ai/scout.lua`, and both are kept. The `C.known` part comes with m2-world's sync, which
  merges on top of the diplomacy lines; m2-world was told which lines those are.
