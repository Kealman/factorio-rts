-- 0.1.1 (r2-ux, issue #12): the custom mouse inputs and the remote view on Factorio 2.1, GUI probe with REAL input.
-- A Skirmish match (lobby defaults: 1 opponent, normal, small) is played with real clicks, drags and keys from
-- tools/gui-drive.sh (the "RTS_DRIVE <n> <cmd> <args>" lines it logs; fdrive's click/rclick/drag take a modifier):
-- lobby Start, SPACE, box select, a click on empty ground, click select, Shift + click, Shift + drag (add),
-- right click (move), right click on an enemy (attack), F + right drag (attack-move), Shift + right drag and
-- Shift + right click (attack-move), a right click while D pans the camera, Ctrl+1 / 1 / double 1 (group, jump),
-- a click on the HUD minimap (jump), F10 menu and Escape, Escape with no panel open (the game menu, never a lost
-- remote view), the menu's Restart (back to the lobby), Start again and Ctrl+Shift+R (restart). Every real input is
-- checked a moment later ("r2i real <name>: PASS|FAIL ..."); on a miss the probe does the same thing through the
-- handler so the run goes on. A watcher logs every controller change ("r2i controller ...") and the last check
-- ("r2i check remote_never_left") fails if the player ever left the remote view.
-- Test copy (self-test off), RTS_LOCALE=en or ru:
--   rm -rf build/r2i-en && mkdir -p build/r2i-en && cp -R mods/factorio-rts mods/mod-list.json build/r2i-en/
--   cp tools/probes/r2_inputs_gui.lua build/r2i-en/factorio-rts/scripts/
--   printf '\nrequire("scripts.r2_inputs_gui")\n' >> build/r2i-en/factorio-rts/control.lua
--   tools/gui-drive.sh build/r2i-en-gui.log build/shots-r2i-en-window RTS_R2I_DONE &
--   RTS_LOCALE=en tools/gui-run.sh build/r2i-en 900 RTS_R2I_DONE '\[rts\] r2i|rror'
-- Check `pgrep -f '^/Users/.*/MacOS/factorio .*--window-size'` prints nothing first: the input goes to the front
-- window. Screenshots build/shots-r2i-<locale>/rts-r2i-<tag>.png (take_screenshot) and window captures (title bar
-- included, +28 px) in build/shots-r2i-<locale>-window/. The stop marker is RTS_R2I_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local units = require("scripts.units")
local buildings = require("scripts.buildings")

local E = "rts-ai-1"
-- macOS virtual key codes (tools/gui-input/fdrive.swift)
local KEY = {A = 0, D = 2, F = 3, X = 7, R = 15, ONE = 18, SPACE = 49, ESC = 53, F10 = 109}

local function note(fmt, ...) util.log("r2i probe: " .. fmt, ...) end
local function check(name, ok, fmt, ...)
  util.log("r2i check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function drive(fmt, ...)
  storage.r2i_seq = (storage.r2i_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.r2i_seq, ...)
end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end
local function click(player, el)
  if not (el and el.valid) then
    note("click: element missing")
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
  return true
end

local function shot(player, tag)
  local path = string.format("rts-r2i-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  note("screenshot %s at %s zoom %.3f", path, util.pos_str(player.position), player.zoom)
end

-- Screen point (game-area points of the 1280x800 window) of a map position in the current view, and back.
local function spx(player, pos)
  local k = 32 * player.zoom
  return math.floor(640 + (pos.x - player.position.x) * k + 0.5), math.floor(400 + (pos.y - player.position.y) * k + 0.5)
end
local function at_px(player, x, y)
  local k = 32 * player.zoom
  return {x = player.position.x + (x - 640) / k, y = player.position.y + (y - 400) / k}
end
-- A unit's click point: the middle of its selection box (spider units draw their body above their feet).
local function unit_px(player, e)
  local b = e.selection_box
  local c = {x = (b.left_top.x + b.right_bottom.x) / 2, y = (b.left_top.y + b.right_bottom.y) / 2}
  return spx(player, c)
end

local function walkers(F)
  local list = {}
  for _, rec in units.for_force(F) do
    if rec.kind == "walker" and rec.entity.valid then list[#list + 1] = rec.entity end
  end
  table.sort(list, function(a, b) return a.unit_number < b.unit_number end)
  return list
end
local function selected_set(player)
  local set, n = {}, 0
  for _, e in ipairs(selection.get(player.index)) do
    set[e.unit_number] = true
    n = n + 1
  end
  return set, n
end
local function issued(kind) return (orders.stats().issued or {})[kind] or 0 end
local function snapshot_stats()
  local s = orders.stats()
  return {move = issued("move"), attack = issued("attack"), attack_move = issued("attack_move"),
          area = s.area_orders or 0, fallbacks = s.fallbacks or 0}
end
local function diff_stats(a)
  local b = snapshot_stats()
  return string.format("move +%d, attack +%d, attack_move +%d, area events +%d, fallbacks +%d", b.move - a.move,
    b.attack - a.attack, b.attack_move - a.attack_move, b.area - a.area, b.fallbacks - a.fallbacks), b
end
local function remote(player) return player.controller_type == defines.controllers.remote end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end
local function snap(tag, wait)
  step(function(player)
    shot(player, tag)
    return wait or 15
  end)
end
local function capture(tag, wait)
  step(function()
    drive("capture r2i-%s", tag)
    return wait or 40
  end)
end
-- A real input, then (after `wait` ticks) its check; on a miss the fallback does it through the handler.
local function real(name, input, ok_fn, fallback, wait)
  step(function(player, P)
    P.before = snapshot_stats()
    P.left0 = P.left
    input(player, P)
    return math.max(wait or 60, 60) -- the driver sees a line within 0.2 s and brings the window to the front first
  end)
  step(function(player, P)
    local ok, detail = ok_fn(player, P)
    util.log("r2i real %s: %s %s", name, ok and "PASS" or "FAIL", tostring(detail or ""))
    if not ok and fallback then fallback(player, P) end
    return 30
  end)
end

---------------------------------------------------------------------------
-- Part A: the lobby, Start
---------------------------------------------------------------------------
snap("a01-lobby")
-- a first click on empty ground of the lobby surface: the window takes the focus with it (a first click into a window
-- that is not active yet was lost once)
step(function()
  drive("click 640 720")
  drive("sleep 400")
  return 60
end)
capture("a01-lobby")
real("lobby_start", function(player, P)
  P.match0 = storage.match.match_id
  drive("click %d %d", P.L.start[1], P.L.start[2])
end, function(player, P)
  return not match.in_lobby() and remote(player), string.format("in lobby %s, controller %s", tostring(match.in_lobby()),
    util.define_name(defines.controllers, player.controller_type))
end, function(player) click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start")) end, 300)
step(function(player, P)
  P.F = player.force.name
  P.home = match.home(P.F)
  P.cc = buildings.main_cc(P.F).entity
  local res = player.display_resolution
  P.k = res.width / 1280 -- display pixels per window point
  note("match %d, home %s, display %dx%d scale %.2f, %d walkers", storage.match.match_id, util.pos_str(P.home),
    res.width, res.height, player.display_scale, #walkers(P.F))
  -- the camera off home, so SPACE has something to do
  camera.jump_to(player, {x = P.home.x + 30, y = P.home.y + 20})
  return 30
end)
real("space_home", function() drive("key %d", KEY.SPACE) end, function(player, P)
  local d = util.distance(player.position, P.home)
  return d < 2 and remote(player), string.format("camera %s, home %s, %.1f tiles", util.pos_str(player.position),
    util.pos_str(P.home), d)
end, function(player) camera.home(player) end, 40)
snap("a02-match")
capture("a02-match")

---------------------------------------------------------------------------
-- Part B: selection
---------------------------------------------------------------------------
-- the camera on the walkers at zoom 0.5 (16 px per tile)
step(function(player, P)
  P.walkers = walkers(P.F)
  local c = util.centroid(P.walkers) or P.home
  camera.jump_to(player, c)
  player.zoom = 0.5
  return 30
end)
real("box_select", function(player, P)
  local x1, y1, x2, y2 = 1280, 800, 0, 0
  for _, e in ipairs(P.walkers) do
    local b = e.selection_box
    local ax, ay = spx(player, b.left_top)
    local bx, by = spx(player, b.right_bottom)
    x1, y1, x2, y2 = math.min(x1, ax), math.min(y1, ay), math.max(x2, bx), math.max(y2, by)
  end
  P.box = {x1 - 12, y1 - 12, x2 + 12, y2 + 12}
  drive("drag %d %d %d %d left", P.box[1], P.box[2], P.box[3], P.box[4])
end, function(player, P)
  local set, n = selected_set(player)
  local hit = 0
  for _, e in ipairs(P.walkers) do if set[e.unit_number] then hit = hit + 1 end end
  return hit == #P.walkers and #P.walkers > 0, string.format("%d of %d walkers, %d selected, box (%d, %d)-(%d, %d)", hit,
    #P.walkers, n, P.box[1], P.box[2], P.box[3], P.box[4])
end, function(player, P) selection.set(player.index, P.walkers) end, 120)
snap("b01-box-selected")
-- a click on empty ground below the walkers deselects
real("click_empty", function(player, P)
  P.empty = {640, math.min(760, P.box[4] + 120)}
  drive("click %d %d", P.empty[1], P.empty[2])
end, function(player)
  local _, n = selected_set(player)
  return n == 0, n .. " selected"
end, function(player) selection.clear(player.index) end, 60)
real("click_select", function(player, P)
  local x, y = unit_px(player, P.walkers[1])
  drive("click %d %d", x, y)
end, function(player, P)
  local set, n = selected_set(player)
  return n == 1 and set[P.walkers[1].unit_number] ~= nil, n .. " selected"
end, function(player, P) selection.set(player.index, {P.walkers[1]}) end, 40)
real("shift_click_add", function(player, P)
  local x, y = unit_px(player, P.walkers[2])
  drive("click %d %d shift", x, y)
end, function(player, P)
  local set, n = selected_set(player)
  return n == 2 and set[P.walkers[2].unit_number] ~= nil, n .. " selected"
end, function(player, P) selection.add(player.index, {P.walkers[2]}) end, 40)
real("shift_drag_add", function(player, P)
  drive("drag %d %d %d %d left shift", P.box[1], P.box[2], P.box[3], P.box[4])
end, function(player, P)
  local _, n = selected_set(player)
  return n >= #P.walkers, string.format("%d selected of %d walkers", n, #P.walkers)
end, function(player, P) selection.set(player.index, P.walkers) end, 120)
snap("b02-shift-added")

---------------------------------------------------------------------------
-- Part C: orders
---------------------------------------------------------------------------
real("rclick_move", function(player, P)
  P.move_px = {640 + 160, 400}
  drive("rclick %d %d", P.move_px[1], P.move_px[2])
end, function(player, P)
  local d = diff_stats(P.before)
  local n = 0
  for _, e in ipairs(P.walkers) do
    local rec = e.valid and units.get(e.unit_number)
    if rec and rec.order == "move" then n = n + 1 end
  end
  return n == #P.walkers, string.format("%d moving; %s", n, d)
end, function(player, P) orders.move(player.index, at_px(player, P.move_px[1], P.move_px[2])) end, 60)
-- The last attack order's target (orders.attack is looked up through the module table at call time)
local attack_targets = {}
local orders_attack = orders.attack
orders.attack = function(who, target)
  if type(who) == "number" and target and target.valid then attack_targets[#attack_targets + 1] = target.unit_number end
  return orders_attack(who, target)
end
-- An enemy walker 9 tiles left of the group, standing still (disabled by script: the test is the click, not the fight)
local function spawn_enemy(P, dy)
  local c = util.centroid(P.walkers)
  local e = units.spawn("rts-walker", {x = c.x - 9, y = c.y + dy}, E)
  if e then e.disabled_by_script = true end
  note("enemy walker #%s at %s", e and e.unit_number or "-", e and util.pos_str(e.position) or "-")
  return e
end
step(function(player, P)
  P.enemy = spawn_enemy(P, 2)
  P.enemy_un = P.enemy and P.enemy.unit_number
  return 30
end)
real("rclick_attack", function(player, P)
  attack_targets = {}
  local x, y = unit_px(player, P.enemy)
  P.enemy_px = {x, y}
  drive("rclick %d %d", x, y)
end, function(player, P)
  local d = diff_stats(P.before)
  local t = attack_targets[#attack_targets]
  return t ~= nil and t == P.enemy_un, string.format("attack target #%s, the enemy walker #%s (click %d, %d); %s",
    tostring(t), tostring(P.enemy_un), P.enemy_px[1], P.enemy_px[2], d)
end, function(player, P) if P.enemy.valid then orders.attack(player.index, P.enemy) end end, 60)
snap("c01-attack")
step(function(player, P)
  orders.stop(player.index)
  if P.enemy and P.enemy.valid then P.enemy.destroy() end
  P.enemy = spawn_enemy(P, -4)
  P.enemy_un = P.enemy and P.enemy.unit_number
  -- its leg farthest from the body
  local best, bd
  for _, leg in ipairs(match.surface().find_entities_filtered({position = P.enemy.position, radius = 10,
      type = "spider-leg", force = E})) do
    local d = util.distance(leg.position, P.enemy.position)
    if not best or d > bd then best, bd = leg, d end
  end
  P.leg = best
  note("enemy leg %s at %s, %.1f tiles from the body", best and best.name or "-", best and util.pos_str(best.position) or "-",
    bd or -1)
  return 30
end)
real("rclick_attack_leg", function(player, P)
  attack_targets = {}
  local x, y = spx(player, P.leg.position)
  P.leg_px = {x, y}
  drive("rclick %d %d", x, y)
end, function(player, P)
  local d = diff_stats(P.before)
  local t = attack_targets[#attack_targets]
  return t ~= nil and t == P.enemy_un, string.format("attack target #%s, the enemy walker #%s, after a click on its leg "
    .. "(%d, %d); %s", tostring(t), tostring(P.enemy_un), P.leg_px[1], P.leg_px[2], d)
end, function(player, P) if P.enemy.valid then orders.attack(player.index, P.enemy) end end, 60)
step(function(player, P)
  if P.enemy and P.enemy.valid then P.enemy.destroy() end
  orders.stop(player.index)
  return 30
end)
real("f_rdrag_attack_move", function(player, P)
  drive("key %d", KEY.F)
  drive("sleep 250")
  drive("drag %d %d %d %d right", 640 - 120, 400 - 60, 640 - 40, 400 + 20)
end, function(player, P)
  local d, b = diff_stats(P.before)
  return b.attack_move - P.before.attack_move >= #P.walkers and b.area > P.before.area, d
end, function(player, P) orders.attack_move(player.index, at_px(player, 560, 360)) end, 150)
snap("c02-f-rdrag")
real("shift_rdrag_attack_move", function(player, P)
  drive("drag %d %d %d %d right shift", 640 + 40, 400 + 40, 640 + 140, 400 + 100)
end, function(player, P)
  local d, b = diff_stats(P.before)
  return b.attack_move - P.before.attack_move >= #P.walkers and b.area > P.before.area, d
end, function(player, P) orders.attack_move(player.index, at_px(player, 730, 470)) end, 120)
real("shift_rclick_attack_move", function(player, P)
  drive("rclick %d %d shift", 640 - 100, 400 + 100)
end, function(player, P)
  local d, b = diff_stats(P.before)
  return b.attack_move - P.before.attack_move >= #P.walkers, d
end, function(player, P) orders.attack_move(player.index, at_px(player, 540, 500)) end, 60)
real("stop_x", function() drive("key %d", KEY.X) end, function(player, P)
  local n = 0
  for _, e in ipairs(P.walkers) do
    local rec = e.valid and units.get(e.unit_number)
    if rec and rec.order == "idle" then n = n + 1 end
  end
  return n == #P.walkers, n .. " idle"
end, function(player) orders.stop(player.index) end, 30)
-- WASD pans the remote view (a held key with auto-repeat), and a right click while D pans still gives its order
real("pan_d", function(player, P)
  P.pan0 = {x = player.position.x, y = player.position.y}
  drive("hold %d 800", KEY.D)
end, function(player, P)
  local moved = player.position.x - P.pan0.x
  return moved > 1 and remote(player), string.format("camera panned %.1f tiles east, controller %s", moved,
    util.define_name(defines.controllers, player.controller_type))
end, nil, 120)
real("rclick_while_panning", function(player, P)
  P.pan0 = {x = player.position.x, y = player.position.y}
  drive("hold %d 1200 rclick 640 280", KEY.D)
end, function(player, P)
  local d, b = diff_stats(P.before)
  local moved = player.position.x - P.pan0.x
  return b.move - P.before.move >= #P.walkers and b.area > P.before.area and moved > 1 and remote(player),
    string.format("%s; camera panned %.1f tiles east, controller %s", d, moved,
      util.define_name(defines.controllers, player.controller_type))
end, function(player, P) orders.move(player.index, at_px(player, 640, 280)) end, 150)
snap("c03-pan-order")

---------------------------------------------------------------------------
-- Part D: control groups and camera jumps
---------------------------------------------------------------------------
real("group_set_ctrl1", function() drive("key %d ctrl", KEY.ONE) end, function(player, P)
  local n = selection.group_count(player.index, 1)
  return n == #P.walkers, n .. " in group 1"
end, function(player) selection.group_set(player.index, 1) end, 30)
step(function(player, P)
  selection.clear(player.index)
  camera.jump_to(player, {x = P.home.x - 40, y = P.home.y - 30})
  return 30
end)
real("group_recall_1", function() drive("key %d", KEY.ONE) end, function(player, P)
  local _, n = selected_set(player)
  return n == #P.walkers, n .. " selected"
end, function(player) selection.group_recall(player.index, 1) end, 30)
real("group_double_tap", function()
  drive("key %d", KEY.ONE)
  drive("key %d", KEY.ONE)
end, function(player, P)
  local c = util.centroid(P.walkers)
  local d = c and util.distance(player.position, c) or 999
  return d < 6, string.format("camera %s, group at %s, %.1f tiles", util.pos_str(player.position),
    c and util.pos_str(c) or "-", d)
end, function(player, P) camera.jump_to(player, util.centroid(P.walkers)) end, 40)
-- a click on the HUD minimap at the enemy's CC
real("minimap_jump", function(player, P)
  local h = storage.players[player.index].hud
  local mm = h.minimap
  local s = player.display_scale
  local loc = mm.location
  local size = 220 * s
  local ppt = 1.0 * mm.zoom * s
  P.target = match.home(E)
  local dx = (loc.x + size / 2 + (P.target.x - mm.position.x) * ppt) / P.k
  local dy = (loc.y + size / 2 + (P.target.y - mm.position.y) * ppt) / P.k
  P.mm_px = {math.floor(dx + 0.5), math.floor(dy + 0.5)}
  drive("click %d %d", P.mm_px[1], P.mm_px[2])
end, function(player, P)
  local d = util.distance(player.position, P.target)
  return d < 12 and remote(player), string.format("camera %s, enemy CC %s, %.1f tiles (click %d, %d)",
    util.pos_str(player.position), util.pos_str(P.target), d, P.mm_px[1], P.mm_px[2])
end, function(player, P) camera.jump_to(player, P.target) end, 40)
snap("d01-minimap-jump")
real("space_home_2", function() drive("key %d", KEY.SPACE) end, function(player, P)
  local d = util.distance(player.position, P.home)
  return d < 2, string.format("%.1f tiles from home", d)
end, function(player) camera.home(player) end, 30)

---------------------------------------------------------------------------
-- Part E: F10, Escape, the game menu
---------------------------------------------------------------------------
real("f10_menu", function() drive("key %d", KEY.F10) end, function(player)
  return player.gui.screen.rts_menu ~= nil, "menu " .. tostring(player.gui.screen.rts_menu ~= nil)
end, function(player) lobby.toggle_menu(player) end, 40)
snap("e01-menu")
capture("e01-menu")
real("menu_escape", function() drive("key %d", KEY.ESC) end, function(player)
  return player.gui.screen.rts_menu == nil and remote(player), string.format("menu %s, controller %s",
    tostring(player.gui.screen.rts_menu ~= nil), util.define_name(defines.controllers, player.controller_type))
end, function(player) if player.gui.screen.rts_menu then lobby.toggle_menu(player) end end, 40)
real("f10_twice", function()
  drive("key %d", KEY.F10)
  drive("sleep 500")
  drive("key %d", KEY.F10)
end, function(player)
  return player.gui.screen.rts_menu == nil, "menu " .. tostring(player.gui.screen.rts_menu ~= nil)
end, function(player) if player.gui.screen.rts_menu then lobby.toggle_menu(player) end end, 120)
-- Escape with nothing open: the vanilla game menu (single player pauses: the second Escape closes it); the view must
-- stay remote (2.1: LuaPlayer::toggle_menu_leaves_remote_view)
real("escape_game_menu", function(player, P)
  P.esc_left = P.left
  drive("key %d", KEY.ESC)
  drive("sleep 900")
  drive("capture r2i-e02-escape")
  drive("key %d", KEY.ESC)
end, function(player, P)
  return P.left == P.esc_left and remote(player), string.format("remote view left %d times during the step, controller %s",
    P.left - P.esc_left, util.define_name(defines.controllers, player.controller_type))
end, nil, 240)
snap("e02-after-escape")

---------------------------------------------------------------------------
-- Part F: the menu's Restart (lobby), Start, Ctrl+Shift+R
---------------------------------------------------------------------------
step(function(player)
  lobby.toggle_menu(player)
  return 30
end)
capture("f01-menu-before-restart")
real("menu_restart_to_lobby", function(player, P)
  drive("click %d %d", P.L.restart[1], P.L.restart[2])
end, function(player)
  return match.in_lobby() and player.gui.screen.rts_lobby ~= nil and remote(player), string.format("in lobby %s, dialog %s",
    tostring(match.in_lobby()), tostring(player.gui.screen.rts_lobby ~= nil))
end, function(player) click(player, find(player.gui.screen, "rts_lobby_menu_restart")) end, 120)
snap("f02-lobby-again")
real("lobby_start_again", function(player, P)
  P.match1 = storage.match.match_id
  drive("click %d %d", P.L.start[1], P.L.start[2])
end, function(player, P)
  return not match.in_lobby() and remote(player), string.format("match %d -> %d", P.match1, storage.match.match_id)
end, function(player) click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start")) end, 300)
real("ctrl_shift_r_restart", function(player, P)
  P.match2 = storage.match.match_id
  drive("key %d ctrl+shift", KEY.R)
end, function(player, P)
  local d = util.distance(player.position, match.home(player.force.name))
  return storage.match.match_id > P.match2 and not match.in_lobby() and remote(player),
    string.format("match %d -> %d, camera %.1f tiles from home", P.match2, storage.match.match_id, d)
end, function(player) lobby.restart_current("probe fallback") end, 300)
snap("f03-restarted")
capture("f03-restarted")
step(function(player, P)
  check("remote_never_left", P.left == 0, "the player left the remote view %d times (%s)", P.left,
    table.concat(P.left_at, ", "))
  util.log("RTS_R2I_DONE player %d", player.index)
  return nil
end)

---------------------------------------------------------------------------
-- Watcher and runner
---------------------------------------------------------------------------
-- Every controller change of the player; a change away from the remote controller counts as "left".
events.on(defines.events.on_player_controller_changed, function(e)
  local P = storage.r2i_probe
  local player = game.get_player(e.player_index)
  if not (P and player) then return end
  local now = util.define_name(defines.controllers, player.controller_type)
  local old = util.define_name(defines.controllers, e.old_type)
  note("controller %s -> %s at tick %d (step %d)", old, now, e.tick, P.i - 1)
  if player.controller_type ~= defines.controllers.remote and P.started then
    P.left = P.left + 1
    P.left_at[#P.left_at + 1] = string.format("t%d step %d %s->%s", e.tick, P.i - 1, old, now)
  end
end)

-- Coordinates of the English layout, then per locale (measured from the window captures of this probe)
local LAYOUT = {
  en = {start = {740, 513}, restart = {533, 438}},
  ru = {start = {740, 513}, restart = {533, 438}},
}

events.on_nth_tick(15, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r2i_probe
  if not P then
    P = {i = 1, at = game.tick + 300, left = 0, left_at = {}}
    storage.r2i_probe = P
  end
  if P.done or game.tick < P.at then return end
  if not P.L then
    P.L = LAYOUT[player.locale] or LAYOUT.en
    P.started = true
    note("locale %s, controller %s", player.locale, util.define_name(defines.controllers, player.controller_type))
  end
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("r2i probe step %d error: %s", idx, tostring(wait))
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    if P.i > #STEPS and wait then util.log("RTS_R2I_DONE player %d (steps ran out)", player.index) end
    return
  end
  P.at = game.tick + wait
end)
