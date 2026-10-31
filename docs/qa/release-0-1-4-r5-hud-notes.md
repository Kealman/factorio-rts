# Release 0.1.4: r5-hud notes (#42, #43, #40)

Agent `r5-hud`, branch of the worktree `agent-a2d5bbac062ed9bda`, base `da0ec26`. Factorio 2.1.23, GUI runs at 1280x800,
UI scale 0.75, EN and RU. Screen slots came from `r5-rails`.

## Commits

| Commit | Issue | What |
|---|---|---|
| `1cb3a6b` | #42 | Rail signal, Chain signal and Rail station recipes on the factory's Logistics tab; build tooltips; help cards and F11 paragraph |
| `c6621ef` | #40 | chooser and help cards clear of the notification lines and the status line, ability card headings, clear order for whole divisions, long-handed inserter in Skirmish |
| `18c918f` | #43 | strip chooser offers every item, grouped, zero stock allowed; hover with minutes left for goods |
| `063df4d` | #42 | final signalling wording from `r5-rails` (card and F11) |

## #42 Signals and the Station on the Logistics tab

* `P4.LOGISTICS_PRODUCTS` (scripts/hud.lua) gained `rts-station`, `rail-signal`, `rail-chain-signal` (the products of the
  three recipes). `P4.recipe_tab` therefore puts them next to the rail. The #35 growth rule (`set_panel_rows`) sizes the
  panel: the probe's Logistics tab holds 22 recipes in 2 rows and the three buttons are present
  (`r4 gui logistics_signals: PASS`), `buildings_no_signals: PASS` (they left the Buildings tab).
* Build tooltips of the three items end with "Made by the factory, Logistics tab." (`rts-signals.note-made`, via the
  `OIL_NOTES` table of `with_places_note`). The Logistics tab tooltip names signals and the Station.
* Help: the two signals are help entries (family `piece`: Shift over the placed signal, "?" cards, the build tooltip's
  one-line description) with how / tip / line texts in `locale/*/help.cfg`; a new Nation paragraph "Rail signals" in the
  F11 window (`locale/*/signals.cfg`, `rts-signals.help-nation-signals`, inserted before the keys paragraph). Wording is the
  final text of `r5-rails` (chain signals in pairs, passing loop, Delete twice). `tools/locale-probe/help-check.py`:
  87 entries, 215 EN / 215 RU keys, 0 problems.
* Not done: no dedicated pinned "signalling" card with a "?" button (the entity cards and the F11 paragraph carry it; a
  button would live in railgui, which `r5-rails` owns).

## #43 Strip chooser offers every item

* `stripgui.pickable_sections(player, nation)` returns the union of: items in any own logistic network (Command Centers,
  City Centers, hubs, depots through the `hub` kind), the Command Center snapshot, the city needs (rations, goods) and
  grain, the make targets of own cities (Nation), every product of an enabled recipe of the force (Nation-only items
  hidden in Skirmish), and the vanilla pieces (belts, inserters, poles, rail, signals, Station). Hidden items, cursor tools
  and entries already on the strip are left out; zero stock is fine.
* Four sections in the picker (`itempicker.open` opts.sections, new): Food and goods, Plates and intermediates, Buildings
  and pieces (anything that places an entity), Kits and military; each in item order (group, subgroup, order).
  `stripgui.group_of(item)`. The picker has no search box (a scroll pane of 10 columns); sections keep it short enough.
* Hover: `stripgui.item_detail(force, item)` (the old `food_detail` name is kept) counts every item across all own
  networks, shows the per-network split when there is more than one network, and the minutes left for anything the cities
  use (rations, grain, household goods: `rts-strip.tip-left-item`). The strip's numbers therefore count City Center and
  hub networks too (before: the Command Center snapshot only for non-food). Network contents are read once per tick.
* The 12-entry limit and the per-mode defaults are unchanged.
* Probe `tools/probes/r5_strip_gui.lua` (MODE nation / skirmish, EN and RU): chooser opened with three alert lines up;
  Nation picks household goods, stone brick, hauler kit and wall at zero stock of a fresh match, all PASS, the strip shows
  them and `hover_rts-goods` reports 100 in the networks and 12.5 minutes left; Skirmish picks magazine, walker kit and
  basic science pack, all PASS. Offered counts at the start: Nation 54 items (1/10/34/9 per section), Skirmish 43 (2/10/23/8).
  Log line `[rts] strip: picker offers N items ...`.
* Shots: `build/shots-r5strip-nation-en/`, `build/shots-r5strip-nation-ru/` (and the Skirmish runs, shots moved into
  `build/shots-r5strip-skirmish-*/`).

## #40 GUI cosmetics

| Item | Result |
|---|---|
| Strip chooser over the notification banner | The chooser opens left of the alert lines, its item picker under them (`rts_hud_alerts` location); shot `rts-r4hud-05-chooser.png`, `06-picker.png` with three probe alerts up |
| Help cards over the strip's status line | Pinned cards open at y = 106 (below the strip) and left of the alert lines; shot `rts-r4hud-c1-unit-card.png`, `c2-abilities-card.png` |
| RU Overcharge heading wrap | The ability card heading is a line of its own, hotkey and cooldown on a dim line below; no heading wraps in RU (`build/shots-r5hud-ru/rts-r4hud-c2-abilities-card.png`) |
| Clear order for whole divisions | `divisions` router: kind `clear` always detaches the selected members (whole division or not) and they clear loose; `orders.clearers` resolves with kind `clear`. AI never calls `orders.clear`. Not covered by a headless probe of its own: the identity runs below cover that the AI is untouched |
| Long-handed inserter in Skirmish | Skirmish factory page holds exactly 28 recipes with it (2 rows of 14; `r4 sk factory_rows: PASS 28 recipes, present=true`); removed from `P4.NATION_ONLY`; the status line stays visible |
| RU depot panel 13 px above the Build menu | Not changed: no overlap, owned by `railgui.place` (`r5-rails` file); the margin is 8 GUI units by design. Left for a pass that touches the depot panel |
| RU locale GUI run logs player locale as en | Probe artifact, untouched |
| Clear button in the build menu | Not done (not cheap: needs an area-selection mode of its own) |

Probes extended: `r4_hud_gui.lua` (three fake alert lines; shots taken before the next click so "02-nation-logistics" shows
the Logistics tab; new checks `logistics_signals`, `buildings_no_signals`; the picker shot has its own step),
`r4_hud_cards_gui.lua` (alerts up), `r4_hud_skirmish_gui.lua` (the long-handed inserter must be present).

## Tests

* GUI runs EN and RU, final tree: `r4_hud_gui` 15/15 each, `r4_hud_cards_gui` 3/3 each, `r4_hud_skirmish_gui` 2/2 each,
  `r5_strip_gui` all PASS in Nation and Skirmish, EN and RU. Shots: `build/shots-r5hud-en/`, `build/shots-r5hud-ru/`.
* Smoke `tools/autotest-run.sh smoke ...`: 65/65, 0 errors (before the #43 commit and after #42).
* Owner saves load on the final tree (100 s headless each, 0 errors, nothing reset): `owner-0113-now`, `owner-0112`,
  `owner-0111-age2` (`build/r5hud-owner-*-server.log`).
* Identity: M1 seed-501 Nation run, 60 minutes, `WHAT=all`, 0.1.3 tree `61d6f05` against this tree: 68,801 lines each,
  **0 differing**. Skirmish matrix SEED=777 against `base0111`: see next paragraph.

Skirmish matrix `SEED=777 JOBS=1 tools/autotest-matrix.sh r5hud` against `base0111` (frozen copy of this tree): 10 scenarios,
0 errors, **total differing lines 0** (the 1v3 stress scenario's 36/38 equals the base's own result, as the compare shows no
difference).

## Proposed changelog lines

* Added: the Rail signal, Chain signal and Rail station recipes moved to the factory's Logistics tab next to the rail; their
  build tooltips say where they are made; a "Rail signals" help paragraph in F11 and help cards on both signals.
* Added: the top-bar chooser offers every item (stock in any network, what the cities need and make, everything the factories
  can make, the pieces), in four groups, with zero stock allowed; the hover shows household goods' minutes left; the top
  bar counts City Center and hub networks too.
* Changed: the top-bar chooser and the pinned help cards no longer cover the notification lines or the strip's status line;
  the ability card headings fit in Russian.
* Added: the long-handed inserter is available in Skirmish too.
* Fixed: a clear order given to whole divisions now works (the members detach and fell the trees).
