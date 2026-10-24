-- Phase 5 M3 integration: HUD/UX audit and the coordinates of docs/qa/phase5-m3-protocol.md, GUI probe. It plays the
-- protocol's steps in order on a 2048 Nation match against one AI, then the 4096 lobby, and checks the protocol's
-- coordinates with REAL clicks and keys (tools/gui-drive.sh runs the "RTS_DRIVE <n> ..." lines it logs: click,
-- rclick, move, key, capture); every real input is checked a moment later ("m3d real <name>: PASS|FAIL") and, when it
-- missed, the probe does the same thing through the handler so the run goes on.
-- Test copy (self-test off), RTS_LOCALE=en or ru:
--   rm -rf build/m3i-en && mkdir -p build/m3i-en && cp -R mods/factorio-rts mods/mod-list.json build/m3i-en/
--   cp tools/probes/m3_docs_gui.lua tools/probes/m3_qa_cmds.lua build/m3i-en/factorio-rts/scripts/
--   printf '\nrequire("scripts.m3_docs_gui")\n' >> build/m3i-en/factorio-rts/control.lua
--   tools/gui-drive.sh build/m3i-en-gui.log build/shots-m3i-en-window RTS_M3D_GUI_DONE &
--   RTS_LOCALE=en tools/gui-run.sh build/m3i-en 1500 RTS_M3D_GUI_DONE '\[rts\] m3d|rror'
-- Check `pgrep -fl 'MacOS/factorio' | grep window-size` prints nothing first: the input goes to the front window.
-- Screenshots build/shots-m3i-<locale>/rts-m3d-<tag>.png (take_screenshot, the game area at 1280x800) and window
-- captures (title bar included, +28 px) in build/shots-m3i-<locale>-window/. Log lines "[rts] m3d probe ...", checks
-- "[rts] m3d check|real <name>: PASS|FAIL ...", the stop marker RTS_M3D_GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local hud = require("scripts.hud")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local cities = require("scripts.cities")
local ages = require("scripts.ages")
local research = require("scripts.research")
local treasury = require("scripts.treasury")
local market = require("scripts.market")
local marketgui = require("scripts.marketgui")
local ledgergui = require("scripts.ledgergui")
local citygui = require("scripts.citygui")
local techgui = require("scripts.techgui")
local diplomacy = require("scripts.diplomacy")
local diplomacygui = require("scripts.diplomacygui")
local divisions = require("scripts.divisions")
local rails = require("scripts.rails")
local age3 = require("scripts.age3")
local rare = require("scripts.rare")
local sinks = require("scripts.sinks")
local air = require("scripts.air")
local fronts = require("scripts.fronts")
local belts = require("scripts.belts")
local trainswar = require("scripts.trainswar")
local worldgen = require("scripts.worldgen")
local garrison = require("scripts.garrison")
local commander = require("scripts.commander")
local dbg = require("scripts.debug")
local qa = require("scripts.m3_qa_cmds") -- the proposed /rts-front and /rts-deposit

local E = "rts-ai-1"
-- macOS virtual key codes (tools/gui-input/fdrive.swift)
local KEY = {F = 3, H = 4, X = 7, B = 11, Q = 12, Y = 16, SPACE = 49, ESC = 53}

-- 0.1.1 (r2-ux, issue #17): the coordinates that differ between the English and the Russian layout (game area of the
-- 1280x800 window, UI scale 0.75), measured from this probe's screenshots; every other coordinate is the same in both.
-- The build menu's tab captions are wider in Russian, so the tabs sit further right; the air panel is wider.
local LAYOUT = {
  en = {tab_economy = {1077, 684}, tab_production = {1131, 684}, tab_defence = {1183, 684}, tab_age2 = {1216, 684},
        air_close = {1243, 226}, hire = {837, 588}},
  ru = {tab_economy = {1082, 684}, tab_production = {1151, 684}, tab_defence = {1214, 684}, tab_age2 = {1249, 684},
        air_close = {1256, 226}, hire = {837, 588}},
}
local L = LAYOUT.en -- set from the player's locale by the runner below

local function note(fmt, ...) util.log("m3d probe: " .. fmt, ...) end
local function check(name, ok, fmt, ...)
  util.log("m3d check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function drive(fmt, ...)
  storage.m3d_seq = (storage.m3d_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.m3d_seq, ...)
end
local function click_at(name) drive("click %d %d", L[name][1], L[name][2]) end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end
local function find_type(el, t)
  if not (el and el.valid) then return nil end
  if el.type == t then return el end
  for _, c in pairs(el.children) do
    local f = find_type(c, t)
    if f then return f end
  end
end
local function find_tag(el, key, value)
  if not (el and el.valid) then return nil end
  if el.tags and el.tags[key] == value then return el end
  for _, c in pairs(el.children) do
    local f = find_tag(c, key, value)
    if f then return f end
  end
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
  note("frames %s: %s", tag, table.concat(parts, " "))
end

local function shot(player, tag)
  local path = string.format("rts-m3d-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  note("screenshot %s at %s zoom %.3f", path, util.pos_str(player.position), player.zoom)
end

-- Pixel at the start zoom (0.5, camera on the CC) of a map position, and back.
local function spx(P, pos)
  return math.floor(640 + (pos.x - P.home.x) * 16 + 0.5), math.floor(400 + (pos.y - P.home.y) * 16 + 0.5)
end
local function at_px(P, x, y) return {x = P.home.x + (x - 640) / 16, y = P.home.y + (y - 400) / 16} end

local function clear_ground(center, r)
  for _, e in ipairs(match.surface().find_entities_filtered({area = {{center.x - r, center.y - r},
      {center.x + r, center.y + r}}, type = {"tree", "simple-entity", "cliff", "fish"}})) do
    if e.valid then e.destroy() end
  end
end
local function place(name, pos, force, radius)
  local surface = match.surface()
  clear_ground(pos, 6)
  local p = surface.find_non_colliding_position(name, pos, radius or 10, 0.5, true) or pos
  return surface.create_entity({name = name, position = p, force = force, raise_built = true})
end
local function own_entity(P, name, near, r)
  local list = match.surface().find_entities_filtered({name = name, force = P.F, position = near, radius = r or 8})
  return list[1]
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
local function snap(tag, wait)
  step(function(player, P)
    shot(player, tag)
    log_frames(player, tag)
    return wait or 15
  end)
end
local function capture(tag, wait)
  step(function(player, P)
    drive("capture m3d-%s", tag)
    return wait or 60
  end)
end
local function wait_until(label, cond, every, max)
  step(function(player, P)
    P.wn = (P.wn or 0) + every
    local ok = cond(player, P)
    if ok or P.wn >= max then
      note("wait %s: %s after %d ticks", label, ok and "done" or "TIMEOUT", P.wn)
      P.wn = nil
      return 1
    end
    P.i = P.i - 1
    return every
  end)
end
-- A real input, then (after `wait` ticks) its check; on a miss the fallback does it through the handler.
local function real(name, input, ok_fn, fallback, wait)
  step(function(player, P)
    input(player, P)
    return math.max(wait or 90, 90)
  end)
  step(function(player, P)
    local ok, detail = ok_fn(player, P)
    util.log("m3d real %s: %s %s", name, ok and "PASS" or "FAIL", tostring(detail or ""))
    if not ok and fallback then fallback(player, P) end
    return 30
  end)
end
local function home_view(player, P)
  camera.jump_to(player, P.home)
  player.zoom = 0.5
end

---------------------------------------------------------------------------
-- Part A: lobby (2048, 2 nations) and the help page
---------------------------------------------------------------------------
snap("a01-lobby-skirmish")
real("lobby_mode", function() drive("click 596 314") end, function(player)
  return true, "list open"
end, nil, 40)
capture("a01-list-mode", 40)
real("lobby_mode_nation", function() drive("click 596 356") end, function(player)
  return storage.lobby.pending.mode == "nation", "mode " .. tostring(storage.lobby.pending.mode)
end, function(player) select_dd(player, find(player.gui.screen.rts_lobby, "rts_lobby_mode"), 2) end, 40)
snap("a02-lobby-nation")
for _, dd in ipairs({{"nations", 596, 267}, {"size", 615, 321}, {"survey", 596, 375}, {"victory", 607, 402},
                     {"time", 596, 429}}) do
  step(function(player, P) drive("click %d %d", dd[2], dd[3]) return 50 end)
  capture("a02-list-" .. dd[1], 40)
  step(function(player, P) drive("click %d %d", dd[2], dd[3]) return 50 end)
end
step(function(player, P)
  local L = player.gui.screen.rts_lobby
  local items = {}
  for _, name in ipairs({"opponents", "difficulty", "size", "map", "survey", "victory", "time_limit"}) do
    local dd = find(L, "rts_lobby_" .. name)
    items[#items + 1] = string.format("%s=%d/%d", name, dd and dd.selected_index or -1, dd and #dd.items or -1)
  end
  check("lobby_defaults", storage.lobby.pending.opponents == 1 and not storage.lobby.pending.survey
    and (storage.lobby.pending.victory or "conquest_space") == "conquest_space", "%s", table.concat(items, " "))
  hud.toggle_help(player, "probe lobby")
  return 30
end)
snap("a03-help-lobby-top")
real("help_wheel", function() for _ = 1, 30 do drive("move 640 500") end drive("click 640 500") end,
  function(player) return true end, nil, 30)
step(function(player, P)
  local pane = find_type(player.gui.screen.rts_hud_help, "scroll-pane")
  if pane then pane.scroll_to_bottom() end
  return 30
end)
snap("a04-help-lobby-bottom")
step(function(player, P)
  hud.toggle_help(player, "probe lobby")
  return 30
end)
real("lobby_start", function() drive("click 732 586") end, function(player)
  return not match.in_lobby(), "in lobby " .. tostring(match.in_lobby())
end, function(player) click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start")) end, 600)
step(function(player, P)
  local F = player.force.name
  P.F = F
  P.cc = buildings.main_cc(F).entity
  P.home = P.cc.position
  P.capital_id = storage.nations[F].capital
  home_view(player, P)
  local c = match.config()
  note("capital at %s, mode %s, world %s, nations %s, victory %s, survey %s", util.pos_str(P.home), tostring(c.mode),
    tostring(c.world_size), tostring(c.nations), tostring(c.victory), tostring(c.survey))
  return 60
end)
snap("a05-capital")

---------------------------------------------------------------------------
-- Part B: Age II, the research panel, the ledger, the Space Program to Age III
---------------------------------------------------------------------------
step(function(player, P)
  ages.set_age(P.F, 2, "probe /rts-age rts-player 2")
  for _, t in ipairs({"rts-industrialisation", "rts-electrification"}) do dbg.run_command("rts-research", t, player.index) end
  treasury.add(P.F, 20000, "probe /rts-treasury add 20000")
  techgui.open(player)
  return 60
end)
snap("b01-research-age2")
step(function(player, P)
  techgui.close(player)
  ledgergui.open(player)
  return 60
end)
snap("b02-ledger-ready")
real("ledger_start", function() drive("click 683 312") end, function(player, P)
  local Pj = age3.project(P.F)
  return Pj ~= nil and Pj.state == "building", Pj and Pj.position and util.pos_str(Pj.position) or "-"
end, function(player) click(player, util.pstorage(player.index).ledger.gui.start) end, 90)
step(function(player, P)
  local Pj = age3.project(P.F)
  if Pj and Pj.position then
    local x, y = spx(P, Pj.position)
    note("Launch complex at %s: start-zoom pixel (%d, %d)", util.pos_str(Pj.position), x, y)
  end
  return 15
end)
snap("b03-ledger-started")
step(function(player, P)
  for _, spec in ipairs({{"steel-plate", 200}, {"concrete", 100}, {"advanced-circuit", 60}}) do
    dbg.run_command("rts-give", spec[1] .. " " .. spec[2], player.index)
  end
  return 240
end)
snap("b04-ledger-progress")
real("ledger_rush", function() drive("click 748 316") end, function(player, P)
  return sinks.rush_state(P.F) ~= nil, serpent.line(sinks.rush_state(P.F))
end, function(player) click(player, util.pstorage(player.index).ledger.gui.a3_rush) end, 60)
snap("b05-ledger-rush")
step(function(player, P)
  ledgergui.close(player)
  return 30
end)
snap("b06-capital-complex")
wait_until("stage 1", function(player, P) return ages.of(P.F) >= 3 end, 60, 60 * 90)
step(function(player, P)
  check("age3", ages.of(P.F) >= 3, "%s", age3.describe(P.F))
  return 60
end)
snap("b07-age3")
step(function(player, P)
  local Pj = age3.project(P.F)
  if Pj and Pj.position then camera.jump_to(player, Pj.position) end
  player.zoom = 1
  return 30
end)
snap("b08-launch-complex-z1")

---------------------------------------------------------------------------
-- Part C: automation (a Steel works) and a rare extractor
---------------------------------------------------------------------------
step(function(player, P)
  home_view(player, P)
  dbg.run_command("rts-give", "rts-district-steel 1", player.index)
  return 30
end)
-- Age II tab, Steel works (row 1, 5th), the site 12 left / 6 down (448, 496), Q
step(function(player, P) click_at("tab_age2") return 30 end)
step(function(player, P) drive("click 1191 711") return 30 end)
step(function(player, P) drive("click 448 496") return 30 end)
real("build_steel_works", function() drive("key %d", KEY.Q) end, function(player, P)
  local g = own_entity(P, "entity-ghost", at_px(P, 448, 496), 6) or own_entity(P, "rts-district-steel", at_px(P, 448, 496), 6)
  return g ~= nil, g and (g.name .. " " .. util.pos_str(g.position)) or "nothing at (448, 496)"
end, function(player, P) place("rts-district-steel", at_px(P, 448, 496), P.F) end, 60)
wait_until("steel works", function(player, P)
  P.district = own_entity(P, "rts-district-steel", at_px(P, 448, 496), 8)
  return P.district ~= nil
end, 60, 60 * 40)
step(function(player, P)
  if P.district then
    local x, y = spx(P, P.district.position)
    note("Steel works at %s: start-zoom pixel (%d, %d)", util.pos_str(P.district.position), x, y)
  end
  return 360 -- the staffing pass
end)
real("select_steel_works", function(player, P)
  local x, y = spx(P, P.district.position)
  drive("click %d %d", x, y)
end, function(player, P)
  return player.gui.screen.rts_citygui_staff ~= nil, "staffing box"
end, function(player, P) selection.select_building(player.index, P.district.unit_number) end, 60)
snap("c01-district-staff")
real("select_cc", function() drive("click 640 400") end, function(player)
  return player.gui.screen.rts_citygui_frame ~= nil, "city panel"
end, function(player, P) selection.select_building(player.index, P.cc.unit_number) end, 60)
snap("c02-city-panel-before")
step(function(player, P)
  selection.clear(player.index)
  dbg.run_command("rts-give", "rts-automation-kit 4", player.index)
  ledgergui.open(player)
  return 60
end)
snap("c03-ledger-age3")
real("automation_metallurgy", function() drive("click 458 349") end, function(player, P)
  local info = age3.automation(P.capital_id).metallurgy
  return info ~= nil and info.on == true, serpent.line(info)
end, function(player) click(player, util.pstorage(player.index).ledger.gui.a3_auto.metallurgy) end, 400)
snap("c04-ledger-automation")
step(function(player, P)
  ledgergui.close(player)
  selection.select_building(player.index, P.district.unit_number)
  return 120
end)
snap("c05-district-automated")
step(function(player, P)
  selection.select_building(player.index, P.cc.unit_number)
  return 60
end)
snap("c06-city-panel-after")
step(function(player, P)
  selection.clear(player.index)
  dbg.run_command("rts-research", "rts-geology", player.index)
  qa.deposit({player_index = player.index, parameter = "saltpetre"})
  local list = match.surface().find_entities_filtered({name = "rts-rare-saltpetre", position = P.home, radius = 40})
  local sx, sy, n = 0, 0, #list
  for _, e in ipairs(list) do sx, sy = sx + e.position.x, sy + e.position.y end
  P.deposit = n > 0 and {x = math.floor(sx / n) + 0.5, y = math.floor(sy / n) + 0.5} or nil
  if P.deposit then
    local x, y = spx(P, P.deposit)
    note("deposit centre %s: start-zoom pixel (%d, %d), %d tiles", util.pos_str(P.deposit), x, y, n)
  end
  dbg.run_command("rts-give", "rts-rare-extractor 1", player.index)
  return 60
end)
snap("c07-deposit")
-- Age II tab, Rare extractor (row 2, 7th), the deposit, Q
step(function(player, P) click_at("tab_age2") return 30 end)
step(function(player, P) drive("click 1253 742") return 30 end)
step(function(player, P)
  local x, y = spx(P, P.deposit)
  drive("click %d %d", x, y)
  return 30
end)
real("build_extractor", function() drive("key %d", KEY.Q) end, function(player, P)
  local g = own_entity(P, "entity-ghost", P.deposit, 5) or own_entity(P, "rts-rare-extractor", P.deposit, 5)
  return g ~= nil, g and (g.name .. " " .. util.pos_str(g.position)) or "nothing on the deposit"
end, function(player, P) place("rts-rare-extractor", P.deposit, P.F, 2) end, 60)
wait_until("saltpetre bonus", function(player, P)
  local b = rare.bonuses(P.F)
  return b and b.saltpetre and b.saltpetre.active
end, 60, 60 * 60)
step(function(player, P)
  P.extractor = own_entity(P, "rts-rare-extractor", P.deposit, 5)
  check("rare_bonus", rare.bonuses(P.F).saltpetre and rare.bonuses(P.F).saltpetre.active, "%s", rare.describe(P.F))
  if P.extractor then selection.select_building(player.index, P.extractor.unit_number) end
  return 60
end)
snap("c08-extractor-page")
step(function(player, P)
  selection.clear(player.index)
  ledgergui.open(player)
  return 60
end)
snap("c09-ledger-rare")
step(function(player, P)
  ledgergui.close(player)
  return 15
end)

---------------------------------------------------------------------------
-- Part D: war, a front (/rts-front), a division, Hold line, H
---------------------------------------------------------------------------
step(function(player, P)
  diplomacygui.toggle(player)
  return 60
end)
snap("d01-diplomacy")
real("diplomacy_war", function() drive("click 736 365") end, function(player, P)
  return diplomacy.state(P.F, E) == "war", tostring(diplomacy.state(P.F, E))
end, function(player) click(player, find(player.gui.screen, "rts_diplo_war_" .. E)) end, 60)
snap("d02-diplomacy-war")
step(function(player, P)
  diplomacygui.close(player)
  qa.front({player_index = player.index, parameter = ""})
  local segs = fronts.segments(P.F)
  check("front", #segs > 0, "%s", fronts.describe(P.F))
  P.front_view = {x = player.position.x, y = player.position.y}
  local seg = fronts.nearest(P.F, player.position, 400) or segs[1]
  if seg then
    P.seg = seg
    note("segment %d: a %s b %s mid %s back (%.2f, %.2f); camera %s; mid on screen (%d, %d)", seg.id,
      util.pos_str(seg.a), util.pos_str(seg.b), util.pos_str(seg.mid), seg.back.x, seg.back.y, util.pos_str(player.position),
      math.floor(640 + (seg.mid.x - player.position.x) * 16), math.floor(400 + (seg.mid.y - player.position.y) * 16))
  end
  return 60
end)
snap("d03-front-view")
step(function(player, P)
  dbg.run_command("rts-spawn", "rts-walker 16", player.index)
  local list = {}
  for _, rec in units.for_force(P.F) do
    if rec.entity.valid and rec.entity.name == "rts-walker" and util.distance(rec.entity.position, player.position) < 30 then
      list[#list + 1] = rec.entity
    end
  end
  -- Ctrl+A, the walker card, Form division (the probe forms it from the 16 new walkers)
  P.div = divisions.create(P.F, list, nil, {owner = "player"})
  selection.set(player.index, list)
  P.walkers = list
  note("division #%s %s with %d walkers", tostring(P.div), P.div and divisions.label(divisions.get(P.div)) or "-", #list)
  return 90
end)
snap("d04-front-card")
real("hold_line_button", function() drive("click 194 282") end, function(player, P)
  local D = divisions.get(P.div)
  return D and D.order and D.order.kind == "hold_line", tostring(D and D.order and D.order.kind)
end, function(player, P) click(player, find(player.gui.screen.rts_div_panel, "rts_div_hold_line_" .. tostring(P.div))) end, 60)
step(function(player, P) return 600 end)
snap("d05-hold-line")
-- X stops it; the mouse onto the front line, H
step(function(player, P)
  selection.set(player.index, P.walkers)
  return 30
end)
real("stop_x", function() drive("key %d", KEY.X) end, function(player, P)
  local D = divisions.get(P.div)
  return not (D and D.order and D.order.kind == "hold_line"), tostring(D and D.order and D.order.kind)
end, nil, 60)
real("hold_h", function(player, P)
  local x = math.floor(640 + (P.seg.mid.x - player.position.x) * player.zoom * 32 + 0.5)
  local y = math.floor(400 + (P.seg.mid.y - player.position.y) * player.zoom * 32 + 0.5) + 40
  note("H at the line: mouse (%d, %d)", x, y)
  drive("move %d %d", x, y)
  drive("key %d", KEY.H)
end, function(player, P)
  local D = divisions.get(P.div)
  return D and D.order and D.order.kind == "hold_line", tostring(D and D.order and D.order.kind)
end, function(player, P) click(player, find(player.gui.screen.rts_div_panel, "rts_div_hold_line_" .. tostring(P.div))) end, 90)
snap("d06-hold-h")
step(function(player, P)
  player.zoom = 0.1
  return 30
end)
capture("d07-front-map", 90)
step(function(player, P)
  selection.clear(player.index)
  home_view(player, P)
  return 30
end)

---------------------------------------------------------------------------
-- Part E: the fort belt tool: F, two right clicks, Build
---------------------------------------------------------------------------
step(function(player, P)
  dbg.run_command("rts-research", "rts-fortification", player.index)
  for _, spec in ipairs({{"rts-wall", 100}, {"rts-turret", 10}, {"rts-field-depot", 1}, {"firearm-magazine", 100}}) do
    dbg.run_command("rts-give", spec[1] .. " " .. spec[2], player.index)
  end
  return 30
end)
real("belt_f", function() drive("click 1000 250") drive("key %d", KEY.F) end, function(player)
  return player.gui.screen[belts.FRAME] ~= nil, "tool panel"
end, function(player) belts.key_f(player) end, 60)
snap("e01-belt-tool")
step(function(player, P) drive("rclick 320 272") return 45 end)
real("belt_points", function() drive("rclick 320 528") end, function(player, P)
  local T = storage.belts and storage.belts.tools[player.index]
  return T and #T.points == 2, T and (#T.points .. " points") or "no tool"
end, function(player, P)
  local T = storage.belts and storage.belts.tools[player.index]
  if T and #T.points == 0 then belts.add_point(player, at_px(P, 320, 272)) end
  if T and #T.points == 1 then belts.add_point(player, at_px(P, 320, 528)) end
end, 60)
snap("e02-belt-points")
real("belt_build", function() drive("click 710 286") end, function(player, P)
  return belts.of(P.F)[1] ~= nil, belts.describe(P.F)
end, function(player) click(player, find(player.gui.screen[belts.FRAME], "rts_belts_build")) end, 60)
snap("e03-belt-building")
wait_until("belt built", function(player, P)
  local p = belts.of(P.F)[1]
  return p and p.state == "built"
end, 120, 60 * 90)
snap("e04-belt-built")
step(function(player, P)
  check("belt", belts.of(P.F)[1] ~= nil, "%s", belts.describe(P.F))
  return 15
end)
real("belt_close", function() drive("click 762 162") end, function(player)
  return player.gui.screen[belts.FRAME] == nil, "panel gone"
end, function(player) belts.close_tool(player, "probe") end, 40)

---------------------------------------------------------------------------
-- Part F: air: the airfield, scouts, Y, Patrol, Return; an AA turret and an enemy bomber
---------------------------------------------------------------------------
step(function(player, P)
  home_view(player, P)
  for _, t in ipairs({"rts-aviation", "rts-air-force"}) do dbg.run_command("rts-research", t, player.index) end
  dbg.run_command("rts-give", "rts-airfield 1", player.index)
  return 30
end)
step(function(player, P) click_at("tab_production") return 30 end)
step(function(player, P) drive("click 1191 742") return 30 end)
step(function(player, P) drive("click 832 304") return 30 end)
real("build_airfield", function() drive("key %d", KEY.Q) end, function(player, P)
  local g = own_entity(P, "entity-ghost", at_px(P, 832, 304), 6) or own_entity(P, "rts-airfield", at_px(P, 832, 304), 6)
  return g ~= nil, g and (g.name .. " " .. util.pos_str(g.position)) or "nothing at (832, 304)"
end, function(player, P) place("rts-airfield", at_px(P, 832, 304), P.F) end, 60)
wait_until("airfield", function(player, P)
  P.field = own_entity(P, "rts-airfield", at_px(P, 832, 304), 8)
  return P.field ~= nil
end, 60, 60 * 40)
real("select_airfield", function(player, P)
  local x, y = spx(P, P.field.position)
  drive("click %d %d", x, y)
end, function(player, P)
  local h = selection.get_building(player.index)
  return h ~= nil and h == P.field.unit_number, tostring(h)
end, function(player, P) selection.select_building(player.index, P.field.unit_number) end, 60)
snap("f01-airfield-page")
step(function(player, P)
  selection.clear(player.index)
  dbg.run_command("rts-spawn", "rts-scout-plane 3", player.index)
  P.planes = {}
  for _, rec in units.for_force(P.F) do
    if rec.entity.valid and air.is_plane(rec.entity) then P.planes[#P.planes + 1] = rec.entity end
  end
  selection.set(player.index, P.planes) -- Ctrl+A, the third card (the scout planes)
  return 60
end)
real("air_y", function() drive("key %d", KEY.Y) end, function(player)
  return player.gui.screen.rts_airfield_panel ~= nil, "air panel"
end, function(player)
  events.dispatch("rts-airfield-panel", {name = "rts-airfield-panel", player_index = player.index, tick = game.tick})
end, 60)
snap("f02-air-panel")
real("air_patrol", function() drive("click 957 413") end, function(player)
  local ps = util.pstorage(player.index).air_gui
  return ps and ps.armed ~= nil, "armed " .. tostring(ps and ps.armed)
end, function(player)
  local ps = util.pstorage(player.index).air_gui
  if not (ps and ps.armed) then click(player, find_tag(player.gui.screen.rts_airfield_panel, "rts_air", "patrol")) end
end, 30)
snap("f03-patrol-armed")
real("air_patrol_point", function() drive("rclick 400 250") end, function(player, P)
  local n = 0
  for _, e in ipairs(P.planes) do
    local rec = e.valid and storage.units[e.unit_number]
    if rec and rec.order == "patrol" then n = n + 1 end
  end
  return n == #P.planes, n .. " on patrol"
end, function(player, P)
  local c = at_px(P, 400, 250)
  orders.handle_reverse_area(player.index, {}, {left_top = c, right_bottom = c}, false)
end, 300)
snap("f04-patrolling")
real("air_return", function() drive("click 1047 413") end, function(player, P)
  local n = 0
  for _, e in ipairs(P.planes) do if e.valid and air.state(e.unit_number) == "returning" then n = n + 1 end end
  return n > 0, n .. " returning"
end, function(player) click(player, find_tag(player.gui.screen.rts_airfield_panel, "rts_air", "return")) end, 60)
step(function(player, P) return 240 end)
snap("f05-returned")
real("air_close", function() click_at("air_close") end, function(player)
  return player.gui.screen.rts_airfield_panel == nil, "closed"
end, function(player)
  local f = player.gui.screen.rts_airfield_panel
  if f then f.destroy() end
  util.pstorage(player.index).air_gui = nil
end, 30)
step(function(player, P)
  selection.clear(player.index)
  dbg.run_command("rts-give", "rts-aa-turret 1", player.index)
  return 30
end)
-- Defence tab, AA turret (row 2, 1st), the site 8 left / 8 down (512, 528), Q
step(function(player, P) click_at("tab_defence") return 30 end)
step(function(player, P) drive("click 1067 742") return 30 end)
step(function(player, P) drive("click 512 528") return 30 end)
real("build_aa", function() drive("key %d", KEY.Q) end, function(player, P)
  local g = own_entity(P, "entity-ghost", at_px(P, 512, 528), 4) or own_entity(P, "rts-aa-turret", at_px(P, 512, 528), 4)
  return g ~= nil, g and (g.name .. " " .. util.pos_str(g.position)) or "nothing at (512, 528)"
end, function(player, P) place("rts-aa-turret", at_px(P, 512, 528), P.F) end, 60)
wait_until("aa turret", function(player, P)
  P.aa = own_entity(P, "rts-aa-turret", at_px(P, 512, 528), 6)
  return P.aa ~= nil and P.aa.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine") > 0
end, 60, 60 * 40)
step(function(player, P)
  if P.aa then selection.select_building(player.index, P.aa.unit_number) end
  return 60
end)
snap("f06-aa-page")
step(function(player, P)
  selection.clear(player.index)
  -- 0.1.1 (r2-ux): the Commander's rockets shot the bomber before the turret could (RU pass m3a); it holds fire for
  -- this check (disabled by script) and is let go after it
  local cmdr = commander.entity(P.F)
  if cmdr and cmdr.valid then
    cmdr.disabled_by_script = true
    P.cmdr_held = cmdr
  end
  local before = {}
  for _, rec in units.for_force(E) do before[rec.entity.unit_number] = true end
  -- Phase 5 M3 QA fix (F2): 70 tiles east of the AA turret, sent at it (spawned 11 tiles away it bombed the turret
  -- before the turret could prove itself)
  -- (on the side away from the front: the division holding it shot an eastern bomber down before the turret could)
  local ap = P.aa and P.aa.valid and P.aa.position
  local d = (P.seg and ap and P.seg.mid.x > ap.x) and -70 or 70
  dbg.run_command("rts-spawn", ap and string.format("rts-bomber 1 %s %d %.1f %.1f", E, d, ap.x, ap.y)
    or ("rts-bomber 1 " .. E), player.index)
  for _, rec in units.for_force(E) do
    if not before[rec.entity.unit_number] and rec.entity.name == "rts-bomber" then P.enemy = rec.entity end
  end
  note("enemy bomber at %s", P.enemy and util.pos_str(P.enemy.position) or "-")
  return 60
end)
snap("f07-aa-firing")
wait_until("bomber down", function(player, P) return not (P.enemy and P.enemy.valid) end, 30, 60 * 30)
step(function(player, P)
  -- the kill feed names the AA turret (hud.lua kill list: killer rts-aa-turret)
  local by_aa = false
  for _, k in ipairs(storage.hud and storage.hud.kills or {}) do
    if k.name == "rts-bomber" and k.killer == "rts-aa-turret" then by_aa = true end
  end
  check("aa", not (P.enemy and P.enemy.valid) and by_aa, "bomber %s, killed by the AA turret: %s",
    (P.enemy and P.enemy.valid) and "alive" or "dead", tostring(by_aa))
  if P.cmdr_held and P.cmdr_held.valid then P.cmdr_held.disabled_by_script = false end
  return 30
end)
snap("f08-aa-after")

---------------------------------------------------------------------------
-- Part G: an artillery train
---------------------------------------------------------------------------
step(function(player, P)
  home_view(player, P)
  for _, t in ipairs({"rts-railways", "rts-military-railways"}) do dbg.run_command("rts-research", t, player.index) end
  for _, spec in ipairs({{"rts-depot", 1}, {"rts-locomotive-kit", 2}, {"rts-artillery-wagon-kit", 1}, {"rts-rail-shell", 40},
                         {"coal", 100}}) do
    dbg.run_command("rts-give", spec[1] .. " " .. spec[2], player.index)
  end
  return 30
end)
-- Economy tab, Rail depot (row 2, 1st), 22 tiles towards the AI town (east: 992, 400), Q
step(function(player, P) click_at("tab_economy") return 30 end)
step(function(player, P) drive("click 1067 742") return 30 end)
step(function(player, P) drive("click 992 400") return 30 end)
real("build_depot", function() drive("key %d", KEY.Q) end, function(player, P)
  local g = own_entity(P, "entity-ghost", at_px(P, 992, 400), 6) or own_entity(P, "rts-depot", at_px(P, 992, 400), 6)
  return g ~= nil, g and (g.name .. " " .. util.pos_str(g.position)) or "nothing at (992, 400)"
end, function(player, P) place("rts-depot", at_px(P, 992, 400), P.F) end, 60)
wait_until("depot", function(player, P)
  P.depot = own_entity(P, "rts-depot", at_px(P, 992, 400), 8)
  return P.depot ~= nil and rails.depot(P.depot.unit_number) ~= nil and rails.depot(P.depot.unit_number).platform ~= nil
end, 60, 60 * 40)
real("select_depot", function(player, P)
  local x, y = spx(P, P.depot.position)
  drive("click %d %d", x, y)
end, function(player) return player.gui.screen.rts_railgui_frame ~= nil, "rail panel" end,
  function(player, P) selection.select_building(player.index, P.depot.unit_number) end, 90)
snap("g01-depot-panel")
real("deploy_artillery", function() drive("click 825 417") end, function(player, P)
  for _, t in ipairs(rails.trains_of(P.F)) do if t.kind == "artillery" then P.train = t.id return true, "train " .. t.id end end
  return false, "no artillery train"
end, function(player) click(player, find(player.gui.screen.rts_railgui_frame, "rts_trainswar_deploy_artillery")) end, 120)
step(function(player, P)
  if not P.train then
    for _, t in ipairs(rails.trains_of(P.F)) do if t.kind == "artillery" then P.train = t.id end end
  end
  local rec
  for _, t in ipairs(rails.trains_of(P.F)) do if t.id == P.train then rec = t end end
  local train = rec and rails.train_of(rec)
  if train then
    local x, y = spx(P, train.front_stock.position)
    note("artillery train front at %s: start-zoom pixel (%d, %d)", util.pos_str(train.front_stock.position), x, y)
    P.train_px = {x, y}
    selection.select_building(player.index, train.front_stock.unit_number) -- a click on a carriage
  end
  return 60
end)
snap("g02-train-panel")
real("bombard_b", function() drive("key %d", KEY.B) end, function(player, P)
  return trainswar.stance(P.train) == "bombard", tostring(trainswar.stance(P.train))
end, function(player) trainswar.key_b(player) end, 60)
snap("g03-train-bombard")
step(function(player, P) return 720 end)
snap("g04-train-fired")
step(function(player, P)
  note("trainswar: %s", trainswar.describe(P.F))
  local d = rails.depot(P.depot.unit_number)
  local o = d and d.label
  check("depot_label", o ~= nil and o.valid, "%s", o and o.valid and serpent.line({o.text, o.scale, o.render_mode}) or "-")
  selection.clear(player.index)
  home_view(player, P)
  player.zoom = 0.1
  return 30
end)
capture("g05-map-z010", 90)
step(function(player, P)
  player.zoom = 0.2
  return 30
end)
capture("g06-map-z020", 90)
step(function(player, P)
  home_view(player, P)
  return 30
end)

---------------------------------------------------------------------------
-- Part H: Hire, the market (port, Mercenaries, a city-state), Rush in the research panel
---------------------------------------------------------------------------
real("select_cc_hire", function() drive("click 640 400") end, function(player)
  return player.gui.screen.rts_citygui_frame ~= nil, "city panel"
end, function(player, P) selection.select_building(player.index, P.cc.unit_number) end, 60)
snap("h01-city-panel")
real("hire", function() click_at("hire") end, function(player, P)
  return (garrison.of(P.capital_id).hired or 0) > 0, string.format("%.1f hired", garrison.of(P.capital_id).hired or 0)
end, function(player) click(player, util.pstorage(player.index).citygui.el.a3_hire) end, 60)
snap("h02-city-hire")
step(function(player, P)
  selection.clear(player.index)
  -- /rts-market ports, /rts-market capture N: the probe places a port next to the capital and takes it
  local surface = match.surface()
  local want = {x = P.home.x, y = P.home.y - 60}
  clear_ground(want, 25)
  local at = surface.find_non_colliding_position(market.POST, want, 30, 1, true) or want
  local p = market.place_port(surface, at)
  P.port = p and p.un
  if P.port then market.set_owner(P.port, P.F) end
  marketgui.open(player)
  return 60
end)
snap("h03-market-port")
real("mercenaries", function() drive("click 370 285") end, function(player, P)
  local s = storage.nations[P.F].sinks
  return s and (s.mercs or 0) == 1, "mercs " .. tostring(s and s.mercs)
end, function(player) click(player, util.pstorage(player.index).market_gui.gui.a3_merc) end, 60)
snap("h04-market-merc")
real("trade_at_open", function() drive("click 800 265") end, function() return true end, nil, 40)
capture("h05-trade-at-list", 40)
real("trade_at_city_state", function(player, P)
  local g = util.pstorage(player.index).market_gui.gui
  local n = #(g.port_dd.items or {})
  P.dd_n = n
  drive("click 800 %d", 265 + 42) -- the second entry (21 px per entry from +21): the first city-state
end, function(player)
  local ps = util.pstorage(player.index).market_gui
  return ps.partner ~= nil, "partner " .. tostring(ps.partner)
end, function(player)
  local g = util.pstorage(player.index).market_gui.gui
  select_dd(player, g.port_dd, #(g.ports or {}) + 1)
end, 60)
snap("h06-market-city-state")
step(function(player, P)
  local ps = util.pstorage(player.index).market_gui
  local rows = {}
  for _, c in ipairs(sinks.city_states(P.F)) do
    if c.city_id == ps.partner then
      P.cs_id = c.city_id
      for _, good in ipairs(c.goods) do rows[#rows + 1] = string.format("%s %d", good.item, good.stock) end
    end
  end
  note("city-state %s goods: %s", tostring(P.cs_id), table.concat(rows, ", "))
  P.rel0 = P.cs_id and sinks.relation(P.cs_id, P.F) or 0
  return 15
end)
step(function(player, P)
  local ps = util.pstorage(player.index).market_gui
  local g = ps.gui
  for _, c in ipairs(sinks.city_states(P.F)) do
    if c.city_id == ps.partner then
      for _, good in ipairs(c.goods) do
        if good.stock >= 100 and not P.cs_item then P.cs_item = good.item end
      end
    end
  end
  local row = P.cs_item and g.rows[P.cs_item]
  note("Buy %s: button %s", tostring(P.cs_item), tostring(row ~= nil))
  if row then click(player, row.buy) end
  return 60
end)
step(function(player, P)
  check("cs_buy", P.cs_id and sinks.relation(P.cs_id, P.F) > P.rel0, "relation %.1f -> %.1f", P.rel0,
    P.cs_id and sinks.relation(P.cs_id, P.F) or -1)
  return 15
end)
snap("h07-market-cs-bought")
step(function(player, P)
  marketgui.close(player)
  techgui.open(player)
  return 60
end)
real("research_chemistry", function() drive("click 1175 431") end, function(player, P)
  local s = research.status(P.F, "rts-chemistry")
  return s == "researching" or s == "queued", tostring(s)
end, function(player, P) research.queue(P.F, "rts-chemistry") techgui.refresh(player) end, 60)
snap("h08-research-chemistry")
-- Phase 5 M3 QA fix (F6): the player has no lab here, so Rush is grey and a click starts nothing (its tooltip says why)
real("research_rush", function() drive("click 1155 194") end, function(player, P)
  local rs = sinks.rush_state(P.F)
  local b = util.pstorage(player.index).techgui and util.pstorage(player.index).techgui.a3_rush
  local _, working = research.lab_counts(P.F)
  if working > 0 then return rs ~= nil and rs.kind == "research", serpent.line(rs) end
  return rs == nil and b ~= nil and b.valid and not b.enabled,
    string.format("no working lab: rush %s, button %s", serpent.line(rs), b and b.valid and tostring(b.enabled) or "-")
end, function(player) end, 60)
snap("h09-research-rush")
step(function(player, P)
  local b = rare.bonuses(P.F).saltpetre
  check("rare_still_on", b and b.active, "%s", rare.describe(P.F))
  return 15
end)
step(function(player, P)
  techgui.close(player)
  return 15
end)

---------------------------------------------------------------------------
-- Part I: F11 in the match; Part J: F10 -> Restart -> the 4096 lobby, Start, the generation line
---------------------------------------------------------------------------
step(function(player, P)
  hud.toggle_help(player, "probe match")
  return 30
end)
snap("i01-help-match-top")
step(function(player, P)
  local pane = find_type(player.gui.screen.rts_hud_help, "scroll-pane")
  if pane then pane.scroll_to_bottom() end
  return 30
end)
snap("i02-help-match-bottom")
step(function(player, P)
  hud.toggle_help(player, "probe match")
  lobby.toggle_menu(player)
  return 30
end)
snap("j01-menu")
real("menu_restart", function() drive("click 533 445") end, function(player)
  return match.in_lobby(), "in lobby " .. tostring(match.in_lobby())
end, function(player) click(player, find(player.gui.screen, "rts_lobby_menu_restart")) end, 120)
snap("j02-lobby-again")
step(function() drive("click 596 267") return 50 end)
real("lobby_nations_6", function() drive("click 620 372") end, function()
  return storage.lobby.pending.opponents == 5, "opponents " .. tostring(storage.lobby.pending.opponents)
end, function(player) select_dd(player, find(player.gui.screen.rts_lobby, "rts_lobby_opponents"), 5) end, 60)
snap("j03-lobby-6-nations")
step(function() drive("click 615 321") return 50 end)
real("lobby_4096", function() drive("click 640 384") end, function()
  return storage.lobby.pending.world_size == 4096, "world " .. tostring(storage.lobby.pending.world_size)
end, function(player) select_dd(player, find(player.gui.screen.rts_lobby, "rts_lobby_size"), 3) end, 60)
step(function() drive("click 596 375") return 50 end)
real("lobby_survey", function() drive("click 620 417") end, function()
  return storage.lobby.pending.survey == true, "survey " .. tostring(storage.lobby.pending.survey)
end, function(player) select_dd(player, find(player.gui.screen.rts_lobby, "rts_lobby_survey"), 2) end, 60)
snap("j04-lobby-4096")
real("lobby_start_4096", function() drive("click 732 586") end, function()
  return not match.in_lobby(), "in lobby " .. tostring(match.in_lobby())
end, function(player) click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start")) end, 300)
snap("j05-world-progress")
step(function(player, P) return 1800 end)
snap("j06-world-progress-35s")
step(function(player, P)
  local f = player.gui.screen[worldgen.HUD_NAME]
  check("world_line", f ~= nil, "%s", f and f.line and serpent.line(f.line.caption) or "-")
  util.log("RTS_M3D_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(15, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.m3d_probe
  if not P then
    P = {i = 1, at = game.tick + 300}
    storage.m3d_probe = P
  end
  if P.done or game.tick < P.at then return end
  L = LAYOUT[player.locale] or LAYOUT.en
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("m3d probe step %d error: %s", idx, tostring(wait))
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    if P.i > #STEPS and wait then util.log("RTS_M3D_GUI_DONE player %d (steps ran out)", player.index) end
    return
  end
  P.at = game.tick + wait
end)
