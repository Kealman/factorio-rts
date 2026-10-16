# Factorio RTS

A Factorio 2.0 mod that turns the game into a StarCraft-style RTS. You get a free camera instead of an engineer, box-select and right-click orders, and a Factorio production chain that turns ore into an army. Your opponents are AI commanders that build real bases, expand and attack you. The economy is the core of the game: you mine, smelt, build forward hubs, run haulers between them and research upgrades, while you fight over ore patches that run out.

**Status: Phase 4.** You can play 1v1 to 1v3 skirmishes against AI commanders, each with its own doctrine. Phase 4 adds hubs, haulers, research, abilities, a Commander hero, and generated maps with water moats. Design: `docs/DESIGN.md`. Phase plans: `docs/PHASE1.md` to `docs/PHASE4.md`. QA protocols and module notes: `docs/qa/`.

## Install (macOS, Steam build)

```sh
tools/install.sh      # copies mods/factorio-rts into ~/Library/Application Support/factorio/mods
                      # and enables only base, Space Age DLC mods and factorio-rts (your old mod list is backed up)
tools/uninstall.sh    # removes the mod and restores the backed-up mod list
```

Start Factorio and choose New game → Freeplay. The RTS lobby opens as soon as you join. Pick your settings and press **Start match**:

- **Opponents:** 1 to 3 AI commanders, free-for-all.
- **Difficulty:** easy, normal or hard.
- **Map size:** small (256×256), medium (384×384) or large (512×512).
- **Map:** *Chokepoints* puts a 16-tile water moat in front of every base, with one 14-tile land gap, plus lakes and forests. A small map with 2 or 3 opponents has no room for moats and gets only lakes and forests. *Open field* is flat grass. Both maps have the same ore patches and a ruin in the middle.

Every side starts with a Command Center (CC), the same stock and 6 walkers. Human players also get a Commander. Space Age is optional: with it, units use the Gleba pentapod graphics; without it, they are built from the spidertron. Drones use biter graphics either way.

## Controls

| Input | Action |
|---|---|
| WASD / mouse wheel | Pan / zoom (remote view) |
| Space | Camera to your CC |
| Click on the minimap | Camera jumps there |
| Left click | Select one unit; if no unit is there, select your own building |
| Left drag | Box-select units |
| Shift + left click / drag | Add to the selection |
| Ctrl+A | Select every unit you own, including haulers and the Commander |
| Ctrl+1..5 / 1..5 | Assign / recall a control group (double tap: camera jumps to it) |
| Click / Shift + click a unit card | Keep only that unit type / drop it from the selection |
| Right click | Move, or attack the enemy under the cursor |
| F, then right click | Attack-move (press F or X again to cancel) |
| Shift + right click | Attack-move |
| X / H | Stop / hold position |
| Right click with a barracks selected | Set its rally point |
| Right click a hub or CC with haulers selected | Set the route's pickup |
| Shift + right click a hub or CC with haulers selected | Set the route's drop-off |
| Right click the ground with haulers selected | Move there and park (**Resume** in the hauler panel restarts the route) |
| Z / C / V / G | Stim / Shield / Scanner sweep / Artillery strike (see below) |
| B | Show or hide the build menu |
| Left click on the map while placing | Place a ghost (R rotates) |
| Q or right click | Stop placing |
| T | Research panel |
| F3 | Jump to the newest alert (press again for older ones) |
| F10 | Match menu (resume, restart) |
| F11 | How to play |
| F1 | Get the RTS cursor back |
| Ctrl+Shift+R | QA: restart the current match with the same settings (admin) |
| Ctrl+Shift+E | QA: write a state summary and the `RTS_QA_END` marker to the log |

On macOS, every Ctrl chord also works with Cmd. You can rebind keys under Settings → Controls; the mod's controls are named "RTS: …", "Ability: …" and "Research panel". Watch out: Ctrl+A also selects your haulers, so a right click on the ground parks them too.

Abilities are on the bar at the bottom centre. Cooldowns are per side.

| Key | Ability | Needs | Effect | Cooldown |
|---|---|---|---|---|
| Z | Stim | Damaged units selected; 10 iron per unit | Heals 30 % of max HP; drones and the Commander also move 50 % faster for 8 s | 30 s |
| C | Shield | A live Commander | The Commander and your units within 8 tiles take half damage for 10 s | 45 s |
| V | Scanner sweep | *Scanner sweep* research; then right-click a target | Reveals a 48×48 area for 30 s | 60 s |
| G | Artillery strike | An artillery walker 8–40 tiles from the target; then right-click a target | Each one fires 2 shells, then keeps attacking there | 20 s |
| (button only) | Overcharge | *Overcharge* research and a CC | Turrets deal double damage for 10 s while the CC's buffer loses 1 MW | 90 s |

After you press V or G, the ability waits for your target. Pressing the key again, X or F cancels it.

## How the economy works

**The pool.** Your CC is a roboport with 3,000 HP, 20 construction and 10 logistic robots, 4 stockpiles and a 4 MW power core. Its logistic network covers 25 tiles in every direction, and its robots build up to 40 tiles out. Stockpiles inside a logistic area belong to that network, and barracks, factories, labs and turrets pull what they need from the network they stand in. A building outside every logistic area gets nothing. Everything you order is a ghost. Construction robots build a ghost from items in the network, but only inside a construction area; the CC's panel shows both ranges.

**Chains.** Extractors mine 1 ore/s from the 5×5 tiles under them. Each one drops its ore onto a belt or straight into a smelter. A smelter makes 0.625 plates/s, so one extractor keeps about 1.6 smelters busy. Smelters also turn stone into bricks and iron plates into steel (2 plates per steel, 3.2 s). A fast inserter moves the output into a stockpile. Stone and coal need no smelting: run them on a belt, then an inserter, into a stockpile. The **factory** repeats the recipe you pick in its panel and sends the output to the network. It makes buildings, belts, inserters, poles, magazines, intermediates (gears, cable, circuits, explosives from coal and iron), science kits and hauler kits. The **barracks** turns plates into unit kits, and each finished kit walks out to the rally point.

| Building | Cost | Building | Cost |
|---|---|---|---|
| Extractor | 20 iron, 5 copper | Lab | 24 iron, 8 copper |
| Smelter | 20 iron, 10 stone | Hub | 32 iron, 10 copper |
| Stockpile (48 slots) | 20 iron, 5 copper | Solar array (400 kW) | 10 iron, 15 copper |
| Factory, Barracks | 60 iron, 20 copper each | Accumulator | 10 iron, 10 copper |
| Turret | 40 iron, 10 copper | Steam plant (research) | 40 iron, 10 steel |
| Laser turret (research) | 20 iron, 10 circuits | Radar | 20 iron, 10 circuits |
| 5 walls | 5 stone bricks | 10 belts / 10 magazines | 10 iron |

**Hubs** are forward bases. A hub has 1,200 HP, a logistic radius of 14 and a construction radius of 22. It comes with 10 construction and 6 logistic robots, plus 5 more logistic robots after *Logistics I*. Two stockpiles appear beside it, and an internal 300 kW generator powers the hub and about two extractors through its own 16×16 pole. Every hub adds +10 supply. Hubs whose logistic areas touch share one network. The CC's area and a hub's touch when the hub is within 39 tiles of the CC; two hubs touch within 28 tiles. Each hub or CC has a **stockpile policy** in its panel. *Keep N* means haulers bring the item until the network holds N. *Export above N* means anything over N is offered to haulers. By default, a CC exports iron, copper and steel above 100, and a new hub keeps 50 iron and 20 copper but exports nothing. To ship a hub's output home, set its *Export above*.

**Building at the natural expansion.** Your natural iron and copper pair lies 50 tiles out on a small map, 70 on medium and 76 on large. The CC's robots reach only 40 tiles and a hub's 22, so a ghost out there waits for the **Commander**: its personal roboport builds every ghost within 15 tiles of it, and while it stands there its trunk is stocked from your CC's pool with the items those ghosts need (anything left over goes back when you walk away). So: let the factory make a hub (and the extractors, smelters, belts and poles for the outpost), place the ghosts at the patch, and walk the Commander next to them. The pool pays exactly what a CC robot would take.

A hub at the natural has its own network. Its stockpiles start empty, so mined plates stay there until a **hauler** takes them home: set the hub's *Export above* (for example iron above 20), make a hauler, and give it a route: right-click the natural hub (pickup), then Shift + right-click the CC (drop-off). Or keep a hub within 39 tiles of the CC (logistic areas touch) or of another joined hub to make one big network that needs no haulers.

**Haulers** carry items between separate networks: a hub at a natural or middle patch, the ruin's stockpiles, or a chain of hubs cut because its middle hub died. The factory makes a hauler from a hauler kit (30 iron, 10 circuits). It walks out in **auto** mode, homed at the hub of the factory's network. An auto hauler fills its home's *Keep* amounts from the nearest network that exports the item. For a **manual route**, right-click the pickup hub and Shift + right-click the drop-off hub. The hauler loads what the pickup exports and the drop-off wants (a drop-off with no *Keep* set takes every export), and loops until you change it. Haulers have 400 HP, 20 cargo slots (+10 with *Hauler capacity I*), no weapons and about twice a walker's speed, and they path around water. Raiders deal 2.5× damage to them and drones hunt them; each loss raises an alert.

**Supply.** The cap is 40 with a CC, +10 per hub, and +10 each for *Supply I* and *Supply II*. Walkers and drones cost 1 supply, raiders 2, heavies 3 and artillery 4; Mk2 units cost the same as their base unit. Haulers and the Commander are free. At the cap, a finished kit waits in the barracks until a unit dies or the cap grows.

**Research.** Labs take science kits from their network, at 10 s per kit per lab, so more labs research faster. The factory makes **basic kits** from 1 gear + 1 copper plate (5 s). Gears come from the factory too, at 2 iron each. **Advanced kits** take 2 circuits + 1 steel (10 s); a circuit is 1 iron + 3 copper cable, and one copper plate makes 2 cable. Tier 1 uses basic kits and tier 2 advanced kits.

| Technology | Kits | Effect |
|---|---|---|
| Supply I / II | 8 basic / 20 advanced | +10 supply each |
| Attack I / II / III | 15 basic / 25 / 40 advanced | +15 % damage for units and turrets, per level |
| Armor I | 15 basic | Barracks deploy Walker Mk2 and Heavy Mk2 (+40 % HP, +25 % damage) from the same kits |
| Armor II / III | 25 / 40 advanced | Units heal back 10 % of each hit, 20 % with both |
| Mining I / II | 11 basic / 25 advanced | +25 % ore per level; the patch drains no faster |
| Logistics I | 11 basic | Robots 50 % faster with +1 cargo; +5 robots per hub |
| Hauler capacity I | 11 basic | +10 hauler cargo slots |
| Heavy walkers / Raiders | 11 / 15 basic | Unlock the unit |
| Artillery walkers | 30 advanced (needs Heavy walkers) | Unlocks artillery |
| Laser turrets / Steam power | 25 / 20 advanced | Unlock the building |
| Overcharge (needs Laser turrets) / Scanner sweep | 25 / 20 advanced | Unlock the ability |

**Power.** The CC core supplies 4 MW and powers everything within 18 tiles; medium poles carry it further. Other sources are a hub's 300 kW, solar arrays (400 kW each, steady, because the arena is always day) and steam plants. A steam plant needs the *Steam power* research, gives 1.8 MW and burns 0.45 coal/s that an inserter feeds in. Accumulators store spare power for peaks. For scale, an extractor draws 90 kW, a smelter 180 kW and a lab 60 kW. A laser turret needs no ammo but takes 800 kJ per shot, up to 2 MW while it fires. Low power slows every machine.

**Depletion and expansion.** Patches are finite:

| Patch | Iron | Copper | Stone | Coal |
|---|---|---|---|---|
| Main | 6,000 | 4,000 | 3,000 | 3,000 |
| Natural | 8,000 | 4,000 | – | – |
| Middle | 12,000 | 8,000 | – | 6,000 |

A main iron patch at full speed lasts 50 minutes with 2 extractors, 25 with 4, about 17 with 6 and 12.5 with 8. An extractor that feeds a single smelter only drains 0.625 ore/s, so 4 such lines last 40 minutes. The normal AI's main iron lasts about half an hour. Extractors on the thin edge of a patch run dry first. A *patch depleted* alert tells you when a patch is empty.

**The ruin** sits in the middle of the map: a dead CC with two stockpiles holding 200 steel plates and 50 circuits. A unit standing within 4 tiles of a ruin stockpile for 10 s captures both stockpiles, as long as no other side's units are there. A rival can take them back the same way. The stockpiles only join a network if a hub stands next to them: walk the Commander there to build one, then haul the steel and circuits home.

## Your first match

You start with 400 iron, 150 copper, 2 extractors, 2 smelters, 1 barracks, 1 factory, 2 stockpiles, 60 belts, 16 fast inserters, 16 medium poles, 6 walkers and the Commander. All of the buildings are still items in the stockpiles. Your iron patch is about 17 tiles in front of the CC and 10 to one side, with copper on the other side and stone and coal further out. This plan mirrors the normal AI's opening:

1. **0:00** Place the factory next to the CC. Build two iron lines (each an extractor feeding a smelter, then an inserter into one of your spare stockpiles) and connect them with poles. Place the barracks.
2. **0:30** Set the factory to make extractors. Put one on stone and belt it into a stockpile, because every new smelter costs 10 stone. Add a third iron extractor.
3. **1:00–1:45** Build a lab and a second factory. Set that factory to basic science kits, and have the first factory make about 10 gears between buildings. Press T and research Supply I (8 kits) or Mining I first.
4. **1:45–3:00** Add iron smelters 3 and 4 and a copper extractor with its smelter. Start the barracks on walker kits once 3 or 4 iron smelters run: a busy barracks eats about 200 iron per minute, and one smelter makes 37. Put two turrets towards the enemy and make magazines.
5. **3:00** The first attack can come now if you face an aggressive normal AI (see below). Your walkers, the Commander's rockets, Shield (C) and Stim (Z) hold it.
6. **3:30** Set up a steel smelter that gets iron plates from another smelter by inserter; heavies need steel. Add a second lab and a feeder factory for gears or circuits.
7. **~4:00** First hub at the natural: the factory makes it, you place the ghost and walk the Commander there (see above). Then extractors and smelters on the natural feeding the hub's stockpiles, *Export above* on the hub and a hauler to bring the plates home.
8. **By 6:00** Aim to have Supply I and one unlock (Heavy walkers or Raiders) done, and to mix units by counter. Walkers and drones need no research, and walkers are your default unit.
9. **6:00–10:00** Make advanced kits (cable, circuits and steel) for Artillery walkers, Laser turrets and Supply II, expand to the middle patches and contest the ruin.

## Units

| Unit | Kit cost | Supply | HP | Range | Role | Beats | Loses to | Unlock |
|---|---|---|---|---|---|---|---|---|
| Walker | 10 iron, 2 copper | 1 | 200 | 20 | Ranged line | drones, raiders | heavies, artillery | – |
| Drone | 6 iron | 1 | 85 | melee | Fast swarm; bites ignore heavy armour, ×3 vs raiders | artillery, raiders | turrets, walkers | – |
| Heavy walker | 30 iron, 10 copper, 5 steel | 3 | 800 | 16 | Tank: 60 % physical armour, splash | walkers, drones | artillery, laser turrets | Heavy walkers |
| Raider | 8 iron, 2 circuits | 2 | 220 | 18 | Fast raider: ×2.5 vs economy buildings, poles, hubs, haulers | artillery | walkers, turrets, drones | Raiders |
| Artillery walker | 40 iron, 5 steel, 10 explosives | 4 | 450 | 44 (min 8) | Siege, area shells, ×9 vs heavies | heavies | drones, raiders | Artillery walkers |
| Walker / Heavy Mk2 | same kit as the base unit | 1 / 3 | 280 / 1,120 | 20 / 16 | +25 % damage | as base | as base | Armor I |
| Commander | free, one per player | 0 | 2,000 | 30 | Hero: rockets; level 2 at 5 kills and level 3 at 15, each adding a 400 shield; respawns at the CC 60 s after dying | – | – | – |
| Hauler | 30 iron, 10 circuits (factory) | 0 | 400 | – | Unarmed cargo | – | raiders, drones | – |

Kits come from the barracks: walkers take 3 s, drones 2 s, raiders 5 s, heavies 8 s and artillery 12 s. Speeds relative to a walker: drone ×1.45, raider ×1.35, artillery ×0.65, heavy ×0.55. Defences:
- **Turret:** 1,200 HP, range 21, about 42 damage/s, fed with magazines from the network.
- **Laser turret:** 1,000 HP, range 22, 75 damage/s from power.
- **Wall:** 500 HP per segment.
- **Radar:** keeps a 160×160-tile area visible.

You see only what your units and buildings see.

## AI

Each AI side draws a **doctrine** at match start. The draw is seeded by the map seed, the match number and the AI's number, so AIs in one match can differ and a new match draws again. An admin can override it with `/rts-ai-doctrine <force> <name>`.

- **Economic:** builds units after its third iron smelter. Its first hub goes up right after the steel chain (around 4:00 on normal), a copper hub follows at about 4:30, and each hub gets a hauler. Two units patrol the route to the hub. Research: Supply I, Heavy walkers, Mining I, Logistics I…
- **Aggressive:** makes units from the start, adds a second barracks at 4:00, and fields drones and raiders (Raiders right after Supply I). It harasses haulers and outlying buildings every 2 minutes, targets extractors and hubs first and builds its hub late.
- **Turtle:** builds turrets from 1:15 (up to 6), then coal and explosives for artillery, solar arrays, two laser turrets once researched, and a late hub.

| | Easy | Normal | Hard |
|---|---|---|---|
| Build pace (one construction job per) | 6 s | 3 s | 2 s |
| First attack: aggressive / economic / turtle | 5:00 / 8:30 / 11:00 | 3:00 / 5:06 / 6:36 | 1:30 / 2:33 / 3:18 |
| Attack size (units): aggressive / economic / turtle | 5 / 6 / 7 | 8 / 10 / 11 | 10 / 12 / 13 |
| Time between attacks | at least 4 min | none | none |
| Vision | what its units and buildings see | what its units and buildings see | the whole map |
| Bonuses | – | – | +50 % starting stock, +25 % mining, every 4th unit free |

Easy opens with one iron and one copper smelter, and only half of its idle army defends. Hard runs the normal build order with time gates ×0.7, and its economic and turtle doctrines add a second barracks. At every difficulty the AI is not held to unit unlocks: it can deploy heavies, raiders and artillery before it has researched them.

## Development

- `tools/headless-run.sh <seconds> '\[rts' mods` runs a map with the mod on a headless server and prints the mod's log. The autotests (`[rts] autotest`, `[rts] ai autotest`) run when no player is connected.
- `tools/gui-run.sh mods <seconds> 'RTS_GUI_READY'` launches the real client with an isolated config (its own write dir and port; F9 opens the console).
- `tools/autotest-run.sh <name> '<lua match table>' [cap=640]` runs one headless AI-autotest scenario on a copy in `build/<name>/` and prints the summary, the per-minute and perf lines and every Lua error. Env options:
  - `VARIANT=sa|base`: Space Age or the base game.
  - `SPEED=<n>`: game speed; UPS numbers only mean something at 1.
  - `SEED=<n>`: map seed.
  - `RESTART_AT=<s>`: restart the match through the Ctrl+Shift+R path, then run the autotest again.
  - `PERF=1`: per-module handler timings.
  - `STRESS=<s>:<n>`: give every side `n` extra walkers and `n`/2 drones at `s` seconds.
  - Also `DURATION_MIN`, `DOCTRINES`, `STOP_ON` and `KEEP_TREE`.
- `tools/autotest-matrix.sh <tag> [filter]` runs the Phase 4 validation matrix in parallel (difficulties, sizes, 1v3, base-only, stress, restart) into `build/matrix-<tag>/` and prints a one-line-per-run table.
- `tools/autotest-batch.sh <tag> <reps> 1v<n>-<difficulty>-<size>...` runs seeded balance samples (the same rep uses the same seed in every tree, so two trees give paired samples) into `build/batch-<tag>/`.
- `tools/saveload-check.sh <name> '<lua match table>' [seconds]` saves a running match at minute 3, reloads it and reports errors from both halves.
- `tools/balance-sim/run.sh <name> [sa|base]` and `tools/balance-sim/both.sh` run the equal-cost unit fight simulator that checks the counter table (`docs/qa/phase4-balance-notes.md`).
- `tools/locale-probe/gen.py <mod dir> <out.lua>` generates a probe that makes a GUI client translate every locale key the mod uses and logs the missing ones.
- Admin console: `/rts-match`, `/rts-give <item> [n]`, `/rts-dump`, `/rts-mapgen`, `/rts-ai-doctrine`, `/rts-qa-reset`, `/rts-qa-end`.
- Interactive QA protocols and results are in `docs/qa/` (`phase1-protocol.md` to `phase3-protocol.md`, and `phase4-protocol.md`). Mod layout, storage schema and module contracts are in `docs/PHASE1.md` to `docs/PHASE4.md`; per-module notes are in `docs/qa/*-notes.md`.
