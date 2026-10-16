-- AI base layout (docs/PHASE3.md "ai/layout.lua"): where an AI force puts its buildings. Pure geometry plus
-- read-only surface queries; it never creates entities except the one-off inserter probe.
--
-- Frame. Every CC has a frame: origin = CC centre (a tile corner), x axis = "forward" (towards the enemy, +1 or -1 in
-- world x), y = world y. Hub slots are defined in that frame, so mirrored bases come out mirrored.
--
-- Hub. No stockpile recipe exists, so plates must reach the CC composite's four stockpiles (buildings.CC_STOCKPILES).
-- Each stockpile can take inserters on its free sides. A smelter slot is
--   feed belt tile -> inserter -> rts-smelter -> inserter -> CC stockpile
-- a direct slot (stone) is feed belt tile -> inserter -> CC stockpile, and a chain slot (steel) is
--   feed -> inserter -> smelter A (iron plates) -> inserter -> smelter B (steel plates) -> inserter -> CC stockpile.
-- HUB lists them (see the ASCII map below);
-- slots that share tiles exclude each other (claiming one kills the others).
--
--      y-7.5  .  .  .  N2f .  .  .  .  .  .  .  N1f .  .  .  .  .  .
--      y-6.5  .  .  .  N2i .  .  .  .  .  .  .  N1i .  .  .  .  .  .
--             .  .  [N2 smelter]  .  .  .  .  [N1 smelter] .  .  .  .
--      y-2.5  .  .  .  N2o .  .  .  .  .  .  .  N1o [E1 smelter] .  .
--      y-1.5 W1f W1i [W1 smelter] W1o SP [  CC  ] SP E1o         E1i E1f
--      y+1.5 W2f W2i [W2 smelter] W2o SP [      ] SP E2o [E2 sm] E2i E2f
--             (S1/S2 mirror N1/N2 in y. Direct slots N1d/S1d/N2d/S2d sit on the N/S inserter tiles and E1d/E2d/
--             W1d/W2d on the E/W ones. Steel chains N1c/N2c/S1c/S2c/E1c/E2c/W1c/W2c are a smelter slot plus a
--             second smelter and inserter further out. Every slot type exists on all four sides.)
--
-- Mining line. An ore patch gets a straight "spine" belt through it towards the CC with extractors on both sides
-- (pairs around a one-tile gap that holds a medium pole: D g D . D g D ...), then an A* belt route from the spine's
-- near end to the feed tile of each hub slot in turn, and a chain of medium poles from the spine to the CC (the
-- hidden core pole connects poles within 9 tiles of the CC centre).
--
-- Sinks (Phase 4). A line ends at a "sink": the CC (default) or a forward rts-hub. A sink is
--   {frame, hub = {[slot] = state}, order = {slot names}, target = pole chain target, wire = chain reach,
--    satellites = bool}
-- The hub sink's frame has its origin 2 tiles south of the hub centre, so the hub's two stockpiles (logistics.lua
-- HUB_STOCKPILES, (+-3.5, 0.5) from the hub) sit where the CC frame's north stockpiles are (+-3.5, -1.5): the "1"
-- slots of HUB (E1, W1, N1, N2 and their d/c variants) then feed the hub's stockpiles unchanged (HUB_SINK_ORDER).
-- Water tiles count as occupied in every planning context (Phase 4 maps have lakes).
local util = require("scripts.util")
local buildings = require("scripts.buildings")

local layout = {}

layout.ARENA_HALF = 80        -- fallback arena half size; the match's storage.match.arena_half wins (layout.arena_half)
layout.BELT = "transport-belt"
layout.POLE = "medium-electric-pole"
layout.INSERTER = "fast-inserter"
layout.DRILL = "rts-extractor"
layout.SMELTER = "rts-smelter"
layout.POLE_STEP = 7.5        -- max centre distance between chained poles (medium pole wire reach 9)
layout.CC_WIRE = 8.5          -- a pole this close to the CC centre wires to the hidden core pole (reach 9)
layout.POWER_HALF = 16        -- buildings stay within this many tiles of the CC centre: core pole supply 36x36
layout.LOGISTIC_HALF = 23     -- turrets stay within this: CC logistic area 50x50 (ammo is fed from the network)
layout.MIN_DRILL_ORE = 6      -- ore tiles a drill's 5x5 mining area must cover
layout.PATCH_SEARCH = 100     -- resources are searched within this many tiles of the CC
layout.HOSTILE_RADIUS = 45    -- a patch this close to another force's spawn belongs to that force
layout.ROUTE_MARGIN = 14      -- A* box = start/goal box grown by this many tiles
layout.LINK_EXPAND = 20000    -- state cap for a link between two hub slots (short; a failed search is the costly one)
layout.SLOT_TRIES = 6         -- hub slots tried per slot entry
layout.MAX_ATTEMPTS = 4       -- line plans tried with a different first slot when the main belt cannot reach it
layout.ROUTE_MAX_EXPAND = 60000
layout.TURN_COST = 1.5
layout.ORE_COST = 2           -- extra cost of a belt on an ore tile (keeps patches free for drills)

local DIR = defines.direction
-- 4-way direction index 1..4 = north, east, south, west
local DX = {0, 1, 0, -1}
local DY = {-1, 0, 1, 0}
local DEFINES = {DIR.north, DIR.east, DIR.south, DIR.west}
local INDEX = {[DIR.north] = 1, [DIR.east] = 2, [DIR.south] = 3, [DIR.west] = 4}
layout.DX, layout.DY, layout.DEFINES = DX, DY, DEFINES

local function idx_of(dx, dy)
  if math.abs(dx) >= math.abs(dy) then return dx >= 0 and 2 or 4 end
  return dy >= 0 and 3 or 1
end

--- defines.direction pointing along (dx, dy) (the dominant axis).
function layout.dir_of(dx, dy) return DEFINES[idx_of(dx, dy)] end

local function opposite_idx(i) return ((i + 1) % 4) + 1 end

---------------------------------------------------------------------------
-- Tiles and frames
---------------------------------------------------------------------------
--- Integer key of a tile (tile left-top corner coordinates).
local function tkey(tx, ty) return tx * 4096 + ty end
layout.tkey = tkey

local function tile_of(x, y) return math.floor(x), math.floor(y) end

--- Frame of a CC: {cx, cy, fx}. fx = +1 when the enemy is towards +x.
function layout.frame(cc_position, fx)
  local x, y = util.xy(cc_position)
  return {cx = x, cy = y, fx = fx or 1}
end

--- World position of a frame offset.
function layout.world(frame, ox, oy)
  return {x = frame.cx + frame.fx * ox, y = frame.cy + oy}
end

--- Footprint of an entity prototype centred at (x, y): first tile x, first tile y, width, height.
function layout.footprint(name, x, y)
  local p = prototypes.entity[name]
  local w, h = p.tile_width, p.tile_height
  return math.floor(x - w / 2 + 0.001), math.floor(y - h / 2 + 0.001), w, h
end

local function each_tile(name, x, y, fn)
  local tx0, ty0, w, h = layout.footprint(name, x, y)
  for tx = tx0, tx0 + w - 1 do
    for ty = ty0, ty0 + h - 1 do
      if fn(tx, ty) == false then return false end
    end
  end
  return true
end
layout.each_tile = each_tile

--- The arena is [-half, half)^2 around (0, 0): storage.match.arena_half (contract with match.lua, set at match
--- start), else ARENA_HALF. Nothing is planned outside it.
function layout.arena_half()
  local m = storage.match
  return (m and m.arena_half) or layout.ARENA_HALF
end

local function in_arena(tx, ty)
  local h = layout.arena_half()
  return tx >= -h + 1 and tx < h - 1 and ty >= -h + 1 and ty < h - 1
end

---------------------------------------------------------------------------
-- Inserter direction (2.0 semantics are probed once and kept in storage, see layout.probe_inserter)
---------------------------------------------------------------------------
--- Create one fast inserter facing north at a free spot near `near`, read where it picks up, destroy it.
--- Stores storage.ai_meta.inserter_dir_is_pickup = true when an inserter's direction points at its pickup side.
function layout.probe_inserter(surface, near)
  local meta = storage.ai_meta
  if meta.inserter_dir_is_pickup ~= nil then return end
  local pos = surface.find_non_colliding_position(layout.INSERTER, near, 30, 1, true)
  if not pos then return end
  local e = surface.create_entity({name = layout.INSERTER, position = pos, direction = DIR.north, force = "neutral",
                                   create_build_effect_smoke = false})
  if not e then return end
  local dy = e.pickup_position.y - e.position.y
  e.destroy()
  meta.inserter_dir_is_pickup = dy < 0
  util.log("ai layout: inserter probe: direction north picks up from %s", dy < 0 and "north" or "south")
end

--- Direction for an inserter that picks up from the neighbouring tile in direction (dx, dy).
function layout.inserter_dir(dx, dy)
  local i = idx_of(dx, dy)
  if storage.ai_meta.inserter_dir_is_pickup == false then i = opposite_idx(i) end
  return DEFINES[i]
end

---------------------------------------------------------------------------
-- Hub slots (frame offsets). Generated: the y mirror of every slot (N<->S, 1<->2).
---------------------------------------------------------------------------
local HUB_BASE = {
  E1 = {stock = {3.5, -1.5}, out = {4.5, -1.5}, smelter = {6.5, -1.5}, inp = {8.5, -1.5}, feed = {9.5, -1.5}},
  N1 = {stock = {3.5, -1.5}, out = {3.5, -2.5}, smelter = {3.5, -4.5}, inp = {3.5, -6.5}, feed = {3.5, -7.5}},
  W1 = {stock = {-3.5, -1.5}, out = {-4.5, -1.5}, smelter = {-6.5, -1.5}, inp = {-8.5, -1.5}, feed = {-9.5, -1.5}},
  N2 = {stock = {-3.5, -1.5}, out = {-3.5, -2.5}, smelter = {-3.5, -4.5}, inp = {-3.5, -6.5}, feed = {-3.5, -7.5}},
  N1d = {stock = {3.5, -1.5}, inp = {3.5, -2.5}, feed = {3.5, -3.5}},
  N2d = {stock = {-3.5, -1.5}, inp = {-3.5, -2.5}, feed = {-3.5, -3.5}},
  E1d = {stock = {3.5, -1.5}, inp = {4.5, -1.5}, feed = {5.5, -1.5}},
  W1d = {stock = {-3.5, -1.5}, inp = {-4.5, -1.5}, feed = {-5.5, -1.5}},
  E1c = {stock = {3.5, -1.5}, out = {4.5, -1.5}, smelter = {6.5, -1.5}, mid = {8.5, -1.5}, smelter2 = {10.5, -1.5},
         inp = {12.5, -1.5}, feed = {13.5, -1.5}},
  W1c = {stock = {-3.5, -1.5}, out = {-4.5, -1.5}, smelter = {-6.5, -1.5}, mid = {-8.5, -1.5},
         smelter2 = {-10.5, -1.5}, inp = {-12.5, -1.5}, feed = {-13.5, -1.5}},
  -- chain (steel): feed -> inserter -> smelter A (iron plates) -> inserter -> smelter B (steel) -> inserter -> stock
  N1c = {stock = {3.5, -1.5}, out = {3.5, -2.5}, smelter = {3.5, -4.5}, mid = {3.5, -6.5}, smelter2 = {3.5, -8.5},
         inp = {3.5, -10.5}, feed = {3.5, -11.5}},
  N2c = {stock = {-3.5, -1.5}, out = {-3.5, -2.5}, smelter = {-3.5, -4.5}, mid = {-3.5, -6.5},
         smelter2 = {-3.5, -8.5}, inp = {-3.5, -10.5}, feed = {-3.5, -11.5}},
}
local MIRROR_NAME = {E1 = "E2", N1 = "S1", W1 = "W2", N2 = "S2", N1d = "S1d", N2d = "S2d", N1c = "S1c",
                     N2c = "S2c", E1d = "E2d", W1d = "W2d", E1c = "E2c", W1c = "W2c"}
layout.HUB = {}
layout.SLOT_FLIP = {}
for name, s in pairs(HUB_BASE) do
  layout.HUB[name] = s
  local m = {}
  for k, v in pairs(s) do m[k] = {v[1], -v[2]} end
  layout.HUB[MIRROR_NAME[name]] = m
  layout.SLOT_FLIP[name] = MIRROR_NAME[name]
  layout.SLOT_FLIP[MIRROR_NAME[name]] = name
end
layout.HUB_ORDER = {"E1", "E2", "N1", "S1", "W1", "W2", "N2", "S2", "N1d", "S1d", "N2d", "S2d", "N1c", "S1c",
                    "N2c", "S2c", "E1d", "E2d", "W1d", "W2d", "E1c", "E2c", "W1c", "W2c"}

--- Type of a hub slot name, or of an abstract slot entry: "smelter" | "chain" | "direct" (nil for "X").
function layout.slot_type(name)
  if name == "smelter" or name == "chain" or name == "direct" then return name end
  if not layout.HUB[name] then return nil end
  local last = string.sub(name, -1)
  if last == "c" then return "chain" end
  if last == "d" then return "direct" end
  return "smelter"
end

--- Entity specs of a hub slot in world coordinates: {{name, x, y, dir, part, pickup?}, ...} in build order.
--- part = "inp" | "smelter2" | "mid" | "out" | "smelter". Also returns the feed tile (tx, ty).
function layout.slot_specs(frame, slot_name)
  local s = layout.HUB[slot_name]
  local function w(o) return layout.world(frame, o[1], o[2]) end
  local specs = {}
  local inp, feed = w(s.inp), w(s.feed)
  specs[#specs + 1] = {name = layout.INSERTER, x = inp.x, y = inp.y, part = "inp", pickup = {feed.x, feed.y},
                       dir = layout.inserter_dir(feed.x - inp.x, feed.y - inp.y)}
  if s.smelter then
    local out, stock, sm = w(s.out), w(s.stock), w(s.smelter)
    local ux, uy = stock.x - out.x, stock.y - out.y -- one tile towards the stockpile
    if s.smelter2 then
      local mid, a = w(s.mid), w(s.smelter2)
      specs[#specs + 1] = {name = layout.SMELTER, x = a.x, y = a.y, part = "smelter2"}
      specs[#specs + 1] = {name = layout.INSERTER, x = mid.x, y = mid.y, part = "mid",
                           pickup = {mid.x - ux, mid.y - uy}, dir = layout.inserter_dir(-ux, -uy)}
    end
    specs[#specs + 1] = {name = layout.INSERTER, x = out.x, y = out.y, part = "out",
                         pickup = {out.x - ux, out.y - uy}, dir = layout.inserter_dir(-ux, -uy)}
    specs[#specs + 1] = {name = layout.SMELTER, x = sm.x, y = sm.y, part = "smelter"}
  end
  local ftx, fty = tile_of(feed.x, feed.y)
  return specs, ftx, fty
end

-- Tiles of a slot (entities + feed tile) as a set of keys.
local function slot_tiles(frame, slot_name)
  local specs, ftx, fty = layout.slot_specs(frame, slot_name)
  local set = {[tkey(ftx, fty)] = true}
  for _, sp in ipairs(specs) do
    each_tile(sp.name, sp.x, sp.y, function(tx, ty) set[tkey(tx, ty)] = true end)
  end
  return set
end

-- The "1" slots feed the north stockpile pair of a frame: on a hub sink these are the hub's two stockpiles.
layout.HUB_SINK_ORDER = {"E1", "W1", "N1", "N2", "E1d", "W1d", "N1d", "N2d", "E1c", "W1c", "N1c", "N2c"}
layout.HUB_SINK_DY = 2      -- hub sink frame origin = hub centre + (0, HUB_SINK_DY)
layout.HUB_WIRE = 8         -- pole chain reach to the hub's hidden pole (wire 9; it snaps up to 0.7 tiles off centre)

--- The CC sink of commander C (see the header).
function layout.cc_sink(C)
  local f = C.frame
  return {frame = f, hub = C.hub, order = layout.HUB_ORDER, target = {x = f.cx, y = f.cy}, wire = layout.CC_WIRE,
          satellites = true}
end

--- Reserve every hub slot's tiles as "hub" (once per commander). C.hub = {[slot] = "free" | "dead" | line name}.
--- `hub` and `order` default to C.hub and HUB_ORDER (the CC); a forward hub passes its own.
function layout.reserve_hub(C, frame, hub, order)
  if not hub then
    C.hub = C.hub or {}
    hub = C.hub
  end
  for _, name in ipairs(order or layout.HUB_ORDER) do
    if not hub[name] then
      hub[name] = "free"
      for k in pairs(slot_tiles(frame, name)) do
        if C.reserved[k] == nil then C.reserved[k] = "hub" end
      end
    end
  end
end

--- Snapshot of the hub state, for layout.restore_hub (a claim whose route then fails is undone).
function layout.snapshot_hub(C, frame, hub, order)
  hub, order = hub or C.hub, order or layout.HUB_ORDER
  local snap = {hub = {}, reserved = {}, ref = hub}
  for k, v in pairs(hub) do snap.hub[k] = v end
  for _, name in ipairs(order) do
    for k in pairs(slot_tiles(frame, name)) do snap.reserved[k] = C.reserved[k] or false end
  end
  return snap
end

function layout.restore_hub(C, snap)
  local hub = snap.ref or C.hub
  for k, v in pairs(snap.hub) do hub[k] = v end
  for k, v in pairs(snap.reserved) do C.reserved[k] = v or nil end
end

--- Claim a hub slot for a line: its tiles become the line's, slots sharing a tile with it die, and the tiles only
--- the dead slots used are released. Returns false when the slot is not free.
function layout.claim_slot(C, frame, slot_name, owner, hub, order)
  hub, order = hub or C.hub, order or layout.HUB_ORDER
  if hub[slot_name] ~= "free" then return false end
  local mine = slot_tiles(frame, slot_name)
  hub[slot_name] = owner
  for k in pairs(mine) do C.reserved[k] = owner end
  for _, other in ipairs(order) do
    if other ~= slot_name and hub[other] == "free" then
      local tiles = slot_tiles(frame, other)
      local shared = false
      for k in pairs(tiles) do
        if mine[k] then shared = true break end
      end
      if shared then
        hub[other] = "dead"
        for k in pairs(tiles) do
          if C.reserved[k] == "hub" then C.reserved[k] = nil end
        end
      end
    end
  end
  -- a released tile may still belong to another live slot: re-reserve those
  for _, other in ipairs(order) do
    if hub[other] == "free" then
      for k in pairs(slot_tiles(frame, other)) do
        if C.reserved[k] == nil then C.reserved[k] = "hub" end
      end
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Planning context: one read of the surface (occupied tiles, ore tiles) for a planning pass
---------------------------------------------------------------------------
local IGNORE_TYPES = {"resource", "spider-unit", "spider-leg", "unit", "corpse", "character", "character-corpse",
                      "particle-source", "highlight-box", "sticker", "projectile", "combat-robot",
                      "construction-robot", "logistic-robot"}
layout.IGNORE_TYPES = IGNORE_TYPES
-- Line planning also treats trees and rocks as free: construction destroys them before it places a ghost.
local PLAN_IGNORE_TYPES = {"tree", "simple-entity"}
for _, t in ipairs(IGNORE_TYPES) do PLAN_IGNORE_TYPES[#PLAN_IGNORE_TYPES + 1] = t end

--- Planning context around a CC: {surface, force, frame, occ = {[tile] = true}, ore = {[tile] = resource name},
--- patches = sorted list}. Costs one find_entities_filtered for obstacles, one for resources and one for water.
function layout.context(C, surface)
  return layout.context_at(C, surface, C.frame, layout.PATCH_SEARCH)
end

--- The same around any frame (a forward hub's), `radius` tiles in each direction.
function layout.context_at(C, surface, frame, radius)
  local R = radius or layout.PATCH_SEARCH
  local area = {{frame.cx - R, frame.cy - R}, {frame.cx + R, frame.cy + R}}
  local occ = {}
  for _, e in pairs(surface.find_entities_filtered({area = area, type = PLAN_IGNORE_TYPES, invert = true})) do
    local bb = e.bounding_box
    local x0, y0 = math.floor(bb.left_top.x + 0.01), math.floor(bb.left_top.y + 0.01)
    local x1, y1 = math.ceil(bb.right_bottom.x - 0.01) - 1, math.ceil(bb.right_bottom.y - 0.01) - 1
    for tx = x0, x1 do
      for ty = y0, y1 do occ[tkey(tx, ty)] = true end
    end
  end
  -- lakes block belts and buildings like an entity does
  for _, t in pairs(surface.find_tiles_filtered({area = area, collision_mask = "water_tile"})) do
    local p = t.position
    occ[tkey(math.floor(p.x), math.floor(p.y))] = true
  end
  local ore, list = {}, {}
  for _, e in pairs(surface.find_entities_filtered({area = area, type = "resource"})) do
    local p = e.position
    local tx, ty = tile_of(p.x, p.y)
    local k = tkey(tx, ty)
    -- map-gen ore right outside the arena can be as near as the arena's own patches; it is not usable
    if not ore[k] and in_arena(tx, ty) then
      ore[k] = e.name
      list[#list + 1] = {k = k, tx = tx, ty = ty, name = e.name}
    end
  end
  return {surface = surface, force = C.force, frame = frame, occ = occ, ore = ore, ore_list = list,
          reserved = C.reserved, avoid = C.avoid}
end

local function free(ctx, tx, ty)
  local k = tkey(tx, ty)
  return in_arena(tx, ty) and not ctx.occ[k] and ctx.reserved[k] == nil and not ctx.avoid[k]
end
layout.free = free

local function reserve(ctx, tx, ty, owner)
  ctx.reserved[tkey(tx, ty)] = owner
end

local function reserve_entity(ctx, name, x, y, owner)
  each_tile(name, x, y, function(tx, ty) reserve(ctx, tx, ty, owner) end)
end
layout.reserve_entity = reserve_entity

local function entity_free(ctx, name, x, y)
  return each_tile(name, x, y, function(tx, ty)
    if not free(ctx, tx, ty) then return false end
  end)
end

---------------------------------------------------------------------------
-- Ore patches
---------------------------------------------------------------------------
--- Ore patches near the CC, nearest first: {name, tiles = {[key] = true}, cells = {{tx, ty}, ...}, count, cx, cy, id}.
--- Clustered by
--- 8-neighbourhood per resource name. Cached in the context.
function layout.patches(ctx)
  if ctx.patches then return ctx.patches end
  local seen, patches = {}, {}
  for _, t in ipairs(ctx.ore_list) do
    if not seen[t.k] then
      local tiles, cells, queue, sx, sy, n = {}, {}, {t}, 0, 0, 0
      local minx, miny = t.tx, t.ty
      seen[t.k] = true
      while #queue > 0 do
        local cur = table.remove(queue)
        tiles[cur.k] = true
        cells[#cells + 1] = {cur.tx, cur.ty}
        n = n + 1
        sx, sy = sx + cur.tx + 0.5, sy + cur.ty + 0.5
        if cur.tx < minx or (cur.tx == minx and cur.ty < miny) then minx, miny = cur.tx, cur.ty end
        for ox = -1, 1 do
          for oy = -1, 1 do
            local nx, ny = cur.tx + ox, cur.ty + oy
            local nk = tkey(nx, ny)
            if not seen[nk] and ctx.ore[nk] == t.name then
              seen[nk] = true
              queue[#queue + 1] = {k = nk, tx = nx, ty = ny}
            end
          end
        end
      end
      patches[#patches + 1] = {name = t.name, tiles = tiles, cells = cells, count = n, cx = sx / n, cy = sy / n,
                               id = string.format("%s@%d,%d", t.name, minx, miny)}
    end
  end
  local f = ctx.frame
  table.sort(patches, function(a, b)
    local da = (a.cx - f.cx) ^ 2 + (a.cy - f.cy) ^ 2
    local db = (b.cx - f.cx) ^ 2 + (b.cy - f.cy) ^ 2
    if da ~= db then return da < db end
    return a.id < b.id
  end)
  ctx.patches = patches
  return patches
end

--- The nearest patch of `ore` that is not in `claimed` or `tried` ({[id] = true}) and not within HOSTILE_RADIUS of
--- any position in `hostile` (other forces' spawns). nil when there is none.
function layout.pick_patch(ctx, ore, claimed, hostile, tried)
  for _, p in ipairs(layout.patches(ctx)) do
    if p.name == ore and not claimed[p.id] and not (tried and tried[p.id]) and p.count >= 4 then
      local ok = true
      for _, h in pairs(hostile) do
        if util.distance({p.cx, p.cy}, h) < layout.HOSTILE_RADIUS then ok = false break end
      end
      if ok then return p end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Spine: belt through the patch, drills on both sides, gap poles
---------------------------------------------------------------------------
-- Ore tiles of the patch inside a drill's 5x5 mining area around (x, y).
local function ore_under(patch, x, y)
  local n = 0
  local tx0, ty0 = math.floor(x - 2.5 + 0.001), math.floor(y - 2.5 + 0.001)
  for tx = tx0, tx0 + 4 do
    for ty = ty0, ty0 + 4 do
      if patch.tiles[tkey(tx, ty)] then n = n + 1 end
    end
  end
  return n
end

-- Drill slots and gap poles for a spine on line `c` (the perpendicular coordinate, a tile index) of the patch.
-- Returns {tiles = {{tx, ty}, ...} from the far end, drills = {...}, poles = {[g] = {x, y}}, score}.
local function spine_candidate(ctx, patch, horizontal, along_sign, c)
  -- along coordinate range of the ore within 4 tiles of the spine line
  local lo, hi
  for _, cell in ipairs(patch.cells) do
    local along, perp = cell[1], cell[2]
    if not horizontal then along, perp = cell[2], cell[1] end
    if math.abs(perp - c) <= 4 then
      if not lo or along < lo then lo = along end
      if not hi or along > hi then hi = along end
    end
  end
  if not lo then return nil end
  -- far end = the end away from the CC; t runs from the far end towards the CC
  local far = along_sign > 0 and lo or hi
  local len = hi - lo
  local function tile_at(t)
    local a = far + along_sign * t
    if horizontal then return a, c end
    return c, a
  end
  local sx, sy = 0, 0 -- side unit vector (perpendicular)
  if horizontal then sy = 1 else sx = 1 end
  local cand = {drills = {}, poles = {}, score = 0, len = len}
  local max_t = len
  for g = 0, 20 do
    local t1, t2, tg = 1 + 7 * g, 5 + 7 * g, 3 + 7 * g
    if t1 - 1 > len then break end
    local group_has = false
    for _, t in ipairs({t1, t2}) do
      if t - 1 <= len then
        local tx, ty = tile_at(t)
        for _, side in ipairs({-1, 1}) do
          local x, y = tx + 0.5 + sx * 2 * side, ty + 0.5 + sy * 2 * side
          local n = ore_under(patch, x, y)
          if n >= layout.MIN_DRILL_ORE and entity_free(ctx, layout.DRILL, x, y) then
            -- the drill faces the spine (its drop tile is the spine tile at t)
            cand.drills[#cand.drills + 1] = {x = x, y = y, dir = layout.dir_of(-sx * side, -sy * side), t = t,
                                             g = g, ore = n}
            cand.score = cand.score + n
            group_has = true
            if t > max_t then max_t = t end
          end
        end
      end
    end
    if group_has then
      local tx, ty = tile_at(tg)
      for _, side in ipairs({-1, 1}) do
        local px, py = tx + sx * side, ty + sy * side
        if free(ctx, px, py) then
          cand.poles[g] = {x = px + 0.5, y = py + 0.5}
          break
        end
      end
    end
  end
  cand.tiles = {}
  for t = 0, max_t do
    local tx, ty = tile_at(t)
    if not free(ctx, tx, ty) then return nil end
    cand.tiles[#cand.tiles + 1] = {tx, ty}
  end
  cand.along = {horizontal and along_sign or 0, horizontal and 0 or along_sign}
  return cand
end

--- Best spine for a patch towards the hub (frame `toward`, default the context's): {tiles, drills (best first),
--- poles, along}. nil if none fits.
function layout.plan_spine(ctx, patch, toward)
  local f = toward or ctx.frame
  local dx, dy = f.cx - patch.cx, f.cy - patch.cy
  local horizontal = math.abs(dx) >= math.abs(dy)
  local along_sign = horizontal and (dx >= 0 and 1 or -1) or (dy >= 0 and 1 or -1)
  local centre = horizontal and math.floor(patch.cy) or math.floor(patch.cx)
  local best
  for off = -2, 2 do
    local cand = spine_candidate(ctx, patch, horizontal, along_sign, centre + off)
    if cand and #cand.drills > 0 and (not best or cand.score > best.score
       or (cand.score == best.score and math.abs(off) < math.abs(best.off))) then
      cand.off = off
      best = cand
    end
  end
  if not best then return nil end
  -- drills: groups nearest the CC first (shorter pole chain), then by ore
  table.sort(best.drills, function(a, b)
    if a.g ~= b.g then return a.g > b.g end
    if a.ore ~= b.ore then return a.ore > b.ore end
    if a.t ~= b.t then return a.t > b.t end
    return a.y < b.y or (a.y == b.y and a.x < b.x)
  end)
  return best
end

---------------------------------------------------------------------------
-- A* belt router on tiles: 4-way moves, turn penalty, ore penalty. Belts face the next tile.
---------------------------------------------------------------------------
-- Binary min-heap over parallel arrays (f, sequence number for deterministic ties, state).
local function heap_push(h, f, s)
  local n = h.n + 1
  h.n = n
  h.seq = h.seq + 1
  local q = h.seq
  local hf, hq, hs = h.f, h.q, h.s
  while n > 1 do
    local p = math.floor(n / 2)
    if hf[p] < f or (hf[p] == f and hq[p] < q) then break end
    hf[n], hq[n], hs[n] = hf[p], hq[p], hs[p]
    n = p
  end
  hf[n], hq[n], hs[n] = f, q, s
end

local function heap_pop(h)
  local n = h.n
  if n == 0 then return nil end
  local hf, hq, hs = h.f, h.q, h.s
  local top = hs[1]
  local lf, lq, ls = hf[n], hq[n], hs[n]
  hf[n], hq[n], hs[n] = nil, nil, nil
  n = n - 1
  h.n = n
  if n > 0 then
    local i = 1
    while true do
      local l = 2 * i
      if l > n then break end
      local r = l + 1
      local c = l
      if r <= n and (hf[r] < hf[l] or (hf[r] == hf[l] and hq[r] < hq[l])) then c = r end
      if hf[c] > lf or (hf[c] == lf and hq[c] > lq) then break end
      hf[i], hq[i], hs[i] = hf[c], hq[c], hs[c]
      i = c
    end
    hf[i], hq[i], hs[i] = lf, lq, ls
  end
  return top
end

--- Route from tile (sx, sy), entered moving in direction index sdir (nil: any first step), to tile (gx, gy). `blocked(tx, ty)` must be
--- false for every tile on the path except the goal. A search stops after max_expand states (default
--- ROUTE_MAX_EXPAND): a failed search costs the most. Returns {{tx, ty}, ...} including start and goal, or nil.
function layout.route(ctx, sx, sy, sdir, gx, gy, blocked, max_expand)
  local m = layout.ROUTE_MARGIN
  local bx0, bx1 = math.min(sx, gx) - m, math.max(sx, gx) + m
  local by0, by1 = math.min(sy, gy) - m, math.max(sy, gy) + m
  local g, parent, coord = {}, {}, {}
  local function skey(x, y, d) return tkey(x, y) * 4 + (d - 1) end
  local h = {n = 0, seq = 0, f = {}, q = {}, s = {}}
  for d = 1, 4 do
    if sdir == nil or d == sdir then
      local s0 = skey(sx, sy, d)
      g[s0], coord[s0] = 0, {sx, sy, d}
      heap_push(h, math.abs(gx - sx) + math.abs(gy - sy), s0)
    end
  end
  local expanded, goal_state = 0, nil
  local closed = {}
  while true do
    local s = heap_pop(h)
    if not s then break end
    if not closed[s] then
      closed[s] = true
      local c = coord[s]
      local x, y, d = c[1], c[2], c[3]
      if x == gx and y == gy then
        goal_state = s
        break
      end
      expanded = expanded + 1
      if expanded > (max_expand or layout.ROUTE_MAX_EXPAND) then break end
      local back = opposite_idx(d)
      for nd = 1, 4 do
        if nd ~= back then
          local nx, ny = x + DX[nd], y + DY[nd]
          if nx >= bx0 and nx <= bx1 and ny >= by0 and ny <= by1 and in_arena(nx, ny)
             and ((nx == gx and ny == gy) or not blocked(nx, ny)) then
            local cost = g[s] + 1
            if nd ~= d then cost = cost + layout.TURN_COST end
            if ctx.ore[tkey(nx, ny)] then cost = cost + layout.ORE_COST end
            local ns = skey(nx, ny, nd)
            if not g[ns] or cost < g[ns] then
              g[ns], parent[ns], coord[ns] = cost, s, {nx, ny, nd}
              heap_push(h, cost + math.abs(gx - nx) + math.abs(gy - ny), ns)
            end
          end
        end
      end
    end
  end
  ctx.last_expanded = expanded
  if not goal_state then return nil end
  local path, s = {}, goal_state
  while s do
    local c = coord[s]
    table.insert(path, 1, {c[1], c[2]})
    s = parent[s]
  end
  return path
end

---------------------------------------------------------------------------
-- Pole chain
---------------------------------------------------------------------------
--- Greedy chain of pole positions from `from` (a pole position) to within `wire` (default CC_WIRE) of `target`
--- (the CC centre, or a hub's): each step takes the free tile within POLE_STEP that is closest to the target.
--- Reserves the tiles. Returns the list and whether the chain reached the target.
function layout.chain_poles(ctx, from, target, owner, wire)
  local out, last = {}, {x = from.x, y = from.y}
  local step = layout.POLE_STEP
  wire = wire or layout.CC_WIRE
  for _ = 1, 16 do
    local dist = util.distance(last, target)
    if dist <= wire then return out, true end
    local best, best_d
    local lx, ly = math.floor(last.x), math.floor(last.y)
    for tx = lx - 8, lx + 8 do
      for ty = ly - 8, ly + 8 do
        local p = {x = tx + 0.5, y = ty + 0.5}
        if util.distance(p, last) <= step and free(ctx, tx, ty) then
          local d = util.distance(p, target)
          if not best_d or d < best_d then best, best_d = p, d end
        end
      end
    end
    if not best or best_d >= dist - 0.5 then return out, false end
    out[#out + 1] = best
    reserve(ctx, math.floor(best.x), math.floor(best.y), owner)
    last = best
  end
  return out, false
end

---------------------------------------------------------------------------
-- Satellites: an extra rts-stockpile with a smelter slot on each side (the CC's four stockpiles cap the hub)
---------------------------------------------------------------------------
layout.CORE_HALF = 18 -- the hidden core pole supplies a 36x36 area around the CC centre

-- True when the footprint of `name` at (x, y) lies inside the core pole's supply area.
local function core_powered(frame, name, x, y)
  local tx0, ty0, w, h = layout.footprint(name, x, y)
  local H = layout.CORE_HALF
  return tx0 >= frame.cx - H and tx0 + w <= frame.cx + H and ty0 >= frame.cy - H and ty0 + h <= frame.cy + H
end
layout.core_powered = core_powered

--- The two slots of a satellite whose stockpile is on tile (sx, sy), along `axis` ("v": north and south of the
--- stockpile, "h": west and east). Returns the stockpile spec and {{specs, ftx, fty}, {specs, ftx, fty}}.
function layout.satellite_slots(sx, sy, axis)
  local S = {x = sx + 0.5, y = sy + 0.5}
  local stock = {name = "rts-stockpile", x = S.x, y = S.y, part = "stock"}
  local slots = {}
  for _, sign in ipairs({-1, 1}) do
    local function at(d)
      if axis == "v" then return {x = S.x, y = S.y + sign * d} end
      return {x = S.x + sign * d, y = S.y}
    end
    local o, sm, i, f = at(1), at(3), at(5), at(6)
    local ux, uy = S.x - o.x, S.y - o.y -- one tile towards the stockpile
    slots[#slots + 1] = {
      specs = {
        {name = layout.INSERTER, x = i.x, y = i.y, part = "inp", pickup = {f.x, f.y},
         dir = layout.inserter_dir(f.x - i.x, f.y - i.y)},
        {name = layout.INSERTER, x = o.x, y = o.y, part = "out", pickup = {o.x - ux, o.y - uy},
         dir = layout.inserter_dir(-ux, -uy)},
        {name = layout.SMELTER, x = sm.x, y = sm.y, part = "smelter"},
      },
      ftx = math.floor(f.x), fty = math.floor(f.y),
    }
  end
  return stock, slots
end

-- Every tile of a satellite (stockpile, both slots, both feed tiles). nil when one is blocked (the router's test:
-- reserved, occupied, or on a belt link planned in this pass) or a machine would be outside the core supply area.
local function satellite_tiles(ctx, stock, slots, blocked)
  local tiles = {}
  local ok = true
  local function add(name, x, y)
    each_tile(name, x, y, function(tx, ty)
      if blocked(tx, ty) then ok = false return false end
      tiles[#tiles + 1] = {tx, ty}
    end)
    if name ~= "rts-stockpile" and not core_powered(ctx.frame, name, x, y) then ok = false end
  end
  add(stock.name, stock.x, stock.y)
  for _, sl in ipairs(slots) do
    for _, sp in ipairs(sl.specs) do add(sp.name, sp.x, sp.y) end
    if blocked(sl.ftx, sl.fty) then ok = false end
    tiles[#tiles + 1] = {sl.ftx, sl.fty}
  end
  return ok and tiles or nil
end

--- Choose a satellite reachable by belt from feed tile `from` (and from its first slot to its second): stockpile
--- candidates within SATELLITE_HALF tiles of the CC, both axes, nearest to `from` first. Reserves its tiles for
--- `owner`. Returns {stock, slots (nearer slot first), links = {route to slot 1, route slot 1 -> slot 2}} or nil.
layout.SATELLITE_HALF = 15
layout.SATELLITE_TRIES = 8
layout.SATELLITE_EXPAND = 6000 -- satellite links are short; a capped search keeps a failed candidate cheap
function layout.plan_satellite(ctx, from, blocked, owner, first)
  local f = ctx.frame
  local cands = {}
  local H = layout.SATELLITE_HALF
  for ox = -H, H - 1 do
    for oy = -H, H - 1 do
      local sx, sy = math.floor(f.cx) + ox, math.floor(f.cy) + oy
      for _, axis in ipairs({"v", "h"}) do
        local stock, slots = layout.satellite_slots(sx, sy, axis)
        local d1 = math.abs(slots[1].ftx - from[1]) + math.abs(slots[1].fty - from[2])
        local d2 = math.abs(slots[2].ftx - from[1]) + math.abs(slots[2].fty - from[2])
        if d2 < d1 then slots = {slots[2], slots[1]} end
        cands[#cands + 1] = {stock = stock, slots = slots, d = math.min(d1, d2), sx = sx, sy = sy, axis = axis}
      end
    end
  end
  table.sort(cands, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.sx ~= b.sx then return a.sx < b.sx end
    if a.sy ~= b.sy then return a.sy < b.sy end
    return a.axis < b.axis
  end)
  local tries = 0
  for _, c in ipairs(cands) do
    local tiles = satellite_tiles(ctx, c.stock, c.slots, blocked)
    if tiles then
      tries = tries + 1
      for _, t in ipairs(tiles) do reserve(ctx, t[1], t[2], owner) end
      local s1, s2 = c.slots[1], c.slots[2]
      -- as a line's first slot, the main route from the spine replaces link 1 (planned later by plan_line)
      local link1 = first and {{from[1], from[2]}, {s1.ftx, s1.fty}}
        or layout.route(ctx, from[1], from[2], nil, s1.ftx, s1.fty, blocked, layout.SATELLITE_EXPAND)
      local link2
      if link1 then
        local extra = {}
        for i = 2, #link1 - 1 do extra[tkey(link1[i][1], link1[i][2])] = true end
        link2 = layout.route(ctx, s1.ftx, s1.fty, nil, s2.ftx, s2.fty, function(tx, ty)
          return extra[tkey(tx, ty)] or blocked(tx, ty)
        end, layout.SATELLITE_EXPAND)
      end
      if link1 and link2 then
        return {stock = c.stock, slots = c.slots, links = {link1, link2}}
      end
      for _, t in ipairs(tiles) do ctx.reserved[tkey(t[1], t[2])] = nil end
      if tries >= layout.SATELLITE_TRIES then break end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Mining line plan
---------------------------------------------------------------------------
-- Direction for the end tile of a belt: keep going straight unless that would feed another belt.
local function end_direction(ctx, path, belt_tiles)
  local n = #path
  local last, prev = path[n], path[n - 1]
  local d = prev and idx_of(last[1] - prev[1], last[2] - prev[2]) or 1
  local candidates = {d, (d % 4) + 1, ((d + 2) % 4) + 1}
  for _, cd in ipairs(candidates) do
    local fx, fy = last[1] + DX[cd], last[2] + DY[cd]
    if not belt_tiles[tkey(fx, fy)] then return cd, fx, fy end
  end
  return d, last[1] + DX[d], last[2] + DY[d]
end

--- Plan a mining line for commander C: patch, spine, drills, gap poles, routes to the hub slots and the pole chain.
--- spec = orders_data.LINES entry. Reserves all its tiles. Returns a plan table or nil, reason:
---   {patch = {id, cx, cy, count, ore}, belts = {{x, y, dir, seg}, ...} (seg 0 = spine, k = up to slot k's feed),
---    drills = {{x, y, dir, g}, ...} best first, gap_poles = {[g] = {x, y}}, chain = {{x, y}, ...},
---    slots = {{name, specs = slot_specs, seg = k}, ...}, chained = bool}
--- `sink` (optional, see the header): where the line ends, default the CC (layout.cc_sink). spec.patch_id (optional)
--- names the patch to use instead of the nearest free one.
function layout.plan_line(C, ctx, line_name, spec, hostile, sink)
  sink = sink or layout.cc_sink(C)
  local sframe, shub, sorder = sink.frame, sink.hub, sink.order
  local patch, spine
  local tried = {}
  while true do
    if spec.patch_id then
      patch = nil
      if not tried[spec.patch_id] then
        for _, p in ipairs(layout.patches(ctx)) do
          if p.id == spec.patch_id then patch = p break end
        end
      end
    else
      patch = layout.pick_patch(ctx, spec.ore, C.claimed, hostile, tried)
    end
    if not patch then break end
    spine = layout.plan_spine(ctx, patch, sframe)
    if spine then break end
    tried[patch.id] = true
    util.log("ai layout: %s line %s: no room for drills on %s, trying the next patch", C.force, line_name, patch.id)
  end
  if not patch then return nil, "no free " .. spec.ore .. " patch with room for drills" end
  C.claimed[patch.id] = line_name
  local plan = {patch = {id = patch.id, cx = patch.cx, cy = patch.cy, count = patch.count, ore = patch.name},
                belts = {}, drills = {}, gap_poles = {}, chain = {}, slots = {}}
  -- reserve spine, drills, gap poles
  local belt_tiles = C.belt_tiles
  for _, t in ipairs(spine.tiles) do
    reserve(ctx, t[1], t[2], line_name)
    belt_tiles[tkey(t[1], t[2])] = true
  end
  for _, d in ipairs(spine.drills) do
    reserve_entity(ctx, layout.DRILL, d.x, d.y, line_name)
    plan.drills[#plan.drills + 1] = {x = d.x, y = d.y, dir = d.dir, g = d.g}
  end
  for g, p in pairs(spine.poles) do
    reserve(ctx, math.floor(p.x), math.floor(p.y), line_name)
    plan.gap_poles[g] = {x = p.x, y = p.y}
  end

  -- Hub slots. Each spec.slots entry is a hub slot name, an abstract type ("smelter", "chain", "direct") or "X" (a
  -- satellite). A named slot is written for a patch on spec.side ("north" or "south" of the CC) and is mirrored in y
  -- (N <-> S, 1 <-> 2) for a patch on the other side; it is the first choice. When it is taken, or its belt link
  -- fails, any free hub slot of the same type is tried, nearest to the previous feed tile (or to the spine) first.
  -- When no hub slot of a smelter type fits, a satellite on that side takes the line's next smelters ("stacked").
  -- So two lines whose patches lie on the same side of the CC (the rotated ore layout) both find slots.
  -- The short links between consecutive slots' feed tiles are routed first; then the main belt from the spine to
  -- the first slot routes around them (otherwise the main belt may arrive at slot 1 over the tile the link to slot
  -- 2 needs). When that main route fails, the line is planned again without that first slot (MAX_ATTEMPTS).
  local patch_side = (patch.cy > sframe.cy + 0.5 and "south") or (patch.cy < sframe.cy - 0.5 and "north")
    or nil
  local flip = patch_side ~= nil and patch_side ~= (spec.side or "north")
  local path = {} -- full belt path: spine, main route, links
  for _, t in ipairs(spine.tiles) do path[#path + 1] = {t[1], t[2], seg = 0} end
  local blocked_extra = {}
  local function blocked(tx, ty)
    local k = tkey(tx, ty)
    return blocked_extra[k] or not free(ctx, tx, ty)
  end
  local function take(route, seg)
    for i = 2, #route do
      local t = route[i]
      path[#path + 1] = {t[1], t[2], seg = seg}
      reserve(ctx, t[1], t[2], line_name)
      belt_tiles[tkey(t[1], t[2])] = true
      blocked_extra[tkey(t[1], t[2])] = true
    end
  end
  local spine_end = spine.tiles[#spine.tiles]

  -- One attempt at choosing slots and links. Returns slots, feeds, links.
  local function choose(exclude_first)
    local slots, feeds, links = {}, {}, {}
    local satellite, sat_used = nil, 0
    local function push(name, specs, ftx, fty, link)
      slots[#slots + 1] = {name = name, specs = specs}
      feeds[#feeds + 1] = {ftx, fty}
      if link and #slots > 1 then
        links[#slots] = link
        for i = 2, #link - 1 do blocked_extra[tkey(link[i][1], link[i][2])] = true end
      end
    end
    -- the next slot of the line's satellite (placed on first use); false when there is none
    local function use_satellite()
      if not sink.satellites then return false end
      if not satellite and sat_used == 0 then
        local from = feeds[#feeds] or spine_end
        satellite = layout.plan_satellite(ctx, from, blocked, line_name, #slots == 0)
        if not satellite then
          sat_used = -1
          util.log("ai layout: %s line %s: no room for a satellite stockpile reachable from %s", C.force,
            line_name, slots[#slots] and ("hub slot " .. slots[#slots].name) or "the spine")
        end
      end
      if not (satellite and sat_used >= 0 and sat_used < 2) then return false end
      sat_used = sat_used + 1
      local sl = satellite.slots[sat_used]
      local specs = {}
      if sat_used == 1 then specs[1] = satellite.stock end
      for _, sp in ipairs(sl.specs) do specs[#specs + 1] = sp end
      push("X" .. sat_used, specs, sl.ftx, sl.fty, satellite.links[sat_used])
      return true
    end
    for _, entry in ipairs(spec.slots) do
      if entry == "X" then
        use_satellite()
      else
        local stype = layout.slot_type(entry)
        local preferred = layout.HUB[entry] and (flip and layout.SLOT_FLIP[entry] or entry) or nil
        if preferred and shub[preferred] == nil then preferred = nil end -- not a slot of this sink
        local ref = feeds[#feeds] or spine_end
        local cands = {}
        if preferred then cands[1] = {name = preferred, d = -1} end
        for _, name in ipairs(sorder) do
          if name ~= preferred and shub[name] == "free" and layout.slot_type(name) == stype then
            local _, ftx, fty = layout.slot_specs(sframe, name)
            cands[#cands + 1] = {name = name, d = math.abs(ftx - ref[1]) + math.abs(fty - ref[2])}
          end
        end
        table.sort(cands, function(a, b)
          if a.d ~= b.d then return a.d < b.d end
          return a.name < b.name
        end)
        local placed, tried = false, 0
        for _, cand in ipairs(cands) do
          local name = cand.name
          if shub[name] == "free" and not (#slots == 0 and exclude_first[name]) then
            tried = tried + 1
            if tried > layout.SLOT_TRIES then break end
            local specs, ftx, fty = layout.slot_specs(sframe, name)
            -- claim first: the slots it kills free their tiles, which a route may need (a direct slot's feed tile
            -- is boxed in by the smelter slot it replaces)
            local snap = layout.snapshot_hub(C, sframe, shub, sorder)
            layout.claim_slot(C, sframe, name, line_name, shub, sorder)
            local link
            if #slots > 0 then
              local prev = feeds[#feeds]
              link = layout.route(ctx, prev[1], prev[2], nil, ftx, fty, blocked, layout.LINK_EXPAND)
            end
            if #slots == 0 or link then
              push(name, specs, ftx, fty, link)
              placed = true
              break
            end
            layout.restore_hub(C, snap)
          end
        end
        if not placed and not (stype == "smelter" and use_satellite()) then
          util.log("ai layout: %s line %s: no hub slot of type %s for %s", C.force, line_name, tostring(stype), entry)
        end
      end
    end
    return slots, feeds, links
  end

  local base_hub, base_reserved = {}, {}
  for k, v in pairs(shub) do base_hub[k] = v end
  for k, v in pairs(C.reserved) do base_reserved[k] = v end
  local function restore()
    for k in pairs(shub) do shub[k] = nil end
    for k, v in pairs(base_hub) do shub[k] = v end
    for k in pairs(C.reserved) do C.reserved[k] = nil end
    for k, v in pairs(base_reserved) do C.reserved[k] = v end
    for k in pairs(blocked_extra) do blocked_extra[k] = nil end
  end
  local cur_dir = idx_of(spine.along[1], spine.along[2])
  local exclude_first = {}
  for attempt = 1, layout.MAX_ATTEMPTS do
    local slots, feeds, links = choose(exclude_first)
    if #slots == 0 then break end
    local main = layout.route(ctx, spine_end[1], spine_end[2], cur_dir, feeds[1][1], feeds[1][2], blocked)
    if main then
      take(main, 1)
      plan.slots[1] = {name = slots[1].name, specs = slots[1].specs, seg = 1}
      for k = 2, #slots do
        take(links[k], k)
        plan.slots[k] = {name = slots[k].name, specs = slots[k].specs, seg = k}
      end
      break
    end
    util.log("ai layout: %s line %s: no belt route to hub slot %s (%d tiles expanded, attempt %d)", C.force,
      line_name, slots[1].name, ctx.last_expanded or 0, attempt)
    restore()
    if slots[1].name:sub(1, 1) == "X" then break end
    exclude_first[slots[1].name] = true
  end
  -- belt directions: each tile faces the next one; the end tile goes straight unless that feeds another belt
  for i, t in ipairs(path) do
    local d
    if i < #path then
      local n = path[i + 1]
      d = idx_of(n[1] - t[1], n[2] - t[2])
    else
      local fx, fy
      d, fx, fy = end_direction(ctx, path, belt_tiles)
      C.avoid[tkey(fx, fy)] = true -- nothing may ever put a belt in front of this line's end
    end
    plan.belts[#plan.belts + 1] = {x = t[1] + 0.5, y = t[2] + 0.5, dir = DEFINES[d], seg = t.seg}
  end

  -- pole chain from the gap pole nearest the sink (the CC's or the hub's hidden pole)
  local start
  local target = sink.target
  for _, p in pairs(plan.gap_poles) do
    if not start or util.distance(p, target) < util.distance(start, target) then start = p end
  end
  if start then
    local chain, ok = layout.chain_poles(ctx, start, target, line_name, sink.wire)
    plan.chain, plan.chained = chain, ok
    if not ok then
      util.log("ai layout: %s line %s: the pole chain from %s stops %.1f tiles short of the sink", C.force, line_name,
        util.pos_str(start), util.distance(chain[#chain] or start, target) - sink.wire)
    end
  end
  return plan
end

---------------------------------------------------------------------------
-- Free spots for single buildings
---------------------------------------------------------------------------
-- Preferred frame offset per building (the mirror in y counts as well), and the allowed box.
local PREFER = {
  ["rts-barracks"] = {6, 12},
  ["rts-factory"] = {-12, 6},
  ["rts-solar-array"] = {-13, -9},
  ["rts-turret"] = {19, 6},
  ["rts-lab"] = {-12, -6},
  ["rts-laser-turret"] = {14, 2},
}

-- Planned (or built) medium poles of a commander: {{x, y}, ...}.
local function planned_poles(C)
  local list = {}
  for _, e in pairs(C.plan) do
    if e.name == layout.POLE and e.status ~= "bad" then list[#list + 1] = {x = e.x, y = e.y} end
  end
  return list
end

-- Power for a powered building at pos (w x h) outside the core supply: covered by a planned pole's 7x7 supply area,
-- or by a new pole on a margin tile that is within wire reach of the CC centre or a planned pole. Returns ok and the
-- new pole position (nil when an existing pole covers it).
local function ring_power(C, frame, pos, w, h, tx0, ty0, poles)
  local sup = 3.5
  for _, p in ipairs(poles) do
    if math.abs(p.x - pos.x) < sup + w / 2 and math.abs(p.y - pos.y) < sup + h / 2 then return true, nil end
  end
  local cc = {x = frame.cx, y = frame.cy}
  for tx = tx0 - 1, tx0 + w do
    for ty = ty0 - 1, ty0 + h do
      local inside = tx >= tx0 and tx < tx0 + w and ty >= ty0 and ty < ty0 + h
      if not inside then
        local q = {x = tx + 0.5, y = ty + 0.5}
        local linked = util.distance(q, cc) <= layout.CC_WIRE
        for _, p in ipairs(poles) do
          if linked then break end
          if util.distance(q, p) <= layout.CC_WIRE then linked = true end
        end
        if linked then return true, q end
      end
    end
  end
  return false, nil
end

--- A free position for `name` near the CC (anchor "cc") or towards the enemy (anchor "front"): every footprint tile
--- and a one-tile margin free of entities, ghosts, reserved tiles and ore, and can_place_entity true.
--- "cc" first tries the core pole's supply area (POWER_HALF); when that is full it tries a second ring out to the
--- edge of the CC logistic area (LOGISTIC_HALF), where a powered building needs a planned pole nearby (lines' gap
--- and chain poles count, so buildings also go along the belt lines towards the ore) or gets a new pole on its margin.
--- "front" spots (turrets: no power needed) lie 10..LOGISTIC_HALF tiles towards the nearest enemy spawn.
--- Reserves the footprint (and the pole tile). Returns the position and the new pole position (or nil), or nil.
function layout.find_spot(C, surface, name, anchor)
  local frame = C.frame
  local p = prototypes.entity[name]
  local w, h = p.tile_width, p.tile_height
  local powered = p.electric_energy_source_prototype ~= nil
  local pref = PREFER[name] or {-10, 10}
  local passes
  if anchor == "front" and powered then
    -- a powered defence (laser turret) stays inside the core pole's supply area
    passes = {{lo_x = 8, hi_x = layout.POWER_HALF, half_y = layout.POWER_HALF}}
  elseif anchor == "front" then
    passes = {{lo_x = 10, hi_x = layout.LOGISTIC_HALF, half_y = layout.LOGISTIC_HALF}}
  else
    passes = {{lo_x = -layout.POWER_HALF, hi_x = layout.POWER_HALF, half_y = layout.POWER_HALF},
              {lo_x = -layout.LOGISTIC_HALF, hi_x = layout.LOGISTIC_HALF, half_y = layout.LOGISTIC_HALF, ring = true}}
  end
  local ox_off = (w % 2 == 1) and 0.5 or 0
  local oy_off = (h % 2 == 1) and 0.5 or 0
  local poles
  for _, pass in ipairs(passes) do
    local cands = {}
    for ox = math.ceil(pass.lo_x), math.floor(pass.hi_x) do
      for oy = -math.floor(pass.half_y), math.floor(pass.half_y) do
        local fx, fy = ox + ox_off, oy + oy_off
        local inner = math.abs(fx) <= layout.POWER_HALF and math.abs(fy) <= layout.POWER_HALF
        if math.abs(fx) + w / 2 <= pass.hi_x + 1.5 and math.abs(fy) + h / 2 <= pass.half_y + 1.5
           and not (pass.ring and inner) then
          local d1 = (fx - pref[1]) ^ 2 + (fy - pref[2]) ^ 2
          local d2 = (fx - pref[1]) ^ 2 + (fy + pref[2]) ^ 2
          cands[#cands + 1] = {fx, fy, math.min(d1, d2)}
        end
      end
    end
    table.sort(cands, function(a, b)
      if a[3] ~= b[3] then return a[3] < b[3] end
      if a[2] ~= b[2] then return a[2] < b[2] end
      return a[1] < b[1]
    end)
    local tested = 0
    for _, c in ipairs(cands) do
      local pos = layout.world(frame, c[1], c[2])
      local tx0, ty0 = layout.footprint(name, pos.x, pos.y)
      local ok = true
      for tx = tx0 - 1, tx0 + w do
        for ty = ty0 - 1, ty0 + h do
          local k = tkey(tx, ty)
          if C.reserved[k] ~= nil or C.avoid[k] or not in_arena(tx, ty) then ok = false break end
        end
        if not ok then break end
      end
      if ok then
        tested = tested + 1
        local area = {{tx0 - 1, ty0 - 1}, {tx0 + w + 1, ty0 + h + 1}}
        local pole
        if surface.count_entities_filtered({area = area, type = IGNORE_TYPES, invert = true}) == 0
           and surface.count_entities_filtered({area = {{tx0, ty0}, {tx0 + w, ty0 + h}}, type = "resource"}) == 0
           and surface.can_place_entity({name = name, position = pos, force = C.force,
                                         build_check_type = defines.build_check_type.manual}) then
          if powered and pass.ring and not core_powered(frame, name, pos.x, pos.y) then
            poles = poles or planned_poles(C)
            ok, pole = ring_power(C, frame, pos, w, h, tx0, ty0, poles)
          end
          if ok then
            for tx = tx0, tx0 + w - 1 do
              for ty = ty0, ty0 + h - 1 do C.reserved[tkey(tx, ty)] = "building" end
            end
            if pole then C.reserved[tkey(math.floor(pole.x), math.floor(pole.y))] = "building" end
            return pos, pole
          end
        end
        if tested > 400 then break end
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Forward hubs (Phase 4): patches across the map, hub sites, spots and power near a hub
---------------------------------------------------------------------------
--- Ore patches within `radius` tiles of `center` (resources only, no obstacle scan), clustered like layout.patches,
--- nearest to `center` first. Only ore inside the arena counts.
function layout.resource_patches(surface, center, radius)
  local area = {{center.x - radius, center.y - radius}, {center.x + radius, center.y + radius}}
  local ore, list = {}, {}
  for _, e in pairs(surface.find_entities_filtered({area = area, type = "resource"})) do
    local p = e.position
    local tx, ty = tile_of(p.x, p.y)
    local k = tkey(tx, ty)
    if not ore[k] and in_arena(tx, ty) then
      ore[k] = e.name
      list[#list + 1] = {k = k, tx = tx, ty = ty, name = e.name}
    end
  end
  return layout.patches({frame = {cx = center.x, cy = center.y, fx = 1}, ore = ore, ore_list = list})
end

--- Bounding box of a patch's tiles: x0, y0, x1, y1 (tiles, inclusive).
function layout.patch_box(patch)
  local x0, y0, x1, y1
  for _, cell in ipairs(patch.cells) do
    local x, y = cell[1], cell[2]
    if not x0 or x < x0 then x0 = x end
    if not x1 or x > x1 then x1 = x end
    if not y0 or y < y0 then y0 = y end
    if not y1 or y > y1 then y1 = y end
  end
  return x0, y0, x1, y1
end

-- Hub site in hub-sink frame tile offsets {x from, x to, y from, y to} ([from, to)): the hub, its two stockpiles
-- and the four "1" smelter slots with their feed tiles, plus a one-tile margin. HUB_SOLAR = world tile offsets
-- from the hub centre south of it, kept free for the solar arrays (inside the hidden pole's 16x16 supply area).
layout.HUB_SITE = {-11, 11, -9, 1}
layout.HUB_SOLAR = {-8, 8, 2, 8}
layout.HUB_RING = {7, 16}      -- hub centre this many tiles (Chebyshev) from the patch's bounding box
layout.HUB_SITE_TRIES = 400

--- The hub-sink frame of a hub centred at (hx, hy).
function layout.hub_frame(hx, hy) return {cx = hx, cy = hy + layout.HUB_SINK_DY, fx = 1} end

--- A site for a forward hub next to `patch` (context ctx around it), nearest to `home` first: the hub centre
--- {x, y} (a tile corner) whose site and solar boxes are free of entities, water, ore, reserved tiles and the arena
--- edge, at least `min_home` tiles from home along x or y (square logistic areas) and `min_apart` tiles from every
--- position in `keep_away` (hubs).
function layout.hub_site(C, ctx, patch, home, min_home, keep_away, min_apart)
  local x0, y0, x1, y1 = layout.patch_box(patch)
  local lo, hi = layout.HUB_RING[1], layout.HUB_RING[2]
  local cands = {}
  for hx = x0 - hi, x1 + 1 + hi do
    for hy = y0 - hi, y1 + 1 + hi do
      local d = math.max(x0 - hx, 0, hx - (x1 + 1), y0 - hy, hy - (y1 + 1))
      if d >= lo and d <= hi then
        local dh = util.distance({hx, hy}, home)
        -- roboport areas are squares: a separate network needs the Chebyshev distance, not the straight one
        local ok = math.max(math.abs(hx - home.x), math.abs(hy - home.y)) >= min_home
        for _, p in ipairs(keep_away or {}) do
          if ok and util.distance({hx, hy}, p) < (min_apart or min_home) then ok = false end
        end
        if ok then cands[#cands + 1] = {hx, hy, dh + 3 * d} end
      end
    end
  end
  table.sort(cands, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  local S, P = layout.HUB_SITE, layout.HUB_SOLAR
  local function box_free(tx0, tx1, ty0, ty1)
    for tx = tx0, tx1 - 1 do
      for ty = ty0, ty1 - 1 do
        local k = tkey(tx, ty)
        if not free(ctx, tx, ty) or ctx.ore[k] then return false end
      end
    end
    return true
  end
  for i, c in ipairs(cands) do
    if i > layout.HUB_SITE_TRIES then break end
    local hx, hy = c[1], c[2]
    local cy = hy + layout.HUB_SINK_DY
    if box_free(hx + S[1], hx + S[2], cy + S[3], cy + S[4]) and box_free(hx + P[1], hx + P[2], hy + P[3], hy + P[4])
       and ctx.surface.can_place_entity({name = "rts-hub", position = {hx, hy}, force = C.force}) then
      return {x = hx, y = hy}
    end
  end
  return nil
end

--- Reserve the hub body and its two stockpile tiles (logistics.lua places the stockpiles when the hub is built).
function layout.reserve_hub_body(C, hx, hy, owner)
  for tx = hx - 2, hx + 1 do
    for ty = hy - 2, hy + 1 do C.reserved[tkey(tx, ty)] = owner end
  end
  C.reserved[tkey(hx - 4, hy)] = owner
  C.reserved[tkey(hx + 3, hy)] = owner
end

--- A free spot for `name` whose footprint lies inside world tiles [x0, x1) x [y0, y1), nearest to `pref` first:
--- no reserved or avoided tile, no entity, no ore, can_place_entity. Reserves the footprint. Returns the position.
function layout.find_spot_in(C, surface, name, x0, y0, x1, y1, pref)
  local p = prototypes.entity[name]
  local w, h = p.tile_width, p.tile_height
  local cands = {}
  for tx = x0, x1 - w do
    for ty = y0, y1 - h do
      local pos = {x = tx + w / 2, y = ty + h / 2}
      cands[#cands + 1] = {pos, (pos.x - pref.x) ^ 2 + (pos.y - pref.y) ^ 2, tx, ty}
    end
  end
  table.sort(cands, function(a, b)
    if a[2] ~= b[2] then return a[2] < b[2] end
    if a[3] ~= b[3] then return a[3] < b[3] end
    return a[4] < b[4]
  end)
  for _, c in ipairs(cands) do
    local pos, tx0, ty0 = c[1], c[3], c[4]
    local ok = true
    for tx = tx0, tx0 + w - 1 do
      for ty = ty0, ty0 + h - 1 do
        local k = tkey(tx, ty)
        if C.reserved[k] ~= nil or C.avoid[k] or not in_arena(tx, ty) then ok = false break end
      end
      if not ok then break end
    end
    if ok and surface.count_entities_filtered({area = {{tx0, ty0}, {tx0 + w, ty0 + h}}, type = IGNORE_TYPES,
                                               invert = true}) == 0
       and surface.count_entities_filtered({area = {{tx0, ty0}, {tx0 + w, ty0 + h}}, type = "resource"}) == 0
       and surface.can_place_entity({name = name, position = pos, force = C.force,
                                     build_check_type = defines.build_check_type.manual}) then
      for tx = tx0, tx0 + w - 1 do
        for ty = ty0, ty0 + h - 1 do C.reserved[tkey(tx, ty)] = "building" end
      end
      return pos
    end
  end
  return nil
end

--- Poles so that every powered entity in `specs` ({name, x, y}) overlaps a supply area: the hub's hidden pole
--- (HUB_POLE_HALF around the hub centre, conservative for the 0.7-tile snap) or a medium pole of `poles` (planned
--- gap and chain poles). A missing one gets a medium pole on a free tile next to it, within HUB_WIRE of the hub
--- centre or wire reach of a pole. Reserves the tiles; returns the new pole positions.
layout.HUB_POLE_HALF = 7.5
function layout.cover_power(C, ctx, hub_pos, specs, poles, owner)
  local out = {}
  local function covered(x0, y0, x1, y1)
    local H = layout.HUB_POLE_HALF
    if x0 < hub_pos.x + H and x1 > hub_pos.x - H and y0 < hub_pos.y + H and y1 > hub_pos.y - H then return true end
    for _, p in ipairs(poles) do
      if x0 < p.x + 3.5 and x1 > p.x - 3.5 and y0 < p.y + 3.5 and y1 > p.y - 3.5 then return true end
    end
    return false
  end
  for _, sp in ipairs(specs) do
    local proto = prototypes.entity[sp.name]
    if proto and proto.electric_energy_source_prototype then
      local tx0, ty0, w, h = layout.footprint(sp.name, sp.x, sp.y)
      if not covered(tx0, ty0, tx0 + w, ty0 + h) then
        local best
        for tx = tx0 - 1, tx0 + w do
          for ty = ty0 - 1, ty0 + h do
            if not best and free(ctx, tx, ty) then
              local q = {x = tx + 0.5, y = ty + 0.5}
              local linked = util.distance(q, hub_pos) <= layout.HUB_WIRE
              for _, p in ipairs(poles) do
                if not linked and util.distance(q, p) <= layout.CC_WIRE then linked = true end
              end
              if linked then best = q end
            end
          end
        end
        if best then
          reserve(ctx, math.floor(best.x), math.floor(best.y), owner)
          poles[#poles + 1] = best
          out[#out + 1] = best
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- ASCII map of a commander's plan (debug: /rts-ai-map and the autotest)
---------------------------------------------------------------------------
local GLYPH = {["rts-extractor"] = "D", ["rts-smelter"] = "S", ["fast-inserter"] = "i", ["medium-electric-pole"] = "P",
               ["rts-barracks"] = "B", ["rts-factory"] = "F", ["rts-solar-array"] = "Z", ["rts-turret"] = "T",
               ["rts-command-center"] = "C", ["rts-stockpile"] = "K", ["rts-hub"] = "H", ["rts-lab"] = "L",
               ["rts-laser-turret"] = "Y"}
local BELT_GLYPH = {[DIR.north] = "^", [DIR.east] = ">", [DIR.south] = "v", [DIR.west] = "<"}
local ORE_GLYPH = {["iron-ore"] = ".", ["copper-ore"] = ",", ["stone"] = ":", ["coal"] = ";"}

--- Text rows of the plan of commander C in the world box [x0, x1) x [y0, y1) (tile coordinates). Lower case
--- letters are planned entries that are not built (yet); "#" = hub tiles reserved for unused slots, "x" = bad.
function layout.ascii(C, surface, x0, y0, x1, y1)
  local grid = {}
  local function put(tx, ty, ch)
    if tx >= x0 and tx < x1 and ty >= y0 and ty < y1 then grid[tkey(tx, ty)] = ch end
  end
  for _, e in pairs(surface.find_entities_filtered({area = {{x0, y0}, {x1, y1}}, type = "resource"})) do
    local tx, ty = tile_of(e.position.x, e.position.y)
    put(tx, ty, ORE_GLYPH[e.name] or "o")
  end
  for k, owner in pairs(C.reserved) do
    if owner == "hub" then
      local ty = k % 4096
      if ty >= 2048 then ty = ty - 4096 end
      put((k - ty) / 4096, ty, "#")
    end
  end
  for _, e in pairs(surface.find_entities_filtered({area = {{x0, y0}, {x1, y1}}, force = C.force,
                                                     name = {"rts-command-center", "rts-stockpile", "rts-hub"}})) do
    each_tile(e.name, e.position.x, e.position.y, function(tx, ty) put(tx, ty, GLYPH[e.name]) end)
  end
  for _, e in pairs(C.plan) do
    local built = e.status == "built" and e.entity and e.entity.valid
    local ch
    if e.name == layout.BELT then ch = BELT_GLYPH[e.dir] or "=" else ch = GLYPH[e.name] or "?" end
    if e.status == "bad" then ch = "x" elseif not built and e.name ~= layout.BELT then ch = string.lower(ch) end
    each_tile(e.name, e.x, e.y, function(tx, ty) put(tx, ty, ch) end)
  end
  local rows = {}
  for ty = y0, y1 - 1 do
    local row = {}
    for tx = x0, x1 - 1 do row[#row + 1] = grid[tkey(tx, ty)] or " " end
    rows[#rows + 1] = string.format("%4d |%s|", ty, table.concat(row))
  end
  return rows
end

return layout
