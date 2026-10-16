# Phase 5 M2: supply, capture, garrison and military trains (warsupply.lua, capture.lua, garrison.lua)

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam), Space Age on unless noted. Agent: `m2-war`. Contract:
`docs/PHASE5-M2.md` (D4, D8; section 3 "warsupply.lua / capture.lua / garrison.lua"; section 4 "War"). Studies:
`docs/research/scale/war-ai-performance.md` sections 2.2, 2.5, 2.6; `docs/research/scale/rails-trade.md` section 3;
`docs/research/scale/deep-economy.md` section 6. Work copy: `build/p5m2-war/factorio-rts`, built on HEAD 22d2dd0 and
rebased onto the M2 wave A snapshots 5874e54 (diplomacy, treasury, people) and 9dc92d7 (people final, world) with
three-way merges (`build/p5m2-war/sync.sh`, base 9dc92d7), and synced into `mods/factorio-rts` on 9dc92d7 (no
conflict; the synced tree is identical to the copy). Everything here is Nation mode only; Skirmish runs exactly as
before (smoke 65/65).

**On `mods/` after the sync:** Skirmish smoke 65/65, rails autotest 12/12, divisions functional probe 25/25, war
autotest 27/27, save/load during a capture and a troop ride PASS; 0 Lua errors in every run.

## 1. Results

| Contract check (section 4 "War") | Result | Evidence |
|---|---|---|
| A division at 0 SP loses 1.5 % of max health per 10 s | PASS | 8 walkers lost 3.00 % in 21 s (two passes) |
| ... and refuses attack orders | PASS | `divisions.order` false, `orders.attack_move` to its members 0 ordered; a loose unit 14 tiles away refused too, one 200 tiles away obeyed |
| A depot with crates refills it and its network loses the crates | PASS | 0 → 20.3 SP in 61 s next to a hub, crates 20 → 17 (1 crate per 10 SP started) |
| A scripted capture flips a 3,000-entity city within 8 ticks of slices | PASS | 3,132 entities in 7 slices over 8 ticks, 20 ghosts destroyed |
| No entity of the old force remains on its land | PASS | 0 entities of the old owner on the city's cells after the job |
| Production resumes after 60 s | PASS | the factory of the city: disabled at 30 s, 33 → 33 crafts in unrest, 47 at 75 s |
| Population x0.7 | PASS | 100 → 70 (stand-in `storage.population`; `population.remove` when m2-people's module is there) |
| The capital moves | PASS | the loser's capital is its second city |
| A troop train carries 12 walkers 600 tiles; they disembark within 10 s with health within 1 % | PASS | 600 tiles in 21.2 s, back on the map 0.1 s after the arrival, worst health difference 0.00 %, SP 60 → 59.9 |
| A destroyed loaded wagon removes its units and alerts | PASS | 6 aboard: division gone, manifest gone, alert `troop-wagon-lost` |
| Save/load during a capture and with manifests in transit: 0 errors | PASS | saved at job slice 865 of 3,102 and 12 units in a moving wagon; after the load the capture finished (0 old entities left, pop 70) and the 12 got out at the far depot; 0 errors in both halves |
| Disbanding a train returns 50 % of its kits | PASS | 2 locomotives + 2 wagons → +1 locomotive kit, +1 wagon kit |
| 1v1 Nation 2048, seed 501, 60 minutes: M1 checks with at least one AI capture attempt | PASS on the M1 base, see 7.3 for the M2 base | 22d2dd0 base: 39/39 on seeds 501 and 402, capture attempts by both AIs, 4 captures on 501; M2 snapshot base: section 7.3 |
| Skirmish smoke 65/65 unchanged | PASS | 65/65 on the copy and on the merged tree |
| The war modules ≤ 0.2 ms per tick with 4 nations x 12 divisions | PASS | 0.02-0.057 ms per tick for warsupply + capture + garrison together (section 7.4) |

Scripted war autotest (`tools/probes/war_autotest.lua`): 27/27, 0 Lua errors, on every base (22d2dd0, 5874e54,
9dc92d7; with m2-people's population and labor the unrest goes through them). Further checks in it: the centre clamps at 10 % (180 of 1,800 HP), the contest takes 20 s, the
land and the city record follow, `rts_city_captured` is emitted, the centre restarts at 25 %, a captured depot's stops
take the new owner's name, low supply takes back the Armor II/III heal (50 lost while low, 40 while supplied with 20 %
armor), garrison entry (12 walkers: 12 points, 3 guns, supply kept), the hidden guns kill two walkers within 1.7 s, a
sortie returns the division at its old SP, an automatic sortie below 50 % health, the right-click garrison path.
Elimination probe: PASS, through a treaty that cedes the last city when m2-diplomacy is there (section 7.2). GUI
probe in the real client: 9/9 on 22d2dd0, 5874e54 and 9dc92d7 (section 7.5).

## 2. Files

| File | Status | What it does |
|---|---|---|
| `scripts/warsupply.lua` | new | Supply points, depots, crates, low/out effects, loose units, field depot, recipes per force, the AI's crate policy |
| `scripts/capture.lua` | new | Subdue clamp, contest, `capture.flip` and its sliced job, unrest, capital move, elimination, treaty hook |
| `scripts/garrison.lua` | new | Garrison records, hidden guns, sorties; troop train boarding, manifests, disembark, wagon loss; right-click hook |
| `prototypes/war.lua` | new | `rts-supply-crate` (2 recipes), `rts-field-depot`, `rts-troop-wagon` + kit, hidden `rts-garrison-turret` |
| `locale/en/war.cfg`, `locale/ru/war.cfg` | new | 50 keys each, the same in both |
| `tools/probes/war_autotest.lua` | new (test) | The scripted war autotest (27 checks) |
| `tools/probes/war_saveload.lua` | new (test) | Capture job and troop ride across a save |
| `tools/probes/war_eliminate.lua` | new (test) | A nation without cities is out |
| `tools/probes/war_perf.lua` | new (test) | 4 forces x 12 divisions x 16 walkers for PERF=1 |
| `tools/probes/war_gui.lua` | new (test) | GUI client probe with screenshots |
| `tools/probes/war_engine_probe.lua` | new (test) | Engine questions (clamp, flip cost, trains on foreign rails) |
| `build/p5m2-war/sync.sh` | tool | Three-way merge of the shared hunks into a tree (base 22d2dd0), copies the own files |

### Shared hunks (marked `-- Phase 5 M2 war`; line numbers in `mods/factorio-rts` after the sync)

| File | Lines | Hunk |
|---|---|---|
| `control.lua` | 53-58 | require warsupply, capture, garrison after districts |
| `data.lua` | 21 | require `prototypes.war` (after `prototypes.trade`) |
| `balance.lua` | 762-801 | `balance.nation.war`, `balance.buildings["rts-field-depot"]` |
| `scripts/divisions.lua` | 50-54, 70-71, 89-90, 353, 457-481, 523-539, 543, 717-718, 791, 913 | header; `ORDER_HOOKS`, `order_lock`; `aboard(D)` keeps a division whose members ride a train; `divisions.attach`; the attack lock in `order`; a refused re-target ends the attack-move |
| `scripts/divisiongui.lua` | 31-52, 123-125, 165-169, 205-209, 244-247, 274-281, 296-302, 312-318, 334-335, 340-343, 419-425 | supply bar, train/garrison states, garrison row and Sortie |
| `scripts/orders.lua` | 351-374, 390-391 | `orders.unit_lock` drops units out of supply from attack orders, flying text |
| `scripts/buildings.lua` | 222-257 | `main_cc` prefers an own CC to a captured one; `buildings.set_force`, `buildings.on_force_changed` |
| `scripts/territory.lua` | 685-725 | `territory.set_source_force`, `territory.city_box` |
| `scripts/cities.lua` | 129-133, 306-378 | `supply_of` for a City Center capital and a captured CC; `cities.set_capital`, `cities.change_owner` |
| `scripts/rails.lua` | 83-89, 132, 172-177, 1267-1269, 1294-1307, 1323-1325, 1394, 1407, 1416, 1427, 1437-1444, 2257, 2322-2467, 2807-2808, 2856, 2929 | troop wagon names and hooks, `kit_list`/`create_train` "troop", `FREIGHT` kinds in routes, `depart_train`, captured depot handler, `disband_train`, the dwell and died hooks |
| `scripts/railgui.lua` | 111, 122-124, 171-173, 192-196, 227-231, 299-311 | troop train title and troops line, Disband, Deploy troop train |
| `scripts/hud.lua` | 151-153, 172-173, 274-275, 353-361 | `P4.NATION_ONLY` items/recipes, factory Logistics tab, field depot in the Production tab, 5 alert styles |
| `scripts/ai/army.lua` | 71-209, 359-360, 511-533, 560-567, 582-589, 599-600 | city and city-state targets, capture timing, reinforcements join, low supply return, crates (`warsupply.ai_step`) |

Conflicts met in the rebases, resolved by keeping both sides: `hud.lua` (people's and war's `P4.NATION_ONLY` lists,
Production tab items and alert styles at the same anchors), `ai/army.lua` (diplomacy's `stale` check and war's low
supply return before the retreat test), `data.lua` and `balance.lua` (trade and people blocks at the same anchors).

No hunk in `match.lua` (the elimination uses its existing out check), `supply.lua` (garrison.lua wraps `supply.used`
at load), `logistics.lua` (capture.lua updates a hub policy's force and its network cache through `storage.logistics`
and calls `logistics.return_home` for the old owner's haulers), `research.lua` (warsupply.lua takes the Armor heal back
in its own damage handler) or `production.lua`.

## 3. Supply (`scripts/warsupply.lua`)

- **Supply points.** `D.sp` (0..100) in `storage.divisions[id]`. Each division is stepped every 60 ticks (staggered):
  - use per minute: idle 0, moving 2, engaged 8 (a member hit or was hit within 300 ticks), +2 on foreign land;
  - refill: within 64 tiles (2 chunks) of a depot of its force whose network holds crates, +20 per minute; a crate is
    taken from that network each time the division's credit runs out and buys 10 SP.
- **States.** supplied ≥ 50, low 1-49, out 0. A state change logs `war: division #N ... supply low -> out` and alerts
  the owner (`supply-low`, `supply-out`).
  - low: the Armor II/III heal of research.lua is taken back in warsupply's own `on_entity_damaged` handler (it runs
    after research's); the card's supply bar turns amber; the AI starts no offensive.
  - out: 1.5 % of max health every 600 ticks (health write, `die()` at 0; the Commander is spared) and attack orders are
    refused: `divisions.order_lock` for division orders (stance and re-target orders included), `orders.unit_lock` for
    orders to units (the player sees "N unit(s) out of supply take no attack order ...").
- **Depots** (`warsupply.depots(force)`): every building of kind `cc` or `hub` of the force: the Command Center, City
  Centers, hubs, rail depots, field depots. `storage.warsupply.depots[force]` follows the registry, force changes too.
- **Field depot** (`rts-field-depot`): a small roboport (logistic radius 8, construction 12, 600 HP), a hub subtype, so
  logistics.lua completes it (hidden power and pole, two stockpiles, robots) and haulers and trains serve it. It keeps 20
  crates by default (not the hub's plates), is named "Field depot N", builds on own or neutral land (territory class
  outpost) and adds no supply cap (a `supply.on_cap` hook takes the hub's +10 back). Build menu: Production tab; the
  Commander's field construction builds its ghost like any other.
- **Loose units** take the state of the nearest division of their force within 24 tiles of them (recomputed every 60
  ticks for divisions that are low or out), else they are supplied.
- **SP memory.** A unit leaving a division (disband, detach to another) remembers the division's SP
  (`storage.warsupply.unit_sp`); a division formed or joined by such units starts at their average; garrison and troop
  records keep it too. So disbanding, garrisoning or a train ride refills nothing. Remembered loose SP refills near a
  depot with crates (a crate pays 10 SP for 16 supply of units, the price of a 16-walker division), so a returned AI
  army can attack again.
- **Crates.** Factory recipes (Logistics tab): Age I `rts-supply-crate` (4 iron plates + 2 coal, 2 s); from Age II
  `rts-supply-crate-ii` (also 1 explosives) replaces it; both make the same item. `warsupply.apply_recipes` enables them
  per participant in a Nation match (at once at match start, every 10 s, on age change), the field depot recipe too,
  and the troop wagon kit once the force has Railways; teardown disables them. The hub panel lists crates only when a
  network holds some (own item subgroup `rts-war`), so Skirmish panels are unchanged.

## 4. Capture (`scripts/capture.lua`)

- **Subdue.** An `on_entity_damaged` handler for `rts-city-center` and `rts-command-center` (the shared filter already
  lists both) of a registered city: health below 10 % is set back to 10 %. Engine fact (probe A): a centre whose handler
  restores its health survives a 1e6 hit (event `final_health` 0). Only damage from a hostile force subdues and counts
  as siege; the owner's own splash or shells in flight after a capture only clamp. The capital armor of cities.lua heals
  before the clamp.
- **Contest** (every 60 ticks, mapgen's ruin rule): registered units within 24 tiles of the centre, haulers excluded.
  Defenders: the owner and its allies (`diplomacy.state == "alliance"`, else engine friends). Attackers: forces hostile
  to the owner (`diplomacy.hostile`, else `is_enemy`). One attacking force and no defender: progress, counted from the
  first sighting; 20 s of it captures. Nobody: progress resets. Contested: it holds. Repaired above 50 % or no attacker
  for 60 s: no longer subdued. A label over the centre shows "Subdued", "Contested: D defenders, A attackers" or "X
  captures: N %".
- **`capture.flip(city_id, force, why)`** (contest, treaty, tests) returns a job id:
  1. now: the centre and its hidden parts (CC core power and pole, hub power and pole, city power) change force through
     `buildings.set_force`; the centre restarts at 25 %; `cities.change_owner` (the loser's capital moves to its
     largest remaining city: population, then tier, then land cells, then lowest id); the garrison is lost;
  2. collect (next tick): entities of the old owner in `territory.city_box(city)` whose cell belongs to the city;
  3. slices of `capture.SLICE` (500) per tick: ghosts, tile ghosts and item-request proxies are destroyed; units,
     haulers, the Commander and rolling stock are left alone; registered buildings go through `buildings.set_force`,
     everything else gets `entity.force`; producers (factory, barracks, district, smelter, extractor, lab) are disabled
     by script for 60 s unless they already were; with m2-people's modules the unrest is
     `population.set_unrest(city, 3600)` instead (no worker works, labor.lua staffs every building at 0 %, and
     `labor.step_city` applies it at once at the flip and at the end of the job; a factory then makes 0 crafts in the
     unrest, measured);
  4. sweeps: the land is read again until nothing of the old owner is left (at most 3 more reads);
  5. finish: population x0.7 (`population.remove(city, 30 %, "capture")`, else the stand-in `storage.population`
     record), the old owner's AI plan forgets the buildings it lost (status "bad"), alerts
     (`city-captured` for the winner, `city-lost` for the loser), signal `rts_city_captured {city_id, from, to}`; a
     participant without a city left is eliminated: its units and its CC/barracks/factories die, so `match.is_out` holds
     at match.lua's next check (probe: "rts-ai-1 is out at 121s", the match ends).
- **Force changes** (`buildings.on_force_changed`): territory source force (`territory.set_source_force`), hub policy
  force and both forces' network caches, the old owner's haulers bound to the hub go home, warsupply's depot sets, and
  in rails.lua a captured depot: its stops take the new owner's name (trains find stops by name across forces: probe C),
  its line is "lost" to the old owner, the old owner's trains bound to it stop ("its depot was captured"), and an AI
  rail program built around it starts again.
- **A captured city keeps its land radius** (a captured capital would otherwise shrink by the capital bonus and strand
  the old owner's buildings in the ring). `buildings.main_cc` prefers a force's own Command Center to a captured one, so
  the winner's base logic stays at home; a captured CC counts its tier's full supply.
- **Treaties.** `wars.on_cede` (m2-diplomacy) is registered at load when `scripts/wars.lua` loaded first, else at the
  first contest step: a ceded city goes through `capture.flip(city_id, to, "ceded by treaty")` (probe: a treaty ceding
  rts-ai-1's last city flipped it, population 185 → 129, and eliminated rts-ai-1).
- **City-states** (m2-world, cities of `rts-neutral`, hostile to everyone) are captured by the same contest; they are
  never eliminated (not a match participant), and the AI does not go for them (they are no war goals).

## 5. Garrison and troop trains (`scripts/garrison.lua`)

- **Garrison.** Right-click the own City Center (or the capital's CC) with units selected, or
  `divisions.order(id, "garrison", city_id)` / `garrison.enter(division_id, city_id)`: members within 14 tiles of the
  centre become records {name, kind, health ratio, SP, division name and template, labor home}; the rest walk there
  and enter on arrival. Points = supply cost. Hidden guns (`rts-garrison-turret`: invisible, not selectable, no
  collision, indestructible, not a military target, the RTS turret's damage) stand on a ring of radius 5; one per 4
  points is enabled (at most 8), ammo is free (topped up to 20 magazines every 5 s). `garrison.of(city)` →
  {records, points, turrets}. Garrisoned units keep counting against the supply cap (`supply.used` is wrapped).
- **Sortie** (the division panel's button while the city is selected, `garrison.sortie(city)`, or automatically when
  the centre drops below 50 %): every record comes out next to the centre as one division (its name when all records
  share it, stance advance) at their SP. A captured city loses its garrison (counted as units lost).
- **Troop train.** 2 locomotive kits + 1-3 troop wagon kits (as many as the network holds); a troop wagon holds 16
  supply. Deployed by the depot panel's "Deploy troop train" or automatically when a division is told to embark at a
  depot with the kits; routed like a freight train (right-click a depot = pickup, Shift = drop-off).
- **Embark.** Right-click an own depot or its platform with units selected (loose units become a division first), or
  `divisions.order(id, "embark", depot_un)`: the division walks beside the track on the far side from the depot (trains
  kill units on the rails), next to the troop wagon when a train stands there. Members within 14 tiles of a troop wagon
  with room board: `storage.rails.manifests[wagon unit_number] = {force, wagon, records, supply}`, `D.aboard` counts
  them and keeps the division alive while all its members ride.
- **Leaving.** At the pickup (rails.lua calls `rails.troop_dwell` every 10 ticks while it stands at a stop) the train
  leaves for its drop-off when nobody is still walking to it, the wagons are full, or 30 s after the last boarding;
  without a drop-off it waits. At the drop-off every manifest gets out at once, 6 tiles off the track on the far side,
  the units rejoin their division (`divisions.attach`, a new division when it was disbanded) and walk 8 tiles clear;
  then the train returns to the pickup.
- **Losses.** A destroyed troop wagon kills its manifest (alert `troop-wagon-lost`, units lost in the match stats, an
  empty division disbands). A troop train without locomotives lets its troops out where it stands.
- **`rails.disband_train(train)`** (train panel "Disband", any kind, standing): half of each kit kind, then up to half
  of all carriages from the kinds with the largest remainder, into the network of the depot whose platform it stands
  on (else its home depot); cargo and coal go there too; troops get out first. A cargo train (2 + 2) returns 1 + 1.

## 6. UI and AI

- **Division card** (Nation mode): a second bar under the health bar, the supply points (blue supplied, amber low, red
  out), tooltip with the number, the state and the rules. State line: "On a troop train (N)", "Boarding a train",
  "Entering the garrison".
- **Garrison row** in the division panel while an own City Center is selected: "Garrison: N units, P points, G guns"
  and Sortie.
- **Train panel**: "Troop train N", "Troops: N units, S / C supply", Disband for every train. **Depot panel**: "Deploy
  troop train".
- **Alerts**: `supply-low`, `supply-out`, `city-subdued`, `city-captured`, `troop-wagon-lost` (styles in hud.lua);
  the loser gets `city-lost` with "X was captured by Y".
- **AI (`scripts/ai/army.lua`, Nation mode)**:
  - `warsupply.ai_step` (every 600 ticks): from Age II a crate make target 60 at the capital (with m2-diplomacy only
    while the force is at war or a division of it is below "supplied", cleared again at peace: on seed 402 crates made
    from minute 2 took rts-ai-1's one works factory away from the Railway Charter and cost it 4 minutes to Age II), the
    CC exports crates above 20, every other hub, City Center and depot keeps 20.
  - Capture operations: a main attack (not a reinforcement) goes for the nearest hostile city whose defenders (units
    within 40 tiles plus garrison points) are fewer than 60 % of the group; the group keeps that target until it is
    captured; reinforcement waves join the city operation under way; re-targets never switch to a new city.
  - When: `army.capture_ok(C)` if the nation strategist sets it; else with m2-diplomacy present while the force has war
    goal cities (`wars.targets`, which then are the only candidates; diplomacy decides war and peace); else from minute
    45 of the match. At most one operation per 15 minutes (balance `capture_from`, `capture_cooldown`). Section 7.3
    explains why. City targets carry `force`, so diplomacy's "stale target" check re-targets a group after a peace.
  - City-states (rts-neutral, archetype `city_state`) are deliberate capture targets only (`army.city_state_target`,
    lead's integration rule; scout.lua ignores rts-neutral buildings otherwise): from Age II and, without the
    strategist's `army.capture_ok`, from minute 45 like town captures, while the nation is at war with no other nation, when the attack group's supply is at least 1.5x the city-state's garrison points (4 per live
    turret of its garrison plus garrison records and defenders), its units are supplied, and the 15-minute capture
    cooldown has passed. The centre is subdued and captured, never razed.
  - A division of an attack group that is low on supply goes back to the rally point (`supply_returns`); the pool does
    not launch an attack while its units' remembered SP is low.
  - Log lines "ai F: capture attempt N on city C (owner, D defenders, group of G)".

## 7. Measurements

### 7.1 Engine probe (`tools/probes/war_engine_probe.lua`)

| Question | Verdict |
|---|---|
| A. Can `on_entity_damaged` keep a City Center / CC alive at final_health 0? | Yes: after a 1e6 hit, health 180/1800 and 300/3000 (set to 10 % in the handler); a second 1e6 hit the same |
| B. Cost of `entity.force` writes, 500 per tick | 0.36-3.9 ms per slice; 300 factories + 200 belts 1.3 ms, 500 belts 3.9 ms, inserters 0.4 ms, chests/poles/walls 0.4-0.6 ms |
| C. Trains and other forces' rails and stops | A train runs on another force's rails and stops at another force's stop by name (15 s, reached it), so a captured depot's stops must be renamed |

### 7.2 Probes

| Run | Result |
|---|---|
| War autotest (`war_autotest.lua`, 1v1 Nation, seed 501, speed 4) | 27/27, 0 errors, on 22d2dd0, 5874e54 and 9dc92d7 |
| Rails autotest (`rails_autotest.lua`) on the final copy | 12/12, 0 errors |
| Divisions functional probe (`MODULE=divisions_func tools/divisions-bench.sh`) on the final copy | 25/25 |
| Save/load (`war_saveload.lua` with `tools/saveload-check.sh`, capture.SLICE 3), every base | before the save: job at 865 of 3,103, 12 units aboard a moving train; after: troops out at the far depot (mean health 0.85, as boarded), capture done, 0 left, population x0.7 (100 → 70; 110 → 76.5 with m2-people's growth); 0 errors in both halves |
| Elimination (`war_eliminate.lua`), 22d2dd0 | rts-ai-1's only city given to rts-player at 2:00 by `capture.flip`: 194 entities flipped in 1 slice, 37 units died, "rts-ai-1 is out at 121s", winner rts-player; rts-player's main CC is still its own (2 CCs) |
| Same on 5874e54 and 9dc92d7 | by a treaty (`wars.end_war` with `{kind = "cede"}`, the on_cede hook): flipped, population 185 → 129, unrest through population, rts-ai-1 out at 121 s, winner rts-player |
| Skirmish smoke (legacy units) on the copy | 65/65, 0 errors, on every base |

### 7.3 1v1 Nation acceptance (seed 501, 2048, 60 minutes, M1 checks)

```sh
PERF=1 KEEP_TREE=build/p5m2-war/factorio-rts EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN=60 SEED=501 SPEED=6 \
  tools/autotest-run.sh p5m2war-acc3 '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048,
  enemy_brain = "ai"}' 4800
```

**On the M1 base (22d2dd0) the acceptance passes.** Final package, 60 minutes, speed 6, the last 5 minutes at speed 1:

| Seed | Result | Age II (player / AI) | Capture | Items by train |
|---|---|---|---|---|
| 501 | 39/39, 0 errors, 60 UPS in minutes 56-60 | 14:46 / 13:19 (as in M1) | one operation each after minute 45; the two towns changed hands 4 times; one group stopped its offensive on low supply | 20,640 |
| 402 | 39/39, 0 errors | 13:38 / 17:26 (as in M1) | one operation each | 24,983 |

War modules in that run: at most 0.013 ms per tick in any minute (warsupply 0.006-0.008, capture 0.002-0.006,
garrison 0.0002).

How the AI rule came about (same seed 501): with city targets from the start and reinforcement waves picking cities
on their own, the AIs went for each other's undefended mining towns from minute 19, captured one, recaptured it, and
fought along the rail lines: 38/39 with 8,747 items by train (M1: 26,000). In M1 every attack went for the other
capital's outskirts and the towns were left alone. Capture operations from minute 45 (one per 15 minutes, no swarm of
reinforcement waves) restored 39/39; making the AI's crates only from Age II fixed seed 402's rts-ai-1, whose one
works factory had made 96 crates instead of Railway Charter goods (Age II 21:54 → 17:26).

**On the M2 wave A base (9dc92d7: diplomacy, treasury, people, world) the package changes nothing at peace.** Same
command, my copy against the plain snapshot (`KEEP_TREE=mods/factorio-rts`):

| Seed | My copy | Snapshot alone | Notes |
|---|---|---|---|
| 501 | 53/53, 20,125 items | 53/53, 20,125 items | identical: no war declared, so no capture operation (diplomacy decides wars; `wars.targets` gives the goals) |
| 402 | 48/53 | 47/53 (`world_claimable` too) | the same 5 rts-ai-1 failures in both: no copper line, no Age II, no town, no line |
| 403 | 48/53, 7,728 items | 48/53, 7,728 items | identical, the same rts-ai-1 failures |
| 404 | 50/53, 18,312 items | 50/53, 8,219 items | the same Age II deadline failures (20:17 / 20:45) in both; one war each; with my copy rts-ai-1's army captured a city-state on its way (rts-neutral, 3 units, D7) |

**On `mods/` after the sync (with the lead's city-state rule, city-state operations from minute 45):**

| Seed | Result | Items by train | City-states |
|---|---|---|---|
| 501 | 53/53, 0 errors | 20,125 (as the snapshot) | capture attempts by both AIs after minute 45; city-states 3 and 4 captured |
| 404 | 50/53, 0 errors: the snapshot's two Age II deadline failures and `train_items` (snapshot 8,219) | 17,894 | city-state 4 captured by an operation; city-state 3 by rts-ai-1's war army in passing |

With city-state operations from Age II (the lead's floor) seed 501 fell to 52/53: three city-states taken by 26:00,
the marches across the rival's land dropped the relation to -55 and led to a war, and the freight total fell to 18,908.
Hence the minute-45 floor without the strategist's `army.capture_ok`, as for towns.

Earlier versions on this base showed why the crate rule matters: with crates made from Age II in peace, a war was
declared on seed 501 (relation -26, power ratio 1.08) where the snapshot had none, and the train total fell to 19,451.
The rts-ai-1 failures of seeds 402 and 403 and the late Age II of 404 are the snapshot's (the same lines without this
package).

### 7.4 Performance (`war_perf.lua`, PERF=1, speed 1)

Four forces of 12 divisions x 16 walkers (768 units) on a lab surface beside a 1v1 Nation AI match: forces 1 and 2
fight (a 192-against-192 battle in the first minute), 3 and 4 march 120 tiles every 40 s, four divisions start low and
two out of supply, hubs with 400 crates each.

| Minute (tick) | warsupply | capture | garrison | total | divisions (for scale) |
|---|---|---|---|---|---|
| 1 (3600, setup and battle) | 0.053 | 0.003 | 0.001 | 0.057 | 0.025 |
| 2 (7200) | 0.029 | 0.002 | 0.000 | 0.031 | 0.019 |
| 3-7 | 0.019-0.028 | 0.001-0.002 | 0.000-0.001 | 0.020-0.030 | 0.014-0.023 |

ms per tick, the events.lua profiler's per-module averages. Contract limit 0.2 ms: met by a factor of 3.5 at the peak.
The AI's war hunk runs inside `ai/init` (0.06 ms per tick for the whole AI there). A flip costs 0.4-3.9 ms in each of
its slice ticks (probe B).

### 7.5 GUI (`tools/probes/war_gui.lua`, real client, Russian locale)

9/9, 0 errors (on every base): supply bars (amber 30 SP, red 0 SP), the out division's refused attack-move (flying text), the
garrison hook (8 units), the garrison row "Гарнизон: 8 ед., 8 очк., орудий 2" with Вылазка, Sortie, "Deploy troop
train" on the depot panel, the troop train panel ("Войсковой поезд 8", "Войска: 0 ед., снабжение 0 / 32", Разобрать),
Disband returning half the kits. Screenshots: `build/shots-p5m2war-gui/rts-war-gui-{1-supply-bars,2-garrison,3-sortie,
4-depot-panel,5-troop-train-panel}.png`.

## 8. Storage

```
storage.warsupply = {unit_sp = {[un] = sp}, loose = {[un] = "low" | "out"}, loose_credit = {[force] = sp}, depots =
  {[force] = {[un] = true}}, field_index, field_number = {[un] = n}, ai = {[force] = {next}}, stats = {[force] =
  {crates, refilled, used, out_hits, out_kills, refused}}, recipes_match}
storage.divisions[id] += {sp, sp_credit, sp_tick, sp_members, engaged_tick, crates, depot, aboard, embark}
storage.capture = {cities = {[city] = {subdued, progress, capturing, attackers, defenders, last_attack, label}},
  jobs = {[id] = {city, from, to, box, phase, list, i, slices, sweeps, flipped, ghosts, unrest, people_unrest}},
  next_job, unrest = {[city] = {until_tick, entities}}, stats, last}
storage.garrison = {cities = {[city] = {force, records, points, turrets, enabled}}, pending = {[division] = city},
  pending_units = {[un] = city}, next_ammo, stats}
storage.rails.manifests = {[wagon un] = {force, wagon, records = {{name, kind, health, sp, division, dname, template,
  stance, soldier}}, supply}}
```

All three modules clear their tables in `match.on_teardown`; the turrets and labels are destroyed there.

## 9. Open issues

1. **AI war intensity against the M1 economy.** With city targets the AIs go for each other's undefended mining towns,
   and every capture or fight there ends a rail line. On seed 501 without a timing rule the train total fell from
   26,000 to 8,747 (M1 needs 20,000). Without m2-diplomacy the default capture window (from minute 45, one per 15
   minutes) applies; with it captures happen only in wars with city goals, and on the M2 base few 60-minute 1v1 matches
   have a war at all (0 or 1 per seed), so few capture attempts. m2-ai's strategist can decide (`army.capture_ok`);
   the M2 end-to-end target (a city changes hands in 3 of 5 seeds, 4 AIs) needs wars with city goals and enough
   attackers (defenders < 60 % of the group).
2. **Towns have no defence.** A town falls to a few units in 20 s once its centre is down. A relief response (send the
   pool to a subdued own city) and governor-built town defences belong to m2-ai.
3. **Rails as targets.** Attack-moves with distraction `by_anything` shoot rails on the way; lines near battles get cut
   and the AI repairs slowly.
4. **Labor and unrest.** With m2-people's modules the unrest uses `population.set_unrest` and `labor.step_city`;
   without them disabled_by_script. Garrison and troop records keep `storage.labor.soldiers[un]` (home city and
   recruits) and write it back under the new unit number.
5. **Not covered:** a captured roboport's robots in flight are flipped with the slices, their behaviour is not measured;
   trains of the old owner standing in a captured station keep their force (they are the old owner's rolling stock).
6. **Codex GUI protocol** for supply, capture, garrison and a troop train is integration's.
7. **City-states fall easily.** Units passing a city-state attack its centre (attack-move distraction) and capture it
   with 2-3 units once it is down (seed 404, before scout.lua ignored rts-neutral): its turret garrison (m2-world) is
   the only defence. Recorded for wave B.
8. **The M2 snapshot's own failures on 1v1 seeds 402-404** (rts-ai-1 without copper, Age II after 20:00) are the same
   without this package (section 7.3).
