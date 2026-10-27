# Release 0.1.3, agent r4-rails: the vanilla rail planner (#37) and rails follow-ups (#33)

Date: 2026-10-27. Branch of `main` 684c069 (0.1.2 + the 0.1.3 plan). Factorio 2.1.23 (Steam, mac-arm64), Space Age on.
Plan: `docs/qa/release-0-1-3-plan.md` (rules: `docs/qa/release-0-1-2-plan.md` section 3).

## 1. Why the vanilla rail planner did not run (#37 investigation)

**Finding: `GameViewSettings.update_entity_selection = false` (scripts/camera.lua, HIDDEN_CHROME) is the whole cause.**
The 2.x rail planner starts from the rail end under the pointer, the engine's hovered entity (the base game's tips
simulation does the same: `move_cursor` onto a rail end, `activate_rail_planner`, move, build). With hover selection off
the engine never sees the rail end, so a press only places one rail, a click elsewhere places another one and a drag
places a staircase of straight pieces: exactly what 0.1.2 saw. With hover selection on, the planner previews its path
from the rail end to the pointer (curves, diagonals, the rail count) and builds it as ghosts, by clicks and by drags,
under the RTS remote view as it is. Nothing else of the RTS view matters: neither the 10-tick hover clear, nor the cursor
watchdog, nor the god body on the lobby surface.

**Probe:** `tools/probes/r4_planner_finding_gui.lua`, real input through `tools/gui-drive.sh` (fdrive clicks, moves and
a slow 40-step drag, which `drag` now takes as optional `STEPS MS` arguments), a Skirmish match from the lobby, the
camera next to the Command Center at zoom 0.35. Two runs:

Run 1, the 0.1.2 input (a click on bare ground, a move, a click; a drag from bare ground): every variant placed single
pieces, the god controller with hover on included (2 rails per click pair, 15 straight pieces per drag). A click on bare
ground never starts the 2.x planner, so this input could not tell the settings apart.

Run 2, the planner's own input (the pointer rests on the east end of two built straight rails, a click there, a move to a
point 24 tiles east and 8 south, a window capture, a click; then a ghost placed on bare ground and a click on its end;
then a slow drag that starts on a rail end). Results, rail pieces placed by the stub test and the drag:

| Variant | What changes | Stub test (click on a rail end, move, click) | Drag from a rail end |
|---|---|---|---|
| base | nothing (as shipped: hover off, 10-tick clear on, watchdog on) | 2 straight ghosts (single pieces) | 18 straight ghosts |
| hover | `update_entity_selection` on, 10-tick clear paused | **6 ghosts: 1 curved-rail-a, 4 half-diagonal, 1 straight** (path preview captured) | **33 ghosts: 8 + 8 curved, 3 half-diagonal, 14 straight** |
| hover_clear | hover on, the 10-tick `clear_selected_entity` left running | 6 ghosts, curves | 25 ghosts, 17 curved |
| hover_nowatch | hover on, cursor watchdog and camera guard paused | 6 ghosts, curves | 33 ghosts, curves |
| hover_surface | hover on, the god body moved from the lobby onto the arena | 6 ghosts, curves | 33 ghosts, curves |
| item_hover | a real `rail` item (100) set into `cursor_stack` under the remote controller | nothing: the item is gone in the same tick | nothing |
| god_hover | god controller on the arena, 100 rails in the cursor stack, hover on | 7 real rails, curves | 10 real rails, curves |
| god | the same with hover off | 4 straight rails | 20 straight rails |

Log lines (`build/r4f-run2/r4f-gui.log`):

```
[rts] r4f result base stub: ghosts 2, real 2 {["real straight-rail"] = 2, ["straight-rail"] = 2}; cursor empty ghost rail
[rts] r4f result hover stub: ghosts 6, real 2 {["curved-rail-a"] = 1, ["half-diagonal-rail"] = 4, ["real straight-rail"] = 2, ["straight-rail"] = 1}
[rts] r4f result hover drag: ghosts 33, real 2 {["curved-rail-a"] = 8, ["curved-rail-b"] = 8, ["half-diagonal-rail"] = 3, ["real straight-rail"] = 2, ["straight-rail"] = 14}
[rts] r4f result hover_clear stub: ghosts 6, real 2 {["curved-rail-a"] = 1, ["half-diagonal-rail"] = 4, ["real straight-rail"] = 2, ["straight-rail"] = 1}
[rts] r4f result god stub: ghosts 0, real 4 {["real straight-rail"] = 4}
[rts] r4f result god_hover stub: ghosts 0, real 7 {["real curved-rail-a"] = 1, ["real half-diagonal-rail"] = 3, ["real straight-rail"] = 3}
[rts] r4f probe: trace ensure(cursor emptied, false) tick 7170: stack empty, ghost nil, controller remote, main inventory none
```

(The stub's two built rails count as "real 2"; the ghost test's counts include the stub test's pieces, its region
overlaps.) Window captures: `build/r4f-run2/shots-r4f-window/hover-stub-preview.png` shows the planner's green path
preview from the rail end to the pointer with its rail count; `base-stub-preview.png` shows the single rail at the
pointer.

The other questions of the issue:

2. **A real rail item vs a cursor ghost.** Under the remote controller the engine itself empties the cursor in the tick
   the item is set (`on_player_cursor_stack_changed` with an empty stack; the remote controller has no inventory behind
   the hand: `get_main_inventory()` is nil). `cursor.ensure` is not the culprit: it only puts the RTS cursor back
   afterwards because the cursor is empty. Under the god controller a real item stays and builds real rails (the
   planner too, with hover on). The cursor ghost is the remote view's way and runs the planner in ghost mode. The `rail`
   item is a `rail-planner` with rails {straight, curved-a, curved-b, half-diagonal, rail-ramp, the four elevated ones}
   and support `rail-support`; `LuaForce::rail_planner_allow_elevated_rails` is false for the RTS forces, so the planner
   stays on the ground (it is false with or without Space Age; the RTS forces never research the vanilla Elevated rail).
3. **The mod's ghost handlers.** `orders.mark_ghost_site` only marks trees and rocks under a player's ghost for
   deconstruction; `territory.build_check` destroys a rail ghost only on another nation's land (with the territory
   flying text); `buildings.on_built` registers buildings only (`KIND_BY_NAME`); `pieces.lua` and `belts.lua` do not
   react to rail ghosts; `rails.lua` handles robot-built rails of its own lines only. No handler touched a planner ghost
   in the probe (all ghosts stayed until the cleanup).
4. **2.1 API and changelog.** `runtime-api.json` 2.1.23 has no LuaPlayer / LuaControl member for the planner (only
   `LuaSimulation::activate_rail_planner` / `deactivate_rail_planner` for tips simulations,
   `LuaForce::rail_planner_allow_elevated_rails` read/write, `LuaItemPrototype::rails` / `support`). The changelog has no
   planner entry after 2.1.0; the ones that matter are 2.0's "Rail planner is usable in the map (remote view)" (FFF-403),
   "Fixed hovering cursor over undo button could change rail planner start location" (the start is the hovered rail
   end), "Fixed rail planner would remain active when changing surfaces" and 2.1.7's "Fixed that rail building in remote
   view thought it was not building ghosts unless force-build was held".

So the planner can run under our view: hover selection goes on while a rail ghost is in the cursor and off when the RTS
cursor comes back (the hover pulse of Phase 5 M2 already does the off part). No substitute tool is needed.

## 2. The rail planner as built (#37)

- **The Rail button** (build menu, Economy tab, Railways) puts the `rail` ghost in the cursor like any build item
  (`hud.build_click` -> `cursor.give_ghost`; the 0.1.2 special case is gone). `cursor.on_ghost_given` hooks tell
  `camera.lua`, which turns `update_entity_selection` on for a rail-planner ghost only (`camera.planner_view`,
  `storage.camera.planner[player]`) and lets the 10-tick hover clear wait meanwhile; when the RTS cursor comes back (Q,
  right click, the button again, F1) the hover pulse of Phase 5 M2 turns it off as after any build mode. A pulse that is
  still running when a planner comes in keeps hover on; a planner ghost that goes without the RTS cursor coming back is
  caught by the 10-tick check; a save made with the planner in hand gets hover back on join. Signals and the Station
  stay single ghosts and keep hover off. The HUD line says "Track: click a rail end, then where it goes. R turns. Q stops,
  Q again: done."
- **The vanilla planner as it is**: click the end of a rail (a depot platform, own track, the rail a first click on bare
  ground places, a ghost's end), then click where the track goes: its path with curves and diagonals follows the
  pointer and the click lays it as ghosts; it goes on from the new end until stopped. The 2.x planner does not build
  while dragging (a drag only moves its preview; probe: 0 ghosts after a 50-step drag, the path after the click), so
  "like belts" means click, move, click. A click on a rail end in the middle of track starts a branch (a junction),
  track laid onto other track joins it. R turns the first rail. Q with a path under way stops the path (the rail stays
  in hand, vanilla), Q again or a right click ends laying. Ground only: `rail_planner_allow_elevated_rails` stays false
  (robots could not build supports and ramps without items); bridges stay the auto lines' (Bridges, Space Age).
- **Land:** pieces on another nation's land are refused by territory's build check with its usual message, now at most
  one flying text per player and tick (a path over foreign land refuses many pieces at once); own and neutral land take
  track; the remote view builds nothing on uncharted ground.
- **Ghosts to track** (`scripts/railplan.lua`, new): every rail ghost a player of a human force places in Nation mode is
  collected per force and handed over `FLUSH_TICKS` (60) after the force's last one to `rails.adopt_ghosts`
  (`scripts/rails.lua`, section "planner track"):
  - piece ends come from the learned geometry (GEO read back as traversals per piece name and direction); the ghosts form
    nodes (rail end positions);
  - chains start where a ghost meets built own track (the start rail is the built rail a train comes off heading into
    the chain: a branch that leaves heading west is entered from the rail east of the junction), then from free track
    ends (the one nearest an own depot first); a chain runs straight on while no built track stands at its end, and every
    other piece at a node (a switch's other leg, a piece from the side, track beyond built rails) starts a chain of its
    own;
  - each chain is a `manual` line with `planner = true`: the 0.1.2 machinery builds it unchanged (robots in range through
    the line index, one crew at a time from the nearest depot connected by track, chain signal pairs every 80 tiles,
    junction chain signals: every piece end at a node with three or more rail ends, built or ghost, carries the mark, so
    whichever piece stands last places them; the "Track not built" alert after a minute, but not for a chain that waits
    behind other planned track);
  - before a crew is sent a chain finds its start rail once built track reaches its first piece, or is turned round when
    built track meets its far end instead;
  - a chain whose ghost goes unbuilt (cancelled by the #27 selection, Ctrl+Z, mined) is dissolved and its other ghosts are
    adopted again, so nothing comes back; a rail built by other means counts as built.
- **The Rail tool is removed**: `scripts/railtool.lua`, its panel, the Backspace undo input (`rts-rail-undo`), its
  locale and help text, `selection.area_hook`. `rails.plan_segment` stays (the fixture draws track with it). On the first
  load of an older save `railplan.init` removes `storage.railtool` and an open Rail tool panel, and turns the 0.1.2
  segments still being built into planner track (`rails.segments_to_planner`: their ghosts stay, built pieces stay track;
  segments with elevated pieces stay as they were).
- The AI never touches any of it: the planner is a player's cursor, adoption needs a human force, every new hunk in
  `check_lines` is behind `line.planner`.

## 3. Tests of the planner (#37)

| Test | Command | Result |
|---|---|---|
| Planner probe, real client, EN and RU (`tools/probes/r4_rails_planner_gui.lua`; real clicks, moves, drags and keys through `tools/gui-drive.sh`) | test copy + `tools/gui-drive.sh build/r4p-<l>-gui.log build/shots-r4p-<l>-window RTS_R4P_DONE &` + `RTS_LOCALE=<l> tools/gui-run.sh build/r4p-<l> 900 RTS_R4P_DONE` | **13/13 in both**: the Rail button gives the planner and turns hover on; a 50-step drag from the depot platform's east end builds nothing (the preview follows), the click at its end lays 18 ghosts (11 half-diagonal, 1 curved, 6 straight; 31 rails, 66 tiles) in one planner line starting on the platform end rail; the depot's crew built it in 12 s; Station 1 put beside it got its 2 stops; a click on the far end and one 16 east / 12 south laid 6 pieces joined to it; a click on a rail end in the middle and one 24 south laid a 9-piece branch starting on track 1; both built in 10 s, 6 chain signals at the branch junction; a freight train depot -> Station 2 stood at Station 2 after 9 s (over the branch); the stop list warnings (section 5); a click over a walker with the planner in hand lays a rail and selects nothing; the first Q stops the path with the rail still in hand, the second one brings the RTS cursor back with hover off; R before a first click turns the rail (direction 2 instead of 0). Screenshots `build/shots-r4-rails-en/`, `build/shots-r4-rails-ru/` (take_screenshot) and `-window/` (window captures with the engine's path previews); the HUD line fits the strip in both languages |
| Manual track fixture, updated for the planner (`tools/probes/r3_rails_manual.lua`: the survey draws tracks 1 to 4, their ghosts are handed over as planner ghosts) | `SEED=501 SPEED=6 EXTRA_LUA=tools/probes/r3_rails_manual.lua STOP_ON='r3 manual summary' tools/autotest-run.sh r4-manual '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1500` | **14/14** (with the new `cancel` and `warnings`): track 1 (280 pieces in one planner line, from built track onto built track) built by a crew in 199 s; the Station took its 2 stops; track 2 (195 pieces, a branch that leaves track 1 heading west) in 185 s with 8 chain signals around the junction; track 3 (52 pieces to free ground) in 58 s, 6 chain signals; auto lines A - C 98 % and A - B 100 % of their pieces reused, A - D open after 221 s (89 % reused); depot A holds 3 lines; a rts-player rail ghost on rts-ai-1's capital land refused by territory's build check; track 4 out of reach: "Track not built" after 62 s; a ghost cancelled in its middle: the line dissolved, 28 of 29 ghosts stand in 2 lines, nothing came back; two trains 10 and 11 loops in 20 minutes, longest stand at a signal 49 s; the single-track hint after 60 s. These are 0.1.2's numbers. The first run failed track 2 (17 of 195 pieces in 10 minutes): the chain's start rail was the rail west of the junction, so the crew parked on the wrong side of a branch that leaves heading west; the start rail is now the one a train comes off heading into the chain |
| Schedule fixture (`tools/probes/r3_rails_schedule.lua`) | `SPEED=8 DURATION_MIN=40 EXTRA_LUA=tools/probes/r3_rails_schedule.lua STOP_ON='r3 schedule summary' tools/autotest-run.sh r4-sched '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' 900` | **8/8**, 0.1.2's numbers (7 loops, 59,762 copper, the junction crossed 15 and 29 times, 0 s at a signal) |
| Train builder fixture (`tools/probes/r3_rails_builder.lua`) | `SEED=501 SPEED=4 EXTRA_LUA=tools/probes/r3_rails_builder.lua STOP_ON='r3 builder summary' tools/autotest-run.sh r4-build '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 900` | **8/8** |
| Skirmish smoke | `tools/autotest-run.sh r4r-smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65, 0 errors (before each commit) |

## 4. Identity and the owner's saves

| What | Command | Result |
|---|---|---|
| AI identity, M1 seed 501 (Nation 1v1 2048, 60 min) against the frozen 0.1.2 tree ac55c09 | `KEEP_TREE=build/trees/ac55c09/mods/factorio-rts TREE_B=<frozen copy of this tree> WHAT=all tools/determinism-compare.sh r4r-m1 '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 60 501` | **line-identical**: on the final tree (808fb96's mod) 67,110 `[rts]` lines on each side, the only difference the event bus's stagger listing, which now names railplan's own period-30 handler (`railplan@30#1=17`); the same on the planner tree before the start-rail fix. Headless runs have no players, so no force is human and nothing of the planner runs |
| Skirmish identity matrix (10 runs, seed 777) against base0111 | `KEEP_TREE=<frozen copy> SEED=777 JOBS=2 tools/autotest-matrix.sh r4r; tools/matrix-compare.sh base0111 r4r` | **0 differing lines** in all 10 runs on 808fb96's mod (summaries as base0111: 1v3 stress 36/38, the rest all passed; 0 Lua errors) |
| Owner's 0.1.2 save `owner-0112.zip` (a copy; the copy's mod version bumped to 0.1.3 so `on_configuration_changed` runs every init, as the release will) | headless server 130 s with an inspection module (`scratchpad/r4-rails/owner_inspect.lua`) | **0 errors**, 741 `[rts]` lines. "the 0.1.2 Rail tool state removed"; the 13 Rail tool segments still being built (#2 to #11, #14, #23, #24) became planner track: their 456 ghosts form **one** planner line of 456 pieces from the 10 built pieces of segment #2 onwards (1,305 tiles, bill 572 rails), so the save's segments do join end to end; rts-player keeps its 41 rails and 456 rail ghosts; the save has no trains. The line waits "no-kits" (no locomotive or construction wagon kits in the depot network) and raises "Track not built: the nearest depot lacks rails, kits or coal" after 60 s, as the segments did before |
| Owner's 0.1.1 Age II save `owner-0111-age2.zip` (same copy) | headless server 130 s | **0 errors**, 813 `[rts]` lines; its auto line open, train 46 keeps its two-stop list; nothing to migrate |

## 5. #33, rails follow-ups

1. **Single track with stub platforms** (item 1): the train panel shows, in yellow under the stop list, "Train N also runs
   between these stops: on single track two trains wait for each other's platform; lay a passing loop or a second
   track" when another train of the force has two or more of the same depots or stations on its list
   (`railroutes.shared_with`). The game cannot tell single from double track, so it is a hint, not an error. The "lay a
   passing loop" preset of the Rail tool is moot: the planner lays a loop with three clicks (a rail end, the loop, back
   onto the track).
2. **A stop no track leads to** (item 2): under each stop row, in red, "No track leads here from stop N: a junction turns
   one way, or the track is not built yet" when no train path leads from the stop before (with Loop on, from the last
   stop to stop 1). `railroutes.unreachable` asks `game.train_manager.request_train_path` once per stop (start: the
   rails of the previous stop's train stops, both directions, since the RTS trains are double-headed; goal: this stop's
   train stops) when the panel is built and every 5 s while it is open; the panel is rebuilt when the warnings change.
   Rail stops (troop and artillery trains) are not checked.
3. **A cancelled ghost** (item 5): the Rail tool is gone, and planner track no longer comes back after its ghosts are
   cancelled (#27's selection, Ctrl+Z): the planner line is dissolved and the rest adopted again (fixture check
   `cancel`). A 0.1.2 Rail tool segment laid a cancelled ghost again when its crew came (`lay_piece` makes a missing
   ghost); the segments of older saves are planner track now. A "remove this track" action for built rails is not done
   (open).
4. Not done (open): item 3 (two auto lines surveyed at the same time over the same ground), item 4 (a platform counts
   as busy while a train has a path ending on it), item 6 (a crew that cannot reach its frontier). r4-ai reports AI
   crews standing "on_the_path" for 120 s on M3 seeds 801 and 804 with the 0.1.2 tree (deterministic); that is AI line
   behaviour, which this branch must keep identical, and r4-ai looks at it.

Tests: GUI probe check `warnings` (EN and RU 13/13): a depot whose platform no track reaches, added as stop 3 of the
freight train's list, is marked unreachable from stop 2 and stop 1 from stop 3, a second train between the depot and
Station 2 brings the hint for train 29, the three labels are in the panel (screenshot `rts-r4p-warnings.png`);
fixture check `warnings` (14/14): A, E unreachable both ways, A, B, C reachable, train 1 shares its stops with train 2.

## 6. Open items

- The 2.x planner lays track by clicks: a drag only moves its preview. That is vanilla; "like belts" in the issue is
  click, move, click with the path following the pointer.
- Ground track only: `rail_planner_allow_elevated_rails` stays off, bridges over water remain the auto lines' (Bridges,
  Space Age). The planner could lay elevated track if supports and ramps had items robots carry or crews laid them;
  not done.
- Q is vanilla: with a path under way the first Q only stops it; Q again or a right click ends laying (the HUD line
  says so).
- While the planner is in hand the vanilla entity info box shows for what the pointer is over (top right), as the
  lead accepted; it goes with the RTS cursor's hover pulse.
- A path that crosses foreign land loses the refused pieces (one message), the rest of it stays as ghosts.
- One crew at a time per force (0.1.2 rule): many separate pieces of planner track wait their turn; robots in range
  build meanwhile.
- The owner's save: its track waits for 2 locomotive kits, 1 construction wagon kit, coal and rails in the depot
  network (or robots in range), exactly as before.
- #33 items 3, 4 and 6, and a "remove this track" action for built rails.
- `docs/FEATURES.md` still says "The Rail tool lays your own track ..." under 0.1.2 (the lead's file).

## 7. Proposed changelog lines

Features:
- Railways: lay your own track with the vanilla rail planner (the Rail button in the build menu): click a rail end,
  then click where the track goes; the path with curves follows the pointer, branches and joins work as in vanilla.
  Robots and construction trains build it, junctions get chain signals. (#37)
- Train panel: a stop that no track reaches from the stop before is marked, and a second train between the same stops
  brings the passing-loop hint. (#33)

Changes:
- The Rail tool (waypoint clicks, Backspace undo, its panel) is replaced by the rail planner; Rail tool track of an
  older save that is not built yet is kept and goes on being built. (#37)

Bugfixes:
- Player track no longer comes back after its ghosts are cancelled. (#33)
- A building or track refused on foreign land shows one message instead of one per piece. (#37)
