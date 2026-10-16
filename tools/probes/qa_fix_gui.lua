-- Phase 4 QA fixes, GUI probe (test copy for tools/gui-run.sh with the self-test off; append
-- require("scripts.qa_fix_gui") to control.lua). Drives the real client through the same functions the input
-- handlers call and logs "[rts] qafix probe <name>: PASS|FAIL ..." lines, then RTS_QAFIX_PROBE_DONE.
--   geometry   markers at a walker's feet (red), torso (yellow) and engine selection box (blue); zoomed screenshots
--   click      0x0 selection areas with no engine hits at the feet, the torso and between: the walker is picked
--   hubpanel   select a hub, its panel opens; the close button (dispatched click) hides it; deselect and select the
--              hub again: the panel is back (QA step 28)
--   hover      hover selection and the entity tooltip are off; a vanilla entity window is closed again; R rotates
--              the inserter under the cursor
--   wrap       an extractor and the hub selected: the building page's long lines wrap (screenshots)
--   factory    a new factory's page counts 0 crafted after a factory of the same force crafted (QA reset finding)
--   end        Concede: forces cease fire on each other, AI commanders stop, units stand; F and right clicks refused
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local economy = require("scripts.economy")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("qafix probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag, position, zoom)
  local path = string.format("rts-qafix-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = position or player.position, zoom = zoom or player.zoom})
  util.log("qafix probe: screenshot %s", path)
end

local function place(name, near, force)
  local surface = match.surface()
  local pos = surface.find_non_colliding_position(name, near, 20, 1, true) or near
  return surface.create_entity({name = name, position = pos, force = force, raise_built = true})
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

-- 1: start the match from the lobby
step(function(player, P)
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 180
end)

-- 2: geometry and click picks
step(function(player, P)
  local F = player.force.name
  local w
  for _, rec in units.for_force(F) do
    if rec.kind == "walker" then w = rec.entity break end
  end
  if not w then check("click", false, "no walker") return 60 end
  P.walker = w
  local surface = w.surface
  local h = 0
  pcall(function() h = w.prototype.height end)
  local p, box = w.position, w.selection_box
  rendering.draw_circle({color = {1, 0, 0}, radius = 0.2, filled = true, target = p, surface = surface, time_to_live = 600})
  rendering.draw_circle({color = {1, 1, 0}, radius = 0.2, filled = true, target = {p.x, p.y - h}, surface = surface,
                         time_to_live = 600})
  rendering.draw_rectangle({color = {0, 0.4, 1}, width = 2, left_top = box.left_top, right_bottom = box.right_bottom,
                            surface = surface, time_to_live = 600})
  util.log("qafix probe: walker #%d at %s, height %.2f, selection box %s-%s, prototype box %s", w.unit_number,
    util.pos_str(p), h, util.pos_str(box.left_top), util.pos_str(box.right_bottom),
    serpent.line(w.prototype.selection_box))
  camera.jump_to(player, p)
  shot(player, "geometry-z1", p, 1.0)
  shot(player, "geometry-z05", p, 0.5)
  local results, ok = {}, true
  for _, off in ipairs({{0, 0}, {0, -h}, {0, -h / 2}, {0.6, -h}, {0, -2 * h}, {-0.6, -2 * h}}) do
    local pt = {x = p.x + off[1], y = p.y + off[2]}
    selection.clear(player.index)
    selection.handle_area(player.index, {}, {left_top = pt, right_bottom = pt}, false, surface)
    local sel = selection.get(player.index)
    local got = sel[1] and sel[1].unit_number
    results[#results + 1] = string.format("(%+.1f,%+.1f)->%s", off[1], off[2], tostring(got))
    if got ~= w.unit_number then ok = false end
  end
  selection.clear(player.index)
  check("click", ok, "0x0 clicks with no engine hits on walker #%d: %s", w.unit_number, table.concat(results, " "))
  return 60
end)

-- 3: hub panel close and reopen
step(function(player, P)
  local cc = buildings.main_cc(player.force.name)
  P.hub = place("rts-hub", {x = cc.entity.position.x + 14, y = cc.entity.position.y - 14}, player.force)
  selection.select_building(player.index, P.hub.unit_number)
  return 60
end)
step(function(player, P)
  P.open1 = player.gui.screen.rts_hubgui_frame ~= nil
  local close = find(player.gui.screen.rts_hubgui_frame, "rts_hubgui_close")
  if close then events.dispatch(defines.events.on_gui_click, {element = close, player_index = player.index,
                                                                name = defines.events.on_gui_click}) end
  return 30
end)
step(function(player, P)
  P.closed = player.gui.screen.rts_hubgui_frame == nil
  selection.clear(player.index)
  return 30
end)
step(function(player, P)
  selection.select_building(player.index, P.hub.unit_number)
  return 30
end)
step(function(player, P)
  local reopened = player.gui.screen.rts_hubgui_frame ~= nil
  check("hubpanel", P.open1 and P.closed and reopened, "opened %s, closed by the x %s, reopened after deselect and "
    .. "reselect %s", tostring(P.open1), tostring(P.closed), tostring(reopened))
  camera.jump_to(player, P.hub.position)
  shot(player, "wrap-hub")
  return 30
end)

-- 4: extractor page (wrapped hint) and the tooltip test
step(function(player, P)
  local home = match.home(player.force.name)
  local ore = match.surface().find_entities_filtered({position = home, radius = 40, type = "resource", name = "iron-ore",
                                                       limit = 1})[1]
  P.extractor = ore and place("rts-extractor", ore.position, player.force)
  if P.extractor then selection.select_building(player.index, P.extractor.unit_number) end
  return 30
end)
step(function(player, P)
  if P.extractor then
    camera.jump_to(player, P.extractor.position)
    shot(player, "wrap-extractor")
  end
  selection.clear(player.index)
  local cc = buildings.main_cc(player.force.name).entity
  camera.jump_to(player, cc.position)
  player.selected = cc
  P.gvs_tip = player.game_view_settings.show_entity_tooltip
  P.gvs_sel = player.game_view_settings.update_entity_selection
  util.log("qafix probe: tooltip test: selected %s, show_entity_tooltip %s, update_entity_selection %s",
    tostring(player.selected and player.selected.name), tostring(P.gvs_tip), tostring(P.gvs_sel))
  check("hover", P.gvs_sel == false and P.gvs_tip == false, "update_entity_selection %s, show_entity_tooltip %s",
    tostring(P.gvs_sel), tostring(P.gvs_tip))
  player.selected = nil
  -- a vanilla entity window opened by script is closed again (camera.lua on_gui_opened)
  pcall(function() player.opened = cc end)
  return 30
end)
step(function(player, P)
  check("entity_window", player.opened == nil, "player.opened after opening the CC's window: %s",
    tostring(player.opened and (player.opened.name or player.opened.object_name)))
  -- R on a placed inserter (hover is off: selection.rotate_at by the cursor position)
  local cc = buildings.main_cc(player.force.name)
  local ins = place("fast-inserter", {x = cc.entity.position.x - 12, y = cc.entity.position.y + 12}, player.force)
  local before = ins and ins.direction
  local rotated = ins and selection.rotate_at(player.index, ins.position, false)
  check("rotate", ins ~= nil and rotated == ins and ins.direction ~= before, "inserter direction %s -> %s",
    tostring(before), tostring(ins and ins.direction))
  return 30
end)

-- 5: factory counters per building
step(function(player, P)
  local cc = buildings.main_cc(player.force.name)
  economy.give(player.force.name, "iron-plate", 400)
  economy.give(player.force.name, "copper-plate", 200)
  P.f1 = place("rts-factory", {x = cc.entity.position.x + 10, y = cc.entity.position.y + 10}, player.force)
  local ok = pcall(function() P.f1.set_recipe("rts-gear") end)
  util.log("qafix probe: factory #%d recipe gear %s", P.f1.unit_number, tostring(ok))
  return 300
end)
step(function(player, P)
  local r1 = buildings.get and buildings.get(P.f1.unit_number) or (storage.buildings or {})[P.f1.unit_number]
  local cc = buildings.main_cc(player.force.name)
  P.f2 = place("rts-factory", {x = cc.entity.position.x + 10, y = cc.entity.position.y + 18}, player.force)
  local r2 = (storage.buildings or {})[P.f2.unit_number]
  check("factory", (r1 and (r1.made or 0) > 0) and r2 and (r2.made or 0) == 0 and (r2.moved or 0) == 0,
    "first factory made %s moved %s; new factory made %s moved %s", tostring(r1 and r1.made), tostring(r1 and r1.moved),
    tostring(r2 and r2.made), tostring(r2 and r2.moved))
  selection.select_building(player.index, P.f2.unit_number)
  return 30
end)
step(function(player, P)
  camera.jump_to(player, P.f2.position)
  shot(player, "factory-new")
  selection.clear(player.index)
  return 30
end)

-- 6: concede, then a calm field and locked orders
step(function(player, P)
  lobby.toggle_menu(player)
  local b = find(player.gui.screen.rts_menu, "rts_lobby_menu_concede")
  lobby.on_click({element = b, player_index = player.index, name = defines.events.on_gui_click})
  b = find(player.gui.screen.rts_menu, "rts_lobby_menu_concede")
  lobby.on_click({element = b, player_index = player.index, name = defines.events.on_gui_click})
  return 120
end)
step(function(player, P)
  local m = storage.match
  local ceasefire = true
  for _, a in ipairs(m.forces) do
    for _, b in ipairs(m.forces) do
      if a ~= b and not game.forces[a].get_cease_fire(b) then ceasefire = false end
    end
  end
  local commanders = table_size(storage.ai or {})
  local busy = 0
  for _, rec in pairs(storage.units) do
    if rec.entity.valid and rec.order ~= units.IDLE and rec.kind ~= "hauler" and rec.kind ~= "commander" then busy = busy + 1 end
  end
  local armed = orders.arm_attack_move(player.index, true)
  local order = orders.handle_reverse_area(player.index, {}, {left_top = player.position, right_bottom = player.position},
    false)
  check("end", m.phase == "ended" and ceasefire and commanders == 0 and busy == 0 and armed == false and order == "none",
    "phase %s, cease fire between all match forces %s, AI commanders %d, units with an order %d, F arms %s, right click "
    .. "-> %s", m.phase, tostring(ceasefire), commanders, busy, tostring(armed), tostring(order))
  shot(player, "end-results")
  return 60
end)
step(function(player, P)
  util.log("RTS_QAFIX_PROBE_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.qafix_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.qafix_probe = P
  end
  if P.done or game.tick < P.at then return end
  local wait = STEPS[P.i](player, P)
  P.i = P.i + 1
  if not wait or P.i > #STEPS then P.done = true return end
  P.at = game.tick + wait
end)
