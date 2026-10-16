# Phase 4 integration (Wave C): validation, fixes and tools

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`. Plan: `docs/PHASE4.md` section 8,
wave C. Module notes: `docs/qa/phase4-*-notes.md`. Balance numbers: `phase4-balance-notes.md` ("Economy pass").

## Status

- **Zero Lua errors** in every run below: two validation matrices, the restart and save/load checks, both Space Age
  variants, the headless and GUI probes, and four GUI self-test runs (English and Russian).
- **60 UPS everywhere at game speed 1**, including 1v3 with 420 extra units. 1v3 small at speed 10 held 596–600 UPS,
  ten times the needed rate. The slowest module averaged 0.20 ms per tick (the AI); see "Performance".
- **Balance:** the economy pass is in (400 iron / 150 copper start, tier-1 research −25 %, cheaper lab and hub).
- **Fixed:** per-match state survived a match reset; a human could not build a hub at the natural expansion; the AI
  autotest judged easy by normal's deadlines; 20 player-facing texts disagreed with the game. See "Bugs fixed".
- **Lead decisions, round two** (all in): the Commander builds forward (robot radii unchanged); Concede in the F10
  menu and Results after the match; Ctrl+A leaves haulers out; the artillery strike uses the walker's 44-tile range; the dead
  AI lock exemption is gone; README and protocol updated. See "Round two".
- **Docs:** `README.md` rewritten for Phase 4; `docs/qa/phase4-protocol.md` is the 62-step GUI protocol for a
  screen-only tester.

## Validation matrix (final tree)

`tools/autotest-matrix.sh final2` (all scenarios in parallel, speed 1 unless noted, unseeded: each run draws its own
map seed). "Kits" are unit kits made by 8:00; "army" counts military units alive at 8:00 (haulers and the Commander
not counted). The first matrix (`final`, before round two) had the same errors, UPS and pass counts except where noted.

| Scenario | Lua errors | UPS (min over minutes) | AI ms/tick (max) | Autotest | Per side at 8:00: kits / army / technologies |
|---|---|---|---|---|---|
| 1v1 normal medium | 0 | 60 | 0.10 | 22/22 | player (economic) 34 / 15 / 4; AI (aggressive) 56 / 3 / 3 |
| 1v2 normal medium | 0 | 60 | 0.16 | 31/31, AI 2 won at about 7:00 | at 7:00: player 27 / 15 / 3 (CC lost 6:18); AI 1 38 / 0 / 2 (CC lost 6:20); AI 2 (economic) 31 / 28 / 4 |
| 1v3 normal small | 0 | 60 | 0.16 | 37/39 (see below; `final`: 39/39) | player 29 / 21 / 4; AI 1 43 / 0 / 2 (CC lost 5:35); AI 2 17 / 3 / 1 (CC lost 5:04); AI 3 (turtle) 19 / 9 / 3 |
| 1v1 hard medium | 0 | 60 | 0.11 | 22/22 | player 67 / 12 / 5; AI 138 / 47 / 2 |
| 1v1 easy medium | 0 | 60 | 0.06 | 22/22 | player 18 / 16 / 1; AI 23 / 9 / 1 (Phase 4 checks "not due" at easy pace) |
| 1v1 normal small, base game only | 0 | 60 | 0.09 | 22/22 | player 28 / 13 / 4; AI 61 / 10 / 3 |
| 1v1 normal small, restart at 4:00 (speed 3) | 0 | 179 | 0.11 | 22/22 + 5 restart checks | second match: player 50 / 8 / 4; AI 83 / 17 / 3 |
| 1v3 normal small + 105 units per side at 1:00 | 0 | 60 | 0.22 | 33/38 (see below) | load test, not a balance sample |
| Legacy Phase 1/2 unit autotest | 0 | – | – | 65/65 | – |
| Legacy unit autotest, base game only | 0 | – | – | 65/65 | – |

- **1v3 small: the failed checks follow the seed, not the code.** On 4 fixed seeds the tree before round two and the
  final tree give the same results: 2 seeds pass 39/39; 2 fail `outcome` (one side, the economic player, still
  produces at 9:00 while the others are crippled but not out) and one of them `harass_rts-ai-1`. The final2 run failed
  `produce_rts-ai-2` and `produce_rts-ai-3` (minutes without a kit while under attack, and a turtle AI that spent its
  iron on six turrets).
- **The stress run's failed checks are the load itself.** The spawned units put every side over its supply cap, so
  the barracks stopped (`produce_*`, `kinds_8min_rts-player`, `techs_6min_rts-player` with labs idle) and the
  player's 111-unit army ended the AIs (`outcome`).
- **Single runs are samples.** Use the seeded batches (`tools/autotest-batch.sh`) for balance questions.
- **Baseline before the fixes** (`build/matrix-base`): zero errors, 60 UPS; easy failed 6 Phase 4 checks, 1v2 failed 4
  (an economic AI that never set its attack size within 8 minutes, no hauler, no harass), 1v3 failed 1.

## Other checks

| Check | How | Result |
|---|---|---|
| Restart in the same session (Ctrl+Shift+R path) | `RESTART_AT=240` (`scripts/debug.lua` `restart_now`, `restart_audit`): `/rts-qa-reset nowaves` 4 minutes into the AI autotest, then the autotest again | `restart_new_match`, `restart_registries` (6 units, 5 buildings, 1 CC per side, none stale), `restart_match_state` (no alerts, hauler counters or hub numbers left), `restart_storage_clean` (484 LuaObjects in storage before, 94 after, 0 invalid, 0 on another surface), `restart_research_reset`: all PASS; the second autotest 22/22 |
| Save and load | `tools/saveload-check.sh`: 1v2 small stopped at minute 3 (the server saves on quit), a new server loads the save and runs 150 s | no load error, minute reports 4 and 5 logged after the load, 0 errors |
| Space Age on and off, data stage | `--create --check-unused-prototype-data` with two mod lists (`build/integ-data-sa`, `build/integ-data-base`) | both load, no warning |
| Space Age off, control stage | matrix rows "base game only" | 22/22 and 65/65, 0 errors |
| Locale, static | every `[section] key` in `locale/en` and `locale/ru` (580 each after round two, same keys, same `__N__` parameters); every literal key in the Lua code; every dynamic family (`rts.difficulty-*`, `rts.map-*`, `rts.size-*`, `rts.results-*`, `rts.match-*`, `rts.ability-*`, `rts.tech-tier-*`, `rts.tech-status-*`, `rts.patch-kind-*`, `rts.help-1..10`) expanded with the values the code uses; every `rts-*` prototype has a name | nothing missing |
| Locale, GUI client | `tools/locale-probe/gen.py` adds a probe to a GUI copy: the client translates 694 strings (all keys above plus every `rts-*` prototype's name) | 0 untranslated in English and in Russian; no "Unknown key" in any server or client log |
| Natural hub, cargo, Concede (headless) | `EXTRA_LUA=tools/probes/wavec_headless.lua` on small, medium and large | the Commander walks to the natural and its robots build a hub next to the natural iron (42–68 tiles out) 4–6 s after the ghost, with its own network; a hauler route CC → hub delivers iron and the hub's network holds it; `match.concede` ends the match as a defeat at once, a second call is refused |
| Menu (GUI) | `tools/probes/menu_gui.lua` in the real client, English and Russian | Ctrl+A selects the 7 combat units, not the hauler; the first Concede click asks "Really concede?", the second ends the match with a defeat and the results window ("Defeat. You conceded the match.", "Conceded at 00:06"); after Continue the menu shows Results and no Concede, and Results opens the window again |
| GUI self-test | `tools/gui-run.sh` with `SELFTEST_DEFAULT = true`: lobby start, selection, groups, orders, build placement, QA reset, hub and hauler panels, menu, unit cards, help, results, back to the lobby | `RTS_GUI_READY`, `RTS_LOGISTICS_GUI_DONE`, `RTS_P4_HUD_DONE`, `RTS_MATCHFLOW_DONE`, `RTS_HUD_DONE`; screenshots in `build/shots-integ-gui-en/` and `build/shots-integ-gui2/` |
| Commander field construction | `EXTRA_LUA=tools/probes/commander_field.lua`: hub and solar array ghosts 55 tiles out, the Commander walks there | built 7 s after the start; the pool paid 1 + 1; the trunk held only robots afterwards |

## Performance

- **Method.** `PERF=1` makes `scripts/events.lua` time every event handler with one accumulating `LuaProfiler` per
  registering module and log `[rts] perf` lines (ms per tick, averaged over each minute). The AI autotest logs its
  own AI time per tick and the wall clock per game minute (UPS).
- **1v3 small with 420 extra units** (105 per side at 1:00; about 450 units alive, then a battle that killed about 250
  of them within the next minute): 60 UPS in every minute. Highest module averages: AI 0.20 ms per tick, production
  0.09, logistics 0.023, orders 0.018, units 0.006. Nothing came near the 1 ms limit, so no hot spot needed a fix.
- **Headroom.** 1v3 small at game speed 10 ran at 596–600 UPS (`build/integ-headroom-1v3-server.log`).
- **One-off costs** stay as reported by the module owners: map generation and the AI's start lines (19–52 ms in one
  tick at match start), hub planning (once per hub).

## Bugs fixed

1. **A match reset kept the old match's state** (`scripts/match.lua:149`, `:744`, `scripts/logistics.lua:152`,
   `scripts/hud.lua:1728`). `storage.alerts` survived `match.teardown`, so after Ctrl+Shift+R or a new match from the
   lobby, F3 jumped to positions of the old arena and the alert lines showed old alerts. The hauler counters (trips,
   deliveries, losses), the "Hub n" numbering, the route and network caches and the kill feed carried over too. New
   `match.on_teardown(fn)`; logistics and the HUD clear their per-match state there. The restart check asserts it.
2. **A human could not build a hub at the natural expansion.** The CC's robots reached 40 tiles, the natural pair
   lies 50–76 tiles out, and the Commander's personal roboport built only from a trunk nobody can fill (no character,
   remote view); the AI revives its ghosts anywhere. Fix (accepted by the lead instead of larger robot radii):
   **Commander field construction** (`scripts/commander.lua` `field_supply`). The sweep stocks the Commander's trunk
   from the CC pool for the ghosts within its roboport radius (15) that no stocked network covers, and returns the
   surplus. The player selects the Commander, walks it to the natural and places the hub ghost; the hub is more than
   39 tiles from the CC, so it has its own network and haulers carry between them. A brief experiment with CC/hub
   construction radii 80/40 was reverted; the radii stay 40/22 and the natural pairs 48–84 tiles out.
3. **The AI autotest judged easy by normal's deadlines** (`scripts/ai/autotest.lua:65`, `:329`). Technologies, unit
   kinds, hub and harass deadlines now scale with `orders_data.TIME_SCALE` (easy ×1.5); a deadline past the test is
   reported as "not due".
4. **20 player-facing texts disagreed with the game** (en and ru, from the README and protocol reviews): the mod
   description and `info.json` (not 1v1 only), the CC (out rule, reach), factory, barracks, hub and hauler-kit
   descriptions, the Ctrl+Shift+R control text, Select all, the extractor hint (no pole needed in a power area), the
   power and build-menu tooltips, the lobby's difficulty and map tooltips, the help paragraphs Build order, Hubs (the
   home ore lasts 12–25 minutes, not 12) and Counters, Scanner sweep (30 s, 48×48), the Commander, the ruin alert.
5. **Tooling:** parallel headless runs collided on UDP ports (hash modulo 300); `tools/autotest-run.sh` now probes for a
   free port. `--create` without `--map-gen-seed` draws its seed from the clock, so samples launched in the same
   second were identical and later ones were unpaired; the batch runner now passes seeds.

## Round two (lead decisions after the README and protocol reviews)

| Decision | Done | Verified by |
|---|---|---|
| Reach: the Commander builds forward (accepted instead of radius 80/40, which was tried and reverted) | `scripts/commander.lua` field supply; help, README, protocol step 23 | headless probe on small, medium and large: the Commander walks to the natural and its robots build the hub, which has its own network |
| Concede in the F10 menu (a defeat with the results window), Results after the match | `scripts/match.lua` `concede`, `result_text_key`; `scripts/lobby.lua` menu; `scripts/hud.lua` strip text | GUI probe (en, ru), headless probe |
| Ctrl+A combat selection only | `scripts/selection.lua` `SELECT_ALL_SKIP` | GUI probe |
| Artillery strike range = artillery range (44) | `scripts/abilities.lua` reads `balance.lua` | code |
| AI unit locks | `research.AI_IGNORES_LOCKS` was set false by `ai/init.lua` on every difficulty; the dead path is removed (`scripts/research.lua`, `scripts/ai/init.lua`) | matrix: AI kinds still follow research |
| Texts | 20 items in `locale/en`, `locale/ru`, `info.json` | static check and GUI probe |
| Stale notes | `phase4-logistics-notes.md`, `phase4-research-notes.md`, `phase4-abilities-notes.md` | – |
| Protocol | step 23 walks the Commander to the natural and places Hub 1 there, step 34 moves iron from the CC to it, step 56 builds a middle hub with the Commander, step 59 concedes and reopens the results | not run by a tester yet |

## Fixes from the computer-use QA run (`phase4-qa-results.md`: 52 pass, 2 fail, 8 skipped)

| Finding | Cause | Fix | Verified by |
|---|---|---|---|
| Step 28: a hub's policy panel never reopened after its × | `hubgui.lua` cleared the "closed" flag only when the selection changed, and `destroy()` had already cleared the key it compared with, so a deselect did not count | the poll clears the flag as soon as the wanted panel differs from the closed one | GUI probe `hubpanel` |
| Step 8: a click on a walker's body selected nothing | the engine's selection box is centred one torso height above the feet; in the remote view the body is drawn about two torso heights up; a click between them hits no box | `selection.unit_at`: a click picks the nearest own unit whose feet, torso or drawn body (0, 1 or 2 × the prototype height up) lies within 1.5 tiles; units win over buildings; the engine's hits are the fallback. The prototypes' boxes stay: the engine already centres them on the torso | GUI probe `click` (0×0 areas with no engine hits) |
| A new factory showed the old one's "Crafted 6 / to network 6" | the line showed the force's totals, which also survived the match | per-factory counters (`rec.made`, `rec.moved`); `production.reset_match()` from `match.teardown` | GUI probe `factory` |
| Fighting went on behind the results window; F still armed after defeat | nothing stopped at the end | `match.lua` `calm_down`: every match force ceases fire on the others (`setup_forces` undoes it), every AI commander stops, every orderable unit stops; `orders.locked_reason` refuses F and right clicks after the end or while the player's side is out, with a flying text | GUI probe `end`; headless concede probe |
| A vanilla info box under the minimap, stale after construction | the remote view shows the hover tooltip for ghosts even with `show_entity_tooltip` off (real entities' tooltips were hidden) | hover selection off (`update_entity_selection` in `camera.lua`'s hidden chrome); R / Shift + R now rotate the own entity or ghost under the cursor (`rts-rotate`, `rts-reverse-rotate` follow the vanilla controls); a vanilla entity window that opens anyway is closed (`on_gui_opened`) | GUI probe `hover`, `entity_window`, `rotate` |
| Help said 80/40 reach | the frozen QA build predates the revert | help (Hubs) states 40 / 22 and the Commander flow, en and ru | text check |
| Truncated lines in the building panel and the order label | single-line labels | the building page's 2nd and 3rd lines wrap; the order label is 250 wide (was 200); the hub and extractor texts are shorter | GUI screenshot `rts-qafix-wrap-hub.png` |
| Protocol | coordinates and a stale remark | step 8 (click anywhere from the shell to the feet), step 23 (the natural iron's centre at ≈(704, 356), hub at ≈(560, 356)), step 36 (Auto-mode buttons at y≈314), step 52 (Ctrl+A has no hauler), a "Survival" note: keep the barracks running from step 22 | – |
| README | – | "Your first match" recommends Easy and says an aggressive Normal AI attacks at 3:00 | – |

## Moats on crowded small maps: not possible, documented

`scripts/mapgen.lua` (comment above `plan_moats`) and the lobby tooltip say why:

- The base ring (60 tiles, no terrain) pushes every moat's centre line to 68+ tiles from its CC. On the small spawn
  circle (88) that puts every moat 18–20 tiles from the arena centre, where the moats of 3 or 4 spawns cross.
- A Python model of the planner (same keep-out rules) found no fair moat for **1v3 small** at any moat distance
  (68–72), spacing (6–12), base ring (46–60) or middle-patch layout: AI 2 sits 60° from both neighbours, 88 tiles
  away, so its base ring overlaps theirs and its sides have no room.
- **1v2 small** gets 12–16-tile sides only with a 50-tile base ring and no middle patches, which would put water
  through the natural pair and remove the contested middle. Shorter sides do not help: the first slice next to the
  gap already collides with a neighbour's moat.
- Medium and large maps keep their moats (medium 1v3: 16 tiles per side). The flood-fill reachability check is
  unchanged and passed in every run.

## Load order (no change needed)

The handler order is the order modules are first required, not the list in `control.lua`: `scripts/ai/init.lua`
requires `supply`, `research` and `logistics` at its end, after it set its `on_entity_damaged` filter, so research's
union filter and then the abilities' Commander entry are set in the right order (`scripts/ai/deps.lua` explains it).
No event has two handlers that act on the same input twice: `rts-stop` is handled by orders, abilities (cancel an
armed ability) and the Commander, each for its own units, by design.

## Tools added (all in `tools/`)

| Tool | What it does |
|---|---|
| `autotest-run.sh <name> '<match table>' [cap]` | One headless autotest on a copy; options `VARIANT=base`, `SPEED`, `SEED`, `DURATION_MIN`, `DOCTRINES`, `RESTART_AT`, `PERF=1`, `STRESS=<s>:<n>`, `EXTRA_LUA`, `STOP_ON`, `KEEP_TREE` |
| `autotest-matrix.sh <tag> [filter]` | The matrix above, in parallel, with a one-line summary per run |
| `autotest-batch.sh <tag> <reps> <config>...` | Seeded paired samples for balance work (`config` = `1v<n>-<difficulty>-<size>`) |
| `saveload-check.sh <name> '<match table>'` | Save at minute 3, load in a new server, run on |
| `locale-probe/gen.py <mod> <out.lua>` | GUI-client translation probe |
| `probes/commander_field.lua` | Commander field construction probe (`EXTRA_LUA`) |
| `probes/wavec_headless.lua` | Natural hub by the Commander, hauler cargo between two networks, Concede (`EXTRA_LUA`) |
| `probes/menu_gui.lua` | GUI copy: Ctrl+A without haulers, Concede twice, results, Results again |
| `factorio-env.sh` | `RTS_LOCALE=en|ru` sets the GUI client's language (without it the client follows the system, Russian here) |

## Open items

- **Easy does not reach Phase 4 content within 8 minutes.** One iron smelter for the whole opening (Phase 3 design):
  first technology at 6:36–7:25, no hub, 2 unit kinds by 8:00. That is the AI owner's call (`OPENING.easy`).
- **1v3 small: the middle AI dies early.** AI 2 (at 0°) is 88 tiles from AIs 1 and 3; their rally points are within
  sight of each other, so skirmishes start in the first minute. It lost its CC at 1:34–6:32 in every 1v3 small run.
- **1v3 small: `outcome` fails on 2 of 4 seeds** (before and after round two): the economic player cripples the AIs
  without finishing them by 9:00. A test criterion question for FFA as much as an AI one.
- **Aggressive vs economic in 1v1 is lopsided** at normal: the aggressive AI lost its CC to the economic one by 8:00
  in 3 of 4 seeded 1v1 runs, before the economy pass and after it (after it, 2 of those matches ended outright).
- **The GUI protocol has not been run by a computer-use tester yet.**
