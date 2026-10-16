-- Wave C GUI probe (test copy for tools/gui-run.sh, self-test off; append require("scripts.menu_gui") to control.lua).
-- Drives the real GUI elements through lobby.on_click, as a click does: Start in the lobby; a hauler from a hauler kit;
-- Ctrl+A (selection.select_all) must leave the hauler out; F10 menu -> Concede -> "Really concede?" -> results window
-- with a defeat; Continue; the menu's Results button opens the results window again. Screenshots after the confirm
-- prompt and both results windows. Log lines "[rts] menu probe ..." and the stop marker RTS_MENU_PROBE_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local selection = require("scripts.selection")
local economy = require("scripts.economy")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function click(player, frame, name)
  local el = find(player.gui.screen[frame], name)
  if not el then
    util.log("menu probe: %s/%s not found", frame, name)
    return nil
  end
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return el
end

local function check(name, ok, fmt, ...)
  util.log("menu probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.menu_probe
  if not P then
    P = {step = "start", at = game.tick + 120}
    storage.menu_probe = P
  end
  if game.tick < P.at or P.step == "done" then return end
  local F = player.force.name
  if P.step == "start" then
    click(player, "rts_lobby", "rts_lobby_start")
    P.step, P.at = "hauler", game.tick + 180
  elseif P.step == "hauler" then
    economy.give(F, "rts-hauler-kit", 1)
    P.step, P.at, P.wait_from = "select", game.tick + 60, game.tick
  elseif P.step == "select" then
    local haulers, army = 0, 0
    for _, rec in units.for_force(F) do
      if rec.kind == "hauler" then haulers = haulers + 1 else army = army + 1 end
    end
    if haulers == 0 and game.tick - P.wait_from < 30 * 60 then P.at = game.tick + 60 return end
    local n = selection.select_all(player.index)
    check("select_all_skips_haulers", haulers > 0 and n == army, "Ctrl+A selected %d; army %d, haulers %d", n, army,
      haulers)
    selection.clear(player.index)
    P.step, P.at = "concede1", game.tick + 60
  elseif P.step == "concede1" then
    lobby.toggle_menu(player)
    local b = click(player, "rts_menu", "rts_lobby_menu_concede")
    local again = find(player.gui.screen.rts_menu, "rts_lobby_menu_concede")
    local cap = again and again.caption
    check("concede_asks_twice", b ~= nil and type(cap) == "table" and cap[1] == "rts.menu-concede-confirm"
      and storage.match.phase == "running", "button after one click: %s, phase %s", type(cap) == "table" and cap[1] or
      tostring(cap), storage.match.phase)
    camera.screenshot(player)
    P.step, P.at = "concede2", game.tick + 60
  elseif P.step == "concede2" then
    click(player, "rts_menu", "rts_lobby_menu_concede")
    local r = match.result(F)
    check("concede_defeat", storage.match.phase == "ended" and r == "defeat" and player.gui.screen.rts_results ~= nil
      and player.gui.screen.rts_menu == nil, "phase %s, result %s, results window %s, winner %s", storage.match.phase,
      tostring(r), tostring(player.gui.screen.rts_results ~= nil), tostring(storage.match.winner))
    camera.screenshot(player)
    P.step, P.at = "continue", game.tick + 60
  elseif P.step == "continue" then
    click(player, "rts_results", "rts_lobby_results_continue")
    local gone = player.gui.screen.rts_results == nil
    lobby.toggle_menu(player)
    local has_results = find(player.gui.screen.rts_menu, "rts_lobby_menu_results") ~= nil
    local no_concede = find(player.gui.screen.rts_menu, "rts_lobby_menu_concede") == nil
    click(player, "rts_menu", "rts_lobby_menu_results")
    check("results_reopen", gone and has_results and no_concede and player.gui.screen.rts_results ~= nil
      and player.gui.screen.rts_menu == nil, "closed by Continue %s, menu has Results %s and no Concede %s, reopened %s",
      tostring(gone), tostring(has_results), tostring(no_concede), tostring(player.gui.screen.rts_results ~= nil))
    camera.screenshot(player)
    P.step, P.at = "finish", game.tick + 60
  elseif P.step == "finish" then
    util.log("RTS_MENU_PROBE_DONE player %d", player.index)
    P.step = "done"
  end
end)
