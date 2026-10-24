# Changelog

The mod's version stayed 0.1.0 through development, so the whole history below is the first public release. Development ran in milestones; each milestone's contract is in `docs/PHASE*.md`, and its acceptance results and open issues are in `docs/qa/`. Git tags mark the milestone ends.

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
