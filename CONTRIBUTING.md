# Contributing to Factorio RTS

Thank you for helping. Bug reports, balance feedback from real matches, tests on Windows and Linux, translations and pull requests are all welcome. Please open an issue before a large change so we can agree on the approach first.

## Reporting a bug

Open an issue on GitHub with:

1. **Versions.** The Factorio version (2.1.x), whether Space Age is enabled, the mod version and your operating system.
2. **Mode and lobby settings.** Skirmish or Nation, the number of opponents or nations, the difficulty, the map size and map (Skirmish) or the world size, start map and victory mode (Nation).
3. **The seed.** Type `/seed` in the game console for the map seed. The log line `[rts] match: starting match N: ...` gives the match number and the settings; a match's arena or world uses the map seed plus that number.
4. **What happened and when.** The game time (shown in the HUD), what you did, what you expected and what you saw. A screenshot helps for anything on screen.
5. **The log lines.** Attach `factorio-current.log` (or `factorio-previous.log` after a crash) from your user data folder, or at least every line with `[rts]` and any `Error` around the time of the bug:

| System | User data folder |
|---|---|
| Windows | `%APPDATA%\Factorio` |
| macOS | `~/Library/Application Support/factorio` |
| Linux | `~/.factorio` |

```sh
grep -nE '\[rts\]|Error' factorio-current.log | tail -200
```

A save from just before the bug is the best evidence of all. Please also try the bug with no other mods enabled, since only the base game and Space Age are tested.

## Setting up for development

The development tooling is written for macOS with the Steam build of Factorio; paths are in `tools/factorio-env.sh`.

- `tools/install.sh` copies the mod into your real mods folder and enables only base, the Space Age mods and factorio-rts (your old mod list is backed up). `tools/uninstall.sh` reverts it.
- The Factorio API documentation is in the game installation (`doc-html`, on macOS inside `factorio.app/Contents`) and at [lua-api.factorio.com](https://lua-api.factorio.com).
- Every runner in `tools/` refuses to start when the game binary's major.minor version differs from `factorio_version` in the tree's `info.json`.
- **Linux.** `tools/autotest-run.sh` runs as is when `FACTORIO_BIN` points at your Factorio binary (`<factorio>/bin/x64/factorio`, or `bin/arm64` on ARM) and `FACTORIO_READ_DATA` at its `<factorio>/data` (tested with the headless build; the standalone and Steam builds use the same layout). `tools/linux/run.sh` runs the Skirmish smoke and the Nation smoke in Docker on the official headless build, which it downloads; no Factorio account is needed. It also checks every `require` and file path for case mismatches, which only a case-sensitive file system shows.
- **Other runners and systems.** The other runners still use the macOS paths and BSD `sed -i ''`. On another system, adapt `FACTORIO_APP` and the user mods folder in `tools/factorio-env.sh`, and replace those `sed` calls.

## Running the autotests

Autotests run a real match on a headless server, with the AI playing every side, and log `[rts]` checks with PASS or FAIL and a summary. They run on a copy of the mod in `build/<name>/`, so your working tree is never modified.

The Skirmish smoke test (about 4 minutes; the expected result is 65/65 with 0 errors):

```sh
tools/autotest-run.sh smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240
```

A 1v1 Nation match on a 2048 world:

```sh
tools/autotest-run.sh nation-1v1 '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 900
```

Useful environment options: `SEED=<n>` (map seed), `VARIANT=base` (no Space Age), `SPEED=<n>` (game speed; performance numbers only mean something at 1), `PERF=1` (per-module timings), `DURATION_MIN=<n>` and `EXTRA_LUA=tools/probes/<fixture>.lua` (a test-only module, for example a milestone's acceptance fixture). The README's [Development](README.md#development) section lists every tool, fixture and console command.

Before a pull request, please run at least:

- the Skirmish smoke test above, with 0 Lua errors;
- for a change that can touch Skirmish, the Skirmish identity check: `SEED=777 tools/autotest-matrix.sh before` on the base commit and `SEED=777 tools/autotest-matrix.sh after` on yours, then `tools/matrix-compare.sh before after`, which must report 0 differing lines;
- for a Nation change, a Nation run of the area you touched and the fixture under `tools/probes/` that covers it.

## QA protocols

Interactive GUI test protocols live in `docs/qa/`: `phase1-protocol.md` to `phase4-protocol.md` for Skirmish and `phase5-m1-protocol.md`, `phase5-m2-protocol.md` and `phase5-m3-protocol.md` for Nation. Each step gives the input, what must be visible afterwards and how to judge PASS or FAIL from the screen. The results of each pass are in `docs/qa/*-qa-results.md`, and the measured numbers, decisions and open issues of each milestone are in `docs/qa/*-integration-notes.md`. A change to anything a protocol names (a caption, a key, a panel position) should update that protocol.

## Code conventions

- **Language.** The mod is Lua for the Factorio 2.1 API, with 2-space indentation, no tabs and lines up to about 120 characters. Code, comments, documents, commit messages and file names are in English.
- **Layout.** Data-stage prototypes are in `prototypes/`, runtime modules in `scripts/` and the AI in `scripts/ai/`. `control.lua` requires the modules in a load-bearing order that its header explains.
- **The event bus.** Every module registers its handlers through `scripts/events.lua` (`events.on`, `events.on_nth_tick`, `events.on_init` and friends), never with `script.on_event` directly, and only while `control.lua` loads, never from inside a handler.
- **Storage.** Each module owns its part of `storage`; other modules only read it or call the owner's public functions. The milestone contracts (`docs/PHASE*.md`) list the storage schema and the public APIs.
- **Balance.** Every number a player could tune lives in `mods/factorio-rts/balance.lua`, which both the data stage and the control stage read. Nation-only numbers are under `balance.nation`. Do not hard-code costs, times or rates in modules.
- **Texts.** Every player-facing string is a locale key with an English and a Russian translation (`locale/en`, `locale/ru`). If you cannot write the Russian text, add the English one in both files and say so in the pull request.
- **Logging.** Log through `util.log`, which adds the `[rts]` prefix that the tests and bug reports rely on.
- **Determinism.** Multiplayer depends on every peer making the same decisions. Do not decide anything from client-side state (chart visibility, a player's GUI or settings), the wall clock or the game speed. Do not let `pairs` order decide anything that a save and load could reorder. Use the game's random generators, never `math.random`. Do not use coroutines.
- **Performance.** Long work runs in slices: through the work-unit scheduler (`scripts/sched.lua`) for Nation jobs, or in bounded steps per tick. The budget is 60 UPS (updates per second) for 4 nations, 16 cities, 600 units and 40 trains.
- **Skirmish stays byte-identical.** Nation features must not change Skirmish behaviour. Gate Nation code on the match mode, and prove it with the seed 777 matrix comparison above. If a Skirmish change is intended, say so in the pull request and record a new baseline.

## Pull requests

- Keep a pull request to one topic, and describe what changed, why, and which tests you ran with their results.
- Update `README.md`, `docs/FEATURES.md` and `CHANGELOG.md` when you change something a player can see; the maintainer adds the matching lines to `mods/factorio-rts/changelog.txt` at release time.
- Do not bump the version in `info.json`; releases are cut by the maintainer with `tools/package.sh` and `docs/release/checklist.md`.

By contributing you agree that your contribution is licensed under the [MIT license](LICENSE).
