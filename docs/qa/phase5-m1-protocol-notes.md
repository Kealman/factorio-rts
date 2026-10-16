# Phase 5 M1 protocol notes

Short GUI checks for M1 features. Each section is self-contained: setup, steps, what must be visible.

## Demolish own buildings

Feature: `scripts/demolish.lua` (player side), `buildings.demolish(entity, opts)` (engine side, reusable by the AI).
Controls: the **Demolish** button on the building page and on the hub panel, and the `rts-demolish` input (Delete, or
Backspace). Both modes (Skirmish and Nation).

Rules the check verifies:

- Two presses. The first press arms: a chat line and a flying text "Demolish 1 building(s)? Press again within 3
  seconds.", and the button turns red with "Press again". The second press within 3 s demolishes. After 3 s the
  button is normal again and the next press arms anew. Selecting another building also disarms.
- The Command Center and the capital City Center are never demolished: the press shows "Command Center cannot be
  demolished." and nothing changes.
- A hub takes its hidden power, pole and both attached stockpiles with it. Nothing of it stays on the map.
- 50 % of the item cost (rounded down; walls carry the remainder inside one batch) goes into the nearest own
  stockpile of the building's logistic network. If none is in that network or all are full, the rest is dropped.
- Stockpile contents (and turret ammo, furnace contents, fuel) go to another own stockpile of the network, else they
  drop on the ground next to the building.
- The alert line under the HUD strip reads "Demolished <icon> <building>" (F3 jumps to it).
- Ghosts are cancelled by `buildings.demolish` without a refund (no input path selects a ghost yet).

### Headless check (lead)

```sh
KEEP_TREE=mods/factorio-rts EXTRA_LUA=tools/probes/demolish_headless.lua STOP_ON='demolish probe: after 10 s' \
  tools/autotest-run.sh demolish-probe '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240
grep -E 'demolish probe' build/demolish-probe-server.log
```

Expected: every `demolish probe ...` line is PASS and `demolish probe done: 0 failure(s)`. The probe builds a barracks,
a turret, a hub with a loaded stockpile, a loaded stockpile, a far stockpile (spill) and two walls, demolishes them
through the two-press request path and compares entity counts of the force, the registry and the stockpile item totals
before and after.

### GUI check (tester, computer use)

Launch: `tools/gui-run.sh` on a copy of the mod, English client (`RTS_LOCALE=en`), start a Skirmish match.

1. Build a barracks next to the Command Center (build menu, B). Wait until it is built. Click it. Its page shows a
   small **Demolish** button right of the "HP" value. PASS: the button is visible and not cut off by the panel.
2. Click **Demolish** once. PASS: the button turns red and reads "Press again"; the chat shows the confirmation line.
3. Wait 4 seconds. PASS: the button is grey again with "Demolish".
4. Click **Demolish**, then within 3 seconds click again. PASS: the barracks disappears, the alert "Demolished
   Barracks" appears under the strip, and the iron and copper counters rise by 30 and 10 (50 % of 60 / 20).
5. Build a hub (hubs need a hub item from the factory) and click it. The hub panel on the right has a **Demolish**
   button under the hint line. Press Delete twice within 3 seconds (the hub stays selected). PASS: the hub and its two
   stockpiles vanish and the panel closes.
6. Click the Command Center and press Delete. PASS: the message "Command Center cannot be demolished." and nothing is
   removed; the button's tooltip says the same.
7. Select a stockpile that holds items and press Backspace twice. PASS: the stockpile is gone and the totals of the
   resource bar do not drop by its contents (they moved to another stockpile).

Log check (lead): `grep -E 'demolish: (armed|done|click|blocked)|demolished rts-' build/<run>-gui.log`.

GUI probe: `tools/probes/demolish_gui.lua` (append `require("scripts.demolish_gui")` to a copy's `control.lua`, run
`tools/gui-run.sh <dir> 150 RTS_DEMOLISH_GUI_DONE`). It clicks the real buttons through `on_gui_click` and saves
screenshots `rts-demolish-armed.png`, `rts-demolish-hub.png` and `rts-demolish-done.png`.
