-- Map generation (docs/PHASE4.md 2.4 and 5): terrain, ore patches with finite totals, the neutral ruin, depletion
-- telemetry and the ruin capture.
--
-- match.start calls, in this order (docs/qa/phase4-mapgen-notes.md):
--   mapgen.plan(spec)            pure planning, no surface: every patch (main, natural, middle), water moats, lakes,
--                                forests and the ruin. Every feature is checked against the keep-out rules below.
--   mapgen.tile_function(plan)   ground tile per arena tile (grass variation on "chokes"); create_arena uses it
--   mapgen.build(surface, plan)  moats, lakes, forests, ore patches and the ruin, before the CCs are placed; then a
--                                land connectivity check (every CC, patch, gap and the ruin reachable on land)
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
--   * moats of different spawns stay MOAT_SPACING apart, and every moat keeps its land gap, so no region is closed.
--
-- Measured on 2.0.77 (headless probe, notes "Terrain and units"): spider units (walker, heavy, raider, artillery) and
-- haulers step over cliff lines, rock rows, forests and water up to 8 tiles wide; walkers and heavies go around water
-- 10-12 wide, everything goes around water 14 or wider; haulers (straight-line autopilot) stop at water 10 or wider.
-- Drones (unit type) go around cliffs and get stuck on rock rows. Chokes are therefore water moats (16 tiles across,
-- more than the 14 that stops every unit) with one land gap each; there are no cliffs.
--
-- Owns storage.mapgen = {
--   surface   arena name the data belongs to; layout, size
--   patches   {{id, kind = "main"|"natural"|"middle", force?, name, center, box = {x0, y0, x1, y1}, total, tiles,
--               remaining, depleted_tick?}}
--   ruin      {position, cc, chests = {LuaEntity}, owner?, capturing?, progress (ticks), label (LuaRenderObject)}
--   counts    terrain feature counts of the current arena (log and notes)
--   moats     {{force, home, front, side, sign, a, len}}: water |a' - a| <= MOAT_WIDTH / 2 and
--             MOAT_GAP / 2 <= b' * sign <= MOAT_GAP / 2 + len, a' / b' = position along front / side from home
--   gaps      {{force, position (centre of the land gap), width (measured)}}
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
-- moat's centre line; moat_len = water on each side of the gap (before pruning); lake_r = radius range; forests.
-- The natural pair sits between the base ring and the moat, so on the small map (spawn circle 88) it is only 50 out.
mapgen.GEOMETRY = {
  small = {natural_a = 50, choke_a = 70, moat_len = 24, lake_r = {11, 15}, forests = 6},
  medium = {natural_a = 70, choke_a = 88, moat_len = 36, lake_r = {13, 17}, forests = 8},
  large = {natural_a = 76, choke_a = 96, moat_len = 48, lake_r = {14, 18}, forests = 10},
}
mapgen.NATURAL_DIST = {48, 84} -- a natural patch centre this far from its own CC
mapgen.BASE_RING = 60        -- no terrain within this many tiles of a CC
mapgen.MOAT_WIDTH = 16       -- water across the front line (14 or more stops every unit, measured)
mapgen.MOAT_GAP = 14         -- the land gap (the choke) on the front line
mapgen.MOAT_MIN = 8          -- a moat side shorter than this (on any spawn) means no moats at all (fairness)
mapgen.HOSTILE = 45          -- = ai/layout.lua HOSTILE_RADIUS: a patch this close to a spawn belongs to that spawn
mapgen.MOAT_SPACING = 12     -- minimum land between moats of different spawns
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

-- Distance from a point to a moat side (exact: the side is a rectangle in its spawn's front/side axes).
local function moat_side_dist(p, m)
  local dx, dy = p.x - m.home.x, p.y - m.home.y
  local a = dx * m.f.x + dy * m.f.y
  local b = (dx * m.s.x + dy * m.s.y) * m.sign
  local half = mapgen.MOAT_WIDTH / 2
  local da = math.max(m.a - half - a, 0, a - (m.a + half))
  local lo = mapgen.MOAT_GAP / 2
  local db = math.max(lo - b, 0, b - (lo + m.len))
  return math.sqrt(da * da + db * db)
end

--- Distance from a point to the nearest planned moat (math.huge without moats).
local function moat_dist(P, p)
  local best = math.huge
  for _, m in ipairs(P.moats) do
    if m.len > 0 then best = math.min(best, moat_side_dist(p, m)) end
  end
  return best
end

-- Distance from a tile box to the nearest moat, from points every tile along the box outline.
local function box_moat_dist(P, box)
  if #P.moats == 0 then return math.huge end
  local best = math.huge
  local function try(x, y) best = math.min(best, moat_dist(P, {x = x, y = y})) end
  for x = box.x0, box.x1 do
    try(x, box.y0)
    try(x, box.y1)
  end
  for y = box.y0 + 1, box.y1 - 1 do
    try(box.x0, y)
    try(box.x1, y)
  end
  return best
end

-- A natural patch box is fine: free of patches and the ruin, 3 tiles from the moats, NATURAL_DIST from its own CC
-- and out of every other spawn's base ring (so also out of the AI's HOSTILE_RADIUS).
local function natural_ok(P, spec, force, home, c, box)
  if not patch_free(P, box, 4) then return false end
  local d = dist(c, home)
  if d < mapgen.NATURAL_DIST[1] or d > mapgen.NATURAL_DIST[2] then return false end
  for other, sp in pairs(spec.spawns) do
    if other ~= force and dist(c, sp) < math.max(mapgen.HOSTILE + 4, mapgen.BASE_RING + 2) then return false end
  end
  if box_moat_dist(P, box) < 3 then return false end
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

-- A moat point is fine: inside the arena, out of every base ring, 3 tiles from patches, 4 from the ruin and
-- MOAT_SPACING from other spawns' moats.
local function moat_point_ok(P, spec, force, p)
  local lim = P.half - 4
  if math.abs(p.x) > lim or math.abs(p.y) > lim then return false end
  for _, sp in pairs(spec.spawns) do
    if dist(p, sp) < mapgen.BASE_RING then return false end
  end
  for _, pa in ipairs(P.patches) do
    if point_box_dist(p, pa.box) < 3 then return false end
  end
  if P.ruin and point_box_dist(p, ruin_box(P.ruin)) < 4 then return false end
  for _, m in ipairs(P.moats) do
    if m.force ~= force and m.len > 0 and moat_side_dist(p, m) < mapgen.MOAT_SPACING then return false end
  end
  return true
end

-- One water moat per spawn: a band MOAT_WIDTH across, centred choke_a tiles out on its front line and perpendicular
-- to it, split by a MOAT_GAP land gap on the front line. Each side grows from the gap outwards in 4-tile slices, one
-- slice per side per round (fair between spawns), and stops at its first slice that breaks a keep-out rule (sample
-- points every 2 tiles). Every side is then cut to the shortest side's length; if that is under MOAT_MIN, no spawn
-- gets a moat (crowded maps: 1v2 and 1v3 small).
-- Why crowded small maps get none (Wave C, 2026-10-16; docs/qa/phase4-mapgen-notes.md "Small maps with 2-3
-- opponents"): the base ring pushes every moat to choke_a >= BASE_RING + MOAT_WIDTH / 2 = 68 from its CC, so on the
-- small spawn circle (88) all moat lines sit 18-20 tiles from the arena centre and cross each other there. A model
-- of this planner found no fair moat (every side >= MOAT_MIN) for 1v3 small with any choke_a, spacing or middle
-- layout, and for 1v2 small only with a 50-tile base ring and no middle patches. Shorter sides do not help: the
-- first slice next to the gap already collides with a neighbour's moat.
local function plan_moats(P, spec, geo)
  local sides = {}
  for _, force in ipairs(spec.forces) do
    local home = spec.spawns[force]
    local f, s = axes_of(home)
    for _, sign in ipairs({1, -1}) do
      local m = {force = force, home = home, f = f, s = s, a = geo.choke_a, sign = sign, len = 0, alive = true}
      sides[#sides + 1] = m
      P.moats[#P.moats + 1] = m
    end
    P.gaps[#P.gaps + 1] = {force = force, position = {x = home.x + f.x * geo.choke_a, y = home.y + f.y * geo.choke_a}}
  end
  local half, lo = mapgen.MOAT_WIDTH / 2, mapgen.MOAT_GAP / 2
  for _ = 1, math.floor(geo.moat_len / 4) do
    for _, m in ipairs(sides) do
      if m.alive then
        local ok = true
        for da = -half, half, 2 do
          for _, db in ipairs({m.len, m.len + 2, m.len + 4}) do
            local a, b = m.a + da, (lo + db) * m.sign
            local p = {x = m.home.x + m.f.x * a + m.s.x * b, y = m.home.y + m.f.y * a + m.s.y * b}
            if not moat_point_ok(P, spec, m.force, p) then ok = false break end
          end
          if not ok then break end
        end
        if ok then m.len = m.len + 4 else m.alive = false end
      end
    end
  end
  local n = math.huge
  for _, m in ipairs(sides) do n = math.min(n, m.len) end
  if n < mapgen.MOAT_MIN then
    P.skipped[#P.skipped + 1] = string.format("moats (a side has room for %d tiles)", n)
    P.moats = {}
    return
  end
  for _, m in ipairs(sides) do m.len = n end
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
  if moat_dist(P, c) < R + 4 then return false end
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
  if moat_dist(P, c) < r + 3 then return false end
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
             moats = {}, gaps = {}, forests = {}, corridors = {}, skipped = {},
             ruin = {x = mapgen.RUIN_POSITION.x, y = mapgen.RUIN_POSITION.y}, spec = spec}
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
  -- Moats before the naturals: the natural solver steps around them; lakes and forests come last.
  if spec.layout == "chokes" then plan_moats(P, spec, geo) end
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

local function tkey(x, y) return (x + 4096) * 8192 + (y + 4096) end

-- Moat corners are rounded (cosmetic, only removes water): radius MOAT_END_ROUND at the outer end, 2 at the gap.
-- da = |a - centre line|, b = along the side from the gap edge region (lo .. lo + len).
mapgen.MOAT_END_ROUND = 5
local function in_rounded(da, b, half, lo, len)
  local function corner(r, bc)
    local dx, dy = da - (half - r), b - bc
    return dx <= 0 or (dx * dx + dy * dy) <= r * r
  end
  local r1 = mapgen.MOAT_END_ROUND
  if b > lo + len - r1 and not corner(r1, lo + len - r1) then return false end
  if b < lo + 2 and not corner(2, lo + 2) then return false end
  return true
end

-- Water of the lakes and moats, then a 2-tile sand shore around it, in one set_tiles call. Returns the number of
-- water tiles, the water set {[tkey] = true} and the water tiles per moat side.
local function build_water(surface, P)
  local water = {}
  local n = 0
  local function put(x, y, name)
    local k = tkey(x, y)
    if not water[k] or name == "deepwater" then
      if not water[k] then n = n + 1 end
      water[k] = name
    end
  end
  for _, l in ipairs(P.lakes) do
    local R = math.ceil(l.r * mapgen.LAKE_SHAPE) + 1
    for x = l.x - R, l.x + R do
      for y = l.y - R, l.y + R do
        local px, py = x + 0.5 - l.x, y + 0.5 - l.y
        local d = math.sqrt(px * px + py * py)
        local rr = lake_radius(l, math.atan2(py, px))
        if d <= rr * 0.55 then put(x, y, "deepwater") elseif d <= rr then put(x, y, "water") end
      end
    end
  end
  local half, lo = mapgen.MOAT_WIDTH / 2, mapgen.MOAT_GAP / 2
  for _, m in ipairs(P.moats) do
    m.tiles = 0
    -- bounding box of the side's four corners
    local xs, ys = {}, {}
    for _, a in ipairs({m.a - half, m.a + half}) do
      for _, b in ipairs({lo * m.sign, (lo + m.len) * m.sign}) do
        xs[#xs + 1] = m.home.x + m.f.x * a + m.s.x * b
        ys[#ys + 1] = m.home.y + m.f.y * a + m.s.y * b
      end
    end
    for x = math.floor(math.min(table.unpack(xs))) - 1, math.ceil(math.max(table.unpack(xs))) + 1 do
      for y = math.floor(math.min(table.unpack(ys))) - 1, math.ceil(math.max(table.unpack(ys))) + 1 do
        local dx, dy = x + 0.5 - m.home.x, y + 0.5 - m.home.y
        local a = dx * m.f.x + dy * m.f.y
        local b = (dx * m.s.x + dy * m.s.y) * m.sign
        if math.abs(a - m.a) <= half and b >= lo and b <= lo + m.len and in_rounded(math.abs(a - m.a), b, half, lo, m.len) then
          put(x, y, (math.abs(a - m.a) <= half - 4 and b >= lo + 2 and b <= lo + m.len - 2) and "deepwater" or "water")
          m.tiles = m.tiles + 1
        end
      end
    end
  end
  local tiles = {}
  local shore = tile_ok(mapgen.SHORE_TILE) and mapgen.SHORE_TILE or nil
  local sand = {}
  for k, name in pairs(water) do
    local x, y = math.floor(k / 8192) - 4096, k % 8192 - 4096
    tiles[#tiles + 1] = {name = name, position = {x, y}}
    if shore then
      for ox = -2, 2 do
        for oy = -2, 2 do
          local k2 = tkey(x + ox, y + oy)
          if not water[k2] and not sand[k2] then
            sand[k2] = true
            tiles[#tiles + 1] = {name = shore, position = {x + ox, y + oy}}
          end
        end
      end
    end
  end
  if #tiles > 0 then surface.set_tiles(tiles, true, true, true, false) end
  return n, water
end

-- Land width of each spawn's gap, measured on the moat's centre line from the built water.
local function measure_gaps(P, water)
  local out = {}
  for _, g in ipairs(P.gaps) do
    local m
    for _, side in ipairs(P.moats) do
      if side.force == g.force then m = side break end
    end
    if m then
      local width = 0
      for _, sign in ipairs({1, -1}) do
        local b = 0
        while b < mapgen.MOAT_GAP + 20 do
          local x = g.position.x + m.s.x * b * sign
          local y = g.position.y + m.s.y * b * sign
          if water[tkey(math.floor(x), math.floor(y))] then break end
          b = b + 0.25
        end
        width = width + b
      end
      g.width = width
      out[#out + 1] = string.format("%s %.1f", g.force, width)
    end
  end
  return table.concat(out, ", ")
end

-- Land connectivity on a 2-tile grid (a cell with any water is blocked), from the first spawn: every CC, patch,
-- gap and the ruin must be reachable. Returns the number of unreachable targets and their names.
local function check_connectivity(P, spec, water)
  local half = P.half
  local function blocked(cx, cy)
    local x, y = cx * 2, cy * 2
    return water[tkey(x, y)] or water[tkey(x + 1, y)] or water[tkey(x, y + 1)] or water[tkey(x + 1, y + 1)]
  end
  local lo, hi = math.floor(-half / 2), math.floor((half - 1) / 2)
  local function ckey(cx, cy) return (cx + 1024) * 2048 + (cy + 1024) end
  local start = spec.spawns[spec.forces[1]]
  local sx, sy = math.floor(start.x / 2), math.floor(start.y / 2)
  local seen, queue, head = {[ckey(sx, sy)] = true}, {{sx, sy}}, 1
  while head <= #queue do
    local c = queue[head]
    head = head + 1
    for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
      local nx, ny = c[1] + d[1], c[2] + d[2]
      if nx >= lo and nx <= hi and ny >= lo and ny <= hi then
        local k = ckey(nx, ny)
        if not seen[k] and not blocked(nx, ny) then
          seen[k] = true
          queue[#queue + 1] = {nx, ny}
        end
      end
    end
  end
  local bad = {}
  local function target(name, p)
    if not seen[ckey(math.floor(p.x / 2), math.floor(p.y / 2))] then bad[#bad + 1] = name end
  end
  for _, f in ipairs(spec.forces) do target("CC " .. f, spec.spawns[f]) end
  for _, pa in ipairs(P.patches) do target(pa.id, pa.center) end
  for _, g in ipairs(P.gaps) do target("gap " .. g.force, g.position) end
  if P.ruin then target("ruin", P.ruin) end
  return #bad, table.concat(bad, ", "), #queue
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
--- Returns the number of resource tiles and the amount placed. opts.land_only (Nation worlds, scripts/world.lua):
--- skip tiles that cannot hold ore (water, rts-mountain, rts-ford, rts-marsh: the resource collision layer).
function mapgen.place_patch(surface, name, center, w, h, total, opts)
  local land_only = opts and opts.land_only
  local cx, cy = center.x, center.y
  local x0, y0 = math.floor(cx - w / 2 + 0.5), math.floor(cy - h / 2 + 0.5)
  local cells, weight = {}, 0
  for tx = x0, x0 + w - 1 do
    for ty = y0, y0 + h - 1 do
      local px, py = tx + 0.5, ty + 0.5
      local nx, ny = (px - cx) / (w / 2), (py - cy) / (h / 2)
      local d2 = nx * nx + ny * ny
      if d2 <= 1.15 and surface.count_entities_filtered({position = {px, py}, type = "resource"}) == 0
         and not (land_only and surface.get_tile(tx, ty).collides_with("resource")) then
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
-- indestructible until captured. opts (Nation worlds, scripts/world.lua): stock = {{item, count}, ...} (default
-- RUIN_STOCK), keys = {label, owned, capturing} locale keys (default the ruin's), kind = "ruin" | "port".
local RUIN_KEYS = {label = "rts.ruin-label", owned = "rts.ruin-owned", capturing = "rts.ruin-capturing"}
local function make_ruin(surface, pos, opts)
  opts = opts or {}
  local stock = opts.stock or mapgen.RUIN_STOCK
  local keys = opts.keys or RUIN_KEYS
  local cc = surface.create_entity({name = "rts-command-center", position = {pos.x, pos.y}, force = "neutral",
                                    create_build_effect_smoke = false})
  if cc then
    cc.destructible = false
    cc.minable_flag = false -- 2.1: LuaEntity::minable is read-only, minable_flag
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
      s.minable_flag = false -- 2.1: LuaEntity::minable is read-only, minable_flag
      local item = stock[i]
      if item then s.insert({name = item[1], count = item[2]}) end
      chests[#chests + 1] = s
    end
  end
  local label = rendering.draw_text({text = {keys.label}, surface = surface, target = {pos.x, pos.y - 3.2},
                                     color = {0.85, 0.8, 0.6}, scale = 1.6, alignment = "center",
                                     vertical_alignment = "middle"})
  return {position = {x = pos.x, y = pos.y}, cc = cc, chests = chests, progress = 0, label = label,
          keys = opts.keys, kind = opts.kind}
end
local function build_ruin(surface, P) return make_ruin(surface, P.ruin) end

--- Build the planned map on the arena (before the CCs are placed). Records patches and the ruin in storage.mapgen.
function mapgen.build(surface, P)
  local prof = helpers.create_profiler()
  local s = {surface = surface.name, layout = P.layout, size = P.size, patches = {}, counts = {}}
  local water, water_set = build_water(surface, P)
  local gaps = measure_gaps(P, water_set)
  local unreachable, unreachable_list, land_cells = check_connectivity(P, P.spec, water_set)
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
  -- moat geometry for other modules (AI, tests): each side is the water band |a - a0| <= MOAT_WIDTH / 2,
  -- MOAT_GAP / 2 <= b * sign <= MOAT_GAP / 2 + len in the spawn's front / side axes (a along front, b along side)
  s.moats, s.gaps = {}, {}
  for _, m in ipairs(P.moats) do
    s.moats[#s.moats + 1] = {force = m.force, home = m.home, front = m.f, side = m.s, sign = m.sign, a = m.a, len = m.len}
  end
  for _, g in ipairs(P.gaps) do
    if #P.moats > 0 then s.gaps[#s.gaps + 1] = {force = g.force, position = g.position, width = g.width} end
  end
  prof.stop()
  s.counts = {lakes = #P.lakes, water_tiles = water, moats = #P.moats / 2, forests = #P.forests, trees = trees,
              patches = #P.patches, skipped = #P.skipped, chokes = gaps, unreachable = unreachable}
  s.next_report = game.tick + mapgen.REPORT_PERIOD
  storage.mapgen = s
  local lakes, moats = {}, {}
  for _, l in ipairs(P.lakes) do lakes[#lakes + 1] = string.format("(%d, %d) r%.0f", l.x, l.y, l.r) end
  for _, m in ipairs(P.moats) do
    moats[#moats + 1] = string.format("%s %s %d long %d tiles", m.force, m.sign > 0 and "+" or "-", m.len, m.tiles or 0)
  end
  log({"", string.format("[rts] mapgen: %s %s on %s: moats %d [%s]; lakes %d [%s]; water tiles %d; forests %d with %d "
    .. "trees; patches %d; ruin at %s with %d stockpiles; skipped [%s]; built in ", P.layout, P.size, surface.name,
    #P.moats / 2, table.concat(moats, ", "), #P.lakes, table.concat(lakes, ", "), water, #P.forests, trees, #P.patches,
    util.pos_str(P.ruin), #s.ruin.chests, table.concat(P.skipped, ", ")), prof})
  util.log("mapgen: moat gaps (land on the moat centre line): %s", gaps ~= "" and gaps or "none")
  util.log("mapgen: land connectivity from %s: %d cells reachable, %s", P.spec.forces[1], land_cells,
    unreachable == 0 and "every CC, patch, gap and the ruin reachable" or ("UNREACHABLE: " .. unreachable_list))
  util.log("mapgen: natural and middle patches: %s", table.concat(parts, "; "))
  return s
end

--- Forget the data of a torn-down match (match.teardown).
function mapgen.reset()
  storage.mapgen = {patches = {}}
end

-- Nation worlds (scripts/world.lua, Phase 5 M1): the world places its own ore and sites and records them here, so
-- depletion alerts, the "ore remaining" report, ruin capture and /rts-mapgen work unchanged.
--- Start the records of a world surface (instead of mapgen.build).
function mapgen.adopt(surface_name, layout, size)
  storage.mapgen = {surface = surface_name, layout = layout, size = size, patches = {}, ruins = {}, counts = {},
                    next_report = game.tick + mapgen.REPORT_PERIOD}
end

--- Record a placed patch: {id, kind, force?, name, center, box = {x0, y0, x1, y1}, total, tiles, remaining}.
function mapgen.record_patch(rec)
  local s = storage.mapgen
  s.patches[#s.patches + 1] = rec
  s.counts.patches = #s.patches
end

--- Place a ruin (or a port: opts.kind, opts.stock, opts.keys) and record it for capture. Returns the record.
function mapgen.add_ruin(surface, pos, opts)
  local s = storage.mapgen
  local r = make_ruin(surface, pos, opts)
  s.ruins = s.ruins or {}
  s.ruins[#s.ruins + 1] = r
  return r
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

--- Match forces with a mining drill on (or next to) patch p, sorted.
function mapgen.miners(surface, p)
  local m = 3 -- an extractor mines a 5x5 area: one standing next to the patch box reaches its edge
  local set = {}
  for _, e in pairs(surface.find_entities_filtered({area = {{p.box.x0 - m, p.box.y0 - m}, {p.box.x1 + m, p.box.y1 + m}},
                                                   type = "mining-drill"})) do
    set[e.force.name] = true
  end
  local out = {}
  for _, f in ipairs(participants()) do
    if set[f] then out[#out + 1] = f end
  end
  return out
end

-- (Phase 5 M3 perf: slice/slices, Nation mode: only the patches i with (i - 1) % slices == slice)
local function check_depletion(surface, slice, slices)
  for i, p in ipairs(storage.mapgen.patches) do
    if not p.depleted_tick and (not slices or (i - 1) % slices == slice) then
      p.remaining = mapgen.remaining(surface, p)
      if p.remaining <= 0 then
        p.depleted_tick = game.tick
        local item = {"item-name." .. p.name}
        util.log("mapgen: patch %s depleted at %.0fs", p.id, (game.tick - (storage.match.tick_started or 0)) / 60)
        -- Phase 5 M1 integration: a patch without an owner (the middle, the world's regions) alerts only the forces
        -- whose extractors stand on it, not every participant
        local to = p.force and {p.force} or mapgen.miners(surface, p)
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

-- Phase 5 M3 perf: a Nation world records dozens of patches and recounting all of them (find_entities_filtered over
-- every ore tile) took 3-16 ms in one tick every 10 s; there the check runs in DEPLETION_SLICES slices, one every
-- DEPLETION_PERIOD / DEPLETION_SLICES ticks, so each patch is still recounted once per DEPLETION_PERIOD.
mapgen.DEPLETION_SLICES = 10
local function nation_world()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end
events.on_nth_tick(mapgen.DEPLETION_PERIOD / mapgen.DEPLETION_SLICES, function(e)
  if not nation_world() then return end
  local surface = live_surface()
  if not surface or storage.match.phase ~= "running" then return end
  local n = mapgen.DEPLETION_SLICES
  check_depletion(surface, (e.tick / (mapgen.DEPLETION_PERIOD / n)) % n, n)
end)

events.on_nth_tick(mapgen.DEPLETION_PERIOD, function(e)
  local surface = live_surface()
  if not surface or storage.match.phase ~= "running" then return end
  if not nation_world() then check_depletion(surface) end -- Phase 5 M3 perf: Nation slices above
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
  set_label(ruin, {(ruin.keys or RUIN_KEYS).owned, label_of(force_name)})
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
local capture_one -- one ruin's step (below)
function mapgen.capture_step(dt)
  local surface = live_surface()
  local s = storage.mapgen
  if not (surface and s and storage.match.phase == "running") then return end
  if s.ruins then -- a Nation world: every ruin and port
    for _, ruin in ipairs(s.ruins) do capture_one(surface, ruin, dt) end
  elseif s.ruin then
    capture_one(surface, s.ruin, dt)
  end
end

capture_one = function(surface, ruin, dt)
  local keys = ruin.keys or RUIN_KEYS
  local alive = false
  for _, chest in ipairs(ruin.chests or {}) do
    if chest.valid then alive = true end
  end
  if not alive then return end
  local present, any = present_forces(surface, ruin)
  if not any then
    if ruin.capturing then
      ruin.capturing, ruin.progress = nil, 0
      set_label(ruin, ruin.owner and {keys.owned, label_of(ruin.owner)} or {keys.label})
    end
    return
  end
  local challengers = {}
  -- Phase 5 M2 diplomacy: only a force at war with the owner can take an owned ruin or port (Skirmish: every force)
  local l = package and package.loaded
  local diplomacy = l and (l["__" .. script.mod_name .. "__/scripts/diplomacy.lua"] or l["scripts.diplomacy"])
  for f in pairs(present) do
    if f ~= ruin.owner and (not ruin.owner or not diplomacy or diplomacy.hostile(f, ruin.owner)) then
      challengers[#challengers + 1] = f
    end
  end
  if #challengers ~= 1 or (ruin.owner and present[ruin.owner]) then return end -- contested or defended: hold
  local f = challengers[1]
  if ruin.capturing ~= f then ruin.capturing, ruin.progress = f, 0 end
  ruin.progress = ruin.progress + (dt or mapgen.CAPTURE_PERIOD)
  if ruin.progress >= mapgen.CAPTURE_TICKS then
    capture(ruin, f)
  else
    set_label(ruin, {keys.capturing, label_of(f), math.floor(100 * ruin.progress / mapgen.CAPTURE_TICKS)})
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
    for _, r in ipairs(s.ruins or {s.ruin}) do
      lines[#lines + 1] = string.format("[rts] mapgen: %s at %s: owner %s, capturing %s (%d ticks)", r.kind or "ruin",
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
--- (rts-mapgen-<tick>-middle.png: ruin, middle patches, the nearest moats).
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
