-- Developer tools: /rts-* console commands, the headless autotest and the GUI self-test steps for
-- selection and orders.
-- Owns storage.debug = {autotest = nil|true|false, stage, started, stage_tick, units = {[unit_number] = true},
--                       dests, hold_pos, moved, attacked, checks = {pass, fail}, next_report, dummy, eco, ...}
--
-- Autotest: decided once at tick 120. With no connected players (tools/headless-run.sh) it runs two parts:
-- * Economy (Phase 2, storage.debug.eco): checks the match-start bases, the CC death cleanup, then clones the
--   starter template for the player (/rts-build-template), adds stock (/rts-give), two factories and a turret,
--   sets a rally point (/rts-rally) and watches for ECO_WINDOW ticks: kits produced, walkers spawned and at the
--   rally, a factory item in the network, turret ammo, a non-zero economy snapshot, enemy production.
-- * Selection and orders (Phase 1): drives selection.lua and orders.lua through the fake player index 0
--   (AUTOTEST_PLAYER), exactly as the input handlers do: selection set/add/click/groups/select-all/clear, then
--   move -> hold -> stop -> right-click dedupe and attack-move arming -> attack a lone enemy -> attack-move into
--   the enemy army -> /rts-qa-reset. The first enemy wave is postponed until that part is done.
-- Every expectation is logged as "[rts] autotest check <name>: PASS|FAIL ..."; when both parts are done the
-- last line is "[rts] autotest summary <passed>/<total>".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local match = require("scripts.match")
local camera = require("scripts.camera")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local cursor = require("scripts.cursor")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local economy = require("scripts.economy")
local basetemplate = require("scripts.basetemplate")

local debug_tools = {}

local PLAYER, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
local AUTOTEST_DECIDE_TICK = 120
local AUTOTEST_PLAYER = 0          -- fake player index: selection/orders treat it as an rts-player commander
local AUTOTEST_WALKERS = 5
local AUTOTEST_HEAVIES = 1
local MOVE_DEST = {x = -25, y = 0}
local DUMMY_POS = {x = -25, y = 28} -- lone enemy walker for the attack stage
local ATTACK_MOVE_DEST = {x = 50, y = 0}
local STAGE_TIMEOUT = 20 * 60
local ENGAGE_GRACE = 8 * 60         -- attack stage: ticks after the first hit before the script kills the target
local HOLD_TICKS = 3 * 60
local AUTOTEST_REPORT_PERIOD = 10 * 60
-- /rts-qa-reset check: once the last autotest stage runs, after the match ends or this long after the start.
local QA_RESET_CHECK_AFTER = 65 * 60
local ARMY_SIZE = match.ARMY_SIZE -- units per side after match.spawn_armies()
local AUTOTEST_WAVE_TIMING = "45 90"  -- /rts-wave-timing for the headless run (the 3 min default is too slow)

-- Economy autotest. Offsets are from the player's CC centre, with x towards the arena centre.
local ECO_WINDOW = 150 * 60          -- ticks the economy checks may take
local ECO_REPORT_PERIOD = 30 * 60
local ECO_SNAPSHOT_AFTER = 15 * 60   -- machines have run for a while before the snapshot is judged
local ECO_RALLY_OFFSET = {20, 10}
local ECO_RALLY_RADIUS = 6           -- a spawned walker within this many tiles of the rally counts as arrived
local ECO_FACTORIES = {{offset = {9.5, -9.5}, recipe = "rts-extractor", item = "rts-extractor"},
                       {offset = {9.5, -13.5}, recipe = "rts-ammo", item = "firearm-magazine"}}
local ECO_TURRET_OFFSET = {10, 9}
local ECO_GIVE = {"iron-plate 400", "copper-plate 100"}
local ECO_DEATH_TEST_POS = {x = 0, y = 60} -- throwaway CC composite for the death-cleanup check
local ECO_BROWNOUT_AT = 20 * 60     -- the core power is switched off for ECO_BROWNOUT_TICKS at this age
local ECO_BROWNOUT_TICKS = 180
local ECO_POOL_FROM = 75 * 60        -- second half of the window: barracks and factories must both progress
local ECO_KEYS = {"eco_kits_produced", "eco_walkers_spawned", "eco_walker_at_rally", "eco_factory_item_in_network",
                  "eco_turret_ammo", "eco_snapshot", "eco_player_smelting", "eco_enemy_production"}

function debug_tools.init()
  storage.debug = storage.debug or {}
end

---------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------
local function force_summary(force_name)
  local kinds, ords, n = {}, {}, 0
  for _, rec in units.for_force(force_name) do
    n = n + 1
    kinds[rec.kind] = (kinds[rec.kind] or 0) + 1
    ords[rec.order] = (ords[rec.order] or 0) + 1
  end
  local function fmt(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, " ")
  end
  return string.format("%s: %d units [%s] orders [%s]", force_name, n, fmt(kinds), fmt(ords))
end

local function fmt_counts(t)
  local parts = {}
  for k, v in pairs(t or {}) do parts[#parts + 1] = k .. "=" .. v end
  table.sort(parts)
  return table.concat(parts, " ")
end

local function stats_line()
  local st = orders.stats()
  return string.format("orders issued [%s] completed [%s] retargets=%d resumed=%d swept=%d released=%d "
    .. "fallbacks=%d area_orders=%d", fmt_counts(st.issued), fmt_counts(st.completed), st.retargets,
    st.resumed or 0, st.swept or 0, st.released, st.fallbacks, st.area_orders)
end

--- Lines describing the current state (used by /rts-dump and the autotest).
function debug_tools.dump_lines()
  local m = storage.match or {}
  local lines = {
    string.format("tick %d, match phase=%s wave=%s next wave in %ss winner=%s (wave timing first %ss, period %ss)",
      game.tick, tostring(m.phase), tostring(m.wave),
      m.enemy_next_wave and string.format("%.0f", (m.enemy_next_wave - game.tick) / 60) or "-", tostring(m.winner),
      m.config and tostring(m.config.first_wave_ticks / 60) or "-",
      m.config and tostring(m.config.wave_period_ticks / 60) or "-"),
    force_summary(PLAYER),
    force_summary(ENEMY),
    string.format("registry size=%d, enemy group=%s", table_size(storage.units or {}),
      (m.enemy_group and m.enemy_group.valid) and ("#" .. m.enemy_group.unique_id) or "none"),
    stats_line(),
  }
  for index, p in pairs(storage.players or {}) do
    local player = selection.real_player(index)
    lines[#lines + 1] = string.format("player %d (%s): desired=%s controller=%s setup_done=%s connected=%s "
      .. "selected=%d boxes=%d armed=%s", index, player and player.name or "fake", tostring(p.desired_controller),
      player and util.define_name(defines.controllers, player.controller_type) or "-",
      tostring(p.setup_done), tostring(player and player.connected), selection.count(index),
      selection.box_count(index), tostring(orders.is_armed(index)))
  end
  for _, force_name in pairs({PLAYER, ENEMY}) do
    lines[#lines + 1] = economy.describe(force_name)
    local st = production.stats(force_name)
    lines[#lines + 1] = string.format("%s production: kits=%d walkers=%d (heavy %d) factory crafts=%d items to "
      .. "network=%d magazines fed=%d | buildings cc=%d barracks=%d factory=%d turret=%d", force_name, st.kits,
      st.walkers, st.heavies, st.buildings, st.items, st.magazines, buildings.count(force_name, "cc"),
      buildings.count(force_name, "barracks"), buildings.count(force_name, "factory"),
      buildings.count(force_name, "turret"))
  end
  local d = storage.debug or {}
  lines[#lines + 1] = string.format("autotest=%s stage=%s", tostring(d.autotest), tostring(d.stage))
  return lines
end

local function reply(cmd, line)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player then player.print(line) else game.print(line) end
  util.log("%s", line)
end

---------------------------------------------------------------------------
-- Autotest
---------------------------------------------------------------------------
local function check(name, ok, fmt, ...)
  local d = storage.debug
  local detail = fmt and string.format(fmt, ...) or ""
  if ok then d.checks.pass = d.checks.pass + 1 else d.checks.fail = d.checks.fail + 1 end
  util.log("autotest check %s: %s %s", name, ok and "PASS" or "FAIL", detail)
  return ok
end

-- Records of the autotest units that are still alive.
local function test_recs()
  local out = {}
  for un in pairs(storage.debug.units) do
    local rec = units.get(un)
    if rec then out[#out + 1] = rec end
  end
  return out
end

local function test_entities()
  local out = {}
  for _, rec in pairs(test_recs()) do out[#out + 1] = rec.entity end
  return out
end

-- True if every live autotest unit has this order (and, for orders.lua claims, issuer "orders").
local function all_have_order(order)
  local recs = test_recs()
  if #recs == 0 then return false, "no units left" end
  local bad = {}
  for _, rec in pairs(recs) do
    local want_issuer = order ~= units.IDLE and orders.ISSUER or nil
    if rec.order ~= order or rec.issuer ~= want_issuer then
      bad[#bad + 1] = string.format("#%d=%s/%s", rec.entity.unit_number, tostring(rec.order), tostring(rec.issuer))
    end
  end
  return #bad == 0, (#bad == 0) and string.format("%d units", #recs) or table.concat(bad, ",")
end

local function command_name(rec)
  local c = rec.entity.commandable
  local cmd = c and c.command
  return cmd and util.define_name(defines.command, cmd.type) or "none"
end

local function autotest_report()
  local d = storage.debug
  local alive = #test_recs()
  util.log("autotest t=%.0fs player=%d (walker %d, heavy %d) enemy=%d (walker %d, heavy %d) "
    .. "autotest_alive=%d selected=%d boxes=%d stage=%s wave=%d match=%s checks pass=%d fail=%d",
    (game.tick - d.started) / 60, units.count(PLAYER), units.count(PLAYER, "walker"), units.count(PLAYER, "heavy"),
    units.count(ENEMY), units.count(ENEMY, "walker"), units.count(ENEMY, "heavy"), alive,
    selection.count(AUTOTEST_PLAYER), selection.box_count(AUTOTEST_PLAYER), d.stage, storage.match.wave or 0,
    tostring(storage.match.phase), d.checks.pass, d.checks.fail)
  local ords, cmds = {}, {}
  for _, rec in pairs(test_recs()) do
    ords[rec.order] = (ords[rec.order] or 0) + 1
    cmds[command_name(rec)] = (cmds[command_name(rec)] or 0) + 1
  end
  util.log("autotest %s; autotest units: orders [%s] commands [%s]", stats_line(), fmt_counts(ords), fmt_counts(cmds))
  return alive
end

local function set_stage(stage)
  local d = storage.debug
  d.stage = stage
  d.stage_tick = game.tick
  util.log("autotest: stage %s at tick %d", stage, game.tick)
end

local function zero_area(pos)
  return {left_top = {x = pos.x, y = pos.y}, right_bottom = {x = pos.x, y = pos.y}}
end

-- Stage 1: selection API, then the move order.
local function selection_checks(picked, enemy)
  local P = AUTOTEST_PLAYER
  local list = {}
  for i, e in ipairs(picked) do list[i] = e end
  list[#list + 1] = enemy -- an enemy unit in the area must be ignored
  local n = selection.set(P, list)
  check("set_ignores_enemy", n == #picked, "selected=%d expected=%d", n, #picked)
  local by_kind, total = selection.count_by_kind(P)
  check("count_by_kind", total == #picked and by_kind.walker == AUTOTEST_WALKERS and by_kind.heavy == AUTOTEST_HEAVIES,
    "total=%d [%s]", total, fmt_counts(by_kind))
  check("boxes_drawn", selection.box_count(P) == #picked, "boxes=%d", selection.box_count(P))
  for _, e in ipairs({picked[1], picked[#picked]}) do
    local lt, rb = selection.box_offsets(e)
    local sb = e.selection_box
    util.log("autotest: %s box offsets (%.2f,%.2f)-(%.2f,%.2f); entity.selection_box rel to position "
      .. "(%.2f,%.2f)-(%.2f,%.2f); formation spacing alone=%.2f", e.name, lt[1], lt[2], rb[1], rb[2],
      sb.left_top.x - e.position.x, sb.left_top.y - e.position.y, sb.right_bottom.x - e.position.x,
      sb.right_bottom.y - e.position.y, orders.spacing({units.get(e.unit_number)}))
  end

  check("group_set", selection.group_set(P, 1) == #picked, "group 1 = %d", selection.group_count(P, 1))
  local all = selection.select_all(P)
  check("select_all", all == units.count(PLAYER) and selection.box_count(P) == all, "selected=%d own=%d boxes=%d",
    all, units.count(PLAYER), selection.box_count(P))
  local recalled = selection.group_recall(P, 1)
  check("group_recall", recalled == #picked and selection.box_count(P) == #picked, "selected=%d boxes=%d",
    recalled, selection.box_count(P))
  check("empty_group_keeps_selection", selection.group_recall(P, 2) == 0 and selection.count(P) == #picked,
    "selected=%d", selection.count(P))

  local first = picked[1]
  local clicked = selection.handle_area(P, {first, picked[2], enemy}, zero_area(first.position), false)
  check("click_selects_one", clicked == 1 and selection.is_selected(P, first.unit_number) and selection.box_count(P) == 1,
    "selected=%d boxes=%d", clicked, selection.box_count(P))
  local drag = {left_top = {x = -100, y = -100}, right_bottom = {x = 100, y = 100}}
  local added = selection.handle_area(P, picked, drag, true)
  check("shift_drag_adds", added == #picked, "selected=%d", added)
  selection.clear(P)
  check("clear", selection.count(P) == 0 and selection.box_count(P) == 0, "selected=%d boxes=%d",
    selection.count(P), selection.box_count(P))
  selection.set(P, picked)
end

---------------------------------------------------------------------------
-- Economy autotest (Phase 2)
---------------------------------------------------------------------------
local function rel(offset)
  local home = match.home(PLAYER)
  local f = match.FACING[PLAYER] or 1
  return {x = home.x + f * offset[1], y = home.y + offset[2]}
end

local function fresh_snapshot(force_name)
  storage.economy.cache[force_name] = nil
  return economy.snapshot(force_name)
end

local function count_resource(name, center, radius)
  return util.surface().count_entities_filtered({name = name, position = center, radius = radius})
end

local function kinds_line(force_name)
  local parts = {}
  for _, kind in ipairs({"cc", "barracks", "factory", "turret", "extractor", "smelter", "solar", "stockpile"}) do
    parts[#parts + 1] = kind .. "=" .. buildings.count(force_name, kind)
  end
  return table.concat(parts, " ")
end

-- The match-start state: player CC composite with the starting stock, ore, the enemy template base.
local function eco_start_state()
  local cc = buildings.main_cc(PLAYER)
  local parts = cc and buildings.core_parts(cc) or {}
  check("eco_cc_composite", cc ~= nil and parts.power ~= nil and parts.power.valid and parts.pole ~= nil
    and parts.pole.valid and buildings.count(PLAYER, "stockpile") == #buildings.CC_STOCKPILES,
    "cc=%s core power=%s core pole=%s stockpiles=%d", cc and ("#" .. cc.entity.unit_number) or "none",
    tostring(parts.power ~= nil), tostring(parts.pole ~= nil), buildings.count(PLAYER, "stockpile"))
  local snap = fresh_snapshot(PLAYER)
  local want, bad = {}, {}
  for _, entry in ipairs(match.STARTING_STOCK) do
    want[#want + 1] = string.format("%s=%d/%d", entry[1], snap.items[entry[1]] or 0, entry[2])
    if (snap.items[entry[1]] or 0) ~= entry[2] then bad[#bad + 1] = entry[1] end
  end
  check("eco_starting_stock", #bad == 0, "network has %s", table.concat(want, " "))
  check("eco_bots", snap.construction_total == buildings.CC_BOTS["construction-robot"]
    and snap.logistic_total == buildings.CC_BOTS["logistic-robot"], "construction=%d logistic=%d idle=%d",
    snap.construction_total, snap.logistic_total, snap.bots_idle)
  local e = cc and cc.entity
  check("eco_cc_buffer_precharged", e ~= nil and e.energy >= 0.9 * e.electric_buffer_size,
    "CC energy %.1f / %.1f MJ at tick %d", e and e.energy / 1e6 or -1, e and e.electric_buffer_size / 1e6 or -1,
    game.tick)
  local home, f = match.home(PLAYER), match.FACING[PLAYER]
  local ore = {}
  local ore_ok = true
  for _, p in ipairs(match.ORE_PATCHES) do
    local n = count_resource(p[1], {x = home.x + f * p[2], y = home.y + p[3]}, math.max(p[4], p[5]) / 2 + 1)
    ore[#ore + 1] = string.format("%s=%d", p[1], n)
    if n < p[4] * p[5] * 0.6 then ore_ok = false end
  end
  check("eco_ore_patches", ore_ok, "%s", table.concat(ore, " "))
  local ek = {cc = 1, barracks = 1, extractor = 3, smelter = 4, solar = 2, stockpile = 8}
  local ok = true
  for kind, n in pairs(ek) do
    if buildings.count(ENEMY, kind) ~= n then ok = false end
  end
  check("eco_enemy_template", ok, "%s", kinds_line(ENEMY))
  local recipes = {}
  for _, rec in buildings.for_force(ENEMY, "barracks") do
    local r = rec.entity.get_recipe()
    recipes[#recipes + 1] = r and r.name or "none"
  end
  check("eco_enemy_barracks_recipe", #recipes > 0 and recipes[1] == match.ENEMY_BARRACKS_RECIPE, "recipes [%s]",
    table.concat(recipes, ","))
end

-- A throwaway CC composite dies: its hidden core parts must go with it and the registry must drop it.
local function eco_death_test()
  local surface = util.surface()
  local cc, parts = buildings.place_cc(surface, ECO_DEATH_TEST_POS, PLAYER)
  if not cc then
    check("eco_cc_death_cleanup", false, "could not place the test CC at %s", util.pos_str(ECO_DEATH_TEST_POS))
    return
  end
  local un = cc.unit_number
  local registered = buildings.get(un) ~= nil
  cc.die()
  check("eco_cc_death_cleanup", registered and storage.buildings[un] == nil and not parts.power.valid
    and not parts.pole.valid, "registered=%s, after die(): in registry=%s core power valid=%s core pole valid=%s",
    tostring(registered), tostring(storage.buildings[un] ~= nil), tostring(parts.power.valid),
    tostring(parts.pole.valid))
  for _, s in ipairs(parts.stockpiles) do
    if s.valid then s.destroy() end
  end
end

local function eco_place(name, offset)
  local surface = util.surface()
  local pos = rel(offset)
  return surface.create_entity({name = name, position = pos, force = PLAYER, raise_built = true})
end

-- Template for the player, stock, factories, turret, rally.
local function eco_setup()
  local e = storage.debug.eco
  debug_tools.run_command("rts-build-template", "")
  local ok = buildings.count(PLAYER, "cc") == 1 and buildings.count(PLAYER, "barracks") == 1
    and buildings.count(PLAYER, "extractor") == 3 and buildings.count(PLAYER, "smelter") == 4
    and buildings.count(PLAYER, "solar") == 2
  check("eco_player_template", ok, "%s", kinds_line(PLAYER))
  local before = fresh_snapshot(PLAYER)
  for _, arg in ipairs(ECO_GIVE) do debug_tools.run_command("rts-give", arg) end
  local after = fresh_snapshot(PLAYER)
  check("eco_give", after.iron - before.iron == 400 and after.copper - before.copper == 100,
    "iron %d -> %d, copper %d -> %d", before.iron, after.iron, before.copper, after.copper)

  e.factories = {}
  for i, spec in ipairs(ECO_FACTORIES) do
    local f = eco_place("rts-factory", spec.offset)
    if f then
      e.factories[i] = f
      if i == 1 then
        check("eco_wrong_category_rejected", production.set_recipe(f, "rts-walker-kit") == false
          and f.get_recipe() == nil, "factory recipe after set_recipe(rts-walker-kit): %s",
          f.get_recipe() and f.get_recipe().name or "none")
      end
      production.set_recipe(f, spec.recipe)
    end
  end
  e.turret = eco_place("rts-turret", ECO_TURRET_OFFSET)
  local reg = 0
  for _, f in pairs(e.factories) do if buildings.get(f.unit_number) then reg = reg + 1 end end
  if e.turret and buildings.get(e.turret.unit_number) then reg = reg + 1 end
  check("eco_registered_by_event", reg == #ECO_FACTORIES + 1, "%d of %d script_raised_built buildings registered",
    reg, #ECO_FACTORIES + 1)

  e.rally = rel(ECO_RALLY_OFFSET)
  debug_tools.run_command("rts-rally", string.format("%.1f %.1f", e.rally.x, e.rally.y))
  local set, total = 0, 0
  for _, rec in buildings.for_force(PLAYER, "barracks") do
    total = total + 1
    if rec.rally and util.distance(rec.rally, e.rally) < 0.01 then set = set + 1 end
  end
  check("eco_rally_set", total > 0 and set == total, "%d of %d barracks rally at %s", set, total,
    util.pos_str(e.rally))
end

local function eco_start()
  local d = storage.debug
  d.eco = {started = game.tick, passed = {}, spawned = {}, next_report = game.tick}
  util.log("autotest eco: started at tick %d", game.tick)
  eco_start_state()
  eco_death_test()
  eco_setup()
end

local function pass_once(key, ok, fmt, ...)
  local e = storage.debug.eco
  if e.passed[key] or not ok then return end
  e.passed[key] = game.tick
  check(key, true, "after %.1fs: " .. fmt, (game.tick - e.started) / 60, ...)
end

local function per_min(n, ticks)
  return ticks > 0 and n * 3600 / ticks or 0
end

local function eco_report(final)
  local e = storage.debug.eco
  local age = game.tick - e.started
  e.last = e.last or {}
  for _, force_name in pairs({PLAYER, ENEMY}) do
    local st = production.stats(force_name)
    local last = e.last[force_name] or {kits = st.kits, crafts = st.buildings, tick = e.started}
    local dt = game.tick - last.tick
    util.log("autotest eco t=%.0fs %s: kits=%d (+%d = %.1f/min) walkers=%d factory crafts=%d (+%d) "
      .. "items->network=%d magazines fed=%d%s | %s", age / 60, force_name, st.kits, st.kits - last.kits,
      per_min(st.kits - last.kits, dt), st.walkers, st.buildings, st.buildings - last.crafts, st.items, st.magazines,
      st.first_kit_tick and string.format(" first kit at tick %d", st.first_kit_tick) or "", kinds_line(force_name))
    e.last[force_name] = {kits = st.kits, crafts = st.buildings, tick = game.tick}
    util.log("autotest eco t=%.0fs %s", age / 60, economy.describe(force_name))
  end
  for _, line in ipairs(economy.power_lines(PLAYER)) do util.log("autotest eco power %s", line) end
  if final then
    local p, en = production.stats(PLAYER), production.stats(ENEMY)
    util.log("autotest eco timing: player kits %d in %.0fs = %.1f/min (first kit %.1fs after the template), "
      .. "enemy kits %d in %.0fs since tick 0 = %.1f/min (first kit at %.1fs)", p.kits, age / 60,
      per_min(p.kits, age), p.first_kit_tick and (p.first_kit_tick - e.started) / 60 or -1, en.kits,
      game.tick / 60, per_min(en.kits, game.tick), en.first_kit_tick and en.first_kit_tick / 60 or -1)
  end
end

-- Brownout: switch the player's core power off (solar only) and back on; the snapshot must see both.
local function eco_brownout(tick, age)
  local e = storage.debug.eco
  local b = e.brownout
  if not b and age >= ECO_BROWNOUT_AT then
    local cc = buildings.main_cc(PLAYER)
    local power = cc and buildings.core_parts(cc).power
    if not (power and power.valid) then
      check("eco_brownout", false, "no core power to switch off")
      e.brownout = {done = true}
      return
    end
    e.brownout = {power = power, orig = power.power_production, tick = tick}
    power.power_production = 0
    power.energy = 0 -- its 4 MJ buffer would otherwise cover the deficit for a few seconds
    util.log("autotest eco: brownout: core power switched off at tick %d (%s)", tick, economy.describe(PLAYER))
  elseif b and not b.done and not b.measured and tick - b.tick >= ECO_BROWNOUT_TICKS - 60 then
    b.measured = true
    local s = fresh_snapshot(PLAYER)
    check("eco_brownout", s.power_satisfaction < 0.9 and s.power_demand > 0, "solar only: %s",
      economy.describe(PLAYER))
    if b.power.valid then b.power.power_production = b.orig end
    b.restored = tick
  elseif b and b.restored and not b.done and tick - b.restored >= 120 then
    b.done = true
    local s = fresh_snapshot(PLAYER)
    check("eco_power_restored", s.power_satisfaction >= 0.95, "core back on: %s", economy.describe(PLAYER))
  end
end

local function eco_tick(tick)
  local e = storage.debug.eco
  if not e or e.done then return end
  local age = tick - e.started
  eco_brownout(tick, age)
  if age >= ECO_POOL_FROM and not e.pool_mark then
    local st = production.stats(PLAYER)
    e.pool_mark = {kits = st.kits, crafts = st.buildings, tick = tick}
  end
  local st = production.stats(PLAYER)
  pass_once("eco_kits_produced", st.kits > 0, "%d kits", st.kits)
  pass_once("eco_walkers_spawned", st.walkers > 0, "%d walkers", st.walkers)
  if not e.passed.eco_walker_at_rally then
    for un in pairs(e.spawned) do
      local rec = units.get(un)
      if rec then
        local dist = util.distance(rec.entity, e.rally)
        pass_once("eco_walker_at_rally", dist <= ECO_RALLY_RADIUS, "walker #%d is %.1f tiles from the rally %s",
          un, dist, util.pos_str(e.rally))
      else
        e.spawned[un] = nil
      end
    end
  end
  local net = economy.network(PLAYER)
  local in_net = net and net.get_item_count(ECO_FACTORIES[1].item) or 0
  pass_once("eco_factory_item_in_network", st.items > 0 and in_net > 0, "%d %s in the network, %d items handed off",
    in_net, ECO_FACTORIES[1].item, st.items)
  local turret = e.turret
  local ammo = turret and turret.valid and turret.get_inventory(defines.inventory.turret_ammo).get_item_count() or 0
  pass_once("eco_turret_ammo", ammo > 0, "turret holds %d magazines", ammo)
  if age >= ECO_SNAPSHOT_AFTER then
    local s = economy.snapshot(PLAYER)
    pass_once("eco_snapshot", s.iron > 0 and s.bots_total > 0 and s.power_capacity > 0 and s.power_demand > 0
      and s.power_satisfaction > 0, "%s", economy.describe(PLAYER))
  end
  local plates = game.forces[PLAYER].get_item_production_statistics(util.surface()).get_input_count("iron-plate")
  pass_once("eco_player_smelting", plates > 0, "%d iron plates smelted by the cloned template", plates)
  local en = production.stats(ENEMY)
  local enemy_plates = game.forces[ENEMY].get_item_production_statistics(util.surface()).get_input_count("iron-plate")
  pass_once("eco_enemy_production", en.walkers > 0 and enemy_plates > 0, "enemy kits=%d walkers=%d, %d iron plates "
    .. "smelted", en.kits, en.walkers, enemy_plates)

  if tick >= e.next_report then
    e.next_report = tick + ECO_REPORT_PERIOD
    eco_report(false)
  end
  local all = true
  for _, key in ipairs(ECO_KEYS) do
    if not e.passed[key] then all = false end
  end
  if all or age >= ECO_WINDOW then
    if not all then
      for _, key in ipairs(ECO_KEYS) do
        if not e.passed[key] then check(key, false, "not reached in %.0fs", age / 60) end
      end
    end
    -- keep measuring the rates over the whole window before closing
    if age >= ECO_WINDOW then
      e.done = true
      local m = e.pool_mark
      local p = production.stats(PLAYER)
      check("eco_shared_pool", m ~= nil and p.kits > m.kits and p.buildings > m.crafts, "since %.0fs: barracks "
        .. "kits +%d, factory crafts +%d (both must progress on the shared iron)", ECO_POOL_FROM / 60,
        m and p.kits - m.kits or -1, m and p.buildings - m.crafts or -1)
      eco_report(true)
      local lat = e.latency
      if lat and lat.n > 0 then
        util.log("autotest eco: kit-to-unit latency over %d player kits: min %d, max %d, avg %.2f ticks", lat.n,
          lat.min, lat.max, lat.sum / lat.n)
      end
      util.log("autotest eco: done after %.0fs", age / 60)
    elseif not e.all_passed then
      e.all_passed = tick
      util.log("autotest eco: all economy checks passed after %.0fs; measuring until %.0fs", age / 60,
        ECO_WINDOW / 60)
    end
  end
end

-- Spawn latency (spike #4 measure): the observer below notes the first tick a finished player kit is visible to
-- Lua (products_finished grew), the spawn callback pairs it with the spawn tick. production.lua's on_tick
-- handler runs before this module's, so the callback first brings the observation up to date for its barracks
-- (a kit that finished just before this tick's spawn then counts with latency 0). Observation only;
-- production.lua does not poll per tick.
local function observe_barracks(e, un, rec)
  e.finish = e.finish or {}
  e.latency = e.latency or {n = 0, sum = 0, min = math.huge, max = 0}
  local pf = rec.entity.products_finished
  local seen = e.finish["pf" .. un] or pf
  if pf > seen then
    local q = e.finish[un] or {}
    e.finish[un] = q
    for _ = seen + 1, pf do q[#q + 1] = game.tick end
  end
  e.finish["pf" .. un] = pf
end

production.on_spawned(function(unit, rec)
  local d = storage.debug
  local e = d and d.eco
  if not (e and not e.done and rec.force == PLAYER) then return end
  e.spawned[unit.unit_number] = game.tick
  observe_barracks(e, rec.entity.unit_number, rec)
  local q = e.finish and e.finish[rec.entity.unit_number]
  local finished = q and table.remove(q, 1)
  if finished then
    local lat = e.latency
    local l = game.tick - finished
    lat.n, lat.sum, lat.max = lat.n + 1, lat.sum + l, math.max(lat.max, l)
    lat.min = math.min(lat.min, l)
  end
end)

events.on(defines.events.on_tick, function()
  local d = storage.debug
  local e = d and d.eco
  if not (e and not e.done) then return end
  for un, rec in buildings.for_force(PLAYER, "barracks") do observe_barracks(e, un, rec) end
end)

function debug_tools.start_autotest()
  local d = storage.debug
  d.autotest = true
  if storage.match.phase ~= "running" or units.count(PLAYER) == 0 or units.count(ENEMY) == 0 then
    match.spawn_armies()
  end
  d.checks = {pass = 0, fail = 0}
  d.summary_logged = nil
  local m = storage.match
  local c = match.wave_config()
  check("wave_config_default", c.first_wave_ticks == match.DEFAULT_CONFIG.first_wave_ticks
    and c.wave_period_ticks == match.DEFAULT_CONFIG.wave_period_ticks
    and m.enemy_next_wave == m.tick_started + c.first_wave_ticks, "first=%ds period=%ds, next wave at tick %s "
    .. "(armies spawned at tick %s)", c.first_wave_ticks / 60, c.wave_period_ticks / 60, tostring(m.enemy_next_wave),
    tostring(m.tick_started))
  debug_tools.run_command("rts-wave-timing", AUTOTEST_WAVE_TIMING)
  check("wave_timing_override", c.first_wave_ticks == 45 * 60 and c.wave_period_ticks == 90 * 60,
    "first=%ds period=%ds", c.first_wave_ticks / 60, c.wave_period_ticks / 60)
  local P, E = PLAYER, ENEMY
  local rule = {match.decide_winner(false, false), match.decide_winner(false, true), match.decide_winner(true, false),
                match.decide_winner(true, true)}
  check("winner_rule", rule[1] == nil and rule[2] == P and rule[3] == E and rule[4] == "draw"
    and match.result(P) == nil, "none out=%s enemy out=%s player out=%s both out=%s, result while running=%s",
    tostring(rule[1]), tostring(rule[2]), tostring(rule[3]), tostring(rule[4]), tostring(match.result(P)))
  -- Re-target with no player entity in range (the path that once called an undefined local): army centroid.
  local far = match.wave_retarget({x = 5000, y = 5000})
  local centroid = units.centroid(PLAYER)
  check("wave_retarget_fallback", far ~= nil and centroid ~= nil and util.distance(far, centroid) < 0.01,
    "target from (5000, 5000) = %s, player centroid %s", util.pos_str(far), util.pos_str(centroid))
  -- The selection/orders part needs a quiet field: the first enemy wave waits until /rts-qa-reset (or this).
  m.enemy_next_wave = game.tick + QA_RESET_CHECK_AFTER + 60 * 60
  eco_start() -- first: it replaces the player base with the template before units are spawned nearby
  debug_tools.run_command("rts-spawn", "rts-walker 2 " .. PLAYER) -- exercises the console command path
  debug_tools.run_command("rts-spawn", "rts-walker-heavy 1 " .. PLAYER) -- the starting armies have no heavies
  debug_tools.run_command("rts-dump", "")
  d.started = game.tick
  d.units, d.dests, d.moved, d.attacked = {}, {}, 0, 0
  d.next_report = game.tick

  local picked, walkers, heavies, enemy = {}, 0, 0, nil
  for _, rec in units.for_force(PLAYER) do
    if rec.kind == "walker" and walkers < AUTOTEST_WALKERS then
      walkers = walkers + 1
      picked[#picked + 1] = rec.entity
    elseif rec.kind == "heavy" and heavies < AUTOTEST_HEAVIES then
      heavies = heavies + 1
      picked[#picked + 1] = rec.entity
    end
  end
  for _, rec in units.for_force(ENEMY) do
    enemy = rec.entity
    break
  end
  for _, e in ipairs(picked) do d.units[e.unit_number] = true end
  util.log("autotest: started at tick %d with %d units [%s] via fake player index %d", game.tick, #picked,
    table.concat((function()
      local l = {}
      for i, e in ipairs(picked) do l[i] = e.unit_number end
      return l
    end)(), ","), AUTOTEST_PLAYER)

  selection_checks(picked, enemy)

  local n = orders.move(AUTOTEST_PLAYER, MOVE_DEST)
  local ok, detail = all_have_order("move")
  check("move_issued", n == #picked and ok, "ordered=%d %s", n, detail)
  local min_gap, slots = math.huge, {}
  for _, rec in pairs(test_recs()) do
    d.dests[rec.entity.unit_number] = {x = rec.dest.x, y = rec.dest.y}
    slots[#slots + 1] = rec.dest
  end
  for i = 1, #slots do
    for j = i + 1, #slots do min_gap = math.min(min_gap, util.distance(slots[i], slots[j])) end
  end
  -- 2.5 is orders.lua's minimum spacing; the base-game walkers sit exactly on it (2.4999... after float math)
  check("move_spread", min_gap >= 2.5 - 1e-6, "min distance between formation slots=%.2f around %s", min_gap,
    util.pos_str(MOVE_DEST))
  set_stage("move")
end

-- Stage 2: hold, then stop.
local function start_hold(why)
  local d = storage.debug
  local n = orders.hold(AUTOTEST_PLAYER)
  local ok, detail = all_have_order("hold")
  check("hold_issued", n > 0 and ok, "(%s) ordered=%d %s", why, n, detail)
  d.hold_pos = {}
  for _, rec in pairs(test_recs()) do
    d.hold_pos[rec.entity.unit_number] = {x = rec.entity.position.x, y = rec.entity.position.y}
  end
  set_stage("hold")
end

local function finish_hold()
  local d = storage.debug
  local drift, cmds = 0, {}
  for _, rec in pairs(test_recs()) do
    local p0 = d.hold_pos[rec.entity.unit_number]
    if p0 then drift = math.max(drift, util.distance(rec.entity, p0)) end
    cmds[command_name(rec)] = (cmds[command_name(rec)] or 0) + 1
  end
  local ok, detail = all_have_order("hold")
  check("hold_kept", ok and drift < 4, "max drift %.2f tiles in %ds (spider-units coast up to ~3), commands [%s], %s",
    drift, HOLD_TICKS / 60, fmt_counts(cmds), detail)
  local n = orders.stop(AUTOTEST_PLAYER)
  ok, detail = all_have_order(units.IDLE)
  check("stop", n > 0 and ok, "ordered=%d %s", n, detail)
end

-- Stage 3: right-click dedupe and attack-move arming, through the same functions the event handlers call.
local function dedupe_step1()
  local P = AUTOTEST_PLAYER
  local d = storage.debug
  local o = storage.orders
  local f0 = orders.stats().fallbacks
  local base = util.centroid(test_entities())
  local p1 = {x = base.x, y = base.y - 6}
  -- (a) rts-rclick, then the reverse-select event in the same tick: one order, nothing left pending.
  orders.handle_rclick(P, p1, nil, false, false)
  local order = orders.handle_reverse_area(P, {}, zero_area(p1), false)
  check("rclick_then_area_same_tick", order == "move" and o.rclick[P] == nil, "order=%s pending=%s", order,
    tostring(o.rclick[P] ~= nil))
  -- (b) the area event first, then rts-rclick in the same tick: the click is ignored.
  local parked = orders.handle_rclick(P, p1, nil, false, false)
  check("area_then_rclick_same_tick", parked == false and o.rclick[P] == nil and orders.stats().fallbacks == f0,
    "parked=%s", tostring(parked))
  d.fallback_pos = {x = base.x, y = base.y + 6}
  set_stage("dedupe")
end

-- (c) rts-rclick alone (a later tick) with no tool in the cursor: the fallback must fire on the next tick.
local function dedupe_step2()
  local P = AUTOTEST_PLAYER
  local o = storage.orders
  local d = storage.debug
  d.fallbacks_before = orders.stats().fallbacks
  d.moves_before = orders.stats().issued.move or 0
  orders.handle_rclick(P, d.fallback_pos, nil, false, false)
  check("lone_rclick_parked", o.rclick[P] ~= nil and o.rclick[P].wait == 1, "pending wait=%s",
    o.rclick[P] and tostring(o.rclick[P].wait) or "none")
  set_stage("dedupe2")
end

local function dedupe_step3()
  local P = AUTOTEST_PLAYER
  local o = storage.orders
  local d = storage.debug
  -- (units may already have finished that short move, so count issued moves instead of reading orders)
  local moved = (orders.stats().issued.move or 0) - d.moves_before
  check("lone_rclick_fallback", orders.stats().fallbacks == d.fallbacks_before + 1 and moved == #test_recs()
    and o.rclick[P] == nil, "fallbacks %d -> %d, move issued to %d units", d.fallbacks_before,
    orders.stats().fallbacks, moved)
  -- (d) rts-rclick with the tool in hand: waits for the area event (which comes on button release).
  d.fallbacks_before = orders.stats().fallbacks
  orders.handle_rclick(P, d.fallback_pos, nil, true, false)
  set_stage("dedupe3")
end

local function dedupe_step4()
  local P = AUTOTEST_PLAYER
  local o = storage.orders
  local d = storage.debug
  local waited = game.tick - (o.rclick[P] and o.rclick[P].tick or game.tick)
  check("tool_rclick_waits", o.rclick[P] ~= nil and orders.stats().fallbacks == d.fallbacks_before,
    "still pending after %d ticks, fallbacks=%d", waited, orders.stats().fallbacks)
  local order = orders.handle_reverse_area(P, {}, zero_area(d.fallback_pos), false)
  check("late_area_cancels_fallback", order == "move" and o.rclick[P] == nil, "order=%s", order)
  -- (e) F then a plain right click = attack-move; the arming is used up.
  orders.arm_attack_move(P, true)
  local armed = orders.is_armed(P)
  order = orders.handle_reverse_area(P, {}, zero_area(d.fallback_pos), false)
  local ok, detail = all_have_order("attack_move")
  check("armed_right_click_attack_moves", armed and order == "attack_move" and ok and not orders.is_armed(P),
    "armed=%s order=%s still_armed=%s %s", tostring(armed), order, tostring(orders.is_armed(P)), detail)
  -- (f) shift + right click (alt reverse) = attack-move; X (stop) cancels an armed attack-move.
  order = orders.handle_reverse_area(P, {}, zero_area(d.fallback_pos), true)
  check("alt_reverse_attack_moves", order == "attack_move", "order=%s", order)
  orders.arm_attack_move(P, true)
  orders.stop(P)
  ok, detail = all_have_order(units.IDLE)
  check("stop_disarms", not orders.is_armed(P) and ok, "armed=%s %s", tostring(orders.is_armed(P)), detail)
end

-- Stage 4: attack a lone enemy walker; right-click on it must pick it as the target.
local function start_attack()
  local d = storage.debug
  local dummy = units.spawn("rts-walker", DUMMY_POS, ENEMY, "walker")
  d.dummy = dummy
  d.attacked, d.engaged_tick, d.dead_tick = 0, nil, nil
  if not dummy then
    check("attack_dummy_spawned", false, "could not place the dummy at %s", util.pos_str(DUMMY_POS))
    return false
  end
  -- right click on the dummy: entity list = [dummy] -> attack
  local order, n = orders.handle_reverse_area(AUTOTEST_PLAYER, {dummy}, zero_area(dummy.position), false)
  local ok, detail = all_have_order("attack")
  local targets_ok = true
  for _, rec in pairs(test_recs()) do
    if rec.target ~= dummy then targets_ok = false end
  end
  check("right_click_enemy_attacks", order == "attack" and n > 0 and ok and targets_ok,
    "order=%s ordered=%d target=#%d %s", order, n, dummy.unit_number, detail)
  set_stage("attack")
  return true
end

local function start_attack_move(why)
  local n = orders.attack_move(AUTOTEST_PLAYER, ATTACK_MOVE_DEST)
  local ok, detail = all_have_order("attack_move")
  check("attack_move_issued", n > 0 and ok, "(%s) ordered=%d %s", why, n, detail)
  set_stage("attack_move")
end

local function autotest_tick(tick)
  local d = storage.debug
  if tick >= d.next_report then
    d.next_report = tick + AUTOTEST_REPORT_PERIOD
    if autotest_report() == 0 and d.stage ~= "done" then
      set_stage("done")
      util.log("autotest: no autotest unit left alive; checks pass=%d fail=%d", d.checks.pass, d.checks.fail)
    end
  end
  local age = tick - d.stage_tick
  if d.stage == "move" and age >= STAGE_TIMEOUT then
    check("move_completed", false, "only %d of %d completed in %ds", d.moved, table_size(d.dests), STAGE_TIMEOUT / 60)
    start_hold("move timeout")
  elseif d.stage == "hold" and age >= HOLD_TICKS then
    finish_hold()
    dedupe_step1()
  elseif d.stage == "dedupe" and age >= 60 then
    dedupe_step2()
  elseif d.stage == "dedupe2" and age >= 60 then
    dedupe_step3()
  elseif d.stage == "dedupe3" and age >= 60 then
    dedupe_step4()
    if not start_attack() then start_attack_move("no dummy") end
  elseif d.stage == "attack" then
    -- The order logic is under test here, not the duel: a lone strafer dodges most projectiles, so 6
    -- walkers need anywhere from ~8 s to over 20 s to kill it. Checks: the target takes damage (engaged),
    -- and once it is gone every attacker is released to idle. If it survives ENGAGE_GRACE ticks after the
    -- first hit, the script kills it to exercise the target-gone path.
    local dummy = d.dummy
    local alive = dummy and dummy.valid
    if alive then
      local nearest, cmds = math.huge, {}
      for _, rec in pairs(test_recs()) do
        nearest = math.min(nearest, util.distance(rec.entity, dummy))
        local c = rec.entity.commandable
        local key = command_name(rec) .. ((c and c.distraction_command) and "+distracted" or "")
        cmds[key] = (cmds[key] or 0) + 1
      end
      util.log("autotest: attack t+%ds dummy health=%.0f nearest attacker %.1f tiles, commands [%s]", age / 60,
        dummy.health, nearest, fmt_counts(cmds))
      if not d.engaged_tick and dummy.health < dummy.max_health then
        d.engaged_tick = tick
        check("attack_engaged", true, "target hit after %.0fs", age / 60)
      end
      if d.engaged_tick and tick - d.engaged_tick >= ENGAGE_GRACE then
        util.log("autotest: target still alive (%.0f hp) %ds after the first hit; killing it by script",
          dummy.health, ENGAGE_GRACE / 60)
        dummy.die()
        alive = false
      elseif not d.engaged_tick and age >= STAGE_TIMEOUT then
        check("attack_engaged", false, "target not hit in %ds", STAGE_TIMEOUT / 60)
        start_attack_move("attack timeout")
        return
      end
    end
    if not alive then
      if not d.engaged_tick then
        -- killed before the first 60-tick look saw any damage (base-game walkers do that in under a second)
        d.engaged_tick = tick
        check("attack_engaged", d.attacked > 0, "target already gone at the first look (%d attack completions)",
          d.attacked)
      end
      d.dead_tick = d.dead_tick or tick
      local ok, detail = all_have_order(units.IDLE)
      if ok then
        check("attack_released", d.attacked > 0, "target gone, all attackers idle again after %.0fs (%d attack "
          .. "completions)", (tick - d.dead_tick) / 60, d.attacked)
        start_attack_move("target gone")
      elseif tick - d.dead_tick >= 10 * 60 then
        check("attack_released", false, "target gone 10s ago, still: %s", detail)
        start_attack_move("release timeout")
      end
    end
  end
end

-- /rts-qa-reset through the console-command path: everything it promises, then a reset with waves on.
local function qa_reset_check()
  local P = AUTOTEST_PLAYER
  util.log("autotest: /rts-qa-reset check at tick %d (match phase=%s wave=%d, player=%d enemy=%d)", game.tick,
    tostring(storage.match.phase), storage.match.wave or 0, units.count(PLAYER), units.count(ENEMY))
  selection.select_all(P)
  selection.group_set(P, 1)
  orders.arm_attack_move(P, true)
  debug_tools.run_command("rts-qa-reset", "nowaves")
  local m = storage.match
  check("qa_reset_armies", units.count(PLAYER) == ARMY_SIZE and units.count(ENEMY) == ARMY_SIZE,
    "player=%d enemy=%d expected %d each", units.count(PLAYER), units.count(ENEMY), ARMY_SIZE)
  local home_p, home_e = units.centroid(PLAYER), units.centroid(ENEMY)
  check("qa_reset_at_spawns", home_p and home_e and util.distance(home_p, match.army_point(PLAYER)) < 8
    and util.distance(home_e, match.army_point(ENEMY)) < 8, "player centroid %s (army point %s), enemy centroid %s "
    .. "(army point %s)", util.pos_str(home_p), util.pos_str(match.army_point(PLAYER)), util.pos_str(home_e),
    util.pos_str(match.army_point(ENEMY)))
  local gap = math.huge
  for _, force_name in pairs({PLAYER, ENEMY}) do
    local list = {}
    for _, rec in units.for_force(force_name) do list[#list + 1] = rec.entity.position end
    for i = 1, #list do
      for j = i + 1, #list do gap = math.min(gap, util.distance(list[i], list[j])) end
    end
  end
  check("qa_reset_spacing", gap >= match.spacing("rts-walker") - 0.01, "min distance between spawned units %.2f "
    .. "(grid %.1f for walkers, %.1f for heavies)", gap, match.spacing("rts-walker"), match.spacing("rts-walker-heavy"))
  check("qa_reset_cleared", selection.count(P) == 0 and selection.box_count(P) == 0 and selection.group_count(P, 1) == 0
    and not orders.is_armed(P), "selected=%d boxes=%d group1=%d armed=%s", selection.count(P), selection.box_count(P),
    selection.group_count(P, 1), tostring(orders.is_armed(P)))
  check("qa_reset_nowaves", m.phase == "running" and m.wave == 0 and m.enemy_next_wave == nil and m.waves_off == true
    and not (m.enemy_group and m.enemy_group.valid), "phase=%s wave=%s next_wave=%s waves_off=%s", tostring(m.phase),
    tostring(m.wave), tostring(m.enemy_next_wave), tostring(m.waves_off))
  debug_tools.run_command("rts-qa-reset", "")
  check("qa_reset_waves_on", m.waves_off == nil and m.enemy_next_wave ~= nil and m.enemy_next_wave > game.tick
    and units.count(PLAYER) == ARMY_SIZE and units.count(ENEMY) == ARMY_SIZE,
    "next wave in %ss, player=%d enemy=%d", m.enemy_next_wave and string.format("%.0f", (m.enemy_next_wave - game.tick) / 60)
    or "nil", units.count(PLAYER), units.count(ENEMY))
  util.log("autotest: finished, checks pass=%d fail=%d", storage.debug.checks.pass, storage.debug.checks.fail)
  debug_tools.run_command("rts-qa-end", "") -- exercises the command; nothing waits for the marker headless
end

-- One-off diagnostic: what rts-player has charted / sees around both spawns (chunks (-2,0) and (1,0)).
local CHART_PROBE_TICK = 600
local function chart_probe()
  local force, surface = game.forces[PLAYER], util.surface()
  local parts = {}
  for _, c in pairs({{-2, 0}, {1, 0}}) do
    parts[#parts + 1] = string.format("chunk(%d,%d) charted=%s visible=%s", c[1], c[2],
      tostring(force.is_chunk_charted(surface, c)), tostring(force.is_chunk_visible(surface, c)))
  end
  util.log("debug: chart probe at tick %d for %s: %s", game.tick, PLAYER, table.concat(parts, ", "))
end

events.on_nth_tick(60, function(e)
  local d = storage.debug
  if e.tick == CHART_PROBE_TICK then chart_probe() end
  if d.autotest == nil and e.tick >= AUTOTEST_DECIDE_TICK then
    d.autotest = #game.connected_players == 0
    util.log("autotest: %s (%d connected players at tick %d)", d.autotest and "on" or "off",
      #game.connected_players, e.tick)
    if d.autotest then debug_tools.start_autotest() end
  end
  if d.autotest and d.stage then autotest_tick(e.tick) end
  if d.autotest and d.eco then eco_tick(e.tick) end
  if d.autotest and d.started and not d.qa_reset_checked and (d.stage == "attack_move" or d.stage == "done")
     and (storage.match.phase == "ended" or e.tick - d.started >= QA_RESET_CHECK_AFTER) then
    d.qa_reset_checked = true
    qa_reset_check()
  end
  -- Both parts done (or the selection/orders part stuck well past the economy window): one summary line.
  if d.autotest and d.started and d.eco and d.eco.done and not d.summary_logged
     and (d.qa_reset_checked or e.tick - d.started >= ECO_WINDOW + 30 * 60) then
    d.summary_logged = true
    local total = d.checks.pass + d.checks.fail
    util.log("autotest summary %d/%d%s", d.checks.pass, total, d.checks.fail == 0 and " (all passed)"
      or string.format(" (%d FAILED)", d.checks.fail))
  end
end)

-- Runs after orders.lua's handler (control.lua order), so a finished move/attack is already "idle" here.
events.on(defines.events.on_ai_command_completed, function(e)
  local d = storage.debug
  if not (d and d.autotest and d.units and d.units[e.unit_number]) then return end
  local rec = units.get(e.unit_number)
  if not rec then return end
  local result = util.define_name(defines.behavior_result, e.result)
  if d.stage == "move" then
    d.moved = d.moved + 1
    local dest = d.dests[e.unit_number]
    util.log("autotest: move completed by #%d (%s) result=%s at %s, %.1f tiles from its slot; now order=%s "
      .. "command=%s [%d/%d]", e.unit_number, rec.kind, result, util.pos_str(rec.entity.position),
      dest and util.distance(rec.entity, dest) or -1, rec.order, command_name(rec), d.moved, table_size(d.dests))
    if d.moved >= table_size(d.dests) then
      local ok, detail = all_have_order(units.IDLE)
      check("move_completed", ok, "all %d moves completed, units released to idle/stop: %s", d.moved, detail)
      start_hold("all moves completed")
    end
  elseif d.stage == "attack" then
    d.attacked = d.attacked + 1
    if d.attacked > 12 then return end -- the first ones tell the story
    util.log("autotest: attack completed by #%d result=%s distracted=%s target alive=%s; now order=%s command=%s",
      e.unit_number, result, tostring(e.was_distracted), tostring(d.dummy and d.dummy.valid), rec.order,
      command_name(rec))
  end
end)

---------------------------------------------------------------------------
-- GUI self-test steps (camera.lua runs them for a real player when the self-test is on)
---------------------------------------------------------------------------
camera.add_selftest_step(180, "select_all", function(player)
  local n = selection.select_all(player.index)
  util.log("selftest: select_all for player %d -> %d selected, %d boxes", player.index, n,
    selection.box_count(player.index))
end)

camera.add_selftest_step(210, "screenshot_selection", function(player)
  camera.screenshot(player)
end)

camera.add_selftest_step(240, "groups", function(player)
  local idx = player.index
  local set = selection.group_set(idx, 1)
  selection.clear(idx)
  local after_clear = selection.box_count(idx)
  local recalled = selection.group_recall(idx, 1)
  util.log("selftest: group 1 set=%d, boxes after clear=%d, recalled=%d, boxes=%d", set, after_clear, recalled,
    selection.box_count(idx))
end)

camera.add_selftest_step(270, "order_move", function(player)
  local pos = player.position
  local n = orders.move(player.index, {x = pos.x + 12, y = pos.y})
  orders.arm_attack_move(player.index, true)
  util.log("selftest: move to %s ordered for %d units; attack-move armed=%s", util.pos_str({pos.x + 12, pos.y}), n,
    tostring(orders.is_armed(player.index)))
  camera.screenshot(player) -- the order marker and the flying text are on screen in this tick
  orders.arm_attack_move(player.index, false)
end)

-- Runs /rts-qa-reset as the real player (admin check included). After the camera's last screenshot (900)
-- and before RTS_GUI_READY (960).
camera.add_selftest_step(930, "qa_reset", function(player)
  debug_tools.run_command("rts-qa-reset", "", player.index)
end)

---------------------------------------------------------------------------
-- Console commands
---------------------------------------------------------------------------
local function admin_only(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player and not player.admin then
    player.print("[rts] admins only")
    return false
  end
  return true
end

-- The force a command acts for: the issuing player's force, else (server console, autotest) rts-player.
local function command_force(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  return player and player.force.name or PLAYER
end

local COMMANDS = {
  ["rts-spawn"] = {
    help = "<name> <count> <force> - spawn RTS units at the camera (or the force's spawn)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      local args = {}
      for word in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = word end
      local name, count, force_name = args[1] or "rts-walker", tonumber(args[2] or "1"), args[3] or PLAYER
      local proto = prototypes.entity[name]
      if not proto or (proto.type ~= "spider-unit" and proto.type ~= "unit") then
        reply(cmd, "rts-spawn: unknown unit prototype " .. tostring(name))
        return
      end
      if not game.forces[force_name] then
        reply(cmd, "rts-spawn: unknown force " .. tostring(force_name))
        return
      end
      count = math.max(1, math.min(100, math.floor(count or 1)))
      local player = cmd.player_index and game.get_player(cmd.player_index)
      local center = player and player.position
      if not center then
        -- no camera: a row starting at the force's army point, on the side facing the arena centre
        local ap = match.army_point(force_name)
        center = {x = ap.x + (match.FACING[force_name] or 1) * 13.5, y = ap.y}
      end
      local made = 0
      local sp = match.spacing(name)
      for i = 0, count - 1 do
        local pos = {x = center.x + (i % 10) * sp - 13.5, y = center.y + math.floor(i / 10) * sp + 12}
        if units.spawn(name, pos, force_name) then made = made + 1 end
      end
      reply(cmd, string.format("rts-spawn: %d x %s for %s near %s", made, name, force_name, util.pos_str(center)))
    end,
  },
  ["rts-dump"] = {
    help = "- print a summary of the RTS state",
    run = function(cmd)
      for _, line in pairs(debug_tools.dump_lines()) do reply(cmd, line) end
    end,
  },
  ["rts-qa-reset"] = {
    help = "[nowaves] - QA: re-spawn both armies at their spawns, clear selections, control groups and "
      .. "armed attack-moves, camera home. nowaves: no enemy waves until the next plain /rts-qa-reset",
    run = function(cmd)
      if not admin_only(cmd) then return end
      local waves = not string.find(string.lower(cmd.parameter or ""), "nowaves", 1, true)
      local d = storage.debug
      if d.autotest and d.stage and d.stage ~= "done" then set_stage("done") end -- its units are about to go
      orders.reset()
      local cleared = 0
      for index in pairs(storage.players or {}) do
        selection.reset(index)
        cleared = cleared + 1
      end
      local removed, corpses = match.reset(waves)
      for _, player in pairs(game.connected_players) do
        camera.home(player)
        cursor.ensure(player, true, "qa-reset")
      end
      local m = storage.match
      reply(cmd, string.format("qa-reset by %s: removed %d units and %d corpses, spawned player=%d enemy=%d, "
        .. "cleared %d selections; enemy waves %s", cmd.player_index and ("player=" .. cmd.player_index) or "script",
        removed, corpses, units.count(PLAYER), units.count(ENEMY), cleared,
        m.waves_off and "off" or string.format("on, next in %.0fs", (m.enemy_next_wave - game.tick) / 60)))
    end,
  },
  ["rts-qa-end"] = {
    help = "- QA: write the state summary and the QA end marker to the log (tools/gui-run.sh can stop on it)",
    run = function(cmd)
      for _, line in pairs(debug_tools.dump_lines()) do reply(cmd, line) end
      util.log("RTS_QA_END by %s at tick %d", cmd.player_index and ("player=" .. cmd.player_index) or "script",
        game.tick)
    end,
  },
  ["rts-give"] = {
    help = "<item> [count=100] - put items into your force's resource pool (the CC network's stockpiles)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      local args = {}
      for word in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = word end
      local item, count = args[1], math.floor(tonumber(args[2] or "100") or 100)
      if not (item and prototypes.item[item]) then
        reply(cmd, "rts-give: unknown item " .. tostring(item))
        return
      end
      local force_name = command_force(cmd)
      local n = economy.give(force_name, item, math.max(1, count))
      reply(cmd, string.format("rts-give: %d x %s into the %s pool", n, item, force_name))
    end,
  },
  ["rts-eco"] = {
    help = "- print the economy summary (resources, bots, power) and production counters of both forces",
    run = function(cmd)
      local own = command_force(cmd)
      local other = own == ENEMY and PLAYER or ENEMY
      for _, force_name in ipairs({own, other}) do
        reply(cmd, economy.describe(force_name))
        local st = production.stats(force_name)
        reply(cmd, string.format("%s production: kits=%d walkers=%d factory crafts=%d items to network=%d "
          .. "magazines fed=%d", force_name, st.kits, st.walkers, st.buildings, st.items, st.magazines))
      end
    end,
  },
  ["rts-build-template"] = {
    help = "- replace your base with the starter base template (CC, extractors, smelters, barracks on walker kits)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      local force_name = command_force(cmd)
      local r = basetemplate.clone_to(util.surface(), force_name, match.home(force_name))
      local armed = match.arm_barracks(force_name, "rts-walker-kit")
      local kinds = {}
      for k, n in pairs(r.kinds) do kinds[#kinds + 1] = k .. "=" .. n end
      table.sort(kinds)
      reply(cmd, string.format("rts-build-template: %d entities for %s at %s [%s], %d barracks on walker kits",
        r.entities, force_name, util.pos_str(match.home(force_name)), table.concat(kinds, " "), armed))
    end,
  },
  ["rts-rally"] = {
    help = "<x> <y> - set the rally point of all your barracks (no arguments: clear it)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      local args = {}
      for word in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = word end
      local x, y = tonumber(args[1] or ""), tonumber(args[2] or "")
      if args[1] and not (x and y) then
        reply(cmd, "rts-rally: usage /rts-rally <x> <y>")
        return
      end
      local force_name = command_force(cmd)
      local pos = x and {x = x, y = y} or nil
      local n = 0
      for un in buildings.for_force(force_name, "barracks") do
        if buildings.set_rally(un, pos) then n = n + 1 end
      end
      reply(cmd, string.format("rts-rally: %d barracks of %s -> %s", n, force_name,
        pos and util.pos_str(pos) or "cleared (default exit)"))
    end,
  },
  ["rts-wave-timing"] = {
    help = "[first_s] [period_s] - debug: enemy wave timing in seconds (no arguments: print it)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      local args = {}
      for word in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = word end
      local first, period = tonumber(args[1] or ""), tonumber(args[2] or "")
      if args[1] and not first then
        reply(cmd, "rts-wave-timing: usage /rts-wave-timing <first_s> [period_s]")
        return
      end
      local c = match.wave_config()
      if first then match.set_wave_timing(first, period or c.wave_period_ticks / 60) end
      local m = storage.match
      reply(cmd, string.format("rts-wave-timing: first wave %.0fs after the armies spawn, then every %.0fs; next %s",
        c.first_wave_ticks / 60, c.wave_period_ticks / 60, m.enemy_next_wave
        and string.format("in %.0fs", (m.enemy_next_wave - game.tick) / 60) or "not scheduled"))
    end,
  },
  ["rts-autotest"] = {
    help = "- start the scripted autotest (selection and orders through fake player index 0)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      debug_tools.start_autotest()
      reply(cmd, "rts-autotest: started")
    end,
  },
}

for name, def in pairs(COMMANDS) do
  commands.add_command(name, def.help, def.run)
end

--- Run one of the /rts-* commands from script, e.g. from the autotest: as the server console, or as the
--- player `player_index` when given.
function debug_tools.run_command(name, parameter, player_index)
  COMMANDS[name].run({name = name, parameter = parameter, tick = game.tick, player_index = player_index})
end

return debug_tools
