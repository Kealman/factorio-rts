# Factorio 2.0.77 API capabilities for an RTS-style mod

Verified against the **offline docs of the installed game** (Factorio 2.0.77, build 84539, mac-arm64, Steam; `runtime-api.json` / `prototype-api.json` report `application_version: 2.0.77`, `api_version: 6`).
Research date: 2026-10-15. Nothing here was tested at runtime; the GUI game was not launched.

## Sources and conventions

| Short name | Path (under `~/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/`) |
|---|---|
| `DOC/` | `doc-html/` (HTML pages; anchors equal member names, e.g. `DOC/classes/LuaPlayer.html#set_controller`) |
| `RJSON` | `doc-html/runtime-api.json` (queried with Python; every runtime fact below was read from here, the HTML page is cited for convenience) |
| `PJSON` | `doc-html/prototype-api.json` |
| `DATA/` | `data/` (vanilla Lua prototypes and scenario scripts) |
| `CHANGELOG` | `data/changelog.txt` (official changelog shipped with the game; line numbers given, version in brackets) |

Verdicts:
- **CONFIRMED**: the docs state it explicitly.
- **PARTIAL**: part is stated, part is inferred or missing (the inferred part is marked).
- **UNCONFIRMED**: the docs are silent; needs a runtime test.
- **NOT AVAILABLE**: the docs show the API does not exist in 2.0.77.

---

## A. RTS camera / controller

### A1. `LuaPlayer.set_controller`, controllers, remote view — **PARTIAL**

`defines.controllers` (DOC/defines.html#controllers), with the doc descriptions:

| value | doc description |
|---|---|
| `character` | controls a character; default in freeplay |
| `god` | "isn't tied to a character. This is the default controller in sandbox." |
| `remote` | "Can't move/change items but can build ghosts/change settings." |
| `spectator` | "Can't change anything in the world but can view anything." |
| `editor` | "near ultimate power to do almost anything" |
| `ghost` | "Can't interact with the world, can only observe. Used in the multiplayer waiting-to-respawn screen." |
| `cutscene` | camera pans in a predefined manner |

`LuaPlayer.set_controller{...}` (takes a table; DOC/classes/LuaPlayer.html#set_controller):
- `type: defines.controllers` (required).
- `character?: LuaEntity`: mandatory for `character`, ignored otherwise.
- `position?: MapPosition`, `surface?: SurfaceIdentification`: only for `remote` ("the position the remote controller will be centered on" / "the surface the remote controller will be put on").
- `waypoints`, `start_position`, `start_zoom`, `final_transition_time`, `chart_mode_cutoff`: cutscene only.
- `god`, `spectator`: no type-specific parameters.
- `editor`: "auto promotes the player to admin and enables cheat mode" and "requires the calling player be an admin".

Remote view related members on `LuaPlayer` (all in RJSON):
- `physical_position` (R), `physical_surface` (R), `physical_surface_index` (R), `physical_vehicle` (R): "this player's physical controller".
- `physical_controller_type` (R): "When a player is in the remote controller, this specifies the controller they will return to."
- `centered_on` (RW, `LuaEntity?`): "The entity being centered on in remote view. When writing, the player will be switched to remote view (if not already in it) and centered on the given entity."
- `exit_remote_view()`: "Exit remote view if possible. Exiting will fail if the player is in a rocket or in a platform."
- `zoom` (RW, double): baseline 1; reads are clamped to `zoom_limits`.
- `zoom_limits` (RW, `ZoomLimits`) and `set_zoom_limits(controller_type, zoom_limits)`: limits are "defined and remembered per controller type". `ZoomLimits = {closest?, furthest?, furthest_game_view?}`, each a `ZoomSpecification {zoom?} | {distance?, max_distance?}`. `furthest_game_view` = "furthest zoom level at which the engine will render the game view. Zoom levels further than this limit will render using chart (map) view." Doc example mentions "a hard zoom limit at 800 tiles" (DOC/concepts/ZoomLimits.html, DOC/concepts/ZoomSpecification.html).
- `render_mode` (R only): `defines.render_mode.game | chart | chart_zoomed_in`.
- `position` is inherited from `LuaControl.position` ("The current position of the entity"). The existence of separate `physical_position` implies `position` is the remote-view position while in remote. **Inferred, not stated.**
- `zoom_to_world`, `open_map`, `close_map`: **NOT AVAILABLE**. CHANGELOG:3388 [2.0.7]: "Removed LuaPlayer::open_map, zoom_to_world, and close_map. LuaPlayer::set_controller with type 'remote' replaces these."

Other relevant facts:
- CHANGELOG:3077 [2.0.7]: "Switching to map view switches to remote controller now." Map view and remote view are the same thing in 2.0.
- `LuaControl.teleport` notes "`script_raised_teleported` will not be raised if teleporting a player with no character", so characterless players can be teleported.
- `DATA/space-age/prototypes/tips-and-tricks-simulations.lua:159` calls `player.set_controller{type = defines.controllers.remote, surface = ...}`.

**Can a player stay in `remote` indefinitely with no character?** UNCONFIRMED. No doc sentence says so. Indirect evidence: the vanilla sandbox scenario removes the character (`player.character = nil`, `DATA/base/script/sandbox/sandbox.lua:33-41`) leaving the god controller, and opening the map from there enters remote, so `physical_controller_type` would be `god`. Whether anything forces an exit, and whether the Escape key or the map toggle always leaves remote, must be tested. There is no `defines.input_action` for "exit remote view" that a permission group could block (checked the 279 `input_action` values).

### A2. The `god` controller — **PARTIAL**

- **Inventory: CONFIRMED.** `defines.inventory.god_main` exists. `GodControllerPrototype.inventory_size` exists, and core defines it as 80 (`DATA/core/prototypes/god-controller.lua`). The sandbox scenario inserts items into a god player (`util.insert_safe(player, ...)`). CHANGELOG:8812 [0.17.24] "Changed god controller inventory size to be the same as the character inventory size."
- **Reach / build distance: CONFIRMED.** `LuaControl.build_distance` and `reach_distance`: "max uint when not a character or player connected to a character".
- **Crafting / mining: CONFIRMED.** `GodControllerPrototype` has `crafting_categories`, `mining_categories`, `mining_speed`, `item_pickup_distance`, `loot_pickup_distance` (core: `{"crafting"}`, `{"basic-solid"}`, 1, 1, 2). `LuaControl.mining_state` may be written for `character`, `god` or `editor` only.
- **Instant building: UNCONFIRMED.** No doc sentence says god builds instantly. Building still consumes items from the cursor (`build_from_cursor` "The cursor stack will automatically be reduced as if the player built normally").
- **WASD movement: PARTIAL.** `GodControllerPrototype.movement_speed` ("Must be >= 0.34375"; core value 0.5) implies keyboard movement. CHANGELOG:10342 "Fixed that the god controller wouldn't trigger the player_moved event". The literal words "WASD" do not appear.
- **Zoom limits noted:** CHANGELOG:1544 [2.0.33] "Reduced how much you can zoom out in god controller"; CHANGELOG:1883 [2.0.25] "Reverted fix for god controller being able to zoom out to map view". `set_zoom_limits` can override this per controller type.
- CHANGELOG:7617: "The camera will zoom to center instead of zooming to cursor in God controller, Ghost controller and Spectator controller."

### A3. Which controller fits a scrollable RTS camera — **PARTIAL (comparison only)**

| Aspect | `remote` | `god` | `spectator` |
|---|---|---|---|
| Body | Keeps a physical controller (`physical_*`) | None | None |
| World changes | Ghosts and entity settings only | Full (with items) | None |
| Cursor stack | Yes (only spectator is documented as `nil`) | Yes | `cursor_stack` is `nil` |
| Inventory | "Can't move/change items" | `god_main`, 80 slots | n/a |
| Move speed prototype | `RemoteControllerPrototype.movement_speed` (core: 1) | `GodControllerPrototype.movement_speed` (core: 0.5) | `SpectatorControllerPrototype.movement_speed` (core: 0.5) |
| Programmatic camera | `set_controller{position, surface}`, `centered_on` (follow entity) | `teleport` | `teleport` |
| Map / chart at far zoom | Yes, it is the 2.0 map view; `render_mode` reports `chart_zoomed_in` (CHANGELOG:1673 [2.0.31]) | Limited zoom-out (A2) | n/a |
| Custom inputs | No prototype flag needed (UNCONFIRMED that they fire) | No prototype flag needed | Need `enabled_while_spectating = true` |
| Selection tools | Usable (CHANGELOG:5774 [1.1.0], CHANGELOG:2235 [2.0.19]) | Usable | No cursor |

Facts that favour `remote` for an RTS camera: built-in map-drag (`LinkedGameControl` has `drag-map`; CHANGELOG:230 mentions remote view dragging), entity GUIs open from afar (CHANGELOG:2916 [2.0.7]), surface list toggle (`GameViewSettings.show_surface_list`), and `centered_on`. Facts that favour `god`: real building from an inventory with unlimited reach. Both can be widened with `set_zoom_limits` and `furthest_game_view`. **Recommendation (judgement, not doc):** prototype the camera in `remote` over a characterless `god` physical controller and test A1's open questions first.

---

## B. Selection and commands

### B4. `selection-tool` prototype and area events — **CONFIRMED** (remote/map view support via changelog)

`SelectionToolPrototype` (`selection-tool`, parent `ItemWithLabelPrototype`; DOC/prototypes/SelectionToolPrototype.html):
- `select: SelectionModeData` (required), `alt_select: SelectionModeData` (required).
- `reverse_select?`, `alt_reverse_select?` ("using SHIFT + Right mouse button"), `super_forced_select?`: all `SelectionModeData`.
- `always_include_tiles?` (default false, "visual only"), `mouse_cursor?` (default `"selection-tool-cursor"`).
- `skip_fog_of_war?: boolean` (default false). **It exists but has no description.**

`SelectionModeData` (DOC/types/SelectionModeData.html): `mode: SelectionModeFlags` (required), `border_color` (required), `cursor_box_type` (required), `chart_color?`, `count_button_color?`, `entity_filters?: array[EntityID]`, `entity_type_filters?: array[string]`, `entity_filter_mode?: "whitelist"|"blacklist"`, `tile_filters?`, `tile_filter_mode?`, `started_sound?`, `ended_sound?`, `play_ended_sound_when_nothing_selected?`.

`SelectionModeFlags` (DOC/types/SelectionModeFlags.html). There is **no separate `force` field**; force filtering is done with mode flags. "Some flags only exclude objects from the selection, meaning they need to be combined with another flag to select anything."
- Selectors: `blueprint`, `deconstruct`, `cancel-deconstruct`, `items`, `trees`, `buildable-type`, `nothing` ("useful to select an area"), `items-to-place`, `any-entity`, `any-tile`, `upgrade`, `cancel-upgrade`, `downgrade`, `entity-with-health`, `is-military-target`, `entity-with-owner`, `entity-ghost`, `tile-ghost`.
- Force excluders: `same-force` ("Excludes entities that have a different force than the selecting player"), `not-same-force`, `friend`, `enemy`.
- Other excluders: `avoid-rolling-stock`, `avoid-vehicle`.
- `controllable`, `controllable-add`, `controllable-remove`: **no description**; vanilla uses them only on the spidertron remote (`DATA/base/prototypes/item.lua:2158-2187`).

Events (DOC/events.html):

| Event | Fired by | Fields |
|---|---|---|
| `on_player_selected_area` | `select` | `player_index, surface, area: BoundingBox, entities: array[LuaEntity], tiles: array[LuaTile], item: string, quality: string, tick, name` |
| `on_player_alt_selected_area` | `alt_select` | same as above |
| `on_player_reverse_selected_area` | `reverse_select` | same **without `quality`** |
| `on_player_alt_reverse_selected_area` | `alt_reverse_select` | same **without `quality`** |

No event is documented for `super_forced_select`. Script helpers: `LuaPlayer.start_selection(position, selection_mode)` ("Does nothing if the player's cursor is not a selection tool"), `LuaPlayer.clear_selection()`, `defines.selection_mode.{select, alt_select, reverse_select, alt_reverse_select}`.

Remote/map view: the API pages say nothing. CHANGELOG:5774 [1.1.0]: "Added support to use blueprints, deconstruction planners, upgrade planners, and modded selection tools from the map view." Combined with CHANGELOG:3077 (map view = remote controller), modded selection tools are meant to work in remote view. CHANGELOG:2235 [2.0.19] also fixed "selection tools ... chosen via remote ghost cursor gui".

### B5. `custom-input` prototype and `CustomInputEvent` — **CONFIRMED** (remote view firing UNCONFIRMED)

`CustomInputPrototype` (DOC/prototypes/CustomInputPrototype.html):
- `key_sequence: string` (required, default binding), `alternative_key_sequence?`, `controller_key_sequence?`, `controller_alternative_key_sequence?`.
- Modifiers: `CONTROL`, `SHIFT`, `COMMAND`, `ALT` joined with `" + "` (e.g. `"ALT + G"`). One normal key or mouse button per binding.
- Mouse names (doc list): `mouse-button-1` (left), `mouse-button-2` (right), `mouse-button-3` (middle), `mouse-button-4` … `mouse-button-9`, `mouse-wheel-up`, `mouse-wheel-down`, `mouse-wheel-left`, `mouse-wheel-right`.
- `consuming?: ConsumingType`, default `"none"`. Values: `"none"` (event fires and passes through to game events; "the custom input event will happen before the internal game event") and `"game-only"` ("block game events that conflict with the key sequence. Actions that are processed regardless of game paused state cannot be blocked").
- `action?`, default `"lua"`: `"lua" | "spawn-item" | "toggle-personal-roboport" | "toggle-personal-logistic-requests" | "toggle-equipment-movement-bonus"`. "A Lua event is only raised if the action is 'lua'."
- `item_to_spawn?: ItemID` for `spawn-item`; the item needs the `spawnable` flag.
- `include_selected_prototype?` (default false): adds `selected_prototype`; "also works in GUIs" and returns the cursor item if nothing is under the cursor.
- `linked_game_control?: LinkedGameControl`: the input fires when a vanilla control fires and is hidden from the controls GUI. 192 values, including `move-up/down/left/right`, `zoom-in`, `zoom-out`, `toggle-map`, `drag-map`, `build`, `mine`, `clear-cursor`, `pipette`, `reverse-select`, `alt-reverse-select`, `select-for-blueprint`, `deselect`, `open-gui`, `toggle-driving`, `shoot-enemy`.
- `enabled?` (default true), `enabled_while_spectating?` (default false), `enabled_while_in_cutscene?` (default false), `block_modifiers?` (default false).

`CustomInputEvent` fields (DOC/events.html#CustomInputEvent):
- `player_index`, `input_name`, `tick`, `name`.
- `cursor_position: MapPosition` (**yes**).
- `cursor_display_location: GuiLocation` (**yes**).
- `cursor_direction?: defines.direction`.
- `selected_prototype?: SelectedPrototypeData {base_type, derived_type, name, quality?}` (**yes**, if enabled on the prototype).
- `element?: LuaGuiElement` (added 2.0.56), `in_gui: boolean` (added 2.0.67).

Remote view: **UNCONFIRMED.** The prototype has opt-in flags only for spectator and cutscene, and the docs never mention remote. Needs a runtime test.

### B6. Cursor, selected entity, mouse position — **PARTIAL**

- `LuaControl.selected` (RW, inherited by `LuaPlayer`): "The currently selected entity". Writing raises `on_selected_entity_changed`.
- `LuaControl.update_selected_entity(position)`: "Select an entity, as if by hovering the mouse above it". `LuaControl.clear_selected_entity()`.
- `LuaControl.cursor_stack` (R `LuaItemStack?`, mutable object): "`nil` if the player controller is a spectator".
- `LuaControl.cursor_ghost` (R `ItemIDAndQualityIDPair`, W `ItemWithQualityID`): "Items in the cursor stack will take priority over the cursor ghost."
- `LuaControl.cursor_record`, `is_cursor_empty()`, `is_cursor_blueprint()`.
- `LuaPlayer.clear_cursor()` → boolean. `LuaPlayer.cursor_stack_temporary` (RW).
- `LuaPlayer.pipette_entity(entity, allow_ghost?)` is **deprecated** in favour of `LuaPlayer.pipette{id, quality?, allow_ghost?}`.
- `LuaPlayer.set_shortcut_toggled(prototype_name, toggled)`, `set_shortcut_available`, `is_shortcut_toggled`, `is_shortcut_available`. Requires `ShortcutPrototype.toggleable = true`.
- `LuaControl.set_gui_arrow{type, margin, ...}` with variants `entity`, `position`, `item_stack`, `crafting_queue`. "This is used in the tutorial." `clear_gui_arrow()`.
- `GameViewSettings.update_entity_selection`: "When `true` (the default), mousing over an entity will select it."
- `on_selected_entity_changed`: `player_index`, `last_entity?`, `tick`, `name`. It carries **no position**.
- **Continuous mouse world position: NOT AVAILABLE.** No `LuaPlayer` or `LuaControl` attribute exposes it. World positions arrive only in events:
  - `CustomInputEvent.cursor_position`
  - selection-area events (`area`)
  - `on_player_used_capsule.position`
  - `on_pre_build.position`
  - `on_player_used_spidertron_remote.position`

  `LuaSimulation.camera_player_cursor_position` exists but only inside tips-and-tricks simulations.

---

## C. Controllable units

### C7. `unit` prototype — **PARTIAL**

`UnitPrototype` (`unit`, parent `EntityWithOwnerPrototype`; DOC/prototypes/UnitPrototype.html). Description: "Entity that moves around and attacks players, for example biters and spitters."

- Required:
  - `attack_parameters: AttackParameters` ("Requires `animation` ... Requires `ammo_type`").
  - `movement_speed: float` ("tiles per tick").
  - `distance_per_frame: float`.
  - `run_animation: RotatedAnimation`.
  - `vision_distance: double`. "Max is 100. Note: Setting to 50 or above can lead to undocumented behavior of individual units creating groups on their own when attacking or being attacked."
  - `distraction_cooldown: uint32`.
- Optional:
  - `ai_settings?: UnitAISettings`.
  - `has_belt_immunity?` (default false), `affected_by_tiles?` (default false), `can_open_gates?`, `move_while_shooting?`.
  - `max_pursue_distance?` (50), `min_pursue_time?` (600 ticks), `rotation_speed?` (0.025).
  - `radar_range?: uint32` (default 0): "In chunks. The radius of how many chunks this unit charts around itself."
  - `absorptions_to_join_attack?`, `spawning_time_modifier?`.
  - `alternative_attacking_frame_sequence?`, `light?`, `render_layer?`, sounds.
- `is_military_target?` is typed literal **`true`** and `allow_run_time_change_of_is_military_target?` literal **`false`** for units. Units are always military targets and cannot be toggled.
- `UnitAISettings` (DOC/types/UnitAISettings.html): `destroy_when_commands_fail` (false), `allow_try_return_to_spawner` (false), `do_separation` (true), `join_attacks` (true), `path_resolution_modifier` (0, range -8..8), `size_in_group` (1.0), `strafe_settings?`. Runtime copy: `LuaEntity.ai_settings → LuaAISettings`, writable fields.
- **Player-force units: PARTIAL.** No restriction is stated anywhere. Supporting doc evidence:
  - `LuaSurface.create_entity` takes `force?` (default enemy).
  - The `LuaSurface.find_units` doc example reads `-- Find units of "player" force`.
  - Vanilla biters carry the `placeable-player` flag, which only "Determines the default force when placing entities in the map editor".
- **`LuaEntity.color` on units: NOT AVAILABLE.** The doc lists "character, rolling stock, corpse, character corpse, train stop, simple-entity-with-owner, car, spider-vehicle, or lamp" only.
- Force-colour alternative: `SpriteParameters.apply_runtime_tint` exists on all animation layers. CHANGELOG:378 [2.0.63] "Fixed spider unit graphic layers with 'apply_runtime_tint' would not use the force color" confirms force tinting for **spider-unit**. For `unit` it is UNCONFIRMED. `LuaForce.custom_color` (RW) sets the force colour.

### C8. `LuaCommandable`, unit groups, commands — **CONFIRMED**

`LuaCommandable` (DOC/classes/LuaCommandable.html): "AI object which can be ordered commands. This can represent a UnitGroup ... or can be a single Unit or SpiderUnit." Obtained via `LuaEntity.commandable` ("Units and SpiderUnits are commandable", otherwise `nil`). CHANGELOG:3520-3522 [2.0.7]: `LuaUnitGroup` renamed to `LuaCommandable`, and "Removed LuaEntity::set_command, set_distraction_command, command, distraction_command and moving".

- **Methods**
  - `set_command(command: Command)`
  - `set_distraction_command(command: Command)`
  - `add_member(member: LuaCommandable|LuaEntity)`: "must have the same force be on the same surface as the group"
  - `release_from_spawner()`
  - `start_moving()`: "start moving even if some of its members haven't yet arrived"
  - `set_autonomous()`: "Autonomous groups will automatically attack polluted areas"
  - `destroy()`: members are unlinked, not destroyed
- **Attributes**
  - `command`, `distraction_command`, `has_command`
  - `is_entity`, `entity`, `is_unit_group`
  - `members` (recursive), `commandable_members`, `parent_group`
  - `is_script_driven`: groups from `create_unit_group` are script-driven
  - `state: defines.group_state`: `gathering, moving, attacking_distraction, attacking_target, finished, pathfinding, wander_in_group`
  - `moving_state: defines.moving_state`: `adaptive, moving, stale, stuck`
  - `position`, `surface`, `force`, `spawner`, `unique_id`, `valid`
- **No `LuaEntity.start_moving`/`set_autonomous`** exist. They are `LuaCommandable` methods. `LuaEntity.release_from_spawner()` also exists.
- `LuaSurface.create_unit_group{position, force?}`: force "Defaults to "enemy"". Raises `on_unit_group_created`.
- **Important:** `LuaForce.ai_controllable` doc: "It is necessary for a force to be AI controllable in order to be able to create unit groups or build bases from scripts." Setting it `true` also lets biters of that force "automatically expand into new territories, build new spawners, and form unit groups".
- `LuaSurface.set_multi_command{command, unit_count, force?, unit_search_distance? (150)}`: "This will automatically select suitable units for the task" and returns the number sent.

`defines.command`: `attack`, `go_to_location`, `compound`, `group`, `attack_area`, `wander`, `flee`, `stop`, `build_base`.
`defines.distraction`: `none`, `by_enemy`, `by_anything` ("including entities 'built' by player"), `by_damage`.
`defines.compound_command`: `logical_and`, `logical_or`, `return_last`.
`defines.behavior_result`: `success`, `fail`, `deleted`, `in_progress`.

`Command` (DOC/concepts/Command.html); `distraction?` defaults to `by_enemy` everywhere:
- `attack`: `target: LuaEntity`.
- `go_to_location`: `destination?` or `destination_entity?` (entity wins), `pathfind_flags?: PathfinderFlags`, `radius?` (default 3).
- `attack_area`: `destination`, `radius`.
- `stop`: `ticks_to_wait?: MapTick` (default max uint64, "stop forever").
- `wander`: `radius?` (10), `ticks_to_wait?`, `wander_in_group?`.
- `flee`: `from: LuaEntity`.
- `group`: `group: LuaCommandable`, `use_group_distraction?` (true).
- `build_base`: `destination`, `ignore_planner?`.
- `compound`: `commands: array[Command]`, `structure_type`.
- `PathfinderFlags`:
  - `allow_destroy_friendly_entities`
  - `allow_paths_through_own_entities`
  - `cache` (default true)
  - `low_priority`
  - `no_break`
  - `prefer_straight_paths`

Events:
- `on_ai_command_completed`: `unit_number` ("unit_number/group_number"), `result: defines.behavior_result`, `was_distracted: boolean`.
- `on_unit_group_finished_gathering`: `group`.
- `on_unit_added_to_group` and `on_unit_removed_from_group`: `group, unit`.
- `on_unit_group_created`: `group`.
- `on_build_base_arrived`: `group?, unit?`.

Limits:
- `UnitGroupMapSettings.max_unit_group_size` (default 200) "only affects automatically created unit groups, manual groups created through the API are unaffected". No hard cap for scripted groups is documented.
- `MapSettings.max_failed_behavior_count`: "If a behavior fails this many times, the enemy (or enemy group) is destroyed."
- Vanilla example: `DATA/base/script/wave-defense/wave_defense.lua:836-854` (`create_unit_group` + `set_command`) and `:1743` (`unit.commandable.set_command`).

### C9. `spider-unit` prototype — **CONFIRMED**

`SpiderUnitPrototype` (`spider-unit`). **Its parent is `EntityWithOwnerPrototype`, not `UnitPrototype`**. It is still commandable via `LuaEntity.commandable` (C8), and `LuaEntity.ai_settings` lists subclasses `Unit` and `SpiderUnit`.
- Required: `attack_parameters`, `spider_engine: SpiderEngineSpecification` (`legs`, `walking_group_overlap?`), `height`, `vision_distance` ("<= 100"), `distraction_cooldown`.
- Optional: `ai_settings?: UnitAISettings`, `radar_range?` (chunks), `graphics_set?`, `torso_bob_speed?`, `torso_rotation_speed?`, `max_pursue_distance?`, `min_pursue_time?`, `spawning_time_modifier?`, `absorptions_to_join_attack?`, `warcry?`, `dying_sound?`.
- There is no `movement_speed` field; movement comes from the legs (`SpiderLegPrototype.initial_movement_speed`, `movement_acceleration`, etc.).
- **Not Space Age gated.** PJSON has no `visibility: space_age` on it, unlike `SegmentedUnitPrototype`. Base defines `dummy-spider-unit` (`DATA/base/prototypes/entity/enemies.lua:919`). Pentapods are `spider-unit` in `DATA/space-age/prototypes/entity/enemies.lua:3610, 5112` and are spawned by `gleba-spawner` (`:6250`).

### C10. `spider-vehicle` — **PARTIAL**

- `SpiderVehiclePrototype` (parent `VehiclePrototype`):
  - `spider_engine`, `height`, `inventory_size`, `trash_inventory_size?`, `guns?: array[ItemID]`.
  - `movement_energy_consumption`, `energy_source` (burner or void), `automatic_weapon_cycling`, `chain_shooting_cooldown_modifier`.
  - From `VehiclePrototype`: `allow_remote_driving?`, `chunk_exploration_radius?` ("radius of the radar range of the vehicle", in chunks), `equipment_grid?`.
  - Vanilla spidertron: `chunk_exploration_radius = 3`, `energy_source = {type = "void"}`, `allow_remote_driving = true` (`DATA/base/prototypes/entity/entities.lua:9673-9746`).
- `LuaEntity` members, all with subclass `SpiderVehicle` unless noted:
  - `autopilot_destination` (RW; writing `nil` clears all), `autopilot_destinations` (R), `add_autopilot_destination(position)`.
  - `follow_target` (RW), `follow_offset` (RW; "randomized each time the follow entity is set").
  - `vehicle_automatic_targeting_parameters` (RW `{auto_target_with_gunner, auto_target_without_gunner}`).
  - `driver_is_gunner` (RW, Car + SpiderVehicle), `selected_gun_index`, `color` (spider-vehicle listed).
  - `stop_spider()`: "Notably does not clear its autopilot_destination".
  - `get_spider_legs()`.
- Driving: `LuaEntity.set_driver(driver: LuaEntity|PlayerIdentification|nil)`, `get_driver()`, `set_passenger`, `get_passenger`.
  - `LuaControl.riding_state` is documented for **cars** ("Current riding state of this car").
  - `LuaControl.walking_state` covers "the spider-vehicle the character is driving".
- Inventories: `defines.inventory.spider_ammo`, `spider_trunk`, `spider_trash`.
- Event `on_spider_command_completed {vehicle}` fires "when a spider finishes moving to its autopilot position".
- **Needs a driver to follow autopilot? UNCONFIRMED.** The autopilot docs never mention a driver. `auto_target_without_gunner` implies driverless shooting.

### C11. Script-driven `character`, pathing — **CONFIRMED**

- `LuaEntity` inherits `LuaControl`, so a character entity has:
  - `walking_state {walking, direction}` (RW). Doc example: "a one-shot action like this will only make the player walk for one tick".
  - `shooting_state {state: defines.shooting (not_shooting|shooting_enemies|shooting_selected), position}` (RW).
  - `mining_state {mining, position?}` (RW).
  - `character_running_speed_modifier` (RW; `-1` gives speed 0; on a `LuaPlayer` it requires an associated character).
  - `character_running_speed` (R).
- `LuaEntity.color` supports characters.
- `LuaSurface.request_path{bounding_box, collision_mask, start, goal, force, radius? (1), pathfind_flags?, can_open_gates?, path_resolution_modifier? (-8..8), max_gap_size? (0..31, >0 "suitable for spiders"), max_attack_distance?, entity_to_ignore?}` returns a `uint32` id. The doc says to use it "to emulate pathing behavior by script for non-unit entities, such as vehicles".
- `on_script_path_request_finished`: `id`, `path?: array[PathfinderWaypoint {position, needs_destroy_to_reach}]` (`nil` on failure), `try_again_later: boolean` ("the pathfinder ... is too busy").
- `LuaSurface.find_non_colliding_position(name, center, radius, precision, force_to_tile_center?)` returns `MapPosition?`. "A radius of `0` means an infinitely-large search area" and the game "will not stop searching until it finds a suitable position". Also `find_non_colliding_position_in_box(name, search_space, precision, force_to_tile_center?)`.

### C12. Combat and targeting on `LuaEntity` — **CONFIRMED**

- `set_command` on a unit: **NOT on `LuaEntity` any more.** Use `entity.commandable.set_command(...)` (C8).
- `shooting_target` (RW, Turret): "Can't be set to `nil` via script."
- 2.0 turret priority list: `get_priority_target(index)`, `set_priority_target(index, entity_id?)`, `priority_targets` (R), `ignore_unprioritised_targets` (RW).
- `force` (RW via `LuaControl.force`, accepts string, index or `LuaForce`).
- `health` (RW, clamped to 0..max; "Entities with a health of `0` can not be attacked"), `max_health` (R).
- `damage(damage, force, type? ("impact"), source?, cause?)` returns the damage applied after resistances.
- `die(force?, cause?)` raises `on_entity_died` and `on_post_entity_died`.
- `is_military_target` (RW only if the prototype allows it; units cannot, see C7).
- `destructible` (RW): `false` means "can't be damaged and won't be attacked automatically".
- Events: `on_entity_damaged {entity, cause?, source?, force?, damage_type, original_damage_amount, final_damage_amount, final_health}` and `on_entity_died {entity, cause?, force?, damage_type?, loot}`.

---

## D. Forces, AI opponents, fog of war

### D13. Forces and diplomacy — **CONFIRMED**

- `game.create_force(name)` → `LuaForce`. "The game currently supports a maximum of 64 forces, including the three built-in forces. This means that a maximum of 61 new forces may be created."
- `game.merge_forces(source, destination)`: "does not merge technologies or bonuses". The built-in forces cannot be the source. Removal happens at the end of the tick.
- Diplomacy (`LuaForce`):
  - `set_cease_fire(other, bool)`: "won't be targeted for attack".
  - `get_cease_fire(other)`.
  - `set_friend(other, bool)`: "unrestricted access to buildings and turrets won't fire at them".
  - `get_friend(other)`, `is_enemy(other)`, `friendly_fire` (RW).
  - Events `on_force_cease_fire_changed` and `on_force_friends_changed`.
- Chart and fog:
  - `share_chart` (RW).
  - `chart(surface, area)`, `chart_all(surface?)`, `clear_chart(surface?)`, `rechart(surface?)`.
  - `unchart_chunk(chunk_position, surface)`, `cancel_charting(surface?)`, `copy_chart(source_force, source_surface, destination_surface)`.
  - `is_chunk_charted(surface, chunk)`, `is_chunk_visible(surface, chunk)`: "charted and visible (not covered by fog of war)".
  - Event `on_chunk_charted {surface_index, position, area, force}`.
- Research: `research_queue` (RW array; silently drops impossible entries), `add_research(tech)`, `current_research`, `technologies`, `recipes`.
- Prototype access: `enable_all_recipes()`, `enable_all_prototypes()`, `disable_all_prototypes()`.
- `ai_controllable` (RW): default `true` for enemy, `false` for others. "Setting this to `false` does not turn off biters' AI." Required for scripted unit groups and bases.
- `set_spawn_position(position, surface)`, `get_spawn_position(surface)`, `players` (R), `get_entity_count(name)` ("O(1)").
- Colour: `color` (R), `custom_color` (RW).
- `kill_all_units()`, `is_pathfinder_busy()`.
- Evolution per force **and per surface** in 2.0: `get_evolution_factor(surface?)` and `set_evolution_factor(factor, surface?)` (surface defaults to "nauvis"), plus `*_by_pollution`, `*_by_time`, `*_by_killing_spawners`. CHANGELOG:3445 [2.0.7] turned the old attributes into get/set methods.
- `LuaSurface` queries:
  - `find_entities_filtered{...}` with `EntitySearchFilters`:
    - `area`, `position`, `radius`, `name`, `type`
    - `force: ForceSet`, `to_be_deconstructed`, `to_be_upgraded`, `is_military_target`
    - `ghost_name`, `ghost_type`, `direction`, `collision_mask`, `quality`, `has_item_inside`
    - `limit`, `invert`
  - `count_entities_filtered{...}`.
  - `find_nearest_enemy{position, max_distance, force?}` returns a military target.
  - `find_nearest_enemy_entity_with_owner{position, max_distance, force?}`.
  - `find_enemy_units(center, radius, force?)`.
  - `find_units{area, force, condition: ForceCondition}`, where the condition is one of `all, enemy, ally, friend, not-friend, same, not-same`. Both unit finders return only type `"unit"` and are "more efficient than find_entities".

### D14. Building by script — **CONFIRMED**

- `LuaSurface.create_entity{...}` (takes table):
  - Common fields: `name`, `position`, `direction?`, `force?` ("default is enemy"), `quality?`, `raise_built?`, `create_build_effect_smoke?` (default true), `player?` (sets `last_user` and the undo queue), `fast_replace?`, `spill?`, `character?`, `item?: LuaItemStack` ("pull stored values from this item"), `move_stuck_players?`, `preserve_ghosts_and_corpses?`, `snap_to_grid?`, `spawn_decorations?`, `source?`, `target?`, `cause?`.
  - Variant fields: `assembling-machine` `{recipe?, recipe_quality?, control_behavior?}`, `spider-vehicle` `{color?, ammo_inventory?, trunk_inventory?, automatic_targeting_parameters?, driver_is_main_gunner?, ...}`, `entity-ghost` `{inner_name, tags?}`, `highlight-box` `{bounding_box?, box_type?, render_player_index?, blink_interval?}`, `speech-bubble` `{text, lifetime?}`.
  - Returns `LuaEntity?`.
- Ghosts: `LuaEntity.revive{raise_revive?, overflow?}` and `silent_revive{...}` return collided items, the entity and the item-request proxy.
- `LuaSurface.can_place_entity{name, position, direction?, force? (default "neutral"), build_check_type? (default ghost_revive), forced?, inner_name?}` → boolean.
- `LuaSurface.set_tiles(tiles, correct_tiles?, remove_colliding_entities?, remove_colliding_decoratives?, raise_event?, player?, undo_index?)`.
- Blueprints:
  - `LuaItemStack.import_stack(data)` returns `0` (ok), `-1` (ok with errors) or `1` (failed).
  - `LuaItemCommon.build_blueprint{surface, force, position, direction?, build_mode? (normal|forced|superforced), skip_fog_of_war?, by_player?, raise_built?}` returns an "Array of created ghosts". **It is force-only capable: `force` is required, `by_player` optional.** It creates ghosts, which then need `revive` or robots.
  - Item stacks without a player: `game.create_inventory(size)` (destroy when done).
  - `get_blueprint_entities` and `set_blueprint_entities` live on `LuaItemCommon` and `LuaRecord`.
- `LuaSurface.create_entities_from_blueprint_string{...}`: "**This method only works when used in simulations.**" It is not usable in a normal game.

### D15. `unit-spawner` — **PARTIAL**

- `EnemySpawnerPrototype` (`unit-spawner`): "Can spawn entities. Used for biter/spitter nests."
  - `result_units: array[UnitSpawnDefinition {unit, spawn_points}]` (required, probabilities by evolution).
  - `spawning_cooldown: {min, max}` ("linear interpolation ... based on the current evolution factor").
  - `max_count_of_owned_units`, `max_count_of_owned_defensive_units?`.
  - `max_friends_around_to_spawn`, `max_defensive_friends_around_to_spawn?`.
  - `spawning_radius`, `spawning_spacing`, `call_for_help_radius`.
  - `spawn_decoration?`, `spawn_decorations_on_expansion?`.
  - `captured_spawner_entity?: EntityID` (**no description**), `time_to_capture?`.
  - `absorptions_per_second?`, `min_darkness_to_spawn?`, `max_darkness_to_spawn?`, `max_spawn_shift`, `max_richness_for_spawn_shift`.
  - `is_military_target` is literal `true`.
  - CHANGELOG:9864 [0.17.0]: "Changed EnemySpawnerPrototype::result_units to support any type of entity."
- Runtime:
  - `LuaEntity.units` (R, Spawner), `absorbed_pollution` (R, Spawner), `spawning_cooldown` (R), `spawn_shift` (R).
  - `LuaEntity.spawner` was **moved** to `LuaCommandable.spawner` (CHANGELOG:3521).
  - Event `on_entity_spawned {entity, spawner}`.
- **Captive biter spawner is not a player-force spawner.** `captive-biter-spawner` is an `assembling-machine` with `fixed_recipe = "biter-egg"`. Its `dying_trigger_effect` creates a `biter-spawner` `as_enemy = true` (`DATA/space-age/prototypes/entity/entities.lua:1450-1490`). `biter-spawner.captured_spawner_entity = "captive-biter-spawner"` (`DATA/space-age/prototypes/entity/enemies.lua:30`).
- **Can a `unit-spawner` on a player force spawn units for that force? UNCONFIRMED.** The docs say nothing. Spawning is tied to pollution absorption and evolution, so it must be tested.

### D16. Map settings and enemy controls — **CONFIRMED**

- `game.map_settings`: "the members of the dictionary that is returned can be modified mid-game".
  - `enemy_expansion`: `enabled`, `min_expansion_cooldown`, `max_expansion_cooldown`, `max_expansion_distance`, `settler_group_min_size`, `settler_group_max_size`, coefficients.
  - `enemy_evolution`: `enabled`, `time_factor`, `destroy_factor`, `pollution_factor`.
  - `unit_group`: `max_unit_group_size` (200), `max_gathering_unit_groups` (30), `min_group_gathering_time`, `max_group_gathering_time`, `min_group_radius`, `max_group_radius`, `member_disown_distance`, ….
  - `path_finder`: 30+ knobs. Notable: `max_clients_to_accept_any_new_request` (10/tick), `max_clients_to_accept_short_new_request` (100/tick), `max_steps_worked_per_tick` (1000), `max_work_done_per_tick` (8000), `use_path_cache`.
  - `steering`: `{default, moving}`, each `{radius, separation_factor, separation_force, force_unit_fuzzy_goto_behavior}`.
  - `pollution`, `asteroids`, `max_failed_behavior_count`.
- `LuaSurface.peaceful_mode` (RW) and `LuaSurface.no_enemies_mode` (RW). Both also exist in `MapGenSettings`.
- `LuaSurface.map_gen_settings` (RW): "will not retroactively update the surface".
- `MapGenSettings.autoplace_controls: dict[name → AutoplaceControl {frequency, size, richness}]`. The `enemy-base` control is defined in `DATA/base/prototypes/autoplace-controls.lua:84`. `default_enable_all_autoplace_controls?` and `starting_points?` also exist.
- `LuaForce.disable_all_prototypes()`: "Disable all recipes and technologies. Only recipes and technologies enabled explicitly will be useable from this point."
- `LuaSurface.build_enemy_base{position, unit_count, force?}`: "The specified force must be AI-controlled."

---

## E. Rendering, GUI, inputs

### E17. `rendering` (LuaRendering) — **CONFIRMED**

- Methods: `draw_line`, `draw_text`, `draw_circle`, `draw_rectangle`, `draw_arc`, `draw_polygon`, `draw_sprite`, `draw_light`, `draw_animation`, `clear(mod_name?)`, `get_all_objects`, `get_object_by_id(id)`.
- **Every `draw_*` returns `LuaRenderObject`** in 2.0. CHANGELOG:3507 [2.0.7]: "All LuaRendering methods for manipulating object selected by id were moved to LuaRenderObject." `LuaRenderObject` has `destroy()`, `bring_to_front()`, `move_to_back()`, `id` (uint64), and RW attributes for every parameter.
- Common parameters:
  - `surface` (required)
  - `players?: array[PlayerIdentification]` and `forces?: ForceSet` (nil or empty means everyone)
  - `visible?` (true), `only_in_alt_mode?` (false), `time_to_live?` (ticks; default forever)
  - `draw_on_ground?` (shapes, text), `blink_interval?`
  - `render_mode?: "game" | "chart"` (default `"game"`; added 2.0.56). **Chart mode draws on the map view.**
- Targets: `target` / `left_top` / `right_bottom` / `from` / `to` take a `ScriptRenderTarget`, which is a `LuaEntity`, a `MapPosition`, or `{entity, offset}` / `{position}`. "If an entity target ... is destroyed or changes surface, then the object is also destroyed."
- Extras:
  - `draw_text`: `scale_with_zoom`, `use_rich_text`.
  - `draw_sprite` and `draw_animation`: `tint`, `orientation_target`, `x_scale`/`y_scale`, `render_layer`.

### E18. GUI — **CONFIRMED** (clicks on camera/minimap UNCONFIRMED)

- `LuaGui` roots:
  - `screen` (empty-widget, free-positioned)
  - `top` and `left` (each a flow inside a scroll pane)
  - `center` (flow)
  - `relative` (empty-widget anchored to game GUIs via `GuiAnchor`)
  - `goal`
- `GuiElementType` values: `button`, `sprite-button`, `checkbox`, `flow`, `frame`, `label`, `line`, `progressbar`, `table`, `textfield`, `radiobutton`, `sprite`, `scroll-pane`, `drop-down`, `list-box`, `camera`, `choose-elem-button`, `text-box`, `slider`, `minimap`, `entity-preview`, `empty-widget`, `tabbed-pane`, `tab`, `switch`.
- `add{type="camera", position, surface_index?, zoom? (0.75)}` and `add{type="minimap", position?, surface_index?, zoom?, force?, chart_player_index?}`.
- Runtime fields:
  - `entity` (RW; camera, minimap and entity-preview "can visually track an entity")
  - `position`, `zoom`, `surface_index` (camera/minimap)
  - `minimap_player_index`, `force` (minimap)
  - `location` (screen elements)
- `LuaControl.opened` (RW): "the GUI that will asked to close (by firing on_gui_closed) when the Esc or E keys are pressed".
- Events:
  - `on_gui_click {element, button, alt, control, shift, cursor_display_location, player_index}`
  - `on_gui_closed {gui_type, element?, entity?, item?, equipment?, other_player?, inventory?, tile_position?, surface_index?}`
  - `on_gui_location_changed {element}`
- `LuaStyle` size fields:
  - `width`, `height`, `size` (write-only shorthands)
  - `minimal_width`, `maximal_width`, `minimal_height`, `maximal_height`, `natural_width`, `natural_height`
  - `horizontally_stretchable`, `vertically_stretchable`, `padding`, `margin`
- Whether `on_gui_click` fires on `camera` or `minimap` elements is not documented.

### E19. Player output and view state — **CONFIRMED**

- `LuaPlayer.print(message, print_settings?)`: identical messages within 60 ticks are suppressed by default.
- `LuaPlayer.create_local_flying_text{text, position? | create_at_cursor?, surface?, color?, time_to_live? (80), speed?}`: "not saved".
- `LuaPlayer.play_sound(PlaySoundSpecification)`: "not played if its location is not charted for this player".
- `LuaPlayer.render_mode` (R only): `game | chart | chart_zoomed_in`.
- `LuaPlayer.map_view_settings` (W only, `MapViewSettings` with `show-*` keys).
- `LuaPlayer.show_on_map` (RW), `LuaPlayer.minimap_enabled` (RW).
- `LuaPlayer.game_view_settings` (RW `GameViewSettings`, a LuaStruct):
  - `show_controller_gui`, `show_minimap`, `show_research_info`, `show_entity_info`, `show_alert_gui`
  - `show_crafting_queue`, `show_tool_bar`, `show_quickbar`, `show_shortcut_bar`, `show_side_menu`
  - `show_map_view_options`, `show_surface_list`, `show_entity_tooltip`, `show_hotkey_suggestions`, `show_rail_block_visualisation`
  - `update_entity_selection`
- Events:
  - `on_player_changed_surface {player_index, surface_index?}`
  - `on_player_controller_changed {player_index, old_type: defines.controllers}`. This is the 2.0 name, added in 2.0.7 (CHANGELOG:3385).

---

## F. Dev workflow and testing without GUI

### F20. `factorio --help` on this binary — **CONFIRMED**

`factorio --version`: `Version: 2.0.77 (build 84539, mac-arm64, steam)`. Every flag asked about **exists**:

| Flag | Help text (abridged) | Window? |
|---|---|---|
| `--mod-directory PATH` | Mod directory to use | n/a |
| `--create FILE` | create a new map | not stated |
| `--map-gen-settings FILE` | for `--create`, `--start-server-load-scenario`, `--generate-map-preview` | n/a |
| `--map-settings FILE` | for `--create` or `--start-server-load-scenario` | n/a |
| `--start-server FILE` | start a multiplayer server | not stated |
| `--server-settings FILE` | server settings | n/a |
| `--benchmark FILE` | load save and run benchmark | not stated; contrasted with `--benchmark-graphics` "with graphics" |
| `--benchmark-ticks N` | default 1000 | n/a |
| `--dump-data` | "dumps data.raw as JSON to the script output folder and exits" | exits |
| `--dump-prototype-locale` | "... and exits" | exits |
| `--check-unused-prototype-data` | warn for prototype values never accessed | n/a |
| `--instrument-mod arg` | enable Instrument Mode for one mod | n/a |
| `--load-game FILE` | "start Factorio and load a game in singleplayer" | yes |
| `--load-scenario [MOD/]NAME` | start Factorio and load scenario in singleplayer | yes |
| `--mp-connect ADDRESS` | start factorio and connect | yes |
| `--disable-audio` | "Mainly for faster startup during development" | n/a |
| `--window-size arg` | e.g. `"1680x1050"` or `"maximized"` | n/a |
| `--fullscreen` | help text literally says "start game in windowed mode (saved to configuration)" | n/a |
| `--force-opengl`, `--force-metal` | renderer choice | n/a |

Only `--run-replay FILE` is explicitly "in headless mode". `--dump-data`, `--dump-icon-sprites` and `--dump-prototype-locale` say "and exits". Other flags useful for automated testing:
- `--until-tick TICK` ("run a save until given map tick").
- `--start-server-load-scenario [MOD/]NAME`, `--map-gen-seed SEED`.
- `--generate-map-preview PATH`.
- `--benchmark-runs`, `--benchmark-verbose`, `--benchmark-sanitize`.
- `--enable-lua-udp PORT` (enables `helpers.send_udp/recv_udp`).
- `--enable-unsafe-lua-debug-api`, `--sync-mods FILE`, `--console-log FILE`, `--rcon-port`, `--rcon-password`, `--nogamepad`.

### F21. Lua debugging, lifecycle, `info.json`, scenarios — **CONFIRMED** (one item NOT AVAILABLE)

- Global functions: `log(LocalisedString)` (to the log file), `localised_print` (to stdout, "useful when communicating with external tools that launch Factorio as a child process"), `table_size`.
- **`game.write_file` moved to `helpers.write_file(filename, data, append?, for_player?)`.** CHANGELOG:3379 [2.0.7] also moved `table_to_json`, `json_to_table`, `remove_path`, `encode_string`, `decode_string`, `evaluate_expression`, `parse_map_exchange_string`, `is_valid_sprite_path`, and others to `LuaHelpers`. `helpers.table_to_json(table)` and `helpers.json_to_table(string)` exist. `helpers` is available in the settings and prototype stages too (2.0.55, CHANGELOG:625).
- `game.take_screenshot{...}`:
  - Parameters: `player?`, `by_player?`, `surface?`, `position?`, `resolution?` (max 16384²), `zoom?` (1), `path?` (png/jpg/tga/bmp under `script-output`), `quality?`, `show_gui?`, `show_entity_info?`, `show_cursor_building_preview?`, `anti_alias?`, `force_render?`, `daytime?`, `water_tick?`, `allow_in_replay?`, `hide_clouds?`, `hide_fog?`.
  - **"If Factorio is running headless, this function will do nothing."**
- `script`: `on_event(event | array, handler, filters?)` (one handler per event per mod), `on_nth_tick(tick | array, handler)`, `on_init`, `on_load`, `on_configuration_changed`, `register_on_object_destroyed`, `raise_event`, `generate_event_name`, `active_mods` (moved from `game` in 2.0.7), `level`, `feature_flags`.
- `remote.add_interface(name, functions)`, `remote.call(interface, function, ...)`, `commands.add_command(name, help, function)`.
- `storage`: CHANGELOG:3364 [2.0.7] "Renamed `global` into `storage`". It is not restored during `control.lua`, and writing to it in `on_load` errors (DOC/auxiliary/storage.html).
- Game timing:
  - `game.tick` (R).
  - `game.speed` (RW; "1.0 is normal speed -- 60 UPS. Minimum value is 0.01").
  - `game.tick_paused`, `game.ticks_to_run`.
- **`game.autosave_interval`: NOT AVAILABLE.** Use `game.autosave_enabled` (RW) and `game.auto_save(name?)`.
- `info.json` (DOC/auxiliary/mod-structure.html):
  - Mandatory fields: `name`, `version` (`"x.y.z"`, each 0..65535), `title`, `author`.
  - `factorio_version: "2.0"` (effectively mandatory; a third number makes the portal reject the mod).
  - `dependencies` (default `["base"]`). Prefixes: `!` incompatible, `?` optional (e.g. `"? space-age"`), `(?)` hidden optional, `~` no load-order effect. Operators `< <= = >= >` with a version.
  - Space Age feature flags: `quality_required`, `rail_bridges_required`, `spoiling_required`, `freezing_required`, `segmented_units_required`, `expansion_shaders_required`, `space_travel_required`.
- Load stages (DOC/auxiliary/data-lifecycle.html):
  - Settings stage: `settings.lua`, `settings-updates.lua`, `settings-final-fixes.lua`.
  - Data stage: `data.lua`, `data-updates.lua`, `data-final-fixes.lua`.
  - Control stage: `control.lua`, then `on_init` (new) or migrations and `on_load` (existing), then `on_configuration_changed`.
- Scenarios vs mods: a mod may ship `scenarios/`, `campaigns/`, `tutorials/` and `migrations/` subfolders, plus `locale/` (DOC/auxiliary/mod-structure.html). "Scenario scripts are treated like mods" for `on_init` (data-lifecycle). The CLI takes `--load-scenario [MOD/]NAME` and `--start-server-load-scenario [MOD/]NAME`. Vanilla scenarios live in `DATA/base/scenarios/`: `freeplay`, `pvp`, `rocket-rush`, `sandbox`, `supply`, `team-production`, `wave-defense`.
- `freeplay` remote interface (`DATA/base/script/freeplay/freeplay.lua:144-203`):
  - Getters and setters: `get/set_created_items`, `get/set_respawn_items`, `get/set_skip_intro`, `get/set_custom_intro_message`, `get/set_disable_crashsite`, `get/set_ship_items`, `get/set_debris_items`, `get/set_ship_parts`.
  - Setter only: `set_chart_distance`. Getter only: `get_init_ran`.
  - Typical use: `remote.call("freeplay", "set_disable_crashsite", true)` and `remote.call("freeplay", "set_skip_intro", true)`.
  - The `sandbox` interface has `set_chart_distance`, `get/set_created_items`.

---

## Implications for an RTS mod

**Hard blockers.** None found that make the concept impossible. The closest:
1. **No continuous mouse world position.** Hover feedback and drag rectangles must come from the native selection-tool box (`select`/`reverse_select`) and from point events (`CustomInputEvent.cursor_position`). A custom "move/attack" right-click is feasible: a `mouse-button-2` custom input with `consuming = "game-only"`, or the selection tool's `reverse_select`.
2. **No runtime colour for `unit`.** Team colours need `apply_runtime_tint` layers (force-tinted is confirmed only for `spider-unit`) or per-team unit prototypes.

**Soft limitations.**
3. Scripted unit groups need `force.ai_controllable = true`, which also enables automatic expansion and grouping for that force. Single units can be commanded without groups via `entity.commandable`.
4. Pathfinder throughput is capped per tick (`path_finder.max_clients_to_accept_*`). `MapSettings.max_failed_behavior_count` destroys units whose behaviours keep failing, which could hit player units.
5. `vision_distance` ≤ 100, and ≥ 50 triggers "undocumented" self-grouping. Units are always military targets.
6. 64 forces in total (61 custom), which is ample for several AI opponents.
7. Unknowns to test first:
   - Remote controller persistence with no character.
   - Custom inputs firing in remote view.
   - Player-force `unit-spawner` behaviour.
   - Spider-vehicle autopilot without a driver.
   - `on_gui_click` on minimap/camera elements.

**Most promising mechanisms.**
8. **Camera:**
   - `set_controller{type = remote, position, surface}` or a characterless `god` controller.
   - `set_zoom_limits(controller, {furthest_game_view = ...})` to keep game view when zoomed far out.
   - `centered_on` for follow-cam.
   - `GameViewSettings` to strip the vanilla HUD.
9. **Selection:** a `selection-tool` with `mode = {"any-entity", "same-force"}` plus `entity_type_filters = {"unit", "spider-unit", "spider-vehicle", "character"}`. `on_player_selected_area` returns the entity list. Selection tools work in map/remote view per the changelog.
10. **Orders:** `LuaCommandable.set_command` covers `go_to_location`, `attack`, `attack_area`, `stop`, `wander` and `compound`. `on_ai_command_completed` gives order feedback. `set_multi_command` handles AI waves.
11. **Unit types:** `unit` and `spider-unit` are both commandable, `spider-unit` is not Space Age gated, and `radar_range` (chunks) gives units their own fog-of-war reveal.
12. **AI bases:**
    - `build_blueprint{force=...}` (force-only, creates ghosts) then `revive`.
    - `create_entity{force, recipe, raise_built}`.
    - `clone_area` / `clone_entities{destination_force}` for templated bases.
    - Production chains run normally per force.
13. **Fog of war per force:** `chart`, `is_chunk_visible`, `share_chart`, `copy_chart`, `on_chunk_charted`.
14. **Overlays:** `rendering.draw_*` with `players`/`forces` filters, entity-attached targets, and `render_mode = "chart"` for map markers. `highlight-box` entities with `render_player_index` for per-player selection boxes.
15. **Headless testing:** `--create`, `--map-gen-settings`, `--until-tick`, `--benchmark` and `--start-server-load-scenario`, combined with `helpers.write_file`, `localised_print` and `--enable-lua-udp`. `take_screenshot` is a no-op when headless.

## Surprising or unrequested findings relevant to RTS control

- **The spidertron remote is already a vanilla RTS unit selector.** CHANGELOG:2914 [2.0.7]: "it can be used to group select and command spidertrons like in your typical RTS game". `LuaPlayer.spidertron_remote_selection` is **writable**. There is an input action `send_spidertron` and an event `on_player_used_spidertron_remote {position}`. Its selection flags `controllable`, `controllable-add` and `controllable-remove` are listed for every selection tool but are undocumented, and `SpidertronRemotePrototype` says it "can only be used for entities of type SpiderVehiclePrototype".
- **Controller behaviour is moddable through prototypes.** `GodControllerPrototype` (`movement_speed`, `inventory_size`, `crafting_categories`, `mining_categories`, `mining_speed`), `RemoteControllerPrototype.movement_speed`, `SpectatorControllerPrototype.movement_speed` and `EditorControllerPrototype` (many flags such as `instant_blueprint_building`, `show_entity_health_bars`, `render_as_day`). Vanilla values are in `DATA/core/prototypes/*-controller.lua`.
- **`CustomInputPrototype.linked_game_control`** can piggyback on vanilla controls such as `zoom-in`, `toggle-map`, `drag-map`, `move-*`, `build` and `reverse-select`.
- **Permission groups.** `LuaPermissionGroup.set_allows_action` over 279 `defines.input_action` values, e.g. `start_walking`, `craft`, `open_character_gui`, `select_area`, `remote_view_surface`, `toggle_map_editor`, `send_spidertron`. This can lock players into an RTS-only interaction set.
- **Turret priority lists** are new in 2.0: `set_priority_target`, `priority_targets`, `ignore_unprioritised_targets`, and create-entity `priority-list`. They are useful for "focus fire" style defences.
- **`LuaSurface.set_multi_command`** picks N units of a force near a destination automatically, which makes cheap AI attack waves.
- **`LuaCommandable.set_autonomous()`** hands a scripted group back to engine AI ("automatically attack polluted areas"). `is_script_driven` tells the two apart.
- **`MapSettings.steering`** (separation radius and force) and **`UnitAISettings.do_separation`, `size_in_group`, `path_resolution_modifier`** allow formation and spacing tuning. `LuaEntity.ai_settings` exposes these per entity at runtime.
- **`helpers.send_udp` / `recv_udp`** with `--enable-lua-udp` (2.0.59) and `on_udp_packet_received` give an external AI or test-harness bridge without file polling.
- **`EnemySpawnerPrototype.result_units` accepts any entity type** (0.17.0), and Gleba spawners already spawn `spider-unit` pentapods. A custom spawner could produce custom RTS units, but this is untested for player forces.
- **`LuaGameScript.create_surface`** (up to 2³²-1 surfaces) and **`set_game_state{game_finished, player_won, can_continue}`** support separate match arenas and victory screens.
- **`SegmentedUnitPrototype`** (demolisher-like units) is Space Age gated (`visibility: space_age`, `segmented_units_required` flag). `spider-unit` is not gated.
