-- Phase 5 M2 war performance probe (test copy only: tools/autotest-run.sh EXTRA_LUA with PERF=1 SPEED=1; contract
-- docs/PHASE5-M2.md: the war modules <= 0.2 ms per tick with 4 nations x 12 divisions). Beside a Nation-mode AI match,
-- on a lab surface outside the territory grid: four forces war-perf-1..4, each with 12 divisions of 16 walkers and a hub
-- holding 400 supply crates near its start. Forces 1 and 2 attack-move into each other (engaged divisions, deaths);
-- forces 3 and 4 march back and forth 120 tiles every 40 s (moving divisions) far apart; four divisions of force 3 start
-- low (30 SP) and two of force 4 out of supply (attrition, refused orders, loose units next to them). The "[rts] perf"
-- lines (events.lua profiling) give warsupply, capture and garrison per tick; this probe logs "[rts] war perf: ..."
-- with the divisions' SP once a minute.
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local warsupply = require("scripts.warsupply")

local LAB = "war-perf"
local FORCES = {"war-perf-1", "war-perf-2", "war-perf-3", "war-perf-4"}
local ORIGIN = {{x = 1100, y = 0}, {x = 1260, y = 0}, {x = 1600, y = -200}, {x = 1600, y = 260}}

local function lab()
  local s = game.surfaces[LAB]
  if s then return s end
  s = game.create_surface(LAB, {width = 3000, height = 1200, peaceful_mode = true, no_enemies_mode = true})
  s.always_day = true
  for cx = 31, 58 do for cy = -11, 14 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = 1000, 1860 do for y = -360, 460 do tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}} end end
  s.set_tiles(tiles, true, false, false, false)
  return s
end

local function setup()
  local P = storage.war_perf
  local s = lab()
  P.divs = {}
  for fi, f in ipairs(FORCES) do
    if not game.forces[f] then game.create_force(f) end
    local o = ORIGIN[fi]
    local hub = s.create_entity({name = "rts-hub", position = {x = o.x, y = o.y - 30}, force = f, raise_built = true})
    local net = hub and logistics.hub_network(hub.unit_number)
    if net then net.insert({name = "rts-supply-crate", count = 400}) end
    P.divs[f] = {}
    for d = 1, 12 do
      local bx = o.x + ((d - 1) % 4) * 16
      local by = o.y + math.floor((d - 1) / 4) * 16
      local list = {}
      for k = 1, 16 do
        local e = units.spawn("rts-walker", {x = bx + ((k - 1) % 4) * 3, y = by + math.floor((k - 1) / 4) * 3}, f, nil, s)
        if e then list[#list + 1] = e end
      end
      local id = divisions.create(f, list, {stance = "hold"}, {owner = "ai"})
      P.divs[f][#P.divs[f] + 1] = id
      local D = divisions.get(id)
      if fi == 3 and d <= 4 then D.sp = 30 end
      if fi == 4 and d <= 2 then D.sp = 0 end
    end
    -- a few loose units next to the first divisions
    for k = 1, 4 do units.spawn("rts-walker", {x = o.x + k * 3, y = o.y - 8}, f, nil, s) end
  end
  util.log("war perf: 4 forces x 12 divisions x 16 walkers on %s", LAB)
end

local function orders_round(round)
  local P = storage.war_perf
  for fi, f in ipairs(FORCES) do
    for i, id in ipairs(P.divs[f]) do
      if divisions.get(id) then
        local o = ORIGIN[fi]
        if fi == 1 or fi == 2 then
          local tx = (fi == 1) and ORIGIN[2].x + 30 or ORIGIN[1].x + 30
          divisions.order(id, "attack_move", {x = tx, y = o.y + ((i - 1) % 3) * 16})
        else
          local dx = (round % 2 == 0) and 120 or 0
          divisions.order(id, "move", {x = o.x + dx + ((i - 1) % 4) * 16, y = o.y + math.floor((i - 1) / 4) * 16})
        end
      end
    end
  end
end

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  if not storage.war_perf then
    if e.tick - m.tick_started < 600 then return end
    storage.war_perf = {round = 0, next = e.tick + 300}
    setup()
  end
  local P = storage.war_perf
  if e.tick >= P.next then
    P.round = P.round + 1
    P.next = e.tick + 40 * 60
    orders_round(P.round)
  end
  if e.tick % 3600 == 0 then
    local parts = {}
    for _, f in ipairs(FORCES) do parts[#parts + 1] = warsupply.describe(f) end
    util.log("war perf: round %d | %s", P.round, table.concat(parts, " | "))
  end
end)
