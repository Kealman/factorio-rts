-- AI raids (Phase 4: docs/PHASE4.md section 6). Three kinds of small groups next to army.lua's attack and defence
-- groups, in C.army.groups with these states (army.lua leaves them to this module):
--   "harass"  aggressive doctrine: every HARASS_PERIOD, HARASS_MIN..HARASS_MAX raiders from the pool go for enemy
--             haulers, hubs, outlying extractors and poles (scout.harass_target); they retreat below
--             HARASS_RETREAT of their hit points, re-target nearby, and come home after HARASS_TIMEOUT. Up to
--             doctrine.reserve_raiders raiders stay out of attack groups for this.
--   "guard"   raid defence: when an own hauler (polled: its health dropped) or an extractor, hub, smelter or solar
--             array outside the base radius is damaged, the GUARD_SIZE pool units nearest to it go there; the group
--             comes home GUARD_TICKS after the last damage.
--   "patrol"  economic doctrine: PATROL_SIZE units walk the route between the CC and the first hub (attack-move,
--             one leg every PATROL_LEG), refilled from the pool.
-- Stats in C.stats: harass, guards, patrols.
local util = require("scripts.util")
local units = require("scripts.units")
local orders = require("scripts.orders")
local scout = require("scripts.ai.scout")
local doctrine = require("scripts.ai.doctrine")
local hubs = require("scripts.ai.hubs")
local deps = require("scripts.ai.deps")
local diplomacy = require("scripts.diplomacy") -- Phase 5 M2 diplomacy: a harass target's nation may make peace

local raids = {}

raids.HARASS_PERIOD = 120 * 60
raids.HARASS_FIRST = 120 * 60     -- no harass before this many ticks after the commander started
raids.HARASS_MIN, raids.HARASS_MAX = 3, 4
raids.HARASS_TIMEOUT = 75 * 60
raids.HARASS_RETREAT = 0.5
raids.HARASS_RETARGET = 5 * 60
raids.HARASS_NEAR = 45            -- next target within this of the group when the first is gone
raids.GUARD_SIZE = 4
raids.GUARD_TICKS = 15 * 60
raids.ALARM_TICKS = 5 * 60        -- an alarm this fresh starts a guard group
raids.GUARD_FROM_CC = 30          -- hauler damage closer than this to the CC is left to the base defence
raids.PATROL_SIZE = 2
raids.PATROL_LEG = 25 * 60
raids.OUTLYING = {extractor = true, hub = true, smelter = true, solar = true, stockpile = true}

-- army.lua helpers, set by army.lua at load (no require loop)
local A
function raids.bind(army_helpers) A = army_helpers end

--- An own building of commander C was damaged far from its CC (init.lua's handler via army.on_damage).
function raids.on_building_damage(C, entity, cause, kind)
  if not raids.OUTLYING[kind] then return end
  local pos = (cause and cause.valid) and cause.position or entity.position
  raids.alarm(C, pos, entity.name)
end

function raids.alarm(C, position, what)
  local fresh = C.raid and game.tick - C.raid.tick <= raids.ALARM_TICKS
  if not fresh then
    util.log("ai %s: raid alarm: %s attacked at %s", C.force, what, util.pos_str(position))
  end
  C.raid = {position = {x = position.x, y = position.y}, tick = game.tick, what = what}
end

-- Own haulers whose health dropped since the last run raise an alarm.
local function poll_haulers(C, home)
  local L = deps.logistics
  if not L then return end
  C.hauler_hp = C.hauler_hp or {}
  local seen = {}
  for un, h in L.haulers_of(C.force) do
    local e = h.entity
    local hp = e.health or 0
    local last = C.hauler_hp[un]
    if last and hp < last - 0.5 and not (home and util.distance(e.position, home) < raids.GUARD_FROM_CC) then
      raids.alarm(C, e.position, "hauler #" .. un)
    end
    C.hauler_hp[un] = hp
    seen[un] = true
  end
  for un in pairs(C.hauler_hp) do
    if not seen[un] then C.hauler_hp[un] = nil end
  end
end

local function kind_of(e)
  local rec = units.get(e.unit_number)
  return rec and rec.kind
end

-- Take up to n units from `pool` (an array of entities), nearest to `pos` first, optionally only of `kind`.
-- Returns the taken list and the rest.
local function take(pool, n, pos, kind)
  local cands = {}
  for i, e in ipairs(pool) do
    if e.valid and (not kind or kind_of(e) == kind) then cands[#cands + 1] = {e, i} end
  end
  if pos then
    table.sort(cands, function(a, b)
      local da, db = util.distance_sq(a[1], pos), util.distance_sq(b[1], pos)
      if da ~= db then return da < db end
      return a[1].unit_number < b[1].unit_number
    end)
  end
  local taken, used = {}, {}
  for i = 1, math.min(n, #cands) do
    taken[#taken + 1] = cands[i][1]
    used[cands[i][2]] = true
  end
  local rest = {}
  for i, e in ipairs(pool) do
    if not used[i] then rest[#rest + 1] = e end
  end
  return taken, rest
end
raids.take = take

-- Order a harass group at a target {position, entity?}.
local function harass_order(C, G, list, target)
  G.target, G.last_order = {position = target.position, kind = target.kind}, game.tick
  if target.entity and target.entity.valid then
    G.target.un = target.entity.unit_number
    return orders.attack(list, target.entity)
  end
  return orders.attack_move(list, target.position)
end

local function find_group(C, state)
  for _, G in pairs(C.army.groups) do
    if G.state == state then return G end
  end
  return nil
end

--- Raider reserve of the doctrine (aggressive): raiders that stay out of attack groups.
function raids.reserved_raiders(C)
  return doctrine.get(C.doctrine).reserve_raiders or 0
end

--- One raid pass (army.step calls it after the base defence): may take units out of `pool`; returns the pool.
--- `reserve` holds the doctrine's reserve raiders (kept out of every other group); the harass takes them first.
function raids.step(C, surface, pool, lists, home, reserve)
  reserve = reserve or {}
  local tick = game.tick
  local a = C.army
  poll_haulers(C, home)
  local D = doctrine.get(C.doctrine)

  -- guard: raid defence
  local raid = C.raid
  local guard = find_group(C, "guard")
  if raid and tick - raid.tick <= raids.ALARM_TICKS then
    if guard then
      if util.distance(guard.target.position, raid.position) > 8 then
        A.order_attack(C, guard, lists[guard.id], {position = raid.position, kind = "raid"})
      end
      guard.alarm_tick = raid.tick
    elseif #pool > 0 then
      local sent
      sent, pool = take(pool, raids.GUARD_SIZE, raid.position)
      if #sent > 0 then
        local G = A.form(C, sent, "guard", nil)
        G.alarm_tick = raid.tick
        lists[G.id] = sent
        A.order_attack(C, G, sent, {position = raid.position, kind = "raid"})
        C.stats.guards = (C.stats.guards or 0) + 1
        util.log("ai %s: group #%d (%d units) guards against a raid on %s at %s", C.force, G.id, #sent, raid.what,
          util.pos_str(raid.position))
      end
    end
  end
  if guard and lists[guard.id] and tick - (guard.alarm_tick or guard.formed) > raids.GUARD_TICKS then
    A.send_home(C, guard, lists[guard.id], "return")
    util.log("ai %s: group #%d returns (raid over)", C.force, guard.id)
  end

  -- patrol along the hauler route (economic)
  if D.patrol then
    local route = hubs.route(C)
    local patrol = find_group(C, "patrol")
    if route then
      local a_pt = {x = (route.from.x + route.to.x) / 2, y = (route.from.y + route.to.y) / 2}
      local dx, dy = route.from.x - route.to.x, route.from.y - route.to.y
      local len = math.max(1, math.sqrt(dx * dx + dy * dy))
      local b_pt = {x = route.to.x + dx / len * 10, y = route.to.y + dy / len * 10}
      if not patrol and #pool > raids.PATROL_SIZE then
        local sent
        sent, pool = take(pool, raids.PATROL_SIZE, a_pt)
        patrol = A.form(C, sent, "patrol", nil)
        lists[patrol.id] = sent
        patrol.leg = 0
        patrol.last_order = tick - raids.PATROL_LEG
        C.stats.patrols = (C.stats.patrols or 0) + 1
        util.log("ai %s: group #%d (%d units) patrols the hauler route %s - %s", C.force, patrol.id, #sent,
          util.pos_str(a_pt), util.pos_str(b_pt))
      elseif patrol and table_size(patrol.members) < raids.PATROL_SIZE and #pool > raids.PATROL_SIZE then
        local sent
        sent, pool = take(pool, raids.PATROL_SIZE - table_size(patrol.members), a_pt)
        for _, e in ipairs(sent) do
          patrol.members[e.unit_number] = true
          a.member[e.unit_number] = patrol.id
          lists[patrol.id][#lists[patrol.id] + 1] = e
        end
        patrol.last_order = tick - raids.PATROL_LEG
      end
      if patrol and lists[patrol.id] and tick - patrol.last_order >= raids.PATROL_LEG then
        patrol.leg = (patrol.leg or 0) + 1
        local pt = patrol.leg % 2 == 1 and b_pt or a_pt
        A.order_attack(C, patrol, lists[patrol.id], {position = pt, kind = "patrol"})
      end
    elseif patrol and lists[patrol.id] then
      A.send_home(C, patrol, lists[patrol.id], "return")
    end
  end

  -- harass (aggressive): raiders at enemy haulers, hubs, outlying extractors
  if D.harass then
    local G = find_group(C, "harass")
    if not G and tick >= (C.next_harass or (C.started + raids.HARASS_FIRST)) then
      local candidates = {}
      for _, e in ipairs(reserve) do candidates[#candidates + 1] = e end
      for _, e in ipairs(pool) do candidates[#candidates + 1] = e end
      local raiders = 0
      for _, e in ipairs(candidates) do
        if e.valid and kind_of(e) == "raider" then raiders = raiders + 1 end
      end
      if raiders >= raids.HARASS_MIN then
        local sent
        sent, candidates = take(candidates, raids.HARASS_MAX, a.rally, "raider")
        local taken_set = {}
        for _, e in ipairs(sent) do taken_set[e.unit_number] = true end
        local rest = {}
        for _, e in ipairs(pool) do
          if not taken_set[e.unit_number] then rest[#rest + 1] = e end
        end
        pool = rest
        local target = scout.harass_target(C, surface, util.centroid(sent) or a.rally)
        if target then
          G = A.form(C, sent, "harass", nil)
          lists[G.id] = sent
          G.initial_hp = A.hp_of(sent)
          harass_order(C, G, sent, target)
          C.next_harass = tick + raids.HARASS_PERIOD
          C.stats.harass = (C.stats.harass or 0) + 1
          util.log("ai %s: harass #%d: group #%d with %d raiders -> %s %s", C.force, C.stats.harass, G.id, #sent,
            target.kind, util.pos_str(target.position))
        else
          C.next_harass = tick + 20 * 60 -- nothing to harass: the raiders stay unassigned and try again later
          C.stats.harass_no_target = (C.stats.harass_no_target or 0) + 1 -- Phase 5 M1: the autotest's excuse
        end
      end
    elseif G and lists[G.id] and tick - G.last_order >= raids.HARASS_RETARGET then
      local list = lists[G.id]
      local hp = A.hp_of(list)
      local centroid = util.centroid(list)
      if hp < raids.HARASS_RETREAT * G.initial_hp or tick - G.formed >= raids.HARASS_TIMEOUT then
        A.send_home(C, G, list, "return")
        util.log("ai %s: harass group #%d comes home (%.0f of %.0f hp, %ds out)", C.force, G.id, hp, G.initial_hp,
          (tick - G.formed) / 60)
      else
        local gone = true
        if G.target and G.target.un then
          local rec = units.get(G.target.un) or (storage.buildings and storage.buildings[G.target.un])
          gone = not (rec and rec.entity.valid and diplomacy.hostile(C.force, rec.force)) -- Phase 5 M2 diplomacy
        elseif G.target then
          gone = centroid ~= nil and util.distance(centroid, G.target.position) < 10
        end
        if gone then
          local target = scout.harass_target(C, surface, centroid or a.rally, raids.HARASS_NEAR)
          if target then
            harass_order(C, G, list, target)
          else
            A.send_home(C, G, list, "return")
            util.log("ai %s: harass group #%d comes home (nothing left near %s)", C.force, G.id,
              util.pos_str(centroid or a.rally))
          end
        else
          G.last_order = tick
        end
      end
    end
  end
  return pool
end

return raids
