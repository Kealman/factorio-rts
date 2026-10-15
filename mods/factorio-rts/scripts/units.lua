-- Unit registry. Owns storage.units:
--
--   storage.units[unit_number] = {
--     entity = LuaEntity,
--     force  = "rts-player" | "rts-enemy",
--     kind   = "walker" | "heavy" | ...,
--     order  = "idle" | "move" | "attack" | "attack_move" | "hold" | ...,  -- written by orders.lua (*)
--     target = LuaEntity?,       -- orders.lua
--     dest   = MapPosition?,     -- orders.lua
--   }
--
-- (*) `order` is the claim on a unit: any value other than "idle" means some module drives the unit and
-- handles its on_ai_command_completed. orders.lua owns it for player orders; match.lua's enemy brain
-- writes "attack_move" for rts-enemy wave members; debug.lua's autotest writes "autotest" for its units.
-- units.lua only creates records with order = "idle" and applies the idle rule below.
--
-- Idle rule (spike decision 3): units with no command wander 8-12 tiles, so whenever an unclaimed unit
-- finishes a command it gets `defines.command.stop` (which never completes and still fights back).
local util = require("scripts.util")
local events = require("scripts.events")

local units = {}

units.IDLE = "idle"

local KIND_BY_NAME = {
  ["rts-walker"] = "walker",
  ["rts-walker-heavy"] = "heavy",
}

local removed_callbacks = {}

--- Register fn(unit_number, record) called when a unit leaves the registry (death or destruction).
--- Call at load time only (module top level). selection.lua uses this to drop dead units.
function units.on_removed(fn)
  removed_callbacks[#removed_callbacks + 1] = fn
end

function units.init()
  storage.units = storage.units or {}
end

local function remove(unit_number)
  local rec = storage.units[unit_number]
  if not rec then return end
  storage.units[unit_number] = nil
  for i = 1, #removed_callbacks do removed_callbacks[i](unit_number, rec) end
end

--- Issue `stop` (hold still, still return fire) to a unit entity.
function units.stop(entity)
  local c = entity.commandable
  if c then c.set_command({type = defines.command.stop}) end
end

--- Spawn a unit near `position` and register it. Returns entity, record (nil when it could not be placed).
function units.spawn(name, position, force_name, kind, surface)
  surface = surface or util.surface()
  local pos = surface.find_non_colliding_position(name, position, 8, 0.5) or position
  local entity = surface.create_entity({name = name, position = pos, force = force_name})
  if not entity then return nil end
  local rec = {
    entity = entity,
    force = force_name,
    kind = kind or KIND_BY_NAME[name] or name,
    order = units.IDLE,
  }
  storage.units[entity.unit_number] = rec
  script.register_on_object_destroyed(entity)
  units.stop(entity)
  return entity, rec
end

--- Record of a live registered unit, or nil (stale records are dropped).
function units.get(unit_number)
  local rec = storage.units[unit_number]
  if not rec then return nil end
  if not rec.entity.valid then
    remove(unit_number)
    return nil
  end
  return rec
end

--- Iterator over (unit_number, record) of the live units of one force:
---   for un, rec in units.for_force("rts-player") do ... end
function units.for_force(force_name)
  local list = storage.units
  local key
  return function()
    while true do
      local rec
      key, rec = next(list, key)
      if key == nil then return nil end
      if rec.force == force_name and rec.entity.valid then return key, rec end
    end
  end
end

--- Number of live units of a force, optionally of one kind.
function units.count(force_name, kind)
  local n = 0
  for _, rec in units.for_force(force_name) do
    if not kind or rec.kind == kind then n = n + 1 end
  end
  return n
end

--- Average position of a force's live units, or nil.
function units.centroid(force_name)
  local list = {}
  for _, rec in units.for_force(force_name) do list[#list + 1] = rec.entity end
  return util.centroid(list)
end

events.on(defines.events.on_entity_died, function(e)
  local entity = e.entity
  local un = entity.unit_number
  if un and storage.units[un] then remove(un) end
end)

events.on(defines.events.on_object_destroyed, function(e)
  if e.type == defines.target_type.entity and storage.units[e.useful_id] then remove(e.useful_id) end
end)

events.on(defines.events.on_ai_command_completed, function(e)
  local rec = storage.units[e.unit_number]
  if not rec then return end -- unit groups and foreign units
  if not rec.entity.valid then
    remove(e.unit_number)
    return
  end
  if rec.order == units.IDLE then units.stop(rec.entity) end
end)

return units
