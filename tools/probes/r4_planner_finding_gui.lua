-- Test-only GUI probe with REAL input, 0.1.3 #37 investigation: which of the RTS view settings keeps the vanilla rail
-- planner from running in the remote view (0.1.2 found that a "rail" cursor ghost only placed single straight pieces,
-- docs/qa/release-0-1-2-r3-rails-notes.md 3.1, without finding why). Results: docs/qa/release-0-1-3-r4-rails-notes.md 1.
-- The 2.x planner starts from a rail END under the pointer (the engine's hovered entity, as the base game's tips
-- simulation does: move_cursor onto the rail end, activate_rail_planner, move, build): a press there activates it,
-- then the path to the pointer is previewed and a click (or the drag) builds it. A click on bare ground only places one
-- rail. Every variant changes one suspect; the same real-input tests run in three regions next to the player's
-- Command Center (cleared between variants):
--   stub      two built straight rails (east-west); the pointer rests on the east end, a click there, a move to B
--             (24 east, 8 south), a window capture of the preview, a click at B: the planner builds a curved path
--             (curved / diagonal ghosts), a plain ghost cursor places one more straight piece
--   ghost     a click on bare ground at C (one ghost), the pointer on that ghost's south end, a click there, a move to
--             D (20 east, 12 south), a click: the planner starts from a ghost end too
--   drag      a built stub at E; press on its east end and drag slowly to F (24 east, 12 south): the planner builds
--             a curved path while dragging
-- Variants ("[rts] r4f result <variant> <test>: ghosts n {by name}"):
--   base         cursor.give_ghost(player, "rail"), every RTS setting as shipped (GameViewSettings.update_entity_selection
--                off, camera.lua's 10-tick hover clear on, the cursor watchdog on)
--   hover        the same ghost with update_entity_selection on and the hover clear paused
--   hover_clear  update_entity_selection on, the 10-tick hover clear left running
--   hover_nowatch update_entity_selection on, the hover clear, the cursor watchdog and the camera guard paused
--                (storage.players[i].setup_done = false)
--   hover_surface update_entity_selection on, the god body moved from the lobby surface onto the arena
--   item_hover   a real "rail" item (100) set into cursor_stack under the remote controller, hover on, watchdog paused;
--                cursor.ensure and on_player_cursor_stack_changed are traced (who empties the cursor)
--   god_hover    god controller on the arena (body moved there), 100 rails in the cursor stack, hover on
--   god          the same with update_entity_selection off
-- Test copy (self-test off):
--   rm -rf build/r4f && mkdir -p build/r4f && cp -R mods/factorio-rts mods/mod-list.json build/r4f/
--   cp tools/probes/r4_planner_finding_gui.lua build/r4f/factorio-rts/scripts/
--   printf '\nrequire("scripts.r4_planner_finding_gui")\n' >> build/r4f/factorio-rts/control.lua
--   tools/gui-drive.sh build/r4f-gui.log build/shots-r4f-window RTS_R4F_DONE &
--   tools/gui-run.sh build/r4f 600 RTS_R4F_DONE '\[rts\] r4f|rror'
-- Check that no other Factorio client runs first (the input goes to the front window).
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local cursor = require("scripts.cursor")
local buildings = require("scripts.buildings")
local match = require("scripts.match")

local RAILS = {"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b"}
local FAR = 2 ^ 40
local RD = defines.rail_direction

local function note(fmt, ...) util.log("r4f probe: " .. fmt, ...) end
local function result(fmt, ...) util.log("r4f result " .. fmt, ...) end
local function drive(fmt, ...)
  storage.r4f_seq = (storage.r4f_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.r4f_seq, ...)
end
local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

-- trace: who empties the cursor (cursor.lua calls cursor.ensure through the module table)
local ensure0 = cursor.ensure
cursor.ensure = function(player, force_replace, reason)
  if storage.r4f_trace and player and player.valid then
    local st = player.cursor_stack
    local inv = player.get_main_inventory()
    note("trace ensure(%s, %s) tick %d: stack %s, ghost %s, controller %s, main inventory %s", tostring(reason),
      tostring(force_replace), game.tick, (st and st.valid_for_read) and (st.name .. " x" .. st.count) or "empty",
      tostring(cursor.ghost_name(player)), util.define_name(defines.controllers, player.controller_type),
      inv and ("rails " .. inv.get_item_count("rail")) or "none")
  end
  return ensure0(player, force_replace, reason)
end

events.on(defines.events.on_player_cursor_stack_changed, function(e)
  if not storage.r4f_trace then return end
  local player = game.get_player(e.player_index)
  local st = player.cursor_stack
  note("trace cursor_stack_changed tick %d: stack %s, ghost %s", game.tick,
    (st and st.valid_for_read) and (st.name .. " x" .. st.count) or "empty", tostring(cursor.ghost_name(player)))
end)

local function spx(player, pos)
  local k = 32 * player.zoom
  return math.floor(640 + (pos.x - player.position.x) * k + 0.5), math.floor(400 + (pos.y - player.position.y) * k + 0.5)
end

local function set_hover(player, on)
  local gvs = player.game_view_settings
  gvs.update_entity_selection = on
  player.game_view_settings = gvs
end

local function pause_clear(player, on)
  storage.camera.pulse = storage.camera.pulse or {}
  storage.camera.pulse[player.index] = on and {at = FAR, reason = "r4f probe"} or nil
end

local function region(P, key)
  local r = P.regions[key]
  return {{r[1].x - 8, r[1].y - 8}, {r[2].x + 8, r[2].y + 8}}
end

local function count(player, area)
  local by, n = {}, 0
  for _, g in ipairs(player.surface.find_entities_filtered({area = area, name = "entity-ghost"})) do
    local gn = g.ghost_name
    for _, r in ipairs(RAILS) do
      if gn == r then
        n = n + 1
        by[gn] = (by[gn] or 0) + 1
      end
    end
  end
  local real = 0
  for _, e in ipairs(player.surface.find_entities_filtered({area = area, name = RAILS})) do
    real = real + 1
    by["real " .. e.name] = (by["real " .. e.name] or 0) + 1
  end
  return n, by, real
end

local function cleanup(player, P)
  local n = 0
  for key in pairs(P.regions) do
    local area = region(P, key)
    for _, g in ipairs(player.surface.find_entities_filtered({area = area, name = "entity-ghost"})) do
      g.destroy()
      n = n + 1
    end
    for _, e in ipairs(player.surface.find_entities_filtered({area = area, name = RAILS})) do
      e.destroy()
      n = n + 1
    end
  end
  return n
end

-- two built straight rails (east-west) ending at about `pos`; returns the position just inside their east end
local function stub(player, pos)
  local s = player.surface
  local x, y = 2 * math.floor(pos.x / 2) + 1, 2 * math.floor(pos.y / 2) + 1
  local last
  for i = 0, 1 do
    last = s.create_entity({name = "straight-rail", position = {x + 2 * i, y}, direction = defines.direction.east,
                            force = player.force}) or last
  end
  if not last then return nil end
  local best
  for _, rd in ipairs({RD.front, RD.back}) do
    local p = last.get_rail_end(rd).location.position
    if not best or p.x > best.x then best = {x = p.x, y = p.y} end
  end
  return {x = best.x - 0.5, y = best.y}
end

-- the cursor of a test: a fresh rail ghost (or rail item) so no planner state carries over from the previous test
local function fresh_cursor(player, V)
  if V.item then
    player.clear_cursor()
    player.cursor_ghost = nil
    local ok = player.cursor_stack.set_stack({name = "rail", count = 100})
    note("%s: set_stack rail x100 -> %s; now stack %s ghost %s controller %s", V.name, tostring(ok),
      player.cursor_stack.valid_for_read and (player.cursor_stack.name .. " x" .. player.cursor_stack.count) or "empty",
      tostring(cursor.ghost_name(player)), util.define_name(defines.controllers, player.controller_type))
  else
    cursor.ensure(player, true, "r4f fresh")
    local ok = cursor.give_ghost(player, "rail")
    note("%s: give_ghost rail -> %s; ghost %s", V.name, tostring(ok), tostring(cursor.ghost_name(player)))
  end
end

local function apply(player, P, V)
  local p = storage.players[player.index]
  set_hover(player, V.hover == true)
  pause_clear(player, V.noclear == true)
  p.setup_done = not V.nowatch
  storage.r4f_trace = V.item == true
  if V.surface or V.god then
    local arena = player.surface -- the view surface
    local view = player.position
    player.set_controller({type = defines.controllers.god})
    local at = V.god and P.view or P.body -- the god's view is centred on its body
    local ok = player.teleport(at, arena)
    if not V.god then
      player.set_controller({type = defines.controllers.remote, position = view, surface = arena})
    end
    note("%s: body moved to %s on %s: %s; controller %s, physical surface %s, view surface %s", V.name, util.pos_str(at),
      arena.name, tostring(ok), util.define_name(defines.controllers, player.controller_type),
      player.physical_surface.name, player.surface.name)
    player.zoom = 0.35
  end
  note("%s: hover %s, hover clear paused %s, watchdog/guard paused %s, controller %s, physical %s", V.name,
    tostring(player.game_view_settings.update_entity_selection), tostring(V.noclear == true), tostring(V.nowatch == true),
    util.define_name(defines.controllers, player.controller_type), player.physical_surface.name)
end

local function restore(player, P)
  local p = storage.players[player.index]
  storage.r4f_trace = false
  set_hover(player, false)
  pause_clear(player, false)
  p.setup_done = true
  if player.controller_type ~= defines.controllers.remote or player.physical_surface.name ~= match.lobby_surface().name then
    camera.setup(player, "r4f restore")
    camera.jump_to(player, P.view)
  end
  player.zoom = 0.35
  cursor.ensure(player, true, "r4f restore")
end

local VARIANTS = {
  {name = "base"},
  {name = "hover", hover = true, noclear = true},
  {name = "hover_clear", hover = true},
  {name = "hover_nowatch", hover = true, noclear = true, nowatch = true},
  {name = "hover_surface", hover = true, noclear = true, surface = true},
  {name = "item_hover", item = true, hover = true, noclear = true, nowatch = true},
  {name = "god_hover", god = true, item = true, hover = true, noclear = true, nowatch = true},
  {name = "god", god = true, item = true, nowatch = true},
}

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player, P)
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 180
end)

step(function(player, P)
  local cc = buildings.main_cc(player.force.name)
  P.cc = cc and cc.entity.position or {x = -88, y = 0}
  P.view = {x = P.cc.x + 30, y = P.cc.y}
  P.body = {x = P.cc.x - 20, y = P.cc.y + 22}
  local v = P.view
  P.regions = {
    stub = {{x = v.x - 6, y = v.y - 22}, {x = v.x + 22, y = v.y - 12}},
    ghost = {{x = v.x - 6, y = v.y - 8}, {x = v.x + 18, y = v.y + 6}},
    drag = {{x = v.x - 6, y = v.y + 9}, {x = v.x + 22, y = v.y + 22}},
  }
  camera.jump_to(player, P.view)
  player.zoom = 0.35
  local rp = prototypes.item["rail"]
  local names = {}
  for _, r in pairs(rp.rails or {}) do names[#names + 1] = r.name end
  note("rail item type %s, rails {%s}, support %s; force rail_planner_allow_elevated_rails %s; arena %s, lobby %s",
    rp.type, table.concat(names, ", "), rp.support and rp.support.name or "none",
    tostring(player.force.rail_planner_allow_elevated_rails), player.surface.name, match.lobby_surface().name)
  P.v = 1
  return 30
end)

local function variant_steps()
  -- stub: activate on a built rail end, move, click
  step(function(player, P)
    local V = VARIANTS[P.v]
    if not V then return "done" end
    apply(player, P, V)
    fresh_cursor(player, V)
    local r = P.regions.stub
    local e = stub(player, r[1])
    P.stub_end = e
    local b = {x = e.x + 24, y = e.y + 8}
    local x1, y1 = spx(player, e)
    local x2, y2 = spx(player, b)
    local mx, my = spx(player, {x = e.x + 12, y = e.y + 3})
    note("%s stub: end %s -> B %s, screen (%d, %d) -> (%d, %d)", V.name, util.pos_str(e), util.pos_str(b), x1, y1, x2, y2)
    drive("move %d %d", x1, y1)
    drive("sleep 600")
    drive("capture %s-stub-hover", V.name)
    drive("click %d %d", x1, y1)
    drive("sleep 400")
    drive("move %d %d", mx, my)
    drive("sleep 300")
    drive("move %d %d", x2, y2)
    drive("sleep 900")
    drive("capture %s-stub-preview", V.name)
    drive("click %d %d", x2, y2)
    drive("sleep 300")
    return 360
  end)
  -- ghost: a click on bare ground, then on that ghost's end, move, click
  step(function(player, P)
    local V = VARIANTS[P.v]
    local n, by, real = count(player, region(P, "stub"))
    result("%s stub: ghosts %d, real %d %s; cursor %s ghost %s; selected %s", V.name, n, real, serpent.line(by),
      player.cursor_stack.valid_for_read and player.cursor_stack.name or "empty", tostring(cursor.ghost_name(player)),
      player.selected and player.selected.name or "none")
    fresh_cursor(player, V)
    local c = P.regions.ghost[1]
    local x1, y1 = spx(player, c)
    drive("move %d %d", x1, y1)
    drive("sleep 300")
    drive("click %d %d", x1, y1)
    drive("sleep 500")
    P.ghost_at = c
    return 90
  end)
  step(function(player, P)
    local V = VARIANTS[P.v]
    -- the ghost (or rail, under god) the click placed: its south or east end, the one nearer D
    local s = player.surface
    local found = s.find_entities_filtered({area = region(P, "ghost"), name = "entity-ghost"})[1]
      or s.find_entities_filtered({area = region(P, "ghost"), name = RAILS})[1]
    local d = P.regions.ghost[2]
    local e
    if found then
      local pos, dir = found.position, found.direction
      if dir == defines.direction.north or dir == defines.direction.south then
        e = {x = pos.x, y = pos.y + 0.5}
      else
        e = {x = pos.x + 0.5, y = pos.y}
      end
      note("%s ghost: first piece %s %s dir %d, pointer on its end at %s", V.name, found.name,
        found.type == "entity-ghost" and found.ghost_name or "", dir, util.pos_str(e))
    else
      e = P.ghost_at
      note("%s ghost: no first piece placed", V.name)
    end
    local x1, y1 = spx(player, e)
    local x2, y2 = spx(player, d)
    local mx, my = spx(player, {x = (e.x + d.x) / 2, y = (e.y + d.y) / 2})
    drive("move %d %d", x1, y1)
    drive("sleep 600")
    drive("click %d %d", x1, y1)
    drive("sleep 400")
    drive("move %d %d", mx, my)
    drive("sleep 300")
    drive("move %d %d", x2, y2)
    drive("sleep 900")
    drive("capture %s-ghost-preview", V.name)
    drive("click %d %d", x2, y2)
    drive("sleep 300")
    return 300
  end)
  -- drag: press on a stub's end, drag slowly
  step(function(player, P)
    local V = VARIANTS[P.v]
    local n, by, real = count(player, region(P, "ghost"))
    result("%s ghost: ghosts %d, real %d %s", V.name, n, real, serpent.line(by))
    fresh_cursor(player, V)
    local r = P.regions.drag
    local e = stub(player, r[1])
    local f = r[2]
    local x1, y1 = spx(player, e)
    local x2, y2 = spx(player, f)
    drive("move %d %d", x1, y1)
    drive("sleep 600")
    drive("drag %d %d %d %d left none 40 60", x1, y1, x2, y2)
    drive("sleep 300")
    return 360
  end)
  step(function(player, P)
    local V = VARIANTS[P.v]
    local n, by, real = count(player, region(P, "drag"))
    result("%s drag: ghosts %d, real %d %s", V.name, n, real, serpent.line(by))
    drive("capture %s-after", V.name)
    return 60
  end)
  step(function(player, P)
    local V = VARIANTS[P.v]
    local gone = cleanup(player, P)
    restore(player, P)
    note("%s: cleaned %d rails and ghosts, restored", V.name, gone)
    P.v = P.v + 1
    P.i = P.loop -- back to the variant's first step
    return 60
  end)
end

local P_LOOP = #STEPS + 1
variant_steps()

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r4f_probe
  if not P then
    P = {i = 1, at = game.tick + 120, loop = P_LOOP}
    storage.r4f_probe = P
  end
  if P.done or game.tick < P.at then return end
  local fn = STEPS[P.i]
  P.i = P.i + 1
  local wait = fn(player, P)
  if wait == "done" then
    P.done = true
    util.log("RTS_R4F_DONE player %d", player.index)
    return
  end
  P.at = game.tick + (wait or 30)
end)
