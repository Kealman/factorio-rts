# Phase 5 M1 visual QA results

Tested **16 October 2026**, English client, **Factorio: Space Age 2.0.77**, 1280×800 game area. Build under test: **factorio-rts 0.1.0, Phase 5 M1 integration / m1-docs findings**, identified by the protocol as after `3f33f4c`; the exact installed commit was not independently inspected. The later main menu displayed engine build 84539 expansion, mac-arm64.

The entire protocol and Phase 4 example report were read before testing. Tester steps 1–48 were attempted in order in one Nation match; no lead log checks were performed. All game interaction used screenshots, mouse and keyboard in the already-open Factorio. No source, logs, shell-based game control, other application interaction, manual launch, close, restart or recovery reset was used. File access was limited to the two permitted documents and saving this report/screenshots.

Coordinates below are **window coordinates including the 28 px title bar**: subtract 28 from y to compare with protocol game coordinates. Screenshots are in [phase5-screenshots](phase5-screenshots/). PASS means the main functional outcome was observed, with unverified subchecks and deviations explicitly recorded; it does not certify frame-exact waits or every transient animation. Failed prerequisites within steps 15 and 43 prevented their remaining target-specific actions.

## Step results

| Step | Name | Result | Observation |
|---:|---|---|---|
| 1 | Lobby | PASS | Five lobby controls visible: Skirmish, 1 opponent, Normal, Small, Chokepoints; no Nation HUD. |
| 2 | Nation mode | PASS | Mode tooltip displayed; selected Nation at (585,385), showing World 1536 and disabled World map setting. |
| 3 | World size | PASS | 1536, 2048 and 3072 offered; selected 1536; disabled Map control did not open. |
| 4 | Start Nation | PASS | Nation HUD and Capital appeared without extra clicks; Land 1.2%, 441 cells, iron 400, copper 150, Supply 6/40; Army 7 by 00:08. |
| 5 | Nation HUD controls | PASS | Land tooltip and city-list hide/show worked; age tooltip and Capital magnifier opened Town panel; × closed it. |
| 6 | Territory and minimap | PASS | Five effective zoom notches showed blue dashed borders and black fog; own land left near (1137,129), AI right near (1241,112); zoom restored 112 px stockpile separation. |
| 7 | Spawn defenders | PASS | After a mistyped first console attempt, pasted exact shortcut successfully: 30 walkers; Army 37, Supply 36/40 yellow. |
| 8 | Nation build menu | PASS | City Center/Fort available and 14 Age II entries disabled; requested tooltips inspected; City charter is labelled City Center. |
| 9 | Factory and barracks | PASS | Factory at (448,332) and barracks at (832,332) changed from ghosts to buildings; respective kit counts reached 0. |
| 10 | Factory categories | PASS | Factory #764 showed five category icons at x=92–172, y=742; category grids/tooltips worked; initial Auto status Paused. |
| 11 | City charter production | PASS | Stone shortcut succeeded; City Center recipe (131,765) produced one then waited for stone; Auto returned unused ingredients and paused. |
| 12 | Found a city | PASS | After fog/tree refusals at (87,428), scouted and placed at (100,590), Commander (120,580), while zoomed out; Ironford 101 cells, Land 1.4%, cap 50; founding alert not captured. |
| 13 | City navigation | PASS | Ironford button centred its City Center (640,428) and two stockpiles; zoom-out showed the smaller connected territory, then zoom restored. |
| 14 | Capital protection | PASS | Capital Town, 431 cells/81%, 2/25 buildings; both Demolish controls disabled and Delete said Command Center cannot be demolished; market already 111/2000, not 0. |
| 15 | City Make target | FAIL | Empty item button (812,422) added RTS cursor instead of opening a picker; removal at (903,420), Q and retry repeated it; gear target 20 and resulting Auto production could not be exercised. |
| 16 | Rename and city policy | PASS | Village 101 cells/19%, HP 1800, Network #12 one hub, Keep 50 iron/20 copper; renamed through (886,249) to Outpost and verified after reselecting. |
| 17 | Hauler production | PASS | Circuit shortcut and hauler recipe produced one hauler #1007; selected actual body (651,508); Army 38, supply unchanged; factory returned to Auto/Paused. |
| 18 | Hauler route without fuel | PASS | Right-click Outpost then Shift-right-click Capital set Outpost → Command Center; yellow no-coal state and no-fuel alert appeared; hauler stayed still. |
| 19 | Hauler fuel | PASS | Coal 200 shortcut succeeded; hauler left and was later waiting at Outpost with tank 4; intermediate transit label was not captured. |
| 20 | Hauler return home | PASS | Return home (1062,342) switched to Auto/Going home, 117 tiles, tank 0 after Outpost tank 4; later seen waiting at Command Center. |
| 21 | Rail shortcuts | PASS | Railways research and all six item grants returned success; depot kits 2, locomotive 4, cargo 2, construction 1, rails 400 and iron +300. |
| 22 | Depot 1 | PASS | Depot at (288,428) built with 40-tile platform/two stops; Network #14 two hubs, coal 192, requested kits and rails; cap rose to 60. |
| 23 | Depot 2 | PASS | Depot at (832,460), Commander sent to (832,388), built with 40-tile platform; Network #15 two hubs, initially no kits/rails/coal; cap 70. |
| 24 | Build rail line | PASS | Right-click destination produced building state: 57 tiles, 38 rails, 14 pieces/14 missing, 0 supports, 4 signals; construction train appeared, kits became 2/2/0. |
| 25 | Open rail line | PASS | Line became green open: 57 tiles, 38 rails, 14 pieces/0 missing/0 supports/4 signals; zoom showed track, construction kits later at Depot 2; transient open alert not captured. |
| 26 | Freight train | PASS | Deployed four-carriage train; selected locomotive at (60,545), train 15 with coal 20, empty cargo/no route/Trips 0; locomotive HP 1000 and no Demolish. |
| 27 | Destination Keep | PASS | Depot 2 iron Keep set to 200 at (1146,364); In network 0 yellow. |
| 28 | First freight delivery | PASS | Route Depot 1 → Depot 2; loading showed copper 20/iron 178, then Trips 1 delivered copper 20/iron 200; depot stock 200/20 and Outpost market 290/400. |
| 29 | Rolling-stock protection | PASS | Actual locomotive (160,545) rejected Delete and BackSpace; wagon (270,545) rejected Delete; no Demolish control, train and route remained. |
| 30 | Factory icons stay scoped | PASS | Locomotive and Rail depot pages had appropriate titles/HP and no factory category icons. |
| 31 | Create division | PASS | Ctrl+A selected 35 combat units; walker card (47,764) selected 34 survivors; Form division (187,214) created Division 1, 34/34, Hold, Reinforce checked. |
| 32 | Division stances | PASS | Advance tooltip described 40-tile engagement; Advance (116,281), Screen (184,281), Hold (50,281) each updated pressed state and card. |
| 33 | Division orders | FAIL | Right-click (1050,478) visibly moved division; F then right-click (1050,278) showed Attack-moving then Idle, but formation stayed at the previous destination in 13:48–14:17 observations. |
| 34 | Select whole division | PASS | Used empty ground (300,228), because (200,228) overlaps panel; walker body (1104,303) selected all 34 and pressed Division 1. |
| 35 | Barracks reinforcement | PASS | Reinforces dropdown (120,237), Division 1 choice (107,279), retained Division 1; requested explanatory tooltip not captured. |
| 36 | Industrialisation | PASS | Exact research command succeeded; completion alert appeared and badge changed to start-the-Charter text after refresh. |
| 37 | Ledger and Charter start | PASS | L opened/closed ledger and Age I reopened it; Start at (753,353) worked and project began; gear row absent because step 15 failed; started-button text clipped. |
| 38 | Charter materials | PASS | Four exact grants succeeded; site at (464,475), left/below Capital, and badge showed rising progress (26% captured). |
| 39 | Reach Age II | PASS | Age II badge, completion alert/chat and unlocked industry observed by 15:51; exact 20-second countdown was missed during observation latency; no age recovery command used. |
| 40 | Steelworks production | PASS | One Steelworks produced, cumulative crafted 3/to network 2, then waiting for materials; Auto restored paused; incidental empty-ground click selected Depot 1. |
| 41 | Build Steelworks | PASS | All 14 Age II build entries enabled; Steelworks button (1190,768), site (640,236), ghost became orange building. |
| 42 | Steelworks controls | PASS | Steelworks #1602, HP 2500, no category icons; Auto ran Steel plates, Auto fixed it and Pause stopped/refunded inputs; 12 steel observed. |
| 43 | Ledger shortfall hint | FAIL | New-target item button (441,524) inserted RTS cursor; Make 10/Short 10 had no needs hint, so Plastic bar was unavailable; Outpost stocks and Auto 1/fixed 1 footer worked. |
| 44 | Drain copper | PASS | Copper cable recipe (105,765) ran; copper 100 → 98 at 20:05 → 0 at 20:57, yellow waiting-for-copper; Pause stopped production. |
| 45 | Army surcharge | PASS | Army 33 needed no extra spawn; copper 2 produced red +10% surcharge waiting line and rule tooltip; Armoured car enabled/cost tooltip; copper 50 deployed walkers, yellow +20% at Army 45. |
| 46 | Keyboard demolition | PASS | Delete armed red Press again, then expired; Delete twice removed barracks and showed alert; iron 157 → 187, copper 16 → 21 initially → 26 by 25:05 (delayed full refund). |
| 47 | City demolition | PASS | City button (978,449) armed all three red controls; second click removed city/stocks, all three alerts, Land 1.2%, cap 70 → 60; Depot 2 one hub, iron 200 → 240, copper 20 → 35, stone 0 → 20; rail remained. |
| 48 | End marker | PASS | F9, RTS_QA_END, Enter printed player: RTS_QA_END at 25:42; original QA match disappeared after inspection timeout; later observed a larger Russian loading/main-menu window without tester launch/restart. |

## Summary

**45 PASS, 3 FAIL, 0 SKIPPED — 48 steps recorded.** Failures: **15, 33, 43**. The match reached strip time **25:42** before the end marker. These are visual results, not log-confirmed engine behavior. The run is not a clean QA pass.

## Findings

### FAIL — Step 15: city target picker selects the RTS cursor

With Capital selected, clicked the empty Make targets item button at **(812,422)**. Instead of an item chooser, a row for **RTS cursor** appeared. Removed it with the row × at **(903,420)**, pressed Q to clear the cursor, and repeated the item-button click: the same wrong item returned. Removed the spurious row afterward. Iron gear wheel could not be selected, so Make 20 and Auto gear production were not verified. The factory was inspected and remained Auto/Paused. Expected: an item chooser allowing Iron gear wheel and a target of 20. Evidence: [qa-15.png](phase5-screenshots/qa-15.png).

### FAIL — Step 33: attack-move accepted without visible relocation

Formed a 34-walker division from survivors. Right-clicked **(1050,478)**: the division moved together and became Idle. Pressed F, then right-clicked **(1050,278)**: the message armed attack-move and the card changed to Attack-moving, then Idle. Comparing observations at **13:48**, **13:49** and **14:17**, the formation remained around its previous move destination instead of visibly relocating toward the second point. Expected: the whole division follows each order. This is a failed visual protocol action, not proof that all division attack-move orders fail; the second point was close to the large formation footprint, and no log/group-order inspection was performed. Transient order circles were not captured. Evidence: [qa-33.png](phase5-screenshots/qa-33.png).

### FAIL — Step 43: ledger target picker prevents Plastic bar/hint check

Opened the Age II ledger and clicked New target item button **(441,524)**. It inserted **RTS cursor**, with no chooser for Plastic bar. Set the row to **10**, verified Make 10 and Short 10, but no needs/material hint appeared. Ctrl+A did not replace the numeric field and temporarily produced 5010; **Cmd+A** corrected it to 10. Expected: Plastic bar, Make 10, Short 10, and a “needs [crude oil]: made nowhere” hint. Outpost selection showed iron 200/copper 20 with no targets; Capital footer correctly counted Auto 1/fixed 1. The unwanted Capital cursor target remained after this check. Evidence: [qa-43.png](phase5-screenshots/qa-43.png). This resembles the step 15 picker problem in a second UI.

### Usability and feedback

- The city kit is called **City Center** in the build/recipe UI, while the protocol calls it **City charter**. Consistent naming would make the recipe/build relationship easier to follow.
- Factory category icons are small and unlabeled until hovered. Large overlapping walker legs and bodies make precise single-unit clicks difficult; the whole-division selection did work when a visible body was located.
- A vanilla entity-information panel sometimes remained under/behind the minimap and was clipped. The started Railway Charter button also retained disabled text clipped at the right edge. No raw translation keys were observed during the English match.
- Nominal empty-ground clicks sometimes selected a depot or freight wagon; notably **(300,600)** selected a wagon despite the visible horizontal train being much higher. This suggests an unexpectedly large/misaligned selection area and makes deselection awkward; no engine hitbox inspection was done.
- “Enemies seen: ?” appeared during periods with nearby combat, making threat status difficult to interpret. No building-loss alert was observed before deliberate demolition.
- The barracks copper refund was delayed on the strip: 16 before demolition, 21 immediately after, then the expected 26 later. Do not diagnose a missing five copper from the immediate screenshot alone. [qa-46.png](phase5-screenshots/qa-46.png) is an additional diagnostic capture of that intermediate state, not a failed step.

## Deviations and coverage limits

- Game time continued while tools and screenshots ran. Fixed waits often overshot: rail observations at 10:16, 10:40 and 11:08 were not ten seconds apart; the freight observation covered about 67 seconds; final barracks production continued roughly 35 seconds and produced 12 walkers rather than a ten-second sample. Demolition disarm was checked after more than four seconds. The Charter countdown was missed, though 26% progress and later completion were captured. Some requested two-second hovers were shorter; visible tooltips, rather than elapsed duration, were verified.
- Five initial tiny wheel inputs in step 6 did not change scale; calibrated to **0.1-page scroll calls**, then used five effective notches out/back. Tiny wheel inputs also positioned the hover pointer.
- The first spawn command entered through simulated typing was malformed and produced **Unknown command “-”**. Retried the exact command by paste, then used paste for subsequent console commands. F9 worked. Ctrl+A worked for army selection but not numeric text selection; Cmd+A worked for the latter. No Fn fallback was needed.
- Outpost placement used the protocol recovery: the initial zoomed-out point was fogged, then obstructed by a tree after scouting. Final site **(100,590)** was southwest of Capital, away from AI territory. No restart or extra material recovery commands were needed.
- Other notable position adjustments: hauler **(651,508)**; moved train locomotive **(160,545)** and wagon **(270,545)**; empty ground **(300,228)** instead of the panel-covered suggested point; walker **(1104,303)**. The Charter Start button was **(753,353)** because the ledger differed after the failed gear target.
- City founding and rail-open transient alerts, intermediate hauler transit text, all train travel-state transitions/circles, the optional construction-train detail panel, the barracks reinforcement tooltip, and exact Charter countdown were not captured. Completed structures, line-open status, tank values, delivery totals and Age II outcome were observed.
- Step 48 closure is inferred from loss of the original QA window/match: after the marker and ten-second wait, bound-window AX inspection timed out. A later read-only screenshot showed a **1920×1080 Russian loading screen**, then the Russian main menu. The application inventory still listed Factorio running. The cause of this apparent external reload/relaunch was not inspected; the tester issued no launch/restart/quit command. The original QA session was gone, so the fallback end chord was not sent to the unrelated main-menu state. No crash dialog was observed during testing.

## Attacks and final state

Times below are observed strip times, not exact unseen attack starts. The GUI observations cannot distinguish every separate AI wave.

| Time | Observation and outcome |
|---|---|
| By 12:02 | Two walker death-feed entries used locomotive icons, and Army fell from 38 to 36; possibly freight collisions, not confirmed as AI attack. The division subsequently contained 34 walkers. |
| 15:51–16:37 | Fighting/health bars appeared at the right of Capital; Army fell to 34 and Division 1 to 32/34. No building destruction observed. |
| 18:40–19:50 | Enemy Raider death entries at 18:40 and 18:57; nearby enemies later counted 2. F3 at 19:11 centred the latest Charter event, so Space restored Capital; Ctrl+A, F, right-click (1200,478) at about 19:50 sent defenders toward combat. One first input attempt was rejected after a foreground-state change and was retried after a fresh observation. |
| 20:57–22:23 | Army 33, division 31/34; Commander alive, level 2, initially 8 kills, later 11. Small contacts showed Enemies seen 2–3 around 21:45–21:47. Barracks replacements restored division 34/34, Army 45. |
| 24:36–end | Commander alive at level 2, 14/15 kills displayed; Army 45, division 34/34. No non-deliberate building loss or Commander death observed. |

Final pre-end state after deliberate barracks/Outpost demolition: **Age II; Army 45; Supply 43/60; Land 1.2%; Capital 441 cells; iron 187, copper 26, steel 12 on the strip; Depot 2 iron 240, copper 35, stone 20, coal 67; rail line open 57 tiles/38 rails.** Hauler tank was 4 after reaching Outpost, 0 on the return-home observation. First freight delivery was **200 iron and 20 copper**, Trips 1.

## Console record

Commands are listed in entry order. Successful give replies reported the exact requested amount/item into the **rts-player pool**.

| Entry | Command / input | Observed reply |
|---:|---|---|
| 1 | Malformed first typing attempt for `/rts-spawn rts-walker 30` | Unknown command “-”; no spawn, retried. |
| 2 | `/rts-spawn rts-walker 30` | 30 × rts-walker for rts-player near (-489.0,85.0). |
| 3 | `/rts-give stone 40` | 40 stone into pool. |
| 4 | `/rts-give electronic-circuit 10` | 10 electronic-circuit into pool. |
| 5 | `/rts-give coal 200` | 200 coal into pool. |
| 6 | `/rts-research rts-railways` | rts-railways researched for rts-player; completion alert. |
| 7 | `/rts-give rts-depot 2` | 2 rts-depot into pool. |
| 8 | `/rts-give rts-locomotive-kit 4` | 4 rts-locomotive-kit into pool. |
| 9 | `/rts-give rts-cargo-wagon-kit 2` | 2 rts-cargo-wagon-kit into pool. |
| 10 | `/rts-give rts-construction-wagon-kit 1` | 1 rts-construction-wagon-kit into pool. |
| 11 | `/rts-give rail 400` | 400 rail into pool. |
| 12 | `/rts-give iron-plate 300` | 300 iron-plate into pool. |
| 13 | `/rts-research rts-industrialisation` | rts-industrialisation researched for rts-player; completion alert. |
| 14 | `/rts-give steel-plate 100` | 100 steel-plate into pool. |
| 15 | `/rts-give electronic-circuit 115` | 115 electronic-circuit into pool. |
| 16 | `/rts-give iron-gear-wheel 100` | 100 iron-gear-wheel into pool. |
| 17 | `/rts-give stone 190` | 190 stone into pool. |
| 18 | `/rts-give copper-plate 2` | 2 copper-plate into pool. |
| 19 | `/rts-give copper-plate 50` | 50 copper-plate into pool. |
| 20 | `RTS_QA_END` | Chat: player: RTS_QA_END, at 25:42; QA match subsequently disappeared. |
