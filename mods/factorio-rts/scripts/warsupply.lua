-- Phase 5 M2 war: supply points, depots and supply crates (docs/PHASE5-M2.md section 3 "warsupply.lua"; study
-- docs/research/scale/war-ai-performance.md section 2.2; notes docs/qa/phase5-war-notes.md). Nation mode only: in
-- Skirmish every division is "supplied", nothing is consumed, no order is refused and the recipes stay disabled.
--
-- Supply points (SP). Every division has D.sp (0..sp_max, storage.divisions[id].sp). Each division is looked at every
-- STEP ticks (staggered by id): it uses balance.nation.war.use SP per minute (idle 0, moving 2, engaged 8 when a member
-- hit or was hit within engaged_ticks; +2 on foreign land) and, within refill.range tiles (2 chunks) of a depot of its
-- force whose logistic network holds supply crates, regains refill.per_minute SP per minute, paying 1 crate per
-- refill.sp_per_crate SP from that network (a crate is taken when the division's credit runs out, so a refill of 20 SP
-- costs exactly 2 crates).
-- Depots: every building of kind "cc" or "hub" of the force: the Command Center, City Centers, hubs, rail depots and
-- field depots (rts-field-depot, a cheap hub subtype the Commander builds; it keeps 20 crates by default and adds no
-- supply cap).
-- States: supplied (>= low), low (1 .. low - 1), out (0).
--   low: Armor II/III heals nothing (this module takes back what scripts/research.lua's heal added), the division card
--        shows an amber supply bar, and the AI starts no offensive with it (scripts/ai/army.lua).
--   out: 1.5 % of max health every 10 s (a health write, die() at 0) and attack orders are refused (divisions.order_lock
--        for division orders, orders.unit_lock for orders to units).
-- A unit outside any division takes the state of the nearest division of its force within loose_radius (24) tiles of
-- it, else it is always supplied. A division keeps the SP of its units: a unit that leaves a division remembers the
-- division's SP (storage.warsupply.unit_sp), and a division formed or joined by such units starts at their average, so
-- disbanding and forming again does not refill anything. New units come with sp_start.
--
-- Crates: the factory makes rts-supply-crate (Age I: 4 iron plates + 2 coal; from Age II rts-supply-crate-ii, which
-- also needs 1 explosives, replaces it; crates of both recipes are the same item). This module enables the recipes per
-- force in a Nation match (and the troop wagon kit once the force has Railways) and disables them in Skirmish.
--
-- Owns storage.warsupply = {unit_sp = {[unit_number] = sp}, loose = {[unit_number] = "low" | "out"},
--   depots = {[force] = {[unit_number] = true}}, field_index = {[force] = n}, ai = {[force] = {next}},
--   stats = {[force] = {crates, refilled, used, out_hits, out_kills, refused}}}, cleared by match teardown.
-- Log lines "[rts] war: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local supply = require("scripts.supply")
local territory = require("scripts.territory")
local research = require("scripts.research")
local balance = require("balance")

local warsupply = {}

local W = balance.nation.war
warsupply.CRATE = "rts-supply-crate"
warsupply.CRATE_RECIPE = "rts-supply-crate"
warsupply.CRATE2_RECIPE = "rts-supply-crate-ii"
warsupply.FIELD_DEPOT = "rts-field-depot"
warsupply.TROOP_KIT_RECIPE = "rts-troop-wagon-kit"
warsupply.STEP = 60              -- each division is looked at this often (ticks)
warsupply.CHECK_PERIOD = 15      -- controller tick (divisions due in this tick are stepped)
warsupply.LOOSE_PERIOD = 60      -- loose units' states are recomputed this often
warsupply.RECIPE_PERIOD = 600    -- recipe switches per force
local DEPOT_KINDS = {cc = true, hub = true}
-- Phase 5 M3 air (scripts/air.lua): fn(entity) -> true for a unit with its own supply (a plane). Its hits never make
-- its division engaged, the out-of-supply wear skips it, no attack order is refused to it, and a division of such units
-- neither uses nor refills supply points.
warsupply.exempt = nil
local function exempt(entity) return warsupply.exempt ~= nil and warsupply.exempt(entity) end
local UNIT_TYPES = {"unit", "spider-unit"}

buildings.KIND_BY_NAME[warsupply.FIELD_DEPOT] = "hub"
territory.CLASS_BY_NAME[warsupply.FIELD_DEPOT] = "outpost" -- own or neutral land, like a hub or a depot

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.warsupply
  if not s then
    s = {}
    storage.warsupply = s
  end
  s.unit_sp = s.unit_sp or {}
  s.loose = s.loose or {}
  s.depots = s.depots or {}
  s.field_index = s.field_index or {}
  s.ai = s.ai or {}
  s.stats = s.stats or {}
  return s
end

function warsupply.init() S() end

--- True in a running Nation-mode match (the rules apply).
function warsupply.nation()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation" and m.surface ~= nil
end
local nation = warsupply.nation

local function stats(force)
  local all = S().stats
  local st = all[force]
  if not st then
    st = {crates = 0, refilled = 0, used = 0, out_hits = 0, out_kills = 0, refused = 0}
    all[force] = st
  end
  return st
end
warsupply.stats = stats

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
local function state_of(sp)
  if sp == nil then return "supplied" end
  if sp <= 0 then return "out" end
  if sp < W.low then return "low" end
  return "supplied"
end
warsupply.state_of = state_of

--- Supply points of a division (0..100); sp_max outside Nation mode or for an unknown division.
function warsupply.sp(division_id)
  local D = divisions.get(division_id)
  if not (D and nation()) then return W.sp_max end
  return D.sp or W.sp_start
end

--- "supplied" (>= 50) | "low" (1-49) | "out" (0). Always "supplied" outside Nation mode.
function warsupply.state(division_id)
  if not nation() then return "supplied" end
  local D = divisions.get(division_id)
  return D and state_of(D.sp or W.sp_start) or "supplied"
end

--- State of a unit entity: its division's, else (loose) the nearest division's within loose_radius, else "supplied".
function warsupply.unit_state(entity)
  if not (entity and entity.valid and nation()) then return "supplied" end
  local un = entity.unit_number
  local id = un and divisions.of_unit(un)
  if id then
    local D = divisions.get(id)
    return state_of(D and D.sp or W.sp_start)
  end
  return S().loose[un] or "supplied"
end

--- Unit numbers of the force's depots (Command Center, City Centers, hubs, rail and field depots), sorted.
function warsupply.depots(force)
  local f = type(force) == "string" and force or force.name
  local out = {}
  for un in pairs(S().depots[f] or {}) do
    local rec = buildings.get(un)
    if rec and rec.force == f and DEPOT_KINDS[rec.kind] then out[#out + 1] = un end
  end
  table.sort(out)
  return out
end

--- Crates in a depot's logistic network (0 without one).
function warsupply.depot_crates(un)
  local rec = buildings.get(un)
  local net = rec and rec.entity.logistic_network
  return (net and net.valid) and net.get_item_count(warsupply.CRATE) or 0
end

---------------------------------------------------------------------------
-- Depot registry (buildings of kind cc / hub)
---------------------------------------------------------------------------
local function add_depot(un, rec)
  if not DEPOT_KINDS[rec.kind] then return end
  local d = S().depots
  d[rec.force] = d[rec.force] or {}
  d[rec.force][un] = true
end

local function drop_depot(un, force)
  local d = S().depots[force]
  if d then d[un] = nil end
end

buildings.on_added(function(un, rec)
  add_depot(un, rec)
  if rec.entity.valid and rec.entity.name == warsupply.FIELD_DEPOT then
    -- a field depot keeps crates, not the hub's plates (logistics.lua made the hub policy just before)
    local pol = logistics.policy(un)
    if pol and not pol.war_defaults then
      pol.war_defaults = true
      for item in pairs(pol.keep) do logistics.set_policy(un, "keep", item, nil) end
      logistics.set_policy(un, "keep", warsupply.CRATE, W.field_depot.keep)
    end
    local s = S()
    if not s.field_number then s.field_number = {} end
    if not s.field_number[un] then
      s.field_index[rec.force] = (s.field_index[rec.force] or 0) + 1
      s.field_number[un] = s.field_index[rec.force]
    end
    util.log("war: field depot #%d (%d) of %s at %s", un, s.field_number[un], rec.force, util.pos_str(rec.position))
  end
end)
buildings.on_removed(function(un, rec) drop_depot(un, rec.force) end)
buildings.on_force_changed(function(un, rec, old)
  drop_depot(un, old)
  add_depot(un, rec)
end)

logistics.NAME_HOOKS[warsupply.FIELD_DEPOT] = function(un)
  local s = storage.warsupply
  local n = s and s.field_number and s.field_number[un]
  return {"rts-war.field-depot-name", n or un}
end

-- Field depots are hubs for logistics (kind "hub"), but they add no supply cap (scripts/supply.lua counts every hub).
supply.on_cap(function(force_name)
  local s = storage.warsupply
  if not (s and s.depots and s.depots[force_name]) then return 0 end
  local n = 0
  for un in pairs(s.depots[force_name]) do
    local rec = storage.buildings[un]
    if rec and rec.entity.valid and rec.entity.name == warsupply.FIELD_DEPOT then n = n + 1 end
  end
  return -n * supply.HUB_CAP
end)

---------------------------------------------------------------------------
-- SP of units between divisions (no refill by disbanding and forming again)
---------------------------------------------------------------------------
local function snapshot(D)
  local set = {}
  for un in pairs(D.units) do set[un] = true end
  D.sp_members = set
end

local function sorted_units(set)
  local list = {}
  for un in pairs(set) do list[#list + 1] = un end
  table.sort(list)
  return list
end

divisions.on_changed(function(D, what)
  local s = S()
  if what == "created" then
    local sum, n = 0, 0
    -- Phase 5 M3 integration (perf notes open issue 9): sums in unit-number order (a float sum depends on the order)
    for _, un in ipairs(sorted_units(D.units)) do
      sum, n = sum + (s.unit_sp[un] or W.sp_start), n + 1
      s.unit_sp[un] = nil
    end
    D.sp = n > 0 and sum / n or W.sp_start
    D.sp_credit = 0
    snapshot(D)
  elseif what == "members" then
    local old = D.sp_members or {}
    local sp = D.sp or W.sp_start
    local stay, sum_new, n_new = 0, 0, 0
    for _, un in ipairs(sorted_units(D.units)) do -- Phase 5 M3 integration: unit-number order
      if old[un] then
        stay = stay + 1
      else
        sum_new, n_new = sum_new + (s.unit_sp[un] or W.sp_start), n_new + 1
        s.unit_sp[un] = nil
      end
    end
    for un in pairs(old) do
      if not D.units[un] and storage.units and storage.units[un] then s.unit_sp[un] = sp end -- it left alive
    end
    if n_new > 0 then D.sp = (sp * stay + sum_new) / (stay + n_new) end
    snapshot(D)
  elseif what == "disbanded" then
    local sp = D.sp or W.sp_start
    for un in pairs(D.units) do
      if storage.units and storage.units[un] then s.unit_sp[un] = sp end
    end
  end
end)

units.on_removed(function(un)
  local s = storage.warsupply
  if s then
    if s.unit_sp then s.unit_sp[un] = nil end
    if s.loose then s.loose[un] = nil end
  end
end)

---------------------------------------------------------------------------
-- The division step
---------------------------------------------------------------------------
local function nearest_depot_with_crates(force, pos)
  local list = S().depots[force]
  if not list then return nil end
  local r2 = W.refill.range * W.refill.range
  local cands = {}
  for un in pairs(list) do
    local rec = storage.buildings[un]
    if rec and rec.entity.valid then
      local p = rec.position
      local dx, dy = p.x - pos.x, p.y - pos.y
      local d2 = dx * dx + dy * dy
      if d2 <= r2 then cands[#cands + 1] = {un = un, d2 = d2, entity = rec.entity} end
    end
  end
  table.sort(cands, function(a, b)
    if a.d2 ~= b.d2 then return a.d2 < b.d2 end
    return a.un < b.un
  end)
  for _, c in ipairs(cands) do
    local net = c.entity.logistic_network
    if net and net.valid and net.get_item_count(warsupply.CRATE) > 0 then return c.un, net end
  end
  return nil
end

local function alert_state(D, old, new)
  local label = divisions.label(D)
  util.log("war: division #%d %s (%s) supply %s -> %s (%.1f SP) at %s", D.id, label, D.force, old, new, D.sp or 0,
    util.pos_str(D.pos))
  if new == "out" or (new == "low" and old == "supplied") then
    local key = new == "out" and "rts-war.alert-supply-out" or "rts-war.alert-supply-low"
    supply.alert(D.force, new == "out" and "supply-out" or "supply-low", key, {D.name}, D.pos)
  end
end

--- One supply step of division D over `dt` ticks. Returns the SP change.
function warsupply.step_division(D, dt)
  local n = divisions.strength(D)
  if n == 0 or not D.pos then return 0 end
  if warsupply.exempt then -- Phase 5 M3 air: an all-plane division neither uses nor refills supply points
    local own = false
    for un in pairs(D.units) do
      local rec = storage.units and storage.units[un]
      if rec and rec.entity.valid and not exempt(rec.entity) then
        own = true
        break
      end
    end
    if not own then return 0 end
  end
  local tick = game.tick
  local minutes = dt / 3600
  local use = W.use
  local rate
  if D.engaged_tick and tick - D.engaged_tick <= W.engaged_ticks then
    rate = use.engaged
  elseif D.state == "moving" or D.state == "settling" then
    rate = use.moving
  else
    rate = use.idle
  end
  local owner = territory.owner_at(D.pos)
  if owner and owner ~= D.force then rate = rate + use.enemy_land end
  local before = D.sp or W.sp_start
  local sp = before - rate * minutes
  local st = stats(D.force)
  st.used = st.used + rate * minutes
  if sp < W.sp_max then
    local un, net = nearest_depot_with_crates(D.force, D.pos)
    if un then
      local want = math.min(W.refill.per_minute * minutes, W.sp_max - sp)
      local credit = D.sp_credit or 0
      while credit < want do
        local got = net.remove_item({name = warsupply.CRATE, count = 1})
        if got < 1 then break end
        credit = credit + W.refill.sp_per_crate
        st.crates = st.crates + 1
        D.crates = (D.crates or 0) + 1
      end
      local add = math.min(want, credit)
      D.sp_credit = credit - add
      sp = sp + add
      st.refilled = st.refilled + add
      D.depot = un
    else
      D.depot = nil
    end
  end
  if sp < 0 then sp = 0 elseif sp > W.sp_max then sp = W.sp_max end
  D.sp = sp
  local old, new = state_of(before), state_of(sp)
  if old ~= new then alert_state(D, old, new) end
  return sp - before
end

--- Every division due: SP use and refill (tests call it to step all divisions at once with dt).
function warsupply.refill_step(dt)
  if not nation() then return 0 end
  local l = storage.divisions
  if not l then return 0 end
  local ids = {}
  for id in pairs(l) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local D = l[id]
    if D then
      D.sp_tick = game.tick
      warsupply.step_division(D, dt or warsupply.STEP)
    end
  end
  return #ids
end

events.on_nth_tick(warsupply.CHECK_PERIOD, function(e)
  local l = storage.divisions
  if not (l and next(l)) or not nation() then return end
  local due = {}
  for id, D in pairs(l) do
    if not D.sp_tick then D.sp_tick = e.tick - (id * warsupply.CHECK_PERIOD) % warsupply.STEP end
    if e.tick - D.sp_tick >= warsupply.STEP then due[#due + 1] = id end
  end
  table.sort(due)
  for _, id in ipairs(due) do
    local D = l[id]
    if D then
      local dt = e.tick - D.sp_tick
      D.sp_tick = e.tick
      warsupply.step_division(D, dt)
    end
  end
end)

---------------------------------------------------------------------------
-- Loose units: the nearest division's state within loose_radius
---------------------------------------------------------------------------
local function loose_pass()
  local s = S()
  local loose = {}
  local l = storage.divisions
  if l and next(l) then
    local by_force = {}
    for _, D in pairs(l) do
      if D.pos and (D.n or 0) > 0 then
        local list = by_force[D.force]
        if not list then
          list = {}
          by_force[D.force] = list
        end
        list[#list + 1] = D
      end
    end
    local r = W.loose_radius
    local member = storage.division_meta and storage.division_meta.member or {}
    for force, list in pairs(by_force) do
      table.sort(list, function(a, b) return a.id < b.id end)
      for _, D in ipairs(list) do
        local st = state_of(D.sp or W.sp_start)
        local first = st ~= "supplied" and divisions.live_members(D)[1]
        local surface = first and first.entity.surface -- a division may stand on any surface
        if surface then
          for _, e in ipairs(surface.find_entities_filtered({position = D.pos, radius = r, force = force,
                                                              type = UNIT_TYPES})) do
            local un = e.unit_number
            if un and not member[un] and storage.units[un] and not loose[un] then
              -- the nearest division of the force decides
              local p = e.position
              local best, bd
              for _, D2 in ipairs(list) do
                local dx, dy = D2.pos.x - p.x, D2.pos.y - p.y
                local d2 = dx * dx + dy * dy
                if not bd or d2 < bd then best, bd = D2, d2 end
              end
              local bst = best and state_of(best.sp or W.sp_start) or "supplied"
              if bst ~= "supplied" and bd <= r * r then loose[un] = bst end
            end
          end
        end
      end
    end
  end
  s.loose = loose
end

-- A unit outside any division that remembers a division's SP below the maximum (warsupply.unit_sp) refills like a
-- division near a depot with crates, paying from a per-force credit (a crate covers 10 SP of 16 supply of units, the
-- price a 16-walker division pays), so a returned AI army can attack again.
local function refill_loose(dt)
  local s = S()
  local list = {}
  for un, sp in pairs(s.unit_sp) do
    if sp < W.sp_max then list[#list + 1] = un end
  end
  if #list == 0 then return end
  table.sort(list)
  local member = storage.division_meta and storage.division_meta.member or {}
  s.loose_credit = s.loose_credit or {}
  local minutes = dt / 3600
  for _, un in ipairs(list) do
    local rec = not member[un] and units.get(un)
    if rec then
      local depot, net = nearest_depot_with_crates(rec.force, rec.entity.position)
      if depot then
        local sp = s.unit_sp[un]
        local want = math.min(W.refill.per_minute * minutes, W.sp_max - sp)
        local credit = s.loose_credit[rec.force] or 0
        if credit < want then
          local got = net.remove_item({name = warsupply.CRATE, count = 1})
          if got > 0 then
            -- one crate pays 10 SP for 16 supply of loose units (a full division pays 1 crate per 10 SP)
            credit = credit + W.refill.sp_per_crate * W.troop_wagon.capacity
            local st = stats(rec.force)
            st.crates = st.crates + 1
          end
        end
        local add = math.min(want, credit / math.max(1, supply.cost(rec.entity.name)))
        s.loose_credit[rec.force] = credit - add * math.max(1, supply.cost(rec.entity.name))
        sp = sp + add
        if sp >= W.sp_max then s.unit_sp[un] = nil else s.unit_sp[un] = sp end
      end
    end
  end
end

events.on_nth_tick(warsupply.LOOSE_PERIOD, function()
  if not nation() then return end
  local s = S()
  local m = storage.match
  if s.recipes_match ~= m.match_id then -- a new Nation match: recipes at once, not after RECIPE_PERIOD
    s.recipes_match = m.match_id
    for _, f in ipairs(match.forces()) do warsupply.apply_recipes(f) end
  end
  loose_pass()
  refill_loose(warsupply.LOOSE_PERIOD)
end)

---------------------------------------------------------------------------
-- Out of supply: attrition
---------------------------------------------------------------------------
local function wear(e, force)
  if not (e and e.valid and e.health and e.max_health and e.max_health > 0) then return end
  local amount = e.max_health * W.out.share
  local st = stats(force)
  st.out_hits = st.out_hits + 1
  if e.health <= amount then
    st.out_kills = st.out_kills + 1
    e.die()
  else
    e.health = e.health - amount
  end
end

--- One out-of-supply attrition pass (every out.period ticks). Returns the units hit.
function warsupply.attrition_pass()
  if not nation() then return 0 end
  local n = 0
  local l = storage.divisions or {}
  local ids = {}
  for id, D in pairs(l) do
    if state_of(D.sp or W.sp_start) == "out" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local D = l[id]
    if D then
      for _, rec in ipairs(divisions.live_members(D)) do
        if rec.kind ~= "commander" and not exempt(rec.entity) then -- Phase 5 M3 air: planes have their own supply
          wear(rec.entity, D.force)
          n = n + 1
        end
      end
    end
  end
  local loose = S().loose
  local list = {}
  for un, st in pairs(loose) do
    if st == "out" then list[#list + 1] = un end
  end
  table.sort(list)
  for _, un in ipairs(list) do
    local rec = units.get(un)
    if rec and rec.kind ~= "commander" and not exempt(rec.entity) then -- Phase 5 M3 air
      wear(rec.entity, rec.force)
      n = n + 1
    end
  end
  if n > 0 then util.log("war: out of supply: %d units lost %.1f %% of their health", n, W.out.share * 100) end
  return n
end

events.on_nth_tick(W.out.period, function() warsupply.attrition_pass() end)

---------------------------------------------------------------------------
-- Engaged, and no Armor II/III heal while low or out
---------------------------------------------------------------------------
local ARMORED = {}
for _, name in ipairs(research.ARMORED_NAMES or {}) do ARMORED[name] = true end

events.on(defines.events.on_entity_damaged, function(e)
  local m = storage.division_meta
  if not (m and nation()) then return end
  local ent = e.entity
  if not (ent and ent.valid) then return end
  local member = m.member
  local tick = game.tick
  local un = not exempt(ent) and ent.unit_number or nil -- Phase 5 M3 air: a hit plane engages nothing, keeps its heal
  local id = un and member[un]
  local l = storage.divisions
  if id then
    local D = l[id]
    if D then D.engaged_tick = tick end
  end
  local cause = e.cause
  if cause and cause.valid and not exempt(cause) then -- Phase 5 M3 air: a plane's hit does not engage its division
    local cun = cause.unit_number
    local cid = cun and member[cun]
    if cid then
      local D = l[cid]
      if D then D.engaged_tick = tick end
    end
  end
  -- Armor II/III (scripts/research.lua, registered earlier) healed a share back: low or out takes it back
  if un and e.final_health > 0 and ARMORED[ent.name] and e.damage_type.name ~= "rts-attrition" then
    local st
    if id then
      local D = l[id]
      st = D and state_of(D.sp or W.sp_start) or "supplied"
    else
      st = S().loose[un] or "supplied"
    end
    if st ~= "supplied" then
      local share = research.armor(ent.force.name)
      if share > 0 then
        local heal = e.final_damage_amount * share
        local h = ent.health - heal
        if h < e.final_health then h = e.final_health end
        if h < ent.health then ent.health = h end
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Order locks
---------------------------------------------------------------------------
divisions.order_lock = function(D, kind)
  if not nation() then return nil end
  if state_of(D.sp or W.sp_start) == "out" then
    stats(D.force).refused = stats(D.force).refused + 1
    return "out of supply"
  end
  return nil
end

orders.unit_lock = function(entity)
  if not nation() then return nil end
  if exempt(entity) then return nil end -- Phase 5 M3 air: planes have their own supply
  if warsupply.unit_state(entity) == "out" then
    local st = stats(entity.force.name)
    st.refused = st.refused + 1
    return "rts-war.order-refused-out"
  end
  return nil
end

---------------------------------------------------------------------------
-- Recipes per force (Nation mode only)
---------------------------------------------------------------------------
local function age_of(force_name)
  local a = storage.ages and storage.ages[force_name]
  return a and a.age or 1
end

local function set_enabled(force, name, on)
  local r = force.recipes[name]
  if r and r.enabled ~= on then r.enabled = on end
end

--- Enable or disable this package's recipes for a force (Nation: crates by age, field depot, troop wagon kit with
--- Railways; Skirmish: none).
function warsupply.apply_recipes(force)
  if type(force) == "string" then force = game.forces[force] end
  if not (force and force.valid) then return end
  local on = nation() and match.is_participant(force.name)
  local age2 = on and age_of(force.name) >= 2
  set_enabled(force, warsupply.CRATE_RECIPE, on and not age2)
  set_enabled(force, warsupply.CRATE2_RECIPE, on and age2)
  set_enabled(force, warsupply.FIELD_DEPOT, on)
  local tech = force.technologies["rts-railways"]
  set_enabled(force, warsupply.TROOP_KIT_RECIPE, on and tech ~= nil and tech.researched)
end

events.on_nth_tick(warsupply.RECIPE_PERIOD, function()
  local m = storage.match
  if not (m and m.surface) then return end
  for _, f in ipairs(match.forces()) do warsupply.apply_recipes(f) end
end)

events.on(defines.events.on_research_finished, function(e)
  local tech = e.research
  if tech and tech.valid and tech.name == "rts-railways" then warsupply.apply_recipes(tech.force) end
end)

do
  local ok, ages = pcall(require, "scripts.ages")
  if ok and type(ages) == "table" and ages.on_age_changed then
    ages.on_age_changed(function(force_name) warsupply.apply_recipes(force_name) end)
  end
end

---------------------------------------------------------------------------
-- AI (scripts/ai/army.lua calls warsupply.ai_step): crates made at the capital and kept at every depot
---------------------------------------------------------------------------
--- True when an AI force should stock crates: always without m2-diplomacy; with it while the force is at war with a
--- nation or one of its divisions is below "supplied".
function warsupply.ai_needs_crates(force)
  local dip = package.loaded["__" .. script.mod_name .. "__/scripts/diplomacy.lua"]
  if not (dip and dip.state and dip.nations) then return true end
  for _, other in ipairs(dip.nations()) do
    if other ~= force and dip.state(force, other) == "war" then return true end
  end
  for _, D in ipairs(divisions.for_force(force)) do
    if state_of(D.sp or W.sp_start) ~= "supplied" then return true end
  end
  return false
end

--- AI commander hook (Nation mode, every ai.period ticks): a crate make target at the capital (from Age II, see
--- ai_needs_crates), the capital exports its crates above the keep and every other hub, City Center and depot keeps
--- crate_keep crates.
function warsupply.ai_step(C)
  if not nation() then return end
  local s = S()
  local A = s.ai[C.force]
  if not A then
    A = {next = 0}
    s.ai[C.force] = A
  end
  if game.tick < A.next then return end
  A.next = game.tick + W.ai.period
  warsupply.apply_recipes(C.force)
  -- crates from Age II on: in Age I the AI's attacks stay within 500 tiles of its capital and use little supply, and
  -- its one works factory is needed for the Railway Charter (seed 402: crates made from minute 2 cost rts-ai-1 4 minutes)
  -- with m2-diplomacy only while the force is at war or one of its divisions is short of supply: at peace the crates
  -- would only take iron and coal from the economy
  local cities_mod = package.loaded["__" .. script.mod_name .. "__/scripts/cities.lua"]
  local nation_rec = storage.nations and storage.nations[C.force]
  local capital = nation_rec and nation_rec.capital
  if cities_mod and capital and cities_mod.get(capital) then
    local want = age_of(C.force) >= W.ai.crates_from_age and warsupply.ai_needs_crates(C.force)
    local cur = cities_mod.make_targets(capital)[warsupply.CRATE]
    if want and not cur then
      cities_mod.set_make_target(capital, warsupply.CRATE, W.ai.crate_target)
      A.crates_set = true
    elseif not want and cur and A.crates_set then
      cities_mod.set_make_target(capital, warsupply.CRATE, nil)
      A.crates_set = nil
    end
  end
  local cc = buildings.main_cc(C.force)
  local cc_un = cc and cc.entity.unit_number
  for _, un in ipairs(warsupply.depots(C.force)) do
    local pol = logistics.policy(un)
    if pol then
      if un == cc_un then
        if pol.export_above[warsupply.CRATE] == nil then
          logistics.set_policy(un, "export_above", warsupply.CRATE, W.ai.crate_keep)
        end
      elseif pol.keep[warsupply.CRATE] == nil then
        logistics.set_policy(un, "keep", warsupply.CRATE, W.ai.crate_keep)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Teardown
---------------------------------------------------------------------------
match.on_teardown(function()
  storage.warsupply = nil
  S()
  for _, force in pairs(game.forces) do
    if string.sub(force.name, 1, 4) == "rts-" then
      for _, name in ipairs({warsupply.CRATE_RECIPE, warsupply.CRATE2_RECIPE, warsupply.FIELD_DEPOT,
                             warsupply.TROOP_KIT_RECIPE}) do
        set_enabled(force, name, false)
      end
    end
  end
end)

--- One line per force for logs: "rts-ai-1 supply: 3 divisions [#2 84 SP, #5 low 31 SP], crates used 12".
function warsupply.describe(force)
  local parts = {}
  for _, D in ipairs(divisions.for_force(force)) do
    local sp = D.sp or W.sp_start
    local st = state_of(sp)
    parts[#parts + 1] = string.format("#%d %s%.0f SP", D.id, st == "supplied" and "" or (st .. " "), sp)
  end
  local st = stats(force)
  return string.format("%s supply: %d divisions [%s], crates used %d, refused attack orders %d, out hits %d",
    force, #parts, table.concat(parts, ", "), st.crates, st.refused, st.out_hits)
end

return warsupply
