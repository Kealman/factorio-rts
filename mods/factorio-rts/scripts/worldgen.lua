-- Phase 5 M3 world3 (docs/PHASE5-M3.md D8, §3 "worldgen.lua"; study docs/research/scale/world-map.md §4.3): how a
-- Nation world comes into existence. scripts/world.lua plans the world (skeleton, sites, regions) and places single
-- features; this module assigns every planned feature and label to chunks, generates a blocking core before the match
-- starts and requests the rest in the background while the match runs.
--
--   worldgen.plan(seed, size, nations) -> plan   world.plan plus worldgen.index: plan.features (ore patches, oil fields,
--                                                uranium, rare deposits, ruins, ports, city-states), plan.labels (region
--                                                names, choke markers, port names), plan.chunk_index = {[chunk key] =
--                                                {f = {feature index, ...}, l = {label index, ...}}}, plan.core (the
--                                                forced core), plan.site_chunks (requested first in the background:
--                                                the spawn squares' corners, the city-state and port squares)
--   worldgen.core_chunks(plan) -> {{x, y}, ...}  the forced core: chunks within CORE_SPAWN of every spawn (a disc:
--                                                chunk centres within CORE_DISC chunks; clipped to the map)
--   worldgen.start(surface, plan)               storage.world, the forced core, cleared spawn areas, every feature whose
--                                                chunks exist (the start kits), then request_rest (world.apply calls it)
--   worldgen.generate_core()                    force_generate_chunk_requests on the core (logs its duration)
--   worldgen.request_rest()                     the background order: the site chunks (the corners of the CORE_SPAWN
--                                                squares, CORE_SITE around every city-state, CORE_PORT around every
--                                                port), then every chunk with a
--                                                feature or a label, then ring by ring from the spawns (8-connected chunk
--                                                BFS); WINDOW chunks in flight
--   worldgen.on_chunk_generated(event)          counts the chunk, places the features whose chunks all exist, emits
--                                                "rts_world_labels" {labels} (scripts/strategic.lua draws them), charts the
--                                                chunk for the survey; idempotent
--   worldgen.progress() -> {generated, planned, share, done, inflight, core}
--   worldgen.generated(position) -> bool        the chunk at a position exists (AI planners: only generated cells)
--   worldgen.request_area(force, area) -> requested, ready
--                                                AI planners ask for chunks they want; they go ahead of the ring order
--   worldgen.reset()                            match teardown (match.lua's list)
--
-- Legacy order: a world of 2-4 nations up to 2048 (the M1/M2 acceptance worlds) is generated in M2's order, request
-- for request: 13 x 13 chunks around every spawn forced, the city-states' 3 x 3 chunks, then the whole map in one
-- request. The engine's generation order shows at chunk seams (a few tiles, trees and decoratives; measured), and an AI
-- match at the same seed then plays out differently (the M1 acceptance at seed 501 lost a depot in a war and its train
-- goal), so these worlds stay identical to M2's. Bigger worlds (3072, 4096) and 5-6 nations use the forced spawn discs
-- and the windowed background order above.
--
-- Survey (config.survey, lobby "Map: Survey"): the charted forces (fog.charted_forces) get every generated chunk charted
-- at the start and each new chunk as it arrives; on_chunk_charted counts them in a module-local table for QA
-- (worldgen.charted(force)): a headless server charts nothing while GUI peers do, so chart state never reaches storage
-- or a decision (every decision here reads is_chunk_generated and the plan).
-- The HUD shows "World: 63 % generated" under the minimap while the fill runs (the frame is the minimap's width).
--
-- Owns storage.worldgen = {surface, phase = "core" | "running" | "done", legacy?, order = {chunk key}, cursor, n_sites,
--   priority, inflight = {[key] = tick}, n_inflight, gen = {[key] = true} (in-map chunks seen generated), core_count,
--   area = {[force] = chunks requested}, area_total, survey, survey_started, sweeps}.
-- storage.world.fill = {total, generated, done, started, done_tick, last} stays world.lua's record (world.ready()).
local util = require("scripts.util")
local events = require("scripts.events")
local mapgen = require("scripts.mapgen")
local world = require("scripts.world")

local worldgen = {}

local ok_balance, balance = pcall(require, "balance")
local B = (ok_balance and type(balance) == "table" and balance.nation and balance.nation.world3) or {}
local BC = B.core or {}
-- The forced core is a disc around every spawn only: a separate square costs about 0.2-0.3 s of blocking generation on
-- top of its chunks (bench at 4096 x 6: 726 spawn chunks 2.97 s; with 8 city-states x 49 and 5 ports x 9 chunks
-- 5.49 s), so the city-state and port squares head the background order instead (all there about 12 s into a 4096
-- match). A disc (chunk centres within 5 chunks: 81 chunks) instead of the 11 x 11 square (121): 2.3 instead of 2.9 s,
-- and a GUI client, which renders while it generates, stays under 3 s too; the corners come first in the background.
worldgen.CORE_SPAWN = BC.spawn or 5   -- chunks around every spawn: chunk centres within CORE_DISC chunks are forced
worldgen.CORE_DISC = BC.disc or 5     -- (81 chunks, at least 115 tiles around the spawn: the start kit reaches 80)
worldgen.CORE_SITE = BC.site or 3     -- chunks around every city-state (first in the background: its land, garrison)
worldgen.CORE_PORT = BC.port or 1     -- chunks around every port (the trade post)
worldgen.LEGACY_CORE = 6              -- legacy order: the M1/M2 core, a 13 x 13 square around every spawn
worldgen.WINDOW = B.window or 160     -- requested chunks in flight
worldgen.PERIOD = B.period or 15      -- ticks between requester steps
worldgen.WATCHDOG = B.watchdog or 3600
worldgen.AREA_MAX = B.area_max or 400
worldgen.HUD_PERIOD = B.hud_period or 60
worldgen.HUD_NAME = "rts_worldgen_progress"
worldgen.MINIMAP_FRAME = "rts_hud_minimap_frame" -- scripts/hud.lua NAMES.minimap_frame
worldgen.MINIMAP_FRAME_SIZE = 228                -- scripts/hud.lua MINIMAP_FRAME_SIZE (GUI units)

local floor, max, min = math.floor, math.max, math.min
local chunk_key = world.chunk_key
local function key_xy(key)
  local cx = floor(key / 2048) - 1024
  return cx, key - (cx + 1024) * 2048 - 1024
end
worldgen.key_xy = key_xy

--- Module lookup at call time (fog, cities, strategic load after this module).
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

local function Q() return storage.worldgen end

local function in_map(half_chunks, cx, cy)
  return cx >= -half_chunks and cx < half_chunks and cy >= -half_chunks and cy < half_chunks
end

---------------------------------------------------------------------------
-- Plan: features and labels per chunk, the core
---------------------------------------------------------------------------
-- Chunk keys of squares (or discs: chunk centres within `disc` chunks of the point's chunk) around points, inside the
-- map, each once (`set` is shared between calls).
local function squares(P, set, list, points, r, disc)
  local c = P.size / 64
  local r2 = disc and disc ^ 2 or 0
  for _, p in ipairs(points) do
    local cx0, cy0 = floor(p.x / 32), floor(p.y / 32)
    for cx = max(-c, cx0 - r), min(c - 1, cx0 + r) do
      for cy = max(-c, cy0 - r), min(c - 1, cy0 + r) do
        local key = chunk_key(cx, cy)
        if not set[key] and (not disc or (cx - cx0) ^ 2 + (cy - cy0) ^ 2 <= r2) then
          set[key] = true
          list[#list + 1] = key
        end
      end
    end
  end
  return list
end

--- Does a plan keep M2's generation order? 2-4 nations up to 2048 (the M1/M2 acceptance worlds).
function worldgen.legacy(P)
  return P.size <= 2048 and not P.xl
end

--- The forced core of a plan: a disc of CORE_SPAWN around every spawn (plan order), and the chunks requested first in
--- the background: the rest of the CORE_SPAWN square around every spawn (the corners the start view and the start
--- chart reach), CORE_SITE around every city-state, then CORE_PORT around every port. Legacy order: the LEGACY_CORE
--- square around every spawn, nothing first (world.apply of M2).
local function core_keys(P)
  local set = {}
  if worldgen.legacy(P) then return squares(P, set, {}, P.spawns, worldgen.LEGACY_CORE), {} end
  local core = squares(P, set, {}, P.spawns, worldgen.CORE_SPAWN, worldgen.CORE_DISC)
  local first = squares(P, set, {}, P.spawns, worldgen.CORE_SPAWN) -- the square's corners
  local cs, ports = {}, {}
  for _, s in ipairs(P.sites) do
    if s.kind == "city_state" then cs[#cs + 1] = s.position elseif s.kind == "port" then ports[#ports + 1] = s.position end
  end
  squares(P, set, first, cs, worldgen.CORE_SITE)
  squares(P, set, first, ports, worldgen.CORE_PORT)
  return core, first
end

--- The core of a plan as chunk positions {{x, y}, ...}.
function worldgen.core_chunks(P)
  local out = {}
  for i, key in ipairs(P.core or (core_keys(P))) do
    local cx, cy = key_xy(key)
    out[i] = {x = cx, y = cy}
  end
  return out
end

--- Assign every feature and label of a plan to chunks: plan.features, plan.labels, plan.chunk_index, plan.core.
function worldgen.index(P)
  local c = P.size / 64
  P.features = P.features or world.build_features(P)
  local idx = {}
  local function entry(key)
    local e = idx[key]
    if not e then
      e = {}
      idx[key] = e
    end
    return e
  end
  for i, f in ipairs(P.features) do
    local b = f.box
    f.chunks = {}
    for cx = floor(b.x0 / 32), floor((b.x1 - 0.001) / 32) do
      for cy = floor(b.y0 / 32), floor((b.y1 - 0.001) / 32) do
        if in_map(c, cx, cy) then -- out-of-map tiles hold nothing and are never requested
          local key = chunk_key(cx, cy)
          f.chunks[#f.chunks + 1] = key
          local e = entry(key)
          e.f = e.f or {}
          e.f[#e.f + 1] = i
        end
      end
    end
  end
  -- chart labels (scripts/strategic.lua): a region's name at its centre, a choke's marker, a port's name
  P.labels = {}
  local function label(kind, id, pos)
    local cx, cy = floor(pos.x / 32), floor(pos.y / 32)
    local key = chunk_key(max(-c, min(c - 1, cx)), max(-c, min(c - 1, cy)))
    P.labels[#P.labels + 1] = {kind = kind, id = id, chunk = key}
    local e = entry(key)
    e.l = e.l or {}
    e.l[#e.l + 1] = #P.labels
  end
  for _, reg in ipairs(P.regions) do label("region", reg.id, reg.center) end
  for _, ch in ipairs(P.chokes) do label("choke", ch.id, ch.position) end
  for i, s in ipairs(P.sites) do
    if s.kind == "port" then label("port", i, s.position) end
  end
  P.chunk_index = idx
  P.core, P.site_chunks = core_keys(P)
  return P
end

--- Plan a world (scripts/world.lua) and index it. `nations` 2-6 (at most 4 on 2048); `size` one of world.SIZES.
function worldgen.plan(seed, size, nations)
  local P = world.plan({nations = nations, world_size = size}, seed)
  return worldgen.index(P)
end

---------------------------------------------------------------------------
-- Generation
---------------------------------------------------------------------------
local function surface_of()
  local q = Q()
  return q and q.surface and game.surfaces[q.surface] or nil
end

local function chunk_ready(surface, key)
  local cx, cy = key_xy(key)
  return surface.is_chunk_generated({cx, cy})
end

-- Place a feature once every chunk of its box exists. Returns true when it was placed now.
local function try_place(surface, W, f)
  if f.placed then return false end
  for _, key in ipairs(f.chunks or {}) do
    if not chunk_ready(surface, key) then return false end
  end
  world.place_feature(surface, W, f)
  return true
end

-- Count an in-map chunk once (storage.worldgen.gen); the survey charts it.
local function count_chunk(q, W, surface, key)
  if q.gen[key] then return false end
  local cx, cy = key_xy(key)
  if not in_map(W.size / 64, cx, cy) then return false end
  q.gen[key] = true
  W.fill.generated = W.fill.generated + 1
  W.fill.last = game.tick
  if q.survey_started then worldgen.chart_chunk(surface, cx, cy) end
  return true
end

--- Force the core (storage.world.plan.core) to generate now. Returns the LuaProfiler of the call.
function worldgen.generate_core()
  local q = Q()
  local surface = surface_of()
  local P = q.plan or (storage.world and storage.world.plan)
  local prof = helpers.create_profiler()
  if worldgen.legacy(P) then -- M2's requests: a square per spawn
    for _, sp in ipairs(P.spawns) do surface.request_to_generate_chunks({sp.x, sp.y}, worldgen.LEGACY_CORE) end
  else
    for _, key in ipairs(P.core) do
      local cx, cy = key_xy(key)
      surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
    end
  end
  surface.force_generate_chunk_requests()
  prof.stop()
  return prof
end

--- Generate the world on `surface` (created with world.map_gen_settings(plan)): the blocking core around the spawns,
--- cleared spawn areas, every feature whose chunks exist (the start kits); the rest in the background (request_rest:
--- the city-state and port sites first; on_chunk_generated). Writes storage.world and storage.worldgen.
function worldgen.start(surface, P)
  local prof = helpers.create_profiler()
  if not P.chunk_index then worldgen.index(P) end
  surface.map_gen_settings = world.map_gen_settings(P)
  surface.always_day = true
  local m = storage.match
  storage.worldgen = {surface = surface.name, phase = "core", plan = P, cursor = 1, order = {}, inflight = {},
                      n_inflight = 0, gen = {}, area = {}, sweeps = 0,
                      survey = (m and m.config and m.config.survey) and true or nil}
  local q = storage.worldgen
  local core = worldgen.generate_core()
  q.plan = nil
  local W = {size = P.size, seed = P.seed, surface = surface.name, plan = P, regions = P.regions, sites = P.sites,
             chokes = P.chokes, region_grid = P.region_grid, region_grid_n = P.region_grid_n, spawns = {}, oil = {},
             checks = {}, started = game.tick, features = P.features}
  for _, sp in ipairs(P.spawns) do W.spawns[#W.spawns + 1] = {force = sp.force, position = {x = sp.x, y = sp.y}} end
  W.fill = {total = (P.size / 32) ^ 2, generated = 0, started = game.tick, last = game.tick}
  storage.world = W
  mapgen.adopt(surface.name, "world", P.size)
  -- count what exists (the core; on_chunk_generated of the forced chunks did not count them)
  for _, key in ipairs(P.core) do
    if chunk_ready(surface, key) then count_chunk(q, W, surface, key) end
  end
  q.core_count = W.fill.generated
  local cleared = 0
  for _, sp in ipairs(P.spawns) do
    for _, e in pairs(surface.find_entities_filtered({position = {sp.x, sp.y}, radius = world.CLEAR_RADIUS,
                                                      type = world.CLEAR_TYPES})) do
      if e.valid then
        e.destroy()
        cleared = cleared + 1
      end
    end
  end
  W.city_states = {} -- Phase 5 M2 world: founded when their ground exists (world.place_feature)
  world.neutral_force()
  local placed = 0
  for _, f in ipairs(P.features) do
    if try_place(surface, W, f) then placed = placed + 1 end
  end
  worldgen.request_rest()
  q.phase = "running"
  prof.stop()
  -- start kit check (placed now: inside the core)
  local kit = {}
  for _, f in ipairs(P.features) do
    if f.type == "patch" and (f.kind == "main" or f.kind == "natural") then
      local sp
      for _, s in ipairs(P.spawns) do if s.force == f.force then sp = s end end
      local d = math.sqrt((f.x - sp.x) ^ 2 + (f.y - sp.y) ^ 2) + max(f.w, f.h) / 2
      kit[#kit + 1] = {force = f.force, name = f.name, kind = f.kind, placed = f.placed and true or false,
                       tiles = f.tiles or 0, amount = f.amount or 0, total = f.total, dist = d}
    end
  end
  W.checks.kit = kit
  W.checks.core_chunks = W.fill.generated
  local n_cs, n_ports = 0, 0
  for _, s in ipairs(P.sites) do
    if s.kind == "city_state" then n_cs = n_cs + 1 elseif s.kind == "port" then n_ports = n_ports + 1 end
  end
  local bg = q.legacy and string.format("the ground of %d city-states, then the whole map (%d chunks) in one request "
    .. "(M2 order)", n_cs, W.fill.total - W.fill.generated)
    or string.format("%d of %d chunks in the request order (%d site chunks: radius %d around %d city-states, %d around "
    .. "%d ports, the spawn squares' corners first; then %d feature and label chunks), window %d", #q.order,
    W.fill.total - W.fill.generated,
    q.n_sites or 0, worldgen.CORE_SITE, n_cs, worldgen.CORE_PORT, n_ports, q.priority or 0, worldgen.WINDOW)
  log({"", string.format("[rts] world: %s generated: core %d chunks (%s around %d spawns), %d trees/rocks "
    .. "cleared, %d of %d features placed; background: %s; core in ", surface.name, W.fill.generated,
    q.legacy and ("square of radius " .. worldgen.LEGACY_CORE .. ", M2 order") or ("disc of radius " .. worldgen.CORE_SPAWN),
    #P.spawns, cleared, placed, #P.features, bg), core, "; start in ", prof})
  return W
end

--- Build the background request order: the site chunks (city-states, then ports), every chunk with a feature or a
--- label (nearest to a spawn first), then every other chunk ring by ring from the spawns (an 8-connected BFS over the
--- chunk grid from the spawns' chunks). Already generated chunks are left out. Starts the first window. Returns the
--- number of chunks in the order.
function worldgen.request_rest()
  local q, W = Q(), storage.world
  local surface = surface_of()
  local P = W.plan
  local c = P.size / 64
  local n = 2 * c
  if worldgen.legacy(P) then -- M2's requests: the city-states' ground, then the whole map at once
    for _, s in ipairs(P.sites) do
      if s.kind == "city_state" then surface.request_to_generate_chunks(s.position, 1) end
    end
    surface.request_to_generate_chunks({0, 0}, math.ceil(P.half / 32))
    q.legacy, q.order, q.cursor, q.n_sites, q.priority = true, {}, 1, 0, 0
    return W.fill.total - W.fill.generated
  end
  -- BFS from the spawn chunks; ring[k] in chunks (k = local index (cy + c) * n + (cx + c) + 1)
  local seen, bfs = {}, {}
  local head = 1
  for _, sp in ipairs(P.spawns) do
    local cx, cy = max(-c, min(c - 1, floor(sp.x / 32))), max(-c, min(c - 1, floor(sp.y / 32)))
    local k = (cy + c) * n + (cx + c) + 1
    if not seen[k] then
      seen[k] = true
      bfs[#bfs + 1] = k
    end
  end
  while head <= #bfs do
    local k = bfs[head]
    head = head + 1
    local i = (k - 1) % n
    local j = (k - 1 - i) / n
    for dj = -1, 1 do
      for di = -1, 1 do
        local ii, jj = i + di, j + dj
        if (di ~= 0 or dj ~= 0) and ii >= 0 and jj >= 0 and ii < n and jj < n then
          local nk = jj * n + ii + 1
          if not seen[nk] then
            seen[nk] = true
            bfs[#bfs + 1] = nk
          end
        end
      end
    end
  end
  local order, taken = {}, {}
  for _, key in ipairs(P.site_chunks or {}) do
    if not taken[key] and not q.gen[key] and not chunk_ready(surface, key) then
      taken[key] = true
      order[#order + 1] = key
    end
  end
  local n_sites = #order
  local prio = {}
  for key in pairs(P.chunk_index) do prio[key] = true end
  local rest = {}
  for _, k in ipairs(bfs) do
    local i = (k - 1) % n
    local j = (k - 1 - i) / n
    local key = chunk_key(i - c, j - c)
    if not taken[key] and not q.gen[key] and not chunk_ready(surface, key) then
      if prio[key] then order[#order + 1] = key else rest[#rest + 1] = key end
    end
  end
  local n_prio = #order - n_sites
  for _, key in ipairs(rest) do order[#order + 1] = key end
  q.order, q.cursor, q.n_sites, q.priority = order, 1, n_sites, n_prio
  worldgen.refill(surface)
  return #order
end

--- Keep WINDOW chunks in flight: request the next chunks of the order (radius 0: one chunk each).
function worldgen.refill(surface)
  local q, W = Q(), storage.world
  surface = surface or surface_of()
  if not (q and W and surface) or q.legacy then return 0 end
  local want = worldgen.WINDOW - q.n_inflight
  local order = q.order
  local made = 0
  while want > 0 and q.cursor <= #order do
    local key = order[q.cursor]
    q.cursor = q.cursor + 1
    if not q.gen[key] and not q.inflight[key] then
      if chunk_ready(surface, key) then
        count_chunk(q, W, surface, key) -- generated without an event we saw (a unit's radar, another module)
      else
        local cx, cy = key_xy(key)
        surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
        q.inflight[key] = game.tick
        q.n_inflight = q.n_inflight + 1
        want = want - 1
        made = made + 1
      end
    end
  end
  return made
end

--- A chunk was generated (on_chunk_generated on the world's surface): count it, place every feature whose chunks now
--- all exist, hand its labels to the strategic layer, finish the fill with the last chunk. Idempotent.
function worldgen.on_chunk_generated(e)
  local q, W = Q(), storage.world
  if not (q and W and W.plan and W.fill) then return end
  local surface = e.surface
  local key = chunk_key(e.position.x, e.position.y)
  if q.inflight[key] then
    q.inflight[key] = nil
    q.n_inflight = q.n_inflight - 1
  end
  count_chunk(q, W, surface, key)
  local P = W.plan
  local entry = P.chunk_index[key]
  if entry then
    for _, i in ipairs(entry.f or {}) do try_place(surface, W, P.features[i]) end
    if entry.l then
      local list = {}
      for _, li in ipairs(entry.l) do list[#list + 1] = P.labels[li] end
      events.emit("rts_world_labels", {labels = list})
    end
  end
  if not W.fill.done and W.fill.generated >= W.fill.total then
    q.phase = "done"
    world.finish_fill(surface, W)
    util.log("world: background generation done: %d chunks (%d core, %s, %d by area requests, %d sweeps) in %.1f s of "
      .. "game time", W.fill.generated, q.core_count or 0, q.legacy and "the rest in one request (M2 order)"
      or ((q.cursor - 1) .. " requested in the background"), q.area_total or 0, q.sweeps,
      (game.tick - W.fill.started) / 60)
  end
end

events.on(defines.events.on_chunk_generated, function(e)
  local q = Q()
  if not (q and q.phase ~= "core" and e.surface.name == q.surface) then return end
  worldgen.on_chunk_generated(e)
end)

-- Every chunk of the map that is not generated, requested again; generated ones counted. The last resort when the
-- order is used up and the fill is still short (chunks lost from the engine's queue).
local function sweep(surface)
  local q, W = Q(), storage.world
  local c = W.size / 64
  local requested = 0
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      local key = chunk_key(cx, cy)
      if not q.gen[key] then
        if surface.is_chunk_generated({cx, cy}) then
          count_chunk(q, W, surface, key)
        elseif not q.inflight[key] then
          surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
          q.inflight[key] = game.tick
          q.n_inflight = q.n_inflight + 1
          requested = requested + 1
        end
      end
    end
  end
  q.sweeps = q.sweeps + 1
  return requested
end

events.on_nth_tick(worldgen.PERIOD, function()
  local q, W = Q(), storage.world
  if not q and W and W.plan and W.fill and not W.fill.done then -- a filling world from an older save
    worldgen.init()
    q = Q()
  end
  if not (q and q.phase == "running" and W and W.fill and not W.fill.done) then return end
  local surface = surface_of()
  if not surface then return end
  if q.survey and not q.survey_started then worldgen.survey_start(surface) end
  worldgen.refill(surface)
  if not q.legacy and q.cursor > #q.order and q.n_inflight == 0 and not W.fill.done then
    local n = sweep(surface)
    util.log("world: request order used up at %d/%d chunks: sweep %d requested %d", W.fill.generated, W.fill.total,
      q.sweeps, n)
    if W.fill.generated >= W.fill.total and not W.fill.done then
      q.phase = "done"
      world.finish_fill(surface, W)
    end
  end
end)

-- Watchdog: no chunk for WATCHDOG ticks (a save loaded while the engine's queue was lost) -> every chunk in flight is
-- requested again.
events.on_nth_tick(600, function()
  local q, W = Q(), storage.world
  if not (q and q.phase == "running" and W and W.fill and not W.fill.done) then return end
  if game.tick - W.fill.last < worldgen.WATCHDOG then return end
  local surface = surface_of()
  if not surface then return end
  if q.legacy then -- M2's watchdog: the whole map again
    surface.request_to_generate_chunks({0, 0}, math.ceil(W.size / 64))
    W.fill.last = game.tick
    util.log("world: no chunk of the fill finished for %d s (%d/%d chunks), generation requested again",
      worldgen.WATCHDOG / 60, W.fill.generated, W.fill.total)
    return
  end
  local n = 0
  for key in pairs(q.inflight) do
    local cx, cy = key_xy(key)
    surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
    q.inflight[key] = game.tick
    n = n + 1
  end
  W.fill.last = game.tick
  util.log("world: no chunk generated for %d s (%d/%d chunks): %d chunks in flight requested again",
    worldgen.WATCHDOG / 60, W.fill.generated, W.fill.total, n)
end)

---------------------------------------------------------------------------
-- Queries and requests
---------------------------------------------------------------------------
--- {generated, planned, share, done, inflight, core} of the running world (zeros without one).
function worldgen.progress()
  local W, q = storage.world, Q()
  local F = W and W.fill
  if not F then return {generated = 0, planned = 0, share = 0, done = false, inflight = 0, core = 0} end
  return {generated = F.generated, planned = F.total, share = F.total > 0 and F.generated / F.total or 0,
          done = F.done and true or false, inflight = q and q.n_inflight or 0, core = q and q.core_count or 0}
end

--- Does the chunk at `position` exist? (false without a world)
function worldgen.generated(position)
  local W = storage.world
  local surface = W and W.surface and game.surfaces[W.surface]
  if not (surface and position) then return false end
  local x, y = util.xy(position)
  if not (x and y) then return false end
  return surface.is_chunk_generated({floor(x / 32), floor(y / 32)})
end

--- Ask for the chunks of `area` ({left_top, right_bottom} or {{x0, y0}, {x1, y1}}) for `force` (a name or a LuaForce):
--- the missing ones are requested now, ahead of the ring order (at most AREA_MAX per call). Returns the number of
--- chunks requested and the number already generated.
function worldgen.request_area(force, area)
  local q, W = Q(), storage.world
  local surface = surface_of()
  if not (q and W and W.fill and surface and area) then return 0, 0 end
  local force_name = type(force) == "string" and force or (force and force.name) or "?"
  local a, b = area.left_top or area[1], area.right_bottom or area[2]
  local ax, ay = util.xy(a)
  local bx, by = util.xy(b)
  if not (ax and ay and bx and by) then return 0, 0 end
  local c = W.size / 64
  local cx0, cx1 = max(-c, floor(min(ax, bx) / 32)), min(c - 1, floor(max(ax, bx) / 32))
  local cy0, cy1 = max(-c, floor(min(ay, by) / 32)), min(c - 1, floor(max(ay, by) / 32))
  local requested, ready = 0, 0
  for cx = cx0, cx1 do
    for cy = cy0, cy1 do
      local key = chunk_key(cx, cy)
      if q.gen[key] or surface.is_chunk_generated({cx, cy}) then
        ready = ready + 1
      elseif not q.inflight[key] and requested < worldgen.AREA_MAX then
        surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
        q.inflight[key] = game.tick
        q.n_inflight = q.n_inflight + 1
        requested = requested + 1
      end
    end
  end
  if requested > 0 then
    q.area[force_name] = (q.area[force_name] or 0) + requested
    q.area_total = (q.area_total or 0) + requested
    util.log("world: %s requested %d chunks of [%d,%d]-[%d,%d] (%d already generated)", force_name, requested,
      floor(math.min(ax, bx)), floor(math.min(ay, by)), floor(math.max(ax, bx)), floor(math.max(ay, by)), ready)
  end
  return requested, ready
end

---------------------------------------------------------------------------
-- Survey: the charted forces see every generated chunk
---------------------------------------------------------------------------
local function survey_forces()
  local fog = loaded("scripts.fog")
  if fog and fog.charted_forces then return fog.charted_forces() end
  return {util.PLAYER_FORCE}
end

function worldgen.chart_chunk(surface, cx, cy)
  local area = {{cx * 32 + 1, cy * 32 + 1}, {cx * 32 + 31, cy * 32 + 31}}
  for _, f in ipairs(survey_forces()) do
    local force = game.forces[f]
    if force then force.chart(surface, area) end
  end
end

--- Chart every generated chunk of the map for the charted forces; from now on each new chunk as it arrives.
function worldgen.survey_start(surface)
  local q, W = Q(), storage.world
  q.survey_started = true
  local n = 0
  local c = W.size / 64
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      if q.gen[chunk_key(cx, cy)] then
        worldgen.chart_chunk(surface, cx, cy)
        n = n + 1
      end
    end
  end
  util.log("world: survey: %d generated chunks charted for %s; the rest as it is generated", n,
    table.concat(survey_forces(), ", "))
end

-- QA count of charted chunks per force (module-local: not saved, may differ between peers, never read by game logic)
local charted_count = {}
events.on(defines.events.on_chunk_charted, function(e)
  local q = Q()
  if not (q and q.survey and e.surface_index and e.force) then return end
  local surface = surface_of()
  if not (surface and surface.index == e.surface_index) then return end
  charted_count[e.force.name] = (charted_count[e.force.name] or 0) + 1
end)

--- QA: chunks of the world charted for `force` since this peer loaded (survey only; 0 on a headless server).
function worldgen.charted(force)
  local name = type(force) == "string" and force or (force and force.name)
  return charted_count[name] or 0
end

---------------------------------------------------------------------------
-- HUD line: "World: 63 % generated" under the minimap while the fill runs
---------------------------------------------------------------------------
local function hud_line(player, text)
  local screen = player.gui.screen
  local f = screen[worldgen.HUD_NAME]
  if not text then
    if f then f.destroy() end
    return
  end
  if not f then
    f = screen.add({type = "frame", name = worldgen.HUD_NAME, direction = "horizontal", style = "rts_hud_frame"})
    f.ignored_by_interaction = true
    local l = f.add({type = "label", name = "line", style = "rts_hud_mono_label"})
    l.style.font_color = {0.85, 0.85, 0.7}
  end
  local s = player.display_scale
  f.style.width = worldgen.MINIMAP_FRAME_SIZE
  local mf = screen[worldgen.MINIMAP_FRAME]
  if mf and mf.valid and mf.location then
    f.location = {mf.location.x, mf.location.y + floor((worldgen.MINIMAP_FRAME_SIZE + 4) * s + 0.5)}
  else
    f.location = {floor(player.display_resolution.width - (worldgen.MINIMAP_FRAME_SIZE + 8) * s), 8}
  end
  f.line.caption = text
end

function worldgen.hud_text()
  local m, W = storage.match, storage.world
  if not (m and m.phase == "running" and m.config and m.config.mode == "nation" and W and W.fill) then return nil end
  if W.fill.done then return nil end
  local p = worldgen.progress()
  return {"rts-world3.hud-progress", floor(100 * p.share)}
end

events.on_nth_tick(worldgen.HUD_PERIOD, function()
  local text = worldgen.hud_text()
  for _, player in pairs(game.connected_players) do
    if text or player.gui.screen[worldgen.HUD_NAME] then hud_line(player, text) end
  end
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
--- Match teardown (match.lua's list): forget the requester; the HUD line goes at its next update.
function worldgen.reset()
  storage.worldgen = nil
  for _, player in pairs(game.players) do
    local f = player.gui.screen[worldgen.HUD_NAME]
    if f then f.destroy() end
  end
end

--- A save from before this module (Phase 5 M2) loaded while its world was still filling: index the plan from the old
--- feature list and request the rest. From match.init (on_configuration_changed) and, should that not run, from the
--- requester's first tick.
function worldgen.init()
  local W = storage.world
  if storage.worldgen or not (W and W.plan and W.fill and not W.fill.done and W.surface) then return end
  local surface = game.surfaces[W.surface]
  if not surface then return end
  local P = W.plan
  P.features = P.features or W.features
  worldgen.index(P)
  W.features = P.features
  storage.worldgen = {surface = surface.name, phase = "core", cursor = 1, order = {}, inflight = {}, n_inflight = 0,
                      gen = {}, area = {}, sweeps = 0}
  local q = storage.worldgen
  local c = W.size / 64
  W.fill.generated = 0
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      local key = chunk_key(cx, cy)
      if surface.is_chunk_generated({cx, cy}) then count_chunk(q, W, surface, key) end
    end
  end
  q.core_count = W.fill.generated
  for _, f in ipairs(P.features) do try_place(surface, W, f) end
  worldgen.request_rest()
  q.phase = "running"
  util.log("world: a filling world from an older save: %d/%d chunks generated, %d in the request order",
    W.fill.generated, W.fill.total, #q.order)
end

return worldgen
