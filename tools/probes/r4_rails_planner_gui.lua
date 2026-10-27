-- Test-only GUI probe with REAL input, 0.1.3 #37: the vanilla rail planner as the player's way of laying track
-- (scripts/railplan.lua, camera.lua's planner view, rails.adopt_ghosts). A Skirmish match from the lobby with the rails
-- module in Nation rules (storage.rails.test_nation) and Railways researched; a box east of the Command Center is
-- cleared and charted; a depot with an east-west platform, stockpiles with kits, rails and coal. Real input
-- (tools/gui-drive.sh) lays the track:
--   cursor     the build menu's Rail button (hud.build_click, the handler of the button) puts the rail ghost in the cursor:
--              hover selection on, the HUD line says how to lay track
--   drag1      a slow drag from the depot platform's east end 60 tiles east and 24 south: the 2.x planner starts at the
--              press and previews its path while the pointer moves; the click at the end builds it (the drag alone builds
--              nothing, logged): ghosts with curves; their planner line starts on the platform rail (joined)
--   built1     a construction crew from the depot (and the depot's robots in range) builds every piece
--   station1   a Station put next to the far end of the track gets its two stops on it
--   diagonal   a click on the far end of the track, a move 24 east and 24 south, a click: diagonal pieces joined to it
--   branch     a click on a rail end in the middle of the track, a move 30 south, a click: a branch from the middle
--   built2     the diagonal and the branch get built
--   junction   the branch's junction gets chain signals (>= 4 within 24 tiles)
--   train      a freight train on a stop list depot -> Station 2 (at the branch's end) reaches Station 2 over the branch
--   warnings   #33: a depot no track reaches added to the train's stops gets "No track leads here from stop 2", and a
--              second train between the depot and Station 2 the passing-loop hint (the train panel, screenshot)
--   unit_click with the planner in hand, a click over one of the player's walkers selects nothing (the planner has the click)
--   q_ends     the first Q stops the planner's path (the rail stays in hand, as in vanilla), the second one ends laying:
--              the RTS cursor comes back and hover selection goes off again
-- Checks "[rts] r4p check <name>: PASS|FAIL ...", summary "[rts] r4p summary <passed>/<total>", marker RTS_R4P_DONE.
-- Screenshots build/shots-<copy>/rts-r4p-*.png (take_screenshot), window captures (path previews, the engine's own
-- overlays) build/shots-<copy>-window/. Test copy (self-test off), RTS_LOCALE=en or ru:
--   rm -rf build/r4p-en && mkdir -p build/r4p-en && cp -R mods/factorio-rts mods/mod-list.json build/r4p-en/
--   cp tools/probes/r4_rails_planner_gui.lua build/r4p-en/factorio-rts/scripts/
--   printf '\nrequire("scripts.r4_rails_planner_gui")\n' >> build/r4p-en/factorio-rts/control.lua
--   tools/gui-drive.sh build/r4p-en-gui.log build/shots-r4p-en-window RTS_R4P_DONE &
--   RTS_LOCALE=en tools/gui-run.sh build/r4p-en 900 RTS_R4P_DONE '\[rts\] (r4p|railplan|rails: planner)|rror'
-- Check that no other Factorio client runs first (the input goes to the front window).
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local cursor = require("scripts.cursor")
local buildings = require("scripts.buildings")
local research = require("scripts.research")
local logistics = require("scripts.logistics")
local rails = require("scripts.rails")
local railroutes = require("scripts.railroutes")
local hud = require("scripts.hud")
local selection = require("scripts.selection")

local KEY = {Q = 12}
local RAILS = {"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b"}
local RD = defines.rail_direction
local TS = defines.train_state
local ZOOM = 0.3

local function note(fmt, ...) util.log("r4p probe: " .. fmt, ...) end
local function check(P, name, ok, fmt, ...)
  P.pass, P.total = (P.pass or 0) + (ok and 1 or 0), (P.total or 0) + 1
  util.log("r4p check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end
local function drive(fmt, ...)
  storage.r4p_seq = (storage.r4p_seq or 0) + 1
  util.log("RTS_DRIVE %d " .. fmt, storage.r4p_seq, ...)
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
  local path = string.format("rts-r4p-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  note("screenshot %s", path)
end
local function spx(player, pos)
  local k = 32 * player.zoom
  return math.floor(640 + (pos.x - player.position.x) * k + 0.5), math.floor(400 + (pos.y - player.position.y) * k + 0.5)
end
local function hover_on(player) return player.game_view_settings.update_entity_selection end

-- rail ghosts and rails of the player in the box
local function census(player, P)
  local s = player.surface
  local g, by = 0, {}
  for _, e in ipairs(s.find_entities_filtered({area = P.box, name = "entity-ghost", force = player.force})) do
    for _, r in ipairs(RAILS) do
      if e.ghost_name == r then
        g = g + 1
        by[r] = (by[r] or 0) + 1
      end
    end
  end
  local built = s.count_entities_filtered({area = P.box, name = RAILS, force = player.force})
  return g, by, built
end

-- planner lines of the player's force: {id, line} sorted by id
local function planner_lines(player)
  local out = {}
  for id, l in pairs(storage.rails.lines) do
    if l.planner and l.force == player.force.name then out[#out + 1] = {id = id, line = l} end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- a point `back` tiles behind a rail end, inside its rail (the pointer rests there to hover the end)
local function inside(pos, dir, back)
  local a = dir * math.pi / 8 -- 16 directions, 0 = north
  return {x = pos.x - math.sin(a) * back, y = pos.y + math.cos(a) * back}
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player, P)
  local el = find(player.gui.screen.rts_lobby, "rts_lobby_start")
  lobby.on_click({element = el, player_index = player.index, name = defines.events.on_gui_click})
  return 180
end)

-- the scene: a cleared, charted box, a depot with an east-west platform, stocks
step(function(player, P)
  storage.rails = storage.rails or {}
  storage.rails.test_nation = true
  local tech = player.force.technologies["rts-railways"]
  if tech then tech.researched = true end
  research.apply(player.force)
  local cc = buildings.main_cc(player.force.name)
  P.cc = cc and cc.entity.position or {x = -88, y = 0}
  local s = player.surface
  local o = {x = P.cc.x + 14, y = P.cc.y - 44}
  P.box = {{o.x - 6, o.y - 12}, {o.x + 130, o.y + 90}}
  local tiles = {}
  for _, t in ipairs(s.find_tiles_filtered({area = P.box, collision_mask = "water_tile"})) do
    tiles[#tiles + 1] = {name = "grass-1", position = t.position}
  end
  if #tiles > 0 then s.set_tiles(tiles) end
  local gone = 0
  for _, e in ipairs(s.find_entities_filtered({area = P.box, type = {"tree", "simple-entity", "cliff", "fish"}})) do
    e.destroy()
    gone = gone + 1
  end
  player.force.chart(s, P.box)
  -- the depot: platform east-west, south of it (the fixture's reuse_site trick)
  local dpos = {x = 2 * math.floor(o.x / 2) + 20, y = 2 * math.floor(o.y / 2)}
  storage.rails.reuse_site = {force = player.force.name, x = dpos.x, y = dpos.y, spec = {axis = "x", side = 1,
    track = 2 * math.floor((dpos.y + rails.PLATFORM_GAP) / 2) + 1}}
  local de = s.create_entity({name = rails.DEPOT, position = dpos, force = player.force, raise_built = true})
  storage.rails.reuse_site = nil
  P.depot = de and de.unit_number
  local d = P.depot and rails.depot(P.depot)
  for i = 1, 4 do
    local sp = s.find_non_colliding_position("rts-stockpile", {dpos.x - 10 + i * 4, dpos.y - 6}, 8, 1, true)
    local st = sp and s.create_entity({name = "rts-stockpile", position = sp, force = player.force, raise_built = true})
    if st then buildings.register(st) end
  end
  local net = P.depot and logistics.hub_network(P.depot)
  for _, it in ipairs({{rails.LOCO_KIT, 6}, {rails.CWAGON_KIT, 2}, {rails.WAGON_KIT, 4}, {"coal", 400},
                       {rails.RAIL, 1200}, {"iron-plate", 2000}, {"rail-chain-signal", 40}}) do
    if net then net.insert({name = it[1], count = it[2]}) end
  end
  local ccnet = cc and cc.entity.logistic_network
  if ccnet then ccnet.insert({name = rails.RAIL, count = 200}) end
  -- the platform's east end
  local pr = d and d.platform and d.platform.rails
  local last = pr and pr[#pr]
  if last then
    for _, rd in ipairs({RD.front, RD.back}) do
      local loc = last.get_rail_end(rd).location
      if not P.E or loc.position.x > P.E.x then P.E = {x = loc.position.x, y = loc.position.y, d = loc.direction} end
    end
    P.platform_end = last
  end
  note("scene: box %s-%s, %d water tiles filled, %d trees/rocks/cliffs removed; depot %s, platform end %s, network %s",
    util.pos_str(P.box[1]), util.pos_str(P.box[2]), #tiles, gone, tostring(P.depot), P.E and util.pos_str(P.E) or "-",
    tostring(net ~= nil))
  P.view = {x = P.E.x + 40, y = P.E.y + 10} -- (zoom 0.3: the whole scene clear of the HUD panels)
  camera.jump_to(player, P.view)
  player.zoom = ZOOM
  return 60
end)

-- cursor + drag 1
step(function(player, P)
  player.zoom = ZOOM
  hud.build_click(player, "rail")
  local msg = find(player.gui.top, "message") or find(player.gui.screen, "message")
  check(P, "cursor", cursor.holds_planner(player) and hover_on(player),
    "the Rail button: cursor ghost %s, rail planner %s, hover selection %s", tostring(cursor.ghost_name(player)),
    tostring(cursor.holds_planner(player)), tostring(hover_on(player)))
  local a = inside(P.E, P.E.d, 0.5)
  P.T1 = {x = P.E.x + 60, y = P.E.y + 24}
  local x1, y1 = spx(player, a)
  local x2, y2 = spx(player, P.T1)
  note("drag 1: platform end %s, pointer (%d, %d) -> (%d, %d)", util.pos_str(P.E), x1, y1, x2, y2)
  drive("move %d %d", x1, y1)
  drive("sleep 700")
  drive("capture drag1-hover")
  drive("drag %d %d %d %d left none 50 60", x1, y1, x2, y2)
  drive("sleep 300")
  drive("capture drag1-preview")
  P.x2, P.y2 = x2, y2
  return 420
end)

step(function(player, P)
  P.g_drag = census(player, P)
  note("drag 1: %d rail ghosts after the drag alone; a click at its end builds the previewed path", P.g_drag)
  drive("click %d %d", P.x2, P.y2)
  drive("sleep 300")
  drive("capture drag1-built")
  return 240
end)

step(function(player, P)
  local g, by = census(player, P)
  local curves = (by["curved-rail-a"] or 0) + (by["curved-rail-b"] or 0) + (by["half-diagonal-rail"] or 0)
  shot(player, "drag1")
  local lines = planner_lines(player)
  local joined = false
  for _, L in ipairs(lines) do
    if L.line.start_rail == P.platform_end or (L.line.start_rail and L.line.start_rail.valid
       and P.platform_end.valid and util.distance(L.line.start_rail.position, P.platform_end.position) < 0.1) then
      joined = true
    end
  end
  P.track1 = {}
  for _, L in ipairs(lines) do
    for _, p in ipairs(L.line.pieces) do P.track1[#P.track1 + 1] = {name = p.name, x = p.x, y = p.y, d = p.d} end
  end
  P.lines1 = #lines
  check(P, "drag1", g >= 15 and curves > 0 and joined, "%d rail ghosts %s (%d after the drag alone), %d planner lines, "
    .. "the first starts on the platform end rail: %s", g, serpent.line(by), P.g_drag or -1, #lines, tostring(joined))
  if #P.track1 == 0 then P.broken = "no track 1" end
  P.t_build1 = game.tick
  return 120
end)

-- wait for track 1 to stand
local function built_of(player, list)
  local s, n = player.surface, 0
  for _, q in ipairs(list) do
    local e = s.find_entity(q.name, {q.x, q.y})
    if e and e.valid and e.direction == q.d then n = n + 1 end
  end
  return n
end

step(function(player, P)
  local n = built_of(player, P.track1)
  if n < #P.track1 and game.tick - P.t_build1 < 150 * 60 then
    P.i = P.i - 1
    return 120
  end
  local crews = 0
  for _, rec in pairs(storage.rails.trains) do
    if rec.kind == "construction" and rec.force == player.force.name then crews = crews + 1 end
  end
  local robot, used = 0, 0
  for _, L in ipairs(planner_lines(player)) do
    robot, used = robot + (L.line.robot or 0), used + (L.line.used or 0)
  end
  check(P, "built1", n == #P.track1 and #P.track1 > 0, "%d of %d pieces of track 1 built after %.0f s (%d rails by robots, "
    .. "%d by crews, crews out now %d)", n, #P.track1, (game.tick - P.t_build1) / 60, robot, used - robot, crews)
  shot(player, "built1")
  -- Station 1 beside a straight piece near the far end of track 1
  local s = player.surface
  local best
  for _, q in ipairs(P.track1) do
    if q.name == "straight-rail" and (not best or q.x > best.x) then best = q end
  end
  if best then
    local horiz = best.d == defines.direction.east or best.d == defines.direction.west
    local want = horiz and {x = best.x, y = best.y - 5} or {x = best.x - 5, y = best.y}
    local pos = s.find_non_colliding_position(rails.STATION, want, 4, 0.5, true)
    local st = pos and s.create_entity({name = rails.STATION, position = pos, force = player.force, raise_built = true})
    P.station1 = st and st.unit_number
    note("station 1 at %s next to the straight piece at %s", pos and util.pos_str(pos) or "-", util.pos_str(best))
  end
  -- the far end of track 1: the end of a planner piece no other piece continues from
  local ends = {}
  for _, L in ipairs(planner_lines(player)) do
    for _, p in ipairs(L.line.pieces) do
      for _, e in ipairs({{p.sx, p.sy, (p.sd + 8) % 16}, {p.gx, p.gy, p.gd}}) do
        local k = e[1] .. "," .. e[2]
        ends[k] = ends[k] or {x = e[1], y = e[2], d = e[3], n = 0}
        ends[k].n = ends[k].n + 1
      end
    end
  end
  local far
  for _, e in pairs(ends) do
    if e.n == 1 and (not far or e.x > far.x) then far = e end
  end
  P.far = far
  -- (the planner goes on from its last end until it is stopped: the first Q stops the path, the second one clears the
  -- cursor, as in vanilla)
  drive("key %d", KEY.Q)
  drive("sleep 500")
  drive("key %d", KEY.Q)
  return 120
end)

step(function(player, P)
  local d = P.station1 and rails.depot(P.station1)
  local stops = d and d.platform and #d.platform.stops or 0
  check(P, "station1", stops == 2, "Station 1 %s: %d stops on the track", tostring(P.station1), stops)
  -- diagonal: click on the far end of track 1, move 24 east and 24 south, click
  hud.build_click(player, "rail")
  if not cursor.holds_planner(player) then hud.build_click(player, "rail") end
  local f = P.far
  if not f then
    note("diagonal: no far end (%s)", tostring(P.broken))
    return 30
  end
  local a = inside(f, f.d, 0.6)
  local b = {x = f.x + 16, y = f.y + 12}
  local x1, y1 = spx(player, a)
  local x2, y2 = spx(player, b)
  local mx, my = spx(player, {x = f.x + 8, y = f.y + 6})
  note("diagonal from the far end %s (heading %d): (%d, %d) -> (%d, %d)", util.pos_str(f), f.d, x1, y1, x2, y2)
  P.lines_before_diag = {}
  for _, L in ipairs(planner_lines(player)) do P.lines_before_diag[L.id] = true end
  drive("move %d %d", x1, y1)
  drive("sleep 700")
  drive("click %d %d", x1, y1)
  drive("sleep 400")
  drive("move %d %d", mx, my)
  drive("sleep 300")
  drive("move %d %d", x2, y2)
  drive("sleep 900")
  drive("capture diagonal-preview")
  drive("click %d %d", x2, y2)
  drive("sleep 300")
  return 480 -- (the drive takes about 4 s; the ghosts are handed over a second after the last one)
end)

step(function(player, P)
  local new, by, joined = {}, {}, false
  P.lines_before_diag = P.lines_before_diag or {}
  P.far = P.far or {x = 0, y = 0, d = 0}
  for _, L in ipairs(planner_lines(player)) do
    if not P.lines_before_diag[L.id] then
      new[#new + 1] = L
      for _, p in ipairs(L.line.pieces) do by[p.name] = (by[p.name] or 0) + 1 end
      local p1 = L.line.pieces[1]
      if math.abs(p1.sx - P.far.x) < 0.2 and math.abs(p1.sy - P.far.y) < 0.2 then joined = true end
      local pn = L.line.pieces[#L.line.pieces]
      if math.abs(pn.gx - P.far.x) < 0.2 and math.abs(pn.gy - P.far.y) < 0.2 then joined = true end
    end
  end
  P.diag = {}
  for _, L in ipairs(new) do
    for _, p in ipairs(L.line.pieces) do P.diag[#P.diag + 1] = {name = p.name, x = p.x, y = p.y, d = p.d} end
  end
  check(P, "diagonal", #P.diag >= 5 and (by["half-diagonal-rail"] or 0) + (by["curved-rail-a"] or 0)
    + (by["curved-rail-b"] or 0) > 0 and joined, "%d new pieces %s in %d lines, joined to the far end of track 1: %s",
    #P.diag, serpent.line(by), #new, tostring(joined))
  shot(player, "diagonal")
  drive("key %d", KEY.Q)
  drive("sleep 500")
  drive("key %d", KEY.Q)
  return 120
end)

step(function(player, P)
  hud.build_click(player, "rail")
  if not cursor.holds_planner(player) then hud.build_click(player, "rail") end
  -- branch: a rail of track 1 near its middle; the pointer on its east end
  local s = player.surface
  local mid = P.track1[math.floor(#P.track1 / 2)]
  local rail = mid and s.find_entity(mid.name, {mid.x, mid.y})
  local e
  if rail then
    for _, rd in ipairs({RD.front, RD.back}) do
      local loc = rail.get_rail_end(rd).location
      if not e or loc.position.x > e.x then e = {x = loc.position.x, y = loc.position.y, d = loc.direction} end
    end
  end
  P.jpos = e
  if not e then
    note("branch: no rail in the middle of track 1 (%s)", tostring(P.broken))
    P.jpos = {x = 0, y = 0}
    P.lines_before_branch = {}
    return 30
  end
  local a = inside(e, e.d, 0.6)
  local b = {x = e.x + 8, y = e.y + 24}
  local x1, y1 = spx(player, a)
  local x2, y2 = spx(player, b)
  local mx, my = spx(player, {x = e.x + 6, y = e.y + 12})
  note("branch from the rail end %s (heading %d) of %s at %s: (%d, %d) -> (%d, %d)", util.pos_str(e), e.d,
    mid.name, util.pos_str(mid), x1, y1, x2, y2)
  P.lines_before_branch = {}
  for _, L in ipairs(planner_lines(player)) do P.lines_before_branch[L.id] = true end
  drive("move %d %d", x1, y1)
  drive("sleep 700")
  drive("capture branch-hover")
  drive("click %d %d", x1, y1)
  drive("sleep 400")
  drive("move %d %d", mx, my)
  drive("sleep 300")
  drive("move %d %d", x2, y2)
  drive("sleep 900")
  drive("capture branch-preview")
  drive("click %d %d", x2, y2)
  drive("sleep 300")
  return 480
end)

step(function(player, P)
  P.branch = {}
  local starts = false
  for _, L in ipairs(planner_lines(player)) do
    if not P.lines_before_branch[L.id] then
      for _, p in ipairs(L.line.pieces) do P.branch[#P.branch + 1] = {name = p.name, x = p.x, y = p.y, d = p.d} end
      local p1 = L.line.pieces[1]
      if L.line.start_rail and math.abs(p1.sx - P.jpos.x) < 0.2 and math.abs(p1.sy - P.jpos.y) < 0.2 then starts = true end
    end
  end
  check(P, "branch", #P.branch >= 5 and starts, "%d branch pieces, its line starts on track 1 at %s: %s", #P.branch,
    util.pos_str(P.jpos), tostring(starts))
  shot(player, "branch")
  P.t_build2 = game.tick
  return 120
end)

step(function(player, P)
  local all = {}
  for _, q in ipairs(P.diag) do all[#all + 1] = q end
  for _, q in ipairs(P.branch) do all[#all + 1] = q end
  local n = built_of(player, all)
  if n < #all and game.tick - P.t_build2 < 180 * 60 then
    P.i = P.i - 1
    return 120
  end
  check(P, "built2", n == #all and #all > 0, "%d of %d pieces of the diagonal and the branch built after %.0f s", n, #all,
    (game.tick - P.t_build2) / 60)
  local s = player.surface
  local chains = s.count_entities_filtered({position = P.jpos, radius = 24, name = "rail-chain-signal",
                                            force = player.force})
  check(P, "junction", chains >= 4, "%d chain signals within 24 tiles of the branch junction %s", chains,
    util.pos_str(P.jpos))
  shot(player, "built2")
  -- Station 2 beside the branch's last straight piece (or its last piece)
  local best = P.branch[#P.branch]
  if not best then
    P.t_train = game.tick
    return 30
  end
  for _, q in ipairs(P.branch) do
    if q.name == "straight-rail" and q.y >= best.y - 6 then best = q end
  end
  local horiz = best.d == defines.direction.east or best.d == defines.direction.west
  local want = horiz and {x = best.x, y = best.y - 5} or {x = best.x - 5, y = best.y}
  local pos = s.find_non_colliding_position(rails.STATION, want, 6, 0.5, true)
  local st = pos and s.create_entity({name = rails.STATION, position = pos, force = player.force, raise_built = true})
  P.station2 = st and st.unit_number
  note("station 2 at %s next to %s at %s", pos and util.pos_str(pos) or "-", best.name, util.pos_str(best))
  P.t_train = game.tick
  drive("key %d", KEY.Q)
  drive("sleep 500")
  drive("key %d", KEY.Q)
  return 120
end)

-- a freight train depot -> Station 2 (over the branch)
step(function(player, P)
  local d2 = P.station2 and rails.depot(P.station2)
  local stops = d2 and d2.platform and #d2.platform.stops or 0
  if not P.station2 then
    check(P, "train", false, "no Station 2 (%s)", tostring(P.broken))
    return 30
  end
  if not P.train then
    local t, why = rails.create_train(P.depot, "cargo")
    if not t then
      if game.tick - P.t_train < 90 * 60 then
        P.i = P.i - 1
        return 120
      end
      check(P, "train", false, "no train deployed: %s (Station 2 stops %d)", tostring(why), stops)
      return 30
    end
    local ok, w = railroutes.set(t, {{target = P.depot, wait = {type = "time", seconds = 3}},
                                     {target = P.station2, wait = {type = "time", seconds = 3}}})
    P.train = rails.train_record(t)
    P.t_route = game.tick
    note("train %d deployed, route set %s (%s), Station 2 stops %d", t.id, tostring(ok), tostring(w), stops)
  end
  local rec = P.train
  local t = rails.train_of(rec)
  local at2 = rec.dwell and rec.dwell.stop == 2 and t and t.state == TS.wait_station
  if not at2 and game.tick - P.t_route < 120 * 60 then
    P.i = P.i - 1
    return 60
  end
  check(P, "train", at2 == true, "train %s at Station 2 (stop 2 of its list) after %.0f s: %s, state %s",
    t and tostring(t.id) or "-", (game.tick - P.t_route) / 60, tostring(at2),
    t and util.define_name(TS, t.state) or "-")
  camera.jump_to(player, t and t.front_stock.position or P.view)
  player.zoom = ZOOM
  return 30
end)

step(function(player, P)
  shot(player, "train")
  camera.jump_to(player, P.view)
  player.zoom = ZOOM
  return 30
end)

-- #33 items 1 and 2: the stop list warns about a stop no track leads to and about a second train between the same stops
step(function(player, P)
  local s = player.surface
  local t = P.train and rails.train_of(P.train)
  if not t then
    check(P, "warnings", false, "no train")
    return 30
  end
  -- a depot of its own, with nothing connecting its platform to the track
  local pos = {x = 2 * math.floor((P.E.x + 70) / 2), y = 2 * math.floor((P.E.y - 2) / 2)}
  storage.rails.reuse_site = {force = player.force.name, x = pos.x, y = pos.y, spec = {axis = "x", side = 1,
    track = 2 * math.floor((pos.y + rails.PLATFORM_GAP) / 2) + 1}}
  local de = s.create_entity({name = rails.DEPOT, position = pos, force = player.force, raise_built = true})
  storage.rails.reuse_site = nil
  P.lone = de and de.unit_number
  local idx = P.lone and railroutes.add(t, P.lone)
  local t2 = rails.create_train(P.depot, "cargo")
  if t2 then
    railroutes.set(t2, {{target = P.depot, wait = {type = "time", seconds = 3}},
                        {target = P.station2, wait = {type = "time", seconds = 3}}})
  end
  P.train2 = t2 and t2.id
  local loco = t.front_stock
  selection.select_building(player.index, loco.unit_number)
  camera.jump_to(player, loco.position)
  player.zoom = ZOOM
  local un = railroutes.unreachable(P.train)
  local shared = railroutes.shared_with(P.train)
  note("warnings: lone depot %s added as stop %s; unreachable %s, shared with %s (second train %s)", tostring(P.lone),
    tostring(idx), serpent.line(un), tostring(shared), tostring(P.train2))
  P.warn = {un = un, shared = shared}
  return 120
end)

step(function(player, P)
  local frame = player.gui.screen.rts_railgui_frame or find(player.gui.screen, "rts_railgui_frame")
  local texts = {}
  local function walk(el)
    if el.type == "label" and type(el.caption) == "table" then
      local key = el.caption[1]
      if key == "rts.route-unreachable" or key == "rts.route-shared" then texts[#texts + 1] = key end
    end
    for _, c in pairs(el.children) do walk(c) end
  end
  for _, el in pairs(player.gui.screen.children) do walk(el) end
  local un = P.warn and P.warn.un or {}
  check(P, "warnings", un[3] == 2 and un[1] == 3 and P.warn.shared == P.train2 and #texts >= 2,
    "stop 3 (a depot with no track to it) unreachable from stop %s, stop 1 from stop %s; shared with train %s (the "
    .. "second train %s); warning labels in the panel %s", tostring(un[3]), tostring(un[1]), tostring(P.warn.shared),
    tostring(P.train2), table.concat(texts, ", "))
  shot(player, "warnings")
  selection.clear(player.index)
  camera.jump_to(player, P.view)
  player.zoom = ZOOM
  return 60
end)

-- a click over one of the player's walkers with the planner in hand
step(function(player, P)
  hud.build_click(player, "rail")
  if not cursor.holds_planner(player) then hud.build_click(player, "rail") end
  selection.clear(player.index)
  local s = player.surface
  local unit
  for _, u in ipairs(s.find_entities_filtered({position = P.cc, radius = 40, force = player.force, type = "spider-unit"})) do
    unit = unit or u
  end
  if not unit then
    for _, u in ipairs(s.find_entities_filtered({position = P.cc, radius = 40, force = player.force, type = "unit"})) do
      unit = unit or u
    end
  end
  P.unit = unit and unit.position
  if unit then
    camera.jump_to(player, unit.position)
    player.zoom = ZOOM
  end
  return 30
end)

step(function(player, P)
  if P.unit then
    local x, y = spx(player, P.unit)
    drive("move %d %d", x, y)
    drive("sleep 500")
    drive("capture unit-hover")
    drive("click %d %d", x, y)
    drive("sleep 300")
  end
  return 150
end)

step(function(player, P)
  local n = selection.count(player.index)
  local near = P.unit and player.surface.count_entities_filtered({position = P.unit, radius = 4, name = "entity-ghost",
                                                                    force = player.force}) or 0
  check(P, "unit_click", P.unit ~= nil and n == 0 and cursor.holds_planner(player),
    "a click over a walker at %s with the planner in hand: %d units selected, planner still in hand %s, %d ghosts "
    .. "placed there", P.unit and util.pos_str(P.unit) or "-", n, tostring(cursor.holds_planner(player)), near)
  drive("key %d", KEY.Q)
  drive("sleep 500")
  drive("key %d", KEY.Q)
  return 120
end)

-- Q with a path under way: the first Q stops the path (the rail stays in hand), the second one ends laying
step(function(player, P)
  hud.build_click(player, "rail")
  if not cursor.holds_planner(player) then hud.build_click(player, "rail") end
  local f = P.far or P.E
  camera.jump_to(player, P.view)
  player.zoom = ZOOM
  P.qf = f
  return 30
end)

step(function(player, P)
  local f = P.qf
  local x1, y1 = spx(player, inside(f, f.d, 0.6))
  local x2, y2 = spx(player, {x = f.x + 6, y = f.y - 10})
  drive("move %d %d", x1, y1)
  drive("sleep 600")
  drive("click %d %d", x1, y1)
  drive("sleep 400")
  drive("move %d %d", x2, y2)
  drive("sleep 600")
  drive("capture q-path")
  drive("key %d", KEY.Q)
  drive("sleep 400")
  drive("capture q-first")
  return 300
end)

step(function(player, P)
  P.q1 = {planner = cursor.holds_planner(player), hover = hover_on(player)}
  drive("key %d", KEY.Q)
  return 120
end)

step(function(player, P)
  check(P, "q_ends", P.q1.planner and cursor.holds_tool(player) and not hover_on(player)
    and not cursor.holds_planner(player), "after the first Q: planner in hand %s (the path stopped), hover %s; after "
    .. "the second Q: RTS cursor %s, hover selection %s", tostring(P.q1.planner), tostring(P.q1.hover),
    tostring(cursor.holds_tool(player)), tostring(hover_on(player)))
  shot(player, "end")
  util.log("r4p summary %d/%d", P.pass or 0, P.total or 0)
  util.log("RTS_R4P_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r4p_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.r4p_probe = P
  end
  if P.done or game.tick < P.at then return end
  local fn = STEPS[P.i]
  if not fn then
    P.done = true
    return
  end
  P.i = P.i + 1
  local wait = fn(player, P)
  if not wait then
    P.done = true
    return
  end
  P.at = game.tick + wait
end)

events.on(defines.events.on_train_changed_state, function(e)
  local P = storage.r4p_probe
  if not (P and P.train) or e.train.state ~= TS.wait_station then return end
  local rec = rails.train_record(e.train)
  if rec == P.train and rec.dwell then note("train at stop %s", tostring(rec.dwell.stop)) end
end)
