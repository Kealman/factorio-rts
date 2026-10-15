-- RTS camera: every human sits in the `remote` controller over a characterless god body (spike #1,
-- decisions 1, 12, 13). Owns these storage.players[i] fields:
--   desired_controller  "remote" (the guard re-applies it whenever the controller changes)
--   setup_done, setup_tick
--   last_remote_pos, last_zoom   tracked every 10 ticks, restored after an unwanted exit
--   selftest_step                GUI self-test progress (dev only)
-- and storage.camera = {pending = {[player_index] = tick}} (deferred re-apply).
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
-- Kept on: show_entity_info (alt mode), show_entity_tooltip, show_rail_block_visualisation,
-- update_entity_selection (hover must keep working).
local HIDDEN_CHROME = {
  "show_controller_gui", "show_minimap", "show_research_info", "show_alert_gui", "show_crafting_queue",
  "show_tool_bar", "show_quickbar", "show_shortcut_bar", "show_side_menu", "show_map_view_options",
  "show_surface_list", "show_hotkey_suggestions",
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

-- Dev-only GUI self-test (tools/gui-run.sh): screenshots, a guard check, a home jump, then the
-- RTS_GUI_READY stop marker. Steps are ticks after setup. Turn off before a release.
local GUI_SELFTEST = true
local SELFTEST_STEPS = {
  {at = 120, run = "screenshot"},
  {at = 330, run = "exit_remote"}, -- off the 60-tick watchdog, so the controller-changed event path is tested
  {at = 360, run = "check_guard"},
  {at = 600, run = "home"},
  {at = 900, run = "screenshot"},
  {at = 960, run = "ready"},
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

local function enter_remote(player, position)
  player.set_controller({type = REMOTE, position = position, surface = player.physical_surface})
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
  if player.controller_type ~= REMOTE then return end -- the guard re-enters remote at last_remote_pos
  local zoom = player.zoom
  enter_remote(player, p.last_remote_pos)
  player.zoom = zoom
end

--- Move the camera to the player's home (own spawn point).
function camera.home(player)
  camera.jump_to(player, match.home(player.force.name))
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

  local group = ensure_permission_group()
  if group then group.add_player(player) end

  local pos = army_position(player)
  enter_remote(player, pos)
  player.set_zoom_limits(REMOTE, ZOOM_LIMITS) -- two positional arguments (spike #1 gotcha 11)
  player.zoom = START_ZOOM                     -- the engine picks 0.2 or 0.133 otherwise (gotcha 9)
  hide_chrome(player)

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

events.on_nth_tick(10, function()
  for _, player in pairs(game.connected_players) do
    if player.controller_type == REMOTE then
      local p = util.pstorage(player.index)
      p.last_remote_pos = player.position
      p.last_zoom = player.zoom
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

if GUI_SELFTEST then
  events.on_nth_tick(30, function(e)
    for _, player in pairs(game.connected_players) do
      local p = storage.players and storage.players[player.index]
      local step = p and p.setup_done and p.selftest_step and SELFTEST_STEPS[p.selftest_step]
      while step and e.tick - p.setup_tick >= step.at do
        p.selftest_step = p.selftest_step + 1
        SELFTEST[step.run](player)
        step = SELFTEST_STEPS[p.selftest_step]
      end
    end
  end)
end

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
  reapply(player, "joined")
  cursor.ensure(player)
end)

events.on(defines.events.on_player_respawned, function(e)
  camera.setup(game.get_player(e.player_index), "respawned")
end)

events.on("rts-camera-home", function(e)
  camera.home(game.get_player(e.player_index))
end)

return camera
