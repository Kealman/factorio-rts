-- Release 0.1.2 r3-build GUI probe (#23, #27, #25). Test copy for tools/gui-run.sh with the self-test off: copy to the
-- mod copy's scripts/ and append require("scripts.r3_build_gui") to its control.lua; stop marker RTS_R3_BUILD_GUI_DONE.
-- Drives the real HUD through selection.handle_area and on_gui_click and writes screenshots rts-r3-<tag>.png:
--   belt, inserter, pole      one piece selected (page with Rotate / Demolish), line = 5 belts boxed (group page),
--   armed                     red "Press again", ghost = smelter ghost (Cancel button), build = economy build menu,
--   factory                   the factory page with the new recipes.
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
  util.log("r3 build gui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt or "", ...))
end

local function shot(player, tag, position)
  game.take_screenshot({player = player, by_player = player, path = "rts-r3-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}, position = position or player.position,
                        zoom = 0.9})
end

local function select_at(player, pos)
  selection.handle_area(player.index, {}, {left_top = {x = pos.x - 0.02, y = pos.y - 0.02},
                                           right_bottom = {x = pos.x + 0.02, y = pos.y + 0.02}}, false, player.surface)
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
  local home = buildings.main_cc(F).entity.position
  local s = player.surface
  local bx, by = math.floor(home.x) + 12, math.floor(home.y) + 12
  P.bx, P.by = bx, by
  for _, e in pairs(s.find_entities_filtered({area = {{bx - 2, by - 2}, {bx + 14, by + 12}}, force = "neutral"})) do e.destroy() end
  P.belts = {}
  for i = 0, 4 do
    P.belts[#P.belts + 1] = s.create_entity({name = "transport-belt", position = {bx + 0.5 + i, by + 0.5}, force = F,
      direction = defines.direction.east, raise_built = true})
  end
  P.ins = s.create_entity({name = "fast-inserter", position = {bx + 6.5, by + 0.5}, force = F, direction = defines.direction.east, raise_built = true})
  P.pole = s.create_entity({name = "medium-electric-pole", position = {bx + 8.5, by + 0.5}, force = F, raise_built = true})
  P.ug = s.create_entity({name = "underground-belt", position = {bx + 0.5, by + 3.5}, force = F, direction = defines.direction.east, type = "input", raise_built = true})
  P.split = s.create_entity({name = "splitter", position = {bx + 3.5, by + 4}, force = F, direction = defines.direction.east, raise_built = true})
  P.long = s.create_entity({name = "long-handed-inserter", position = {bx + 6.5, by + 3.5}, force = F, direction = defines.direction.east, raise_built = true})
  P.ghost = s.create_entity({name = "entity-ghost", inner_name = "rts-smelter", position = {bx + 6, by + 70}, force = F, raise_built = true})
  P.center = {x = bx + 5, y = by + 3}
  camera.jump_to(player, P.center)
  return 120
end)

local function page_step(tag, get_entity, expect)
  step(function(player, P)
    local e = get_entity(P)
    select_at(player, e.position)
    check(tag .. " selected", #selection.get_pieces(player.index) == 1, "n=%d", #selection.get_pieces(player.index))
    return 60
  end)
  step(function(player, P)
    shot(player, tag, P.center)
    return 30
  end)
end
page_step("belt", function(P) return P.belts[1] end)
page_step("inserter", function(P) return P.ins end)
page_step("pole", function(P) return P.pole end)
page_step("underground", function(P) return P.ug end)
page_step("splitter", function(P) return P.split end)
page_step("longinserter", function(P) return P.long end)

step(function(player, P)
  selection.handle_area(player.index, {}, {left_top = {x = P.bx - 0.2, y = P.by - 0.2}, right_bottom = {x = P.bx + 5.2, y = P.by + 1.2}}, false, player.surface)
  check("line selected", #selection.get_pieces(player.index) == 5, "n=%d", #selection.get_pieces(player.index))
  return 60
end)
step(function(player, P)
  shot(player, "line", P.center)
  click(find(player.gui.screen.rts_hud_panel, "rts_hud_demolish"), player)
  return 30
end)
step(function(player, P)
  check("armed", demolish.is_armed(player.index), "")
  shot(player, "armed", P.center)
  return 30
end)
step(function(player, P)
  click(find(player.gui.screen.rts_hud_panel, "rts_hud_demolish"), player)
  local gone = 0
  for _, e in ipairs(P.belts) do if not e.valid then gone = gone + 1 end end
  check("line demolished", gone == 5, "gone=%d", gone)
  return 60
end)
step(function(player, P)
  camera.jump_to(player, P.ghost.position)
  select_at(player, P.ghost.position)
  return 60
end)
step(function(player, P)
  shot(player, "ghost", P.ghost.position)
  return 30
end)
step(function(player, P)
  click(find(player.gui.screen.rts_hud_panel, "rts_hud_demolish"), player)
  check("ghost cancelled by button", not P.ghost.valid, "")
  return 60
end)
step(function(player, P)
  local F = player.force.name
  local home = buildings.main_cc(F).entity.position
  P.factory = player.surface.create_entity({name = "rts-factory", position = {home.x - 14, home.y + 10}, force = F,
                                            raise_built = true})
  if P.factory then
    camera.jump_to(player, P.factory.position)
    selection.select_building(player.index, P.factory.unit_number)
  end
  return 90
end)
step(function(player, P)
  shot(player, "factory", P.factory and P.factory.position)
  return 30
end)
step(function(player, P)
  selection.clear(player.index)
  local b = find(player.gui.screen, "rts_hud_build_tab_economy")
  if b then click(b, player) end
  return 60
end)
step(function(player, P)
  shot(player, "build", P.center)
  return 30
end)
step(function(player)
  util.log("RTS_R3_BUILD_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r3_build_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.r3_build_gui_probe = P
  end
  if P.done or game.tick < P.at then return end
  local ok, wait = pcall(STEPS[P.i], player, P)
  if not ok then
    util.log("r3 build gui probe ERROR step %d: %s", P.i, tostring(wait))
    wait = 30
  end
  P.i = P.i + 1
  if not wait or P.i > #STEPS then P.done = true return end
  P.at = game.tick + wait
end)
