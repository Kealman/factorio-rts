# Phase 4 research, upgrades and supply: implementation notes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Plan: `docs/PHASE4.md` sections 1 (supply cap, upgrades), 2.5 (science kits), 3 (mk2 tiers) and 4 (tech tree).
Wave A3 of the plan. Content data: `balance.lua` and `docs/qa/phase4-content-notes.md`. Logistics: `scripts/logistics.lua`.

## Files

| File | Status | What it does |
|---|---|---|
| `prototypes/research.lua` | new | The lab, the two science kits and their recipes, the `rts-science` category and subgroup, 19 technologies |
| `data-updates.lua` | new | Requires `prototypes/research.lua` and appends `rts-science` to the factory's `crafting_categories` |
| `scripts/research.lua` | new | Force init and per-match reset, effects, unlocks, the barracks kit gate, lab feeding, Armor II/III, research events |
| `scripts/techgui.lua` | new | The research panel on T |
| `scripts/supply.lua` | new | Supply cap and use, the shared alert writer |
| `locale/en/research.cfg`, `locale/ru/research.cfg` | new | 72 keys each, same parameters. A separate file, like the content agent's `content.cfg`, so parallel edits of `factorio-rts.cfg` cannot collide. |
| `prototypes/inputs.lua` | +1 input | `rts-tech`: T, `consuming = "game-only"` |
| `scripts/production.lua` | 2 small hooks | `production.kit_gate` before a kit becomes a unit; `set_recipe` refuses a recipe the force has disabled |
| `control.lua` | 3 require lines | `scripts.supply` and `scripts.research` after `scripts.ai.init`, `scripts.techgui` after `scripts.lobby` |

No other file was touched. `scripts/buildings.lua` learns the lab through `buildings.KIND_BY_NAME["rts-lab"] = "lab"`,
which `scripts/research.lua` sets at load time, as the logistics module does for the hub.

## Prototypes

| Prototype | Details |
|---|---|
| `rts-lab` | Clone of the vanilla lab, icon tinted like the other buildings. 600 HP, speed 1, 60 kW, no modules, `inputs = {"rts-science-basic", "rts-science-advanced"}`. Item stack 10, subgroup `rts-economy`. |
| Recipe `rts-lab` | Factory (`rts-buildings`), 6 s, 24 iron plate + 8 copper plate (30 + 10 before the Wave C economy pass) |
| `rts-science-basic` | `tool` item copied from the automation science pack (red icon), stack 200, durability 1 |
| `rts-science-advanced` | `tool` item copied from the logistic science pack (green icon) |
| Recipe `rts-science-basic` | Factory (`rts-science`), 5 s, 1 `iron-gear-wheel` + 1 copper plate. The gear comes from the content agent's `rts-gear` recipe (`rts-intermediates`). |
| Recipe `rts-science-advanced` | Factory (`rts-science`), 10 s, 2 `electronic-circuit` + 1 steel plate |

All recipes are enabled, hidden from hand crafting and have `auto_recycle = false`. The HUD's factory recipe grid lists
the two kit recipes by itself, because it reads the machine's crafting categories.

### Technologies

Every technology costs `count` kits of one kind, 10 s per kit per lab (vanilla: several labs work in parallel).
The Wave C economy pass (2026-10-16, `phase4-balance-notes.md`) cut the tier-1 counts by 25 %; the table shows the new
counts. They have
no engine `effects`: `scripts/research.lua` applies everything (see Effects). Icons are vanilla technology icons.

| Technology | Tier, kit | Kits | Prerequisite | Effect |
|---|---|---|---|---|
| `rts-attack-1` | 1, basic | 15 | | +15 % ammo damage for every unit ammo category, +15 % turret attack for every rts turret |
| `rts-armor-1` | 1, basic | 15 | | Tier-1 walker and heavy kits deploy mk2 units |
| `rts-mining-1` | 1, basic | 11 | | `mining_drill_productivity_bonus` +0.25 |
| `rts-logistics-1` | 1, basic | 11 | | `worker_robots_speed_modifier` +0.5, `worker_robots_storage_bonus` +1, +5 robots per hub (flag for logistics) |
| `rts-supply-1` | 1, basic | 8 | | Supply cap +10 |
| `rts-unlock-heavy` | 1, basic | 11 | | Heavy walker kits become units |
| `rts-unlock-raider` | 1, basic | 15 | | Raider kits become units |
| `rts-hauler-capacity-1` | 1, basic | 11 | | `storage.research.hauler_slots[force]` = 10 |
| `rts-attack-2` | 2, advanced | 25 | Attack I | Another +15 % (30 % in total) |
| `rts-attack-3` | 2, advanced | 40 | Attack II | Another +15 % (45 % in total) |
| `rts-armor-2` | 2, advanced | 25 | Armor I | Every unit takes 10 % less damage |
| `rts-armor-3` | 2, advanced | 40 | Armor II | Every unit takes 20 % less damage in total |
| `rts-unlock-artillery` | 2, advanced | 30 | Unlock Heavy | Artillery kits become units |
| `rts-unlock-laser` | 2, advanced | 25 | | Enables the `rts-laser-turret` recipe |
| `rts-steam-power` | 2, advanced | 20 | | Enables the `rts-steam-plant` recipe; flag `steam` |
| `rts-overcharge` | 2, advanced | 25 | Unlock Laser | Flag `overcharge` (the abilities agent implements it) |
| `rts-scanner` | 2, advanced | 20 | | Flag `scanner` (the abilities agent implements it) |
| `rts-supply-2` | 2, advanced | 20 | Supply I | Supply cap +10 |
| `rts-mining-2` | 2, advanced | 25 | Mining I | `mining_drill_productivity_bonus` +0.25 (0.5 in total) |

Each technology sets `localised_name = {"technology-name.<name>"}` explicitly. Without it the engine treats the `-1`
suffix as a level and looks up `technology-name.rts-attack`.

## Effects (`scripts/research.lua`)

`research.EFFECTS` maps each technology to its effect. `research.apply(force)` sums the effects of the researched
`rts-*` technologies and applies the **difference** to what this module applied before, recorded in
`storage.research.applied[force]`. Other writers of the same modifiers keep their share. The hard AI adds 0.25 to
`mining_drill_productivity_bonus` at its start, and a research reset does not remove it.

- **Attack.** The unit ammo categories are read from the prototypes at load: the `attack_parameters.ammo_categories`
  of every `rts-*` spider-unit and unit, plus every `ammo_category` in `balance.units`. Today these are
  `rts-walker`, `rts-heavy`, `rts-drone`, `rts-raider`, `rts-artillery` and `rts-commander`. The turrets are every
  `rts-*` prototype matching the `turret` filter: `rts-turret` and `rts-laser-turret`. New units and turrets are picked
  up without code changes.
- **Armor I.** The barracks gate replaces a tier-1 unit by its mk2 prototype: `rts-walker` becomes `rts-walker-mk2`,
  `rts-walker-heavy` becomes `rts-heavy-mk2`. The pairs come from `balance.units[mk2].base`, falling back to a
  `-mk2` name. The mk2 kit recipes start disabled (`prototypes/recipes.lua`) and stay disabled. The kit, its cost and
  the unit's kind stay the same, so counts, HUD kinds and AI logic see a walker. `research.MK2_AUTO = false` switches
  the swap off.
- **Armor II/III.** An `on_entity_damaged` handler heals back 10 % or 20 % of `final_damage_amount` for every unit of
  a force with the technology. The armored units are every `rts-*` spider-unit and unit prototype: walker, heavy,
  drone, raider, artillery and both mk2 units. Haulers and the commander are vehicles and are not included. A killing
  blow (`final_health == 0`) is not reduced. See "The damage filter" below.
- **Mining, logistics.** Force modifiers as listed. Mining is productivity: extra ore without draining the patch faster.
  The engine has no force-wide mining speed or belt speed modifier.
- **Supply.** `storage.research.supply_bonus[force]`, which `supply.cap` reads.
- **Unlocks.** `storage.research.unlocked[force][name] = true` for every unit, kit, building and recipe name that a
  researched technology unlocks (`research.LOCKS` maps a name to its technology). Two mechanisms enforce it:
  - *Recipes that start disabled* (`rts-laser-turret`, `rts-steam-plant`) are enabled per force by research and disabled
    again by a reset. `production.set_recipe` refuses a recipe the force has disabled, because `LuaEntity.set_recipe`
    accepts one (Gotcha 1).
  - *Tier-1 kits* (heavy, raider, artillery) keep enabled recipes, as the lead specified. The barracks may craft them,
    but the gate does not turn a kit of a locked unit into a unit. The kit stays in the output, the barracks record gets
    `research_block = {reason = "locked", tech, unit, kit, tick}`, and the force gets an alert and a chat line.
- **Flags.** `storage.research.flags[force]` = `{steam, overcharge, scanner}`. `hub_robots[force]` = 5 after
  Logistics I.

### The barracks kit gate

`production.kit_gate = research.gate` is called for every finished kit before it becomes a unit:

1. **Lock.** A unit or kit in `research.LOCKS` that the force has not unlocked is refused. Forces run by an AI commander
   (`storage.ai[force]`) are exempt while `research.AI_IGNORES_LOCKS` is true. The AI does not research yet, and it
   alternates walker and heavy kits on normal and hard. Without the exemption its heavy kits would sit in the barracks.
2. **mk2.** After Armor I the unit is swapped for its mk2 prototype.
3. **Supply.** `supply.can_spawn(force, unit)` must allow it. Otherwise the kit waits, the record gets
   `research_block = {reason = "supply", unit, kit, used, cap, tick}`, and `supply.blocked` raises an alert, at most
   once per 30 s per force.

A refused kit stays in the barracks output, and production's 60-tick sweep retries it. When a slot frees up, the kit
becomes a unit within a second. The record's `research_block` is cleared, and so is `storage.research.blocked[force]`,
which holds the force's last refusal. The barracks keeps crafting until its output is full. A locked recipe therefore
costs a few kits' worth of resources before it stops. The HUD should say why (`research.block_of(unit_number)`).

### Labs

The lab is a building of kind `"lab"`. Every 60 ticks each lab with a current research gets that research's kits from
the logistic network it stands in (`production.network_for`). A lab holding fewer than 2 kits of an ingredient is
topped up to 5 (`LAB_MIN`, `LAB_FEED`). `rec.lab_state` is `idle`, `researching`, `starved: <kit>` or `no network`, and it
is logged on change. A lab outside every CC and hub network gets nothing.

### Forces and the per-match reset

- **`research.init_force(force)`** disables every non-`rts-` technology (275 of them with Space Age) and enables the 19
  `rts-*` ones. It clears a queue that holds a vanilla technology and applies the effects. It runs on `on_force_created`
  (match.lua's `game.create_force`), and a 60-tick sweep catches any other `rts-*` force.
- **A new match** (`storage.match.match_id` changed) resets every `rts-*` force. The queue is emptied and every `rts-*`
  technology is un-researched, successors first, with `saved_progress` set to 0. The effects are then removed by the
  same delta apply. Forces persist across matches in one save, so this is required.
- **`research.sync()`** does both. It runs at the top of every API entry point and on the 60-tick sweep, because
  match.lua is not this module's to edit. The probe shows the reset in the same tick as `lobby.start_match`.

## Supply (`scripts/supply.lua`)

```
cap  = 40 if the force has a live CC  (balance.buildings["rts-command-center"].supply_cap)
     + 10 per live hub (buildings kind "hub"; balance.buildings["rts-hub"].supply_cap)
     + research bonus (Supply I and II: +10 each)
used = sum of supply.cost(unit name) over the force's live registered units
```

`supply.cost` reads `balance.units[name].supply`: walker 1, drone 1, heavy 3, raider 2, artillery 4, commander 0, and
mk2 the same as its tier 1. Without `balance.lua` it uses a fallback table with the same numbers. A name in neither
place costs the cost of its `-mk2` base, else 1. Haulers are registered units (kind `"hauler"`) with
`balance.units["rts-hauler"].supply = 0`, so they are free. `balance.lua` is loaded with `pcall(require, "balance")`.
The two caps fall back to 40 and 10 without it. `supply.init` logs where they came from, for example
`supply: CC cap 40 (balance), hub cap 10 (balance)`, in the map-creation log.

The cap applies to every force, the AI included. Units that already exist are never removed. A cap that drops because
a hub dies only stops new units.

## Research panel (`scripts/techgui.lua`)

T (`rts-tech`, `consuming = "game-only"`, so the vanilla technology screen does not open) toggles a `screen` frame
that is independent of the HUD:

- **Title bar.** "Research" with a close button. The bar is draggable, and Escape closes the frame (`player.opened`).
- **Status block.** The current research and its percentage with a progress bar, labs and working labs, and kits in
  the network.
- **Tier columns.** Two columns, tier 1 and tier 2. Each row has the technology icon, its name (tooltip: description
  and prerequisites), its cost as kit icon and count, its status and a button. The statuses are Done, Researching N %,
  Queued, Available, Locked and Unavailable. The button is "Research" for an available technology. For a researching
  or queued one it is "Cancel", which removes it from the queue.
- **Queue.** "Research" appends to the vanilla research queue (`add_research`), so several technologies can be queued.
  A technology whose prerequisites are not done is "Locked" and its button is disabled.
- **Refresh.** Every 30 ticks while open, captions are updated in place.

Element names start with `rts_tech_`. Clicks carry `tags.rts_tech` = `research`, `cancel` or `close`, and
`tags.tech`. `techgui.on_click` is exposed for scripted clicks.

## API for the other agents

| Function / data | For | Returns / does |
|---|---|---|
| `supply.get(force)` | HUD strip | `{used, cap}` |
| `supply.can_spawn(force, unit)`, `supply.cost(unit)`, `supply.used(force)`, `supply.cap(force)` | HUD, AI | As named. `can_spawn` also returns used and cap. |
| `supply.alert(force, kind, text_key, params, position?)` | anyone | Appends `{tick, force, kind, position, text = key, params}` to `storage.alerts`, the logistics format plus `params`. Display it as `{entry.text, table.unpack(entry.params or {})}`. Kinds written here: `supply-blocked`, `unit-locked`, `research-complete`. |
| `research.is_unlocked(force, name)` | HUD build menu, barracks grid | False only for a name in `research.LOCKS` that the force has not researched. Names: `rts-walker-heavy(-kit)`, `rts-raider(-kit)`, `rts-artillery(-kit)`, `rts-laser-turret`, `rts-steam-plant`. |
| `storage.research.unlocked[force]` | HUD | The same as a set |
| `research.lock_of(name)` | HUD tooltips | The technology that unlocks `name` |
| `research.block_of(barracks_unit_number)` | HUD barracks page | `{reason = "locked" \| "supply", tech?, unit, kit, used?, cap?, tick}` or nil |
| `research.flag(force, "steam" \| "overcharge" \| "scanner")` | abilities, HUD | Boolean |
| `research.hauler_slots(force)`, `storage.research.hauler_slots[force]` | logistics | Extra hauler slots: 0, or 10 after Hauler capacity I |
| `research.robots_per_hub_bonus(force)` | logistics | 0, or 5 after Logistics I |
| `research.armor(force)`, `research.uses_mk2(force)`, `research.mk2_of(unit)` | HUD, AI | The Armor II/III share, Armor I state, and the mk2 name |
| `research.queue(force, tech)`, `research.cancel(force, tech)` | AI (later), HUD | Queue or unqueue. `queue` returns `ok, reason`, where reason is the status when it is not available. |
| `research.status(force, tech)` | HUD, AI | `done`, `researching`, `queued`, `available`, `locked` or `disabled` |
| `research.current(force)` | HUD | `{name, progress}` or nil |
| `research.list()` | HUD, AI | `{name, order, count, kit, tier, prerequisites}` in tree order |
| `research.lab_counts(force)` | HUD | Labs, and labs working |
| `research.debug_line(force)` | debug | One line: researched technologies, current research, modifiers, supply, armor, mk2 |
| `techgui.toggle/open/close(player)`, `techgui.is_open(player)` | HUD button, tutorial | The panel |

**HUD agent.** Three things are needed:
- Add `rts-lab` to `BUILD_ITEMS`. Done: the Production tab has the lab.
- Grey out recipes whose `player.force.recipes[name].enabled` is false in the barracks and factory grids. The mk2 kits
  and the laser turret and steam plant before research are such recipes. A click on one is refused and logged, and
  nothing else happens.
- Show `research.block_of` on the barracks page.

**AI agent (B1).** To let the AI research:
- Call `research.queue`.
- Build labs and kits.
- Set `research.AI_IGNORES_LOCKS = false`.
- Keep the guard at the top of the AI's damage handler. The shared filter carries unit names, see below.

### The damage filter (Armor II/III)

`script.set_event_filter` holds one filter per event per mod. `scripts/ai/init.lua` registers its handler and sets the
`on_entity_damaged` filter to the RTS building names. That handler now starts with a guard,
`if not buildings.KIND_BY_NAME[entity.name] then return end` (`scripts/ai/init.lua:131`, added by the AI owner on
2026-10-15). Only damage to buildings feeds the AI's base-threat and defend logic.

`scripts/research.lua` loads after `ai.init` and re-sets the filter to this union:

- the building registry's names, including the lab;
- every `balance.buildings` name and `rts-hub`, so modules that load later are covered;
- the armored unit names (`research.ARMORED_NAMES`).

The switch is one constant, `research.ARMOR_ALL_UNITS`:

| Value | Armored units | When |
|---|---|---|
| `true` (current) | Every `rts-*` spider-unit and unit | The AI handler has the guard |
| `false` | The mk2 units only | Fallback for a handler that treats every damaged entity of an AI force as a base threat. Only researching forces have mk2 units, so the AI handler never sees its own units. |

Every unit hit of every force now raises the event. For a force without Armor II/III the handler returns after one
table lookup, and the AI handler returns at its guard.

The handler cost, measured in the probe as 10 000 direct calls:

| Path | Per call |
|---|---|
| Heal path | about 1.1–2.7 µs |
| Early exit: a force without Armor II/III, as every AI force today | about 0.9–1.0 µs |

Only mk2 units and buildings raise the event at all.

## Validation

Every run uses a copy of `mods/` plus `mods/mod-list.json` (Space Age, quality and elevated-rails on). Each copy was taken
from the shared `mods/` while the content and logistics agents were also working, so it includes their files as of
23:10–23:22. The probe copies add `scripts/research_probe.lua` and one `require` line at the end of `control.lua`. The
probe is active only when `storage.debug` exists and `storage.debug.research_probe ~= false`. Its source lives in the
build copies only: `build/p4-research/factorio-rts/scripts/research_probe.lua`.

| Run | Copy | Result | Errors |
|---|---|---|---|
| `--check-unused-prototype-data --create` | `build/p4-research-check.log` | 0 warnings | 0 |
| Headless probe, 300 s, `tools/headless-run.sh 300 '\[rts\] research probe' build/p4-research`, final code (`ARMOR_ALL_UNITS = true`) | `build/p4-research` | `research probe summary 21/21 (all passed)` | 0 |
| Legacy Phase 1/2 autotest, 240 s, `AUTOTEST_MATCH` set to `size = "legacy", enemy_brain = "waves"` | `build/p4-research-legacy`, `-legacy2`, `-legacy3`, `build/p4-ab-t1`, `-t2`, `-f1`, `-f2` | 65/65 in 6 of 8 runs (the first, mk2-only filter, in a copy since overwritten). See "Legacy variance" below. | 0 |
| AI autotest, 420 s, unchanged copy, final code | `build/p4-research-ai` | `ai autotest summary 14/14 (all passed), result=both alive (time)` in both runs (mk2-only filter and all-units filter); armies stayed under 40 supply, so no kit was refused | 0 |
| GUI, Russian (system language), `tools/gui-run.sh build/p4-research-gui 160 RESEARCH_GUI_DONE` | `build/p4-research-gui` | 14 probe checks passed before the marker, panel opened through the T handler path, a scripted click queued Mining I | 0, no "Unknown key" |
| GUI, English (scratch copy of `gui-run.sh` that appends `[general] locale=en`) | `build/p4-research-gui-en` | Same | 0 |

**The probe** starts its own 1v1 match against an easy AI and suppresses the default autotest. It then drives
`rts-player`, which has no AI commander. Each line below is one check, in order:

1. `init_force` and `init_force_ai`: 0 vanilla technologies enabled and 19 rts ones, for `rts-player` and for
   `rts-ai-1`.
2. `supply_initial`: 6 of 40.
3. `laser_recipe_locked`, `laser_set_recipe_refused`: the laser recipe is disabled and `production.set_recipe` refuses
   it. The first probe run failed this check, which led to the `set_recipe` hook (Gotcha 1).
4. `kit_recipe_set`, `kit_crafted`: a factory set to `rts-science-basic` finished 3 kits in 20 s from 20 gears plus
   copper, through the normal production pull and hand-off.
5. `labs_registered`: 8 labs registered as kind `lab`. They were given 200 basic and 100 advanced kits.
6. `queue_locked_refused`: Attack II is refused with status `locked`. `queue_tier1`: Attack I, Unlock Heavy, Armor I
   and Supply I are queued.
7. `heavy_locked`: a heavy kit put into a barracks output stays there, with `research_block = locked /
   rts-unlock-heavy`.
8. `attack1_modifiers`: Attack I finished 25 s after it was queued, with 8 labs. Then `rts-artillery`, `rts-commander`, `rts-drone`,
   `rts-heavy`, `rts-raider` and `rts-walker` read 0.15, and so do both turrets.
9. `heavy_spawned_after_unlock`: the waiting heavy kit became an `rts-walker-heavy` in the same sweep that Unlock Heavy
   finished.
10. `armor1_mk2_spawn`: after Armor I, a walker kit becomes `rts-walker-mk2`.
11. `supply1_cap`: the cap is 50. Filling it with 40 walkers gives 50/50, and a walker kit then waits
    (`supply_blocked`), with a `supply-blocked` alert in `storage.alerts`. After one walker dies, the kit becomes an mk2
    walker within 3 s (`supply_released`).
12. `armor2_damage`: with Armor II, an mk2 walker and a tier-1 walker each lose 90.00 of 100 physical damage, against
    100.00 without the share. An `rts-ai-1` walker (no research) loses 100.00. The armored names are `rts-artillery`,
    `rts-drone`, `rts-heavy-mk2`, `rts-raider`, `rts-walker`, `rts-walker-heavy` and `rts-walker-mk2`.
13. `laser_unlocked`: after Unlock Laser, the recipe is enabled and `set_recipe` accepts it.
14. `match_reset`: `lobby.start_match` for match 2. In the same tick: 0 technologies researched, every modifier back to
    0.00, cap 40, the laser recipe disabled and the queue empty.

The six researched technologies (four tier 1 and two tier 2, 115 kits) took about 145 s with 8 labs. That matches
115 × 10 s / 8 = 144 s. Neither the legacy run nor the
AI run logged a single supply refusal.

**Last probe run (supply caps from `balance.lua`).** By then, the wave B agents' work in `mods/` failed to load. The
`hud.lua` main chunk hit "too many local variables (limit is 200)" at line 1981, which is not a research file. The last
probe therefore ran on the snapshot of `build/p4-ab-t1`, with these changes:

- the current `scripts/supply.lua`;
- `balance.lua` patched to `supply_cap` for the CC and the hub;
- `research.lua` and `techgui.lua` identical to `mods/`.

The result was `research probe summary 21/21 (all passed)`, 0 errors, and `supply: CC cap 40 (balance), hub cap 10
(balance)`.

**Legacy variance.** The 65/65 legacy autotest does not use research. Two runs with the all-units filter scored
64/65 and failed `eco_shared_pool`. The autotest's own Phase 1 attack-move destroyed the enemy barracks and CC, at 73 s
and 98 s. The match then ended in a victory, and the autotest's `/rts-qa-reset` started a new match. That match had no
economy base, so the 75–150 s window saw no progress. Economy notes gotcha 8 describes the same attack-move razing the
enemy base. Then 4 runs of one identical copy, 2 with `ARMOR_ALL_UNITS = true` and 2 with `false`, all passed 65/65 with
no early victory. A third `false` run passed too. With research unused, both damage handlers return on their first
check, so the filter cannot change combat. The test is sensitive to combat strength. `balance.lua` and
`prototypes/units.lua` changed at 23:20–23:33, between the first passing run and the failing ones.

**Measured costs** (probe, Space Age, 10 000 or 1 000 direct calls):

| Call | Cost |
|---|---|
| `research.on_damaged`, heal path | 1.1–2.7 µs (four runs, 3–4 servers in parallel) |
| `research.on_damaged`, early exit | 0.9 µs |
| `supply.can_spawn` with 48 own and 56 registered units | 33 µs. It walks the unit registry once. At 400 units, expect about 0.25 ms. The barracks gate calls it once per finished kit. If the HUD shows supply every refresh, cache `supply.get` per tick or per 30 ticks. |

**Screenshots.**

| File | What it shows |
|---|---|
| `build/shots-p4-research-gui/rts-p1-1140.png` (Russian) | The panel at 00:14: Attack I at 51 %, four queued |
| `build/shots-p4-research-gui/rts-p1-3900.png` (Russian) | The panel at 01:00: Attack I and Heavy walkers done (green), Armor I 60 % with Cancel, Mining I queued by the scripted click, tier 2 rows available or locked by prerequisites, "Labs: 8 (working: 8)", kits in the network |
| `build/shots-p4-research-gui-en/rts-p1-1140.png`, `rts-p1-3900.png` (English) | The same two moments |

The name column is 190 px wide. The first Russian run with 150 px clipped "Вместимость транспортёров I" and
"Артиллерийские шагоходы". The frame is about 785 × 410 px in the 1280 × 800 screenshots and is auto-centred.

## Gotchas

1. **`LuaEntity.set_recipe` accepts a recipe the force has disabled.** The probe's first run set the locked laser
   turret recipe on a factory without complaint. `production.set_recipe` now checks `force.recipes[name].enabled` first.
   Code that calls `entity.set_recipe` directly bypasses this check.
2. **Technology names ending in `-N` are level names.** Without an explicit `localised_name`, the engine looks up
   `technology-name.rts-attack` for `rts-attack-1`. Every RTS technology sets its own key.
3. **Un-researching raises `on_research_reversed`.** The reset un-researches successors first, by reverse tree order,
   and the reversed handler is muted during the reset. Prerequisites are never un-researched under a researched
   successor.
4. **Force modifiers are shared.** The hard AI adds a mining bonus, so research applies deltas, never absolute values.
   `storage.research.applied` is the bookkeeping. Writing absolute values here would erase the AI's bonus.
5. **The damage filter is one per mod.** The last `set_event_filter` call wins, so `scripts.research` must load after
   `scripts.ai.init` (control.lua). See "The damage filter".
6. **The research queue is on.** In 2.0, `add_research` appends, and a queue of 5 worked. Writing `research_queue = {}`
   cancels the current research.
7. **275 vanilla technologies** (Space Age) are disabled for every `rts-*` force, the template force included. T is
   consumed `game-only`, so the vanilla technology screen does not open on T.
8. **The barracks keeps crafting a refused kit until its output is full.** A locked or capped barracks wastes a few
   kits' worth of plates. Pausing the barracks is the player's or the HUD's call.
9. **A killing blow is not reduced by Armor II/III.** The handler skips hits that leave `final_health` at 0.
10. **Lab placement.** A lab outside every CC or hub logistic network gets no kits and logs `no network`. The lab is
    3×3 and draws 60 kW.

## Decisions and open items for the lead

- **Armor II/III scope: decided.** All units (option 1). The guard is in `scripts/ai/init.lua:131`, and
  `research.ARMOR_ALL_UNITS = true`. Setting it to `false` is the mk2-only fallback.
- **The AI is exempt from unit locks** (`research.AI_IGNORES_LOCKS`). It still has the supply cap. B1 should switch the
  exemption off when the AI researches.
- **Heavy walkers are locked behind Unlock Heavy for human players.** `balance.lua` has no `unlock` flag on the heavy,
  but the tree in docs/PHASE4.md and the lead's brief have the technology. The gate does the locking, so no recipe
  changes.
- **Haulers are free.** `balance.units["rts-hauler"].supply = 0` (content agent).
- **HUD (B2).** The HUD needs:
  - the supply strip (`supply.get`);
  - the alert line for `storage.alerts`, whose entries may carry `params`;
  - `rts-lab` in the build menu;
  - greyed-out disabled recipes;
  - the barracks block reason;
  - a button that calls `techgui.toggle`.
- **The probe copies can be deleted** after review: `build/p4-research*`.
