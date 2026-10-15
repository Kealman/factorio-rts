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
-- Stats in C.stats: attacks, reinforcements, retreats, defends, recalls.
local util = require("scripts.util")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local orders = require("scripts.orders")
local scout = require("scripts.ai.scout")

local army = {}

army.RETARGET_TICKS = 10 * 60    -- re-target attack groups this often
army.RALLY_RADIUS = 14           -- pool units farther than this from the rally are sent back to it
army.RALLY_RESEND_TICKS = 30 * 60
army.THREAT_TICKS = 5 * 60       -- a damage report stays fresh this long
army.BASE_RADIUS = 55            -- threats this close to the CC are defended
army.RECALL_DAMAGE = 400         -- damage within one threat that recalls an attack group when the pool is empty
army.RETURN_TIMEOUT = 45 * 60    -- a retreating / returning group disbands after this long anyway
army.REGROUP_TICKS = 30 * 60     -- no new attack this long after a retreat
army.RALLY_SHARE = 0.34          -- rally point: this share of the way from the CC to the nearest enemy spawn,
army.RALLY_MIN, army.RALLY_MAX = 20, 40 -- clamped; two rallies 24 tiles apart (0.4 of 120) saw each other (vision 30)

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
  return G
end

local function order_attack(C, G, list, target)
  G.target = target
  G.last_order = game.tick
  return orders.attack_move(list, target.position)
end

local function send_home(C, G, list, state)
  G.state, G.state_tick, G.last_order = state, game.tick, game.tick
  orders.move(list, C.army.rally)
end

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

  -- the pool: own units in no group
  local pool, far = {}, {}
  for un, rec in units.for_force(C.force) do
    if not a.member[un] then
      pool[#pool + 1] = rec.entity
      if rec.order == units.IDLE and util.distance(rec.entity, a.rally) > army.RALLY_RADIUS
         and tick - (a.sent[un] or -army.RALLY_RESEND_TICKS) >= army.RALLY_RESEND_TICKS then
        far[#far + 1] = rec.entity
        a.sent[un] = tick
      end
    end
  end
  if #far > 0 and not threat_fresh(C, home) then orders.move(far, a.rally) end

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
    elseif #pool > 0 then
      local G = form(C, pool, "defend", nil)
      lists[G.id] = pool
      order_attack(C, G, pool, {position = t.position, kind = "threat"})
      C.stats.defends = C.stats.defends + 1
      util.log("ai %s: group #%d (%d units) defends against an attack at %s", C.force, G.id, #pool,
        util.pos_str(t.position))
      pool = {}
    elseif t.damage >= army.RECALL_DAMAGE then
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

  -- launch an attack (or reinforce one under way). The pool's strength counts wounded units by their health
  -- share, so the remains of a beaten group do not turn round at once.
  local attacking = false
  for _, G in pairs(a.groups) do
    if G.state == "attack" then attacking = true end
  end
  local strength = 0
  for _, e in ipairs(pool) do strength = strength + (e.get_health_ratio() or 1) end
  a.pool_strength = strength
  if a.min and #pool > 0 and not threat_fresh(C, home) and tick >= (a.hold_until or 0) then
    local launch = strength >= a.min and tick - a.last_attack >= (C.cfg.attack_interval or 0)
    local reinforce = attacking and strength >= math.max(3, a.min / 2)
    if launch or reinforce then
      local target = scout.best_target(C, surface, a.rally)
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
        if G.state == "attack" and G.initial_hp > 0 and hp < (C.cfg.retreat_ratio or 0.4) * G.initial_hp then
          send_home(C, G, list, "retreat")
          a.hold_until = tick + army.REGROUP_TICKS
          C.stats.retreats = C.stats.retreats + 1
          util.log("ai %s: group #%d retreats: %.0f of %.0f hp left, %d units", C.force, gid, hp, G.initial_hp,
            #list)
        elseif tick - G.last_order >= army.RETARGET_TICKS then
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
            for _, e in ipairs(list) do
              local rec = units.get(e.unit_number)
              if rec and rec.order == units.IDLE then idle = true break end
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
  a.pool_size = #pool
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
    parts[#parts + 1] = string.format("#%d %s %du -> %s %s", gid, G.state, table_size(G.members),
      G.target and G.target.kind or "-", G.target and util.pos_str(G.target.position) or "")
  end
  return string.format("rally %s min=%s pool=%d (strength %.1f) groups=[%s]", util.pos_str(a.rally),
    tostring(a.min), a.pool_size or 0, a.pool_strength or 0, table.concat(parts, "; "))
end

return army
