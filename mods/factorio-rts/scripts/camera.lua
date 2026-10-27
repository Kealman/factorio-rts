-- RTS camera: every human sits in the `remote` controller over a characterless god body (spike #1,
-- decisions 1, 12, 13). Owns these storage.players[i] fields:
--   desired_controller  "remote" (the guard re-applies it whenever the controller changes)
--   setup_done, setup_tick
--   last_remote_pos, last_zoom   tracked every 10 ticks, restored after an unwanted exit
--   qa_pos, qa_zoom, qa_render   last camera state written to the log (QA lines "camera pan|zoom|render_mode")
--   selftest_step                GUI self-test progress (dev only)
-- and storage.camera = {pending = {[player_index] = tick}, selftest = nil|true|false,
--                       pulse = {[player_index] = {at, on, reason}}, planner = {[player_index] = true}}
-- (deferred re-apply; the self-test switch set by /rts-selftest, nil = SELFTEST_DEFAULT).
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local units = require("scripts.units")
local cursor = require("scripts.cursor")

local camera = {}

local REMOTE = defines.controllers.remote
local GOD = defines.controllers.god
local START_ZOOM = 0.5 -- ~80 tiles across at 1280 px
-- Keep the game view (never the chart) at every allowed zoom: furthest_game_view == furthest.
local ZOOM_LIMITS = {closest = {zoom = 2}, furthest = {zoom = 0.15}, furthest_game_view = {zoom = 0.15}}
local PERMISSION_GROUP = "rts"

-- Every GameViewSettings field that is vanilla chrome (verified in runtime-api.json 2.0.77).
-- Kept on: show_entity_info (alt mode), show_entity_tooltip (hud.lua switches it off), show_rail_block_visualisation.
-- update_entity_selection is off since Wave C (Phase 4 QA steps 19 and 24): in the remote view the vanilla info box
-- for a hovered entity or ghost still appeared in the top-right corner under the HUD minimap with
-- show_entity_tooltip off, and went stale after the ghost was built. Nothing in the RTS needs hover: clicks and drags
-- come from the rts-cursor selection tool (selection.lua picks units and buildings by position), right clicks from
-- its reverse selection.
local HIDDEN_CHROME = {
  "show_controller_gui", "show_minimap", "show_research_info", "show_alert_gui", "show_crafting_queue",
  "show_tool_bar", "show_quickbar", "show_shortcut_bar", "show_side_menu", "show_map_view_options",
  "show_surface_list", "show_hotkey_suggestions", "update_entity_selection",
  "show_pins_gui", -- Factorio 2.1: the new map pins panel (GameViewSettings::show_pins_gui)
}

-- Input actions that break the RTS illusion. Deliberately NOT blocked: start_walking (it may be what
-- pans the remote camera with WASD), select/alt/reverse select_area, remote_view_*, gui_*, build,
-- custom_input, lua_shortcut, spawn_item (the cursor shortcut), clear_cursor (re-insert handles it),
-- write_to_console (commands).
local BLOCKED_ACTIONS = {
  "toggle_map_editor", "open_character_gui", "craft", "cancel_craft", "toggle_driving",
  "change_shooting_state", "begin_mining", "begin_mining_terrain", "pipette",
  "quick_bar_pick_slot", "quick_bar_set_slot", "quick_bar_set_selected_page", "change_active_quick_bar",
  "open_blueprint_library_gui", "open_production_gui", "open_logistics_gui", "open_trains_gui",
  "open_achievements_gui", "open_bonus_gui", "toggle_personal_roboport", "toggle_personal_logistic_requests",
  "toggle_equipment_movement_bonus", "drop_item", "use_item",
}

-- Dev-only GUI self-test (tools/gui-run.sh): screenshots, a guard check, a home jump, the selection and
-- order steps that debug.lua adds, then the RTS_GUI_READY stop marker. Steps are ticks after setup.
-- Off by default so QA sessions are not disturbed; `/rts-selftest on` runs it from now (and `off` stops it).
-- Only the RTS_GUI_READY log line (`always`) is written with the self-test off, so tools/gui-run.sh can
-- still use it as the stop marker of a smoke run.
local SELFTEST_DEFAULT = false
local SELFTEST_STEPS = {
  {at = 120, run = "screenshot"},
  {at = 330, run = "exit_remote"}, -- off the 60-tick watchdog, so the controller-changed event path is tested
  {at = 360, run = "check_guard"},
  {at = 600, run = "home"},
  {at = 900, run = "screenshot"},
  {at = 960, run = "ready", always = true},
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function desired_type(p)
  return defines.controllers[p.desired_controller or "remote"]
end

local function army_position(player)
  return units.centroid(player.force.name) or match.home(player.force.name)
end

-- Phase 3: the view is on the match arena (or the lobby surface before a match), not on the physical surface.
local function enter_remote(player, position)
  player.set_controller({type = REMOTE, position = position, surface = match.view_surface()})
end

-- Phase 3 join flow: the characterless god body lives on the lobby surface, so nauvis is never shown, not even
-- for the tick between leaving and re-entering the remote view. Teleporting needs the god controller.
local function park_body(player)
  local lobby = match.lobby_surface()
  if player.physical_surface.index == lobby.index then return end
  if player.controller_type ~= GOD then player.set_controller({type = GOD}) end
  local ok = player.teleport({0, 0}, lobby)
  util.log("camera: god body of player %d moved to %s: %s", player.index, lobby.name, tostring(ok))
end

local function chrome_shown(player)
  local gvs = player.game_view_settings
  local shown = {}
  for _, field in pairs(HIDDEN_CHROME) do
    if gvs[field] then shown[#shown + 1] = field end
  end
  return shown
end

local function hide_chrome(player)
  local gvs = player.game_view_settings
  for _, field in pairs(HIDDEN_CHROME) do gvs[field] = false end
  -- GameViewSettings is a LuaStruct; if the read returned a detached copy, write the whole struct back.
  if #chrome_shown(player) > 0 then
    player.game_view_settings = gvs
    util.log("camera: game_view_settings needed a write-back for player %d", player.index)
  end
end

local function ensure_permission_group()
  local group = game.permissions.get_group(PERMISSION_GROUP)
  if group then return group end
  group = game.permissions.create_group(PERMISSION_GROUP)
  if not group then
    util.log("camera: could not create permission group %q", PERMISSION_GROUP)
    return nil
  end
  local blocked, missing = 0, {}
  for _, name in pairs(BLOCKED_ACTIONS) do
    local action = defines.input_action[name]
    if action then
      group.set_allows_action(action, false)
      blocked = blocked + 1
    else
      missing[#missing + 1] = name
    end
  end
  util.log("camera: permission group %q created, %d input actions blocked%s", PERMISSION_GROUP, blocked,
    #missing > 0 and (", unknown: " .. table.concat(missing, ",")) or "")
  return group
end

-- 0.1.1 (issue #12): Factorio 2.1 lets the toggle-menu key (Escape) leave the remote view; with the god body parked on
-- the lobby surface that showed the empty lobby for a tick until the guard below re-entered the remote view, and the
-- game menu (save, load, settings, quit) could never open. With the switch off, Escape closes an open panel first and
-- otherwise opens the game menu, and the view stays remote (tools/probes/r2_inputs_gui.lua, "escape_game_menu").
local function keep_remote_on_menu(player)
  if player.toggle_menu_leaves_remote_view ~= false then player.toggle_menu_leaves_remote_view = false end
end

local function view_summary(player)
  local shown = chrome_shown(player)
  return string.format("controller=%s physical=%s character=%s position=%s zoom=%.3f render_mode=%s "
    .. "cursor=%s force=%s group=%s chrome_still_shown=[%s]",
    util.define_name(defines.controllers, player.controller_type),
    util.define_name(defines.controllers, player.physical_controller_type), tostring(player.character ~= nil),
    util.pos_str(player.position), player.zoom, util.define_name(defines.render_mode, player.render_mode),
    (player.cursor_stack and player.cursor_stack.valid_for_read) and player.cursor_stack.name or "empty",
    player.force.name, player.permission_group and player.permission_group.name or "none",
    table.concat(shown, ","))
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Move the camera to a world position, keeping the current zoom.
function camera.jump_to(player, position)
  local p = util.pstorage(player.index)
  p.last_remote_pos = {x = position.x or position[1], y = position.y or position[2]}
  p.qa_pos = p.last_remote_pos -- a jump is not a pan (see the QA tracker below)
  util.log("camera jump player=%d -> %s", player.index, util.pos_str(p.last_remote_pos))
  if player.controller_type ~= REMOTE then return end -- the guard re-enters remote at last_remote_pos
  local zoom = player.zoom
  enter_remote(player, p.last_remote_pos)
  player.zoom = zoom
end

--- Move the camera to the player's home (own spawn point).
function camera.home(player)
  local home = match.home(player.force.name)
  util.log("camera home player=%d -> %s", player.index, util.pos_str(home))
  camera.jump_to(player, home)
end

--- Full camera setup: remove the character, enter remote view over the army, zoom, hide chrome.
function camera.setup(player, reason)
  local p = util.pstorage(player.index)
  p.desired_controller = "remote"

  local character = player.character
  if character then
    player.character = nil -- switches to god immediately (spike #1 gotcha 4)
    if character.valid then character.destroy() end
  end
  local ct = player.controller_type
  if ct ~= GOD and ct ~= REMOTE then player.set_controller({type = GOD}) end
  park_body(player)

  local group = ensure_permission_group()
  if group then group.add_player(player) end

  local pos = army_position(player)
  enter_remote(player, pos)
  player.set_zoom_limits(REMOTE, ZOOM_LIMITS) -- two positional arguments (spike #1 gotcha 11)
  player.zoom = START_ZOOM                     -- the engine picks 0.2 or 0.133 otherwise (gotcha 9)
  hide_chrome(player)
  keep_remote_on_menu(player)

  p.last_remote_pos = pos
  p.last_zoom = START_ZOOM
  p.setup_done = true
  p.setup_tick = game.tick
  p.selftest_step = 1
  cursor.ensure(player)
  util.log("camera: setup (%s) player %d: %s", reason, player.index, view_summary(player))
end

---------------------------------------------------------------------------
-- Controller guard
---------------------------------------------------------------------------
local function reapply(player, why)
  local p = util.pstorage(player.index)
  if player.character then
    camera.setup(player, "reapply/" .. why)
    return
  end
  if player.controller_type == desired_type(p) then return end
  local old = util.define_name(defines.controllers, player.controller_type)
  enter_remote(player, p.last_remote_pos or army_position(player))
  player.zoom = p.last_zoom or START_ZOOM
  cursor.ensure(player)
  util.log("camera: re-applied remote for player %d (%s, was %s) at %s", player.index, why, old,
    util.pos_str(player.position))
end

-- The event is deferred and coalesced (spike #1 gotcha 5): compare against the desired controller and
-- re-apply on the next tick instead of using re-entry flags.
events.on(defines.events.on_player_controller_changed, function(e)
  local p = storage.players and storage.players[e.player_index]
  if not (p and p.setup_done) then return end
  local player = game.get_player(e.player_index)
  if player.controller_type ~= desired_type(p) then
    storage.camera.pending[e.player_index] = e.tick + 1
  end
end)

events.on(defines.events.on_tick, function(e)
  local pending = storage.camera.pending
  if next(pending) == nil then return end
  for index, due in pairs(pending) do
    if e.tick >= due then
      pending[index] = nil
      local player = game.get_player(index)
      if player and player.connected then reapply(player, "controller changed") end
    end
  end
end)

-- Phase 5 M1 QA round 1 (finding 5): with hover selection off (update_entity_selection) the engine still selects an
-- entity now and then by itself, and the selection then stays. Nothing in the RTS reads player.selected (selection.lua
-- picks by position), so a set one is cleared at once.
local function clear_hover(player)
  local sel = player.selected
  if sel then
    local name = sel.valid and (sel.type == "entity-ghost" and ("ghost of " .. sel.ghost_name) or sel.name) or "?"
    player.clear_selected_entity()
    util.log("camera: cleared the hover selection (%s) of player %d", name, player.index)
  end
end

-- Phase 5 M2 QA round 1 (step 29): the box under the minimap is not the selected entity's tooltip. A build from a
-- cursor that holds a ghost leaves the vanilla info box of the placed item in the top-right corner, and with hover
-- selection off the engine never refreshes it: it stayed 72 s after Q in the QA run, with player.selected nil the
-- whole time. A GUI probe with real clicks (docs/qa/phase5-m2-integration-notes.md section 7) reproduced it;
-- clear_selected_entity, `selected = nil` and update_selected_entity left it, update_entity_selection on for one tick
-- removed it, with the mouse over empty ground and over a ghost alike. While the cursor still holds the ghost the box
-- stays whatever is done (it is the box of the building in hand), so the pulse runs whenever the RTS cursor comes back
-- (Q, right click, F1, the build button again): the box goes when build mode ends. During the pulse tick the engine
-- selects what is under the mouse; with the entity tooltip off that shows no box, and the selection is cleared on the
-- next tick.
function camera.hover_pulse(player, reason)
  if not (player and player.valid and player.connected) then return end
  if not (player.permission_group and player.permission_group.name == PERMISSION_GROUP) then return end
  local c = storage.camera
  c.pulse = c.pulse or {}
  if c.pulse[player.index] then return end
  c.pulse[player.index] = {at = game.tick + 1, reason = reason}
end

local function entity_text(e)
  if not (e and e.valid) then return "nothing" end
  return e.type == "entity-ghost" and ("ghost of " .. e.ghost_name) or e.name
end

local function set_hover(player, on)
  local gvs = player.game_view_settings
  gvs.update_entity_selection = on
  player.game_view_settings = gvs -- a LuaStruct read may be a detached copy: write the whole struct back
end

events.on(defines.events.on_tick, function(e)
  local pulse = storage.camera.pulse
  if not pulse or next(pulse) == nil then return end
  for index, P in pairs(pulse) do
    if e.tick >= P.at then
      local player = game.get_player(index)
      if not (player and player.connected) then
        pulse[index] = nil
      elseif not P.on then
        set_hover(player, true)
        P.on, P.at = true, e.tick + 1
      elseif storage.camera.planner and storage.camera.planner[index] then
        pulse[index] = nil -- 0.1.3 (#37): a rail planner came into the cursor meanwhile: hover selection stays on
      else
        set_hover(player, false)
        local sel = player.selected
        if sel then player.clear_selected_entity() end
        pulse[index] = nil
        util.log("camera: hover pulse player=%d (%s), under the mouse: %s", index, P.reason or "-", entity_text(sel))
      end
    end
  end
end)

-- 0.1.3 (#37, docs/qa/release-0-1-3-r4-rails-notes.md section 1): the vanilla rail planner starts from the rail end
-- under the pointer, and the engine only knows what is under the pointer with hover selection on
-- (update_entity_selection, off for RTS players since Wave C): with it off every click of a rail ghost placed one piece
-- and a drag a staircase of straight pieces (0.1.2), with it on the planner previews and builds its path, curves,
-- joins and all (probe tools/probes/r4_planner_finding_gui.lua, real input). So while a rail planner ghost is in the
-- cursor hover selection is on and the 10-tick hover clear below waits (storage.camera.planner); when the RTS cursor
-- comes back the hover pulse turns it off as after any build mode.
function camera.planner_view(player, on)
  if not (player and player.valid) then return end
  local c = storage.camera
  c.planner = c.planner or {}
  if on then
    if c.planner[player.index] then return end
    c.planner[player.index] = true
    set_hover(player, true)
    util.log("camera: rail planner view on (hover selection) player=%d", player.index)
  elseif c.planner[player.index] then
    c.planner[player.index] = nil
    util.log("camera: rail planner view off player=%d", player.index)
  end
end

cursor.on_ghost_given(function(player, item)
  local proto = prototypes.item[item]
  if proto and proto.type == "rail-planner" then camera.planner_view(player, true) end
end)

cursor.on_tool_given(function(player, reason)
  camera.planner_view(player, false) -- 0.1.3 (#37): the pulse below turns hover selection off
  camera.hover_pulse(player, "tool back: " .. tostring(reason))
end)

events.on_nth_tick(10, function()
  for _, player in pairs(game.connected_players) do
    if player.controller_type == REMOTE then
      local p = util.pstorage(player.index)
      p.last_remote_pos = player.position
      p.last_zoom = player.zoom
      local pulsing = storage.camera.pulse and storage.camera.pulse[player.index]
      local planner = storage.camera.planner and storage.camera.planner[player.index] -- 0.1.3 (#37)
      if planner and not cursor.holds_planner(player) and not pulsing then
        -- (the planner ghost went without the RTS cursor coming back: hover selection off again)
        camera.planner_view(player, false)
        set_hover(player, false)
        planner = nil
      end
      if not (pulsing or planner) and player.permission_group and player.permission_group.name == PERMISSION_GROUP then
        clear_hover(player)
      end
    end
  end
end)

-- QA log lines (docs/qa/phase1-protocol.md): camera pans (WASD), zoom changes (wheel) and render mode
-- changes (M), sampled twice a second. Jumps (minimap, SPACE, double tap) log their own line instead.
local QA_PAN_TILES = 1
local QA_ZOOM_RATIO = 0.02
events.on_nth_tick(30, function()
  for _, player in pairs(game.connected_players) do
    local p = storage.players and storage.players[player.index]
    if p and p.setup_done then
      local pos, zoom = player.position, player.zoom
      local mode = util.define_name(defines.render_mode, player.render_mode)
      if p.qa_pos and util.distance(pos, p.qa_pos) > QA_PAN_TILES then
        util.log("camera pan player=%d %s -> %s d=(%.1f, %.1f) controller=%s", player.index, util.pos_str(p.qa_pos),
          util.pos_str(pos), pos.x - p.qa_pos.x, pos.y - p.qa_pos.y,
          util.define_name(defines.controllers, player.controller_type))
      end
      if p.qa_zoom and math.abs(zoom - p.qa_zoom) > QA_ZOOM_RATIO * p.qa_zoom then
        util.log("camera zoom player=%d %.3f -> %.3f", player.index, p.qa_zoom, zoom)
      end
      if p.qa_render and p.qa_render ~= mode then
        util.log("camera render_mode player=%d %s -> %s controller=%s", player.index, p.qa_render, mode,
          util.define_name(defines.controllers, player.controller_type))
      end
      if not p.qa_pos or util.distance(pos, p.qa_pos) > QA_PAN_TILES then p.qa_pos = {x = pos.x, y = pos.y} end
      if not p.qa_zoom or math.abs(zoom - p.qa_zoom) > QA_ZOOM_RATIO * p.qa_zoom then p.qa_zoom = zoom end
      p.qa_render = mode
    end
  end
end)

-- Backstop in case an event was missed.
events.on_nth_tick(60, function()
  for _, player in pairs(game.connected_players) do
    local p = storage.players and storage.players[player.index]
    if p and p.setup_done and player.controller_type ~= desired_type(p) and not storage.camera.pending[player.index] then
      reapply(player, "watchdog")
    end
  end
end)

---------------------------------------------------------------------------
-- GUI self-test (dev only)
---------------------------------------------------------------------------
local function screenshot(player)
  local path = string.format("rts-p%d-%d.png", player.index, game.tick)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  util.log("camera: selftest screenshot %s: %s", path, view_summary(player))
end

local SELFTEST = {
  screenshot = screenshot,
  exit_remote = function(player)
    player.exit_remote_view()
    util.log("camera: selftest exit_remote_view() -> controller=%s",
      util.define_name(defines.controllers, player.controller_type))
  end,
  check_guard = function(player)
    util.log("camera: selftest guard check (expect remote): %s", view_summary(player))
  end,
  home = function(player)
    local before = util.pos_str(player.position)
    camera.home(player)
    util.log("camera: selftest home: %s -> %s (home %s)", before, util.pos_str(player.position),
      util.pos_str(match.home(player.force.name)))
  end,
  ready = function(player)
    util.log("RTS_GUI_READY player %d: %s", player.index, view_summary(player))
  end,
}

--- Screenshot of what the player sees (with the GUI) into script-output; logs the view summary.
camera.screenshot = screenshot

--- True while the GUI self-test is on (storage switch from /rts-selftest, else SELFTEST_DEFAULT).
function camera.selftest_enabled()
  local flag = storage.camera and storage.camera.selftest
  if flag == nil then return SELFTEST_DEFAULT end
  return flag
end

--- Add a self-test step: fn(player) runs `at` ticks after the player's setup while the self-test is on.
--- Load time only (module top level), so every client has the same list.
function camera.add_selftest_step(at, name, fn)
  assert(not SELFTEST[name], "camera.add_selftest_step: duplicate step " .. name)
  SELFTEST[name] = fn
  SELFTEST_STEPS[#SELFTEST_STEPS + 1] = {at = at, run = name}
  table.sort(SELFTEST_STEPS, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.run < b.run
  end)
end

-- Registered unconditionally (the switch lives in storage); every handler registration must be the same
-- on every load.
events.on_nth_tick(30, function(e)
  local enabled = camera.selftest_enabled()
  for _, player in pairs(game.connected_players) do
    local p = storage.players and storage.players[player.index]
    local step = p and p.setup_done and p.selftest_step and SELFTEST_STEPS[p.selftest_step]
    while step and e.tick - p.setup_tick >= step.at do
      p.selftest_step = p.selftest_step + 1
      if enabled or step.always then SELFTEST[step.run](player) end
      step = SELFTEST_STEPS[p.selftest_step]
    end
  end
end)

commands.add_command("rts-selftest", "[on|off] - run the GUI self-test from now (on) or stop it (off)", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player and not player.admin then
    player.print("[rts] admins only")
    return
  end
  local arg = (cmd.parameter or ""):lower()
  local on = arg ~= "off"
  storage.camera.selftest = on
  if on then
    for _, pl in pairs(game.connected_players) do
      local p = storage.players and storage.players[pl.index]
      if p and p.setup_done then
        p.setup_tick = game.tick
        p.selftest_step = 1
      end
    end
  end
  local line = "[rts] GUI self-test " .. (on and "on (restarted for connected players)" or "off")
  if player then player.print(line) else game.print(line) end
  util.log("camera: %s", line)
end)

-- No vanilla entity window for RTS players (Phase 4 QA): if anything opens one (a click through, a script setting
-- player.opened), close it again. The RTS panels are custom GUIs and stay.
events.on(defines.events.on_gui_opened, function(e)
  if e.gui_type ~= defines.gui_type.entity then return end
  local player = game.get_player(e.player_index)
  if not (player and player.permission_group and player.permission_group.name == PERMISSION_GROUP) then return end
  local name = e.entity and e.entity.valid and e.entity.name or "?"
  player.opened = nil
  util.log("camera: closed the vanilla entity window of %s for player %d", name, player.index)
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function camera.init()
  storage.camera = storage.camera or {pending = {}}
  ensure_permission_group()
  -- Freeplay: no crash site, no intro, no items for a character we remove. Must happen in on_init:
  -- the scenario's own on_player_created runs before ours (spike #1 gotcha 2).
  if remote.interfaces.freeplay then
    for _, call in pairs({{"set_disable_crashsite", true}, {"set_skip_intro", true},
                          {"set_created_items", {}}, {"set_respawn_items", {}}}) do
      if remote.interfaces.freeplay[call[1]] then remote.call("freeplay", call[1], call[2]) end
    end
  end
  for _, player in pairs(game.connected_players) do
    local p = storage.players and storage.players[player.index]
    if not (p and p.setup_done) then camera.setup(player, "init") end
  end
  for _, player in pairs(game.players) do keep_remote_on_menu(player) end -- saves from 0.1.0 (issue #12)
end

events.on(defines.events.on_player_created, function(e)
  camera.setup(game.get_player(e.player_index), "created")
end)

events.on(defines.events.on_player_joined_game, function(e)
  local player = game.get_player(e.player_index)
  local p = util.pstorage(player.index)
  if not p.setup_done or player.character then
    camera.setup(player, "joined")
    return
  end
  hide_chrome(player)
  keep_remote_on_menu(player)
  reapply(player, "joined")
  cursor.ensure(player)
  local c = storage.camera -- 0.1.3 (#37): a save made with the rail planner in hand keeps it working
  if c.planner and c.planner[player.index] and cursor.holds_planner(player) then set_hover(player, true) end
end)

events.on(defines.events.on_player_respawned, function(e)
  camera.setup(game.get_player(e.player_index), "respawned")
end)

events.on("rts-camera-home", function(e)
  camera.home(game.get_player(e.player_index))
end)

return camera
