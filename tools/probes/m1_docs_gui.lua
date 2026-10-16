-- Phase 5 M1 protocol coordinates, GUI probe (test copy for tools/gui-run.sh with the self-test off; copy this file
-- into the copy's scripts/ and append require("scripts.m1_docs_gui") to its control.lua). Run with RTS_LOCALE=en.
-- Drives the real client through the functions the input handlers call, the way docs/qa/phase5-m1-protocol.md plays:
-- the lobby in Nation mode, the capital HUD, the city panel and list (a make target through the item picker), the
-- factory's tabs, the build menu tabs, a second city, a hauler without coal and with a tank, depots, a line, a freight
-- train, rolling stock, a division, the Railway Charter and Age II, a district, the Age II ledger (Plastic bar through
-- the picker), the army surcharge, demolish (a barracks and the second city's City Center).
-- Screenshots rts-m1d-<tag>.png (1280x800, GUI on); log lines "[rts] m1d probe ..." and the stop marker
-- RTS_M1D_GUI_DONE. Measures nothing by itself: the screenshots give the coordinates.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local units = require("scripts.units")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local hud = require("scripts.hud")
local logistics = require("scripts.logistics")
local cities = require("scripts.cities")
local territory = require("scripts.territory")
local rails = require("scripts.rails")
local ages = require("scripts.ages")
local ledgergui = require("scripts.ledgergui")
local divisiongui = require("scripts.divisiongui")
local production = require("scripts.production")
local research = require("scripts.research")
local demolish = require("scripts.demolish")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function note(fmt, ...)
  util.log("m1d probe: " .. fmt, ...)
end

local function shot(player, tag, position, zoom)
  local path = string.format("rts-m1d-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = position or player.position, zoom = zoom or player.zoom})
  note("screenshot %s at %s zoom %.2f", path, util.pos_str(position or player.position), zoom or player.zoom)
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

local function area_at(pos)
  return {left_top = {x = pos.x - 0.01, y = pos.y - 0.01}, right_bottom = {x = pos.x + 0.01, y = pos.y + 0.01}}
end

local function place(name, near, force, radius)
  local surface = match.surface()
  local pos = surface.find_non_colliding_position(name, near, radius or 20, 1, true) or near
  return surface.create_entity({name = name, position = pos, force = force, raise_built = true})
end

local function depot_near(player, want)
  local surface = match.surface()
  for r = 0, 40, 3 do
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

local function log_frames(player, tag)
  local parts = {}
  for _, el in pairs(player.gui.screen.children) do
    if el.visible then
      local loc = el.location or {x = 0, y = 0}
      parts[#parts + 1] = string.format("%s@(%d,%d)", el.name, loc.x or loc[1] or 0, loc.y or loc[2] or 0)
    end
  end
  table.sort(parts)
  note("frames %s: %s", tag, table.concat(parts, " "))
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
-- A screenshot renders at the end of its tick, so a GUI change later in the same tick shows in it: every screenshot
-- gets a step of its own, and the next change waits for the next step.
local function snap(tag, pos_fn, zoom, wait, frames)
  step(function(player, P)
    shot(player, tag, pos_fn and pos_fn(P) or nil, zoom)
    if frames then log_frames(player, tag) end
    return wait or 15
  end)
end

-- lobby: the default dialog, then Mode = Nation through the drop-down's handler
snap("lobby-skirmish", nil, nil, 15, true)
step(function(player, P)
  local dd = find(player.gui.screen.rts_lobby, "rts_lobby_mode")
  if dd then
    dd.selected_index = 2
    events.dispatch(defines.events.on_gui_selection_state_changed,
      {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
  end
  return 30
end)
snap("lobby-nation", nil, nil, 15, true)
step(function(player, P)
  local size = find(player.gui.screen.rts_lobby, "rts_lobby_size")
  local map = find(player.gui.screen.rts_lobby, "rts_lobby_map")
  note("lobby nation: size enabled %s index %s, map enabled %s", tostring(size and size.enabled),
    tostring(size and size.selected_index), tostring(map and map.enabled))
  click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
  return 360
end)

-- the capital
step(function(player, P)
  ai.stop_force("rts-ai-1")
  local F = player.force.name
  P.F = F
  P.cc = buildings.main_cc(F).entity
  P.home = P.cc.position
  P.front = match.front(F)
  note("capital at %s, front (%.2f, %.2f), mode %s, world %s", util.pos_str(P.home), P.front.x, P.front.y,
    tostring(match.config().mode), tostring(match.config().world_size))
  return 15
end)
snap("capital", nil, nil, 15, true)
snap("capital-z015", function(P) return P.home end, 0.15)
step(function(player, P)
  selection.select_building(player.index, P.cc.unit_number)
  return 60
end)
snap("cc-selected", nil, nil, 15, true)
step(function(player, P)
  selection.clear(player.index)
  click(player, find(player.gui.screen, "rts_hud_cities"))
  return 30
end)
snap("list-hidden")
step(function(player, P)
  click(player, find(player.gui.screen, "rts_hud_cities"))
  -- factory and barracks behind the capital (away from the front)
  local F, h, f = P.F, P.home, P.front
  P.factory = place("rts-factory", {x = h.x - f.x * 9 - f.y * 6, y = h.y - f.y * 9 + f.x * 6}, F)
  P.barracks = place("rts-barracks", {x = h.x - f.x * 9 + f.y * 6, y = h.y - f.y * 9 - f.x * 6}, F)
  note("factory %s at %s, barracks %s at %s", tostring(P.factory and P.factory.unit_number),
    P.factory and util.pos_str(P.factory.position) or "-", tostring(P.barracks and P.barracks.unit_number),
    P.barracks and util.pos_str(P.barracks.position) or "-")
  if P.factory then selection.select_building(player.index, P.factory.unit_number) end
  return 60
end)
snap("factory-buildings")
step(function(player, P) click(player, find(player.gui.screen, "rts_hud_factory_tab_logistics")) return 30 end)
snap("factory-logistics")
step(function(player, P) click(player, find(player.gui.screen, "rts_hud_factory_tab_intermediates")) return 30 end)
snap("factory-intermediates")
step(function(player, P) click(player, find(player.gui.screen, "rts_hud_factory_tab_science")) return 30 end)
snap("factory-science")
step(function(player, P) click(player, find(player.gui.screen, "rts_hud_factory_tab_age2")) return 30 end)
snap("factory-age2")
step(function(player, P)
  click(player, find(player.gui.screen, "rts_hud_factory_tab_buildings"))
  return 15
end)
step(function(player, P)
  selection.select_building(player.index, P.barracks.unit_number)
  return 30
end)
snap("barracks-page")
step(function(player, P)
  selection.clear(player.index)
  hud.set_build_tab(player, "production")
  return 30
end)
snap("build-production")
step(function(player, P) hud.set_build_tab(player, "defence") return 30 end)
snap("build-defence")
step(function(player, P) hud.set_build_tab(player, "economy") return 30 end)
snap("build-economy", nil, nil, 15, true)
step(function(player, P)
  -- a make target in the capital through the panel's item picker (QA round 1: scripts/itempicker.lua)
  P.capital_id = storage.nations[P.F].capital
  selection.select_building(player.index, P.cc.unit_number)
  return 60
end)
step(function(player, P)
  click(player, find(player.gui.screen, "rts_citygui_add"))
  return 15
end)
snap("cc-picker", nil, nil, 15, true)
step(function(player, P)
  click(player, find(player.gui.screen.rts_itempicker, "rts_itempicker_pick_iron-gear-wheel"))
  local tf = find(player.gui.screen, "rts_citygui_target_iron-gear-wheel")
  if tf then
    tf.text = "20"
    events.dispatch(defines.events.on_gui_text_changed, {element = tf, player_index = player.index, text = "20",
      name = defines.events.on_gui_text_changed})
  end
  note("capital targets %s", serpent.line(cities.make_targets(P.capital_id)))
  return 30
end)
snap("cc-target")
step(function(player, P)
  selection.select_building(player.index, P.factory.unit_number)
  return 120
end)
snap("factory-auto-target")
step(function(player, P)
  selection.clear(player.index)
  -- a second city 115-160 tiles out on neutral land
  local surface = match.surface()
  local best
  for _, d in ipairs({125, 140, 115, 160}) do
    for a = 0, 15 do
      local ang = a * math.pi / 8
      local p = {x = math.floor(P.home.x + d * math.cos(ang)) + 0.0, y = math.floor(P.home.y + d * math.sin(ang)) + 0.0}
      local ok = territory.can_build(P.F, "rts-city-center", p)
      if ok and surface.can_place_entity({name = "rts-city-center", position = p, force = P.F,
                                          build_check_type = defines.build_check_type.manual_ghost, forced = true}) then
        best = p
        break
      end
    end
    if best then break end
  end
  if best then
    local trees = surface.find_entities_filtered({position = best, radius = 30, type = {"tree", "simple-entity", "cliff"}})
    for _, e in pairs(trees) do e.destroy() end
    P.city2 = cities.found(P.F, best)
  end
  note("second city %s at %s", tostring(P.city2), best and util.pos_str(best) or "-")
  return 120
end)
snap("city2-founded-z015", function(P) return P.home end, 0.15)
step(function(player, P)
  local c = P.city2 and cities.get(P.city2)
  if c then
    P.city2_center = c.entity
    P.city2_pos = c.position
    camera.jump_to(player, c.position)
    selection.select_building(player.index, c.center)
  end
  return 60
end)
snap("city2-selected", nil, nil, 15, true)
step(function(player, P)
  camera.jump_to(player, P.home)
  selection.clear(player.index)
  -- a hauler at the capital's approach point, auto, home = the CC
  local ap = logistics.approach_point(P.cc.unit_number)
  P.hauler = logistics.spawn_hauler(match.surface(), ap, P.F, P.cc.unit_number)
  if P.hauler then selection.set(player.index, {P.hauler}) end
  return 90
end)
snap("hauler-auto", nil, nil, 15, true)
step(function(player, P)
  if P.city2_center and P.city2_center.valid then
    local o1 = orders.handle_reverse_area(player.index, {P.city2_center}, area_at(P.city2_center.position), false)
    local o2 = orders.handle_reverse_area(player.index, {P.cc}, area_at(P.cc.position), true)
    note("hauler route orders %s / %s", tostring(o1), tostring(o2))
  end
  return 150
end)
snap("hauler-nofuel")
step(function(player, P)
  economy.give(P.F, "coal", 50)
  return 150
end)
snap("hauler-tank")
step(function(player, P)
  local h = P.hauler and logistics.hauler(P.hauler.unit_number)
  note("hauler state %s reason %s fuel %s", tostring(h and h.state), tostring(h and h.reason), tostring(h and h.fuel))
  return 900
end)
snap("hauler-arrived")
step(function(player, P)
  local h = P.hauler and logistics.hauler(P.hauler.unit_number)
  note("hauler later: state %s reason %s fuel %s", tostring(h and h.state), tostring(h and h.reason), tostring(h and h.fuel))
  selection.clear(player.index)
  -- railways
  game.forces[P.F].technologies["rts-railways"].researched = true
  hud.set_build_tab(player, "production")
  return 30
end)
step(function(player, P) hud.set_build_tab(player, "economy") return 30 end)
snap("build-economy-rails")
step(function(player, P)
  local F, h, f = P.F, P.home, P.front
  P.a = depot_near(player, {x = h.x - f.x * 24 + f.y * 18, y = h.y - f.y * 24 - f.x * 18})
  local c2 = P.city2_pos or h
  P.b = depot_near(player, {x = c2.x + 16, y = c2.y + 4})
  note("depots %s at %s, %s at %s", tostring(P.a and P.a.unit_number), P.a and util.pos_str(P.a.position) or "-",
    tostring(P.b and P.b.unit_number), P.b and util.pos_str(P.b.position) or "-")
  for name, n in pairs({["rts-locomotive-kit"] = 4, ["rts-cargo-wagon-kit"] = 2, ["rts-construction-wagon-kit"] = 1,
                        rail = 400, coal = 200}) do
    economy.give(F, name, n)
  end
  if P.a then
    selection.select_building(player.index, P.a.unit_number)
    camera.jump_to(player, P.a.position)
  end
  return 60
end)
snap("depot-panel", nil, nil, 15, true)
step(function(player, P)
  if P.b then
    selection.select_building(player.index, P.b.unit_number)
    camera.jump_to(player, P.b.position)
  end
  return 60
end)
snap("depot-b-panel", nil, nil, 15, true)
step(function(player, P)
  if P.a then
    selection.select_building(player.index, P.a.unit_number)
    camera.jump_to(player, P.a.position)
  end
  return 30
end)
step(function(player, P)
  if P.a and P.b then
    P.order = orders.handle_reverse_area(player.index, {P.b}, area_at(P.b.position), false)
    note("lay rail order %s", tostring(P.order))
  end
  P.t_line = game.tick
  return 45
end)
snap("depot-surveying")
step(function(player, P)
  local d = P.a and rails.depot(P.a.unit_number)
  local line = d and d.line and storage.rails.lines[d.line]
  if not (line and line.state == "open") and game.tick - P.t_line < 200 * 60 then
    if not P.shot_building and line and line.state == "building" then
      P.shot_building = true
      shot(player, "depot-building")
      local trains = rails.trains_of(P.F)
      local crew = trains[#trains]
      if crew and crew.loco and crew.loco.valid then
        P.crew_pos = crew.loco.position
        shot(player, "crew", crew.loco.position, 0.3)
      end
    end
    P.i = P.i - 1
    return 30
  end
  note("line %s state %s after %.0f s", tostring(line and line.id), tostring(line and line.state),
    (game.tick - P.t_line) / 60)
  return 15
end)
snap("line-open", nil, nil, 15)
snap("line-open-z015", nil, 0.15, 15)
step(function(player, P)
  local d = P.a and rails.depot(P.a.unit_number)
  local line = d and d.line and storage.rails.lines[d.line]
  if line and line.builder and game.tick - P.t_line < 260 * 60 then
    P.i = P.i - 1
    return 60
  end
  if P.a then selection.select_building(player.index, P.a.unit_number) end
  return 30
end)
snap("depot-open")
step(function(player, P)
  click(player, find(player.gui.screen, "rts_railgui_deploy"))
  return 60
end)
step(function(player, P)
  local trains = rails.trains_of(P.F)
  local rec
  for _, t in ipairs(trains) do if t.kind == "cargo" then rec = t end end
  P.rec = rec
  note("freight train %s", tostring(rec and rec.id))
  if rec then
    selection.select_building(player.index, rec.loco.unit_number)
    camera.jump_to(player, rec.loco.position)
  end
  return 60
end)
snap("train-unset", nil, nil, 15, true)
step(function(player, P)
  if P.a and P.b then
    local o1 = orders.handle_reverse_area(player.index, {P.a}, area_at(P.a.position), false)
    local o2 = orders.handle_reverse_area(player.index, {P.b}, area_at(P.b.position), true)
    note("train route orders %s / %s", tostring(o1), tostring(o2))
  end
  return 120
end)
snap("train-route")
step(function(player, P) return 1200 end)
step(function(player, P)
  if P.rec and P.rec.loco.valid then camera.jump_to(player, P.rec.loco.position) end
  note("train delivered %s trips %s", P.rec and serpent.line(P.rec.delivered) or "-", tostring(P.rec and P.rec.trips))
  return 15
end)
snap("train-later")
step(function(player, P)
  -- rolling stock page: no Demolish button; Delete prints the refusal
  if P.rec and P.rec.loco.valid then selection.select_building(player.index, P.rec.loco.unit_number) end
  return 60
end)
snap("loco-page")
step(function(player, P)
  local r = demolish.request(player.index)
  note("demolish on the locomotive: %s", tostring(r))
  return 20
end)
snap("loco-delete")
step(function(player, P)
  selection.clear(player.index)
  camera.jump_to(player, P.home)
  -- divisions: the starting walkers
  local list = {}
  for _, rec in units.for_force(P.F) do
    if rec.kind == "walker" and rec.entity.valid then list[#list + 1] = rec.entity end
  end
  selection.set(player.index, list)
  note("selected %d walkers", #list)
  return 60
end)
snap("div-selected", nil, nil, 15, true)
step(function(player, P)
  P.div = divisiongui.form(player)
  return 60
end)
snap("div-formed", nil, nil, 15, true)
step(function(player, P)
  if P.barracks and P.barracks.valid then selection.select_building(player.index, P.barracks.unit_number) end
  return 60
end)
snap("div-barracks")
step(function(player, P)
  selection.clear(player.index)
  -- Age II: Industrialisation, the badge, the ledger
  game.forces[P.F].technologies["rts-industrialisation"].researched = true
  return 90
end)
snap("badge-ready")
step(function(player, P) ledgergui.open(player) return 60 end)
snap("ledger-ready", nil, nil, 15, true)
step(function(player, P)
  P.project = ages.start_project(P.F)
  for item, n in pairs(ages.required()) do economy.give(P.F, item, n) end
  return 60
end)
snap("ledger-started")
step(function(player, P)
  ledgergui.close(player)
  if P.project and P.project.site and P.project.site.valid then
    camera.jump_to(player, P.project.site.position)
  end
  return 240
end)
snap("site-progress")
step(function(player, P)
  if ages.of(P.F) < 2 and game.tick - (P.t_age or game.tick) < 90 * 60 then
    P.t_age = P.t_age or game.tick
    if not P.shot_countdown and P.project and P.project.state == "countdown" then
      P.shot_countdown = true
      shot(player, "site-countdown")
    end
    P.i = P.i - 1
    return 30
  end
  note("age %d", ages.of(P.F))
  return 30
end)
snap("age2")
step(function(player, P) hud.set_build_tab(player, "age2") return 30 end)
snap("build-age2", nil, nil, 15, true)
step(function(player, P)
  local h, f = P.home, P.front
  P.district = place("rts-district-steel", {x = h.x - f.y * 16, y = h.y + f.x * 16}, P.F)
  if P.district then
    selection.select_building(player.index, P.district.unit_number)
    camera.jump_to(player, P.district.position)
  end
  return 60
end)
snap("district-page")
step(function(player, P) hud.recipe_click(player, "*auto*") return 60 end)
snap("district-fixed")
step(function(player, P)
  -- QA round 1: the Age II ledger's item picker, Plastic bar 10 (protocol step 43)
  selection.clear(player.index)
  ledgergui.open(player)
  local g = util.pstorage(player.index).ledger.gui
  click(player, g and g.chooser)
  return 15
end)
snap("ledger-age2-picker", nil, nil, 15, true)
step(function(player, P)
  local g = util.pstorage(player.index).ledger.gui
  click(player, find(player.gui.screen.rts_itempicker, "rts_itempicker_pick_plastic-bar"))
  if g then
    g.amount.text = "10"
    for _, el in pairs(g.amount.parent.children) do
      if el.tags and el.tags.rts_ledger == "add" then click(player, el) end
    end
  end
  return 120
end)
snap("ledger-age2-target", nil, nil, 15, true)
step(function(player, P) ledgergui.close(player) return 15 end)
step(function(player, P)
  selection.clear(player.index)
  camera.jump_to(player, P.home)
  hud.set_build_tab(player, "economy")
  -- the army surcharge: 30 more walkers, walker kits, copper drained by cable
  local made = 0
  for i = 0, 29 do
    local pos = {x = P.home.x + P.front.x * 30 + (i % 10) * 3.5 - 15, y = P.home.y + P.front.y * 30 + math.floor(i / 10) * 3.5}
    if units.spawn("rts-walker", pos, P.F) then made = made + 1 end
  end
  note("spawned %d walkers, army %d, multiplier %.2f", made, production.army_size(P.F), production.army_multiplier(P.F))
  if P.barracks and P.barracks.valid then production.set_recipe(P.barracks.unit_number, "rts-walker-kit") end
  if P.factory and P.factory.valid then production.set_recipe(P.factory.unit_number, "rts-cable") end
  if P.barracks and P.barracks.valid then selection.select_building(player.index, P.barracks.unit_number) end
  P.t_sur = game.tick
  return 60
end)
step(function(player, P)
  local b = P.barracks and P.barracks.valid and research.block_of(P.barracks.unit_number)
  if not (b and b.reason == "surcharge") and game.tick - P.t_sur < 150 * 60 then
    if not P.shot_paid and game.tick - P.t_sur > 15 * 60 then
      P.shot_paid = true
      shot(player, "barracks-paid")
    end
    P.i = P.i - 1
    return 30
  end
  note("barracks block %s after %.0f s", b and serpent.line(b) or "none", (game.tick - P.t_sur) / 60)
  return 15
end)
snap("barracks-surcharge")
step(function(player, P)
  if P.factory and P.factory.valid then production.set_recipe(P.factory.unit_number, nil) end
  -- demolish the barracks: two presses
  demolish.request(player.index)
  return 15
end)
snap("barracks-armed")
step(function(player, P) demolish.request(player.index) return 30 end)
snap("barracks-demolished")
step(function(player, P)
  -- the second city's City Center: the city panel's Demolish button, twice
  if P.city2_center and P.city2_center.valid then
    camera.jump_to(player, P.city2_center.position)
    selection.select_building(player.index, P.city2_center.unit_number)
  end
  return 60
end)
snap("city2-before", nil, nil, 15, true)
step(function(player, P) click(player, find(player.gui.screen, "rts_citygui_demolish")) return 15 end)
snap("city2-armed")
step(function(player, P) click(player, find(player.gui.screen, "rts_citygui_demolish")) return 60 end)
snap("city2-demolished")
snap("city2-demolished-z015", nil, 0.15)
step(function(player, P)
  util.log("RTS_M1D_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(15, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.m1d_probe
  if not P then
    P = {i = 1, at = game.tick + 240}
    storage.m1d_probe = P
  end
  if P.done or game.tick < P.at then return end
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("m1d probe step %d error: %s", idx, tostring(wait))
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    if P.i > #STEPS and wait then util.log("RTS_M1D_GUI_DONE player %d (steps ran out)", player.index) end
    return
  end
  P.at = game.tick + wait
end)
