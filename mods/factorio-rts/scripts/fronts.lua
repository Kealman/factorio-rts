-- Phase 5 M3 war2: fronts and the hold_line order (docs/PHASE5-M3.md D5, section 3 "fronts.lua / belts.lua /
-- trainswar.lua"; study docs/research/scale/war-ai-performance.md 2.4; notes docs/qa/phase5-war2-notes.md). Nation
-- mode only.
--
--   fronts.of(force) -> {[war_id] = {enemy, tick, segments = {{id, a, b, chord, threat, holder, ...}}}}
--   fronts.refresh(force?)           queue a recomputation now (it runs by itself every balance.nation.fronts.refresh
--                                    ticks and when a war starts or ends); fronts.flush() finishes it at once (tests)
--   fronts.threat(segment) -> number value behind x (1 + enemy strength near / strength_unit)
--   fronts.segment(force, id) -> segment, war_id
--   fronts.nearest(force, position, max_distance?) -> segment, distance   (by distance to the chord)
--   divisions.order(id, "hold_line", segment_id, opts) -> ok, reason      (divisions.ORDER_HOOKS)
--
-- Segments. For each war going on (wars.active: active or in its ceasefire), each side's border cells that touch the
-- other side's land (4-neighbours on the territory grid, 8-tile cells) are joined into 8-connected pieces; a piece of
-- at least min_cells cells is walked from one end (nearest-neighbour order) and cut into segment_min..segment_max tiles of
-- walk (a shorter piece stays one segment). A segment: a and b (its end cells' centres), mid, chord (|b - a|, tiles),
-- length (walk), cells, back (unit vector into own land: away from the enemy cells it touches), strength (supply of
-- the enemy's units within near_radius of mid), value (own cities within value_radius: tier x 10 + residents / 10,
-- +20 for the capital, falling off linearly with distance; own hubs and depots within depot_radius: 8 each), threat,
-- name (the region), holder (division id holding it). A refresh keeps the id and holder of an old segment of the same
-- war whose middle lies within match_radius of a new one. The enemy strength is read from the unit registry
-- (fronts.STRENGTH can be replaced: m3-ai's intel). The refresh is a job of rows_per_tick territory rows per tick and
-- one side's segments per tick, so no tick pays for a whole map scan.
-- Map. Each force sees its own segments on the map (chart view): a line along the chord coloured by threat (green,
-- yellow, red: relative to its most threatened segment) and "Front N · threat T" at the middle (and the holder); the
-- game view shows the same as a thin dashed line with a small label (where H holds the line).
-- hold_line. The division walks to slots spread along the chord (behind it by hold.behind tiles, inside own land),
-- members matched to slots along the chord, stance hold; a division farther than hold.far from the chord marches there
-- as a group first. Every hold.maintain ticks members that drifted more than hold.drift from their slot (no enemy
-- within enemy_clear) walk back, and reinforcements get slots. Any other order ends the line. H with whole divisions selected
-- and the cursor within hold.pick tiles of an own segment's chord orders hold_line (several divisions share the chord),
-- else H is the plain hold (orders.lua asks fronts through orders.h_claim). The division panel's Hold line button holds
-- the nearest segment.
--
-- Owns storage.fronts = {match_id, next_id, job, pending, next_refresh, lines = {[division id] = {segment, part, phase
--   = "march" | "spread" | "hold", slots = {[unit number] = {x, y}}, a, b, n, tick}}, objs = {[force] =
--   {LuaRenderObject}}, stats = {refreshes, segments, holds}} and storage.nations[force].fronts (the contract's table).
-- Log lines "[rts] front: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local units = require("scripts.units")
local orders = require("scripts.orders")
local selection = require("scripts.selection")
local buildings = require("scripts.buildings")
local divisions = require("scripts.divisions")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local diplomacy = require("scripts.diplomacy")
local balance = require("balance")
local sched = require("scripts.sched") -- Phase 5 M3 integration: the refresh job runs on the work-unit scheduler

local fronts = {}
local FB = balance.nation.fronts
local H = FB.hold
fronts.PROFILE_STEPS = false -- test copies: log the time of every refresh job tick ("front: step ...")

local floor, sqrt, max, min, abs = math.floor, math.sqrt, math.max, math.min, math.abs
local CMD, DIS = defines.command, defines.distraction
local SETTLE_TICKS = 20 * 60 -- divisions.lua: settling members still walking this long after the settle tick stop

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.fronts
  if not s then
    s = {}
    storage.fronts = s
  end
  s.next_id = s.next_id or 1
  s.lines = s.lines or {}
  s.objs = s.objs or {}
  s.stats = s.stats or {refreshes = 0, segments = 0, holds = 0}
  return s
end

function fronts.init() S() end

local function nation()
  local m = storage.match
  return m ~= nil and m.phase == "running" and m.config ~= nil and m.config.mode == "nation"
end

local function loaded(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function nation_rec(force_name)
  storage.nations = storage.nations or {}
  local N = storage.nations[force_name]
  if not N then
    N = {}
    storage.nations[force_name] = N
  end
  return N
end

--- {[war_id] = {enemy, tick, segments}} of a force (empty outside a Nation match or without wars).
function fronts.of(force_name)
  local N = storage.nations and storage.nations[force_name]
  return (N and N.fronts) or {}
end

--- Segment `id` of a force and its war id, or nil.
function fronts.segment(force_name, id)
  for war_id, F in pairs(fronts.of(force_name)) do
    for _, seg in ipairs(F.segments) do
      if seg.id == id then return seg, war_id end
    end
  end
  return nil
end

--- Every segment of a force, by id.
function fronts.segments(force_name)
  local out = {}
  for _, war_id in ipairs(sorted_keys(fronts.of(force_name))) do
    for _, seg in ipairs(fronts.of(force_name)[war_id].segments) do out[#out + 1] = seg end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

--- Threat of a segment (value behind x (1 + enemy strength near / strength_unit)).
function fronts.threat(seg)
  if not seg then return 0 end
  return seg.threat or 0
end

-- Distance from p to the segment a-b, and the projection parameter t (0..1).
local function to_chord(p, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local len2 = dx * dx + dy * dy
  local t = len2 > 0 and ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 or 0
  t = max(0, min(1, t))
  local qx, qy = a.x + dx * t, a.y + dy * t
  local ex, ey = p.x - qx, p.y - qy
  return sqrt(ex * ex + ey * ey), t
end

--- The force's segment whose chord is nearest `position` (within max_distance when given), and that distance.
function fronts.nearest(force_name, position, max_distance)
  local x, y = util.xy(position)
  local p = {x = x, y = y}
  local best, bd
  for _, seg in ipairs(fronts.segments(force_name)) do
    local d = to_chord(p, seg.a, seg.b)
    if (not max_distance or d <= max_distance) and (not bd or d < bd) then best, bd = seg, d end
  end
  return best, bd
end

---------------------------------------------------------------------------
-- Strength and value
---------------------------------------------------------------------------
local function supply_of(name)
  local u = balance.units[name]
  return u and u.supply or 1
end

-- Positions and supply of a force's combat units, read once per tick (module-local, rebuilt from the registry).
local unit_cache = {tick = -1, by_force = {}}
local function unit_list(force_name)
  if unit_cache.tick ~= game.tick then unit_cache.tick, unit_cache.by_force = game.tick, {} end
  local list = unit_cache.by_force[force_name]
  if not list then
    list = {}
    for _, rec in units.for_force(force_name) do
      if rec.kind ~= "hauler" then
        local p = rec.entity.position
        list[#list + 1] = {x = p.x, y = p.y, n = supply_of(rec.entity.name)}
      end
    end
    unit_cache.by_force[force_name] = list
  end
  return list
end

--- Enemy strength near a position: supply of `enemy`'s registered units within radius. Replaceable (intel).
fronts.STRENGTH = function(force_name, enemy, position, radius)
  local r2 = radius * radius
  local n = 0
  for _, u in ipairs(unit_list(enemy)) do
    local dx, dy = u.x - position.x, u.y - position.y
    if dx * dx + dy * dy <= r2 then n = n + u.n end
  end
  return n
end

-- Own hubs, depots and centres (warsupply.depots: no walk over the whole building registry).
local function depot_positions(force_name)
  local ws = loaded("warsupply")
  local out = {}
  if ws and ws.depots then
    for _, un in ipairs(ws.depots(force_name)) do
      local rec = buildings.get(un)
      if rec then out[#out + 1] = rec.position end
    end
  else
    for _, rec in buildings.for_force(force_name, "hub") do out[#out + 1] = rec.position end
  end
  return out
end

local function value_behind(force_name, position, depots)
  local V = FB.value
  local population = loaded("population")
  local capital = storage.nations and storage.nations[force_name] and storage.nations[force_name].capital
  local v = 0
  for _, c in ipairs(cities.for_force(force_name)) do
    local d = util.distance(c.position, position)
    if d < FB.value_radius then
      local pop = 0
      local P_ = population and population.of and population.of(c.id)
      if P_ then pop = P_.pop or 0 end
      local cv = (c.tier or 1) * V.tier + pop / V.per_residents + (c.id == capital and V.capital or 0)
      v = v + cv * (1 - d / FB.value_radius)
    end
  end
  local r2 = FB.depot_radius * FB.depot_radius
  for _, p in ipairs(depots or depot_positions(force_name)) do
    local d2 = util.distance_sq(p, position)
    if d2 <= r2 then v = v + V.depot * (1 - sqrt(d2) / FB.depot_radius) end
  end
  return v
end

---------------------------------------------------------------------------
-- Refresh job
---------------------------------------------------------------------------
local function war_list()
  local wars = loaded("wars")
  if not (wars and wars.all) then return {} end
  local out = {}
  for _, id in ipairs(wars.all()) do
    local W = wars.get(id)
    if W and W.status ~= "ended" and W.a and W.b then out[#out + 1] = {id = id, a = W.a, b = W.b} end
  end
  return out
end

--- Queue a recomputation of every front (the job covers all wars; `force` is accepted for the contract).
function fronts.refresh(force_name)
  local s = S()
  if s.job or s.job_id then
    s.pending = true
  else
    s.next_refresh = game.tick
  end
  return true
end

local function new_job(T)
  return {wars = war_list(), w = 1, row = 1, phase = "scan", side = 1, cells = {{}, {}}, out = {}, started = game.tick,
          cell = T.cell, x0 = T.x0, y0 = T.y0, w_cells = T.w, h_cells = T.h}
end

-- Scan rows of the current war: border cells of each side (4-neighbours of the other side). A side's row is looked at
-- only when the other side owns a cell in it or in the row above or below (string.find, so rows far from the border
-- cost three C calls); at most rows_per_tick rows and about cell_budget visited cells per tick (4-nation probe with
-- 48 rows and 1,500 cells: 0.15 ms per scan tick on average, 1.2 ms at most on a quiet machine).
local function scan_rows(job, T, W, budget)
  local CELL_BUDGET = FB.cell_budget
  local fa, fb = T.fids[W.a], T.fids[W.b]
  if not (fa and fb) then
    job.row = T.h + 1
    return
  end
  local ca, cb = string.char(fa), string.char(fb)
  local owner = T.owner
  local last = min(T.h, job.row + budget - 1)
  local visited = 0
  local r = job.row
  while r <= last and visited < CELL_BUDGET do
    local row = owner[r]
    local up, down = owner[r - 1], owner[r + 1]
    for side = 1, 2 do
      local mine, oc, other = side == 1 and ca or cb, side == 1 and cb or ca, side == 1 and fb or fa
      if string.find(row, oc, 1, true) or (up and string.find(up, oc, 1, true))
         or (down and string.find(down, oc, 1, true)) then
        local list = job.cells[side]
        local i = string.find(row, mine, 1, true)
        while i do
          visited = visited + 1
          local ex, ey, n = 0, 0, 0
          if i < #row and string.byte(row, i + 1) == other then ex, n = ex + 1, n + 1 end
          if i > 1 and string.byte(row, i - 1) == other then ex, n = ex - 1, n + 1 end
          if down and string.byte(down, i) == other then ey, n = ey + 1, n + 1 end
          if up and string.byte(up, i) == other then ey, n = ey - 1, n + 1 end
          if n > 0 then list[#list + 1] = {cx = i - 1, cy = r - 1, ex = ex, ey = ey} end
          i = string.find(row, mine, i + 1, true)
        end
      end
    end
    r = r + 1
  end
  job.row = r
end

local function centre(job, c)
  return {x = job.x0 + (c.cx + 0.5) * job.cell, y = job.y0 + (c.cy + 0.5) * job.cell}
end

--- How many segments a border piece of `total` tiles is cut into: lengths inside segment_min..segment_max when
--- possible, else as close to that range as possible, then as close to its middle (160) as possible.
function fronts.pieces(total)
  local mid = (FB.segment_min + FB.segment_max) / 2
  local best, bs
  for k = 1, math.max(1, math.ceil(total / FB.segment_min) + 1) do
    local L = total / k
    local dev = (L < FB.segment_min and FB.segment_min - L) or (L > FB.segment_max and L - FB.segment_max) or 0
    local score = dev * 1000 + abs(L - mid)
    if not bs or score < bs then best, bs = k, score end
  end
  return best
end

-- Pieces (8-connected), walked from an end, cut into segments.
local function build_side(job, W, side)
  local force_name, enemy = side == 1 and W.a or W.b, side == 1 and W.b or W.a
  local cells = job.cells[side]
  local index = {}
  for k, c in ipairs(cells) do index[c.cx * 65536 + c.cy] = k end
  local comp = {}
  local pieces = {}
  for k, c in ipairs(cells) do
    if not comp[k] then
      local piece = {k}
      comp[k] = true
      local q = 1
      while q <= #piece do
        local cc = cells[piece[q]]
        for dy = -1, 1 do
          for dx = -1, 1 do
            local j = index[(cc.cx + dx) * 65536 + (cc.cy + dy)]
            if j and not comp[j] then
              comp[j] = true
              piece[#piece + 1] = j
            end
          end
        end
        q = q + 1
      end
      if #piece >= FB.min_cells then pieces[#pieces + 1] = piece end
    end
  end
  local segs = {}
  local cell = job.cell
  for _, piece in ipairs(pieces) do
    -- an end: the cell farthest from the piece's first cell; then nearest-neighbour order
    local first = cells[piece[1]]
    local start, sd = piece[1], -1
    for _, k in ipairs(piece) do
      local c = cells[k]
      local d = (c.cx - first.cx) ^ 2 + (c.cy - first.cy) ^ 2
      if d > sd then start, sd = k, d end
    end
    local left = {}
    for _, k in ipairs(piece) do left[k] = true end
    local order = {start}
    left[start] = nil
    local cur = start
    for _ = 2, #piece do
      local cc = cells[cur]
      local best, bd
      -- the nearest unwalked cell within 2 cells through the index, else a scan of the piece
      for dy = -2, 2 do
        for dx = -2, 2 do
          local k = index[(cc.cx + dx) * 65536 + (cc.cy + dy)]
          if k and left[k] then
            local d = dx * dx + dy * dy
            if not bd or d < bd or (d == bd and k < best) then best, bd = k, d end
          end
        end
      end
      if not best then
        for _, k in ipairs(piece) do
          if left[k] then
            local c = cells[k]
            local d = (c.cx - cc.cx) ^ 2 + (c.cy - cc.cy) ^ 2
            if not bd or d < bd then best, bd = k, d end
          end
        end
      end
      left[best] = nil
      order[#order + 1] = best
      cur = best
    end
    -- walk length (tiles)
    local cum = {0}
    for i = 2, #order do
      local a, b = cells[order[i - 1]], cells[order[i]]
      cum[i] = cum[i - 1] + sqrt((a.cx - b.cx) ^ 2 + (a.cy - b.cy) ^ 2) * cell
    end
    local total = cum[#order] + cell
    local k = fronts.pieces(total)
    local from = 1
    for part = 1, k do
      local upto = part == k and #order or from
      if part < k then
        local limit = total * part / k
        while upto < #order and cum[upto + 1] <= limit do upto = upto + 1 end
      end
      if upto >= from then
        local a, b = centre(job, cells[order[from]]), centre(job, cells[order[upto]])
        local bx, by, sx, sy = 0, 0, 0, 0
        for i = from, upto do
          local c = cells[order[i]]
          bx, by = bx - c.ex, by - c.ey
          local p = centre(job, c)
          sx, sy = sx + p.x, sy + p.y
        end
        local n = upto - from + 1
        local bl = sqrt(bx * bx + by * by)
        if bl < 0.01 then
          -- no clear side: perpendicular to the chord, towards the force's capital
          bx, by = -(b.y - a.y), b.x - a.x
          bl = sqrt(bx * bx + by * by)
          if bl < 0.01 then bx, by, bl = 1, 0, 1 end
          local cap = storage.nations and storage.nations[force_name] and storage.nations[force_name].capital
          local c = cap and cities.get(cap)
          if c and (c.position.x - a.x) * bx + (c.position.y - a.y) * by < 0 then bx, by = -bx, -by end
        end
        local mid = {x = sx / n, y = sy / n}
        segs[#segs + 1] = {war = W.id, enemy = enemy, a = a, b = b, mid = mid,
                           chord = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2),
                           length = (part == k and total or cum[upto] + cell) - cum[from], cells = n,
                           back = {x = bx / bl, y = by / bl}}
      end
      from = upto + 1
      if from > #order then break end
    end
  end
  -- strength, value, threat, name
  local world = loaded("world")
  local depots = #segs > 0 and depot_positions(force_name) or {}
  for _, seg in ipairs(segs) do
    seg.strength = fronts.STRENGTH(force_name, enemy, seg.mid, FB.near_radius)
    seg.value = value_behind(force_name, seg.mid, depots)
    seg.threat = floor(seg.value * (1 + seg.strength / FB.strength_unit) + 0.5)
    seg.name = world and world.place_name and world.place_name(seg.mid) or nil
  end
  job.out[force_name] = job.out[force_name] or {}
  job.out[force_name][W.id] = {enemy = enemy, tick = game.tick, segments = segs}
end

-- Ids and holders: a new segment takes the id (and holder) of the old segment of the same war nearest it.
local function carry_over(s, force_name, wars_out)
  local old = fronts.of(force_name)
  local r2 = FB.match_radius * FB.match_radius
  for _, war_id in ipairs(sorted_keys(wars_out)) do
    local olds = old[war_id] and old[war_id].segments or {}
    local taken = {}
    for _, seg in ipairs(wars_out[war_id].segments) do
      local best, bd
      for i, o in ipairs(olds) do
        if not taken[i] then
          local d = util.distance_sq(o.mid, seg.mid)
          if d <= r2 and (not bd or d < bd) then best, bd = i, d end
        end
      end
      if best then
        taken[best] = true
        seg.id, seg.holder = olds[best].id, olds[best].holder
      else
        seg.id = s.next_id
        s.next_id = s.next_id + 1
      end
      -- a holder that no longer holds this segment is dropped
      local D = seg.holder and divisions.get(seg.holder)
      local L = s.lines[seg.holder or 0]
      local holds = D and L and L.segment == seg.id
        and (L.phase == "march" or (D.order and D.order.kind == "hold_line"))
      if not holds then seg.holder = nil end
    end
  end
end

local redraw

local function commit(job)
  local s = S()
  local forces = {}
  for _, f in ipairs(match.forces()) do forces[#forces + 1] = f end
  for f in pairs(job.out) do
    local known = false
    for _, g in ipairs(forces) do if g == f then known = true end end
    if not known then forces[#forces + 1] = f end
  end
  table.sort(forces)
  local total, parts = 0, {}
  for _, f in ipairs(forces) do
    local out = job.out[f] or {}
    carry_over(s, f, out)
    local N = nation_rec(f)
    local before = 0
    for _, F in pairs(N.fronts or {}) do before = before + #F.segments end
    N.fronts = out
    local n, top = 0, 0
    for _, F in pairs(out) do
      n = n + #F.segments
      for _, seg in ipairs(F.segments) do top = max(top, seg.threat) end
    end
    total = total + n
    if n > 0 or before > 0 then -- no line (and no redraw) while a war has no front at all
      parts[#parts + 1] = string.format("%s %d (max threat %d)", f, n, top)
      redraw(f)
    end
  end
  s.stats.refreshes = s.stats.refreshes + 1
  s.stats.segments = total
  if total > 0 or #parts > 0 then
    util.log("front: refresh %d: %d wars, %d segments in %d ticks: %s", s.stats.refreshes, #job.wars, total,
      game.tick - job.started, table.concat(parts, ", "))
  end
end

-- One tick of the job. Returns true when it finished.
local function job_step(job)
  local T = territory.ensure_grid()
  if not T then return true end
  local W = job.wars[job.w]
  if not W then
    commit(job)
    return true
  end
  if job.phase == "scan" then
    scan_rows(job, T, W, FB.rows_per_tick)
    if job.row > T.h then job.phase = "build" end
  elseif job.phase == "build" then
    build_side(job, W, job.side)
    if job.side == 1 then
      job.side = 2
    else
      job.w, job.row, job.phase, job.side, job.cells = job.w + 1, 1, "scan", 1, {{}, {}}
    end
  end
  return false
end

-- Phase 5 M3 integration (war2 notes open issue 9): in a Nation match the refresh is a scheduler job of kind
-- "fronts_refresh" at BACKGROUND priority on the budget of the match's first nation (a human's budget is otherwise
-- idle; spare units of the tick cap go to it too). One step of job_step (rows_per_tick rows / cell_budget cells, or one
-- side's segments) counts STEP_UNITS; a call runs at least one step and more while its units last.
fronts.STEP_UNITS = 300
sched.register("fronts_refresh", function(job, units)
  local used = 0
  repeat
    used = used + fronts.STEP_UNITS
    if job_step(job.state) then return used, true end
  until used + fronts.STEP_UNITS > units
  return used, false
end, function(job)
  local s = storage.fronts
  if not (s and s.job_id == job.id) then return end
  s.job_id = nil
  if s.pending then
    s.pending = nil
    s.next_refresh = game.tick + 1
  end
end)

--- Finish the running (or a new) refresh job now (tests).
function fronts.flush()
  local s = S()
  if s.job_id then -- Phase 5 M3 integration: a scheduler job is finished here and taken off the scheduler
    local J = sched.get(s.job_id)
    local id = s.job_id
    s.job_id = nil
    if J and (J.status == "queued" or J.status == "running") then
      s.job = J.state
      sched.cancel(id)
    end
  end
  if not s.job then
    local T = territory.ensure_grid()
    if not T then return 0 end
    s.job = new_job(T)
  end
  local n = 0
  while s.job and n < 100000 do
    n = n + 1
    if job_step(s.job) then s.job = nil end
  end
  s.next_refresh = game.tick + FB.refresh
  return n
end

events.on(defines.events.on_tick, function(e)
  local s = storage.fronts
  if not s then return end
  if s.job_id then -- Phase 5 M3 integration: the scheduler runs it
    local st = sched.status(s.job_id)
    if st == "queued" or st == "running" then return end
    s.job_id = nil
  end
  if s.job then -- a job of a save from before the scheduler, or a match without it
    local prof = fronts.PROFILE_STEPS and helpers.create_profiler() or nil
    local phase, w = s.job.phase, s.job.w
    local finished = job_step(s.job)
    if prof then
      prof.stop()
      log({"", string.format("[rts] front: step tick %d war %d %s: ", e.tick, w, phase), prof})
    end
    if finished then
      s.job = nil
      if s.pending then
        s.pending = nil
        s.next_refresh = e.tick + 1
      end
    end
    return
  end
  if not (s.next_refresh and e.tick >= s.next_refresh) then return end
  if not nation() then return end
  local T = territory.ensure_grid()
  if not T then return end
  s.next_refresh = e.tick + FB.refresh
  local job = new_job(T)
  local first = match.forces()[1]
  local id = first and sched.enabled() and sched.submit(first, "fronts_refresh", job, sched.BACKGROUND)
  if id then s.job_id = id else s.job = job end
end)

-- A new Nation match: the first refresh after a minute of play; wars start and end a refresh at once.
match.on_started(function()
  storage.fronts = nil
  S().next_refresh = game.tick + 60 * 60
end)
events.on_signal("rts_war_declared", function() fronts.refresh() end)
events.on_signal("rts_war_ended", function() fronts.refresh() end)

---------------------------------------------------------------------------
-- Map
---------------------------------------------------------------------------
local function threat_color(t, top)
  local r = top > 0 and t / top or 0
  if r < 0.5 then return {r = 0.4 + r * 1.2, g = 0.9, b = 0.3, a = 0.9} end
  return {r = 1, g = 0.9 - (r - 0.5) * 1.4, b = 0.25, a = 0.9}
end

redraw = function(force_name)
  local s = S()
  for _, o in ipairs(s.objs[force_name] or {}) do
    if o.valid then o.destroy() end
  end
  local objs = {}
  s.objs[force_name] = objs
  local surface = match.surface()
  if not (surface and game.forces[force_name]) then return end
  local segs = fronts.segments(force_name)
  local top = 0
  for _, seg in ipairs(segs) do top = max(top, seg.threat) end
  local size = (storage.world and storage.world.size or 2048) / 2048
  for _, seg in ipairs(segs) do
    local col = threat_color(seg.threat, top)
    objs[#objs + 1] = rendering.draw_line({surface = surface, color = col, width = 5, from = seg.a, to = seg.b,
      render_mode = "chart", forces = {force_name}})
    local text = {"", {"rts-war3.front-label", seg.id, seg.threat}}
    local D = seg.holder and divisions.get(seg.holder)
    if D then text = {"", text, " · ", {"rts-war3.front-held", D.name}} end
    objs[#objs + 1] = rendering.draw_text({text = text, surface = surface, target = seg.mid, color = col,
      scale = 12 * size, alignment = "center", vertical_alignment = "middle", render_mode = "chart",
      forces = {force_name}})
    -- the game view too (thin, dashed, with the label): where H holds the line
    objs[#objs + 1] = rendering.draw_line({surface = surface, color = col, width = 3, from = seg.a, to = seg.b,
      dash_length = 2, gap_length = 1.5, forces = {force_name}})
    objs[#objs + 1] = rendering.draw_text({text = text, surface = surface, target = seg.mid, color = col, scale = 1.6,
      alignment = "center", vertical_alignment = "middle", forces = {force_name}})
  end
end
fronts.redraw = function(force_name) redraw(force_name) end

---------------------------------------------------------------------------
-- hold_line
---------------------------------------------------------------------------
local function chord_of(seg, part)
  local a, b = seg.a, seg.b
  if part and part.k > 1 then
    local t0, t1 = (part.i - 1) / part.k, part.i / part.k
    a = {x = seg.a.x + (seg.b.x - seg.a.x) * t0, y = seg.a.y + (seg.b.y - seg.a.y) * t0}
    b = {x = seg.a.x + (seg.b.x - seg.a.x) * t1, y = seg.a.y + (seg.b.y - seg.a.y) * t1}
  end
  return a, b
end

-- Slots along a-b, hold.behind tiles into own land; members matched by their projection on the chord.
local function make_slots(recs, a, b, back, force_name)
  local n = #recs
  local dx, dy = b.x - a.x, b.y - a.y
  local proj, idx = {}, {}
  for i, rec in ipairs(recs) do
    local p = rec.entity.position
    proj[i] = (p.x - a.x) * dx + (p.y - a.y) * dy
    idx[i] = i
  end
  table.sort(idx, function(u, v)
    if proj[u] ~= proj[v] then return proj[u] < proj[v] end
    return recs[u].entity.unit_number < recs[v].entity.unit_number
  end)
  local slots = {}
  for k, i in ipairs(idx) do
    local t = (k - 0.5) / n
    local x, y = a.x + dx * t + back.x * H.behind, a.y + dy * t + back.y * H.behind
    -- not on own land (a bulge of the border): further back, up to 32 tiles
    local step = 0
    while territory.owner_at({x = x, y = y}) ~= force_name and step < 8 do
      x, y = x + back.x * 4, y + back.y * 4
      step = step + 1
    end
    slots[recs[i].entity.unit_number] = {x = x, y = y}
  end
  return slots
end

-- Members walk to their slots ("settling" in divisions.lua: each one stops on arrival, then the division is idle).
local function send_to_slots(D, recs, slots, only)
  local far = 0
  D.settling = D.settling or {}
  for _, rec in ipairs(recs) do
    local un = rec.entity.unit_number
    local slot = slots[un]
    if slot and (not only or only[un]) then
      rec.order, rec.dest, rec.target, rec.issuer, rec.fails = "move", slot, nil, divisions.ISSUER, nil
      D.settling[un] = true
      orders.cancel_queued(rec.entity)
      orders.queue_command(rec.entity, {type = CMD.go_to_location, destination = slot, radius = 1,
                                        distraction = DIS.by_enemy})
      far = max(far, util.distance(rec.entity.position, slot))
    end
  end
  if next(D.settling) then
    D.state = "settling"
    -- divisions.lua stops members still walking SETTLE_TICKS after settle_tick: give long walks their time (4 tiles/s)
    D.settle_tick = game.tick + max(0, floor(far / 4 * 60) + 300 - SETTLE_TICKS)
  end
end

local function spread(D, L, seg)
  local recs = divisions.live_members(D)
  if #recs == 0 then return false end
  if D.group and D.group.valid or D.state == "moving" then
    divisions.order(D.id, "stop", nil, {auto = "hold_line"}) -- drops the group, members stop
  end
  local a, b = chord_of(seg, L.part)
  local slots = make_slots(recs, a, b, seg.back, D.force)
  D.detached, D.joining, D.settling = {}, {}, {}
  send_to_slots(D, recs, slots)
  local mid = {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}
  D.order = {kind = "hold_line", target = mid, tick = game.tick, segment = seg.id}
  L.phase, L.slots, L.a, L.b, L.n, L.tick = "hold", slots, a, b, #recs, game.tick
  if D.stance ~= "hold" then divisions.set_stance(D.id, "hold") end
  util.log("front: division #%d %s holds segment %d of %s: %d slots along %.0f tiles (%s -> %s)", D.id,
    divisions.label(D), seg.id, D.force, #recs, util.distance(a, b), util.pos_str(a), util.pos_str(b))
  return true
end

--- Order a division to hold a segment of its force's front (divisions.order(id, "hold_line", segment_id, opts)).
--- opts.part = {i, k}: the i-th of k equal parts of the chord (several divisions on one segment). Returns ok, reason.
function fronts.hold_line(div_id, seg_id, opts)
  local D = divisions.get(div_id)
  if not D then return false, "no-division" end
  local seg = fronts.segment(D.force, seg_id)
  if not seg then return false, "no-segment" end
  local recs = divisions.live_members(D)
  if #recs == 0 then return false, "no-members" end
  local s = S()
  local L = {segment = seg.id, part = opts and opts.part or nil, tick = game.tick}
  s.lines[div_id] = L
  s.stats.holds = s.stats.holds + 1
  -- the previous holder of this segment lets go
  if seg.holder and seg.holder ~= div_id then
    local old = s.lines[seg.holder]
    if old and old.segment == seg.id and not (L.part and old.part) then s.lines[seg.holder] = nil end
  end
  seg.holder = div_id
  local a, b = chord_of(seg, L.part)
  local cen = divisions.strength(D, true) and D.pos or recs[1].entity.position
  local d = to_chord(cen, a, b)
  if d > H.far then
    local mid = {x = (a.x + b.x) / 2 + seg.back.x * H.behind, y = (a.y + b.y) / 2 + seg.back.y * H.behind}
    L.phase, L.target = "march", mid
    if not divisions.order(div_id, "move", mid, {auto = "hold_line march"}) then
      s.lines[div_id] = nil
      return false, "refused"
    end
    util.log("front: division #%d %s marches %.0f tiles to segment %d of %s", div_id, divisions.label(D), d, seg.id,
      D.force)
  else
    spread(D, L, seg)
  end
  redraw(D.force)
  return true
end
divisions.ORDER_HOOKS.hold_line = function(id, target, opts) return fronts.hold_line(id, target, opts) end

-- The members stand in their slots (divisions.lua finished the settling and made the division idle): they stay claimed
-- as "hold" (re-stopped whenever a command ends, like the hold order; idle units would be taken by an AI army pool).
local function hold_members(D, L)
  for _, rec in ipairs(divisions.live_members(D)) do
    local p = rec.entity.position
    rec.order, rec.dest, rec.target, rec.issuer, rec.fails = "hold", {x = p.x, y = p.y}, nil, divisions.ISSUER, nil
  end
  D.state = "holding"
  L.held = game.tick
end

divisions.on_changed(function(D, what)
  if what ~= "state" or D.state ~= "idle" then return end
  local s = storage.fronts
  local L = s and s.lines[D.id]
  if not L then return end
  if L.phase == "march" then
    local o = D.order
    local seg = fronts.segment(D.force, L.segment)
    if seg and o and o.kind == "move" and L.target and o.target and util.distance(o.target, L.target) < 1 then
      spread(D, L, seg)
    end
  elseif L.phase == "hold" and D.order and D.order.kind == "hold_line" then
    hold_members(D, L)
  end
end)

-- Line upkeep: a marching division spreads when it arrived; holding ones put drifted members and newcomers back.
local function line_check(tick, maintain)
  local s = storage.fronts
  if not (s and next(s.lines)) then return end
  for _, id in ipairs(sorted_keys(s.lines)) do
    local L = s.lines[id]
    local D = divisions.get(id)
    local seg = D and fronts.segment(D.force, L.segment)
    -- still this line: the hold_line order, or its march (a regroup re-issues the same move)
    local o = D and D.order
    local ours = o and (o.kind == "hold_line" or (L.phase == "march" and o.kind == "move" and L.target and o.target
      and util.distance(o.target, L.target) < 1))
    if not (D and seg and ours) then
      s.lines[id] = nil
      if seg and seg.holder == id then
        seg.holder = nil
        redraw(D and D.force or seg.enemy)
      end
    elseif L.phase == "march" then
      if D.state == "idle" then spread(D, L, seg) end
    elseif maintain and (D.state == "idle" or D.state == "holding") then
      local recs = divisions.live_members(D)
      local a, b = chord_of(seg, L.part)
      local moved = util.distance(a, L.a) > 8 or util.distance(b, L.b) > 8
      if moved or #recs ~= L.n then
        spread(D, L, seg)
      else
        local only, n = {}, 0
        local surface = recs[1] and recs[1].entity.surface
        for _, rec in ipairs(recs) do
          local un = rec.entity.unit_number
          local slot = L.slots[un]
          if slot and util.distance(rec.entity.position, slot) > H.drift
             and not surface.find_nearest_enemy({position = rec.entity.position, max_distance = H.enemy_clear,
                                                 force = D.force}) then
            only[un] = true
            n = n + 1
          end
        end
        if n > 0 then
          send_to_slots(D, recs, L.slots, only)
          util.log("front: division #%d %s: %d member(s) back to the line of segment %d", D.id, divisions.label(D), n,
            seg.id)
        end
      end
    end
  end
end

events.on_nth_tick(60, function(e) line_check(e.tick, e.tick % H.maintain == 0) end)

--- The division panel's Hold line: the segment nearest the division. Returns ok, reason.
function fronts.hold_nearest(div_id)
  local D = divisions.get(div_id)
  if not D then return false, "no-division" end
  divisions.strength(D, true)
  local seg = D.pos and fronts.nearest(D.force, D.pos)
  if not seg then return false, "no-front" end
  return divisions.order(div_id, "hold_line", seg.id)
end

---------------------------------------------------------------------------
-- H key
---------------------------------------------------------------------------
-- Whole divisions in a player's selection, sorted by id.
local function selected_divisions(player_index)
  local p = storage.players and storage.players[player_index]
  local whole = p and p.selection and selection.whole_divisions(p.selection) or {}
  local ids = {}
  for id, ok in pairs(whole) do
    if ok then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

local function pick(player_index, cursor)
  if not (nation() and cursor) then return nil end
  local ids = selected_divisions(player_index)
  if #ids == 0 then return nil end
  local seg = fronts.nearest(selection.force_name(player_index), cursor, H.pick)
  if not seg then return nil end
  return seg, ids
end

--- H claims (orders.lua): whole divisions selected and the cursor near an own segment: hold_line, not hold.
function fronts.claims_h(player_index, cursor)
  return pick(player_index, cursor) ~= nil
end
orders.h_claim = fronts.claims_h

--- H (hud.lua P4.KEYS): the selected divisions hold the segment at the cursor (sharing its chord).
function fronts.key_h(player, e)
  local seg, ids = pick(player.index, e and e.cursor_position)
  if not seg then return false end
  -- divisions along the chord in the order of their centroids
  local proj = {}
  for _, id in ipairs(ids) do
    local D = divisions.get(id)
    divisions.strength(D, true)
    local _, t = to_chord(D.pos or seg.mid, seg.a, seg.b)
    proj[id] = t
  end
  table.sort(ids, function(u, v)
    if proj[u] ~= proj[v] then return proj[u] < proj[v] end
    return u < v
  end)
  local n = 0
  for i, id in ipairs(ids) do
    if fronts.hold_line(id, seg.id, {part = {i = i, k = #ids}}) then n = n + 1 end
  end
  util.log("order hold_line segment=%d divisions=%d player=%d", seg.id, n, player.index)
  return n > 0
end

match.on_teardown(function()
  local s = storage.fronts
  for _, list in pairs(s and s.objs or {}) do
    for _, o in ipairs(list) do
      if o.valid then o.destroy() end
    end
  end
  storage.fronts = nil
  for _, N in pairs(storage.nations or {}) do N.fronts = nil end
end)

--- One line for logs: "rts-player: 3 segments [#1 160 t 42 held by #4, ...]".
function fronts.describe(force_name)
  local parts = {}
  for _, seg in ipairs(fronts.segments(force_name)) do
    parts[#parts + 1] = string.format("#%d %.0f t%d%s", seg.id, seg.chord, seg.threat,
      seg.holder and (" held by #" .. seg.holder) or "")
  end
  return string.format("%s: %d segments [%s]", force_name, #parts, table.concat(parts, ", "))
end

return fronts
