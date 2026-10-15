-- Spike control stage. Every finding is written with log() and the prefix "[rts-camera]".
-- Spike #1: remote controller persistence without a character (watchdog + controller-changed event).
-- Spike #2: custom-input mouse buttons and selection-tool area events in remote view.
-- Spike #6: on_gui_click on minimap / camera GUI elements.

local TAG = "[rts-camera] "
local UNIT_SPAWN_CENTER = {x = 10, y = 10}
local REMOTE_START = {x = 6, y = 6}
-- Remote zoom limits under test: keep game rendering until ~300 tiles across.
local REMOTE_ZOOM_LIMITS = {furthest_game_view = {distance = 300, max_distance = 600}}

-- Self-test schedule (ticks after the player joined). Runs without human input in the GUI run.
local SHOT_TICKS = {[120] = "", [180] = "playerzoom", [3000] = ""}
local SELFTEST = {
  EXIT_REMOTE = 3060,   -- simulate the player leaving remote view (like pressing M / Escape)
  ZOOM_GAME = 3180,     -- zoom 0.2 (~200 tiles across at 1280 px): should still be game view
  ZOOM_GAME_LOG = 3200,
  ZOOM_CHART = 3240,    -- zoom 0.08 (~500 tiles): beyond furthest_game_view, should be chart
  ZOOM_CHART_LOG = 3260,
  ZOOM_RESET = 3300,
  TO_GOD = 3360,        -- same code path as the F2 toggle
  GOD_SHOT = 3400,
  TO_REMOTE = 3460,
  DONE = 3520,
}

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------
local function L(fmt, ...)
  log(TAG .. string.format(fmt, ...))
end

local CTRL_NAME = {}
for k, v in pairs(defines.controllers) do CTRL_NAME[v] = k end
local RENDER_NAME = {}
for k, v in pairs(defines.render_mode) do RENDER_NAME[v] = k end
local MOUSE_NAME = {}
for k, v in pairs(defines.mouse_button_type) do MOUSE_NAME[v] = k end

local function s(v) return tostring(v) end
local function ctrl(t) return CTRL_NAME[t] or s(t) end

local function pos(p)
  if not p then return "nil" end
  local x, y = p.x or p[1], p.y or p[2]
  return string.format("{%.2f, %.2f}", x, y)
end

local function loc(g)
  if not g then return "nil" end
  return string.format("{%d, %d}", g.x or g[1], g.y or g[2])
end

local function area_str(a)
  if not a then return "nil" end
  local lt, rb = a.left_top or a[1], a.right_bottom or a[2]
  local w = (rb.x or rb[1]) - (lt.x or lt[1])
  local h = (rb.y or rb[2]) - (lt.y or lt[2])
  return string.format("%s..%s (%.2fx%.2f)", pos(lt), pos(rb), w, h)
end

local function sel_proto(sp)
  if not sp then return "nil" end
  return string.format("%s/%s/%s", s(sp.base_type), s(sp.derived_type), s(sp.name))
end

local function cursor_str(player)
  local cs = player.cursor_stack
  if not cs then return "nil-stack" end
  if cs.valid_for_read then return cs.name end
  local ghost = player.cursor_ghost
  if ghost then return "ghost:" .. s(ghost.name and ghost.name.name or ghost.name) end
  return "empty"
end

local function read(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return "ERR(" .. s(v) .. ")"
end

-- Wrap handlers so a spike bug is logged instead of crashing the GUI session.
-- The word "Error" keeps it visible to tools/headless-run.sh's error grep.
local function safe(name, fn)
  return function(e)
    local ok, err = xpcall(fn, function(m) return debug.traceback(m, 2) end, e)
    if not ok then L("Error in handler %s: %s", name, s(err)) end
  end
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function init_storage()
  storage.players = storage.players or {}
  storage.pending_reapply = storage.pending_reapply or {}
  storage.spawned = storage.spawned or false
end

local function pstate(player)
  local st = storage.players[player.index]
  if not st then
    st = {desired = "remote", join_tick = game.tick, setup_done = false}
    storage.players[player.index] = st
  end
  return st
end

local function desired_type(st) return defines.controllers[st.desired] end

---------------------------------------------------------------------------
-- Controller handling
---------------------------------------------------------------------------
local function apply_remote(player, position, why)
  local st = pstate(player)
  st.desired = "remote"
  local target = position or st.last_remote_pos or player.position
  local ok, err = pcall(player.set_controller, {
    type = defines.controllers.remote,
    position = target,
    surface = player.physical_surface,
  })
  L("set_controller{remote} (%s) ok=%s err=%s target=%s -> controller=%s physical=%s position=%s physical_position=%s",
    why, s(ok), s(err), pos(target), ctrl(player.controller_type), ctrl(player.physical_controller_type),
    pos(player.position), pos(player.physical_position))
  return ok
end

local function apply_god(player, why)
  local st = pstate(player)
  st.desired = "god"
  local camera_pos = player.position
  local ok, err = pcall(player.set_controller, {type = defines.controllers.god})
  L("set_controller{god} (%s) ok=%s err=%s -> controller=%s position=%s (camera was at %s)",
    why, s(ok), s(err), ctrl(player.controller_type), pos(player.position), pos(camera_pos))
  -- Try to keep the camera where it was: teleport the characterless god body.
  local tok, terr = pcall(player.teleport, camera_pos, player.physical_surface)
  L("teleport god to camera position ok=%s result=%s -> position=%s", s(tok), s(terr), pos(player.position))
  return ok
end

local function reapply(player, why)
  local st = pstate(player)
  if player.controller_type == desired_type(st) then
    L("reapply (%s) skipped: controller already %s", why, st.desired)
    return
  end
  if st.desired == "remote" then
    apply_remote(player, st.last_remote_pos, "reapply/" .. why)
  else
    apply_god(player, "reapply/" .. why)
  end
end

local function toggle_controller(player, why)
  if player.controller_type == defines.controllers.remote then
    L("TOGGLE (%s): remote -> god", why)
    apply_god(player, "toggle/" .. why)
  else
    L("TOGGLE (%s): %s -> remote", why, ctrl(player.controller_type))
    apply_remote(player, player.position, "toggle/" .. why)
  end
end

---------------------------------------------------------------------------
-- Cursor
---------------------------------------------------------------------------
local function give_cursor(player, why, replace)
  local cs = player.cursor_stack
  if not cs then
    L("give_cursor (%s): cursor_stack is nil (controller=%s)", why, ctrl(player.controller_type))
    return
  end
  if cs.valid_for_read and not replace then return end
  if replace then
    local cok, cres = pcall(player.clear_cursor)
    L("give_cursor (%s): clear_cursor ok=%s result=%s", why, s(cok), s(cres))
  end
  local ok, res = pcall(cs.set_stack, {name = "rts-cursor", count = 1})
  L("give_cursor (%s): set_stack ok=%s result=%s cursor=%s temporary=%s controller=%s",
    why, s(ok), s(res), cursor_str(player), s(read(function() return player.cursor_stack_temporary end)),
    ctrl(player.controller_type))
end

---------------------------------------------------------------------------
-- GUI (spike #6)
---------------------------------------------------------------------------
local HELP_LINES = {
  "RTS camera spike. Every action is logged with the prefix [rts-camera].",
  "1) Left-drag over the biters (select).  2) Shift + left-drag (alt select).",
  "3) Right-click empty ground, then right-drag over biters (reverse select).",
  "4) Shift + right-drag (alt reverse).  5) Middle-click.  6) Ctrl+1 (or Cmd+1), then 1.",
  "7) F2 toggles remote <-> god, F2 again.  8) Click the minimap, the camera and the button.",
  "9) Press M / Escape (leave remote view): the mod should put you back.  10) Q clears the cursor; F1 restores it.",
}

local function build_gui(player)
  local screen = player.gui.screen
  if screen.rts_spike_frame then screen.rts_spike_frame.destroy() end
  local surface_index = player.physical_surface.index
  local frame = screen.add{type = "frame", name = "rts_spike_frame", caption = "RTS spike: minimap / camera", direction = "vertical"}
  frame.location = {x = 10, y = 90}
  for i, line in ipairs(HELP_LINES) do
    frame.add{type = "label", name = "help_" .. i, caption = line}
  end
  local row = frame.add{type = "flow", name = "row", direction = "horizontal"}
  local mm = row.add{type = "minimap", name = "rts_minimap", position = {0, 0}, zoom = 0.5,
                     surface_index = surface_index, raise_hover_events = true}
  mm.style.width = 200
  mm.style.height = 200
  local cam = row.add{type = "camera", name = "rts_camera", position = UNIT_SPAWN_CENTER, zoom = 0.25,
                      surface_index = surface_index, raise_hover_events = true}
  cam.style.width = 200
  cam.style.height = 200
  frame.add{type = "button", name = "rts_button", caption = "Control button", raise_hover_events = true}
  L("GUI built for player %d: frame=%s minimap=%s camera=%s button=%s",
    player.index, s(frame.valid), s(mm.valid), s(cam.valid), s(frame.rts_button and frame.rts_button.valid))
end

---------------------------------------------------------------------------
-- Player setup (spike #1)
---------------------------------------------------------------------------
local function print_help(player)
  for _, line in ipairs(HELP_LINES) do
    player.print("[rts] " .. line, {skip = defines.print_skip.never})
  end
end

local function setup_player(player, reason)
  local st = pstate(player)
  st.in_setup = true
  L("SETUP (%s) player=%d tick=%d controller=%s physical=%s character=%s position=%s multiplayer=%s",
    reason, player.index, game.tick, ctrl(player.controller_type), ctrl(player.physical_controller_type),
    s(player.character ~= nil), pos(player.position), s(game.is_multiplayer()))
  if remote.interfaces.freeplay then
    L("freeplay state at %s: init_ran=%s disable_crashsite=%s skip_intro=%s", reason,
      s(read(function() return remote.call("freeplay", "get_init_ran") end)),
      s(read(function() return remote.call("freeplay", "get_disable_crashsite") end)),
      s(read(function() return remote.call("freeplay", "get_skip_intro") end)))
  end

  -- 1. Remove the character (sandbox pattern: detach first, then destroy the entity).
  local character = player.character
  if character then
    local ok, err = pcall(function() player.character = nil end)
    L("player.character = nil -> ok=%s err=%s controller_now=%s", s(ok), s(err), ctrl(player.controller_type))
    if character.valid then
      local dok, derr = pcall(character.destroy)
      L("character.destroy() -> ok=%s result=%s", s(dok), s(derr))
    end
  end

  -- 2. Make sure the physical controller is god (not ghost / character / cutscene).
  local ct = player.controller_type
  if ct ~= defines.controllers.god and ct ~= defines.controllers.remote then
    local ok, err = pcall(player.set_controller, {type = defines.controllers.god})
    L("set_controller{god} (physical fix from %s) ok=%s err=%s -> %s", ctrl(ct), s(ok), s(err), ctrl(player.controller_type))
  end

  -- 3. Enter remote view and record the engine's default remote zoom limits.
  apply_remote(player, REMOTE_START, "setup/" .. reason)
  L("default zoom_limits (controller=%s): %s ; zoom=%s", ctrl(player.controller_type),
    serpent.line(read(function() return player.zoom_limits end)), s(read(function() return player.zoom end)))

  -- 4. Zoom limits for the remote controller.
  local zok, zerr = pcall(player.set_zoom_limits, defines.controllers.remote, REMOTE_ZOOM_LIMITS)
  L("set_zoom_limits(remote, %s) ok=%s err=%s", serpent.line(REMOTE_ZOOM_LIMITS), s(zok), s(zerr))
  L("zoom_limits now (controller=%s): %s ; zoom=%s render_mode=%s", ctrl(player.controller_type),
    serpent.line(read(function() return player.zoom_limits end)), s(read(function() return player.zoom end)),
    RENDER_NAME[player.render_mode] or s(player.render_mode))
  st.initial_zoom = read(function() return player.zoom end)

  st.in_setup = false
  st.setup_done = true
  st.join_tick = game.tick

  -- 5. Cursor, GUI, instructions.
  give_cursor(player, "setup/" .. reason, false)
  build_gui(player)
  print_help(player)
end

---------------------------------------------------------------------------
-- Scenario setup
---------------------------------------------------------------------------
local function configure_freeplay()
  local ifaces = {}
  for name in pairs(remote.interfaces) do ifaces[#ifaces + 1] = name end
  table.sort(ifaces)
  L("remote interfaces at on_init: %s", table.concat(ifaces, ", "))
  if not remote.interfaces.freeplay then return end
  -- Created/respawn items emptied so freeplay never inserts into a characterless player.
  local calls = {
    {"set_disable_crashsite", true},
    {"set_skip_intro", true},
    {"set_created_items", {}},
    {"set_respawn_items", {}},
  }
  for _, c in ipairs(calls) do
    local ok, err = pcall(remote.call, "freeplay", c[1], c[2])
    L("remote.call(freeplay, %s) ok=%s err=%s", c[1], s(ok), s(err))
  end
end

local function spawn_units()
  local surface = game.surfaces.nauvis or game.surfaces[1]
  surface.request_to_generate_chunks(UNIT_SPAWN_CENTER, 2)
  surface.force_generate_chunk_requests()
  local made = 0
  for i = 0, 9 do
    local want = {x = UNIT_SPAWN_CENTER.x + (i % 5) * 2, y = UNIT_SPAWN_CENTER.y + math.floor(i / 5) * 2}
    local p = surface.find_non_colliding_position("small-biter", want, 10, 0.5)
    if p then
      local e = surface.create_entity{name = "small-biter", position = p, force = "player"}
      if e then made = made + 1 end
    end
  end
  local car_pos = surface.find_non_colliding_position("car", {x = UNIT_SPAWN_CENTER.x - 6, y = UNIT_SPAWN_CENTER.y}, 10, 0.5)
  local car = car_pos and surface.create_entity{name = "car", position = car_pos, force = "player"}
  L("spawned %d small-biters (force=player) near %s and car=%s on %s at tick %d",
    made, pos(UNIT_SPAWN_CENTER), s(car ~= nil), surface.name, game.tick)
end

---------------------------------------------------------------------------
-- Events: lifecycle
---------------------------------------------------------------------------
L("control.lua loaded")

script.on_init(safe("on_init", function()
  init_storage()
  local mods = {}
  for name, version in pairs(script.active_mods) do mods[#mods + 1] = name .. "@" .. version end
  table.sort(mods)
  L("on_init tick=%d active_mods=%s", game.tick, table.concat(mods, ", "))
  configure_freeplay()
  local surface = game.surfaces.nauvis or game.surfaces[1]
  surface.peaceful_mode = true
  L("peaceful_mode on %s = %s", surface.name, s(surface.peaceful_mode))
end))

script.on_configuration_changed(safe("on_configuration_changed", function()
  init_storage()
  L("on_configuration_changed tick=%d", game.tick)
end))

script.on_event(defines.events.on_player_created, safe("on_player_created", function(e)
  init_storage()
  local player = game.get_player(e.player_index)
  L("EVENT on_player_created player=%d tick=%d", e.player_index, e.tick)
  setup_player(player, "created")
end))

script.on_event(defines.events.on_player_joined_game, safe("on_player_joined_game", function(e)
  init_storage()
  local player = game.get_player(e.player_index)
  local st = pstate(player)
  L("EVENT on_player_joined_game player=%d tick=%d setup_done=%s controller=%s",
    e.player_index, e.tick, s(st.setup_done), ctrl(player.controller_type))
  if not st.setup_done or player.character then
    setup_player(player, "joined")
  else
    if player.controller_type ~= desired_type(st) then reapply(player, "joined") end
    st.join_tick = game.tick
    give_cursor(player, "joined", false)
    build_gui(player)
    print_help(player)
  end
end))

script.on_event(defines.events.on_player_respawned, safe("on_player_respawned", function(e)
  local player = game.get_player(e.player_index)
  L("EVENT on_player_respawned (unexpected) player=%d controller=%s character=%s",
    e.player_index, ctrl(player.controller_type), s(player.character ~= nil))
  setup_player(player, "respawned")
end))

script.on_event(defines.events.on_player_controller_changed, safe("on_player_controller_changed", function(e)
  local player = game.get_player(e.player_index)
  local st = pstate(player)
  local now = player.controller_type
  L("EVENT on_player_controller_changed old=%s new=%s physical=%s desired=%s in_setup=%s position=%s",
    ctrl(e.old_type), ctrl(now), ctrl(player.physical_controller_type), st.desired, s(st.in_setup), pos(player.position))
  if now ~= desired_type(st) and not st.in_setup then
    L("CONTROLLER CHANGED (event): %s -> %s while desired=%s; re-applying next tick", ctrl(e.old_type), ctrl(now), st.desired)
    storage.pending_reapply[player.index] = game.tick + 1
  end
  -- set_controller{god} creates a fresh god controller with an empty cursor (GUI run 2026-10-15).
  if st.setup_done and cursor_str(player) == "empty" then give_cursor(player, "after controller change", false) end
end))

---------------------------------------------------------------------------
-- Events: cursor and selection (spike #2)
---------------------------------------------------------------------------
script.on_event(defines.events.on_player_cursor_stack_changed, safe("on_player_cursor_stack_changed", function(e)
  local player = game.get_player(e.player_index)
  local st = storage.players and storage.players[player.index]
  local now = cursor_str(player)
  L("EVENT on_player_cursor_stack_changed cursor=%s controller=%s", now, ctrl(player.controller_type))
  if st and st.setup_done and now == "empty" and not st.giving then
    st.giving = true
    give_cursor(player, "re-insert after cursor emptied", false)
    st.giving = false
  end
end))

local function selection_handler(kind)
  return safe(kind, function(e)
    local player = game.get_player(e.player_index)
    local names = {}
    for i = 1, math.min(#e.entities, 8) do
      local ent = e.entities[i]
      names[#names + 1] = ent.valid and (ent.type .. ":" .. ent.name .. "@" .. ent.force.name) or "invalid"
    end
    local a = e.area
    local center = {x = (a.left_top.x + a.right_bottom.x) / 2, y = (a.left_top.y + a.right_bottom.y) / 2}
    L("SELECT %s item=%s area=%s center=%s entities=%d [%s] tiles=%d surface=%s controller=%s quality=%s",
      kind, s(e.item), area_str(a), pos(center), #e.entities, table.concat(names, ", "), #e.tiles,
      e.surface and e.surface.name or "nil", ctrl(player.controller_type), s(e.quality))
    player.print(string.format("[rts] %s: %d entities, area %s (tick %d)", kind, #e.entities, area_str(a), e.tick))
  end)
end

script.on_event(defines.events.on_player_selected_area, selection_handler("on_player_selected_area"))
script.on_event(defines.events.on_player_alt_selected_area, selection_handler("on_player_alt_selected_area"))
script.on_event(defines.events.on_player_reverse_selected_area, selection_handler("on_player_reverse_selected_area"))
script.on_event(defines.events.on_player_alt_reverse_selected_area, selection_handler("on_player_alt_reverse_selected_area"))

script.on_event(defines.events.on_selected_entity_changed, safe("on_selected_entity_changed", function(e)
  local player = game.get_player(e.player_index)
  local sel = player.selected
  if sel then
    L("HOVER selected=%s:%s at %s controller=%s", sel.type, sel.name, pos(sel.position), ctrl(player.controller_type))
  end
end))

---------------------------------------------------------------------------
-- Events: custom inputs (spike #2)
---------------------------------------------------------------------------
local INPUTS = {
  "rts-give-cursor", "rts-rclick", "rts-rclick-consuming", "rts-lclick", "rts-cg-1", "rts-recall-1",
  "rts-toggle-controller", "rts-linked-toggle-map", "rts-linked-clear-cursor",
}

local function on_custom_input(e)
  local player = game.get_player(e.player_index)
  local el = e.element
  L("INPUT %s tick=%d cursor_position=%s cursor_display_location=%s in_gui=%s element=%s selected_prototype=%s controller=%s render_mode=%s cursor=%s",
    e.input_name, e.tick, pos(e.cursor_position), loc(e.cursor_display_location), s(e.in_gui),
    el and el.valid and (el.type .. ":" .. el.name) or "nil", sel_proto(e.selected_prototype),
    ctrl(player.controller_type), RENDER_NAME[player.render_mode] or s(player.render_mode), cursor_str(player))
  if e.input_name == "rts-lclick" or e.input_name == "rts-rclick" then
    -- Keep chat readable: only echo clicks, keys are echoed below.
    player.print(string.format("[rts] %s at %s (gui=%s, tick %d)", e.input_name, pos(e.cursor_position), s(e.in_gui), e.tick))
  else
    player.print(string.format("[rts] input %s (tick %d)", e.input_name, e.tick))
  end
  if e.input_name == "rts-give-cursor" then
    give_cursor(player, "F1", true)
  elseif e.input_name == "rts-toggle-controller" then
    toggle_controller(player, "F2")
  end
end

for _, name in ipairs(INPUTS) do
  script.on_event(name, safe("input " .. name, on_custom_input))
end

script.on_event(defines.events.on_lua_shortcut, safe("on_lua_shortcut", function(e)
  L("EVENT on_lua_shortcut %s", s(e.prototype_name))
end))

---------------------------------------------------------------------------
-- Events: GUI (spike #6)
---------------------------------------------------------------------------
local function el_str(el)
  if not (el and el.valid) then return "nil" end
  return el.type .. ":" .. el.name
end

script.on_event(defines.events.on_gui_click, safe("on_gui_click", function(e)
  local player = game.get_player(e.player_index)
  L("GUI_CLICK element=%s button=%s alt=%s control=%s shift=%s cursor_display_location=%s controller=%s",
    el_str(e.element), MOUSE_NAME[e.button] or s(e.button), s(e.alt), s(e.control), s(e.shift),
    loc(e.cursor_display_location), ctrl(player.controller_type))
  player.print(string.format("[rts] on_gui_click %s button=%s (tick %d)", el_str(e.element), MOUSE_NAME[e.button] or s(e.button), e.tick))
end))

script.on_event(defines.events.on_gui_hover, safe("on_gui_hover", function(e)
  L("GUI_HOVER element=%s", el_str(e.element))
end))

script.on_event(defines.events.on_gui_leave, safe("on_gui_leave", function(e)
  L("GUI_LEAVE element=%s", el_str(e.element))
end))

---------------------------------------------------------------------------
-- Tick: unit spawn, deferred re-apply, status log, screenshots, self-tests
---------------------------------------------------------------------------
local function screenshot(player, label)
  local path = "rts-camera-" .. game.tick .. (label ~= "" and ("-" .. label) or "") .. ".png"
  -- take_screenshot renders at its own zoom (default 1), not the player's; "playerzoom" passes player.zoom.
  local zoom = (label == "playerzoom") and read(function() return player.zoom end) or nil
  local ok, err = pcall(game.take_screenshot, {
    player = player, by_player = player, path = path, resolution = {1280, 800},
    show_gui = true, force_render = true, zoom = (type(zoom) == "number") and zoom or nil,
  })
  L("SCREENSHOT %s ok=%s err=%s controller=%s position=%s", path, s(ok), s(err),
    ctrl(player.controller_type), pos(player.position))
end

local function status(player, st)
  local sel = player.selected
  L("STATUS tick=%d rel=%d player=%d controller=%s physical=%s desired=%s position=%s physical_position=%s character=%s render_mode=%s zoom=%s surface=%s cursor=%s selected=%s",
    game.tick, game.tick - st.join_tick, player.index, ctrl(player.controller_type),
    ctrl(player.physical_controller_type), st.desired, pos(player.position), pos(player.physical_position),
    s(player.character ~= nil), RENDER_NAME[player.render_mode] or s(player.render_mode),
    s(read(function() return string.format("%.3f", player.zoom) end)), player.surface.name, cursor_str(player),
    sel and (sel.type .. ":" .. sel.name) or "nil")
end

local function run_selftests(player, st, rel)
  if SHOT_TICKS[rel] then screenshot(player, SHOT_TICKS[rel]) end
  if rel == SELFTEST.EXIT_REMOTE then
    local ok, res = pcall(player.exit_remote_view)
    L("SELFTEST exit_remote_view() ok=%s result=%s -> controller=%s", s(ok), s(res), ctrl(player.controller_type))
  elseif rel == SELFTEST.ZOOM_GAME then
    player.zoom = 0.2
    L("SELFTEST zoom := 0.2 -> zoom=%s render_mode=%s", s(read(function() return player.zoom end)), RENDER_NAME[player.render_mode])
  elseif rel == SELFTEST.ZOOM_GAME_LOG or rel == SELFTEST.ZOOM_CHART_LOG then
    L("SELFTEST zoom check -> zoom=%s render_mode=%s", s(read(function() return player.zoom end)), RENDER_NAME[player.render_mode])
  elseif rel == SELFTEST.ZOOM_CHART then
    player.zoom = 0.08
    L("SELFTEST zoom := 0.08 -> zoom=%s render_mode=%s", s(read(function() return player.zoom end)), RENDER_NAME[player.render_mode])
  elseif rel == SELFTEST.ZOOM_RESET then
    player.zoom = (type(st.initial_zoom) == "number") and st.initial_zoom or 1
    L("SELFTEST zoom reset -> zoom=%s render_mode=%s", s(read(function() return player.zoom end)), RENDER_NAME[player.render_mode])
  elseif rel == SELFTEST.TO_GOD then
    toggle_controller(player, "selftest")
  elseif rel == SELFTEST.GOD_SHOT then
    screenshot(player, "god")
  elseif rel == SELFTEST.TO_REMOTE then
    toggle_controller(player, "selftest")
  elseif rel == SELFTEST.DONE then
    L("SELFTEST done: controller=%s character=%s", ctrl(player.controller_type), s(player.character ~= nil))
  end
end

script.on_event(defines.events.on_tick, safe("on_tick", function(e)
  if not storage.players then init_storage() end
  if not storage.spawned then
    storage.spawned = true
    spawn_units()
  end

  for index, due in pairs(storage.pending_reapply) do
    if e.tick >= due then
      storage.pending_reapply[index] = nil
      local player = game.get_player(index)
      if player and player.connected then reapply(player, "event") end
    end
  end

  for _, player in pairs(game.connected_players) do
    local st = storage.players[player.index]
    if st and st.setup_done then
      if e.tick % 10 == 0 and player.controller_type == defines.controllers.remote then
        st.last_remote_pos = player.position
      end
      if e.tick % 60 == 0 then
        status(player, st)
        if player.controller_type ~= desired_type(st) then
          L("CONTROLLER CHANGED (watchdog): controller=%s desired=%s character=%s -- re-applying",
            ctrl(player.controller_type), st.desired, s(player.character ~= nil))
          reapply(player, "watchdog")
        end
      end
      run_selftests(player, st, e.tick - st.join_tick)
    end
  end

  if e.tick % 600 == 0 then
    L("HEARTBEAT tick=%d connected_players=%d", e.tick, #game.connected_players)
  end
end))
