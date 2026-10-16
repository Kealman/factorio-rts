# Phase 3 AI commander: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Plan: `docs/PHASE3.md` ("AI architecture", "Difficulty",
"Acceptance"). Builds on the Phase 2 APIs in `docs/qa/phase2-economy-notes.md`, the orders API in
`docs/qa/phase1-selection-orders-notes.md` and the Phase 3 match flow in `docs/qa/phase3-matchflow-notes.md`.

## Status

- **Phase 4 (wave B1, 2026-10-16): doctrines, research, hubs and haulers, counters.** See the section "Phase 4" at the
  end. Not committed.
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

## Phase 4: doctrines, research, hubs and haulers, unit mix (wave B1)

Date: 2026-10-16. Plan: `docs/PHASE4.md` sections 2, 3, 4 and 6. APIs: `docs/qa/phase4-content-notes.md`,
`docs/qa/phase4-logistics-notes.md`, `docs/qa/phase4-research-notes.md`, `docs/qa/phase4-mapgen-notes.md`.
Only `scripts/ai/*` changed. Nothing is committed.

### Status

- **Every brief item is built** (B1: army pools, research, hubs and haulers, unit mix and counters, doctrines, raid
  defence and patrol, the barracks rebuild fix, hubs as finishing targets). The validated `scripts/ai/` is copied back
  into `mods/`.
- **Final runs, zero errors in all of them,** on copies of the current `mods/` (map generation with natural patches
  and moats, the balance pass, haulers on land routes) plus these AI files:

  | Run | Doctrines | Checks | Result |
  |---|---|---|---|
  | Normal 1v1 small, 480 s (`build/p4-ai-final`) | economic vs aggressive | 22/22 | both alive |
  | Same, second map seed (`build/p4-ai2b`) | economic vs aggressive | 22/22 | both alive |
  | Hard 1v1, seeded draw (`build/p4-ai2-hard`) | aggressive vs turtle | 21/21 | both alive |
  | Hard 1v1 (`build/p4-ai2-hard2`) | economic vs aggressive | 22/22 | both alive |
  | 1v3 normal small, 540 s (`build/p4-ai2-1v3`) | economic, aggressive ×2, turtle | 37/38 | 0 errors; `techs_6min_rts-ai-1` FAIL: lost its CC at 6:33 with one technology |

- **The margins are thin.** On normal the second technology lands at 4:55-5:15, the first hauler delivery at
  6:05-6:13, the first harass at about 7:00 and the economic doctrine's first heavy at 7:24. A map seed moves these by
  30-90 s. Earlier configurations of this work failed one of these checks on some seeds; "Tuning history" lists what
  traded against what.
- **60 UPS everywhere:** wall clock 59.9-60.0 s per 3600 ticks. AI time 0.05-0.11 ms per tick averaged over a minute
  with two commanders, up to 0.17 ms with four.

### Files (`scripts/ai/`)

| File | Lines | Phase 4 change |
|---|---|---|
| `deps.lua` | 9, new | Late-bound `supply`, `research`, `logistics` (see "Load order") |
| `doctrine.lua` | 77, new | The three doctrines and the seeded draw |
| `tech.lua` | 127, new | Research queue per doctrine; Supply first when capped; `C.science` for the workshop |
| `hubs.lua` | 461, new | The `hub` build-order step: patch, site, line into the hub, solar arrays, extra poles; policies, robots, hauler homes; diagnosis |
| `mix.lua` | 318, new | Desired unit mix with counters, barracks recipe rotation, unlock and supply checks, barracks yields |
| `raids.lua` | 277, new | Harass (aggressive), raid defence ("guard"), hauler-route patrol (economic) |
| `layout.lua` | +246 | Line sinks (CC or hub), `context_at` with water, hub sites, `find_spot_in`, `cover_power`, powered front spots |
| `build_order.lua` | +89 | Step-kind registry, `when.unlocked`, base counts near the CC, priority rebuild of a lost factory or barracks |
| `orders_data.lua` | +171 | `data.order(difficulty, doctrine)`: openings, doctrine steps, `UNITS_AFTER`; workshop data; coal line |
| `commander.lua` | +208 | Doctrine at start, builder / workshop / feeder factories, `recipe_for` with intermediates, ammo cap, dump lines |
| `army.lua` | +36 | Pool skips haulers and the commander; reserve raiders; raids step; attack parity; doctrine retreat and targets |
| `scout.lua` | +140 | Enemy units by kind, seen haulers, largest enemy army, harass targets, arena patch list, hubs in the finishing order |
| `construction.lua` | +34 | `construction.flowing`; `clear` areas a revive waits for (a hub's stockpile spots) |
| `init.lua` | +58 | `deps` binding, `AI_IGNORES_LOCKS = false`, `/rts-ai-doctrine`, `ai.set_doctrine`, supply-checked hard bonus, hub maps in `/rts-ai-map` |
| `autotest.lua` | +130 | Doctrines per force, 8 minutes, Phase 4 checks and minute lines, AI time per tick |

### Load order (`deps.lua`)

`control.lua` loads `scripts.ai.init` before `scripts.supply`, `scripts.research` and `scripts.logistics`. The AI needs
all three, but `research.lua` must set the `on_entity_damaged` filter after `ai/init.lua` sets its own: the filter is
one per mod, and research's is the union with the armored unit names. `require` is not allowed at run time. So
`ai/init.lua` requires the three modules at its very end, after its own `set_event_filter`, and stores them in
`ai/deps.lua`. The AI modules read `deps.<name>` at run time only.

Side effect: `logistics.lua` now loads before `fog`, `hubgui`, `hud`, `lobby`, `techgui` and `debug` instead of after
them. Its handlers do not depend on those modules. `selection`, `orders`, `camera` and `cursor` were already loaded
early through `ai/army.lua`.

`ai/init.lua` also sets `research.AI_IGNORES_LOCKS = false` at load. AI commanders research their own unlocks and obey
the barracks gate like a player, on every difficulty. Easy simply researches slowly.

### Doctrines (`doctrine.lua`)

`commander.new` draws one per AI force with `game.create_random_generator(seed)`. The seed is the nauvis map seed +
match id × 7919 + force number × 104729. The draw is logged as `[rts] ai <force>: doctrine <name> (seed N)`.
`storage.ai_meta.doctrines[force]` overrides it; `/rts-ai-doctrine <force> <name>` (admin) and `ai.set_doctrine` write
it. A running commander switches at once: build order, research order, mix and pacing change; plan, base and army stay.

| | Economic | Aggressive | Turtle |
|---|---|---|---|
| First attack (× difficulty) | 1.7: normal 5:06, hard 2:33 | 1.0: normal 3:00, hard 1:30 | 2.2: normal 6:36, hard 3:18 |
| Attack size (× difficulty) | 1.0 | 0.8 | 1.1 |
| Retreat below | 40 % (difficulty) | 60 % | 40 % |
| Target penalties | default | extractor and hub 0, smelter 5, solar 10, barracks and factory 15 | default |
| Unit mix (base weights) | walker 4, heavy 3, drone 1, raider 1, artillery 1 | drone 4, walker 3, raider 4, heavy 1 | walker 3, heavy 3, artillery 2, drone 1 |
| Research | Supply I, Unlock Heavy, Mining I, Logistics I, Hauler capacity I, Attack I, Armor I, Unlock Raider, Supply II, Mining II, Attack II, Armor II, Unlock Artillery, Attack III, Armor III | Supply I, Unlock Raider, Attack I, Armor I, Unlock Heavy, Attack II, Supply II, Armor II, Mining I, Attack III | Supply I, Unlock Heavy, Armor I, Unlock Laser, Unlock Artillery, Attack I, Mining I, Armor II, Overcharge, Supply II, Attack II |
| Unit production | after the third iron smelter | at once | after the third iron smelter |
| Expansions | hub 1 (iron) in the opening after the steel chain, whole at 3:20; hub 2 (copper) at 4:30; one hauler each | hub 1 at 5:30 | hub 1 at 5:30 |
| Defence | 2 turrets, hauler-route patrol | 1 turret, second barracks at 4:00 | 2, 4, 6 turrets; 2 laser turrets once unlocked; 2 solar arrays; coal line for explosives |
| Raids | patrol of 2 | harass every 2 minutes, 4 reserve raiders | – |
| Barracks yield above | 6 units | 6 units | 6 units |

The research orders differ from the lead's examples on purpose. Every doctrine starts with Supply I, the cheapest
technology at 10 kits, then its unlock. In the first measured runs no AI completed a technology by 6 minutes; with this
order the second one lands at 4:55-5:15 on normal. The aggressive doctrine needs Unlock Raider (20 kits) second for its
harass.

The turtle's "artillery group" is the mix weight: artillery is made once Unlock Artillery (tier 2) is researched and
explosives flow from the coal line. No AI reached tier 2 within 8 minutes.

### Build orders (`orders_data.lua` `data.order`)

`data.order(difficulty, doctrine)` is the difficulty's opening, the recipe step (unit production) after the opening
step tagged `UNITS_AFTER[doctrine]`, the army step (attack size = difficulty `attack_min` × doctrine factor), and the
doctrine's steps. Time gates are in normal seconds and scale with `TIME_SCALE` (easy 1.5, normal 1, hard 0.7). A step
with `min_difficulty` is dropped below it. Orders are cached per key.

Normal and hard opening:

| # | Step |
|---|---|
| 1-4 | Factory, 2 iron extractors, 2 iron smelters, barracks (starting stock) |
| – | Aggressive: unit production on |
| 5-6 | Stone extractor and its direct slot |
| 7 | Lab |
| 8 | Second factory: the workshop |
| 9-10 | Third iron extractor, third iron smelter (stone 10) |
| – | Economic, turtle: unit production on |
| 11-12 | Copper extractor and smelter (stone 10) |
| 13 | Fourth iron smelter (stone 10) |
| 14 | Second lab |
| 15 | Third factory: the feeder |
| 16 | Steel chain: fifth iron slot (stone 20), steel for heavies and advanced kits |
| – | Economic: hub 1, stage 1 (`OPENING_EXTRA`) |
| 17-18 | Second copper extractor and smelter (stone 10): walkers, science, circuits and heavies all take copper |

The opening has no time gates. Two failed `when` per walk end the walk, so a gated lab at 30 s kept the iron core
waiting. Easy keeps its Phase 3 opening and adds a lab at 60 s and the workshop at 120 s.

Doctrine steps (normal times):

- **Economic.** Hub 1 stage 1 sits in the opening right after the steel chain (`data.OPENING_EXTRA`): iron,
  2 extractors, 1 smelter slot, 1 solar array, planned for 2 and 2. Then hub 1 whole (2 slots, 2 solar) at 200 s,
  fourth iron extractor 150 s, 2 turrets 200 s, hard: second barracks 240 s, hub 2 (copper) 270 s, iron smelters 6
  and 7 and extractor 5 at 300-330 s. Placed after the whole opening, the hub stood at 5-6 minutes and its first
  hauler delivered after minute 8; placed before the labs and the feeder, the second technology slipped to 6:40;
  with its queue entries moved to the front, the steel chain waited and no heavy came by minute 8.
- **Aggressive.** Second barracks 240 s (at 120 s its plates never left room for science); 1 turret 180 s; fourth iron
  extractor 200 s; smelter 6 and extractor 5 at 300 s; hub 1 at 330 s; smelter 7 at 360 s.
- **Turtle.** 2 turrets 75 s; fourth iron extractor 140 s; 4 turrets 150 s; coal line 240 s; hard: second barracks
  240 s; 6 turrets and 2 solar arrays 270 s; 2 laser turrets once `rts-laser-turret` is unlocked; smelter 6 at 300 s;
  hub 1 at 330 s; smelter 7 at 360 s.

New step data: `{kind = "hub", id, ore, extractors, slots, solar, haulers, plan_slots?, plan_solar?, front?}`,
`when = {unlocked = <name>}`, and `OPENING_EXTRA[doctrine][tag]` (doctrine steps placed after a tagged opening step).
`front = true` moves the hub's queue entries ahead of everything but labs and factories; no order uses it now.
`build_order.KINDS[kind] = {satisfied, in_progress, execute, describe}` lets a module add
a step kind; `hubs.lua` registers `hub`. "cc" and "front" build steps now count buildings within 32 tiles of the CC
(`build_order.base_count`), so a hub's solar arrays do not satisfy the turtle's "2 solar arrays". Names outside the
building registry are counted from the plan.

### Research (`tech.lua`)

Every 5 s a commander with a lab keeps one technology running:

1. While the barracks are supply-capped (`C.capped`), Supply I or II comes first. A running technology of another
   kind is put back with `research.cancel` after Supply is queued; it keeps its progress.
2. Otherwise the first technology of the doctrine's order that `research.status` calls `available` and whose kit the
   force can make. Advanced kits need steel and copper in the network or produced in the last minute.
3. Otherwise any available technology, in tree order.

`C.science = {kit, want = labs × SCIENCE_PER_LAB (4), tech}` tells the workshop which kit to keep. Log lines:
`[rts] ai <force>: research <tech> (<doctrine> doctrine, N labs)` and `research <tech> done at Ns (N done)`.

### Factories: builder, workshop, feeder (`commander.lua`)

- **Builder** (the force's first factory): the construction queue's items, then ammo, as in Phase 3. A due hauler kit
  counts as construction and keeps the recipe until it is out. `commander.recipe_for(C, item)` returns the recipe to
  run now: the item's own when its ingredients are at hand or, for raw plates, flowing; else the recipe of a missing
  intermediate from `balance.intermediates` (gear, cable, circuit, explosives), depth first. Ammo is capped at 10
  magazines per turret and 30 in all per minute: a turtle's six turrets under fire took every plate in a 1v3 run.
- **Workshop** (the second). Its demands come in groups that take turns of at most `WS_TURN` (20 s, round robin)
  while more than one group is active:

  | Group | Demand |
  |---|---|
  | science | Gears for basic kits (or circuits for advanced ones) in batches, then the running research's kit, up to 4 per lab |
  | circuits | 10 → 20 circuits while raiders are wanted and unlocked, laser turrets are queued, or hauler kits are wanted |
  | explosives | 10 → 20 explosives while artillery is wanted and unlocked |

  With a strict priority the always-short science stock kept the aggressive doctrine's workshop from ever making a
  circuit, so no raider came after Unlock Raider.
- **Feeder** (the third). Gears for basic kits (or circuits for advanced ones) up to two batches ahead, else what the
  workshop demands that the workshop itself is not making. Alone, the workshop spent half its time on gears, about
  6 kits a minute; with the feeder it makes kits back to back, 10-11 a minute.
- Workshop and feeder never craft construction items: with plates short, three factories crafting buildings in
  parallel only split the plates, and a lab took three minutes.

**Plate allocation.** `production.lua` serves the oldest-starved consumer with up to two crafts' worth, and a consumer
short of one item reserves it. The workshop's 2-plate gears came one every ~20 s behind the builder's 20-40-plate
bites and the barracks. Two measures, both with duty caps:

- **Barracks yield** (`mix.lua`). While a factory has starved of plates for 2 s on workshop work (science kits, hauler
  kits and their intermediates), the barracks clear their recipe and their ingredients return at once. Conditions: the
  army holds `yield_army` (6) units, no base threat is fresh, a unit spawned in the last 40 s, and the barracks yielded
  less than 60 % of the last minute.
- **Builder steps aside** (`commander.lua`). After 4 s of workshop starvation the builder's recipe is cleared for one
  pass, at most 35 % of each minute. It never steps aside while it makes a hauler kit.

### Hubs and haulers (`hubs.lua`, `layout.lua`)

The `hub` step:

1. **Patch.** Every iron or copper patch of the arena within 150 tiles of the CC that has at least 30 tiles, lies at
   least 45 tiles from the CC (outside the main) and at least 50 tiles from every other force's spawn, CC and hub, and
   is at most 15 tiles farther from us than from the nearest other base. The step's ore first, then the nearest. A
   patch with another force's building or ghost within 8 tiles is skipped. `storage.ai_meta.patch_claims` keeps two
   AI commanders off one patch. On the map-generation tree this picks the natural, 52-65 tiles out; on the open map
   the middle patches.
2. **Site.** Candidate hub centres 7-16 tiles from the patch's bounding box, nearest to the CC first. The centre must
   be at least 42 tiles from the CC along x or y: logistic areas are squares, and a hub 45 tiles away in a straight
   line but 36 along x joined the CC network, so its hauler never had anything to fetch. It must also be 24 tiles from
   other hubs. The site box (the hub, its two stockpiles, the four smelter slots with feed tiles, a margin) and the
   solar box south of the hub must be free of entities, water, ore and reserved tiles, and
   `can_place_entity("rts-hub")` must hold.
3. **Line.** `layout.plan_line` takes a **sink**. The hub sink's frame has its origin 2 tiles south of the hub, so the
   hub's stockpiles at (±3.5, 0.5) sit where the CC frame's north stockpiles are, and the "1" slots (E1, W1, N1, N2)
   feed them unchanged. The spine points at the hub, slots are the abstract `smelter` type, there are no satellites,
   and the pole chain ends within 8 tiles of the hub centre: the hub's hidden pole has wire reach 9 and snaps up to
   0.7 tiles off centre.
4. **Power.** The hub's own 300 kW plus `solar` solar arrays south of it. A column under the hub stays free, because
   haulers stop there. `layout.cover_power` adds a medium pole next to any slot machine that neither the hub's 16×16
   supply area (counted as ±7.5) nor the line's poles reach. E1 and W1 input inserters usually need one.
5. **Build.** The hub first, then the drills with the spine, belts and poles, the slots, the extra poles and the solar
   arrays, all by the usual paced revive paid from the CC network. `logistics.lua` places the hub's stockpiles when
   the hub is built and moves a blocked one up to 4 tiles; the smelters' output inserters then drop plates on the
   ground. So trees, rocks and items on the two stockpile tiles are removed when the step runs, and the hub is revived
   only while no unit stands on them: own units there are sent to the rally point (`clear` areas of a plan entry,
   `construction.lua`).

Once the hub stands, `hubs.step` clears its keep thresholds, sets `export_above <plate> = 20`, takes its 10
construction robots out and makes the CC keep 400 of the plate. It logs where the stockpiles ended up. When the hub's
line has a built drill and a built slot, the hub's `haulers` join `C.want_haulers`. The builder makes the kits,
`logistics.lua` deploys them, and every auto hauler of the force is homed at the CC with `logistics.set_home`.
Deliveries are read from `logistics.stats(force).delivered`. `hubs.diagnose` logs every hub line's machines by entity
status at the end of an autotest, and `/rts-ai-map` adds a map of each hub.

Every planning context now marks water tiles (`find_tiles_filtered{collision_mask = "water_tile"}`) as occupied,
for the generated lakes and moats. `layout.context_at(C, surface, frame, radius)` plans around any frame.

### Unit mix and counters (`mix.lua`)

Kinds come from `balance.units`: tier-1 units with a barracks kit and no `made_by`. The desired weights are the
doctrine's mix plus counters. For every enemy kind seen in the last minute (`C.seen`) and every known enemy turret,
laser turret and wall, each own kind that lists it under `counters` or `strong` gains `COUNTER_GAIN` (8) × that kind's
share of what was seen. With the current `balance.lua`: drones against artillery, haulers and raiders; walkers against
drones and raiders; heavies against walkers and drones; artillery against heavies, turrets, laser turrets and walls;
raiders against artillery and haulers.

A harassing doctrine's raider weight is tripled (`RESERVE_BOOST`) while it has fewer raiders than its reserve, and so
is the weight of a heavy, raider or artillery kind the force has no unit of yet (`FIRST_BOOST`): the economic
doctrine's first heavy came 2-3 minutes after Unlock Heavy behind walkers and drones, which take plates in smaller
bites. Each barracks makes the available kind furthest below its desired share. Kinds being made count as present,
so two barracks diversify. It keeps the kind until a unit of it spawned. Heavies, raiders and artillery rest for
30 s after starving for 20 s; walkers and drones never rest. A kind is available when research unlocked it, every
kit ingredient is in the network or was produced in the last minute, and its supply cost fits under the cap
(`supply.get`). With no room for any kind the barracks stop (the recipe is cleared once the output is empty),
`C.capped` is set and `tech.lua` researches supply. The hard bonus unit checks `supply.can_spawn` too.

### Raids (`raids.lua`)

| Group | Trigger | Behaviour |
|---|---|---|
| harass | Aggressive doctrine, every 2 minutes from minute 2, at least 3 raiders among the reserve and the pool | 3-4 raiders attack the nearest seen enemy hauler, else a known hub, else an outlying extractor, smelter or solar array (26 tiles from enemy CCs and known turrets), else a pole next to one. With nothing known they go to the patch where an enemy expansion would be. Home below 50 % hit points or after 75 s; the next target within 45 tiles when the first is gone. |
| guard | An own hauler loses health beyond 30 tiles of the CC (polled every run), or an extractor, hub, smelter, stockpile or solar array beyond the base radius (55) is damaged | The 4 pool units nearest to it attack-move there; home 15 s after the last alarm |
| patrol | Economic doctrine, once a hub stands | 2 units attack-move between the route's midpoint and a point 10 tiles before the hub, one leg every 25 s, refilled from the pool |

The doctrine's reserve raiders (4) stay out of defence, guard, patrol and attack groups; only the harass takes them.

### Army changes (`army.lua`, `scout.lua`)

- **Pool.** Units of kind `hauler` (logistics) and `commander` (abilities) never join the pool, a group or the strength.
- **Parity.** `scout.step` remembers the largest enemy army seen in one scan for 3 minutes (`C.enemy_army`). A
  non-finishing attack also needs 80 % of it. Without this the aggressive doctrine fed its army piecemeal into a
  defending one and lost its base by minute 6.
- **Doctrine settings.** `cfg.retreat_ratio` and `cfg.target_penalty` come from the doctrine. `TARGET_PENALTY`
  gained `lab` 15, `hub` 20, `laser-turret` 12, `steam-plant` and `radar` 30, `accumulator` 40 and `wall` 90.
- **Walls.** Every wall segment is a registered building of kind `wall` (HUD agent, `buildings.lua`). Attacks prefer
  what a wall protects (penalty 90), known walls count towards artillery in the mix, and with honest vision a scan
  checks at most 50 enemy wall segments (`scout.WALL_CHECKS`), so a long wall does not make every scan expensive. The
  AI builds no walls. Kinds used in steps and counts: `laser-turret`, `lab`, `hub`; `turret` is the gun turret only,
  so the magazine budget is unaffected.
- **Finishing** targets factories, then hubs, then stockpiles.
- **Priority rebuild.** This fixes the Phase 3 1v3 failure `attack_rts-ai-1` ("never reached attack size after losing
  its barracks"). When the force had a factory or a barracks and has none left, `build_order.priority` queues one,
  the factory first because it makes the barracks item. The entry moves to the front of the construction queue, so the
  factory makes its item next. Log: `priority rebuild: rts-barracks at (x, y) (the last one was lost)`.

### APIs used

| Module | Calls |
|---|---|
| `research` | `queue`, `cancel`, `status`, `list`, `has`, `is_unlocked`, `lab_counts`; `AI_IGNORES_LOCKS` |
| `supply` | `get`, `can_spawn` |
| `logistics` | `set_policy`, `policy`, `haulers_of`, `set_home`, `stats`, `entry_for_hub`, `HUB_STOCKPILES` |
| `balance` | `units` (kind, kit, made_by, tier, supply, cost, counters, strong), `intermediates` |
| `buildings` | kinds `lab`, `hub`, `laser-turret`, `wall`; `kind_of`, `for_force`, `count`, `main_cc` |
| `production` | `set_recipe`, `on_spawned`, `KITS`; records' `pull_state`, `starved_since`, `spawned` |
| vanilla | `LuaForce.current_research`, `research_unit_ingredients`, `get_item_production_statistics`, `LuaSurface.find_tiles_filtered`, `game.create_random_generator`, `LuaEntity.status` |

### Validation

Each run is a copy of `mods/` plus `mods/mod-list.json` (Space Age on). Copies differ only in `debug.lua`
`AUTOTEST_MATCH` (difficulty, opponents) and `ai/autotest.lua` `DOCTRINES` (nil = the seeded draw). Every map creation
draws a new seed. Runner: create, start the server, stop at `ai autotest summary`.

```sh
rm -rf build/p4-ai-final && mkdir -p build/p4-ai-final && cp -R mods/factorio-rts mods/mod-list.json build/p4-ai-final/
tools/headless-run.sh 520 '\[rts\] (ai|research|logistics: hub)' build/p4-ai-final
```

New autotest checks (each excused for a force that lost its CC before the deadline, which the line says):
`lab_<force>`, `techs_6min_<force>` (2 technologies by 6:00), `kinds_8min_<force>` (3 unit kinds spawned by 8:00),
`hub_<force>` (economic: a hub and a hauler delivery), `harass_<force>` (aggressive: a raider harass). The Phase 3
`attack_<force>` check now also passes when an economic or turtle commander held (its pool stayed below its attack size
or 80 % of the enemy army it saw) or when its first attack was not due yet; the line says which.

**Phase 4 checks, final runs:**

| Run | Force | Lab | Technologies (time) | Hub, first delivery, plates by 8:00 | Harass | Kinds by 8:00 |
|---|---|---|---|---|---|---|
| Normal (`p4-ai-final`) | economic | 1:41 | Supply I 3:40, Unlock Heavy 4:55, Mining I 7:00 | natural at (-40, 0), 52 tiles out; built 4:18; 6:13; 97 | – | drone, walker, heavy (7:24) |
| | aggressive | 1:16 | Supply I 3:20, Unlock Raider 5:15 | – | 1 at 7:03 (3 raiders on the hub) | drone, walker, raider (6:15) |
| Normal (`p4-ai2b`) | economic | 1:41 | 3:40, 4:55, 7:00 | (-41, 0); 4:18; 6:05; 102 | – | heavy at 7:25 |
| | aggressive | 1:16 | 3:20, 5:15 | – | 1 at 6:57 | raider at 6:20 |
| Hard (`p4-ai2-hard`) | aggressive | 0:43 | 2:40, 4:20 | – | 1 at 6:14 | raider at 5:29 |
| | turtle | 0:43 | 2:15, 3:30, Armor I 5:10 | (42, 0) at 6:26 | – | heavy at 4:29 |
| Hard (`p4-ai2-hard2`) | economic | 0:43 | 2:15, 3:55, 7:05 | 2:44; 4:57; 255 by 8:00 (2 hubs, 44 trips) | – | heavy at 5:46 |
| | aggressive | 0:43 | 2:45, 4:25 | – | 1 at 6:15 | raider at 4:49 |
| 1v3 (`p4-ai2-1v3`) | economic (player) | 1:40 | 3:45, 5:00, 7:35 | 4:10; 6:06; 115 | – | heavy at 7:09 |

**AI time** (`[rts] ai perf minute N` lines; the AI time per tick is the minute's total over 3600 ticks):

| Run | Commanders | AI time per minute | Per tick | Wall clock per 3600 ticks |
|---|---|---|---|---|
| Normal 1v1 (two runs) | 2 | 188-397 ms | 0.05-0.11 ms | 59.91-60.01 s |
| Hard 1v1 (two runs) | 2 | 204-368 ms | 0.06-0.10 ms | 59.91-60.01 s |
| 1v3 normal | 4 | 431-616 ms | 0.12-0.17 ms | 59.93-60.00 s |

One-off costs in a single tick: planning a hub 19-52 ms (16 plans), the start lines 27-49 ms per force.

**Also run, earlier builds of this work:** easy 1v1 (turtle vs economic), zero errors, 14/21: the lab came at 4:30 and
Supply I at 7:00, so the Phase 4 checks are not met on easy; pacing by design. Not rerun on the final build.

**Priority rebuild** triggered twice in the 1v3 run (`priority rebuild: rts-barracks ... (the last one was lost)` at
3:21 and 6:28); both forces lost their CC within seconds, so a completed rebuild was not observed.

### Tuning history (what traded against what)

Every early step competes for the same plates. Measured on normal, one variable at a time:

| Change | Gained | Lost |
|---|---|---|
| Phase 3 order plus a lab and a workshop as doctrine steps | – | no technology by 6:00 in any run |
| Lab and workshop in the opening, Supply I first | second technology 5:40 | – |
| Feeder factory, workshop groups in turns | second technology 4:55-5:15; raiders after Unlock Raider | – |
| Hub 1 after the whole opening | – | hub built at 5:11-6:18, no delivery by 8:00 on two seeds |
| Hub 1 right after "core" (third smelter) | hub built at 4:36 | second technology 7:00 |
| One more step in flight for the economic doctrine | delivery 6:14 | second technology 7:10 |
| Hub 1 stage 1 after the steel chain, entries to the front of the queue | delivery 6:26-6:29 | steel chain late, no heavy by 8:00 |
| **Final:** hub 1 stage 1 after the steel chain, labs and feeder before it | delivery 6:05-6:13, second technology 4:55 | heavy at ~7:25 |
| Circuits ahead of Unlock Raider | – | Unlock Raider at 7:45 (reverted) |
| First unit of a fresh kind ×3 weight | first heavy 7:05-7:25 instead of 7:47-7:58 | – |

### Gotchas

1. **`require` is not allowed at run time,** and the damage filter is one per mod. Hence the late `deps` binding.
2. **Plates decide everything.** The Phase 4 investments (two labs, two more factories, a hub with its line and solar
   arrays, hauler kits, science) compete with the barracks for 75-190 plates a minute. Early steps took 40-80 s each
   while iron ran out. The fixes were the order (lab, workshop and the iron core from the starting plates; units after
   the third smelter for economic and turtle) and the duty-capped yields.
3. **A time gate in the opening stops the walk.** Two failed `when` per walk end it.
4. **Production serves the oldest-starved consumer with two crafts.** Small recipes (gears, circuits) lose to
   20-40-plate bites. Strict workshop priority starved circuits, so the groups take turns.
5. **Logistic areas are squares.** A hub must clear the CC's 50×50 area by Chebyshev distance, not straight-line
   distance.
6. **`logistics.lua` moves a hub stockpile whose spot is taken** when the hub is built: by a tree or rock (planning
   treats them as free) or by a unit standing there. The west stockpile, on the side the army comes from, moved in
   both hubs of one run, and the smelters' output inserters then dropped plates on the ground.
7. **The hub's hidden pole snaps 0.7 tiles off the hub centre.** The pole chain targets 8 tiles, not the CC's 8.5, and
   E1 and W1 input inserters need an extra pole.
8. **A hauler kit made before the hub's line runs** takes the plates the hub's own parts need.
9. **Every map creation draws a new seed.** The generated terrain, the hub sites and the doctrine draws change from
   run to run, and so do the timings. One run per configuration is a sample, not a measurement.

### Open issues

- **Small armies.** At 8:00 on normal each side fields 6-8 units (economic: walker 4, drone 1, heavy 1). Phase 3
  normal had about 20. Plates now go to labs, two more factories, hubs, haulers and science first. This is a balance
  call for the lead: starting plates, kit or building costs, or fewer AI investments.
- **Thin margins** (Status): a slow seed can push the second technology, the first delivery, the first harass (about
  7:00 on normal, needs 3 raiders at once) or the first heavy past its deadline. "Tuning history" shows the
  trade-offs; no order improved all four at once with the current costs.
- **Free-for-all.** Aggressive AIs in a 1v3 sometimes lose their CC before their second technology (1 of 4 forces in
  the final run). The economic player's first heavy came at 7:09.
- **No AI reached tier 2** within 8 minutes: advanced kits, laser turrets, artillery and the turtle's artillery group
  are exercised by code paths only, not by a run.
- **Harass raids are short.** Raiders come home after about 10 s at half their hit points; the harass happens, but
  costs the defender little so far.
- **Hub planning costs 19-52 ms in one tick,** once per hub; the start lines 27-49 ms per force. A split over several
  ticks would remove the hitch.
- **Economic and turtle may not attack within 8 minutes** on normal; the attack check allows it ("held").
- **`logistics.lua` loads earlier** than `control.lua` lists it (see "Load order"). Nothing depends on the old order
  today.
- **Not tested:** a GUI session, a human opponent, medium and large maps, easy on the final build, more than 8 minutes,
  `/rts-ai-doctrine` from the console (the autotest calls `ai.set_doctrine`).
