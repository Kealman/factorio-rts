-- Phase 5 M3 perf: functional test of scripts/sched.lua (test copy only, tools/autotest-run.sh EXTRA_LUA) on a Nation
-- match:
--   EXTRA_LUA=tools/probes/perf_sched.lua STOP_ON="perf sched summary" tools/autotest-run.sh ps-1 \
--     '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 600
-- and across a save and load (the long job is in flight when the server quits at the AI autotest's minute 1):
--   EXTRA_LUA=tools/probes/perf_sched.lua SAVE_MINUTE=1 tools/saveload-check.sh ps-sl '<same table>' 120
-- Five seconds after the match start it submits, for every match force: a NORMAL count of 4000 units, then an URGENT
-- count of 1000 (must end first), a BACKGROUND count of 800 cancelled at once, and a long count (budget x 60 x 90 units,
-- about 90 s) that spans the save; for the first force also a job that overruns its budget 3x per call (debt: two idle
-- ticks after each call), a job that yields until 2 s later while a lower job runs, and a job whose step raises (status
-- "failed", logged as "[rts] sched: Error ..." on purpose). Checks: per-tick units <= budget, completion order and
-- ticks, statuses, finish callbacks, debt spacing, yield hand-over, run_sync, stats, the long job's total after a load.
-- Log: "[rts] perf sched check <name>: PASS|FAIL ..." and "[rts] perf sched summary <passed>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local sched = require("scripts.sched")
local layout = require("scripts.ai.layout")

-- a wall at x = 10 (y -12..12) with a gap at y = 8, between (0, 0) and (20, 0)
local function maze()
  local set = {}
  for y = -12, 12 do
    if y ~= 8 then set[layout.tkey(10, y)] = true end
  end
  return set
end

local function P()
  storage.perf_sched = storage.perf_sched or {checks = {pass = 0, fail = 0}, per_tick = {}, done = {}, finished = {},
                                              overrun_ticks = {}, yield_calls = 0, low_while_yield = 0}
  return storage.perf_sched
end

local function check(name, ok, fmt, ...)
  local p = P()
  if ok then p.checks.pass = p.checks.pass + 1 else p.checks.fail = p.checks.fail + 1 end
  util.log("perf sched check %s: %s " .. (fmt or ""), name, ok and "PASS" or "FAIL", ...)
end

local function count_step(job, units)
  local s = job.state
  local stop = math.min(s.n, s.i + units)
  local used = stop - s.i
  s.i = stop
  local pt = P().per_tick
  local key = job.force .. "@" .. game.tick
  pt[key] = (pt[key] or 0) + used
  if s.watch_low then P().low_while_yield = P().low_while_yield + 1 end
  return used, s.i >= s.n
end

sched.register("perf_count", count_step, function(job, status)
  local p = P()
  p.finished[job.id] = {status = status, tick = game.tick, i = job.state.i, n = job.state.n}
  if job.state.long and status == "done" then
    util.log("perf sched long job #%d of %s done at tick %d: %d of %d units in %d steps", job.id, job.force, game.tick,
      job.state.i, job.state.n, job.steps)
  end
end)

sched.register("perf_overrun", function(job, units)
  local s = job.state
  s.calls = s.calls + 1
  P().overrun_ticks[#P().overrun_ticks + 1] = game.tick
  return units * 3, s.calls >= 3
end)

sched.register("perf_yield", function(job, units)
  local s = job.state
  P().yield_calls = P().yield_calls + 1
  if game.tick >= s.until_tick then return 1, true end
  return 0, false
end)

sched.register("perf_fail", function(job, units)
  error("perf_sched: this step fails on purpose")
end, function(job, status)
  P().finished[job.id] = {status = status, tick = game.tick}
end)

local function start()
  local p = P()
  p.started = game.tick
  p.forces = {}
  for _, f in ipairs(match.forces()) do p.forces[#p.forces + 1] = f end
  p.jobs = {}
  for _, f in ipairs(p.forces) do
    local budget = sched.budget(f)
    local j = {}
    j.a = sched.submit(f, "perf_count", {i = 0, n = 4000})
    j.b = sched.submit(f, "perf_count", {i = 0, n = 1000}, sched.URGENT)
    j.c = sched.submit(f, "perf_count", {i = 0, n = 800}, sched.BACKGROUND)
    j.c_cancelled = sched.cancel(j.c)
    -- every force wants more all the time: each gets about tick_cap / forces per tick, so this lasts about 90 s
    local rate = math.max(budget, math.floor(sched.tick_cap() / #p.forces))
    j.long = sched.submit(f, "perf_count", {i = 0, n = rate * 60 * 90, long = true}, sched.BACKGROUND - 5)
    j.budget = budget
    p.jobs[f] = j
  end
  local f1 = p.forces[1]
  p.route_job = layout.submit_route(p.forces[#p.forces], {sx = 0, sy = 0, gx = 20, gy = 0, blocked = maze()})
  p.jobs[f1].over = sched.submit(f1, "perf_overrun", {calls = 0}, sched.URGENT + 10)
  p.jobs[f1].yield = sched.submit(f1, "perf_yield", {until_tick = game.tick + 120}, sched.URGENT + 20)
  p.jobs[f1].fail = sched.submit(f1, "perf_fail", {}, sched.URGENT + 30)
  util.log("perf sched: jobs submitted at tick %d for %s (budget %d)", game.tick, table.concat(p.forces, ", "),
    p.jobs[f1].budget)
end

local function evaluate()
  local p = P()
  local f1 = p.forces[1]
  for _, f in ipairs(p.forces) do
    local j = p.jobs[f]
    local fa, fb = p.finished[j.a], p.finished[j.b]
    check("urgent_first_" .. f, fa and fb and fb.tick < fa.tick, "urgent ended at +%s, normal at +%s",
      fb and (fb.tick - p.started) or "-", fa and (fa.tick - p.started) or "-")
    check("results_" .. f, fa and fb and fa.i == 4000 and fb.i == 1000 and sched.status(j.a) == "done",
      "normal %s/4000, urgent %s/1000, status %s", fa and fa.i or "-", fb and fb.i or "-", tostring(sched.status(j.a)))
    check("cancel_" .. f, j.c_cancelled and sched.status(j.c) == "cancelled" and p.finished[j.c]
      and p.finished[j.c].status == "cancelled" and p.finished[j.c].i == 0, "cancelled %s, status %s",
      tostring(j.c_cancelled), tostring(sched.status(j.c)))
    local worst = 0
    for key, n in pairs(p.per_tick) do
      if string.sub(key, 1, #f + 1) == f .. "@" and n > worst then worst = n end
    end
    check("per_tick_budget_" .. f, worst <= sched.tick_cap(), "worst tick %d units (budget %d, tick cap %d)", worst,
      j.budget, sched.tick_cap())
    if f ~= f1 then
      -- 5000 units: at least the budget every tick (13 ticks at 400), more while the tick cap leaves units over
      local ticks = fa and (fa.tick - p.started) or -1
      local least = math.ceil(5000 / sched.tick_cap())
      check("normal_ticks_" .. f, ticks >= least and ticks <= 14, "normal job ended %d ticks after submission", ticks)
    end
  end
  -- the loop is work-conserving: all forces together never above max(tick cap, sum of budgets); with units left over
  -- by the cap, a force got more than its budget
  local per, sum_budget, extra = {}, 0, false
  for _, f in ipairs(p.forces) do sum_budget = sum_budget + p.jobs[f].budget end
  for key, n in pairs(p.per_tick) do
    local f, t = string.match(key, "^(.*)@(%d+)$")
    per[t] = (per[t] or 0) + n
    if p.jobs[f] and n > p.jobs[f].budget then extra = true end
  end
  local worst_total = 0
  for _, n in pairs(per) do if n > worst_total then worst_total = n end end
  check("tick_cap", worst_total <= math.max(sched.tick_cap(), sum_budget) and (extra or sched.tick_cap() <= sum_budget),
    "worst tick of all forces %d units (cap %d, budgets %d), extra units given: %s", worst_total, sched.tick_cap(),
    sum_budget, tostring(extra))
  local ot = p.overrun_ticks
  check("debt_spacing", #ot == 3 and ot[2] - ot[1] == 3 and ot[3] - ot[2] == 3, "overrun calls at %s",
    table.concat(ot, ", "))
  check("yield_handover", p.yield_calls >= 100 and sched.status(p.jobs[f1].yield) == "done"
    and p.finished[p.jobs[f1].a] ~= nil, "yield step called %d times; the normal job of %s ended at +%s",
    p.yield_calls, f1, p.finished[p.jobs[f1].a] and (p.finished[p.jobs[f1].a].tick - p.started) or "-")
  check("failed_job", sched.status(p.jobs[f1].fail) == "failed" and p.finished[p.jobs[f1].fail]
    and p.finished[p.jobs[f1].fail].status == "failed", "status %s", tostring(sched.status(p.jobs[f1].fail)))
  local rj = sched.get(p.route_job)
  local bl = maze()
  local sync = layout.route({ore = {}}, 0, 0, nil, 20, 0, function(tx, ty) return bl[layout.tkey(tx, ty)] == true end)
  local same = rj and rj.status == "done" and rj.state.R.path and sync and #rj.state.R.path == #sync
  if same then
    for i, t in ipairs(sync) do
      if rj.state.R.path[i][1] ~= t[1] or rj.state.R.path[i][2] ~= t[2] then same = false end
    end
  end
  check("layout_route_job", same, "job %s, %s tiles (sync %s tiles), %d units in %d steps", rj and rj.status or "-",
    rj and rj.state.R and rj.state.R.path and #rj.state.R.path or "-", sync and #sync or "-", rj and rj.units or 0,
    rj and rj.steps or 0)
  local job = sched.run_sync("perf_count", {i = 0, n = 5000}, f1)
  check("run_sync", job.state.i == 5000 and job.status == "done" and job.steps == 1, "i %d, %d steps", job.state.i,
    job.steps)
  check("not_in_storage", sched.get(0) == nil, "run_sync jobs are never stored")
end

events.on_nth_tick(60, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started and m.config and m.config.mode == "nation") then return end
  local p = P()
  if not p.started and game.tick - m.tick_started >= 300 then
    start()
    return
  end
  if p.started and not p.evaluated and game.tick - p.started >= 240 then
    p.evaluated = true
    evaluate()
  end
  if p.started and not p.stats_checked and game.tick - p.started >= 3700 then
    p.stats_checked = true
    local st = sched.stats()[p.forces[1]]
    check("stats", st and st.units_last_minute > 0 and st.jobs >= 1, "jobs %s, units last minute %s",
      st and st.jobs or "-", st and st.units_last_minute or "-")
  end
  -- the long jobs end about 90 s after submission (after a load too)
  if p.started and not p.long_checked then
    local all, ok = true, true
    for _, f in ipairs(p.forces) do
      local fin = p.finished[p.jobs[f].long]
      if not fin then all = false elseif fin.status ~= "done" or fin.i ~= fin.n then ok = false end
    end
    if all then
      p.long_checked = true
      check("long_jobs", ok, "%d long jobs ended %d ticks after submission", #p.forces, game.tick - p.started)
      util.log("perf sched summary %d/%d", p.checks.pass, p.checks.pass + p.checks.fail)
    end
  end
end)

return {}
