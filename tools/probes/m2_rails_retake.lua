-- Phase 5 M2 integration probe: an AI rail line whose far city is lost and retaken is taken up again
-- (scripts/rails.lua: line restore on the depot's force change, rails.ai_revive on rts_city_captured), and construction
-- trains leave with a full coal load. 1v1 Nation, seed 501 (rts-player's AI opens its line by minute 20):
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m2_rails_retake.lua STOP_ON=RTS_RAILS_RETAKE_DONE SEED=501 SPEED=8 \
--     DURATION_MIN=45 tools/autotest-run.sh m2i-retake '{opponents = 1, difficulty = "normal", mode = "nation",
--     world_size = 2048, enemy_brain = "ai"}' 3000
-- From minute 22: the far city of rts-player's program goes to rts-ai-1 (capture.flip), 60 s later back. Checks
-- ("[rts] rails retake check <name>: PASS|FAIL ..."): lost (the line "lost", the program kept in R.ai_lost), restored
-- (the line "cut" or "building" again and the program back), open_again (the line open within 10 minutes),
-- freight_again (its freight train routed again), crew_coal
-- (every construction train deployed with at least 2 x fuel_target coal).
local events = require("scripts.events")
local util = require("scripts.util")
local cities = require("scripts.cities")
local capture = require("scripts.capture")
local rails = require("scripts.rails")

local F, E = "rts-player", "rts-ai-1"
-- true: flip the far city while the line is still being built (a crew out, pieces missing) instead of at minute 22
local WHILE_BUILDING = false
-- true: the far depot dies while the city is lost (seed 703: it fell in the fight for the town)
local DESTROY_DEPOT = false

-- one diagnostic line: state, missing, builder, platform rails and stops, a path between the platforms
local function diag(R, line)
  local A, B = rails.depot(line.a), rails.depot(line.b)
  local function plat(d)
    if not (d and d.platform) then return "no platform" end
    local bad, stops = 0, 0
    for _, r in ipairs(d.platform.rails or {}) do if not r.valid then bad = bad + 1 end end
    for _, st in pairs(d.platform.stops or {}) do if st.valid and st.connected_rail then stops = stops + 1 end end
    return string.format("%d/%d rails bad, %d stops", bad, #(d.platform.rails or {}), stops)
  end
  local path = "-"
  if A and B and A.platform and B.platform then
    local goals = {}
    for _, st in pairs(B.platform.stops) do if st.valid and st.connected_rail then goals[#goals + 1] = {train_stop = st} end end
    local rail = A.platform.rails[math.floor(#A.platform.rails / 2)]
    if rail and rail.valid and #goals > 0 then
      local ok, res = pcall(game.train_manager.request_train_path, {starts = {{rail = rail, direction = defines.rail_direction.front},
        {rail = rail, direction = defines.rail_direction.back}}, goals = goals, type = "any-goal-accessible"})
      path = tostring(ok and res and res.found_path)
    end
  end
  local stale = 0
  for _, p in ipairs(line.pieces or {}) do if p.e and not p.e.valid then stale = stale + 1 end end
  return string.format("line #%d %s missing %d stale %d builder %s wait %s | A %s | B %s | path %s", line.id, line.state,
    line.missing or -1, stale, tostring(line.builder), tostring(line.wait), plat(A), plat(B), path)
end
local function S()
  storage.rretake = storage.rretake or {step = "wait", pass = 0, fail = 0}
  return storage.rretake
end
local function check(name, ok, fmt, ...)
  local s = S()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("rails retake check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

events.on_nth_tick(60, function(ev)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = S()
  local R = storage.rails
  local age = ev.tick - m.tick_started
  if s.step == "wait" then
    if age < (WHILE_BUILDING and 10 or 22) * 3600 then return end
    local A = R and R.ai and R.ai[F]
    local line = A and A.line and R.lines[A.line]
    local city = A and A.far and cities.of_center(A.far)
    if WHILE_BUILDING and line and not (line.state == "building" and (line.missing or 0) > 0 and line.builder) then
      line = nil
    end
    if not (line and city) then
      if age > 40 * 3600 then
        check("setup", false, "no program with a line and a far city by minute 40")
        s.step = "done"
        log("RTS_RAILS_RETAKE_DONE")
      end
      return
    end
    s.line, s.city, s.far, s.before = line.id, city.id, A.far, line.state
    util.log("rails retake: line #%d (%s) to city %d (#%d): flip to %s", line.id, line.state, city.id, A.far, E)
    capture.flip(city.id, E, "rails retake probe")
    s.t = ev.tick
    s.step = "lost"
  elseif s.step == "lost" then
    if ev.tick - s.t < 3600 then return end
    local line = R.lines[s.line]
    local kept = false
    for _, P in ipairs(R.ai_lost and R.ai_lost[F] or {}) do if P.far == s.far then kept = true end end
    check("lost", line and line.state == "lost" and kept, "line #%d %s -> %s, program kept %s", s.line, s.before,
      line and line.state or "-", tostring(kept))
    if DESTROY_DEPOT and line then
      local far = rails.depot(line.b)
      if far and far.entity.valid then
        util.log("rails retake: far depot #%d dies", line.b)
        far.entity.die()
      end
    end
    capture.flip(s.city, F, "rails retake probe")
    s.t = ev.tick
    s.step = "restored"
  elseif s.step == "restored" then
    if ev.tick - s.t < 600 then return end
    local line = R.lines[s.line]
    local A = R.ai and R.ai[F]
    local back = (A and A.far == s.far) and "main" or nil
    local prog = back and A or nil
    for _, P in ipairs(R.ai_more and R.ai_more[F] or {}) do if P.far == s.far then back, prog = "second", P end end
    if DESTROY_DEPOT then
      -- the program re-binds the line to a new depot or plans a new one: follow the program's line
      s.prog = prog
      check("restored", back ~= nil, "program %s (line #%s %s)", tostring(back), tostring(s.line), line and line.state or "-")
      s.t = ev.tick
      s.step = "open"
      return
    end
    check("restored", line and (line.state == "cut" or line.state == "building" or line.state == "open") and back ~= nil,
      "line #%d %s, program %s", s.line, line and line.state or "-", tostring(back))
    s.t = ev.tick
    s.step = "open"
  elseif s.step == "open" then
    if DESTROY_DEPOT and s.prog and s.prog.line then s.line = s.prog.line end
    local line = R.lines[s.line]
    if line and (ev.tick - s.t) % 1800 == 0 then util.log("rails retake: %s", diag(R, line)) end
    local routed
    for _, rec in pairs(R.trains) do
      if rec.kind == "cargo" and rec.force == F and rec.ai_line == s.line and rec.pickup and rec.dropoff then routed = rec end
    end
    if (line and line.state == "open" and routed) or ev.tick - s.t > (DESTROY_DEPOT and 20 or 10) * 3600 then
      check("open_again", line and line.state == "open", "line #%d %s %.1f min after the city came back", s.line,
        line and line.state or "-", (ev.tick - s.t) / 3600)
      check("freight_again", routed ~= nil, "freight train %s on line #%d: %s", routed and tostring(routed.id) or "-",
        s.line, routed and string.format("route #%s -> #%s, state %s", tostring(routed.pickup), tostring(routed.dropoff),
        tostring(routed.state)) or "none routed")
      check("crew_coal", (s.crews or 0) > 0 and (s.low or 0) == 0, "%d construction trains deployed, %d with less than "
        .. "40 coal", s.crews or 0, s.low or 0)
      util.log("rails retake summary %d/%d", s.pass, s.pass + s.fail)
      s.step = "done"
      log("RTS_RAILS_RETAKE_DONE")
    end
  end
end)

-- every construction train deployment (rails.create_train logs "deployed construction train N: C carriages, X coal")
local create = rails.create_train
rails.create_train = function(depot_un, kind)
  local train, why = create(depot_un, kind)
  if train and kind == "construction" then
    local s = S()
    local coal = 0
    for _, loco in ipairs(train.locomotives.front_movers) do coal = coal + loco.get_fuel_inventory().get_item_count("coal") end
    for _, loco in ipairs(train.locomotives.back_movers) do coal = coal + loco.get_fuel_inventory().get_item_count("coal") end
    s.crews = (s.crews or 0) + 1
    if coal < 40 then s.low = (s.low or 0) + 1 end
  end
  return train, why
end
