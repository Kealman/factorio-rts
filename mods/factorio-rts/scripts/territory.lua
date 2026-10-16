-- Phase 5 M1 territory (docs/PHASE5-M1.md section 3 "territory.lua"; study docs/research/scale/territory-cities.md
-- section 2). Nation mode only (storage.match.config.mode == "nation"); in Skirmish nothing here does any work.
--
-- Grid. The match surface is cut into CELL x CELL tile cells (8x8): the world's size (storage.world.size) when the world
-- module made one, else the arena ([-arena_half, arena_half)^2). Every cell stores its owner (a force id byte, 0 =
-- neutral) and its city (a city id byte, 0 = none) in row strings, one byte per cell: storage.territory.owner[row] and
-- .city[row] (row = cell y + 1; byte = cell x + 1). owner_at / city_at read one byte.
--
-- Sources. territory.add_source(entity, radius_tiles, opts) claims land around an entity: City Centers and the capital
-- (scripts/cities.lua, radius by tier 48/72/96), forts (24), hubs (16) and radars (16; this module registers forts,
-- hubs and radars itself from the building registry). A source scores s * (1 - d^2 / (r + 1)^2) on every cell within r
-- cells (s = strength, balance.nation.territory.strength); the highest score wins. A cell keeps its owner unless a
-- challenger beats the owner's own best score by STICKY (15 %), so borders do not flicker. The city of a cell is the
-- winning source's city; a fort, hub or radar hands its cells to the nearest city of its force.
--
-- Job queue. A source change queues the bounding box of its old and new disk. Each tick the queue recomputes at most
-- CELL_BUDGET cells and then redraws at most SEG_BUDGET render segments, so a change never costs more than about a
-- millisecond in one tick and finishes within a few ticks. When a job is done, the signal "rts_territory_changed"
-- {force, cells, delta, lost, lost_at, lost_city, box} is emitted (events.emit) for every force whose land changed.
--
-- Borders. Render objects per segment of SEG cells: horizontal boundary segments ("h"), vertical ones ("v") and the
-- chart tint per row ("t"). A border edge between two cells of different owners gets a line on each owned side, 0.5
-- tiles inside, in the owner's colour (match.FORCE_COLORS): a dashed GAME_WIDTH px line drawn on the ground in the game
-- view and a solid CHART_WIDTH px line in the chart (map) view; owned row runs get a faint filled rectangle in the chart
-- view only. Borders are public (no forces filter), as in Rise of Nations. Only the segments a job changed are redrawn.
--
-- Build rules (buildings.on_build_check, players' ghosts and robots; script placements are trusted). Classes:
--   city      rts-city-center: own or neutral land, at least balance.nation.cities.spacing tiles from every City
--             Center (any force), at most `limit` cities per nation
--   outpost   fort, hub, radar, turrets, depot: own or neutral land
--   infra     belts, inserters, poles, pipes, walls, rails, stockpiles: own or neutral land
--   economic  everything else (extractors, smelters, factories, barracks, labs, power): own land only
--   No building of any class on enemy land. A refused player ghost is removed with a flying text; a refused robot build
--   is removed and its item goes back to the force's pool. The AI asks territory.can_build before it places a ghost
--   (scripts/ai/construction.lua).
--
-- Attrition. Every `period` ticks, every unit (storage.units: units, haulers, the Commander) standing on another
-- force's land whose 5x5 cell window is all that force's (at least 16 tiles deep) takes `share` (1.5 %) of its max
-- health as damage type rts-attrition from the land's owner (about 18 % per minute; the Commander half), unless it is
-- within supply_radius (24) tiles of an own City Center, capital, hub or fort.
--
-- Forts get balance.nation.territory.fort_ammo free magazines when built and are fed from the network covering them
-- like turrets (production.TURRET_MIN / TURRET_FEED).
--
-- Owns storage.territory = {active, match_id, surface (index), cell, x0, y0 (tile of cell (0, 0)), w, h (cells),
--   owner = {row strings}, city = {row strings}, fids = {[force] = id}, fnames = {[id] = force},
--   sources = {[unit_number] = {un, force, fid, x, y, cx, cy, r (cells), s, kind, city, entity}},
--   counts = {[fid] = owned cells}, city_cells = {[city id] = cells}, jobs = {...}, objs = {[segment key] = {LuaRenderObject}},
--   nobj, attrition = {dealt = {[unit_number] = hp}, total, hits, passes, by_force = {[force] = {hp, hits, kills}}},
--   stats = {jobs, cells, segments}}
-- cleared by match teardown. Log lines "[rts] territory: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local economy = require("scripts.economy")
local match = require("scripts.match")
local balance = require("balance")

local territory = {}

local TB = balance.nation.territory
local CB = balance.nation.cities

territory.CELL = TB.cell
territory.SEG = 16                -- cells per render segment
territory.CELL_BUDGET = 3000      -- cells recomputed per tick at most (about 0.3 ms)
territory.SEG_BUDGET = 16         -- render segments redrawn per tick at most (24 measured up to 0.87 ms)
territory.STICKY = TB.sticky
territory.GAME_WIDTH = 12         -- px at zoom 1 (32 px per tile)
territory.CHART_WIDTH = 3
territory.DASH, territory.GAP = 1.5, 0.75  -- tiles (game view)
territory.LINE_ALPHA = 0.9
territory.TINT_ALPHA = 0.16
territory.FORT_FEED_PERIOD = 120
territory.SIZE_OVERRIDE = nil     -- test copies: grid side in tiles (a 2048 grid on the 512 arena)
territory.PROFILE_STEPS = false   -- test copies: log the time of every job-queue tick ("territory: step ...")
territory.SIGNAL = "rts_territory_changed"
territory.DEFAULT_COLOR = {r = 0.7, g = 0.7, b = 0.7}

-- Building classes (see the header). Entity names first, then entity types for infrastructure.
territory.CLASS_BY_NAME = {
  ["rts-city-center"] = "city",
  ["rts-fort"] = "outpost", ["rts-hub"] = "outpost", ["rts-radar"] = "outpost", ["rts-turret"] = "outpost",
  ["rts-laser-turret"] = "outpost", ["rts-depot"] = "outpost",
  ["rts-wall"] = "infra", ["rts-stockpile"] = "infra",
}
territory.INFRA_TYPES = {}
for _, t in ipairs({"transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "inserter",
                    "electric-pole", "pipe", "pipe-to-ground", "pump", "wall", "gate", "lamp", "straight-rail",
                    "curved-rail-a", "curved-rail-b", "half-diagonal-rail", "legacy-straight-rail", "legacy-curved-rail",
                    "elevated-straight-rail", "elevated-curved-rail-a", "elevated-curved-rail-b",
                    "elevated-half-diagonal-rail", "rail-ramp", "rail-support", "rail-signal", "rail-chain-signal",
                    "train-stop", "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"}) do
  territory.INFRA_TYPES[t] = true
end
territory.REASON_KEYS = {
  enemy = "rts.territory-refused-enemy",
  ["not-own"] = "rts.territory-refused-not-own",
  spacing = "rts.territory-refused-spacing",
  limit = "rts.territory-refused-limit",
}
-- Kinds of sources that stop attrition for their force (radars do not).
local SUPPLY_KINDS = {city = true, hub = true, fort = true}

local class_cache = {} -- [entity name] = class (prototype data only)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function fresh()
  return {active = false, sources = {}, jobs = {}, objs = {}, nobj = 0, counts = {}, city_cells = {}, fids = {},
          fnames = {}, owner = {}, city = {}, attrition = {dealt = {}, total = 0, hits = 0, passes = 0},
          stats = {jobs = 0, cells = 0, segments = 0}}
end

function territory.init()
  storage.territory = storage.territory or fresh()
end

--- True while a Nation-mode match has an arena (the module's rules apply).
function territory.nation()
  local m = storage.match
  return m ~= nil and m.surface ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function grid()
  local T = storage.territory
  if T and T.active then return T end
  return nil
end

local function force_id(T, force_name)
  local id = T.fids[force_name]
  if id then return id end
  id = #T.fnames + 1
  T.fnames[id] = force_name
  T.fids[force_name] = id
  T.counts[id] = 0
  return id
end

local function grid_side()
  if territory.SIZE_OVERRIDE then return territory.SIZE_OVERRIDE end
  local w = storage.world
  if w and type(w.size) == "number" and w.size > 0 then return w.size end
  return 2 * match.arena_half()
end

--- The grid of the current Nation-mode match, created on first use (nil in Skirmish or the lobby).
function territory.ensure_grid()
  local T = grid()
  local m = storage.match
  if T and T.match_id == (m and m.match_id) then return T end
  if not territory.nation() then return nil end
  local surface = match.surface()
  if not surface then return nil end
  local cell = territory.CELL
  local n = math.ceil(grid_side() / cell)
  T = fresh()
  T.active, T.match_id, T.surface, T.cell = true, m.match_id, surface.index, cell
  T.w, T.h = n, n
  T.x0, T.y0 = -n * cell / 2, -n * cell / 2
  local zero = string.rep("\0", n)
  for r = 1, n do
    T.owner[r] = zero
    T.city[r] = zero
  end
  storage.territory = T
  util.log("territory: grid %dx%d cells of %d tiles (%d tiles) from (%d, %d) on %s", n, n, cell, n * cell, T.x0, T.y0,
    surface.name)
  return T
end

---------------------------------------------------------------------------
-- Lookups
---------------------------------------------------------------------------
local function cell_of(T, x, y)
  local cx = math.floor((x - T.x0) / T.cell)
  local cy = math.floor((y - T.y0) / T.cell)
  if cx < 0 or cy < 0 or cx >= T.w or cy >= T.h then return nil end
  return cx, cy
end
territory.cell_of = function(position)
  local T = grid()
  if not T then return nil end
  local x, y = util.xy(position)
  return cell_of(T, x, y)
end

local function owner_byte(T, cx, cy) return string.byte(T.owner[cy + 1], cx + 1) end

--- Force that owns the land at `position`, or nil (neutral, outside the grid, or no Nation match).
function territory.owner_at(position)
  local T = grid()
  if not T then return nil end
  local x, y = util.xy(position)
  local cx, cy = cell_of(T, x, y)
  if not cx then return nil end
  local b = owner_byte(T, cx, cy)
  return b > 0 and T.fnames[b] or nil
end

--- City id of the land at `position`, or nil.
function territory.city_at(position)
  local T = grid()
  if not T then return nil end
  local x, y = util.xy(position)
  local cx, cy = cell_of(T, x, y)
  if not cx then return nil end
  local b = string.byte(T.city[cy + 1], cx + 1)
  return b > 0 and b or nil
end

--- Owned cells of a force.
function territory.cells(force_name)
  local T = grid()
  local id = T and T.fids[force_name]
  return id and T.counts[id] or 0
end

--- Cells of a city's land.
function territory.city_cells(city_id)
  local T = grid()
  return T and T.city_cells[city_id] or 0
end

--- Fraction of the claimable cells a force owns (M1: every grid cell is claimable).
function territory.share(force_name)
  local T = grid()
  if not T then return 0 end
  return territory.cells(force_name) / (T.w * T.h)
end

--- Grid checksum (save/load check): a hash over both layers.
function territory.checksum()
  local T = grid()
  if not T then return 0 end
  local h = 7
  for r = 1, T.h do
    local row, crow = T.owner[r], T.city[r]
    for i = 1, T.w do
      local o, c = string.byte(row, i), string.byte(crow, i)
      if o > 0 or c > 0 then h = (h * 31 + (r * 4096 + i) * 7 + o * 257 + c) % 2147483629 end
    end
  end
  return h
end

--- Render objects this module holds (and how many of them are still valid).
function territory.object_count()
  local T = storage.territory
  if not T then return 0, 0 end
  local n, valid = 0, 0
  for _, list in pairs(T.objs or {}) do
    for _, o in ipairs(list) do
      n = n + 1
      if o.valid then valid = valid + 1 end
    end
  end
  return n, valid
end

---------------------------------------------------------------------------
-- Jobs
---------------------------------------------------------------------------
local function disk_box(T, src)
  local r = math.ceil(src.r)
  return {x0 = math.max(0, src.cx - r), y0 = math.max(0, src.cy - r),
          x1 = math.min(T.w - 1, src.cx + r), y1 = math.min(T.h - 1, src.cy + r)}
end

local function union(a, b)
  if not a then return b end
  if not b then return a end
  return {x0 = math.min(a.x0, b.x0), y0 = math.min(a.y0, b.y0), x1 = math.max(a.x1, b.x1), y1 = math.max(a.y1, b.y1)}
end

local function queue_job(T, box, why)
  if not box then return end
  for _, j in ipairs(T.jobs) do
    if not j.started and j.x0 <= box.x1 + 1 and box.x0 <= j.x1 + 1 and j.y0 <= box.y1 + 1 and box.y0 <= j.y1 + 1 then
      j.x0, j.y0 = math.min(j.x0, box.x0), math.min(j.y0, box.y0)
      j.x1, j.y1 = math.max(j.x1, box.x1), math.max(j.y1, box.y1)
      j.why = j.why .. "+" .. why
      return j
    end
  end
  local j = {x0 = box.x0, y0 = box.y0, x1 = box.x1, y1 = box.y1, row = box.y0, phase = "compute", why = why,
             queued = game.tick, rows = {}, delta = {}, lost = {}}
  T.jobs[#T.jobs + 1] = j
  return j
end

--- Queue a recompute of the cells around a position (radius in tiles): tests and other modules.
function territory.touch(position, radius_tiles, why)
  local T = grid()
  if not T then return end
  local x, y = util.xy(position)
  local cx, cy = cell_of(T, x, y)
  if not cx then return end
  queue_job(T, disk_box(T, {cx = cx, cy = cy, r = radius_tiles / T.cell}), why or "touch")
end

-- Sources whose disk reaches the job's box, plus the city sources per force (nearest-city fallback).
local function job_sources(T, j)
  local list, cities_by_fid = {}, {}
  for _, src in pairs(T.sources) do
    local r = src.r
    if src.cx + r >= j.x0 and src.cx - r <= j.x1 and src.cy + r >= j.y0 and src.cy - r <= j.y1 then
      list[#list + 1] = src
    end
    if src.city then
      local l = cities_by_fid[src.fid]
      if not l then
        l = {}
        cities_by_fid[src.fid] = l
      end
      l[#l + 1] = src
    end
  end
  table.sort(list, function(a, b) return a.un < b.un end)
  for _, l in pairs(cities_by_fid) do table.sort(l, function(a, b) return a.un < b.un end) end
  return list, cities_by_fid
end

local function nearest_city(cities_by_fid, fid, cx, cy)
  local l = cities_by_fid[fid]
  if not l then return 0 end
  local best, bd = 0, math.huge
  for i = 1, #l do
    local s = l[i]
    local dx, dy = s.cx - cx, s.cy - cy
    local d = dx * dx + dy * dy
    if d < bd then best, bd = s.city, d end
  end
  return best
end

-- Recompute rows of job j within `budget` cells. Returns the budget left.
local function compute(T, j, budget)
  local srcs, cities_by_fid = job_sources(T, j)
  local sticky = territory.STICKY
  local width = j.x1 - j.x0 + 1
  local n = #srcs
  while j.row <= j.y1 and (budget >= width or budget == territory.CELL_BUDGET) do
    local cy = j.row
    local orow, crow = T.owner[cy + 1], T.city[cy + 1]
    local olds = {string.byte(orow, j.x0 + 1, j.x1 + 1)}
    local oldc = {string.byte(crow, j.x0 + 1, j.x1 + 1)}
    local news, newc = {}, {}
    local cmin, cmax, ccity = nil, nil, false
    for i = 1, width do
      local cx = j.x0 + i - 1
      local cur = olds[i]
      local best_f, best_s, best_src = 0, 0, nil
      local cur_s, cur_src = 0, nil
      for k = 1, n do
        local s = srcs[k]
        local dx, dy = cx - s.cx, cy - s.cy
        local d2 = dx * dx + dy * dy
        if d2 <= s.r2 then
          local v = s.s * (1 - d2 / s.rr)
          if v > 0 then
            if s.fid == cur and v > cur_s then cur_s, cur_src = v, s end
            if v > best_s then best_s, best_f, best_src = v, s.fid, s end
          end
        end
      end
      local f, win = best_f, best_src
      if cur ~= 0 and cur_s > 0 and best_f ~= cur and best_s <= cur_s * sticky then f, win = cur, cur_src end
      local c = 0
      if f ~= 0 then c = (win and win.city) or nearest_city(cities_by_fid, f, cx, cy) end
      news[i], newc[i] = f, c
      if f ~= cur then
        if cur ~= 0 then
          T.counts[cur] = (T.counts[cur] or 0) - 1
          j.delta[cur] = (j.delta[cur] or 0) - 1
          local L = j.lost[cur]
          if not L then
            L = {n = 0, sx = 0, sy = 0, city = {}}
            j.lost[cur] = L
          end
          L.n, L.sx, L.sy = L.n + 1, L.sx + cx, L.sy + cy
          local oc = oldc[i]
          if oc > 0 then L.city[oc] = (L.city[oc] or 0) + 1 end
        end
        if f ~= 0 then
          T.counts[f] = (T.counts[f] or 0) + 1
          j.delta[f] = (j.delta[f] or 0) + 1
        end
        if not cmin then cmin = cx end
        cmax = cx
      end
      if c ~= oldc[i] then
        ccity = true
        if oldc[i] > 0 then T.city_cells[oldc[i]] = (T.city_cells[oldc[i]] or 0) - 1 end
        if c > 0 then T.city_cells[c] = (T.city_cells[c] or 0) + 1 end
      end
    end
    if cmin then
      T.owner[cy + 1] = string.sub(orow, 1, j.x0) .. string.char(table.unpack(news)) .. string.sub(orow, j.x1 + 2)
      j.rows[#j.rows + 1] = {cy, cmin, cmax}
    end
    if ccity then
      T.city[cy + 1] = string.sub(crow, 1, j.x0) .. string.char(table.unpack(newc)) .. string.sub(crow, j.x1 + 2)
    end
    budget = budget - width
    j.row = j.row + 1
    T.stats.cells = T.stats.cells + width
  end
  if j.row > j.y1 then
    -- the render segments the changed cells touch
    local SEG = territory.SEG
    local set, list = {}, {}
    local function add(key, kind, a, b)
      if not set[key] then
        set[key] = true
        list[#list + 1] = {kind, a, b}
      end
    end
    for _, r in ipairs(j.rows) do
      local cy, a, b = r[1], r[2], r[3]
      local sa, sb = math.floor(a / SEG), math.floor(b / SEG)
      for s = sa, sb do
        add("h:" .. cy .. ":" .. s, "h", cy, s)
        add("h:" .. (cy + 1) .. ":" .. s, "h", cy + 1, s)
        add("t:" .. cy .. ":" .. s, "t", cy, s)
      end
      local sy = math.floor(cy / SEG)
      for c = a, b + 1 do add("v:" .. c .. ":" .. sy, "v", c, sy) end
    end
    j.draw, j.next_draw = list, 1
    j.phase = "draw"
  end
  return budget
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local function color_of(T, fid, alpha)
  local c = match.FORCE_COLORS[T.fnames[fid]] or territory.DEFAULT_COLOR
  -- render colours are premultiplied by alpha
  return {r = c.r * alpha, g = c.g * alpha, b = c.b * alpha, a = alpha}
end

local function line(T, fid, x1, y1, x2, y2, out)
  local surface = T.surface
  local c = color_of(T, fid, territory.LINE_ALPHA)
  out[#out + 1] = rendering.draw_line({surface = surface, color = c, width = territory.GAME_WIDTH,
    dash_length = territory.DASH, gap_length = territory.GAP, from = {x1, y1}, to = {x2, y2}, draw_on_ground = true,
    render_mode = "game"})
  out[#out + 1] = rendering.draw_line({surface = surface, color = c, width = territory.CHART_WIDTH,
    from = {x1, y1}, to = {x2, y2}, render_mode = "chart"})
end

local function clear_segment(T, key)
  local old = T.objs[key]
  if not old then return end
  for _, o in ipairs(old) do
    if o.valid then o.destroy() end
  end
  T.nobj = T.nobj - #old
  T.objs[key] = nil
end

-- Owner of cell (cx, cy), 0 outside the grid.
local function own(T, cx, cy)
  if cx < 0 or cy < 0 or cx >= T.w or cy >= T.h then return 0 end
  return string.byte(T.owner[cy + 1], cx + 1)
end

local function draw_segment(T, kind, a, s)
  local key = kind .. ":" .. a .. ":" .. s
  clear_segment(T, key)
  local SEG, cell = territory.SEG, T.cell
  local out = {}
  if kind == "h" then
    -- horizontal boundary a: between row a - 1 (above) and row a (below); columns of segment s
    local c0, c1 = s * SEG, math.min((s + 1) * SEG, T.w) - 1
    local wy = T.y0 + a * cell
    local c = c0
    while c <= c1 do
      local up, dn = own(T, c, a - 1), own(T, c, a)
      if up ~= dn then
        local start = c
        while c + 1 <= c1 and own(T, c + 1, a - 1) == up and own(T, c + 1, a) == dn do c = c + 1 end
        local wx0, wx1 = T.x0 + start * cell, T.x0 + (c + 1) * cell
        if up > 0 then line(T, up, wx0, wy - 0.5, wx1, wy - 0.5, out) end
        if dn > 0 then line(T, dn, wx0, wy + 0.5, wx1, wy + 0.5, out) end
      end
      c = c + 1
    end
  elseif kind == "v" then
    -- vertical boundary a: between column a - 1 (left) and column a (right); rows of segment s
    local r0, r1 = s * SEG, math.min((s + 1) * SEG, T.h) - 1
    local wx = T.x0 + a * cell
    local r = r0
    while r <= r1 do
      local lf, rt = own(T, a - 1, r), own(T, a, r)
      if lf ~= rt then
        local start = r
        while r + 1 <= r1 and own(T, a - 1, r + 1) == lf and own(T, a, r + 1) == rt do r = r + 1 end
        local wy0, wy1 = T.y0 + start * cell, T.y0 + (r + 1) * cell
        if lf > 0 then line(T, lf, wx - 0.5, wy0, wx - 0.5, wy1, out) end
        if rt > 0 then line(T, rt, wx + 0.5, wy0, wx + 0.5, wy1, out) end
      end
      r = r + 1
    end
  else
    -- chart tint of row a, columns of segment s
    local c0, c1 = s * SEG, math.min((s + 1) * SEG, T.w) - 1
    local wy0, wy1 = T.y0 + a * cell, T.y0 + (a + 1) * cell
    local c = c0
    while c <= c1 do
      local o = own(T, c, a)
      if o > 0 then
        local start = c
        while c + 1 <= c1 and own(T, c + 1, a) == o do c = c + 1 end
        out[#out + 1] = rendering.draw_rectangle({surface = T.surface, color = color_of(T, o, territory.TINT_ALPHA),
          filled = true, left_top = {T.x0 + start * cell, wy0}, right_bottom = {T.x0 + (c + 1) * cell, wy1},
          render_mode = "chart"})
      end
      c = c + 1
    end
  end
  if #out > 0 then
    T.objs[key] = out
    T.nobj = T.nobj + #out
  end
  T.stats.segments = T.stats.segments + 1
end

local function draw(T, j, budget)
  local list = j.draw
  while budget > 0 and j.next_draw <= #list do
    local d = list[j.next_draw]
    draw_segment(T, d[1], d[2], d[3])
    j.next_draw = j.next_draw + 1
    budget = budget - 1
  end
  if j.next_draw > #list then j.phase = "done" end
  return budget
end

local function finish(T, j)
  T.stats.jobs = T.stats.jobs + 1
  local fids = {}
  for fid in pairs(j.delta) do fids[#fids + 1] = fid end
  for fid in pairs(j.lost) do
    if not j.delta[fid] then fids[#fids + 1] = fid end
  end
  table.sort(fids)
  local parts = {}
  for _, fid in ipairs(fids) do
    local force = T.fnames[fid]
    local L = j.lost[fid]
    local data = {force = force, cells = T.counts[fid] or 0, delta = j.delta[fid] or 0, lost = L and L.n or 0,
                  box = {x0 = j.x0, y0 = j.y0, x1 = j.x1, y1 = j.y1}}
    if L and L.n > 0 then
      local cell = T.cell
      data.lost_at = {x = T.x0 + (L.sx / L.n + 0.5) * cell, y = T.y0 + (L.sy / L.n + 0.5) * cell}
      local best, bn = nil, 0
      for id, n in pairs(L.city) do
        if n > bn or (n == bn and best and id < best) then best, bn = id, n end
      end
      data.lost_city = best
    end
    parts[#parts + 1] = string.format("%s %+d (%d, lost %d)", force, data.delta, data.cells, data.lost)
    events.emit(territory.SIGNAL, data)
  end
  util.log("territory: job %s box (%d,%d)-(%d,%d) done in %d ticks: %d rows changed, %d segments; %s; %d objects",
    j.why, j.x0, j.y0, j.x1, j.y1, game.tick - j.queued, #j.rows, #j.draw, #parts > 0 and table.concat(parts, ", ")
    or "no change", T.nobj)
end

--- Run the job queue for one tick (also called by tests to finish work at once: territory.flush()).
function territory.step()
  local T = grid()
  if not (T and T.jobs[1]) then return end
  local prof = territory.PROFILE_STEPS and helpers.create_profiler() or nil
  local budget, segs = territory.CELL_BUDGET, territory.SEG_BUDGET
  while true do
    local j = T.jobs[1]
    if not j then break end
    j.started = true
    if j.phase == "compute" then
      budget = compute(T, j, budget)
      if j.phase == "compute" then break end
    end
    if j.phase == "draw" then
      segs = draw(T, j, segs)
      if j.phase == "draw" then break end
    end
    finish(T, j)
    table.remove(T.jobs, 1)
    if budget <= 0 or segs <= 0 then break end
  end
  if prof then
    prof.stop()
    log({"", string.format("[rts] territory: step tick %d: %d cells, %d segments, %d jobs left: ", game.tick,
      territory.CELL_BUDGET - budget, territory.SEG_BUDGET - segs, #T.jobs), prof})
  end
end

--- Finish every queued job now (tests, match setup).
function territory.flush()
  local T = grid()
  local n = 0
  while T and T.jobs[1] and n < 100000 do
    territory.step()
    n = n + 1
  end
  return n
end

--- Jobs waiting or running.
function territory.pending()
  local T = grid()
  return T and #T.jobs or 0
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------
--- Claim land around `entity` (City Center, capital, fort, hub, radar). opts = {strength, kind = "city" | "fort" |
--- "hub" | "radar" | ..., city = city id}. Calling it again for the same entity updates the radius and strength.
--- Returns true when the source is registered (Nation mode, entity on the match surface inside the grid).
function territory.add_source(entity, radius_tiles, opts)
  opts = opts or {}
  local T = territory.ensure_grid()
  if not (T and entity and entity.valid and entity.unit_number) then return false end
  if entity.surface.index ~= T.surface then return false end
  local p = entity.position
  local cx, cy = cell_of(T, p.x, p.y)
  if not cx then return false end
  local un = entity.unit_number
  local old = T.sources[un]
  local r = radius_tiles / T.cell
  local src = {un = un, force = entity.force.name, fid = force_id(T, entity.force.name), x = p.x, y = p.y, cx = cx,
               cy = cy, r = r, r2 = r * r, rr = (r + 1) * (r + 1), s = opts.strength or 1, kind = opts.kind or "other",
               city = opts.city, entity = entity}
  T.sources[un] = src
  local box = disk_box(T, src)
  if old then box = union(box, disk_box(T, old)) end
  queue_job(T, box, (old and "update " or "add ") .. src.kind .. "#" .. un)
  util.log("territory: source %s #%d of %s at %s radius %d tiles strength %.1f%s", src.kind, un, src.force,
    util.pos_str(p), radius_tiles, src.s, src.city and (" city " .. src.city) or "")
  return true
end

--- Change the radius (tiles) and strength of a registered source.
function territory.update_source(unit_number, radius_tiles, strength)
  local T = grid()
  local src = T and T.sources[unit_number]
  if not src then return false end
  local before = disk_box(T, src)
  src.r = radius_tiles / T.cell
  src.r2, src.rr = src.r * src.r, (src.r + 1) * (src.r + 1)
  if strength then src.s = strength end
  queue_job(T, union(before, disk_box(T, src)), "update " .. src.kind .. "#" .. unit_number)
  util.log("territory: source %s #%d radius %d tiles strength %.1f", src.kind, unit_number, radius_tiles, src.s)
  return true
end

--- Drop a source (its land is recomputed by the queue).
function territory.remove_source(unit_number)
  local T = grid()
  local src = T and T.sources[unit_number]
  if not src then return false end
  T.sources[unit_number] = nil
  queue_job(T, disk_box(T, src), "remove " .. src.kind .. "#" .. unit_number)
  util.log("territory: source %s #%d of %s removed", src.kind, unit_number, src.force)
  return true
end

--- The source record of a unit number, or nil.
function territory.source(unit_number)
  local T = grid()
  return T and T.sources[unit_number] or nil
end

---------------------------------------------------------------------------
-- Build rules
---------------------------------------------------------------------------
--- Build class of an entity name: "city" | "outpost" | "infra" | "economic".
function territory.class_of(name)
  local c = class_cache[name]
  if c then return c end
  c = territory.CLASS_BY_NAME[name]
  if not c then
    local p = prototypes.entity[name]
    c = (p and territory.INFRA_TYPES[p.type]) and "infra" or "economic"
  end
  class_cache[name] = c
  return c
end

local function box_of(name, position, direction)
  local p = prototypes.entity[name]
  local cb = p and p.collision_box or {left_top = {x = -0.4, y = -0.4}, right_bottom = {x = 0.4, y = 0.4}}
  local lx, ly, rx, ry = cb.left_top.x, cb.left_top.y, cb.right_bottom.x, cb.right_bottom.y
  if direction == defines.direction.east or direction == defines.direction.west then
    lx, ly, rx, ry = -ry, lx, -ly, rx
  end
  local x, y = util.xy(position)
  return {left_top = {x = x + lx, y = y + ly}, right_bottom = {x = x + rx, y = y + ry}}
end

local function count_cities(T, fid)
  local n = 0
  for _, src in pairs(T.sources) do
    if src.kind == "city" and src.fid == fid then n = n + 1 end
  end
  return n
end

--- Can `force` build `entity_name` there? `where` is a position, or a BoundingBox ({left_top, right_bottom}).
--- Returns ok, reason ("enemy" | "not-own" | "spacing" | "limit"), class. Always true outside Nation mode.
function territory.can_build(force, entity_name, where, direction)
  local T = grid()
  if not T then return true end
  local force_name = type(force) == "string" and force or force.name
  local class = territory.class_of(entity_name)
  local box = (where.left_top and where.right_bottom) and where or box_of(entity_name, where, direction)
  local lt, rb = box.left_top, box.right_bottom
  local ax, ay = util.xy(lt)
  local bx, by = util.xy(rb)
  local fid = T.fids[force_name] or -1
  local c0, r0 = math.floor((ax + 0.01 - T.x0) / T.cell), math.floor((ay + 0.01 - T.y0) / T.cell)
  local c1, r1 = math.floor((bx - 0.01 - T.x0) / T.cell), math.floor((by - 0.01 - T.y0) / T.cell)
  local foreign = false
  for cy = r0, r1 do
    for cx = c0, c1 do
      local o = own(T, cx, cy)
      if o ~= 0 and o ~= fid then return false, "enemy", class end
      if o ~= fid then foreign = true end
    end
  end
  if class == "economic" and foreign then return false, "not-own", class end
  if class == "city" then
    local cx, cy = (ax + bx) / 2, (ay + by) / 2
    local spacing2 = CB.spacing * CB.spacing
    for _, src in pairs(T.sources) do
      if src.kind == "city" then
        local dx, dy = src.x - cx, src.y - cy
        if dx * dx + dy * dy < spacing2 then return false, "spacing", class end
      end
    end
    if fid > 0 and count_cities(T, fid) >= CB.limit then return false, "limit", class end
  end
  return true, nil, class
end

--- The flying text / message of a refusal reason.
function territory.reason_text(reason, entity_name)
  local key = territory.REASON_KEYS[reason] or "rts.territory-refused-enemy"
  if reason == "spacing" then return {key, CB.spacing} end
  if reason == "limit" then return {key, CB.limit} end
  if reason == "not-own" then return {key, {"entity-name." .. entity_name}} end
  return {key}
end

local BUILD_EVENTS = {[defines.events.on_built_entity] = "player", [defines.events.on_robot_built_entity] = "robot"}
local MOBILE = {unit = true, ["spider-unit"] = true, ["spider-vehicle"] = true, character = true, car = true}

-- buildings.on_build_check: players' ghosts and robot builds (script placements are trusted).
local function build_check(entity, e)
  local who = BUILD_EVENTS[e.name]
  if not who then return true end
  local T = grid()
  if not T then return true end
  local ghost = entity.type == "entity-ghost"
  if entity.type == "tile-ghost" then return true end
  local name = ghost and entity.ghost_name or entity.name
  local proto = prototypes.entity[name]
  if not proto or MOBILE[proto.type] then return true end
  local force_name = entity.force.name
  local ok, reason = territory.can_build(force_name, name, entity.bounding_box)
  if ok then return true end
  local pos = entity.position
  local surface = entity.surface
  local item
  if not ghost then
    local items = entity.prototype.items_to_place_this
    item = items and items[1]
  end
  entity.destroy()
  if item then economy.give(force_name, item.name, item.count or 1) end
  local text = territory.reason_text(reason, name)
  local player = (e.player_index or 0) > 0 and game.get_player(e.player_index)
  if player and player.valid then
    player.create_local_flying_text({text = text, position = pos, surface = surface, color = {1, 0.4, 0.3}})
  end
  util.log("territory: refused %s%s of %s at %s (%s, %s by %s)", name, ghost and " ghost" or "", force_name,
    util.pos_str(pos), reason, territory.class_of(name), who)
  return false
end
buildings.on_build_check(build_check)
territory.build_check = build_check -- tests

---------------------------------------------------------------------------
-- Forts, hubs and radars as sources
---------------------------------------------------------------------------
local AUTO = {
  fort = {radius = TB.radius.fort, strength = TB.strength.fort},
  radar = {radius = TB.radius.radar, strength = TB.strength.radar},
}

buildings.on_added(function(un, rec)
  if not territory.nation() then return end
  local spec = AUTO[rec.kind]
  local kind = rec.kind
  if rec.kind == "hub" and rec.entity.name == "rts-hub" then
    spec, kind = {radius = TB.radius.hub, strength = TB.strength.hub}, "hub"
  end
  if not spec then return end
  territory.add_source(rec.entity, spec.radius, {kind = kind, strength = spec.strength})
  if kind == "fort" then
    local ammo = rec.entity.get_inventory(defines.inventory.turret_ammo)
    if ammo and TB.fort_ammo > 0 then ammo.insert({name = production.AMMO, count = TB.fort_ammo}) end
  end
end)

buildings.on_removed(function(un)
  local T = storage.territory
  if T and T.active and T.sources[un] then territory.remove_source(un) end
end)

events.on_nth_tick(territory.FORT_FEED_PERIOD, function()
  if not grid() then return end
  for _, rec in buildings.all("fort") do
    local e = rec.entity
    local ammo = e.get_inventory(defines.inventory.turret_ammo)
    if ammo and ammo.get_item_count(production.AMMO) < production.TURRET_MIN then
      local net = production.network_for(e)
      local got = net and net.remove_item({name = production.AMMO, count = production.TURRET_FEED}) or 0
      if got > 0 then
        local put = ammo.insert({name = production.AMMO, count = got})
        if put < got then net.insert({name = production.AMMO, count = got - put}) end
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Attrition
---------------------------------------------------------------------------
local function deep(T, cx, cy, o, d)
  for y = cy - d, cy + d do
    if y < 0 or y >= T.h then return false end
    local row = T.owner[y + 1]
    for x = cx - d, cx + d do
      if x < 0 or x >= T.w or string.byte(row, x + 1) ~= o then return false end
    end
  end
  return true
end

--- One attrition pass (every balance.nation.territory.attrition.period ticks). Returns units hit.
function territory.attrition_pass()
  local T = grid()
  if not T then return 0 end
  local A = TB.attrition
  local r2 = A.supply_radius * A.supply_radius
  local supply_points = {}
  for _, src in pairs(T.sources) do
    if SUPPLY_KINDS[src.kind] then
      local l = supply_points[src.force]
      if not l then
        l = {}
        supply_points[src.force] = l
      end
      l[#l + 1] = src
    end
  end
  local victims = {}
  for _, f in ipairs(match.forces()) do
    local fid = T.fids[f] or -1
    local points = supply_points[f]
    for un, rec in units.for_force(f) do
      local p = rec.entity.position
      local cx, cy = cell_of(T, p.x, p.y)
      if cx then
        local o = owner_byte(T, cx, cy)
        if o ~= 0 and o ~= fid and deep(T, cx, cy, o, A.depth_cells) then
          local supplied = false
          for _, s in ipairs(points or {}) do
            local dx, dy = s.x - p.x, s.y - p.y
            if dx * dx + dy * dy <= r2 then
              supplied = true
              break
            end
          end
          if not supplied then victims[#victims + 1] = {un, rec, o} end
        end
      end
    end
  end
  local AT = T.attrition
  AT.passes = AT.passes + 1
  AT.by_force = AT.by_force or {}
  for _, v in ipairs(victims) do
    local un, rec, o = v[1], v[2], v[3]
    local e = rec.entity
    if e.valid and e.health and e.max_health and e.max_health > 0 then
      local amount = e.max_health * A.share * (rec.kind == "commander" and A.commander or 1)
      local died = e.health <= amount
      local dealt = e.damage(amount, T.fnames[o], "rts-attrition")
      AT.dealt[un] = (AT.dealt[un] or 0) + dealt
      AT.total = AT.total + dealt
      AT.hits = AT.hits + 1
      local F = AT.by_force[rec.force]
      if not F then
        F = {hp = 0, hits = 0, kills = 0}
        AT.by_force[rec.force] = F
      end
      F.hp, F.hits = F.hp + dealt, F.hits + 1
      if died then F.kills = F.kills + 1 end
    end
  end
  -- one log line per minute while anything was hit: "territory: attrition so far: <force> <hp> hp, <hits> hits, <kills>"
  if AT.passes % 12 == 0 and AT.hits > (AT.logged_hits or 0) then
    AT.logged_hits = AT.hits
    local parts = {}
    for f, F in pairs(AT.by_force) do
      parts[#parts + 1] = string.format("%s %.0f hp, %d hits, %d killed", f, F.hp, F.hits, F.kills)
    end
    table.sort(parts)
    util.log("territory: attrition so far: %s", table.concat(parts, "; "))
  end
  return #victims
end

events.on_nth_tick(TB.attrition.period, function()
  if grid() then territory.attrition_pass() end
end)

---------------------------------------------------------------------------
-- Tick, teardown
---------------------------------------------------------------------------
events.on(defines.events.on_tick, function()
  local T = storage.territory
  if T and T.active and T.jobs[1] then territory.step() end
end)

match.on_teardown(function()
  local T = storage.territory
  local n = 0
  for key in pairs(T and T.objs or {}) do
    local list = T.objs[key]
    for _, o in ipairs(list) do
      if o.valid then
        o.destroy()
        n = n + 1
      end
    end
  end
  if T and T.active then
    util.log("territory: teardown: %d border objects destroyed, %d jobs dropped", n, #T.jobs)
  end
  storage.territory = fresh()
end)

return territory
