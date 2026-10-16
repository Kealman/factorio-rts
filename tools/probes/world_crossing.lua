-- World crossing probe (test copy only: tools/autotest-run.sh EXTRA_LUA=tools/probes/world_crossing.lua; docs/PHASE5-M1.md
-- §4 World). Starts a Nation match (CFG), stops the AI commanders, generates the whole map, then for one mountain
-- range and one river (barrier rays of the plan) picks a mid-span point far from the passes and fords, finds the real
-- barrier there on the tiles and spawns a walker, a heavy, a raider, an artillery, two drones and a hauler 70 tiles
-- in front of it. Every unit is ordered (orders.move; the hauler: logistics.move_hauler) to the point 70 tiles
-- behind it. Every 10 ticks the probe reads each unit's warped position (rts_w_wx / rts_w_wy, the space in which the
-- barrier is an exact band around the planned polyline and every pass / ford an exact disc) and records a crossing
-- whenever the unit changes side of the polyline: "pass"/"ford" when it happens inside a crossing disc, "end" around
-- the barrier's inner end, otherwise "MID-SPAN". PASS per unit: it arrives within 8 tiles of its goal and never
-- crossed mid-span. Log lines "[rts] crossing probe ...", checks "[rts] autotest check crossing_...", and a final
-- "[rts] autotest summary P/T".
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local world = require("scripts.world")
local ai = require("scripts.ai.init")
local match = require("scripts.match")
local units = require("scripts.units")
local orders = require("scripts.orders")
local logistics = require("scripts.logistics")

local CFG = {opponents = 1, world_size = 2048, timeout = 7 * 60 * 60, offset = 70}
local UNITS = {{"rts-walker", "walker"}, {"rts-walker-heavy", "heavy"}, {"rts-raider", "raider"},
               {"rts-artillery", "artillery"}, {"rts-drone", "drone"}, {"rts-drone", "drone"}}
local F = util.PLAYER_FORCE

local function S() return storage.crossing_probe end

local function check(name, ok, fmt, ...)
  local st = S()
  if ok then st.pass = st.pass + 1 else st.fail = st.fail + 1 end
  util.log("autotest check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

events.on_init(function()
  storage.debug = storage.debug or {}
  storage.debug.autotest = false
  storage.crossing_probe = {step = "start", pass = 0, fail = 0}
end)

local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

-- Nearest point of a polyline: distance, segment index, parameter t, signed side (cross product sign).
local function poly_info(pts, p)
  local best, bi, bt, side
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local vx, vy = b.x - a.x, b.y - a.y
    local l2 = vx * vx + vy * vy
    local t = l2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / l2)) or 0
    local qx, qy = a.x + vx * t, a.y + vy * t
    local d = math.sqrt((p.x - qx) ^ 2 + (p.y - qy) ^ 2)
    if not best or d < best then
      best, bi, bt = d, i, t
      local cr = vx * (p.y - a.y) - vy * (p.x - a.x)
      side = cr >= 0 and 1 or -1
    end
  end
  return best, bi, bt, side
end

local function point_at(pts, s)
  for i = 1, #pts - 1 do
    local l = dist(pts[i], pts[i + 1])
    if s <= l or i == #pts - 1 then
      local t = l > 0 and math.min(1, s / l) or 0
      return {x = pts[i].x + (pts[i + 1].x - pts[i].x) * t, y = pts[i].y + (pts[i + 1].y - pts[i].y) * t}, i
    end
    s = s - l
  end
end

local function blocking(surface, p)
  local t = surface.get_tile(p.x, p.y)
  return t.name == "rts-mountain" or (t.collides_with("player") and t.name ~= "rts-ford")
end

-- A mid-span test across barrier b: the arc length farthest from its crossings (and 150 tiles from its inner end,
-- the map edge and the sea), the real barrier found on the tiles along the normal, start / goal CFG.offset beyond.
local function setup_lane(surface, P, b)
  local pts = b.points
  local total = 0
  for i = 1, #pts - 1 do total = total + dist(pts[i], pts[i + 1]) end
  local cross = {}
  for _, cid in ipairs(b.crossings) do cross[#cross + 1] = P.crossings[cid] end
  local best, best_s
  for s = 150, total - 40, 10 do
    local p = point_at(pts, s)
    local edge = P.half - math.max(math.abs(p.x), math.abs(p.y))
    if edge > 160 then
      local dc = math.huge
      for _, c in ipairs(cross) do dc = math.min(dc, math.abs(s - c.along)) end
      -- the nearest crossing must be clearly shorter than walking round the open inner end
      if dc < 600 and dc >= 120 and s - dc > 120 and (not best or dc > best) then best, best_s = dc, s end
    end
  end
  if not best_s then return nil, "no mid-span point" end
  local p, i = point_at(pts, best_s)
  local tx, ty = pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y
  local l = math.sqrt(tx * tx + ty * ty)
  local n = {x = -ty / l, y = tx / l}
  -- the real barrier along the normal: the blocked run nearest to p
  local lo, hi
  for d = -60, 60 do
    local q = {x = p.x + n.x * d, y = p.y + n.y * d}
    if blocking(surface, q) then
      lo = lo or d
      hi = d
    end
  end
  if not lo then return nil, "no barrier tiles on the normal at " .. util.pos_str(p) end
  local mid = (lo + hi) / 2
  local c = {x = p.x + n.x * mid, y = p.y + n.y * mid}
  local function land(sign)
    for d = CFG.offset, CFG.offset + 60, 4 do
      local q = {x = math.floor(c.x + n.x * d * sign) + 0.5, y = math.floor(c.y + n.y * d * sign) + 0.5}
      local okq = true
      for dx = -3, 3, 3 do
        for dy = -3, 3, 3 do
          if surface.get_tile(q.x + dx, q.y + dy).collides_with("player") then okq = false end
        end
      end
      if okq then return q end
    end
  end
  local a, g = land(-1), land(1)
  if not (a and g) then return nil, "no land beside the barrier" end
  local blocked = 0
  for k = 0, 200 do
    local q = {x = a.x + (g.x - a.x) * k / 200, y = a.y + (g.y - a.y) * k / 200}
    if blocking(surface, q) then blocked = blocked + 1 end
  end
  return {barrier = b, start = a, goal = g, center = c, s = best_s, nearest_crossing = best, blocked_samples = blocked,
          width = hi - lo + 1, cross = cross}
end

local function spawn_lane(surface, lane)
  lane.units = {}
  local list = {}
  for i, u in ipairs(UNITS) do
    local pos = {x = lane.start.x + (i - 3) * 4, y = lane.start.y}
    local e = units.spawn(u[1], pos, F, u[2], surface)
    if e then
      lane.units[#lane.units + 1] = {un = e.unit_number, entity = e, kind = u[2], flips = {}}
      list[#list + 1] = e
    end
  end
  orders.move(list, lane.goal)
  local he = logistics.spawn_hauler(surface, {x = lane.start.x, y = lane.start.y + 6}, F, nil)
  if he then
    lane.units[#lane.units + 1] = {un = he.unit_number, entity = he, kind = "hauler", flips = {}}
    logistics.move_hauler(he.unit_number, lane.goal)
  end
end

-- Warped positions of every unit of a lane (one calculate_tile_properties call).
local function track(surface, lane, tick)
  local pos, idx = {}, {}
  for i, u in ipairs(lane.units) do
    if u.entity.valid and not u.arrived then
      pos[#pos + 1] = u.entity.position
      idx[#idx + 1] = i
    end
  end
  if #pos == 0 then return end
  local res = surface.calculate_tile_properties({"rts_w_wx", "rts_w_wy"}, pos)
  local pts = lane.barrier.points
  for k, i in ipairs(idx) do
    local u = lane.units[i]
    local q = {x = res.rts_w_wx[k], y = res.rts_w_wy[k]}
    local d, si, t, side = poly_info(pts, q)
    if u.side and side ~= u.side then
      local kind = "MID-SPAN"
      for _, c in ipairs(lane.cross) do
        if dist(q, c) <= c.r + 4 then kind = c.kind end
      end
      if si == 1 and t <= 0 then kind = "end" end
      u.flips[#u.flips + 1] = {kind = kind, at = {x = pos[k].x, y = pos[k].y}, tick = tick}
      util.log("crossing probe: %s #%d crossed the %s (%s) at %s, warped %s, distance %.1f from the polyline: %s",
        u.kind, u.un, lane.barrier.kind, world.PROPER[lane.barrier.proper], util.pos_str(pos[k]), util.pos_str(q), d, kind)
    end
    u.side = side
    if dist(pos[k], lane.goal) <= 8 then
      u.arrived = tick
      util.log("crossing probe: %s #%d arrived after %.0f s", u.kind, u.un, (tick - lane.started) / 60)
    end
  end
end

local function report(lane, tag)
  for _, u in ipairs(lane.units) do
    local kinds, mid = {}, 0
    for _, f in ipairs(u.flips) do
      kinds[#kinds + 1] = f.kind
      if f.kind == "MID-SPAN" then mid = mid + 1 end
    end
    check(string.format("crossing_%s_%s_%d", tag, u.kind, u.un), u.arrived ~= nil and mid == 0 and #u.flips > 0,
      "%s: %s, crossings [%s]", u.kind, u.arrived and string.format("arrived after %.0f s", (u.arrived - lane.started) / 60)
      or "did not arrive", table.concat(kinds, " "))
  end
end

events.on_nth_tick(10, function(e)
  local st = S()
  if not st or st.done or e.tick < 150 then return end
  if st.step == "start" then
    lobby.start_match({opponents = CFG.opponents, difficulty = "normal", mode = "nation", world_size = CFG.world_size,
                       enemy_brain = "ai"}, "crossing-probe")
    for _, f in ipairs(match.ai_forces()) do ai.stop_force(f) end
    local surface = match.surface()
    surface.request_to_generate_chunks({0, 0}, math.ceil(storage.world.size / 64))
    surface.force_generate_chunk_requests()
    st.step = "lanes"
  elseif st.step == "lanes" then
    local surface = match.surface()
    local P = storage.world.plan
    st.lanes = {}
    for _, kind in ipairs({"range", "river"}) do
      for _, b in ipairs(P.barriers) do
        if b.kind == kind and b.ray and not st.lanes[kind] then
          local lane, why = setup_lane(surface, P, b)
          if lane then
            st.lanes[kind] = lane
            util.log("crossing probe: %s %s (barrier %d): mid-span at arc %.0f, nearest crossing %.0f tiles along, real width %d, "
              .. "start %s goal %s, %d/201 samples on the straight line blocked", kind, world.PROPER[b.proper], b.id,
              lane.s, lane.nearest_crossing, lane.width, util.pos_str(lane.start), util.pos_str(lane.goal), lane.blocked_samples)
          else
            util.log("crossing probe: %s barrier %d skipped: %s", kind, b.id, why)
          end
        end
      end
      local lane = st.lanes[kind]
      check("crossing_lane_" .. kind, lane ~= nil and lane.blocked_samples >= 20, "%s",
        lane and string.format("barrier %d, %d blocked samples between start and goal", lane.barrier.id, lane.blocked_samples)
        or "no lane")
      if lane then
        spawn_lane(surface, lane)
        lane.started = e.tick
      end
    end
    st.step = "run"
    st.run_tick = e.tick
  elseif st.step == "run" then
    local surface = match.surface()
    local all = true
    for _, lane in pairs(st.lanes) do
      track(surface, lane, e.tick)
      for _, u in ipairs(lane.units) do
        if not u.arrived and u.entity.valid then all = false end
      end
    end
    if all or e.tick - st.run_tick > CFG.timeout then
      for kind, lane in pairs(st.lanes) do report(lane, kind) end
      st.done = true
      util.log("autotest summary %d/%d%s", st.pass, st.pass + st.fail, st.fail == 0 and " (all passed)" or
        string.format(" (%d FAILED)", st.fail))
    end
  end
end)
