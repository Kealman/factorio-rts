# Release 0.1.2: oil without pipes, a new city's robots, help cards, recipe names (r3-ux)

Date: 2026-10-26. Engine: Factorio 2.1.23 (mac-arm64, Steam), Space Age on. Branch `worktree-agent-a056550886cf2c4ba`.
Issues: #29, #28, #26, #30, #19. GUI runs: 1280x800 window, UI scale 0.75, one client at a time (slots agreed with
`r3-build`, `r3-orders`, `r3-rails`), probe `tools/probes/r3ux_gui.lua`, helper scripts in the session scratchpad
(`.../scratchpad/r3-ux/`: `gui.sh`, `lp.sh`, `ow.sh`, `smoke.sh`).

Commits (oldest first): 0d1a7cb (#29), 94203f7 (#28 + #26), abe8558 (#26 stock from the mother city), 9d7c17f (#30
first cut), merge of main f9426da, c6f978c (#26: AI-commanded forces skipped), 10eca8c (#19), 9b5cb50 (#30 finished).

## 1. #29 Recipe names

**Cause and fix.** `M.recipe` (prototypes/age2.lua) gave a `localised_name` only for multi-result recipes; the engine
fallback to the product's name fails on 2.1 for a recipe whose name differs from its product. Now `M.recipe` and
`M.building_recipe` always set it (`recipe-name.<name>` / `entity-name.<name>`), the air kit recipes use their item name,
and EN and RU `[recipe-name]` entries exist for all 14 recipes that had none.

**Affected recipes (0.1.1, found by the GUI locale probe):** `rts-oil-processing`, `rts-plastic`, `rts-sulfur`,
`rts-engine`, `rts-advanced-circuit`, `rts-concrete`, `rts-processing-unit`, `rts-battery`, `rts-rocket-fuel`,
`rts-light-oil-barrel`. Entries were also added for `rts-steel-beam`, `rts-science-industrial`, `rts-armoured-car-kit`
and `rts-automation-kit` (they worked through their item names).

**Check.** `tools/locale-probe/gen.py` already asks the client to translate the `localised_name` of every `rts-*` recipe:
on the 0.1.1 tree `tools/gui-run.sh` shows `2227 strings, 12 not translated` (10 recipes plus two prefix keys), on the
fixed tree `0` recipes (`rts.results-*-` and the dynamic `rts.route-*-` prefixes are known false positives of the
prefix keys). EN and RU runs: the RU run logs `(en)` for `player.locale` but the strings are translated by the Russian
client (the probe passes with the RU files only, which have the same keys: checked by `help-check.py` for help.cfg and
by the review of 0.1.1 for the rest).

## 2. #28 Oil without pipes

* Pumpjack panel (`scripts/hud.lua` `update_other`): "Crude oil goes into this network as items: N / min" (an
  exponential average kept by `districts.drain`, `rec.pump_rate`), `pump_state` "no network" in red with "Place it inside
  a hub or city area", a dim hint "No pipes: the output is the network. Turning it changes only the picture". The drain
  now checks the network first, so a pumpjack outside every network says so before it has pumped anything, and one alert
  per pumpjack per five minutes ("Oil well outside every network: its crude oil goes nowhere", with a position).
* Refinery and chemical plant pages: a dim hint line under the status line ("No pipes, no rotation: takes crude oil
  from this network as items, returns petroleum to it").
* Build tooltips of the three items have a "No pipes" note; the F11 Nation page has an Oil paragraph
  (`rts-ux.help-nation-oil`).
* R on a refinery or chemical plant (or its ghost) shows the flying text "Cannot rotate: oil travels through the
  network as items, there are no pipes" (`selection.rotate_at`).
* Art: the pumpjack's `output_fluid_box` pipe pictures and covers are removed. The refinery and chemical plant have no
  fluid boxes since 0.1.0, so no pipe stub is drawn by the engine. **Limit:** the vanilla sprites themselves have
  piping and the pumpjack's outlet stub baked in (see `build/shots-r3-ux-en/r3ux-pumpjack-in.png`); removing it needs
  new art, which this release does not have. The panels, tooltips and the R text say what the picture does not.

Screenshots EN / RU: `r3ux-pumpjack-in`, `r3ux-pumpjack-out` (red state and alert), `r3ux-refinery`,
`r3ux-chemical-plant`, `r3ux-refinery-rotate-text` in `build/shots-r3-ux-{en,ru}/`.
Probe checks: `oil_placed`, `rotate_refinery`, `pump_states` (in-network `pumping`, 23 items/min; outside `no network`).

## 3. #26 A new city's robots

* `scripts/netwait.lua` (new, read-only): every 120 ticks, for each hub and City Center of a force no AI commander
  drives, the own entity ghosts in its construction radius whose first item the network holds less than one of count as
  waiting. The hub panel and the city panel show "N ghosts waiting: nothing to build them with ([item] missing in this
  network)" in red, and one alert per centre per five minutes says "<City>: the robots have nothing to build with".
  `scripts/netwaitline.lua` holds the readers so the hub panel (loaded before the cities) needs no cities require.
* Building stock: the settlers of a human player's new city bring raw goods (iron 100, copper 40, stone 40, coal 20), a
  factory, 2 houses and a farm **as far as the mother city's network holds them** (`remove_item` there, `insert`
  here, a refused remainder goes back, nothing is created). The log line lists what moved and what was short:
  `people: city 7 building stock from city 1: moved copper-plate 40, iron-plate 100, rts-factory 1, rts-farm 1,
  rts-house 2; short coal 20, stone 40`. The lead's rule: the economy must matter, so no free kit.
* **AI unchanged.** Both the stock and netwait skip every force an AI drives (`match.ai_forces()` and, in
  autotests, `storage.ai[force]`: the first version tested only the first and changed the M1 seed-501 run, c6f978c).
* The Nation objective hint of the second city says "The settlers bring building stock the mother city can spare;
  bring more by a hauler or a train".
* Optional robot recipe: **not done** (not cheap: it needs a robot item flow into a hub's inventory, a button and the
  network payment; left as a follow-up).

Acceptance in the probe (`r3ux_gui.lua`, second city 300 tiles out, an `rts-lab` ghost nobody can pay): `city_waiting`
PASS (1 ghost), `city_stock` PASS, the alert and the red lines are in `r3ux-city-waiting.png`; a house ghost in the city
was built from the stock by the city's robots. On the owner's Age II save netwait finds real ghosts at once (2 ghosts
waiting for `underground-belt x2` in the capital).

## 4. #30 Help cards

* `scripts/help.lua`: one table keyed by entity name (85 entries: every visible `rts-*` entity, the six vanilla pieces
  and the rail), family per entry, `help.facts(name)` generating the numbers from `balance.lua` and the prototypes
  (cost of the building recipe, health, power use and production, logistic / construction radius, turret range, workers
  from `balance.nation.people.jobs`, unit stats from `balance.units`, the extractor's mining speed, and for machines with
  at most 8 recipes the distinct items they take and make). Texts per entity in `locale/{en,ru}/help.cfg`
  `[rts-help]`: `<name>-how` (2 to 3 sentences) and `<name>-tip`, plus `-line` for the pieces. Abilities keep their
  texts in `rts.ability-*-desc` (already in the ability tooltips).
* `scripts/helpgui.lua`: the card (name, one-line description, How it works, stats, Takes, Makes, Ranges, Needs, Tip, "Also
  in Factoriopedia", Open in F11). Three ways to open it:
  * **Shift hover.** Plain `SHIFT` is not a legal `key_sequence` on 2.1.23 (the prototype load fails: "unknown
    key_sequence: SHIFT"); the custom input `rts-help-hover` is `LSHIFT` with alternative `RSHIFT`, `consuming = "none"`.
    The engine reports key presses only, so the card appears 18 ticks after the press unless a mouse click came first.
    A hover card goes away with the next click, after 20 s, or on a Shift press over nothing.
  * **Shift+F11 / Shift+/** (`rts-help-card`): the card at once, pinned.
  * **? button** on the building page (also for single belts, inserters, poles and ghosts), the hub / depot panel and the
    city panel: the card pinned at the top centre.
* Build tooltips (`build_tooltip`): the one-line description under the name for every building (`entity-description`)
  and the one-liner of the six pieces; the oil items add the "No pipes" note.
* Headless check: `[rts] help: 85 entries, 0 entities without help text` at init (every visible `rts-*` entity of
  `prototypes.entity` has an entry) and `tools/locale-probe/help-check.py` (every entry has `-how` and `-tip` in EN and RU,
  same keys in both, no empty text, no orphan key): `0 problems`. `tools/locale-probe/gen.py` (GUI) translates every
  key of both files.
* **Real input** (`tools/gui-drive.sh`, new `moddown` / `modup` commands in `tools/gui-input/fdrive.swift`, which post the
  modifier as a flagsChanged event): the GUI client receives the Shift press (`helpgui: shift press ...`) and shows the
  card 0.3 s later (`help_hover_real` PASS, `help-hover-real.png`), **Shift+click** adds a walker to the selection
  (2 selected) with no card (`shift_click` PASS), **Shift+right-click** gives `attack_move` (0 to 2 orders) with no
  card (`shift_rclick` PASS), and Shift+F11 shows the card (`help_key_real` PASS). Tooltips are translated by the
  client and logged (`r3ux tooltip rts-refinery: PASS ...`) because a screenshot cannot show a tooltip.
* Screenshots EN / RU: a card per kind (`r3ux-card-{refinery,pumpjack,extractor,city-center,walker,district,depot,hub}`)
  and the real-input captures `help-hover-real`, `help-key-real` in `build/shots-r3-ux-{en,ru}/`.
* Not done: cards for ghosts and units under a Shift hover use the same entry (a ghost shows the card of what it
  will be); the five abilities have no card of their own (their tooltips are the manual).

Texts written from the README and the entity descriptions; if a number in a text became wrong, the card still shows the
generated numbers, the text avoids numbers except the one stable fact per entity.

## 5. #19 Objectives log noise

`objectives.check` marks only the flags of the current mode's steps (`objectives.STEPS[mode]`). The 0.1.1 objectives
probe (`tools/probes/r2_objectives_gui.lua`) passes 27/27 on this tree and a Nation enemy kill no longer logs
"step attack done (.../7, nation)".

## 6. Tests

| Test | Result |
|---|---|
| Smoke `tools/autotest-run.sh smoke ...` before each commit | 65/65, 0 errors (s29, s28, s26, s2826, s26b, s30a-e, s30m) |
| Owner's Age II save (`owner-0111-age2.zip`), 125 s headless on the final tree (also after #29 and #28/#26) | 0 Lua errors, 767 `[rts]` lines, no reset or migration line, the capital's `underground-belt` ghosts reported by netwait; the save has no pumpjack in a network problem |
| GUI locale probe EN, RU on the final tree | 2585 strings, 0 untranslated except the prefix keys |
| `tools/probes/r3ux_gui.lua` EN, RU (final) | all checks PASS (oil_placed, rotate_refinery, pump_states, city_founded, city_waiting, city_stock, hub_panel, help_hover_real, shift_click, shift_rclick, help_key_real) |
| `r2_objectives_gui.lua` EN | 27 PASS |
| Skirmish identity (see 7) | 0 differing lines in all 10 scenarios |
| M1 seed 501 on the tree with the AI gate (see 7) | 51/53, train items 19,101, as 0.1.1 |

## 7. Identity and M1

**Skirmish identity.** `SEED=777 JOBS=2 KEEP_TREE=<archive of 9d7c17f> tools/autotest-matrix.sh r3ux` against
`base0111` (the lead's 0.1.1 baseline, its server logs linked into this worktree's `build/`), then
`tools/matrix-compare.sh base0111 r3ux`: `1v1-easy-medium 1235/1235`, `1v1-hard-medium 3691/3691`,
`1v1-normal-medium 3356/3356`, `1v1-normal-small-nosa 2700/2700`, `1v1-normal-small-restart 4597/4597`,
`1v2-normal-medium 4722/4722`, `1v3-normal-small 4858/4858`, `1v3-normal-small-stress 3024/3024`,
`legacy-units 470/470`, `legacy-units-nosa 473/473` lines, **total differing lines: 0**. The tree is 9d7c17f, my work on
top of 0.1.1 before the merge of main, so the identity is mine alone (the later commits touch only Nation code,
objectives and GUI).

**M1 seed 501 (the regression the lead found in 94203f7).** The first version of netwait and of the building stock
looked at `match.ai_forces()` only; in autotests the `rts-player` force is played by an AI commander that list does not
contain, so the player side got the stock and the ghost line and the run left the 0.1.1 path at minute 1 (train items
19,101 to 7,784). c6f978c adds `storage.ai[force] ~= nil` to both tests. Rerun
(`PERF=1 EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN=60 SEED=501 SPEED=8 tools/autotest-run.sh r3ux-m1-s8
'{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 4800`, tree = merged
main + the fix): `51/53`, `train_items` 19,101 (rts-player 10,881 in 60 trips, rts-ai-1 8,220 in 39), both alive: the
0.1.1 numbers. Against r3-rails's baseline log (`r3r-m1-base-server.log`; `[rts]` lines normalised, timing and
stagger lines dropped) 68,909 lines against 68,871: 38 differ, all of them lines only the baseline has (production,
logistics and fog chatter lines, none added on this side), which looks like log throttling and not a state change; the
counters (items moved, trips, minute lines) are identical.

## 8. Open items

* The vanilla sprites keep their baked piping and the pumpjack's outlet stub (needs art).
* The optional robot recipe of #26.
* A card for the abilities and a hover card on the HUD's unit panel.
* The key release is not reported by the engine: a Shift hover card closes by click, timeout or the next Shift press, not
  by releasing Shift.

## 9. Proposed changelog lines

**Bugfixes**
* Fixed `Unknown key: "recipe-name.rts-oil-processing"` (and nine other recipes) in the refinery, chemical plant and
  factory pages: every recipe has an explicit EN and RU name.
* The objectives of the other mode no longer log "step done" in a match (log only).

**Features**
* Refinery, chemical plant and pumpjack say that oil travels through the network as items: panel lines, a
  "no network" state and an alert for a pumpjack outside every network, build tooltips, a paragraph in F11, and a flying
  text on R.
* A new city's hub and city panels show "N ghosts waiting: nothing to build them with" and raise an alert when its robots
  have nothing to build with. The settlers of a new city now bring raw goods, a factory, two houses and a farm from the
  mother city's network (as far as it holds them).
* Help cards: hold Shift over a building, unit or ghost (or press Shift+F11 / Shift+/) for what it is, how it works, what
  it takes and makes, its ranges, needs and a tip; a "?" button on building, hub, depot and city panels; the build menu
  tooltips now show a one-line description. English and Russian.

**Modding / tools**
* `tools/locale-probe/help-check.py`, `tools/probes/r3ux_gui.lua`, `moddown` / `modup` in `tools/gui-input/fdrive.swift`.
