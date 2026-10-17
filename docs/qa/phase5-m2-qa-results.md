# Phase 5 M2 GUI QA results

Date: **2026-10-17**. Build: **80c05d2** (user-specified build; not independently inspected). Client: **Factorio: Space Age 2.0.77**, English, 1280×800 game area on macOS.

Read the complete tester protocol before testing, excluding the lead launch procedure, and used the M1 report as the format reference. Steps 1–31 were addressed in order in the already-open game. No source, logs, process inspection, other application interaction, manual launch, close, or restart was used. File access was limited to reading the protocol/report reference and writing this report and screenshots. All game control used screenshots, mouse, keyboard, and the protocol's in-game console commands.

Coordinates below are **window coordinates, including the 28 px title bar**; subtract 28 from y for protocol game-area coordinates. PASS records the main observed functional result, with missing subchecks explicitly stated; it does not certify every transient state or exact screenshot interval. SKIPPED means a prerequisite prevented completion, even where initial inputs were attempted. Screenshots were taken throughout; saved failure evidence is linked below.

## Step results

| Step | Name | Result | Observation |
|---:|---|---|---|
| 1 | Nation lobby | PASS | Selected Nation at (585,385); Victory Conquest, Time limit unlimited, World 1536×1536, disabled World map and the correct peace/capital/Victory hint appeared. |
| 2 | Victory and time limit | PASS | Lists showed Conquest/Territory/Score and 60/90/120 min/unlimited; reselected Conquest (585,472) and unlimited (585,561). |
| 3 | Nation help | PASS | F11 opened all eight Nation paragraphs, including Keys; page fit without scrolling and × (862,213) closed it. |
| 4 | Start | PASS | Start (739,568) opened Capital with treasury ₡1,500 and Conquest/unlimited goal; Land 1.3%, Supply 6/40, Army initially 6 then 7 by 00:05. |
| 5 | Market entry points | PASS | Treasury (840,72) and M both opened Market; Normal, Solvent, no-port warning, Commerce 0/300, goods and contracts showed; second M closed it. |
| 6 | Army shortcut | PASS | Exact command replied 30 walkers near (501.0,17.0); three rows appeared, Army 37 and Supply 36/40. |
| 7 | People, priorities, draft | PASS | Capital showed Residents 200/200, Happiness 100, both needs 100%, workforce/recruits; nine priority families appeared, Power ▲ (994,540) swapped Power/Military; draft list offered 0/10/20/30/50%, and 30% persisted. |
| 8 | Staffing and Pin | PASS | Factory placed at (448,332), built; Staff 100%: 12.0 of 12 workers · Capital · Services; Pin (298,714) changed to Unpin after the wait. |
| 9 | Nation build menu | PASS | Production showed the expected seven top-row/four second-row icons, including disabled Apartment; Economy showed disabled Rail depot/Rail works; icon identities followed protocol ordering, without hover verification. |
| 10 | Port capture | PASS | First listed port #335 captured successfully; green alert read “Linmere Marsh: Port captured: Port of Linmere Marsh.” |
| 11 | Sale and tax | PASS | Steel Sell (770,544) reduced stock 300→200 and balance rose ₡1,524→₡1,820; exports/Commerce 294/450, price 3.30→3.24; High selected, net later +311 versus +306, then Normal restored. |
| 12 | Diplomacy at peace | PASS | F4 showed AI 1 Peace, opinion +1, four capturable city-states and no current war/proposal; Free City of Serrin/Torrith/Vinilin/Karwick names fit without ellipses. |
| 13 | Declare war | PASS | War button was (736,388), 38 px right of protocol; AI state became War, opinion −29, score +0/weariness 0%, with “Tharwick Plains: War on AI 1. Our goal: capture Capital.” |
| 14 | Division | PASS | Walker card (47,764), Form division (187,194) created Division 1, 36/36, green health and full blue supply bars. |
| 15 | Low/zero supply | PASS | 30 SP showed an approximately 30%-length amber bar; zero showed red OUT OF SUPPLY; F/right-click (1200,620) refused all 36 units with visible resupply text and no movement. |
| 16 | Resupply | PASS | Twenty crates accepted; supply reached 19 at 04:21 and 25 at 04:42, approximately one-quarter amber; retry at (1200,620) showed Attack-moving and relocation, then right-click (640,520) returned the division. |
| 17 | Rail research and stock | PASS | All seven commands succeeded; Railways completion alert appeared, Rail depot showed 2, Rail works unlocked; optional factory Logistics inspection not performed. |
| 18 | Two depots | PASS | Depots at (288,428)/(992,428) built with platforms; Depot 1 reported 40 tiles/2 stops, locomotive 4, construction 1, rails 300, coal 200, troop wagons 2; shared Network #20 had 3 hubs. |
| 19 | Rail line | PASS | Closed rail panel × (992,227) to expose Depot 2, then right-clicked (992,428); “Keltor Plains: Rail line open” appeared and reopened panel showed green open, 4 tiles/6 rails, 2 pieces/0 missing/0 supports/2 signals; construction animation was not captured. |
| 20 | Deploy/route troop train | FAIL | Enabled Deploy troop train (818,372), located below freight, returned “Cannot deploy a train: the train does not fit on the platform”; no train was available for panel/route checks at this step. |
| 21 | Embark/ride/drop-off | SKIPPED | Missing train from step 20 prevented ride/drop-off; name (50,219) and right-click Depot 1 were still attempted: 36 walkers gathered there, card stayed Boarding a train from 06:41 through 07:53, no observed riders. |
| 22 | Minimap and city-state army | PASS | N showed world and regional modes with the expected chat replies; goto reached (27.0,116.0), 484 tiles away; 40 walkers spawned at Free City of Serrin and turrets fired. |
| 23 | Capture | PASS | Ctrl+A, F/right-click center (640,428) led to capture alert at 08:51; center survived and city list gained Free City of Serrin, Town/232 cells, Land 2.0%; intermediate Subdued/percentage readings were missed between screenshots. |
| 24 | Under attack and Jump | PASS | Scripted raid triggered Capital warning triangle and red Under attack row; minimap (1147,67) moved away, Jump (986,247) centered the damaged left depot; warning later cleared, CC remained 3000/3000; enemy death animation not observed. |
| 25 | Accept peace | PASS | Peace proposal #3 appeared below an unsolicited ceasefire; accepted white-peace row at (744,201), 20 px below normal row; green Tharwick Plains peace alert and F4 AI 1 Peace/no wars verified. |
| 26 | Strategic labels | PASS | Wheel zoom showed readable Keltor Plains, Eldgarth Heights, Belo os/Beloos Marsh, Talmor Fens and Ostholm Hills labels, resource icons and blue/neutral outlines; depot labels overlapped Capital; returned to game view and restored original scale before step 29. |
| 27 | Region names in alerts | PASS | Port, war, rail-open, capture, raid, peace and later territory/tier alerts carried region prefixes; Railways research did not; no alert ellipsis was observed in the sampled lines. |
| 28 | Bin disband | PASS | Raider card (72,770) selected exactly 3; bin (378,742) armed with chat message and yellow state, second click within 3 s removed all three; Army 68→65, “0 recruits went home.” |
| 29 | Persistent info box | FAIL | Lab placed at (832,332), built by 12:18; after Q and pointer moved to verified empty ground (200,628), vanilla Lab box remained behind/below minimap throughout 11:54–13:06, over 60 seconds. |
| 30 | Single Delete | PASS | Walkers were offscreen after Space; right-clicked Division 1 name (50,237) to locate them, deselected and clicked walker (625,253); Walker ×36, Delete armed only; after >4 s and deselection Army 65/division 36 remained. |
| 31 | End marker/window closure | FAIL | F9 and exact RTS_QA_END printed “player: RTS_QA_END” at 13:46; QA match disappeared, but next observation showed loading and then a different 00:00 match rather than confirmed closed window; no input sent to replacement session. |

## Summary

**27 PASS, 3 FAIL, 1 SKIPPED — 31 steps recorded.** Failures: **20, 29, 31**. The tested match reached **13:46** before the end marker. This is not a clean QA pass. Step 31 is a session/harness outcome discrepancy, not a diagnosed gameplay defect. Step 21 lacked its train prerequisite; step 23's capture outcome passed but capture-progress text remains unverified.

## Findings

### FAIL — Step 20: enabled troop deployment refuses the prescribed platform

Research Railways and grant the exact step 17 stock. Place depots at **(288,428)** and **(992,428)**, wait for construction, select the left depot and right-click the right depot. The line reported **open, 4 tiles, 6 rails** and **40-tile platforms**; its detail also said **“the train does not fit on the platform.”** Click the enabled **Deploy troop train** button at **(818,372)**. Chat reported **“Cannot deploy a train: the train does not fit on the platform”**; no new train was visible. Kits remained locomotive 4, construction 1, troop wagons 2; coal 200 and rails 298 were available. Expected: deploy the troop train, inspect its Troops 0/32 panel, and assign pickup/drop-off. Evidence: [m2-qa-20.png](phase5-screenshots/m2-qa-20.png).

The two 40-tile platforms appeared collinear with a short connecting gap; geometry may be relevant, but no implementation was inspected. Step 21's embark command still displayed **Boarding a train** and walked units to the platform, with no ride observed through 07:53. Evidence: [m2-qa-21.png](phase5-screenshots/m2-qa-21.png). No no-room-for-platform or missing-resource recovery condition occurred.

A train appeared later at **09:35**, following the raid-response Ctrl+A/F/right-click at **(640,620)** after Jump had centered the left depot. Both divisions then read Boarding a train, despite the click being visually below the rails, and the F attack-order hint remained armed. A second division of 28 appeared without an explicit Form division click. This late behavior suggests an embark/depot action was triggered, but its cause was not verified. It does not establish that the step 20 button succeeded or that anyone rode to Depot 2. No train route was assigned in this later state.

### FAIL — Step 29: vanilla Lab info box persists after Q and empty-ground input

Grant one lab, select Production/Lab, place at **(832,332)**, press Q, and move away. The protocol's **(300,628)** selected the Commander, so used verified empty ground **(200,628)** and began the no-input observation there. At **11:54**, **12:18**, **12:36**, and **13:06**, the dark vanilla Lab panel remained at the top right, partly behind the minimap. Visible text included **Health: 600/600**, **Consumes electricity**, and **Max. consumption: 60.0 kW**. The lab changed from ghost to built, but the panel persisted for **72 seconds** with nothing selected and the pointer unmoved on empty ground. Expected: no persistent entity info box. Evidence: [m2-qa-29.png](phase5-screenshots/m2-qa-29.png).

The same symptom appeared earlier with Factory and Rail depot boxes; changing selections/console actions sometimes eventually cleared or replaced them. No raw locale key was observed.

### FAIL — Step 31: marker ends original match, but window closure not observed

Opened F9, pasted **RTS_QA_END**, Enter; chat showed the exact marker at **13:46**. After a ten-second wait, the Factorio observation took about seventeen seconds and returned a loading screen. A later screenshot showed a different terrain and **00:00** match with initial resources, rather than a closed application window. Evidence: [m2-qa-31.png](phase5-screenshots/m2-qa-31.png).

The tester did not launch, close, restart or reset Factorio. The original QA session had already disappeared, so the fallback Ctrl+Shift+E was not sent into the replacement loading/new-match state. Closure/relaunch versus an internal reload cannot be distinguished from these screenshots. The end marker was delivered; the protocol's literal window-closure criterion remains unconfirmed and is conservatively recorded FAIL.

### Usability and feedback

- **Persistent entity descriptions overlap the minimap** and are partly hidden behind it. This occurred with Factory, Rail depot and Lab.
- **Enabled deployment despite a known fit problem:** the panel states the train does not fit but leaves Deploy troop train enabled. The click gives an error, with no visible explanation of how to repair platform geometry.
- **Boarding without a visible train:** the card stays Boarding a train rather than explaining that no train is available. The later depot/embark hit near empty-looking ground was unexpected.
- **Dense unit sprites and broad selection areas:** overlapping walker bodies make clicks difficult; (300,628) selected the Commander when trying to move to empty ground. Jump and selection recovery were needed to find a walker for step 30.
- **Icon-only building menus** are difficult to verify by name without hover. The prescribed slot layout was present, but this is weaker evidence than visible text labels.
- **Strategic label overlap:** raw-looking internal depot identifiers such as “rts-player depot 1127” overlapped Capital/Keltor Plains. These are internal labels, not confirmed missing locale keys. Full city/port/choke-label coverage was limited by fog and viewport.
- **Offer countdown stale between updates:** the unsolicited ceasefire displayed “119 s” at 08:51, 09:04, 09:35 and 10:22, then changed to 24 s when the scripted peace offer arrived at 10:25. It remained available briefly after white peace ended the war.
- Diplomacy's **War** action was **38 px right** of the protocol position. Growing rows moved Deploy troop train to y=372 and white-peace Accept to y=201; these were found visually instead of skipped. City-state names were not cut off in diplomacy. The Capital name field appeared blank even while the title/list named Capital.
- No raw translation keys or wrong-language text were seen during the tested match. Alert text sampled here fit without ellipses; some long feedback near the right edge was cramped.

## Deviations and coverage limits

- Tool/model latency made several fixed observation intervals longer than requested. Factory construction was checked at 01:13 after placement at 00:43. Resupply ran from about 03:26 to 04:42 (76 s); the intended 70-second sample therefore read 25 rather than about 20 SP.
- Step 21 screenshots were at 06:41, 07:05, 07:28 and 07:53 instead of every 15 seconds; no train existed during this observation. No passenger count, train panel, route, travel or unloading was verified.
- Step 23 attack was observed at 08:20 and capture at 08:51. **Subdued and Capture by You: N% were not captured**, so no numeric progress readings can be reported. Final city ownership/list entry was verified by 09:04. Evidence: [m2-qa-23.png](phase5-screenshots/m2-qa-23.png).
- Step 24 raid was spawned around 09:07; first screenshot was 09:21, showing the warning and a damaged depot but no visible enemies. Jump landed on the depot, not the CC. The subsequent intended attack click triggered Boarding a train instead; X later cleared orders. The CC survived and warning cleared, but exact raid deaths and the scripted defensive attack were not verified.
- Step 29's nominal 10/30/60-second screenshots landed at approximately **24/42/72 seconds** after verified empty-ground positioning. No UI inputs occurred during that observation. The persistent box was visible throughout.
- Single Delete expiry was inspected after more than four seconds, never confirmed with a second Delete.
- Wheel calls used 0.1-page increments. After strategic zoom, equal inverse calls initially left the view enlarged; two extra downward increments restored the original 112-px stockpile separation before lab placement.
- F4, F9 and F11 worked; no Fn or alternate console binding was needed. No manual reset, extra resource recovery command, hover action or lead log check was used. Incidental tooltips appeared after clicks but were not needed for the protocol's hover-free pass criteria.

## Attacks and final tested state

| Observed time | Event and outcome |
|---|---|
| 08:10–08:51 | City-state turrets fired on spawned walkers; Army peaked at 77, fell through 68 to 65; Free City of Serrin captured, center survived, 28 of the 40 new walkers remained by the later division count. |
| Around 08:50 | AI 1 independently offered a ceasefire; left unanswered. |
| Around 09:07–09:34 | Four scripted AI walkers spawned at Capital; alert named Keltor Plains and Rail depot; left depot visibly damaged, Capital 3000/3000. Under attack age 14/25/27 seconds observed; Jump worked. |
| By 10:22 | Warning triangle and row absent; no red attackers visible, Enemies seen 0. No nonscripted AI assault was positively identified. |
| 10:38 | Scripted white peace accepted; F4 confirmed AI 1 Peace and no wars. |
| 11:24 | Captured Serrin shrank from Town to Village: territory-loss 119 cells alert, remaining 113 cells, Land 1.7%, cap 70. |

Final original-match state before marker: **Age I, Army 65, Supply 64/70, Land 1.7%, Capital Town/441 cells and Free City of Serrin Village/113 cells; Division 1 36/36 and Division 2 28/28; treasury about ₡1,832 (−13/min); iron 400, copper 150; factory and lab built; both depots and rail line present; AI 1 at peace.** No crash dialog or sustained stall was seen before the end marker.

## Console record

Every entry used F9, exact paste, Enter. Replies below were read on screen; no logs were checked.

| Entry | Command/input | Observed reply |
|---:|---|---|
| 1 | `/rts-spawn rts-walker 30` | 30 × rts-walker for rts-player near (501.0,17.0). |
| 2 | `/rts-market ports` | Port #335 at (−524.0,628.0), owner nil; #638 at (564.0,628.0), owner nil; player/AI port and commerce summaries, AI envoy #213. |
| 3 | `/rts-market capture 335` | market: capture → true; Linmere Marsh port alert. |
| 4 | `/rts-supply 30` | 1 division of rts-player set to 30 SP. |
| 5 | `/rts-supply 0` | 1 division of rts-player set to 0 SP. |
| 6 | `/rts-give rts-supply-crate 20` | 20 × rts-supply-crate into rts-player pool. |
| 7 | `/rts-research rts-railways` | rts-railways researched for rts-player; Research complete: Railways. |
| 8 | `/rts-give rts-depot 2` | 2 × rts-depot into rts-player pool. |
| 9 | `/rts-give rts-locomotive-kit 4` | 4 × rts-locomotive-kit into rts-player pool. |
| 10 | `/rts-give rts-troop-wagon-kit 2` | 2 × rts-troop-wagon-kit into rts-player pool. |
| 11 | `/rts-give rts-construction-wagon-kit 1` | 1 × rts-construction-wagon-kit into rts-player pool. |
| 12 | `/rts-give rail 300` | 300 × rail into rts-player pool. |
| 13 | `/rts-give coal 200` | 200 × coal into rts-player pool. |
| 14 | `/rts-goto city-state` | city-state at (27.0,116.0), 484 tiles. |
| 15 | `/rts-spawn rts-walker 40` | 40 × rts-walker for rts-player near (27.0,116.0). |
| 16 | `/rts-spawn rts-walker 4 rts-ai-1` | 4 × rts-walker for rts-ai-1 near (501.0,17.0). |
| 17 | `/rts-diplomacy propose rts-ai-1 rts-player peace` | proposal #3 peace rts-ai-1 → rts-player. |
| 18 | `/rts-spawn rts-raider 3` | 3 × rts-raider for rts-player near (501.0,17.0). |
| 19 | `/rts-give rts-lab 1` | 1 × rts-lab into rts-player pool. |
| 20 | `RTS_QA_END` | player: RTS_QA_END at 13:46; original match subsequently disappeared. |
