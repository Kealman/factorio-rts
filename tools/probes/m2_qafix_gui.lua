-- Phase 5 M2 QA round 1 (docs/qa/phase5-m2-integration-notes.md section 7): GUI check of the fixes for the Codex run's
-- failures, Nation match, with real mouse and keys where the engine's own input path matters (tools/gui-drive.sh runs
-- the "RTS_DRIVE <n> ..." lines this probe logs: clicks, Q, F, right clicks, window captures). Parts:
--   A  step 29: a lab ghost placed with a real click, real Q, a click on the protocol's empty ground (1000, 250); window
--      captures at 10, 30 and 60 s show no vanilla info box under the minimap
--   B  steps 20-21: two depots on one track under the CC (the QA geometry), a division across the platform track, the
--      depot panel (Deploy troop train enabled, the yellow reason line for the freight train), Deploy (the walkers step
--      off the track), a real right click on the other depot without kits ("No troop train" on the card, no boarding),
--      F and a real right click 4 tiles below the track (an attack-move: no boarding, no new division)
--   C  the AI's offers under the alert lines: the countdown ticks; a ceasefire offer goes when white peace ends the war
--   D  the city panel's name field shows the default name ("Capital", "Столица")
-- Run (RTS_LOCALE=en or ru):
--   rm -rf build/qfv && mkdir -p build/qfv && cp -R mods/factorio-rts mods/mod-list.json build/qfv/
--   cp tools/probes/m2_qafix_gui.lua build/qfv/factorio-rts/scripts/
--   printf '\nrequire("scripts.m2_qafix_gui")\n' >> build/qfv/factorio-rts/control.lua
--   tools/gui-drive.sh build/qfv-gui.log build/shots-qfv-window RTS_QF_DONE &
--   RTS_LOCALE=en tools/gui-run.sh build/qfv 600 RTS_QF_DONE
-- Log lines "[rts] qfv check <name>: PASS|FAIL ...", screenshots build/shots-qfv/qfv-*.png (take_screenshot) and
-- build/shots-qfv-window/*.png (window captures), stop marker RTS_QF_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local economy = require("scripts.economy")
local camera = require("scripts.camera")
local hud = require("scripts.hud")
local match = require("scripts.match")
local units = require("scripts.units")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local rails = require("scripts.rails")
local garrison = require("scripts.garrison")
local diplomacy = require("scripts.diplomacy")
local diplomacygui = require("scripts.diplomacygui")
local logistics = require("scripts.logistics")

local E = "rts-ai-1"

local function note(fmt, ...) util.log("qfv probe: " .. fmt, ...) end
local function check(name, ok, fmt, ...)
  util.log("qfv check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function drive(fmt, ...)
  storage.qf_seq = (storage.qf_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.qf_seq, ...)
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
local function px(player, pos)
  local z = player.zoom * 32
  return math.floor(640 + (pos.x - player.position.x) * z + 0.5), math.floor(400 + (pos.y - player.position.y) * z + 0.5)
end
local function shot(player, tag)
  game.take_screenshot({player = player, by_player = player, path = "qfv-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}, position = player.position, zoom = player.zoom})
end
local function clear_ground(center, rx, ry)
  for _, e in ipairs(match.surface().find_entities_filtered({area = {{center.x - rx, center.y - ry},
      {center.x + rx, center.y + ry}}, type = {"tree", "simple-entity", "cliff", "entity-ghost"}})) do
    if e.valid then e.destroy() end
  end
end
local function card_state(player, div)
  local panel = player.gui.screen.rts_div_panel
  local function walk(el)
    if not (el and el.valid) then return nil end
    if el.type == "label" and el.caption and type(el.caption) == "table" then
      local k = el.caption[1]
      if k == "rts-war.state-no-train" or k == "rts-war.state-embarking" or k == "rts-div.state-idle" then return k end
    end
    for _, c in pairs(el.children) do
      local f = walk(c)
      if f then return f end
    end
  end
  return walk(panel)
end

local function select_div(player, P)
  local list = {}
  for _, rec in ipairs(divisions.live_members(divisions.get(P.div))) do list[#list + 1] = rec.entity end
  selection.set(player.index, list)
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
local function capture(tag, wait, real)
  step(function(player, P)
    if real ~= false then drive("capture %s", tag) end
    shot(player, tag)
    return wait or 30
  end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
step(function(player, P)
  local dd = find(player.gui.screen.rts_lobby, "rts_lobby_mode")
  dd.selected_index = 2
  events.dispatch(defines.events.on_gui_selection_state_changed,
    {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
  return 30
end)
step(function(player, P)
  click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
  return 420
end)
step(function(player, P)
  ai.stop_force(E)
  P.F = player.force.name
  P.cc = buildings.main_cc(P.F).entity
  P.home = P.cc.position
  camera.jump_to(player, P.home)
  player.zoom = 0.5
  economy.give(P.F, "rts-lab", 2)
  -- the empty-ground point of protocol step 29: 22.5 tiles right of the CC and 9.4 up, game area (1000, 250)
  P.empty = {x = P.home.x + 22.5, y = P.home.y - 9.375}
  clear_ground(P.empty, 4, 4)
  drive("click 1000 250") -- focus the window on that empty ground
  return 60
end)

---------------------------------------------------------------------------
-- A: the info box (step 29)
---------------------------------------------------------------------------
capture("a-start", 30)
step(function(player, P)
  hud.set_build_tab(player, "production")
  hud.build_click(player, "rts-lab")
  P.t1 = {x = P.home.x + 12, y = P.home.y - 6}
  clear_ground(P.t1, 3, 3)
  local x, y = px(player, P.t1)
  drive("click %d %d", x, y)
  return 40
end)
capture("a-ghost", 20)
step(function(player, P)
  drive("key 12") -- Q
  return 30
end)
step(function(player, P)
  drive("click 1000 250") -- the mouse to empty ground (a click there selects nothing)
  return 120 -- the driver needs up to a second
end)
-- one more pulse with the mouse on the empty point: the log names what is under the mouse
step(function(player, P)
  camera.hover_pulse(player, "probe: mouse position check")
  return 570
end)
capture("a-10s", 1200)
capture("a-30s", 1800)
capture("a-60s", 30)
step(function(player, P)
  local labs = match.surface().count_entities_filtered({name = "rts-lab", position = P.t1, radius = 3})
  check("a_lab_built", labs == 1, "lab at the ghost's place: %d", labs)
  return 10
end)

---------------------------------------------------------------------------
-- D: the city panel's name field
---------------------------------------------------------------------------
step(function(player, P)
  selection.select_building(player.index, P.cc.unit_number)
  return 60
end)
capture("d-city", 30)
step(function(player, P)
  local f = find(player.gui.screen.rts_citygui_frame, "rts_citygui_name")
  -- "Capital" in English, "Столица" in Russian: the translated default name, not an empty field
  check("d_name_field", f ~= nil and f.text ~= "", "name field text %q", f and f.text or "-")
  selection.clear(player.index)
  return 15
end)

---------------------------------------------------------------------------
-- C: offers under the alert lines
---------------------------------------------------------------------------
local function offer_left(player)
  local fr = player.gui.screen.rts_diplo_offers
  local out = {}
  local function walk(el)
    if not (el and el.valid) then return end
    if el.type == "label" and type(el.caption) == "table" and el.caption[1] == "rts.diplomacy-offer-left" then
      out[#out + 1] = el.caption[2]
    end
    for _, c in pairs(el.children) do walk(c) end
  end
  walk(fr)
  return out
end
step(function(player, P)
  diplomacy.propose(P.F, E, "war", {})
  P.cf = diplomacy.propose(E, P.F, "ceasefire", {})
  note("war state %s, ceasefire proposal %s", tostring(diplomacy.state(P.F, E)), tostring(P.cf))
  diplomacygui.toggle(player)
  return 60
end)
capture("c-diplomacy-war", 30)
step(function(player, P)
  diplomacygui.close(player)
  return 30
end)
step(function(player, P)
  P.left0 = offer_left(player)
  note("offer countdown at t0: %s", serpent.line(P.left0))
  return 600
end)
capture("c-offer-10s", 30)
step(function(player, P)
  local l = offer_left(player)
  check("c_countdown", P.left0[1] and l[1] and P.left0[1] - l[1] >= 9 and P.left0[1] - l[1] <= 11 or false,
    "ceasefire offer countdown %s -> %s after 10 s", tostring(P.left0[1]), tostring(l[1]))
  P.peace = diplomacy.propose(E, P.F, "peace", {kind = "white"})
  return 60
end)
capture("c-two-offers", 30)
step(function(player, P)
  local ok = diplomacy.answer(P.peace, true)
  note("white peace accepted: %s", tostring(ok))
  return 150
end)
capture("c-after-peace", 30)
step(function(player, P)
  local cf = diplomacy.get_proposal(P.cf)
  check("c_moot_offer", cf and cf.status == "void" and player.gui.screen.rts_diplo_offers == nil or false,
    "ceasefire proposal %s after the peace; offers frame %s", cf and cf.status or "-",
    tostring(player.gui.screen.rts_diplo_offers ~= nil))
  return 15
end)

---------------------------------------------------------------------------
-- B: troop train in the QA geometry
---------------------------------------------------------------------------
step(function(player, P)
  game.forces[P.F].technologies["rts-railways"].researched = true
  for item, n in pairs({["rts-locomotive-kit"] = 4, ["rts-troop-wagon-kit"] = 2, ["rts-construction-wagon-kit"] = 1,
                        rail = 300, coal = 200}) do
    economy.give(P.F, item, n)
  end
  clear_ground({x = P.home.x, y = P.home.y + 8}, 46, 6)
  local s = match.surface()
  P.depA = s.create_entity({name = "rts-depot", position = {P.home.x - 22, P.home.y}, force = P.F, raise_built = true})
  P.depB = s.create_entity({name = "rts-depot", position = {P.home.x + 22, P.home.y}, force = P.F, raise_built = true})
  local dA, dB = rails.depot(P.depA.unit_number), rails.depot(P.depB.unit_number)
  note("depots: A track %s, B track %s", tostring(dA.platform and dA.platform.track),
    tostring(dB.platform and dB.platform.track))
  P.line = rails.plan_line(P.F, P.depA.unit_number, P.depB.unit_number)
  P.t = game.tick
  return 60
end)
step(function(player, P)
  local line = rails.lines[P.line]
  local crew = false -- the construction train drives back to its depot after the line opens: walkers on the track die
  for _, rec in pairs(storage.rails.trains) do
    if rec.kind == "construction" and rec.force == P.F then crew = true end
  end
  if not (line and line.state == "open" and not crew) and game.tick - P.t < 120 * 60 then
    P.i = P.i - 1 -- wait here
    return 60
  end
  check("b_line_open", line and line.state == "open" or false, "line %s state %s, wait %s", tostring(P.line),
    line and line.state or "-", line and tostring(line.wait) or "-")
  local list = {}
  for k = 1, 30 do
    local e = units.spawn("rts-walker", {x = P.home.x - 8 + ((k - 1) % 6) * 3, y = P.home.y + 16 + math.floor((k - 1) / 6) * 2},
      P.F, nil, match.surface())
    if e then list[#list + 1] = e end
  end
  P.div = divisions.create(P.F, list, {stance = "hold"}, {owner = "player"})
  local dA = rails.depot(P.depA.unit_number)
  local e = dA.platform.ends[line.a_end or 2]
  local dx = (e.d == defines.direction.east and -1) or (e.d == defines.direction.west and 1) or 0
  divisions.order(P.div, "move", {x = e.x + dx * 12, y = dA.platform.track}) -- across the track at the train's head
  return 20 * 60
end)
step(function(player, P)
  selection.select_building(player.index, P.depA.unit_number)
  return 60
end)
capture("b-panel-a", 30)
step(function(player, P)
  local b = find(player.gui.screen.rts_railgui_frame, "rts_railgui_deploy_troop")
  local f = find(player.gui.screen.rts_railgui_frame, "rts_railgui_deploy")
  check("b_buttons", b ~= nil and b.enabled and f ~= nil and not f.enabled, "troop %s, freight %s",
    tostring(b and b.enabled), tostring(f and f.enabled))
  click(player, b)
  return 60
end)
capture("b-deployed", 30)
step(function(player, P)
  local rec = garrison.troop_train_at(P.F, P.depA.unit_number)
  check("b_deploy", rec ~= nil, "troop train at depot A: %s", tostring(rec and rec.id))
  -- no kits left for depot B and no train routed there: embark refused
  local net = logistics.hub_network(P.depB.unit_number)
  for _, k in ipairs({"rts-locomotive-kit", "rts-troop-wagon-kit"}) do
    local n = net.get_item_count(k)
    if n > 0 then net.remove_item({name = k, count = n}) end
  end
  select_div(player, P)
  local dB = rails.depot(P.depB.unit_number)
  local x, y = px(player, {x = P.depB.position.x, y = dB.platform.track})
  P.divs_before = #divisions.for_force(P.F)
  drive("rclick %d %d", x, y)
  return 150
end)
capture("b-no-train", 30)
step(function(player, P)
  local D = divisions.get(P.div)
  local st = card_state(player, P.div)
  check("b_no_train", D and not D.embark and D.no_train ~= nil and st == "rts-war.state-no-train" or false,
    "embark %s, no_train %s, card %s", serpent.line(D and D.embark), serpent.line(D and D.no_train), tostring(st))
  selection.select_building(player.index, P.depB.unit_number)
  return 60
end)
capture("b-panel-b", 30)
step(function(player, P)
  select_div(player, P)
  -- F, then a right click 4 tiles below depot A's track (the QA's click at (479, 29))
  local dA = rails.depot(P.depA.unit_number)
  P.qa_click = {x = P.depA.position.x, y = dA.platform.track + 4}
  drive("key 3") -- F
  return 120
end)
step(function(player, P)
  note("attack-move armed: %s", tostring(orders.is_armed(player.index)))
  local x, y = px(player, P.qa_click)
  drive("rclick %d %d", x, y)
  return 150
end)
step(function(player, P)
  local D = divisions.get(P.div)
  check("b_armed_click", D and not D.embark and #divisions.for_force(P.F) == P.divs_before and not orders.is_armed(player.index) or false,
    "embark %s, divisions %d (before %d), still armed %s, order %s", serpent.line(D and D.embark),
    #divisions.for_force(P.F), P.divs_before, tostring(orders.is_armed(player.index)), D and D.order and D.order.kind or "-")
  return 30
end)
capture("b-armed-click", 30)
step(function(player, P)
  util.log("RTS_QF_DONE")
  return nil
end)

events.on_nth_tick(5, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.qfv_probe
  if not P then
    P = {i = 1, at = game.tick + 240}
    storage.qfv_probe = P
  end
  if P.done or game.tick < P.at then return end
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("qfv probe step %d error: %s", idx, tostring(wait))
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    return
  end
  P.at = game.tick + wait
end)
