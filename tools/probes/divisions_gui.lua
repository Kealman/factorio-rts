-- Division panel GUI probe (test copy for tools/gui-run.sh: append require("scripts.divisions_gui") to control.lua).
-- Drives the real client through the functions the GUI handlers call (events.dispatch for clicks, confirms and drop-down
-- changes) and takes screenshots; logs "[rts] divgui probe <name>: PASS|FAIL ..." lines, then RTS_DIVGUI_PROBE_DONE.
--   start     Start in the lobby
--   form      16 walkers + 4 heavies selected: the panel offers Form division; a click forms it (card, detail rows)
--   stance    Advance clicked: the stance changes, the button is toggled
--   rename    Rename, type "1st Guards", Enter: the card shows the new name
--   move      a right-click move order: the card says Moving; a plain click on one member selects the whole division
--   barracks  the barracks selected: the Reinforces drop-down lists the division; choosing it sets the reinforcement
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local divisions = require("scripts.divisions")
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
  util.log("divgui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag)
  local path = string.format("rts-divgui-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  util.log("divgui probe: screenshot %s", path)
end

local function panel(player) return player.gui.screen.rts_div_panel end

local function click(player, el, extra)
  local e = {element = el, player_index = player.index, name = defines.events.on_gui_click,
             button = defines.mouse_button_type.left, shift = false, control = false, alt = false}
  for k, v in pairs(extra or {}) do e[k] = v end
  events.dispatch(defines.events.on_gui_click, e)
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player)
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 180
end)

step(function(player, P)
  local home = match.home(player.force.name)
  local f = match.front(player.force.name)
  local at = {x = home.x + f.x * 30, y = home.y + f.y * 30}
  local list = {}
  for k = 1, 20 do
    local e = units.spawn(k <= 16 and "rts-walker" or "rts-walker-heavy",
      {x = at.x + ((k - 1) % 5) * 3, y = at.y + math.floor((k - 1) / 5) * 3}, player.force.name, nil, match.surface())
    if e then list[#list + 1] = e end
  end
  P.list = list
  camera.jump_to(player, at)
  selection.set(player.index, list)
  return 30
end)

step(function(player, P)
  local form = find(panel(player), "rts_div_form")
  check("form_offered", form ~= nil and form.enabled, "panel %s, Form button %s", tostring(panel(player) ~= nil),
    form and (form.enabled and "enabled" or "disabled") or "missing")
  shot(player, "1-selected")
  if form then click(player, form) end
  local ds = divisions.for_force(player.force.name)
  P.id = ds[1] and ds[1].id
  local card = P.id and find(panel(player), "rts_div_select_" .. P.id)
  check("form_creates_card", P.id ~= nil and card ~= nil and card.toggled and find(panel(player), "rts_div_stance_" .. P.id
    .. "_advance") ~= nil, "division %s, card %s (toggled %s), detail rows %s", tostring(P.id), tostring(card ~= nil),
    tostring(card and card.toggled), tostring(P.id and find(panel(player), "rts_div_stance_" .. P.id .. "_advance") ~= nil))
  return 30
end)

step(function(player, P)
  shot(player, "2-formed")
  local b = find(panel(player), "rts_div_stance_" .. P.id .. "_advance")
  if b then click(player, b) end
  local D = divisions.get(P.id)
  b = find(panel(player), "rts_div_stance_" .. P.id .. "_advance")
  check("stance_click", D and D.stance == "advance" and b and b.toggled, "stance %s, Advance toggled %s",
    D and D.stance or "-", tostring(b and b.toggled))
  local r = find(panel(player), "rts_div_rename_" .. P.id)
  if r then click(player, r) end
  local tf = find(panel(player), "rts_div_rename_field_" .. P.id)
  check("rename_field", tf ~= nil, "text field %s", tostring(tf ~= nil))
  if tf then
    tf.text = "1st Guards"
    events.dispatch(defines.events.on_gui_confirmed, {element = tf, player_index = player.index,
      name = defines.events.on_gui_confirmed})
  end
  local card = find(panel(player), "rts_div_select_" .. P.id)
  check("rename_applies", D and D.name == "1st Guards" and card and card.caption == "1st Guards",
    "name %s, card caption %s", D and tostring(D.name) or "-", card and tostring(card.caption) or "-")
  return 30
end)

step(function(player, P)
  local D = divisions.get(P.id)
  local to = {x = D.pos.x + 40, y = D.pos.y}
  P.moved = orders.move(player.index, to)
  return 20
end)

step(function(player, P)
  local D = divisions.get(P.id)
  check("move_order", D and D.state == "moving" and P.moved == 20, "orders.move -> %s, state %s, order %s",
    tostring(P.moved), D and D.state or "-", D and D.order and D.order.kind or "-")
  hud.refresh(player.index)
  shot(player, "3-moving")
  -- a plain click on one member selects the whole division
  local one = P.list[3]
  selection.clear(player.index)
  local n = selection.handle_area(player.index, {one}, {left_top = one.position, right_bottom = one.position}, false)
  check("click_selects_division", n == 20, "plain click on one member -> %d selected", n)
  return 30
end)

step(function(player, P)
  local un
  for bun, rec in pairs(storage.buildings) do
    if rec.kind == "barracks" and rec.force == player.force.name and rec.entity.valid then un = bun break end
  end
  if not un then
    local home = match.home(player.force.name)
    local surface = match.surface()
    local pos = surface.find_non_colliding_position("rts-barracks", {home.x, home.y + 14}, 30, 1, true)
    local e = surface.create_entity({name = "rts-barracks", position = pos, force = player.force, raise_built = true})
    un = e and e.unit_number
  end
  P.barracks = un
  selection.select_building(player.index, un)
  local dd = find(panel(player), "rts_div_barracks")
  check("barracks_dropdown", dd ~= nil and #dd.items == 2, "drop-down %s with %d items", tostring(dd ~= nil),
    dd and #dd.items or 0)
  if dd then
    dd.selected_index = 2
    events.dispatch(defines.events.on_gui_selection_state_changed, {element = dd, player_index = player.index,
      name = defines.events.on_gui_selection_state_changed})
  end
  check("barracks_reinforces", divisions.barracks_division(un) == P.id, "barracks #%s reinforces %s", tostring(un),
    tostring(divisions.barracks_division(un)))
  return 30
end)

step(function(player, P)
  camera.jump_to(player, storage.buildings[P.barracks].entity.position)
  return 30
end)

step(function(player, P)
  shot(player, "4-barracks")
  util.log("RTS_DIVGUI_PROBE_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.divgui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.divgui_probe = P
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
