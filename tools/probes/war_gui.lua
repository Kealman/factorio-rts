-- Phase 5 M2 war GUI probe (test copy for tools/gui-run.sh: append require("scripts.war_gui") to control.lua). Drives the
-- real client through the war panels and takes screenshots; logs "[rts] war gui probe <name>: PASS|FAIL ..." lines, then
-- RTS_WAR_GUI_PROBE_DONE.
--   supply    two divisions of the player: one low (30 SP), one out (0 SP): the division cards show an amber and a red
--             supply bar; an attack-move order to the out division is refused with a flying text
--   garrison  the low division right-clicks into the capital (garrison hook); the capital selected: the garrison row
--             (units, points, guns) and Sortie; Sortie brings it back as a division
--   trains    on a lab surface two depots of the player with kits: Deploy troop train on the depot panel, the troop train
--             panel (title, troops line, Disband), Disband returns half of the kits
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local cities = require("scripts.cities")
local rails = require("scripts.rails")
local garrison = require("scripts.garrison")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("war gui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag)
  local path = string.format("rts-war-gui-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  util.log("war gui probe: screenshot %s", path)
end

local function click(player, el)
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
end

local function spawn(force, at, n)
  local list = {}
  for k = 1, n do
    local e = units.spawn("rts-walker", {x = at.x + ((k - 1) % 4) * 3, y = at.y + math.floor((k - 1) / 4) * 3}, force,
      nil, match.surface())
    if e then list[#list + 1] = e end
  end
  return list
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function()
  lobby.start_match({opponents = 1, difficulty = "normal", enemy_brain = "ai", mode = "nation"}, "war gui probe")
  return 600
end)

step(function(player, P)
  local F = player.force.name
  local cap = cities.get(storage.nations[F].capital)
  P.cap = cap.id
  local p = cap.position
  local a = spawn(F, {x = p.x + 20, y = p.y + 20}, 8)
  local b = spawn(F, {x = p.x + 35, y = p.y + 20}, 8)
  P.low = divisions.create(F, a, {name = "Low Guard", stance = "hold"}, {owner = "player"})
  P.out = divisions.create(F, b, {name = "Lost Patrol", stance = "hold"}, {owner = "player"})
  divisions.get(P.low).sp = 30
  divisions.get(P.out).sp = 0
  camera.jump_to(player, {x = p.x + 25, y = p.y + 20})
  selection.set(player.index, b)
  return 90
end)

step(function(player, P)
  local panel = player.gui.screen.rts_div_panel
  local n = orders.attack_move(player.index, {x = 0, y = 0})
  check("supply_bars", panel ~= nil, "division panel %s", tostring(panel ~= nil))
  check("out_refused", n == 0, "attack-move with the out division selected ordered %d units", n)
  shot(player, "1-supply-bars")
  -- the low division right-clicks into the capital
  local cap = cities.get(P.cap)
  local low = {}
  for _, rec in ipairs(divisions.live_members(divisions.get(P.low))) do low[#low + 1] = rec.entity end
  selection.set(player.index, low)
  local order, k = garrison.right_click(player.index, cap.entity.position, {cap.entity}, false)
  check("garrison_hook", order == "garrison" and k == 8, "right-click on the capital: %s %s", tostring(order),
    tostring(k))
  return 900
end)

step(function(player, P)
  local cap = cities.get(P.cap)
  local gar = garrison.of(P.cap)
  selection.set(player.index, {})
  selection.select_building(player.index, cap.center)
  camera.jump_to(player, cap.position)
  P.records = #gar.records
  return 60
end)

step(function(player, P)
  local panel = player.gui.screen.rts_div_panel
  local sortie = find(panel, "rts_div_sortie")
  check("garrison_row", sortie ~= nil and sortie.enabled and P.records == 8, "garrison row %s, Sortie %s, %d records",
    tostring(sortie ~= nil), sortie and tostring(sortie.enabled) or "-", P.records)
  shot(player, "2-garrison")
  return 30
end)

step(function(player, P)
  local sortie = find(player.gui.screen.rts_div_panel, "rts_div_sortie")
  if sortie then click(player, sortie) end
  return 60
end)

step(function(player, P)
  local gar = garrison.of(P.cap)
  check("sortie_click", #gar.records == 0, "%d records after Sortie", #gar.records)
  shot(player, "3-sortie")
  -- trains on a lab surface
  local s = game.create_surface("war-gui-lab", {width = 600, height = 300, peaceful_mode = true})
  for cx = -6, 5 do for cy = -3, 2 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -180, 179 do for y = -80, 79 do tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}} end end
  s.set_tiles(tiles, true, false, false, false)
  local F = player.force.name
  local d = s.create_entity({name = "rts-depot", position = {x = -100, y = 0}, force = F, raise_built = true})
  P.depot = d.unit_number
  local net = logistics.hub_network(d.unit_number)
  net.insert({name = "rts-locomotive-kit", count = 2})
  net.insert({name = "rts-troop-wagon-kit", count = 2})
  net.insert({name = "coal", count = 50})
  selection.select_building(player.index, P.depot)
  return 60
end)

step(function(player, P)
  local f = player.gui.screen.rts_railgui_frame
  local b = find(f, "rts_railgui_deploy_troop")
  check("deploy_troop_button", b ~= nil and b.enabled, "depot panel %s, Deploy troop train %s", tostring(f ~= nil),
    b and tostring(b.enabled) or "-")
  shot(player, "4-depot-panel")
  return 30
end)

step(function(player, P)
  local b = find(player.gui.screen.rts_railgui_frame, "rts_railgui_deploy_troop")
  if b then click(player, b) end
  return 60
end)

step(function(player, P)
  local rec = garrison.troop_train_at(player.force.name, P.depot)
  local train = rec and rails.train_of(rec)
  check("troop_train_deployed", train ~= nil, "troop train %s", tostring(train and train.id))
  if train then
    P.train = train.id
    selection.select_building(player.index, train.front_stock.unit_number)
  end
  return 60
end)

step(function(player, P)
  local f = player.gui.screen.rts_railgui_frame
  local b = find(f, "rts_railgui_disband")
  check("troop_train_panel", f ~= nil and b ~= nil and b.enabled, "train panel %s, Disband %s", tostring(f ~= nil),
    b and tostring(b.enabled) or "-")
  shot(player, "5-troop-train-panel")
  return 30
end)

step(function(player, P)
  local b = find(player.gui.screen.rts_railgui_frame, "rts_railgui_disband")
  local net = logistics.hub_network(P.depot)
  P.l0 = net.get_item_count("rts-locomotive-kit")
  if b then click(player, b) end
  return 60
end)

step(function(player, P)
  local net = logistics.hub_network(P.depot)
  local l1, w1 = net.get_item_count("rts-locomotive-kit"), net.get_item_count("rts-troop-wagon-kit")
  check("disband_click", l1 == P.l0 + 1 and w1 == 1, "after Disband: %d locomotive kits (+%d), %d troop wagon kits", l1,
    l1 - P.l0, w1)
  util.log("RTS_WAR_GUI_PROBE_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.war_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.war_gui_probe = P
  end
  if P.done or game.tick < P.at then return end
  local wait = STEPS[P.i](player, P)
  P.i = P.i + 1
  if not wait or P.i > #STEPS then
    P.done = true
    return
  end
  P.at = game.tick + wait
end)
