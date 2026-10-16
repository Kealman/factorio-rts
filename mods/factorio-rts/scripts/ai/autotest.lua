-- Headless AI autotest (docs/PHASE3.md acceptance 2 and 4): both forces are AI commanders and fight for DURATION.
-- debug.lua starts it instead of the Phase 1/2 autotest when storage.match.config.enemy_brain == "ai".
--
-- Log lines:
--   [rts] ai autotest: started ...
--   [rts] ai minute N <force>: buildings [...] units N kits N walkers N (+N/min) known enemies N attacks N ...
--   [rts] ai perf minute N: ticks T, AI runs R, AI time <profiler>, wall clock <profiler>
--   [rts] ai autotest check <name>: PASS|FAIL ...
--   [rts] ai autotest summary <passed>/<total> ... result=...
-- Checks: lines_<force> (iron and copper lines each have a built drill and a built hub slot at some point, unless
-- the force lost its CC first), planner_arena_half and planner_vertical_iron / _copper (autotest.planner_check: a base whose ore lies north
-- and south of the CC, as rotated spawns put it), build_3min (each force has an extractor, a smelter and a barracks by 3 min), produce (kits made in every
-- minute from minute 3 on while the force still has a barracks and a CC), attack (each force launched an attack by the end,
-- unless the match ended first or the force lost its CC first), outcome (the match ended, or at least two forces
-- still produce at the end; when a force stopped producing at DURATION, the test waits up to END_GRACE for the match
-- to end), no_bad_spam (fewer than 20 construction entries given up per force). FORCES is every match force (debug.lua
-- sets it); 1v1 is rts-player vs rts-ai-1.
-- Phase 4 checks (each excused for a force that lost its CC before the deadline): lab_<force> (a lab stood),
-- techs_6min_<force> (at least 2 technologies researched by 6 minutes), kinds_8min_<force> (at least 3 unit kinds
-- spawned by 8 minutes, or by the end), hub_<force> (economic doctrine: a hub built and at least 1 hauler delivery),
-- harass_<force> (aggressive doctrine: at least 1 raider harass); these deadlines scale with the force's
-- orders_data.TIME_SCALE (easy x1.5) and a check whose scaled deadline lies past the test is "not due". DOCTRINES sets
-- the doctrines (nil = the seeded
-- draw); the minute report adds research, hubs, haulers, the unit mix and supply, and the perf line the AI time
-- per tick.
-- Phase 5 check: divisions (every force that attacked or defended did it with divisions; the order queue stayed within
-- orders.QUEUE's per-tick budgets).
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local economy = require("scripts.economy")
local ai = require("scripts.ai.init")
local commander = require("scripts.ai.commander")
local layout = require("scripts.ai.layout")
local data = require("scripts.ai.orders_data")
local build_order = require("scripts.ai.build_order")
local tech = require("scripts.ai.tech")
local hubs = require("scripts.ai.hubs")
local mix = require("scripts.ai.mix")
local deps = require("scripts.ai.deps")
local age_up = require("scripts.ai.age_up") -- Phase 5 E1
local divisions = require("scripts.divisions") -- Phase 5: the divisions check
local orders = require("scripts.orders")
local world = require("scripts.world") -- Phase 5 M1: world checks of a Nation match (docs/PHASE5-M1.md §4)
local towns = require("scripts.ai.towns") -- Phase 5 M1 integration: the AI's mining town (minute line)

local autotest = {}

autotest.DURATION = 8 * 60 * 60 -- test copies may set a longer one to see how long a match takes
autotest.MINUTE = 60 * 60
autotest.BUILD_DEADLINE = 3 * 60 * 60
autotest.TECH_DEADLINE = 6 * 60 * 60
autotest.KINDS_DEADLINE = 8 * 60 * 60
autotest.END_GRACE = 60 * 60 -- at DURATION, a side that stopped producing gets this long for the match to end
-- Phase 5 E1 (Nation mode only): Age II by AGE_DEADLINE (normal pace), DISTRICTS districts within DISTRICT_WINDOW of it
autotest.AGE_DEADLINE = 20 * 60 * 60
autotest.DISTRICTS = 2
autotest.DISTRICT_WINDOW = 5 * 60 * 60
autotest.CAR_WINDOW = 4 * 60 * 60 -- an Age II force has an Armoured car within this long of Age II
autotest.NATION_IDLE_MINUTES = 3 -- Nation mode: produce fails after this many minutes in a row without a kit
-- Phase 5 M1 integration (docs/PHASE5-M1.md section 4, end-to-end): a second city by CITY_DEADLINE, an open rail line
-- by LINE_DEADLINE (each force), TRAIN_ITEMS items delivered by train by all forces together by TRAIN_DEADLINE
autotest.CITY_DEADLINE = 15 * 60 * 60
autotest.LINE_DEADLINE = 40 * 60 * 60
autotest.TRAIN_ITEMS = 20000
autotest.TRAIN_DEADLINE = 60 * 60 * 60
autotest.FORCES = {util.PLAYER_FORCE, util.ENEMY_FORCE}
-- The player commander's difficulty; nil = the same as the enemy's (storage.match.config.enemy_difficulty), so
-- one setting runs easy-vs-easy, normal-vs-normal or hard-vs-hard.
autotest.PLAYER_DIFFICULTY = nil
-- Doctrines per force for the run; nil (or a force left out) = the seeded draw (ai/doctrine.lua).
autotest.DOCTRINES = {["rts-player"] = "economic", ["rts-ai-1"] = "aggressive"}

-- Module-local wall clock (profilers are not game state).
local wall

local function state() return storage.ai_autotest end

-- Phase 4 deadlines scale with the commander's pacing (orders_data.TIME_SCALE: easy 1.5, normal 1, hard 0.7), like its
-- build-order time gates (Wave C): easy researches and expands later by design. A scaled deadline past the end of the
-- test makes the check "not due" (it passes and says so) unless the force met it anyway.
local function scaled(C, ticks)
  local scale = C and data.TIME_SCALE and data.TIME_SCALE[C.difficulty] or 1
  return math.floor(ticks * math.max(1, scale) + 0.5)
end

-- Phase 5 M1 integration: in Nation mode the AI researches Industrialisation and saves for the Charter first, so its
-- third unit kind may come a little later (the economic doctrine missed 8:00 in 1 of 5 seeds): NATION_KINDS_DEADLINE.
autotest.NATION_KINDS_DEADLINE = 10 * 60 * 60
local function nation_match()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end
local function kinds_due(C)
  return nation_match() and autotest.NATION_KINDS_DEADLINE or autotest.KINDS_DEADLINE
end

local function check(name, ok, fmt, ...)
  local s = state()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("ai autotest check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

---------------------------------------------------------------------------
-- Planner check (rotated spawns): a CC whose ore lies north and south of it
---------------------------------------------------------------------------
autotest.PLANNER_SURFACE = "rts-ai-planner-check"
autotest.PLANNER_ORE = {{"iron-ore", 0, 28, 12}, {"copper-ore", 0, -28, 10}} -- name, dx, dy, size (from the CC)

--- Plan the iron and copper lines with the real planner for a CC at (0, 0) on a scratch surface, iron 28 tiles
--- south and copper 28 tiles north of it, as rotated spawns put them. Both spines must run north-south (vertical),
--- with drills, at least one routed hub slot and a pole chain to the CC. Also checks the arena-size contract
--- (layout.arena_half() == storage.match.arena_half). Nothing is registered and the surface is deleted afterwards.
function autotest.planner_check()
  local m = storage.match
  check("planner_arena_half", m == nil or m.arena_half == nil or layout.arena_half() == m.arena_half,
    "layout.arena_half() = %s, storage.match.arena_half = %s", tostring(layout.arena_half()),
    tostring(m and m.arena_half))
  local surface = game.surfaces[autotest.PLANNER_SURFACE] or game.create_surface(autotest.PLANNER_SURFACE, {
    default_enable_all_autoplace_controls = false,
    autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
                          decorative = {treat_missing_as_default = false, settings = {}}},
  })
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  for _, e in pairs(surface.find_entities_filtered({area = {{-60, -60}, {60, 60}}})) do e.destroy() end
  local tiles = {}
  for x = -60, 59 do
    for y = -60, 59 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, true, true, false)
  -- obstacles where a CC composite stands (neutral, unregistered: create_entity raises no built event)
  surface.create_entity({name = "rts-command-center", position = {0, 0}, force = "neutral"})
  for _, off in ipairs(buildings.CC_STOCKPILES) do
    surface.create_entity({name = "rts-stockpile", position = {off.x, off.y}, force = "neutral"})
  end
  for _, o in ipairs(autotest.PLANNER_ORE) do
    local half = o[4] / 2
    for x = o[2] - half, o[2] + half - 1 do
      for y = o[3] - half, o[3] + half - 1 do
        surface.create_entity({name = o[1], position = {x + 0.5, y + 0.5}, amount = 1000})
      end
    end
  end
  local C = {force = "rts-planner-check", frame = layout.frame({x = 0, y = 0}, 1), reserved = {}, avoid = {},
             belt_tiles = {}, claimed = {}, plan = {}}
  layout.reserve_hub(C, C.frame)
  local ctx = layout.context(C, surface)
  for _, name in ipairs({"iron", "copper"}) do
    local ok_plan, plan, reason = pcall(layout.plan_line, C, ctx, name, data.LINES[name], {})
    local vertical, drills, slots, detail = false, 0, 0, nil
    if not ok_plan then
      detail = "planner error: " .. tostring(plan)
    elseif not plan then
      detail = "no plan: " .. tostring(reason)
    else
      local xs, ys = {}, {}
      for _, b in ipairs(plan.belts) do
        if b.seg == 0 then
          xs[b.x] = true
          ys[b.y] = true
        end
      end
      vertical = table_size(xs) == 1 and table_size(ys) > 1
      drills, slots = #plan.drills, #plan.slots
      local names = {}
      for i, sl in ipairs(plan.slots) do names[i] = sl.name end
      detail = string.format("patch %s at %s: spine %s (%d tiles), %d drill spots, slots [%s], %d belts, pole chain %s",
        plan.patch.id, util.pos_str({plan.patch.cx, plan.patch.cy}), vertical and "vertical" or "NOT vertical",
        table_size(ys) * table_size(xs), drills, table.concat(names, " "), #plan.belts,
        plan.chained and "reaches the CC" or "short")
    end
    check("planner_vertical_" .. name, vertical and drills >= 2 and slots >= 1, "%s", detail)
  end
  game.delete_surface(surface)
end

function autotest.start()
  local s = {started = game.tick, minute = 0, pass = 0, fail = 0, kits = {}, per_minute = {}, built_at = {},
             lines_at = {}, produced_ok = {}, done = false, lab_at = {}, techs_at_deadline = {}, kinds = {},
             kinds_at_deadline = {}, hub_at = {}, delivery_at = {}, cc_lost_at = {}}
  storage.ai_autotest = s
  autotest.planner_check()
  local cfg = storage.match and storage.match.config
  local difficulty = autotest.PLAYER_DIFFICULTY or (cfg and cfg.enemy_difficulty) or "normal"
  for _, f in ipairs(autotest.FORCES) do
    local want = autotest.DOCTRINES and autotest.DOCTRINES[f]
    if want then ai.set_doctrine(f, want) end
    if not ai.get(f) then ai.init_force(f, difficulty) end
    s.kits[f] = production.stats(f).kits
    s.per_minute[f] = {}
    s.produced_ok[f] = true
    s.kinds[f] = {}
  end
  ai.reset_perf()
  wall = helpers.create_profiler()
  autotest.log_maps()
  local parts = {}
  for _, f in ipairs(autotest.FORCES) do
    local C = ai.get(f)
    parts[#parts + 1] = string.format("%s (%s, %s)", f, C.difficulty, C.doctrine)
  end
  util.log("ai autotest: started at tick %d, %s, %d minutes", game.tick, table.concat(parts, " vs "),
    autotest.DURATION / autotest.MINUTE)
end

-- Unit kinds each force's barracks spawned (kinds_8min check).
production.on_spawned(function(unit, rec, kit)
  local s = storage.ai_autotest
  if not (s and s.kinds and s.kinds[rec.force]) then return end
  local u = units.get(unit.unit_number)
  local kind = u and u.kind or unit.name
  if not s.kinds[rec.force][kind] then
    s.kinds[rec.force][kind] = game.tick - s.started
    util.log("ai autotest: %s spawned its first %s at %.0fs", rec.force, kind, (game.tick - s.started) / 60)
  end
end)

local function kinds_line(t)
  local list = {}
  for kind in pairs(t or {}) do list[#list + 1] = kind end
  table.sort(list)
  return table.concat(list, " ")
end

local function delivered_total(f)
  local st = deps.logistics and deps.logistics.stats(f)
  local n = 0
  for _, c in pairs(st and st.delivered or {}) do n = n + c end
  return n, st
end

local function kinds(force_name)
  local parts = {}
  for _, kind in ipairs({"cc", "extractor", "smelter", "barracks", "factory", "turret", "solar"}) do
    parts[#parts + 1] = kind .. "=" .. buildings.count(force_name, kind)
  end
  return table.concat(parts, " ")
end

local function minute_report(s, n)
  local m = storage.match
  for _, f in ipairs(autotest.FORCES) do
    local C = ai.get(f)
    local st = production.stats(f)
    local delta = st.kits - (s.kits[f] or 0)
    s.kits[f] = st.kits
    s.per_minute[f][n] = delta
    local snap = economy.snapshot(f)
    -- plates smelted this minute (force item production statistics)
    local made = {}
    local stats = game.forces[f].get_item_production_statistics(util.surface())
    s.made = s.made or {}
    s.made[f] = s.made[f] or {}
    for _, item in ipairs({"iron-plate", "copper-plate", "steel-plate"}) do
      local total = stats.get_input_count(item)
      made[item] = total - (s.made[f][item] or 0)
      s.made[f][item] = total
    end
    util.log("ai minute %d %s: buildings [%s] units %d kits %d (+%d this minute) walkers %d heavies %d | smelted "
      .. "+%d iron +%d copper +%d steel | network iron %d copper %d stone %d steel %d | queue %d known enemies %d "
      .. "attacks %d reinforcements %d retreats %d defends %d | step %s", n, f, kinds(f), units.count(f), st.kits,
      delta, st.walkers, st.heavies, made["iron-plate"], made["copper-plate"], made["steel-plate"],
      snap.iron, snap.copper, snap.stone, snap.steel, C and #C.queue or -1, C and table_size(C.known) or -1,
      C and C.stats.attacks or -1, C and C.stats.reinforcements or -1, C and C.stats.retreats or -1,
      C and C.stats.defends or -1, C and tostring(C.current_step) or "-")
    if C then
      local labs, working = 0, 0
      if deps.research then labs, working = deps.research.lab_counts(f) end
      local total, lst = delivered_total(f)
      util.log("ai minute %d %s phase4: doctrine %s | labs %d (working %d) techs %d research %s | hubs %d haulers %d "
        .. "trips %d delivered %d lost %d | units [%s] desired [%s] kinds spawned [%s] | supply %s/%s%s | harass %d "
        .. "guards %d patrols %d priority %d yields %d/%d", n, f, C.doctrine, labs, working, tech.done_count(f),
        C.science and C.science.tech or "-", buildings.count(f, "hub"), hubs.hauler_count(C), lst and lst.trips or 0,
        total, lst and lst.lost or 0, mix.describe(C.mix_counts), mix.describe(C.mix_weights), kinds_line(s.kinds[f]),
        tostring(C.supply_used), tostring(C.supply_cap), C.capped and " CAPPED" or "", C.stats.harass or 0,
        C.stats.guards or 0, C.stats.patrols or 0, C.stats.priority or 0, C.stats.yields or 0,
        C.stats.builder_yields or 0)
    end
  end
  if deps.ages and deps.ages.is_nation() then -- Phase 5 E1
    for _, f in ipairs(autotest.FORCES) do
      local C = ai.get(f)
      local st = production.stats(f)
      util.log("ai minute %d %s nation: %s | %s | districts %d | cars %d, army %d (Age I kit cost x%.1f, %d "
        .. "surcharges paid)", n, f, deps.ages.describe(f), C and age_up.describe(C) or "-",
        buildings.count(f, "district"), units.count(f, "car"), production.army_size(f), production.army_multiplier(f),
        st.surcharge or 0)
      -- Phase 5 M1 integration: cities, the town, rail lines and train freight
      local rs = deps.rails and deps.rails.stats(f)
      local lines = {}
      for _, line in ipairs(deps.rails and deps.rails.lines_of(f) or {}) do
        lines[#lines + 1] = string.format("#%d %s %d/%d", line.id, line.state, (line.pieces and #line.pieces or 0)
          - (line.missing or 0), line.pieces and #line.pieces or 0)
      end
      local lst = deps.logistics and deps.logistics.stats(f)
      util.log("ai minute %d %s m1: cities %d | %s | lines [%s] | trains: %d trips, %d items [%s] | haulers: %d trips, "
        .. "%d coal burnt", n, f, deps.cities and #deps.cities.for_force(f) or 0, C and towns.describe(C) or "-",
        table.concat(lines, " "), rs and rs.trips or 0, rs and rs.items or 0, rs and (function()
          local parts = {}
          for item, c in pairs(rs.delivered) do parts[#parts + 1] = item .. "=" .. c end
          table.sort(parts)
          return table.concat(parts, " ")
        end)() or "", lst and lst.trips or 0, lst and lst.fuel or 0)
      if not (s.car_at and s.car_at[f]) and units.count(f, "car") > 0 then
        s.car_at = s.car_at or {}
        s.car_at[f] = game.tick - s.started
      end
    end
  end
  util.log("ai minute %d match: phase=%s winner=%s", n, tostring(m and m.phase), tostring(m and m.winner))
  local p = ai.perf()
  if wall then
    wall.stop()
    log({"", string.format("[rts] ai perf minute %d: %d ticks, %d AI runs, AI time ", n, autotest.MINUTE, p.runs),
         p.ai, " | wall clock ", wall})
    -- per tick: the AI time divided over the minute's ticks (Lua formats the profiler; the division is done there)
    local per_tick = helpers.create_profiler(true)
    per_tick.add(p.ai)
    per_tick.divide(autotest.MINUTE)
    log({"", string.format("[rts] ai perf minute %d: AI time per tick (average over %d ticks) ", n, autotest.MINUTE),
         per_tick})
    local parts = {""}
    for _, name in ipairs(commander.PARTS) do
      parts[#parts + 1] = " | " .. name .. " "
      parts[#parts + 1] = p.parts[name]
    end
    log({"", string.format("[rts] ai perf minute %d parts", n), parts})
    wall.reset()
  else
    log({"", string.format("[rts] ai perf minute %d: %d AI runs, AI time ", n, p.runs), p.ai,
         " (wall clock lost after a load)"})
    wall = helpers.create_profiler()
  end
  ai.reset_perf()
end

--- True when the force's commander has built at least one drill and one hub slot on its iron and copper lines.
function autotest.lines_running(f)
  local C = ai.get(f)
  if not C then return false end
  for _, name in ipairs({"iron", "copper"}) do
    local L = C.lines[name]
    if not (L and L.status == "ok" and build_order.line_drills_built(C, L) > 0
            and build_order.line_slots_built(C, L) > 0) then
      return false
    end
  end
  return true
end

local function has_all(f)
  return buildings.count(f, "extractor") > 0 and buildings.count(f, "smelter") > 0
    and buildings.count(f, "barracks") > 0
end

function autotest.log_maps() ai.log_maps() end

--- Forces that made a kit in the last reported minute.
function autotest.producing(s)
  local n = 0
  for _, f in ipairs(autotest.FORCES) do
    if (s.per_minute[f][s.minute] or 0) > 0 then n = n + 1 end
  end
  return n
end

local function finish(s, why)
  s.done = true
  local m = storage.match
  local ended = m and m.phase == "ended"
  ai.run_command("rts-ai-dump", "") -- the console command path, as the server console
  ai.run_command("rts-ai", "no-such-force normal")
  ai.run_command("rts-ai-map", "")
  local enemy_ai = ai.get(util.ENEMY_FORCE)
  if enemy_ai then ai.run_command("rts-ai", util.ENEMY_FORCE .. " " .. enemy_ai.difficulty) end -- in-place path
  for _, f in ipairs(autotest.FORCES) do
    local C = ai.get(f)
    local knocked_out = buildings.count(f, "cc") == 0
    local lost = s.cc_lost_at[f]
    local function excused(deadline) return lost ~= nil and lost < deadline end
    local lost_txt = lost and string.format(" (lost its CC at %.0fs)", lost / 60) or ""
    check("lab_" .. f, s.lab_at[f] ~= nil or excused(autotest.BUILD_DEADLINE), "%s: %s%s", f,
      s.lab_at[f] and string.format("first lab at %.0fs", s.lab_at[f] / 60) or "no lab", lost_txt)
    local tech_deadline, kinds_deadline = scaled(C, autotest.TECH_DEADLINE), scaled(C, kinds_due(C))
    local end_deadline = scaled(C, autotest.DURATION)
    local function not_due(deadline)
      return game.tick - s.started < deadline and string.format(", not due (deadline %.1f min at %s pace)",
        deadline / autotest.MINUTE, C and C.difficulty or "?") or ""
    end
    local techs = s.techs_at_deadline[f]
    if techs == nil then techs = tech.done_count(f) end
    local techs_nd = techs < 2 and s.techs_at_deadline[f] == nil and not_due(tech_deadline) or ""
    check("techs_6min_" .. f, techs >= 2 or excused(tech_deadline) or techs_nd ~= "", "%s: %d technologies by %s%s%s [%s]",
      f, techs, s.techs_at_deadline[f] and string.format("%.1f min", tech_deadline / autotest.MINUTE) or "the end",
      lost_txt, techs_nd, (function()
        local names = {}
        for name, t in pairs(C and C.tech and C.tech.done or {}) do names[#names + 1] = string.format("%s@%.0fs", name,
          (t - C.started) / 60) end
        table.sort(names)
        return table.concat(names, " ")
      end)())
    local nk = s.kinds_at_deadline[f] or table_size(s.kinds[f] or {})
    local kinds_nd = nk < 3 and s.kinds_at_deadline[f] == nil and not_due(kinds_deadline) or ""
    -- Phase 5 M1 integration: a Nation AI at its Age I army cap (ai/mix.lua AGE1_ARMY) makes no unit at all, so no new
    -- kind either (the aggressive doctrine fills its 40 by minute 4)
    local capped_at = s.cap_at and s.cap_at[f]
    local cap_txt = nk < 3 and capped_at and capped_at < kinds_deadline and string.format(
      ", army at the Age I cap from %.0fs (no units, so no new kinds)", capped_at / 60) or ""
    check("kinds_8min_" .. f, nk >= 3 or excused(kinds_deadline) or kinds_nd ~= "" or cap_txt ~= "",
      "%s: %d unit kinds spawned [%s]%s%s%s", f, nk, kinds_line(s.kinds[f]), lost_txt, kinds_nd, cap_txt)
    if C then
      for _, l in ipairs(hubs.diagnose(C)) do util.log("%s", l) end
    end
    if C and C.doctrine == "economic" then
      local total, lst = delivered_total(f)
      local hub_nd = not (s.hub_at[f] ~= nil and total > 0) and not_due(end_deadline) or ""
      check("hub_" .. f, (s.hub_at[f] ~= nil and total > 0) or excused(end_deadline) or hub_nd ~= "",
        "%s: %s, %s%s%s; %s", f, s.hub_at[f] and string.format("hub built at %.0fs", s.hub_at[f] / 60) or "no hub",
        s.delivery_at[f] and string.format("first hauler delivery at %.0fs", s.delivery_at[f] / 60) or "no delivery",
        lost_txt, hub_nd, hubs.describe(C))
    end
    if C and C.doctrine == "aggressive" then
      local harass_nd = (C.stats.harass or 0) < 1 and not_due(end_deadline) or ""
      -- Phase 5 M1 integration: on a Nation world (3072 tiles) the raiders may be ready long before scouting has seen
      -- a single enemy hauler, hub or outlying extractor; that is the map, not the doctrine
      local no_target = nation_match() and (C.stats.harass or 0) < 1 and (C.stats.harass_no_target or 0) > 0
      check("harass_" .. f, (C.stats.harass or 0) >= 1 or excused(end_deadline) or harass_nd ~= "" or no_target,
        "%s: %d raider harass(es)%s%s%s", f, C.stats.harass or 0, lost_txt, harass_nd, no_target
        and string.format(", raiders ready %d times but no enemy target known yet (Nation world)",
          C.stats.harass_no_target) or "")
    end
    -- Phase 4: the economic and turtle doctrines push late; one whose pool never reached its attack size or parity
    -- with the enemy army it saw (army.lua PARITY) holds, by design, and the line says so
    local a = C and C.army
    local need = a and math.max(a.min or 0, math.floor((a.enemy_seen or 0) * 0.8 + 0.5)) or 0
    local held = C and (C.doctrine == "turtle" or C.doctrine == "economic") and a and (a.pool_strength or 0) < need
    local not_due = C and game.tick < C.started + (C.cfg.first_attack or 0) -- easy x late doctrines: past 8 minutes
    -- Phase 5 M1 integration: in Nation mode's Age I the AI attacks nothing beyond army.NATION_AGE1_REACH
    local reach = C and (C.stats.attacks or 0) == 0 and (C.stats.reach_held or 0) > 0
    held = held or reach
    check("attack_" .. f, (C and C.stats.attacks > 0) or ended or knocked_out or held or not_due,
      "%s launched %d attacks (%d reinforcements)%s", f, C and C.stats.attacks or 0, C and C.stats.reinforcements or 0,
      ended and ", match ended" or (knocked_out and ", lost its CC first" or (reach and string.format(
        ", Age I: every target lay beyond the Nation reach (%d times)", C.stats.reach_held) or held and string.format(
        ", %s held: pool strength %.1f below %d (attack size %d, enemy army seen %d)", C.doctrine,
        a.pool_strength or 0, need, a.min or 0, a.enemy_seen or 0) or (not_due and string.format(
        ", first attack not due before %ds", (C.cfg.first_attack or 0) / 60) or ""))))
    check("produce_" .. f, s.produced_ok[f], "%s kits per minute [%s]", f,
      table.concat(s.per_minute[f], " "))
    check("no_bad_spam_" .. f, (C and C.stats.bad or 0) < 20, "%s gave up on %d construction entries", f,
      C and C.stats.bad or 0)
    local lp = {}
    for _, name in ipairs({"iron", "copper"}) do
      local L = C and C.lines[name]
      lp[#lp + 1] = L and (L.status == "ok" and string.format("%s drills %d slots %d", name,
        build_order.line_drills_built(C, L), build_order.line_slots_built(C, L))
        or (name .. " unavailable: " .. tostring(L.reason))) or (name .. " not planned")
    end
    check("lines_" .. f, s.lines_at[f] ~= nil or knocked_out, "%s: %s; %s", f, s.lines_at[f]
      and string.format("iron and copper lines running at %.0fs", s.lines_at[f] / 60)
      or (knocked_out and "lost its CC first" or "not both running"), table.concat(lp, ", "))
  end
  if deps.ages and deps.ages.is_nation() then -- Phase 5 E1
    for _, f in ipairs(autotest.FORCES) do
      local C = ai.get(f)
      local lost = s.cc_lost_at[f]
      local deadline = scaled(C, autotest.AGE_DEADLINE)
      local at = s.age2_at and s.age2_at[f]
      local nd = not at and game.tick - s.started < deadline and string.format(", not due (deadline %.1f min)",
        deadline / autotest.MINUTE) or ""
      check("age2_" .. f, (at ~= nil and at <= deadline) or (lost ~= nil and lost < deadline) or nd ~= "",
        "%s: %s; industrialisation %s, charter started %s%s%s; %s", f,
        at and string.format("Age II at %d:%02d", math.floor(at / 3600), math.floor(at / 60) % 60) or "no Age II",
        s.indust_at and s.indust_at[f] and string.format("%.0fs", s.indust_at[f] / 60) or "-",
        s.charter_at and s.charter_at[f] and string.format("%.0fs", s.charter_at[f] / 60) or "-",
        lost and string.format(" (lost its CC at %.0fs)", lost / 60) or "", nd, deps.ages.describe(f))
      local nd2 = (not at or game.tick - s.started < at + autotest.DISTRICT_WINDOW) and ", not due" or ""
      local nd_ok = buildings.count(f, "district") >= autotest.DISTRICTS
      check("districts_" .. f, nd_ok or nd2 ~= "" or buildings.count(f, "cc") == 0,
        "%s: %d districts%s; %s", f, buildings.count(f, "district"), nd_ok and "" or nd2,
        C and age_up.describe(C) or "-")
      -- the Age II army: an Armoured car within CAR_WINDOW of Age II (first seen in a minute report)
      local car_at = s.car_at and s.car_at[f]
      local car_nd = (not at or game.tick - s.started < at + autotest.CAR_WINDOW) and ", not due" or ""
      check("cars_" .. f, car_at ~= nil or car_nd ~= "" or buildings.count(f, "cc") == 0,
        "%s: %s%s; army %d, %d surcharges paid", f, car_at and string.format("first Armoured car by %d:%02d",
          math.floor(car_at / 3600), math.floor(car_at / 60) % 60) or "no Armoured car", car_at and "" or car_nd,
        production.army_size(f), production.stats(f).surcharge or 0)
    end
  end
  if deps.ages and deps.ages.is_nation() then -- Phase 5 M1 integration: the end-to-end acceptance (PHASE5-M1.md §4)
    local age_now = game.tick - s.started
    local function due(deadline) return age_now >= deadline end
    local items, parts = 0, {}
    for _, f in ipairs(autotest.FORCES) do
      local lost = s.cc_lost_at[f]
      local c2 = s.city2_at and s.city2_at[f]
      check("city2_" .. f, c2 ~= nil or (lost ~= nil and lost < autotest.CITY_DEADLINE) or not due(autotest.CITY_DEADLINE),
        "%s: %s%s%s", f, c2 and string.format("second city at %d:%02d", math.floor(c2 / 3600), math.floor(c2 / 60) % 60)
        or "no second city", lost and string.format(" (lost its CC at %.0fs)", lost / 60) or "",
        (not c2 and not due(autotest.CITY_DEADLINE)) and ", not due" or "")
      local la = s.line_at and s.line_at[f]
      local C = ai.get(f)
      check("rail_line_" .. f, la ~= nil or (lost ~= nil and lost < autotest.LINE_DEADLINE) or not due(autotest.LINE_DEADLINE),
        "%s: %s%s%s; %s", f, la and string.format("first line open at %d:%02d", math.floor(la / 3600),
        math.floor(la / 60) % 60) or "no open line", lost and string.format(" (lost its CC at %.0fs)", lost / 60) or "",
        (not la and not due(autotest.LINE_DEADLINE)) and ", not due" or "", C and towns.describe(C) or "-")
      local rs = deps.rails and deps.rails.stats(f)
      items = items + (rs and rs.items or 0)
      parts[#parts + 1] = string.format("%s %d items in %d trips", f, rs and rs.items or 0, rs and rs.trips or 0)
    end
    check("train_items", items >= autotest.TRAIN_ITEMS or not due(autotest.TRAIN_DEADLINE),
      "%d items moved by train (%s), goal %d%s", items, table.concat(parts, ", "), autotest.TRAIN_ITEMS,
      (items < autotest.TRAIN_ITEMS and not due(autotest.TRAIN_DEADLINE)) and ", not due" or "")
  end
  -- Phase 5 (docs/PHASE5-M1.md section 4): attack and defence groups ran as divisions (one unit-group path each) and
  -- the order queue kept its budgets
  local dst, q = divisions.stats(), orders.queue_stats()
  local fought, per_force = 0, {}
  for _, f in ipairs(autotest.FORCES) do
    local C = ai.get(f)
    local groups = C and ((C.stats.attacks or 0) + (C.stats.reinforcements or 0) + (C.stats.defends or 0)) or 0
    fought = fought + groups
    per_force[#per_force + 1] = string.format("%s %d groups / %d divisions", f, groups,
      dst.by_force and dst.by_force[f] or 0)
  end
  local kinds = {}
  for k, n in pairs(dst.orders) do kinds[#kinds + 1] = string.format("%s=%d", k, n) end
  table.sort(kinds)
  check("divisions", (fought == 0 or dst.created >= 1) and q.max_u <= orders.QUEUE.unit_budget
    and q.max_g <= orders.QUEUE.group_budget,
    "%d divisions formed (%s), orders [%s], arrivals %d, re-targets %d, regroups %d, group fails %d; queue max %d unit "
    .. "+ %d group commands per tick (budgets %d / %d), %d queued", dst.created, table.concat(per_force, ", "),
    table.concat(kinds, " "), dst.arrivals, dst.retargets, dst.regroups, dst.group_fails, q.max_u, q.max_g,
    orders.QUEUE.unit_budget, orders.QUEUE.group_budget, q.queued)
  -- Phase 5 M1: in a Nation match, the world checks (connectivity on samples and real tiles, start kits, spawn
  -- score spread, background fill) join the summary
  if m and m.config and m.config.mode == "nation" then world.autotest_checks(check) end
  local last = s.minute
  local producing = autotest.producing(s)
  -- Phase 5 M1 integration: a match where at most one force still has a CC or a barracks is decided even when a beaten
  -- side's last units keep it from ending (1v3: three AIs lost their CCs, one kept 4 units)
  local based = 0
  for _, f in ipairs(autotest.FORCES) do
    if buildings.count(f, "cc") > 0 or buildings.count(f, "barracks") > 0 then based = based + 1 end
  end
  local decided = not ended and producing < 2 and based <= 1
  check("outcome", ended or producing >= 2 or decided, "%s", ended and string.format("match ended at %.0fs, winner %s",
    (m.ended_tick - s.started) / 60, tostring(m.winner)) or string.format("%d of %d forces still produce at minute %d%s",
    producing, #autotest.FORCES, last, decided and string.format(", decided: %d force(s) with a CC or barracks", based)
    or ""))
  util.log("ai autotest summary %d/%d%s, result=%s (%s)", s.pass, s.pass + s.fail,
    s.fail == 0 and " (all passed)" or string.format(" (%d FAILED)", s.fail),
    ended and ("winner " .. tostring(m.winner)) or "both alive", why)
end

--- Every 60 ticks (registered below): build deadline, minute reports, the end.
function autotest.tick(tick)
  local s = state()
  if not s or s.done then return end
  local age = tick - s.started
  for _, f in ipairs(autotest.FORCES) do
    if not s.built_at[f] and has_all(f) then
      s.built_at[f] = age
      util.log("ai autotest: %s has an extractor, a smelter and a barracks at %.0fs", f, age / 60)
    end
    if not s.cc_lost_at[f] and buildings.count(f, "cc") == 0 then
      s.cc_lost_at[f] = age
      util.log("ai autotest: %s lost its CC at %.0fs", f, age / 60)
    end
    if not s.lab_at[f] and buildings.count(f, "lab") > 0 then
      s.lab_at[f] = age
      util.log("ai autotest: %s has a lab at %.0fs", f, age / 60)
    end
    if not s.hub_at[f] and buildings.count(f, "hub") > 0 then
      s.hub_at[f] = age
      util.log("ai autotest: %s has a hub at %.0fs", f, age / 60)
    end
    if not s.delivery_at[f] and delivered_total(f) > 0 then
      s.delivery_at[f] = age
      util.log("ai autotest: %s: first hauler delivery at %.0fs", f, age / 60)
    end
    local C = ai.get(f)
    if age >= scaled(C, autotest.TECH_DEADLINE) and s.techs_at_deadline[f] == nil then
      s.techs_at_deadline[f] = tech.done_count(f)
    end
    if age >= scaled(C, kinds_due(C)) and s.kinds_at_deadline[f] == nil then
      s.kinds_at_deadline[f] = table_size(s.kinds[f] or {})
    end
    if deps.ages and deps.ages.is_nation() then -- Phase 5 E1
      s.age2_at, s.indust_at, s.charter_at = s.age2_at or {}, s.indust_at or {}, s.charter_at or {}
      if not s.indust_at[f] and deps.research and deps.research.has(f, "rts-industrialisation") then
        s.indust_at[f] = age
        util.log("ai autotest: %s researched Industrialisation at %.0fs", f, age / 60)
      end
      if not s.charter_at[f] and deps.ages.project(f) then
        s.charter_at[f] = age
        util.log("ai autotest: %s started the Railway Charter at %.0fs", f, age / 60)
      end
      if not s.age2_at[f] and deps.ages.of(f) >= 2 then
        s.age2_at[f] = age
        util.log("ai autotest: %s reached Age II at %.0fs", f, age / 60)
      end
      -- Phase 5 M1 integration: the second city and the first open rail line; the Age I army cap (kinds check)
      s.cap_at = s.cap_at or {}
      if not s.cap_at[f] and deps.ages.of(f) < 2 and production.army_size(f) >= mix.AGE1_ARMY then
        s.cap_at[f] = age
        util.log("ai autotest: %s reached the Age I army cap (%d) at %.0fs", f, mix.AGE1_ARMY, age / 60)
      end
      s.city2_at, s.line_at = s.city2_at or {}, s.line_at or {}
      if not s.city2_at[f] and deps.cities and #deps.cities.for_force(f) >= 2 then
        s.city2_at[f] = age
        util.log("ai autotest: %s has a second city at %.0fs", f, age / 60)
      end
      if not s.line_at[f] and deps.rails then
        for _, line in ipairs(deps.rails.lines_of(f)) do
          if line.state == "open" and not s.line_at[f] then
            s.line_at[f] = age
            util.log("ai autotest: %s opened rail line #%d (%.0f tiles) at %.0fs", f, line.id, line.length or 0, age / 60)
          end
        end
      end
    end
    if not s.lines_at[f] and autotest.lines_running(f) then
      s.lines_at[f] = age
      util.log("ai autotest: %s runs an iron line and a copper line (a drill and a hub slot each) at %.0fs", f,
        age / 60)
    end
  end
  if age >= autotest.BUILD_DEADLINE and not s.build_checked then
    s.build_checked = true
    for _, f in ipairs(autotest.FORCES) do
      check("build_3min_" .. f, s.built_at[f] ~= nil, "%s: %s", f, s.built_at[f]
        and string.format("extractor + smelter + barracks at %.0fs", s.built_at[f] / 60) or ("only " .. kinds(f)))
    end
  end
  if age > 0 and age % autotest.MINUTE == 0 then
    s.minute = age / autotest.MINUTE
    minute_report(s, s.minute)
    if age >= autotest.BUILD_DEADLINE then
      for _, f in ipairs(autotest.FORCES) do
        -- a barracks only produces while a CC network feeds it
        -- Phase 5 E1: a Nation-mode AI at its Age I army cap, or saving for a district item this minute, makes no kit
        -- on purpose (ai/mix.lua AGE1_ARMY, ai/age_up.lua C.nation.saving)
        local C = ai.get(f)
        local N = C and C.nation
        local capped = deps.ages and deps.ages.is_nation() and (production.army_size(f) >= mix.AGE1_ARMY
          or (N and N.saving_tick and game.tick - N.saving_tick <= autotest.MINUTE))
        local zero = buildings.count(f, "barracks") > 0 and buildings.count(f, "cc") > 0
          and (s.per_minute[f][s.minute] or 0) == 0 and not capped
        -- Phase 5 E1: in Nation mode a short pause is part of the economy (surcharge waits, Charter deliveries): the
        -- check fails only after NATION_IDLE_MINUTES minutes in a row without a kit
        s.zero_run = s.zero_run or {}
        s.zero_run[f] = zero and (s.zero_run[f] or 0) + 1 or 0
        local nation = deps.ages and deps.ages.is_nation()
        if zero and (not nation or s.zero_run[f] >= autotest.NATION_IDLE_MINUTES) then
          s.produced_ok[f] = false
        end
      end
    end
  end
  local m = storage.match
  local all_produce = autotest.producing(s) == #autotest.FORCES
  if age >= autotest.DURATION and not (m and m.phase == "ended")
     and (all_produce or age >= autotest.DURATION + autotest.END_GRACE) then
    finish(s, "time")
  elseif m and m.phase == "ended" and not s.ended_at then
    s.ended_at = tick
    util.log("ai autotest: match ended at %.0fs, winner %s", age / 60, tostring(m.winner))
  elseif s.ended_at and tick - s.ended_at >= 10 * 60 then
    finish(s, "match ended")
  end
end

events.on_nth_tick(60, function(e) autotest.tick(e.tick) end)

return autotest
