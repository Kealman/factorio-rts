-- Building registry (docs/PHASE2.md "Control stage additions"). Owns storage.buildings:
--
--   storage.buildings[unit_number] = {
--     entity   = LuaEntity,
--     kind     = "cc" | "barracks" | "factory" | "turret" | "extractor" | "smelter" | "stockpile" | "solar",
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

--- fn(unit_number, record) after a building is registered. Call at load time (module top level).
function buildings.on_added(fn) added_callbacks[#added_callbacks + 1] = fn end

--- fn(unit_number, record) after a building left the registry (record.entity may be invalid). Load time only.
function buildings.on_removed(fn) removed_callbacks[#removed_callbacks + 1] = fn end

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
function buildings.main_cc(force_name)
  local best_un, best
  for un, rec in buildings.for_force(force_name, "cc") do
    if not best_un or un < best_un then best_un, best = un, rec end
  end
  return best, best_un
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
-- Events
---------------------------------------------------------------------------
local function on_built(e)
  local entity = e.entity or e.destination
  if entity and entity.valid and buildings.KIND_BY_NAME[entity.name] then buildings.register(entity) end
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
