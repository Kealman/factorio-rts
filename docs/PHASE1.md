# Phase 1 — Control vertical slice

Goal: a 1v1 skirmish map with no economy where the player controls 20 walkers against 20 enemy walkers with RTS controls. Success = it feels like an RTS skirmish: free camera, box select, right-click orders, control groups, selection boxes, a minimal HUD.

Verified facts this phase builds on: `research/spikes.md` (decisions 1–13). Reuse code from `spikes/camera-input/` (controller guard, cursor re-insert, inputs) and `spikes/units/` (spider-unit prototypes, stop/hold, attack re-targeting).

## Mod layout

```
mods/factorio-rts/                # mod name "factorio-rts", version 0.1.0, factorio_version "2.0", "? space-age"
  info.json
  settings.lua                    # (later)
  data.lua                        # requires prototypes/*
  prototypes/
    units.lua                     # rts-walker, rts-walker-heavy (spider-unit), optional pentapod graphics
    cursor.lua                    # rts-cursor selection-tool + shortcut
    inputs.lua                    # custom-input prototypes (see Input map)
    styles.lua                    # GUI styles
    map-settings.lua              # max_failed_behavior_count etc.
  control.lua                     # requires scripts/*, wires events through scripts/events.lua
  scripts/
    events.lua                    # tiny multi-handler event bus: events.on(defines.events.X, fn), events.on_nth_tick(n, fn)
    util.lua                      # logging (log prefix "[rts]"), position math, force helpers
    camera.lua                    # remote-view controller: setup on join, desired-controller guard, zoom, hide vanilla chrome, permission group
    cursor.lua                    # give/re-insert the rts-cursor tool; handles Q/F1
    units.lua                     # unit registry in storage.units, spawn(), on death cleanup, idle -> stop
    selection.lua                 # per-player selection set, area events, selection boxes (rendering), control groups
    orders.lua                    # move / attack entity / attack-move / stop for a selection; attack re-targeting
    hud.lua                       # bottom panel + minimap; selection summary; command buttons
    match.lua                     # Phase 1 arena: flat area, forces rts-player / rts-enemy, spawn 20 walkers each, dumb enemy AI (attack-move every N s)
    debug.lua                     # /rts-* console commands for testing (spawn, select all, dump state)
```

## storage schema (owned by one module each; others read only)

```lua
storage.players[player_index] = {
  desired_controller = "remote",          -- camera.lua
  selection = { [unit_number] = true },   -- selection.lua
  groups = { [1..9] = { [unit_number] = true } },  -- selection.lua
  boxes = { [unit_number] = LuaRenderObject },      -- selection.lua
  hud = { frame = LuaGuiElement, ... },   -- hud.lua
}
storage.units[unit_number] = { entity = LuaEntity, force = "rts-player", kind = "walker", order = "idle"|"move"|"attack"|"attack_move"|"hold", target = LuaEntity? , dest = MapPosition? }  -- units.lua / orders.lua
storage.match = { phase = "running", tick_started = n, enemy_next_wave = n }  -- match.lua
```

## Input map (prototypes/inputs.lua)

| Name | key_sequence | consuming | Purpose |
|---|---|---|---|
| rts-lclick | mouse-button-1 | none | log/hover helper only (selection comes from the tool) |
| rts-rclick | mouse-button-2 | none | order at cursor (fallback; primary path is reverse_select) |
| rts-attack-move | A | game-only | next right click = attack-move |
| rts-stop | S | game-only | stop selected |
| rts-hold | H | game-only | hold position (stop + flag) |
| rts-group-set-N | CONTROL + N (1..5) | game-only | assign control group |
| rts-group-N | N (1..5) | game-only | recall control group (must consume so the quickbar does not react) |
| rts-select-all | CONTROL + A | game-only | select all own army on screen? (Phase 1: all) |
| rts-camera-home | SPACE | game-only | jump camera to own spawn |
| rts-give-cursor | F1 | none | re-give the cursor tool |

Selection tool `rts-cursor`: `select` = own controllable entities (mode any-entity + same-force, entity_type_filters spider-unit/unit), `alt_select` = same (add to selection), `reverse_select` = any entity (mode any-entity, include enemies) → order, `alt_reverse_select` = attack-move. A 0×0 reverse area whose entity list is empty = move to center; containing an enemy = attack that entity; containing own unit = follow is out of scope (treat as move).

## Orders (orders.lua)

- `move(selection, pos)`: `go_to_location` with `distraction = none`, spread targets in a small grid so units do not stack.
- `attack(selection, entity)`: `attack` command on the entity with `distraction = by_enemy`.
- `attack_move(selection, pos)`: `attack_area{destination=pos, radius=8}` with `distraction = by_anything`; on completion, re-issue toward the nearest enemy within 30 tiles, else `stop`.
- `stop(selection)`: `defines.command.stop`.
- `on_ai_command_completed` → unit state update; idle units get `stop` (they wander otherwise).

## Rendering

- Selection box: `rendering.draw_rectangle` attached to the entity (target = entity), per-player (`players = {idx}`), colour by force, width 2, drawn when selected; health bar under selected units (optional).
- Order feedback: brief `rendering.draw_circle` at the destination, `time_to_live = 30`.

## HUD (hud.lua)

Bottom-left `screen` frame: selection count + list by kind, command buttons (Move cursor hint, Attack-move, Stop, Hold), group indicators 1–5. Top-right `minimap` (size 220) — click to jump the camera (spike #6 confirmed `on_gui_click` and `cursor_display_location`; map the click to a world position by minimap zoom and centre). Hide vanilla chrome: try `player.game_view_settings` (show_quickbar=false, show_shortcut_bar=false, show_minimap=false, show_side_menu=false, show_controller_gui=false, show_research_info=false, show_alert_gui=false); verify which exist in `LuaGameViewSettings` docs.

## Match (match.lua)

- On init: create forces `rts-player` (humans join it) and `rts-enemy`; mutual enemies; both cease-fire with `enemy` (biters) and keep the surface peaceful or disable enemy bases via map gen settings for the arena. `ai_controllable = false` on both.
- Flatten a 160×160 area around {0,0} (set_tiles grass), clear trees/rocks/cliffs/water via landfill.
- Spawn 20 `rts-walker` + 4 `rts-walker-heavy` per side at x = -50 and x = +50. Player camera starts at its army.
- Enemy brain: every 90 s, group all idle enemy units and `attack_area` the centroid of player units (re-target on completion). Trivial but gives a fight.
- Win/lose message when one side has 0 units.

## Dev loop

- Headless: `tools/headless-run.sh 60 '\[rts' mods` — no players, so match.lua must still run the arena setup and the enemy brain; add a `storage.debug.autotest` that spawns both armies and issues orders via the API to exercise orders.lua without a player.
- GUI: `tools/gui-run.sh mods 90 'MARKER'` (launched by the lead with the sandbox disabled if it crashes in a sandboxed shell); screenshots via `game.take_screenshot` into the run's `script-output`.
- Interactive QA: a written protocol in `docs/qa/phase1-protocol.md`, executed by the lead via Codex computer use.

## Acceptance checklist

1. Join → remote view over own army, no character, vanilla chrome hidden as far as the API allows, cursor tool in hand.
2. Left-drag selects own walkers only; boxes appear; Shift adds.
3. Right-click ground moves the selection in a spread; right-click enemy attacks it; A then right-click = attack-move; S stops.
4. Ctrl+1 / 1 control groups work and do not trigger the quickbar.
5. Minimap shows both armies; clicking it moves the camera.
6. Enemy waves come; fights resolve; win/lose message.
7. Headless autotest passes with zero errors; GUI run has zero script errors.
