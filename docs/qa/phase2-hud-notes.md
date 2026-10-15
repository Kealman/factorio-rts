# Phase 2 HUD, build menu and building selection: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE2.md` ("Player interaction"). Economy API: `docs/qa/phase2-economy-notes.md`. Phase 1 HUD:
`docs/qa/phase1-hud-notes.md`. QA protocol: `docs/qa/phase2-protocol.md`.

## Files

| File | Change |
|---|---|
| `scripts/hud.lua` | Build menu, building page of the selection panel, resource row on the strip, prompts on the message line, QA hotkeys, build log lines, Phase 2 self-test steps |
| `scripts/selection.lua` | Single-click selection of an own building, exclusive with units; outline, rally line and flag |
| `scripts/orders.lua` | Right click with a barracks selected sets its rally point; right click in build mode ends it; armed prompt moved to the HUD; "attack done" log line |
| `scripts/cursor.lua` | Build mode (`cursor.give_ghost`), Q follow-up input, 10-tick cursor watchdog |
| `prototypes/inputs.lua` | `rts-build-menu` (B), `rts-qa-reset` (Ctrl+Shift+R), `rts-qa-end` (Ctrl+Shift+E), `rts-clear-cursor` (linked to the vanilla clear-cursor control) |
| `prototypes/styles.lua` | Armed attack-move button, build and recipe slot buttons, 20 px icons, progress bar |
| `prototypes/controller.lua` | New. Remote-view pan speed. |
| `data.lua` | Requires `prototypes.controller` |

No economy, match, debug, camera or locale file was edited. The new inputs carry an English `localised_name`, so the
locale file stays untouched.

## Layout

All areas are in `player.gui.screen`. Sizes are GUI units, multiplied by `player.display_scale`.

| Area | Anchor | Size (GUI units) | Content |
|---|---|---|---|
| Selection panel | bottom-left | 420 × 140 (was 122) | Units: Phase 1 page plus a hint line. Building: name, HP, status line with progress bar, recipe buttons, two info lines. |
| Build menu | bottom-right | 272 × 122 | Heading "Build [B]", hint "Q / right-click: done", 10 slot buttons in 6 columns |
| Match strip | top-centre, never under the minimap | 600 × 96 (was 420 × 64) | Timer and army counts; resource row; message line |
| Minimap | top-right | 220 × 220 | Unchanged |

Placement at 1280×800, from the `hud: layout` log line:

| UI scale | Panel | Build menu | Strip | Minimap |
|---|---|---|---|---|
| 0.75 (automatic scale of `tools/gui-run.sh`) | (6, 689) 315×105 | (1070, 702) 204×92 | (415, 6) 450×72 | (1106, 9) 165×165 |
| 1.0 (the user's own config) | (8, 652) 420×140 | (1000, 670) 272×122 | (340, 8) 600×96 | (1048, 12) 220×220 |
| 1.25 (computed, not run) | (10, 615) 525×175 | (930, 637) 340×153 | (225, 10) 750×120, shifted left of the minimap | (990, 15) 275×275 |

Nothing overlaps at 0.75 in the screenshots. At 1.25 the centred strip would reach the minimap, so `place()` shifts it
left to end one margin before the minimap frame.

### Element positions at UI scale 0.75 (measured in the screenshots, 1280×800 game area)

| Element | Centre |
|---|---|
| Unit page: Attack-move [F], Stop [X], Hold [H], Select all [Ctrl+A] | (56, 741), (124, 741), (176, 741), (249, 741) |
| Unit page: group buttons 1–5 | y 763; x 66, 110, 153, 197, 241 |
| Building page: recipe buttons | y 744, x = 27 + 26 × index. Barracks: walker kit (27), heavy kit (53), pause (79). Factory: barracks, turret, ammo, extractor (105), smelter, solar array, factory, belt, inserter, pole, pause (287). |
| Build menu, row 1 | y 741: extractor 1093, smelter 1124, solar array 1155, belt 1186, inserter 1217, pole 1248 |
| Build menu, row 2 | y 772: factory 1093, barracks 1124, turret 1155, stockpile 1186 |
| Strip: resource row | y 43: iron, copper, steel, stone, magazines, power, bots from x ≈ 480 to 800 |
| Strip: message line | y 62 |
| Minimap | (1106, 9) to (1271, 174), centre (1188.5, 91.5), 0.9375 px per tile. Own CC at (1132, 92), enemy CC at (1245, 92). |

The recipe buttons follow the recipes' `order`. The `hud: recipe buttons <kind>#N` log line lists them left to right.

## What each control does and logs

Every line has the `[rts]` prefix.

| Control | Effect | QA log line |
|---|---|---|
| Build button | Disabled while an item has no recipe and the network holds none (the stockpile today). Otherwise `cursor.give_ghost(player, item)`: the RTS cursor goes, a ghost of the item is in the cursor. The button shows as pressed and the message line reads "Placing <item>: left-click the map. R rotates. Q or right-click: done." Clicking the pressed button again gives the RTS cursor back. | `hud click build <item> player=N in_network=N ghost=true` or `... -> build mode off (tool=true)` |
| Left click on the map in build mode | Vanilla ghost placement. The ghost stays in the cursor, so several can be placed. | `build ghost <entity> player=N at (x, y) direction=<dir>` |
| Robots build a ghost | Vanilla | `robot built <entity> #N at (x, y) direction=<dir> force=<force>`, plus `pickup=... drop=...` for inserters and `drop=...` for extractors |
| R over a built entity or ghost | Vanilla rotation | `rotated <entity> #N at (x, y) direction=<dir> player=N`, plus the inserter or extractor positions |
| Q in build mode | Vanilla clear-cursor ends build mode; the linked `rts-clear-cursor` input gives the RTS cursor back on the next tick | `cursor clear (Q) player=N ghost=<item>`, then `cursor given player=N reason=...` |
| Right click in build mode | Ends build mode; no order is given | `build mode ended item=<item> player=N (right click)` |
| F1 | As in Phase 1; also ends build mode | `cursor F1 player=N tool_in_hand=true (ended build mode, ghost <item>)` |
| B | Shows or hides the build menu. The state survives HUD rebuilds. | `hud build menu hidden player=N (B)` / `shown` |
| Left click on an own building | Selects it, deselects units. Outline in the force colour; a barracks also gets a dashed line to its rally point and a flag (grey at the default exit while no rally is set). | `select building <kind> unit=N player=N at (x, y)` |
| Recipe button | `production.set_recipe(unit, recipe)`, which reads the recipe back | `recipe set <kind>#N <recipe> ok=true now=<recipe> player=N` |
| Pause button | `production.set_recipe(unit, nil)` | `recipe set <kind>#N none ok=true now=none player=N` |
| Right click with a barracks selected | `buildings.set_rally`, green marker, the flag moves | `rally set barracks #N -> (x, y) ok=true player=N` |
| Right click with another building selected | Nothing | `rally ignored: the selected <kind> #N has no rally point player=N` |
| Ctrl+Shift+R (Cmd+Shift+R) | `debug.run_command("rts-qa-reset", "nowaves", player)`: same code as the console command | `qa hotkey /rts-qa-reset nowaves player=N`, then `qa-reset by player=N: ...` |
| Ctrl+Shift+E (Cmd+Shift+E) | `debug.run_command("rts-qa-end", "", player)` | `qa hotkey /rts-qa-end player=N`, then `RTS_QA_END by player=N` |
| F, or the Attack-move button | Armed: the button turns red and the message line reads "Attack-move armed: right-click where to go. F or X cancels." No more flying text at the cursor. | Phase 1 lines unchanged |
| An attack's target dies | Attackers go idle | `order attack done unit=#N (target gone)`, one per attacker |
| Resource row | Refreshed every 30 ticks from `economy.snapshot` | `hud resources player=N iron=.. copper=.. steel=.. stone=.. magazines=.. power=../.. MW sat=..% bots=../..`, on change and at most every 5 s |

The Phase 1 log lines are unchanged: `select mode=...`, `order ...`, `group ...`, `hud click <button> ...`,
`hud click minimap ...`, `cursor given ...`, `camera ...`.

### Panel contents per building kind

| Kind | Line 1 (with progress bar) | Buttons | Lines 2 and 3 |
|---|---|---|---|
| Barracks | Recipe icon and name, then "running", "waiting for [item]..." or "outside the logistic network" | Walker kit, heavy kit, pause | Units from this barracks; force totals of kits, units and heavies. Rally point, or "No rally point". |
| Factory | Same | Every `rts-buildings` recipe, then pause | Force totals of crafts and of items moved into the network |
| Command Center | Robots idle, construction and logistic | none | Power used / available and machine satisfaction; robot ranges |
| Turret | Ammo count and feed state | none | Magazines in the network |
| Extractor, smelter, solar array, stockpile | Entity status | none | Ore under the extractor, smelter recipe, stockpile item count, solar output |

### Resource row

Iron, copper, steel, stone and magazines are `economy.snapshot` counts. Power is `demand/capacity MW` plus the
satisfaction in green (90 % or more), yellow or red. Bots are idle/total. The numbers come from the cached snapshot,
so they are at most 30 ticks old.

### Message line priority

1. Attack-move armed (red).
2. Build mode (green).
3. Match: "Preparing the arena...", wave alerts, "Enemy wave N in m:ss", "Enemy waves off (QA reset). /rts-qa-reset
   turns them back on.", "Destroy the enemy base and army.", and the result. The result comes from
   `match.result(force)` and reads "Victory! The enemy base and army are destroyed.", "Defeat. Your base and army are
   destroyed." or "Draw: both sides are destroyed.".

## API for other modules

| Function | Does |
|---|---|
| `cursor.give_ghost(player, item)` | Build mode. Returns true when the ghost is in the cursor; otherwise gives the RTS cursor back. |
| `cursor.ghost_name(player)` | Item name of the cursor ghost, or nil |
| `cursor.holds_tool(player)` | True when the RTS cursor is in hand |
| `selection.select_building(i, unit_number)` | Selects an own building. Returns false for other forces. |
| `selection.get_building(i)` | `unit_number, record` of the selected building, or nil |
| `selection.refresh_building(i)` | Redraws the outline and flag, for example after a rally change |
| `selection.building_at(i, position, surface?)` | Own building at a point: the hovered entity if the point is on it, else the nearest selection box within 1 tile |
| `selection.handle_area(i, entities, area, add, surface?)` | New optional `surface`. A plain click with no own unit selects the building there. |
| `orders.set_rally(i, position)` | Rally of the selected barracks. Returns `"rally", 1` or `"none", 0`. |
| `hud.build_click(player, item)`, `hud.recipe_click(player, recipe_or_"")` | The button paths, also used by the self-test |

Storage:

- `storage.players[i].building` and `.building_render`, owned by selection.lua.
- `storage.players[i].hud_prefs = {build_hidden}` and `.hud_resource_log`, owned by hud.lua.
- `storage.orders.cancel_tick`, owned by orders.lua.
- `storage.cursor.pending`, owned by cursor.lua.

All of them are created on first use, so saves from Phase 1 need no migration.

## Phase 1 follow-ups done here

| Item | Result |
|---|---|
| 1. Pan speed | `data.raw["remote-controller"].default.movement_speed` goes from 1 to 0.34375, about a third. A quarter is not allowed: the prototype docs say "Must be >= 0.34375". The data stage logs `controller: remote-controller movement_speed 1 -> 0.34375`. The pan speed itself is not measured yet; there is no scripted key input. |
| 3. Console-free QA controls | Ctrl+Shift+R runs `/rts-qa-reset nowaves`, Ctrl+Shift+E runs `/rts-qa-end`, both through `debug.run_command` as the pressing player. Cmd+Shift+R/E are the macOS alternatives. |
| 5. Attack-move prompt | The flying text at the cursor is gone. The prompt is on the strip's message line, and the armed button uses the vanilla red button graphics. |
| HUD texts (economy notes) | The match texts now say "base and army", and the result comes from `match.result`. |

## Visibility of the enemy

`match.lua` charts `[-112, 112]²` for `rts-player` once, on the first 60-tick pass. Both bases are inside that area.
The self-test screenshot after the minimap jump (`rts-hud-720.png`) shows the enemy base in full detail: CC,
stockpiles, extractors, smelters, belts, poles, solar arrays and barracks. Walkers have `radar_range = 1`, so the area
around each unit stays live. No change to `match.lua` is needed for Phase 2.

## Gotchas

1. **Every crafting machine lists the "parameters" category.** `entity.prototype.crafting_categories` of the barracks
   includes it, so a recipe list built from the categories showed the ten blueprint parameter recipes 0–9 as purple
   buttons. `LuaRecipePrototype.parameter` filters them out.
2. **`toggled` overrides a button's style graphics.** A toggled button draws its selected graphics, orange for the
   vanilla button. The armed Attack-move button therefore stays untoggled and switches to the red style instead.
3. **Self-test steps run in 30-tick sweeps, and screenshots render at the end of the tick.** camera.lua runs every
   due step in one sweep. A state set and undone in the same tick never reaches a screenshot. This is why debug.lua's
   step 270 screenshot never showed the armed button. Steps that must be seen are at least 30 ticks apart.
4. **`build_from_cursor` with a ghost in the cursor raises no `on_built_entity`.** It placed the barracks ghost, and
   robots built it, but no `build ghost` line was logged. A real left click is expected to raise the event; the QA
   protocol checks it.
5. **`on_player_cursor_stack_changed` comes later in the same tick, not instantly** (event docs). Clearing the tool
   to put a ghost in the cursor is therefore safe: by the time the event arrives, the ghost occupies the cursor. Clearing
   the cursor in the self-test brought the RTS cursor back through that event (`reason=cursor emptied`).
6. **Clearing a cursor ghost is not guaranteed to raise the cursor event.** The stack itself stays empty, so
   cursor.lua has the linked clear-cursor input and a 10-tick watchdog as backstops.
7. **The core pole's supply area is drawn in build mode.** Holding a building ghost shows the dark 36×36 square of the
   hidden `rts-core-pole` (`rts-hud-420.png`). It shows where buildings get power without poles, which helps players.
8. **The alert sprite `utility/electricity_icon` is a red warning triangle.** The power icon is the core sprite
   `tooltip-category-electricity`, a plain yellow bolt.
9. **A stockpile has no recipe and no starting stock.** Its build button is greyed out and disabled while the network
   holds none. `/rts-give rts-stockpile N` enables it.

## Validation

| Run | Result |
|---|---|
| `tools/headless-run.sh 200 '\[rts' build/p2-hud` (Space Age, a copy identical to `mods/`, final code) | `autotest summary 64/64 (all passed)`, 0 errors in the create and server logs (`build/p2-hud-server.log`). The data stage logs `controller: remote-controller movement_speed 1 -> 0.34375`. |
| `tools/gui-run.sh build/p2-hud 90 'RTS_GUI_READY'`, final code, self-test switched on in the copy only (`SELFTEST_DEFAULT = true` in its `camera.lua`) | 0 script errors (`build/p2-hud-gui.log`). Screenshots in `build/shots-p2-hud/`. |

Self-test results in the GUI run (setup-relative ticks; screenshot names use absolute ticks):

| Step | Log evidence | Screenshot |
|---|---|---|
| Build click, barracks | `hud click build rts-barracks player=1 in_network=1 ghost=true`; cursor `tool=false ghost=rts-barracks` | `rts-hud-420.png`: message line "Placing Barracks: ...", barracks button pressed, power area square |
| `build_from_cursor` | `ghosts there=1; tool=false ghost=rts-barracks`: the ghost stays in the cursor after placing | |
| `clear_cursor` (Q's action) | `cursor given player=1 reason=cursor emptied ok=true`, then `tool=true ghost=none` | |
| Armed attack-move via the button | `hud click attack-move player=1 result=true` | `rts-hud-540.png`: red button, red prompt on the strip |
| Robots build the ghosts | `robot built rts-barracks #N at (-54.5, -8.5) direction=north`, same for the factory | |
| CC click | `select building cc unit=N player=1 at (-60.0, 0.0)` | `rts-hud-840.png`: CC panel with robots and power, build menu, resource row (iron 200) |
| Barracks click, recipe, rally | `select building barracks`, `recipe set barracks#N rts-walker-kit ok=true`, `rally set barracks #N -> (-44.0, -10.0) ok=true`; 3 s later `spawned rts-walker ... -> rally (-45.8, -8.3)` | `rts-p1-900.png`: barracks panel (walker kit active), dashed line and flag; iron 180, copper 96 |
| Factory click, recipe | `hud: recipe buttons factory#N player=1: rts-barracks rts-turret rts-ammo rts-extractor rts-smelter rts-solar-array rts-factory rts-belt rts-inserter rts-pole pause`, `recipe set factory#N rts-extractor ok=true` | `rts-hud-960.png`: 11 buttons fit (last one at x 287 of 315) |
| Minimap jump to the enemy | `hud click minimap ... -> world (49.6, 0.5)` | `rts-hud-720.png`: the enemy base in full detail |

Earlier runs found and fixed the parameter recipes (gotcha 1), a truncated CC line, the red warning power icon (gotcha 8)
and the orange armed button (gotcha 2). The pan speed was not measured: no run had keyboard input.

## For the lead

- **The player cannot complete the extractor, smelter and stockpile loop from the starting stock.** The iron patch
  is about 24 tiles from the CC stockpiles, the stock has 20 belts and no stockpile, and the stockpile has no recipe.
  A stockpile inside the logistic area at the patch edge, at x ≥ −36 from a CC at (−60, 0), would close the loop.
  Options: 2 stockpiles in `match.STARTING_STOCK`, a factory recipe for `rts-stockpile`, or both. The build menu shows
  the stockpile as soon as the network holds one.
- **Not verified with real input:** Q, B, Ctrl+Shift+R/E, right click in build mode, a real ghost click, a real
  building click with the hover path, and the pan speed. The QA protocol covers each.
