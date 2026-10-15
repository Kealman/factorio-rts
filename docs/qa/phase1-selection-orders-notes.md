# Phase 1 selection and orders: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/` (0.1.0).
Builds on `docs/PHASE1.md`, `docs/qa/phase1-skeleton-notes.md` and `docs/research/spikes.md` decisions 3–6 and 10–13.

## What is implemented

| File | What it does |
|---|---|
| `scripts/selection.lua` | Per-player selection set, selection boxes, control groups 1–5, select all, the HUD refresh hook |
| `scripts/orders.lua` | Move, attack, attack-move, stop and hold. Right-click handling with the `rts-rclick` fallback, attack-move arming (F), completion handling, re-targeting and a 2 s sweep |
| `prototypes/inputs.lua` | Attack-move moved to F and stop to X. Nothing is bound to W, A, S or D any more. |
| `prototypes/cursor.lua` | Comment only (handler locations, F) |
| `scripts/camera.lua` | GUI self-test off by default. `/rts-selftest on|off` switches it, and `camera.add_selftest_step` lets other modules add steps. `camera.screenshot` and `camera.selftest_enabled` are exported. |
| `scripts/debug.lua` | The headless autotest now drives selection.lua and orders.lua through the fake player index 0, with 29 PASS/FAIL checks. It adds GUI self-test steps for selection and orders, and `/rts-dump` shows selection and order stats. |
| `scripts/match.lua` | Heavies spawn 4 tiles apart in a column 6 tiles in front of the walker block. Walkers keep 3 tiles. |
| `scripts/units.lua` | Comment only: documents the `issuer` field |
| `docs/PHASE1.md` | Input table only |

## Inputs

| Key | Input | Effect |
|---|---|---|
| left drag or click | `on_player_selected_area` | Replace the selection with own registered units. A click selects the one own unit nearest the click; a click on empty ground clears the selection. |
| Shift + left | `on_player_alt_selected_area` | Add to the selection |
| right click or drag | `on_player_reverse_selected_area` | Attack if the area holds an enemy-force entity. Registered RTS units are preferred over other enemy entities, then the one nearest the centre. Otherwise move to the area centre. If attack-move is armed, attack-move instead. |
| Shift + right | `on_player_alt_reverse_selected_area` | Attack-move to the area centre |
| F | `rts-attack-move` | Arm attack-move: the next plain right click is an attack-move. F again, X or H disarms it. |
| X | `rts-stop` | Stop |
| H | `rts-hold` | Hold position |
| Ctrl+1..5 (Cmd on macOS) | `rts-group-set-N` | Assign the control group |
| 1..5 | `rts-group-N` | Recall the group. An empty group leaves the selection alone. A double tap within 20 ticks jumps the camera to the group. |
| Ctrl+A (Cmd+A) | `rts-select-all` | Select every own living unit |

Ctrl+A should consume only the chord, so plain A still reaches the vanilla move-left control and all four WASD keys should pan the remote camera again. No keyboard input was possible in these runs, so this is unverified until QA.

## Right-click event logic and dedupe

The spike #2 log shows the `rts-rclick` custom input and `on_player_reverse_selected_area` about 50 ms apart, not in the same tick (`build/camera-human.log`):

```
551.585 INPUT rts-rclick tick=31704 cursor_position={-1.91, 14.12}
551.635 SELECT on_player_reverse_selected_area ... entities=0
```

The custom input fires on button press. The area event fires on release, so for a drag it comes much later. A same-tick dedupe would issue every click twice. The implemented rule:

1. **The reverse-select events are the primary path.** Each one records `storage.orders.area_tick[player] = tick`, clears any pending fallback for that player and issues the order.
2. **`rts-rclick` never orders directly.**
   - It is ignored when `in_gui` is true (the HUD owns those clicks) or when an area event for the player was already handled in this tick.
   - Otherwise it parks `storage.orders.rclick[player] = {tick, position, entity = player.selected, wait}`.
3. **The `wait` depends on the cursor.**
   - It is 1 tick if the cursor did not hold the `rts-cursor` at the press. No area event can come then.
   - It is 120 ticks if the cursor did hold it. The area event comes on release.
4. **`on_tick` runs the pending fallback after `wait` ticks** if no area event cancelled it. It uses the same decision as a right click: armed means attack-move; an enemy under the cursor at the press means attack; otherwise move to the press position. The fallback is logged as `orders: player N right click at ... without a reverse-select event -> fallback ...`.

A right drag held longer than 2 s gets the fallback order first. The area order on release then overrides it.

The autotest covers all four orderings through `orders.handle_rclick` and `orders.handle_reverse_area`, the same functions the handlers call:
- the click, then the area event in the same tick;
- the area event, then the click in the same tick;
- a lone click with no tool in the cursor;
- a click with the tool in hand whose area event comes 60 ticks later.

## Orders

Every order takes `who`: a player index, which acts on that player's selection, or an array of `LuaEntity`. Each returns the number of units ordered. It only commands units whose `order` is `"idle"` or whose `issuer` is `"orders"`. Units claimed by another module, such as debug's `"autotest"` or match's enemy waves, are skipped.

| Order | Command | On `on_ai_command_completed` |
|---|---|---|
| `move(who, pos)` | `go_to_location`, `distraction = none`, radius 1, one formation slot per unit | `idle` + `stop` |
| `attack(who, entity)` | `attack_area` centred on the target, radius 4, `distraction = by_enemy` (see deviations) | Target alive: re-issued at the target's current position. Target gone: `idle` + `stop` |
| `attack_move(who, pos)` | `attack_area`, radius 8, `distraction = by_anything`, one formation slot per unit | More than 8 tiles from the slot: resume towards it. Arrived: nearest enemy within 30 tiles (`find_nearest_enemy`), else `idle` + `stop` |
| `stop(who)` | `stop` | (unclaimed; units.lua re-stops) |
| `hold(who)` | `stop`, `order = "hold"` | `stop` again |

The other rules:

- **Failed commands.** Three consecutive `fail` results on an attack or attack-move release the unit.
- **2 s sweep.** It releases attack units whose target is gone, and attack-move units that reached their slot with no enemy within 30 tiles. In both cases `attack_area` may never report completion.
- **Formation.** Slots form a grid of ceil(sqrt(n)) columns facing the direction of travel. Spacing is the widest collision box in the selection plus 0.75, with a minimum of 2.5. Units are matched to slots front-to-back, then left-to-right, so paths cross little.
  - Space Age: walkers alone get 2.55 and any heavy makes it 3.45.
  - Base game: 2.5.
- **Order feedback.** A circle drawn for 30 ticks, visible to the ordering player only. Move is green at the destination, attack is red on the target and attack-move is amber.

### Deviations from PHASE1, with evidence

1. **Attack uses `attack_area` on the target, not `defines.command.attack`.** On a spider-unit, `attack` reports `success` on nearly every tick while the target lives, with or without a distraction. The PHASE1 version, `attack` with `by_enemy` and release on completion, left six walkers idle 22 tiles from a lone enemy for 20 s. Measured against one 200 hp enemy walker (one run each; the duel is noisy):

   | Variant | Time to kill | Completion events |
   |---|---|---|
   | `attack`, `by_enemy`, re-issued while alive | ~16 s | ~5000 |
   | `attack`, `none`, re-issued | 7–9 s | 550–1800 |
   | `attack_area` r=4 on target, `by_enemy`, re-issued | ~8 s | 14 |
   | `attack_area` r=4 on target, `none` | not in 20 s | 42 |

   `ATTACK_MODE` in `orders.lua` switches back to `attack`. The cost of `attack_area` is weaker focus fire: units hit any enemy within 4 tiles of the target.
2. **Attack and attack-move treat a completion as "keep going".** A distraction ends `attack_area` early with `result=success` and `was_distracted=true`. Without the resume rule, the first autotest attack-move stopped after its first fight: re-targeting found nothing within 30 tiles, and the units went idle far from the enemy army. With the rule they reach the enemy, and re-targeting takes over there.

## API for hud.lua and other modules

`selection` (all take a player index; index 0 is the autotest's fake commander):

- `get(i)` returns an array of valid `LuaEntity`; dead units are pruned on the way.
- `count(i)` returns the number of selected units.
- `count_by_kind(i)` returns `{walker = n, heavy = m}` and the total.
- `is_selected(i, unit_number)`.
- `set(i, entities)` replaces the selection and `add(i, entities)` adds to it; both return the new size.
- `clear(i)`.
- `select_all(i)` returns the count.
- `group_set(i, n)` returns the group size and `group_recall(i, n)` returns the number selected (0 means the group was empty).
- `group_count(i, n)`.
- `handle_area(i, entities, area, add)` is the selection-tool logic.
- `box_count(i)` and `box_offsets(entity)` are for tests.
- `notify_hud(i)`, `real_player(i)` and `force_name(i)`.
- `MAX_GROUPS = 5`.

`orders`:

- `move(who, pos)`, `attack(who, entity)`, `attack_move(who, pos)`, `stop(who)`, `hold(who)`.
- `arm_attack_move(i, on)`: `on = nil` toggles; returns the new state.
- `is_armed(i)`.
- `handle_reverse_area(i, entities, area, alt)` and `handle_rclick(i, position, hovered, holds_tool, in_gui)`.
- `formation(recs, center)`, `spacing(recs)` and `stats()`. The stats counters are `issued`, `completed`, `retargets`, `resumed`, `swept`, `released`, `fallbacks` and `area_orders`.
- `ISSUER = "orders"`.

HUD refresh: selection.lua calls `hud.refresh(player_index)`, when that function exists, after every selection change, group change and attack-move arm change. Unit deaths remove units from selections and groups; their refreshes are batched into the next tick through `storage.selection.dirty`. The fake index 0 never reaches the HUD.

## Storage

- **`storage.players[i]`** (owned by selection.lua):
  - `selection = {[unit_number] = true}`
  - `groups = {[1..5] = {[unit_number] = true}}`
  - `boxes = {[unit_number] = LuaRenderObject}`
  - `group_recall = {n, tick}`
- **`storage.selection`**: `{dirty = {[player_index] = true}}`.
- **`storage.orders`**:
  - `armed = {[i] = tick}`
  - `rclick = {[i] = {tick, position, entity, wait}}`
  - `area_tick = {[i] = tick}`
  - `stats`
- **`storage.units[n]` fields written by orders.lua**: `order`, `dest`, `target`, `issuer = "orders"` and `fails`. orders.lua handles completions only when `issuer == "orders"`, because match.lua also writes `order = "attack_move"`.
- **Missing tables are created on first use.** A save made with an older build of these modules works without `on_configuration_changed`, which does not fire for script-only changes at the same version.

## Validation

| Check | Result |
|---|---|
| Headless with Space Age, 80 s, copy `build/sel-sa` | 29 PASS, 0 FAIL, 0 errors |
| Headless without Space Age, quality or elevated-rails, 80 s, `build/rts-nosa` | 29 PASS, 0 FAIL, 0 errors |
| `--check-unused-prototype-data --create` with `mods` | No warnings |
| GUI with the self-test on, copy `build/rts-selftest` (`SELFTEST_DEFAULT = true`) | 0 errors |
| GUI with the self-test off, copy `build/sel-off` (identical to `mods`) | 0 errors |

What the self-test-on GUI run did:
- It selected all 24 units, drew 24 boxes, assigned group 1, cleared it (0 boxes) and recalled it (24 boxes).
- It moved the army 12 tiles and finished with `RTS_GUI_READY`.

What the self-test-off GUI run did:
- No camera or selection self-test step ran.
- The `RTS_GUI_READY` line still came at setup + 960 ticks.

The runs used named copies because another agent was running `headless-run.sh` on `mods` at the same time. Both runs write `build/mods-server.log`, so one run's log was overwritten by the other's.

Screenshots in `build/shots-rts-selftest/`:

- **`rts-p1-210.png`.** All 24 units have light-blue boxes around the raised torsos, visible in remote view (`render_mode=chart_zoomed_in`). The HUD reads "24 units selected, Walker ×20 Heavy ×4". This screenshot was taken with 0.15 tiles of padding, and walker boxes touched on the 3-tile spawn grid; padding is now 0.
- **`rts-p1-270.png`.** The green move marker is visible. The HUD shows "Order: Move" and "1: 24".
- **`rts-p1-900.png`.** The army has arrived in a spread block, and the boxes followed the units.

Excerpt from the autotest log (Space Age):

```
autotest check move_spread: PASS min distance between formation slots=3.45 around (-25.0, 0.0)
autotest check move_completed: PASS all 6 moves completed, units released to idle/stop: 6 units
autotest check hold_kept: PASS max drift 1.17 tiles in 3s (spider-units coast up to ~3), commands [stop=6], 6 units
autotest check lone_rclick_fallback: PASS fallbacks 0 -> 1, move issued to 6 units
autotest check tool_rclick_waits: PASS still pending after 60 ticks, fallbacks=1
autotest check armed_right_click_attack_moves: PASS armed=true order=attack_move still_armed=false 6 units
autotest check attack_engaged: PASS target hit after 3s
autotest check attack_released: PASS target gone, all attackers idle again after 1s (65 attack completions)
```

## Gotchas found

1. **`package.loaded` is keyed by the resolved file.** The key is `"__factorio-rts__/scripts/hud.lua"`, not the `require()` argument. `require()` is not allowed in event handlers, so modules that would form a require cycle look each other up by that key. hud.lua does the same.
2. **`defines.command.attack` completes on nearly every tick for spider-units.** See the deviations above.
3. **`attack_area` ends early on every distraction.** It reports `success, was_distracted=true`. It does not complete while a unit stands at its destination with no enemy around, hence the sweep.
4. **`stop` with the default `by_enemy` distraction completes after each distraction.** Spike #3 only saw it never complete with no enemies around. Idle units within sight of an enemy therefore produce about 3 completions per second each. units.lua re-stops them and they stay put. It works, but it is event traffic.
5. **The selection box of a spider-unit is raised.** `entity.selection_box` is shifted up by the torso height: about 1.5 tiles for the Space Age walker and 0.7 for the heavy. `prototype.selection_box` is centred on the position. Boxes use the entity's box, captured at selection time; render offsets are fixed after that.
6. **A lone strafer dodges most projectiles.** Six walkers took 8 s to more than 20 s to kill one, at about 1 hit in 6 shots. This is a balance note for `prototypes/units.lua`. The autotest therefore checks that the target is hit, and kills it by script 8 s after the first hit to test the target-gone path.
7. **The attack-move arming text cannot be checked in a screenshot.** `create_local_flying_text{create_at_cursor = true}` puts it at the cursor. Screenshots have no cursor, so it showed up at the top-left corner.

## Follow-ups (resolved)

- **PHASE1.** The integration agent updated the text: F, X and H, plus the attack and attack-move behaviour as built.
- **HUD self-test.** All HUD dev steps now run only when `camera.selftest_enabled()` is true. The HUD agent checked this with GUI runs, once with the switch off and once with it on.
- **The self-test is still available.** Run `/rts-selftest on` in game, or copy the mod with `SELFTEST_DEFAULT = true` as in `build/rts-selftest`.
- **Later changes by the integration agent are not covered by the validation above.** They own `mods/factorio-rts/` from here on.
  - **Log lines.** They added QA log lines to selection.lua and orders.lua and changed the group-set line to `group set N n=M player=P`.
  - **Reset.** They added `/rts-qa-reset` and `orders.reset()`.

## Open items for interactive QA

- WASD panning with no game-only inputs left on those keys.
- F, X, H and the digit keys with the real keyboard. The quickbar must not react.
- A real right drag over enemies, and Shift + right drag.
- A right click while the cursor is empty: the fallback path.
- Double-tap recall.
- The box and marker visuals at the default zoom.
