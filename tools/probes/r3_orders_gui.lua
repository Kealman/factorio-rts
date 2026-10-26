-- Release 0.1.2 r3-orders (#22) GUI probe: the craft queue in the building panel, EN and RU (RTS_LOCALE=ru).
-- A Skirmish match is started, the AI stopped, a factory and a barracks placed and stocked. The recipe buttons are
-- clicked through the real on_gui_click handler with the modifier flags a real click carries (plain, Shift, Ctrl, right
-- button, Shift + right), exactly the event the engine raises; screenshots show the panel (the remaining count on the
-- button and in the status line, the Endless toggle). Log lines "[rts] r3 gui <check>: PASS|FAIL ..." and the stop marker
-- RTS_R3_ORDERS_GUI_DONE. Test copy, one GUI slot (plan rule 8):
--   rm -rf build/r3og-en && mkdir -p build/r3og-en && cp -R mods/factorio-rts mods/mod-list.json build/r3og-en/
--   cp tools/probes/r3_orders_gui.lua build/r3og-en/factorio-rts/scripts/
--   printf '\nrequire("scripts.r3_orders_gui")\n' >> build/r3og-en/factorio-rts/control.lua
--   RTS_LOCALE=en tools/gui-run.sh build/r3og-en 400 RTS_R3_ORDERS_GUI_DONE '\[rts\] r3 gui|rror'
-- Screenshots land in build/shots-r3og-en/ (rename the folder to build/shots-r3-orders-en).
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local economy = require("scripts.economy")
local production = require("scripts.production")
local buildings = require("scripts.buildings")
local hud = require("scripts.hud")

local function check(name, ok, fmt, ...)
  util.log("r3 gui %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function click(player, name, mods)
  mods = mods or {}
  local el = find(player.gui.screen, name)
  if not el then
    util.log("r3 gui: button %s missing", name)
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = mods.right and defines.mouse_button_type.right
      or defines.mouse_button_type.left, shift = mods.shift or false, control = mods.control or false, alt = false})
  return true
end

local pending_shot -- {tag, tick}: the screenshot is taken 40 ticks after the click, once the panel has redrawn
local function shot(player, tag) pending_shot = {tag = tag, tick = game.tick + 40} end
local function take_shot(player, tag)
  hud.refresh(player.index)
  game.take_screenshot({player = player, by_player = player, path = "rts-r3og-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}})
end

local function line1(player)
  local el = find(player.gui.screen, "rts_hud_f_line1") or find(player.gui.screen, "rts_hud_b_line1")
  return el and el.caption
end

local S = {step = 0}
local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(s, player)
  lobby.start_match({opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}, "r3 gui probe")
  s.wait = 240
  return true
end)

step(function(s, player)
  local F = player.force.name
  ai.stop_force(util.ENEMY_FORCE)
  storage.match.waves_off, storage.match.enemy_next_wave = true, nil
  local home, surface = match.home(F), match.surface()
  for _, item in ipairs({"iron-plate", "copper-plate", "stone-brick", "steel-plate"}) do economy.give(F, item, 4000) end
  local function put(name, want)
    local pos = surface.find_non_colliding_position(name, want, 12, 1, true)
    return surface.create_entity({name = name, position = pos, force = F, raise_built = true})
  end
  s.factory = put("rts-factory", {x = home.x - 12.5, y = home.y - 10.5})
  s.barracks = put("rts-barracks", {x = home.x + 12.5, y = home.y - 10.5})
  selection.select_building(player.index, s.factory.unit_number)
  s.wait = 90
  return true
end)

step(function(s, player)
  shot(player, "01-idle")
  s.base = (buildings.get(s.factory.unit_number).made or 0)
  check("click_1", click(player, "rts_hud_recipe_rts-extractor"), "plain click on the extractor button")
  s.wait = 60
  return true
end)

step(function(s, player)
  local st = production.status(s.factory.unit_number)
  check("click_1_queue", st.queue and st.queue.total == 1, "status queue total %s", st.queue and st.queue.total or "none")
  shot(player, "02-queue-1")
  s.wait = 600
  return true
end)

step(function(s, player)
  local rec = buildings.get(s.factory.unit_number)
  local st = production.status(s.factory.unit_number)
  check("click_1_done", not st.recipe and (rec.made or 0) - s.base == 1, "made %d, recipe %s, line: stopped",
    (rec.made or 0) - s.base, tostring(st.recipe))
  shot(player, "03-stopped")
  s.base = rec.made or 0
  click(player, "rts_hud_recipe_rts-extractor", {shift = true})
  s.wait = 200
  return true
end)

step(function(s, player)
  local st = production.status(s.factory.unit_number)
  check("shift_5", st.queue and st.queue.total == 5, "Shift click: queue total %s, %s left",
    st.queue and st.queue.total or "none", st.queue and st.queue.remaining or "-")
  shot(player, "04-queue-5-counting")
  s.wait = 90
  s.shift_left = st.queue and st.queue.remaining
  return true
end)

step(function(s, player)
  local st = {queue = {remaining = production.status(s.factory.unit_number).queue.remaining}}
  click(player, "rts_hud_recipe_rts-extractor", {right = true})
  local st2 = production.status(s.factory.unit_number)
  check("right_click", st2.queue and st2.queue.remaining == st.queue.remaining - 1, "right click: %s left (was %s)",
    st2.queue and st2.queue.remaining or "none", st.queue.remaining)
  click(player, "rts_hud_recipe_rts-extractor", {control = true})
  local st3 = production.status(s.factory.unit_number)
  check("ctrl_click", st3.queue and st3.queue.total > 5, "Ctrl click: queue total %s", st3.queue and st3.queue.total or "none")
  shot(player, "05-queue-ctrl")
  s.wait = 90
  return true
end)

step(function(s, player)
  click(player, "rts_hud_recipe_rts-extractor", {right = true, control = true})
  local st4 = production.status(s.factory.unit_number)
  check("ctrl_right", st4.queue == nil and not st4.recipe, "Ctrl + right click empties the order: queue %s, recipe %s",
    st4.queue and st4.queue.remaining or "none", tostring(st4.recipe))
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hud_recipe_endless")
  click(player, "rts_hud_recipe_rts-extractor")
  local st = production.status(s.factory.unit_number)
  check("endless", st.recipe == "rts-extractor" and st.queue == nil, "Endless on + click: recipe %s, queue %s",
    tostring(st.recipe), st.queue and "yes" or "none")
  s.wait = 120
  shot(player, "06-endless")
  return true
end)

step(function(s, player)
  click(player, "rts_hud_recipe_endless") -- off again
  click(player, "rts_hud_recipe_pause")
  local st = production.status(s.factory.unit_number)
  check("pause", not st.recipe, "Pause clears the recipe: %s", tostring(st.recipe))
  selection.select_building(player.index, s.barracks.unit_number)
  s.wait = 90
  return true
end)

step(function(s, player)
  shot(player, "07-barracks-idle")
  s.wait = 90
  return true
end)

step(function(s, player)
  s.spawned = buildings.get(s.barracks.unit_number).spawned or 0
  click(player, "rts_hud_recipe_rts-walker-kit", {shift = true})
  s.wait = 150
  return true
end)

step(function(s, player)
  local st = production.status(s.barracks.unit_number)
  shot(player, "08-barracks-queue-5")
  check("barracks_shift", st.queue ~= nil or (buildings.get(s.barracks.unit_number).spawned or 0) > s.spawned,
    "barracks Shift click: %s left of %s", st.queue and st.queue.remaining or "-", st.queue and st.queue.total or "-")
  s.wait = 900
  return true
end)

step(function(s, player)
  local rec = buildings.get(s.barracks.unit_number)
  local st = production.status(s.barracks.unit_number)
  check("barracks_done", not st.recipe and (rec.spawned or 0) - s.spawned == 5, "spawned %d, recipe %s",
    (rec.spawned or 0) - s.spawned, tostring(st.recipe))
  shot(player, "09-barracks-stopped")
  s.wait = 60
  return true
end)

step(function(s, player)
  util.log("RTS_R3_ORDERS_GUI_DONE")
  return true
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player or S.done then return end
  if pending_shot and game.tick >= pending_shot.tick then
    take_shot(player, pending_shot.tag)
    pending_shot = nil
  end
  S.at = S.at or game.tick + 180
  if game.tick < S.at then return end
  local fn = STEPS[S.step + 1]
  if not fn then
    S.done = true
    return
  end
  S.wait = 0
  if fn(S, player) then
    S.step = S.step + 1
    S.at = game.tick + (S.wait or 0)
  end
end)
