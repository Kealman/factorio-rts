-- r2-econ (Economy 0.1.1, #9) GUI probe: a 2048 Nation match against one AI; eight haulers walk 250-600 tiles away
-- from the capital in different directions (move orders: a live autopilot destination each); the map view
-- (zoom 0.07 over the capital) is captured with no selection (the engine's path lines, if any) and with two haulers
-- selected (the hauler panel's route lines). Logs "[rts] r2e map check <name>: PASS|FAIL ..." and RTS_R2E_MAP_DONE.
-- Test copy: append require("scripts.r2e_map_gui") to control.lua; tools/gui-drive.sh runs the RTS_DRIVE captures.
-- The screen belongs to r2-ux in 0.1.1: ask for a slot first. With D = a mods dir holding factorio-rts (the probe in
-- its scripts/) and mod-list.json:
--   tools/gui-drive.sh build/<D>-gui.log build/shots-<D>-window RTS_R2E_MAP_DONE & \
--     tools/gui-run.sh build/<D> 420 RTS_R2E_MAP_DONE '\[rts\] r2e|rror'
-- Window captures all.png (no selection) and selected.png (two haulers selected) show the map lines.
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local logistics = require("scripts.logistics")
local lobby = require("scripts.lobby")
local hubgui = require("scripts.hubgui")
local camera = require("scripts.camera")

local function check(name, ok, fmt, ...)
  util.log("r2e map check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end
local function drive(fmt, ...)
  storage.r2e_seq = (storage.r2e_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.r2e_seq, ...)
end
local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end
local function shot(player, tag)
  game.take_screenshot({player = player, by_player = player, path = "r2e-map-" .. tag .. ".png", show_gui = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom, force_render = true})
  drive("capture %s", tag)
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player, P)
  storage.camera = storage.camera or {}
  storage.camera.selftest = false
  storage.lobby.pending.mode = "nation"
  storage.lobby.pending.opponents = 1
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 300
end)

step(function(player, P)
  if not (storage.match and storage.match.phase == "running") then P.i = P.i - 1 return 120 end
  local cc = buildings.main_cc(player.force.name)
  if not cc then P.i = P.i - 1 return 120 end
  P.home = {x = cc.entity.position.x, y = cc.entity.position.y}
  local surface = cc.entity.surface
  if not P.charted then
    P.charted = true
    player.force.chart(surface, {{P.home.x - 640, P.home.y - 400}, {P.home.x + 640, P.home.y + 400}})
    P.i = P.i - 1
    return 600
  end
  P.haulers = {}
  for k = 0, 7 do
    local a = k * math.pi / 4 + 0.3
    local r = 250 + 50 * k
    local start = surface.find_non_colliding_position(logistics.HAULER, {P.home.x + 8 * math.cos(a), P.home.y + 8 + 8 * math.sin(a)}, 20, 1)
    local e = start and logistics.spawn_hauler(surface, start, player.force.name)
    if e then
      local dest = {x = P.home.x + r * math.cos(a), y = P.home.y + r * math.sin(a)}
      logistics.move_hauler(e.unit_number, dest)
      P.haulers[#P.haulers + 1] = e.unit_number
    end
  end
  util.log("r2e map: %d haulers sent from %s", #P.haulers, util.pos_str(P.home))
  return 240
end)

step(function(player, P)
  local moving = 0
  for _, un in ipairs(P.haulers) do
    local h = logistics.hauler(un)
    if h and h.entity.valid and h.entity.autopilot_destination then moving = moving + 1 end
  end
  check("moving", moving >= 6, "%d of %d haulers have an autopilot destination", moving, #P.haulers)
  selection.clear(player.index)
  camera.jump_to(player, P.home)
  player.zoom = 0.07
  return 90
end)

step(function(player, P)
  util.log("r2e map: view zoom %.3f render_mode %s", player.zoom, util.define_name(defines.render_mode, player.render_mode))
  shot(player, "all")
  return 120
end)

step(function(player, P)
  local list = {}
  for i = 1, 2 do
    local h = logistics.hauler(P.haulers[i])
    if h then list[#list + 1] = h.entity end
  end
  selection.set(player.index, list)
  hubgui.refresh(player.index)
  return 60
end)

step(function(player, P)
  hubgui.refresh(player.index)
  local g = storage.players[player.index].hubgui
  local n, ok = 0, true
  for _, r in pairs(g.routes or {}) do
    n = n + 1
    ok = ok and r.obj.valid and r.obj.render_mode == "chart"
  end
  check("route_lines", n == 2 and ok, "%d route lines for 2 selected haulers (chart only: %s)", n, tostring(ok))
  camera.jump_to(player, P.home)
  player.zoom = 0.07
  return 30
end)

step(function(player, P)
  shot(player, "selected")
  return 120
end)

step(function(player, P)
  selection.clear(player.index)
  hubgui.refresh(player.index)
  local g = storage.players[player.index].hubgui
  check("route_lines_cleared", g.routes == nil or next(g.routes) == nil, "routes after deselect: %s",
    serpent.line(g.routes))
  util.log("RTS_R2E_MAP_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r2e_map
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.r2e_map = P
  end
  if P.done or game.tick < P.at then return end
  local wait = STEPS[P.i](player, P)
  P.i = P.i + 1
  if not wait or P.i > #STEPS then P.done = true return end
  P.at = game.tick + wait
end)
