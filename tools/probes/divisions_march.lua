-- Divisions mid-march save/load probe (test copy only: EXTRA_LUA=tools/probes/divisions_march.lua with
-- tools/saveload-check.sh or tools/autotest-run.sh). docs/PHASE5-M1.md section 4: save/load with divisions mid-march.
--
-- 30 s into the match the probe creates the force rts-div-march (a friend of every force, so nobody fights it) and two
-- divisions of 12 walkers + 4 heavies on the match surface. They march back and forth between two points 120 tiles
-- apart (about 25 s per leg at the heavies' speed), so at any save they are mid-march. Every 10 s: one line per division
-- "[rts] div march t=..s #id state n=16 group=#gid|none order=... arrivals=N". A save / load in between must keep them
-- marching: their unit groups, records and the order queue live in storage, and arrivals go on after the load.
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")

local FORCE = "rts-div-march"
local POINTS = {{x = 0, y = -60}, {x = 0, y = 60}}

local function setup(m)
  local surface = game.surfaces[m.surface]
  if not game.forces[FORCE] then game.create_force(FORCE) end
  local f = game.forces[FORCE]
  for _, other in pairs(game.forces) do
    if other.name ~= FORCE then
      f.set_friend(other, true)
      f.set_cease_fire(other, true)
      other.set_friend(f, true)
      other.set_cease_fire(f, true)
    end
  end
  local P = {ids = {}, leg = {}, arrivals = {}, started = game.tick}
  storage.div_march = P
  for i = 1, 2 do
    local at = POINTS[i]
    local list = {}
    for k = 1, 16 do
      local name = k <= 12 and "rts-walker" or "rts-walker-heavy"
      local e = units.spawn(name, {x = at.x - 12 + ((k - 1) % 4) * 3 + (i - 1) * 24, y = at.y + math.floor((k - 1) / 4) * 3},
        FORCE, nil, surface)
      if e then list[#list + 1] = e end
    end
    local id = divisions.create(FORCE, list, {stance = "hold"}, {owner = "player"})
    P.ids[#P.ids + 1] = id
    P.leg[id] = i
    P.arrivals[id] = 0
    divisions.order(id, "move", POINTS[3 - i])
  end
  util.log("div march: started at tick %d with divisions %s", game.tick, table.concat(P.ids, ", "))
end

divisions.on_changed(function(D, what)
  local P = storage.div_march
  if not (P and what == "state" and D.state == "idle" and P.leg[D.id]) then return end
  P.arrivals[D.id] = P.arrivals[D.id] + 1
  P.leg[D.id] = 3 - P.leg[D.id]
  P.turn = P.turn or {}
  P.turn[#P.turn + 1] = D.id -- ordered on the next tick, outside divisions' own handler
end)

events.on(defines.events.on_tick, function(e)
  local P = storage.div_march
  if not (P and P.turn and #P.turn > 0) then return end
  for _, id in ipairs(P.turn) do
    if divisions.get(id) then divisions.order(id, "move", POINTS[3 - P.leg[id]]) end
  end
  P.turn = {}
end)

events.on_nth_tick(600, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local P = storage.div_march
  if not P then
    if e.tick - m.tick_started >= 30 * 60 then setup(m) end
    return
  end
  for _, id in ipairs(P.ids) do
    local D = divisions.get(id)
    if D then
      local n = divisions.strength(D, true)
      util.log("div march t=%ds #%d %s n=%d group=%s order=%s -> %s arrivals=%d at %s", (e.tick - P.started) / 60, id,
        D.state, n, (D.group and D.group.valid) and ("#" .. D.group_id) or "none", D.order and D.order.kind or "-",
        D.order and util.pos_str(D.order.target) or "-", P.arrivals[id], util.pos_str(D.pos))
    else
      util.log("div march t=%ds #%d gone", (e.tick - P.started) / 60, id)
    end
  end
end)
