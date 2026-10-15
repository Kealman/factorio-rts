# Spike #3 results: `spider-unit` as the RTS unit class

Factorio 2.0.77 (mac-arm64), headless, 2026-10-15. Mod: `spikes/units/rts-spike-units_0.0.1/`.

**Verdict: `spider-unit` works as the primary controllable unit class.** All 48 small-test units obeyed scripted orders and fired completion events. They hold position with `stop` and fight across custom forces with ranged attacks and zero friendly fire. 400 walkers fighting kept the server at 60 UPS, with 1.2–4.2 ms/tick average cost. Space Age is optional: a base-only spider-unit built from spidertron graphics passed the same scenario.

## How to run

```sh
spikes/units/run-headless.sh 125                                   # Space Age enabled (spikes/units/mod-list.json)
spikes/units/run-headless.sh 125 '\[rts-units' build/units-nosa 34212   # no Space Age (mod copy + mod-list.json in build/)
```

`run-headless.sh` is `tools/headless-run.sh` plus an isolated write-data dir and UDP port (see gotcha 1). The scenario is a phase machine in `control.lua`, about 108 s of game time:

| Phase | Game time | What happens |
|---|---|---|
| setup | 0 s | Forces `rts-red`/`rts-blue`, 256×256 grass arena via `set_tiles`, entities cleared |
| orders | 2–22 s | 24 units per side spawn; `go_to_location` 30 tiles; on completion each unit gets one of 4 hold strategies |
| group | 22–32 s | Red group with `ai_controllable=false`, blue group with `true`. Stage 1 `go_to_location`; stage 2 `attack_area` on enemy walkers |
| combat | 32–75 s | `set_multi_command` test, then everyone attack-moves. Ends when a side is wiped or at 75 s |
| scale | +30 s | Small test removed; 200 `rts-walker` per side attack-move |
| idle | +20 s | Red survivors get `stop`, blue survivors get no new orders |

### Runs and logs

The logs are in `build/`, which is git-ignored, so the excerpts below are the record.

| Run | Code | Log |
|---|---|---|
| 1 | orders phase only, walker leg speed 2.5 | `build/units-server-run1-orders.log` |
| 2 | full; attack-move to enemy centroid | `build/units-server-run2-full.log` |
| 3 | full; nearest-enemy re-targeting, two groups | `build/units-server-run3-full.log` |
| 4 | **final code**, Space Age | `build/units-server-run4-full.log` |
| nosa | final code, Space Age / quality / elevated-rails disabled | `build/units-nosa-server.log` |
| bench | `--benchmark` of a fresh final-code save, per-tick timings | `build/units-benchmark.txt`, `build/units-nosa-benchmark.txt` |

## Prototypes built

| Name | Type | Source | HP | Attack | Notes |
|---|---|---|---|---|---|
| `rts-walker` | spider-unit | copy of `small-strafer-pentapod` (SA) / spidertron graphics (no SA) | 200 | SA: projectile `rts-walker-projectile`, explosion 20, range 20, cooldown 60. No SA: hitscan physical 20 | Own leg `rts-walker-leg`, `initial_movement_speed` 0.072 |
| `rts-walker-heavy` | spider-unit | copy of `small-stomper-pentapod` (SA) / spidertron graphics ×0.8 (no SA) | 600 | SA: acid stream range 10, `damage_modifier` 2, plus vanilla stomp (impact). No SA: hitscan explosion 60, range 12 | Own leg, speed 0.036 |
| `rts-swarm-red`, `rts-swarm-blue` | unit | copy of `small-biter` | 60 | vanilla melee | Hard-coded mask tint per team |
| `rts-swarm` | unit | copy of `small-biter` | 60 | vanilla melee | Mask layers use `apply_runtime_tint` (tint test) |

All copies set `vision_distance = 30` and `radar_range = 1`. AI settings are `destroy_when_commands_fail = false`, `allow_try_return_to_spawner = false`, `join_attacks = false` and `do_separation = true`. No autoplace or spawner references them, so they never spawn naturally. Map settings are changed at data stage and confirmed at runtime:

```
data: map-settings.max_failed_behavior_count: 3 -> 1000000
data: map-settings.enemy_expansion.enabled: true -> false
data: map-settings.enemy_evolution.enabled: true -> false
setup: tick=0 space-age=2.0.77 ... map_settings.max_failed_behavior_count=1000000 enemy_expansion=false enemy_evolution=false
```

---

## (a) Does a spider-unit work without a Space Age dependency? **Yes, with base graphics. Pentapod copies need Space Age.**

- The engine type does not need Space Age. Without it, `rts-walker` and `rts-walker-heavy` are built from base spidertron graphics: the torso comes from `spidertron_torso_graphics_set(scale)` and 8 legs from `make_spidertron_leg(...)`, both global helpers that base defines at data stage. The no-SA run passed every phase:
  ```
  data: space-age loaded: false
  data: rts-walker <- base spidertron graphics: hp=200 legs=8 scale=0.50 leg_scale=0.50 range=20
  setup: tick=0 space-age=nil quality=nil ...
  move summary walker   completed=20/20 results={success = 20} ... speed(tiles/s, 30 tiles / median)=9.00
  combat RESULT: winner=rts-red after 25.5s of full combat
  scale FINAL t=30.0s ... alive red=92 blue=0 ... wall-clock since last report: Duration: 2498.627500ms   (150 ticks)
  ```
- Pentapod copies cannot avoid Space Age. Their sprites live under `__space-age__/graphics/...`, and their leg prototypes, projectiles, streams and corpses are defined in Space Age's `enemies.lua`.
- The mod declares `"? space-age"` as an optional dependency and branches on `mods["space-age"]` in `prototypes/walkers.lua`.
- **Recommendation:** ship the base-graphics walker as the default and offer pentapod skins when Space Age is present. Do not call the base global helpers in the real mod, because they are not a stable API. Deep-copy from `data.raw["spider-vehicle"]["spidertron"].graphics_set` and `data.raw["spider-leg"]["spidertron-leg-N"]` instead.

## (b) Commandable orders and completion events: **work for both `spider-unit` and `unit`.**

- `entity.commandable` is non-nil for every spawned unit. `set_command{type=go_to_location, destination, distraction=none, radius=1.5}` succeeded for 48 of 48 units.
- `on_ai_command_completed.unit_number` equals `entity.unit_number` for units. For groups it equals `LuaCommandable.unique_id`.
  ```
  spawn detail red/walker: name=rts-walker type=spider-unit unit_number=1 valid=true force=rts-red commandable=true is_entity=true has_command=false health=200/200 color: ok=true value=nil ...
  move done: rts-blue swarm #171 result=success was_distracted=false ticks=155 dist_to_dest=1.78 -> hold=stop_renew
  move summary walker   completed=20/20 results={success = 20} distracted=0 ticks min/median/max=168/209/316 speed(tiles/s, 30 tiles / median)=8.61 max_dist_to_dest_at_completion=2.77
  move summary heavy    completed=6/6 results={success = 6} distracted=0 ticks min/median/max=205/314/486 speed(tiles/s, 30 tiles / median)=5.73 max_dist_to_dest_at_completion=3.40
  move summary swarm    completed=20/20 results={success = 20} distracted=0 ticks min/median/max=155/205/272 speed(tiles/s, 30 tiles / median)=8.78 max_dist_to_dest_at_completion=1.78
  ```
- Spider-units report completion short of the destination with `radius=1.5`, then coast on. Walkers complete up to 2.8 tiles short and heavies up to 3.4. After settling, walkers sit 0.7–0.8 tiles from the ordered point on average and heavies about 1.5. Biters complete within 1.8 tiles and stop dead.
- `stop{ticks_to_wait=300}` completes with `success` after exactly 301 ticks:
  ```
  hold: stop(ticks_to_wait=300) completed for walker #108 result=success after 301 ticks; renewed
  ```
- Speed is set by the leg prototype, not the unit, and the relation is non-linear. Run 1 used leg speed 0.150 and run 4 used 0.072.

  | Leg `initial_movement_speed` | Median speed |
  |---|---|
  | 0.150 | 10.3 tiles/s |
  | 0.072 | 8.6 tiles/s |
  | 0.036 (heavy) | 5.7 tiles/s |

## (c) How to keep idle units still: **`stop` works for both classes. `wander{radius=0}` works for `unit` only.**

Drift is measured from where each unit stood when its hold order was given. "Moved last 5 s" separates settling from wandering. These are run 4 numbers at t=20 s, 15+ s after the hold orders:

| Strategy | `unit` (swarm) | spider-unit (walker) | spider-unit (heavy) |
|---|---|---|---|
| no command | wanders (engine assigns `wander`): drift 8.8, moved 12.8 | wanders: drift 11.9, moved 19.3 | wanders: drift 10.7, moved 12.7 |
| `stop` (forever) | **0.00 / 0.00** | **settles ≤3.2 tiles, then moved 0.00** | **settles ≤2.0, then 0.00** |
| `stop{ticks_to_wait=300}` renewed on completion | 0.00 / 0.00 | settles ≤2.6, then 0.00 | n/a |
| `wander{radius=0}` | 0.00 / 0.00 | still wanders, moved 5.7 | still wanders, moved 2.9 |

```
hold t=20s walker/stop        n=6 drift_from_hold_point max=3.22 mean=2.41 over_2_tiles=5 | max_moved_last_5s=0.00 mean_dist_to_ordered_point=0.80 | commands={stop = 6} moving_states={adaptive = 6}
hold t=20s walker/wander0     n=4 drift_from_hold_point max=3.79 mean=2.84 over_2_tiles=4 | max_moved_last_5s=5.72 mean_dist_to_ordered_point=2.32 | commands={wander = 4}
hold t=20s walker/none        n=6 drift_from_hold_point max=11.89 mean=7.70 over_2_tiles=6 | max_moved_last_5s=19.33 ... commands={wander = 6}
hold t=20s swarm/stop         n=6 drift_from_hold_point max=0.00 mean=0.00 over_2_tiles=0 | max_moved_last_5s=0.00 ...
```

- The 2–3 tiles a spider-unit moves after `stop` is coasting toward the destination, not wandering. It brings the unit nearer the ordered point.
- With the default `distraction=by_enemy`, a stopped unit still fights back. In the idle phase the red survivors on `stop` beat the blue survivors that were still attack-moving into them:
  ```
  idle: red: 65 units given `stop`; blue: 61 units left without new orders (attack-move loop off)
  idle FINAL t=20.0s | red alive=11 in_group=0 groups_created=0 commands={stop = 11} | blue alive=4 ... commands={attack_area = 4}
  ```
- **Recommendation:** issue `stop` from `on_ai_command_completed` whenever a unit finishes an order. Never leave an RTS unit without a command. A compound command was not needed.

## (d) Unit groups and the `ai_controllable` requirement: **not required in 2.0.77.**

- The API doc says a force must be AI-controllable to create unit groups. That is not enforced for script-created groups. The `ai_controllable=false` group was created, gathered, moved, fired completion events and fought exactly like the `ai_controllable=true` group. This held in runs 3, 4, nosa and bench.
  ```
  group: create_unit_group for rts-red with ai_controllable=false -> ok=true unique_id=179 is_unit_group=true is_script_driven=true state=gathering
  group: create_unit_group for rts-blue with ai_controllable=true -> ok=true unique_id=180 is_unit_group=true is_script_driven=true state=gathering
  event: on_unit_group_finished_gathering group=#179 unit=- t=23.0s
  group: #179 (rts-red) t=23.0s state=moving members=5 ...
  group: on_ai_command_completed for group #179 (rts-red, ai_controllable at creation=false) stage=go_to result=success was_distracted=false at t=23.6s (1.6s after stage start) members=5
  group: on_ai_command_completed for group #180 (rts-blue, ai_controllable at creation=true) stage=go_to result=success was_distracted=false at t=23.6s (1.6s after stage start) members=5
  group: #179 (rts-red) t=30.0s state=attacking_distraction members=5 position=(-18.1,-30.5) moving_state=moving command=attack_area
  ```
- The lifecycle was identical in all three runs that checked it:
  - Gathering takes about 1 s, without calling `start_moving()`.
  - Members report command type `group`.
  - `attack_area` never completed while enemies remained; the group stays in `attacking_distraction`.
  - When every member dies, the group goes to `finished` and becomes invalid **without** an `on_ai_command_completed` event.
  - `group.destroy()` with an active command fires the event with `result=fail`.
  ```
  group: #179 (rts-red) t=51.0s state=finished members=0 position=(-11.9,-58.6) ...
  group: #179 (rts-red) became invalid at t=51.5s
  group: on_ai_command_completed for group #180 ... stage=attack_area result=fail ... members=-1     (destroyed by script)
  ```
- **Recommendation:** keep `ai_controllable=false` on every RTS force. Use script groups for formation moves if they help, and poll `group.valid` because death of the group raises no event.

## (e) Cross-force combat and ranged attacks: **work, zero friendly fire.**

- `set_friend(false)` with `set_cease_fire(false)` between the two custom forces gives `is_enemy=true`. Cease-fire with `enemy`, `player` and `neutral` in both directions kept nauvis biters out of the fight.
- The damage types seen match each attack:
  - Walker projectile: `explosion`.
  - Heavy acid stream: `acid`.
  - Heavy stomp: `impact`.
  - Biter melee: `physical`.
  - No-SA hitscan: `physical`.
- `friendly-fire hits=0` in every run.
  ```
  damage: first hit in phase group at t=31.6s: victim=rts-walker(rts-red) attacker_force=rts-blue cause=rts-walker source=rts-walker-projectile type=explosion original=20.0 final=20.0 final_health=180.0
  combat FINAL t=58s ... alive: red walker=0 heavy=0 swarm=0; blue walker=2 heavy=3 swarm=0 | hits=576 damage(attacker->victim): rts-blue->rts-red=4978 rts-red->rts-blue=4416 | damage types=acid,explosion,impact,physical | friendly-fire hits=0
  combat RESULT: winner=rts-blue after 26.0s of full combat (36.0s since the first group order)
  ```
- Fights resolved in 25–26 s in runs 3, 4 and nosa. In the bench seed the fight was still going at the 75 s timeout, with 2 red heavies against 1 dying blue walker.
- Run 2 stalled at 8 against 5 because attack-move targeted the enemy centroid, which lands in empty space once an army splits. Re-targeting the nearest enemy on completion fixed it. `LuaSurface.find_nearest_enemy{position, max_distance, force}` respects cease-fire, so it never returns nauvis biters.

## (f) UPS at 400 units: **60 UPS held, roughly 3× headroom.**

- On the server, every 300-tick report took 4998–5001 ms of wall-clock time, so the game never fell behind:
  ```
  scale: spawned 400 rts-walker (200 per side) at tick 3480 in Duration: 10.685708ms
  scale: attack_area issued to 400 units in Duration: 6.429250ms
  scale t=12.0s tick=4200 game_ticks_since_last=300 alive red=197 blue=199 hits=556 ... reissued=1899 has_command=396 moving=382 stuck=4 ... | wall-clock since last report: Duration: 4998.230542ms | mod event-handler time: Duration: 68.457497ms
  scale t=22.0s tick=4800 game_ticks_since_last=300 alive red=133 blue=118 hits=2788 ... | wall-clock since last report: Duration: 4999.615000ms | mod event-handler time: Duration: 28.327254ms
  ```
- Per-tick cost comes from `--benchmark` with `--benchmark-verbose all` on a fresh save, averaged per 300-tick window. Times are ms per tick; the budget at 60 UPS is 16.7 ms.

  | Window | avg | p99 | entityUpdate | pathFinder | particleUpdate |
  |---|---|---|---|---|---|
  | 48 units fighting | 0.39 | 0.62 | 0.05 | 0.01 | 0.17 |
  | 400 walkers, approach | 1.20 | 2.69 | 0.72 | 0.20 | 0.10 |
  | 400 walkers, peak fight (SA pentapods) | 4.20 | 5.19 | 0.64–0.98 | 0.10–0.17 | **2.8–3.3** |
  | 400 walkers, peak fight (no-SA spidertron graphics) | 1.20 | 3.43 | 0.70 | 0.29 | 0.03–0.28 |

- Simulating 400 spider-units with 5 legs each costs about 1 ms per tick. The rest of the SA peak is particles from the pentapod hit and death effects, inherited through `damaged_trigger_effect`, `dying_explosion` and leg dying effects.
- Script cost is small. The re-order loop reissued 5,500–5,800 orders in 30 s, because `attack_area` completes every ~2 s per unit in a melee. Handler time stayed at or below 0.23 ms per tick.
- **Recommendation:** replace the particle-heavy pentapod effects with light ones before scaling. Cache per-tick lookups in order loops.

## (g) `LuaSurface.set_multi_command`: **works without `ai_controllable`, but never selects spider-units.**

```
multi: set_multi_command(attack_area dest=(54.7,6.2) radius=20 unit_count=10) force=rts-red ai_controllable=false -> ok=true returned=8; units whose command/group changed: {["swarm/none:wander->attack_area"] = 3, ["swarm/stop_renew:wander->attack_area"] = 2, ["swarm/wander0:wander->attack_area"] = 2, ["swarm_rt/none:wander->attack_area"] = 1}
multi: set_multi_command(... ) force=rts-blue ai_controllable=true -> ok=true returned=8; (identical selection)
```

- It returned 8, not 10, in all four runs of this test (runs 3, 4, nosa, bench). It picked only `unit`-type entities whose current command was `wander`.
- It skipped idle `wander` spider-units, and it skipped units holding `stop`.
- It gave individual commands. It created no group and set no `parent_group`.
- Results with `ai_controllable` true and false were identical.
- **Recommendation:** do not use it for spider-unit armies. Command units individually or through script groups.

## (h) Force tint: field names and status. **Field confirmed to be read. Colour not visually confirmed.**

- The only runtime tint field in `prototype-api.json` is `SpriteParameters.apply_runtime_tint`. It is also on `AnimationPrototype` and `SpritePrototype`, which is irrelevant here. No `use_forces_color` or similar field exists.
- Changelog line 378 (2.0.63) says spider-unit layers with `apply_runtime_tint` use the force color.
- What was set:
  - **Spider-units:** `apply_runtime_tint = true` on every layer whose file name contains `mask`, with `tint` and `tint_as_overlay` removed. This covers the strafer (1 torso and 3 leg layers) and the stomper (1 torso and 6 leg layers). Torso layers are in `graphics_set` (`SpiderTorsoGraphicsSet`); leg layers are in `SpiderLegPrototype.graphics_set`. The base spidertron torso and legs already use `apply_runtime_tint` on their mask and joint layers.
  - **Force color:** `LuaForce.custom_color` is writable, and `force.color` reads it back:
    ```
    forces: rts-red index=4 color={a = 1, b = 0.1..., g = 0.1..., r = 1} custom_color={...}
    ```
  - **Units:** `apply_runtime_tint` is also read on biter `run_animation` and attack animation layers. Which color a `unit` gets at runtime is unknown. Per-team prototypes with hard-coded `tint` (`rts-swarm-red` and `rts-swarm-blue`) load and fight normally, so that pattern is safe.
- What was verified headless:
  - All prototypes load.
  - `--check-unused-prototype-data` reports no unused value for any of our prototypes, in both the SA and no-SA builds. The checker works: a planted field produced `Warning PrototypeLoader.cpp:199: Value ROOT.spider-unit.rts-walker.rts_bogus_field was not used.`, so `apply_runtime_tint` on these layers really is read.
  - `LuaEntity.color` returns `nil` without raising, for both `unit` and `spider-unit`.
- **Not verified:** the actual on-screen colour. `game.take_screenshot` does nothing headless, so this needs a GUI check. The question is whether the force colour replaces or multiplies the pentapod mask look, and whether `tint_as_overlay` should be kept.

## (i) Gotchas

1. **Concurrent headless runs collide on the write-data lock.** `tools/headless-run.sh` failed with `Couldn't acquire exclusive lock` while another spike's server ran. `spikes/units/run-headless.sh` passes `--config <build/...-write/config/config.ini>` with its own `write-data` and `--port`. Consider adding this to the shared tool.
2. **The headless server saves on SIGTERM** into the save it was started from, so `build/<id>-headless.zip` holds the end state. A `--benchmark` of that file measures an empty, finished game; create a fresh save with `--create` first.
3. **`on_init` runs in the `--create` process**, so its log lines land in `build/<id>-create.log`. `on_nth_tick(30)` first fires at tick 0 of the server run, which is where the scenario does its setup.
4. **Pentapod copies inherit enemy behaviour** that must be overridden:
   - `ai_settings` from gleba: `destroy_when_commands_fail=true` and `allow_try_return_to_spawner=true`.
   - `dying_trigger_effect` that spawns wrigglers or stomper shells.
   - Projectiles that spawn wrigglers and apply a slowdown sticker.
   - `absorptions_to_join_attack = {spores=...}` and `healing_per_tick`.
5. **`spider-unit` has no `movement_speed`.** Speed lives in the `spider-leg` prototype (`initial_movement_speed`, `movement_acceleration`) and leg geometry, and is non-linear. Each unit type needs its own leg prototype and a calibration pass.
6. **Engine-made unit groups appear for non-AI forces.** In runs 2 and 3, a group with `is_script_driven=false` was created for `rts-red` or `rts-blue` near the end of the 400-unit fight, with `ai_controllable=false`. It pulled in a unit and later completed its own command:
   ```
   event: on_unit_group_created phase=scale t=86.0s group=#2607 force=rts-red is_script_driven=false members=0 position=(26.0,20.6)
   scale FINAL ... in_group=1 groups_created=1
   event: on_ai_command_completed for unknown unit_number=2607 result=success phase=done
   ```
   It did not reproduce in run 4, the bench run, or the nosa run, and the trigger is unknown. Untested mitigation: in `on_unit_group_created`, destroy any non-script group of an RTS force and re-issue the members' orders.
7. **Attack-move needs re-targeting.** `attack_area` completes very often in a melee, with `success` and `was_distracted=true`. Toward a fixed point it stalls once armies split; re-target the nearest enemy on completion.
8. **`LuaCommandable.state` and `members` work for groups only.** On a group, the event field `unit_number` carries `unique_id`.
9. **Arena setup is a one-tick hitch.** Generating chunks and setting 65k tiles took 60–220 ms on the server, depending on how much had to be cleared, and 191 ms in the benchmark. That is fine at match start but must not happen mid-game.
10. **`LuaProfiler` semantics.** `reset()` resets and restarts; `restart()` resumes without resetting. A profiler can only be printed through a LocalisedString in `log`, and it cannot be stored in `storage`.
11. **`find_non_colliding_position` was not needed** for a 4-tile spawn grid. Creating 400 spider-units at exact positions took 8–11 ms.

## Recommendations for the real mod

- Make `spider-unit` the line-unit class. Default to the base spidertron-graphics variant and add pentapod skins when Space Age is present, with the overrides from gotcha 4 and lighter hit and death effects.
- Command each unit through its own `commandable`:
  - **Move:** `go_to_location`, with `distraction=none` for a pure move.
  - **Attack-move:** `attack_area` that re-targets the nearest enemy on completion.
  - **Hold or idle:** `stop`. Re-issue `stop` after every completed order so units never wander and are less likely to be drafted into engine groups.
- Keep `ai_controllable=false` on all RTS forces. Script groups work without it. `set_multi_command` is useless for spider-units.
- Set `max_failed_behavior_count` at data stage, which also covers new maps, and keep AI `destroy_when_commands_fail=false`.
- Budget for 400 units: about 1–2 ms per tick with light effects. Watch `particleUpdate` first, then `entityUpdate`.
- Open items for later spikes:
  - Visual check of the force tint in the GUI.
  - Hold-fire semantics, `stop` with `distraction=none` versus `by_enemy` for "hold position".
  - Pathing around player buildings.
  - The trigger for engine-made groups.
