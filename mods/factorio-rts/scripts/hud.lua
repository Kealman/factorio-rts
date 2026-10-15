-- HUD: three areas in player.gui.screen.
--   bottom-left   selection panel: count per kind, average health, current order, four command buttons,
--                 control-group indicators 1-5
--   top-centre    match strip: timer, own vs enemy unit counts, a message line for match events
--   top-right     minimap of the arena (directly on `screen`, over a decorative frame); a click jumps the
--                 camera there (camera.jump_to)
--
-- Owns storage.players[i].hud = {panel, strip, minimap_frame, minimap (LuaGuiElement), el = {...}, groups = {...}}
-- and storage.hud = {wave_seen, wave_tick, ended_tick} (match-event tracking shared by all players).
-- Reads storage.players[i].selection / .groups (selection.lua), storage.units (units.lua) and
-- storage.match (match.lua); never writes them.
--
-- selection.lua / orders.lua are looked up at call time through package.loaded, never require()d here:
-- require() is not allowed inside event handlers, and a top-level require would create a require cycle
-- when those modules want to call hud.refresh.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local camera = require("scripts.camera")

local hud = {}

local PLAYER, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE

-- Dev only. The HUD self-test steps are camera self-test steps (camera.add_selftest_step), so they run
-- only while camera.selftest_enabled() is true: off by default, `/rts-selftest on` turns it on and restarts
-- the steps for connected players. Ticks are counted from the player's camera setup:
--   540   presses "Select all" through the button path and assigns control group 1
--   600   screenshot rts-hud-<tick>.png
--   660   synthetic minimap click at the enemy spawn (the camera jumps there)
--   720   screenshot
--   780   camera home
--   3000  screenshot, then the "RTS_HUD_DONE" marker
-- HUD_CALIBRATE (a load-time constant): at setup + 180 adds chart tags A, B, C at (-64,-64), (64,-64),
-- (-64,64) and O at (0,0), to measure the minimap scale from a screenshot (docs/qa/phase1-hud-notes.md).
local HUD_CALIBRATE = false

local REFRESH_PERIOD = 30          -- ticks; fallback refresh (counts, dead units, timer)
local WAVE_ALERT_TICKS = 10 * 60   -- how long "wave N is attacking" stays on the message line

-- Layout, in GUI units (multiplied by player.display_scale on screen).
local MARGIN = 8
local PANEL_WIDTH, PANEL_HEIGHT = 420, 122
local STRIP_WIDTH, STRIP_HEIGHT = 420, 64
local MINIMAP_SIZE = 220
local MINIMAP_PADDING = 4          -- rim of the decorative frame drawn behind the minimap
local MINIMAP_FRAME_SIZE = MINIMAP_SIZE + 2 * MINIMAP_PADDING

-- Minimap scale. MINIMAP_PX_PER_TILE_AT_ZOOM_1 is GUI pixels per tile at minimap zoom 1, measured from
-- screenshots (docs/qa/phase1-hud-notes.md). The zoom is chosen so the 160-tile arena plus a rim fits.
local ARENA_HALF = 80
local MINIMAP_CENTER = {x = 0, y = 0}
local MINIMAP_VIEW_TILES = 2 * ARENA_HALF + 16
local MINIMAP_PX_PER_TILE_AT_ZOOM_1 = 1.0
local MINIMAP_ZOOM = MINIMAP_SIZE / (MINIMAP_VIEW_TILES * MINIMAP_PX_PER_TILE_AT_ZOOM_1) -- 1.25

local NAMES = {panel = "rts_hud_panel", strip = "rts_hud_strip", minimap_frame = "rts_hud_minimap_frame",
               minimap = "rts_hud_minimap"}
local PREFIX = "rts_hud_"          -- every clickable HUD element's name starts with this

local KIND_NAMES = {walker = "Walker", heavy = "Heavy"}
local KIND_RANK = {walker = 1, heavy = 2}
local ORDER_NAMES = {idle = "Idle", move = "Move", attack = "Attack", attack_move = "Attack-move", hold = "Hold"}

local COLOR = {
  white = {1, 1, 1},
  yellow = {1, 0.85, 0.3},
  red = {1, 0.42, 0.36},
  green = {0.5, 1, 0.5},
  own = {0.5, 0.72, 1},
  enemy = {1, 0.5, 0.45},
}

-- Command buttons. Each calls the first of module[fns[i]](player_index) that exists at click time.
local COMMANDS = {
  {action = "attack_move", caption = "Attack-move", key = "F", module = "scripts.orders",
   fns = {"arm_attack_move"},
   tooltip = "Attack-move: the next right click sends the selection there, fighting every enemy on the way."},
  {action = "stop", caption = "Stop", key = "X", module = "scripts.orders", fns = {"stop"},
   tooltip = "Stop: cancel the current orders. Units still return fire."},
  {action = "hold", caption = "Hold", key = "H", module = "scripts.orders", fns = {"hold"},
   tooltip = "Hold position: stay put and fire at enemies in range."},
  {action = "select_all", caption = "Select all", key = "Ctrl+A", module = "scripts.selection", fns = {"select_all"},
   tooltip = "Select your whole army."},
}
local COMMAND_BY_ACTION = {}
for _, c in pairs(COMMANDS) do COMMAND_BY_ACTION[c.action] = c end
local GROUP_COUNT = 5

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- The first of `fn_names` exported by an already-loaded module, or nil. Safe inside event handlers.
--- package.loaded is keyed by the resolved file, "__factorio-rts__/scripts/orders.lua", not by the
--- require() argument "scripts.orders" (logged on 2.0.77); both keys are tried.
local function optional_fn(module_name, fn_names)
  local loaded = package and package.loaded
  if not loaded then return nil end
  local mod = loaded["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"]
    or loaded[module_name]
  if type(mod) ~= "table" then return nil end
  for _, name in ipairs(fn_names) do
    if type(mod[name]) == "function" then return mod[name] end
  end
  return nil
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function count_force(force_name)
  if not storage.units then return 0 end
  return units.count(force_name)
end

--- The live registry record of a unit, without side effects (units.get would drop stale records and
--- fire on_removed callbacks while we iterate another module's set).
local function live_record(unit_number)
  local rec = storage.units and storage.units[unit_number]
  if rec and rec.entity and rec.entity.valid then return rec end
  return nil
end

local function live_count(set)
  local n = 0
  if set then
    for un in pairs(set) do
      if live_record(un) then n = n + 1 end
    end
  end
  return n
end

local function pstate(player_index)
  return storage.players and storage.players[player_index]
end

--- The player's HUD state if all three frames are alive, else nil.
local function get_hud(player)
  local p = pstate(player.index)
  local h = p and p.hud
  if h and h.panel and h.panel.valid and h.strip and h.strip.valid and h.minimap_frame and h.minimap_frame.valid
     and h.minimap and h.minimap.valid then
    return h
  end
  return nil
end

---------------------------------------------------------------------------
-- Minimap maths
--
-- Screen (display) coordinates are physical pixels, the same space as GuiLocation and
-- cursor_display_location. GUI sizes are scaled by player.display_scale. The minimap element sits
-- directly in player.gui.screen, so its `location` is its own top-left corner (inside a frame, the
-- content offset did not match the frame's padding: ~8.7 GUI px measured with padding 4). It shows
-- `zoom * K * scale` physical pixels per tile around `position` (K = MINIMAP_PX_PER_TILE_AT_ZOOM_1).
---------------------------------------------------------------------------
local function minimap_geometry(player, h)
  local s = player.display_scale
  local loc = h.minimap.location or {x = 0, y = 0}
  local size = MINIMAP_SIZE * s
  local cx = (loc.x or loc[1]) + size / 2
  local cy = (loc.y or loc[2]) + size / 2
  local ppt = MINIMAP_PX_PER_TILE_AT_ZOOM_1 * h.minimap.zoom * s -- physical pixels per tile
  return cx, cy, ppt, size
end

--- World position under a display location on the minimap.
local function minimap_to_world(player, h, display)
  local cx, cy, ppt = minimap_geometry(player, h)
  local center = h.minimap.position
  local dx, dy = (display.x or display[1]) - cx, (display.y or display[2]) - cy
  return {x = center.x + dx / ppt, y = center.y + dy / ppt}, dx, dy
end

--- Display location of a world position on the minimap (inverse of minimap_to_world).
local function world_to_minimap(player, h, position)
  local cx, cy, ppt = minimap_geometry(player, h)
  local center = h.minimap.position
  local x, y = util.xy(position)
  return {x = math.floor(cx + (x - center.x) * ppt + 0.5), y = math.floor(cy + (y - center.y) * ppt + 0.5)}
end

---------------------------------------------------------------------------
-- Building and placement
---------------------------------------------------------------------------
local function place(player, h)
  local res, s = player.display_resolution, player.display_scale
  local m = math.floor(MARGIN * s + 0.5)
  h.panel.location = {m, res.height - math.floor(PANEL_HEIGHT * s + 0.5) - m}
  h.strip.location = {math.floor((res.width - STRIP_WIDTH * s) / 2 + 0.5), m}
  local pad = math.floor(MINIMAP_PADDING * s + 0.5)
  local mx = res.width - math.floor(MINIMAP_SIZE * s + 0.5) - pad - m
  h.minimap.location = {mx, m + pad}
  h.minimap_frame.location = {mx - pad, m}
end

local function add_filler(parent)
  return parent.add({type = "empty-widget", style = "rts_hud_filler"})
end

local function build_panel(screen, h)
  local panel = screen.add({type = "frame", name = NAMES.panel, direction = "vertical", style = "rts_hud_frame"})
  panel.style.width = PANEL_WIDTH
  panel.style.height = PANEL_HEIGHT
  h.panel = panel
  local el = h.el

  local header = panel.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.sel_count = header.add({type = "label", style = "rts_hud_heading_label"})
  add_filler(header)
  el.health = header.add({type = "label", style = "rts_hud_mono_label", tooltip = "Average health of the selection"})
  el.order = header.add({type = "label", style = "rts_hud_label", tooltip = "Current order of the selection"})

  el.kinds = panel.add({type = "label", style = "rts_hud_label"})

  local commands = panel.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  for _, c in ipairs(COMMANDS) do
    el["cmd_" .. c.action] = commands.add({
      type = "button", name = PREFIX .. "cmd_" .. c.action, style = "rts_hud_button",
      caption = string.format("%s [%s]", c.caption, c.key),
      tooltip = string.format("%s (%s)\n%s", c.caption, c.key, c.tooltip),
      tags = {rts_hud = c.action}})
  end

  local groups = panel.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  groups.add({type = "label", style = "rts_hud_dim_label", caption = "Groups"})
  for n = 1, GROUP_COUNT do
    h.groups[n] = groups.add({type = "button", name = PREFIX .. "group_" .. n, style = "rts_hud_group_button",
                              caption = tostring(n), tags = {rts_hud = "group", group = n}})
  end
end

local function build_strip(screen, h)
  local strip = screen.add({type = "frame", name = NAMES.strip, direction = "vertical", style = "rts_hud_frame"})
  strip.style.width = STRIP_WIDTH
  strip.style.height = STRIP_HEIGHT
  h.strip = strip
  local el = h.el
  local row = strip.add({type = "flow", direction = "horizontal", style = "rts_hud_centered_row"})
  el.timer = row.add({type = "label", style = "rts_hud_timer_label", caption = "--:--", tooltip = "Match time"})
  el.own = row.add({type = "label", style = "rts_hud_mono_label", tooltip = "Your units"})
  el.own.style.font_color = COLOR.own
  row.add({type = "label", style = "rts_hud_dim_label", caption = "vs"})
  el.enemy = row.add({type = "label", style = "rts_hud_mono_label", tooltip = "Enemy units"})
  el.enemy.style.font_color = COLOR.enemy
  local message_row = strip.add({type = "flow", direction = "horizontal", style = "rts_hud_centered_row"})
  el.message = message_row.add({type = "label", style = "rts_hud_message_label"})
end

-- The minimap is a direct child of `screen` (exact location for the click maths), added after its
-- decorative frame so it is drawn on top of it.
local function build_minimap(screen, h)
  local frame = screen.add({type = "frame", name = NAMES.minimap_frame, style = "rts_hud_minimap_frame",
                            ignored_by_interaction = true})
  frame.style.width = MINIMAP_FRAME_SIZE
  frame.style.height = MINIMAP_FRAME_SIZE
  h.minimap_frame = frame
  local mm = screen.add({type = "minimap", name = NAMES.minimap, style = "rts_hud_minimap",
                         position = MINIMAP_CENTER, zoom = MINIMAP_ZOOM, surface_index = util.surface().index,
                         tags = {rts_hud = "minimap"}})
  mm.style.width = MINIMAP_SIZE
  mm.style.height = MINIMAP_SIZE
  mm.bring_to_front()
  h.minimap = mm
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function sorted_kinds(kinds)
  local list = {}
  for k in pairs(kinds) do list[#list + 1] = k end
  table.sort(list, function(a, b)
    local ra, rb = KIND_RANK[a] or 99, KIND_RANK[b] or 99
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return list
end

local function order_text(orders, n)
  local list = {}
  for o, c in pairs(orders) do list[#list + 1] = {o, c} end
  table.sort(list, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[1] < b[1]
  end)
  if #list == 0 then return "" end
  local function name(o) return ORDER_NAMES[o] or o end
  if #list == 1 then return name(list[1][1]) end
  return string.format("%s %d, %s %d%s", name(list[1][1]), list[1][2], name(list[2][1]), list[2][2],
    #list > 2 and ", ..." or "")
end

local function update_selection(player, h)
  local el = h.el
  local p = pstate(player.index)
  local selection = p and p.selection
  local n, kinds, orders, health_sum, health_n = 0, {}, {}, 0, 0
  if selection then
    for un in pairs(selection) do
      local rec = live_record(un)
      if rec then
        n = n + 1
        local kind = rec.kind or "?"
        kinds[kind] = (kinds[kind] or 0) + 1
        local order = rec.order or units.IDLE
        orders[order] = (orders[order] or 0) + 1
        local ratio = rec.entity.get_health_ratio()
        if ratio then
          health_sum, health_n = health_sum + ratio, health_n + 1
        end
      end
    end
  end

  if n == 0 then
    el.sel_count.caption = "No units selected"
    el.kinds.caption = "Left-drag to select. Shift adds."
    el.kinds.style.font_color = {0.72, 0.72, 0.72}
    el.health.caption = ""
    el.order.caption = ""
    return n
  end

  el.sel_count.caption = string.format("%d %s selected", n, n == 1 and "unit" or "units")
  local parts = {}
  for _, kind in ipairs(sorted_kinds(kinds)) do
    parts[#parts + 1] = string.format("%s ×%d", KIND_NAMES[kind] or kind, kinds[kind])
  end
  el.kinds.caption = table.concat(parts, "   ")
  el.kinds.style.font_color = COLOR.white
  if health_n > 0 then
    local avg = health_sum / health_n
    el.health.caption = string.format("HP %3d%%", math.floor(avg * 100 + 0.5))
    el.health.style.font_color = avg >= 0.66 and COLOR.green or (avg >= 0.33 and COLOR.yellow or COLOR.red)
  else
    el.health.caption = ""
  end
  el.order.caption = "Order: " .. order_text(orders, n)
  return n
end

local function same_set(a, b)
  for un in pairs(a) do
    if live_record(un) and not b[un] then return false end
  end
  for un in pairs(b) do
    if live_record(un) and not a[un] then return false end
  end
  return true
end

local function update_groups(player, h)
  local p = pstate(player.index)
  local groups = p and p.groups
  local selection = p and p.selection
  for n = 1, GROUP_COUNT do
    local button = h.groups[n]
    local set = groups and groups[n]
    local count = live_count(set)
    if count > 0 then
      button.caption = string.format("%d: %d", n, count)
      button.tooltip = string.format("Control group %d: %d units.\n%d recalls it, Ctrl+%d assigns the selection.",
        n, count, n, n)
      button.toggled = selection ~= nil and next(selection) ~= nil and same_set(set, selection)
    else
      button.caption = tostring(n)
      button.tooltip = string.format("Control group %d is empty.\nCtrl+%d assigns the selection.", n, n)
      button.toggled = false
    end
    button.enabled = count > 0
  end
end

--- Notice wave launches and the end of the match (storage.match has no tick for either).
local function track_match()
  local m, hs = storage.match, storage.hud
  if not (m and hs) then return end
  local wave = m.wave or 0
  if wave ~= hs.wave_seen then
    if wave > (hs.wave_seen or 0) then hs.wave_tick = game.tick end
    hs.wave_seen = wave
  end
  if m.phase == "ended" then
    hs.ended_tick = hs.ended_tick or game.tick
  else
    hs.ended_tick = nil
  end
end

local function match_message(m, own)
  if not (m and m.phase) or m.phase == "setup" then return "Preparing the arena...", COLOR.yellow end
  if m.phase == "ended" then
    if m.winner == own then return "Victory! The enemy army is destroyed.", COLOR.green end
    if m.winner == "draw" then return "Draw: both armies are destroyed.", COLOR.yellow end
    return "Defeat. Your army is destroyed.", COLOR.red
  end
  local hs = storage.hud
  if (m.wave or 0) > 0 and hs and hs.wave_tick and game.tick - hs.wave_tick < WAVE_ALERT_TICKS then
    return string.format("Enemy wave %d is attacking!", m.wave), COLOR.red
  end
  if m.enemy_next_wave then
    return string.format("Enemy wave %d in %s", (m.wave or 0) + 1, clock((m.enemy_next_wave - game.tick) / 60)),
      COLOR.yellow
  end
  if m.waves_off then return "Enemy waves off (/rts-qa-reset nowaves)", COLOR.yellow end
  return "Destroy the enemy army.", COLOR.yellow
end

local function update_strip(player, h)
  local el = h.el
  local m = storage.match
  local hs = storage.hud or {}
  if m and m.tick_started then
    local now = (m.phase == "ended" and hs.ended_tick) or game.tick
    el.timer.caption = clock((now - m.tick_started) / 60)
  else
    el.timer.caption = "--:--"
  end
  local own = player.force.name
  local enemy = own == ENEMY and PLAYER or ENEMY
  el.own.caption = string.format("Army %d", count_force(own))
  el.enemy.caption = string.format("%d Enemy", count_force(enemy))
  local text, color = match_message(m, own)
  el.message.caption = text
  el.message.style.font_color = color
end

local function update_commands(player, h)
  local is_armed = optional_fn("scripts.orders", {"is_armed"})
  h.el.cmd_attack_move.toggled = is_armed ~= nil and is_armed(player.index) == true
end

local function update(player, h)
  track_match()
  update_selection(player, h)
  update_commands(player, h)
  update_groups(player, h)
  update_strip(player, h)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Destroy the player's HUD frames.
function hud.destroy(player)
  local screen = player.gui.screen
  for _, key in pairs({"panel", "strip", "minimap_frame", "minimap"}) do
    local frame = screen[NAMES[key]]
    if frame then frame.destroy() end
  end
  local p = pstate(player.index)
  if p then p.hud = nil end
end

--- (Re)build the player's HUD from scratch. Idempotent.
function hud.build(player)
  hud.destroy(player)
  local screen = player.gui.screen
  local h = {el = {}, groups = {}}
  build_panel(screen, h)
  build_strip(screen, h)
  build_minimap(screen, h)
  util.pstorage(player.index).hud = h
  place(player, h)
  update(player, h)
  local res = player.display_resolution
  util.log("hud: built for player %d (display %dx%d, scale %.2f, density %.2f; minimap zoom %.4f, "
    .. "%.2f px/tile at scale 1)", player.index, res.width, res.height, player.display_scale,
    player.display_density_scale, MINIMAP_ZOOM, MINIMAP_ZOOM * MINIMAP_PX_PER_TILE_AT_ZOOM_1)
  return h
end

--- Update the player's HUD now (selection.lua calls this after every selection change). Builds the HUD
--- when it is missing. Cheap: one pass over the selection and the unit registry.
function hud.refresh(player_index)
  local player = game.get_player(player_index)
  if not (player and player.connected) then return end
  local h = get_hud(player)
  if not h then
    hud.build(player)
    return
  end
  update(player, h)
end

function hud.init()
  storage.hud = storage.hud or {wave_seen = storage.match and storage.match.wave or 0}
  -- Every module is loaded by now: confirm the package.loaded lookups the buttons depend on.
  local found = {}
  for _, c in ipairs(COMMANDS) do
    found[#found + 1] = string.format("%s=%s", c.action, optional_fn(c.module, c.fns) and "ok" or "MISSING")
  end
  found[#found + 1] = "is_armed=" .. (optional_fn("scripts.orders", {"is_armed"}) and "ok" or "MISSING")
  found[#found + 1] = "group_recall=" .. (optional_fn("scripts.selection", {"group_recall"}) and "ok" or "MISSING")
  util.log("hud: module lookup %s", table.concat(found, " "))
  for _, player in pairs(game.players) do hud.build(player) end
end

---------------------------------------------------------------------------
-- Clicks
---------------------------------------------------------------------------
local function minimap_click(player, h, e, source)
  local world, dx, dy = minimap_to_world(player, h, e.cursor_display_location)
  local loc = h.minimap.location
  util.log("hud click minimap player=%d source=%s button=%s display=(%d, %d) minimap at (%d, %d) "
    .. "offset from centre=(%.1f, %.1f) px -> world %s", player.index, source,
    util.define_name(defines.mouse_button_type, e.button), e.cursor_display_location.x,
    e.cursor_display_location.y, loc.x, loc.y, dx, dy, util.pos_str(world))
  camera.jump_to(player, world)
  return world
end

local function run_command(player, action)
  local c = COMMAND_BY_ACTION[action]
  local fn = optional_fn(c.module, c.fns)
  if not fn then
    local wanted = c.module .. "." .. table.concat(c.fns, "/")
    player.print(string.format("[RTS] %s is not available yet (%s is missing).", c.caption, wanted))
    util.log("hud: button %s: %s missing", action, wanted)
    return
  end
  local result = fn(player.index)
  -- QA log line, one per button: "hud click attack-move|stop|hold|select-all player=N result=..."
  util.log("hud click %s player=%d result=%s", string.gsub(action, "_", "-"), player.index, tostring(result))
end

local function recall_group(player, n)
  local fn = optional_fn("scripts.selection", {"group_recall", "recall_group"})
  if not fn then
    player.print(string.format("[RTS] Control group %d: press %d to recall it.", n, n))
    return
  end
  local selected = fn(player.index, n)
  util.log("hud click group %d player=%d selected=%s", n, player.index, tostring(selected))
end

local function on_click(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local action = element.tags.rts_hud
  local player = game.get_player(e.player_index)
  local h = get_hud(player)
  if not (action and h) then return end
  if action == "minimap" then
    minimap_click(player, h, e, "mouse")
    return
  elseif action == "group" then
    recall_group(player, element.tags.group)
  elseif COMMAND_BY_ACTION[action] then
    run_command(player, action)
  end
  hud.refresh(player.index)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
events.on(defines.events.on_gui_click, on_click)

-- Registered after camera.lua's handlers (control.lua requires hud after camera), so the camera is set up first.
events.on(defines.events.on_player_created, function(e)
  hud.build(game.get_player(e.player_index))
end)

events.on(defines.events.on_player_joined_game, function(e)
  hud.build(game.get_player(e.player_index))
end)

-- display_resolution and display_scale are placeholders (1920x1080, 1) during on_player_created; these
-- events follow shortly after with the real values.
local function reposition(e)
  local player = game.get_player(e.player_index)
  local h = player and get_hud(player)
  if not h then return end
  place(player, h)
  local res = player.display_resolution
  util.log("hud: repositioned for player %d (display %dx%d, scale %.2f)", player.index, res.width, res.height,
    player.display_scale)
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

events.on_nth_tick(REFRESH_PERIOD, function()
  for _, player in pairs(game.connected_players) do hud.refresh(player.index) end
end)

---------------------------------------------------------------------------
-- Dev-only checks (self-test steps and HUD_CALIBRATE, see the top of this file)
---------------------------------------------------------------------------
local function screenshot(player)
  local path = string.format("rts-hud-%d.png", game.tick)
  local res = player.display_resolution
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {res.width, res.height}, position = player.position, zoom = player.zoom})
  local h = get_hud(player)
  local cx, cy, ppt = 0, 0, 0
  if h then cx, cy, ppt = minimap_geometry(player, h) end
  util.log("hud: screenshot %s at %s zoom %.3f; minimap centre at display (%.1f, %.1f), %.3f px/tile; "
    .. "own spawn -> %s, enemy spawn -> %s", path, util.pos_str(player.position), player.zoom, cx, cy, ppt,
    h and util.pos_str(world_to_minimap(player, h, {x = -50, y = 0})) or "-",
    h and util.pos_str(world_to_minimap(player, h, {x = 50, y = 0})) or "-")
end

local CALIBRATION_TAGS = {{x = -64, y = -64, text = "A"}, {x = 64, y = -64, text = "B"},
                          {x = -64, y = 64, text = "C"}, {x = 0, y = 0, text = "O"}}

local function add_calibration_tags()
  local force, surface = game.forces[PLAYER], util.surface()
  for _, t in pairs(CALIBRATION_TAGS) do
    local tag = force.add_chart_tag(surface, {position = {t.x, t.y}, text = t.text,
                                              icon = {type = "virtual", name = "signal-" .. t.text}})
    util.log("hud: calibration tag %s at %s: %s", t.text, util.pos_str(t), tostring(tag ~= nil))
  end
end

local function synthetic_click(player)
  local h = get_hud(player)
  if not h then return end
  local target = {x = 50, y = 0}
  local display = world_to_minimap(player, h, target)
  local world = minimap_click(player, h, {player_index = player.index, button = defines.mouse_button_type.left,
                                           cursor_display_location = display}, "synthetic")
  util.log("hud: synthetic click aimed at %s, round trip error %.2f tiles", util.pos_str(target),
    util.distance(world, target))
end

-- Self-test steps: camera.lua runs them `at` ticks after the player's setup, only while the self-test
-- switch is on (camera.selftest_enabled()). Registered at load time, identically on every load.
if HUD_CALIBRATE then
  camera.add_selftest_step(180, "hud_calibrate", function() add_calibration_tags() end)
end
camera.add_selftest_step(540, "hud_select_all_group1", function(player)
  run_command(player, "select_all")
  local group_set = optional_fn("scripts.selection", {"group_set"}) -- group 1 indicator: "1: 24", toggled
  if group_set then group_set(player.index, 1) end
  hud.refresh(player.index)
end)
camera.add_selftest_step(600, "hud_screenshot_600", screenshot)
camera.add_selftest_step(660, "hud_minimap_click", synthetic_click)
camera.add_selftest_step(720, "hud_screenshot_720", screenshot)
camera.add_selftest_step(780, "hud_home", function(player) camera.home(player) end)
camera.add_selftest_step(3000, "hud_done", function(player) -- about 5 s into the first enemy wave
  screenshot(player)
  util.log("RTS_HUD_DONE player %d", player.index)
end)

return hud
