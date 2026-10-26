# Release 0.1.2: r3-orders notes (#22 craft queue, #24 clear trees and rocks, #21 supply-route coal)

Branch `worktree-agent-ac26fb24b598633c6`. Engine Factorio 2.1.23. Commits: `624da26` (#22), `7c922f5` (#24), `edf92dd`
(#21), then the merge of `main` (26026ae) so the last checks ran on the integrated HUD.

## 1. #22 Craft queue

**What changed.** `scripts/production.lua`: `production.queue_recipe(target, recipe, count)`, `production.unqueue(target, n)`,
`production.affordable(target, recipe)` and the `rec.queue = {recipe, remaining, total, pf, restore_auto}` record. The
queue counts down on the `products_finished` delta (`queue_step`, called from `check_barracks` and `hand_off`). `pull`
tops the input up to `min(PULL_CRAFTS, remaining - crafting)` crafts, so a machine never makes more than ordered. At zero
and with an empty output the machine takes `set_recipe(nil)` (a stopped machine, not a dead pause: a new click queues
again) and an order that overrode Auto hands the machine back to Auto. `production.set_recipe` is unchanged for callers
(the AI and `logistics.lua` keep endless production) and drops a running queue; `set_auto(true)` also ends the queue.
The same recipe clicked again adds to the order, another recipe replaces it.

**HUD** (`scripts/hud.lua` `hud.recipe_click(player, recipe, mods)`): click = 1, Shift = 5, Ctrl = as many as the
network (plus the machine's input) can pay, right click = take 1 off the order (Shift 5, Ctrl all). Pause stays first,
Auto second in Nation mode, the new **Endless** toggle (`*endless*`, a per-player pref) comes after them and never moves
them; with Endless on a recipe click is the old endless `set_recipe`. The ordered recipe's button shows the remaining
count (`button.number`) and the status line says "Extractor: running (221 / 223 left)". Internal selftest calls pass
`{endless = true}`. Locale: `recipe-queue-hint`, `recipe-endless-tooltip`, `recipe-queue-line` in `locale/en/hud.cfg` and
`locale/ru/hud.cfg`.

**Tests.**

| Test | Result |
|---|---|
| `tools/probes/r3_orders_headless.lua` (Skirmish 777, `SPEED=3`) | 22/22: queue 1 -> exactly 1 extractor, stops, nothing more in the next 15 s; queue 5 -> 5; Ctrl count = 4 for a stock of 4 crafts, ran out of the stock; endless drops the queue and goes on; Auto -> order overrides -> hands back to Auto; unqueue 10 -> 9 -> 4 -> 0 stops; barracks 1 kit -> 1 unit, 5 kits -> 5 units |
| `tools/probes/r3_orders_gui.lua` (GUI client, handler path with the click's modifier flags) EN and RU | 11/11 PASS each: plain, Shift, Ctrl, right, Ctrl+right, Endless on, Pause, barracks Shift x5 |
| Screenshots | `build/shots-r3-orders-en/` and `build/shots-r3-orders-ru/` (9 each; `rts-r3og-05-queue-ctrl.png` shows the count 221 on the button and "221 / 223 left") |
| Smoke | 65/65, 0 errors (after the merge too) |

## 2. #24 Clear trees and rocks

**What changed.** `scripts/orders.lua`, section "Clearing trees and rocks": `orders.clear(who, targets)` (the call for the
AI: `who` is a player index or an entity list), `orders.clear_area(who, area)`, `orders.nearest_clearable`,
`orders.is_clearable`, `orders.mark_ghost_site`. Unit record: `order = "clear"`, `rec.clear = {job, idx, ready, deadline,
fails, cmd_tick}`, `rec.target` is the tree being walked to; `storage.orders.clearing` is the set the 15-tick step visits.
A job (shared list of targets) is split nearest-first among the units: each takes the nearest target nobody else walks to,
walks there (`go_to_location`, radius 1.2, through the path queue), and the script fells it (`die()`, then `destroy` if it
stays) when the unit is within `CLEAR_REACH` = 2.5 tiles and its rate allows (`CLEAR_TICKS`: walker 60 ticks, heavy and
Commander 30). A target a unit cannot reach (3 failed paths, or 20 s) is dropped and counted ("N of M targets given up");
a unit pulled away (an enemy in sight) is sent back every 2 s. Rocks pay their mining products (stone, coal) to the
nearest own stockpile, else the force's pool (`economy.give`). Trees stay on the neutral force (checked in the probe).
Units owned by another module (a moving division, haulers: not `spider-unit`/`unit`) are left alone.

* Right click on a tree or rock with units selected (no enemy under the cursor, not while attack-move is armed): clear
  order for the nearest one. Log: `order clear n=1 targets=1 first=<tree> player=N`, then `order clear done: ...`.
* Shift + right-drag of at least `CLEAR_DRAG` = 3 tiles over trees or rocks: box clear (a plain Shift + click or a small
  drag stays an attack-move). The right-click hooks now get the area as a fifth argument.
* A player-placed ghost marks the trees and rocks under it for deconstruction (`on_built_entity`), so the construction
  robots clear the site (marked 9 trees under a hub ghost; the hub was built 8 s later).
* Not done: the "whole division" version (division members that carry a division order are skipped; idle members clear
  as loose units), a Clear tool button in the build menu, an AI call site (the call exists; the AI's base template and
  expansion placement already avoid forests). Open items for the lead.

**Tests** (`r3_orders_headless.lua`, same 22/22 run): 4 walkers clear a 20-tree patch in 6.5 s (the issue asks about 10 s);
a right click on a tree -> `clear n=1`; a Shift drag over 9 trees -> `clear n=1`, 9 trees felled in 8.5 s by one walker;
a big rock -> +40 stone to the stockpile; a hub ghost over 16 trees -> 9 marked, hub built in 8 s. Skirmish smoke is
identical when no clear order is given (the only code on that path is one `entity.type` test per right click).

## 3. #21 Supply routes burn coal on small loads

**What changed.** `scripts/logistics.lua` `manual_plan` now also returns `hold` (true for a route whose drop-off keeps
stock levels, when every planned item is in `balance.nation.supply_hold_items` = rations, goods, magazines, and every one
stands at `supply_low` (0.5) of the drop-off's keep or more). `plan_next` then lets a manual hauler at its pickup wait in
the existing `small-load` state (up to `balance.nation.supply_batch_wait` = 4 min) while its load is under
`hauler_items_per_coal` items per coal of the round trip. Below half the keep a small load leaves at once (rations never
wait); export / feeder routes (a drop-off with no keep levels), fuel and building routes never wait; 0.1.1's return-leg
rule (the way back's coal, rescue) is untouched, and a waiting hauler stands at a hub with its network, never in the
field. The first version held every keep-level route and cost train items in both seeds (train_items 11,226 on 501 and
two lost lines): the hold set is now the people's goods only.

**Measurements**, Nation M1 (1v1, 2048, 60 min, SPEED 8, `m1_acceptance.lua`), `tools/probes/r2e_coal_by_mode.py`
(coal per leg, the Nation charge as an upper bound). `before` = 7c922f5's mod, `v1` = edf92dd's first version (every keep
route), `after` = the rations / goods / magazines version. Runs are chaotic: the AI trajectories diverge at the first
changed load, so the numbers below are two runs per seed, not a controlled difference.

| Run | rts-player manual: coal, deliveries (under 20) | rts-ai-1 manual: coal, deliveries (under 20) | Auto coal (both) | train_items | Checks |
|---|---|---|---|---|---|
| 501 before | 3,419, 133 (106) | 3,438, 139 (116) | 425 + 130 | 19,101 | 51/53 (age2 ai-1, train_items) |
| 501 v1 | 2,322, 65 (28) | 2,624, 87 (55) | 343 + 284 | 11,226 | 50/53 |
| 501 after | 2,671, 100 (70) | 2,682, 89 (65) | 718 + 179 | 13,314 | 51/53 (age2 ai-1 at 22:39 instead of 32:36, train_items) |
| 502 before | 2,155, 99 (89) | 3,433, 122 (103) | 298 + 198 | 20,424 | 53/53 |
| 502 v1 | 1,538, 61 (50) | 3,117, 93 (58) | 297 + 296 | 18,941 | 51/53 |
| 502 after | 268, 10 (2) (the player's army died early) | 3,092, 87 (60) | 48 + 235 | 22,279 | 51/53 (rts-player lost: districts, cars) |

Reading: manual coal falls 10 to 30 % and the under-20 deliveries fall by a third to a half in every pair; items
per coal of the manual routes rise (rts-player 501: 2.9 to 2.9 in the after run, 5.8 in v1; rts-ai-1: 1.4 to 2.0). train_items
and the AI trajectories move both ways with the coal (501 after: 13,314 against 19,101; 502 after: 22,279 against
20,424), because the first changed load changes everything after it; I could not isolate a train-item effect from the
noise with two seeds. The lead's `release-check` M1 pair and M2 701-705 are the better judge; if train_items is a hard
gate, `balance.nation.supply_batch_wait = 0` turns the change off without touching code.

## 4. Identity and saves

* **Skirmish seed 777 identity** (`SEED=777 JOBS=2 tools/autotest-matrix.sh r3orders`, `tools/matrix-compare.sh base0111
  r3orders`) on the merged tree: total differing lines: 0 (all 11 scenarios)
* **Owner save** (`build/saves/owner-0111-age2.zip`, copy, 130 s, merged tree, `tools/probes/r3_owner_save.lua`): 0 Lua
  errors, 819 `[rts]` lines, no reset or migration lines; the existing factory took a queue of 1 extractor and stopped,
  the barracks took 1 kit (one unit), a walker cleared 3 planted trees in 3 s. New storage (`rec.queue`,
  `rec.clear`, `storage.orders.clearing`) is created lazily; nothing is migrated.
* Smoke on the merged tree: 65/65, 0 errors.

## 5. Proposed changelog lines

Features:
* Factory and barracks recipe buttons order crafts like vanilla handcrafting: click = 1, Shift = 5, Ctrl = as many as the network can pay, right click takes crafts off the order; the status line and the button show the crafts left, and a finished order stops the machine. A new Endless toggle in the recipe grid keeps the old endless production.
* Units clear trees and rocks: right click on a tree or rock, or Shift + right-drag over an area; rocks pay their stone to the nearest stockpile. A ghost placed over trees marks them for the construction robots.

Balance / fixes:
* Town supply routes wait for a fuller load of rations, goods and magazines while the town still holds half its stock, which cuts hauler coal on small deliveries; below half they leave at once.

## 6. Open items

* Clear order for whole divisions, a Clear button in the build menu, and an AI call site (`orders.clear(entities, targets)` exists).
* Ctrl+click counts what the network holds now; a Ctrl order for a recipe whose ingredients another factory makes is not planned.
* #21: confirm with the release-check M1 / M2 runs; `supply_batch_wait = 0` disables it.
