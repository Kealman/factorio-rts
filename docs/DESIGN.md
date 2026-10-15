# Factorio RTS — Design Document (v0.2, 2026-10-15)

> Phase 0 spike verdicts and the decisions taken from them: `research/spikes.md`.

## 1. Vision

A Factorio 2.0 mod that plays like a StarCraft-style RTS:

- **RTS control, not a character.** Free-scrolling camera, box-select, right-click to move/attack, control groups, a command panel and a minimap.
- **Factorio economy as the base-building layer.** Resources are ore patches; production chains (smelting, assembling, research) replace the classic "spend 50 minerals" model. Units, buildings and upgrades are *items* produced by chains and converted into entities on the map.
- **Symmetric opponents.** 1–7 AI forces that start with the same command center, mine the same resources, build real factories and send real armies. Biters are optional neutral fauna, not the main enemy.
- **Match structure.** A game is a match on one surface with spawn points, fog of war per force, and a win condition (destroy all enemy command centers).

## 2. Why Factorio 2.0 makes this feasible

Verified against the offline API docs (see `research/api-capabilities-2.0.77.md`) and headless runtime probes:

| Need | Mechanism | Status |
|---|---|---|
| RTS camera | `remote` controller (2.0 map/remote view) with `set_zoom_limits{furthest_game_view}`; fallback `god` controller | documented, persistence w/o character untested |
| Box select | `selection-tool` item with `select = {mode={"any-entity","same-force"}, entity_type_filters=...}` → `on_player_selected_area` | confirmed; works in remote view per changelog |
| Point orders | `reverse_select` of the same tool (area center = click point, entities = target) and/or `custom-input` on `mouse-button-2` with `cursor_position` | confirmed; remote-view firing untested |
| Controllable units | `unit` / `spider-unit` entities via `LuaCommandable` (`go_to_location`, `attack`, `attack_area`, `stop`, `compound`), `on_ai_command_completed` | **confirmed at runtime** (probe: biter in custom force reached its destination) |
| Many forces | up to 64 forces, `set_cease_fire`/`set_friend`, per-force chart & fog | confirmed at runtime (force creation) |
| Team colors | `spider-unit` is force-tinted; `spider-vehicle`/`character` have `color`; plain `unit` needs per-team prototypes | partial |
| AI base building | `build_blueprint{force}` → ghosts → `revive`, `create_entity{force, recipe}`, `clone_area` | documented |
| AI armies | `LuaSurface.set_multi_command`, unit groups, `set_autonomous` | documented |
| Overlays / UI | `rendering.draw_*` with `players` filter, `highlight-box`, `LuaGui` screen frames, `minimap` & `camera` elements | documented |
| Headless dev loop | `--create` + `--start-server`, Lua `log()` | **confirmed at runtime** (`tools/headless-run.sh`) |

Known hard limits (shape the design, do not block it):

1. **No continuous mouse world position.** Only click/drag events deliver positions. Hover highlighting therefore uses `LuaPlayer.selected` + `on_selected_entity_changed`; drag rectangles use the native selection-tool box.
2. **No runtime tint for `unit`.** Use `spider-unit` (force-tinted) as the primary unit class, or generate one `unit` prototype per team slot at data stage.
3. **Scripted unit groups need `force.ai_controllable = true`,** which also enables engine-driven expansion for that force. Single-entity `commandable` orders do not need it. We command units individually or via groups created on demand and keep `ai_controllable` off for player forces unless groups prove necessary.
4. **`max_failed_behavior_count`** can destroy units whose orders keep failing. Set it very high in map settings.

## 3. Core design decisions

### 3.1 Controller: remote view as the RTS camera
- On join, the player's character is removed (or never created: freeplay crash site disabled) and the player is put into `defines.controllers.remote` centered on their command center.
- `set_zoom_limits` keeps full game rendering when zoomed far out; `GameViewSettings` hides the vanilla HUD pieces we do not want (quickbar, crafting, inventory).
- A permission group strips input actions that break the RTS illusion (`toggle_map_editor`, `open_character_gui`, `craft`, …), while allowing `select_area`, `build`, `remote_view_surface`, GUI actions.
- Fallback if remote view cannot persist without a character: `god` controller with a custom `GodControllerPrototype` (no inventory, high `movement_speed`), building via ghosts only.

### 3.2 Input model
- The cursor permanently holds an **RTS Cursor** selection tool (re-inserted on `on_player_cursor_stack_changed`).
  - **Left drag**: `select` → replace selection with friendly controllable entities in the box.
  - **Shift + left drag**: `alt_select` → add to selection.
  - **Right click/drag**: `reverse_select` → order. If the area contains an enemy entity → `attack`; a friendly entity → follow/escort; nothing → `go_to_location` at the area center. Right-drag with Shift → `attack_area` (attack-move).
- Keyboard `custom-input`s: `Ctrl+1..9` assign control group, `1..9` recall, `S` stop, `H` hold, `A` attack-move modifier, `F2`/`Space` jump camera to base/last event.
- Build mode: pressing a build hotkey or clicking a panel button puts the building item ghost into the cursor (vanilla ghost placement in remote view), then restores the RTS Cursor on placement.
- Vanilla spidertron remote stays available as an *optional* path for spider-vehicles (it is already "RTS-like" in 2.0.7+).

### 3.3 Units
- **Primary class: `spider-unit`** (Gleba pentapod engine). Not Space Age gated, force-tinted, commandable, has `attack_parameters`, legs look like mechs. We define our own prototypes (marine/walker, heavy walker, artillery walker) reusing vanilla pentapod graphics with tint, or biter graphics as a fallback for `unit`-class swarm units.
- **Secondary class: `unit`** for cheap swarm units (biter/spitter sprites, per-team tinted prototypes generated at data stage). Zero pathing code needed.
- **Workers:** construction robots from the command center's roboport build ghosts placed in remote view. This is the SCV analog and is fully vanilla.
- **Vehicles (`spider-vehicle`)** as a later, hero-tier unit (autopilot, auto-targeting, color).
- Every unit prototype gets `radar_range` so armies reveal fog for their force.
- Idle units wander by default; we issue `defines.command.stop` on `on_ai_command_completed` so they hold position (spike #3: `wander{radius=0}` only works for plain `unit`).
- Unit groups work without `force.ai_controllable` (spike #3), so player forces keep it off. Attack-move re-targets the nearest enemy entity instead of aiming at a centroid.

### 3.4 Economy and production (the Factorio half)
- **Command Center**: a composite — roboport (construction area), storage/provider chests, a small power source — placed as one blueprint. Losing all command centers loses the match.
- **Resources**: vanilla ore patches as mineral fields; mining drills + belts/bots feed smelting. Power is the "gas" analog (steam early, solar later).
- **Units as recipes**: assemblers with `rts-barracks` crafting category produce *unit items* (`rts-marine`, `rts-walker`). A `Barracks` entity (custom assembling machine) is checked at the predicted craft-completion tick (from `crafting_progress`, recipe energy and `crafting_speed`), with a slow fallback sweep; finished unit items in its output are consumed and spawned as entities at its rally point (spike #4: 0-tick latency, ~6 µs per check). Production time and ingredient chains give RTS "build time" and "tech cost".
- **Buildings as items**: regular Factorio placeables built by bots from ghosts. Build time = bot travel + item availability, so expanding your logistics network is a core skill.
- **Research**: vanilla labs and a trimmed tech tree (unit tiers, armor/damage upgrades, new buildings). Uses `LuaForce.technologies` per force.
- **Scale**: compressed early game. Starting inventory in the command center chests (ores, plates, a few drills/assemblers) so the first unit appears within ~2 minutes.

### 3.5 AI opponents
- Phase A ("scripted commander"): each AI force follows a **build order script** (data-driven JSON/Lua table of steps: place blueprint X at anchor Y when items Z are in storage). Bases are placed via `build_blueprint{force, build_mode}` + paced `revive` (visible construction), production is real Factorio production, so the AI's army size is bounded by its actual factory (spike #5: works with no players in the force; verify ghost counts because drills without ore are skipped silently; clear blocking trees before revive).
- Army control: periodic evaluation — gather idle units into a group with `create_unit_group` (no `ai_controllable` needed), send `attack_area` to the nearest known enemy structure, retreat on heavy losses. `set_multi_command` only picks plain `unit` entities, so walker waves use explicit groups.
- Phase B: adaptive AI (scout → counter-compose, expand to new patches, defend chokes). Possible external brain via `--enable-lua-udp` bridge for experiments, but the shipped game must be pure Lua.
- Difficulty knobs: build-order speed multipliers, starting stock, aggression timers.

### 3.6 Fog of war and vision
- Vanilla per-force charting; `share_chart` off between enemies, on for allies. Units/buildings reveal via `radar_range`/radars.
- Minimap GUI element per player; map markers for pings via `render_mode = "chart"` rendering.

### 3.7 HUD
- Bottom command panel (`LuaGui.screen` frame): selection portrait grid, command buttons (move, attack, stop, hold, patrol), build menu tabs (economy / military / defense), resource summary (plates, circuits, power headroom), unit count.
- Selection boxes: `highlight-box` entities with `render_player_index` or `rendering.draw_rectangle` attached to entities, player-filtered. Health bars via `rendering.draw_rectangle`.
- Event feed: "Base under attack" text + camera jump hotkey.

## 4. Open questions to settle with spikes (Phase 0)

| # | Unknown | Spike |
|---|---|---|
| 1 | Can a player stay in `remote` controller with no character indefinitely? Does respawn logic interfere? | **CONFIRMED** (see `research/spikes.md`) |
| 2 | Do `custom-input` mouse buttons and selection tools fire in remote view with correct `cursor_position`/area? | **OPEN**: test mod and protocol ready in `spikes/camera-input/`, needs a human or computer-use run |
| 3 | `spider-unit` with our prototype: force tint visible, `commandable` works, attack behavior sane? | **CONFIRMED** headless (tint needs a visual check) |
| 4 | Barracks pattern: assembler output → spawn entity; latency and UPS | **CONFIRMED** |
| 5 | AI base placement: `build_blueprint{force}` + revive timing; does production run for a force with no players? | **CONFIRMED** |
| 6 | Does `on_gui_click` work on `minimap`/`camera` elements (click-to-jump)? | **OPEN**: same test mod as #2 |

Everything headless-testable runs through `tools/headless-run.sh`; interactive spikes need the GUI client and a human (or screenshot-based) check.

## 5. Roadmap

- **Phase 0 — Spikes (1–2 days).** Answer the six unknowns above. Output: `docs/research/spikes.md` with verdicts, plus the mod skeleton `mods/factorio-rts/`.
- **Phase 1 — Control vertical slice.** Two forces on a small map, RTS camera, RTS Cursor select/orders, 20 spider-units per side, selection boxes, control groups, hotkeys. No economy. Success: it *feels* like an RTS skirmish.
- **Phase 2 — Economy slice.** Command center blueprint, starting stock, barracks → units, bot construction from remote view, trimmed tech tree, resource HUD. Success: build order from zero to a 10-unit army in ~8 minutes.
- **Phase 3 — AI opponent v1.** Scripted build order, timed attack waves, defends base. Fog of war, victory/defeat. Success: a losable 1v1.
- **Phase 4 — Depth.** More unit types (swarm `unit`, spider-vehicle hero, static defenses), 1vN, adaptive AI, map generator presets for arenas, polish, team colors, sounds.

## 6. Repository layout (proposed)

```
factorio_rts/
  mods/factorio-rts/        # the mod (info.json, data.lua, control.lua, prototypes/, scripts/, graphics/)
  tools/                    # headless-run.sh, factorio-env.sh, server-settings.json
  docs/                     # DESIGN.md, research/, spikes.md
  build/                    # generated saves and logs (git-ignored)
```

## 7. Risks

- **Interaction feel**: Factorio's selection tool and remote view were not designed for twitch RTS control; some friction (cursor item juggling, no hover position) is unavoidable. Mitigation: Phase 1 is purely about feel, before investing in economy.
- **Idle-unit wandering and pathing stalls** for `unit` class entities; `spider-unit` behavior under many simultaneous orders is unknown.
- **AI economy realism**: a real factory per AI force is UPS-cheap but needs careful templating so the AI does not stall on logistics; the build-order DSL must include simple self-repair ("if belt empty, rebuild").
- **Scope**: the Factorio half is deep; keep tech tree and recipes small and data-driven so iteration stays fast.
