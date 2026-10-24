# Factorio RTS 0.1.0

The first public release. Factorio as a StarCraft-style real-time strategy game, with a real Factorio production economy, grown into a Rise of Nations-style mini-state.

**Requirements:** Factorio 2.1 (tested on 2.1.23). Space Age is optional.

**Install:** download `factorio-rts_0.1.0.zip` below and put it, unpacked or not, into your mods folder (`%APPDATA%\Factorio\mods` on Windows, `~/Library/Application Support/factorio/mods` on macOS, `~/.factorio/mods` on Linux), or install "Factorio RTS" from the in-game Mods menu. Start a new Freeplay game; the RTS lobby opens when you join.

## What is in it

- **Skirmish:** 15 to 30 minute matches against 1 to 3 AI commanders with their own doctrines, on generated arenas. RTS controls, a Factorio economy with hubs and haulers, 19 technologies, five abilities and a Commander hero.
- **Nation:** a mini-state on worlds of 2048 to 4096 tiles with 2 to 6 nations. Cities and territory, people and labor, rails and trains, a treasury and a world market, diplomacy and war goals, three ages up to the Space Program, and war with divisions, supply, fronts, fort belts, air units and artillery trains.
- **AI:** doctrine commanders in Skirmish, and a layered nation AI in Nation whose difficulty changes skill, never resources.
- **Multiplayer:** cooperative against the AI.
- English and Russian.

The full feature list is in [docs/FEATURES.md](https://github.com/Kealman/factorio-rts/blob/main/docs/FEATURES.md) and the history in [CHANGELOG.md](https://github.com/Kealman/factorio-rts/blob/main/CHANGELOG.md).

## Known issues

- Only macOS has been tested; Windows and Linux should work.
- The Nation AI is slower to Age III than designed and rarely uses air units, artillery trains or front holds.
- The aggressive AI links its cities by rail late, and AI nations seldom go into debt.
- Two humans in one multiplayer session at the same time have not been tested yet.

The full list is in the README's [Known limitations](https://github.com/Kealman/factorio-rts#known-limitations-and-open-issues) section.
