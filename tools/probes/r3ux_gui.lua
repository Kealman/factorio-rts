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
local units = require("scripts.units")
local orders = require("scripts.orders")
local helpgui = require("scripts.helpgui")
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
  local capnet = P.cap.entity.logistic_network
  if capnet then -- the mother city can spare a factory, two houses and a farm (the settlers bring only what it holds)
    capnet.insert({name = "rts-factory", count = 1})
    capnet.insert({name = "rts-house", count = 2})
    capnet.insert({name = "rts-farm", count = 1})
  end
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
-- the build-menu tooltips with the one-line description: translated by the client and logged
local TIPS = {"rts-pumpjack", "rts-refinery", "rts-extractor", "rts-hub", "rts-depot", "transport-belt", "fast-inserter", "medium-electric-pole"}
events.on(defines.events.on_string_translated, function(e)
  local label = P.tip_ids and P.tip_ids[e.id]
  if not label then return end
  util.log("r3ux tooltip %s: %s %s", label, e.translated and "PASS" or "FAIL", string.gsub(tostring(e.result), "\n", " | "))
end)
step(function(player)
  P.tip_ids = {}
  for _, item in ipairs(TIPS) do
    local id = player.request_translation(hud.build_tooltip(item, 5, nil))
    if id then P.tip_ids[id] = item end
  end
  local diag = {["diag-desc"] = {"?", {"entity-description.transport-belt"}, {"item-description.transport-belt"}, ""},
                ["diag-name"] = prototypes.item["transport-belt"].localised_name,
                ["diag-instock"] = {"rts.in-stock", 5}}
  for label, ls in pairs(diag) do
    local id = player.request_translation(ls)
    if id then P.tip_ids[id] = label end
  end
  return 60
end)
-- #30: REAL input (tools/gui-drive.sh): Shift held over the refinery shows its card; Shift+click still adds to the
-- selection and Shift+right-click still gives an attack-move; the key fallback Shift+F11 shows the card at once.
local function drive(fmt, ...)
  P.seq = (P.seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, P.seq, ...)
  -- the client's stdout is block buffered when it goes to a file: padding makes the driver see the line now
  for _ = 1, 400 do log("RTS_PAD " .. string.rep("x", 100)) end
end
local function spx(player, pos)
  local k = 32 * player.zoom
  return math.floor(640 + (pos.x - player.position.x) * k + 0.5), math.floor(400 + (pos.y - player.position.y) * k + 0.5)
end
local function card_of(player)
  local g = util.pstorage(player.index).helpcard
  return g and g.frame and g.frame.valid and g.name or nil
end
step(function(player) -- Shift held over the refinery
  camera.jump_to(player, P.ref.position)
  player.zoom = 1
  selection.clear(player.index)
  return 90
end)
step(function(player)
  local x, y = spx(player, P.ref.position)
  drive("click %d %d", 1100, 300) -- a focus click on empty ground
  drive("move %d %d", x, y)
  drive("moddown shift")
  drive("sleep 700")
  -- the game takes the posted flagsChanged press when the release arrives (the hardware order is the same: press,
  -- hold, release): the card comes HOVER_DELAY ticks after the press event, unless a click follows
  drive("modup shift")
  drive("sleep 500")
  drive("capture help-hover-real")
  drive("click %d %d", 1100, 300)
  return 30
end)
step(function(player) -- wait (up to 200 s) for the driver: it runs a command every few hundred ms
  P.wait = (P.wait or 0) + 1
  if not P.hover_seen and P.wait < 400 then return "retry" end
  check("help_hover_real", P.hover_seen == true, "Shift over the refinery: hover card seen %s (after %d polls)",
    tostring(P.hover_seen), P.wait)
  return 240
end)
step(function(player) -- Shift+click adds to the selection, no card
  P.walkers = {}
  for _, rec in units.for_force(P.f) do
    if rec.kind == "walker" and rec.entity.valid then P.walkers[#P.walkers + 1] = rec.entity end
  end
  table.sort(P.walkers, function(a, b) return a.unit_number < b.unit_number end)
  if #P.walkers < 2 then check("shift_click", false, "fewer than two walkers") return end
  camera.jump_to(player, P.walkers[1].position)
  player.zoom = 1
  return 60
end)
step(function(player)
  if not P.walkers or #P.walkers < 2 then return end
  local function pt(e)
    local b = e.selection_box
    return spx(player, {x = (b.left_top.x + b.right_bottom.x) / 2, y = (b.left_top.y + b.right_bottom.y) / 2})
  end
  local x1, y1 = pt(P.walkers[1])
  local x2, y2 = pt(P.walkers[2])
  drive("click %d %d", x1, y1)
  drive("sleep 400")
  drive("click %d %d shift", x2, y2)
  drive("sleep 900")
  return 150
end)
step(function(player)
  if not P.walkers or #P.walkers < 2 then return end
  local n = #selection.get(player.index)
  check("shift_click", n >= 2 and card_of(player) == nil, "Shift+click selected %d units, card %s", n,
    tostring(card_of(player)))
  P.am = (orders.stats().issued or {}).attack_move or 0
  local x, y = spx(player, {x = player.position.x + 8, y = player.position.y + 8})
  drive("rclick %d %d shift", x, y)
  drive("sleep 600")
  return 120
end)
step(function(player)
  local now = (orders.stats().issued or {}).attack_move or 0
  check("shift_rclick", now > (P.am or 0), "Shift+right-click gave attack_move (%d -> %d), card %s", P.am or 0, now,
    tostring(card_of(player)))
end)
step(function(player) -- the fallback key
  selection.clear(player.index)
  camera.jump_to(player, P.ref.position)
  player.zoom = 1
  return 90
end)
step(function(player)
  local x, y = spx(player, P.ref.position)
  drive("move %d %d", x, y)
  drive("key 103 shift") -- Shift+F11 (macOS virtual key 103)
  drive("sleep 600")
  drive("capture help-key-real")
  return 100
end)
step(function(player)
  check("help_key_real", card_of(player) == "rts-refinery", "Shift+F11 over the refinery: card %s",
    tostring(card_of(player)))
  helpgui.close(player)
end)
-- the pinned card from the ? button of a building page, and the cards of a unit, a district, a City Center, a ghost
local function card_shot(name, tag)
  step(function(player)
    helpgui.open(player, name, "pinned")
    return 40
  end)
  snap(tag)
end
step(function(player)
  camera.jump_to(player, P.ref.position)
  selection.select_building(player.index, P.ref.unit_number)
  return 40
end)
card_shot("rts-refinery", "card-refinery")
card_shot("rts-pumpjack", "card-pumpjack")
card_shot("rts-extractor", "card-extractor")
card_shot("rts-city-center", "card-city-center")
card_shot("rts-walker", "card-walker")
card_shot("rts-district-steel", "card-district")
card_shot("rts-depot", "card-depot")
card_shot("rts-hub", "card-hub")
step(function()
  helpgui.close(game.connected_players[1])
  log("RTS_R3UX_DONE")
  return "done"
end)

events.on_nth_tick(3, function()
  local player = game.connected_players[1]
  if player and P.f and not P.hover_seen then
    local g = util.pstorage(player.index).helpcard
    if g and g.frame and g.frame.valid and g.name == "rts-refinery" and g.shown and not g.pinned then
      P.hover_seen = true
    end
  end
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
