-- Phase 5 M2 protocol coordinates and HUD audit, GUI probe (test copy for tools/gui-run.sh with the self-test off:
-- copy this file into the copy's scripts/ and append require("scripts.m2_docs_gui") to its control.lua). Run it with
-- RTS_LOCALE=en and RTS_LOCALE=ru. It drives the real client through the functions the input handlers call, the way
-- docs/qa/phase5-m2-protocol.md plays: the lobby in Nation mode (Victory, Time limit, the Nation help page), the capital
-- HUD and the treasury strip, the city panel's people section and priorities, the staffing box, the build menu
-- (Rail works in the Economy tab, the people buildings in Production), the market panel and a sale at a captured port,
-- the diplomacy panel (War, an AI peace offer, Accept), a capture of an AI town with its progress label, an own town
-- under attack (the city panel's "Under attack" row and Jump, the red city list row), a division's supply bar in three
-- states and the refill at the CC, a troop train (Deploy troop train, embark, ride, disembark), the regional and world
-- minimap, region labels at strategic zoom, the Disband bin on the units page, and the info-box check (a ghost placed
-- from the build menu, Q, 60 s).
-- Screenshots rts-m2d-<tag>.png (game.take_screenshot, 1280x800, GUI on); the map view cannot be rendered by
-- take_screenshot, so those steps also log "M2D_CAPTURE <tag>" for a window grabber. Log lines "[rts] m2d probe ...",
-- checks "[rts] m2d check <name>: PASS|FAIL ...", the stop marker RTS_M2D_GUI_DONE.
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
local divisions = require("scripts.divisions")
local divisiongui = require("scripts.divisiongui")
local demolish = require("scripts.demolish")
local treasury = require("scripts.treasury")
local market = require("scripts.market")
local marketgui = require("scripts.marketgui")
local diplomacy = require("scripts.diplomacy")
local diplomacygui = require("scripts.diplomacygui")
local capture = require("scripts.capture")
local garrison = require("scripts.garrison")
local warsupply = require("scripts.warsupply")
local strategic = require("scripts.strategic")
local citygui = require("scripts.citygui")
local world = require("scripts.world")
local dbg = require("scripts.debug") -- the QA console commands (/rts-supply, /rts-goto, /rts-diplomacy)

local E = "rts-ai-1"

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

-- First element under `el` whose tags[key] == value (and tags.item == item when given).
local function find_tag(el, key, value, item)
  if not (el and el.valid) then return nil end
  local t = el.tags
  if t and t[key] == value and (item == nil or t.item == item) then return el end
  for _, c in pairs(el.children) do
    local f = find_tag(c, key, value, item)
    if f then return f end
  end
end

local function note(fmt, ...)
  util.log("m2d probe: " .. fmt, ...)
end

local function check(name, ok, fmt, ...)
  util.log("m2d check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag, position, zoom)
  local path = string.format("rts-m2d-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = position or player.position,
                        zoom = math.max(1 / 32, zoom or player.zoom)})
  note("screenshot %s at %s zoom %.3f", path, util.pos_str(position or player.position), zoom or player.zoom)
end

local function click(player, el)
  if not (el and el.valid) then
    note("click: element missing")
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
  return true
end

local function select_dd(player, dd, index)
  if not (dd and dd.valid) then return false end
  dd.selected_index = index
  events.dispatch(defines.events.on_gui_selection_state_changed,
    {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
  return true
end

-- Every visible frame of player.gui.screen with its location and size (where the engine knows it).
local function log_frames(player, tag)
  local parts = {}
  for _, el in pairs(player.gui.screen.children) do
    if el.visible then
      local loc = el.location or {x = 0, y = 0}
      parts[#parts + 1] = string.format("%s@(%d,%d)", el.name ~= "" and el.name or ("<" .. el.type .. ">"),
        loc.x or loc[1] or 0, loc.y or loc[2] or 0)
    end
  end
  table.sort(parts)
  note("frames %s (scale %.2f, res %dx%d): %s", tag, player.display_scale, player.display_resolution.width,
    player.display_resolution.height, table.concat(parts, " "))
end

local function area_at(pos)
  return {left_top = {x = pos.x - 0.01, y = pos.y - 0.01}, right_bottom = {x = pos.x + 0.01, y = pos.y + 0.01}}
end

local function place(name, near, force, radius)
  local surface = match.surface()
  local pos = surface.find_non_colliding_position(name, near, radius or 20, 1, true) or near
  return surface.create_entity({name = name, position = pos, force = force, raise_built = true})
end

local function spawn(force, at, n, name)
  local list = {}
  for k = 1, n do
    local e = units.spawn(name or "rts-walker", {x = at.x + ((k - 1) % 5) * 3, y = at.y + math.floor((k - 1) / 5) * 3},
      force, nil, match.surface())
    if e then list[#list + 1] = e end
  end
  return list
end

local function clear_area(center, rx, ry)
  local surface = match.surface()
  local tiles = {}
  for x = math.floor(center.x - rx), math.floor(center.x + rx) do
    for y = math.floor(center.y - ry), math.floor(center.y + ry) do
      local t = surface.get_tile(x, y)
      local wet = false
      if t.valid then
        local ok, hit = pcall(function() return t.collides_with("water_tile") end)
        wet = (ok and hit) or t.name:find("water") ~= nil or t.name:find("mountain") ~= nil
      end
      if wet then
        tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
      end
    end
  end
  if #tiles > 0 then surface.set_tiles(tiles, true) end
  for _, e in pairs(surface.find_entities_filtered({area = {{center.x - rx, center.y - ry}, {center.x + rx, center.y + ry}},
                                                   type = {"tree", "simple-entity", "cliff", "fish"}})) do
    if e.valid then e.destroy() end
  end
end

-- A spot `d` tiles from `home` where `force` may found a City Center (the m1 probe's search).
local function city_spot(force, home, dists, avoid)
  local surface = match.surface()
  for _, d in ipairs(dists) do
    for a = 0, 15 do
      local ang = a * math.pi / 8
      local p = {x = math.floor(home.x + d * math.cos(ang)) + 0.0, y = math.floor(home.y + d * math.sin(ang)) + 0.0}
      local far = not avoid or util.distance(p, avoid) > 150
      if far and territory.can_build(force, "rts-city-center", p) and surface.can_place_entity({name = "rts-city-center",
          position = p, force = force, build_check_type = defines.build_check_type.manual_ghost, forced = true}) then
        return p
      end
    end
  end
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
-- A screenshot renders at the end of its tick, so every screenshot gets a step of its own.
local function snap(tag, pos_fn, zoom, wait, frames)
  step(function(player, P)
    shot(player, tag, pos_fn and pos_fn(P) or nil, zoom)
    if frames then log_frames(player, tag) end
    return wait or 15
  end)
end

---------------------------------------------------------------------------
-- Lobby
---------------------------------------------------------------------------
snap("lobby-skirmish", nil, nil, 15, true)
step(function(player, P)
  select_dd(player, find(player.gui.screen.rts_lobby, "rts_lobby_mode"), 2)
  return 30
end)
snap("lobby-nation", nil, nil, 15, true)
step(function(player, P)
  local v = find(player.gui.screen.rts_lobby, "rts_lobby_victory")
  local t = find(player.gui.screen.rts_lobby, "rts_lobby_time_limit")
  check("lobby_rows", v ~= nil and t ~= nil, "Victory %s (%d items), Time limit %s (%d items)", tostring(v ~= nil),
    v and #v.items or 0, tostring(t ~= nil), t and #t.items or 0)
  hud.toggle_help(player, "probe lobby")
  return 30
end)
snap("help-lobby-nation", nil, nil, 15, true)
step(function(player, P)
  hud.toggle_help(player, "probe lobby")
  click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
  return 420
end)

---------------------------------------------------------------------------
-- The capital, treasury strip, help in the match
---------------------------------------------------------------------------
step(function(player, P)
  ai.stop_force(E)
  local F = player.force.name
  P.F = F
  P.cc = buildings.main_cc(F).entity
  P.home = P.cc.position
  P.front = match.front(F)
  P.capital_id = storage.nations[F].capital
  local caption, color, tip = treasury.strip(F)
  note("capital at %s, front (%.2f, %.2f), mode %s, world %s", util.pos_str(P.home), P.front.x, P.front.y,
    tostring(match.config().mode), tostring(match.config().world_size))
  note("treasury strip caption %s tooltip %s", serpent.line(caption), serpent.line(tip))
  return 30
end)
snap("capital", nil, nil, 15, true)
step(function(player, P)
  hud.toggle_help(player, "probe match")
  return 30
end)
snap("help-match", nil, nil, 15, true)
step(function(player, P)
  hud.toggle_help(player, "probe match")
  selection.select_building(player.index, P.cc.unit_number)
  return 60
end)

---------------------------------------------------------------------------
-- City panel: people, priorities, draft; staffing box
---------------------------------------------------------------------------
snap("city-panel", nil, nil, 15, true)
step(function(player, P)
  click(player, find(player.gui.screen, "rts_citygui_prio_toggle"))
  return 30
end)
snap("city-priorities", nil, nil, 15, true)
step(function(player, P)
  local up = find(player.gui.screen, "rts_citygui_prio_up_power")
  note("priorities: power up button %s", tostring(up ~= nil))
  if up then click(player, up) end
  local dd = find(player.gui.screen, "rts_citygui_draft")
  note("draft drop-down %s items %s", tostring(dd ~= nil), dd and serpent.line(dd.items) or "-")
  return 30
end)
snap("city-priorities-moved", nil, nil, 15)
step(function(player, P)
  click(player, find(player.gui.screen, "rts_citygui_prio_toggle"))
  selection.clear(player.index)
  local F, h, f = P.F, P.home, P.front
  P.factory = place("rts-factory", {x = h.x - f.x * 9 - f.y * 6, y = h.y - f.y * 9 + f.x * 6}, F)
  P.barracks = place("rts-barracks", {x = h.x - f.x * 9 + f.y * 6, y = h.y - f.y * 9 - f.x * 6}, F)
  note("factory %s at %s, barracks %s", tostring(P.factory and P.factory.unit_number),
    P.factory and util.pos_str(P.factory.position) or "-", tostring(P.barracks and P.barracks.unit_number))
  return 360 -- the staffing pass (every 5 s per city) must see the factory
end)
step(function(player, P)
  if P.factory then selection.select_building(player.index, P.factory.unit_number) end
  return 60
end)
snap("staff-box", nil, nil, 15, true)
step(function(player, P)
  click(player, find(player.gui.screen, "rts_citygui_pin"))
  return 360
end)
snap("staff-pinned", nil, nil, 15, true)

---------------------------------------------------------------------------
-- Build menu: Economy (Rail works after Railways) and Production
---------------------------------------------------------------------------
step(function(player, P)
  selection.clear(player.index)
  hud.set_build_tab(player, "economy")
  return 30
end)
snap("build-economy", nil, nil, 15, true)
step(function(player, P)
  game.forces[P.F].technologies["rts-railways"].researched = true
  hud.set_build_tab(player, "production")
  return 30
end)
step(function(player, P) hud.set_build_tab(player, "economy") return 30 end)
snap("build-economy-railways", nil, nil, 15)
step(function(player, P)
  if P.factory and P.factory.valid then selection.select_building(player.index, P.factory.unit_number) end
  return 30
end)
step(function(player, P)
  click(player, find(player.gui.screen, "rts_hud_factory_tab_logistics"))
  return 30
end)
snap("factory-logistics-railways", nil, nil, 15, true)
step(function(player, P)
  click(player, find(player.gui.screen, "rts_hud_factory_tab_buildings"))
  return 30
end)
snap("factory-buildings-railways", nil, nil, 15)
step(function(player, P) selection.clear(player.index) return 15 end)
step(function(player, P) hud.set_build_tab(player, "production") return 30 end)
snap("build-production", nil, nil, 15)
step(function(player, P) hud.set_build_tab(player, "economy") return 15 end)

---------------------------------------------------------------------------
-- Market: a trade port next to the capital, the panel, a sale
---------------------------------------------------------------------------
step(function(player, P)
  local surface = match.surface()
  local want = {x = P.home.x - P.front.x * 50, y = P.home.y - P.front.y * 50}
  clear_area(want, 20, 20)
  local at = surface.find_non_colliding_position(market.POST, want, 30, 1, true) or want
  local p = market.place_port(surface, at)
  P.port = p and p.un
  P.port_pos = p and p.position
  local ok = P.port and market.set_owner(P.port, P.F)
  local pol = P.port and logistics.policy(P.port)
  if pol then
    for _, s in ipairs(pol.parts.stockpiles) do
      s.insert({name = "steel-plate", count = 300})
      s.insert({name = "stone", count = 300})
    end
  end
  note("trade port %s at %s owner set %s", tostring(P.port), P.port_pos and util.pos_str(P.port_pos) or "-", tostring(ok))
  marketgui.toggle(player)
  return 60
end)
snap("market-panel", nil, nil, 15, true)
step(function(player, P)
  local g = util.pstorage(player.index).market_gui.gui
  local row = g and g.rows["steel-plate"]
  local bal = treasury.balance(P.F)
  if row then
    row.amount.text = "100"
    click(player, row.sell)
  end
  local after = treasury.balance(P.F)
  check("market_sell", row ~= nil and after > bal, "balance %.1f -> %.1f after Sell 100 steel", bal, after)
  return 60
end)
snap("market-sold", nil, nil, 15)
step(function(player, P)
  marketgui.close(player)
  if P.port_pos then camera.jump_to(player, P.port_pos) end
  return 30
end)
snap("port-view", nil, nil, 15)
step(function(player, P)
  camera.jump_to(player, P.home)
  return 15
end)

---------------------------------------------------------------------------
-- Diplomacy: the panel at peace, War
---------------------------------------------------------------------------
step(function(player, P)
  diplomacygui.toggle(player)
  return 60
end)
snap("diplo-peace", nil, nil, 15, true)
step(function(player, P)
  local b = find(player.gui.screen, "rts_diplo_war_" .. E)
  note("War button %s", tostring(b ~= nil))
  click(player, b)
  return 60
end)
snap("diplo-war", nil, nil, 15, true)
step(function(player, P)
  check("war_declared", diplomacy.state(P.F, E) == "war", "state %s", tostring(diplomacy.state(P.F, E)))
  diplomacygui.close(player)
  return 30
end)

---------------------------------------------------------------------------
-- Capture an AI town: progress label, alerts
---------------------------------------------------------------------------
step(function(player, P)
  local spot = city_spot(E, P.home, {140, 160, 125, 180})
  if spot then
    clear_area(spot, 30, 30)
    P.ai_city = cities.found(E, spot)
  end
  local c = P.ai_city and cities.get(P.ai_city)
  note("AI town %s at %s", tostring(P.ai_city), spot and util.pos_str(spot) or "-")
  if c then
    P.ai_center = c.entity
    P.ai_pos = c.position
    camera.jump_to(player, c.position)
  end
  return 120
end)
step(function(player, P)
  if not (P.ai_center and P.ai_center.valid) then return 15 end
  P.attackers = spawn(P.F, {x = P.ai_pos.x - 7, y = P.ai_pos.y + 10}, 10)
  P.ai_center.health = P.ai_center.max_health * 0.1
  capture.subdue(P.ai_center, P.F)
  return 300
end)
snap("capture-progress", function(P) return P.ai_pos end, nil, 15, true)
step(function(player, P)
  local cs = P.ai_city and capture.of(P.ai_city)
  note("capture state %s", cs and serpent.line({subdued = cs.subdued, capturing = cs.capturing, progress = cs.progress,
    attackers = cs.attackers, defenders = cs.defenders}) or "none")
  return 1260 -- 20 s of contest from the first sighting, which may come a second after the subdue
end)
snap("capture-done", function(P) return P.ai_pos end, nil, 15, true)
step(function(player, P)
  local c = P.ai_city and cities.get(P.ai_city)
  check("captured", c ~= nil and c.force == P.F, "AI town %s owner %s", tostring(P.ai_city), c and c.force or "-")
  for _, e in ipairs(P.attackers or {}) do if e.valid then e.destroy() end end
  camera.jump_to(player, P.home)
  return 30
end)

---------------------------------------------------------------------------
-- An own town under attack: the city panel row, Jump, the red list row
---------------------------------------------------------------------------
step(function(player, P)
  local spot = city_spot(P.F, P.home, {125, 140, 160}, P.ai_pos)
  if spot then
    clear_area(spot, 30, 30)
    P.town = cities.found(P.F, spot)
  end
  local c = P.town and cities.get(P.town)
  note("own town %s at %s", tostring(P.town), spot and util.pos_str(spot) or "-")
  if c then
    P.town_center = c.entity
    P.town_pos = c.position
  end
  return 180
end)
step(function(player, P)
  if not (P.town_center and P.town_center.valid) then return 15 end
  P.raiders = spawn(E, {x = P.town_pos.x + 8, y = P.town_pos.y + 9}, 5)
  return 240
end)
step(function(player, P)
  if not (P.town_center and P.town_center.valid) then return 15 end
  local a = cities.under_attack(P.town)
  check("under_attack_tracked", a ~= nil, "last attack %s", a and serpent.line(a) or "none")
  citygui.open(player, P.town)
  camera.jump_to(player, P.home) -- away from the town: the Jump button has to bring the camera there
  return 60
end)
snap("town-under-attack", nil, nil, 15, true)
step(function(player, P)
  if P.town_center and P.town_center.valid then
    P.town_center.health = P.town_center.max_health * 0.1
    capture.subdue(P.town_center, E)
  end
  return 420
end)
snap("town-being-captured", nil, nil, 15, true)
step(function(player, P)
  local row = find(player.gui.screen, "rts_citygui_attack_jump")
  check("attack_row", row ~= nil and row.parent.visible, "attack row %s visible %s", tostring(row ~= nil),
    tostring(row and row.parent.visible))
  click(player, row)
  return 30
end)
snap("town-jumped", nil, nil, 15)
step(function(player, P)
  -- the town falls (no defenders): the loser's alert; then the attackers go
  return 900
end)
snap("town-lost", nil, nil, 15, true)
step(function(player, P)
  local c = P.town and cities.get(P.town)
  note("own town owner after the contest: %s", c and c.force or "-")
  for _, e in ipairs(P.raiders or {}) do if e.valid then e.destroy() end end
  citygui.open(player, P.capital_id)
  camera.jump_to(player, P.home)
  return 30
end)

---------------------------------------------------------------------------
-- Diplomacy: an AI peace offer, Accept
---------------------------------------------------------------------------
step(function(player, P)
  dbg.run_command("rts-diplomacy", "propose " .. E .. " " .. P.F .. " peace", player.index)
  local list = diplomacy.pending_for(P.F)
  P.offer = list[#list] and list[#list].id
  note("AI peace proposal %s", tostring(P.offer))
  return 90
end)
snap("diplo-offer", nil, nil, 15, true)
step(function(player, P)
  diplomacygui.toggle(player)
  return 60
end)
snap("diplo-panel-offer", nil, nil, 15, true)
step(function(player, P)
  diplomacygui.close(player)
  local b = find(player.gui.screen, "rts_diplo_accept_o" .. tostring(P.offer))
  note("offers Accept button %s", tostring(b ~= nil))
  click(player, b)
  return 90
end)
snap("diplo-accepted", nil, nil, 15, true)
step(function(player, P)
  check("peace_accepted", diplomacy.state(P.F, E) == "peace" or diplomacy.state(P.F, E) == "ceasefire", "state %s",
    tostring(diplomacy.state(P.F, E)))
  return 15
end)

---------------------------------------------------------------------------
-- Division supply: supplied, low, out, refill at the CC
---------------------------------------------------------------------------
step(function(player, P)
  citygui.open(player, P.capital_id)
  local g = util.pstorage(player.index).citygui
  if g then g.pinned, g.closed = nil, g.key end
  selection.clear(player.index)
  local at = {x = P.home.x + P.front.x * 22, y = P.home.y + P.front.y * 22}
  P.div_units = spawn(P.F, at, 8)
  P.div = divisions.create(P.F, P.div_units, {name = "Supply Test", stance = "hold"}, {owner = "player"})
  camera.jump_to(player, at)
  selection.set(player.index, P.div_units)
  return 90
end)
snap("div-supplied", nil, nil, 15, true)
step(function(player, P)
  dbg.run_command("rts-supply", "30", player.index)
  return 60
end)
snap("div-low", nil, nil, 15)
step(function(player, P)
  dbg.run_command("rts-supply", "0", player.index)
  return 60
end)
snap("div-out", nil, nil, 15)
step(function(player, P)
  local n = orders.attack_move(player.index, {x = P.home.x + P.front.x * 60, y = P.home.y + P.front.y * 60})
  check("out_refused", n == 0, "attack-move with the out division selected ordered %d units", n)
  economy.give(P.F, "rts-supply-crate", 20)
  P.t_refill = game.tick
  return 3660
end)
snap("div-refilled", nil, nil, 15)
step(function(player, P)
  local D = divisions.get(P.div)
  check("refill", D and D.sp >= 15, "SP %.1f after 61 s next to the CC with 20 crates (state %s)", D and D.sp or -1,
    tostring(D and warsupply.state(P.div)))
  return 15
end)

---------------------------------------------------------------------------
-- Troop train: two depots on one track, Deploy troop train, embark, ride, disembark
---------------------------------------------------------------------------
step(function(player, P)
  selection.clear(player.index)
  local y = math.floor(P.home.y + 48)
  local cx = math.floor(P.home.x)
  clear_area({x = cx, y = y + 6}, 95, 14)
  P.depA = place(rails.DEPOT, {x = cx - 70, y = y}, P.F, 6)
  P.depB = place(rails.DEPOT, {x = cx + 70, y = y}, P.F, 6)
  local dA = P.depA and rails.depot(P.depA.unit_number)
  local dB = P.depB and rails.depot(P.depB.unit_number)
  note("depots %s at %s, %s at %s, platforms %s / %s", tostring(P.depA and P.depA.unit_number),
    P.depA and util.pos_str(P.depA.position) or "-", tostring(P.depB and P.depB.unit_number),
    P.depB and util.pos_str(P.depB.position) or "-", dA and dA.platform and serpent.line(dA.platform.ends) or "-",
    dB and dB.platform and serpent.line(dB.platform.ends) or "-")
  local laid = 0
  if dA and dB and dA.platform and dB.platform and dA.platform.track == dB.platform.track then
    local ty = dA.platform.track
    local ax = math.min(dA.platform.ends[2].x, dB.platform.ends[2].x)
    local bx = math.max(dA.platform.ends[1].x, dB.platform.ends[1].x)
    for x = ax + 1, bx - 1, 2 do
      if match.surface().create_entity({name = "straight-rail", position = {x, ty}, direction = defines.direction.east,
                                        force = P.F}) then laid = laid + 1 end
    end
  end
  note("rails laid %d", laid)
  P.track_ok = laid > 0
  for _, d in ipairs({P.depA, P.depB}) do
    if d then logistics.hub_network(d.unit_number).insert({name = "coal", count = 100}) end
  end
  if P.depA then
    local net = logistics.hub_network(P.depA.unit_number)
    net.insert({name = "rts-locomotive-kit", count = 2})
    net.insert({name = "rts-troop-wagon-kit", count = 1})
    camera.jump_to(player, P.depA.position)
    selection.select_building(player.index, P.depA.unit_number)
  end
  return 60
end)
snap("depot-troop", nil, nil, 15, true)
step(function(player, P)
  local b = find(player.gui.screen.rts_railgui_frame, "rts_railgui_deploy_troop")
  check("deploy_troop_button", b ~= nil and b.enabled, "Deploy troop train %s", b and tostring(b.enabled) or "-")
  click(player, b)
  return 120
end)
step(function(player, P)
  local rec = P.depA and garrison.troop_train_at(P.F, P.depA.unit_number)
  P.train = rec and rails.train_of(rec)
  note("troop train %s", tostring(P.train and P.train.id))
  if P.train then
    selection.select_building(player.index, P.train.front_stock.unit_number)
    if P.depB then rails.set_route(P.train, P.depA.unit_number, P.depB.unit_number) end
  end
  return 60
end)
snap("troop-train-panel", nil, nil, 15, true)
step(function(player, P)
  selection.clear(player.index)
  if P.depA then
    local ok = divisions.order(P.div, "embark", P.depA.unit_number)
    note("embark order %s", tostring(ok))
  end
  P.t_embark = game.tick
  return 600
end)
snap("troop-boarding", nil, nil, 15, true)
step(function(player, P)
  local D = divisions.get(P.div)
  if D and (D.aboard or 0) > 0 and P.train and P.train.valid and P.train.front_stock then
    camera.jump_to(player, P.train.front_stock.position)
  end
  note("aboard %s after %.0f s", tostring(D and D.aboard), (game.tick - P.t_embark) / 60)
  return 1500
end)
step(function(player, P)
  if P.depB then camera.jump_to(player, P.depB.position) end
  local D = divisions.get(P.div)
  local near = 0
  for _, rec in ipairs(D and divisions.live_members(D) or {}) do
    if P.depB and util.distance(rec.entity.position, P.depB.position) < 60 then near = near + 1 end
  end
  check("troop_ride", near >= 6, "%d members near depot B, aboard %s", near, tostring(D and D.aboard))
  if D then
    local list = {}
    for _, rec in ipairs(divisions.live_members(D)) do list[#list + 1] = rec.entity end
    selection.set(player.index, list)
  end
  return 60
end)
snap("troop-disembarked", nil, nil, 15, true)

---------------------------------------------------------------------------
-- /rts-goto: the nearest city-state and port
---------------------------------------------------------------------------
step(function(player, P)
  selection.clear(player.index)
  camera.jump_to(player, P.home)
  dbg.run_command("rts-goto", "city-state", player.index)
  P.cs_pos = player.position
  return 120
end)
snap("goto-city-state", nil, nil, 15, true)
step(function(player, P)
  camera.jump_to(player, P.home)
  dbg.run_command("rts-goto", "port", player.index)
  dbg.run_command("rts-diplomacy", "", player.index)
  return 60
end)
snap("goto-port", nil, nil, 15)

---------------------------------------------------------------------------
-- Minimap modes, an alert with its region, the strategic zoom
---------------------------------------------------------------------------
step(function(player, P)
  selection.clear(player.index)
  camera.jump_to(player, P.home)
  logistics.alert(P.F, "hauler-lost", {x = P.home.x + 20, y = P.home.y + 20}, "rts.alert-hauler-lost")
  return 60
end)
snap("minimap-regional", nil, nil, 15, true)
step(function(player, P)
  local lines = {}
  for _, a in ipairs(storage.alerts or {}) do
    if a.force == P.F then lines[#lines + 1] = serpent.line({a.kind, a.text, a.params}) end
  end
  note("alerts: %s", table.concat(lines, " | "))
  strategic.toggle_minimap(player)
  return 60
end)
snap("minimap-world", nil, nil, 15, true)
step(function(player, P)
  strategic.toggle_minimap(player)
  local s = match.surface()
  player.force.chart(s, {{P.home.x - 700, P.home.y - 700}, {P.home.x + 700, P.home.y + 700}})
  return 300
end)
step(function(player, P)
  camera.jump_to(player, P.home)
  player.zoom = 0.05
  note("M2D_CAPTURE strategic-z005 (render mode %s, zoom %.3f)", util.define_name(defines.render_mode,
    player.render_mode), player.zoom)
  util.log("M2D_CAPTURE strategic-z005")
  return 240
end)
snap("strategic-z005", nil, 0.05, 15, true)
step(function(player, P)
  player.zoom = 0.1
  util.log("M2D_CAPTURE strategic-z010")
  return 240
end)
step(function(player, P)
  camera.jump_to(player, P.home)
  player.zoom = 1
  return 60
end)

---------------------------------------------------------------------------
-- Disband on the units page
---------------------------------------------------------------------------
step(function(player, P)
  local at = {x = P.home.x - P.front.x * 16, y = P.home.y - P.front.y * 16}
  P.dis = spawn(P.F, at, 4)
  camera.jump_to(player, at)
  selection.set(player.index, P.dis)
  return 60
end)
snap("units-page", nil, nil, 15, true)
step(function(player, P)
  local b = find(player.gui.screen, "rts_hud_disband")
  check("disband_button", b ~= nil and b.visible, "bin %s visible %s", tostring(b ~= nil), tostring(b and b.visible))
  local r, n = demolish.disband(player.index)
  note("disband first press %s %s", tostring(r), tostring(n))
  return 20
end)
snap("disband-armed", nil, nil, 15)
step(function(player, P)
  local r, n = demolish.disband(player.index)
  local alive = 0
  for _, e in ipairs(P.dis) do if e.valid then alive = alive + 1 end end
  check("disband_done", r == "done" and alive == 0, "second press %s %s, %d left", tostring(r), tostring(n), alive)
  return 60
end)
snap("disband-done", nil, nil, 15)

---------------------------------------------------------------------------
-- Info box: a ghost from the build menu, Q, 60 s
---------------------------------------------------------------------------
step(function(player, P)
  camera.jump_to(player, P.home)
  hud.set_build_tab(player, "production")
  local ok = hud.build_click(player, "rts-lab")
  local p = {x = P.home.x + P.front.y * 14, y = P.home.y - P.front.x * 14}
  local built = player.can_build_from_cursor({position = p}) and player.build_from_cursor({position = p})
  note("ghost in cursor %s, built from cursor at %s: %s", tostring(ok), util.pos_str(p), tostring(built))
  return 20
end)
step(function(player, P)
  events.dispatch("rts-clear-cursor", {player_index = player.index, input_name = "rts-clear-cursor",
    name = "rts-clear-cursor", tick = game.tick})
  player.clear_cursor()
  P.t_q = game.tick
  return 3600
end)
snap("infobox-60s", nil, nil, 15, true)
step(function(player, P)
  check("infobox_selected", player.selected == nil, "player.selected %s after 60 s",
    player.selected and player.selected.name or "nil")
  util.log("RTS_M2D_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(15, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.m2d_probe
  if not P then
    P = {i = 1, at = game.tick + 240}
    storage.m2d_probe = P
  end
  if P.done or game.tick < P.at then return end
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("m2d probe step %d error: %s", idx, tostring(wait))
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    if P.i > #STEPS and wait then util.log("RTS_M2D_GUI_DONE player %d (steps ran out)", player.index) end
    return
  end
  P.at = game.tick + wait
end)
