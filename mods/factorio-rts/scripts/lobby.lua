-- Match flow GUI and orchestration (docs/PHASE3.md "Match flow"): the start dialog (lobby), the in-match menu and
-- the results frame, all centred in player.gui.screen; starting, restarting and leaving matches.
--
--   lobby.start_match(config, who)   tear the old match down (if any), build the new one (match.start), start the AI
--                                    commanders, fog, cameras to the CCs, HUD rebuilt for the new arena
--   lobby.back_to_lobby(reason)      tear down, cameras to the lobby surface, the start dialog for everyone
--   lobby.restart_current(reason)    the same config again (/rts-qa-reset, Ctrl+Shift+R)
--   lobby.show_lobby / show_menu / toggle_menu / show_results (player)
-- The menu has Concede (two clicks; match.concede: the human side is out, defeat) while the match runs and Results
-- (the results window again) after it ended.
-- Console: /rts-match <opponents> <difficulty> <size> [chokes|open] [waves]. Input: rts-menu (F10) toggles the menu;
-- the HUD has a Menu button (hud.lua calls lobby.toggle_menu).
--
-- Owns storage.lobby = {pending = {opponents, difficulty, size, map}} (the dialog's choices, shared by every player)
-- and storage.players[i].results_closed = match_id whose results frame the player closed, .concede_armed = tick of
-- the first Concede click.
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
local mapgen = require("scripts.mapgen")
local world = require("scripts.world") -- Phase 5 M1: Nation mode (world sizes)
local balance = require("balance") -- Phase 5 M2 diplomacy: victory modes and time limits (D6)
local VICTORY = balance.nation.diplomacy.victory -- Phase 5 M2 diplomacy

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
  if not l.pending.map then l.pending.map = match.DEFAULT_CONFIG.map end -- saves from before the Map choice
  if not l.pending.mode then l.pending.mode = "skirmish" end -- Phase 5 M1: saves from before the Mode choice
  if not l.pending.victory then l.pending.victory = VICTORY.default_mode end -- Phase 5 M2 diplomacy (D6)
  if not l.pending.time_limit then l.pending.time_limit = VICTORY.default_time_limit end
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

--- One-line description of a config: "2 opponents · Normal · Small (256×256) · Chokepoints"; a Nation match:
--- "Nation · 3 nations · Normal · World 2048×2048".
function lobby.config_text(c)
  if c.mode == "nation" then
    local line = {"rts.config-line-nation", c.opponents + 1, {"rts.difficulty-" .. c.difficulty}, c.world_size or 0}
    if c.victory then -- Phase 5 M2 diplomacy: "... · Territory · 90 min"
      return {"", line, " · ", {"rts.victory-" .. c.victory}, " · ", (c.time_limit or 0) > 0
        and {"rts.time-limit-minutes", c.time_limit} or {"rts.time-limit-none"}}
    end
    return line
  end
  return {"", {"rts.config-line", c.opponents, {"rts.difficulty-" .. c.difficulty}, size_caption(c.size)}, " · ",
          {"rts.map-" .. (c.map or match.DEFAULT_CONFIG.map)}}
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

-- 0.1.1 (issue #16): fn(player, row, pending) adds a control at the left of the start dialog's button row (the guided
-- objectives switch of scripts/objectives.lua), so the dialog keeps its size and the protocol coordinates hold. Load
-- time only.
lobby.dialog_hooks = {}
function lobby.on_dialog(fn) lobby.dialog_hooks[#lobby.dialog_hooks + 1] = fn end

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
  -- Phase 5 M1: Mode. Nation fixes the map type (World, greyed); its size is a World size (world.SIZES), by default
  -- world.size_for(nations) until the player picks one (pending.world_size, nil = the default).
  local nation = p.mode == "nation"
  -- Phase 5 M3 world3: the mode and size tooltips name the M3 world sizes (rts-world3 keys)
  grid.add({type = "label", caption = {"rts.lobby-mode"}, tooltip = {"rts-world3.lobby-mode-tooltip"}})
  grid.add({type = "drop-down", name = PREFIX .. "mode", items = {{"rts.mode-skirmish"}, {"rts.mode-nation"}},
            selected_index = nation and 2 or 1, tags = {rts_lobby = "mode"}, tooltip = {"rts-world3.lobby-mode-tooltip"}})
  -- Phase 5 M3 world3: in Nation mode the same drop-down counts nations, 2-6 (item i = i opponents)
  local opp = {}
  if nation then
    grid.add({type = "label", caption = {"rts-world3.lobby-nations"}, tooltip = {"rts-world3.lobby-nations-tooltip"}})
    for i = 1, match.MAX_NATIONS - 1 do opp[i] = tostring(i + 1) end
  else
    grid.add({type = "label", caption = {"rts.lobby-opponents"}, tooltip = {"rts.lobby-opponents-tooltip"}})
    for i = 1, match.MAX_OPPONENTS do opp[i] = tostring(i) end
  end
  grid.add({type = "drop-down", name = PREFIX .. "opponents", items = opp, selected_index = math.min(p.opponents, #opp),
            tags = {rts_lobby = "opponents"},
            tooltip = nation and {"rts-world3.lobby-nations-tooltip"} or {"rts.lobby-opponents-tooltip"}})
  grid.add({type = "label", caption = {"rts.lobby-difficulty"}, tooltip = {"rts.lobby-difficulty-tooltip"}})
  local diffs = {}
  for i, d in ipairs(match.DIFFICULTIES) do diffs[i] = {"rts.difficulty-" .. d} end
  grid.add({type = "drop-down", name = PREFIX .. "difficulty", items = diffs,
            selected_index = index_of(match.DIFFICULTIES, p.difficulty), tags = {rts_lobby = "difficulty"},
            tooltip = {"rts.lobby-difficulty-tooltip"}})
  grid.add({type = "label", caption = {"rts.lobby-size"}})
  local sizes = {}
  for i, s in ipairs(match.SIZE_ORDER) do sizes[i] = size_caption(s) end
  if nation then
    sizes = {}
    for i, ws in ipairs(world.SIZES) do sizes[i] = {"rts.size-world", ws} end
    grid.add({type = "drop-down", name = PREFIX .. "size", items = sizes,
              selected_index = index_of(world.SIZES, p.world_size or world.size_for(p.opponents + 1)),
              tags = {rts_lobby = "world_size"}, tooltip = {"rts-world3.lobby-size-tooltip"}})
  else
    grid.add({type = "drop-down", name = PREFIX .. "size", items = sizes,
              selected_index = index_of(match.SIZE_ORDER, p.size), tags = {rts_lobby = "size"}})
  end
  grid.add({type = "label", caption = {"rts.lobby-map"}, tooltip = {"rts.lobby-map-tooltip"}})
  local maps = {}
  for i, name in ipairs(match.MAPS) do maps[i] = {"rts.map-" .. name} end
  if nation then maps = {{"rts.map-world"}} end
  grid.add({type = "drop-down", name = PREFIX .. "map", items = maps,
            selected_index = nation and 1 or index_of(match.MAPS, p.map), tags = {rts_lobby = "map"},
            tooltip = nation and {"rts.lobby-map-nation-tooltip"} or {"rts.lobby-map-tooltip"}}).enabled = not nation
  if nation then -- Phase 5 M3 world3: Map knowledge (Explore: fog as before; Survey: the generated world charted)
    grid.add({type = "label", caption = {"rts-world3.lobby-survey"}, tooltip = {"rts-world3.lobby-survey-tooltip"}})
    grid.add({type = "drop-down", name = PREFIX .. "survey", items = {{"rts-world3.survey-explore"},
              {"rts-world3.survey-survey"}}, selected_index = p.survey and 2 or 1, tags = {rts_lobby = "survey"},
              tooltip = {"rts-world3.lobby-survey-tooltip"}})
  end
  if nation then -- Phase 5 M2 diplomacy (D6): Victory and Time limit, Nation mode only
    grid.add({type = "label", caption = {"rts.lobby-victory"}, tooltip = {"rts.lobby-victory-tooltip"}})
    local vitems = {}
    for i, v in ipairs(VICTORY.modes) do vitems[i] = {"rts.victory-" .. v} end
    grid.add({type = "drop-down", name = PREFIX .. "victory", items = vitems,
              selected_index = index_of(VICTORY.modes, p.victory), tags = {rts_lobby = "victory"},
              tooltip = {"rts.lobby-victory-tooltip"}})
    grid.add({type = "label", caption = {"rts.lobby-time-limit"}, tooltip = {"rts.lobby-time-limit-tooltip"}})
    local titems = {}
    for i, t in ipairs(VICTORY.time_limits) do
      titems[i] = t > 0 and {"rts.time-limit-minutes", t} or {"rts.time-limit-none"}
    end
    grid.add({type = "drop-down", name = PREFIX .. "time_limit", items = titems,
              selected_index = index_of(VICTORY.time_limits, p.time_limit or 0), tags = {rts_lobby = "time_limit"},
              tooltip = {"rts.lobby-time-limit-tooltip"}})
  end
  if nation then -- Phase 5 M3 world3: how the world is generated (the core at the start, the rest in the background)
    local ws = p.world_size or world.size_for(p.opponents + 1)
    local chunks = (ws / 32) ^ 2
    -- minutes at the measured background rate: 66-67 chunks per second at 60 UPS on 2.1.23 (42-45 on 2.0; r2-platform,
    -- issue #13), rounded with 64 so the line stays a slight overestimate under load
    local gen = inner.add({type = "label", name = PREFIX .. "generation",
                           caption = {"rts-world3.lobby-generation", ws, chunks, math.ceil(chunks / 64 / 60)}})
    gen.style.single_line = false
    gen.style.maximal_width = DIALOG_WIDTH - 40
    gen.style.font_color = COLOR.dim
    gen.style.top_margin = 8
  end
  -- Phase 5 M2 integration: the Nation hint (peace at the start, out without a city, the Victory rule)
  local hint = inner.add({type = "label", caption = {nation and "rts.lobby-hint-nation" or "rts.lobby-hint"}})
  hint.style.single_line = false
  hint.style.maximal_width = DIALOG_WIDTH - 40
  hint.style.font_color = COLOR.dim
  hint.style.top_margin = 8
  local row = button_row(frame)
  for _, fn in ipairs(lobby.dialog_hooks) do fn(player, row, p) end -- 0.1.1 (issue #16)
  filler(row, frame)
  local start = row.add({type = "button", name = PREFIX .. "start", style = "confirm_button",
                         caption = {"rts.lobby-start"}, tags = {rts_lobby = "start"}})
  start.enabled = can_control(player)
  if p.mode == "nation" then -- Phase 5 M1 integration: the Nation line names the world, not the Skirmish size and map
    util.log("lobby: dialog shown to player %d (%d opponent(s), %s, nation, world %s, victory %s, time limit %s)",
      player.index, p.opponents, p.difficulty, tostring(p.world_size or "default"), tostring(p.victory),
      tostring(p.time_limit)) -- Phase 5 M2 diplomacy: victory and time limit
  else
    util.log("lobby: dialog shown to player %d (%d opponent(s), %s, %s, %s, %s)", player.index, p.opponents,
      p.difficulty, p.size, p.map, p.mode)
  end
  return frame
end

-- Concede asks twice: the first click arms the button for this long, the second gives up.
local CONCEDE_CONFIRM_TICKS = 5 * 60

local function concede_armed(player)
  local t = util.pstorage(player.index).concede_armed
  return t ~= nil and game.tick - t < CONCEDE_CONFIRM_TICKS
end

--- The in-match menu: the match's settings and time, [Restart] [Concede | Results] [Resume]. Concede while the match
--- runs (the human side only; two clicks), Results once it ended (the results window again after Continue).
function lobby.show_menu(player)
  local m = storage.match
  if match.in_lobby() then return lobby.show_lobby(player) end
  local frame, inner = dialog(player, "menu", {"rts.menu-title"})
  -- Phase 5 M3 integration: the Nation line ("... · Conquest + Space · unlimited") is wider than the dialog: wrap it
  local cfg = inner.add({type = "label", caption = lobby.config_text(m.config)})
  cfg.style.single_line = false
  cfg.style.maximal_width = DIALOG_WIDTH - 40
  local secs = math.floor(match.elapsed_seconds())
  inner.add({type = "label", caption = {"rts.menu-time", string.format("%02d:%02d", math.floor(secs / 60), secs % 60)}})
  local row = button_row(frame)
  row.add({type = "button", name = PREFIX .. "menu_restart", style = "back_button", caption = {"rts.menu-restart"},
           tooltip = {"rts.menu-restart-tooltip"}, tags = {rts_lobby = "restart"}}).enabled = can_control(player)
  if m.phase == "running" and player.force.name == match.PLAYER and not (m.out and m.out[match.PLAYER]) then
    local armed = concede_armed(player)
    row.add({type = "button", name = PREFIX .. "menu_concede", style = "red_button",
             caption = armed and {"rts.menu-concede-confirm"} or {"rts.menu-concede"},
             tooltip = {"rts.menu-concede-tooltip"}, tags = {rts_lobby = "concede"}}).enabled = can_control(player)
  elseif match.result(player.force.name) then
    row.add({type = "button", name = PREFIX .. "menu_results", caption = {"rts.menu-results"},
             tooltip = {"rts.menu-results-tooltip"}, tags = {rts_lobby = "results"}})
  end
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
  local sub = inner.add({type = "label", caption = {match.result_text_key(player.force.name)}})
  sub.style.single_line = false
  sub.style.maximal_width = DIALOG_WIDTH - 40
  inner.add({type = "label", caption = {"rts.results-time", clock(match.elapsed_seconds())}})
  local cfg = inner.add({type = "label", caption = lobby.config_text(m.config)})
  cfg.style.font_color = COLOR.dim
  cfg.style.single_line = false -- Phase 5 M3 integration: the Nation line wraps (Russian, Conquest + Space)
  cfg.style.maximal_width = 560
  -- Phase 5 M2 diplomacy: a Nation match names its victory and adds the score (D6) and the war score per nation
  local nation = m.config and m.config.mode == "nation"
  local l = package and package.loaded
  local wars = nation and l and (l["__" .. script.mod_name .. "__/scripts/wars.lua"] or l["scripts.wars"]) or nil
  if nation then frame.style.width = 720 end
  if nation and m.victory and m.victory.how then
    local names = {""}
    for i, f in ipairs(m.victory.winners or {}) do
      if i > 1 then names[#names + 1] = ", " end
      names[#names + 1] = match.label(f)
    end
    local key = #(m.victory.winners or {}) > 0 and "rts.results-victory-" or "rts.results-draw-"
    local how = inner.add({type = "label", caption = {key .. m.victory.how, names}})
    how.style.single_line = false
    how.style.maximal_width = 560
  end
  local t = inner.add({type = "table", column_count = wars and 6 or 4, style = "bordered_table"})
  t.style.top_margin = 8
  t.style.horizontally_stretchable = true
  local headers = {"results-force", "results-units", "results-buildings", "results-status"}
  if wars then
    headers[#headers + 1] = "results-score"
    headers[#headers + 1] = "results-war-score"
  end
  for _, key in ipairs(headers) do
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
      status = {m.conceded == f and "rts.results-conceded" or "rts.results-out", clock((m.out[f] - m.tick_started) / 60)}
    elseif m.winner == f or (m.winners and m.winners[f]) then -- Phase 5 M2 diplomacy: shared victories
      status = {"rts.results-winner"}
    else
      status = {"rts.results-alive"}
    end
    t.add({type = "label", caption = status})
    if wars then -- Phase 5 M2 diplomacy
      local score, parts = wars.nation_score(f)
      t.add({type = "label", caption = tostring(score), tooltip = {"rts.results-score-tooltip", math.floor(parts.pop),
        math.floor(parts.treasury), math.floor(parts.land), math.floor(parts.supply)}})
      local ws = wars.war_score(f)
      t.add({type = "label", caption = string.format("%+d", math.floor(ws + 0.5)), tooltip = {"rts.results-war-score-tooltip"}})
    end
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
  if c.size ~= "legacy" and c.mode ~= "nation" then pending().size, pending().map = c.size, c.map end
  pending().mode = c.mode or "skirmish"
  if c.mode == "nation" then pending().victory, pending().time_limit = c.victory, c.time_limit end -- Phase 5 M2 diplomacy
  if c.mode == "nation" then
    util.log("lobby: match %d started by %s on %s: %d opponent(s), %s, nation, world %dx%d, brain %s", m.match_id,
      tostring(who), surface.name, c.opponents, c.difficulty, c.world_size, c.world_size, c.enemy_brain)
  else
    util.log("lobby: match %d started by %s on %s: %d opponent(s), %s, %s, map %s, brain %s, mode %s", m.match_id,
      tostring(who), surface.name, c.opponents, c.difficulty, c.size, c.map, c.enemy_brain, tostring(c.mode))
  end
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
    lobby.start_match({opponents = p.opponents, difficulty = p.difficulty, size = p.size, map = p.map,
                       enemy_brain = "ai", mode = p.mode, victory = p.victory, time_limit = p.time_limit, -- Phase 5 M2 diplomacy
                       world_size = p.mode == "nation" and (p.world_size or world.size_for(p.opponents + 1)) or nil,
                       survey = p.mode == "nation" and p.survey or nil}, -- Phase 5 M3 world3
                      "player " .. player.index)
  elseif action == "restart" then
    if not can_control(player) then return end
    lobby.back_to_lobby("restart by player " .. player.index)
  elseif action == "resume" then
    destroy(player, "menu")
  elseif action == "concede" then
    if not can_control(player) then return end
    if not concede_armed(player) then
      util.pstorage(player.index).concede_armed = game.tick
      util.log("lobby: concede armed by player %d", player.index)
      lobby.show_menu(player)
      return
    end
    util.pstorage(player.index).concede_armed = nil
    destroy(player, "menu")
    match.concede(player.force.name, "player " .. player.index) -- match.on_ended below shows the results
  elseif action == "results" then
    destroy(player, "menu")
    if match.result(player.force.name) then lobby.show_results(player) end
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
    -- Phase 5 M3 world3: 5-6 nations need a bigger world than 2048 (the size follows unless the player picked one)
    if p.mode == "nation" and p.world_size and p.opponents + 1 > world.max_nations(p.world_size) then
      p.world_size = world.normalize_size(p.world_size, p.opponents + 1)
    end
  elseif what == "difficulty" then
    p.difficulty = match.DIFFICULTIES[el.selected_index] or p.difficulty
  elseif what == "size" then
    p.size = match.SIZE_ORDER[el.selected_index] or p.size
  elseif what == "map" then
    if p.mode ~= "nation" then p.map = match.MAPS[el.selected_index] or p.map end
  elseif what == "mode" then
    p.mode = el.selected_index == 2 and "nation" or "skirmish"
    if p.mode ~= "nation" then p.opponents = math.min(p.opponents, match.MAX_OPPONENTS) end -- Phase 5 M3 world3
  elseif what == "survey" then -- Phase 5 M3 world3
    p.survey = el.selected_index == 2 or nil
  elseif what == "victory" then -- Phase 5 M2 diplomacy (D6)
    p.victory = VICTORY.modes[el.selected_index] or p.victory
  elseif what == "time_limit" then
    p.time_limit = VICTORY.time_limits[el.selected_index] or p.time_limit
  elseif what == "world_size" then
    local ws = world.SIZES[el.selected_index]
    p.world_size = (ws and ws ~= world.size_for(p.opponents + 1)) and ws or nil -- the default follows the nations
    -- Phase 5 M3 world3: a world holds at most world.max_nations(size) nations (4 on 2048)
    if ws then p.opponents = math.min(p.opponents, world.max_nations(ws) - 1) end
  else
    return
  end
  if p.mode == "nation" then
    util.log("lobby: player %d set %s -> %d opponent(s), %s, nation, world %s", e.player_index, tostring(what),
      p.opponents, p.difficulty, tostring(p.world_size or "default"))
  else
    util.log("lobby: player %d set %s -> %d opponent(s), %s, %s, %s, %s, world %s", e.player_index, tostring(what),
      p.opponents, p.difficulty, p.size, p.map, p.mode, tostring(p.world_size or "default"))
  end
  -- every connected player sees the same choices; a mode change (and the nation count in Nation mode) also redraws
  -- the dialog of the player who made it (greyed size and map, the world size)
  local redraw_self = what == "mode" or (what == "opponents" and p.mode == "nation")
    or what == "world_size" -- Phase 5 M3 world3: the nation count and the generation line follow the size
  for _, player in pairs(game.connected_players) do
    if (redraw_self or player.index ~= e.player_index) and player.gui.screen[NAMES.lobby] then lobby.show_lobby(player) end
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

commands.add_command("rts-match",
  "<opponents 1-3 (nation: 1-5)> <easy|normal|hard> <small|medium|large> [chokes|open] [waves] [nation [2048|3072|4096] [survey] [conquest_space|conquest|territory|score|any] [t60|t90|t120]] - start a "
    .. "new match",
  function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    if player and not player.admin then
      player.print("[rts] admins only")
      return
    end
    local args = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = string.lower(w) end
    local cfg = {opponents = tonumber(args[1] or ""), difficulty = args[2], size = args[3], enemy_brain = "ai"}
    for i = 4, #args do
      if args[i] == "waves" then cfg.enemy_brain = "waves" end
      if args[i] == "open" or args[i] == "chokes" then cfg.map = args[i] end
      if args[i] == "nation" then cfg.mode = "nation" end -- Phase 5 M1
      if args[i] == "survey" then cfg.survey = true end -- Phase 5 M3 world3
      if args[i] == "conquest" or args[i] == "territory" or args[i] == "score" then cfg.victory = args[i] end -- Phase 5 M2 diplomacy
      if args[i] == "conquest_space" or args[i] == "any" then cfg.victory = args[i] end -- Phase 5 M3 age3
      if string.match(args[i], "^t%d+$") then cfg.time_limit = tonumber(string.sub(args[i], 2)) end -- t60: time limit
      if tonumber(args[i]) and i > 3 then cfg.world_size = tonumber(args[i]) end
    end
    local c = match.normalize_config(cfg)
    lobby.start_match(c, player and ("player " .. player.index) or "console")
    local line = string.format("[rts] rts-match: match %d, %d opponent(s), %s, %s, map %s, mode %s", storage.match.match_id,
      c.opponents, c.difficulty, c.size, c.map, c.mode)
    if player then player.print(line) else game.print(line) end
  end)

-- Dev-only GUI self-test step (camera.lua, off by default): the whole arena, zoomed out, before the 900 screenshot
-- and the QA reset at 930 (scripts/debug.lua).
camera.add_selftest_step(890, "mapgen_overview", function(player) mapgen.overview_screenshot(player) end)

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
