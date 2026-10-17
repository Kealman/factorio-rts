-- Phase 5 M3 age3 GUI probe (test copy for tools/gui-run.sh; append require("scripts.age3_gui") to control.lua; the
-- copy is made by build/p5m3-age3/gui-copy.sh). Lobby: Mode Nation, Start. In the match both AIs stop; rts-player gets
-- Electrification, Chemistry and Geology, enters Age III through stage 1 of the Space Program (stage 2 partly
-- delivered), saltpetre and gold reach its capital, a Steel works is automated, a trade port near the capital is its.
-- Screenshots (1280x800): the ledger (Space Program row, Rush, rare line, automation buttons), the ledger while rushing,
-- the city panel with Hire, the market panel on a city-state and on the own port (Mercenaries row), the research panel
-- with its Rush button, the Launch complex. Clicks go through the real handlers (events.dispatch). Log lines "[rts] age3 gui
-- <check>: PASS|FAIL ..." and the stop marker RTS_AGE3_GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local logistics = require("scripts.logistics")
local research = require("scripts.research")
local ages = require("scripts.ages")
local cities = require("scripts.cities")
local treasury = require("scripts.treasury")
local market = require("scripts.market")
local marketgui = require("scripts.marketgui")
local ledgergui = require("scripts.ledgergui")
local citygui = require("scripts.citygui")
local techgui = require("scripts.techgui")
local production = require("scripts.production")
local garrison = require("scripts.garrison")
local age3 = require("scripts.age3")
local rare = require("scripts.rare")
local sinks = require("scripts.sinks")
local balance = require("balance")
local hud = require("scripts.hud")
local function require_hud() return hud end

local A3 = balance.nation.age3

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("age3 gui %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, path, position, zoom)
  game.take_screenshot({player = player, surface = match.view_surface(), position = position, zoom = zoom,
                        resolution = {1280, 800}, path = path, show_gui = true, show_entity_info = true,
                        daytime = 0, force_render = true})
  util.log("age3 gui: screenshot %s", path)
end

local function click(player, el)
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
                                                name = defines.events.on_gui_click, button = defines.mouse_button_type.left})
end

local function research_now(force, tech)
  local t = game.forces[force].technologies[tech]
  if t and not t.researched then t.researched = true end
  research.apply(game.forces[force])
end

events.on_nth_tick(30, function(e)
  local player = game.connected_players[1]
  if not player then return end
  local st = storage.age3_gui_probe
  if not st then
    st = {step = 1, tick = e.tick}
    storage.age3_gui_probe = st
  end
  if st.done or e.tick - st.tick < 90 then return end
  st.tick = e.tick
  -- a screenshot shows the end of its tick: it gets a tick of its own, after the step that set it up
  if st.shot then
    shot(player, st.shot.path, st.shot.position or player.position, st.shot.zoom or 1)
    st.shot = nil
    return
  end
  local f = player.force.name
  if st.step == 1 then
    local dd = find(player.gui.screen.rts_lobby, "rts_lobby_mode")
    if not dd then return end
    dd.selected_index = 2
    events.dispatch(defines.events.on_gui_selection_state_changed,
      {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
    st.step = 2
  elseif st.step == 2 then
    local start = find(player.gui.screen.rts_lobby, "rts_lobby_start")
    lobby.on_click({element = start, player_index = player.index, name = defines.events.on_gui_click})
    for _, af in ipairs(match.ai_forces()) do ai.stop_force(af) end
    st.step = 3
  elseif st.step == 3 then
    for _, tech in ipairs({"rts-industrialisation", "rts-geology"}) do research_now(f, tech) end
    ages.set_age(f, 2, "gui probe")
    for _, tech in ipairs({A3.tech, "rts-chemistry"}) do research_now(f, tech) end
    treasury.set_balance(f, 5000, "gui probe")
    ledgergui.open(player) -- before the start: "Start the Space Program"
    st.shot = {path = "age3-ledger-ready.png"}
    st.step = 4
  elseif st.step == 4 then
    local g = util.pstorage(player.index).ledger.gui
    click(player, g.start)
    local P = age3.project(f)
    check("start_button", P ~= nil and P.state == "building", "the ledger's Start placed the Launch complex: %s",
      P and P.state or "nil")
    age3.stage_done(f, 1)
    local net = rare.capital_network(f)
    net.insert({name = "battery", count = 30})
    net.insert({name = "engine-unit", count = 20})
    net.insert({name = "rts-rare-saltpetre", count = 3})
    net.insert({name = "rts-rare-gold", count = 3})
    net.insert({name = A3.kit.item, count = 2})
    local cap = cities.get(storage.nations[f].capital)
    local surface = match.surface()
    local pos = surface.find_non_colliding_position("rts-district-steel", {x = cap.position.x - 14,
      y = cap.position.y + 14}, 24, 1, true)
    local d = pos and surface.create_entity({name = "rts-district-steel", position = pos, force = f, raise_built = true})
    if d then production.set_recipe(d.unit_number, "rts-dst-steel") end
    st.city = cap.id
    -- a trade port next to the capital, ours
    local want = {x = cap.position.x, y = cap.position.y - 60}
    for _, en in pairs(surface.find_entities_filtered({position = want, radius = 25, type = {"tree", "simple-entity",
                                                                                              "cliff"}})) do en.destroy() end
    local at = surface.find_non_colliding_position(market.POST, want, 30, 1, true) or want
    local p = market.place_port(surface, at)
    st.port = p and p.un
    if st.port then market.set_owner(st.port, f) end
    storage.research.supply_bonus[f] = 200
    st.step = 5
  elseif st.step == 5 then
    local g = util.pstorage(player.index).ledger.gui
    ledgergui.refresh(player)
    local auto = g.a3_auto and g.a3_auto.metallurgy
    check("ledger_age3", g.a3_rush and g.a3_rush.valid and g.a3_rush.visible and auto and auto.valid and auto.enabled,
      "ledger in Age III: Rush %s, automation buttons %s", tostring(g.a3_rush and g.a3_rush.visible),
      tostring(auto and auto.enabled))
    if auto then click(player, auto) end
    st.step = 6
  elseif st.step == 6 then
    local info = age3.automation(st.city).metallurgy
    check("automate_button", info and info.on and info.kits == 2, "automation metallurgy: on %s, kits %s",
      tostring(info and info.on), tostring(info and info.kits))
    ledgergui.refresh(player)
    st.shot = {path = "age3-ledger.png"}
    st.step = 7
  elseif st.step == 7 then
    local g = util.pstorage(player.index).ledger.gui
    click(player, g.a3_rush)
    check("rush_button", sinks.rush_state(f) ~= nil, "the Rush button rushes: %s",
      tostring(sinks.rush_state(f) and sinks.rush_state(f).what))
    ledgergui.refresh(player)
    st.shot = {path = "age3-ledger-rush.png"}
    st.step = 8
  elseif st.step == 8 then
    ledgergui.close(player)
    citygui.open(player, st.city)
    st.step = 9
  elseif st.step == 9 then
    local g = util.pstorage(player.index).citygui
    local b = g and g.el and g.el.a3_hire
    if b and b.valid then click(player, b) end
    local hired = garrison.of(st.city).hired or 0
    check("hire_button", b ~= nil and hired == balance.nation.sinks.hire.step, "the Hire button hired %.1f points",
      hired)
    st.shot = {path = "age3-city.png"}
    st.step = 10
  elseif st.step == 10 then
    marketgui.open(player)
    local g = util.pstorage(player.index).market_gui.gui
    local ports = #(g.ports or {})
    local cs = g.partner_keys and g.partner_keys[1]
    if cs then
      g.port_dd.selected_index = ports + 1
      events.dispatch(defines.events.on_gui_selection_state_changed, {element = g.port_dd, player_index = player.index,
        name = defines.events.on_gui_selection_state_changed})
    end
    check("market_city_state", cs ~= nil and util.pstorage(player.index).market_gui.partner == cs,
      "the port drop-down lists %d port(s) and %d city-state(s); selected partner %s", ports,
      #(g.partner_keys or {}), tostring(util.pstorage(player.index).market_gui.partner))
    st.shot = {path = "age3-market-city-state.png"}
    st.step = 11
  elseif st.step == 11 then
    local ps = util.pstorage(player.index).market_gui
    local g = ps.gui
    local bought = false
    for _, c in ipairs(sinks.city_states(f)) do
      if c.city_id == ps.partner then
        for _, good in ipairs(c.goods) do
          local row = g.rows[good.item]
          if row and good.stock >= 10 and not bought then
            row.amount.text = "10"
            local r0 = sinks.relation(c.city_id, f)
            click(player, row.buy)
            bought = sinks.relation(c.city_id, f) > r0
          end
        end
      end
    end
    check("market_cs_buy", bought, "a Buy click at the city-state raised the relation")
    g.port_dd.selected_index = 1
    events.dispatch(defines.events.on_gui_selection_state_changed, {element = g.port_dd, player_index = player.index,
      name = defines.events.on_gui_selection_state_changed})
    marketgui.refresh(player)
    st.shot = {path = "age3-market-port.png"}
    st.step = 12
  elseif st.step == 12 then
    local g = util.pstorage(player.index).market_gui.gui
    if g.a3_merc and g.a3_merc.valid then click(player, g.a3_merc) end
    local s = storage.nations[f].sinks
    check("merc_button", s and (s.mercs or 0) == 1, "the Mercenaries button hired %d division(s)", s and s.mercs or 0)
    marketgui.close(player)
    research.queue(f, "rts-nuclear-power")
    techgui.open(player)
    st.step = 13
  elseif st.step == 13 then
    local g = util.pstorage(player.index).techgui
    techgui.refresh(player)
    if g and g.a3_rush and g.a3_rush.valid then click(player, g.a3_rush) end
    local rs = sinks.rush_state(f)
    check("rush_research", rs ~= nil and rs.kind == "research", "the research panel's Rush: %s",
      tostring(rs and rs.what))
    techgui.refresh(player)
    st.shot = {path = "age3-research-rush.png"}
    st.step = 14
  elseif st.step == 14 then
    techgui.close(player)
    local P = age3.project(f)
    st.shot = {path = "age3-launch-complex.png", position = P and P.position and {x = P.position.x,
      y = P.position.y + 1}}
    st.step = 15
  elseif st.step == 15 then
    require_hud().set_build_tab(player, "age2") -- the Age II / III build tab (three rows)
    st.shot = {path = "age3-build-tab.png"}
    st.step = 151
  elseif st.step == 151 then
    st.shot = {path = "age3-overview.png", zoom = 0.5}
    st.step = 16
  elseif st.step == 16 then
    st.done = true
    log("RTS_AGE3_GUI_DONE")
  end
end)
