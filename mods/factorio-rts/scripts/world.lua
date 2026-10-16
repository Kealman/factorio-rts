-- Phase 5 M1 world (docs/PHASE5-M1.md §3 world.lua; study docs/research/scale/world-map.md): Nation-mode maps.
--
-- Hybrid generation. Lua plans the strategic skeleton (spawns, mountain ranges with passes, rivers with fords, coasts,
-- lakes, climate anchors, protected sites, ore deposits); prototypes/world.lua turns it into terrain through named
-- noise expressions that read the skeleton as numeric constants from MapGenSettings.property_expression_names.
--
--   world.size_for(nations)        the default size: 1536 for 2 nations, 2048 for 3-4 (1536 / 2048 / 3072 selectable)
--   world.plan(config, seed)       skeleton + validation on engine samples (LuaSurface.calculate_tile_properties on
--                                  an ungenerated sampler surface, 8-tile grid): land connectivity, start kits, spawn
--                                  scores; a failing skeleton is re-rolled (world.ATTEMPTS). Then sites and regions.
--   world.map_gen_settings(plan)   the arena's MapGenSettings (Nauvis tiles, trees, decoratives; no ore, no enemies)
--   world.apply(surface, plan)     blocking core (CORE_RADIUS chunks around each spawn), spawn areas cleared, start
--                                  kits placed; the rest of the map generates in the background and every planned
--                                  feature (ore deposit, oil field, ruin, port) is placed when its chunks exist
--   world.region_at(position)      -> region {id, name, label, kind = "highland"|"plain"|"swamp"|"coast", climate,
--                                     role, center, owner?, resources = {[name] = total}}
--   world.regions(), world.spawns() -> {position, ...} (force order), world.spawn_of(force)
--   world.sites(kind?)             -> {{kind = "city_site"|"ruin"|"port"|"oil", position, region, ...}}
--   world.chokes()                 -> {{kind = "pass"|"ford", position, width, name, label, barrier}}
--   world.reset()                  match teardown (match.lua)
--
-- Ore goes through mapgen.place_patch (exact totals) and is recorded with mapgen.record_patch, so the depletion
-- alerts, the "ore remaining" report and /rts-mapgen cover the world; ruins and ports are mapgen ruins
-- (mapgen.add_ruin), captured like the Skirmish ruin.
--
-- Owns storage.world = {
--   size, seed, surface, plan (skeleton, sites, regions, scores; no grid), regions, spawns = {{force, position}},
--   sites, chokes, region_grid (32-tile Voronoi lookup), features (placement queue), pending = {[chunk key] = {i}},
--   fill = {total, generated, done, started, done_tick, last}, post (real-tile check after the fill), checks
-- }
local util = require("scripts.util")
local events = require("scripts.events")
local mapgen = require("scripts.mapgen")

local world = {}

-- Must match prototypes/world.lua SLOTS (world.check_prototypes).
world.SLOTS = {range = 16, pass = 12, river = 12, ford = 16, site = 24, lake = 12, climate = 24}
world.SIZES = {1536, 2048, 3072} -- accepted config.world_size values (the lobby offers all three in Nation mode)
world.CELL = 8                   -- validation grid (tiles per cell)
world.CORE_RADIUS = 6            -- chunks generated around each spawn before the match starts (192 tiles)
world.CLEAR_RADIUS = 100         -- trees and rocks removed around each spawn (the AI's base and naturals)
world.SPAWN_CLEAR = 175          -- protected disc around a spawn: no range, river, sea or marsh
world.KIT_RADIUS = 150           -- the start kit lies within this many tiles of the spawn
world.ATTEMPTS = 8
world.SPREAD_MAX = 0.15          -- spawn score spread (max - min) / max
world.WARP = 22                  -- domain warp amplitude (tiles)
world.RANGE_W = {18, 21}         -- range half thickness (plus about 3 tiles of rough edge)
world.RIVER_W = {17, 20}         -- river half width
world.MIN_THICK = 30             -- every barrier at least this thick on real (sampled) tiles: thinner spots are
                                 -- widened (world crossing probe: the artillery spider bridged an 18-tile spot)
world.PASS_OPEN = {34, 46}       -- open ground across a range at a pass (the disc radius follows the range width)
world.FORD_R_EXTRA = {9, 12}     -- ford disc radius = river half width + this
world.DENSITY = 170              -- ore per tile in deposit patches
world.SAMPLER = "rts-world-sampler"
world.MASSIFS = 2                -- free-standing short ranges in frontier regions
world.write_images = false       -- QA: write the real-tile class grid as script-output/rts-world-<surface>.ppm
world.QA_COUNTS = false          -- QA: whole-map tile and entity counts when the fill completes (about 100 ms in one
                                 -- tick at 2048, so off in play; tools/probes/world_seeds.lua turns it on)
world.LABEL_COLORS = {region = {0.95, 0.92, 0.8}, pass = {0.85, 0.85, 0.9}, ford = {0.6, 0.85, 0.95}}
-- Chart labels keep a fixed size in the world (scale_with_zoom off): about 16 tiles tall for a region, 9 for a pass
-- or ford, readable in the map view at strategic zoom and only a few pixels in the HUD minimap (with
-- scale_with_zoom on, screen-sized names covered the whole minimap: GUI probe 2026-10-16).
world.LABEL_SCALE = {region = 28, choke = 16}

-- Volumes (balance.nation.world overrides, docs/PHASE5-M1.md §1). value = sum of ore x VALUE weight.
local ok_balance, balance = pcall(require, "balance")
local NB = (ok_balance and type(balance) == "table" and balance.nation and balance.nation.world) or {}
world.MAIN_TOTALS = NB.main_totals or {["iron-ore"] = 18000, ["copper-ore"] = 12000, stone = 9000, coal = 9000}
-- natural pair per spawn: {ore, w, h, total, side}; NATURAL_A tiles out along the front, NATURAL_SIDE to the sides
world.NATURAL = NB.natural or {{"iron-ore", 10, 10, 16000, 1}, {"copper-ore", 8, 8, 8000, -1}}
world.NATURAL_A, world.NATURAL_SIDE = 70, 13
world.VALUE = {["iron-ore"] = 1, ["copper-ore"] = 1, coal = 0.8, stone = 0.5, well = 6000}
world.OIL_HOME = NB.oil_home or {wells = 3, amount = 450000}
world.OIL_CENTER = NB.oil_center or {wells = 8, amount = 600000}
-- Home specialties: equal value (66,000), different kind; every nation gets one.
world.SPECIALTIES = NB.specialties or {
  iron = {kind = "highland", ores = {{"iron-ore", 60000, 3}, {"stone", 12000, 1}}},
  copper = {kind = "highland", ores = {{"copper-ore", 60000, 3}, {"stone", 12000, 1}}},
  coal = {kind = "swamp", ores = {{"coal", 60000, 3}}, wells = 3},
  mixed = {kind = "highland", ores = {{"iron-ore", 30000, 2}, {"copper-ore", 30000, 2}, {"stone", 12000, 1}}},
}
world.SPECIALTY_ORDER = {"iron", "copper", "coal", "mixed"}
-- Contested majors on the bisectors between neighbours (richer than home): kind order per nation count.
world.CONTESTED = NB.contested or {
  copper = {{"copper-ore", 90000, 3}}, iron = {{"iron-ore", 90000, 3}}, coal = {{"coal", 112000, 3}},
}
world.CONTESTED_ORDER = {[2] = {"copper", "iron"}, [3] = {"copper", "iron", "coal"}, [4] = {"copper", "iron", "copper", "iron"}}
world.RUIN_STOCK = {{"steel-plate", 200}, {"electronic-circuit", 50}}
world.PORT_STOCK = {{"steel-plate", 300}, {"electronic-circuit", 100}}

-- Names (locale rts-world.proper-<i>; English copies for the log).
world.PROPER = {"Kerr", "Ash", "Varn", "Oster", "Bel", "Dorn", "Hale", "Iver", "Mar", "Brenn", "Corvo", "Elm", "Fenn",
                "Gall", "Hask", "Ivo", "Jor", "Kell", "Lind", "Mott", "Nor", "Orrin", "Pell", "Quill", "Ros", "Sarn",
                "Tor", "Ulm", "Vell", "Wren", "Yarr", "Zell", "Adder", "Brisk", "Cold", "Dunn", "Erne", "Frey",
                "Grim", "Holt"}
world.NOUNS = {highland = {"Hills", "Highlands", "Heights"}, plain = {"Plains", "Fields", "Vale"},
               swamp = {"Marsh", "Fens", "Mire"}, coast = {"Coast", "Shore", "Strand"}}

local TAU = 2 * math.pi
local floor, sqrt, max, min, abs = math.floor, math.sqrt, math.max, math.min, math.abs

--- Module lookup at call time (match requires this module).
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

function world.init()
  storage.world = storage.world or {}
end

function world.reset()
  storage.world = {}
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------
local function V(x, y) return {x = x, y = y} end
local function vadd(a, b, k) k = k or 1 return {x = a.x + b.x * k, y = a.y + b.y * k} end
local function dist(a, b) return sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function norm(v) local l = sqrt(v.x * v.x + v.y * v.y) if l < 1e-9 then return V(1, 0) end return V(v.x / l, v.y / l) end
local function rot(v, a) local c, s = math.cos(a), math.sin(a) return V(v.x * c - v.y * s, v.x * s + v.y * c) end
local function round(p) return V(floor(p.x + 0.5), floor(p.y + 0.5)) end
local function seg_dist(p, a, b)
  local vx, vy = b.x - a.x, b.y - a.y
  local l2 = vx * vx + vy * vy
  local t = l2 > 0 and ((p.x - a.x) * vx + (p.y - a.y) * vy) / l2 or 0
  t = max(0, min(1, t))
  return dist(p, V(a.x + vx * t, a.y + vy * t)), t
end
local function poly_dist(p, pts)
  local best = math.huge
  for i = 1, #pts - 1 do best = min(best, (seg_dist(p, pts[i], pts[i + 1]))) end
  return best
end
--- Point at arc length s along a polyline.
local function poly_at(pts, s)
  for i = 1, #pts - 1 do
    local l = dist(pts[i], pts[i + 1])
    if s <= l or i == #pts - 1 then
      local t = l > 0 and min(1, s / l) or 0
      return V(pts[i].x + (pts[i + 1].x - pts[i].x) * t, pts[i].y + (pts[i + 1].y - pts[i].y) * t)
    end
    s = s - l
  end
  return pts[#pts]
end
-- Index of the segment that holds arc length s.
local function poly_index(pts, s)
  for i = 1, #pts - 1 do
    local l = dist(pts[i], pts[i + 1])
    if s <= l then return i end
    s = s - l
  end
  return #pts - 1
end
local function poly_length(pts)
  local t = 0
  for i = 1, #pts - 1 do t = t + dist(pts[i], pts[i + 1]) end
  return t
end
-- Distance from the map centre to the square map's edge along an angle.
local function edge_distance(angle, half)
  return half / max(abs(math.cos(angle)), abs(math.sin(angle)))
end
-- Front (towards the map centre) and side axes of a spawn: match.front's rule.
local function axes_of(home)
  local len = sqrt(home.x * home.x + home.y * home.y)
  if len < 1 then return V(1, 0), V(0, 1) end
  local f = V(-home.x / len, -home.y / len)
  local sx, sy = -f.y, f.x
  if sy < -1e-9 or (abs(sy) <= 1e-9 and sx < 0) then sx, sy = -sx, -sy end
  return f, V(sx, sy)
end
world.axes_of = axes_of
-- Distance from p to the sea of each sea edge (positive inland); math.huge without sea.
local function sea_margin(P, p)
  local best = math.huge
  local H = P.half
  for e, d in pairs(P.sea) do
    local to_edge = (e == "n" and p.y + H) or (e == "s" and H - p.y) or (e == "e" and H - p.x) or (H + p.x)
    best = min(best, to_edge - d)
  end
  return best
end
local function edge_margin(P, p) return P.half - max(abs(p.x), abs(p.y)) end

---------------------------------------------------------------------------
-- Sizes and config
---------------------------------------------------------------------------
--- Default map size (tiles) for a number of nations: 2 -> 1536, 3-4 -> 2048 (docs/PHASE5-M1.md §1; the lobby also
--- offers the other sizes of world.SIZES).
function world.size_for(nations)
  return (nations or 2) <= 2 and 1536 or 2048
end

--- A valid world size: `size` when it is one of world.SIZES, else size_for(nations).
function world.normalize_size(size, nations)
  size = tonumber(size)
  for _, s in ipairs(world.SIZES) do
    if size == s then return s end
  end
  return world.size_for(nations)
end

--- The last slot of every kind must exist (prototypes/world.lua and world.SLOTS agree). Returns ok, message.
function world.check_prototypes()
  local nx = prototypes.named_noise_expression
  local function has(name) return nx and nx[name] ~= nil end
  local probes = {
    {"rts_w_rg" .. world.SLOTS.range .. "_w", "rts_w_rg" .. (world.SLOTS.range + 1) .. "_w"},
    {"rts_w_ps" .. world.SLOTS.pass .. "_r", "rts_w_ps" .. (world.SLOTS.pass + 1) .. "_r"},
    {"rts_w_rv" .. world.SLOTS.river .. "_w", "rts_w_rv" .. (world.SLOTS.river + 1) .. "_w"},
    {"rts_w_fd" .. world.SLOTS.ford .. "_r", "rts_w_fd" .. (world.SLOTS.ford + 1) .. "_r"},
    {"rts_w_st" .. world.SLOTS.site .. "_r", "rts_w_st" .. (world.SLOTS.site + 1) .. "_r"},
    {"rts_w_lk" .. world.SLOTS.lake .. "_r", "rts_w_lk" .. (world.SLOTS.lake + 1) .. "_r"},
    {"rts_w_cl" .. world.SLOTS.climate .. "_r", "rts_w_cl" .. (world.SLOTS.climate + 1) .. "_r"},
  }
  for _, p in ipairs(probes) do
    if not has(p[1]) or has(p[2]) then return false, "slot mismatch at " .. p[1] end
  end
  for _, t in ipairs({"rts-mountain", "rts-ford", "rts-marsh"}) do
    if not prototypes.tile[t] then return false, "missing tile " .. t end
  end
  return true, "ok"
end

---------------------------------------------------------------------------
-- Skeleton
---------------------------------------------------------------------------
local function new_rng(seed, attempt, nations)
  return game.create_random_generator(mapgen.mix_seed((seed or 1) * 31 + (attempt or 0) * 7919 + (nations or 2) * 104729))
end

local function shuffle(rng, t)
  for i = #t, 2, -1 do
    local j = rng(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

-- Names: a shuffled proper-name list per plan, handed out in order.
local function namer(rng)
  local idx = {}
  for i = 1, #world.PROPER do idx[i] = i end
  shuffle(rng, idx)
  local n = 0
  return function()
    n = n + 1
    return idx[(n - 1) % #idx + 1]
  end
end

local function region_name(kind, noun, proper)
  return {"rts-world.region-name", {"rts-world.noun-" .. kind .. "-" .. noun}, {"rts-world.proper-" .. proper}},
         world.PROPER[proper] .. " " .. world.NOUNS[kind][noun]
end

-- Main patches of the start kit (match.ORE_PATCHES in the spawn's front axes, the Skirmish layout the AI planner
-- knows) and the natural pair NATURAL_A tiles out along the front.
local function start_kit(P, sp)
  local match = loaded("scripts.match")
  local mains = match and match.ORE_PATCHES or {{"iron-ore", 17, 10, 12, 12}, {"copper-ore", 17, -10, 8, 8},
                                                 {"stone", 28, 16, 6, 6}, {"coal", 36, 16, 6, 6}}
  local f, s = axes_of(sp)
  local out = {}
  for _, p in ipairs(mains) do
    out[#out + 1] = {kind = "main", force = sp.force, name = p[1], w = p[4], h = p[5],
                     total = world.MAIN_TOTALS[p[1]] or 9000,
                     center = round(V(sp.x + f.x * p[2] + s.x * p[3], sp.y + f.y * p[2] + s.y * p[3]))}
  end
  for _, n in ipairs(world.NATURAL) do
    local a, b = world.NATURAL_A, world.NATURAL_SIDE * n[5]
    out[#out + 1] = {kind = "natural", force = sp.force, name = n[1], w = n[2], h = n[3], total = n[4],
                     center = round(V(sp.x + f.x * a + s.x * b, sp.y + f.y * a + s.y * b))}
  end
  return out
end

-- Split a deposit's ores into patches around its centre (exact totals per ore, the last patch takes the rest).
local function deposit_patches(rng, d, ores)
  local list = {}
  for _, o in ipairs(ores) do
    local parts = o[3] or 1
    local each = floor(o[2] / parts)
    for i = 1, parts do
      list[#list + 1] = {name = o[1], total = (i == parts) and (o[2] - each * (parts - 1)) or each}
    end
  end
  local n = #list
  local a0 = rng() * TAU
  local rho = n <= 1 and 0 or d.r * 0.52
  for i, p in ipairs(list) do
    local tiles = p.total / world.DENSITY
    local side = math.max(6, math.ceil(sqrt(tiles / 0.88)))
    p.w, p.h = side, side
    local a = a0 + TAU * (i - 1) / n
    p.center = round(V(d.x + math.cos(a) * rho, d.y + math.sin(a) * rho))
  end
  return list
end

local function oil_wells(rng, d, wells, amount)
  local out = {}
  local tries = 0
  while #out < wells and tries < 400 do
    tries = tries + 1
    local a, r = rng() * TAU, d.r * 0.65 * sqrt(rng())
    local p = round(V(d.x + math.cos(a) * r, d.y + math.sin(a) * r))
    local ok = true
    for _, q in ipairs(out) do
      if dist(p, q) < 9 then ok = false break end
    end
    if ok then out[#out + 1] = {x = p.x + 0.5, y = p.y + 0.5, amount = amount} end
  end
  return out
end

-- Is `p` with radius r clear of the barriers (polylines with half width w), the map edge and the sea?
local function clear_of(P, p, r, opts)
  opts = opts or {}
  if edge_margin(P, p) < r + (opts.edge or 90) then return false, "edge" end
  if sea_margin(P, p) < r + (opts.sea or 70) then return false, "sea" end
  for _, b in ipairs(P.barriers) do
    if b ~= opts.except and poly_dist(p, b.points) < r + b.w + world.WARP + (opts.barrier or 24) then
      return false, "barrier " .. b.id
    end
  end
  for _, q in ipairs(opts.discs or {}) do
    if dist(p, q) < r + q.r + (opts.gap or 20) then return false, "disc" end
  end
  return true
end

local function protect(P, p, r, why)
  P.protect[#P.protect + 1] = {x = p.x, y = p.y, r = r, why = why}
end

-- One skeleton attempt (pure: no surface). Returns P, or nil and a reason.
local function skeleton(cfg, seed, attempt)
  local N, S = cfg.nations, cfg.size
  local H = S / 2
  local k = S / 2048
  local rng = new_rng(seed, attempt, N)
  local function rr(a, b) return a + (b - a) * rng() end
  local P = {version = 1, seed = seed, attempt = attempt, size = S, half = H, nations = N, forces = cfg.forces,
             spawns = {}, barriers = {}, crossings = {}, lakes = {}, climate = {}, sea = {}, protect = {},
             deposits = {}, regions = {}, sites = {}, chokes = {}}
  local name = namer(rng)
  -- Coasts: 0-2 sea edges.
  local edges = shuffle(rng, {"n", "s", "e", "w"})
  local roll = rng()
  local nsea = roll < 0.3 and 0 or (roll < 0.75 and 1 or 2)
  for i = 1, nsea do P.sea[edges[i]] = floor(rr(70, 120) * k) end
  -- Spawns on a ring, evenly spread with a little jitter; force order = config forces (rts-player first).
  local R_s = ({[2] = 0.32, [3] = 0.30, [4] = 0.31})[N] * S
  local r_in = (N == 2 and 0.13 or 0.16) * S
  local th0 = rng() * TAU
  for i = 1, N do
    local th = th0 + TAU * (i - 1) / N + rr(-0.05, 0.05)
    local r = R_s * rr(0.97, 1.03)
    local p = round(V(r * math.cos(th), r * math.sin(th)))
    p.force, p.angle = cfg.forces[i], th
    P.spawns[i] = p
  end
  -- A sea edge too close to a spawn is dropped (the spawn disc is protected anyway; this keeps homes roomy).
  for e, d in pairs(P.sea) do
    for _, sp in ipairs(P.spawns) do
      local to_edge = (e == "n" and sp.y + H) or (e == "s" and H - sp.y) or (e == "e" and H - sp.x) or (H + sp.x)
      if to_edge < d + world.SPAWN_CLEAR + 120 then P.sea[e] = nil break end
    end
  end
  -- Barrier rays on the bisectors between angular neighbours, from r_in out past the map edge: ranges with passes
  -- and rivers with fords, alternating.
  local flip = rng(0, 1)
  for i = 1, N do
    local a1, a2 = P.spawns[i].angle, P.spawns[i % N + 1].angle
    if a2 < a1 then a2 = a2 + TAU end
    if N == 2 and i == 2 then a2 = P.spawns[1].angle + TAU end
    local bis = (a1 + a2) / 2
    local dir = V(math.cos(bis), math.sin(bis))
    local perp = V(-dir.y, dir.x)
    local d_exit = edge_distance(bis, H)
    local L = d_exit - r_in
    local pts = {}
    for j, f in ipairs({0, 1 / 3, 2 / 3}) do
      local off = (j == 1) and 0 or rr(-25, 25) * k
      pts[j] = vadd(vadd(V(0, 0), dir, r_in + L * f), perp, off)
    end
    pts[4] = vadd(V(0, 0), dir, d_exit + 80)
    local kind = ((i + flip) % 2 == 0) and "range" or "river"
    local w = kind == "range" and floor(rr(world.RANGE_W[1], world.RANGE_W[2]) + 0.5)
              or floor(rr(world.RIVER_W[1], world.RIVER_W[2]) + 0.5)
    local b = {id = #P.barriers + 1, kind = kind, points = pts, w = w, ws = {w, w, w}, ray = i, angle = bis, crossings = {},
               between = {P.spawns[i].force, P.spawns[i % N + 1].force}, proper = name()}
    P.barriers[#P.barriers + 1] = b
    -- crossings: 2 on a long ray, 1 on a short one; kept out of the sea
    local fr
    if S >= 3072 and L > 1000 then -- big maps: a crossing every 300-550 tiles
      fr = {0.28 + rr(-0.04, 0.04), 0.56 + rr(-0.04, 0.04), 0.84 + rr(-0.04, 0.04)}
    elseif L > 520 * k then
      fr = {0.38 + rr(-0.05, 0.05), 0.78 + rr(-0.05, 0.05)}
    else
      fr = {0.55 + rr(-0.05, 0.05)}
    end
    for _, f in ipairs(fr) do
      local s = L * f
      local p = poly_at(pts, s)
      while sea_margin(P, p) < 80 and s > L * 0.2 do
        s = s - 20
        p = poly_at(pts, s)
      end
      local c = {id = #P.crossings + 1, kind = kind == "range" and "pass" or "ford", x = floor(p.x + 0.5),
                 y = floor(p.y + 0.5), barrier = b.id, proper = name(), along = s,
                 open = kind == "range" and rr(world.PASS_OPEN[1], world.PASS_OPEN[2])
                        or rr(world.FORD_R_EXTRA[1], world.FORD_R_EXTRA[2])}
      c.seg = poly_index(pts, s)
      c.r = kind == "range" and floor(sqrt((w + 3) ^ 2 + (c.open / 2) ^ 2) + 0.5) or floor(w + c.open + 0.5)
      P.crossings[#P.crossings + 1] = c
      b.crossings[#b.crossings + 1] = c.id
    end
  end
  -- Home content per nation: start kit, specialty (tangential side), home oil (other side), home lake (outward).
  local spec_kinds = {}
  for i = 1, N do spec_kinds[i] = world.SPECIALTY_ORDER[i] end
  shuffle(rng, spec_kinds)
  local function place_home(sp, base_angle, dist0, side, r)
    local u = norm(sp)
    local t = rot(u, math.pi / 2)
    for _, da in ipairs({0, -12, 12, -24, 24, -36}) do
      for _, dd in ipairs({0, -40, 40, -70}) do
        local a = math.rad(base_angle + da)
        local p = round(vadd(vadd(V(sp.x, sp.y), u, (dist0 + dd) * k * math.cos(a)), t, side * (dist0 + dd) * k * math.sin(a)))
        local ok = clear_of(P, p, r, {edge = 120 * k, sea = 80, discs = P.home_discs})
        if ok and dist(p, sp) > world.SPAWN_CLEAR + r - 40 then return p end
      end
    end
    return nil
  end
  P.home_discs = {}
  for i, sp in ipairs(P.spawns) do
    protect(P, sp, world.SPAWN_CLEAR, "spawn " .. sp.force)
    P.home_discs[#P.home_discs + 1] = {x = sp.x, y = sp.y, r = world.SPAWN_CLEAR - 60}
    sp.kit = start_kit(P, sp)
    local spec = world.SPECIALTIES[spec_kinds[i]]
    local r_spec = floor(52 * max(k, 0.85))
    local p = place_home(sp, 72, 380, 1, r_spec)
    if not p then return nil, "no room for the specialty of " .. sp.force end
    local d = {id = #P.deposits + 1, role = "specialty", specialty = spec_kinds[i], force = sp.force, x = p.x, y = p.y,
               r = r_spec, kind = spec.kind}
    d.patches = deposit_patches(rng, d, spec.ores)
    if spec.wells then d.wells = oil_wells(rng, d, spec.wells, world.OIL_HOME.amount) end
    P.deposits[#P.deposits + 1] = d
    P.home_discs[#P.home_discs + 1] = {x = p.x, y = p.y, r = r_spec}
    local r_oil = floor(34 * max(k, 0.85))
    local q = place_home(sp, 78, 300, -1, r_oil)
    if not q then return nil, "no room for the home oil of " .. sp.force end
    local o = {id = #P.deposits + 1, role = "home_oil", force = sp.force, x = q.x, y = q.y, r = r_oil, kind = "swamp", patches = {}}
    o.wells = oil_wells(rng, o, world.OIL_HOME.wells, world.OIL_HOME.amount)
    P.deposits[#P.deposits + 1] = o
    P.home_discs[#P.home_discs + 1] = {x = q.x, y = q.y, r = r_oil}
    -- home lake: outward, a little to the oil side
    local u = norm(sp)
    local lake = round(vadd(V(sp.x, sp.y), rot(u, -0.35), 135))
    P.lakes[#P.lakes + 1] = {x = lake.x, y = lake.y, r = 15, why = "home " .. sp.force}
  end
  -- Contested majors on the bisector directions inside the open centre, and the oil swamp in the middle.
  local r_c = (N == 2 and 0.58 or 0.62) * r_in
  local order = world.CONTESTED_ORDER[N]
  for i, b in ipairs(P.barriers) do
    local kind = order[i]
    if kind then
      local p = round(V(math.cos(b.angle) * r_c, math.sin(b.angle) * r_c))
      local d = {id = #P.deposits + 1, role = "contested", contested = kind, x = p.x, y = p.y,
                 r = floor(52 * max(k, 0.75)), kind = "highland", between = b.between}
      d.patches = deposit_patches(rng, d, world.CONTESTED[kind])
      P.deposits[#P.deposits + 1] = d
    end
  end
  local center = {id = #P.deposits + 1, role = "center_oil", x = 0, y = 0, r = floor(60 * max(k, 0.75)), kind = "swamp",
                  patches = {}}
  center.wells = oil_wells(rng, center, world.OIL_CENTER.wells, world.OIL_CENTER.amount)
  P.deposits[#P.deposits + 1] = center
  for _, d in ipairs(P.deposits) do protect(P, d, d.r + 12, "deposit " .. d.id) end
  -- Spur ranges behind highland specialties (free ends: units walk around them; cliffs on the rim).
  for _, d in ipairs(P.deposits) do
    if d.role == "specialty" and d.kind == "highland" then
      local sp
      for _, s in ipairs(P.spawns) do if s.force == d.force then sp = s end end
      local v = norm(V(d.x - sp.x, d.y - sp.y))
      local t = rot(v, math.pi / 2)
      local c = vadd(V(d.x, d.y), v, d.r + 85 * k)
      local half_len = 130 * k
      local pts = {vadd(c, t, -half_len), vadd(vadd(c, v, rr(0, 25) * k), t, rr(-20, 20) * k), vadd(c, t, half_len)}
      local w = 16
      local ok = true
      for _, q in ipairs(P.protect) do
        if poly_dist(q, pts) < q.r + w + world.WARP + 14 then ok = false break end
      end
      for _, b in ipairs(P.barriers) do
        for _, pt in ipairs(pts) do
          if poly_dist(pt, b.points) < b.w + w + 2 * world.WARP + 60 then ok = false end
        end
      end
      for _, pt in ipairs(pts) do
        if edge_margin(P, pt) < 60 or sea_margin(P, pt) < 40 then ok = false end
      end
      if ok then
        P.barriers[#P.barriers + 1] = {id = #P.barriers + 1, kind = "range", spur = true, points = pts, w = w,
                                       ws = {w, w}, crossings = {}, proper = name()}
      end
    end
  end
  -- Region centres: homes, deposits, then filler regions (Poisson disc).
  local function add_region(p, role, kind, extra)
    local reg = {id = #P.regions + 1, center = V(p.x, p.y), role = role, kind = kind, climate = "temperate",
                 resources = {}, proper = name(), noun = rng(1, 3)}
    for k2, v in pairs(extra or {}) do reg[k2] = v end
    P.regions[#P.regions + 1] = reg
    return reg
  end
  for _, sp in ipairs(P.spawns) do add_region(sp, "home", "plain", {owner = sp.force}) end
  for _, d in ipairs(P.deposits) do
    local role = (d.role == "center_oil" or d.role == "contested") and "contested" or d.role
    local reg = add_region(d, role, d.kind, {owner = d.force})
    d.region = reg.id
    if d.kind == "highland" then reg.climate = "highland" elseif d.kind == "swamp" then reg.climate = "swamp" end
  end
  local target = S >= 3072 and 28 or (S >= 2048 and 20 or 14)
  local cands = {}
  local step = floor(96 * k)
  for x = -H + 80, H - 80, step do
    for y = -H + 80, H - 80, step do
      cands[#cands + 1] = V(x + rr(-30, 30) * k, y + rr(-30, 30) * k)
    end
  end
  shuffle(rng, cands)
  for _, c in ipairs(cands) do
    if #P.regions >= target then break end
    if sea_margin(P, c) > 40 then
      local okc = true
      for _, reg in ipairs(P.regions) do
        if dist(c, reg.center) < 300 * k then okc = false break end
      end
      if okc then
        local kind = "plain"
        if sea_margin(P, c) < 220 * k then kind = "coast" end
        for _, b in ipairs(P.barriers) do
          if b.kind == "range" and poly_dist(c, b.points) < 170 * k then kind = "highland" end
        end
        local roll2 = rng()
        local climate = roll2 < 0.3 and "desert" or (roll2 < 0.6 and "forest" or (roll2 < 0.75 and "lakes" or "temperate"))
        add_region(round(c), "frontier", kind, {climate = climate})
      end
    end
  end
  -- Massifs: short free-standing ranges through some frontier regions (highland character, local chokes).
  local massifs = 0
  for _, reg in ipairs(P.regions) do
    if massifs >= world.MASSIFS and reg.role == "frontier" and reg.climate ~= "lakes" then break end
    if reg.role == "frontier" and reg.climate ~= "lakes" and massifs < world.MASSIFS then
      local a = rng() * math.pi
      local t = V(math.cos(a), math.sin(a))
      local nrm = V(-t.y, t.x)
      local half_len = rr(100, 140) * k
      local c = reg.center
      local pts = {vadd(c, t, -half_len), vadd(c, nrm, rr(-30, 30) * k), vadd(c, t, half_len)}
      local w = floor(rr(16, 19) + 0.5)
      local ok = true
      for _, q in ipairs(P.protect) do
        if poly_dist(q, pts) < q.r + w + world.WARP + 30 then ok = false break end
      end
      for _, b in ipairs(P.barriers) do
        for _, pt in ipairs(pts) do
          if poly_dist(pt, b.points) < b.w + w + 2 * world.WARP + 70 then ok = false end
        end
        for _, pt in ipairs(b.points) do
          if poly_dist(pt, pts) < b.w + w + 2 * world.WARP + 70 then ok = false end
        end
      end
      for _, x in ipairs(P.crossings) do
        if poly_dist(x, pts) < x.r + w + world.WARP + 60 then ok = false end
      end
      for _, l in ipairs(P.lakes) do
        if poly_dist(l, pts) < l.r + w + world.WARP + 20 then ok = false end
      end
      for _, pt in ipairs(pts) do
        if edge_margin(P, pt) < 60 or sea_margin(P, pt) < 40 then ok = false end
      end
      if ok then
        massifs = massifs + 1
        reg.kind, reg.climate = "highland", "highland"
        P.barriers[#P.barriers + 1] = {id = #P.barriers + 1, kind = "range", massif = true, points = pts, w = w,
                                       ws = {w, w}, crossings = {}, proper = name()}
      end
    end
  end
  -- Climate anchors (deposit regions first, then fillers) and lakeland lakes.
  local function anchor(p, r, m, a, s)
    if #P.climate < world.SLOTS.climate then
      P.climate[#P.climate + 1] = {x = p.x, y = p.y, r = r, m = m, a = a, s = s}
    end
  end
  for _, d in ipairs(P.deposits) do
    -- swamps are centred a little off their deposit, so the pools (kept out of the deposit's protected disc) do not
    -- ring it evenly
    local a = rng() * TAU
    local off = V(d.x + math.cos(a) * d.r * 0.6, d.y + math.sin(a) * d.r * 0.6)
    if d.kind == "highland" then anchor(d, 150 * k, -0.08, 0.22, 0)
    elseif d.role == "center_oil" then anchor(off, 150 * k, 0.35, 0, 1.0)
    elseif d.role == "home_oil" then anchor(off, 95 * k, 0.25, 0, 0.8)
    else anchor(off, 135 * k, 0.35, 0, 1.0) end
  end
  for _, reg in ipairs(P.regions) do
    if reg.role == "frontier" then
      if reg.climate == "highland" then anchor(reg.center, 150 * k, -0.08, 0.22, 0)
      elseif reg.climate == "desert" then anchor(reg.center, 190 * k, -0.42, 0.12, 0)
      elseif reg.climate == "forest" then anchor(reg.center, 170 * k, 0.30, 0, 0)
      elseif reg.climate == "lakes" then
        anchor(reg.center, 150 * k, 0.12, 0, 0)
        for j = 1, 2 do
          if #P.lakes < world.SLOTS.lake then
            local p = round(vadd(reg.center, V(math.cos(j * 2.4 + rng()), math.sin(j * 2.4 + rng())), 55 * k))
            local r = floor(rr(11, 17))
            local okl = clear_of(P, p, r + 6, {edge = 60, sea = 30, discs = P.protect, gap = 12})
            if okl then P.lakes[#P.lakes + 1] = {x = p.x, y = p.y, r = r, why = "lakeland " .. reg.id} end
          end
        end
      end
    end
  end
  -- Slot budget.
  local nr, nv = 0, 0
  for _, b in ipairs(P.barriers) do
    if b.kind == "range" then nr = nr + #b.points - 1 else nv = nv + #b.points - 1 end
  end
  local npass, nford = 0, 0
  for _, c in ipairs(P.crossings) do
    if c.kind == "pass" then npass = npass + 1 else nford = nford + 1 end
  end
  if nr > world.SLOTS.range or nv > world.SLOTS.river or npass > world.SLOTS.pass or nford > world.SLOTS.ford
     or #P.protect > world.SLOTS.site or #P.lakes > world.SLOTS.lake then
    return nil, string.format("slot budget: ranges %d rivers %d passes %d fords %d sites %d lakes %d", nr, nv, npass,
      nford, #P.protect, #P.lakes)
  end
  P.home_discs = nil
  return P
end

-- Crossing discs follow the width of their segment: a pass leaves `open` tiles of ground across the range, a ford
-- reaches `open` tiles past the river's half width.
local function size_crossings(P)
  for _, c in ipairs(P.crossings) do
    local b = P.barriers[c.barrier]
    local w = (b.ws and b.ws[c.seg]) or b.w
    if c.kind == "pass" then
      c.r = floor(sqrt((w + 3) ^ 2 + (c.open / 2) ^ 2) + 0.5)
    else
      c.r = floor(w + c.open + 0.5)
    end
  end
end

---------------------------------------------------------------------------
-- MapGenSettings
---------------------------------------------------------------------------
local function fmt(v) return string.format("%.2f", v) end

--- property_expression_names constants of a skeleton.
local function constants(P)
  local c = {}
  local ir, iv = 0, 0
  for _, b in ipairs(P.barriers) do
    for j = 1, #b.points - 1 do
      local a, e = b.points[j], b.points[j + 1]
      local pre
      if b.kind == "range" then ir = ir + 1 pre = "rts_w_rg" .. ir .. "_" else iv = iv + 1 pre = "rts_w_rv" .. iv .. "_" end
      c[pre .. "ax"], c[pre .. "ay"], c[pre .. "bx"], c[pre .. "by"], c[pre .. "w"] = fmt(a.x), fmt(a.y), fmt(e.x), fmt(e.y),
        fmt((b.ws and b.ws[j]) or b.w)
    end
  end
  local ip, ifd = 0, 0
  for _, x in ipairs(P.crossings) do
    local pre
    if x.kind == "pass" then ip = ip + 1 pre = "rts_w_ps" .. ip .. "_" else ifd = ifd + 1 pre = "rts_w_fd" .. ifd .. "_" end
    c[pre .. "x"], c[pre .. "y"], c[pre .. "r"] = fmt(x.x), fmt(x.y), fmt(x.r)
  end
  for i, s in ipairs(P.protect) do
    c["rts_w_st" .. i .. "_x"], c["rts_w_st" .. i .. "_y"], c["rts_w_st" .. i .. "_r"] = fmt(s.x), fmt(s.y), fmt(s.r)
  end
  for i, l in ipairs(P.lakes) do
    c["rts_w_lk" .. i .. "_x"], c["rts_w_lk" .. i .. "_y"], c["rts_w_lk" .. i .. "_r"] = fmt(l.x), fmt(l.y), fmt(l.r)
  end
  for i, a in ipairs(P.climate) do
    local pre = "rts_w_cl" .. i .. "_"
    c[pre .. "x"], c[pre .. "y"], c[pre .. "r"] = fmt(a.x), fmt(a.y), fmt(a.r)
    c[pre .. "m"], c[pre .. "a"], c[pre .. "s"] = fmt(a.m), fmt(a.a), fmt(a.s)
  end
  for e, d in pairs(P.sea) do c["rts_w_sea_" .. e] = fmt(d) end
  c.rts_w_half = fmt(P.half)
  c.rts_w_warp = fmt(world.WARP)
  return c
end
world.constants = constants

local ORE_CONTROLS = {"iron-ore", "copper-ore", "stone", "coal", "uranium-ore", "crude-oil", "enemy-base"}

--- The world's MapGenSettings: Nauvis' tiles, trees, rocks and decoratives, no ore and no enemies, our elevation,
--- moisture, aux and cliffs, the skeleton constants, and the three world tiles.
function world.map_gen_settings(P)
  local mgs
  local nauvis = game.surfaces.nauvis
  if nauvis then mgs = nauvis.map_gen_settings end
  mgs = mgs or {}
  mgs.seed = P.seed % 4294967296
  mgs.width, mgs.height = P.size, P.size
  local starts = {}
  for _, sp in ipairs(P.spawns) do starts[#starts + 1] = {x = sp.x, y = sp.y} end
  mgs.starting_points = starts
  mgs.no_enemies_mode, mgs.peaceful_mode = true, true
  mgs.autoplace_controls = mgs.autoplace_controls or {}
  for _, name in ipairs(ORE_CONTROLS) do
    if prototypes.autoplace_control[name] then mgs.autoplace_controls[name] = {frequency = 1, size = 0, richness = 1} end
  end
  local pen = {elevation = "rts_w_elevation", moisture = "rts_w_moisture", aux = "rts_w_aux",
               cliff_elevation = "rts_w_cliff_elevation", cliffiness = "rts_w_cliffiness"}
  for k, v in pairs(constants(P)) do pen[k] = v end
  mgs.property_expression_names = pen
  mgs.autoplace_settings = mgs.autoplace_settings or {}
  local ts = mgs.autoplace_settings.tile or {settings = {}}
  ts.settings = ts.settings or {}
  for _, t in ipairs({"rts-mountain", "rts-ford", "rts-marsh"}) do ts.settings[t] = {} end
  mgs.autoplace_settings.tile = ts
  mgs.cliff_settings = {name = "cliff", control = prototypes.autoplace_control["nauvis_cliff"] and "nauvis_cliff" or nil,
                        cliff_elevation_0 = 20, cliff_elevation_interval = 40, richness = 1, cliff_smoothing = 0}
  return mgs
end

---------------------------------------------------------------------------
-- Sampling and validation (8-tile grid)
---------------------------------------------------------------------------
local LAND, WATER, MOUNTAIN, FORD, MARSH = 0, 1, 2, 3, 4
world.CLASS = {[LAND] = "land", [WATER] = "water", [MOUNTAIN] = "mountain", [FORD] = "ford", [MARSH] = "marsh"}
local SAMPLE_PROPS = {"rts_w_elevation", "rts_w_mountain", "rts_w_ford", "rts_w_marsh"}

local sampler_surface -- below

-- Real thickness of every barrier: stations every THICK_STEP tiles along its polyline (not at its free ends, its
-- crossings, the map edge or the sea), moved from warped to plain coordinates, then three transects (the normal and
-- +-20 degrees) of sampled tiles; the station's thickness is the shortest blocked run through it. Returns the
-- stations {b, seg, s, th}.
world.THICK_STEP = 24
local function measure_thickness(P, surface)
  local st = {}
  for _, b in ipairs(P.barriers) do
    local pts = b.points
    local total = poly_length(pts)
    local s = 30
    while s <= total - 30 do
      local p = poly_at(pts, s)
      if edge_margin(P, p) > 24 and sea_margin(P, p) > 40 then
        local near = false
        for _, cid in ipairs(b.crossings) do
          local c = P.crossings[cid]
          if abs(c.along - s) < c.r + 16 then near = true end
        end
        if not near then
          local j = poly_index(pts, s)
          st[#st + 1] = {b = b, seg = j, s = s, p = p, t = norm(V(pts[j + 1].x - pts[j].x, pts[j + 1].y - pts[j].y))}
        end
      end
      s = s + world.THICK_STEP
    end
  end
  if #st == 0 then return st end
  local pos = {}
  for i, x in ipairs(st) do pos[i] = x.p end
  local r1 = surface.calculate_tile_properties({"rts_w_dx", "rts_w_dy"}, pos)
  local pos2 = {}
  for i, x in ipairs(st) do pos2[i] = {x = x.p.x - r1.rts_w_dx[i], y = x.p.y - r1.rts_w_dy[i]} end
  local r2 = surface.calculate_tile_properties({"rts_w_dx", "rts_w_dy"}, pos2)
  local ANG, U = {-0.35, 0, 0.35}, 55
  local all = {}
  for i, x in ipairs(st) do
    x.real = V(x.p.x - r2.rts_w_dx[i], x.p.y - r2.rts_w_dy[i])
    local n = V(-x.t.y, x.t.x)
    for a = 1, 3 do
      local d = rot(n, ANG[a])
      for u = -U, U do all[#all + 1] = {x = x.real.x + d.x * u, y = x.real.y + d.y * u} end
    end
  end
  local mtn, elev, ford = {}, {}, {}
  local i0 = 1
  while i0 <= #all do
    local batch = {}
    for k = i0, min(#all, i0 + 8191) do batch[#batch + 1] = all[k] end
    local res = surface.calculate_tile_properties({"rts_w_mountain", "rts_w_elevation", "rts_w_ford"}, batch)
    for k = 1, #batch do
      mtn[i0 + k - 1], elev[i0 + k - 1], ford[i0 + k - 1] = res.rts_w_mountain[k], res.rts_w_elevation[k], res.rts_w_ford[k]
    end
    i0 = i0 + #batch
  end
  local per = 2 * U + 1
  for i, x in ipairs(st) do
    local range = x.b.kind == "range"
    local best = math.huge
    for a = 1, 3 do
      local base = ((i - 1) * 3 + (a - 1)) * per
      local function blocked(u)
        local k = base + u + U + 1
        if range then return mtn[k] > 0 end
        return elev[k] < -0.05 and ford[k] <= 0
      end
      local c
      for off = 0, 20 do
        if blocked(off) then c = off break end
        if blocked(-off) then c = -off break end
      end
      local run = 0
      if c then
        local lo, hi = c, c
        while lo > -U and blocked(lo - 1) do lo = lo - 1 end
        while hi < U and blocked(hi + 1) do hi = hi + 1 end
        run = hi - lo + 1
      end
      best = min(best, run)
    end
    x.th = best
  end
  return st
end

-- Widen every segment that has a station thinner than MIN_THICK and re-measure, at most 3 rounds. Records
-- b.min_thick. Returns the stations still thin.
local function thicken(P)
  local thin = {}
  for round = 1, 3 do
    size_crossings(P)
    local surface = sampler_surface(world.map_gen_settings(P))
    local st = measure_thickness(P, surface)
    for _, b in ipairs(P.barriers) do b.min_thick = nil end
    thin = {}
    local bump = {}
    for _, x in ipairs(st) do
      local b = x.b
      b.min_thick = min(b.min_thick or math.huge, x.th)
      if x.th < world.MIN_THICK then
        thin[#thin + 1] = x
        local key = b.id .. ":" .. x.seg
        bump[key] = max(bump[key] or 0, math.ceil((world.MIN_THICK - x.th) / 2) + 2)
      end
    end
    P.thicken_rounds = round
    if #thin == 0 then break end
    if round < 3 then
      for key, add in pairs(bump) do
        local bid, seg = string.match(key, "^(%d+):(%d+)$")
        local b = P.barriers[tonumber(bid)]
        b.ws[tonumber(seg)] = min(34, b.ws[tonumber(seg)] + add)
      end
    end
  end
  size_crossings(P)
  return thin
end

sampler_surface = function(mgs)
  local s = game.surfaces[world.SAMPLER]
  if not s then
    s = game.create_surface(world.SAMPLER, mgs)
  else
    s.map_gen_settings = mgs
  end
  return s
end

--- Classify the grid from engine samples: {n, cell, half, cls = {[k] = class}}. k = j * n + i + 1 (0-based i, j).
local function sample_grid(surface, P)
  local cell = world.CELL
  local n = P.size / cell
  local H = P.half
  local cls = {}
  local batch, keys = {}, {}
  local function flush()
    if #batch == 0 then return end
    local res = surface.calculate_tile_properties(SAMPLE_PROPS, batch)
    local e, m, f, mr = res.rts_w_elevation, res.rts_w_mountain, res.rts_w_ford, res.rts_w_marsh
    for b = 1, #batch do
      local c
      if f[b] > 0 then c = FORD
      elseif m[b] > 0 then c = MOUNTAIN
      elseif mr[b] > 0 then c = MARSH
      elseif e[b] < -0.05 then c = WATER
      else c = LAND end
      cls[keys[b]] = c
    end
    batch, keys = {}, {}
  end
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      batch[#batch + 1] = {x = -H + i * cell + cell / 2, y = -H + j * cell + cell / 2}
      keys[#keys + 1] = j * n + i + 1
      if #batch >= 8192 then flush() end
    end
  end
  flush()
  return {n = n, cell = cell, half = H, cls = cls}
end

local function cell_of(G, p)
  local i = floor((p.x + G.half) / G.cell)
  local j = floor((p.y + G.half) / G.cell)
  if i < 0 or j < 0 or i >= G.n or j >= G.n then return nil end
  return j * G.n + i + 1, i, j
end
local function cell_center(G, k)
  local i = (k - 1) % G.n
  local j = (k - 1 - i) / G.n
  return V(-G.half + i * G.cell + G.cell / 2, -G.half + j * G.cell + G.cell / 2)
end
local function passable(c) return c ~= WATER and c ~= MOUNTAIN end

--- 4-connected BFS over passable cells: dist[k] = steps + 1 (nil = unreachable).
local function bfs(G, start)
  local n, cls = G.n, G.cls
  local d = {}
  if not start or not passable(cls[start]) then return d end
  local q, head, tail = {start}, 1, 1
  d[start] = 1
  while head <= tail do
    local k = q[head]
    head = head + 1
    local nd = d[k] + 1
    local i = (k - 1) % n
    local nb
    if i > 0 then nb = k - 1 if not d[nb] and passable(cls[nb]) then d[nb] = nd tail = tail + 1 q[tail] = nb end end
    if i < n - 1 then nb = k + 1 if not d[nb] and passable(cls[nb]) then d[nb] = nd tail = tail + 1 q[tail] = nb end end
    if k > n then nb = k - n if not d[nb] and passable(cls[nb]) then d[nb] = nd tail = tail + 1 q[tail] = nb end end
    if k <= n * (n - 1) then nb = k + n if not d[nb] and passable(cls[nb]) then d[nb] = nd tail = tail + 1 q[tail] = nb end end
  end
  return d, tail
end

-- BFS distance in tiles from a spawn's distance field to a position (nil = unreachable). Looks at the nearest
-- passable cell within 2 cells (a deposit centre may sit on a patch next to a pond).
local function path_tiles(G, d, p)
  local k, i, j = cell_of(G, p)
  if not k then return nil end
  local best
  for dj = -2, 2 do
    for di = -2, 2 do
      local ii, jj = i + di, j + dj
      if ii >= 0 and jj >= 0 and ii < G.n and jj < G.n then
        local v = d[jj * G.n + ii + 1]
        if v and (not best or v < best) then best = v end
      end
    end
  end
  return best and best * G.cell or nil
end

local function buildable_box(G, p, half_tiles)
  local r = math.ceil(half_tiles / G.cell)
  local _, i, j = cell_of(G, p)
  if not i then return false end
  for dj = -r, r do
    for di = -r, r do
      local ii, jj = i + di, j + dj
      if ii < 0 or jj < 0 or ii >= G.n or jj >= G.n or G.cls[jj * G.n + ii + 1] ~= LAND then return false end
    end
  end
  return true
end

-- Per-spawn score (study 5.1): buildable land within KIT_RADIUS (0.35), water within 200 (0.15), defensibility from
-- the land runs on the ring at 300 (0.20), expansion value (0.30): every deposit's value shared by inverse square
-- path distance and divided by max(1, distance / 500), normalised by the best nation.
local function score_spawns(P, G, dists)
  local scores = {}
  local cell = G.cell
  for si, sp in ipairs(P.spawns) do
    local land, total, water = 0, 0, 0
    local r1 = math.ceil(200 / cell)
    local _, ci, cj = cell_of(G, sp)
    for dj = -r1, r1 do
      for di = -r1, r1 do
        local ii, jj = ci + di, cj + dj
        if ii >= 0 and jj >= 0 and ii < G.n and jj < G.n then
          local dd = sqrt(di * di + dj * dj) * cell
          local c = G.cls[jj * G.n + ii + 1]
          if dd <= world.KIT_RADIUS then
            total = total + 1
            if c == LAND then land = land + 1 end
          end
          if dd <= 200 and c == WATER then water = 1 end
        end
      end
    end
    -- ring at 300: runs of passable samples
    local samples, runs, open = 314, 0, 0
    local prev, first
    for s = 0, samples - 1 do
      local a = TAU * s / samples
      local k = cell_of(G, V(sp.x + 300 * math.cos(a), sp.y + 300 * math.sin(a)))
      local pass = k and passable(G.cls[k]) or false
      if pass then open = open + 1 end
      if s == 0 then first = pass end
      if pass and prev == false then runs = runs + 1 end
      prev = pass
    end
    if first and prev == false then runs = runs + 1 end
    local def
    if open == samples then def = 0.7
    elseif runs <= 1 then def = 0.6
    elseif runs <= 3 then def = 1.0
    elseif runs == 4 then def = 0.85
    else def = 0.7 end
    scores[si] = {land = total > 0 and land / total or 0, water = water, def = def, runs = runs, exp = 0}
  end
  for _, d in ipairs(P.deposits) do
    local value = 0
    for _, p in ipairs(d.patches or {}) do value = value + p.total * (world.VALUE[p.name] or 0.5) end
    value = value + #(d.wells or {}) * world.VALUE.well
    d.value = value
    local inv, ds = 0, {}
    for si in ipairs(P.spawns) do
      local t = path_tiles(G, dists[si], d)
      ds[si] = t
      if t then inv = inv + 1 / (t * t) end
    end
    if inv > 0 then
      for si in ipairs(P.spawns) do
        local t = ds[si]
        if t then scores[si].exp = scores[si].exp + value * (1 / (t * t)) / inv / max(1, t / 500) end
      end
    end
  end
  local best_exp = 0
  for _, s in ipairs(scores) do best_exp = max(best_exp, s.exp) end
  local hi, lo = -math.huge, math.huge
  for _, s in ipairs(scores) do
    s.exp_n = best_exp > 0 and s.exp / best_exp or 1
    s.total = 0.35 * s.land + 0.15 * s.water + 0.20 * s.def + 0.30 * s.exp_n
    hi, lo = max(hi, s.total), min(lo, s.total)
  end
  return scores, hi > 0 and (hi - lo) / hi or 0
end

-- Validate one skeleton on its samples. Returns a report {ok, reasons, conn, kit, spread, scores, ...}.
local function validate(P, G)
  local R = {reasons = {}}
  local dists = {}
  for si, sp in ipairs(P.spawns) do dists[si] = bfs(G, cell_of(G, sp)) end
  -- connectivity from the first spawn: every spawn, every deposit (contested ones included), every region centre
  -- on land
  local d1 = dists[1]
  local targets, bad = 0, {}
  local function target(label, p, must)
    local k = cell_of(G, p)
    if not k then return end
    if not must and not passable(G.cls[k]) then return end -- a filler region centre in the sea is dropped later
    targets = targets + 1
    if not path_tiles(G, d1, p) then bad[#bad + 1] = label end
  end
  for _, sp in ipairs(P.spawns) do target("spawn " .. sp.force, sp, true) end
  for _, d in ipairs(P.deposits) do target("deposit " .. d.id .. " " .. d.role, d, true) end
  for _, reg in ipairs(P.regions) do target("region " .. reg.id, reg.center, false) end
  R.conn_targets, R.conn_bad = targets, bad
  if #bad > 0 then R.reasons[#R.reasons + 1] = "unreachable: " .. table.concat(bad, ", ") end
  -- start kits on clean land within KIT_RADIUS
  local kit_bad = {}
  for _, sp in ipairs(P.spawns) do
    for _, p in ipairs(sp.kit) do
      local half = max(p.w, p.h) / 2
      if dist(p.center, sp) + half > world.KIT_RADIUS or not buildable_box(G, p.center, half) then
        kit_bad[#kit_bad + 1] = sp.force .. " " .. p.kind .. " " .. p.name
      end
    end
    if not buildable_box(G, sp, 40) then kit_bad[#kit_bad + 1] = sp.force .. " base" end
  end
  R.kit_bad = kit_bad
  if #kit_bad > 0 then R.reasons[#R.reasons + 1] = "start kit: " .. table.concat(kit_bad, ", ") end
  -- deposits on land
  local dep_bad = {}
  for _, d in ipairs(P.deposits) do
    for _, p in ipairs(d.patches or {}) do
      if not buildable_box(G, p.center, max(p.w, p.h) / 2 - 2) then dep_bad[#dep_bad + 1] = d.id .. " " .. p.name end
    end
  end
  if #dep_bad > 0 then R.reasons[#R.reasons + 1] = "deposits off land: " .. table.concat(dep_bad, ", ") end
  R.scores, R.spread = score_spawns(P, G, dists)
  if R.spread > world.SPREAD_MAX then R.reasons[#R.reasons + 1] = string.format("spawn score spread %.3f", R.spread) end
  -- nearest-enemy path spread (study: 12 %; informational)
  local near = {}
  for si, sp in ipairs(P.spawns) do
    local best
    for sj, sq in ipairs(P.spawns) do
      if sj ~= si then
        local t = path_tiles(G, dists[si], sq)
        if t and (not best or t < best) then best = t end
      end
    end
    near[si] = best or 0
  end
  local nhi, nlo = 0, math.huge
  for _, v in ipairs(near) do nhi, nlo = max(nhi, v), min(nlo, v) end
  R.nearest_enemy, R.enemy_spread = near, nhi > 0 and (nhi - nlo) / nhi or 0
  R.ok = #R.reasons == 0
  R.dists = dists
  return R
end

---------------------------------------------------------------------------
-- Sites, regions, chokes (after the skeleton is accepted)
---------------------------------------------------------------------------
local function nearest_spawn_dist(P, p)
  local best = math.huge
  for _, sp in ipairs(P.spawns) do best = min(best, dist(p, sp)) end
  return best
end

local function plan_sites(P, G, R)
  local k = P.size / 2048
  local d1 = R.dists[1]
  local rng = new_rng(P.seed, 1000 + P.attempt, P.nations)
  local sites = {}
  local function reachable(p) return path_tiles(G, d1, p) ~= nil end
  local function far_from(p, list, r)
    for _, s in ipairs(list) do
      if dist(p, s.position) < r then return false end
    end
    return true
  end
  local function off_deposits(p, margin)
    for _, d in ipairs(P.deposits) do
      if dist(p, d) < d.r + margin then return false end
    end
    for _, sp in ipairs(P.spawns) do
      for _, kp in ipairs(sp.kit) do
        if dist(p, kp.center) < 20 + margin then return false end
      end
    end
    return true
  end
  -- candidates: every 4th cell
  local cands = {}
  for j = 2, G.n - 3, 4 do
    for i = 2, G.n - 3, 4 do
      local p = cell_center(G, j * G.n + i + 1)
      if G.cls[j * G.n + i + 1] == LAND then cands[#cands + 1] = p end
    end
  end
  -- city sites: one next to every non-start deposit first, then the best open land
  local city = {}
  for _, d in ipairs(P.deposits) do
    local best, best_s
    for _, p in ipairs(cands) do
      local dd = dist(p, d)
      if dd > d.r + 24 and dd < d.r + 110 and nearest_spawn_dist(P, p) > 230 * k and buildable_box(G, p, 20)
         and off_deposits(p, 14) and far_from(p, city, 96) and reachable(p) then
        local s = dd + 0.25 * nearest_spawn_dist(P, p)
        if not best_s or s < best_s then best, best_s = p, s end
      end
    end
    if best then city[#city + 1] = {kind = "city_site", position = round(best), deposit = d.id, score = 3} end
  end
  local target = P.size >= 3072 and 48 or (P.size >= 2048 and 32 or 22)
  local scored = {}
  for _, p in ipairs(cands) do
    if nearest_spawn_dist(P, p) > 230 * k and buildable_box(G, p, 20) and off_deposits(p, 14) and reachable(p) then
      local s = 0
      for _, d in ipairs(P.deposits) do
        if dist(p, d) < d.r + 140 then s = s + 1 end
      end
      local _, ci, cj = cell_of(G, p)
      local water, open, tot = 0, 0, 0
      for dj = -12, 12, 2 do
        for di = -12, 12, 2 do
          local ii, jj = ci + di, cj + dj
          if ii >= 0 and jj >= 0 and ii < G.n and jj < G.n then
            local c = G.cls[jj * G.n + ii + 1]
            tot = tot + 1
            if c == LAND then open = open + 1 end
            if c == WATER then water = 1 end
          end
        end
      end
      scored[#scored + 1] = {p = p, s = s + 0.5 * water + open / max(1, tot) + 0.1 * rng()}
    end
  end
  table.sort(scored, function(a, b) return a.s > b.s end)
  for _, c in ipairs(scored) do
    if #city >= target then break end
    if far_from(c.p, city, 96) then city[#city + 1] = {kind = "city_site", position = round(c.p), score = c.s} end
  end
  for _, s in ipairs(city) do sites[#sites + 1] = s end
  -- ruins: low-value land far from every spawn
  local ruins = {}
  local rtarget = P.size >= 3072 and 14 or (P.size >= 2048 and 10 or 6)
  shuffle(rng, cands)
  local rscored = {}
  for _, p in ipairs(cands) do
    local ds = nearest_spawn_dist(P, p)
    if ds > 320 * k and buildable_box(G, p, 12) and off_deposits(p, 60) and reachable(p) then
      rscored[#rscored + 1] = {p = p, s = ds + 200 * rng()}
    end
  end
  table.sort(rscored, function(a, b) return a.s > b.s end)
  for _, c in ipairs(rscored) do
    if #ruins >= rtarget then break end
    if far_from(c.p, ruins, 220 * k) and far_from(c.p, city, 40) then
      ruins[#ruins + 1] = {kind = "ruin", position = round(c.p)}
    end
  end
  for _, s in ipairs(ruins) do sites[#sites + 1] = s end
  -- ports: on the coast (land next to the sea) or at the map edge, far from the spawns, spread out
  local ports = {}
  local ptarget = (P.nations <= 2 and P.size < 3072) and 2 or min(4, max(3, P.nations))
  local pc = {}
  local has_sea = next(P.sea) ~= nil
  for _, p in ipairs(cands) do
    local coastal
    if has_sea then
      local m = sea_margin(P, p)
      if m < 120 then
        local _, ci, cj = cell_of(G, p)
        for dj = -5, 5 do
          for di = -5, 5 do
            local ii, jj = ci + di, cj + dj
            if ii >= 0 and jj >= 0 and ii < G.n and jj < G.n and G.cls[jj * G.n + ii + 1] == WATER then coastal = true end
          end
        end
      end
    else
      coastal = edge_margin(P, p) < 70 and edge_margin(P, p) > 30
    end
    if coastal and buildable_box(G, p, 12) and off_deposits(p, 40) and reachable(p) and nearest_spawn_dist(P, p) > 300 * k then
      pc[#pc + 1] = p
    end
  end
  for _ = 1, ptarget do
    local best, best_s
    for _, p in ipairs(pc) do
      if far_from(p, ports, 500 * k) and far_from(p, ruins, 80) then
        local s = nearest_spawn_dist(P, p)
        for _, q in ipairs(ports) do s = s + 0.5 * dist(p, q.position) end
        if not best_s or s > best_s then best, best_s = p, s end
      end
    end
    if best then ports[#ports + 1] = {kind = "port", position = round(best)} end
  end
  for _, s in ipairs(ports) do sites[#sites + 1] = s end
  -- oil fields (m1-economy: the AI looks for kind "oil"): one site per planned field, at its centre
  for _, d in ipairs(P.deposits) do
    if d.wells and #d.wells > 0 then
      local amount = 0
      for _, w in ipairs(d.wells) do amount = amount + w.amount end
      sites[#sites + 1] = {kind = "oil", position = V(d.x, d.y), deposit = d.id, role = d.role, force = d.force,
                           wells = #d.wells, amount = amount}
    end
  end
  return sites
end

-- Region grid: 32-tile Voronoi cells over the region centres. Drops filler centres in water or mountains.
local function finish_regions(P, G)
  local keep = {}
  for _, reg in ipairs(P.regions) do
    local k = cell_of(G, reg.center)
    if reg.role ~= "frontier" or (k and passable(G.cls[k])) then keep[#keep + 1] = reg end
  end
  for i, reg in ipairs(keep) do
    reg.id = i
    reg.name, reg.label = region_name(reg.kind, reg.noun, reg.proper)
  end
  P.regions = keep
  local gn = P.size / 32
  local grid = {}
  for j = 0, gn - 1 do
    for i = 0, gn - 1 do
      local p = V(-P.half + i * 32 + 16, -P.half + j * 32 + 16)
      local best, bd = 1, math.huge
      for _, reg in ipairs(keep) do
        local dd = (p.x - reg.center.x) ^ 2 + (p.y - reg.center.y) ^ 2
        if dd < bd then best, bd = reg.id, dd end
      end
      grid[j * gn + i + 1] = best
    end
  end
  P.region_grid, P.region_grid_n = grid, gn
  local function region_id(p)
    local i = max(0, min(gn - 1, floor((p.x + P.half) / 32)))
    local j = max(0, min(gn - 1, floor((p.y + P.half) / 32)))
    return grid[j * gn + i + 1]
  end
  -- resources per region
  for _, d in ipairs(P.deposits) do
    local reg = keep[region_id(d)]
    d.region = reg.id
    for _, p in ipairs(d.patches or {}) do reg.resources[p.name] = (reg.resources[p.name] or 0) + p.total end
    for _, w in ipairs(d.wells or {}) do reg.resources["crude-oil"] = (reg.resources["crude-oil"] or 0) + w.amount end
  end
  for _, sp in ipairs(P.spawns) do
    local reg = keep[region_id(sp)]
    for _, p in ipairs(sp.kit) do reg.resources[p.name] = (reg.resources[p.name] or 0) + p.total end
  end
  for _, s in ipairs(P.sites) do s.region = region_id(s.position) end
end

-- Chokes: planned crossings, moved from warped to plain coordinates (one fixed-point step on the sampled warp).
local function plan_chokes(P, surface)
  local pts = {}
  for _, c in ipairs(P.crossings) do pts[#pts + 1] = {x = c.x, y = c.y} end
  if #pts == 0 then return end
  local res = surface.calculate_tile_properties({"rts_w_dx", "rts_w_dy"}, pts)
  local p1 = {}
  for i, c in ipairs(P.crossings) do p1[i] = {x = c.x - res.rts_w_dx[i], y = c.y - res.rts_w_dy[i]} end
  local res2 = surface.calculate_tile_properties({"rts_w_dx", "rts_w_dy"}, p1)
  for i, c in ipairs(P.crossings) do
    local p = round(V(c.x - res2.rts_w_dx[i], c.y - res2.rts_w_dy[i]))
    local b = P.barriers[c.barrier]
    local w = (b.ws and b.ws[c.seg]) or b.w
    c.position = p
    local width = c.kind == "pass" and 2 * sqrt(max(0, c.r * c.r - (w + 3) ^ 2)) or 2 * sqrt(max(0, c.r * c.r - (w + 1.5) ^ 2))
    local nm = {"rts-world." .. c.kind .. "-name", {"rts-world.proper-" .. c.proper}}
    P.chokes[#P.chokes + 1] = {kind = c.kind, position = p, width = floor(width + 0.5), name = nm,
                               label = (c.kind == "pass" and "Gate of " or "Ford of ") .. world.PROPER[c.proper],
                               barrier = c.barrier, crossing = c.id, r = c.r}
  end
end

---------------------------------------------------------------------------
-- world.plan
---------------------------------------------------------------------------
local function plan_config(config)
  local c = config or {}
  local nations = (tonumber(c.opponents) or 1) + 1
  if c.nations then nations = c.nations end
  nations = max(2, min(4, nations))
  local forces = {util.PLAYER_FORCE}
  for i = 1, nations - 1 do forces[#forces + 1] = "rts-ai-" .. i end
  return {nations = nations, size = world.normalize_size(c.world_size, nations), forces = forces}
end

--- Plan a world for a match config (opponents, world_size) and a seed: the skeleton is re-rolled until it passes
--- validation on engine samples (or the best of world.ATTEMPTS is kept), then sites, regions and chokes.
--- Uses the sampler surface (never generated). Returns the plan.
function world.plan(config, seed)
  local cfg = plan_config(config)
  local prof = helpers.create_profiler()
  local okp, msg = world.check_prototypes()
  assert(okp, "world: prototypes/world.lua and world.SLOTS disagree: " .. msg)
  local best, bestR, bestG
  local tried = {}
  for attempt = 1, world.ATTEMPTS do
    local P, why = skeleton(cfg, seed, attempt)
    if not P then
      tried[#tried + 1] = string.format("#%d skeleton: %s", attempt, why)
    else
      local thin = thicken(P)
      local surface = sampler_surface(world.map_gen_settings(P))
      local G = sample_grid(surface, P)
      local R = validate(P, G)
      if #thin > 0 then
        local m = math.huge
        for _, x in ipairs(thin) do m = min(m, x.th) end
        R.ok = false
        R.reasons[#R.reasons + 1] = string.format("%d barrier stations thinner than %d (thinnest %d)", #thin, world.MIN_THICK, m)
      end
      tried[#tried + 1] = string.format("#%d %s (spread %.3f)", attempt, R.ok and "ok" or table.concat(R.reasons, "; "),
        R.spread)
      local better = not best or (R.ok and not bestR.ok) or (R.ok == bestR.ok and #R.conn_bad <= #bestR.conn_bad
        and R.spread < bestR.spread)
      if better then best, bestR, bestG = P, R, G end
      if R.ok then break end
    end
  end
  assert(best, "world: no skeleton could be planned: " .. table.concat(tried, " | "))
  local P, R, G = best, bestR, bestG
  local surface = sampler_surface(world.map_gen_settings(P))
  P.sites = plan_sites(P, G, R)
  finish_regions(P, G)
  plan_chokes(P, surface)
  if world.write_images then world.write_image({plan = P, surface = "plan", seed = P.seed}, G) end
  -- counts of the sampled terrain
  local counts = {land = 0, water = 0, mountain = 0, ford = 0, marsh = 0}
  for _, c in pairs(G.cls) do counts[world.CLASS[c]] = counts[world.CLASS[c]] + 1 end
  local spawn_scores = {}
  for si, s in ipairs(R.scores) do
    spawn_scores[si] = {force = P.spawns[si].force, total = s.total, land = s.land, water = s.water, def = s.def,
                        runs = s.runs, exp = s.exp_n, nearest_enemy = R.nearest_enemy[si]}
  end
  P.validation = {ok = R.ok, reasons = R.reasons, attempts = #tried, tried = tried, conn_targets = R.conn_targets,
                  conn_bad = R.conn_bad, kit_bad = R.kit_bad, spread = R.spread, enemy_spread = R.enemy_spread,
                  scores = spawn_scores, cells = counts}
  local thick = {}
  for _, b in ipairs(P.barriers) do
    thick[#thick + 1] = string.format("%s%d w%s min %s", b.kind, b.id, table.concat(b.ws or {b.w}, "/"),
      b.min_thick and tostring(b.min_thick) or "-")
  end
  P.validation.thickness = thick
  prof.stop()
  log({"", string.format("[rts] world: planned %dx%d for %d nations, seed %d: barriers [%s] (thicken rounds %s); "
    .. "attempt %d of %d [%s]; spread %.3f, "
    .. "nearest-enemy path spread %.3f; %d/%d targets reachable; sampled cells %s; %d barriers, %d crossings, %d deposits, "
    .. "%d regions, %d sites; planned in ", P.size, P.size, P.nations, P.seed, table.concat(thick, ", "),
    tostring(P.thicken_rounds), P.attempt, #tried,
    table.concat(tried, " | "), R.spread, R.enemy_spread, R.conn_targets - #R.conn_bad, R.conn_targets,
    serpent.line(counts), #P.barriers, #P.crossings, #P.deposits, #P.regions, #P.sites), prof})
  return P
end

---------------------------------------------------------------------------
-- world.apply: generation and placement
---------------------------------------------------------------------------
local function chunk_key(cx, cy) return (cx + 1024) * 2048 + (cy + 1024) end

-- Features: patches, oil fields, ruins, ports. Each knows its tile box; it is placed once all its chunks exist.
local function build_features(P)
  local list = {}
  local function add(f)
    f.box = f.box or {x0 = f.x - f.half, y0 = f.y - f.half, x1 = f.x + f.half, y1 = f.y + f.half}
    list[#list + 1] = f
  end
  for _, sp in ipairs(P.spawns) do
    for _, p in ipairs(sp.kit) do
      add({type = "patch", kind = p.kind, force = p.force, name = p.name, x = p.center.x, y = p.center.y, w = p.w,
           h = p.h, total = p.total, half = max(p.w, p.h) / 2 + 3})
    end
  end
  for _, d in ipairs(P.deposits) do
    for _, p in ipairs(d.patches or {}) do
      add({type = "patch", kind = "region", deposit = d.id, name = p.name, x = p.center.x, y = p.center.y, w = p.w,
           h = p.h, total = p.total, half = max(p.w, p.h) / 2 + 3})
    end
    if d.wells and #d.wells > 0 then
      add({type = "oil", deposit = d.id, x = d.x, y = d.y, half = d.r, wells = d.wells})
    end
  end
  for _, s in ipairs(P.sites) do
    if s.kind == "ruin" or s.kind == "port" then
      add({type = s.kind, x = s.position.x, y = s.position.y, half = 12, region = s.region})
    end
  end
  return list
end

local CLEAR_TYPES = {"tree", "simple-entity", "cliff", "fish"}

local function clear_box(surface, x0, y0, x1, y1)
  local n = 0
  for _, e in pairs(surface.find_entities_filtered({area = {{x0, y0}, {x1, y1}}, type = CLEAR_TYPES})) do
    if e.valid then e.destroy() n = n + 1 end
  end
  return n
end

local function place_feature(surface, W, f)
  if f.placed then return end
  f.placed = true
  local b = f.box
  f.cleared = clear_box(surface, b.x0 - 1, b.y0 - 1, b.x1 + 1, b.y1 + 1)
  if f.type == "patch" then
    local n, amount = mapgen.place_patch(surface, f.name, {x = f.x, y = f.y}, f.w, f.h, f.total, {land_only = true})
    f.tiles, f.amount = n, amount
    local box = {x0 = floor(f.x - f.w / 2 + 0.5), y0 = floor(f.y - f.h / 2 + 0.5)}
    box.x1, box.y1 = box.x0 + f.w, box.y0 + f.h
    mapgen.record_patch({id = string.format("%s-%s-%s@%d,%d", f.kind, f.force or "all", f.name, f.x, f.y),
                         kind = f.kind, force = f.force, name = f.name, center = {x = f.x, y = f.y}, box = box,
                         total = amount, tiles = n, remaining = amount})
  elseif f.type == "oil" then
    local n, amount = 0, 0
    for _, w in ipairs(f.wells) do
      local pos
      for _, off in ipairs({{0, 0}, {3, 0}, {-3, 0}, {0, 3}, {0, -3}, {4, 4}, {-4, -4}, {4, -4}, {-4, 4}}) do
        local p = {x = w.x + off[1], y = w.y + off[2]}
        local ok = true
        for dx = -1, 1 do
          for dy = -1, 1 do
            if surface.get_tile(p.x + dx, p.y + dy).collides_with("resource") then ok = false end
          end
        end
        if ok and surface.count_entities_filtered({position = p, radius = 3, type = "resource"}) == 0 then pos = p break end
      end
      if pos and surface.create_entity({name = "crude-oil", position = pos, amount = w.amount}) then
        n, amount = n + 1, amount + w.amount
      end
    end
    f.wells_placed, f.amount = n, amount
    W.oil[#W.oil + 1] = {deposit = f.deposit, position = {x = f.x, y = f.y}, wells = n, amount = amount}
  elseif f.type == "ruin" or f.type == "port" then
    local stock = f.type == "port" and world.PORT_STOCK or world.RUIN_STOCK
    local keys = f.type == "port" and {label = "rts-world.port-label", owned = "rts-world.port-owned",
                                       capturing = "rts-world.port-capturing"} or nil
    local r = mapgen.add_ruin(surface, {x = f.x, y = f.y}, {stock = stock, keys = keys, kind = f.type})
    f.ok = r ~= nil
  end
  W.placed = (W.placed or 0) + 1
end

local function index_features(surface, W)
  W.pending = {}
  local ready = {}
  for i, f in ipairs(W.features) do
    local b = f.box
    local missing = 0
    for cx = floor(b.x0 / 32), floor((b.x1 - 0.001) / 32) do
      for cy = floor(b.y0 / 32), floor((b.y1 - 0.001) / 32) do
        if not surface.is_chunk_generated({cx, cy}) then
          missing = missing + 1
          local key = chunk_key(cx, cy)
          local l = W.pending[key]
          if not l then l = {} W.pending[key] = l end
          l[#l + 1] = i
        end
      end
    end
    f.missing = missing
    if missing == 0 then ready[#ready + 1] = f end
  end
  return ready
end

-- Chart-mode labels: region names, passes and fords.
local function draw_labels(surface, P, W)
  W.labels = {}
  for _, reg in ipairs(P.regions) do
    W.labels[#W.labels + 1] = rendering.draw_text({text = reg.name, surface = surface, target = reg.center,
      color = world.LABEL_COLORS.region, scale = world.LABEL_SCALE.region, alignment = "center",
      vertical_alignment = "middle", render_mode = "chart"})
  end
  for _, c in ipairs(P.chokes) do
    W.labels[#W.labels + 1] = rendering.draw_text({text = c.name, surface = surface, target = c.position,
      color = world.LABEL_COLORS[c.kind], scale = world.LABEL_SCALE.choke, alignment = "center",
      vertical_alignment = "middle", render_mode = "chart"})
  end
end

local function count_map_chunks(surface, H)
  local c = H / 32
  local n = 0
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      if surface.is_chunk_generated({cx, cy}) then n = n + 1 end
    end
  end
  return n
end

--- Generate the world on `surface` (created with world.map_gen_settings(plan)): the blocking core around every spawn,
--- cleared spawn areas, the start kits; everything else in the background (on_chunk_generated). Writes storage.world.
function world.apply(surface, P)
  local prof = helpers.create_profiler()
  surface.map_gen_settings = world.map_gen_settings(P)
  surface.always_day = true
  local core = helpers.create_profiler()
  for _, sp in ipairs(P.spawns) do surface.request_to_generate_chunks({sp.x, sp.y}, world.CORE_RADIUS) end
  surface.force_generate_chunk_requests()
  core.stop()
  local W = {size = P.size, seed = P.seed, surface = surface.name, plan = P, regions = P.regions, sites = P.sites,
             chokes = P.chokes, region_grid = P.region_grid, region_grid_n = P.region_grid_n, spawns = {}, oil = {},
             checks = {}, started = game.tick}
  for _, sp in ipairs(P.spawns) do W.spawns[#W.spawns + 1] = {force = sp.force, position = {x = sp.x, y = sp.y}} end
  storage.world = W
  mapgen.adopt(surface.name, "world", P.size)
  local cleared = 0
  for _, sp in ipairs(P.spawns) do
    for _, e in pairs(surface.find_entities_filtered({position = {sp.x, sp.y}, radius = world.CLEAR_RADIUS,
                                                      type = CLEAR_TYPES})) do
      if e.valid then e.destroy() cleared = cleared + 1 end
    end
  end
  W.features = build_features(P)
  local ready = index_features(surface, W)
  for _, f in ipairs(ready) do place_feature(surface, W, f) end
  draw_labels(surface, P, W)
  local total = (P.size / 32) ^ 2
  W.fill = {total = total, generated = count_map_chunks(surface, P.half), started = game.tick, last = game.tick}
  surface.request_to_generate_chunks({0, 0}, math.ceil(P.half / 32))
  prof.stop()
  -- start kit check (placed now: inside the core)
  local kit = {}
  for _, f in ipairs(W.features) do
    if f.type == "patch" and (f.kind == "main" or f.kind == "natural") then
      local sp
      for _, s in ipairs(P.spawns) do if s.force == f.force then sp = s end end
      local d = dist(V(f.x, f.y), sp) + max(f.w, f.h) / 2
      kit[#kit + 1] = {force = f.force, name = f.name, kind = f.kind, placed = f.placed and true or false,
                       tiles = f.tiles or 0, amount = f.amount or 0, total = f.total, dist = d}
    end
  end
  W.checks.kit = kit
  W.checks.core_chunks = W.fill.generated
  log({"", string.format("[rts] world: %s generated: core %d chunks (radius %d around %d spawns), %d trees/rocks "
    .. "cleared, %d of %d features placed, %d pending on %d chunks; background fill of %d chunks requested; core in ",
    surface.name, W.fill.generated, world.CORE_RADIUS, #P.spawns, cleared, W.placed or 0, #W.features,
    #W.features - (W.placed or 0), table_size(W.pending), total - W.fill.generated), core, "; apply in ", prof})
  return W
end

---------------------------------------------------------------------------
-- Background fill: placement on chunk generation, completion, post-check on real tiles
---------------------------------------------------------------------------
local post_step -- forward

local function finish_fill(surface, W)
  local F = W.fill
  F.done, F.done_tick = true, game.tick
  local prof = helpers.create_profiler()
  local area = {{-W.size / 2, -W.size / 2}, {W.size / 2, W.size / 2}}
  local counts = not world.QA_COUNTS and {} or {
    mountain = surface.count_tiles_filtered({area = area, name = "rts-mountain"}),
    ford = surface.count_tiles_filtered({area = area, name = "rts-ford"}),
    marsh = surface.count_tiles_filtered({area = area, name = "rts-marsh"}),
    water = surface.count_tiles_filtered({area = area, collision_mask = "water_tile"}),
    cliffs = surface.count_entities_filtered({area = area, type = "cliff"}),
    trees = surface.count_entities_filtered({area = area, type = "tree"}),
    resources = surface.count_entities_filtered({area = area, type = "resource"}),
  }
  if world.QA_COUNTS then counts.water = counts.water - counts.ford - counts.marsh end
  W.tile_counts = counts
  local unplaced = 0
  for _, f in ipairs(W.features) do if not f.placed then unplaced = unplaced + 1 end end
  prof.stop()
  log({"", string.format("[rts] world: fill complete on %s: %d chunks in %.1f s of game time; tiles %s; features "
    .. "placed %d, unplaced %d; counted in ", surface.name, F.generated, (game.tick - F.started) / 60, serpent.line(counts),
    W.placed or 0, unplaced), prof})
  -- post-check on real tiles: the 8-tile grid from get_tile at cell centres, sliced over ticks
  W.post = {row = 0, n = W.size / world.CELL, cls = {}, agree = 0, total = 0}
end

events.on(defines.events.on_chunk_generated, function(e)
  local W = storage.world
  if not (W and W.fill and not W.fill.done and e.surface.name == W.surface) then return end
  local cx, cy = e.position.x, e.position.y
  local c = W.size / 64
  if cx >= -c and cx < c and cy >= -c and cy < c then
    W.fill.generated = W.fill.generated + 1
    W.fill.last = game.tick
  end
  local key = chunk_key(cx, cy)
  local list = W.pending and W.pending[key]
  if list then
    W.pending[key] = nil
    for _, i in ipairs(list) do
      local f = W.features[i]
      f.missing = f.missing - 1
      if f.missing <= 0 then place_feature(e.surface, W, f) end
    end
  end
  if W.fill.generated >= W.fill.total then finish_fill(e.surface, W) end
end)

-- Rows of the real-tile grid per tick (n = 256 at 2048: 32 ticks of 2,048 get_tile calls).
world.POST_ROWS = 8

post_step = function(W)
  local surface = game.surfaces[W.surface]
  local Q = W.post
  if not surface then W.post = nil return end
  local n, cell, H = Q.n, world.CELL, W.size / 2
  for _ = 1, world.POST_ROWS do
    if Q.row >= n then break end
    local j = Q.row
    for i = 0, n - 1 do
      local t = surface.get_tile(-H + i * cell + cell / 2, -H + j * cell + cell / 2)
      local nm = t.name
      local c
      if nm == "rts-ford" then c = FORD
      elseif nm == "rts-mountain" then c = MOUNTAIN
      elseif nm == "rts-marsh" then c = MARSH
      elseif t.collides_with("player") then c = WATER
      else c = LAND end
      Q.cls[j * n + i + 1] = c
    end
    Q.row = Q.row + 1
  end
  if Q.row < n then return end
  -- flood from the first spawn on the real grid
  local G = {n = n, cell = cell, half = H, cls = Q.cls}
  local P = W.plan
  local d1 = bfs(G, cell_of(G, P.spawns[1]))
  local bad, targets = {}, 0
  local function target(label, p)
    targets = targets + 1
    if not path_tiles(G, d1, p) then bad[#bad + 1] = label end
  end
  for _, sp in ipairs(P.spawns) do target("spawn " .. sp.force, sp) end
  for _, d in ipairs(P.deposits) do target("deposit " .. d.id .. " " .. d.role, d) end
  for _, reg in ipairs(P.regions) do target("region " .. reg.id, reg.center) end
  for _, s in ipairs(P.sites) do target(s.kind .. " " .. util.pos_str(s.position), s.position) end
  local cells = {land = 0, water = 0, mountain = 0, ford = 0, marsh = 0}
  for _, c in pairs(Q.cls) do cells[world.CLASS[c]] = cells[world.CLASS[c]] + 1 end
  if world.write_images then world.write_image(W, G) end
  W.post = nil
  W.checks.post = {targets = targets, bad = bad, cells = cells}
  util.log("world: real-tile check on %s: %d/%d targets reachable from %s on land%s; real cells %s, sampled cells %s",
    W.surface, targets - #bad, targets, P.spawns[1].force, #bad > 0 and (" UNREACHABLE: " .. table.concat(bad, ", ")) or "",
    serpent.line(cells), serpent.line(P.validation.cells))
end

-- QA image: one pixel per 8-tile cell (binary PPM in script-output): land by region kind, water, mountain, ford,
-- marsh; spawns white, deposits by ore, sites (city yellow, ruin orange, port cyan), chokes magenta.
local CLASS_RGB = {[LAND] = {92, 128, 64}, [WATER] = {40, 80, 150}, [MOUNTAIN] = {170, 165, 160}, [FORD] = {90, 200, 210},
                   [MARSH] = {70, 90, 50}}
local ORE_RGB = {["iron-ore"] = {110, 140, 200}, ["copper-ore"] = {220, 120, 60}, coal = {20, 20, 20}, stone = {200, 180, 140}}
function world.write_image(W, G)
  local n = G.n
  local px = {}
  for k = 1, n * n do px[k] = CLASS_RGB[G.cls[k]] or {0, 0, 0} end
  local P = W.plan
  local function dot(p, rgb, r)
    local k0, ci, cj = cell_of(G, p)
    if not k0 then return end
    for dj = -r, r do
      for di = -r, r do
        local ii, jj = ci + di, cj + dj
        if ii >= 0 and jj >= 0 and ii < n and jj < n then px[jj * n + ii + 1] = rgb end
      end
    end
  end
  for _, d in ipairs(P.deposits) do
    for _, p in ipairs(d.patches or {}) do dot(p.center, ORE_RGB[p.name] or {255, 0, 0}, 1) end
    for _, w in ipairs(d.wells or {}) do dot(w, {150, 0, 150}, 0) end
  end
  for _, s in ipairs(P.sites) do
    if s.kind ~= "oil" then
      dot(s.position, s.kind == "ruin" and {255, 140, 0} or (s.kind == "port" and {0, 255, 255} or {255, 230, 0}),
        s.kind == "city_site" and 0 or 1)
    end
  end
  for _, c in ipairs(P.chokes) do dot(c.position, {255, 0, 255}, 1) end
  for _, sp in ipairs(P.spawns) do
    dot(sp, {255, 255, 255}, 2)
    for _, kp in ipairs(sp.kit) do dot(kp.center, ORE_RGB[kp.name] or {255, 0, 0}, 0) end
  end
  local parts = {"P6\n" .. n .. " " .. n .. "\n255\n"}
  local row = {}
  for k = 1, n * n do
    local c = px[k]
    row[#row + 1] = string.char(c[1], c[2], c[3])
    if #row >= 4096 then parts[#parts + 1] = table.concat(row) row = {} end
  end
  parts[#parts + 1] = table.concat(row)
  local path = "rts-world-" .. W.surface .. "-" .. W.seed .. ".ppm"
  helpers.write_file(path, table.concat(parts), false)
  util.log("world: image %s written (%dx%d, one pixel per %d tiles)", path, n, n, G.cell)
end

events.on(defines.events.on_tick, function()
  local W = storage.world
  if W and W.post then post_step(W) end
end)

-- Watchdog (a safety net: measured saves kept their generation requests): a fill that finished no chunk for
-- FILL_WATCHDOG ticks asks for the map again. At 3072 the first background chunk finished only after 20-30 s (the
-- engine takes all requested chunks through the early generation stages first), so the window is a minute.
world.FILL_WATCHDOG = 3600
events.on_nth_tick(600, function()
  local W = storage.world
  if not (W and W.fill and not W.fill.done) then return end
  local surface = game.surfaces[W.surface]
  if not surface then return end
  if game.tick - W.fill.last >= world.FILL_WATCHDOG then
    surface.request_to_generate_chunks({0, 0}, math.ceil(W.size / 64))
    W.fill.last = game.tick
    util.log("world: no chunk of the fill finished for %d s (%d/%d chunks), generation requested again",
      world.FILL_WATCHDOG / 60, W.fill.generated, W.fill.total)
  end
end)

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
local function W() return storage.world end

--- The region at a position, or nil (no world).
function world.region_at(position)
  local w = W()
  if not (w and w.region_grid) then return nil end
  local x, y = util.xy(position)
  local n = w.region_grid_n
  local i = max(0, min(n - 1, floor((x + w.size / 2) / 32)))
  local j = max(0, min(n - 1, floor((y + w.size / 2) / 32)))
  return w.regions[w.region_grid[j * n + i + 1]]
end

function world.regions() return (W() and W().regions) or {} end

--- One position per nation, in force order (rts-player first).
function world.spawns()
  local out = {}
  for _, s in ipairs((W() and W().spawns) or {}) do out[#out + 1] = s.position end
  return out
end

function world.spawn_of(force_name)
  for _, s in ipairs((W() and W().spawns) or {}) do
    if s.force == force_name then return s.position end
  end
  return nil
end

--- Sites of the world: {kind = "city_site"|"ruin"|"port", position, region, ...}; only one kind when given.
function world.sites(kind)
  local out = {}
  for _, s in ipairs((W() and W().sites) or {}) do
    if not kind or s.kind == kind then out[#out + 1] = s end
  end
  return out
end

function world.chokes() return (W() and W().chokes) or {} end

--- Oil fields placed so far: {deposit, position, wells, amount}.
function world.oil_fields() return (W() and W().oil) or {} end

--- Is the background fill done?
function world.ready()
  local w = W()
  return w and w.fill and w.fill.done or false
end

function world.active()
  local w = W()
  return w ~= nil and w.surface ~= nil
end

---------------------------------------------------------------------------
-- Autotest (scripts/ai/autotest.lua calls this at its summary in a Nation match)
---------------------------------------------------------------------------
--- World checks of the running Nation match through the autotest's check(name, ok, fmt, ...).
function world.autotest_checks(check)
  local w = W()
  if not (w and w.plan) then return end
  local P = w.plan
  local V2 = P.validation
  check("world_connectivity", #V2.conn_bad == 0, "%d/%d targets reachable on the sampled grid%s", V2.conn_targets - #V2.conn_bad,
    V2.conn_targets, #V2.conn_bad > 0 and (": " .. table.concat(V2.conn_bad, ", ")) or "")
  local post = w.checks.post
  check("world_connectivity_real", post ~= nil and #post.bad == 0, "%s", post and string.format(
    "%d/%d targets reachable on real tiles%s", post.targets - #post.bad, post.targets,
    #post.bad > 0 and (": " .. table.concat(post.bad, ", ")) or "") or "fill or real-tile check not finished")
  local kit_ok, parts = true, {}
  for _, k in ipairs(w.checks.kit or {}) do
    local ok = k.placed and k.tiles > 0 and k.amount == k.total and k.dist <= world.KIT_RADIUS
    if not ok then kit_ok = false end
    parts[#parts + 1] = string.format("%s %s %s %d/%d at %.0f%s", k.force, k.kind, k.name, k.amount, k.total, k.dist,
      ok and "" or " BAD")
  end
  check("world_start_kit", kit_ok and #(w.checks.kit or {}) > 0, "%s", table.concat(parts, "; "))
  check("world_spawn_spread", V2.spread <= world.SPREAD_MAX, "spread %.3f (max %.2f), nearest-enemy path spread %.3f",
    V2.spread, world.SPREAD_MAX, V2.enemy_spread)
  local unplaced = 0
  for _, f in ipairs(w.features or {}) do if not f.placed then unplaced = unplaced + 1 end end
  check("world_fill", w.fill and w.fill.done and unplaced == 0, "%s, %d features unplaced",
    w.fill and (w.fill.done and string.format("fill done in %.0f s", (w.fill.done_tick - w.fill.started) / 60)
    or string.format("fill at %d/%d chunks", w.fill.generated, w.fill.total)) or "no fill", unplaced)
end

---------------------------------------------------------------------------
-- Console: /rts-world (QA)
---------------------------------------------------------------------------
function world.dump(player)
  local w = W()
  local lines = {}
  if not (w and w.plan) then
    lines[1] = "[rts] world: no world (Skirmish mode or the lobby)"
  else
    local P = w.plan
    lines[#lines + 1] = string.format("[rts] world: %s %dx%d seed %d, %d nations, fill %d/%d%s, validation %s spread %.3f",
      w.surface, w.size, w.size, w.seed, P.nations, w.fill.generated, w.fill.total, w.fill.done and " (done)" or "",
      P.validation.ok and "ok" or table.concat(P.validation.reasons, "; "), P.validation.spread)
    for _, sp in ipairs(P.spawns) do lines[#lines + 1] = string.format("[rts] world: spawn %s at %s", sp.force, util.pos_str(sp)) end
    for _, b in ipairs(P.barriers) do
      lines[#lines + 1] = string.format("[rts] world: %s%s %d (%s), half widths %s, real min thickness %s, %s -> %s",
        b.spur and "spur " or (b.massif and "massif " or ""), b.kind, b.id, world.PROPER[b.proper],
        table.concat(b.ws or {b.w}, "/"), tostring(b.min_thick), util.pos_str(b.points[1]), util.pos_str(b.points[#b.points]))
    end
    for _, c in ipairs(P.chokes) do
      lines[#lines + 1] = string.format("[rts] world: %s %s at %s, width %d", c.kind, c.label, util.pos_str(c.position), c.width)
    end
    for _, reg in ipairs(P.regions) do
      local res = {}
      for name, n in pairs(reg.resources) do res[#res + 1] = name .. " " .. n end
      table.sort(res)
      lines[#lines + 1] = string.format("[rts] world: region %d %s (%s, %s, %s%s) at %s: %s", reg.id, reg.label, reg.kind,
        reg.climate, reg.role, reg.owner and (" " .. reg.owner) or "", util.pos_str(reg.center), table.concat(res, ", "))
    end
    local by = {}
    for _, s in ipairs(P.sites) do by[s.kind] = (by[s.kind] or 0) + 1 end
    lines[#lines + 1] = "[rts] world: sites " .. serpent.line(by)
  end
  for _, line in ipairs(lines) do
    log(line)
    if player then player.print(line) end
  end
  return lines
end

commands.add_command("rts-world", "- Nation-mode world: skeleton, chokes, regions, sites", function(cmd)
  world.dump(cmd.player_index and game.get_player(cmd.player_index))
end)

return world
