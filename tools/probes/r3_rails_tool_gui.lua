-- Test-only GUI probe, 0.1.2 #31 part A: the Rail tool (scripts/railtool.lua) in the real client, driven through the
-- handlers the inputs call (a left click: selection.area_hook; right click: orders.handle_reverse_area; Backspace and Q:
-- their custom input events).
-- Test copy (self-test off), append require("scripts.r3_rails_tool_gui") to its control.lua, then:
--   tools/gui-drive.sh build/<copy>-gui.log build/shots-<copy>-window RTS_R3T_DONE &
--   tools/gui-run.sh build/<copy> 300 RTS_R3T_DONE '\[rts\] (r3t|railtool)|rror'      (RTS_LOCALE=ru for Russian)
-- A Skirmish match from the lobby with the rails module in Nation rules (storage.rails.test_nation) and Railways
-- researched for the player; the camera next to the Command Center at zoom 0.3; the CC network gets 400 rails.
-- Checks ("[rts] r3t check <name>: PASS|FAIL ..."):
--   open       the build menu's Rail button opens the tool and its panel
--   segments   three left clicks (start, a waypoint 50 tiles south, one 40 tiles east and further south) plan two
--              segments; the second one has curved or diagonal pieces
--   undo       a right click takes the last segment back, Backspace the one before (no segment left, its ghosts
--              gone); two clicks plan it again
--   robots     the CC's robots build the planned track within 90 s
--   branch     a click on a built rail, then a click 30 tiles away plans a branch; its junction gets chain signals once
--              built
--   close      Q ends the tool (panel gone, the RTS cursor back)
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local buildings = require("scripts.buildings")
local research = require("scripts.research")
local rails = require("scripts.rails")
local railtool = require("scripts.railtool")
local hud = require("scripts.hud")
local orders = require("scripts.orders")
local selection = require("scripts.selection")

local KEY = {Q = 12, BACKSPACE = 51}
local RAILS = {"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b"}

local function note(fmt, ...) util.log("r3t probe: " .. fmt, ...) end
local function check(name, ok, fmt, ...)
  util.log("r3t check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function drive(fmt, ...)
  storage.r3t_seq = (storage.r3t_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.r3t_seq, ...)
end
local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end
local function shot(player, tag)
  local path = string.format("rts-r3t-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  note("screenshot %s", path)
end
local function spx(player, pos)
  local k = 32 * player.zoom
  return math.floor(640 + (pos.x - player.position.x) * k + 0.5), math.floor(400 + (pos.y - player.position.y) * k + 0.5)
end
-- A left click on the map as the rts-cursor reports it (selection.lua's on_player_selected_area -> area_hook). Real OS
-- input reached the same event in tools/probes/r3_rails_planner_gui.lua; with another window in front the drive's
-- clicks are lost, so the probe raises the event's handler path itself.
local function click_at(player, pos)
  selection.area_hook(player.index, {left_top = {x = pos.x - 0.05, y = pos.y - 0.05},
    right_bottom = {x = pos.x + 0.05, y = pos.y + 0.05}}, {}, player.surface)
end
local function T(player) return storage.railtool and storage.railtool.tools[player.index] end
local function ghosts(player)
  local n = 0
  for _, g in ipairs(player.surface.find_entities_filtered({name = "entity-ghost", force = player.force})) do
    for _, r in ipairs(RAILS) do if g.ghost_name == r then n = n + 1 end end
  end
  return n
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player, P)
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 180
end)

step(function(player, P)
  storage.rails = storage.rails or {}
  storage.rails.test_nation = true
  local tech = player.force.technologies["rts-railways"]
  if tech then tech.researched = true end
  research.apply(player.force)
  local cc = buildings.main_cc(player.force.name)
  P.cc = cc.entity.position
  local net = cc.entity.logistic_network
  P.rails_in = net and net.insert({name = "rail", count = 400}) or 0
  if net then net.insert({name = "rail-chain-signal", count = 40}) end
  camera.jump_to(player, {x = P.cc.x + 44, y = P.cc.y + 9})
  player.zoom = 0.3
  return 30
end)

step(function(player, P)
  hud.build_click(player, "rail")
  local frame = player.gui.screen[railtool.FRAME]
  check("open", T(player) ~= nil and frame ~= nil, "tool %s, panel %s (rails in the CC network %d)",
    tostring(T(player) ~= nil), tostring(frame ~= nil), P.rails_in)
  shot(player, "open")
  -- waypoints where no panel covers the map (screen points of the 1280x800 window)
  local function at_px(x, y)
    local k = 32 * player.zoom
    return {x = player.position.x + (x - 640) / k, y = player.position.y + (y - 400) / k}
  end
  P.w1 = at_px(300, 280)
  P.w2 = at_px(300, 560)
  P.w3 = at_px(720, 660)
  click_at(player, P.w1)
  click_at(player, P.w2)
  return 150
end)

step(function(player, P)
  click_at(player, P.w3)
  return 150
end)

step(function(player, P)
  local t = T(player)
  local segs = t and t.segments or {}
  local curved = 0
  local last = segs[#segs] and rails.lines[segs[#segs]]
  for _, p in ipairs(last and last.pieces or {}) do
    if p.name ~= "straight-rail" or p.d % 4 ~= 0 then curved = curved + 1 end
  end
  P.g2 = ghosts(player)
  check("segments", #segs == 2 and curved > 0, "%d segments, %d curved or diagonal pieces in the second, %d rail ghosts",
    #segs, curved, P.g2)
  shot(player, "segments")
  return 30
end)

step(function(player, P)
  -- right click (orders.lua's reverse-select path): undo the last segment; Backspace (rts-rail-undo): the one before
  local p3 = {x = P.w3.x + 4, y = P.w3.y}
  local order = orders.handle_reverse_area(player.index, {}, {left_top = {x = p3.x - 0.05, y = p3.y - 0.05},
    right_bottom = {x = p3.x + 0.05, y = p3.y + 0.05}}, false)
  note("right click order %s", tostring(order))
  events.dispatch("rts-rail-undo", {player_index = player.index, name = "rts-rail-undo", tick = game.tick})
  return 120
end)

step(function(player, P)
  local t = T(player)
  local g = ghosts(player)
  check("undo", t ~= nil and #t.segments == 0 and g < P.g2, "segments %d after right click + Backspace, rail ghosts %d "
    .. "(were %d)", t and #t.segments or -1, g, P.g2)
  -- plan the first two waypoints again (the head went back to the start)
  click_at(player, P.w2)
  return 150
end)

step(function(player, P)
  local t = T(player)
  P.segs_again = t and #t.segments or 0
  shot(player, "again")
  P.t_robots = game.tick
  return 60
end)

step(function(player, P)
  local g = ghosts(player)
  if g > 0 and game.tick - P.t_robots < 90 * 60 then
    P.i = P.i - 1
    return 120
  end
  local built = player.surface.count_entities_filtered({name = RAILS, force = player.force})
  check("robots", P.segs_again == 1 and g == 0 and built > 0, "segment planned again %d; after %.0f s %d ghosts left, "
    .. "%d rails built", P.segs_again, (game.tick - P.t_robots) / 60, g, built)
  shot(player, "built")
  -- branch: a click on a built rail halfway, then 30 tiles east
  local mid = player.surface.find_entities_filtered({position = {x = P.w1.x, y = P.cc.y}, radius = 3,
    name = "straight-rail", force = player.force})[1]
  P.mid = mid and mid.position
  railtool.close(player, "probe: a new start")
  railtool.open(player)
  if mid then
    click_at(player, mid.position)
    click_at(player, {x = mid.position.x + 34, y = mid.position.y + 12})
  end
  return 240
end)

step(function(player, P)
  local t = T(player)
  local segs = t and t.segments or {}
  local line = segs[1] and rails.lines[segs[1]]
  local g = ghosts(player)
  P.t_branch = P.t_branch or game.tick
  if ((t and t.pending) or (line and (line.missing or 0) > 0 and g > 0)) and game.tick - P.t_branch < 90 * 60 then
    P.i = P.i - 1
    return 120
  end
  local chains = P.mid and player.surface.count_entities_filtered({position = P.mid, radius = 24,
    name = "rail-chain-signal", force = player.force}) or 0
  check("branch", line ~= nil and line.state ~= "failed" and chains >= 4, "branch segment %s (%s), %d chain signals "
    .. "around the junction", tostring(segs[1]), line and line.state or "-", chains)
  shot(player, "branch")
  events.dispatch("rts-clear-cursor", {player_index = player.index, name = "rts-clear-cursor", tick = game.tick}) -- Q
  return 60
end)

step(function(player, P)
  local frame = player.gui.screen[railtool.FRAME]
  local stack = player.cursor_stack
  check("close", T(player) == nil and frame == nil, "tool %s, panel %s, cursor %s", tostring(T(player) ~= nil),
    tostring(frame ~= nil), stack and stack.valid_for_read and stack.name or "empty")
  util.log("RTS_R3T_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r3t_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.r3t_probe = P
  end
  if P.done or game.tick < P.at then return end
  local fn = STEPS[P.i]
  P.i = P.i + 1
  local wait = fn(player, P)
  if not wait or P.i > #STEPS then
    P.done = true
    return
  end
  P.at = game.tick + wait
end)
