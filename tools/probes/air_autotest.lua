-- Phase 5 M3 air autotest (test copy only, tools/autotest-run.sh EXTRA_LUA; docs/PHASE5-M3.md section 4 "Air";
-- docs/qa/phase5-air-notes.md). Runs beside a Nation-mode AI match, on its land in the corner farthest from the spawns,
-- with the non-participating forces rts-ai-3 (HOME: a city with an airfield and a barracks) and rts-ai-2 (FOE: no
-- airfield). One step after the other:
--   age_gate         Aviation needs Age II, Air Force Age III (research.status "age"), a bomber is locked at Age II
--   airfield_gate    a scout kit waits in the barracks with the block "airfield" until the city has an airfield, then
--                    the plane appears at the airfield; a second airfield in the city is refused (one per city)
--   scout_crossing   a division of 3 scouts flies over a 30-tile lake and a wall line to a point 150 tiles out
--   mixed_division   2 scouts and 4 walkers in one division: the planes fly outside the unit group, all arrive
--   return_rearm     an interceptor at supply 21 far from the airfield returns, rearms to 100 and is let go
--   crash            a plane of FOE (no airfield) at supply 3 crashes: dead, state "crashed", alerts
--   aa_turret        an AA turret kills a hovering bomber, a gun turret beside it never fires at it (but at a drone);
--                    an empty AA turret in a network with magazines is fed
--   patrol           a division of 3 interceptors patrols a circle: state "patrolling", waypoints, radius, and as an
--                    all-plane division it keeps its war supply points
--   bomber_vs_walker 2 bombers (cost 128) and 11 walkers (cost 132) each attack a FOE rail depot 40 tiles away: the
--                    bombers destroy theirs at least twice as fast, from the first hit and from the order
--   fog_scout        fog.lua charts more chunks around a scout than around a walker at the same place
--   perf_step        60 planes (20 per kind) on patrol: 20 supply steps profiled (tools/probes/air_perf.lua is the
--                    full fixture: PERF=1 and --benchmark saves)
-- Log lines "[rts] air autotest check <name>: PASS|FAIL ..." and "[rts] air autotest summary <pass>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local divisions = require("scripts.divisions")
local orders = require("scripts.orders")
local production = require("scripts.production")
local research = require("scripts.research")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local fog = require("scripts.fog")
local air = require("scripts.air")
local airgui = require("scripts.airgui")
local selection = require("scripts.selection")
local balance = require("balance")

local HOME, FOE = "rts-ai-3", "rts-ai-2"
local START = 300            -- ticks after the match start
local A = balance.nation.air

local T -- storage.air_at

local function check(name, ok, fmt, ...)
  T.checks[#T.checks + 1] = {name = name, ok = ok}
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("air autotest check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function surface() return game.surfaces[storage.match.surface] end
local function at(dx, dy) return {x = T.c.x + T.dir.x * dx - T.dir.y * dy, y = T.c.y + T.dir.y * dx + T.dir.x * dy} end

local function spawn(name, pos, force)
  local e = units.spawn(name, pos, force, nil, surface())
  return e
end

local function set_age(force, age)
  storage.ages = storage.ages or {}
  storage.ages[force] = storage.ages[force] or {age = 1}
  storage.ages[force].age = age -- the console clamps to ages.MAX_AGE (2 until m3-age3 lands): the test sets it
  if storage.nations and storage.nations[force] then storage.nations[force].age = age end
  research.apply(game.forces[force])
end

local function research_tech(force, name)
  local tech = game.forces[force].technologies[name]
  if tech and not tech.researched then tech.researched = true end
  research.apply(game.forces[force])
end

local function plane_rec(e) return e and e.valid and storage.air and storage.air.planes[e.unit_number] end

---------------------------------------------------------------------------
-- Rig
---------------------------------------------------------------------------
local function test_corner()
  local half = (storage.world and storage.world.size or 2048) / 2
  local spawns = storage.match.spawns or {}
  local best, bd
  local r = half - 230
  for _, c in ipairs({{r, r}, {-r, r}, {r, -r}, {-r, -r}, {0, r}, {0, -r}, {r, 0}, {-r, 0}}) do
    local md
    for _, p in pairs(spawns) do
      local d = util.distance(p, {x = c[1], y = c[2]})
      if not md or d < md then md = d end
    end
    md = md or 0
    if not bd or md > bd then best, bd = {x = c[1], y = c[2]}, md end
  end
  return best, bd
end

local function setup()
  local s = surface()
  local corner, md = test_corner()
  local dx, dy = -corner.x, -corner.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then dx, dy, len = 1, 0, 1 end
  T.dir = {x = dx / len, y = dy / len}
  T.c = {x = math.floor(corner.x), y = math.floor(corner.y)}
  local pts = {at(-60, -60), at(-60, 60), at(240, -90), at(240, 90)}
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(pts) do
    x0, y0, x1, y1 = math.min(x0, p.x), math.min(y0, p.y), math.max(x1, p.x), math.max(y1, p.y)
  end
  x0, y0, x1, y1 = math.floor(x0), math.floor(y0), math.ceil(x1), math.ceil(y1)
  for cx = math.floor(x0 / 32), math.floor(x1 / 32) do
    for cy = math.floor(y0 / 32), math.floor(y1 / 32) do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end
  end
  s.force_generate_chunk_requests()
  -- flat land; a 30-tile lake band 60-90 tiles out, a wall line 115 tiles out, both 120 tiles wide across the axis
  local tiles = {}
  for x = x0, x1 - 1 do
    for y = y0, y1 - 1 do
      local rx, ry = x + 0.5 - T.c.x, y + 0.5 - T.c.y
      local along = rx * T.dir.x + ry * T.dir.y
      local across = -rx * T.dir.y + ry * T.dir.x
      local water = along >= 60 and along < 90 and math.abs(across) < 60
      tiles[#tiles + 1] = {name = water and "water" or "grass-1", position = {x, y}}
    end
  end
  s.set_tiles(tiles, true, true, true, false)
  for _, e in ipairs(s.find_entities_filtered({area = {{x0, y0}, {x1, y1}}})) do
    if e.valid and e.type ~= "character" and not (e.force and e.force.name ~= "neutral") then
      e.destroy({do_cliff_correction = e.type == "cliff"})
    end
  end
  for k = -60, 60 do
    local p = at(115, k)
    s.create_entity({name = "rts-wall", position = {math.floor(p.x) + 0.5, math.floor(p.y) + 0.5}, force = FOE})
  end
  T.city = cities.found(HOME, T.c, {why = "(air autotest)"})
  territory.flush()
  storage.population = storage.population or {}
  if T.city then
    if storage.population[T.city] then storage.population[T.city].pop = 200 else storage.population[T.city] = {pop = 200} end
  end
  local bpos = s.find_non_colliding_position("rts-barracks", at(0, -22), 8, 1, true)
  T.barracks = bpos and s.create_entity({name = "rts-barracks", position = bpos, force = HOME, raise_built = true})
  util.log("air autotest: rig at %s (nearest spawn %.0f tiles), axis (%.2f, %.2f), city %s, barracks %s", util.pos_str(T.c),
    md, T.dir.x, T.dir.y, tostring(T.city), T.barracks and util.pos_str(T.barracks.position) or "-")
  return T.city ~= nil and T.barracks ~= nil
end

---------------------------------------------------------------------------
-- Steps: {name, start(S) -> nil | false (skip), tick(S) -> true when done, timeout ticks}
---------------------------------------------------------------------------
local STEPS = {}
local function step(name, timeout, start, tick) STEPS[#STEPS + 1] = {name = name, timeout = timeout, start = start, tick = tick} end

step("age_gate", 120, function(S)
  set_age(HOME, 2)
  local av2, af2 = research.status(HOME, "rts-aviation"), research.status(HOME, "rts-air-force")
  local bomber2 = research.is_unlocked(HOME, "rts-bomber")
  research_tech(HOME, "rts-aviation")
  local af2b = research.status(HOME, "rts-air-force")
  set_age(HOME, 3)
  local af3 = research.status(HOME, "rts-air-force")
  research_tech(HOME, "rts-air-force")
  local bomber3 = research.is_unlocked(HOME, "rts-bomber")
  local recipe = game.forces[HOME].recipes["rts-bomber-kit"].enabled
  local scout_recipe = game.forces[HOME].recipes["rts-scout-plane-kit"].enabled
  local skirmish_hidden = research.NATION_ONLY["rts-aviation"] == true and research.NATION_ONLY["rts-air-force"] == true
  check("age_gate", av2 == "available" and af2 == "age" and af2b == "age" and not bomber2 and af3 == "available"
    and bomber3 and recipe and scout_recipe and skirmish_hidden,
    "Age II: aviation %s, air force %s (after aviation %s), bomber unlocked %s; Age III: air force %s, after it bomber %s, "
    .. "kit recipes bomber %s scout %s; Nation-only %s", av2, af2, af2b, tostring(bomber2), af3, tostring(bomber3),
    tostring(recipe), tostring(scout_recipe), tostring(skirmish_hidden))
  return true
end, function() return true end)

step("airfield_gate", 20 * 60, function(S)
  production.set_recipe(T.barracks, "rts-scout-plane-kit") -- a machine without a recipe has no output slot
  local out = T.barracks.get_output_inventory()
  out.insert({name = "rts-scout-plane-kit", count = 1})
  S.t0 = game.tick
  S.phase = "wait_block"
end, function(S)
  local brec = buildings.get(T.barracks.unit_number)
  if S.phase == "wait_block" then
    if game.tick - S.t0 < 180 then return false end
    local out = T.barracks.get_output_inventory()
    S.held = out.get_item_count("rts-scout-plane-kit")
    S.block = brec and brec.research_block and brec.research_block.reason
    local s = surface()
    local fpos = s.find_non_colliding_position("rts-airfield", at(0, 30), 10, 1, true)
    local ok1, why1 = air.can_build_airfield(HOME, fpos)
    T.field = s.create_entity({name = "rts-airfield", position = fpos, force = HOME, raise_built = true})
    local ok2, why2 = air.can_build_airfield(HOME, at(-25, 30))
    local ok3, why3 = air.can_build_airfield(HOME, at(200, 0))
    S.build = {ok1, why1, ok2, why2, ok3, why3}
    S.phase = "wait_plane"
    S.t1 = game.tick
    return false
  end
  local out = T.barracks.get_output_inventory()
  local left = out.get_item_count("rts-scout-plane-kit")
  local plane
  for _, rec in units.for_force(HOME) do
    if rec.entity.name == "rts-scout-plane" then plane = rec.entity end
  end
  if not plane and game.tick - S.t1 < 600 then return false end
  local d = plane and T.field and util.distance(plane.position, T.field.position) or -1
  local b = S.build
  check("airfield_gate", S.held == 1 and S.block == "airfield" and left == 0 and plane ~= nil and d >= 0 and d <= 8,
    "without an airfield the kit waited (%d in the output, block %s); with one at %s: kits left %d, scout %s %.1f tiles "
    .. "from the airfield after %.1f s", S.held or -1, tostring(S.block), T.field and util.pos_str(T.field.position) or "-",
    left, plane and ("#" .. plane.unit_number) or "none", d, (game.tick - S.t1) / 60)
  check("one_per_city", b[1] == true and b[3] == false and b[4] == "one-per-city" and b[5] == false,
    "first airfield allowed %s (%s); a second in the city %s (%s); outside the city %s (%s)", tostring(b[1]),
    tostring(b[2]), tostring(b[3]), tostring(b[4]), tostring(b[5]), tostring(b[6]))
  if plane then plane.destroy() end
  production.set_recipe(T.barracks, nil)
  return true
end)

step("scout_crossing", 40 * 60, function(S)
  local list = {}
  for i = 1, 3 do list[i] = spawn("rts-scout-plane", at(-5, (i - 2) * 4), HOME) end
  S.id = divisions.create(HOME, list, {name = "Air test 1"})
  S.target = at(150, 0)
  S.ok = divisions.order(S.id, "move", S.target)
  S.t0 = game.tick
  S.planes = list
  S.in_group = 0
end, function(S)
  local D = divisions.get(S.id)
  for _, p in ipairs(S.planes) do
    if p.valid and p.commandable and p.commandable.parent_group then S.in_group = S.in_group + 1 end
  end
  local near = 0
  for _, p in ipairs(S.planes) do
    if p.valid and util.distance(p.position, S.target) <= 8 then near = near + 1 end
  end
  if not (near == 3 and D and D.state == "idle") and game.tick - S.t0 < 30 * 60 then return false end
  check("scout_crossing", S.ok and near == 3 and D ~= nil and D.state == "idle" and S.in_group == 0,
    "3 scouts over the lake (30 tiles) and the wall line to %s: %d within 8 tiles after %.1f s, division %s, in a unit "
    .. "group %d times", util.pos_str(S.target), near, (game.tick - S.t0) / 60, D and D.state or "gone", S.in_group)
  if D then divisions.disband(S.id, "test") end
  for _, p in ipairs(S.planes) do if p.valid then p.destroy() end end
  return true
end)

step("mixed_division", 60 * 60, function(S)
  local list = {}
  for i = 1, 2 do list[#list + 1] = spawn("rts-scout-plane", at(-10, -20 + i * 4), HOME) end
  for i = 1, 4 do list[#list + 1] = spawn("rts-walker", at(-14, -24 + i * 4), HOME) end
  S.list = list
  S.id = divisions.create(HOME, list, {name = "Air test 2"})
  S.target = at(20, -45) -- on this side of the lake
  S.ok = divisions.order(S.id, "move", S.target)
  S.t0 = game.tick
  S.plane_in_group, S.walker_in_group = 0, 0
end, function(S)
  local D = divisions.get(S.id)
  for _, e in ipairs(S.list) do
    if e.valid and e.commandable and e.commandable.parent_group then
      if air.is_plane(e) then S.plane_in_group = S.plane_in_group + 1 else S.walker_in_group = S.walker_in_group + 1 end
    end
  end
  local near = 0
  for _, e in ipairs(S.list) do
    if e.valid and util.distance(e.position, S.target) <= 12 then near = near + 1 end
  end
  if not (near == 6 and D and D.state == "idle") and game.tick - S.t0 < 50 * 60 then return false end
  check("mixed_division", S.ok and near == 6 and D ~= nil and D.state == "idle" and S.plane_in_group == 0
    and S.walker_in_group > 0, "2 scouts + 4 walkers: %d of 6 within 12 tiles of %s after %.1f s, division %s; planes "
    .. "seen in the group %d times, walkers %d times", near, util.pos_str(S.target), (game.tick - S.t0) / 60,
    D and D.state or "gone", S.plane_in_group, S.walker_in_group)
  if D then divisions.disband(S.id, "test") end
  for _, e in ipairs(S.list) do if e.valid then e.destroy() end end
  return true
end)

step("return_rearm", 60 * 60, function(S)
  S.plane = spawn("rts-interceptor", at(160, 30), HOME)
  air.step(0) -- registers it
  local p = plane_rec(S.plane)
  p.supply = A.supply.return_at + 1
  S.t0 = game.tick
  S.seen = {}
end, function(S)
  local p = plane_rec(S.plane)
  if not p then
    check("return_rearm", false, "the plane is gone (state %s)", tostring(S.plane.valid and "alive" or "dead"))
    return true
  end
  if not S.seen[p.state] then
    S.seen[p.state] = game.tick
    util.log("air autotest: return_rearm state %s at %.1f s, supply %.0f, %.0f tiles from the airfield", p.state,
      (game.tick - S.t0) / 60, p.supply, util.distance(S.plane.position, T.field.position))
  end
  local done = S.seen.returning and S.seen.rearming and p.state == "flying" and p.supply >= A.supply.max
  if not done and game.tick - S.t0 < 50 * 60 then return false end
  local rec = storage.units[S.plane.unit_number]
  check("return_rearm", done and rec.order == units.IDLE and util.distance(S.plane.position, T.field.position) <= 12,
    "supply 21 at 160 tiles: returning after %.1f s, rearming after %.1f s, let go after %.1f s with supply %.0f, %.1f "
    .. "tiles from the airfield, order %s", ((S.seen.returning or 0) - S.t0) / 60, ((S.seen.rearming or 0) - S.t0) / 60,
    (game.tick - S.t0) / 60, p.supply, util.distance(S.plane.position, T.field.position), rec.order)
  S.plane.destroy()
  return true
end)

step("crash", 20 * 60, function(S)
  S.plane = spawn("rts-scout-plane", at(200, -40), FOE)
  S.un = S.plane.unit_number
  air.step(0)
  plane_rec(S.plane).supply = 3
  S.alerts0 = #(storage.alerts or {})
  S.t0 = game.tick
end, function(S)
  if S.plane.valid and game.tick - S.t0 < 15 * 60 then return false end
  local crashed, no_field = false, false
  for i = S.alerts0 + 1, #(storage.alerts or {}) do
    local a = storage.alerts[i]
    if a.force == FOE and a.kind == "plane-crashed" then crashed = true end
    if a.force == FOE and a.kind == "plane-no-airfield" then no_field = true end
  end
  check("crash", not S.plane.valid and air.state(S.un) == "crashed" and crashed and no_field,
    "FOE scout (no airfield) at supply 3: dead %s after %.1f s, state %s, alerts crashed %s, no-airfield %s",
    tostring(not S.plane.valid), (game.tick - S.t0) / 60, tostring(air.state(S.un)), tostring(crashed), tostring(no_field))
  return true
end)

step("aa_turret", 40 * 60, function(S)
  local s = surface()
  S.aa = s.create_entity({name = "rts-aa-turret", position = at(40, 40), force = HOME, raise_built = true})
  S.aa.insert({name = "firearm-magazine", count = 20})
  S.gun = s.create_entity({name = "rts-turret", position = at(40, 52), force = HOME, raise_built = true})
  S.gun.insert({name = "firearm-magazine", count = 20})
  S.bomber = spawn("rts-bomber", at(40, 46), FOE)
  S.bomber.commandable.set_command({type = defines.command.stop, distraction = defines.distraction.none})
  S.bomber_hp = S.bomber.health
  S.t0 = game.tick
  S.phase = "air"
end, function(S)
  if S.phase == "air" then
    if S.bomber.valid and game.tick - S.t0 < 20 * 60 then return false end
    S.t_kill = (game.tick - S.t0) / 60
    S.gun_mag = S.gun.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine")
    S.drone = spawn("rts-drone", at(40, 58), FOE)
    S.drone.commandable.set_command({type = defines.command.stop, distraction = defines.distraction.none})
    -- an empty AA turret beside the city centre, magazines in its network
    local s = surface()
    local c = cities.get(T.city)
    local net = c and c.entity and c.entity.valid and s.find_logistic_network_by_position(c.entity.position, HOME)
    if net then net.insert({name = "firearm-magazine", count = 50}) end
    local fpos = s.find_non_colliding_position("rts-aa-turret", c.entity.position, 10, 1, true)
    S.aa2 = fpos and s.create_entity({name = "rts-aa-turret", position = fpos, force = HOME, raise_built = true})
    S.net = net ~= nil and net.valid
    S.t1 = game.tick
    S.phase = "drone"
    return false
  end
  if game.tick - S.t1 < 5 * 60 then return false end
  local fed = S.aa2 and S.aa2.valid and S.aa2.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine") or 0
  check("aa_turret", not S.bomber.valid and S.gun_mag == 20 and not S.drone.valid and fed >= A.aa_turret.feed_min,
    "AA turret: hovering bomber (%d HP) dead after %.1f s; gun turret beside it fired %d magazine(s) at it; the gun "
    .. "turret then killed a drone: %s; an empty AA turret in a network with magazines (network %s) holds %d",
    S.bomber_hp, S.t_kill, 20 - S.gun_mag, tostring(not S.drone.valid), tostring(S.net), fed)
  for _, e in pairs({S.aa, S.gun, S.aa2}) do if e and e.valid then e.destroy() end end
  return true
end)

step("patrol", 50 * 60, function(S)
  local list = {}
  for i = 1, 3 do list[i] = spawn("rts-interceptor", at(0, 40 + i * 3), HOME) end
  S.list = list
  S.id = divisions.create(HOME, list, {name = "Air test 3"})
  S.center = at(30, 50)
  S.n = air.order_patrol(S.id, S.center, 30)
  S.k0 = {}
  for _, e in ipairs(list) do S.k0[e.unit_number] = plane_rec(e) and plane_rec(e).patrol and plane_rec(e).patrol.k end
  S.t0 = game.tick
  S.maxd = 0
  S.moves = 0
end, function(S)
  for _, e in ipairs(S.list) do
    if e.valid then S.maxd = math.max(S.maxd, util.distance(e.position, S.center)) end
  end
  if game.tick - S.t0 < 30 * 60 then return false end
  local D = divisions.get(S.id)
  local turns, all = 0, 0
  for _, e in ipairs(S.list) do
    local p = plane_rec(e)
    if p and p.patrol then
      all = all + 1
      local k0 = S.k0[e.unit_number] or 0
      local adv = (p.patrol.k - k0) % A.patrol.points
      if adv >= 2 or p.patrol.k ~= k0 then turns = turns + 1 end
    end
  end
  local sp = D and (D.sp or balance.nation.war.sp_start)
  check("patrol", S.n == 3 and D ~= nil and D.state == "patrolling" and all == 3 and turns == 3 and S.maxd <= 30 + 20
    and sp == balance.nation.war.sp_max,
    "3 interceptors patrol %s r=30: division %s, %d planes on patrol, %d moved on along the circle in 30 s, farthest "
    .. "%.1f tiles from the centre; division supply points %.1f (an all-plane division keeps them)",
    util.pos_str(S.center), D and D.state or "gone", all, turns, S.maxd, sp or -1)
  -- the division is ordered home: every plane returns; a division order then leaves the returning planes alone
  local sent = air.order_return(S.id)
  local returning = 0
  for _, e in ipairs(S.list) do if air.state(e.unit_number) == "returning" then returning = returning + 1 end end
  local after = D and D.state
  local moved = D and divisions.order(S.id, "move", at(60, 60))
  local still = 0
  for _, e in ipairs(S.list) do
    local rec = storage.units[e.unit_number]
    if rec and rec.issuer == air.ISSUER and rec.order == "return" then still = still + 1 end
  end
  check("order_return", sent == 3 and returning == 3 and after == "idle" and still == 3 and not moved,
    "order_return sent %d, %d returning, the division %s; a move order to the division then: given %s, %d planes kept "
    .. "their return", sent, returning, tostring(after), tostring(moved), still)
  if divisions.get(S.id) then divisions.disband(S.id, "test") end
  for _, e in ipairs(S.list) do if e.valid then e.destroy() end end
  return true
end)

local depot_watch = {}
events.on(defines.events.on_entity_damaged, function(e)
  local ent = e.entity
  local w = ent and ent.valid and depot_watch[ent.unit_number]
  if w and not w.first then w.first = game.tick end
end)
events.on(defines.events.on_entity_died, function(e)
  local ent = e.entity
  local w = ent and ent.valid and depot_watch[ent.unit_number]
  if w then w.dead = game.tick end
end)

step("bomber_vs_walker", 120 * 60, function(S)
  local s = surface()
  local function depot(pos)
    local p = s.find_non_colliding_position("rts-depot", pos, 10, 1, true)
    return p and s.create_entity({name = "rts-depot", position = p, force = FOE, raise_built = true})
  end
  S.d1, S.d2 = depot(at(200, -50)), depot(at(200, 50))
  local function cost(name)
    local W = {["iron-plate"] = 1, ["copper-plate"] = 1, ["steel-plate"] = 3, ["electronic-circuit"] = 4,
               ["rts-explosives"] = 2, ["engine-unit"] = 7}
    local c = 0
    for item, n in pairs(balance.units[name].cost) do c = c + n * W[item] end
    return c
  end
  S.cost_b, S.cost_w = 2 * cost("rts-bomber"), 11 * cost("rts-walker")
  local bombers, walkers = {}, {}
  for i = 1, 2 do bombers[i] = spawn("rts-bomber", at(160, -50 + (i - 1.5) * 4), HOME) end
  for i = 1, 11 do walkers[i] = spawn("rts-walker", at(160 + math.floor((i - 1) / 4) * 3, 50 + ((i - 1) % 4 - 1.5) * 3), HOME) end
  S.bombers, S.walkers = bombers, walkers
  S.ib = divisions.create(HOME, bombers, {name = "Bombers"})
  depot_watch = {}
  depot_watch[S.d1.unit_number] = {}
  depot_watch[S.d2.unit_number] = {}
  S.w1, S.w2 = depot_watch[S.d1.unit_number], depot_watch[S.d2.unit_number]
  S.hp = S.d1.max_health
  divisions.order(S.ib, "attack", S.d1)
  orders.attack(walkers, S.d2) -- the loose-unit attack (the M2 war autotest's): attack_area on the target
  S.t0 = game.tick
end, function(S)
  if not (S.w1.dead and S.w2.dead) and game.tick - S.t0 < 110 * 60 then return false end
  local tb = S.w1.dead and S.w1.first and (S.w1.dead - S.w1.first) / 60
  local tw = S.w2.dead and S.w2.first and (S.w2.dead - S.w2.first) / 60
  local ob = S.w1.dead and (S.w1.dead - S.t0) / 60
  local ow = S.w2.dead and (S.w2.dead - S.t0) / 60
  check("bomber_vs_walker", tb ~= nil and tw ~= nil and tw >= 2 * tb and ow >= 2 * ob,
    "depot %d HP: 2 bombers (cost %d) destroyed theirs %s s after the first hit (%s s after the order), 11 walkers "
    .. "(cost %d) %s s (%s s); ratio %s (from the order %s)", S.hp, S.cost_b, tb and string.format("%.1f", tb) or "-",
    ob and string.format("%.1f", ob) or "-", S.cost_w, tw and string.format("%.1f", tw) or "-",
    ow and string.format("%.1f", ow) or "-", (tb and tw and tb > 0) and string.format("%.2f", tw / tb) or "-",
    (ob and ow and ob > 0) and string.format("%.2f", ow / ob) or "-")
  if divisions.get(S.ib) then divisions.disband(S.ib, "test") end
  local wd = 0
  for _, e in ipairs(S.walkers) do if e.valid then wd = wd + util.distance(e.position, S.d2.valid and S.d2.position or e.position) end end
  util.log("air autotest: bomber_vs_walker walkers' mean distance to their depot at the end %.1f", wd / #S.walkers)
  for _, l in ipairs({S.bombers, S.walkers}) do for _, e in ipairs(l) do if e.valid then e.destroy() end end end
  for _, d in ipairs({S.d1, S.d2}) do if d and d.valid then d.destroy() end end
  return true
end)

-- Diagnostic (no check): a walker division ordered to attack a FOE rail depot (the first run's walkers never hit it)
step("walker_division_diag", 50 * 60, function(S)
  local s = surface()
  local p = s.find_non_colliding_position("rts-depot", at(200, 0), 10, 1, true)
  S.d = p and s.create_entity({name = "rts-depot", position = p, force = FOE, raise_built = true})
  if not S.d then return false end
  S.walkers = {}
  for i = 1, 8 do S.walkers[i] = spawn("rts-walker", at(165 + math.floor((i - 1) / 4) * 3, ((i - 1) % 4 - 1.5) * 3), HOME) end
  S.id = divisions.create(HOME, S.walkers, {name = "Walker diag"})
  depot_watch = {}
  depot_watch[S.d.unit_number] = {}
  S.w = depot_watch[S.d.unit_number]
  S.ok = divisions.order(S.id, "attack", S.d)
  S.t0 = game.tick
end, function(S)
  local el = game.tick - S.t0
  if el % 600 == 0 then
    local D = divisions.get(S.id)
    local g = D and D.group
    local wd, n = 0, 0
    for _, e in ipairs(S.walkers) do
      if e.valid then
        wd, n = wd + util.distance(e.position, S.d.valid and S.d.position or e.position), n + 1
      end
    end
    util.log("air autotest: walker_division_diag %.0f s: order %s, division %s, group %s, mean distance %.1f, depot "
      .. "first hit %s, dead %s", el / 60, tostring(S.ok), D and D.state or "gone",
      (g and g.valid) and util.define_name(defines.group_state, g.state) or "none", n > 0 and wd / n or -1,
      tostring(S.w.first), tostring(S.w.dead))
  end
  if not S.w.dead and el < 40 * 60 then return false end
  if divisions.get(S.id) then divisions.disband(S.id, "test") end
  for _, e in ipairs(S.walkers) do if e.valid then e.destroy() end end
  if S.d.valid then S.d.destroy() end
  return true
end)

-- The panel's logic without a GUI (no player on a headless server): the patrol hook takes the fake player 0's right
-- click, and the HUD building lines of an airfield and an AA turret
step("gui_logic", 10 * 60, function(S)
  local P = util.PLAYER_FORCE
  S.list = {spawn("rts-scout-plane", at(10, -40), P), spawn("rts-scout-plane", at(14, -40), P)}
  local n_sel = selection.set(0, S.list)
  local ps = util.pstorage(0)
  ps.air_gui = {armed = game.tick, armed_tick = game.tick}
  local pos = at(30, -40)
  local order, n = orders.handle_reverse_area(0, {}, {left_top = pos, right_bottom = pos}, false)
  local patrolling = 0
  for _, e in ipairs(S.list) do
    local rec = storage.units[e.unit_number]
    if rec and rec.order == "patrol" and rec.issuer == air.ISSUER then patrolling = patrolling + 1 end
  end
  -- a player order takes a patrolling plane (units.yields)
  local moved = orders.move(0, at(30, -60))
  local taken = 0
  for _, e in ipairs(S.list) do
    local rec = storage.units[e.unit_number]
    if rec and rec.issuer == orders.ISSUER then taken = taken + 1 end
  end
  local el = {b_line1 = {}, b_line2 = {}, b_line3 = {}}
  airgui.building_lines(el, buildings.get(T.field.unit_number))
  local s = surface()
  local aa = s.create_entity({name = "rts-aa-turret", position = at(-30, -40), force = HOME, raise_built = true})
  local el2 = {b_line1 = {}, b_line2 = {}, b_line3 = {}}
  airgui.building_lines(el2, buildings.get(aa.unit_number))
  aa.destroy()
  selection.clear(0)
  util.pstorage(0).air_gui = nil
  check("gui_logic", n_sel == 2 and order == "patrol" and n == 2 and patrolling == 2 and moved == 2 and taken == 2
    and type(el.b_line2.caption) == "table" and type(el2.b_line1.caption) == "table",
    "armed patrol: selection %d, the right click gave %s to %s planes, %d on patrol; a move order then took %d of %d; "
    .. "airfield lines %s / %s, AA line %s", n_sel, tostring(order), tostring(n), patrolling, taken, moved,
    serpent.line(el.b_line1.caption), serpent.line(el.b_line2.caption), serpent.line(el2.b_line1.caption))
  for _, e in ipairs(S.list) do if e.valid then e.destroy() end end
  return true
end, function() return true end)

step("fog_scout", 60, function(S)
  local pos = at(230, 0)
  local scout = spawn("rts-scout-plane", pos, HOME)
  local with = fog.update_force(HOME)
  scout.destroy()
  local walker = spawn("rts-walker", pos, HOME)
  local without = fog.update_force(HOME)
  walker.destroy()
  check("fog_scout", with > without, "chunks fog.lua charts for %s: %d with a scout at %s, %d with a walker there "
    .. "(scout radius %d tiles, units %d)", HOME, with, util.pos_str(pos), without, fog.RADIUS_BY_KIND["scout-plane"] or -1,
    fog.UNIT_RADIUS)
  return true
end, function() return true end)

step("perf_step", 60 * 60, function(S)
  S.list = {}
  for k, name in ipairs(A.planes) do
    for i = 1, 20 do S.list[#S.list + 1] = spawn(name, at(20 + i * 3, -60 + k * 30), HOME) end
  end
  S.id = divisions.create(HOME, S.list, {name = "Air wing"})
  air.order_patrol(S.id, at(100, 0), 70)
  S.t0 = game.tick
end, function(S)
  if game.tick - S.t0 < 20 * 60 then return false end
  -- the supply step over 60 planes on patrol: 20 steps, profiled (the full fixture with PERF=1 and --benchmark is
  -- tools/probes/air_perf.lua)
  local prof = helpers.create_profiler()
  for _ = 1, 20 do air.step(0) end
  prof.stop()
  log({"", "[rts] air autotest perf: 20 supply steps over ", tostring(table_size(storage.air.planes)), " planes: ", prof})
  check("perf_step", table_size(storage.air.planes) >= 60, "60 planes on patrol; the step's time is the line above "
    .. "(one step per %d ticks)", A.period)
  if divisions.get(S.id) then divisions.disband(S.id, "test") end
  for _, e in ipairs(S.list) do if e.valid then e.destroy() end end
  return true
end)

---------------------------------------------------------------------------
-- Driver
---------------------------------------------------------------------------
events.on_nth_tick(1, function()
  if not game.is_multiplayer() then return end -- a --benchmark of a save of this run: stay still
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  if not storage.air_at then
    if game.tick - m.tick_started < START then return end
    storage.air_at = {pass = 0, fail = 0, checks = {}, started = game.tick, i = 0}
    T = storage.air_at
    for _, f in ipairs({HOME, FOE}) do if not game.forces[f] then game.create_force(f) end end
    game.forces[HOME].set_cease_fire(FOE, false)
    game.forces[FOE].set_cease_fire(HOME, false)
    if not setup() then
      check("setup", false, "city %s barracks %s", tostring(T.city), tostring(T.barracks))
      T.done = true
      util.log("air autotest summary %d/%d (FAILED)", T.pass, T.pass + T.fail)
      return
    end
  end
  T = storage.air_at
  if T.done then return end
  local cur = T.cur
  if not cur then
    T.i = T.i + 1
    local st = STEPS[T.i]
    if not st then
      T.done = true
      util.log("air autotest: %s; %s", air.describe(HOME), air.describe(FOE))
      util.log("air autotest summary %d/%d (%s)", T.pass, T.pass + T.fail, T.fail == 0 and "all passed" or "FAILED")
      return
    end
    cur = {name = st.name, started = game.tick, S = {}}
    T.cur = cur
    util.log("air autotest: step %s", st.name)
    if st.start(cur.S) == false then T.cur = nil end
    return
  end
  local st = STEPS[T.i]
  if st.tick(cur.S) then
    T.cur = nil
  elseif game.tick - cur.started > st.timeout then
    check(st.name, false, "timeout after %d s", st.timeout / 60)
    T.cur = nil
  end
end)

events.on_load(function() T = storage.air_at end)
