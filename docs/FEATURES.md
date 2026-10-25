# Factorio RTS: complete feature list

Every feature of version 0.1.1, by area. Each line starts with the milestone that introduced it:

| Tag | Milestone | Tag | Milestone |
|---|---|---|---|
| `P0` | Phase 0: feasibility spikes | `M1` | Phase 5 M1: "Two cities and a railway" |
| `P1` | Phase 1: control vertical slice | `M2` | Phase 5 M2: "People, money and war goals" |
| `P2` | Phase 2: economy slice | `M3` | Phase 5 M3: "A state at war" |
| `P3` | Phase 3: AI opponent and match flow | `2.1` | The port to Factorio 2.1 |
| `P4` | Phase 4: a real RTS with a Factorio economy | `0.1.1` | The first update after the public release |

Phases 1 to 4 built the Skirmish game; M1 to M3 built Nation mode on top of it. The player guide is the [README](../README.md); the design is in [DESIGN.md](DESIGN.md) and [SCALE-VISION.md](SCALE-VISION.md).

## Modes and match flow

- `P3` A lobby opens when you join a Freeplay game and starts a match with the chosen settings.
- `P3` Skirmish matches are free-for-all against 1 to 3 AI commanders on their own arena surface.
- `P3` Every side starts with the same Command Center (CC), stock and walkers, and human players also get a Commander.
- `P3` A side is out when it has no CC, barracks or factory and no combat units, and the last side standing wins.
- `P3` A results window lists every side's units and buildings built and lost.
- `P3` The F10 match menu resumes, restarts the match with the same settings or returns to the lobby.
- `P4` Concede in the F10 menu ends the match as a defeat after two clicks, and Results shows the window again after the match.
- `M1` The lobby's Mode drop-down chooses between Skirmish and Nation.
- `M1` Nation is a long match (one to three hours) on a generated world, designed to be saved and resumed.
- `M2` The Nation lobby sets the victory mode (Conquest + Space, Conquest, Territory, Score or Any) and a time limit of 60, 90 or 120 minutes or none.
- `M3` The Nation lobby offers 2 to 6 nations, worlds of 2048, 3072 or 4096 tiles and a start map of Explore or Survey, and says how long the world takes to generate.
- `P3` In a multiplayer game only an admin can change the lobby.

## Camera and controls

- `P0` The player commands from the remote view with no character, and the RTS cursor tool stays in the cursor.
- `P1` WASD pans and the mouse wheel zooms, and Space jumps the camera to your CC.
- `P1` A left click selects a unit and a left drag box-selects units, with Shift adding to the selection.
- `P1` A right click moves the selection or attacks the enemy under the cursor.
- `P1` F then a right click, or Shift and a right click, gives an attack-move.
- `P1` X stops and H holds position.
- `P1` Ctrl+1..5 assigns a control group, 1..5 recalls it and a double tap moves the camera to it.
- `P1` A click on the minimap moves the camera there.
- `P1` Selected units show selection boxes drawn only for their owner.
- `P1` F1 gives the RTS cursor back, and every Ctrl chord also works with Cmd on macOS.
- `P1` Every key is rebindable under Settings → Controls.
- `P2` B shows the build menu, a left click places a ghost, R and Shift+R rotate it and Q or a right click stops placing.
- `P2` A right click with a barracks selected sets its rally point.
- `P4` Ctrl+A selects the whole army (every combat unit and the Commander, not the haulers).
- `P4` A click on a unit card keeps only that unit type, and Shift and a click drops it.
- `P4` A right click on a hub or CC with haulers selected sets their pickup, and Shift and a right click their drop-off.
- `P4` A left click with no unit under the cursor selects your own building.
- `M1` Delete or Backspace (two presses within 3 s) demolishes the selected own building with a 50 % refund, in both modes.
- `M1` A left click on any carriage selects a train.
- `M2` Delete with units selected disbands them in Nation mode, and their recruits go home.
- `M3` H with whole divisions selected and the cursor at a front makes them hold that front.
- `0.1.1` Escape opens the game menu (save, load, settings, exit) and closes an open RTS panel first, without leaving the remote view.
- `0.1.1` A right click on a pentapod's leg attacks the pentapod.

## HUD and feedback

- `P1` The HUD has a minimap and a selection panel.
- `P2` A resource strip shows plates, circuits, steel and power headroom.
- `P2` A building panel shows the recipe choice, progress and rally point of the selected building.
- `P4` The build menu has tabs with research gating and tells why a building is locked.
- `P4` Unit cards group the selection by type with health.
- `P4` Alerts announce attacks, losses and depleted patches, and F3 jumps to the newest one and then to older ones.
- `P4` A kill feed shows who killed what.
- `P4` F11 opens How to play.
- `M1` The Nation HUD adds an age badge, a Land N% button and a city list with camera and panel buttons per city.
- `M1` Depots, trains and cities have their own panels left of the stockpile panel.
- `M2` The Nation help page lists every Nation rule and hotkey in a scroll pane.
- `M2` The city list marks a city under attack, and its panel shows a red line with a Jump button.
- `M3` Depots are labelled on the map with their panel names.
- `M3` "World: N % generated" under the minimap shows the background world generation.
- `M3` The kill feed names a building killer, such as the AA turret that shot a plane down.
- `0.1.1` Guided objectives show seven first steps for a first Skirmish and a first Nation match, with a switch in the lobby.
- `0.1.1` The stockpile panel colours a count against the selected hub's own Keep and names the network's levels in the tooltip.

## Units and abilities

- `P1` The walker is a ranged spider-unit and the default unit.
- `P4` Five combat units form a counter wheel: the walker, drone, heavy walker, raider and artillery walker.
- `P4` The drone is a fast melee swarm whose bites ignore heavy armour and deal triple damage to raiders.
- `P4` The heavy walker is a tank with 60 % physical armour and splash damage.
- `P4` The raider deals 2.5 times damage to economy buildings, poles, hubs and haulers.
- `P4` The artillery walker fires area shells up to 44 tiles away and wrecks heavies.
- `P4` Armor I makes the barracks deploy Walker Mk2 and Heavy Mk2 (+40 % health, +25 % damage) from the same kits.
- `P4` The Commander is a hero with rockets who levels up at 5 and 15 kills and respawns at the CC 60 s after dying.
- `P4` The Commander's personal roboport builds ghosts within 15 tiles, stocked from the CC's pool, so it builds outposts beyond robot reach.
- `P4` Five abilities have per-side cooldowns: Stim, Shield, Scanner sweep, Artillery strike and Overcharge.
- `P4` With Space Age, units use the Gleba pentapod graphics; without it they are built from the spidertron, and drones use biter graphics.
- `M1` In Age II every unit gets the Mk2 line (+25 % damage, takes 1/1.4 of the damage).
- `M1` The Armoured car is a fast Age II unit with 800 HP, strong against walkers and raiders.
- `M3` Planes fly over water, mountains and walls: the scout plane, the bomber and the interceptor.
- `M3` Uranium rounds give heavy walkers +30 % damage while the capital supplies one magazine per heavy a minute.

## Divisions (both modes)

- `M1` Two or more combat units form a division that moves as one formation along one path.
- `M1` A division card shows the name, strength, health, current order and stance.
- `M1` Stances are Hold, Advance (attack within 40 tiles) and Screen (fall back from enemies within 25).
- `M1` A barracks can reinforce a division until it reaches its strength target.
- `M1` An order queue caps pathfinding at 100 units and 4 groups per tick, so a large army's order never stalls the game.
- `M1` Control groups remember divisions, and an order to part of a division detaches those units until the next whole-division order.
- `M1` The AI forms its attack groups into divisions too.
- `M3` Divisions finish attacks on buildings and can hold a front along its whole length.

## Economy

- `P2` The CC is a roboport composite with robots, stockpiles and a 4 MW power core.
- `P2` Everything is built as a ghost by construction robots from items in the logistic network.
- `P2` Extractors mine finite ore patches, smelters make plates, bricks and steel, and inserters move the output into stockpiles.
- `P2` The factory repeats a chosen recipe and sends its output to the network.
- `P2` The barracks turns plates into unit kits, and each finished kit walks out to the rally point.
- `P2` Barracks, factories, labs and turrets pull their inputs from the network they stand in.
- `P2` Power comes from the CC core and solar arrays, and low power slows every machine.
- `P4` Labs, hubs, laser turrets, walls, steam plants, accumulators and radars complete the building set.
- `P4` The factory makes intermediates: gears, cable, circuits, explosives and magazines.
- `P4` A supply cap of 40 grows with hubs and research, and units cost 1 to 4 supply.
- `P4` Patches deplete, and a natural pair, middle patches and a ruin wait further out.
- `M1` In Nation mode every inserter moves 3 items per swing.
- `M1` In Nation mode every 10 army units beyond 20 make Age I unit kits 10 % dearer (the army soft cap).
- `M1` Make targets tell a city how much of a good to keep, and new factories and districts run on Auto to fill the largest shortfall.
- `M1` The city ledger (L) shows stock, production, use, targets, shortfalls and hints for every good of a city.

## Hubs and haulers

- `P4` Hubs are forward bases with their own logistic network, robots, two stockpiles and a 300 kW generator.
- `P4` Hubs whose logistic areas touch share one network.
- `P4` Each hub and CC has a stockpile policy of Keep N and Export above N per item.
- `P4` Haulers carry items between separate networks, either in auto mode for their home's Keep amounts or on a manual route.
- `P4` Haulers follow land routes from the pathfinder and recover from stalls.
- `P4` Raiders and drones hunt haulers, and each loss raises an alert.
- `M1` In Nation mode haulers carry 10 slots and burn 1 coal per 40 tiles, so trains win beyond about 300 tiles.
- `M1` A hauler fills its tank for the way back too, so one end of a route with coal is enough.
- `M3` A route hauler waits at its pickup until both legs are in its tank when the drop-off holds too little coal.
- `0.1.1` A hauler bound for a stop that may lack coal pays its way back before it leaves, from its tank, its network or the destination's, so it does not strand there without coal.
- `0.1.1` An auto hauler waits at home for up to a minute for a load worth the trip's coal.
- `0.1.1` The map shows the selected haulers' routes while the hauler panel is open, and the engine's own hauler lines are drawn at their thinnest.

## Research

- `P4` Labs consume basic and advanced science kits, and more labs research faster.
- `P4` Skirmish has 19 technologies: Supply I-II, Attack I-III, Armor I-III, Mining I-II, Logistics I, Hauler capacity I, Heavy walkers, Raiders, Artillery walkers, Laser turrets, Steam power, Overcharge and Scanner sweep.
- `M1` Nation adds Railways, Bridges (Space Age), Industrialisation and the Age II research Supply III, Mining III, Hauler capacity II and Attack IV.
- `M1` The industrial science kit (an engine, an advanced circuit and sulfur) feeds the Age II research.
- `M2` Nation adds Commerce I-II and Geology.
- `M3` Nation adds Fortification, Military railways, Aviation, Air Force, Electrification, Chemistry and Nuclear power.
- `M3` Rush runs the current research at twice the lab speed for crowns while a lab works.

## Skirmish maps

- `P2` Ore patches are placed by script, with iron, copper, stone and coal near each spawn and contested patches in the middle.
- `P3` Fog of war per side: you see only what your units and buildings see.
- `P4` Map sizes are small (256×256), medium (384×384) and large (512×512).
- `P4` Chokepoints puts a water moat with one land gap in front of every base, plus lakes and forests; Open field is flat grass.
- `P4` A ruin in the middle holds steel and circuits and is captured by standing next to it.
- `P4` A reachability flood fill guarantees every base can reach every other.

## Nation: the world

- `M1` The world is a planned skeleton over the engine's terrain, with mountain ranges no unit crosses, passes and rivers with walkable fords.
- `M1` Spawns are scored for fairness, and every nation starts with the same ore near its capital.
- `M1` Oil fields supply the crude for Age II.
- `M2` The world is split into named regions (highland, plain, lakeland, coast, swamp, desert, forest, mountain) shown on the map and in alerts.
- `M2` A scarcity portfolio gives every nation a home specialty and a home oil field, and leaves the large deposits and a contested oil swamp between nations, so every nation lacks something.
- `M2` City-states (neutral cities with growing turret garrisons) sit on scarce sites.
- `M2` Trade ports, ruins and named chokes (passes, fords, narrows) are placed fairly by path.
- `M2` Uranium deposits on contested ground are mined only after Geology.
- `M2` Rare deposits (saltpetre, quartz, tungsten, diamonds, rare earths, gold) lie on desert and mountain rims and city-state land.
- `M2` The strategic map shows regions, borders, chokes, cities and ports at far zoom, and N switches the minimap between the region and the whole world.
- `M3` Worlds of 2048, 3072 and 4096 tiles hold 2 to 6 nations, with more city-states, ports, ruins and rare deposits on larger worlds.
- `M3` The land around every capital, city-state and port is generated first, and the rest fills in the background while you play.
- `M3` Survey charts the generated world as it appears, and Explore charts only the land around your capital.

## Nation: cities and territory

- `M1` Your starting CC is your capital, and a City charter founds up to three more cities at least 96 tiles from every City Center.
- `M2` Founding moves 40 settlers from your nearest city that can spare them.
- `M1` A City Center has its own logistic network, robots, two stockpiles and 1 MW of power.
- `M1` Cities grow from village to town to city, which raises their land radius and supply.
- `M1` The capital claims more land, keeps the CC's supply and heals back half of every hit.
- `M1` The map is an 8×8-tile ownership grid, with claims by City Centers, forts, hubs and radars and a 15 % margin to take a cell.
- `M1` Borders are drawn on the ground, on the map and on the minimap, and they are public.
- `M1` Build rules limit economy buildings to your own land, let outposts and infrastructure go on neutral land and forbid enemy land.
- `M1` Enemy units deep in your land lose about 18 % of their health a minute (attrition) unless an own centre, hub or fort is near.
- `M1` Forts are cheap machine-gun strongpoints that claim land and stop attrition for your units.
- `M1` The city panel shows the city's tier, land, supply, networks and make targets, and renames or demolishes it.

## Nation: rails and trains

- `M1` Rail depots are hubs with a platform, and Railways unlocks rails, locomotive, cargo wagon and construction wagon kits.
- `M1` Selecting a depot and right-clicking another surveys a route around water, buildings and foreign land and shows it as ghost rails.
- `M1` A construction train lays about 10 pieces a second, clears trees, rocks and cliffs, and adds signals.
- `M1` Bridges (Space Age) let a line cross water on elevated spans.
- `M1` Freight trains load what the pickup exports and the drop-off keeps, and refuel at every stop.
- `M1` A destroyed rail leaves a ghost, the line is cut, and a construction train from the free side repairs it.
- `M1` Auto haulers leave a network to the train once a freight train serves it.
- `M2` Troop trains carry units between depots, and a destroyed troop wagon kills its passengers.
- `M2` Disband in the train panel turns a standing train back into half of its kits.
- `M2` A line whose depot is captured comes back when you retake the city, and its trains take their route up again.
- `M2` Attack-moves spare rails, signals and poles, while raiders and right-click attacks still cut them.
- `M3` A line crosses your own walls through gates, and a blocked piece makes the crew survey a short detour after two minutes.
- `M3` Artillery trains bombard hostile buildings within 120 tiles that your units, planes, radars, land or held fronts see.
- `M3` Armoured locomotives and wagons have 3 times the health and 40 % resistance, for artillery and troop trains.
- `M3` A greyed Deploy button lists in a yellow line what a train is missing.

## Nation: ages, districts and goods

- `M1` Industrialisation unlocks the Railway Charter, a national project next to the capital whose deliveries bring Age II.
- `M1` Age II brings oil as goods (oil wells, refinery, chemical plant), engines, advanced circuits, steel beams and concrete.
- `M1` The Bunker is an Age II gun emplacement with 3,000 HP and range 26.
- `M1` Ten districts run compressed production chains at about twice the output of the machines they replace.
- `M1` The Rail works district comes with Railways already in Age I.
- `M2` Supply crates for divisions are a factory recipe.
- `M3` Electrification unlocks the Space Program, an 8×8 launch complex with three stages of deliveries.
- `M3` Stage 1 of the Space Program brings Age III, and the launch after stage 3 wins under Conquest + Space and Any.
- `M3` Age III brings the Chemistry district, the Electronics II plant, the Concrete works and, with Nuclear power, the 40 MW Nuclear plant.
- `M3` Automation kits in a family's districts cut their jobs by 30 % at the same output and free people for the army and the labs.
- `M3` Rush speeds a national project's deliveries and countdown for crowns.

## Nation: people and labor

- `M2` Every city has residents who need housing, rations and, from town tier, household goods.
- `M2` Houses and Age II apartments add housing on the city's land.
- `M2` Farms, bakeries and fishing huts make rations, and the factory makes household goods.
- `M2` With Space Age rations spoil after 15 minutes.
- `M2` Cities grow when their needs are met and lose people when they starve.
- `M2` Happiness follows food, goods, power, crowding, taxes and debt, and drives growth and taxes.
- `M2` 60 % of residents work, and buildings take their workers from the city whose land they stand on.
- `M2` Hidden labor modules throttle a partly staffed building, and one with no workers stops.
- `M2` Labor priorities order nine families of jobs, and Pin serves one building first.
- `M2` Every unit takes recruits from its barracks' city, from the unemployed and a draft share of the employed.
- `M2` The city panel adds residents, housing, happiness, needs, the workforce, the draft and the priorities.

## Nation: treasury, market and trade

- `M2` Every nation has a treasury in crowns that pays upkeep, soldiers and imports and earns taxes and exports; nothing is built with money.
- `M2` Three tax levels scale income by residents and happiness.
- `M2` Debt has three recoverable stages: imports stop, wages go unpaid, then unrest.
- `M2` Trade ports are captured like ruins and connect you to a shared world market.
- `M2` Prices follow a shared world stock, so every nation's sales move them.
- `M2` A commerce cap limits trade per minute and grows with ports held and Commerce research.
- `M2` Contracts between nations sell goods at a fixed price per delivery.
- `M2` The market panel (M) shows prices with sparklines, the port's stock, sell and buy, the tax level and the debt stage.
- `M3` Hire adds decaying garrison points to a city for crowns.
- `M3` Mercenaries buy a small division at your port once every 10 minutes.
- `M3` City-states trade their region's goods at 1.3 times the market price, falling with relation, and buy any good at 0.7 times.
- `M3` Tax and deficit changes have a hysteresis band, and the credit line follows a falling income slowly.

## Nation: diplomacy, wars and victory

- `M2` Two nations are at war, ceasefire, peace or alliance, and city-states are at war with everyone.
- `M2` Opinions move with trade, contracts, common enemies, border pressure, attacks and gifts.
- `M2` A war has a goal (nearest city, capital or tribute) and ends in a treaty when the goal is met, by weariness or after 45 minutes.
- `M2` The diplomacy panel (F4) declares war, proposes ceasefire, peace and alliance, sends gifts and offers contracts.
- `M2` AI proposals arrive as alerts with Accept and Decline.
- `M2` Attack orders on a nation you are not at war with are refused.
- `M2` Conquest wins by holding every rival's first capital or knocking every rival out.
- `M2` Territory wins by holding 45 % of the claimable land, or twice the next nation's, for 3 minutes.
- `M2` Score wins at the time limit by residents, treasury, land and army.
- `M2` Allies share a victory.
- `M3` Capturing a city-state while at peace with everyone costs relation with every other nation.

## Nation: war

- `M2` Divisions burn supply on the march and in combat and refill from supply crates near your centres, hubs, depots and field depots.
- `M2` A division out of supply loses health and refuses attack orders.
- `M2` Cities are captured, not destroyed: a subdued City Center flips to the attacker after 20 uncontested seconds, with its land, buildings and 70 % of its people.
- `M2` The loser's capital moves to its largest remaining city, and a nation with no city left is out.
- `M2` Units garrison a city and man hidden guns around its centre, and the garrison sorties by itself when the centre is in danger.
- `M2` In Nation mode attack-moves fight what can fight back and spare belts, inserters and plain buildings around a fight.
- `M3` In a war the shared border is cut into fronts of 128 to 192 tiles, drawn on the map and in the game view with their threat.
- `M3` The fort belt tool lays a wall with gates, turrets, AA turrets and a field depot along 2 to 6 points, built by a crew from your nearest city.
- `M3` Fort belt turrets shoot artillery and heavies first.
- `M3` Airfields make and refuel planes, which return home on low supply and crash when it runs out.
- `M3` The air panel (Y) lists airfields and planes and orders Patrol and Return to airfield.
- `M3` AA turrets shoot only planes, and gun and laser turrets cannot hit them.

## Nation: rare resources

- `M3` The Rare extractor works a rare deposit at one item every 10 s.
- `M3` While a rare item reached the capital's network in the last 90 s, the whole nation has its bonus, from +25 % explosives to +15 % tax.
- `M3` The ledger lists active bonuses with the seconds left, and alerts say when one is gained or lost.

## AI and difficulty

- `P3` AI commanders build real bases from build orders through ghosts and the same production as the player.
- `P3` The AI's army defends, scouts and attacks the nearest known enemy building.
- `P3` Three difficulties change build pace, attack timing and size, and vision.
- `P4` Each Skirmish AI draws an economic, aggressive or turtle doctrine from the map seed, the match number and its own number.
- `P4` The AI researches, builds hubs with haulers, mixes its army by counter and raids haulers and outlying buildings.
- `P3` Hard Skirmish AIs get +50 % starting stock, a production bonus (today +25 % mining and every fourth unit free) and map-wide vision.
- `M1` The Nation AI founds a mining town, links it by rail, runs the Railway Charter and builds districts and Bunkers in Age II.
- `M2` A nation strategist sets taxes, sells at its ports, signs contracts and makes war and peace by its doctrine.
- `M2` A governor per city keeps food and goods, builds farms and houses, sets the draft and the labor priorities, and runs supply haulers.
- `M2` The AI runs capture operations for its war goals and takes city-states.
- `M3` An economic planner scores city sites, founds a third and fourth city, links its cities by a rail trunk and takes the road to Age III.
- `M3` A war council holds threatened fronts, lays fort belts, runs operations with phases and timeouts, flies patrols and sends bombers and artillery trains to sieges.
- `M3` Division controllers retreat when outnumbered and go back for supply.
- `0.1.1` The planner runs a concrete chain, an engine focus and a science hold so the AI reaches Age III sooner.
- `0.1.1` At war the council lays siege railways for artillery trains, patrols the capital with interceptors, sends bombers and researches war technologies first.
- `0.1.1` In debt the AI retires idle units and stops recruiting while it loses money.
- `0.1.1` A depot an AI line lost in a war is rebuilt on its old site and the line bound to it again.
- `0.1.1` An AI freight train carries everything its town offers.
- `M3` An intelligence layer knows only what the AI's units see.
- `M3` In Nation mode difficulty changes the freshness of intelligence, the number of operations, the build pace and the division handling, and never resources.
- `0.1.1` Hard plans more housing and goes for a second city-state, which makes it beat normal by skill.
- `M3` All AI work runs on a deterministic work-unit scheduler with resumable jobs, at about 0.07 ms per nation per tick.

## Multiplayer, determinism and performance

- `P1` Every RTS force keeps the engine's AI control off, so no engine expansion or unit-group behaviour interferes.
- `M2` Matches save and load at any point, with acceptance checks at minutes 20 and 40.
- `P3` Every human player joins the player's side, so multiplayer is cooperative against the AI.
- `M3` The simulation is deterministic across a server and its clients, checked with state checksums on every peer.
- `M3` Decisions read no client-side chart state, wall clock or game speed, and loops never depend on table order that a reload rebuilds.
- `M3` The budget scene of 4 nations, 16 cities, 600 units and 40 trains runs at 60 UPS on the development Mac.
- `M3` World generation, rail surveys and AI planners are sliced across ticks so no single tick stalls.
- `2.1` The mod runs on Factorio 2.1 with the 2.0 unit steering restored on every RTS unit.
- `0.1.1` Nation-mode periodic handlers run on phases of their own, so their work no longer piles onto the same tick.
- `0.1.1` RTS buildings that looked alike on Factorio 2.1's art have distinct tints.

## Localisation

- `P2` Every text is translated to English and Russian.
- `0.1.1` The Russian text follows one glossary and the game's own Russian item names.

## Development and QA tooling

- `P0` Headless runs use a dedicated server with an isolated write directory per run.
- `P1` A headless autotest plays a match and logs `[rts]` checks with PASS or FAIL.
- `P4` A scenario runner, a validation matrix, seeded balance batches, a save/load check and an equal-cost fight simulator test the Skirmish game.
- `P0` A GUI launcher with an isolated config per run lets an automated computer-use tester run the GUI QA protocols.
- `M1` Nation acceptance fixtures measure each milestone's contract numbers on fixed seeds.
- `M2` A GUI driver replays real clicks and keys from a probe's log.
- `M3` Performance benches, a determinism comparison, heavy mode and a LAN check with two GUI clients guard the multiplayer and performance budget.
- `M3` Every runner refuses to start when the game version does not match the mod's `factorio_version`.
- `M3` A matrix comparison proves Skirmish stays line-identical after Nation changes.
- `0.1.1` A Docker check runs the headless autotests on the official Linux build for x86-64 and ARM64.
- `0.1.1` One command runs a release's whole headless acceptance and writes a report.
