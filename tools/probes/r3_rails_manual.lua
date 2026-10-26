-- Test-only (tools/autotest-run.sh EXTRA_LUA): 0.1.2 #31 part A, player-built track (rails.plan_segment: the Rail
-- tool's planner; crews, junction signals, reuse by the auto survey, depots with two lines, own land). Beside a Nation
-- AI match (about 8 minutes of wall clock):
--   SEED=501 SPEED=6 EXTRA_LUA=tools/probes/r3_rails_manual.lua STOP_ON='r3 manual summary' \
--     tools/autotest-run.sh r3-manual '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1500
-- Scene on a lab-tile surface, force rts-ai-2 played "as a human" (storage.rails.test_human: its surveys reuse own
-- track, its depots take any number of lines): depots A (0, 0), B (600, 0), C (300, 400) and D (230, 220), every
-- platform east-west.
--   1. segment 1 from A's platform end rail to B's (rails.plan_segment as the Rail tool calls it); a crew from A builds
--   2. segment 2 branches from a rail of segment 1 near x = 300 and joins C's platform end rail: the junction gets chain
--      signals on all three tracks once its first piece stands
--   3. the auto lines A - C and A - B (rails.plan_line) run along that track: nearly every piece reused; A holds both
--   4. train 1 runs A (load exports) -> B (unload to Keep, load exports) -> C (unload everything, load exports) -> B
--      (unload to Keep); train 2 runs A (load) -> C (unload); both share the single track and the junction
--   5. on the match surface, a segment from rts-player land into rts-ai-1's capital land is refused
--   6. a Station placed 7 tiles from segment 1's track gets its two stops on the track, adds no supply cap, and a
--      train path leads from A's platform to it
--   7. segment 3, as the Rail tool plans a click on a rail of segment 1 near x = 150 and then a click on free ground
--      (railtool.starts_of / goals_of), branches off to a point 110 tiles south: planned, built by a crew that parks
--      behind the junction first, chain signals at its junction
--   8. the auto line A - D runs along own track as far as it helps, then leaves it: a crew from A reaches the point
--      where it leaves (past the junctions on the way) and lays the rest
-- Checks ("[rts] r3 manual check <name>: PASS|FAIL ..."): seg1_built, junction (chain signals around it), seg2_built,
-- seg3 (the free-point branch built, chain signals at its junction), reuse (the auto lines A - C and A - B reuse >= 90 %
-- of their pieces), partial (A - D open, part of it reused, part new), depot_lines (A holds all three lines), loops
-- (each train >= MIN_LOOPS loops in RUN_MINUTES, the stop order kept, no stand at a signal over STUCK_S), own_land,
-- station, track_waits (a segment on free ground far from every depot and network raises the "track not built" alert
-- after a minute). A crew without a path dumps its track ("r3 manual: diag: ..."). Summary "[rts] r3 manual summary <passed>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local logistics = require("scripts.logistics")
local buildings = require("scripts.buildings")
local rails = require("scripts.rails")
local railroutes = require("scripts.railroutes")
local railtool = require("scripts.railtool")

local F = "rts-ai-2"
local SURFACE = "r3-manual"
local START_TICK = 900
local RUN_MINUTES = 20
local MIN_LOOPS = 3
local STUCK_S = 180
local D = defines.direction
local RD = defines.rail_direction
local TS = defines.train_state

local function S()
  storage.r3_manual = storage.r3_manual or {pass = 0, fail = 0, stage = "setup", visits = {{}, {}}}
  return storage.r3_manual
end
local function log(fmt, ...) util.log("r3 manual: " .. fmt, ...) end
local function check(T, name, ok, fmt, ...)
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("r3 manual check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

local function finish(T)
  T.stage = "done"
  util.log("r3 manual summary %d/%d", T.pass, T.pass + T.fail)
end

local function surface()
  local s = game.surfaces[SURFACE]
  if s then return s end
  s = game.create_surface(SURFACE, {width = 0, height = 0, peaceful_mode = true, no_enemies_mode = true})
  s.generate_with_lab_tiles = true
  s.always_day = true
  for x = -96, 704, 32 do
    for y = -96, 480, 32 do s.request_to_generate_chunks({x + 16, y + 16}, 0) end
  end
  s.force_generate_chunk_requests()
  return s
end

local function depot(s, pos)
  storage.rails.reuse_site = {force = F, x = pos.x, y = pos.y, spec = {axis = "x", side = 1,
    track = 2 * math.floor((pos.y + rails.PLATFORM_GAP) / 2) + 1}}
  local e = s.create_entity({name = rails.DEPOT, position = pos, force = F, raise_built = true})
  storage.rails.reuse_site = nil
  for i = 1, 4 do
    local sp = s.find_non_colliding_position("rts-stockpile", {pos.x - 10 + i * 4, pos.y - 6}, 8, 1, true)
    local st = sp and s.create_entity({name = "rts-stockpile", position = sp, force = F, raise_built = true})
    if st then buildings.register(st) end
  end
  return e and e.unit_number
end

local function fill(un, items)
  local net = logistics.hub_network(un)
  for _, it in ipairs(items) do if net then net.insert({name = it[1], count = it[2]}) end end
end

-- the rail end states of a rail: as starts (pointing out) and as goals (arriving into it)
local function ends_of(rail, as_goal)
  local out = {}
  for _, rd in ipairs({RD.front, RD.back}) do
    local loc = rail.get_rail_end(rd).location
    out[#out + 1] = {x = loc.position.x, y = loc.position.y, d = as_goal and (loc.direction + 8) % 16 or loc.direction,
                     l = loc.rail_layer}
  end
  return out
end

local function platform_rail(un, which)
  local pr = rails.depot(un).platform.rails
  return which == 1 and pr[1] or pr[#pr]
end

local function setup(T)
  local R = storage.rails
  R.test_forces = R.test_forces or {}
  R.test_forces[F] = true
  R.test_human = R.test_human or {}
  R.test_human[F] = true
  if not game.forces[F] then game.create_force(F) end
  local s = surface()
  T.A = depot(s, {x = 0, y = 0})
  T.B = depot(s, {x = 600, y = 0})
  T.C = depot(s, {x = 300, y = 400})
  T.D = depot(s, {x = 230, y = 220})
  T.stage, T.at = "stock", game.tick + 120
end

local function stock(T)
  fill(T.A, {{rails.LOCO_KIT, 8}, {rails.CWAGON_KIT, 2}, {rails.WAGON_KIT, 4}, {"coal", 600}, {rails.RAIL, 2400},
             {"iron-plate", 8000}})
  fill(T.B, {{"coal", 300}, {"copper-plate", 8000}})
  fill(T.C, {{"coal", 300}, {"stone", 4000}})
  fill(T.D, {{"coal", 100}})
  logistics.set_policy(T.A, "export_above", "iron-plate", 0)
  logistics.set_policy(T.B, "keep", "iron-plate", 2000)
  logistics.set_policy(T.B, "keep", "stone", 1000)
  logistics.set_policy(T.B, "export_above", "copper-plate", 0)
  logistics.set_policy(T.C, "export_above", "stone", 0)
  local a_end, b_end = platform_rail(T.A, 2), platform_rail(T.B, 1)
  local id, why = rails.plan_segment(F, {starts = ends_of(a_end), goals = ends_of(b_end, true),
    surface = surface().index, start_rail = a_end, end_rail = b_end, own_land = true})
  T.seg1 = id
  log("segment 1: line %s (%s)", tostring(id), tostring(why))
  T.stage, T.t0 = "seg1", game.tick
end

local function seg1(T)
  local line = rails.lines[T.seg1]
  if not line then
    check(T, "seg1_built", false, "segment 1 gone")
    finish(T)
    return
  end
  if line.state ~= "open" then
    if game.tick - T.t0 > 10 * 3600 then
      check(T, "seg1_built", false, "state %s after 10 min, %d missing, wait %s", line.state, line.missing or -1,
        tostring(line.wait))
      finish(T)
    end
    return
  end
  check(T, "seg1_built", true, "%d pieces (%d reused), bill %d rails, built in %.0f s (%d by robots), %d signals",
    #line.pieces, line.reused or 0, line.bill.rails, (game.tick - T.t0) / 60, line.robot or 0, #(line.signals or {}))
  -- a Station next to the track
  local se = surface().create_entity({name = rails.STATION, position = {450, 0}, force = F, raise_built = true})
  local sd = se and rails.depot(se.unit_number)
  local stops = sd and sd.platform and #sd.platform.stops or 0
  local supply = package.loaded["__" .. script.mod_name .. "__/scripts/supply.lua"] or package.loaded["scripts.supply"]
  local discount = supply and supply.hub_discount and supply.hub_discount(F) or -1
  local reach = false
  local goals = {}
  for _, st in pairs(sd and sd.platform and sd.platform.stops or {}) do
    if st.valid and st.connected_rail then goals[#goals + 1] = {train_stop = st} end
  end
  local pr = rails.depot(T.A).platform.rails[10]
  if #goals > 0 and pr then
    local ok, res = pcall(game.train_manager.request_train_path, {starts = {{rail = pr, direction = RD.front},
      {rail = pr, direction = RD.back}}, goals = goals, type = "any-goal-accessible"})
    reach = ok and res and res.found_path or false
    if not ok then log("station path request: %s", tostring(res)) end
  end
  check(T, "station", stops == 2 and discount == 1 and reach == true, "station %s: %d stops, supply discount %d, path from "
    .. "A %s", tostring(se and se.unit_number), stops, discount, tostring(reach))
  -- segment 2: from a rail of segment 1 near x = 300 to C's west platform end
  local s = surface()
  local mid
  for _, p in ipairs(line.pieces) do
    if p.e and p.e.valid and p.name == "straight-rail" and math.abs(p.x - 301) <= 4 then mid = p.e end
  end
  local c_end = platform_rail(T.C, 1)
  local id, why = rails.plan_segment(F, {starts = ends_of(mid), goals = ends_of(c_end, true), surface = s.index,
    start_rail = mid, end_rail = c_end, own_land = true})
  T.seg2, T.jpos = id, mid and {x = mid.position.x, y = mid.position.y}
  log("segment 2 from the rail at %s: line %s (%s)", mid and util.pos_str(mid.position) or "-", tostring(id),
    tostring(why))
  T.stage, T.t1 = "seg2", game.tick
end

local function seg2(T)
  local line = rails.lines[T.seg2]
  if not line then
    check(T, "seg2_built", false, "segment 2 gone")
    finish(T)
    return
  end
  if line.state ~= "open" then
    if game.tick - T.t1 > 10 * 3600 then
      check(T, "seg2_built", false, "state %s after 10 min, %d missing, wait %s", line.state, line.missing or -1,
        tostring(line.wait))
      finish(T)
    end
    return
  end
  local s = surface()
  -- (the junction: where the segment leaves segment 1; it may run along segment 1 for a few pieces first)
  for _, p in ipairs(line.pieces) do
    if p.jpos then
      T.jpos = p.jpos
      break
    end
  end
  log("segment 2 leaves segment 1 at %s", util.pos_str(T.jpos))
  local chains = s.count_entities_filtered({position = T.jpos, radius = 24, name = "rail-chain-signal", force = F})
  local plain = s.count_entities_filtered({position = T.jpos, radius = 24, name = "rail-signal", force = F})
  check(T, "seg2_built", true, "%d pieces (%d reused), bill %d rails, built in %.0f s", #line.pieces, line.reused or 0,
    line.bill.rails, (game.tick - T.t1) / 60)
  check(T, "junction", chains >= 4 and plain == 0, "%d chain signals and %d rail signals within 24 tiles of the junction",
    chains, plain)
  -- segment 3: the Rail tool's states for a click on a rail of segment 1 near x = 150, then on free ground
  local l1 = rails.lines[T.seg1]
  local r150
  for _, p in ipairs(l1.pieces) do
    if p.e and p.e.valid and p.name == "straight-rail" and math.abs(p.x - 151) <= 2 then r150 = p.e end
  end
  local id3, why3
  if r150 then
    local goal = {x = r150.position.x + 30, y = r150.position.y + 110}
    id3, why3 = rails.plan_segment(F, {starts = railtool.starts_of({kind = "rail", rail = r150}),
      goals = railtool.goals_of(nil, goal), surface = s.index, start_rail = r150, own_land = true})
    T.j3 = {x = r150.position.x, y = r150.position.y}
  end
  T.seg3 = id3
  log("segment 3 from the rail at %s to free ground: line %s (%s)", r150 and util.pos_str(r150.position) or "-",
    tostring(id3), tostring(why3))
  T.stage, T.t15 = "seg3", game.tick
end

local function seg3(T)
  local line = T.seg3 and rails.lines[T.seg3]
  if not line or line.state == "failed" then
    check(T, "seg3", false, "segment 3 %s (%s)", line and line.state or "gone", line and tostring(line.reason) or "-")
    finish(T)
    return
  end
  if line.state ~= "open" then
    if game.tick - T.t15 > 10 * 3600 then
      check(T, "seg3", false, "state %s after 10 min, %d missing, wait %s", line.state, line.missing or -1,
        tostring(line.wait))
      finish(T)
    end
    return
  end
  local chains = surface().count_entities_filtered({position = T.j3, radius = 24, name = "rail-chain-signal", force = F})
  check(T, "seg3", chains >= 4, "free-point branch: %d pieces, bill %d rails, built in %.0f s, %d chain signals at its "
    .. "junction", #line.pieces, line.bill.rails, (game.tick - T.t15) / 60, chains)
  -- the auto lines A - C and A - B along the player track
  T.lac = rails.plan_line(F, T.A, T.C)
  T.lab = rails.plan_line(F, T.A, T.B)
  T.lad = rails.plan_line(F, T.A, T.D)
  log("auto lines A-C %s, A-B %s, A-D %s", tostring(T.lac), tostring(T.lab), tostring(T.lad))
  T.stage, T.t2 = "auto", game.tick
end

local function auto(T)
  local l1, l2, l3 = rails.lines[T.lac], rails.lines[T.lab], rails.lines[T.lad]
  if not (l1 and l2 and l3) then
    check(T, "reuse", false, "lines %s %s %s", tostring(T.lac), tostring(T.lab), tostring(T.lad))
    finish(T)
    return
  end
  if l1.state == "surveying" or l2.state == "surveying" or l3.state == "surveying" then return end
  if not (l1.state == "open" and l2.state == "open" and l3.state == "open") and game.tick - T.t2 < 10 * 3600 then
    return
  end
  local function share(l) return l.pieces and #l.pieces > 0 and (l.reused or 0) / #l.pieces or 0 end
  check(T, "reuse", share(l1) >= 0.9 and share(l2) >= 0.9 and l1.state == "open" and l2.state == "open",
    "A-C: %s, %d pieces, %d reused (%.0f %%), bill %d rails; A-B: %s, %d pieces, %d reused (%.0f %%), bill %d rails",
    l1.state, #(l1.pieces or {}), l1.reused or 0, 100 * share(l1), l1.bill and l1.bill.rails or -1, l2.state,
    #(l2.pieces or {}), l2.reused or 0, 100 * share(l2), l2.bill and l2.bill.rails or -1)
  check(T, "partial", l3.state == "open" and share(l3) > 0.3 and share(l3) < 1,
    "A-D: %s after %.0f s, %d pieces, %d reused (%.0f %%), bill %d rails, built by crews %d", l3.state,
    (game.tick - T.t2) / 60, #(l3.pieces or {}), l3.reused or 0, 100 * share(l3), l3.bill and l3.bill.rails or -1,
    l3.used or 0)
  local dA = rails.depot(T.A)
  local n = (dA.line and 1 or 0)
  for _ in pairs(dA.lines or {}) do n = n + 1 end
  check(T, "depot_lines", n == 3, "depot A: line #%s and %d more", tostring(dA.line), n - (dA.line and 1 or 0))
  T.stage, T.t25 = "train1", game.tick
end

local function train1(T)
  local t1, w1 = rails.create_train(T.A, "cargo")
  if not t1 then
    if game.tick - T.t25 > 5 * 3600 then
      check(T, "loops", false, "first train not deployed: %s", tostring(w1))
      finish(T)
    end
    return
  end
  local ok1 = railroutes.set(t1, {
    {target = T.A, load = "exports", wait = {type = "inactivity", seconds = 5}},
    {target = T.B, unload = "keep", load = "exports", wait = {type = "inactivity", seconds = 5}},
    {target = T.C, unload = "all", load = "exports", wait = {type = "inactivity", seconds = 5}},
    {target = T.B, unload = "keep", wait = {type = "inactivity", seconds = 5}},
  })
  T.r1 = rails.train_record(t1)
  T.stage, T.t3 = "train2", game.tick + 60 * 30 -- the second train once the first one left A's platform
  log("train 1 %s set %s", tostring(t1.id), tostring(ok1))
end

local function train2(T)
  if game.tick < T.t3 then return end
  local t2, w2 = rails.create_train(T.A, "cargo")
  if not t2 then
    if game.tick - T.t3 > 5 * 3600 then
      check(T, "loops", false, "second train not deployed: %s", tostring(w2))
      finish(T)
    end
    return
  end
  railroutes.set(t2, {{target = T.A, load = "exports", wait = {type = "inactivity", seconds = 5}},
                      {target = T.C, unload = "all", wait = {type = "inactivity", seconds = 5}}})
  T.r2 = rails.train_record(t2)
  log("train 2 %d deployed and routed A -> C", t2.id)
  T.stage, T.t4 = "run", game.tick
end

local function own_land(T)
  local ms = game.surfaces[storage.match and storage.match.surface or ""]
  local nat = storage.nations and storage.nations["rts-ai-1"]
  local cities = package.loaded["__" .. script.mod_name .. "__/scripts/cities.lua"] or package.loaded["scripts.cities"]
  local city = nat and cities and cities.get and cities.get(nat.capital)
  local c = city and city.center and buildings.get(city.center)
  if not (ms and c) then
    check(T, "own_land", false, "no AI capital on the match surface")
    return
  end
  local p = c.entity.position
  local a = {x = 2 * math.floor((p.x + 30) / 2), y = 2 * math.floor((p.y + 30) / 2)}
  local b = {x = a.x + 30, y = a.y}
  local starts, goals = {}, {}
  for d = 0, 14, 2 do starts[#starts + 1] = {x = a.x, y = a.y, d = d, l = 0} end
  for d = 0, 15 do goals[#goals + 1] = {x = b.x, y = b.y, d = d, l = 0} end
  local R = storage.rails
  R.test_human["rts-player"] = true
  T.foreign = rails.plan_segment("rts-player", {starts = starts, goals = goals, surface = ms.index, own_land = true})
  log("segment on rts-ai-1's land near %s: line %s", util.pos_str(a), tostring(T.foreign))
  -- a segment out of every reach (no track to it, no network over it): an alert after a minute
  T.wild = rails.plan_segment(F, {starts = railtool.starts_of({kind = "point", x = 0, y = 300}),
    goals = railtool.goals_of(nil, {x = 60, y = 300}), surface = surface().index, own_land = true})
  T.t_wild = game.tick
  log("segment out of reach at (0, 300): line %s", tostring(T.wild))
end

-- Once per line: a crew of F without a path to its target gets its track dumped (where the path along the line breaks,
-- the signals around the line's junctions).
local function path_ok(a, b)
  if not (a and a.valid and b and b.valid) then return "-" end
  local ok, res = pcall(game.train_manager.request_train_path, {starts = {{rail = a, direction = RD.front},
    {rail = a, direction = RD.back}}, goals = {{rail = b, direction = RD.front}, {rail = b, direction = RD.back}},
    type = "any-goal-accessible"})
  return ok and res and res.found_path and "y" or "n"
end

local function diag(T)
  T.diag = T.diag or {}
  for _, rec in pairs(storage.rails.trains or {}) do
    local train = rec.kind == "construction" and rec.force == F and rails.train_of(rec)
    if train and train.state == TS.no_path and rec.line and not T.diag[rec.line] then
      T.diag[rec.line] = true
      local line = rails.lines[rec.line]
      local i = rec.scan or 0
      log("diag: crew %d of line %d without a path at %s, frontier %d, target %s", train.id, rec.line,
        util.pos_str(train.front_stock.position), i, tostring(rec.target))
      local pr = rails.depot(T.A).platform.rails[10]
      for j = math.max(1, i - 14), math.min(#line.pieces, i + 1) do
        local p = line.pieces[j]
        local prev = line.pieces[j - 1]
        log("diag: piece %d %s at %s d %d %s%s; from the previous %s, from A %s%s%s", j, p.name, util.pos_str({p.x, p.y}),
          p.d, p.reused and "reused" or "new", (p.e and p.e.valid) and "" or " (missing)",
          path_ok(prev and prev.e, p.e), path_ok(pr, p.e), p.jpos and (" jpos " .. util.pos_str(p.jpos)) or "",
          p.jpos2 and (" jpos2 " .. util.pos_str(p.jpos2)) or "")
        for _, jp in ipairs({p.jpos or false, p.jpos2 or false}) do
          if jp then
            for _, sg in ipairs(surface().find_entities_filtered({position = jp, radius = 12,
                                                                  type = {"rail-signal", "rail-chain-signal"}})) do
              log("diag:   signal %s at %s dir %d", sg.name, util.pos_str(sg.position), sg.direction)
            end
            for _, r in ipairs(surface().find_entities_filtered({position = jp, radius = 6,
                                                                 type = {"straight-rail", "curved-rail-a",
                                                                         "curved-rail-b", "half-diagonal-rail"}})) do
              log("diag:   rail %s at %s dir %d", r.name, util.pos_str(r.position), r.direction)
            end
          end
        end
      end
    end
  end
end

local function run(T)
  for k, rec in ipairs({T.r1, T.r2}) do
    local train = rec and rails.train_of(rec)
    if train then
      local st = train.state
      if st == TS.wait_signal or st == TS.no_path or st == TS.path_lost then
        T["stuck" .. k] = T["stuck" .. k] or game.tick
        T.max_stuck = math.max(T.max_stuck or 0, (game.tick - T["stuck" .. k]) / 60)
      else
        T["stuck" .. k] = nil
      end
    end
  end
  local fl = T.foreign and rails.lines[T.foreign]
  if T.foreign and not T.land_done and (not fl or fl.state ~= "surveying") then
    T.land_done = true
    check(T, "own_land", fl ~= nil and fl.state == "failed" and string.sub(tostring(fl.reason), 1, 5) == "land-",
      "segment on another nation's land: %s (%s)", fl and fl.state or "gone", fl and tostring(fl.reason) or "-")
  end
  local wl = T.wild and rails.lines[T.wild]
  if T.wild and not T.wild_done and (game.tick - T.t_wild > 150 * 60 or (wl and wl.alerted)) then
    T.wild_done = true
    local seen = false
    for _, a in ipairs(storage.alerts or {}) do
      if a.kind == "track-waits" and a.force == F then seen = true end
    end
    check(T, "track_waits", wl ~= nil and wl.state == "building" and wl.alerted == "no-access" and seen,
      "segment out of reach after %.0f s: %s, wait %s, alerted %s, alert in the list %s", (game.tick - T.t_wild) / 60,
      wl and wl.state or "gone", wl and tostring(wl.wait) or "-", wl and tostring(wl.alerted) or "-", tostring(seen))
  end
  if (game.tick - T.t4) % 3600 == 0 then
    log("minute %d: train 1 visits %d, train 2 visits %d, longest stand %.0f s", (game.tick - T.t4) / 3600,
      #T.visits[1], #T.visits[2], T.max_stuck or 0)
  end
  if game.tick - T.t4 < RUN_MINUTES * 3600 then return end
  local loops, order = {0, 0}, true
  for i, v in ipairs(T.visits[1]) do
    if i > 1 and v ~= (T.visits[1][i - 1] % 4) + 1 then order = false end
    if v == 4 then loops[1] = loops[1] + 1 end
  end
  for _, v in ipairs(T.visits[2]) do if v == 2 then loops[2] = loops[2] + 1 end end
  check(T, "loops", order and loops[1] >= MIN_LOOPS and loops[2] >= MIN_LOOPS and (T.max_stuck or 0) < STUCK_S,
    "train 1 %d loops (order %s), train 2 %d loops; longest stand at a signal %.0f s; train 1 delivered %s",
    loops[1], tostring(order), loops[2], T.max_stuck or 0, T.r1 and serpent.line(T.r1.delivered) or "-")
  finish(T)
end

events.on(defines.events.on_train_changed_state, function(e)
  local T = storage.r3_manual
  if not (T and T.r1) or e.train.state ~= TS.wait_station then return end
  local rec = rails.train_record(e.train)
  local d = rec and rec.dwell
  if not d then return end
  if rec == T.r1 then T.visits[1][#T.visits[1] + 1] = d.stop end
  if rec == T.r2 then T.visits[2][#T.visits[2] + 1] = d.stop end
end)

events.on_nth_tick(60, function(e)
  local T = S()
  if T.stage == "done" or e.tick < START_TICK or not storage.rails then return end
  if T.A then diag(T) end
  if T.stage == "setup" then setup(T)
  elseif T.stage == "stock" then if e.tick >= T.at then stock(T) end
  elseif T.stage == "seg1" then seg1(T)
  elseif T.stage == "seg2" then seg2(T)
  elseif T.stage == "seg3" then seg3(T)
  elseif T.stage == "auto" then auto(T)
  elseif T.stage == "train1" then train1(T)
  elseif T.stage == "train2" then
    train2(T)
    if T.stage == "run" then own_land(T) end
  elseif T.stage == "run" then run(T) end
end)
