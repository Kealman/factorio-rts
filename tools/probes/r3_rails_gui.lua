-- Test-only GUI probe, 0.1.2 #31 part B and #32: the train panel's stop list and the stop editor, the depot panel's
-- train builder and the train panel's carriage row in the real client. Append require("scripts.r3_rails_gui") to a test copy's control.lua and run
-- tools/gui-run.sh <copy> 300 RTS_R3_GUI_DONE (RTS_LOCALE=ru for the Russian screenshots). It starts a Skirmish match
-- from the lobby, switches the rails module to Nation rules (storage.rails.test_nation) and builds a scene on its own
-- lab-tile surface for the player's force: depots A, B, C on one straight track, a freight train at A. Then it drives
-- the same functions the input handlers call. Logs "[rts] r3 gui check <name>: PASS|FAIL ...", screenshots
-- rts-r3-<tag>.png, then RTS_R3_GUI_DONE.
--   stops       right clicks on A, B, C, B (train selected) make a 4-stop list; the panel lists 4 rows
--   insert      Shift + right click on C with stop 1 selected inserts C as stop 2 (then it is removed again)
--   editor      a click on row 2 opens its editor (unload / load drop-downs, wait drop-down)
--   items       unload "items..." + Add item + a pick from the item list gives the stop an item row
--   wait        the wait drop-down set to "item count" writes an item_count wait condition into the engine record
--   status      the train runs: the status line reads "Stop i of 4" and the train delivered iron to B
--   composer    depot E's panel shows the builder (Freight preset, palette with kit counts, Deploy)
--   preset      the preset drop-down on "Mixed: armoured siege" fills 4 carriages; missing kits are named
--   palette     a palette click adds a cargo wagon in front of the rear locomotive; reversing the front locomotive
--               is refused with the reason
--   template    a composition saved as "Probe" shows up in the drop-down
--   deploy      the Freight preset deployed at E; the train panel's carriage row couples a cargo wagon at the rear
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local lobby = require("scripts.lobby")
local logistics = require("scripts.logistics")
local rails = require("scripts.rails")
local railroutes = require("scripts.railroutes")

local SURFACE = "r3-gui"
local D = defines.direction

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("r3 gui check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag, P, position, zoom)
  local path = string.format("rts-r3-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, surface = SURFACE, path = path, show_gui = true,
    force_render = true, resolution = {1280, 800}, position = position or P.view, zoom = zoom or 0.6})
  util.log("r3 gui: screenshot %s", path)
end

local function area_at(pos)
  return {left_top = {x = pos.x - 0.01, y = pos.y - 0.01}, right_bottom = {x = pos.x + 0.01, y = pos.y + 0.01}}
end

local function click(player, name, opts)
  local el = find(player.gui.screen, name)
  if not el then
    util.log("r3 gui: no element %s", name)
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = opts and opts.shift or false,
    control = false, alt = false})
  return true
end

local function choose(player, name, index)
  local el = find(player.gui.screen, name)
  if not el then
    util.log("r3 gui: no drop-down %s", name)
    return false
  end
  el.selected_index = index
  events.dispatch(defines.events.on_gui_selection_state_changed, {element = el, player_index = player.index,
    name = defines.events.on_gui_selection_state_changed})
  return true
end

local function scene(player, P)
  local s = game.surfaces[SURFACE]
  if not s then
    s = game.create_surface(SURFACE, {width = 0, height = 0, peaceful_mode = true, no_enemies_mode = true})
    s.generate_with_lab_tiles = true
    s.always_day = true
    for x = -96, 544, 32 do
      for y = -96, 256, 32 do s.request_to_generate_chunks({x + 16, y + 16}, 0) end
    end
    s.force_generate_chunk_requests()
  end
  local f = player.force
  local function depot(x)
    storage.rails.reuse_site = {force = f.name, x = x, y = 0, spec = {axis = "x", side = 1, track = 7}}
    local e = s.create_entity({name = rails.DEPOT, position = {x, 0}, force = f, raise_built = true})
    storage.rails.reuse_site = nil
    for i = 1, 3 do
      local sp = s.find_non_colliding_position("rts-stockpile", {x - 8 + i * 4, -6}, 8, 1, true)
      local st = sp and s.create_entity({name = "rts-stockpile", position = sp, force = f, raise_built = true})
      if st then buildings.register(st) end
    end
    return e
  end
  P.a, P.b, P.c = depot(0), depot(200), depot(400)
  storage.rails.reuse_site = {force = f.name, x = 0, y = 200, spec = {axis = "x", side = 1, track = 207}}
  P.e = s.create_entity({name = rails.DEPOT, position = {0, 200}, force = f, raise_built = true})
  storage.rails.reuse_site = nil
  for x = 21, 179, 2 do s.create_entity({name = "straight-rail", position = {x, 7}, direction = D.east, force = f}) end
  for x = 221, 379, 2 do s.create_entity({name = "straight-rail", position = {x, 7}, direction = D.east, force = f}) end
  P.view = {x = 0, y = 4}
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player, P)
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 180
end)

step(function(player, P)
  storage.rails = storage.rails or {}
  storage.rails.test_nation = true
  scene(player, P)
  return 120
end)

step(function(player, P)
  local un = function(e) return e.unit_number end
  logistics.set_policy(un(P.a), "export_above", "iron-plate", 0)
  logistics.set_policy(un(P.b), "keep", "iron-plate", 2000)
  logistics.set_policy(un(P.b), "export_above", "copper-plate", 0)
  for _, x in ipairs({{P.a, {{rails.LOCO_KIT, 2}, {rails.WAGON_KIT, 2}, {"coal", 300}, {"iron-plate", 6000}}},
                      {P.b, {{"coal", 300}, {"copper-plate", 6000}}}, {P.c, {{"coal", 300}, {"stone", 3000}}},
                      {P.e, {{rails.LOCO_KIT, 2}, {rails.WAGON_KIT, 3}, {"coal", 100}}}}) do
    local net = logistics.hub_network(x[1].unit_number)
    for _, it in ipairs(x[2]) do if net then net.insert({name = it[1], count = it[2]}) end end
  end
  local train, why = rails.create_train(un(P.a), "cargo")
  P.train = train
  if not train then
    check("stops", false, "no train (%s)", tostring(why))
    return nil
  end
  P.id = train.id
  selection.select_building(player.index, train.front_stock.unit_number)
  return 30
end)

step(function(player, P)
  shot(player, "train-new", P)
  P.orders = {}
  for i, d in ipairs({P.a, P.b, P.c, P.b}) do
    P.orders[i] = orders.handle_reverse_area(player.index, {d}, area_at(d.position), false)
  end
  return 30
end)

step(function(player, P)
  local rec = rails.train_record(P.id) or rails.train_record(P.train)
  local frame = player.gui.screen.rts_railgui_frame
  local rows = 0
  for i = 1, 8 do if find(frame, "rts_railgui_stop_" .. i) then rows = i end end
  check("stops", rec ~= nil and rec.stops and #rec.stops == 4 and rows == 4,
    "orders [%s], %d stops, %d rows in the panel", table.concat(P.orders, " "), rec and rec.stops and #rec.stops or 0,
    rows)
  shot(player, "stops", P)
  P.rec = rec
  -- Shift + right click inserts after the selected stop 1
  click(player, "rts_railgui_stop_1")
  return 20
end)

step(function(player, P)
  local o = orders.handle_reverse_area(player.index, {P.c}, area_at(P.c.position), true)
  local rec = P.rec
  local second = rec.stops[2] and rec.stops[2].target
  check("insert", o == "train-stop" and #rec.stops == 5 and second == P.c.unit_number,
    "order %s, %d stops, stop 2 = #%s (C #%d)", tostring(o), #rec.stops, tostring(second), P.c.unit_number)
  shot(player, "inserted", P)
  railroutes.remove(rails.train_of(rec), 2)
  return 20
end)

step(function(player, P)
  click(player, "rts_railgui_stop_2")
  return 20
end)

step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame
  local ok = find(frame, "rts_railgui_stop_unload") and find(frame, "rts_railgui_stop_load")
    and find(frame, "rts_railgui_stop_wait")
  check("editor", ok ~= nil and #P.rec.stops == 4, "editor of stop 2: unload, load and wait drop-downs %s; %d stops",
    tostring(ok ~= nil), #P.rec.stops)
  shot(player, "editor", P)
  choose(player, "rts_railgui_stop_unload", 4) -- items...
  return 20
end)

step(function(player, P)
  click(player, "rts_railgui_item_add_unload_items")
  return 20
end)

step(function(player, P)
  shot(player, "picker", P)
  click(player, "rts_itempicker_pick_iron-plate")
  return 20
end)

step(function(player, P)
  local st = P.rec.stops[2]
  local row = find(player.gui.screen.rts_railgui_frame, "rts_railgui_count_unload_items_iron-plate")
  check("items", st.unload == "items" and st.unload_items and st.unload_items["iron-plate"] ~= nil and row ~= nil,
    "stop 2 unload %s items %s, row %s", tostring(st.unload), serpent.line(st.unload_items), tostring(row ~= nil))
  shot(player, "items", P)
  choose(player, "rts_railgui_stop_wait", 5) -- item count
  return 20
end)

step(function(player, P)
  local train = rails.train_of(P.rec)
  local r = train.get_schedule().get_record({schedule_index = 2})
  local w = r and r.wait_conditions and r.wait_conditions[1]
  check("wait", w ~= nil and w.type == "item_count", "record 2 wait %s", w and serpent.line(w) or "-")
  shot(player, "wait-item", P)
  -- back to the defaults for the run: unload to Keep, idle 10 s
  railroutes.update(train, 2, {unload = "keep", wait = {type = "inactivity", seconds = 10}})
  P.t_run = game.tick
  return 60 * 25
end)

step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame
  P.status_text = frame and frame.valid and "panel" or "-"
  shot(player, "running", P, P.rec.loco.valid and P.rec.loco.position or nil)
  return 60 * 20
end)

step(function(player, P)
  local rec = P.rec
  local train = rails.train_of(rec)
  local st = train and railroutes.status(rec, train)
  check("status", st ~= nil and st.index ~= nil and st.count == 4 and (rec.delivered["iron-plate"] or 0) > 0,
    "status stop %s of %s (%s), delivered %s", tostring(st and st.index), tostring(st and st.count),
    tostring(st and st.phase), serpent.line(rec.delivered))
  shot(player, "later", P, rec.loco.valid and rec.loco.position or nil)
  -- #32: the depot panel's train builder
  selection.select_building(player.index, P.e.unit_number)
  P.view = {x = 0, y = 204}
  return 30
end)

step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame
  local ok = frame and find(frame, "rts_railgui_builder_preset") and find(frame, "rts_railgui_pal_rts-cargo-wagon")
    and find(frame, "rts_railgui_deploy") and find(frame, "rts_railgui_car_4")
  check("composer", ok ~= nil, "builder in the depot panel %s (preset drop-down, palette, 4 carriages, Deploy)",
    tostring(ok ~= nil))
  shot(player, "composer", P)
  choose(player, "rts_railgui_builder_preset", #rails.PRESETS + 1) -- the last preset: Mixed, armoured siege
  return 20
end)

step(function(player, P)
  local g = storage.players[player.index].railgui
  local c = g.compose and g.compose[P.e.unit_number]
  local why = c and rails.compose_check(P.e.unit_number, c.cars)
  check("preset", c ~= nil and #c.cars == 4 and c.cars[1].name == rails.ALOCO and why == "no-kits",
    "%d carriages, first %s, check %s", c and #c.cars or 0, c and c.cars[1] and c.cars[1].name or "-", tostring(why))
  shot(player, "composer-siege", P)
  click(player, "rts_railgui_pal_rts-cargo-wagon")
  return 20
end)

step(function(player, P)
  local g = storage.players[player.index].railgui
  local c = g.compose[P.e.unit_number]
  P.pal_ok = #c.cars == 5 and c.cars[4].name == rails.WAGON and c.cars[5].reversed == true
  click(player, "rts_railgui_car_1")
  return 20
end)

step(function(player, P)
  click(player, "rts_railgui_builder_reverse")
  return 20
end)

step(function(player, P)
  local g = storage.players[player.index].railgui
  local c = g.compose[P.e.unit_number]
  local why = rails.compose_check(P.e.unit_number, c.cars)
  check("palette", P.pal_ok and c.cars[1].reversed == true and why == "no-front-loco",
    "cargo wagon in front of the rear locomotive %s; front reversed %s, check %s", tostring(P.pal_ok),
    tostring(c.cars[1].reversed), tostring(why))
  shot(player, "composer-rules", P)
  click(player, "rts_railgui_builder_reverse") -- back
  g.tname = "Probe"
  click(player, "rts_railgui_builder_save")
  return 20
end)

step(function(player, P)
  local dd = find(player.gui.screen.rts_railgui_frame, "rts_railgui_builder_preset")
  local last = dd and dd.items[#dd.items]
  local list = rails.templates(player.force.name)
  check("template", #list >= 1 and list[#list].name == "Probe" and dd ~= nil and #dd.items == #rails.PRESETS + 2,
    "%d templates, last '%s', %d drop-down entries", #list, list[#list] and list[#list].name or "-",
    dd and #dd.items or 0)
  choose(player, "rts_railgui_builder_preset", 2) -- Freight
  return 20
end)

step(function(player, P)
  click(player, "rts_railgui_deploy")
  return 30
end)

step(function(player, P)
  local trains = rails.trains_of(player.force.name)
  local rec = trains[#trains]
  P.t2 = rec
  if rec and rec.composed then
    selection.select_building(player.index, rec.loco.unit_number)
  end
  return 30
end)

step(function(player, P)
  local rec = P.t2
  local train = rec and rails.train_of(rec)
  local n0 = train and #train.carriages or 0
  shot(player, "train-carriages", P)
  click(player, "rts_railgui_tpal_rts-cargo-wagon")
  P.n0 = n0
  return 30
end)

step(function(player, P)
  local rec = P.t2
  local train = rec and rec.loco.valid and rec.loco.train
  local n1 = train and #train.carriages or 0
  check("deploy", rec ~= nil and rec.composed and P.n0 == 4 and n1 == 5, "composed train %s: %d carriages, %d after "
    .. "Couple", tostring(rec and rec.id), P.n0 or 0, n1)
  shot(player, "train-coupled", P)
  util.log("RTS_R3_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r3_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.r3_gui_probe = P
  end
  if P.done or game.tick < P.at then return end
  local fn = STEPS[P.i]
  P.i = P.i + 1
  local wait = fn(player, P)
  if not wait or P.i > #STEPS then
    P.done = true
    if wait == nil and P.i <= #STEPS then util.log("RTS_R3_GUI_DONE player %d (stopped early)", player.index) end
    return
  end
  P.at = game.tick + wait
end)
