# Release 0.1.3: r4-hud notes (#35, #36, #38, #34)

Agent `r4-hud`, branch of the worktree `agent-ad269dfd22abb95d2`. Engine Factorio 2.1.23, Space Age on.

## What changed

### #35 factory page (commit 14ced36)

- Pause, Auto and Endless moved from the recipe grid to the building page header (new flow `el.b_ctl`, between the
  category tabs and the HP). Names (`rts_hud_recipe_pause`, `_auto`, `_endless`), the `rts_hud = "recipe"` tags and
  every QA log line are unchanged, so `r3_orders_gui`, `economy_gui*`, `m1_docs_gui` need no edit. New styles
  `rts_hud_ctl_button` / `_active` (24 px). Barracks pages use the header Pause too (their grid holds kits only).
- The panel grows: `P4.set_panel_rows` makes it `126 + extra * 36` high and moves it up (`extra` = grid rows beyond
  `P4.FACTORY_ROWS` = 2) per player on every rebuild of the recipe grid (tab change, new selection) and back to 126 on
  other pages. Log line `hud: panel rows player=N extra=E height=H`. The staffing box of `citygui.lua` follows the
  panel's real top.
- The Nation buildings tab holds 27 recipes today (2 rows) and the logistics tab 19, so with 0.1.2's recipes the growth
  does not trigger by itself; tested with `FACTORY_ROWS` lowered to 1 in the test copy (panel 162, status line, counts
  and "5 / 5" visible, controls in the header). Skirmish factory page stays at two rows (27-28 recipes).
- Not checked: 1920x1080 / scale 1.0 (the lowered run was 1280x800 / 0.75).

### #36 version numbers (commit e1f65be)

Only the two Endless tooltips (`recipe-endless-tooltip`, EN and RU) named a release; the sweep of all locale values,
`help.lua`, F11 texts and alerts found nothing else (the other hits are `#` comment lines of the cfg files and
Lua comments, not player text). `tools/locale-probe/help-check.py` now fails on release numbers (`\d+.\d+.\d+`), `#NN`,
"Phase N" / "Фаза N", `M1-M3`, "Release N" / "Релиз N" and agent branch names in any locale value of both languages;
checked with a planted line (3 problems reported) and 0 problems on the tree.

### #38 configurable strip (14ced36 and later)

- New module `scripts/stripgui.lua`: entry keys (`timer`, `army`, `supply`, `power`, `bots`, `treasury`,
  `item:<name>`), defaults per mode, validation, the chooser frame `rts_strip_chooser`, hover details.
- Defaults: Nation = timer, iron, copper, stone, coal, grain (the "food" entry: `rts-grain`, the crop the bakeries
  use), rations, power, treasury. Skirmish = timer, army counters, supply, iron, copper, stone, coal, magazines, power.
  Steel, circuits, explosives, robots and everything else are off until added.
- Gear button (`rts_hud_strip_gear`) at the end of the resource row opens the chooser: the list with `<` `>` `x`
  (order, remove), "Show also" buttons for the special entries, "Add an item" (the shared item picker, owner "strip",
  list = items with stock in the force's networks that are not shown yet), "Reset to default". At most 12 entries.
- Storage: `storage.players[i].hud_prefs.strip = {nation = {keys}, skirmish = {keys}}`, created on the first change
  (lazily; a missing list = default), so both owner saves load unchanged. Stock history for the last-minute change:
  `storage.players[i].strip_hist` (sampled every 5 s for shown items).
- Hover: item entries show the total, the split per logistic network (named by its Command Center / City Center) and
  "last minute: +N per minute"; rations and grain show the stock of every network that feeds a city, the minutes left
  per city and in total from `population.needs` (grain counts as the rations the bakery makes from it: 2 grain make 3
  rations), and the label reads "700 (35 min)" in yellow under 10 min, red under 3.
- Row 1 keeps timer, army counters (hidden unless chosen), supply (hidden unless chosen) and the buttons.
- Verified in the GUI (EN and RU, 1280x800 at 0.75): default sets, chooser open, remove stone, add steel through the
  picker, order change, persistence of the stored table (serialise round trip), reset, a 12-entry Skirmish strip fits
  without touching the buttons. Persistence across a real save/load rests on the plain `storage` table; not run as a
  separate save test.
- Food numbers with a real stock: `tools/probes/r4_food_headless.lua` (300 rations / 20 a minute = 15 min; with 400
  more rations and grain 35 and 30 min).
- Not tested: a nation with several cities (the per-city rows) in the GUI; one capital only.

### #34 cosmetics

- Done: the recipe grid third row (#35); the flaky `pump_states` check of `tools/probes/r3ux_gui.lua` (waits 5 s more
  before the check; the old check ran right after the scene steps).
- Looked at and left: the long-handed inserter stays Nation only (Skirmish holds 27-28 recipes, a 29th would grow the
  Skirmish panel; #34 wants two rows).
- Not done: train panel over the Build menu (a max-height clamp in `railgui.place` was written and dropped: it clips the
  stop list and `r4-rails` is reworking the rail panels), Rail tool panel and the RU summary line (the Rail tool goes
  away with #37), help cards for the five abilities and the unit panel, clear order for divisions. Open for 0.1.4.

## Tests

| Check | Result |
|---|---|
| Smoke `autotest-run.sh smoke ... waves 240` (before each commit) | 65/65, 0 errors |
| GUI `tools/probes/r4_hud_gui.lua` EN + RU (Nation) | factory page layout PASS, queue 5 / 5, strip steps PASS (shots `build/shots-r4-hud-en`, `-ru`) |
| GUI `tools/probes/r4_hud_skirmish_gui.lua` EN + RU | two rows, Skirmish strip defaults PASS |
| `help-check.py` | 85 entries, 205 + 205 keys, 0 problems |
| Owner save `owner-0112.zip`, 120 s headless | loads, 659 `[rts]` lines, 0 errors |
| Owner save `owner-0111-age2.zip`, 120 s headless | loads, 725 `[rts]` lines, 0 errors |
| M1 seed 501 vs frozen 0.1.2 tree (`determinism-compare.sh`, WHAT=all, 60 min) | 67110 lines both, 2 differing = the stagger-phase listing lines (new modules); no other difference |
| Skirmish seed 777 matrix vs `base0111` | see below |

Screenshot index (`build/shots-r4-hud-en/`, `-ru/`): 01-03 factory page with the panel grown one row (Nation,
buildings, logistics, queue), 04-08 strip default / chooser / picker / edited / reset, s1-s3 Skirmish factory page and
strips.

## Proposed changelog lines

- Factory page: Pause, Auto and Endless are in the page header; a tab that needs more rows makes the panel taller, so the
  status line (progress, state, counts, queue) is always visible.
- The top strip is configurable: a gear button opens a chooser (any item with stock in your networks, power, robots,
  treasury, supply, army counters, timer; order and reset). Defaults: iron, copper, stone, coal, food, rations, power in
  Nation; iron, copper, stone, coal, magazines, power with the army counters and supply in Skirmish. Hovering shows the
  split per city and the last minute's change; food and rations show the minutes left.
- Player text no longer mentions release numbers (the Endless tooltip said "as in 0.1.1").
- Internal: the locale check fails on release numbers, issue numbers and phase names.
