-- Phase 5 M2 people GUI probe. Test copy for tools/gui-run.sh, self-test off: copy this file into the copy's scripts/
-- and append require("scripts.people_gui") to its control.lua. It starts a Nation match (1 AI, large arena), then shows:
-- the capital's city panel with the people section and the labor priorities open, a staffed building's staffing box
-- (pinned and unpinned), a building at 0 % ("No workers" in the HUD status line), a barracks holding a kit for
-- "no recruits", and the build menu's Production tab with the people buildings. Each view writes rts-people-<tag>.png
-- (game.take_screenshot with the GUI). Log lines "[rts] peoplegui ...", the last one RTS_PEOPLEGUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local selection = require("scripts.selection")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local citygui = require("scripts.citygui")
local population = require("scripts.population")
local labor = require("scripts.labor")
local hud = require("scripts.hud")
local ai = require("scripts.ai.init")

local function capture(player, tag)
  local path = "rts-people-" .. tag .. ".png"
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  util.log("peoplegui: screenshot %s", path)
end

local function frame_text(el, out)
  out = out or {}
  if not (el and el.valid) then return out end
  if el.type == "label" or el.type == "button" then
    local c = el.caption
    if type(c) == "table" then out[#out + 1] = serpent.line(c) elseif c and c ~= "" then out[#out + 1] = c end
  end
  for _, child in pairs(el.children) do frame_text(child, out) end
  return out
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function()
  lobby.start_match({opponents = 1, difficulty = "normal", size = "large", map = "chokes", enemy_brain = "ai",
                     mode = "nation"}, "people gui probe")
  return 240
end)

step(function(player, S)
  local F = player.force.name
  ai.stop_force(F)
  territory.flush()
  local cap = cities.get(storage.nations[F].capital)
  S.cap = cap.id
  local surface = match.surface()
  -- a lab, a factory and a barracks next to the CC; a house and a farm
  local function put(name, dx, dy)
    local p = surface.find_non_colliding_position(name, {cap.position.x + dx, cap.position.y + dy}, 12, 1, true)
    return p and surface.create_entity({name = name, position = p, force = F, raise_built = true})
  end
  S.lab = put("rts-lab", -10, -10)
  S.factory = put("rts-factory", 12, -10)
  S.barracks = put("rts-barracks", -12, 10)
  put("rts-house", 14, 12)
  put("rts-farm", 20, 0)
  put("rts-bakery", -18, 0)
  if S.barracks then production.set_recipe(S.barracks, "rts-walker-kit") end
  local P = population.get(cap.id)
  P.pop = 60 -- 36 workers: not every job is staffed
  labor.step_city(cap.id)
  camera.jump_to(player, cap.position)
  player.zoom = 0.6
  selection.select_building(player.index, cap.center)
  local g = storage.players[player.index].citygui
  g.prio_open = true
  citygui.refresh(player.index, true)
  return 120
end)

step(function(player, S)
  local g = storage.players[player.index].citygui
  util.log("peoplegui: city panel: %s", table.concat(frame_text(g and g.frame), " | "))
  capture(player, "panel")
  return 60
end)

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, child in pairs(el.children) do
    local f = find(child, name)
    if f then return f end
  end
  return nil
end

-- the panel's controls through the real event handlers: Military one down, draft 50 %
step(function(player, S)
  local g = storage.players[player.index].citygui
  local down = find(g and g.frame, "rts_citygui_prio_down_military")
  if down then events.dispatch(defines.events.on_gui_click, {element = down, player_index = player.index,
                                                              button = defines.mouse_button_type.left}) end
  local dd = find(g and g.frame, "rts_citygui_draft")
  if dd then
    dd.selected_index = #dd.items
    events.dispatch(defines.events.on_gui_selection_state_changed, {element = dd, player_index = player.index})
  end
  local P = population.get(S.cap)
  util.log("peoplegui: clicked: priorities %s; draft %s", table.concat(labor.priorities(player.force.name), ">"),
    tostring(P and P.draft))
  return 60
end)

step(function(player, S)
  -- the factory (services, ranked last): partly staffed or stopped; its staffing box and the HUD status line
  selection.clear(player.index)
  if S.factory and S.factory.valid then selection.select_building(player.index, S.factory.unit_number) end
  citygui.refresh(player.index)
  hud.refresh(player.index)
  return 90
end)

step(function(player, S)
  local g = storage.players[player.index].citygui
  util.log("peoplegui: staffing box: %s; factory staffing %s, status %s", table.concat(frame_text(g and g.staff), " | "),
    S.factory and S.factory.valid and tostring(labor.staffing(S.factory)) or "-",
    S.factory and S.factory.valid and serpent.line(S.factory.custom_status) or "-")
  capture(player, "staff")
  -- pin it through the staffing box's button: it is staffed first
  local pin = g and g.staff_el and g.staff_el.pin
  if pin and pin.valid then
    events.dispatch(defines.events.on_gui_click, {element = pin, player_index = player.index,
                                                  button = defines.mouse_button_type.left})
  end
  labor.step_city(S.cap)
  citygui.refresh(player.index)
  return 90
end)

step(function(player, S)
  local g = storage.players[player.index].citygui
  util.log("peoplegui: pinned: %s; factory staffing %s", table.concat(frame_text(g and g.staff), " | "),
    S.factory and S.factory.valid and tostring(labor.staffing(S.factory)) or "-")
  capture(player, "pinned")
  -- the barracks: draft 0, no unemployed worker -> "no recruits"
  population.set_draft(S.cap, 0)
  local P = population.get(S.cap)
  P.pop = 25
  labor.step_city(S.cap)
  if S.barracks and S.barracks.valid then S.barracks.get_output_inventory().insert({name = "rts-walker-kit", count = 1}) end
  selection.clear(player.index)
  if S.barracks and S.barracks.valid then selection.select_building(player.index, S.barracks.unit_number) end
  return 150
end)

step(function(player, S)
  hud.refresh(player.index)
  local rec = S.barracks and S.barracks.valid and buildings.get(S.barracks.unit_number)
  util.log("peoplegui: barracks block %s", rec and rec.surcharge_block and rec.surcharge_block.reason or "none")
  capture(player, "recruits")
  return 60
end)

step(function(player)
  selection.clear(player.index)
  hud.set_build_tab(player, "production")
  hud.refresh(player.index)
  return 60
end)

step(function(player)
  capture(player, "buildmenu")
  return 30
end)

step(function()
  util.log("RTS_PEOPLEGUI_DONE")
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local S = storage.peoplegui_probe
  if not S then
    S = {i = 1, at = game.tick + 180}
    storage.peoplegui_probe = S
  end
  if S.done or game.tick < S.at then return end
  local ok, wait = pcall(STEPS[S.i], player, S)
  if not ok then
    util.log("peoplegui: step %d failed: %s", S.i, tostring(wait))
    wait = 30
  end
  S.i = S.i + 1
  if S.i > #STEPS then
    S.done = true
    return
  end
  S.at = game.tick + (wait or 30)
end)
