# Phase 4 content prototypes (wave A1): implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE4.md` sections 2.5 (chains), 3 (units and counters) and 4 (technology names).
Conventions follow `docs/qa/phase2-prototypes-notes.md`.

## Files

| File | Change |
|---|---|
| `balance.lua` (mod root) | New. Pure-data balance table for both stages (see "Balance table API"). |
| `prototypes/units.lua` | Rewritten. Adds the drone, raider, artillery, walker Mk2, heavy Mk2 and commander. Every unit reads its numbers from `balance.lua`. |
| `prototypes/buildings.lua` | Adds the laser turret, wall, steam plant, accumulator and radar. Health now comes from `balance.lua`, with values unchanged. Adds the raid-target mask and the factory's `rts-intermediates` category. |
| `prototypes/items.lua` | Adds 5 building items, 5 kits and the `rts-commander` item. |
| `prototypes/recipes.lua` | Kit and building recipes are now generated from `balance.lua`, with values unchanged. Adds the new recipes and overrides the vanilla steel recipe. |
| `prototypes/intermediates.lua` | New. The `rts-explosives` item and the factory recipes for gears, cable, circuits and explosives. |
| `prototypes/categories.lua` | Adds the `rts-intermediates` recipe category and subgroup. Adds 6 ammo categories and the `rts-raid-target` trigger target type. |
| `data.lua` | Two lines: `require("balance")` and `require("prototypes.intermediates")`. |
| `scripts/units.lua` | `KIND_BY_NAME` is built from `balance.units`. This is also the control-stage `require("balance")`. |
| `scripts/production.lua` | Five entries added to `production.KITS`. Nothing else changed. |
| `locale/en/content.cfg`, `locale/ru/content.cfg` | New. All strings for these prototypes. They are separate files, so `factorio-rts.cfg` is never touched. |

## New names

| Kind | Names |
|---|---|
| Units (entities) | `rts-drone` (unit), `rts-raider`, `rts-artillery`, `rts-walker-mk2`, `rts-heavy-mk2` (spider-unit), `rts-commander` (spider-vehicle) |
| Unit parts | Space Age legs: `rts-raider-leg`, `rts-artillery-leg`, `rts-walker-mk2-leg`, `rts-heavy-mk2-leg`. Base-game legs: `<unit>-leg-1..8`. Commander legs: `rts-commander-leg-1..8`. Projectiles: `rts-raider-projectile` and `rts-walker-mk2-projectile` (Space Age), `rts-artillery-shell`, `rts-commander-rocket`. |
| Buildings | `rts-laser-turret` (electric-turret), `rts-wall` (wall), `rts-steam-plant` (burner-generator), `rts-accumulator` (accumulator), `rts-radar` (radar) |
| Items | The 5 building items above, plus the kits `rts-drone-kit`, `rts-raider-kit`, `rts-artillery-kit`, `rts-walker-mk2-kit` and `rts-heavy-mk2-kit`. Also `rts-explosives` and `rts-commander` (item-with-entity-data, no recipe). The commander's guns are `rts-commander-launcher-1/2` and its ammo is `rts-commander-rocket`; both are hidden. |
| Recipes | One per kit and building, named like the item. Plus `rts-gear`, `rts-cable`, `rts-circuit` and `rts-explosives`. |
| Categories | Recipe category `rts-intermediates`, item subgroup `rts-intermediates`, trigger target type `rts-raid-target`, equipment grid `rts-commander-grid` (4×4, `armor` category) |
| Ammo categories | `rts-walker` (walker and Mk2), `rts-heavy` (heavy and Mk2), `rts-drone`, `rts-raider`, `rts-artillery`, `rts-commander` |

## Costs

All recipes are hidden from hand crafting and have `auto_recycle = false`.

| Recipe | Machine | Time | Cost | Result | Enabled at start |
|---|---|---|---|---|---|
| `rts-drone-kit` | barracks | 2 s | 6 iron | 1 | yes |
| `rts-raider-kit` | barracks | 5 s | 15 iron, 8 circuit | 1 | yes (research gate in the barracks) |
| `rts-artillery-kit` | barracks | 12 s | 40 iron, 10 steel, 10 explosives | 1 | yes (research gate in the barracks) |
| `rts-walker-mk2-kit` | barracks | 3 s | 10 iron, 2 copper, 5 steel | 1 | **no** |
| `rts-heavy-mk2-kit` | barracks | 8 s | 30 iron, 10 copper, 10 steel | 1 | **no** |
| `rts-laser-turret` | factory | 8 s | 20 iron, 10 circuit | 1 | **no** (`rts-unlock-laser`) |
| `rts-steam-plant` | factory | 10 s | 40 iron, 10 steel | 1 | **no** (`rts-steam-power`) |
| `rts-wall` | factory | 2 s | 5 stone brick | 5 | yes |
| `rts-accumulator` | factory | 4 s | 10 iron, 10 copper | 1 | yes |
| `rts-radar` | factory | 6 s | 20 iron, 10 circuit | 1 | yes |
| `rts-gear` | factory | 1 s | 2 iron | 1 `iron-gear-wheel` | yes |
| `rts-cable` | factory | 0.5 s | 1 copper | 2 `copper-cable` | yes |
| `rts-circuit` | factory | 1.5 s | 1 iron, 3 cable | 1 `electronic-circuit` | yes |
| `rts-explosives` | factory | 2 s | 2 coal, 1 iron | 1 `rts-explosives` | yes |
| `steel-plate` (vanilla, smelter) | smelter | 6.4 s (3.2 s in the smelter) | **2 iron** (was 5 iron, 16 s) | 1 steel | yes |
| `stone-brick` (vanilla, smelter) | smelter | 3.2 s | 2 stone | 1 brick | yes (vanilla) |

The Phase 2 recipes keep their costs. Steel now follows `docs/PHASE4.md` 2.5 ("2 plates, slow"). As a result the heavy kit costs 40 iron-equivalent instead of 55.

**Gating matches `scripts/research.lua`.**

- Tier-1 kit recipes stay enabled. The research gate in the barracks refuses locked units.
- Research turns building recipes in its `LOCKS` on and off per force at runtime. Those recipes start disabled here as well.
- The mk2 kit recipes start disabled. Research deploys mk2 units from tier-1 kits after Armor I, so these kits would let a player skip the research.
- **`LuaEntity.set_recipe` accepts a disabled recipe.** The probe set `rts-walker-mk2-kit` on a barracks successfully. The HUD and production code must not offer disabled recipes.

## Units

Speed is the design target relative to the walker. "Measured" is the average speed between 1 s and 5 s into a 120-tile `go_to_location`. The first figure is Space Age, the second base-only. The final probe values are under "Speeds".

| Unit | Kind | Supply | Health | Attack | Range | Speed target | Measured (Space Age / base) | Strong vs | Weak vs |
|---|---|---|---|---|---|---|---|---|---|
| `rts-walker` | walker | 1 | 200 | 20 per 60 ticks | 20 | 1.0 | 11.1 / 11.6 tiles/s | drone | heavy, artillery |
| `rts-walker-mk2` | walker | 1 | 280 | 25 per 60 ticks | 20 | 1.0 | ×0.97 / ×1.00 | drone | heavy, artillery |
| `rts-walker-heavy` | heavy | 3 | 600 | Space Age: acid stream, modifier 2. Base: 60 per 90 ticks | 10 / 12 | ~0.75 | ×0.76 / ×0.76 | walker, drone | artillery, laser |
| `rts-heavy-mk2` | heavy | 3 | 840 | Space Age: acid stream, modifier 2.5. Base: 75 per 90 ticks | 10 / 12 | ~0.75 | ×0.72 / ×0.76 | walker, drone | artillery, laser |
| `rts-drone` | drone | 1 | 60 | 10 physical per 30 ticks (melee) | 1 | ≥ 1.4 | ×1.50 / ×1.43 (16.6 tiles/s) | artillery, hauler, raider | turret, walker |
| `rts-raider` | raider | 2 | 120 | 8 per 30 ticks; ×3 against raid targets | 12 | 1.3 | ×1.29 / ×1.37 | hauler, buildings | walker, turret |
| `rts-artillery` | artillery | 4 | 250 | 100 explosion, radius 4, per 240 ticks | 40, min 8 | 0.6 | ×0.60 / ×0.63 | turret, laser, heavy, wall | drone, raider |
| `rts-commander` | commander | 0 | 2000 | 40 explosion per rocket, two launchers at 30-tick cooldown | 30 | 1.2 × spidertron | ×1.22 / ×1.20 of the spidertron | — | focus fire |

**Visuals.**

- With Space Age, the walker and its Mk2 are the small strafer, the heavy and its Mk2 the small stomper, the raider the medium strafer and the artillery the medium stomper. Mask layers use the force colour. The GUI screenshot showed red and blue teams correctly.
- Without Space Age, they are spidertron mechs at scale 0.5 (walker), 0.8 (heavy), 0.6 (raider) and 1.0 (artillery).
- The drone is a medium-biter copy with one neutral steel-blue tint. **Units of type `unit` cannot take the force colour at runtime, so both teams' drones look the same.** Team colour for drones is out of scope.
- The commander is a spidertron copy. It has no resistances, because the spidertron's 60–80 % would make it immune to walker fire. It has a 20-slot trunk, no logistics tab, and `chunk_exploration_radius` 1.

**Vision is `max(30, range + 2)`.** The artillery therefore sees 42 tiles and acquires targets at its full range. It stays under 50, the value the unit documentation says causes self-grouping.

**The commander needs `rts-commander-rocket` in its ammo inventory (`defines.inventory.spider_ammo`).** Auto-targeting without a gunner is on by default, as read from `vehicle_automatic_targeting_parameters`. In a duel it fired one rocket every ~29 ticks, about 80 damage per second, and used about 2 rockets per second across both commanders. The grid accepted `personal-roboport-equipment`. A roboport in the grid also needs power equipment, which the abilities agent decides on.

**Changes to the Phase 1/2 units.**

- Each attack now uses its role's ammo category. The walker used to use `bullet` (base-only) or `biological` (Space Age), shared with the gun turret. Research can now scale every role on its own.
- Legs differ by variant:
  - Pentapod legs no longer carry the creature's resistances.
  - Base-game mech legs take no explosion damage. Every other damage type still passes to the torso.
- The base-only heavy's leg speed went from 0.8 to 0.5. It ran at ×0.95 of the walker and now runs at ×0.76, like the Space Age heavy.

## Buildings

| Building | Type (vanilla source) | Size | Health | Key stats | Raid target | Military target |
|---|---|---|---|---|---|---|
| `rts-laser-turret` | electric-turret (`laser-turret`) | 2×2 | 1000 | Range 22. 30 laser per shot every 40 ticks (45 per second). 800 kJ per shot, input limit 2 MW, buffer 801 kJ, drain 24 kW. Ammo category `laser`. | no | yes |
| `rts-wall` | wall (`stone-wall`) | 1×1 | 500 | No resistances. Vanilla's made it take 0.2 from an 8-damage shot. | no | no |
| `rts-steam-plant` | burner-generator (`burner-generator`, steam-engine graphics) | 3×5 | 800 | 1.8 MW `secondary-output`. Burns chemical fuel at effectivity 1, i.e. 0.45 coal/s at full load. 2 fuel slots. No pollution. | yes | no |
| `rts-accumulator` | accumulator (`accumulator`) | 2×2 | 300 | Vanilla 5 MJ, 300 kW | yes | no |
| `rts-radar` | radar (`radar`) | 3×3 | 400 | Nearby and sector radius 2 chunks: a 5×5-chunk square (160×160 tiles) stays charted. No far scan. Not linked to other radars. | yes | yes |

**Raid targets** have `trigger_target_mask = {"common", "rts-raid-target"}`. They are the CC, stockpile, extractor, smelter, solar array, factory, barracks, steam plant, accumulator, radar and the vanilla `medium-electric-pole` that the RTS uses.

- The lead's brief listed the assembling-machine, roboport, electric-pole, mining-drill, furnace and container types. I also added the solar array, steam plant, accumulator and radar as economy targets.
- Turrets and walls are not raid targets, so raiders stay weak against defences.
- **`rts-hub` and `rts-hauler` (`prototypes/logistics.lua`) must set the same mask to take raider bonus damage.** That file belongs to the logistics agent, and the team lead has been told.

**Radar.** "5 chunk reveal" in the brief was read as a 5×5-chunk square. For a radius of 5, set `balance.buildings["rts-radar"].reveal_chunks = 5`. That reveals 11×11 chunks, which is the whole small map. The radar's reveal was not checked at runtime: a headless server with no players does not chart (phase 1 gotcha 4).

**Steam plant fuel.** Inserters can feed its fuel slots. If coal should come from the logistic network instead, a script has to insert it, as `production.lua` does for turret ammo.

## Balance table API

`balance.lua` sits at the mod root and holds data only. It never touches `data.raw`, `game` or `prototypes`. `require("balance")` works from `data.lua`, from `prototypes/*.lua`, from `control.lua` and from `scripts/*.lua`. The probe logged `balance loaded in control: 8 units, 13 buildings` in `on_init`. Treat the table as read-only, because `require` caches it per stage.

```lua
local balance = require("balance")
balance.raid_target_type                 -- "rts-raid-target"
balance.units[name]  = {kind, tier, base?, role, supply, kit?, cost?, time?, unlock?, health, speed,
                        range, min_range?, cooldown, damage, damage_type?, damage_modifier?, splash?,
                        raid_multiplier?, ammo_category, ammo?, strong = {kinds}, weak = {kinds}}
balance.buildings[name] = {kind, cost?, time?, count?, health?, unlock?, supply_cap?, power?, ...}
balance.intermediates[recipe] = {result, count, cost, time}
balance.smelting[vanilla recipe] = {cost, time}
```

- **`kind`.** For units this is the `scripts/units.lua` kind. Mk2 tiers share the base kind and set `tier = 2` and `base`.
  - Supply: `balance.units[entity.name].supply`, for example walker 1, drone 1, raider 2, heavy 3, artillery 4, commander 0.
  - Barracks kit to unit: `for name, u in pairs(balance.units) do if u.kit and not u.made_by then ... end end`. The hauler's kit has `made_by = "factory"`: the factory makes it and `scripts/logistics.lua` turns it into a hauler next to the factory. It must not appear in barracks kit lists, AI kit choices or HUD barracks buttons. `production.KITS` is a static table, so it is not affected today.
- **`unlock`** names the research that unlocks the unit or building, matching `scripts/research.lua` `EFFECTS`. For units it is informational only.
- **`strong` and `weak`** hold unit kinds plus `building`, `turret`, `laser-turret`, `hauler` and `wall`.
- **`balance.buildings[name].kind`** matches the `scripts/buildings.lua` registry for Phase 2 buildings. For the new buildings it is a proposal: `laser-turret`, `wall`, `steam-plant`, `accumulator` and `radar`.
- **`supply_cap`** is the command capacity one live building adds: `rts-command-center` 40 and `rts-hub` 10 (PHASE4 section 1, added at the lead's request). `scripts/supply.lua` should read it instead of its hard-coded 40 and `HUB_CAP`. Today it reads the older field name `supply_provided` and falls back to 40, so nothing breaks in the meantime. Research bonuses stay in `scripts/research.lua`.
- **Entries for other agents' prototypes** carry only what this table is the source of.
  - `units["rts-hauler"]` = `{kind = "hauler", role = "hauler", supply = 0, kit = "rts-hauler-kit", made_by = "factory"}`, so supply never charges for haulers. It has no combat numbers.
  - The logistics agent sets the raid mask on `rts-hub` and `rts-hauler`. Its `logistics.init` logs `trigger target masks rts-hub=[common rts-raid-target] rts-hauler=[common rts-raid-target]`.
  - `buildings["rts-hub"]` = `{kind = "hub", supply_cap = 10}`. Its cost and health stay in `prototypes/logistics.lua`.
  - The commander's supply is 0.
- **Consumers that loop over `balance.units`** must expect partial entries, such as the hauler, which has no `ammo_category` or `health`.
- **The prototypes read costs, times, health and the combat numbers from this table.** Change a value here and restart.
  - Exceptions: leg speeds, the Space Age heavy's acid range of 10, the artillery's projectile speed and the strafe settings live in `prototypes/units.lua`.
  - Leg speeds are tuned per variant against the measured walker. Speed is not linear in leg speed: the Space Age raider needed leg speed 1.8 for ×1.29.

## Validation

| Check | Result |
|---|---|
| `--check-unused-prototype-data --create`, Space Age (`build/p4-content-check.log`) | 0 warnings, 0 errors. This included the other agents' `logistics.lua` and `research.lua` as they were at the final run. |
| The same check, base only (`build/p4-content-nosa-check.log`) | 0 warnings, 0 errors |
| `tools/headless-run.sh 60 '\[rts' build/p4-content` (real control) | 0 errors, 277 `[rts]` lines. The AI autotest built a base, and both barracks spawned walkers. |
| The same run, base only (`build/p4-content-nosa`) | 0 errors, 277 `[rts]` lines |
| Probe, Space Age (`build/p4-probe/`, `build/p4-probe-out.txt`) | 0 errors. Results below. |
| Probe, base only (`build/p4-probe-nosa/`, `build/p4-probe-nosa-out.txt`) | 0 errors. Results below. |
| GUI translation probe, en and ru (`build/p4-gui/`, `build/p4-gui-en.log`, `build/p4-gui-ru.log`) | 14 of 14 keys translated in both languages. The keys covered every section of `content.cfg` plus two existing keys. 0 script errors. |
| GUI screenshot (`build/shots-p4-content/`) | The new units for two forces in red and blue, the drone in its neutral tint, and the five buildings |

The probe replaces `control.lua` in a throwaway copy. It builds independent arenas on a lab-tile surface and logs every damage event with the cause, amount and distance. Its source is the copy's `control.lua`. Results, the same in both variants unless noted:

**Speeds**

| Unit | Space Age | Base only |
|---|---|---|
| walker | 11.1 tiles/s | 11.6 tiles/s |
| drone | 16.6 tiles/s (×1.50) | 16.6 tiles/s (×1.43) |
| raider | ×1.29 | ×1.37 |
| artillery | ×0.60 | ×0.63 |
| commander | ×1.22 of the spidertron | ×1.20 of the spidertron |

**Fights**

- Every new unit fought a copy of itself from another force 20 tiles away, under attack orders.
  - Drone: 10 per bite.
  - Raider: 8 per shot.
  - Artillery: 100 per shell. Both artillery units died within 10 s.
  - Mk2 walker: 25 per shot. Base-only Mk2 heavy: 75 per shot.
  - Commander: 40 per rocket. Both commanders died after about 24 s.
- **Artillery minimum range.** An enemy walker was placed 5 tiles away. The artillery backed off 26–34 tiles and fired its first shell from 12.1 tiles (Space Age) or 11.6 tiles (base only). It never fired below 8. An own wall next to the target kept 500 of 500 health: there is no friendly fire.
- **Artillery against a turret.** From 33–36 tiles it killed an `rts-turret` with 12 shells in about 44 s and took no damage.
- **Raider against buildings.** It did 24 per shot (8 + 16) to the extractor, smelter and medium pole. It did 8 to a walker, a turret and a wall.
  - One raider destroyed the pole (100 health) in 8 s in Space Age and 2 s in base only. It destroyed the smelter (600 health) in 19.5 s and 12.5 s.
  - It fires in bursts while strafing, so the extractor (500) still had 20 health (Space Age) or 236 health (base only) after 60 s.
- **Laser turret.** 30 per shot every 40 ticks; it killed a walker in 7 shots.
- **Ammo damage modifiers scale unit attacks.** A force with +50 % on the role categories hit for 30 (walker), 15 (drone), 12 (raider, ×1.5 of 8) and 150 (artillery). The Space Age heavy's acid scaled to 3.0. Its leg stomp (43.75 impact) did not scale.
- **Drones against walkers.** In Space Age, one drone beat one walker, and two drones beat one walker. In base only the walker won both fights: its hitscan kills each drone in 3 shots while the drones close in. See open items.
- **Walls.** Drones stop at a 3-thick wall line and chew through it. Walkers stepped over it in every Space Age run, and in 3 of 4 base-only runs.

**Economy and recipes**

- 10 iron made 5 steel and 10 stone made 5 bricks in the smelter.
- The factory made 3 gears, 6 cables, 3 circuits and 3 explosives from 3 crafts' worth of input.
- The barracks made 2 drone kits from 12 iron.
- The steam plant burnt 22 coal in 50 s under a 3 MW load, which is 1.76 MW.
- The recipe-enabled flags on a new force match the Costs table.
- `units.spawn` kinds: drone→drone, raider→raider, artillery→artillery, walker-mk2→walker, heavy-mk2→heavy.

## Gotchas

1. **A `direct` trigger ignores `trigger_target_mask`.** The base-only raider's first bonus was a second `direct` trigger item, and walkers and turrets took it too. An `area` trigger honours the mask: the hitscan raider uses a nested `area` with radius 0.5, and the projectile raider an `area` with radius 1.
2. **Spider legs pass their damage on to the torso, after the leg's own resistances.**
   - A 4-tile shell hit a base-game mech unit once per leg in range: 3 hits of 100.
   - A drone biting a strafer leg did 7.2 instead of 10, because of the strafer leg's physical resistance.
   - Pentapod projectiles mostly land on a leg, so pentapod legs must take explosion damage. Making them immune stopped raider-on-raider damage completely (0.0 per hit).
   - Fix: mech legs ignore only explosions; pentapod legs have no resistances.
3. **Stompers deal leg-stomp damage while attacking.** The medium stomper does 87.5 impact. The artillery copy crushed its 5-tile target with its feet while backing away, so it has no stomp. The heavy keeps its stomp, and research ammo modifiers do not scale it.
4. **Vision under range.** With the default vision of 30, the artillery would never auto-acquire a target at range 40.
5. **Units on `stop` do not approach.** Two ranged units 20 tiles apart under `stop` never fired. Under attack orders they fight. The AI and orders code issue attack commands, so this only matters for tests.
6. **Space Age strafers rarely hit another strafer in a 1-v-1.** Two walkers circling at 18–20 tiles exchanged 5 hits in the first 10 s and none in the next 20. They fire rarely while strafing. Faster projectiles (0.5) and target leading did not help (`build/p4-duel/`). This is pre-existing walker behaviour and was left unchanged. Base-only hitscan never misses.
7. **The vanilla stone wall's resistances.** Explosion 10 / 30 %, physical 3 / 20 % and acid 80 % made it nearly immune to raiders, walkers and the heavy's acid. `rts-wall` has none.
8. **`set_recipe` accepts a disabled recipe**, as covered under Costs.
9. **Runtime fields that do not exist.** `LuaEntityPrototype` has no radar sector fields, and a burner generator has no `energy_generated_last_tick` (it raises). The steam plant was measured by the coal it burnt.
10. **The freeplay cutscene blocks `player.teleport` in a GUI test.** `take_screenshot` needs `surface =`.

## Open items for other agents

- **scripts/buildings.lua (`KIND_BY_NAME`).** The new buildings are not registered: `rts-laser-turret`, `rts-wall`, `rts-steam-plant`, `rts-accumulator` and `rts-radar` work as entities but are invisible to the registry, the HUD and the results. `balance.buildings[*].kind` has proposed kinds. Registering every wall segment costs an `on_object_destroyed` registration each.
- **HUD.**
  - The `[rts]` locale needs `kind-drone`, `kind-raider`, `kind-artillery` and `kind-commander`; today `hud.lua` shows the raw kind.
  - `BUILD_ITEMS` needs the five new buildings.
  - The barracks recipe grid lists every recipe in the category, including the disabled mk2 kits.
- **Research: resolved.** `research.mk2_of` now maps through `balance.units[mk2].base`, so `rts-walker-heavy` upgrades to `rts-heavy-mk2` (working tree of `scripts/research.lua`).
- **Commit state.** Commit e9d1d67 ("Phase 4 logistics") already contains this agent's `data.lua` requires, the `production.lua` kit entries and `content.cfg`. `balance.lua`, `prototypes/intermediates.lua` and the prototype changes are not committed yet, so HEAD alone fails at the data stage until they are.
- **Logistics: resolved.** The hub and hauler carry the raid mask (see the balance API section).
- **Abilities and commander.** Spawn with `surface.create_entity{name = "rts-commander", force = ...}`. Set `entity.color`. Insert `rts-commander-rocket`; it uses about one per 0.5 s while fighting. Grid power is not decided yet.
- **Balance pass.**
  - Drone against walker differs by variant: Space Age drones win, base-only walkers win.
  - The Space Age strafer 1-v-1 hit rate is low (gotcha 6).
  - The commander's damage is about 80 per second.
  - Radar radius 2 or 5.
