-- Headless AI autotest (docs/PHASE3.md acceptance 2 and 4): both forces are AI commanders and fight for DURATION.
-- debug.lua starts it instead of the Phase 1/2 autotest when storage.match.config.enemy_brain == "ai".
--
-- Log lines:
--   [rts] ai autotest: started ...
--   [rts] ai minute N <force>: buildings [...] units N kits N walkers N (+N/min) known enemies N attacks N ...
--   [rts] ai perf minute N: ticks T, AI runs R, AI time <profiler>, wall clock <profiler>
--   [rts] ai autotest check <name>: PASS|FAIL ...
--   [rts] ai autotest summary <passed>/<total> ... result=...
-- Checks: planner_arena_half and planner_vertical_iron / _copper (autotest.planner_check: a base whose ore lies north
-- and south of the CC, as rotated spawns put it), build_3min (each force has an extractor, a smelter and a barracks by 3 min), produce (kits made in every
-- minute from minute 3 on while the force still has a barracks and a CC), attack (each force launched an attack by the end,
-- unless the match ended first or the force lost its CC first), outcome (the match ended, or at least two forces
-- still produce at the end; when a force stopped producing at DURATION, the test waits up to END_GRACE for the match
-- to end), no_bad_spam (fewer than 20 construction entries given up per force). FORCES is every match force (debug.lua
-- sets it); 1v1 is rts-player vs rts-ai-1.
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

local autotest = {}

autotest.DURATION = 6 * 60 * 60 -- test copies may set a longer one to see how long a match takes
autotest.MINUTE = 60 * 60
autotest.BUILD_DEADLINE = 3 * 60 * 60
autotest.END_GRACE = 60 * 60 -- at DURATION, a side that stopped producing gets this long for the match to end
autotest.FORCES = {util.PLAYER_FORCE, util.ENEMY_FORCE}
-- The player commander's difficulty; nil = the same as the enemy's (storage.match.config.enemy_difficulty), so
-- one setting runs easy-vs-easy, normal-vs-normal or hard-vs-hard.
autotest.PLAYER_DIFFICULTY = nil

-- Module-local wall clock (profilers are not game state).
local wall

local function state() return storage.ai_autotest end

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
             produced_ok = {}, done = false}
  storage.ai_autotest = s
  autotest.planner_check()
  local cfg = storage.match and storage.match.config
  local difficulty = autotest.PLAYER_DIFFICULTY or (cfg and cfg.enemy_difficulty) or "normal"
  for _, f in ipairs(autotest.FORCES) do
    if not ai.get(f) then ai.init_force(f, difficulty) end
    s.kits[f] = production.stats(f).kits
    s.per_minute[f] = {}
    s.produced_ok[f] = true
  end
  ai.reset_perf()
  wall = helpers.create_profiler()
  autotest.log_maps()
  util.log("ai autotest: started at tick %d, %s (%s) vs %s (%s), %d minutes", game.tick, autotest.FORCES[1],
    ai.get(autotest.FORCES[1]).difficulty, autotest.FORCES[2], ai.get(autotest.FORCES[2]).difficulty,
    autotest.DURATION / autotest.MINUTE)
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
  end
  util.log("ai minute %d match: phase=%s winner=%s", n, tostring(m and m.phase), tostring(m and m.winner))
  local p = ai.perf()
  if wall then
    wall.stop()
    log({"", string.format("[rts] ai perf minute %d: %d ticks, %d AI runs, AI time ", n, autotest.MINUTE, p.runs),
         p.ai, " | wall clock ", wall})
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
    check("attack_" .. f, (C and C.stats.attacks > 0) or ended or knocked_out,
      "%s launched %d attacks (%d reinforcements)%s", f, C and C.stats.attacks or 0, C and C.stats.reinforcements or 0,
      ended and ", match ended" or (knocked_out and ", lost its CC first" or ""))
    check("produce_" .. f, s.produced_ok[f], "%s kits per minute [%s]", f,
      table.concat(s.per_minute[f], " "))
    check("no_bad_spam_" .. f, (C and C.stats.bad or 0) < 20, "%s gave up on %d construction entries", f,
      C and C.stats.bad or 0)
  end
  local last = s.minute
  local producing = autotest.producing(s)
  check("outcome", ended or producing >= 2, "%s", ended and string.format("match ended at %.0fs, winner %s",
    (m.ended_tick - s.started) / 60, tostring(m.winner)) or string.format("%d of %d forces still produce at minute %d",
    producing, #autotest.FORCES, last))
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
        if buildings.count(f, "barracks") > 0 and buildings.count(f, "cc") > 0
           and (s.per_minute[f][s.minute] or 0) == 0 then
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
