# Phase 3 AI commander: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Plan: `docs/PHASE3.md` ("AI architecture", "Difficulty",
"Acceptance"). Builds on the Phase 2 APIs in `docs/qa/phase2-economy-notes.md` and the orders API in
`docs/qa/phase1-selection-orders-notes.md`.

## Status

- **Both forces run as AI commanders in the headless autotest.** The main run passes 9/9 checks with zero errors
  at 60 UPS. Both commanders have an extractor, a smelter and a barracks by 21–23 s, produce units every minute,
  attack, defend, retreat and rebuild.
- **The new files are in `mods/factorio-rts/scripts/ai/`.** Nothing else in `mods/` was edited.
- **The wiring is a 3-file patch for the lead,** listed under "Wiring edits" and saved as
  `build/p3-ai-wiring.patch`. It applies cleanly to the current `mods/` (checked with `patch --dry-run`).

## Files (`scripts/ai/`, all new)

| File | Lines | What it does |
|---|---|---|
| `init.lua` | 272 | Entry. `ai.init`, `ai.init_force`, `ai.stop_force`, `ai.get`, the scheduler, the damage event, the hard bonus units, the console commands, `ai.log_maps`, `ai.perf` |
| `commander.lua` | 312 | Per-force state, start-up, the run sequence, barracks and factory recipes, the dump lines |
| `orders_data.lua` | 157 | Data: the difficulty table, the mining lines, the three build orders, factory recipes, target priorities |
| `build_order.lua` | 358 | Step interpreter, line planning and bookkeeping (which drills and hub slots to queue) |
| `layout.lua` | 904 | Geometry: hub slots, ore patches, mining spines, the A* belt router, pole chains, free spots, the ASCII map |
| `construction.lua` | 258 | Plan entries, ghosts, paced revive with item debit, give-up rules, repair, network item counts |
| `army.lua` | 305 | Rally, attack waves, reinforcements, retreat, defence, re-targeting |
| `scout.lua` | 146 | Known enemy buildings, spawn guesses, sight checks, target choice |
| `autotest.lua` | 204 | Headless AI-vs-AI test: minute reports, checks, performance lines, the summary |

## Running it

```sh
# test copy = mods + the wiring patch
rm -rf build/p3-ai && mkdir -p build/p3-ai && cp -R mods/factorio-rts mods/mod-list.json build/p3-ai/
(cd build/p3-ai && patch -p2 < ../p3-ai-wiring.patch)   # or apply the edits below by hand
tools/headless-run.sh 400 '\[rts\] (ai|match)' build/p3-ai
```

With the patch, a new game has `enemy_brain = "ai"`. The autotest then starts a normal commander for `rts-player`
too at tick 120, and the two fight for 6 minutes. The headless runner keeps the server up for its full time even
after the summary. I used a private runner that stops at the summary line, so runs cannot overlap on the same mods
directory (two overlapping runs fail with "Couldn't acquire exclusive lock").

Console commands (admin for the ones that change state):

| Command | Effect |
|---|---|
| `/rts-ai <force> [easy\|normal\|hard]` | Start a commander. On a force that has one, it only changes the difficulty in place: new settings and build order; plan, base and army stay. |
| `/rts-ai-stop <force>` | Forget the commander; units and buildings stay |
| `/rts-ai-dump [force]` | State: build-order step, queue, lines, buildings, army groups, scouting |
| `/rts-ai-map [force]` | Writes an ASCII map of the plan to the log (see "Layout") |

## Architecture as built

### Scheduler and state

- **Scheduler.** `ai.tick` runs every 10 ticks. Each commander runs every 60 ticks (`commander.THINK`), staggered by
  20 ticks per force.
- **Run order.** A run is build order → construction (+ repair every 10 s) → production → army → scouting (every 5 s).
  It does nothing once `storage.match.phase == "ended"`. Without a CC only the army and scouting run.
- **State.** It lives in `storage.ai[force_name]`; the field list is in the header of `commander.lua`.
  `storage.ai_meta.inserter_dir_is_pickup` holds the result of a one-time probe. In 2.0 an inserter's
  `direction` points at its pickup side.
- **Start.** `commander.start` runs these steps:
  1. It takes the robots out of the force's CCs (30 each).
  2. It builds the frame: CC centre, and forward = towards the nearest other spawn.
  3. It sets the rally point, seeds the spawn guesses and applies the hard cheats.
  4. It reserves every hub-slot tile and plans the three start lines (iron, stone, copper) in one pass. This takes
     8–22 ms per force.

### Build order (`build_order.lua`, data in `orders_data.lua`)

Each run walks the steps in order:

| Step state | What happens |
|---|---|
| Satisfied | Skipped. A step whose buildings died becomes unsatisfied again. |
| Unsatisfied, work still queued | Counts as in progress |
| Unsatisfied, `when` holds | Executed: its work is queued, and it counts as in progress |
| Unsatisfied, `when` fails | Skipped. The walk passes over at most 2 such steps (`LOOKAHEAD`). |
| Executed, but nothing could be queued | Backs off for 10 s |

The walk stops at `max_in_progress` steps in progress (2, 3 or 4 by difficulty).

Step kinds, as asked for:

| Step | Meaning |
|---|---|
| `{kind="build", name, anchor="cc"\|"front", count}` | N buildings on free spots |
| `{kind="build", name="rts-extractor", anchor=<line>, count}` | N drills on a mining line, plus the line's belts and poles |
| `{kind="build", name="rts-smelter"\|"slot", anchor=<line>, count}` | N hub slots of the line, plus the belt segments to them |
| `{kind="recipe", building="rts-barracks", recipe}` | Turns unit production on |
| `{kind="army", min, action="attack"}` | Attack size |
| `{kind="expand", anchor="iron2", extractors, slots}` | Plans a line to the next free patch of that ore. It is skipped when none exists, which is the case on the current map. |

`when` keys are `iron`, `copper`, `stone` and `steel` (network counts), `units` and `time` (seconds since start).

**The gates use stone and time, not iron.** Once the barracks run, iron rarely sits in the network. In the first
version every iron-gated step stalled, and the economy froze at minute 2. A queued step still gets its iron:
production.lua's fairness rule makes the starved factory reserve iron ahead of the barracks.

### Layout (`layout.lua`)

**Hub.** The smelters must deliver into the four CC stockpiles. The PHASE2 starting stock had no stockpile items and
there was no stockpile recipe when this was designed; the lead has since added both, and the AI does not use them
yet. Each stockpile takes inserters on its free sides, and `layout.HUB` defines 18 slots in the CC frame, mirrored
for the other side:

| Slot type | Names | Chain |
|---|---|---|
| Smelter | E, N, W, S 1–2 | Feed belt tile → inserter → `rts-smelter` → inserter → stockpile |
| Direct | `N1d`, `S1d`, `N2d`, `S2d`, `E1d`, `E2d` | Feed tile → inserter → stockpile. Used for stone. |
| Steel chain | `N1c`, `N2c`, `S1c`, `S2c` | Feed → inserter → smelter A (iron plates) → inserter → smelter B (steel) → inserter → stockpile |

Slots that share tiles exclude each other: claiming one kills the others and frees their tiles. All slot tiles are
reserved from the start, so nothing else is built in the hub.

**Lines.** A line is planned like this:

1. **Patch.** The nearest free patch of its ore, clustered from the resource entities inside the arena. Map-gen
   ore just outside the arena was as near as the arena patch in one run and is excluded.
2. **Spine.** A straight belt through the patch towards the CC, on the best of five candidate rows. Drills sit on
   both sides in pairs around a one-tile gap that holds a medium pole: `D g D . D g D`. Each pole powers four
   drills, and gap poles are 7 tiles apart.
3. **Belt routes.**
   - The short links between consecutive hub slots are routed first.
   - Then the main belt is routed from the spine to the first slot, around those links. Without this order, the
     iron belt once reached its first slot over the tile the second link needed and took a 40-tile detour around
     the CC.
   - The router is A* over tiles with 4-way moves, a turn penalty of 1.5 and an ore penalty of 2. Every belt faces
     the next tile.
   - A line's last belt goes straight on, unless that would feed another belt. The tile in front of it is banned
     for every later belt, so no line can side-load into another.
4. **Power.** A greedy chain of medium poles runs from the nearest gap pole to within 8.5 tiles of the CC centre,
   where the hidden core pole connects it.

**Lines on the current map** (iron 17 tiles forward and 10 south, copper 17 forward and 10 north, stone 28 forward
and 16 south):

| Line | Hub slots, in order | Belts | Drill spots |
|---|---|---|---|
| Iron | `S1`, `S2`, `W2`, `W1`, then the steel chain `N2c` | 61 | 8 |
| Copper | `N1`, `E1` | 32 | 5 |
| Stone | `E2d` | 41 | 4 |

Slot lists are written for the patch side named in `side` and mirror in y when the patch is on the other side. The
enemy base is the same plan mirrored in x.

**Free spots.** Barracks, factory, solar and turrets go on candidate positions sorted by distance to a preferred
offset (`PREFER`, mirrored in y).

| Anchor | Area |
|---|---|
| `cc` | Within 16 tiles of the CC, inside the core pole's supply area |
| `front` | 10–23 tiles forward, inside the CC logistic area, so turret ammo can be fed |

A spot needs a free one-tile margin, no reserved tiles and `can_place_entity`.

The player's base at the end of the main run, from `/rts-ai-map`. Upper case = built, lower case = planned,
`<>^v` = belts, `D` = extractor, `S` = smelter, `i` = inserter, `P` = pole, `K` = stockpile, `C` = CC,
`B` = barracks, `F` = factory, `T` = turret, `.` `,` `:` = iron, copper and stone ore.

```
  -12 |              >>>>>>>       BBB    DDDddd,ddd
  -11 |              ^     i             PDDDdddpddd
  -10 |              ^    SSS     v<<<<<<<<<<<<<<<<<
   -8 |          FFF ^    SSS     >>>>>>v    ddd,ddd
   -6 |          FFF ^    SSS    SSSP   v
   -3 |              ^ SSS i      i sss v
   -2 |              ^iSSSiK CCCC Kisssiv
    0 |              ^ SSS   CCCC
    1 |              ^iSSSiK CCCC Ki<<<<<<<<<<<<<<<<<<<
    3 |              ^    SSS    SSSP                 ^
    5 |              ^    SSS    SSS P     ......TT.. ^
    7 |              ^<<<<<<<<<<<<<     DDD.DDDddd.ddd^
    9 |                           ^    PDDDPDDDdddpddd^
   10 |                           ^<<<<<<<<<<<<<<<<<<<^
   13 |                                 DDD.DDDddd.ddd^ddd:DDD
```

### Construction (`construction.lua`)

- **No robots.** `commander.start` empties the CC robot inventories. Otherwise the 20 construction robots build the
  AI's ghosts from the network at their own pace.
- **Plan entries.** Each entity has an entry with the states planned → queued → ghost → built, or bad. Ghosts are
  `create_entity{name="entity-ghost", inner_name=...}`. Trees, rocks and items in the footprint are destroyed first.
- **Pace.** One job every `build_period` ticks per commander (120 at normal). A job is one building, or up to
  `small_batch` belts, inserters and poles (5 at normal).
- **Paying.** A revive takes one item from the network with `economy.take` and uses `revive{raise_revive=true}`, so
  buildings.lua registers the building. The item goes back when the revive fails. Inserters are checked against
  their expected pickup position after revive and turned round if needed; this never triggered after the probe.
- **Giving up.** A ghost that cannot be placed, or a revive that keeps failing, is dropped after 60 s and marked
  `bad`. Its tiles stay reserved, so a spot is not reused. Own units standing on a footprint whose revive failed
  are sent to the rally point.
- **Repair.** Every 10 s, built entries whose entity died are queued again. This happened in the runs ("3
  destroyed entities queued for rebuilding").
- **Network counts.** `construction.have(C, item)` counts an item in the CC networks, memoized per tick. The AI uses
  it instead of `economy.snapshot`, whose full HUD summary (power and every building) was most of the AI's time.

### Production (in `commander.lua`)

**Barracks.**
- Each barracks gets the build order's unit recipe once the recipe step ran, and the army rally point as its
  rally.
- One barracks switches to heavy kits while the network holds 150 or more iron and 5 or more steel, as specified.
  A recipe only changes while the barracks is idle or not crafting.

**Factory.**
- The lowest-numbered factory makes the first item the construction queue lacks, in queue order
  (`FACTORY_RECIPE`).
- It keeps a recipe that still makes something short, so two shortages do not make it flip.
- With nothing to build it makes ammo while turrets exist and the network holds fewer than 20 magazines.
  Otherwise it idles, so the iron goes to units.

### Army (`army.lua`)

**Orders through orders.lua.** No fake player index is needed: `orders.move` and `orders.attack_move` accept an
array of `LuaEntity` as `who`. AI units therefore get formation slots, nearest-enemy re-targeting and release to
idle + stop exactly like player units. The selection state is not involved.

**Rally.** The rally point is 34 % of the way to the nearest other spawn, clamped to 20–40 tiles. That is (-20, 0)
for the player and (20, 0) for the enemy. At 40 % the rallies were 24 tiles apart, inside unit vision (30), and the
armies fought at the centre from the first second.
- Pool units further than 14 tiles from it are sent back, at most every 30 s per unit.
- Barracks rally points are set to it.

**Attack.**
- An attack starts when the pool's strength reaches the build order's `min`, and `attack_interval` has passed
  (easy only). Strength counts each unit by its health share, so the wounded remains of a group do not count fully.
- There is no attack for 30 s after a retreat.
- While a group attacks, a pool of half the attack size goes after it as a reinforcement.

**Target.** The target is the known enemy building with the lowest distance + penalty (`TARGET_PENALTY`):
- barracks and factory 0, turret 10, extractor and smelter 25, solar 35, CC 45, stockpile 60;
- then the nearest visible enemy unit;
- then the enemy spawn guess.

Factories are first-class targets: in one base-game run the AI hunted down the enemy's last factory to end the
match.

**Group upkeep.** Every 10 s each group:
- retreats to the rally when its HP falls below 40 % of what it started with;
- re-targets, re-issuing `attack_move` only when the target moved more than 6 tiles or a member went idle;
- returns home when nothing is known.

Groups that are back, or 45 s into a retreat, disband.

**Defence.**
- `on_entity_damaged` has a filter on the 8 RTS building names; no other module uses that event.
- Damage to an own building records a threat: position, time and damage.
- A fresh threat within 55 tiles of the CC sends the whole pool there as a defence group.
- With an empty pool, a threat of 400 or more damage recalls the nearest attack group.

### Scouting (`scout.lua`)

- **Honest vision (easy and normal).** A spot counts as seen while any own entity is within 30 tiles (the units'
  `vision_distance`) or its chunk is visible. Every 5 s the scan adds the seen enemy buildings from the buildings
  registry. It forgets a building only when its spot is seen and the building is gone.
- **Spawn guesses.** The other spawns from `storage.match.spawns` are known from the start, like start locations on
  a skirmish map, and are dropped when seen.
- **Hard** sees everything.
- **Chunk visibility alone does not work.** In headless runs `is_chunk_visible` and `is_chunk_charted` stayed false
  for both forces with units standing in the chunks. Even the player force's arena chart was still false at tick
  600 in the debug probe.

### Difficulty (`orders_data.DIFFICULTY`)

| | Easy | Normal | Hard |
|---|---|---|---|
| Construction job every | 3 s, 3 small pieces | 2 s, 5 small pieces | 1 s, 6 small pieces |
| Steps in flight | 2 | 3 | 4 |
| Attack | at 6, at most every 4 min | at 10 | at 12 |
| Vision | honest | honest | full map |
| Cheats | none | none | x1.5 starting stock, mining productivity +25 %, a free unit every 4th spawn (x1.25) |
| Build order | 1 iron drill, 2 iron smelters, stone, copper, 1 turret late | see below | normal's shape, earlier gates, 3 turrets, steel at 3 min |

The crafting speed of a single machine cannot be changed at runtime, so "production speed x1.25" is a bonus unit
for every 4th spawn.

## Build orders (normal)

| # | Step | Gate |
|---|---|---|
| 1 | Factory @cc | – |
| 2 | 2 extractors @iron (with the spine, belt and poles) | – |
| 3 | 2 iron hub slots (S1, S2) | – |
| 4 | Barracks @cc | – |
| 5 | Barracks → walker kits | – |
| 6–7 | Stone extractor and its direct slot | – |
| 8–9 | Copper extractor and slot N1 | stone 10 |
| 10 | Army: attack at 10 | – |
| 11–12 | 3rd iron extractor and slot W2 | stone 10 |
| 13 | 2 turrets @front | 150 s |
| 14 | Expand iron2 (skipped on this map) | 210 s |
| 15 | 4th iron slot W1 | stone 10, 240 s |
| 16–17 | 4th iron extractor and the steel chain N2c | 300 s, stone 20 |

Easy and hard are in `orders_data.lua`. The normal order has no solar arrays (the CC's 4 MW covers a full base) and
no second barracks (one barracks out-produces a full iron line).

## Wiring edits for the lead

The patch is `build/p3-ai-wiring.patch` (92 lines). It applies to the current `mods/` with
`patch -p1 --dry-run` from the project root. The edits:

1. **`control.lua`**, in the module list right after `require("scripts.match"),`:
   ```lua
   require("scripts.ai.init"),  -- Phase 3 AI commanders; after match (ai.init reads storage.match.config)
   ```
2. **`scripts/match.lua`**, four hunks:
   - **`match.DEFAULT_CONFIG`** gains `enemy_brain = "ai", enemy_difficulty = "normal"`. With `"waves"` the Phase 2
     template enemy and the waves come back.
   - **`config()`** fills both fields for older configs. A save from before Phase 3 (phase not `"setup"`) gets
     `"waves"`, so its template enemy keeps working.
   - **`place_bases`**: with `enemy_brain == "ai"`, `rts-enemy` gets the same start as the player, through
     `buildings.place_cc` plus `match.STARTING_STOCK`. Otherwise it gets the template and the barracks recipe as
     before.
   - **The 60-tick handler** launches no wave when `enemy_brain == "ai"`. The test is
     `... and config().enemy_brain ~= "ai"` on the `enemy_next_wave` line.
3. **`scripts/debug.lua`**:
   - Add `local ai_autotest = require("scripts.ai.autotest")` after the `basetemplate` require.
   - At the autotest decision, replace `if d.autotest then debug_tools.start_autotest() end` with a branch that
     calls `ai_autotest.start()` when `storage.match.config.enemy_brain == "ai"`, else the Phase 1/2 autotest.

Notes for the lead:
- **Pick the default brain.** With `enemy_brain = "ai"` as default, the Phase 1/2 autotest no longer runs, because
  it expects the template enemy and the waves. Keep `"waves"` as the default, or switch per run, if both autotests
  must stay.
- **`ai.init`** starts the enemy commander in `on_init` when `enemy_brain == "ai"`. The autotest adds the
  `rts-player` commander at tick 120. In a real game nothing starts a commander for `rts-player`.
- **The match's win rule is unchanged.** A force is out with no CC, barracks or factory and no units.

## Validation and measured timings

| Run | Copy | Result | Errors |
|---|---|---|---|
| Normal vs normal, Space Age, current map, alone on the machine | `build/p3-ai` | 9/9, both alive and producing at 6 min | 0 |
| Hard (player) vs easy (enemy), Space Age | `build/p3-ai-hard` | 7/7, hard wins at 115 s | 0 |
| Normal vs normal, base game only (Space Age, quality and elevated-rails off) | `build/p3-ai-nosa` | 9/9, the enemy wins at 219 s | 0 |

The normal-vs-normal run passed 9/9 in each of the last seven runs: five on the Phase 2 map (iron straight ahead of
the CC), then two on the current one.

### Main run (Space Age), per minute

| Minute | Player kits | Enemy kits | Player iron smelted | Enemy iron smelted | AI time, both commanders | Wall clock per 3600 ticks |
|---|---|---|---|---|---|---|
| 1 | 6 | 7 | 42 | 44 | 189 ms | 59 982 ms |
| 2 | 5 | 4 | 74 | 76 | 145 ms | 59 998 ms |
| 3 | 5 | 6 | 108 | 107 | 136 ms | 60 001 ms |
| 4 | 4 | 4 | 111 | 114 | 156 ms | 59 997 ms |
| 5 | 11 | 9 | 142 | 141 | 142 ms | 60 003 ms |
| 6 | 7 | 6 | 156 | 162 | 162 ms | 59 998 ms |

**Timings.**
- An extractor, a smelter and a barracks stand at 21 s (enemy) and 23 s (player). The first kits follow at about
  20 s.
- The first attacks leave at 57–60 s with 12 units each. Both groups retreat at about 40 % HP.
- The enemy finished its whole build order (17/17) by 6 min.

**UPS.** The game held 60 UPS for all 6 minutes.
- The commanders cost 136–189 ms per 3600 ticks together: about 0.04–0.05 ms per tick on average and about 1.1–1.6
  ms per commander run.
- Split of AI time per minute: build order 40–63 ms, construction 10–74 ms (74 in minute 1 with the long queue),
  production 18–30 ms, army 21–39 ms, scouting 13–21 ms.
- Planning at start: 8–22 ms per force, once.
- `--benchmark` of the end-state save for 3600 ticks (`build/p3-ai-benchmark.txt`): whole update 0.297 ms per tick
  on average. Script update (all mod code) is 0.010 ms on average and 0.194 ms at the 99th percentile; commander
  ticks take 0.2–0.4 ms, with a single 2.2 ms outlier. That save holds about 15 units, so it does not answer
  PHASE3 acceptance 5 (3 AI bases and 300 units). Units and combat dominated cost in the units spike, not the AI.

**Kits and iron.** Kits stay at 4–6 per minute while the economy is being built. production.lua's fairness rule
gives the factory and the barracks iron craft by craft, so construction takes about two thirds of the iron then.
Once the queue empties (minute 5), all iron goes to units: about 11 kits per minute on about 140 plates per minute.

### Base-game run

- **Final build: 9/9 checks, zero errors.** Both sides had an extractor, a smelter and a barracks at 21–23 s. Their
  first attacks left at 57–60 s and both retreated.
- **The end.** The enemy's second attack at 182 s (15 units, aimed at the player's barracks) won the match at
  219 s.
- **Earlier builds.** Two base-game runs went the other way: the player AI won at 242 s and at 366 s, the second one
  by hunting down the enemy's last factory. In one of them the produce check failed: the enemy had lost its CC but
  kept a barracks. The check now requires a CC, because without the CC's network nothing can be produced.

## Deviations from the request, with reasons

1. **Construction pace: one job per 2 s, and a job may be up to 5 belts, inserters or poles.** Strictly one entity
   per 2 s puts a 40–60-tile belt line at 2 minutes on its own; the economy then missed the 3-minute target.
   Buildings still go one per job.
2. **The pace is per commander, not per CC.** A force has one CC in this match setup.
3. **No fake player index.** orders.lua already takes entity lists, and that is simpler and keeps AI units out of
   selection state.
4. **"Extractors on ore → belt → smelters next to a stockpile"** is built as belts into the CC hub slots, since
   only the CC stockpiles existed. With the new `rts-stockpile` recipe, smelter blocks at the patch with their own
   stockpile would cut belt lengths (see open issues).
5. **Honest vision is sight-based, not chunk-based.** Chunk visibility stays false headless (see Scouting).

## Gotchas

1. **The CC's robots build the AI's ghosts.** Without taking them out, construction is not paced and costs nothing
   extra to model. Both commanders log "removed 30 robots".
2. **Map-gen ore just outside the arena counts as a patch.** It can tie with the arena patch for nearest; the first
   full run planned the player's iron line on it and lost the game. Only resources inside the arena are used now.
3. **A direct slot's feed tile is boxed in by the smelter slot it replaces.** The router must claim the slot (and
   kill the conflicting ones) before routing, and undo the claim when no route is found
   (`layout.snapshot_hub` / `restore_hub`).
4. **2.0 inserter direction is the pickup side.** This was probed once (`inserter probe: direction north picks up
   from north`) and stored in `storage.ai_meta`.
5. **Network iron is a useless gate.** Once a barracks runs, the network holds about one kit's worth of iron.
6. **`economy.snapshot` is expensive for a 60-tick consumer.** Its cache lasts 30 ticks, so every commander run
   recomputed the full HUD summary.
7. **`helpers.create_profiler` objects are module-local.** They are lost on load and recreated by `ai.perf()`; they
   are only logged, never stored.
8. **`tools/headless-run.sh` keeps the server up for the full time.** A second run on the same mods directory
   started early fails with the write-data lock. A runner that checks for a running server must match the
   Factorio binary, not just `--mod-directory <dir>`, or it matches its own shell command line.

## Open issues

- **Heavy kits almost never happen.** The specified rule needs 150 iron in the network, which a running barracks
  never leaves. The steel chain makes steel from minute 5–6 (steel 1–9 seen), but no heavy was built in any run.
  Options:
  - lower the iron threshold to one heavy kit's worth (30) while steel is at least 5;
  - or reserve iron for heavies by pausing walkers for one craft.
- **The new stockpile items are unused.** The start now includes 2 `rts-stockpile` and there is a recipe. A
  patch-side smelter block (drills → belt → smelters → inserters → stockpile) inside the CC logistic area would free
  the hub and allow more than four iron smelters. The hub is full on the current map, so `expand iron2` has no slot
  left even when a second patch exists.
- **The AI never builds a second CC.** No CC item exists. A lost CC ends production, because it is the only
  logistic network. The barracks keeps a force "alive" but idle until the factory hunt finishes it, which the army
  does.
- **The enemy commander starts 2 s before the player's in the autotest.** `on_init` starts it at tick 0, and the
  autotest starts the player's at tick 120. The enemy reaches its attack size first and attacks the spawn guess;
  the player's first attack then aims at the enemy's marching group. Results still went both ways: base-game runs
  were won twice by the player and once by the enemy, and Space Age normal runs ended even at 6 min.
- **Defence uses the whole pool.** Any damage to a building, even a stray walker's, pulls every idle unit off the
  rally, so the attack size is reached late. The enemy logged 8 defences and only 1 attack in the last run. A
  threshold on threat damage, or sending only enough units to match the visible attackers, would help.
- **Turrets may stand on ore.** "front" spots avoid reserved tiles, and drill footprints are reserved, but the rest
  of the patch is not.
- **No GUI check.** Belt directions, curves and side-loading were checked through the plan map and through
  production (smelted plates per minute), not visually.
- **Not measured: PHASE3 acceptance 5, 3 AI bases and 300 units at 60 UPS.** The arena has two spawns.
