-- Phase 5 M3 perf: the budget scene of docs/PHASE5-M3.md D9 (test copy only: tools/perf-bench.sh scene). On a 4-nation
-- normal AI match (2048) it builds, at match minute cfg.at_minute:
--   cities  every nation up to 4 (16 in all): City Centers by script (cities.found) on the free world city sites nearest
--           its capital, else on a ring 260 tiles around it;
--   units   every nation up to 150 units (600 in all): 2/3 walkers and 1/3 drones spawned on a grid 40 tiles from the
--           capital, in divisions of 16 that march between the nation's cities (a new leg every LEG_TICKS); the AI's
--           army does not call them back to its rally point (a.sent) but may still form groups from them (defence, war);
--   trains  every nation 10 freight lines (40 trains) on a lab surface "perf-rails": two depots 200 tiles apart joined
--           by a straight track, depot A exports iron plates, depot B keeps them, one rails.lua cargo train per line;
--           every RECYCLE_TICKS the plates delivered to B go back into A, so the trains keep shuttling.
-- Then it switches the game to speed 1, lets the scene settle for SETTLE_TICKS and saves it with game.server_save
-- ("perf-scene"), logging "[rts] perf scene saved". After a load (the benchmark, the realtime run) it keeps the legs
-- and the recycling going and logs once a minute "[rts] perf scene minute N: units U, moving M, trains T (moving K),
-- cities C, wall clock <profiler>" (the wall clock only reaches the log).
-- Config: scripts/perf_scene_cfg.lua (written by tools/perf-bench.sh) = {at_minute = 10, speed = 8}.
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local units = require("scripts.units")
local cities = require("scripts.cities")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local rails = require("scripts.rails")
local territory = require("scripts.territory")
local world = require("scripts.world")

local ok_cfg, CFG = pcall(require, "scripts.perf_scene_cfg")
CFG = ok_cfg and type(CFG) == "table" and CFG or {}
local AT_MINUTE = CFG.at_minute or 10
local SPEED = CFG.speed or 8

local CITIES, UNITS, LINES = 4, 150, 10
local DIV_SIZE = 16
local LEG_TICKS = 40 * 60
local RECYCLE_TICKS = 30 * 60
local SETTLE_TICKS = 60 * 60
local SURFACE = "perf-rails"
local LINE_LEN = 200
local PLATES = 20000

local wall -- module-local wall-clock profiler (only logged)

local function S()
  storage.perf_scene = storage.perf_scene or {}
  return storage.perf_scene
end

events.on_init(function() game.speed = SPEED end)

local function nations()
  local out = {}
  for _, f in ipairs(match.forces()) do out[#out + 1] = f end
  return out
end

---------------------------------------------------------------------------
-- Cities
---------------------------------------------------------------------------
local function capital_of(f)
  local list = cities.for_force(f)
  for _, c in ipairs(list) do if c.capital then return c end end
  return list[1]
end

local function found_cities(f, log_parts)
  local cap = capital_of(f)
  local home = cap and cap.position or match.home(f)
  local cands = {}
  for _, s in ipairs(world.sites("city_site")) do
    cands[#cands + 1] = {p = s.position, d = util.distance(s.position, home)}
  end
  for i = 0, 11 do
    local a = i * math.pi / 6
    local p = {x = home.x + 260 * math.cos(a), y = home.y + 260 * math.sin(a)}
    cands[#cands + 1] = {p = p, d = 10000 + i}
  end
  table.sort(cands, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.p.x ~= b.p.x then return a.p.x < b.p.x end
    return a.p.y < b.p.y
  end)
  local surface = match.surface()
  local made = 0
  for _, c in ipairs(cands) do
    if #cities.for_force(f) >= CITIES then break end
    local owner = territory.owner_at(c.p)
    local half = 1024
    if (owner == nil or owner == f) and math.abs(c.p.x) < half - 100 and math.abs(c.p.y) < half - 100 then
      local spot = surface.find_non_colliding_position(cities.CENTER, c.p, 24, 1, true)
      local clear = true
      for _, other in pairs(storage.cities or {}) do
        if spot and util.distance(other.position, spot) < 96 then clear = false break end
      end
      if spot and clear and cities.found(f, spot) then made = made + 1 end
    end
  end
  log_parts[#log_parts + 1] = string.format("%s +%d cities (%d)", f, made, #cities.for_force(f))
end

---------------------------------------------------------------------------
-- Units in marching divisions
---------------------------------------------------------------------------
local function spawn_units(f, log_parts)
  local P = S()
  local have = units.count(f)
  local want = math.max(0, UNITS - have)
  local cap = capital_of(f)
  local home = cap and cap.position or match.home(f)
  local dir = home.x >= 0 and -1 or 1 -- towards the map centre
  local surface = match.surface()
  local made, list = 0, {}
  for i = 1, want do
    local name = (i % 3 == 0) and "rts-drone" or "rts-walker"
    local k = i - 1
    local pos = {x = home.x + dir * (40 + (k % 10) * 3), y = home.y - 30 + math.floor(k / 10) * 3}
    local e = units.spawn(name, pos, f, nil, surface)
    if e then
      made = made + 1
      list[#list + 1] = e
    end
  end
  -- the AI's army sends idle units far from its rally point back there (ai/army.lua, a.sent = last send tick); the
  -- scene's divisions march on their own legs, so their units are marked as just sent for the rest of the match
  local C = storage.ai and storage.ai[f]
  if C and C.army then
    C.army.sent = C.army.sent or {}
    for _, e in ipairs(list) do C.army.sent[e.unit_number] = 2 ^ 31 end
  end
  P.divs = P.divs or {}
  local n = 0
  for i = 1, #list, DIV_SIZE do
    local part = {}
    for j = i, math.min(#list, i + DIV_SIZE - 1) do part[#part + 1] = list[j] end
    local id = divisions.create(f, part, {stance = "hold"}, {owner = "player"})
    if id then
      P.divs[#P.divs + 1] = {id = id, force = f, leg = #P.divs}
      n = n + 1
    end
  end
  log_parts[#log_parts + 1] = string.format("%s +%d units in %d divisions (%d)", f, made, n, units.count(f))
end

local function march()
  local P = S()
  for _, d in ipairs(P.divs or {}) do
    if divisions.get(d.id) then
      local list = cities.for_force(d.force)
      if #list > 0 then
        d.leg = d.leg + 1
        local c = list[d.leg % #list + 1]
        divisions.order(d.id, "move", {x = c.position.x + 12, y = c.position.y + 12})
      end
    end
  end
end

---------------------------------------------------------------------------
-- Freight lines on a lab surface
---------------------------------------------------------------------------
local function lab()
  local s = game.surfaces[SURFACE]
  if s then return s end
  s = game.create_surface(SURFACE, {width = 1400, height = 1400, peaceful_mode = true, no_enemies_mode = true})
  s.always_day = true
  for cx = -2, 9 do
    for cy = -2, 20 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end
  end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -60, 300 do
    for y = -60, 660 do tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}} end
  end
  s.set_tiles(tiles, true, false, false, false)
  for _, e in pairs(s.find_entities_filtered({area = {{-60, -60}, {300, 660}}, type = {"tree", "simple-entity", "cliff"}})) do
    e.destroy()
  end
  return s
end

local function build_lines(f, fi, log_parts)
  local P = S()
  local s = lab()
  P.lines = P.lines or {}
  local made, trains = 0, 0
  for li = 0, LINES - 1 do
    local y = (fi - 1) * LINES * 16 + li * 16
    local ea = s.create_entity({name = rails.DEPOT, position = {0, y}, force = f, raise_built = true})
    local eb = s.create_entity({name = rails.DEPOT, position = {LINE_LEN, y}, force = f, raise_built = true})
    local A, B = ea and rails.depot(ea.unit_number), eb and rails.depot(eb.unit_number)
    if A and B and A.platform and B.platform and A.platform.axis == "x" and B.platform.axis == "x"
       and A.platform.track == B.platform.track then
      local ty = A.platform.track
      local x0, x1 = A.platform.ends[2].x, B.platform.ends[1].x
      for x = x0 + 1, x1 - 1, 2 do
        s.create_entity({name = "straight-rail", position = {x, ty}, direction = defines.direction.east, force = f})
      end
      made = made + 1
      local na, nb = logistics.hub_network(ea.unit_number), logistics.hub_network(eb.unit_number)
      if na and nb then
        logistics.set_policy(ea.unit_number, "export_above", "iron-plate", 0)
        logistics.set_policy(eb.unit_number, "keep", "iron-plate", logistics.MAX_THRESHOLD)
        na.insert({name = rails.LOCO_KIT, count = 2})
        na.insert({name = rails.WAGON_KIT, count = 2})
        na.insert({name = "coal", count = 400})
        nb.insert({name = "coal", count = 400})
        na.insert({name = "iron-plate", count = PLATES})
        local train, why = rails.create_train(ea.unit_number, "cargo")
        if train and rails.set_route(train, ea.unit_number, eb.unit_number) then
          trains = trains + 1
          P.lines[#P.lines + 1] = {a = ea.unit_number, b = eb.unit_number, force = f, train = train.id}
        else
          util.log("perf scene: line %d of %s: no train (%s)", li + 1, f, tostring(why))
        end
      end
    else
      util.log("perf scene: line %d of %s: depots or platforms missing", li + 1, f)
    end
  end
  log_parts[#log_parts + 1] = string.format("%s %d lines, %d trains", f, made, trains)
end

local function recycle()
  for _, L in ipairs(S().lines or {}) do
    local na, nb = logistics.hub_network(L.a), logistics.hub_network(L.b)
    if na and nb then
      local n = nb.get_item_count("iron-plate")
      if n > 0 then
        local moved = nb.remove_item({name = "iron-plate", count = n})
        if moved > 0 then na.insert({name = "iron-plate", count = moved}) end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Driver
---------------------------------------------------------------------------
local function build()
  local P = S()
  P.built = game.tick
  local parts = {}
  local list = nations()
  for _, f in ipairs(list) do found_cities(f, parts) end
  for _, f in ipairs(list) do spawn_units(f, parts) end
  for fi, f in ipairs(list) do build_lines(f, fi, parts) end
  local n = 0
  for _ in pairs(storage.cities or {}) do n = n + 1 end
  util.log("perf scene: built at tick %d: %s; %d cities in the world (city-states included)", game.tick,
    table.concat(parts, "; "), n)
  game.speed = 1
  march()
end

local function census()
  local nunits, moving = 0, 0
  for _, rec in pairs(storage.units or {}) do
    if rec.entity.valid and rec.force ~= "rts-neutral" then
      nunits = nunits + 1
      if rec.entity.type ~= "spider-vehicle" and rec.order ~= units.IDLE then moving = moving + 1 end
    end
  end
  local ntrains, tmoving = 0, 0
  for _, rec in pairs(storage.rails and storage.rails.trains or {}) do
    local loco = rec.loco
    if loco and loco.valid and loco.train then
      ntrains = ntrains + 1
      if math.abs(loco.train.speed) > 0.01 then tmoving = tmoving + 1 end
    end
  end
  local ncities = 0
  for _, c in pairs(storage.cities or {}) do
    if c.force ~= "rts-neutral" then ncities = ncities + 1 end
  end
  return nunits, moving, ntrains, tmoving, ncities
end

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local P = S()
  if not P.built then
    if e.tick - m.tick_started >= AT_MINUTE * 3600 then build() end
    return
  end
  local age = e.tick - P.built
  if age > 0 and age % LEG_TICKS == 0 then march() end
  if age > 0 and age % RECYCLE_TICKS == 0 then recycle() end
  if not P.saved and age >= SETTLE_TICKS then
    P.saved = e.tick
    local u, mv, t, tm, c = census()
    util.log("perf scene saved at tick %d: units %d (moving %d), trains %d (moving %d), cities %d", e.tick, u, mv, t,
      tm, c)
    game.server_save("perf-scene")
  end
  if age % 3600 == 0 then
    local u, mv, t, tm, c = census()
    if wall then
      wall.stop()
      log({"", string.format("[rts] perf scene minute %d: units %d, moving %d, trains %d (moving %d), cities %d, "
        .. "wall clock ", age / 3600, u, mv, t, tm, c), wall})
      wall.reset()
    else
      util.log("perf scene minute %d: units %d, moving %d, trains %d (moving %d), cities %d (wall clock from the next "
        .. "minute)", age / 3600, u, mv, t, tm, c)
      wall = helpers.create_profiler()
    end
  end
end)

return {}
