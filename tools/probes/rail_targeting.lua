-- Probe (m2-integ, work item B1): what do RTS units shoot on an attack-move that crosses enemy rails, signals,
-- poles, belts and buildings? Five lanes, each with the same enemy row (rails, a signal, a pole, a belt, an inserter,
-- a factory, an extractor, a stockpile); four walkers per lane march through it with a different command:
--   L1 attack_area by_anything (the current attack-move), destination beyond the row
--   L2 attack_area by_enemy, destination beyond the row
--   L3 attack_area by_enemy, destination beyond the row, the row's buildings is_military_target = true (runtime)
--   L4 attack_area by_enemy centred on the row (radius 10), buildings not military
--   L5 attack_area by_enemy centred on the row (radius 10), buildings military
-- The probe tree must allow the runtime change (tools: append the data line from the brief to data-updates.lua).
-- Log: "rtp: lane N <entity> health h/max" every 10 s; "RTS_RTP_DONE" at the end.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local units = require("scripts.units")

local F, E = "rts-player", "rts-ai-1"
local function S() storage.rtp = storage.rtp or {step = "wait"} return storage.rtp end
local CMD, DIS = defines.command, defines.distraction

local ONLY = nil -- set by the run script: one lane per run (lanes 30 tiles apart disturb each other)
local LANES = {
  {dis = DIS.by_anything, mil = false, centre = false},
  {dis = DIS.by_enemy, mil = false, centre = false},
  {dis = DIS.by_enemy, mil = true, centre = false},
  {dis = DIS.by_enemy, mil = false, centre = true},
  {dis = DIS.by_enemy, mil = true, centre = true},
}

local function row(surface, x0, y0, mil)
  local list = {}
  local function add(spec)
    spec.force = E
    local e = surface.create_entity(spec)
    if e then
      list[#list + 1] = e
      if mil and (e.name == "rts-factory" or e.name == "rts-extractor" or e.name == "rts-stockpile") then
        local ok, err = pcall(function() e.is_military_target = true end)
        util.log("rtp: %s is_military_target=true -> %s %s", e.name, tostring(ok), tostring(err or e.is_military_target))
      end
    else
      util.log("rtp: could not create %s at %s", spec.name, util.pos_str(spec.position))
    end
  end
  for i = -4, 4 do add({name = "straight-rail", position = {x0 + i * 2 + 1, y0 + 1}, direction = defines.direction.east}) end
  add({name = "rail-signal", position = {x0 + 0.5, y0 - 1.5}, direction = defines.direction.west})
  add({name = "medium-electric-pole", position = {x0 - 6.5, y0 - 4.5}})
  add({name = "transport-belt", position = {x0 + 6.5, y0 - 4.5}})
  add({name = "inserter", position = {x0 + 7.5, y0 - 4.5}})
  add({name = "rts-factory", position = {x0 - 8, y0 + 8}})
  add({name = "rts-extractor", position = {x0 + 8, y0 + 8}})
  add({name = "rts-stockpile", position = {x0, y0 + 8}})
  return list
end

events.on_nth_tick(60, function(ev)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = S()
  if s.step == "wait" then
    if ev.tick - m.tick_started < 180 then return end
    ai.stop_force(F) ai.stop_force(E)
    local surface = game.surfaces[m.surface]
    local home = m.spawns[F]
    local y0 = home.y + 70
    local x_first = home.x - 40
    local tiles = {}
    for x = x_first - 25, x_first + 30 * #LANES + 5 do
      for y = y0 - 45, y0 + 45 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
    end
    surface.set_tiles(tiles, true)
    for _, e in pairs(surface.find_entities_filtered({area = {{x_first - 25, y0 - 45}, {x_first + 30 * #LANES + 5, y0 + 45}}})) do
      if e.valid and e.type ~= "character" then e.destroy() end
    end
    s.lanes = {}
    for i, L in ipairs(LANES) do
     if not ONLY or ONLY == i then
      local x0 = x_first + (i - 1) * 30
      local lane = {entities = row(surface, x0, y0, L.mil), units = {}, names = {}}
      for k, e in ipairs(lane.entities) do lane.names[k] = e.name end
      for k = 1, 4 do
        local e = units.spawn("rts-walker", {x0 - 3 + k * 1.5, y0 + 30}, F, nil, surface)
        if e then
          local rec = storage.units[e.unit_number]
          rec.order, rec.issuer = "probe", "probe"
          lane.units[#lane.units + 1] = e
          local dest = L.centre and {x0, y0} or {x0, y0 - 35}
          e.commandable.set_command({type = CMD.attack_area, destination = dest, radius = L.centre and 10 or 8,
                                     distraction = L.dis})
        end
      end
      s.lanes[#s.lanes + 1] = lane
      lane.index = i
     end
    end
    s.t = ev.tick
    s.step = "observe"
    util.log("rtp: started %d lanes at y0=%d", #LANES, y0)
  elseif s.step == "observe" then
    local age = ev.tick - s.t
    if age % 600 ~= 0 then return end
    for _, lane in ipairs(s.lanes) do
      local i = lane.index
      local parts = {}
      for k, e in ipairs(lane.entities) do
        if e.valid then
          if e.health < e.max_health then parts[#parts + 1] = string.format("%s %.0f/%.0f", e.name, e.health, e.max_health) end
        else
          parts[#parts + 1] = lane.names[k] .. " DEAD"
        end
      end
      local dead = 0
      for _, e in ipairs(lane.entities) do if not e.valid then dead = dead + 1 end end
      local pos = {}
      for _, u in ipairs(lane.units) do
        if u.valid then
          local c = u.commandable
          local dc = c and c.distraction_command
          pos[#pos + 1] = string.format("(%.0f,%.0f)%s", u.position.x, u.position.y, dc and ("dist:" .. tostring(dc.type)) or "")
        end
      end
      util.log("rtp: t=%ds lane %d: %d of %d dead, damaged [%s] units %s", age / 60, i, dead, #lane.entities,
        table.concat(parts, ", "), table.concat(pos, " "))
    end
    if age >= 60 * 60 then
      log("RTS_RTP_DONE")
      s.step = "done"
    end
  end
end)
