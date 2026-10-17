-- Match flow (docs/PHASE3.md "Match flow"): config, the per-match arena surface, forces, spawn points, starting
-- bases, ore, starting armies, out / win / lose, per-force counters, and the legacy Phase 2 wave brain.
--
-- Lifecycle: a new game sits in the "lobby" phase (no arena; lobby.lua shows the start dialog). match.start(config)
-- builds the arena surface rts-arena-<n>, the forces rts-player + rts-ai-1..N (free-for-all), the map (scripts/mapgen.lua:
-- terrain on "chokes", main / natural / middle ore patches with finite totals, the neutral ruin), a CC with the same
-- starting stock for every force, 6 walkers each, and starts the clock. lobby.lua starts the AI commanders and moves the players' cameras. match.teardown() stops the brains,
-- removes the match's units and buildings and returns to the lobby; lobby.lua deletes the old surface after moving
-- the players off it (match.delete_arena). Nauvis is never touched: the players' god bodies sit on the lobby surface
-- (camera.lua) and the remote view looks at the arena.
--
-- A force is out when it has no CC, barracks or factory (buildings.is_alive_force) and no units. An AI that is out
-- is removed from the AI tick. The match ends for the human force (rts-player): victory when every AI is out,
-- defeat when rts-player is out, draw when both happen in the same check.
--
-- Owns storage.match:
--   version          3
--   phase            "lobby" | "setup" | "running" | "ended" (match.result derives the result from it)
--   match_id         number of matches started in this save (the arena of match n is rts-arena-<n>)
--   config           {opponents 1-3, difficulty, size, map = "chokes" | "open" (scripts/mapgen.lua layouts),
--                    enemy_brain = "ai" | "waves", enemy_difficulty (= difficulty, read by ai.init), first_wave_ticks,
--                    wave_period_ticks}; match.normalize_config
--   surface          name of the current arena surface (nil in the lobby); util.surface() returns it
--   arena_half       arena half size in tiles: the arena is [-arena_half, arena_half)^2 around (0, 0). Contract
--                    with the AI planner (lead, 2026-10-15): ai/layout.lua reads it (fallback 80); nil before the
--                    first match
--   forces           participating forces, rts-player first; ai_forces = the AI ones
--   spawns           {[force] = MapPosition} CC centres (match.home); facing = {[force] = +1 | -1}
--   out              {[force] = tick the force was out}; conceded = the force that gave up (menu), if any
--   stats            {[force] = {units_built, units_lost, buildings_built, buildings_lost}} (match.stats)
--   tick_started     tick the clock started; ended_tick, winner (force name, "ai" = several AIs left, or "draw")
--   placing          true while match.start places the starting entities (the counters ignore them)
--   start_plates     {[force] = {["iron-plate"] = n, ["copper-plate"] = n}} in the stockpiles at match start
--   Legacy wave brain (config.enemy_brain == "waves", 1 opponent with the Phase 2 template base):
--   wave, enemy_next_wave, enemy_group (LuaCommandable), enemy_group_id, waves_off
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local basetemplate = require("scripts.basetemplate")
local mapgen = require("scripts.mapgen")
local world = require("scripts.world") -- Phase 5 M1: Nation-mode worlds (config.mode == "nation")
local worldgen = require("scripts.worldgen") -- Phase 5 M3 world3: world generation (core, background fill, placement)
local balance = require("balance") -- Phase 5 M2 diplomacy: victory modes (balance.nation.diplomacy.victory)

local match = {}

local PLAYER, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
match.PLAYER, match.ENEMY = PLAYER, ENEMY
match.LOBBY_SURFACE = util.LOBBY_SURFACE
match.ARENA_PREFIX = "rts-arena-"
match.AI_PREFIX = "rts-ai-"
match.NEUTRAL = "rts-neutral" -- Phase 5 M2 diplomacy (D7): the city-states' force, Nation mode only
match.MAX_OPPONENTS = 3
match.MAX_NATIONS = world.MAX_NATIONS -- Phase 5 M3 world3: a Nation match has 2-6 nations (at most 4 on a 2048 world)
local ARENA_TILE = "grass-1"

-- Map sizes: the arena is [-half, half)^2; spawns sit on a circle of `radius` (size / 2 - 40). "legacy" is the
-- Phase 2 geometry (CCs at +-60 on a 160-tile arena): the waves brain and its autotest use it, without mapgen.
match.SIZES = {
  small = {half = 128, radius = 88},
  medium = {half = 192, radius = 152},
  large = {half = 256, radius = 216},
  legacy = {half = 80, radius = 60},
}
match.SIZE_ORDER = {"small", "medium", "large"} -- what the lobby offers
match.MAPS = mapgen.LAYOUTS -- "chokes" (default), "open"
match.DIFFICULTIES = {"easy", "normal", "hard"}
-- AI spawn angles in degrees (0 = east, y grows south); the player is at 180. Chosen so that no AI has two
-- equally near neighbours: the AI commander faces the nearest other spawn along x (ai/commander.lua), and an exact
-- tie would make its facing depend on table order.
match.AI_ANGLES = {[1] = {0}, [2] = {-70, 70}, [3] = {-60, 0, 60}}

-- Phase 1 QA follow-up 2 timing for the legacy wave brain; Phase 3 defaults for the match.
match.DEFAULT_CONFIG = {opponents = 1, difficulty = "normal", size = "small", map = mapgen.DEFAULT_LAYOUT, enemy_brain = "ai",
                        enemy_difficulty = "normal", first_wave_ticks = 3 * 60 * 60, wave_period_ticks = 2 * 60 * 60,
                        mode = "skirmish"}

-- Starting armies, ARMY_OFFSET tiles in front of the CC (along the force's facing): ARMY.walkers walkers in
-- ARMY_COLUMNS columns and ARMY.heavies heavies in a column in front of them. Grid spacing per unit: 3.5 tiles for
-- walkers, 5 for heavies (Phase 1 QA follow-up 6).
match.ARMY = {walkers = 6, heavies = 0}
match.ARMY_SIZE = match.ARMY.walkers + match.ARMY.heavies
match.SPACING = {["rts-walker"] = 3.5, ["rts-walker-heavy"] = 5}
local ARMY_COLUMNS = 2
local ARMY_OFFSET = 14
local HEAVY_FRONT = 6

-- Starting plates and stock, the same for every force (lead decisions of 2026-10-15; docs/qa/phase2-economy-notes.md).
-- Wave C balance (2026-10-16, docs/qa/phase4-balance-notes.md "Economy pass"): 400 iron and 150 copper, up from 200
-- and 100, so labs, a hub and science do not starve the barracks in the first minutes (iron is the binding plate:
-- 200 copper measured the same as 150).
match.START_PLATES = {{"iron-plate", 400}, {"copper-plate", 150}}
match.STARTING_STOCK = {
  match.START_PLATES[1], match.START_PLATES[2], {"rts-extractor", 2}, {"rts-smelter", 2}, {"rts-barracks", 1},
  {"rts-factory", 1}, {"rts-stockpile", 2}, {"transport-belt", 60}, {"fast-inserter", 16},
  {"medium-electric-pole", 16},
}
do
  local plates = {}
  for _, entry in ipairs(match.START_PLATES) do plates[entry[1]] = entry[2] end
  basetemplate.STOCK = plates -- the legacy template enemy gets the same plates
end
match.ENEMY_BARRACKS_RECIPE = "rts-walker-kit"

-- Ore patches per spawn, relative to the CC centre: {resource, dx, dy, width, height}. dx runs along the force's
-- front (match.front: towards the arena centre), dy along the side axis, which points south (east when the front is
-- due north or south). The player's front is +x, so its patches are the calibrated Phase 2 layout; an AI on the
-- x axis gets it mirrored in x, as before; off-axis AIs get it rotated towards the centre.
-- Amounts: on the legacy map ORE_AMOUNT per tile (Phase 2); on every other map mapgen.MAIN_TOTALS per patch
-- (PHASE4 2.4: finite totals), plus mapgen's natural pairs and middle patches (scripts/mapgen.lua).
match.ORE_AMOUNT = 1500
match.ORE_PATCHES = {
  {"iron-ore", 17, 10, 12, 12},
  {"copper-ore", 17, -10, 8, 8},
  {"stone", 28, 16, 6, 6},
  {"coal", 36, 16, 6, 6},
}
-- Contested patches near the centre: mapgen.MIDDLE (iron, copper, coal; not on the legacy map).
-- AI_VERTICAL_LINES: the AI planner can lay mining lines north/south of its CC. Before the AI fix of 2026-10-15
-- (commit 1051c60) it could not (layout.lua:412 crashed the game), and 1v2 / 1v3 matches got CONTESTED_SAFE_ORE
-- instead of the contested iron. false brings that stand-in back.
match.AI_VERTICAL_LINES = true
match.CONTESTED_SAFE_ORE = "stone"

match.FORCE_COLORS = {
  [PLAYER] = {r = 0.15, g = 0.45, b = 1.0, a = 1},
  ["rts-ai-1"] = {r = 0.95, g = 0.15, b = 0.1, a = 1},
  ["rts-ai-2"] = {r = 1.0, g = 0.75, b = 0.1, a = 1},
  ["rts-ai-3"] = {r = 0.25, g = 0.85, b = 0.3, a = 1},
  ["rts-ai-4"] = {r = 0.7, g = 0.3, b = 0.95, a = 1}, -- Phase 5 M3 world3: nations 5 and 6
  ["rts-ai-5"] = {r = 0.15, g = 0.85, b = 0.9, a = 1},
}
local WAVE_RADIUS = 16
local RETARGET_RANGE = 300

local function ai_force_name(i) return match.AI_PREFIX .. i end

--- Module lookup at call time (ai.init requires ai.commander, which requires this module).
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

---------------------------------------------------------------------------
-- Callbacks (registered at load time by lobby.lua, fog.lua)
---------------------------------------------------------------------------
local ended_callbacks, out_callbacks, teardown_callbacks = {}, {}, {}
--- fn(storage.match) once the match ended (phase "ended"). Load time only.
function match.on_ended(fn) ended_callbacks[#ended_callbacks + 1] = fn end
--- fn(force_name) when a force is out while the match goes on. Load time only.
function match.on_force_out(fn) out_callbacks[#out_callbacks + 1] = fn end
--- fn(old_surface_name) at the end of match.teardown (restart, back to the lobby, a new match): modules drop their
--- per-match state there (logistics: alerts, hauler stats, hub numbers; hud: kill feed). Load time only.
function match.on_teardown(fn) teardown_callbacks[#teardown_callbacks + 1] = fn end
-- Phase 5 M2 diplomacy: fn(storage.match) at the end of match.start, once the forces, bases and armies exist
-- (scripts/diplomacy.lua sets the Nation states, scripts/wars.lua its victory state). Load time only.
local started_callbacks = {}
function match.on_started(fn) started_callbacks[#started_callbacks + 1] = fn end
match.on_teardown(function() world.reset() end) -- Phase 5 M1: storage.world (scripts/world.lua)
match.on_teardown(function() worldgen.reset() end) -- Phase 5 M3 world3: storage.worldgen (scripts/worldgen.lua)

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
--- A validated copy of a config table (missing or bad fields take the defaults). The waves brain plays one
--- opponent on the legacy map.
function match.normalize_config(c)
  c = c or {}
  local d = match.DEFAULT_CONFIG
  local out = {}
  local n = math.floor(tonumber(c.opponents) or d.opponents)
  out.opponents = math.max(1, math.min(match.MAX_OPPONENTS, n))
  local diff_ok = {easy = true, normal = true, hard = true}
  out.difficulty = diff_ok[c.difficulty] and c.difficulty or d.difficulty
  out.size = match.SIZES[c.size] and c.size or d.size
  out.map = (c.map == "open" or c.map == "chokes") and c.map or d.map
  out.enemy_brain = c.enemy_brain == "waves" and "waves" or "ai"
  if out.enemy_brain == "waves" then
    out.opponents = 1
    if not c.size then out.size = "legacy" end
  end
  if out.size == "legacy" then out.map = "open" end -- the Phase 2 geometry has no terrain
  -- Phase 5 M1 (docs/PHASE5-M1.md §1): mode "skirmish" (the arenas above) or "nation" (an engine-generated world,
  -- scripts/world.lua, map "world", sized by nation count unless world_size names a valid size). Nation needs the AI.
  out.mode = (c.mode == "nation" and out.enemy_brain == "ai") and "nation" or "skirmish"
  if out.mode == "nation" then
    -- Phase 5 M3 world3 (D8): 2-6 nations (config.nations, else opponents + 1); 5-6 need a 3072 or 4096 world
    local nations = math.floor(tonumber(c.nations) or ((tonumber(c.opponents) or d.opponents) + 1))
    out.nations = math.max(2, math.min(match.MAX_NATIONS, nations))
    out.opponents = out.nations - 1
    out.world_size = world.normalize_size(c.world_size, out.nations)
    out.survey = c.survey and true or nil -- Phase 5 M3 world3: chart the generated world at the start (scripts/worldgen.lua)
    out.map = "world"
    if out.size == "legacy" then out.size = d.size end
    -- Phase 5 M2 diplomacy (D6): victory mode and time limit in minutes (0 = none); Score needs a limit
    local V = balance.nation.diplomacy.victory
    -- Phase 5 M3 age3: Conquest+Space and Any
    local mode_ok = {conquest = true, territory = true, score = true, conquest_space = true, any = true}
    out.victory = mode_ok[c.victory] and c.victory or V.default_mode
    local tl = math.floor(tonumber(c.time_limit) or V.default_time_limit)
    local tl_ok = false
    for _, v in ipairs(V.time_limits) do if v == tl then tl_ok = true end end
    out.time_limit = tl_ok and tl or V.default_time_limit
    if out.victory == "score" and out.time_limit == 0 then out.time_limit = V.score_default_limit end
  end
  out.enemy_difficulty = out.difficulty
  out.first_wave_ticks = tonumber(c.first_wave_ticks) or d.first_wave_ticks
  out.wave_period_ticks = tonumber(c.wave_period_ticks) or d.wave_period_ticks
  return out
end

local function config()
  local m = storage.match
  if not m.config then m.config = match.normalize_config(nil) end
  local c = m.config
  for k, v in pairs(match.DEFAULT_CONFIG) do
    if c[k] == nil then c[k] = v end
  end
  c.enemy_difficulty = c.difficulty
  return c
end
match.config = function() return config() end

--- Current wave timing {first_wave_ticks, wave_period_ticks} (storage.match.config).
function match.wave_config() return config() end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
--- The current arena surface, or nil (lobby).
function match.surface()
  local m = storage.match
  local s = m and m.surface and game.surfaces[m.surface]
  return s
end

--- Arena half size in tiles (the lobby reports the default map's).
function match.arena_half()
  local m = storage.match
  return (m and m.arena_half) or match.SIZES[match.DEFAULT_CONFIG.size].half
end

function match.phase()
  return storage.match and storage.match.phase or "lobby"
end

function match.in_lobby()
  local m = storage.match
  return not (m and m.surface)
end

--- Participating forces (rts-player first) and the AI ones.
function match.forces() return (storage.match and storage.match.forces) or {PLAYER} end
function match.ai_forces() return (storage.match and storage.match.ai_forces) or {} end

function match.is_participant(force_name)
  for _, f in ipairs(match.forces()) do
    if f == force_name then return true end
  end
  return false
end

-- Phase 5 M2 diplomacy: "enemy" is diplomacy.hostile (Skirmish: every other participant, as before; Nation: the
-- nations at war with the force). The module is looked up at call time (it loads after this one).
local function hostile_to(force_name, f)
  local d = loaded("scripts.diplomacy")
  local m = storage.match
  if d and m and m.phase == "running" then return d.hostile(force_name, f) end
  return f ~= force_name -- after the end every force ceases fire: the totals count every other participant, as before
end

--- Live units of every participant hostile to `force_name`.
function match.enemy_unit_count(force_name)
  if not storage.units then return 0 end
  local n = 0
  for _, f in ipairs(match.forces()) do
    if hostile_to(force_name, f) then n = n + units.count(f) end
  end
  return n
end

--- Enemy units `force_name` sees now: live units of the other match forces standing in a chunk next to one of the
--- force's own entities (Phase 5 M3 perf: was LuaForce.is_chunk_visible, chart state that differs between a headless
--- server and a GUI peer; fog.lua charts the same neighbourhood of own units and buildings). The HUD
--- shows this instead of the real total while the match runs, so the count does not leak through the fog.
function match.enemy_units_seen(force_name)
  local force = game.forces[force_name]
  local surface = match.surface()
  if not (force and surface and storage.units) then return 0 end
  local visible, n = {}, 0
  for _, f in ipairs(match.forces()) do
    if hostile_to(force_name, f) then -- Phase 5 M2 diplomacy
      for _, rec in units.for_force(f) do
        local p = rec.entity.position
        local cx, cy = math.floor(p.x / 32), math.floor(p.y / 32)
        local key = cx * 4096 + cy
        local v = visible[key]
        if v == nil then
          -- Phase 5 M3 perf (determinism): "in sight" = the force has an entity in this chunk or a neighbouring one,
          -- not the chunk's chart visibility (a headless server charts nothing, a GUI peer does: different HUDs)
          v = surface.count_entities_filtered({area = {{cx * 32 - 32, cy * 32 - 32}, {cx * 32 + 64, cy * 32 + 64}},
            force = force, limit = 1}) > 0
          visible[key] = v
        end
        if v then n = n + 1 end
      end
    end
  end
  return n
end

--- Home position (CC centre) of a force, or {0, 0}.
function match.home(force_name)
  local spawns = storage.match and storage.match.spawns
  return (spawns and spawns[force_name]) or {x = 0, y = 0}
end

--- +1 when the force's front (ore, army) is towards +x, else -1.
function match.facing(force_name)
  local f = storage.match and storage.match.facing
  return (f and f[force_name]) or (force_name == PLAYER and 1 or -1)
end
-- Read-only views for older callers (debug.lua used match.FACING[force] and match.CC_POSITIONS[force]).
match.FACING = setmetatable({}, {__index = function(_, k) return match.facing(k) end})
match.CC_POSITIONS = setmetatable({}, {__index = function(_, k) return match.home(k) end})

--- The force's front and side axes as unit vectors: front = from its CC towards the arena centre (0, 0); side =
--- perpendicular, pointing south (east when the front is due north or south). A force without a spawn gets its
--- facing along x. Ore patches (dx, dy) and the starting army are laid out in these axes.
function match.front(force_name)
  local home = match.home(force_name)
  local len = math.sqrt(home.x * home.x + home.y * home.y)
  if len < 1 then return {x = match.facing(force_name), y = 0}, {x = 0, y = 1} end
  local f = {x = -home.x / len, y = -home.y / len}
  local sx, sy = -f.y, f.x
  if sy < -1e-9 or (math.abs(sy) <= 1e-9 and sx < 0) then sx, sy = -sx, -sy end
  return f, {x = sx, y = sy}
end

-- Per-spawn layout of the ore patches and the starting army (the player's is the same in both):
--   "rotated"  (default) front = towards the arena centre (match.front). For the off-axis AIs of 1v2 and 1v3 it puts
--              iron and copper on one side of the CC; the AI's hub slots handle that since commit 33d5b40 (slots on
--              all four sides). Before it, their copper line found no hub slot.
--   "facing"   (option) front = along x towards the force's facing (the AI commander's rule), side = +y: iron south
--              and copper north of every CC, the layout the AI hub was first calibrated on.
match.ORE_LAYOUT = "rotated"

--- The axes ore and army are laid out in (match.ORE_LAYOUT): front, side unit vectors.
function match.layout_axes(force_name)
  if match.ORE_LAYOUT == "facing" then return {x = match.facing(force_name), y = 0}, {x = 0, y = 1} end
  return match.front(force_name)
end

--- Where a force's army gathers: ARMY_OFFSET tiles in front of its CC (match.layout_axes).
function match.army_point(force_name)
  local home = match.home(force_name)
  local f = match.layout_axes(force_name)
  return {x = home.x + f.x * ARMY_OFFSET, y = home.y + f.y * ARMY_OFFSET}
end

--- Grid spacing for a unit prototype name (match.SPACING; 3.5 for anything not listed).
function match.spacing(name)
  return match.SPACING[name] or match.SPACING["rts-walker"]
end

--- Per-match counters of a force (zeros for a force that is not in the match).
function match.stats(force_name)
  local m = storage.match
  local s = m and m.stats and m.stats[force_name]
  return s or {units_built = 0, units_lost = 0, buildings_built = 0, buildings_lost = 0}
end

--- Localised display name of a force: "You" or "AI 2".
-- "rts-ai-" has Lua pattern specials ("-"), so the prefix is escaped (before this fix AI forces got their raw name).
local AI_PATTERN = "^" .. (string.gsub(match.AI_PREFIX, "%p", "%%%0")) .. "(%d+)$"
function match.label(force_name)
  if force_name == PLAYER then return {"rts.force-player"} end
  local n = force_name and tonumber(string.match(force_name, AI_PATTERN))
  if n then return {"rts.force-ai", n} end
  return force_name or "?"
end

--- Seconds of match time so far (or until the end).
function match.elapsed_seconds()
  local m = storage.match
  if not (m and m.tick_started) then return 0 end
  local now = (m.phase == "ended" and m.ended_tick) or game.tick
  return math.max(0, (now - m.tick_started) / 60)
end

---------------------------------------------------------------------------
-- Surfaces
---------------------------------------------------------------------------
-- No autoplace at all, lab tiles (cheap; every arena tile is replaced anyway), no cliffs, no enemies.
local function empty_mgs(half, seed)
  return {
    seed = seed, width = half and 2 * half or 0, height = half and 2 * half or 0,
    default_enable_all_autoplace_controls = false,
    autoplace_controls = {},
    autoplace_settings = {
      entity = {treat_missing_as_default = false, settings = {}},
      decorative = {treat_missing_as_default = false, settings = {}},
    },
    cliff_settings = {name = "cliff", cliff_elevation_0 = 1024, cliff_elevation_interval = 10, richness = 0},
    no_enemies_mode = true,
    peaceful_mode = true,
  }
end

--- The lobby surface (created once): a 64x64 map paved with out-of-map tiles, so the camera shows black there.
--- The players' god bodies stay on it for the whole session (camera.lua).
function match.lobby_surface()
  local s = game.surfaces[match.LOBBY_SURFACE]
  if s then return s end
  s = game.create_surface(match.LOBBY_SURFACE, empty_mgs(32, 1))
  s.generate_with_lab_tiles = true
  s.always_day = true
  s.request_to_generate_chunks({0, 0}, 1)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -32, 31 do
    for y = -32, 31 do tiles[#tiles + 1] = {name = "out-of-map", position = {x, y}} end
  end
  s.set_tiles(tiles, false, false, false, false)
  util.log("match: lobby surface %s created (index %d), tile at (0, 0): %s", s.name, s.index, s.get_tile(0, 0).name)
  return s
end

--- The surface the camera shows: the arena while a match exists, else the lobby.
function match.view_surface()
  return match.surface() or match.lobby_surface()
end

--- The arena seed of the current match (nauvis seed + match number).
local function arena_seed(m)
  return ((game.surfaces.nauvis and game.surfaces.nauvis.map_gen_settings.seed or 1) + m.match_id) % 4294967296
end

-- `tile_at(x, y)` (mapgen.tile_function) names the ground tile; nil = ARENA_TILE everywhere (open, legacy).
local function create_arena(m, tile_at)
  local half = m.arena_half
  local name = match.ARENA_PREFIX .. m.match_id
  local old = game.surfaces[name]
  if old then game.delete_surface(old) end -- a leftover from an older save; never the live arena
  local seed = arena_seed(m)
  local surface = game.create_surface(old and (name .. "b") or name, empty_mgs(half, seed))
  surface.generate_with_lab_tiles = true
  surface.always_day = true
  local prof = helpers.create_profiler()
  surface.request_to_generate_chunks({0, 0}, math.ceil(half / 32))
  surface.force_generate_chunk_requests()
  local area = {{-half, -half}, {half, half}}
  local removed = 0
  for _, e in pairs(surface.find_entities_filtered({area = area})) do
    if e.valid and e.type ~= "character" then
      e.destroy()
      removed = removed + 1
    end
  end
  -- Grass over everything (no water, no lab tiles; mapgen's ground variation on "chokes"), then no decoratives.
  local tiles = {}
  for x = -half, half - 1 do
    for y = -half, half - 1 do
      tiles[#tiles + 1] = {name = tile_at and tile_at(x, y) or ARENA_TILE, position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, true, true, false)
  surface.destroy_decoratives({area = area})
  prof.stop()
  local water = surface.count_tiles_filtered({area = area, collision_mask = "water_tile"})
  log({"", string.format("[rts] match: arena %s (index %d) [%d,%d)^2 ready: %d tiles set to %s, %d entities "
    .. "removed, water tiles=%d, edge tiles: (%d, 0)=%s (%d, 0)=%s, built in ", surface.name, surface.index, -half,
    half, #tiles, ARENA_TILE, removed, water, half - 1, surface.get_tile(half - 1, 0).name, half,
    surface.get_tile(half, 0).name), prof})
  return surface
end

-- Phase 5 M1: the Nation world's surface, created with the world's MapGenSettings; world.apply generates it.
local function create_world(m, P)
  local name = match.ARENA_PREFIX .. m.match_id
  local old = game.surfaces[name]
  if old then game.delete_surface(old) end -- a leftover from an older save; never the live arena
  return game.create_surface(old and (name .. "b") or name, world.map_gen_settings(P))
end

--- Delete an old arena surface (deferred by the engine to a later tick). Move every player off it first.
function match.delete_arena(name)
  local s = name and game.surfaces[name]
  if not s then return false end
  local ok = game.delete_surface(s)
  util.log("match: arena %s queued for deletion: %s", name, tostring(ok))
  return ok
end

---------------------------------------------------------------------------
-- Forces
---------------------------------------------------------------------------
local function ensure_force(name)
  local f = game.forces[name] or game.create_force(name)
  f.custom_color = match.FORCE_COLORS[name] or {r = 0.6, g = 0.6, b = 0.6, a = 1}
  f.ai_controllable = false -- script groups work without it (spike decision 4)
  f.share_chart = false
  return f
end

--- Free-for-all: every RTS force is the enemy of every other; vanilla forces stay out of the fight.
local function setup_forces(names)
  local list = {}
  for _, name in ipairs(names) do list[#list + 1] = ensure_force(name) end
  for _, f in ipairs(list) do
    for _, other in ipairs(list) do
      if f ~= other then
        f.set_friend(other, false)
        f.set_cease_fire(other, false)
      end
    end
    for _, vanilla in pairs({"enemy", "player", "neutral"}) do
      f.set_cease_fire(vanilla, true)
      game.forces[vanilla].set_cease_fire(f, true)
    end
  end
  -- Phase 5 M2 diplomacy (D7): the city-states' force, created once (forces are never deleted) and at war with every
  -- nation; it has no commander and fights only with its turrets. Nation mode only: Skirmish creates no force.
  if config().mode == "nation" then
    local n = game.forces[match.NEUTRAL] or game.create_force(match.NEUTRAL)
    n.custom_color = {r = 0.75, g = 0.75, b = 0.75, a = 1}
    n.ai_controllable = false
    n.share_chart = false
    for _, f in ipairs(list) do
      f.set_friend(n, false)
      n.set_friend(f, false)
      f.set_cease_fire(n, false)
      n.set_cease_fire(f, false)
    end
    for _, vanilla in pairs({"enemy", "player", "neutral"}) do
      n.set_cease_fire(vanilla, true)
      game.forces[vanilla].set_cease_fire(n, true)
    end
  end
end

--- Put a player on the RTS player force (humans always play rts-player).
function match.assign_player(player)
  ensure_force(PLAYER)
  if player.force.name ~= PLAYER then player.force = PLAYER end
end

---------------------------------------------------------------------------
-- Spawns, ore, bases, armies
---------------------------------------------------------------------------
-- Spawn points on the circle: the player at 180 degrees, the AIs at match.AI_ANGLES.
local function spawn_points(n, radius)
  local spawns = {[PLAYER] = {x = -radius, y = 0}}
  for i, deg in ipairs(match.AI_ANGLES[n]) do
    local a = math.rad(deg)
    spawns[ai_force_name(i)] = {x = math.floor(radius * math.cos(a) + 0.5), y = math.floor(radius * math.sin(a) + 0.5)}
  end
  return spawns
end

-- The AI commander's facing rule (ai/commander.lua): towards the nearest other spawn along x. Forces are visited
-- in sorted order, so a tie picks the same spawn every time.
local function facing_of(force_name, spawns)
  local home = spawns[force_name]
  local names = {}
  for name in pairs(spawns) do names[#names + 1] = name end
  table.sort(names)
  local best, fx
  for _, name in ipairs(names) do
    if name ~= force_name then
      local d = util.distance(home, spawns[name])
      if not best or d < best then best, fx = d, (spawns[name].x >= home.x) and 1 or -1 end
    end
  end
  return fx or (home.x <= 0 and 1 or -1)
end

local function place_ore_patches(surface, force_name)
  local home = match.home(force_name)
  local f, side = match.layout_axes(force_name)
  local parts = {}
  for _, p in ipairs(match.ORE_PATCHES) do
    local center = {x = math.floor(home.x + f.x * p[2] + side.x * p[3] + 0.5),
                    y = math.floor(home.y + f.y * p[2] + side.y * p[3] + 0.5)}
    local n = basetemplate.place_ore(surface, p[1], center, p[4], p[5], match.ORE_AMOUNT, true)
    parts[#parts + 1] = string.format("%s %dx%d at %s: %d tiles", p[1], p[4], p[5], util.pos_str(center), n)
  end
  util.log("match: ore for %s: %s", force_name, table.concat(parts, "; "))
end

-- The main patches of a force (match.ORE_PATCHES in its layout axes) as {force, name, center, w, h}.
local function main_patches(force_name)
  local home = match.home(force_name)
  local f, side = match.layout_axes(force_name)
  local out = {}
  for _, p in ipairs(match.ORE_PATCHES) do
    out[#out + 1] = {force = force_name, name = p[1], w = p[4], h = p[5],
                     center = {x = math.floor(home.x + f.x * p[2] + side.x * p[3] + 0.5),
                               y = math.floor(home.y + f.y * p[2] + side.y * p[3] + 0.5)}}
  end
  return out
end

--- The mapgen spec of the match being started (storage.match spawns, forces, config).
local function mapgen_spec(m, c)
  local size = match.SIZES[c.size]
  local main = {}
  for _, f in ipairs(m.forces) do
    for _, p in ipairs(main_patches(f)) do main[#main + 1] = p end
  end
  local safe = not match.AI_VERTICAL_LINES and c.opponents >= 2 and c.enemy_brain == "ai"
  return {size = c.size, layout = c.map, half = size.half, radius = size.radius, seed = arena_seed(m),
          forces = m.forces, spawns = m.spawns, main = main, middle_iron_ore = safe and match.CONTESTED_SAFE_ORE or nil}
end

local function stock_stockpiles(stockpiles, items)
  local parts = {}
  for _, entry in ipairs(items) do
    local name, left = entry[1], entry[2]
    for _, chest in ipairs(stockpiles) do
      if left <= 0 then break end
      left = left - chest.insert({name = name, count = left})
    end
    parts[#parts + 1] = string.format("%s=%d", name, entry[2] - left)
  end
  return table.concat(parts, " ")
end

--- Set the walker-kit recipe on every barracks of a force that has none. Returns the number set.
function match.arm_barracks(force_name, recipe)
  local n = 0
  for _, rec in buildings.for_force(force_name, "barracks") do
    if not rec.entity.get_recipe() and production.set_recipe(rec.entity, recipe or match.ENEMY_BARRACKS_RECIPE) then
      n = n + 1
    end
  end
  return n
end

-- Plates in a force's stockpiles right now: {[item] = count} for match.START_PLATES items.
local function stockpile_plates(force_name)
  local out = {}
  for _, entry in ipairs(match.START_PLATES) do out[entry[1]] = 0 end
  for _, rec in buildings.for_force(force_name, "stockpile") do
    local inv = rec.entity.get_inventory(defines.inventory.chest)
    for name in pairs(out) do out[name] = out[name] + inv.get_item_count(name) end
  end
  return out
end

local function place_bases(surface)
  local m = storage.match
  local c = config()
  for _, force_name in ipairs(m.forces) do
    if force_name == ENEMY and c.enemy_brain == "waves" then
      -- Legacy: the full starter template, facing the arena centre, barracks on walker kits.
      basetemplate.ensure()
      basetemplate.clone_to(surface, ENEMY, match.home(ENEMY), match.facing(ENEMY))
      match.arm_barracks(ENEMY, match.ENEMY_BARRACKS_RECIPE)
    else
      local cc, parts = buildings.place_cc(surface, match.home(force_name), force_name)
      if cc then
        util.log("match: %s CC at %s facing %+d, starting stock: %s", force_name, util.pos_str(cc.position),
          match.facing(force_name), stock_stockpiles(parts.stockpiles, match.STARTING_STOCK))
      else
        util.log("match: %s CC could not be placed at %s", force_name, util.pos_str(match.home(force_name)))
      end
    end
  end
  -- Other sizes: mapgen.build placed the main, natural and middle patches before the CCs.
  if c.size == "legacy" then
    for _, force_name in ipairs(m.forces) do place_ore_patches(surface, force_name) end
  end
  m.start_plates = {}
  for _, force_name in ipairs(m.forces) do
    local plates = stockpile_plates(force_name)
    m.start_plates[force_name] = plates
    util.log("match: %s starting plates: iron=%d copper=%d", force_name, plates["iron-plate"], plates["copper-plate"])
  end
end

--- Spawn one force's starting army at match.army_point: walkers in ARMY_COLUMNS columns (the first column faces
--- the front, the others extend towards the own CC), heavies in a column HEAVY_FRONT tiles in front of them. Columns
--- run along the side axis (match.front).
local function spawn_army(force_name, surface)
  local s = match.army_point(force_name)
  local f, side = match.layout_axes(force_name)
  local made = 0
  local ws, hs = match.spacing("rts-walker"), match.spacing("rts-walker-heavy")
  local walkers, heavies = match.ARMY.walkers, match.ARMY.heavies
  local rows = math.ceil(walkers / ARMY_COLUMNS)
  local function at(along, across) return {x = s.x + f.x * along + side.x * across,
                                           y = s.y + f.y * along + side.y * across} end
  for i = 0, walkers - 1 do
    local col, row = i % ARMY_COLUMNS, math.floor(i / ARMY_COLUMNS)
    if units.spawn("rts-walker", at(-col * ws, (row - (rows - 1) / 2) * ws), force_name, "walker", surface) then
      made = made + 1
    end
  end
  for i = 0, heavies - 1 do
    if units.spawn("rts-walker-heavy", at(HEAVY_FRONT, (i - (heavies - 1) / 2) * hs), force_name, "heavy",
      surface) then
      made = made + 1
    end
  end
  return made
end

--- Spawn the starting army of every participant that has no units, and (re)start the clock.
function match.spawn_armies()
  local m = storage.match
  local surface = util.surface()
  for _, force_name in ipairs(m.forces or {PLAYER}) do
    if units.count(force_name) == 0 then
      local n = spawn_army(force_name, surface)
      util.log("match: spawned %d units for %s at %s", n, force_name, util.pos_str(match.army_point(force_name)))
    end
  end
  m.phase = "running"
  m.winner = nil
  m.winners, m.victory = nil, nil -- Phase 5 M2 diplomacy: shared victories (match.finish_by)
  m.ended_tick = nil
  m.tick_started = game.tick
  m.out = {}
  m.enemy_next_wave = config().enemy_brain == "waves" and (game.tick + config().first_wave_ticks) or nil
end

local function fresh_stats(names)
  local stats = {}
  for _, f in ipairs(names) do
    stats[f] = {units_built = 0, units_lost = 0, buildings_built = 0, buildings_lost = 0}
  end
  return stats
end

--- Build a new match from `cfg` (match.normalize_config): arena surface, forces, CCs and stock, ore, armies, clock.
--- The previous match must be torn down first (match.teardown). AI commanders, fog and cameras are lobby.lua's job.
--- Returns the arena surface.
function match.start(cfg)
  local m = storage.match
  assert(not m.surface, "match.start: tear the old match down first")
  local c = match.normalize_config(cfg)
  m.config = c
  local size = match.SIZES[c.size]
  m.match_id = (m.match_id or 0) + 1
  m.phase = "setup"
  m.arena_half = size.half -- the AI planner's bounds too (see the header)
  m.forces = {PLAYER}
  m.ai_forces = {}
  for i = 1, c.opponents do
    m.forces[#m.forces + 1] = ai_force_name(i)
    m.ai_forces[#m.ai_forces + 1] = ai_force_name(i)
  end
  -- Phase 5 M3 world3: a Nation world has up to 5 opponents; Skirmish spawn angles exist for 1-3 only
  m.spawns = c.mode ~= "nation" and spawn_points(c.opponents, size.radius) or {}
  -- Phase 5 M1: a Nation world plans its own spawns, scored for fairness (scripts/world.lua); Phase 5 M3 world3: the
  -- plan assigns every feature and label to chunks (scripts/worldgen.lua)
  local wplan = c.mode == "nation" and worldgen.plan(arena_seed(m), c.world_size, c.nations or (c.opponents + 1)) or nil
  if wplan then
    m.arena_half = wplan.half
    m.spawns = {}
    for _, sp in ipairs(wplan.spawns) do m.spawns[sp.force] = {x = sp.x, y = sp.y} end
  end
  m.facing = {}
  for _, f in ipairs(m.forces) do m.facing[f] = facing_of(f, m.spawns) end
  m.out, m.winner, m.ended_tick, m.tick_started = {}, nil, nil, nil
  m.wave, m.waves_off, m.enemy_next_wave = 0, nil, nil
  m.stats = fresh_stats(m.forces)
  if c.mode == "nation" then -- Phase 5 M1 integration: a Nation match logs its world, not the Skirmish size and map
    util.log("match: starting match %d: %d opponent(s), %s, nation, world %dx%d, brain %s", m.match_id, c.opponents,
      c.difficulty, 2 * m.arena_half, 2 * m.arena_half, c.enemy_brain)
  else
    util.log("match: starting match %d: %d opponent(s), %s, %s (%dx%d), map %s, brain %s", m.match_id, c.opponents,
      c.difficulty, c.size, 2 * m.arena_half, 2 * m.arena_half, c.map, c.enemy_brain)
  end

  -- Map generation (scripts/mapgen.lua): planned before the arena exists (ground tiles), built before the CCs.
  local plan = c.size ~= "legacy" and not wplan and mapgen.plan(mapgen_spec(m, c)) or nil
  local surface = wplan and create_world(m, wplan) or create_arena(m, plan and mapgen.tile_function(plan))
  m.surface = surface.name
  setup_forces(m.forces)
  if wplan then
    worldgen.start(surface, wplan) -- Phase 5 M3 world3: the forced core; the rest fills in the background
  elseif plan then mapgen.build(surface, plan) else mapgen.reset() end
  m.placing = true
  place_bases(surface)
  m.placing = nil
  match.spawn_armies()
  local parts = {}
  for _, f in ipairs(m.forces) do
    parts[#parts + 1] = string.format("%s CC %s facing %+d", f, util.pos_str(m.spawns[f]), m.facing[f])
  end
  util.log("match: match %d running on %s at tick %d: %s", m.match_id, surface.name, game.tick,
    table.concat(parts, "; "))
  for _, fn in ipairs(started_callbacks) do fn(m) end -- Phase 5 M2 diplomacy
  return surface
end

local function drop_group()
  local m = storage.match
  local g = m.enemy_group
  m.enemy_group, m.enemy_group_id = nil, nil
  if g and g.valid then g.destroy() end
end

--- End the current match and return to the lobby: stop the brains, destroy the match's units and registered
--- buildings (so nothing of the old match is found by registry queries in this tick), forget the arena. The
--- surface itself is deleted by match.delete_arena once the players are moved off it. Returns the old surface name.
function match.teardown(reason)
  local m = storage.match
  local old = m.surface
  local ai = loaded("scripts.ai.init")
  local stopped = 0
  for name in pairs(storage.ai or {}) do
    if ai and ai.stop_force(name) then stopped = stopped + 1 end
  end
  drop_group()
  mapgen.reset()
  local removed_units = units.despawn_all()
  local removed_buildings = 0
  for un, rec in pairs(storage.buildings or {}) do
    if rec.entity and rec.entity.valid and (not old or rec.entity.surface.name == old) then
      for _, part in pairs(rec.parts or {}) do
        if part.valid then part.destroy() end
      end
      rec.entity.destroy()
      removed_buildings = removed_buildings + 1
    end
  end
  m.phase = "lobby"
  m.surface = nil
  m.tick_started, m.ended_tick, m.winner = nil, nil, nil
  m.winners, m.victory = nil, nil -- Phase 5 M2 diplomacy
  m.wave, m.enemy_next_wave, m.waves_off = 0, nil, nil
  m.out, m.conceded = {}, nil
  production.reset_match()
  for _, fn in ipairs(teardown_callbacks) do fn(old) end
  util.log("match: match %s torn down (%s): %d AI commanders stopped, %d units and %d buildings removed, arena %s",
    tostring(m.match_id), reason or "-", stopped, removed_units, removed_buildings, tostring(old))
  return old
end

--- Switch the legacy enemy waves on or off (/rts-qa-reset nowaves).
function match.set_waves(on)
  local m = storage.match
  if config().enemy_brain ~= "waves" then
    m.waves_off = nil -- the AI brain sends no waves; nothing to switch
    return
  end
  if on then
    m.waves_off = nil
    if config().enemy_brain == "waves" and m.phase == "running" and not m.enemy_next_wave then
      m.enemy_next_wave = game.tick + config().first_wave_ticks
    end
  else
    m.waves_off = true
    m.enemy_next_wave = nil
    drop_group()
  end
end

--- Change the enemy wave timing (seconds). A first wave that has not come yet is rescheduled to
--- tick_started + first (at the earliest one second from now). Legacy waves brain, debug and autotest only.
function match.set_wave_timing(first_seconds, period_seconds)
  local m = storage.match
  local c = config()
  c.first_wave_ticks = math.max(60, math.floor(first_seconds * 60))
  c.wave_period_ticks = math.max(60, math.floor(period_seconds * 60))
  if m.phase == "running" and (m.wave or 0) == 0 and m.enemy_next_wave and not m.waves_off then
    m.enemy_next_wave = math.max(game.tick + 60, (m.tick_started or game.tick) + c.first_wave_ticks)
  end
  util.log("match: wave timing first=%.0fs period=%.0fs, next wave %s", c.first_wave_ticks / 60,
    c.wave_period_ticks / 60, m.enemy_next_wave and string.format("in %.0fs", (m.enemy_next_wave - game.tick) / 60)
    or "not scheduled")
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
function match.init()
  mapgen.init()
  world.init()
  worldgen.init() -- Phase 5 M3 world3: a world still filling in an older save
  local m = storage.match
  if m and m.version == 3 then
    config()
    if m.half and not m.arena_half then m.arena_half, m.half = m.half, nil end -- the first Phase 3 field name
    match.lobby_surface()
    return
  end
  local legacy = m ~= nil
  storage.match = {version = 3, phase = "lobby", match_id = 0, wave = 0, forces = {PLAYER}, ai_forces = {},
                   spawns = {}, facing = {}, out = {}, stats = {}}
  config()
  if legacy then
    -- A Phase 1/2 save: its match lived on nauvis. Its units, buildings and commanders go (they would keep forces
    -- "alive" in the registries); the rest of nauvis is left as it is, and the save restarts in the lobby.
    match.teardown("pre-Phase-3 save, phase " .. tostring(m.phase) .. " on nauvis")
  end
  match.lobby_surface()
  ensure_force(PLAYER)
  for _, player in pairs(game.players) do match.assign_player(player) end
end

---------------------------------------------------------------------------
-- Per-force counters
---------------------------------------------------------------------------
local function counting(force_name)
  local m = storage.match
  if not (m and m.phase == "running" and not m.placing and m.stats) then return nil end
  return m.stats[force_name]
end

production.on_spawned(function(unit, rec)
  local s = counting(rec.force)
  if s then s.units_built = s.units_built + 1 end
end)

-- A unit leaves the registry while still valid only when it died (despawns and stale records are invalid).
units.on_removed(function(_, rec)
  if not (rec.entity and rec.entity.valid) then return end
  local s = counting(rec.force)
  if s then s.units_lost = s.units_lost + 1 end
end)

buildings.on_added(function(_, rec)
  local s = counting(rec.force)
  if s then s.buildings_built = s.buildings_built + 1 end
end)

events.on(defines.events.on_entity_died, function(e)
  local entity = e.entity
  if not (entity and entity.valid and buildings.KIND_BY_NAME[entity.name]) then return end
  local s = counting(entity.force.name)
  if s then s.buildings_lost = s.buildings_lost + 1 end
end)

---------------------------------------------------------------------------
-- Legacy enemy brain (config.enemy_brain == "waves"): every wave_period_ticks send every rts-ai-1 unit, as one
-- unit group, to attack the player army (or its CC when the army is gone).
---------------------------------------------------------------------------
local function wave_target()
  local target = units.centroid(PLAYER)
  if target then return target end
  local cc = buildings.main_cc(PLAYER)
  return cc and cc.entity.position or nil
end

--- Where a wave near `position` should go next: the nearest player entity within RETARGET_RANGE, else the
--- player army centroid, else the player CC. nil when the player has nothing left.
local function player_target(position)
  if position then
    local nearest = util.surface().find_nearest_enemy({position = position, max_distance = RETARGET_RANGE,
                                                       force = ENEMY})
    if nearest then return nearest.position end
  end
  return wave_target()
end
match.wave_retarget = player_target

local function launch_wave()
  local m = storage.match
  local target = wave_target()
  local origin = units.centroid(ENEMY)
  if not (target and origin) then return end
  drop_group()
  local group = util.surface().create_unit_group({position = origin, force = ENEMY})
  local n = 0
  for _, rec in units.for_force(ENEMY) do
    group.add_member(rec.entity)
    rec.order = "attack_move"
    rec.dest = target
    n = n + 1
  end
  group.set_command({type = defines.command.attack_area, destination = target, radius = WAVE_RADIUS,
                     distraction = defines.distraction.by_anything})
  m.enemy_group, m.enemy_group_id = group, group.unique_id
  m.wave = m.wave + 1
  util.log("match: enemy wave %d: group #%d with %d units from %s -> attack_area %s", m.wave, group.unique_id,
    n, util.pos_str(origin), util.pos_str(target))
end

-- Wave members whose group is gone go back to idle (stop), so they do not wander.
local function release_orphans()
  for _, rec in units.for_force(ENEMY) do
    if rec.order == "attack_move" and rec.issuer == nil then
      local c = rec.entity.commandable
      if not (c and c.parent_group) then
        rec.order = units.IDLE
        rec.dest = nil
        units.stop(rec.entity)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Out, win, lose
---------------------------------------------------------------------------
--- A force is out when it has no CC, barracks or factory left (buildings.is_alive_force) and no units.
--- Phase 4: haulers and the Commander (it respawns at the CC) do not keep a side in the match.
local NOT_ARMY = {hauler = true, commander = true}
function match.is_out(force_name)
  if buildings.is_alive_force(force_name) then return false end
  for _, rec in units.for_force(force_name) do
    if not NOT_ARMY[rec.kind] then return false end
  end
  return true
end

--- Pure winner rule from the human force's view: rts-player wins when every enemy is out and it is not; both out
--- is a draw; rts-player out alone returns ENEMY (rts-ai-1, the 1v1 enemy); nobody out is no result (nil).
function match.decide_winner(player_out, enemies_out)
  if player_out and enemies_out then return "draw" end
  if enemies_out then return PLAYER end
  if player_out then return ENEMY end
  return nil
end

--- Locale key of the one-line outcome for a force: rts.match-victory / -defeat / -draw, or rts.match-conceded for a
--- force that gave up (match.concede).
function match.result_text_key(force_name)
  local r = match.result(force_name)
  if not r then return nil end
  local m = storage.match
  if r == "defeat" and m.conceded == force_name then return "rts.match-conceded" end
  if m.victory and m.victory.how then return "rts.match-" .. r .. "-" .. m.victory.how end -- Phase 5 M2 diplomacy
  return "rts.match-" .. r
end

--- The match result from a force's point of view, derived from storage.match.phase only:
--- nil while the match is not "ended", else "victory" | "defeat" | "draw".
function match.result(force_name)
  local m = storage.match
  if not (m and m.phase == "ended") then return nil end
  if m.winner == "draw" or m.winner == nil then return "draw" end
  if m.winners and m.winners[force_name] then return "victory" end -- Phase 5 M2 diplomacy: allies share a victory
  return m.winner == force_name and "victory" or "defeat"
end

-- A calm results screen (Phase 4 QA): fighting went on behind the results window. At the end every match force
-- ceases fire on the others (match.start's setup_forces turns it back on), every AI commander stops and every unit
-- that orders.lua may command stands still. Haulers and the Commander keep their own claims but fire on no one.
local function calm_down(m)
  local list = {}
  for _, f in ipairs(m.forces) do
    if game.forces[f] then list[#list + 1] = game.forces[f] end
  end
  for _, a in ipairs(list) do
    for _, b in ipairs(list) do
      if a ~= b then a.set_cease_fire(b, true) end
    end
  end
  local ai = loaded("scripts.ai.init")
  local stopped = 0
  for _, f in ipairs(m.ai_forces) do
    if ai and ai.get(f) and ai.stop_force(f) then stopped = stopped + 1 end
  end
  local orders = loaded("scripts.orders")
  local entities = {}
  for _, rec in pairs(storage.units or {}) do
    if rec.entity.valid then entities[#entities + 1] = rec.entity end
  end
  local n = orders and orders.stop(entities) or 0
  util.log("match: calm after the end: %d forces cease fire on each other, %d AI commanders stopped, %d units stopped",
    #list, stopped, n)
end

local function finish(winner)
  local m = storage.match
  m.phase = "ended"
  m.ended_tick = game.tick
  m.winner = winner
  drop_group()
  release_orphans()
  calm_down(m)
  local parts = {}
  for _, f in ipairs(m.forces) do
    local s = m.stats[f] or {}
    parts[#parts + 1] = string.format("%s units=%d built=%s lost=%s buildings=%d built=%s lost=%s out=%s", f,
      units.count(f), tostring(s.units_built), tostring(s.units_lost), buildings.count(f), tostring(s.buildings_built),
      tostring(s.buildings_lost), m.out[f] and string.format("%.0fs", (m.out[f] - m.tick_started) / 60) or "no")
  end
  util.log("match: ended at tick %d after %.0fs, winner=%s, result for %s=%s | %s", game.tick,
    match.elapsed_seconds(), tostring(winner), PLAYER, tostring(match.result(PLAYER)), table.concat(parts, " | "))
  for _, player in pairs(game.players) do
    player.print({"", "[RTS] ", {match.result_text_key(player.force.name) or "rts.match-draw"}})
  end
  for _, fn in ipairs(ended_callbacks) do fn(m) end
end

local function check_out()
  local m = storage.match
  local ai = loaded("scripts.ai.init")
  for _, f in ipairs(m.forces) do
    if not m.out[f] and match.is_out(f) then
      m.out[f] = game.tick
      util.log("match: %s is out at %.0fs (no CC, barracks, factory or units)", f, match.elapsed_seconds())
      if f ~= PLAYER and ai and ai.get(f) then ai.stop_force(f) end
      for _, fn in ipairs(out_callbacks) do fn(f) end
    end
  end
  local alive = {}
  for _, f in ipairs(m.ai_forces) do
    if not m.out[f] then alive[#alive + 1] = f end
  end
  local winner = match.decide_winner(m.out[PLAYER] ~= nil, #alive == 0)
  if not winner then return end
  if winner == ENEMY then winner = (#alive == 1) and alive[1] or "ai" end
  finish(winner)
end

--- The human side gives up (the menu's Concede button, lobby.lua): it is out now, and the winner rule above ends the
--- match at once with a defeat for it and the results window for everyone. Returns true when the match ended.
function match.concede(force_name, who)
  local m = storage.match
  if not (m and m.phase == "running") or force_name ~= PLAYER or m.out[force_name] then return false end
  m.out[force_name] = game.tick
  m.conceded = force_name
  util.log("match: %s concedes at %.0fs (%s)", force_name, match.elapsed_seconds(), tostring(who))
  for _, fn in ipairs(out_callbacks) do fn(force_name) end
  check_out()
  return m.phase == "ended"
end

--- Phase 5 M2 diplomacy (D6): end a Nation match by a victory mode (scripts/wars.lua victory_step). `winners` is a list
--- of forces that share the victory (an alliance; empty = a draw), `how` = "conquest" | "alliance" | "territory" |
--- "score", `detail` a log text. The end runs through the usual flow (calm, results window). Returns true when it ended.
function match.finish_by(winners, how, detail)
  local m = storage.match
  if not (m and m.phase == "running") then return false end
  m.winners = {}
  for _, f in ipairs(winners or {}) do m.winners[f] = true end
  m.victory = {how = how, detail = detail, winners = winners}
  util.log("match: %s victory for %s (%s)", tostring(how), #(winners or {}) > 0 and table.concat(winners, ", ") or "nobody",
    tostring(detail))
  finish((winners and winners[1]) or "draw")
  return true
end

-- Phase 5 M3 age3 (D1): the third stage of a Space Program (scripts/age3.lua) wins a Nation match when the victory
-- mode allows it (balance.nation.age3.modes: Conquest+Space, Any); the nation's allies share the victory.
events.on_signal("rts_space_victory", function(d)
  local m = storage.match
  if not (m and m.phase == "running" and m.config and m.config.mode == "nation" and d and d.force) then return end
  if not balance.nation.age3.modes[m.config.victory or ""] then
    util.log("match: %s completed the Space Program; victory mode %s has no Space victory", d.force,
      tostring(m.config.victory))
    return
  end
  match.finish_by(d.winners or {d.force}, "space", string.format("%s launched at %.0fs", d.force,
    match.elapsed_seconds()))
end)

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running") then return end
  if m.enemy_group and not m.enemy_group.valid then
    util.log("match: wave group #%s is gone (all members dead or disbanded)", tostring(m.enemy_group_id))
    m.enemy_group, m.enemy_group_id = nil, nil
    release_orphans()
  end
  if m.enemy_next_wave and e.tick >= m.enemy_next_wave and config().enemy_brain == "waves" then
    m.enemy_next_wave = e.tick + config().wave_period_ticks
    launch_wave()
  end
  check_out()
end)

-- Re-target the wave when its attack_area completes: nearest player unit, else the player centroid.
events.on(defines.events.on_ai_command_completed, function(e)
  local m = storage.match
  if not (m and m.enemy_group_id and e.unit_number == m.enemy_group_id) then return end
  local group = m.enemy_group
  if not (group and group.valid) or m.phase ~= "running" then return end
  local target = player_target(group.position)
  if not target then return end
  group.set_command({type = defines.command.attack_area, destination = target, radius = WAVE_RADIUS,
                     distraction = defines.distraction.by_anything})
  util.log("match: wave group #%d command completed (result=%s), re-targeted to %s", group.unique_id,
    util.define_name(defines.behavior_result, e.result), util.pos_str(target))
end)

events.on(defines.events.on_player_created, function(e)
  match.assign_player(game.get_player(e.player_index))
end)

events.on(defines.events.on_player_joined_game, function(e)
  match.assign_player(game.get_player(e.player_index))
end)

return match
