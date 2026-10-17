-- Phase 5 M3 war2 GUI probe (test copy for tools/gui-run.sh: append require("scripts.war2_gui") to the copy's
-- control.lua; RTS_LOCALE=ru for the Russian pass). Drives the real client at 1280x800 through the war2 panels and takes
-- screenshots; logs "[rts] war2 gui probe <name>: PASS|FAIL ..." lines, then RTS_WAR2_GUI_PROBE_DONE.
--   front    a war with touching land (two cities of each side in the corner farthest from the spawns), a 16-walker
--            division of the player selected: its card has the front row and Hold line; the click spreads it along
--            the nearest segment (game-view front lines and labels)
--   belt     the build menu's fort belt button opens the tool; two right-click points; the panel's bill; Build
--   trains   a depot of the player with artillery, armoured and plain kits: the depot panel (kits line, Deploy
--            artillery train, Armoured), the artillery train's panel (stance row, gun line), B = Bombard
--   help     F11 Nation page with the fronts line
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local hud = require("scripts.hud")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local rails = require("scripts.rails")
local wars = require("scripts.wars")
local diplomacy = require("scripts.diplomacy")
local fronts = require("scripts.fronts")
local belts = require("scripts.belts")
local trainswar = require("scripts.trainswar")
local buildings = require("scripts.buildings")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function find_prefix(el, prefix)
  if not (el and el.valid) then return nil end
  if string.sub(el.name or "", 1, #prefix) == prefix then return el end
  for _, c in pairs(el.children) do
    local f = find_prefix(c, prefix)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("war2 gui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag)
  local path = string.format("rts-war2-gui-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  util.log("war2 gui probe: screenshot %s", path)
end

local function click(player, el)
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
end

local function flatten(surface, area)
  local tiles = {}
  for x = area[1][1], area[2][1] - 1 do
    for y = area[1][2], area[2][2] - 1 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, true, true, false)
  for _, e in ipairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "resource",
                                                                          "fish", "corpse"}})) do
    if e.valid then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function()
  lobby.start_match({opponents = 1, difficulty = "normal", enemy_brain = "ai", mode = "nation"}, "war2 gui probe")
  return 600
end)

-- the rig: cities of both sides 100 tiles apart, a war, fronts
step(function(player, P)
  local F = player.force.name
  local E = "rts-ai-1"
  local surface = match.surface()
  local half = (storage.world and storage.world.size or 2048) / 2
  local best, bd
  for _, c in ipairs({{half - 240, half - 240}, {-half + 240, half - 240}, {half - 240, -half + 240},
                      {-half + 240, -half + 240}}) do
    local md
    for _, p in pairs(storage.match.spawns or {}) do
      local d = util.distance(p, {x = c[1], y = c[2]})
      if not md or d < md then md = d end
    end
    if md and (not bd or md > bd) then best, bd = {x = c[1], y = c[2]}, md end
  end
  local dx, dy = best.x > 0 and -1 or 1, best.y > 0 and -1 or 1
  local O = best
  P.O, P.dx, P.dy = O, dx, dy
  local x0, x1 = math.min(O.x - 140 * dx, O.x + 300 * dx), math.max(O.x - 140 * dx, O.x + 300 * dx)
  local y0, y1 = math.min(O.y - 130 * dy, O.y + 240 * dy), math.max(O.y - 130 * dy, O.y + 240 * dy)
  for cx = math.floor(x0 / 32), math.floor(x1 / 32) do
    for cy = math.floor(y0 / 32), math.floor(y1 / 32) do surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end
  end
  surface.force_generate_chunk_requests()
  flatten(surface, {{x0, y0}, {x1, y1}})
  P.cities = {}
  for k, spec in pairs({A1 = {F, 0, 0}, A2 = {F, 160, 0}, B1 = {E, 0, 100}, B2 = {E, 160, 100}}) do
    local id = cities.found(spec[1], {x = O.x + spec[2] * dx, y = O.y + spec[3] * dy}, {why = "(war2 gui probe)"})
    local c = id and cities.get(id)
    if c then cities.set_tier(c, 3, "war2 gui probe") end
    P.cities[k] = id
  end
  territory.flush()
  if diplomacy.state(F, E) ~= "war" then wars.declare(F, E, {kind = "border"}) end
  fronts.flush()
  game.forces[F].technologies["rts-fortification"].researched = true
  -- a division 40 tiles behind the first segment
  local seg = fronts.segments(F)[1]
  local at = seg and {x = seg.mid.x + seg.back.x * 40, y = seg.mid.y + seg.back.y * 40} or O
  local list = {}
  for k = 1, 16 do
    local e = units.spawn("rts-walker", {x = at.x + ((k - 1) % 4) * 3, y = at.y + math.floor((k - 1) / 4) * 3}, F, nil,
      surface)
    if e then list[#list + 1] = e end
  end
  P.div = divisions.create(F, list, {name = "Iron Line", stance = "hold"}, {owner = "player"})
  selection.set(player.index, list)
  camera.jump_to(player, seg and seg.mid or at)
  player.zoom = 0.5
  check("front_setup", seg ~= nil and P.div ~= nil, "%s; division #%s", fronts.describe(F), tostring(P.div))
  return 90
end)

step(function(player, P)
  local panel = player.gui.screen.rts_div_panel
  local btn = find(panel, "rts_div_hold_line_" .. tostring(P.div))
  check("front_card", btn ~= nil, "division panel %s, Hold line button %s", tostring(panel ~= nil), tostring(btn ~= nil))
  shot(player, "1-front-card")
  if btn then click(player, btn) end
  return 900
end)

step(function(player, P)
  local D = divisions.get(P.div)
  check("hold_line", D and D.order and D.order.kind == "hold_line", "division order %s, state %s",
    tostring(D and D.order and D.order.kind), tostring(D and D.state))
  shot(player, "2-hold-line")
  -- the belt tool through the build menu's button
  selection.set(player.index, {})
  local btn = find(player.gui.screen, "rts_hud_fort_belt")
  check("belt_button", btn ~= nil and btn.visible, "build menu fort belt button %s", tostring(btn ~= nil))
  if btn then click(player, btn) end
  local c = cities.get(P.cities.A1)
  local p = c.position
  belts.add_point(player, {x = p.x - 20 * P.dx, y = p.y + 20 * P.dy})
  belts.add_point(player, {x = p.x + 150 * P.dx, y = p.y + 20 * P.dy})
  camera.jump_to(player, {x = p.x + 65 * P.dx, y = p.y + 20 * P.dy})
  player.zoom = 0.35
  return 60
end)

step(function(player, P)
  local frame = player.gui.screen[belts.FRAME]
  check("belt_tool", frame ~= nil, "tool panel %s", tostring(frame ~= nil))
  shot(player, "3-belt-tool") -- the two points, the line and the planned turrets and depot (before Build)
  return 30
end)

step(function(player, P)
  local frame = player.gui.screen[belts.FRAME]
  local c = cities.get(P.cities.A1)
  local net = buildings.get(c.center).entity.logistic_network
  for item, n in pairs({["rts-wall"] = 300, ["rts-gate"] = 10, ["rts-turret"] = 30, ["rts-field-depot"] = 2,
                        ["firearm-magazine"] = 300}) do net.insert({name = item, count = n}) end
  local b = frame and find(frame, "rts_belts_build")
  if b then click(player, b) end
  return 600
end)

step(function(player, P)
  shot(player, "4-belt-building")
  local plans = belts.of(player.force.name)
  check("belt_plan", #plans == 1, "%s", belts.describe(player.force.name))
  belts.close_tool(player, "probe")
  -- a depot with artillery, armoured and plain kits in the second city
  local c = cities.get(P.cities.A2)
  local surface = match.surface()
  local dep = surface.create_entity({name = "rts-depot", position = {c.position.x + 30 * P.dx, c.position.y - 30 * P.dy},
                                     force = player.force, raise_built = true})
  local net = dep and logistics.hub_network(dep.unit_number)
  if net then
    for item, n in pairs({coal = 200, ["rts-locomotive-kit"] = 2, ["rts-artillery-wagon-kit"] = 1, ["rts-rail-shell"] = 40,
                          ["rts-armoured-locomotive-kit"] = 2, ["rts-armoured-wagon-kit"] = 1}) do
      net.insert({name = item, count = n})
    end
  end
  P.depot = dep and dep.unit_number
  if dep then
    selection.select_building(player.index, dep.unit_number)
    camera.jump_to(player, dep.position)
  end
  return 60
end)

step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame
  local btn = frame and find(frame, "rts_trainswar_deploy_artillery")
  check("depot_panel", btn ~= nil and btn.enabled, "depot panel %s, Deploy artillery train %s", tostring(frame ~= nil),
    tostring(btn and btn.enabled))
  shot(player, "5-depot-panel")
  if btn then click(player, btn) end
  return 60
end)

step(function(player, P)
  local trains = rails.trains_of(player.force.name)
  local rec
  for _, t in ipairs(trains) do if t.kind == "artillery" then rec = t end end
  local train = rec and rails.train_of(rec)
  if train then
    selection.select_building(player.index, train.front_stock.unit_number)
    camera.jump_to(player, train.front_stock.position)
  end
  P.train = rec and rec.id
  check("artillery_deployed", train ~= nil, "artillery train %s", tostring(P.train))
  return 60
end)

step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame
  local b = frame and find(frame, "rts_trainswar_stance_bombard")
  check("train_panel", b ~= nil, "train panel %s, Bombard button %s", tostring(frame ~= nil), tostring(b ~= nil))
  trainswar.key_b(player)
  return 60
end)

step(function(player, P)
  check("bombard_key", trainswar.stance(P.train) == "bombard", "stance %s after B", trainswar.stance(P.train))
  shot(player, "6-train-panel")
  selection.set(player.index, {})
  hud.toggle_help(player, "probe")
  return 30
end)

step(function(player, P)
  shot(player, "7-help")
  hud.toggle_help(player, "probe")
  util.log("RTS_WAR2_GUI_PROBE_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.war2_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.war2_gui_probe = P
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
