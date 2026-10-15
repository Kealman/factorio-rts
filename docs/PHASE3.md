# Phase 3 — AI opponent and match flow

Goal: a losable 1v1 (and 1vN) against scripted commanders that build real bases with the Phase 2 economy, defend, expand and attack. Plus full match flow: start screen, spawn points, fog of war, victory/defeat, restart.

Built on `PHASE2.md` (buildings, production pull, CC composite) and spike #5 (`build_blueprint{force}` + paced revive, calibrated templates, `clone_area` for identical starts).

## AI architecture (`scripts/ai/`)

- `ai/commander.lua`: one commander per AI force, state in `storage.ai[force_name]`, ticks every 60 ticks. Sub-systems run in order: economy → construction → production → army → scouting.
- `ai/build_order.lua`: data-driven build order (Lua table): a list of steps `{kind="building", name="rts-extractor", anchor="iron", slot=1, when={plates>=20}}`, `{kind="recipe", building="rts-barracks", recipe="rts-walker-kit"}`, `{kind="army", min_units=8, action="attack"}`. Steps are evaluated in order; the first unsatisfied, affordable step is executed. Difficulty = different build orders + resource multipliers.
- `ai/layout.lua`: base layout templates per anchor (CC, iron patch, copper patch, stone patch): calibrated blueprint strings from the Phase 2 enemy base template (extractors on ore → belts → smelters → inserters → stockpile), plus free-slot placement using `surface.can_place_entity` on a spiral around the CC for barracks/factory/solar/turrets.
- `ai/construction.lua`: the AI does not use bots. It places ghosts via `build_blueprint{force}` / `create_entity{name="entity-ghost"}` and revives them at a fixed rate (1 ghost per 2 s per CC) **only if the items exist in its logistic network** (removed on revive). This mirrors the player's cost without bot pathing. Trees in the way are destroyed first.
- `ai/army.lua`: rally idle units at a defensive point between CC and the enemy; groups of ≥ N attack-move at the nearest known enemy building (priority: barracks/factory > extractors > CC); retreat when group HP < 40 %; defend when own buildings are damaged (`on_entity_damaged` filtered to own force → send the nearest group). Uses `orders.lua` functions with a fake player index per AI force so behaviour matches the player's units.
- `ai/scout.lua`: chart the map progressively (`force.chart`) and remember enemy building positions from `find_entities_filtered` within charted chunks; AI vision is honest (only what its units/radar see) at normal difficulty, full map at hard.

## Match flow (`scripts/match.lua` rewrite)

- Match config in `storage.match.config`: number of AI opponents (1–3), difficulty, map size (small 256², medium 384²), starting resources.
- Map: a dedicated surface `rts-arena` created per match (`game.create_surface` with map gen: no enemy bases, no cliffs, low water, resources off) — the match script places ore patches itself (one iron/copper/stone/coal cluster per spawn + contested patches in the middle). Spawn points on a circle; the player's camera starts at their CC.
- Start: a simple GUI dialog (opponents, difficulty) on first join; "Start match" builds the arena and CCs (`clone_area` of a template built once on a scratch surface) and starts the clock. `/rts-restart` and a HUD button restart.
- Fog of war: per force `chart` only around own buildings/units (`radar_range` on units; CC has a small radar); `share_chart` off; allied AIs (team mode) share.
- Win/lose: a force is out when it has no CC and no barracks/factory; victory when all enemies are out; show a results frame (time, units built/lost) with Restart.
- Biters: keep off the arena surface (no enemy bases, `peaceful_mode` as safety).

## Difficulty

| Level | Build order | Cheats |
|---|---|---|
| Easy | slow economy, attacks every 4 min with ≥ 6 units | none, full-map vision off |
| Normal | standard build order, expands to a second patch, attacks at 10 units | none |
| Hard | fast build order, ×1.5 starting stock, production speed ×1.25 | full-map vision |

## Acceptance

1. New game → dialog → Start: arena with the player's base and N AI bases, fog of war hides enemies.
2. AI builds extractors/smelters/barracks within 3 minutes, produces walkers continuously, sends waves, defends its base.
3. Destroying an AI's CC + production = that AI is out; losing all of ours = defeat screen; Restart works without reloading.
4. Headless autotest: two AI commanders fight each other for 8 minutes with zero errors; one wins or both still produce.
5. 60 UPS with 3 AI bases and 300 units.
