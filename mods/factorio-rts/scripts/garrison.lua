-- Phase 5 M2 war: units off the map as records (docs/PHASE5-M2.md section 3 "garrison.lua" and the troop wagon; studies
-- docs/research/scale/war-ai-performance.md sections 2.5 and 2.6, docs/research/scale/rails-trade.md section 3; notes
-- docs/qa/phase5-war-notes.md). Nation mode only. Records cost nothing per tick.
--
-- Garrisons. A division ordered into its own city (right-click the City Center or the capital's Command Center, or
-- divisions.order(id, "garrison", city_id)) walks there; each member within enter_radius of the centre becomes a record
-- {name, kind, health ratio, division name and template} in storage.garrison.cities[city].records and its entity goes.
-- Garrison points = the records' supply cost. Hidden turrets (rts-garrison-turret: invisible, not selectable, no
-- collision, indestructible, free ammo) stand on a ring around the centre; one is enabled per points_per_turret (4)
-- points, at most max_turrets. A sortie (garrison.sortie: the division panel's button, or automatically when the centre
-- drops below sortie_health of its health) re-creates every record next to the centre as one division (stance
-- advance). A captured city loses its garrison (capture.lua calls garrison.on_captured).
--
-- Troop trains. rails.lua builds them from 2 locomotive kits and 1..max_wagons troop wagon kits (rails.create_train
-- with kind "troop", the depot rail panel's "Deploy troop train", or automatically when a division is told to embark at
-- a depot that has the kits) and routes them like freight trains (right-click a depot = pickup, Shift = drop-off). A
-- division ordered to embark (right-click an own depot or its platform, or divisions.order(id, "embark", depot_un))
-- walks to the platform (Phase 5 M2 QA round 1: only when a troop train stands there, can be deployed there or is
-- routed through it; otherwise the order is refused and the card reads "No troop train"); members within embark_radius
-- of a troop wagon of a troop train standing at that depot board while the wagon has room (capacity 16 supply): their
-- records go into storage.rails.manifests[wagon unit_number] and the entities go. D.aboard counts them, so the division
-- stays while every member rides. At the pickup the train leaves for its drop-off when nobody is still walking to it
-- (or embark_wait after the last boarding, or full); at the drop-off every manifest disembarks at once on the far side
-- of the track (disembark_ring tiles out), the units rejoin their division (divisions.attach) with the health they
-- boarded with and walk clear of the platform; then the train returns to the pickup. A destroyed troop wagon kills its
-- manifest (alert); a troop train that lost its locomotives lets its troops out where it stands. Garrisoned and
-- travelling units keep counting against the supply cap (supply.used is wrapped below).
--
-- Owns storage.garrison = {cities = {[city_id] = {force, records, points, turrets = {LuaEntity}, enabled}},
--   pending = {[division_id] = city_id}, pending_units = {[unit_number] = city_id}, next_ammo, stats} and
-- storage.rails.manifests = {[wagon unit_number] = {force, wagon, records, supply}}; both cleared by match teardown.
-- Log lines "[rts] war: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local orders = require("scripts.orders")
local selection = require("scripts.selection")
local divisions = require("scripts.divisions")
local supply = require("scripts.supply")
local rails = require("scripts.rails")
local cities = require("scripts.cities")
local balance = require("balance")

local garrison = {}

local W = balance.nation.war
local G = W.garrison
local TW = W.troop_wagon
garrison.TURRET = "rts-garrison-turret"
garrison.TWAGON = "rts-troop-wagon"
garrison.AMMO = "firearm-magazine"
garrison.POLL = 30               -- boarding, garrison entry and stranded-train checks (ticks)
garrison.SKIP_KINDS = {hauler = true, commander = true}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.garrison
  if not s then
    s = {}
    storage.garrison = s
  end
  s.cities = s.cities or {}
  s.pending = s.pending or {}
  s.pending_units = s.pending_units or {}
  s.next_ammo = s.next_ammo or 0
  s.stats = s.stats or {entered = 0, sorties = 0, boarded = 0, disembarked = 0, lost_in_wagons = 0, trains = 0}
  return s
end

local function manifests()
  local R = storage.rails
  if not R then
    R = {}
    storage.rails = R
  end
  R.manifests = R.manifests or {}
  return R.manifests
end

function garrison.init()
  S()
end

local function nation()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation" and m.surface ~= nil
end

local function city_rec(city_id)
  local s = S()
  local c = s.cities[city_id]
  if not c then
    local city = cities.get(city_id)
    c = {force = city and city.force, records = {}, points = 0, turrets = {}, enabled = 0}
    s.cities[city_id] = c
  end
  return c
end

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------
-- m2-people (scripts/labor.lua): a soldier's home city lives in storage.labor.soldiers[unit_number]; records keep it so
-- a unit that comes back (sortie, disembark) still returns its recruits home when it is disbanded.
local function labor_soldier(un)
  local L = storage.labor
  return L and L.soldiers and L.soldiers[un] or nil
end

local function record_of(rec, D)
  local e = rec.entity
  local max = e.max_health or 0
  -- the supply points travel with the record (a garrison or a train refills nothing: scripts/warsupply.lua)
  local ws = storage.warsupply
  local sp = D and D.sp or (ws and ws.unit_sp and ws.unit_sp[e.unit_number]) or nil
  return {name = e.name, kind = rec.kind, health = max > 0 and e.health / max or 1, division = D and D.id or nil,
          dname = D and D.name or nil, template = D and D.template or nil, stance = D and D.stance or nil, sp = sp,
          soldier = labor_soldier(e.unit_number)}
end

-- Mean supply points of records (nil entries count as full).
local function records_sp(list)
  local sum, n = 0, 0
  for _, r in ipairs(list) do
    sum, n = sum + (r.sp or W.sp_start), n + 1
  end
  return n > 0 and sum / n or W.sp_start
end

-- Take a unit off the map (its record was made): the entity goes and the registry forgets it at once.
local function despawn(rec)
  local un = rec.entity.unit_number
  orders.cancel_queued(rec.entity)
  rec.entity.destroy()
  units.get(un) -- invalid now: removed from storage.units, on_removed callbacks run (divisions, selection, army)
end

-- Re-create a record at `pos` (nearest free spot). Returns the entity or nil.
local function respawn(r, force, surface, pos)
  local e = units.spawn(r.name, pos, force, r.kind, surface)
  if not e then return nil end
  local max = e.max_health or 0
  if max > 0 then e.health = math.max(1, math.min(max, r.health * max)) end
  -- its supply points: the division it joins averages them in (scripts/warsupply.lua unit_sp)
  local ws = storage.warsupply
  if ws and ws.unit_sp and r.sp and r.sp < W.sp_max then ws.unit_sp[e.unit_number] = r.sp end
  local L = storage.labor
  if r.soldier and L and L.soldiers then L.soldiers[e.unit_number] = r.soldier end
  return e
end

local function cost_of(name) return supply.cost(name) end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t or {}) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

local function owner_of(force)
  for _, f in ipairs(match.ai_forces()) do
    if f == force then return "ai" end
  end
  return "player"
end

---------------------------------------------------------------------------
-- Supply: garrisoned and travelling units keep their supply
---------------------------------------------------------------------------
--- Supply of a force's garrisons and troop wagon manifests.
function garrison.offmap_supply(force_name)
  local n = 0
  local s = storage.garrison
  for _, c in pairs(s and s.cities or {}) do
    if c.force == force_name then n = n + (c.points or 0) end
  end
  local R = storage.rails
  for _, m in pairs(R and R.manifests or {}) do
    if m.force == force_name then n = n + (m.supply or 0) end
  end
  return n
end

do
  local base_used = supply.used
  supply.used = function(force_name) return base_used(force_name) + garrison.offmap_supply(force_name) end
end

---------------------------------------------------------------------------
-- Garrison turrets
---------------------------------------------------------------------------
local function ring_positions(center, n)
  local list = {}
  for i = 1, n do
    local a = (i - 1) / n * 2 * math.pi + math.pi / 8
    list[i] = {x = center.x + math.cos(a) * G.ring, y = center.y + math.sin(a) * G.ring}
  end
  return list
end

-- Enable one turret per points_per_turret points (create them on first use), disable the rest.
local function update_turrets(city_id)
  local c = S().cities[city_id]
  local city = cities.get(city_id)
  if not (c and city and city.entity and city.entity.valid) then return end
  local want = math.min(G.max_turrets, math.floor((c.points or 0) / G.points_per_turret))
  local surface = city.entity.surface
  if want > 0 and #c.turrets < G.max_turrets then
    for i, pos in ipairs(ring_positions(city.entity.position, G.max_turrets)) do
      if not (c.turrets[i] and c.turrets[i].valid) then
        local t = surface.create_entity({name = garrison.TURRET, position = pos, force = city.force})
        if t then
          t.destructible = false
          t.disabled_by_script = true
          c.turrets[i] = t
        end
      end
    end
  end
  local on = 0
  for i, t in ipairs(c.turrets) do
    if t.valid then
      local enable = i <= want
      if t.force.name ~= city.force then t.force = city.force end
      if t.disabled_by_script == enable then t.disabled_by_script = not enable end
      if enable then
        on = on + 1
        local inv = t.get_inventory(defines.inventory.turret_ammo)
        local have = inv and inv.get_item_count(garrison.AMMO) or 0
        if inv and have < G.ammo then inv.insert({name = garrison.AMMO, count = G.ammo - have}) end
      end
    end
  end
  c.enabled = on
end

local function destroy_turrets(c)
  for _, t in ipairs(c.turrets or {}) do
    if t.valid then t.destroy() end
  end
  c.turrets, c.enabled = {}, 0
end

---------------------------------------------------------------------------
-- Garrison: enter, sortie
---------------------------------------------------------------------------
local function center_of(city_id)
  local city = cities.get(city_id)
  local e = city and city.entity
  if e and e.valid then return e, city end
  return nil, city
end

local function absorb(city_id, rec, D)
  local c = city_rec(city_id)
  c.records[#c.records + 1] = record_of(rec, D)
  c.points = (c.points or 0) + cost_of(rec.entity.name)
  local s = S()
  s.stats.entered = s.stats.entered + 1
  if D then divisions.remove_units({rec.entity.unit_number}) end
  s.pending_units[rec.entity.unit_number] = nil
  despawn(rec)
end

-- Members of division D (or loose units) within enter_radius of the centre go in. Returns how many.
local function enter_near(city_id, recs, D)
  local center = center_of(city_id)
  if not center then return 0 end
  local p = center.position
  local r2 = G.enter_radius * G.enter_radius
  local n = 0
  for _, rec in ipairs(recs) do
    local e = rec.entity
    if e.valid then
      local q = e.position
      local dx, dy = q.x - p.x, q.y - p.y
      if dx * dx + dy * dy <= r2 then
        absorb(city_id, rec, D)
        n = n + 1
      end
    end
  end
  if n > 0 then update_turrets(city_id) end
  return n
end

local function city_of_target(target)
  if type(target) == "number" then return cities.get(target) and target or cities.of_center(target) and
    cities.of_center(target).id or nil end
  if type(target) == "table" and target.valid and target.unit_number then
    local c = cities.of_center(target.unit_number)
    return c and c.id or nil
  end
  return nil
end

--- Division `division_id` goes into the garrison of its own city `city_id` (a city id or the centre entity / unit
--- number): members near the centre enter now, the others walk there. Returns true when the order was taken.
function garrison.enter(division_id, city_id)
  if not nation() then return false end
  city_id = city_of_target(city_id) or city_id
  local D = divisions.get(division_id)
  local center, city = center_of(city_id)
  if not (D and center and city and city.force == D.force) then return false end
  local recs = divisions.live_members(D)
  local n = enter_near(city_id, recs, D)
  local s = S()
  if divisions.get(division_id) then
    divisions.order(division_id, "move", center.position)
    s.pending[division_id] = city_id
  end
  util.log("war: division #%d %s garrisons city %d (%s): %d entered at once", division_id, divisions.label(D), city_id,
    city.force, n)
  return true
end
divisions.ORDER_HOOKS.garrison = function(id, target) return garrison.enter(id, target) end

--- Loose units (LuaEntity list) go into the garrison of their own city. Returns how many were ordered.
function garrison.enter_units(entities, city_id)
  if not nation() then return 0 end
  local center, city = center_of(city_id)
  if not (center and city) then return 0 end
  local recs, walkers = {}, {}
  for _, e in ipairs(entities) do
    local rec = e.valid and units.get(e.unit_number)
    if rec and rec.force == city.force and not garrison.SKIP_KINDS[rec.kind] then recs[#recs + 1] = rec end
  end
  enter_near(city_id, recs, nil)
  local s = S()
  for _, rec in ipairs(recs) do
    if rec.entity.valid then
      walkers[#walkers + 1] = rec.entity
      s.pending_units[rec.entity.unit_number] = city_id
    end
  end
  if #walkers > 0 then orders.move(walkers, center.position) end
  return #recs
end

--- {records = {{name, kind, health, ...}}, points, turrets = enabled hidden turrets} of a city ({} records when none).
function garrison.of(city_id)
  local c = S().cities[city_id]
  if not c then return {records = {}, points = 0, turrets = 0} end
  return {records = c.records, points = c.points or 0, turrets = c.enabled or 0}
end

--- The garrison leaves the city as one division next to the centre (stance advance). Returns the division id or nil.
function garrison.sortie(city_id, why)
  local c = S().cities[city_id]
  local center, city = center_of(city_id)
  if not (c and center and city and #c.records > 0) then return nil end
  local surface = center.surface
  local p = center.position
  local list = {}
  local names, name = {}, nil
  for i, r in ipairs(c.records) do
    local a = (i - 1) / math.max(1, #c.records) * 2 * math.pi
    local e = respawn(r, city.force, surface, {x = p.x + math.cos(a) * 6, y = p.y + math.sin(a) * 6})
    if e then list[#list + 1] = e end
    if type(r.dname) == "string" then names[r.dname] = true end
  end
  if table_size(names) == 1 then name = next(names) end
  local n = #c.records
  local sp = records_sp(c.records)
  c.records, c.points = {}, 0
  update_turrets(city_id)
  local s = S()
  s.stats.sorties = s.stats.sorties + 1
  local id = #list > 0 and divisions.create(city.force, list, {name = name, stance = "advance"},
    {owner = owner_of(city.force)}) or nil
  if id then divisions.get(id).sp = sp end
  util.log("war: city %d (%s) garrison sortie (%s): %d records, %d units, division #%s", city_id, city.force,
    why or "order", n, #list, tostring(id))
  return id
end

--- capture.lua: the centre took damage; below sortie_health the garrison comes out by itself.
function garrison.on_center_damaged(city_id, center)
  local c = storage.garrison and storage.garrison.cities[city_id]
  if c and #c.records > 0 and center.health < center.max_health * G.sortie_health then
    garrison.sortie(city_id, "the centre is below " .. math.floor(G.sortie_health * 100) .. " %")
  end
end

--- capture.lua: the city changed hands; its garrison is lost and its turrets go.
function garrison.on_captured(city_id, old, new)
  local s = S()
  local c = s.cities[city_id]
  if c then
    util.log("war: city %d captured by %s: the garrison of %s is lost (%d records, %d points)", city_id, new, old,
      #c.records, c.points or 0)
    local st = match.stats(old)
    if st and #c.records > 0 then st.units_lost = (st.units_lost or 0) + #c.records end
    destroy_turrets(c)
    s.cities[city_id] = nil
  end
  for id, cid in pairs(s.pending) do
    if cid == city_id then s.pending[id] = nil end
  end
  for un, cid in pairs(s.pending_units) do
    if cid == city_id then s.pending_units[un] = nil end
  end
end

---------------------------------------------------------------------------
-- Troop trains: boarding
---------------------------------------------------------------------------
local function troop_wagons(train)
  local list = {}
  for _, w in ipairs(train.cargo_wagons) do
    if w.name == garrison.TWAGON then list[#list + 1] = w end
  end
  return list
end

-- The manifest of a wagon; `create` makes it (only when someone boards: no empty manifests).
local function manifest_of(wagon, force, create)
  local M = manifests()
  local m = M[wagon.unit_number]
  if not m and create then
    m = {force = force, wagon = wagon, records = {}, supply = 0}
    M[wagon.unit_number] = m
  end
  return m
end

local function recount_aboard()
  local counts = {}
  for _, m in pairs(manifests()) do
    for _, r in ipairs(m.records) do
      if r.division then counts[r.division] = (counts[r.division] or 0) + 1 end
    end
  end
  for id, D in pairs(storage.divisions or {}) do
    local n = counts[id] or 0
    if (D.aboard or 0) ~= n then D.aboard = n > 0 and n or nil end
  end
end

-- Inside a depot's platform area (with a margin).
local function on_platform(d, pos)
  local a = d.platform and d.platform.area
  if not a then return false end
  return pos.x >= a[1][1] - 4 and pos.x <= a[2][1] + 4 and pos.y >= a[1][2] - 4 and pos.y <= a[2][2] + 4
end

--- The troop train of `force` standing at depot `depot_un` (record, LuaTrain), or nil.
function garrison.troop_train_at(force, depot_un)
  local d = rails.depot(depot_un)
  if not d then return nil end
  local R = storage.rails
  local ids = {}
  for id in pairs(R and R.trains or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local rec = R.trains[id]
    if rec.kind == "troop" and rec.force == force then
      local train = rails.train_of(rec)
      if train and train.valid and train.speed == 0 and train.front_stock and on_platform(d, train.front_stock.position)
      then
        return rec, train
      end
    end
  end
  return nil
end

-- Where boarding units wait: beside the track on the far side from the depot (trains kill units on the rails), next to
-- the troop wagon of a train standing there, else beside the platform's middle.
local function boarding_spot(d, train)
  local p = d.platform
  local a = p and p.area
  if not a then return d.entity.position end
  local along
  local w = train and troop_wagons(train)[1]
  if w then
    along = p.axis == "x" and w.position.x or w.position.y
  else
    along = p.axis == "x" and (a[1][1] + a[2][1]) / 2 or (a[1][2] + a[2][2]) / 2
  end
  local off = p.track + (p.side or 1) * W.disembark_ring
  if p.axis == "x" then return {x = along, y = off} end
  return {x = off, y = along}
end

-- Phase 5 M2 QA round 1 (step 21): a troop train of `force` that comes to depot `depot_un` (its pickup or drop-off).
local function troop_train_coming(force, depot_un)
  local R = storage.rails
  for _, id in ipairs(sorted_keys(R and R.trains)) do
    local rec = R.trains[id]
    if rec.kind == "troop" and rec.force == force and (rec.pickup == depot_un or rec.dropoff == depot_un)
       and rails.train_of(rec) then
      return rec
    end
  end
  return nil
end

--- Phase 5 M2 QA round 1 (step 21): can units of `force` board at depot `depot_un`? True when a troop train stands
--- there, one can be deployed there now, or one is routed through it; else false and the reason (rails.deploy_check's).
function garrison.can_embark(force, depot_un)
  local d = rails.depot(depot_un)
  if not (d and d.force == force) then return false, "no-depot" end
  if not d.platform then return false, "no-platform" end
  if garrison.troop_train_at(force, depot_un) or troop_train_coming(force, depot_un) then return true end
  local why = rails.deploy_check(depot_un, "troop")
  if why then return false, why end
  return true
end

--- Division `id` boards a troop train at depot `depot_un` (unit number or the depot entity): it walks to the platform;
--- a troop train is deployed there from kits when none stands there. Returns true when the order was taken; false and
--- the reason when no troop train stands there, none can be deployed and none comes (the division stays as it was and
--- its card reads "No troop train" for a while).
function garrison.embark(id, depot_un)
  if not nation() then return false end
  if type(depot_un) == "table" and depot_un.valid then depot_un = depot_un.unit_number end
  local D = divisions.get(id)
  local d = rails.depot(depot_un)
  if not (D and d and d.force == D.force and d.platform) then return false end
  local rec = garrison.troop_train_at(D.force, depot_un)
  if not rec and not troop_train_coming(D.force, depot_un) then
    local train, why = rails.create_train(depot_un, "troop")
    if train then
      S().stats.trains = S().stats.trains + 1
      util.log("war: troop train %d deployed at depot #%d for division #%d", train.id, depot_un, id)
    else
      -- Phase 5 M2 QA round 1 (step 21): no train, none to deploy, none coming: the card said "Boarding a train" for a
      -- minute while the walkers stood on the platform track (and kept the next train from being placed)
      D.no_train = {depot = depot_un, why = why, tick = game.tick}
      util.log("war: division #%d %s cannot embark at depot #%d: no troop train (%s)", id, divisions.label(D), depot_un,
        tostring(why))
      return false, why
    end
  end
  local _, standing = garrison.troop_train_at(D.force, depot_un)
  divisions.order(id, "move", boarding_spot(d, standing))
  D.embark = {depot = depot_un, tick = game.tick, train = standing and standing.id or nil}
  D.no_train = nil
  util.log("war: division #%d %s embarks at depot #%d%s", id, divisions.label(D), depot_un,
    standing and "" or " (its troop train is on the way)")
  return true
end
divisions.ORDER_HOOKS.embark = function(id, target) return garrison.embark(id, target) end

-- Members of D near a troop wagon of `train` board while the wagons have room. Returns how many boarded.
local function board(D, rec, train)
  local wagons = troop_wagons(train)
  if #wagons == 0 then return 0 end
  local r2 = W.embark_radius * W.embark_radius
  local n = 0
  for _, urec in ipairs(divisions.live_members(D)) do
    local e = urec.entity
    local q = e.position
    local cost = cost_of(e.name)
    for _, w in ipairs(wagons) do
      local m = manifest_of(w, D.force)
      local wp = w.position
      local dx, dy = q.x - wp.x, q.y - wp.y
      if (m and m.supply or 0) + cost <= TW.capacity and dx * dx + dy * dy <= r2 then
        m = m or manifest_of(w, D.force, true)
        m.records[#m.records + 1] = record_of(urec, D)
        m.supply = m.supply + cost
        D.aboard = (D.aboard or 0) + 1
        despawn(urec)
        n = n + 1
        break
      end
    end
  end
  if n > 0 then
    local s = S()
    s.stats.boarded = s.stats.boarded + n
    rec.boarded_tick = game.tick
    rec.manifest_units = (rec.manifest_units or 0) + n
    util.log("war: %d unit(s) of division #%d %s boarded troop train %d (%d aboard)", n, D.id, divisions.label(D),
      train.id, D.aboard or 0)
  end
  return n
end

local function train_load(train)
  local n, sup = 0, 0
  for _, w in ipairs(troop_wagons(train)) do
    local m = manifests()[w.unit_number]
    if m then
      n = n + #m.records
      sup = sup + m.supply
    end
  end
  return n, sup, #troop_wagons(train) * TW.capacity
end
garrison.train_load = train_load

-- Divisions still walking to board at a depot (live members on the map).
local function embarking(force, depot_un)
  local list = {}
  for _, D in ipairs(divisions.for_force(force)) do
    if D.embark and D.embark.depot == depot_un and (D.n or 1) > 0 and next(D.units) then list[#list + 1] = D end
  end
  return list
end

---------------------------------------------------------------------------
-- Troop trains: disembark
---------------------------------------------------------------------------
-- Positions on the far side of the track from the depot (or around the wagon without a platform).
local function exit_spot(train, i, n)
  local w = train.front_stock
  local pos = w.position
  local R = storage.rails
  local d
  for _, un in ipairs(sorted_keys(R and R.depots)) do
    local dd = R.depots[un]
    if dd.platform and on_platform(dd, pos) then
      d = dd
      break
    end
  end
  local ring = W.disembark_ring
  if d and d.platform then
    local p = d.platform
    local a = p.area
    local span = (p.axis == "x") and (a[2][1] - a[1][1]) or (a[2][2] - a[1][2])
    local t = (i - 0.5) / math.max(1, n)
    local along = (p.axis == "x" and a[1][1] or a[1][2]) + 4 + t * (span - 8)
    local off = p.track + (p.side or 1) * ring
    if p.axis == "x" then return {x = along, y = off}, {x = along, y = off + (p.side or 1) * 8} end
    return {x = off, y = along}, {x = off + (p.side or 1) * 8, y = along}
  end
  local a = (i - 1) / math.max(1, n) * 2 * math.pi
  return {x = pos.x + math.cos(a) * ring, y = pos.y + math.sin(a) * ring}, nil
end

-- Every manifest of `train` gets out next to it. Returns the number of units re-created.
local function disembark(train, why)
  local M = manifests()
  local made = 0
  local by_div = {}
  local all = {}
  for _, w in ipairs(troop_wagons(train)) do
    local m = M[w.unit_number]
    if m then
      for _, r in ipairs(m.records) do all[#all + 1] = {r = r, force = m.force} end
      M[w.unit_number] = nil
    end
  end
  if #all == 0 then return 0 end
  local surface = train.front_stock.surface
  local clear = {}
  for i, item in ipairs(all) do
    local spot, beyond = exit_spot(train, i, #all)
    local e = respawn(item.r, item.force, surface, spot)
    if e then
      made = made + 1
      local id = item.r.division
      local key = id or 0
      by_div[key] = by_div[key] or {force = item.force, list = {}, r = item.r, recs = {}}
      by_div[key].list[#by_div[key].list + 1] = e
      by_div[key].recs[#by_div[key].recs + 1] = item.r
      if beyond then clear[key] = beyond end
    end
  end
  recount_aboard()
  local keys = {}
  for k in pairs(by_div) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local grp = by_div[key]
    local id = key ~= 0 and key or nil
    if id and divisions.get(id) then
      divisions.attach(id, grp.list, "disembarked from troop train " .. train.id)
      divisions.get(id).embark = nil
    else
      id = divisions.create(grp.force, grp.list, {name = type(grp.r.dname) == "string" and grp.r.dname or nil,
        composition = grp.r.template and grp.r.template.composition or nil, stance = grp.r.stance or "hold"},
        {owner = owner_of(grp.force)})
      if id then divisions.get(id).sp = records_sp(grp.recs) end
    end
    if id and clear[key] then divisions.order(id, "move", clear[key]) end
  end
  local s = S()
  s.stats.disembarked = s.stats.disembarked + made
  util.log("war: troop train %d: %d unit(s) disembarked at %s (%s)", train.id, made,
    util.pos_str(train.front_stock.position), why or "-")
  return made
end
garrison.disembark = disembark

---------------------------------------------------------------------------
-- rails.lua hooks
---------------------------------------------------------------------------
-- A troop train standing at one of its stops (every rails.TRANSFER_PERIOD ticks).
rails.troop_dwell = function(rec, train)
  local d = rec.dwell
  if not d then return end
  local n, sup, cap = train_load(train)
  if d.role == "dropoff" then
    if n > 0 then
      rec.state = "unloading"
      disembark(train, "drop-off depot #" .. d.depot)
      rec.trips = (rec.trips or 0) + 1
    end
    if rec.pickup then rails.depart_train(train, 1, "troops out") end
    return
  end
  if d.role ~= "pickup" then
    if rec.pickup then rails.depart_train(train, 1, "not on its route") end
    return
  end
  -- pickup: wait for the divisions walking here; leave when they are aboard, the wagons are full or the wait is over
  local waiting = #embarking(rec.force, d.depot)
  rec.state = n > 0 and "loading" or "waiting"
  if n == 0 then
    rec.reason = waiting > 0 and nil or "nothing"
    return
  end
  if not rec.dropoff then
    rec.reason = "no-route"
    return
  end
  rec.reason = nil
  local since = game.tick - (rec.boarded_tick or d.since)
  if waiting == 0 or sup >= cap or since >= W.embark_wait then
    util.log("war: troop train %d leaves depot #%d with %d units (%d / %d supply)%s", train.id, d.depot, n, sup, cap,
      waiting > 0 and string.format(", %d division(s) left behind", waiting) or "")
    rails.depart_train(train, 2, "troops aboard")
  end
end

-- A carriage of a recorded train died: a troop wagon kills its manifest.
rails.on_stock_died = function(rec, entity, cause)
  if entity.name ~= garrison.TWAGON then return end
  local M = manifests()
  local m = M[entity.unit_number]
  if not m then return end
  M[entity.unit_number] = nil
  local n = #m.records
  recount_aboard()
  for id, D in pairs(storage.divisions or {}) do
    if not D.aboard and next(D.units) == nil then divisions.disband(id, "its units died in a troop wagon") end
  end
  local st = match.stats(m.force)
  if st then st.units_lost = (st.units_lost or 0) + n end
  local s = S()
  s.stats.lost_in_wagons = s.stats.lost_in_wagons + n
  util.log("war: troop wagon #%d of %s destroyed at %s by %s: %d unit(s) aboard lost", entity.unit_number, m.force,
    util.pos_str(entity.position), cause and cause.valid and cause.name or "unknown", n)
  supply.alert(m.force, "troop-wagon-lost", "rts-war.alert-troop-wagon-lost", {n}, entity.position)
end

-- Before a train is disbanded: troops get out first.
rails.on_disband = function(rec, train)
  if rec.kind == "troop" then disembark(train, "train disbanded") end
end

-- The troop line of the train panel (railgui.lua).
rails.troop_text = function(rec)
  local train = rails.train_of(rec)
  if not train then return nil end
  local n, sup, cap = train_load(train)
  return {"rts-war.troop-aboard", n, sup, cap}
end

---------------------------------------------------------------------------
-- Poll: boarding, garrison entry, stranded troop trains, turret ammo
---------------------------------------------------------------------------
events.on_nth_tick(garrison.POLL, function(e)
  if not nation() then return end
  local s = S()
  -- boarding
  local l = storage.divisions
  if l then
    local ids = {}
    for id, D in pairs(l) do
      if D.embark then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local D = l[id]
      local rec, train = garrison.troop_train_at(D.force, D.embark.depot)
      if rec then
        board(D, rec, train)
        local emb = D.embark
        if emb and emb.train ~= train.id and next(D.units) then
          -- a troop train arrived after the order: the rest walks to its wagon
          local d = rails.depot(emb.depot)
          divisions.order(id, "move", boarding_spot(d, train))
          emb.train = train.id
          D.embark = emb
        end
      elseif not rails.depot(D.embark.depot) then
        D.embark = nil
      end
    end
  end
  -- garrison entry
  if next(s.pending) then
    local ids = {}
    for id in pairs(s.pending) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local D = divisions.get(id)
      local city_id = s.pending[id]
      if not D or not cities.get(city_id) then
        s.pending[id] = nil
      else
        enter_near(city_id, divisions.live_members(D), D)
        if not divisions.get(id) then s.pending[id] = nil end
      end
    end
  end
  if next(s.pending_units) then
    local by_city = {}
    for un, city_id in pairs(s.pending_units) do
      local rec = units.get(un)
      if rec then
        by_city[city_id] = by_city[city_id] or {}
        table.insert(by_city[city_id], rec)
      else
        s.pending_units[un] = nil
      end
    end
    for city_id, recs in pairs(by_city) do
      table.sort(recs, function(a, b) return a.entity.unit_number < b.entity.unit_number end)
      enter_near(city_id, recs, nil)
    end
  end
  -- troop trains without a locomotive let their troops out; manifests of vanished wagons go
  local M = manifests()
  if next(M) then
    local keys = {}
    for k in pairs(M) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local m = M[k]
      if m and not (m.wagon and m.wagon.valid) then
        M[k] = nil
        util.log("war: manifest of wagon #%d (%s) dropped: the wagon is gone (%d records)", k, m.force, #m.records)
        recount_aboard()
      elseif m then
        local train = m.wagon.train
        local locos = train and (#train.locomotives.front_movers + #train.locomotives.back_movers) or 0
        if train and locos == 0 then disembark(train, "the train lost its locomotives") end
      end
    end
  end
  -- garrison turrets: ammo
  if e.tick >= s.next_ammo then
    s.next_ammo = e.tick + G.ammo_period
    local ids = {}
    for id in pairs(s.cities) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local c = s.cities[id]
      local city = cities.get(id)
      if not city then
        destroy_turrets(c)
        s.cities[id] = nil
      elseif (c.enabled or 0) > 0 or (c.points or 0) >= G.points_per_turret then
        c.force = city.force
        update_turrets(id)
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Right click: own City Center = garrison, own depot or its platform = embark (Nation mode)
---------------------------------------------------------------------------
local function own_city_at(player_index, force, position, entities)
  for _, e in pairs(entities or {}) do
    if e.valid and e.unit_number and e.force.name == force then
      local c = cities.of_center(e.unit_number)
      if c then return c end
    end
  end
  local un = selection.building_at(player_index, position)
  local c = un and cities.of_center(un)
  if c and c.force == force then return c end
  return nil
end

-- Phase 5 M2 QA round 1: a click counts as "on the platform" within this many tiles of its track (the platform area
-- reaches 4 tiles out: a right click visibly below the rails made two divisions board)
local PLATFORM_HIT = 2.5

local function own_depot_at(player_index, force, position, entities)
  for _, e in pairs(entities or {}) do
    if e.valid and e.unit_number and e.force.name == force and rails.depot(e.unit_number) then return e.unit_number end
  end
  local un, rec = selection.building_at(player_index, position)
  if rec and rails.depot(un) then return un end
  local R = storage.rails
  local x, y = util.xy(position)
  for _, k in ipairs(sorted_keys(R and R.depots)) do
    local d = R.depots[k]
    local p = d.platform
    if d.force == force and d.entity.valid and p then
      local a = p.area
      local along, across = x, y
      local lo, hi = a[1][1], a[2][1]
      if p.axis ~= "x" then along, across, lo, hi = y, x, a[1][2], a[2][2] end
      if along >= lo and along <= hi and math.abs(across - p.track) <= PLATFORM_HIT then return k end
    end
  end
  return nil
end

function garrison.right_click(player_index, position, entities, alt)
  if alt or not nation() then return nil end
  if selection.count(player_index) == 0 then return nil end
  -- Phase 5 M2 QA round 1: with F armed the right click is an attack-move (it made two divisions board a train)
  if orders.is_armed(player_index) then return nil end
  local force = selection.force_name(player_index)
  local city = own_city_at(player_index, force, position, entities)
  local depot = not city and own_depot_at(player_index, force, position, entities) or nil
  if not (city or depot) then return nil end
  local ents = selection.get(player_index)
  local p = util.pstorage(player_index)
  local whole = selection.whole_divisions(p.selection or {})
  local loose = {}
  for _, e in ipairs(ents) do
    local rec = storage.units[e.unit_number]
    if rec and not garrison.SKIP_KINDS[rec.kind] then
      local id = divisions.of_unit(e.unit_number)
      if not (id and whole[id]) then loose[#loose + 1] = e end
    end
  end
  local ids = {}
  for id in pairs(whole) do ids[#ids + 1] = id end
  table.sort(ids)
  local n = 0
  if city then
    for _, id in ipairs(ids) do
      local k = #divisions.members(id)
      if divisions.order(id, "garrison", city.id) then n = n + k end
    end
    if #loose > 0 then n = n + garrison.enter_units(loose, city.id) end
    util.log("order garrison city=%d n=%d divisions=%d player=%d", city.id, n, #ids, player_index)
    return "garrison", n
  end
  -- Phase 5 M2 QA round 1: without a troop train to board the units stay as they are (no new division, no walk)
  local ok, why = garrison.can_embark(force, depot)
  if not ok then
    for _, id in ipairs(ids) do
      local D = divisions.get(id)
      if D then D.no_train = {depot = depot, why = why, tick = game.tick} end -- the card reads "No troop train"
    end
    local player = game.get_player(player_index)
    if player then
      player.create_local_flying_text({text = {"rts-war.embark-no-train", {"rts.rails-why-" .. tostring(why)}},
                                       position = position, color = {1, 0.85, 0.3}})
    end
    util.log("order embark depot=#%d refused (%s) player=%d", depot, tostring(why), player_index)
    return "embark", 0
  end
  if #loose > 0 then
    local id = divisions.create(force, loose, {stance = "hold"}, {owner = "player"})
    if id then ids[#ids + 1] = id end
  end
  for _, id in ipairs(ids) do
    local k = #divisions.members(id)
    if divisions.order(id, "embark", depot) then n = n + k end
  end
  util.log("order embark depot=#%d n=%d divisions=%d player=%d", depot, n, #ids, player_index)
  return "embark", n
end
orders.on_right_click(garrison.right_click)

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------
match.on_teardown(function()
  local s = storage.garrison
  for _, c in pairs(s and s.cities or {}) do destroy_turrets(c) end
  storage.garrison = nil
  S()
  if storage.rails then storage.rails.manifests = {} end
end)

--- One line for logs: "garrison: 2 cities (14 points), 1 manifest (8 units), boarded 12, disembarked 12, lost 0".
function garrison.describe()
  local s = S()
  local nc, pts = 0, 0
  for _, c in pairs(s.cities) do
    if (c.points or 0) > 0 then
      nc = nc + 1
      pts = pts + c.points
    end
  end
  local nm, nu = 0, 0
  for _, m in pairs(manifests()) do
    nm = nm + 1
    nu = nu + #m.records
  end
  return string.format("garrison: %d cities (%d points), %d manifests (%d units), boarded %d, disembarked %d, lost %d",
    nc, pts, nm, nu, s.stats.boarded, s.stats.disembarked, s.stats.lost_in_wagons)
end

return garrison
