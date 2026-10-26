-- Test-only GUI probe with REAL input, 0.1.2 #31 part A day-1 question: does the vanilla rail planner work in the RTS
-- remote view on 2.1 with a rail ghost in the cursor (scripts/cursor.lua give_ghost), and do robots build its ghosts?
-- Test copy (self-test off), then:
--   tools/gui-drive.sh build/r3rails-planner-gui.log build/shots-r3rails-planner-window RTS_R3P_DONE &
--   tools/gui-run.sh build/r3rails-planner 300 RTS_R3P_DONE '\[rts\] r3p|rror'
-- (append require("scripts.r3_rails_planner_gui") to the copy's control.lua; the input goes to the front window.)
-- Steps: the Skirmish match starts from the lobby; Nation rules for rails (storage.rails.test_nation); the camera goes
-- next to the player's Command Center at zoom 0.35; the cursor gets a "rail" ghost; a real left drag runs straight
-- north-south, a second one diagonally; the probe counts rail ghosts and logs what the cursor holds. Then the CC network
-- gets 200 rails and the probe waits for its robots to build the ghosts. Checks "[rts] r3p check <name>: PASS|FAIL":
--   ghost_cursor  cursor.give_ghost(player, "rail") left a rail ghost in the cursor
--   straight      the first drag made straight rail ghosts
--   curve         the second drag made curved or diagonal rail ghosts
--   cursor_kept   the rail ghost is still in the cursor after both drags (build mode goes on)
--   robots        the CC's construction robots built the ghosts within 60 s (rails in its network)
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local cursor = require("scripts.cursor")
local buildings = require("scripts.buildings")
local logistics = require("scripts.logistics")

local RAIL_GHOSTS = {"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b"}

local function note(fmt, ...) util.log("r3p probe: " .. fmt, ...) end
local function check(name, ok, fmt, ...)
  util.log("r3p check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function drive(fmt, ...)
  storage.r3p_seq = (storage.r3p_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.r3p_seq, ...)
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
  local path = string.format("rts-r3p-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  note("screenshot %s", path)
end
local function spx(player, pos)
  local k = 32 * player.zoom
  return math.floor(640 + (pos.x - player.position.x) * k + 0.5), math.floor(400 + (pos.y - player.position.y) * k + 0.5)
end

local function ghosts(player, kind)
  local s = player.surface
  local n, by = 0, {}
  for _, g in ipairs(s.find_entities_filtered({name = "entity-ghost", force = player.force})) do
    if g.valid then
      local gn = g.ghost_name
      for _, r in ipairs(RAIL_GHOSTS) do
        if gn == r then
          n = n + 1
          by[gn] = (by[gn] or 0) + 1
        end
      end
    end
  end
  local built = s.count_entities_filtered({name = RAIL_GHOSTS, force = player.force})
  return n, by, built
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
  local cc = buildings.main_cc(player.force.name)
  P.cc = cc and cc.entity.position or {x = -88, y = 0}
  P.view = {x = P.cc.x + 30, y = P.cc.y}
  camera.jump_to(player, P.view)
  player.zoom = 0.35
  return 30
end)

step(function(player, P)
  local ok
  if rawget(_G, "R3P_ITEM") then
    -- variant: a real rail item in the cursor stack (the remote view builds ghosts with it)
    player.cursor_stack.set_stack({name = "rail", count = 1})
    ok = player.cursor_stack.valid_for_read and player.cursor_stack.name == "rail"
    check("ghost_cursor", ok, "rail item in the cursor stack %s, controller %s", tostring(ok),
      tostring(player.controller_type))
  else
    ok = cursor.give_ghost(player, "rail")
    check("ghost_cursor", ok and cursor.ghost_name(player) == "rail", "give_ghost ok %s, cursor ghost %s, controller %s",
      tostring(ok), tostring(cursor.ghost_name(player)), tostring(player.controller_type))
  end
  P.g0, P.by0, P.b0 = ghosts(player)
  local a, b = {x = P.cc.x + 22, y = P.cc.y - 20}, {x = P.cc.x + 22, y = P.cc.y + 20}
  note("can place straight rail ghost at %s: %s", util.pos_str(a), tostring(player.surface.can_place_entity({
    name = "straight-rail", position = a, direction = defines.direction.north, force = player.force,
    build_check_type = defines.build_check_type.manual_ghost})))
  -- variant 1: a single click (one piece), then a click at the far end (2.0: the planner runs from the last piece)
  local x1, y1 = spx(player, a)
  local x2, y2 = spx(player, b)
  note("click at (%d, %d), move to (%d, %d), click; view %s zoom %.2f", x1, y1, x2, y2, util.pos_str(player.position),
    player.zoom)
  drive("move %d %d", x1, y1)
  drive("sleep 300")
  drive("click %d %d", x1, y1)
  drive("sleep 500")
  drive("move %d %d", x2, y2)
  drive("sleep 700")
  drive("click %d %d", x2, y2)
  drive("sleep 300")
  drive("capture planner-click")
  return 300
end)

step(function(player, P)
  P.gc, P.byc = ghosts(player)
  note("after the clicks: rail ghosts %d %s, built %d", P.gc, serpent.line(P.byc), storage.r3p_built or 0)
  shot(player, "clicks")
  -- variant 2: a slow drag north-south further east
  local a, b = {x = P.cc.x + 32, y = P.cc.y - 25}, {x = P.cc.x + 32, y = P.cc.y + 25}
  local x1, y1 = spx(player, a)
  local x2, y2 = spx(player, b)
  drive("move %d %d", x1, y1)
  drive("sleep 300")
  drive("drag %d %d %d %d left", x1, y1, x2, y2)
  return 240
end)

step(function(player, P)
  P.g1, P.by1 = ghosts(player)
  shot(player, "drag1")
  check("straight", (P.by1["straight-rail"] or 0) > (P.by0["straight-rail"] or 0), "rail ghosts %d -> %d (clicks) -> %d "
    .. "(drag) %s", P.g0, P.gc, P.g1, serpent.line(P.by1))
  -- variant 3 (curves): click at a start point, move diagonally, click
  local x1, y1 = spx(player, {x = P.cc.x + 44, y = P.cc.y - 25})
  local x2, y2 = spx(player, {x = P.cc.x + 64, y = P.cc.y + 5})
  note("curve: drag (%d, %d) to (%d, %d)", x1, y1, x2, y2)
  drive("move %d %d", x1, y1)
  drive("sleep 300")
  drive("drag %d %d %d %d left", x1, y1, x2, y2)
  return 300
end)

step(function(player, P)
  P.g2, P.by2 = ghosts(player)
  shot(player, "drag2")
  local curves = (P.by2["curved-rail-a"] or 0) + (P.by2["curved-rail-b"] or 0) + (P.by2["half-diagonal-rail"] or 0)
  check("curve", curves > 0 and P.g2 > P.g1, "rail ghosts %d -> %d %s", P.g1, P.g2, serpent.line(P.by2))
  check("cursor_kept", cursor.ghost_name(player) == "rail", "cursor ghost %s, cursor stack %s",
    tostring(cursor.ghost_name(player)), tostring(player.cursor_stack and player.cursor_stack.valid_for_read
    and player.cursor_stack.name or "empty"))
  drive("capture planner-window")
  -- rails for the CC's robots
  local cc = buildings.main_cc(player.force.name)
  local net = cc and cc.entity.logistic_network
  P.put = net and net.insert({name = "rail", count = 300}) or 0
  P.t_robots = game.tick
  return 60
end)

step(function(player, P)
  local n, by, built = ghosts(player)
  if n > 0 and game.tick - P.t_robots < 45 * 60 then
    P.i = P.i - 1
    return 120
  end
  shot(player, "robots")
  for _, g in ipairs(player.surface.find_entities_filtered({name = "entity-ghost", force = player.force})) do
    note("ghost left: %s at %s", g.ghost_name, util.pos_str(g.position))
  end
  check("robots", n == 0 and built > 0, "%d rails into the CC network; after %.0f s: %d rail ghosts left, %d rails built",
    P.put, (game.tick - P.t_robots) / 60, n, built)
  util.log("RTS_R3P_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r3p_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.r3p_probe = P
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

events.on(defines.events.on_built_entity, function(e)
  local en = e.entity
  if en and en.valid and en.name == "entity-ghost" then
    storage.r3p_built = (storage.r3p_built or 0) + 1
    if storage.r3p_built <= 5 then note("built ghost %s at %s", en.ghost_name, util.pos_str(en.position)) end
  end
end)
