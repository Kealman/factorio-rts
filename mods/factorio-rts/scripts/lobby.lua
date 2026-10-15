-- Match flow GUI and orchestration (docs/PHASE3.md "Match flow"): the start dialog (lobby), the in-match menu and
-- the results frame, all centred in player.gui.screen; starting, restarting and leaving matches.
--
--   lobby.start_match(config, who)   tear the old match down (if any), build the new one (match.start), start the AI
--                                    commanders, fog, cameras to the CCs, HUD rebuilt for the new arena
--   lobby.back_to_lobby(reason)      tear down, cameras to the lobby surface, the start dialog for everyone
--   lobby.restart_current(reason)    the same config again (/rts-qa-reset, Ctrl+Shift+R)
--   lobby.show_lobby / show_menu / toggle_menu / show_results (player)
-- Console: /rts-match <opponents> <difficulty> <size>. Input: rts-menu (F10) toggles the menu; the HUD has a Menu
-- button (hud.lua calls lobby.toggle_menu).
--
-- Owns storage.lobby = {pending = {opponents, difficulty, size}} (the dialog's choices, shared by every player)
-- and storage.players[i].results_closed = match_id whose results frame the player closed.
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local ai = require("scripts.ai.init")
local fog = require("scripts.fog")
local camera = require("scripts.camera")
local cursor = require("scripts.cursor")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local hud = require("scripts.hud")

local lobby = {}

local NAMES = {lobby = "rts_lobby", menu = "rts_menu", results = "rts_results"}
local PREFIX = "rts_lobby_"         -- every clickable element of this module: rts_lobby_<action>
local DIALOG_WIDTH = 420
local COLOR = {green = {0.5, 1, 0.5}, red = {1, 0.42, 0.36}, yellow = {1, 0.85, 0.3}, dim = {0.72, 0.72, 0.72}}

local function pending()
  local l = storage.lobby
  if not l then
    l = {}
    storage.lobby = l
  end
  if not l.pending then
    local c = storage.match and storage.match.config or match.DEFAULT_CONFIG
    l.pending = {opponents = c.opponents, difficulty = c.difficulty,
                 size = match.SIZES[c.size] and c.size ~= "legacy" and c.size or match.DEFAULT_CONFIG.size}
  end
  return l.pending
end

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
  return 1
end

local function size_caption(size)
  local s = match.SIZES[size]
  return {"rts.size-" .. size, 2 * s.half}
end

--- One-line description of a config: "2 opponents · Normal · Small (256×256)".
function lobby.config_text(c)
  return {"rts.config-line", c.opponents, {"rts.difficulty-" .. c.difficulty}, size_caption(c.size)}
end

local function can_control(player)
  return not game.is_multiplayer() or player.admin
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local function destroy(player, key)
  local f = player.gui.screen[NAMES[key]]
  if f then f.destroy() end
end

local function dialog(player, key, caption)
  destroy(player, key)
  local frame = player.gui.screen.add({type = "frame", name = NAMES[key], direction = "vertical", caption = caption})
  frame.style.width = DIALOG_WIDTH
  frame.auto_center = true
  local inner = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  inner.style.horizontally_stretchable = true
  return frame, inner
end

local function button_row(frame)
  local row = frame.add({type = "flow", direction = "horizontal", style = "dialog_buttons_horizontal_flow"})
  return row
end

local function filler(row, frame)
  local f = row.add({type = "empty-widget", style = "draggable_space"})
  f.style.horizontally_stretchable = true
  f.style.height = 32
  f.drag_target = frame
  return f
end

--- The start dialog: opponents, difficulty, map size, [Start match].
function lobby.show_lobby(player)
  destroy(player, "menu")
  destroy(player, "results")
  local p = pending()
  local frame, inner = dialog(player, "lobby", {"rts.lobby-title"})
  local grid = inner.add({type = "table", column_count = 2})
  grid.style.horizontal_spacing = 16
  grid.style.vertical_spacing = 8
  grid.add({type = "label", caption = {"rts.lobby-opponents"}, tooltip = {"rts.lobby-opponents-tooltip"}})
  local opp = {}
  for i = 1, match.MAX_OPPONENTS do opp[i] = tostring(i) end
  grid.add({type = "drop-down", name = PREFIX .. "opponents", items = opp, selected_index = p.opponents,
            tags = {rts_lobby = "opponents"}, tooltip = {"rts.lobby-opponents-tooltip"}})
  grid.add({type = "label", caption = {"rts.lobby-difficulty"}, tooltip = {"rts.lobby-difficulty-tooltip"}})
  local diffs = {}
  for i, d in ipairs(match.DIFFICULTIES) do diffs[i] = {"rts.difficulty-" .. d} end
  grid.add({type = "drop-down", name = PREFIX .. "difficulty", items = diffs,
            selected_index = index_of(match.DIFFICULTIES, p.difficulty), tags = {rts_lobby = "difficulty"},
            tooltip = {"rts.lobby-difficulty-tooltip"}})
  grid.add({type = "label", caption = {"rts.lobby-size"}})
  local sizes = {}
  for i, s in ipairs(match.SIZE_ORDER) do sizes[i] = size_caption(s) end
  grid.add({type = "drop-down", name = PREFIX .. "size", items = sizes, selected_index = index_of(match.SIZE_ORDER, p.size),
            tags = {rts_lobby = "size"}})
  local hint = inner.add({type = "label", caption = {"rts.lobby-hint"}})
  hint.style.single_line = false
  hint.style.maximal_width = DIALOG_WIDTH - 40
  hint.style.font_color = COLOR.dim
  hint.style.top_margin = 8
  local row = button_row(frame)
  filler(row, frame)
  local start = row.add({type = "button", name = PREFIX .. "start", style = "confirm_button",
                         caption = {"rts.lobby-start"}, tags = {rts_lobby = "start"}})
  start.enabled = can_control(player)
  util.log("lobby: dialog shown to player %d (%d opponent(s), %s, %s)", player.index, p.opponents, p.difficulty, p.size)
  return frame
end

--- The in-match menu: the match's settings and time, [Resume] [Restart].
function lobby.show_menu(player)
  local m = storage.match
  if match.in_lobby() then return lobby.show_lobby(player) end
  local frame, inner = dialog(player, "menu", {"rts.menu-title"})
  inner.add({type = "label", caption = lobby.config_text(m.config)})
  local secs = math.floor(match.elapsed_seconds())
  inner.add({type = "label", caption = {"rts.menu-time", string.format("%02d:%02d", math.floor(secs / 60), secs % 60)}})
  local row = button_row(frame)
  row.add({type = "button", name = PREFIX .. "menu_restart", style = "back_button", caption = {"rts.menu-restart"},
           tooltip = {"rts.menu-restart-tooltip"}, tags = {rts_lobby = "restart"}}).enabled = can_control(player)
  filler(row, frame)
  row.add({type = "button", name = PREFIX .. "menu_resume", style = "confirm_button", caption = {"rts.menu-resume"},
           tags = {rts_lobby = "resume"}})
  player.opened = frame
  util.log("lobby: menu opened by player %d", player.index)
  return frame
end

function lobby.toggle_menu(player)
  local f = player.gui.screen[NAMES.menu]
  if f then
    destroy(player, "menu")
    util.log("lobby: menu closed by player %d", player.index)
    return false
  end
  if player.gui.screen[NAMES.lobby] then return true end -- the start dialog is already up
  lobby.show_menu(player)
  return true
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

--- The results frame for the player's force: title, match time, counters per force, [Restart] [Continue].
function lobby.show_results(player)
  local m = storage.match
  local result = match.result(player.force.name)
  if not result then return nil end
  destroy(player, "menu")
  local frame, inner = dialog(player, "results", {"rts.results-title"})
  frame.style.width = 600
  local title = inner.add({type = "label", caption = {"rts.results-" .. result}})
  title.style.font = "default-large-bold"
  title.style.font_color = result == "victory" and COLOR.green or (result == "defeat" and COLOR.red or COLOR.yellow)
  local sub = inner.add({type = "label", caption = {"rts.match-" .. result}})
  sub.style.single_line = false
  sub.style.maximal_width = DIALOG_WIDTH - 40
  inner.add({type = "label", caption = {"rts.results-time", clock(match.elapsed_seconds())}})
  inner.add({type = "label", caption = lobby.config_text(m.config)}).style.font_color = COLOR.dim
  local t = inner.add({type = "table", column_count = 4, style = "bordered_table"})
  t.style.top_margin = 8
  t.style.horizontally_stretchable = true
  for _, key in ipairs({"results-force", "results-units", "results-buildings", "results-status"}) do
    local l = t.add({type = "label", caption = {"rts." .. key}})
    l.style.font = "default-bold"
    l.style.single_line = false
  end
  for _, f in ipairs(m.forces) do
    local s = match.stats(f)
    local name = f == match.PLAYER and {"rts.force-player"} or {"rts.force-ai-difficulty", tonumber(string.sub(f, #match.AI_PREFIX + 1)) or 0,
      {"rts.difficulty-" .. m.config.difficulty}}
    t.add({type = "label", caption = name})
    t.add({type = "label", caption = {"rts.results-pair", s.units_built, s.units_lost}})
    t.add({type = "label", caption = {"rts.results-pair", s.buildings_built, s.buildings_lost}})
    local status
    if m.out[f] then
      status = {"rts.results-out", clock((m.out[f] - m.tick_started) / 60)}
    elseif m.winner == f then
      status = {"rts.results-winner"}
    else
      status = {"rts.results-alive"}
    end
    t.add({type = "label", caption = status})
  end
  local row = button_row(frame)
  row.add({type = "button", name = PREFIX .. "results_restart", style = "back_button", caption = {"rts.menu-restart"},
           tooltip = {"rts.menu-restart-tooltip"}, tags = {rts_lobby = "restart"}}).enabled = can_control(player)
  filler(row, frame)
  row.add({type = "button", name = PREFIX .. "results_continue", style = "confirm_button",
           caption = {"rts.results-continue"}, tooltip = {"rts.results-continue-tooltip"},
           tags = {rts_lobby = "continue"}})
  player.opened = frame
  util.log("lobby: results shown to player %d: %s after %s", player.index, result, clock(match.elapsed_seconds()))
  return frame
end

local function close_all(player)
  for key in pairs(NAMES) do destroy(player, key) end
end

---------------------------------------------------------------------------
-- Orchestration
---------------------------------------------------------------------------
-- Selections, control groups, armed attack-moves and the cursor of every player: nothing may point into the
-- old match.
local function reset_players()
  orders.reset()
  for index in pairs(storage.players or {}) do selection.reset(index) end
end

local function players_to_view(home)
  for _, player in pairs(game.players) do
    match.assign_player(player)
    close_all(player)
    if player.connected then
      camera.jump_to(player, home(player))
      cursor.ensure(player, true, "match flow")
      hud.build(player)
    end
  end
end

--- Start a new match from `cfg` (anything match.normalize_config accepts). An existing match is torn down first and
--- its arena is deleted once the players look at the new one. `who` is for the log.
function lobby.start_match(cfg, who)
  local m = storage.match
  local old
  if m.surface then old = match.teardown("new match by " .. tostring(who)) end
  reset_players()
  local surface = match.start(cfg)
  local c = m.config
  if c.enemy_brain == "ai" then
    for _, f in ipairs(m.ai_forces) do ai.init_force(f, c.difficulty) end
  end
  fog.start()
  players_to_view(function(player) return match.home(player.force.name) end)
  if old then match.delete_arena(old) end
  pending().opponents, pending().difficulty = c.opponents, c.difficulty
  if c.size ~= "legacy" then pending().size = c.size end
  util.log("lobby: match %d started by %s on %s: %d opponent(s), %s, %s, brain %s", m.match_id, tostring(who),
    surface.name, c.opponents, c.difficulty, c.size, c.enemy_brain)
  return surface
end

--- Abandon the current match and show the start dialog to everyone.
function lobby.back_to_lobby(reason)
  local old = match.teardown(reason)
  reset_players()
  players_to_view(function() return {x = 0, y = 0} end)
  for _, player in pairs(game.connected_players) do lobby.show_lobby(player) end
  match.delete_arena(old)
  util.log("lobby: back in the lobby (%s)", tostring(reason))
end

--- The current match again, with the same config (QA reset).
function lobby.restart_current(who)
  local c = storage.match.config
  return lobby.start_match(c, who)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function on_click(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local action = el.tags and el.tags.rts_lobby
  local player = game.get_player(e.player_index)
  util.log("lobby click %s player=%d", tostring(action), player.index)
  if action == "start" then
    if not can_control(player) then return end
    local p = pending()
    lobby.start_match({opponents = p.opponents, difficulty = p.difficulty, size = p.size, enemy_brain = "ai"},
      "player " .. player.index)
  elseif action == "restart" then
    if not can_control(player) then return end
    lobby.back_to_lobby("restart by player " .. player.index)
  elseif action == "resume" then
    destroy(player, "menu")
  elseif action == "continue" then
    util.pstorage(player.index).results_closed = storage.match.match_id
    destroy(player, "results")
  end
end
lobby.on_click = on_click -- the GUI self-test clicks through this path

events.on(defines.events.on_gui_click, on_click)

events.on(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local p = pending()
  local what = el.tags and el.tags.rts_lobby
  if what == "opponents" then
    p.opponents = el.selected_index
  elseif what == "difficulty" then
    p.difficulty = match.DIFFICULTIES[el.selected_index] or p.difficulty
  elseif what == "size" then
    p.size = match.SIZE_ORDER[el.selected_index] or p.size
  else
    return
  end
  util.log("lobby: player %d set %s -> %d opponent(s), %s, %s", e.player_index, tostring(what), p.opponents,
    p.difficulty, p.size)
  -- every connected player sees the same choices
  for _, player in pairs(game.connected_players) do
    if player.index ~= e.player_index and player.gui.screen[NAMES.lobby] then lobby.show_lobby(player) end
  end
end)

-- Escape closes the menu (resume) and the results frame (continue); the start dialog stays.
events.on(defines.events.on_gui_closed, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local player = game.get_player(e.player_index)
  if el.name == NAMES.menu then
    destroy(player, "menu")
    util.log("lobby: menu closed by player %d (Escape)", player.index)
  elseif el.name == NAMES.results then
    util.pstorage(player.index).results_closed = storage.match.match_id
    destroy(player, "results")
    util.log("lobby: results closed by player %d (Escape)", player.index)
  end
end)

events.on("rts-menu", function(e)
  local player = game.get_player(e.player_index)
  util.log("lobby: rts-menu (F10) player=%d", player.index)
  lobby.toggle_menu(player)
end)

-- What a (re)joining player sees: the start dialog in the lobby, the results frame after a match.
local function greet(player)
  if not player.connected then return end
  if match.in_lobby() then
    lobby.show_lobby(player)
  elseif match.result(player.force.name) and util.pstorage(player.index).results_closed ~= storage.match.match_id then
    lobby.show_results(player)
  end
end

events.on(defines.events.on_player_created, function(e) greet(game.get_player(e.player_index)) end)
events.on(defines.events.on_player_joined_game, function(e) greet(game.get_player(e.player_index)) end)

match.on_ended(function()
  for _, player in pairs(game.connected_players) do
    if match.result(player.force.name) then lobby.show_results(player) end
  end
end)

match.on_force_out(function(force_name)
  game.print({"", "[RTS] ", {"rts.match-force-out", match.label(force_name)}})
end)

commands.add_command("rts-match", "<opponents 1-3> <easy|normal|hard> <small|medium> - start a new match",
  function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    if player and not player.admin then
      player.print("[rts] admins only")
      return
    end
    local args = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = string.lower(w) end
    local cfg = {opponents = tonumber(args[1] or ""), difficulty = args[2], size = args[3],
                 enemy_brain = args[4] == "waves" and "waves" or "ai"}
    local c = match.normalize_config(cfg)
    lobby.start_match(c, player and ("player " .. player.index) or "console")
    local line = string.format("[rts] rts-match: match %d, %d opponent(s), %s, %s", storage.match.match_id,
      c.opponents, c.difficulty, c.size)
    if player then player.print(line) else game.print(line) end
  end)

function lobby.init()
  pending()
  -- ai.init (on_configuration_changed) may have started a commander for rts-ai-1 by config; only the forces of a
  -- running match have commanders.
  local m = storage.match
  for name in pairs(storage.ai or {}) do
    local keep = m.phase == "running" and match.is_participant(name) and not (m.out and m.out[name])
    if not keep then ai.stop_force(name) end
  end
  for _, player in pairs(game.connected_players) do
    if match.in_lobby() and not player.gui.screen[NAMES.lobby] then lobby.show_lobby(player) end
  end
end

return lobby
