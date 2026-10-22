-- Phase 5 M3 war2: fort belts (docs/PHASE5-M3.md D5, section 3 "fronts.lua / belts.lua / trainswar.lua"; study
-- docs/research/scale/war-ai-performance.md 2.4; notes docs/qa/phase5-war2-notes.md). Nation mode only.
--
--   belts.plan(force, points, opts) -> plan_id | nil, reason   a 2-6 point polyline inside own land becomes a plan of
--                                    ghosts; opts.aa (default true), opts.depot (default true), opts.why (log)
--   belts.layout(force, points, opts) -> layout | nil, reason   the same without placing anything (the tool's preview):
--                                    {entries = {{name, x, y, dir, kind}}, need = {[item] = n}, length, skipped}
--   belts.ghosts(plan_id) -> n       ghosts placed so far (built ones included)
--   belts.cancel(plan_id)            the ghosts not built yet go; what stands stays
--   belts.get(plan_id), belts.of(force) -> plans
--   belts.plan_front(force, segment_id, opts) -> plan_id | nil, reason   a belt along a front segment's chord, opts.behind
--                                    (16) tiles into own land (for the AI's war council)
--
-- Layout: the polyline is snapped to tile centres and rasterised 4-connected (a wall line without diagonal gaps). On
-- every tile of own land: a wall (rts-wall), or a gate (rts-gate) where a straight orthogonal rail crosses it (no wall
-- on curved or diagonal track or on rail supports: a gap); a turret (rts-turret) every turret_every tiles of
-- polyline, turret_behind tiles behind it; from Age II an AA turret every aa_every tiles (m3-air's prototype, looked up
-- by name, and only when the force has its recipe); a field depot depot_behind tiles behind the middle. "Behind" is
-- away from the enemy: the back side of the force's front segment nearest the belt (within 600 tiles), else the side of the
-- City Center nearest the middle of the belt. Anything outside own land, on water or on a building is left out
-- ("skipped").
-- Building: the ghosts are placed ghosts_per_tick per tick, then the belt crew revives build_rate ghosts per second in
-- plan order (depot, turrets, AA, gates, walls), each debiting its item from the nearest own city's network (then the
-- next nearest); a missing item waits (alert "belt-waiting" once per item) and the crew takes the next entry it can
-- pay. Hub robots, depot robots and the Commander's field construction build the same ghosts (they pay from their own
-- network); a ghost they built counts as built, a ghost someone removed as skipped. Trees, rocks and cliffs on a
-- footprint are cleared before the revive. A new turret gets `magazines` magazines from the same network and the
-- priority list `priority` (LuaEntity.set_priority_target: artillery and siege walkers first); the belt's field depot
-- keeps 100 magazines and tops its belt's turrets up every feed.period ticks.
-- Tool (F with no unit selected, or the Fort belt button of the build menu): right-clicks add points (own land only),
-- the panel shows the length and the bill, AA / depot checkboxes, Undo, Build, Cancel; the preview is drawn for the
-- player in the game view and the map view. Fortification (Age I) unlocks the tool and the gate.
--
-- Owns storage.belts = {next_id, plans = {[id] = P}, tools = {[player_index] = {points, aa, depot, objs, reason}},
--   stats = {planned, built, cancelled, revived, by_robots, skipped}}; P = {id, force, points, opts, mid, length,
--   entries = {{name, item, x, y, dir, kind, status = "planned" | "ghost" | "built" | "skipped", ghost, entity}},
--   placed, built, skipped, cursor, credit, nets = {city center unit numbers}, need, debited = {[item] = n},
--   state = "laying" | "building" | "built" | "cancelled", created, done, waiting, alerted = {[item] = true},
--   depot (LuaEntity)}. Log lines "[rts] belt: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local logistics = require("scripts.logistics")
local match = require("scripts.match")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local supply = require("scripts.supply")
local production = require("scripts.production")
local balance = require("balance")
local research
do
  local ok, mod = pcall(require, "scripts.research")
  if ok and type(mod) == "table" then research = mod end
end

local belts = {}
local BB = balance.nation.belts

belts.FRAME = "rts_belts_tool"
belts.BUILD_PERIOD = 15
belts.AMMO = "firearm-magazine"
belts.DEPOT_KEEP = 100     -- magazines the belt's field depot keeps
belts.MAX_FAILS = 20       -- a ghost that will not revive this many times is skipped
belts.SCAN = 64            -- entries the crew looks at per pass for one it can pay
local P = "rts_belts_"
local WIDTH = 380
belts.TOP = 196 -- GUI units: below the HUD strip (8 + 96) and its three alert lines, centred

-- Fortification (Age I): the gate and the tool. The gate is a wall for the registry (not a target of re-targets).
buildings.KIND_BY_NAME[BB.gate] = "wall"
if research then
  research.EFFECTS[BB.tech] = {unlock = {BB.gate}, flag = "fortification"}
  research.LOCKS[BB.gate] = BB.tech
  if research.NATION_ONLY then research.NATION_ONLY[BB.tech] = true end
end

local floor, abs, sqrt, max, min = math.floor, math.abs, math.sqrt, math.max, math.min
local D = defines.direction
local RAIL_TYPES = {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail", "legacy-straight-rail",
                    "legacy-curved-rail", "rail-ramp", "rail-support"}
local CLEAR_TYPES = {"tree", "simple-entity", "cliff"}
local ORDER = {depot = 1, turret = 2, aa = 3, gate = 4, wall = 5}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.belts
  if not s then
    s = {}
    storage.belts = s
  end
  s.next_id = s.next_id or 1
  s.plans = s.plans or {}
  s.tools = s.tools or {}
  s.stats = s.stats or {planned = 0, built = 0, cancelled = 0, revived = 0, by_robots = 0, skipped = 0}
  return s
end

function belts.init() S() end

local function nation()
  local m = storage.match
  return m ~= nil and m.phase == "running" and m.config ~= nil and m.config.mode == "nation"
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function belts.get(id) return S().plans[id] end

--- Plans of a force, oldest first.
function belts.of(force_name)
  local out = {}
  local s = S()
  for _, id in ipairs(sorted_keys(s.plans)) do
    if s.plans[id].force == force_name then out[#out + 1] = s.plans[id] end
  end
  return out
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------
local function round(v) return floor(v + 0.5) end

local item_cache = {}
local function item_of(name)
  local it = item_cache[name]
  if it == nil then
    local p = prototypes.entity[name]
    local list = p and p.items_to_place_this
    it = list and list[1] and list[1].name or false
    item_cache[name] = it
  end
  return it or nil
end

--- The AA turret this force may put into a belt now, or nil (m3-air's prototype exists, Age II, its recipe enabled).
function belts.aa_name(force_name)
  local name = BB.aa_turret
  if not (name and prototypes.entity[name]) then return nil end
  local l = package.loaded
  local ages = l["__" .. script.mod_name .. "__/scripts/ages.lua"] or l["scripts.ages"]
  if ages and ages.of and ages.of(force_name) < BB.aa_age then return nil end
  -- Aviation unlocks it (m3-air: research.is_unlocked(force, "rts-aa-turret")); without research, its recipe
  if research and research.is_unlocked then
    if not research.is_unlocked(force_name, name) then return nil end
  else
    local force = game.forces[force_name]
    local item = item_of(name)
    local recipe = force and item and force.recipes[item]
    if recipe and not recipe.enabled then return nil end
  end
  return name
end

-- Own city centres sorted by distance from `pos`: {{un, position, d}}.
local function city_centres(force_name, pos)
  local out = {}
  for _, c in ipairs(cities.for_force(force_name)) do
    local brec = c.center and buildings.get(c.center)
    if brec then
      local p = brec.entity.position
      out[#out + 1] = {un = c.center, position = {x = p.x, y = p.y}, d = util.distance(p, pos)}
    end
  end
  table.sort(out, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.un < b.un
  end)
  return out
end

-- Polyline helpers: segments with cumulative length.
local function segments_of(pts)
  local segs, total = {}, 0
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local dx, dy = b.x - a.x, b.y - a.y
    local len = sqrt(dx * dx + dy * dy)
    if len > 0.01 then
      segs[#segs + 1] = {a = a, b = b, ux = dx / len, uy = dy / len, len = len, s0 = total}
      total = total + len
    end
  end
  return segs, total
end

local function point_at(segs, s)
  for _, g in ipairs(segs) do
    if s <= g.s0 + g.len or g == segs[#segs] then
      local t = math.max(0, math.min(g.len, s - g.s0))
      return {x = g.a.x + g.ux * t, y = g.a.y + g.uy * t}, g
    end
  end
  return nil
end

local function tile_box(x, y) return {{x + 0.08, y + 0.08}, {x + 0.92, y + 0.92}} end

-- What stands on a wall tile: "free", "gate" (with the gate direction) or "skip".
local function rail_check(surface, x, y)
  local found = surface.find_entities_filtered({area = tile_box(x, y), type = RAIL_TYPES})
  if #found == 0 then return "free" end
  local dir
  for _, r in ipairs(found) do
    if r.type ~= "straight-rail" and r.type ~= "legacy-straight-rail" then return "skip" end
    local d = r.direction
    local horizontal = d == D.east or d == D.west
    local vertical = d == D.north or d == D.south
    if not (horizontal or vertical) then return "skip" end
    local gd = horizontal and D.north or D.east -- a gate across the track (the wall line crosses it)
    if dir and dir ~= gd then return "skip" end
    dir = gd
  end
  return "gate", dir
end

local function can_place(surface, force_name, name, x, y, dir)
  return surface.can_place_entity({name = name, position = {x, y}, direction = dir, force = force_name,
    build_check_type = defines.build_check_type.manual_ghost, forced = true})
end

-- A footprint centre on the tile grid for an entity of `name` around (px, py).
local function snapped(name, px, py)
  local p = prototypes.entity[name]
  local w, h = p and p.tile_width or 1, p and p.tile_height or 1
  local x = (w % 2 == 0) and round(px) or (floor(px) + 0.5)
  local y = (h % 2 == 0) and round(py) or (floor(py) + 0.5)
  return x, y
end

--- The belt for a polyline without placing it: {entries, need, length, skipped, mid, nets} or nil, reason
--- ("not-nation", "no-tech", "points", "not-own", "too-long", "no-city").
function belts.layout(force_name, points, opts)
  opts = opts or {}
  if not nation() then return nil, "not-nation" end
  if research and not opts.ignore_tech and not research.has(force_name, BB.tech) then return nil, "no-tech" end
  if type(points) ~= "table" or #points < BB.min_points or #points > BB.max_points then return nil, "points" end
  local pts = {}
  for i, p in ipairs(points) do
    local x, y = util.xy(p)
    pts[i] = {x = floor(x) + 0.5, y = floor(y) + 0.5}
    if territory.owner_at(pts[i]) ~= force_name then return nil, "not-own" end
  end
  local segs, length = segments_of(pts)
  if #segs == 0 then return nil, "points" end
  if length > BB.max_length then return nil, "too-long" end
  local surface = match.surface()
  if not surface then return nil, "not-nation" end
  local mid = point_at(segs, length / 2)
  local nets = city_centres(force_name, mid)
  if #nets == 0 then return nil, "no-city" end
  local home = nets[1].position
  -- "behind" per segment: away from the enemy when a front of the force lies within 600 tiles (its segment's back
  -- vector points into own land), else towards the nearest City Center
  local l = package.loaded
  local fr = l["__" .. script.mod_name .. "__/scripts/fronts.lua"] or l["scripts.fronts"]
  local front = fr and fr.nearest and fr.nearest(force_name, mid, 600)
  for _, g in ipairs(segs) do
    local nx, ny = -g.uy, g.ux
    local cx, cy = (g.a.x + g.b.x) / 2, (g.a.y + g.b.y) / 2
    if front then
      if nx * front.back.x + ny * front.back.y < 0 then nx, ny = -nx, -ny end
    elseif nx * (home.x - cx) + ny * (home.y - cy) < 0 then
      nx, ny = -nx, -ny
    end
    g.nx, g.ny = nx, ny
  end
  local entries, seen, skipped = {}, {}, 0
  -- Phase 5 M3 integration (GUI audit): the drop tile of an own mining drill (an extractor, a rare extractor) stays
  -- free, so a belt laid across a drill's output does not stop it (a rare bonus was lost that way)
  local drop = {}
  do
    local x0, y0, x1, y1 = pts[1].x, pts[1].y, pts[1].x, pts[1].y
    for _, p in ipairs(pts) do
      x0, y0, x1, y1 = math.min(x0, p.x), math.min(y0, p.y), math.max(x1, p.x), math.max(y1, p.y)
    end
    for _, d in ipairs(surface.find_entities_filtered({area = {{x0 - 8, y0 - 8}, {x1 + 8, y1 + 8}},
                                                      type = "mining-drill", force = force_name})) do
      local dp = d.drop_position
      if dp then drop[floor(dp.x) * 65536 + floor(dp.y)] = true end
    end
  end
  local function own(x, y) return territory.owner_at({x = x, y = y}) == force_name end
  local function add(kind, name, x, y, dir)
    entries[#entries + 1] = {kind = kind, name = name, item = item_of(name), x = x, y = y, dir = dir or D.north}
  end
  -- wall line (tile coordinates are the left-top corners; entities stand at the centres)
  local function wall_tile(tx, ty)
    local key = tx * 65536 + ty
    if seen[key] then return end
    seen[key] = true
    local x, y = tx + 0.5, ty + 0.5
    if not own(x, y) or drop[key] then -- Phase 5 M3 integration: a drill's drop tile is left free
      skipped = skipped + 1
      return
    end
    local what, gdir = rail_check(surface, tx, ty)
    if what == "skip" then
      skipped = skipped + 1
    elseif what == "gate" then
      if can_place(surface, force_name, BB.gate, x, y, gdir) then
        add("gate", BB.gate, x, y, gdir)
      else
        local other = gdir == D.north and D.east or D.north
        if can_place(surface, force_name, BB.gate, x, y, other) then add("gate", BB.gate, x, y, other)
        else skipped = skipped + 1 end
      end
    elseif can_place(surface, force_name, BB.wall, x, y) then
      add("wall", BB.wall, x, y)
    else
      skipped = skipped + 1
    end
  end
  for _, g in ipairs(segs) do
    local ax, ay = floor(g.a.x), floor(g.a.y)
    local bx, by = floor(g.b.x), floor(g.b.y)
    local dx, dy = bx - ax, by - ay
    local n = max(abs(dx), abs(dy))
    local x, y = ax, ay
    wall_tile(x, y)
    for i = 1, n do
      local nx, ny = ax + round(dx * i / n), ay + round(dy * i / n)
      if nx ~= x and ny ~= y then wall_tile(nx, y) end -- keep the line 4-connected
      x, y = nx, ny
      wall_tile(x, y)
    end
  end
  -- turrets, AA, the depot behind the line
  local function behind(kind, name, s, dist)
    local p, g = point_at(segs, s)
    if not p then return end
    local x, y = snapped(name, p.x + g.nx * dist, p.y + g.ny * dist)
    if own(x, y) and can_place(surface, force_name, name, x, y) then
      add(kind, name, x, y)
    else
      skipped = skipped + 1
    end
  end
  local s = BB.turret_every / 2
  while s <= length do
    behind("turret", BB.turret, s, BB.turret_behind)
    s = s + BB.turret_every
  end
  local aa = opts.aa ~= false and belts.aa_name(force_name)
  if aa then
    s = BB.aa_every / 2
    while s <= length do
      behind("aa", aa, s, BB.aa_behind)
      s = s + BB.aa_every
    end
  end
  if opts.depot ~= false then behind("depot", BB.depot, length / 2, BB.depot_behind) end
  -- build order: depot, turrets, AA, gates, walls (stable within a kind: along the line)
  for i, e in ipairs(entries) do e.i = i end
  table.sort(entries, function(a, b)
    if ORDER[a.kind] ~= ORDER[b.kind] then return ORDER[a.kind] < ORDER[b.kind] end
    return a.i < b.i
  end)
  local need = {}
  for _, e in ipairs(entries) do
    e.i = nil
    if e.item then need[e.item] = (need[e.item] or 0) + 1 end
  end
  local net_uns = {}
  for i, c in ipairs(nets) do net_uns[i] = c.un end
  return {entries = entries, need = need, length = length, skipped = skipped, mid = mid, nets = net_uns, points = pts}
end

---------------------------------------------------------------------------
-- Plans
---------------------------------------------------------------------------
local function counts_text(t)
  local parts = {}
  for _, k in ipairs(sorted_keys(t)) do parts[#parts + 1] = string.format("%s x%d", k, t[k]) end
  return table.concat(parts, " ")
end

--- Plan a belt: validates the polyline, computes the layout and starts laying its ghosts. Returns the plan id, or nil
--- and a reason (see belts.layout; "empty" when nothing fits).
function belts.plan(force_name, points, opts)
  opts = opts or {}
  local L, why = belts.layout(force_name, points, opts)
  if not L then
    util.log("belt: plan for %s refused (%s)", tostring(force_name), tostring(why))
    return nil, why
  end
  if #L.entries == 0 then return nil, "empty" end
  local s = S()
  local id = s.next_id
  s.next_id = id + 1
  local entries = {}
  for i, e in ipairs(L.entries) do
    entries[i] = {kind = e.kind, name = e.name, item = e.item, x = e.x, y = e.y, dir = e.dir, status = "planned"}
  end
  local P_ = {id = id, force = force_name, points = L.points,
              opts = {aa = opts.aa ~= false, depot = opts.depot ~= false},
              mid = L.mid, length = L.length, entries = entries, placed = 0, built = 0, skipped = L.skipped, cursor = 1,
              credit = 0, nets = L.nets, need = L.need, debited = {}, state = "laying", created = game.tick,
              alerted = {}}
  s.plans[id] = P_
  s.laying = (s.laying or 0) + 1
  s.stats.planned = s.stats.planned + 1
  util.log("belt: plan %d of %s: %d points, %.0f tiles, %d entries [%s], %d skipped, debit city centres [%s]%s", id,
    force_name, #L.points, L.length, #entries, counts_text(L.need), L.skipped, table.concat(L.nets, " "),
    opts.why and (" (" .. opts.why .. ")") or "")
  return id
end

--- A belt along a front segment of the force (scripts/fronts.lua): its chord moved opts.behind (16) tiles into own land
--- and shortened by 8 tiles at each end. For the AI's war council. Returns the plan id or nil, reason ("no-segment").
function belts.plan_front(force_name, segment_id, opts)
  opts = opts or {}
  local l = package.loaded
  local fr = l["__" .. script.mod_name .. "__/scripts/fronts.lua"] or l["scripts.fronts"]
  local seg = fr and fr.segment(force_name, segment_id)
  if not seg then return nil, "no-segment" end
  local back = opts.behind or 16
  local dx, dy = seg.b.x - seg.a.x, seg.b.y - seg.a.y
  local len = sqrt(dx * dx + dy * dy)
  local cut = len > 24 and 8 / len or 0
  local function at(t)
    return {x = seg.a.x + dx * t + seg.back.x * back, y = seg.a.y + dy * t + seg.back.y * back}
  end
  return belts.plan(force_name, {at(cut), at(1 - cut)}, {aa = opts.aa, depot = opts.depot,
                                                         why = opts.why or ("front segment " .. segment_id)})
end

--- Ghosts placed so far (built entries included).
function belts.ghosts(id)
  local P_ = S().plans[id]
  return P_ and P_.placed or 0
end

--- Remove the ghosts of a plan that are not built yet. Returns true when the plan existed.
function belts.cancel(id, why)
  local P_ = S().plans[id]
  if not P_ then return false end
  local n = 0
  for _, e in ipairs(P_.entries) do
    if e.status == "ghost" or e.status == "planned" then
      if e.ghost and e.ghost.valid then
        e.ghost.destroy()
        n = n + 1
      end
      e.ghost, e.status = nil, "skipped"
    end
  end
  P_.state = "cancelled"
  P_.done = game.tick
  S().stats.cancelled = S().stats.cancelled + 1
  util.log("belt: plan %d of %s cancelled (%s): %d ghosts removed, %d built stay", id, P_.force, why or "-", n,
    P_.built)
  return true
end

local function lay(P_, surface, budget)
  local entries = P_.entries
  local i = P_.lay_i or 1
  while i <= #entries and budget > 0 do
    local e = entries[i]
    if e.status == "planned" then
      local g = can_place(surface, P_.force, e.name, e.x, e.y, e.dir) and surface.create_entity({name = "entity-ghost",
        inner_name = e.name, position = {e.x, e.y}, direction = e.dir, force = P_.force,
        create_build_effect_smoke = false})
      if g then
        e.ghost, e.status = g, "ghost"
        P_.placed = P_.placed + 1
      else
        e.status = "skipped"
        P_.skipped = P_.skipped + 1
      end
      budget = budget - 1
    end
    i = i + 1
  end
  P_.lay_i = i
  if i > #entries then
    P_.state = "building"
    util.log("belt: plan %d of %s: %d ghosts placed (%d skipped) in %.1f s", P_.id, P_.force, P_.placed, P_.skipped,
      (game.tick - P_.created) / 60)
  end
end

local function network_of(un)
  local brec = buildings.get(un)
  local net = brec and brec.entity.logistic_network
  return (net and net.valid) and net or nil
end

-- Take `n` of `item` from the plan's city networks, nearest first. Returns the network it came from, or nil.
local function take(P_, item, n)
  for _, un in ipairs(P_.nets) do
    local net = network_of(un)
    if net and net.get_item_count(item) >= n then
      local got = net.remove_item({name = item, count = n})
      if got >= n then return net end
      if got > 0 then net.insert({name = item, count = got}) end
    end
  end
  return nil
end

local priority_names
local function priorities()
  if not priority_names then
    priority_names = {}
    for _, name in ipairs(BB.priority) do
      if prototypes.entity[name] then priority_names[#priority_names + 1] = name end
    end
  end
  return priority_names
end

--- Give a belt turret its priority list (artillery and siege walkers first). Returns the entries set.
function belts.set_priorities(turret)
  local n = 0
  for i, name in ipairs(priorities()) do
    if pcall(turret.set_priority_target, i, name) then n = n + 1 end
  end
  return n
end

local function finish_entity(P_, e, ent, net)
  e.entity = ent
  if e.kind == "turret" then
    local inv = ent.get_inventory(defines.inventory.turret_ammo)
    if inv and net then
      local got = net.remove_item({name = belts.AMMO, count = BB.magazines})
      if got > 0 then
        local put = inv.insert({name = belts.AMMO, count = got})
        if put < got then net.insert({name = belts.AMMO, count = got - put}) end
        P_.debited[belts.AMMO] = (P_.debited[belts.AMMO] or 0) + put
      end
    end
    belts.set_priorities(ent)
  elseif e.kind == "depot" then
    P_.depot = ent
    logistics.set_policy(ent.unit_number, "keep", belts.AMMO, belts.DEPOT_KEEP)
  end
end

local function clear_footprint(surface, e)
  local p = prototypes.entity[e.name]
  local hw, hh = (p and p.tile_width or 1) / 2, (p and p.tile_height or 1) / 2
  for _, x in ipairs(surface.find_entities_filtered({area = {{e.x - hw, e.y - hh}, {e.x + hw, e.y + hh}},
                                                     type = CLEAR_TYPES})) do
    if x.valid then x.destroy({do_cliff_correction = x.type == "cliff"}) end
  end
end

-- The crew: revive up to `budget` ghosts the plan can pay. Returns the number built.
local function crew(P_, surface, budget)
  local entries = P_.entries
  -- first undone entry
  local c = P_.cursor
  while c <= #entries and (entries[c].status == "built" or entries[c].status == "skipped") do c = c + 1 end
  P_.cursor = c
  local missing, done, scanned = {}, 0, 0
  local i = c
  while i <= #entries and done < budget and scanned < belts.SCAN do
    local e = entries[i]
    if e.status == "ghost" then
      scanned = scanned + 1
      if not (e.ghost and e.ghost.valid) then
        -- built by robots or the Commander, or removed
        local ent = surface.find_entity(e.name, {e.x, e.y})
        if ent and ent.force.name == P_.force then
          e.status, e.ghost = "built", nil
          P_.built = P_.built + 1
          S().stats.by_robots = S().stats.by_robots + 1
          finish_entity(P_, e, ent, network_of(P_.nets[1]))
        else
          e.status, e.ghost = "skipped", nil
          P_.skipped = P_.skipped + 1
          S().stats.skipped = S().stats.skipped + 1
        end
      elseif e.item and not missing[e.item] then
        local net = take(P_, e.item, 1)
        if not net then
          missing[e.item] = true
        else
          clear_footprint(surface, e)
          local _, ent = e.ghost.revive({raise_revive = true})
          if ent and ent.valid then
            e.status, e.ghost = "built", nil
            P_.built = P_.built + 1
            P_.debited[e.item] = (P_.debited[e.item] or 0) + 1
            S().stats.revived = S().stats.revived + 1
            finish_entity(P_, e, ent, net)
            done = done + 1
          else
            net.insert({name = e.item, count = 1})
            e.fails = (e.fails or 0) + 1
            if e.fails >= belts.MAX_FAILS then
              if e.ghost.valid then e.ghost.destroy() end
              e.status, e.ghost = "skipped", nil
              P_.skipped = P_.skipped + 1
              util.log("belt: plan %d: %s at %s will not build, skipped", P_.id, e.name, util.pos_str(e))
            end
          end
        end
      end
    end
    i = i + 1
  end
  local waiting = sorted_keys(missing)
  P_.waiting = #waiting > 0 and waiting or nil
  if done == 0 and #waiting > 0 then
    for _, item in ipairs(waiting) do
      if not P_.alerted[item] then
        P_.alerted[item] = true
        supply.alert(P_.force, "belt-waiting", "rts-war3.alert-belt-waiting", {P_.id, "[item=" .. item .. "]"}, P_.mid)
        util.log("belt: plan %d of %s waits for %s", P_.id, P_.force, item)
      end
    end
  end
  return done
end

local function check_done(P_)
  for _, e in ipairs(P_.entries) do
    if e.status == "ghost" or e.status == "planned" then return false end
  end
  P_.state = "built"
  P_.done = game.tick
  P_.waiting = nil
  S().stats.built = S().stats.built + 1
  local kinds = {}
  for _, e in ipairs(P_.entries) do
    if e.status == "built" then kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
  end
  util.log("belt: plan %d of %s built in %.1f s: %s; %d skipped; debited [%s]", P_.id, P_.force,
    (game.tick - P_.created) / 60, counts_text(kinds), P_.skipped, counts_text(P_.debited))
  supply.alert(P_.force, "belt-built", "rts-war3.alert-belt-built", {P_.id, P_.built}, P_.mid)
  return true
end

-- Laying: ghosts_per_tick ghosts per tick over every plan being laid (s.laying counts them, so idle ticks cost one
-- comparison).
events.on(defines.events.on_tick, function()
  local s = storage.belts
  if not (s and (s.laying or 0) > 0) then return end
  local surface = match.surface()
  if not surface then return end
  local budget = BB.ghosts_per_tick
  local n = 0
  for _, id in ipairs(sorted_keys(s.plans)) do
    local P_ = s.plans[id]
    if P_.state == "laying" then
      if budget > 0 then
        local before = P_.lay_i or 1
        lay(P_, surface, budget)
        budget = budget - ((P_.lay_i or 1) - before)
      end
      if P_.state == "laying" then n = n + 1 end
    end
  end
  s.laying = n
end)

events.on_nth_tick(belts.BUILD_PERIOD, function()
  local s = storage.belts
  if not (s and next(s.plans)) then return end
  local surface = match.surface()
  if not surface then return end
  for _, id in ipairs(sorted_keys(s.plans)) do
    local P_ = s.plans[id]
    if P_.state == "building" then
      P_.credit = math.min(P_.credit + BB.build_rate * belts.BUILD_PERIOD / 60, BB.build_rate)
      local budget = floor(P_.credit)
      local done = crew(P_, surface, budget)
      P_.credit = P_.credit - done
      check_done(P_)
    end
  end
end)

-- The belt's field depot tops its turrets up (magazines from its own network: haulers and trains fill it).
events.on_nth_tick(BB.feed.period, function()
  local s = storage.belts
  if not (s and next(s.plans)) then return end
  for _, id in ipairs(sorted_keys(s.plans)) do
    local P_ = s.plans[id]
    local net = P_.depot and P_.depot.valid and P_.depot.logistic_network
    if net and net.valid and P_.state ~= "cancelled" then
      for _, e in ipairs(P_.entries) do
        local t = e.kind == "turret" and e.entity
        if t and t.valid then
          local inv = t.get_inventory(defines.inventory.turret_ammo)
          local have = inv and inv.get_item_count(belts.AMMO) or BB.feed.min
          if have < BB.feed.min then
            local got = net.remove_item({name = belts.AMMO, count = BB.feed.top - have})
            if got > 0 then
              local put = inv.insert({name = belts.AMMO, count = got})
              if put < got then net.insert({name = belts.AMMO, count = got - put}) end
            end
          end
        end
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Tool (F, the build menu button): points by right click, panel, preview
---------------------------------------------------------------------------
local function tool(player_index) return S().tools[player_index] end

local function clear_preview(T)
  for _, o in ipairs(T.objs or {}) do
    if o.valid then o.destroy() end
  end
  T.objs = {}
end

local COLORS = {line = {r = 1, g = 0.75, b = 0.25, a = 0.9}, point = {r = 1, g = 0.9, b = 0.4, a = 1},
                turret = {r = 1, g = 0.45, b = 0.2, a = 0.9}, aa = {r = 0.4, g = 0.8, b = 1, a = 0.9},
                depot = {r = 0.5, g = 1, b = 0.5, a = 0.9}, gate = {r = 0.9, g = 0.9, b = 0.9, a = 0.9}}

local function draw_preview(player, T)
  clear_preview(T)
  local surface = match.surface()
  if not surface then return end
  local players = {player.index}
  for _, mode in ipairs({"game", "chart"}) do
    local w = mode == "chart" and 3 or 4
    for i = 1, #T.points - 1 do
      T.objs[#T.objs + 1] = rendering.draw_line({surface = surface, color = COLORS.line, width = w, from = T.points[i],
        to = T.points[i + 1], players = players, render_mode = mode, dash_length = mode == "game" and 1 or nil,
        gap_length = mode == "game" and 0.5 or nil})
    end
    for _, p in ipairs(T.points) do
      T.objs[#T.objs + 1] = rendering.draw_circle({surface = surface, color = COLORS.point, radius = 1.2, filled = true,
        target = p, players = players, render_mode = mode})
    end
  end
  if T.layout then
    for _, e in ipairs(T.layout.entries) do
      if e.kind ~= "wall" then
        T.objs[#T.objs + 1] = rendering.draw_circle({surface = surface, color = COLORS[e.kind] or COLORS.point,
          radius = e.kind == "gate" and 0.5 or 1, width = 2, filled = false, target = {x = e.x, y = e.y},
          players = players})
      end
    end
  end
end

local REASONS = {["not-nation"] = true, ["no-tech"] = true, points = true, ["not-own"] = true, ["too-long"] = true,
                 ["no-city"] = true, empty = true}

local function reason_text(why)
  return REASONS[why] and {"rts-war3.belt-why-" .. why, BB.min_points, BB.max_points, BB.max_length}
    or {"rts-war3.belt-why-empty"}
end

local function bill_text(need)
  local parts = {}
  for _, item in ipairs(sorted_keys(need)) do parts[#parts + 1] = string.format("[item=%s] %d", item, need[item]) end
  return #parts > 0 and table.concat(parts, "  ") or "-"
end

local function update_panel(player, T)
  local frame = player.gui.screen[belts.FRAME]
  if not (frame and frame.valid and T.el) then return end
  local el = T.el
  local L = T.layout
  el.points.caption = {"rts-war3.belt-points", #T.points, BB.max_points, L and floor(L.length + 0.5) or 0}
  el.bill.caption = L and {"rts-war3.belt-bill", bill_text(L.need)} or {"rts-war3.belt-bill", "-"}
  if T.reason then
    el.reason.caption = reason_text(T.reason)
    el.reason.visible = true
  else
    el.reason.visible = false
  end
  local aa_ok = belts.aa_name(player.force.name) ~= nil
  el.aa.enabled = aa_ok
  el.aa.state = aa_ok and T.aa ~= false
  el.depot.state = T.depot ~= false
  el.build.enabled = L ~= nil and #T.points >= BB.min_points and #L.entries > 0
  el.undo.enabled = #T.points > 0
  -- plans under way
  el.plans.clear()
  local n = 0
  for _, P_ in ipairs(belts.of(player.force.name)) do
    if P_.state == "laying" or P_.state == "building" then
      n = n + 1
      if n <= 3 then
        local row = el.plans.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
        local todo = 0
        for _, e in ipairs(P_.entries) do
          if e.status ~= "skipped" then todo = todo + 1 end
        end
        local waits = {}
        for _, it in ipairs(P_.waiting or {}) do waits[#waits + 1] = "[item=" .. it .. "]" end
        local l = row.add({type = "label", style = "rts_hud_dim_label",
          caption = {"rts-war3.belt-plan-line", P_.id, P_.built, todo,
                     #waits > 0 and {"rts-war3.belt-waits", table.concat(waits, " ")} or ""}})
        l.style.maximal_width = WIDTH - 80
        row.add({type = "empty-widget", style = "rts_hud_filler"})
        row.add({type = "button", name = P .. "cancel_plan_" .. P_.id, style = "rts_hud_button",
                 caption = {"rts-war3.belt-cancel-plan"}, tooltip = {"rts-war3.belt-cancel-plan-tooltip"},
                 tags = {rts_belts = "cancel_plan", plan = P_.id}})
      end
    end
  end
end

local function recompute(player, T)
  T.layout, T.reason = nil, nil
  if #T.points >= BB.min_points then
    local L, why = belts.layout(player.force.name, T.points, {aa = T.aa, depot = T.depot})
    T.layout, T.reason = L, (not L) and why or nil
  end
  draw_preview(player, T)
  update_panel(player, T)
end

local function build_panel(player, T)
  local old = player.gui.screen[belts.FRAME]
  if old then old.destroy() end
  local frame = player.gui.screen.add({type = "frame", name = belts.FRAME, direction = "vertical",
                                       style = "rts_hud_frame"})
  frame.style.width = WIDTH
  local el = {}
  local head = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  head.add({type = "label", style = "rts_hud_heading_label", caption = {"rts-war3.belt-title"},
            tooltip = {"rts-war3.belt-title-tooltip", BB.turret_every, BB.aa_every}})
  head.add({type = "empty-widget", style = "rts_hud_filler"})
  head.add({type = "sprite-button", name = P .. "close", sprite = "utility/close", style = "frame_action_button",
            tooltip = {"rts-war3.belt-close"}, tags = {rts_belts = "close"}})
  local hint = frame.add({type = "label", style = "rts_hud_dim_label", caption = {"rts-war3.belt-hint", BB.min_points,
                                                                                 BB.max_points}})
  hint.style.single_line = false
  hint.style.maximal_width = WIDTH - 20
  el.points = frame.add({type = "label", style = "rts_hud_label", caption = ""})
  el.bill = frame.add({type = "label", style = "rts_hud_label", caption = ""})
  el.bill.style.single_line = false
  el.bill.style.maximal_width = WIDTH - 20
  el.reason = frame.add({type = "label", style = "rts_hud_label", caption = ""})
  el.reason.style.font_color = {1, 0.45, 0.35}
  el.reason.style.single_line = false
  el.reason.style.maximal_width = WIDTH - 20
  local opts = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.aa = opts.add({type = "checkbox", name = P .. "aa", caption = {"rts-war3.belt-aa"}, state = T.aa ~= false,
                    tooltip = {"rts-war3.belt-aa-tooltip", BB.aa_every, BB.aa_age}, tags = {rts_belts = "aa"}})
  el.depot = opts.add({type = "checkbox", name = P .. "depot", caption = {"rts-war3.belt-depot"},
                       state = T.depot ~= false, tooltip = {"rts-war3.belt-depot-tooltip"},
                       tags = {rts_belts = "depot"}})
  local buttons = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.undo = buttons.add({type = "button", name = P .. "undo", style = "rts_hud_button",
                         caption = {"rts-war3.belt-undo"}, tags = {rts_belts = "undo"}})
  buttons.add({type = "empty-widget", style = "rts_hud_filler"})
  el.build = buttons.add({type = "button", name = P .. "build", style = "rts_hud_button",
                          caption = {"rts-war3.belt-build"}, tooltip = {"rts-war3.belt-build-tooltip"},
                          tags = {rts_belts = "build"}})
  el.cancel = buttons.add({type = "button", name = P .. "cancel", style = "rts_hud_button",
                           caption = {"rts-war3.belt-cancel"}, tags = {rts_belts = "close"}})
  el.plans = frame.add({type = "flow", direction = "vertical"})
  T.el = el
  local s = player.display_scale
  local res = player.display_resolution
  frame.location = {math.floor((res.width - WIDTH * s) / 2), math.floor(belts.TOP * s)}
  update_panel(player, T)
end

--- Open the fort belt tool for a player (closes it when open). Returns true when it is open now.
function belts.toggle_tool(player)
  local s = S()
  local T = s.tools[player.index]
  if T then
    belts.close_tool(player, "toggle")
    return false
  end
  if not nation() then return false end
  if research and not research.has(player.force.name, BB.tech) then
    player.create_local_flying_text({text = {"rts-war3.belt-why-no-tech"}, create_at_cursor = true})
    util.log("belt: tool refused player=%d (no %s)", player.index, BB.tech)
    return false
  end
  T = {points = {}, aa = true, depot = true, objs = {}}
  s.tools[player.index] = T
  orders.arm_attack_move(player.index, false)
  build_panel(player, T)
  util.log("belt: tool opened player=%d", player.index)
  return true
end

function belts.close_tool(player, why)
  local s = S()
  local T = s.tools[player.index]
  if not T then return end
  clear_preview(T)
  s.tools[player.index] = nil
  local frame = player.gui.screen[belts.FRAME]
  if frame then frame.destroy() end
  util.log("belt: tool closed player=%d (%s)", player.index, why or "-")
end

--- Add a point to a player's tool (the right-click hook; tests call it). Returns true when added.
function belts.add_point(player, position)
  local T = tool(player.index)
  if not T then return false end
  local p = {x = floor(position.x) + 0.5, y = floor(position.y) + 0.5}
  if territory.owner_at(p) ~= player.force.name then
    player.create_local_flying_text({text = {"rts-war3.belt-why-not-own"}, create_at_cursor = true})
    return false
  end
  if #T.points >= BB.max_points then
    player.create_local_flying_text({text = {"rts-war3.belt-why-points", BB.min_points, BB.max_points},
                                     create_at_cursor = true})
    return false
  end
  T.points[#T.points + 1] = p
  util.log("belt: tool point %d at %s player=%d", #T.points, util.pos_str(p), player.index)
  recompute(player, T)
  return true
end

--- Build the player's belt (the panel's Build). Returns the plan id or nil, reason.
function belts.build_tool(player)
  local T = tool(player.index)
  if not T then return nil, "no-tool" end
  local id, why = belts.plan(player.force.name, T.points, {aa = T.aa, depot = T.depot,
                                                            why = "player " .. player.index})
  if not id then
    T.reason = why
    update_panel(player, T)
    return nil, why
  end
  player.create_local_flying_text({text = {"rts-war3.belt-planned", id, #S().plans[id].entries},
                                   create_at_cursor = true})
  T.points, T.layout, T.reason = {}, nil, nil
  draw_preview(player, T)
  update_panel(player, T)
  return id
end

-- Right click while the tool is open: a point (the hook runs before the other right-click hooks).
orders.on_right_click(function(player_index, position)
  local T = storage.belts and storage.belts.tools[player_index]
  if not T then return nil end
  local player = game.get_player(player_index)
  if not player then return nil end
  local ok = belts.add_point(player, position)
  return "belt-point", ok and 1 or 0
end, true)

--- F claims (orders.lua): with no unit selected, F is the fort belt tool, not attack-move.
function belts.claims_f(player_index)
  if not nation() then return false end
  if storage.belts and storage.belts.tools[player_index] then return true end
  return selection.count(player_index) == 0
end
orders.f_claim = belts.claims_f

--- F (hud.lua P4.KEYS): toggle the tool when F is the tool's key now.
function belts.key_f(player)
  if not belts.claims_f(player.index) then return false end
  return belts.toggle_tool(player)
end

events.on(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #P) ~= P then return end
  local player = game.get_player(e.player_index)
  local action = element.tags and element.tags.rts_belts
  if not (player and action) then return end
  local T = tool(player.index)
  if action == "close" then
    belts.close_tool(player, "button")
  elseif action == "undo" and T then
    table.remove(T.points)
    recompute(player, T)
  elseif action == "build" and T then
    local id, why = belts.build_tool(player)
    util.log("belt: click build player=%d plan=%s (%s)", player.index, tostring(id), tostring(why))
  elseif action == "cancel_plan" then
    local P_ = S().plans[element.tags.plan]
    if P_ and P_.force == player.force.name then belts.cancel(P_.id, "player " .. player.index) end
    if T then update_panel(player, T) end
  end
end)

events.on(defines.events.on_gui_checked_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #P) ~= P then return end
  local player = game.get_player(e.player_index)
  local T = player and tool(player.index)
  if not T then return end
  local action = element.tags and element.tags.rts_belts
  if action == "aa" then T.aa = element.state elseif action == "depot" then T.depot = element.state else return end
  recompute(player, T)
end)

-- Open tools refresh their plan lines every second.
events.on_nth_tick(60, function()
  local s = storage.belts
  if not (s and next(s.tools)) then return end
  for _, index in ipairs(sorted_keys(s.tools)) do
    local player = game.get_player(index)
    if player and player.connected then
      update_panel(player, s.tools[index])
    else
      clear_preview(s.tools[index])
      s.tools[index] = nil
    end
  end
end)

local function reposition(e)
  local player = game.get_player(e.player_index)
  local frame = player and player.gui.screen[belts.FRAME]
  if frame and frame.valid then
    local s = player.display_scale
    frame.location = {math.floor((player.display_resolution.width - WIDTH * s) / 2), math.floor(belts.TOP * s)}
  end
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

match.on_teardown(function()
  local s = storage.belts
  for index, T in pairs(s and s.tools or {}) do
    clear_preview(T)
    local player = game.get_player(index)
    local frame = player and player.gui.screen[belts.FRAME]
    if frame then frame.destroy() end
  end
  storage.belts = nil
  S()
end)

--- One line for logs.
function belts.describe(force_name)
  local parts = {}
  for _, P_ in ipairs(belts.of(force_name)) do
    parts[#parts + 1] = string.format("#%d %s %d/%d", P_.id, P_.state, P_.built, #P_.entries)
  end
  return string.format("%s: %d belts [%s]", force_name, #parts, table.concat(parts, ", "))
end

return belts
