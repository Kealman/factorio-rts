-- Phase 5 M1 world (docs/PHASE5-M1.md §3 world.lua; study docs/research/scale/world-map.md): Nation-mode maps.
-- Phase 5 M2 world (docs/PHASE5-M2.md §3 "world.lua additions", study world-map.md §2.2-2.5, §5.3, §5.4): region
-- kinds and generated names, the scarcity portfolio, city-states, ruins, ports, uranium and rare deposits, chokes from
-- a distance transform; the strategic layer (chart labels, regional minimap) is scripts/strategic.lua.
-- Phase 5 M3 world3 (docs/PHASE5-M3.md D8, §3 "worldgen.lua"): world sizes 2048 (default), 3072 and 4096, 2-6 nations
-- (at most 4 on 2048); generation and placement moved to scripts/worldgen.lua (the plan assigns every feature and
-- label to chunks, a forced core, the rest in the background). A 2048 or 3072 world of 2-4 nations plans exactly as in
-- M2 (same seed, same world): every M3 change below is gated by the extended plan (P.xl: 5-6 nations or 4096).
--
-- Hybrid generation. Lua plans the strategic skeleton (spawns, mountain ranges with passes, rivers with fords, coasts,
-- lakes, climate anchors, protected sites, ore deposits); prototypes/world.lua turns it into terrain through named
-- noise expressions that read the skeleton as numeric constants from MapGenSettings.property_expression_names.
--
--   world.size_for(nations)        the default size: 2048 for 2-4 nations, 3072 for 5-6 (2048 / 3072 / 4096 selectable;
--                                  1536 still accepted from configs and probes)
--   world.plan(config, seed)       skeleton + validation on engine samples (LuaSurface.calculate_tile_properties on
--                                  an ungenerated sampler surface, 8-tile grid): land connectivity, start kits, spawn
--                                  scores; a failing skeleton is re-rolled (world.ATTEMPTS). Then (M2, on the sampled
--                                  grid, own random stream) regions, chokes, uranium, ports, city-states, ruins, city
--                                  sites, rare deposits, the scarcity record and the fairness measures.
--   world.map_gen_settings(plan)   the arena's MapGenSettings (Nauvis tiles, trees, decoratives; no ore, no enemies)
--   world.apply(surface, plan)     scripts/worldgen.lua (worldgen.start): blocking core around the spawns and the
--                                  city-state and port sites, spawn areas cleared, start kits placed; the rest of the
--                                  map generates in the background and every planned feature (ore deposit, oil field,
--                                  uranium, rare deposit, ruin, port, city-state) is placed when its chunks exist
--                                  (city-states: cities.found for rts-neutral)
--   world.region_at(position)      -> region {id, name (localised), label (English), kind = "highland" | "plain" |
--                                     "lakeland" | "coast" | "swamp" | "desert" | "forest" | "mountain", climate, role,
--                                     center, bbox, owner?, resources = {[name] = total}, sites = {site index, ...},
--                                     owner_share = {[force] = share of the region's land}}
--   world.place_name(position)     -> the localised region name there, or nil (alerts: "Iron Hills: hauler lost")
--   world.regions(), world.spawns() -> {position, ...} (force order), world.spawn_of(force)
--   world.sites(kind?)             -> {{kind = "city_site"|"ruin"|"port"|"oil"|"city_state"|"rare"|"uranium", position,
--                                      region, name?, ...}}
--   world.chokes()                 -> {{id, kind = "pass"|"ford"|"gap", position, width, name, label, regions = {a, b}}}
--   world.scarcity()               -> {[force] = {home_specialty = region id, specialty = kind, lacks = {ore, ...}}}
--   world.city_states()            -> {{site, name, city_id?, force?, turrets}, ...}
--   world.reset()                  match teardown (match.lua)
--
-- Ore goes through mapgen.place_patch (exact totals) and is recorded with mapgen.record_patch, so the depletion
-- alerts, the "ore remaining" report and /rts-mapgen cover the world; ruins and ports are mapgen ruins
-- (mapgen.add_ruin), captured like the Skirmish ruin. Uranium (rts-uranium-ore) is mined by the ordinary extractor,
-- but an extractor that would reach it is refused until the force has researched Geology (rts-geology).
--
-- Owns storage.world = {
--   size, seed, surface, plan (skeleton, sites, regions, scores; no grid), regions, spawns = {{force, position}},
--   sites, chokes, region_grid (32-tile Voronoi lookup), features (= plan.features, the placement list; plan.chunk_index
--   maps chunks to them, scripts/worldgen.lua), fill = {total, generated, done, started, done_tick, last}, post
--   (real-tile check after the fill), checks,
--   city_states = {{site, name, label, anchor, position, city_id, center, founded, turrets = {LuaEntity}}}
-- }
local util = require("scripts.util")
local events = require("scripts.events")
local mapgen = require("scripts.mapgen")
local buildings = require("scripts.buildings") -- Phase 5 M2 world: the Geology build check (control.lua loads it earlier)

local world = {}

-- Must match prototypes/world.lua SLOTS (world.check_prototypes).
world.SLOTS = {range = 32, pass = 16, river = 16, ford = 16, site = 32, lake = 16, climate = 40}
-- Phase 5 M3 world3: the M2 slot budget; a plan of 2-4 nations up to 3072 keeps it (skeleton(): re-rolls and climate
-- anchors as in M2, so the same seed gives the same world), an extended plan (5-6 nations or 4096) uses world.SLOTS.
world.SLOTS_M2 = {range = 16, pass = 12, river = 12, ford = 16, site = 24, lake = 12, climate = 24}
world.SIZES = {2048, 3072, 4096} -- Phase 5 M3 world3: the lobby's world sizes (2048 the default up to 4 nations)
world.LEGACY_SIZES = {1536}      -- still accepted from a config (M1/M2 probes); the lobby no longer offers it
world.MAX_NATIONS = 6            -- Phase 5 M3 world3: nations per world (at most world.max_nations(size))
world.CELL = 8                   -- validation grid (tiles per cell)
world.CORE_RADIUS = 5            -- Phase 5 M3 world3: scripts/worldgen.lua's core radius around each spawn (chunks)
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
-- Phase 5 M3 world3: balance.nation.world3 (pure data): counts for 5-6 nations and 4096 maps
local W3B = (ok_balance and type(balance) == "table" and balance.nation and balance.nation.world3) or {}
world.W3 = W3B
for n, order in pairs(W3B.contested_order or {}) do world.CONTESTED_ORDER[n] = world.CONTESTED_ORDER[n] or order end
--- A count from an M2 table (2-4 nations, 1536-3072) or else from the M3 one (5-6 nations, 4096), else `default`.
local function count_of(t2, t3, key, default)
  local v = t2 and t2[key]
  if v == nil and t3 then v = t3[key] end
  if v == nil then return default end
  return v
end
world.count_of = count_of
world.RUIN_STOCK = {{"steel-plate", 200}, {"electronic-circuit", 50}}
world.PORT_STOCK = {{"steel-plate", 300}, {"electronic-circuit", 100}}
-- Phase 5 M2 treasury: fn(surface, position) -> port record; scripts/market.lua sets it (port sites become trade posts)
world.place_port = nil

-- Phase 5 M2 world: balance.nation.world (pure data). Each key falls back to the default below.
local function nbw(key, default)
  local v = NB[key]
  if v == nil then return default end
  return v
end
world.W2 = {
  city_states = nbw("city_states", {[2] = 4, [3] = 5, [4] = 6}),
  city_state = nbw("city_state", {}),
  uranium = nbw("uranium", {}),
  rare = nbw("rare", {}),
  ruins = nbw("ruins", {}),
  ports = nbw("ports", {}),
  chokes = nbw("chokes", {}),
  scarce_fair = nbw("scarce_fair", 0.15),
  need_bonus = nbw("need_bonus", 0.5),
}
local CS = world.W2.city_state
local function cs(key, default) if CS[key] == nil then return default end return CS[key] end
world.CS = {
  tier = cs("tier", 1), garrison = cs("garrison", 4), garrison_every = cs("garrison_every", 10 * 3600),
  garrison_max = cs("garrison_max", 10), turret = cs("turret", "rts-turret"), ring = cs("ring", 10),
  ammo_keep = cs("ammo_keep", 200), spawn_gap = cs("spawn_gap", 300), spacing = cs("spacing", 200),
  port_gap = cs("port_gap", 150), choke_offset = cs("choke_offset", {60, 90}), route_gap = cs("route_gap", 90),
  stock = cs("stock", {
    copper = {{"copper-plate", 400}, {"copper-cable", 400}},
    iron = {{"iron-plate", 400}, {"steel-plate", 100}},
    oil = {{"plastic-bar", 150}, {"sulfur", 100}},
    coast = {{"raw-fish", 100}, {"stone-brick", 200}},
    pass = {{"stone-brick", 300}, {"iron-gear-wheel", 150}},
    ford = {{"stone", 300}, {"coal", 200}},
  }),
}
world.URANIUM = {count = world.W2.uranium.count or {[2] = 1, [3] = 1, [4] = 2},
                 amount = world.W2.uranium.amount or 20000, offset = world.W2.uranium.offset or 0.45,
                 tech = world.W2.uranium.tech or "rts-geology", name = "rts-uranium-ore"}
world.RARE = {count = world.W2.rare.count or {[1536] = 4, [2048] = 6, [3072] = 8},
              amount = world.W2.rare.amount or 3000, side = world.W2.rare.side or 6,
              kinds = world.W2.rare.kinds or {"saltpetre", "quartz", "tungsten", "diamonds", "rare-earths", "gold"},
              city_state_share = world.W2.rare.city_state_share or 0.6}
world.RUINS = {count = world.W2.ruins.count or {[1536] = 8, [2048] = 10, [3072] = 12},
               min_spawn = world.W2.ruins.min_spawn or 300, spacing = world.W2.ruins.spacing or 220}
world.PORTS = {spread_max = world.W2.ports.spread_max or 0.15, min_spawn = world.W2.ports.min_spawn or 300,
               spacing = world.W2.ports.spacing or 500}
world.CHOKES = {max_width = world.W2.chokes.max_width or 80, min_width = world.W2.chokes.min_width or 16,
                window = world.W2.chokes.window or 24, min_side = world.W2.chokes.min_side or 40,
                spacing = world.W2.chokes.spacing or 12, spawn_clear = world.W2.chokes.spawn_clear or 140,
                max_tests = world.W2.chokes.max_tests or 120}
world.BASIC_ORES = {"iron-ore", "copper-ore", "coal", "stone"}

-- Names: generated proper names from a syllable table (locale rts-world.syl-a-<i>, syl-b-<i>, syl-c-<i>; the English
-- copies below make the log labels), drawn without repeats from a random stream seeded by the world seed. A name is
-- A + C, or A + B + C (30 %).
world.SYL_A = {"Kar", "Bel", "Dor", "Ost", "Ver", "Ash", "Mor", "Tal", "Hel", "Gar", "Lin", "Ser", "Ul", "Vin", "Ror", "Eld",
               "Fen", "Bran", "Cor", "Hal", "Tor", "Ys", "Mar", "Kel", "Ard", "Sel", "Thar", "Var", "Brin", "Oth", "Nor",
               "Esk"}
world.SYL_B = {"a", "e", "i", "o", "an", "el", "or", "is", "un", "ar"}
world.SYL_C = {"mere", "dun", "holm", "wick", "garth", "ra", "ven", "dor", "lin", "mar", "tor", "rith", "an", "os",
               "stead", "by", "moor", "ka", "nia", "wyn", "gard", "ost", "heim", "rin"}
-- Region nouns per kind (locale rts-world.noun-<kind>-<n>, n = 1..3).
world.NOUNS = {highland = {"Hills", "Highlands", "Heights"}, plain = {"Plains", "Fields", "Vale"},
               lakeland = {"Lakes", "Waters", "Meres"}, coast = {"Coast", "Shore", "Strand"},
               swamp = {"Marsh", "Fens", "Mire"}, desert = {"Barrens", "Sands", "Wastes"},
               forest = {"Woods", "Forest", "Weald"}, mountain = {"Peaks", "Crags", "Mountains"}}
world.KINDS = {"highland", "plain", "lakeland", "coast", "swamp", "desert", "forest", "mountain"}

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
--- Default map size (tiles) for a number of nations. Phase 5 M3 world3 (docs/PHASE5-M3.md D8): 2048 for 2-4 nations
--- (M1 gave 2 nations 1536), 3072 for 5-6; the lobby also offers the other sizes of world.SIZES.
function world.size_for(nations)
  return (nations or 2) <= world.max_nations(2048) and 2048 or 3072
end

--- Phase 5 M3 world3: the most nations a world size holds (balance.nation.world3.max_nations: 4 on 2048, 6 above).
function world.max_nations(size)
  local t = W3B.max_nations or {}
  return t[size] or (size and size >= 3072 and world.MAX_NATIONS or 4)
end

--- A valid world size: `size` when it is one of world.SIZES (or world.LEGACY_SIZES) and holds `nations`, else the
--- smallest size that does (size_for(nations) without a size). Phase 5 M3 world3.
function world.normalize_size(size, nations)
  size = tonumber(size)
  nations = nations or 2
  local ok = false
  for _, s in ipairs(world.SIZES) do
    if size == s then ok = true end
  end
  for _, s in ipairs(world.LEGACY_SIZES) do
    if size == s then ok = true end
  end
  if not ok then return world.size_for(nations) end
  if nations > world.max_nations(size) then
    for _, s in ipairs(world.SIZES) do
      if s > size and nations <= world.max_nations(s) then return s end
    end
  end
  return size
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

-- Skeleton name slots: M1 handed out proper names from a fixed list of 40 here. The skeleton keeps exactly these
-- draws (a shuffled index list), so every seed keeps its M1 terrain; the names shown come from the syllable namer
-- after validation (Phase 5 M2 world).
local PROPER_SLOTS = 40
local function namer(rng)
  local idx = {}
  for i = 1, PROPER_SLOTS do idx[i] = i end
  shuffle(rng, idx)
  local n = 0
  return function()
    n = n + 1
    return idx[(n - 1) % #idx + 1]
  end
end

--- Phase 5 M2 world: a generator of unique proper names {loc = LocalisedString, en = English copy for the log}.
local function syllable_namer(rng)
  local used = {}
  local na, nb, nc = #world.SYL_A, #world.SYL_B, #world.SYL_C
  return function()
    local a, b, c
    for _ = 1, 80 do
      a, c = rng(1, na), rng(1, nc)
      b = rng() < 0.3 and rng(1, nb) or nil
      local key = a .. ":" .. (b or 0) .. ":" .. c
      if not used[key] then
        used[key] = true
        break
      end
    end
    local loc = {"", {"rts-world.syl-a-" .. a}}
    local en = world.SYL_A[a]
    if b then
      loc[#loc + 1] = {"rts-world.syl-b-" .. b}
      en = en .. world.SYL_B[b]
    end
    loc[#loc + 1] = {"rts-world.syl-c-" .. c}
    return {loc = loc, en = en .. world.SYL_C[c]}
  end
end
world.syllable_namer = syllable_namer

local function region_name(kind, noun, proper)
  return {"rts-world.region-name", {"rts-world.noun-" .. kind .. "-" .. noun}, proper.loc},
         proper.en .. " " .. world.NOUNS[kind][noun]
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

-- Phase 5 M2 world: value of a deposit's ores for one nation (VALUE chain weights; the basic ores the nation lacks at
-- home count 1 + need_bonus), plus its oil wells.
local function deposit_value(ores, wells, lacks)
  local v = 0
  for _, o in ipairs(ores or {}) do
    v = v + o[2] * (world.VALUE[o[1]] or 0.5) * ((lacks and lacks[o[1]]) and (1 + world.W2.need_bonus) or 1)
  end
  return v + (wells or 0) * world.VALUE.well
end

--- The basic ores a specialty kind does not hold: {[ore] = true}.
function world.lacks_of(kind)
  local have = {}
  for _, o in ipairs((world.SPECIALTIES[kind] or {}).ores or {}) do have[o[1]] = true end
  local out = {}
  for _, ore in ipairs(world.BASIC_ORES) do
    if not have[ore] then out[ore] = true end
  end
  return out
end

--- Phase 5 M2 world: the specialty kinds assigned to the spawns by permutation search (world-map.md §2.4). Nation value
--- = every deposit's value (deposit_value, the nation's own lacks) shared by inverse square distance and divided by
--- max(1, distance / 500), like the spawn score's expansion term. Returns the best order of `kinds` (index = spawn) and
--- {spread, drawn_spread, values, permutations, changed}. Pure: straight-line distances, no random draws.
function world.assign_specialties(spawns, kinds, spec_pos, oil_pos, contested)
  local N = #kinds
  local perms = {}
  local function permute(arr, n)
    if n <= 1 then
      perms[#perms + 1] = {table.unpack(arr)}
      return
    end
    for i = n, 1, -1 do
      arr[n], arr[i] = arr[i], arr[n]
      permute(arr, n - 1)
      arr[n], arr[i] = arr[i], arr[n]
    end
  end
  local idx = {}
  for i = 1, N do idx[i] = i end
  permute(idx, N) -- the identity comes first
  local best, best_spread, best_values, drawn_spread
  for pi, perm in ipairs(perms) do
    local assigned, lacks = {}, {}
    for i = 1, N do
      assigned[i] = kinds[perm[i]]
      lacks[i] = world.lacks_of(assigned[i])
    end
    local deps = {}
    for j = 1, N do
      local spec = world.SPECIALTIES[assigned[j]]
      deps[#deps + 1] = {pos = spec_pos[j], ores = spec.ores, wells = spec.wells}
      deps[#deps + 1] = {pos = oil_pos[j], wells = world.OIL_HOME.wells}
    end
    for _, c in ipairs(contested) do deps[#deps + 1] = {pos = c, ores = world.CONTESTED[c.kind]} end
    deps[#deps + 1] = {pos = {x = 0, y = 0}, wells = world.OIL_CENTER.wells}
    local values = {}
    for i = 1, N do values[i] = 0 end
    for _, d in ipairs(deps) do
      local inv, ts = 0, {}
      for i, sp in ipairs(spawns) do
        ts[i] = max(1, dist(sp, d.pos))
        inv = inv + 1 / (ts[i] * ts[i])
      end
      for i = 1, N do
        values[i] = values[i] + deposit_value(d.ores, d.wells, lacks[i]) * (1 / (ts[i] * ts[i])) / inv / max(1, ts[i] / 500)
      end
    end
    local hi, lo = -math.huge, math.huge
    for i = 1, N do hi, lo = max(hi, values[i]), min(lo, values[i]) end
    local spread = hi > 0 and (hi - lo) / hi or 0
    if pi == 1 then drawn_spread = spread end
    if not best or spread < best_spread - 1e-9 then best, best_spread, best_values = assigned, spread, values end
  end
  local changed = false
  for i = 1, N do if best[i] ~= kinds[i] then changed = true end end
  return best, {spread = best_spread, drawn_spread = drawn_spread, values = best_values, permutations = #perms,
                changed = changed}
end

-- One skeleton attempt (pure: no surface). Returns P, or nil and a reason.
local function skeleton(cfg, seed, attempt)
  local N, S = cfg.nations, cfg.size
  local H = S / 2
  local k = S / 2048
  local rng = new_rng(seed, attempt, N)
  local function rr(a, b) return a + (b - a) * rng() end
  -- Phase 5 M3 world3: an extended plan (5-6 nations or a 4096 map) gets the M3 slots and counts; any other plan keeps
  -- the M2 rules draw for draw (same seed, same world)
  local xl = N > 4 or S > 3072
  local kh = xl and min(k, W3B.home_scale_max or 1.5) or k -- specialty and home oil distances
  local P = {version = 1, seed = seed, attempt = attempt, size = S, half = H, nations = N, forces = cfg.forces,
             spawns = {}, barriers = {}, crossings = {}, lakes = {}, climate = {}, sea = {}, protect = {},
             deposits = {}, regions = {}, sites = {}, chokes = {}, xl = xl or nil,
             slots = xl and world.SLOTS or world.SLOTS_M2}
  local name = namer(rng)
  -- Coasts: 0-2 sea edges.
  local edges = shuffle(rng, {"n", "s", "e", "w"})
  local roll = rng()
  local nsea = roll < 0.3 and 0 or (roll < 0.75 and 1 or 2)
  for i = 1, nsea do P.sea[edges[i]] = floor(rr(70, 120) * k) end
  -- Spawns on a ring, evenly spread with a little jitter; force order = config forces (rts-player first).
  local R_s = (({[2] = 0.32, [3] = 0.30, [4] = 0.31})[N] or (W3B.spawn_ring or {})[N] or 0.33) * S -- M3: 5-6 nations
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
  for i = 1, N do spec_kinds[i] = world.SPECIALTY_ORDER[(i - 1) % #world.SPECIALTY_ORDER + 1] end -- M3: 5-6 repeat kinds
  shuffle(rng, spec_kinds)
  -- Phase 5 M3 world3: with 5-6 nations the neighbours are 60-72 degrees apart, so the specialty and the home oil sit
  -- closer to the outward direction (balance.nation.world3.specialty_angle) and the home distances stop growing at 3072
  local spec_angle = (xl and (W3B.specialty_angle or {})[N]) or 72
  local oil_angle = spec_angle + 6
  local function place_home(sp, base_angle, dist0, side, r, discs)
    local u = norm(sp)
    local t = rot(u, math.pi / 2)
    for _, da in ipairs({0, -12, 12, -24, 24, -36}) do
      for _, dd in ipairs({0, -40, 40, -70}) do
        local a = math.rad(base_angle + da)
        local p = round(vadd(vadd(V(sp.x, sp.y), u, (dist0 + dd) * kh * math.cos(a)), t, side * (dist0 + dd) * kh * math.sin(a)))
        local ok = clear_of(P, p, r, {edge = 120 * k, sea = 80, discs = discs or P.home_discs})
        if ok and dist(p, sp) > world.SPAWN_CLEAR + r - 40 then return p end
      end
    end
    return nil
  end
  -- Phase 5 M2 world: specialties by permutation search (world-map.md §2.4). Positions do not depend on the kind, so a
  -- dry run of the placement below gives them without drawing from the random stream; world.assign_specialties then
  -- values every assignment of the drawn kinds and keeps the one with the lowest spread of nation value (ties keep the
  -- drawn order).
  local r_c = (N == 2 and 0.58 or 0.62) * r_in
  do
    local discs, spec_pos, oil_pos = {}, {}, {}
    for i, sp in ipairs(P.spawns) do
      discs[#discs + 1] = {x = sp.x, y = sp.y, r = world.SPAWN_CLEAR - 60}
      local r_spec = floor(52 * max(kh, 0.85))
      local p = place_home(sp, spec_angle, 380, 1, r_spec, discs)
      if not p then break end
      discs[#discs + 1] = {x = p.x, y = p.y, r = r_spec}
      local r_oil = floor(34 * max(kh, 0.85))
      local q = place_home(sp, oil_angle, 300, -1, r_oil, discs)
      if not q then break end
      discs[#discs + 1] = {x = q.x, y = q.y, r = r_oil}
      spec_pos[i], oil_pos[i] = p, q
    end
    if #spec_pos == N and #oil_pos == N then
      local contested = {}
      for i, b in ipairs(P.barriers) do
        local kind = world.CONTESTED_ORDER[N][i]
        if kind then contested[#contested + 1] = {kind = kind, x = math.cos(b.angle) * r_c, y = math.sin(b.angle) * r_c} end
      end
      local best, search = world.assign_specialties(P.spawns, spec_kinds, spec_pos, oil_pos, contested)
      spec_kinds = best
      P.specialty_search = search
    end
  end
  P.home_discs = {}
  for i, sp in ipairs(P.spawns) do
    protect(P, sp, world.SPAWN_CLEAR, "spawn " .. sp.force)
    P.home_discs[#P.home_discs + 1] = {x = sp.x, y = sp.y, r = world.SPAWN_CLEAR - 60}
    sp.kit = start_kit(P, sp)
    local spec = world.SPECIALTIES[spec_kinds[i]]
    local r_spec = floor(52 * max(kh, 0.85))
    local p = place_home(sp, spec_angle, 380, 1, r_spec)
    if not p then return nil, "no room for the specialty of " .. sp.force end
    local d = {id = #P.deposits + 1, role = "specialty", specialty = spec_kinds[i], force = sp.force, x = p.x, y = p.y,
               r = r_spec, kind = spec.kind}
    d.patches = deposit_patches(rng, d, spec.ores)
    if spec.wells then d.wells = oil_wells(rng, d, spec.wells, world.OIL_HOME.amount) end
    P.deposits[#P.deposits + 1] = d
    P.home_discs[#P.home_discs + 1] = {x = p.x, y = p.y, r = r_spec}
    local r_oil = floor(34 * max(kh, 0.85))
    local q = place_home(sp, oil_angle, 300, -1, r_oil)
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
  center.wells = oil_wells(rng, center, (xl and (W3B.center_oil_wells or {})[N]) or world.OIL_CENTER.wells, -- M3 world3
    world.OIL_CENTER.amount)
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
  local spacing = 300 * k
  if xl then -- Phase 5 M3 world3: more regions on 4096 and for the homes and deposits of nations 5 and 6
    target = count_of(nil, W3B.regions, S, target) + 4 * max(0, N - 4)
    spacing = 300 * min(k, W3B.region_spacing_max or 1.5)
  end
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
        if dist(c, reg.center) < spacing then okc = false break end
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
  local max_massifs = xl and count_of(nil, W3B.massifs, S, world.MASSIFS) or world.MASSIFS -- Phase 5 M3 world3
  for _, reg in ipairs(P.regions) do
    if massifs >= max_massifs and reg.role == "frontier" and reg.climate ~= "lakes" then break end
    if reg.role == "frontier" and reg.climate ~= "lakes" and massifs < max_massifs then
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
    if #P.climate < P.slots.climate then
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
          if #P.lakes < P.slots.lake then
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
  local SL = P.slots -- Phase 5 M3 world3: the M2 budget unless the plan is extended
  if nr > SL.range or nv > SL.river or npass > SL.pass or nford > SL.ford
     or #P.protect > SL.site or #P.lakes > SL.lake then
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
-- Phase 5 M3 world3: the octile path fields (below, Phase 5 M2) also serve an extended plan's validation
local path_field, path_len, coarse_fields

local function score_spawns(P, G, dists, pathf)
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
      local t = pathf and pathf(si, d) or path_tiles(G, dists[si], d) -- Phase 5 M3 world3: pathf (extended plan)
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
  -- Phase 5 M3 world3: an extended plan (5-6 nations, 4096: 262,144 cells) floods the 8-tile grid from the first
  -- spawn only (connectivity) and scores with the octile path fields of the 16-tile grid (the M2 fairness measures),
  -- which the M2 steps reuse: five fewer floods of the fine grid, about 0.75 s of planning at 4096
  local pathf
  if P.xl then
    dists[1] = bfs(G, cell_of(G, P.spawns[1]))
    R.coarse = coarse_fields(P, G)
    pathf = function(si, p) return path_len(R.coarse.G2, R.coarse.fields[si], P.spawns[si], p) end
  else
    for si, sp in ipairs(P.spawns) do dists[si] = bfs(G, cell_of(G, sp)) end
  end
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
  R.scores, R.spread = score_spawns(P, G, dists, pathf)
  if R.spread > world.SPREAD_MAX then R.reasons[#R.reasons + 1] = string.format("spawn score spread %.3f", R.spread) end
  -- nearest-enemy path spread (study: 12 %; informational)
  local near = {}
  for si, sp in ipairs(P.spawns) do
    local best
    for sj, sq in ipairs(P.spawns) do
      if sj ~= si then
        local t = pathf and pathf(si, sq) or path_tiles(G, dists[si], sq)
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
-- Sites, regions, chokes (after the skeleton is accepted). Phase 5 M2 world: everything below works on the sampled
-- 8-tile grid with its own random streams, so the terrain of a seed stays the skeleton's.
---------------------------------------------------------------------------
local function nearest_spawn_dist(P, p)
  local best = math.huge
  for _, sp in ipairs(P.spawns) do best = min(best, dist(p, sp)) end
  return best
end

-- Phase 5 M2 world: path distance field from one cell over the passable cells with 8 neighbours, chamfer weights 3
-- (orthogonal) and 4 (diagonal; no corner cutting between two blocked cells), by a bucket queue. The M1 field (bfs) is
-- 4-connected and counts a diagonal approach up to 41 % longer than a straight one; this one is within 6 % of the
-- true length in every direction, which the fairness measures need. Returns {[cell] = chamfer units} (3 per cell).
path_field = function(G, start, pass) -- Phase 5 M3 world3: forward-declared above (validate)
  local n = G.n
  local nn = n * n
  local d = {}
  if not start or not pass[start] then return d end
  local buckets = {[0] = {start}}
  d[start] = 0
  local cur, last = 0, 0
  while cur <= last do
    local list = buckets[cur]
    if list then
      buckets[cur] = nil
      local c3, c4 = cur + 3, cur + 4
      local b3, b4 = buckets[c3] or {}, buckets[c4] or {}
      for idx = 1, #list do
        local k = list[idx]
        if d[k] == cur then
          local i = (k - 1) % n
          local pw = i > 0 and pass[k - 1]
          local pe = i < n - 1 and pass[k + 1]
          local pn = k > n and pass[k - n]
          local ps = k <= nn - n and pass[k + n]
          local nk, o
          if pw then nk = k - 1 o = d[nk] if not o or c3 < o then d[nk] = c3 b3[#b3 + 1] = nk end end
          if pe then nk = k + 1 o = d[nk] if not o or c3 < o then d[nk] = c3 b3[#b3 + 1] = nk end end
          if pn then nk = k - n o = d[nk] if not o or c3 < o then d[nk] = c3 b3[#b3 + 1] = nk end end
          if ps then nk = k + n o = d[nk] if not o or c3 < o then d[nk] = c3 b3[#b3 + 1] = nk end end
          if pw and pn then nk = k - n - 1 if pass[nk] then o = d[nk] if not o or c4 < o then d[nk] = c4 b4[#b4 + 1] = nk end end end
          if pe and pn then nk = k - n + 1 if pass[nk] then o = d[nk] if not o or c4 < o then d[nk] = c4 b4[#b4 + 1] = nk end end end
          if pw and ps then nk = k + n - 1 if pass[nk] then o = d[nk] if not o or c4 < o then d[nk] = c4 b4[#b4 + 1] = nk end end end
          if pe and ps then nk = k + n + 1 if pass[nk] then o = d[nk] if not o or c4 < o then d[nk] = c4 b4[#b4 + 1] = nk end end end
        end
      end
      -- only buckets that hold cells are kept (an empty one would extend the queue forever)
      if #b3 > 0 then
        buckets[c3] = b3
        if c3 > last then last = c3 end
      end
      if #b4 > 0 then
        buckets[c4] = b4
        if c4 > last then last = c4 end
      end
    end
    cur = cur + 1
  end
  return d
end

-- Path tiles from a path_field (source position `src`) to a position: the nearest passable cell within 2 cells (like
-- path_tiles), never shorter than the straight line (the chamfer runs up to 6 % short on diagonals); nil when
-- unreachable.
path_len = function(G, d, src, p) -- Phase 5 M3 world3: forward-declared above
  local k, i, j = cell_of(G, p)
  if not k then return nil end
  local best
  for dj = -2, 2 do
    for di = -2, 2 do
      local ii, jj = i + di, j + dj
      if ii >= 0 and jj >= 0 and ii < G.n and jj < G.n then
        local v = d[jj * G.n + ii + 1]
        if v then
          v = v + 3 * math.max(math.abs(di), math.abs(dj))
          if not best or v < best then best = v end
        end
      end
    end
  end
  if not best then return nil end
  return max(best * G.cell / 3, dist(src, p))
end

-- The 16-tile grid of the octile path fields (a coarse cell is passable when at least 3 of its 4 cells are) and one
-- field per spawn: {G2, fields = {[si] = field}}.
coarse_fields = function(P, G)
  local n2 = G.n / 2
  local G2 = {n = n2, cell = G.cell * 2, half = G.half}
  local pass = {}
  for j = 0, n2 - 1 do
    for i = 0, n2 - 1 do
      local k = 2 * j * G.n + 2 * i + 1
      local c = 0
      if passable(G.cls[k]) then c = c + 1 end
      if passable(G.cls[k + 1]) then c = c + 1 end
      if passable(G.cls[k + G.n]) then c = c + 1 end
      if passable(G.cls[k + G.n + 1]) then c = c + 1 end
      pass[j * n2 + i + 1] = c >= 3
    end
  end
  local fields = {}
  for si, sp in ipairs(P.spawns) do fields[si] = path_field(G2, cell_of(G2, sp), pass) end
  return {G2 = G2, fields = fields}
end

-- Shared context of the M2 planning steps: grid, distance fields, candidate cells, helpers.
local function plan_context(P, G, R)
  local X = {P = P, G = G, R = R, k = P.size / 2048, d1 = R.dists[1]}
  X.has_sea = next(P.sea) ~= nil
  X.cands = {}
  for j = 2, G.n - 3, 4 do
    for i = 2, G.n - 3, 4 do
      local key = j * G.n + i + 1
      if G.cls[key] == LAND then X.cands[#X.cands + 1] = cell_center(G, key) end
    end
  end
  function X.reachable(p) return path_tiles(G, X.d1, p) ~= nil end
  function X.far_from(p, list, r)
    for _, s in ipairs(list) do
      if dist(p, s.position or s) < r then return false end
    end
    return true
  end
  -- away from every deposit disc (margin beyond its radius) and every start-kit patch. The gap of a point is cached
  -- (X.gap_cache, keyed by the point table: the candidates are reused by every step); X.forget_gaps() after deposits
  -- are added.
  X.gap_cache = {}
  local function gap_of(p)
    local g = X.gap_cache[p]
    if g then return g end
    g = math.huge
    for _, d in ipairs(P.deposits) do g = min(g, dist(p, d) - d.r) end
    for _, sp in ipairs(P.spawns) do
      for _, kp in ipairs(sp.kit) do g = min(g, dist(p, kp.center) - 20) end
    end
    X.gap_cache[p] = g
    return g
  end
  function X.off_deposits(p, margin) return gap_of(p) >= margin end
  function X.forget_gaps() X.gap_cache = {} end
  -- away from every planned patch and oil well by `margin` tiles beyond the patch's half side
  function X.off_patches(p, margin)
    for _, d in ipairs(P.deposits) do
      for _, q in ipairs(d.patches or {}) do
        if dist(p, q.center) < max(q.w, q.h) / 2 + margin then return false end
      end
      for _, w in ipairs(d.wells or {}) do
        if dist(p, w) < margin then return false end
      end
    end
    for _, sp in ipairs(P.spawns) do
      for _, kp in ipairs(sp.kit) do
        if dist(p, kp.center) < max(kp.w, kp.h) / 2 + margin then return false end
      end
    end
    return true
  end
  -- coastal: land next to the sea (water within 5 cells, less than 120 tiles from a sea edge)
  function X.coastal(p)
    if not X.has_sea or sea_margin(P, p) >= 120 then return false end
    local _, water = X.window(p, 5)
    return water > 0
  end
  -- path tiles from every spawn ({[si] = tiles or nil}; octile path fields, see path_field)
  -- path fields on a 16-tile grid (4x fewer cells; fairness needs no finer): a coarse cell is passable when at least 3
  -- of its 4 cells are (a 30-tile barrier still blocks, a 34-tile pass or a ford still opens)
  local C = R.coarse or coarse_fields(P, G) -- Phase 5 M3 world3: an extended plan computed them in validate
  local G2 = C.G2
  X.fields = C.fields
  function X.paths(p)
    local out = {}
    for si, sp in ipairs(P.spawns) do out[si] = path_len(G2, X.fields[si], sp, p) end
    return out
  end
  function X.path(si, p) return path_len(G2, X.fields[si], P.spawns[si], p) end
  -- prefix sums of land and mountain cells: O(1) box tests
  local n = G.n
  local land, mtn, wat = {}, {}, {}
  for j = 0, n do land[j * (n + 1) + 1], mtn[j * (n + 1) + 1], wat[j * (n + 1) + 1] = 0, 0, 0 end
  for i = 0, n do land[i + 1], mtn[i + 1], wat[i + 1] = 0, 0, 0 end
  for j = 1, n do
    local rl, rm, rw = 0, 0, 0
    for i = 1, n do
      local c = G.cls[(j - 1) * n + i]
      if c == LAND then rl = rl + 1 end
      if c == MOUNTAIN then rm = rm + 1 end
      if c == WATER then rw = rw + 1 end
      local at, up = j * (n + 1) + i + 1, (j - 1) * (n + 1) + i + 1
      land[at] = land[up] + rl
      mtn[at] = mtn[up] + rm
      wat[at] = wat[up] + rw
    end
  end
  local function box_sum(t, i0, j0, i1, j1) -- inclusive cell box, clamped by the caller
    local w = n + 1
    return t[(j1 + 1) * w + i1 + 2] - t[j0 * w + i1 + 2] - t[(j1 + 1) * w + i0 + 1] + t[j0 * w + i0 + 1]
  end
  -- buildable_box on the prefix sums: every cell of the box land and inside the grid
  function X.buildable(p, half_tiles)
    local r = math.ceil(half_tiles / G.cell)
    local _, i, j = cell_of(G, p)
    if not i or i - r < 0 or j - r < 0 or i + r >= n or j + r >= n then return false end
    return box_sum(land, i - r, j - r, i + r, j + r) == (2 * r + 1) * (2 * r + 1)
  end
  -- a mountain cell within r cells
  function X.mountain_near(p, r)
    local _, i, j = cell_of(G, p)
    if not i then return false end
    return box_sum(mtn, max(0, i - r), max(0, j - r), min(n - 1, i + r), min(n - 1, j + r)) > 0
  end
  -- land and water cells within r cells: land, water, total
  function X.window(p, r)
    local _, i, j = cell_of(G, p)
    if not i then return 0, 0, 0 end
    local i0, j0, i1, j1 = max(0, i - r), max(0, j - r), min(n - 1, i + r), min(n - 1, j + r)
    return box_sum(land, i0, j0, i1, j1), box_sum(wat, i0, j0, i1, j1), (i1 - i0 + 1) * (j1 - j0 + 1)
  end
  -- straight-line distance from p to the nearest spawn-to-centre segment (the main marching lines)
  function X.route_gap(p)
    local best = math.huge
    for _, sp in ipairs(P.spawns) do best = min(best, (seg_dist(p, sp, V(0, 0)))) end
    return best
  end
  return X
end

-- Region of a position on a plan's 32-tile region grid.
local function plan_region_id(P, p)
  local gn = P.region_grid_n
  local i = max(0, min(gn - 1, floor((p.x + P.half) / 32)))
  local j = max(0, min(gn - 1, floor((p.y + P.half) / 32)))
  return P.region_grid[j * gn + i + 1]
end
world.plan_region_id = plan_region_id

-- Regions: drop filler centres in water or mountains, the 32-tile Voronoi grid, kinds from the sampled cells and the
-- climate, generated names.
world.MOUNTAIN_SHARE = 0.06 -- a frontier region with this share of mountain cells is a "mountain" region (a range
                            -- 40 tiles thick across a 2048 frontier region is 5-8 %)
local function build_regions(P, G, names)
  local keep = {}
  for _, reg in ipairs(P.regions) do
    local k = cell_of(G, reg.center)
    if reg.role ~= "frontier" or (k and passable(G.cls[k])) then keep[#keep + 1] = reg end
  end
  for i, reg in ipairs(keep) do reg.id = i end
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
  -- cell shares and bounding boxes per region (from the 8-tile grid)
  local stats = {}
  for _, reg in ipairs(keep) do
    stats[reg.id] = {total = 0, mountain = 0, water = 0, marsh = 0}
    reg.bbox = {x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge}
  end
  local n, cell = G.n, G.cell
  for j = 0, n - 1 do
    local y = -G.half + j * cell + cell / 2
    for i = 0, n - 1 do
      local x = -G.half + i * cell + cell / 2
      local gi, gj = floor((x + P.half) / 32), floor((y + P.half) / 32)
      local rid = grid[gj * gn + gi + 1]
      local st = stats[rid]
      local c = G.cls[j * n + i + 1]
      st.total = st.total + 1
      if c == MOUNTAIN then st.mountain = st.mountain + 1
      elseif c == WATER then st.water = st.water + 1
      elseif c == MARSH then st.marsh = st.marsh + 1 end
      local bb = keep[rid].bbox
      if x - cell / 2 < bb.x0 then bb.x0 = x - cell / 2 end
      if y - cell / 2 < bb.y0 then bb.y0 = y - cell / 2 end
      if x + cell / 2 > bb.x1 then bb.x1 = x + cell / 2 end
      if y + cell / 2 > bb.y1 then bb.y1 = y + cell / 2 end
    end
  end
  for _, reg in ipairs(keep) do
    local st = stats[reg.id]
    local share = st.total > 0 and st.mountain / st.total or 0
    reg.mountain_share, reg.water_share = share, st.total > 0 and st.water / st.total or 0
    if reg.role == "home" then
      reg.kind = "plain"
    elseif reg.role ~= "frontier" then
      reg.kind = reg.kind == "swamp" and "swamp" or "highland"
    elseif reg.kind == "coast" then
      reg.kind = "coast"
    elseif share >= world.MOUNTAIN_SHARE then
      reg.kind = "mountain"
    elseif reg.climate == "desert" then reg.kind = "desert"
    elseif reg.climate == "forest" then reg.kind = "forest"
    elseif reg.climate == "lakes" then reg.kind = "lakeland"
    elseif reg.climate == "highland" or reg.kind == "highland" then reg.kind = "highland"
    else reg.kind = "plain" end
    reg.pname = names()
    reg.name, reg.label = region_name(reg.kind, reg.noun, reg.pname)
    reg.sites = {}
  end
  -- barriers keep a generated name too (dump, labels)
  for _, b in ipairs(P.barriers) do
    b.pname = names()
    b.label = b.kind == "range" and (b.pname.en .. " Range") or ("River " .. b.pname.en)
    b.name = {"rts-world." .. b.kind .. "-name", b.pname.loc}
  end
end

---------------------------------------------------------------------------
-- Chokes: planned crossings plus narrow places found by a distance transform on the passability grid
---------------------------------------------------------------------------
-- Distance (in cells, chamfer 1 / sqrt 2) of every passable cell to the nearest blocked cell (water, mountain) or the
-- map border; blocked cells have 0.
local function distance_field(G)
  local n, cls = G.n, G.cls
  local D = {}
  local SQ = 1.41421
  for k = 1, n * n do D[k] = passable(cls[k]) and 1e9 or 0 end
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      local k = j * n + i + 1
      local d = D[k]
      if d > 0 then
        local b = min(i + 1, j + 1, n - i, n - j)
        if b < d then d = b end
        local v
        if i > 0 then v = D[k - 1] + 1 if v < d then d = v end end
        if j > 0 then
          v = D[k - n] + 1 if v < d then d = v end
          if i > 0 then v = D[k - n - 1] + SQ if v < d then d = v end end
          if i < n - 1 then v = D[k - n + 1] + SQ if v < d then d = v end end
        end
        D[k] = d
      end
    end
  end
  for j = n - 1, 0, -1 do
    for i = n - 1, 0, -1 do
      local k = j * n + i + 1
      local d = D[k]
      if d > 0 then
        local v
        if i < n - 1 then v = D[k + 1] + 1 if v < d then d = v end end
        if j < n - 1 then
          v = D[k + n] + 1 if v < d then d = v end
          if i < n - 1 then v = D[k + n + 1] + SQ if v < d then d = v end end
          if i > 0 then v = D[k + n - 1] + SQ if v < d then d = v end end
        end
        D[k] = d
      end
    end
  end
  return D
end
world.distance_field = distance_field

-- Is cell k a bottleneck? Cut a disc of radius D(k) + 1 cells around it and flood the passable cells of a window of
-- `W` cells around it from the rim of the cut: two or more separate sides of at least `min_side` cells make a choke
-- (one side, or sides joined around a small obstacle inside the window, do not). Returns the two largest sides
-- {{x, y (cell centroid), size}, ...} or nil.
local function bottleneck(G, D, k, W, min_side)
  local n = G.n
  local ci = (k - 1) % n
  local cj = (k - 1 - ci) / n
  local rc = D[k] + 1.0
  local rc2, rim2 = rc * rc, (rc + 1.5) * (rc + 1.5)
  local i0, i1, j0, j1 = max(0, ci - W), min(n - 1, ci + W), max(0, cj - W), min(n - 1, cj + W)
  local comp = {}
  local sides = {}
  local R = math.ceil(rc + 1.5)
  local qk, qi, qj = {}, {}, {}
  for dj = -R, R do
    for di = -R, R do
      local r2 = di * di + dj * dj
      local si, sj = ci + di, cj + dj
      if r2 > rc2 and r2 <= rim2 and si >= i0 and si <= i1 and sj >= j0 and sj <= j1 then
        local sk = sj * n + si + 1
        if D[sk] > 0 and not comp[sk] then
          local id = #sides + 1
          comp[sk] = id
          local head, tail = 1, 1
          qk[1], qi[1], qj[1] = sk, si, sj
          local size, sx, sy = 0, 0, 0
          while head <= tail do
            local kk, i, j = qk[head], qi[head], qj[head]
            head = head + 1
            size, sx, sy = size + 1, sx + i, sy + j
            for nb = 1, 4 do
              local ni, nj = i, j
              if nb == 1 then ni = i - 1 elseif nb == 2 then ni = i + 1 elseif nb == 3 then nj = j - 1 else nj = j + 1 end
              if ni >= i0 and ni <= i1 and nj >= j0 and nj <= j1 then
                local nk = nj * n + ni + 1
                if not comp[nk] and D[nk] > 0 then
                  local ddi, ddj = ni - ci, nj - cj
                  if ddi * ddi + ddj * ddj > rc2 then
                    comp[nk] = id
                    tail = tail + 1
                    qk[tail], qi[tail], qj[tail] = nk, ni, nj
                  end
                end
              end
            end
          end
          sides[id] = {i = sx / size, j = sy / size, size = size}
        end
      end
    end
  end
  local big = {}
  for _, s in ipairs(sides) do
    if s.size >= min_side then big[#big + 1] = s end
  end
  if #big < 2 then return nil end
  table.sort(big, function(a, b) return a.size > b.size end)
  local function pos(s) return V(-G.half + s.i * G.cell + G.cell / 2, -G.half + s.j * G.cell + G.cell / 2) end
  return {pos(big[1]), pos(big[2])}, #big
end

local function plan_chokes(P, surface, G, names)
  local C = world.CHOKES
  local D = distance_field(G)
  -- clearance width on the sampled grid around a point: the widest ridge within 2 cells, (2 D - 1) cells
  local function measured(p)
    local _, ci, cj = cell_of(G, p)
    if not ci then return nil end
    local best = 0
    for dj = -2, 2 do
      for di = -2, 2 do
        local ii, jj = ci + di, cj + dj
        if ii >= 0 and jj >= 0 and ii < G.n and jj < G.n then best = max(best, D[jj * G.n + ii + 1]) end
      end
    end
    return best > 0 and floor((2 * best - 1) * G.cell + 0.5) or 0
  end
  -- planned crossings, moved from warped to plain coordinates (two fixed-point steps on the sampled warp)
  local pts = {}
  for _, c in ipairs(P.crossings) do pts[#pts + 1] = {x = c.x, y = c.y} end
  if #pts > 0 then
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
      local t = norm(V(b.points[c.seg + 1].x - b.points[c.seg].x, b.points[c.seg + 1].y - b.points[c.seg].y))
      local nrm = V(-t.y, t.x)
      local ra = plan_region_id(P, vadd(p, nrm, w + 40))
      local rb = plan_region_id(P, vadd(p, nrm, -(w + 40)))
      local pname = names()
      P.chokes[#P.chokes + 1] = {id = #P.chokes + 1, kind = c.kind, position = p, width = floor(width + 0.5),
                                 name = {"rts-world." .. c.kind .. "-name", pname.loc}, pname = pname,
                                 label = (c.kind == "pass" and "Gate of " or "Ford of ") .. pname.en,
                                 barrier = c.barrier, crossing = c.id, r = c.r, regions = {ra, rb},
                                 measured_width = measured(p)}
    end
  end
  -- emergent chokes: ridge cells of the distance field (local maxima across the corridor) no wider than max_width,
  -- grouped into 8-connected clusters; the narrowest cell of each cluster is tested as a bottleneck
  local n = G.n
  local dmin, dmax = (C.min_width / G.cell + 1) / 2, (C.max_width / G.cell + 1) / 2
  -- a ridge cell lies between two obstacles: along its ridge axis the clearance falls on both sides and a blocked cell
  -- (or the border) follows within its clearance + 1.5 cells on both sides (shoreline noise has open land on one side)
  local cand = {}
  local axes = {{1, 0, 1}, {0, 1, 1}, {1, 1, 1.41421}, {1, -1, 1.41421}}
  local function walls(i, j, e, d)
    local steps = math.ceil((d + 1.5) / e[3])
    local hit = 0
    for sgn = -1, 1, 2 do
      for t = 1, steps do
        local ii, jj = i + sgn * e[1] * t, j + sgn * e[2] * t
        if ii < 0 or jj < 0 or ii >= n or jj >= n or D[jj * n + ii + 1] == 0 then
          hit = hit + 1
          break
        end
      end
    end
    return hit == 2
  end
  for j = 1, n - 2 do
    for i = 1, n - 2 do
      local k = j * n + i + 1
      local d = D[k]
      if d >= dmin and d <= dmax then
        for _, e in ipairs(axes) do
          local a, b = D[k - e[1] - e[2] * n], D[k + e[1] + e[2] * n]
          if a <= d and b <= d and (a < d or b < d) and walls(i, j, e, d) then
            cand[k] = true
            break
          end
        end
      end
    end
  end
  local seen, clusters = {}, {}
  for k in pairs(cand) do
    if not seen[k] then
      local list, q, head = {}, {k}, 1
      seen[k] = true
      while head <= #q do
        local kk = q[head]
        head = head + 1
        list[#list + 1] = kk
        local i = (kk - 1) % n
        for dj = -1, 1 do
          for di = -1, 1 do
            local nk = kk + di + dj * n
            if (di ~= 0 or dj ~= 0) and i + di >= 0 and i + di < n and cand[nk] and not seen[nk] then
              seen[nk] = true
              q[#q + 1] = nk
            end
          end
        end
      end
      table.sort(list, function(a, b)
        if D[a] ~= D[b] then return D[a] < D[b] end
        return a < b
      end)
      clusters[#clusters + 1] = list
    end
  end
  table.sort(clusters, function(a, b)
    if D[a[1]] ~= D[b[1]] then return D[a[1]] < D[b[1]] end
    return a[1] < b[1]
  end)
  local tests, found = 0, 0
  local edge_cells = 6
  for _, list in ipairs(clusters) do
    if tests >= C.max_tests then break end
    for t = 1, min(3, #list) do
      local k = list[t]
      local p = cell_center(G, k)
      local i = (k - 1) % n
      local j = (k - 1 - i) / n
      local ok = i >= edge_cells and j >= edge_cells and i < n - edge_cells and j < n - edge_cells
        and nearest_spawn_dist(P, p) >= C.spawn_clear
      if ok then
        for _, c in ipairs(P.chokes) do
          if dist(p, c.position) < (c.r or 0) + 48 or (c.kind == "gap" and dist(p, c.position) < C.spacing * G.cell) then
            ok = false
            break
          end
        end
      end
      if ok then
        tests = tests + 1
        local sides = bottleneck(G, D, k, C.window, C.min_side)
        if sides then
          local pname = names()
          found = found + 1
          P.chokes[#P.chokes + 1] = {id = #P.chokes + 1, kind = "gap", position = round(p),
                                     width = floor((2 * D[k] - 1) * G.cell + 0.5), measured_width = measured(p),
                                     name = {"rts-world.gap-name", pname.loc}, pname = pname,
                                     label = "Narrows of " .. pname.en, r = floor(D[k] * G.cell + 0.5),
                                     regions = {plan_region_id(P, sides[1]), plan_region_id(P, sides[2])}}
          break
        end
      end
    end
  end
  P.choke_stats = {candidates = table_size(cand), clusters = #clusters, tests = tests, found = found}
end

---------------------------------------------------------------------------
-- Uranium (contested: inside the oil swamp in the middle), ports (fair by path), city-states, ruins, city sites, oil
-- sites, rare deposits
---------------------------------------------------------------------------
local function patch_side(total) return math.max(6, math.ceil(sqrt(total / world.DENSITY / 0.88))) end

local function plan_uranium(P, X)
  local center
  for _, d in ipairs(P.deposits) do if d.role == "center_oil" then center = d end end
  if not center then return end
  local count = count_of(world.URANIUM.count, W3B.uranium, P.nations, 1) -- Phase 5 M3 world3: 5-6 nations
  local side = patch_side(world.URANIUM.amount)
  local rays = {}
  for _, b in ipairs(P.barriers) do if b.ray then rays[#rays + 1] = b end end
  local picks = count >= 2 and {1, (#rays >= 4) and 3 or 2} or {1}
  if count >= 3 then -- Phase 5 M3 world3: evenly spread over the rays
    picks = {}
    for i = 1, count do picks[i] = floor((i - 1) * #rays / count) + 1 end
  end
  for _, ri in ipairs(picks) do
    local b = rays[ri]
    if b then
      local spot
      for _, f in ipairs({world.URANIUM.offset, 0.35, 0.55, 0.65, 0.25, 0.75, 0.85}) do
        for _, da in ipairs({0, 0.2, -0.2, 0.4, -0.4, 0.6, -0.6}) do
          local a = b.angle + da
          local p = round(V(center.x + math.cos(a) * center.r * f, center.y + math.sin(a) * center.r * f))
          local okw = true
          for _, w in ipairs(center.wells or {}) do
            if dist(p, w) < side / 2 + 6 then okw = false break end
          end
          for _, d in ipairs(P.deposits) do
            if d.role == "uranium" and dist(p, d) < side + 16 then okw = false end
          end
          if okw and buildable_box(X.G, p, side / 2 - 2) then spot = p break end
        end
        if spot then break end
      end
      if spot then
        local d = {id = #P.deposits + 1, role = "uranium", x = spot.x, y = spot.y, r = floor(side / 2 + 4), kind = "swamp",
                   patch_kind = "uranium", patches = {{name = world.URANIUM.name, total = world.URANIUM.amount, w = side,
                   h = side, center = V(spot.x, spot.y)}}}
        P.deposits[#P.deposits + 1] = d
        P.sites[#P.sites + 1] = {kind = "uranium", position = V(spot.x, spot.y), deposit = d.id,
                                 amount = world.URANIUM.amount, resource = world.URANIUM.name}
      end
    end
  end
end

-- Ports: 2 for 2 nations below 3072, else 3-4, on the coast (or the map edge), at least PORTS.min_spawn tiles from
-- every spawn and PORTS.spacing apart; chosen by a greedy search from many starts that minimises the spread of the
-- nations' path distance to their nearest port (coast preferred over a dry edge when the map has a sea).
local function plan_ports(P, X, rng, names)
  local G, k = X.G, X.k
  local target = (P.nations <= 2 and P.size < 3072) and 2 or min(4, max(3, P.nations))
  if P.nations > 4 then target = count_of(nil, W3B.ports, P.nations, 4) end -- Phase 5 M3 world3
  local min_spawn = max(world.PORTS.min_spawn, 300 * k)
  local pc = {}
  for _, p in ipairs(X.cands) do
    local coast = X.coastal(p)
    local edge = edge_margin(P, p) < 70 and edge_margin(P, p) > 30
    if (coast or edge) and X.buildable(p, 12) and X.off_deposits(p, 40) and nearest_spawn_dist(P, p) > min_spawn then
      local d = X.paths(p)
      local all = true
      for si in ipairs(P.spawns) do if not d[si] then all = false end end
      if all then pc[#pc + 1] = {p = p, coast = coast, d = d} end
    end
  end
  local N = #P.spawns
  local function cost(set)
    local hi, lo, dry = 0, math.huge, 0
    for si = 1, N do
      local best = math.huge
      for _, c in ipairs(set) do best = min(best, c.d[si]) end
      hi, lo = max(hi, best), min(lo, best)
    end
    for _, c in ipairs(set) do if X.has_sea and not c.coast then dry = dry + 1 end end
    local spread = hi > 0 and (hi - lo) / hi or 0
    return spread + 0.03 * dry, spread
  end
  local spacing = world.PORTS.spacing * k
  local best_set, best_cost, best_spread
  local starts = {}
  for i = 1, #pc do starts[i] = i end
  shuffle(rng, starts)
  for si = 1, min(#starts, 24) do
    local set = {pc[starts[si]]}
    while #set < target do
      local pick, pick_cost
      for _, c in ipairs(pc) do
        local okc = true
        for _, q in ipairs(set) do
          if c == q or dist(c.p, q.p) < spacing then okc = false break end
        end
        if okc then
          set[#set + 1] = c
          local cc = cost(set)
          set[#set] = nil
          if not pick_cost or cc < pick_cost then pick, pick_cost = c, cc end
        end
      end
      if not pick then break end
      set[#set + 1] = pick
    end
    local cc, spread = cost(set)
    if #set > (best_set and #best_set or 0) or (best_set and #set == #best_set and cc < best_cost) then
      best_set, best_cost, best_spread = set, cc, spread
    end
  end
  local ports = {}
  for _, c in ipairs(best_set or {}) do
    local pname = names()
    ports[#ports + 1] = {kind = "port", position = round(c.p), coast = c.coast, paths = c.d, pname = pname,
                         name = {"rts-world.port-name", pname.loc}, label = "Port " .. pname.en}
    P.sites[#P.sites + 1] = ports[#ports]
  end
  P.port_stats = {target = target, candidates = #pc, spread = best_spread}
  return ports
end

-- City-states (world-map.md §5.3): each contested copper region (in the middle of its deposit), the oil swamp (beside
-- it, away from the marching lines), the coast, then the major passes and fords (beside the crossing, out of turret
-- reach of the path through it), then the contested iron regions; world.W2.city_states per nation count.
local function plan_city_states(P, X, ports, names)
  local G, k = X.G, X.k
  local target = count_of(world.W2.city_states, W3B.city_states, P.nations, 5) -- Phase 5 M3 world3: 5-6 nations
  local list = {}
  local function spot_ok(p, allow_deposit)
    if not (X.buildable(p, 14) and X.reachable(p)) then return false end
    if nearest_spawn_dist(P, p) < world.CS.spawn_gap then return false end
    if not X.far_from(p, list, world.CS.spacing) or not X.far_from(p, ports, world.CS.port_gap) then return false end
    if not X.off_patches(p, 14) then return false end
    if not allow_deposit then
      for _, d in ipairs(P.deposits) do
        if d.role ~= "center_oil" and d.role ~= "uranium" and dist(p, d) < d.r + 10 then return false end
      end
    end
    return true
  end
  local function add(p, anchor, extra)
    local pname = names()
    local s = {kind = "city_state", position = round(p), anchor = anchor, pname = pname,
               name = {"rts-world.city-state-name", pname.loc}, label = "Free City of " .. pname.en}
    for key, v in pairs(extra or {}) do s[key] = v end
    list[#list + 1] = s
    return s
  end
  local function ring(c, radii, steps)
    local out = {}
    for _, r in ipairs(radii) do
      if r == 0 then
        out[#out + 1] = V(c.x, c.y)
      else
        for a = 0, steps - 1 do
          local ang = TAU * a / steps
          out[#out + 1] = round(V(c.x + math.cos(ang) * r, c.y + math.sin(ang) * r))
        end
      end
    end
    return out
  end
  local function deposit_anchor(d, anchor)
    for _, p in ipairs(ring(d, {0, 10, 16, 22, 30, d.r, d.r + 10, d.r + 20}, 16)) do
      if spot_ok(p, true) then return add(p, anchor, {deposit = d.id}) end
    end
  end
  -- contested copper
  for _, d in ipairs(P.deposits) do
    if #list < target and d.role == "contested" and d.contested == "copper" then deposit_anchor(d, "copper") end
  end
  -- the oil swamp in the middle: at its edge, off the marching lines through the centre (a 60-minute 1v1 showed an army
  -- bound for the enemy capital razing a city-state 55 tiles from the centre): the spot farthest from the
  -- spawn-to-centre lines up to ROUTE_GAP tiles, then the one nearest the swamp
  local center
  for _, d in ipairs(P.deposits) do if d.role == "center_oil" then center = d end end
  if center and #list < target then
    local best, best_s
    for _, b in ipairs(P.barriers) do
      if b.ray then
        for _, da in ipairs({0, 0.17, -0.17, 0.35, -0.35}) do
          for _, r in ipairs({55, 70, 85, 100, 115, 130}) do
            local a = b.angle + da
            local rr = r * max(k, 0.75)
            local p = round(V(center.x + math.cos(a) * rr, center.y + math.sin(a) * rr))
            if spot_ok(p, true) then
              local s = min(X.route_gap(p), world.CS.route_gap * max(k, 0.75)) - 0.1 * rr
              if not best_s or s > best_s then best, best_s = p, s end
            end
          end
        end
      end
    end
    if best then add(best, "oil", {deposit = center.id}) end
  end
  -- the coast: the most contested coastal spot (equal path distance to its two nearest nations)
  if X.has_sea and #list < target then
    local best, best_s
    for _, p in ipairs(X.cands) do
      if X.coastal(p) and spot_ok(p) then
        local d = X.paths(p)
        local a, b = math.huge, math.huge
        for si in ipairs(P.spawns) do
          local t = d[si] or math.huge
          if t < a then a, b = t, a elseif t < b then b = t end
        end
        if b < math.huge then
          local s = -abs(a - b) / b
          if not best_s or s > best_s then best, best_s = p, s end
        end
      end
    end
    if best then add(best, "coast") end
  end
  -- major crossings: the main rays' inner crossings first
  local crossings = {}
  for _, c in ipairs(P.chokes) do
    if c.crossing then crossings[#crossings + 1] = c end
  end
  table.sort(crossings, function(a, b)
    local ca, cb = P.crossings[a.crossing], P.crossings[b.crossing]
    if ca.along ~= cb.along then return ca.along < cb.along end
    return a.id < b.id
  end)
  for _, c in ipairs(crossings) do
    if #list >= target then break end
    local o = world.CS.choke_offset
    local best, best_d
    for _, p in ipairs(ring(c.position, {o[1], (o[1] + o[2]) / 2, o[2]}, 24)) do
      if spot_ok(p) then
        local dd = dist(p, c.position)
        if not best_d or dd < best_d then best, best_d = p, dd end
      end
    end
    if best then add(best, c.kind, {choke = c.id}) end
  end
  -- fallback: contested iron
  for _, d in ipairs(P.deposits) do
    if #list < target and d.role == "contested" and d.contested ~= "copper" then deposit_anchor(d, "iron") end
  end
  for _, s in ipairs(list) do P.sites[#P.sites + 1] = s end
  return list
end

-- Ruins (world-map.md §5.3): low-value land (desert, swamp, mountain regions, mountain rims, far corners) at least
-- RUINS.min_spawn tiles from every spawn, RUINS.spacing apart, away from deposits, city-states and ports.
local function plan_ruins(P, X, rng, city_states, ports)
  local G, k = X.G, X.k
  -- Phase 5 M3 world3: 4096 maps (balance.nation.world3.ruins)
  local target = count_of(world.RUINS.count, W3B.ruins, P.size, P.size >= 3072 and 12 or (P.size >= 2048 and 10 or 8))
  local min_spawn = max(world.RUINS.min_spawn, 320 * k)
  local scored = {}
  for _, p in ipairs(X.cands) do
    local ds = nearest_spawn_dist(P, p)
    if ds > min_spawn and X.buildable(p, 12) and X.off_deposits(p, 60) and X.reachable(p)
       and X.far_from(p, city_states, 140) and X.far_from(p, ports, 100) then
      local s = ds + 200 * rng()
      local reg = P.regions[plan_region_id(P, p)]
      if reg then
        if reg.role ~= "frontier" then s = s - 250 end
        if reg.kind == "desert" or reg.kind == "swamp" or reg.kind == "mountain" then s = s + 150 end
      end
      if X.mountain_near(p, 3) then s = s + 120 end
      if edge_margin(P, p) < 250 * k then s = s + 80 end
      scored[#scored + 1] = {p = p, s = s}
    end
  end
  table.sort(scored, function(a, b) return a.s > b.s end)
  local ruins = {}
  for _, c in ipairs(scored) do
    if #ruins >= target then break end
    if X.far_from(c.p, ruins, world.RUINS.spacing * k) then ruins[#ruins + 1] = {kind = "ruin", position = round(c.p)} end
  end
  for _, s in ipairs(ruins) do P.sites[#P.sites + 1] = s end
  return ruins
end

-- City sites (for cities.lua): one next to every non-start deposit first (24-110 tiles from its edge), then the best
-- open land; at least 96 apart, 230 from every spawn, and City Center spacing away from every city-state.
local function plan_city_sites(P, X, rng, city_states, ruins)
  local G, k = X.G, X.k
  local spacing = 96
  local city = {}
  local function free(p) return X.far_from(p, city, spacing) and X.far_from(p, city_states, spacing) end
  -- the static tests of a candidate, once: far from spawns, room for a city, off deposits, reachable
  local good = {}
  for _, p in ipairs(X.cands) do
    if nearest_spawn_dist(P, p) > 230 * k and X.buildable(p, 20) and X.off_deposits(p, 14) and X.reachable(p) then
      good[#good + 1] = p
    end
  end
  for _, d in ipairs(P.deposits) do
    if d.role ~= "uranium" and d.role ~= "rare" then
      local best, best_s
      for _, p in ipairs(good) do
        local dd = dist(p, d)
        if dd > d.r + 24 and dd < d.r + 110 and free(p) then
          local s = dd + 0.25 * nearest_spawn_dist(P, p)
          if not best_s or s < best_s then best, best_s = p, s end
        end
      end
      if best then city[#city + 1] = {kind = "city_site", position = round(best), deposit = d.id, score = 3} end
    end
  end
  local target = P.size >= 3072 and 48 or (P.size >= 2048 and 32 or 22)
  if P.xl then target = count_of(nil, W3B.city_sites, P.size, target) + 4 * max(0, P.nations - 4) end -- Phase 5 M3 world3
  local scored = {}
  for _, p in ipairs(good) do
    do
      local s = 0
      for _, d in ipairs(P.deposits) do
        if dist(p, d) < d.r + 140 then s = s + 1 end
      end
      local open, water, tot = X.window(p, 12)
      scored[#scored + 1] = {p = p, s = s + 0.5 * (water > 0 and 1 or 0) + open / max(1, tot) + 0.1 * rng()}
    end
  end
  table.sort(scored, function(a, b) return a.s > b.s end)
  for _, c in ipairs(scored) do
    if #city >= target then break end
    if free(c.p) and X.far_from(c.p, ruins, 40) then
      city[#city + 1] = {kind = "city_site", position = round(c.p), score = c.s}
    end
  end
  for _, s in ipairs(city) do P.sites[#P.sites + 1] = s end
  return city
end

-- Rare deposits (world-map.md §2.4, deep-economy.md §3.7; resource entities only, bonuses are M3): RARE.city_state_share
-- of them on city-state land (20-36 tiles from its City Center), the rest on mountain rims (desert and mountain regions
-- preferred), away from spawns, deposits and other sites.
local function plan_rare(P, X, rng, city_states)
  local G, k = X.G, X.k
  -- Phase 5 M3 world3: 4096 maps (balance.nation.world3.rare)
  local count = count_of(world.RARE.count, W3B.rare, P.size, P.size >= 3072 and 8 or (P.size >= 2048 and 6 or 4))
  local kinds = {}
  for i, kd in ipairs(world.RARE.kinds) do kinds[i] = kd end
  shuffle(rng, kinds)
  local side = world.RARE.side
  local placed = {}
  local function ok_spot(p)
    if not (X.buildable(p, side / 2 + 1) and X.reachable(p) and X.off_patches(p, side + 6)) then return false end
    if not X.far_from(p, placed, 120) then return false end
    for _, s in ipairs(P.sites) do
      if s.kind ~= "city_state" and dist(p, s.position) < 30 then return false end
    end
    return true
  end
  local function add(p, where)
    local kind = kinds[(#placed % #kinds) + 1]
    local d = {id = #P.deposits + 1, role = "rare", rare = kind, x = p.x, y = p.y, r = side, kind = "highland",
               patch_kind = "rare", patches = {{name = "rts-rare-" .. kind, total = world.RARE.amount, w = side, h = side,
               center = V(p.x, p.y)}}}
    P.deposits[#P.deposits + 1] = d
    placed[#placed + 1] = {kind = "rare", position = V(p.x, p.y), deposit = d.id, rare = kind, where = where,
                           resource = "rts-rare-" .. kind, amount = world.RARE.amount}
  end
  local on_cs = min(#city_states, math.ceil(count * world.RARE.city_state_share))
  for i = 1, on_cs do
    local c = city_states[i]
    local start = rng(0, 15)
    for _, r in ipairs({24, 30, 36, 20}) do
      local done = false
      for a = 0, 15 do
        local ang = TAU * ((a + start) % 16) / 16
        local p = round(V(c.position.x + math.cos(ang) * r, c.position.y + math.sin(ang) * r))
        if ok_spot(p) then
          add(p, "city_state")
          done = true
          break
        end
      end
      if done then break end
    end
  end
  local scored = {}
  for _, p in ipairs(X.cands) do
    if #placed >= count then break end
    if nearest_spawn_dist(P, p) > 250 * max(k, 0.75) and X.off_deposits(p, 30) then
      local rim = X.mountain_near(p, 2)
      local reg = P.regions[plan_region_id(P, p)]
      local desert = reg and (reg.kind == "desert" or reg.kind == "mountain" or reg.climate == "desert")
      if rim or desert then scored[#scored + 1] = {p = p, s = (rim and 1 or 0) + (desert and 1 or 0) + rng()} end
    end
  end
  table.sort(scored, function(a, b) return a.s > b.s end)
  for _, c in ipairs(scored) do
    if #placed >= count then break end
    if ok_spot(c.p) then add(c.p, "rim") end
  end
  for _, s in ipairs(placed) do P.sites[#P.sites + 1] = s end
  return placed
end

-- Region resources (deposits, start kits), sites per region, the region of every site.
local function finish_regions(P)
  for _, reg in ipairs(P.regions) do
    reg.resources = {}
    reg.sites = {}
  end
  for _, d in ipairs(P.deposits) do
    local reg = P.regions[plan_region_id(P, d)]
    d.region = reg.id
    for _, p in ipairs(d.patches or {}) do reg.resources[p.name] = (reg.resources[p.name] or 0) + p.total end
    for _, w in ipairs(d.wells or {}) do reg.resources["crude-oil"] = (reg.resources["crude-oil"] or 0) + w.amount end
  end
  for _, sp in ipairs(P.spawns) do
    local reg = P.regions[plan_region_id(P, sp)]
    for _, p in ipairs(sp.kit) do reg.resources[p.name] = (reg.resources[p.name] or 0) + p.total end
  end
  for i, s in ipairs(P.sites) do
    s.region = plan_region_id(P, s.position)
    local reg = P.regions[s.region]
    reg.sites[#reg.sites + 1] = i
  end
end

-- Scarcity and fairness (docs/PHASE5-M2.md §4 World): per nation its home specialty, the basic ores its home lacks
-- beyond the start kit, path tiles to its specialty; per scarce deposit (contested majors, the oil swamp, uranium) the
-- path distances of the two nearest nations; per nation the path to its nearest port.
local function plan_scarcity(P, X, ports)
  local G, R = X.G, X.R
  P.scarcity = {}
  for si, sp in ipairs(P.spawns) do
    local rec = {force = sp.force, lacks = {}}
    local have = {}
    for _, d in ipairs(P.deposits) do
      if d.force == sp.force and (d.role == "specialty" or d.role == "home_oil") then
        for _, p in ipairs(d.patches or {}) do have[p.name] = true end
        if d.role == "specialty" then
          rec.home_specialty, rec.specialty = d.region, d.specialty
          rec.specialty_path = X.path(si, d)
          local other
          for sj in ipairs(P.spawns) do
            if sj ~= si then
              local t = X.path(sj, d)
              if t and (not other or t < other) then other = t end
            end
          end
          rec.specialty_other = other
        end
      end
    end
    for _, ore in ipairs(world.BASIC_ORES) do
      if not have[ore] then rec.lacks[#rec.lacks + 1] = ore end
    end
    P.scarcity[sp.force] = rec
  end
  -- scarce types
  local types = {}
  local function add(kind, d)
    local paths = {}
    for si in ipairs(P.spawns) do
      local t = X.path(si, d)
      if t then paths[#paths + 1] = {force = P.spawns[si].force, t = t} end
    end
    table.sort(paths, function(a, b) return a.t < b.t end)
    local diff = (#paths >= 2 and paths[2].t > 0) and (paths[2].t - paths[1].t) / paths[2].t or 1
    local T = types[kind]
    if not T then
      T = {kind = kind, deposits = {}}
      types[kind] = T
    end
    T.deposits[#T.deposits + 1] = {id = d.id, a = paths[1] and paths[1].force, b = paths[2] and paths[2].force,
                                   ta = paths[1] and paths[1].t, tb = paths[2] and paths[2].t, diff = diff,
                                   ok = #paths >= 2 and diff <= world.W2.scarce_fair}
  end
  for _, d in ipairs(P.deposits) do
    if d.role == "contested" then
      add(d.patches[1] and d.patches[1].name or d.contested, d)
    elseif d.role == "center_oil" then
      add("crude-oil", d)
    elseif d.role == "uranium" then
      add(world.URANIUM.name, d)
    end
  end
  for _, T in pairs(types) do
    T.ok = true
    for _, x in ipairs(T.deposits) do if not x.ok then T.ok = false end end
  end
  -- ports
  local near, hi, lo = {}, 0, math.huge
  for si, sp in ipairs(P.spawns) do
    local best
    for _, p in ipairs(ports) do
      local t = p.paths and p.paths[si]
      if t and (not best or t < best) then best = t end
    end
    near[sp.force] = best
    if best then hi, lo = max(hi, best), min(lo, best) end
  end
  P.fair = {types = types, ports = {count = #ports, nearest = near, spread = (hi > 0 and lo < math.huge) and (hi - lo) / hi or 1}}
end

--- Phase 5 M2 world: the M2 planning steps on an accepted skeleton (own random streams; no terrain change).
local function plan_w2(P, G, R, surface)
  local times = {}
  local function step(name)
    local prof = helpers.create_profiler()
    times[#times + 1] = {name, prof}
    return prof
  end
  local t = step("context")
  local X = plan_context(P, G, R)
  local names = syllable_namer(new_rng(P.seed, 3000 + P.attempt, P.nations))
  local rng = new_rng(P.seed, 1000 + P.attempt, P.nations)
  P.sites = {}
  t.stop() t = step("regions")
  build_regions(P, G, names)
  t.stop() t = step("chokes")
  plan_chokes(P, surface, G, names)
  t.stop() t = step("uranium+ports")
  plan_uranium(P, X)
  X.forget_gaps()
  local ports = plan_ports(P, X, rng, names)
  t.stop() t = step("city-states")
  local city_states = plan_city_states(P, X, ports, names)
  t.stop() t = step("ruins")
  local ruins = plan_ruins(P, X, rng, city_states, ports)
  t.stop() t = step("city sites")
  plan_city_sites(P, X, rng, city_states, ruins)
  t.stop() t = step("rare+scarcity")
  -- oil fields (m1-economy: the AI looks for kind "oil"): one site per planned field, at its centre
  for _, d in ipairs(P.deposits) do
    if d.wells and #d.wells > 0 then
      local amount = 0
      for _, w in ipairs(d.wells) do amount = amount + w.amount end
      P.sites[#P.sites + 1] = {kind = "oil", position = V(d.x, d.y), deposit = d.id, role = d.role, force = d.force,
                               wells = #d.wells, amount = amount}
    end
  end
  plan_rare(P, X, rng, city_states)
  finish_regions(P)
  plan_scarcity(P, X, ports)
  t.stop()
  local parts = {""}
  for i, x in ipairs(times) do
    parts[#parts + 1] = (i > 1 and "; " or "") .. x[1] .. " "
    parts[#parts + 1] = x[2]
  end
  log({"", "[rts] world: M2 planning steps: ", parts})
end

-- Phase 5 M2 world: claimable cells for territory.share (the Territory victory, docs/PHASE5-M2.md D6): land and marsh
-- cells of the sampled 8-tile grid (the territory grid has the same cells) that are not within CLAIM_RIM cells of the
-- map border; mountain, water and ford cells are not claimable. One row string per grid row, "\1" = claimable.
world.CLAIM_RIM = 2
world.CLAIM_RANGE = {0.40, 0.97} -- the autotest's bounds of the claimable share of a map (measured 88-93 % at 2048;
                                 -- Phase 5 M3 world3: 95.5 % on a 3072 world without sea, seed 30726, the M2 plan)
local function build_claimable(G)
  local n, rim = G.n, world.CLAIM_RIM
  local rows, count = {}, 0
  for j = 0, n - 1 do
    local row = {}
    for i = 0, n - 1 do
      local c = G.cls[j * n + i + 1]
      local ok = (c == LAND or c == MARSH) and i >= rim and j >= rim and i < n - rim and j < n - rim
      if ok then count = count + 1 end
      row[i + 1] = ok and "\1" or "\0"
    end
    rows[j + 1] = table.concat(row)
  end
  return {n = n, rows = rows, count = count, total = n * n}
end

local function thousands(v)
  local str = tostring(math.floor(v))
  local out = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

---------------------------------------------------------------------------
-- world.plan
---------------------------------------------------------------------------
local function plan_config(config)
  local c = config or {}
  local nations = (tonumber(c.opponents) or 1) + 1
  if c.nations then nations = c.nations end
  nations = max(2, min(world.MAX_NATIONS, nations)) -- Phase 5 M3 world3: up to six nations
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
  -- Phase 5 M3 world3: the time of each M1 planning step over all attempts (log line "M1 planning steps")
  local steps = {skeleton = helpers.create_profiler(true), thicken = helpers.create_profiler(true),
                 sample = helpers.create_profiler(true), validate = helpers.create_profiler(true)}
  local function timed(name, fn, ...)
    steps[name].restart()
    local a, b = fn(...)
    steps[name].stop()
    return a, b
  end
  for attempt = 1, world.ATTEMPTS do
    local P, why = timed("skeleton", skeleton, cfg, seed, attempt)
    if not P then
      tried[#tried + 1] = string.format("#%d skeleton: %s", attempt, why)
    else
      local thin = timed("thicken", thicken, P)
      local surface = sampler_surface(world.map_gen_settings(P))
      local G = timed("sample", sample_grid, surface, P)
      local R = timed("validate", validate, P, G)
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
  log({"", "[rts] world: M1 planning steps: skeleton ", steps.skeleton, "; thicken ", steps.thicken, "; sample ",
    steps.sample, "; validate ", steps.validate})
  local surface = sampler_surface(world.map_gen_settings(P))
  local w2 = helpers.create_profiler() -- Phase 5 M2 world
  plan_w2(P, G, R, surface)
  P.claimable = build_claimable(G)
  w2.stop()
  util.log("world: claimable %d %% of %s cells (%s cells: land and marsh, %d-cell rim left out)",
    math.floor(100 * P.claimable.count / P.claimable.total + 0.5), thousands(P.claimable.total),
    thousands(P.claimable.count), world.CLAIM_RIM)
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
  world.log_w2(P, w2)
  return P
end

--- Phase 5 M2 world: one log line with the M2 planning results (regions by kind, chokes, sites, scarcity, fairness).
function world.log_w2(P, prof)
  local kinds, sites, chokes = {}, {}, {}
  for _, reg in ipairs(P.regions) do kinds[reg.kind] = (kinds[reg.kind] or 0) + 1 end
  for _, s in ipairs(P.sites) do sites[s.kind] = (sites[s.kind] or 0) + 1 end
  for _, c in ipairs(P.chokes) do chokes[c.kind] = (chokes[c.kind] or 0) + 1 end
  local lacks, types = {}, {}
  for _, sp in ipairs(P.spawns) do
    local r = P.scarcity[sp.force]
    lacks[#lacks + 1] = string.format("%s %s spec %s path %s/%s lacks [%s]", sp.force, tostring(r.specialty),
      tostring(r.home_specialty), r.specialty_path and string.format("%.0f", r.specialty_path) or "-",
      r.specialty_other and string.format("%.0f", r.specialty_other) or "-", table.concat(r.lacks, " "))
  end
  for kind, T in pairs(P.fair.types) do
    local parts = {}
    for _, x in ipairs(T.deposits) do
      parts[#parts + 1] = string.format("#%d %s %.0f / %s %.0f (%.1f%%)", x.id, tostring(x.a), x.ta or -1, tostring(x.b),
        x.tb or -1, 100 * x.diff)
    end
    types[#types + 1] = string.format("%s %s [%s]", kind, T.ok and "ok" or "UNFAIR", table.concat(parts, ", "))
  end
  table.sort(types)
  local ss = P.specialty_search
  log({"", string.format("[rts] world: M2 plan seed %d: regions %s; chokes %s (gap search: %s); sites %s; ports spread "
    .. "%.3f (%d candidates); specialties %s; scarcity %s; scarce types %s; M2 planning in ", P.seed,
    serpent.line(kinds), serpent.line(chokes), serpent.line(P.choke_stats), serpent.line(sites),
    P.fair.ports.spread, P.port_stats and P.port_stats.candidates or 0,
    ss and string.format("spread %.3f (drawn %.3f, %d permutations%s)", ss.spread, ss.drawn_spread, ss.permutations,
      ss.changed and ", reassigned" or "") or "-", table.concat(lacks, "; "), table.concat(types, "; ")), prof})
end

---------------------------------------------------------------------------
-- world.apply: generation and placement
---------------------------------------------------------------------------
local function chunk_key(cx, cy) return (cx + 1024) * 2048 + (cy + 1024) end
world.chunk_key = chunk_key -- Phase 5 M3 world3: scripts/worldgen.lua (plan.chunk_index keys)

-- Features: patches, oil fields, ruins, ports. Each knows its tile box; it is placed once all its chunks exist.
-- Phase 5 M3 world3: built at planning (scripts/worldgen.lua keeps them in plan.features and maps them to chunks).
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
      add({type = "patch", kind = d.patch_kind or "region", deposit = d.id, name = p.name, x = p.center.x, -- M2: uranium, rare
           y = p.center.y, w = p.w, h = p.h, total = p.total, half = max(p.w, p.h) / 2 + 3})
    end
    if d.wells and #d.wells > 0 then
      add({type = "oil", deposit = d.id, x = d.x, y = d.y, half = d.r, wells = d.wells})
    end
  end
  for i, s in ipairs(P.sites) do
    if s.kind == "ruin" or s.kind == "port" then
      add({type = s.kind, x = s.position.x, y = s.position.y, half = 12, region = s.region})
    elseif s.kind == "city_state" then -- Phase 5 M2 world: founded for rts-neutral once its ground exists
      add({type = "city_state", site = i, x = s.position.x, y = s.position.y, half = 16, region = s.region})
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
      -- Phase 5 M3 integration: a second ring of offsets (a 4096 world whose chunks came in another order put a well's
      -- nine spots on water; the first nine tries are unchanged, so worlds that placed every well stay the same)
      for _, off in ipairs({{0, 0}, {3, 0}, {-3, 0}, {0, 3}, {0, -3}, {4, 4}, {-4, -4}, {4, -4}, {-4, 4},
                            {7, 0}, {-7, 0}, {0, 7}, {0, -7}, {7, 7}, {-7, -7}, {7, -7}, {-7, 7}}) do
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
  elseif f.type == "port" and world.place_port then -- Phase 5 M2 treasury: a trade post (scripts/market.lua)
    f.ok = world.place_port(surface, {x = f.x, y = f.y}) ~= nil
  elseif f.type == "ruin" or f.type == "port" then
    local stock = f.type == "port" and world.PORT_STOCK or world.RUIN_STOCK
    local keys = f.type == "port" and {label = "rts-world.port-label", owned = "rts-world.port-owned",
                                       capturing = "rts-world.port-capturing"} or nil
    local r = mapgen.add_ruin(surface, {x = f.x, y = f.y}, {stock = stock, keys = keys, kind = f.type})
    f.ok = r ~= nil
  elseif f.type == "city_state" then
    f.ok = world.found_city_state(surface, W, f.site) ~= nil
  end
  W.placed = (W.placed or 0) + 1
end

world.build_features = build_features -- Phase 5 M3 world3: scripts/worldgen.lua
world.place_feature = place_feature
world.CLEAR_TYPES = CLEAR_TYPES

--- Generate the world on `surface` (created with world.map_gen_settings(plan)). Phase 5 M3 world3: the generation is
--- scripts/worldgen.lua's (worldgen.start: the blocking core, cleared spawn areas, the start kits, the rest of the
--- map in the background). Writes storage.world.
function world.apply(surface, P)
  local worldgen = loaded("scripts.worldgen")
  assert(worldgen, "world.apply: scripts/worldgen.lua is not loaded")
  return worldgen.start(surface, P)
end

---------------------------------------------------------------------------
-- Background fill: placement on chunk generation, completion, post-check on real tiles
---------------------------------------------------------------------------
local post_step -- forward

--- The background fill is complete (scripts/worldgen.lua calls it): QA counts, the unplaced count, then the real-tile
--- check over the next ticks.
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

world.finish_fill = finish_fill -- Phase 5 M3 world3: scripts/worldgen.lua (on_chunk_generated moved there)

-- Rows of the real-tile grid per tick (n = 256 at 2048: 32 ticks of 2,048 get_tile calls).
world.POST_ROWS = 8
-- Phase 5 M3 world3: the real-tile check in slices that keep every tick short on a 4096 map: grid rows for at most
-- POST_CELLS cells per tick (8 rows at 2048, 4 at 4096), class counts on the way, the flood POST_BFS cells per tick.
world.POST_CELLS = 2048
world.POST_BFS = 20000

post_step = function(W)
  local surface = game.surfaces[W.surface]
  local Q = W.post
  if not surface then W.post = nil return end
  local n, cell, H = Q.n, world.CELL, W.size / 2
  Q.counts = Q.counts or {[LAND] = 0, [WATER] = 0, [MOUNTAIN] = 0, [FORD] = 0, [MARSH] = 0}
  local rows = max(1, min(world.POST_ROWS, floor(world.POST_CELLS / n)))
  if Q.row < n then
    for _ = 1, rows do
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
        Q.counts[c] = Q.counts[c] + 1
      end
      Q.row = Q.row + 1
    end
    return
  end
  -- flood from the first spawn on the real grid (bfs(), resumable: POST_BFS cells per tick)
  local G = {n = n, cell = cell, half = H, cls = Q.cls}
  local P = W.plan
  local B = Q.bfs
  if not B then
    local start = cell_of(G, P.spawns[1])
    B = {d = {}, q = {}, head = 1, tail = 0}
    if start and passable(Q.cls[start]) then
      B.d[start], B.q[1], B.tail = 1, start, 1
    end
    Q.bfs = B
  end
  do
    local cls, d, q = Q.cls, B.d, B.q
    local head, tail = B.head, B.tail
    local stop = head + world.POST_BFS
    while head <= tail and head < stop do
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
    B.head, B.tail = head, tail
    if head <= tail then return end
  end
  local d1 = B.d
  local bad, targets = {}, 0
  local function target(label, p)
    targets = targets + 1
    if not path_tiles(G, d1, p) then bad[#bad + 1] = label end
  end
  for _, sp in ipairs(P.spawns) do target("spawn " .. sp.force, sp) end
  for _, d in ipairs(P.deposits) do target("deposit " .. d.id .. " " .. d.role, d) end
  for _, reg in ipairs(P.regions) do target("region " .. reg.id, reg.center) end
  for _, s in ipairs(P.sites) do target(s.kind .. " " .. util.pos_str(s.position), s.position) end
  local cells = {}
  for c, v in pairs(Q.counts) do cells[world.CLASS[c]] = v end
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
  local SITE_RGB = {ruin = {255, 140, 0}, port = {0, 255, 255}, city_site = {255, 230, 0}, city_state = {255, 0, 0},
                    uranium = {80, 255, 80}, rare = {255, 120, 220}} -- Phase 5 M2 world: city-states, uranium, rare
  for _, s in ipairs(P.sites) do
    if s.kind ~= "oil" then
      dot(s.position, SITE_RGB[s.kind] or {255, 230, 0}, s.kind == "city_site" and 0 or (s.kind == "city_state" and 2 or 1))
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

-- Phase 5 M3 world3: the fill watchdog moved to scripts/worldgen.lua (it re-requests the chunks in flight).

---------------------------------------------------------------------------
-- Phase 5 M2 world: city-states (D7), their garrison, the Geology gate on uranium
---------------------------------------------------------------------------
world.NEUTRAL = "rts-neutral"
world.NEUTRAL_COLOR = {r = 0.78, g = 0.76, b = 0.86, a = 1} -- chart names of city-states

--- The city-states' force, created idempotently (other M2 packages do the same): at war with every match force, at
--- peace with the vanilla forces (the ruins are "neutral"), its chart not shared.
function world.neutral_force()
  local f = game.forces[world.NEUTRAL] or game.create_force(world.NEUTRAL)
  f.share_chart = false
  f.ai_controllable = false
  local m = storage.match
  for _, name in ipairs((m and m.forces) or {}) do
    local o = game.forces[name]
    if o and o ~= f then
      f.set_friend(o, false)
      o.set_friend(f, false)
      f.set_cease_fire(o, false)
      o.set_cease_fire(f, false)
    end
  end
  for _, vanilla in pairs({"enemy", "player", "neutral"}) do
    local v = game.forces[vanilla]
    if v then
      f.set_cease_fire(v, true)
      v.set_cease_fire(f, true)
    end
  end
  return f
end

-- Garrison slots around a City Center: the four diagonals first, then the axes, then the eighths between them.
local GARRISON_ANGLES = {45, 135, 225, 315, 0, 90, 180, 270, 22.5, 112.5, 202.5, 292.5, 67.5, 157.5, 247.5, 337.5}

local function add_turret(surface, rec, c)
  local name = world.CS.turret
  if not prototypes.entity[name] then return nil end
  for n = (rec.slot or 0) + 1, #GARRISON_ANGLES do
    rec.slot = n
    local a = math.rad(GARRISON_ANGLES[n])
    local p = {x = floor(c.position.x + math.cos(a) * world.CS.ring + 0.5),
               y = floor(c.position.y + math.sin(a) * world.CS.ring + 0.5)}
    if not surface.can_place_entity({name = name, position = p, force = world.NEUTRAL}) then
      p = surface.find_non_colliding_position(name, p, 3, 1, true)
    end
    local t = p and surface.create_entity({name = name, position = p, force = world.NEUTRAL, raise_built = true,
                                           create_build_effect_smoke = false})
    if t then
      local ammo = t.get_inventory(defines.inventory.turret_ammo)
      if ammo then ammo.insert({name = "firearm-magazine", count = 10}) end
      rec.turrets[#rec.turrets + 1] = t
      rec.added = (rec.added or 0) + 1
      return t
    end
  end
  return nil
end

-- The City Center's network gets its region's goods (balance.nation.world.city_state.stock by anchor) and the
-- garrison's magazines.
local function stock_city_state(rec, c)
  local net = c.entity.valid and c.entity.logistic_network
  local goods = world.CS.stock[rec.anchor] or world.CS.stock.pass or {}
  local put = {}
  local function insert(item, n)
    if not (prototypes.item[item] and n > 0) then return end
    local done = 0
    if net and net.valid then done = net.insert({name = item, count = n}) end
    if done < n then
      for _, s in pairs(c.entity.surface.find_entities_filtered({name = "rts-stockpile", position = c.position, radius = 8,
                                                                 force = world.NEUTRAL})) do
        done = done + s.insert({name = item, count = n - done})
        if done >= n then break end
      end
    end
    put[#put + 1] = item .. " " .. done
  end
  for _, g in ipairs(goods) do insert(g[1], g[2]) end
  insert("firearm-magazine", world.CS.ammo_keep)
  return put
end

--- Found the city-state of site `si` (cities.found for rts-neutral with archetype "city_state"): its City Center, the
--- region's goods in its stockpiles, world.CS.garrison turrets. Returns the city id or nil.
function world.found_city_state(surface, W, si)
  local s = W.sites[si]
  local cities = loaded("scripts.cities")
  if not (s and cities and cities.found) then return nil end
  W.city_states = W.city_states or {}
  world.neutral_force()
  local id = cities.found(world.NEUTRAL, s.position, {archetype = "city_state", tier = world.CS.tier, title = s.name,
                                                      why = "(city-state " .. s.label .. ")"})
  local rec = {site = si, name = s.name, label = s.label, anchor = s.anchor, position = s.position, city_id = id,
               founded = game.tick, turrets = {}}
  W.city_states[#W.city_states + 1] = rec
  s.city_id = id
  local c = id and cities.get(id)
  local put = {}
  if c then
    rec.center = c.center
    put = stock_city_state(rec, c)
    for _ = 1, world.CS.garrison do add_turret(surface, rec, c) end
  end
  util.log("world: city-state %s (%s) at %s: city %s, %d turrets, stock [%s]", s.label, tostring(s.anchor),
    util.pos_str(s.position), tostring(id), #rec.turrets, table.concat(put, ", "))
  return id
end

-- Phase 5 M2 integration: a city-state's people neither eat nor grow while it is free; the nation that captures it finds
-- its granary (balance.nation.world.city_state.food in the City Center's network at the capture), else the captured
-- city starved at its first needs pass, long before the captor's food line reached it. Given at the capture, not at the
-- founding: rations spoil in 15 minutes with Space Age.
events.on_signal("rts_city_captured", function(d)
  if not (d and d.from == world.NEUTRAL and d.city_id) then return end
  local cities = loaded("scripts.cities")
  local c = cities and cities.get(d.city_id)
  if not (c and c.archetype == "city_state" and c.entity and c.entity.valid) then return end
  local net = c.entity.logistic_network
  local put = {}
  for _, g in ipairs(CS.food or {}) do
    if prototypes.item[g[1]] and net and net.valid then
      local n = net.insert({name = g[1], count = g[2]})
      put[#put + 1] = g[1] .. " " .. n
    end
  end
  util.log("world: city-state city %d captured by %s: granary [%s]", d.city_id, tostring(d.to), table.concat(put, ", "))
end)

--- City-state records {site, name, label, anchor, position, city_id, center, founded, turrets}.
function world.city_states() return (storage.world and storage.world.city_states) or {} end

-- Garrison growth (4 + 1 per CS.garrison_every, at most CS.garrison_max turrets ever added; a destroyed turret is not
-- replaced) and the magazine stock, for every city-state rts-neutral still holds.
events.on_nth_tick(600, function()
  local W = storage.world
  if not (W and W.city_states and #W.city_states > 0) then return end
  local surface = game.surfaces[W.surface]
  local cities = loaded("scripts.cities")
  if not (surface and cities) then return end
  for _, rec in ipairs(W.city_states) do
    local c = rec.city_id and cities.get(rec.city_id)
    if c and c.force == world.NEUTRAL and c.entity and c.entity.valid then
      local want = min(world.CS.garrison_max, world.CS.garrison + floor((game.tick - rec.founded) / world.CS.garrison_every))
      if (rec.added or 0) < want and add_turret(surface, rec, c) then
        util.log("world: city-state %s garrison +1 (%d turrets added)", rec.label, rec.added)
      end
      local net = c.entity.logistic_network
      if net and net.valid then
        local have = net.get_item_count("firearm-magazine")
        if have < world.CS.ammo_keep / 2 then net.insert({name = "firearm-magazine", count = world.CS.ammo_keep - have}) end
      end
    end
  end
end)

-- Geology (docs/PHASE5-M2.md §3): a mining drill whose mining area reaches uranium is refused until the force has
-- researched world.URANIUM.tech. Players' ghosts and robot builds, like territory.lua's rules; script placements are
-- trusted.
local GEOLOGY_EVENTS = {[defines.events.on_built_entity] = "player", [defines.events.on_robot_built_entity] = "robot"}
function world.geology_check(entity, e)
  local who = GEOLOGY_EVENTS[e.name]
  if not who then return true end
  local W = storage.world
  if not (W and W.plan) then return true end
  local ghost = entity.type == "entity-ghost"
  local name = ghost and entity.ghost_name or entity.name
  local proto = prototypes.entity[name]
  if not (proto and proto.type == "mining-drill" and proto.mining_drill_radius) then return true end
  local research = loaded("scripts.research")
  local force_name = entity.force.name
  if research and research.has(force_name, world.URANIUM.tech) then return true end
  local r = proto.mining_drill_radius
  local p = entity.position
  local surface = entity.surface
  if surface.count_entities_filtered({area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}}, name = world.URANIUM.name,
                                      limit = 1}) == 0 then
    return true
  end
  local item
  if not ghost then
    local items = entity.prototype.items_to_place_this
    item = items and items[1]
  end
  entity.destroy()
  local economy = loaded("scripts.economy")
  if item and economy then economy.give(force_name, item.name, item.count or 1) end
  local player = (e.player_index or 0) > 0 and game.get_player(e.player_index)
  if player and player.valid then
    player.create_local_flying_text({text = {"rts-world.geology-required"}, position = p, surface = surface,
                                     color = {1, 0.4, 0.3}})
  end
  util.log("world: refused %s%s of %s at %s: uranium needs %s (%s)", name, ghost and " ghost" or "", force_name,
    util.pos_str(p), world.URANIUM.tech, who)
  return false
end
buildings.on_build_check(world.geology_check)

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
local function W() return storage.world end

local function region_record(position)
  local w = W()
  if not (w and w.region_grid and position) then return nil end
  local x, y = util.xy(position)
  if not (x and y) then return nil end
  local n = w.region_grid_n
  local i = max(0, min(n - 1, floor((x + w.size / 2) / 32)))
  local j = max(0, min(n - 1, floor((y + w.size / 2) / 32)))
  return w.regions[w.region_grid[j * n + i + 1]]
end

--- Phase 5 M2 world: shares of a region's land by owner {[force] = 0..1}, sampled at the centre of every 32-tile cell
--- of the region from territory.owner_at; cached until the territory module finishes its next job.
function world.owner_share(reg)
  local w = W()
  local territory = loaded("scripts.territory")
  if not (w and reg and territory and territory.owner_at) then return {} end
  local T = storage.territory
  local version = (T and T.active and T.stats and T.stats.jobs or -1) .. ":" .. tostring(T and T.match_id)
  if reg.owner_share and reg.share_version == version then return reg.owner_share end
  local n, H = w.region_grid_n, w.size / 2
  local bb = reg.bbox or {x0 = -H, y0 = -H, x1 = H, y1 = H}
  local i0, i1 = max(0, floor((bb.x0 + H) / 32)), min(n - 1, floor((bb.x1 - 0.01 + H) / 32))
  local j0, j1 = max(0, floor((bb.y0 + H) / 32)), min(n - 1, floor((bb.y1 - 0.01 + H) / 32))
  local counts, total = {}, 0
  for j = j0, j1 do
    for i = i0, i1 do
      if w.region_grid[j * n + i + 1] == reg.id then
        total = total + 1
        local owner = territory.owner_at({x = -H + i * 32 + 16, y = -H + j * 32 + 16})
        if owner then counts[owner] = (counts[owner] or 0) + 1 end
      end
    end
  end
  local share = {}
  for f, c in pairs(counts) do share[f] = total > 0 and c / total or 0 end
  reg.owner_share, reg.share_version = share, version
  return share
end

--- The region at a position, or nil (no world): {id, name, label, kind, climate, role, center, bbox, resources, sites,
--- owner?, owner_share}.
function world.region_at(position)
  local reg = region_record(position)
  if reg then world.owner_share(reg) end
  return reg
end

--- Phase 5 M2 world: the localised name of the region at a position, or nil (no world, no position). Alerts use it:
--- "Iron Hills: hauler lost" (scripts/hud.lua).
function world.place_name(position)
  local reg = region_record(position)
  return reg and reg.name or nil
end

--- Phase 5 M2 world: is territory cell (cx, cy) claimable? 0-based indices of the territory grid (8 tiles, origin at
--- the map's top-left corner), which are the world grid's cells. False outside a world.
function world.claimable(cx, cy)
  local w = W()
  local C = w and w.plan and w.plan.claimable
  if not C or cx < 0 or cy < 0 or cx >= C.n or cy >= C.n then return false end
  return string.byte(C.rows[cy + 1], cx + 1) == 1
end

--- Phase 5 M2 world: number of claimable cells of the world, or nil (no world).
function world.claimable_count()
  local w = W()
  local C = w and w.plan and w.plan.claimable
  return C and C.count or nil
end

--- Phase 5 M2 world: {[force] = {home_specialty = region id, specialty = kind, lacks = {ore, ...}, specialty_path}}.
function world.scarcity()
  local w = W()
  return (w and w.plan and w.plan.scarcity) or {}
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
  world.w2_checks(check, "")
end

--- Phase 5 M2 world: the M2 world checks (docs/PHASE5-M2.md §4 World) of the running world through check(name, ok,
--- fmt, ...); `tag` is appended to every name (the seed matrix). City-state land needs the territory queue done.
function world.w2_checks(check, tag)
  local w = W()
  if not (w and w.plan and w.plan.scarcity) then return end
  local P = w.plan
  tag = tag or ""
  -- each nation lacks at least one basic ore beyond its start kit; its specialty 300-700 path tiles out, nearest
  local lack_ok, spec_ok, parts, sparts = true, true, {}, {}
  -- Phase 5 M3 world3: an extended plan's home distances stop growing at 3072's (balance.nation.world3.home_scale_max)
  local spec_lo, spec_hi = 300 * P.size / 2048, 700
  if P.xl then
    local kk = P.size / 2048
    local hs = world.W3.home_scale_max or 1.5
    spec_lo, spec_hi = 300 * min(kk, hs), 700 * max(1, kk / hs)
  end
  for _, sp in ipairs(P.spawns) do
    local r = P.scarcity[sp.force]
    if #r.lacks < 1 then lack_ok = false end
    parts[#parts + 1] = string.format("%s (%s) lacks %s", sp.force, tostring(r.specialty), table.concat(r.lacks, " "))
    local okp = r.specialty_path and r.specialty_path >= spec_lo and r.specialty_path <= spec_hi
      and (not r.specialty_other or r.specialty_other > r.specialty_path)
    if not okp then spec_ok = false end
    sparts[#sparts + 1] = string.format("%s %s/%s%s", sp.force, tostring(r.specialty_path), tostring(r.specialty_other),
      okp and "" or " BAD")
  end
  check("world_lacks" .. tag, lack_ok, "%s", table.concat(parts, "; "))
  check("world_specialty" .. tag, spec_ok, "path tiles own/nearest other: %s", table.concat(sparts, "; "))
  -- each scarce type reachable by two nations within +-scarce_fair
  local fair_ok, fparts = true, {}
  for kind, T in pairs(P.fair.types) do
    if not T.ok then fair_ok = false end
    local worst = 0
    for _, x in ipairs(T.deposits) do worst = max(worst, x.diff) end
    fparts[#fparts + 1] = string.format("%s %d deposit(s) worst %.1f%%%s", kind, #T.deposits, 100 * worst,
      T.ok and "" or " UNFAIR")
  end
  table.sort(fparts)
  check("world_scarce_fair" .. tag, fair_ok and #fparts > 0, "%s", table.concat(fparts, "; "))
  -- named chokes
  local named, by = 0, {}
  for _, c in ipairs(P.chokes) do
    if c.name and c.label then named = named + 1 end
    by[c.kind] = (by[c.kind] or 0) + 1
  end
  -- docs/PHASE5-M2.md §4: at least 5 on a 4-nation map; smaller maps: every planned crossing named
  local need = P.nations >= 4 and 5 or #P.crossings
  check("world_chokes" .. tag, named >= need and named > 0, "%d named chokes (need %d) %s", named, need, serpent.line(by))
  -- city-states: planned count, each with a City Center (live, registered) and land
  local cities = loaded("scripts.cities")
  local territory = loaded("scripts.territory")
  local want = count_of(world.W2.city_states, world.W3.city_states, P.nations, 5) -- Phase 5 M3 world3: 5-6 nations
  local planned, live, cparts = 0, 0, {}
  for _, s in ipairs(P.sites) do if s.kind == "city_state" then planned = planned + 1 end end
  for _, rec in ipairs(w.city_states or {}) do
    local c = rec.city_id and cities and cities.get(rec.city_id)
    local cells = (c and territory) and territory.city_cells(c.id) or 0
    local ok = c ~= nil and c.entity ~= nil and c.entity.valid and cells > 0
    if ok then live = live + 1 end
    cparts[#cparts + 1] = string.format("%s %s %s %d cells %d turrets", rec.label, tostring(rec.anchor),
      c and c.force or "-", cells, #rec.turrets)
  end
  local lo = P.nations >= 4 and 5 or want - 1
  if P.nations > 4 then lo = want - 1 end -- Phase 5 M3 world3
  check("world_city_states" .. tag, planned >= lo and planned <= max(want, 6) and live == planned,
    "%d planned (want %d), %d with a City Center and land: %s", planned, want, live, table.concat(cparts, "; "))
  -- ports, fair by path
  local F = P.fair.ports
  local max_ports = max(4, count_of(nil, world.W3.ports, P.nations, 4)) -- Phase 5 M3 world3: 5-6 nations
  check("world_ports" .. tag, F.count >= 2 and F.count <= max_ports and F.spread <= world.PORTS.spread_max,
    "%d ports, nearest-port path spread %.3f (max %.2f) %s", F.count, F.spread, world.PORTS.spread_max,
    serpent.line(F.nearest))
  -- ruins, uranium, rare deposits
  local n = {}
  local far = true
  for _, s in ipairs(P.sites) do
    n[s.kind] = (n[s.kind] or 0) + 1
    if s.kind == "ruin" and nearest_spawn_dist(P, s.position) < world.RUINS.min_spawn then far = false end
  end
  -- Phase 5 M3 world3: an extended plan's counts (balance.nation.world3) widen the M2 ranges
  local ruin_hi = max(12, count_of(world.RUINS.count, world.W3.ruins, P.size, 12))
  local uranium_hi = max(2, count_of(world.URANIUM.count, world.W3.uranium, P.nations, 2))
  local rare_hi = max(8, count_of(world.RARE.count, world.W3.rare, P.size, 8))
  check("world_sites" .. tag, (n.ruin or 0) >= 8 and (n.ruin or 0) <= ruin_hi and far and (n.uranium or 0) >= 1
    and (n.uranium or 0) <= uranium_hi and (n.rare or 0) >= 4 and (n.rare or 0) <= rare_hi,
    "ruins %d (all >= %d tiles from spawns: %s), uranium %d, rare %d, ports %d, city sites %d", n.ruin or 0,
    world.RUINS.min_spawn, tostring(far), n.uranium or 0, n.rare or 0, n.port or 0, n.city_site or 0)
  -- region names for every spawn; chart labels for every region (scripts/strategic.lua)
  local names_ok, nparts = true, {}
  for _, sp in ipairs(P.spawns) do
    local reg = world.region_at(sp)
    if not (reg and reg.name and reg.label) then names_ok = false end
    nparts[#nparts + 1] = sp.force .. " " .. (reg and reg.label or "NONE")
  end
  check("world_region_names" .. tag, names_ok, "%s", table.concat(nparts, "; "))
  local strategic = loaded("scripts.strategic")
  local lab_ok, lparts = strategic ~= nil, {}
  local m = storage.match
  for _, f in ipairs((m and m.forces) or {}) do
    local cnt = strategic and strategic.counts(f) or {}
    if (cnt.regions or 0) < #P.regions then lab_ok = false end
    lparts[#lparts + 1] = string.format("%s regions %d/%d chokes %d cities %d total %d", f, cnt.regions or 0, #P.regions,
      cnt.chokes or 0, cnt.cities or 0, cnt.total or 0)
  end
  check("world_chart_labels" .. tag, lab_ok, "%s", table.concat(lparts, "; "))
  -- claimable cells (territory.share's denominator): CLAIM_RANGE of the map (measured 88-93 %: the worlds are
  -- about 92 % land); territory's per-force counts agree with a recount
  local C = P.claimable
  local frac = C and C.count / C.total or 0
  local T = storage.territory
  local recount_ok, rparts = true, {}
  if C and T and T.active and T.w == C.n then
    local by = {}
    for cy = 0, C.n - 1 do
      local orow, crow = T.owner[cy + 1], C.rows[cy + 1]
      for cx = 1, C.n do
        local o = string.byte(orow, cx)
        if o > 0 and string.byte(crow, cx) == 1 then by[o] = (by[o] or 0) + 1 end
      end
    end
    for fid, name in ipairs(T.fnames) do
      local have = (T.claim and T.claim[fid]) or 0
      if have ~= (by[fid] or 0) then recount_ok = false end
      rparts[#rparts + 1] = string.format("%s %d/%d", name, have, by[fid] or 0)
    end
  end
  check("world_claimable" .. tag, C ~= nil and frac >= world.CLAIM_RANGE[1] and frac <= world.CLAIM_RANGE[2] and recount_ok,
    "%.1f %% of %d cells claimable; owned claimable cells (territory/recount): %s", 100 * frac, C and C.total or 0,
    table.concat(rparts, ", "))
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
        b.spur and "spur " or (b.massif and "massif " or ""), b.kind, b.id, tostring(b.label),
        table.concat(b.ws or {b.w}, "/"), tostring(b.min_thick), util.pos_str(b.points[1]), util.pos_str(b.points[#b.points]))
    end
    for _, c in ipairs(P.chokes) do
      lines[#lines + 1] = string.format("[rts] world: choke %d %s %s at %s, width %d (sampled %s), regions %s/%s",
        c.id or 0, c.kind, c.label, util.pos_str(c.position), c.width, tostring(c.measured_width),
        tostring(c.regions and c.regions[1]), tostring(c.regions and c.regions[2]))
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
    -- Phase 5 M2 world
    for _, s in ipairs(P.sites) do
      if s.kind == "city_state" or s.kind == "port" or s.kind == "uranium" or s.kind == "rare" then
        lines[#lines + 1] = string.format("[rts] world: %s %s at %s (region %s)%s", s.kind, s.label or s.rare or s.resource
          or "", util.pos_str(s.position), tostring(s.region), s.city_id and (" city " .. s.city_id) or "")
      end
    end
    for force, r in pairs(P.scarcity or {}) do
      lines[#lines + 1] = string.format("[rts] world: scarcity %s: specialty %s (region %s, %s path tiles), lacks %s",
        force, tostring(r.specialty), tostring(r.home_specialty), tostring(r.specialty_path and math.floor(r.specialty_path)),
        table.concat(r.lacks, ", "))
    end
    if P.fair then
      for kind, T in pairs(P.fair.types) do
        lines[#lines + 1] = string.format("[rts] world: scarce %s %s", kind, T.ok and "fair" or "UNFAIR")
      end
      lines[#lines + 1] = string.format("[rts] world: ports %d, nearest-port path spread %.3f", P.fair.ports.count,
        P.fair.ports.spread)
    end
    for _, rec in ipairs(w.city_states or {}) do
      local live = 0
      for _, t in ipairs(rec.turrets) do if t.valid then live = live + 1 end end
      lines[#lines + 1] = string.format("[rts] world: city-state %s city %s, %d/%d turrets", rec.label,
        tostring(rec.city_id), live, rec.added or 0)
    end
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
