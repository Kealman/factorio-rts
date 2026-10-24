-- 0.1.1 (r2-ux, issue #16): guided objectives, GUI probe with real clicks for the lobby switch, the strip's buttons and
-- the first selection (tools/gui-drive.sh runs the "RTS_DRIVE <n> ..." lines it logs); the other steps are done by
-- script the way the game does them (a building raised as built, a unit from a barracks, a research, a kill, a city
-- founded, the age, a war), and each is checked on the strip a moment later ("r2o check|real <name>: PASS|FAIL").
--   A  lobby (a fresh save: the first Skirmish): the switch is on (auto); two real clicks: off, on (pref true).
--   B  Skirmish: Start; the strip 0/7 between the match strip and the minimap; a box select ticks "select"; extractor,
--      barracks, a walker from it, a research, a hub, an enemy walker killed; 7/7 and the "done" text; the list button
--      (real click) shows the list; the × (real click) hides the strip.
--   C  F10, Restart (lobby); the switch back to auto (pref nil): Skirmish now off, Nation on; Nation in the lobby shows
--      the switch on; Start a 2048 Nation match: 0/7; the city panel, a farm and a bakery, a house, a town, an open
--      line (rails.lines_of answers one open line for the check), Age II, a war: 7/7.
--   D  F10, Restart, Skirmish, Start: the second Skirmish match has no strip (auto: off).
-- Test copy (self-test off), RTS_LOCALE=en or ru:
--   rm -rf build/r2o-en && mkdir -p build/r2o-en && cp -R mods/factorio-rts mods/mod-list.json build/r2o-en/
--   cp tools/probes/r2_objectives_gui.lua build/r2o-en/factorio-rts/scripts/
--   printf '\nrequire("scripts.r2_objectives_gui")\n' >> build/r2o-en/factorio-rts/control.lua
--   tools/gui-drive.sh build/r2o-en-gui.log build/shots-r2o-en-window RTS_R2O_DONE &
--   RTS_LOCALE=en tools/gui-run.sh build/r2o-en 900 RTS_R2O_DONE '\[rts\] r2o|objectives|rror'
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local selection = require("scripts.selection")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local economy = require("scripts.economy")
local objectives = require("scripts.objectives")
local cities = require("scripts.cities")
local ages = require("scripts.ages")
local rails = require("scripts.rails")
local diplomacy = require("scripts.diplomacy")

local E = "rts-ai-1"
local KEY = {F10 = 109}

local function note(fmt, ...) util.log("r2o probe: " .. fmt, ...) end
local function check(name, ok, fmt, ...)
  util.log("r2o check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function drive(fmt, ...)
  storage.r2o_seq = (storage.r2o_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.r2o_seq, ...)
end
local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end
local function click(player, el)
  if not (el and el.valid) then return false end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
  return true
end
local function toggle(player, el)
  if not (el and el.valid) then return false end
  el.state = not el.state
  events.dispatch(defines.events.on_gui_checked_state_changed, {element = el, player_index = player.index,
    name = defines.events.on_gui_checked_state_changed})
  return true
end
local function select_dd(player, dd, index)
  if not (dd and dd.valid) then return false end
  dd.selected_index = index
  events.dispatch(defines.events.on_gui_selection_state_changed,
    {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
  return true
end
local function shot(player, tag)
  game.take_screenshot({player = player, by_player = player, path = string.format("rts-r2o-%s.png", tag), show_gui = true,
                        force_render = true, resolution = {1280, 800}, position = player.position, zoom = player.zoom})
end
local function ps_of(player) return storage.objectives and storage.objectives.players[player.index] end
local function strip(player) return player.gui.screen[objectives.FRAME] end
local function done_n(player)
  local ps = ps_of(player)
  local n = 0
  for _ in pairs(ps and ps.done or {}) do n = n + 1 end
  return n
end
local function step_caption(player)
  local l = find(strip(player), "rts_objectives_step")
  return l and l.caption and l.caption[1] or "-"
end
local function lobby_switch(player) return find(player.gui.screen.rts_lobby, "rts_objectives_lobby") end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
local function snap(tag)
  step(function(player)
    shot(player, tag)
    return 15
  end)
end
local function capture(tag, wait)
  step(function()
    drive("capture r2o-%s", tag)
    return wait or 40
  end)
end
local function real(name, input, ok_fn, fallback, wait)
  step(function(player, P)
    input(player, P)
    return math.max(wait or 60, 60)
  end)
  step(function(player, P)
    local ok, detail = ok_fn(player, P)
    util.log("r2o real %s: %s %s", name, ok and "PASS" or "FAIL", tostring(detail or ""))
    if not ok and fallback then fallback(player, P) end
    return 30
  end)
end
-- A step of the strip done by script: `act` does it, then after `wait` ticks the step must be ticked
local function scripted(name, id, act, wait)
  step(function(player, P)
    act(player, P)
    return wait or 90
  end)
  step(function(player, P)
    local ps = ps_of(player)
    check("step_" .. name, ps and ps.done[id] == true, "%s: %d/7 done, strip says %s", id, done_n(player),
      step_caption(player))
    return 15
  end)
end
local function place(P, name, dx, dy, force)
  local s = match.surface()
  local pos = {x = P.home.x + dx, y = P.home.y + dy}
  pos = s.find_non_colliding_position(name, pos, 20, 1, true) or pos
  local e = s.create_entity({name = name, position = pos, force = force or P.F, raise_built = true})
  note("placed %s at %s: %s", name, util.pos_str(pos), tostring(e ~= nil))
  return e
end

---------------------------------------------------------------------------
-- A: the lobby switch
---------------------------------------------------------------------------
step(function()
  drive("click 640 720") -- the focus click
  drive("sleep 400")
  return 60
end)
capture("a01-lobby")
step(function(player, P)
  local sw = lobby_switch(player)
  local ps = ps_of(player)
  check("lobby_switch_auto_on", sw ~= nil and sw.state == true and (ps == nil or ps.pref == nil),
    "switch %s, state %s, pref %s", tostring(sw ~= nil), tostring(sw and sw.state), tostring(ps and ps.pref))
  return 15
end)
real("lobby_switch_off", function(player, P) drive("click %d %d", P.L.switch[1], P.L.switch[2]) end, function(player)
  local ps = ps_of(player)
  return ps and ps.pref == false, "pref " .. tostring(ps and ps.pref)
end, function(player) toggle(player, lobby_switch(player)) end)
real("lobby_switch_on", function(player, P) drive("click %d %d", P.L.switch[1], P.L.switch[2]) end, function(player)
  local ps = ps_of(player)
  return ps and ps.pref == true, "pref " .. tostring(ps and ps.pref)
end, function(player) toggle(player, lobby_switch(player)) end)
snap("a02-lobby-switch")

---------------------------------------------------------------------------
-- B: a Skirmish match with the strip
---------------------------------------------------------------------------
real("lobby_start", function(player, P) drive("click %d %d", P.L.start[1], P.L.start[2]) end, function(player)
  return not match.in_lobby(), "in lobby " .. tostring(match.in_lobby())
end, function(player) click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start")) end, 300)
step(function(player, P)
  P.F = player.force.name
  P.home = match.home(P.F)
  local f = strip(player)
  check("strip_shown", f ~= nil and done_n(player) == 0, "frame %s at %s, %d done, step %s", tostring(f ~= nil),
    f and serpent.line(f.location) or "-", done_n(player), step_caption(player))
  P.walkers = {}
  for _, rec in units.for_force(P.F) do if rec.kind == "walker" then P.walkers[#P.walkers + 1] = rec.entity end end
  camera.jump_to(player, util.centroid(P.walkers) or P.home)
  player.zoom = 0.5
  return 60
end)
snap("b01-strip")
capture("b01-strip")
real("select_ticks", function(player, P)
  local x1, y1, x2, y2 = 1280, 800, 0, 0
  local k = 32 * player.zoom
  for _, e in ipairs(P.walkers) do
    local x = 640 + (e.position.x - player.position.x) * k
    local y = 400 + (e.position.y - player.position.y) * k
    x1, y1, x2, y2 = math.min(x1, x), math.min(y1, y - 60), math.max(x2, x), math.max(y2, y)
  end
  drive("drag %d %d %d %d left", x1 - 40, y1 - 20, x2 + 40, y2 + 20)
end, function(player)
  local ps = ps_of(player)
  return ps and ps.done.select == true, string.format("%d selected, %d/7, strip %s", selection.count(player.index),
    done_n(player), step_caption(player))
end, function(player, P) selection.set(player.index, P.walkers) end, 150)
scripted("extractor", "extractor", function(player, P) place(P, "rts-extractor", -14, 10) end)
scripted("barracks", "barracks", function(player, P) P.barracks = place(P, "rts-barracks", 10, -10) end)
scripted("unit", "unit", function(player, P)
  economy.give(P.F, "iron-plate", 400)
  if P.barracks then production.set_recipe(P.barracks, "rts-walker-kit") end
end, 60 * 25)
scripted("research", "research", function(player, P)
  player.force.technologies["rts-supply-1"].researched = true
end)
scripted("hub", "hub", function(player, P) place(P, "rts-hub", 30, 20) end)
scripted("attack", "attack", function(player, P)
  local c = util.centroid(P.walkers) or P.home
  units.spawn("rts-walker", {x = c.x + 6, y = c.y}, E)
end, 60 * 15)
step(function(player, P)
  local ps = ps_of(player)
  check("all_done", ps and ps.finished ~= nil and step_caption(player) == "rts-objectives.skirmish-done",
    "%d/7, finished %s, strip %s", done_n(player), tostring(ps and ps.finished), step_caption(player))
  return 15
end)
snap("b02-done")
real("list_button", function(player, P) drive("click %d %d", P.L.list[1], P.L.list[2]) end, function(player)
  local ps = ps_of(player)
  return ps and ps.expanded == true and find(strip(player), "rts_objectives_steps") ~= nil, "expanded " ..
    tostring(ps and ps.expanded)
end, function(player) click(player, find(strip(player), "rts_objectives_list")) end)
snap("b03-list")
capture("b03-list")
real("close_button", function(player, P)
  drive("click %d %d", P.L.close[1], P.L.close[2])
  drive("move 640 700") -- no tooltip in the later shots
end, function(player)
  local ps = ps_of(player)
  return strip(player) == nil and ps and ps.on == false, "strip " .. tostring(strip(player) ~= nil)
end, function(player) click(player, find(strip(player), "rts_objectives_close")) end)

---------------------------------------------------------------------------
-- C: the lobby again (auto), a Nation match
---------------------------------------------------------------------------
step(function(player)
  lobby.toggle_menu(player)
  click(player, find(player.gui.screen, "rts_lobby_menu_restart"))
  return 60
end)
step(function(player, P)
  ps_of(player).pref = nil -- back to auto: Skirmish played once, Nation never
  local sk, na = objectives.wanted(player.index, "skirmish"), objectives.wanted(player.index, "nation")
  select_dd(player, find(player.gui.screen.rts_lobby, "rts_lobby_mode"), 2)
  local sw = lobby_switch(player)
  check("auto_after_first", sk == false and na == true and sw ~= nil and sw.state == true,
    "skirmish %s, nation %s, the Nation dialog's switch %s", tostring(sk), tostring(na), tostring(sw and sw.state))
  return 30
end)
capture("c01-lobby-nation")
step(function(player)
  click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
  return 600
end)
step(function(player, P)
  P.F = player.force.name
  P.home = match.home(P.F)
  P.cc = buildings.main_cc(P.F).entity
  camera.jump_to(player, P.home)
  player.zoom = 0.5
  check("nation_strip", strip(player) ~= nil and done_n(player) == 0 and ps_of(player).mode == "nation",
    "strip %s, %d done, mode %s, step %s", tostring(strip(player) ~= nil), done_n(player), tostring(ps_of(player).mode),
    step_caption(player))
  return 30
end)
snap("c02-nation-strip")
capture("c02-nation-strip")
scripted("city", "city", function(player, P) selection.select_building(player.index, P.cc.unit_number) end)
snap("c03-city-panel")
step(function(player) selection.clear(player.index) return 15 end)
scripted("food", "food", function(player, P)
  place(P, "rts-farm", -20, 18)
  place(P, "rts-bakery", -12, 18)
end)
scripted("house", "house", function(player, P) place(P, "rts-house", 14, 18) end)
scripted("town", "town", function(player, P)
  local id = cities.found(P.F, {x = P.home.x + 130, y = P.home.y}, {})
  note("town %s", tostring(id))
end)
-- an open rail line: rails.lines_of answers one for the check (laying a real line takes minutes)
scripted("rail", "rail", function(player, P)
  P.lines_of = rails.lines_of
  rails.lines_of = function(f) return f == P.F and {{id = 0, force = f, state = "open"}} or P.lines_of(f) end
end)
step(function(player, P)
  rails.lines_of = P.lines_of
  return 1
end)
scripted("age2", "age2", function(player, P) ages.set_age(P.F, 2, "r2o probe") end)
scripted("diplomacy", "diplomacy", function(player, P) diplomacy.set_state(P.F, E, "war", "r2o probe") end)
step(function(player, P)
  local ps = ps_of(player)
  check("nation_all_done", ps and ps.finished ~= nil and step_caption(player) == "rts-objectives.nation-done",
    "%d/7, strip %s", done_n(player), step_caption(player))
  if ps then ps.expanded = true end
  objectives.render(player)
  return 30
end)
snap("c04-nation-done-list")
capture("c04-nation-done-list")

---------------------------------------------------------------------------
-- D: the second Skirmish match: no strip
---------------------------------------------------------------------------
step(function(player)
  lobby.toggle_menu(player)
  click(player, find(player.gui.screen, "rts_lobby_menu_restart"))
  return 60
end)
step(function(player)
  select_dd(player, find(player.gui.screen.rts_lobby, "rts_lobby_mode"), 1)
  local sw = lobby_switch(player)
  check("second_skirmish_switch_off", sw ~= nil and sw.state == false, "switch %s", tostring(sw and sw.state))
  click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
  return 300
end)
step(function(player)
  local ps = ps_of(player)
  check("second_skirmish_no_strip", strip(player) == nil and ps.on == false and ps.played.skirmish == 2,
    "strip %s, on %s, played %s", tostring(strip(player) ~= nil), tostring(ps.on), serpent.line(ps.played))
  util.log("RTS_R2O_DONE player %d", player.index)
  return nil
end)

-- Coordinates per locale (game area of the 1280x800 window), measured from this probe's window captures
local LAYOUT = {
  en = {switch = {499, 513}, start = {740, 513}, list = {1056, 21}, close = {1078, 21}},
  ru = {switch = {499, 513}, start = {740, 513}, list = {1047, 21}, close = {1070, 21}},
}

events.on_nth_tick(15, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r2o_probe
  if not P then
    P = {i = 1, at = game.tick + 300}
    storage.r2o_probe = P
  end
  if P.done or game.tick < P.at then return end
  P.L = P.L or LAYOUT[player.locale] or LAYOUT.en
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("r2o probe step %d error: %s", idx, tostring(wait))
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    if P.i > #STEPS and wait then util.log("RTS_R2O_DONE player %d (steps ran out)", player.index) end
    return
  end
  P.at = game.tick + wait
end)
