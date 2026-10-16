-- Probe (m2-treasury): do RTS units attack an indestructible roboport of a hostile force (rts-neutral)?
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local units = require("scripts.units")
local match = require("scripts.match")

local F = "rts-player"
local function P() storage.ntp = storage.ntp or {step = "wait"} return storage.ntp end

local function spawn(surface, pos, n, tag)
  local list = {}
  for i = 1, n do
    local e, rec = units.spawn("rts-walker", {pos.x + i * 2, pos.y}, F, nil, surface)
    if e then rec.order = "probe" rec.issuer = "probe" list[#list + 1] = e end
  end
  return list
end

local function cmd_line(e)
  local c = e.commandable
  local cmd = c and c.command
  local dc = c and c.distraction_command
  local tgt = dc and dc.target
  return string.format("#%d cmd=%s dist=%s target=%s", e.unit_number, cmd and tostring(cmd.type) or "-",
    dc and tostring(dc.type) or "-", (tgt and tgt.valid) and (tgt.name .. "/" .. tgt.force.name) or "-")
end

events.on_nth_tick(30, function(ev)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = P()
  if s.step == "wait" then
    if ev.tick - m.tick_started < 120 then return end
    ai.stop_force(F) ai.stop_force("rts-ai-1")
    local surface = game.surfaces[m.surface]
    local nf = game.forces["rts-neutral"] or game.create_force("rts-neutral")
    for _, f in ipairs({"rts-player", "rts-ai-1"}) do
      nf.set_cease_fire(f, false) game.forces[f].set_cease_fire(nf, false)
      nf.set_friend(f, false) game.forces[f].set_friend(nf, false)
    end
    local home = m.spawns[F]
    local P1 = {x = home.x, y = home.y + 60}
    local P2 = {x = home.x + 40, y = home.y + 60}
    for _, e in pairs(surface.find_entities_filtered({area = {{P1.x - 30, P1.y - 30}, {P2.x + 30, P2.y + 30}},
        type = {"tree", "simple-entity", "cliff"}})) do e.destroy() end
    s.hubA = surface.create_entity({name = "rts-hub", position = P1, force = nf})
    s.hubA.destructible = false
    s.hubB = surface.create_entity({name = "rts-stockpile", position = {P2.x + 200, P2.y}, force = "neutral"})
    s.stock = surface.create_entity({name = "rts-stockpile", position = {P1.x - 4, P1.y}, force = nf})
    s.stock.destructible = false
    util.log("ntp: hubA %s mil=%s hubB %s", tostring(s.hubA and s.hubA.valid), tostring(s.hubA.is_military_target), tostring(s.hubB and s.hubB.valid))
    s.A = spawn(surface, {x = P1.x - 4, y = P1.y + 12}, 3, "stop")
    s.B = spawn(surface, {x = P2.x - 4, y = P2.y + 12}, 3, "stopB")
    s.C = spawn(surface, {x = P1.x - 4, y = P1.y + 30}, 3, "attack_area")
    for _, e in ipairs(s.C) do
      e.commandable.set_command({type = defines.command.attack_area, destination = P1, radius = 20,
        distraction = defines.distraction.by_anything})
    end
    s.D = spawn(surface, {x = P1.x - 30, y = P1.y + 2}, 3, "go_to by_enemy")
    for _, e in ipairs(s.D) do
      e.commandable.set_command({type = defines.command.go_to_location, destination = {P1.x + 40, P1.y + 2},
        distraction = defines.distraction.by_enemy})
    end
    s.t = ev.tick
    s.step = "observe"
  elseif s.step == "observe" then
    local age = ev.tick - s.t
    if age % 300 ~= 0 then return end
    for _, g in ipairs({"A", "B", "C", "D"}) do
      local parts = {}
      for _, e in ipairs(s[g]) do if e.valid then parts[#parts + 1] = cmd_line(e) .. string.format(" at %s", util.pos_str(e.position)) end end
      util.log("ntp: t=%ds group %s: %s", age / 60, g, table.concat(parts, "; "))
    end
    util.log("ntp: t=%ds hubB health %s, hubA valid %s", age / 60, s.hubB.valid and tostring(s.hubB.health) or "dead",
      tostring(s.hubA.valid))
    if age >= 1200 then
      log("RTS_NTP_DONE")
      s.step = "done"
    end
  end
end)
