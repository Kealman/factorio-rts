# Phase 5 M3 GUI QA results

Date: **2026-10-23**. Build: **dad7a40** (user-specified; not independently inspected). Client: **Factorio: Space Age 2.0.77**, English, 1280×800 game area on macOS.

Read the tester protocol in full before testing, excluding execution of the lead launch block, and read the M2 report as the format reference. Addressed steps 1–30 in order in the already-open Factorio window. All game interaction used computer-use screenshots, mouse, keyboard and the prescribed console shortcuts/recovery. No source, logs, processes or other application were inspected; Factorio was not manually launched or closed. File access was limited to the protocol/reference report and writing this report and screenshots.

Coordinates are **window coordinates, including the 28 px title bar**; subtract 28 from y for protocol game-area coordinates. PASS means the step's principal functional criterion was observed; missed transient details are disclosed below. FAIL includes an unverified required outcome, not necessarily a diagnosed product defect. Only PASS, FAIL and SKIPPED are used, as requested. Screenshots were captured throughout; one per step plus artillery recovery evidence is saved in `phase5-screenshots/m3-qa-*.png`.

## Step results

| Step | Name | Result | Observation |
|---:|---|---|---|
| 1 | Nation lobby | PASS | Mode Nation selected at (596,384); Nations 2, Normal, World 2048×2048, disabled World map, Explore, Conquest + Space, unlimited and the 4096-chunk/about-2-min generation text appeared. |
| 2 | Lobby lists | PASS | All four lists showed the prescribed entries: nations 2–6, worlds 2048/3072/4096, Explore/Survey and five victory choices; original values were restored. |
| 3 | Lobby help | PASS | F11 opened a scrollable page; scrolling over (640,428) reached Age III and money, Fronts and fortifications, Air and Keys with Y/F/B/H, without right-edge clipping. |
| 4 | Start 2048 | PASS | Space Program/unlimited goal and Age I appeared; generation rose from 8% at 00:05 to 10% at 00:15, later 36%, 48%, 62%, 77–80%, then disappeared. |
| 5 | Age III research gates | PASS | Exact shortcuts succeeded; Age II badge, Electrification Done, Aviation Available and Chemistry/Nuclear power/Air Force Needs Age III were visible; treasury reply was 21,519. |
| 6 | Start Space Program | PASS | Start at (683,340) produced stage 1, Rush/bar and a launch complex southeast of CC near (768,668); its stage label was visible after closing the ledger in step 8. |
| 7 | Stage goods and Rush | PASS | Goods advanced from 0/60,10/100,30/200 to 60/60,100/100,160/200; Rush at (748,344) became Stop rush (₡0/min), with steel then 180/200. |
| 8 | Age III | PASS | Label showed stage-one countdown of 20 s; next sample at 01:48 showed Age III and Space Program 2/3: 0%. |
| 9 | Steel works jobs | PASS | Steel works placed at (448,524), selected at (456,532); Staff 100%:16.0 of 16 workers · Capital · Metallurgy; CC showed 16 of 16 filled jobs. |
| 10 | Automation | PASS | Metallurgy at (458,377) gained a green check; staffing fell to 7.8 of 7.8 and CC showed 8 of 8 jobs,112 free,recruits113. |
| 11 | Rare extractor | PASS | Northeast deposit at world (310,553); extractor placed (832,220), selected (840,228), Working with 4 workers; ledger showed +25% explosives and munitions (89 s); transient bonus alert was not captured. |
| 12 | War | PASS | War at (736,388) changed AI 1 Peace→War, opinion −10→−40 and displayed “Ultor Plains: War on AI 1. Our goal: capture Capital”; four city-state names fit. |
| 13 | Front | PASS | Shortcut founded town 7 at (413,566),115 tiles east,1 segment [#2 80 t52]; dashed front and small Front 2 · threat 52 label appeared; oversized duplicate label was briefly clipped at right. |
| 14 | Division / Hold line | PASS | Walker card (50,764),Form division (187,194),Hold line (194,310) created 22/22 Division 1; card read Holding the line (front 2), label named Division 1 and walkers spread vertically along the front. |
| 15 | H | PASS | X showed Idle; pointer placed near front at (980,450) using a minimal wheel input, then H restored Holding the line; formation remained along the line. |
| 16 | Fort belt | PASS | F opened tool; right-clicks (320,300)/(320,556) gave 2 points,16 tiles and bill depot1/turret1/wall17; Build (710,314) planned19, showed2/19 waiting transiently, then wall/turret/depot were built by07:39. |
| 17 | Airfield / Y | PASS | Airfield at (832,332) built with hazard rim/apron/hangar; page named Capital and0 nearby planes; three scouts spawned, selected via second card (50,764) because walkers had died; Y showed3 total/ready,selected3,supply93. |
| 18 | Patrol / Return | PASS | Patrol (957,441) armed orange prompt; right-click (400,278) showed Order:Patrol and moving scouts; Return (1047,441) showed Returning, then3 near airfield and supply100–100 at09:58. |
| 19 | AA shoot-down | FAIL | AA at (512,556) had10 magazines; bomber spawn hit it at10:46; by11:05 Bomber×(AI1) appeared but AA was wrecked and Commander kills rose0→1; AA firing/kill attribution was not established. |
| 20 | Artillery deployment | PASS | East depot (992,428) built a40-tile/2-stop platform; exact kits/shells/coal were shown, freight/troop disabled as expected; Deploy artillery train (825,445) spawned two locomotives and gun wagon. |
| 21 | B / artillery target | FAIL | Train6 selected at (991,529); B lit Bombard but after45 game seconds showed “Shells:20 · no hostile building within120 tiles”; recovery Depot2 at (992,332) and redeployed Train13 produced the same gun line. |
| 22 | Hire | PASS | Hire (837,616) reduced treasury21,885→21,725 exactly160; garrison row gained4points/1gun and button remained. |
| 23 | Mercenaries | PASS | First port#317 captured; Mercenaries (380,314) created Mercenaries(Verrin)8/8, green8-hired alert and600-second cooldown; balance fell about600 with intervening income. |
| 24 | City-state Buy | PASS | Trade at (800,294) listed own port plus Eldan/Ostlin/Ashdor/Ysdor; selected Eldan (800,335), bought100 copper at (821,542),stock400→300,relation+0→+1; capital copper later150→250. |
| 25 | Research Rush | PASS | Chemistry Research (1175,459) showed Researching:Chemistry(0%); Rush (1155,222) became Stop rush(₡0/min); Chemistry/Nuclear power available and Air Force Done. |
| 26 | Strategic labels | PASS | Map showed blue Capital/Eskholm Plains,red Ironford and Front2·threat64; Depot1/Depot2 readable with stop markers and no raw station names in inspected view; Division1 suffix absent after its elimination. |
| 27 | In-match help | PASS | F11 and scroll reached the same Keys paragraph; page remained inside window,closed with×(862,117). |
| 28 | Six-nation 4096 lobby | PASS | F10 menu showed correct two-line settings; Restart (533,473) opened Nation lobby; chose6,4096,Survey and verified16384chunks/about7min generation text. |
| 29 | 4096 generation | PASS | New Age I match at00:00 showed2% generated; next captured sample at01:28 showed23% and expanded Survey minimap; exact30-second sample was missed. |
| 30 | End marker / closure | FAIL | F9/exact RTS_QA_END/Enter displayed “player:RTS_QA_END” at02:04; subsequent bound-window screenshot and state observations timed out, so disappearance within10s could not be verified; no further input sent. |

## Summary

**27 PASS, 3 FAIL, 0 SKIPPED — 30 steps recorded.** Failures: **19, 21, 30**. All prescribed sections were exercised. This is not a clean QA pass. Step19 lacks proof of the required AA firing/shoot-down; step21 reproduced a no-target outcome after recovery; step30 is an observation/closure-verification failure, not a diagnosed end-marker defect.

The first match reached approximately **24:41** before Restart; the six-nation match reached **02:04** when the end marker was sent. No sustained in-game stall or crash dialog was seen. No replacement Factorio session was observed or controlled.

## Findings

### FAIL — Step 19: bomber dies, but AA shoot-down is not established

Research Aviation/Air Force, grant one AA turret, place it at **(512,556)** beside the Steel works and wait. Its page showed **AA turret #1320**, HP1000/1000, **Magazines:10**, and the plane-only firing/network-magazine description. Spawn the exact `/rts-spawn rts-bomber 1 rts-ai-1` from the capital camera. At **10:46**, the bomber appeared near **(424,592)** and an explosion covered the AA turret; the alert named **Eskholm Plains: Base under attack: AA turret**. A projectile trail was also visible near the Commander, but the screenshots did not establish AA-origin tracers.

By **11:05**, the kill feed showed **Bomber × (AI1)**, Enemies seen returned to0, the AA site appeared as a wreck, and the Commander's kill counter had changed from0/5 to1/5. Clicking the former AA site at11:20 produced no building selection/page. Expected: visibly firing AA and bomber death attributable to that defense. Bomber death alone is insufficient to certify this step. Commander credit suggests interference but does not prove whether AA inflicted any damage. Evidence: [m3-qa-19.png](phase5-screenshots/m3-qa-19.png).

### FAIL — Step 21: artillery cannot find the nearby eastern hostile town

Declare war and run `/rts-front`: reply gives **town7 at(413,566),115tiles east of capital**, segment2/threat52. Capital is **(298,566)**, confirmed by later spawn replies. Give the exact railway research and stock. Place Depot1 **22tiles east**, window **(992,428)**. Deploy succeeds on its40-tile platform. Select the first locomotive at **(991,529)**: Train6, HP1000/1000,coal20,Position:Depot1,Hold fire,Shells20·fired0.

Press B. Bombard turns yellow without closing the build menu. At13:11 the line is looking for a target; at13:56 it reads **“Shells:20 · no hostile building within120tiles.”** No target name or spent shell was observed. Evidence: [m3-qa-21.png](phase5-screenshots/m3-qa-21.png).

Executed the specified recovery: gave another depot and placed it at **(992,332)**, still22tiles east and6tiles north, avoiding the original building. After construction, selected the train and right-clicked Depot2. The panel changed to **Position:Depot2** and **no path(line cut?)**, although the train remained visibly at Depot1. With no line, followed the protocol's explicit “Disband and Deploy at the new depot” instruction. Disband returned only one locomotive kit; the new depot showed locomotive1,artillerywagon1,shells40,coal100 and disabled artillery deployment. Repeated `/rts-give rts-locomotive-kit 2`, deployed Train13 on Depot2's vertical platform, selected it at **(1104,330)**, and pressed B. By17:00 it again read **“Shells:20 · no hostile building within120tiles.”** Evidence: [m3-qa-21-recovery.png](phase5-screenshots/m3-qa-21-recovery.png).

Both depots are on the town-facing side; this is not evidence of the protocol's suggested wrong-side placement. Visibility, target eligibility or range calculation was not diagnosed. The optional minimap inspection of shell impacts was not performed because no shot was observed.

Automatic approval review initially rejected the recovery Disband click, saying it was destructive and not clearly authorized. Re-read protocol Recovery lines698–700, which explicitly prescribe it when no line exists. Retried with that authorization established; the click succeeded. No recovery remains blocked by that review.

### FAIL — Step 30: exact marker delivered, closure timing unverified

In the new4096 match, open F9, paste **RTS_QA_END** without a slash, Enter. Chat visibly showed **player:RTS_QA_END** at **02:04**, with generation32%. Evidence: [m3-qa-30.png](phase5-screenshots/m3-qa-30.png).

After a5-second explicit wait, the bound-app screenshot request failed with **Computer Use server error -10005:timeoutReached**. A subsequent bound-window state request also timed out. These observations are consistent with an unavailable/closed window but do not prove the protocol's disappearance-within-about10seconds criterion. Conservatively FAIL for verification, not a claim that the marker failed. No Ctrl+Shift+E was sent into an unobservable window: the QA match could already have gone, and the user prohibits touching any replacement agent's session. No app reacquisition, launch,close or other application interaction followed.

### Usability and feedback

- **Oversized duplicate front text:** immediately after `/rts-front`, a huge red fragment of the front label was clipped at the right edge while the normal small label remained readable. It later vanished at that zoom but reappeared during intermediate map zoom. Evidence: [m3-qa-13.png](phase5-screenshots/m3-qa-13.png). The full strategic-map label was readable.
- **Dense map labels:** Capital,Eskholm Plains,resource icons and depot stop markers overlap near the capital. Depot1 andDepot2 remain readable at suitable zoom; no raw `rts-player depot N` names appeared in the inspected map. Evidence: [m3-qa-26.png](phase5-screenshots/m3-qa-26.png).
- **Train “Position” is misleading after a failed move:** the panel immediately said Depot2 while the carriages remained on Depot1 with no path. The label appears to convey destination in this state.
- **Artillery deployment prerequisites lack specific feedback:** after disband, one locomotive kit was present and deployment was disabled; the only yellow warning was about freight/troop trains having no kits. No visible artillery-specific message explained that two locomotive kits were needed.
- **Large unit bodies and small air sprites:** walkers obscure nearby ground/buildings, while scout sprites are tiny at normal zoom. Selecting scouts by the unit card was reliable; the expected third card moved to second after all walkers died.
- **Icon-only build choices and fort bill:** most building identities and bill components have no persistent caption in the menu. Identification relied on prescribed slots and subsequent clicked building pages; incidental tooltips were not used as pass evidence.
- **Panels can cover existing panels or map objects:** the ledger initially hid the launch-complex label; city/hub panels remained behind the ledger when the suggested empty-ground click hit the existing city panel at(1000,278). Used truly empty ground(300,428)/(300,228) when needed. Air panel stayed below the minimap.
- **Help wording:** the help's general Keys sentence says “Delete demolishes ... (press twice)” although the displayed selection UI was not tested for deletion here; no new deletion defect is asserted.
- No raw translation key, “Unknown key”,wrong-language caption or persistent vanilla entity-information box was observed. Main tested button captions fit. Generation text was dim but readable.

## Deviations and coverage limits

- Observations followed screenshots and visible captions. No step was skipped for a coordinate mismatch. Most controls matched protocol positions plus28px title bar. Restart was at(533,473),7px below adjusted expected position. The rare patch center was(832,220),not exactly the suggested(850,218),and looked gray-green rather than pink. Air selection was the second card after walker elimination.
- The ledger's actual stage-one totals were **60advancedcircuits,100concrete,200steel**, matching step7's shortcut amounts; step6's expected-text example says100/200/200. No extra goods were necessary. Stage2 correctly showed100batteries,80engines,40processingunits.
- Tool/model latency made several waits longer than specified. Steel placement02:10→inspection02:43; rare placement03:42→inspection04:19; airfield08:06→inspection08:42; AA10:14→inspection10:43; first depot12:03→inspection12:38. Patrol/Return and bomber post-spawn samples likewise ran late.
- Stage-one completion alerts, the saltpetre-bonus alert and the final belt-completed alert were not captured while visible. The resulting Age III state,working extractor/bonus and built19-piece belt were observed. Delivery speed doubling was not independently timed; the Rush button change and advancing goods were observed.
- Step15 required pointer placement without a click, but this computer-use interface exposes no standalone pointer-move action. A zero-distance scroll was rejected before action; a **0.001-page** downward scroll at(980,450) placed the pointer without an apparent zoom change, then H restored Holding the line. No hover-only text was used.
- The map was zoomed using small wheel calls, generally0.1-page increments. Two map zooms showed readable depots. The remote captured port was outside the inspected viewport, so its “(You)” map label was not verified. “Held by Division1” was checked in steps14–15 but could not remain in step26 after the division died.
- The4096 start screenshot showed2% at00:00. Although a30-second wait was requested, the next screenshot arrived at**01:28**,showing23%; the exact30-second percentage is unverified. The next match inherited the zoom left by step26.
- F4,F9,F10,F11 and the letter hotkeys worked; no Fn fallback was needed. No Ctrl+Shift+R restart,extra unspecified console command or lead log check was used. The only restart was step28's menu Restart.

## Attacks and final tested state

| Observed time | Event and outcome |
|---|---|
| 04:42 | Declared war onAI1; nearby eastern QA town created at04:45. |
| 06:54–08:57 | Front combat: AI hauler/walker/drone kills and own walker losses in feed; Division1 fell22→21→15→6→4→0. At08:42 Enemies seen10; by08:57 zero. Capital was not under attack and the interruption procedure requiring F3 was not triggered. |
| 10:46–11:05 | Deliberately spawned bomber attacked AA turret; capital warning appeared, AA was destroyed,bomber died,Commander kills rose to1. This is the protocol's intentional bomber event,not an unsolicited AI-attack interruption. |
| 13:10 | Enemies seen briefly1 during train selection; by13:56 zero; no capital damage alert or visible assailant. |
| Remaining first match | No observed unsolicited assault reached the capital; no F3/Ctrl+A/F defensive interruption was necessary. |

Before Restart: **Age III,Space Program stage2 at0%,Capital Town431cells,Army12,Supply11/60,one8/8 Mercenaries(Verrin)division,three scouts,Commander,automated Steel works,working saltpetre extractor,fort belt,airfield,two depots,Train13 in Bombard without a target; AA and Division1 lost.** Food/household stock had run out and residents/happiness declined during the prolonged test; no economy recovery was prescribed. Treasury approximately20,942,copper250. First match remained at war.

Final marker state: new six-nation4096Survey world,**Age I,02:04,32% generated,Army7,Supply6/40,Land0.2%,treasury1,586**. Exact marker visible; no later game input.

## Console record

Every entry used F9,exact paste,Enter. Replies were read on screen; no logs were checked. Standard give replies below mean `rts-give: N x ITEM into the rts-player pool`; research replies mean `rts-research: TECH researched for rts-player`.

| Entry | Input | Observed reply/result |
|---:|---|---|
| 1 | `/rts-age rts-player 2` | rts-player:age2; AgeII:Industry alert. |
| 2 | `/rts-research rts-industrialisation` | Researched for rts-player; completion alert. |
| 3 | `/rts-research rts-electrification` | Researched for rts-player; completion alert. |
| 4 | `/rts-treasury add 20000` | Balance21,519,net+20019/min,tax22,other20000,taxnormal,pop200,happiness100. |
| 5 | `/rts-give steel-plate 200` | 200steel-plate into pool. |
| 6 | `/rts-give concrete 100` | 100concrete into pool. |
| 7 | `/rts-give advanced-circuit 60` | 60advanced-circuit into pool. |
| 8 | `/rts-give rts-district-steel 1` | 1rts-district-steel into pool. |
| 9 | `/rts-give rts-automation-kit 4` | 4rts-automation-kit into pool. |
| 10 | `/rts-research rts-geology` | Researched for rts-player. |
| 11 | `/rts-deposit saltpetre` | Saltpetre deposit(6x6,36tiles)at(310.0,553.0),18tiles north-east of capital; place Rare extractor. |
| 12 | `/rts-give rts-rare-extractor 1` | 1rts-rare-extractor into pool. |
| 13 | `/rts-front` | rts-ai-1 town7 at(413.0,566.0),115tiles east of capital;rts-player:1segments[#2 80 t52]. |
| 14 | `/rts-spawn rts-walker 16` | 16rts-walker for rts-player near(356.0,564.0). |
| 15 | `/rts-research rts-fortification` | Researched for rts-player. |
| 16 | `/rts-give rts-wall 100` | 100rts-wall into pool. |
| 17 | `/rts-give rts-turret 10` | 10rts-turret into pool. |
| 18 | `/rts-give rts-field-depot 1` | 1rts-field-depot into pool. |
| 19 | `/rts-give firearm-magazine 100` | 100firearm-magazine into pool. |
| 20 | `/rts-research rts-aviation` | Researched for rts-player. |
| 21 | `/rts-research rts-air-force` | Researched for rts-player. |
| 22 | `/rts-give rts-airfield 1` | 1rts-airfield into pool. |
| 23 | `/rts-spawn rts-scout-plane 3` | 3rts-scout-plane for rts-player near(298.0,566.0). |
| 24 | `/rts-give rts-aa-turret 1` | 1rts-aa-turret into pool. |
| 25 | `/rts-spawn rts-bomber 1 rts-ai-1` | 1rts-bomber for rts-ai-1 near(298.0,566.0). |
| 26 | `/rts-research rts-railways` | Researched for rts-player. |
| 27 | `/rts-research rts-military-railways` | Researched for rts-player. |
| 28 | `/rts-give rts-depot 1` | 1rts-depot into pool. |
| 29 | `/rts-give rts-locomotive-kit 2` | 2rts-locomotive-kit into pool. |
| 30 | `/rts-give rts-artillery-wagon-kit 1` | 1rts-artillery-wagon-kit into pool. |
| 31 | `/rts-give rts-rail-shell 40` | 40rts-rail-shell into pool. |
| 32 | `/rts-give coal 100` | 100coal into pool. |
| 33 | `/rts-give rts-depot 1` | Recovery:1rts-depot into pool. |
| 34 | `/rts-give rts-locomotive-kit 2` | Recovery:2rts-locomotive-kit into pool. |
| 35 | `/rts-market ports` | Port#317(-972.0,-748.0),owner rts-ai-1;port#564(980.0,692.0),owner nil;player ports[],AIports[317],cap1/450,volume2113. |
| 36 | `/rts-market capture 317` | market:capture→true;Verrin Woods port-captured alert. |
| 37 | `RTS_QA_END` | player:RTS_QA_END at02:04 in final match. |
