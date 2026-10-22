-- AI build order (docs/PHASE3.md "ai/build_order.lua"): runs the data-driven step list of ai/orders_data.lua.
--
-- Each commander run walks the steps in order:
--   * a satisfied step is skipped (a "build" step whose buildings died becomes unsatisfied again);
--   * an unsatisfied step whose work is still queued counts as in progress;
--   * an unsatisfied step whose `when` holds is executed (queues its work) and counts as in progress;
--   * an unsatisfied step whose `when` does not hold is skipped, but at most LOOKAHEAD of those are passed over.
-- The walk stops at cfg.max_in_progress steps in progress, so a few steps overlap and the queue stays short.
-- Phase 4: the order is data.order(difficulty, doctrine). Before the walk, a lost factory or barracks is rebuilt
-- first (build_order.priority: its entry moves to the front of the construction queue, so the factory makes its
-- item next). Other modules add step kinds through build_order.KINDS[kind] = {satisfied, in_progress, execute,
-- describe} (ai/hubs.lua: "hub").
--
-- Mining lines (C.lines[name]) are planned by ai/layout.lua once: the START_LINES when the commander starts, an
-- expansion line when its step runs. A line holds the plan keys of its parts:
--   {name, ore, status = "ok" | "unavailable", reason?, patch, chained,
--    belts = {[seg] = {key, ...}} (seg 0 = spine through the patch, seg k = belt up to slot k's feed tile),
--    drills = {{key, g}, ...} best first, gap_poles = {[g] = key}, chain = {key, ...},
--    slots = {{name, keys = {key, ...}, seg}, ...}}
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local units = require("scripts.units")
local data = require("scripts.ai.orders_data")
local layout = require("scripts.ai.layout")
local construction = require("scripts.ai.construction")
local deps = require("scripts.ai.deps")
local planjob = require("scripts.ai.planjob") -- Phase 5 M3 ai (perf): line planning as a resumable planner

local build_order = {}

build_order.LOOKAHEAD = 2           -- unaffordable steps passed over before the walk stops
build_order.RETRY_TICKS = 10 * 60   -- a step that found no spot tries again after this long
build_order.BASE_COUNT_RADIUS = 32  -- "cc" / "front" build steps count buildings this close to the CC
build_order.KINDS = {}              -- extra step kinds (see the header)

---------------------------------------------------------------------------
-- Lines
---------------------------------------------------------------------------
-- Spawns and CCs of every other force: patches near them are theirs.
local function hostile_positions(C)
  local list = {}
  local m = storage.match
  for force_name, pos in pairs(m and m.spawns or {}) do
    if force_name ~= C.force then list[#list + 1] = {x = pos.x, y = pos.y} end
  end
  for _, rec in buildings.all("cc") do
    if rec.force ~= C.force then list[#list + 1] = rec.position end
  end
  return list
end

--- Plan line `name` (orders_data.LINES, or `spec`) for commander C with planning context ctx, into `sink` (default
--- the CC, see layout.lua). Idempotent.
--- Phase 5 M3 ai (perf): the planner "bo_line" (ai/planjob.lua) run to the end: line_begin, layout's "plan_line",
--- line_commit; build_order.plan_line_async plans an expansion line as a scheduler job in Nation mode.
function build_order.plan_line(C, ctx, name, spec, sink)
  return planjob.sync(C, build_order.line_frame(ctx, name, spec, sink))
end

--- A frame of the planner "bo_line". ctx nil: it reads its own context around the CC (on `surface`).
function build_order.line_frame(ctx, name, spec, sink, surface)
  return {fn = "bo_line", ctx = ctx, name = name, spec = spec, sink = sink, surface = surface}
end

-- The line record before layout's planner: the line itself when it exists or has no spec, else nil and the spec.
local function line_begin(C, name, spec)
  if C.lines[name] then return C.lines[name] end
  spec = spec or data.line_spec(name, deps.ages ~= nil and deps.ages.is_nation()) -- Phase 5 M1: Nation line specs
  local L = {name = name, ore = spec and spec.ore}
  C.lines[name] = L
  if not spec then
    L.status, L.reason = "unavailable", "no such line"
    return L
  end
  return L, spec
end

-- The line record after layout's planner: plan entries for its parts (or the reason it is unavailable).
local function line_commit(C, L, plan, reason)
  local name = L.name
  if not plan then
    L.status, L.reason = "unavailable", reason
    util.log("ai %s: line %s unavailable: %s", C.force, name, reason)
    return L
  end
  if #plan.slots == 0 then
    L.status, L.reason = "unavailable", "no hub slot reachable for " .. plan.patch.id
    util.log("ai %s: line %s unavailable: %s", C.force, name, L.reason)
    return L
  end
  L.status, L.patch, L.chained = "ok", plan.patch, plan.chained
  L.belts, L.drills, L.gap_poles, L.chain, L.slots = {}, {}, {}, {}, {}
  for _, b in ipairs(plan.belts) do
    local key = construction.add(C, {name = layout.BELT, x = b.x, y = b.y, dir = b.dir, line = name})
    L.belts[b.seg] = L.belts[b.seg] or {}
    table.insert(L.belts[b.seg], key)
  end
  for _, d in ipairs(plan.drills) do
    L.drills[#L.drills + 1] = {key = construction.add(C, {name = layout.DRILL, x = d.x, y = d.y, dir = d.dir,
                                                         line = name}), g = d.g}
  end
  for g, p in pairs(plan.gap_poles) do
    L.gap_poles[g] = construction.add(C, {name = layout.POLE, x = p.x, y = p.y, line = name})
  end
  for _, p in ipairs(plan.chain) do
    L.chain[#L.chain + 1] = construction.add(C, {name = layout.POLE, x = p.x, y = p.y, line = name})
  end
  for _, s in ipairs(plan.slots) do
    local keys = {}
    for _, sp in ipairs(s.specs) do
      keys[#keys + 1] = construction.add(C, {name = sp.name, x = sp.x, y = sp.y, dir = sp.dir, line = name,
                                             part = sp.part, pickup = sp.pickup})
    end
    L.slots[#L.slots + 1] = {name = s.name, keys = keys, seg = s.seg}
  end
  local nbelts = 0
  for _, list in pairs(L.belts) do nbelts = nbelts + #list end
  local slot_names = {}
  for i, s in ipairs(L.slots) do slot_names[i] = s.name end
  util.log("ai %s: line %s planned on %s (%d ore tiles at %s): %d belts, %d drill spots, %d gap poles, "
    .. "%d chain poles%s, hub slots [%s]", C.force, name, L.patch.id, L.patch.count,
    util.pos_str({L.patch.cx, L.patch.cy}), nbelts, #L.drills, table_size(L.gap_poles), #L.chain,
    L.chained and "" or " (NOT connected to the CC)", table.concat(slot_names, " "))
  return L
end

planjob.define("bo_line", {
  start = function(S, F)
    if F.ctx then
      F.pc = "begin"
      return 1
    end
    planjob.call(S, F, "got_ctx", layout.context_frame(F.surface, S.C.frame, layout.PATCH_SEARCH))
    return 1
  end,
  got_ctx = function(S, F)
    F.ctx = F.r1
    F.pc = "begin"
    return 1
  end,
  begin = function(S, F)
    local C = S.C
    local L, spec = line_begin(C, F.name, F.spec)
    if not spec then
      planjob.ret(S, L)
      return 5
    end
    F.L = L
    planjob.call(S, F, "planned", layout.line_frame(F.ctx, F.name, spec, hostile_positions(C), F.sink))
    return 10
  end,
  planned = function(S, F)
    local plan = F.r1
    local L = line_commit(S.C, F.L, plan, F.r2)
    planjob.ret(S, L)
    local parts = 0
    for _, sl in ipairs(plan and plan.slots or {}) do parts = parts + #sl.specs end
    return 40 + (plan and (6 * #plan.belts + 20 * #plan.drills + 20 * parts) or 0)
  end,
}, function(S, C, status)
  -- an expansion line planned as a job: one that did not finish is unavailable (its step is skipped, nothing retries)
  local F = S.stack[1] or {}
  local L = C.lines[F.name or ""]
  if status ~= "done" and L and not L.status then
    L.status, L.reason = "unavailable", "planning job " .. status
  end
end)

--- Phase 5 M3 ai (perf): line `name` for the build order. In Nation mode with the scheduler on, a line not planned yet
--- is planned by a job (kind ai_layout_plan, C.planning.line = name): nil now, the line once the job ended (the
--- commander's economy slice waits meanwhile). Otherwise build_order.plan_line now, with get_ctx()'s context.
function build_order.plan_line_async(C, get_ctx, name, surface)
  if C.lines[name] then return C.lines[name] end
  if planjob.async(C) then
    if planjob.busy(C) then return nil end
    if planjob.submit(C, "ai_layout_plan", build_order.line_frame(nil, name, nil, nil, surface), {line = name}) then
      return nil
    end
  end
  return build_order.plan_line(C, get_ctx(), name)
end

-- true while a planning job plans line `name`
local function line_planning(C, name)
  local P = C.planning
  return P ~= nil and P.line == name and planjob.busy(C)
end

local function queue_list(C, list)
  for _, key in ipairs(list or {}) do construction.queue(C, key) end
end
build_order.queue_list = queue_list

--- Number of the line's drills that are built.
function build_order.line_drills_built(C, L)
  local n = 0
  for _, d in ipairs(L.drills or {}) do
    if construction.is_built(C, d.key) then n = n + 1 end
  end
  return n
end

--- Number of the line's hub slots whose entities are all built.
function build_order.line_slots_built(C, L)
  local n = 0
  for _, s in ipairs(L.slots or {}) do
    local all = true
    for _, key in ipairs(s.keys) do
      if not construction.is_built(C, key) then all = false break end
    end
    if all then n = n + 1 end
  end
  return n
end

local function line_busy(C, L)
  for _, key in ipairs(C.queue) do
    local e = C.plan[key]
    if e and e.line == L.name then return true end
  end
  return false
end
build_order.line_busy = line_busy

-- Queue drills until `n` are built or queued: the spine, the belt to the first slot, the poles, then the drills.
local function want_drills(C, L, n)
  local have, min_g = 0, nil
  local wanted = {}
  for _, d in ipairs(L.drills) do
    local st = construction.status(C, d.key)
    if st == "built" or st == "queued" or st == "ghost" then
      have = have + 1
      if not min_g or d.g < min_g then min_g = d.g end
    end
  end
  for _, d in ipairs(L.drills) do
    if have >= n then break end
    if construction.status(C, d.key) == "planned" then
      wanted[#wanted + 1] = d.key
      have = have + 1
      if not min_g or d.g < min_g then min_g = d.g end
    end
  end
  queue_list(C, L.belts[0])
  queue_list(C, L.belts[1])
  local gs = {}
  for g in pairs(L.gap_poles) do
    if min_g and g >= min_g then gs[#gs + 1] = g end
  end
  table.sort(gs, function(a, b) return a > b end)
  for _, g in ipairs(gs) do construction.queue(C, L.gap_poles[g]) end
  queue_list(C, L.chain)
  queue_list(C, wanted)
  return #wanted
end
build_order.want_drills = want_drills

-- Queue hub slots 1..n with the belt segments that reach them.
local function want_slots(C, L, n)
  local queued = 0
  for i = 1, math.min(n, #L.slots) do
    for seg = 1, L.slots[i].seg do queue_list(C, L.belts[seg]) end
    for _, key in ipairs(L.slots[i].keys) do
      if construction.queue(C, key) then queued = queued + 1 end
    end
  end
  return queued
end
build_order.want_slots = want_slots

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local WHEN_ITEMS = {iron = "iron-plate", copper = "copper-plate", steel = "steel-plate", stone = "stone"}

local function when_ok(C, step)
  local w = step.when
  if not w then return true end
  for key, need in pairs(w) do
    if key == "unlocked" then
      if not (deps.research and deps.research.is_unlocked(C.force, need)) then return false end
    else
      local have
      if key == "units" then
        have = units.count(C.force)
      elseif key == "time" then
        have = (game.tick - C.started) / 60
      else
        have = construction.have(C, WHEN_ITEMS[key] or key)
      end
      if have < need then return false end
    end
  end
  return true
end

local function line_of(C, step)
  return C.lines[step.anchor]
end

--- Live buildings named `name` of commander C's force within BASE_COUNT_RADIUS of its CC (a forward hub's solar
--- arrays do not count for the base). Names outside the building registry are counted from the plan.
function build_order.base_count(C, name)
  local kind = buildings.kind_of(name)
  local f = C.frame
  local centre = f and {x = f.cx, y = f.cy}
  local n = 0
  if kind then
    for _, rec in buildings.for_force(C.force, kind) do
      if not centre or util.distance(rec.position, centre) <= build_order.BASE_COUNT_RADIUS then n = n + 1 end
    end
    return n
  end
  for _, e in pairs(C.plan) do
    if e.name == name and e.status == "built" and e.entity and e.entity.valid then n = n + 1 end
  end
  return n
end

local function satisfied(C, step, st)
  if st.skipped then return true end
  local kind = step.kind
  local ext = build_order.KINDS[kind]
  if ext then return ext.satisfied(C, step, st) end
  if kind == "build" then
    local count = step.count or 1
    if step.anchor == "cc" or step.anchor == "front" then
      return build_order.base_count(C, step.name) >= count
    end
    local L = line_of(C, step)
    if not L then return false end
    if L.status ~= "ok" then return true end
    if step.name == layout.DRILL then
      return build_order.line_drills_built(C, L) >= math.min(count, #L.drills)
    elseif step.name == layout.SMELTER or step.name == "slot" then
      return build_order.line_slots_built(C, L) >= math.min(count, #L.slots)
    end
    return true
  elseif kind == "recipe" then
    if step.building == "rts-barracks" then return C.unit_recipe == step.recipe end
    return true
  elseif kind == "army" then
    return C.army.min == step.min and C.army.action == step.action
  elseif kind == "expand" then
    local L = line_of(C, step)
    if not L then return false end
    if L.status ~= "ok" then return true end
    return build_order.line_drills_built(C, L) >= math.min(step.extractors or 2, #L.drills)
      and build_order.line_slots_built(C, L) >= math.min(step.slots or 1, #L.slots)
  end
  return true
end

local function in_progress(C, step)
  local ext = build_order.KINDS[step.kind]
  if ext then return ext.in_progress(C, step) end
  if step.kind == "build" then
    if step.anchor == "cc" or step.anchor == "front" then
      return (C.pending[step.name] or 0) > 0 or layout.spot_pending(C, step.name) -- (spot_pending: Phase 5 M3 ai perf)
    end
    local L = line_of(C, step)
    if not L and line_planning(C, step.anchor) then return true end -- Phase 5 M3 ai (perf): its planning job runs
    return L ~= nil and L.status == "ok" and line_busy(C, L)
  elseif step.kind == "expand" then
    local L = line_of(C, step)
    if not L and line_planning(C, step.anchor) then return true end -- Phase 5 M3 ai (perf): its planning job runs
    return L ~= nil and L.status == "ok" and line_busy(C, L)
  end
  return false
end

local function execute(C, step, st, surface, get_ctx)
  local kind = step.kind
  local ext = build_order.KINDS[kind]
  if ext then return ext.execute(C, step, st, surface, get_ctx) end
  if kind == "build" then
    local count = step.count or 1
    if step.anchor == "cc" or step.anchor == "front" then
      local have = build_order.base_count(C, step.name) + (C.pending[step.name] or 0)
      local placed = 0
      for _ = have + 1, count do
        local pos, pole, wait = layout.find_spot(C, surface, step.name, step.anchor)
        if wait then break end -- Phase 5 M3 ai (perf): a planning job looks for the spot (the step is in progress)
        if pole then
          construction.queue(C, construction.add(C, {name = layout.POLE, x = pole.x, y = pole.y}))
          util.log("ai %s: %s goes to %s outside the core supply, with a pole at %s", C.force, step.name,
            util.pos_str(pos), util.pos_str(pole))
        end
        if not pos then
          st.retry_at = game.tick + build_order.RETRY_TICKS
          util.log("ai %s: no free spot for %s (%s), retry in %ds", C.force, step.name, step.anchor,
            build_order.RETRY_TICKS / 60)
          break
        end
        construction.queue(C, construction.add(C, {name = step.name, x = pos.x, y = pos.y}))
        placed = placed + 1
      end
      return placed
    end
    local L = line_of(C, step) or build_order.plan_line_async(C, get_ctx, step.anchor, surface) -- Phase 5 M3 ai (perf)
    if not L then return 0 end -- (a planning job plans it: in progress)
    if L.status ~= "ok" then
      st.skipped = L.reason
      return 0
    end
    if step.name == layout.DRILL then return want_drills(C, L, count) end
    if step.name == layout.SMELTER or step.name == "slot" then return want_slots(C, L, count) end
    return 0
  elseif kind == "recipe" then
    if step.building == "rts-barracks" then C.unit_recipe = step.recipe end
    return 1
  elseif kind == "army" then
    C.army.min, C.army.action = step.min, step.action
    util.log("ai %s: army attacks once %d units are idle", C.force, step.min)
    return 1
  elseif kind == "expand" then
    local L = line_of(C, step) or build_order.plan_line_async(C, get_ctx, step.anchor, surface) -- Phase 5 M3 ai (perf)
    if not L then return 0 end -- (a planning job plans it: in progress)
    if L.status ~= "ok" then
      st.skipped = L.reason
      util.log("ai %s: expansion %s skipped: %s", C.force, step.anchor, tostring(L.reason))
      return 0
    end
    return want_drills(C, L, step.extractors or 2) + want_slots(C, L, step.slots or 1)
  end
  return 0
end

local function describe(step)
  local ext = build_order.KINDS[step.kind]
  if ext then return ext.describe(step) end
  if step.kind == "build" then
    return string.format("build %s x%d @%s", step.name, step.count or 1, step.anchor)
  elseif step.kind == "recipe" then
    return string.format("recipe %s -> %s", step.building, step.recipe)
  elseif step.kind == "army" then
    return string.format("army %s at %d", step.action, step.min)
  elseif step.kind == "expand" then
    return string.format("expand %s", step.anchor)
  end
  return step.kind
end
build_order.describe = describe

---------------------------------------------------------------------------
-- Priority rebuild (Phase 4 fix: a side that lost its barracks never rebuilt it in time)
---------------------------------------------------------------------------
-- A lost factory comes first (it makes the barracks item), then the barracks once unit production is on. Their
-- queue entries move to the front of C.queue, so construction places them first and the factory, which makes the
-- first item the queue lacks, makes their items next.
build_order.PRIORITY = {"rts-factory", "rts-barracks"}

function build_order.priority(C, surface)
  local front = {}
  C.had = C.had or {}
  for _, name in ipairs(build_order.PRIORITY) do
    local n = buildings.count(C.force, buildings.kind_of(name))
    if n > 0 then C.had[name] = true end
    -- only a building the force had and lost: the opening places the first ones
    if C.had[name] and n == 0 then
      C.priority_retry = C.priority_retry or {}
      if (C.pending[name] or 0) == 0 and game.tick >= (C.priority_retry[name] or 0) then
        C.priority_retry[name] = game.tick + build_order.RETRY_TICKS
        local pos, pole, wait = layout.find_spot(C, surface, name, "cc")
        if wait then C.priority_retry[name] = nil end -- Phase 5 M3 ai (perf): a planning job looks: ask again next run
        if pos then
          if pole then construction.queue(C, construction.add(C, {name = layout.POLE, x = pole.x, y = pole.y})) end
          construction.queue(C, construction.add(C, {name = name, x = pos.x, y = pos.y}))
          C.stats.priority = (C.stats.priority or 0) + 1
          util.log("ai %s: priority rebuild: %s at %s (the last one was lost)", C.force, name, util.pos_str(pos))
        end
      end
      for _, key in ipairs(C.queue) do
        local e = C.plan[key]
        if e and e.name == name then front[#front + 1] = key end
      end
    end
  end
  if #front == 0 then return false end
  local set = {}
  for _, key in ipairs(front) do set[key] = true end
  local q = {}
  for _, key in ipairs(front) do q[#q + 1] = key end
  for _, key in ipairs(C.queue) do
    if not set[key] then q[#q + 1] = key end
  end
  C.queue = q
  return true
end

---------------------------------------------------------------------------
-- Phase 5 M2 ai: raw-line bootstrap (Nation mode). A start line whose plate the force does not make yet comes first
-- once that plate runs low: its first drill and slot are queued and moved to the front of the construction queue, so
-- the builder makes their items before anything else takes the last plates. (M2 wave A: the people governor's goods
-- works and bakery took an aggressive AI's last copper at 5:00 and its copper extractor never came: seeds 402-404 and
-- 611 without a copper line, Age II or a town for the whole match.)
---------------------------------------------------------------------------
build_order.BOOT_CRITICAL = 20 -- below this many plates the workshops and barracks skip their recipes with that plate
build_order.BOOTSTRAP = {
  {line = "copper", item = "copper-plate", low = 40}, -- an extractor, a batch of poles and one of inserters, a margin
}

--- True when line `name` of commander C has a drill and a slot built (its plate flows), or no such line exists.
function build_order.line_running(C, name)
  local L = C.lines[name]
  if not (L and L.status == "ok") then return true end
  return build_order.line_drills_built(C, L) > 0 and build_order.line_slots_built(C, L) > 0
end

-- While a bootstrap is on, C.boot[item] = true: the make targets (ai/age_up.lua), the goods works (ai/governor.lua) and
-- the workshop factories (ai/commander.lua) take none of that plate, so the last plates reach the line's own parts (seed
-- 705: the bootstrap fired at 26 copper and the works factory's circuits still took them).
function build_order.bootstrap(C)
  if not (deps.ages and deps.ages.is_nation()) then return end
  C.boot = nil
  for _, b in ipairs(build_order.BOOTSTRAP) do
    local L = C.lines[b.line]
    if L and L.status == "ok" and not build_order.line_running(C, b.line)
       and construction.have(C, b.item) < b.low then
      C.boot = C.boot or {}
      C.boot[b.item] = true
      want_drills(C, L, 1)
      want_slots(C, L, 1)
      local front, rest = {}, {}
      for _, key in ipairs(C.queue) do
        local e = C.plan[key]
        if e and e.line == b.line then front[#front + 1] = key else rest[#rest + 1] = key end
      end
      if #front > 0 and C.queue[1] ~= front[1] then
        for _, key in ipairs(rest) do front[#front + 1] = key end
        C.queue = front
        if not (C.boot_logged and C.boot_logged[b.line]) then
          C.boot_logged = C.boot_logged or {}
          C.boot_logged[b.line] = true
          util.log("ai %s: bootstrap: %s line first (%d %s left, no drill and slot running yet)", C.force, b.line,
            construction.have(C, b.item), b.item)
        end
      end
    end
  end
end

--- Walk the build order of commander C once (see the header). get_ctx() returns a planning context.
function build_order.step(C, surface, get_ctx)
  local order = data.order(C.difficulty, C.doctrine, deps.ages ~= nil and deps.ages.is_nation()) -- Phase 5 M1
  build_order.priority(C, surface)
  local busy, passed = 0, 0
  C.current_step = nil
  for i, step in ipairs(order) do
    local st = C.steps[i]
    if not st then
      st = {}
      C.steps[i] = st
    end
    if satisfied(C, step, st) then
      if not st.done then
        st.done = game.tick
        util.log("ai %s: step %d done: %s%s (t=%ds)", C.force, i, describe(step),
          st.skipped and (" [skipped: " .. tostring(st.skipped) .. "]") or "", (game.tick - C.started) / 60)
      end
    else
      if st.done then
        util.log("ai %s: step %d undone: %s", C.force, i, describe(step))
        st.done = nil
      end
      C.current_step = C.current_step or i
      if in_progress(C, step) then
        busy = busy + 1
      elseif (not st.retry_at or game.tick >= st.retry_at) and when_ok(C, step) then
        st.retry_at = nil
        local n = execute(C, step, st, surface, get_ctx)
        if not st.started then
          st.started = game.tick
          util.log("ai %s: step %d started: %s (%d things queued, t=%ds)", C.force, i, describe(step), n,
            (game.tick - C.started) / 60)
        end
        if n > 0 or in_progress(C, step) or satisfied(C, step, st) then
          busy = busy + 1
        else
          -- nothing could be queued (no spot, every candidate bad): look again later, let later steps run
          st.retry_at = st.retry_at or (game.tick + build_order.RETRY_TICKS)
          passed = passed + 1
        end
      else
        passed = passed + 1
      end
      if busy >= C.cfg.max_in_progress or passed >= build_order.LOOKAHEAD then break end
    end
  end
end

return build_order
