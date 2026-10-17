-- Phase 5 M3 world3 functional probe (test copy only; docs/PHASE5-M3.md §4 "World 3"). Run through tools/world3-run.sh
-- (tools/autotest-run.sh with EXTRA_LUA=tools/probes/world3_autotest.lua, a Nation match table and
-- STOP_ON='world3 autotest summary'). The AIs keep playing; the world fills in the background as in a real match.
--
-- At the start: the forced core is generated and the start kits placed; world.region_at answers from the plan for a
-- point whose chunk does not exist yet; worldgen.request_area on the far end of the request order is generated ahead of
-- it. Every minute a progress line ("world3: progress ...", tools/world3-run.sh turns them into rates and UPS). When the
-- fill is done: the fill time (8 minutes at most), every planned feature placed (patches with exact totals, oil wells,
-- ruins, ports, city-states with a City Center), the chart labels drawn as their chunks arrived (no refresh), every
-- chunk of the map generated, the real-tile check, the M2 world checks. CFG.save_at (seconds of match time) logs
-- "world3: save point" once: tools/world3-run.sh stops the server there (it saves) and loads the save; the probe then
-- checks that the fill went on after the save point.
-- Checks "[rts] autotest check w3_<name>: PASS|FAIL ...", the last line "[rts] world3 autotest summary P/T".
local events = require("scripts.events")
local util = require("scripts.util")
local world = require("scripts.world")
local worldgen = require("scripts.worldgen")
local strategic = require("scripts.strategic")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local match = require("scripts.match")

local CFG = {save_at = nil, fill_limit_s = 480, area_chunks = 3} -- tools/world3-run.sh rewrites this line

local function S()
  storage.w3test = storage.w3test or {pass = 0, fail = 0}
  return storage.w3test
end

local function check(name, ok, fmt, ...)
  local st = S()
  if ok then st.pass = st.pass + 1 else st.fail = st.fail + 1 end
  util.log("autotest check w3_%s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function surface() return storage.world and storage.world.surface and game.surfaces[storage.world.surface] end

local function chunk_generated(cx, cy)
  local s = surface()
  return s ~= nil and s.is_chunk_generated({cx, cy})
end

-- The in-map chunk farthest (Chebyshev, in chunks) from every spawn: the end of the ring order.
local function farthest_chunk(P)
  local c = P.size / 64
  local best, bd
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      local d = math.huge
      for _, sp in ipairs(P.spawns) do
        d = math.min(d, math.max(math.abs(cx - math.floor(sp.x / 32)), math.abs(cy - math.floor(sp.y / 32))))
      end
      if not chunk_generated(cx, cy) and (not bd or d > bd) then best, bd = {cx, cy}, d end
    end
  end
  return best, bd
end

local function at_start(st, W)
  local P = W.plan
  st.started = game.tick
  st.total = W.fill.total
  local prog = worldgen.progress()
  local kit_ok, nkit = #(W.checks.kit or {}) > 0, 0
  for _, k in ipairs(W.checks.kit or {}) do
    nkit = nkit + 1
    if not (k.placed and k.amount == k.total and k.dist <= world.KIT_RADIUS) then kit_ok = false end
  end
  local core_ok = prog.core == #P.core and prog.generated >= #P.core
  for _, key in ipairs(P.core) do
    local cx, cy = worldgen.key_xy(key)
    if not chunk_generated(cx, cy) then core_ok = false end
  end
  check("core", core_ok and kit_ok, "%d core chunks generated (plan %d), %d/%d of the map at the start (%.1f %%); %d "
    .. "start-kit patches placed with exact totals: %s", prog.core, #P.core, prog.generated, prog.planned,
    100 * prog.share, nkit, tostring(kit_ok))
  -- world.region_at from the plan where no chunk exists yet
  local far, ring = farthest_chunk(P)
  local pos = far and {x = far[1] * 32 + 16, y = far[2] * 32 + 16}
  local reg = pos and world.region_at(pos)
  local want = pos and world.plan_region_id(P, pos)
  check("region_from_plan", pos ~= nil and not worldgen.generated(pos) and reg ~= nil and reg.id == want
    and world.place_name(pos) ~= nil, "chunk %s (ring %s from the nearest spawn) not generated: %s; region_at -> %s "
    .. "(plan region %s)", far and (far[1] .. "," .. far[2]) or "-", tostring(ring), tostring(pos and not worldgen.generated(pos)),
    reg and (reg.id .. " " .. reg.label) or "nil", tostring(want))
  -- an AI planner asks for the far end of the order: it is generated ahead of the ring order
  if pos then
    local r = CFG.area_chunks * 16
    local area = {{pos.x - r, pos.y - r}, {pos.x + r - 1, pos.y + r - 1}}
    local requested, ready = worldgen.request_area("rts-ai-1", area)
    local c = P.size / 64 -- the map's chunks only (the area may reach past a corner)
    st.area = {x0 = math.max(-c, math.floor((pos.x - r) / 32)), y0 = math.max(-c, math.floor((pos.y - r) / 32)),
               x1 = math.min(c - 1, math.floor((pos.x + r - 1) / 32)), y1 = math.min(c - 1, math.floor((pos.y + r - 1) / 32)),
               tick = game.tick, requested = requested, ready = ready}
    util.log("world3: request_area around %s for rts-ai-1: %d requested, %d already generated", util.pos_str(pos),
      requested, ready)
  end
end

local function area_done(st)
  local A = st.area
  if not A then return false end
  for cx = A.x0, A.x1 do
    for cy = A.y0, A.y1 do
      if not chunk_generated(cx, cy) then return false end
    end
  end
  return true
end

local function final_checks(st, W)
  local P = W.plan
  local Fd = W.fill
  local secs = (Fd.done_tick - Fd.started) / 60
  check("fill_time", secs <= CFG.fill_limit_s, "%d chunks in %.1f s of game time (limit %d s), %d core", Fd.generated, secs,
    CFG.fill_limit_s, worldgen.progress().core)
  -- every chunk of the map
  local c = W.size / 64
  local missing = 0
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      if not chunk_generated(cx, cy) then missing = missing + 1 end
    end
  end
  local prog = worldgen.progress()
  check("all_chunks", missing == 0 and prog.done and prog.share >= 1, "%d of %d chunks missing; progress %d/%d (%.3f), done %s",
    missing, (2 * c) ^ 2, prog.generated, prog.planned, prog.share, tostring(prog.done))
  -- every feature placed
  local by, bad = {}, {}
  local patch_ok, oil_ok = true, true
  for i, f in ipairs(P.features) do
    by[f.type] = (by[f.type] or 0) + 1
    if not f.placed or f.ok == false then bad[#bad + 1] = f.type .. " #" .. i .. " at " .. f.x .. "," .. f.y end
    if f.type == "patch" and not (f.tiles and f.tiles > 0 and f.amount == f.total) then
      patch_ok = false
      bad[#bad + 1] = string.format("patch %s #%d %s/%s", f.name, i, tostring(f.amount), tostring(f.total))
    end
    if f.type == "oil" and f.wells_placed ~= #f.wells then
      oil_ok = false
      bad[#bad + 1] = string.format("oil #%d %s/%d wells", i, tostring(f.wells_placed), #f.wells)
    end
  end
  check("features", #bad == 0, "%d features placed %s%s", #P.features, serpent.line(by),
    #bad > 0 and (": BAD " .. table.concat(bad, "; ")) or "")
  check("patches_exact", patch_ok and oil_ok, "patches with exact totals %s, oil fields with every well %s",
    tostring(patch_ok), tostring(oil_ok))
  -- city-states with a City Center, ports, ruins
  local planned_cs, planned_ports, planned_ruins = 0, 0, 0
  for _, s in ipairs(P.sites) do
    if s.kind == "city_state" then planned_cs = planned_cs + 1
    elseif s.kind == "port" then planned_ports = planned_ports + 1
    elseif s.kind == "ruin" then planned_ruins = planned_ruins + 1 end
  end
  local live, first_tick, last_tick = 0, math.huge, 0
  for _, rec in ipairs(world.city_states()) do
    local cc = rec.city_id and cities.get(rec.city_id)
    if cc and cc.entity and cc.entity.valid then live = live + 1 end
    first_tick, last_tick = math.min(first_tick, rec.founded), math.max(last_tick, rec.founded)
  end
  check("city_states", live == planned_cs and planned_cs > 0, "%d of %d planned city-states have a City Center, founded "
    .. "%.1f-%.1f s after the start", live, planned_cs, (first_tick - Fd.started) / 60, (last_tick - Fd.started) / 60)
  local ruins = storage.mapgen and storage.mapgen.ruins or {}
  check("ruins_ports", #ruins >= planned_ruins and (by.port or 0) == planned_ports, "%d mapgen ruins (planned ruins %d), "
    .. "%d port features (planned %d)", #ruins, planned_ruins, by.port or 0, planned_ports)
  -- chart labels drawn as their chunks arrived (no refresh since the start)
  local lab_ok, parts = true, {}
  for _, f in ipairs(match.forces()) do
    local cnt = strategic.counts(f)
    if cnt.regions ~= #P.regions or cnt.chokes ~= #P.chokes or cnt.ports ~= planned_ports then lab_ok = false end
    parts[#parts + 1] = string.format("%s regions %d/%d chokes %d/%d ports %d/%d", f, cnt.regions, #P.regions, cnt.chokes,
      #P.chokes, cnt.ports, planned_ports)
  end
  check("labels_by_chunk", lab_ok, "%s", table.concat(parts, "; "))
  -- the area request was generated ahead of the ring order (a legacy-order world requests the whole map at once, so
  -- the area only has to exist when the fill is done)
  if st.area then
    local t = st.area_done and (st.area_done - st.area.tick) / 60
    local legacy = worldgen.legacy(P)
    check("request_area", st.area.requested > 0 and t ~= nil and (t <= 60 or legacy), "%d chunks requested for rts-ai-1 "
      .. "at the far end of the order, all generated %s s later (fill done %.0f s after the start%s)", st.area.requested,
      t and string.format("%.1f", t) or "never", secs, legacy and "; legacy order: the whole map was requested at once" or "")
  end
  -- save in the middle of the fill
  if st.save_tick then
    check("saveload_resumed", st.save_generated < W.fill.total and Fd.done_tick > st.save_tick,
      "saved at %.0f s with %d/%d chunks; after the load the fill finished at %.0f s", (st.save_tick - Fd.started) / 60,
      st.save_generated, W.fill.total, secs)
  end
  -- the real-tile check and the M2 world checks
  local post = W.checks.post
  check("connectivity_real", post ~= nil and #post.bad == 0, "%s", post and string.format("%d/%d targets reachable on "
    .. "real tiles", post.targets - #post.bad, post.targets) or "no real-tile check")
  territory.flush()
  world.w2_checks(check, "")
end

events.on_nth_tick(60, function(e)
  local st = S()
  local W = storage.world
  local m = storage.match
  if st.done or not (m and m.phase == "running" and W and W.plan and W.fill) then return end
  if not st.started then
    at_start(st, W)
    return
  end
  if st.area and not st.area_done and area_done(st) then
    st.area_done = game.tick
    util.log("world3: requested area generated %.1f s after the request", (game.tick - st.area.tick) / 60)
  end
  if not st.features_done then -- when the last planned feature was placed (objectives first in the background order)
    local all = true
    for _, f in ipairs(W.plan.features) do
      if not f.placed then all = false break end
    end
    if all then
      st.features_done = game.tick
      util.log("world3: every planned feature placed %.0f s after the start (%d/%d chunks generated)",
        (game.tick - st.started) / 60, W.fill.generated, W.fill.total)
    end
  end
  local t = (game.tick - st.started) / 60
  if (game.tick - st.started) % 3600 == 0 or (W.fill.done and not st.done_logged) then
    local p = worldgen.progress()
    util.log("world3: progress t=%d s generated %d/%d (%.1f %%) inflight %d done %s", math.floor(t), p.generated,
      p.planned, 100 * p.share, p.inflight, tostring(p.done))
    if W.fill.done then st.done_logged = true end
  end
  if CFG.save_at and not st.save_tick and t >= CFG.save_at then
    st.save_tick, st.save_generated = game.tick, W.fill.generated
    util.log("world3: save point at %d s: %d/%d chunks", math.floor(t), W.fill.generated, W.fill.total)
    return
  end
  if W.fill.done and W.checks and W.checks.post and (st.area_done or not st.area or t > 600) then
    st.done = true
    final_checks(st, W)
    util.log("world3 autotest summary %d/%d%s", st.pass, st.pass + st.fail, st.fail == 0 and " (all passed)" or
      string.format(" (%d FAILED)", st.fail))
  elseif t > CFG.fill_limit_s + 300 then
    st.done = true
    check("fill_time", false, "fill at %d/%d after %.0f s", W.fill.generated, W.fill.total, t)
    util.log("world3 autotest summary %d/%d (%d FAILED)", st.pass, st.pass + st.fail, st.fail)
  end
end)
