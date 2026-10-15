# Phase 4 — A real RTS with a Factorio economy

Direction from the owner (2026-10-15): do not limit content. Take what made StarCraft, WarCraft III and Age of Empires great and build a strong RTS, but keep Factorio's reason to exist: production chains instead of resource piles, and logistics that reward planning — distributing items across stockpiles, hauling, designing hubs. The economy is the star.

## 1. What made the classics work, and how we express it through chains

| RTS pillar | Classic form | Our form (Factorio economy) |
|---|---|---|
| Resource gathering | workers mine piles | extractors mine finite patches; ore has to be moved and smelted; distance is a cost (belts, haulers, robots) |
| Expansions / map control | "take your natural", contest the middle | patches deplete; forward **hubs** with their own logistic network; **haulers** carry items between hubs and can be raided; power lines can be cut |
| Supply cap | pylons/depots/farms | **command capacity** from CC and hubs (CC 40, hub +10, tech +10); units cost 1–4 |
| Tech tiers | barracks → factory → starport | **chains gate tiers**: steel → heavies, circuits → raiders/lasers, explosives → artillery; labs consume science kits made from chains |
| Upgrades | attack/armor +1..3 | force-wide research (`force.technologies`): damage, armor-as-HP-tier, mining speed, belt speed, robot count, hauler capacity, supply |
| Unit counters | marine/zealot/tank/siege | 6 roles with a counter wheel (section 3) |
| Micro and abilities | stim, blink, spells | a few scripted abilities with cooldowns: Stim (speed burst, costs HP), Shield (temporary absorb), Scanner sweep, Artillery strike (vanilla artillery), Overcharge (turrets ×2 damage for 10 s, drains power) |
| Heroes | WC3 heroes | a **Commander** spidertron per player: color, equipment grid, respawns at the CC after 60 s, levels via kills (grid slots unlock), carries a small roboport for field construction |
| Defence | bunkers, towers, walls | gun turret, laser turret (power-hungry, fits power-as-supply), stone walls, mines later |
| Fog and scouting | fog, scans | per-force charting (done), scanner sweep, radar building, watchtower |
| Feedback | "base under attack", pings | alert line + hotkey to jump, minimap pings, kill feed, unit voice/sounds from vanilla |
| Pacing | build orders, cheese, late game | early: starting stock lets you choose economy-first or rush; mid: expansions + tech; late: artillery, lasers, big armies, hauler convoys |
| Replayability | matchups, AI, maps | AI with doctrines (economic / aggressive / turtle), generated maps with chokepoints (cliffs, lakes, forests), 1v1–1v3, difficulty |

## 2. The economy (the core)

### 2.1 Hubs and networks
- **Hub** (`rts-hub`): a small roboport (logistic radius 14, construction radius 22, 10 robots) + 2 attached stockpiles + a 300 kW internal generator (enough for itself and two extractors). Cost 40 iron 10 copper, built like any building.
- Each hub forms its own logistic **network** unless its roboport area overlaps another hub/CC (vanilla behaviour). Consumers (barracks, factory, labs, turrets) pull only from the network they stand in. A base is therefore a graph of networks.
- **Stockpile policies** per hub (GUI on the hub): for each item a *keep* threshold (import until N) and an *export above* threshold. Items above export are offered to haulers; below keep they are requested. This is the distribution game.

### 2.2 Moving items
- **Belts and inserters**: intra-base and short links; cheap, static, raidable.
- **Haulers** (`rts-hauler`, spider-vehicle, 20 cargo slots, no weapon, 2× walker speed): script-driven routes. Select a hauler → right-click hub A (pickup) → Shift+right-click hub B (drop-off); or assign it to a hub as an *auto hauler*, which serves that hub's requests from any hub with exports (nearest first). Haulers die to raiders; losses are logged. Capacity grows with tech.
- **Robots** move items inside one network only.
- **Trains** are out of scope (haulers play that role).

### 2.3 Power as supply
- Every building draws power. CC 4 MW, hub 0.3 MW internal, solar arrays +0.4 MW, **steam plant** (boiler + 2 engines clone, needs coal via belts, +1.8 MW) mid-game. Accumulators buffer. Poles connect; cutting a pole line browns out a forward base.
- Laser turrets and Overcharge drain power deliberately.

### 2.4 Depletion and expansion
- Patches: main (iron 6k, copper 4k, stone 3k, coal 3k), natural (iron 8k, copper 4k) 60–80 tiles out, contested middle patches (iron 12k, copper 8k, coal 6k). Extraction empties the main in ~12 minutes with 6 extractors, forcing hubs at the natural.

### 2.5 Chains
```
iron ore → iron plate → gear, steel (2 plates, slow)
copper ore → copper plate → copper cable → circuit (1 iron + 3 cable)
coal + iron → explosives (grenade-like intermediate)
stone → stone brick → wall
kits: walker (10 iron, 2 copper), drone (6 iron), heavy (30 iron, 10 copper, 5 steel), raider (15 iron, 8 circuit), artillery (40 iron, 10 steel, 10 explosives)
science: basic kit (1 gear + 1 copper, 5 s), advanced kit (2 circuit + 1 steel, 10 s)
buildings: hub, lab, steam plant, accumulator, laser turret (20 iron, 10 circuit), wall (stone brick), radar
```

## 3. Units and counters

| Unit | Role | Cost (supply) | Strong vs | Weak vs |
|---|---|---|---|---|
| Walker | all-round ranged | 10 Fe 2 Cu (1) | drones | heavies, artillery |
| Drone | cheap fast melee swarm (`unit` class, biter sprites, tinted per team) | 6 Fe (1) | artillery, haulers, raiders | turrets, walkers in numbers |
| Heavy | tank, slow, splash stomp | 30 Fe 10 Cu 5 steel (3) | walkers, drones | artillery, lasers |
| Raider | fast, bonus vs buildings and haulers, weak vs units | 15 Fe 8 circuit (2) | haulers, extractors, poles | walkers, turrets |
| Artillery walker | long range siege, min range, slow | 40 Fe 10 steel 10 explosives (4) | turrets, heavies, static defence | drones, raiders |
| Commander | hero spidertron, abilities | free, 1 per player | — | focus fire |

Attack/armor upgrades via research apply through force damage modifiers (ammo category per unit role) and tiered prototypes for HP (mk2 variants unlocked by research; barracks switch recipe output).

## 4. Tech tree (labs, two science kits)

Tier 1 (basic kit): Attack I, Armor I, Mining I (+25 % speed), Logistics I (belt speed, +5 robots per hub), Supply I (+10), Unlock Heavy, Unlock Raider, Hauler capacity I.
Tier 2 (advanced kit): Attack II/III, Armor II/III, Unlock Artillery, Unlock Laser turret, Steam power, Overcharge, Scanner sweep, Supply II, Mining II.
Research costs 10–40 kits; one lab per 10 s per kit; multiple labs parallelise (vanilla).

## 5. Map generation
- Arena surface with terrain: 2–3 lakes, cliff lines forming 2 chokes between each main and the middle (`surface.create_entity{name="cliff"}` or map gen cliffs with the arena flattening only at bases), forests as vision/pathing obstacles, patches as in 2.4, a neutral **ruin** in the middle (a dead CC with 2 stockpiles holding 200 steel + 50 circuits, raidable). Sizes small/medium/large.

## 6. AI
- Doctrines: *economic* (hubs early, haulers, late push), *aggressive* (drones + raiders at 2 min, harass haulers), *turtle* (turrets, lasers, artillery). Difficulty scales pacing as today. The AI uses hubs/haulers/tech/counters: army composition reacts to what scouting saw (drones vs artillery, heavies vs walkers, raiders vs hauler lines).

## 7. HUD and feel
- Alerts: "Base under attack" / "Hauler lost" / "Research complete" with a jump key (F3 cycles alerts), minimap pings.
- Unit cards with HP bars, ability buttons with cooldowns, tech panel (lab recipes + research queue), hub panel (policies), hauler panel (routes), supply "40/60" in the strip, kill feed.
- Team colours verified on screen, vanilla sounds for shots/deaths, Commander voice lines are out of scope.
- Tutorial: a lobby "How to play" page and first-5-minutes tips (goal: first hub by minute 6, expansion by minute 10).

## 8. Work plan (waves of parallel agents, each validated headless + GUI; Codex QA at the end of each wave)

- **Wave A (content foundation)** — parallel: A1 prototypes (units, hub, hauler, lab, kits, intermediates, steam, laser, wall, radar, mk2 variants); A2 logistics control (hub networks, policies, haulers, routes GUI, raid logging); A3 research & supply (labs, techs, modifiers, mk2 switching, supply cap enforcement in production); A4 map gen (terrain, patches, ruin, sizes) + depletion.
- **Wave B (play)** — B1 AI doctrines + new content usage; B2 HUD (alerts, cards, tech/hub/hauler panels, supply); B3 abilities + Commander; B4 balance pass with headless battle sims (each counter pair).
- **Wave C** — Codex full-match QA, fixes, README/tutorial, performance check at 400 units + 3 AIs.
