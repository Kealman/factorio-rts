# Factorio RTS 0.1.2

The update after the first real game of 0.1.1. It makes your own building, demolition and logistics understandable and controllable, adds in-game help, and gives railways back to the player: stop lists, a train builder and your own track. Skirmish plays as in 0.1.1: the Skirmish test matrix logs the same lines. 0.1.1 saves load.

**Requirements (unchanged):** Factorio 2.1 (tested on 2.1.23). Space Age is optional.

**Install or update:** download `factorio-rts_0.1.2.zip` below and put it into your mods folder in place of the 0.1.1 zip (`%APPDATA%\Factorio\mods` on Windows, `~/Library/Application Support/factorio/mods` on macOS, `~/.factorio/mods` on Linux), or update "Factorio RTS" from the in-game Mods menu.

## What changed

- **Craft queue.** Factory and barracks recipe buttons order crafts: click = 1, Shift = 5, Ctrl = as many as the network can pay, right click takes crafts off. A finished order stops the machine; an Endless toggle keeps the old behaviour (#22).
- **Pieces and ghosts.** Belts, underground belts, splitters, inserters and medium poles can be selected and demolished (two presses, half the recipe back), and ghosts are cancelled with one press (#23, #27). The factory makes underground belts and splitters, and in Nation mode long-handed inserters (#25).
- **Clearing.** Right click a tree or rock with units selected, or Shift + right-drag over an area; a ghost placed over trees marks them for the robots (#24).
- **Help.** Hold Shift over a building, unit or ghost, click the ? button or press Shift+F11 for a card with what it is, how it works, what it takes and makes, ranges and a tip; build tooltips have a description. Refinery, chemical plant and pumpjack panels say that oil travels as items, with no pipes; recipe names no longer show "Unknown key" (#30, #28, #29).
- **New cities.** The settlers bring starter stock and a factory, houses and a farm from the mother city's network, and a city whose robots have nothing to build with says so (#26). Your own supply haulers wait up to 4 minutes for a fuller load of rations, goods and magazines while the town holds at least half its Keep (#21).
- **Railways.** Trains run stop lists with orders per stop (unload, load, troops, bombard) and the engine's wait conditions (#31). The train builder composes trains carriage by carriage from presets or saved templates, with 40-, 60- or 80-tile platforms (#32). The Rail tool lays your own track with curves, branches and undo, signalled with chain signals; rail stations put stops on it; auto lines run along it (#31).
- **Saves.** A 0.1.1 save loads: its train routes become two-stop lists, and the Station and signals are unlocked. Objectives of the other mode no longer log noise (#19).

The full list is in [CHANGELOG.md](https://github.com/Kealman/factorio-rts/blob/main/CHANGELOG.md).

## Known issues

- On single track two trains that each want the platform the other holds wait for each other; a passing loop or a second track solves it. Junctions turn one way, as in vanilla (#31).
- The pumpjack's picture keeps a drawn pipe stub although oil travels as items.
- A hover help card closes with a click, after 20 s or on the next Shift press, not when you release Shift.
- The long-handed inserter is Nation only; the clear order works for loose units, not whole divisions.
- The Nation AI is as in 0.1.1: Age III later than designed, rail linking and air, artillery and interceptor use still open (#2, #20).
- Windows is untested, and on Linux only the headless autotests have run (#15). Reports are welcome, working or not.
- The engine draws a thin line from every driving hauler to its next stop on the map, which Factorio 2.1 cannot switch off.

The full list is in the README's [Known limitations](https://github.com/Kealman/factorio-rts#known-limitations-and-open-issues) section.
