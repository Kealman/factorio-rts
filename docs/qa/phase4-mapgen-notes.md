# Phase 4 map generation: implementation notes

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE4.md` sections 2.4 (depletion) and 5 (map generation), wave A4. Match flow background:
`docs/qa/phase3-matchflow-notes.md`. AI planner limits: `docs/qa/phase3-ai-notes.md`. Haulers:
`docs/qa/phase4-logistics-notes.md`.

## Status

- **Every match gets a generated map.** The lobby has a **Map** choice: "Chokepoints" (the default) or "Open field".
  "Open field" is the flat Phase 3 arena. Both maps get the same ore patches and the ruin. A **Large** size (512×512)
  joins Small and Medium.
- **Chokepoints terrain.** In front of every base there is a **water moat**: 16 tiles across with one 14-tile land gap.
  Water that wide stops every unit, so the gap is the choke. The map also gets 2–3 lakes, 6–10 forests and varied grass,
  and nothing within 60 tiles of a Command Center.
- **The moats replaced cliff walls (lead decision, 2026-10-16).** Cliffs did not channel the army: every unit except
  the drone stepped over them (see "Terrain and units"). There are no cliffs any more.
- **The moats are measured to work.** 10 walkers, 4 heavies and 4 drones attack-moved past a moat. They all arrived,
  through the gap or around the moat's end, with no unit stuck. They took the same time as on Open field when the gap
  is on the way, and 2–4 s more when the target sits behind a moat side.
- **Haulers.** Haulers cross through the gap since the logistics land routes (383e9fa). Before that commit they
  stopped at the water.
- **Ore is finite, with PHASE4 2.4 totals.**
  - Main patches: iron 6k, copper 4k, stone 3k, coal 3k.
  - A natural pair per spawn between the base ring and the moat: iron 8k, copper 4k.
  - Middle patches: iron 12k, copper 8k and coal 6k.
- **A neutral ruin sits in the centre.** A unit standing within 4 tiles of its stockpiles for 10 s captures them, with
  200 steel plates and 50 circuits. The ruin can be taken back.
- **Depletion telemetry.** An `[rts] ore remaining` log line per force every 60 s. A `patch-depleted` alert when a
  patch reaches 0.
- **The AI builds and attacks on the moat layout.** 1v1 small: 14/14, both sides attack twice. 1v3 medium: 24/24.
  Zero errors in every run. See Validation.
- **Commits.** The lead committed the cliff version (add68a1, 29f97e5). The moat version is not committed.

## Files

| File | Status | What it does |
|---|---|---|
| `scripts/mapgen.lua` | new | Planning (patches, moats, naturals, lakes, forests, ruin) under keep-out rules; ground tiles; building; land connectivity check; depletion checks and the `ore remaining` log; ruin capture; alerts; `/rts-mapgen`; the dev overview screenshot |
| `scripts/match.lua` | edited (map-generation parts) | `SIZES.large`, `SIZE_ORDER` with large, `MAPS`, `config.map`. `match.start` plans the map, passes the ground tiles to `create_arena` and builds the map before the CCs. Non-legacy ore comes from mapgen; `CONTESTED_PATCHES` / `place_contested` are gone (replaced by `mapgen.MIDDLE`). `teardown` resets mapgen. `match.label` escapes the AI prefix. |
| `scripts/lobby.lua` | edited | The "Map" drop-down; `pending.map`; the config line shows the map; `/rts-match ... [chokes\|open] [waves]`; a dev-only self-test step `mapgen_overview` at tick 890 |
| `locale/en/mapgen.cfg`, `locale/ru/mapgen.cfg` | new | 14 `[rts]` keys each, same parameters. Own files, so parallel edits of `factorio-rts.cfg` cannot collide. |

`control.lua`, `scripts/ai/*`, `hud.lua`, prototypes, `logistics.lua`, `research.lua` and `supply.lua` are not touched.
`match.init` calls `mapgen.init`, so the module needs no line in `control.lua`.

## How a map is made

`match.start` → `mapgen.plan(spec)` (pure, no surface) → `create_arena(m, mapgen.tile_function(plan))` →
`setup_forces` → `mapgen.build(surface, plan)` → CCs (`place_bases`) → armies.
- The legacy map skips mapgen (`mapgen.reset()`) and keeps the Phase 2 ore.
- The plan is deterministic per arena seed: nauvis seed + match number, scrambled by `mapgen.mix_seed` (gotcha 1).

Planning order. Each step checks its features against everything planned before it.
1. Main patches (the `match.ORE_PATCHES` positions, unchanged).
2. Middle patches (`mapgen.MIDDLE`) and the ruin at (0, 0).
3. Water moats (Chokepoints only).
4. Natural pairs.
5. Hauler corridors.
6. Lakes.
7. Forests.

After building, `mapgen.build` floods the land on a 2-tile grid from the first spawn. It logs whether every CC,
patch, moat gap and the ruin can be reached on land. Every run below reported all of them reachable.

### Geometry per size

| Size | Arena | Spawn circle | Natural pair at | Moat centre at | Moat band | Moat length per side | Lake radius | Forests |
|---|---|---|---|---|---|---|---|---|
| Small | 256×256 | 88 | 50 tiles along the front | 70 | 62–78 | up to 24 | 11–15 | 6 |
| Medium | 384×384 | 152 | 70 | 88 | 80–96 | up to 36 | 13–17 | 8 |
| Large | 512×512 | 216 | 76 | 96 | 88–104 | up to 48 | 14–18 | 10 |

"Front" is the line from the CC to the arena centre. "Side" is perpendicular to it (`match.front`).

### Ore patches

| Kind | Where | Size | Total | Notes |
|---|---|---|---|---|
| Main | `match.ORE_PATCHES` per spawn (iron 17/10, copper 17/−10, stone 28/16, coal 36/16) | 12×12, 8×8, 6×6, 6×6 | iron 6000, copper 4000, stone 3000, coal 3000 | same positions as Phase 3 |
| Natural | a pair 48–84 tiles from its CC, between the base ring and the moat | iron 10×10, copper 8×8 | iron 8000, copper 4000 | first choice: natural_a tiles out, iron 13 tiles to one side, copper 13 to the other |
| Middle | iron (0, −24), copper (0, 24), coal (0, 44) | 14×14, 10×10, 8×8 | 12000, 8000, 6000 | contested |

- **Amounts per tile.** Patches are richer in the middle (weight 1.5 − d², at least 0.35) and add up to the total
  exactly. Main iron has 19–75 ore per tile on 124 tiles; middle coal is the richest, 69–171.
- **Why the small map's natural is closer.** On the small map the spawn circle is 88. A natural 10 tiles wide and a
  16-tile moat do not both fit between the base ring (60) and the centre, so the natural sits 50 tiles out and the moat
  at 70.
- **The natural solver** scores every candidate and keeps the best one that fits:
  - distance along the front: natural_a −20 to +16;
  - sideways shift of the pair: −48 to +48;
  - half-spacing 13 or 9;
  - iron on either side.

  Every candidate must lie 48–84 tiles from its own CC and out of every other base ring (≥ 62 tiles from any other
  spawn, so also outside the AI's `HOSTILE_RADIUS` 45). It must keep 4 tiles from any other patch and 3 from a moat.
  In 1v1 the first choice fits; on crowded maps the pair shifts sideways.
- **The AI finds the naturals by itself** (resource search within 100 tiles).
  - At 360 s its `expand iron2` step targets the natural iron.
  - In 1v1 the belt route back to the CC fails (`no belt route to hub slot X1`), as it did for the middle patch in
    Phase 3, so the expansion is skipped.
  - In 1v3 medium AI 3 planned `iron2` on its own natural (106 belts).
  - Hubs at the natural (wave B1) are the real fix.

### Water moats (Chokepoints)

- **Shape.** Each spawn gets one moat, `choke_a` tiles out along its front and perpendicular to it.
  - The moat is a water band `MOAT_WIDTH` 16 across, split by a `MOAT_GAP` 14-tile land gap on the front line.
  - Each side of the gap reaches up to `moat_len` tiles.
  - The band follows the front's true angle, so the diagonal spawns of 1v2 and 1v3 get diagonal moats.
  - Inside: deepwater, with a water rim and a 2-tile sand shore. The outer corners are rounded (radius 5); this is
    cosmetic and only removes water.
- **Gap width.** Measured on the moat's centre line from the built water: 14.0–14.3 tiles, logged as
  `mapgen: moat gaps`.
- **Planning.** Each side grows from the gap outwards in 4-tile slices, one slice per side per round. A side stops at
  its first slice where a sample point (every 2 tiles) breaks a rule:
  - outside the arena, or within 60 tiles of any CC;
  - within 3 tiles of a patch or 4 of the ruin;
  - within `MOAT_SPACING` 12 tiles of another spawn's moat.
- **Fairness.** Every side is then cut to the shortest side's length. If that is under 8 tiles, no spawn gets a moat.

  | Map | Opponents | Moats |
  |---|---|---|
  | Small | 1 | 24 tiles per side; a 20-tile lane between the two moats holds the ruin and the middle iron and copper |
  | Small | 2, 3 | none: the centre is too crowded |
  | Medium | 1, 2 | 36 per side |
  | Medium | 3 | 16 per side (cut to the shortest) |
  | Large | 1, 3 | 48 per side |
- **Storage.** `storage.mapgen.moats` and `storage.mapgen.gaps` keep the geometry for other modules. Each moat has
  front and side axes, `a`, `len` and `sign`. Each gap has its centre position and measured width.

### Lakes, forests, ground (Chokepoints)

- **Lakes.**
  - Shape: blobs of radius r × (1 + three harmonics), at most 1.3 r; a deepwater core and a 2-tile sand shore.
  - Positions: the angular midpoints between neighbouring spawns, at 0.36–1.05 × the spawn radius from the centre,
    radius shrinking by 2 up to twice, at most 3.
  - With two spawns only the mirror axis is used, so 1v1 lakes are symmetric (2 lakes). With 3–4 spawns, angles beside
    the midpoints are tried too.
  - Keep-out:
    - 60 + 1.3 r + 2 from every CC;
    - 6 from patches, 12 from the ruin, 4 from a moat, 10 from a moat gap, 14 from another lake;
    - 6 from every hauler corridor, 16 for natural corridors. A hauler corridor is a straight line from a CC to its
      naturals, the middle patches or the ruin.
- **Forests.**
  - Random spots outside every base ring (60 + r), with radius 6–11.
  - Keep-out: 3 tiles from patches, lakes and moats; 10 from the ruin and from a gap.
  - Each forest mixes two vanilla tree species (`tree-01` … `tree-09` and the red and brown variants).
  - Density is 34 % at the centre and 12 % at the edge; 165–440 trees per map.
- **Ground.**
  - Value noise on two grids (32 and 11 tiles) picks grass-1, with patches of grass-2, grass-3 and grass-4.
  - `create_arena` sets these tiles in its existing pass. "Open field" stays plain grass-1.

### The ruin

- **What is placed.**
  - An `rts-command-center` of the `neutral` force at (0, 0): not destructible, not minable, not operable, 30 % health.
    Its buffer is filled, so no "no power" icon shows. It has no robots and no core, so it does nothing.
  - Two `rts-stockpile` of the `neutral` force at (−3.5, −1.5) and (3.5, 1.5): 200 steel plates in one, 50 electronic
    circuits in the other. They are not destructible while neutral.
  - A rendered label "Ruin" above it.
  - None of these is in the buildings registry.
- **Capture** (`mapgen.capture_step`, every 30 ticks).
  - Units in range: registered units (the units registry: spider units, haulers, drones) of a match force within 4
    tiles of a ruin stockpile.
  - Progress: when exactly one force other than the owner is there, and no unit of the owner, that force gains progress.
  - Capture: 600 ticks (10 s) of progress capture the stockpiles. `chest.force` becomes that force and the stockpiles
    become destructible.
  - Resets and holds: nobody there resets the progress. Several forces there, or the owner present, hold it.
  - The label shows "Ruin: capture by AI 2, 40%" and then "Ruin (You)".
- **Alerts.**
  - The capturer gets `ruin-captured` with params {steel, circuits}.
  - A previous owner gets `ruin-captured` with the text `rts.alert-ruin-lost`.
- **Using the loot.** The stockpiles are storage chests. They join a logistic network only inside a roboport area of
  the new owner, so a hub has to be built next to them, or the items hauled.

## Terrain and units (measured)

**Barrier probe** (headless, 2026-10-15). Each barrier was 60–100 tiles long, and each unit was ordered straight
across it (`go_to_location`; `autopilot_destination` for the hauler, before the logistics land routes).

| Barrier | Walker | Heavy | Raider | Artillery | Drone | Hauler (straight line) |
|---|---|---|---|---|---|---|
| Cliff line (1 row, 3 tiles thick) | over | over | over | over | **around** | over |
| Cliffs, 2 or 3 rows | over | over | over | over | – | over |
| Huge rocks every 3 tiles, 1 row | over | over | over | over | **stuck** at the row | over |
| Huge rocks, 3 or 5 rows | over | over | over | over | – | over |
| Forest band 11 tiles deep, ~30 % trees | through | through | through | through | through | through |
| Water 2–8 tiles wide | over | over | over | over | around (6, 8) | over |
| Water 10 | around | around | over | over | around | **stuck** |
| Water 12 | around | around | over | over | around | **stuck** |
| Water 14, 16 | around | around | around | around | around | **stuck** |

**Moat pathing** (test-only module `mgpath.lua` appended to the copy). Setup:
- The AI commanders are stopped, with a test-only cease-fire.
- 10 walkers, 4 heavies and 4 drones spawn 36 tiles in front of the player's CC and get `orders.attack_move` to a
  target behind the moat.
- A hauler gets `logistics.move_hauler` to the same target.
- The crossing point is interpolated where each unit's path crosses the moat's centre line.

Arrival times are min/median/max in seconds. "Gap" means the path crossed the moat line inside the 14-tile gap;
"end" means it went around a moat's end.

| Map, target | Walkers | Heavies | Drones | Hauler |
|---|---|---|---|---|
| Small Chokepoints, target (4, 21) behind a moat side | 10/10, 7/8/8, gap 10 | 4/4, 13/14/15, gap 4 | 4/4, 5/5/6, gap 4 | arrived in 5 s |
| Small Chokepoints, target (2, 26) | 10/10, 7/8/9, gap 10 | 4/4, 14/14/15, gap 4 | 4/4, 5/6/6, gap 3, end 1 | arrived in 5 s |
| Medium Chokepoints, target (−42, 39) deep behind a side | 10/10, 9/11/12, end 9, 1 at the end's edge | 4/4, 15/17/20, end 3, 1 at the edge | 4/4, 7/7/9, end 4 | arrived in 7 s |
| Small Open field, target (4, 21) (baseline) | 10/10, 7/8/9 | 4/4, 14/14/14 | 4/4, 5/5/6 | arrived in 4 s |
| Medium Open field, target (−42, 39) (baseline, earlier code) | 10/10, 8/9/10 | 4/4, 14/15/16 | 4/4, 7/7/7 | arrived in 5 s |

- **Nobody is stuck, and no unit crossed a moat mid-span.**
- **Spider units cut the ends.** Walkers and heavies cut the corner of a moat's end by up to about 6 tiles: the legs
  stand on the end face, and the body hangs over water. So for spider units a moat is effectively about 6 tiles
  shorter at each end. Drones keep to land.
- **The hauler rows** are on HEAD 383e9fa, with the logistics land routes. It routed through the gap:
  `route via (-7.5, 0.5)`. On 29f97e5, before those routes, the hauler stopped at the moat's inner edge in every
  Chokepoints run.

Consequences:
- **Chokes are water, not cliffs or rocks.** Rock rows trap drones, and spider units step over cliffs.
- **The gap is the short way through.** Going around the moat's end is the other way.
- **Forests are visual only for movement.** They also block building, but the AI's construction clears trees in a
  footprint first.

## Depletion and alerts

- **Patch records.** `storage.mapgen.patches` keeps every placed patch: id, kind, force (nil for middle), ore name,
  centre, tile box, total, remaining.
- **Depletion check.** Every 600 ticks the resource entities in each box are summed. At 0 the patch gets
  `depleted_tick` and an alert:
  - kind `patch-depleted`, text `rts.alert-patch-depleted`;
  - params {ore name, `rts.patch-kind-<kind>`}, position = the patch centre;
  - sent to the owner, or to every match force for a middle patch.
- **Report.** Every 3600 ticks:

  ```
  [rts] ore remaining rts-player: main iron-ore 5211/6000, main copper-ore 3839/4000, main stone 2765/3000, main coal 3000/3000, natural iron-ore 8000/8000, natural copper-ore 4000/4000
  [rts] ore remaining middle: middle iron-ore 12000/12000, middle copper-ore 8000/8000, middle coal 6000/6000
  ```
- **Alert format.** `mapgen.alert` hands every alert to the shared writer `supply.alert(force, kind, text, params,
  position)`, looked up at call time. That writer appends `{tick, force, kind, text, params, position}` to
  `storage.alerts`, at most 100. The text is also printed to the force.
- **HUD.** The HUD styles both kinds (`patch-depleted` yellow with an ore icon, `ruin-captured` green, ruin-lost as a
  loss since 5d176ad). It shows the newest 3, and F3 jumps to them.
- **Measured pace.** The normal AI mines about 1000 main iron in 6 minutes (6000 → 4924–5241). At that pace the main
  iron lasts about 30 minutes, not the 12 of PHASE4 2.4.

## Lobby, config, console

- **Start dialog.** A fourth row, "Map" ("Карта"): Chokepoints / Open field. The tooltip describes the moat and its
  14-tile gap and says that water stops every unit. Size offers Small / Medium / Large (512×512).
- **Config line** (menu, results): "1 opponent · Normal · Small (256×256) · Chokepoints".
- **`storage.match.config.map`.** "chokes" (default) or "open"; `match.normalize_config` fills it and forces "open"
  on the legacy size. `storage.lobby.pending.map` is filled for older saves.
- **`/rts-match`.** `/rts-match <1-3> <easy|normal|hard> <small|medium|large> [chokes|open] [waves]`
- **`/rts-mapgen`** (QA) prints the terrain counts and the moat gaps, every patch with the ore left, and the ruin's
  owner and capture progress. `mapgen.dump(player?)` is the same from script.
- **Autotest override.** `storage.debug.autotest_match` and the `AUTOTEST_MATCH` line accept `map = "open"`;
  without it a match is "chokes".

## API for other modules

| Function / field | Returns / does |
|---|---|
| `mapgen.patches(force?, kind?)` | The recorded patches: `{id, kind, force, name, center, box, total, tiles, remaining, depleted_tick?}`. `remaining` is refreshed every 10 s. Example: `mapgen.patches("rts-ai-1", "natural")` for an AI hub site. |
| `mapgen.remaining(surface, patch)` | Ore left in a patch now |
| `mapgen.alert(force, kind, text, params, position)` | Through `supply.alert`, and printed to the force |
| `mapgen.capture_step(dt)` | One ruin step (tests) |
| `mapgen.dump(player?)` | `/rts-mapgen` |
| `mapgen.mix_seed(n)` | 32-bit hash for random generator seeds |
| `storage.mapgen.moats` | `{{force, home, front, side, sign, a, len}}`. Water where the distance along front from home is within `MOAT_WIDTH / 2` of `a`, and `MOAT_GAP / 2 ≤ (distance along side) × sign ≤ MOAT_GAP / 2 + len`. |
| `storage.mapgen.gaps` | `{{force, position, width}}`: the land gap of each moat, for rally points and defence |
| `storage.mapgen.ruin` | `{position, cc, chests, owner, capturing, progress, label}` |
| `storage.mapgen.counts` | `{lakes, water_tiles, moats, forests, trees, patches, skipped, chokes, unreachable}` |

For the AI agent (wave B1):
- **Hub sites.** The natural pair is the intended expansion.
- **The ruin.** A unit near a ruin stockpile for 10 s takes 200 steel and 50 circuits.
- **Defending the gap.** `storage.mapgen.gaps[i].position` is the one short way into a base on Chokepoints maps.

## Validation

Every copy is a committed tree plus the map-generation files from `mods/` (`mapgen.lua`, `match.lua`, `lobby.lua`,
both `mapgen.cfg`). Other agents had unfinished edits in `mods/`. Only the `AUTOTEST_MATCH` line differs per copy, or
for the GUI copies `SELFTEST_DEFAULT` (and once the lobby default).

```sh
tools/headless-run.sh 430 '\[rts\]' build/p4-mgmf-ai-1v1s
tools/gui-run.sh build/p4-mgmoat-gui 200 RTS_MATCHFLOW_DONE
```

**Moat version (final code, HEAD 383e9fa plus these files):**

| Run | Map | Result | Errors |
|---|---|---|---|
| `build/p4-mgmf-ai-1v1s`, 430 s | 1v1 small Chokepoints | **14/14**, both alive. Each side launched 2 attacks of 16 units, met the other's group, fought and retreated: the attacks crossed the moats. Moat gaps 14.3; all targets reachable. | 0 |
| `build/p4-mgmf-ai-1v3m`, 430 s | 1v3 medium Chokepoints | **24/24**; every force built by 37 s; lines at 133–178 s; moats 16 per side, gaps 14.0–14.3 | 0 |
| `build/p4-mgmf-path-s`, `-path-s2`, `-path-m`, `-path-open` | pathing, see "Moat pathing" | 18/18 units and the hauler arrived in every run | 0 |
| `build/p4-mgmf-ruin` | ruin and depletion check | **9/9** | 0 |
| `build/p4-mgmf-plan-3s`, `-plan-3l` | plan smoke 1v3 small and large | small: no moats (fairness), 2 lakes; large: 4 moats × 48, gaps 14.0–14.3; all reachable | 0 |
| `build/p4-mgmoat-gui`, GUI self-test | 1v1 small Chokepoints, Russian client | full flow to `RTS_MATCHFLOW_DONE`; overview screenshots | 0 |

An earlier moat run on HEAD 29f97e5 (before the rounded corners) also passed: 1v1 small 14/14 and 1v3 medium 24/24
(`build/p4-mgmoat-1v1s`, `-1v3m`).

**Cliff version (committed as add68a1 / 29f97e5), for the record:**
- 1v1 small 14/14 and 1v3 medium 24/24.
- 1v2 small 19/19 and 1v3 small 24/24.
- The legacy waves autotest 65/65 (`build/p4-mapgen-legacy`).
- The ruin check 6/6, then 9/9.
- Zero errors.

The baseline without mapgen (`build/p4-mapgen-base`) gives the same kits per minute, [2 5 3 2 6 3].

**Ruin and depletion check** (`mgcheck.lua`, a test-only module appended to the copy's `control.lua`). It stops the
AI commanders, puts walkers next to the stockpiles (with a test-only cease-fire, so they stand still) and removes the
player's main stone ore.

| Check | Result |
|---|---|
| `ruin_not_yet`: owner still neutral after 5 s | PASS |
| `ruin_captured`: both stockpiles `rts-player`, destructible, alert with params {200, 50} | PASS |
| `patch_depleted_alert`: `patch-depleted` for `rts-player` at (−60, 16), params {stone, main patch} | PASS |
| `ruin_defended_hold`: an AI walker and a player walker at the stockpiles: no progress | PASS |
| `ruin_recaptured`: the player leaves → AI 1 owns them 10 s later; AI 1 gets `ruin-captured`, the player `rts.alert-ruin-lost` | PASS |
| `label_ai`, `ruin_label_owner`: "AI 1" names (`match.label` fix) | PASS |
| `alert_format`: `{tick, force, kind, text, params, position}` | PASS |
| `dump`: `/rts-mapgen` wrote 17 lines | PASS |

**Screenshots** (`build/shots-p4-mgmoat-gui/`, Russian client):

| File | Shows |
|---|---|
| `rts-p1-900.png` | Tick 900 after the scripted Start: own CC, army, varied grass, the main patches |
| `rts-mapgen-900.png` | The whole 256×256 arena: four moat halves (two per base) with their gaps on the centre line, two lakes on the mirror axis, six forests, the ruin, natural and middle patches |
| `rts-mapgen-900-middle.png` | The middle at zoom 0.35: the moats with deepwater cores, sand shores and rounded outer corners; the 14-tile gaps; the ruin with its label; the middle iron, copper and coal in the lane between the moats |

**Measured.**

| Measure | Value |
|---|---|
| Arena tiles (`create_arena`), Chokepoints / Open, quiet machine | small 95 / 64 ms, medium 218 / 147 ms, large 380 / 268 ms |
| `mapgen.build` (water, forests, patches, ruin, connectivity flood) | small 37–46 ms, medium 94–115 ms, large 158–181 ms |
| Water per map, Chokepoints | small 1v1: 2 moats (4 × 372–384 tiles) + 2 lakes = 2480–2840 tiles; medium 1v1: 3580–3990; large 1v3: 8489 |
| Moat gap on the centre line | 14.0–14.3 tiles |
| Depletion check (every 10 s) | one `find_entities_filtered` per patch: 15 patches in 1v1, 27 in 1v3 |

## Gotchas

1. **`game.create_random_generator(seed)` ignores the lowest seed bits.** Seeds n and n + 1 gave identical maps for
   match 1 and match 2. `mapgen.mix_seed` scrambles the seed first.
2. **Ore looks sparse.** With PHASE4 totals a patch has 19–171 ore per tile, and vanilla ore sprites pick their
   stage from the amount, so patches show the smallest pebbles. A prototype change (resource `stage_counts`) would make
   them look full.
3. **Self-test steps run on a 30-tick cadence.** A step at 915 ran in the same tick as the QA reset at 930. The arena
   was deleted before the screenshot rendered. The overview step is at 890.
4. **Spider-unit bodies can hang over water** next to a shore while the legs stand on land, about 6 tiles out at a
   moat's end. A position check that a unit is "on water" is not proof that it crossed water.
5. **Cliffs (if they come back)** snap to a 4×4 grid at (4i + 2, 4j + 2.5). Their end pieces are about 1.75 tiles
   shorter than a cell.

## Open items for the lead

- **Small maps with 3–4 players have no moats.** The centre is too crowded for fair moats. They still get lakes,
  forests, naturals and the ruin. A smaller moat for small 1v2 and 1v3 would need the middle patches moved.
- **Moats are finite.** Units can walk around a moat's end, and spider units cut each end by about 6 tiles. Longer
  moats channel more, but they are cut to the shortest side for fairness.
- **The small map's natural sits 50 tiles from the CC**, not 60–80, to fit inside the moat.
- **The AI ignores the ruin and the gaps.** B1 could send a unit to the ruin and rally or defend at
  `storage.mapgen.gaps`.
- **The AI cannot expand to a natural with belts** in 1v1: the route fails. B1 needs hubs and haulers there.
- **Alerts appear twice:** in the force's chat and in the HUD alert lines. Drop the chat line in `mapgen.alert` if
  the HUD alone is enough.
- **Main patches last about 30 minutes at the current AI pace**, not 12.
