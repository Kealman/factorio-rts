-- AI construction (docs/PHASE3.md "ai/construction.lua"). The AI does not use robots (init.lua takes them out of its
-- Command Centers): it places entity ghosts and revives them itself, at a fixed pace per CC, only when the item is in
-- its logistic network (the item is removed on revive, so the AI pays what a player pays).
--
-- Plan entries, C.plan[key] (key = "<name>@<x>,<y>"):
--   {key, name, item, x, y, dir, line?, part?, pickup?, status, ghost?, entity?, since, blocked_since?, fail_since?}
--   status: "planned" (known, not wanted yet) -> "queued" (wanted, no ghost) -> "ghost" -> "built";
--           "bad" when it could not be placed or revived for GIVE_UP_TICKS. A "built" entry whose entity died goes
--           back to "queued" (repair), so a razed line is rebuilt.
-- C.queue = {key, ...} in the order the work was asked for (build_order.lua). C.pending[name] = queued + ghost
-- entries per entity name, C.need[item] = items the queue still needs, C.need_list = those items in queue order.
--
-- Pace: one job every cfg.build_period ticks. A job revives one building, or up to cfg.small_batch belts, inserters
-- and poles (counting each belt tile as a job would make a 40-tile belt take minutes).
local util = require("scripts.util")
local economy = require("scripts.economy")
local units = require("scripts.units")
local orders = require("scripts.orders")
local layout = require("scripts.ai.layout")

local construction = {}

construction.GHOSTS_PER_PASS = 40       -- ghosts created per commander run
construction.GIVE_UP_TICKS = 60 * 60    -- a ghost that cannot be placed / revived for this long is dropped
construction.SMALL = {["transport-belt"] = true, ["fast-inserter"] = true, ["medium-electric-pole"] = true}
local CLEAR_TYPES = {"tree", "simple-entity", "item-entity"}

local function item_of(name)
  local p = prototypes.entity[name]
  local items = p and p.items_to_place_this
  return items and items[1] and items[1].name or name
end

--- Register (or find) the plan entry for an entity spec {name, x, y, dir?, line?, part?, pickup?, clear?}. `clear` =
--- areas that must be free of units before the revive (a hub's stockpile spots). Returns the key.
function construction.add(C, spec)
  local key = string.format("%s@%.1f,%.1f", spec.name, spec.x, spec.y)
  if not C.plan[key] then
    C.plan[key] = {key = key, name = spec.name, item = item_of(spec.name), x = spec.x, y = spec.y, dir = spec.dir,
                   line = spec.line, part = spec.part, pickup = spec.pickup, clear = spec.clear, status = "planned"}
  end
  return key
end

local UNIT_TYPES = {"spider-unit", "unit", "spider-leg", "spider-vehicle", "character"}

-- True while a unit stands in one of the entry's `clear` areas; own units there are sent to the rally point.
local function units_in_clear(C, surface, e)
  local blocked = false
  for _, box in ipairs(e.clear or {}) do
    local found = surface.find_entities_filtered({area = box, type = UNIT_TYPES})
    if #found > 0 then
      blocked = true
      local own = {}
      for _, u in pairs(found) do
        if u.valid and u.unit_number and u.force.name == C.force and units.get(u.unit_number) then own[#own + 1] = u end
      end
      if #own > 0 and C.army and C.army.rally then orders.move(own, C.army.rally) end
    end
  end
  return blocked
end

--- Ask for an entry to be built. No effect when it is already queued, a ghost or built (and alive).
function construction.queue(C, key)
  local e = C.plan[key]
  if not e then return false end
  if e.status == "built" and e.entity and e.entity.valid then return false end
  if e.status == "queued" or e.status == "ghost" then return false end
  e.status = "queued"
  e.since = game.tick
  e.blocked_since, e.fail_since = nil, nil
  C.queue[#C.queue + 1] = key
  C.pending[e.name] = (C.pending[e.name] or 0) + 1
  return true
end

--- Count of `item` in the force's CC logistic networks, memoized for the current tick. The AI uses this instead
--- of economy.snapshot, whose full HUD summary (power, robots, every building) was most of the AI's time.
function construction.have(C, item)
  if C.have_tick ~= game.tick then
    C.have_tick, C.have = game.tick, {}
  end
  local n = C.have[item]
  if n then return n end
  n = 0
  for _, net in ipairs(economy.networks(C.force)) do n = n + net.get_item_count(item) end
  C.have[item] = n
  return n
end

--- True when the force produced `item` in the last minute (item production statistics), memoized per tick.
function construction.flowing(C, item)
  if C.flow_tick ~= game.tick then C.flow_tick, C.flow = game.tick, {} end
  local v = C.flow[item]
  if v == nil then
    local stats = game.forces[C.force].get_item_production_statistics(util.surface())
    v = stats.get_flow_count({name = item, category = "input",
                              precision_index = defines.flow_precision_index.one_minute}) > 0
    C.flow[item] = v
  end
  return v
end

--- True when the entry is built and its entity is alive.
function construction.is_built(C, key)
  local e = C.plan[key]
  return e ~= nil and e.status == "built" and e.entity ~= nil and e.entity.valid
end

--- "built" | "queued" | "ghost" | "planned" | "bad" | nil (an entry whose entity died counts as not built).
function construction.status(C, key)
  local e = C.plan[key]
  if not e then return nil end
  if e.status == "built" and not (e.entity and e.entity.valid) then return "planned" end
  return e.status
end

local function find_built(surface, C, e)
  local ent = surface.find_entity(e.name, {e.x, e.y})
  if ent and ent.valid and ent.force.name == C.force then return ent end
  return nil
end

local function mark_built(C, e, ent)
  e.status, e.entity, e.ghost = "built", ent, nil
  e.blocked_since, e.fail_since = nil, nil
end

local function mark_bad(C, e, why)
  if e.ghost and e.ghost.valid then e.ghost.destroy() end
  e.status, e.ghost = "bad", nil
  C.stats.bad = C.stats.bad + 1
  util.log("ai %s: construction gave up on %s at %s: %s", C.force, e.name, util.pos_str({e.x, e.y}), why)
end

-- Trees, rocks and items on the ground in the footprint go first (spike #5: revive returns nil while a tree blocks).
local function clear_footprint(surface, e)
  local tx0, ty0, w, h = layout.footprint(e.name, e.x, e.y)
  local n = 0
  for _, obstacle in pairs(surface.find_entities_filtered({area = {{tx0, ty0}, {tx0 + w, ty0 + h}},
                                                            type = CLEAR_TYPES})) do
    if obstacle.valid then
      obstacle.destroy()
      n = n + 1
    end
  end
  return n
end

local function place_ghost(C, surface, e)
  clear_footprint(surface, e)
  local g = surface.create_entity({name = "entity-ghost", inner_name = e.name, position = {e.x, e.y},
                                   direction = e.dir, force = C.force, create_build_effect_smoke = false})
  if g then
    e.status, e.ghost, e.blocked_since = "ghost", g, nil
    C.stats.ghosts = C.stats.ghosts + 1
    return true
  end
  if not e.blocked_since then
    e.blocked_since = game.tick
    util.log("ai %s: cannot place a %s ghost at %s yet", C.force, e.name, util.pos_str({e.x, e.y}))
  end
  return false
end

-- Own units standing on a footprint block the revive: send them to the rally point.
local function nudge_units(C, surface, e)
  local tx0, ty0, w, h = layout.footprint(e.name, e.x, e.y)
  local list = {}
  for _, u in pairs(surface.find_entities_filtered({area = {{tx0 - 1, ty0 - 1}, {tx0 + w + 1, ty0 + h + 1}},
                                                     force = C.force, type = {"spider-unit", "unit"}})) do
    if units.get(u.unit_number) then list[#list + 1] = u end
  end
  if #list > 0 and C.army and C.army.rally then orders.move(list, C.army.rally) end
end

-- 2.0 inserter direction semantics are probed (layout.probe_inserter); this double-checks the result once built.
local function check_inserter(C, e, ent)
  if not e.pickup or ent.type ~= "inserter" then return end
  local pp = ent.pickup_position
  if math.abs(pp.x - e.pickup[1]) < 0.3 and math.abs(pp.y - e.pickup[2]) < 0.3 then return end
  ent.direction = (ent.direction + 8) % 16
  util.log("ai %s: inserter at %s picked up from %s, turned around (now %s)", C.force, util.pos_str(ent.position),
    util.pos_str(pp), util.pos_str(ent.pickup_position))
end

local function revive(C, surface, e)
  local _, ent = e.ghost.revive({raise_revive = true})
  if ent and ent.valid then
    mark_built(C, e, ent)
    check_inserter(C, e, ent)
    C.stats.revived = C.stats.revived + 1
    return true
  end
  e.fail_since = e.fail_since or game.tick
  nudge_units(C, surface, e)
  return false
end

--- One construction pass for commander C: keep ghosts in place for the queue, then revive one job when it is due.
function construction.step(C, surface)
  local tick = game.tick
  local keep, made = {}, 0
  local pending, need, need_list = {}, {}, {}
  for _, key in ipairs(C.queue) do
    local e = C.plan[key]
    if e and (e.status == "queued" or e.status == "ghost") then
      if e.status == "ghost" and not (e.ghost and e.ghost.valid) then
        local ent = find_built(surface, C, e)
        if ent then mark_built(C, e, ent) else e.status, e.ghost = "queued", nil end
      end
      if e.status == "queued" then
        local ent = find_built(surface, C, e)
        if ent then
          mark_built(C, e, ent)
        elseif made < construction.GHOSTS_PER_PASS then
          made = made + 1
          place_ghost(C, surface, e)
        end
      end
      if e.status == "queued" and e.blocked_since and tick - e.blocked_since > construction.GIVE_UP_TICKS then
        mark_bad(C, e, "the spot stayed blocked")
      elseif e.status == "ghost" and e.fail_since and tick - e.fail_since > construction.GIVE_UP_TICKS then
        mark_bad(C, e, "revive kept failing")
      end
      if e.status == "queued" or e.status == "ghost" then
        keep[#keep + 1] = key
        pending[e.name] = (pending[e.name] or 0) + 1
        if not need[e.item] then need_list[#need_list + 1] = e.item end
        need[e.item] = (need[e.item] or 0) + 1
      end
    end
  end
  C.queue, C.pending, C.need, C.need_list = keep, pending, need, need_list

  if tick < (C.next_build or 0) then return end
  local cfg = C.cfg
  local job, smalls, names, lacking = nil, 0, {}, {}
  for _, key in ipairs(C.queue) do
    local e = C.plan[key]
    if e.status == "ghost" and e.ghost and e.ghost.valid and not lacking[e.item]
       and not (e.clear and units_in_clear(C, surface, e)) then
      local small = construction.SMALL[e.name] == true
      if job == nil or (job == "small" and small) then
        if economy.take(C.force, e.item, 1) ~= 1 then
          lacking[e.item] = true
        else
          if revive(C, surface, e) then
            if small then
              job = "small"
              smalls = smalls + 1
              names[e.name] = (names[e.name] or 0) + 1
            else
              job = "building"
              util.log("ai %s: built %s at %s (%d jobs queued)", C.force, e.name, util.pos_str({e.x, e.y}),
                #C.queue - 1)
            end
          else
            economy.give(C.force, e.item, 1)
          end
        end
      end
      if job == "building" or smalls >= cfg.small_batch then break end
    end
  end
  if job then
    C.next_build = tick + cfg.build_period
    C.stats.jobs = C.stats.jobs + 1
    if job == "small" then
      local parts = {}
      for n, c in pairs(names) do parts[#parts + 1] = c .. " " .. n end
      table.sort(parts)
      util.log("ai %s: built %s (%d jobs queued)", C.force, table.concat(parts, ", "), #C.queue)
    end
  end
end

--- Re-queue every built entry whose entity is gone (rebuild what the enemy destroyed). Returns the count.
function construction.repair(C)
  local n = 0
  for key, e in pairs(C.plan) do
    if e.status == "built" and not (e.entity and e.entity.valid) then
      e.status, e.entity = "planned", nil
      if construction.queue(C, key) then n = n + 1 end
    end
  end
  if n > 0 then util.log("ai %s: %d destroyed entities queued for rebuilding", C.force, n) end
  return n
end

return construction
