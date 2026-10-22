-- Phase 5 M3 ai (perf): resumable AI planners (docs/qa/phase5-perf-notes.md section 7, open issue 1).
--
-- The AI's layout planners (a mining line with its satellites and belt routes, the start planning with its coal and
-- copper passes, forward hubs, the mining town, spot searches) are state machines over an explicit call stack. One
-- implementation serves both modes:
--   * planjob.sync(C, frame) runs a planner to the end at once (Skirmish, tests, any caller outside the scheduler);
--   * planjob.submit(C, kind, frame) runs it as a scheduler job (scripts/sched.lua, Nation mode): a few work units per
--     tick, its whole state plain data in storage (job.state = S below): no closure, no coroutine, no profiler value.
--
-- A planner is a table of named phases, planjob.define(name, phases [, finish]). A frame is {fn = name, pc = phase,
-- ...the planner's locals...}; S.stack holds the frames of the running calls and the top one runs:
--   phase(S, F, units) -> used
-- does a bounded piece of work (a phase may loop while it has used fewer than `units`; units is math.huge in a
-- synchronous run), then sets F.pc to the next phase, calls another planner (planjob.call: F resumes at the given phase
-- with the callee's results in F.r1, F.r2, F.r3) or returns (planjob.ret: pops F and hands up to three results to the
-- caller's frame, or to S.r1, S.r2, S.r3 at the root). Whatever lives across a phase boundary is a frame field, never a
-- Lua local. Work units are scripts/sched.lua's (about one microsecond of script time each on the dev Mac).
--
-- S = {force, stack = {frame, ...}, root = name of the root planner, tag = planjob.submit's, J = {[tile set name] =
--      {journal, ...}} (the write journals of layout.lua, innermost last: they span steps), sync = true in a synchronous
--      run, r1, r2, r3 (results), C = the commander, bound for the duration of one step (never left in storage)}
--
-- Nation mode. One planning job per commander at a time: C.planning = {id, kind, root, since, line?, hub?, town?, spot?,
-- spot_name?} is the mutex. While it is set, the job alone writes the commander's tile sets (C.reserved, C.avoid,
-- C.belt_tiles; its journals span steps): every planning call of the commander hears "pending" (planjob.busy) and asks
-- again later, ai/commander.lua skips the build order walk, and while the start lines are planned (their passes restore
-- the whole plan) also the rest of the economy slice, the age-up, the governors and the council. The callers that asked
-- for a plan (the build order, hubs, towns, the town site, the spot searches' callers) take the job's result on a later
-- call. The job kinds (sched minute lines): ai_start_plan (the start lines), ai_layout_plan (an expansion line),
-- ai_hub_plan (a forward hub), ai_town_plan (the mining town's site and line), ai_find_spot (a building spot:
-- layout.find_spot / find_spot_in). A job whose step raises ends "failed" (scripts/sched.lua logs it): its open journals
-- are undone and its finish marks the plan unavailable.
local util = require("scripts.util")
local sched = require("scripts.sched")

local planjob = {}

planjob.FN = {}   -- [planner name] = {[phase] = fn(S, F, units) -> used}
planjob.FIN = {}  -- [root planner name] = fn(S, C, status, job): hands a job's result to its owner (Nation mode)
planjob.KINDS = {"ai_start_plan", "ai_layout_plan", "ai_hub_plan", "ai_town_plan", "ai_find_spot"}
local FN = planjob.FN

--- Register a planner (file level, once per name). finish (optional): the result hand-over when it is a job's root.
function planjob.define(name, phases, finish)
  assert(type(name) == "string" and type(phases) == "table", "planjob.define(name, phases [, finish])")
  assert(not FN[name], "planjob.define: planner defined twice: " .. name)
  FN[name] = phases
  if finish then planjob.FIN[name] = finish end
end

--- Call planner `callee` (a frame {fn = name, ...arguments}); frame F resumes at phase `next_pc` with the results in
--- F.r1, F.r2, F.r3.
function planjob.call(S, F, next_pc, callee)
  F.pc = next_pc
  F.r1, F.r2, F.r3 = nil, nil, nil
  callee.pc = callee.pc or "start"
  S.stack[#S.stack + 1] = callee
end

--- Return from the top frame with up to three results.
function planjob.ret(S, a, b, c)
  local st = S.stack
  st[#st] = nil
  local P = st[#st] or S
  P.r1, P.r2, P.r3 = a, b, c
end

--- Run the stack until it is empty or `units` are spent. Returns the units spent and whether the planner returned.
function planjob.run(S, units)
  local st, used = S.stack, 0
  while true do
    local F = st[#st]
    if not F then return used, true end
    local phases = FN[F.fn]
    local h = phases and phases[F.pc]
    if not h then error(string.format("planjob: no phase %s.%s", tostring(F.fn), tostring(F.pc))) end
    local u = h(S, F, units - used) or 0
    used = used + (u >= 1 and u or 1)
    if used >= units then return used, #st == 0 end
  end
end

-- Binders: bind(S, C) -> token before a run, unbind(S, C, token) after it (layout.lua binds the tile-set journals).
local binders = {}
function planjob.binder(bind, unbind)
  binders[#binders + 1] = {bind, unbind}
end

local function traceback(err)
  return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err)
end

local running = 0 -- planner runs in progress (a planner never submits a job from inside a run)
local function bound_run(S, C, units)
  local prevC = S.C
  S.C = C
  local tokens = {}
  for i, b in ipairs(binders) do tokens[i] = b[1](S, C) end
  running = running + 1
  local ok, used, done = xpcall(planjob.run, traceback, S, units)
  running = running - 1
  for i = #binders, 1, -1 do binders[i][2](S, C, tokens[i]) end
  S.C = prevC
  if not ok then error(used, 0) end
  return used, done
end

--- Run planner `frame` to the end now for commander C. Returns its results.
function planjob.sync(C, frame)
  frame.pc = frame.pc or "start"
  local S = {force = C.force, stack = {frame}, root = frame.fn, J = {}, sync = true}
  bound_run(S, C, math.huge)
  return S.r1, S.r2, S.r3
end

--- True when commander C may plan on the scheduler: a Nation match with the scheduler on and C a live commander.
function planjob.async(C)
  return running == 0 and sched.enabled() and storage.ai ~= nil and storage.ai[C.force] == C
end

--- Submit planner `frame` as a job of `kind` for commander C and set the mutex (C.planning, with the fields of `tag`).
--- Returns the job id, or nil when the scheduler refuses (Skirmish: the caller runs planjob.sync instead).
function planjob.submit(C, kind, frame, tag, priority)
  frame.pc = frame.pc or "start"
  local S = {force = C.force, stack = {frame}, root = frame.fn, J = {}, tag = tag}
  local id = sched.submit(C.force, kind, S, priority or sched.NORMAL)
  if not id then return nil end
  local P = {id = id, kind = kind, root = frame.fn, since = game.tick}
  for k, v in pairs(tag or {}) do P[k] = v end
  C.planning = P
  return id
end

--- True while a planning job of commander C runs (the mutex; a job that vanished without its finish is forgotten).
function planjob.busy(C)
  local P = C.planning
  if not P then return false end
  local st = sched.status(P.id)
  if st == "queued" or st == "running" then return true end
  C.planning = nil
  return false
end

-- The scheduler step of every planning kind: run the job's stack for `units` (at most MAX_STEP: a lone job also gets
-- the tick's spare units, and one call stays about a millisecond) with its commander bound.
planjob.MAX_STEP = 1000
function planjob.step(job, units)
  local S = job.state
  local C = storage.ai and storage.ai[S.force]
  if not C then
    S.stack, S.gone = {}, true -- the commander was stopped: nothing to hand over
    return 1, true
  end
  return bound_run(S, C, math.min(units, planjob.MAX_STEP))
end

planjob.unwind = nil -- set by layout.lua: undo the open journals of a job that did not finish (failed, cancelled)

function planjob.finish(job, status)
  local S = job.state
  local C = storage.ai and storage.ai[S.force]
  if C and C.planning and C.planning.id == job.id then C.planning = nil end
  if not C or S.gone then return end
  if status ~= "done" and planjob.unwind and next(S.J or {}) ~= nil then planjob.unwind(S, C) end
  if status ~= "done" then
    util.log("ai %s: planning job #%d (%s) %s after %d units", S.force, job.id, tostring(S.root), status, job.units or 0)
  end
  local fin = planjob.FIN[S.root]
  if fin then fin(S, C, status, job) end
end

for _, kind in ipairs(planjob.KINDS) do
  -- (thin wrappers: the step and finish are looked up on the module at call time, so a test probe can wrap them)
  sched.register(kind, function(job, units) return planjob.step(job, units) end,
    function(job, status) return planjob.finish(job, status) end)
end

---------------------------------------------------------------------------
-- Resumable sort (bottom-up merge sort over plain arrays). With a comparator that is a strict total order (every sort
-- the planners do breaks its ties by position or id) the result is table.sort's.
---------------------------------------------------------------------------
planjob.CMP = {} -- [name] = less(a, b), registered at load

planjob.SORT_UNIT = 0.17 -- units per element moved in a merge

--- A frame that sorts array `arr` by comparator `cmp` (a planjob.CMP name) and returns the sorted array (a new one).
function planjob.sort_frame(arr, cmp)
  return {fn = "msort", src = arr, cmp = cmp}
end

planjob.define("msort", {
  start = function(S, F)
    local n = #F.src
    F.n, F.w = n, 1
    if n <= 1 then
      planjob.ret(S, F.src)
      return 1
    end
    F.dst, F.i = {}, 1
    F.pc = "merge"
    return 1
  end,
  -- merge the runs [i, i + w) and [i + w, i + 2w) of src into dst; one handler call merges until the units run out
  merge = function(S, F, units)
    local less = planjob.CMP[F.cmp]
    local src, dst, n, w = F.src, F.dst, F.n, F.w
    local used = 0
    local unit = planjob.SORT_UNIT
    while used < units do
      if not F.l then
        if F.i > n then
          -- the level is done
          F.src, F.dst = dst, src
          src, dst = F.src, F.dst
          F.w = w * 2
          w = F.w
          F.i = 1
          if w >= n then
            local out = F.src
            F.src, F.dst = nil, nil
            planjob.ret(S, out)
            return used + 1
          end
        else
          local i = F.i
          F.l, F.le = i, math.min(i + w, n + 1)
          F.r, F.re = F.le, math.min(i + 2 * w, n + 1)
          F.k = i
        end
      else
        local l, le, r, re, k = F.l, F.le, F.r, F.re, F.k
        local stop = k + math.max(1, math.floor((units - used) / unit))
        while k < re and k < stop do
          if r >= re or (l < le and not less(src[r], src[l])) then
            dst[k] = src[l]
            l = l + 1
          else
            dst[k] = src[r]
            r = r + 1
          end
          k = k + 1
        end
        used = used + (k - F.k) * unit
        F.l, F.r, F.k = l, r, k
        if k >= re then
          F.i = re
          F.l, F.le, F.r, F.re, F.k = nil, nil, nil, nil, nil
        end
      end
    end
    return used
  end,
})

return planjob
