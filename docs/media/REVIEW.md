# Release screenshot review

Viewed all 17 files individually, checked gallery shots at approximately 900 px, and enlarged small labels/panels. Scores: 1 poor, 5 excellent. “Drop” means omit from the gallery. The strongest hook is 13; empty ground and obscured subjects weaken several others.

| File | Composition | Readability | Store appeal | Verdict |
|---|---:|---:|---:|---|
| 01-lobby.png | 2 | 1 | 1 | drop |
| 02-capital.png | 3 | 3 | 4 | keep |
| 03-rail-line.png | 2 | 2 | 2 | reshoot |
| 04-division-battle.png | 3 | 3 | 4 | keep |
| 05-front-fort-belt.png | 2 | 2 | 3 | reshoot |
| 06-air.png | 2 | 2 | 2 | reshoot |
| 07-artillery-train.png | 2 | 2 | 3 | reshoot |
| 08-space-program.png | 3 | 2 | 3 | keep |
| 09-strategic-map.png | 3 | 2 | 3 | reshoot |
| 10-diplomacy.png | 3 | 2 | 3 | keep |
| 11-market.png | 3 | 2 | 3 | reshoot |
| 12-world-4096.png | 2 | 2 | 3 | reshoot |
| 13-commander-abilities.png | 4 | 3 | 5 | keep |
| 14-skirmish-base.png | 2 | 2 | 3 | reshoot |
| 15-city-panel.png | 3 | 2 | 3 | keep |
| thumbnail-source.png | 4 | 3 | 5 | drop |
| mods/factorio-rts/thumbnail.png | 2 | 2 | 2 | reshoot |

Retain the product HUD. Use daylight throughout; map/lobby lighting is immaterial. Zoom changes are relative. World zoom enlarges objects, **not GUI text**: dense panels still require full-size viewing.

1. **Lobby:** Correct settings and Victory choices occupy overwhelming blackness; the dropdown covers explanatory text. Keep for setup documentation. Camera/zoom cannot fix this GUI composition. If recaptured, preserve settings, open Victory immediately before capture, and add no props.

2. **Capital:** A credible factory, but haulers disappear among central walkers/wires; right-side grass and clipped peripheral works dilute it. Centre on the housing–hub–production cluster, zoom about 15%, and move parked combat units outside it. Capture separated, loaded haulers travelling between hubs and operating production; resolve visible machine alerts through normal supplies/connections. Leave selection empty.

3. **Rail:** The lead engine disappears beneath the top HUD; the city competes with the train and the right half is mostly grass. Stage a horizontal/diagonal departure onto open track, depot left and locomotive near centre-right, with the whole consist below the HUD. Centre on the train, zoom about 25%, capture smoke just after departure; select the depot if its identity needs explanation.

4. **Division battle:** Explosions sell combat; cars/artillery disappear beneath giants, and northern units hit the HUD. Keep this zoom, shift combat downward, spread heavies, and place cars/artillery in clear rear ranks. Select the attacking division; capture a central impact before corpses dominate.

5. **Fort belt:** Units form an overlapping column in front of the wall; selection boxes bury the tiny red front label. Remove the unrelated train, build a longer visible wall/turret rhythm, and position defenders behind it with a gap around the label. Centre on depot–wall–front, zoom 25–30%, keep Hold visible, and capture settled defenders with one approaching enemy group.

6. **Air:** Aircraft read as hovering pods; broad grass separates airfield, AA and enemies. No unmistakable AA shot is visible. Bring the enemy flight closer, centre the airfield/AA/flight triangle, and zoom about 30%. Space aircraft silhouettes, select a bomber for identification, and capture an AA muzzle flash/projectile plus one impact while retaining visible aircraft shadows.

7. **Artillery train:** Train and burst are disconnected; the town looks scattered. Stage rail closer to a compact town within firing range, train left and target right, clear of its panel. Centre between them; zoom 25%. Keep Bombard selected; capture impact beside town buildings with the whole train visible.

8. **Space:** Ledger and stage 2/3 agree at 75%, but the complex resembles an empty ring and the left side wastes space. Keep the ledger; centre the camera so a 20% larger complex sits immediately right of it. Include working supply buildings/haulers nearby, capture an active delivery before stage completion, and avoid clipping the complex under the build menu.

9. **Strategic map:** Depot/division labels are tiny; capital labels overlap and long blue lines dominate. Centre on Capital–Redrock, zoom 40–50%, and stage separated divisions and depots along that front. Keep one city-state visible; capture after orders settle.

10. **Diplomacy:** War and peace offer are present; repeated banners and tiny text compete. Keep panel/zoom; centre a quieter town edge behind it. Capture after the yellow notification expires while the offer remains active. AI 1 and AI 2 plus the player make three nations.

11. **Market:** Sparklines survive reduction; prices and partner explanation barely do. The cancelled/missed contract undermines the trade story. Keep panel/zoom, centre a working trade hub behind the exposed margin, and capture a successful active contract with goods arriving. Retain the city-state partner and populated price history.

12. **World:** Northern capitals sit under the HUD and southern capitals are cut off; this does not visually establish all six nations. Centre on their combined extent and zoom out about 25–35%, adjusting until all six fit between HUD bands. Capture after generation completes; add no armies. Fine labels will remain secondary to geography.

13. **Commander:** Best action shot; Shield circles, strike and cooldowns register, but mass selection obscures the hero. Keep zoom, centre slightly farther right, separate the Commander from heavies and select only the hero. Capture Shield and a bright strike together, before the southern walkers reach the ability bar. Provide sufficient normal supply capacity.

14. **Skirmish base:** Empty upper half, a tangled army block, damaged hub and zero haulers weaken logistics. Centre lower on base–natural–rally, zoom 20%, place the army in spaced ranks nearer production, repair the hub and dispatch haulers. Keep stockpile policy open; capture loaded transport in transit.

15. **City:** Workforce/draft/targets are present, but panels obscure the factory. Shift the city left-middle at current zoom, disperse walkers, and capture separated arriving haulers. Keep both panels and selected command centre.

**Gallery order:** Lead with **13 → 02 → reshot 07 → reshot 05 → reshot 09**. Follow with 06, 03, 08, 10, 11, 14, 15, 12. Use 04 as an alternate combat image; omit 01 and duplicate thumbnail-source. For a shorter gallery, also omit 04, 14, 15 and 12.

**Thumbnail:** At 144×144, the current crop is brown rubble, red units and small bursts; it loses the blue Shield story. An interim crop from thumbnail-source is **x=850, y=300, 650×650** (top-left origin), previewed at 144 px: both sides and effects survive, though still busy. Best reshoot: one separated shielded hero facing two enemies around one impact. Apply 13’s scene changes to thumbnail-source; never gallery both duplicates.

**Possible defects/debug appearance:** No console dump or traceback is visible. Investigate 13’s **111/80 supply**; it may be staging, not a rules bug. In 15, iron **584 / Keep 400** is yellow despite the panel’s “below keep” explanation; verify semantics. Repeated machine warning triangles, 14’s **503/1200 HP**, and 11’s cancelled contract look unhealthy. Numeric entity IDs/front threat values look technical but are product UI. The train’s “idle (no route)” can coexist with Bombard; it is not proof of failure. Tiny turret-like slivers at the extreme upper-left of 13/14 also deserve checking.

## Changes after this review (re-shot 2026-10-24)

The review above judged the first set. The scene scripts were changed as follows and every shot was taken again; the
current files are listed in `INDEX.md`.

| Shot | Applied | Not applied, and why |
|---|---|---|
| 01 lobby | The pointer leaves the window after the Victory list opens (no cursor icon) | Kept in the set as the setup shot; the dialog's layout is the mod's GUI |
| 02 capital | Zoom +15 %; the idle army is moved 165-195 tiles out of the capital before the shoot; the capture waits for a hauler that moved in the last half second | Machine warning icons belong to the baked economy (missing inputs) |
| 03 rail | A freight train leaving the capital's depot, the whole consist in frame, zoom +30 %, captured with its smoke | – |
| 04 battle | Two lines facing each other, heavies spread, armoured cars on both flanks, artillery behind; camera lower; the division selected (its card and stances on the HUD) | – |
| 05 front | The front town is a tier-2 town (an 80-tile front instead of 41); the wall stands 1 tile behind the border, the division 11 tiles behind it; the artillery train is disbanded before this shot; zoom +60 %, the front in the right third | An approaching enemy group (it would end the hold) |
| 06 air | The enemy flight spawns 17 tiles out and is caught inside 12; zoom 1.6; the airfield fully in frame; own planes selected; interceptors added | – |
| 07 artillery | Second reshoot (lead): the scene founds its own compact AI 1 village (land radius 48) east of one of our cities, the depot stands 12 tiles inside our land level with it, the train moves to the platform end nearest the village; the frame fits the whole train and the village (train left third, village right third, zoom 0.65 instead of 0.47), captured as the second shell bursts at the village's edge with the next one in the air, Bombard and the train panel on | – |
| 08 space | Zoom +20 %, the complex beside the ledger | – |
| 09 map | Zoom +45 %, centred between the capital and the front town; the engine's construction alert icons and the haulers' long autopilot lines (drawn by the engine from every hauler to its next stop) are hidden for the capture | Label sizes are the mod's |
| 10 diplomacy | Every stale alert line removed before the capture (the offer bar stays) | – |
| 11 market | Ended contracts of the baked match removed; an active steel contract with AI 2 | – |
| 12 world | All six capitals in frame between the HUD bands (the map view's zoom limit is widened for this capture only); second pass (lead): zoom +11 %, the most that keeps every capital marker between the strip and the ability bar | Filling the 16:9 width: the square world needs +53 % for that, and then only two capitals stay whole (alternate take in build/showcase/alt/) |
| 13 Commander | Only the Commander selected; parked units disbanded so supply is at or under the cap (80/80, was 111/80); captured as the strike lands | – |
| 14 Skirmish base | The base's bounding box framed left of the hub policy panel; raid damage repaired; a 12-unit block at the rally point; the natural hub selected | – |
| 15 city | The city left of the two panels | – |
| Thumbnail | A 640×640 square of 13 with the Shield rings and the strike burst | – |

Defects noted above: 13's 111/80 supply was staging (spawned units over the cap) and is gone. The yellow count next to Keep
400 in the stockpile policy follows the network's Keep, which is the largest Keep of the network's hubs
(`scripts/logistics.lua`; the capital's network has 6-7 hubs; `scripts/hubgui.lua` colours the count yellow below it),
not the selected hub's own field: the panel is consistent with its rule, though a reader may expect the hub's own Keep. The small icon at the extreme top left of the in-game shots is the RTS cursor tool
(the selection tool every player holds, with the spidertron remote's icon), which the game draws for the item in the
cursor while the pointer is parked outside the window; the cursor module puts the tool back as soon as the cursor
empties, so the captures keep it.
