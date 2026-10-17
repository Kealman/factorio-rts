-- Phase 5 M3 air (docs/PHASE5-M3.md D4, section 3 "air.lua"; docs/qa/phase5-air-notes.md): planes' supply, the return
-- to an airfield, rearming and crashes, airfields (one per city, the kit gate and the spawn point), patrols, the AA
-- turret's magazines, and the planes' place in divisions, orders, war supply and fog. Nation mode only: in Skirmish no
-- plane, kit, airfield or AA turret can exist (the technologies are Nation-only) and every handler returns at once.
--
--   air.is_plane(entity) -> bool
--   air.supply(unit_number) -> 0..100              (nil for a unit that is no plane)
--   air.state(unit_number) -> "flying" | "returning" | "rearming" | "crashed" | nil
--   air.airfields(force) -> {entity}               one per city
--   air.airfield_of_city(force, city_id) -> entity | nil
--   air.can_build_airfield(force, position) -> ok, reason   ("not-own" | "one-per-city")
--   air.order_patrol(division_id, position, radius) -> n    the division's planes circle `position`
--   air.order_return(division_id) -> n                     the division's planes fly to the nearest own airfield
--   air.patrol_units(entities, position, radius) / air.return_units(entities) -> n   the same for loose planes
--   air.planes(force) -> {[unit_number] = {name, supply, state, ...}}  (read-only)
--
-- Supply (balance.nation.air.supply): every plane has 0..max (100). Every `period` ticks a plane within `range` (24)
-- tiles of an own airfield gains `refill` per second, any other plane loses `drain` per second. A flying plane at
-- `return_at` (20) or less flies to the nearest own airfield on its own ("returning"; its storage.units record is
-- claimed with issuer "air", order "return"), waits there until full ("rearming", order "rearm"), and is let go again
-- ("flying", idle; a plane that was on patrol resumes it). At 0 it crashes: it dies, an alert and a chat line go out,
-- and air.state answers "crashed" for crash_keep ticks. With no airfield left a low plane keeps flying (one alert)
-- until it crashes or an airfield appears.
--
-- Planes and the other modules:
--   * production: a plane kit becomes a plane only when the barracks' city (the city whose land it stands on, else the
--     force's nearest city) has an airfield; otherwise the kit waits with the block "airfield" (the kit gate is wrapped
--     like scripts/treasury.lua does). The plane appears at that airfield (production.exit_of) and stays there.
--   * divisions: planes may be members of any division. A division order flies its planes to their formation slots by
--     direct commands (they ignore terrain and never join the division's unit group, divisions.flying); planes that
--     return or rearm sit division orders out (divisions.held). A patrol is the planes' own order (air.order_patrol);
--     an all-plane division on patrol has the state "patrolling", which the division controller leaves alone.
--   * orders: a patrolling plane takes a player's order (units.yields); a returning or rearming one does not.
--   * war supply: planes have their own supply, so they neither use nor lose division supply points
--     (warsupply.exempt): an all-plane division keeps its points, a plane's hits do not make its division "engaged", out
--     of supply wears no plane, and no attack order is refused to a plane.
--   * territory: planes are immune to attrition (100 % resistance to rts-attrition, prototypes/air.lua).
--   * fog: scouts chart balance.units["rts-scout-plane"].vision tiles around them (fog.RADIUS_BY_KIND).
--   * AA turrets (kind "aa-turret") get magazines from the network they stand in every feed_period ticks.
--
-- Owns storage.air = {planes = {[unit_number] = {force, name, kind, supply, state, field, patrol, since, alerted}},
-- crashed = {[unit_number] = {tick, force, name}}, patrols = {[division_id] = {x, y, r, tick}}, stats = {[force] =
-- {returns, rearms, crashes, patrols}}} and storage.nations[force].air = {planes, by_kind, airfields, returning,
-- rearming, crashed} (the nation blackboard, refreshed every step). Cleared by the match teardown. Log lines "air: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local research = require("scripts.research")
local supply = require("scripts.supply")
local match = require("scripts.match")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local warsupply = require("scripts.warsupply")
local fog = require("scripts.fog")
local targeting = require("scripts.targeting")
local economy = require("scripts.economy")
local balance = require("balance")

local A = balance.nation.air
local SUP = A.supply

local air = {}

air.ISSUER = "air"
air.DISCOVER_STEPS = 10 -- supply steps between scans of the unit registry for planes that did not come from a barracks
air.AIRFIELD = "rts-airfield"
air.AA_TURRET = "rts-aa-turret"
air.PLANES = {}      -- [prototype name] = true
air.KINDS = {}       -- [units.lua kind] = prototype name
air.KITS = {}        -- [kit item] = prototype name
for _, name in ipairs(A.planes) do
  local u = balance.units[name]
  air.PLANES[name] = true
  air.KINDS[u.kind] = name
  air.KITS[u.kit] = name
end
local SCOUT = "rts-scout-plane"
local CMD, DIS = defines.command, defines.distraction
local HELD = {["return"] = true, rearm = true} -- claims of planes that sit division and player orders out
local AAT_KIND = A.aa_turret.kind

---------------------------------------------------------------------------
-- Registration with the other modules (load time)
---------------------------------------------------------------------------
buildings.KIND_BY_NAME[air.AIRFIELD] = A.airfield.kind
buildings.KIND_BY_NAME[air.AA_TURRET] = A.aa_turret.kind
territory.CLASS_BY_NAME[air.AA_TURRET] = "outpost" -- own or neutral land, like the gun turret; the airfield: own land

-- Plane kits: barracks recipes; units.lua kinds come from balance.units. Registered after scripts/ai/mix.lua built its
-- kit table, so the Phase 4 AI never chooses a plane kit (wave B's air AI orders planes deliberately).
for kit, name in pairs(air.KITS) do production.KITS[kit] = {unit = name, kind = balance.units[name].kind} end

-- Aviation (Age II) and Air Force (Age III): Nation-only technologies whose unlocks enable the recipes and let the
-- barracks deploy the planes (scripts/research.lua). AGE_REQUIRED gates the technology, the planes and their kits.
for _, t in ipairs(A.techs) do
  research.EFFECTS[t.name] = {unlock = t.unlock}
  research.NATION_ONLY[t.name] = true
  research.AGE_REQUIRED[t.name] = t.age
  for _, name in ipairs(t.unlock) do
    research.LOCKS[name] = t.name
    if balance.units[name] or air.KITS[name] then research.AGE_REQUIRED[name] = t.age end
  end
end

-- Fog: the scout's reveal
fog.RADIUS_BY_KIND[balance.units[SCOUT].kind] = balance.units[SCOUT].vision

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.air
  if not s then
    s = {}
    storage.air = s
  end
  s.planes = s.planes or {}
  s.crashed = s.crashed or {}
  s.patrols = s.patrols or {}
  s.stats = s.stats or {}
  s.fields = s.fields or {} -- [force] = {[unit_number] = true}: airfields (kept by the building hooks below)
  s.aa = s.aa or {}         -- [unit_number] = true: AA turrets
  return s
end

function air.init() S() end

--- True in a Nation-mode match (running or not).
local function nation()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation" and m.surface ~= nil
end
air.nation = nation

local function stats(force)
  local all = S().stats
  local st = all[force]
  if not st then
    st = {returns = 0, rearms = 0, crashes = 0, patrols = 0}
    all[force] = st
  end
  return st
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
function air.is_plane(entity)
  return entity ~= nil and entity.valid and air.PLANES[entity.name] == true
end

local function is_plane_rec(rec) return rec ~= nil and air.KINDS[rec.kind] ~= nil end

function air.supply(unit_number)
  local p = storage.air and storage.air.planes[unit_number]
  if p then return p.supply end
  local rec = storage.units and storage.units[unit_number]
  if is_plane_rec(rec) then return SUP.max end
  return nil
end

function air.state(unit_number)
  local s = storage.air
  local p = s and s.planes[unit_number]
  if p then return p.state end
  if s and s.crashed[unit_number] then return "crashed" end
  local rec = storage.units and storage.units[unit_number]
  if is_plane_rec(rec) and rec.entity.valid then return "flying" end
  return nil
end

--- The planes of a force: {[unit_number] = record} (read-only). A plane the supply step has not registered yet (it did
--- not come from a barracks) answers a full, flying record.
function air.planes(force)
  local out = {}
  local planes = storage.air and storage.air.planes or {}
  for un, rec in units.for_force(force) do
    if air.KINDS[rec.kind] then
      out[un] = planes[un] or {force = force, name = rec.entity.name, kind = rec.kind, supply = SUP.max,
                               state = "flying"}
    end
  end
  return out
end

--- Live airfields of a force, sorted by unit number.
function air.airfields(force)
  local keys = {}
  for un in pairs(S().fields[force] or {}) do
    local rec = storage.buildings[un]
    if rec and rec.entity.valid and rec.force == force then keys[#keys + 1] = un end
  end
  table.sort(keys)
  local out = {}
  for i, un in ipairs(keys) do out[i] = storage.buildings[un].entity end
  return out
end

-- The city of a position for a force: the city whose land it is (territory.city_at), else the force's nearest city.
local function city_of(force, position)
  local id = territory.city_at(position)
  local c = id and cities.get(id)
  if c and c.force == force then return id end
  local best, bd
  for _, city in ipairs(cities.for_force(force)) do
    local d = util.distance_sq(city.position, position)
    if not bd or d < bd then best, bd = city.id, d end
  end
  return best
end
air.city_of = city_of

function air.airfield_of_city(force, city_id)
  if not city_id then return nil end
  for _, e in ipairs(air.airfields(force)) do
    if city_of(force, e.position) == city_id then return e end
  end
  return nil
end

--- Whether `force` may put an airfield at `position`: own land (territory) and no other airfield (or ghost of one) of
--- the force in that city.
function air.can_build_airfield(force, position, except)
  local surface = match.surface()
  if not surface then return false, "no-surface" end
  local ok, reason = territory.can_build(force, air.AIRFIELD, position)
  if not ok then return false, reason end
  local city = territory.city_at(position)
  if not city then return false, "not-own" end
  for _, e in ipairs(air.airfields(force)) do
    if e ~= except and territory.city_at(e.position) == city then return false, "one-per-city" end
  end
  for _, g in ipairs(surface.find_entities_filtered({ghost_name = air.AIRFIELD, force = force})) do
    if g ~= except and territory.city_at(g.position) == city then return false, "one-per-city" end
  end
  return true
end

-- Airfield positions of a force for the supply step: {{un, x, y}, ...}
local function field_list(force)
  local out = {}
  for un in pairs(S().fields[force] or {}) do
    local rec = storage.buildings[un]
    if rec and rec.entity.valid and rec.force == force then
      local p = rec.position
      out[#out + 1] = {un, p.x, p.y}
    end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

local function nearest_field(list, pos)
  local best, bd
  for _, f in ipairs(list) do
    local dx, dy = f[2] - pos.x, f[3] - pos.y
    local d = dx * dx + dy * dy
    if not bd or d < bd then best, bd = f, d end
  end
  return best, bd and math.sqrt(bd) or nil
end

---------------------------------------------------------------------------
-- Plane records
---------------------------------------------------------------------------
local function register(s, un, rec)
  local p = {force = rec.force, name = rec.entity.name, kind = rec.kind, supply = SUP.max, state = "flying",
             since = game.tick}
  s.planes[un] = p
  return p
end

-- Planes the registry got by any road (barracks, /rts-spawn, tests): units.lua has no spawn event, so the step scans
-- for plane kinds it does not know yet (a table walk over storage.units once per period).
local function discover(s)
  for un, rec in pairs(storage.units) do
    if not s.planes[un] and air.KINDS[rec.kind] and rec.entity.valid then register(s, un, rec) end
  end
end

local function claim(rec, order, dest)
  rec.order, rec.dest, rec.target, rec.issuer, rec.fails = order, dest, nil, air.ISSUER, nil
end

local function let_go(rec)
  if rec.issuer == air.ISSUER then
    rec.order, rec.dest, rec.target, rec.issuer, rec.fails = units.IDLE, nil, nil, nil, nil
  end
end

-- A landing slot on the airfield's apron: one of 12 places around its centre.
local function apron(field, un)
  local k = un % 12
  local angle = k * 2 * math.pi / 12
  local r = 2 + (k % 3)
  return {x = field[2] + r * math.cos(angle), y = field[3] + r * math.sin(angle)}
end

local function fly_home(rec, p, field)
  local dest = apron(field, rec.entity.unit_number)
  claim(rec, "return", dest)
  p.field = field[1]
  orders.cancel_queued(rec.entity)
  orders.queue_command(rec.entity, {type = CMD.go_to_location, destination = dest, radius = A.return_radius,
                                    distraction = DIS.none})
end

local function start_return(rec, p, fields, why)
  local field = nearest_field(fields, rec.entity.position)
  if not field then
    if not p.alerted then
      p.alerted = true
      supply.alert(p.force, "plane-no-airfield", "rts-air.alert-no-airfield", {{"entity-name." .. p.name}},
        rec.entity.position)
      util.log("air: %s #%d (%s) low on supply (%.0f) and no airfield", p.name, rec.entity.unit_number, p.force,
        p.supply)
    end
    return false
  end
  p.state, p.since, p.alerted = "returning", game.tick, nil
  fly_home(rec, p, field)
  -- its division does not wait for it to reach its formation slot
  local un = rec.entity.unit_number
  local D = divisions.get(divisions.of_unit(un))
  if D and D.settling then D.settling[un] = nil end
  stats(p.force).returns = stats(p.force).returns + 1
  util.log("air: %s #%d (%s) returns to airfield #%d (%s, supply %.0f) from %s", p.name, rec.entity.unit_number,
    p.force, field[1], why, p.supply, util.pos_str(rec.entity.position))
  return true
end

local function begin_rearm(rec, p)
  p.state, p.since = "rearming", game.tick
  claim(rec, "rearm", rec.entity.position)
  orders.cancel_queued(rec.entity)
  units.stop(rec.entity)
  stats(p.force).rearms = stats(p.force).rearms + 1
end

local next_waypoint -- patrols, below

local function release(rec, p, why)
  p.state, p.since = "flying", game.tick
  let_go(rec)
  units.stop(rec.entity)
  local pt = p.patrol
  if pt and pt.div then -- a division patrol that a later division order replaced is over
    local D = divisions.get(pt.div)
    if not D or (D.order and D.order.kind ~= "patrol" and D.order.tick > pt.tick) then p.patrol = nil end
  end
  util.log("air: %s #%d (%s) %s at %s%s", p.name, rec.entity.unit_number, p.force, why or "rearmed",
    util.pos_str(rec.entity.position), p.patrol and " (resumes its patrol)" or "")
  if p.patrol then next_waypoint(rec, p) end
end

local function crash(s, un, rec, p)
  local e = rec.entity
  local pos = e.position
  util.log("air: %s #%d (%s) crashed at %s (supply 0, %s)", p.name, un, p.force, util.pos_str(pos), p.state)
  supply.alert(p.force, "plane-crashed", "rts-air.alert-crashed", {{"entity-name." .. p.name}}, pos)
  local force = game.forces[p.force]
  if force then force.print({"rts-air.alert-crashed", {"entity-name." .. p.name}}) end
  s.crashed[un] = {tick = game.tick, force = p.force, name = p.name}
  s.planes[un] = nil
  stats(p.force).crashes = stats(p.force).crashes + 1
  e.die()
end

---------------------------------------------------------------------------
-- Patrols
---------------------------------------------------------------------------
next_waypoint = function(rec, p)
  local pt = p.patrol
  local n = A.patrol.points
  pt.k = (pt.k or 0) % n + 1
  local angle = pt.k * 2 * math.pi / n
  local dest = {x = pt.x + pt.r * math.cos(angle), y = pt.y + pt.r * math.sin(angle)}
  claim(rec, "patrol", dest)
  orders.cancel_queued(rec.entity)
  orders.queue_command(rec.entity, {type = CMD.go_to_location, destination = dest, radius = 3,
    distraction = p.name == SCOUT and DIS.none or DIS.by_enemy})
end

local function plane_records(items)
  local out, seen = {}, {}
  for _, item in pairs(items or {}) do
    local un = type(item) == "number" and item or (type(item) == "table" and item.valid and item.unit_number)
    if not un and type(item) == "table" and item.entity then un = item.entity.valid and item.entity.unit_number end
    if un and not seen[un] then
      seen[un] = true
      local rec = units.get(un)
      if is_plane_rec(rec) then out[#out + 1] = rec end
    end
  end
  table.sort(out, function(a, b) return a.entity.unit_number < b.entity.unit_number end)
  return out
end

--- Loose planes (entities, unit numbers or unit records) circle `position` at `radius` tiles. Planes that return or
--- rearm start the patrol when they are full. Returns the number of planes.
function air.patrol_units(items, position, radius, division_id)
  local s = S()
  local x, y = util.xy(position)
  radius = radius or A.patrol.radius
  local recs = plane_records(items)
  for i, rec in ipairs(recs) do
    local un = rec.entity.unit_number
    local p = s.planes[un] or register(s, un, rec)
    -- the planes spread over the circle's waypoints
    p.patrol = {x = x, y = y, r = radius, k = math.floor((i - 1) * A.patrol.points / #recs), div = division_id,
                tick = game.tick}
    if not HELD[rec.order] or rec.issuer ~= air.ISSUER then
      p.state = "flying"
      next_waypoint(rec, p)
    end
  end
  if #recs > 0 then
    local f = recs[1].force
    stats(f).patrols = stats(f).patrols + 1
    util.log("air: %d plane(s) of %s patrol %s radius %.0f%s", #recs, f, util.pos_str({x = x, y = y}), radius,
      division_id and (" (division #" .. division_id .. ")") or "")
  end
  return #recs
end

--- Planes fly to the nearest own airfield now, whatever their supply, rearm there and wait. Returns the number sent.
function air.return_units(items)
  local s = S()
  local n = 0
  local lists = {}
  for _, rec in ipairs(plane_records(items)) do
    local un = rec.entity.unit_number
    local p = s.planes[un] or register(s, un, rec)
    if p.state ~= "returning" and p.state ~= "rearming" then
      p.patrol = nil
      lists[p.force] = lists[p.force] or field_list(p.force)
      if start_return(rec, p, lists[p.force], "ordered") then n = n + 1 end
    end
    -- a division whose patrol this ends is idle again (its planes wait at the airfield)
    local id = divisions.of_unit(un)
    local D = divisions.get(id)
    if D and D.state == "patrolling" then
      D.state = "idle"
      if D.order then D.order.done = game.tick end
      s.patrols[id] = nil
    end
  end
  return n
end

local function plane_members(D)
  local out = {}
  for _, rec in ipairs(divisions.live_members(D)) do
    if is_plane_rec(rec) then out[#out + 1] = rec end
  end
  return out
end

--- The planes of division `division_id` patrol a circle of `radius` (default balance) around `position`. An all-plane
--- division takes the state "patrolling" (the division controller leaves it alone; any division order ends it).
--- Returns the number of planes.
function air.order_patrol(division_id, position, radius)
  local D = divisions.get(division_id)
  if not D then return 0 end
  local planes = plane_members(D)
  if #planes == 0 then return 0 end
  local n = air.patrol_units(planes, position, radius, division_id)
  local x, y = util.xy(position)
  if n == table_size(D.units) then
    D.state = "patrolling"
    D.order = {kind = "patrol", target = {x = x, y = y}, tick = game.tick}
    D.detached, D.joining, D.settling = {}, {}, {}
  end
  S().patrols[division_id] = {x = x, y = y, r = radius or A.patrol.radius, tick = game.tick}
  return n
end

--- The planes of division `division_id` fly back to the nearest own airfield and rearm. Returns the number sent.
function air.order_return(division_id)
  local D = divisions.get(division_id)
  if not D then return 0 end
  local n = air.return_units(plane_members(D))
  util.log("air: division #%d (%s) ordered home: %d plane(s)", division_id, D.force, n)
  return n
end

---------------------------------------------------------------------------
-- The supply step
---------------------------------------------------------------------------
local function blackboard(force, counts)
  local nations = storage.nations
  local n = nations and nations[force]
  if n then n.air = counts end
end

--- One supply step over every plane (every A.period ticks; tests may call it with another dt in ticks).
function air.step(dt)
  if not nation() then return 0 end
  local s = S()
  -- barracks planes register when they spawn; others (console, scripts) within DISCOVER_STEPS steps (a test's call
  -- with dt looks at once)
  s.steps = (s.steps or 0) + 1
  if dt or s.steps % air.DISCOVER_STEPS == 0 then discover(s) end
  dt = (dt or A.period) / 60
  local fields, counts = {}, {}
  local list = {}
  for un in pairs(s.planes) do list[#list + 1] = un end
  table.sort(list)
  for _, un in ipairs(list) do
    local p = s.planes[un]
    local rec = storage.units[un]
    if not (rec and rec.entity.valid) then
      s.planes[un] = nil
    else
      local f = p.force
      if rec.force ~= f then p.force, f = rec.force, rec.force end -- a captured plane (none yet; cheap to follow)
      local fl = fields[f]
      if not fl then
        fl = field_list(f)
        fields[f] = fl
      end
      local e = rec.entity
      local pos = e.position
      local near, nd = nearest_field(fl, pos)
      local in_range = near ~= nil and nd <= SUP.range
      if in_range then
        p.supply = math.min(SUP.max, p.supply + SUP.refill * dt)
      else
        p.supply = p.supply - SUP.drain * dt
      end
      if p.supply <= 0 then
        crash(s, un, rec, p)
      else
        if p.state == "flying" and p.patrol and rec.issuer ~= air.ISSUER then p.patrol = nil end -- re-ordered
        if p.state == "returning" then
          local b = storage.buildings[p.field or 0]
          if in_range and nd <= A.return_radius + 6 then
            begin_rearm(rec, p)
          elseif rec.issuer ~= air.ISSUER or rec.order ~= "return" or not (b and b.force == f and b.entity.valid) then
            -- lost its claim, or its airfield is gone or captured: the nearest own one, else it flies on free
            if not start_return(rec, p, fl, "again") then release(rec, p, "let go: no airfield") end
          end
        elseif p.state == "rearming" then
          if not in_range then
            if not start_return(rec, p, fl, "pushed off") then release(rec, p, "let go: no airfield") end
          elseif p.supply >= SUP.max then
            release(rec, p)
          end
        elseif not in_range then
          -- at return_at, or earlier when the flight home needs more (bingo: distance / speed x drain, with a margin)
          local speed = (e.speed or 0) * 60
          local need = (near and speed > 0.5) and nd / speed * SUP.drain * SUP.bingo_factor + SUP.bingo_margin or 0
          if p.supply <= SUP.return_at or p.supply <= need then
            start_return(rec, p, fl, p.supply <= SUP.return_at and "low supply" or "bingo")
          end
        end
        local c = counts[f]
        if not c then
          c = {planes = 0, by_kind = {}, returning = 0, rearming = 0, airfields = #fl}
          counts[f] = c
        end
        c.planes = c.planes + 1
        c.by_kind[p.kind] = (c.by_kind[p.kind] or 0) + 1
        if p.state == "returning" then c.returning = c.returning + 1 end
        if p.state == "rearming" then c.rearming = c.rearming + 1 end
      end
    end
  end
  -- crashed records expire; divisions that left their patrol forget it
  local tick = game.tick
  for un, c in pairs(s.crashed) do
    if tick - c.tick > A.crash_keep then s.crashed[un] = nil end
  end
  for id in pairs(s.patrols) do
    local D = divisions.get(id)
    if not D or D.state ~= "patrolling" then s.patrols[id] = nil end
  end
  for _, f in ipairs(match.forces()) do
    local c = counts[f] or {planes = 0, by_kind = {}, returning = 0, rearming = 0, airfields = #field_list(f)}
    c.crashed = stats(f).crashes
    blackboard(f, c)
  end
  return #list
end

events.on_nth_tick(A.period, function()
  local m = storage.match
  if m and m.phase == "running" and storage.air and nation() then air.step() end
end)

---------------------------------------------------------------------------
-- Commands that ended
---------------------------------------------------------------------------
events.on(defines.events.on_ai_command_completed, function(e)
  local rec = storage.units and storage.units[e.unit_number]
  if not (rec and rec.issuer == air.ISSUER and rec.entity.valid) then return end
  local s = storage.air
  local p = s and s.planes[e.unit_number]
  if not p then
    let_go(rec)
    units.stop(rec.entity)
    return
  end
  if rec.order == "return" then
    if e.result == defines.behavior_result.fail then
      rec.fails = (rec.fails or 0) + 1
      if rec.fails <= 3 and rec.dest then
        orders.queue_command(rec.entity, {type = CMD.go_to_location, destination = rec.dest,
                                          radius = A.return_radius, distraction = DIS.none})
        return
      end
    end
    begin_rearm(rec, p) -- the step lets it go when full (or sends it on if it is out of the airfield's range)
  elseif rec.order == "patrol" then
    if p.patrol then next_waypoint(rec, p) else let_go(rec) units.stop(rec.entity) end
  elseif rec.order == "rearm" then
    units.stop(rec.entity)
  end
end)

---------------------------------------------------------------------------
-- Barracks: the airfield gate and the spawn point
---------------------------------------------------------------------------
--- The airfield a barracks' plane kits use: the one in the barracks' city, or nil.
function air.airfield_for_barracks(rec)
  local e = rec.entity
  if not (e and e.valid) then return nil end
  return air.airfield_of_city(rec.force, city_of(rec.force, e.position))
end

local inner_gate = production.kit_gate
production.kit_gate = function(rec, kit, def)
  if air.KITS[kit] then
    if not air.airfield_for_barracks(rec) then
      local old = rec.research_block
      if not (old and old.reason == "airfield") then
        util.log("air: barracks #%d (%s) holds a %s: no airfield in its city", rec.entity.unit_number, rec.force, kit)
      end
      rec.research_block = {reason = "airfield", unit = def.unit, kit = kit, tick = game.tick}
      return nil
    end
  end
  if inner_gate then return inner_gate(rec, kit, def) end
  return def
end
air.kit_gate = production.kit_gate

production.exit_of = function(rec, def)
  if not air.PLANES[def.unit] then return nil end
  local field = air.airfield_for_barracks(rec)
  if not field then return nil end
  local p = field.position
  local k = (rec.spawned or 0) % 8
  local angle = k * 2 * math.pi / 8
  return {x = p.x + 2.5 * math.cos(angle), y = p.y + 2.5 * math.sin(angle)}
end

-- A new plane stays on its airfield (production gave it the barracks' rally walk), unless a division took it.
production.on_spawned(function(unit, brec)
  if not (unit.valid and air.PLANES[unit.name]) then return end
  local rec = storage.units[unit.unit_number]
  if rec and rec.order == units.IDLE then units.stop(unit) end
  if rec then register(S(), unit.unit_number, rec) end
  util.log("air: %s #%d (%s) ready at %s", unit.name, unit.unit_number, brec.force, util.pos_str(unit.position))
end)

---------------------------------------------------------------------------
-- Divisions, orders and war supply
---------------------------------------------------------------------------
divisions.flying = function(rec) return is_plane_rec(rec) end
divisions.held = function(rec) return rec.issuer == air.ISSUER and HELD[rec.order] == true end
units.yields = function(rec) return rec.issuer == air.ISSUER and rec.order == "patrol" end
warsupply.exempt = function(entity) return entity.valid and air.PLANES[entity.name] == true end

-- Bombers in a division's attack go for the enemy building at the point (divisions.lua's fly()); this answers which.
function air.strike_target(surface, position, force)
  return targeting.nearest_building(surface, position, force, targeting.ATTACK_RADIUS + 1)
end
divisions.air_strike = air.strike_target

---------------------------------------------------------------------------
-- Airfields: one per city (players' ghosts and robot builds; the AI asks air.can_build_airfield)
---------------------------------------------------------------------------
local BUILD_EVENTS = {[defines.events.on_built_entity] = true, [defines.events.on_robot_built_entity] = true}
buildings.on_build_check(function(entity, e)
  if not BUILD_EVENTS[e.name] then return true end
  local name = entity.type == "entity-ghost" and entity.ghost_name or entity.name
  if name ~= air.AIRFIELD or not nation() then return true end
  local force = entity.force.name
  local city = territory.city_at(entity.position)
  local clash = false
  if city then
    for _, other in ipairs(air.airfields(force)) do
      if other ~= entity and territory.city_at(other.position) == city then clash = true end
    end
    for _, g in ipairs(entity.surface.find_entities_filtered({ghost_name = air.AIRFIELD, force = force})) do
      if g ~= entity and territory.city_at(g.position) == city then clash = true end
    end
  end
  if not clash then return true end
  local pos, surface = entity.position, entity.surface
  local ghost = entity.type == "entity-ghost"
  entity.destroy()
  if not ghost then economy.give(force, air.AIRFIELD, 1) end -- back to the pool, like a territory refusal
  local player = (e.player_index or 0) > 0 and game.get_player(e.player_index)
  if player and player.valid then
    player.create_local_flying_text({text = {"rts-air.refused-one-per-city"}, position = pos, surface = surface,
                                     color = {1, 0.4, 0.3}})
  end
  util.log("air: refused a second airfield%s of %s in city %s at %s", ghost and " ghost" or "", force, tostring(city),
    util.pos_str(pos))
  return false
end)

local function index_add(un, rec)
  if rec.kind == A.airfield.kind then
    local s = S()
    s.fields[rec.force] = s.fields[rec.force] or {}
    s.fields[rec.force][un] = true
  elseif rec.kind == AAT_KIND then
    S().aa[un] = true
  end
end

local function index_drop(un, force)
  local s = storage.air
  if not s then return end
  if s.fields and s.fields[force] then s.fields[force][un] = nil end
  if s.aa then s.aa[un] = nil end
end

buildings.on_added(function(un, rec)
  index_add(un, rec)
  if rec.kind == A.airfield.kind then
    util.log("air: airfield #%d of %s at %s (city %s)", un, rec.force, util.pos_str(rec.position),
      tostring(territory.city_at(rec.position)))
  end
end)
buildings.on_removed(function(un, rec) index_drop(un, rec.force) end)
buildings.on_force_changed(function(un, rec, old)
  index_drop(un, old)
  index_add(un, rec)
end)

---------------------------------------------------------------------------
-- AA turrets: magazines from their network
---------------------------------------------------------------------------
local AAT = A.aa_turret
local AMMO = production.AMMO
local function feed(rec)
  local e = rec.entity
  local inv = e.get_inventory(defines.inventory.turret_ammo)
  if not (inv and inv.get_item_count(AMMO) < AAT.feed_min) then return end
  local network = production.network_for(e)
  local got = network and network.remove_item({name = AMMO, count = AAT.feed}) or 0
  if got > 0 then
    local put = inv.insert({name = AMMO, count = got})
    if put < got then network.insert({name = AMMO, count = got - put}) end
    if production.on_flow then production.on_flow(rec, AMMO, put, "used") end
  end
end

events.on_nth_tick(AAT.feed_period, function()
  local s = storage.air
  if not (s and s.aa and next(s.aa) and nation()) then return end
  local list = {}
  for un in pairs(s.aa) do list[#list + 1] = un end
  table.sort(list)
  for _, un in ipairs(list) do
    local rec = buildings.get(un)
    if rec then feed(rec) else s.aa[un] = nil end
  end
end)

---------------------------------------------------------------------------
-- Teardown, console
---------------------------------------------------------------------------
match.on_teardown(function()
  storage.air = nil
  for _, n in pairs(storage.nations or {}) do n.air = nil end
end)

--- One line per force for logs and the console.
function air.describe(force)
  local by, n, sup = {}, 0, 0
  local st = {flying = 0, returning = 0, rearming = 0}
  for _, p in pairs(air.planes(force)) do
    n = n + 1
    sup = sup + p.supply
    by[p.kind] = (by[p.kind] or 0) + 1
    st[p.state] = (st[p.state] or 0) + 1
  end
  local kinds = {}
  for k, v in pairs(by) do kinds[#kinds + 1] = k .. "=" .. v end
  table.sort(kinds)
  local s = stats(force)
  return string.format("%s: %d planes [%s] flying %d returning %d rearming %d, mean supply %.0f; %d airfields; "
    .. "returns %d rearms %d crashes %d patrols %d", force, n, table.concat(kinds, " "), st.flying, st.returning,
    st.rearming, n > 0 and sup / n or 0, #air.airfields(force), s.returns, s.rearms, s.crashes, s.patrols)
end

commands.add_command("rts-air", "[force] - planes, supply and airfields of a force", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  local force = (cmd.parameter and cmd.parameter ~= "" and cmd.parameter) or (player and player.force.name)
    or util.PLAYER_FORCE
  local line = air.describe(force)
  if player then player.print(line) else log("[rts] " .. line) end
end)

return air
