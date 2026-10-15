-- Developer tools: /rts-* console commands and the headless autotest.
-- Owns storage.debug = {autotest = nil|true|false, stage, started, stage_tick, units = {[unit_number] = true},
--                       moved, retargets, next_report}
--
-- Autotest: decided once at tick 120. With no connected players (tools/headless-run.sh) it spawns both
-- armies if needed, sends 5 player walkers to {0, 0} (go_to_location), then attack-moves them into the
-- enemy (attack_area re-targeted at the nearest enemy on completion) and logs unit counts every 10 s.
-- Its units carry order = "autotest", so units.lua's idle rule and orders.lua leave them alone.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local match = require("scripts.match")

local debug_tools = {}

local PLAYER, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
local AUTOTEST_DECIDE_TICK = 120
local AUTOTEST_UNITS = 5
local AUTOTEST_MOVE_DEST = {x = 0, y = 0}
local AUTOTEST_MOVE_TIMEOUT = 20 * 60
local AUTOTEST_REPORT_PERIOD = 10 * 60
local ATTACK_RADIUS = 10
local RETARGET_RANGE = 300
local CLAIM = "autotest"

function debug_tools.init()
  storage.debug = storage.debug or {}
end

---------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------
local function force_summary(force_name)
  local kinds, orders, n = {}, {}, 0
  for _, rec in units.for_force(force_name) do
    n = n + 1
    kinds[rec.kind] = (kinds[rec.kind] or 0) + 1
    orders[rec.order] = (orders[rec.order] or 0) + 1
  end
  local function fmt(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, " ")
  end
  return string.format("%s: %d units [%s] orders [%s]", force_name, n, fmt(kinds), fmt(orders))
end

--- Lines describing the current state (used by /rts-dump and the autotest).
function debug_tools.dump_lines()
  local m = storage.match or {}
  local lines = {
    string.format("tick %d, match phase=%s wave=%s next wave in %ss winner=%s", game.tick, tostring(m.phase),
      tostring(m.wave), m.enemy_next_wave and string.format("%.0f", (m.enemy_next_wave - game.tick) / 60) or "-",
      tostring(m.winner)),
    force_summary(PLAYER),
    force_summary(ENEMY),
    string.format("registry size=%d, enemy group=%s", table_size(storage.units or {}),
      (m.enemy_group and m.enemy_group.valid) and ("#" .. m.enemy_group.unique_id) or "none"),
  }
  for index, p in pairs(storage.players or {}) do
    local player = game.get_player(index)
    lines[#lines + 1] = string.format("player %d (%s): desired=%s controller=%s setup_done=%s connected=%s",
      index, player and player.name or "?", tostring(p.desired_controller),
      player and util.define_name(defines.controllers, player.controller_type) or "?",
      tostring(p.setup_done), tostring(player and player.connected))
  end
  local d = storage.debug or {}
  lines[#lines + 1] = string.format("autotest=%s stage=%s", tostring(d.autotest), tostring(d.stage))
  return lines
end

local function reply(cmd, line)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player then player.print(line) else game.print(line) end
  util.log("%s", line)
end

---------------------------------------------------------------------------
-- Autotest
---------------------------------------------------------------------------
local function autotest_report()
  local d = storage.debug
  local alive = 0
  for un in pairs(d.units) do
    if units.get(un) then alive = alive + 1 end
  end
  util.log("autotest t=%.0fs player=%d (walker %d, heavy %d) enemy=%d (walker %d, heavy %d) "
    .. "autotest_alive=%d stage=%s moved=%d retargets=%d wave=%d match=%s",
    (game.tick - d.started) / 60, units.count(PLAYER), units.count(PLAYER, "walker"), units.count(PLAYER, "heavy"),
    units.count(ENEMY), units.count(ENEMY, "walker"), units.count(ENEMY, "heavy"), alive, d.stage, d.moved,
    d.retargets, storage.match.wave or 0, tostring(storage.match.phase))
  return alive
end

-- Attack-move one autotest unit towards the nearest enemy; idle it when no enemy is left in range.
local function retarget(rec)
  local enemy = util.surface().find_nearest_enemy({position = rec.entity.position, max_distance = RETARGET_RANGE,
                                                   force = rec.force})
  if not enemy then
    rec.order = units.IDLE
    units.stop(rec.entity)
    return false
  end
  rec.entity.commandable.set_command({type = defines.command.attack_area, destination = enemy.position,
                                      radius = ATTACK_RADIUS, distraction = defines.distraction.by_anything})
  storage.debug.retargets = storage.debug.retargets + 1
  return true
end

local function start_attack(why)
  local d = storage.debug
  d.stage = "attack"
  d.stage_tick = game.tick
  local n = 0
  for un in pairs(d.units) do
    local rec = units.get(un)
    if rec and retarget(rec) then n = n + 1 end
  end
  util.log("autotest: attack-move issued to %d units (%s)", n, why)
end

function debug_tools.start_autotest()
  local d = storage.debug
  d.autotest = true
  if storage.match.phase ~= "running" or units.count(PLAYER) == 0 or units.count(ENEMY) == 0 then
    match.spawn_armies()
  end
  debug_tools.run_command("rts-spawn", "rts-walker 2 " .. PLAYER) -- exercises the console command path
  debug_tools.run_command("rts-dump", "")
  d.started = game.tick
  d.stage = "move"
  d.stage_tick = game.tick
  d.units, d.moved, d.retargets = {}, 0, 0
  d.next_report = game.tick
  local picked = {}
  for un, rec in units.for_force(PLAYER) do
    if rec.kind == "walker" and #picked < AUTOTEST_UNITS then picked[#picked + 1] = un end
  end
  for i, un in ipairs(picked) do
    local rec = units.get(un)
    -- spread the destinations in a small cross so the walkers do not stack
    local dx, dy = ((i - 1) % 3 - 1) * 4, (math.floor((i - 1) / 3) - 0.5) * 4
    rec.order = CLAIM
    rec.dest = {x = AUTOTEST_MOVE_DEST.x + dx, y = AUTOTEST_MOVE_DEST.y + dy}
    rec.entity.commandable.set_command({type = defines.command.go_to_location, destination = rec.dest,
                                        distraction = defines.distraction.none, radius = 1.5})
    d.units[un] = true
  end
  util.log("autotest: started at tick %d, go_to_location %s issued to %d walkers [%s]", game.tick,
    util.pos_str(AUTOTEST_MOVE_DEST), #picked, table.concat(picked, ","))
end

local function autotest_tick(tick)
  local d = storage.debug
  if tick >= d.next_report then
    d.next_report = tick + AUTOTEST_REPORT_PERIOD
    if autotest_report() == 0 and d.stage ~= "done" then
      d.stage = "done"
      util.log("autotest: no autotest unit left alive")
    end
  end
  if d.stage == "move" and tick - d.stage_tick >= AUTOTEST_MOVE_TIMEOUT then
    start_attack("move timeout")
  end
end

-- One-off diagnostic: what rts-player has charted / sees around both spawns (chunks (-2,0) and (1,0)).
local CHART_PROBE_TICK = 600
local function chart_probe()
  local force, surface = game.forces[PLAYER], util.surface()
  local parts = {}
  for _, c in pairs({{-2, 0}, {1, 0}}) do
    parts[#parts + 1] = string.format("chunk(%d,%d) charted=%s visible=%s", c[1], c[2],
      tostring(force.is_chunk_charted(surface, c)), tostring(force.is_chunk_visible(surface, c)))
  end
  util.log("debug: chart probe at tick %d for %s: %s", game.tick, PLAYER, table.concat(parts, ", "))
end

events.on_nth_tick(60, function(e)
  local d = storage.debug
  if e.tick == CHART_PROBE_TICK then chart_probe() end
  if d.autotest == nil and e.tick >= AUTOTEST_DECIDE_TICK then
    d.autotest = #game.connected_players == 0
    util.log("autotest: %s (%d connected players at tick %d)", d.autotest and "on" or "off",
      #game.connected_players, e.tick)
    if d.autotest then debug_tools.start_autotest() end
  end
  if d.autotest and d.stage then autotest_tick(e.tick) end
end)

events.on(defines.events.on_ai_command_completed, function(e)
  local d = storage.debug
  if not (d and d.autotest and d.units and d.units[e.unit_number]) then return end
  local rec = units.get(e.unit_number)
  if not rec or rec.order ~= CLAIM then return end
  local result = util.define_name(defines.behavior_result, e.result)
  if d.stage == "move" then
    d.moved = d.moved + 1
    units.stop(rec.entity) -- wait for the others
    util.log("autotest: move completed by #%d result=%s at %s, %.1f tiles from its destination [%d/%d]",
      e.unit_number, result, util.pos_str(rec.entity.position), util.distance(rec.entity, rec.dest), d.moved,
      table_size(d.units))
    if d.moved >= table_size(d.units) then start_attack("all moves completed") end
  elseif d.stage == "attack" then
    retarget(rec)
  end
end)

---------------------------------------------------------------------------
-- Console commands
---------------------------------------------------------------------------
local function admin_only(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player and not player.admin then
    player.print("[rts] admins only")
    return false
  end
  return true
end

local COMMANDS = {
  ["rts-spawn"] = {
    help = "<name> <count> <force> - spawn RTS units at the camera (or the force's spawn)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      local args = {}
      for word in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = word end
      local name, count, force_name = args[1] or "rts-walker", tonumber(args[2] or "1"), args[3] or PLAYER
      local proto = prototypes.entity[name]
      if not proto or (proto.type ~= "spider-unit" and proto.type ~= "unit") then
        reply(cmd, "rts-spawn: unknown unit prototype " .. tostring(name))
        return
      end
      if not game.forces[force_name] then
        reply(cmd, "rts-spawn: unknown force " .. tostring(force_name))
        return
      end
      count = math.max(1, math.min(100, math.floor(count or 1)))
      local player = cmd.player_index and game.get_player(cmd.player_index)
      local center = player and player.position or match.home(force_name)
      local made = 0
      for i = 0, count - 1 do
        local pos = {x = center.x + (i % 10) * 3 - 13.5, y = center.y + math.floor(i / 10) * 3 + 12}
        if units.spawn(name, pos, force_name) then made = made + 1 end
      end
      reply(cmd, string.format("rts-spawn: %d x %s for %s near %s", made, name, force_name, util.pos_str(center)))
    end,
  },
  ["rts-dump"] = {
    help = "- print a summary of the RTS state",
    run = function(cmd)
      for _, line in pairs(debug_tools.dump_lines()) do reply(cmd, line) end
    end,
  },
  ["rts-autotest"] = {
    help = "- start the scripted autotest (5 walkers move, then attack)",
    run = function(cmd)
      if not admin_only(cmd) then return end
      debug_tools.start_autotest()
      reply(cmd, "rts-autotest: started")
    end,
  },
}

for name, def in pairs(COMMANDS) do
  commands.add_command(name, def.help, def.run)
end

--- Run one of the /rts-* commands from script (as the server console), e.g. from the autotest.
function debug_tools.run_command(name, parameter)
  COMMANDS[name].run({name = name, parameter = parameter, tick = game.tick})
end

return debug_tools
