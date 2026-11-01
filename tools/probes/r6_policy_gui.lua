-- Release 0.1.4 r6-hud GUI probe (#46 hub / City Center policy panel, hauler Carry list; #40 Clear button), EN and RU
-- (RTS_LOCALE=ru). A Nation match (both AIs stopped): at the capital with no petroleum, Add item -> petroleum, Keep 200;
-- Age II default rows; a far hub holding petroleum and a hauler route to the capital: the "nothing to load" reason, then
-- Carry petroleum + Unload everything. Log lines "[rts] r6 gui <check>: PASS|FAIL ..." and the stop marker
-- RTS_R6_POLICY_GUI_DONE. Test copy, one GUI slot (screen owner r6-rails):
--   R=build/r6hud-en; rm -rf $R; mkdir -p $R; cp -R mods/factorio-rts mods/mod-list.json $R/
--   cp tools/probes/r6_policy_gui.lua $R/factorio-rts/scripts/; printf '\nrequire("scripts.r6_policy_gui")\n' >> $R/factorio-rts/control.lua
--   RTS_LOCALE=en tools/gui-run.sh $R 300 RTS_R6_POLICY_GUI_DONE '\[rts\] r6 gui|rror'
-- Screenshots land in build/shots-r6hud-en/ (rename to build/shots-r6-hud-en).
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local economy = require("scripts.economy")
local hud = require("scripts.hud")
local ages = require("scripts.ages")
local buildings = require("scripts.buildings")
local logistics = require("scripts.logistics")
local orders = require("scripts.orders")
local units = require("scripts.units")

local ITEM = "rts-petroleum"

local function tree_name()
  local best
  for name, proto in pairs(prototypes.entity) do
    if proto.type == "tree" and (not best or name < best) then best = name end
  end
  return best
end

local function check(name, ok, fmt, ...)
  util.log("r6 gui %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function click(player, name)
  local el = find(player.gui.screen, name)
  if not el then
    util.log("r6 gui: button %s missing", name)
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
  return true
end

local function type_into(player, name, text)
  local el = find(player.gui.screen, name)
  if not el then return false end
  el.text = text
  events.dispatch(defines.events.on_gui_text_changed, {element = el, player_index = player.index, text = text,
    name = defines.events.on_gui_text_changed})
  return true
end

local pending_shot
local function shot(tag) pending_shot = {tag = tag, tick = game.tick + 20} end
local function take_shot(player, tag)
  hud.refresh(player.index)
  game.take_screenshot({player = player, by_player = player, path = "rts-r6hud-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}})
end

local S = {step = 0}
local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(s, player)
  lobby.start_match({opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai", mode = "nation"},
    "r6 gui probe")
  s.wait = 240
  return true
end)

step(function(s, player)
  local F = player.force.name
  s.F = F
  ai.stop_force(F)
  ai.stop_force(util.ENEMY_FORCE)
  storage.match.waves_off, storage.match.enemy_next_wave = true, nil
  local cc, cc_un = buildings.main_cc(F)
  s.cc, s.cc_un = cc, cc_un
  for _, item in ipairs({"iron-plate", "copper-plate", "coal"}) do economy.give(F, item, 500) end
  logistics.set_policy(cc_un, "keep", "coal", 50)
  selection.select_building(player.index, cc_un)
  s.wait = 90
  return true
end)

step(function(s, player)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  check("panel_open", panel ~= nil, "City Center panel open")
  check("nation_rows", find(panel, "rts_hubgui_keep_rts-rations") and find(panel, "rts_hubgui_keep_rts-grain")
    and find(panel, "rts_hubgui_keep_rts-goods"), "rations, grain, goods rows in Age I")
  check("no_oil_age1", not find(panel, "rts_hubgui_keep_" .. ITEM), "no petroleum row before Age II or Add item")
  shot("01-capital-age1")
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hubgui_add_item")
  s.wait = 40
  return true
end)

step(function(s, player)
  check("picker_open", find(player.gui.screen, "rts_itempicker") ~= nil
    and find(player.gui.screen, "rts_itempicker_pick_" .. "transport-belt") ~= nil, "picker open and offers transport belt at zero stock")
  shot("02-picker")
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_itempicker_pick_" .. "transport-belt")
  s.wait = 40
  return true
end)

step(function(s, player)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  check("row_added", find(panel, "rts_hubgui_keep_transport-belt") ~= nil and find(panel, "rts_hubgui_export_" .. "transport-belt") ~= nil,
    "transport belt row added with empty Keep / Export")
  local rm = find(panel, "rts_hubgui_row_remove_" .. "transport-belt")
  local net = logistics.hub_network(s.cc_un)
  local stock = net and net.get_item_count("transport-belt") or 0
  check("x_visible", rm ~= nil and (rm.visible == (stock == 0)), "small x shown only for zero stock (stock %d, visible %s)", stock,
    tostring(rm and rm.visible))
  type_into(player, "rts_hubgui_keep_transport-belt", "200")
  check("keep_set", logistics.policy(s.cc_un).keep["transport-belt"] == 200, "Keep 200 for transport belt at the capital")
  s.wait = 40
  return true
end)

step(function(s, player)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  local rm = find(panel, "rts_hubgui_row_remove_" .. "transport-belt")
  check("x_hidden", rm == nil or not rm.visible, "x hidden while a Keep is set")
  shot("03-keep-200")
  s.wait = 70
  return true
end)

step(function(s, player)
  click(player, "rts_hubgui_add_item")
  s.wait = 30
  return true
end)

step(function(s, player)
  click(player, "rts_itempicker_pick_rail")
  s.wait = 30
  return true
end)

step(function(s, player)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  check("crude_added", find(panel, "rts_hubgui_keep_rail") ~= nil, "rail row added")
  click(player, "rts_hubgui_row_remove_rail")
  s.wait = 30
  return true
end)

step(function(s, player)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  check("crude_removed", find(panel, "rts_hubgui_keep_rail") == nil, "rail row removed with its x")
  game.forces[s.F].technologies["rts-industrialisation"].researched = true
  ages.set_age(s.F, 2, "r6 gui probe")
  s.wait = 60
  return true
end)

step(function(s, player)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  local missing = {}
  for _, item in ipairs({"rts-crude-oil", "rts-petroleum", "plastic-bar", "sulfur"}) do
    if not find(panel, "rts_hubgui_keep_" .. item) then missing[#missing + 1] = item end
  end
  check("age2_rows", #missing == 0, "Age II default rows (crude oil, petroleum, plastic, sulfur) missing: %s",
    table.concat(missing, ","))
  shot("04-capital-age2")
  s.wait = 70
  return true
end)

step(function(s, player)
  click(player, "rts_hubgui_row_remove_" .. ITEM)
  s.wait = 40
  return true
end)

step(function(s, player)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  check("oil_hidden", find(panel, "rts_hubgui_keep_" .. ITEM) == nil, "petroleum default row taken off with its x")
  click(player, "rts_hubgui_add_item")
  s.wait = 40
  return true
end)

step(function(s, player)
  check("picker_oil", find(player.gui.screen, "rts_itempicker_pick_" .. ITEM) ~= nil,
    "Age II picker offers petroleum at zero stock")
  click(player, "rts_itempicker_pick_" .. ITEM)
  s.wait = 40
  return true
end)

step(function(s, player)
  type_into(player, "rts_hubgui_keep_" .. ITEM, "200")
  check("keep_oil", logistics.policy(s.cc_un).keep[ITEM] == 200, "Keep 200 for petroleum at the capital (zero stock)")
  shot("04b-petroleum-keep")
  s.wait = 70
  return true
end)

step(function(s, player)
  -- a far hub with petroleum, a hauler route to the capital
  local cc = s.cc
  local surface = cc.entity.surface
  local want = {x = cc.entity.position.x, y = cc.entity.position.y + 100}
  local pos = surface.find_non_colliding_position(logistics.HUB, want, 30, 1, true) or want
  local hub = surface.create_entity({name = logistics.HUB, position = pos, force = s.F, raise_built = true})
  s.hub = hub.unit_number
  hub.logistic_network.insert({name = ITEM, count = 600})
  local h = logistics.spawn_hauler(surface, buildings.default_exit(cc), s.F, s.cc_un)
  s.hauler = h.unit_number
  logistics.set_pickup(h.unit_number, s.hub)
  logistics.set_dropoff(h.unit_number, s.cc_un)
  selection.set(player.index, {h})
  s.wait = 900
  return true
end)

step(function(s, player)
  local h = logistics.hauler(s.hauler)
  local panel = find(player.gui.screen, "rts_hubgui_frame")
  local why = find(panel, "rts_hubgui_frame") -- placeholder to keep the shape of the checks
  local state = h.state .. "/" .. tostring(h.reason)
  check("hauler_panel", panel ~= nil and find(panel, "rts_hubgui_carry_add") ~= nil and find(panel, "rts_hubgui_unload_all") ~= nil,
    "hauler panel has Carry and Unload (state %s, reason line: %s)", state, tostring(logistics.nothing_reason(s.hauler)))
  shot("05-hauler-nothing")
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hubgui_carry_add")
  s.wait = 40
  return true
end)

step(function(s, player)
  check("carry_picker", find(player.gui.screen, "rts_itempicker_pick_" .. ITEM) ~= nil, "Carry picker offers petroleum")
  click(player, "rts_itempicker_pick_" .. ITEM)
  s.wait = 40
  return true
end)

step(function(s, player)
  local h = logistics.hauler(s.hauler)
  check("carry_set", h.carry and h.carry[ITEM] == 0, "Carry petroleum, count 0 (as much as fits)")
  type_into(player, "rts_hubgui_carry_count_" .. ITEM, "250")
  check("carry_count", h.carry[ITEM] == 250, "Carry count 250 typed")
  click(player, "rts_hubgui_unload_all")
  check("unload_all", h.unload == "all", "Unload everything")
  s.wait = 40
  return true
end)

step(function(s, player)
  shot("06-hauler-carry")
  s.wait = 900
  return true
end)

step(function(s, player)
  local net = logistics.hub_network(s.cc_un)
  local n = net and net.get_item_count(ITEM) or 0
  check("delivered", n > 0, "capital network holds %d petroleum (trips of at most 250) with Keep %s", n,
    tostring(logistics.policy(s.cc_un).keep[ITEM]))
  selection.select_building(player.index, s.cc_un)
  s.wait = 90
  return true
end)

step(function(s, player)
  shot("07-capital-stocked")
  s.wait = 60
  return true
end)

-- #40: the Clear button in the build menu header
step(function(s, player)
  selection.clear(player.index)
  local clear = find(player.gui.screen, "rts_hud_clear_tool")
  check("clear_button", clear ~= nil and clear.visible, "Clear button in the build menu header")
  click(player, "rts_hud_clear_tool")
  check("clear_armed", orders.clear_is_armed(player.index), "armed after a click")
  s.wait = 40
  return true
end)

step(function(s, player)
  shot("08-clear-armed")
  click(player, "rts_hud_clear_tool")
  check("clear_disarmed", not orders.clear_is_armed(player.index), "a second click disarms")
  -- armed + a box with a tree and a selected walker
  local surface = s.cc.entity.surface
  local home = match.home(s.F)
  local pos = {x = home.x + 14, y = home.y + 14}
  for _, t in pairs(surface.find_entities_filtered({position = pos, radius = 10, type = {"tree", "simple-entity"}})) do t.destroy() end
  local walker = units.spawn("rts-walker", pos, s.F, "walker", surface)
  local tree = surface.create_entity({name = tree_name(), position = {x = pos.x + 6, y = pos.y}, force = "neutral"})
  s.tree = tree
  selection.set(player.index, {walker})
  orders.arm_clear(player.index, true)
  local name, n = orders.handle_reverse_area(player.index, {}, {left_top = {x = pos.x + 5.5, y = pos.y - 0.5},
    right_bottom = {x = pos.x + 6.5, y = pos.y + 0.5}}, false)
  check("clear_order", name == "clear" and not orders.clear_is_armed(player.index),
    "armed Clear + plain right click: order %s with %d units, tool disarmed", tostring(name), n or -1)
  s.wait = 30
  return true
end)

step(function(s, player)
  util.log("RTS_R6_POLICY_GUI_DONE")
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
