-- Building registry (docs/PHASE2.md "Control stage additions"). Owns storage.buildings:
--
--   storage.buildings[unit_number] = {
--     entity   = LuaEntity,
--     kind     = "cc" | "barracks" | "factory" | "turret" | "extractor" | "smelter" | "stockpile" | "solar",
--                Phase 4: "laser-turret" | "wall" | "steam-plant" | "accumulator" | "radar" (below), "lab"
--                (scripts/research.lua) and "hub" (scripts/logistics.lua), which those modules add at load time,
--     force    = force name,
--     surface  = surface index,
--     position = MapPosition (copied at registration; used after the entity is gone),
--     rally    = MapPosition?  barracks only: where new units walk to (nil = stay at the default exit,
--                              see buildings.rally_point). Written by buildings.set_rally.
--     parts    = {power = LuaEntity, pole = LuaEntity}?  cc only: the hidden rts-core-power and
--                              rts-core-pole of this Command Center. Destroyed with the CC.
--     -- production.lua adds its own fields: last_pf, next_check, pull_state, feed_state, spawned.
--   }
--
-- Registration: on_built_entity, on_robot_built_entity, script_raised_built, script_raised_revive,
-- on_entity_cloned (clone_area templates) and buildings.register(entity). Entities on the template scratch
-- surface are never registered. Removal: on_entity_died, on_player_mined_entity, on_robot_mined_entity and
-- on_object_destroyed (every registered entity is passed to register_on_object_destroyed), whichever comes
-- first. When a CC goes, its core parts are destroyed too (docs/qa/phase2-prototypes-notes.md gotcha 7).
local util = require("scripts.util")
local events = require("scripts.events")
local balance = require("balance")

local buildings = {}

buildings.SCRATCH_SURFACE = "rts-scratch" -- basetemplate.lua builds the template there; never registered

buildings.KIND_BY_NAME = {
  ["rts-command-center"] = "cc",
  ["rts-barracks"] = "barracks",
  ["rts-factory"] = "factory",
  ["rts-turret"] = "turret",
  ["rts-extractor"] = "extractor",
  ["rts-smelter"] = "smelter",
  ["rts-stockpile"] = "stockpile",
  ["rts-solar-array"] = "solar",
  -- Phase 4 defence and power (prototypes/buildings.lua; kinds as in balance.buildings[name].kind). The laser turret
  -- is not "turret": production.lua feeds kind "turret" with magazines, the AI budgets magazines per "turret" and
  -- counts build-order steps by kind_of(name). Every wall segment is a building (one on_object_destroyed
  -- registration each), so damage to a wall raises base-attacked alerts and counts as a base threat for the AI.
  ["rts-laser-turret"] = "laser-turret",
  ["rts-wall"] = "wall",
  ["rts-steam-plant"] = "steam-plant",
  ["rts-accumulator"] = "accumulator",
  ["rts-radar"] = "radar",
  -- Phase 5 M1 (prototypes/cities.lua, Nation mode): the City Center is a hub subtype (logistics.lua builds its
  -- composite like a hub's; scripts/cities.lua tells it apart by name); the fort is a strongpoint and a territory source.
  ["rts-city-center"] = "hub",
  ["rts-fort"] = "fort",
}

buildings.CC_NAME = "rts-command-center"
buildings.CORE_POWER = "rts-core-power"
buildings.CORE_POLE = "rts-core-pole"

-- Command Center composite, offsets from the CC centre (the CC is 4x4, so its centre is on a tile corner).
-- The four 1x1 stockpiles sit one tile left and right of the CC body, 1 tile above and below its axis.
buildings.CC_STOCKPILES = {{x = -3.5, y = -1.5}, {x = -3.5, y = 1.5}, {x = 3.5, y = -1.5}, {x = 3.5, y = 1.5}}
buildings.CC_BOTS = {["construction-robot"] = 20, ["logistic-robot"] = 10}

-- Default exit of a barracks: this many tiles from its centre towards ARENA_CENTRE.
buildings.EXIT_DISTANCE = 6
buildings.ARENA_CENTRE = {x = 0, y = 0}

local added_callbacks, removed_callbacks = {}, {}
local build_checks = {} -- Phase 5 M1: build rules (scripts/territory.lua), see buildings.on_build_check

--- fn(unit_number, record) after a building is registered. Call at load time (module top level).
function buildings.on_added(fn) added_callbacks[#added_callbacks + 1] = fn end

--- fn(unit_number, record) after a building left the registry (record.entity may be invalid). Load time only.
function buildings.on_removed(fn) removed_callbacks[#removed_callbacks + 1] = fn end

--- Phase 5 M1: fn(entity, event) -> false when it refused the build (and removed the entity), for every entity or
--- ghost the build events below report, before it is registered. Load time only (scripts/territory.lua).
function buildings.on_build_check(fn) build_checks[#build_checks + 1] = fn end

function buildings.init()
  storage.buildings = storage.buildings or {}
end

---------------------------------------------------------------------------
-- Core parts of a Command Center
---------------------------------------------------------------------------
local function find_parts(surface, position, force)
  local found = surface.find_entities_filtered({position = position, radius = 0.5, force = force,
                                                name = {buildings.CORE_POWER, buildings.CORE_POLE}})
  local parts = {}
  for _, e in pairs(found) do
    if e.name == buildings.CORE_POWER then parts.power = e else parts.pole = e end
  end
  return parts
end

--- The {power, pole} core parts of a CC record. Looks them up at the CC's position when they are not known
--- yet (clones: the CC can be cloned before its parts) and only while the CC itself is still valid.
function buildings.core_parts(rec)
  local parts = rec.parts
  if parts and parts.power and parts.power.valid and parts.pole and parts.pole.valid then return parts end
  if not rec.entity.valid then return parts or {} end
  local found = find_parts(rec.entity.surface, rec.entity.position, rec.entity.force)
  if found.power or found.pole then rec.parts = found end
  return rec.parts or {}
end

local function destroy_parts(rec, died_entity)
  local parts = rec.parts
  if not parts and died_entity and died_entity.valid then
    -- Not resolved yet: whatever core parts sit under the dying CC are its own (it still occupies the spot).
    parts = find_parts(died_entity.surface, died_entity.position, died_entity.force)
  end
  local n = 0
  for _, e in pairs(parts or {}) do
    if e.valid then
      e.destroy()
      n = n + 1
    end
  end
  return n
end

---------------------------------------------------------------------------
-- Registry
---------------------------------------------------------------------------
--- Kind of an entity name ("cc", "barracks", ...), or nil when it is not a registered building.
function buildings.kind_of(name)
  return buildings.KIND_BY_NAME[name]
end

--- Register a building entity (idempotent). Returns the record, or nil for non-buildings, ghosts and
--- entities on the template scratch surface.
function buildings.register(entity)
  if not (entity and entity.valid) then return nil end
  local kind = buildings.KIND_BY_NAME[entity.name]
  if not kind then return nil end
  if entity.surface.name == buildings.SCRATCH_SURFACE then return nil end
  local un = entity.unit_number
  local rec = storage.buildings[un]
  if rec then return rec end
  local p = entity.position
  rec = {entity = entity, kind = kind, force = entity.force.name, surface = entity.surface.index,
         position = {x = p.x, y = p.y}}
  storage.buildings[un] = rec
  script.register_on_object_destroyed(entity)
  if kind == "cc" then buildings.core_parts(rec) end
  for i = 1, #added_callbacks do added_callbacks[i](un, rec) end
  return rec
end

local function remove(un, died_entity, why)
  local rec = storage.buildings[un]
  if not rec then return end
  storage.buildings[un] = nil
  local parts = 0
  if rec.kind == "cc" then parts = destroy_parts(rec, died_entity) end
  if rec.kind == "cc" or rec.kind == "barracks" or rec.kind == "factory" then
    util.log("buildings: %s #%d of %s at %s removed (%s)%s", rec.kind, un, rec.force, util.pos_str(rec.position),
      why, rec.kind == "cc" and string.format(", %d core parts destroyed", parts) or "")
  end
  for i = 1, #removed_callbacks do removed_callbacks[i](un, rec) end
end

--- Live record of a building, or nil (stale records are dropped).
function buildings.get(unit_number)
  local rec = storage.buildings[unit_number]
  if not rec then return nil end
  if not rec.entity.valid then
    remove(unit_number, nil, "invalid")
    return nil
  end
  return rec
end

--- Iterator over (unit_number, record) of the live buildings of a force, optionally of one kind:
---   for un, rec in buildings.for_force("rts-player", "barracks") do ... end
function buildings.for_force(force_name, kind)
  local list = storage.buildings
  local key
  return function()
    while true do
      local rec
      key, rec = next(list, key)
      if key == nil then return nil end
      if rec.force == force_name and (not kind or rec.kind == kind) and rec.entity.valid then return key, rec end
    end
  end
end

--- Iterator over (unit_number, record) of every live building of one kind (all forces).
function buildings.all(kind)
  local list = storage.buildings
  local key
  return function()
    while true do
      local rec
      key, rec = next(list, key)
      if key == nil then return nil end
      if (not kind or rec.kind == kind) and rec.entity.valid then return key, rec end
    end
  end
end

--- Number of live buildings of a force, optionally of one kind.
function buildings.count(force_name, kind)
  local n = 0
  for _ in buildings.for_force(force_name, kind) do n = n + 1 end
  return n
end

--- True while the force still has a Command Center, a barracks or a factory.
function buildings.is_alive_force(force_name)
  for _, rec in buildings.for_force(force_name) do
    if rec.kind == "cc" or rec.kind == "barracks" or rec.kind == "factory" then return true end
  end
  return false
end

--- The first live CC record of a force (lowest unit number), or nil.
--- Phase 5 M2 war: a Command Center the force captured (rec.origin, another force) counts only when it has no own CC.
function buildings.main_cc(force_name)
  local best_un, best, alt_un, alt
  for un, rec in buildings.for_force(force_name, "cc") do
    if rec.origin and rec.origin ~= force_name then
      if not alt_un or un < alt_un then alt_un, alt = un, rec end
    elseif not best_un or un < best_un then
      best_un, best = un, rec
    end
  end
  if best then return best, best_un end
  return alt, alt_un
end

---------------------------------------------------------------------------
-- Phase 5 M2 war: capture gives buildings to another force in place (scripts/capture.lua)
---------------------------------------------------------------------------
local force_changed_callbacks = {}
--- fn(unit_number, record, old_force) after a registered building changed its force (buildings.set_force). Load time.
function buildings.on_force_changed(fn) force_changed_callbacks[#force_changed_callbacks + 1] = fn end

--- Give an entity to another force in place. A registered building keeps its record: rec.force follows, rec.origin
--- keeps the force it was built by, and the on_force_changed callbacks run (logistics, territory, rails, cities).
--- Returns the record, or nil for an entity that is not a registered building.
function buildings.set_force(entity, force_name)
  if not (entity and entity.valid) then return nil end
  local un = entity.unit_number
  local rec = un and storage.buildings[un] or nil
  local old = entity.force.name
  if old == force_name then return rec end
  entity.force = force_name
  if not rec then return nil end
  rec.origin = rec.origin or old
  rec.force = force_name
  for i = 1, #force_changed_callbacks do force_changed_callbacks[i](un, rec, old) end
  return rec
end

---------------------------------------------------------------------------
-- Rally points
---------------------------------------------------------------------------
--- Default exit of a building: EXIT_DISTANCE tiles from its centre towards the arena centre.
function buildings.default_exit(rec)
  local p = rec.entity.valid and rec.entity.position or rec.position
  local c = buildings.ARENA_CENTRE
  local dx, dy = c.x - p.x, c.y - p.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.001 then dx, dy, len = 1, 0, 1 end
  local d = buildings.EXIT_DISTANCE
  return {x = p.x + dx / len * d, y = p.y + dy / len * d}
end

--- Set (position) or clear (nil) the rally point of a barracks. Returns true when the record exists.
function buildings.set_rally(unit_number, position)
  local rec = buildings.get(unit_number)
  if not rec then return false end
  if position then
    local x, y = util.xy(position)
    rec.rally = {x = x, y = y}
  else
    rec.rally = nil
  end
  return true
end

--- Where units of this barracks end up: its rally point if set, else its default exit.
function buildings.rally_point(unit_number)
  local rec = buildings.get(unit_number)
  if not rec then return nil end
  return rec.rally or buildings.default_exit(rec)
end

---------------------------------------------------------------------------
-- Command Center composite
---------------------------------------------------------------------------
--- Place the full CC composite: rts-command-center + rts-core-power + rts-core-pole at `position` (rounded to
--- a tile corner), 4 rts-stockpile at CC_STOCKPILES, CC_BOTS in the CC. The CC's 200 MJ buffer is filled
--- (LuaEntity.energy is writable for the roboport), so it does not draw 2 MW from the core for ~95 s.
--- Returns cc, {power, pole, stockpiles = {...}} or nil when the CC could not be created.
function buildings.place_cc(surface, position, force)
  local px, py = util.xy(position)
  local x, y = math.floor(px + 0.5), math.floor(py + 0.5)
  local force_name = type(force) == "string" and force or force.name
  local cc = surface.create_entity({name = buildings.CC_NAME, position = {x, y}, force = force_name})
  if not cc then
    util.log("buildings: place_cc failed for %s at (%d, %d)", force_name, x, y)
    return nil
  end
  local power = surface.create_entity({name = buildings.CORE_POWER, position = {x, y}, force = force_name})
  local pole = surface.create_entity({name = buildings.CORE_POLE, position = {x, y}, force = force_name})
  local stockpiles = {}
  for _, off in ipairs(buildings.CC_STOCKPILES) do
    local s = surface.create_entity({name = "rts-stockpile", position = {x + off.x, y + off.y}, force = force_name})
    if s then stockpiles[#stockpiles + 1] = s end
  end
  local robots = cc.get_inventory(defines.inventory.roboport_robot)
  for name, count in pairs(buildings.CC_BOTS) do robots.insert({name = name, count = count}) end
  local buffer = cc.electric_buffer_size or 0
  cc.energy = buffer
  local rec = buildings.register(cc)
  if rec then rec.parts = {power = power, pole = pole} end
  for _, s in ipairs(stockpiles) do buildings.register(s) end
  util.log("buildings: CC composite for %s at (%d, %d) on %s: core power=%s pole=%s stockpiles=%d bots=%d "
    .. "buffer %.0f/%.0f MJ", force_name, x, y, surface.name, tostring(power ~= nil), tostring(pole ~= nil),
    #stockpiles, robots.get_item_count(), cc.energy / 1e6, buffer / 1e6)
  return cc, {power = power, pole = pole, stockpiles = stockpiles}
end

---------------------------------------------------------------------------
-- Demolition (docs/qa/phase5-m1-protocol-notes.md "Demolish"; scripts/demolish.lua is the player-facing part)
---------------------------------------------------------------------------
buildings.REFUND_RATIO = 0.5  -- share of the item cost that comes back
buildings.SINK_RANGE = 40     -- tiles: where a building without a logistic network looks for a stockpile
buildings.REFUND_RANGE = 64   -- tiles: other own stockpiles a refund may go to when its network has none (M1)
-- Inventories whose items are recovered when their building goes (stockpile chest, turret ammo, furnace and
-- assembler slots, fuel, lab inputs); roboport robots go down with the building.
buildings.CONTENT_INVENTORIES = {"chest", "turret_ammo", "fuel", "furnace_source", "furnace_result",
                                 "furnace_modules", "crafter_input", "crafter_output", "lab_input"}
local demolish_checks, demolish_parts = {}, {}

--- fn(rec) -> reason string when the building must not be demolished, else nil. Load time only.
function buildings.on_demolish_check(fn) demolish_checks[#demolish_checks + 1] = fn end

--- fn(rec) -> array of LuaEntity that are part of this building (hub stockpiles): they go with it, free of refund,
--- and their contents are recovered. Load time only (scripts/logistics.lua).
function buildings.on_demolish_parts(fn) demolish_parts[#demolish_parts + 1] = fn end

--- Why a building cannot be demolished: "protected" for a Command Center or a capital City Center, a hook's reason,
--- or nil when it can.
function buildings.demolish_blocked(rec)
  if rec.kind == "cc" then return "protected" end
  -- Phase 5 M1 (rails.lua): rolling stock is a building of kind "train"; removing one carriage breaks the train
  if rec.kind == "train" then return "rolling-stock" end
  -- Nation mode (scripts/cities.lua): the capital's City Center. Read from storage, no module dependency.
  local cs = storage.city_state
  local id = cs and cs.by_center and rec.entity.valid and cs.by_center[rec.entity.unit_number]
  local city = id and storage.cities and storage.cities[id]
  if city and city.capital then return "protected" end
  for i = 1, #demolish_checks do
    local why = demolish_checks[i](rec)
    if why then return why end
  end
  return nil
end

--- {[item] = amount, count = items per craft} of a building prototype's cost: balance.buildings, else its recipe
--- (hub, lab, ...). nil when it has none.
function buildings.item_cost(name)
  local b = balance.buildings[name]
  if b and b.cost then return b.cost, b.count or 1 end
  local recipe = prototypes.recipe[name]
  local item = name
  if not recipe then
    -- Phase 5 M1 integration: an entity placed by an item of another name (rts-city-center <- rts-city-charter)
    local proto = prototypes.entity[name]
    local places = proto and proto.items_to_place_this
    local first = places and places[1]
    item = first and (first.name or first) or nil
    recipe = item and prototypes.recipe[item] or nil
    local b2 = item and balance.buildings[item]
    if b2 and b2.cost then return b2.cost, b2.count or 1 end
  end
  if not recipe then return nil end
  local cost, count = {}, 1
  for _, ing in pairs(recipe.ingredients) do
    if ing.type == "item" then cost[ing.name] = (cost[ing.name] or 0) + ing.amount end
  end
  for _, prod in pairs(recipe.products) do
    if prod.name == item then count = prod.amount or 1 end
  end
  return cost, count
end

-- Nearest own stockpile (not in `exclude`) on the logistic network `net_id`; without a network, within SINK_RANGE.
local function sink_candidates(surface_index, force_name, position, net_id, exclude)
  local list = {}
  for un, rec in pairs(storage.buildings) do
    if rec.kind == "stockpile" and rec.force == force_name and rec.surface == surface_index
       and not exclude[un] and rec.entity.valid then
      local e = rec.entity
      local d = util.distance(e.position, position)
      local net = e.logistic_network
      local ok
      if net_id then ok = net and net.valid and net.network_id == net_id else ok = d <= buildings.SINK_RANGE end
      if ok then list[#list + 1] = {entity = e, d = d} end
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  return list
end

-- Insert item stacks ({name, count, quality}) into the candidates in order. Returns what did not fit.
local function insert_into(candidates, stacks)
  local rest = {}
  for _, st in ipairs(stacks) do
    local left = st.count
    for _, c in ipairs(candidates) do
      if left <= 0 then break end
      if c.entity.valid then left = left - c.entity.insert({name = st.name, count = left, quality = st.quality}) end
    end
    if left > 0 then rest[#rest + 1] = {name = st.name, count = left, quality = st.quality} end
  end
  return rest
end

local function spill(surface, position, stacks)
  local n = 0
  for _, st in ipairs(stacks) do
    surface.spill_item_stack({position = position, stack = {name = st.name, count = st.count, quality = st.quality},
                              enable_looted = false, allow_belts = false})
    n = n + st.count
  end
  return n
end

-- Items in the recovered inventories of an entity, emptied: array of {name, count, quality}.
local function take_contents(entity)
  local out = {}
  for _, key in ipairs(buildings.CONTENT_INVENTORIES) do
    local id = defines.inventory[key]
    local inv = id and entity.get_inventory(id)
    if inv and inv.valid then
      for _, item in pairs(inv.get_contents()) do
        out[#out + 1] = {name = item.name, count = item.count, quality = item.quality}
      end
      inv.clear()
    end
  end
  return out
end

--- Demolish one own building (or cancel a ghost). Removes it through the registry first (on_removed callbacks:
--- hub parts, logistics policy, territory, cities, selection), then destroys it and its parts. Attached stockpiles
--- (hub), hidden parts and contents are handled; contents go to the nearest other own stockpile (same logistic
--- network) and what does not fit is spilled. 50 % of the item cost goes into the nearest own stockpile of the
--- building's network (the rest is dropped).
--- opts: force = force name that must own it, refund = false (no refund), exclude = {[unit_number] = true} stockpiles
--- that are going too (a batch), carry = table that collects fractional refunds across a batch.
--- opts.carry also keeps the sub-item remainders between calls (5 walls cost 5 bricks: 2 walls refund 1).
--- Returns true, info {name, kind, position, refund = {[item] = n}, moved = n, spilled = n, parts = n} or false,
--- reason ("invalid" | "not-building" | "protected" | "foreign" | a hook's reason).
function buildings.demolish(entity, opts)
  opts = opts or {}
  if not (entity and entity.valid) then return false, "invalid" end
  if opts.force and entity.force.name ~= opts.force then return false, "foreign" end
  if entity.type == "entity-ghost" then
    local name = entity.ghost_name
    local p = entity.position
    entity.destroy()
    return true, {name = name, kind = "ghost", position = {x = p.x, y = p.y}, refund = {}, moved = 0, spilled = 0,
                  parts = 0}
  end
  local un = entity.unit_number
  local rec = un and storage.buildings[un]
  if not rec then return false, "not-building" end
  local why = buildings.demolish_blocked(rec)
  if why then return false, why end

  local surface, force_name, pos, name = entity.surface, rec.force, entity.position, entity.name
  local exclude = opts.exclude or {}
  exclude[un] = true
  local part_entities = {}
  for i = 1, #demolish_parts do
    for _, part in ipairs(demolish_parts[i](rec) or {}) do
      if part.valid and part.unit_number then
        part_entities[#part_entities + 1] = part
        exclude[part.unit_number] = true
      end
    end
  end

  -- The network is read while the entity still exists (a hub is its own network node).
  local net = entity.logistic_network
  if not (net and net.valid) then net = surface.find_logistic_network_by_position(pos, force_name) end
  local net_id = net and net.valid and net.network_id or nil
  local sinks = sink_candidates(rec.surface, force_name, pos, net_id, exclude)

  local contents = take_contents(entity)
  local parts = 0
  for _, part in ipairs(part_entities) do
    if part.valid then
      for _, st in ipairs(take_contents(part)) do contents[#contents + 1] = st end
      local pun = part.unit_number
      if storage.buildings[pun] then remove(pun, part, "demolished (part)") end
      part.destroy()
      parts = parts + 1
    end
  end
  remove(un, entity, "demolished")
  entity.destroy()

  local refund = {}
  if opts.refund ~= false then
    local cost, count = buildings.item_cost(name)
    local carry = opts.carry
    for item, amount in pairs(cost or {}) do
      local exact = amount / count * buildings.REFUND_RATIO + ((carry and carry[item]) or 0)
      local whole = math.floor(exact + 1e-9)
      if carry then carry[item] = exact - whole end
      if whole > 0 then refund[item] = whole end
    end
  end
  local stacks = {}
  for item, n in pairs(refund) do stacks[#stacks + 1] = {name = item, count = n} end
  local refunded = {}
  local lost = insert_into(sinks, stacks)
  -- Phase 5 M1 integration: a lone hub or City Center (no other stockpile in its network) refunds into the nearest
  -- other own stockpile within REFUND_RANGE tiles, else into the force's pool (the Command Center's network); what
  -- still has no room spills on the ground and the player gets an alert (demolish.lua), never a silent loss
  if #lost > 0 and opts.refund ~= false then
    local near = {}
    for sun, r in pairs(storage.buildings) do
      if r.kind == "stockpile" and r.force == force_name and r.surface == rec.surface and not exclude[sun]
         and r.entity.valid then
        local d = util.distance(r.entity.position, pos)
        if d <= buildings.REFUND_RANGE then near[#near + 1] = {entity = r.entity, d = d, un = sun} end
      end
    end
    table.sort(near, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.un < b.un end)
    lost = insert_into(near, lost)
  end
  if #lost > 0 and opts.refund ~= false then
    local cc = buildings.main_cc(force_name)
    local pool = cc and cc.entity.valid and cc.entity.logistic_network
    if pool and pool.valid then
      local rest = {}
      for _, st in ipairs(lost) do
        local n = pool.insert({name = st.name, count = st.count})
        if n < st.count then rest[#rest + 1] = {name = st.name, count = st.count - n} end
      end
      lost = rest
    end
  end
  local refund_spilled = #lost > 0 and spill(surface, pos, lost) or 0 -- on the ground, with an alert (demolish.lua)
  local lost_by = {}
  for _, st in ipairs(lost) do lost_by[st.name] = st.count end
  for item, n in pairs(refund) do refunded[item] = n - (lost_by[item] or 0) end

  local total = 0
  for _, st in ipairs(contents) do total = total + st.count end
  local rest = insert_into(sinks, contents)
  local spilled = spill(surface, pos, rest)
  local lost_n = 0
  for _, st in ipairs(lost) do lost_n = lost_n + st.count end
  local shown = {}
  for item, n in pairs(refunded) do
    if n > 0 then shown[#shown + 1] = n .. " " .. item end
  end
  table.sort(shown)
  util.log("buildings: demolished %s #%d (%s) of %s at %s: refund [%s]%s, contents %d (%d spilled), %d parts", name, un,
    rec.kind, force_name, util.pos_str(pos), table.concat(shown, ", "),
    lost_n > 0 and string.format(" (%d spilled on the ground, no stockpile with room)", lost_n) or "", total, spilled,
    parts)
  return true, {name = name, kind = rec.kind, position = {x = pos.x, y = pos.y}, refund = refunded,
                moved = total - spilled, spilled = spilled, parts = parts, unit_number = un,
                refund_spilled = refund_spilled}
end

--- Deliver item stacks ({name, count, quality}) of a removed non-building piece (belt, inserter, pole; scripts/pieces.lua):
--- into the nearest own stockpile of the logistic network at `position`, else (no network) a stockpile within
--- SINK_RANGE, else another own stockpile within REFUND_RANGE, else the Command Center's network; what has no room
--- spills on the ground. The same cascade as the refund of buildings.demolish. Returns delivered, spilled (item counts).
function buildings.deliver_items(surface, force_name, position, stacks)
  if #stacks == 0 then return 0, 0 end
  local net = surface.find_logistic_network_by_position(position, force_name)
  local net_id = net and net.valid and net.network_id or nil
  local rest = insert_into(sink_candidates(surface.index, force_name, position, net_id, {}), stacks)
  if #rest > 0 then
    local near = {}
    for sun, r in pairs(storage.buildings) do
      if r.kind == "stockpile" and r.force == force_name and r.surface == surface.index and r.entity.valid then
        local d = util.distance(r.entity.position, position)
        if d <= buildings.REFUND_RANGE then near[#near + 1] = {entity = r.entity, d = d, un = sun} end
      end
    end
    table.sort(near, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.un < b.un end)
    rest = insert_into(near, rest)
  end
  if #rest > 0 then
    local cc = buildings.main_cc(force_name)
    local pool = cc and cc.entity.valid and cc.entity.logistic_network
    if pool and pool.valid then
      local left = {}
      for _, st in ipairs(rest) do
        local n = pool.insert({name = st.name, count = st.count, quality = st.quality})
        if n < st.count then left[#left + 1] = {name = st.name, count = st.count - n, quality = st.quality} end
      end
      rest = left
    end
  end
  local total = 0
  for _, st in ipairs(stacks) do total = total + st.count end
  local spilled = #rest > 0 and spill(surface, position, rest) or 0
  return total - spilled, spilled
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function on_built(e)
  local entity = e.entity or e.destination
  if not (entity and entity.valid) then return end
  for i = 1, #build_checks do
    if not build_checks[i](entity, e) then return end -- Phase 5 M1: refused (territory), already removed
  end
  if buildings.KIND_BY_NAME[entity.name] then buildings.register(entity) end
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)
events.on(defines.events.script_raised_built, on_built)
events.on(defines.events.script_raised_revive, on_built)

-- Template clones: the scratch copies are disabled by script (basetemplate.lua), the clones must run.
events.on(defines.events.on_entity_cloned, function(e)
  local dst = e.destination
  if not (dst and dst.valid) or dst.surface.name == buildings.SCRATCH_SURFACE then return end
  if e.source.valid and e.source.surface.name == buildings.SCRATCH_SURFACE and dst.disabled_by_script then
    dst.disabled_by_script = false
  end
  if buildings.KIND_BY_NAME[dst.name] then buildings.register(dst) end
end)

-- After a whole area is cloned every core part exists: resolve the parts of the cloned CCs.
events.on(defines.events.on_area_cloned, function(e)
  local area = e.destination_area
  for _, rec in buildings.all("cc") do
    local p = rec.entity.position
    if rec.surface == e.destination_surface.index and p.x >= area.left_top.x and p.x <= area.right_bottom.x
       and p.y >= area.left_top.y and p.y <= area.right_bottom.y then
      rec.parts = nil
      buildings.core_parts(rec)
    end
  end
end)

events.on(defines.events.on_entity_died, function(e)
  local entity = e.entity
  local un = entity.unit_number
  if un and storage.buildings[un] then remove(un, entity, "died") end
end)

local function on_mined(e)
  local entity = e.entity
  local un = entity.unit_number
  if un and storage.buildings[un] then remove(un, entity, "mined") end
end
events.on(defines.events.on_player_mined_entity, on_mined)
events.on(defines.events.on_robot_mined_entity, on_mined)

events.on(defines.events.on_object_destroyed, function(e)
  if e.type == defines.target_type.entity and storage.buildings[e.useful_id] then
    remove(e.useful_id, nil, "destroyed")
  end
end)

return buildings
