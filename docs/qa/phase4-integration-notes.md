# Phase 4 integration (Wave C): validation, fixes and tools

Date: 2026-10-16. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`. Plan: `docs/PHASE4.md` section 8,
wave C. Module notes: `docs/qa/phase4-*-notes.md`. Balance numbers: `phase4-balance-notes.md` ("Economy pass").

## Status

- **Zero Lua errors** in every run below: the validation matrix, the restart and save/load checks, both Space Age
  variants, and three GUI self-test runs (English, Russian, English after the last code change).
- **60 UPS everywhere at game speed 1**, including 1v3 with 420 extra units. 1v3 small at speed 10 held 596–600 UPS,
  ten times the needed rate. The slowest module averaged 0.20 ms per tick (the AI); see "Performance".
- **Balance:** the economy pass is in (400 iron / 150 copper start, tier-1 research −25 %, cheaper lab and hub).
- **Fixed:** per-match state survived a match reset; a human could not build beyond the CC's robot reach; the AI
  autotest judged easy by normal's deadlines. See "Bugs fixed".
- **Docs:** `README.md` rewritten for Phase 4; `docs/qa/phase4-protocol.md` is the 62-step GUI protocol for a
  screen-only tester.

## Validation matrix (final tree)

`tools/autotest-matrix.sh final` (all scenarios in parallel, speed 1 unless noted, default map seed). "Kits" are unit
kits made by 8:00; "army" counts military units alive at 8:00 (haulers and the Commander not counted).

| Scenario | Lua errors | UPS (min over minutes) | AI ms/tick (max) | Autotest | Per side at 8:00: kits / army / technologies |
|---|---|---|---|---|---|
| 1v1 normal medium | 0 | 60 | 0.09 | 22/22 | player (economic) 28 / 13 / 4; AI (aggressive) 55 / 0 / 3 (the player's army was in its base) |
| 1v2 normal medium | 0 | 60 | 0.16 | 30/30 | player 30 / 8 / 4; AI 1 (aggressive) 36 / 0 / 2, CC lost 6:12; AI 2 (turtle) 18 / 17 / 3 |
| 1v3 normal small | 0 | 60 | 0.19 | 39/39 | player 30 / 6 / 4; AI 1 71 / 3 / 2 (CC lost 8:59); AI 2 CC lost 3:58; AI 3 (economic) 40 / 5 / 5 |
| 1v1 hard medium | 0 | 60 | 0.09 | 22/22 | player 68 / 28 / 4; AI 135 / 47 / 3 |
| 1v1 easy medium | 0 | 60 | 0.05 | 22/22 | player 18 / 21 / 1; AI 21 / 11 / 1 (Phase 4 checks "not due" at easy pace) |
| 1v1 normal small, base game only | 0 | 60 | 0.10 | 22/22 | player 33 / 11 / 4; AI 54 / 7 / 3 |
| 1v1 normal small, restart at 4:00 (speed 3) | 0 | 180 | 0.08 | 22/22 + 5 restart checks | second match: player 42 / 7 / 4; AI 74 / 16 / 3 |
| 1v3 normal small + 105 units per side at 1:00 | 0 | 60 | 0.19 | 35/39 (see below) | load test, not a balance sample |
| Legacy Phase 1/2 unit autotest | 0 | – | – | 65/65 | – |
| Legacy unit autotest, base game only | 0 | – | – | 65/65 | – |

- **The stress run's 4 failed checks are the load itself.** The spawned units put every side over its supply cap, so
  the barracks stopped (`produce_*`, `kinds_8min_rts-player`) and the player's 111-unit army ended the AIs (`outcome`).
- **Single runs are samples.** Use the seeded batches (`tools/autotest-batch.sh`) for balance questions.
- **Baseline before the fixes** (`build/matrix-base`): zero errors, 60 UPS; easy failed 6 Phase 4 checks, 1v2 failed 4
  (an economic AI that never set its attack size within 8 minutes, no hauler, no harass), 1v3 failed 1.

## Other checks

| Check | How | Result |
|---|---|---|
| Restart in the same session (Ctrl+Shift+R path) | `RESTART_AT=240` (`scripts/debug.lua` `restart_now`, `restart_audit`): `/rts-qa-reset nowaves` 4 minutes into the AI autotest, then the autotest again | `restart_new_match`, `restart_registries` (6 units, 5 buildings, 1 CC per side, none stale), `restart_match_state` (no alerts, hauler counters or hub numbers left), `restart_storage_clean` (476 LuaObjects in storage before, 94 after, 0 invalid, 0 on another surface), `restart_research_reset`: all PASS; the second autotest 22/22 |
| Save and load | `tools/saveload-check.sh`: 1v2 small stopped at minute 3 (the server saves on quit), a new server loads the save and runs 150 s | no load error, minute reports 4 and 5 logged after the load, 0 errors |
| Space Age on and off, data stage | `--create --check-unused-prototype-data` with two mod lists (`build/integ-data-sa`, `build/integ-data-base`) | both load, no warning |
| Space Age off, control stage | matrix rows "base game only" | 22/22 and 65/65, 0 errors |
| Locale, static | every `[section] key` in `locale/en` and `locale/ru` (573 each, same keys, same `__N__` parameters); every literal key in the Lua code; every dynamic family (`rts.difficulty-*`, `rts.map-*`, `rts.size-*`, `rts.results-*`, `rts.match-*`, `rts.ability-*`, `rts.tech-tier-*`, `rts.tech-status-*`, `rts.patch-kind-*`, `rts.help-1..10`) expanded with the values the code uses; every `rts-*` prototype has a name | nothing missing |
| Locale, GUI client | `tools/locale-probe/gen.py` adds a probe to a GUI copy: the client translates 687 strings (all keys above plus every `rts-*` prototype's name) | 0 untranslated in English and in Russian; no "Unknown key" in any server or client log |
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
2. **A human could not build beyond the CC's 40-tile robot reach** (`scripts/commander.lua:325`, `:399`). The natural
   pair lies 50–76 tiles out, and the Commander's personal roboport built only from a trunk nobody can fill (no
   character, remote view). The AI revives its ghosts anywhere, so only the AI could place hubs at naturals. The
   Commander sweep now stocks the trunk from the CC pool for the ghosts within its roboport radius that no stocked
   network covers, and returns the surplus. README, the in-game help (`locale/*/hud.cfg:98`) and the protocol (step 56)
   describe it.
3. **The AI autotest judged easy by normal's deadlines** (`scripts/ai/autotest.lua:65`, `:329`). Technologies, unit
   kinds, hub and harass deadlines now scale with `orders_data.TIME_SCALE` (easy ×1.5); a deadline past the test is
   reported as "not due".
4. **The in-game help said the home ore lasts about 12 minutes** (`locale/*/hud.cfg:98`). That holds only with 8
   extractors at full speed; it now says 12–25 minutes (8 to 4 extractors) and how to build a hub at the next patch.
5. **The lobby's map tooltip promised moats on every map** (`locale/*/mapgen.cfg:10`). It now says a small map with 2
   or 3 opponents gets lakes and forests only.
6. **Tooling:** parallel headless runs collided on UDP ports (hash modulo 300); `tools/autotest-run.sh` now probes for a
   free port. `--create` without `--map-gen-seed` used the same seed every time, so "repeated" samples were identical;
   the batch runner now passes seeds.

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
| `factorio-env.sh` | `RTS_LOCALE=en|ru` sets the GUI client's language (without it the client follows the system, Russian here) |

## Open items

- **Easy does not reach Phase 4 content within 8 minutes.** One iron smelter for the whole opening (Phase 3 design):
  first technology at 6:36–7:25, no hub, 2 unit kinds by 8:00. That is the AI owner's call (`OPENING.easy`).
- **1v3 small: the middle AI dies early.** AI 2 (at 0°) is 88 tiles from AIs 1 and 3; their rally points are within
  sight of each other, so skirmishes start in the first minute. It lost its CC at 1:36–6:32 in all six 1v3 small runs.
- **Aggressive vs economic in 1v1 is lopsided** at normal: the aggressive AI lost its CC to the economic one by 8:00
  in 3 of 4 seeded 1v1 runs, before the economy pass and after it (after it, 2 of those matches ended outright).
- **The GUI protocol has not been run by a computer-use tester yet.**
