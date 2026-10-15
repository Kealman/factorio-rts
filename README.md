# Factorio RTS

A Factorio 2.0 mod that turns the game into a StarCraft-style RTS: a free camera instead of an engineer, box-select and right-click orders, a Factorio production chain that turns ore into an army, and AI commanders that build real bases and attack you.

Status: playable 1v1–1v3 skirmish (Phase 3). See `docs/DESIGN.md`, `docs/PHASE1.md`–`PHASE3.md` and `docs/research/` for the design and the verified engine facts.

## Install (macOS, Steam build)

```sh
tools/install.sh      # copies mods/factorio-rts into ~/Library/Application Support/factorio/mods
                      # and enables only base, Space Age DLC mods and factorio-rts (your old mod list is backed up)
tools/uninstall.sh    # removes the mod and restores the backed-up mod list
```

Then start Factorio → New game → Freeplay. The RTS lobby opens as soon as you join: pick opponents (1–3), difficulty and map size, press Start.

Space Age is optional: with it the units use pentapod graphics, without it spidertron-based walkers.

## Controls

| Action | Input |
|---|---|
| Pan / zoom | WASD / mouse wheel (remote view) |
| Select units | left drag; click one unit; Shift adds |
| Select a building | left click on it |
| Move / attack | right click on ground / on an enemy |
| Attack-move | F, then right click (or Shift + right drag) |
| Stop / Hold | X / H |
| Control groups | Ctrl+1..5 set, 1..5 recall (double tap jumps the camera) |
| Select all | Ctrl+A |
| Camera home | Space |
| Build menu | B (or the bottom-right panel); click a building, place it, Q or right click to stop |
| Rally point | select a barracks, right click the ground |
| Menu (restart) | F10 or the Menu button |
| Give the RTS cursor back | F1 |

## How the economy works

- Your Command Center is a roboport with stockpiles, 30 robots and 4 MW of power. Everything you place is a ghost that your robots build from items in the stockpiles.
- Extractors mine ore onto belts; smelters turn it into plates; inserters put plates into stockpiles. That part is pure Factorio logistics.
- Barracks and the Factory pull ingredients from your logistic network automatically: barracks turn plates into walker kits and spawn walkers at the rally point; the factory makes buildings, belts, inserters, poles and ammo into your stockpiles.
- A side is out when it has no Command Center, barracks or factory and no units.

## Development

- `tools/headless-run.sh <seconds> '\[rts' mods` runs a map with the mod on a headless server and prints the mod's log; the autotests (`[rts] autotest`, `[rts] ai autotest`) run when no player is connected.
- `tools/gui-run.sh mods <seconds> 'RTS_GUI_READY'` launches the real client with an isolated config (own write dir and port, F9 opens the console).
- Interactive QA protocols and results live in `docs/qa/`.
- Mod layout, storage schema and module contracts: `docs/PHASE1.md`, `docs/PHASE2.md`, `docs/PHASE3.md`; per-module notes in `docs/qa/*-notes.md`.
