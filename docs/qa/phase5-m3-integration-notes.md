# Phase 5 M3 integration (wave B): balance, fixes, HUD, acceptance, docs

Date: 2026-10-17 to 2026-10-23. Factorio 2.0.77 (mac-arm64, Steam), Space Age on unless noted. Agent: `m3-integ`. Contract:
`docs/PHASE5-M3.md` (§4 "M3 end-to-end" is this package's acceptance). Starting point: HEAD 80bcdbe (tag
`m3-wave-a` = m2-ready + the five M3 wave A snapshots). Package notes: `docs/qa/phase5-{air,age3,war2,perf,world3}-notes.md`;
the AI of wave B is `m3-ai`'s. Everything below is Nation mode only unless it says otherwise.

## 1. Verdict

Final HEAD **dad7a40** (m3-ai's AI 5a06781 → 73f045b → 1f28ccb → dad7a40, this package's 3edd55b … 705a33a, aaf8764).
M3 runs end to end with 0 Lua errors in every run of this package, at 60 UPS, deterministic, through save/load and on
LAN; the Skirmish matrix is line-identical to m2-ready. The economy criteria hold except where the AI's pace decides
them; three contract numbers are short and listed as open issues (section 7).

| Criterion (PHASE5-M3 §4) | Result | |
|---|---|---|
| 0 Lua errors, 60 UPS | every run; speed-1 minutes 60.0 s (60.1-60.2 in the last, the autotest's end); perf scene 60.0 s per game minute | PASS |
| M2 end-to-end criteria on 801-805 (trade, war, peace, capture, starving) | 5 of 5 seeds (section 4.2) | PASS |
| Every nation founds ≥ 3 cities | 20 of 20 | PASS |
| … and links them by rail by 35:00 | 10 of 20 nations (15 of 20 on 705a33a; 8 of 20 on 5a06781) | **short** |
| ≥ 1 operation with phases per nation | 19 of 20 | **1 short** |
| Air patrols fly | 3 of 5 seeds | PASS (partial) |
| A belt on a threatened segment | built in 5 of 5 seeds (sector belts: lands rarely touch on 2048) | PASS |
| Age III by 40:00 in ≥ 3 of 5 | 2 of 5 (33:03, 39:48; a third at 40:13) | **short** |
| Wars and peaces as in M2 | 2-7 wars, all seeds back to peace, 3-9 captures | PASS |
| AI budget ≤ 0.5 ms/tick/nation mean, ≤ 3 ms any tick | 0.063 ms per nation in the perf scene; commander runs over 3 ms: 17 ticks of 18,000 (worst 5.98 ms), market.ai_step once (3.54 ms) | mean PASS, worst-tick **short** |
| Save/load at 20 and 40 | 0 errors in all halves | PASS |
| Skirmish matrix unchanged vs m2-ready | 10 scenarios, 0 differing lines (705a33a; later commits are Nation-only, m3-ai's byte-identical) | PASS |
| GUI protocol (Codex) | `docs/qa/phase5-m3-protocol.md`; this package's own pass EN 52/53, RU 48/53 (placements and Russian coordinates) | ready |
| Perf scene 60 UPS, M2+M3 ≤ 1 ms | 1.369 ms mean, UPS capacity 731, realtime 60.0 s per minute; M2 0.025, M3 0.013 ms/tick | PASS |
| Determinism (two seeds) | 801 and 802, 30 minutes: 214 and 209 event lines, 0 differing | PASS |
| Heavy mode 10 min, LAN | heavy: ticks 3,600-4,200, 0 desyncs; LAN: two clients, 0 desyncs, 33 + 25 checksums equal | PASS |
| M1 seed 501 | 52/52 all passed, twice identical (the aggressive AI won at 59:18) | PASS |
| M2 seeds 701-705 within tolerance | trade, war, peace, capture 5 of 5; starving 2 seeds (tolerance 1) | **short** |
| Money (balance target): debt in ≥ 2 of 5 seeds, nobody bankrupt | debt in 1 of 5; nobody at the credit line | **short** |

## 2. What changed

### A. Balance

Method: 4 normal AIs, 2048, 60 minutes, `tools/probes/m3_acceptance.lua` (per nation the first open line, Age II and
III, the lowest balance, the highest debt stage, minutes in debt, the credit line), seeds 801-805. Three trees: the
wave A tree (HEAD 80bcdbe, the M2 AI; `m3i-base-*`), the integration tree with m3-ai's AI as of 2026-10-22 morning
(`m3i-live2-*`), then the same with this pass's changes (`m3i-live3-*` and later).

| Run set | Nations in a debt stage (seeds) | At the credit line | First lines at or after 25:00 | Age III by 40:00 |
|---|---|---|---|---|
| wave A AI (`m3i-base-801..805`) | none (0 of 5 seeds); lowest balances ₡ 439-1,500, the AI imports down to its ₡ 500 reserve | none | 6 of 20 (801: 2, 803: 2, 804: 1) | no Age III road in that AI |
| m3-ai's AI before this pass (`m3i-live2-801..804`) | 6 nations in 3 of 4 seeds, all stage 3 | **4 nations** (801, 802, 804 x2) at 50:19-57:59 | 7 of 16 incl. 2 nations without a line | 2 of 4 seeds (36:36, 38:30) |
| + rush rule, debt tax, credit decay, Railways 10 (`m3i-live3-801..804`) | 2 nations in 2 of 4 seeds (801, 803; stage 3 for 5-8 min) | none | 11 of 16 (25:16-43:46) | 2 of 4 (38:18, 35:40) |
| + Electrification 25 (`m3i-live4-801..804`) | 2 nations in 2 of 4 seeds (802, 804; stage 2 in the last minute) | none | 8 of 16 (25:00-48:27) | 2 of 4 (35:34, 38:15); Electrification done at 27-35 min, then stage 1 took 10-24 min (advanced circuits last: 21 of 100 after 9 minutes) |

What drove the debts (treasury minute lines): (1) "other" expenses of 176-186 cr a minute for ten minutes and more:
the research Rush on Electrification while both labs stood idle (no industrial kits); (2) a spiral: stage 3 (-25
happiness) put the AI's banded tax on low below happiness 40, the tax income fell to a third, and the credit line (10
minutes of gross income) shrank with it, so a balance of -773 was "at the credit line" of 743; (3) armies of 155-280
supply (army upkeep at the same number of crowns a minute) that grow at war and do not shrink in debt (m3-ai's).

| Change | Why | Where |
|---|---|---|
| A rush pays only while it speeds something up: a project stage whose goods came in during the last 3 s (or its countdown), a research while a lab works | (1); age3 notes open issue 6 | `scripts/sinks.lua`, `scripts/age3.lua`, `scripts/ages.lua` (`pulled_at`) |
| In debt (stage >= 1) an unhappy AI keeps the normal tax instead of the low one | (2) | `scripts/market.lua` (banded tax) |
| The credit line falls at most 1 % per treasury step (about 6 % a minute) when the income falls | (2): a credit line that halves in a minute makes a temporary tax drop a bankruptcy | `scripts/treasury.lua`, `balance.nation.treasury.credit.decay = 0.99` |
| Railways 10 basic kits (was 15) | first lines at 21-36 minutes; the labs waited for basic kits after Industrialisation | `prototypes/rails.lua` |
| Electrification 25 industrial kits (was 40) | the labs waited for industrial kits 12-30 minutes after Age II; the Space Program started at 29:44-47:59 | `balance.nation.age3.techs` |
| Army upkeep 1.2 cr per supply point a minute (was 1) | with m3-ai's tuned AI (a ₡ 500-1,500 reserve, fewer rushes) no nation went into debt in 4 seeds; at 1.2 two of four seeds had a nation in debt, none at its credit line | `balance.nation.treasury.army` |
| Space Program stage 1: 200 steel, 150 concrete, 60 advanced circuits (was 200 / 200 / 100) | stage 1 took the AIs 10-24 minutes, the advanced circuits last; stages 2 and 3 (the Space victory) unchanged | `balance.nation.age3.stages` |
| Wave B.2: stage 1 concrete 100 (was 150) | concrete was the last good of stage 1 in every 4-nation seed (12-96 of 150 at 40:00, steel 200/200) | `balance.nation.age3.stages` |
| Wave B.2: escrow part payments leave 50 steel (`rails.AI_ESCROW_FLOOR`) | the escrow paid all six AI depots of seed 802 in minutes 24-25 and Electrification waited for steel (m3-ai: steel made in minutes 18-37 412 against 564, the research 1,045 s against 660 s) | `scripts/rails.lua` |

| HEAD 9c60893 (this pass + m3-ai's df6736c tuning; `m3i-e2e1-801..804`) | none (lowest balances ₡ 157-503: the AI keeps a reserve) | none | 9 of 16 (26:54-50:20) | 2 of 4 (39:19; 36:06, 38:35) |
| + army upkeep 1.2 per supply point (`m3i-army12-801, 802, 803, 805`) | 2 nations in 2 of 4 seeds (802 rts-ai-3, 805 rts-player; stage 3, lowest ₡ -364 / -488) | none | 10 of 16 | 1 of 4 (36:59) |

| HEAD 705a33a (wave B.2: m3-ai's 5a06781 AI, this package's rail fixes and escrow; `m3i-f1-801..805`) | 2 nations in 2 of 5 seeds (804 rts-player stage 2, 805 rts-ai-3 stage 3; lowest ₡ -695) | none | 3 cities linked by 35:00: 15 of 20 (m3-ai's 5a06781 tree: 8 of 20) | 0 of 5 (leaders 40:10, 43:19, 41:46; m3-ai's batch M on 5a06781: 3 of 5, 38-40) |
| the same with army upkeep 0.8 (A/B arm, `m3i-f1-ab-801..805`) | **none in 5 seeds** (lowest ₡ 105-501) | none | similar | 0 of 5 |

**Army upkeep A/B** (the lead's wave B.2 item 5; m3-ai suspected 1.2 cost linking, air and Age III): at 0.8 no nation
reaches a debt stage in 5 seeds (the money criterion fails) and Age III is no earlier; linking, air patrols and belts
are the same in both arms. **1.2 stays.**

**Age III by 40:00** (0 of 5 on 705a33a): a bisect on seed 802 that takes out one wave B.2 change at a time
(rts-ai-2 / rts-ai-3 at 43:19 / 43:55 on the base): weary_ratio and the tax cap change nothing (line-identical up to
minute 45); without the escrow 42:40 / 40:31, but linking by 35:00 falls from 4 of 4 nations to 1 of 4; without the
port hold rts-ai-2 has no Age III by 45:00 and rts-ai-3 42:02. The Space Program waits for Electrification (stage 1
started 35:39-41:32) and then for concrete, the last good of stage 1 in every seed (12-96 of 150 at 40:00, steel
200/200).

### B. Fixes carried from M2 and wave A

| Item | Cause | Fix | Where | Evidence |
|---|---|---|---|---|
| Fights razed belts, inserters and plain buildings (M2 integration open issue 2) | A unit distracted by an enemy gets an engine `attack_area` distraction (no target) and a division's group the same; both attack every enemy entity in the area, military or not, until none is left (probe: loose walkers with command go_to + distraction attack_area hit the inserter, factory, stockpile and house of the row; division members with command `group` the belts and the extractor) | Damage to an entity that is not a military target (walls, gates, units and rolling stock excepted) is undone when it comes from a careful unit (not a raider, not a plane) that is fighting something else: its distraction (with or without a target), its attack command, or its group's; explicit attacks (`rec.target`), re-target strikes and division strikes (`D.order.strike`, `D.strike`) still destroy, and so do area commands without a fight. The entity turns indestructible for 10 s (the rails' rule), so the area attack drops it and the units walk on; an explicit attack exposes it at once. Belts, splitters, loaders, inserters and pipes join the shared damage filter | `scripts/targeting.lua` | `tools/probes/m3_integ.lua` lanes A-D (below) |
| A player's trains stayed stopped when a lost depot came back (M2 integration open issue 12) | `buildings.on_force_changed` cleared the lost half of the route and only the AI's rail program routed its trains again | The lost half is remembered (`lost_pickup`, `lost_dropoff`); when the depot comes back to the train's force, every train without an AI line mark (`rec.ai_line`) gets its route again (`rails.set_route`), log `rails: train N (force) routed again: depot #D is back`; a new route by hand forgets the lost half | `scripts/rails.lua` | `tools/probes/m3_reroute.lua` |
| Raw stop names on the map ("rts-player depot 504", M2 integration open issue 8) | Train stops carry unique script names for the schedules; the engine draws them on the map | The stop names stay (schedules), the map view setting `show-train-station-names` is off for every player in a Nation match (restored at teardown), and each depot draws a localised chart label "Depot N" (the depot panel's name) for its owner, redrawn on capture | `scripts/rails.lua` | GUI audit |
| Dead code `population.ai_step` / `ai_describe` (M2 open issue 11, ai notes 10) | m2-ai's governor took the rules over | Removed (313 lines) | `scripts/population.lua` | smoke, fixtures |
| Research panel: "Needs Age II" for Air Force (air notes open issue 3) | one status text for every age gate | "Needs Age III" for techs gated by Age III (`rts.tech-status-age-3`) | `scripts/techgui.lua`, `locale/*/economy.cfg` | GUI audit |
| F11 Nation page reached 695 of 800 px in Russian and lacked the M3 keys (air notes open issue 7) | a plain flow | The page scrolls inside 80 % of the window height; an "Age III and money" paragraph; the air paragraph before the keys; the keys paragraph names Y, and F / B / H in context; the victory paragraph names Space and the world sizes; the supply paragraph says attack-moves spare the buildings around a fight | `scripts/hud.lua`, `locale/*/hud.cfg`, `locale/*/age3.cfg` | GUI audit |
| «Нация» / «Держава» in the Russian diplomacy texts | M2 diplomacy used «Нация» while the mode is «Держава» | every «Нация»/нация of `diplomacy.cfg`, `hud.cfg`, `cities.cfg` (and the city-state tooltip that said trade "comes later") | `locale/ru/*.cfg`, `locale/en/diplomacy.cfg` | GUI audit |
| Airfield art placeholder (air notes open issue 5) | the cargo landing pad's graphics read as a large machine | A refined-concrete apron with a hazard-striped rim and a centre line, a small roboport hangar in one corner (base-game textures; the roboport icon) | `prototypes/air.lua` | GUI audit |
| The headless autotest started on any dedicated server with nobody connected at tick 120 (perf notes open issue 9) | `debug.lua` decided by the player count only | Opt-in: `local AUTOTEST_ENABLED = false` in `scripts/debug.lua`; `tools/autotest-run.sh`, `perf-bench.sh`, `heavy-mode.sh` and `lan-check.sh` set it to true in their copies (older trees without the line run as before) | `scripts/debug.lua`, `tools/*.sh` | every run of this package |
| `diplomacy.is_human` counted connected players (a disconnect handed a nation's diplomacy to the AI; perf notes open issue 9) | | A flag per nation set at the match start for forces with connected players and when a player joins a nation later (`on_player_joined_game`, `on_player_changed_force`), never cleared; outside a Nation match (and in saves from before) the old rule | `scripts/diplomacy.lua` | `m3_integ.lua` human_flag |
| Order-dependent loops (perf notes open issue 9) | | `population.lua` loose-building pass: a sorted snapshot walked RESOLVE_BUDGET per tick (the old walk restarted at the first key every tick and never got past 200 loose buildings); `selection.get` in unit-number order in Nation matches (Skirmish keeps its order: the legacy autotest compares it); `logistics.init` walks a sorted snapshot (it inserted into the table it traversed); `warsupply` sums supply in unit-number order; `strategic.lua`'s zoom tier reads `LuaPlayer.zoom`, synchronised player state, and only scales chart texts: kept, covered by the LAN and heavy-mode runs | `scripts/population.lua`, `selection.lua`, `logistics.lua`, `warsupply.lua` | smoke, matrix, determinism |
| The fronts refresh ran on its own on_tick driver (war2 notes open issue 9) | wave A had no scheduler hook | A scheduler job (kind `fronts_refresh`, BACKGROUND priority, on the budget of the match's first nation; a job step = 300 units: 24 rows / 600 cells or one side's segments); `fronts.flush()` takes a running job off the scheduler; the old driver stays for a job of a save from before | `scripts/fronts.lua` | war2 autotest 22/22 |
| The rail planner went around fort belts (war2 notes open issue 4) | walls and gates were blockers | Own walls and gates no longer count as blockers of a coarse cell; a straight orthogonal piece whose only obstacles are own walls or gates costs +6 (`rails.WALL_CROSS_COST`), and when its ghost is laid the walls under it become `rts-gate` across the track (health share kept; log `rails: survey #N: K wall(s) at (x, y) turned into gates`) | `scripts/rails.lua` | `m3_integ.lua` wall_cross |
| A city site on ungenerated ground (world3 notes open issue 4) | `cities.lua` picked candidates without asking whether their chunk exists | A candidate on a chunk that does not exist yet is requested (`worldgen.request_area`) and skipped this time; `ai/towns.lua` got the same proposal through m3-ai | `scripts/cities.lua` | 4096 runs |
| The M2 fixture's upkeep check failed after m3-age3's sliced census | a new building counts after the next full census, up to 1,200 ticks later | the fixture waits 1,210 ticks | `tools/probes/m2_integ.lua` | 11/11 |
| An AI re-surveyed the same failing depot pair back to back (seed 702: rts-ai-2's scheduler at 3.44 ms/tick in minutes 55-60) | `rails.ai_program` started a new survey of the same pair right after one failed; the fine phase's units were set for the old A* (one unit per expansion against ~10 µs of real work) | A failed line backs off (`A.retry`: 2, 4, 8, 16 minutes after 1-4 failures in a row, log `rails: AI X line #N failed (k in a row): next survey in S s`), reset when a line opens; `rails.SURVEY_UNITS` recalibrated (fine 10, check 36) | `scripts/rails.lua` | 702 rerun: sched 0.109 ms/tick; smoke, `m3_integ` |
| A depot built over a line surveyed but not laid yet blocked it for good (m3-ai, M1 seed 501: the planner's depot #3083 put its stop on piece 24 of the player's town line one second after its survey; the crew stood at piece 24 from minute 26 to 60) | depot sites and platform layouts checked only what stood on the ground | AI depot sites and their platforms keep clear (3 tiles) of every piece a line still has to lay (`covers_planned`, any force on the surface, per-line bounding box); a depot placed by hand takes such a platform layout first and any that fits after it, as before | `scripts/rails.lua` | M1 501 (section 4.4) |
| The AI's tax switched 3 times in an hour for one nation in 4 of ten 4-nation runs (the contract: <= 2 per nation-hour) | high for a deficit or a war, back to normal when the money was in, high again at the next war or deficit (802 rts-player: normal at 25:00 and a war 20 s later) | At most `max_per_hour` (2) switches in any hour; unrest (happiness below happy_low) and debt pass the cap; the acceptance probe checks it (`check tax`) | `scripts/market.lua`, `balance.nation.market.ai.hysteresis.max_per_hour` | 802, 702, 705 reruns (section 4.2) |
| Wave B.2: a line blocked for good stayed blocked (the lead's item 1) | a crew retried the piece every step; nothing changed the plan | A ghost that does not revive while the rail itself fits the manual check (a hauler or its legs on the tile: 13 of the 40 blockers in all logs) is built outright. A line blocked at piece i for `rails.DETOUR_AFTER` (2 minutes, doubling per attempt) gets a detour: pieces within `DETOUR_SPAN` (6, then 12, then 24) of i on both sides are taken up (laid rails, their signals and supports back to depot A), a survey runs from the end of the last kept piece (depot A's platform when none is kept) to the start of the first kept one after it (depot B's platform), and its path is spliced in; crews go home or look for their frontier again; a failed detour leaves the plan as it was | `scripts/rails.lua` (`start_detour`, `apply_detour`) | `tools/probes/m3_detour.lua` |
| Wave B.2: an AI's depot kit waited for 40 iron, 10 steel and 10 copper at one check (the aggressive AI's capital held no copper from 13:00 to 20:00; the lead's item 3) | `ai_pay` paid a craft all at once or not at all | AI depot and kit crafts are paid through an escrow per rail program (`A.escrow[recipe]`): what the network spares of each ingredient above `AI_RESERVE` plus `AI_ESCROW_FLOOR` (60 iron, 60 copper, 20 circuits left for the barracks) is held until the bill is complete | `scripts/rails.lua` | M1 501, 801-805 |
| Wave B.2: the town site search cost up to 9.5 ms in one tick (m3-ai's perf bench; the lead's item 2) | `cities.ai_step` did not declare that it waits for a "pending" search | `cities.TOWN_PENDING_OK = true`: ai/towns.lua runs the search as a planning job | `scripts/cities.lua` | m3-ai's 4-nation perf bench: pick_site gone from the >3 ms ticks |
| Wave B.2: the player slot sold its captured port's 100 circuits in 6 of 20 runs, rts-ai-1 in 20 of 20 (the lead's slot diagnosis) | `ai_wanted` held a port's goods for the trip home whether or not a hauler served the route, racing the strategist's sale (staggered by slot in force-name order) | goods are held for home only while a hauler serves the port route | `scripts/market.lua` | slot diagnosis |
| Wave B.2: an AI-driven rts-player's garrison, troop train and mercenary divisions had owner "player" (latent; the AI controller ignores those) | owner from `match.ai_forces()`, which never lists rts-player | owner "ai" whenever `diplomacy.is_ai(force)` | `scripts/garrison.lua`, `scripts/sinks.lua` | war fixture 27/27 |
| Wave B.2: an economic AI at power ratio 4.58 sued for a ceasefire on 38 % weariness in the middle of its siege (war-paths probe) | weariness alone was enough to offer | an offer on weariness alone only below `balance.nation.diplomacy.weary_ratio` (1.0); a ratio below cf_ratio still offers as before; acceptance unchanged | `scripts/diplomacy.lua`, balance | 801-805 |
| Wave B.2: `market.ai_step` cost 2.3-3.2 ms inside one AI run (m3-ai's 4-nation bench; the perf scene on 705a33a: 2 ticks over 3 ms, worst 3.65) | the whole market pass (taxes, envoy, route, haul home, sales, purchases, restores) ran in one commander run, the capital's ledger read in it | four slices on consecutive AI runs (taxes and envoy; route and haul home; sales; purchases and restores), the ledger rows read once a pass and kept in the AI's market state until the purchases | `scripts/market.lua` | perf scene (section 6) |

### C. HUD and UX

A GUI audit of every M3 panel in English and Russian at 1280x800 (a helper of this package; probe
`tools/probes/m3_docs_gui.lua`, which plays the M3 protocol's steps in order with real clicks, keys and right clicks
through `tools/gui-drive.sh` and checks each one 1.5 s later: English 53/53 PASS, Russian 48/53 with the 5 misses only
English coordinates of the Russian layout; screenshots `build/shots-m3i-{en,ru}/`, window captures
`build/shots-m3i-{en,ru}-window/`, earlier passes `-run1`..`-run3`). No raw key anywhere, no raw station name on the map.

| Finding | Fix | Where |
|---|---|---|
| F10 menu and the results window cut the Nation config line ("...Conquest + Spac...") | the line wraps | `scripts/lobby.lua` |
| The air panel (Y) covered the "World: N % generated" line under the minimap | the panel starts below it (`airgui.TOP` 282 GUI units) | `scripts/airgui.lua` |
| The market's Trade at drop-down cut the city-state entries | 280 wide | `scripts/marketgui.lua` |
| The staffing box after automation read "7.8 of 7.84 workers" | jobs rounded to one decimal | `scripts/citygui.lua` |
| The Russian goal line on the strip was cut | shorter Russian goal texts (conquest_space, any, territory) | `locale/ru/age3.cfg`, `diplomacy.cfg` |
| "Mercenaries (Port of X)" cut on the division card | name button 220, and the division is named after the region's proper name ("Mercenaries (Karvis)") | `scripts/divisiongui.lua`, `scripts/sinks.lua` |
| An artillery train's gun line before its first shot read "last target: none (0 tiles)" | "looking for a target, next shot in N s" | `scripts/trainswar.lua`, `locale/*/war3.cfg` |
| The depot panel's shared reason "Cannot deploy a train: ..." stood above an enabled Deploy artillery train | "Freight and troop trains: ..." | `scripts/railgui.lua`, `locale/*/rails.cfg` |
| Russian wording: нации/страны/вольный город/Эпоха II/отряды/комплекты/семья | державы, город-государство, II эпоха, юниты, наборы, семейство (item names unchanged) | `locale/ru/*.cfg` |
| A fort belt laid across a rare extractor's drop tile stopped it and its bonus ran out | the belt layout leaves the drop tile of every own mining drill near the line free | `scripts/belts.lua` |
| The "Depot N" chart labels were unreadable at map zoom (world-sized scale 1.6) | world-sized at scale 8, like the strategic labels (a screen-sized label covered the HUD minimap) | `scripts/rails.lua` |

After this package's later GUI changes (the Ready column, the artillery train's depot position, world-sized depot
labels, the stage 1 goods) the probe ran again on HEAD 1851531 / 9c60893: English 50/53, Russian 48/53, 0 Lua errors
(`build/shots-m3i-{en2,ru2}/`, window captures `build/shots-m3i-{en2,ru2}-window/`); every miss is a placement site of
that run's world (the Steel works and the AA turret sites taken by the Launch complex or walkers; the Russian layout's
own coordinates for the build tabs, Hire and the air panel's x, which the protocol gives), and the probe's fallback
went on. The map shows "Депо 1" next to the depot and no raw station name (`m3d-g05-map-z010.png`).

Checked and unchanged: the F11 page in its scroll pane (fits y 74-722, 11 paragraphs, Y/F/B/H in the keys, Russian
reads well), "Needs Age III" for Chemistry, Nuclear power and Air Force, the lobby (Nations 2-6, 2048/3072/4096,
Explore/Survey, the victory list, the generation line) in both languages, the 4096 progress line, the front lines and
labels, and the airfield picture (it reads as an airfield at game zoom).

### D. Acceptance tooling

| Tool | What |
|---|---|
| `tools/probes/m3_acceptance.lua` | EXTRA_LUA for the 4-AI end-to-end runs: the M2 criteria (trade, war, peace, capture, starving; the last 5 minutes at speed 1) and per nation Age II and III, the first open line, items by train, the lowest balance, the highest debt stage, minutes in debt, the credit line, tax switches, capital depots destroyed, and every 10 minutes the M3 modules' describe lines (Space Program, rare, sinks, air, belts, war trains, fronts) |
| `tools/probes/m3_integ.lua` | collateral damage (lanes A-D, raiders as info), the rail planner over a fort belt, the human flag |
| `tools/probes/m3_reroute.lua` | a train routed by hand comes back to its route when its lost depot returns |
| `build/m3i-tools/mktree.sh` | frozen test trees: `mods/` with `scripts/ai/` from HEAD (or live) |

## 3. Shared code touched

Every file except `scripts/ai/*` (m3-ai's) and m3-ai's sub-tables of `balance.lua`. Hunks are marked `-- Phase 5 M3
integration`; m3-ai's hunks applied here are marked `-- Phase 5 M3 ai`.

| File | What |
|---|---|
| `scripts/targeting.lua` | collateral damage undone and the entity protected for 10 s; belts, inserters, pipes in the damage filter; `targeting.expose` for any protected entity |
| `scripts/rails.lua` | re-route of trains routed by hand when a depot returns; "Depot N" chart labels and hidden station names; own walls and gates crossed (cost, gates); m3-ai's `A.pay` (H1) and the freight trains of a line only ahead of its crew (H4, adapted: freight records carry no `line`) |
| `scripts/fronts.lua` | the refresh job on the scheduler (`fronts_refresh`) |
| `scripts/population.lua` | the dead AI governor removed; the loose-building pass sorted and budgeted |
| `scripts/selection.lua`, `logistics.lua`, `warsupply.lua` | deterministic orders (Nation sort, init snapshot, sorted sums) |
| `scripts/diplomacy.lua` | the human flag |
| `scripts/debug.lua` | `AUTOTEST_ENABLED`; `/rts-front`, `/rts-deposit` |
| `scripts/cities.lua` | worldgen required at load (the crash), ungenerated sites skipped and requested; m3-ai's "pending" no-try rule |
| `scripts/hud.lua` | the help page in a scroll pane, its paragraphs and keys |
| `scripts/techgui.lua` | "Needs Age III" |
| `scripts/sinks.lua`, `age3.lua`, `ages.lua` | a rush pays only while it speeds something up |
| `scripts/market.lua` | no low tax in debt; m3-ai's `no_buy` (H5) |
| `scripts/treasury.lua` | the credit line decays; m3-ai's H2 (no hard tax bonus) |
| `scripts/belts.lua` | drill drop tiles left free |
| `scripts/lobby.lua`, `airgui.lua`, `marketgui.lua`, `citygui.lua`, `divisiongui.lua`, `railgui.lua`, `trainswar.lua` | the GUI audit's fixes (C); `/rts-match` help lists conquest_space and any |
| `prototypes/air.lua` | the airfield picture and icon |
| `prototypes/rails.lua` | Railways 10 kits |
| `balance.lua` | `treasury.credit.decay`, `age3.techs` Electrification 25, `age3.stages[1]` |
| `locale/{en,ru}/*.cfg` | help paragraphs and keys, "Needs Age III", the держава wording, the GUI audit's keys and texts |
| `tools/autotest-run.sh`, `perf-bench.sh`, `heavy-mode.sh`, `lan-check.sh` | `AUTOTEST_ENABLED` set in the test copy |
| `tools/probes/m2_integ.lua`, `age3_fixture.lua` | census wait; the research rush charge rule |

## 4. Acceptance in detail

The final HEAD is **dad7a40** (this package's aaf8764 on m3-ai's 1f28ccb + dad7a40). `build/m3i-tools/final.sh <rev>
<tag> <steps>` runs everything below on a `git archive` of the revision, at most four headless servers at a time
(tags `f1` = 705a33a, `f2` = dad7a40; outputs `build/m3i-<tag>-*`, `build/final-<tag>/`).

### 4.1 Save and load (dad7a40)

`SAVE_MINUTE=20|40 SPEED=8 DURATION_MIN=60 SEED=802 tools/saveload-check.sh m3i-f2-sl20|40 '<4 nations, 2048>' 400`:
saved at minute 20 (towns, trunk lines building, scheduler jobs in flight) and at minute 40 (wars, captures, Space
Programs running, fronts, belts), loaded and played on to minute 61: **0 errors in all four halves**. On 705a33a the two
loaded games reached the same state lines at minutes 60 and 61 (`units 68 kits 138`, `units 70 kits 141` for
rts-player in both).

### 4.2 M3 end-to-end: 4 normal AIs, 60 minutes, 2048, seeds 801-805 (dad7a40)

```sh
PERF=1 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m3_acceptance.lua DURATION_MIN=60 SEED=801 SPEED=8 \
  tools/autotest-run.sh m3i-f2-801 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
  enemy_brain = "ai"}' 12000
```

| Seed | AI autotest | Lowest trade (₡) | Wars / back to peace | Cities changed hands | Starving | Debt (stage) | Lowest balance | First Age III | 3 cities linked by 35:00 | Speed-1 minutes (s) |
|---|---|---|---|---|---|---|---|---|---|---|
| 801 | 82/83 | 4,228 | 4 / 3 | 8 | none | none | ₡ 234 | 44:21 | 3 of 4 | 60.0 x4, 60.2 |
| 802 | 77/83 | 5,753 | 2 / 2 | 3 | none | none | ₡ 499 | **33:03** | 2 of 4 | 60.0 x4, 60.2 |
| 803 | 81/83 | 5,575 | 7 / 6 | 9 | none | none | ₡ 246 | 47:12 | 2 of 4 | 60.0 x4, 60.2 |
| 804 | 82/83 | 5,047 | 6 / 5 | 7 | none | rts-player (3) | ₡ -552 | **39:48** | 2 of 4 | 60.0 x4, 60.2 |
| 805 | 81/82 | 5,741 | 4 / 3 | 8 | none | none | ₡ 329 | 42:59 | 1 of 4 | 60.0 x4, 60.1 |

0 Lua errors in every run; nobody at the credit line; tax switches 1.00-1.25 per nation-hour. **M2 criteria** (trade,
war, peace, capture, no starving): 5 of 5. **Money**: a nation in a debt stage in 1 of 5 seeds (the target is 2 of 5;
the AIs keep a reserve of ₡ 234-499). **AI criteria** (§4 of the contract, from the ai3 summary): every nation founds
3-8 cities (20 of 20); operations with phases in 19 of 20 nations (802 rts-ai-2 none); a fort belt built in 5 of 5
seeds; air patrols in 3 of 5 seeds (801, 802, 805); three cities linked by rail by 35:00 for 10 of 20 nations (the
aggressive rts-ai-1 links at 37-57 or not at all); **Age III by 40:00 in 2 of 5** (802, 804; 802's rts-ai-2 at 40:13).

The same set on 705a33a (`f1`, before m3-ai's 73f045b-dad7a40 and this package's aaf8764): debt 2 of 5, starving 1 of 5
(801), linked 15 of 20, air patrols 5 of 5, Age III by 40:00 0 of 5 (40:10, 43:19, 41:46); with army upkeep 0.8 (A/B
arm) debt 0 of 5 and Age III 0 of 5 (section 2.A).

### 4.3 M2 acceptance: seeds 701-705 (the same fixture and match, dad7a40)

| Seed | AI autotest | Lowest trade (₡) | Wars / back to peace | Cities changed hands | Starving | Debt | Speed-1 minutes (s) |
|---|---|---|---|---|---|---|---|
| 701 | 79/82 | 5,048 | 6 / 5 | 6 | **city 12** (rts-ai-1's town from 40:00, then rts-player's after its capture, from 50:00) | none | 60.0 x4, 60.2 |
| 702 | 81/83 | 5,988 | 6 / 5 | 6 | none | none | 60.0 x4, 60.2 |
| 703 | 82/83 | 5,232 | 6 / 4 | 13 | **rts-ai-3** (city 12 from 55:00) | none | 60.0 x4, 60.2 |
| 704 | 82/83 | 4,563 | 6 / 6 | 10 | none | rts-ai-2 (2) | 60.0 x4, 60.2 |
| 705 | 81/83 | 4,884 | 6 / 6 | 9 | none | none | 60.0 x4, 60.2 |

Trade, war, peace and capture pass in 5 of 5; starving in 2 seeds (the tolerance is 1). On 705a33a the same five seeds
had no starving city (m3-ai's export policy of 3ea458e fixed 701 and 702); the two cases came back with the last AI
round (73f045b-dad7a40: the barracks heartbeat and pin) or this package's market slicing; not bisected (open issue).

### 4.4 M1 acceptance (1v1, seed 501, 60 minutes, `m1_acceptance.lua`, dad7a40)

**52/52, all passed**, in two runs (SPEED 6 and 10: 66,906 `[rts]` lines, 0 differing): both rail lines open (rts-player
21:49, rts-ai-1 30:01), 19,285 items by train (rts-player 6,230 in 35 trips, rts-ai-1 13,055 in 78), produce passes for
both; the aggressive AI took the player's capital at 59:10 and the match ended at 59:18 (winner rts-ai-1), so the
train-items goal (20,000 at minute 60) reads "not due" and one 60-minute check is not reached. On 705a33a: 51/53
(produce_rts-player, train_items 17,433), twice identical.

### 4.5 Earlier trees

#### Save and load (c1c920d)

`SAVE_MINUTE=20|40 SPEED=8 DURATION_MIN=60 SEED=802 KEEP_TREE=<HEAD c1c920d> tools/saveload-check.sh m3i-sl20|40 '<4
nations, 2048>' 400`: saved at minute 20 (towns, trunk lines building, scheduler jobs in flight) and at minute 40 (wars,
captures, Space Programs running, fronts, belts), loaded and played on to minute 61: 0 errors in both halves of both runs;
after the load the scheduler resumed every nation's jobs (`sched: minute 21 ... ended`) and the wars, treaties and
captures went on.

#### M3 end-to-end on c1c920d

```sh
PERF=1 KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m3_acceptance.lua DURATION_MIN=60 SEED=801 SPEED=8 \
  tools/autotest-run.sh m3i-acc-801 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
  enemy_brain = "ai"}' 12000
```

The tree is HEAD c1c920d (801-803 ran on the identical tree `m3i-army12`, 804 and 805 as `m3i-acc6`). Every run: 0 Lua
errors, 60.0 s of wall clock per game minute at speed 1 in minutes 56-60 (60.2 in the last one, the autotest's end).

| Seed | AI autotest | Lowest trade (₡) | Wars / back to peace | Cities changed hands | Starving | Debt (stage) | At the credit line | Lowest balance | Age III by 40:00 | First lines at or after 25:00 |
|---|---|---|---|---|---|---|---|---|---|---|
| 801 | 81/83 | 3,513 | 3 / 2 | 2 | none | none | none | ₡ 500 | none (41:00 first) | 4 of 4 (27:11-53:22) |
| 802 | 79/83 | 1,976 | 3 / 3 | 3 | none | rts-ai-3 (3) | none | ₡ -364 | 1 (36:59) | 2 |
| 803 | 82/83 | 5,227 | 10 / 8 | 11 | none | none | none | ₡ 391 | none | 2 |
| 804 | 81/83 | 3,947 | 7 / 6 | 14 | none | none | none | ₡ 485 | 2 (35:58, 36:54) | 2 |
| 805 | 81/82 | 3,912 | 5 / 4 | 9 | none | rts-player (3) | none | ₡ -488 | none | 3 |

M2 criteria: every nation trades, wars, peaces and captures in 5 of 5, no starving nation. Money: a nation in a debt
stage in 2 of 5 seeds, nobody at its credit line. AI side (m3-ai's ai3 summary of the same runs): every nation founds
3-8 cities; 11 of 20 have three cities linked by rail by 35:00; every nation runs operations with phases (1-38); air
patrols fly in 9 of 20 nations; a fort belt is built in 6 of 20; Age III by 40:00 in 2 of 5 seeds (the contract wants
3 of 5; open issue). Costs in the speed-1 minutes: AI 0.39-0.51 ms/tick for four nations (0.10-0.13 per nation), M2
modules 0.035-0.059, M3 modules 0.052-0.074.

#### M2 acceptance on c1c920d

| Seed | AI autotest | Lowest trade (₡) | Wars / back to peace | Cities changed hands | Starving | Debt | Speed-1 minutes (s) |
|---|---|---|---|---|---|---|---|
| 701 | 80/82 | 3,321 | 4 / 4 | 6 | **rts-ai-1** (its town from 34:00) | none | 60.0 x4, 60.2 |
| 702 (aaa8061) | 79/83 | 5,418 | 6 / 4 | 6 | **rts-ai-2** (a far "trade" city from 52:00) | none | 60.0 x4, 60.2 |
| 703 | 81/83 | 4,502 | 6 / 4 | 5 | none | none | 60.0 x4, 60.2 |
| 704 | 81/83 | 1,774 | 1 / 1 | 3 | none | player (1), rts-ai-3 (3) | 60.0 x4, 60.2 |
| 705 | 81/83 | 4,407 | 3 / 2 | 4 | none | player (1) | 60.0 x4, 60.2 |

Trade, war, peace and capture pass in 5 of 5; the starving criterion (at most 1 seed) fails with 2 seeds: in 701 the
town's ration hauler was taken over by the planner's Age III export haul (65 batteries over 725 tiles), in 702 a far
city without a farm ran dry; both are AI governance (sent to m3-ai). The first 702 run (c1c920d) found the failing-survey
loop of section 2.B (sched 3.44 ms/tick in minutes 55-60); with aaa8061 the scheduler costs 0.11 ms/tick there.

#### M1 acceptance on 1851531

HEAD 1851531: **53/53**, 0 errors, 23,259 items by train (rts-player 9,340 in 48 trips, rts-ai-1 13,919 in 76 trips;
goal 20,000; wave A 22,999, M2 26,612), both nations alive, 60 UPS in the speed-1 minutes. On the first integration tree
(3edd55b with the wave A AI) 53/53 with 22,822 items and no capital depot lost.

## 5. Checks of this package

### 5.1 Skirmish unchanged

`KEEP_TREE=<tree> SEED=777 build/m3i-tools/matrix-batched.sh <tag>` (the ten scenarios of `tools/autotest-matrix.sh`,
four at a time) on `m2-ready` (497cb1c, `m3i-m2ready`) and on the integration HEADs, compared with
`tools/matrix-compare.sh` (it now also drops the Nation-only plane ammo categories and the AA turret from the static
research line, as it did for the garrison gun):

| Scenario | m2-ready | HEAD 4de0bc6 (`m3i-h4de0`) | `[rts]` lines | Differing |
|---|---|---|---|---|
| 1v1-easy-medium | 23/23 | 23/23 | 1,211 | 0 |
| 1v1-hard-medium | 20/23 | 20/23 | 4,037 | 0 |
| 1v1-normal-medium | 23/23 | 23/23 | 3,240 | 0 |
| 1v1-normal-small-nosa | 23/23 | 23/23 | 3,294 | 0 |
| 1v1-normal-small-restart | 22/23 | 22/23 | 4,450 | 0 |
| 1v2-normal-medium | 31/31 | 31/31 | 4,491 | 0 |
| 1v3-normal-small | 39/39 | 39/39 | 5,024 | 0 |
| 1v3-normal-small-stress | 34/38 | 34/38 | 3,333 | 0 |
| legacy-units, legacy-units-nosa | 65/65, 65/65 | 65/65, 65/65 | 468, 469 | 0 |

The hard, restart and stress failures are m2-ready's own (as in the M2 integration).

### 5.2 Fixtures

On the final HEAD dad7a40: `m3_integ.lua` 6/6, `age3_fixture.lua` 35/35 (stage 1 at 100 concrete), `m3_detour.lua` 2/2
with the rails autotest 8/8, `war_autotest.lua` 27/27, Skirmish smoke 65/65; 0 Lua errors. The list below is the
earlier pass (HEAD 4de0bc6-1851531) and the wave B.2 tree:

| Fixture | Result |
|---|---|
| `m3_integ.lua` (collateral lanes A-D, wall crossing, human flag), 1v1 Nation seed 501 | 6/6 (collateral hits undone 12; lanes A and B lose nothing; an explicit attack and a division strike destroy their factory, the belts beside the strike survive) |
| `m3_reroute.lua` (seed 501, 45 min) | 2/2 |
| `m2_targeting.lua` | 5/5 |
| `m2_integ.lua` | 11/11 (the census wait) |
| `war_autotest.lua` (M2) | 27/27 |
| `war2_autotest.lua` (fronts on the scheduler) | 22/22 |
| `air_autotest.lua` | 14/14 |
| `age3_fixture.lua` | 35/35 (the research rush charge rule) |
| `m3_detour.lua` (wave B.2: the rails autotest's main line with a foreign furnace on piece 103 of 309; 1v1 Skirmish beside it, speed 4) | 2/2 and the rails autotest 8/8: blocked at piece 103, the crew went home, detour survey of pieces 98..108 in 0.1 s (5 pieces for 11), line open 344 s after the furnace with the bill exact (535 rails, 0.0 %), then a freight train over the detour, the cut, the repair and the resumed deliveries |
| `war_autotest.lua` on the wave B.2 tree (garrison owner) | 27/27 |
| Skirmish smoke | 65/65 before every commit |

### 5.3 LAN and heavy mode

**Final HEAD dad7a40**: `KEEP_TREE=<dad7a40> SEED=701 tools/heavy-mode.sh m3i-f2-heavy 10`: the 4-nation match saved at
tick 3,600 and played in the GUI client with `--heavy` for 10 minutes of wall clock: ticks 3,600-4,200, **0 desync
lines, PASS**, no Lua error (the client's "Steam API could not be initialized" is the environment).
`KEEP_TREE=<dad7a40> SEED=701 tools/lan-check.sh m3i-f2-lan 10 5`: a headless 4-nation server, GUI client 1 joined at
tick 1,636, client 2 at minute 5 by hand-over (tick 22,819); **0 desync lines** on the server and both clients, 33 and 25
checksum lines equal to the server's, no Lua error: **PASS**.

Earlier (HEAD 1851531):

`KEEP_TREE=<HEAD 1851531> SEED=701 tools/lan-check.sh m3i-lan1 10 5`: a headless 4-nation server, GUI client 1 from
tick 1,716, client 2 at minute 5 by hand-over (one Steam account: the server refuses the same player name twice); 0
desync lines on the server and both clients, 34 and 24 checksum lines equal to the server's, no Lua error (the clients'
"Steam API could not be initialized" is the environment). The joining player made rts-player a human nation
(`diplomacy: rts-player is played by a human from tick 1716`), the same on every peer.

`KEEP_TREE=<HEAD 1851531> SEED=701 tools/heavy-mode.sh m3i-heavy1 10`: the 4-nation match saved 60 s after its start
(tick 3,600) and loaded in the GUI client with `--heavy` (save, load and compare every tick) for 10 minutes of wall
clock: ticks 3,600-4,200+, 0 desync lines, no desync report, no Lua error. Heavy mode runs about one tick a second on a
2048 world, so 10 minutes of wall clock are 10 s of game; the headless save/load equivalence (section 4) covers whole
minutes.

## 6. Performance

**Final HEAD dad7a40** (`KEEP_TREE=<dad7a40> SEED=701 REALTIME=5 tools/perf-bench.sh scene m3i-f2-scene 5`): wholeUpdate
mean 1.369 ms (p50 0.980, p95 2.617, p99 5.282, max 24.1), scriptUpdate mean 0.427, UPS capacity 731; 4 ticks over
16.67 ms, at the autotest's minute reports (test code); on a headless server at speed 1 **60.0 s per game minute**
(59,987 / 60,008 / 59,998 / 60,005 ms). PERF over the benchmarked minutes: all modules 0.419 ms/tick, AI 0.254 (0.063
per nation), M2 modules 0.025, M3 modules 0.013. Script ticks over 3 ms by mark: commander.run 17 (worst 5.98 ms),
market.ai_step 1 (3.54 ms; 2 at 3.65 ms before its slicing on 705a33a). In the 4-nation end-to-end runs (section 4.2)
the AI commanders cost 0.49-0.93 ms/tick for four nations in minutes 56-60 (0.12-0.23 per nation). Determinism on
dad7a40: seeds 801 and 802, 30 minutes, 214 and 209 event lines, 0 differing.

Earlier, on HEAD 9c60893:

**Budget scene** (`KEEP_TREE=<HEAD 9c60893> SEED=701 REALTIME=5 tools/perf-bench.sh scene m3i-scene1 5`: 4 nations, 16
cities, 604-608 units of which 371-431 moving, 40 freight trains):

| Per tick, 18,000 benchmarked ticks | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| wholeUpdate (ms) | 1.698 | 1.240 | 3.590 | 6.832 | 26.1 |
| scriptUpdate (ms) | 0.546 | 0.041 | 2.231 | 5.060 | 24.7 |
| entityUpdate (ms) | 0.802 | 0.786 | 1.043 | 1.232 | 2.8 |

UPS capacity at the mean tick 589; 8 ticks over 16.67 ms in five minutes, the five worst at the minute boundaries where
the AI autotest's minute report and the scene fixture log (test code, 10-13 ms of `ai/autotest`). The same save played
on a headless server at speed 1: **60.0 s of wall clock per game minute** (59,995 / 60,005 / 59,997 / 60,005 ms).
PERF per module over the realtime minutes: all modules 0.577 ms/tick, AI 0.353 (0.088 per nation), M2 modules 0.035,
M3 modules 0.020 (sched 0.016, fronts 0.001, belts 0.001, age3 0.001, rare 0.001).

**Determinism** (`PARALLEL=1 WHAT=events KEEP_TREE=<HEAD 9c60893> tools/determinism-compare.sh m3i-det-<seed> '<4
nations>' 30 <seed>`: two fresh saves of the same seed, 30 minutes each): seed 801 202 event lines and seed 802 207
(city sites and foundings, captures, wars, treaties, start lines, rail lines and surveys), **0 differing** in both.

**Reproducibility of the autotest runs** (wave B.2, the lead's item 4): the same frozen tree (903a7b1 + this package's
rails fixes), M1 seed 501, at SPEED 6 and at SPEED 10: 56,137 `[rts]` lines up to the autotest summary, **0 differing**
(`build/m3i-tools/runcmp.py`, the matrix comparison's normalisation; both 52/53 with the same failure). The mod and the
probes read no wall clock and no game speed (profilers are only logged, scheduler budgets are work units); the harness's
cap is a wall-clock stop that cuts a run, it never changes one. The spread of 51-53 on seed 501 came from different
trees (m3-ai confirmed it in its notes, section 6 item 8).

m3-perf's measurement of m3-age3's sliced treasury census (perf notes §6a, synced tree): a slice costs 0.058 ms on
average and 0.15 ms at worst, the treasury step 0.79 ms; the 600-tick census it replaced cost up to ~8 ms in one tick.

## 7. Open issues

1. **Age III by 40:00 in 2 of 5 seeds** (contract 3 of 5): Electrification waits for industrial kits (steel, engines,
   advanced circuits) and stage 1 for concrete. This package moved stage 1 to 100 concrete and left the AI 50 steel in
   the escrow; m3-ai's dad7a40 holds engine kits back while Electrification lacks engines. The rest is the AI capital's
   production (m3-ai).
2. **Three cities linked by 35:00 for 10 of 20 nations**: the aggressive AI (rts-ai-1) links at 37-57 or never; its
   capital spends its iron, steel and circuits on the army. The escrow (wave B.2) gives every program its depot and
   kits in time once the plates are there (705a33a: 15 of 20); the last AI round (barracks heartbeat, pin) took part
   of that back (m3-ai's dad7a40 limits them).
3. **Money: a debt stage in 1 of 5 seeds** (target 2 of 5) on the final tree; 2 of 5 on 705a33a and c1c920d. The AIs
   now keep a reserve (lowest balances ₡ 234-499 in four seeds). Army upkeep 1.3 (or a smaller AI reserve) is the
   lever if QA wants the pressure back; 0.8 gives no debt at all (A/B, section 2.A).
4. **Starving towns in M2 701 and 703** (tolerance 1 seed; 0 on 705a33a): city 12 in both, a mining town supplied by a
   hauler. Came with the last AI round or this package's market slicing; not bisected.
5. **Worst AI ticks**: 17 commander runs over 3 ms in the perf scene (worst 5.98 ms; town-site search gone with
   TOWN_PENDING_OK), market.ai_step once at 3.54 ms after the slicing (the capital's ledger read).
6. **Air, holds and artillery in the AI's war**: patrols in 3 of 5 seeds; interceptors, bombers, artillery trains
   and holds 0 in every run. Their balance (air kits, AA, artillery, armoured stock) stays at wave A's first guesses.
7. **AI armies do not shrink in debt** (m3-ai): nobody reached the credit line in 20 seeds.
8. **The research Rush can be started with no industrial kits in stock**; it costs nothing until a lab works.
9. **4096 x 6 start**: planning 2.5-3.2 s and the forced core 2.6-2.9 s block the start for about 5 s (world3's; core
   ≤ 3 s holds).
10. **M1 seed 501** ends at 59:18 with the aggressive AI taking the player's capital: 52/52, but the 60-minute
    train-items goal reads "not due" (19,285 items by then).

11. **Per-seed AI outcomes are sensitive to small changes** (finding): on seed 802, dad7a40's rts-ai-1 opens no line;
    the same tree without the escrow's steel floor, or without the market slicing, gives it a first line at 28:10 and
    three linked cities at 30-31 (first differences at minute 21 and minute 3). Every run is deterministic, but a
    seed's war outcome flips with any perturbation, so single-seed comparisons between trees carry a spread of about
    one nation per seed.

Fixed in this package from the earlier lists: fights razing belts and plain buildings, trains stuck after a lost depot
came back, raw stop names on the map, the failed-survey loop, blocked rail lines (detour), the depot kit's all-at-once
payment, the town-site search in one tick, the tax switch count, the port-loot race against the player slot, the
AI-run player's division owner, ceasefires on weariness while winning, the market pass in one run, mercenary names,
the air panel's Ready column, the artillery train's position.
