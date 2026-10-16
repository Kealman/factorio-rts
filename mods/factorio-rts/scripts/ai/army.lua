-- AI army (docs/PHASE3.md "ai/army.lua"). Units are commanded through orders.lua with entity lists (orders.move /
-- orders.attack_move take an array of LuaEntity as `who`), so AI units behave exactly like player units: formation
-- slots, attack-move re-targeting of the nearest enemy, release to idle + stop when done. No fake player index is
-- needed; the selection state is not involved.
--
-- C.army = {
--   rally      MapPosition  idle units gather here (between the CC and the nearest enemy spawn); barracks rally too
--   min        number?      attack once this many units are in the pool (set by the build order's "army" step)
--   action     "attack"?
--   groups     {[gid] = G}  G = {id, state = "attack" | "defend" | "retreat" | "return", members = {[un] = true},
--                                 target = {position, kind, un?}, initial_hp, formed, state_tick, last_order}
--   member     {[unit_number] = gid}   units in a group; every other own unit is in the pool
--   sent       {[unit_number] = tick}  pool units last sent to the rally point
--   threat     {position, tick, damage, since}?  latest damage to an own building (init.lua on_entity_damaged)
--   last_attack, next_gid
-- }
-- Defence sends the nearest half of the idle units (at least DEFEND_MIN; easy at most half) and keeps the rest at
-- the rally. No attack starts before cfg.first_attack ticks; an enemy without CC and barracks is attacked with
-- FINISH_MIN units, its remaining buildings all known (scout.best_target).
-- Phase 4: the pool never holds haulers or the commander (POOL_SKIP); ai/raids.lua forms "harass", "guard" and
-- "patrol" groups from it after the base defence, and the doctrine's reserve raiders stay out of attack groups.
-- Stats in C.stats: attacks, reinforcements, retreats, defends, recalls.
-- Phase 5 (docs/PHASE5-M1.md section 3): attack and defence groups run as divisions (scripts/divisions.lua, stance
-- advance, owner "ai"): G.division is the division id, order_attack / send_home order it with divisions.order (one
-- unit-group path per group instead of one path per unit), disband() disbands it, and a group counts as idle when its
-- division is. Guard, patrol and harass groups (ai/raids.lua) stay loose units.
local util = require("scripts.util")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions") -- Phase 5: attack and defence groups are divisions
local scout = require("scripts.ai.scout")
local raids = require("scripts.ai.raids")
local deps = require("scripts.ai.deps") -- Phase 5 M1 integration: deps.ages (Nation Age I reach)
local diplomacy = require("scripts.diplomacy") -- Phase 5 M2 diplomacy: a target's nation may make peace

local army = {}

army.RETARGET_TICKS = 10 * 60    -- re-target attack groups this often
army.RALLY_RADIUS = 14           -- pool units farther than this from the rally are sent back to it
army.RALLY_RESEND_TICKS = 30 * 60
army.THREAT_TICKS = 5 * 60       -- a damage report stays fresh this long
army.BASE_RADIUS = 55            -- threats this close to the CC are defended
army.RECALL_DAMAGE = 400         -- damage within one threat that recalls an attack group when the pool is empty
army.RETURN_TIMEOUT = 45 * 60    -- a retreating / returning group disbands after this long anyway
army.REGROUP_TICKS = 30 * 60     -- no new attack this long after a retreat
army.DEFEND_MIN = 4              -- a defence group takes the nearest half of the idle units, at least this many
army.FINISH_MIN = 3              -- attack size against an enemy without CC and barracks
army.RALLY_SHARE = 0.34          -- rally point: this share of the way from the CC to the nearest enemy spawn,
army.RALLY_MIN, army.RALLY_MAX = 20, 40 -- clamped; two rallies 24 tiles apart (0.4 of 120) saw each other (vision 30)
army.POOL_SKIP = {hauler = true, commander = true} -- unit kinds the army never commands (logistics, abilities)
army.PARITY = 0.8 -- an attack (not a finishing one) also needs this share of the largest enemy army seen lately
army.DIVISION_STATES = {attack = true, defend = true} -- Phase 5: groups formed in these states run as divisions
-- Phase 5 M1 integration, Nation mode only (the aggressive doctrine lost its capital in 4 of 4 Nation runs): a home
-- guard of the pool never joins an attack, no attack starts while the capital is under attack, and a heavy attack on
-- the capital recalls the nearest attack group even when idle units are left.
army.NATION_GUARD_SHARE = 0.4
army.NATION_GUARD_MIN, army.NATION_GUARD_MAX = 10, 16
army.NATION_RECALL_DAMAGE = 1500
army.NATION_PARITY = 1.2 -- Nation mode: an attack needs this share of the enemy army it saw (Skirmish: PARITY)
-- Nation mode, Age I: attacks only on targets within this many tiles of the own capital (both AIs of a 2048 world
-- sent their armies at each other's capital in minute 9 and the weaker one fell at 12:17); raids go on, and from Age II
-- on any target is fair. Capitals lie about 1000 (1536 world) to 1300 tiles (2048) apart.
army.NATION_AGE1_REACH = 500

local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

--- Set up C.army; the rally point lies between `home` (CC) and the nearest other spawn.
function army.init(C, home)
  local a = C.army or {}
  C.army = a
  a.groups = a.groups or {}
  a.member = a.member or {}
  a.sent = a.sent or {}
  a.next_gid = a.next_gid or 1
  a.last_attack = a.last_attack or game.tick
  local target, best
  local m = storage.match
  for force_name, pos in pairs(m and m.spawns or {}) do
    if force_name ~= C.force then
      local d = util.distance(home, pos)
      if not best or d < best then target, best = pos, d end
    end
  end
  if target and best > 0 then
    local share = math.max(army.RALLY_MIN, math.min(army.RALLY_MAX, best * army.RALLY_SHARE)) / best
    a.rally = {x = home.x + (target.x - home.x) * share, y = home.y + (target.y - home.y) * share}
  else
    a.rally = {x = home.x, y = home.y}
  end
end

--- Record damage to an own building (called from the on_entity_damaged handler).
function army.on_damage(C, entity, cause, damage)
  local a = C.army
  if not a then return end
  local pos = (cause and cause.valid) and cause.position or entity.position
  local t = a.threat
  if not t or game.tick - t.tick > army.THREAT_TICKS then
    t = {damage = 0, since = game.tick}
    a.threat = t
    util.log("ai %s: %s at %s damaged by %s (%s)", C.force, entity.name, util.pos_str(entity.position),
      (cause and cause.valid) and cause.name or "unknown", (cause and cause.valid) and cause.force.name or "-")
  end
  t.position = {x = pos.x, y = pos.y}
  t.tick = game.tick
  t.damage = t.damage + (damage or 0)
  -- far from the CC (a forward hub, its extractors): the raid defence answers (ai/raids.lua)
  local cc = buildings.main_cc(C.force)
  if not cc or util.distance(entity.position, cc.position) > army.BASE_RADIUS then
    raids.on_building_damage(C, entity, cause, buildings.kind_of(entity.name))
  end
end

--- How many of `idle` pool units defend: the nearest half, at least DEFEND_MIN (cfg.defend_share caps it: easy
--- never sends more than half).
function army.defenders(C, idle)
  local share = C.cfg.defend_share
  local n
  if share then
    n = math.floor(idle * share)
  else
    n = math.max(army.DEFEND_MIN, math.ceil(idle / 2))
  end
  return math.min(n, idle)
end

local function entities_of(G)
  local list = {}
  for un in pairs(G.members) do
    local rec = units.get(un)
    if rec then list[#list + 1] = rec.entity end
  end
  return list
end

local function hp_of(list)
  local hp = 0
  for _, e in ipairs(list) do hp = hp + (e.health or 0) end
  return hp
end

local function disband(C, G, why)
  for un in pairs(G.members) do C.army.member[un] = nil end
  C.army.groups[G.id] = nil
  if G.division then divisions.disband(G.division, "AI group #" .. G.id .. " disbanded: " .. why) end
  util.log("ai %s: group #%d disbanded (%s)", C.force, G.id, why)
end

local function form(C, list, state, target)
  local a = C.army
  local G = {id = a.next_gid, state = state, members = {}, target = target, formed = game.tick,
             state_tick = game.tick, last_order = game.tick}
  a.next_gid = a.next_gid + 1
  for _, e in ipairs(list) do
    G.members[e.unit_number] = true
    a.member[e.unit_number] = G.id
    a.sent[e.unit_number] = nil
  end
  G.initial_hp = hp_of(list)
  a.groups[G.id] = G
  if army.DIVISION_STATES[state] then
    G.division = divisions.create(C.force, list, {stance = "advance"}, {owner = "ai"})
  end
  return G
end

-- Phase 5: the group's division, when it has one that still exists.
local function division_of(G)
  return G.division and divisions.get(G.division) and G.division or nil
end

-- Units of the group outside its division (none normally: a unit another module drives cannot join).
local function outside(G, list)
  local out = {}
  for _, e in ipairs(list) do
    if e.valid and divisions.of_unit(e.unit_number) ~= G.division then out[#out + 1] = e end
  end
  return out
end

local function order_attack(C, G, list, target)
  G.target = target
  G.last_order = game.tick
  local id = division_of(G)
  if id and divisions.order(id, "attack_move", target.position) then
    local rest = outside(G, list)
    if #rest > 0 then orders.attack_move(rest, target.position) end
    return #list
  end
  return orders.attack_move(list, target.position)
end

local function send_home(C, G, list, state)
  G.state, G.state_tick, G.last_order = state, game.tick, game.tick
  local id = division_of(G)
  if id and divisions.order(id, state == "retreat" and "retreat" or "move", C.army.rally) then
    local rest = outside(G, list)
    if #rest > 0 then orders.move(rest, C.army.rally) end
    return
  end
  orders.move(list, C.army.rally)
end

raids.bind({form = form, order_attack = order_attack, send_home = send_home, hp_of = hp_of, disband = disband})

local function threat_fresh(C, home)
  local t = C.army.threat
  return t ~= nil and game.tick - t.tick <= army.THREAT_TICKS and home ~= nil
    and util.distance(t.position, home) <= army.BASE_RADIUS
end

--- One army pass for commander C.
function army.step(C, surface)
  local a = C.army
  local tick = game.tick
  local cc = buildings.main_cc(C.force)
  local home = cc and cc.position or a.rally

  -- groups: drop the dead, count hit points
  local lists = {}
  for gid, G in pairs(a.groups) do
    for un in pairs(G.members) do
      if not units.get(un) then
        G.members[un] = nil
        a.member[un] = nil
      end
    end
    local list = entities_of(G)
    if #list == 0 then
      disband(C, G, "no members left")
    else
      lists[gid] = list
    end
  end

  -- the pool: own units in no group (haulers and the commander never)
  local pool, far = {}, {}
  for un, rec in units.for_force(C.force) do
    if not a.member[un] and not army.POOL_SKIP[rec.kind] and rec.issuer ~= "market" then -- Phase 5 M2 treasury: envoys
      pool[#pool + 1] = rec.entity
      if rec.order == units.IDLE and util.distance(rec.entity, a.rally) > army.RALLY_RADIUS
         and tick - (a.sent[un] or -army.RALLY_RESEND_TICKS) >= army.RALLY_RESEND_TICKS then
        far[#far + 1] = rec.entity
        a.sent[un] = tick
      end
    end
  end
  if #far > 0 and not threat_fresh(C, home) then orders.move(far, a.rally) end

  -- the doctrine's reserve raiders stay out of defence, guard, patrol and attack groups: they harass (raids.lua)
  local reserve = {}
  local n_reserve = raids.reserved_raiders(C)
  if n_reserve > 0 then
    local rest = {}
    for _, e in ipairs(pool) do
      local rec = units.get(e.unit_number)
      if #reserve < n_reserve and rec and rec.kind == "raider" then reserve[#reserve + 1] = e else rest[#rest + 1] = e end
    end
    pool = rest
  end

  -- defend the base
  if threat_fresh(C, home) then
    local t = a.threat
    local defending
    for _, G in pairs(a.groups) do
      if G.state == "defend" then defending = G end
    end
    if defending then
      if util.distance(defending.target.position, t.position) > 8 then
        order_attack(C, defending, lists[defending.id], {position = t.position, kind = "threat"})
      end
    elseif #pool > 0 and army.defenders(C, #pool) > 0 then
      -- the nearest part of the pool defends; the rest keeps rallying
      local n = army.defenders(C, #pool)
      local tp = t.position
      table.sort(pool, function(x, y)
        local dx, dy = util.distance_sq(x, tp), util.distance_sq(y, tp)
        if dx ~= dy then return dx < dy end
        return x.unit_number < y.unit_number
      end)
      local sent, rest = {}, {}
      for i, e in ipairs(pool) do
        if i <= n then sent[#sent + 1] = e else rest[#rest + 1] = e end
      end
      local G = form(C, sent, "defend", nil)
      lists[G.id] = sent
      order_attack(C, G, sent, {position = tp, kind = "threat"})
      C.stats.defends = C.stats.defends + 1
      util.log("ai %s: group #%d (%d of %d idle units) defends against an attack at %s", C.force, G.id, #sent,
        #pool, util.pos_str(tp))
      pool = rest
    elseif (#pool == 0 and t.damage >= army.RECALL_DAMAGE)
        or (nation_mode() and t.damage >= army.NATION_RECALL_DAMAGE and not t.recalled) then
      t.recalled = true
      local nearest, nd
      for gid, G in pairs(a.groups) do
        if G.state == "attack" then
          local c = util.centroid(lists[gid])
          local d = c and util.distance(c, home) or math.huge
          if not nd or d < nd then nearest, nd = G, d end
        end
      end
      if nearest then
        nearest.state, nearest.state_tick = "defend", tick
        order_attack(C, nearest, lists[nearest.id], {position = t.position, kind = "threat"})
        C.stats.recalls = C.stats.recalls + 1
        util.log("ai %s: group #%d recalled to defend %s (%.0f damage)", C.force, nearest.id,
          util.pos_str(t.position), t.damage)
      end
    end
  end

  -- raids: raid defence, the hauler-route patrol, raider harassment (ai/raids.lua; the harass takes the reserve)
  pool = raids.step(C, surface, pool, lists, home, reserve)

  -- launch an attack (or reinforce one under way). The pool's strength counts wounded units by their health
  -- share, so the remains of a beaten group do not turn round at once.
  local attacking = false
  for _, G in pairs(a.groups) do
    if G.state == "attack" then attacking = true end
  end
  local strength = 0
  for _, e in ipairs(pool) do strength = strength + (e.get_health_ratio() or 1) end
  a.pool_strength = strength
  -- an enemy without CC and barracks is finished off with whatever is at hand
  local finishing = scout.beaten_enemy(C) ~= nil
  local need = finishing and math.min(a.min or 3, army.FINISH_MIN) or a.min
  -- no suicide: once scouting saw the enemy army, an attack waits for rough parity (Phase 4; the aggressive doctrine
  -- fed its army piecemeal into a defending one and lost its base by minute 6)
  if need and not finishing then
    local e = C.enemy_army
    local seen = (e and tick - e.tick <= scout.ENEMY_ARMY_TICKS) and e.n or 0
    a.enemy_seen = seen
    need = math.max(need, math.floor(seen * (nation_mode() and army.NATION_PARITY or army.PARITY) + 0.5))
  end
  -- (a threat does not stop it: the defence above took its share of the pool, the rest may attack)
  -- Phase 5 M1 integration, Nation mode: the home guard stays, and nothing leaves while the capital is attacked
  local guard_list = {}
  if nation_mode() and #pool > 0 then
    if threat_fresh(C, home) then
      guard_list, pool = pool, {}
    else
      local n = math.min(#pool, army.NATION_GUARD_MAX,
        math.max(army.NATION_GUARD_MIN, math.ceil(#pool * army.NATION_GUARD_SHARE)))
      table.sort(pool, function(x, y)
        local dx, dy = util.distance_sq(x, home), util.distance_sq(y, home)
        if dx ~= dy then return dx < dy end
        return x.unit_number < y.unit_number
      end)
      local rest = {}
      for i, e in ipairs(pool) do
        if i <= n then guard_list[#guard_list + 1] = e else rest[#rest + 1] = e end
      end
      pool = rest
      strength = 0
      for _, e in ipairs(pool) do strength = strength + (e.get_health_ratio() or 1) end
      a.pool_strength = strength
    end
  end
  if a.min and #pool > 0 and tick >= (a.hold_until or 0) and tick >= C.started + (C.cfg.first_attack or 0) then
    local launch = strength >= need and (finishing or tick - a.last_attack >= (C.cfg.attack_interval or 0))
    local reinforce = attacking and strength >= math.max(3, need / 2)
    if launch or reinforce then
      local target = scout.best_target(C, surface, a.rally)
      if target and nation_mode() and not finishing and home
         and util.distance(target.position, home) > army.NATION_AGE1_REACH then
        local ages = deps.ages
        if ages and ages.of(C.force) < 2 then
          if not a.reach_logged then
            a.reach_logged = true
            util.log("ai %s: Age I: no attack on %s %s (%.0f tiles from the capital, reach %d)", C.force, target.kind,
              util.pos_str(target.position), util.distance(target.position, home), army.NATION_AGE1_REACH)
          end
          C.stats.reach_held = (C.stats.reach_held or 0) + 1
          target = nil
        end
      end
      if target then
        local G = form(C, pool, "attack", target)
        lists[G.id] = pool
        local n = order_attack(C, G, pool, target)
        if launch then
          a.last_attack = tick
          C.stats.attacks = C.stats.attacks + 1
        else
          C.stats.reinforcements = C.stats.reinforcements + 1
        end
        util.log("ai %s: %s #%d: group #%d with %d units (%d ordered, %.0f hp) -> %s %s", C.force,
          launch and "attack" or "reinforcement", launch and C.stats.attacks or C.stats.reinforcements, G.id, #pool,
          n, G.initial_hp, target.kind, util.pos_str(target.position))
        pool = {}
      end
    end
  end

  -- group upkeep: retreat, re-target, return
  for gid, G in pairs(a.groups) do
    local list = lists[gid]
    if list then
      local centroid = util.centroid(list)
      if G.state == "attack" or G.state == "defend" then
        local hp = hp_of(list)
        -- Phase 5 M2 diplomacy: the target's nation is no longer at war with us: re-target now (scout filters it out)
        local stale = G.target and G.target.force and not diplomacy.hostile(C.force, G.target.force)
        if G.state == "attack" and G.initial_hp > 0 and hp < (C.cfg.retreat_ratio or 0.4) * G.initial_hp then
          send_home(C, G, list, "retreat")
          a.hold_until = tick + army.REGROUP_TICKS
          C.stats.retreats = C.stats.retreats + 1
          util.log("ai %s: group #%d retreats: %.0f of %.0f hp left, %d units", C.force, gid, hp, G.initial_hp,
            #list)
        elseif stale or tick - G.last_order >= army.RETARGET_TICKS then
          local target
          if G.state == "defend" then
            if threat_fresh(C, home) then target = {position = a.threat.position, kind = "threat"} end
          else
            target = scout.best_target(C, surface, centroid)
          end
          if not target then
            send_home(C, G, list, "return")
            util.log("ai %s: group #%d returns to the rally point (%s)", C.force, gid,
              G.state == "defend" and "threat over" or "no target known")
          else
            local idle = false
            if division_of(G) then
              idle = divisions.is_idle(G.division)
            else
              for _, e in ipairs(list) do
                local rec = units.get(e.unit_number)
                if rec and rec.order == units.IDLE then idle = true break end
              end
            end
            local moved = util.distance(target.position, G.target and G.target.position or target.position) > 6
            if moved or idle then
              order_attack(C, G, list, target)
            else
              G.last_order = tick
            end
          end
        end
      elseif G.state == "retreat" or G.state == "return" then
        if (centroid and util.distance(centroid, a.rally) <= army.RALLY_RADIUS)
           or tick - G.state_tick >= army.RETURN_TIMEOUT then
          disband(C, G, G.state == "retreat" and "back from a retreat" or "back at the rally point")
        end
      end
    end
  end
  a.pool_size = #pool + #guard_list
end

--- Summary for logs: "pool=N groups=[#1 attack 8u -> barracks (x, y)] ..."
function army.describe(C)
  local a = C.army
  local parts = {}
  local ids = {}
  for gid in pairs(a.groups) do ids[#ids + 1] = gid end
  table.sort(ids)
  for _, gid in ipairs(ids) do
    local G = a.groups[gid]
    parts[#parts + 1] = string.format("#%d %s %du%s -> %s %s", gid, G.state, table_size(G.members),
      division_of(G) and (" div#" .. G.division) or "", G.target and G.target.kind or "-",
      G.target and util.pos_str(G.target.position) or "")
  end
  return string.format("rally %s min=%s pool=%d (strength %.1f, enemy army seen %d) groups=[%s]",
    util.pos_str(a.rally), tostring(a.min), a.pool_size or 0, a.pool_strength or 0, a.enemy_seen or 0,
    table.concat(parts, "; "))
end

return army
