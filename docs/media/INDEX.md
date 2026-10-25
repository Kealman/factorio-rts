# Release media

Staged screenshots of Factorio RTS for the README and the Factorio Mod Portal, the game area of a real English client
(Factorio 2.1.23 with Space Age), with the mod's HUD. Release 0.1.1 re-shot 01, 02, 03, 05, 06, 07, 08, 13, 14 and 15
on HEAD fd75b4d (the 2.1 building tints, the lobby's "Guided objectives" switch, the 1 px hauler lines and the AI of
0.1.1, on a new 60-minute bake); 04, 09, 10, 11 and 12 are the 0.1.0 shots, which nothing in 0.1.1 changed (12 came out
pixel-identical). The scenes switch the guided objectives off before every Start (`showcase_lib.lua`,
`lib.no_objectives`), so no shot shows the objective strip; 01 shows the switch in its default "on" state. The files here are web versions: 1600×900 PNG, pngquant
(quality 70-90) and oxipng. The full-size 1920×1080 originals for the Mod Portal gallery are written to
`build/showcase/full/` (not in git; `tools/showcase.sh full` lists them, `tools/showcase.sh web` re-encodes this folder
from them). No human played: `tools/showcase.sh all`
regenerates every file. A scripted scene spawns, gives and positions everything through the module calls behind the QA
console shortcuts (`/rts-give`, `/rts-spawn`, `/rts-research`, `/rts-age`, `/rts-front`, `/rts-market`), moves the
camera, waits for the moment and grabs the client window (`tools/gui-drive.sh`). The Nation shots play on a 3-nation
2048 world (seed 4242) that the AI built for 60 game minutes for every nation, yours included (`tools/showcase.sh
bake`). Alternate takes land in `build/showcase/alt/`. `REVIEW.md` is the review of the first set by Codex computer use
(model gpt-6-astra) and the changes made after it.

| File | What it shows | Launch, probe and scene |
|---|---|---|
| `01-lobby.png` | The Nation lobby: 6 nations, World 4096×4096, Survey, the Victory list open (opened by a real click) | `lobby`, `tools/probes/showcase_lobby.lua`, scene `01-lobby` |
| `02-capital.png` | The capital at city tier: districts, hubs, rail depots, stockpiles and haulers on the move; Age III badge, treasury and supply on the strip | `nation`, `tools/probes/showcase_nation_scenes.lua`, scene `02-capital` |
| `03-rail-line.png` | A freight train leaving the capital's depot on an open line to a town | `nation`, `showcase_nation_scenes.lua`, scene `03-rail-line` |
| `04-division-battle.png` | A division of Walker Mk2s, heavies, armoured cars and artillery walkers (selected: its card with the stances, the unit cards) meets an AI 1 force: shell bursts, the kill feed | `nation`, `showcase_nation_scenes.lua`, scene `04-division-battle` |
| `05-front-fort-belt.png` | Front 2 against an AI 1 town (the dashed border lines and the label "Front 2 · threat T · held by Division N"), the fort belt built along it (a wall 1 tile behind the border, turrets behind it) and the division holding the line behind the wall (its card: "Holding the line (front 2)") | `nation`, `showcase_nation_scenes.lua`, scene `05-front-fort-belt` |
| `06-air.png` | The capital's airfield with scout planes, bombers and interceptors on patrol (selected), the AA turret firing at AI 1 bombers coming in from the right | `nation`, `showcase_nation_scenes.lua`, scene `06-air` |
| `07-artillery-train.png` | An armoured artillery train in Bombard (left third) at a depot 12 tiles behind a front, the dashed borders and the yellow front line crossing the frame, and a compact AI 1 village 45 tiles away (right third: its centre, houses, turrets, barracks, radar) with a rail shell bursting at its edge; the train panel ("Bombard [B]", "Shells: 19 · next shot in 9 s · last target: Turret (37 tiles)") | `nation`, `showcase_nation_scenes.lua`, scene `07-artillery-train` |
| `08-space-program.png` | The city ledger with the Space Program at stage 2/3 (the goods delivered so far, Rush, the automation row) next to the Launch complex and its progress label | `nation`, `showcase_nation_scenes.lua`, scene `08-space-program` |
| `09-strategic-map.png` | The map view around the capital: region names, the capital and towns with their land, the AI 1 town across the front, a city-state, rail lines, depot labels and the division marker at the front | `nation`, `showcase_nation_scenes.lua`, scene `09-strategic-map` |
| `10-diplomacy.png` | The diplomacy panel: AI 1 at war (score, weariness), AI 2 at peace, a city-state, our war and AI 1's peace offer with Accept and Decline (also as the offer bar above it) | `nation`, `showcase_nation_scenes.lua`, scene `10-diplomacy` |
| `11-market.png` | The market: treasury, tax and flows, the commerce cap, prices with 10-minute sparklines, a city-state as the trade partner and an active steel contract with AI 2 | `nation`, `showcase_nation_scenes.lua`, scene `11-market` |
| `12-world-4096.png` | A fully generated 6-nation 4096 world in the map view, all six capitals between the HUD bands: regions, rivers with fords, mountain ranges with passes, city-states and ports. The square world leaves dark bands left and right at the zoom that keeps every capital in frame; the launch also writes `build/showcase/alt/alt-12-world-4096-wide.png`, which fills the width with four capitals | `lobby`, `showcase_lobby.lua`, scene `12-world-4096` |
| `13-commander-abilities.png` | Skirmish: the Commander (selected) casts Shield on the army around it and an Artillery strike lands in its target ring; the ability bar shows both cooldowns | `skirmish`, `tools/probes/showcase_skirmish.lua`, scene `13-commander-abilities` |
| `14-skirmish-base.png` | Skirmish: the factory base built by the AI in 14 minutes, the natural hub (selected) with its stockpile policy (Export above 20) and an army block at the rally point | `skirmish`, `showcase_skirmish.lua`, scene `14-skirmish-base` |
| `15-city-panel.png` | The capital's city panel (residents, happiness, needs, workforce, draft, make targets, Hire) and its stockpile policy panel | `nation`, `showcase_nation_scenes.lua`, scene `15-city-panel` |
| `thumbnail-source.png` | The 640×640 square of the full-size `13-commander-abilities.png` of 0.1.0 that the mod portal thumbnail is scaled from (full resolution, web-encoded); the 0.1.1 take of 13 is not better, so the thumbnail stays | `tools/showcase.sh thumb` |
| `../../mods/factorio-rts/thumbnail.png` | 144×144 thumbnail: the Shield rings around the Commander and the Artillery strike bursting in its ring (that square scaled to 144×144) | `tools/showcase.sh thumb` (`THUMB_SHOT`, `THUMB_CROP`) |

Probes: `tools/probes/showcase_lib.lua` (steps, scenes, captures, staging helpers), `showcase_lobby.lua`,
`showcase_nation.lua` (the bake and the scene launch) with `showcase_nation_scenes.lua`, `showcase_skirmish.lua`. One
scene again: `tools/showcase.sh nation 06-air` (the setup steps always run). A full run takes about 15 minutes of wall
clock and one GUI client at a time; Steam must be running.
