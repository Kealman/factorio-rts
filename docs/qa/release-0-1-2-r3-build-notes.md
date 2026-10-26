# Release 0.1.2: r3-build notes (#23, #27, #25)

Branch `worktree-agent-a1a21e32eb8b77660`. Engine Factorio 2.1.23. Plan: `docs/qa/release-0-1-2-plan.md`.

## 1. What changed

### #23 and #27: one selection path for own non-building entities and ghosts

* New module `scripts/pieces.lua` (no state): `pieces.kind` (ghost / piece / nil), `pieces.at` (nearest own piece or ghost within
  0.35 tiles of its selection box), `pieces.in_area`, `pieces.describe` (HUD page text), `pieces.remove` (refund and contents).
  Pieces are decided by NAME (`pieces.RECIPE`: transport-belt, underground-belt, splitter, fast-inserter, long-handed-inserter,
  medium-electric-pole) plus any `entity-ghost` of the player's force. A hub's hidden pole, enemy and neutral entities never count.
* **`storage.buildings` is unchanged**: no belt records, no `on_object_destroyed` registration, no alert or AI counters touched
  (the "design note" option 2 of the issue). Selection state is `storage.players[i].pieces` (array of LuaEntity) and
  `piece_boxes` (render objects), created lazily and dropped by every other selection change. Exclusive with units and building.
* `scripts/selection.lua`: `select_pieces`, `get_pieces`; `handle_area`: a click picks the nearest of building / piece (a piece
  wins only when strictly nearer, so a belt next to a stockpile is selectable); a box with no own unit inside selects the
  pieces and ghosts in it (Shift adds). A box that holds units behaves as before. `building_at` now also returns the distance.
* `scripts/demolish.lua`: `request` checks the piece selection first. Ghosts are cancelled at once on the first press
  (`ghost cancelled <name> at (x, y) player=N`, `demolish: done player=N ghosts=K refund []`); real pieces follow the two-press rule
  (`demolish: armed player=N pieces=K (key)` then `demolish: done player=N pieces=K refund [5 iron-plate]`); a mixed selection cancels
  the ghosts and arms the pieces. `is_armed` / `preview` know pieces.
* Refund (`pieces.remove`): 50 % of the recipe cost per piece, `math.floor` with the fractions carried across the batch, so
  10 belts (10 iron per craft of 10) refund 5 iron plates and a lone belt refunds 0; the flying text says
  "The refund rounds down to nothing". Items on a belt or in an inserter's hand go through the new
  `buildings.deliver_items` (network stockpile, else stockpile in range, else the CC pool, else spilled), the same cascade as
  `buildings.demolish`. `buildings.demolish` itself is untouched.
* HUD: the building page is reused: title, a Rotate button (rotatable pieces and ghosts), Demolish (red "Press again" armed) or
  Cancel for a pure ghost selection; one piece shows "From / To" (inserter), direction, items on the belt or wire links; a group
  shows "N pieces selected" and the count per name. Locale EN+RU in `locale/*/demolish.cfg`.
* Nation attack-move collateral rules (`scripts/targeting.lua`) are untouched.

### #25: underground belts, splitters, long-handed inserters

* Recipes (factory, subgroup `rts-economy`): `rts-underground-belt` (10 iron + 5 belts, 4 s, 2 undergrounds), `rts-splitter`
  (10 iron + 5 copper + 4 belts, 4 s: the no-circuit variant, Age I has no circuits), `rts-long-inserter` (15 iron + 5 copper, 3 s, 5 items).
* Build menu economy tab: belt, underground belt, splitter, fast inserter, long-handed inserter, pole. `P4.LOGISTICS_PRODUCTS` has
  the three new products (Nation factory logistics tab). Selection, demolish and refund come from the #23 path (`pieces.RECIPE`).
* **Deviation: the long-handed inserter (recipe and build item) is Nation only** (`P4.NATION_ONLY`). The Skirmish factory page is one
  grid of 14 columns and exactly two rows fit the 126 px panel (28 buttons, Pause included): 26 buttons existed, the three new
  recipes made it 29 and the last one fell out of the panel (seen in the first GUI run). The issue calls the long inserter optional.
  If the lead wants it in Skirmish, the factory page needs a third row or a smaller button.
* Rotation and the underground pair placement are vanilla cursor-ghost behaviour (unchanged code); `buildings.item_cost` finds the
  recipe through `prototypes.recipe[name]`: the three vanilla item names have no `balance.buildings` entry and the build tooltip
  uses `recipe_for(item)`, which finds the rts recipe by product. The AI's template and budgets are unchanged.
* Not done by me (files owned by the lead): README "Chains" and `docs/FEATURES.md`; proposed text below.

## 2. Tests

| Test | Command | Result |
|---|---|---|
| Headless probe `tools/probes/r3_build_headless.lua` | `STOP_ON='r3 build probe done' EXTRA_LUA=tools/probes/r3_build_headless.lua tools/autotest-run.sh r3b '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 300` | 0 failures: click select + two presses of belt / inserter / pole (held items moved), box of 10 belts refunds 5 iron, a lone belt refunds 0, smelter ghost cancelled with one press, 10 belt ghosts boxed and cancelled with one press, enemy belt, enemy ghost and enemy box not selectable, CC click still selects the CC, underground / splitter / long inserter select and demolish, an underground pair refunds 5 iron + 2 belts, the three recipes are enabled and the factory accepts them, registry count unchanged (22 = 22) |
| Smoke | `tools/autotest-run.sh smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65, 0 errors (before each commit) |
| GUI probe `tools/probes/r3_build_gui.lua` (EN and RU) | `tools/gui-run.sh <dir> 200 RTS_R3_BUILD_GUI_DONE` | all PASS; screenshots in `build/shots-r3-build-en/` and `build/shots-r3-build-ru/` |
| Owner save | `tools/probes/r3_build_save.lua` on a copy of `build/saves/owner-0111-age2.zip`, 135 s | 875 `[rts]` lines, 0 Lua errors, no reset line; the save's own belt, fast inserter and medium pole are selected and demolished (armed/done), and a 6-belt box too |
| Identity | see section 3 | see section 3 |

Screenshots (`build/shots-r3-build-{en,ru}/`): `rts-r3-belt|inserter|pole|underground|splitter|longinserter.png` (one piece page),
`rts-r3-line.png` (5 belts boxed, "Press again"), `rts-r3-armed.png`, `rts-r3-ghost.png` (smelter ghost, Cancel), `rts-r3-factory.png`
(Skirmish factory grid, two rows), `rts-r3-build.png` (economy tab).

## 3. Identity and open items

* Skirmish identity: `SEED=777 JOBS=2 tools/autotest-matrix.sh r3build` then `tools/matrix-compare.sh base0111 r3build`:
  **total differing lines: 0** (6 common scenarios). The matrix also ran 4 scenarios without a base0111 counterpart: nosa 22/22,
  restart 23/23, legacy-nosa 65/65, and stress 36/38 (`produce_*` kit checks fail because the stress match ends early with a
  winner; not compared, pre-existing behaviour of that scenario as far as the lead's 0.1.1 reports show). 0 Lua errors in all 10.
* Owner save (`owner-0111-age2.zip`, final tree, 135 s): 851 `[rts]` lines, 0 Lua errors, no reset; existing belt, inserter, pole demolishable.
* Final smoke 65/65 and the headless probe 0 failures on the committed tree.
* Not tested: real crafting of the new recipes over minutes (the probe sets the recipe on a factory and checks the recipe is
  enabled; the factory crafting code is generic) and a live underground pair under a wall with ore flowing (vanilla engine behaviour).
* `buildings.deliver_items` duplicates the three-tier refund cascade of `buildings.demolish` on purpose (that code is
  identity-critical and untouched). A later cleanup can make `buildings.demolish` call it.
* Mouse path: the probes call `selection.handle_area` and the Demolish / Rotate button handlers; the real mouse goes through the
  same `on_player_selected_area` event with an empty entity list (the selection tool filters on unit types), as the building
  click already did. A real-mouse check of a belt click is still open for the lead's GUI pass.

## 4. Proposed changelog lines

* Bugfixes / Interface: Belts, undergrounds, splitters, inserters and medium poles can be selected (click, or a box with no units
  in it) and demolished with Delete or the Demolish button; the refund is half of the recipe, rounded down per batch.
* Interface: Placed ghosts can be selected (click or box) and cancelled at once with Delete, Backspace or the Cancel button.
* Economy: the factory crafts underground belts, splitters and (Nation) long-handed inserters; the economy build menu has them.

README "Chains" proposal: "... It makes buildings, belts, underground belts, splitters, inserters, poles, magazines ..." and a
sentence "Select a misplaced belt, inserter, pole or ghost with a click or a box and press Delete (twice for built pieces, once for ghosts)."
