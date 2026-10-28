# Factorio RTS 0.1.3

The update after the owner's second real game. The vanilla rail planner comes back in place of the Rail tool, the factory page stops overflowing, the top strip is configurable, and the Nation AI gets its pace work. Skirmish plays as in 0.1.1: the Skirmish test matrix logs the same lines. 0.1.2 and 0.1.1 saves load.

**Requirements (unchanged):** Factorio 2.1 (tested on 2.1.23). Space Age is optional.

**Install or update:** download `factorio-rts_0.1.3.zip` below and put it into your mods folder in place of the 0.1.2 zip (`%APPDATA%\Factorio\mods` on Windows, `~/Library/Application Support/factorio/mods` on macOS, `~/.factorio/mods` on Linux), or update "Factorio RTS" from the in-game Mods menu.

## What changed

- **Rail planner (#37).** The Rail button puts the vanilla rail planner in your hand: click a rail end, then click where the track goes; the path with curves and diagonals follows the pointer. A click on a rail end in the middle starts a branch, track laid onto track joins it, R turns the first rail, Q stops the path, Q again or a right click ends laying. Robots and construction trains build it and junctions get chain signals. Ground track only: bridges stay with the auto lines. The Rail tool is gone; its unbuilt track in a 0.1.2 save is kept and built.
- **Rails follow-ups (#33).** The train panel marks a stop that no track reaches from the stop before it, and a second train between the same stops brings the passing-loop hint. Cancelled planner ghosts stay gone.
- **Factory page (#35).** Pause, Auto and Endless are in the page header; the panel grows taller when a tab needs more rows.
- **Top strip (#38).** A gear button opens a chooser: any item with stock in your networks, power, robots, treasury, supply, army counters and the timer, in your order, with defaults per mode. Hover an entry for the split per city and the last minute's change; rations and grain show the minutes left.
- **Interface (#34, #36).** The train and depot panels stop above the Build menu; help cards for a selected unit type and for the five abilities; player text names no release numbers.
- **Nation AI (#20, #2).** The aggressive AI researches Industrialisation, then Railways, first (Age II at about 20 minutes instead of 26 to 32); capitals add a coal extractor when coal runs short; a freight train that loses a locomotive or its path is rebuilt; siege railways get their artillery kits from plan time. In the test seeds Age III by minute 40 is 5 of 5 (was 2 of 5), 12 of 20 nations have three cities linked by minute 35 (was 9; target 16) and the 1v1 seed moves 25,678 items by train (was 19,101).

The full list is in [CHANGELOG.md](https://github.com/Kealman/factorio-rts/blob/main/CHANGELOG.md).

## Known issues

- AI rail linking is 12 of 20 nations by minute 35, short of 16: Age I copper is the limit (#39, #2).
- Rails: two auto lines surveyed at the same time can plan over the same ground, a busy platform makes a depot deploy rarely, a crew that cannot reach its frontier goes home after 120 s, and built track has no remove action (#33). On single track two trains that each want the other's platform wait; a passing loop or a second track solves it.
- The strip chooser and the unit and ability help cards open over the top banner (#34). The long-handed inserter is Nation only; the clear order works for loose units, not whole divisions.
- The pumpjack's picture keeps a drawn pipe stub although oil travels as items. A hover help card closes with a click, after 20 s or on the next Shift press.
- Windows is untested, and on Linux only the headless autotests have run (#15). Reports are welcome, working or not.
- The engine draws a thin line from every driving hauler to its next stop on the map, which Factorio 2.1 cannot switch off.

The full list is in the README's [Known limitations](https://github.com/Kealman/factorio-rts#known-limitations-and-open-issues) section.
