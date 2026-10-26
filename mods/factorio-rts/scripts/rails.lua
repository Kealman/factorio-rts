-- Phase 5 M1 rails (docs/PHASE5-M1.md section 3 "rails.lua"; docs/qa/phase5-rails-notes.md): depots, the line
-- planner, construction trains, freight trains with script-written schedules, repair of cut lines, the AI hook.
-- Nation mode only: every entry point is inert in Skirmish (rails.nation()), whose research and build menu never offer
-- the depot or the kits (research.NATION_ONLY for the technologies, hud.lua P4.NATION_ONLY for items and recipes).
--
-- Public API (contract):
--   rails.plan_line(force, depot_a, depot_b) -> line id (= survey job id) or nil, reason
--   rails.lines[id] = {id, force, a, b, state = "surveying" | "building" | "open" | "cut" | "failed", rails = n (bill),
--                      length (tiles of track), ...}        (rails.lines is storage.rails.lines)
--   rails.create_train(depot_un, kind = "cargo" | "construction") -> LuaTrain or nil, reason   (kits from the depot
--                      network: 2 locomotive kits + 2 cargo wagon kits, or + 1 construction wagon kit; own units on
--                      the platform track step aside first)
--   rails.deploy_check(depot_un, kind) -> nil when a train of that kind can be deployed now, else the reason
--   rails.set_route(train, pickup_depot_un, dropoff_depot_un) -> true | false
--   rails.ai_step(C)   AI commander hook (scripts/ai/commander.lua), rails.ai_program(force, state) its core
--
-- Geometry. on_init builds a scratch surface (GEO_SURFACE) with one rail per extension of every rail end state
-- (LuaRailEnd.get_rail_extensions: 16 directions x ground / elevated). The extension table itself is module-local and
-- is re-read from those scratch rails on first use after every load: reads only, so it is identical on every peer and
-- never in storage.
--
-- Depot. rts-depot is a hub subtype (logistics.lua: kind "hub", default keep 50 coal). When one is registered this
-- module lays a 40-tile platform of straight rails 7 tiles off its centre (south, north, east or west, the first that
-- fits) and two rts-depot-stop with the same name, one at each end facing inward: a train reaches whichever stop
-- matches the end the line joins, so a dead-end platform works from either side.
--
-- Survey (rails.plan_line). A job runs on on_tick within a per-tick budget, so no tick spends more than a few ms:
--   score     16x16-tile cells of the box around both depots: water, void, cliffs, trees, buildings, foreign land
--   coarse    A* over the cells; widen the box when it fails
--   corridor  cells within R of the coarse path, and a flow field (cost to go per cell) for the fine heuristic
--   fine      A* over rail end states with the learned extensions inside the corridor; ground pieces and ramps are
--             checked with build_check_type manual_ghost + forced (trees and rocks pass, water and buildings do not;
--             probe P1), elevated pieces with script (supports come later); widen the corridor when it fails
--   extract   pieces, supports (on an elevated rail end every <= 10 tiles, probe P2), signal pairs (in/out signal
--             locations at a rail end every signal_spacing tiles and at both station entries, probe P3), the bill
--   ghosts    entity-ghosts of every piece and support, a few dozen per tick
--
-- Construction train (kind "construction"): 2 locomotives + 1 construction wagon from kits in a depot network. It
-- loads the rails of the work, drives to the last built rail before the first missing piece (a temporary rail record),
-- clears trees, rocks and cliffs under the next pieces and revives their ghosts at build_rate pieces per second
-- within build_reach tiles, then returns to its depot and goes back into kits. Destroyed line rails leave a ghost
-- (on_entity_died, this module), the line turns "cut", and a crew comes from the depot on the side of the cut that the
-- line's freight train is not on. Signal pairs keep the two trains apart.
--
-- Freight train (kind "cargo"): double-headed, locomotive + 2 wagons + locomotive. Its schedule has two records (the
-- pickup and the drop-off depot stop) with a long wait; this module loads and unloads at transfer_rate items per
-- second per wagon and sends it on with go_to_station. Cargo = what the pickup's network exports above its threshold
-- and the drop-off's network still keeps (logistics.lua policies; a drop-off without keep thresholds takes every
-- export). Locomotives are topped up with coal from the depot network at every stop.
-- 0.1.2 (#31 part B): that two-record route is the AI's (rails.set_route, unchanged). A train with a stop list
-- (rec.stops: the player's trains) runs a native engine schedule instead: scripts/railroutes.lua owns it and sets
-- rails.routes = {step, click, refresh, resume, serves}; this module's train step, state handler, right click,
-- depot removal and capture call those hooks for such trains and leave their legacy paths alone.
--
-- storage.rails = {
--   version, test_nation, test_forces, test_bridges = {[force] = true} (autotest only),
--   depots  = {[depot un] = {un, force, surface, entity, platform = {axis, track, rails = {LuaEntity}, ends = {{x, y,
--              d, l}, {x, y, d, l}}, stops = {LuaEntity}, area}, stop_name, line}},
--   lines   = {[id] = line}, jobs = {[id] = survey job}, trains = {[train id] = train record}, dwelling = {[train id]},
--   index   = {[surface index] = {[piece key] = line id * 100000 + piece | -depot un}}, stops = {[stop un] = depot un},
--   stats   = {[force] = {delivered = {[item] = n}, trips, lost}}, ai = {[force] = state}, next_id
-- }
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local match = require("scripts.match")
local logistics = require("scripts.logistics")
local balance = require("balance")
local deps = require("scripts.ai.deps")
local sched = require("scripts.sched") -- Phase 5 M3 perf: surveys are scheduler jobs in a Nation match
local research
do
  local ok, mod = pcall(require, "scripts.research")
  if ok and type(mod) == "table" then research = mod end
end

local rails = {}
local CFG = balance.nation.rails

rails.DEPOT = "rts-depot"
rails.STOP = "rts-depot-stop"
rails.LOCO = "rts-locomotive"
rails.WAGON = "rts-cargo-wagon"
rails.CWAGON = "rts-construction-wagon"
rails.LOCO_KIT = "rts-locomotive-kit"
rails.WAGON_KIT = "rts-cargo-wagon-kit"
rails.CWAGON_KIT = "rts-construction-wagon-kit"
-- Phase 5 M2 war (scripts/garrison.lua, docs/PHASE5-M2.md D8): troop trains = 2 locomotives + 1..max_wagons troop wagons;
-- their troops travel as records (storage.rails.manifests[wagon unit_number], garrison.lua). Hooks set by garrison.lua:
-- troop_dwell(rec, train) while a troop train stands at one of its stops, on_stock_died(rec, entity, cause) when a
-- carriage of a recorded train dies, on_disband(rec, train) before rails.disband_train, troop_text(rec) for the panel.
rails.TWAGON = "rts-troop-wagon"
rails.TWAGON_KIT = "rts-troop-wagon-kit"
rails.troop_dwell, rails.on_stock_died, rails.on_disband, rails.troop_text = nil, nil, nil, nil
-- Phase 5 M3 war2 (scripts/trainswar.lua, docs/PHASE5-M3.md D6): artillery trains (2 locomotives + 1 artillery wagon)
-- and armoured stock (create_train opts.armoured: armoured locomotives, armoured troop wagons). rails.KIND_HOOKS[kind] =
-- {right_click = fn(player_index, position, entities, alt, trec, train, depot_un) -> order, n} for the kinds another
-- module drives (trainswar.lua: "artillery").
rails.ARTY = "rts-artillery-wagon"
rails.ARTY_KIT = "rts-artillery-wagon-kit"
rails.ALOCO = "rts-armoured-locomotive"
rails.ALOCO_KIT = "rts-armoured-locomotive-kit"
rails.AWAGON = "rts-armoured-wagon"
rails.AWAGON_KIT = "rts-armoured-wagon-kit"
rails.KIND_HOOKS = {}
rails.RAIL = "rail"
rails.SIGNAL = "rail-signal"
rails.SUPPORT = "rail-support"
rails.RAMP = "rail-ramp"
rails.FUEL = "coal"
rails.KIND = "train"                -- buildings.lua kind of rolling stock (click-selects a train like a building)
rails.GEO_SURFACE = "rts-rails-geometry"
rails.PLATFORM_PIECES = 20          -- straight rails of a platform (40 tiles: a 4-carriage train is 28)
rails.PLATFORM_GAP = 7              -- tiles from the depot centre to the platform track
rails.CELL = 16                     -- coarse grid cell, tiles
rails.SURVEY_CELLS = 120            -- cells scored per tick
rails.SURVEY_COARSE = 400           -- coarse A* expansions per tick
rails.SURVEY_EXPANSIONS = 150       -- fine A* expansions per tick (about 2-3.5 ms on a busy machine)
rails.SURVEY_GHOSTS = 50            -- ghosts placed per tick
rails.MAX_EXPANSIONS = 160000       -- fine A* gives up after this many (per corridor width)
rails.MAX_CORRIDOR = 3              -- corridor radius in cells, widened from 1 when the fine search fails
rails.WEIGHT = 1.3                  -- heuristic weight (weighted A*)
rails.WALL_CROSS_COST = 6           -- Phase 5 M3 integration: extra cost of a straight piece over own walls (gated)
-- Phase 5 M3 perf: in a Nation match a survey is a scheduler job (scripts/sched.lua kind "rails_survey") that spends
-- the nation's work units instead of the fixed per-tick counts above (those stay for the rails autotest outside a
-- match). Units per item, calibrated with PERF=1 so that one unit is about 1 microsecond (docs/qa/phase5-perf-notes.md):
-- a scored cell (5 area counts and a territory lookup), a coarse A* expansion, a fine A* expansion plus each new piece
-- placement check, a corridor cell (Dijkstra and flow field), an extracted piece, a placed ghost.
-- Phase 5 M3 integration: fine 10 and check 36 (were 6 and 12): a survey that failed in its fine phase (366,662
-- expansions, 480,601 placement checks) ran at 3.8 microseconds per unit, 4 ms a tick of scheduler time in a 4-nation
-- match (seed 702, minutes 55-60)
rails.SURVEY_UNITS = {cell = 25, coarse = 4, fine = 10, check = 36, corridor = 3, extract = 2, ghost = 20}
rails.SURVEY_SCHED = true
rails.SUPPORT_SPACING = 10          -- tiles of elevated track between supports (probe P2: <= 12 holds)
rails.RAMP_SLACK = 2                -- a ramp's elevated end counts as a support this many tiles "used"
rails.STEP = 30                     -- train state machine and builder period, ticks
rails.TRANSFER_PERIOD = 10          -- depot transfer period, ticks
rails.CHECK_PERIOD = 60             -- line checks (open, cut, builder dispatch), ticks
rails.LONG_WAIT = 60 * 60 * 60      -- schedule wait: the script sends trains on, this is only a safety net
rails.SURVEY_CLEARANCE = 48         -- an AI depot waits while a line within this many tiles is surveyed
rails.DETOUR_AFTER = 2 * 60 * 60     -- a line blocked this long (doubling per detour) is surveyed again around the piece
rails.DETOUR_SPAN = {6, 12, 24}       -- pieces replaced on each side of the blocked one, per detour attempt
rails.MAX_PIECE_FAILS = 20          -- a piece that will not revive this many times blocks the line (alert)
rails.WAGON_STACKS = 20             -- construction wagon slots
rails.CARRIAGE = 7                  -- tiles between carriage centres
rails.CREW_COAL = 50                -- coal a construction wagon takes along for its locomotives
-- Economy 0.1.1 follow-up (r2-ai's report): a crew that neither moves a tile nor lays a piece for CREW_STUCK_TICKS
-- goes home; one that cannot get home either is recalled (its kits, rails and coal go back into its depot's network).
-- Crews of crossing lines jammed into each other at the crossing and stood for the rest of the match (M2 803 on 2.1:
-- lines #7 and #9 never opened); a crew waiting at a signal of a block such a crew held stood as long.
rails.CREW_STUCK_TICKS = 2 * 60 * 60
-- a crew leaves only with rails for at least min(the line's need, CREW_MIN_RAILS): crews with 1-3 rails left a depot
-- every game second while the rails trickled in (M2 803: 18 crews in 14 s)
rails.CREW_MIN_RAILS = 40

-- The depot is a hub subtype: kind "hub" (logistics.lua builds the hub composite, keeps its policy, shows the hub
-- panel), named "Depot n" through logistics.NAME_HOOKS; this module adds the platform and sets its default policy.
buildings.KIND_BY_NAME[rails.DEPOT] = "hub"
rails.DEPOT_POLICY = {keep = {coal = 50}} -- replaces the hub defaults (50 iron, 20 copper) on a new depot
if logistics.NAME_HOOKS then
  logistics.NAME_HOOKS[rails.DEPOT] = function(un)
    local d = storage.rails and storage.rails.depots[un]
    return {"rts.depot-name", d and d.index or un}
  end
end
-- Rolling stock is a building of kind "train" (selection, removal events, fog); rails.lua keeps the train records.
buildings.KIND_BY_NAME[rails.LOCO] = rails.KIND
buildings.KIND_BY_NAME[rails.WAGON] = rails.KIND
buildings.KIND_BY_NAME[rails.CWAGON] = rails.KIND
buildings.KIND_BY_NAME[rails.TWAGON] = rails.KIND -- Phase 5 M2 war
-- Phase 5 M3 war2: artillery wagons and armoured stock are rolling stock too
for _, name in ipairs({rails.ARTY, rails.ALOCO, rails.AWAGON}) do buildings.KIND_BY_NAME[name] = rails.KIND end
-- Ctrl+A and box selection take units only; trains are clicked.
selection.SELECT_ALL_SKIP[rails.KIND] = true
-- QA round 1: a click picks rolling stock and depots only inside their (oriented) selection box, not 1 tile around it
if selection.EXACT_PICK_KINDS then
  selection.EXACT_PICK_KINDS[rails.KIND] = true
  selection.EXACT_PICK_NAMES[rails.DEPOT] = true
end

-- Research (scripts/research.lua): Railways unlocks the depot, rails and kits; Bridges lets the planner fly over water.
-- Both technologies are Nation-only.
local UNLOCKS = {rails.DEPOT, "rts-rail", rails.LOCO_KIT, rails.WAGON_KIT, rails.CWAGON_KIT,
                 "rts-district-rails", "rts-dra-rail"} -- Phase 5 M2 integration: the Rail works in Age I (scripts/ages.lua)
if research then
  research.EFFECTS["rts-railways"] = {unlock = UNLOCKS}
  research.EFFECTS["rts-bridges"] = {flag = "bridges"}
  for _, name in ipairs(UNLOCKS) do research.LOCKS[name] = "rts-railways" end
  -- Nation-only technologies (research.lua: left out of research.list(), disabled outside Nation mode)
  if research.NATION_ONLY then
    research.NATION_ONLY["rts-railways"] = true
    research.NATION_ONLY["rts-bridges"] = true
  end
end
deps.rails = rails -- the AI reads it at run time (scripts/ai/deps.lua)

local D = defines.direction
local RD = defines.rail_direction
local TS = defines.train_state
local floor, sqrt, min, max, abs = math.floor, math.sqrt, math.min, math.max, math.abs

-- Rail entity names (elevated ones only with the elevated-rails mod).
local RAIL_NAMES, NAME_INDEX = {}, {}
for _, n in ipairs({"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b", "elevated-straight-rail",
                    "elevated-half-diagonal-rail", "elevated-curved-rail-a", "elevated-curved-rail-b", "rail-ramp"}) do
  if prototypes.entity[n] then
    RAIL_NAMES[#RAIL_NAMES + 1] = n
    NAME_INDEX[n] = #RAIL_NAMES
  end
end
local RAIL_SET = {}
for _, n in ipairs(RAIL_NAMES) do RAIL_SET[n] = true end
local STOCK_SET = {[rails.LOCO] = true, [rails.WAGON] = true, [rails.CWAGON] = true,
                   [rails.TWAGON] = true} -- Phase 5 M2 war: troop wagons
STOCK_SET[rails.ARTY], STOCK_SET[rails.ALOCO], STOCK_SET[rails.AWAGON] = true, true, true -- Phase 5 M3 war2
-- Phase 5 M2 war: the kit each carriage came from (rails.disband_train)
local KIT_OF = {[rails.LOCO] = rails.LOCO_KIT, [rails.WAGON] = rails.WAGON_KIT, [rails.CWAGON] = rails.CWAGON_KIT,
                [rails.TWAGON] = rails.TWAGON_KIT}
-- Phase 5 M3 war2: the kits of the artillery wagon and the armoured stock
KIT_OF[rails.ARTY], KIT_OF[rails.ALOCO], KIT_OF[rails.AWAGON] = rails.ARTY_KIT, rails.ALOCO_KIT, rails.AWAGON_KIT
rails.KITS = {} -- Phase 5 M3 war2: every rolling-stock kit -> the carriage it makes (docs/PHASE5-M3.md section 3)
for stock, kit in pairs(KIT_OF) do rails.KITS[kit] = stock end
local FREIGHT = {cargo = true, troop = true} -- Phase 5 M2 war: kinds with a pickup -> drop-off route
rails.FREIGHT = FREIGHT -- 0.1.2 (#31): scripts/railroutes.lua
rails.KIT_OF = KIT_OF   -- 0.1.2 (#32): the train builder
-- Entity types that block a coarse cell (with water and void). Trees, rocks and cliffs are cleared by the builder.
local BLOCKER_TYPES = {"assembling-machine", "furnace", "mining-drill", "roboport", "container", "logistic-container",
  "ammo-turret", "electric-turret", "fluid-turret", "artillery-turret", "wall", "gate", "radar", "lab", "solar-panel",
  "accumulator", "boiler", "generator", "reactor", "train-stop", "rocket-silo", "unit-spawner", "beacon", "pipe",
  "pipe-to-ground", "storage-tank", "pump", "offshore-pump", "inserter", "transport-belt", "underground-belt",
  "splitter", "lamp"}
local CLEAR_TYPES = {"tree", "simple-entity", "cliff"}
local WALL_TYPES = {"wall", "gate"} -- Phase 5 M3 integration: own ones are crossed (rails.WALL_CROSS_COST, gates)
local MANUAL_GHOST, SCRIPT, MANUAL = defines.build_check_type.manual_ghost, defines.build_check_type.script,
  defines.build_check_type.manual

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function rstate()
  local R = storage.rails
  if not R then
    R = {}
    storage.rails = R
  end
  R.version = R.version or 1
  R.depots = R.depots or {}
  R.lines = R.lines or {}
  R.jobs = R.jobs or {}
  R.trains = R.trains or {}
  R.dwelling = R.dwelling or {}
  R.index = R.index or {}
  R.stops = R.stops or {}
  R.stats = R.stats or {}
  R.ai = R.ai or {}
  R.next_id = R.next_id or 1
  return R
end

local function bind()
  rails.lines = storage.rails and storage.rails.lines or {}
end
rails.lines = {}

--- True in Nation mode (storage.match.config.mode == "nation") or in the rails autotest.
function rails.nation()
  local R = storage.rails
  if R and R.test_nation then return true end
  local m = storage.match
  local c = m and m.config
  return c ~= nil and c.mode == "nation"
end

function rails.stats(force_name)
  local R = rstate()
  local s = R.stats[force_name]
  if not s then
    s = {delivered = {}, trips = 0, lost = 0, items = 0}
    R.stats[force_name] = s
  end
  return s
end

local function sorted_keys(t)
  local list = {}
  for k in pairs(t) do list[#list + 1] = k end
  table.sort(list)
  return list
end

local function alert(force, kind, position, key)
  local ok = pcall(logistics.alert, force, kind, position, key)
  if not ok then util.log("rails: alert %s failed", kind) end
end

local function force_color(force_name)
  local f = game.forces[force_name]
  return f and (f.custom_color or f.color) or nil
end

---------------------------------------------------------------------------
-- Geometry (module-local; see the header)
---------------------------------------------------------------------------
local GEO, LEN, HAS_RAMP

local function geo_surface()
  local s = game.surfaces[rails.GEO_SURFACE]
  if s then return s end
  s = game.create_surface(rails.GEO_SURFACE, {
    width = 0, height = 0, default_enable_all_autoplace_controls = false, autoplace_controls = {},
    autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
                          decorative = {treat_missing_as_default = false, settings = {}}},
    cliff_settings = {name = "cliff", cliff_elevation_0 = 1024, cliff_elevation_interval = 10, richness = 0},
    no_enemies_mode = true, peaceful_mode = true,
  })
  s.generate_with_lab_tiles = true
  s.always_day = true
  for x = 0, 480, 32 do
    for y = 0, 480, 32 do s.request_to_generate_chunks({x + 16, y + 16}, 0) end
  end
  s.force_generate_chunk_requests()
  return s
end

-- Learn the extension table: one scratch rail per extension of every end state, each in its own 40-tile slot.
local function learn_geometry()
  local s = geo_surface()
  if #s.find_entities_filtered({name = RAIL_NAMES, limit = 1}) > 0 then return end
  local force = "neutral"
  pcall(function() game.forces.neutral.rail_planner_allow_elevated_rails = true end)
  local prof = helpers.create_profiler()
  local seen, slot, queue, qi, placed, failed = {}, 0, {}, 0, 0, 0
  local function origin()
    local i = slot
    slot = slot + 1
    return {x = (i % 12) * 40 + 8, y = floor(i / 12) * 40 + 8}
  end
  local o = origin()
  local seed = s.create_entity({name = "straight-rail", position = {o.x + 1, o.y + 1}, direction = D.east, force = force})
  if not seed then
    util.log("rails: geometry seed rail could not be placed")
    return
  end
  queue[1] = seed.get_rail_end(RD.front)
  queue[2] = seed.get_rail_end(RD.back)
  while qi < #queue and qi < 1000 do
    qi = qi + 1
    local e = queue[qi]
    local loc = e.location
    local k = loc.direction * 2 + loc.rail_layer
    if not seen[k] then
      seen[k] = true
      for _, x in ipairs(e.get_rail_extensions("rail")) do
        local og = origin()
        local dx = og.x - 2 * floor(loc.position.x / 2)
        local dy = og.y - 2 * floor(loc.position.y / 2)
        local pos = {x = x.position.x + dx, y = x.position.y + dy}
        local ent = s.create_entity({name = x.name, position = pos, direction = x.direction, force = force})
        if not ent then
          -- elevated pieces need a support on a rail end (probe P2): their start end, then their own position
          s.create_entity({name = rails.SUPPORT, position = {loc.position.x + dx, loc.position.y + dy},
                           direction = loc.direction, force = force})
          ent = s.create_entity({name = x.name, position = pos, direction = x.direction, force = force})
          if not ent then
            s.create_entity({name = rails.SUPPORT, position = pos, direction = x.direction, force = force})
            ent = s.create_entity({name = x.name, position = pos, direction = x.direction, force = force})
          end
        end
        if ent then
          placed = placed + 1
          local gx, gy = x.goal.position.x + dx, x.goal.position.y + dy
          for _, rd in ipairs({RD.front, RD.back}) do
            local re = ent.get_rail_end(rd)
            local p = re.location.position
            if abs(p.x - gx) < 0.15 and abs(p.y - gy) < 0.15 and re.location.direction == x.goal.direction then
              queue[#queue + 1] = re
            end
          end
        else
          failed = failed + 1
        end
      end
    end
  end
  prof.stop()
  log({"", string.format("[rts] rails: geometry learned on %s: %d end states, %d scratch rails, %d failed, in ",
    rails.GEO_SURFACE, table_size(seen), placed, failed), prof})
end

local function entries_of(re)
  local loc = re.location
  local out = {}
  for _, x in ipairs(re.get_rail_extensions("rail")) do
    local name = x.name
    if NAME_INDEX[name] then
      local proto = prototypes.entity[name]
      local items = proto and proto.items_to_place_this
      local count = 1
      if items and items[1] and items[1].name == rails.RAIL then count = items[1].count or 1 end
      local ramp = name == rails.RAMP
      local elev = (not ramp) and string.sub(name, 1, 9) == "elevated-"
      local curve = string.find(name, "curved", 1, true) ~= nil or string.find(name, "half", 1, true) ~= nil
      local len = LEN[name .. "|" .. x.direction] or 2
      out[#out + 1] = {
        name = name, ni = NAME_INDEX[name], dir = x.direction,
        dx = x.position.x - loc.position.x, dy = x.position.y - loc.position.y,
        gdx = x.goal.position.x - loc.position.x, gdy = x.goal.position.y - loc.position.y,
        gdir = x.goal.direction, glayer = x.goal.rail_layer,
        len = len, rails = ramp and CFG.ramp_rails or count, elev = elev, ramp = ramp,
        cost = len * (elev and 1.5 or 1) + (ramp and 20 or 0) + (curve and 1 or 0),
      }
      if ramp then HAS_RAMP = true end
    end
  end
  table.sort(out, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.dir ~= b.dir then return a.dir < b.dir end
    if a.dx ~= b.dx then return a.dx < b.dx end
    return a.dy < b.dy
  end)
  return out
end

--- The extension table {[direction * 2 + layer] = {entry, ...}}, read from the scratch rails on first use.
local function geometry()
  if GEO then return GEO end
  local s = game.surfaces[rails.GEO_SURFACE]
  if not s then return nil end
  local list = s.find_entities_filtered({name = RAIL_NAMES})
  if #list == 0 then return nil end
  LEN = {}
  for _, e in ipairs(list) do LEN[e.name .. "|" .. e.direction] = e.rail_length end
  local geo, n = {}, 0
  for _, e in ipairs(list) do
    for _, rd in ipairs({RD.front, RD.back}) do
      local re = e.get_rail_end(rd)
      local loc = re.location
      local k = loc.direction * 2 + loc.rail_layer
      if not geo[k] then
        geo[k] = entries_of(re)
        n = n + 1
      end
    end
  end
  GEO = geo
  util.log("rails: geometry read: %d end states from %d scratch rails, ramps %s", n, #list, tostring(HAS_RAMP == true))
  return GEO
end
rails.geometry = geometry

--- True when the force may plan elevated spans (Bridges researched, or the autotest).
function rails.bridges(force_name)
  if not geometry() or not HAS_RAMP then return false end
  local R = storage.rails
  if R and R.test_bridges and R.test_bridges[force_name] then return true end
  return research ~= nil and research.flag(force_name, "bridges")
end

-- Keys: node = end state (x, y on a half-tile grid, direction, layer); piece = position, name, direction.
local OFF, SPAN = 32768, 65536
local function nkey(x, y, d, l)
  return ((floor(x * 2 + 0.5) + OFF) * SPAN + (floor(y * 2 + 0.5) + OFF)) * 32 + d * 2 + l
end
local function ndecode(k)
  local dl = k % 32
  local r = (k - dl) / 32
  local y2 = r % SPAN
  local x2 = (r - y2) / SPAN
  return (x2 - OFF) / 2, (y2 - OFF) / 2, floor(dl / 2), dl % 2
end
local function pkey(name, x, y, d)
  return ((floor(x * 2 + 0.5) + OFF) * SPAN + (floor(y * 2 + 0.5) + OFF)) * 256 + (NAME_INDEX[name] or 0) * 16 + d
end
local function ckey(cx, cy) return (cx + 4096) * 8192 + (cy + 4096) end
local function cdecode(k)
  local cy = k % 8192
  return (k - cy) / 8192 - 4096, cy - 4096
end

---------------------------------------------------------------------------
-- Depots and platforms
---------------------------------------------------------------------------
--- Depot record, or nil.
function rails.depot(un)
  local R = storage.rails
  local d = R and un and R.depots[un]
  if d and d.entity.valid then return d end
  return nil
end

function rails.is_depot(un) return rails.depot(un) ~= nil end

local function stop_name(force_name, un)
  return string.format("%s depot %d", force_name, un)
end

-- Phase 5 M3 integration (M2 integration open issue 8): the stops keep their unique script names (schedules use them),
-- but the map shows the owner a localised "Depot N" instead; the engine's station names are hidden in Nation matches
-- (map view setting show-train-station-names, restored at teardown).
rails.LABEL_SCALE = 8 -- world-sized like the strategic labels (cities 16, ports 14): 1.6 was unreadable on the map, a
                      -- screen-sized label (scale_with_zoom) covered the HUD minimap
local function draw_depot_label(d)
  if d.label and d.label.valid then d.label.destroy() end
  d.label = nil
  local e = d.entity
  if not (e and e.valid) then return end
  d.label = rendering.draw_text({text = {"rts.depot-name", d.index or d.un}, surface = e.surface, target = {entity = e,
    offset = {0, -6}}, color = {r = 0.85, g = 0.85, b = 1, a = 1}, scale = rails.LABEL_SCALE, alignment = "center",
    vertical_alignment = "middle", render_mode = "chart", forces = {d.force}})
end

local function station_names(player, show)
  if player and player.valid then player.map_view_settings = {["show-train-station-names"] = show} end
end
match.on_started(function()
  if not rails.nation() then return end
  for _, p in pairs(game.players) do station_names(p, false) end
end)
events.on(defines.events.on_player_joined_game, function(e)
  station_names(game.get_player(e.player_index), not rails.nation())
end)

-- Platform layouts around a depot at p: {axis, track coordinate, rail centres, ends, stop specs}.
local function platform_specs(p)
  local cx, cy = 2 * floor(p.x / 2), 2 * floor(p.y / 2)
  local half = rails.PLATFORM_PIECES -- tiles from the platform centre to an end
  local specs = {}
  for _, side in ipairs({{"x", 1}, {"x", -1}, {"y", 1}, {"y", -1}}) do
    local axis, sign = side[1], side[2]
    local spec = {axis = axis, side = sign, rails = {}}
    if axis == "x" then
      local ty = 2 * floor((p.y + sign * rails.PLATFORM_GAP) / 2) + 1
      spec.track = ty
      for i = 0, rails.PLATFORM_PIECES - 1 do spec.rails[#spec.rails + 1] = {x = cx - half + 1 + 2 * i, y = ty} end
      spec.ends = {{x = cx - half, y = ty, d = D.west, l = 0}, {x = cx + half, y = ty, d = D.east, l = 0}}
      -- a train coming in through the east end runs west and stops near the west end (stop north of the track)
      spec.stops = {{x = cx - half + 3, y = ty - 2, d = D.west}, {x = cx + half - 3, y = ty + 2, d = D.east}}
      spec.area = {{cx - half - 1, ty - 4}, {cx + half + 1, ty + 4}}
    else
      local tx = 2 * floor((p.x + sign * rails.PLATFORM_GAP) / 2) + 1
      spec.track = tx
      for i = 0, rails.PLATFORM_PIECES - 1 do spec.rails[#spec.rails + 1] = {x = tx, y = cy - half + 1 + 2 * i} end
      spec.ends = {{x = tx, y = cy - half, d = D.north, l = 0}, {x = tx, y = cy + half, d = D.south, l = 0}}
      spec.stops = {{x = tx + 2, y = cy - half + 3, d = D.north}, {x = tx - 2, y = cy + half - 3, d = D.south}}
      spec.area = {{tx - 4, cy - half - 1}, {tx + 4, cy + half + 1}}
    end
    specs[#specs + 1] = spec
  end
  return specs
end

local function rail_dir(spec) return spec.axis == "x" and D.east or D.north end

-- Phase 5 M3 integration: does `area` (grown by `margin`) cover a surveyed piece not laid yet of a line on the surface?
-- A depot or platform placed there blocks that line for good (M1 seed 501: an AI depot's stop stood on piece 24 of the
-- player's town line, surveyed a second earlier, which then never revived).
local function covers_planned(surface_index, area, margin)
  local x0, y0 = area[1][1] - margin, area[1][2] - margin
  local x1, y1 = area[2][1] + margin, area[2][2] + margin
  for _, line in pairs(rstate().lines) do
    if line.surface == surface_index and line.pieces and line.pieces[1] and (line.missing or 0) > 0 then
      local bb = line.bbox
      if not bb then
        local p1 = line.pieces[1]
        bb = {p1.x, p1.y, p1.x, p1.y}
        for _, p in ipairs(line.pieces) do
          bb[1], bb[2], bb[3], bb[4] = min(bb[1], p.x), min(bb[2], p.y), max(bb[3], p.x), max(bb[4], p.y)
        end
        line.bbox = bb
      end
      if bb[1] <= x1 and bb[3] >= x0 and bb[2] <= y1 and bb[4] >= y0 then
        for _, p in ipairs(line.pieces) do
          if p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 and not (p.e and p.e.valid) then return true end
        end
      end
    end
  end
  return false
end

-- Phase 5 M3 integration: is `p` within `width` tiles of the straight way between the depots of a line on the surface
-- that is being surveyed? Its pieces are not known yet (a depot placed there during the survey stood on the finished
-- line: M1 seed 501, piece 4 of the player's town line under depot #2941, placed 0.3 s into the survey).
local function near_survey(surface_index, p, width)
  for _, line in pairs(rstate().lines) do
    if line.surface == surface_index and line.state == "surveying" then
      local A, B = rails.depot(line.a), rails.depot(line.b)
      if A and B and A.entity.valid and B.entity.valid then
        local a, b = A.entity.position, B.entity.position
        local dx, dy = b.x - a.x, b.y - a.y
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) or 0
        local ex, ey = p.x - (a.x + t * dx), p.y - (a.y + t * dy)
        if ex * ex + ey * ey <= width * width then return true end
      end
    end
  end
  return false
end

-- `strict`: the platform must also keep clear of the pieces other lines still have to lay (covers_planned)
local function spec_fits(surface, force_name, spec, strict)
  if strict and covers_planned(surface.index, spec.area, 3) then return false end
  for _, r in ipairs(spec.rails) do
    if not surface.can_place_entity({name = "straight-rail", position = {r.x, r.y}, direction = rail_dir(spec),
                                     force = force_name, build_check_type = MANUAL_GHOST, forced = true}) then
      return false
    end
  end
  -- a stop cannot pass a placement check before its rail exists: its 2x2 box must hold no water and no buildings
  for _, st in ipairs(spec.stops) do
    local area = {{st.x - 1, st.y - 1}, {st.x + 1, st.y + 1}}
    if surface.count_tiles_filtered({area = area, collision_mask = "water_tile", limit = 1}) > 0
       or surface.count_entities_filtered({area = area, type = BLOCKER_TYPES, limit = 1}) > 0
       or surface.count_entities_filtered({area = area, name = RAIL_NAMES, limit = 1}) > 0 then
      return false
    end
  end
  return true
end

--- The first platform layout that fits next to a depot position (nil when none does). For depot placement (AI): it
--- keeps clear of the pieces lines still have to lay, as the platform built for that depot then does.
function rails.platform_fits(surface, force_name, position)
  for _, spec in ipairs(platform_specs(position)) do
    if spec_fits(surface, force_name, spec, true) then return spec end
  end
  return nil
end

-- Destroy trees, rocks and cliffs in an area. `count` (optional table) gets {tree, ["simple-entity"], cliff} added.
local function clear_area(surface, area, count)
  local n = 0
  for _, e in ipairs(surface.find_entities_filtered({area = area, type = CLEAR_TYPES})) do
    if e.valid then
      local t = e.type
      if t == "cliff" then e.destroy({do_cliff_correction = true}) else e.destroy() end
      n = n + 1
      if count then count[t] = (count[t] or 0) + 1 end
    end
  end
  return n
end

local function index_of(surface_index)
  local R = rstate()
  local t = R.index[surface_index]
  if not t then
    t = {}
    R.index[surface_index] = t
  end
  return t
end

local function place_stops(d, spec)
  local surface, force_name = d.entity.surface, d.force
  d.platform.stops = d.platform.stops or {}
  local R = rstate()
  for i, st in ipairs(spec.stops) do
    local cur = d.platform.stops[i]
    if not (cur and cur.valid) then
      local made
      for _, shift in ipairs({0, 2, -2, 4}) do
        local pos = spec.axis == "x" and {st.x + shift, st.y} or {st.x, st.y + shift}
        local e = surface.create_entity({name = rails.STOP, position = pos, direction = st.d, force = force_name})
        if e then
          if e.connected_rail then
            made = e
            break
          end
          e.destroy()
        end
      end
      if made then
        made.backer_name = d.stop_name
        local color = force_color(force_name)
        if color then made.color = color end
        d.platform.stops[i] = made
        R.stops[made.unit_number] = d.un
      else
        util.log("rails: depot #%d: stop %d could not be placed near (%.1f, %.1f)", d.un, i, st.x, st.y)
      end
    end
  end
end

-- Lay the platform of a freshly registered depot.
local function setup_depot(un, rec)
  local R = rstate()
  local e = rec.entity
  local d = R.depots[un]
  if not d then
    R.depot_index = R.depot_index or {}
    R.depot_index[rec.force] = (R.depot_index[rec.force] or 0) + 1
    d = {un = un, force = rec.force, surface = e.surface.index, entity = e, stop_name = stop_name(rec.force, un),
         index = R.depot_index[rec.force]}
    R.depots[un] = d
    draw_depot_label(d) -- Phase 5 M3 integration
    -- a depot keeps coal for the locomotives instead of the hub's plates (set once; the player edits it later)
    local pol = logistics.policy(un)
    if pol then
      for item in pairs(pol.keep) do
        if not rails.DEPOT_POLICY.keep[item] then logistics.set_policy(un, "keep", item, nil) end
      end
      for item, n in pairs(rails.DEPOT_POLICY.keep) do logistics.set_policy(un, "keep", item, n) end
    end
  end
  if d.platform then return d end
  local surface = e.surface
  local spec
  -- Economy 0.1.1 (#7, #2): a depot rebuilt on a lost depot's site (rails.ai_program, ai_depot) takes the old platform
  -- layout and the old platform rails that still stand there (spec_fits refuses rails on rails)
  local reuse = R.reuse_site
  R.reuse_site = nil
  if reuse and reuse.force == rec.force and math.abs(reuse.x - e.position.x) < 0.5
     and math.abs(reuse.y - e.position.y) < 0.5 then
    for _, s in ipairs(platform_specs(e.position)) do
      if s.axis == reuse.spec.axis and s.side == reuse.spec.side and s.track == reuse.spec.track then spec = s end
    end
  end
  -- (a layout clear of other lines' unlaid pieces first; then any that fits, as before)
  for _, strict in ipairs(spec and {} or {true, false}) do
    for _, s in ipairs(platform_specs(e.position)) do
      if spec_fits(surface, rec.force, s, strict) then
        spec = s
        break
      end
    end
    if spec then break end
  end
  if not spec then
    util.log("rails: depot #%d of %s at %s: no room for a platform", un, rec.force, util.pos_str(e.position))
    alert(rec.force, "depot-no-platform", e.position, "rts.alert-depot-no-platform")
    return d
  end
  local cleared = clear_area(surface, spec.area)
  local platform = {axis = spec.axis, side = spec.side, track = spec.track, rails = {}, area = spec.area, stops = {}}
  d.platform = platform
  local idx = index_of(surface.index)
  for _, r in ipairs(spec.rails) do
    local rail = reuse and surface.find_entity("straight-rail", {r.x, r.y})
    if not (rail and rail.valid and rail.direction == rail_dir(spec)) then
      rail = surface.create_entity({name = "straight-rail", position = {r.x, r.y}, direction = rail_dir(spec),
                                    force = rec.force})
    end
    platform.rails[#platform.rails + 1] = rail
    if rail then idx[pkey("straight-rail", rail.position.x, rail.position.y, rail.direction)] = -un end
  end
  platform.ends = spec.ends
  place_stops(d, spec)
  platform.spec = spec
  util.log("rails: depot #%d (%s) of %s at %s: platform %s%+d, track %s=%d, %d rails, %d stops '%s', %d obstacles cleared",
    un, util.pos_str(e.position), rec.force, util.pos_str(e.position), spec.axis, spec.side, spec.axis == "x" and "y" or "x",
    spec.track, #platform.rails, #platform.stops, d.stop_name, cleared)
  return d
end

buildings.on_added(function(un, rec)
  if rec.kind == "hub" and rec.entity.valid and rec.entity.name == rails.DEPOT then setup_depot(un, rec) end
end)

buildings.on_removed(function(un, rec)
  local R = storage.rails
  local d = R and R.depots[un]
  if not d then return end
  R.depots[un] = nil
  for _, st in pairs(d.platform and d.platform.stops or {}) do
    if st.valid then
      R.stops[st.unit_number] = nil
      st.destroy()
    end
  end
  util.log("rails: depot #%d of %s removed (platform rails stay)", un, d.force)
  -- Phase 5 M2 integration: a line without one of its depots is lost (it stood "building" or "open" with no path to
  -- the missing end; seed 703: the far depot died in the fight for the town). The AI program re-binds it to a new
  -- depot on the same spot or plans a new line (rails.ai_program).
  local line = d.line and R.lines[d.line]
  local p = d.entity and d.entity.valid and d.entity.position or rec.position
  local sp = d.platform and d.platform.spec
  local spec = sp and {axis = sp.axis, track = sp.track, side = sp.side} or nil
  if line and line.state ~= "lost" then
    line.state = "lost"
    line.lost_depot = {un = un, x = p and p.x, y = p and p.y, spec = spec}
    local other = R.depots[line.a == un and line.b or line.a]
    if other and other.line == line.id then other.line = nil end
    util.log("rails: line #%d of %s lost: depot #%d is gone", line.id, line.force, un)
  end
  -- a line lost with its city (force change) whose depot dies meanwhile remembers where the depot stood
  for _, id in ipairs(sorted_keys(R.lines)) do
    local ln = R.lines[id]
    if ln.state == "lost" and not ln.lost_depot and (ln.a == un or ln.b == un) then
      ln.lost_depot = {un = un, x = p and p.x, y = p and p.y, spec = spec}
    end
  end
  if rails.routes then rails.routes.refresh(un) end -- 0.1.2 (#31 part B): stop lists skip the gone depot
end)

local function platform_free(d)
  local p = d.platform
  if not p then return false end
  local surface = d.entity.surface
  return surface.count_entities_filtered({area = p.area, type = {"locomotive", "cargo-wagon", "fluid-wagon",
                                                                  "artillery-wagon"}}) == 0
end

---------------------------------------------------------------------------
-- Survey (time-sliced planner)
---------------------------------------------------------------------------
local function heap_push(hf, hk, f, k)
  local i = #hk + 1
  hf[i], hk[i] = f, k
  while i > 1 do
    local p = floor(i / 2)
    if hf[p] <= f then break end
    hf[i], hk[i] = hf[p], hk[p]
    i = p
  end
  hf[i], hk[i] = f, k
end

local function heap_pop(hf, hk)
  local n = #hk
  local topk = hk[1]
  local lf, lk = hf[n], hk[n]
  hf[n], hk[n] = nil, nil
  n = n - 1
  if n > 0 then
    local i = 1
    while true do
      local l = 2 * i
      if l > n then break end
      local r = l + 1
      local c = (r <= n and hf[r] < hf[l]) and r or l
      if hf[c] >= lf then break end
      hf[i], hk[i] = hf[c], hk[c]
      i = c
    end
    hf[i], hk[i] = lf, lk
  end
  return topk
end

-- Phase 5 M1 integration: package.loaded is keyed by the resolved file ("__factorio-rts__/scripts/territory.lua"), so
-- the plain module name never matched and the survey never saw foreign land, nor the AI hook its cities.
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

local function territory_owner(position)
  local t = loaded("scripts.territory")
  if type(t) ~= "table" or not t.owner_at then return nil end
  local ok, owner = pcall(t.owner_at, position)
  return ok and owner or nil
end

-- Score one coarse cell: cost (nil = blocked), multiplier for fine pieces in it, cliff flag.
local function score_cell(job, s, cx, cy)
  local C = rails.CELL
  local x0, y0 = cx * C, cy * C
  if not s.is_chunk_generated({floor(x0 / 32), floor(y0 / 32)}) then return nil, 1, false end
  local area = {{x0, y0}, {x0 + C, y0 + C}}
  local water = s.count_tiles_filtered({area = area, collision_mask = "water_tile"})
  local void = s.count_tiles_filtered({area = area, name = "out-of-map"})
  local cliffs = s.count_entities_filtered({area = area, type = "cliff"})
  local trees = s.count_entities_filtered({area = area, type = {"tree", "simple-entity"}})
  local blockers = s.count_entities_filtered({area = area, type = BLOCKER_TYPES})
  -- Phase 5 M3 integration (war2 notes open issue 4): own walls and gates (a fort belt) are crossed at a gate
  blockers = blockers - s.count_entities_filtered({area = area, type = WALL_TYPES, force = job.force})
  local owner = territory_owner({x = x0 + C / 2, y = y0 + C / 2})
  local foreign = owner ~= nil and owner ~= job.force
  local mul = 1 + min(trees, 64) / 128 + (cliffs > 0 and 0.5 or 0) + min(blockers, 16) / 8 + (foreign and 0.5 or 0)
  local wf = (water + void) / (C * C)
  local cost
  if void >= C * C / 2 or blockers >= 24 then
    cost = nil
  elseif wf > 0.75 then
    cost = job.bridges and C * (mul + 3) or nil
  else
    cost = C * (mul + 3 * wf)
  end
  return cost, mul, cliffs > 0
end

local function cell_of(x, y) return floor(x / rails.CELL), floor(y / rails.CELL) end

local function job_box(job)
  local C = rails.CELL
  local m = job.margin
  local x0, x1 = min(job.ax, job.bx) - m, max(job.ax, job.bx) + m
  local y0, y1 = min(job.ay, job.by) - m, max(job.ay, job.by) + m
  return floor(x0 / C), floor(y0 / C), floor(x1 / C), floor(y1 / C)
end

-- Phase "score": every cell of the box not scored yet.
local function survey_score(job, s, budget)
  local cx0, cy0, cx1, cy1 = job_box(job)
  local w = cx1 - cx0 + 1
  local total = w * (cy1 - cy0 + 1)
  local n = 0
  while job.scan < total and n < budget do
    local cx = cx0 + job.scan % w
    local cy = cy0 + floor(job.scan / w)
    job.scan = job.scan + 1
    local k = ckey(cx, cy)
    if job.mul[k] == nil then
      local cost, mul, cliff = score_cell(job, s, cx, cy)
      job.cost[k] = cost or false
      job.mul[k] = mul
      if cliff then job.cliff[k] = true end
      n = n + 1
    end
  end
  job.cells_scored = (job.cells_scored or 0) + n
  if job.scan >= total then
    -- the depots' neighbourhoods are always passable (their own buildings and platforms are in them)
    for _, p in ipairs({{job.ax, job.ay}, {job.bx, job.by}}) do
      local pcx, pcy = cell_of(p[1], p[2])
      for dx = -2, 2 do
        for dy = -2, 2 do
          local k = ckey(pcx + dx, pcy + dy)
          if job.cost[k] == false then job.cost[k] = rails.CELL * 4 end
        end
      end
    end
    job.phase = "coarse"
    job.coarse = nil
  end
  return n
end

local NB = {{1, 0, 1}, {-1, 0, 1}, {0, 1, 1}, {0, -1, 1}, {1, 1, 1.4142}, {1, -1, 1.4142}, {-1, 1, 1.4142},
            {-1, -1, 1.4142}}

-- Phase "coarse": A* over cells from depot A's cell to depot B's.
local function survey_coarse(job, budget)
  local C = rails.CELL
  local cx0, cy0, cx1, cy1 = job_box(job)
  local scx, scy = cell_of(job.ax, job.ay)
  local gcx, gcy = cell_of(job.bx, job.by)
  local goal = ckey(gcx, gcy)
  local Q = job.coarse
  if not Q then
    Q = {hf = {}, hk = {}, g = {}, came = {}, closed = {}}
    job.coarse = Q
    local sk = ckey(scx, scy)
    Q.g[sk] = 0
    heap_push(Q.hf, Q.hk, 0, sk)
  end
  local n = 0
  while n < budget do
    if #Q.hk == 0 then
      -- no coarse route inside the box: widen it, or give up
      if job.margin < 1024 then
        job.margin = job.margin * 2
        job.scan = 0
        job.phase = "score"
        util.log("rails: survey #%d: no coarse route, box margin -> %d tiles", job.id, job.margin)
        return n
      end
      job.phase = "failed"
      job.reason = "no-route"
      return n
    end
    local k = heap_pop(Q.hf, Q.hk)
    if not Q.closed[k] then
      Q.closed[k] = true
      n = n + 1
      if k == goal then
        local path = {}
        local c = k
        while c do
          path[#path + 1] = c
          c = Q.came[c]
        end
        job.path_cells = path
        job.coarse = nil
        job.phase = "corridor"
        job.R = job.R or 1
        return n
      end
      local cx, cy = cdecode(k)
      local cc = job.cost[k] or C * 4
      for _, nb in ipairs(NB) do
        local nx, ny = cx + nb[1], cy + nb[2]
        if nx >= cx0 and nx <= cx1 and ny >= cy0 and ny <= cy1 then
          local nk = ckey(nx, ny)
          local nc = job.cost[nk]
          if nc and not Q.closed[nk] then
            local ng = Q.g[k] + (cc + nc) / 2 * nb[3]
            if not Q.g[nk] or ng < Q.g[nk] then
              Q.g[nk] = ng
              Q.came[nk] = k
              local hx, hy = (gcx - nx) * C, (gcy - ny) * C
              heap_push(Q.hf, Q.hk, ng + sqrt(hx * hx + hy * hy), nk)
            end
          end
        end
      end
    end
  end
  return n
end

-- Phase "corridor": cells within R of the coarse path, and the flow field (cost to go) over them.
local function survey_corridor(job)
  local C = rails.CELL
  local corridor = {}
  local R = job.R
  local function add(cx, cy, r)
    for dx = -r, r do
      for dy = -r, r do corridor[ckey(cx + dx, cy + dy)] = true end
    end
  end
  for _, k in ipairs(job.path_cells) do
    local cx, cy = cdecode(k)
    add(cx, cy, R)
  end
  for _, e in ipairs(job.starts) do add(floor(e.x / C), floor(e.y / C), 2) end
  for _, e in ipairs(job.goals) do add(floor(e.x / C), floor(e.y / C), 2) end
  job.corridor = corridor
  -- Dijkstra from the goal cells over the corridor's passable cells
  local dist, hf, hk = {}, {}, {}
  local goal_pos = {}
  for _, e in ipairs(job.goals) do
    local k = ckey(floor(e.x / C), floor(e.y / C))
    if not goal_pos[k] then
      goal_pos[k] = {e.x, e.y}
      dist[k] = 0
      heap_push(hf, hk, 0, k)
    end
  end
  local done = {}
  while #hk > 0 do
    local k = heap_pop(hf, hk)
    if not done[k] then
      done[k] = true
      local cx, cy = cdecode(k)
      local cc = job.cost[k] or C * 4
      for _, nb in ipairs(NB) do
        local nk = ckey(cx + nb[1], cy + nb[2])
        local nc = job.cost[nk]
        if corridor[nk] and nc and not done[nk] then
          local nd = dist[k] + (cc + nc) / 2 * nb[3]
          if not dist[nk] or nd < dist[nk] then
            dist[nk] = nd
            heap_push(hf, hk, nd, nk)
          end
        end
      end
    end
  end
  -- per cell: {x, y, cost to go from there}: the goal itself in goal cells, else the centre of the best neighbour
  local flow = {}
  for k in pairs(dist) do
    if goal_pos[k] then
      flow[k] = {goal_pos[k][1], goal_pos[k][2], 0}
    else
      local cx, cy = cdecode(k)
      local cc = job.cost[k] or C * 4
      local best, bv
      for _, nb in ipairs(NB) do
        local nk = ckey(cx + nb[1], cy + nb[2])
        local nd = dist[nk]
        if nd then
          local v = nd + (cc + (job.cost[nk] or cc)) / 2 * nb[3]
          if not bv or v < bv then best, bv = nk, v end
        end
      end
      if best then
        local bx, by = cdecode(best)
        flow[k] = goal_pos[best] and {goal_pos[best][1], goal_pos[best][2], 0}
          or {bx * C + C / 2, by * C + C / 2, dist[best]}
      end
    end
  end
  job.flow = flow
  -- fine search state
  local F = {hf = {}, hk = {}, g = {}, came = {}, closed = {}, pc = {}}
  job.fine = F
  job.goalset = {}
  for i, e in ipairs(job.goals) do job.goalset[nkey(e.x, e.y, e.d, e.l)] = i end
  for _, e in ipairs(job.starts) do
    local k = nkey(e.x, e.y, e.d, e.l)
    F.g[k] = 0
    heap_push(F.hf, F.hk, 0, k)
  end
  job.fine_expanded = 0
  job.phase = "fine"
  util.log("rails: survey #%d: coarse path %d cells, corridor radius %d = %d cells, flow over %d cells", job.id,
    #job.path_cells, R, table_size(corridor), table_size(flow))
end

local function heuristic(job, x, y, ck)
  local fl = job.flow[ck]
  if fl then
    local dx, dy = x - fl[1], y - fl[2]
    return sqrt(dx * dx + dy * dy) + fl[3]
  end
  local best
  for _, e in ipairs(job.goals) do
    local dx, dy = x - e.x, y - e.y
    local d = sqrt(dx * dx + dy * dy)
    if not best or d < best then best = d end
  end
  return (best or 0) * 1.5
end

-- Placement check of one planned piece: true, false, or a number (allowed at that extra cost: cliffs to blow up).
-- Phase 5 M3 integration (war2 notes open issue 4): a straight orthogonal piece whose only obstacles are walls and
-- gates of its own force crosses them (its walls turn into gates when the ghosts are laid: gate_walls).
local function wall_crossing(job, s, e, px, py)
  if e.name ~= "straight-rail" or e.dir % 4 ~= 0 then return false end
  local area = {{px - 1, py - 1}, {px + 1, py + 1}}
  local own = s.count_entities_filtered({area = area, type = WALL_TYPES, force = job.force})
  if own == 0 or s.count_entities_filtered({area = area, type = BLOCKER_TYPES}) > own then return false end
  if s.count_tiles_filtered({area = area, collision_mask = "water_tile", limit = 1}) > 0 then return false end
  return s.count_entities_filtered({area = area, name = RAIL_NAMES, limit = 1}) == 0
end

-- Economy 0.1.1 follow-up: rts-mountain (prototypes/world.lua) takes no rail, but neither the placement check of a
-- ghost nor the cliff rule saw it: mountains are rimmed by cliffs, and M2 803's line #12 was surveyed over a rim three
-- times (pieces 98 and 113 "will not revive" on rts-mountain tiles). A piece within MOUNTAIN_CLEARANCE of one is out.
rails.MOUNTAIN = "rts-mountain"
rails.MOUNTAIN_CLEARANCE = 2.5
local function on_mountain(s, px, py)
  if not prototypes.tile[rails.MOUNTAIN] then return false end
  local r = rails.MOUNTAIN_CLEARANCE
  return s.count_tiles_filtered({area = {{px - r, py - r}, {px + r, py + r}}, name = rails.MOUNTAIN, limit = 1}) > 0
end

local function check_piece(job, s, e, px, py, ck)
  if not e.elev and on_mountain(s, px, py) then return false end
  if e.elev then
    return s.can_place_entity({name = e.name, position = {px, py}, direction = e.dir, force = job.force,
                               build_check_type = SCRIPT})
  end
  if s.can_place_entity({name = e.name, position = {px, py}, direction = e.dir, force = job.force,
                         build_check_type = MANUAL_GHOST, forced = true}) then
    return true
  end
  if wall_crossing(job, s, e, px, py) then return rails.WALL_CROSS_COST end -- Phase 5 M3 integration
  if not job.cliff[ck] then return false end
  -- only cliffs (plus trees and rocks) in the way, no water and no buildings: the builder clears them
  local r = 3
  local area = {{px - r, py - r}, {px + r, py + r}}
  if s.count_entities_filtered({area = area, type = "cliff", limit = 1}) == 0 then return false end
  if s.count_tiles_filtered({area = area, collision_mask = "water_tile", limit = 1}) > 0 then return false end
  if s.count_entities_filtered({area = area, type = BLOCKER_TYPES, limit = 1}) > 0 then return false end
  if s.count_entities_filtered({area = area, name = RAIL_NAMES, limit = 1}) > 0 then return false end
  return 15
end

-- Phase "fine": A* over rail end states inside the corridor.
local function survey_fine(job, s, budget)
  local geo = GEO
  local F = job.fine
  local hf, hk, g, came, closed, pc = F.hf, F.hk, F.g, F.came, F.closed, F.pc
  local goalset, corridor, mul = job.goalset, job.corridor, job.mul
  local W = rails.WEIGHT
  local C = rails.CELL
  local bridges = job.bridges
  local n = 0
  while n < budget do
    if #hk == 0 or job.fine_expanded >= rails.MAX_EXPANSIONS then
      if job.R < rails.MAX_CORRIDOR then
        job.R = job.R + 1
        job.phase = "corridor"
        util.log("rails: survey #%d: fine search failed after %d expansions, corridor radius -> %d", job.id,
          job.fine_expanded, job.R)
      else
        job.phase = "failed"
        job.reason = "no-route"
      end
      return n
    end
    local k = heap_pop(hf, hk)
    if not closed[k] then
      closed[k] = true
      n = n + 1
      job.fine_expanded = job.fine_expanded + 1
      job.expanded = job.expanded + 1
      if goalset[k] then
        job.found = k
        job.phase = "extract"
        return n
      end
      local x, y, d, l = ndecode(k)
      local gk = g[k]
      local list = geo[d * 2 + l]
      if list then
        for ei = 1, #list do
          local e = list[ei]
          if bridges or not (e.elev or e.ramp) then
            local nx, ny = x + e.gdx, y + e.gdy
            local ck = ckey(floor(nx / C), floor(ny / C))
            if corridor[ck] then
              local k2 = nkey(nx, ny, e.gdir, e.glayer)
              if not closed[k2] then
                local px, py = x + e.dx, y + e.dy
                local key = ((floor(px * 2 + 0.5) + OFF) * SPAN + (floor(py * 2 + 0.5) + OFF)) * 256 + e.ni * 16 + e.dir
                local ok = pc[key]
                if ok == nil then
                  ok = check_piece(job, s, e, px, py, ck)
                  pc[key] = ok
                  job.checks = job.checks + 1
                end
                if ok then
                  local ng = gk + e.cost * (mul[ck] or 1) + (ok == true and 0 or ok)
                  local old = g[k2]
                  if not old or ng < old then
                    g[k2] = ng
                    came[k2] = k * 64 + ei
                    heap_push(hf, hk, ng + W * heuristic(job, nx, ny, ck), k2)
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return n
end

-- Phase 5 M3 integration: a detour survey's path (pieces job.detour.lo + 1 .. hi - 1 of the line replaced by it; see
-- start_detour) spliced into the line: kept pieces, supports and signals stay, the bill and the piece index follow.
local function apply_detour(job, line, path, supports, start_k)
  local old = line.pieces
  local lo, hi = job.detour.lo, job.detour.hi
  local idx = index_of(job.surface)
  for i = lo + 1, hi - 1 do
    local p = old[i]
    local key = pkey(p.name, p.x, p.y, p.d)
    local v = idx[key]
    if v and floor(v / 100000) == line.id then idx[key] = nil end
  end
  local pieces = {}
  for i = 1, lo do pieces[#pieces + 1] = old[i] end
  for _, p in ipairs(path) do pieces[#pieces + 1] = p end
  for i = hi, #old do pieces[#pieces + 1] = old[i] end
  local shift = #path - (hi - 1 - lo)
  local sups = {}
  for _, sp in ipairs(line.supports or {}) do
    if sp.before <= lo then
      sups[#sups + 1] = sp
    elseif sp.before >= hi then
      sp.before = sp.before + shift
      sups[#sups + 1] = sp
    end
  end
  for _, sp in ipairs(supports) do
    sp.before = sp.before + lo
    sups[#sups + 1] = sp
  end
  if lo == 0 then
    local sx, sy = ndecode(start_k)
    for i, e in ipairs(job.starts) do
      if abs(e.x - sx) < 0.1 and abs(e.y - sy) < 0.1 then line.a_end = i end
    end
  end
  if hi > #old then line.b_end = job.goalset[job.found] end
  local track, length, signals, missing = 0, 0, 0, 0
  for _, p in ipairs(pieces) do
    track = track + p.rails
    length = length + p.len
    if p.sig then signals = signals + 2 end
    if not (p.e and p.e.valid) then missing = missing + 1 end
  end
  line.pieces = pieces
  line.bbox = nil
  line.supports = sups
  line.bill = {rails = track + #sups * CFG.support_rails + signals * CFG.signal_rails, track = track,
               pieces = #pieces, supports = #sups, ramps = line.bill and line.bill.ramps or 0, signals = signals}
  line.rails = line.bill.rails
  line.length = length
  line.missing = missing
  for i, p in ipairs(pieces) do idx[pkey(p.name, p.x, p.y, p.d)] = line.id * 100000 + i end
  -- a crew still out looks for its frontier again (piece numbers moved; it laid on past the detour, then stood still)
  for _, rec in pairs(rstate().trains) do
    if rec.line == line.id then rec.scan, rec.target = nil, nil end
  end
  job.phase = "ghosts"
  job.ghost_i, job.ghost_end = lo + 1, lo + #path
  util.log("rails: detour survey #%d of line #%d done in %.1f s: %d pieces in place of %d (pieces %d..%d), line now %d "
    .. "pieces, %d missing; %d fine expansions, %d checks", job.id, line.id, (game.tick - job.started) / 60, #path,
    hi - 1 - lo, lo + 1, hi - 1, #pieces, missing, job.expanded, job.checks)
end

-- Phase "extract": the piece list, supports, signals and the bill; the line record gets them.
local function survey_extract(job)
  local R = rstate()
  local line = R.lines[job.line]
  local F = job.fine
  local path = {}
  local k = job.found
  while F.came[k] do
    local v = F.came[k]
    local ei = v % 64
    local pk = (v - ei) / 64
    local px, py, pd, pl = ndecode(pk)
    local e = GEO[pd * 2 + pl][ei]
    table.insert(path, 1, {name = e.name, x = px + e.dx, y = py + e.dy, d = e.dir, l = e.glayer, rails = e.rails,
                           len = e.len, elev = e.elev, ramp = e.ramp, sx = px, sy = py, sd = pd, sl = pl,
                           gx = px + e.gdx, gy = py + e.gdy, gd = e.gdir})
    k = pk
  end
  -- which platform ends the route uses (a detour: apply_detour)
  if not job.detour then
    local sx, sy = ndecode(k)
    for i, e in ipairs(job.starts) do
      if abs(e.x - sx) < 0.1 and abs(e.y - sy) < 0.1 then line.a_end = i end
    end
    line.b_end = job.goalset[job.found]
  end
  -- supports on elevated rail ends (probe P2)
  local supports, since = {}, nil
  local ramps = 0
  for i, p in ipairs(path) do
    if p.ramp then
      ramps = ramps + 1
      since = (p.l == 1) and rails.RAMP_SLACK or nil
    elseif p.elev then
      since = since or rails.RAMP_SLACK
      if since + p.len > rails.SUPPORT_SPACING then
        supports[#supports + 1] = {x = p.sx, y = p.sy, d = p.sd, before = i}
        since = 0
      end
      since = since + p.len
    else
      since = nil
    end
  end
  -- signal pairs at rail ends of ground track: both station entries and every signal_spacing tiles
  local acc, signals = 0, 0
  for i, p in ipairs(path) do
    acc = acc + p.len
    local nxt = path[i + 1]
    if nxt and not (p.elev or p.ramp or nxt.elev or nxt.ramp) then
      if i == 1 or i == #path - 1 or acc >= CFG.signal_spacing then
        p.sig = true
        acc = 0
        signals = signals + 2
      end
    end
  end
  if job.detour then return apply_detour(job, line, path, supports, k) end
  local track, length = 0, 0
  for _, p in ipairs(path) do
    track = track + p.rails
    length = length + p.len
  end
  line.pieces = path
  line.bbox = nil -- covers_planned's box of the pieces
  line.supports = supports
  line.signals = {}
  line.bill = {rails = track + #supports * CFG.support_rails + signals * CFG.signal_rails, track = track,
               pieces = #path, supports = #supports, ramps = ramps, signals = signals}
  line.rails = line.bill.rails
  line.length = length
  line.missing = #path
  line.used, line.loaded, line.returned, line.robot = 0, 0, 0, 0
  line.survey = {ticks = game.tick - job.started, expanded = job.expanded, checks = job.checks,
                 cells = job.cells_scored or 0, corridor = job.R}
  local idx = index_of(job.surface)
  for i, p in ipairs(path) do idx[pkey(p.name, p.x, p.y, p.d)] = line.id * 100000 + i end
  job.phase = "ghosts"
  job.ghost_i = 1
  util.log("rails: survey #%d done in %.1f s (%d ticks of work): %d pieces (%d ramps), %.0f tiles of track for %.0f "
    .. "straight, %d supports, %d signals, bill %d rails; %d fine expansions, %d checks, %d cells, corridor %d",
    job.id, (game.tick - job.started) / 60, job.ticks, #path, ramps, length,
    util.distance({job.ax, job.ay}, {job.bx, job.by}), #supports, signals, line.bill.rails, job.expanded, job.checks,
    job.cells_scored or 0, job.R)
end

-- Phase 5 M3 integration: own walls under a straight orthogonal piece become gates across the track (vanilla gates
-- stand on straight rails: a horizontal track takes a gate facing north, a vertical one east; belts.lua's rule).
rails.GATE = "rts-gate"
local function gate_walls(s, force_name, p)
  if p.name ~= "straight-rail" or p.d % 4 ~= 0 or not prototypes.entity[rails.GATE] then return 0 end
  local walls = s.find_entities_filtered({area = {{p.x - 1, p.y - 1}, {p.x + 1, p.y + 1}}, type = "wall",
                                          force = force_name})
  local gd = (p.d == D.east or p.d == D.west) and D.north or D.east
  local n = 0
  for _, w in ipairs(walls) do
    local pos, share = w.position, w.health / w.max_health
    w.destroy({raise_destroy = true})
    local g = s.create_entity({name = rails.GATE, position = pos, direction = gd, force = force_name, raise_built = true})
    if g then
      g.health = g.max_health * share
      n = n + 1
    end
  end
  return n
end

-- Phase "ghosts": entity-ghosts of the pieces and supports.
local function survey_ghosts(job, s, budget)
  local R = rstate()
  local line = R.lines[job.line]
  local n = 0
  local pieces = line.pieces
  local last = job.ghost_end or #pieces -- a detour lays ghosts of its own pieces only
  while job.ghost_i <= last and n < budget do
    local p = pieces[job.ghost_i]
    job.ghost_i = job.ghost_i + 1
    local gated = gate_walls(s, job.force, p) -- Phase 5 M3 integration
    if gated > 0 then util.log("rails: survey #%d: %d wall(s) at (%.0f, %.0f) turned into gates", job.id, gated, p.x, p.y) end
    p.g = s.create_entity({name = "entity-ghost", inner_name = p.name, position = {p.x, p.y}, direction = p.d,
                           force = job.force})
    n = n + 1
  end
  if job.ghost_i > last then
    for _, sp in ipairs(line.supports) do
      if not ((sp.e and sp.e.valid) or (sp.g and sp.g.valid)) then
        sp.g = s.create_entity({name = "entity-ghost", inner_name = rails.SUPPORT, position = {sp.x, sp.y},
                                direction = sp.d, force = job.force})
      end
    end
    job.phase = "done"
  end
  return n
end

local function line_position(line)
  local p = line.pieces and line.pieces[floor(#line.pieces / 2) + 1]
  if p then return {x = p.x, y = p.y} end
  local d = rails.depot(line.b)
  return d and d.entity.position or {x = 0, y = 0}
end

local function finish_job(job)
  local R = rstate()
  local line = R.lines[job.line]
  R.jobs[job.id] = nil
  if not line then return end
  if job.detour then -- Phase 5 M3 integration: the line goes on with the detour, or as planned when none was found
    line.detours = (line.detours or 0) + 1
    line.state = job.detour.state or "building"
    if job.phase == "failed" then
      local bp = line.pieces[job.detour.blocked]
      if bp then bp.fails = 0 end -- blocked again -> the next, wider detour after the backoff
      line.blocked, line.blocked_at = nil, nil
      util.log("rails: detour survey #%d of line #%d failed (%s) after %.1f s: pieces %d..%d are laid as planned",
        job.id, line.id, tostring(job.reason), (game.tick - job.started) / 60, job.detour.lo + 1, job.detour.hi - 1)
    else
      line.blocked, line.blocked_at = nil, nil
      line.surveyed = game.tick
    end
    return
  end
  if job.phase == "failed" then
    line.state = "failed"
    line.reason = job.reason
    util.log("rails: survey #%d failed (%s) after %.1f s, %d expansions, %d checks", job.id, tostring(job.reason),
      (game.tick - job.started) / 60, job.expanded, job.checks)
    local d = rails.depot(line.a)
    alert(line.force, "line-failed", d and d.entity.position or {0, 0}, "rts.alert-line-failed")
    return
  end
  line.state = "building"
  line.surveyed = game.tick
end

local function survey_tick(job)
  local s = game.surfaces[job.surface]
  if not s or not geometry() then
    job.phase = "failed"
    job.reason = "no-surface"
    finish_job(job)
    return
  end
  job.ticks = job.ticks + 1
  local phase = job.phase
  if phase == "score" then
    survey_score(job, s, rails.SURVEY_CELLS)
  elseif phase == "coarse" then
    survey_coarse(job, rails.SURVEY_COARSE)
  elseif phase == "corridor" then
    survey_corridor(job)
  elseif phase == "fine" then
    survey_fine(job, s, rails.SURVEY_EXPANSIONS)
  elseif phase == "extract" then
    survey_extract(job)
  elseif phase == "ghosts" then
    survey_ghosts(job, s, rails.SURVEY_GHOSTS)
  end
  if job.phase == "done" or job.phase == "failed" then finish_job(job) end
end

-- Phase 5 M3 perf: one scheduler step of survey `id` (sjob.state.job) with `units` work units (rails.SURVEY_UNITS).
local SU = rails.SURVEY_UNITS
local function survey_sched_step(sjob, units)
  local R = storage.rails
  local job = R and R.jobs[sjob.state.job]
  if not job then return 0, true end
  local s = game.surfaces[job.surface]
  if not s or not geometry() then
    job.phase = "failed"
    job.reason = "no-surface"
    finish_job(job)
    return 1, true
  end
  job.ticks = job.ticks + 1
  -- phases run on in the same step until the units are spent (a phase change or an estimate that undershoots would
  -- otherwise end the step early, and the scheduler only gives spare units to a job that spent all it was offered)
  local total = 0
  for _ = 1, 16 do
    local left = units - total
    if left < SU.cell then break end
    local phase = job.phase
    local used = 1
    if phase == "score" then
      used = max(1, survey_score(job, s, max(1, floor(left / SU.cell))) * SU.cell)
    elseif phase == "coarse" then
      used = max(1, survey_coarse(job, max(1, floor(left / SU.coarse))) * SU.coarse)
    elseif phase == "corridor" then
      survey_corridor(job)
      used = max(1, table_size(job.flow or {}) * SU.corridor)
    elseif phase == "fine" then
      -- expansions this step from the checks per expansion so far (each expansion tries up to ~16 extensions, most of
      -- them cached once the search is under way)
      local per = SU.fine + SU.check * (job.expanded > 0 and job.checks / job.expanded or 4)
      local c0 = job.checks
      local n = survey_fine(job, s, max(1, floor(left / per)))
      used = max(1, n * SU.fine + (job.checks - c0) * SU.check)
    elseif phase == "extract" then
      survey_extract(job)
      local line = R.lines[job.line]
      used = max(1, (line and line.pieces and #line.pieces or 1) * SU.extract)
    elseif phase == "ghosts" then
      used = max(1, survey_ghosts(job, s, max(1, floor(left / SU.ghost))) * SU.ghost)
    end
    total = total + used
    if job.phase == "done" or job.phase == "failed" then
      finish_job(job)
      return total, true
    end
  end
  return max(total, units), false
end
sched.register("rails_survey", survey_sched_step, function(sjob, status)
  -- a step that raised leaves the line surveying: fail it so the owner (player panel, AI rail program) moves on
  -- (a cancel only comes from the match teardown, which clears the rails state itself)
  local R = storage.rails
  local job = R and R.jobs[sjob.state.job]
  if job and status == "failed" then
    job.phase = "failed"
    job.reason = job.reason or ("survey " .. status)
    finish_job(job)
  end
end)

--- Plan a line between two own depots. Returns the line id (= survey job id), or nil and a reason.
function rails.plan_line(force, depot_a, depot_b)
  local force_name = type(force) == "string" and force or force.name
  local R = rstate()
  local A, B = rails.depot(depot_a), rails.depot(depot_b)
  local why
  if not rails.nation() then why = "not-nation"
  elseif not geometry() then why = "no-geometry"
  elseif not (A and B) or depot_a == depot_b then why = "no-depot"
  elseif A.force ~= force_name or B.force ~= force_name then why = "foreign-depot"
  elseif A.surface ~= B.surface then why = "other-surface"
  elseif not (A.platform and B.platform) then why = "no-platform"
  elseif (A.line and R.lines[A.line]) or (B.line and R.lines[B.line]) then why = "depot-busy" end
  if why then
    util.log("rails: plan_line %s #%s -> #%s refused: %s", force_name, tostring(depot_a), tostring(depot_b), why)
    return nil, why
  end
  local id = R.next_id
  R.next_id = id + 1
  local line = {id = id, force = force_name, a = depot_a, b = depot_b, state = "surveying", created = game.tick,
                surface = A.surface, rails = 0, length = 0, missing = 0}
  R.lines[id] = line
  A.line, B.line = id, id
  local pa, pb = A.entity.position, B.entity.position
  local job = {id = id, line = id, force = force_name, surface = A.surface, bridges = rails.bridges(force_name),
               ax = pa.x, ay = pa.y, bx = pb.x, by = pb.y, phase = "score", scan = 0, cost = {}, mul = {}, cliff = {},
               margin = max(96, floor(util.distance(pa, pb) / 4)), started = game.tick, ticks = 0, expanded = 0,
               checks = 0, starts = {}, goals = {}}
  for _, e in ipairs(A.platform.ends) do job.starts[#job.starts + 1] = {x = e.x, y = e.y, d = e.d, l = e.l} end
  for _, e in ipairs(B.platform.ends) do job.goals[#job.goals + 1] = {x = e.x, y = e.y, d = (e.d + 8) % 16, l = e.l} end
  R.jobs[id] = job
  -- Phase 5 M3 perf: nil outside a Nation match (and with rails.SURVEY_SCHED off: a test copy's comparison with M2)
  job.sched = rails.SURVEY_SCHED and sched.submit(force_name, "rails_survey", {job = id}) or nil
  util.log("rails: line #%d of %s: survey %s (#%d) -> %s (#%d), %.0f tiles, bridges %s%s", id, force_name,
    util.pos_str(pa), depot_a, util.pos_str(pb), depot_b, util.distance(pa, pb), tostring(job.bridges),
    job.sched and string.format(", scheduler job %d", job.sched) or "")
  return id
end

-- Phase 5 M3 integration: a line blocked at piece line.blocked for rails.DETOUR_AFTER (doubling per attempt) is surveyed
-- again around it: pieces within DETOUR_SPAN[attempt] of it on both sides are taken up (laid rails go back to depot A's
-- network, their signals and supports with them) and a survey runs from the end of the last kept piece (depot A's
-- platform when none is kept) to the start of the first kept one after it (depot B's platform). The crews go home
-- meanwhile; a failed detour leaves the plan as it was and the crews lay it again.
local function start_detour(line)
  local R = rstate()
  local i, n = line.blocked, #line.pieces
  local attempt = (line.detours or 0) + 1
  local span = rails.DETOUR_SPAN[attempt]
  local A, B = rails.depot(line.a), rails.depot(line.b)
  local s = game.surfaces[line.surface]
  if not (i and span and s and A and B and A.platform and B.platform and A.platform.ends and B.platform.ends) then
    return false
  end
  local lo, hi = max(0, i - span), min(n + 1, i + span)
  local starts, goals = {}, {}
  if lo == 0 then
    for _, e in ipairs(A.platform.ends) do starts[#starts + 1] = {x = e.x, y = e.y, d = e.d, l = e.l} end
  else
    local p = line.pieces[lo]
    starts[1] = {x = p.gx, y = p.gy, d = p.gd, l = p.l}
  end
  if hi > n then
    for _, e in ipairs(B.platform.ends) do goals[#goals + 1] = {x = e.x, y = e.y, d = (e.d + 8) % 16, l = e.l} end
  else
    local p = line.pieces[hi]
    goals[1] = {x = p.sx, y = p.sy, d = p.sd, l = p.sl}
  end
  -- take up the pieces in between
  local refund, taken = 0, 0
  for k = lo + 1, hi - 1 do
    local p = line.pieces[k]
    if p.e and p.e.valid then
      if p.sig and line.signals then
        -- its signal pair stands at its far end
        local keep = {}
        for _, sig in ipairs(line.signals) do
          if sig.valid then
            local dx, dy = sig.position.x - p.gx, sig.position.y - p.gy
            if dx * dx + dy * dy <= 9 then sig.destroy() else keep[#keep + 1] = sig end
          end
        end
        line.signals = keep
      end
      p.e.destroy()
      refund = refund + p.rails
      taken = taken + 1
      line.missing = line.missing + 1
    end
    if p.g and p.g.valid then p.g.destroy() end
    p.e, p.g = nil, nil
  end
  for _, sp in ipairs(line.supports or {}) do
    if sp.before > lo and sp.before < hi then
      if sp.e and sp.e.valid then
        sp.e.destroy()
        refund = refund + CFG.support_rails
      end
      if sp.g and sp.g.valid then sp.g.destroy() end
      sp.e, sp.g = nil, nil
    end
  end
  local net = logistics.hub_network(line.a)
  if refund > 0 and net then net.insert({name = rails.RAIL, count = refund}) end
  line.used = max(0, (line.used or 0) - refund)
  line.returned = (line.returned or 0) + refund
  local prev = line.state
  line.state = "surveying"
  local id = R.next_id
  R.next_id = id + 1
  local sa, ga = starts[1], goals[1]
  local job = {id = id, line = line.id, force = line.force, surface = line.surface, bridges = rails.bridges(line.force),
               ax = sa.x, ay = sa.y, bx = ga.x, by = ga.y, phase = "score", scan = 0, cost = {}, mul = {}, cliff = {},
               margin = 64, started = game.tick, ticks = 0, expanded = 0, checks = 0, starts = starts, goals = goals,
               detour = {lo = lo, hi = hi, blocked = i, state = prev, attempt = attempt}}
  R.jobs[id] = job
  job.sched = rails.SURVEY_SCHED and sched.submit(line.force, "rails_survey", {job = id}) or nil
  util.log("rails: line #%d blocked at piece %d for %.0f s: detour survey #%d over pieces %d..%d (attempt %d, %d laid "
    .. "pieces taken up, %d rails back)", line.id, i, (game.tick - (line.blocked_at or game.tick)) / 60, id, lo + 1, hi - 1,
    attempt, taken, refund)
  return true
end

---------------------------------------------------------------------------
-- Trains: records, creation, routes
---------------------------------------------------------------------------
local function train_of(rec)
  local loco = rec.loco
  if loco and loco.valid then return loco.train end
  for _, e in ipairs(rec.stock or {}) do
    if e.valid and e.train then return e.train end
  end
  return nil
end

--- The train record of a LuaTrain, a rolling stock entity or a train id, or nil.
function rails.train_record(x)
  local R = storage.rails
  if not (R and x) then return nil end
  local id
  if type(x) == "number" then id = x
  elseif x.object_name == "LuaTrain" then id = x.id
  elseif x.valid and x.train then id = x.train.id end
  return id and R.trains[id] or nil
end

local function cargo_of(train)
  local out = {}
  for _, item in pairs(train.get_contents()) do out[item.name] = (out[item.name] or 0) + item.count end
  return out
end
rails.cargo_of = cargo_of

local function wagons_of(train, name)
  local list = {}
  for _, w in ipairs(train.cargo_wagons) do
    if not name or w.name == name then list[#list + 1] = w end
  end
  return list
end
rails.wagons_of = wagons_of -- 0.1.2 (#31): scripts/railroutes.lua

local function kit_list(kind, n, armoured) -- Phase 5 M2 war: n troop wagons
  if kind == "construction" then return {{rails.LOCO_KIT, 2}, {rails.CWAGON_KIT, 1}} end
  -- Phase 5 M3 war2: armoured locomotives (and armoured troop wagons); the artillery train's one artillery wagon
  local loco = armoured and rails.ALOCO_KIT or rails.LOCO_KIT
  if kind == "artillery" then return {{loco, 2}, {rails.ARTY_KIT, 1}} end
  if kind == "troop" then -- Phase 5 M2 war
    return {{loco, 2}, {armoured and rails.AWAGON_KIT or rails.TWAGON_KIT, n or 1}}
  end
  return {{loco, 2}, {rails.WAGON_KIT, CFG.cargo_wagons}}
end

--- Kits a train of `kind` needs: {{item, n}, ...}.
rails.kit_list = kit_list

local function refuel(train, net)
  if not (net and net.valid) then return 0 end
  local put = 0
  for _, group in pairs({train.locomotives.front_movers, train.locomotives.back_movers}) do
    for _, loco in ipairs(group) do
      local inv = loco.get_fuel_inventory()
      if inv then
        local want = CFG.fuel_target - inv.get_item_count(rails.FUEL)
        if want > 0 then put = put + logistics.transfer(net, inv, rails.FUEL, want) end
      end
    end
  end
  return put
end
rails.refuel = refuel -- 0.1.2 (#31): scripts/railroutes.lua

-- Phase 5 M2 QA round 1 (step 20): the train layout, the own units that step off the platform track, and why a train
-- cannot be deployed (rails.deploy_check, the depot panel's reason line). In the QA run a division waiting by the
-- platform stood across its track: a walker's legs reach several tiles from its body and keep rolling stock from being
-- placed, so Deploy refused "the train does not fit on the platform" with a 40-tile platform and a 28-tile train.
local UNIT_TYPES = {"unit", "spider-unit", "spider-vehicle"}
local LEGGED = {["spider-unit"] = true, ["spider-vehicle"] = true}
local STEP_CLEAR = 2  -- tiles between the train's box and the legs of a unit that stepped aside
local LEG_REACH = 4   -- assumed when the legs cannot be read

local function kits_for(kind, net, armoured) -- Phase 5 M3 war2: armoured stock
  local nw = nil
  if kind == "troop" then -- Phase 5 M2 war
    nw = math.max(1, math.min(net.get_item_count(armoured and rails.AWAGON_KIT or rails.TWAGON_KIT), -- Phase 5 M3 war2
      balance.nation.war.troop_wagon.max_wagons))
  end
  return kit_list(kind, nw, armoured)
end

-- Phase 5 M3 war2: the kinds create_train knows ("artillery": 2 locomotives + 1 artillery wagon) and its armoured
-- option (never for a construction train)
local function train_kind(kind)
  return (kind == "construction" or kind == "troop" or kind == "artillery") and kind or "cargo"
end
local function armoured_of(kind, opts) return opts ~= nil and opts.armoured == true and kind ~= "construction" end

-- Phase 5 M2 integration: a construction train refuels nowhere but from its wagon, so it leaves only with a full
-- load for both locomotives (2 x fuel_target; an AI crew left with 2 coal and stood at piece 36 for half an hour)
local function min_fuel(kind) return kind == "construction" and 2 * CFG.fuel_target or 2 end

-- Carriage names front to back and their slots on the platform: the front locomotive at the end the line joins (or
-- the second end), facing out; the last locomotive faces the other way.
local function train_slots(d, kind, kits, armoured) -- Phase 5 M3 war2: armoured stock, the artillery wagon
  local R = rstate()
  local p = d.platform
  local line = d.line and R.lines[d.line]
  local conn = 2
  if line then conn = (line.a == d.un) and (line.a_end or 2) or (line.b_end or 2) end
  local e = p.ends[conn] or p.ends[2]
  local ox, oy = 0, 0
  if e.d == D.east then ox = 1 elseif e.d == D.west then ox = -1 elseif e.d == D.south then oy = 1 else oy = -1 end
  local loco = armoured and rails.ALOCO or rails.LOCO -- Phase 5 M3 war2: armoured stock, the artillery wagon
  local names = {loco}
  for _ = 1, kits[2][2] do -- Phase 5 M2 war: troop wagons
    names[#names + 1] = kind == "construction" and rails.CWAGON or (kind == "troop" and (armoured and rails.AWAGON
      or rails.TWAGON) or (kind == "artillery" and rails.ARTY or rails.WAGON))
  end
  names[#names + 1] = loco
  local slots = {}
  for i, name in ipairs(names) do
    local back = 4 + (i - 1) * rails.CARRIAGE
    slots[i] = {name = name, x = e.x - ox * back, y = e.y - oy * back,
                dir = (i == #names) and ((e.d + 8) % 16) or e.d}
  end
  return slots
end

-- The box a carriage (or the whole train) covers on the platform track.
local function track_box(p, lo, hi)
  if p.axis == "x" then return {{lo, p.track - 1.5}, {hi, p.track + 1.5}} end
  return {{p.track - 1.5, lo}, {p.track + 1.5, hi}}
end

local function slot_box(p, slot)
  local a = p.axis == "x" and slot.x or slot.y
  return track_box(p, a - rails.CARRIAGE / 2, a + rails.CARRIAGE / 2)
end

local function in_box(pos, box)
  return pos.x >= box[1][1] and pos.x <= box[2][1] and pos.y >= box[1][2] and pos.y <= box[2][2]
end

-- Units whose body or legs stand in `box`: own = true those of force_name, own = false everybody else's.
-- {{entity, reach = how far its legs stand from its body}}.
local function units_in(surface, force_name, box, own)
  local big = {{box[1][1] - 12, box[1][2] - 12}, {box[2][1] + 12, box[2][2] + 12}}
  local list = {}
  for _, e in ipairs(surface.find_entities_filtered({area = big, type = UNIT_TYPES})) do
    if e.valid and (e.force.name == force_name) == own then
      local hit, reach = in_box(e.position, box), 0
      if LEGGED[e.type] then
        local ok, legs = pcall(e.get_spider_legs)
        if ok and legs then
          for _, leg in ipairs(legs) do
            if leg.valid then
              if in_box(leg.position, box) then hit = true end
              reach = max(reach, util.distance(leg.position, e.position))
            end
          end
        else
          reach = LEG_REACH
          local wide = {{box[1][1] - reach, box[1][2] - reach}, {box[2][1] + reach, box[2][2] + reach}}
          hit = hit or in_box(e.position, wide)
        end
      end
      if hit then list[#list + 1] = {entity = e, reach = reach} end
    end
  end
  return list
end

-- Own units on the platform track step off it, to the side away from the depot (where troops board), far enough
-- that their legs clear the train. Returns how many moved.
local function step_aside(d, box)
  local p = d.platform
  local surface = d.entity.surface
  local side = p.side or 1
  local n = 0
  for _, u in ipairs(units_in(surface, d.force, box, true)) do
    local e = u.entity
    local off = 1.5 + u.reach + STEP_CLEAR
    local along = p.axis == "x" and e.position.x or e.position.y
    local dest = p.axis == "x" and {x = along, y = p.track + side * off} or {x = p.track + side * off, y = along}
    local pos = surface.find_non_colliding_position(e.name, dest, 6, 0.5) or dest
    local across = p.axis == "x" and pos.y or pos.x
    if (across - p.track) * side < off - 0.01 then pos = dest end -- the search may come back towards the track
    if e.teleport(pos) then n = n + 1 end
  end
  return n
end

-- True when every platform rail under the train's slots stands (a carriage may fit beside a gap, the train would not
-- join into one).
local function track_whole(d, slots)
  local p = d.platform
  local a1 = p.axis == "x" and slots[1].x or slots[1].y
  local a2 = p.axis == "x" and slots[#slots].x or slots[#slots].y
  local box = track_box(p, min(a1, a2) - rails.CARRIAGE / 2, max(a1, a2) + rails.CARRIAGE / 2)
  local want = 0
  for _, r in ipairs(p.spec and p.spec.rails or {}) do
    if in_box(r, box) then want = want + 1 end
  end
  local have = 0
  for _, r in ipairs(d.entity.surface.find_entities_filtered({area = box, name = "straight-rail"})) do
    if in_box(r.position, box) then have = have + 1 end
  end
  return have >= want
end

-- Why a carriage cannot stand in its slot (nil when it can, or when only own units are in the way: they step aside).
local function slot_problem(d, slot)
  local surface = d.entity.surface
  if surface.can_place_entity({name = slot.name, position = {slot.x, slot.y}, direction = slot.dir, force = d.force})
  then
    return nil
  end
  local box = slot_box(d.platform, slot)
  if not track_whole(d, {slot}) then return "no-track" end
  if #units_in(surface, d.force, box, false) > 0 then return "enemy-on-track" end
  if #units_in(surface, d.force, box, true) > 0 then return nil end
  return "no-room"
end

--- Phase 5 M2 QA round 1: why a train of `kind` cannot be deployed at the depot now, or nil when it can (own units on
--- the platform track do not count: they step aside). Reasons as rails.create_train's, plus "no-track" (a platform
--- rail is gone) and "enemy-on-track". Phase 5 M3 war2: kind "artillery", opts.armoured as create_train's.
function rails.deploy_check(depot_un, kind, opts)
  kind = train_kind(kind) -- Phase 5 M3 war2
  local armoured = armoured_of(kind, opts) -- Phase 5 M3 war2
  local d = rails.depot(depot_un)
  if not d then return "no-depot" end
  if not d.platform then return "no-platform" end
  if not platform_free(d) then return "busy" end
  local net = logistics.hub_network(depot_un)
  if not net then return "no-network" end
  local kits = kits_for(kind, net, armoured)
  for _, k in ipairs(kits) do
    if net.get_item_count(k[1]) < k[2] then return "no-kits" end
  end
  if net.get_item_count(rails.FUEL) < min_fuel(kind) then return "no-fuel" end
  local slots = train_slots(d, kind, kits, armoured)
  if not track_whole(d, slots) then return "no-track" end
  for _, slot in ipairs(slots) do
    local why = slot_problem(d, slot)
    if why then return why end
  end
  return nil
end

--- Spawn a train of `kind` ("cargo" | "construction") on a depot platform from kits in the depot's network.
--- Returns the LuaTrain, or nil and a reason ("no-depot", "no-platform", "busy", "no-kits", "no-fuel", "no-room",
--- "no-track", "enemy-on-track"). Own units on the train's stretch of the platform track step off it.
--- Phase 5 M3 war2: kind "artillery" (2 locomotives + 1 artillery wagon); opts.armoured: armoured locomotives (and
--- armoured troop wagons for "troop"), never for a construction train.
function rails.create_train(depot_un, kind, opts)
  -- Phase 5 M2 war: "troop" (2 locomotive kits + as many troop wagon kits as the network holds, at most max_wagons)
  kind = train_kind(kind) -- Phase 5 M3 war2
  local armoured = armoured_of(kind, opts) -- Phase 5 M3 war2
  local d = rails.depot(depot_un)
  if not d then return nil, "no-depot" end
  if not d.platform then return nil, "no-platform" end
  if not platform_free(d) then return nil, "busy" end
  local net = logistics.hub_network(depot_un)
  if not net then return nil, "no-network" end
  local kits = kits_for(kind, net, armoured)
  for _, k in ipairs(kits) do
    if net.get_item_count(k[1]) < k[2] then return nil, "no-kits" end
  end
  -- Phase 5 M1 integration: a train without coal never moves (an AI crew stood on its platform with 0 coal).
  if net.get_item_count(rails.FUEL) < min_fuel(kind) then return nil, "no-fuel" end
  local surface, force_name = d.entity.surface, d.force
  local slots = train_slots(d, kind, kits, armoured)
  if not track_whole(d, slots) then return nil, "no-track" end
  local names = {}
  for i, slot in ipairs(slots) do names[i] = slot.name end
  -- Phase 5 M2 QA round 1: own units on the train's stretch of track step off it first (the engine snaps rolling stock
  -- up to 2 tiles along the rail, and a carriage placed past a walker's legs did not couple with the next one: a GUI
  -- check had "did not join into one train"), and again for a carriage that still cannot be placed
  local p = d.platform
  local a1 = p.axis == "x" and slots[1].x or slots[1].y
  local a2 = p.axis == "x" and slots[#slots].x or slots[#slots].y
  local margin = rails.CARRIAGE / 2 + 3
  local made, moved = {}, step_aside(d, track_box(p, min(a1, a2) - margin, max(a1, a2) + margin))
  for i, slot in ipairs(slots) do
    local spec = {name = slot.name, position = {slot.x, slot.y}, direction = slot.dir, force = force_name}
    local ent = surface.create_entity(spec)
    if not ent then
      local n = step_aside(d, slot_box(p, slot))
      if n > 0 then
        moved = moved + n
        ent = surface.create_entity(spec)
      end
    end
    if not ent then
      for _, m in ipairs(made) do m.destroy() end
      local why = slot_problem(d, slot) or "no-room"
      util.log("rails: depot #%d: %s %d of %d could not be placed (%s)", depot_un, slot.name, i, #slots, why)
      return nil, why
    end
    made[#made + 1] = ent
  end
  if moved > 0 then
    util.log("rails: depot #%d: %d own unit(s) stepped off the platform track for a %s train", depot_un, moved, kind)
  end
  local train = made[1].train
  if not (train and #train.carriages == #names) then
    local at = {}
    for _, m in ipairs(made) do at[#at + 1] = util.pos_str(m.position) end
    for _, m in ipairs(made) do if m.valid then m.destroy() end end
    util.log("rails: depot #%d: rolling stock did not join into one train (%s)", depot_un, table.concat(at, " "))
    return nil, "no-room"
  end
  for _, k in ipairs(kits) do net.remove_item({name = k[1], count = k[2]}) end
  local color = force_color(force_name)
  for _, ent in ipairs(made) do
    if color then ent.color = color end
    buildings.register(ent)
  end
  -- starter fuel from the network (Phase 5 M2 integration: a construction train's locomotives leave full)
  local fuel = 0
  local load = kind == "construction" and CFG.fuel_target or CFG.starter_fuel
  for _, ent in ipairs({made[1], made[#made]}) do
    local inv = ent.get_fuel_inventory()
    if inv then fuel = fuel + logistics.transfer(net, inv, rails.FUEL, load) end
  end
  train.manual_mode = true
  local rec = {id = train.id, kind = kind, force = force_name, home = depot_un, loco = made[1], stock = made,
               state = "idle", created = game.tick, delivered = {}, trips = 0,
               armoured = armoured or nil} -- Phase 5 M3 war2
  rstate().trains[train.id] = rec
  util.log("rails: depot #%d (%s) deployed %s%s train %d: %d carriages, %d coal", depot_un, force_name,
    armoured and "armoured " or "", kind, train.id, #made, fuel)
  return train
end

local function schedule_two(train, rec)
  local A, B = rails.depot(rec.pickup), rails.depot(rec.dropoff)
  if not (A and B) then return false end
  local sch = train.get_schedule()
  sch.clear_records()
  sch.add_record({station = A.stop_name, wait_conditions = {{type = "time", ticks = rails.LONG_WAIT}}})
  sch.add_record({station = B.stop_name, wait_conditions = {{type = "time", ticks = rails.LONG_WAIT}}})
  return true
end

local function depart(rec, train, index, why)
  local R = rstate()
  rec.dwell = nil
  R.dwelling[train.id] = nil
  rec.reason = nil
  train.manual_mode = false
  local sch = train.get_schedule()
  if sch.get_record_count() >= index then sch.go_to_station(index) end
  rec.state = index == 2 and "to_dropoff" or "to_pickup"
  rec.leg = game.tick
  util.log("rails: train %d (%s) leaves for %s (%s)", train.id, rec.force, index == 2 and "drop-off" or "pickup",
    why or "-")
end

--- Freight route: pickup depot -> drop-off depot. Writes the schedule and starts the train. Returns true when set.
function rails.set_route(train, pickup, dropoff)
  local rec = rails.train_record(train)
  if not (rec and FREIGHT[rec.kind] and train and train.valid) then return false end -- Phase 5 M2 war
  if not (rails.depot(pickup) and rails.depot(dropoff)) or pickup == dropoff then return false end
  if rec.stops then -- 0.1.2 (#31 part B): a two-record route replaces a stop list (scripts/railroutes.lua)
    rec.stops, rec.rmap, rec.written, rec.dwell = nil, nil, nil, nil
  end
  rec.pickup, rec.dropoff = pickup, dropoff
  rec.lost_pickup, rec.lost_dropoff = nil, nil -- Phase 5 M3 integration: a new route replaces a lost one
  if not schedule_two(train, rec) then return false end
  local cargo = cargo_of(train)
  util.log("rails: train %d (%s) route depot #%d -> depot #%d", train.id, rec.force, pickup, dropoff)
  depart(rec, train, next(cargo) and 2 or 1, "route")
  return true
end

--- Route halves from the right-click UX: set the pickup or the drop-off; the route starts when both are set.
function rails.set_pickup(train, depot_un)
  local rec = rails.train_record(train)
  if not (rec and FREIGHT[rec.kind] and rails.depot(depot_un)) then return false end -- Phase 5 M2 war
  rec.pickup = depot_un
  if rec.dropoff and rec.dropoff ~= depot_un then return rails.set_route(train, depot_un, rec.dropoff) end
  util.log("rails: train %d pickup depot #%d (drop-off not set)", train.id, depot_un)
  return true
end

function rails.set_dropoff(train, depot_un)
  local rec = rails.train_record(train)
  if not (rec and FREIGHT[rec.kind] and rails.depot(depot_un)) then return false end -- Phase 5 M2 war
  rec.dropoff = depot_un
  if rec.pickup and rec.pickup ~= depot_un then return rails.set_route(train, rec.pickup, depot_un) end
  util.log("rails: train %d drop-off depot #%d (pickup not set)", train.id, depot_un)
  return true
end

--- Send a waiting or stopped freight train on (re-plans at its stop, or restarts its schedule).
function rails.resume(train)
  local rec = rails.train_record(train)
  if not rec then return false end
  if rec.stops and rails.routes then return rails.routes.resume(rec, train) end -- 0.1.2 (#31 part B)
  if FREIGHT[rec.kind] and rec.pickup and rec.dropoff then -- Phase 5 M2 war: troop trains too
    schedule_two(train, rec)
    if rec.dwell then
      rec.dwell.plan, rec.dwell.next_plan = nil, nil
      return true
    end
    depart(rec, train, next(cargo_of(train)) and 2 or 1, "resume")
    return true
  end
  return false
end

--- Phase 5 M2 war: send a freight or troop train on to its pickup (1) or drop-off (2) now (scripts/garrison.lua).
function rails.depart_train(train, index, why)
  local rec = rails.train_record(train)
  if not (rec and train and train.valid and FREIGHT[rec.kind]) then return false end
  depart(rec, train, index, why)
  return true
end

---------------------------------------------------------------------------
-- Freight: loading, unloading, refuelling at depots
---------------------------------------------------------------------------
-- Cargo already promised to a network by other trains of the force: {[item] = n} for the drop-off's network id.
local function inbound(force_name, net_id, except_id)
  local out = {}
  for id, rec in pairs(rstate().trains) do
    if id ~= except_id and rec.force == force_name and rec.kind == "cargo" and rec.dropoff then
      local entry = logistics.entry_for_hub(rec.dropoff)
      local train = entry and entry.id == net_id and train_of(rec)
      if train then
        for item, n in pairs(cargo_of(train)) do out[item] = (out[item] or 0) + n end
      end
    end
  end
  return out
end
rails.inbound = inbound -- 0.1.2 (#31): scripts/railroutes.lua adds the cargo of trains on stop lists

-- What to load at the pickup for the drop-off (hauler manual-route rule). Returns plan or nil, reason.
local function cargo_plan(rec, train)
  local src = logistics.entry_for_hub(rec.pickup)
  local dst = logistics.entry_for_hub(rec.dropoff)
  if not (src and dst) then return nil, "no-route" end
  if src.id == dst.id then return nil, "same-network" end
  local in_res = inbound(rec.force, dst.id, train.id)
  local aboard = cargo_of(train)
  -- Economy 0.1.1 (#7): an AI rail program's freight train carries everything its town offers, not only what the
  -- capital's Keep still lacks: with the capital at its 3,000-ore Keep a trip carried what the capital had used since
  -- (6-184 ore in M1 501) while the town's surplus went 1,000 tiles to the port by hauler (6,000 copper ore of the
  -- player's); the capital's port route sells what it holds above its export level
  local feeder = next(dst.keep) == nil or rec.ai_line ~= nil
  local plan, any = {}, false
  for item, threshold in pairs(src.export) do
    local avail = src.network.get_item_count(item) - threshold
    if avail > 0 then
      local wanted
      if feeder then
        wanted = avail
      else
        local keep = dst.keep[item]
        wanted = keep and (keep - dst.network.get_item_count(item) - (in_res[item] or 0) - (aboard[item] or 0)) or 0
      end
      local n = min(avail, wanted)
      if n > 0 then
        plan[item] = n
        any = true
      end
    end
  end
  if not any then return nil, "nothing" end
  return plan
end

local function dwell_step(rec, train)
  local d = rec.dwell
  local net = logistics.hub_network(d.depot)
  if not net then
    rec.reason = "no-network"
    return
  end
  local budget0 = floor(CFG.transfer_rate * rails.TRANSFER_PERIOD / 60)
  local stats = rails.stats(rec.force)
  if d.role == "pickup" then
    if not d.plan then
      if d.next_plan and game.tick < d.next_plan then return end
      local plan, why = cargo_plan(rec, train)
      if not plan then
        if next(cargo_of(train)) then
          refuel(train, net)
          depart(rec, train, 2, "cargo aboard")
          return
        end
        rec.reason = why
        rec.state = "waiting"
        d.next_plan = game.tick + 60
        return
      end
      d.plan, d.loaded = plan, {}
      rec.state, rec.reason = "loading", nil
    end
    local items = sorted_keys(d.plan)
    local moved = 0
    for _, wagon in ipairs(wagons_of(train)) do
      local inv = wagon.get_inventory(defines.inventory.cargo_wagon)
      local budget = budget0
      for _, item in ipairs(items) do
        local want = d.plan[item]
        if inv and want > 0 and budget > 0 then
          local n = logistics.transfer(net, inv, item, min(want, budget))
          d.plan[item] = want - n
          d.loaded[item] = (d.loaded[item] or 0) + n
          budget = budget - n
          moved = moved + n
        end
      end
    end
    local left = 0
    for _, n in pairs(d.plan) do left = left + n end
    if left <= 0 or moved == 0 then
      refuel(train, net)
      local parts = {}
      for _, item in ipairs(sorted_keys(d.loaded)) do parts[#parts + 1] = string.format("%d %s", d.loaded[item], item) end
      util.log("rails: train %d loaded %s at depot #%d", train.id, #parts > 0 and table.concat(parts, ", ") or "nothing",
        d.depot)
      if next(cargo_of(train)) then
        depart(rec, train, 2, "loaded")
      else
        d.plan, d.next_plan = nil, game.tick + 60
        rec.state, rec.reason = "waiting", "nothing"
      end
    end
  elseif d.role == "dropoff" then
    rec.state = "unloading"
    local moved, left = 0, 0
    for _, wagon in ipairs(wagons_of(train)) do
      local inv = wagon.get_inventory(defines.inventory.cargo_wagon)
      local budget = budget0
      if inv then
        for _, item in pairs(inv.get_contents()) do
          if budget > 0 then
            local n = logistics.transfer(inv, net, item.name, min(item.count, budget))
            budget = budget - n
            moved = moved + n
            if n > 0 then
              rec.delivered[item.name] = (rec.delivered[item.name] or 0) + n
              stats.delivered[item.name] = (stats.delivered[item.name] or 0) + n
              stats.items = stats.items + n
              d.unloaded = (d.unloaded or 0) + n
            end
          end
        end
        left = left + #inv - inv.count_empty_stacks()
      end
    end
    if left == 0 then
      refuel(train, net)
      rec.trips = rec.trips + 1
      stats.trips = stats.trips + 1
      util.log("rails: train %d delivered %d items to depot #%d (trip %d, %.1f s at the platform)", train.id,
        d.unloaded or 0, d.depot, rec.trips, (game.tick - d.since) / 60)
      depart(rec, train, 1, "unloaded")
    elseif moved == 0 then
      rec.reason = "full"
    end
  else
    refuel(train, net)
    depart(rec, train, 1, "not on its route")
  end
end

---------------------------------------------------------------------------
-- Lines: open, cut, repair dispatch
---------------------------------------------------------------------------
local function line_path_ok(line, reverse)
  local A, B = rails.depot(line.a), rails.depot(line.b)
  if reverse then A, B = B, A end
  if not (A and B and A.platform and B.platform) then return false end
  local goals = {}
  for _, st in pairs(B.platform.stops) do
    if st.valid and st.connected_rail then goals[#goals + 1] = {train_stop = st} end
  end
  local rail = A.platform.rails[floor(#A.platform.rails / 2)]
  if not (rail and rail.valid) or #goals == 0 then return false end
  local ok, res = pcall(game.train_manager.request_train_path, {
    starts = {{rail = rail, direction = RD.front}, {rail = rail, direction = RD.back}}, goals = goals,
    type = "any-goal-accessible"})
  return ok and res ~= nil and res.found_path == true
end

local function supports_missing(line)
  local n = 0
  for _, sp in ipairs(line.supports or {}) do
    if not (sp.e and sp.e.valid) then n = n + 1 end
  end
  return n
end

local function open_line(line)
  local was = line.state
  line.state = "open"
  line.opened = line.opened or game.tick
  line.reopened = game.tick
  line.blocked = nil
  line.wait = nil -- Phase 5 M2 QA round 1: an open line showed the last construction train's "does not fit" reason
  local stats = rails.stats(line.force)
  local cl = line.cleared or {}
  util.log("rails: line #%d of %s %s: %d pieces, %.0f tiles, rails used %d (bill %d, loaded %d, returned %d, robots %d); "
    .. "cleared %d trees, %d rocks, %d cliffs", line.id, line.force, was == "cut" and "repaired and open" or "open",
    #line.pieces, line.length, line.used, line.bill.rails, line.loaded, line.returned, line.robot, cl.tree or 0,
    cl["simple-entity"] or 0, cl.cliff or 0)
  alert(line.force, "line-open", line_position(line), "rts.alert-line-open")
  stats.lines_open = (stats.lines_open or 0) + (was == "cut" and 0 or 1)
  -- trains of the line that lost their path go again
  for id, rec in pairs(rstate().trains) do
    if rec.kind == "cargo" and rec.force == line.force then
      local train = train_of(rec)
      if train and train.state == TS.no_path then pcall(train.recalculate_path) end
    end
  end
end

local function piece_missing(line, i, entity_died)
  local p = line.pieces[i]
  if not p then return end
  local was_built = p.e ~= nil
  p.e = nil
  if was_built then line.missing = line.missing + 1 end
  local s = game.surfaces[line.surface]
  if s and not (p.g and p.g.valid) then
    p.g = s.create_entity({name = "entity-ghost", inner_name = p.name, position = {p.x, p.y}, direction = p.d,
                           force = line.force})
  end
  if line.state == "open" then
    line.state = "cut"
    line.cut_tick = game.tick
    line.cut_at = {x = p.x, y = p.y}
    util.log("rails: line #%d of %s cut at %s (piece %d %s)", line.id, line.force, util.pos_str(line.cut_at), i, p.name)
    alert(line.force, "line-cut", line.cut_at, "rts.alert-line-cut")
  end
end

-- Index of the line piece nearest to a position (0 = depot A's platform, #pieces + 1 = depot B's), or nil.
local function line_index_at(line, pos)
  local A, B = rails.depot(line.a), rails.depot(line.b)
  if A and A.platform and util.distance(pos, A.entity.position) < 24 then return 0 end
  if B and B.platform and util.distance(pos, B.entity.position) < 24 then return #line.pieces + 1 end
  local best, bd
  for i, p in ipairs(line.pieces) do
    local dx, dy = p.x - pos.x, p.y - pos.y
    local d = dx * dx + dy * dy
    if not bd or d < bd then best, bd = i, d end
  end
  if bd and bd < 400 then return best end
  return nil
end

-- Where the line's freight trains stand: list of piece indices.
-- Phase 5 M3 ai (H4, applied by m3-integ): only this line's freight trains stand "ahead" of its crew; another line's
-- train waiting at a shared capital depot kept a trunk line's crews turning back for 20 minutes (seed 801). A freight
-- train is this line's when its AI line mark or a depot of its route is the line's; a train without a route still counts.
local function on_line(rec, line)
  if rec.ai_line then return rec.ai_line == line.id end
  if rec.stops then -- 0.1.2 (#31 part B): a train on a stop list is the line's when one of its stops is a line end
    for _, st in ipairs(rec.stops) do
      if st.target and (st.target == line.a or st.target == line.b) then return true end
    end
    return next(rec.stops) == nil
  end
  local p, d = rec.pickup, rec.dropoff
  if not (p or d) then return true end
  return p == line.a or p == line.b or d == line.a or d == line.b
end

local function cargo_positions(line)
  local list = {}
  for _, rec in pairs(rstate().trains) do
    if rec.kind == "cargo" and rec.force == line.force and on_line(rec, line) then
      local train = train_of(rec)
      if train then
        for _, stock in ipairs({train.front_stock, train.back_stock}) do
          if stock and stock.valid then
            local i = line_index_at(line, stock.position)
            if i then list[#list + 1] = i end
          end
        end
      end
    end
  end
  return list
end

local function missing_range(line)
  local lo, hi
  for i, p in ipairs(line.pieces) do
    if not (p.e and p.e.valid) then
      lo = lo or i
      hi = i
    end
  end
  return lo, hi
end

local function rails_needed(line, dir, from)
  local need = 0
  local n = #line.pieces
  local i, last = from, dir == 1 and n or 1
  while (dir == 1 and i <= last) or (dir == -1 and i >= last) do
    local p = line.pieces[i]
    if not (p.e and p.e.valid) then
      need = need + p.rails
      if p.sig then need = need + 2 * CFG.signal_rails end
    end
    i = i + dir
  end
  for _, sp in ipairs(line.supports) do
    if not (sp.e and sp.e.valid) then need = need + CFG.support_rails end
  end
  return need
end

local function dispatch_builder(line)
  local lo, hi = missing_range(line)
  if not lo then return end
  local cargo = cargo_positions(line)
  local sides = {{depot = line.a, dir = 1, from = lo}, {depot = line.b, dir = -1, from = hi}}
  local why = "no-kits"
  local why_set = false -- Phase 5 M1 integration: the far side's "no-rails" no longer hides the near side's reason
  for _, side in ipairs(sides) do
    local blocked = false
    for _, ci in ipairs(cargo) do
      if (side.dir == 1 and ci < lo) or (side.dir == -1 and ci > hi) then blocked = true end
    end
    local d = rails.depot(side.depot)
    local net = d and logistics.hub_network(side.depot)
    if blocked then
      why = "train-in-the-way"
    elseif d and net then
      local need = rails_needed(line, side.dir, side.from)
      local have = net.get_item_count(rails.RAIL)
      if have <= 0 or have < min(need, rails.CREW_MIN_RAILS) then
        if not why_set then why = "no-rails" end
      else
        local train, reason = rails.create_train(side.depot, "construction")
        if train then
          local rec = rails.train_record(train)
          rec.line, rec.dir, rec.state = line.id, side.dir, "to_head"
          local wagon = wagons_of(train, rails.CWAGON)[1]
          rec.wagon = wagon
          local inv = wagon and wagon.get_inventory(defines.inventory.cargo_wagon)
          local cap = rails.WAGON_STACKS * (prototypes.item[rails.RAIL].stack_size or 100)
          local loaded = inv and logistics.transfer(net, inv, rails.RAIL, min(need, cap)) or 0
          line.loaded = line.loaded + loaded
          -- coal for the trip in the wagon: the crew refuels its locomotives on the way (stop-and-go burns a lot)
          if inv then logistics.transfer(net, inv, rails.FUEL, rails.CREW_COAL) end
          line.builder = train.id
          line.wait = nil
          util.log("rails: line #%d: construction train %d from depot #%d (dir %+d, missing %d..%d), %d rails loaded "
            .. "of %d needed", line.id, train.id, side.depot, side.dir, lo, hi, loaded, need)
          return
        end
        why, why_set = reason, true
      end
    end
  end
  if line.wait ~= why then
    line.wait = why
    util.log("rails: line #%d (%s) waits for a construction train: %s", line.id, line.state, why)
  end
end

local function check_lines()
  local R = rstate()
  for _, id in ipairs(sorted_keys(R.lines)) do
    local line = R.lines[id]
    local st = line.state
    if (st == "building" or st == "cut") and line.pieces then
      if line.builder and not R.trains[line.builder] then line.builder = nil end
      local detour_due = st == "building" and line.blocked and line.blocked_at
        and (line.detours or 0) < #rails.DETOUR_SPAN
        and game.tick - line.blocked_at >= rails.DETOUR_AFTER * 2 ^ (line.detours or 0)
      -- the crew goes home first (builder_step): the detour takes up the rails it stands on
      line.detour_wanted = (detour_due and line.builder) and true or nil
      if detour_due and line.builder then
        -- (waiting for the crew)
      elseif detour_due and start_detour(line) then
        -- (surveying around the blocked piece)
      elseif line.missing <= 0 and supports_missing(line) == 0 then
        if line_path_ok(line) then
          open_line(line)
        elseif line_path_ok(line, true) and #(line.signals or {}) > 0 then
          -- one-way (an unpaired signal from an older save or a cut): the signals go, a single-train line needs none
          local n = 0
          for _, sig in ipairs(line.signals) do
            if sig.valid then
              sig.destroy()
              n = n + 1
            end
          end
          line.signals = {}
          util.log("rails: line #%d of %s was one-way: %d signals removed", line.id, line.force, n)
        end
      elseif not line.builder then
        dispatch_builder(line)
      end
    elseif st == "open" and line.missing > 0 then
      line.state = "cut"
      line.cut_tick = line.cut_tick or game.tick
    end
  end
end

---------------------------------------------------------------------------
-- Construction trains
---------------------------------------------------------------------------
local function goto_rail(train, rail)
  local sch = train.get_schedule()
  sch.clear_records()
  sch.add_record({rail = rail, temporary = true, wait_conditions = {{type = "time", ticks = rails.LONG_WAIT}}})
  train.manual_mode = false
  sch.go_to_station(1)
end

local function go_home(rec, train, why)
  local d = rails.depot(rec.home)
  rec.state = "returning"
  rec.target = nil
  if not d then return end
  local sch = train.get_schedule()
  sch.clear_records()
  sch.add_record({station = d.stop_name, temporary = true, wait_conditions = {{type = "time", ticks = rails.LONG_WAIT}}})
  train.manual_mode = false
  sch.go_to_station(1)
  util.log("rails: construction train %d returns to depot #%d (%s)", train.id, rec.home, why)
end

-- Construction train back into kits, its cargo and fuel into the depot network.
local function despawn(rec, train)
  local R = rstate()
  local net = logistics.hub_network(rec.home)
  local line = rec.line and R.lines[rec.line]
  local returned = {}
  if net then
    for _, w in ipairs(wagons_of(train)) do
      local inv = w.get_inventory(defines.inventory.cargo_wagon)
      for _, item in pairs(inv and inv.get_contents() or {}) do
        local n = logistics.transfer(inv, net, item.name, item.count)
        returned[item.name] = (returned[item.name] or 0) + n
      end
    end
    for _, group in pairs({train.locomotives.front_movers, train.locomotives.back_movers}) do
      for _, loco in ipairs(group) do
        local inv = loco.get_fuel_inventory()
        local n = inv and inv.get_item_count(rails.FUEL) or 0
        if n > 0 then logistics.transfer(inv, net, rails.FUEL, n) end
      end
    end
    for _, k in ipairs(kit_list("construction")) do net.insert({name = k[1], count = k[2]}) end
  end
  if line then
    line.returned = line.returned + (returned[rails.RAIL] or 0)
    if line.builder == train.id then line.builder = nil end
  end
  R.trains[train.id] = nil
  R.dwelling[train.id] = nil
  util.log("rails: construction train %d back in depot #%d: %d rails returned, kits stored", train.id, rec.home,
    returned[rails.RAIL] or 0)
  for _, e in ipairs(train.carriages) do
    if e.valid then e.destroy() end
  end
end

local function wagon_inv(rec)
  local w = rec.wagon
  return w and w.valid and w.get_inventory(defines.inventory.cargo_wagon) or nil
end

local function take_rails(rec, n)
  if n <= 0 then return true end
  local inv = wagon_inv(rec)
  if not inv or inv.get_item_count(rails.RAIL) < n then return false end
  inv.remove({name = rails.RAIL, count = n})
  return true
end

local function clear_for(s, box, count)
  if not box then return 0 end
  local lt, rb = box.left_top, box.right_bottom
  return clear_area(s, {{lt.x - 0.5, lt.y - 0.5}, {rb.x + 0.5, rb.y + 0.5}}, count)
end

local function lay_support(line, sp, rec, s)
  if sp.e and sp.e.valid then return true end
  local inv = wagon_inv(rec)
  if not inv or inv.get_item_count(rails.RAIL) < CFG.support_rails then return false end
  clear_area(s, {{sp.x - 1.5, sp.y - 1.5}, {sp.x + 1.5, sp.y + 1.5}})
  local ent
  if sp.g and sp.g.valid then
    local _, e = sp.g.revive({raise_revive = true})
    ent = e
  end
  if not ent and s.can_place_entity({name = rails.SUPPORT, position = {sp.x, sp.y}, direction = sp.d,
                                     force = line.force, build_check_type = MANUAL}) then
    ent = s.create_entity({name = rails.SUPPORT, position = {sp.x, sp.y}, direction = sp.d, force = line.force})
  end
  if not ent then return false end
  take_rails(rec, CFG.support_rails)
  line.used = line.used + CFG.support_rails
  sp.e, sp.g = ent, nil
  return true
end

local function place_signals(line, p, rec, s)
  local e = p.e
  if not (e and e.valid) then return end
  local re
  for _, rd in ipairs({RD.front, RD.back}) do
    local x = e.get_rail_end(rd)
    local pos = x.location.position
    if abs(pos.x - p.gx) < 0.2 and abs(pos.y - p.gy) < 0.2 then re = x end
  end
  if not re then return end
  -- Phase 5 M1 integration: both signals of a pair or none: a crew short of rails placed one signal of a pair, which
  -- made the line one-way (no path from depot A to B; seed 405 never opened its line)
  local n = 0
  for _, key in ipairs({"in_signal_location", "out_signal_location"}) do
    local loc = re[key]
    if loc and loc.rail_layer == 0 then n = n + 1 end
  end
  local inv0 = wagon_inv(rec)
  if not inv0 or inv0.get_item_count(rails.RAIL) < n * CFG.signal_rails then return end
  for _, key in ipairs({"in_signal_location", "out_signal_location"}) do
    local loc = re[key]
    local inv = wagon_inv(rec)
    if loc and loc.rail_layer == 0 and inv and inv.get_item_count(rails.RAIL) >= CFG.signal_rails then
      local sig = s.create_entity({name = rails.SIGNAL, position = loc.position, direction = loc.direction,
                                   force = line.force, rail_layer = loc.rail_layer})
      if sig then
        take_rails(rec, CFG.signal_rails)
        line.used = line.used + CFG.signal_rails
        line.signals[#line.signals + 1] = sig
      end
    end
  end
end

-- Lay piece i: supports due first, then clear the ground and revive the ghost. Returns ok, reason.
local function lay_piece(line, i, rec, s)
  local p = line.pieces[i]
  for _, sp in ipairs(line.supports) do
    if sp.before == i and not (sp.e and sp.e.valid) then
      if not lay_support(line, sp, rec, s) then return false, "support" end
    end
  end
  local inv = wagon_inv(rec)
  if not inv or inv.get_item_count(rails.RAIL) < p.rails then return false, "no-rails" end
  local g = p.g
  if not (g and g.valid) then
    g = s.create_entity({name = "entity-ghost", inner_name = p.name, position = {p.x, p.y}, direction = p.d,
                         force = line.force})
    p.g = g
  end
  if not g then return false, "ghost" end
  line.cleared = line.cleared or {}
  clear_for(s, g.bounding_box, line.cleared)
  local x0, x1 = min(p.sx, p.gx, p.x), max(p.sx, p.gx, p.x)
  local y0, y1 = min(p.sy, p.gy, p.y), max(p.sy, p.gy, p.y)
  if not p.elev then clear_area(s, {{x0 - 2.5, y0 - 2.5}, {x1 + 2.5, y1 + 2.5}}, line.cleared) end
  local _, ent = g.revive({raise_revive = true})
  if not ent and p.elev then
    -- a support on either end of the piece carries it (probe P2)
    for _, at in ipairs({{p.sx, p.sy, p.sd}, {p.gx, p.gy, p.gd}}) do
      if not ent and inv.get_item_count(rails.RAIL) >= p.rails + CFG.support_rails then
        local sp = {x = at[1], y = at[2], d = at[3], before = i, extra = true}
        if lay_support(line, sp, rec, s) then
          line.supports[#line.supports + 1] = sp
          if g.valid then
            local _, e2 = g.revive({raise_revive = true})
            ent = e2
          end
        end
      end
    end
  end
  if not ent and not p.elev and g.valid
     and s.can_place_entity({name = p.name, position = {p.x, p.y}, direction = p.d, force = line.force,
                             build_check_type = MANUAL}) then
    -- Phase 5 M3 integration: a ghost does not revive under a vehicle though the rail itself fits (a city's hauler
    -- parked on the line: M1 seed 501's line #6 stood at piece 63 for 34 minutes): build the piece outright
    g.destroy()
    p.g = nil
    ent = s.create_entity({name = p.name, position = {p.x, p.y}, direction = p.d, force = line.force, raise_built = true})
    if not ent then return false, "create" end
  end
  if not ent then
    if not p.debugged and g.valid then
      p.debugged = true
      local bb = g.bounding_box
      local ents, tiles = {}, {}
      for _, x in ipairs(s.find_entities_filtered({area = bb})) do
        if x ~= g then ents[#ents + 1] = x.type .. ":" .. x.name .. "@" .. util.pos_str(x.position) end
      end
      for _, t in ipairs(s.find_tiles_filtered({area = bb})) do tiles[t.name] = (tiles[t.name] or 0) + 1 end
      local tl = {}
      for n, c in pairs(tiles) do tl[#tl + 1] = n .. "=" .. c end
      table.sort(tl)
      util.log("rails: piece %d %s at %s dir %d will not revive: box %s-%s, entities [%s], tiles [%s], manual_ghost=%s "
        .. "manual=%s", i, p.name, util.pos_str({p.x, p.y}), p.d, util.pos_str(bb.left_top), util.pos_str(bb.right_bottom),
        table.concat(ents, " "), table.concat(tl, " "),
        tostring(s.can_place_entity({name = p.name, position = {p.x, p.y}, direction = p.d, force = line.force,
                                     build_check_type = MANUAL_GHOST, forced = true})),
        tostring(s.can_place_entity({name = p.name, position = {p.x, p.y}, direction = p.d, force = line.force,
                                     build_check_type = MANUAL})))
    end
    return false, "revive"
  end
  take_rails(rec, p.rails)
  line.used = line.used + p.rails
  p.e, p.g = ent, nil
  line.missing = line.missing - 1
  if p.sig then place_signals(line, p, rec, s) end
  return true
end

local function next_missing(line, dir, from)
  local n = #line.pieces
  local i = from or (dir == 1 and 1 or n)
  while i >= 1 and i <= n do
    local p = line.pieces[i]
    if not (p.e and p.e.valid) then return i end
    i = i + dir
  end
  return nil
end

local function nearest_loco_distance(train, pos)
  local best
  for _, stock in ipairs({train.front_stock, train.back_stock}) do
    if stock and stock.valid then
      local d = util.distance(stock.position, pos)
      if not best or d < best then best = d end
    end
  end
  return best or math.huge
end

-- Work done in this direction. A crew whose last piece was the one next to the far platform parks at that depot (it
-- is there already); any other crew (a repair) goes back the way it came, so it never meets the freight train.
local function finish_build(rec, train, line)
  local far = rails.depot(rec.dir == 1 and line.b or line.a)
  local last = line.pieces[rec.dir == 1 and #line.pieces or 1]
  if far and last and not next_missing(line, rec.dir)
     and nearest_loco_distance(train, {x = last.x, y = last.y}) <= CFG.build_reach + 20 then
    rec.home = far.un
  end
  go_home(rec, train, "done")
end

-- True when the crew has neither moved a tile nor laid a piece for CREW_STUCK_TICKS (a crew at a piece that will not
-- revive is the blocked-line detour's, not this rule's).
local function crew_stuck(rec, train, line)
  local fs = train.front_stock
  if not (fs and fs.valid) then return false end
  local p, m = fs.position, rec.moved
  if not m or util.distance(m, p) > 1 or (rec.built or 0) ~= m.built then
    rec.moved = {x = p.x, y = p.y, tick = game.tick, built = rec.built or 0}
    return false
  end
  if rec.state ~= "returning" and line and line.blocked then return false end
  return game.tick - m.tick >= rails.CREW_STUCK_TICKS
end

local function builder_step(rec, train)
  local R = rstate()
  local line = rec.line and R.lines[rec.line]
  if crew_stuck(rec, train, line) then
    local secs = (game.tick - rec.moved.tick) / 60
    local where = util.pos_str(train.front_stock.position)
    local how = util.define_name(defines.train_state, train.state)
    rec.moved = nil
    if rec.state == "returning" then
      util.log("rails: construction train %d stuck on its way home at %s for %.0f s (%s): recalled to depot #%s",
        train.id, where, secs, how, tostring(rec.home))
      despawn(rec, train)
    else
      util.log("rails: construction train %d of line #%s stuck at %s for %.0f s (%s): it goes home", train.id,
        tostring(rec.line), where, secs, how)
      go_home(rec, train, "stuck")
    end
    return
  end
  if rec.state == "returning" then
    if rec.arrived then despawn(rec, train) end
    return
  end
  if not (line and line.pieces) or line.state == "surveying" or line.detour_wanted then
    go_home(rec, train, line and "detour survey" or "no line")
    return
  end
  local s = train.front_stock.surface
  local i = next_missing(line, rec.dir, rec.scan)
  rec.scan = i
  if not i then
    finish_build(rec, train, line)
    return
  end
  -- never lay past the line's freight train
  for _, ci in ipairs(cargo_positions(line)) do
    if (rec.dir == 1 and i > ci and ci > 0) or (rec.dir == -1 and i < ci and ci <= #line.pieces) then
      go_home(rec, train, "freight train ahead")
      return
    end
  end
  local inv = wagon_inv(rec)
  if not inv or inv.get_item_count(rails.RAIL) < line.pieces[i].rails then
    go_home(rec, train, "out of rails")
    return
  end
  -- the crew tops its locomotives up from the wagon's coal
  for _, group in pairs({train.locomotives.front_movers, train.locomotives.back_movers}) do
    for _, loco in ipairs(group) do
      local finv = loco.get_fuel_inventory()
      if finv and finv.get_item_count(rails.FUEL) < 5 then logistics.transfer(inv, finv, rails.FUEL, 10) end
    end
  end
  local budget = max(1, floor(CFG.build_rate * rails.STEP / 60 + 0.5))
  if (rec.next_log or 0) <= game.tick then
    rec.next_log = game.tick + 600
    local p = line.pieces[i]
    util.log("rails: construction train %d: frontier piece %d %s at %s (%.0f tiles away), target %s, train %s speed %.2f, "
      .. "%d rails aboard", train.id, i, p.name, util.pos_str({p.x, p.y}), nearest_loco_distance(train, {x = p.x, y = p.y}),
      tostring(rec.target), util.define_name(defines.train_state, train.state), train.speed,
      inv.get_item_count(rails.RAIL))
  end
  while budget > 0 and i do
    local p = line.pieces[i]
    if nearest_loco_distance(train, {x = p.x, y = p.y}) > CFG.build_reach then break end
    local ok, why = lay_piece(line, i, rec, s)
    if not ok then
      p.fails = (p.fails or 0) + 1
      if why == "no-rails" then
        go_home(rec, train, "out of rails")
        return
      end
      if p.fails == rails.MAX_PIECE_FAILS and not line.blocked then
        line.blocked, line.blocked_at = i, game.tick
        util.log("rails: line #%d blocked at piece %d %s %s (%s)", line.id, i, p.name, util.pos_str({p.x, p.y}), why)
        alert(line.force, "line-blocked", {x = p.x, y = p.y}, "rts.alert-line-blocked")
      end
      break
    end
    rec.built = (rec.built or 0) + 1
    rec.last_built = i
    if line.blocked == i then line.blocked, line.blocked_at = nil, nil end -- it went away
    budget = budget - 1
    i = next_missing(line, rec.dir, i)
    rec.scan = i
  end
  if not i then
    finish_build(rec, train, line)
    return
  end
  -- drive to the last built rail before the frontier (a platform end rail when the frontier is the first piece), but
  -- only once the frontier is out of the crew's reach: one hop per stretch instead of a new target every step
  local fp = line.pieces[i]
  if nearest_loco_distance(train, {x = fp.x, y = fp.y}) <= CFG.build_reach and rec.target then
    rec.state = "building"
    return
  end
  local t = i - rec.dir
  local target
  if t >= 1 and t <= #line.pieces then
    target = line.pieces[t].e
  else
    local d = rails.depot(t < 1 and line.a or line.b)
    local which = t < 1 and (line.a_end or 2) or (line.b_end or 2)
    local pr = d and d.platform and d.platform.rails
    if pr then target = which == 1 and pr[1] or pr[#pr] end
  end
  if target and target.valid and rec.target ~= t then
    rec.target = t
    goto_rail(train, target)
  end
  rec.state = "building"
end

---------------------------------------------------------------------------
-- Per-train step (state for the GUI, no fuel, construction trains)
---------------------------------------------------------------------------
local function fuel_left(train)
  local n = 0
  for _, group in pairs({train.locomotives.front_movers, train.locomotives.back_movers}) do
    for _, loco in ipairs(group) do
      local inv = loco.get_fuel_inventory()
      n = n + (inv and inv.get_item_count(rails.FUEL) or 0)
      if loco.burner and loco.burner.currently_burning then n = n + 1 end
    end
  end
  return n
end
rails.fuel_left = fuel_left

-- Phase 5 M1 integration: a train standing without coal on one of its force's depot platforms (deployed before the
-- network had coal) tanks from that depot's network as soon as the coal is there.
local function refuel_stranded(rec, train)
  if train.speed ~= 0 or fuel_left(train) > 0 then return end
  local R = rstate()
  local pos = train.front_stock and train.front_stock.valid and train.front_stock.position
  if not pos then return end
  for _, un in ipairs(sorted_keys(R.depots)) do
    local d = R.depots[un]
    local a = d.force == rec.force and d.platform and d.platform.area
    if a and pos.x >= a[1][1] - 4 and pos.x <= a[2][1] + 4 and pos.y >= a[1][2] - 4 and pos.y <= a[2][2] + 4 then
      local put = refuel(train, logistics.hub_network(un))
      if put > 0 then
        util.log("rails: train %d (%s) stranded without coal at depot #%d took %d coal", train.id, rec.force, un, put)
      end
      return
    end
  end
end

local function train_step(id, rec)
  local R = rstate()
  local train = train_of(rec)
  if not (train and train.valid) then
    R.trains[id] = nil
    R.dwelling[id] = nil
    return
  end
  refuel_stranded(rec, train)
  if train.id ~= id then
    R.trains[id] = nil
    R.trains[train.id] = rec
    rec.id = train.id
    if R.dwelling[id] then
      R.dwelling[id] = nil
      R.dwelling[train.id] = true
    end
  end
  if rec.kind == "construction" then
    builder_step(rec, train)
    return
  end
  if rec.stops then -- 0.1.2 (#31 part B): a train on a stop list (scripts/railroutes.lua)
    if rails.routes then rails.routes.step(rec, train) end
    return
  end
  if rec.dwell then return end
  local st = train.state
  if st == TS.no_path or st == TS.path_lost then
    if rec.state ~= "no_path" then
      rec.state = "no_path"
      util.log("rails: train %d (%s) has no path", train.id, rec.force)
    end
  elseif train.manual_mode then
    rec.state = rec.pickup and "stopped" or "idle"
  elseif train.speed == 0 and fuel_left(train) == 0 and st == TS.on_the_path then
    if rec.reason ~= "no-fuel" then
      rec.reason = "no-fuel"
      util.log("rails: train %d (%s) is out of fuel at %s", train.id, rec.force, util.pos_str(train.front_stock.position))
    end
  elseif rec.state == "no_path" then
    rec.state = rec.leg_to == 2 and "to_dropoff" or "to_pickup"
  end
end

---------------------------------------------------------------------------
-- Right click (orders.lua hook): a train selected -> right click a depot = pickup, Shift = drop-off;
-- a depot selected -> right click another own depot = lay a line between them.
---------------------------------------------------------------------------
local function pick_depot(player_index, force_name, position, entities)
  for _, e in pairs(entities or {}) do
    if e.valid and e.force.name == force_name and e.unit_number and rails.depot(e.unit_number) then return e.unit_number end
  end
  local un, rec = selection.building_at(player_index, position)
  if rec and rails.depot(un) and rec.force == force_name then return un end
  -- a click on a depot's platform or stop
  local R = storage.rails
  for _, dun in ipairs(sorted_keys(R and R.depots or {})) do
    local d = R.depots[dun]
    if d.force == force_name and d.platform and d.entity.valid then
      local a = d.platform.area
      local x, y = util.xy(position)
      if x >= a[1][1] and x <= a[2][1] and y >= a[1][2] and y <= a[2][2] then return dun end
    end
  end
  return nil
end

local function mark(player_index, target, color, surface)
  if not selection.real_player(player_index) then return end
  rendering.draw_circle({color = color, radius = 3, width = 4, filled = false, target = target, surface = surface,
                         time_to_live = 30, players = {player_index}})
end

function rails.right_click(player_index, position, entities, alt)
  local R = storage.rails
  if not R then return nil end
  local un, rec = selection.get_building(player_index)
  if not rec then return nil end
  local force_name = selection.force_name(player_index)
  if rec.kind == rails.KIND then
    local trec = rails.train_record(rec.entity)
    local train = trec and train_of(trec)
    local target = pick_depot(player_index, force_name, position, entities)
    -- 0.1.2 (#31 part B): a right click adds a stop to the train's stop list (scripts/railroutes.lua)
    if trec and train and rails.routes and rails.routes.click then
      local order, n = rails.routes.click(player_index, position, entities, alt, trec, train, target)
      if order then return order, n end
    end
    -- Phase 5 M3 war2: kinds another module drives (scripts/trainswar.lua: artillery trains go to a depot or a rail)
    local kh = trec and train and rails.KIND_HOOKS[trec.kind]
    if kh and kh.right_click then return kh.right_click(player_index, position, entities, alt, trec, train, target) end
    if not (train and FREIGHT[trec.kind] and target) then -- Phase 5 M2 war: troop trains too
      util.log("order train-none train=%s depot=%s player=%d", tostring(trec and trec.id), tostring(target), player_index)
      return "train-none", 0
    end
    local ok
    if alt then ok = rails.set_dropoff(train, target) else ok = rails.set_pickup(train, target) end
    local order = alt and "train-dropoff" or "train-pickup"
    util.log("order %s train=%d depot=#%d ok=%s player=%d", order, train.id, target, tostring(ok), player_index)
    local d = rails.depot(target)
    if d then mark(player_index, d.entity, alt and {r = 0.3, g = 1, b = 0.4, a = 1} or {r = 0.3, g = 0.7, b = 1, a = 1},
                   d.entity.surface) end
    return order, ok and 1 or 0
  end
  if rails.depot(un) and not alt then
    local target = pick_depot(player_index, force_name, position, entities)
    if target and target ~= un then
      local id, why = rails.plan_line(force_name, un, target)
      util.log("order lay-rail depot=#%d -> #%d line=%s (%s) player=%d", un, target, tostring(id), tostring(why),
        player_index)
      local player = selection.real_player(player_index)
      if player and not id then player.print({"rts.rails-plan-refused", {"rts.rails-why-" .. tostring(why)}}) end
      return "lay-rail", id and 1 or 0
    end
  end
  return nil
end

orders.on_right_click(rails.right_click)

---------------------------------------------------------------------------
-- Queries (railgui.lua)
---------------------------------------------------------------------------
--- Lines of a force, by id.
function rails.lines_of(force_name)
  local out = {}
  local R = storage.rails
  for _, id in ipairs(sorted_keys(R and R.lines or {})) do
    local line = R.lines[id]
    if line.force == force_name then out[#out + 1] = line end
  end
  return out
end

--- Trains of a force: list of records.
function rails.trains_of(force_name)
  local out = {}
  local R = storage.rails
  for _, id in ipairs(sorted_keys(R and R.trains or {})) do
    local rec = R.trains[id]
    if rec.force == force_name then out[#out + 1] = rec end
  end
  return out
end

rails.train_of = train_of

--- Kits, rails and coal in a depot's network: {loco, wagon, cwagon, rails, coal}.
function rails.depot_stock(un)
  local net = logistics.hub_network(un)
  if not net then return nil end
  return {loco = net.get_item_count(rails.LOCO_KIT), wagon = net.get_item_count(rails.WAGON_KIT),
          cwagon = net.get_item_count(rails.CWAGON_KIT), rails = net.get_item_count(rails.RAIL),
          coal = net.get_item_count(rails.FUEL)}
end

-- Phase 5 M2 war: a captured depot changes owner (scripts/capture.lua through buildings.set_force). Its stops get the
-- new owner's name (trains find stops by name across forces: probe), its line is lost to the old owner, the old
-- owner's trains bound to it stop, and an AI rail program built around the building starts again.
buildings.on_force_changed(function(un, rec, old)
  local R = storage.rails
  if not R then return end
  local d = R.depots[un]
  if d then
    d.force = rec.force
    d.stop_name = stop_name(rec.force, un)
    draw_depot_label(d) -- Phase 5 M3 integration: the new owner's label
    local color = force_color(rec.force)
    for _, st in pairs(d.platform and d.platform.stops or {}) do
      if st.valid then
        st.force = rec.force
        st.backer_name = d.stop_name
        if color then st.color = color end
      end
    end
    local line = d.line and R.lines[d.line]
    if line and line.force ~= rec.force then
      line.state = "lost"
      for _, end_un in ipairs({line.a, line.b}) do
        local od = R.depots[end_un]
        if od and od.line == line.id then od.line = nil end
      end
      util.log("rails: line #%d of %s lost: depot #%d now belongs to %s", line.id, line.force, un, rec.force)
    end
    d.line = nil
    -- Phase 5 M2 integration: the depot is back with the owner of a line it lost (its city retaken): the line is
    -- restored when its other end is the owner's too, as "cut" (repair crews) once it had opened, else "building"
    for _, id in ipairs(sorted_keys(R.lines)) do
      local ln = R.lines[id]
      if ln.state == "lost" and ln.force == rec.force and (ln.a == un or ln.b == un) then
        local other = R.depots[ln.a == un and ln.b or ln.a]
        if other and other.entity.valid and other.force == rec.force and not other.line then
          ln.state = ln.opened and "cut" or "building"
          ln.wait = nil
          d.line, other.line = id, id
          util.log("rails: line #%d of %s restored (%s): depot #%d is back", id, rec.force, ln.state, un)
          break
        end
      end
    end
    for _, id in ipairs(sorted_keys(R.trains)) do
      local trec = R.trains[id]
      if trec.force == old and (trec.pickup == un or trec.dropoff == un or trec.home == un) then
        local train = train_of(trec)
        if train and train.valid then train.manual_mode = true end
        -- Phase 5 M3 integration: remember the lost half, so a human's train takes its route up again (below)
        if trec.pickup == un then trec.pickup, trec.lost_pickup = nil, un end
        if trec.dropoff == un then trec.dropoff, trec.lost_dropoff = nil, un end
        trec.state, trec.reason = "stopped", "depot-lost"
        R.dwelling[id] = nil
        trec.dwell = nil
      end
    end
    -- Phase 5 M3 integration (M2 integration open issue 12): the depot is back: trains routed by hand that lost it get
    -- their route again (an AI rail program routes its own trains: rec.ai_line)
    for _, id in ipairs(sorted_keys(R.trains)) do
      local trec = R.trains[id]
      if trec.force == rec.force and not trec.ai_line and (trec.lost_pickup == un or trec.lost_dropoff == un) then
        if trec.lost_pickup == un then trec.pickup, trec.lost_pickup = un, nil end
        if trec.lost_dropoff == un then trec.dropoff, trec.lost_dropoff = un, nil end
        local train = train_of(trec)
        if train and train.valid and trec.pickup and trec.dropoff and not trec.lost_pickup and not trec.lost_dropoff
           and rails.set_route(train, trec.pickup, trec.dropoff) then
          util.log("rails: train %d (%s) routed again: depot #%d is back", train.id, rec.force, un)
        end
      end
    end
  end
  -- Phase 5 M2 integration: a program that lost a building is kept in R.ai_lost and taken up again when its far city
  -- comes back (rails.ai_revive, the rts_city_captured signal); the AI plans a new line meanwhile
  local function lose(P)
    R.ai_lost = R.ai_lost or {}
    R.ai_lost[old] = R.ai_lost[old] or {}
    table.insert(R.ai_lost[old], {anchor = P.anchor, far = P.far, depot_a = P.depot_a, depot_b = P.depot_b,
                                  line = P.line, far_site = P.far_site})
  end
  local function uses(P) return P.anchor == un or P.far == un or P.depot_a == un or P.depot_b == un end
  local A = R.ai and R.ai[old]
  if A and uses(A) then
    R.ai[old] = nil
    lose(A)
    util.log("rails: AI %s lost #%d of its rail program: it plans a new line", old, un)
  end
  local more = R.ai_more and R.ai_more[old]
  for i = #(more or {}), 1, -1 do
    if uses(more[i]) then
      lose(table.remove(more, i))
      util.log("rails: AI %s lost #%d of a second rail program", old, un)
    end
  end
  -- 0.1.2 (#31 part B): stop lists of both owners skip or take up the depot again
  if d and rails.routes then rails.routes.refresh(un) end
end)

--- Phase 5 M2 integration: a city came back to a force (rts_city_captured): a rail program it lost with that city as
--- its far end is taken up again (its restored line, or a new depot and line), as the main program when the force has
--- none, else beside it (R.ai_more, serviced by rails.ai_step).
function rails.ai_revive(force_name, center_un)
  local R = storage.rails
  local lost = R and R.ai_lost and R.ai_lost[force_name]
  if not (lost and center_un) then return false end
  for i, P in ipairs(lost) do
    if P.far == center_un then
      table.remove(lost, i)
      P.state, P.next, P.why, P.policies = "idle", nil, nil, nil
      R.ai = R.ai or {}
      local where
      if not R.ai[force_name] then
        R.ai[force_name] = P
        where = "main"
      else
        R.ai_more = R.ai_more or {}
        R.ai_more[force_name] = R.ai_more[force_name] or {}
        table.insert(R.ai_more[force_name], P)
        where = "second"
      end
      util.log("rails: AI %s takes up its line to #%d again (%s program, line #%s)", force_name, center_un, where,
        tostring(P.line))
      return true
    end
  end
  return false
end

events.on_signal("rts_city_captured", function(d)
  if not (d and d.to and d.city_id and rails.nation()) then return end
  local cities = loaded("scripts.cities")
  local city = type(cities) == "table" and cities.get and cities.get(d.city_id)
  if city and city.center then rails.ai_revive(d.to, city.center) end
end)

---------------------------------------------------------------------------
-- Phase 5 M2 war: rolling stock back into kits (docs/PHASE5-M2.md section 3 "rails.disband_train")
---------------------------------------------------------------------------
--- Take a standing train apart: balance.nation.war.disband_share (50 %) of its kits (rounded to half of all its
--- carriages), its cargo and its coal go into the network of the depot whose platform it stands on, else its home
--- depot. Troops aboard get out first (rails.on_disband). Returns {kits = {[item] = n}, depot = un} or nil, reason
--- ("no-train" | "moving" | "no-depot").
function rails.disband_train(train, fallback)
  local rec = rails.train_record(train)
  if not (rec and train and train.valid) then return nil, "no-train" end
  if math.abs(train.speed) > 0.001 then return nil, "moving" end
  local R = rstate()
  local depot_un
  local front = train.front_stock
  local pos = front and front.valid and front.position
  if pos then
    for _, un in ipairs(sorted_keys(R.depots)) do
      local d = R.depots[un]
      local a = d.force == rec.force and d.entity.valid and d.platform and d.platform.area
      if a and pos.x >= a[1][1] - 4 and pos.x <= a[2][1] + 4 and pos.y >= a[1][2] - 4 and pos.y <= a[2][2] + 4 then
        depot_un = un
        break
      end
    end
  end
  if not depot_un and rails.depot(rec.home) then depot_un = rec.home end
  -- Phase 5 M2 integration: the AI scraps a train stranded on a lost line into a depot of its choice
  if not depot_un and fallback and rails.depot(fallback) then depot_un = fallback end
  local net = depot_un and logistics.hub_network(depot_un)
  if not net then return nil, "no-depot" end
  if rails.on_disband then rails.on_disband(rec, train) end
  local counts = {}
  for _, c in ipairs(train.carriages) do
    local kit = KIT_OF[c.name]
    if kit then counts[kit] = (counts[kit] or 0) + 1 end
  end
  -- cargo and coal back into the network
  local moved = 0
  for _, w in ipairs(train.cargo_wagons) do
    local inv = w.get_inventory(defines.inventory.cargo_wagon)
    for _, item in pairs(inv and inv.get_contents() or {}) do
      moved = moved + logistics.transfer(inv, net, item.name, item.count)
    end
  end
  for _, group in pairs({train.locomotives.front_movers, train.locomotives.back_movers}) do
    for _, loco in ipairs(group) do
      local inv = loco.get_fuel_inventory()
      local n = inv and inv.get_item_count(rails.FUEL) or 0
      if n > 0 then moved = moved + logistics.transfer(inv, net, rails.FUEL, n) end
    end
  end
  -- half of every kind, then up to half of all carriages from the kinds with the largest remainder
  local share = balance.nation.war.disband_share
  local back, total, got = {}, 0, 0
  local kits = sorted_keys(counts)
  for _, kit in ipairs(kits) do
    total = total + counts[kit]
    back[kit] = floor(counts[kit] * share)
    got = got + back[kit]
  end
  local want = floor(total * share + 0.5)
  while got < want do
    local best, br
    for _, kit in ipairs(kits) do
      local r = counts[kit] - back[kit]
      if r > 0 and (not br or r > br) then best, br = kit, r end
    end
    if not best then break end
    back[best] = back[best] + 1
    got = got + 1
  end
  local spilled = 0
  for _, kit in ipairs(kits) do
    if back[kit] > 0 then
      local put = net.insert({name = kit, count = back[kit]})
      if put < back[kit] then
        spilled = spilled + back[kit] - put
        front.surface.spill_item_stack({position = front.position, stack = {name = kit, count = back[kit] - put},
                                        enable_looted = false, allow_belts = false})
      end
    end
  end
  for _, line in pairs(R.lines) do
    if line.builder == train.id then line.builder = nil end
  end
  local id = train.id
  R.trains[id] = nil
  R.dwelling[id] = nil
  local parts = {}
  for _, kit in ipairs(kits) do parts[#parts + 1] = string.format("%d of %d %s", back[kit], counts[kit], kit) end
  util.log("rails: %s train %d (%s) disbanded at depot #%d: kits back [%s]%s, %d items of cargo and coal returned",
    rec.kind, id, rec.force, depot_un, table.concat(parts, ", "),
    spilled > 0 and string.format(" (%d spilled: the network had no room)", spilled) or "", moved)
  for _, c in ipairs(train.carriages) do
    if c.valid then c.destroy() end
  end
  return {kits = back, depot = depot_un}
end

---------------------------------------------------------------------------
-- AI hook (scripts/ai/commander.lua): a second hub or city >= ai_min_distance from the capital gets a depot at each
-- end, one line, one freight train (far depot -> capital), and both crews repair cuts. The AI pays the factory
-- recipes' ingredients from its capital's network at one recipe per AI_CRAFT_TICKS (products go to the depot that
-- needs them) instead of queueing factory work (the full planner is M3).
---------------------------------------------------------------------------
rails.AI_PERIOD = 600
rails.AI_CRAFT_TICKS = 300
rails.AI_REPAIR_RAILS = 60
rails.AI_EXPORT = 100
rails.AI_KEEP = 3000
rails.AI_PAY = true -- Phase 5 M3 ai: A.pay (a unit number, normally the capital's centre) pays a program's depots, kits and
                    -- rails instead of A.anchor (a trunk edge between two towns, ai/planner.lua); nil = A.anchor

local function ai_state(force_name)
  local R = rstate()
  local A = R.ai[force_name]
  if not A then
    A = {state = "idle"}
    R.ai[force_name] = A
  end
  return A
end

-- Phase 5 M1 integration: what an intermediate is made of, per item (balance.intermediates; steel from the smelter
-- recipe, balance.smelting). The AI pays a missing intermediate with its inputs (circuits were the rail program's
-- bottleneck: locomotive kits waited for them for half an hour while plates piled up).
local AI_EXPAND = {}
for _, def in pairs(balance.intermediates or {}) do
  local per = {}
  for item, amount in pairs(def.cost) do per[item] = amount / (def.count or 1) end
  AI_EXPAND[def.result] = per
end
for item, def in pairs(balance.smelting or {}) do
  local per = {}
  for ing, amount in pairs(def.cost) do per[ing] = amount end
  AI_EXPAND[item] = per
end
-- (steel paid as iron without a reserve starved an AI's army and repairs of plates and lost it its capital: an
-- expanded item's inputs keep AI_RESERVE_EXPANDED in the network)
-- What the AI's capital keeps for its own army and repairs: the rail program never takes it below this, and never
-- below the larger AI_RESERVE_EXPANDED for the inputs of an intermediate it pays as plates (circuits for a kit).
rails.AI_RESERVE = {["iron-plate"] = 40, ["copper-plate"] = 20, ["stone"] = 20}
rails.AI_RESERVE_EXPANDED = {["iron-plate"] = 150, ["copper-plate"] = 60}
-- Phase 5 M3 integration: a part payment into the escrow (ai_pay) leaves this much more for the barracks (m3-ai: the
-- walker and drone kits starve on copper first; 50 steel for the industrial kits: six AI depots paid in two minutes held
-- Electrification back, seed 802)
rails.AI_ESCROW_FLOOR = {["iron-plate"] = 60, ["copper-plate"] = 60, ["electronic-circuit"] = 20, ["steel-plate"] = 50}
-- Economy 0.1.1 (#1, #2, #7): rail crafts (ai_supplies: 1 steel and 1 stone for 2 rails, a line's whole bill ahead of
-- its crews) leave this much in the capital for the districts, bricks and concrete. Since 7248285 (more lines
-- finished) seeds 801-805 reached Age III by 40:00 in 3 of 5 instead of 5 of 5; in 802 rts-ai-3's capital held 0-45
-- stone from 30:00 while its crews loaded 2,109 rails, its Smelting and Steel works were never built and Space Program
-- stage 1 stood at 68 % (r2-ai's batches h1 and g2). Stone only, the shortage seen: 100 stone gave Age III by 40:00 in
-- 3 of 5 with phases by registration order and 2 of 5 with the name-based ones (events.lua; nations with three cities
-- linked by 35:00: 12 and 9 of 20). A steel keep too (100 steel, 150 stone) gave 4 of 5 but cost lines (7 and 8 of 20).
-- Five seeds do not resolve this; carried to 0.1.2 with #1 and #2. A kept item is never paid with its inputs (ai_bill).
rails.AI_RAIL_KEEP = {["stone"] = 100}

-- Raw goods to take from `pay` for `count` of `item` (an intermediate it lacks is paid with its inputs, 3 levels deep;
-- `taken` holds what earlier parts of the same payment already take). Returns false when the network cannot pay.
-- `keep` (optional, {[item] = n}): more to leave in the network for these items, and no expansion of them into their
-- inputs (rail crafts: rails.AI_RAIL_KEEP)
local function ai_bill(pay, item, count, taken, depth, keep)
  local reserve = depth > 0 and rails.AI_RESERVE_EXPANDED[item] or rails.AI_RESERVE[item] or 0
  if keep and keep[item] then reserve = reserve + keep[item] end
  local have = pay.get_item_count(item) - (taken[item] or 0) - reserve
  local use = math.min(math.max(0, have), count)
  if use > 0 then taken[item] = (taken[item] or 0) + use end
  local rest = count - use
  if rest <= 0 then return true end
  if keep and keep[item] then return false end
  local per = AI_EXPAND[item]
  if not per or depth >= 3 then return false end
  for ing, amount in pairs(per) do
    if not ai_bill(pay, ing, math.ceil(amount * rest - 1e-9), taken, depth + 1) then return false end
  end
  return true
end

-- Pay `n` crafts of a recipe's ingredients from network `pay` and put the products into network `put`. Returns true.
-- Phase 5 M3 integration: with `escrow` (a table kept by the caller) the craft is paid over several calls: what the
-- network can spare of each ingredient goes into the escrow until the bill is complete (40 iron, 10 steel and 10 copper
-- at one check starved the aggressive AI's depot kit while its capital held no copper for 7 minutes).
local function ai_pay(pay, put, recipe_name, n, escrow, no_floor, keep)
  local proto = prototypes.recipe[recipe_name]
  if not (proto and pay and pay.valid and put and put.valid) then return false end
  local taken = {}
  local complete, held = true, nil
  if escrow then
    held = escrow[recipe_name] or {}
    escrow[recipe_name] = held
  end
  for _, ing in ipairs(proto.ingredients) do
    local need = ing.amount * n - (held and held[ing.name] or 0)
    if need > 0 then
      local try = {}
      for k, v in pairs(taken) do try[k] = v end
      if ai_bill(pay, ing.name, need, try, 0, keep) then
        taken = try
        if held then held[ing.name] = (held[ing.name] or 0) + need end
      elseif held then
        -- what the network spares of it now (no sub-recipes), the rest at a later call
        -- (no_floor, Economy 0.1.1: a lost line's depot takes what the network holds, reserve and floor included: the
        -- player's capital held 2-51 iron from 30:00 to 50:00 in M1 501, and with the 40-iron reserve kept the kit had
        -- 20 of its 40 iron after 20 minutes)
        local reserve = no_floor and 0 or ((rails.AI_RESERVE[ing.name] or 0) + (rails.AI_ESCROW_FLOOR[ing.name] or 0))
        local have = pay.get_item_count(ing.name) - (taken[ing.name] or 0) - reserve
        local use = math.min(math.max(0, have), need)
        if use > 0 then
          taken[ing.name] = (taken[ing.name] or 0) + use
          held[ing.name] = (held[ing.name] or 0) + use
        end
        complete = false
      else
        return false
      end
    end
  end
  for item, count in pairs(taken) do pay.remove_item({name = item, count = count}) end
  if not complete then return false end
  if escrow then escrow[recipe_name] = nil end
  for _, prod in ipairs(proto.products) do
    if prod.type == "item" then put.insert({name = prod.name, count = (prod.amount or 1) * n}) end
  end
  return true
end

local function anchor_net(un)
  local rec = buildings.get(un)
  local net = rec and rec.entity.logistic_network
  return (net and net.valid) and net or nil
end

-- Phase 5 M1 integration: `reach` = the largest Chebyshev distance at which the depot's logistic area still touches
-- the anchor's (the depot then joins the anchor's network: freight loads and unloads straight into it); sites within
-- it are tried first, the rest of the ring after them. `prefer` (ai/towns.lua's reserved site) comes first of all.
local function find_depot_site(surface, force_name, center, reach, prefer)
  local function fits(p)
    return surface.can_place_entity({name = rails.DEPOT, position = p, force = force_name,
                                     build_check_type = MANUAL_GHOST, forced = true})
      and not covers_planned(surface.index, {{p.x - 2, p.y - 2}, {p.x + 2, p.y + 2}}, 3)
      and rails.platform_fits(surface, force_name, p) ~= nil
  end
  if prefer and fits(prefer) then return {x = prefer.x, y = prefer.y} end
  for pass = 1, reach and 2 or 1 do
    for r = 26, 74, 8 do
      for a = 0, 15 do
        local ang = a * math.pi / 8
        local p = {x = floor(center.x + r * math.cos(ang) + 0.5), y = floor(center.y + r * math.sin(ang) + 0.5)}
        local near = reach and math.max(math.abs(p.x - center.x), math.abs(p.y - center.y)) <= reach
        if (pass == 2 or not reach or near) and not (pass == 2 and near) and fits(p) then return p end
      end
    end
  end
  return nil
end

-- A depot next to `anchor_un`, paid from the capital's network (A.anchor): a new city's network is nearly empty.
-- Economy 0.1.1 (#7, #2): a depot of an AI line destroyed in a war is rebuilt on its old site (the line's pieces and the
-- platform rails still stand) once no enemy unit, vehicle or turret is within RESITE_CLEAR tiles of it; the program
-- then binds the line to it again (rails.ai_program). Before, a new depot went to the first free site of a ring
-- search (the old one never fitted: its own platform rails stood there), the intact line was given up and a new one
-- surveyed: M1 501 on 6bd9fe3, the player's 125-piece line #2 lost its capital depot at 28:00 and stayed lost, new
-- lines were surveyed at 51:00, and train_items fell to 9,435.
rails.RESITE_CLEAR = 40
local ENEMY_TYPES = {"unit", "spider-unit", "spider-vehicle", "car", "character", "ammo-turret", "electric-turret",
                     "fluid-turret", "artillery-turret", "turret"}
-- The nearest enemy unit, vehicle or turret within r tiles of pos, or nil.
local function enemies_near(surface, force_name, pos, r)
  local force = game.forces[force_name]
  if not force then return nil end
  local best, bd
  for _, e in ipairs(surface.find_entities_filtered({position = pos, radius = r, type = ENEMY_TYPES})) do
    if e.valid and e.force ~= force and force.is_enemy(e.force) then
      local d = util.distance(e.position, pos)
      if not bd or d < bd then best, bd = e, d end
    end
  end
  return best, bd
end

local function ai_depot(force_name, anchor_un, field, A)
  local un = A[field]
  if un and rails.depot(un) then return un end
  local anchor = buildings.get(anchor_un)
  local net = anchor_net(A.pay or A.anchor)
  if not (anchor and net) then return nil end
  local line = A.line and rstate().lines[A.line]
  local ld = line and line.state == "lost" and line.lost_depot
  local site = ld and un and ld.un == un and ld.x and ld.y and ld.spec and {x = ld.x, y = ld.y} or nil
  if net.get_item_count(rails.DEPOT) == 0 then
    if game.tick < (A.next_craft or 0) then return nil end
    A.escrow = A.escrow or {}
    -- (a lost line's depot reopens the whole line: its kit takes the network's spare goods first, ahead of the barracks'
    -- floor and reserve; the player's capital held 3-45 iron from 30:00 to 50:00 in M1 501 and the kit waited 21
    -- minutes for a peak)
    if not ai_pay(net, net, "rts-depot", 1, A.escrow, site ~= nil) then
      A.next_craft = game.tick + rails.AI_CRAFT_TICKS
      return nil
    end
    A.next_craft = game.tick + rails.AI_CRAFT_TICKS
  end
  -- (the kit is paid while the site waits for the enemies to leave)
  local foe, fd = nil, nil
  if site then foe, fd = enemies_near(anchor.entity.surface, force_name, site, rails.RESITE_CLEAR) end
  if foe then
    if A.why ~= "enemies" or game.tick >= (A.why_log or 0) then
      A.why_log = game.tick + 5 * 3600
      util.log("rails: AI %s waits to rebuild depot #%d of line #%d at %s: %s %s of %s %.0f tiles away", force_name, un,
        line.id, util.pos_str(site), foe.type, foe.name, foe.force.name, fd)
    end
    A.why = "enemies"
    return nil
  end
  local surface = anchor.entity.surface
  local radius = anchor.entity.prototype.logistic_radius or 0
  local depot_radius = prototypes.entity[rails.DEPOT].logistic_radius or 14
  local reach = radius > 0 and math.floor(radius + depot_radius - 2) or nil
  local pos
  if site and surface.can_place_entity({name = rails.DEPOT, position = site, force = force_name,
                                        build_check_type = MANUAL_GHOST, forced = true}) then
    pos = site
  else
    pos = find_depot_site(surface, force_name, anchor.entity.position, reach,
      field == "depot_b" and A.far_site or nil)
  end
  if not pos then
    if A.why ~= "no-site" then util.log("rails: AI %s finds no depot site near #%d", force_name, anchor_un) end
    A.why = "no-site"
    return nil
  end
  -- (and not while a line near the site is being surveyed: a few seconds; covers_planned sees its pieces afterwards)
  if near_survey(surface.index, pos, rails.SURVEY_CLEARANCE) then
    A.why = "survey"
    return nil
  end
  clear_area(surface, {{pos.x - 3, pos.y - 3}, {pos.x + 3, pos.y + 3}})
  net.remove_item({name = rails.DEPOT, count = 1})
  -- the new roboport may merge networks: the old LuaLogisticNetwork object is invalid afterwards
  -- (on the lost depot's site setup_depot takes the old platform: R.reuse_site, read while the depot registers)
  if pos == site then rstate().reuse_site = {x = site.x, y = site.y, spec = ld.spec, force = force_name} end
  local e = surface.create_entity({name = rails.DEPOT, position = pos, force = force_name, raise_built = true})
  rstate().reuse_site = nil
  if e and pos == site then
    util.log("rails: AI %s rebuilds depot #%d of line #%d on its old site %s as #%d", force_name, un, line.id,
      util.pos_str(site), e.unit_number)
  end
  if not e then
    local back = anchor_net(A.pay or A.anchor)
    if back then back.insert({name = rails.DEPOT, count = 1}) end
    return nil
  end
  net = anchor_net(A.pay or A.anchor)
  A[field] = e.unit_number
  local own = logistics.hub_network(e.unit_number)
  util.log("rails: AI %s placed depot #%d at %s next to #%d (%s network as the capital)", force_name, e.unit_number,
    util.pos_str(pos), anchor_un, (own and net and own.network_id == net.network_id) and "same" or "not the same")
  return e.unit_number
end

-- Make sure a depot network holds the kits of `kind`, paid from the anchor's network. True when they are there.
local function ai_kits(depot_un, anchor_un, kind, A)
  local net = logistics.hub_network(depot_un)
  if not net then return false end
  for _, k in ipairs(kit_list(kind)) do
    if net.get_item_count(k[1]) < k[2] then
      if game.tick < (A.next_craft or 0) then return false end
      A.escrow = A.escrow or {}
      ai_pay(anchor_net(anchor_un), net, k[1], 1, A.escrow) -- (paid over several calls: the escrow)
      A.next_craft = game.tick + rails.AI_CRAFT_TICKS
      return false
    end
  end
  return true
end

-- Rails (paid as rts-rail crafts) and coal for the depot network, from the anchor's network.
local function ai_supplies(depot_un, anchor_un, want_rails)
  local net = logistics.hub_network(depot_un)
  local pay = anchor_net(anchor_un)
  if not (net and pay) then return false end
  if net.network_id ~= pay.network_id and net.get_item_count(rails.FUEL) < 40 then
    logistics.transfer(pay, net, rails.FUEL, 40 - net.get_item_count(rails.FUEL))
  end
  local have = net.get_item_count(rails.RAIL)
  if have >= want_rails then return true end
  local crafts = min(25, math.ceil((want_rails - have) / CFG.rail.count))
  while crafts > 0 and not ai_pay(pay, net, "rts-rail", crafts, nil, nil, rails.AI_RAIL_KEEP) do crafts = floor(crafts / 2) end
  return false
end

--- One step of the AI rail program for a force. A = {anchor = capital hub/CC un, far = far hub un, ...}.
function rails.ai_program(force_name, A)
  local R = rstate()
  local anchor_rec, far_rec = buildings.get(A.anchor), buildings.get(A.far)
  -- Phase 5 M2 integration: both ends must be the force's own (a far city may change hands)
  if not (anchor_rec and far_rec and anchor_rec.force == force_name and far_rec.force == force_name) then
    A.state = "idle"
    return
  end
  if A.pay and not buildings.get(A.pay) then A.pay = nil end -- Phase 5 M3 ai
  local da = ai_depot(force_name, A.anchor, "depot_a", A)
  local db = da and ai_depot(force_name, A.far, "depot_b", A)
  if not (da and db) then
    A.state = "depots"
    return
  end
  local line = A.line and R.lines[A.line]
  -- Phase 5 M2 integration: a lost line whose missing depot stood where this program's depot stands now (rebuilt on the
  -- same site) is bound to it again; any other lost line is re-planned
  if line and line.state == "lost" then
    local ld = line.lost_depot
    -- the new depot's platform lies on the old one's track (the line's last piece joins it), not merely nearby
    local function near(un)
      local nd = rails.depot(un)
      local e = nd and nd.entity
      local ns = nd and nd.platform and nd.platform.spec
      return ld and ld.x and ld.spec and e and e.valid and ns and math.abs(e.position.x - ld.x) <= 3
        and math.abs(e.position.y - ld.y) <= 3 and ns.axis == ld.spec.axis and ns.track == ld.spec.track
    end
    local rebound
    if ld and ld.un == line.b and line.a == da and db ~= ld.un and near(db) and not rails.depot(db).line then
      line.b, rebound = db, db
    elseif ld and ld.un == line.a and line.b == db and da ~= ld.un and near(da) and not rails.depot(da).line then
      line.a, rebound = da, da
    end
    if rebound and rails.depot(da) and rails.depot(db) then
      rails.depot(da).line, rails.depot(db).line = line.id, line.id
      line.state, line.lost_depot, line.wait = line.opened and "cut" or "building", nil, nil
      util.log("rails: AI %s binds line #%d to its new depot #%d", force_name, line.id, rebound)
      -- Economy 0.1.1 (#7, #2): its freight trains still head for the dead depot's stop: routed to the new one
      for _, id in ipairs(sorted_keys(R.trains)) do
        local trec = R.trains[id]
        if trec and trec.force == force_name and trec.kind == "cargo" and trec.ai_line == line.id then
          local train = train_of(trec)
          if train and train.valid and rails.set_route(train, db, da) then
            util.log("rails: AI %s routes freight train %d on line #%d again (depot #%d)", force_name, train.id, line.id,
              rebound)
          end
        end
      end
    else
      -- its freight trains stand without a route on the old track and block the new line's crews: scrapped into the
      -- capital-side depot (half of the kits back, like the train panel's Disband)
      local old_id = line.id
      for _, id in ipairs(sorted_keys(R.trains)) do
        local trec = R.trains[id]
        if trec and trec.force == force_name and trec.kind == "cargo" and trec.ai_line == old_id
           and not (trec.pickup and trec.dropoff) then
          local train = train_of(trec)
          local ok, why = false, "gone"
          if train and train.valid then ok, why = rails.disband_train(train, da) end
          util.log("rails: AI %s scraps freight train %d of lost line #%d (%s)", force_name, id, old_id,
            ok and "kits back" or tostring(why))
        end
      end
      A.line, line = nil, nil
    end
  end
  if not line or line.state == "failed" then
    if line and line.state == "failed" then
      -- Phase 5 M3 integration: a failed survey between the same depots fails again: back off 2, 4, 8, 16 minutes
      -- (the same pair of depots was surveyed every 2 minutes for 30 minutes at 4 ms a tick, seed 702)
      if not A.failed_line or A.failed_line ~= A.line then
        A.failed_line, A.fails = A.line, (A.fails or 0) + 1
        A.retry = game.tick + 60 * 60 * 2 ^ math.min(A.fails, 4)
        util.log("rails: AI %s line #%d failed (%d in a row): next survey in %d s", force_name, A.line, A.fails,
          (A.retry - game.tick) / 60)
      end
      if game.tick < (A.retry or 0) then return end
      R.lines[A.line] = nil
      local d1, d2 = rails.depot(da), rails.depot(db)
      if d1 then d1.line = nil end
      if d2 then d2.line = nil end
    end
    A.line = rails.plan_line(force_name, da, db)
    A.retry = game.tick + 60 * 60
    A.state = "survey"
    return
  end
  if line.state == "surveying" then return end
  if line.state == "building" or line.state == "cut" then
    A.state = line.state
    -- a crew at the capital end (and one at the far end once the line has opened once) with rails for the work
    ai_kits(da, A.pay or A.anchor, "construction", A)
    ai_supplies(da, A.pay or A.anchor, line.state == "building" and (line.bill.rails + 20) or rails.AI_REPAIR_RAILS)
    if line.opened then
      ai_kits(db, A.pay or A.anchor, "construction", A)
      ai_supplies(db, A.pay or A.anchor, rails.AI_REPAIR_RAILS)
    end
    return
  end
  if line.state == "open" then
    A.fails, A.failed_line = nil, nil -- Phase 5 M3 integration: the backoff ends with an open line
    A.state = "open"
    if not A.policies then
      for _, item in ipairs({"iron-plate", "copper-plate", "steel-plate"}) do
        logistics.set_policy(db, "export_above", item, rails.AI_EXPORT)
        logistics.set_policy(da, "keep", item, rails.AI_KEEP)
      end
      A.policies = true
    end
    local have
    for _, rec in pairs(R.trains) do
      if rec.kind == "cargo" and rec.force == force_name and rec.ai_line == A.line then have = rec end
    end
    -- Phase 5 M2 integration: the freight train of a line taken up again stood "depot-lost" without a route
    if have and not (have.pickup and have.dropoff) then
      local train = train_of(have)
      if train and train.valid then
        rails.set_route(train, db, da)
        util.log("rails: AI %s routes freight train %d on line #%d again", force_name, train.id, A.line)
      else
        have = nil
      end
    end
    if not have then
      if ai_kits(db, A.pay or A.anchor, "cargo", A) then
        local train = rails.create_train(db, "cargo")
        if train then
          local rec = rails.train_record(train)
          rec.ai_line = A.line
          rails.set_route(train, db, da)
          util.log("rails: AI %s runs freight train %d on line #%d", force_name, train.id, A.line)
        end
      end
    end
    -- spare crew and rails for repairs at both ends
    ai_kits(db, A.pay or A.anchor, "construction", A)
    ai_supplies(da, A.pay or A.anchor, rails.AI_REPAIR_RAILS)
    ai_supplies(db, A.pay or A.anchor, rails.AI_REPAIR_RAILS)
  end
end

--- logistics.lua hook: a cargo train of the force runs from a depot in network `src_id` to one in `home_id` on an
--- open line (auto haulers then leave that source to the train).
logistics.served_by_train = function(force_name, src_id, home_id)
  local R = storage.rails
  if not (R and next(R.trains)) then return false end
  for _, rec in pairs(R.trains) do
    if rec.kind == "cargo" and rec.force == force_name and rec.pickup and rec.dropoff then
      local a, b = logistics.hub_network(rec.pickup), logistics.hub_network(rec.dropoff)
      local line = rec.line and R.lines[rec.line]
      if a and b and a.network_id == src_id and b.network_id == home_id and (not line or line.state == "open") then
        return true
      end
    elseif rec.stops and rec.force == force_name and rails.routes and rails.routes.serves(rec, src_id, home_id) then
      return true -- 0.1.2 (#31 part B): a stop list that loads in the source network and unloads at home
    end
  end
  return false
end

--- The AI rail program's state for a force: "idle" | "depots" | "survey" | "building" | "cut" | "open" (ai/age_up.lua
--- saves plates for it).
function rails.ai_program_state(force_name)
  local R = storage.rails
  local A = R and R.ai and R.ai[force_name]
  return A and A.state or "idle"
end

--- ai/towns.lua: the depot site it reserved next to the AI's mining town (the far end of its line).
function rails.ai_set_far_site(force_name, position)
  local A = ai_state(force_name)
  A.far_site = {x = position.x, y = position.y}
  util.log("rails: AI %s far depot site %s (town)", force_name, util.pos_str(position))
end

--- AI commander hook (ai/commander.lua, every run): Nation mode only, every AI_PERIOD ticks.
function rails.ai_step(C)
  if not rails.nation() then return end
  local A = ai_state(C.force)
  if game.tick < (A.next or 0) then return end
  A.next = game.tick + rails.AI_PERIOD
  -- Phase 5 M2 integration: second programs (lines taken up again after a city came back) run beside the main one
  local R0 = storage.rails
  local more = R0.ai_more and R0.ai_more[C.force]
  local used_far = {}
  for i = #(more or {}), 1, -1 do
    local P = more[i]
    if buildings.get(P.anchor) and buildings.get(P.far) then
      used_far[P.far] = true
      rails.ai_program(C.force, P)
    else
      table.remove(more, i)
    end
  end
  if not (A.anchor and buildings.get(A.anchor) and A.far and buildings.get(A.far)) then
    local cc, cc_un = buildings.main_cc(C.force)
    local cities = loaded("scripts.cities")
    if type(cities) == "table" and cities.get and storage.nations and storage.nations[C.force] then
      local ok, city = pcall(cities.get, storage.nations[C.force].capital)
      if ok and city and city.center and buildings.get(city.center) then cc, cc_un = buildings.get(city.center), city.center end
    end
    if not cc then return end
    local best, bd
    -- Phase 5 M1 integration: a City Center (the AI's mining town, ai/towns.lua) before any hub; with a reserved far
    -- depot site, the hub or City Center nearest to it
    local function rank(un, rec)
      local d = util.distance(rec.entity.position, cc.entity.position)
      if A.far_site then return util.distance(rec.entity.position, A.far_site), d end
      local city = type(cities) == "table" and cities.of_center and cities.of_center(un)
      return d + (city and 0 or 100000), d
    end
    local best_rank
    for un, rec in buildings.for_force(C.force) do
      if (rec.kind == "hub" or rec.kind == "cc") and un ~= cc_un and not rails.depot(un) and not used_far[un]
         and rec.entity.name ~= "rts-trade-post" -- Phase 5 M2 treasury: a captured port is no city to connect
         and rec.entity.surface == cc.entity.surface then
        local r, d = rank(un, rec)
        if d >= CFG.ai_min_distance and (not best_rank or r < best_rank) then best, bd, best_rank = un, d, r end
      end
    end
    if not best then return end
    A.anchor, A.far = cc_un, best
    util.log("rails: AI %s plans a line from #%d to #%d (%.0f tiles)", C.force, cc_un, best, bd)
  end
  rails.ai_program(C.force, A)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
events.on(defines.events.on_tick, function()
  local R = storage.rails
  if not (R and next(R.jobs)) then return end
  local prof = R.profile_survey and helpers.create_profiler() or nil
  -- one survey at a time, oldest first (Phase 5 M3 perf: scheduler jobs run in scripts/sched.lua, not here)
  local id
  for _, k in ipairs(sorted_keys(R.jobs)) do
    if not R.jobs[k].sched then
      id = k
      break
    end
  end
  if not id then
    if prof then prof.stop() end
    return
  end
  local job = R.jobs[id]
  local phase = job.phase
  survey_tick(job)
  if prof then
    prof.stop()
    log({"", string.format("[rts] rails survey tick %d job %d %s: ", game.tick, id, phase), prof,
         string.format(" expanded %d checks %d", job.expanded, job.checks)})
  end
end)

events.on_nth_tick(rails.TRANSFER_PERIOD, function()
  local R = storage.rails
  if R and rails.routes then rails.routes.tick() end -- 0.1.2 (#31 part B): trains on a stop list at their stops
  if not (R and next(R.dwelling)) then return end
  for _, id in ipairs(sorted_keys(R.dwelling)) do
    local rec = R.trains[id]
    local train = rec and train_of(rec)
    if not (rec and rec.dwell and train and train.state == TS.wait_station) then
      R.dwelling[id] = nil
      if rec then rec.dwell = nil end
    elseif rec.kind == "troop" then -- Phase 5 M2 war: troops board and leave by scripts/garrison.lua
      if rails.troop_dwell then rails.troop_dwell(rec, train) end
    else
      dwell_step(rec, train)
    end
  end
end)

events.on_nth_tick(rails.STEP, function()
  local R = storage.rails
  if not (R and next(R.trains)) then return end
  for _, id in ipairs(sorted_keys(R.trains)) do
    local rec = R.trains[id]
    if rec then train_step(id, rec) end
  end
end)

events.on_nth_tick(rails.CHECK_PERIOD, function()
  local R = storage.rails
  if not (R and next(R.lines)) then return end
  check_lines()
  -- stops of depots that lost one (destroyed) come back
  for _, un in ipairs(sorted_keys(R.depots)) do
    local d = R.depots[un]
    if d.platform and d.platform.spec and d.entity.valid then
      for _, st in pairs(d.platform.stops) do
        if not st.valid then
          place_stops(d, d.platform.spec)
          break
        end
      end
    end
  end
end)

events.on(defines.events.on_train_changed_state, function(e)
  local R = storage.rails
  if not R then return end
  local train = e.train
  local rec = R.trains[train.id]
  if not rec then return end
  if rec.stops then return end -- 0.1.2 (#31 part B): scripts/railroutes.lua handles trains on a stop list
  if e.old_state == TS.wait_station and rec.dwell then
    rec.dwell = nil
    R.dwelling[train.id] = nil
  end
  if train.state == TS.wait_station then
    local st = train.station
    local dun = st and st.valid and R.stops[st.unit_number]
    if dun then
      if FREIGHT[rec.kind] then -- Phase 5 M2 war: troop trains dwell like freight trains
        local role = (dun == rec.pickup and "pickup") or (dun == rec.dropoff and "dropoff") or "other"
        rec.dwell = {depot = dun, role = role, since = game.tick}
        R.dwelling[train.id] = true
        rec.state = role == "pickup" and "loading" or (role == "dropoff" and "unloading" or rec.state)
        if rec.leg then
          util.log("rails: train %d (%s) at depot #%d (%s) after %.1f s", train.id, rec.force, dun, role,
            (game.tick - rec.leg) / 60)
        end
        refuel(train, logistics.hub_network(dun))
      elseif rec.kind == "construction" and rec.state == "returning" and dun == rec.home then
        rec.arrived = true
      end
    end
  elseif train.state == TS.no_path and rec.state ~= "no_path" then
    rec.leg_to = rec.state == "to_dropoff" and 2 or 1
    rec.state = "no_path"
    util.log("rails: train %d (%s) %s: no path", train.id, rec.force, rec.kind)
  elseif train.state == TS.on_the_path and rec.state == "no_path" then
    rec.state = rec.leg_to == 2 and "to_dropoff" or "to_pickup"
  end
end)

events.on(defines.events.on_train_created, function(e)
  local R = storage.rails
  if not R then return end
  for _, old in ipairs({e.old_train_id_1, e.old_train_id_2}) do
    local rec = old and R.trains[old]
    if rec and rec.loco and rec.loco.valid and rec.loco.train and rec.loco.train.id == e.train.id then
      R.trains[old] = nil
      R.trains[e.train.id] = rec
      rec.id = e.train.id
      if R.dwelling[old] then
        R.dwelling[old] = nil
        R.dwelling[e.train.id] = true
      end
    end
  end
end)

local function on_rail_gone(entity)
  local R = storage.rails
  if not R then return end
  local idx = R.index[entity.surface.index]
  local v = idx and idx[pkey(entity.name, entity.position.x, entity.position.y, entity.direction)]
  if not v then return end
  if v < 0 then
    -- a platform rail: leave a ghost for the depot's robots
    entity.surface.create_entity({name = "entity-ghost", inner_name = entity.name, position = entity.position,
                                  direction = entity.direction, force = entity.force})
    return
  end
  local line = R.lines[floor(v / 100000)]
  if line and line.pieces then piece_missing(line, v % 100000, true) end
end

events.on(defines.events.on_entity_died, function(e)
  local entity = e.entity
  if not (entity and entity.valid) then return end
  local name = entity.name
  if RAIL_SET[name] then
    on_rail_gone(entity)
  elseif STOCK_SET[name] then
    local R = storage.rails
    local rec = R and entity.train and R.trains[entity.train.id]
    if rec then
      local stats = rails.stats(rec.force)
      util.log("rails: %s of train %d (%s, %s) destroyed at %s by %s", name, entity.train.id, rec.force, rec.kind,
        util.pos_str(entity.position), e.cause and e.cause.valid and e.cause.name or "unknown")
      if name == rails.LOCO or name == rails.ALOCO then -- Phase 5 M3 war2: armoured locomotives too
        stats.lost = stats.lost + 1
        alert(rec.force, "train-lost", entity.position, "rts.alert-train-lost")
      end
      if rails.on_stock_died then rails.on_stock_died(rec, entity, e.cause) end -- Phase 5 M2 war: troop manifests
    end
  end
end)

local function on_built_rail(e)
  local entity = e.entity or e.destination
  if not (entity and entity.valid and RAIL_SET[entity.name]) then return end
  local R = storage.rails
  local idx = R and R.index[entity.surface.index]
  local v = idx and idx[pkey(entity.name, entity.position.x, entity.position.y, entity.direction)]
  if not v or v < 0 then return end
  local line = R.lines[floor(v / 100000)]
  local p = line and line.pieces and line.pieces[v % 100000]
  if p and not (p.e and p.e.valid) then
    p.e, p.g = entity, nil
    line.missing = line.missing - 1
    line.robot = line.robot + p.rails
    line.used = line.used + p.rails
  end
end
events.on(defines.events.on_robot_built_entity, on_built_rail)

match.on_teardown(function()
  local R = rstate()
  for _, rec in pairs(R.trains) do
    for _, e in ipairs(rec.stock or {}) do
      if e.valid then e.destroy() end
    end
  end
  R.depots, R.lines, R.jobs, R.trains, R.dwelling, R.index, R.stops, R.stats, R.ai = {}, {}, {}, {}, {}, {}, {}, {}, {}
  R.ai_more, R.ai_lost = nil, nil -- Phase 5 M2 integration
  R.depot_index = {}
  R.test_nation, R.test_bridges, R.test_forces = nil, nil, nil
  for _, p in pairs(game.players) do station_names(p, true) end -- Phase 5 M3 integration
  bind()
end)

function rails.init()
  rstate()
  learn_geometry()
  bind()
end

events.on_load(bind)

---------------------------------------------------------------------------
-- Headless autotest (docs/PHASE5-M1.md section 4, Rails). Off unless rails.AUTOTEST_DEFAULT is true (test copies:
-- tools/probes/rails_autotest.lua) or storage.debug.rails_autotest is set. It runs beside the Skirmish AI autotest on
-- its own surface (vanilla terrain: trees, cliffs, ore, water) with the non-participating forces rts-ai-3 (lines) and
-- rts-ai-2 (AI program), in Nation rules (storage.rails.test_nation). Log lines "[rts] rails autotest ...".
---------------------------------------------------------------------------
rails.AUTOTEST_DEFAULT = false
rails.AUTOTEST_START = 300         -- ticks after the match runs before the test starts
rails.AUTOTEST_STAGES = nil        -- test copies may limit the stages: {"main", "bridge", "ai"}
local AT = {
  surface = "rts-railtest",
  force = "rts-ai-3",
  ai_force = "rts-ai-2",
  seed = 4242,
  a = {x = 0, y = 0}, b = {x = 800, y = 0},
  lake = {{340, -150}, {460, 150}},           -- water across the straight line
  foreign = {{180, -6}, {196, 6}},            -- a block of foreign buildings on the straight line
  iron = 9000, keep = 6000, deliver = 4000, coal = 400,
  survey_limit = 10 * 60, deliver_window = 180 * 60, repair_limit = 60 * 60, resume_limit = 60 * 60,
  bridge_a = {x = 0, y = 400}, bridge_b = {x = 320, y = 400}, band = {{120, 250}, {190, 560}},
  ai_anchor = {x = 0, y = -420}, ai_far = {x = 420, y = -420},
  -- chunk boxes generated per stage, in tiles
  gen_main = {{-128, -256}, {928, 256}}, gen_bridge = {{-96, 224}, {416, 576}}, gen_ai = {{-128, -544}, {576, -288}},
  -- Nation hauler rules: a hub pair 220 tiles apart
  gen_hauler = {{-96, 640}, {352, 800}}, hauler_s = {x = 0, y = 720}, hauler_t = {x = 220, y = 720},
  hauler_u = {x = 220, y = 770},              -- a hub without coal: its hauler must raise one "no fuel" alert
}

rails.AUTOTEST_CONFIG = AT -- test copies (tools/probes) may move the depots or the lake

-- Every test position sits AT_SHIFT tiles east of the numbers above: ai/hubs.lua compares positions of buildings on
-- any surface, so test depots near (0, 0) made the Skirmish AI's central ore patches look taken. Applied once per load
-- on first use, after the probes (loaded later) changed the table.
local AT_SHIFT = 3000
local at_shifted = false
local function at_shift()
  if at_shifted then return end
  at_shifted = true
  local function move(p)
    if p.x then p.x = p.x + AT_SHIFT else p[1] = p[1] + AT_SHIFT end
  end
  for _, k in ipairs({"a", "b", "bridge_a", "bridge_b", "ai_anchor", "ai_far", "hauler_s", "hauler_t", "hauler_u"}) do
    move(AT[k])
  end
  for _, k in ipairs({"lake", "foreign", "band", "gen_main", "gen_bridge", "gen_ai", "gen_hauler"}) do
    move(AT[k][1])
    move(AT[k][2])
  end
end

local function at_enabled()
  local d = storage.debug
  if not (d and d.autotest) then return false end
  if d.rails_autotest ~= nil then return d.rails_autotest end
  return rails.AUTOTEST_DEFAULT
end

local function at_check(T, name, ok, fmt, ...)
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("rails autotest check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function stage_on(name)
  if not rails.AUTOTEST_STAGES then return true end
  for _, s in ipairs(rails.AUTOTEST_STAGES) do
    if s == name then return true end
  end
  return false
end

local function at_surface()
  local s = game.surfaces[AT.surface]
  if s then return s end
  local mgs = game.surfaces.nauvis.map_gen_settings -- a fresh table on every read
  mgs.seed = AT.seed
  mgs.no_enemies_mode = true
  mgs.peaceful_mode = true
  mgs.width, mgs.height = 0, 0
  mgs.cliff_settings = {name = "cliff", cliff_elevation_0 = 10, cliff_elevation_interval = 40, richness = 1}
  s = game.create_surface(AT.surface, mgs)
  s.always_day = true
  return s
end

local function at_generate(s, box)
  local prof = helpers.create_profiler()
  local n = 0
  for cx = floor(box[1][1] / 32), floor((box[2][1] - 1) / 32) do
    for cy = floor(box[1][2] / 32), floor((box[2][2] - 1) / 32) do
      s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
      n = n + 1
    end
  end
  s.force_generate_chunk_requests()
  prof.stop()
  log({"", string.format("[rts] rails autotest: %d chunks generated in ", n), prof})
  return s
end

local function at_ground(s, center, hw, hh)
  local area = {{center.x - hw, center.y - hh}, {center.x + hw, center.y + hh}}
  local tiles = {}
  for x = area[1][1], area[2][1] - 1 do
    for y = area[1][2], area[2][2] - 1 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  s.set_tiles(tiles, true, true, true, false)
  for _, e in ipairs(s.find_entities_filtered({area = area})) do
    if e.valid and e.type ~= "character" then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
end

local function at_water(s, box)
  local tiles = {}
  for x = box[1][1], box[2][1] - 1 do
    for y = box[1][2], box[2][2] - 1 do tiles[#tiles + 1] = {name = "water", position = {x, y}} end
  end
  s.set_tiles(tiles, true, true, true, false)
  return #tiles
end

local function at_depot(s, force, pos, stockpiles)
  at_ground(s, pos, 34, 30)
  local e = s.create_entity({name = rails.DEPOT, position = pos, force = force, raise_built = true})
  if not e then return nil end
  for i = 1, stockpiles or 0 do
    local sp = s.find_non_colliding_position("rts-stockpile", {pos.x - 10 + i * 2, pos.y - 5}, 8, 1, true)
    local st = sp and s.create_entity({name = "rts-stockpile", position = sp, force = force, raise_built = true})
    if st then buildings.register(st) end
  end
  return e
end

local function at_fill(un, items)
  local net = logistics.hub_network(un)
  if not net then return 0 end
  local n = 0
  for name, count in pairs(items) do n = n + net.insert({name = name, count = count}) end
  return n
end

local function at_setup(T)
  local R = rstate()
  R.test_nation = true
  R.test_forces = {[AT.force] = true, [AT.ai_force] = true} -- logistics.lua: Nation hauler rules for these only
  local s = at_surface()
  at_generate(s, AT.gen_main)
  T.surface = s.index
  for _, f in ipairs({AT.force, AT.ai_force}) do
    if not game.forces[f] then game.create_force(f) end
  end
  local box = {AT.gen_main[1], AT.gen_main[2]}
  util.log("rails autotest: terrain %s-%s: %d trees, %d rocks, %d cliffs, %d ore entities, %d water tiles (before the lake)",
    util.pos_str(box[1]), util.pos_str(box[2]), s.count_entities_filtered({area = box, type = "tree"}),
    s.count_entities_filtered({area = box, type = "simple-entity"}), s.count_entities_filtered({area = box, type = "cliff"}),
    s.count_entities_filtered({area = box, type = "resource"}),
    s.count_tiles_filtered({area = box, collision_mask = "water_tile"}))
  -- probe: does the planner's check (manual_ghost + forced) let a rail over a cliff? (the builder blows cliffs up)
  for _, c in ipairs(s.find_entities_filtered({area = box, type = "cliff", limit = 3})) do
    local x, y = 2 * floor(c.position.x / 2) + 1, 2 * floor(c.position.y / 2) + 1
    util.log("rails autotest: cliff %s at %s: straight rail at (%d, %d) manual_ghost+forced=%s manual=%s", c.name,
      util.pos_str(c.position), x, y,
      tostring(s.can_place_entity({name = "straight-rail", position = {x, y}, direction = D.east, force = AT.force,
                                   build_check_type = MANUAL_GHOST, forced = true})),
      tostring(s.can_place_entity({name = "straight-rail", position = {x, y}, direction = D.east, force = AT.force,
                                   build_check_type = MANUAL})))
  end
  local water = at_water(s, AT.lake)
  -- foreign buildings across the straight line
  local fo = 0
  for x = AT.foreign[1][1], AT.foreign[2][1], 3 do
    for y = AT.foreign[1][2], AT.foreign[2][2], 3 do
      if s.create_entity({name = "stone-furnace", position = {x, y}, force = AT.ai_force}) then fo = fo + 1 end
    end
  end
  local A = at_depot(s, AT.force, AT.a, 4)
  local B = at_depot(s, AT.force, AT.b, 4)
  if not (A and B and rails.depot(A.unit_number) and rails.depot(B.unit_number)) then
    at_check(T, "rails_setup", false, "depots could not be placed (A %s, B %s)", tostring(A), tostring(B))
    T.stage = "done"
    return
  end
  T.A, T.B = A.unit_number, B.unit_number
  local da, db = rails.depot(T.A), rails.depot(T.B)
  logistics.set_policy(T.A, "export_above", "iron-plate", 0)
  logistics.set_policy(T.B, "keep", "iron-plate", AT.keep)
  local put = at_fill(T.A, {["iron-plate"] = AT.iron, coal = AT.coal, [rails.LOCO_KIT] = 4, [rails.WAGON_KIT] = 2,
                            [rails.CWAGON_KIT] = 1, [rails.RAIL] = 1400})
  at_fill(T.B, {coal = AT.coal, [rails.LOCO_KIT] = 2, [rails.CWAGON_KIT] = 1, [rails.RAIL] = 200})
  at_check(T, "rails_depot_composite", da.platform ~= nil and db.platform ~= nil and #da.platform.rails == 20
    and #da.platform.stops == 2 and #db.platform.stops == 2 and buildings.get(T.A).kind == "hub"
    and logistics.policy(T.A).keep.coal == 50 and logistics.policy(T.A).keep["copper-plate"] == nil,
    "depot A #%d platform %s%+d (%d rails, %d stops), depot B #%d platform %s, kind %s, keep %s, %d items stocked; "
    .. "lake %d water tiles, %d foreign furnaces", T.A, da.platform and da.platform.axis or "-",
    da.platform and da.platform.side or 0, da.platform and #da.platform.rails or 0,
    da.platform and #da.platform.stops or 0, T.B, db.platform and db.platform.axis or "-",
    tostring(buildings.get(T.A) and buildings.get(T.A).kind), serpent.line(logistics.policy(T.A).keep), put, water, fo)
  R.profile_survey = true
  T.line = rails.plan_line(AT.force, T.A, T.B)
  T.t_survey = game.tick
  T.stage = "survey"
end

local function at_main(T, tick)
  local R = rstate()
  local line = T.line and R.lines[T.line]
  if T.stage == "survey" then
    if not line then
      at_check(T, "rails_survey", false, "plan_line refused")
      T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
      return
    end
    if line.state ~= "surveying" then
      R.profile_survey = nil
      local secs = (tick - T.t_survey) / 60
      local sv = line.survey or {}
      at_check(T, "rails_survey", line.state == "building" and tick - T.t_survey <= AT.survey_limit,
        "state %s after %.1f s (limit %.0f s): %d pieces, %.0f tiles for %.0f straight, bill %d rails (%d supports, "
        .. "%d signals), %d expansions, %d checks, %d cells, corridor %d", line.state, secs, AT.survey_limit / 60,
        line.pieces and #line.pieces or 0, line.length or 0, util.distance(AT.a, AT.b), line.rails or 0,
        line.bill and line.bill.supports or 0, line.bill and line.bill.signals or 0, sv.expanded or 0, sv.checks or 0,
        sv.cells or 0, sv.corridor or 0)
      -- the route avoids the lake and the foreign block
      local wet, foreign = 0, 0
      for _, p in ipairs(line.pieces or {}) do
        if p.x >= AT.lake[1][1] and p.x < AT.lake[2][1] and p.y >= AT.lake[1][2] and p.y < AT.lake[2][2] then wet = wet + 1 end
        if p.x >= AT.foreign[1][1] - 2 and p.x <= AT.foreign[2][1] + 2 and p.y >= AT.foreign[1][2] - 2
           and p.y <= AT.foreign[2][2] + 2 then foreign = foreign + 1 end
      end
      at_check(T, "rails_route_avoids", (line.pieces ~= nil) and wet == 0 and foreign == 0,
        "%d pieces in the lake, %d in the foreign block", wet, foreign)
      if line.state ~= "building" then
        T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
        return
      end
      T.t_build = tick
      T.stage = "build"
    end
  elseif T.stage == "build" then
    if (tick - T.t_build) % 1200 == 0 then
      util.log("rails autotest: building %.0f s: line %s, %d of %d pieces missing, builder %s, wait %s",
        (tick - T.t_build) / 60, line.state, line.missing, #line.pieces, tostring(line.builder), tostring(line.wait))
    end
    if line.state == "open" then
      local net_used = line.loaded - line.returned + line.robot
      local dev = line.bill.rails > 0 and abs(net_used - line.bill.rails) / line.bill.rails or 1
      at_check(T, "rails_line_built", dev <= 0.05,
        "open after %.0f s: %d pieces, rails used %d (net from depots %d = loaded %d - returned %d + robots %d) "
        .. "vs bill %d: %.1f %%", (tick - T.t_build) / 60, #line.pieces, line.used, net_used, line.loaded,
        line.returned, line.robot, line.bill.rails, dev * 100)
      T.stage = "deploy"
    elseif tick - T.t_build > 8 * 60 * 60 then
      at_check(T, "rails_line_built", false, "not open after 8 min (%d missing, wait %s)", line.missing,
        tostring(line.wait))
      T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
    end
  elseif T.stage == "deploy" then
    if line.builder then return end -- the crew is still on its way home
    local train, why = rails.create_train(T.A, "cargo")
    if not train then
      if tick - T.t_build > 10 * 60 * 60 then
        at_check(T, "rails_deliver", false, "no freight train: %s", tostring(why))
        T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
      end
      return
    end
    T.train = train.id
    T.trec = rails.train_record(train)
    rails.set_route(train, T.A, T.B)
    T.t_deliver = tick
    T.stage = "deliver"
  elseif T.stage == "deliver" then
    local rec = T.trec
    local iron = rec.delivered["iron-plate"] or 0
    if iron >= AT.deliver then
      local B = logistics.hub_network(T.B)
      at_check(T, "rails_deliver", tick - T.t_deliver <= AT.deliver_window,
        "%d iron delivered %.0f s after the train left (window %.0f s); depot B holds %d", iron,
        (tick - T.t_deliver) / 60, AT.deliver_window / 60, B and B.get_item_count("iron-plate") or -1)
      -- a second trip to cut the line under
      logistics.set_policy(T.B, "keep", "iron-plate", AT.iron + 1000)
      T.delivered1 = iron
      T.stage = "cut_wait"
    elseif tick - T.t_deliver > AT.deliver_window + 60 * 60 then
      at_check(T, "rails_deliver", false, "only %d iron after %.0f s (state %s, reason %s)", iron,
        (tick - T.t_deliver) / 60, tostring(rec.state), tostring(rec.reason))
      T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
    end
  elseif T.stage == "cut_wait" then
    local rec = T.trec
    local train = train_of(rec)
    if not train then
      T.stage = "bridge_setup"
      return
    end
    -- cut 3 pieces at 60 % of the line once the loaded train is a fifth of the way out
    if rec.state == "to_dropoff" and next(cargo_of(train)) then
      local i = line_index_at(line, train.front_stock.position) or 0
      if i >= floor(#line.pieces * 0.2) then
        local c = floor(#line.pieces * 0.6)
        local killed = 0
        for j = c, c + 2 do
          local p = line.pieces[j]
          if p.e and p.e.valid and p.e.die() then killed = killed + 1 end
        end
        T.t_cut = tick
        T.cut_alerts = #(storage.alerts or {})
        util.log("rails autotest: cut %d rails at pieces %d..%d while train %d is at piece %d", killed, c, c + 2,
          train.id, i)
        T.stage = "cut"
      end
    elseif tick - T.t_deliver > AT.deliver_window * 2 then
      at_check(T, "rails_cut", false, "the train never left loaded again (state %s, reason %s)", tostring(rec.state),
        tostring(rec.reason))
      T.stage = "bridge_setup"
    end
  elseif T.stage == "cut" then
    local rec = T.trec
    local train = train_of(rec)
    if not T.cut_seen and train and (train.state == TS.no_path or rec.state == "no_path") then
      T.cut_seen = tick
      local found
      for _, a in ipairs(storage.alerts or {}) do
        if a.kind == "line-cut" and a.tick >= T.t_cut then found = a end
      end
      at_check(T, "rails_cut", line.state == "cut" and found ~= nil,
        "train %d no_path %.1f s after the cut; line %s, alert %s", train.id, (tick - T.t_cut) / 60, line.state,
        found and found.text or "none")
    end
    if line.state == "open" and line.reopened and line.reopened > T.t_cut then
      at_check(T, "rails_repair", line.reopened - T.t_cut <= AT.repair_limit,
        "line repaired and open %.1f s after the cut (limit %.0f s)", (line.reopened - T.t_cut) / 60,
        AT.repair_limit / 60)
      if not T.cut_seen then
        at_check(T, "rails_cut", false, "the train never reported no_path")
      end
      T.t_reopen = line.reopened
      T.iron_before = rec.delivered["iron-plate"] or 0
      T.stage = "resume"
    elseif tick - T.t_cut > 3 * AT.repair_limit then
      at_check(T, "rails_repair", false, "not repaired %.0f s after the cut (missing %d, wait %s, builder %s)",
        (tick - T.t_cut) / 60, line.missing, tostring(line.wait), tostring(line.builder))
      T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
    end
  elseif T.stage == "resume" then
    local rec = T.trec
    local iron = rec.delivered["iron-plate"] or 0
    if iron > T.iron_before then
      at_check(T, "rails_resume", tick - T.t_reopen <= AT.resume_limit,
        "deliveries resumed %.1f s after the repair (%d more iron)", (tick - T.t_reopen) / 60, iron - T.iron_before)
      T.stage = "idle_perf"
      T.t_idle = tick
    elseif tick - T.t_reopen > AT.resume_limit * 2 then
      at_check(T, "rails_resume", false, "no delivery %.0f s after the repair (state %s, reason %s)",
        (tick - T.t_reopen) / 60, tostring(rec.state), tostring(rec.reason))
      T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
    end
  elseif T.stage == "idle_perf" then
    -- a minute with the train running and no survey: the PERF lines measure the module's idle cost
    if tick - T.t_idle >= 70 * 60 then
      util.log("rails autotest: idle minute done (see the perf lines, label rails)")
      T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
    end
  end
end

-- Bridge stage (Space Age only): two depots across a 70-tile water band, Bridges allowed.
local function at_bridge(T, tick)
  local R = rstate()
  if T.stage == "bridge_setup" then
    if not rails.geometry() or not HAS_RAMP then
      util.log("rails autotest: no elevated rails (base game): bridge stage skipped")
      T.stage = "ai_setup"
      return
    end
    local s = game.surfaces[T.surface]
    at_generate(s, AT.gen_bridge)
    local water = at_water(s, AT.band)
    local C = at_depot(s, AT.force, AT.bridge_a, 0)
    local Dd = at_depot(s, AT.force, AT.bridge_b, 0)
    if not (C and Dd) then
      at_check(T, "rails_bridge", false, "bridge depots could not be placed")
      T.stage = "ai_setup"
      return
    end
    T.C, T.D = C.unit_number, Dd.unit_number
    at_fill(T.C, {coal = 100, [rails.LOCO_KIT] = 2, [rails.CWAGON_KIT] = 1, [rails.RAIL] = 1800})
    R.test_bridges = R.test_bridges or {}
    R.test_bridges[AT.force] = true
    T.bline = rails.plan_line(AT.force, T.C, T.D)
    T.t_bridge = tick
    util.log("rails autotest: bridge stage: %d water tiles, depots #%d -> #%d, line %s", water, T.C, T.D,
      tostring(T.bline))
    T.stage = "bridge"
  elseif T.stage == "bridge" then
    local line = T.bline and R.lines[T.bline]
    if not line or line.state == "failed" or line.state == "open" or tick - T.t_bridge > 8 * 60 * 60 then
      local elev, sups = 0, 0
      for _, p in ipairs(line and line.pieces or {}) do
        if p.elev then elev = elev + 1 end
      end
      for _, sp in ipairs(line and line.supports or {}) do
        if sp.e and sp.e.valid then sups = sups + 1 end
      end
      at_check(T, "rails_bridge", line ~= nil and line.state == "open" and (line.bill and line.bill.ramps or 0) >= 2,
        "line %s after %.0f s (missing %s, blocked %s, wait %s): %d pieces, %d ramps, %d elevated, %d supports standing, "
        .. "%.0f tiles", line and line.state or "none", (tick - T.t_bridge) / 60, tostring(line and line.missing),
        tostring(line and line.blocked), tostring(line and line.wait), line and line.pieces and #line.pieces or 0,
        line and line.bill and line.bill.ramps or 0, elev, sups, line and line.length or 0)
      T.stage = "ai_setup"
    end
  end
end

-- AI stage: the rail program of rts-ai-2 between a hub ("capital") and a far hub.
local function at_ai(T, tick)
  local R = rstate()
  if T.stage == "ai_setup" then
    local s = game.surfaces[T.surface]
    at_generate(s, AT.gen_ai)
    at_ground(s, AT.ai_anchor, 80, 60)
    at_ground(s, AT.ai_far, 80, 60)
    local h1 = s.create_entity({name = logistics.HUB, position = AT.ai_anchor, force = AT.ai_force, raise_built = true})
    local h2 = s.create_entity({name = logistics.HUB, position = AT.ai_far, force = AT.ai_force, raise_built = true})
    if not (h1 and h2) then
      at_check(T, "rails_ai", false, "AI hubs could not be placed")
      T.stage = "hauler_setup"
      return
    end
    for _, h in ipairs({h1, h2}) do
      for i = 1, 4 do
        local sp = s.find_non_colliding_position("rts-stockpile", {h.position.x - 6 + 3 * i, h.position.y - 6}, 6, 1, true)
        local st = sp and s.create_entity({name = "rts-stockpile", position = sp, force = AT.ai_force, raise_built = true})
        if st then buildings.register(st) end
      end
    end
    local stock = {["iron-plate"] = 3000, ["steel-plate"] = 2000, ["stone"] = 1000, ["electronic-circuit"] = 200,
                   ["copper-plate"] = 300, coal = 300}
    at_fill(h1.unit_number, stock)
    at_fill(h2.unit_number, stock)
    T.ai = {anchor = h1.unit_number, far = h2.unit_number, state = "idle"}
    R.ai[AT.ai_force] = T.ai
    T.t_ai = tick
    T.stage = "ai"
  elseif T.stage == "ai" then
    if tick % 60 == 0 then rails.ai_program(AT.ai_force, T.ai) end
    local A = T.ai
    local line = A.line and R.lines[A.line]
    local train
    for _, rec in pairs(R.trains) do
      if rec.force == AT.ai_force and rec.kind == "cargo" then train = rec end
    end
    if (tick - T.t_ai) % 1800 == 0 then
      util.log("rails autotest: AI %.0f s: state %s, depots #%s #%s, line %s (%s, missing %s, wait %s), train %s",
        (tick - T.t_ai) / 60, tostring(A.state), tostring(A.depot_a), tostring(A.depot_b), tostring(A.line),
        line and line.state or "-", line and tostring(line.missing) or "-", line and tostring(line.wait) or "-",
        train and tostring(train.id) or "-")
    end
    local delivered = train and next(train.delivered) ~= nil
    if delivered or tick - T.t_ai > 10 * 60 * 60 then
      at_check(T, "rails_ai", A.depot_a ~= nil and A.depot_b ~= nil and line ~= nil and line.state == "open"
        and train ~= nil and delivered,
        "after %.0f s: depots #%s #%s, line #%s %s (%.0f tiles), freight train %s, delivered %s", (tick - T.t_ai) / 60,
        tostring(A.depot_a), tostring(A.depot_b), tostring(A.line), line and line.state or "-", line and line.length or 0,
        train and tostring(train.id) or "none", train and serpent.line(train.delivered) or "-")
      T.stage = "hauler_setup"
    end
  end
end

-- Hauler stage: Nation-mode haulers carry 10 slots and burn 1 coal per 40 tiles from the hub they leave.
local function at_hauler(T, tick)
  if T.stage == "hauler_setup" then
    local s = game.surfaces[T.surface]
    at_generate(s, AT.gen_hauler)
    at_ground(s, AT.hauler_s, 24, 20)
    at_ground(s, AT.hauler_t, 24, 20)
    local hs = s.create_entity({name = logistics.HUB, position = AT.hauler_s, force = AT.force, raise_built = true})
    local ht = s.create_entity({name = logistics.HUB, position = AT.hauler_t, force = AT.force, raise_built = true})
    if not (hs and ht) then
      at_check(T, "rails_hauler_rules", false, "hubs could not be placed")
      T.stage = "done"
      return
    end
    T.hs, T.ht = hs.unit_number, ht.unit_number
    for _, item in ipairs({"iron-plate", "copper-plate"}) do
      logistics.set_policy(T.hs, "keep", item, nil)
      logistics.set_policy(T.ht, "keep", item, nil)
    end
    logistics.set_policy(T.hs, "export_above", "iron-plate", 0)
    logistics.set_policy(T.ht, "keep", "iron-plate", 3000)
    at_fill(T.hs, {["iron-plate"] = 3000, coal = 100})
    at_fill(T.ht, {coal = 100})
    local h = logistics.spawn_hauler(s, logistics.approach_point(T.ht), AT.force, T.ht)
    T.hauler = h and h.unit_number
    T.fuel0 = logistics.stats(AT.force).fuel or 0
    T.legs = util.distance(logistics.approach_point(T.hs), logistics.approach_point(T.ht))
    T.t_hauler = tick
    T.stage = "hauler"
  elseif T.stage == "hauler" then
    local h = T.hauler and logistics.hauler(T.hauler)
    local iron = h and h.delivered and h.delivered["iron-plate"] or 0
    if iron > 0 or not h or tick - T.t_hauler > 120 * 60 then
      local burnt = (logistics.stats(AT.force).fuel or 0) - T.fuel0
      local per_leg = math.ceil(T.legs * 1.1 / balance.nation.hauler_tiles_per_coal)
      local cap = logistics.capacity(AT.force)
      -- each departure from a hub takes per_leg coal (the hauler may already have left on its next trip); a leg may
      -- cost one less when the hauler leaves from a few tiles off the approach point (it arrives within 4 tiles)
      local legs_ok = false
      for k = 2, 20 do
        if burnt >= k * (per_leg - 1) and burnt <= k * per_leg then legs_ok = true end
      end
      at_check(T, "rails_hauler_rules", iron > 0 and iron <= cap * 100 and cap == balance.nation.hauler_slots
        and legs_ok,
        "hauler #%s delivered %d iron (capacity %d slots) over %.0f tiles per leg, burnt %d coal = %.1f legs of %d",
        tostring(T.hauler), iron, cap, T.legs, burnt, burnt / per_leg, per_leg)
      -- a hub with no coal: its auto hauler waits "no-fuel" and raises one alert (at most one per 2 minutes)
      local s = game.surfaces[T.surface]
      at_ground(s, AT.hauler_u, 20, 14)
      local hu = s.create_entity({name = logistics.HUB, position = AT.hauler_u, force = AT.force, raise_built = true})
      if hu then
        logistics.set_policy(hu.unit_number, "keep", "copper-plate", nil)
        logistics.set_policy(hu.unit_number, "keep", "iron-plate", 1000)
        local hn = logistics.spawn_hauler(s, logistics.approach_point(hu.unit_number), AT.force, hu.unit_number)
        T.nofuel = hn and hn.unit_number
      end
      T.t_nofuel = tick
      T.stage = "hauler_nofuel"
    end
  elseif T.stage == "hauler_nofuel" then
    if tick - T.t_nofuel < 20 * 60 then return end
    local h = T.nofuel and logistics.hauler(T.nofuel)
    local n, text = 0, nil
    for _, a in ipairs(storage.alerts or {}) do
      if a.kind == "hauler-no-fuel" and a.params and a.params[1] == T.nofuel then
        n = n + 1
        text = a.text
      end
    end
    at_check(T, "rails_hauler_no_fuel_alert", h ~= nil and h.state == "waiting" and h.reason == "no-fuel" and n == 1,
      "hauler #%s %s (%s) after 20 s; %d alert(s) %s for it", tostring(T.nofuel), h and h.state or "gone",
      h and tostring(h.reason) or "-", n, tostring(text))
    T.stage = "done"
  end
end

events.on_nth_tick(60, function(e)
  if not at_enabled() then return end
  at_shift()
  local R = rstate()
  local T = R.autotest
  if not T then
    local m = storage.match
    if not (m and m.phase == "running" and m.tick_started and e.tick - m.tick_started >= rails.AUTOTEST_START) then return end
    T = {stage = "setup", pass = 0, fail = 0, started = e.tick}
    R.autotest = T
    util.log("rails autotest: start at tick %d (stages %s)", e.tick,
      rails.AUTOTEST_STAGES and table.concat(rails.AUTOTEST_STAGES, ",") or "all")
  end
  if T.stage == "setup" then
    if stage_on("main") then
      at_setup(T)
    else
      R.test_nation = true
      R.test_forces = {[AT.force] = true, [AT.ai_force] = true}
      T.surface = at_surface().index
      for _, f in ipairs({AT.force, AT.ai_force}) do
        if not game.forces[f] then game.create_force(f) end
      end
      T.stage = stage_on("bridge") and "bridge_setup" or "ai_setup"
    end
  elseif T.stage == "bridge_setup" or T.stage == "bridge" then
    if stage_on("bridge") then at_bridge(T, e.tick) else T.stage = "ai_setup" end
  elseif T.stage == "ai_setup" or T.stage == "ai" then
    if stage_on("ai") then at_ai(T, e.tick) else T.stage = "hauler_setup" end
  elseif T.stage == "hauler_setup" or T.stage == "hauler" or T.stage == "hauler_nofuel" then
    if stage_on("hauler") then at_hauler(T, e.tick) else T.stage = "done" end
  elseif T.stage == "done" then
    if not T.summary then
      T.summary = true
      local st = rails.stats(AT.force)
      util.log("rails autotest: stats %s: trips %d, items %d, delivered %s", AT.force, st.trips, st.items,
        serpent.line(st.delivered))
      util.log("rails autotest summary %d/%d%s", T.pass, T.pass + T.fail,
        T.fail == 0 and " (all passed)" or string.format(" (%d FAILED)", T.fail))
    end
  else
    at_main(T, e.tick)
  end
end)

return rails
