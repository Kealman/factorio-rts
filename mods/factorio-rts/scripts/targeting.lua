-- Phase 5 M2 integration: Nation-mode attack-move targeting (docs/qa/phase5-m2-integration-notes.md, work item B1).
--
-- Problem (docs/qa/phase5-war-notes.md open issue 3): attack-moves shot rails, signals and poles on the way and cut
-- rail lines near every battle. Probe (tools/probes/rail_targeting.lua, enemy rails, a signal, a pole, a belt, an
-- inserter, a factory, an extractor and a stockpile crossed by four walkers per lane):
--   attack_area + by_anything (the Skirmish attack-move) kills the signal, pole, belt and inserter in passing;
--   attack_area + by_enemy passing the row damages nothing (none of those is a military target);
--   any attack_area kills every enemy entity inside its radius once no military target is left (rails included).
-- Making every building a military target (run-time is_military_target) also kept the rails, but then the attackers
-- razed a besieged city's factories before the capture (the war autotest's capture_unrest lost its factory), which is
-- against "cities are captured, not razed" (D4). Rule (Nation mode only; Skirmish keeps every command as it was):
--   * an attack-move leg is go_to_location with distraction by_enemy: on the way units fight military targets (units,
--     turrets, Command and City Centers, barracks, hubs, depots, districts, radars, rolling stock) and nothing else;
--   * at the end the re-target picks the nearest military enemy, else the nearest enemy building (registered, not a wall)
--     within BUILDING_RANGE (what the old attack_area at the point cleared), and attacks only it (a small area around
--     it, ATTACK_RADIUS), so rails, signals, poles, belts and inserters beside it survive;
--   * raiders keep the Skirmish legs (attack_area, by_anything): sabotage of poles, signals, belts and rails is theirs;
--   * explicit attack orders on any entity (a rail too) work as before.
-- The legs alone did not keep the lines whole: a unit (or a division) distracted by an enemy unit fights with an area
-- attack and splash that also hits the rails, signals and poles around the fight (probe lanes A and B with two enemy
-- walkers 15 tiles before the row: 4 and 13 pieces of infrastructure lost). So in Nation mode rails, rail signals,
-- rail supports and ramps and electric poles are protected: damage to them is undone unless it comes from a raider or
-- from a unit whose explicit attack order targets exactly that entity, and the entity turns indestructible for
-- PROTECT_TICKS so the engine's target selection drops it (units never pick indestructible targets), then destructible
-- again. storage.targeting = {protected = {{entity, until_tick}, ...}, undone = n}.
local buildings = require("scripts.buildings")
local balance = require("balance")
local diplomacy = require("scripts.diplomacy")

local targeting = {}

local CMD, DIS = defines.command, defines.distraction
targeting.SKIP_KINDS = {wall = true}  -- walls block, they are not targets
targeting.ATTACK_RADIUS = 2           -- re-target area around the chosen enemy: that entity, not its neighbours
targeting.GOTO_RADIUS = 2             -- an attack-move leg ends this close to its point
targeting.BUILDING_RANGE = 12         -- enemy buildings this close to a unit at the end of its leg are attacked

function targeting.nation()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function is_raider(name)
  local u = balance.units[name]
  return u ~= nil and u.kind == "raider"
end
targeting.is_raider = is_raider

--- True when the Nation rules apply to a unit of this prototype (Nation mode, not a raider).
function targeting.careful(name)
  return targeting.nation() and not is_raider(name)
end

--- The command of one attack-move leg towards `dest` for a unit of prototype `name`; nil means "use the Skirmish
--- command" (the caller keeps its own attack_area + by_anything).
function targeting.leg(name, dest)
  if not targeting.careful(name) then return nil end
  return {type = CMD.go_to_location, destination = dest, radius = targeting.GOTO_RADIUS, distraction = DIS.by_enemy}
end

--- The re-target command against `enemy` for a unit of prototype `name`; nil means the Skirmish command.
function targeting.strike(name, enemy)
  if not targeting.careful(name) then return nil end
  return {type = CMD.attack_area, destination = enemy.position, radius = targeting.ATTACK_RADIUS,
          distraction = DIS.by_enemy}
end

--- True when a division of these unit records attack-moves by the Nation rules (any member that is not a raider).
function targeting.careful_group(recs)
  if not targeting.nation() then return false end
  for _, rec in ipairs(recs) do
    if rec.entity and rec.entity.valid and not is_raider(rec.entity.name) then return true end
  end
  return false
end

local building_names
local function names()
  if not building_names then
    building_names = {}
    for name, kind in pairs(buildings.KIND_BY_NAME) do
      if not targeting.SKIP_KINDS[kind] and prototypes.entity[name] then building_names[#building_names + 1] = name end
    end
    table.sort(building_names)
  end
  return building_names
end

--- The nearest destructible enemy building (registered, not a wall) of a force hostile to `force_name` within `range`
--- of `position`, or nil. Nation mode only (nil otherwise).
function targeting.nearest_building(surface, position, force_name, range)
  if not targeting.nation() then return nil end
  local hostile = {}
  for _, f in pairs(game.forces) do
    if diplomacy.hostile(force_name, f.name) then hostile[#hostile + 1] = f.name end
  end
  if #hostile == 0 then return nil end
  local best, bd
  for _, e in pairs(surface.find_entities_filtered({position = position, radius = range or targeting.BUILDING_RANGE,
                                                    name = names(), force = hostile})) do
    if e.valid and e.destructible then
      local dx, dy = e.position.x - position.x, e.position.y - position.y
      local d = dx * dx + dy * dy
      if not bd or d < bd then best, bd = e, d end
    end
  end
  return best
end

--- The next target at the end of an attack-move leg: the nearest military enemy within `range`, else, when `careful`
--- (targeting.careful / careful_group: Nation mode, not raiders), the nearest enemy building within BUILDING_RANGE.
function targeting.next_enemy(surface, position, force, range, careful)
  local enemy = surface.find_nearest_enemy({position = position, max_distance = range, force = force})
  if enemy or not careful then return enemy end
  local f = type(force) == "string" and force or force.name
  return targeting.nearest_building(surface, position, f, targeting.BUILDING_RANGE)
end

---------------------------------------------------------------------------
-- Infrastructure protection (Nation mode)
---------------------------------------------------------------------------
targeting.PROTECTED_TYPES = {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail",
  "legacy-straight-rail", "legacy-curved-rail", "elevated-straight-rail", "elevated-curved-rail-a",
  "elevated-curved-rail-b", "elevated-half-diagonal-rail", "rail-ramp", "rail-support", "rail-signal",
  "rail-chain-signal", "electric-pole"}
local PROTECTED = {}
for _, t in ipairs(targeting.PROTECTED_TYPES) do PROTECTED[t] = true end
targeting.PROTECT_TICKS = 600

local function tstate()
  local s = storage.targeting
  if not s then
    s = {protected = {}, undone = 0}
    storage.targeting = s
  end
  return s
end

--- Make `entity` (a protected rail, signal or pole) destructible again now: an explicit attack order calls it.
function targeting.expose(entity)
  if not (entity and entity.valid) or entity.destructible then return end -- Phase 5 M3 integration: buildings too
  local s = storage.targeting
  if not s then return end
  for i = #s.protected, 1, -1 do
    local p = s.protected[i]
    if p.entity == entity then
      if entity.valid then entity.destructible = true end
      table.remove(s.protected, i)
    end
  end
end

---------------------------------------------------------------------------
-- Phase 5 M3 integration: collateral damage (Nation mode; M2 integration open issue 2)
---------------------------------------------------------------------------
-- A unit that fights an enemy unit (or attacks one by order) hits everything around its target with splash: belts,
-- inserters, pipes and the plain buildings of a city (factories, extractors, smelters, stockpiles, labs, houses...)
-- died in fights they had no part in. Rule: damage to an entity that is not a military target (walls, gates, units
-- and rolling stock excepted) is undone when it comes from a careful unit (not a raider, not a plane) whose current
-- attack aims at another entity: its distraction command's target, else its own attack command's target. Explicit
-- attacks (the unit record's target), the strikes of attack-move re-targets and of divisions (D.order.strike,
-- D.strike) and area commands without a target (a unit clearing a point, an obstacle in its path) still destroy it,
-- so cities are still taken by siege and buildings razed on purpose. storage.targeting.collateral counts the undone hits.
targeting.COLLATERAL_TYPES = {"transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "inserter",
  "pipe", "pipe-to-ground"}
targeting.COLLATERAL_SKIP = {wall = true, gate = true, unit = true, ["spider-unit"] = true, ["spider-vehicle"] = true,
  character = true, car = true, locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true,
  ["artillery-wagon"] = true, tree = true, ["simple-entity"] = true}

-- What a commandable is fighting: (target, fighting). A distraction is a fight (an attack on its target, or an
-- attack_area the engine gives a unit or group distracted by an enemy: no target); an attack command aims at its target.
local function aim(cm)
  local dc = cm.distraction_command
  if dc then
    if dc.target and dc.target.valid then return dc.target, true end
    return nil, true
  end
  local c = cm.has_command and cm.command
  if c and c.type == CMD.attack and c.target and c.target.valid then return c.target, true end
  return nil, false
end

-- A unit's own fight, else (a member of a unit group: a division) its group's.
local function aimed_at(cause)
  local cm = cause.commandable
  if not cm then return nil, false end
  local t, fighting = aim(cm)
  if t or fighting then return t, fighting end
  local g = cm.parent_group
  if g and g.valid then return aim(g) end
  return nil, false
end

--- True when this hit on `ent` is collateral damage to undo (header above).
local function collateral(e, ent)
  if ent.is_military_target or targeting.COLLATERAL_SKIP[ent.type] then return false end
  local cause = e.cause
  if not (cause and cause.valid and cause.unit_number) then return false end
  local u = balance.units[cause.name]
  if not u or u.kind == "raider" or u.air then return false end -- sabotage; bombers raze
  local rec = storage.units and storage.units[cause.unit_number]
  if not rec or rec.target == ent then return false end -- an explicit attack or a re-target strike on it
  local meta = storage.division_meta
  local did = meta and meta.member and meta.member[cause.unit_number]
  local D = did and storage.divisions and storage.divisions[did]
  if D then -- a division striking a building hits that building only
    local st = (D.strike and D.strike.entity) or (D.order and D.order.strike)
    if st == ent then return false end
    if st and st.valid then return true end
  end
  local t, fighting = aimed_at(cause)
  if t then return t ~= ent end
  if fighting then return true end -- an area fight the engine started (distracted by an enemy)
  -- no fight: an area command clears what it was sent to clear (a point, an obstacle); its order's target, when that
  -- is another entity, makes the hit collateral
  return rec.target ~= nil and rec.target.valid and rec.target ~= ent
end

local events = require("scripts.events")
events.on(defines.events.on_entity_damaged, function(e)
  local ent = e.entity
  if not (ent and ent.valid) or not targeting.nation() then return end
  if not PROTECTED[ent.type] then -- Phase 5 M3 integration: collateral damage
    if ent.force ~= e.force and e.force and collateral(e, ent) then
      ent.health = ent.health + e.final_damage_amount
      local s = tstate()
      s.collateral = (s.collateral or 0) + 1
      -- indestructible for PROTECT_TICKS, so the fight's area attack drops it and the units walk on (as for rails)
      if ent.destructible then
        ent.destructible = false
        s.protected[#s.protected + 1] = {entity = ent, until_tick = game.tick + targeting.PROTECT_TICKS}
      end
    end
    return
  end
  local by = e.force
  if not by or by == ent.force then return end
  local cause = e.cause
  if cause and cause.valid then
    if is_raider(cause.name) then return end -- sabotage
    local rec = cause.unit_number and storage.units and storage.units[cause.unit_number]
    if rec and rec.order == "attack" and rec.target == ent then return end -- an explicit attack on it
  end
  ent.health = ent.health + e.final_damage_amount
  local s = tstate()
  s.undone = s.undone + 1
  if ent.destructible then
    ent.destructible = false
    s.protected[#s.protected + 1] = {entity = ent, until_tick = game.tick + targeting.PROTECT_TICKS}
  end
end)

events.on_nth_tick(60, function()
  local s = storage.targeting
  if not (s and #s.protected > 0) then return end
  local tick = game.tick
  local keep = {}
  for _, p in ipairs(s.protected) do
    if p.entity.valid then
      if tick >= p.until_tick then p.entity.destructible = true else keep[#keep + 1] = p end
    end
  end
  s.protected = keep
end)

--- Append the protected types to the shared on_entity_damaged filter (scripts/research.lua sets it, abilities.lua adds
--- the Commander). control.lua calls this after every module loaded, identically on every load. In Skirmish no rail
--- exists and every other handler ignores poles (they check names), so only the event count changes there.
function targeting.install_damage_filters()
  local filters = script.get_event_filter(defines.events.on_entity_damaged)
  if not filters then return end -- no filter: every entity raises the event already
  local have = {}
  for _, f in ipairs(filters) do
    if f.filter == "type" then have[f.type] = true end
  end
  local out = {}
  for i, f in ipairs(filters) do out[i] = f end
  local added = false
  local types = {}
  for _, t in ipairs(targeting.PROTECTED_TYPES) do types[#types + 1] = t end
  for _, t in ipairs(targeting.COLLATERAL_TYPES) do types[#types + 1] = t end -- Phase 5 M3 integration
  for _, t in ipairs(types) do
    if not have[t] and #prototypes.get_entity_filtered({{filter = "type", type = t}}) > 0 then
      out[#out + 1] = {filter = "type", type = t}
      added = true
    end
  end
  if added then script.set_event_filter(defines.events.on_entity_damaged, out) end
end

return targeting
