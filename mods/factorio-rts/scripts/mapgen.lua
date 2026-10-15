-- Map generation (docs/PHASE4.md 2.4 and 5): terrain, ore patches with finite totals, the neutral ruin, depletion
-- telemetry and the ruin capture.
--
-- match.start calls, in this order (docs/qa/phase4-mapgen-notes.md):
--   mapgen.plan(spec)            pure planning, no surface: every patch (main, natural, middle), lakes, cliff walls,
--                                forests and the ruin. Every feature is checked against the keep-out rules below.
--   mapgen.tile_function(plan)   ground tile per arena tile (grass variation on "chokes"); create_arena uses it
--   mapgen.build(surface, plan)  lakes, cliffs, forests, ore patches and the ruin, before the CCs are placed
--
-- Layouts (lobby "Map"): "chokes" (default) = terrain + patches + ruin; "open" = the flat Phase 3 arena with the same
-- patches and ruin. The legacy map (waves brain) does not use this module.
--
-- At run time: every DEPLETION_PERIOD the recorded patches are re-counted (alert "patch-depleted" at 0), every
-- REPORT_PERIOD an "ore remaining" log line per force; every CAPTURE_PERIOD the ruin capture step (mapgen.capture_step).
-- API for other modules: mapgen.patches(force?, kind?), mapgen.remaining(surface, patch), mapgen.dump(player?)
-- (also /rts-mapgen), mapgen.alert(force, kind, text, params, position).
--
-- Keep-out rules (the AI planner in scripts/ai/layout.lua plans inside the CC's base ring and never checks tiles):
--   * no terrain within BASE_RING (60) tiles of any CC;
--   * no terrain on or next to an ore patch or the ruin;
--   * no water within reach of a hauler corridor: the straight lines from each CC to its natural patches, to the
--     middle patches and to the ruin (haulers walk straight lines and stop at water 10 tiles wide or more);
--   * cliff walls of different spawns stay WALL_SPACING apart, so walls never close a region.
--
-- Measured on 2.0.77 (headless probe, notes "Terrain and units"): spider units (walker, heavy, raider, artillery) and
-- haulers step over cliff lines, rock rows, forests and water up to 8 tiles wide; walkers and heavies go around water
-- 10-12 wide, everything goes around water 14 or wider; haulers (straight-line autopilot) stop at water 10 or wider.
-- Drones (unit type) go around cliffs and get stuck on rock rows. Walls are therefore cliffs, not rocks.
--
-- Owns storage.mapgen = {
--   surface   arena name the data belongs to; layout, size
--   patches   {{id, kind = "main"|"natural"|"middle", force?, name, center, box = {x0, y0, x1, y1}, total, tiles,
--               remaining, depleted_tick?}}
--   ruin      {position, cc, chests = {LuaEntity}, owner?, capturing?, progress (ticks), label (LuaRenderObject)}
--   counts    terrain feature counts of the current arena (log and notes)
--   next_report  tick of the next "ore remaining" log
-- }
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")

local mapgen = {}

mapgen.LAYOUTS = {"chokes", "open"} -- lobby order
mapgen.DEFAULT_LAYOUT = "chokes"

-- Ore totals per patch (PHASE4 2.4). Main patches: positions from match.ORE_PATCHES (per spawn).
mapgen.MAIN_TOTALS = {["iron-ore"] = 6000, ["copper-ore"] = 4000, stone = 3000, coal = 3000}
-- Natural pair per spawn, NATURAL_A tiles from the CC towards the arena centre: {ore, width, height, total, side}.
-- side = which side of the front line (the solver may mirror both).
mapgen.NATURAL = {
  {"iron-ore", 10, 10, 8000, 1},
  {"copper-ore", 8, 8, 4000, -1},
}
-- Contested middle patches, absolute positions: {ore, x, y, width, height, total}.
mapgen.MIDDLE = {
  {"iron-ore", 0, -24, 14, 14, 12000},
  {"copper-ore", 0, 24, 10, 10, 8000},
  {"coal", 0, 44, 8, 8, 6000},
}

-- Per map size: natural_a = distance of the natural pair from its CC along the front; choke_a = distance of the
-- cliff wall; wall_len = tiles of cliff on each side of the gap (before pruning); lake_r = radius range; forests.
mapgen.GEOMETRY = {
  small = {natural_a = 64, choke_a = 76, wall_len = 20, lake_r = {11, 15}, forests = 6},
  medium = {natural_a = 70, choke_a = 86, wall_len = 28, lake_r = {13, 17}, forests = 8},
  large = {natural_a = 76, choke_a = 96, wall_len = 36, lake_r = {14, 18}, forests = 10},
}
mapgen.BASE_RING = 60        -- no terrain within this many tiles of a CC
mapgen.GAP = 12              -- choke width between the two cliff segments of a spawn (measured between collision boxes)
mapgen.END_TRIM = 3.5        -- a run's end pieces are this much shorter than their two grid cells together (measured)
mapgen.HOSTILE = 45          -- = ai/layout.lua HOSTILE_RADIUS: a patch this close to a spawn belongs to that spawn
mapgen.WALL_SPACING = 12     -- minimum gap between cliff cells of different spawns
mapgen.LAKE_SHAPE = 1.3      -- a lake reaches at most this factor of its radius (blob shape)
mapgen.MAX_LAKES = 3
mapgen.RUIN_POSITION = {x = 0, y = 0}
mapgen.RUIN_STOCK = {{"steel-plate", 200}, {"electronic-circuit", 50}} -- one item per stockpile
mapgen.RUIN_STOCKPILES = {{x = -3.5, y = -1.5}, {x = 3.5, y = 1.5}}
mapgen.CAPTURE_RANGE = 4     -- tiles from a ruin stockpile
mapgen.CAPTURE_TICKS = 600   -- 10 s of uncontested presence
mapgen.CAPTURE_PERIOD = 30
mapgen.DEPLETION_PERIOD = 600  -- depletion check (alerts)
mapgen.REPORT_PERIOD = 3600    -- "ore remaining" log
mapgen.ALERTS_MAX = 100        -- = logistics.MAX_ALERTS
mapgen.TREES = {"tree-01", "tree-02", "tree-03", "tree-04", "tree-05", "tree-06", "tree-07", "tree-08", "tree-09",
                "tree-02-red", "tree-06-brown", "tree-08-brown", "tree-09-brown"}
-- Ground variation on "chokes": value noise thresholds -> tile (first match wins), else BASE_TILE.
mapgen.BASE_TILE = "grass-1"
mapgen.GROUND = {{above = 0.80, tile = "grass-3"}, {above = 0.64, tile = "grass-2"}, {below = 0.16, tile = "grass-4"}}
mapgen.SHORE_TILE = "sand-1"

local UNIT_TYPES = {"spider-unit", "spider-vehicle", "unit"}

--- Module lookup at call time (match requires this module).
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

function mapgen.init()
  storage.mapgen = storage.mapgen or {patches = {}}
end

---------------------------------------------------------------------------
-- Geometry helpers
---------------------------------------------------------------------------
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

-- Tile box {x0, y0, x1, y1} (x1, y1 exclusive) of a w x h patch centred at c, as basetemplate.place_ore lays it.
local function patch_box(c, w, h)
  local x0, y0 = math.floor(c.x - w / 2 + 0.5), math.floor(c.y - h / 2 + 0.5)
  return {x0 = x0, y0 = y0, x1 = x0 + w, y1 = y0 + h}
end

-- Separation of two boxes along the better axis (negative = overlap).
local function box_gap(a, b)
  return math.max(a.x0 - b.x1, b.x0 - a.x1, a.y0 - b.y1, b.y0 - a.y1)
end

local function point_box_dist(p, b)
  local dx = math.max(b.x0 - p.x, 0, p.x - b.x1)
  local dy = math.max(b.y0 - p.y, 0, p.y - b.y1)
  return math.sqrt(dx * dx + dy * dy)
end

local function point_seg_dist(p, a, b)
  local vx, vy = b.x - a.x, b.y - a.y
  local len2 = vx * vx + vy * vy
  local t = len2 > 0 and ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2 or 0
  t = math.max(0, math.min(1, t))
  return dist(p, {x = a.x + vx * t, y = a.y + vy * t})
end

local function inside(b, half, margin)
  return b.x0 >= -half + margin and b.y0 >= -half + margin and b.x1 <= half - margin and b.y1 <= half - margin
end

local function round_pos(p) return {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5)} end

-- (a * b) mod 2^32 for a, b < 2^32, exact in doubles (16-bit halves).
local function mul32(a, b)
  local ah, al = math.floor(a / 65536), a % 65536
  return ((ah * b % 65536) * 65536 + al * b) % 4294967296
end

--- 32-bit integer hash. LuaRandomGenerator ignores the lowest seed bits (measured: seeds n and n + 1 gave the same
--- map), so consecutive match seeds are scrambled first.
function mapgen.mix_seed(x)
  x = math.floor(x) % 4294967296
  x = mul32(bit32.bxor(x, bit32.rshift(x, 16)), 0x7feb352d)
  x = mul32(bit32.bxor(x, bit32.rshift(x, 15)), 0x846ca68b)
  x = bit32.bxor(x, bit32.rshift(x, 16))
  return math.max(1, x)
end

-- Front (towards the arena centre) and side axes of a spawn, as match.front computes them.
local function axes_of(home)
  local len = math.sqrt(home.x * home.x + home.y * home.y)
  if len < 1 then return {x = 1, y = 0}, {x = 0, y = 1} end
  local f = {x = -home.x / len, y = -home.y / len}
  local sx, sy = -f.y, f.x
  if sy < -1e-9 or (math.abs(sy) <= 1e-9 and sx < 0) then sx, sy = -sx, -sy end
  return f, {x = sx, y = sy}
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------
local function ruin_box(p) return {x0 = p.x - 6, y0 = p.y - 4, x1 = p.x + 6, y1 = p.y + 4} end

local function add_patch(P, kind, force, name, center, w, h, total)
  local c = round_pos(center)
  local rec = {kind = kind, force = force, name = name, center = c, w = w, h = h, total = total,
               box = patch_box(c, w, h)}
  rec.id = string.format("%s-%s-%s@%d,%d", kind, force or "all", name, c.x, c.y)
  P.patches[#P.patches + 1] = rec
  return rec
end

-- A new patch box is fine: inside the arena, `gap` tiles from every placed patch and from the ruin.
local function patch_free(P, box, gap)
  if not inside(box, P.half, 4) then return false end
  for _, p in ipairs(P.patches) do
    if box_gap(box, p.box) < gap then return false end
  end
  if P.ruin and box_gap(box, ruin_box(P.ruin)) < 6 then return false end
  return true
end

-- A natural patch box is fine: free of patches and the ruin, 3 tiles from cliff cells, 58-84 tiles from its own CC
-- and out of every other spawn's base ring (so also out of the AI's HOSTILE_RADIUS).
local function natural_ok(P, spec, force, home, c, box)
  if not patch_free(P, box, 4) then return false end
  local d = dist(c, home)
  if d < 58 or d > 84 then return false end
  for other, sp in pairs(spec.spawns) do
    if other ~= force and dist(c, sp) < math.max(mapgen.HOSTILE + 4, mapgen.BASE_RING + 2) then return false end
  end
  for _, w in ipairs(P.wall_cells) do
    if box_gap(box, w.box) < 3 then return false end
  end
  return true
end

-- Natural pair of one spawn: the iron and copper patch side by side across the front line, `a` tiles out along it.
-- Every candidate (a around natural_a, the pair's centre shifted sideways by c, half-spacing h, iron on either side)
-- is scored by how far it strays from (natural_a, 0); the best one that fits wins. On open maps the first candidate
-- (score 0) usually fits; crowded 1v3 small maps push the pair sideways.
local function plan_naturals(P, spec, geo, force)
  local home = spec.spawns[force]
  local f, s = axes_of(home)
  local best, best_score
  for da = -20, 16, 4 do
    local a = geo.natural_a + da
    for c = -48, 48, 4 do
      for _, h in ipairs({13, 9}) do
        for _, sign in ipairs({1, -1}) do
          local score = math.abs(da) + 0.7 * math.abs(c) + (h == 13 and 0 or 2) + (sign == 1 and 0 or 1)
          if not best_score or score < best_score then
            local cands, good = {}, true
            for i, n in ipairs(mapgen.NATURAL) do
              local off = c + n[5] * sign * h
              local ctr = round_pos({x = home.x + f.x * a + s.x * off, y = home.y + f.y * a + s.y * off})
              local box = patch_box(ctr, n[2], n[3])
              if not natural_ok(P, spec, force, home, ctr, box) then good = false break end
              for _, prev in ipairs(cands) do
                if box_gap(box, prev.box) < 4 then good = false end
              end
              if not good then break end
              cands[i] = {c = ctr, box = box}
            end
            if good then best, best_score = cands, score end
          end
        end
      end
    end
  end
  if not best then
    P.skipped[#P.skipped + 1] = "natural pair of " .. force
    return false
  end
  for i, n in ipairs(mapgen.NATURAL) do add_patch(P, "natural", force, n[1], best[i].c, n[2], n[3], n[4]) end
  return true
end

-- Corridors a hauler (straight-line autopilot) may walk: CC -> own naturals, CC -> middle patches, CC -> ruin.
local function plan_corridors(P, spec)
  for _, force in ipairs(spec.forces) do
    local home = spec.spawns[force]
    for _, p in ipairs(P.patches) do
      if p.kind == "middle" or (p.kind == "natural" and p.force == force) then
        P.corridors[#P.corridors + 1] = {a = home, b = p.center, natural = p.kind == "natural"}
      end
    end
    if P.ruin then P.corridors[#P.corridors + 1] = {a = home, b = P.ruin} end
  end
end

-- Cliff cell (4x4 grid cell) box. we = wall runs west-east (cells along x in row j), else north-south.
local function cell_box(we, i, j)
  if we then return {x0 = 4 * i, y0 = 4 * j, x1 = 4 * i + 4, y1 = 4 * j + 4} end
  return {x0 = 4 * j, y0 = 4 * i, x1 = 4 * j + 4, y1 = 4 * i + 4}
end

local function wall_cell_ok(P, spec, force, box)
  if not inside(box, P.half, 4) then return false end
  for _, sp in pairs(spec.spawns) do
    if point_box_dist(sp, box) < mapgen.BASE_RING then return false end
  end
  for _, p in ipairs(P.patches) do
    if box_gap(box, p.box) < 3 then return false end
  end
  if P.ruin and box_gap(box, ruin_box(P.ruin)) < 6 then return false end
  for _, w in ipairs(P.wall_cells) do
    if w.force ~= force and box_gap(box, w.box) < mapgen.WALL_SPACING then return false end
  end
  return true
end

-- Two cliff segments per spawn, roughly perpendicular to its front (straight west-east or north-south runs only: the
-- axis nearer to the perpendicular), leaving a gap of about GAP tiles between their collision boxes, centred on the
-- front line (measured 11.5-12.9; logged as "choke widths"). Cells are added from the gap outwards, one per side per
-- round (fair between spawns), and a side stops at its first cell that breaks a keep-out rule.
local function plan_walls(P, spec, geo)
  local sides = {}
  for _, force in ipairs(spec.forces) do
    local home = spec.spawns[force]
    local f = axes_of(home)
    local p = {x = home.x + f.x * geo.choke_a, y = home.y + f.y * geo.choke_a}
    local we = math.abs(f.y) > math.abs(f.x)
    local along, across = we and p.x or p.y, we and p.y or p.x
    -- the cliff row whose cell centre (4j + 2) is nearest the choke line; on a tie the one on the base side, so
    -- mirrored spawns get mirrored walls
    local jf = (across - 2) / 4
    local j0, j1 = math.floor(jf), math.ceil(jf)
    local d0, d1 = math.abs(4 * j0 + 2 - across), math.abs(4 * j1 + 2 - across)
    local j
    if d0 < d1 - 1e-9 then j = j0 elseif d1 < d0 - 1e-9 then j = j1 else j = ((we and f.y or f.x) > 0) and j0 or j1 end
    -- empty grid cells between the two runs: GAP minus what the end pieces leave open, on the 4-tile grid
    local cell_gap = 4 * math.max(1, math.floor((mapgen.GAP - mapgen.END_TRIM) / 4 + 0.5))
    local gap_lo = 4 * math.floor((along - cell_gap / 2) / 4 + 0.5)
    local left = gap_lo / 4 - 1             -- last cell of the run before the gap
    local right = (gap_lo + cell_gap) / 4   -- first cell of the run after it
    sides[#sides + 1] = {force = force, we = we, j = j, i = left, step = -1, cells = {}, alive = true, gap = p}
    sides[#sides + 1] = {force = force, we = we, j = j, i = right, step = 1, cells = {}, alive = true, gap = p}
    P.gaps[#P.gaps + 1] = {force = force, position = p}
  end
  local rounds = math.floor(geo.wall_len / 4)
  for _ = 1, rounds do
    for _, sd in ipairs(sides) do
      if sd.alive then
        local box = cell_box(sd.we, sd.i, sd.j)
        if wall_cell_ok(P, spec, sd.force, box) then
          sd.cells[#sd.cells + 1] = sd.i
          P.wall_cells[#P.wall_cells + 1] = {force = sd.force, box = box}
          sd.i = sd.i + sd.step
        else
          sd.alive = false
        end
      end
    end
  end
  -- Fairness: every side is cut to the shortest side's length, so every spawn gets the same choke. If any side has
  -- room for fewer than 2 cells (crowded maps: 1v3 small), there are no walls at all.
  local n = rounds
  for _, sd in ipairs(sides) do n = math.min(n, #sd.cells) end
  P.wall_cells = {}
  if n < 2 then
    P.skipped[#P.skipped + 1] = string.format("cliff walls (a side has room for %d cell%s)", n, n == 1 and "" or "s")
    return
  end
  for _, sd in ipairs(sides) do
    local cells = {}
    for k = 1, n do cells[k] = sd.cells[k] end -- the cells nearest the gap
    table.sort(cells)
    P.walls[#P.walls + 1] = {force = sd.force, we = sd.we, j = sd.j, cells = cells}
    for _, i in ipairs(cells) do
      P.wall_cells[#P.wall_cells + 1] = {force = sd.force, box = cell_box(sd.we, i, sd.j)}
    end
  end
end

local function lake_ok(P, spec, c, r)
  local R = r * mapgen.LAKE_SHAPE
  local lim = P.half - R - 8
  if math.abs(c.x) > lim or math.abs(c.y) > lim then return false end
  for _, sp in pairs(spec.spawns) do
    if dist(c, sp) < mapgen.BASE_RING + R + 2 then return false end
  end
  for _, p in ipairs(P.patches) do
    if point_box_dist(c, p.box) < R + 6 then return false end
  end
  if P.ruin and dist(c, P.ruin) < R + 12 then return false end
  for _, w in ipairs(P.wall_cells) do
    if point_box_dist(c, w.box) < R + 4 then return false end
  end
  for _, g in ipairs(P.gaps) do
    if dist(c, g.position) < R + 10 then return false end
  end
  for _, k in ipairs(P.corridors) do
    -- natural corridors also carry the AI's expansion belt (its router may stray ~14 tiles from the line)
    if point_seg_dist(c, k.a, k.b) < R + (k.natural and 16 or 6) then return false end
  end
  for _, l in ipairs(P.lakes) do
    if dist(c, l) < R + l.r * mapgen.LAKE_SHAPE + 14 then return false end
  end
  return true
end

-- Lakes between angularly neighbouring spawns (widest gaps first), then beside those midpoints, at several
-- distances from the centre and shrinking radii, until MAX_LAKES fit.
local function plan_lakes(P, spec, geo, rng)
  local angs = {}
  for _, force in ipairs(spec.forces) do
    local s = spec.spawns[force]
    angs[#angs + 1] = math.atan2(s.y, s.x)
  end
  table.sort(angs)
  local mids = {}
  for i = 1, #angs do
    local a1, a2 = angs[i], angs[i % #angs + 1]
    if i == #angs then a2 = a2 + 2 * math.pi end
    mids[#mids + 1] = {a = (a1 + a2) / 2, span = a2 - a1}
  end
  table.sort(mids, function(x, y)
    if math.abs(x.span - y.span) > 1e-6 then return x.span > y.span end
    return x.a < y.a
  end)
  local cands = {}
  for _, m in ipairs(mids) do cands[#cands + 1] = m.a end
  -- With two spawns the map is mirror-symmetric: lakes stay on the mirror axis (the midpoints), so neither side gets
  -- a lake on its flank. With more spawns, angles beside the midpoints are tried too.
  for _, k in ipairs(#angs > 2 and {0.15, 0.3, 0.45} or {}) do
    for _, m in ipairs(mids) do
      cands[#cands + 1] = m.a + k * m.span
      cands[#cands + 1] = m.a - k * m.span
    end
  end
  local D = {0.62, 0.78, 0.48, 0.92, 0.36, 1.05}
  local R = spec.radius
  for _, a in ipairs(cands) do
    if #P.lakes >= mapgen.MAX_LAKES then break end
    local r0 = geo.lake_r[1] + rng() * (geo.lake_r[2] - geo.lake_r[1])
    local placed = false
    for _, r in ipairs({r0, r0 - 2, r0 - 4}) do
      if r >= 10 and not placed then
        for _, df in ipairs(D) do
          local c = round_pos({x = math.cos(a) * df * R, y = math.sin(a) * df * R})
          if lake_ok(P, spec, c, r) then
            P.lakes[#P.lakes + 1] = {x = c.x, y = c.y, r = r, phase = {rng() * 6.283, rng() * 6.283, rng() * 6.283}}
            placed = true
            break
          end
        end
      end
    end
  end
end

local function forest_ok(P, spec, c, r)
  if math.abs(c.x) > P.half - r - 4 or math.abs(c.y) > P.half - r - 4 then return false end
  for _, sp in pairs(spec.spawns) do
    if dist(c, sp) < mapgen.BASE_RING + r then return false end
  end
  for _, p in ipairs(P.patches) do
    if point_box_dist(c, p.box) < r + 3 then return false end
  end
  if P.ruin and dist(c, P.ruin) < r + 10 then return false end
  for _, l in ipairs(P.lakes) do
    if dist(c, l) < r + l.r * mapgen.LAKE_SHAPE + 3 then return false end
  end
  for _, w in ipairs(P.wall_cells) do
    if point_box_dist(c, w.box) < r + 3 then return false end
  end
  for _, g in ipairs(P.gaps) do
    if dist(c, g.position) < r + 10 then return false end
  end
  for _, o in ipairs(P.forests) do
    if dist(c, o) < r + o.r + 8 then return false end
  end
  return true
end

local function plan_forests(P, spec, geo, rng)
  local tries = 0
  while #P.forests < geo.forests and tries < 800 do
    tries = tries + 1
    local r = 6 + rng() * 5
    local c = {x = math.floor((rng() * 2 - 1) * (P.half - 8) + 0.5), y = math.floor((rng() * 2 - 1) * (P.half - 8) + 0.5)}
    if forest_ok(P, spec, c, r) then
      P.forests[#P.forests + 1] = {x = c.x, y = c.y, r = r, seed = rng(1, 2147483647)}
    end
  end
  P.forest_tries = tries
end

--- Plan a map. spec = {size, layout, half, radius, seed, forces (rts-player first), spawns = {[force] = pos},
--- main = {{force, name, center, w, h}}, middle_iron_ore = name? (stand-in for the middle iron)}. Pure: no surface.
function mapgen.plan(spec)
  local geo = mapgen.GEOMETRY[spec.size] or mapgen.GEOMETRY.small
  local rng = game.create_random_generator(mapgen.mix_seed(spec.seed))
  local P = {layout = spec.layout, size = spec.size, half = spec.half, seed = spec.seed, patches = {}, lakes = {},
             walls = {}, wall_cells = {}, gaps = {}, forests = {}, corridors = {}, skipped = {},
             ruin = {x = mapgen.RUIN_POSITION.x, y = mapgen.RUIN_POSITION.y}}
  for _, p in ipairs(spec.main) do
    add_patch(P, "main", p.force, p.name, p.center, p.w, p.h, mapgen.MAIN_TOTALS[p.name] or 3000)
  end
  for _, mp in ipairs(mapgen.MIDDLE) do
    local name = (mp[1] == "iron-ore" and spec.middle_iron_ore) or mp[1]
    local c = {x = mp[2], y = mp[3]}
    if patch_free(P, patch_box(c, mp[4], mp[5]), 4) then
      add_patch(P, "middle", nil, name, c, mp[4], mp[5], mp[6])
    else
      P.skipped[#P.skipped + 1] = "middle " .. name
    end
  end
  -- Walls before the naturals: the natural solver steps around them; lakes and forests come last.
  if spec.layout == "chokes" then plan_walls(P, spec, geo) end
  for _, force in ipairs(spec.forces) do plan_naturals(P, spec, geo, force) end
  plan_corridors(P, spec)
  if spec.layout == "chokes" then
    plan_lakes(P, spec, geo, rng)
    plan_forests(P, spec, geo, rng)
    P.ground_seed = rng(1, 2147483647)
  end
  return P
end

---------------------------------------------------------------------------
-- Ground tiles
---------------------------------------------------------------------------
local function tile_ok(name)
  return name and prototypes.tile[name] ~= nil
end

--- A function (x, y) -> tile name for the arena ground, or nil for plain BASE_TILE (open layout). Value noise on
--- two grids (32 and 11 tiles), smoothstep-interpolated, values from a seeded generator.
function mapgen.tile_function(P)
  if not (P and P.layout == "chokes") then return nil end
  local rng = game.create_random_generator(P.ground_seed or 1)
  local function grid(step)
    local n = math.ceil(2 * P.half / step) + 2
    local g = {}
    for i = 0, n do
      g[i] = {}
      for j = 0, n do g[i][j] = rng() end
    end
    return {g = g, step = step, n = n}
  end
  local g1, g2 = grid(32), grid(11)
  local rules = {}
  for _, rule in ipairs(mapgen.GROUND) do
    if tile_ok(rule.tile) then rules[#rules + 1] = rule end
  end
  local base, half, nrules = mapgen.BASE_TILE, P.half, #rules
  local function smooth(t) return t * t * (3 - 2 * t) end
  -- create_arena walks x in the outer loop: the column part (grid rows and x weight) is cached per x
  local lx, a0, a1, ta, b0, b1, tb
  return function(x, y)
    if x ~= lx then
      lx = x
      local fa, fb = (x + half) / g1.step, (x + half) / g2.step
      local ia, ib = math.floor(fa), math.floor(fb)
      a0, a1, ta = g1.g[ia], g1.g[ia + 1], smooth(fa - ia)
      b0, b1, tb = g2.g[ib], g2.g[ib + 1], smooth(fb - ib)
    end
    local fa, fb = (y + half) / g1.step, (y + half) / g2.step
    local ja, jb = math.floor(fa), math.floor(fb)
    local ua, ub = smooth(fa - ja), smooth(fb - jb)
    local p = a0[ja] + (a1[ja] - a0[ja]) * ta
    local q = a0[ja + 1] + (a1[ja + 1] - a0[ja + 1]) * ta
    local r = b0[jb] + (b1[jb] - b0[jb]) * tb
    local t = b0[jb + 1] + (b1[jb + 1] - b0[jb + 1]) * tb
    local v = 0.65 * (p + (q - p) * ua) + 0.35 * (r + (t - r) * ub)
    for i = 1, nrules do
      local rule = rules[i]
      if (rule.above and v > rule.above) or (rule.below and v < rule.below) then return rule.tile end
    end
    return base
  end
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------
-- Lake radius at angle t (blob: three harmonics, at most LAKE_SHAPE times r).
local function lake_radius(l, t)
  local ph = l.phase
  return l.r * (1 + 0.14 * math.sin(2 * t + ph[1]) + 0.09 * math.sin(3 * t + ph[2]) + 0.05 * math.sin(5 * t + ph[3]))
end

local function build_lakes(surface, P)
  local tiles, water = {}, 0
  local shore = tile_ok(mapgen.SHORE_TILE) and mapgen.SHORE_TILE or nil
  for _, l in ipairs(P.lakes) do
    local R = math.ceil(l.r * mapgen.LAKE_SHAPE) + 3
    for x = l.x - R, l.x + R do
      for y = l.y - R, l.y + R do
        local px, py = x + 0.5 - l.x, y + 0.5 - l.y
        local d = math.sqrt(px * px + py * py)
        local rr = lake_radius(l, math.atan2(py, px))
        local name
        if d <= rr * 0.55 then
          name = "deepwater"
        elseif d <= rr then
          name = "water"
        elseif shore and d <= rr + 2 then
          name = shore
        end
        if name then
          tiles[#tiles + 1] = {name = name, position = {x, y}}
          if name ~= shore then water = water + 1 end
        end
      end
    end
  end
  if #tiles > 0 then surface.set_tiles(tiles, true, true, true, false) end
  return water
end

local CLIFF_RUN = {
  [true] = {first = "none-to-east", mid = "west-to-east", last = "west-to-none"},
  [false] = {first = "none-to-south", mid = "north-to-south", last = "north-to-none"},
}

local function build_walls(surface, P)
  local made, failed = 0, 0
  for _, w in ipairs(P.walls) do
    local names = CLIFF_RUN[w.we]
    w.made = 0
    w.lo, w.hi = nil, nil -- extent of the built cliffs' collision boxes along the run
    for k, i in ipairs(w.cells) do
      local orientation = (k == 1 and names.first) or (k == #w.cells and names.last) or names.mid
      local x, y
      if w.we then x, y = 4 * i + 2, 4 * w.j + 2.5 else x, y = 4 * w.j + 2, 4 * i + 2.5 end
      local e = surface.create_entity({name = "cliff", position = {x, y}, cliff_orientation = orientation})
      if e then
        made = made + 1
        w.made = w.made + 1
        local bb = e.bounding_box
        local lo = w.we and bb.left_top.x or bb.left_top.y
        local hi = w.we and bb.right_bottom.x or bb.right_bottom.y
        w.lo = math.min(w.lo or lo, lo)
        w.hi = math.max(w.hi or hi, hi)
      else
        failed = failed + 1
      end
    end
  end
  return made, failed
end

-- Measured choke width per spawn: the distance between the collision boxes of its two walls along the run.
local function measure_gaps(P)
  local by_force, out = {}, {}
  for _, w in ipairs(P.walls) do
    if w.lo then
      by_force[w.force] = by_force[w.force] or {}
      table.insert(by_force[w.force], w)
    end
  end
  for _, g in ipairs(P.gaps) do
    local ws = by_force[g.force]
    if ws and #ws == 2 then
      local a, b = ws[1], ws[2]
      if a.lo > b.lo then a, b = b, a end
      g.width = b.lo - a.hi
      out[#out + 1] = string.format("%s %.1f", g.force, g.width)
    end
  end
  return table.concat(out, ", ")
end

local function tree_names()
  local out = {}
  for _, name in ipairs(mapgen.TREES) do
    if prototypes.entity[name] then out[#out + 1] = name end
  end
  return out
end

local function build_forests(surface, P)
  local names = tree_names()
  if #names == 0 then return 0 end
  local total = 0
  for _, f in ipairs(P.forests) do
    local rng = game.create_random_generator(f.seed)
    local species = {names[rng(1, #names)], names[rng(1, #names)]}
    local n = 0
    local R = math.ceil(f.r)
    for x = f.x - R, f.x + R do
      for y = f.y - R, f.y + R do
        local d = math.sqrt((x - f.x) ^ 2 + (y - f.y) ^ 2) / f.r
        if d <= 1 and rng() < 0.34 - 0.22 * d then
          local name = species[rng(1, 2)]
          local pos = {x + rng() * 0.8 + 0.1, y + rng() * 0.8 + 0.1}
          if surface.can_place_entity({name = name, position = pos}) and surface.create_entity({name = name, position = pos}) then
            n = n + 1
          end
        end
      end
    end
    f.trees = n
    total = total + n
  end
  return total
end

--- Place a patch with a fixed total: the tiles of basetemplate.place_ore's round shape, richer in the middle.
--- Returns the number of resource tiles and the amount placed.
function mapgen.place_patch(surface, name, center, w, h, total)
  local cx, cy = center.x, center.y
  local x0, y0 = math.floor(cx - w / 2 + 0.5), math.floor(cy - h / 2 + 0.5)
  local cells, weight = {}, 0
  for tx = x0, x0 + w - 1 do
    for ty = y0, y0 + h - 1 do
      local px, py = tx + 0.5, ty + 0.5
      local nx, ny = (px - cx) / (w / 2), (py - cy) / (h / 2)
      local d2 = nx * nx + ny * ny
      if d2 <= 1.15 and surface.count_entities_filtered({position = {px, py}, type = "resource"}) == 0 then
        local wt = math.max(0.35, 1.5 - d2)
        cells[#cells + 1] = {px, py, wt}
        weight = weight + wt
      end
    end
  end
  local placed, sum = 0, 0
  for i, c in ipairs(cells) do
    local amount = math.max(1, math.floor(total * c[3] / weight))
    if i == #cells then amount = math.max(1, total - sum) end
    if surface.create_entity({name = name, position = {c[1], c[2]}, amount = amount}) then
      placed = placed + 1
      sum = sum + amount
    end
  end
  return placed, sum
end

-- The neutral ruin: a dead Command Center and two stockpiles with the loot, all of the neutral force and
-- indestructible until captured.
local function build_ruin(surface, P)
  local pos = P.ruin
  local cc = surface.create_entity({name = "rts-command-center", position = {pos.x, pos.y}, force = "neutral",
                                    create_build_effect_smoke = false})
  if cc then
    cc.destructible = false
    cc.minable = false
    cc.operable = false
    cc.health = cc.max_health * 0.3
    cc.energy = cc.electric_buffer_size or 0 -- no "no power" icon; it has no robots and no core, so it does nothing
  end
  local chests = {}
  for i, off in ipairs(mapgen.RUIN_STOCKPILES) do
    local s = surface.create_entity({name = "rts-stockpile", position = {pos.x + off.x, pos.y + off.y},
                                     force = "neutral", create_build_effect_smoke = false})
    if s then
      s.destructible = false
      s.minable = false
      local item = mapgen.RUIN_STOCK[i]
      if item then s.insert({name = item[1], count = item[2]}) end
      chests[#chests + 1] = s
    end
  end
  local label = rendering.draw_text({text = {"rts.ruin-label"}, surface = surface, target = {pos.x, pos.y - 3.2},
                                     color = {0.85, 0.8, 0.6}, scale = 1.6, alignment = "center",
                                     vertical_alignment = "middle"})
  return {position = {x = pos.x, y = pos.y}, cc = cc, chests = chests, progress = 0, label = label}
end

--- Build the planned map on the arena (before the CCs are placed). Records patches and the ruin in storage.mapgen.
function mapgen.build(surface, P)
  local prof = helpers.create_profiler()
  local s = {surface = surface.name, layout = P.layout, size = P.size, patches = {}, counts = {}}
  local water = build_lakes(surface, P)
  local cliffs, cliff_failed = build_walls(surface, P)
  local gaps = measure_gaps(P)
  local trees = build_forests(surface, P)
  local parts = {}
  for _, p in ipairs(P.patches) do
    local n, amount = mapgen.place_patch(surface, p.name, p.center, p.w, p.h, p.total)
    s.patches[#s.patches + 1] = {id = p.id, kind = p.kind, force = p.force, name = p.name, center = p.center,
                                 box = p.box, total = amount, tiles = n, remaining = amount}
    if p.kind ~= "main" then
      parts[#parts + 1] = string.format("%s %s %s %dx%d at %s: %d tiles, %d ore", p.kind, p.force or "", p.name, p.w,
        p.h, util.pos_str(p.center), n, amount)
    end
  end
  s.ruin = build_ruin(surface, P)
  prof.stop()
  s.counts = {lakes = #P.lakes, water_tiles = water, walls = #P.walls, cliffs = cliffs, cliff_failed = cliff_failed,
              forests = #P.forests, trees = trees, patches = #P.patches, skipped = #P.skipped, chokes = gaps}
  s.next_report = game.tick + mapgen.REPORT_PERIOD
  storage.mapgen = s
  local lakes, walls = {}, {}
  for _, l in ipairs(P.lakes) do lakes[#lakes + 1] = string.format("(%d, %d) r%.0f", l.x, l.y, l.r) end
  for _, w in ipairs(P.walls) do
    walls[#walls + 1] = string.format("%s %s %d/%d", w.force, w.we and "W-E" or "N-S", w.made or 0, #w.cells)
  end
  log({"", string.format("[rts] mapgen: %s %s on %s: lakes %d (%d water tiles) [%s]; cliff walls %d, cliffs %d "
    .. "(failed %d) [%s]; forests %d with %d trees; patches %d; ruin at %s with %d stockpiles; skipped [%s]; built in ",
    P.layout, P.size, surface.name, #P.lakes, water, table.concat(lakes, ", "), #P.walls, cliffs, cliff_failed,
    table.concat(walls, ", "), #P.forests, trees, #P.patches, util.pos_str(P.ruin), #s.ruin.chests,
    table.concat(P.skipped, ", ")), prof})
  util.log("mapgen: choke widths (between the cliff collision boxes): %s", gaps ~= "" and gaps or "none")
  util.log("mapgen: natural and middle patches: %s", table.concat(parts, "; "))
  return s
end

--- Forget the data of a torn-down match (match.teardown).
function mapgen.reset()
  storage.mapgen = {patches = {}}
end

---------------------------------------------------------------------------
-- Alerts: the shared writer supply.alert (storage.alerts {tick, force, kind, text, params, position}; the HUD shows
-- {text, params...} and picks an icon per kind), looked up at call time so this module does not change the load
-- order. Also printed to the force.
---------------------------------------------------------------------------
function mapgen.alert(force_name, kind, text, params, position)
  local supply = loaded("scripts.supply")
  if supply and supply.alert then
    supply.alert(force_name, kind, text, params, position)
  else -- same format, for a tree without supply.lua
    local list = storage.alerts
    if not list then
      list = {}
      storage.alerts = list
    end
    list[#list + 1] = {tick = game.tick, force = force_name, kind = kind, text = text, params = params,
                       position = position and {x = position.x, y = position.y} or nil}
    while #list > mapgen.ALERTS_MAX do table.remove(list, 1) end
  end
  local force = game.forces[force_name]
  local msg = {text}
  for _, p in ipairs(params or {}) do msg[#msg + 1] = p end
  if force then force.print({"", "[RTS] ", msg}) end
  util.log("mapgen: alert %s for %s at %s", kind, force_name, position and util.pos_str(position) or "-")
end

---------------------------------------------------------------------------
-- Depletion
---------------------------------------------------------------------------
local function live_surface()
  local s = storage.mapgen
  local m = storage.match
  if not (s and s.surface and m and m.surface == s.surface and (m.phase == "running" or m.phase == "ended")) then
    return nil
  end
  return game.surfaces[s.surface]
end

--- Ore left in a recorded patch now (sum of its resource entities).
function mapgen.remaining(surface, p)
  local n = 0
  for _, e in pairs(surface.find_entities_filtered({area = {{p.box.x0, p.box.y0}, {p.box.x1, p.box.y1}},
                                                   name = p.name})) do
    n = n + e.amount
  end
  return n
end

--- Recorded patches, optionally only those of one force / one kind.
function mapgen.patches(force_name, kind)
  local out = {}
  for _, p in ipairs((storage.mapgen and storage.mapgen.patches) or {}) do
    if (not force_name or p.force == force_name) and (not kind or p.kind == kind) then out[#out + 1] = p end
  end
  return out
end

local function participants()
  local m = storage.match
  return (m and m.forces) or {}
end

local function check_depletion(surface)
  for _, p in ipairs(storage.mapgen.patches) do
    if not p.depleted_tick then
      p.remaining = mapgen.remaining(surface, p)
      if p.remaining <= 0 then
        p.depleted_tick = game.tick
        local item = {"item-name." .. p.name}
        util.log("mapgen: patch %s depleted at %.0fs", p.id, (game.tick - (storage.match.tick_started or 0)) / 60)
        local to = p.force and {p.force} or participants()
        for _, f in ipairs(to) do
          mapgen.alert(f, "patch-depleted", "rts.alert-patch-depleted", {item, {"rts.patch-kind-" .. p.kind}},
            p.center)
        end
      end
    end
  end
end

local function report()
  local per = {}
  for _, p in ipairs(storage.mapgen.patches) do
    local key = p.force or "middle"
    per[key] = per[key] or {}
    local list = per[key]
    list[#list + 1] = string.format("%s %s %d/%d", p.kind, p.name, p.remaining or 0, p.total)
  end
  for _, f in ipairs(participants()) do
    if per[f] then util.log("ore remaining %s: %s", f, table.concat(per[f], ", ")) end
  end
  if per.middle then util.log("ore remaining middle: %s", table.concat(per.middle, ", ")) end
end

events.on_nth_tick(mapgen.DEPLETION_PERIOD, function(e)
  local surface = live_surface()
  if not surface or storage.match.phase ~= "running" then return end
  check_depletion(surface)
  local s = storage.mapgen
  if s.next_report and e.tick >= s.next_report then
    s.next_report = e.tick + mapgen.REPORT_PERIOD
    report()
  end
end)

---------------------------------------------------------------------------
-- Ruin capture
---------------------------------------------------------------------------
local function label_of(force_name)
  local match = loaded("scripts.match")
  return match and match.label(force_name) or force_name
end

local function set_label(ruin, text)
  if ruin.label and ruin.label.valid then ruin.label.text = text end
end

-- Forces with a registered unit within CAPTURE_RANGE of a live ruin stockpile.
local function present_forces(surface, ruin)
  local present, any = {}, false
  local is_participant = {}
  for _, f in ipairs(participants()) do is_participant[f] = true end
  for _, chest in ipairs(ruin.chests) do
    if chest.valid then
      for _, e in pairs(surface.find_entities_filtered({position = chest.position, radius = mapgen.CAPTURE_RANGE,
                                                       type = UNIT_TYPES})) do
        local f = e.force.name
        if is_participant[f] and e.unit_number and units.get(e.unit_number) then
          present[f] = true
          any = true
        end
      end
    end
  end
  return present, any
end

local function capture(ruin, force_name)
  local previous = ruin.owner
  ruin.owner = force_name
  ruin.capturing, ruin.progress = nil, 0
  local counts = {}
  for _, chest in ipairs(ruin.chests) do
    if chest.valid then
      chest.force = force_name
      chest.destructible = true
      local inv = chest.get_inventory(defines.inventory.chest)
      for _, item in ipairs(mapgen.RUIN_STOCK) do counts[item[1]] = (counts[item[1]] or 0) + inv.get_item_count(item[1]) end
    end
  end
  set_label(ruin, {"rts.ruin-owned", label_of(force_name)})
  util.log("mapgen: ruin at %s captured by %s (from %s): steel %d, circuits %d", util.pos_str(ruin.position),
    force_name, previous or "neutral", counts["steel-plate"] or 0, counts["electronic-circuit"] or 0)
  mapgen.alert(force_name, "ruin-captured", "rts.alert-ruin-captured",
    {counts["steel-plate"] or 0, counts["electronic-circuit"] or 0}, ruin.position)
  if previous then
    mapgen.alert(previous, "ruin-captured", "rts.alert-ruin-lost", {label_of(force_name)}, ruin.position)
  end
end

--- One capture step (every CAPTURE_PERIOD ticks): a single force (not the owner) with units within CAPTURE_RANGE
--- of a ruin stockpile, while no unit of the owner is there, gains progress; CAPTURE_TICKS of it captures the
--- stockpiles. Nobody there resets the progress; several forces there hold it.
function mapgen.capture_step(dt)
  local surface = live_surface()
  local s = storage.mapgen
  local ruin = s and s.ruin
  if not (surface and ruin and storage.match.phase == "running") then return end
  local alive = false
  for _, chest in ipairs(ruin.chests or {}) do
    if chest.valid then alive = true end
  end
  if not alive then return end
  local present, any = present_forces(surface, ruin)
  if not any then
    if ruin.capturing then
      ruin.capturing, ruin.progress = nil, 0
      set_label(ruin, ruin.owner and {"rts.ruin-owned", label_of(ruin.owner)} or {"rts.ruin-label"})
    end
    return
  end
  local challengers = {}
  for f in pairs(present) do
    if f ~= ruin.owner then challengers[#challengers + 1] = f end
  end
  if #challengers ~= 1 or (ruin.owner and present[ruin.owner]) then return end -- contested or defended: hold
  local f = challengers[1]
  if ruin.capturing ~= f then ruin.capturing, ruin.progress = f, 0 end
  ruin.progress = ruin.progress + (dt or mapgen.CAPTURE_PERIOD)
  if ruin.progress >= mapgen.CAPTURE_TICKS then
    capture(ruin, f)
  else
    set_label(ruin, {"rts.ruin-capturing", label_of(f), math.floor(100 * ruin.progress / mapgen.CAPTURE_TICKS)})
  end
end

events.on_nth_tick(mapgen.CAPTURE_PERIOD, function() mapgen.capture_step(mapgen.CAPTURE_PERIOD) end)

---------------------------------------------------------------------------
-- Console: /rts-mapgen (QA): terrain counts, ore left per patch, the ruin's owner
---------------------------------------------------------------------------
--- Write the map generation state to the log (and to `player`, when given). Returns the lines.
function mapgen.dump(player)
  local s = storage.mapgen
  local lines = {}
  if not (s and s.surface) then
    lines[1] = "[rts] mapgen: no generated map (lobby, or the legacy map)"
  else
    local surface = game.surfaces[s.surface]
    lines[#lines + 1] = string.format("[rts] mapgen: %s %s on %s: %s", tostring(s.layout), tostring(s.size), s.surface,
      serpent.line(s.counts))
    for _, p in ipairs(s.patches) do
      local left = surface and mapgen.remaining(surface, p) or 0
      lines[#lines + 1] = string.format("[rts] mapgen: %s %s %s at %s: %d/%d%s", p.kind, p.force or "middle", p.name,
        util.pos_str(p.center), left, p.total, p.depleted_tick and " (depleted)" or "")
    end
    local r = s.ruin
    if r then
      lines[#lines + 1] = string.format("[rts] mapgen: ruin at %s: owner %s, capturing %s (%d ticks)",
        util.pos_str(r.position), tostring(r.owner or "neutral"), tostring(r.capturing or "-"), r.progress or 0)
    end
  end
  for _, line in ipairs(lines) do
    log(line)
    if player then player.print(line) end
  end
  return lines
end

commands.add_command("rts-mapgen", "- map generation state: terrain counts, ore left per patch, the ruin", function(cmd)
  mapgen.dump(cmd.player_index and game.get_player(cmd.player_index))
end)

---------------------------------------------------------------------------
-- Dev: whole-arena screenshot (GUI self-test)
---------------------------------------------------------------------------
--- Two screenshots without GUI: the whole arena (script-output/rts-mapgen-<tick>.png) and the middle at zoom 0.35
--- (rts-mapgen-<tick>-middle.png: ruin, middle patches, the nearest cliff walls).
function mapgen.overview_screenshot(player, resolution)
  local s = storage.mapgen
  local m = storage.match
  local surface = m and m.surface and game.surfaces[m.surface]
  if not surface then return nil end
  local half = m.arena_half or 128
  local res = resolution or 1600
  local path = string.format("rts-mapgen-%d.png", game.tick)
  game.take_screenshot({player = player, surface = surface, position = {0, 0}, resolution = {res, res},
                        zoom = res / (2 * half * 32), path = path, show_gui = false, show_entity_info = false,
                        force_render = true, daytime = 0})
  local middle = string.format("rts-mapgen-%d-middle.png", game.tick)
  game.take_screenshot({player = player, surface = surface, position = {0, 0}, resolution = {1600, 1000},
                        zoom = 0.35, path = middle, show_gui = false, show_entity_info = true, force_render = true,
                        daytime = 0})
  util.log("mapgen: overview screenshots %s and %s of %s (%s %s), counts %s", path, middle, surface.name,
    tostring(s and s.layout), tostring(s and s.size), s and s.counts and serpent.line(s.counts) or "-")
  return path
end

return mapgen
