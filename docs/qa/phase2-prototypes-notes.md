# Phase 2 data-stage prototypes: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE2.md` ("Economic model", "Data stage additions"). Barracks pattern: spike #4 (`docs/research/spikes.md` decision 7).

## Files

| File | What it defines |
|---|---|
| `prototypes/categories.lua` | Recipe categories `rts-units` and `rts-buildings`. Item group `rts` with the subgroups `rts-economy`, `rts-military`, `rts-units` and `rts-defense`. |
| `prototypes/buildings.lua` | Ten entities: the Command Center composite (3) and seven buildings. All are `table.deepcopy` clones of vanilla with vanilla graphics. |
| `prototypes/items.lua` | Eight building items and two unit kits |
| `prototypes/recipes.lua` | Thirteen recipes, counting the later `rts-stockpile` recipe. It also enables vanilla `steel-plate` from the start. |
| `data.lua` | Requires the four files after `prototypes.units`, in this order: categories, buildings, items, recipes. Items read their name and icon from the entity. |

No other file was touched. The locale file belongs to someone else. Every name and description therefore uses `{"?", {"entity-name.rts-x"}, "English fallback"}`. Once a locale key exists it wins, so adding `entity-name.*`, `entity-description.*`, `item-name.rts-walker-kit`, `item-name.rts-walker-heavy-kit` and `item-group-name.rts` to `locale/en/factorio-rts.cfg` takes over without code changes.

## Entities

Size means the tile footprint. Every building has `map_color` and `enemy_map_color = {0.9, 0.2, 0.15}`, so enemy bases show red on the map. Every building except the core parts mines into the rts item of the same name. `next_upgrade`, `fast_replaceable_group` and `factoriopedia_simulation` are cleared on every clone.

| Entity | Type (vanilla source) | Size | Health | Key stats |
|---|---|---|---|---|
| `rts-command-center` | roboport (`roboport`) | 4×4 | 3000 | Logistics radius 25 and construction radius 40. Buffer 200 MJ, input limit 2 MW, idle 50 kW, recharge minimum 40 MJ. 8 charging stations on a 1.6-tile circle. `is_military_target`. Flags `not-deconstructable` and `not-upgradable`. Space Age `surface_conditions` removed. |
| `rts-core-power` | electric-energy-interface (`hidden-electric-energy-interface`) | point, no collision | immune | Produces 4 MW at `secondary-output`, output limit 4 MW, buffer 4 MJ, no input, usage 0 W. Hidden, not selectable, empty sprite, no item, not minable. |
| `rts-core-pole` | electric-pole (`substation`) | 2×2, no collision | immune | Supply distance 18 (36×36 area), wire reach 30. No sprite (`pictures = nil`). Hidden, not selectable, no item, not minable. |
| `rts-stockpile` | logistic-container (`storage-chest`) | 1×1 | 800 | Logistic mode `storage`, 48 slots |
| `rts-extractor` | mining-drill (`electric-mining-drill`) | 3×3 | 500 | Mining speed 1.0, 90 kW, no modules. The vanilla 3×3 is kept because 2×2 needs new graphics. |
| `rts-smelter` | furnace (`electric-furnace`) | 3×3 | 600 | Crafting speed 2, 180 kW, no modules, category `smelting` |
| `rts-solar-array` | solar-panel (`solar-panel`) | 3×3 | 300 | Produces 400 kW |
| `rts-factory` | assembling-machine (`assembling-machine-2`) | 3×3 | 1000 | Category `{"rts-buildings"}` only. Speed 1, 150 kW, no modules, no fluid boxes. |
| `rts-barracks` | assembling-machine (`assembling-machine-2`) | 3×3 | 1500 | Category `{"rts-units"}` only. Speed 1, 150 kW, no modules, no fluid boxes. `is_military_target`. |
| `rts-turret` | ammo-turret (`gun-turret`) | 2×2 | 1200 | Ammo category `bullet`, range 18. Fires every 36 ticks with `damage_modifier` 5, so a firearm-magazine round does 25 damage (see Turret balance). One ammo slot, automated ammo count 10. `is_military_target`. |

The composite is three entities at the same position. The match script creates all three with `create_entity`. The core power sits inside the core pole's supply area, and so does the CC.

Map colours: the CC and core parts are cyan (0.2, 0.85, 1.0). The stockpile is lavender, the extractor green, the smelter orange-brown, the solar array dark blue, the factory steel blue, the barracks yellow and the turret orange.

## Items

| Item | Places | Stack | Subgroup | Craftable |
|---|---|---|---|---|
| `rts-command-center` | `rts-command-center` | 1 | rts-economy | no (match start only) |
| `rts-stockpile` | `rts-stockpile` | 50 | rts-economy | factory (recipe added 2026-10-15) |
| `rts-extractor` | `rts-extractor` | 50 | rts-economy | factory |
| `rts-smelter` | `rts-smelter` | 50 | rts-economy | factory |
| `rts-solar-array` | `rts-solar-array` | 50 | rts-economy | factory |
| `rts-factory` | `rts-factory` | 10 | rts-economy | factory |
| `rts-barracks` | `rts-barracks` | 10 | rts-military | factory |
| `rts-turret` | `rts-turret` | 50 | rts-defense | factory |
| `rts-walker-kit` | nothing | 10 | rts-units | barracks |
| `rts-walker-heavy-kit` | nothing | 10 | rts-units | barracks |

Building items are deep copies of the vanilla item, so sounds and weight carry over. Their icon is the vanilla icon tinted amber (1, 0.8, 0.55), and the entity uses the same icon. With Space Age, kit icons are the small strafer and small stomper icons. Without it, both kits use the spidertron icon, tinted blue for the walker and orange for the heavy.

## Recipes

All recipes are `enabled = true`, `hide_from_player_crafting = true` and `auto_recycle = false`.

| Recipe | Category | Time | Ingredients | Result |
|---|---|---|---|---|
| `rts-walker-kit` | rts-units | 3 s | 10 iron plate, 2 copper plate | 1 `rts-walker-kit` |
| `rts-walker-heavy-kit` | rts-units | 8 s | 30 iron plate, 10 copper plate, 5 steel plate | 1 `rts-walker-heavy-kit` |
| `rts-stockpile` | rts-buildings | 4 s | 20 iron plate, 5 copper plate | 1 `rts-stockpile` (added 2026-10-15, see the economy notes) |
| `rts-extractor` | rts-buildings | 5 s | 20 iron plate, 5 copper plate | 1 `rts-extractor` |
| `rts-smelter` | rts-buildings | 5 s | 20 iron plate, 10 stone | 1 `rts-smelter` |
| `rts-solar-array` | rts-buildings | 4 s | 15 copper plate, 10 iron plate | 1 `rts-solar-array` |
| `rts-factory` | rts-buildings | 10 s | 60 iron plate, 20 copper plate | 1 `rts-factory` |
| `rts-barracks` | rts-buildings | 10 s | 60 iron plate, 20 copper plate | 1 `rts-barracks` |
| `rts-turret` | rts-buildings | 6 s | 40 iron plate, 10 copper plate | 1 `rts-turret` |
| `rts-belt` | rts-buildings | 2 s | 10 iron plate | 10 vanilla `transport-belt` |
| `rts-inserter` | rts-buildings | 2 s | 10 iron plate, 5 copper plate | 5 vanilla `fast-inserter` |
| `rts-pole` | rts-buildings | 2 s | 5 copper plate, 5 iron plate | 5 vanilla `medium-electric-pole` |
| `rts-ammo` | rts-buildings | 3 s | 10 iron plate | 10 vanilla `firearm-magazine` |

The smelter runs the vanilla `smelting` recipes: iron plate, copper plate, stone brick and steel plate. Vanilla `steel-plate` is disabled until research, so `recipes.lua` sets it to `enabled = true`.

## Reused vanilla entities

- **Belt, inserter and pole are not cloned.** The vanilla `transport-belt`, `fast-inserter` and `medium-electric-pole` entities and items are reused, and the factory recipes produce the vanilla items. This is the simplest option. The vanilla items already place, mine, pipette and blueprint correctly. Bots revive ghosts with them, and the build menu can use them directly as `cursor_ghost`. A second item that places the same entity would compete with the vanilla item for ghosts and mining results.
- **Ammo is the vanilla `firearm-magazine`.** Its category is `bullet`, the same as the turret.
- **Smelting uses the vanilla recipes**, as described above.

## Validation

| Check | Result |
|---|---|
| `--check-unused-prototype-data --create`, Space Age on (`build/p2-proto-check.log`) | 0 warnings, 0 errors |
| The same check, base only (`build/p2-proto-nosa/`, `build/p2-proto-nosa-check.log`) | 0 warnings, 0 errors |
| Checker sensitivity probe: a bogus key added to the CC in a copy | Flagged: `Value ROOT.roboport.rts-command-center.bogus_probe_value was not used.` |
| `tools/headless-run.sh 20 '\[rts' mods` | 0 errors in the create and server stages. 78 `[rts]` lines from the Phase 1 control code. |
| The same run, base only (`build/p2-proto-nosa`) | 0 errors, 89 `[rts]` lines |
| Runtime probe, Space Age on and base only (`build/p2-probe*/`, see below) | All checks pass in both |

The runtime probe is a throwaway copy whose `control.lua` is replaced by a test script. It builds the composite and every building on nauvis and runs 20 s. Results, identical with and without Space Age:

- **Power wiring.** The CC, core power, core pole and every building share one electric network.
- **Solar first.** The solar array gives its full 400 kW and the core covers only the remainder. In one measurement the load was 2.38 MW: the array gave 400 kW, 1.86 MW of extra probe panels gave the rest, and the core gave 118 kW.
- **CC buffer.** It starts at 10 MJ, which is 0.25 × recharge minimum, and charges at 2 MW. It reads 29.5 MJ after 10 s and 49 MJ after 20 s.
- **Barracks.** It produced one heavy walker kit from 30 iron, 10 copper and 5 steel.
- **Factory.** `rts-ammo` produced 10 firearm magazines.
- **Smelter.** It made steel plates from iron plates, which confirms the steel recipe is enabled.
- **Extractor.** It mines about 1 ore/s (9 after 10 s, 19 after 20 s) into a stockpile placed at its drop position.
- **Logistic network.** The CC network sees both stockpiles and their contents. Five robots were registered.
- **Recipe isolation.** `barracks.set_recipe("iron-gear-wheel")` and `factory.set_recipe("rts-walker-kit")` leave the recipe nil.
- **CC protection.** `cc.order_deconstruction(force)` returns false.
- **Core immunity.** 5000 explosion plus 5000 physical damage leaves the core power and core pole at full health.
- **Pole connections.** Medium poles connect to the hidden core pole when created by script within reach, revived from a ghost, or built by robots from a ghost.

## Turret balance (2026-10-15)

**The problem.** The AI agent reported that a turret with firearm magazines needed 20 s or more to kill one walker.

**The cause.** The vanilla turret fires a 5-damage physical round every 6 ticks. In addition, the Space Age walker
prototypes, which are copies of the Gleba pentapods, inherited Gleba's physical resistance:

| Unit | Inherited resistances |
|---|---|
| `rts-walker` (strafer copy) | physical: decrease 2 and 10 %. laser: 50 %. |
| `rts-walker-heavy` (stomper copy) | physical: decrease 2 and 50 %. laser and impact: 80 %. |

A round therefore did 2.7 damage to a walker and 1.5 to a heavy. The base-game walkers have no resistances.

**The change.**

- **Units (`prototypes/units.lua`).** The pentapod copies now set `resistances = nil`, the same as the base-game
  variant. The units' own attacks deal explosion damage (the walker projectile) and acid damage (the heavy stream),
  and neither original resisted those, so unit-vs-unit fights do not change.
- **Turret (`prototypes/buildings.lua`).**

  | Parameter | Value |
  |---|---|
  | `attack_parameters.cooldown` | 36 ticks, instead of 6 |
  | `attack_parameters.damage_modifier` | 5 |
  | Damage per round | 25 |
  | Damage per second | about 42 |
  | 10 magazines (100 rounds) | 60 s of continuous fire |

  Walker health was not changed.

**Measured.** A probe copy in `build/p2-balance/` (Space Age) and `build/p2-balance-nosa/` (base only) replaces
`control.lua` with a test script. It places an `rts-turret` with 10 magazines and a unit 10 tiles away. It does this in
both directions between two hostile forces, A and B, for a walker and for a heavy. A third turret fires at a walker
whose health is reset every tick. Turrets do not target an entity with `destructible = false`, so that cannot be used.
Times are measured from when the unit spawns.

| Case | Before (Space Age) | Before (base only) | After (both variants, both directions) |
|---|---|---|---|
| Turret kills a walker | 7.9 s, 75 rounds = 7.5 magazines | 4.4 s, 4 magazines | **4.7 s** (4.2 s from the first hit), 8 rounds = 0.8 magazines |
| Turret kills a heavy | never: the heavy outlasts all 10 magazines and destroys the turret | never: same | **14.3 s** (13.8 s from the first hit), 24 rounds = 2.4 magazines |
| 10 magazines of continuous fire | 10 s | 10 s | **59.4 s** |
| Turret health after the heavy duel | 0 | 0 | 305–600 of 1200 |

Damage per hit reads 25.0 before and after resistances, and the forces have no bullet damage or speed modifiers (both
0.00).

**Regression runs** on fresh copies with the change: zero errors in all of them.

| Run | Copy | Result |
|---|---|---|
| Legacy Phase 1/2 autotest, Space Age | `build/p2-balance-legacy` | `autotest summary 65/65` |
| Legacy Phase 1/2 autotest, base only | `build/p2-balance-legacy-nosa` | `autotest summary 65/65` |
| AI autotest (1v1 normal small) | `build/p2-balance-ai` | `ai autotest summary 12/12, result=both alive (time)`. Both sides built 2 turrets and kept producing. |

In the legacy copies, `AUTOTEST_MATCH` was set to `size = "legacy", enemy_brain = "waves"`.

**Note.** The walker's range (20) is longer than the turret's (18). Walkers that strafe at 19–20 tiles can outrange
it. The strafe settings aim for 16 ± 2 tiles, so this did not happen in the probe.

## Gotchas

1. **`set_recipe` with a recipe from another category does not raise an error.** It silently leaves the recipe unset. The production module should check `get_recipe()` after setting one.
2. **Furnaces only pick enabled recipes.** Without `steel-plate.enabled = true` the smelter would never make steel, and the heavy kit would be unbuildable.
3. **Overlapping supply areas split a producer between networks.** A pole that is not wired to the core, and whose supply area covers a solar array, takes half of the array's output into its own network. The probe first showed 200 kW for a 400 kW array because of this.
4. **Pole reach is measured centre to centre, and the shorter reach wins.** A 1×1 pole at integer position (6, 6) has its centre at (6.5, 6.5), which is 9.19 tiles from the core pole. That is past the medium pole's 9-tile reach, so it stays unconnected. At (6, -6) it connects. The core pole's 30-tile reach only matters between two core poles.
5. **Core power priority is `secondary-output`.** `solar` and `primary-output` are the same tier, so with `primary-output` the core would share load with the solar arrays. Total capacity is the same either way: 4 MW plus solar.
6. **The CC takes 2 MW from the core while its buffer fills.** That lasts about 95 s after placement. The match script can set the CC's `energy` to a full buffer at match start to avoid this; that write is not tested yet.
7. **The core parts are immune but not self-cleaning.** They have 100 % resistance to every damage type defined at load time, so splash damage on the CC cannot cut its power. When the CC dies, the match script must destroy `rts-core-power` and `rts-core-pole`, or they keep powering the network. They are not selectable, not deconstructable and not blueprintable, so `clone_area` is the only non-script way to copy them.
8. **`charging_offsets` is ignored when `charging_station_count > 0`.** The CC therefore uses `charging_distance = 1.6`, which is how the base personal roboports do it.
9. **Space Age changes vanilla prototypes before our data stage.** `base-data-updates.lua` runs inside Space Age's `data.lua`. Clones therefore inherit `heating_energy` and frozen graphics, which is harmless on Nauvis. They also inherit the roboport pressure condition, which the CC clears, and assembler-2's long crafting category list, which our assemblers override.
10. **The quality mod's recycling generator overwrites by result name.** Without `auto_recycle = false`, the generated `firearm-magazine-recycling` recipe could come from `rts-ammo` instead of the vanilla recipe. The checker does not warn about `auto_recycle`.
11. **The factory hands off vanilla item names.** The production module must expect `transport-belt`, `fast-inserter`, `medium-electric-pole` and `firearm-magazine` from the factory, not `rts-*` names. Kits map to `rts-walker` and `rts-walker-heavy`.
12. **The shared `mods` run id can be locked by another agent's run.** The first validation attempt failed at map creation with "Couldn't acquire exclusive lock". The retry passed once the other run had ended.

## Open items

- **Visuals are not checked in a GUI run.** This covers the invisible core pole's wire attach point, the tinted icons and the RTS tab in the factory recipe picker.
- **Stockpile recipe: done.** It was added on 2026-10-15 (20 iron plate, 5 copper plate, 4 s). See `docs/qa/phase2-economy-notes.md`.
- **The probe copies can be deleted.** `build/p2-probe/` and `build/p2-probe-nosa/` contain the probe `control.lua` and five extra test solar prototypes in `data.lua`. They are not part of the mod.
