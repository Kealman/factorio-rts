-- Test-only (tools/autotest-run.sh EXTRA_LUA): 0.1.2 #31 part B, multi-stop schedules (scripts/railroutes.lua).
-- Run (about 5 minutes of wall clock at SPEED=8; a Skirmish AI autotest runs beside it, long enough not to end the
-- match: the legacy "waves" autotest resets its match after 2.5 minutes, which tears the rails down):
--   SPEED=8 DURATION_MIN=40 EXTRA_LUA=tools/probes/r3_rails_schedule.lua STOP_ON='r3 schedule summary' \
--     tools/autotest-run.sh r3-sched '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}' 900
-- Scene on its own lab-tile surface "r3-sched" with the non-participating force rts-ai-3 in Nation rules
-- (storage.rails.test_nation): depots A (0, 0), B (400, 0), C (800, 0) whose platforms lie on one east-west track
-- (y = 7) joined by script-laid straight rails, and depots D (200, -400) and E (200, 400) whose platforms lie on a
-- north-south track (x = 207) that crosses the first one at (207, 7): a junction guarded by a chain signal before and a
-- rail signal after it on all four arms. Freight train 1 runs A (load exports, idle 5 s) -> B (unload to Keep, load
-- exports, idle 10 s) -> C (unload everything, load exports, 40 s) -> B (unload to Keep, idle 10 s) and loops; freight
-- train 2 runs D (load exports) -> E (unload everything) through the junction. Networks: A exports iron, B keeps 2,000
-- iron and 1,000 stone and exports copper, C exports stone, D exports coal; B's iron is used up a little every
-- minute. An artillery train runs F (-400, 0) -> a rail at (-201, 7) (bombard, 20 s) and loops on the track west of A
-- (a signal pair at x = -61 splits it from A's platform). Checks after RUN_MINUTES of game time ("[rts] r3 schedule
-- check <name>: PASS|FAIL ..."):
--   records       train 1's engine schedule has 4 records with inactivity / inactivity / time / inactivity waits
--   order         train 1 visited its stops in list order (A B C B A ...) and finished >= MIN_LOOPS loops
--   policies      B received iron and stone, C received copper (the policies' goods)
--   native        the engine ran the loop: the script wrote no schedule after the setup (rec.writes)
--   junction      both trains crossed the junction; train 2 finished >= MIN_LOOPS loops
--   no_deadlock   no train stood at a signal or without a path for DEADLOCK_S seconds in a row
--   status        railroutes.status said "stop i of 4" with an item and counts while train 1 loaded
--   rail_stop     the artillery train's rail record stays in its schedule (not temporary), it looped F -> rail
--                 >= MIN_LOOPS times and railroutes.bombard_here was true at the rail
-- Summary: "[rts] r3 schedule summary <passed>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local rails = require("scripts.rails")
local railroutes = require("scripts.railroutes")
local logistics = require("scripts.logistics")
local buildings = require("scripts.buildings")

local F = "rts-ai-3"
local SURFACE = "r3-sched"
local START_TICK = 600
local RUN_MINUTES = tonumber(rawget(_G, "R3_SCHED_MINUTES") or 20)
local MIN_LOOPS = 4
local DEADLOCK_S = 60
local D = defines.direction
local TS = defines.train_state

local function S()
  storage.r3_sched = storage.r3_sched or {pass = 0, fail = 0, visits = {}, visits2 = {}, cross = {0, 0}}
  return storage.r3_sched
end

local function log(fmt, ...) util.log("r3 schedule: " .. fmt, ...) end

local function check(T, name, ok, fmt, ...)
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("r3 schedule check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

local function surface()
  local s = game.surfaces[SURFACE]
  if s then return s end
  s = game.create_surface(SURFACE, {width = 0, height = 0, peaceful_mode = true, no_enemies_mode = true})
  s.generate_with_lab_tiles = true
  s.always_day = true
  for x = -480, 928, 32 do
    for y = -480, 480, 32 do s.request_to_generate_chunks({x + 16, y + 16}, 0) end
  end
  s.force_generate_chunk_requests()
  return s
end

-- A depot whose platform takes the given layout (rails.lua's rebuild-on-site hook picks the spec).
local function depot(s, pos, axis, side)
  local p = {x = pos.x, y = pos.y}
  local track
  if axis == "x" then track = 2 * math.floor((p.y + side * rails.PLATFORM_GAP) / 2) + 1
  else track = 2 * math.floor((p.x + side * rails.PLATFORM_GAP) / 2) + 1 end
  storage.rails.reuse_site = {force = F, x = p.x, y = p.y, spec = {axis = axis, side = side, track = track}}
  local e = s.create_entity({name = rails.DEPOT, position = p, force = F, raise_built = true})
  storage.rails.reuse_site = nil
  if not e then return nil end
  for i = 1, 4 do
    local sp = s.find_non_colliding_position("rts-stockpile", {p.x - 10 + i * 4, p.y - 6}, 8, 1, true)
    local st = sp and s.create_entity({name = "rts-stockpile", position = sp, force = F, raise_built = true})
    if st then buildings.register(st) end
  end
  return e.unit_number
end

-- items = {{name, count}, ...} in order (kits and coal first: the stockpiles hold 6 x 48 stacks)
local function fill(un, items)
  local net = logistics.hub_network(un)
  local n = 0
  for _, it in ipairs(items) do n = n + (net and net.insert({name = it[1], count = it[2]}) or 0) end
  return n
end

local function lay(s, x0, x1, y, dir)
  local n = 0
  for v = x0, x1, 2 do
    local pos = dir == D.east and {v, y} or {y, v}
    if not s.find_entity("straight-rail", pos) or true then
      if s.create_entity({name = "straight-rail", position = pos, direction = dir, force = F}) then n = n + 1 end
    end
  end
  return n
end

-- A chain signal before and a rail signal after the junction on one arm: the arm's rail `at`, its end toward `toward`.
local function guard(s, at, dir, toward)
  local rail
  for _, r in ipairs(s.find_entities_filtered({position = at, radius = 0.5, name = "straight-rail"})) do
    if r.direction == dir or r.direction == (dir + 8) % 16 then rail = r end
  end
  if not rail then return 0 end
  local best, bd
  for _, rd in ipairs({defines.rail_direction.front, defines.rail_direction.back}) do
    local re = rail.get_rail_end(rd)
    local p = re.location.position
    local d = (p.x - toward.x) ^ 2 + (p.y - toward.y) ^ 2
    if not bd or d < bd then best, bd = re, d end
  end
  local n = 0
  local out, inn = best.out_signal_location, best.in_signal_location
  if s.create_entity({name = "rail-chain-signal", position = out.position, direction = out.direction, force = F}) then
    n = n + 1
  end
  if s.create_entity({name = "rail-signal", position = inn.position, direction = inn.direction, force = F}) then
    n = n + 1
  end
  return n
end

local function setup(T)
  local R = storage.rails
  R.test_nation = true
  R.test_forces = R.test_forces or {}
  R.test_forces[F] = true
  if not game.forces[F] then game.create_force(F) end
  local s = surface()
  T.A = depot(s, {x = 0, y = 0}, "x", 1)
  T.B = depot(s, {x = 400, y = 0}, "x", 1)
  T.C = depot(s, {x = 800, y = 0}, "x", 1)
  T.D = depot(s, {x = 200, y = -400}, "y", 1)
  T.E = depot(s, {x = 200, y = 400}, "y", 1)
  T.F = depot(s, {x = -400, y = 0}, "x", 1)
  for _, k in ipairs({"A", "B", "C", "D", "E", "F"}) do
    local d = T[k] and rails.depot(T[k])
    log("depot %s #%s platform %s track %s", k, tostring(T[k]), d and d.platform and d.platform.axis or "-",
      d and d.platform and tostring(d.platform.track) or "-")
    if not (d and d.platform) then
      check(T, "setup", false, "depot %s has no platform", k)
      T.done = true
      return
    end
  end
  -- track: y = 7 from A's platform through B's to C's; x = 207 from D's to E's
  local laid = lay(s, 21, 379, 7, D.east) + lay(s, 421, 779, 7, D.east) + lay(s, -379, 379, 207, D.north)
    + lay(s, -379, -21, 7, D.east)
  local sig = guard(s, {x = 199, y = 7}, D.east, {x = 207, y = 7}) + guard(s, {x = 215, y = 7}, D.east, {x = 207, y = 7})
    + guard(s, {x = 207, y = -1}, D.north, {x = 207, y = 7}) + guard(s, {x = 207, y = 15}, D.north, {x = 207, y = 7})
  -- a signal pair between F's track and A's platform
  local r61 = s.find_entity("straight-rail", {-61, 7})
  local re = r61 and r61.get_rail_end(defines.rail_direction.front)
  if re then
    for _, loc in ipairs({re.in_signal_location, re.out_signal_location}) do
      if s.create_entity({name = "rail-signal", position = loc.position, direction = loc.direction, force = F}) then
        sig = sig + 1
      end
    end
  end
  log("track: %d rails laid, %d signals", laid, sig)
  T.stage = "fill"
  T.fill_at = game.tick + 120
end

-- (two seconds later: the depot networks exist)
local function stock(T)
  logistics.set_policy(T.A, "export_above", "iron-plate", 0)
  logistics.set_policy(T.B, "keep", "iron-plate", 2000)
  logistics.set_policy(T.B, "keep", "stone", 1000)
  logistics.set_policy(T.B, "export_above", "copper-plate", 0)
  logistics.set_policy(T.C, "export_above", "stone", 0)
  logistics.set_policy(T.D, "export_above", "coal", 2000)
  local kits = {{rails.LOCO_KIT, 2}, {rails.WAGON_KIT, 2}, {"coal", 500}}
  local n = fill(T.A, {kits[1], kits[2], kits[3], {"iron-plate", 12000}})
    + fill(T.B, {kits[3], {"copper-plate", 12000}}) + fill(T.C, {kits[3], {"stone", 6000}})
    + fill(T.D, {kits[1], kits[2], {"coal", 10000}}) + fill(T.E, {kits[3]})
    + fill(T.F, {kits[1], {rails.ARTY_KIT, 1}, kits[3]})
  local na, nd = logistics.hub_network(T.A), logistics.hub_network(T.D)
  log("%d items stocked; A network %s: %d loco kits, %d wagon kits, %d coal; D %d loco kits", n,
    tostring(na and na.network_id), na and na.get_item_count(rails.LOCO_KIT) or -1,
    na and na.get_item_count(rails.WAGON_KIT) or -1, na and na.get_item_count("coal") or -1,
    nd and nd.get_item_count(rails.LOCO_KIT) or -1)
  T.stage, T.train_at = "trains", game.tick + 60
end

local function trains(T)
  local na = logistics.hub_network(T.A)
  local de = rails.depot(T.A).entity
  local chests = de.surface.find_entities_filtered({position = de.position, radius = 20, type = {"container",
    "logistic-container"}})
  local parts = {}
  for _, c in ipairs(chests) do
    local inv = c.get_inventory(defines.inventory.chest)
    parts[#parts + 1] = string.format("%s@%s:%d net=%s", c.name, util.pos_str(c.position), inv and inv.get_item_count() or -1,
      tostring(c.logistic_network and c.logistic_network.network_id))
  end
  log("before trains: A network %s cells %d energy %.0f: %d items, loco kits %d; chests [%s]",
    tostring(na and na.network_id), na and #na.cells or -1, de.energy, na and na.get_item_count() or -1,
    na and na.get_item_count(rails.LOCO_KIT) or -1, table.concat(parts, "; "))
  local t1, why1 = rails.create_train(T.A, "cargo")
  local t2, why2 = rails.create_train(T.D, "cargo")
  if not (t1 and t2) then
    check(T, "setup", false, "trains: %s (%s), %s (%s)", tostring(t1), tostring(why1), tostring(t2), tostring(why2))
    T.done = true
    return
  end
  local ok1, e1 = railroutes.set(t1, {
    {target = T.A, load = "exports", wait = {type = "inactivity", seconds = 5}},
    {target = T.B, unload = "keep", load = "exports", wait = {type = "inactivity", seconds = 10}},
    {target = T.C, unload = "all", load = "exports", wait = {type = "time", seconds = 40}},
    {target = T.B, unload = "keep", wait = {type = "inactivity", seconds = 10}},
  })
  local ok2, e2 = railroutes.set(t2, {
    {target = T.D, load = "exports", wait = {type = "inactivity", seconds = 5}},
    {target = T.E, unload = "all", wait = {type = "inactivity", seconds = 5}},
  })
  T.id1, T.id2 = t1.id, t2.id
  T.r1, T.r2 = rails.train_record(t1), rails.train_record(t2)
  local t3, why3 = rails.create_train(T.F, "artillery")
  local rail = surface().find_entity("straight-rail", {-201, 7})
  if t3 and rail then
    local i1 = railroutes.add(t3, T.F)
    local i2 = railroutes.add(t3, rail)
    T.r3 = rails.train_record(t3)
    local st = T.r3.stops[2]
    log("artillery train %d: stops %s, %s; rail stop %s", t3.id, tostring(i1), tostring(i2),
      st and railroutes.describe(st) or "-")
    railroutes.update(t3, 2, {wait = {type = "time", seconds = 20}})
  else
    log("artillery train: %s (%s), rail %s", tostring(t3), tostring(why3), tostring(rail))
  end
  T.visits3, T.bombard_seen = {}, false
  log("trains %d (%s %s) and %d (%s %s) on their stop lists", t1.id, tostring(ok1), tostring(e1), t2.id, tostring(ok2),
    tostring(e2))
  T.writes1, T.writes2 = T.r1.writes, T.r2.writes
  T.t0 = game.tick
end

local function train_of(rec) return rec and rails.train_of(rec) end

local function watch(T, rec, key, state_key)
  local train = train_of(rec)
  if not (train and train.valid) then return end
  local st = train.state
  local stuck = st == TS.wait_signal or st == TS.no_path or st == TS.path_lost or st == TS.destination_full
  if stuck then
    T[state_key] = T[state_key] or game.tick
    local secs = (game.tick - T[state_key]) / 60
    T.max_stuck = math.max(T.max_stuck or 0, secs)
  else
    T[state_key] = nil
  end
  -- crossings of the junction
  local p = train.front_stock and train.front_stock.position
  if p then
    local side = key == 1 and (p.x < 207 and -1 or 1) or (p.y < 7 and -1 or 1)
    local last = T["side" .. key]
    if last and last ~= side then T.cross[key] = T.cross[key] + 1 end
    T["side" .. key] = side
  end
end

events.on(defines.events.on_train_changed_state, function(e)
  local T = storage.r3_sched
  if not (T and T.t0 and not T.done) or e.train.state ~= TS.wait_station then return end
  local rec = rails.train_record(e.train)
  if not rec then return end
  local d = rec.dwell
  if rec == T.r1 and d then T.visits[#T.visits + 1] = d.stop end
  if rec == T.r2 and d then T.visits2[#T.visits2 + 1] = d.stop end
  if rec == T.r3 and d then T.visits3[#T.visits3 + 1] = d.stop end
end)

local function net_count(un, item)
  local net = logistics.hub_network(un)
  return net and net.get_item_count(item) or 0
end

events.on_nth_tick(60, function(e)
  local T = S()
  if T.done or e.tick < START_TICK then return end
  if not T.t0 then
    if not storage.rails then return end
    if not T.stage then setup(T) elseif T.stage == "fill" and e.tick >= T.fill_at then stock(T)
    elseif T.stage == "trains" and e.tick >= T.train_at then trains(T) end
    return
  end
  watch(T, T.r1, 1, "stuck1")
  watch(T, T.r2, 2, "stuck2")
  local t3 = train_of(T.r3)
  if t3 and railroutes.bombard_here(T.r3, t3) then T.bombard_seen = true end
  local t1 = train_of(T.r1)
  -- B's industry uses 300 iron a minute; C and E use what they get; A, B, C and D keep their exports up
  if (e.tick - T.t0) % 3600 == 0 then
    local net = logistics.hub_network(T.B)
    if net then net.remove_item({name = "iron-plate", count = 300}) end
    for _, x in ipairs({{T.C, "copper-plate"}, {T.E, "coal"}}) do
      local n2 = logistics.hub_network(x[1])
      local have = n2 and n2.get_item_count(x[2]) or 0
      if have > 2000 then n2.remove_item({name = x[2], count = have - 2000}) end
    end
    for _, x in ipairs({{T.A, "iron-plate", 12000}, {T.B, "copper-plate", 12000}, {T.C, "stone", 6000},
                        {T.D, "coal", 10000}}) do
      local n2 = logistics.hub_network(x[1])
      local have = n2 and n2.get_item_count(x[2]) or 0
      if have < x[3] then n2.insert({name = x[2], count = x[3] - have}) end
    end
    local st = t1 and railroutes.status(T.r1, t1)
    log("minute %d: train 1 %s stop %s/%d, visits %d; train 2 visits %d; crossings %d/%d; B iron %d stone %d, C copper %d",
      (e.tick - T.t0) / 3600, tostring(T.r1.state), tostring(st and st.index), st and st.count or 0, #T.visits,
      #T.visits2, T.cross[1], T.cross[2], net_count(T.B, "iron-plate"), net_count(T.B, "stone"),
      net_count(T.C, "copper-plate"))
  end
  if t1 and not T.status_seen then
    local st = railroutes.status(T.r1, t1)
    if st.item and st.want and st.want > 0 and st.index then
      T.status_seen = string.format("stop %d of %d, %s %s %d / %d", st.index, st.count, tostring(st.phase), st.item,
        st.done or 0, st.want)
    end
  end
  if e.tick - T.t0 < RUN_MINUTES * 3600 then return end
  T.done = true
  local sch = t1 and t1.get_schedule()
  local recs = sch and sch.get_records() or {}
  local waits = {}
  for i, r in ipairs(recs) do waits[i] = r.wait_conditions and r.wait_conditions[1] and r.wait_conditions[1].type or "-" end
  check(T, "records", #recs == 4 and waits[1] == "inactivity" and waits[2] == "inactivity" and waits[3] == "time"
    and waits[4] == "inactivity", "%d records, waits [%s]", #recs, table.concat(waits, " "))
  local in_order, loops = true, 0
  for i, v in ipairs(T.visits) do
    if i > 1 and v ~= (T.visits[i - 1] % 4) + 1 then in_order = false end
    if v == 4 then loops = loops + 1 end
  end
  check(T, "order", in_order and loops >= MIN_LOOPS, "visits [%s], %d loops", table.concat(T.visits, " "), loops)
  local stats = T.r1.delivered or {}
  check(T, "policies", (stats["iron-plate"] or 0) > 0 and (stats.stone or 0) > 0 and (stats["copper-plate"] or 0) > 0,
    "train 1 delivered %s", serpent.line(stats))
  check(T, "native", T.r1.writes == T.writes1 and T.r2.writes == T.writes2,
    "schedule writes by the script: train 1 %s (after the setup %s), train 2 %s (%s)", tostring(T.r1.writes),
    tostring(T.writes1), tostring(T.r2.writes), tostring(T.writes2))
  local loops2 = 0
  for _, v in ipairs(T.visits2) do if v == 2 then loops2 = loops2 + 1 end end
  check(T, "junction", T.cross[1] >= 2 and T.cross[2] >= 2 and loops2 >= MIN_LOOPS,
    "junction crossed %d times by train 1 and %d by train 2; train 2 loops %d", T.cross[1], T.cross[2], loops2)
  check(T, "no_deadlock", (T.max_stuck or 0) < DEADLOCK_S, "longest stand at a signal or without a path %.0f s",
    T.max_stuck or 0)
  check(T, "status", T.status_seen ~= nil, "%s", tostring(T.status_seen))
  local t3 = train_of(T.r3)
  local recs3 = t3 and t3.get_schedule().get_records() or {}
  local loops3 = 0
  for _, v in ipairs(T.visits3 or {}) do if v == 2 then loops3 = loops3 + 1 end end
  check(T, "rail_stop", #recs3 == 2 and recs3[2].rail ~= nil and not recs3[2].temporary and loops3 >= MIN_LOOPS
    and T.bombard_seen, "%d records (2nd: rail %s, temporary %s), visits [%s], %d loops, bombard seen %s", #recs3,
    tostring(recs3[2] and recs3[2].rail ~= nil), tostring(recs3[2] and recs3[2].temporary),
    table.concat(T.visits3 or {}, " "), loops3, tostring(T.bombard_seen))
  util.log("r3 schedule summary %d/%d", T.pass, T.pass + T.fail)
end)
