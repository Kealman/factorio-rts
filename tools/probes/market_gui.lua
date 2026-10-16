-- Market GUI probe (test copy for tools/gui-run.sh; append require("scripts.market_gui") to control.lua).
-- Lobby: Mode Nation, Start. In the match: both AIs stop, a trade port 60 tiles from the capital is placed and given to
-- rts-player with steel and stone; screenshots of the HUD strip (treasury button), the market panel opened through the
-- M key's handler, a sale through the Sell button, the strip in deficit (red), and the port in the game view with its
-- label. Log lines "[rts] market gui ..." and the stop marker RTS_MARKET_GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local logistics = require("scripts.logistics")
local treasury = require("scripts.treasury")
local market = require("scripts.market")
local marketgui = require("scripts.marketgui")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("market gui %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, path, position, zoom)
  game.take_screenshot({player = player, surface = match.view_surface(), position = position, zoom = zoom,
                        resolution = {1280, 800}, path = path, show_gui = true, show_entity_info = true,
                        daytime = 0, force_render = true})
  util.log("market gui: screenshot %s", path)
end

events.on_nth_tick(30, function(e)
  local player = game.connected_players[1]
  if not player then return end
  local st = storage.market_gui_probe
  if not st then
    st = {step = 1, tick = e.tick}
    storage.market_gui_probe = st
  end
  if st.done or e.tick - st.tick < 90 then return end
  st.tick = e.tick
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
    for _, f in ipairs(match.ai_forces()) do ai.stop_force(f) end
    st.step = 3
  elseif st.step == 3 then
    local m = storage.match
    local surface = game.surfaces[m.surface]
    local cc = buildings.main_cc(player.force.name)
    local want = {x = cc.position.x, y = cc.position.y - 60}
    for _, en in pairs(surface.find_entities_filtered({position = want, radius = 25, type = {"tree", "simple-entity",
                                                                                              "cliff"}})) do en.destroy() end
    local at = surface.find_non_colliding_position(market.POST, want, 30, 1, true) or want
    local p = market.place_port(surface, at)
    st.port = p and p.un
    market.set_owner(st.port, player.force.name)
    local pol = logistics.policy(st.port)
    for _, s in ipairs(pol.parts.stockpiles) do
      s.insert({name = "steel-plate", count = 300})
      s.insert({name = "stone", count = 300})
    end
    st.port_pos = p.position
    st.step = 4
  elseif st.step == 4 then
    shot(player, "market-gui-strip.png", player.position, 1)
    events.dispatch("rts-market", {player_index = player.index, input_name = "rts-market", name = "rts-market"})
    local frame = player.gui.screen[marketgui.FRAME]
    check("open_by_key", frame ~= nil and frame.valid, "market frame %s", tostring(frame and frame.valid))
    st.step = 5
  elseif st.step == 5 then
    shot(player, "market-gui-panel.png", player.position, 1)
    local g = util.pstorage(player.index).market_gui.gui
    local row = g and g.rows["steel-plate"]
    local bal = treasury.balance(player.force.name)
    if row then
      row.amount.text = "200"
      events.dispatch(defines.events.on_gui_click, {element = row.sell, player_index = player.index,
                                                    name = defines.events.on_gui_click, button = defines.mouse_button_type.left})
    end
    local after = treasury.balance(player.force.name)
    check("sell_button", row ~= nil and after > bal, "balance %.1f -> %.1f after Sell 200 steel", bal, after)
    st.step = 6
  elseif st.step == 6 then
    shot(player, "market-gui-sold.png", player.position, 1)
    marketgui.close(player)
    treasury.set_balance(player.force.name, -150, "gui probe")
    st.step = 7
  elseif st.step == 7 then
    local h = util.pstorage(player.index).hud
    local b = h and h.el and h.el.treasury
    check("strip_red", b ~= nil and b.valid and b.visible, "treasury button visible %s caption %s",
      tostring(b and b.visible), b and serpent.line(b.caption) or "-")
    shot(player, "market-gui-deficit.png", player.position, 1)
    st.step = 8
  elseif st.step == 8 then
    shot(player, "market-gui-port.png", {x = st.port_pos.x, y = st.port_pos.y + 2}, 1)
    st.done = true
    log("RTS_MARKET_GUI_DONE")
  end
end)
