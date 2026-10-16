# Factorio RTS

A Factorio 2.0 mod that turns the game into a StarCraft-style RTS. You get a free camera instead of an engineer, box-select and right-click orders, and a Factorio production chain that turns ore into an army. Your opponents are AI commanders that build real bases, expand and attack you. The economy is the core of the game: you mine, smelt, build forward hubs, run haulers between them and research upgrades, while you fight over ore patches that run out.

**Status: Phase 5, milestone M1 ("Two cities and a railway").** Two modes. **Skirmish** is the Phase 4 game: 1v1 to 1v3 matches against AI commanders with their own doctrines, with hubs, haulers, research, abilities, a Commander hero and generated arenas with water moats. **Nation** (new) plays on a generated world of 1536 to 3072 tiles: you found cities, claim land, connect your cities by rail, ship goods between them and race the AI to Age II through a national project (see [Nation mode](#nation-mode)). Divisions and demolishing your own buildings work in both modes. Design: `docs/DESIGN.md` and `docs/SCALE-VISION.md`. Phase plans: `docs/PHASE1.md` to `docs/PHASE4.md` and `docs/PHASE5-M1.md`. QA protocols and module notes: `docs/qa/`.

## Install (macOS, Steam build)

```sh
tools/install.sh      # copies mods/factorio-rts into ~/Library/Application Support/factorio/mods
                      # and enables only base, Space Age DLC mods and factorio-rts (your old mod list is backed up)
tools/uninstall.sh    # removes the mod and restores the backed-up mod list
```

Start Factorio and choose New game → Freeplay. The RTS lobby opens as soon as you join. Pick your settings and press **Start match**:

- **Mode:** *Skirmish* (the arena maps below) or *Nation* (a generated world, see [Nation mode](#nation-mode)).
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
| Left click | Select one unit (the whole division if it belongs to one); if no unit is there, select your own building, or a train by any of its carriages |
| Left drag | Box-select units |
| Shift + left click / drag | Add to the selection (only the units hit, even inside a division) |
| Ctrl+A | Select your army: every combat unit and the Commander, not the haulers |
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
| Right click another own depot with a depot selected | Nation: lay a rail line between the two depots |
| Right click / Shift + right click a depot with a train selected | Nation: set the train's pickup / drop-off |
| Z / C / V / G | Stim / Shield / Scanner sweep / Artillery strike (see below) |
| B | Show or hide the build menu |
| Left click on the map while placing | Place a ghost (R rotates) |
| R / Shift + R | Rotate the building or ghost under the cursor (while placing: the ghost on the cursor) |
| Q or right click | Stop placing |
| T | Research panel |
| L, or a click on the age badge | Nation: city ledger (age, national project, goods, make targets) |
| Delete or Backspace, or the **Demolish** button | Demolish the selected own building: the first press arms (the button turns red), a second press within 3 s demolishes it. 50 % of its cost goes back to the nearest other stockpile of its logistic network (with none there, the refund is lost and the contents spill on the ground). A hub, depot or City Center takes its stockpiles with it. The Command Center, the capital and trains cannot be demolished ("Locomotive cannot be demolished.") |
| F3 | Jump to the newest alert (press again for older ones) |
| F10 | Match menu: resume, restart, concede (click twice); after the match, the results again |
| F11 | How to play |
| F1 | Get the RTS cursor back |
| Ctrl+Shift+R | QA: restart the current match with the same settings (admin) |
| Ctrl+Shift+E | QA: write a state summary and the `RTS_QA_END` marker to the log |
| The grave key (`` ` ``), or F9 in `tools/gui-run.sh` clients | Game console: chat and the admin commands under Development. A chat line `RTS_QA_END` also writes the end marker |

On macOS, every Ctrl chord also works with Cmd. You can rebind keys under Settings → Controls; the mod's controls are named "RTS: …", "Ability: …", "Research panel" and "City ledger". Haulers are left out of Ctrl+A; select them with a click or a box.

Abilities are on the bar at the bottom centre. Cooldowns are per side.

| Key | Ability | Needs | Effect | Cooldown |
|---|---|---|---|---|
| Z | Stim | Damaged units selected; 10 iron per unit | Heals 30 % of max HP; drones and the Commander also move 50 % faster for 8 s | 30 s |
| C | Shield | A live Commander | The Commander and your units within 8 tiles take half damage for 10 s | 45 s |
| V | Scanner sweep | *Scanner sweep* research; then right-click a target | Reveals a 48×48 area for 30 s | 60 s |
| G | Artillery strike | An artillery walker 8–44 tiles from the target (its own range); then right-click a target | Each one fires 2 shells, then keeps attacking there | 20 s |
| (button only) | Overcharge | *Overcharge* research and a CC | Turrets deal double damage for 10 s while the CC's buffer loses 1 MW | 90 s |

After you press V or G, the ability waits for your target. Pressing the key again, X or F cancels it.

## How the economy works

**The pool.** Your CC is a roboport with 3,000 HP, 20 construction and 10 logistic robots, 4 stockpiles and a 4 MW power core. Its logistic network covers 25 tiles in every direction, and its robots build up to 40 tiles out; further out, the Commander builds (see below). Stockpiles inside a logistic area belong to that network, and barracks, factories, labs and turrets pull what they need from the network they stand in. A building outside every logistic area gets nothing. Everything you order is a ghost. Construction robots build a ghost from items in the network, but only inside a construction area; the CC's panel shows both ranges.

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

**Building at the natural expansion: the Commander.** Your natural iron and copper pair lies 50 tiles out on a small map, 70 on medium and 76 on large, beyond the CC's 40-tile robot reach. The **Commander** builds there: its personal roboport builds every ghost within 15 tiles of it, and while it stands there its trunk is stocked from your CC's pool with the items those ghosts need (anything left over goes back when you walk away). So: let the factory make a hub (and later the extractors, smelters, inserters and poles for the outpost); select the Commander, right-click next to the natural ore to walk it there, and place the hub ghost near it. Its robots build the hub within seconds, and the pool pays exactly what a CC robot would take. The same works for the middle patches and the ruin.

A hub at the natural is more than 39 tiles from the CC, so it has its own network. Its stockpiles start empty, and mined plates stay there until a **hauler** takes them home: set the hub's *Export above* (for example iron above 20), make a hauler, and give it a route: right-click the natural hub (pickup), then Shift + right-click the CC (drop-off). A hub within 39 tiles of the CC (logistic areas touch) or 28 tiles of another joined hub joins that network instead and needs no haulers.

**Haulers** carry items between separate networks: a hub at a natural or middle patch, the ruin's stockpiles, or a chain of hubs cut because its middle hub died. The factory makes a hauler from a hauler kit (30 iron, 10 circuits). It walks out in **auto** mode, homed at the hub of the factory's network. An auto hauler fills its home's *Keep* amounts from the nearest network that exports the item. For a **manual route**, right-click the pickup hub and Shift + right-click the drop-off hub. The hauler loads what the pickup exports and the drop-off wants (a drop-off with no *Keep* set takes every export), and loops until you change it. Haulers have 400 HP, 20 cargo slots (+10 with *Hauler capacity I*; 10 slots and coal fuel in Nation mode, see below), no weapons and about twice a walker's speed, and they path around water. Raiders deal 2.5× damage to them and drones hunt them; each loss raises an alert.

**Supply.** The cap is 40 with a CC, +10 per hub, and +10 each for *Supply I* and *Supply II* (in Nation mode also +10 per depot, the supply of your other cities and +15 for *Supply III*). Walkers and drones cost 1 supply, raiders 2, heavies 3 and artillery 4; Mk2 units cost the same as their base unit. Haulers and the Commander are free. At the cap, a finished kit waits in the barracks until a unit dies or the cap grows.

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

You start with 400 iron, 150 copper, 2 extractors, 2 smelters, 1 barracks, 1 factory, 2 stockpiles, 60 belts, 16 fast inserters, 16 medium poles, 6 walkers and the Commander. All of the buildings are still items in the stockpiles. Your iron patch is about 17 tiles in front of the CC and 10 to one side, with copper on the other side and stone and coal further out. This plan mirrors the normal AI's opening.

**Play your first game on Easy.** Easy's first attack comes at 5:00 at the earliest and at least 4 minutes pass between attacks. On Normal an aggressive AI attacks at 3:00, so keep the barracks making walkers from the first minute and keep your army near the CC.

1. **0:00** Place the factory next to the CC. Build two iron lines (each an extractor feeding a smelter, then an inserter into one of your spare stockpiles) and connect them with poles. Place the barracks.
2. **0:30** Set the factory to make extractors. Put one on stone and belt it into a stockpile, because every new smelter costs 10 stone. Add a third iron extractor.
3. **1:00–1:45** Build a lab and a second factory. Set that factory to basic science kits, and have the first factory make about 10 gears between buildings. Press T and research Supply I (8 kits) or Mining I first.
4. **1:45–3:00** Add iron smelters 3 and 4 and a copper extractor with its smelter. Start the barracks on walker kits once 3 or 4 iron smelters run: a busy barracks eats about 200 iron per minute, and one smelter makes 37. Put two turrets towards the enemy and make magazines.
5. **3:00** On Normal, an aggressive AI attacks now (economic at about 5:00, turtle at 6:30; see below). Your walkers, the Commander's rockets, Shield (C) and Stim (Z) hold it.
6. **3:30** Set up a steel smelter that gets iron plates from another smelter by inserter; heavies need steel. Add a second lab and a feeder factory for gears or circuits.
7. **~4:00** First hub at the natural: the factory makes it, you walk the Commander to the natural ore and place the hub ghost next to it, and the Commander's robots build it (see above). Then extractors and smelters on the natural feeding the hub's stockpiles, *Export above* on the hub and a hauler to bring the plates home.
8. **By 6:00** Aim to have Supply I and one unlock (Heavy walkers or Raiders) done, and to mix units by counter. Walkers and drones need no research, and walkers are your default unit.
9. **6:00–10:00** Make advanced kits (cable, circuits and steel) for Artillery walkers, Laser turrets and Supply II, expand to the middle patches and contest the ruin.

**Winning.** A side is out when it has no CC, barracks or factory and no combat units left (haulers and the Commander do not count). You win when every AI is out and you are not. The results window lists every side's units and buildings built and lost; **Concede** in the F10 menu ends the match as a defeat, and the menu's **Results** button shows the window again after you closed it.

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

Easy opens with one iron and one copper smelter, and only half of its idle army defends. Hard runs the normal build order with time gates ×0.7, and its economic and turtle doctrines add a second barracks. The AI researches its unlocks like a player and its barracks obey the same locks.

## Nation mode

Nation mode turns a match into a small state. You found cities on a large generated world, claim the land around them, connect them by rail, ship goods between them and race the AI to Age II. Everything you know from Skirmish still works; Nation adds the layers below. Skirmish matches are unchanged.

**Starting a match.** In the lobby set **Mode** to *Nation*. The map type becomes *World* (greyed), and the size drop-down offers World 1536×1536, 2048×2048 or 3072×3072; the default follows the number of nations (2: 1536, 3 or 4: 2048). Every size is playable a few seconds after **Start match**, and the far terrain fills in while you play: about 1 minute on 1536, 1½ on 2048 and 4 on 3072. A Nation match is meant to run far longer than a skirmish.

**The world.** Mountain ranges (grey rock that no unit crosses) with passes, rivers with walkable fords, coasts, lakes, swamps, deserts and forests split the world into named regions. Every nation starts with the same ore within 150 tiles of its capital, laid out as in Skirmish; the richer deposits lie between the nations. Each nation has a home oil field about 300 tiles out, and a large contested oil swamp lies in the middle. Ruins (6 on a 1536 world) and ports (2) hold steel and circuits and are captured like the skirmish ruin. At the start only the land within 160 tiles of your capital is charted; the rest stays black until your units or buildings see it.

### Capital, cities and territory

**The capital.** Your starting CC is your capital: a *town* whose land reaches 96 tiles around it. The HUD adds an **age badge** left of the top strip, a **Land N%** button on the strip (your share of the map) and the **city list** at the top left: one row per city with a button that jumps the camera there and a magnifier that opens its panel. The Land button shows or hides the list.

**Founding a city.** The factory makes a **City charter** (80 iron, 30 copper, 40 stone, 20 s). Place it from the build menu's Production tab like a hub: at least 96 tiles from every other City Center of any nation, on your own or neutral land, never on enemy land, at most 4 cities per nation (capital included). New sites lie beyond your robots' reach, so walk the Commander next to the ghost; its robots build the City Center from your stock. A **City Center** has 1,800 HP, two stockpiles and its own logistic network (radius 16, 10 construction robots reaching 30 tiles, 6 logistic robots), 1 MW of power, and keeps 50 iron and 20 copper by default like a hub. An alert announces "City founded: <name>".

**Tiers.** A city grows from village to town to city. Every 10 s it counts your buildings on its land (walls and stockpiles excluded) and the goods delivered to its market (its logistic network) since it was founded.

| Tier | Land radius | Supply | Needs |
|---|---|---|---|
| Village | 48 tiles | 10 | founding |
| Town | 72 tiles | 20 | 10 buildings, 400 goods delivered |
| City | 96 tiles | 30 | 25 buildings, 2,000 goods delivered |

The capital claims 24 tiles more than its tier (96 as a town, 120 as a city) and keeps the CC's supply: 40 as a town, 50 as a city. Its centre heals back half of every hit, so it takes about twice the damage to fall. A city whose City Center dies or is demolished is lost with its land ("City lost: <name>"); a lost capital passes to your next city.

**Territory.** The map is divided into 8×8-tile cells, each owned by one nation or neutral. City Centers claim land by tier, forts 24 tiles, hubs and radars 16; where claims meet, the stronger claim wins, and an owner keeps a cell until a rival beats it by 15 %. Borders are dashed lines in the nation's colour on the ground, and solid lines with a tint on the map and the HUD minimap. They are public: you see the AI's land even where you have not explored. "Territory lost near <city> (N cells)" warns you when you lose land.

| What you build | Your land | Neutral land | Enemy land |
|---|---|---|---|
| Economy: extractor, smelter, factory, barracks, lab, solar array, steam plant, accumulator, Age II buildings and districts, Bunker | yes | no | no |
| Outposts: hub, rail depot, fort, turret, laser turret, radar | yes | yes | no |
| Infrastructure: belts, inserters, poles, walls, rails, stockpiles | yes | yes | no |
| City Center | if 96 tiles from every city | yes | no |

A refused ghost disappears with a flying text such as "Enemy land: nothing can be built here" or "Smelter can only be built on your own land". Buildings on land that changes hands keep working.

**Attrition.** Enemy units at least 16 tiles deep in your land lose 1.5 % of their health every 5 s (about 18 % a minute; the Commander half), unless an own City Center, capital, hub or fort stands within 24 tiles of them. Your armies suffer the same in enemy land.

**Forts** (factory: 30 iron, 20 stone, 6 s) are cheap machine-gun strongpoints: 600 HP, range 18, fed with magazines like a turret (20 come with a new fort). They claim 24 tiles, stand on neutral land and stop attrition for your units nearby, so they carry your land and your supply line forward.

### The city panel, make targets and the ledger

**The city panel** opens left of the stockpile panel when you select your CC or a City Center, or with the magnifier in the city list. It shows the name (a field to rename it), tier and land radius, your nation's age, the city's land cells and their share of your nation, its supply, what the next tier needs, the logistic networks on its land, the city's make targets, and a **Demolish** button (greyed for the capital). Demolishing a City Center (two presses, like any building) ends the city: its land goes, and half of the charter's cost returns to another stockpile of its network if there is one (a depot's, for example).

**Make targets** tell a city how many of a good to keep in stock. Add one with the item button under "Make targets" and type a number (empty clears it). In Nation mode a new factory or district starts on **Auto**: every second it switches to the good with the largest shortfall among its city's targets that its inputs allow, and stops when every target is met. Choosing a recipe or Pause in the building page fixes it; the **Auto** button (the circular arrows next to Pause) switches it back.

**The city ledger** (L, or a click on the age badge) shows one city at a time: a city drop-down, the age and the national project with its progress, then one row per good with its stock, made and used per minute, the make target (editable), the shortfall and a hint for a short good whose input is missing, such as "needs [plastic]: made in <city> (ship it here)" or "needs [crude oil]: made nowhere". Under the table you can add a target for any good. The footer counts the city's factories and districts on Auto and on a fixed recipe.

### Haulers in Nation mode

Haulers carry 10 slots instead of 20 (*Hauler capacity I* and *II* add 10 each) and burn coal: a hauler leaving a hub takes 1 coal per 40 tiles of the trip (×1.1, rounded up) from that hub's network. A hauler leaving for a pickup also fills its tank with the coal for the way back, so only the end a round trip starts from needs coal: for a route from an outpost to your capital, keep coal at the capital. A walk inside one network (a new hauler from its factory to its home hub) burns nothing. The hauler panel shows the tank after the cargo ("Tank: [coal] 4"). Without coal the hauler waits with "no coal for the trip in the hub network", and an alert "Hauler N: no fuel at <hub>" comes at most every 2 minutes per hauler. Beyond about 300 tiles, trains are the better carrier. In Nation mode every inserter also moves 3 items per swing instead of 1, so one inserter into a stockpile keeps up with several extractors.

### Rails

**Railways** (tier-1 research, 15 basic kits; Nation mode only) unlocks five factory recipes:

| Item | Cost |
|---|---|
| Rail depot | 40 iron, 10 steel, 10 copper (10 s) |
| Rails | 2 steel + 1 stone → 2 rails (2 s) |
| Locomotive kit | 40 iron, 10 steel, 10 circuits (10 s) |
| Cargo wagon kit | 20 iron, 5 steel (6 s) |
| Construction wagon kit | 30 iron, 10 steel (8 s) |

**Depots.** A rail depot (build menu, Economy tab) is a hub with a railway: 1,500 HP, logistic radius 14, construction radius 22, +10 supply, the same keep / export policy as a hub (it keeps 50 coal by default), and a 40-tile platform with a stop at each end that the game lays next to it (an alert says when there is no room). Select a depot to see its rail panel left of the stockpile panel: platform, kits, rails and coal in its network, its line and the force's line list.

**Laying a line.** Select a depot and right-click another of your depots. The game surveys a route in a few seconds (around water, buildings and foreign land), shows it as ghost rails, and sends a **construction train** (2 locomotive kits + 1 construction wagon kit, rails and coal from the first depot's network). It lays about 10 pieces per second, clears trees, rocks and cliffs on the way, and adds signals; the line reads *surveying*, *building*, then *open* ("Rail line open"). A line costs roughly 0.6 rails per tile of track; curves, signals and bridges cost more. In M1 each depot has one line.

**Freight trains.** **Deploy freight train** in the depot's rail panel assembles locomotive + 2 cargo wagons + locomotive (2 locomotive kits, 2 cargo wagon kits, at least 2 coal) on its platform. Click any carriage to select the train and open the train panel. Right-click a depot to set the pickup and Shift + right-click another to set the drop-off; the train then runs at about 30 tiles/s. It loads what the pickup network exports and the drop-off network keeps (a drop-off with no Keep takes every export), 200 items per second per wagon, 40 stacks a wagon, and refuels its locomotives to 20 coal at every stop. The panel shows the route, the state (with the reason when it waits), the cargo, the trips and what it delivered. Auto haulers leave a network to the train once a freight train runs from it to their home. A train that stands on a platform without coal takes coal from the depot as soon as some arrives.

**Cuts and repairs.** A destroyed rail of a line leaves a ghost, the line reads *cut*, and "Rail line cut" sounds. A construction train from the free side of the cut repairs it, so keep a crew's kits and rails at both ends; trains resume afterwards. Trains run over units on the track (haulers pass through), so keep armies off the line.

**Bridges** (tier-2 research, 20 advanced kits, Space Age only) let the planner cross water on elevated spans with supports.

### Ages

Today's game is **Age I**. *Industrialisation* (tier-2 research, 20 advanced kits) lets you **Start the Railway Charter** from the ledger: a 6×6 site next to the capital takes 100 steel, 100 circuits, 100 gears and 150 stone from the capital's network, at most 10 of each per second, shown as "Railway Charter N %" over the site and on the badge. When everything has arrived, a 20 s countdown runs, and your nation (only yours) enters **Age II**; your rivals get a chat line. A destroyed site loses half of its deliveries; start it again for the rest.

**Age II** brings:

- **The Mk2 line:** every unit of yours deals 25 % more damage and takes 1/1.4 of the damage it is hit by (the Mk2 numbers for every kind).
- **The Armoured car** (barracks): 2 engines, 2 steel beams and 10 iron (8 s); 800 HP, 30 % physical resistance, 1.6× a walker's speed, range 18, supply 3; strong against walkers and raiders, weak against heavies and artillery.
- **The Bunker:** a 3×3 gun emplacement on magazines with 3,000 HP, range 26 (beyond walkers) and about 2.4× a turret's damage; 8 steel beams, 20 concrete, 20 iron.
- **Oil as goods:** an oil well (30 iron, 5 steel, 5 circuits) on an oil field pumps crude into its network as crude oil items, so haulers and trains carry it and no pipe is needed. The refinery turns crude into petroleum, the chemical plant makes plastic and sulfur.
- **New goods** in the factory: engines, advanced circuits, steel beams, concrete and the industrial science kit (an engine, an advanced circuit and sulfur).
- **Research** with industrial kits: Supply III (+15), Mining III (+25 %), Hauler capacity II (+10 slots), Attack IV (+15 %).
- **Districts** (below) and the build menu's **Age II** tab (the icon tab after Defence).

**The army soft cap** (Nation mode): every 10 army units beyond 20 make Age I unit kits 10 % dearer. When a kit becomes a unit, the barracks takes that share of each kit ingredient (rounded up) from its network; while the network cannot pay, the kit waits and the barracks page shows "Army surcharge +N %: waiting for [item]". Haulers and the Commander do not count, and Age II kits pay nothing. The economy, not walker spam, is the road to a winning army.

### Districts

A district is one 5×5 building that runs a compressed production chain from its city's network, with about twice the output of the machines it replaces and more goods per raw plate. Each costs 80 iron, 40 stone and 15 circuits (the Science campus 40 copper and 25 circuits more), needs 400 kW and has 2,500 HP. The factory makes them on its Age II tab. Districts start on Auto; one without a target runs the first recipe it can feed.

| District | Recipes |
|---|---|
| Smelting works | 10 iron ore → 12 iron plates; 10 copper ore → 12 copper plates; 10 stone → 6 bricks |
| Steel works | 6 iron plates → 4 steel; 6 iron ore + 1 coal → 4 steel |
| Circuit works | 2 iron + 3 copper → 3 circuits; 5 copper → 15 cable |
| Electronics plant | 2 circuits + 2 plastic + 1 copper → 2 advanced circuits |
| Petrochemical works | 3 crude + 1 coal → 8 plastic + 2 sulfur; 2 crude → 10 sulfur |
| Engine works | 2 steel + 3 iron → 2 engines |
| Munitions works | 10 iron → 15 magazines; 4 coal + 2 iron → 4 explosives |
| Rail works | 4 steel + 2 stone → 8 rails; 3 steel → 4 steel beams |
| Construction works | 5 bricks + 2 stone → 10 concrete; 8 bricks → 10 walls |
| Science campus | 4 iron + 2 copper → 3 basic kits; 4 circuits + 2 steel → 3 advanced kits; 2 engines + 2 advanced circuits + 2 sulfur → 6 industrial kits |

### Divisions (both modes)

A **division** is a group of combat units that moves as one formation along one path. Select at least two combat units and press **Form division** in the division panel (top left, under the kill feed or the city list). Its card shows the name, strength (alive / target), a health bar, the current order and the stance. When the whole division is selected, the card adds the stances **Hold** (stand and return fire), **Advance** (attack enemies that come within 40 tiles) and **Screen** (fall back 20 tiles from enemies within 25), a **Reinforce** checkbox, rename and disband. A plain click or drag on any member selects the whole division; Shift + click adds single units. An order to the whole division is one group order; an order to some of its members detaches them until the next whole-division order. Control groups remember divisions. With a barracks selected, the panel's **Reinforces** drop-down sends its new units to a division while that division is below its strength target. The AI forms its attack groups into divisions too.

### What the AI does in Nation mode

The AI plays by the same rules. It mines coal once its iron core runs (haulers and trains need it; when no CC slot takes the coal belt, a coal hub next to the patch joins the CC's network) and puts two turrets towards the enemy. From 5:00 it founds a second city: a **mining town** next to an iron region patch 170–560 tiles from its capital (copper only when no iron is in reach), where six extractors feed two direct inserters (ore) and two smelters (plates) into the town's stockpiles. The town gets a depot at each end of a line, construction crews at both ends and a freight train that ships its ore and plates to the capital; while the line waits for its depots, kits and rails the barracks save plates (never below 20 army units). The AI pays depots, kits and rails straight from its capital's plates (circuits, gears and steel as the plates they are made of), but never takes the capital below a small reserve. It researches Industrialisation as soon as it can make advanced kits, runs the Railway Charter, and in Age II builds districts (Steel works, four Smelting works for the town's ore, Engine works, Rail works), a warehouse of six stockpiles where it stores the town's ore and plates, two Bunkers once a Smelting works makes bricks, and adds Armoured cars to its army. It stops making Age I units beyond 40 army units unless its base is threatened, and saves for district items instead, but never lets its army fall below 20 for the Charter, its town or a district. In Age I it attacks nothing farther than 500 tiles from its capital (raids go on); a share of its idle army (40 %, 10 to 16 units) stays home as a guard, an attack needs 1.2 times the enemy army it last saw, no attack leaves while its capital is under attack, and a heavy attack on the capital calls the nearest attack group back.

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
- `tools/probes/*.lua` are test-only modules: `EXTRA_LUA=tools/probes/wavec_headless.lua` (a hub at the natural built by the Commander, hauler cargo between two networks, Concede) and `commander_field.lua` (Commander field construction) run headless through `tools/autotest-run.sh`; `menu_gui.lua` drives the F10 menu, Concede and Results in a GUI client; `m1_docs_gui.lua` walks a GUI client through the Nation panels of the Phase 5 M1 protocol and saves the screenshots its coordinates come from.
- Admin console: `/rts-match` (add `nation [1536|2048|3072]` for a Nation match), `/rts-give <item> [n]` (into your CC's network), `/rts-spawn <unit> <count> [force]`, `/rts-research <technology>` (finish an RTS technology at once, e.g. `rts-railways`), `/rts-age [force] [age]` (show or set a nation's age), `/rts-world`, `/rts-dump`, `/rts-mapgen`, `/rts-ai-doctrine`, `/rts-qa-reset`, `/rts-qa-end`. The GUI QA protocols use a few of them as shortcuts, and a tester ends a session by typing `RTS_QA_END` in the console.
- Interactive QA protocols and results are in `docs/qa/` (`phase1-protocol.md` to `phase4-protocol.md`, and `phase5-m1-protocol.md` for a Nation match). Mod layout, storage schema and module contracts are in `docs/PHASE1.md` to `docs/PHASE4.md` and `docs/PHASE5-M1.md`; per-module notes are in `docs/qa/*-notes.md`.
