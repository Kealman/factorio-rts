# Changelog

The mod's version stayed 0.1.0 through development, so everything up to the public release is in the 0.1.0 section. Development ran in milestones; each milestone's contract is in `docs/PHASE*.md`, and its acceptance results and open issues are in `docs/qa/`. Git tags mark the milestone ends.

## 0.1.2

Factorio 2.1, Space Age optional. The update that follows the first real 0.1.1 game: it makes your own building, demolition and logistics understandable and controllable, and gives railways back to the player. Skirmish plays as in 0.1.1: all ten scenarios of the Skirmish test matrix log the same lines as 0.1.1 on every agent branch. Old saves: 0.1.1 saves load, with the changes named under Saves. The AI pace items (#2, #20) and Windows (#15) follow in 0.1.3. Issue numbers refer to [the issue tracker](https://github.com/Kealman/factorio-rts/issues).

### Production and building

- **Craft queue (#22).** The factory's and the barracks' recipe buttons order crafts like vanilla handcrafting: click = 1, Shift = 5, Ctrl = as many as the network (plus the machine's input) can pay, right click takes crafts off the order (Shift 5, Ctrl all). The ordered recipe's button shows the crafts left, the status line reads "Extractor: running (221 / 223 left)", and a finished order stops the machine; an order that overrode Auto hands the machine back to Auto. A new **Endless** toggle in the recipe grid brings back the old endless production. The AI's machines keep endless production.
- **Demolish pieces (#23).** Belts, underground belts, splitters, inserters and medium poles can be selected with a click or with a box that holds no unit (Shift adds), and demolished with Delete or the Demolish button: two presses, half the recipe back, rounded down per batch (10 belts give 5 iron plates, a lone belt gives nothing, and the flying text says so). Items on a belt or in an inserter's hand go to the network's stockpile. The building page shows the piece (direction, the inserter's From / To, items on the belt) and a Rotate button.
- **Cancel ghosts (#27).** Placed ghosts can be selected (click or box) and cancelled at once with Delete, Backspace or the Cancel button. Only your own ghosts count; enemy and neutral entities never do.
- **New logistics items (#25).** The factory crafts underground belts (10 iron + 5 belts, 2 pieces), splitters (10 iron + 5 copper + 4 belts) and, in Nation mode only, long-handed inserters (15 iron + 5 copper, 5 pieces); the economy build menu has all three. The Skirmish factory page has no room for a third row, so the long inserter stays out of Skirmish.
- **Clear trees and rocks (#24).** Right click a tree or rock with units selected, or Shift + right-drag (at least 3 tiles) over an area, and the units walk there and fell them. In the test 4 walkers cleared a 20-tree patch in 6.5 s. Rocks pay their stone and coal to the nearest stockpile. A ghost you place marks the trees and rocks under it for deconstruction, so the construction robots clear the site themselves. Units that belong to a moving division and haulers are left alone.
- **Supply haulers (#21).** Your own supply routes (a hub to a hub that keeps stock levels) wait for a fuller load of rations, goods and magazines while the town holds at least half its Keep, 4 minutes at most; below half they leave at once, and fuel, building and export routes never wait. This cuts hauler coal on small deliveries. AI nations are unchanged.

### Nation: cities and oil

- **A new city's stock (#26).** The settlers of a new city bring raw goods (iron 100, copper 40, stone 40, coal 20), a factory, two houses and a farm from the mother city's network, as far as it holds them: nothing is created, and the log says what moved and what was short. When the city's robots have nothing to build with, its hub and city panels say "N ghosts waiting: nothing to build them with ([item] missing in this network)" and an alert says so at most every five minutes. The AI's cities are unchanged.
- **Oil without pipes (#28).** The refinery and chemical plant pages and the pumpjack panel say that oil travels through the network as items: the pumpjack shows its output per minute, or "no network" in red when it stands outside every hub and city area, with an alert. The build tooltips have a "No pipes" note, F11 has an Oil paragraph, and R on a refinery says why it cannot rotate. The pumpjack's pipe pictures and covers are removed; the vanilla sprites keep their baked pipe stub, which needs new art.
- **Recipe names (#29).** Ten recipes (oil processing, plastic, sulfur, engine, advanced circuit, concrete, processing unit, battery, rocket fuel, light-oil barrel) showed "Unknown key: recipe-name.…" in the refinery's and the factory's pages on Factorio 2.1. Every recipe now has an explicit English and Russian name.

### Help and interface

- **Help cards (#30).** Hold Shift over a building, unit or ghost (the card shows about 0.3 s after the press), or press Shift+F11, for a card: what it is, how it works, the numbers generated from the game's own balance (cost, health, power, ranges, workers, recipes), what it takes and makes, what it needs and a tip. 85 entries cover every visible RTS entity. A **?** button on the building page, the hub and depot panel and the city panel opens the same card, pinned. Build tooltips show a one-line description under the name. A hover card closes with a click, after 20 s or on the next Shift press (the engine does not report a key release). English and Russian.
- **Objectives log (#19).** The objectives of the other mode no longer mark steps or log "step done" in a match (log only).

### Railways (#31, #32)

- **Stop lists (#31, part B).** Right click a depot or station with a train selected to add it as the last stop (Shift: insert after the selected stop); troop and artillery trains also take a rail. Each stop has its own orders: unload to Keep, everything or chosen items; load exports or chosen items; troops board or get off; Bombard here; and the engine's wait conditions (cargo idle 10 s by default, full, empty, a time, an item count). The train runs its list as a native engine schedule and loops by itself, A to B to C to B and on. The train panel shows the stops, the state ("Stop 3 of 4: Depot 2, loading ...") and an editor per stop. The AI's trains keep their two script-driven records.
- **Train builder (#32).** The depot panel composes a train carriage by carriage from the depot network's kits, with presets (Freight, Construction, Troop, Artillery, armoured and mixed trains) and up to 5 saved templates. The panel names what is missing and refuses what cannot run (the front must be a locomotive facing forwards, the train must fit the platform). **Platform of new depots** lays 40, 60 or 80 tiles (5, 8 or 11 carriages). A standing train couples a carriage at the rear or takes the rear one off at its depot (half the kit back). Cargo wagons follow the stop policies, troop wagons board and unload, artillery wagons bombard, in one mixed train.
- **The Rail tool and your own track (#31, part A).** The vanilla rail planner does not run in the RTS view, so the Economy tab has a Rail tool: click waypoints (the first on one of your rails for a branch, or on free ground), each further click plans a segment with curves and diagonals and shows its bill; right click or Backspace undo the last segment; Q or Done end the tool. Robots build the ghosts their networks cover, and a construction train from your nearest connected depot lays the rest, one crew at a time. Track nothing reaches raises "Track not built: ..." after a minute.
- **Signals and stations (#31).** Your track is single and runs both ways, so it gets chain signals only (a pair every 80 tiles and around each junction): a train enters a stretch only when its way is free, so two trains never meet head-on. Rail signals and chain signals are in the build menu. The **rail station** (20 iron, 4 steel, 4 copper) is a small depot without a platform: it puts two stops on your track within 8 tiles and takes no supply.
- **Auto lines on your track (#31).** The survey of a depot-to-depot line runs along your own track where it leads the right way (those pieces cost nothing), and a depot takes any number of lines. In the fixture the lines reused 98 % and 100 % of their pieces. The AI's lines are unchanged.
- **Limits.** On single track two trains that each want the platform the other holds wait for each other; after a minute the train panel says "single track needs a passing loop or a second track (Rail tool)". Junctions turn one way, as in vanilla: a branch entered from the other side needs a second segment. Both are in the README's rail section.

### Saves from 0.1.1

- 0.1.1 saves load. The train routes you set (pickup and drop-off) become two-stop lists: the pickup loads exports (troop trains board), the drop-off unloads to Keep (troops get off), with the wait "cargo idle 10 s". The Station and the signals are unlocked for nations that already had Railways. New storage is created lazily and nothing else is reset. The owner's Age II save loaded and played 130 s with 0 Lua errors.

### Tested

- The Skirmish smoke test passes 65/65 with 0 errors, and the Skirmish matrix is line-identical to 0.1.1 on the build, UX and Rails branches (0 differing lines in 10 scenarios; the orders branch ran 11 scenarios). On the UX branch the M1 test seed 501 gives 51/53 and 19,101 train items, as in 0.1.1, so the AI's own side is unchanged. GUI probes ran in English and Russian for the craft queue, pieces, help cards, oil panels, the train builder, stop lists and the Rail tool; a locale probe translates all 2,585 strings.

### Not done, moved to 0.1.3

- The AI's pace (#2) and air, artillery and interceptor use (#20), and Windows (#15), are open.
- Rails: the stop editor cannot tell that a stop is unreachable from the stop before it (junctions turn one way); two auto lines surveyed at the same time can plan over the same ground and the second takes a detour; a busy depot with many trains through it deploys rarely; the Rail tool has no "cancel the whole track" of its own (undo works while it is open, otherwise cancel the ghosts).
- Clear order for whole divisions and a Clear button in the build menu; a robot recipe for a new city; cards for the five abilities; the pumpjack's baked pipe stub needs art.

## 0.1.1

Factorio 2.1, Space Age optional. The first update after the public release: the Nation AI, hauler fuel and rail freight, the script tick budget, the interface on Factorio 2.1, guided objectives, a Russian review and a Linux check. Skirmish plays as in 0.1.0: all ten scenarios of the Skirmish test matrix log the same lines as 0.1.0. The release acceptance passed 42 of 46 criteria; the four misses are named below. Issue numbers refer to [the issue tracker](https://github.com/Kealman/factorio-rts/issues).

### Nation AI

- **Age III sooner (#1), partial.** The planner runs a concrete chain, builds its Age II districts in the order Age III needs, keeps its oil town, forwards goods bought from city-states to the capital, reserves the Launch complex's site, focuses the works factory on engines while Electrification waits for them, and holds other industrial research while Space Program stage 1 lacks goods. In the release acceptance the first nation reached Age III at 34:42, 38:15, 41:13, 41:16 and 41:36 in the five four-nation test seeds: 2 of 5 by minute 40, short of the target of 3 (0.1.0: 1 of 5, at 36:24 to 48:17). The AI's own runs on earlier trees of this release reached 3 to 5 of 5.
- Factories that the governor or the planner set to a fixed recipe are no longer borrowed as workshops; they used to switch recipes about 1,000 times a match. Every nation's goods chain benefits (#1).
- **Rail linking (#2), partial, still open.** The works factory makes a waiting line's depots and crew kits, no new district is queued while a capital line waits for its crew's kits, crews go out in turn, coal is imported for waiting crews, an open line gets its freight train's kits from the capital, and rail crafts leave 100 stone in the capital. In the release acceptance the aggressive AI's first line came before minute 32 in 4 of 5 seeds (target met; 0.1.0: 1 of 5), but only 9 of 20 nations had three cities linked by minute 35 (target 16; 0.1.0: 12). Lines lost in wars and capitals short of steel for the crews' kits cause most misses.
- **War tools (#4), partial.** At war the council lays siege railways (a forward depot with a radar near the target and a line to it) for its artillery trains and asks for the train every 30 s, interceptors patrol the capital, bombers strike the nearest enemy city, and the war technologies are researched first. With the technology granted every war path works (6 of 6 in the release acceptance). In the 60-minute acceptance matches scout planes patrolled in 5 of 5 seeds (0.1.0: 3 of 5), but no interceptor or bomber flew and no artillery train fired: no nation reached Air Force, and no siege line opened before its operation ended. In the AI's own runs Military railways came in 13 of 20 nations (before: 3 to 4). Requesting the artillery train's kits when the siege railway is planned is the next step.
- **Armies shrink in debt (#5).** From debt stage 2 the AI retires idle units down to 40 supply, and its barracks make nothing more until five minutes after the debt. It also stops recruiting while it loses money below ₡ 300. No nation reached debt stage 2 or its credit line in the acceptance seeds, and the debt test passes 3 of 3.
- **Hard is stronger by skill (#3).** Hard plans housing for 160 more residents than its jobs need and goes for a second city-state. It beat normal in 20 of 20 side-swapped 1v1 matches (0.1.0: 5 of 10), with no resource bonus.
- A depot lost in a war is rebuilt on its old site, and its intact line is bound to it again (#7, #2).

### Economy and logistics

- **Hauler fuel (#6).** A hauler bound for a stop that may lack coal pays its way back before it leaves: from its tank, then the network it leaves, then the destination's. A hauler re-routed while driving takes its way back from its destination or refuels first, and a hauler dry for 30 s at a hub gets its trip paid by the stop it drives to. No hauler stranded at a remote hub in the M1 and M2 test seeds (0.1.0: 9 to 16 per run).
- Auto haulers wait at home for up to a minute for a load worth the trip's coal (25 items per coal of the round trip). In the 1v1 test the player side's auto haulers moved the same goods on 62 % less coal.
- **Rail freight (#7).** An AI rail program's freight train carries everything its town offers, not only the capital's shortfall. On the shipped tree the 1v1 acceptance seed moves 19,101 items by train in two identical runs, just short of the 20,000 target (0.1.0: 13,506), so #7 is partial on that seed.
- **Rail crews (#2).** Surveys keep clear of mountain rims, a crew stuck for two minutes goes home or is recalled with its kits, rails and coal, and a crew leaves only with at least 40 rails (or its line's whole need).
- **Balance.** Air Force costs 30 industrial kits (was 50) and Military railways 17 (was 25).

### Performance

- **Script tick budget (#8).** Nation-mode periodic handlers run on phases of their own, derived from stable keys; the market AI reads the capital's ledger in a scheduler job; the auto-recipe pass and the hauler-kit sweep are spread over ticks; and the AI's target scans answer from a short cache. In the 5-minute budget scene the script ticks over 3 ms fell from about 390 to 19 (the worst 4.9 ms) and the script p99 to 1.7 ms. The whole tick averages 1.33 ms with a p99 of 2.9 ms and a capacity of 752 updates per second (0.1.0: 1.435 ms, 5.68 ms, 697), and no tick exceeds 16.67 ms. The market AI causes none of the slow ticks. No script tick over 3 ms at all remains the long-term goal.

### Interface, onboarding and localisation

- **Guided objectives (#16).** An objective strip at the top right walks a first Skirmish and a first Nation match through seven steps each. A "Guided objectives" switch in the lobby turns it on or off; it is on for your first match of each mode. English and Russian.
- **Escape (#12)** opens the game menu (save, load, settings, exit) and closes an open RTS panel first; it no longer drops the remote view for a tick.
- A right click on a pentapod's leg attacks the pentapod, not the leg (#12).
- **Hauler lines on the map (#9).** The engine's line from every hauler to its destination is drawn at its 1 px minimum without destination markers, and the mod draws the selected haulers' routes while the hauler panel is open. The engine line itself cannot be hidden on Factorio 2.1.
- The stockpile panel colours a count against this hub's own Keep, and the count's tooltip names the network's levels (#10).
- **Russian review (#17).** One glossary across the mod (держава, ж/д депо, полевой склад, дивизия, комплект and набор, дроны), the game's own Russian item names, and shorter panel lines. The M3 GUI pass reaches 53 of 53 in Russian (0.1.0: 48 of 53).
- The Nation lobby's world-generation estimate uses Factorio 2.1's rate (4096: about 5 minutes, was 7).
- The in-game mod description covers both modes.

### Factorio 2.1 port follow-ups

- **Building look (#11).** Every RTS building was reviewed against 2.1's new art. The barracks, the Electronics and Electronics II plants, the Petrochemical works, the field depot, the fishing hut, the AA turret and the fort get tints that tell them apart from their neighbours; only tints changed.
- **Inputs (#12).** A real-input GUI probe of 29 checks (box and click select, orders, attack-move, camera, control groups, minimap, menus, restart) passes in English and Russian.
- **Baselines (#13).** Worlds generate as on 2.0; background generation is faster (4096 with 6 nations in 244 s, was 375-381 s); the division pathfinding budgets stay.

### Platform and tooling

- **Linux (#14).** `tools/linux/run.sh` runs the headless autotests in Docker on the official Linux build: the Skirmish smoke (65/65) and the Nation smoke (53/53) pass on x86-64 and ARM64, with and without Space Age, with the same logs as macOS. A case check of every `require` and file path finds no mismatch. The Linux GUI client is untested.
- **Windows (#15), still open.** Untested. GitHub issue templates for bug reports and feature requests ask for the system, versions and log, and the README asks Windows players for reports.
- `tools/release-check.sh` runs a release's whole headless acceptance in one command and writes a report (#18). `tools/probes/ai3_debt.lua` tests the debt path, the GUI driver gained drags, modifier keys, held keys and double taps, and `tools/autotest-run.sh` runs on Linux too.

### Release acceptance (tree 615854f)

- **Passed:** the Skirmish smoke test (65/65) and the Skirmish matrix (10 scenarios, line-identical to 0.1.0); the M2 seeds 701-705 (trade, war, peace and capture in 5 of 5, a starving nation in 1 seed, within the tolerance of 1); the M3 seeds 801-805 apart from the two misses below (every nation held 3 cities and ran an operation, fort belts and air patrols in 5 of 5, a starving nation in 1 seed); a 3072 world with 4 nations; save and load at minutes 20 and 40; determinism (two runs per seed, 0 differing lines); the budget scene at 60 updates per second; heavy mode; a LAN session with a server and two GUI clients joining one after the other (0 desyncs); the war-paths test (6/6) and the debt test (3/3); the GUI pass in English and Russian (53/53 each); and the Linux headless tests (65/65 and 53/53).
- **Missed:** Age III by minute 40 in 2 of 5 seeds (target 3, #1); three cities linked by minute 35 for 9 of 20 nations (target 16, #2); the M1 seed's rail freight at 19,101 items (target 20,000, #7); and the M1 seed's score of 51/53, whose second miss is the aggressive AI reaching Age II at 32:36, after the test's 20:30 deadline.

## 0.1.0: first public release

Factorio 2.1, Space Age optional. Built from 2026-10-15 to 2026-10-24.

### Factorio 2.1 port and the M3 QA fix round (tag `m3-ready`, 2026-10-23 to 2026-10-24)

- **Ported to Factorio 2.1** (tested on 2.1.23): science packs as plain items, recipe `categories`, the fuel rod's `fuel_categories`, `crafter_output`, `extract_fluid`, `minable_flag`, `independent_probability` in the market's price derivation, and the new pins panel hidden. The mod no longer loads on 2.0.
- Every RTS unit gets the 2.0 map steering on its prototype, so units keep their 2.0 spacing after 2.1 moved steering off the map settings.
- The install keeps the built-in `recycler` mod enabled, which Space Age and Quality need on 2.1.
- Artillery trains see targets through your own land, your planes and fronts your divisions hold, and the gun line tells "not seen" from "out of range".
- AA turrets deal twice the damage, their shots and kills are logged, and the kill feed names the turret that shot a plane down.
- A single front label replaces the oversized duplicate that showed at intermediate map zoom.
- The train panel shows where an artillery train is and where it goes, and a greyed Deploy artillery train button lists what is missing.
- The research Rush is refused, and greyed, while no lab is working.
- A route hauler waits at its pickup until both legs of coal are in its tank when the drop-off holds too little coal for the way back.
- The Nation AI keeps coal for its supply haulers, imports coal while one waits, replaces stranded haulers and rebuilds destroyed hubs first, which ended the starving AI towns in the M2 acceptance seeds.
- Every run tool refuses a game binary whose version does not match the mod's `factorio_version`, and headless autosaves are off.
- The M1 acceptance's Age II deadline moved from 20:00 to 20:30, because Industrialisation finishes about 16 s later on the new engine.

### Phase 5 M3: "A state at war" (tags `m3-wave-a` and `m3-ready`, 2026-10-17 to 2026-10-23)

Added:

- **Age III and the Space Program:** Electrification starts a three-stage launch complex next to the capital; stage 1 brings Age III and the launch after stage 3 wins under Conquest + Space and Any.
- Age III content: the Chemistry district, the Electronics II plant, the Concrete works, the 40 MW Nuclear plant with fuel rods, batteries and rocket fuel, and uranium rounds for heavy walkers.
- **Automation kits** that cut a district family's jobs by 30 % at the same output.
- **Rare resources:** the Rare extractor and six nation-wide bonuses that hold only while rare items keep reaching the capital.
- **Money sinks:** Rush for national projects and research, Hire for garrison points, and Mercenaries at your ports.
- **City-state trade** at 1.3 times the market price, with relations that move with trade.
- **Air:** airfields, the scout plane, bomber and interceptor, plane supply with automatic return and crashes, the AA turret and the air panel (Y) with Patrol and Return.
- **Fronts:** in a war the shared border is cut into fronts with a threat level, and divisions can hold a front along its length (H).
- **Fort belts:** a tool (F) that lays a wall with gates, turrets, AA turrets and a field depot along 2 to 6 points, built by a crew.
- **Artillery and armoured trains** with Military railways, and the Bombard order (B).
- **Huge worlds:** 2048, 3072 and 4096 tiles with 2 to 6 nations, a forced spawn core, background generation with a progress line, and the Explore or Survey start map.
- **The layered nation AI:** an economic planner, a war council, division controllers and an intelligence layer, with difficulty that changes skill instead of resources.
- A deterministic work-unit scheduler with resumable jobs for rail surveys, AI planners, fog and map generation.
- Performance, determinism, heavy-mode and LAN tools, and the M3 GUI protocol.

Changed:

- Balance passes: army upkeep 1.2 crowns per supply point a minute, Railways 10 basic kits, Electrification 25 industrial kits, a lighter Space Program stage 1, and tax and deficit changes with a hysteresis band.
- Rail lines cross your own walls through gates, get past blocked pieces with a short detour, and re-route trains when a lost depot comes back.
- Attack-moves spare belts, inserters and plain buildings around a fight.
- Depots are labelled on the map, and the Nation help page scrolls.

Fixed:

- LAN-critical determinism: AI sight, the kill feed and the enemy count no longer read client-side chart state, and order-dependent loops were made deterministic.
- A crash on a run-time require in the cities module, a failed rail survey that repeated back to back, and a town-site search that ran in one tick.

### Phase 5 M2: "People, money and war goals" (tags `m2-wave-a` and `m2-ready`, 2026-10-16 to 2026-10-17)

Added:

- **People and labor:** residents, housing, rations and household goods, farms, bakeries and fishing huts, growth and happiness, workers drawn from the city's land, labor priorities, Pin, recruits and the draft.
- **Treasury and trade:** a treasury in crowns, three tax levels, building, army and transport upkeep, three debt stages, trade ports, a shared world market with a commerce cap, contracts between nations and the market panel (M).
- **Diplomacy:** war, ceasefire, peace and alliance, opinions, war goals, treaties, gifts and proposals in the diplomacy panel (F4).
- **Victory modes:** Conquest, Territory, Score and Any, with a time limit.
- **War supply:** supply points for divisions, supply crates and field depots.
- **Capture, not destruction:** subdued City Centers flip to the attacker with their land, buildings and most of their people.
- **Garrisons** with Sortie, and **troop trains** with boarding at depots and Disband for standing trains.
- **The world gets regions:** named regions, a scarcity portfolio, city-states, ruins, trade ports, named chokes, uranium and rare deposits.
- **The strategic layer:** map labels for regions, chokes, cities and ports, and a regional minimap with a world toggle (N).
- **The nation AI:** a strategist for taxes, trade, contracts, war and peace, a governor per city, and capture operations.
- Disband for units (Delete), Commerce and Geology research, and the Nation help page.

Fixed:

- Units step off a platform before a train is placed there, Deploy buttons explain why they are greyed, boarding is refused without a troop train, and the diplomacy countdown ticks.
- Rail lines survive a lost and retaken city, and construction trains leave fuelled.

### Phase 5 M1: "Two cities and a railway" (tag `m1-ready`, 2026-10-16)

Added:

- **Nation mode** in the lobby, on a generated world with mountains, passes, fords, fair spawns, regions and oil sites.
- **Territory:** an ownership grid, borders, build rules by land, attrition in enemy land, and forts.
- **City Centers:** founding with a City charter, tiers from village to city, the city list and the city panel.
- **Rails:** depots, rail and rolling-stock kits, a route planner with bridges, a construction train, scripted freight schedules, cuts and repairs, and the train and depot panels.
- **Ages:** the Railway Charter national project brings Age II with oil as goods, engines, advanced circuits, steel beams, concrete, the Armoured car, the Bunker, the industrial science kit and ten districts.
- **Make targets** with Auto recipes, and the city ledger (L).
- **Divisions** in both modes: formations, stances, reinforcement and an order queue that caps pathfinding per tick.
- **Demolish** your own buildings in both modes with Delete or Backspace (two presses, 50 % refund).
- Nation-mode haulers with 10 slots and coal fuel, inserters that move 3 items per swing, and the army soft cap.
- The Nation AI founds a mining town, links it by rail, runs the Railway Charter and builds districts.

Fixed (QA round 1):

- A scripted make-target picker, a division attack-move that reaches its point, exact selection of rolling stock and depots, and City charter names.

### Phase 4: a real RTS with a Factorio economy (2026-10-15 to 2026-10-16)

- Hubs with their own logistic networks, stockpile policies, and haulers with auto mode and manual routes.
- Labs, basic and advanced science kits, and 19 technologies.
- New units: drone, raider, artillery walker, Mk2 tiers, the Commander hero and the hauler; new buildings: laser turret, wall, steam plant, accumulator and radar; new intermediates.
- Five abilities on an ability bar: Stim, Shield, Scanner sweep, Artillery strike and Overcharge.
- Commander field construction stocked from the CC's pool, so the Commander builds beyond robot reach.
- Map generation with lakes, forests, water moats with land gaps, natural and middle patches, a capturable ruin, depletion alerts and a large map size.
- AI doctrines (economic, aggressive, turtle) with research, hubs, haulers, counter-based army mixes and raids.
- HUD: build menu tabs with research gating, unit cards, blocked reasons, supply, alerts with F3, a kill feed and How to play (F11).
- Concede and Results in the F10 menu, Ctrl+A for the army, and an economy pass (400 iron and 150 copper to start, cheaper tier-1 research).
- Tools: a headless scenario runner, a validation matrix, seeded balance batches, a save/load check and an equal-cost fight simulator.

### Phase 3: AI opponent and match flow (2026-10-15)

- AI commanders that build real bases from build orders, produce, defend, scout and attack.
- A lobby, an arena surface per match, 1v1 to 1v3 free-for-all, fog of war, victory and defeat, a results screen, and the match menu with restart.
- Three difficulties, and install and uninstall scripts.

### Phase 2: economy slice (2026-10-15)

- The Command Center composite, stockpiles, extractors, smelters, factories, barracks, turrets and solar arrays with their recipes and kits.
- Production that pulls its inputs from the logistic network, barracks that deploy units at a rally point, and the starting base.
- The build menu, the building panel with recipes and rally point, the resource strip, and English and Russian texts.

### Phase 1: control vertical slice (2026-10-15)

- The remote-view RTS camera with no character, the RTS cursor, box select, control groups, move, attack, attack-move, stop and hold.
- Selection boxes, the HUD with a minimap, the event bus and a headless autotest.

### Phase 0: feasibility spikes (2026-10-15)

- Spikes confirmed the remote-view camera, mouse input in remote view, spider-units as controllable units, the barracks pattern and scripted AI bases.
