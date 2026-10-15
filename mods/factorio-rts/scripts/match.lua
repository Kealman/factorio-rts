-- Phase 1 skirmish: forces, a flat arena around {0, 0}, two armies, a trivial enemy brain, win/lose.
-- Owns storage.match:
--   phase            "running" | "ended"
--   tick_started     tick the armies spawned
--   enemy_next_wave  tick of the next enemy wave
--   spawns           {["rts-player"] = MapPosition, ["rts-enemy"] = MapPosition}
--   wave             number of waves launched so far
--   enemy_group      LuaCommandable? (current wave group), enemy_group_id = its unique_id
--   winner           force name, once phase == "ended"
--   charted          true once the arena was charted for rts-player
--   waves_off        true after `/rts-qa-reset nowaves`: no enemy waves (enemy_next_wave is nil)
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")

local match = {}

local PLAYER, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
local ARENA_HALF = 80                       -- arena is [-80, 80)^2 tiles
local ARENA_TILE = "grass-1"
local SPAWNS = {[PLAYER] = {x = -50, y = 0}, [ENEMY] = {x = 50, y = 0}}
local FACING = {[PLAYER] = 1, [ENEMY] = -1} -- +1 = the enemy is east
local FORCE_COLORS = {
  [PLAYER] = {r = 0.15, g = 0.45, b = 1.0, a = 1},
  [ENEMY] = {r = 0.95, g = 0.15, b = 0.1, a = 1},
}
local FIRST_WAVE_TICKS = 45 * 60            -- first enemy wave 45 s after the armies spawn
local WAVE_PERIOD_TICKS = 90 * 60           -- then every 90 s
local WAVE_RADIUS = 16
local RETARGET_RANGE = 300

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local function setup_forces()
  local forces = {}
  for _, name in pairs({PLAYER, ENEMY}) do
    local f = game.forces[name] or game.create_force(name)
    f.custom_color = FORCE_COLORS[name]
    f.ai_controllable = false -- script groups work without it (spike decision 4)
    forces[#forces + 1] = f
  end
  local a, b = forces[1], forces[2]
  for _, pair in pairs({{a, b}, {b, a}}) do
    local f, other = pair[1], pair[2]
    f.set_friend(other, false)
    f.set_cease_fire(other, false)
    -- Keep vanilla forces (biters, the default player force, neutral) out of the fight.
    for _, vanilla in pairs({"enemy", "player", "neutral"}) do
      f.set_cease_fire(vanilla, true)
      game.forces[vanilla].set_cease_fire(f, true)
    end
  end
end

-- Disable natural enemy bases for chunks generated from now on. Works from the control stage as long as
-- it runs before the chunks are generated (on_init of a new map).
local function disable_enemy_bases(surface)
  local mgs = surface.map_gen_settings
  local controls = mgs.autoplace_controls or {}
  if controls["enemy-base"] then
    controls["enemy-base"].size = 0
    controls["enemy-base"].frequency = 0
    mgs.autoplace_controls = controls
    surface.map_gen_settings = mgs
  end
  -- The starting chunks are generated before on_init runs, so remove what map gen already placed there.
  local removed = 0
  for _, e in pairs(surface.find_entities_filtered({force = "enemy"})) do
    e.destroy()
    removed = removed + 1
  end
  local read_back = surface.map_gen_settings.autoplace_controls["enemy-base"]
  util.log("match: enemy-base autoplace size=%s frequency=%s; chunk (0,0) generated before on_init: %s; "
    .. "%d pre-generated enemy entities removed", read_back and tostring(read_back.size) or "n/a",
    read_back and tostring(read_back.frequency) or "n/a", tostring(surface.is_chunk_generated({0, 0})), removed)
end

local function prepare_arena(surface)
  local h = ARENA_HALF
  local area = {{-h, -h}, {h, h}}
  surface.request_to_generate_chunks({0, 0}, math.ceil(h / 32) + 1)
  surface.force_generate_chunk_requests()

  local removed = 0
  for _, e in pairs(surface.find_entities_filtered({area = area})) do
    if e.valid and e.type ~= "character" then
      e.destroy()
      removed = removed + 1
    end
  end
  -- Grass over everything, water included (acts as landfill), then clear decoratives for a clean look.
  local tiles = {}
  for x = -h, h - 1 do
    for y = -h, h - 1 do
      tiles[#tiles + 1] = {name = ARENA_TILE, position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, true, true, false)
  surface.destroy_decoratives({area = area})
  surface.always_day = true

  local water = surface.count_tiles_filtered({area = area, collision_mask = "water_tile"})
  util.log("match: arena [%d,%d)^2 ready: %d tiles set to %s, %d entities removed, water tiles left=%d",
    -h, h, #tiles, ARENA_TILE, removed, water)
end

-- Spawn grid spacing. The Space Age walker (strafer copy) is 1.8 tiles wide and the heavy (stomper copy)
-- 2.7 tiles, so heavies need more room than walkers; the base-game variants are smaller.
local WALKER_SPACING = 3
local HEAVY_SPACING = 4
local HEAVY_FRONT = 6 -- heavies' column, tiles in front of the walker block's first column

--- Spawn the standard army of one force around its spawn point: 20 walkers in a 4x5 block and
--- 4 heavies in a column in front of them (towards the enemy).
local function spawn_army(force_name)
  local s = SPAWNS[force_name]
  local dir = FACING[force_name]
  local made = 0
  for i = 0, 19 do
    local col, row = i % 4, math.floor(i / 4)
    local pos = {x = s.x - dir * col * WALKER_SPACING, y = s.y + (row - 2) * WALKER_SPACING}
    if units.spawn("rts-walker", pos, force_name, "walker") then made = made + 1 end
  end
  for i = 0, 3 do
    local pos = {x = s.x + dir * HEAVY_FRONT, y = s.y + (i - 1.5) * HEAVY_SPACING}
    if units.spawn("rts-walker-heavy", pos, force_name, "heavy") then made = made + 1 end
  end
  return made
end

--- Spawn both armies (idempotent per force: only spawns a force that has no units) and (re)start the match.
function match.spawn_armies()
  local m = storage.match
  for _, force_name in pairs({PLAYER, ENEMY}) do
    if units.count(force_name) == 0 then
      local n = spawn_army(force_name)
      util.log("match: spawned %d units for %s at %s", n, force_name, util.pos_str(SPAWNS[force_name]))
    end
  end
  m.phase = "running"
  m.winner = nil
  m.tick_started = game.tick
  m.enemy_next_wave = game.tick + FIRST_WAVE_TICKS
end

--- Put a player on the RTS player force (humans always play rts-player in Phase 1).
function match.assign_player(player)
  if player.force.name ~= PLAYER then player.force = PLAYER end
end

--- Home position (spawn point) of a force, or {0, 0}.
function match.home(force_name)
  local spawns = storage.match and storage.match.spawns
  return (spawns and spawns[force_name]) or {x = 0, y = 0}
end

function match.init()
  if storage.match then return end
  local spawns = {}
  for force_name, pos in pairs(SPAWNS) do spawns[force_name] = {x = pos.x, y = pos.y} end
  storage.match = {phase = "setup", wave = 0, spawns = spawns}
  local surface = util.surface()
  disable_enemy_bases(surface)
  setup_forces()
  prepare_arena(surface)
  match.spawn_armies()
  for _, player in pairs(game.players) do match.assign_player(player) end
end

---------------------------------------------------------------------------
-- Enemy brain: every WAVE_PERIOD send every enemy unit, as one unit group, to attack the player army.
---------------------------------------------------------------------------
local function player_target(position)
  if position then
    local nearest = util.surface().find_nearest_enemy({position = position, max_distance = RETARGET_RANGE,
                                                       force = ENEMY})
    if nearest then return nearest.position end
  end
  return units.centroid(PLAYER)
end

local function drop_group()
  local m = storage.match
  local g = m.enemy_group
  m.enemy_group, m.enemy_group_id = nil, nil
  if g and g.valid then g.destroy() end
end

local function launch_wave()
  local m = storage.match
  local target = units.centroid(PLAYER)
  local origin = units.centroid(ENEMY)
  if not (target and origin) then return end
  drop_group()
  local group = util.surface().create_unit_group({position = origin, force = ENEMY})
  local n = 0
  for _, rec in units.for_force(ENEMY) do
    group.add_member(rec.entity)
    rec.order = "attack_move"
    rec.dest = target
    n = n + 1
  end
  group.set_command({type = defines.command.attack_area, destination = target, radius = WAVE_RADIUS,
                     distraction = defines.distraction.by_anything})
  m.enemy_group, m.enemy_group_id = group, group.unique_id
  m.wave = m.wave + 1
  util.log("match: enemy wave %d: group #%d with %d units from %s -> attack_area %s", m.wave, group.unique_id,
    n, util.pos_str(origin), util.pos_str(target))
end

-- Wave members whose group is gone go back to idle (stop), so they do not wander.
local function release_orphans()
  for _, rec in units.for_force(ENEMY) do
    if rec.order == "attack_move" then
      local c = rec.entity.commandable
      if not (c and c.parent_group) then
        rec.order = units.IDLE
        rec.dest = nil
        units.stop(rec.entity)
      end
    end
  end
end

local function check_winner()
  local m = storage.match
  local alive_player, alive_enemy = units.count(PLAYER), units.count(ENEMY)
  if alive_player > 0 and alive_enemy > 0 then return end
  m.phase = "ended"
  m.winner = alive_player > 0 and PLAYER or (alive_enemy > 0 and ENEMY or "draw")
  drop_group()
  release_orphans()
  local msg = m.winner == PLAYER and "Victory! The enemy army is destroyed."
    or (m.winner == ENEMY and "Defeat. Your army is destroyed." or "Draw: both armies are destroyed.")
  game.print("[RTS] " .. msg)
  util.log("match: ended at tick %d, winner=%s (player units=%d, enemy units=%d)", game.tick, m.winner,
    alive_player, alive_enemy)
end

--- QA reset (/rts-qa-reset): drop the wave group, destroy every unit and the corpses in the arena, spawn
--- both armies again at their spawns and restart the match clock. With waves = false no enemy wave comes
--- until the next reset with waves on. Returns the number of units and corpses removed.
function match.reset(waves)
  local m = storage.match
  drop_group()
  local removed = units.despawn_all()
  local h = ARENA_HALF
  local corpses = 0
  for _, e in pairs(util.surface().find_entities_filtered({area = {{-h, -h}, {h, h}}, type = "corpse"})) do
    e.destroy()
    corpses = corpses + 1
  end
  m.wave = 0
  match.spawn_armies()
  m.waves_off = not waves or nil
  if m.waves_off then m.enemy_next_wave = nil end
  return removed, corpses
end

-- Chart the arena for the player force. A chart requested in on_init of `--create` never happens (it
-- is not processed without ticks), so it runs on the first second of a ticking session instead.
local function chart_arena(m)
  local h = ARENA_HALF + 32
  game.forces[PLAYER].chart(util.surface(), {{-h, -h}, {h, h}})
  m.charted = true
end

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not m then return end
  if not m.charted then chart_arena(m) end
  if m.phase ~= "running" then return end
  if m.enemy_group and not m.enemy_group.valid then
    util.log("match: wave group #%s is gone (all members dead or disbanded)", tostring(m.enemy_group_id))
    m.enemy_group, m.enemy_group_id = nil, nil
    release_orphans()
  end
  if m.enemy_next_wave and e.tick >= m.enemy_next_wave then
    m.enemy_next_wave = e.tick + WAVE_PERIOD_TICKS
    launch_wave()
  end
  check_winner()
end)

-- Re-target the wave when its attack_area completes: nearest player unit, else the player centroid.
events.on(defines.events.on_ai_command_completed, function(e)
  local m = storage.match
  if not (m and m.enemy_group_id and e.unit_number == m.enemy_group_id) then return end
  local group = m.enemy_group
  if not (group and group.valid) or m.phase ~= "running" then return end
  local target = player_target(group.position)
  if not target then return end
  group.set_command({type = defines.command.attack_area, destination = target, radius = WAVE_RADIUS,
                     distraction = defines.distraction.by_anything})
  util.log("match: wave group #%d command completed (result=%s), re-targeted to %s", group.unique_id,
    util.define_name(defines.behavior_result, e.result), util.pos_str(target))
end)

events.on(defines.events.on_player_created, function(e)
  match.assign_player(game.get_player(e.player_index))
end)

events.on(defines.events.on_player_joined_game, function(e)
  match.assign_player(game.get_player(e.player_index))
end)

return match
