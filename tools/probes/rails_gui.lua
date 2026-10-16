-- Phase 5 M1 rails, GUI probe (test copy for tools/gui-run.sh with the self-test off; append
-- require("scripts.rails_gui") to control.lua). Starts a Skirmish match from the lobby, switches the rails module to
-- Nation rules (storage.rails.test_nation, as the autotest does), and drives the real client through the functions the
-- input handlers call. Logs "[rts] rails gui probe <name>: PASS|FAIL ..." lines, screenshots, then RTS_RAILS_GUI_DONE.
--   buildmenu  the economy tab lists the depot in Nation rules (after a tab switch), not before
--   depot      selecting a depot opens the depot rail panel left of the hub panel
--   layrail    right-click on the second depot with the first selected plans a line; it opens
--   deploy     the panel's "Deploy freight train" button assembles a train on the platform
--   train      selecting the train opens the train panel; right-click / Shift + right-click on the depots set the route
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local logistics = require("scripts.logistics")
local rails = require("scripts.rails")
local hud = require("scripts.hud")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("rails gui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag, position, zoom)
  local path = string.format("rts-rails-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = position or player.position, zoom = zoom or player.zoom})
  util.log("rails gui probe: screenshot %s", path)
end

local function area_at(pos)
  return {left_top = {x = pos.x - 0.01, y = pos.y - 0.01}, right_bottom = {x = pos.x + 0.01, y = pos.y + 0.01}}
end

local function depot_near(player, want)
  local surface = match.surface()
  for r = 0, 60, 4 do
    for a = 0, 7 do
      local p = {x = math.floor(want.x + r * math.cos(a * math.pi / 4) + 0.5),
                 y = math.floor(want.y + r * math.sin(a * math.pi / 4) + 0.5)}
      if surface.can_place_entity({name = rails.DEPOT, position = p, force = player.force,
                                   build_check_type = defines.build_check_type.manual_ghost, forced = true})
         and rails.platform_fits(surface, player.force.name, p) then
        return surface.create_entity({name = rails.DEPOT, position = p, force = player.force, raise_built = true})
      end
    end
  end
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

-- 1: start the match from the lobby
step(function(player, P)
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 180
end)

-- 2: build menu in Skirmish, then Nation rules
step(function(player, P)
  P.skirmish_depot = find(player.gui.screen, "rts_hud_build_rts-depot") ~= nil
  storage.rails = storage.rails or {}
  storage.rails.test_nation = true
  -- the HUD's Nation-only filter reads the match mode: Nation for this check only (other M1 modules watch it too)
  storage.match.config.mode = "nation"
  hud.set_build_tab(player, "production")
  hud.set_build_tab(player, "economy")
  return 30
end)

step(function(player, P)
  local nation_depot = find(player.gui.screen, "rts_hud_build_rts-depot") ~= nil
  check("buildmenu", not P.skirmish_depot and nation_depot, "depot button in Skirmish %s, in Nation rules %s",
    tostring(P.skirmish_depot), tostring(nation_depot))
  shot(player, "buildmenu")
  storage.match.config.mode = nil
  -- two depots: next to the CC and 100 tiles towards the arena centre
  local cc = buildings.main_cc(player.force.name)
  local c = cc.entity.position
  local len = math.sqrt(c.x * c.x + c.y * c.y)
  local ux, uy = -c.x / len, -c.y / len
  -- both behind / beside the own base, away from the enemy (a depot at the arena centre is attacked at once)
  P.a = depot_near(player, {x = c.x - ux * 22, y = c.y - uy * 22})
  P.b = depot_near(player, {x = c.x - uy * 80, y = c.y + ux * 80})
  if not (P.a and P.b) then
    check("depot", false, "depots could not be placed (%s, %s)", tostring(P.a), tostring(P.b))
    return 30
  end
  for _, d in ipairs({P.a, P.b}) do
    local net = logistics.hub_network(d.unit_number)
    for name, n in pairs({[rails.LOCO_KIT] = 4, [rails.WAGON_KIT] = 2, [rails.CWAGON_KIT] = 1, [rails.RAIL] = 400,
                          coal = 100, ["iron-plate"] = d == P.a and 2000 or nil}) do
      net.insert({name = name, count = n})
    end
  end
  logistics.set_policy(P.a.unit_number, "export_above", "iron-plate", 0)
  logistics.set_policy(P.b.unit_number, "keep", "iron-plate", 1000)
  selection.select_building(player.index, P.a.unit_number)
  camera.jump_to(player, P.a.position)
  return 30
end)

-- depot panel
step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame
  local hub = player.gui.screen.rts_hubgui_frame
  check("depot", frame ~= nil and hub ~= nil and frame.location.x < hub.location.x,
    "rail panel %s at %s, hub panel %s at %s", tostring(frame ~= nil), frame and serpent.line(frame.location) or "-",
    tostring(hub ~= nil), hub and serpent.line(hub.location) or "-")
  shot(player, "depot-panel", P.a.position)
  -- lay rail: right click on depot B with depot A selected
  P.order = orders.handle_reverse_area(player.index, {P.b}, area_at(P.b.position), false)
  P.t_line = game.tick
  return 60
end)

step(function(player, P)
  local d = rails.depot(P.a.unit_number)
  local line = d and d.line and rails.lines[d.line]
  if not (line and line.state == "open") and game.tick - P.t_line < 150 * 60 then
    if (game.tick - P.t_line) % 600 < 30 then
      shot(player, "building-" .. math.floor((game.tick - P.t_line) / 60), P.a.position, 0.4)
    end
    P.i = P.i - 1 -- repeat this step
    return 30
  end
  check("layrail", P.order == "lay-rail" and line ~= nil and line.state == "open",
    "order %s, line %s %s after %.0f s (%d pieces)", tostring(P.order), tostring(line and line.id),
    tostring(line and line.state), (game.tick - P.t_line) / 60, line and line.pieces and #line.pieces or 0)
  selection.select_building(player.index, P.a.unit_number)
  return 30
end)

-- deploy button
step(function(player, P)
  local d = rails.depot(P.a.unit_number)
  local line = d and d.line and rails.lines[d.line]
  if line and line.builder then
    P.i = P.i - 1
    return 30
  end
  local button = find(player.gui.screen.rts_railgui_frame, "rts_railgui_deploy")
  if button then
    events.dispatch(defines.events.on_gui_click, {element = button, player_index = player.index,
                                                  name = defines.events.on_gui_click, button = defines.mouse_button_type.left})
  end
  return 30
end)

step(function(player, P)
  local trains = rails.trains_of(player.force.name)
  local rec = trains[#trains]
  check("deploy", rec ~= nil and rec.kind == "cargo", "%d trains of the force, last %s", #trains,
    rec and (rec.kind .. " " .. rec.id) or "none")
  P.rec = rec
  if rec then
    selection.select_building(player.index, rec.loco.unit_number)
    camera.jump_to(player, rec.loco.position)
  end
  return 30
end)

-- train panel and route orders
step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame
  P.train_panel = frame ~= nil
  shot(player, "train-panel-unset")
  if not (P.a.valid and P.b.valid) then
    check("train", false, "a depot is gone (A %s, B %s)", tostring(P.a.valid), tostring(P.b.valid))
    return 30
  end
  P.o1 = orders.handle_reverse_area(player.index, {P.a}, area_at(P.a.position), false)
  P.o2 = orders.handle_reverse_area(player.index, {P.b}, area_at(P.b.position), true)
  return 30
end)

step(function(player, P)
  local rec = P.rec
  check("train", P.train_panel and P.o1 == "train-pickup" and P.o2 == "train-dropoff" and rec ~= nil
    and rec.pickup == P.a.unit_number and rec.dropoff == P.b.unit_number,
    "panel %s, orders %s / %s, route #%s -> #%s, state %s", tostring(P.train_panel), tostring(P.o1), tostring(P.o2),
    tostring(rec and rec.pickup), tostring(rec and rec.dropoff), tostring(rec and rec.state))
  shot(player, "train-panel-route")
  P.t_trip = game.tick
  return 600
end)

step(function(player, P)
  if P.rec and P.rec.loco.valid then camera.jump_to(player, P.rec.loco.position) end
  shot(player, "train-running", nil, 0.5)
  return 600
end)

step(function(player, P)
  shot(player, "train-later")
  local rec = P.rec
  check("delivery", rec ~= nil and (rec.delivered["iron-plate"] or 0) > 0, "train %s state %s delivered %s",
    tostring(rec and rec.id), tostring(rec and rec.state), rec and serpent.line(rec.delivered) or "-")
  util.log("RTS_RAILS_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.rails_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.rails_gui_probe = P
  end
  if P.done or game.tick < P.at then return end
  local fn = STEPS[P.i]
  P.i = P.i + 1
  local wait = fn(player, P)
  if not wait or P.i > #STEPS then
    P.done = true
    return
  end
  P.at = game.tick + wait
end)
