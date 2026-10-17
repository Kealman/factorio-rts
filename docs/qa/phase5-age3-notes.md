# Phase 5 M3, package "Age III, Space Program, rare bonuses, money sinks" (wave A)

Date: 2026-10-17. Factorio 2.0.77 (mac-arm64, Steam). Agent: `m3-age3`. Contract: `docs/PHASE5-M3.md` (decisions D1, D2,
D3, D10, D11; §1; §2 row `m3-age3`; §3 "age3.lua / rare.lua / sinks.lua"; §4 "Age III / rare / sinks"; §5). Studies:
`docs/research/scale/deep-economy.md` §2.5, §2.6, §3.7, §5.6, §9.3. Open issues folded in:
`docs/qa/phase5-m2-integration-notes.md` §6 item 6 (money not tight), `docs/qa/phase5-ai-notes.md` §6 item 3 (tax and
deficit flapping). Built and tested in `build/p5m3-age3/factorio-rts` (a copy of `mods/` at HEAD 9263e69); nothing in
`mods/` was touched. `build/p5m3-age3/sync.sh` brings the package over once syncing opens (section 5). Everything here
is Nation mode only; Skirmish is unchanged (smoke 65/65).

## 1. Verdict

| Contract item (§4) | Result |
|---|---|
| A scripted nation that delivers stage 1 reaches Age III and its districts unlock | PASS (fixture `stage1_age3`, `age3_recipes`, `age3_signal`) |
| Stage 3 ends the match with Space victory when the mode allows, and not otherwise | PASS (`space_mode`: mode Conquest, the match goes on; `space_victory`: Conquest+Space, the match ends, "space") |
| An automated family at 2 kits per district shows jobs x0.49 and the same output | PASS (`automation_jobs`: factor 0.490, city jobs 28.00 -> 19.84; `automation_output`: speed 1.000 -> 1.000, staffing 1) |
| Saltpetre raises explosives productivity by 0.25 within 90 s; losing the flow removes it within 90 s | PASS (`rare_on` at the first arrival; `rare_grace` still on at 80 s, `rare_off` gone at 92 s, every delta back to the start value) |
| The nuclear plant yields 40 MW from uranium | PASS (`fuel_rod`: a rod from uranium ore in the Chemistry district; `nuclear_40mw`: 40.28 MW into a sink) |
| Rush doubles a project's pull speed and charges per item-s | PASS (`rush_pull` 20 per good and second, `rush_stage2` countdown 15 s instead of 30, `rush_charge` expenses = the rush's charges) |
| Hired garrison points decay | PASS (`hire`: 8 points for 320 cr, 2 hidden turrets; `hire_decay` 6.83 after 62 s) |
| A mercenary division spawns at a port and the cooldown holds | PASS (`mercenaries`: 6 units at the port, a second hire refused "cooldown") |
| Tax switches <= 2 times per nation-hour in a 60-minute 4-nation run | PASS on seed 701: 4 switches in 4 nation-hours (1.0) on the final tree, 6 (1.5; the most for one nation 3) in the run before; deficit mode the same |
| City-state trade changes relation | PASS (`city_state_buy` relation +cr/100, `city_state_arrival` after 30 s, `city_state_capture` -10) |
| The normal AI reaches Age III by 40:00 in 3 of 5 seeds | wave B (`m3-ai`): the AI does not start the Space Program yet (section 7) |
| Skirmish smoke 65/65; M1 acceptance seed 501 | 65/65; 53/53 (section 6) |
| GUI (both locales, 1280x800) | 9/9 clicks through the real handlers, 0 errors, screenshots `build/shots-p5m3-age3-gui-{en,ru}/` (section 6.2) |

## 2. What a player sees

1. **Electrification** (Age II, 40 industrial kits, after Industrialisation) unlocks the **Space Program**. The ledger
   (L) and the age badge show it from Age II on: "Research Electrification ...", then "Start the Space Program". Start
   places the **Launch complex** (8x8, the rocket silo's platform) next to the capital, inside its logistic network. It
   pulls each stage's goods from that network, 10 per good and second, and counts down when the list is complete:

   | Stage | Goods | Countdown | Result |
   |---|---|---|---|
   | 1 structure | 200 steel, 200 concrete, 100 advanced circuits | 20 s | **Age III** (signal `rts_age_up` {force, age = 3}) |
   | 2 systems | 40 processing units, 100 batteries, 80 engines | 30 s | |
   | 3 fuel | 40 rocket fuel, 200 sulfur, 50 light oil barrels | 120 s ("launch in N s", every nation is warned) | **Space victory** under Conquest+Space and Any (signal `rts_space_victory`) |

   Every nation sees the complex's bar and label ("Space Program 2/3: 45 %"). A destroyed complex loses half of the
   running stage's deliveries; finished stages stay; Start places a new one.
2. **Age III** enables the Age III recipes: the **Chemistry district** (plastic and sulfur straight from crude oil;
   light oil in barrels; batteries and rocket fuel with *Chemistry*; fuel rods from uranium ore with *Nuclear power*),
   the **Electronics II plant** (advanced circuits, processing units, automation kits), the **Concrete works**, the
   factory's processing units and automation kits, the chemical plant's batteries, rocket fuel and barrels. *Nuclear
   power* (Age III and Geology) unlocks the **Nuclear plant**: 40 MW from fuel rods (one a minute at full load), which it
   takes from its logistic network, and **uranium rounds** (Munitions works): while the capital's network pays one
   magazine per heavy walker a minute, heavies deal +30 %.
3. **Automation** (ledger, Age III): one button per labor family with districts; a city's policy "automate <family>"
   puts two automation kits from the city's network into each district of that family (module slots 2 and 3); each
   kit cuts the building's jobs by 30 % at the same output. Off, a lower age or a change of owner takes them out
   again (into the network).
4. **Rare resources.** *Geology* unlocks the **Rare extractor** (3x3, own or neutral land, no power): one item every
   10 s from a rare deposit into the logistic network it stands in. Every second the capital's network gives up the
   rare items that reached it; each arrival holds that kind's nation-wide bonus for 90 s. Bonuses: saltpetre +25 %
   explosives and magazines, quartz +20 % circuits (all three), tungsten +20 % steel (recipe productivity), diamonds
   +15 % mining productivity, rare earths +10 % lab speed and productivity, gold +15 % tax. The ledger lists them
   ("Rare: [saltpetre] +25 % explosives and munitions (73 s) ..."); alerts when one is gained or lost.
5. **Money sinks.** *Rush* (ledger, next to Start; research panel T, next to the current research): the national
   project's running stage pulls and counts down twice as fast (0.01 cr per missing item and second, 8 cr a second in
   the countdown); a research runs at twice the lab speed (0.1 cr per missing unit and second); the button shows the
   cost per minute; it stops when the stage or research is done or the treasury cannot pay (no rush into debt).
   *Hire garrison* (city panel): +4 garrison points for 160 cr, at most 32 per city, -1 point a minute; they man the
   city's hidden garrison turrets (one per 4 points, with the garrisoned units) and need no supply. *Mercenaries*
   (market panel, an own port selected): a small division by the port's region (e.g. highland 4 walkers + 2 heavies)
   for 600 cr, once per 10 minutes per nation, within the supply cap.
6. **City-states in the market panel.** The port drop-down lists every city-state after the nation's ports
   ("City-state Karsk (x1.30, relation +3)"). A city-state sells its region's goods (what lies in its network; it
   restocks a quarter of its starting goods every 5 minutes) at 1.3 x the market price, falling to 1.1 x at relation
   100, and buys any good at 0.7 x; bought goods arrive in the buyer's city nearest to it after 30 s, sold goods leave
   that city. Every 100 cr traded is +1 relation with that city-state; below -50 it refuses. Capturing a city-state while
   at peace with every nation costs -10 relation with every other nation (and -30 with the other city-states).
7. **Victory** drop-down (lobby): Conquest + Space (default), Conquest, Territory, Score, Any (all rules).

## 3. Design as built

### 3.1 Space Program (`scripts/age3.lua`)

`age3.project(force)`, `can_start` ("mode" | "age" | "research" | "running" | "complete"), `start(force, position?)`,
`stage_done(force, stage)`, `progress`, `missing(force)` (the running stage's missing goods: an AI's make targets),
`describe`. The flow copies the Railway Charter (`ages.lua`) with stages: every 60 ticks per participant force (order
of `match.forces()`), pull, countdown, next stage. Stage 1 calls `ages.set_age(force, 3)` (`ages.MAX_AGE` is 3 now)
and emits `rts_age_up`; stage 3 emits `rts_space_victory` {force, winners = force + allies}; `match.lua` ends the match
through `match.finish_by(winners, "space")` when `balance.nation.age3.modes[victory]`, else logs that the mode has no
Space victory. The Age III recipe set (`age3.AGE3_RECIPES`, every Age III recipe and building without a `tech`) is
switched on an `ages.on_age_changed` callback and off at match teardown; `research.AGE_LOCKS` shows "locked: Age III
(Space Program, stage 1)" in the HUD. Technology-gated recipes go through `research.LOCKS` / `research.EFFECTS[tech]
.unlock` (Chemistry, Nuclear power, and Geology for the rare extractor).

### 3.2 Automation kits and the nuclear plant (`scripts/age3.lua`, `prototypes/age3.lua`)

Every district (the ten Age II ones, the three Age III ones, the refinery and the chemical plant) has 3 module slots
for the categories `rts-labor` and `rts-automation`. The kit is a module without effects (category
`rts-automation`). The kit pass runs every 300 ticks per city (staggered by id like the staffing pass) and only for a
city with a policy or kits; it moves kits between the city's network and the module inventory and records
`storage.age3.kits[unit_number]`. `labor.job_factor(entity)` = 0.7^kits; `labor.step_city` multiplies the building's
jobs by it, so the staffing pass needs fewer workers for the same step. `labor.lua`'s `set_module` now clears only the
labor modules, so the kits survive every staffing change. The nuclear plant is the RTS steam plant's burner
generator at 5x5 with the vanilla reactor's picture, 40 MW, fuel category `nuclear`, registry kind `steam-plant`
(power figures, upkeep and labor work unchanged; the HUD page says "Fuel rods"). The fuel rod is `rts-fuel-rod`
(2.4 GJ).

### 3.3 Rare resources (`scripts/rare.lua`)

The rare extractor is a clone of the RTS extractor on the `rts-rare` category, `mining_speed` 0.2 (2 s deposits: one
item per 10 s), `uses_force_mining_productivity_bonus = false`, void energy, one labor slot (4 jobs, family
extraction), territory class `outpost`. It drops its item at its drop position; every 60 ticks `rare.lua` moves it into
the network the extractor stands in (or keeps up to 20 in a buffer). Every 60 ticks the capital's network (the capital
centre's) gives up every rare item: an arrival sets `last_tick`; a kind is active while `tick - last_tick <= 90 s`.
`rare.apply(force)` turns the active set into force modifiers as deltas against `storage.rare.applied[force]`
(`LuaRecipe.productivity_bonus` of every rts-* recipe and smelting recipe that makes one of the kind's items,
`mining_drill_productivity_bonus`, `laboratory_speed_modifier`, `laboratory_productivity_bonus`, the heavies' ammo
damage modifier for uranium rounds); gold is `treasury.tax_bonus(force)`. The teardown takes every delta back.
`rare.deposits(force)`, `rare.bonuses(force)`, `rare.describe`.

### 3.4 Sinks and city-state trade (`scripts/sinks.lua`)

`sinks.rush(force, "project" | tech)`, `cancel_rush`, `rush_state`, `rush_target`; `ages.rush_factor` and
`age3.rush_factor` return 2 while a project rush runs (one rush per nation; a project rush belongs to one stage).
`sinks.hire_garrison(force, city, points)` -> `garrison.add_hired` (hired points in the garrison record, turrets by
`floor((units' points + hired) / 4)`, `garrison.of(city).points` includes them, `offmap_supply` does not), decay every
600 ticks. `sinks.mercenaries(force, port_un)`: template by `world.region_at(port).kind`, `units.spawn` around the
port, `divisions.create` with stance hold, cooldown per nation. `market.trade_with_city_state(force, city, item, n,
buy)` is installed by this module (relations per city-state in `storage.sinks.cs`, because `diplomacy.adjust` only
knows the nations); `sinks.city_states(force)` feeds the market panel. The capture penalty listens to
`rts_city_captured` from `rts-neutral`.

### 3.5 Tax and deficit hysteresis (`scripts/market.lua`)

`balance.nation.market.ai.hysteresis = {enter = 1500, leave = 2100 (1.4 x), tax_hold = 10 min, happy_band = 12,
war_footing = 15 min}`. The deficit flag (tax and the export thresholds) sets below `enter` with a falling balance
and clears only at `leave`. The tax: low below happiness 40 until 52; high at war, on a war footing for 15 minutes
after the last war, or in deficit, and after either until the balance is back at `leave`; a war start and a happiness
drop switch at once, every other change waits 10 minutes. Without the war footing the first 60-minute run gave 14
switches (3.5 per nation-hour, every one around a war: an aggressive AI with four wars switched 7 times); with it 6,
and 4 on the final tree.

### 3.6 Treasury census in slices (`scripts/treasury.lua`, after m3-perf's numbers)

m3-perf measured the 600-tick census (every building and unit, 3-5 API calls each) at up to 8 ms in one tick on a
4-nation 2048 match (23.8 ms on a loaded machine). Buildings and units are now counted in 6 slices (unit_number % 6),
one every 100 ticks, into `storage.treasury_census.partial`; the last slice makes it the `done` census that the next
step uses (the counts are at most one step old; the first step of a match counts everything at once). Each building
record caches its upkeep class (none / loco / age1 / age2 and whether it is a crafting machine), so a slice calls
`valid`, `disabled_by_script` and, for crafters, `get_recipe` only. The spike per tick is a sixth of the old one; the
mean grows a little (0.0014 -> 0.0017 ms/tick on seed 701: six table walks instead of one). Rails, cities and the flows
stay in the step.

## 4. Deviations from the contract and decisions taken here

1. **Rush cost.** Contract: "crowns per missing item/second, 2x speed". Built: 0.01 cr per missing item and second
   while the stage pulls, plus 8 cr a second during the countdown, and the countdown also runs twice as fast (without
   that a rush was worth nothing when the goods were in stock; the first fixture run cost 32 cr for stage 2). A
   research rush is a lab-speed delta (+1) at 0.1 cr per missing research unit and second. Numbers are first guesses
   for the integration's balance pass.
2. **Rare extractor placement**: own or neutral land (outpost class), unlocked by Geology in any age; a deposit on a
   city-state's land needs the city-state taken first. The contract does not say where it may stand; rim deposits
   would otherwise need a city founded next to each.
3. **Bonus bookkeeping** lives in `rare.lua` (`storage.rare.applied`), the same delta pattern as `research.apply`; no
   `research.lua` hunk was needed (techs and unlocks are registered through its tables at load time).
4. **Age III technologies use industrial kits** (no modern kit: a new kit would change the lab, the AI's kit logic and
   every tech tier); Chemistry gates batteries and rocket fuel (stages 2 and 3), Nuclear power the plant, the fuel rods
   and uranium rounds.
5. **Nuclear plant** is one burner generator on a custom fuel rod (no reactor, heat pipes or turbines); fuel rods are
   made in the Chemistry district (4 uranium ore + 1 steel, 10 s).
6. **Uranium rounds** (D3) are a supply, not ammunition in the units: one magazine per heavy walker a minute from the
   capital's network keeps +30 % on the heavies' ammo category.
7. **City-state trade**: the goods arrive in (or leave) the buyer's city nearest to the city-state (the contract says
   "their City Center is a port"; a port's network would need a hauler to the city-state's own network). Selling to a
   city-state pays 0.7 x (not the ports' 0.9): it must not become an outlet outside the commerce cap. "Relation
   effects" = the markup (1.3 -> 1.1 with relation) and a refusal below -50. "Capturing a city-state at peace" is
   read as "while the captor is at peace with every nation" (an AI that takes one during a war loses nothing; seed
   701's capture was such a case).
8. **Tax hysteresis** adds `tax_hold` (10 min) and `war_footing` (15 min) to the contract's `enter`/`leave` band: the
   band alone did not get below 2 switches per nation-hour.
9. **Victory "Any"** includes Territory: one line in `wars.lua` (not in this package's shared-file list).
10. **Hire garrison** needs hired points in the garrison record: two hunks in `garrison.lua` (not in the list).
11. **GUI placement**: the automation policy sits in the ledger (it already has the city drop-down and the room; the
    city panel is full at 1280x800); the Rush button for research is on the research panel (`techgui.lua` hook, not
    in the list); Mercenaries is a row of its own in the market panel (the port row was full).
12. **Age III buildings** pay the Age II upkeep rate (4 cr a minute); the rare extractor and the nuclear plant too.

## 5. Files and shared hunks

New (owner): `scripts/age3.lua`, `scripts/rare.lua`, `scripts/sinks.lua`, `prototypes/age3.lua`,
`locale/en/age3.cfg`, `locale/ru/age3.cfg` (same 140 keys, same parameters), `tools/probes/age3_fixture.lua` (headless
fixture, 35 checks), `tools/probes/age3_saveload.lua` (save/load probe), `tools/probes/age3_gui.lua` (GUI probe with
screenshots, not run: section 7), `build/p5m3-age3/sync.sh`, `build/p5m3-age3/gui-copy.sh`, `build/p5m3-age3/loadcheck.sh`.

Shared hunks (marker `-- Phase 5 M3 age3`; line numbers in `mods/factorio-rts` after the sync onto d27417c; `sync.sh` writes them as patches against
9263e69 into `build/p5m3-age3/patches/` and applies them with `patch` to the files as they are then):

| File | Lines | Hunk |
|---|---|---|
| `balance.lua` | 692-694, 824-831, 931-1127 | victory modes `conquest_space` (default) and `any`; `market.ai.hysteresis`; `balance.nation.age3`, `.rare`, `.sinks`, jobs and families of the Age III buildings, `balance.buildings` entries, p0 of batteries and rocket fuel |
| `control.lua` | 82-87 (after m3-air's `scripts.air` / `airgui`) | `scripts.age3`, `scripts.rare`, `scripts.sinks` before `scripts.debug` |
| `data-updates.lua` | 19-22 | `require("prototypes.age3")` after the people prototypes |
| `scripts/ages.lua` | 47-48, 335-343, 359 | `MAX_AGE = 3`, `ages.rush_factor`; the Charter's pull and countdown use it |
| `scripts/labor.lua` | 67, 209-211, 280-281 | `labor.job_factor`; `set_module` clears only labor modules; jobs x job factor |
| `scripts/ledgergui.lua` | 30-32, 65-67, 198, 249, 341 | hooks: project text, project row, extra elements, their refresh |
| `scripts/hud.lua` | 303-305, 1597-1600, 2889 | Age III items in the age2 build tab (a third row); the nuclear plant's page text; `hud.P4` exported |
| `scripts/match.lua` | 190-191, 1127-1140 | accepted victory modes; the `rts_space_victory` handler |
| `scripts/wars.lua` | 727 | Territory also under Any |
| `scripts/lobby.lua` | 553 | `/rts-match ... conquest_space | any` |
| `scripts/treasury.lua` | 77, 157, 402-501, 547 | `treasury.tax_bonus` (gold); the census in slices (3.6) and its teardown |
| `scripts/market.lua` | 1070-1078, 1087-1124 | hysteresis of the deficit flag; the banded tax decision |
| `scripts/marketgui.lua` | 20-26, 179, 232-262, 268, 274-276, 292-301, 339-344, 371-374 | partners (city-states) in the port drop-down, their prices, Buy/Sell; the extend hooks |
| `scripts/garrison.lua` | 211-212, 238-241, 354-374 | hired points man the turrets; a disabled hidden turret keeps one magazine (the GUI run showed "no ammo" icons around the city); `garrison.of` reports hired points; `garrison.add_hired` |
| `scripts/citygui.lua` | 34, 211-213, 273-276, 344, 411 | foot and refresh hooks (Hire); jobs shown rounded and after the building's kits |
| `scripts/techgui.lua` | 14-16, 139, 190 | extend hooks (research Rush) |
| `locale/{en,ru}/diplomacy.cfg` | `lobby-victory-tooltip` | the two new modes |
| `locale/{en,ru}/world.cfg` | `entity-description.rts-rare`, `technology-description.rts-geology` | the rare extractor |
| `locale/{en,ru}/economy.cfg` | `rts.tech-tier-3` | "Ages II-III: industrial kits" (the column holds the Age III techs too) |

Every hunk is a hook or a table entry; the modules that use them (`age3`, `rare`, `sinks`) load after their owners.
`control.lua` and `data-updates.lua` get their require blocks by anchor (m3-air appends to the same lists):
`prototypes.age3` right after `prototypes.people`, so it stays before `prototypes.air`, which gives every building
defined before it its air masks; the three scripts before `scripts.debug`. `sync.sh` (dry run) reports every hunk
applies to `mods/` as of this writing (HEAD 497cb1c with m3-air's files), and the merged tree passes (section 6).

## 6. Tests

All runs on the work copy, Space Age on unless noted, 0 Lua errors in every run.

| Run | Command (abridged) | Result |
|---|---|---|
| Fixture (SA) | `KEEP_TREE=build/p5m3-age3/factorio-rts EXTRA_LUA=tools/probes/age3_fixture.lua STOP_ON=RTS_AGE3_DONE SPEED=4 tools/autotest-run.sh p5m3-age3-fx4 '{opponents = 1, difficulty = "normal", enemy_brain = "ai", mode = "nation"}' 900` | 35/35 (final tree) |
| Fixture (base game) | the same with `VARIANT=base` (`p5m3-age3-fxb`) | 35/35 |
| Fixture at speed 1, PERF=1 | `p5m3-age3-fxp` | see section 6.1 |
| Skirmish smoke | `tools/autotest-run.sh p5m3-age3-smoke2 '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240` | 65/65 |
| Skirmish AI, against HEAD | `SEED=4242 tools/autotest-run.sh p5m3-age3-sk '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' 700`, the same on `git archive 9263e69` | 23/23 both; every check line and all 32 minute reports identical |
| M1 acceptance | `PERF=1 EXTRA_LUA=tools/probes/m1_acceptance.lua DURATION_MIN=60 SEED=501 SPEED=6 ... '{opponents = 1, ..., mode = "nation", world_size = 2048}'` (`p5m3-age3-m1-501c`, final tree) | 53/53, both alive; Age II 16:59 / 17:40 (as M2's 16:59 / 17:40); speed-1 minutes 56-60: 60.0 60.0 60.0 60.0 60.1 s; one tax switch per nation |
| M2 end-to-end, 4 nations, 60 min | `PERF=1 EXTRA_LUA=tools/probes/m2_acceptance.lua DURATION_MIN=60 SEED=701 SPEED=8 ... '{opponents = 3, ..., world_size = 2048}'` (`p5m3-age3-m2-701c`, final tree) | trade, war, peace, capture, starving: 5/5 PASS; AI autotest 81/82 (`produce_rts-ai-3`, the known M1-era check, as in the M2 baseline); Age II 14:37 / 18:37 / 16:26 / 14:28 (identical to M2's); 3 wars, 2 peaces, 1 city-state captured (the run before the census change: 4, 3, 1); tax switches 4, deficit mode 4 (1.0 per nation-hour each); speed-1 minutes 56-60: 60.0 60.0 60.0 60.0 60.1 s |
| Save/load | `SAVE_MINUTE=3 EXTRA_LUA=tools/probes/age3_saveload.lua tools/saveload-check.sh p5m3-age3-sl2 '{opponents = 1, ..., mode = "nation"}' 200` (saved with a running, rushed program, gold flowing, hired points and a city-state delivery in transit) | 0 errors in both halves; after the load 4/4 (Age III, label, gold, hired points and their turret, the delivery) |
| Merged tree | `mods/factorio-rts` as of 497cb1c plus m3-air's synced files, with this package applied by `SYNC_DST=build/p5m3-age3-merged/factorio-rts build/p5m3-age3/sync.sh --apply`: fixture (`p5m3-age3-fxm`) and smoke (`p5m3-age3-smokem`) | 35/35, 65/65 |
| Data stage | `build/p5m3-age3/loadcheck.sh` (SA and base) | loads |
| Locale | static check: every key the package uses exists in en and ru, same key set, same parameters | OK |

### 6.1 Cost (PERF=1, ms per tick averaged over a minute)

| Run | age3 | rare | sinks | together |
|---|---|---|---|---|
| 1v1 (seed 501, minutes 56-60, no Age III activity) | 0.0004 | 0.0007 | 0.0001 | 0.0011 |
| 4 nations (seed 701, minutes 56-60) | 0.0005 | 0.0011 | 0.0001 | 0.0017 (treasury itself 0.0017, sliced) |
| Fixture at speed 1, 8 minutes (program, kits, extractor, rare flow, nuclear plant, rushes), mean | 0.0006 | 0.0006 | 0.0002 | 0.0014 |
| the same, worst minute per module | 0.0010 | 0.0008 | 0.0009 | 0.0025 |

### 6.2 GUI run (1280x800, English and Russian clients)

`build/p5m3-age3/gui-copy.sh && RTS_LOCALE=<en|ru> tools/gui-run.sh build/p5m3-age3-gui 300 RTS_AGE3_GUI_DONE ...`:
every check passes in both languages (Start places the complex, the automation button automates with 2 kits, Rush
rushes, Hire hires 4 points, the drop-down lists the port and 4 city-states and a Buy click raises the relation, the
Mercenaries button hires a division, the research panel's Rush rushes), 0 errors. Screenshots
`build/shots-p5m3-age3-gui-{en,ru}/`: ledger before the start, ledger in Age III, ledger while rushing, city panel
with Hire, market on a city-state and on the own port, research panel with Rush, the Launch complex, the build tab
with its third row, an overview. Everything fits at 1280x800 in Russian (the automation row and the Rush button
included). Fixed after the first look: the "no ammo" icons over a city's unused hidden garrison turrets, city-state
names cut off in the port drop-down (the drop-down now says "<name> (x1.30, +0)" and the line under it has the rest),
mercenary texts that said "port Port ...", fractional jobs in the city panel, the research column title.

### 6.3 After the sync (mods/factorio-rts = d27417c + this package, not committed)

`build/p5m3-age3/sync.sh --apply` on the clean d27417c tree: every hunk applied, the require blocks went in by anchor
(`prototypes.age3` before m3-air's `prototypes.air`, the three scripts after `scripts.airgui`). On `mods/`: smoke
65/65, age3 fixture 35/35, m3-air's `tools/probes/air_autotest.lua` 14/14 (SEED=501, SPEED=4), 0 Lua errors.

## 7. Open issues

1. **The AI does not use any of this yet** (wave B, `m3-ai`): it researches Electrification late in its tree order
   and never starts the Space Program, automates, builds rare extractors, rushes, hires or trades with city-states.
   Hooks for it: `age3.can_start/start`, `age3.missing(force)` (make targets of the running stage), `age3.automate`,
   `rare.deposits(force)`, `sinks.rush/hire_garrison/mercenaries`, `market.trade_with_city_state`. The contract's
   "normal AI reaches Age III by 40:00 in 3 of 5 seeds" is open until then; so is "money is tight", which needs the AI
   to spend.
2. **GUI**: seen by the probe (6.2), not yet by the Codex protocol (the M3 protocol is `m3-integ`'s). Hover tooltips
   and the rare extractor's building page were not shot.
3. **Balance numbers are first guesses**: stage lists, rush rates, hire and mercenary prices, the city-state markup,
   the Age III recipe ratios (district efficiency was not re-measured with `economy_e1`'s floor for the Age III goods).
4. **The tax metric is one seed** (701, twice). Wars drive almost every switch; a nation with many short wars can still
   switch 3 times an hour.
5. **Rare deposits on city-state land** (60 % of them) stay out of reach until the city-state is taken, which makes
   city-states targets: with the -10 capture penalty in peacetime this pulls in two directions; worth watching in the
   AI runs.
6. **Research rush with no working lab** still costs (0.1 cr per missing unit and second) and does nothing; the button
   shows the cost per minute.
