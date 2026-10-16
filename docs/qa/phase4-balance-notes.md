# Phase 4 balance pass (wave B4): simulator and counter matrix

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Brief: run every counter from `balance.units[*].counters` as an open-field fight between equal-cost armies, in both
variants (Space Age and base-only).

- **Counters:** the counter must win with 40–70 % of its army left.
- **Mirrors:** a mirror must behave the same in both variants.
- **Defences:**
  - A gun turret holds against 3 walkers.
  - A laser turret holds against 6 drones.
  - 3 artillery kill a turret from outside its range.
- **Spacing:** 2 walkers spread 2.5 tiles apart do not block each other.

Earlier content: `docs/qa/phase4-content-notes.md`.

## Simulator

| File | Purpose |
|---|---|
| `tools/balance-sim/balancesim.lua` | The simulator module. It goes into a test copy only, as `scripts/balancesim.lua`. |
| `tools/balance-sim/run.sh <name> [sa\|base] [cap]` | Copies `mods/factorio-rts` to `build/<name>/` and appends `require("scripts.balancesim")` to the copy's `control.lua`. Runs headless until `[rts] bsim done`. |
| `tools/balance-sim/both.sh` | Runs `build/p4-balance` (Space Age) and `build/p4-balance-nosa` (base-only) in parallel and prints the summaries side by side. About 1–2 minutes for 8 reps. |
| `tools/balance-sim/diag-data-final-fixes.lua` | Used with `SIM_TRACE=1` only. Adds script triggers that count every unit's shots. |

Environment options:

- `SIM_ONLY=<Lua pattern>` runs only the matching scenarios, for example `SIM_ONLY=artillery`.
- `SIM_TRACE=1` logs every army scenario of round 1 every 0.5 s, with alive counts, health, shots and the closest distance.
- `SIM_FROM_HEAD="scripts/hud.lua"` takes files from git HEAD. It was needed while another agent's `hud.lua` did not load.

### How it works

- **Guard.** `on_init` sets `storage.debug.balancesim` and `storage.debug.autotest = false`, so no match starts and the simulator owns the game. `game.speed` is 8.
- **Arenas.** Every scenario has its own arena on a lab-tile surface, 320 tiles apart, and all arenas of a round run at once. There are 8 rounds (reps).
- **Equal-cost armies.**
  - Cost is iron-equivalent: iron and copper ×1, steel ×3, circuit ×4, explosives ×2.
  - The two sides' costs match within about 3 %, at a budget of about 360.
  - Final costs: walker 12, drone 6, raider 16, heavy 55, artillery 75.
- **Start.**
  - Both fronts start 30 tiles apart, in grid formations spaced like `orders.formation`: `max(2.5, collision width + 0.75)`.
  - Both sides get `orders.attack_move` (the player's order) towards the other side's front.
  - A cease-fire holds during the 1 s setup. Without it, units spawned in range shot first: artillery killed every heavy before the start.
- **Variation between reps.** The game is deterministic, so every rep places its units with ±0.4-tile jitter. Even reps swap the sides and the order the two attack-moves are issued in.
- **Metric for counters.** "Army left" is the winner's remaining health as a share of its starting health. Units never heal, so damage is a permanent loss. Every result line also logs the number of survivors.
  - A counter passes when it wins and keeps 40–70 %.
  - For a mirror, the metric is the winner's surviving unit count, and it passes when the fight ends before the 120 s timeout.
- **Building and spacing scenarios.**

| Scenario | Setup | Pass |
|---|---|---|
| Turret | 3 walkers attack-move onto an `rts-turret` with 20 magazines | The turret survives |
| Laser | 6 drones against a powered `rts-laser-turret` | The laser survives |
| Siege | 3 artillery attack-move onto a turret 45 tiles away | The turret dies and the artillery takes no damage (the closest distance is logged) |
| Spacing | 2 walkers 2.5 tiles apart use `orders.move` for 40 tiles | Both arrive within 10 s |

## Final matrix

8 reps per variant, on the working tree as of 2026-10-16 00:45. "Left" is the winner's average health left. "In band" counts reps the counter won with 40–70 % left. Times are in game seconds.

| Counter (a beats b) | Space Age: wins, left, in band, time | Base-only: wins, left, in band, time |
|---|---|---|
| walker > drone | 8/8, 50 %, 8/8, 15.3 s | 8/8, 61 %, 8/8, 14.4 s |
| walker > raider | 8/8, 52 %, 8/8, 11.6 s | 8/8, 50 %, 8/8, 11.1 s |
| heavy > walker | 8/8, 44 %, 6/8, 21.9 s | 8/8, 43 %, 6/8, 21.9 s |
| heavy > drone | 8/8, 49 %, 6/8, 11.9 s | 8/8, 52 %, 6/8, 10.6 s |
| drone > artillery | 7/8, 60 %, 3/8, 10.6 s | 7/8, 64 %, 4/8, 11.4 s |
| drone > raider | 8/8, 55 %, 8/8, 11.0 s | 8/8, 48 %, 6/8, 11.7 s |
| raider > artillery | 8/8, 58 %, 4/8, 6.6 s | 8/8, 59 %, 6/8, 5.8 s |
| artillery > heavy | 7/8, 34 %, 2/8, 10.9 s | 7/8, 45 %, 0/8, 8.8 s |

| Mirror | Space Age: wins A/B, winner keeps (units), time | Base-only |
|---|---|---|
| walker | 4/4, 35 %, 20.4 s | 3/5, 43 %, 18.3 s |
| drone | 3/5, 22 %, 18.1 s | 5/3, 22 %, 17.8 s |
| raider | 5/3, 19 %, 18.9 s | 7/1, 30 %, 19.4 s |
| heavy | 6/2, 48 %, 17.9 s | 3/5, 43 %, 19.0 s |
| artillery | 3/5, 50 %, 6.6 s | 5/3, 55 %, 9.7 s |

| Scenario | Space Age | Base-only |
|---|---|---|
| Turret vs 3 walkers | 8/8 held, turret keeps 52 % | 8/8 held, 51 % |
| Laser vs 6 drones | 8/8 held, laser keeps 53 % | 8/8 held, 58 % |
| 3 artillery vs turret | 8/8: turret dead in 10.3 s, closest artillery 33 tiles on average, no damage | 7/8: one rep took 2 % at 21 tiles |
| 2 walkers 2.5 tiles apart, 40-tile move | 8/8, both arrive in 5.5 s | 8/8, 4.5 s |

### Reading the matrix

- **Every listed counter wins in both variants**, at 7/8 or 8/8.
- **Averages.** Every counter's average health left is inside 40–70 % in both variants, except artillery > heavy. That one averages 34 % in Space Age and 45 % in base-only.
- **Counters inside the band in 6 or more of 8 reps:**
  - walker > drone
  - walker > raider
  - heavy > walker
  - heavy > drone
  - drone > raider
- **Counters involving artillery** are inside the band in fewer reps. The opening volley carries a lot of weight: it either lands on a clumped army or it does not. Individual reps range from about 10 % to 90 %. Earlier runs with the same numbers but different prototypes gave artillery > heavy averages of 51 % / 41 % and 62 % / 48 %. Run-to-run noise at 8 reps is about ±8 points.
- **Mirrors resolve alike in both variants**: walker about 19 s, drone 18 s, raider 19 s and heavy 18 s, with the winner keeping 20–50 %. The artillery mirror is short in both, 6–10 s, and is decided by the first volleys.
  - Before the pass, the heavy mirror took 10.7 s in Space Age against 30.8 s in base-only.
  - Before the pass, 1-v-1 Space Age walker duels barely hit at all.

## What was wrong, and the prototype fixes

These are in the order they were found. Each was confirmed with the simulator or a focused probe.

1. **Space Age strafers missed.** The vanilla strafer fires along its torso's facing (`use_shooter_direction`). Its projectile turns at 0.002 per tick and explodes in a 1-tile area wherever it collides, mostly beside the target or on a leg. A shot-counting probe showed 27 impacts but 10 hits on a target that never moved.
   - Fix: the walker and raider projectiles now fly straight at the target, home at 0.05, collide with nothing on the way (empty `hit_collision_mask`) and apply their damage to the target directly. Their starting speed is 1.
   - Result: 10–11 hits from 11 shots, like the base-only hitscan.
2. **The two variants were different units.**
   - **Attacks:** the Space Age heavy used the stomper's acid stream and stomp; the base-only heavy used hitscan.
   - **Strafing:** the base-only units had no strafe settings.
   - **Collision boxes** differed.
   - **Damage types** differed: explosion in Space Age, physical in base-only.

   Now `role()` in `prototypes/units.lua` gives each role one attack, damage type, strafe setting, collision box, armour and trigger mask in both variants. Only the graphics, the legs and the walker and raider projectile visuals differ.
3. **`distraction_cooldown`.** The stompers carry 300 ticks; the strafers and base-only mechs carry 30. With 300:
   - Stomper-based heavies first fired 3–5 s into a fight instead of 0.3–1 s.
   - Artillery fired one volley every 5 s, and had a single shell in the air while heavies walked up to it.

   All units now use 30. This alone made the Space Age heavy mirror match base-only: 15 s against 14.5 s.
4. **Spider legs pass their damage on to the torso, after the leg's own resistances.**
   - The pentapod legs carried the creature's resistances, so drone bites on a strafer leg did 7.2 instead of 10.
   - A base-only mech took one shell hit per leg in the splash.
   - Bonus damage (an area check around the bitten entity) never applied to bites on legs, so drones did not get their ×3 against raiders.

   Fix: legs now take the torso's armour and are immune to explosions, so an area attack counts once. Legs also carry the torso's target types.
5. **Stomps.** The stompers deal 43.75 impact (small) or 87.5 impact (medium) under their feet while attacking. Neither the heavy nor the artillery keeps the stomp. The heavy has an explicit splash in both variants instead.
6. **Long pentapod legs.** The medium strafer's and the stompers' legs plant 6–8 tiles from the torso, which gave drones far more to bite than the base-only mechs' 1–3 tiles. Space Age raiders lost to drones that base-only raiders beat. The heavy, raider and artillery now plant their feet at half the vanilla reach (`reach = 0.5`).
7. **Speeds now match in absolute terms.** The values below are tiles per second, measured over 1–5 s of a 120-tile move. The leg speeds are in `prototypes/units.lua`.

   | Unit | Space Age | Base-only |
   |---|---|---|
   | walker | 11.4 | 11.6 |
   | heavy | 6.3 | 6.0 |
   | raider | 15.2 | 16.2 |
   | artillery | 7.4 | 7.4 |
   | drone | 16.6 | 16.6 |
   | commander | 16.3 | 16.2 |
   | vanilla spidertron | 13.3 | 13.1 |

   The commander moves at ×1.22 of the spidertron.
8. **Gun turret range 21, up from vanilla 18.** Walkers (range 20) used to outrange it: 3 walkers killed a turret in every base-only rep.
9. **Artillery behaviour.**
   - **Creeping.** It crept into the range of the turret it was shelling. The causes were its orbit (strafe 32 ± 4), the slow shell (0.6), and a long `distraction_cooldown`. A "deploy" pause after each shot, `movement_slow_down_factor = 0`, did not help and was removed.
   - **Fix:** no strafing, a fast shell (starting speed 2), `lead_target_for_projectile_speed = 2`, range 44, and firing from 32–44 tiles (`min_attack_distance`, `balance.units["rts-artillery"].attack_from`).
   - **Splash.** A 4.5–5-tile splash made every artillery fight bimodal, because one volley either deleted a clump or missed. The splash is now 3.5 tiles. The armour bonus applies only within 2 tiles of the impact (`bonus_radius`).
10. **Bonus damage is a general mechanism.**
    - `balance.target_types` defines four types: `raid`, `armored`, `light` and `siege`.
    - Units carry types through `tags`. Attacks deal `bonus[type]` × damage through a nested `area` trigger with that mask; a `direct` trigger ignores the mask.
    - Who carries what:
      - Buildings and the hub and hauler are `raid`.
      - Heavies are `armored`.
      - Raiders are `light`.
      - Artillery is `siege`.

## Balance changes

All values live in `balance.lua`. The mk2 tiers are derived there: +40 % health, +25 % damage and splash, and 5 more steel.

| Unit | Before the pass | After |
|---|---|---|
| walker | 200 hp, 20 per 60 ticks, range 20, cost 12 | Unchanged. Damage type is physical in both variants. |
| heavy | 600 hp, Space Age acid stream ×2 plus stomp, base-only 60 per 90 ticks, range 10/12, no armour, ×0.75 speed | 800 hp; 50 explosion per 60 ticks plus 12 splash within 2.5 tiles; range 16; physical armour 60 %; ×0.55 speed; tag `armored`. Cost 55, unchanged. |
| drone | 60 hp, 10 physical per 30 ticks | 85 hp; 11 impact per 30 ticks, which ignores heavy armour; ×3 against `light`. Cost 6. |
| raider | 120 hp, 8 per 30 ticks, range 12, ×3 against raid targets, cost 47 (15 iron, 8 circuit) | 220 hp; 12 per 30 ticks; range 18; ×2.5 against `raid`; ×1.65 against `siege`; tag `light`. Cost 16 (8 iron, 2 circuit). |
| artillery | 250 hp, 100 per 240 ticks, splash 4, range 40, cost 90 (40 iron, 10 steel, 10 explosives) | 450 hp; 120 per 180 ticks; splash 3.5; ×9 against `armored` within 2 tiles; range 44, minimum range 8, firing distance 32–44; 25 % impact resistance against drone bites; tag `siege`. Cost 75 (40 iron, **5** steel, 10 explosives). |
| gun turret | range 18 | Range 21 |
| laser turret | 30 per 40 ticks | 50 per 40 ticks: 2 shots kill a drone. 800 kJ per shot, about 1.2 MW while firing. |
| wall | (content pass) no resistances, 500 hp | Unchanged |

`counters` in `balance.lua` lists the verified pairs:

- walker: drone, raider
- heavy: walker, drone
- drone: artillery, raider
- raider: artillery
- artillery: heavy

`strong` and `weak` keep the broader design roles from PHASE4, including buildings, haulers and turrets.

**Walker beats artillery is not a listed counter.** It is in PHASE4 ("walker weak vs artillery"), but it cannot hold in this test. From a 30-tile start, walkers reach range in about 1 s. A siege unit at equal cost then loses whatever its numbers are. The open-field test cannot show it; its place is positional play, which the siege scenario covers.

## Regression runs

All runs use fresh copies of the final tree.

| Run | Copy | Result |
|---|---|---|
| AI autotest: 1v1, normal, small | `build/p4-balance-ai` | `ai autotest summary 14/14 (all passed), result=both alive (time)`. 0 errors. |
| Legacy Phase 1/2 autotest, Space Age. `AUTOTEST_MATCH` set to legacy / waves in the copy. | `build/p4-balance-legacy` | `autotest summary 65/65 (all passed)`. 0 errors. |
| The same, base-only | `build/p4-balance-legacy-nosa` | `autotest summary 65/65 (all passed)`. 0 errors. |
| `--check-unused-prototype-data`, both variants | `build/p4-content`, `build/p4-content-nosa` | 0 warnings, 0 errors |
| `tools/headless-run.sh 60` with the real control script, both variants | `build/p4-content`, `build/p4-content-nosa` | 0 errors, 277 `[rts]` lines each |

## Gotchas

1. **A `direct` trigger ignores `trigger_target_mask`.** Bonus damage has to be an `area` nested in the hit.
2. **Spider legs pass their damage to the torso, after the leg's resistances.** They also get targeted by melee and hit by area attacks. Give them the torso's armour and target types, and make them ignore explosions (fix 4).
3. **`distraction_cooldown` controls how often a unit picks a target.** At 300 a ranged unit fires one burst per 5 s. That is easy to miss, because 1-v-1 duels look fine.
4. **Artillery choices.** `min_attack_distance` and `min_range` decide where artillery stands. Strafing artillery drifts.
5. **The game is deterministic.** Identical starting positions give identical fights, so reps need jitter.
6. **A static start in range of long-range units favours the first volley.** Use a cease-fire until the start.
7. **`LuaEntity.set_recipe` accepts disabled recipes.** This is from the content notes.
8. **Another agent's half-finished file can stop every copy from loading.** `run.sh` can take named files from HEAD: `SIM_FROM_HEAD`.

## Open items

- **artillery > heavy averages below the band in Space Age (34 %).** It still wins 7/8 in both variants. Opening-volley luck spreads its health left from about 10 % to 90 %. A larger budget, or a formation spread for heavies, would narrow it.
- **The artillery mirror ends in 6–10 s.** The first volleys decide it. It behaves the same in both variants, but it is not a long fight.
- **Some 8-rep mirror runs favoured one force** (sim-b won 7/8 in one run), but the next run did not. Sides and issue order alternate per rep, so this is noise or an engine update-order effect, not a placement bias.
- **Drones share one tint for both teams.** This is from the content notes.

## Economy pass (Wave C, 2026-10-16)

Brief from the lead: the AI's army at 8:00 on normal was small because plates go to labs, factories, hubs and science
first. Target: 12–16 units per side at 8:00 on normal, while the AI still builds a hub and researches 2 technologies by
6:00. Levers in order of preference: starting plates (symmetric), tier-1 research or basic kit cost about −25 %, lab
and hub cost slightly lower. Unit and kit costs stay as this pass tuned them.

### What changed

| Lever | Before | After | Where |
|---|---|---|---|
| Starting plates in the CC stockpiles (every side) | 200 iron, 100 copper | **400 iron, 150 copper** | `scripts/match.lua` `START_PLATES` |
| Tier-1 research (basic kits) | 20 / 15 / 10 | **15 / 11 / 8** (Attack I, Armor I, Unlock Raider 15; Mining I, Logistics I, Unlock Heavy, Hauler capacity I 11; Supply I 8) | `prototypes/research.lua` `TECHS` |
| Lab | 30 iron, 10 copper | **24 iron, 8 copper** | `prototypes/research.lua` |
| Hub | 40 iron, 10 copper | **32 iron, 10 copper** | `prototypes/logistics.lua` |

The hard AI's `stock_bonus` (+50 %) applies on top, so hard starts with 600 iron and 225 copper.

### How it was measured

- **Paired seeded samples.** `tools/autotest-batch.sh <tag> 4 1v1-normal-medium 1v2-normal-medium` with
  `KEEP_TREE=build/tree-<variant>`: 4 map seeds (`--map-gen-seed 1000 + r × 104729`) × 2 configurations = 8 AI-vs-AI
  runs per variant at game speed 4. The same rep uses the same seed in every variant, so each pair differs only by the
  balance numbers. Without `--map-gen-seed`, `--create` draws the seed from the clock, so runs started in the same
  second are identical (the first batch showed it: rep 1 and rep 2, launched together, gave the same numbers to the
  unit), and runs started later are unpaired.
- **Doctrines.** `rts-player` economic, `rts-ai-1` aggressive (autotest default); `rts-ai-2` in 1v2 draws its own.
- **Army** = military units alive at 8:00 (the minute report's unit mix: haulers and the Commander are not counted),
  averaged over the forces that still have a CC. **Kits** = unit kits the force's barracks made by 8:00 (production).
- Variants: c0 = the merged tree before the pass; c1 = 300/150 plates + the research, lab and hub cuts; c3 = 350/175;
  c4 = 400/150; c2 = 400/200. c1–c4 all carry the research, lab and hub cuts.

| Variant | Runs with a failed check | Aggressive: kits / army | Economic: kits / army | Techs by 6:00 (min) | Hub built (economic, mean) | Matches over by 8:00 |
|---|---|---|---|---|---|---|
| c0 (before) | 6 of 8 (9 checks) | 27.7 / 10.2 | 20.2 / 18.0 | aggressive 1.8 (1), economic 2.0 | 10/10, 272 s | 0 of 8 |
| c1 300/150 | 1 of 8 | 37.0 / 15.1 | 21.2 / 10.7 | 2.0 / 2.6 (2) | 10/10, 234 s | 0 of 8 |
| c3 350/175 | 1 of 8 | 39.7 / 14.4 | 25.9 / 10.0 | 2.0 / 3.0 (2) | 10/10, 209 s | 0 of 8 |
| **c4 400/150 (chosen)** | **0 of 8** | **44.1 / 15.2** | **33.5 / 17.8** | **2.0 / 3.0 (2)** | **8/8, 210 s** | 3 of 8 |
| c2 400/200 | 0 of 8 | 44.6 / 16.7 | 32.7 / 16.1 | 2.0 / 3.0 (2) | 7/7, 212 s | 3 of 8 |

Second technology (all forces): c0 at 319 s on average (296–366 s, so some forces missed 6:00); c4 at 243 s (221–291 s).

### Reading it

- **Iron is the binding plate.** c4 (400/150) and c2 (400/200) measure the same, so the extra copper buys nothing;
  150 copper stays.
- **The economic doctrine spends a first raise on tech and hubs.** At c1 and c3 its kits barely move (20 → 21 → 26)
  while its research and hub come earlier; its army at 8:00 even drops (fights with a stronger aggressive AI). Only at
  400 iron do both doctrines field 15–18 units at 8:00.
- **Faster decisive games.** With c4 the economic player beat the aggressive AI before 8:00 in 3 of 8 runs (1v1). In
  c0 the aggressive AI also lost its CC in 5 of 20 forces by 8:00, the match just went on longer. Doctrine matchups,
  not the start, decide these runs.
- **Alive armies are noisy.** One run's army at 8:00 depends on whether a fight just happened (the final 1v1 matrix
  run: economic 13, aggressive 0 while the player's army was in its base, with 55 kits made). Compare variants with kits and with
  averages over seeds, not with one run.

### After the pass (final tree, validation matrix at game speed 1, unseeded)

| Scenario | Kits made by 8:00 per side | Army at 8:00 per side | Technologies at 8:00 |
|---|---|---|---|
| 1v1 normal medium | player 28, AI 55 | 13, 0 (the player's army was in its base in minute 8; its 19 new units died defending) | 4, 3 |
| 1v2 normal medium | player 30, AI 1 36 (CC lost 6:12), AI 2 18 | 8, 0, 17 | 4, 2, 3 |
| 1v1 hard medium | 68, 135 | 28, 47 | 4, 3 |
| 1v1 easy medium | 18, 21 | 21, 11 | 1, 1 |

Easy keeps its single iron smelter (Phase 3 design) and does not research two technologies by 6:00; the autotest's
Phase 4 deadlines now scale with the difficulty's pace (`orders_data.TIME_SCALE`, easy ×1.5), so on easy they are "not
due" within 8 minutes (`scripts/ai/autotest.lua`).
