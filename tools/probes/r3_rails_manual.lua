-- Test-only (tools/autotest-run.sh EXTRA_LUA): player-built track. 0.1.2 #31 part A laid it with the Rail tool; 0.1.3
-- #37 lays it with the vanilla rail planner, whose ghosts rails.adopt_ghosts turns into planner track (crews, robots,
-- junction signals, the "track not built" alert). A headless run has no pointer to drive the planner, so
-- rails.plan_segment only draws each piece of track (its survey lays the curved and diagonal ghosts the planner would)
-- and the moment its ghosts stand they are handed over as a player's planner ghosts (rails.segments_to_planner: the
-- same rails.adopt_ghosts path; tools/probes/r4_rails_planner_gui.lua drives the real planner). Then: crews, junction
-- signals, reuse by the auto survey, depots with several lines, own land, a cancelled ghost. Beside a Nation AI match
-- (about 8 minutes of wall clock):
--   SEED=501 SPEED=6 EXTRA_LUA=tools/probes/r3_rails_manual.lua STOP_ON='r3 manual summary' \
--     tools/autotest-run.sh r3-manual '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 1500
-- Scene on a lab-tile surface, force rts-ai-2 played "as a human" (storage.rails.test_human: its surveys reuse own
-- track, its depots take any number of lines): depots A (0, 0), B (600, 0), C (300, 400) and D (230, 220), every
-- platform east-west.
--   1. track 1 from A's platform end rail to B's; a crew from A builds it
--   2. track 2 branches from a rail of track 1 near x = 300 and joins C's platform end rail: the junction gets chain
--      signals on all three tracks once its first piece stands
--   3. the auto lines A - C and A - B (rails.plan_line) run along that track: nearly every piece reused; A holds both
--   4. train 1 runs A (load exports) -> B (unload to Keep, load exports) -> C (unload everything, load exports) -> B
--      (unload to Keep); train 2 runs A (load) -> C (unload); both share the single track and the junction
--   5. on the match surface, a player's rail ghost on rts-ai-1's capital land is refused (territory's build check)
--   6. a Station placed 7 tiles from track 1 gets its two stops on the track, adds no supply cap, and a train path
--      leads from A's platform to it
--   7. track 3 from a rail of track 1 near x = 150 to free ground 110 tiles south: built by a crew that parks behind
--      the junction first, chain signals at its junction
--   8. the auto line A - D runs along own track as far as it helps, then leaves it: a crew from A reaches the point
--      where it leaves (past the junctions on the way) and lays the rest
--   9. track 4 on free ground far from everything: the "track not built" alert after a minute; then one of its ghosts
--      in the middle is cancelled: its planner line is dissolved, the other ghosts become two lines, nothing comes back
-- Checks ("[rts] r3 manual check <name>: PASS|FAIL ..."): seg1_built, junction (chain signals around it), seg2_built,
-- seg3 (the free-point branch built, chain signals at its junction), reuse (the auto lines A - C and A - B reuse >= 90 %
-- of their pieces), partial (A - D open, part of it reused, part new), depot_lines (A holds all three lines), loops
-- (each train >= MIN_LOOPS loops in RUN_MINUTES, the stop order kept, no stand at a signal over STUCK_S), own_land,
-- station, track_waits (the alert of track 4), cancel (track 4 after the cancelled ghost), warnings (#33: a stop no
-- track leads to, two trains between the same stops), platform_held (train 2 kept
-- on C's platform: train 1, bound for C, shows the single-track hint after a minute at a signal), and 0.1.4 (#41):
-- short_signals (ten short pieces of track laid one after another from B's free platform end, each handed over on its
-- own as a player's planner segment: built by a crew, 0 signals on them), spur (a branch off the eighth: a real
-- junction, one chain-signal pair per branch), remove_junction (the spur's first rail removed through
-- rails.remove_track: the junction's signals go with it), remove_track (the rails of segments 4 to 6 removed: rails
-- refunded, their lines gone, segments 3 and 7 still lines, nothing comes back; a platform rail is refused), crews_home
-- (a crew cut off by the removal is recalled after 30 s). A crew without a path dumps its track ("r3 manual: diag: ..."). Summary "[rts] r3 manual summary <passed>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local logistics = require("scripts.logistics")
local buildings = require("scripts.buildings")
local rails = require("scripts.rails")
local railroutes = require("scripts.railroutes")
local territory = require("scripts.territory")

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

-- 0.1.3: the start states of a rail (the Rail tool's "click on a rail") and goal states around a free point
local function starts_of_rail(rail)
  local out = {}
  for _, rd in ipairs({RD.front, RD.back}) do
    local loc = rail.get_rail_end(rd).location
    if loc.rail_layer == 0 then out[#out + 1] = {x = loc.position.x, y = loc.position.y, d = loc.direction, l = 0} end
  end
  return out
end
local function starts_of_point(x, y)
  local out = {}
  for dx = 0, 1 do
    for dy = 0, 1 do
      for d = 0, 14, 2 do out[#out + 1] = {x = x + dx, y = y + dy, d = d, l = 0} end
    end
  end
  return out
end
local function goals_of_point(pos)
  local out = {}
  local x, y = 2 * math.floor(pos.x / 2 + 0.5), 2 * math.floor(pos.y / 2 + 0.5)
  for dx = -2, 2 do
    for dy = -2, 2 do
      for d = 0, 15 do out[#out + 1] = {x = x + dx, y = y + dy, d = d, l = 0} end
    end
  end
  return out
end

-- 0.1.3 (#37): draw a piece of track with the survey; handed() hands its ghosts over as planner ghosts once they stand
local function lay(T, key, opts)
  opts.surface = opts.surface or surface().index
  local id, why = rails.plan_segment(opts.force or F, opts)
  T.plan = T.plan or {}
  T.plan[key] = {seg = id, why = why}
  log("%s: drawn as survey #%s (%s)", key, tostring(id), tostring(why))
  return id, why
end

-- The planner track of `key`: {pieces = {{name, x, y, d}}, lines = {ids}} once handed over, nil while the survey runs,
-- false when it failed.
local function handed(T, key)
  local P = T.plan and T.plan[key]
  if not P then return false end
  if P.pieces then return P end
  local line = P.seg and rails.lines[P.seg]
  if not line or line.state == "failed" then return false end
  if line.state == "surveying" then return nil end
  local first = storage.rails.next_id
  P.pieces = {}
  for _, p in ipairs(line.pieces or {}) do
    -- (where the ghost stands: a survey from a free point may plan off the rail grid, and the ghost snaps onto it)
    local g = p.g and p.g.valid and p.g
    if g then
      P.pieces[#P.pieces + 1] = {name = g.ghost_name, x = g.position.x, y = g.position.y, d = g.direction}
    elseif not p.reused then
      P.pieces[#P.pieces + 1] = {name = p.name, x = p.x, y = p.y, d = p.d}
    end
  end
  local n, made, ghosts = rails.segments_to_planner(P.seg)
  P.lines = {}
  for id = first, storage.rails.next_id - 1 do
    if rails.lines[id] and rails.lines[id].planner then P.lines[#P.lines + 1] = id end
  end
  P.t0 = game.tick
  log("%s: %d new pieces, %d ghosts handed over as planner ghosts: %d planner lines (%s)", key, #P.pieces, ghosts, made,
    table.concat(P.lines, ", "))
  return P
end

-- built pieces of a planner track, rails standing on its pieces' places
local function built_of(P)
  local s, n = surface(), 0
  for _, q in ipairs(P.pieces) do
    local e = s.find_entity(q.name, {q.x, q.y})
    if e and e.valid and e.direction == q.d and e.force.name == F then n = n + 1 end
  end
  return n
end

-- the built straight rail of a planner track nearest to x = `x` (within `tol`)
local function rail_near_x(P, x, tol)
  local s = surface()
  for _, q in ipairs(P.pieces) do
    if q.name == "straight-rail" and math.abs(q.x - x) <= tol then
      local e = s.find_entity(q.name, {q.x, q.y})
      if e and e.valid then return e end
    end
  end
  return nil
end

-- wait for a planner track to stand: true when built, false on a timeout or a failed survey (checked as `name`)
local function track_done(T, key, name, t0)
  local P = handed(T, key)
  if P == nil then return nil end
  if P == false then
    check(T, name, false, "%s: survey failed or gone", key)
    finish(T)
    return false
  end
  local built = built_of(P)
  if built >= #P.pieces then return P end
  if game.tick - t0 > 10 * 3600 then
    local waits = {}
    for _, id in ipairs(P.lines) do
      local l = rails.lines[id]
      if l then waits[#waits + 1] = string.format("#%d %s %s", id, l.state, tostring(l.wait)) end
    end
    check(T, name, false, "%s: %d of %d pieces built after 10 min; lines %s", key, built, #P.pieces,
      table.concat(waits, ", "))
    finish(T)
    return false
  end
  return nil
end

local function crews_of(P)
  local robot, crew = 0, 0
  for _, id in ipairs(P.lines) do
    local l = rails.lines[id]
    if l then
      robot = robot + (l.robot or 0)
      crew = crew + (l.used or 0) - (l.robot or 0)
    end
  end
  return robot, crew
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
  lay(T, "track1", {starts = ends_of(a_end), goals = ends_of(b_end, true), start_rail = a_end, end_rail = b_end,
    own_land = true})
  T.stage, T.t0 = "seg1", game.tick
end

local function seg1(T)
  local P = track_done(T, "track1", "seg1_built", T.t0)
  if not P then return end
  local robot, crew = crews_of(P)
  check(T, "seg1_built", true, "%d pieces in %d planner lines, built in %.0f s (%d rails by robots, %d by crews)",
    #P.pieces, #P.lines, (game.tick - T.t0) / 60, robot, crew)
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
  -- track 2: from a rail of track 1 near x = 300 to C's west platform end
  local mid = rail_near_x(P, 301, 4)
  local c_end = platform_rail(T.C, 1)
  lay(T, "track2", {starts = ends_of(mid), goals = ends_of(c_end, true), start_rail = mid, end_rail = c_end,
    own_land = true})
  T.jpos = mid and {x = mid.position.x, y = mid.position.y}
  log("track 2 from the rail at %s", mid and util.pos_str(mid.position) or "-")
  T.stage, T.t1 = "seg2", game.tick
end

local function seg2(T)
  local P = track_done(T, "track2", "seg2_built", T.t1)
  if not P then return end
  local s = surface()
  -- (the junction: where track 2 leaves track 1, the end of track 2's first new piece next to track 1)
  for _, id in ipairs(P.lines) do
    local l = rails.lines[id]
    for _, p in ipairs(l and l.pieces or {}) do
      if p.jpos and not T.jfound then T.jpos, T.jfound = p.jpos, true end
    end
  end
  log("track 2 leaves track 1 at %s", util.pos_str(T.jpos))
  local chains = s.count_entities_filtered({position = T.jpos, radius = 24, name = "rail-chain-signal", force = F})
  local plain = s.count_entities_filtered({position = T.jpos, radius = 24, name = "rail-signal", force = F})
  local robot, crew = crews_of(P)
  check(T, "seg2_built", true, "%d pieces in %d planner lines, built in %.0f s (%d rails by robots, %d by crews)",
    #P.pieces, #P.lines, (game.tick - T.t1) / 60, robot, crew)
  check(T, "junction", chains >= 4 and plain == 0, "%d chain signals and %d rail signals within 24 tiles of the junction",
    chains, plain)
  -- track 3: from a rail of track 1 near x = 150 to free ground
  local r150 = rail_near_x(T.plan.track1, 151, 2)
  if r150 then
    local goal = {x = r150.position.x + 30, y = r150.position.y + 110}
    lay(T, "track3", {starts = starts_of_rail(r150), goals = goals_of_point(goal), start_rail = r150, own_land = true})
    T.j3 = {x = r150.position.x, y = r150.position.y}
  end
  log("track 3 from the rail at %s to free ground", r150 and util.pos_str(r150.position) or "-")
  T.stage, T.t15 = "seg3", game.tick
end

local function seg3(T)
  local P = track_done(T, "track3", "seg3", T.t15)
  if not P then return end
  -- (0.1.4: the junction is where track 3 leaves track 1, its first piece's mark; the survey may run along track 1 first)
  for _, id in ipairs(P.lines) do
    local l = rails.lines[id]
    for _, p in ipairs(l and l.pieces or {}) do
      if p.jpos and not T.j3found then T.j3, T.j3found = p.jpos, true end
    end
  end
  local chains = surface().count_entities_filtered({position = T.j3, radius = 24, name = "rail-chain-signal", force = F})
  check(T, "seg3", chains >= 4, "free-point branch: %d pieces in %d planner lines, built in %.0f s, %d chain signals at "
    .. "its junction %s", #P.pieces, #P.lines, (game.tick - T.t15) / 60, chains, util.pos_str(T.j3))
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
  else
    -- a planner ghost of rts-player on rts-ai-1's capital land: territory's build check (on_built_entity) refuses it
    local p = c.entity.position
    local at = {x = 2 * math.floor((p.x + 12) / 2) + 1, y = 2 * math.floor((p.y + 12) / 2) + 1}
    local g = ms.create_entity({name = "entity-ghost", inner_name = "straight-rail", position = at,
                                direction = D.east, force = "rts-player"})
    local ok = g and territory.build_check(g, {name = defines.events.on_built_entity, player_index = 0})
    check(T, "own_land", g ~= nil and ok == false and not g.valid,
      "a rail ghost of rts-player on rts-ai-1's capital land at %s: placed %s, build check %s, ghost left %s",
      util.pos_str(at), tostring(g ~= nil), tostring(ok), tostring(g ~= nil and g.valid))
  end
  -- track 4, out of every reach (no track to it, no network over it): an alert after a minute
  lay(T, "wild", {starts = starts_of_point(0, 300), goals = goals_of_point({x = 60, y = 300}), own_land = true})
  T.t_wild = game.tick
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
    if train and train.state == TS.no_path and rec.line and rails.lines[rec.line] and not T.diag[rec.line] then
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
  local W = T.t_wild and handed(T, "wild")
  local wl = W and W.lines and rails.lines[W.lines[1]]
  if W and not T.wild_done and (game.tick - T.t_wild > 150 * 60 or (wl and wl.alerted)) then
    T.wild_done = true
    local seen = false
    for _, a in ipairs(storage.alerts or {}) do
      if a.kind == "track-waits" and a.force == F then seen = true end
    end
    check(T, "track_waits", wl ~= nil and wl.state == "building" and wl.alerted == "no-access" and seen,
      "track out of reach after %.0f s: %d planner lines, %s, wait %s, alerted %s, alert in the list %s",
      (game.tick - T.t_wild) / 60, #W.lines, wl and wl.state or "gone", wl and tostring(wl.wait) or "-",
      wl and tostring(wl.alerted) or "-", tostring(seen))
    -- cancel one ghost in the middle of track 4 (as #27's selection or the vanilla undo would)
    local q = W.pieces[math.floor(#W.pieces / 2)]
    local s = surface()
    for _, g in ipairs(s.find_entities_filtered({position = {q.x, q.y}, radius = 0.5, name = "entity-ghost"})) do
      if g.ghost_name == q.name and g.direction == q.d then
        g.destroy()
        T.cancelled = {name = q.name, x = q.x, y = q.y, d = q.d, at = game.tick}
      end
    end
    log("track 4: ghost %s at %s cancelled", q.name, util.pos_str({q.x, q.y}))
  end
  if T.cancelled and not T.cancel_done and game.tick - T.cancelled.at > 10 * 60 then
    T.cancel_done = true
    local s, ghosts, lines, holder = surface(), 0, {}, false
    for _, q in ipairs(W.pieces) do
      for _, g in ipairs(s.find_entities_filtered({position = {q.x, q.y}, radius = 0.5, name = "entity-ghost"})) do
        if g.ghost_name == q.name and g.direction == q.d then ghosts = ghosts + 1 end
      end
    end
    for id, l in pairs(storage.rails.lines) do
      if l.planner and l.force == F then
        for _, p in ipairs(l.pieces) do
          if math.abs(p.x - W.pieces[1].x) < 200 and math.abs(p.y - 300) < 40 then lines[id] = true end
          if p.x == T.cancelled.x and p.y == T.cancelled.y and p.name == T.cancelled.name then holder = true end
        end
      end
    end
    local nl = table_size(lines)
    check(T, "cancel", ghosts == #W.pieces - 1 and nl == 2 and not holder,
      "track 4 after a cancelled ghost: %d of %d ghosts stand, %d planner lines hold them, a line holds the cancelled "
      .. "piece %s", ghosts, #W.pieces, nl, tostring(holder))
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
  -- 0.1.3 (#33 items 1 and 2): the stop editor's warnings. A depot E whose platform no track reaches: A -> E and E -> A
  -- are unreachable, A -> B is not; train 1 (A, B, C, B) shares A and C with train 2 (A, C)
  T.E = depot(surface(), {x = 500, y = 300})
  local un = railroutes.unreachable({stops = {{target = T.A}, {target = T.E}}, loop = true})
  local none = railroutes.unreachable({stops = {{target = T.A}, {target = T.B}, {target = T.C}}, loop = true})
  local shared = railroutes.shared_with(T.r1)
  check(T, "warnings", un[2] == 1 and un[1] == 2 and next(none) == nil and shared ~= nil and shared == T.r2.id,
    "A, E: unreachable %s; A, B, C: unreachable %s; train 1 shares its stops with train %s (train 2 is %s)",
    serpent.line(un), serpent.line(none), tostring(shared), tostring(T.r2 and T.r2.id))
  T.stage, T.t5 = "hold", game.tick
end

-- Train 2 stays on C's platform (manual mode once it stands there); train 1, on its way to C, waits for it and after
-- a minute carries the single-track hint ("platform-held") in its panel's state line.
local function hold(T)
  local t2 = T.r2 and rails.train_of(T.r2)
  if not T.held_at then
    local d = T.r2 and T.r2.dwell
    if t2 and t2.state == TS.wait_station and d and d.stop == 2 then
      t2.manual_mode = true
      T.held_at = game.tick
      log("train 2 held on C's platform")
    elseif game.tick - T.t5 > 10 * 3600 then
      check(T, "platform_held", false, "train 2 never stood at C")
      finish(T)
    end
    return
  end
  local r1 = T.r1
  if r1 and r1.reason == "platform-held" then
    check(T, "platform_held", true, "train 1 waits %.0f s at a signal for C's platform, state line reason %s",
      (game.tick - (r1.held_since or game.tick)) / 60, r1.reason)
    if t2 then t2.manual_mode = false end -- (train 2 goes on: the crews of the short segments pass C's platform side)
    T.stage, T.short_k = "short", 0
  elseif game.tick - T.held_at > 10 * 3600 then
    check(T, "platform_held", false, "train 1 reason %s, state %s, held since %s", tostring(r1 and r1.reason),
      tostring(r1 and r1.state), tostring(r1 and r1.held_since))
    if t2 then t2.manual_mode = false end
    T.stage, T.short_k = "short", 0
  end
end

-- 0.1.4 (#41): the end state of a planner track's last piece (where the next short segment starts)
local function end_state(P)
  local id = P.lines[#P.lines]
  local l = id and rails.lines[id]
  local q = l and l.pieces[#l.pieces]
  return q and {x = q.gx, y = q.gy, d = q.gd, l = 0}
end

-- signals (and their ghosts) of F in the box around a list of pieces, `pad` tiles wider
local function signals_around(list, pad)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, q in ipairs(list) do
    x0, y0, x1, y1 = math.min(x0, q.x), math.min(y0, q.y), math.max(x1, q.x), math.max(y1, q.y)
  end
  local area = {{x0 - pad, y0 - pad}, {x1 + pad, y1 + pad}}
  local s = surface()
  return s.count_entities_filtered({area = area, force = F, type = {"rail-signal", "rail-chain-signal"}}),
    s.count_entities_filtered({area = area, force = F, ghost_type = {"rail-signal", "rail-chain-signal"}})
end

-- ten short segments in a row from B's free (east) platform end: each surveyed and handed over before the next one
local function short(T)
  if T.short_k > 0 then
    local P = handed(T, "short" .. T.short_k)
    if P == nil then return end
    if P == false then
      check(T, "short_signals", false, "short segment %d: survey failed", T.short_k)
      finish(T)
      return
    end
  end
  if T.short_k == 10 then
    T.stage, T.t7 = "short_built", game.tick
    return
  end
  local k = T.short_k + 1
  local b = platform_rail(T.B, 2)
  if k == 1 then -- (crews from B, next to the segments)
    fill(T.B, {{rails.LOCO_KIT, 4}, {rails.CWAGON_KIT, 2}, {"coal", 300}, {rails.RAIL, 800}})
  end
  local x0, y0 = b.position.x, b.position.y
  local goal = {x = x0 + 14 * k, y = y0 + (k > 4 and 6 * (k - 4) or 0)}
  if k == 1 then
    lay(T, "short1", {starts = ends_of(b), goals = goals_of_point(goal), start_rail = b, own_land = true})
  else
    local st = end_state(T.plan["short" .. (k - 1)])
    lay(T, "short" .. k, {starts = {st}, goals = goals_of_point(goal), own_land = true})
  end
  T.short_k = k
end

local function short_built(T)
  local all, built = {}, 0
  for k = 1, 10 do
    for _, q in ipairs(T.plan["short" .. k].pieces) do all[#all + 1] = q end
    built = built + built_of(T.plan["short" .. k])
  end
  if built < #all then
    if game.tick - T.t7 > 15 * 3600 then
      check(T, "short_signals", false, "%d of %d pieces of the ten short segments built after 15 min", built, #all)
      finish(T)
    end
    return
  end
  local sig, ghosts = signals_around(all, 4)
  local lines = 0
  for k = 1, 10 do lines = lines + #T.plan["short" .. k].lines end
  check(T, "short_signals", sig == 0 and ghosts == 0, "ten short segments in a row (%d pieces in %d planner lines) "
    .. "built in %.0f s: %d signals, %d signal ghosts on them", #all, lines, (game.tick - T.t7) / 60, sig, ghosts)
  -- a spur off a straight rail of segment 8: a real junction
  local P8 = T.plan.short8
  local from
  for _, q in ipairs(P8.pieces) do
    if q.name == "straight-rail" and not from then
      local e = surface().find_entity(q.name, {q.x, q.y})
      if e and e.valid then from = e end
    end
  end
  if not from then
    check(T, "spur", false, "no straight rail in segment 8")
    finish(T)
    return
  end
  lay(T, "spur", {starts = starts_of_rail(from), goals = goals_of_point({x = from.position.x + 6,
    y = from.position.y - 34}), start_rail = from, own_land = true})
  T.stage, T.t8 = "spur", game.tick
end

local function spur(T)
  local P = track_done(T, "spur", "spur", T.t8)
  if not P then return end
  local first
  for _, id in ipairs(P.lines) do
    local l = rails.lines[id]
    for _, p in ipairs(l and l.pieces or {}) do
      if p.jpos and not T.spur_j then T.spur_j, first = p.jpos, p.e end
    end
  end
  local chains = T.spur_j and surface().count_entities_filtered({position = T.spur_j, radius = 30,
    name = "rail-chain-signal", force = F}) or -1
  check(T, "spur", T.spur_j ~= nil and chains >= 4 and chains % 2 == 0 and chains <= 6,
    "spur off segment 8 (%d pieces) built in %.0f s: junction at %s, %d chain signals within 30 tiles",
    #P.pieces, (game.tick - T.t8) / 60, T.spur_j and util.pos_str(T.spur_j) or "-", chains)
  if not (first and first.valid) then
    check(T, "remove_junction", false, "the spur's first rail is not built")
    finish(T)
    return
  end
  local before = 0
  for _ in pairs(storage.rails.lines) do before = before + 1 end
  local res = rails.remove_track({first}, F, 0)
  local after = 0
  for _ in pairs(storage.rails.lines) do after = after + 1 end
  local left = surface().count_entities_filtered({position = T.spur_j, radius = 30, name = "rail-chain-signal",
    force = F})
  check(T, "remove_junction", res.rails == 1 and left == 0 and not first.valid and after == before,
    "the spur's first rail removed: %d rails, %d signals went, %d chain signals left within 30 tiles of the junction; "
    .. "lines %d -> %d (the spur's line goes on without its first piece)", res.rails, res.signals, left, before, after)
  -- the rails of segments 4 to 6, and a platform rail of A
  local list, want, keys = {}, 0, {}
  for k = 4, 6 do
    for _, id in ipairs(T.plan["short" .. k].lines) do
      local l = rails.lines[id]
      for _, p in ipairs(l and l.pieces or {}) do
        if p.e and p.e.valid then
          list[#list + 1] = p.e
          want = want + p.rails
          keys[#keys + 1] = {name = p.name, x = p.x, y = p.y, d = p.d}
        end
      end
    end
  end
  local pr = platform_rail(T.A, 1)
  list[#list + 1] = pr
  local res2 = rails.remove_track(list, F, 0)
  local gone_lines = true
  for k = 4, 6 do
    for _, id in ipairs(T.plan["short" .. k].lines) do if rails.lines[id] then gone_lines = false end end
  end
  local kept = 0
  for _, k in ipairs({3, 7}) do
    for _, id in ipairs(T.plan["short" .. k].lines) do if rails.lines[id] then kept = kept + 1 end end
  end
  T.removed = {keys = keys, at = game.tick, ok = res2.rails == #list - 1 and (res2.refund.rail or 0) == want
    and res2.kept.platform == 1 and pr.valid and gone_lines and kept >= 2, n = res2.rails, want = #list - 1,
    refund = res2.refund.rail or 0, rails_want = want, platform = res2.kept.platform, gone_lines = gone_lines,
    kept = kept, crews = {}}
  -- crews out beyond the removed stretch have no way home: recalled after 30 s (#41, the log says why)
  for id, rec in pairs(storage.rails.trains) do
    if rec.kind == "construction" and rec.force == F then T.removed.crews[#T.removed.crews + 1] = id end
  end
  T.stage = "removed"
end

local function removed(T)
  local M = T.removed
  if game.tick - M.at < 40 * 60 then return end
  local s, back = surface(), 0
  for _, q in ipairs(M.keys) do
    for _, e in ipairs(s.find_entities_filtered({position = {q.x, q.y}, radius = 0.5})) do
      if (e.name == q.name or (e.type == "entity-ghost" and e.ghost_name == q.name)) and e.direction == q.d then
        back = back + 1
      end
    end
  end
  check(T, "remove_track", M.ok and back == 0, "segments 4 to 6: %d of %d rails removed, refund %d rails (their pieces "
    .. "%d), their lines gone %s, segments 3 and 7 still lines %d, a platform rail kept %d; after 40 s %d rails or "
    .. "ghosts back on their places", M.n, M.want, M.refund, M.rails_want, tostring(M.gone_lines), M.kept, M.platform,
    back)
  local stuck = 0
  for _, id in ipairs(M.crews) do
    local rec = storage.rails.trains[id]
    local t = rec and rails.train_of(rec)
    if t and (t.state == TS.no_path or t.state == TS.path_lost) then stuck = stuck + 1 end
  end
  check(T, "crews_home", stuck == 0, "%d crews were out when the track went; after 40 s %d of them stand without a path "
    .. "(a crew cut off is recalled after 30 s)", #M.crews, stuck)
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
  elseif T.stage == "run" then run(T)
  elseif T.stage == "hold" then hold(T)
  elseif T.stage == "short" then short(T)
  elseif T.stage == "short_built" then short_built(T)
  elseif T.stage == "spur" then spur(T)
  elseif T.stage == "removed" then removed(T) end
end)
