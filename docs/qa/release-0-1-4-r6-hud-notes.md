# Release 0.1.4 wave 2: r6-hud notes (#46, #40 remainder)

Base main 3abff7b. Branch commits: e9e1416 (#46), 42bd09b (#40 Clear), 814ecc2 (fixes found by the GUI run, probes).

## #46 hub / City Center stockpile policy

| Item | What it does now | Files |
|---|---|---|
| 1. Add item | A button under the hint opens the item picker left of the panel with `stripgui.pickable_sections(player, nation, true)`: the strip chooser's union (stock in any own network, city needs and make targets, enabled recipe products, the pieces), without the strip's "already shown" filter, zero stock allowed. A pick adds a row with empty Keep / Export (`logistics.add_policy_row`, stored as `policy.rows`). A row with both fields empty and zero stock gets a small x (`remove_policy_row`, stored as `policy.hidden`; refused while a threshold is set). Rows also appear by themselves when the network starts to hold an item (the panel rebuilds when its item list changes) | `hubgui.lua`, `logistics.lua`, `stripgui.lua` |
| 2. Nation default rows | rations, grain, goods always; crude oil, petroleum, plastic, sulfur from Age II; every default row can be hidden with its x | `hubgui.lua` `item_list` |
| 3. City panel make targets | No change needed: `citygui.lua` already has "+" with the scripted picker (`itempicker.list()`, every item a factory or district recipe makes, locked ones listed after "Can make now"); crude oil (pumpjack output, no recipe) is the one item it cannot offer, and a make target for it makes no sense | none |
| 4. Header hint | A second dim line: "Keep: haulers and trains bring the item until the network holds this much. Export above: the surplus is offered to them. Add item for anything not listed." The hub and City Center help cards' tip lines point at it. The panel stops above the Build menu (`maximal_height`) | locale `factorio-rts.cfg`, `help.cfg` |
| 5. Hauler Carry / Unload | Route mode shows "Carry: [+ Item]" with a row per item (name, per-trip count, x; empty / 0 = as much as fits) and "Unload: To Keep | Everything". With a Carry list the pickup needs no Export (it gives what it holds above its Export, else Keep, level); "Everything" ignores the drop-off's Keep, "To Keep" brings only the Keep's shortfall. Buttons act on every selected hauler. Without a Carry list the route logic is unchanged | `logistics.lua` `manual_plan`, `set_carry`, `set_unload` |
| 6. "Nothing to load" reason | Under the state line: the pickup exports nothing (set an Export or Carry), holds nothing above its Export levels, holds none of the Carry items, or the drop-off keeps only [items] (add a Keep, set Carry or unload everything). Computed by `logistics.nothing_reason` for the panel only: it never changes a hauler, so no log line or AI behaviour moves | `logistics.lua`, `hubgui.lua` |

AI haulers never get `h.carry`, so their route code path is the old one (the new code only runs under `if carry`).

## #40 remainder

| Item | State |
|---|---|
| Clear button in the build menu header | "Clear" next to the fort belt button: arm it, then a right click or right drag over a box (a click is padded to 3 x 3 tiles) makes the selected walkers and drones fell its trees and rocks (`orders.arm_clear`, `clear_is_armed`, consumed in `handle_reverse_area`; plain, no Shift, any size); a second click disarms; flying text when nothing was cleared. The Shift + right-drag path is unchanged |
| RU depot panel margin | `railgui.place` is r6-rails's: sent the change (`- MARGIN` to `- 2 * MARGIN` in the `maximal_height` line); r6-rails applies it |
| HUD Demolish tooltip for track | r6-rails adds the two `update_pieces` lines and the locale key itself; I left that spot alone |

## Tests

* GUI probe `tools/probes/r6_policy_gui.lua`, EN and RU (`build/shots-r6-hud-en/`, `build/shots-r6-hud-ru/`): **24/24 PASS** each. Nation match at the capital: rations, grain, goods rows in Age I and no petroleum row; Add item shows the picker and offers a never-held item (transport belt in Age I; petroleum from Age II: its recipe is enabled then, so Age I has no petroleum in the union, as for the strip chooser), the row appears empty with the x, Keep 200 is stored, the x hides while a Keep is set; rail row added and removed; Age II adds crude oil, petroleum, plastic, sulfur; petroleum's default row removed with its x, re-added with Add item at zero stock, Keep 200; a far hub with 600 petroleum and a hauler route to the capital: the panel names the reason ("the pickup exports nothing"), Carry + Item offers petroleum, count 250, Unload Everything, the capital's network ends with 600 petroleum while its Keep for it is 200; Clear button present, arms, disarms, and armed Clear + right click gives the walker the clear order and disarms.
* Shots: `01-capital-age1`, `02-picker`, `03-keep-200`, `04-capital-age2`, `04b-petroleum-keep`, `05-hauler-nothing` (reason line), `06-hauler-carry`, `07-capital-stocked`, `08-clear-armed`. Two things the first run showed and were fixed: the hidden x broke the table's columns (now in a fixed-width cell) and the module lookup at run time needs the `__factorio-rts__/scripts/x.lua` key.
* Headless `tools/probes/r6_policy_headless.lua` (Skirmish 1v1, hub 101 tiles from the CC with 600 petroleum): **8/8** PASS: row add / blocked removal / removal, reason `no-export`, reason `dropoff-keeps` with Unload To Keep and no Keep, Unload Everything delivers 600 petroleum with no Keep anywhere in 6 s, then Unload To Keep with Keep 640 brings exactly the 40 short.
* Not run: a train-stop "load items / unload everything" probe (railgui's stop lists already exist and are r6-rails's; the hauler list is modelled on them), and a Skirmish GUI shot of the hub panel (the Skirmish headless run exercises the same API).
* Identity (frozen copy of 814ecc2): M1 seed 501 Nation 1v1 2048, 60 minutes, `WHAT=all`, against the dev-build-1 tree 115ac7c: 68,801 lines each, **0 differing**. Skirmish seed 777 1v1 medium, 20 minutes, `WHAT=all`, against 3abff7b: 4,907 lines each, **0 differing** (the full 10-scenario matrix was not run).
* Owner saves load on 814ecc2 (100 s headless each, 0 errors): `owner-0111-age2`, `owner-0112`, `owner-0113-now`, `owner-0114-now` (`build/r6h-own*-server.log`); old hub policies without `rows` / `hidden` are handled (nil-guarded).

## Proposed changelog lines

* Added: the hub and City Center stockpile panel has an "Add item" button (any item, even one the network never held), small x buttons on empty rows, default rows for rations, grain and goods and, from Age II, crude oil, petroleum, plastic and sulfur, and a hint explaining Keep and Export above.
* Added: a hauler route can carry an explicit item list ("Carry", with a per-trip count) and unload "to Keep" or "everything", so a route works without a Keep on the drop-off; a waiting hauler's panel says why there is nothing to load.
* Added: a Clear button in the build menu: arm it and drag a box with the right mouse button to have the selected walkers and drones fell its trees and rocks.
