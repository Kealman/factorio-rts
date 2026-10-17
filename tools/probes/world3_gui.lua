-- Phase 5 M3 world3 GUI probe (test copy for tools/gui-run.sh, self-test off; EXTRA_LUA-style: append
-- require("scripts.world3_gui") to the copy's control.lua). Lobby: Mode -> Nation through the real drop-down handler;
-- the nation drop-down offers 2-6; 6 nations move the default size to 3072; 4096 is picked, Survey is picked, the
-- generation line names 4096; Start through lobby.on_click. In the match: the HUD progress line under the minimap
-- ("World: N % generated"), its share growing; the survey charted the generated chunks (on_chunk_charted counts).
-- Screenshots world3-gui-lobby.png, world3-gui-start.png, world3-gui-later.png. Log lines "[rts] world3 gui <check>:
-- PASS|FAIL ..." and the stop marker RTS_WORLD3_GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local world = require("scripts.world")
local worldgen = require("scripts.worldgen")
local fog = require("scripts.fog")

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function check(name, ok, fmt, ...)
  util.log("world3 gui %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, path)
  game.take_screenshot({player = player, surface = match.view_surface(), position = player.position, zoom = 0.35,
                        resolution = {1280, 800}, path = path, show_gui = true, show_entity_info = true, daytime = 0,
                        force_render = true})
  util.log("world3 gui: screenshot %s", path)
end

local function select(player, name, index)
  local dd = find(player.gui.screen.rts_lobby, name)
  if not dd then return nil end
  dd.selected_index = index
  events.dispatch(defines.events.on_gui_selection_state_changed,
    {element = dd, player_index = player.index, name = defines.events.on_gui_selection_state_changed})
  return dd
end

events.on_nth_tick(30, function(e)
  local player = game.connected_players[1]
  if not player then return end
  local st = storage.world3_gui
  if not st then
    st = {step = 1, tick = e.tick}
    storage.world3_gui = st
  end
  if st.done or e.tick - st.tick < 60 then return end
  st.tick = e.tick
  if st.step == 1 then
    if not select(player, "rts_lobby_mode", 2) then util.log("world3 gui: no mode drop-down yet") return end
    local opp = find(player.gui.screen.rts_lobby, "rts_lobby_opponents")
    check("nations_dropdown", opp and #opp.items == match.MAX_NATIONS - 1, "nation drop-down items %s",
      opp and serpent.line(opp.items) or "-")
    st.step = 2
  elseif st.step == 2 then
    select(player, "rts_lobby_opponents", 5) -- 6 nations
    local size = find(player.gui.screen.rts_lobby, "rts_lobby_size")
    check("six_nations_size", storage.lobby.pending.opponents == 5 and size
      and world.SIZES[size.selected_index] == 3072, "opponents %s, size drop-down on %s", tostring(storage.lobby.pending.opponents),
      tostring(size and world.SIZES[size.selected_index]))
    st.step = 3
  elseif st.step == 3 then
    select(player, "rts_lobby_size", 3) -- 4096
    select(player, "rts_lobby_survey", 2)
    local gen = find(player.gui.screen.rts_lobby, "rts_lobby_generation")
    check("lobby_4096", storage.lobby.pending.world_size == 4096 and storage.lobby.pending.survey == true and gen ~= nil
      and tostring(gen.caption[2]) == "4096", "pending world %s, survey %s, generation line %s", tostring(storage.lobby.pending.world_size),
      tostring(storage.lobby.pending.survey), gen and serpent.line(gen.caption) or "-")
    shot(player, "world3-gui-lobby.png")
    st.step = 4
  elseif st.step == 4 then
    local start = find(player.gui.screen.rts_lobby, "rts_lobby_start")
    lobby.on_click({element = start, player_index = player.index, name = defines.events.on_gui_click})
    local c = storage.match.config
    check("started_4096", c.mode == "nation" and c.world_size == 4096 and c.nations == 6 and c.survey == true,
      "config mode %s, world %s, nations %s, survey %s", tostring(c.mode), tostring(c.world_size), tostring(c.nations),
      tostring(c.survey))
    st.step, st.started = 5, e.tick
  elseif st.step == 5 then
    if e.tick - st.started < 300 then return end
    local f = player.gui.screen[worldgen.HUD_NAME]
    st.share0 = worldgen.progress().share
    check("hud_line", f ~= nil and f.visible and f.line ~= nil, "progress frame %s, caption %s", tostring(f ~= nil),
      f and serpent.line(f.line.caption) or "-")
    shot(player, "world3-gui-start.png")
    st.step = 6
  elseif st.step == 6 then
    if e.tick - st.started < 60 * 60 then return end
    local p = worldgen.progress()
    local f = player.gui.screen[worldgen.HUD_NAME]
    local charted = fog.counts(match.PLAYER)
    local counted = worldgen.charted(match.PLAYER)
    check("hud_grows", f ~= nil and p.share > st.share0, "share %.3f -> %.3f, caption %s", st.share0, p.share,
      f and serpent.line(f.line.caption) or "-")
    check("survey_charted", charted >= p.core and counted > 0, "rts-player charted %d chunks (on_chunk_charted counted %d), "
      .. "%d generated", charted, counted, p.generated)
    shot(player, "world3-gui-later.png")
    util.log("RTS_WORLD3_GUI_DONE")
    st.done = true
  end
end)
