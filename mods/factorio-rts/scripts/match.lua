-- Skirmish: forces, a flat arena around {0, 0}, a base per side, small starting armies, a trivial enemy brain,
-- win/lose.
-- Phase 2 start (docs/PHASE2.md): the player gets the CC composite at (-60, 0) with the starting stock in its
-- stockpiles; the enemy gets the full starter base template (basetemplate.lua, mirrored) at (+60, 0) with its
-- barracks on walker kits; both sides get ore patches and ARMY_SIZE walkers. A force is out of the match when it
-- has no CC, barracks or factory (buildings.is_alive_force) and no units.
-- Owns storage.match:
--   phase            "setup" | "running" | "ended"   (the only source of truth for the match result, see
--                    match.result: a winner exists only while phase == "ended")
--   tick_started     tick the armies spawned
--   ended_tick       tick the match ended (phase == "ended")
--   config           {first_wave_ticks, wave_period_ticks}: enemy wave timing (match.DEFAULT_CONFIG; change it with
--                    match.set_wave_timing or /rts-wave-timing)
--   enemy_next_wave  tick of the next enemy wave
--   spawns           {["rts-player"] = MapPosition, ["rts-enemy"] = MapPosition}  CC centres (match.home)
--   wave             number of waves launched so far
--   enemy_group      LuaCommandable? (current wave group), enemy_group_id = its unique_id
--   winner           force name or "draw", once phase == "ended" (match.decide_winner)
--   charted          true once the arena was charted for rts-player
--   waves_off        true after `/rts-qa-reset nowaves`: no enemy waves (enemy_next_wave is nil)
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local basetemplate = require("scripts.basetemplate")

local match = {}

local PLAYER, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
local ARENA_HALF = 80                       -- arena is [-80, 80)^2 tiles
local ARENA_TILE = "grass-1"
local SPAWNS = {[PLAYER] = {x = -60, y = 0}, [ENEMY] = {x = 60, y = 0}} -- CC centres (tile corners)
local FACING = {[PLAYER] = 1, [ENEMY] = -1} -- +1 = the enemy is east
match.CC_POSITIONS = SPAWNS
match.FACING = FACING

-- Starting armies, ARMY_OFFSET tiles in front of the CC: ARMY.walkers walkers in ARMY_COLUMNS columns and
-- ARMY.heavies heavies in a column in front of them. Grid spacing per unit (Phase 1 QA follow-up 6: the denser
-- 3-tile grid overlapped visually): 3.5 tiles for walkers, 5 for heavies.
match.ARMY = {walkers = 6, heavies = 0}
match.ARMY_SIZE = match.ARMY.walkers + match.ARMY.heavies
match.SPACING = {["rts-walker"] = 3.5, ["rts-walker-heavy"] = 5}
local ARMY_COLUMNS = 2
local ARMY_OFFSET = 14
local HEAVY_FRONT = 6 -- tiles from the walker block's front column to the heavies' column

-- Enemy wave timing (Phase 1 QA follow-up 2): first wave 3 minutes after the armies spawn, then every 2 minutes.
-- Copied into storage.match.config at init; the headless autotest shortens it through match.set_wave_timing.
match.DEFAULT_CONFIG = {first_wave_ticks = 3 * 60 * 60, wave_period_ticks = 2 * 60 * 60}

-- docs/PHASE2.md "Starting stock", inserted into the player's CC stockpiles.
match.STARTING_STOCK = {
  {"iron-plate", 200}, {"copper-plate", 100}, {"rts-extractor", 2}, {"rts-smelter", 2}, {"rts-barracks", 1},
  {"transport-belt", 20}, {"fast-inserter", 10}, {"medium-electric-pole", 10},
}
match.ENEMY_BARRACKS_RECIPE = "rts-walker-kit"

-- Ore patches per side, relative to the CC centre for the side facing +x (dx is flipped for the other side):
-- {resource, dx, dy, width, height}. Iron: a 12x12 blob 30 tiles towards the arena centre.
match.ORE_AMOUNT = 1500
match.ORE_PATCHES = {
  {"iron-ore", 30, 0, 12, 12},
  {"copper-ore", 28, -16, 8, 8},
  {"stone", 28, 16, 6, 6},
  {"coal", 36, 16, 6, 6},
}
local FORCE_COLORS = {
  [PLAYER] = {r = 0.15, g = 0.45, b = 1.0, a = 1},
  [ENEMY] = {r = 0.95, g = 0.15, b = 0.1, a = 1},
}
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

--- Where a force's army gathers: ARMY_OFFSET tiles in front of its CC (towards the arena centre).
function match.army_point(force_name)
  local home = match.home(force_name)
  return {x = home.x + (FACING[force_name] or 1) * ARMY_OFFSET, y = home.y}
end

--- Grid spacing for a unit prototype name (match.SPACING; 3.5 for anything not listed).
function match.spacing(name)
  return match.SPACING[name] or match.SPACING["rts-walker"]
end

--- Spawn the starting army of one force at match.army_point: match.ARMY.walkers walkers in ARMY_COLUMNS columns
--- (the first column faces the enemy, the others extend towards the own CC), match.ARMY.heavies heavies in a
--- column HEAVY_FRONT tiles in front of them.
local function spawn_army(force_name)
  local s = match.army_point(force_name)
  local dir = FACING[force_name]
  local made = 0
  local ws, hs = match.spacing("rts-walker"), match.spacing("rts-walker-heavy")
  local walkers, heavies = match.ARMY.walkers, match.ARMY.heavies
  local rows = math.ceil(walkers / ARMY_COLUMNS)
  for i = 0, walkers - 1 do
    local col, row = i % ARMY_COLUMNS, math.floor(i / ARMY_COLUMNS)
    local pos = {x = s.x - dir * col * ws, y = s.y + (row - (rows - 1) / 2) * ws}
    if units.spawn("rts-walker", pos, force_name, "walker") then made = made + 1 end
  end
  for i = 0, heavies - 1 do
    local pos = {x = s.x + dir * HEAVY_FRONT, y = s.y + (i - (heavies - 1) / 2) * hs}
    if units.spawn("rts-walker-heavy", pos, force_name, "heavy") then made = made + 1 end
  end
  return made
end

local function config()
  local m = storage.match
  if not m.config then
    m.config = {first_wave_ticks = match.DEFAULT_CONFIG.first_wave_ticks,
                wave_period_ticks = match.DEFAULT_CONFIG.wave_period_ticks}
  end
  return m.config
end

--- Current wave timing {first_wave_ticks, wave_period_ticks} (storage.match.config).
function match.wave_config()
  return config()
end

--- Change the enemy wave timing (seconds). A first wave that has not come yet is rescheduled to
--- tick_started + first (at the earliest one second from now); later waves use the new period from the next
--- launch on. Waves switched off by /rts-qa-reset nowaves stay off. Debug and autotest use only.
function match.set_wave_timing(first_seconds, period_seconds)
  local m = storage.match
  local c = config()
  c.first_wave_ticks = math.max(60, math.floor(first_seconds * 60))
  c.wave_period_ticks = math.max(60, math.floor(period_seconds * 60))
  if m.phase == "running" and (m.wave or 0) == 0 and m.enemy_next_wave and not m.waves_off then
    m.enemy_next_wave = math.max(game.tick + 60, (m.tick_started or game.tick) + c.first_wave_ticks)
  end
  util.log("match: wave timing first=%.0fs period=%.0fs, next wave %s", c.first_wave_ticks / 60,
    c.wave_period_ticks / 60, m.enemy_next_wave and string.format("in %.0fs", (m.enemy_next_wave - game.tick) / 60)
    or "not scheduled")
end

--- Spawn both armies (idempotent per force: only spawns a force that has no units) and (re)start the match.
function match.spawn_armies()
  local m = storage.match
  for _, force_name in pairs({PLAYER, ENEMY}) do
    if units.count(force_name) == 0 then
      local n = spawn_army(force_name)
      util.log("match: spawned %d units for %s at %s", n, force_name, util.pos_str(match.army_point(force_name)))
    end
  end
  m.phase = "running"
  m.winner = nil
  m.ended_tick = nil
  m.tick_started = game.tick
  m.enemy_next_wave = game.tick + config().first_wave_ticks
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

-- Ore patches of one side (match.ORE_PATCHES, flipped in x for the side facing -x).
local function place_ore_patches(surface, force_name)
  local home, dir = SPAWNS[force_name], FACING[force_name]
  local parts = {}
  for _, p in ipairs(match.ORE_PATCHES) do
    local center = {x = home.x + dir * p[2], y = home.y + p[3]}
    local n = basetemplate.place_ore(surface, p[1], center, p[4], p[5], match.ORE_AMOUNT, true)
    parts[#parts + 1] = string.format("%s %dx%d at %s: %d tiles", p[1], p[4], p[5], util.pos_str(center), n)
  end
  util.log("match: ore for %s: %s", force_name, table.concat(parts, "; "))
end

local function stock_stockpiles(stockpiles, items)
  local parts = {}
  for _, entry in ipairs(items) do
    local name, left = entry[1], entry[2]
    for _, chest in ipairs(stockpiles) do
      if left <= 0 then break end
      left = left - chest.insert({name = name, count = left})
    end
    parts[#parts + 1] = string.format("%s=%d", name, entry[2] - left)
  end
  return table.concat(parts, " ")
end

--- Set the walker-kit recipe on every barracks of a force that has none. Returns the number set.
function match.arm_barracks(force_name, recipe)
  local n = 0
  for _, rec in buildings.for_force(force_name, "barracks") do
    if not rec.entity.get_recipe() and production.set_recipe(rec.entity, recipe or match.ENEMY_BARRACKS_RECIPE) then
      n = n + 1
    end
  end
  return n
end

local function place_bases(surface)
  -- Player: the CC composite and the starting stock.
  local cc, parts = buildings.place_cc(surface, SPAWNS[PLAYER], PLAYER)
  if cc then
    util.log("match: %s starting stock: %s", PLAYER, stock_stockpiles(parts.stockpiles, match.STARTING_STOCK))
  end
  -- Enemy: the full starter template, facing the arena centre, with its barracks on walker kits.
  basetemplate.ensure()
  basetemplate.clone_to(surface, ENEMY, SPAWNS[ENEMY], FACING[ENEMY])
  match.arm_barracks(ENEMY, match.ENEMY_BARRACKS_RECIPE)
  for _, force_name in pairs({PLAYER, ENEMY}) do place_ore_patches(surface, force_name) end
end

function match.init()
  if storage.match then
    config() -- older saves: add the wave timing config
    return
  end
  local spawns = {}
  for force_name, pos in pairs(SPAWNS) do spawns[force_name] = {x = pos.x, y = pos.y} end
  storage.match = {phase = "setup", wave = 0, spawns = spawns}
  config()
  local surface = util.surface()
  disable_enemy_bases(surface)
  setup_forces()
  prepare_arena(surface)
  place_bases(surface)
  match.spawn_armies()
  for _, player in pairs(game.players) do match.assign_player(player) end
end

---------------------------------------------------------------------------
-- Enemy brain: every config.wave_period_ticks send every enemy unit, as one unit group, to attack the player army
-- (or its CC when the army is gone).
---------------------------------------------------------------------------
-- Wave target: the player army, or the player's CC when the army is gone.
local function wave_target()
  local target = units.centroid(PLAYER)
  if target then return target end
  local cc = buildings.main_cc(PLAYER)
  return cc and cc.entity.position or nil
end

--- Where a wave near `position` should go next: the nearest player entity within RETARGET_RANGE, else the
--- player army centroid, else the player CC. nil when the player has nothing left.
local function player_target(position)
  if position then
    local nearest = util.surface().find_nearest_enemy({position = position, max_distance = RETARGET_RANGE,
                                                       force = ENEMY})
    if nearest then return nearest.position end
  end
  return wave_target()
end

local function drop_group()
  local m = storage.match
  local g = m.enemy_group
  m.enemy_group, m.enemy_group_id = nil, nil
  if g and g.valid then g.destroy() end
end

local function launch_wave()
  local m = storage.match
  local target = wave_target()
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

-- Result rules (Phase 1 QA follow-up 4: the banner said Victory at 0 vs 0).
--- A force is out when it has no CC, barracks or factory left (buildings.is_alive_force) and no units.
function match.is_out(force_name)
  return units.count(force_name) == 0 and not buildings.is_alive_force(force_name)
end

--- Pure winner rule: a side wins only when the other side is out and it is not; both out is a draw; nobody
--- out is no result (nil).
function match.decide_winner(player_out, enemy_out)
  if player_out and enemy_out then return "draw" end
  if enemy_out then return PLAYER end
  if player_out then return ENEMY end
  return nil
end

--- The match result from a force's point of view, derived from storage.match.phase only:
--- nil while the match is not "ended", else "victory" | "defeat" | "draw". The HUD banner should use this.
function match.result(force_name)
  local m = storage.match
  if not (m and m.phase == "ended") then return nil end
  if m.winner == "draw" or m.winner == nil then return "draw" end
  return m.winner == force_name and "victory" or "defeat"
end

local function check_winner()
  local m = storage.match
  local winner = match.decide_winner(match.is_out(PLAYER), match.is_out(ENEMY))
  if not winner then return end
  m.phase = "ended"
  m.ended_tick = game.tick
  m.winner = winner
  drop_group()
  release_orphans()
  local msg = m.winner == PLAYER and "Victory! The enemy base and army are destroyed."
    or (m.winner == ENEMY and "Defeat. Your base and army are destroyed." or "Draw: both sides are destroyed.")
  game.print("[RTS] " .. msg)
  util.log("match: ended at tick %d, winner=%s (player units=%d alive=%s, enemy units=%d alive=%s)", game.tick,
    m.winner, units.count(PLAYER), tostring(buildings.is_alive_force(PLAYER)), units.count(ENEMY),
    tostring(buildings.is_alive_force(ENEMY)))
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
    m.enemy_next_wave = e.tick + config().wave_period_ticks
    launch_wave()
  end
  check_winner()
end)

match.wave_retarget = player_target

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
