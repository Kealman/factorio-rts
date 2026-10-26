-- Test-only (tools/autotest-run.sh EXTRA_LUA): 0.1.2 #32, the train builder (rails.create_composed, add / remove
-- carriage, templates, platform lengths) with the stop lists of #31 part B. Runs beside a Nation AI match (garrison's
-- boarding is Nation-only), about 4 minutes of wall clock:
--   SEED=501 SPEED=4 EXTRA_LUA=tools/probes/r3_rails_builder.lua STOP_ON='r3 builder summary' \
--     tools/autotest-run.sh r3-build '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 900
-- Scene on its own lab-tile surface, force rts-ai-2 (and rts-ai-3 as the enemy of the siege), four rigs:
--   freight  depot A with an 80-tile platform (rails.set_platform_length) and depot B (40 tiles) 600 tiles apart on
--            one track; loco + 3 cargo + loco composed at A runs A (load exports) -> B (unload to Keep)
--   mixed    depots C (80) and D (40): loco + cargo + troop wagon + loco composed at C, 8 walkers embark at C; the
--            train runs C (load exports, troops board) -> D (unload to Keep, troops get off)
--   siege    depot S with a dead-end track 400 tiles east: armoured loco + artillery + armoured troop wagon + armoured
--            loco runs S -> a rail 300 tiles out marked "bombard here"; an rts-ai-3 turret 100 tiles from that rail
--            (a walker of rts-ai-2 spots it); the train's stance stays "none": it fires only from the stop
--   edit     depot T (40 tiles): loco + cargo + loco, then add carriages at the rear up to the platform's 5, a 6th is
--            refused; two removals give one kit back (half each)
-- Checks ("[rts] r3 builder check <name>: PASS|FAIL ..."):
--   platforms   A and C have 80-tile platforms (11 carriages), B and D 40 (5)
--   too_long    loco + 7 cargo + loco is refused at B "too-long" and accepted by compose_check at A
--   rules       an empty composition, a wagon in front and a reversed front locomotive are refused; a composition with
--               no locomotive facing back is flagged forwards-only
--   freight     the composed freight train (5 carriages, kits gone from A) delivered iron to B
--   mixed       the mixed train's kind is "cargo" with caps cargo 1 / troop 1, it delivered goods to D and the 8
--               walkers got off at D
--   siege       the turret died, the train fired shells, its stance stayed "none"
--   edit        3 -> 4 -> 5 carriages, the 6th refused "too-long"; 5 -> 4 -> 3 with one cargo wagon kit back
--   templates   5 templates saved, a 6th refused "full", one deleted, one replaced by name
-- Summary: "[rts] r3 builder summary <passed>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local buildings = require("scripts.buildings")
local rails = require("scripts.rails")
local railroutes = require("scripts.railroutes")
local trainswar = require("scripts.trainswar")
local garrison = require("scripts.garrison")

local F, E = "rts-ai-2", "rts-ai-3"
local SURFACE = "r3-build"
local START_TICK = 900
local D = defines.direction
local L, AL, C, CW = rails.LOCO, rails.ALOCO, rails.WAGON, rails.CWAGON
local T_, AT, A = rails.TWAGON, rails.AWAGON, rails.ARTY

local function S()
  storage.r3_build = storage.r3_build or {pass = 0, fail = 0, stage = "setup"}
  return storage.r3_build
end
local function log(fmt, ...) util.log("r3 builder: " .. fmt, ...) end
local function check(T, name, ok, fmt, ...)
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("r3 builder check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end
local function cars(list)
  local out = {}
  for i, n in ipairs(list) do
    if type(n) == "table" then out[i] = {name = n[1], reversed = n[2]} else out[i] = {name = n} end
  end
  return out
end

local function surface()
  local s = game.surfaces[SURFACE]
  if s then return s end
  s = game.create_surface(SURFACE, {width = 0, height = 0, peaceful_mode = true, no_enemies_mode = true})
  s.generate_with_lab_tiles = true
  s.always_day = true
  for x = -96, 704, 32 do
    for y = -64, 1000, 32 do s.request_to_generate_chunks({x + 16, y + 16}, 0) end
  end
  s.force_generate_chunk_requests()
  return s
end

local function depot(s, pos, tiles)
  rails.set_platform_length(F, tiles)
  storage.rails.reuse_site = {force = F, x = pos.x, y = pos.y, spec = {axis = "x", side = 1,
    track = 2 * math.floor((pos.y + rails.PLATFORM_GAP) / 2) + 1}}
  local e = s.create_entity({name = rails.DEPOT, position = pos, force = F, raise_built = true})
  storage.rails.reuse_site = nil
  rails.set_platform_length(F, 40)
  if not e then return nil end
  for i = 1, 4 do
    local sp = s.find_non_colliding_position("rts-stockpile", {pos.x - 10 + i * 4, pos.y - 6}, 8, 1, true)
    local st = sp and s.create_entity({name = "rts-stockpile", position = sp, force = F, raise_built = true})
    if st then buildings.register(st) end
  end
  return e.unit_number
end

local function lay(s, x0, x1, y)
  local n = 0
  for x = x0, x1, 2 do
    if s.create_entity({name = "straight-rail", position = {x, y}, direction = D.east, force = F}) then n = n + 1 end
  end
  return n
end

local function fill(un, items)
  local net = logistics.hub_network(un)
  for _, it in ipairs(items) do if net then net.insert({name = it[1], count = it[2]}) end end
end

local function count(un, item)
  local net = logistics.hub_network(un)
  return net and net.get_item_count(item) or 0
end

local function track_of(un) return rails.depot(un).platform.track end

local function setup(T)
  local R = storage.rails
  R.test_forces = R.test_forces or {}
  R.test_forces[F] = true
  for _, f in ipairs({F, E}) do if not game.forces[f] then game.create_force(f) end end
  game.forces[F].set_cease_fire(E, false)
  game.forces[E].set_cease_fire(F, false)
  local s = surface()
  T.A = depot(s, {x = 0, y = 0}, 80)
  T.B = depot(s, {x = 600, y = 0}, 40)
  T.C = depot(s, {x = 0, y = 300}, 80)
  T.D = depot(s, {x = 600, y = 300}, 40)
  T.S = depot(s, {x = 0, y = 600}, 40)
  T.T = depot(s, {x = 0, y = 900}, 40)
  for _, k in ipairs({"A", "B", "C", "D", "S", "T"}) do
    local d = T[k] and rails.depot(T[k])
    if not (d and d.platform) then
      check(T, "platforms", false, "depot %s has no platform", k)
      T.stage = "done"
      return
    end
  end
  local laid = lay(s, 41, 579, track_of(T.A)) + lay(s, 41, 579, track_of(T.C)) + lay(s, 21, 401, track_of(T.S))
  log("track: %d rails", laid)
  local tA, tB = rails.platform_tiles(rails.depot(T.A)), rails.platform_tiles(rails.depot(T.B))
  local tC, tD = rails.platform_tiles(rails.depot(T.C)), rails.platform_tiles(rails.depot(T.D))
  check(T, "platforms", tA == 80 and tC == 80 and tB == 40 and tD == 40 and rails.max_carriages(tA) == 11
    and rails.max_carriages(tB) == 5, "A %d, B %d, C %d, D %d tiles; A holds %d carriages, B %d", tA, tB, tC, tD,
    rails.max_carriages(tA), rails.max_carriages(tB))
  T.stage, T.at = "stock", game.tick + 120
end

local function stock(T)
  local kit = {[L] = rails.LOCO_KIT, [AL] = rails.ALOCO_KIT, [C] = rails.WAGON_KIT, [T_] = rails.TWAGON_KIT,
               [AT] = rails.AWAGON_KIT, [A] = rails.ARTY_KIT}
  fill(T.A, {{kit[L], 4}, {kit[C], 9}, {"coal", 300}, {"iron-plate", 8000}})
  fill(T.B, {{"coal", 300}})
  fill(T.C, {{kit[L], 2}, {kit[C], 1}, {kit[T_], 1}, {"coal", 300}, {"copper-plate", 6000}})
  fill(T.D, {{"coal", 300}})
  fill(T.S, {{kit[AL], 2}, {kit[A], 1}, {kit[AT], 1}, {"coal", 300}, {trainswar.SHELL, 40}})
  fill(T.T, {{kit[L], 2}, {kit[C], 5}, {"coal", 300}})
  logistics.set_policy(T.A, "export_above", "iron-plate", 0)
  logistics.set_policy(T.B, "keep", "iron-plate", 4000)
  logistics.set_policy(T.C, "export_above", "copper-plate", 0)
  logistics.set_policy(T.D, "keep", "copper-plate", 2000)
  -- rules
  local long = cars({L, C, C, C, C, C, C, C, {L, true}})
  local why_b = rails.compose_check(T.B, long)
  local why_a = rails.compose_check(T.A, long)
  check(T, "too_long", why_b == "too-long" and (why_a == nil or why_a == "no-kits"),
    "9 carriages at B (40 tiles): %s; at A (80 tiles): %s", tostring(why_b), tostring(why_a))
  local e1 = rails.compose_check(T.A, {})
  local e2 = rails.compose_check(T.A, cars({C, {L, true}}))
  local e3 = rails.compose_check(T.A, cars({{L, true}, C}))
  local _, info = rails.compose_check(T.A, cars({L, C, C}))
  check(T, "rules", e1 == "empty" and e2 == "no-front-loco" and e3 == "no-front-loco" and info.forwards_only == true,
    "empty %s, wagon in front %s, reversed front %s, loco + 2 cargo forwards-only %s", tostring(e1), tostring(e2),
    tostring(e3), tostring(info.forwards_only))
  -- freight at A
  local kits0 = count(T.A, rails.WAGON_KIT)
  local t1, w1 = rails.create_composed(T.A, cars({L, C, C, C, {L, true}}), {preset = "test"})
  T.freight = t1 and t1.id
  T.freight_kits = kits0 - count(T.A, rails.WAGON_KIT)
  T.freight_cars = t1 and #t1.carriages or 0
  if t1 then
    railroutes.set(t1, {{target = T.A, load = "exports", wait = {type = "inactivity", seconds = 5}},
                        {target = T.B, unload = "keep", wait = {type = "inactivity", seconds = 5}}})
  end
  -- mixed at C, 8 walkers embark
  local t2, w2 = rails.create_composed(T.C, cars({L, C, T_, {L, true}}))
  T.mixed = t2 and t2.id
  if t2 then
    local s = surface()
    local list = {}
    local p = rails.depot(T.C).entity.position
    for k = 1, 8 do
      local e = units.spawn("rts-walker", {x = p.x - 12 + (k % 4) * 3, y = p.y - 14 - math.floor(k / 4) * 3}, F, nil, s)
      if e then list[#list + 1] = e end
    end
    T.div = divisions.create(F, list, {name = "Rail Test", stance = "hold"}, {owner = "ai"})
    local ok = T.div and garrison.embark(T.div, T.C)
    log("mixed train %s at C, division #%s of %d walkers, embark %s", tostring(t2.id), tostring(T.div), #list,
      tostring(ok))
  end
  -- siege at S: armoured loco + artillery + armoured troop wagon + armoured loco, a rail stop 300 tiles out
  local t3, w3 = rails.create_composed(T.S, cars({AL, A, AT, {AL, true}}))
  T.siege = t3 and t3.id
  if t3 then
    local s = surface()
    local ty = track_of(T.S)
    local rail = s.find_entity("straight-rail", {301, ty})
    T.turret = s.create_entity({name = "rts-turret", position = {301, ty + 100}, force = E, raise_built = true})
    T.spotter = units.spawn("rts-walker", {x = 301, y = ty + 65}, F, nil, s)
    railroutes.set(t3, {{target = T.S, wait = {type = "inactivity", seconds = 5}},
                        {rail = rail, bombard = true, wait = {type = "time", seconds = 120}}})
  end
  -- edit at T: loco + cargo + loco
  local t4, w4 = rails.create_composed(T.T, cars({L, C, {L, true}}))
  T.edit = t4 and t4.id
  log("composed: freight %s (%s), mixed %s (%s), siege %s (%s), edit %s (%s)", tostring(T.freight), tostring(w1),
    tostring(T.mixed), tostring(w2), tostring(T.siege), tostring(w3), tostring(T.edit), tostring(w4))
  -- templates
  local f = F
  local ids = {}
  for k = 1, 5 do ids[k] = rails.save_template(f, "T" .. k, cars({L, C, {L, true}})) end
  local sixth, why6 = rails.save_template(f, "T6", cars({L, {L, true}}))
  local del = rails.delete_template(f, 2)
  local rep = rails.save_template(f, "T3", cars({AL, A, {AL, true}}))
  local list = rails.templates(f)
  check(T, "templates", ids[5] == 5 and sixth == nil and why6 == "full" and del and #list == 4 and rep == 2
    and list[2].cars[1].name == AL, "saved %s, 6th %s (%s), deleted #2 %s, T3 replaced at %s; %d templates",
    serpent.line(ids), tostring(sixth), tostring(why6), tostring(del), tostring(rep), #list)
  T.stage, T.t0 = "run", game.tick
end

local function edit_step(T)
  local rec = rails.train_record(T.edit)
  local train = rec and rails.train_of(rec)
  if not train then
    check(T, "edit", false, "no edit train")
    return
  end
  local front = train.front_stock -- (every coupling makes a new LuaTrain: follow the front locomotive)
  local n = {#train.carriages}
  local ok1 = rails.add_carriage(front.train, C)
  n[#n + 1] = #front.train.carriages
  local ok2 = rails.add_carriage(front.train, C)
  n[#n + 1] = #front.train.carriages
  local ok3, why3 = rails.add_carriage(front.train, C)
  local kits0 = count(T.T, rails.WAGON_KIT)
  local ok4 = rails.remove_carriage(front.train)
  n[#n + 1] = #front.train.carriages
  local ok5, why5 = rails.remove_carriage(front.train)
  n[#n + 1] = #front.train.carriages
  local back = count(T.T, rails.WAGON_KIT) - kits0
  check(T, "edit", ok1 and ok2 and not ok3 and why3 == "too-long" and ok4 and ok5 and n[1] == 3 and n[2] == 4
    and n[3] == 5 and n[4] == 4 and n[5] == 3 and back == 1,
    "carriages %s; 6th %s (%s); removals %s %s (%s); cargo wagon kits back %d", table.concat(n, " -> "),
    tostring(ok3), tostring(why3), tostring(ok4), tostring(ok5), tostring(why5), back)
end

events.on_nth_tick(60, function(e)
  local T = S()
  if T.stage == "done" or e.tick < START_TICK then return end
  if T.stage == "setup" then
    if not storage.rails then return end
    setup(T)
    return
  end
  if T.stage == "stock" then
    if e.tick >= T.at then stock(T) end
    return
  end
  local age = e.tick - T.t0
  if age == 600 or (age > 600 and not T.edited) then
    T.edited = true
    edit_step(T)
  end
  -- the mixed train leaves once its troops are aboard: its stop list is set after the boarding started
  if not T.mixed_routed and age >= 300 then
    local rec = rails.train_record(T.mixed)
    local train = rec and rails.train_of(rec)
    if train then
      railroutes.set(train, {{target = T.C, load = "exports", troops = "board", wait = {type = "inactivity", seconds = 5}},
                             {target = T.D, unload = "keep", troops = "unload", wait = {type = "inactivity", seconds = 5}}})
      T.mixed_routed = true
    end
  end
  local rec3 = rails.train_record(T.siege)
  local t3 = rec3 and rails.train_of(rec3)
  if t3 and railroutes.bombard_here(rec3, t3) and not T.bombard_at then T.bombard_at = game.tick end
  if age % 1800 == 0 then
    local r1 = rails.train_record(T.freight)
    local r2 = rails.train_record(T.mixed)
    log("minute %.1f: freight %s delivered %s; mixed %s delivered %s, division aboard %s; siege %s shots %s, turret %s",
      age / 3600, r1 and r1.state or "-", r1 and serpent.line(r1.delivered) or "-", r2 and r2.state or "-",
      r2 and serpent.line(r2.delivered) or "-", tostring(T.div and divisions.get(T.div) and divisions.get(T.div).aboard),
      rec3 and rec3.state or "-", tostring(rec3 and rec3.shots), tostring(T.turret and T.turret.valid))
  end
  if age < 6 * 3600 then return end
  T.stage = "done"
  local r1 = rails.train_record(T.freight)
  check(T, "freight", T.freight_cars == 5 and T.freight_kits == 3 and r1 ~= nil and (r1.delivered["iron-plate"] or 0) > 0,
    "%d carriages, %d cargo wagon kits used, delivered %s", T.freight_cars or 0, T.freight_kits or 0,
    r1 and serpent.line(r1.delivered) or "-")
  local r2 = rails.train_record(T.mixed)
  local out = 0
  local dp = rails.depot(T.D).entity.position
  for _, u in ipairs(surface().find_entities_filtered({position = dp, radius = 60, name = "rts-walker", force = F})) do
    if u.valid then out = out + 1 end
  end
  check(T, "mixed", r2 ~= nil and r2.kind == "cargo" and r2.caps and r2.caps.cargo == 1 and r2.caps.troop == 1
    and (r2.delivered["copper-plate"] or 0) > 0 and out == 8, "kind %s caps %s, delivered %s, %d walkers at D",
    tostring(r2 and r2.kind), r2 and serpent.line(r2.caps) or "-", r2 and serpent.line(r2.delivered) or "-", out)
  check(T, "siege", not (T.turret and T.turret.valid) and rec3 ~= nil and (rec3.shots or 0) > 0
    and trainswar.stance(T.siege) == "none" and T.bombard_at ~= nil,
    "turret %s, %s shots, stance %s, at the bombard stop from tick %s", (T.turret and T.turret.valid) and "alive" or
    "destroyed", tostring(rec3 and rec3.shots), trainswar.stance(T.siege), tostring(T.bombard_at))
  util.log("r3 builder summary %d/%d", T.pass, T.pass + T.fail)
end)
