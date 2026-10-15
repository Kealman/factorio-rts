# Spikes #4 and #5: barracks pattern and AI base (Factorio 2.0.77, headless)

Date: 2026-10-15. Mod: `spikes/economy/rts-spike-economy_0.0.1/`. Run:

```sh
tools/headless-run.sh 130 '\[rts-eco' spikes/economy
```

Full logs: `build/economy-server.log` and `build/economy-run-output.txt`.
Two configurations were run, and every logged number matched across them:

- **Space Age, quality and elevated-rails enabled.** This is what Factorio writes into an absent `mod-list.json`.
- **Base only.** This run used `build/economy-baseonly/` with an explicit `mod-list.json`.

No errors appeared in either run. The scripts ran with no players at all and `auto_pause=false`.

None of the logs contain the write-dir lock error (`Couldn't acquire exclusive lock`).
The final run used the updated runner with an isolated write dir under `build/runs/economy/` and reproduced every number below.

## Verdicts

| Spike | Verdict |
|---|---|
| #4 Barracks pattern | **Works and is reliable.** 20/20 kits became 20 units on both barracks variants. No missed or duplicated spawn. Polling is cheap, and predictive scheduling brings latency to 0 ticks. |
| #5 AI base for a force with no players | **Works.** `build_blueprint{force=...}` needs no player and no charting, ghosts never expire, script `revive` works, and production runs: 34 plates/min, matching theory. |
| Bonus: `clone_area` | **Works**, including `destination_force`. It is an exact state copy that includes inventories, fuel, resources and ghosts. It suits instant match-start bases, not visible construction. |

## Spike #4: barracks (assembler output becomes a unit)

Setup:

- `rts-barracks` is a copy of `assembling-machine-1` with category `rts-barracks`, `crafting_speed = 1`, and `energy_source = {type = "void"}` for the spike.
  **The real mod will use an electric energy source**, so low power will slow crafting.
- Recipe `rts-marine-kit` costs 2 iron + 1 copper and takes 3 s, which is 180 ticks.
- Each barracks got 40 iron + 20 copper, enough for 20 kits.
- `small-biter` in force `rts-ai` stands in for the unit.

Two variants ran side by side:

1. **10-tick poll**: `on_nth_tick(10)` reads `get_output_inventory().get_item_count(kit)`, removes the kits and spawns at the rally point.
2. **Predicted tick**: one check at the tick predicted by `(1 - crafting_progress) * recipe.energy / crafting_speed * 60`, then a re-prediction after each check.
   While idle (`is_crafting() == false`), it re-checks every 60 ticks.

A per-tick observer of `products_finished` recorded the exact completion tick for the latency measurement only.

```
[rts-eco] pred-barracks: spawn #1 tick=211 ... finished_tick=211 latency=0 crafting_progress=0.006 products_finished=1 checks_so_far=3
[rts-eco] barracks: spawn #1 tick=220 ... finished_tick=211 latency=9 crafting_progress=0.056 products_finished=1 checks_so_far=20
...
[rts-eco] SUMMARY #4 barracks (10-tick poll): spawned=20 products_finished=20 checks=687 ... latency min=9 max=9 avg=9.00 ticks;
          predicted-vs-observed completion deltas: 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
[rts-eco] SUMMARY #4 pred-barracks (predicted tick): spawned=20 products_finished=20 checks=76 ... latency min=0 max=0 avg=0.00 ticks
[rts-eco] bench: variant A average per poll: Duration: 0.536911ms   (90 barracks)
[rts-eco] bench: variant B average per poll: Duration: 0.517062ms   (90 barracks)
```

### Measured numbers

| Metric | 10-tick poll | Predicted tick |
|---|---|---|
| Spawn latency after craft completion | 9 ticks every time, see note 1 | 0 ticks (20/20) |
| Checks while producing (20 kits) | 362, about 18 per unit | 22, about 1.1 per unit |
| Checks over the whole 115 s run, including idle | 687 | 76 |
| Entities touched per check | 1 barracks: 1 inventory read, plus 1 remove and 1 `create_entity` per spawned unit | same |
| Prediction accuracy | n/a | exact for 19/20 crafts; the first was 1 tick late because the machine starts one tick after creation |

Note 1: the 180-tick craft is a multiple of the 10-tick poll period, so the phase locked at the worst case. In general, latency with an N-tick poll is uniform over 0..N-1.

Per-poll cost was measured with `helpers.create_profiler` over 90 extra barracks, 30 polls per variant, across 4 runs:

- **Variant A** reads the output inventory every time: 0.507–0.537 ms per poll of 90, about **5.8 µs per barracks per poll**.
- **Variant B** first compares `products_finished` and opens the inventory only on change: 0.452–0.517 ms, about **5.4 µs per barracks**.
  The saving is within noise. The cost is the Lua-to-engine call itself, not inventory access.
- With 100 barracks polled every 10 ticks, the average is about 0.06 ms per tick, 0.35% of the 16.7 ms tick budget.

### Is there an event for "assembler finished a craft"?

No. `runtime-api.json` events that match "craft" are `on_player_crafted_item`, `on_pre_player_crafted_item` and `on_player_cancelled_crafting`, and all are player-only.
There is no crafting-machine completion event. The available mechanisms are:

- **Polling.** Reliable and cheap, as measured above.
- **Predictive scheduling.** Exact in this spike. It is self-correcting when power drops: the item appears later than predicted, the check finds nothing and re-predicts.
  It can be late only if speed increases mid-craft (beacons or modules added), so keep a slow fallback sweep.
- **Item spoilage with `spoil_to_trigger_result`.** This would fire `on_script_trigger_effect`, but `spoiling_required` "requires ownership of the Space Age expansion" according to `auxiliary/mod-structure.html`. It was not pursued, because the mod treats Space Age as optional.

### Other observations

- `find_non_colliding_position("small-biter", rally, 10, 0.5)` returned the rally point itself every time, because earlier units had wandered off: 1–4 units stayed within 3 tiles.
  Burst spawns (several items in one poll) were not exercised. A spread or formation offset may be needed.
- `defines.inventory.assembling_machine_input == defines.inventory.crafter_input == 2`. They are aliases in 2.0.
- 40 units of force `rts-ai` existed at the end, and the force had no players.

## Spike #5: AI base from a blueprint string, force with no players

Steps:

1. **Template.** At (-40,-40) I created ore and 22 entities with `create_entity` for force `rts-ai`:
   - lane 1: burner drill, stone furnace, burner inserter onto a belt
   - lane 2: electric drill, stone furnace, burner inserter onto the same belt
   - 9 belts, then an electric inserter into a wooden chest
   - power: 2 solar panels, an accumulator and 2 medium poles; `always_day` is set
2. **Blueprint without a player.** I used `game.create_inventory(1)`, `inv[1].set_stack("blueprint")`, `create_blueprint{surface, force, area}` and `export_stack()`, then destroyed the originals.
3. **Calibration.** I imported the string and built it on a scratch surface `rts-templates`, fully covered with ore, at P0=(0,0). This records each ghost's offset; see the gotchas below for why.
4. **Real build.** I placed ore under the predicted drill positions at P=(40,40), then called `build_blueprint{surface, force="rts-ai", position=P, build_mode=normal, raise_built=true}`.
5. **Revive.** Every 30 ticks, up to 3 ghosts are revived with `ghost.revive{raise_revive=true}`. The `script_raised_revive` handler inserts 10 coal into every entity with a burner.
   One accumulator ghost was deliberately left unrevived as an expiry control.
6. **Production report** every 600 ticks: chest, belts, furnaces, entity status and `force.get_item_production_statistics(surface)`.

```
[rts-eco] template: set_stack=true create_blueprint mapped 22 entities, get_blueprint_entities=22, export_stack length=573 prefix="0eNqdld2OgyAQhd+"
[rts-eco] template: string = version char "0" + base64(zlib(JSON)); JSON length=2085, ... entities=22, first stored entity transport-belt pos=(-34.50,-40.50)
[rts-eco] calibrate: scratch surface rts-templates, built 22 ghosts at P0=(0,0) (normal mode, ore everywhere), drills=2; template burner-mining-drill at (-39.00,-40.00) -> rel (1.00,-5.00)
[rts-eco] build: force rts-ai players=0 chunk (1,1) charted=false visible=false
[rts-eco] build: attempt 1 (no ore, build_mode=normal, no player) -> 20 ghosts [accumulator=1 burner-inserter=2 inserter=1 medium-electric-pole=2 solar-panel=2 stone-furnace=2 transport-belt=9 wooden-chest=1]
[rts-eco] build: placed 29 ore tiles under predicted drill positions
[rts-eco] build: attempt 2 (ore placed, build_mode=normal, no player) -> 22 ghosts [... burner-mining-drill=1 electric-mining-drill=1 ...]; script_raised_built events=22
[rts-eco] build: calibrated positions matched 22/22 ghosts (translation P + rel holds for integer P)
[rts-eco] build: ghost[1] transport-belt at (45.50,34.50) type=entity-ghost force=rts-ai time_to_live read ok=false value=Entity is not combat-robot, highlight-box, smoke, or sticker..
[rts-eco] build: force.create_ghost_on_entity_death=false (2.0 replaced ghost_time_to_live with this bool)
[rts-eco] revive: tick=90 rt=90 burner-mining-drill at (41.00,35.00) -> entity=245 collided=0 proxy=false
[rts-eco] revive: done at tick=300, revived=21 failed=0, took 210 ticks from first revive; revive events=21
[rts-eco] revive: poles wire-connected after revive=true, network ids 3/3
[rts-eco] base: first iron plate produced by rts-ai at rt=540 (450 ticks after first revive, 240 ticks after last revive)
[rts-eco] base rt=1800: chest_plates=10 belt_items=2 force_produced plate=13 ore=19 | ... electric-mining-drill{working} ... inserter{working}
[rts-eco] base rt=5400: chest_plates=44 belt_items=1 force_produced plate=47 ore=64 | ...
[rts-eco] SUMMARY #5: ghosts=22 revived=21 failed=0 control ghost (accumulator) still valid at rt=6900: true
[rts-eco] SUMMARY #5: iron plates produced by rts-ai between rt=1800 and rt=5400: 34 (34.0 plates/min), chest +34
```

### Measured numbers

| Metric | Value |
|---|---|
| Blueprint string for 22 entities | 573 chars; the decoded JSON is 2085 chars |
| Ghosts from `build_blueprint` | 22/22 with ore pre-placed; 20/22 without ore, because the drills were skipped |
| Revive pacing | 3 per 30 ticks gives 21 entities in 210 ticks, with 0 failures and 21 `script_raised_revive` events |
| Time to first plate | 450 ticks after the first revive, 240 after the last |
| Plates smelted, steady state | **34.0 plates/min** between rt=1800 and 5400. Theory is 33.75: lane 1 is drill-bound at 15/min, lane 2 is furnace-bound at 18.75/min, and its furnace ore buffer kept growing to 21. |
| Ghost lifetime | The control ghost was still valid about 6800 ticks after placement. There is no ghost TTL in 2.0. |

### Questions from the brief

- **Does production run for a force with no players?** Yes. Drills, furnaces, inserters, belts and the solar/electric network all reported `working`.
  `get_item_production_statistics` counted the force's output, and `ai_controllable=false` changed nothing.
- **Does `build_blueprint` require a player?** No. `by_player` was omitted, and `raise_built=true` still fired `script_raised_built` once per ghost.
- **Does the force need to have charted the area?** No. The target chunk was uncharted and not visible, and ghosts were placed anyway with `skip_fog_of_war` at its default.
- **Does it need research?** No. Ghosts and script revive worked for solar panels, an accumulator and medium poles while `rts-ai` had researched nothing.
  Script `revive` also consumes no items. The real mod must debit items itself if AI construction should cost resources.
- **Do ghosts expire?** No. Reading `time_to_live` on a ghost raises `Entity is not combat-robot, highlight-box, smoke, or sticker`.
  The 2.0 changelog says `LuaForce::ghost_time_to_live` became the boolean `create_ghost_on_entity_death`. Ghosts from `build_blueprint` stayed valid for the whole run.
- **Quirks of a player-less force:** none found.
  - Fuel is not part of blueprints; I inserted it in the revive handler.
  - Drills need real ore underneath. That is a blueprint rule, not a force rule.

### Obstruction matrix

I placed one obstacle where the first stone furnace goes, on a separate site, and ran each mode with ore present. "Revive" means `revive{}` on the furnace ghost.

| Obstacle | `normal` | `forced` | `superforced` |
|---|---|---|---|
| `tree-01` (neutral) | 0 ghosts, all-or-nothing | 22 ghosts; tree marked for deconstruction by `rts-ai`; **revive returns nil until the tree is removed**, then succeeds | same as forced |
| `wooden-chest` (neutral force) | 0 ghosts | 21 ghosts; furnace skipped; chest not marked | 21 ghosts; furnace skipped; chest not marked |
| `wooden-chest` (own force `rts-ai`) | 0 ghosts | 21 ghosts; furnace skipped | 22 ghosts; chest marked for deconstruction; revive blocked until it is removed, then succeeds |

## Bonus: `clone_area` as a templating mechanism

At rt=4800 I cloned the running base's area, 15×17 tiles, to x−80 with `destination_force="rts-ai-2"`, `clone_entities=true`, `clone_tiles=true` and `clear_destination_entities=true`:

```
[rts-eco] clone: ... before: src(rts-ai)=22 src(resources)=29 dst(rts-ai-2)=0 dst(all)=0
[rts-eco] clone: clone_area took Duration: 7.634916ms
[rts-eco] clone: after: src(rts-ai)=22 dst(rts-ai-2)=22 dst(resources)=29 dst(ghosts)=1 on_entity_cloned events=51 area_cloned=1
[rts-eco] clone: cloned state preserved: coal in burners=41 chest plates=39 pole network ids=4/4
[rts-eco] clone rt=7200: chest_plates=61 ... force_produced plate=23 ore=30 | ... all working
```

- The clone copies everything: resources (29), ghosts (the unrevived accumulator), inventories (39 plates, 41 coal), wires, and machine progress.
- It runs as a deterministic replica. The clone's chest matched the original tick for tick: 44, 50, 55, 61.
- `rts-ai-2` produced 23 plates in 2400 ticks, about 34.5/min.
- Cost was 6.6–7.6 ms for 51 entities in one call, over three runs: fine at match start, too heavy for routine per-tick use.

## API gotchas: names and behaviour that differed from expectations

1. **`build_blueprint` has no `force_build`.** The parameter is `build_mode = defines.build_mode.normal | forced | superforced`.
   The other parameters are `surface`, `force`, `position`, `direction?`, `skip_fog_of_war?`, `by_player?` and `raise_built?`. It returns an array of ghosts.
2. **`normal` mode is all-or-nothing only for collisions.** A mining drill with no ore under it is skipped silently, and the rest is built (20/22). This happens in every mode.
   Always compare the returned ghost count with the template's entity count.
3. **Blueprint coordinates are not normalised.** After `create_blueprint`, `get_blueprint_entities()` and the exported JSON hold world positions; the first belt sat at (-34.5,-40.5).
   `build_blueprint` centres the entity bounding box on `position` with grid snapping, so ghost positions are not simply P plus the template offset.
   The transform is a pure translation for integer P: offsets calibrated at (0,0) matched 22/22 ghosts at (40,40).
4. **Ghost TTL.** `LuaEntity.time_to_live` errors on ghosts, and `LuaForce.ghost_time_to_live` no longer exists in 2.0.
5. **`revive` returns three values:** collided items, entity and proxy. A Lua `x and f() or y` expression truncates them to one, which is a bug I hit.
6. **`find_non_colliding_position(name, center, radius, precision, force_to_tile_center?)` is positional,** not a table.
   The same goes for `request_to_generate_chunks(position, radius)` and `game.create_inventory(size, gui_title?)`.
7. **Inserter `direction` is the side it picks from.** An inserter with `direction=west` picks from the west and drops to the east.
   The template code derives the direction from `pickup_position` instead of assuming it.
8. **In 2.0, `create_entity` auto-connects medium poles,** and the wires survive the blueprint string and revive (both poles shared network id 3).
   The 2.0 wire API is `get_wire_connector(defines.wire_connector_id.pole_copper, or_create)` with `connect_to(...)`.
9. **Profiler and decoder live on `helpers`:** `helpers.create_profiler(stopped?)` and `helpers.decode_string`, not `game.*`.
   A `LuaProfiler` can be embedded in a `log{...}` localised string. It cannot live in `storage`, so keep it in a file-level local.
10. **`import_stack` works on an empty script-inventory slot** and returns 0. `set_stack("blueprint")` also works with a plain name.
11. **`on_init` runs during `--create`,** so its `log()` lines land in `build/<mods-dir>-create.log`, not the server log.
    The spike therefore schedules everything from the first server tick (`storage.t0`).
12. **The headless runner enables Space Age by default** when `mod-list.json` is absent. Base-only needs an explicit `mod-list.json`.
13. **No crafting-machine completion event exists.** Spoil triggers need the Space Age-gated `spoiling_required` flag.

## Recommendations for the real mod

**Barracks:**

- Use predictive scheduling: a tick-bucketed schedule keyed by predicted completion. On each check, drain the output, spawn, and re-predict from `crafting_progress`.
- Add a slow fallback sweep, every 120–300 ticks spread round-robin, to catch speed changes from beacons, modules or power.
- Plain 10-tick round-robin polling is an acceptable simpler start at about 6 µs per barracks per poll. Spread the barracks across ticks instead of polling all on one tick.
- Keep rally points and a spawn spread or formation offset per barracks, and test burst spawns.

**AI base templates:** use blueprint strings plus a calibrated layout. Ship templates as strings in Lua data; one 22-entity base takes 573 chars. At load or on init:

1. Import each template once on a hidden scratch surface fully covered with ore. Build it at (0,0) and record `{name, rel_pos, dir, is_drill, drill_radius}`. Optionally store that table next to the string.
2. Choose sites with this table: check that ore lies under every drill footprint, and run `can_place_entity` if needed.
3. Build with `normal` mode as an atomic placement test, then assert `#ghosts == #template`. If it fails, destroy the ghosts and choose another site.
   On natural terrain, use `forced` instead, and have the AI script remove the nature entities it marked for deconstruction before reviving.
4. Revive progressively, paced by the AI's stock (debit items per revive) for visible construction. Do fuel and initial inventory in `script_raised_revive`.
   Ghosts persist indefinitely, so the AI can lay out a whole build-order step at once.
5. Script revive skips research and items. Fairness, meaning tech gating and costs, must be enforced by the build-order DSL.

**`clone_area` versus blueprint strings:** blueprint strings for anything an AI builds during a match, because construction stays visible, paced and costed.
`clone_area` only for identical instant setups such as match-start command centres for every force. Clone from a hidden template surface with `destination_surface`, and keep that template free of ore and inventories, since everything is copied.
Cloning onto the real map without the template's resources needs `clone_entities` with a filtered list; that was not tested.

**Power:** the barracks will be electric. The base above ran on solar with `always_day=true`, which is not realistic at night. Phase 2 should test barracks under low power with steam.

## Files

- `rts-spike-economy_0.0.1/info.json`: factorio_version 2.0, dependencies `base >= 2.0`, `? space-age`.
- `rts-spike-economy_0.0.1/data.lua`: recipe category, `rts-marine-kit` item and recipe, `rts-barracks` entity, item and recipe.
- `rts-spike-economy_0.0.1/control.lua`: the timeline, both barracks variants, the benchmark, template and blueprint, calibration, the obstruction matrix, revive, reports and clone.
- `mod-list.json`: written by Factorio on the first run, with Space Age enabled.
