-- 0.1.2 r3-ux GUI probe (test copy for tools/gui-run.sh): oil without pipes (#28), a new city's empty network (#26) and
-- the help cards (#30). Starts a Nation match (both AIs stopped), takes Age II, and photographs each new panel and card
-- (1280x800 take_screenshot with the GUI). Log lines "[rts] r3ux <check>: PASS|FAIL ..." and the stop marker RTS_R3UX_DONE.
-- Run (EN or RU), the screen must be free (see docs/qa/release-0-1-2-r3-ux-notes.md):
--   R=build/r3ux-en; rm -rf $R; mkdir -p $R; cp -R mods/factorio-rts mods/mod-list.json $R/
--   cp tools/probes/r3ux_gui.lua $R/factorio-rts/scripts/; printf '\nrequire("scripts.r3ux_gui")\n' >> $R/factorio-rts/control.lua
--   RTS_LOCALE=en tools/gui-run.sh $R 300 RTS_R3UX_DONE '\[rts\] r3ux|rror'
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local ai = require("scripts.ai.init")
local ages = require("scripts.ages")
local cities = require("scripts.cities")
local camera = require("scripts.camera")
local selection = require("scripts.selection")
local research = require("scripts.research")
local buildings = require("scripts.buildings")
local nw = require("scripts.netwait")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end
local function check(name, ok, fmt, ...)
  util.log("r3ux %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function shot(player, tag)
  game.take_screenshot({player = player, surface = match.view_surface(), position = player.position, zoom = player.zoom,
                        resolution = {1280, 800}, path = "r3ux-" .. tag .. ".png", show_gui = true,
                        show_entity_info = true, daytime = 0, force_render = true})
  util.log("r3ux: screenshot %s", tag)
end

local P = {} -- scene state
local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
local function snap(tag) step(function(player) shot(player, tag) end) end
local function place(surface, name, pos, force)
  local at = surface.find_non_colliding_position(name, pos, 30, 1, true) or pos
  return surface.create_entity({name = name, position = at, force = force, raise_built = true})
end

step(function(player) -- lobby: Nation
  local dd = find(player.gui.screen.rts_lobby, "rts_lobby_mode")
  if not dd then return "retry" end
  dd.selected_index = 2
  events.dispatch(defines.events.on_gui_selection_state_changed,
    {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
end)
step(function(player)
  lobby.on_click({element = find(player.gui.screen.rts_lobby, "rts_lobby_start"), player_index = player.index,
                  name = defines.events.on_gui_click})
  for _, af in ipairs(match.ai_forces()) do ai.stop_force(af) end
end)
step(function(player)
  local f = player.force.name
  local t = game.forces[f].technologies["rts-industrialisation"]
  if t then t.researched = true end
  research.apply(game.forces[f])
  ages.set_age(f, 2, "r3ux probe")
  P.f, P.surface = f, match.surface()
  P.cap = cities.get(storage.nations[f].capital)
  local c = P.cap.position
  P.surface.create_entity({name = "crude-oil", position = {x = c.x + 12, y = c.y + 10}, amount = 300000})
  P.surface.create_entity({name = "crude-oil", position = {x = c.x + 200, y = c.y + 10}, amount = 300000})
  P.pj = place(P.surface, "rts-pumpjack", {x = c.x + 12, y = c.y + 10}, f)
  P.pj_out = place(P.surface, "rts-pumpjack", {x = c.x + 200, y = c.y + 10}, f)
  P.ref = place(P.surface, "rts-refinery", {x = c.x - 14, y = c.y + 12}, f)
  P.chem = place(P.surface, "rts-chemical-plant", {x = c.x - 14, y = c.y + 24}, f)
  check("oil_placed", P.pj and P.pj_out and P.ref and P.chem, "pumpjack in %s, out %s, refinery %s, chem %s",
    tostring(P.pj ~= nil), tostring(P.pj_out ~= nil), tostring(P.ref ~= nil), tostring(P.chem ~= nil))
  return 300 -- let the oil flow and the alert fire
end)
local function show(entity_key, tag, zoom)
  step(function(player)
    local e = P[entity_key]
    if not (e and e.valid) then return end
    camera.jump_to(player, e.position)
    player.zoom = zoom or 1
    selection.select_building(player.index, e.unit_number)
    return 60
  end)
  snap(tag)
end
show("pj", "pumpjack-in")
show("pj_out", "pumpjack-out")
show("ref", "refinery")
show("chem", "chemical-plant")
step(function(player) -- R on the refinery: the flying text
  camera.jump_to(player, P.ref.position)
  local r = selection.rotate_at(player.index, P.ref.position, false)
  check("rotate_refinery", r == nil, "R on the refinery rotates nothing and shows the flying text")
  return 20
end)
snap("refinery-rotate-text")
step(function(player)
  local rec = buildings.get(P.pj.unit_number)
  local out = buildings.get(P.pj_out.unit_number)
  check("pump_states", rec and rec.pump_state == "pumping" and out and out.pump_state == "no network",
    "in-network pumpjack %s (%s items/min); outside %s", tostring(rec and rec.pump_state),
    tostring(rec and rec.pump_rate), tostring(out and out.pump_state))
end)
-- #26: a second city 300 tiles out: starter stock, a ghost that has no item in the network, the panel line and the alert
step(function(player)
  local c = P.cap.position
  local id = cities.found(P.f, {x = c.x + 300, y = c.y}, {})
  P.city = id and cities.get(id)
  check("city_founded", P.city ~= nil, "second city founded: %s", tostring(id))
  if not P.city then return end
  local p = P.city.position
  P.surface.create_entity({name = "entity-ghost", inner_name = "rts-lab", position = {x = p.x + 8, y = p.y + 8},
                           force = P.f})
  P.surface.create_entity({name = "entity-ghost", inner_name = "rts-house", position = {x = p.x - 8, y = p.y + 8},
                           force = P.f})
  return 600
end)
step(function(player)
  if not P.city then return end
  local line = nw.get(P.city.center)
  check("city_waiting", line ~= nil and line.n >= 1, "ghosts waiting in the new city: %s",
        line and tostring(line.n) or "none")
  local net = P.city.entity.logistic_network
  check("city_stock", net and net.get_item_count("rts-factory") >= 1 and net.get_item_count("iron-plate") >= 100,
        "starter stock: factory %s, iron %s", net and net.get_item_count("rts-factory") or "-",
        net and net.get_item_count("iron-plate") or "-")
  camera.jump_to(player, P.city.position)
  player.zoom = 0.6
  selection.select_building(player.index, P.city.center)
  return 90
end)
snap("city-waiting")
step(function(player)
  local hubgui_open = player.gui.screen.rts_hubgui_frame
  check("hub_panel", hubgui_open ~= nil, "hub panel open for the new city centre")
end)
step(function()
  log("RTS_R3UX_DONE")
  return "done"
end)

events.on_nth_tick(30, function(e)
  local player = game.connected_players[1]
  if not player then return end
  local st = storage.r3ux_probe
  if not st then
    st = {i = 1, wait = e.tick + 90}
    storage.r3ux_probe = st
  end
  if st.done or e.tick < st.wait then return end
  local fn = STEPS[st.i]
  if not fn then
    st.done = true
    return
  end
  local r = fn(player)
  if r == "retry" then
    st.wait = e.tick + 30
    return
  end
  if r == "done" then
    st.done = true
    return
  end
  st.i = st.i + 1
  st.wait = e.tick + (type(r) == "number" and r or 45)
end)
