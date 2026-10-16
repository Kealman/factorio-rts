-- Phase 5 M1 QA round 1 fixes, GUI probe (test copy for tools/gui-run.sh: copy this file into the copy's scripts/ and
-- append require("scripts.m1_qafix_gui") to its control.lua; run with RTS_LOCALE=en). A Nation match in the real
-- client; the player holds the rts-cursor throughout (as in every RTS session) while the probe:
--   * opens the city panel's make-target picker (the add button), checks that it lists Iron gear wheel and no
--     rts-cursor, picks the gear and sets 20 (finding 1, protocol step 15);
--   * opens the ledger's picker, picks Plastic bar, sets 10 (finding 1, protocol step 43); refuses rts-cursor as a target;
--   * selects a ghost (player.selected) and checks that camera.lua clears it (finding 5);
--   * lays a horizontal track with a cargo wagon and a depot and checks the click picks (finding 3);
--   * checks the charter's names and build-menu tooltip and the "Enemies seen" value (finding 4).
-- Log lines "[rts] qafix gui check <name>: PASS|FAIL ...", screenshots rts-qafix-<tag>.png (1280x800, GUI on) and the
-- stop marker RTS_QAFIX_GUI_DONE with the pass count.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local match = require("scripts.match")
local camera = require("scripts.camera")
local cursor = require("scripts.cursor")
local hud = require("scripts.hud")
local cities = require("scripts.cities")
local districts = require("scripts.districts")
local ledgergui = require("scripts.ledgergui")
local itempicker = require("scripts.itempicker")
local rails = require("scripts.rails")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function note(fmt, ...) util.log("qafix gui: " .. fmt, ...) end

local function check(P, name, ok, fmt, ...)
  P.pass, P.total = (P.pass or 0) + (ok and 1 or 0), (P.total or 0) + 1
  util.log("qafix gui check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag, position, zoom)
  local path = string.format("rts-qafix-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = position or player.position, zoom = zoom or player.zoom})
  note("screenshot %s", path)
end

local function click(player, el)
  if not (el and el.valid) then
    note("click: element missing")
    return
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
end

local function type_text(player, el, text)
  el.text = text
  events.dispatch(defines.events.on_gui_text_changed, {element = el, player_index = player.index, text = text,
    name = defines.events.on_gui_text_changed})
end

-- true when the localised string (nested tables) uses `key`
local function uses_key(ls, key)
  if type(ls) ~= "table" then return false end
  if ls[1] == key then return true end
  for i = 2, #ls do if uses_key(ls[i], key) then return true end end
  return false
end

local function picker_items(player)
  local frame = player.gui.screen[itempicker.FRAME]
  local out = {}
  local function walk(el)
    if el.tags and el.tags.rts_itempicker == "pick" then out[#out + 1] = el.tags.item end
    for _, c in pairs(el.children) do walk(c) end
  end
  if frame then walk(frame) end
  return out
end

local function frame_loc(player, name)
  local f = player.gui.screen[name]
  local l = f and f.location
  return l and string.format("(%d,%d)", l.x or 0, l.y or 0) or "-"
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
local function snap(tag, pos_fn, zoom)
  step(function(player, P)
    shot(player, tag, pos_fn and pos_fn(P) or nil, zoom)
    return 15
  end)
end

-- lobby: Mode = Nation, Start
step(function(player, P)
  local dd = find(player.gui.screen.rts_lobby, "rts_lobby_mode")
  if dd then
    dd.selected_index = 2
    events.dispatch(defines.events.on_gui_selection_state_changed,
      {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
  end
  return 30
end)
step(function(player, P)
  click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
  return 360
end)
step(function(player, P)
  ai.stop_force("rts-ai-1")
  P.F = player.force.name
  P.cc = buildings.main_cc(P.F).entity
  P.home = P.cc.position
  P.capital = storage.nations[P.F].capital
  check(P, "cursor_holds_tool", cursor.holds_tool(player), "the player's cursor holds %s",
    player.cursor_stack.valid_for_read and player.cursor_stack.name or "nothing")
  selection.select_building(player.index, P.cc.unit_number)
  return 60
end)
snap("cc-panel")

-- Finding 1: the city panel's picker
step(function(player, P)
  click(player, find(player.gui.screen, "rts_citygui_add"))
  local items = picker_items(player)
  local set = {}
  for _, i in ipairs(items) do set[i] = true end
  check(P, "city_picker_opens", itempicker.is_open(player, "citygui") and #items > 20 and set["iron-gear-wheel"]
    and set["plastic-bar"] and not set[util.CURSOR_ITEM] and cursor.holds_tool(player),
    "picker open %s at %s (city panel at %s), %d goods, gear %s, plastic %s, rts-cursor %s, cursor still %s",
    tostring(itempicker.is_open(player, "citygui")), frame_loc(player, itempicker.FRAME),
    frame_loc(player, "rts_citygui_frame"), #items, tostring(set["iron-gear-wheel"]), tostring(set["plastic-bar"]),
    tostring(set[util.CURSOR_ITEM]), tostring(cursor.holds_tool(player)))
  note("picker goods: %s", table.concat(items, " "))
  return 15
end)
snap("city-picker")
step(function(player, P)
  click(player, find(player.gui.screen[itempicker.FRAME], "rts_itempicker_pick_iron-gear-wheel"))
  local tf = find(player.gui.screen, "rts_citygui_target_iron-gear-wheel")
  click(player, tf) -- select-all on click (no error)
  if tf then type_text(player, tf, "20") end
  local c = cities.get(P.capital)
  check(P, "city_target_gear", not itempicker.is_open(player) and tf ~= nil and c.make["iron-gear-wheel"] == 20
    and c.make[util.CURSOR_ITEM] == nil, "picker closed %s, row %s, make targets %s",
    tostring(not itempicker.is_open(player)), tostring(tf ~= nil), serpent.line(c.make))
  check(P, "cursor_target_refused", cities.set_make_target(P.capital, util.CURSOR_ITEM, 5) == false
    and districts.set_make_target(P.capital, util.CURSOR_ITEM, 5) == false and c.make[util.CURSOR_ITEM] == nil,
    "set_make_target(rts-cursor, 5) refused")
  return 30
end)
snap("city-target")
step(function(player, P)
  -- the add button toggles; another selection closes the picker
  click(player, find(player.gui.screen, "rts_citygui_add"))
  local open1 = itempicker.is_open(player, "citygui")
  click(player, find(player.gui.screen, "rts_citygui_add"))
  local open2 = itempicker.is_open(player)
  click(player, find(player.gui.screen, "rts_citygui_add"))
  selection.clear(player.index)
  P.after_clear = true
  check(P, "city_picker_toggles", open1 and not open2, "open %s, closed again %s", tostring(open1), tostring(not open2))
  return 30
end)
step(function(player, P)
  check(P, "city_picker_closes_with_panel", not itempicker.is_open(player), "picker open after the panel closed: %s",
    tostring(itempicker.is_open(player)))
  return 15
end)

-- Finding 1: the ledger's picker; finding 6: the amount field
step(function(player, P)
  ledgergui.open(player)
  local g = util.pstorage(player.index).ledger.gui
  P.ledger_city = util.pstorage(player.index).ledger.city
  click(player, g.chooser)
  check(P, "ledger_picker_opens", itempicker.is_open(player, "ledger") and cursor.holds_tool(player),
    "picker open %s over the ledger, cursor still %s", tostring(itempicker.is_open(player, "ledger")),
    tostring(cursor.holds_tool(player)))
  return 15
end)
snap("ledger-picker")
step(function(player, P)
  local g = util.pstorage(player.index).ledger.gui
  click(player, find(player.gui.screen[itempicker.FRAME], "rts_itempicker_pick_plastic-bar"))
  click(player, g.amount) -- select-all on click (no error)
  g.amount.text = "10"
  local add
  for _, el in pairs(g.amount.parent.children) do if el.tags and el.tags.rts_ledger == "add" then add = el end end
  click(player, add)
  local t = districts.make_targets(P.ledger_city)
  check(P, "ledger_target_plastic", g.chosen == "plastic-bar" and g.chooser.sprite == "item/plastic-bar"
    and t["plastic-bar"] == 10 and t[util.CURSOR_ITEM] == nil, "chosen %s, sprite %s, targets %s", tostring(g.chosen),
    tostring(g.chooser.sprite), serpent.line(t))
  return 90
end)
snap("ledger-target")
step(function(player, P)
  local g = util.pstorage(player.index).ledger.gui
  click(player, g.chooser)
  local open1 = itempicker.is_open(player, "ledger")
  ledgergui.close(player)
  check(P, "ledger_picker_closes_with_ledger", open1 and not itempicker.is_open(player),
    "open %s, after the ledger closed %s", tostring(open1), tostring(itempicker.is_open(player)))
  return 15
end)

-- Finding 4: names, tooltip, Enemies seen
step(function(player, P)
  local item = prototypes.item["rts-city-charter"]
  local recipe = prototypes.recipe["rts-city-charter"]
  check(P, "charter_names", uses_key(item.localised_name, "item-name.rts-city-charter")
    and uses_key(recipe.localised_name, "recipe-name.rts-city-charter"), "item %s, recipe %s",
    serpent.line(item.localised_name), serpent.line(recipe.localised_name))
  hud.set_build_tab(player, "production")
  return 30
end)
step(function(player, P)
  local b = find(player.gui.screen, "rts_hud_build_rts-city-charter")
  local h = util.pstorage(player.index).hud
  local enemy = h and h.el and h.el.enemy
  check(P, "charter_tooltip_places", b ~= nil and uses_key(b.tooltip, "rts.tooltip-places"), "build button tooltip %s",
    b and serpent.line(b.tooltip) or "-")
  local cap = enemy and enemy.valid and enemy.caption
  check(P, "enemies_seen_number", type(cap) == "table" and cap[1] == "rts.enemies-seen" and tonumber(cap[2]) ~= nil,
    "strip caption %s", serpent.line(cap))
  hud.set_build_tab(player, "economy")
  return 15
end)

-- Finding 5: a selected ghost (the vanilla info box under the minimap) is cleared
step(function(player, P)
  local surface = match.surface()
  local pos = surface.find_non_colliding_position("rts-city-center", {x = P.home.x - 20, y = P.home.y + 14}, 30, 1, true)
  P.ghost = pos and surface.create_entity({name = "entity-ghost", inner_name = "rts-city-center", position = pos,
                                           force = P.F})
  player.selected = P.ghost
  note("ghost %s, selected %s", tostring(P.ghost and P.ghost.valid), tostring(player.selected and player.selected.name))
  shot(player, "hover-set")
  return 20
end)
step(function(player, P)
  check(P, "hover_cleared", P.ghost ~= nil and player.selected == nil, "player.selected 20 ticks later: %s",
    tostring(player.selected and player.selected.name))
  if P.ghost and P.ghost.valid then P.ghost.destroy() end
  return 15
end)
snap("hover-cleared")

-- Finding 3: a horizontal wagon and a depot
step(function(player, P)
  local surface = match.surface()
  local y = math.floor(P.home.y) + 31 -- 2.0 straight rails sit on odd coordinates
  if y % 2 == 0 then y = y + 1 end
  local x0 = math.floor(P.home.x) - 25
  if x0 % 2 == 0 then x0 = x0 + 1 end
  for _, e in pairs(surface.find_entities_filtered({area = {{x0 - 4, y - 6}, {x0 + 40, y + 6}},
                                                     type = {"tree", "simple-entity", "cliff"}})) do e.destroy() end
  local n = 0
  for x = x0, x0 + 36, 2 do
    if surface.create_entity({name = "straight-rail", position = {x, y}, direction = defines.direction.east,
                              force = P.F}) then n = n + 1 end
  end
  P.wagon = surface.create_entity({name = rails.WAGON, position = {x0 + 18, y}, orientation = 0.25, force = P.F})
  if P.wagon then buildings.register(P.wagon) end
  P.rail_y = y
  note("rails %d, wagon %s at %s orientation %s box %s", n, tostring(P.wagon and P.wagon.unit_number),
    P.wagon and util.pos_str(P.wagon.position) or "-", P.wagon and tostring(P.wagon.orientation) or "-",
    P.wagon and serpent.line(P.wagon.selection_box) or "-")
  return 15
end)
step(function(player, P)
  local w = P.wagon
  if not (w and w.valid) then
    check(P, "wagon_pick", false, "no wagon")
    return 15
  end
  local p = w.position
  local function at(dx, dy) local un = selection.building_at(player.index, {x = p.x + dx, y = p.y + dy}) return un end
  local on, along, below, below_near, above = at(0, 0), at(2.5, 0), at(0, 3), at(0, 2), at(0, -1.8)
  check(P, "wagon_pick", on == w.unit_number and along == w.unit_number and below == nil and below_near == nil
    and above == nil, "centre %s, 2.5 along %s, 3 below %s, 2 below %s, 1.8 above %s (wagon #%d)", tostring(on),
    tostring(along), tostring(below), tostring(below_near), tostring(above), w.unit_number)
  selection.select_building(player.index, w.unit_number)
  camera.jump_to(player, p)
  return 30
end)
snap("wagon-selected", function(P) return P.wagon and P.wagon.position end, 1.5)
step(function(player, P)
  selection.clear(player.index)
  local surface = match.surface()
  local want = {x = P.home.x + 30, y = P.home.y - 30}
  for r = 0, 40, 3 do
    for a = 0, 7 do
      local p = {x = math.floor(want.x + r * math.cos(a * math.pi / 4) + 0.5),
                 y = math.floor(want.y + r * math.sin(a * math.pi / 4) + 0.5)}
      if not P.depot and surface.can_place_entity({name = rails.DEPOT, position = p, force = P.F,
          build_check_type = defines.build_check_type.manual_ghost, forced = true}) then
        P.depot = surface.create_entity({name = rails.DEPOT, position = p, force = P.F, raise_built = true})
      end
    end
  end
  return 30
end)
step(function(player, P)
  local d = P.depot
  if not (d and d.valid) then
    check(P, "depot_pick", false, "no depot")
    return 15
  end
  local box = d.selection_box
  local inside = selection.building_at(player.index, {x = box.right_bottom.x - 0.3, y = d.position.y})
  local edge = selection.building_at(player.index, {x = box.right_bottom.x + 0.6, y = d.position.y})
  check(P, "depot_pick", inside == d.unit_number and edge ~= d.unit_number,
    "inside %s, 0.6 outside the box %s (depot #%d)", tostring(inside), tostring(edge), d.unit_number)
  return 15
end)
step(function(player, P)
  util.log("RTS_QAFIX_GUI_DONE %d/%d checks passed", P.pass or 0, P.total or 0)
  return nil
end)

events.on_nth_tick(15, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.qafix_probe
  if not P then
    P = {i = 1, at = game.tick + 240}
    storage.qafix_probe = P
  end
  if P.done or game.tick < P.at then return end
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("qafix gui step %d error: %s", idx, tostring(wait))
    P.pass, P.total = P.pass or 0, (P.total or 0) + 1
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    if P.i > #STEPS and wait then util.log("RTS_QAFIX_GUI_DONE %d/%d (steps ran out)", P.pass or 0, P.total or 0) end
    return
  end
  P.at = game.tick + wait
end)
