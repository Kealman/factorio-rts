# Port to Factorio 2.1 (port21)

Date: 2026-10-23. Engine: Factorio 2.1.23 (build 87750, mac-arm64, Steam), Space Age on unless noted. Agent:
`m3-port21`. Starting point: HEAD d2ac880, whose `mods/` tree equals dad7a40, the tree behind the 2.0.77 numbers in
`docs/qa/phase5-m3-integration-notes.md`. Steam updated the installed game from 2.0.77 to 2.1.23. The 2.0 mod failed at
load ("Incompatible Factorio version (current: 2.1, required: 2.0)"), and the owner chose to port rather than roll
back. The port was developed and measured in `build/port21/` and then applied to `mods/`.

## 1. Verdict

- **The port is small.** 24 files of `mods/factorio-rts` plus `mods/mod-list.json` change, with 73 added and 37 removed
  lines, and `tools/install.sh` changes by one line.
- **Every 2.1 run had 0 Lua errors.** That covers 20 headless runs, a save/load cycle and a 2.0 save loaded into 2.1.
- **The smoke passes from `mods/`:** 65/65 with 0 errors.
- **Acceptance scores match 2.0 on the same seed and tree.** Seed 801 is 82/83 on both versions, and the other seeds
  are in the 2.0 range.
- **No systematic behaviour change.** Trains, fluids, the economy, world generation and performance (60 UPS) behave as
  on 2.0.
- **Runs no longer compare line by line with 2.0.** 2.1 fills the world faster, so same-seed runs diverge from minute
  3 (section 5.1). Baselines from before the port compare only in aggregate; section 7 lists what a 2.1 re-acceptance
  must re-establish.
- **Not verified:** the GUI client and LAN play (section 6).

## 2. Changes

Line numbers are in `mods/factorio-rts` after the port.

| # | File:line | Change | 2.1 reason | Effect without it |
|---|---|---|---|---|
| 1 | `info.json:6`, `:8` | `factorio_version` "2.1", dependency `base >= 2.1` | version gate | "Incompatible Factorio version" |
| 2 | `prototypes/research.lua:65-66`, `prototypes/age2.lua:219-220` | science-pack templates from `data.raw.item` instead of `data.raw.tool` | 2.1.7: science packs are plain items; labs and technologies accept any item (`science_capacity` defaults to 1, the old durability) | load error (the assert on the nil template) |
| 3 | `prototypes/recipes.lua:26`, `research.lua:84`, `age2.lua:121`, `age2.lua:161`, `people.lua:259`, `war.lua:53`, `war3.lua:55`, `logistics.lua:236`, `cities.lua:58`, `rails.lua:167`, `age3.lua:42`, `intermediates.lua:35`, `air.lua:315` | `category = X` becomes `categories = {X}` in all 13 recipe constructors, which generate every RTS recipe | 2.1.7: `RecipePrototype::category` and `additional_categories` were removed | silent: the unknown key is ignored and every recipe defaults to `{"crafting"}`, which no RTS machine crafts |
| 4 | `prototypes/age3.lua:94` | the fuel rod's `fuel_category` becomes `fuel_categories = {"nuclear"}` | 2.1.20 | silent: the rod has no fuel category and the nuclear plant cannot burn it |
| 5 | `prototypes/age2.lua:97` | `clean_machine` sets `use_mirroring = nil` instead of `forced_symmetry = nil` | 2.1.7: `forced_symmetry` removed; vanilla chemical plant and refinery now set `use_mirroring = true` | district machines keep mirroring while their flipped graphics are stripped |
| 6 | `scripts/util.lua:91-106` | helpers `util.recipe_category(r)` (first category) and `util.recipe_in(r, set)` (any category in a set) | 2.1.7: `LuaRecipePrototype::category` read removed | none on its own; item 7 uses them |
| 7 | `scripts/hud.lua:193-195`, `:596`, `:621`; `debug.lua:421-422`; `itempicker.lua:61`; `age3.lua:129`; `production.lua:634`; `market.lua:153` | recipe category reads go through the helpers | same | runtime error in HUD, production, market and item picker |
| 8 | `scripts/hud.lua:2859` | `defines.inventory.assembling_machine_output` becomes `crafter_output` | 2.1.7: the machine-specific inventory defines were removed | runtime error (nil define) |
| 9 | `scripts/districts.lua:263` | pumpjack drain `remove_fluid{...}` becomes `extract_fluid{...}` | 2.1.7: renamed; the new `remove_fluid(amount, index)` takes other arguments | runtime error on the first crude drain |
| 10 | `scripts/market.lua:507`, `mapgen.lua:805`, `:816` | `entity.minable = false` becomes `minable_flag = false` | 2.1.7: `LuaEntity::minable` write removed | runtime error at world-port and ruin creation |
| 11 | `scripts/market.lua:202` | price derivation reads `independent_probability` and falls back to `probability` | 2.1.7: product `probability` became `independent_probability` | silent: probabilistic vanilla products such as uranium are priced as if they always drop |
| 12 | `scripts/camera.lua:37` | `show_pins_gui` added to the hidden chrome | new 2.1 pins panel (`GameViewSettings::show_pins_gui`) | GUI: a new vanilla panel shows in the RTS view |
| 13 | `data-updates.lua:27-37` | every `rts-` unit and spider-unit gets the 2.0 map steering: `move {radius 3, separation_force 0.01, separation_factor 3}`, `stay {1.2, 0.005, 1.2}` | 2.1.7: `MapSettings::steering` removed, steering moved onto the unit prototypes | behaviour: our units inherit pentapod or biter steering, with about 20x the 2.0 separation push when standing (section 5.2) |
| 14 | `mods/mod-list.json` | adds `recycler` (enabled) | 2.1.7: Space Age and Quality depend on the new built-in recycler mod | Factorio refuses to load quality and space-age (tested: "Missing required dependency recycler >= 2.1.0") |
| 15 | `tools/install.sh:18` | `recycler` added to the keep list | the same | the install disables recycler in the user's mods folder, so the game loses Space Age |

Items 1-4, 14 and 15 were required to load the mod or to make it work at all. Items 7-10 are runtime errors on the
first use of each code path. Items 5, 11, 12 and 13 preserve 2.0 behaviour.

**Not committed here.** The base-only mod lists in `tools/autotest-run.sh` and `tools/perf-bench.sh` should disable
`recycler` explicitly. Those files carry m3-integ's uncommitted guard edits, so the hunk went to m3-integ to fold into
their commit.

### Items from the cross-reference that needed no change

| Item | Finding |
|---|---|
| `LuaGameScript::create_profiler` (28 hits) | every call already uses `helpers.create_profiler` |
| `LuaEntity::active` write | the code already uses `disabled_by_script` (`garrison.lua`, `buildings.lua`); the `.active` hits are Lua tables |
| `LuaItemPrototype::inventory_size` (17 hits) | no runtime read; the hits are data-stage container sizes |
| `max_power_output` (4 hits) | runtime already calls `get_max_power_output`; the data-stage generator property still exists |
| `VehiclePrototype::braking_power` / `friction` | not set anywhere; the "friction" hits are in diplomacy |
| `loot` | the only use is `p.loot = nil` |
| `probability` (4 hits) | three are autoplace `probability_expression`, which is still valid; the runtime read is item 11 |
| furnace and assembler inventory defines | only item 8; all 103 distinct `defines.*` the mod uses exist in 2.1 (checked against `runtime-api.json`) |
| `set_fluid`, `LuaEntity::fluidbox` | not used |
| custom input key names (32 inputs) | all in the 2.1 key list: letters, digits, F-keys, SPACE, DELETE, BACKSPACE, mouse-button-1/2 and CONTROL/COMMAND/SHIFT modifiers |
| `MapSettings::steering` | the mod never set it; handled per prototype instead (item 13) |
| `defines.default_icon_size` | not used |

## 3. Static checks

- **Data stage.** I dumped `data.raw` with 2.1 (`factorio --dump-data`) and linted every `rts-` prototype and all 32
  GUI styles against `doc-html/prototype-api.json`, including nested non-graphics types. No key is unknown to 2.1.
  This matters because 2.1 ignores stale 2.0 keys silently, which is how items 3 and 4 would have hidden. A planted
  test file with `category`, `fuel_category`, `braking_power` and loot `probability` was caught.
- **Sprite and sound paths.** All 1,324 sprite and sound paths of the RTS prototypes exist in the 2.1 data. Five
  `.bnvib` console haptics files are missing, but vanilla references them too. This needs a real check because
  headless servers never load graphics.
- **Runtime names.** These all exist in 2.1: 103 defines, the 24 input actions blocked by `camera.lua`, the 13 hidden
  GameViewSettings fields and the `show-train-station-names` map view setting. No renamed vanilla prototype name
  appears in the mod's string literals (749 checked).

## 4. Runs

All runs are headless on 2.1.23 with 0 Lua errors. The run copies of `tools/autotest-run.sh` and
`tools/saveload-check.sh` had the 2.0 version guard removed and wrote everything under `build/port21/`. "H" is
`git archive HEAD` plus the port, which is byte-identical to the committed `mods/`. "No steering" means the port
without item 13.

| Run | Tree | 2.1 result | 2.0 reference |
|---|---|---|---|
| Legacy smoke (1v1 small, waves), from `mods/` after applying | mods/ | **65/65** | 65/65 |
| Legacy smoke | H | 65/65 | 65/65 |
| The same with `VARIANT=base` (no Space Age, quality or recycler) | working-tree copy | 65/65 | 65/65 (matrix `nosa`) |
| Nation smoke (1v1, 2048, ai, 8 min) | working-tree copy, no steering | 53/53 | none at 8 min |
| Nation smoke | H | 52/53; the failure is `techs_6min_rts-player`, which failed 82 of 1,014 times in 2.0 logs | none at 8 min |
| M3 acceptance seed 801 (`m3_acceptance.lua`, 4 normal AIs, 60 min, speed 8) | H, no steering | 81/83 | 82/83 (`m3i-f2-801`) |
| M3 acceptance seed 801 | H | **82/83** | 82/83 |
| M3 acceptance seed 802 | H, no steering | 81/83 | 77/83 (`m3i-f2-802`) |
| M1 acceptance seed 501 (`m1_acceptance.lua`, 1v1, 60 min, speed 6) | H, no steering | 50/53 | 52/52 (`m3i-f2-m1`; the match ended at 59:18) |
| M1 acceptance seed 501 | H | **51/53** | 52/52 |
| Save at minute 20, load, play to minute 61 (seed 802, 4 nations) | H | 0 errors in both halves | 0 errors |
| 2.0 save (`m3i-f2-sl20`, minute 61, seed 802, 4 nations) loaded into 2.1 with the ported mod | 2.0 test copy plus port | engine migrations applied, mod init re-ran, 14.4 game minutes played with trains, wars and captures; 0 errors | n/a |
| Age III fixture (`age3_fixture.lua` of the 2.0 run) | H, no steering | 35/35 | 35/35 |
| War fixture (`war_autotest.lua`, seed 501) | H | 27/27 | 27/27 |
| Collateral lanes fixture (`m3_integ.lua`, seed 501) | H | 6/6 | 6/6 |
| Rail detour fixture (`m3_detour.lua`) | H | rails 8/8, detour 2/2 | 8/8, 2/2 |
| Steering probe, A/B (section 5.2) | working-tree copy both ways | section 5.2 | n/a |

### Same seed and tree, 2.0 against 2.1

Each cell reads 2.0 / 2.1. For seed 801 the 2.1 values come from the final tree; for 802 and 501 they come from the
run without item 13.

| Metric | Seed 801 | Seed 802 | Seed 501 (M1) |
|---|---|---|---|
| AI autotest | 82/83 / 82/83 | 77/83 / 81/83 | 52/52 / 51/53 (final tree) |
| Lowest trade (cr) | 4,228 / 5,555 | 5,753 / 5,607 | n/a |
| Wars / back to peace | 4/3 / 3/2 | 2/2 / 2/1 | 2.1: 2 wars, 1 peace |
| Cities changed hands | 8 / 3 | 3 / 3 | n/a |
| Starving or debt | none / none | none / none | n/a |
| First Age III | 44:21 / 41:52 | 33:03 / 42:34 | n/a |
| 3 cities linked by 35:00 | 3 of 4 / 3 of 4 | 2 of 4 / 4 of 4 | n/a |
| First lines open | 24:28-32:57 / 23:31-31:27 | 26:20-34:20, one none / 26:30-29:34 | 21:49, 30:01 / 28:35, 27:51 |
| Items by train | 32,415 / 25,914 | 19,253 / 27,625 | 19,285 / 19,397 |
| Armoured car checks passed | 4 of 4 / 4 of 4 | 2 of 4 / 4 of 4 | 2 of 2 / 2 of 2 |
| Speed-1 minutes (s) | 60.0 / 60.0 | 60.0 / 60.0 | 60.0 / 60.0 |
| Run time at speed 8 or 6 (s) | 726 / 724 | 784 / 783 | 827 / 918 (2.1 ran to minute 60, 2.0 ended at 59:18) |

**Armoured car checks.** Without item 13, the rts-player missed its car on seeds 801 and 501. Across the three seeds
both versions still pass 8 of 10 car checks, and with the final tree the player's car came at 42:00 on 501 and in time
on 801.

**Age II and research.** Industrialisation and Age II times move in both directions by seed. The rts-ai-1 Age II check
on seed 501 fails at 20:16 against 19:15 on 2.0, and on seed 802 several nations were earlier on 2.1.

## 5. Behaviour differences

### 5.1 World generation and determinism across versions

The same seed produces the same world. For seeds 801 and 802, every structural world check matches 2.0 line for line:
connectivity 36/36 and 110/110 on real tiles, start kit, spawn spread, specialty paths, scarce fairness, chokes, ports,
sites, region names, and core chunks with features placed. Only end-of-match ownership checks differ.

The fill is faster. The 2048 world's background chunk generation finishes in 54 s of game time on 2.1, against 84 s on
2.0. City-states and other features therefore appear at different ticks, the AIs plan in a different order, and the
runs diverge from minute 3. The minute-1 and minute-2 AI reports are line-identical.

### 5.2 Unit steering

In 2.0 every unit used the map steering. The 2.0.77 `data.raw` dump in `build/runs/integ-data-sa` gives standing
radius 1.2 with force 0.005, and moving radius 3 with force 0.01. In 2.1 the units inherit vanilla steering instead:
walkers and heavies stand at radius 3.6 with force 0.1, raiders and artillery at 4.8 with force 0.1 (the size rescale
also scales the radius), and drones, cars and planes at move radius 2 and stay radius 3.5.

The probe (`build/port21/probes/steering_probe.lua`) placed 24 walkers of a ceasefire force on a tight grid, left them
10 s, then sent them to one point:

| Steering | After 10 s idle (mean radius / min pair, tiles) | 20 s after the move (mean radius / min pair, tiles) |
|---|---|---|
| 2.1 inherited | 7.87 / 1.22 | 7.94 / 1.75 |
| 2.0 restored (item 13) | 7.32 / 1.11 | 6.05 / 0.33 |

- **Arrival spacing.** With the 2.1 values, blobs arriving at a point stay spread out; with the 2.0 values they bunch
  as before.
- **Hold drift.** The smoke's `hold_kept` drift is 2.03 tiles with the 2.1 values and 1.30 with the 2.0 values,
  against 1.13 and 2.51 in two 2.0 runs.
- **Group command failures.** 0-3 per run on 2.1, against 0-64 per seed on 2.0, so no regression.

The restore is a judgment call: delete the block at `data-updates.lua:27-37` to take the 2.1 vanilla spacing instead.

### 5.3 Trains, fluids, combat, performance

- **Trains.** The detour fixture's timings are identical to 2.0: delivery 54 s after departure, `no_path` 1.0 s after
  the cut, repair 14.0 s, deliveries resumed 25.0 s later, and a bill of 535 rails at 0.0 %. In the seeded runs every
  nation opened a line, and items moved by train are in the 2.0 range.
- **Fluids, nuclear power and kits.** Pumpjack draining works through `extract_fluid`: oil towns fill the network to
  the 3,000 crude cap, as on 2.0. The Age III fixture's nuclear plant output (40.28 MW), fuel rod output (2 in 25 s),
  automation kit job cut (0.490) and rare-deposit numbers are identical to 2.0.
- **Combat and capture timings shift by about a second.** In the war fixture, subdue takes 13.3 s (2.0: 11.1 s) and
  garrison entry 5.9 s (2.0: 4.9 s). In the collateral fixture, 18 collateral hits are undone (2.0: 15).
- **Performance is unchanged.** The game holds 60 UPS at speed 1 in the last five minutes of every acceptance run, and
  wall time at speed 8 is unchanged.
- **Vanilla technology count.** The research init disables 277 vanilla technologies instead of 275 (2.1 added two).

## 6. Open risks

1. **GUI client, not run.**
   - 2.1.7 removed "the extra CustomInputEvent for inputs that collide with the map-drag control". `rts-lclick` and
     `rts-rclick` sit on mouse buttons 1 and 2, so box select, click select and right-click orders need a GUI pass,
     including during a camera drag.
   - `LuaPlayer::teleport` no longer exits remote view. `camera.lua` switches to the god controller before it
     teleports, so this should be fine, but the join flow, match restart and lobby return need a look.
   - The new `toggle_menu_leaves_remote_view` player setting may change how Escape interacts with the remote-view guard
     (F10 opens the RTS menu).
   - New vanilla UI may appear: the alerts side button and the Factoriopedia pin. The pins panel is already hidden
     (item 12).
   - RTS buildings deep-copy vanilla sprites, and 2.1 ships new assembling-machine and oil-refinery graphics. The
     factory, district and refinery look will change. Paths resolve, but the visual fit and the sprites rescaled by
     `age2.rescale` need eyes on them.
2. **Pathfinding.** Three seeds plus fixtures show no regression, but this is not a statistical sample.
3. **Train stop renames.** In 2.1, renaming the last stop with a name no longer rewrites schedules. `rails.lua:2977`
   renames depot stops on capture, but the code also puts the line's trains in manual mode (`rails.lua:3010`) and
   rebuilds schedules by script. A capture while trains are en route was not tested on purpose.
4. **Fluid system rewrite.** 2.1 adds fluid segments and changes the default `fluidbox_multiplier` to 3. Only the
   pumpjack drain uses fluids; the crude rate per pumpjack was not measured directly.
5. **Not run:** LAN multiplayer (`tools/lan-check.sh`), heavy mode, the perf scene, and determinism on 2.1 (two runs of
   one seed).
6. **No way back to 2.0.** With `factorio_version` set to "2.1", the mod no longer loads on 2.0.

## 7. Baselines that a 2.1 re-acceptance must re-establish

1. **Determinism (measured on 2.0.77 only).** None of these were re-run on 2.1. Re-run them with
   `tools/determinism-compare.sh` and `tools/saveload-check.sh`.
   - Seeds 801/802, 30 minutes: 214/209 event lines, 0 differing (`phase5-m3-integration-notes.md`).
   - M1 seed 501 at SPEED 6 against SPEED 10: 56,137 and 66,906 `[rts]` lines, 0 differing.
   - Seeds 701/702: identical (`phase5-perf-notes.md`).
   - Save/load equivalence: 42 state checksums with 6,236 lines, and 47 checksums with 12,429 lines (perf notes
     section 4.3).
   - The cities save/load checksums (`phase5-cities-notes.md`).
2. **Skirmish identity.** Every claim compares two 2.0 runs, so the stored reference logs cannot be reused on 2.1.
   - The seed 777 matrix, 10 scenarios, 0 differing against m2-ready (m2 and m3 integration notes); 6 scenarios
     byte-identical (perf notes); 4,518 lines against aaf8764/aaa8061 (`phase5-ai3-notes.md`).
   - The SEED 9090 smoke and 1v1 baselines (world, world3 and treasury notes); SEED 11 (economy); seed 4242 (age3); the
     paired runs of the people notes.
   - Run `tools/autotest-matrix.sh` (seed 777) and the SEED 9090 smoke and 1v1 once on the ported HEAD, and record them
     as the new reference. `tools/determinism-compare.sh` still works, because it runs both trees fresh on the same
     engine.
3. **World identity.** It holds for seeds 801 and 802 (section 5.1). The world3 notes' "2048 identical for the M1/M2
   acceptances" (20 seeds x 4 nations) still needs a re-run of the world3 seed matrix, and its world-fill times
   (4096 x 6 in 375-379 s of game time) need new values.
4. **Performance (measured on 2.0).**
   - The perf scene: 1.369 ms per tick mean, p99 5.282 ms, UPS capacity 731; AI 0.063 ms per nation; M2 0.025 and M3
     0.013 ms/tick; 17 commander ticks over 3 ms (m3 integration notes).
   - The budget scene: 1.80 ms per tick mean, p99 6.5 ms (perf notes).
   - Heavy mode and LAN: 0 desyncs.
   - The division pathfinder budgets (`unit_budget` 100, `group_budget` 4, `group_inflight` 2), tuned on 2.0 pathFinder
     costs of 5-21 ms (`phase5-divisions-notes.md`). Re-bench with `tools/divisions-bench.sh`, since steering changed
     and pathing may have.
   - Air: 60 planes cost +0.026 ms/tick. The war2 per-module costs.
5. **Seed outcome tables.** The per-seed AI outcomes for 801-805, 701-705 and 501 (Age III by 40:00 in 2 of 5, a debt
   stage in 1 of 5, linked by 35:00 in 10 of 20, starving, items by train) diverge from minute 3 on 2.1. They must be
   re-measured as distributions; they are the acceptance criteria themselves.
6. **Engine-behaviour thresholds tuned on 2.0.**
   - The smoke's `hold_kept` limit ("spider-units coast up to ~3" tiles), `move_spread` and the formation spacing, now
     under per-prototype steering.
   - The balance notes' fight reps, which rely on the game being deterministic (re-run `tools/balance-sim` if the
     tables are reused).
   - The mapgen gotcha that `create_random_generator` ignores the low seed bits (harmless with `mix_seed`, but
     unverified on 2.1).
   - The install's real-config load checksums (m1-ready 3969627748, m2-ready 2375539681), which will change.
   - `docs/research/api-capabilities-2.0.77.md`, which describes 2.0.
7. **GUI protocol coordinates.** `phase5-m3-protocol.md` assumes the 2.0 layout at UI scale 0.75. 2.1 adds side
   buttons such as alerts and pins, so positions need checking in the first GUI pass.

## 8. Re-acceptance estimate

Runs go two at a time.

| Block | Runs | Time |
|---|---|---|
| M3 seeds 803-805 (801 and 802 done here), M2 seeds 701-705, M1 seed 501 a second time | 9 runs of 13-15 min | about 1 h 15 min |
| Save/load at minutes 20 and 40; determinism on 801 and 802 (2 runs each, 30 min) | 6 runs | about 1 h |
| Perf scene, heavy mode, LAN check, Skirmish matrix as the new reference | about 10 short runs | about 1 h |
| The remaining fixtures (air autotest, demolish, divisions, diplomacy, people, market). Age III, war, collateral and detour are done here. | about 8 short runs | about 30 min |
| GUI: the Codex QA protocol (`phase5-m3-protocol.md`, 30 steps) plus a 2.1 checklist (mouse inputs and camera drag, remote-view join and restart, Escape and F10, new vanilla UI, building sprites) | 1 GUI session plus fixes | 2-3 h |
| New 2.1 baselines in the notes of section 7 | n/a | 30 min |

The total is about one working day, and most of it is the GUI pass.
