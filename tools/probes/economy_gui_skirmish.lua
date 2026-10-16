-- Phase 5 E1 GUI probe, Skirmish (test copy for tools/gui-run.sh; copy into the copy's scripts/ and require it from its
-- control.lua). Starts a Skirmish match, places a factory and selects it: the factory page has no category tabs and
-- none of the Age II or Nation-only recipes, as before E1. Log lines "[rts] e1 skirmish probe ...", the screenshot
-- rts-e1-skirmish-factory.png and the stop marker RTS_E1_SKIRMISH_GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local research = require("scripts.research")

local function check(name, ok, fmt, ...)
  util.log("e1 skirmish probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.e1_skirmish_probe
  if not P then
    P = {step = 1, at = game.tick + 180}
    storage.e1_skirmish_probe = P
  end
  if P.done or game.tick < P.at then return end
  if P.step == 1 then
    lobby.start_match({opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}, "e1 skirmish probe")
    P.step, P.at = 2, game.tick + 180
  elseif P.step == 2 then
    local F = player.force.name
    ai.stop_force(util.ENEMY_FORCE)
    local home = match.home(F)
    local surface = match.surface()
    local pos = surface.find_non_colliding_position("rts-factory", {x = home.x - 12.5, y = home.y - 10.5}, 10, 1, true)
    P.factory = surface.create_entity({name = "rts-factory", position = pos, force = F, raise_built = true})
    selection.select_building(player.index, P.factory.unit_number)
    P.step, P.at = 3, game.tick + 60
  elseif P.step == 3 then
    game.take_screenshot({player = player, by_player = player, path = "rts-e1-skirmish-factory.png", show_gui = true,
                          force_render = true, resolution = {1280, 800}})
    local h = util.pstorage(player.index).hud
    local names, bad = {}, {}
    for name in pairs(h and h.recipe_buttons or {}) do
      names[#names + 1] = name
      if research.AGE_LOCKS[name] then bad[#bad + 1] = name end
    end
    table.sort(names)
    local tabs = find(player.gui.screen, "rts_hud_factory_tab_buildings")
    check("skirmish_factory_grid", #bad == 0 and #names <= 28 and not (tabs and tabs.visible),
      "%d buttons, Age II recipes [%s], tab row %s: %s", #names, table.concat(bad, " "),
      tabs and tostring(tabs.visible) or "none", table.concat(names, " "))
    log("RTS_E1_SKIRMISH_GUI_DONE")
    P.done = true
  end
end)
