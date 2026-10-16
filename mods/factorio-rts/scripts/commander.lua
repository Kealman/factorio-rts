-- Commander hero (docs/PHASE4.md sections 1 "Heroes" and 3): one rts-commander spider-vehicle per human force.
--
-- Spawn and respawn. A 60-tick sweep gives every human force of a running match a Commander at its main CC (the CC's
-- default exit, buildings.default_exit) when it has none. After a death it comes back RESPAWN_TICKS (60 s) later, at
-- whatever CC the force has then; a force without a CC waits. A death adds the alert kind "commander-down" to
-- storage.alerts (supply.alert: {tick, force, kind, position, text, params}); a respawn adds "commander-ready".
-- Human force: a match participant that is not an AI force (match.ai_forces), has no AI commander (storage.ai) and
-- has players (LuaForce.players) or was enabled by script (commander.enable: the headless probe, which has no players).
-- So the headless autotests, whose rts-player is AI-driven or has no players, get no Commander.
--
-- Unit registry. The Commander is a unit in storage.units: kind "commander" (supply 0, balance.lua), order
-- "commander" and issuer "commander". The non-idle order is a claim (units.lua): orders.lua and the AI army never
-- command it (a spider-vehicle has no LuaCommandable anyway). selection.lua selects it like any unit (the RTS cursor
-- selects spider-vehicles since prototypes/logistics.lua), so box select, click select, groups and Ctrl+A include it.
-- Orders: the orders.on_right_click hook below moves it with autopilot_destination: right click on the ground = move,
-- on an enemy = walk to ATTACK_STANDOFF tiles from it (its rockets reach 30 and fire on their own), Shift + right
-- click or an armed attack-move = move (it fires while walking). X (stop) and H (hold) clear the autopilot. Other
-- selected units get their normal order from orders.lua.
--
-- Combat. Auto-targeting without a gunner (vehicle_automatic_targeting_parameters). Rockets (rts-commander-rocket) are
-- topped up to AMMO_KEEP every sweep: the hero's ammo is free.
--
-- Levels. Kills by the Commander (on_entity_died with cause = the Commander; enemy RTS units and buildings, no walls)
-- raise its level: level 2 at 5 kills, level 3 at 15. LuaEntity.max_health is read-only, so each level heals it fully
-- and adds an rts-commander-shield to its grid (400 shield = 20 % of 2000 HP, prototypes/abilities.lua). Kills and
-- level survive deaths within a match; a new match starts at level 1.
-- Grid (4x4, rts-commander-grid): personal roboport (0,0) and rts-commander-core (2,2) from level 1, shields at (2,0)
-- from level 2 and (0,2) from level 3. The roboport and ROBOTS construction robots in the trunk give field
-- construction: ghosts within the roboport's construction radius (15 tiles) are built from items in the trunk.
-- Field supply (Wave C): a player cannot fill the trunk (no character, remote view), and the CC's robots reach only
-- 40 tiles, so a hub at a natural patch was out of a human's reach while the AI revives its ghosts anywhere. Every
-- sweep therefore stocks the trunk from the force's CC network (economy.take) with the items of the ghosts near the
-- Commander that no stocked network covers (nearest FIELD_GHOSTS), and gives back what no nearby ghost needs any
-- more (robots excepted). So: place the ghosts, walk the Commander there, its robots build them from the pool.
--
-- Owns storage.commander = {
--   match_id,                         the match the per-force records belong to (a new match resets them)
--   forces = {[force] = {unit_number?, entity?, level, kills, deaths, spawned, dead_tick?, respawn_tick?, waiting?}},
--   enabled = {[force] = true},       forces enabled by script (commander.enable)
-- }
-- Log lines: "[rts] commander: ..." (spawn, death, respawn, level, kill credit every kill).
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local supply = require("scripts.supply")
local camera = require("scripts.camera")
local economy = require("scripts.economy")
local balance = require("balance")

local commander = {}

commander.NAME = "rts-commander"
commander.KIND = "commander"
commander.ORDER = "commander"       -- storage.units claim
commander.ISSUER = "commander"
commander.SWEEP_TICKS = 60
commander.RESPAWN_TICKS = 60 * 60
commander.LEVEL_KILLS = {0, 5, 15}  -- kills needed for level 1, 2, 3
commander.AMMO = "rts-commander-rocket"
commander.AMMO_KEEP = 100           -- rockets; it fires about 2 per second in a fight
commander.ROBOTS = {name = "construction-robot", count = 4}
commander.CORE = "rts-commander-core"
commander.SHIELD = "rts-commander-shield"
commander.ROBOPORT = "personal-roboport-equipment"
-- Grid contents per level (position = top-left cell in the 4x4 grid).
commander.GRID = {
  {name = commander.ROBOPORT, position = {0, 0}, level = 1},
  {name = commander.CORE, position = {2, 2}, level = 1},
  {name = commander.SHIELD, position = {2, 0}, level = 2},
  {name = commander.SHIELD, position = {0, 2}, level = 3},
}
commander.ATTACK_STANDOFF = 22      -- tiles from an attacked enemy the Commander walks to
commander.FIELD_GHOSTS = 12         -- field supply: ghosts stocked for per sweep, nearest first
commander.FIELD_RADIUS = 15         -- fallback when the roboport cell reports no construction radius
local FEEDBACK_COLORS = {move = {r = 0.2, g = 1, b = 0.2, a = 1}, attack = {r = 1, g = 0.2, b = 0.15, a = 1}}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function cstate()
  local S = storage.commander
  if not S then
    S = {}
    storage.commander = S
  end
  S.forces = S.forces or {}
  S.enabled = S.enabled or {}
  return S
end

local function force_rec(force_name)
  local S = cstate()
  local F = S.forces[force_name]
  if not F then
    F = {level = 1, kills = 0, deaths = 0, spawned = 0}
    S.forces[force_name] = F
  end
  return F
end

function commander.init()
  cstate()
end

--- Let a force without players have a Commander (headless probes). on = false takes it back.
function commander.enable(force_name, on)
  cstate().enabled[force_name] = (on ~= false) or nil
end

--- True when `force_name` is a human force of the running match (see the header).
function commander.is_human(force_name)
  if not match.is_participant(force_name) then return false end
  for _, f in ipairs(match.ai_forces()) do
    if f == force_name then return false end
  end
  if storage.ai and storage.ai[force_name] then return false end
  if cstate().enabled[force_name] then return true end
  local force = game.forces[force_name]
  return force ~= nil and #force.players > 0
end

--- The force's live Commander entity, or nil.
function commander.entity(force_name)
  local S = storage.commander
  local F = S and S.forces and S.forces[force_name]
  local e = F and F.entity
  if e and e.valid then return e end
  return nil
end

--- True when the entity is a Commander.
function commander.is_commander(entity)
  return entity ~= nil and entity.valid and entity.name == commander.NAME
end

--- Level for a kill count.
function commander.level_for(kills)
  local level = 1
  for l, need in ipairs(commander.LEVEL_KILLS) do
    if kills >= need then level = l end
  end
  return level
end

--- Card data for the HUD / ability bar: {alive, level, kills, next_kills?, health, max_health, shield, max_shield,
--- respawn_in (seconds, while dead), waiting (no CC to respawn at), unit_number?, deaths}. nil for a force without
--- a Commander record (not human, or no match).
function commander.card(force_name)
  local S = storage.commander
  local F = S and S.forces and S.forces[force_name]
  if not F then return nil end
  local e = commander.entity(force_name)
  local c = {alive = e ~= nil, level = F.level, kills = F.kills, next_kills = commander.LEVEL_KILLS[F.level + 1],
             deaths = F.deaths, waiting = F.waiting, unit_number = e and e.unit_number}
  if e then
    c.health, c.max_health = e.health, e.max_health
    local grid = e.grid
    c.shield, c.max_shield = grid and grid.shield or 0, grid and grid.max_shield or 0
  elseif F.respawn_tick then
    c.respawn_in = math.max(0, math.ceil((F.respawn_tick - game.tick) / 60))
  end
  return c
end

---------------------------------------------------------------------------
-- Equipment, ammo, colour
---------------------------------------------------------------------------
--- Put the grid equipment of `level` that is missing. Returns the number of pieces added.
function commander.apply_level(entity, level)
  local grid = entity.grid
  if not grid then return 0 end
  local added = 0
  for _, g in ipairs(commander.GRID) do
    if g.level <= level and not grid.get(g.position) then
      local eq = grid.put({name = g.name, position = g.position})
      if eq then
        added = added + 1
        if eq.max_shield and eq.max_shield > 0 then eq.shield = eq.max_shield end
        if eq.max_energy and eq.max_energy > 0 then eq.energy = eq.max_energy end
      else
        util.log("commander: could not put %s at (%d, %d) into #%d's grid", g.name, g.position[1], g.position[2],
          entity.unit_number)
      end
    end
  end
  return added
end

local function top_up_ammo(entity)
  local inv = entity.get_inventory(defines.inventory.spider_ammo)
  if not inv then return 0 end
  local have = inv.get_item_count(commander.AMMO)
  if have >= commander.AMMO_KEEP / 2 then return 0 end
  return inv.insert({name = commander.AMMO, count = commander.AMMO_KEEP - have})
end

local function setup(entity, F)
  local force = entity.force
  local color = force.custom_color or force.color
  if color then entity.color = color end
  entity.vehicle_automatic_targeting_parameters = {auto_target_without_gunner = true, auto_target_with_gunner = true}
  top_up_ammo(entity)
  commander.apply_level(entity, F.level)
  local trunk = entity.get_inventory(defines.inventory.spider_trunk)
  if trunk and prototypes.item[commander.ROBOTS.name] then trunk.insert(commander.ROBOTS) end
  entity.health = entity.max_health
end

---------------------------------------------------------------------------
-- Spawn, death, respawn
---------------------------------------------------------------------------
local function spawn(force_name, F)
  local cc = buildings.main_cc(force_name)
  if not cc then
    if not F.waiting then
      F.waiting = true
      util.log("commander: %s has no CC; the Commander waits for one", force_name)
    end
    return nil
  end
  F.waiting = nil
  local surface = cc.entity.surface
  local exit = buildings.default_exit(cc)
  local pos = surface.find_non_colliding_position(commander.NAME, exit, 16, 0.5) or exit
  local entity, rec = units.spawn(commander.NAME, pos, force_name, commander.KIND, surface)
  if not entity then
    util.log("commander: could not place the Commander for %s near %s", force_name, util.pos_str(exit))
    return nil
  end
  rec.order, rec.issuer = commander.ORDER, commander.ISSUER
  setup(entity, F)
  F.entity, F.unit_number = entity, entity.unit_number
  F.spawned = F.spawned + 1
  F.respawn_tick, F.dead_tick = nil, nil
  util.log("commander: spawned #%d for %s at %s (spawn %d, level %d, kills %d, grid %d pieces, %d rockets)",
    entity.unit_number, force_name, util.pos_str(entity.position), F.spawned, F.level, F.kills,
    entity.grid and #entity.grid.equipment or 0,
    entity.get_inventory(defines.inventory.spider_ammo).get_item_count(commander.AMMO))
  if F.spawned > 1 then
    supply.alert(force_name, "commander-ready", "rts.alert-commander-ready", {}, entity.position)
    local force = game.forces[force_name]
    if force then force.print({"rts.alert-commander-ready"}) end
  end
  return entity
end

--- Spawn the force's Commander now if it has none (ignores the respawn timer). Returns the entity or nil.
function commander.spawn_now(force_name)
  local e = commander.entity(force_name)
  if e then return e end
  return spawn(force_name, force_rec(force_name))
end

local function on_death(entity, cause)
  local force_name = entity.force.name
  local S = storage.commander
  local F = S and S.forces and S.forces[force_name]
  if not (F and F.unit_number == entity.unit_number) then return end
  F.entity, F.unit_number = nil, nil
  F.dead_tick = game.tick
  F.respawn_tick = game.tick + commander.RESPAWN_TICKS
  F.deaths = F.deaths + 1
  local secs = commander.RESPAWN_TICKS / 60
  local by = (cause and cause.valid) and string.format("%s (%s)", cause.name, cause.force.name) or "unknown"
  util.log("commander: #%d of %s died at %s, killed by %s; respawn at tick %d (death %d, level %d)",
    entity.unit_number, force_name, util.pos_str(entity.position), by, F.respawn_tick, F.deaths, F.level)
  supply.alert(force_name, "commander-down", "rts.alert-commander-down", {secs}, entity.position)
  entity.force.print({"rts.alert-commander-down", secs})
end

-- Kill credit: enemy RTS units and buildings (not walls, not legs).
local function counts_as_kill(killer, victim)
  if victim.type == "spider-leg" or victim.type == "wall" then return false end
  if not killer.force.is_enemy(victim.force) then return false end
  local name = victim.name
  return balance.units[name] ~= nil or buildings.KIND_BY_NAME[name] ~= nil or balance.buildings[name] ~= nil
end

local function credit(killer, victim)
  local force_name = killer.force.name
  local S = storage.commander
  local F = S and S.forces and S.forces[force_name]
  if not (F and F.unit_number == killer.unit_number) or not counts_as_kill(killer, victim) then return end
  F.kills = F.kills + 1
  local level = commander.level_for(F.kills)
  util.log("commander: #%d of %s killed %s (%s), kills %d", killer.unit_number, force_name, victim.name,
    victim.force.name, F.kills)
  if level > F.level then
    F.level = level
    killer.health = killer.max_health
    local added = commander.apply_level(killer, level)
    local grid = killer.grid
    util.log("commander: %s level %d at %d kills: healed to %.0f, +%d grid pieces, shield %.0f/%.0f", force_name, level,
      F.kills, killer.health, added, grid and grid.shield or 0, grid and grid.max_shield or 0)
    local shield = prototypes.equipment[commander.SHIELD]
    killer.force.print({"rts.commander-level-up", level, shield and shield.get_shield() or 0})
  end
end

---------------------------------------------------------------------------
-- Field supply (see the header)
---------------------------------------------------------------------------
local function item_to_place(ghost)
  local list = ghost.ghost_prototype.items_to_place_this
  local it = list and list[1]
  if not it then return nil end
  return it.name, it.count or 1
end

-- True when a logistic network other than the Commander's own covers `pos` for construction and holds the item:
-- the base's robots build that ghost, so the trunk is not stocked for it.
local function covered(surface, force, pos, item, own_id)
  for _, net in pairs(surface.find_logistic_networks_by_construction_area(pos, force)) do
    if net.valid and net.network_id ~= own_id and net.get_item_count(item) > 0 then return true end
  end
  return false
end

--- Stock the Commander's trunk for nearby uncovered ghosts and return the surplus to the pool. Returns the number of
--- items moved into the trunk.
function commander.field_supply(e, force_name)
  local cell = e.logistic_cell
  local trunk = e.get_inventory(defines.inventory.spider_trunk)
  if not (cell and trunk) then return 0 end
  local radius = cell.construction_radius
  if not radius or radius <= 0 then radius = commander.FIELD_RADIUS end
  local own = e.logistic_network
  local own_id = own and own.valid and own.network_id or -1
  local surface, force, pos = e.surface, e.force, e.position
  local ghosts = surface.find_entities_filtered({position = pos, radius = radius, type = "entity-ghost", force = force})
  local d2 = {}
  for _, g in ipairs(ghosts) do
    local gp = g.position
    d2[g] = (gp.x - pos.x) ^ 2 + (gp.y - pos.y) ^ 2
  end
  table.sort(ghosts, function(a, b) return d2[a] < d2[b] end)
  local need, n = {}, 0
  for _, g in ipairs(ghosts) do
    if n >= commander.FIELD_GHOSTS then break end
    local item, count = item_to_place(g)
    if item and not covered(surface, force, g.position, item, own_id) then
      need[item] = (need[item] or 0) + count
      n = n + 1
    end
  end
  local moved, parts = 0, {}
  for item, want in pairs(need) do
    local missing = want - trunk.get_item_count(item)
    if missing > 0 then
      local got = economy.take(force_name, item, missing)
      if got > 0 then
        local put = trunk.insert({name = item, count = got})
        if put < got then economy.give(force_name, item, got - put) end
        if put > 0 then
          moved = moved + put
          parts[#parts + 1] = item .. " x" .. put
        end
      end
    end
  end
  local back = {}
  for _, it in pairs(trunk.get_contents()) do
    if it.name ~= commander.ROBOTS.name and not need[it.name] then
      local removed = trunk.remove({name = it.name, count = it.count, quality = it.quality})
      if removed > 0 then
        local given = economy.give(force_name, it.name, removed)
        if given < removed then trunk.insert({name = it.name, count = removed - given}) end
        back[#back + 1] = it.name .. " x" .. given
      end
    end
  end
  if moved > 0 or #back > 0 then
    table.sort(parts)
    table.sort(back)
    util.log("commander: field supply for %s at %s: %d ghosts within %.0f tiles need the trunk; stocked [%s], "
      .. "returned [%s]", force_name, util.pos_str(pos), n, radius, table.concat(parts, " "), table.concat(back, " "))
  end
  return moved
end

local function sweep(tick)
  local m = storage.match
  if not (m and m.surface and m.phase == "running") then return end
  local S = cstate()
  if S.match_id ~= m.match_id then
    S.match_id = m.match_id
    S.forces = {}
  end
  for _, f in ipairs(match.forces()) do
    if commander.is_human(f) then
      local F = force_rec(f)
      local e = commander.entity(f)
      if e then
        top_up_ammo(e)
        commander.field_supply(e, f)
      elseif not F.respawn_tick or tick >= F.respawn_tick then
        spawn(f, F)
      end
    end
  end
end
commander.sweep = sweep

events.on_nth_tick(commander.SWEEP_TICKS, function(e) sweep(e.tick) end)

events.on(defines.events.on_entity_died, function(e)
  local entity = e.entity
  if not (entity and entity.valid) then return end
  local cause = e.cause
  if cause and cause.valid and cause.name == commander.NAME then credit(cause, entity) end
  if entity.name == commander.NAME then on_death(entity, cause) end
end)

---------------------------------------------------------------------------
-- Orders (orders.on_right_click hook) and stop / hold
---------------------------------------------------------------------------
-- The selected Commander and the number of other selected units orders.lua would command.
local function selected(player_index)
  local cmd, others = nil, 0
  for _, e in pairs(selection.get(player_index)) do
    local rec = storage.units[e.unit_number]
    if rec then
      if rec.kind == commander.KIND then
        cmd = e
      elseif rec.order == units.IDLE or rec.issuer == orders.ISSUER then
        others = others + 1
      end
    end
  end
  return cmd, others
end
commander.selected = selected

local function marker(player_index, target, color, surface)
  local player = selection.real_player(player_index)
  if not player then return end
  rendering.draw_circle({color = color, radius = 1.75, width = 4, filled = false, target = target, surface = surface,
    time_to_live = 20, players = {player_index}})
end

local function pick_enemy(force, entities)
  local best, best_unit
  for _, e in pairs(entities or {}) do
    if e.valid and e.force and force.is_enemy(e.force) and e.type ~= "spider-leg" then
      local is_unit = e.unit_number ~= nil and storage.units[e.unit_number] ~= nil
      if not best or (is_unit and not best_unit) then best, best_unit = e, is_unit end
    end
  end
  return best
end

--- Send a Commander towards a point (move) or to ATTACK_STANDOFF tiles from an enemy (attack). Returns the destination
--- (nil when it already stands in range of the enemy).
function commander.go(entity, position, enemy)
  local dest = position
  if enemy and enemy.valid then
    local d = util.distance(entity, enemy)
    if d <= commander.ATTACK_STANDOFF then
      dest = nil
    else
      local ex, ey = util.xy(enemy)
      local cx, cy = util.xy(entity)
      local k = commander.ATTACK_STANDOFF / d
      dest = {x = ex + (cx - ex) * k, y = ey + (cy - ey) * k}
    end
  end
  entity.autopilot_destination = dest and {x = dest.x or dest[1], y = dest.y or dest[2]} or nil
  return dest
end

--- orders.on_right_click hook: the selected Commander moves or attacks; the click is consumed when nothing else that
--- orders.lua commands is selected.
function commander.right_click(player_index, position, entities, alt)
  local cmd, others = selected(player_index)
  if not cmd then return nil end
  local armed = orders.is_armed(player_index)
  local enemy = not (alt or armed) and pick_enemy(cmd.force, entities) or nil
  local dest = commander.go(cmd, position, enemy)
  local order = enemy and "commander-attack" or ((alt or armed) and "commander-attack-move" or "commander-move")
  util.log("order %s n=1 unit=#%d dest=%s%s player=%d", order, cmd.unit_number, util.pos_str(dest),
    enemy and string.format(" target=%s (%s)", enemy.name, enemy.force.name) or "", player_index)
  local px, py = util.xy(position)
  marker(player_index, enemy or {x = px, y = py}, enemy and FEEDBACK_COLORS.attack or FEEDBACK_COLORS.move,
    cmd.surface)
  if others > 0 then return nil end -- orders.lua orders the rest (and uses up an armed attack-move)
  if armed then orders.arm_attack_move(player_index, false) end
  return order, 1
end

orders.on_right_click(commander.right_click)

--- Stop the player's selected Commander (X / H). Returns true when one was selected.
function commander.stop(player_index)
  local cmd = selected(player_index)
  if not cmd then return false end
  cmd.autopilot_destination = nil
  util.log("order commander-stop n=1 unit=#%d player=%d", cmd.unit_number, player_index)
  return true
end

events.on("rts-stop", function(e) commander.stop(e.player_index) end)
events.on("rts-hold", function(e) commander.stop(e.player_index) end)

--- Select the force's Commander for a player; a second call while it is selected jumps the camera to it.
function commander.select(player_index)
  local e = commander.entity(selection.force_name(player_index))
  if not e then return false end
  local sel = selection.get(player_index)
  if #sel == 1 and sel[1] == e then
    local player = selection.real_player(player_index)
    if player then camera.jump_to(player, e.position) end
    util.log("commander: camera to #%d player=%d", e.unit_number, player_index)
  else
    selection.set(player_index, {e})
    util.log("commander: selected #%d player=%d", e.unit_number, player_index)
  end
  return true
end

return commander
