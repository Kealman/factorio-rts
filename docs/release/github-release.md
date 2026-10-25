# Factorio RTS 0.1.1

The first update after the public release. It brings the Nation AI to Age III sooner and shrinks its armies in debt, fixes stranded haulers, makes AI rail freight carry full loads, cuts the script tick spikes, adds guided objectives for a first match, reviews the Russian translation and checks the mod on Linux. Skirmish plays as in 0.1.0: all ten Skirmish test scenarios log the same lines. The release acceptance passed 42 of 46 criteria; the four misses are under Known issues.

**Requirements (unchanged):** Factorio 2.1 (tested on 2.1.23). Space Age is optional.

**Install or update:** download `factorio-rts_0.1.1.zip` below and put it into your mods folder in place of the 0.1.0 zip (`%APPDATA%\Factorio\mods` on Windows, `~/Library/Application Support/factorio/mods` on macOS, `~/.factorio/mods` on Linux), or update "Factorio RTS" from the in-game Mods menu.

## What changed

- **Nation AI.** A concrete chain, an engine focus and a science hold bring Age III sooner: by minute 40 in 2 of 5 four-nation test seeds (0.1.0: 1 of 5) (#1). The aggressive AI opens its first rail line before minute 32 in 4 of 5 seeds (0.1.0: 1 of 5) (#2). In debt the AI retires idle units and stops recruiting (#5). Hard beats normal by skill (more housing, a second city-state) in 20 of 20 side-swapped 1v1 matches (#3). At war it lays siege railways, patrols with interceptors, sends bombers and researches its war technologies first (#4). A depot lost in a war is rebuilt on its old site (#7).
- **Haulers and rails.** A hauler pays its way back before it leaves, so none strands at a remote hub without coal (#6). Auto haulers wait up to a minute for a load worth the trip's coal. AI freight trains carry everything their town offers: the 1v1 test seed moves 19,101 items by train (0.1.0: 13,506) (#7). Rail crews avoid mountain rims and come home when stuck, and rail crafts leave 100 stone in the capital (#2).
- **Performance.** Nation-mode periodic work is spread over ticks. In the five-minute budget scene the script ticks over 3 ms fell from about 390 to 19, and the average tick from 1.435 to 1.33 ms (#8).
- **Interface.** Guided objectives walk a first Skirmish and a first Nation match through seven steps each, with a lobby switch (#16). Escape opens the game menu (#12). A right click on a pentapod's leg attacks the pentapod (#12). The selected haulers' routes are drawn on the map, and the engine's own hauler lines are thinner (#9). The stockpile panel colours counts against the hub's own Keep (#10). Buildings that looked alike on Factorio 2.1's art get distinct tints (#11).
- **Russian.** A full review with one glossary, the game's own item names and shorter panel lines (#17).
- **Balance.** Air Force costs 30 industrial kits (was 50) and Military railways 17 (was 25).
- **Platforms.** The headless autotests pass on Linux (x86-64 and ARM64) with the same results as macOS (#14).
- **Tested.** Save and load, determinism, heavy mode and a LAN session with two clients joining one after the other all pass, and the GUI test pass reaches 53 of 53 in English and in Russian.

The full list is in [CHANGELOG.md](https://github.com/Kealman/factorio-rts/blob/main/CHANGELOG.md).

## Known issues

- Windows is untested, and on Linux only the headless autotests have run (#15). Reports are welcome, working or not.
- The AI reaches Age III later than designed: by minute 40 in 2 of 5 test seeds, against a target of 3 (#1, partial).
- The AI links its cities by rail later than designed: 9 of 20 nations had three cities linked by minute 35 in the test seeds, against a target of 16 (#2, open).
- Rail freight on the 1v1 test seed is 19,101 items, just short of the 20,000 target (#7, partial on that seed).
- The AI still fields no interceptors, bombers or artillery trains within a 60-minute match. Air Force needs Age III, Aviation and a war at the same time, and no siege line opened before its operation ended (#4, partial).
- The engine draws a thin line from every driving hauler to its next stop on the map, which Factorio 2.1 cannot switch off.
- Two humans in one multiplayer session at the same time have not been tested yet.

The full list is in the README's [Known limitations](https://github.com/Kealman/factorio-rts#known-limitations-and-open-issues) section.
