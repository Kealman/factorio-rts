-- World GUI probe (test copy for tools/gui-run.sh, self-test off; append require("scripts.world_gui") to control.lua).
-- Lobby: switches Mode to Nation through the real drop-down handler (size and map must grey out), screenshot, then
-- Start through lobby.on_click. In the match: fog counts of rts-player (charted around the capital only: every chunk
-- within fog.NATION_START_RADIUS of it, none around the enemy capital), screenshots of the capital, of a pass and of a
-- ford (the probe charts those two spots for the shot), and of a region label in the chart. Log lines
-- "[rts] world gui ..." and the stop marker RTS_WORLD_GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local fog = require("scripts.fog")
local world = require("scripts.world")
local ai = require("scripts.ai.init")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("world gui %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, path, position, zoom, gui)
  game.take_screenshot({player = player, surface = match.view_surface(), position = position, zoom = zoom,
                        resolution = {1280, 800}, path = path, show_gui = gui or false, show_entity_info = true,
                        daytime = 0, force_render = true})
  util.log("world gui: screenshot %s at %s zoom %.2f", path, util.pos_str(position), zoom)
end

local function chunk_charted(force, surface, p)
  return force.is_chunk_charted(surface, {math.floor(p.x / 32), math.floor(p.y / 32)})
end

events.on_nth_tick(30, function(e)
  local player = game.connected_players[1]
  if not player then return end
  local st = storage.world_gui
  if not st then
    st = {step = 1, tick = e.tick}
    storage.world_gui = st
  end
  if st.done or e.tick - st.tick < 60 then return end
  st.tick = e.tick
  if st.step == 1 then
    local dd = find(player.gui.screen.rts_lobby, "rts_lobby_mode")
    if not dd then util.log("world gui: no mode drop-down yet") return end
    dd.selected_index = 2
    events.dispatch(defines.events.on_gui_selection_state_changed,
      {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
    local size = find(player.gui.screen.rts_lobby, "rts_lobby_size")
    local map = find(player.gui.screen.rts_lobby, "rts_lobby_map")
    check("lobby_nation", storage.lobby.pending.mode == "nation" and size and not size.enabled and map and not map.enabled,
      "pending mode %s, size enabled %s, map enabled %s", tostring(storage.lobby.pending.mode),
      tostring(size and size.enabled), tostring(map and map.enabled))
    st.step = 2
  elseif st.step == 2 then
    shot(player, "world-gui-lobby.png", player.position, 1, true)
    st.step = 3
  elseif st.step == 3 then
    local start = find(player.gui.screen.rts_lobby, "rts_lobby_start")
    lobby.on_click({element = start, player_index = player.index, name = defines.events.on_gui_click})
    local c = storage.match.config
    check("started_nation", c.mode == "nation" and storage.world and storage.world.surface == storage.match.surface,
      "config mode %s, world %s, %s", tostring(c.mode), tostring(c.world_size), lobby.config_text and "ok" or "")
    for _, f in ipairs(match.ai_forces()) do ai.stop_force(f) end -- a calm map for the screenshots
    st.step = 4
  elseif st.step == 4 then
    local surface = match.surface()
    local force = game.forces[match.PLAYER]
    local home = match.home(match.PLAYER)
    local enemy = match.home(match.ai_forces()[1])
    local charted, visible, total = fog.counts(match.PLAYER)
    local near_all, far_none = true, true
    for dx = -fog.NATION_START_RADIUS + 16, fog.NATION_START_RADIUS - 16, 32 do
      for dy = -fog.NATION_START_RADIUS + 16, fog.NATION_START_RADIUS - 16, 32 do
        if not chunk_charted(force, surface, {x = home.x + dx, y = home.y + dy}) then near_all = false end
      end
    end
    if chunk_charted(force, surface, enemy) then far_none = false end
    check("fog_capital", charted > 0 and near_all and far_none, "charted %d, visible %d of %d chunks; all chunks within %d of "
      .. "the capital charted: %s; enemy capital chunk uncharted: %s", charted, visible, total, fog.NATION_START_RADIUS,
      tostring(near_all), tostring(far_none))
    shot(player, "world-gui-capital.png", home, 0.35, true)
    st.step = 5
  elseif st.step == 5 then
    -- chart a pass and a ford for the shots
    local surface = match.surface()
    local force = game.forces[match.PLAYER]
    st.spots = {}
    for _, c in ipairs(world.chokes()) do
      if not st.spots[c.kind] then
        st.spots[c.kind] = c.position
        force.chart(surface, {{c.position.x - 96, c.position.y - 96}, {c.position.x + 96, c.position.y + 96}})
      end
    end
    st.step = 6
  elseif st.step == 6 then
    for kind, p in pairs(st.spots or {}) do shot(player, "world-gui-" .. kind .. ".png", p, 0.3, false) end
    local charted = fog.counts(match.PLAYER)
    util.log("world gui: after the spot charts %d chunks charted; fill %d/%d", charted, storage.world.fill.generated,
      storage.world.fill.total)
    st.step = 7
  elseif st.step == 7 then
    st.wait = st.wait or e.tick
    if not world.ready() and e.tick - st.wait < 150 * 60 then return end
    local charted = fog.counts(match.PLAYER)
    check("fog_stays_local", charted < 300, "%d chunks charted after the background fill (fill done: %s)", charted,
      tostring(world.ready()))
    util.log("RTS_WORLD_GUI_DONE")
    st.done = true
  end
end)
