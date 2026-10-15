-- AI build order (docs/PHASE3.md "ai/build_order.lua"): runs the data-driven step list of ai/orders_data.lua.
--
-- Each commander run walks the steps in order:
--   * a satisfied step is skipped (a "build" step whose buildings died becomes unsatisfied again);
--   * an unsatisfied step whose work is still queued counts as in progress;
--   * an unsatisfied step whose `when` holds is executed (queues its work) and counts as in progress;
--   * an unsatisfied step whose `when` does not hold is skipped, but at most LOOKAHEAD of those are passed over.
-- The walk stops at cfg.max_in_progress steps in progress, so a few steps overlap and the queue stays short.
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

local build_order = {}

build_order.LOOKAHEAD = 2           -- unaffordable steps passed over before the walk stops
build_order.RETRY_TICKS = 10 * 60   -- a step that found no spot tries again after this long

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

--- Plan line `name` (orders_data.LINES) for commander C with planning context ctx. Idempotent.
function build_order.plan_line(C, ctx, name)
  if C.lines[name] then return C.lines[name] end
  local spec = data.LINES[name]
  local L = {name = name, ore = spec and spec.ore}
  C.lines[name] = L
  if not spec then
    L.status, L.reason = "unavailable", "no such line"
    return L
  end
  local plan, reason = layout.plan_line(C, ctx, name, spec, hostile_positions(C))
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

local function queue_list(C, list)
  for _, key in ipairs(list or {}) do construction.queue(C, key) end
end

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

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local WHEN_ITEMS = {iron = "iron-plate", copper = "copper-plate", steel = "steel-plate", stone = "stone"}

local function when_ok(C, step)
  local w = step.when
  if not w then return true end
  for key, need in pairs(w) do
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
  return true
end

local function line_of(C, step)
  return C.lines[step.anchor]
end

local function satisfied(C, step, st)
  if st.skipped then return true end
  local kind = step.kind
  if kind == "build" then
    local count = step.count or 1
    if step.anchor == "cc" or step.anchor == "front" then
      return buildings.count(C.force, buildings.kind_of(step.name)) >= count
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
  if step.kind == "build" then
    if step.anchor == "cc" or step.anchor == "front" then return (C.pending[step.name] or 0) > 0 end
    local L = line_of(C, step)
    return L ~= nil and L.status == "ok" and line_busy(C, L)
  elseif step.kind == "expand" then
    local L = line_of(C, step)
    return L ~= nil and L.status == "ok" and line_busy(C, L)
  end
  return false
end

local function execute(C, step, st, surface, get_ctx)
  local kind = step.kind
  if kind == "build" then
    local count = step.count or 1
    if step.anchor == "cc" or step.anchor == "front" then
      local have = buildings.count(C.force, buildings.kind_of(step.name)) + (C.pending[step.name] or 0)
      local placed = 0
      for _ = have + 1, count do
        local pos = layout.find_spot(C, surface, step.name, step.anchor)
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
    local L = line_of(C, step) or build_order.plan_line(C, get_ctx(), step.anchor)
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
    local L = line_of(C, step) or build_order.plan_line(C, get_ctx(), step.anchor)
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

--- Walk the build order of commander C once (see the header). get_ctx() returns a planning context.
function build_order.step(C, surface, get_ctx)
  local order = data.BUILD_ORDERS[C.difficulty] or data.BUILD_ORDERS[data.DEFAULT_DIFFICULTY]
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
