# Phase 4 map generation: implementation notes

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE4.md` sections 2.4 (depletion) and 5 (map generation), wave A4. Match flow background:
`docs/qa/phase3-matchflow-notes.md`. AI planner limits: `docs/qa/phase3-ai-notes.md`. Haulers:
`docs/qa/phase4-logistics-notes.md`.

## Status

- **Every match now gets a generated map.** The lobby has a new **Map** choice: "Chokepoints" (the default) or "Open
  field". "Open field" is the flat Phase 3 arena. Both maps get the same ore patches and the ruin. A new **Large**
  size (512×512) joins Small and Medium.
- **Chokepoints terrain:** 2–3 lakes, a cliff wall with a 12-tile gap in front of every base, 6–10 forests and
  varied grass. Nothing is placed within 60 tiles of a Command Center.
- **Ore is finite, with PHASE4 2.4 totals.**
  - Main patches: iron 6k, copper 4k, stone 3k, coal 3k.
  - A natural pair per spawn, 58–84 tiles out: iron 8k, copper 4k.
  - Middle patches: iron 12k, copper 8k, and a new coal 6k.
- **A neutral ruin sits in the centre.** A unit standing within 4 tiles of its stockpiles for 10 s captures them, with
  200 steel plates and 50 circuits. The ruin can be taken back.
- **Depletion telemetry.** An `[rts] ore remaining` log line per force every 60 s. A `patch-depleted` alert when a
  patch reaches 0.
- **The AI still builds on every map.**
  - 1v1 small Chokepoints: 14/14.
  - 1v3 medium Chokepoints: 24/24.
  - 1v2 and 1v3 small: all checks pass.
  - The legacy waves autotest: 65/65.
  - Zero errors in every run. See Validation.
- **Cliffs do not stop spider units.** This was measured: walkers, heavies, raiders, artillery and haulers step over
  cliff lines. Cliffs stop drones and building placement. Only water 14 tiles wide or more stops every unit, and
  lakes are that wide. See "Terrain and units" and the open items.
- **Nothing of mine is committed**, except the two locale files: the HUD commit 8e83c78 swept in
  `locale/*/mapgen.cfg`.

## Files

| File | Status | What it does |
|---|---|---|
| `scripts/mapgen.lua` | new | Planning (patches, walls, naturals, lakes, forests, ruin) under keep-out rules; ground tiles; building; depletion checks and the `ore remaining` log; ruin capture; alerts; `/rts-mapgen`; the dev overview screenshot |
| `scripts/match.lua` | edited (map-generation parts) | `SIZES.large`, `SIZE_ORDER` with large, `MAPS`, `config.map`. `match.start` plans the map, passes the ground tiles to `create_arena` and builds the map before the CCs. Non-legacy ore now comes from mapgen; `CONTESTED_PATCHES` / `place_contested` are gone (replaced by `mapgen.MIDDLE`). `teardown` resets mapgen. The match flow is unchanged. |
| `scripts/lobby.lua` | edited | The "Map" drop-down; `pending.map`; the config line shows the map; `/rts-match ... [chokes\|open] [waves]`; a dev-only self-test step `mapgen_overview` at tick 890 |
| `locale/en/mapgen.cfg`, `locale/ru/mapgen.cfg` | new | 14 `[rts]` keys each, same parameters. A separate file, like `content.cfg` and `research.cfg`, so parallel edits cannot collide. |

`control.lua`, `scripts/ai/*`, `hud.lua`, prototypes, `logistics.lua`, `research.lua` and `supply.lua` are not touched.
`match.init` calls `mapgen.init`, so the module needs no line in `control.lua`.

## How a map is made

`match.start` → `mapgen.plan(spec)` (pure, no surface) → `create_arena(m, mapgen.tile_function(plan))` →
`setup_forces` → `mapgen.build(surface, plan)` → CCs (`place_bases`) → armies. The legacy map skips mapgen
(`mapgen.reset()`) and keeps the Phase 2 ore. The plan is deterministic per arena seed: nauvis seed + match number,
scrambled by `mapgen.mix_seed` (see gotcha 1).

Planning order. Each step checks its features against everything planned before it.
1. Main patches (the `match.ORE_PATCHES` positions, unchanged).
2. Middle patches (`mapgen.MIDDLE`) and the ruin at (0, 0).
3. Cliff walls (Chokepoints only).
4. Natural pairs.
5. Hauler corridors.
6. Lakes.
7. Forests.

### Geometry per size

| Size | Arena | Spawn circle | Natural pair at | Cliff wall at | Wall length per side | Lake radius | Forests |
|---|---|---|---|---|---|---|---|
| Small | 256×256 | 88 | 64 tiles along the front | 76 | up to 20 tiles (5 cliffs) | 11–15 | 6 |
| Medium | 384×384 | 152 | 70 | 86 | up to 28 (7) | 13–17 | 8 |
| Large | 512×512 | 216 | 76 | 96 | up to 36 (9) | 14–18 | 10 |

"Front" is the line from the CC to the arena centre (`match.front`).

### Ore patches

| Kind | Where | Size | Total | Notes |
|---|---|---|---|---|
| Main | `match.ORE_PATCHES` per spawn (iron 17/10, copper 17/−10, stone 28/16, coal 36/16) | 12×12, 8×8, 6×6, 6×6 | iron 6000, copper 4000, stone 3000, coal 3000 | same positions as Phase 3 |
| Natural | a pair 58–84 tiles from its CC, across the front line | iron 10×10, copper 8×8 | iron 8000, copper 4000 | first choice: 64/70/76 tiles out, iron 13 tiles to the side axis, copper 13 the other way |
| Middle | iron (0, −24), copper (0, 24), coal (0, 44) | 14×14, 10×10, 8×8 | 12000, 8000, 6000 | contested; the coal is new |

- Amounts per tile are richer in the middle of a patch (weight 1.5 − d², at least 0.35) and add up to the total
  exactly. Main iron gets 19–75 ore per tile on 124 tiles; the richest tiles are middle coal, 69–171.
- **The natural solver** scores every candidate and keeps the best one that fits:
  - distance along the front: natural_a −20 to +16;
  - sideways shift of the pair: −48 to +48;
  - half-spacing 13 or 9;
  - iron on either side.

  Every candidate must lie 58–84 tiles from its own CC and out of every other base ring (≥ 62 tiles from any other
  spawn, so also outside the AI's `HOSTILE_RADIUS` 45). It must also keep 4 tiles from any other patch and 3 from
  cliffs.

  Results:
  - **1v1 and 1v2 medium:** the first choice fits.
  - **Diagonal spawns of 1v3 medium and large:** the pair is mirrored (iron on the other side), clear of their
    west-east walls.
  - **Crowded small maps:** the pair moves sideways. In 1v3 small, AI 1 gets iron (−30, −45) and copper (−15, −36),
    80 and 63 tiles from its CC.
- **The AI finds the naturals by itself.** It searches resources within 100 tiles (`layout.PATCH_SEARCH`).
  - At 360 s its `expand iron2` step targets the nearest free iron patch, which is now the natural iron (log:
    `line iron2 unavailable: no hub slot reachable for iron-ore@-29,10`).
  - In 1v1 the belt route back to the CC is too long for the router (`no belt route to hub slot X1`), so the expansion
    is skipped, as it was for the middle patch in Phase 3.
  - In 1v3 small, AI 3 planned `iron2` on AI 2's natural (113 belts); a natural only belongs to its spawn inside the
    AI's 45-tile radius.
  - Hubs at the natural (wave B1) are the real fix.

### Cliff walls (Chokepoints)

- **Shape.** Each spawn gets two straight cliff runs, one on each side of its front line, `choke_a` tiles out.
  - The run axis is the one nearer to the perpendicular of the front: north-south for spawns on the x axis,
    west-east for the diagonal spawns of 1v2 and 1v3.
  - Only the vanilla straight orientations are used: `none-to-east`, `west-to-east`, `west-to-none` and their
    north-south equivalents. Cliffs sit on the 4×4 cliff grid at (4i + 2, 4j + 2.5).
- **Gap width.** The end pieces are shorter than their grid cells, so the cell gap is 8 tiles.
  - Measured between the cliff collision boxes: 11.5 tiles (north-south) and 12.9 (west-east).
  - Logged as `mapgen: choke widths`; the screenshot shows about 12.5 tiles.
- **Planning.** Cells are added from the gap outwards, one per side per round. A side stops at its first cell that
  comes:
  - within 60 tiles of a CC;
  - within 3 tiles of a patch;
  - within 6 tiles of the ruin;
  - within 12 tiles of another spawn's cliffs.
- **Fairness.** Every side is then cut to the shortest side's length. If any side has room for fewer than 2 cliffs,
  no spawn gets a wall.

  | Map | Opponents | Walls |
  |---|---|---|
  | Small | 1 | full (5 cliffs per side) |
  | Small | 2, 3 | none: the centre is too crowded |
  | Medium, large | 1–3 | full: 7 or 9 cliffs per side |

### Lakes, forests, ground (Chokepoints)

- **Lakes.**
  - Shape: blobs of radius r × (1 + three harmonics), at most 1.3 r; a deepwater core and a 2-tile sand shore.
  - Positions: the angular midpoints between neighbouring spawns, at 0.36–1.05 × the spawn radius from the centre,
    radius shrinking by 2 up to twice, at most 3.
  - With two spawns only the mirror axis is used, so 1v1 lakes are symmetric (2 lakes). With 3–4 spawns, angles
    beside the midpoints are tried too.
  - Keep-out:
    - 60 + 1.3 r + 2 from every CC;
    - 6 from patches, 12 from the ruin, 4 from cliffs, 10 from a choke gap;
    - 14 from another lake;
    - **6 tiles from every hauler corridor**, 16 for natural corridors (the AI's expansion belt may stray from the line).
      A hauler corridor is a straight line from a CC to its naturals, to the middle patches or to the ruin.
- **Forests.** Random spots outside every base ring (60 + r) with radius 6–11. They keep:
  - 3 tiles from patches, lakes and cliffs;
  - 10 from the ruin and from a choke gap.

  Each forest mixes two vanilla tree species (`tree-01` … `tree-09` and the red and brown variants). Density is 34 %
  at the centre and 12 % at the edge; 165–440 trees per map.
- **Ground.**
  - Value noise on two grids (32 and 11 tiles) picks grass-1, with patches of grass-2, grass-3 and grass-4.
  - `create_arena` sets these tiles in its existing pass, so there is no second tile pass.
  - "Open field" stays plain grass-1.

### The ruin

- **What is placed.**
  - An `rts-command-center` of the `neutral` force at (0, 0): not destructible, not minable, not operable, 30 % health.
    Its buffer is filled, so no "no power" icon shows. It has no robots and no core, so it does nothing.
  - Two `rts-stockpile` of the `neutral` force at (−3.5, −1.5) and (3.5, 1.5): 200 steel plates in one, 50 electronic
    circuits in the other. They are not destructible while neutral.
  - A rendered label "Ruin" above it.
  - None of these is in the buildings registry, so nothing counts them as a force's base.
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
  - Both are also printed to the force.
- **Using the loot.** The stockpiles are storage chests. They join a logistic network only inside a roboport area of
  the new owner, so a hub has to be built next to them, or the items hauled.

## Terrain and units (measured)

Headless probe, 2026-10-15. Each barrier was 60–100 tiles long, and each unit was ordered straight across it
(`go_to_location` for spider units and drones, `autopilot_destination` for the hauler). The crossing point says
whether a unit went over or around the barrier.

| Barrier | Walker | Heavy | Raider | Artillery | Drone | Hauler |
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
| Lake 80×24 | around (38 tiles off the line) | – | – | – | – | **stuck** |

Consequences:
- **Walls are cliffs, not rocks.** Rock rows trap drones; cliffs send them around.
- **Lakes (≥ 20 tiles across) stop every unit.** The pathfinder routes around them.
- **A hauler walks a straight line and stops at water 10 tiles wide or more.** It stops at a lake too. Lakes therefore
  stay off the straight lines from each CC to its naturals, to the middle patches and to the ruin. A hub placed
  elsewhere can still have a lake between it and its partner; see the open items.
- **Forests are visual only for movement.** They also block building, but the AI's construction clears trees in a
  footprint first.

## Depletion and alerts

- **Patch records.** `storage.mapgen.patches` keeps every placed patch: id, kind, force (nil for middle), ore name,
  centre, tile box, total, remaining.
- **Depletion check.** Every 600 ticks the resource entities in each box are summed. At 0 the patch gets
  `depleted_tick` and an alert:
  - kind `patch-depleted`, text `rts.alert-patch-depleted`;
  - params {ore name, `rts.patch-kind-<kind>`}, position = the patch centre;
  - sent to the owner, or to every match force for a middle patch;
  - also printed to the force.
- **Report.** Every 3600 ticks:

  ```
  [rts] ore remaining rts-player: main iron-ore 5211/6000, main copper-ore 3839/4000, main stone 2765/3000, main coal 3000/3000, natural iron-ore 8000/8000, natural copper-ore 4000/4000
  [rts] ore remaining middle: middle iron-ore 12000/12000, middle copper-ore 8000/8000, middle coal 6000/6000
  ```
- **Alert format.** Alerts go to the shared `storage.alerts`: `{tick, force, kind, text, params, position}`, newest
  last, at most 100. The supply and logistics modules use the same format.
- **HUD.** The HUD of commit 8e83c78 already styles both kinds: `patch-depleted` yellow with an ore icon,
  `ruin-captured` green with a steel icon. It shows the newest 3 alerts under the strip, and F3 jumps to them.
- **Measured pace.** The normal AI mines about 1000 main iron in 6 minutes (6000 → 4924–5241). At that pace the main
  iron lasts about 30 minutes, not the 12 of PHASE4 2.4, because the AI's lines are limited by smelting, not by drills.

## Lobby, config, console

- **Start dialog.** A fourth row, "Map" ("Карта"): Chokepoints / Open field, with a tooltip that also says what cliffs
  and lakes stop. Size offers Small / Medium / Large (512×512).
- **Config line** (menu, results): "1 opponent · Normal · Small (256×256) · Chokepoints".
- **`storage.match.config.map`.** "chokes" (default) or "open"; `match.normalize_config` fills it and forces "open"
  on the legacy size. `storage.lobby.pending.map` is filled for older saves.
- **`/rts-match`.** `/rts-match <1-3> <easy|normal|hard> <small|medium|large> [chokes|open] [waves]`
- **`/rts-mapgen`** (QA). It prints:
  - the terrain counts and the measured choke widths;
  - every patch with the ore left;
  - the ruin's owner and capture progress.

  `mapgen.dump(player?)` is the same from script.
- **Autotest override.** `storage.debug.autotest_match` and the `AUTOTEST_MATCH` line accept `map = "open"`;
  without it a match is "chokes".

## API for other modules

| Function | Returns / does |
|---|---|
| `mapgen.patches(force?, kind?)` | The recorded patches: `{id, kind, force, name, center, box, total, tiles, remaining, depleted_tick?}`. `remaining` is refreshed every 10 s. Example: `mapgen.patches("rts-ai-1", "natural")` for an AI hub site. |
| `mapgen.remaining(surface, patch)` | Ore left in a patch now |
| `mapgen.alert(force, kind, text, params, position)` | Appends to `storage.alerts` and prints to the force |
| `mapgen.capture_step(dt)` | One ruin step (tests) |
| `mapgen.dump(player?)` | `/rts-mapgen` |
| `mapgen.mix_seed(n)` | 32-bit hash for random generator seeds |
| `storage.mapgen.ruin` | `{position, cc, chests, owner, capturing, progress, label}` |
| `storage.mapgen.counts` | `{lakes, water_tiles, walls, cliffs, cliff_failed, forests, trees, patches, skipped, chokes}` |

For the AI agent (wave B1):
- **Hub sites.** The natural iron is the AI's `iron2` target. A hub next to the natural pair is the intended
  expansion.
- **The ruin.** A unit near a ruin stockpile for 10 s takes 200 steel and 50 circuits.

## Validation

Every copy is a committed tree plus the map-generation files from `mods/` (`mapgen.lua`, `match.lua`, `lobby.lua`,
both `mapgen.cfg`).
- Why: other agents had unfinished edits in `mods/` at the time, and `hud.lua` there once did not load ("too many
  local variables").
- Commits: the first final set used HEAD 8e83c78. The last runs used HEAD 025158d, with the Commander, the ability
  bar and the new HUD.
- Per-copy edits: only the `AUTOTEST_MATCH` line, or for the GUI copies `SELFTEST_DEFAULT` and the lobby default.

Commands:

```sh
tools/headless-run.sh 430 '\[rts\]' build/p4-mgfinal-1v1s
tools/gui-run.sh build/p4-mgfinal-gui 200 RTS_MATCHFLOW_DONE
```

| Run | HEAD | Map | Result | Errors |
|---|---|---|---|---|
| `build/p4-mgfinal2-1v1s`, 430 s | 025158d | 1v1 small Chokepoints | **14/14**, both alive; extractor, smelter and barracks at 34 s; iron + copper lines at 133–134 s; kits per minute [2 5 3 2 6 3] each; choke widths 11.5 | 0 |
| `build/p4-mgfinal2-1v3m`, 430 s | 025158d | 1v3 medium Chokepoints | **24/24**; every force built by 37 s; lines at 133–178 s; 3 lakes, 8 walls (56 cliffs), choke widths 11.5 / 12.9; `rts-ai-2` out at 417 s | 0 |
| `build/p4-mgfinal-1v1s`, 430 s | 8e83c78 | 1v1 small Chokepoints | **14/14**, both alive; both forces had extractor, smelter and barracks at 34 s and iron + copper lines at 133–134 s; kits per minute [2 5 3 2 6 3] each | 0 |
| `build/p4-mgfinal-1v3m`, 430 s | 8e83c78 | 1v3 medium Chokepoints | **24/24**; every force built by 37 s; lines at 133–178 s; `rts-ai-2` out at 384 s | 0 |
| `build/p4-mgfinal-1v2s`, 430 s | 8e83c78 | 1v2 small Chokepoints (no walls by the fairness rule) | **19/19**; lines at 134–206 s; the AIs won at 286 s | 0 |
| `build/p4-mgfinal-1v3s`, 430 s | 8e83c78 | 1v3 small Chokepoints (no walls; naturals moved sideways) | **24/24**; `rts-ai-1` out at 388 s | 0 |
| `build/p4-mgfinal-1v3l`, 160 s | 8e83c78 | 1v3 large Chokepoints | every force built by 37 s, lines from 133 s; 3 lakes, 8 walls, 10 forests | 0 |
| `build/p4-mgfinal-open`, 160 s | 8e83c78 | 1v1 small Open field | built at 34 s, lines at 133–134 s; no terrain, 15 patches, the ruin | 0 |
| `build/p4-mgfinal-legacy`, 250 s | 8e83c78 | legacy waves brain (Phase 1/2 autotest, 3 matches) | **65/65** | 0 |
| `build/p4-mgfinal-gui`, GUI self-test | 025158d | 1v1 small Chokepoints, Russian client | full flow to `RTS_MATCHFLOW_DONE`; match 1 and match 2 (QA reset) got different terrain | 0 |
| `build/p4-mgfinal-gui-l3`, GUI self-test | 8e83c78 | 1v3 large Chokepoints (lobby default changed in the copy) | full flow; overview screenshot | 0 |
| `build/p4-mapgen-base`, 430 s | a52da4b, without these changes | 1v1 small, Phase 3 arena | 14/14, kits per minute [2 5 3 2 6 3] (baseline) | 0 |

Earlier runs on the code before the last three fixes (seed scramble, wall gap, walls before naturals) also passed:
1v1 small 14/14 and 1v3 medium 24/24 (`build/p4-mapgen`, `build/p4-mapgen-1v3m`), 1v2 small 19/19, 1v3 small
24/24. In the first of them (`build/p4-mapgen`), AI 1's attack group passed the centre and captured the ruin by
accident at 386 s; the AI has no ruin logic.

The ruin and depletion check (`build/p4-mgfinal-ruin`) is a test-only module appended to the copy's `control.lua`:
it stops the AI commanders, puts walkers next to the stockpiles (with a test-only cease-fire between the two forces,
so they stand still) and removes the player's main stone ore.

| Check (`build/p4-mgfinal2-ruin`) | Result |
|---|---|
| `ruin_not_yet`: owner still neutral after 5 s, progress 300 ticks | PASS |
| `ruin_captured`: both stockpiles `rts-player`, destructible, alert `rts.alert-ruin-captured` with params {200, 50} | PASS |
| `patch_depleted_alert`: main stone ore removed → `patch-depleted` alert for `rts-player` at (−60, 16), params {stone, main patch} | PASS |
| `ruin_defended_hold`: an AI 1 walker at one stockpile and a player walker at the other: no progress | PASS |
| `ruin_recaptured`: the player walker leaves → AI 1 owns the stockpiles 10 s later; AI 1 gets `ruin-captured`, the player `rts.alert-ruin-lost` | PASS |
| `dump`: `mapgen.dump` (`/rts-mapgen`) wrote 17 lines | PASS (6/6, 0 errors) |

**Baseline.** The committed tree without these changes (`build/p4-mapgen-base`, 1v1 small) gives the same kits per
minute, [2 5 3 2 6 3], as the Chokepoints run. The lower rate than the Phase 3 numbers comes from other Phase 4
changes, not from finite ore or terrain.

**Screenshots** (`build/shots-p4-mgfinal-gui/`, Russian client):

| File | Shows |
|---|---|
| `rts-p1-900.png` | Tick 900 after the scripted Start: own CC, army, varied grass, the main patches (sparse, see gotcha 3) |
| `rts-mapgen-900.png` | The whole 256×256 arena: two lakes on the mirror axis, four cliff walls with their gaps on the centre line, six forests, the ruin in the centre, natural and middle patches |
| `rts-mapgen-900-middle.png` | The middle at zoom 0.35: cliff runs with tapered ends, the 12-tile gaps, the ruin with its label "Руины" and health bar, the middle iron, copper and coal, the naturals behind the walls |
| `build/shots-p4-mgfinal-gui-l3/rts-mapgen-900.png` | 1v3 large: three lakes, eight walls (north-south for the spawns on the x axis, west-east for the diagonal ones), ten forests |

**Measured.**

| Measure | Value |
|---|---|
| Arena tiles (`create_arena`), Chokepoints / Open, 3 opponents, quiet machine | small 95 / 64 ms, medium 218 / 147 ms, large 380 / 268 ms (the ground noise costs the difference; it was 616 ms on large before the per-column cache) |
| `mapgen.build` (lakes, cliffs, forests, patches, ruin) | 5–13 ms |
| Planning (`mapgen.plan`) | included in the arena time; under 10 ms |
| Terrain per map, Chokepoints | small 1v1: 2 lakes (800–1350 water tiles), 4 walls (20 cliffs), 6 forests (165–280 trees); medium 1v3: 3 lakes, 8 walls (56 cliffs), 8 forests; large 1v3: 3 lakes (2200–3000 water tiles), 8 walls (72 cliffs), 10 forests (350–440 trees) |
| Choke width between cliff collision boxes | 11.5 (north-south walls), 12.9 (west-east walls) |
| Depletion check (every 10 s) | one `find_entities_filtered` per patch: 15 patches in 1v1, 27 in 1v3 |
| Main iron mined by the normal AI in 6 minutes | 760–1076 of 6000 |

## Gotchas

1. **`game.create_random_generator(seed)` ignores the lowest seed bits.** Seeds n and n + 1 gave identical maps for
   match 1 and match 2. `mapgen.mix_seed` scrambles the seed first.
2. **Cliff positions snap to a 4×4 grid** at (4i + 2, 4j + 2.5). The end pieces (`none-to-*`, `*-to-none`) are about
   1.75 tiles shorter than a cell, so an 8-tile cell gap is a 11.5–12.9-tile choke.
3. **Ore looks sparse.** With PHASE4 totals a patch has 19–171 ore per tile, and vanilla ore sprites pick their
   stage from the amount, so patches show the smallest pebbles. A prototype change (resource `stage_counts`) would make
   them look full; that is not a map-generation file.
4. **Self-test steps run on a 30-tick cadence.** A step at 915 ran in the same tick as the QA reset at 930. The
   arena was then deleted before the screenshot rendered, and no file appeared. The overview step is at 890.

## Open items for the lead

- **Cliff chokes do not channel spider units.** Every army unit except the drone, and the hauler, steps over them. To
  make chokes real for every unit, the walls would need water at least 14 tiles wide. Water that wide stops haulers
  that walk a straight line across it.
  - Two options: keep cliffs (current), or back each wall with a 14-tile moat once haulers path around water.
  - For the moat, the logistics owner would route haulers with `LuaSurface.request_path` waypoints; their notes
    already name that as the next step.
- **Haulers and lakes.** Lakes stay off the straight lines from each CC to its naturals, the middle and the ruin. A
  hauler route between two other hubs can still cross a lake; the hauler then logs "may be stuck".
- **Small maps with 3–4 players have no cliff walls.** The centre is too crowded for fair walls. They still get lakes,
  forests, naturals and the ruin.
- **The AI ignores the ruin.** Wave B1 could send a unit to it (`storage.mapgen.ruin.position`).
- **The AI cannot expand to a natural with belts.** The route from 60+ tiles fails, so B1 needs hubs and haulers
  there (`mapgen.patches(force, "natural")`).
- **Alerts appear twice.** `patch-depleted` and `ruin-captured` are printed to the force's chat and shown in the HUD
  alert lines, like `supply-blocked`. Drop the chat line in `mapgen.alert` if the HUD alone is enough.
- **My locale files were committed by someone else.** The HUD commit 8e83c78 includes `locale/en/mapgen.cfg` and
  `locale/ru/mapgen.cfg`; my other files are uncommitted.
- **Main patches last about 30 minutes at the current AI pace**, not 12. If 12 is the target, either the totals or
  the AI's smelting throughput has to change.
