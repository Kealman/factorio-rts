-- Phase 5 M3 perf: the work-unit scheduler (docs/PHASE5-M3.md D7, D9 and section 3 "sched.lua"; study
-- docs/research/scale/war-ai-performance.md 4.6; notes docs/qa/phase5-perf-notes.md).
--
-- Long computations (A* searches, region scoring, city layout, rail routing) run as resumable jobs: a job keeps its
-- whole state as plain data in storage.sched.jobs[id] and a step function registered per kind advances it by a number
-- of deterministic work units. One on_tick loop gives every nation a budget of units per tick and spends it on that
-- nation's jobs. Factorio's Lua has no coroutines and storage cannot hold closures, so a job is a state machine: open
-- and closed sets are arrays and maps of numbers, phases are strings, and the step function is looked up by kind on
-- every call (after a load too). Budgets are counted in work units, never wall clock (profilers differ between peers
-- and cannot be read as numbers): count the states expanded, cells scored, entities examined, and calibrate the unit
-- against PERF=1 (one unit is about 1 microsecond of script time on the dev Mac).
--
-- Nation mode only: in Skirmish (and outside a match) sched.submit refuses (nil, "not-nation"), so the Skirmish AI keeps
-- its synchronous code. sched.run_sync runs the same step function to the end at once: one implementation serves both.
--
-- API
--   sched.register(kind, step_fn [, finish_fn])      file level (load time), once per kind
--       step_fn(job, units) -> used, done
--           job     the job record (job.state is the caller's state table; job.id, job.force, job.kind, job.priority
--                   are the scheduler's: read only)
--           units   units this call may spend (>= 1)
--           used    units actually spent (it may overrun by one indivisible item: the overrun is charged to the next
--                   ticks of the nation as debt). A step that spends fewer units than offered and is not done yields:
--                   the scheduler moves on to the nation's next job (waiting for something: return 0, false).
--           done    true when the job is finished; the result stays in job.state
--       finish_fn(job, status) optional: called once when the job ends, status "done" | "cancelled" | "failed"
--           ("failed": step_fn raised an error; it is logged as "[rts] sched: Error ..." and the job is dropped). This
--           is where a job hands its result to its owner (the owner is named in job.state, never a closure).
--   sched.submit(force, kind, state, priority) -> job_id | nil, reason     priority: higher runs first (default
--           sched.NORMAL); equal priorities run in submission order. reason "not-nation" | "unknown-kind"
--   sched.cancel(job_id) -> true when it was queued or running
--   sched.status(job_id) -> "queued" | "running" | "done" | "cancelled" | "failed" | nil (unknown, or ended more than
--           sched.RETAIN ticks ago)
--   sched.get(job_id) -> the job record while it lives and sched.RETAIN ticks after it ended (job.state = the result)
--   sched.run_sync(kind, state, force) -> job        runs the step function until done in this tick (Skirmish path,
--           tests); nothing is stored, finish_fn is not called
--   sched.budget(force) -> units per tick: balance.nation.ai3.budget (default 400) x the difficulty factor of the
--           force's AI commander (balance.nation.ai3.difficulty[level].budget_factor, default 1; human nations 1)
--   sched.tick_cap() -> units a tick may spend in all once every nation had its budget: balance.nation.ai3.tick_cap
--           (default 2000)
--   sched.stats() -> {[force] = {jobs = live jobs, units_last_minute = n, ms_last_minute = LuaProfiler | nil}}
--           (ms_last_minute exists with PERF=1 only and, like every profiler, can only be logged)
--   sched.enabled() -> true while a Nation match runs
--
-- Rules: one on_tick loop; the nations with live jobs are served every tick, round-robin by index (the first one served
-- moves on by one each tick); each gets its whole budget; a nation's jobs run by priority, then id; unused units are
-- not carried over, overruns are (debt). The loop is work-conserving: what tick_cap leaves once every nation had its
-- budget goes, in the same order and shared equally, to the nations whose jobs wanted more (a job wants more when it
-- spent all it was offered and is not done), so a lone job runs at up to tick_cap units per tick; a nation in debt gets
-- no extra. Every minute (game.tick % 3600 == 0) a line per nation with activity:
--   [rts] sched: minute 12 rts-ai-1: 2 live, 3 ended, 41200 units (11.4 per tick, budget 400) | kinds: layout_route
--   38000 (2 ended), rails_survey 3200
-- and with PERF=1 (events.enable_profiling) the measured script time per nation and per kind:
--   [rts] sched: minute 12 time rts-ai-1 Duration: 41.2ms | layout_route Duration: 38.0ms | ...
--
-- Example job (a resumable count to n, 1 unit per number):
--   sched.register("count", function(job, units)
--     local s = job.state
--     local stop = math.min(s.n, s.i + units)
--     local used = stop - s.i
--     s.i = stop
--     return used, s.i >= s.n
--   end, function(job, status)
--     if status == "done" then util.log("counted to %d for %s", job.state.n, job.force) end
--   end)
--   local id = sched.submit("rts-ai-1", "count", {i = 0, n = 5000})   -- 13 ticks at 400 units per tick, 3 alone
--
-- storage.sched = {next_id, jobs = {[id] = job}, queues = {[force] = {job id, ...}} (priority desc, id asc), forces =
--   {force, ...} (order of first submit), debt = {[force] = units}, ended = {[id] = job}, live = n, minute = {[force] =
--   {units, ended, kinds = {[kind] = {units, ended}}}}, last = {[force] = units of the last minute}}
-- job = {id, force, kind, priority, state, status, submitted (tick), started (tick), ended (tick), units, steps}
local events = require("scripts.events")
local util = require("scripts.util")
local balance = require("balance")

local sched = {}

sched.NORMAL = 50
sched.URGENT = 100
sched.BACKGROUND = 10
sched.DEFAULT_BUDGET = 400
sched.DEFAULT_TICK_CAP = 2000 -- units a tick may spend in all once every nation had its budget (sched.tick_cap)
sched.RETAIN = 3600          -- ticks an ended job stays readable (sched.get, sched.status)
sched.MINUTE = 3600
sched.SYNC_UNITS = 1000000   -- units per call of sched.run_sync

local kinds = {}             -- [kind] = {step = fn, finish = fn | nil}; registered at load, identical on every peer

-- PERF=1 only: module-local profilers (never in storage, only logged)
local prof = nil             -- {force = {[force] = LuaProfiler}, kind = {[kind] = LuaProfiler}, lap = LuaProfiler}

local function S()
  local s = storage.sched
  if not s then
    s = {next_id = 1, jobs = {}, queues = {}, forces = {}, debt = {}, ended = {}, live = 0, minute = {}, last = {}}
    storage.sched = s
  end
  return s
end

--- Register the step function (and optional finish function) of a job kind. Load time only, once per kind.
function sched.register(kind, step_fn, finish_fn)
  assert(type(kind) == "string" and type(step_fn) == "function", "sched.register(kind, step_fn [, finish_fn])")
  assert(not kinds[kind], "sched.register: kind registered twice: " .. kind)
  kinds[kind] = {step = step_fn, finish = finish_fn}
end

function sched.enabled()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation" and m.phase ~= "ended"
end

function sched.budget(force)
  local ai3 = balance.nation and balance.nation.ai3 or {}
  local base = ai3.budget or sched.DEFAULT_BUDGET
  local C = storage.ai and storage.ai[force]
  local level = C and C.difficulty
  local d = level and ai3.difficulty and ai3.difficulty[level]
  local factor = d and d.budget_factor or 1
  return math.max(1, math.floor(base * factor))
end

local function queue_insert(q, jobs, job)
  local i = #q + 1
  while i > 1 do
    local prev = jobs[q[i - 1]]
    if prev.priority > job.priority or (prev.priority == job.priority and prev.id < job.id) then break end
    q[i] = q[i - 1]
    i = i - 1
  end
  q[i] = job.id
end

local function minute_rec(s, force)
  local m = s.minute[force]
  if not m then
    m = {units = 0, ended = 0, kinds = {}}
    s.minute[force] = m
  end
  return m
end

--- Submit a job. Returns the job id, or nil and a reason ("not-nation": Skirmish never schedules; "unknown-kind").
function sched.submit(force, kind, state, priority)
  if not sched.enabled() then return nil, "not-nation" end
  if not kinds[kind] then return nil, "unknown-kind" end
  local force_name = type(force) == "string" and force or force.name
  local s = S()
  local id = s.next_id
  s.next_id = id + 1
  local job = {id = id, force = force_name, kind = kind, priority = priority or sched.NORMAL, state = state or {},
               status = "queued", submitted = game.tick, units = 0, steps = 0}
  s.jobs[id] = job
  local q = s.queues[force_name]
  if not q then
    q = {}
    s.queues[force_name] = q
    s.forces[#s.forces + 1] = force_name
  end
  queue_insert(q, s.jobs, job)
  s.live = s.live + 1
  return id
end

local function remove_from_queue(s, job)
  local q = s.queues[job.force]
  if not q then return end
  for i = 1, #q do
    if q[i] == job.id then
      table.remove(q, i)
      return
    end
  end
end

local function finish(s, job, status)
  remove_from_queue(s, job)
  s.jobs[job.id] = nil
  s.live = s.live - 1
  job.status, job.ended = status, game.tick
  s.ended[job.id] = job
  local m = minute_rec(s, job.force)
  m.ended = m.ended + 1
  local mk = m.kinds[job.kind]
  if mk then mk.ended = (mk.ended or 0) + 1 else m.kinds[job.kind] = {units = 0, ended = 1} end
  local k = kinds[job.kind]
  if k and k.finish then
    local ok, err = pcall(k.finish, job, status)
    if not ok then util.log("sched: Error in the finish of job #%d (%s, %s): %s", job.id, job.kind, job.force, err) end
  end
end

function sched.cancel(job_id)
  local s = storage.sched
  local job = s and s.jobs[job_id]
  if not job then return false end
  finish(s, job, "cancelled")
  return true
end

function sched.get(job_id)
  local s = storage.sched
  if not s then return nil end
  return s.jobs[job_id] or s.ended[job_id]
end

function sched.status(job_id)
  local job = sched.get(job_id)
  return job and job.status or nil
end

--- Run a job of `kind` to the end in this tick (the Skirmish path and tests). Returns the job record.
function sched.run_sync(kind, state, force)
  local k = kinds[kind]
  assert(k, "sched.run_sync: unknown kind " .. tostring(kind))
  local job = {id = 0, force = force, kind = kind, priority = sched.NORMAL, state = state or {}, status = "running",
               submitted = game.tick, units = 0, steps = 0}
  local guard = 0
  while true do
    local used, done = k.step(job, sched.SYNC_UNITS)
    job.units = job.units + (used or 0)
    job.steps = job.steps + 1
    if done then break end
    guard = guard + 1
    if guard > 10000 and (used or 0) <= 0 then error("sched.run_sync: job " .. kind .. " makes no progress") end
  end
  job.status = "done"
  return job
end

function sched.stats()
  local s = storage.sched
  local out = {}
  if not s then return out end
  for _, force in ipairs(s.forces) do
    local q = s.queues[force]
    out[force] = {jobs = q and #q or 0, units_last_minute = s.last[force] or 0,
                  ms_last_minute = prof and prof.last and prof.last[force] or nil}
  end
  return out
end

---------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------
local function profiler(tbl, key)
  local p = tbl[key]
  if not p then
    p = helpers.create_profiler(true)
    tbl[key] = p
  end
  return p
end

-- Spend one nation's budget on its queue.
-- Spend `budget` units on one nation's queue. Returns the units spent and whether the nation wants more this tick (its
-- last job spent all it was offered and is not done, or jobs were left when the units ran out).
local function serve(s, force, budget)
  local q = s.queues[force]
  if not q or #q == 0 then return 0, false end
  local m = minute_rec(s, force)
  local spent, hungry = 0, false
  -- the jobs of this tick, in queue order (a step may submit or cancel jobs)
  local ids = {}
  for i = 1, #q do ids[i] = q[i] end
  for _, id in ipairs(ids) do
    local offer = budget - spent
    if offer <= 0 then
      hungry = s.jobs[id] ~= nil
      break
    end
    local job = s.jobs[id]
    if job then
      local k = kinds[job.kind]
      if not k then
        util.log("sched: Error: job #%d of %s has an unregistered kind %s; dropped", id, force, tostring(job.kind))
        finish(s, job, "failed")
      else
        if job.status == "queued" then
          job.status, job.started = "running", game.tick
        end
        local lap
        if prof then
          lap = prof.lap
          lap.reset()
        end
        local ok, used, done = pcall(k.step, job, offer)
        if lap then
          lap.stop()
          profiler(prof.force, force).add(lap)
          profiler(prof.kind, job.kind).add(lap)
        end
        if not ok then
          util.log("sched: Error in job #%d (%s, %s): %s", id, job.kind, force, tostring(used))
          finish(s, job, "failed")
          hungry = false
        else
          used = math.max(0, math.floor(used or 0))
          job.units = job.units + used
          job.steps = job.steps + 1
          m.units = m.units + used
          local mk = m.kinds[job.kind]
          if mk then mk.units = mk.units + used else m.kinds[job.kind] = {units = used, ended = 0} end
          if used > offer then s.debt[force] = (s.debt[force] or 0) + (used - offer) end
          spent = spent + used
          if done then
            finish(s, job, "done")
            hungry = false
          else
            -- it spent everything: it would take more; it spent less: it yields, the next job gets the rest
            hungry = used >= offer
          end
        end
      end
    end
  end
  return spent, hungry
end

-- Phase 5 M3 perf (lead request): the loop is work-conserving. Every nation with jobs first gets its own budget; what
-- the tick cap leaves after that goes to the nations whose jobs wanted more, in the same order, shared equally. A lone
-- job (a rail survey while no planner runs) so moves at up to TICK_CAP units per tick instead of its nation's budget;
-- a busy tick of every nation stays at the sum of the budgets. A nation in debt gets no extra.
function sched.tick_cap()
  local ai3 = balance.nation and balance.nation.ai3 or {}
  return ai3.tick_cap or sched.DEFAULT_TICK_CAP
end

events.on(defines.events.on_tick, function(e)
  local s = storage.sched
  if not s or s.live == 0 then return end
  local n = #s.forces
  local first = e.tick % n
  local used_total, hungry = 0, {}
  for i = 0, n - 1 do
    local force = s.forces[(first + i) % n + 1]
    local q = s.queues[force]
    if q and #q > 0 then
      local budget = sched.budget(force)
      local debt = s.debt[force]
      if debt and debt >= budget then
        s.debt[force] = debt - budget
      else
        if debt then
          budget = budget - debt
          s.debt[force] = nil
        end
        local used, more = serve(s, force, budget)
        used_total = used_total + used
        if more then hungry[#hungry + 1] = force end
      end
    end
  end
  local left = sched.tick_cap() - used_total
  for i, force in ipairs(hungry) do
    if left <= 0 then break end
    local share = math.floor(left / (#hungry - i + 1))
    if share > 0 and not s.debt[force] then
      local used = serve(s, force, share)
      left = left - used
    end
  end
end)

-- Minute summary, retention of ended jobs, the PERF profilers.
events.on_nth_tick(sched.MINUTE, function(e)
  local s = storage.sched
  if events.profiling and events.profiling() then
    if not prof then prof = {force = {}, kind = {}, lap = helpers.create_profiler(true), last = {}} end
  else
    prof = nil
  end
  if not s then return end
  local minute = math.floor(e.tick / sched.MINUTE)
  for _, force in ipairs(s.forces) do
    local m = s.minute[force]
    local q = s.queues[force]
    s.last[force] = m and m.units or 0
    if m and (m.units > 0 or m.ended > 0) then
      local names = {}
      for kind in pairs(m.kinds) do names[#names + 1] = kind end
      table.sort(names)
      local parts = {}
      for _, kind in ipairs(names) do
        local mk = m.kinds[kind]
        parts[#parts + 1] = string.format("%s %d%s", kind, mk.units, mk.ended > 0 and
          string.format(" (%d ended)", mk.ended) or "")
      end
      util.log("sched: minute %d %s: %d live, %d ended, %d units (%.1f per tick, budget %d) | kinds: %s", minute, force,
        q and #q or 0, m.ended, m.units, m.units / sched.MINUTE, sched.budget(force), table.concat(parts, ", "))
      if prof and prof.force[force] then
        local p = prof.force[force]
        local line = {"", string.format("[rts] sched: minute %d time %s ", minute, force), p}
        for _, kind in ipairs(names) do
          local pk = prof.kind[kind]
          if pk and #line < 18 then
            line[#line + 1] = string.format(" | %s ", kind)
            line[#line + 1] = pk
          end
        end
        log(line)
        prof.last[force] = p
      end
    end
  end
  s.minute = {}
  if prof then
    prof.force, prof.kind = {}, {}
  end
  for id, job in pairs(s.ended) do
    if e.tick - (job.ended or 0) > sched.RETAIN then s.ended[id] = nil end
  end
end)

local function reset(why)
  local s = storage.sched
  if not s then return end
  local ids = {}
  for id in pairs(s.jobs) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local job = s.jobs[id]
    if job then finish(s, job, "cancelled") end
  end
  if #ids > 0 then util.log("sched: %s: %d jobs cancelled", why, #ids) end
  storage.sched = nil
end

-- A match teardown (restart, lobby, new match) cancels every job; the next match starts from an empty scheduler.
do
  local ok, match = pcall(require, "scripts.match")
  if ok and type(match) == "table" and match.on_teardown then
    match.on_teardown(function() reset("teardown") end)
  end
end

return sched
