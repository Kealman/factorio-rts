# Phase 4 visual QA results

Tested 16 October 2026, English, Factorio: Space Age 2.0.77, 1280×800 game area. Screenshots include the 28 px macOS title bar. The whole protocol, tester setup, attack handling and recovery instructions were read before testing. All game interaction used screenshots, mouse and keyboard in the already-running application; no console, game shell commands, launch, relaunch or manual quit was used.

Screenshots are in [phase4-screenshots](phase4-screenshots/). Each numbered step has `step-N-before.png` and `step-N-after.png`; intermediate screenshots capture transient states. PASS means the stated functional result was observed. SKIPPED identifies an unavailable prerequisite or an incomplete check, rather than claiming a product failure. Deviations and unverified subchecks are stated explicitly. No log checks were performed: those belong to the lead.

The first-before to final-after screenshot span was **31 minutes 32 seconds**, within the 55-minute budget. There are **240 PNG screenshots**, including all 124 required numbered before/after files. The recovered matches were separate runs; their strip timers must not be read as one continuous match.

## Step results

| Step | Name | Result | Screen evidence |
|---:|---|---|---|
| 1 | Lobby | PASS | Four settings and Start match visible; black arena, Army 0, Supply 0/0 (`step-1-after.png`). |
| 2 | Choose Medium | PASS | 1 opponent, Normal, Medium, Chokepoints selected (`step-2-after.png`). |
| 3 | Start match | PASS | At 00:08: Army 7, Supply 6/40, iron 400, copper 150, Commander Lv 1 and HUD present (`step-3-after.png`); exact five-second threshold was not captured. |
| 4 | WASD pan | PASS | Each direction moved correctly and stopped; one second of D moved approximately 0.8 screen widths (`step-4-d.png`, `step-4-after.png`). |
| 5 | Space home | PASS | CC returned to centre (`step-5-after.png`). |
| 6 | Wheel zoom | PASS | Zoomed out and back; CC stockpiles returned to approximately 112 px separation (`step-6-zoom-out.png`, `step-6-after.png`). |
| 7 | Minimap jump | PASS | Natural expansion appeared, then Space returned home (`step-7-jump.png`, `step-7-after.png`). |
| 8 | Click / Shift-click walkers | FAIL | Both prescribed clicks left “No units selected”; no blue boxes (`step-8-single.png`, `step-8-after.png`). |
| 9 | Optional drag selection | PASS | Drag selected six walkers, excluding Commander (`step-9-after.png`). |
| 10 | Select all | PASS | Seven units, Idle 6 / Commander 1, two cards (`step-10-after.png`). |
| 11 | Unit cards | SKIPPED | Filtering and Shift-removal worked, leaving Commander ×1; required card tooltip was not captured (`step-11-walkers.png`, `step-11-after.png`). |
| 12 | Deselect / CC selection | PASS | CC HP 3000, robot/power information and policy panel appeared; empty click closed selection (`step-12-cc.png`, `step-12-after.png`). |
| 13 | Move | PASS | Army moved to target and became idle (`step-13-ordered.png`, `step-13-after.png`); transient green click ring not captured. |
| 14 | Attack-move | PASS | F armed the red action and ground order cleared it; units moved (`step-14-armed.png`, `step-14-after.png`). |
| 15 | Stop | PASS | X stopped army before the distant destination (`step-15-after.png`). |
| 16 | Hold / Stop button | PASS | Hold order appeared, then Stop returned walkers to Idle (`step-16-hold.png`, `step-16-after.png`). |
| 17 | Shift attack-move / park | PASS | Order accepted; army parked away from build sites and deselected (`step-17-shift.png`, `step-17-after.png`). |
| 18 | Build menu | PASS | Tabs, stock counts, Hub tooltip, locked defence tooltip and B hide/show worked (`step-18-hub-tooltip.png`, `step-18-defence.png`, `step-18-after.png`); steam tooltip not captured. |
| 19 | Production buildings | PASS | Factory and barracks built; lab remained a ghost until crafted (`step-19-ghosts.png`, `step-19-after.png`). |
| 20 | Iron line construction | PASS | Extractor, smelter, inserter and stockpile built; right-click ended placement (`step-20-after.png`). |
| 21 | Iron line operation | PASS | Extractor Working / Iron ore, smelter Iron plate, stockpile 57 items; no R rotation needed (`step-21-extractor.png`, `step-21-stockpile.png`). |
| 22 | Barracks / rally / pause | PASS | Locked heavy recipe, running walker kit, rally (-132,-5), then paused; 15 walkers produced because elapsed time exceeded the requested 30 s (`step-22-rally.png`, `step-22-after.png`). |
| 23 | Commander / natural hub ghost | PASS | Commander reached natural and hub ghost placed left of ore, after defensive interruption (`step-23-natural.png`, `step-23-after.png`). |
| 24 | Craft hub and lab | PASS | Both recipes ran, three of each completed before pause (`step-24-hub-running.png`, `step-24-lab-running.png`, `step-24-after.png`). |
| 25 | Hub and lab built | PASS | Real natural hub with side stockpiles, real home lab, cap 50 and 4.3 MW (`step-25-hub.png`, `step-25-lab.png`). |
| 26 | Hub panel | PASS | Hub 1, HP 1200, separate Network #6 with 1 hub and Keep 50 iron / 20 copper (`step-26-after.png`). |
| 27 | Hub policies | PASS | Stone Keep 30, coal Export above 10; stone 0 yellow, coal 0 white (`step-27-after.png`). |
| 28 | Close / reopen hub panel | FAIL | × closed it, but deselecting and reselecting the same hub did not reopen it; reproduced after recovery (`step-28-after.png`, `step-recovery-hub-reopened.png`). |
| 29 | CC export policy | PASS | CC Network #2 differed from hub #6; iron Export above 0 turned count green (`step-29-edited.png`); subsequent attack destroyed base. |
| 30 | Cable / circuits | PASS | After recovery, both recipes ran and circuits reached 37 (`step-30-after.png`). |
| 31 | Hauler production | PASS | Three small haulers appeared; circuits spent and Army increased without supply use; production wait overshot one kit (`step-31-after.png`). |
| 32 | Select hauler | PASS | Hauler #1659, Auto, HP 400, Home CC, empty cargo and zero trips (`step-32-hauler-at-home.png`). |
| 33 | Route pickup | PASS | Right-click CC selected Route with missing drop-off / waiting state (`step-33-after.png`). |
| 34 | Route delivery | SKIPPED | AI destroyed Hub 1 before drop-off could be assigned; no cross-network delivery verified (`step-34-destroyed-hub.png`). |
| 35 | Auto at Hub 1 | SKIPPED | Auto button worked, but Home remained CC because destination hub was destroyed (`step-35-after.png`). |
| 36 | Park / Resume / Return home | PASS | Parked yellow, Resume and Return home changed to Going home; tested with CC home, not destroyed Hub 1 (`step-36-parked.png`, `step-36-return-home.png`). |
| 37 | Research panel | PASS | 19 technologies, two tiers, Labs 1 / working 0, locked prerequisite tooltip (`step-37-after.png`, `step-37-locked-tooltip.png`). |
| 38 | Queue / cancel / close | PASS | Supply I researching 0%, Attack I queued then Available, Escape closed (`step-38-supply.png`, `step-38-cancelled.png`). |
| 39 | Science kits | PASS | Gear then basic science recipes ran; kits accumulated and lab consumed them (`step-39-science-progress.png`); attack extended gear-production time. |
| 40 | Lab / restart barracks | PASS | Lab Supply I 99%, then completion alert at 8:32; walker production restarted (`step-40-lab.png`, `step-40-after.png`). |
| 41 | Ability tooltips | PASS | All five tooltips showed name, hotkey/no-hotkey, cooldown and reasons; Shield unavailable because Commander was down (`step-41-*-tooltip.png`, `step-41-after.png`). |
| 42 | Stim | PASS | Damaged-unit branch: selected walkers healed from 67% to 94%, green effect and 30 s cooldown; iron dropped (`step-42-selection.png`, `step-42-after.png`); healthy refusal not exercised. |
| 43 | Stim on Commander | SKIPPED | Commander down and Stim recharging; no live Commander available (`step-43-after.png`). |
| 44 | Shield | SKIPPED | C reported “Commander is down”; Shield had worked during earlier defensive interruptions (`step-44-after.png`). |
| 45 | Unavailable abilities | PASS | V: Needs research Scanner; G: No artillery walker; Overcharge remained unavailable (`step-45-scanner.png`, `step-45-artillery.png`, `step-45-after.png`). |
| 46 | Commander icon / camera | PASS | After respawn, icon selected Commander only and second click centred it; level and kills persisted (`step-46-selected.png`, `step-46-after.png`). |
| 47 | Commander move / stop | PASS | Move changed position; X stopped before far destination, under active enemy fire (`step-47-move.png`, `step-47-after.png`). |
| 48 | Commander attack-move | SKIPPED | Shift order accepted, but Commander died and match ended before full sequence / return could finish (`step-48-shift.png`, `step-48-after.png`). |
| 49 | Completed research / cap | SKIPPED | Supply I was green Done, but CC and hub were destroyed, so cap was 10 rather than the required 60 (`step-49-research.png`, `step-49-after.png`). |
| 50 | Alerts | PASS | Research completion line/chat at 8:32 and multiple red base-attack / Commander-down alerts observed; sound not assessed (`step-40-after.png`, `step-39-after.png`). |
| 51 | F3 alerts | PASS | Successive F3 presses moved camera between attack locations (`step-51-first.png`, `step-51-after.png`); alert-line click initially untested. |
| 52 | Assign groups | PASS | After second recovery, group 1 held 7, group 2 held Commander only, groups 3–5 disabled; no hauler existed to remove (`step-52-group1.png`, `step-52-after.png`). |
| 53 | Recall groups | PASS | 1, 2 and button recalled correctly, 3 preserved selection; `1 1` visibly centred army (`step-53-double.png`, `step-53-after.png`). |
| 54 | Fight an attack | PASS | At 4:05–4:31, green enemy/red friendly deaths, Enemies seen 30→22, Commander kills 4→15; five of six walkers lost in this encounter (`step-54-moat-order.png`, `step-54-after.png`). |
| 55 | Shield / Stim / levels | PASS | Blue Shield ring and 45 s cooldown; after combat, Stim green ring, selected average HP 60→75%, iron 400→390, 30 s cooldown; Commander Lv 3 / 15 kills, no death (`step-55-shield.png`, `step-55-stim.png`). |
| 56 | Optional middle hub | SKIPPED | Omitted to prioritize required ending checks; fresh recovery had no factory or spare hub (`step-56-before.png`, `step-56-after.png`). |
| 57 | Match menu | PASS | F10 showed correct settings/time and Restart/Concede/Resume; Resume and Menu→Escape closed without moving camera (`step-57-menu.png`, `step-57-after.png`). |
| 58 | How to play | PASS | F11 opened and closed all ten headed paragraphs; no clipped help text seen (`step-58-help.png`, `step-58-after.png`). |
| 59 | Concede / results / reopen | PASS | First click “Really concede?”, second within 5 s ended at 05:15; Conceded/Winner rows and Results reopening matched (`step-59-armed.png`, `step-59-results.png`, `step-59-results-again.png`). |
| 60 | Ctrl+Shift+R | PASS | Fresh base, Army 7, Supply 6/40, iron 400, Lv 1, no production buildings, Supply I Available (`step-60-research.png`, `step-60-after.png`). |
| 61 | Menu Restart / lobby / Start | PASS | Black lobby retained 1/Normal/Medium/Chokepoints; Start restored fresh match (`step-61-lobby.png`, `step-61-after.png`). |
| 62 | Final end marker | PASS | Ctrl+Shift+E printed state summary (`step-62-after.png`); subsequent running-app inventory no longer included Factorio and bound-window read timed out. No manual quit or relaunch. |

## Failures in detail

- **Step 8 — walker clicks selected nothing.** Expected one walker, then two with Shift. Both screenshots show “No units selected.” The prescribed positions were used; subsequent drag and Ctrl+A selection worked. F1 and a more precise body click were not retried here, so this is a failed protocol action, not proof that all single-unit selection is broken. Evidence: `step-8-single.png`, `step-8-after.png`.
- **Step 28 — closed hub policy panel did not reopen.** Expected deselect/reselect to reopen and preserve the edited policies. The hub's bottom-left building page returned but the right policy panel stayed absent. Repeated after the first recovery with an intervening deselection observation, same result. Selecting the CC opened its own policy panel. Evidence: `step-28-closed.png`, `step-28-after.png`, `step-recovery-hub-deselected.png`, `step-recovery-hub-reopened.png`.
- **Incomplete coverage is not a product failure.** Card tooltip (11), cross-network cargo delivery / new home (34–35), scheduled Commander abilities (43–44), full Commander attack-move sequence (48), and full 60-cap state (49) were not verified. Destruction of their prerequisites is documented in the table. Park/Resume was exercised using the surviving CC instead of Hub 1.

## Protocol coordinates that were wrong

Coordinates below exclude the 28 px title bar, as the protocol does.

- Step 23: after minimap (1153,98), natural iron centre was approximately **(704,356)** rather than near screen centre (640,400). Hub was correctly placed relative to the actual patch at approximately **(560,356)**. See `step-23-natural.png`.
- Steps 31–32: by selection time, haulers were near **(600,444)** at home, rather than the suggested factory spawn point (824,530). This was movement after production, not evidence of a misplaced spawn. See `step-32-hauler-at-home.png`.
- Step 36: Auto-mode Resume and Return home were at approximately **(1124,314)** and **(1062,314)**; Route mode adds a line and moves them down near the documented y=329. Difference is below 30 px but affected clicking.
- Step 8's given walker positions did not select units. The visual bodies/legs overlap and their selection boxes sit above body sprites; a verified replacement single-click coordinate was not established.
- Step 52 asks to remove a hauler after Ctrl+A, but tester setup says Ctrl+A excludes haulers. The recovered match had no haulers, so no such card was present.

## Observations

- Basic camera, selection via drag/cards, movement, construction, recipe production, research and control groups formed a usable RTS loop. All observed UI was English; no raw translation keys were seen.
- Large walker legs overlap heavily. It is hard to identify a precise body click, and selection boxes appear displaced above the apparent body. Drag selection is much easier.
- Defensive attack-move led some walkers to pursue toward the enemy side of the moat, making it difficult to keep the base defended. This is observed behavior, not a confirmed pathing/order bug.
- Normal AI repeatedly attacked while the long UI protocol kept the barracks paused. Two matches were lost around ten minutes. This makes the economy/logistics checks fragile and prevented delivery coverage.
- Some long building descriptions and order text were truncated. A vanilla building-info panel appeared behind/under the minimap after construction and sometimes remained stale while other RTS work continued (`step-19-after.png`, `step-24-panel.png`).
- A new factory initially displayed the preceding factory's “Crafted 6 / to network 6” totals after reset (`step-recovery-hub-crafting.png`); possible stale display/counter state. Immediate reset screenshots also briefly showed old Commander/supply values, but these refreshed to Lv 1 / 6/40 within seconds.
- After defeat, F could still arm attack-move with no army (`step-48-f-order.png`), replacing useful defeat feedback. Space/F3 remained operable, although the destroyed base view was chart-like/pixelated.
- GUI hover automation used tiny wheel movements to position the pointer. This accidentally changed map zoom during ability tooltips; documented recovery restored the 112 px stockpile separation. This is a tester-side deviation, not a mod defect.
- Several production waits overshot because game time continued during screenshots and tool calls: the first barracks produced 15 walkers, factory produced extra hubs/labs, and hauler production made three. Some requested fixed waits were shortened or extended by intervening combat. This was not a frame-exact timing test.
- The help's Hubs paragraph says CC robots build up to 80 tiles and hub robots up to 40, while protocol step 23 says CC range 40. These documents should agree (`step-58-help.png`).
- Fighting and unit damage continued behind the results dialog after concession, while match time stayed frozen at 05:15. The results table stayed fixed when reopened (`step-59-results-again.png`, `step-59-after.png`).
- The later attempt to click an alert line occurred after it faded; it deselected the army instead. Alert-line navigation remains unverified, although F3 navigation passed (`step-51-alert-click-later.png`).

### Attacks, recovery and Commander record

Times are visible strip times; they are observations, not exact unseen attack start times.

| Match | Time | Observed attack and outcome |
|---|---|---|
| 1 | ~7:01–8:18 | First substantial combat during natural-hub setup. Army fell from 22 to 4; Commander reached Lv 2 / 11 kills. Defence used F orders and C. Some walkers pursued away from home (`step-23-attack-defense.png`, `step-23-attack-outcome.png`). |
| 1 | 9:38–10:28 | Hub attacked (HP 1192 visible), destroyed by ~9:59; attack reached home around 10:00, Commander died around 10:15, defeat at 10:28. Results: You units built/lost 15/22, buildings 9/11; AI 57/32, buildings 41/0 (`step-29-attack-outcome.png`). |
| 2 | ~3:50–4:02 | Hub lost, six starting walkers lost, extractor/base attacked; Army 4 consisted of Commander and three haulers. F3/attack-move/Shield defended home; Commander Lv 2 / 9 kills (`step-32-attack-defense.png`). |
| 2 | ~5:29–6:51 | Expansion/stockpile alert; Commander fought, briefly at 68 HP with Lv 3 / 28 kills, later 31 kills (`step-39-defense.png`, `step-39-attack-outcome.png`). |
| 2 | ~8:29 onward | Commander died, then respawned near CC around 9:29 (observed alive at 9:52). Barracks reinforcements fought; research completed 8:32. Buildings and haulers subsequently destroyed (`step-39-after.png`, `step-40-after.png`, `step-46-after.png`). |
| 2 | 10:18–10:29 | Commander HP 14%, reached 62 kills, died again; defeat at 10:29. Results: You units 12/23, buildings 9/9; AI units 125/75, buildings 36/0 (`step-47-after.png`, `step-48-after.png`). |
| 3 | 4:05–4:31 | After quiet base wait from 00:34 to 03:56 (22 s over the requested three minutes), army attack-moved toward the moat and met about 30 visible enemies. Five walkers lost; at least 15 kills credited to Commander. Stockpile attack alert around 4:11, damaged stockpile visible at home. Commander reached Lv 3, survived, Shield and Stim worked (`step-54-after.png`, `step-55-after.png`). |
| 3 | ~4:52–5:15 | Another enemy force arrived during menu/help checks; last walker died, Commander reached at least 22 kills, stockpiles and CC took damage. Conceded at 5:15; final results You units 0 built / 6 lost, buildings 0/0; AI units 31/27, buildings 21/0 (`step-59-results.png`). |

Recovery reset 1 followed match 1 defeat; factory, barracks, iron line, natural hub and lab were rebuilt before step 30. Recovery reset 2 followed match 2 defeat and step 51; it restored initial units for groups and combat. Both used the protocol's Ctrl+Shift+R, not application relaunch. Highest Commander observed before match 3: **Lv 3, 62 kills**. Three deaths observed across matches 1–2 (one plus two); the second-match respawn retained level/kills. Exact 60-second respawn alert was not captured.

Before step 60: **Army 1, Supply 0/40, iron 390; no research completed in match 3** (`step-60-before.png`). Supply I had completed in match 2 and was cleared by recovery reset 2. Step 60 independently showed it Available. Match 3 Commander survived through concession, reached Lv 3 and at least 22 kills; no additional death observed before reset. Highest run-wide observed value remains Lv 3 / 62 kills, with three observed deaths.

All tested function keys (F3, F10, F11) and Ctrl chords worked without Cmd fallback. Ctrl+Shift+E was the final game input. It produced the summary at match 5 time 00:22, then Factorio disappeared from the running-app inventory. A read-only attempt to inspect the old bound window timed out; see `step-62-window-state.txt`. The required after screenshot captures the summary before automatic closure. The application was never manually quit, and was not relaunched to counteract the protocol's automatic ending. This differs from the user's requested final running state because the end marker's launcher behavior closed it.

## Verdict

**Playable as an RTS, but this is not a clean QA pass.** Camera control, army orders, production, research, groups, combat abilities and match lifecycle worked well enough to play and fight. The hub-panel reopening failure is reproducible, single-walker clicking was unreliable at the supplied positions, and overlapping sprites/truncated UI reduce clarity. Normal AI pressure repeatedly destroyed prerequisites during this long tutorial-style test; cross-network hauler delivery and several Commander-specific checks remain unverified. The recorded results are **52 PASS, 2 FAIL, 8 SKIPPED**, with the stated subcheck limitations, two recovery resets and optional step 56 omitted.
