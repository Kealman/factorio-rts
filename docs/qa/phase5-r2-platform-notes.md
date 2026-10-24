# Release 0.1.1: platforms and 2.1 baselines (r2-platform)

Date: 2026-10-24. Engine: Factorio 2.1.23 (build 87750). Agent: `r2-platform`. Issues: #13 (2.1 world and divisions
baselines), #14 (Linux headless autotest in Docker), #15 (Windows status and issue templates). Every run used a frozen
copy of the mod from `git archive ae708bc` (`build/r2p-tree-ae708bc/`), because other agents edit `mods/` at the same
time.

## 1. Linux (#14)

### Verdict

- **The mod loads and plays on Linux.** On the official Factorio 2.1.23 headless build for Linux, the Skirmish smoke
  test passes 65/65 and the Nation smoke 53/53, with 0 Lua errors. That holds on x86-64 (`linux64`) and on ARM64
  (`linux-arm64`), with and without Space Age.
- **Linux, macOS, ARM64 and x86-64 play the same game.** Each run logs the same `[rts]` lines on all three builds,
  after `tools/matrix-compare.sh`'s normalisation (timestamps, durations and timing lines). That covers the smoke's
  471 lines (474 with Space Age) and the Nation smoke's 3,157 lines at seed 9090, with and without Space Age.
- **No case mismatch.** Every `require` and every file path that the mod's prototypes end up with matches the case of
  the files on disk.
- **No mod change is needed for Linux.** Two tool fixes and one image choice were needed (below).
- **Not covered:** the Linux GUI client, which loads graphics and sounds that the headless build does not ship. The
  case check covers their paths statically.

### How it runs

`tools/linux/run.sh` does everything in one command:

1. It downloads the headless archive for the chosen architecture into its own directory,
   `build/linux/dl-<version>-<linux64|linux-arm64>/`. It checks the archive against factorio.com's SHA-256 list.
   - `factorio-headless_linux_2.1.23.tar.xz` (x86-64): `4633250f...c46b9`.
   - `factorio-headless_linux-arm64_2.1.23.tar.xz`: `bf130c30...c0251a`.
2. It builds the image from `tools/linux/Dockerfile`: Debian 13 slim with `python3` and `xz-utils`, and the archive
   unpacked to `/opt/factorio`.
3. It runs one container with the repository mounted read-only at `/rts`, the mod under test at `/mod` and the results
   at `/out`. The container runs as the host user's uid.
   - `tools/linux/in-container.sh` runs each scenario through `tools/autotest-run.sh`, the runner of the macOS tests.
     The runner copies the mod onto the container's own file system first, which is case-sensitive. A bind mount from
     macOS would not be: APFS resolves any case.
   - After each smoke it runs `factorio --dump-data` on that copy, which writes `data.raw` after every data stage.
4. On the host, `tools/linux/case-check.py` checks the mod's `require` calls and its `__factorio-rts__/` paths. It also
   checks every `__mod__/....ext` path in both `data.raw` dumps against the full game data of the macOS install. The
   headless build has no graphics or sounds to check against.

The headless archive carries the data of base, Space Age, Quality, Elevated Rails and the recycler. No account and no
Steam are involved, so the Space Age variant runs too.

```sh
tools/linux/run.sh                                  # host architecture, base and Space Age, smoke and Nation smoke
ARCH=amd64 tools/linux/run.sh                       # x86-64; emulated on Apple silicon (wall-clock caps x4)
TREE=build/r2p-tree-ae708bc/mods/factorio-rts SCENARIOS="smoke" VARIANTS=base tools/linux/run.sh
```

### Results

Seed 9090, game speed 1. Each container ran its four scenarios in parallel.

| Build | Variant | Smoke (legacy units, 1v1 small, waves) | Nation smoke (1v1, 2048, AI, 8 min) |
|---|---|---|---|
| linux-arm64, native | base | **65/65**, 0 errors, 162 s | **53/53**, 0 errors, 548 s |
| linux-arm64, native | Space Age | **65/65**, 0 errors, 160 s | **53/53**, 0 errors, 548 s |
| linux64 (x86-64), emulated on Apple silicon | base | **65/65**, 0 errors, 163 s | **53/53**, 0 errors, 549 s |
| linux64 (x86-64), emulated | Space Age | **65/65**, 0 errors, 163 s | **53/53**, 0 errors, 550 s |
| macOS (Steam), same tree and seed | base | 65/65, 162 s | 53/53, 547 s |
| macOS (Steam), same tree and seed | Space Age | 65/65, 162 s | 53/53, 548 s |

Line-by-line comparison:

| Pair | Smoke base | Smoke Space Age | Nation base | Nation Space Age |
|---|---|---|---|---|
| macOS vs linux-arm64 | 471 lines, 0 differ | 474 lines, 0 differ | 3,157 lines, 0 differ | 3,157 lines, 0 differ |
| linux-arm64 vs linux64 | 471 lines, 0 differ | 474 lines, 0 differ | 3,157 lines, 0 differ | 3,157 lines, 0 differ |

The emulated x86-64 container kept real time: the 8-minute Nation smoke took the same 549 s as the native one.

### Case check

| Item | Checked | Case mismatches | Missing in every case |
|---|---|---|---|
| `require` calls in the mod's Lua | 808 | 0 | 0 |
| `__factorio-rts__/` paths | 0 (the mod ships no graphics) | 0 | 0 |
| File paths in `data.raw`, base and Space Age dumps | 19,705 | 0 | 76 |

The 76 paths missing in every case are vanilla references the game never loads:

- 72 `.bnvib` files: console haptics, which ship only with the console builds. Two RTS prototypes inherit them from
  vanilla sounds: `rts-artillery` (artillery-shoots) and `rts-armoured-car` (submachine-gunshot).
- 4 vanilla sprites with stale names: `hr-bigass-explosion-36f.png` (the files on disk are
  `bigass-explosion-36f-1/-2.png`) and `vulcanus-rock-big-17.png` with its emissive variant.

A planted test caught all three kinds of mismatch: `require("scripts.Util")`, `"__factorio-rts__/Thumbnail.png"` and a
`data.raw` icon `__base__/graphics/icons/Iron-plate.png` on an `rts-` item.

### Findings

1. **glibc 2.38 or newer.** The 2.1.23 Linux builds do not start on Debian 12 (glibc 2.36):
   `GLIBC_2.38' not found (required by /opt/factorio/bin/arm64/factorio)`. The image uses Debian 13 (glibc 2.41).
   This is Factorio's requirement, not the mod's. A player on an older distribution gets the same error from the game
   itself.
2. **`__PATH__system-read-data__` means `/usr/share/factorio` on Linux.** The per-run `config.ini` of
   `factorio_isolated_config` used it, which on macOS points into the app bundle. On Linux the server failed with
   "There is no package core in /usr/share/factorio". `FACTORIO_READ_DATA` now overrides it, and the image sets
   `/opt/factorio/data`.
3. **BSD `sed -i ''`.** GNU sed reads the `''` as the script. `tools/autotest-run.sh` now uses `sed -i.bak` plus `rm`,
   which both accept. The same BSD form is still in `tools/perf-bench.sh`, `tools/lan-check.sh`, `tools/heavy-mode.sh`
   and `tools/balance-sim/run.sh`, which the Linux check does not use.
4. **No `lsof` in the image.** The port probe of `tools/autotest-run.sh` now skips `lsof` when it is absent. Each
   container has its own network namespace, so ports cannot collide.

### Tool changes (macOS behaviour unchanged)

| File | Change |
|---|---|
| `tools/factorio-env.sh` | `FACTORIO_BIN`, `RTS_BUILD_DIR` and `FACTORIO_READ_DATA` can be set by the caller; the defaults are the old values |
| `tools/autotest-run.sh` | portable in-place `sed`; `lsof` optional |
| `tools/linux/Dockerfile`, `run.sh`, `in-container.sh`, `case-check.py` | new |

The macOS smoke on the changed tools gives 65/65 with the same 471 lines as Linux.

## 2. Windows (#15)

No Windows machine is available, so Windows stays untested. The README's Requirements say so and ask players to
report how the mod runs, whether it works or not. The new issue templates under `.github/ISSUE_TEMPLATE/` are a bug
report and a feature request. The bug report asks for the OS, Factorio version and source, mod version, Space Age,
other mods, single or multiplayer, mode and lobby settings, the seed (`/seed`), the match time, the steps, the
`[rts]` log lines and `factorio-current.log`, with its path on Windows, macOS and Linux.

The issue's acceptance includes a confirmation from a Windows tester, which is still open.

## 3. 2.1 baselines (#13)

The details are in the 2.1 sections at the end of `phase5-world3-notes.md` and `phase5-divisions-notes.md`. In short:

| Baseline | 2.0.77 | 2.1.23 |
|---|---|---|
| World identity, 20 seeds x 4 nations at 2048 | reference | plans, sites, scores and 260 check lines identical; tile counts identical in 19 of 20 (one more ore entity on one seed) |
| Other seed matrices: 2048 x 2/3/4, 3072 x 4, 3072 x 5/6, 4096 x 4/5/6 | 117/117, 38/39, 52/52, 78/78 | 117/117, 39/39, 52/52, 78/78; identical plans and sites, differences explained |
| Background fill, 4096 x 6 | 375-381 s | **244.1 s** (66.4 chunks per game second) |
| Background fill, 3072 x 4 | 212-214 s | **136.8 s** |
| Background fill, 2048 x 4 (legacy order) | 84-87 s | **54.0 s** |
| Save at 2:00 mid-fill and load, 4096 x 6 | 22/22 | 22/22, fill ends at the same 244 s |
| Group path cost (2,048-tile march, slowest pathfinder ticks) | 12.5, 10.1, 10.0 ms | 12.7, 10.7, 10.5 ms |
| Mass orders, engine A/B in Docker (mean ms/tick) | 3.46 / 3.54 | 3.33 / 3.69 |
| Divisions functional test | 25/25 | 25/25 |

The pathfinder budgets stay as they are, so no `balance.lua` hunk follows. The lobby's fill-time estimate went to r2-ux
as a hunk. The README's Known limitations line now gives about 4 minutes for a 4096 world.

### Running a tool in the Linux image

The image of `tools/linux/Dockerfile` runs any runner that sources `tools/factorio-env.sh` and only needs bash,
python3 and coreutils. This is how the engine A/B ran `tools/divisions-bench.sh` on 2.0.77 and on 2.1.23. A 2.0.77
image builds from `build/linux/dl-2.0.77-linux64/` with the same Dockerfile. For 2.0, mount a mod list without
`recycler` over `/rts/mods`.

```sh
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" -e KEEP_TREE=/mod -e RTS_BUILD_DIR=/tmp/rts-build \
  -v "$PWD:/rts:ro" -v "$PWD/build/r2p-tree-ae708bc/mods/factorio-rts:/mod:ro" -v "$PWD/build/linux/ab:/out" \
  factorio-rts-headless:2.1.23-amd64 bash -c "/rts/tools/divisions-bench.sh ab-mass \
  '{mode = \"mass\", n = 1000, half = 512, start = 120}' 1800 > /out/ab-mass.txt 2>&1; cp -R /tmp/rts-build/ab-mass-out /out/"
```
