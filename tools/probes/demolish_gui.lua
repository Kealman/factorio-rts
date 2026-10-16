-- Demolish GUI probe (test copy for tools/gui-run.sh with the self-test off; append require("scripts.demolish_gui") to
-- the copy's control.lua). Drives the real HUD and hub panel buttons through the on_gui_click handlers and logs
-- "[rts] demolish gui probe <name>: PASS|FAIL ..." lines, then RTS_DEMOLISH_GUI_DONE. Screenshots (script-output):
--   rts-demolish-armed.png    barracks page after the first click (red "Press again" button)
--   rts-demolish-hub.png      hub panel with its Demolish button
--   rts-demolish-done.png     after both buildings are gone (alert line "Demolished ...")
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local demolish = require("scripts.demolish")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function click(el, player)
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index, button = defines.mouse_button_type.left,
                                                shift = false, control = false, alt = false, name = defines.events.on_gui_click})
end

local function check(name, ok, fmt, ...)
  util.log("demolish gui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag, position)
  game.take_screenshot({player = player, by_player = player, path = "rts-demolish-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}, position = position or player.position,
                        zoom = 0.6})
end

local function place(name, near, force)
  local surface = match.surface()
  local pos = surface.find_non_colliding_position(name, near, 20, 1, true) or near
  return surface.create_entity({name = name, position = pos, force = force, raise_built = true})
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player)
  lobby.on_click({element = find(player.gui.screen.rts_lobby, "rts_lobby_start"), player_index = player.index,
                  name = defines.events.on_gui_click})
  return 240
end)

step(function(player, P)
  local F = player.force.name
  local cc = buildings.main_cc(F)
  local home = cc.entity.position
  P.barracks = place("rts-barracks", {x = home.x + 14, y = home.y}, F)
  P.hub = place("rts-hub", {x = home.x, y = home.y + 16}, F)
  camera.jump_to(player, {x = home.x + 6, y = home.y + 6})
  selection.select_building(player.index, P.barracks.unit_number)
  return 90
end)

step(function(player, P)
  local btn = find(player.gui.screen.rts_hud_panel, "rts_hud_demolish")
  check("button present", btn ~= nil and btn.visible, "caption %s", btn and "ok" or "missing")
  click(btn, player)
  btn = find(player.gui.screen.rts_hud_panel, "rts_hud_demolish")
  check("armed", P.barracks.valid and demolish.is_armed(player.index) and btn.style.name == "rts_hud_button_armed",
    "valid %s style %s", tostring(P.barracks.valid), btn.style.name)
  shot(player, "armed", P.barracks.position)
  return 60
end)

step(function(player, P)
  local btn = find(player.gui.screen.rts_hud_panel, "rts_hud_demolish")
  click(btn, player)
  check("barracks demolished", not P.barracks.valid, "")
  selection.select_building(player.index, P.hub.unit_number)
  return 90
end)

step(function(player, P)
  local btn = find(player.gui.screen.rts_hubgui_frame, "rts_hubgui_demolish")
  check("hub button", btn ~= nil, "")
  shot(player, "hub", P.hub.position)
  click(btn, player)
  check("hub armed", P.hub.valid and demolish.is_armed(player.index), "")
  return 30
end)

step(function(player, P)
  local btn = find(player.gui.screen.rts_hubgui_frame, "rts_hubgui_demolish")
  click(btn, player)
  check("hub demolished", not P.hub.valid, "")
  return 60
end)

step(function(player, P)
  selection.select_building(player.index, (buildings.main_cc(player.force.name)).entity.unit_number)
  local btn = find(player.gui.screen.rts_hud_panel, "rts_hud_demolish")
  click(btn, player)
  check("cc protected", buildings.main_cc(player.force.name) ~= nil and not demolish.is_armed(player.index), "")
  shot(player, "done")
  return 60
end)

step(function(player)
  util.log("RTS_DEMOLISH_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.demolish_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.demolish_gui_probe = P
  end
  if P.done or game.tick < P.at then return end
  local ok, wait = pcall(STEPS[P.i], player, P)
  if not ok then
    util.log("demolish gui probe ERROR step %d: %s", P.i, tostring(wait))
    wait = 30
  end
  P.i = P.i + 1
  if not wait or P.i > #STEPS then P.done = true return end
  P.at = game.tick + wait
end)
