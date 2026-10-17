-- Phase 5 M3 air GUI probe (test copy for tools/gui-run.sh: copy into scripts/ and append require("scripts.air_gui") to
-- control.lua; docs/qa/phase5-air-notes.md section 1). Drives the real client through the air content and takes
-- screenshots; logs "[rts] air gui probe <name>: PASS|FAIL ..." lines, then RTS_AIR_GUI_PROBE_DONE.
--   setup      a Nation match; the player's force in Age III with Aviation and Air Force, an airfield and an AA turret by
--              the capital, magazines in the network, 3 scouts, 2 bombers and 3 interceptors on the apron
--   airfield   the airfield selected: the HUD building page with the air lines
--   panel      Y (the key's handler) opens the air panel; the planes selected: the selection line and both buttons
--   division   the 3 interceptors form a division: its card in the division panel; on patrol the card says "Patrol"
--   patrol     Patrol armed by its button, a right click sets the centre: the selected planes patrol
--   aa         an enemy bomber over the AA turret: it fires, the bomber dies
--   return     Return to airfield: the planes fly home
--   help       F11: the Nation help page with the air line
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local cities = require("scripts.cities")
local research = require("scripts.research")
local hud = require("scripts.hud")
local air = require("scripts.air")
local divisions = require("scripts.divisions")

local ENEMY = "rts-ai-2"

local function find_tag(el, value)
  if not (el and el.valid) then return nil end
  if el.tags and el.tags.rts_air == value then return el end
  for _, c in pairs(el.children) do
    local f = find_tag(c, value)
    if f then return f end
  end
end

-- An element whose caption is the locale key `key` (or a table starting with it), anywhere under `el`.
local function find_caption(el, key)
  if not (el and el.valid) then return nil end
  local ok, c = pcall(function() return el.caption end)
  if ok and type(c) == "table" and c[1] == key then return el end
  for _, ch in pairs(el.children) do
    local f = find_caption(ch, key)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("air gui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag)
  local path = string.format("rts-air-gui-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  util.log("air gui probe: screenshot %s", path)
end

local function click(player, el)
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function()
  lobby.start_match({opponents = 1, difficulty = "normal", enemy_brain = "ai", mode = "nation"}, "air gui probe")
  return 600
end)

step(function(player, P)
  local F = player.force.name
  local s = player.surface
  local cap = cities.get(storage.nations[F].capital)
  storage.ages[F] = storage.ages[F] or {}
  storage.ages[F].age = 3
  for _, name in ipairs({"rts-aviation", "rts-air-force"}) do player.force.technologies[name].researched = true end
  research.apply(player.force)
  local p = cap.position
  local fpos = s.find_non_colliding_position("rts-airfield", {p.x, p.y + 30}, 30, 1, true)
  P.field = s.create_entity({name = "rts-airfield", position = fpos, force = F, raise_built = true})
  local apos = s.find_non_colliding_position("rts-aa-turret", {fpos.x + 10, fpos.y}, 20, 1, true)
  P.aa = s.create_entity({name = "rts-aa-turret", position = apos, force = F, raise_built = true})
  P.aa.insert({name = "firearm-magazine", count = 20})
  P.planes = {}
  local k = 0
  for _, spec in ipairs({{"rts-scout-plane", 3}, {"rts-bomber", 2}, {"rts-interceptor", 3}}) do
    for _ = 1, spec[2] do
      k = k + 1
      local e = units.spawn(spec[1], {x = fpos.x - 6 + (k % 4) * 3, y = fpos.y - 2 + math.floor(k / 4) * 3}, F, nil, s)
      if e then P.planes[#P.planes + 1] = e end
    end
  end
  local wing = {}
  for _, e in ipairs(P.planes) do if e.name == "rts-interceptor" then wing[#wing + 1] = e end end
  P.div = divisions.create(F, wing, {name = "Air wing"}, {owner = "player"})
  camera.jump_to(player, P.field.position)
  player.zoom = 1.2
  selection.select_building(player.index, P.field.unit_number)
  check("setup", P.field ~= nil and P.aa ~= nil and #P.planes == 8, "airfield %s, AA turret %s, %d planes; Air Force %s",
    tostring(P.field ~= nil), tostring(P.aa ~= nil), #P.planes, research.status(F, "rts-air-force"))
  return 90
end)

step(function(player, P)
  shot(player, "1-airfield-page")
  return 30
end)

step(function(player, P)
  selection.set(player.index, P.planes)
  events.dispatch("rts-airfield-panel", {name = "rts-airfield-panel", player_index = player.index, tick = game.tick})
  return 90
end)

step(function(player, P)
  local f = player.gui.screen.rts_airfield_panel
  local patrol, ret = find_tag(f, "patrol"), find_tag(f, "return")
  check("panel", f ~= nil and patrol ~= nil and patrol.enabled and ret ~= nil and ret.enabled,
    "Y opened the panel %s, Patrol %s, Return %s", tostring(f ~= nil), patrol and tostring(patrol.enabled) or "-",
    ret and tostring(ret.enabled) or "-")
  shot(player, "2-panel")
  if patrol then click(player, patrol) end
  return 30
end)

step(function(player, P)
  local f = player.gui.screen.rts_airfield_panel
  shot(player, "3-patrol-armed")
  local c = {x = P.field.position.x + 50, y = P.field.position.y + 10}
  P.center = c
  local order, n = orders.handle_reverse_area(player.index, {}, {left_top = c, right_bottom = c}, false)
  check("patrol", order == "patrol" and n == #P.planes, "the right click after Patrol: %s for %s planes", tostring(order),
    tostring(n))
  return 600
end)

step(function(player, P)
  camera.jump_to(player, P.center)
  player.zoom = 1.0
  local n = 0
  for _, e in ipairs(P.planes) do
    local rec = e.valid and storage.units[e.unit_number]
    if rec and rec.order == "patrol" then n = n + 1 end
  end
  check("patrolling", n == #P.planes, "%d of %d planes on patrol after 10 s", n, #P.planes)
  local D = divisions.get(P.div)
  local card = find_caption(player.gui.screen.rts_div_panel, "rts-air.order-patrol")
  check("division_card", D ~= nil and D.state == "patrolling" and card ~= nil,
    "the air wing (3 interceptors): division %s, its card shows the patrol order %s", D and D.state or "gone",
    tostring(card ~= nil))
  return 30
end)

step(function(player, P)
  shot(player, "4-patrol")
  if not game.forces[ENEMY] then game.create_force(ENEMY) end
  game.forces[ENEMY].set_cease_fire(player.force, false)
  player.force.set_cease_fire(ENEMY, false)
  local p = P.aa.position
  P.enemy = units.spawn("rts-bomber", {x = p.x + 4, y = p.y - 4}, ENEMY, nil, player.surface)
  P.enemy.commandable.set_command({type = defines.command.stop, distraction = defines.distraction.none})
  camera.jump_to(player, p)
  player.zoom = 1.5
  return 70
end)

step(function(player, P)
  shot(player, "5-aa-firing")
  return 600
end)

step(function(player, P)
  local mags = P.aa.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine")
  check("aa", not P.enemy.valid, "enemy bomber over the AA turret: %s, the turret holds %d magazines",
    P.enemy.valid and "alive" or "dead", mags)
  selection.set(player.index, P.planes)
  local ret = find_tag(player.gui.screen.rts_airfield_panel, "return")
  if ret then click(player, ret) end
  local n = 0
  for _, e in ipairs(P.planes) do
    if e.valid and air.state(e.unit_number) == "returning" then n = n + 1 end
  end
  local D = divisions.get(P.div)
  check("return", n > 0 and D ~= nil and D.state == "idle", "%d planes returning after Return to airfield, the air wing %s",
    n, D and D.state or "gone")
  camera.jump_to(player, P.field.position)
  return 420
end)

step(function(player, P)
  shot(player, "6-return")
  hud.toggle_help(player, "air gui probe")
  return 30
end)

step(function(player, P)
  local f = player.gui.screen.rts_hud_help
  check("help", f ~= nil, "F11 page open %s", tostring(f ~= nil))
  shot(player, "7-help")
  util.log("RTS_AIR_GUI_PROBE_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.air_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.air_gui_probe = P
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
