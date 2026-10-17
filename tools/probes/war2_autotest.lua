-- Phase 5 M3 war2 autotest (test copy only, tools/autotest-run.sh EXTRA_LUA; docs/PHASE5-M3.md section 4 "Fronts /
-- belts / trains"; docs/qa/phase5-war2-notes.md). Runs beside a 1v1 Nation AI match:
--   fronts  in the map corner farthest from the spawns: two tier-3 cities of each nation 160 tiles apart (rts-player
--           = A, rts-ai-1 = B 100 tiles further from the corner: one straight border of about 320 tiles), a war
--           A -> B: each side gets >= 2 segments with threat values. rts-player's AI commander is stopped first (an
--           AI army pools every own unit, the hold_line division too: docs/qa/phase5-war2-notes.md)
--   hold    24 walkers of A form a division 40 tiles behind A's segment whose chord is nearest 160 tiles;
--           divisions.order(id, "hold_line", segment): within 20 s every member stands at its slot (<= 3 tiles) and
--           the members cover >= 85 % of the chord
--   belt    A researches Fortification; a 200-tile belt crossing a straight rail of A: planned, built within 3
--           minutes, two gates on the rail tiles, the city networks lose exactly the built pieces (+ magazines),
--           turrets carry the priority list; a point outside own land is refused
--   arty    on a lab surface (rts-ai-2 attacks rts-ai-3, cease fire off): an artillery train deployed from kits at a
--           depot, an enemy turret 100 tiles away, stance bombard: the turret dies within 60 s and the wagon spent
--           what was fired; the train disbanded at its depot returns its shells
--   armour  plain and armoured locomotive / troop wagon: the armoured one survives 3x the physical damage that
--           destroyed the plain one; an armoured troop train deploys from armoured kits and its wagons carry troops
--   strike  (m3-air's divdiag_depot) 8 walkers of rts-ai-2 as a division attack an rts-ai-3 rail depot: it is destroyed
--           within 45 s (before the fix the group stood 18 tiles away in attacking_target, firing at the depot's immune
--           hidden pole and power entity)
-- Log lines "[rts] war2 autotest check <name>: PASS|FAIL ..." and "[rts] war2 autotest summary <pass>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local rails = require("scripts.rails")
local wars = require("scripts.wars")
local diplomacy = require("scripts.diplomacy")
local fronts = require("scripts.fronts")
local belts = require("scripts.belts")
local trainswar = require("scripts.trainswar")
local garrison = require("scripts.garrison")
local buildings = require("scripts.buildings")
local ai_init = require("scripts.ai.init")
local ages = require("scripts.ages")
local research = require("scripts.research")

local A, B = "rts-player", "rts-ai-1"
local ATT, DEF = "rts-ai-2", "rts-ai-3"
local LAB = "war2-test"
local START = 300
local TIMEOUT = 12 * 60 * 60
local D = defines.direction

local T -- storage.war2_at

local function check(name, ok, fmt, ...)
  T.checks[#T.checks + 1] = {name = name, ok = ok}
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("war2 autotest check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function lab()
  local s = game.surfaces[LAB]
  if s then return s end
  s = game.create_surface(LAB, {width = 4000, height = 1000, peaceful_mode = true, no_enemies_mode = true})
  s.always_day = true
  for cx = 30, 56 do for cy = -3, 12 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = 980, 1780 do for y = -80, 400 do tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}} end end
  s.set_tiles(tiles, true, false, false, false)
  for _, e in ipairs(s.find_entities_filtered({area = {{960, -100}, {1800, 420}}})) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  return s
end

local function spawn_n(surface, name, n, force, at, cols)
  local list = {}
  cols = cols or 6
  for k = 1, n do
    local e = units.spawn(name, {x = at.x + ((k - 1) % cols) * 3, y = at.y + math.floor((k - 1) / cols) * 3}, force,
      nil, surface)
    if e then list[#list + 1] = e end
  end
  return list
end

local function flatten(surface, area)
  local tiles = {}
  for x = area[1][1], area[2][1] - 1 do
    for y = area[1][2], area[2][2] - 1 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, true, true, false)
  for _, e in ipairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "resource",
                                                                          "fish", "corpse"}})) do
    if e.valid then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
end

-- The map corner farthest from every spawn, and the unit directions towards the map centre.
local function corner()
  local half = (storage.world and storage.world.size or 2048) / 2
  local spawns = storage.match.spawns or {}
  local best, bd
  local r = half - 240
  for _, c in ipairs({{r, r}, {-r, r}, {r, -r}, {-r, -r}}) do
    local md
    for _, p in pairs(spawns) do
      local d = util.distance(p, {x = c[1], y = c[2]})
      if not md or d < md then md = d end
    end
    md = md or 0
    if not bd or md > bd then best, bd = {x = c[1], y = c[2]}, md end
  end
  return best, best.x > 0 and -1 or 1, best.y > 0 and -1 or 1, bd
end

---------------------------------------------------------------------------
-- Fronts and hold_line
---------------------------------------------------------------------------
local function fronts_setup()
  local F = T.fr
  local surface = game.surfaces[storage.match.surface]
  local O, dx, dy, md = corner()
  F.O, F.dx, F.dy = O, dx, dy
  local function at(u, v) return {x = O.x + u * dx, y = O.y + v * dy} end
  F.at = {A1 = at(0, 0), A2 = at(160, 0), B1 = at(0, 100), B2 = at(160, 100)}
  local x0, x1 = math.min(O.x - 140 * dx, O.x + 300 * dx), math.max(O.x - 140 * dx, O.x + 300 * dx)
  local y0, y1 = math.min(O.y - 130 * dy, O.y + 310 * dy), math.max(O.y - 130 * dy, O.y + 310 * dy)
  for cx = math.floor(x0 / 32), math.floor(x1 / 32) do
    for cy = math.floor(y0 / 32), math.floor(y1 / 32) do surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end
  end
  surface.force_generate_chunk_requests()
  flatten(surface, {{x0, y0}, {x1, y1}})
  util.log("war2 autotest: front rig at %s (nearest spawn %.0f tiles), towards the centre %d, %d", util.pos_str(O), md,
    dx, dy)
  if ai_init.stop_force then ai_init.stop_force(A) end
  F.cities = {}
  for _, k in ipairs({"A1", "A2", "B1", "B2"}) do
    local id = cities.found(k:sub(1, 1) == "A" and A or B, F.at[k], {why = "(war2 autotest)"})
    F.cities[k] = id
    local c = id and cities.get(id)
    if c then cities.set_tier(c, 3, "war2 autotest") end
  end
  territory.flush()
  local st = diplomacy.state(A, B)
  if st ~= "war" then
    F.war = wars.declare(A, B, {kind = "border"})
  else
    local W = wars.between(A, B)
    F.war = W and W.id
  end
  fronts.flush()
  local na, nb = #fronts.segments(A), #fronts.segments(B)
  local function all_threat(f)
    local n = 0
    for _, seg in ipairs(fronts.segments(f)) do
      if type(seg.threat) == "number" and seg.threat > 0 then n = n + 1 end
    end
    return n
  end
  check("fronts_setup", F.cities.A1 and F.cities.A2 and F.cities.B1 and F.cities.B2 and F.war ~= nil,
    "cities A %s %s, B %s %s, war #%s (%s before)", tostring(F.cities.A1), tostring(F.cities.A2), tostring(F.cities.B1),
    tostring(F.cities.B2), tostring(F.war), st)
  check("fronts_segments", na >= 2 and nb >= 2 and all_threat(A) == na and all_threat(B) == nb,
    "%s; %s", fronts.describe(A), fronts.describe(B))
  local chords = {}
  for _, seg in ipairs(fronts.segments(A)) do
    chords[#chords + 1] = string.format("#%d len %.0f chord %.0f str %d val %.0f", seg.id, seg.length, seg.chord,
      seg.strength, seg.value)
  end
  util.log("war2 autotest: A segments %s", table.concat(chords, "; "))
end

local function hold_setup()
  local F = T.fr
  local best, bd
  for _, seg in ipairs(fronts.segments(A)) do
    local d = math.abs(seg.chord - 160)
    if not bd or d < bd then best, bd = seg, d end
  end
  if not best then
    check("hold_line_setup", false, "no segment of %s", A)
    F.phase = "done"
    return
  end
  local surface = game.surfaces[storage.match.surface]
  local at = {x = best.mid.x + best.back.x * 40, y = best.mid.y + best.back.y * 40}
  local list = spawn_n(surface, "rts-walker", 24, A, {x = at.x - 7, y = at.y - 5}, 6)
  F.div = divisions.create(A, list, {name = "Line Guard", stance = "advance"}, {owner = "ai"})
  F.seg = best.id
  local ok = divisions.order(F.div, "hold_line", best.id)
  F.t0 = game.tick
  check("hold_line_order", ok == true and #list == 24, "division #%s of %d walkers at %s, segment %d chord %.0f tiles, "
    .. "order %s", tostring(F.div), #list, util.pos_str(at), best.id, best.chord, tostring(ok))
  F.phase = "hold_wait"
end

local function hold_tick()
  local F = T.fr
  local D_ = divisions.get(F.div)
  local L = storage.fronts and storage.fronts.lines[F.div]
  local elapsed = (game.tick - F.t0) / 60
  local done = false
  local worst, n = 0, 0
  if D_ and L and L.slots then
    for _, rec in ipairs(divisions.live_members(D_)) do
      local slot = L.slots[rec.entity.unit_number]
      if slot then
        worst = math.max(worst, util.distance(rec.entity.position, slot))
        n = n + 1
      end
    end
    done = (D_.state == "holding" or D_.state == "idle") and n == 24 and worst <= 3
  end
  if done or elapsed > 25 then
    -- the arrival: divisions.lua stamps order.done when the last member reached its slot
    if done and D_.order and D_.order.done then elapsed = (D_.order.done - F.t0) / 60 end
    local seg = fronts.segment(A, F.seg)
    local lo, hi = math.huge, -math.huge
    if D_ and seg then
      local ux, uy = seg.b.x - seg.a.x, seg.b.y - seg.a.y
      local len = math.sqrt(ux * ux + uy * uy)
      ux, uy = ux / len, uy / len
      for _, rec in ipairs(divisions.live_members(D_)) do
        local p = rec.entity.position
        local t = (p.x - seg.a.x) * ux + (p.y - seg.a.y) * uy
        lo, hi = math.min(lo, t), math.max(hi, t)
      end
    end
    local cover = seg and (hi - lo) / seg.chord or 0
    check("hold_line_spread", done and elapsed <= 20 and cover >= 0.85,
      "after %.1f s: state %s, %d members, worst %.1f tiles from its slot, cover %.0f %% of the %.0f-tile chord, stance %s, "
      .. "card order %s", elapsed, D_ and D_.state or "-", n, worst, cover * 100, seg and seg.chord or 0,
      D_ and D_.stance or "-", D_ and D_.order and D_.order.kind or "-")
    check("hold_line_holder", seg ~= nil and seg.holder == F.div, "segment %d holder %s", F.seg,
      tostring(seg and seg.holder))
    F.phase = "done"
  end
end

---------------------------------------------------------------------------
-- Belt
---------------------------------------------------------------------------
local ITEMS = {"rts-wall", "rts-gate", "rts-turret", "rts-field-depot", "firearm-magazine"}

-- The rig cities' networks (the capital's economy moves magazines on its own).
local function nets_of(force_name)
  local out = {}
  for _, id in ipairs({T.fr.cities.A1, T.fr.cities.A2}) do
    local c = cities.get(id)
    local brec = c and c.center and buildings.get(c.center)
    local net = brec and brec.entity.logistic_network
    if net and net.valid then out[#out + 1] = net end
  end
  return out
end

local function counts(force_name)
  local t = {}
  for _, item in ipairs(ITEMS) do t[item] = 0 end
  local seen = {}
  for _, net in ipairs(nets_of(force_name)) do
    if not seen[net.network_id] then
      seen[net.network_id] = true
      for _, item in ipairs(ITEMS) do t[item] = t[item] + net.get_item_count(item) end
    end
  end
  return t
end

local function belt_setup()
  local Bt = T.belt
  local F = T.fr
  local surface = game.surfaces[storage.match.surface]
  local O, dx, dy = F.O, F.dx, F.dy
  game.forces[A].technologies["rts-fortification"].researched = true
  -- refused: a point outside own land
  local far = {x = O.x + 80 * dx, y = O.y + 150 * dy}
  local id0, why0 = belts.plan(A, {{x = O.x, y = O.y + 20 * dy}, far})
  check("belt_refuses_foreign", id0 == nil and why0 == "not-own", "a point on %s's land: plan %s (%s)", B,
    tostring(id0), tostring(why0))
  -- stock A1's network
  local c1 = cities.get(F.cities.A1)
  local net = c1 and buildings.get(c1.center).entity.logistic_network
  if net then
    for item, n in pairs({["rts-wall"] = 300, ["rts-gate"] = 10, ["rts-turret"] = 30, ["rts-field-depot"] = 2,
                          ["firearm-magazine"] = 500}) do net.insert({name = item, count = n}) end
  end
  -- a straight rail of A across the line (vertical in the rig's frame: along y)
  local rx = O.x + 60 * dx
  local by = O.y + 20 * dy
  Bt.rails = 0
  for v = -20, 20, 2 do
    if surface.create_entity({name = "straight-rail", position = {rx, by + v}, direction = D.north, force = A}) then
      Bt.rails = Bt.rails + 1
    end
  end
  Bt.before = counts(A)
  local p1, p2 = {x = O.x - 20 * dx, y = by}, {x = O.x + 180 * dx, y = by}
  Bt.points = {p1, p2}
  local id, why = belts.plan(A, {p1, p2})
  Bt.id = id
  local P_ = id and belts.get(id)
  local kinds = {}
  for _, e in ipairs(P_ and P_.entries or {}) do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
  check("belt_planned", P_ ~= nil and (kinds.gate or 0) >= 2 and (kinds.turret or 0) >= 15 and (kinds.depot or 0) == 1,
    "plan %s (%s): %.0f tiles, walls %d, gates %d, turrets %d, aa %d, depot %d, %d skipped; %d rails laid at x=%.1f",
    tostring(id), tostring(why), P_ and P_.length or 0, kinds.wall or 0, kinds.gate or 0, kinds.turret or 0,
    kinds.aa or 0, kinds.depot or 0, P_ and P_.skipped or 0, Bt.rails, rx)
  Bt.t0 = game.tick
  Bt.phase = id and "wait" or "done"
end

local function belt_tick()
  local Bt = T.belt
  local P_ = belts.get(Bt.id)
  local elapsed = (game.tick - Bt.t0) / 60
  if not (P_ and (P_.state == "built" or elapsed > 200)) then return end
  local surface = game.surfaces[storage.match.surface]
  local built = {}
  local gates_on_rail, prio, turrets = 0, 0, 0
  for _, e in ipairs(P_.entries) do
    if e.status == "built" then
      built[e.item] = (built[e.item] or 0) + 1
      if e.kind == "gate" then
        local g = surface.find_entity("rts-gate", {e.x, e.y})
        local r = surface.find_entities_filtered({area = {{e.x - 0.4, e.y - 0.4}, {e.x + 0.4, e.y + 0.4}},
                                                  type = "straight-rail"})
        if g and #r > 0 then gates_on_rail = gates_on_rail + 1 end
      elseif e.kind == "turret" and e.entity and e.entity.valid then
        turrets = turrets + 1
        if e.entity.get_priority_target(1) then prio = prio + 1 end
      end
    end
  end
  local after = counts(A)
  local parts, exact = {}, true
  for _, item in ipairs(ITEMS) do
    local lost = Bt.before[item] - after[item]
    local want = item == "firearm-magazine" and (P_.debited[item] or 0) or (built[item] or 0)
    if lost ~= want then exact = false end
    parts[#parts + 1] = string.format("%s -%d (built/debited %d)", item, lost, want)
  end
  local done_s = P_.done and (P_.done - P_.created) / 60 or elapsed
  check("belt_built", P_.state == "built" and done_s <= 180, "plan %d %s in %.1f s: %d built, %d skipped of %d",
    P_.id, P_.state, done_s, P_.built, P_.skipped, #P_.entries)
  check("belt_gates_on_rail", gates_on_rail >= 2, "%d gates stand on rail tiles", gates_on_rail)
  check("belt_debit", exact, "%s", table.concat(parts, ", "))
  check("belt_priorities", turrets > 0 and prio == turrets, "%d of %d belt turrets have a priority list", prio, turrets)
  -- the war council's helper: a belt along a front segment
  local seg = fronts.segments(A)[2] or fronts.segments(A)[1]
  local fid, fwhy = seg and belts.plan_front(A, seg.id)
  local FP = fid and belts.get(fid)
  check("belt_plan_front", FP ~= nil and #FP.entries > 0, "segment %s: plan %s (%s), %d entries, %.0f tiles",
    tostring(seg and seg.id), tostring(fid), tostring(fwhy), FP and #FP.entries or 0, FP and FP.length or 0)
  -- AA turrets (m3-air's rts-aa-turret): none in Age I, one every 36 tiles in Age II with Aviation
  local function aa_count()
    local L = belts.layout(A, Bt.points)
    local n = 0
    for _, e in ipairs(L and L.entries or {}) do if e.kind == "aa" then n = n + 1 end end
    return n
  end
  local before = aa_count()
  if prototypes.entity["rts-aa-turret"] then
    storage.ages = storage.ages or {}
    storage.ages[A] = storage.ages[A] or {age = 1}
    storage.ages[A].age = 2
    if storage.nations and storage.nations[A] then storage.nations[A].age = 2 end
    local tech = game.forces[A].technologies["rts-aviation"]
    if tech then tech.researched = true end
    research.apply(game.forces[A])
  end
  local after = aa_count()
  check("belt_aa_turrets", before == 0 and (after >= 4 or not prototypes.entity["rts-aa-turret"]),
    "AA turrets in the 200-tile layout: Age I %d, Age II with Aviation %d (prototype %s)", before, after,
    tostring(prototypes.entity["rts-aa-turret"] ~= nil))
  Bt.phase = "done"
end

---------------------------------------------------------------------------
-- Artillery train and armour (lab surface)
---------------------------------------------------------------------------
local TY = 0

local function arty_setup()
  local Ar = T.arty
  local s = lab()
  for _, f in ipairs({ATT, DEF}) do if not game.forces[f] then game.create_force(f) end end
  game.forces[ATT].set_cease_fire(DEF, false)
  game.forces[DEF].set_cease_fire(ATT, false)
  local dep = s.create_entity({name = "rts-depot", position = {1100, TY}, force = ATT, raise_built = true})
  local d = dep and rails.depot(dep.unit_number)
  local net = d and logistics.hub_network(dep.unit_number)
  if not (d and d.platform and net) then
    check("arty_setup", false, "depot %s platform %s net %s", tostring(dep), tostring(d and d.platform), tostring(net))
    Ar.phase = "done"
    return
  end
  for item, n in pairs({coal = 200, ["rts-locomotive-kit"] = 2, ["rts-artillery-wagon-kit"] = 1,
                        ["rts-rail-shell"] = 40}) do net.insert({name = item, count = n}) end
  Ar.depot = dep.unit_number
  local train, why = trainswar.deploy(dep.unit_number, "artillery", false)
  local wagon = train and trainswar.arty_wagons(train)[1]
  if not wagon then
    check("arty_setup", false, "train %s (%s)", tostring(train and train.id), tostring(why))
    Ar.phase = "done"
    return
  end
  Ar.train = train.id
  Ar.shells0 = trainswar.shells(train) + net.get_item_count("rts-rail-shell") -- it rearms at its depot
  local tp = {x = math.floor(wagon.position.x) + 0.0, y = math.floor(wagon.position.y + 100)}
  Ar.turret = s.create_entity({name = "rts-turret", position = tp, force = DEF, raise_built = true})
  -- a spotter: an own walker 35 tiles short of the turret (outside its 21-tile range); without one the train holds fire
  Ar.spotted_before = #trainswar.targets(train.id)
  Ar.spotter = units.spawn("rts-walker", {x = tp.x, y = tp.y - 35}, ATT, nil, s)
  local dist = Ar.turret and util.distance(wagon, Ar.turret) or 0
  check("arty_setup", Ar.turret ~= nil and Ar.shells0 >= 20 and #train.carriages == 3,
    "artillery train %d (%d carriages) at depot #%d with %d shells, enemy turret %.0f tiles away", train.id,
    #train.carriages, dep.unit_number, Ar.shells0, dist)
  check("arty_needs_spotter", Ar.spotted_before == 0 and #trainswar.targets(train.id) >= 1,
    "targets without a spotter %d, with a walker 35 tiles from the turret %d", Ar.spotted_before,
    #trainswar.targets(train.id))
  local ok = trainswar.set_stance(train.id, "bombard")
  Ar.t0 = game.tick
  Ar.phase = ok and "wait" or "done"
  if not ok then check("arty_stance", false, "set_stance refused") end
end

local function arty_tick()
  local Ar = T.arty
  local elapsed = (game.tick - Ar.t0) / 60
  local dead = not (Ar.turret and Ar.turret.valid)
  if not dead and elapsed <= 62 then return end
  local rec = rails.train_record(Ar.train)
  local train = rec and rails.train_of(rec)
  local net0 = logistics.hub_network(Ar.depot)
  local aboard = train and trainswar.shells(train) or 0
  local shells = aboard + (net0 and net0.get_item_count("rts-rail-shell") or 0)
  local shots = rec and rec.shots or 0
  check("arty_destroys_turret", dead and elapsed <= 60, "turret %s after %.1f s, %d shots", dead and "destroyed" or
    "alive", elapsed, shots)
  check("arty_spends_shells", shots > 0 and Ar.shells0 - shells == shots, "shells (wagon + depot) %d -> %d, %d fired",
    Ar.shells0, shells, shots)
  -- disband at the depot: the shells go back
  local net = logistics.hub_network(Ar.depot)
  local n0 = net and net.get_item_count("rts-rail-shell") or 0
  local res, why = nil, "no-train"
  if train then res, why = rails.disband_train(train) end
  local n1 = net and net.get_item_count("rts-rail-shell") or 0
  check("arty_disband_shells", res ~= nil and n1 - n0 == aboard, "disband %s (%s): %d shells back to the depot (%d aboard)",
    tostring(res ~= nil), tostring(why), n1 - n0, aboard)
  Ar.phase = "done"
end

local function armour_test()
  local s = lab()
  local out = {}
  for i, pr in ipairs({{"rts-locomotive", "rts-armoured-locomotive"}, {"rts-troop-wagon", "rts-armoured-wagon"}}) do
    local y = 200 + i * 20
    for x = 1200, 1240, 2 do s.create_entity({name = "straight-rail", position = {x + 1, y}, direction = D.east,
                                               force = ATT}) end
    for x = 1300, 1340, 2 do s.create_entity({name = "straight-rail", position = {x + 1, y}, direction = D.east,
                                               force = ATT}) end
    local plain = s.create_entity({name = pr[1], position = {1220, y}, direction = D.east, force = ATT})
    local arm = s.create_entity({name = pr[2], position = {1320, y}, direction = D.east, force = ATT})
    local dealt = 0
    while plain and plain.valid and dealt < 100000 do
      plain.damage(50, DEF, "physical")
      dealt = dealt + 50
    end
    local dealt2 = 0
    while arm and arm.valid and dealt2 < 3 * dealt do
      arm.damage(50, DEF, "physical")
      dealt2 = dealt2 + 50
    end
    local alive = arm and arm.valid
    out[#out + 1] = {pr = pr, dealt = dealt, alive = alive, health = alive and arm.health or 0,
                     max = alive and arm.max_health or 0}
  end
  for _, o in ipairs(out) do
    check("armour_" .. o.pr[2], o.alive == true, "%s died after %d physical; %s took %d and is %s (%.0f / %.0f)", o.pr[1],
      o.dealt, o.pr[2], 3 * o.dealt, o.alive and "alive" or "destroyed", o.health, o.max)
  end
  -- an armoured troop train from armoured kits
  local dep = s.create_entity({name = "rts-depot", position = {1500, TY}, force = ATT, raise_built = true})
  local net = dep and logistics.hub_network(dep.unit_number)
  if net then
    for item, n in pairs({coal = 100, ["rts-armoured-locomotive-kit"] = 2, ["rts-armoured-wagon-kit"] = 2}) do
      net.insert({name = item, count = n})
    end
  end
  local train, why = dep and rails.create_train(dep.unit_number, "troop", {armoured = true})
  local names = {}
  for _, c in ipairs(train and train.carriages or {}) do names[#names + 1] = c.name end
  local rec = train and rails.train_record(train)
  check("armoured_troop_train", rec ~= nil and rec.armoured == true and names[1] == "rts-armoured-locomotive"
    and names[2] == "rts-armoured-wagon" and garrison.TWAGONS["rts-armoured-wagon"] == true,
    "train %s (%s): [%s], record armoured %s, troop wagon set %s", tostring(train and train.id), tostring(why),
    table.concat(names, " "), tostring(rec and rec.armoured), tostring(garrison.TWAGONS["rts-armoured-wagon"]))
end

local function strike_setup()
  local St = T.strike
  local s = lab()
  St.depot = s.create_entity({name = "rts-depot", position = {1650, 330}, force = DEF, raise_built = true})
  local list = {}
  for i = 1, 8 do
    local e = units.spawn("rts-walker", {x = 1610 + math.floor((i - 1) / 4) * 3, y = 330 + ((i - 1) % 4 - 1.5) * 3},
      ATT, nil, s)
    if e then list[#list + 1] = e end
  end
  St.div = divisions.create(ATT, list, {name = "Depot Raid"}, {owner = "ai"})
  St.t0 = game.tick
  St.phase = "order"
end

local function strike_tick()
  local St = T.strike
  if St.phase == "order" then
    -- one pass later: the depot's composite is built and its hidden parts hardened
    if game.tick - St.t0 < 30 then return end
    St.ok = divisions.order(St.div, "attack", St.depot)
    St.t0 = game.tick
    St.phase = "wait"
    return
  end
  local elapsed = (game.tick - St.t0) / 60
  local dead = not (St.depot and St.depot.valid)
  if not dead and elapsed <= 45 then return end
  local st = divisions.stats()
  check("division_strikes_depot", St.ok and dead and elapsed <= 45, "order %s; depot %s after %.1f s; strikes %d",
    tostring(St.ok), dead and "destroyed" or string.format("alive (%.0f HP)", St.depot.health), elapsed, st.strikes or 0)
  St.phase = "done"
end

---------------------------------------------------------------------------
-- Driver
---------------------------------------------------------------------------
events.on_nth_tick(1, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  if not storage.war2_at then
    if game.tick - m.tick_started < START then return end
    storage.war2_at = {pass = 0, fail = 0, checks = {}, started = game.tick, fr = {phase = "setup"},
                       belt = {phase = "wait"}, arty = {phase = "setup"}, armour = {phase = "setup"},
                       strike = {phase = "setup"}}
    T = storage.war2_at
    util.log("war2 autotest: started at tick %d (mode %s)", game.tick, tostring(m.config.mode))
  end
  T = storage.war2_at
  if T.done then return end
  local F = T.fr
  if F.phase == "setup" then
    fronts_setup()
    F.phase = "hold_setup"
    T.belt.phase = "setup"
  elseif F.phase == "hold_setup" then
    hold_setup()
  elseif F.phase == "hold_wait" and game.tick % 30 == 0 then
    hold_tick()
  end
  if T.belt.phase == "setup" and F.phase ~= "setup" then
    belt_setup()
  elseif T.belt.phase == "wait" and game.tick % 60 == 0 and T.belt.id then
    belt_tick()
  end
  if T.arty.phase == "setup" then
    arty_setup()
  elseif T.arty.phase == "wait" and game.tick % 30 == 0 then
    arty_tick()
  end
  if T.armour.phase == "setup" then
    armour_test()
    T.armour.phase = "done"
  end
  if T.strike.phase == "setup" and T.arty.phase ~= "setup" then
    strike_setup()
  elseif T.strike.phase ~= "setup" and T.strike.phase ~= "done" and game.tick % 30 == 0 then
    strike_tick()
  end
  local all = F.phase == "done" and T.belt.phase == "done" and T.arty.phase == "done" and T.armour.phase == "done"
    and T.strike.phase == "done"
  if all or game.tick - T.started > TIMEOUT then
    T.done = true
    util.log("war2 autotest: %s; %s; %s; %s", fronts.describe(A), fronts.describe(B), belts.describe(A),
      trainswar.describe(ATT))
    util.log("war2 autotest summary %d/%d (%s)", T.pass, T.pass + T.fail, T.fail == 0 and "all passed" or "FAILED")
  end
end)

events.on_load(function() T = storage.war2_at end)
