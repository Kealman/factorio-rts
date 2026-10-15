# Phase 4 abilities and the Commander (wave B3): implementation notes

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE4.md` section 1 ("Micro and abilities", "Heroes"), section 3 (Commander row) and section 7 (ability
buttons). Builds on `docs/qa/phase4-content-notes.md` (the `rts-commander` prototype) and
`docs/qa/phase4-research-notes.md` (the `rts-scanner` and `rts-overcharge` technologies, the damage filter).

## Files

| File | Status | What it does |
|---|---|---|
| `scripts/commander.lua` | new | Spawn, respawn, the unit registry entry, orders (right-click hook, X and H), kill credit, levels, grid |
| `scripts/abilities.lua` | new | The five abilities, cooldowns, targeting through the next right click, the shield damage handler |
| `scripts/abilitygui.lua` | new | The ability bar at the bottom centre with the Commander card |
| `prototypes/abilities.lua` | new | `rts-commander-core`, `rts-commander-shield` (equipment and hidden items), `rts-stim-sticker`, the bar's GUI styles |
| `locale/en/abilities.cfg`, `locale/ru/abilities.cfg` | new | 50 keys each, same parameters. Separate files, like `content.cfg` and `research.cfg`. |
| `prototypes/inputs.lua` | +4 inputs | `rts-ability-1..4` on Z, C, V, G, `consuming = "game-only"` |
| `data.lua` | +1 line | `require("prototypes.abilities")` after `prototypes.logistics` |
| `control.lua` | +3 lines | `scripts.commander`, `scripts.abilities`, `scripts.abilitygui` after `scripts.hubgui` |
| `scripts/orders.lua` | 1 hook change | `orders.on_right_click(fn, first)`: `first = true` puts a hook ahead of the others |

No other file was touched.

## The Commander (`scripts/commander.lua`)

**Spawn.** A 60-tick sweep gives each human force of a running match one `rts-commander`. It appears at the
default exit of the force's main CC (`buildings.default_exit`, 6 tiles towards the arena centre).

- **Human force.** A match participant that is not in `match.ai_forces()`, has no AI commander in `storage.ai`, and
  has players (`LuaForce.players`). `commander.enable(force)` adds a force without players; the headless probe uses it.
  The headless autotests therefore get no Commander: in the AI autotest rts-player is AI-driven, and the legacy autotest
  has no players.
- **Respawn.** 60 s after a death, at whatever CC the force has then. A force without a CC waits and logs it once.
- **Alerts.** A death appends `{tick, force, kind = "commander-down", position, text = "rts.alert-commander-down",
  params = {60}}` to `storage.alerts` through `supply.alert`, and prints the same line to the force. A respawn adds
  kind `commander-ready`.
- **New match.** `match.teardown` destroys the Commander with the other units. The per-force records (kills, level)
  reset when `storage.match.match_id` changes.

**Unit registry.** The Commander sits in `storage.units` with kind `commander`, order `commander` and issuer
`commander`. The non-idle order is a claim (`units.lua`), so orders.lua and the AI army never command it.

- **Supply.** 0, from `balance.units["rts-commander"].supply`.
- **Selection.** `selection.lua` selects it like any unit: box select, click, control groups and Ctrl+A. The RTS cursor
  selects spider-vehicles since `prototypes/logistics.lua` added them for haulers.
- **Colour.** `entity.color` is the force's `custom_color`.

**Orders.** A right-click hook (`orders.on_right_click`, registered after the haulers' hook) drives it with
`autopilot_destination`:

| Input | Commander |
|---|---|
| Right click on the ground | Moves there |
| Right click on an enemy | Walks to 22 tiles from it (`ATTACK_STANDOFF`); its rockets reach 30 and fire on their own |
| Shift + right click, or a right click with attack-move armed | Moves there and fires on the way |
| X or H | Clears the autopilot (`commander.stop`) |

Other selected units still get their normal order from orders.lua. The hook consumes the click only when nothing else
that orders.lua commands is selected. With attack-move armed it also disarms it.

**Combat.** Auto-targeting without a gunner (`vehicle_automatic_targeting_parameters`). The sweep tops its rockets up
to 100 when it holds fewer than 50, so the hero's ammo is free.

**Levels.** Kills raise the level: level 2 at 5 kills, level 3 at 15.

- **What counts as a kill.** `on_entity_died` with `cause` = the force's current Commander. The victim must be an enemy
  RTS unit or building (`balance.units`, `balance.buildings`, the building registry); walls and spider legs do not count.
- **Reward.** `LuaEntity.max_health` is read-only. Each level therefore heals the Commander fully and adds an
  `rts-commander-shield` to its grid. Each shield holds 400 points, 20 % of its 2000 health.
- **Persistence.** Kills and level survive deaths within a match. A respawned Commander gets the equipment of its level.

**Grid** (4×4 `rts-commander-grid`, `armor` category):

| Cell | Level 1 | Level 2 | Level 3 |
|---|---|---|---|
| (0,0) 2×2 | `personal-roboport-equipment` | | |
| (2,2) 2×2 | `rts-commander-core`: 300 kW, free | | |
| (2,0) 2×2 | | `rts-commander-shield` | |
| (0,2) 2×2 | | | `rts-commander-shield` |

The shield costs 50 kJ per point and takes at most 250 kW, so the core's 300 kW regenerates about 6 points per second
across both shields. The trunk starts with 4 construction robots. Field construction builds ghosts within 15 tiles from
items in the Commander's trunk, which starts empty.

**Card.** The ability bar shows the level, a health bar and "Kills: 5 / 15". While the Commander is dead it shows
"Down: back in N s" instead. `commander.card(force)` is the HUD's source for its unit card (see API).

## Abilities (`scripts/abilities.lua`)

| Ability | Key | Needs | Effect | Cooldown |
|---|---|---|---|---|
| Stim | Z | Own units selected | Damaged units heal 30 % of max health for 10 iron each from the CC networks, most damaged first, as many as the iron pays for. Drones and the Commander also get `rts-stim-sticker`: speed ×1.5 for 8 s. | 30 s |
| Shield | C | A live Commander | The Commander and own units within 8 tiles get 10 s of 50 % damage reduction | 45 s |
| Scanner sweep | V | `rts-scanner` | Targeted: charts 48×48 tiles for 30 s | 60 s |
| Artillery strike | G | An own artillery walker | Targeted: each artillery walker 8–40 tiles from the point fires 2 shells there, then attacks the enemy there | 20 s |
| Overcharge | button | `rts-overcharge` and a CC | Turrets ×2 damage for 10 s; the CC buffer loses 1 MW meanwhile | 90 s |

**Stim (choice).** The 2.0.77 docs say `LuaEntity.speed` "Only the speed of units, cars, and projectiles are writable".
The probe confirmed it: writing it on a walker raises "Entity is not car or unit or projectile or artillery-projectile".
Stickers attach only to unit, character, car and spider-vehicle prototypes. Walkers, heavies, raiders and artillery
are spider-units, so they cannot be sped up without swapping the entity.

- Stim is therefore the brief's fallback: an instant 30 % heal for 10 iron per damaged unit.
- Drones (`unit`) and the Commander (`spider-vehicle`) also get the speed sticker. This keeps PHASE4's "speed burst"
  where the engine allows it.
- Units at full health cost nothing. Stim is refused when nothing would happen: all units are at full health and none
  can take the sticker, or the force has no iron.

**Shield.** An `on_entity_damaged` handler heals back 50 % of `final_damage_amount` for marked units. Like Armor II/III,
a killing blow (`final_health == 0`) is not reduced. The handler returns at once when no shield is active. It stacks
with Armor II/III: research heals its share first, then the shield heals 50 % of the same hit. A blue ring shows on
each shielded unit for 10 s.

**The damage filter.** `script.set_event_filter` holds one filter per event per mod; see
`docs/qa/phase4-research-notes.md`. `abilities.lua` loads after `research.lua`, reads the current filter with
`script.get_event_filter` and adds `rts-commander`. The Commander is a spider-vehicle and was not in the filter. Every
building and armored unit name stays.

**Scanner sweep.** `force.chart` on the 48×48 area at the cast, then again every 240 ticks while
`tick + 600 <= end`. A chart stays visible about 600 ticks (`fog.lua`), so the area is visible for 30 s. That makes 6
charts. Afterwards the area falls back to its last chart, like any other fogged area. A cyan rectangle marks it for the
caster's force.

**Artillery strike.** The volley is script-made `rts-artillery-shell` projectiles, with each artillery walker as
`source` and `cause`. The impacts spread within 2 tiles of the point. The walkers orders.lua may command then get
`orders.attack` on the enemy nearest the point (attack_area radius 4 there, renewed while the target lives). With no
artillery walker in range the click is used up, a message says why and no cooldown starts.

**Overcharge.** For each `rts-*` turret prototype (`research.turret_names()`: `rts-turret`, `rts-laser-turret`), the
turret attack modifier `m` gets the delta `1 + m`, so `(1 + m + delta) = 2 (1 + m)`. The same delta is subtracted after
10 s. Research applies deltas too, so the two coexist.

The drain takes 1 MJ per second from the main CC's `energy`, 10 MJ in all. The CC buffer is 200 MJ and recharges at up
to 2 MW from the core, so in practice the drain is 1 MW of the network's power for 10 s. The probe saw the buffer back
at 200 MJ and 10 MJ drained. A yellow ring marks every turret of the force.

**Use and targeting.** The hotkey or button calls `abilities.activate(player, name)`.

- An instant ability casts at once.
- A targeted ability is armed. The next right click casts it at the click position. Its hook is registered with
  `first = true`, so it runs before the hauler and Commander hooks and before the normal orders; the units do not move.
- Pressing the same key again or X cancels it. F (arming attack-move) replaces it, and arming a targeted ability
  disarms attack-move.

**Cooldowns.** Cooldowns belong to the force, so players of one force share them. A new match clears them.

**Log lines.**

```
[rts] ability <name> player=<i> force=<f> <details>
[rts] ability <name> refused player=<i> force=<f>: <reason>
[rts] ability <name> armed player=<i>: next right click
[rts] ability overcharge ended force=<f> modifiers ..., drained 10.0 MJ
[rts] ability scanner ended force=<f> at (x, y) after 6 charts
```

## Ability bar (`scripts/abilitygui.lua`)

A `screen` frame named `rts_ability_bar` sits at the bottom centre. It exists only while a match runs and the player's
force takes part.

**Placement.** The bar is centred between the HUD's selection panel and its build menu, bottom aligned. The HUD
reserves 8 + 520 + 8 GUI units on the left and 8 + 308 + 8 on the right (`HUD_LEFT` and `HUD_RIGHT`, mirroring
`hud.lua`'s MARGIN, PANEL_WIDTH and BUILD_WIDTH). The full bar is 478 × 86 GUI units. When it does not fit between the
two, the compact layout (320 units) drops the card's text column. The Commander icon then shows the level as its number
and carries the rest in its tooltip. A resolution or UI-scale change rebuilds the bar in the right layout.

| Window, UI scale | Layout | Position |
|---|---|---|
| 1280×800, 0.75 (the automatic scale of `tools/gui-run.sh`) | full, 359 × 65 px | x 461–820, y 729–794 |
| 1280×800, 1.0 (the owner's config) | compact, 320 × 86 px | x 536–856, y 706–792. HUD panel ends at 528, build menu starts at 964. |
| 1920×1080, 1.0 | full, 478 × 86 px | centred |

**Guards.** Every refresh first checks the player, `player.gui.screen` and each element. The bar's elements are
collected into one table, and anything missing or invalid, or a layout change, makes it rebuild instead of raising. No
`pcall` is used. Style writes go only to flows: a frame style has no `horizontal_spacing` (gotcha 2).

- **Card.** The Commander icon, "Commander · Lv N", a health bar, and "Kills: k / next". It shows "Down: back in N s"
  while the Commander is dead, and "Target: <ability>" in yellow while a targeted ability is armed. The icon's tooltip
  has health, shield and kills. A click selects the Commander, and a second click jumps the camera to it.
- **Buttons.** Five 44-unit slot buttons with vanilla item icons: exoskeleton, energy shield, radar, artillery
  targeting remote and discharge defense. Under each is a thin recharge bar and the hotkey, or "54 s" while it recharges.
  - An unavailable button is disabled (greyed): no research, nothing selected for Stim, no Commander for Shield, no
    artillery walker, or on cooldown.
  - The armed ability's button is green.
  - The tooltip gives the name, hotkey, description, cooldown, required technology and the current reason.
  - A click is the hotkey.
- **Refresh.** Every 15 ticks, and at once when an ability is armed, cast or refused.

## API for other agents

| Function | Returns / does |
|---|---|
| `commander.card(force)` | `{alive, level, kills, next_kills?, health, max_health, shield, max_shield, respawn_in?, waiting?, unit_number?, deaths}`, or nil for a force without a Commander record |
| `commander.entity(force)` | The live Commander entity, or nil |
| `commander.is_human(force)`, `commander.enable(force, on)` | The spawn rule, and the override for headless tests |
| `commander.select(player)`, `commander.stop(player)` | The card click, and X / H for the Commander |
| `commander.spawn_now(force)` | Spawn now, ignoring the respawn timer (tests) |
| `abilities.activate(player, name)` | The hotkey and button path |
| `abilities.cast(player, name, position?)` | Cast directly; targeted abilities need the position |
| `abilities.available(player, name)` | `true`, or `false` and a localised reason |
| `abilities.cooldown_left(force, name)`, `abilities.armed(player)`, `abilities.disarm(player, why)` | As named |
| `abilities.stats()` | `{[name] = {used, refused}}`, and the total damage the shield healed back |
| `abilities.on_changed(fn)` | `fn(player)` after arm, disarm or cast (load time only) |
| `abilities.LIST`, `abilities.DEF` | Order and numbers |

**HUD (B2).** The HUD agent was told the following on 2026-10-16:

- The units page needs `rts.kind-commander`. The working-tree HUD of 00:15 already shows "Командир ×1".
- The unit card can show the level from `commander.card`.
- The alert kinds are `commander-down` and `commander-ready`.
- The bar's screen area must stay clear.
- The HUD's own Stop and Hold buttons call `orders.stop` and `orders.hold`, which skip the Commander. If they should
  also stop the Commander, call `commander.stop(player_index)` there. Only X and H do it today.

## Validation

Every copy is `mods/factorio-rts` plus a `mod-list.json`, with one exception. **`scripts/hud.lua` is the committed
version (`git show HEAD:...`)**, because the HUD agent's working-tree `hud.lua` failed to load at that time ("too many
local variables (limit is 200) in main function", hud.lua:2205). Probe copies add `scripts/abilities_probe.lua` and one
`require` line at the end of `control.lua`. The probe is active only when `storage.debug` exists and
`storage.debug.abilities_probe ~= false`. Its source lives in the build copies only:
`build/p4-abilities/factorio-rts/scripts/abilities_probe.lua`.

| Run | Copy | Result | Errors |
|---|---|---|---|
| `--check-unused-prototype-data --create`, Space Age | `build/p4-abilities-check.log` | 0 warnings | 0 |
| The same, base only | `build/p4-abilities-nosa-check.log` | 0 warnings | 0 |
| Headless probe, 240 s, `tools/headless-run.sh 240 ... build/p4-abilities` | `build/p4-abilities` | `abilities probe summary 34/34 (all passed)` at 91.8 s | 0 |
| Headless probe, base only, 240 s | `build/p4-abilities-nosa` | 34/34 at 90.9 s, the same numbers within noise | 0 |
| AI autotest, 420 s, no probe | `build/p4-abilities-ai` | `ai autotest summary 14/14 (all passed), result=both alive (time)`; no Commander spawned (AI-driven rts-player) | 0 |
| Legacy Phase 1/2 autotest, 240 s, `AUTOTEST_MATCH` = legacy / waves | `build/p4-abilities-legacy` | `autotest summary 65/65 (all passed)`; no Commander spawned (no players) | 0 |
| GUI, Russian (system language), `tools/gui-run.sh build/p4-abilities-gui 220 ABILITIES_GUI_DONE` | `build/p4-abilities-gui` | `abilities probe summary 6/6 (all passed)` | 0, no "Unknown key" |
| GUI, English (scratch copy of `gui-run.sh` that appends `[general] locale=en`) | `build/p4-abilities-gui-en` | 6/6 | 0 |
| GUI, Russian, with the HUD agent's working-tree `hud.lua` of 00:15 (it loaded again) | `build/p4-abilities-gui-hud` | 6/6. The bar (461–820, 729–794) and the new HUD panel (6–396, 699–794) and build menu (from x 1043) do not overlap. | 0 |
| GUI smoke after the lead's report (the frame-spacing crash, fixed at 00:02 in `mods/`), plain copy of `mods/` with the live HUD, UI scale 0.75 | `build/p4-abilities-smoke` | 7/7: the six checks above plus `gui_bar_rebuilds`. A button column destroyed by script was rebuilt by the next refresh, with no error. | 0 |
| The same at UI scale 1.0 (scratch `gui-run.sh` that appends `[interface] automatic-ui-scale=false, custom-ui-scale=1.0`) | `build/p4-abilities-smoke-s1` | 6/6. Compact layout at (536, 706), clear of the HUD (`build/shots-p4-abilities-smoke-s1/rts-p1-1080.png`). | 0 |

**Headless probe checks**, in order. The probe starts its own 1v1 against an easy AI, suppresses the default autotest
and drives rts-player through the fake player index 0.

1. `commander_spawned`, `commander_color`, `commander_setup`, `commander_supply_0`, `commander_selectable`:
   - It spawned at (-82, 0), the exit of the CC at (-88, 0).
   - Its colour is the force's (0.15, 0.45, 1.00).
   - The grid holds the roboport and the core; it carries 100 rockets and 4 robots; it auto-targets without a gunner;
     health 2000/2000.
   - Supply cost 0; selection size 1.
2. `commander_right_click_move`, `commander_stop`, `commander_mixed_selection`:
   - A right click through `orders.handle_reverse_area` returned `commander-move` and set the autopilot to the point.
     X cleared it.
   - With 2 walkers in the selection, the walkers got `move` from orders.lua and the Commander its autopilot. Its
     record kept order `commander`.
3. `commander_kill_credit`: an enemy walker 18 tiles away died to the Commander's own rockets in 3.0 s; kills 1.
4. `commander_level_2`, `commander_level_3`: script kills with the Commander as `cause`.
   - Level 2 at 5 kills: 1 shield, max shield 400, health full.
   - Level 3 at 15: 2 shields, max shield 800. An enemy wall killed in between was not counted.
5. `commander_death`: 10⁶ explosion damage.
   - The entity was gone, `respawn_tick` = death + 3600.
   - A `commander-down` alert with `params = {60}` and a position.
6. `commander_respawn_not_early`: no Commander 30 s after the death.
   `commander_respawned`: 62 s after the death a new unit number, spawn 2, level 3, 2 shields, a `commander-ready`
   alert.
7. `stim_heal`, `stim_sticker`, `stim_cooldown`:
   - 4 walkers damaged to 100/200 went to 160; iron 200 → 160.
   - The selected drone got the sticker, an unselected one did not.
   - Cooldown 1800 ticks; a second use was refused.
8. `stim_speed_drone`: the stimmed drone ran 71.0 tiles in 3 s, an unstimmed one 39.5 (×1.80, measured from a
   standing start).
9. `scanner_locked`, `scanner_cast`, `scanner_expired`:
   - Refused before research.
   - After research the key armed it. The next right click returned `ability-scanner` and started the 3600-tick
     cooldown.
   - The scan ended after 30 s with 6 charts. Headless charts nothing; see the GUI run.
10. `artillery_needs_walker`, `artillery_out_of_range`, `artillery_cast`, `artillery_kills_cluster`:
    - Refused with no artillery walker.
    - A click 100 tiles away was used up with no cooldown.
    - 3 artillery walkers fired 6 shells at 6 enemy walkers packed within 1.5 tiles, 30 tiles away. All 3 got the
      follow-up attack. **6 of 6 walkers were dead 2.5 s later.**
11. `overcharge_locked`, `overcharge_applied`, `overcharge_damage_x2`, `overcharge_reverted`:
    - Refused before research.
    - `rts-turret` and `rts-laser-turret` modifiers went from 0.00 to 1.00.
    - An `rts-turret` firing at an enemy heavy hit for 25.00 before and 50.00 during. After the heavy's resistances
      that was 12.50 and 25.00: ×2.00.
    - Both modifiers were back at 0.00 after 10 s; 10.0 MJ drained, CC buffer back at 200 MJ.
12. `shield_cast`, `shield_halves_damage`, `shield_expires`:
    - The respawned Commander and 6 units within 8 tiles were marked; a walker 30 tiles away was not.
    - 100 physical damage cost the shielded walker 50.00 and the unshielded one 100.00.
    - After 10 s both lost the same.
13. `stim_commander_sticker`, `stim_speed_commander`: the Commander alone at full health got the sticker for no iron.
    It moved at 21.3 tiles/s against a 16.2 tiles/s baseline (×1.31–1.32 in three runs). The spider-vehicle reaches less than ×1.5.

**GUI probe checks** (both languages):

- `gui_commander`: the Commander exists and the bar is shown.
- `gui_scanner_armed`: the key armed the scanner.
- `gui_scanner_cast`: a right click cast it at the enemy base.
- `gui_scanner_charts`: 4 s later all 4 chunks of the area were charted and visible.
- `gui_overcharge`: Overcharge cast.
- `gui_scanner_fades`: 38 s after the cast the 4 chunks were still charted, with 0 visible.

**Screenshots** (1280×800, UI scale 0.75):

| File | What it shows |
|---|---|
| `build/shots-p4-abilities-gui/rts-p1-690.png` (Russian) | The Commander selected (blue spidertron, selection box) next to 2 artillery walkers and a damaged walker. The bar: "Командир · ур. 2", health bar, "ПКМ: Сканирование" in yellow, the scanner button green. |
| `build/shots-p4-abilities-gui/rts-p1-1080.png` (Russian) | 7 s later: "Убийств: 5 / 15", Scanner "54 с" and Overcharge "89 с" greyed with their recharge bars, the others ready |
| `build/shots-p4-abilities-gui-en/rts-p1-690.png`, `rts-p1-1080.png` (English) | The same: "Commander · Lv 2", "Target: Scanner sweep", "Kills: 5 / 15", "54 s", "89 s" |
| `build/shots-p4-abilities-gui-hud/rts-p1-1080.png` (Russian, new HUD) | The bar next to the new HUD: units page "Командир ×1", kill feed with the 5 kills, research alerts |

The first English run clipped "Right-click: Scanner sweep" in the 116-unit card column. The column is now 150 units
and the English hint reads "Target: …".

## Gotchas

1. **`LuaEntity.speed` is writable only for units, cars and projectiles**, and stickers attach only to units,
   characters, cars and spider-vehicles. Spider-units cannot be sped up by script. This is the reason for the Stim
   choice.
2. **A frame style has no `horizontal_spacing`.** Setting it on a frame raised "Expected Table or Flow or
   HorizontalFlow style type but was Frame" in the first GUI run. The error came from the 15-tick refresh, so it took
   down every GUI client. It was fixed in `mods/` at 00:02, and the HUD agent's report came from a copy taken before
   that. The spacing now comes from the frame style's `horizontal_flow_style`, and the bar's code is guarded (see
   "Guards").
3. **Only one `on_entity_damaged` filter per mod.** Read it with `script.get_event_filter` and extend it; do not
   replace it. See the research notes, gotcha 5.
4. **`LuaEntity.damage` without a cause** kills with `cause = nil`. The Commander's death log then says
   "killed by unknown".
5. **The CC refills a drained buffer at once.** The CC buffer recharges from the core at up to 2 MW. Overcharge's
   drain therefore costs network power while it lasts and does not leave the buffer empty.
6. **Headless never charts.** The scanner's chart can only be checked in a GUI run (`docs/qa/phase3-matchflow-notes.md`).

## Decisions and open items for the lead

- **A Commander alone keeps a force in the match.** `match.is_out` needs no units and no CC, barracks or factory, and
  the Commander is a unit. It cannot respawn without a CC, so once it dies the force is out. If a lone hero should not
  count, `match.is_out` has to skip kind `commander` (match.lua, not mine).
- **The hero's ammo is free.** Rockets are topped up every second.
- **The player can open the Commander's GUI.** Clicking it without the RTS cursor, for example after Q, opens its
  inventory and grid, so the player can move equipment or rockets. Nothing breaks: the sweep refills rockets, and
  `apply_level` only adds missing pieces when the level rises or the Commander respawns.
- **Stim on spider-units heals only.** A real speed burst for walkers would need a faster prototype swapped in for 8 s
  (`create_entity` and `destroy`, keeping health, orders and selection). That is too heavy for this wave.
- **The numbers live in `abilities.DEF` and `commander.*`, not `balance.lua`.** `balance.lua` is the content agent's
  file; moving them there is a one-line change per value.
- **The probe copies can be deleted after review:** `build/p4-abilities*`.
