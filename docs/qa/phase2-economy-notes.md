# Phase 2 control-stage economy: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE2.md`. Prototypes: `docs/qa/phase2-prototypes-notes.md`. Barracks and base patterns: spike decisions 7–8 in
`docs/research/spikes.md`. Event bus, storage and claim rules: `docs/qa/phase1-skeleton-notes.md`.

## Files

| File | Status | What it does |
|---|---|---|
| `scripts/buildings.lua` | new | Building registry, CC composite placement, CC death cleanup, rally points |
| `scripts/production.lua` | new | Network pull for barracks and factories, kits to units, factory hand-off, turret feeding, counters |
| `scripts/economy.lua` | new | Cached per-force resource, robot and power summary, resource pool helpers |
| `scripts/basetemplate.lua` | new | Starter base template as data, built once on a scratch surface, copied with `clone_area` |
| `scripts/match.lua` | changed | Phase 2 start: bases, ore, 6 walkers per side, wave target, building-aware win/lose |
| `scripts/debug.lua` | changed | Four new commands, the economy autotest, Phase 1 checks adapted to 6-unit armies |
| `control.lua` | changed | Requires buildings, production, economy and basetemplate after units and before match |

`scripts/units.lua` is unchanged. No prototype, HUD, selection, orders, camera or cursor file was touched.

## What the match start looks like

| Side | CC centre | Base | Army |
|---|---|---|---|
| `rts-player` | (-60, 0) | CC composite only, starting stock in its 4 stockpiles | 6 walkers at (-46, 0), 2 columns × 3 rows, 3.5 tiles apart |
| `rts-enemy` | (60, 0) | Full starter template, mirrored, barracks on `rts-walker-kit` | 6 walkers at (46, 0), mirrored |

- **Ore per side.** Each patch is placed relative to the CC, towards the arena centre, with 1500 ore per tile. Every patch is a rounded blob.

  | Resource | Size | Centre (player side) | Tiles |
  |---|---|---|---|
  | iron-ore | 12×12 | (-43, 10) | 124 |
  | copper-ore | 8×8 | (-43, -10) | 52 |
  | stone | 6×6 | (-32, 16) | 32 |
  | coal | 6×6 | (-24, 16) | 32 |

  The iron and copper centres are 16 tiles from the nearest CC stockpile (relative (3.5, ±1.5)). They moved in from
  about 26 tiles on 2026-10-15, so the first extractor-to-stockpile loop fits the starting belts. They sit off the x
  axis, so the starting army, 14 tiles straight ahead of the CC, does not stand on them.

  The enemy side mirrors these in x. The data is `match.ORE_PATCHES` and `match.ORE_AMOUNT`.
- **Starting stock** is the PHASE2 table, extended by lead decisions on 2026-10-15. One factory was added, because
  without it the player can never make more buildings. Two stockpiles and more belts, inserters and poles were added,
  so the first extractor → belt → smelter → inserter → stockpile loop can be closed from the stock. The stock is now:

  | Item | Count |
  |---|---|
  | iron-plate | 200 |
  | copper-plate | 100 |
  | rts-extractor | 2 |
  | rts-smelter | 2 |
  | rts-barracks | 1 |
  | rts-factory | 1 |
  | rts-stockpile | 2 |
  | transport-belt | 60 |
  | fast-inserter | 16 |
  | medium-electric-pole | 16 |

  The data is `match.STARTING_STOCK`.
- **Stockpile recipe.** `rts-stockpile` now has a factory recipe in `prototypes/recipes.lua`: 20 iron plate and
  5 copper plate, 4 s, category `rts-buildings`, order "b". The HUD enables a build button when such a recipe exists,
  so the stockpile button is no longer greyed. The factory panel now lists 12 recipes.
- **Both sides start with the same plates**, 200 iron and 100 copper, from `match.START_PLATES`. The enemy gets them
  through the template: match.lua sets `basetemplate.STOCK` from `match.START_PLATES` when the module loads. The
  stockpile contents of each side right after placement are kept in `storage.match.start_plates`.
- **`always_day`** is set on the arena, as in Phase 1. The arena is still [-80, 80)².
- **`match.home(force)`** is now the CC centre, which is where SPACE jumps the camera. The new **`match.army_point(force)`**
  is the army's gathering point, 14 tiles in front of the CC.

### CC composite (`buildings.place_cc`)

Offsets are from the CC centre. The CC is 4×4, so its centre is a tile corner, and `place_cc` rounds the position to one.

| Entity | Offset | Notes |
|---|---|---|
| `rts-command-center` | (0, 0) | 20 construction robots and 10 logistic robots in its robot inventory (`buildings.CC_BOTS`) |
| `rts-core-power` | (0, 0) | hidden, 4 MW |
| `rts-core-pole` | (0, 0) | hidden, covers 36×36 tiles |
| `rts-stockpile` ×4 | (-3.5, -1.5), (-3.5, 1.5), (3.5, -1.5), (3.5, 1.5) | `buildings.CC_STOCKPILES` |

**The CC buffer is pre-charged.** `LuaEntity.energy` is writable for the roboport, so `place_cc` sets it to
`electric_buffer_size`. The autotest reads 200.0 / 200.0 MJ at tick 120. The CC therefore never draws the 2 MW
charging load that the prototype notes warned about (gotcha 6).

### Starter base template (`basetemplate.ENTITIES`)

The template is data. Offsets are from the CC centre for the variant facing +x, where +x points at the arena centre.
The mirrored variant flips x and swaps east and west.

| Part | Entities and offsets |
|---|---|
| CC composite | at (0, 0), as above. `basetemplate.STOCK` goes into its stockpiles. match.lua sets it from `match.START_PLATES`: 200 iron plate and 100 copper plate. |
| Iron line, north | 2 extractors facing north at (-8.5, -6.5) and (-5.5, -6.5), on iron ore placed under their 5×5 mining area. A belt runs east from (-9.5, -8.5) to (2.5, -8.5). 2 inserters at (±1.5, -9.5) feed 2 smelters at (±1.5, -11.5). 2 inserters at (±1.5, -13.5) feed 2 stockpiles at (±1.5, -14.5). |
| Copper line, south | 1 extractor facing south at (-6.5, 6.5), on copper ore. A belt runs east from (-7.5, 8.5) to (2.5, 8.5). The inserters, 2 smelters and 2 stockpiles mirror the iron line in y. |
| Power | 6 medium poles at (0.5, ±4.5), (0.5, ±9.5), (-5.5, 0.5) and (5.5, 1.5), all within the 9-tile wire reach of the core pole or of each other. 2 solar arrays at (-7.5, ±1.5). |
| Military | 1 barracks at (5.5, -1.5), next to the CC stockpile at (3.5, -1.5) |

- **Size.** The template has 57 entities, plus the 2 core parts, and 65 ore tiles at 3000 ore each. Its area is (-12, -16)–(8, 16) from the CC for
  facing +x. Everything is inside the CC's logistic area (radius 25) and the core pole's supply area.
- **Build.** `basetemplate.ensure()` creates the surface `rts-scratch` and the force `rts-template`. It builds both variants
  from the data, with the CC at (-40, 0) for +x and at (40, 0) for -x. It then sets `disabled_by_script` on the copies,
  hides the surface from every force, and logs `basetemplate: variant ±1 ... 0 failed`. Inserters are rotated by trial
  until their `pickup_position` matches the entry's `pickup`, which avoids depending on 2.0's inserter direction
  semantics.
- **Clone.** `basetemplate.clone_to(surface, force, cc_position, facing?)` runs `clone_area` with
  `clear_destination_entities = true` for any force. It then registers and re-enables the clones, resolves the CC core
  parts and refills the CC buffer. Cloning onto an existing CC replaces that CC composite, stock included.
- **Adjusting the layout.** Edit `basetemplate.ENTITIES`; the area is measured after building. Keep every consumer
  inside the CC's logistic area, and keep extra poles within 9 tiles of a connected pole. Prototype gotcha 3 explains
  why: an unwired pole steals half of a solar array's output.

## API for the HUD and selection agent

All modules follow the Phase 1 rules: register through `events`, use idempotent `init()`, and store state in `storage`.
`buildings.lua` requires only `util` and `events`, so `selection.lua`, `orders.lua` and `hud.lua` can require it, and
`production` and `economy` too, without a cycle.

### `scripts/buildings.lua`

`storage.buildings[unit_number] = {entity, kind, force, surface, position, rally?, parts?}`.

| Field | Meaning |
|---|---|
| `kind` | `"cc"`, `"barracks"`, `"factory"`, `"turret"`, `"extractor"`, `"smelter"`, `"stockpile"` or `"solar"` |
| `force` | Force name |
| `surface` | Surface index |
| `position` | Copied at registration, so it stays usable after the entity is gone |
| `rally` | Barracks only. See Rally semantics below. |
| `parts` | CC only: `{power, pole}`, the hidden core entities |

production.lua adds these fields: `last_pf`, `next_check`, `pull_state`, `starved_since`, `feed_state` and `spawned`.

| Function | Returns / does |
|---|---|
| `buildings.get(unit_number)` | Live record or nil (drops stale records) |
| `buildings.for_force(force_name, kind?)` | Iterator `(unit_number, record)` over live buildings |
| `buildings.all(kind?)` | Same, all forces |
| `buildings.count(force_name, kind?)` | Number of live buildings |
| `buildings.is_alive_force(force_name)` | True while the force has a CC, a barracks or a factory |
| `buildings.main_cc(force_name)` | `record, unit_number` of the lowest-numbered live CC, or nil |
| `buildings.kind_of(entity_name)` | Kind or nil; `buildings.KIND_BY_NAME` is the map |
| `buildings.register(entity)` | Idempotent. The registration events already call it; use it after `create_entity` without `raise_built`. |
| `buildings.place_cc(surface, position, force)` | Places the full composite and returns `cc, {power, pole, stockpiles}` |
| `buildings.core_parts(cc_record)` | `{power, pole}` of a CC |
| `buildings.set_rally(unit_number, position_or_nil)` | Sets or clears a barracks rally point. Returns false when the record does not exist. |
| `buildings.rally_point(unit_number)` | The rally point if one is set, else the default exit |
| `buildings.default_exit(record)` | 6 tiles (`EXIT_DISTANCE`) from the building centre towards (0, 0) (`ARENA_CENTRE`) |
| `buildings.on_added(fn(un, rec))` | Callback for a new building. Register at load time. |
| `buildings.on_removed(fn(un, rec))` | Callback for a removed building, for example to drop it from a building selection. Register at load time. `rec.entity` may already be invalid. |

**Registration events.** Buildings are registered on `on_built_entity`, `on_robot_built_entity`, `script_raised_built`,
`script_raised_revive` and `on_entity_cloned`. Ghosts are ignored, and so is everything on `rts-scratch`. Buildings are
removed on `on_entity_died`, `on_player_mined_entity`, `on_robot_mined_entity` and `on_object_destroyed`, whichever comes first.
When a CC is removed, its core parts are destroyed. The parts are matched by stored reference, so a CC that a clone
replaced cannot take the new CC's parts down with it.

**Selecting a building.** Single-clicking an own building gives an entity in the `select` event list. Use
`buildings.get(entity.unit_number)` and check `rec.force == player.force.name`.

### Rally semantics

- **No rally set.** `rally == nil`. New units appear at the barracks' default exit, get `stop` and stay there.
- **Rally set.** New units appear at the default exit and get a `go_to_location` to the rally with radius 1 and
  `distraction = none`. Successive units go to a golden-angle spiral of slots around the rally, 2.5 tiles apart, and the
  slots repeat every 12 units.
- **The order stays "idle"** during the walk, so the unit is unclaimed. When the walk completes, units.lua's idle rule
  issues `stop`. When the player orders the unit, orders.lua claims it and the walk is replaced.
- **Setting a rally** is `buildings.set_rally(un, position)`. The PHASE2 right-click flow should call it for each
  selected barracks. `/rts-rally x y` does the same for every own barracks.

### `scripts/production.lua`

| Function / data | Returns / does |
|---|---|
| `production.set_recipe(entity_or_unit_number, recipe_name_or_nil)` | Sets or clears the recipe of a barracks or factory and returns true when the machine now has it. The recipe is read back, because a wrong-category recipe is silently ignored (prototype gotcha 1). Ingredients and products that the change removes go back to the network; anything the network cannot take is spilled. Use nil for the PHASE2 "pause" button. |
| `production.status(unit_number)` | `{recipe, progress (0..1), crafting, state, rally, spawned}` for the barracks or factory panel. `state` is one of `idle`, `supplied`, `starved: <items>` or `no network`. |
| `production.stats(force_name)` | `{kits, walkers, heavies, buildings, items, magazines, first_kit_tick, first_walker_tick}`; see Counters below |
| `production.on_spawned(fn(unit_entity, barracks_record, kit_name))` | Callback after a barracks spawned a unit. Register at load time. |
| `production.network_for(entity)` | The force's logistic network covering the entity's position, or nil |
| `production.KITS` | Kit item name to `{unit, kind}`: `rts-walker-kit` gives `rts-walker` (walker) and `rts-walker-heavy-kit` gives `rts-walker-heavy` (heavy) |

**Counters**, in `storage.production.stats[force]`:

| Counter | What it counts |
|---|---|
| `kits` | Barracks crafts, from `products_finished` deltas |
| `walkers` | Units spawned from kits. `heavies` is the heavy share of it. |
| `buildings` | Factory crafts. One craft is one recipe run, for example 1 extractor or 10 belts. |
| `items` | Items the factories moved into the network |
| `magazines` | Magazines moved from the network into turrets |

**Cadence** (all values are in `production.*`):

- **Every 30 ticks** (`PULL_PERIOD`):
  - **Pull.** A barracks or factory with a recipe pulls when its input lacks one craft. It takes up to 2 crafts' worth
    (`PULL_CRAFTS`) with `network.remove_item`, and only when the network can cover every missing ingredient.
  - **Hand-off.** Each factory moves its whole output into the network with `LuaLogisticNetwork.insert`. Whatever does
    not fit stays in the output.
- **Barracks checks.** A barracks is checked at its predicted completion tick, `(1 - crafting_progress) × recipe.energy / crafting_speed`.
  A sweep every 60 ticks catches anything the prediction missed.
- **Every 120 ticks** (`FEED_PERIOD`), each `rts-turret` holding fewer than 5 `firearm-magazine` gets up to 10 from its
  network. Since the turret balance on 2026-10-15, a magazine is 6 s of fire, so 10 last a minute and the 2 s feed
  cadence is ample. See "Turret balance" in `phase2-prototypes-notes.md`.
- **Logging.** The pull and feed states are logged on change only. Spawns and hand-offs are logged as they happen.

**Fairness.** Consumers are visited oldest-starved first. A starved consumer whose only shortage is a single item
reserves that item for the rest of the pass. Without this, a factory that needs 20 iron starved forever next to a
barracks that took every 10 iron as it arrived: factory crafts stayed at 33 from 90 s to 150 s in the first run. With
it, both progress (`eco_shared_pool`). A consumer short of several items reserves nothing, so a heavy-kit barracks
waiting for steel does not block iron for everyone else.

### `scripts/economy.lua`

**`economy.snapshot(force_name)`** is recomputed at most every 30 ticks and cached in `storage.economy.cache`. The
cache must live in `storage` because GUI captions are game state. Its fields:

| Field | Meaning |
|---|---|
| `iron`, `copper`, `steel`, `stone`, `magazines` | Network counts of iron-plate, copper-plate, steel-plate, stone and firearm-magazine |
| `items` | `{[name] = count}` for everything in the force's CC networks, all qualities summed. Circuits are `items["electronic-circuit"]`. |
| `bots_total`, `bots_idle` | Construction plus logistic robots. Split fields: `construction_total`, `construction_idle`, `logistic_total`, `logistic_idle`. |
| `power_demand` | W drawn, as the 5 s average of the `input` category of the core pole's `electric_network_statistics` |
| `power_production` | W produced, as the 5 s average of the `output` category |
| `power_capacity` | W available: `power_production × 60` of each CC core (4 MW), plus `get_max_energy_production() × 60` of every solar array on those networks. The arena is always day. |
| `power_satisfaction` | 0..1: the average `energy / electric_buffer_size` of the force's extractors, smelters, barracks and factories on those networks with status `working` or `low_power`. It is 1 when there are none. |
| `networks` | Number of distinct CC logistic networks |
| `tick` | Tick the snapshot was computed |

A force with no CC gets zeros, `networks = 0` and `power_satisfaction = 1`.

**Measured power semantics.** In electric network statistics, `input` is consumption by entity name and `output` is
production. Both are J/tick, so multiply by 60 for watts. One template base reads `rts-smelter=680kW`, `rts-factory=310kW`,
`rts-extractor=270kW`, `rts-barracks=155kW`, `rts-command-center=50kW` and `fast-inserter=45kW`. The output side reads
`rts-solar-array=800kW` and `rts-core-power=710kW`. Solar is used first and the core covers the rest. The CC's buffer is
not a usable satisfaction signal, because it charges slowly.

| Other function | Returns / does |
|---|---|
| `economy.describe(force_name)` | One line for `game.print` or the HUD, for example: `rts-player: iron 411, copper 175, steel 0, stone 0, magazines 30 \| bots 30 idle / 30 \| power 1.48 / 4.80 MW, satisfaction 100%` |
| `economy.networks(force_name)` | The distinct CC networks |
| `economy.network(force_name)` | The main CC's network |
| `economy.give(force_name, item, count)` | Puts items into the pool: the network first, then the force's stockpiles |
| `economy.take(force_name, item, count)` | Removes items from the pool. Returns the count moved. |
| `economy.power_lines(force_name)` | Debug lines with the flows per entity name |

### `scripts/match.lua` additions

| Addition | What it is |
|---|---|
| `match.CC_POSITIONS` | CC centres |
| `match.FACING` | +1 for the player, -1 for the enemy |
| `match.ARMY` | `{walkers = 6, heavies = 0}`. `match.ARMY_SIZE` is their sum. |
| `match.SPACING`, `match.spacing(name)` | Spawn grid spacing per unit: 3.5 tiles for `rts-walker`, 5 for `rts-walker-heavy` |
| `match.army_point(force)` | The army's gathering point. Walkers fill 2 columns from it back towards the CC, and heavies stand in a column 6 tiles in front. |
| `match.DEFAULT_CONFIG`, `match.wave_config()` | Wave timing `{first_wave_ticks, wave_period_ticks}`. The live copy is `storage.match.config`. |
| `match.set_wave_timing(first_s, period_s)` | Debug override, also `/rts-wave-timing` |
| `match.is_out(force)` | No CC, barracks or factory, and no units |
| `match.decide_winner(player_out, enemy_out)` | Pure rule: nil, a force name, or `"draw"` |
| `match.result(force)` | `nil` unless `phase == "ended"`, else `"victory"`, `"defeat"` or `"draw"` from that force's view |
| `match.wave_retarget(position)` | Where a wave goes next: the nearest player entity within 300 tiles, else the army centroid, else the CC |
| `match.START_PLATES`, `match.STARTING_STOCK`, `match.ORE_PATCHES`, `match.ORE_AMOUNT` | Starting plates for both sides, the player's starting stock, and ore data |
| `match.ENEMY_BARRACKS_RECIPE` | `rts-walker-kit` |
| `match.arm_barracks(force, recipe)` | Sets the recipe on every barracks of the force that has none |

**Win and lose** (Phase 1 QA follow-up 4). A force is out when `buildings.is_alive_force` is false and it has no units.

- **Who wins.** A side wins only when the other side is out and it is not. Both out is a draw, and nobody out means
  the match goes on.
- **Units alone decide nothing.** 0 vs 0 units with buildings left on either side does not end the match. Victory
  with 0 units of your own is possible when your base still stands and the enemy has nothing.
- **What ending does.** It sets `storage.match.phase = "ended"` and `winner`, plus `ended_tick`, and prints "Victory!
  The enemy base and army are destroyed." or "Defeat. Your base and army are destroyed.". The result is final until
  `/rts-qa-reset`.

**For the HUD agent.** Derive the banner from `match.result(player.force.name)`, which is nil while the match runs. Do
not derive it from unit counts. The HUD's Phase 1 texts are also stale ("Destroy the enemy army", "Your army is
destroyed").

**Waves.** The first wave comes 3 minutes after the armies spawn, then one every 2 minutes (Phase 1 QA follow-up 2).
`storage.match.config` holds the timing. `/rts-wave-timing <first_s> [period_s]` or `match.set_wave_timing` changes it.
A first wave that has not come yet is rescheduled. A wave targets the player army, or the player CC when there is no
army. Waves include every enemy unit, so the barracks output joins them automatically.

## Console commands

All commands are admin only. They act for the issuing player's force, or for `rts-player` from the server console and
the autotest.

| Command | Effect |
|---|---|
| `/rts-give <item> [count=100]` | Puts the item into the pool through `economy.give` |
| `/rts-eco` | Prints `economy.describe` and the production counters for both forces |
| `/rts-build-template` | Clones the template over your own base at `match.home` (replacing it and its stock) and sets the barracks to walker kits |
| `/rts-rally <x> <y>` | Sets the rally of all your barracks. With no arguments, it clears them. |
| `/rts-wave-timing [first_s] [period_s]` | Debug: sets the enemy wave timing. With no arguments, it prints the timing. |

`/rts-dump` now also prints the economy line and the production counters for each force.

## Headless autotest

Run it on a copy, because the log is named after the directory:

```sh
rm -rf build/p2-eco && mkdir -p build/p2-eco && cp -R mods/factorio-rts mods/mod-list.json build/p2-eco/
tools/headless-run.sh 200 '\[rts' build/p2-eco
```

For the base-only run, use `build/p2-eco-nosa` with the mod list from `build/rts-nosa/mod-list.json`. That list disables
Space Age, quality and elevated-rails.

The economy part starts at tick 120, before the Phase 1 part. It checks the following, in order:

1. **Match-start state.**
   - `eco_cc_composite`, `eco_starting_stock` (every entry of `match.STARTING_STOCK` in the network, stockpiles, factory
     and the larger belt, inserter and pole counts included) and `eco_starting_plates_parity` (200/100 in both sides'
     stockpiles at match start).
   - `eco_bots` (20 + 10) and `eco_cc_buffer_precharged`.
   - `eco_ore_patches`, `eco_enemy_template` (cc 1, barracks 1, extractor 3, smelter 4, solar 2, stockpile 8) and
     `eco_enemy_barracks_recipe`.
2. **CC death.** A throwaway CC composite at (0, 60) is killed with `die()`. `eco_cc_death_cleanup` expects both core
   parts invalid and the registry entry gone in the same tick.
3. **Setup.**
   - `/rts-build-template` (`eco_player_template`).
   - `/rts-give iron-plate 400` and `copper-plate 100` (`eco_give`).
   - 2 factories and 1 turret created with `raise_built` (`eco_registered_by_event`).
   - `set_recipe(factory, "rts-walker-kit")` is rejected (`eco_wrong_category_rejected`). `rts-stockpile` exists in
     `rts-buildings` and the factory accepts it (`eco_stockpile_recipe`). The factories are then set to
     `rts-extractor` and `rts-ammo`.
   - `/rts-rally -40 10` (`eco_rally_set`).
4. **Within 150 s:**
   - Production: `eco_kits_produced`, `eco_walkers_spawned`, `eco_walker_at_rally` (within 6 tiles),
     `eco_factory_item_in_network`, `eco_turret_ammo`.
   - Economy: `eco_snapshot` (non-zero iron, bots, capacity and demand after 15 s), `eco_player_smelting` (the cloned
     template smelts) and `eco_enemy_production`.
5. **Power.** `eco_brownout` switches the player's core off at 20 s, solar only, and expects the snapshot satisfaction
   below 0.9. `eco_power_restored` expects 0.95 or more after it is back on.
6. **Fairness.** `eco_shared_pool` expects barracks kits and factory crafts both to grow from 75 s to 150 s.
7. **Reports.** The part logs reports every 30 s. At 150 s it logs timing and latency lines, and then
   `[rts] autotest summary X/Y` once the Phase 1 part is done.

The Phase 1 part was adapted in these ways:

- **Heavy.** It spawns 1 heavy through `/rts-spawn`, because the starting armies are walkers only.
- **Resets.** `qa_reset_*` expects 6 per side at `match.army_point`. `qa_reset_spacing` expects at least 3.5 tiles
  between the freshly spawned units.
- **Wave timing.** `wave_config_default` checks the 3 min / 2 min default and that the first wave was scheduled 3 min
  after the armies spawned. The autotest then runs `/rts-wave-timing 45 90`, and `wave_timing_override` checks it.
  `winner_rule` checks the winner truth table and that `match.result` is nil while the match runs.
  `wave_retarget_fallback` drives the retarget path with no player entity in range (gotcha 12).
- **First wave.** It is postponed until `/rts-qa-reset` re-enables waves. The `qa_reset` check then expects the next
  wave 45 s later, so the wave brain is still exercised: the log shows `enemy wave 1` at about 112 s.

### Results (final code)

| Run | Checks | Errors | Log |
|---|---|---|---|
| Space Age, quality and elevated-rails on (`build/p2-eco/`) | 65/65 | 0 (data, create and server stages) | `build/p2-eco-server.log` |
| Base only (`build/p2-eco-nosa/`) | 65/65 | 0 | `build/p2-eco-nosa-server.log` |

Both runs last 220 s, so they continue for about a minute after the summary line. They use a copy of `mods/` that
was identical to `mods/` when the runs finished, so it includes the HUD, selection and orders work. An earlier
base-only run ended in a defeat, at tick 11820, and kept running without errors afterwards.

Excerpt from the Space Age run:

```
[rts] autotest check eco_cc_buffer_precharged: PASS CC energy 200.0 / 200.0 MJ at tick 120
[rts] buildings: cc #281 of rts-player at (0.0, 60.0) removed (died), 2 core parts destroyed
[rts] basetemplate: cloned variant +1 for rts-player, CC at (-60, 0): 59 entities [barracks=1 cc=1 extractor=3 ...]
[rts] autotest check eco_walker_at_rally: PASS after 5.0s: walker #368 is 3.1 tiles from the rally (-40.0, 10.0)
[rts] autotest check eco_factory_item_in_network: PASS after 6.0s: 1 rts-extractor in the network, 11 items handed off
[rts] autotest check eco_brownout: PASS solar only: rts-player: ... power 1.24 / 0.80 MW, satisfaction 52%
[rts] autotest eco: kit-to-unit latency over 23 player kits: min 0, max 0, avg 0.00 ticks
[rts] match: enemy wave 1: group #800 with 10 units from (45.4, -1.3) -> attack_area (-43.8, 1.8)
[rts] autotest summary 65/65 (all passed)
```

**The defeat path ran in an earlier base-only run.** The wave of 16 enemy walkers killed the player army. It then
re-targeted to the player CC, and the player's barracks, factories and CC died, the CC with "2 core parts destroyed".
The log then shows `match: ended at tick 10860, winner=rts-enemy`. In a later base-only run, one autotest factory
survived the wave. The player correctly stayed "not out" with 0 units, and the match kept running. That is the rule,
but see Open items.

## Measured timings

All times are game time at 60 UPS. In the autotest, the player's template is cloned at tick 120.

**Response times.**

| Event | Time |
|---|---|
| First player kit | 3.5 s after the clone: the next 30-tick pull plus the 3 s recipe |
| First enemy kit | 3.0 s after tick 0 |
| First walker at the rally | 5 s, after walking 14 tiles from the barracks exit |
| First factory item in the network | 6 s |
| Turret holds ammo | 5 s, via the ammo factory and the 120-tick feed |
| Kit-to-unit latency | 0 ticks for all 23 player kits, in both variants |

The 0-tick latency comes from the predictive check, as in spike #4.

**Production rates.**

| Case | Measured | Why |
|---|---|---|
| Barracks ceiling | 20 kits/min | The recipe takes 3 s at crafting speed 1 |
| Stock-fed | 20 kits/min | The enemy's first 90 s with an intact base: 30 kits by 90 s in the base-only run |
| Iron-limited, theory | 7.5 kits/min | 2 iron smelters (speed 2, 3.2 s recipe) give 1.25 plates/s, and a kit takes 10 plates |
| Iron-limited, enemy | 8.0 then 6.0 kits/min | The 90–120 s and 120–150 s periods of the base-only run, enemy base intact |
| Shared iron, player | about 2 kits/min + 4–5 factory crafts/min | The player template with 2 factories sharing the iron (extractor 20 iron, ammo 10 iron) |

**Power.**

| Reading | Value |
|---|---|
| Template base, everything running | 1.5 MW |
| Steady, iron-limited | 0.9–1.25 MW |
| Capacity | 4.8 MW: the 4 MW core plus 2 × 400 kW solar |
| Solar only (brownout test) | 52 % satisfaction at about 1.5 MW demand |

**Cost.** The pull pass was not profiled. Every 30 ticks it visits each barracks and factory once, with a few inventory
reads and one `find_logistic_network_by_position`. Spike #4 measured about 6 µs per barracks per poll.

## Gotchas

1. **`LuaEntity.energy` is writable for a roboport.** It is not limited to energy interfaces, so the CC buffer can be
   pre-charged. `electric_buffer_size` is readable for the roboport too: 200 MJ.
2. **`disabled_by_script` is ignored by roboports.** The scratch CC cannot be frozen. With no ghosts and no requests on
   the scratch surface, its robots stay docked. Whether `clone_area` copies the flag is not established. buildings.lua
   clears it on every clone from the scratch surface, and `clone_to` clears it again.
3. **`on_entity_cloned` fires during `clone_area`, synchronously**, also for resource entities, and it can deliver a
   CC before its core parts. The parts are resolved again on `on_area_cloned` and in `clone_to`.
4. **`on_object_destroyed` arrives at the end of the tick.** When a clone replaces a CC, the old CC's removal must not
   look for core parts at its position, because the new CC's parts are already there. Removal therefore uses stored
   references. The position lookup is only used in `on_entity_died`, where the dying CC still occupies the spot.
5. **The core power's 4 MJ buffer bridges about 2.5 s of deficit.** Setting `power_production = 0` alone did not cause a
   brownout within 2 s. The test also sets its `energy = 0`.
6. **Electric flow statistics are J/tick.** `input` is consumption and `output` is production, and only the core pole
   (an electric pole) has `electric_network_statistics`.
7. **A greedy pull starves the bigger recipe.** See Fairness above. Production order matters even with tiny incomes.
8. **The Phase 1 attack-move hits the enemy base.** In Space Age runs, the 6 autotest walkers sent to (50, 0) destroy
   both enemy solar arrays and a smelter within about 60 s, and in one run also the enemy barracks. Enemy production
   then stops, so the clean enemy rates above come from the base-only run, where the enemy base stayed intact. Six
   walkers can raze much of the template base, which says something about its durability.
9. **Two Phase 1 checks were flaky in the base-only variant.** `move_spread` sat on a float boundary: the base-game
   walkers' formation spacing is exactly the 2.5 minimum, and `>= 2.5` failed once at 2.4999…. It now has a 1e-6
   tolerance. `attack_engaged` was never logged when the base-game walkers killed the dummy before the first 60-tick
   look. That case now counts as engaged when attack completions were seen, so both variants run the same 58 checks.
10. **The factory hand-off is name-agnostic.** It moves whatever is in the output, so the vanilla belt, inserter, pole
    and magazine items (prototype gotcha 11) need no mapping. Only kits are mapped, in `production.KITS`.
11. **Pairing finish and spawn events needs care within one tick.** production.lua's `on_tick` handler runs before
    debug.lua's, so an observer that only polls in its own handler sees a kit finish after it was already spawned. The
    first latency reading, 180 ticks or more, was this artifact. The spawn callback now syncs the observer first.
12. **A local function used before its definition is a nil global at runtime.** The first Phase 2 `match.lua` called
    `wave_target()` from `player_target()` above it, and nothing complained until a wave's command completed with no
    player entity in range. That happened in a base-only run right after the player CC died, and the server stopped
    with "attempt to call global 'wave_target'". It is fixed, and a scan of all six edited files finds no other
    forward reference. There is no `luac` on this machine, so only runs catch this class of bug.

## Decisions for the lead

- **Factory and plate parity: done.** The player's stock now includes 1 factory. Both sides start with 200 iron and
  100 copper, as the lead decided on 2026-10-15.
- **Enemy production versus waves.** The template barracks makes a walker every 3 s while its 200-plate stock lasts:
  about 20 in the first minute. After that, iron limits it to about 7.5 a minute. In the base-only run, with the enemy
  base intact, it had made 37 walkers by 150 s. With the first wave now at 3 min, a player who starts from zero meets
  roughly 40 barracks walkers plus the 6 starting ones in that wave. The plate parity does not change this. The
  difference is the enemy's free, working template: its barracks starts at once, and 4 smelters run. Other balance
  levers are less starting plates (`match.START_PLATES`, which moves both sides) or an enemy production cap. Interactive QA of the economy should still start with
  `/rts-qa-reset nowaves`. Note that `/rts-qa-reset` resets units, not buildings or production.
- **The template ore under the extractors is extra.** It is 65 tiles at 3000 ore each, close to the CC, in addition to
  the per-side patches. The player has no such ore in a normal start.

## Open items

- **No GUI check yet.** CC composite rendering, the ore patches, the mirrored enemy base and walkers walking to the
  rally have not been seen in a GUI run.
- **Saves from Phase 1 get no bases.** `match.init` returns early when `storage.match` exists, so
  `on_configuration_changed` on such a save does not place any. New games are fine.
- **A lone factory can keep a beaten player alive.** The wave's `attack_area` did not complete again after the CC
  fell, so it never re-targeted the last factory, which is not a military target. Phase 3's enemy brain should hunt
  the remaining buildings, or the rule could ignore factories.
- **The scratch surface stays in the save.** It holds the two frozen template copies and has no other effect.
