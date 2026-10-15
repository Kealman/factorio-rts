# Phase 3 match flow: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Plan: `docs/PHASE3.md` ("Match flow", "Difficulty",
"Acceptance"). AI API: `docs/qa/phase3-ai-notes.md`. Phase 2 match API: `docs/qa/phase2-economy-notes.md`. Locale
conventions: `docs/qa/phase2-polish-notes.md`. QA protocol: `docs/qa/phase3-protocol.md`.

## Status

- **The match flow works end to end in the GUI.** The start dialog shows on join. Start builds a fresh arena and
  starts the AI. The in-match menu opens and resumes. Destroying the AI gives the results frame. Restart goes back to
  the start dialog. Ctrl+Shift+R restarts the current match.
- **The AI autotest passes on the new arena.** 1v1 normal on the small map: 9/9, zero errors, 60 UPS. 1v2: see
  Validation.
- **Fog of war is verified on the minimap.** The GUI run's minimap is black except around the player's base, and
  the log reads `rts-player charted 20 visible 20 of 64`. Script screenshots render the world without fog, so the
  world view in remote view is not verified. Protocol steps 5, 6 and 9 check it with a real screen.
- **Contested iron is back in every match size,** since p3-ai's fix (commit 1051c60). Vertical mining lines and the
  `storage.match.arena_half` contract are in `mods/`.
- **Per-spawn ore is rotated towards the centre by default** (`match.ORE_LAYOUT = "rotated"`). The AI's hub slots
  handle it since commit 33d5b40. `"facing"` (east/west) stays as an option. See "Final runs after the AI fix".
- **Nothing is committed.**

## Files

| File | Change |
|---|---|
| `scripts/match.lua` | Rewritten. Lobby phase, the per-match arena surface, free-for-all forces, spawns on a circle, ore per spawn and contested ore, out / win / lose for N forces, per-force counters, the legacy wave brain kept behind `enemy_brain = "waves"` |
| `scripts/lobby.lua` | New. Start dialog, in-match menu, results frame; `start_match`, `back_to_lobby`, `restart_current`; `/rts-match`; the `rts-menu` input |
| `scripts/fog.lua` | New. Script charting around own buildings and units, a stats line, the end-of-match reveal |
| `scripts/camera.lua` | Two small edits. `enter_remote`, used by setup, jumps and the controller guard, now targets `match.view_surface()` instead of the physical surface. `camera.setup`, the join flow, parks the god body on the lobby surface. |
| `scripts/hud.lua` | Minimal. Minimap zoom from the arena size; "Enemies seen: N" (only enemy units in sight, "?" for none; the real total after the match); selection panel and build menu hidden in the lobby; lobby message; a Menu button that calls `lobby.toggle_menu` |
| `scripts/debug.lua` | Autotest match start, `/rts-qa-reset` restarts the match, `/rts-kill-force`, the match-flow self-test steps, dump lines for N forces |
| `scripts/util.lua` | `util.ENEMY_FORCE = "rts-ai-1"`, `util.LOBBY_SURFACE`, and `util.surface()` returns the current arena |
| `control.lua` | Requires `scripts.fog` after `scripts.ai.init` and `scripts.lobby` after `scripts.hud` |
| `prototypes/inputs.lua` | One entry: `rts-menu` on F10. The lead's task asked for this input; a custom input exists only in the data stage. |
| `locale/en`, `locale/ru` | 42 new `[rts]` keys and `controls.rts-menu`, identical key sets and parameters (227 keys each) |

No file in `scripts/ai/` and none of `orders.lua`, `selection.lua`, `production.lua`, `economy.lua` or `buildings.lua` was
edited. The AI planner's arena bounds come from `storage.match.arena_half` (see "AI planner limits").

## Match lifecycle

| Phase | What exists | Who moves on |
|---|---|---|
| `lobby` | The lobby surface only; the start dialog is open | Start match, `/rts-match`, `/rts-qa-reset`, or the headless autotest at tick 120 |
| `setup` | Only inside `match.start`, within one tick | `match.start` itself |
| `running` | Arena, forces, bases, armies, AI commanders, fog | A force goes out, or Restart / QA reset |
| `ended` | As running; AI commanders idle, no waves, arena fully charted | Restart / QA reset |

**Surfaces.**
- `rts-lobby`. Created once: a 64×64 map paved with `out-of-map` tiles, so it is black. Every player's characterless
  god body is teleported there on setup, so nauvis is never shown, not even for the tick between leaving and
  re-entering the remote view.
- `rts-arena-<n>`. One per match; n counts the matches in the save. Map gen has no autoplace, lab tiles, no cliffs and
  no enemies, and the map size equals the arena size. Every arena tile is then set to `grass-1`, and everything outside
  the arena is out-of-map. A small arena takes 79 ms to build.
- **Nauvis is not touched.**

`game.delete_surface` only queues the deletion for a later tick, so a restart in the same tick must use a new name.
The old arena is deleted after the players' cameras have moved off it. Two restarts in one tick (the legacy autotest
does this) went through without errors.

**Teardown** (`match.teardown`) runs these steps:
1. It stops every AI commander.
2. It drops the wave group and despawns all units.
3. It destroys every registered building and its CC core parts on the old arena, so registry queries in the same tick
   no longer find the old match.
4. It returns to the lobby phase.

`lobby.lua` then resets every player's selection, control groups and armed attack-move, moves the cameras, rebuilds
the HUD and deletes the old surface.

### Spawns and ore

Spawns sit on a circle of radius size/2 − 40. The player is at 180°. The AIs are at the angles in
`match.AI_ANGLES`: 0° for one AI, ±70° for two, −60°, 0° and +60° for three. These angles avoid exact ties between
neighbours. The AI commander faces its nearest other spawn along x, and on a tie table order would decide.

| Map | Opponents | CC centres (facing) |
|---|---|---|
| Small 256×256 (radius 88) | 1 | player (−88, 0) +x; AI 1 (88, 0) −x |
| | 2 | player (−88, 0) +x; AI 1 (30, −83) −x; AI 2 (30, 83) −x |
| | 3 | player (−88, 0) +x; AI 1 (44, −76) +x; AI 2 (88, 0) −x; AI 3 (44, 76) +x |
| Medium 384×384 (radius 152) | 1 | player (−152, 0) +x; AI 1 (152, 0) −x |
| | 2 | player (−152, 0) +x; AI 1 (52, −143) −x; AI 2 (52, 143) −x |
| | 3 | player (−152, 0) +x; AI 1 (76, −132) +x; AI 2 (152, 0) −x; AI 3 (76, 132) +x |
| Legacy 160×160 (waves brain) | 1 | player (−60, 0) +x; AI 1 (60, 0) −x (the Phase 2 geometry) |

The facing in the table is the AI commander's own rule, towards the nearest other spawn along x. The match uses it
only for the legacy template.

**Ore per spawn** (`match.ORE_LAYOUT`). Each force gets `match.ORE_PATCHES`, the Phase 2 table: iron (17, ±10),
copper, stone and coal. `dx` runs along the force's front and `dy` along its side axis. The starting army
(`match.army_point`, 14 tiles ahead) uses the same axes.

| Layout | Front and side axes |
|---|---|
| `"rotated"` (default) | Front from the CC towards (0, 0) (`match.front`). Side perpendicular, pointing south (east when the front is due north or south). |
| `"facing"` (option) | Front along x, towards the force's facing (the AI commander's rule). Side +y: iron south of the CC, copper north. The AI hub was first calibrated on this layout. |

**History of the default.** Before p3-ai's commit 33d5b40, `"rotated"` put iron and copper on the same side of an
off-axis AI's CC in 1v2 and 1v3. That AI's copper line then found no hub slot (`line copper unavailable: no hub slot
reachable`), and it smelted no copper (see "Final runs after the AI fix"). For a while the lead made `"facing"` the
default. 33d5b40 gives the hub slots on all four sides, and `"rotated"` is the default again. The player's layout is
the same in both modes, and so is any AI on the x axis, so 1v1 does not change.

Iron patch centres:

| Map | Opponents | `"facing"` | `"rotated"` (default) |
|---|---|---|---|
| Small | 1 | player (−71, 10); AI 1 (71, 10) | same |
| | 2 | AI 1 (13, −73); AI 2 (13, 93) | AI 1 (34, −64); AI 2 (15, 70) |
| | 3 | AI 1 (61, −66); AI 2 (71, 10); AI 3 (61, 86) | AI 1 (44, −56); AI 2 (71, 10); AI 3 (27, 66) |
| Medium | 2 | AI 1 (35, −133); AI 2 (35, 153) | AI 1 (56, −124); AI 2 (37, 130) |
| | 3 | AI 1 (93, −122); AI 2 (135, 10); AI 3 (93, 142) | AI 1 (76, −112); AI 2 (135, 10); AI 3 (59, 122) |

In both layouts, a check script found no overlapping patch and no patch outside the arena. No patch lies within 45
tiles (`HOSTILE_RADIUS`) of another force's CC.

**Contested ore.** Two patches near the centre, 2500 per tile: iron 14×14 at (0, −24) and copper 10×10 at (0, 24).
They are placed in every match size except legacy. `match.AI_VERTICAL_LINES = false` would bring back the stone
stand-in for 1v2 and 1v3.

**Starting state, the same for every force.** `buildings.place_cc` with `match.STARTING_STOCK`: 200 iron, 100 copper and
the Phase 2 building stock. 6 walkers stand 14 tiles in front of the CC, towards the centre. Hard AI adds its own ×1.5 stock.

**Forces.** `rts-player` (blue) and `rts-ai-1` (red), `rts-ai-2` (yellow) and `rts-ai-3` (green). Every pair is
enemies, with no cease-fire: free-for-all. `share_chart` is off, and there is cease-fire with the vanilla `enemy`,
`player` and `neutral` forces. No team mode was built.

### AI planner limits (for the lead and p3-ai)

1. **Vertical mining lines crash.** `ai/layout.lua` `spine_candidate` line 412 reads `along, perp = ty, tx`, which are
   undefined globals. Any patch that lies more north/south of a CC than east/west stops the game with
   `layout.lua:414: attempt to perform arithmetic on local 'perp' (a nil value)`. The first 1v2 run hit it at 210 s,
   through `expand iron2` picking the contested iron patch.
   - **Fixed by p3-ai in commit 1051c60.** `match.AI_VERTICAL_LINES` is now true. Hub slots on all four sides came
     in commit 33d5b40, and `"rotated"` ore is the default since then.
   - Before the fix, the flag (false) swapped the contested iron for stone in 1v2 and 1v3.
2. **`ai/layout.lua` `ARENA_HALF` was a constant 80.** The AI plans nothing outside it, and the small map's CCs are at
   ±88.
   - The lead set a contract (2026-10-15): `match.lua` sets `storage.match.arena_half` (the size / 2) at match start,
     and `ai/layout.lua` reads it, with a fallback of 80. `match.lua` no longer writes the module field.
   - The validation runs above wrote the module field directly, an earlier version of this code.
   - **p3-ai's side is in `mods/` (commit 1051c60).** In the gap before it landed, the AI planned no lines on the
     small map: `line iron unavailable: no hub slot reachable`, with no script errors.
3. **`expand iron2` never succeeds in practice.** In the 1v1 run both AIs found the contested iron patch, then logged
   `line iron2 unavailable: no hub slot reachable for iron-ore@-7,-28`. This matches the AI notes' "hub is full".

## Lobby, menu and results

All three are centred frames in `player.gui.screen` (`auto_center`). Clickable elements are named `rts_lobby_*`, and
the click handler is `lobby.on_click`.

| Frame | Content | Buttons |
|---|---|---|
| `rts_lobby` "Factorio RTS: new match" | Drop-downs for opponents (1–3), difficulty (Easy / Normal / Hard, with the PHASE3 difficulty table as tooltip) and map size (Small 256×256 / Medium 384×384); a rules hint | Start match (green) |
| `rts_menu` "Menu" | Config line ("1 opponent · Normal · Small (256×256)"), match time | Restart (back to the start dialog), Resume |
| `rts_results` "Match over" | Victory / Defeat / Draw in colour, the long result text, match time, config, and a table per force: units built / lost, buildings built / lost, status (Winner / Still in / Out at mm:ss) | Restart, Continue (close and look around) |

**Behaviour.**
- The drop-down choices are shared by every player (`storage.lobby.pending`). In multiplayer only admins can start or
  restart.
- The menu and the results frame are `player.opened`, so Escape closes them. The start dialog stays open on Escape.
- **Menu entry points:**
  - the HUD's **Menu** button, at the right end of the strip's first row;
  - F10 (`rts-menu`);
  - in the lobby, both are no-ops, because the dialog is already up.
- A player who joins during the lobby gets the dialog. A player who joins after the end gets the results frame, unless
  they closed it.

## Fog of war (`fog.lua`)

**Measured with a GUI probe on 2.0.77.**
- `LuaForce.chart(surface, area)` makes chunks charted and visible. Visibility ends about 600–660 ticks later
  (visible at tick 660 after a chart at 60, not at 720).
- An `rts-walker` (spider unit, `radar_range = 1`) keeps its chunks charted and visible continuously, with no script.
- In remote view, only visible chunks render live entities. Other charted chunks show the chart.

**Design.**
- At match start, 64 tiles around the CC are charted: 20 chunks.
- Every 300 ticks, `fog.lua` re-charts the chunks within 40 tiles of each own building and 24 tiles of each own unit.
  Own bases therefore never fall into fog.
- Charts are not shared, and the forces are not friends.
- Only forces that people look at are charted: `rts-player` and any force with players. AI forces need no chart;
  their scouting is sight-based, and hard AI sees everything by itself.
- At the end of a match the whole arena is charted for the human forces.

**The minimap** is the HUD's existing `minimap` element. It shows the force's chart, now zoomed to fit the arena: 0.81
for small, 0.55 for medium.

**Cost.** 12–21 `chart` calls per 5 s for one base and its army.

**Headless.** No chunk is ever charted (`fog: ... charted 0 visible 0`), as the AI notes found. The code runs, and the
GUI run shows the chart: `rts-player charted 20 visible 20 of 64`.

**Screenshots ignore fog.** `game.take_screenshot` renders the world as it is, enemies in fog included. Fog can only be
judged on the minimap in a screenshot, or by a person looking at the screen.

## Out, win, lose, counters

- **Out.** Every 60 ticks each force is checked with the existing rule: no CC, barracks or factory, and no units.
  - An out AI is removed from the AI tick (`ai.stop_force`).
  - Everyone gets "[RTS] AI 2 is out." while the match goes on.
- **The match ends for the human force.**

  | Case | Winner | Result for `rts-player` |
  |---|---|---|
  | Every AI is out | `rts-player` | Victory |
  | `rts-player` is out, one AI left | that AI | Defeat |
  | `rts-player` is out, several AIs left | `"ai"` | Defeat |
  | Both in the same check | `"draw"` | Draw |

  `match.result(force)` derives the result from `phase` and `winner`, as before.
- **When it ends:**
  - each player gets the localised result line (`rts.match-victory`, `-defeat` or `-draw`);
  - the results frame opens;
  - fog reveals the arena;
  - the wave brain stops, and AI commanders idle (`commander.run` returns once the phase is `ended`).
- **Counters** (`match.stats(force)`), per match, kept by `match.lua`:

  | Counter | Source |
  |---|---|
  | `units_built` | `production.on_spawned` |
  | `units_lost` | `units.on_removed` while the unit entity is still valid, which only a death leaves |
  | `buildings_built` | `buildings.on_added` after setup |
  | `buildings_lost` | `on_entity_died` of an RTS building |

  The starting CC, stockpiles and walkers are not counted. AI hard bonus units are not counted either, because they
  are spawned outside the barracks callback.

## Config and autotests

`storage.match.config = {opponents, difficulty, size, enemy_brain = "ai", enemy_difficulty, first_wave_ticks,
wave_period_ticks}` (`match.normalize_config`). `enemy_difficulty` mirrors `difficulty`, because `ai.init` reads it.

**Headless autotest.** At tick 120 with nobody connected, `debug.lua` starts `AUTOTEST_MATCH` through
`lobby.start_match`: 1v1, normal, small, `enemy_brain = "ai"`.
- `storage.debug.autotest_match`, if set earlier, overrides it.
- A test copy may edit the `AUTOTEST_MATCH` line. The 1v2 run used `sed` on the copy: `opponents = 2`.
- With the AI brain, every match force is an AI commander: `ai/autotest.lua` with `FORCES` = the match forces, and
  `rts-player` normal.

**Legacy autotest: kept.**
- `AUTOTEST_MATCH = {opponents = 1, difficulty = "normal", size = "legacy", enemy_brain = "waves"}` reproduces the
  Phase 2 start on an arena surface: CCs at ±60, the template enemy, waves, `/rts-wave-timing`.
- The Phase 1/2 autotest runs on it unchanged, except for one thing: its `/rts-qa-reset` check now runs at 155 s
  instead of 65 s. QA reset rebuilds the arena, and the economy checks need the original base until 150 s.

## Console commands and hotkeys

| Command / key | Effect |
|---|---|
| `/rts-match <1-3> <easy\|normal\|hard> <small\|medium>` | Start a new match now (admin). Missing or bad arguments take the defaults. A 4th word `waves` gives the legacy brain. |
| `/rts-qa-reset [nowaves]`, Ctrl+Shift+R | Restart the current match with the same config: new arena, bases, armies and clock, selections cleared, camera to the CC. In the lobby it starts the dialog's settings. `nowaves` only matters for the legacy brain. Log: `qa-reset by player=N: match A -> B on rts-arena-B, spawned rts-player=6 rts-ai-1=6, ...` |
| `/rts-qa-end`, Ctrl+Shift+E | Unchanged; the dump now lists the config, the arena and every force with its counters |
| `/rts-kill-force <force\|ai\|all>` | Debug: `die()` every unit and building of the force(s). Used by the self-test for a scripted victory. |
| F10, HUD Menu button | Toggle the in-match menu |
| `/rts-wave-timing` | Legacy wave brain only |

## API for other modules

| Function | Returns / does |
|---|---|
| `match.start(cfg)`, `match.teardown(reason)`, `match.delete_arena(name)` | World part of starting and ending a match; `lobby.start_match` / `back_to_lobby` wrap them |
| `storage.match.arena_half` | Arena half size in tiles; the contract with the AI planner. `match.arena_half()` reads it. |
| `match.surface()`, `match.view_surface()`, `match.lobby_surface()` | Arena (nil in the lobby), arena or lobby, lobby (created on demand) |
| `match.in_lobby()`, `match.phase()`, `match.config()`, `match.arena_half()` | State |
| `match.forces()`, `match.ai_forces()`, `match.is_participant(f)`, `match.enemy_unit_count(f)`, `match.enemy_units_seen(f)` | Participants (rts-player first); live enemy units in total, and those in the force's sight |
| `match.home(f)`, `match.facing(f)`, `match.army_point(f)` | CC centre, ±1, army gathering point. `match.FACING[f]` and `match.CC_POSITIONS[f]` still work as read-only views. |
| `match.stats(f)`, `match.label(f)`, `match.elapsed_seconds()` | Counters, localised name ("You", "AI 2"), match time |
| `match.result(f)`, `match.is_out(f)`, `match.decide_winner(player_out, enemies_out)` | As in Phase 2, for N forces |
| `match.on_ended(fn(m))`, `match.on_force_out(fn(f))` | Load-time callbacks (`lobby.lua`, `fog.lua`) |
| `lobby.start_match(cfg, who)`, `lobby.back_to_lobby(reason)`, `lobby.restart_current(who)` | Full flow, including AI commanders, fog, cameras, HUD |
| `lobby.show_lobby / show_menu / toggle_menu / show_results (player)`, `lobby.on_click(event)` | GUI |
| `fog.update_force(f)`, `fog.counts(f)`, `fog.stats_line()` | Re-chart now; charted / visible / total chunks |

## Validation

All runs use copies of `mods/` plus `mods/mod-list.json` (Space Age on). "Final code" means the copy is identical to
`mods/` at the end, except for the one-line `AUTOTEST_MATCH` or `SELFTEST_DEFAULT` edit named in the row.

| Run | Copy | Result | Errors |
|---|---|---|---|
| Headless 1v1 normal small, `tools/headless-run.sh 420 '\[rts' build/p3-flow`, final code | `build/p3-flow` | `ai autotest summary 9/9 (all passed), result=both alive (time)`; both forces had extractor, smelter and barracks at 23 s; attacks 4 and 2; kits per minute [6 5 5 4 11 7] and [6 5 5 4 10 6] | 0 |
| Headless 1v2 normal small, final code with `opponents = 2` | `build/p3-flow-1v2` | `ai autotest summary 13/13 (all passed), result=winner ai (match ended)`; `rts-player is out at 269s`; `expand iron2` skipped "no free iron-ore patch" for both AIs | 0 |
| Headless 1v2 normal small, first run, before the contested-ore workaround | (overwritten) | Game stopped at 210 s: `layout.lua:414 ... 'perp' (a nil value)` | 1 |
| Headless 1v2, second run (same game logic as final; the copy lacked only the Escape log lines and the pre-Phase-3 save cleanup) | `build/p3-flow-1v2-first-server.log` | 13/13 all passed, both alive at minute 7; `expand iron2` skipped "no free iron-ore patch" | 0 |
| Headless 1v3 normal small, 260 s smoke | `build/p3-flow-1v3` | All 4 forces had extractor, smelter and barracks at 23 s. `rts-ai-1 is out at 238s`, then `ai rts-ai-1: commander stopped`; the match went on. | 0 |
| Headless 1v2 hard medium, 260 s | `build/p3-flow-med` | 13/13 all passed. The hard AIs won at 192 s: `winner=ai`, defeat for `rts-player`. | 0 |
| Headless legacy waves brain (Phase 1/2 autotest on the legacy map), 240 s | `build/p3-flow-legacy` | `autotest summary 65/65 (all passed)` | 0 |
| GUI smoke, self-test off, `tools/gui-run.sh build/p3-flow 120 'RTS_GUI_READY'` | `build/p3-flow` | Start dialog on join, `autotest: off (1 connected players)`, `RTS_GUI_READY` | 0 |
| GUI self-test, Russian (system language), `SELFTEST_DEFAULT = true` in the copy | `build/p3-flow-st` | Full flow up to `RTS_MATCHFLOW_DONE`, screenshots `build/shots-p3-flow-st/` | 0 |
| GUI self-test, English (scratch copy of `gui-run.sh` that adds `locale=en`) | `build/p3-flow-en` | Same, screenshots `build/shots-p3-flow-en/` | 0 |
| GUI self-test, 1v2 hard medium (the copy also sets the dialog's choice before Start) | `build/p3-flow-st2` | Same; "Army 6 vs 12 Enemy" (before the "Enemies seen" change); a 3-row results table; screenshots `build/shots-p3-flow-st2/` | 0 |

**Follow-up: "Enemies seen" and the lobby panels.**
- **Enemy count.** The strip now counts only enemy units whose chunk is visible to the player's force
  (`match.enemy_units_seen`, `LuaForce.is_chunk_visible`). It reads "Enemies seen: N", or "?" with none in sight.
  After the match it shows the real total, "Enemies: N".
- **Lobby panels.** The selection panel and the build menu are hidden in the lobby and come back at Start.
- **GUI self-test** (`build/p3-flow-st`, Russian, `RTS_MATCHFLOW_DONE`, 0 errors).
  - A new step at 1230 spawns one enemy walker next to the own CC. The log reads
    `enemies seen by rts-player before the spawn: 0 (total 6)`, then `after the spawn: 1 (total 7)`.
  - The screenshots show:

    | Screenshot | Strip and panels |
    |---|---|
    | 120 | "Врагов видно: ?"; no panel and no build menu under the dialog |
    | 1200 | "Врагов видно: ?" |
    | 1290 | "Врагов видно: 1", the red walker beside the base |
    | 1620 | "Враги: 0" after the victory |
- **Headless run**, 150 s on `build/p3-flow`: 0 errors. The AI planned no lines in this run: the arena_half gap described in "AI planner limits".

### Final runs after the AI fix

**Current defaults:** `match.ORE_LAYOUT = "rotated"` and `match.AI_VERTICAL_LINES = true` (contested iron in every
size). Every run is headless, 6-minute AI autotest, small map, normal difficulty, zero errors.

| Run | AI code | Layout | Result |
|---|---|---|---|
| `build/p3-final-1v1` (final-code copy), 420 s | 1051c60 | 1v1, identical in both | 12/12, both alive |
| `build/p3-final-1v2` | 1051c60 | rotated | 16/16, but both AIs logged `line copper unavailable` and smelted 0 copper. Player AI out at 278 s. |
| `build/p3-final-1v2f` | 1051c60 | facing | 16/16; every line planned. Player AI out at 338 s. |
| `build/p3-final-1v3` | 1051c60 | rotated | 17/20. AI 1 and AI 3 had no copper line. Failed checks: `attack_rts-ai-1`, `produce_rts-ai-3`, `outcome`. |
| `build/p3-final-1v3f` | 1051c60 | facing | 20/20; every line planned |
| **`build/p3-rot-1v2`** | **33d5b40** (current `mods/`) | **rotated** | **19/19.** Every AI built extractor, smelter and barracks at 34 s and smelts copper. Player AI out at 321 s. |
| **`build/p3-rot-1v3`** | **33d5b40** | **rotated** | **23/24.** Every AI built extractor, smelter and barracks at 31–37 s. Only `rts-player:iron2` was unavailable, so every AI got its iron and copper lines. |

**The one failure is AI army behaviour, not match flow.** The failed check is `attack_rts-ai-1: launched 0 attacks`:
1. AI 1 lost its barracks and kept 2 units.
2. AI 2 lost its CC and barracks, but kept a factory, so it was not out.
3. In the four-way fight, AI 1 never reached its attack size.

A GUI smoke run on the final 1v1 copy passed: lobby on join, `RTS_GUI_READY`, 0 errors.

**Self-test timeline.** Ticks count from the player's camera setup. camera.lua's step at 960 still writes
`RTS_GUI_READY`.

| Tick | Step |
|---|---|
| 120 | Screenshot: the start dialog |
| 150 | Start clicked through `lobby.on_click` |
| 180–900 | Phase 1/2 steps on the new arena |
| 930 | `/rts-qa-reset`: match 1 becomes match 2 on `rts-arena-2` |
| 1200 | Screenshot: the arena, fog on the minimap |
| 1260–1320 | Menu opened, screenshot at 1290, Resume clicked |
| 1500 | `/rts-kill-force ai` |
| 1620 | Screenshot: the results frame |
| 1680 | Restart clicked on the results frame |
| 1740 | Screenshot: the start dialog again |
| 1800 | `RTS_MATCHFLOW_DONE` |

**What the screenshots show** (`rts-p1-<tick>.png`, English names first):

| Screenshot | Content |
|---|---|
| 120 | Centred dialog with the opponents, difficulty and size drop-downs and the hint, over black. The strip reads "--:--", "Choose the match settings and press Start match.". The minimap is black. |
| 1200 | Own CC, 6 walkers and 4 ore patches. On the minimap only a square around the base is lit (128×160 tiles, the 20 charted chunks); the rest is black. These runs predate the "Enemies seen" change and showed "Army 6 vs 6 Enemy". |
| 1290 | Menu: "1 opponent · Normal · Small (256×256)", match time, Restart and Resume |
| 1620 | "Victory", "Match time: 00:09", the table (You 0 / 0, 0 / 0, Winner; AI 1 (Normal) 0 / 6, 1 / 6, Out at 00:09), Restart and Continue. The minimap now shows the whole arena with both bases. |
| 1740 | The start dialog over black again |

Script screenshots render the world as it is, so the world view in these shots shows no fog (gotcha 6).

**Measured.**

| Measure | Value |
|---|---|
| Arena build, small (256×256) | 79 ms |
| Arena build, medium (384×384) | 167 ms |
| AI time per 3600 ticks, 1v1, two commanders | 95–189 ms |
| AI time per 3600 ticks, 1v2, three commanders | 171–298 ms |
| Wall clock per 3600 ticks, every headless run | 59.9–60.0 s (60 UPS) |

**Fog in the GUI.** The stats line read `rts-player charted 20 visible 20 of 64` 8 s into the match, and 144 chunks
on the medium map.

## Gotchas

1. **`set_controller{type = remote, surface = ...}` does nothing during the freeplay intro cutscene.** The controller
   type stays 6, and the view stays on nauvis. `camera.init` already disables the intro, so the mod is not affected. A
   bare probe hit it.
2. **A god body can be teleported to another surface (`player.teleport(pos, surface)`), and remote view can look at a
   surface other than the physical one**, in both directions.
3. **`game.delete_surface` is deferred** (`on_pre_surface_deleted` and `on_surface_deleted` come on a future tick), so
   arenas get unique names.
4. **A HUD `minimap` element keeps its `surface_index`.** The HUD is rebuilt (`hud.build`) whenever the arena changes.
5. **A sized map is centred on (0, 0).** With `width = height = 256`, tile (127, 0) is grass and (128, 0) is
   `out-of-map`.
6. **`game.take_screenshot` ignores fog of war** (see Fog).
7. **No chart happens headless.** Fog stats are 0 on a headless server, so fog can only be verified in the GUI.

## Open issues

- **No team mode.** It is always free-for-all. Allied AIs would need `set_friend`, `share_chart` and a team-aware
  `check_out`.
- **The lobby still shows the HUD strip and the minimap** behind the dialog, with zeros, "--:--" and the Menu button.
  The selection panel and the build menu are hidden there.
- **Not tested with real input:** F10, the drop-downs (clicked by a person), Escape on the menu and results frames,
  and `/rts-match` typed in the console. The protocol covers each.
- **Pre-Phase-3 saves** drop their old match on load (teardown) and restart in the lobby. Nauvis keeps whatever else was
  there. This was not run.
