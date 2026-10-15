# Phase 3 AI commander: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Plan: `docs/PHASE3.md` ("AI architecture", "Difficulty",
"Acceptance"). Builds on the Phase 2 APIs in `docs/qa/phase2-economy-notes.md`, the orders API in
`docs/qa/phase1-selection-orders-notes.md` and the Phase 3 match flow in `docs/qa/phase3-matchflow-notes.md`.

## Status

- **Round 1 is committed (a843594).** That covers the commanders, build orders, ghost construction, production, army,
  scouting, the AI-vs-AI autotest, and the wiring into `control.lua`, `match.lua` and `debug.lua`.
- **Round 3 (latest) generalizes the hub for the rotated ore layout.** Slot types now exist on all four sides of the
  CC. Each line takes its first-choice slot, then the nearest free slot of the same type, then a satellite
  ("stacked" lines). See "Choosing slots" and "Round 3 validation". With `match.ORE_LAYOUT = "rotated"`, every AI
  in 1v2 and 1v3 builds iron and copper lines. The facing layout is unchanged and passes.
- **Round 2 is the tuning round, inside `scripts/ai/` only:**
  - difficulty pacing for human opponents;
  - heavy kits;
  - partial defence;
  - satellite stockpiles and a second building ring;
  - finishing a beaten side;
  - fixes for the new match flow: the arena-size contract and vertical mining lines.
- **Results.** On the current `mods/` (lobby match flow, small 256×256 map), the 6-minute AI-vs-AI autotest has zero
  errors at every difficulty and keeps 60 UPS. Both sides build at every difficulty, and every check passes:

  | Difficulty | Checks | Result |
  |---|---|---|
  | Easy vs easy | 9/9 | Both alive at 6 min |
  | Normal vs normal | 9/9 | Both alive at 6 min |
  | Hard vs hard | 9/9 | Match ends at 224 s |
  | 1v3 free-for-all (normal) | 17/17 | Two AIs out by minute 5 |

  Hard finishes a match faster than easy. In 12-minute runs, easy and normal both still stood at 12 minutes, while
  hard ended at 224 s again.
- **The match-flow owner can set `match.AI_VERTICAL_LINES = true` and rotate spawns.**
  - The vertical-line crash that their notes report (`layout.lua:412`, undefined `tx`/`ty` in the vertical branch of
    `spine_candidate`) is fixed: `along, perp = cell[2], cell[1]`.
  - The arena size comes from `storage.match.arena_half` (`layout.arena_half()`, fallback 80).
  - The autotest checks both at start ("Planner check" below). The 1v3 run passes with the flag on.

## Files (`scripts/ai/`)

| File | Lines | What it does |
|---|---|---|
| `init.lua` | 279 | Entry. `ai.init`, `ai.init_force` (changes the difficulty in place when a commander exists), `ai.stop_force`, `ai.get`, the scheduler, the damage event, the last kit per barracks and hard's bonus units, the console commands, `ai.log_maps`, `ai.perf` |
| `commander.lua` | 390 | Per-force state, start-up, the run sequence, barracks recipes (heavy alternation), the factory (feasible recipe first, ammo budget), the dump lines |
| `orders_data.lua` | 181 | Data: the difficulty table, the mining lines, the three build orders, factory recipes, target priorities |
| `build_order.lua` | 363 | Step interpreter, line planning and bookkeeping |
| `layout.lua` | 1182 | Geometry: hub slots on all four sides and how lines choose them, satellites, ore patches, mining spines, the A* belt router, pole chains, free spots with a second ring, the ASCII map |
| `construction.lua` | 258 | Plan entries, ghosts, paced revive with item debit, give-up rules, repair, network item counts |
| `army.lua` | 339 | Rally, attacks, reinforcements, retreat, partial defence, finishing, re-targeting |
| `scout.lua` | 190 | Known enemy buildings, spawn guesses, sight checks, beaten enemies, target choice |
| `autotest.lua` | 324 | Headless AI-vs-AI test for every match force: the planner check, minute reports, checks (incl. iron and copper lines per force), performance lines, the summary |

## Running it

The autotest runs by itself in a headless game. debug.lua starts a match through `lobby.start_match(AUTOTEST_MATCH)`;
the lobby starts a commander for every AI force, and `ai_autotest.start()` adds one for `rts-player` at the same
difficulty.

```sh
rm -rf build/p3-ai2 && mkdir -p build/p3-ai2 && cp -R mods/factorio-rts mods/mod-list.json build/p3-ai2/
tools/headless-run.sh 400 '\[rts\] (ai|match|lobby)' build/p3-ai2
```

`AUTOTEST_MATCH` in `debug.lua` is 1v1, normal, small (256×256, CCs at ±88). For the easy, hard and 1v3 runs below,
the test copies changed only that line. `autotest.DURATION` in `ai/autotest.lua` is 6 minutes; the 12-minute copies
changed only that line. I ran the copies with a private runner that stops the server at the summary line.

Console commands (admin for the ones that change state):

| Command | Effect |
|---|---|
| `/rts-ai <force> [easy\|normal\|hard]` | Start a commander. On a force that has one, it changes the difficulty in place: new settings and build order; plan, base and army stay. |
| `/rts-ai-stop <force>` | Forget the commander; units and buildings stay |
| `/rts-ai-dump [force]` | State: build-order step, queue, lines, buildings, army groups, scouting |
| `/rts-ai-map [force]` | Writes an ASCII map of the plan to the log (see "Layout") |

## Round 2 changes at a glance

| Request | As built |
|---|---|
| 1. Pacing per difficulty | Construction job every 6 / 3 / 2 s. No attack before 5 / 3 / 1.5 min. Attack size 6 / 10 / 12. Easy defends with at most half its idle units. |
| 2. Heavy kits at steel ≥ 5 and iron ≥ 40, then alternate | A heavy kit is due after every walker kit once steel ≥ 5. The barracks switches when the iron in the network plus the iron inside the barracks is ≥ 40; short of that it pauses at most 20 s, then makes one more walker. |
| 3. Defence takes only the nearest half (min 4) | Done; the rest stays at the rally. A fresh threat no longer stops an attack by the rest of the pool. |
| 4. Second ring, extra stockpiles, turrets at the enemy side | Free spots get a second ring out to the CC logistic edge, with power from a planned pole or a new pole on the building's margin. Satellites add an extra `rts-stockpile` with a smelter on each side, two more iron smelters. Turrets go 10–23 tiles towards the nearest enemy spawn and never on ore. |
| 5. Finish a beaten side | An enemy with no CC and no barracks is attacked with 3 units at a time. The target is its nearest factory, then stockpile, then any building, known or not. |
| Not asked, found on the way | Factory recipe choice skips recipes it cannot feed (easy deadlocked on copper). Ammo is capped at 10 magazines per turret per minute: gun turrets burned about 200 iron a minute on walkers. The vertical-line crash and the arena-size contract are fixed. Expansions use satellites and come last. |

## Architecture as built

### Scheduler and state

- **Scheduler.** `ai.tick` runs every 10 ticks. Each commander runs every 60 ticks (`commander.THINK`), staggered by
  20 ticks per force.
- **Run order.** A run is build order → construction (+ repair every 10 s) → production → army → scouting (every 5 s).
  It does nothing once `storage.match.phase == "ended"`. Without a CC only the army and scouting run.
- **State.** It lives in `storage.ai[force_name]`; the field list is in the header of `commander.lua`.
  `storage.ai_meta.inserter_dir_is_pickup` holds a one-time probe: in 2.0 an inserter's `direction` points at its
  pickup side.
- **Who starts commanders.** `lobby.start_match` starts a commander for each AI force of a match, and
  `match.teardown` stops them. `ai.init` only starts one itself for the older single-enemy `match.lua`.
- **Start.** `commander.start` runs these steps:
  1. It takes the robots out of the force's CCs.
  2. It builds the frame: CC centre, and forward = towards the nearest other spawn along x.
  3. It sets the rally point, seeds the spawn guesses and applies the hard cheats.
  4. It reserves every hub-slot tile and plans the three start lines (iron, stone, copper) in one pass. This takes
     19–32 ms per force on the small map.

### Build order (`build_order.lua`, data in `orders_data.lua`)

Each run walks the steps in order:

| Step state | What happens |
|---|---|
| Satisfied | Skipped. A step whose buildings died becomes unsatisfied again. |
| Unsatisfied, work still queued | Counts as in progress |
| Unsatisfied, `when` holds | Executed: its work is queued, and it counts as in progress |
| Unsatisfied, `when` fails | Skipped. The walk passes over at most 2 such steps. |
| Executed, but nothing could be queued | Backs off for 10 s |

The walk stops at `max_in_progress` steps in progress (2, 3 or 4 by difficulty).

| Step | Meaning |
|---|---|
| `{kind="build", name, anchor="cc"\|"front", count}` | N buildings on free spots |
| `{kind="build", name="rts-extractor", anchor=<line>, count}` | N drills on a mining line, plus the line's belts and poles |
| `{kind="build", name="rts-smelter"\|"slot", anchor=<line>, count}` | The first N slots of the line, plus the belt segments to them |
| `{kind="recipe", building="rts-barracks", recipe}` | Turns unit production on |
| `{kind="army", min, action="attack"}` | Attack size |
| `{kind="expand", anchor="iron2", extractors, slots}` | A line to the next free patch of that ore (on the small map, the contested centre patch) |

`when` keys are `iron`, `copper`, `stone`, `steel` (network counts), `units` and `time` (seconds since start). The
gates use stone and time, not iron: once the barracks run, iron rarely sits in the network.

### Layout (`layout.lua`)

**Arena bounds.** The arena is `[-arena_half, arena_half)²` from `storage.match.arena_half`, as agreed with
match.lua (`layout.arena_half()`, fallback 80). Nothing is planned outside it, and ore outside it is ignored.

**Hub.** Each of the four CC stockpiles takes inserters on its free sides. `layout.HUB` defines 24 slots in the CC
frame, mirrored for the other side. Every type exists on all four sides (round 3 added the east and west direct
and chain slots):

| Slot type | Names | Chain |
|---|---|---|
| Smelter | `E1`/`E2`, `N1`/`N2`, `W1`/`W2`, `S1`/`S2` | Feed belt tile → inserter → `rts-smelter` → inserter → stockpile |
| Direct | `N1d`, `N2d`, `S1d`, `S2d`, `E1d`, `E2d`, `W1d`, `W2d` | Feed tile → inserter → stockpile. Used for stone. |
| Steel chain | `N1c`, `N2c`, `S1c`, `S2c`, `E1c`, `E2c`, `W1c`, `W2c` | Feed → inserter → smelter A (iron plates) → inserter → smelter B (steel) → inserter → stockpile |

Slots that share tiles exclude each other: claiming one kills the others and frees their tiles. All slot tiles are
reserved from the start.

**Choosing slots** (round 3). A line's `slots` list (orders_data.LINES) holds hub slot names, the abstract types
`"smelter"`, `"chain"` and `"direct"`, or `"X"` for a satellite. Each entry is tried in this order:

1. **The named slot.** It is written for a patch on the line's `side` and mirrored in y when the patch lies on the
   other side. The calibrated facing layout keeps exactly these choices.
2. **Any free hub slot of the same type,** nearest to the previous slot's feed tile (or to the spine) first, up to
   6 slots. Each is claimed, then its belt link from the previous feed is routed (capped at 20 000 states).
3. **For a smelter: the line's satellite,** placed on first use. This is how two lines on the same side of the CC
   stack.

When the main belt from the spine cannot reach the chosen first slot, the whole line is planned again without that
slot, up to 4 attempts. The hub and the reserved tiles are restored between attempts.

**Rotated ore** (`match.ORE_LAYOUT = "rotated"`) puts iron and copper on the same side of an off-axis AI's CC.
Planned lines, 12-second smoke runs:

| Run | Force | Iron slots | Copper slots | Stone slot |
|---|---|---|---|---|
| Rotated 1v2 | `rts-ai-1` | `S1 S2 W2 W1 N2c X1 X2` | `E1 N1` (41 belts) | `E2d` |
| | `rts-ai-2` | `N1 N2 W1 W2 S2c X1 X2` | `E2 S1` (93 belts) | `E1d` |
| Rotated 1v3 | `rts-ai-1` | `S1 S2 W2 W1 N2c X1 X2` | `E1 N1` (87 belts) | `E2d` |
| | `rts-ai-3` | `N1 N2 W1 W2 S2c X1 X2` | `E2 S1` (48 belts) | `E1d` |

Before round 3, these copper lines failed with "no hub slot reachable". The facing layout plans exactly as before.

**Satellites** (slot name `X`, new). A satellite is an `rts-stockpile` with a smelter slot on each side, north and
south of it or west and east. It sits anywhere within 15 tiles of the CC where both smelters get the core pole's
power and the belt can reach both feeds:
- Candidates are sorted by distance to the previous feed tile.
- For each of up to 8 candidates with free tiles, the planner routes the link from the previous feed and the link
  between the two feeds. Searches are capped at 6000 states.
- As a line's first slot (expansion lines), the main route from the spine replaces the first link.

The stockpile is in the CC's logistic area, so it joins the network. The first satellite slot builds the stockpile.

**Lines.** A line is planned like this:

1. **Patch.** The nearest free patch of its ore, inside the arena, not within 45 tiles of another spawn. Another
   force's ghosts or buildings on it make it unusable.
2. **Spine.** A straight belt through the patch towards the CC: horizontal when the patch lies more east/west of the
   CC, vertical otherwise. Drills sit on both sides in pairs around a one-tile gap that holds a medium pole.
3. **Belt routes.** The short links between consecutive slots' feeds are routed first. The main belt from the spine
   to the first slot then routes around them. The router is A* over tiles with a turn penalty, and every belt faces
   the next tile. A line's last belt never feeds another belt.
4. **Power.** A greedy chain of medium poles runs from the spine to within 8.5 tiles of the CC centre, where the
   hidden core pole connects it.

**Lines on the small map.** Each spawn has iron 17 tiles forward and 10 south, copper 17 forward and 10 north, and
stone 28 forward and 16 south. The contested iron sits in the centre.

| Line | Slots, in order | Belts | Drill spots |
|---|---|---|---|
| Iron | `S1`, `S2`, `W2`, `W1`, steel chain `N2c`, satellite `X1`, `X2` | 78 | 8 |
| Copper | `N1`, `E1` | 32 | 5 |
| Stone | `E2d` | 41 | 4 |
| Iron2 (expansion, contested centre patch) | satellite `X1`, `X2` | 86–128 when it fits | 2–8 |

**Free spots.** Barracks, factory, solar and turrets go on candidate positions sorted by distance to a preferred
offset (`PREFER`, mirrored in y). A spot needs a free one-tile margin, no reserved tiles, no ore under it and
`can_place_entity`.

| Anchor | Pass | Area |
|---|---|---|
| `cc` | 1 | Within 16 tiles of the CC, inside the core pole's supply area |
| `cc` | 2 (new, when pass 1 is full) | Out to 23 tiles, inside the logistic area. A powered building needs a planned pole within supply reach (line gap and chain poles count, so buildings also go along the belt lines towards the ore). Otherwise it gets a new pole on its margin, within wire reach of the CC or of a planned pole. |
| `front` | 1 | 10–23 tiles towards the nearest enemy spawn: turrets |

The player's base at 6 minutes, normal, from `/rts-ai-map`. Upper case = built, lower case = planned, `<>^v` = belts,
`D` = extractor, `S` = smelter, `i` = inserter, `P` = pole, `K` = stockpile, `C` = CC, `B` = barracks, `F` = factory,
`T` = turret, `.` `,` `:` = iron, copper and stone ore.

```
  -15 |                    >>>>>>>>>>>>v
  -13 |                    ^iSSSiKiSSSiv  DDDddd,ddd      <- satellite: stockpile K, smelters both sides
  -12 |              >>>>>>^ SSS   SSS    DDDddd,ddd
  -10 |              ^    SSS     v<<<<<<<<<<<<<<<<<      <- copper
   -8 |          FFF ^    SSS     >>>>>>v    ddd,ddd
   -6 |          FFF ^    SSS    SSSP   v
   -5 |              ^    SSS    SSS    v        TT     <- turret towards the enemy
   -2 |              ^iSSSiK CCCC Kisssiv
    1 |              ^iSSSiK CCCC Ki<<<<<<<<<<<<<<<<<<<  <- stone into the east stockpile
    3 |              ^    SSS    SSSP              TT ^
    5 |              ^    SSS    SSS P     .......... ^
    7 |              ^<<<<<<<<<<<<<     DDD.DDDDDD.ddd^  <- iron, round the west side to the steel chain and the satellite
   10 |                           ^<<<<<<<<<<<<<<<<<<<^
```

### Construction (`construction.lua`)

- **No robots.** `commander.start` empties the CC robot inventories, so the AI's ghosts are not built by robots.
- **Plan entries.** Each entity goes planned → queued → ghost → built, or bad. Ghosts are
  `create_entity{name="entity-ghost", inner_name=...}`. Trees, rocks and items in the footprint are destroyed first.
- **Pace.** One job every `build_period` ticks per commander: 360, 180 and 120 for easy, normal and hard. A job is
  one building, or up to `small_batch` belts, inserters and poles (3, 5 and 6).
- **Paying.** A revive takes the item from the network and uses `revive{raise_revive=true}`.
- **Giving up.** A ghost that cannot be placed or revived for 60 s is dropped as `bad`.
- **Repair.** Every 10 s, built entries whose entity died are queued again.
- **Counts.** `construction.have(C, item)` counts an item in the CC networks, memoized per tick.

### Production (in `commander.lua`)

**Barracks.** Each barracks gets the unit recipe once the build order's recipe step ran, and the army rally as its
rally. Heavy kits (normal and hard) work like this:
- A heavy kit is due after every walker kit. `C.last_kit` per barracks comes from production's `on_spawned` hook.
- With steel ≥ 5 in the network, the barracks switches to heavy kits once the network iron plus the iron inside the
  force's barracks is 40 or more. A walker barracks keeps network iron near zero, so the network alone never reached
  40.
- Short of iron, it pauses (recipe cleared, its iron goes back to the network) for at most 20 s, then makes one more
  walker and tries again.
- Once on heavy kits it keeps the recipe until the heavy kit is out, or it starves for 20 s. Without this the kit's
  own pull took the network steel below 5 and the next check switched back: no heavy was ever finished.
- A busy barracks changes recipe only in the first 15 % of a craft; the ingredients go back to the network.

**Factory.**
- It makes the first item the construction queue lacks whose recipe can run: every ingredient is in the network or
  was produced in the last minute (item production statistics). If none can run, it takes the first lacking item
  anyway. Before this rule, easy ran out of copper and the factory waited forever on an extractor that needs copper,
  while the copper smelter that would end the shortage was queued behind it.
- It keeps a recipe that still makes something short and can run.
- Ammo while turrets exist and the network holds fewer than 20 magazines, at most 10 magazines per turret per minute.
  One craft is allowed, then the next waits its share of the minute, and a running ammo craft is cut off when the
  budget is spent. Uncapped, the factory made 10 magazines every 3 s, about 200 iron a minute. Gun turrets fire about
  a magazine a second at a walker that soaks hits: a probe saw three turrets take 20 s or more to kill a walker
  (93 → 12 HP).
- With nothing to make, it idles, so the iron goes to units.

### Army (`army.lua`)

**Orders through orders.lua.** `orders.move` and `orders.attack_move` take an array of `LuaEntity` as `who`, so AI
units get the same formations, re-targeting and release as player units.

**Rally.** 34 % of the way to the nearest other spawn, clamped to 20–40 tiles: 40 tiles in front of the CC on the
small map. Pool units further than 14 tiles from it are sent back, at most every 30 s per unit. Barracks rally there.

**Attack.**
- An attack starts when the pool's strength reaches the attack size, with these limits:
  - not before `first_attack` (5 / 3 / 1.5 min);
  - `attack_interval` apart (easy: 4 min);
  - not within 30 s of a retreat.
- Strength counts each unit by its health share.
- A fresh threat no longer stops an attack: the defence takes its share first.
- While a group attacks, a pool of half the attack size follows as a reinforcement.

**Target.**
- Normally: the known enemy building with the lowest distance + penalty (barracks and factory 0, turret 10, extractor
  and smelter 25, solar 35, CC 45, stockpile 60), then the nearest visible enemy unit, then a spawn guess.
- Finishing (new): an enemy with buildings but no CC and no barracks can no longer produce. Its nearest factory is
  the target (a factory keeps a side in the match), then its nearest stockpile, then any of its buildings, known or
  not. The attack size drops to 3, with no interval.

**Group upkeep.** Every 10 s a group re-targets, retreats below 40 % of its starting HP, or returns when nothing is
known. Groups disband at the rally.

**Defence.**
- `on_entity_damaged`, filtered to the 8 RTS building names, records a threat.
- A fresh threat within 55 tiles of the CC sends the pool units nearest to it: half the idle units, at least 4 (but
  never more than the pool). Easy sends at most half, rounded down. The rest stays at the rally and may attack.
- With an empty pool, 400 damage recalls the nearest attack group.

### Scouting (`scout.lua`)

- **Honest vision (easy and normal).** A spot counts as seen while any own entity is within 30 tiles, or its chunk is
  visible. Headless, chunks never become visible (see the match-flow notes).
- **Hard** sees everything.
- **Spawn guesses.** The other spawns are known from the start and dropped when seen.
- **Beaten enemies** (`scout.beaten_enemy`) are detected from the buildings registry.

### Difficulty (`orders_data.DIFFICULTY`)

| | Easy | Normal | Hard |
|---|---|---|---|
| Construction job every | 6 s, 3 small pieces | 3 s, 5 small pieces | 2 s, 6 small pieces |
| Steps in flight | 2 | 3 | 4 |
| First attack | 5 min | 3 min | 1.5 min |
| Attack size | 6, at most every 4 min | 10 | 12 |
| Defence | at most half the idle units | nearest half, at least 4 | nearest half, at least 4 |
| Heavy kits | no | alternate | alternate |
| Vision | honest | honest | full map |
| Cheats | none | none | x1.5 starting stock, mining productivity +25 %, a free unit every 4th spawn |

## Build orders

**Normal:**

| # | Step | Gate |
|---|---|---|
| 1 | Factory @cc | – |
| 2–3 | 2 extractors and 2 smelters @iron (S1, S2) | – |
| 4–5 | Barracks, walker kits | – |
| 6–7 | Stone extractor and its direct slot | – |
| 8–9 | Copper extractor and slot N1 | stone 10 |
| 10 | Army: attack at 10 | – |
| 11–12 | 3rd iron extractor and slot W2 | stone 10 |
| 13 | 2 turrets @front | 150 s |
| 14 | 4th iron slot W1 | stone 10, 210 s |
| 15–16 | 4th iron extractor and the steel chain N2c | 240 s, stone 20 |
| 17–19 | 1st satellite slot, 5th iron extractor, 2nd satellite slot | 300–330 s |
| 20 | Expand iron2 to the contested patch | 360 s |

**Easy** puts one starting smelter on iron and one on copper; copper ran out after about 35 kits otherwise. It has
one barracks, then stone, a second iron smelter, a second extractor, and one turret at 5 minutes.

**Hard** is normal's shape with:
- earlier gates;
- three turrets;
- the steel chain at 2.5 min and the satellites at 3–3.5 min;
- a second barracks at 4 min;
- the expansion at 5 min.

## Validation and measured timings

### Round 3 validation (hub slots on all sides)

Each copy is the current `mods/` with only `AUTOTEST_MATCH.opponents` and, for the rotated runs,
`match.ORE_LAYOUT = "rotated"` changed. The new check `lines_<force>` requires that iron and copper each had a
built drill and a built hub slot at some point (a force that lost its CC first is excused).

| Run | Copy | Checks | `lines_*` for every force | Result | Errors |
|---|---|---|---|---|---|
| Facing 1v1 | `build/p3-ai3` | 14/14 | iron + copper running at 133–134 s | both alive at 6 min | 0 |
| Facing 1v3 | `build/p3-ai3-f3` | 24/24 | all 4 forces by 134 s | `rts-ai-1` and `rts-ai-2` out by minute 5 | 0 |
| Rotated 1v2 | `build/p3-ai3-r2` | 19/19 | player 134 s, `rts-ai-1` 149 s, `rts-ai-2` 190 s | the AIs win at 284 s | 0 |
| Rotated 1v3 | `build/p3-ai3-r3` | 24/24 | all 4 forces by 165 s | `rts-ai-1` and `rts-ai-2` out by minute 7 | 0 |

All runs held 60 UPS (59 9xx – 60 03x ms of wall clock per 3600 ticks, four servers at once).

Meanwhile, other agents changed `prototypes/buildings.lua` and `prototypes/units.lua` in `mods/`. A rerun on a fresh
copy of that `mods/` with these AI files also passed, with zero errors:

| Run | Copy | Checks |
|---|---|---|
| Facing 1v1 | `build/p3-ai3b` | 14/14 |
| Rotated 1v3 | `build/p3-ai3b-r3` | 24/24 |

| Commanders | AI time per 3600 ticks |
|---|---|
| 2 | 126–216 ms |
| 3 | 215–252 ms |
| 4 | 285–598 ms; 598 was the minute in which expansions were planned |

Planning the three start lines takes 21–40 ms per force; the longest are the rotated copper lines.

### Round 2 runs

**Planner check** (`autotest.planner_check`, run at the start of every AI autotest):
- It plans the iron and copper lines with the real planner on a scratch surface, deleted afterwards.
- The CC is at (0, 0) with iron 28 tiles south and copper 28 tiles north, as rotated spawns put ore.
- `planner_vertical_iron` and `planner_vertical_copper` require a north-south spine, at least 2 drills and a routed
  hub slot. `planner_arena_half` requires `layout.arena_half() == storage.match.arena_half`.

Result on the current code:

```
ai autotest check planner_arena_half: PASS layout.arena_half() = 128, storage.match.arena_half = 128
ai autotest check planner_vertical_iron: PASS patch iron-ore@-6,22 at (0.0, 28.0): spine vertical (13 tiles), 8 drill spots, slots [S1 S2 W2 W1 N2c X1 X2], 85 belts, pole chain reaches the CC
ai autotest check planner_vertical_copper: PASS patch copper-ore@-5,-33 at (0.0, -28.0): spine vertical (10 tiles), 6 drill spots, slots [N1 E1], 53 belts, pole chain reaches the CC
```

A full 6-minute normal run with the check in place: 12/12 (the 9 match checks plus these 3), zero errors.

With the old line put back (`along, perp = ty, tx`), both vertical checks FAIL with the reported error instead of
crashing the game, because the planner runs under `pcall`:

```
ai autotest check planner_vertical_iron: FAIL planner error: __factorio-rts__/scripts/ai/layout.lua:421: attempt to perform arithmetic on local 'perp' (a nil value)
```

All runs below use the current `mods/` plus these AI files. Each copy differs from `mods/` only in `AUTOTEST_MATCH`
(difficulty, opponents), `autotest.DURATION`, or, for the 1v3 run, `match.AI_VERTICAL_LINES = true`. Up to seven
servers ran at once, and every one held 60 UPS: 59 9xx – 60 08x ms of wall clock per 3600 ticks.

| Run | Copy | Checks | Result | Errors |
|---|---|---|---|---|
| Easy vs easy, 6 min | `build/p3-ai2-easy` | 9/9 | both alive and producing | 0 |
| Normal vs normal, 6 min | `build/p3-ai2` | 9/9 | both alive and producing | 0 |
| Hard vs hard, 6 min | `build/p3-ai2-hard` | 9/9 | `rts-ai-1` wins at 224 s | 0 |
| 1v3 normal free-for-all, 7 min (with the grace period) | `build/p3-ai2-ffa` | 17/17 | `rts-ai-1` and `rts-ai-2` lose their CCs by minute 5; the player and `rts-ai-3` still produce | 0 |
| Easy vs easy, 12 min | `build/p3-ai2-e12` | 9/9 | both alive at 12 min (40 kits each) | 0 |
| Normal vs normal, 12 min | `build/p3-ai2-n12` | 9/9 | both alive at 12 min (~20 kits a minute each) | 0 |
| Hard vs hard, 12 min | `build/p3-ai2-h12` | 9/9 | `rts-ai-1` wins at 224 s (the same game as the 6-minute run) | 0 |

**Per minute, 6-minute runs (player side; the AI side is within a kit or two).**

| Minute | Easy kits | Normal kits | Hard kits | Easy iron smelted | Normal iron smelted | Hard iron smelted |
|---|---|---|---|---|---|---|
| 1 | 0 | 2 | 10 | 0 | 26 | 26 |
| 2 | 4 | 5 | 6 | 25 | 75 | 105 |
| 3 | 2 | 3 | 2 | 38 | 80 | 144 |
| 4 | 1 | 2 | – | 37 | 112 | – |
| 5 | 2 | 6 | – | 38 | 154 | – |
| 6 | 1 | 6 | – | 37 | 220 | – |

**Pacing as measured.**

| | Easy | Normal | Hard |
|---|---|---|---|
| Extractor + smelter + barracks | 79 s | 34 s | 37 s |
| First attack (after the commanders started) | 5:00 | 3:00 | 1:31 |

- At 6 min normal has 9 smelters including the steel chain and the first satellite, and smelts 220 iron a minute.
  Over 12 minutes normal reaches about 20 kits a minute per side, the barracks' ceiling.
- **Heavy kits.**
  - In the 12-minute normal run, `rts-ai-1` built its first heavy in minute 7 and had 3 by minute 12; the player had
    1.
  - The final hard game ended at 224 s, before its steel chain was up.
  - An earlier hard build made 1–3 heavies per side by minute 6.

**AI time.** The commanders' total time per 3600 ticks:

| Run | AI time per 3600 ticks |
|---|---|
| Easy | 101–169 ms |
| Normal | 162–204 ms |
| Hard | 189–235 ms |
| 1v3, four commanders | 279–460 ms |
| Normal minute 7, when the expansion is planned and fails | 468 ms |

**Benchmarks** (`--benchmark` of end-state saves, 3600 ticks, nothing else running):

| Save | Whole update avg / max | Mod script avg / p99 / max |
|---|---|---|
| Normal vs normal at 12 min (two full bases, ~33 units) | 0.447 / 1.676 ms | 0.0128 / 0.257 / 0.520 ms |
| 1v3 at 7 min (4 forces, 2 alive, ~40 units) | 0.347 / 1.402 ms | 0.0155 / 0.296 / 0.697 ms |

Mod script time includes every module of the mod (production, orders, units, fog, HUD), not only the AI. PHASE3
acceptance 5 (3 AI bases with 300 units) is still not measured. The 1v3 run is the closest so far, and it holds
60 UPS with a small army count.

## Deviations from the request, with reasons

1. **The construction pace counts a batch of small pieces as one job.** At easy's 6 s per job, a 78-belt iron line
   one belt at a time would take 8 minutes.
2. **The heavy-kit iron test counts the iron inside the barracks too.** With a walker barracks running, network iron
   alone never reaches 40, so the switch would never happen. When it is still short, the barracks pauses for at most
   20 s.
3. **The pace is per commander, not per CC.** A force has one CC in this match setup.
4. **No fake player index.** orders.lua takes entity lists.
5. **Honest vision is sight-based.** Chunk visibility stays false headless.

## Gotchas

1. **The CC's robots build the AI's ghosts.** Without taking them out, construction is not paced.
2. **Map-gen ore just outside the arena counts as a patch** unless the arena bounds are applied.
3. **A direct slot's feed tile is boxed in by the smelter slot it replaces.** Claim the slot before routing, and undo
   the claim when no route is found.
4. **2.0 inserter direction is the pickup side.**
5. **Network iron is a useless gate** once a barracks runs.
6. **A machine that pulls ingredients for two crafts is nearly always crafting.** "Let the craft finish" never let
   the factory leave ammo.
7. **A heavy kit's own pull takes the network steel below the switch threshold at once.** The recipe must stick until
   the kit is out.
8. **Satellite tiles must be checked against this pass's planned links too,** not only reserved tiles: a satellite
   feed once landed on a belt of the link to the steel chain.
9. **As a line's first slot, a satellite's first link must not be marked blocked:** the main route replaces it. The
   first try walled the main route in after one tile.
10. **A failed A* search is the expensive one.** It exhausts its state cap. Satellite searches are capped at 6000
    states.
11. **Gun turrets against walkers burn about a magazine a second each** while a walker soaks hits.

## Open issues

- **The expansion fails late in the game.** At 6 minutes on the small map, the belts of the main lines enclose the
  core around the CC, and the turrets close the last corridor. No belt reaches a satellite spot from the centre
  patch, and A* gives up after about 17 700 states, about 0.3 s of AI time once. It worked in a build that planned it
  at 210 s. The planned fix: let a satellite stand anywhere in the logistic area, powered from the line's own pole
  chain, or near the patch with its own stockpile. The step is skipped and logged meanwhile.
- **Easy is very slow.** It makes 1–2 kits a minute before minute 8 and never ended a match in 12 minutes. That suits
  a beginner, but easy-vs-easy is not a useful autotest.
- **Turrets against walkers.** Gun turrets fire about a magazine a second at a walker that soaks hits, and three
  turrets needed 20 s or more to finish one. That is a balance point for the prototypes owner. The AI only caps its
  ammo budget.
- **Heavy kits stay rare.** The steel chain makes about 7 steel a minute and every heavy costs 5, so heavies are at
  most about one in three kits. In practice it is fewer, because the barracks gives up after a 20 s wait for iron.
- **Free-for-all.** Two AIs next to each other on one side fight each other first. The free-for-all checks therefore
  allow a force that lost its CC early. The AI picks the nearest known target, with no alliances or threat
  assessment.
- **The AI never builds a second CC.** No CC item exists, and a lost CC ends production.
- **No GUI check** of satellites, the second ring or turret placement. They were checked through the plan map and
  through production (smelted plates, kits per minute).
- **Not measured: PHASE3 acceptance 5,** 3 AI bases and 300 units at 60 UPS.
