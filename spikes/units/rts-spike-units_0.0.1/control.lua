-- Phase 0 spike #3: spider-units as RTS units. Headless scenario; every result is a log() line
-- prefixed with "[rts-units]". Phases run back to back, driven by script.on_nth_tick:
--   setup -> orders (move + hold test) -> group -> combat (after set_multi_command) -> scale -> idle -> done
local TAG = "[rts-units] "
local RED, BLUE = "rts-red", "rts-blue"
local ARENA = 128     -- half-size of the grass arena, in tiles
local SCHED = 30      -- scheduler period, ticks
local REPORT = 300    -- report period, ticks (5 s)

-- Schedule in seconds after setup.
local AT = {
  spawn = 2,
  hold_fallback = 18, -- give a hold order to units whose move order never completed
  group = 22,
  multi = 32,         -- set_multi_command test, then full combat
  combat_timeout = 75,
  scale_duration = 30,
  idle_duration = 20, -- after the scale test: red holds with `stop`, blue is left without orders
}

local TEAMS = {
  {force = RED, short = "red", x = -40, dir = -1},
  {force = BLUE, short = "blue", x = 40, dir = 1},
}

-- Small-test roster per team. Each kind spawns as a column at the team's x.
local ROSTER = {
  {kind = "walker", name = function() return "rts-walker" end, count = 10, y0 = -50, dy = 4},
  {kind = "heavy", name = function() return "rts-walker-heavy" end, count = 3, y0 = -6, dy = 6},
  {kind = "swarm", name = function(t) return "rts-swarm-" .. t.short end, count = 10, y0 = 14, dy = 4},
  {kind = "swarm_rt", name = function() return "rts-swarm" end, count = 1, y0 = 58, dy = 0},
}

local HOLD_STRATEGIES = {"none", "stop", "wander0", "stop_renew"}

-- Not persisted (cannot be stored in `storage`); only used within one server run.
local wall_clock   -- LuaProfiler: wall-clock time between scale reports
local script_clock -- LuaProfiler: accumulated time spent in this mod's event handlers
local cache = {tick = -1, centroid = {}}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function logf(fmt, ...) log(TAG .. string.format(fmt, ...)) end

local function define_name(tbl, value)
  for k, v in pairs(tbl) do if v == value then return k end end
  return tostring(value)
end

local function pos_str(p) return p and string.format("(%.1f,%.1f)", p.x, p.y) or "nil" end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function secs() return (game.tick - storage.t0) / 60 end

local function surface() return game.surfaces["nauvis"] end

local function try(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then return true, res end
  return false, (tostring(res):gsub("\n", " | "))
end

local function clock_start()
  if not script_clock then
    script_clock = helpers.create_profiler(true)
  end
  script_clock.restart() -- resume without resetting
end

local function clock_stop() script_clock.stop() end

-- Stats buckets: "orders", "fight" (group + combat phases), "scale", "done".
local function stats_bucket(phase)
  if phase == "group" or phase == "combat" then return "fight" end
  return phase
end

local function stats()
  local bucket = stats_bucket(storage.phase)
  local st = storage.stats[bucket]
  if not st then
    st = {hits = 0, dmg = {}, dtypes = {}, ff = 0, deaths = {}, deaths_logged = 0, first_hit_logged = false,
          events = {}, reissues = 0, groups_created = 0, groups_by_force = {}, adds_logged = 0, unknown = 0}
    storage.stats[bucket] = st
  end
  return st
end

local function enemy_of(force_name) return force_name == RED and BLUE or RED end

local function alive(force_name, kind)
  local n = 0
  for _, rec in pairs(storage.units) do
    if rec.e.valid and rec.team == force_name and (not kind or rec.kind == kind) then n = n + 1 end
  end
  return n
end

local function centroid(force_name, kind)
  local key = force_name .. "/" .. (kind or "*")
  if cache.tick ~= game.tick then cache = {tick = game.tick, centroid = {}} end
  local c = cache.centroid[key]
  if c ~= nil then return c or nil end
  local sx, sy, n = 0, 0, 0
  for _, rec in pairs(storage.units) do
    if rec.e.valid and rec.team == force_name and (not kind or rec.kind == kind) then
      local p = rec.e.position
      sx, sy, n = sx + p.x, sy + p.y, n + 1
    end
  end
  c = n > 0 and {x = sx / n, y = sy / n} or false
  cache.centroid[key] = c
  return c or nil
end

local function command_name(c)
  local cmd = c.command
  return cmd and define_name(defines.command, cmd.type) or "none"
end

-------------------------------------------------------------------------------
-- Setup: forces and arena
-------------------------------------------------------------------------------
local function setup_forces()
  local red = game.forces[RED] or game.create_force(RED)
  local blue = game.forces[BLUE] or game.create_force(BLUE)
  red.custom_color = {r = 1, g = 0.1, b = 0.1, a = 1}
  blue.custom_color = {r = 0.1, g = 0.35, b = 1, a = 1}
  for _, pair in pairs({{red, blue}, {blue, red}}) do
    local a, b = pair[1], pair[2]
    a.set_friend(b, false)
    a.set_cease_fire(b, false)
    for _, other in pairs({"enemy", "player", "neutral"}) do
      a.set_cease_fire(other, true)
      game.forces[other].set_cease_fire(a, true)
    end
    a.ai_controllable = false
  end
  for _, f in pairs({red, blue}) do
    local o = game.forces[enemy_of(f.name)]
    logf("forces: %s index=%d color=%s custom_color=%s is_enemy(%s)=%s cease_fire(%s)=%s cease_fire(enemy)=%s "
      .. "enemy.cease_fire(%s)=%s ai_controllable=%s", f.name, f.index, serpent.line(f.color),
      serpent.line(f.custom_color), o.name, tostring(f.is_enemy(o)), o.name, tostring(f.get_cease_fire(o)),
      tostring(f.get_cease_fire("enemy")), f.name, tostring(game.forces.enemy.get_cease_fire(f)),
      tostring(f.ai_controllable))
  end
end

local function prepare_arena()
  local s = surface()
  local prof = helpers.create_profiler()
  s.request_to_generate_chunks({0, 0}, math.ceil(ARENA / 32) + 1)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -ARENA, ARENA - 1 do
    for y = -ARENA, ARENA - 1 do
      tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
    end
  end
  s.set_tiles(tiles, true, true, true, false)
  local removed = 0
  for _, e in pairs(s.find_entities_filtered({area = {{-ARENA, -ARENA}, {ARENA, ARENA}}})) do
    if e.valid and e.type ~= "resource" and e.type ~= "character" then
      e.destroy()
      removed = removed + 1
    end
  end
  s.always_day = true
  prof.stop()
  log({"", TAG, string.format("arena: %d tiles set to grass-1, %d entities removed in [%d,%d]^2 ",
    #tiles, removed, -ARENA, ARENA), prof})
  local water = s.count_tiles_filtered({area = {{-ARENA, -ARENA}, {ARENA, ARENA}}, collision_mask = "water_tile"})
  logf("arena: water tiles left=%d, chunk (0,0) generated=%s, chunk (3,3) generated=%s", water,
    tostring(s.is_chunk_generated({0, 0})), tostring(s.is_chunk_generated({3, 3})))
end

local function setup()
  storage.t0 = game.tick
  storage.phase = "setup"
  local ms = game.map_settings
  logf("setup: tick=%d space-age=%s quality=%s map_settings.max_failed_behavior_count=%s enemy_expansion=%s "
    .. "enemy_evolution=%s path_finder.max_steps_worked_per_tick=%s", game.tick,
    tostring(script.active_mods["space-age"]), tostring(script.active_mods["quality"]),
    tostring(ms.max_failed_behavior_count), tostring(ms.enemy_expansion.enabled),
    tostring(ms.enemy_evolution.enabled), tostring(ms.path_finder.max_steps_worked_per_tick))
  setup_forces()
  prepare_arena()
end

-------------------------------------------------------------------------------
-- Spawning and orders
-------------------------------------------------------------------------------
local function spawn(name, force, pos, exact)
  local s = surface()
  local p = pos
  if not exact then p = s.find_non_colliding_position(name, pos, 8, 0.5) or pos end
  return s.create_entity({name = name, position = p, force = force})
end

local function register(e, team, kind, index)
  local rec = {e = e, team = team, kind = kind, name = e.name, index = index}
  storage.units[e.unit_number] = rec
  return rec
end

local function describe_entity(e, label)
  local c = e.commandable
  local okc, color = try(function() return e.color end)
  local ai = e.ai_settings
  local okr, radar = try(function() return e.prototype.radar_range end)
  logf("spawn detail %s: name=%s type=%s unit_number=%s valid=%s force=%s commandable=%s is_entity=%s "
    .. "has_command=%s health=%.0f/%.0f color: ok=%s value=%s | ai_settings: destroy_when_commands_fail=%s "
    .. "try_return_to_spawner=%s do_separation=%s join_attacks=%s | prototype.radar_range: ok=%s value=%s",
    label, e.name, e.type, tostring(e.unit_number), tostring(e.valid), e.force.name, tostring(c ~= nil),
    tostring(c and c.is_entity), tostring(c and c.has_command), e.health, e.max_health,
    tostring(okc), okc and serpent.line(color) or color,
    tostring(ai and ai.allow_destroy_when_commands_fail), tostring(ai and ai.allow_try_return_to_spawner),
    tostring(ai and ai.do_separation), tostring(ai and ai.join_attacks), tostring(okr), tostring(radar))
end

local function spawn_and_move()
  storage.phase = "orders"
  for _, team in pairs(TEAMS) do
    for _, r in pairs(ROSTER) do
      local name = r.name(team)
      local made, valid, cmd, forces = 0, 0, 0, {}
      for i = 1, r.count do
        local e = spawn(name, team.force, {x = team.x, y = r.y0 + (i - 1) * r.dy})
        if e then
          made = made + 1
          if e.valid then valid = valid + 1 end
          if e.commandable then cmd = cmd + 1 end
          forces[e.force.name] = true
          local rec = register(e, team.force, r.kind, i)
          if i == 1 then describe_entity(e, team.short .. "/" .. r.kind) end
          -- Move order: 30 tiles away from the enemy, no distraction.
          local start = e.position
          rec.start = start
          rec.dest = {x = start.x + team.dir * 30, y = start.y}
          rec.order_tick = game.tick
          rec.hold = HOLD_STRATEGIES[(i - 1) % #HOLD_STRATEGIES + 1]
          e.commandable.set_command({type = defines.command.go_to_location, destination = rec.dest,
            distraction = defines.distraction.none, radius = 1.5})
        end
      end
      local fl = {}
      for f in pairs(forces) do fl[#fl + 1] = f end
      logf("spawn %s: %s x%d requested, created=%d valid=%d commandable=%d forces=%s", team.short, name,
        r.count, made, valid, cmd, table.concat(fl, ","))
    end
  end
  logf("orders: go_to_location (30 tiles, distraction=none, radius=1.5) issued to %d units at tick %d",
    table_size(storage.units), game.tick)
end

-- RTS attack-move: attack_area around the nearest enemy (or the enemy centroid).
local function attack_move(rec, radius, use_centroid)
  local target
  if use_centroid then
    target = centroid(enemy_of(rec.team))
  else
    local enemy = surface().find_nearest_enemy({position = rec.e.position, max_distance = 400, force = rec.team})
    target = enemy and enemy.position
  end
  if not target then return false end
  rec.e.commandable.set_command({type = defines.command.attack_area, destination = target, radius = radius,
    distraction = defines.distraction.by_enemy})
  return true
end

-------------------------------------------------------------------------------
-- Hold-position test
-------------------------------------------------------------------------------
local function apply_hold(rec)
  local e = rec.e
  local cmd
  if rec.hold == "stop" then
    cmd = {type = defines.command.stop}
  elseif rec.hold == "wander0" then
    cmd = {type = defines.command.wander, radius = 0}
  elseif rec.hold == "stop_renew" then
    cmd = {type = defines.command.stop, ticks_to_wait = 300}
  end
  if cmd then
    local ok, err = try(e.commandable.set_command, cmd)
    if not ok then logf("hold: %s #%d set_command(%s) failed: %s", rec.kind, e.unit_number, rec.hold, err) end
  end
  rec.hold_pos = e.position
  rec.hold_tick = game.tick
end

local function hold_fallback()
  storage.hold_fallback_done = true
  local n = 0
  for un, rec in pairs(storage.units) do
    if rec.e.valid and not rec.hold_pos then
      n = n + 1
      logf("hold fallback: %s %s #%d never completed its move order; pos=%s dest=%s dist=%.1f command=%s "
        .. "moving_state=%s", rec.team, rec.kind, un, pos_str(rec.e.position), pos_str(rec.dest),
        dist(rec.e.position, rec.dest), command_name(rec.e.commandable),
        define_name(defines.moving_state, rec.e.commandable.moving_state))
      apply_hold(rec)
    end
  end
  logf("hold fallback: %d units without move completion at t=%.1fs", n, secs())
end

local function report_hold()
  local agg = {}
  local pending = 0
  for _, rec in pairs(storage.units) do
    if rec.e.valid then
      if rec.hold_pos then
        local key = rec.kind .. "/" .. rec.hold
        local a = agg[key] or {n = 0, max = 0, sum = 0, over2 = 0, cmds = {}, states = {}, step = 0, to_dest = 0}
        agg[key] = a
        local p = rec.e.position
        local d = dist(p, rec.hold_pos)
        -- movement since the previous report separates "settling after the order" from "wandering"
        local step = dist(p, rec.last_report_pos or rec.hold_pos)
        rec.last_report_pos = p
        if step > a.step then a.step = step end
        a.to_dest = a.to_dest + dist(p, rec.dest)
        a.n = a.n + 1
        a.sum = a.sum + d
        if d > a.max then a.max = d end
        if d > 2 then a.over2 = a.over2 + 1 end
        local c = rec.e.commandable
        local cn = command_name(c)
        a.cmds[cn] = (a.cmds[cn] or 0) + 1
        local ms = define_name(defines.moving_state, c.moving_state)
        a.states[ms] = (a.states[ms] or 0) + 1
      else
        pending = pending + 1
      end
    end
  end
  local keys = {}
  for k in pairs(agg) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local a = agg[k]
    logf("hold t=%.0fs %-18s n=%d drift_from_hold_point max=%.2f mean=%.2f over_2_tiles=%d | max_moved_last_5s=%.2f "
      .. "mean_dist_to_ordered_point=%.2f | commands=%s moving_states=%s", secs(), k, a.n, a.max, a.sum / a.n,
      a.over2, a.step, a.to_dest / a.n, serpent.line(a.cmds), serpent.line(a.states))
  end
  if pending > 0 then logf("hold t=%.0fs: %d units still executing their move order", secs(), pending) end
end

local function summarize_moves()
  local agg = {}
  for _, rec in pairs(storage.units) do
    local a = agg[rec.kind] or {n = 0, done = 0, ticks = {}, err = 0, results = {}, distracted = 0}
    agg[rec.kind] = a
    a.n = a.n + 1
    if rec.done_tick then
      a.done = a.done + 1
      a.ticks[#a.ticks + 1] = rec.done_tick - rec.order_tick
      a.err = math.max(a.err, rec.done_err or 0)
      a.results[rec.result] = (a.results[rec.result] or 0) + 1
      if rec.distracted then a.distracted = a.distracted + 1 end
    end
  end
  for kind, a in pairs(agg) do
    table.sort(a.ticks)
    local mn, mx = a.ticks[1], a.ticks[#a.ticks]
    local med = a.ticks[math.max(1, math.floor(#a.ticks / 2))]
    logf("move summary %-8s completed=%d/%d results=%s distracted=%d ticks min/median/max=%s/%s/%s "
      .. "speed(tiles/s, 30 tiles / median)=%s max_dist_to_dest_at_completion=%.2f", kind, a.done, a.n,
      serpent.line(a.results), a.distracted, tostring(mn), tostring(med), tostring(mx),
      med and string.format("%.2f", 30 / (med / 60)) or "n/a", a.err)
  end
end

-------------------------------------------------------------------------------
-- Unit group test: red group with ai_controllable=false, blue group with ai_controllable=true.
-- Stage 1: go_to_location 15 tiles toward the middle (distraction none).
-- Stage 2 (on the group's completion event): attack_area on the enemy walkers.
-------------------------------------------------------------------------------
local function make_group(team, ai)
  local s = surface()
  local force = game.forces[team.force]
  force.ai_controllable = ai
  local here = centroid(team.force, "walker")
  local ok, g = try(s.create_unit_group, {position = here, force = force})
  logf("group: create_unit_group for %s with ai_controllable=%s -> ok=%s %s", team.force, tostring(ai),
    tostring(ok), ok and string.format("unique_id=%d is_unit_group=%s is_script_driven=%s state=%s", g.unique_id,
      tostring(g.is_unit_group), tostring(g.is_script_driven), define_name(defines.group_state, g.state)) or g)
  if not ok then return end
  local members = {}
  for un, rec in pairs(storage.units) do
    if #members < 5 and rec.team == team.force and rec.kind == "walker" and rec.e.valid then
      local okm, err = try(g.add_member, rec.e)
      if okm then
        members[#members + 1] = un
      else
        logf("group: add_member #%d failed: %s", un, err)
      end
    end
  end
  local dest = {x = here.x - team.dir * 15, y = here.y}
  local okc, errc = try(g.set_command, {type = defines.command.go_to_location, destination = dest,
    distraction = defines.distraction.none})
  storage.groups[g.unique_id] = {g = g, team = team.force, ai = ai, t = game.tick, stage = "go_to",
                                 last_state = nil, members = members}
  logf("group: #%d (%s) %d members added %s; stage 1 go_to_location dest=%s set_command ok=%s %s; members=%d "
    .. "state=%s", g.unique_id, team.force, #members, serpent.line(members), pos_str(dest), tostring(okc),
    okc and "" or errc, #g.members, define_name(defines.group_state, g.state))
end

local function group_test()
  summarize_moves()
  storage.phase = "group"
  make_group(TEAMS[1], false)
  make_group(TEAMS[2], true)
end

local function on_group_completed(gr, ev, result)
  logf("group: on_ai_command_completed for group #%d (%s, ai_controllable at creation=%s) stage=%s result=%s "
    .. "was_distracted=%s at t=%.1fs (%.1fs after stage start) members=%d", ev.unit_number, gr.team,
    tostring(gr.ai), gr.stage, result, tostring(ev.was_distracted), secs(), (ev.tick - gr.t) / 60,
    gr.g.valid and #gr.g.members or -1)
  if gr.stage == "go_to" and gr.g.valid then
    local target = centroid(enemy_of(gr.team), "walker") or centroid(enemy_of(gr.team))
    if target then
      gr.g.set_command({type = defines.command.attack_area, destination = target, radius = 15,
        distraction = defines.distraction.by_enemy})
      gr.stage = "attack_area"
      gr.t = ev.tick
      logf("group: #%d stage 2 attack_area dest=%s radius=15", ev.unit_number, pos_str(target))
    end
  else
    gr.stage = "done:" .. result
  end
end

local function watch_groups()
  for id, gr in pairs(storage.groups) do
    if not gr.gone then
      local g = gr.g
      if not g.valid then
        gr.gone = true
        logf("group: #%d (%s) became invalid at t=%.1fs", id, gr.team, secs())
      else
        local state = define_name(defines.group_state, g.state)
        if state ~= gr.last_state then
          gr.last_state = state
          logf("group: #%d (%s) t=%.1fs state=%s members=%d position=%s moving_state=%s command=%s", id, gr.team,
            secs(), state, #g.members, pos_str(g.position), define_name(defines.moving_state, g.moving_state),
            command_name(g))
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- set_multi_command test: red with ai_controllable=false, blue with ai_controllable=true.
-------------------------------------------------------------------------------
local function multi_test()
  local s = surface()
  for _, case in ipairs({{team = RED, ai = false}, {team = BLUE, ai = true}}) do
    local force = game.forces[case.team]
    force.ai_controllable = case.ai
    local before = {}
    for un, rec in pairs(storage.units) do
      if rec.e.valid and rec.team == case.team then
        local c = rec.e.commandable
        before[un] = {cmd = command_name(c), group = c.parent_group and c.parent_group.unique_id}
      end
    end
    local dest = centroid(enemy_of(case.team))
    local ok, res = try(s.set_multi_command, {
      command = {type = defines.command.attack_area, destination = dest, radius = 20,
                 distraction = defines.distraction.by_enemy},
      unit_count = 10, force = force, unit_search_distance = 150})
    local changed = {}
    for un, b in pairs(before) do
      local rec = storage.units[un]
      local c = rec.e.commandable
      local now_group = c.parent_group and c.parent_group.unique_id
      local now_cmd = command_name(c)
      if now_cmd ~= b.cmd or now_group ~= b.group then
        rec.multi = true
        local key = string.format("%s/%s:%s->%s%s", rec.kind, rec.hold or "?", b.cmd, now_cmd,
          now_group and ("@group" .. now_group) or "")
        changed[key] = (changed[key] or 0) + 1
      end
    end
    logf("multi: set_multi_command(attack_area dest=%s radius=20 unit_count=10) force=%s ai_controllable=%s -> "
      .. "ok=%s returned=%s; units whose command/group changed: %s", pos_str(dest), case.team, tostring(case.ai),
      tostring(ok), tostring(res), serpent.line(changed))
  end
end

-------------------------------------------------------------------------------
-- Combat
-------------------------------------------------------------------------------
local function snapshot(label)
  for _, team in pairs(TEAMS) do
    local lines = {}
    for un, rec in pairs(storage.units) do
      if rec.e.valid and rec.team == team.force then
        local c = rec.e.commandable
        lines[#lines + 1] = string.format("%s#%d@%s cmd=%s grp=%s ms=%s hp=%.0f", rec.kind, un,
          pos_str(rec.e.position), command_name(c), c.parent_group and tostring(c.parent_group.unique_id) or "-",
          define_name(defines.moving_state, c.moving_state), rec.e.health)
      end
    end
    logf("snapshot %s %s (%d): %s", label, team.short, #lines, table.concat(lines, "; "))
  end
end

local function start_combat()
  storage.phase = "combat"
  storage.combat_t0 = game.tick
  game.forces[BLUE].ai_controllable = false
  game.forces[RED].ai_controllable = false
  local issued, skipped = 0, 0
  for _, rec in pairs(storage.units) do
    if rec.e.valid then
      if rec.e.commandable.parent_group then
        skipped = skipped + 1
      elseif attack_move(rec, 25, true) then
        issued = issued + 1
      end
    end
  end
  logf("combat: ai_controllable reset to false for both; attack_area toward enemy centroid issued to %d units, "
    .. "%d skipped (in a group); alive red=%d blue=%d", issued, skipped, alive(RED), alive(BLUE))
end

local function report_combat(final)
  local st = stats()
  local parts = {}
  for _, t in pairs(TEAMS) do
    parts[#parts + 1] = string.format("%s walker=%d heavy=%d swarm=%d", t.short, alive(t.force, "walker"),
      alive(t.force, "heavy"), alive(t.force, "swarm") + alive(t.force, "swarm_rt"))
  end
  local dmg = {}
  for k, v in pairs(st.dmg) do dmg[#dmg + 1] = string.format("%s=%.0f", k, v) end
  table.sort(dmg)
  local dtypes = {}
  for k in pairs(st.dtypes) do dtypes[#dtypes + 1] = k end
  table.sort(dtypes)
  logf("%s t=%.0fs phase=%s alive: %s | hits=%d damage(attacker->victim): %s | damage types=%s | "
    .. "friendly-fire hits=%d | deaths=%s | reissued orders=%d", final and "combat FINAL" or "combat", secs(),
    storage.phase, table.concat(parts, "; "), st.hits, table.concat(dmg, " "), table.concat(dtypes, ","),
    st.ff, serpent.line(st.deaths), st.reissues)
  -- Stall detection: no new hits for a whole report period while both sides are alive.
  if storage.phase == "combat" and not final then
    if st.hits == storage.last_hits and alive(RED) > 0 and alive(BLUE) > 0 then
      storage.stalls = (storage.stalls or 0) + 1
      if storage.stalls <= 2 then snapshot("stall") end
    end
    storage.last_hits = st.hits
  end
end

local function combat_over()
  return alive(RED) == 0 or alive(BLUE) == 0
end

local function end_combat()
  report_combat(true)
  local winner = alive(RED) == 0 and (alive(BLUE) == 0 and "none (both dead)" or BLUE)
    or (alive(BLUE) == 0 and RED or "unresolved (timeout)")
  logf("combat RESULT: winner=%s after %.1fs of full combat (%.1fs since the first group order)", winner,
    (game.tick - storage.combat_t0) / 60, secs() - AT.group)
  if winner == "unresolved (timeout)" then snapshot("timeout") end
  for _, bucket in pairs({"orders", "fight"}) do
    local st = storage.stats[bucket]
    if st then
      logf("event summary bucket=%s on_ai_command_completed by kind:result=%s unknown_unit_numbers=%d "
        .. "unit_groups_created=%d", bucket, serpent.line(st.events), st.unknown, st.groups_created)
    end
  end
end

-------------------------------------------------------------------------------
-- Scale / UPS test
-------------------------------------------------------------------------------
local function start_scale()
  -- Clear the small test.
  for _, gr in pairs(storage.groups) do if gr.g.valid then gr.g.destroy() end end
  storage.groups = {}
  for _, rec in pairs(storage.units) do if rec.e.valid then rec.e.destroy() end end
  storage.units = {}

  storage.phase = "scale"
  local prof = helpers.create_profiler()
  local n = 0
  for _, team in pairs(TEAMS) do
    for col = 0, 9 do
      for row = 0, 19 do
        local x = team.dir * (44 + col * 4)
        local e = spawn("rts-walker", team.force, {x = x, y = -38 + row * 4}, true)
        if e then
          register(e, team.force, "walker", n)
          n = n + 1
        end
      end
    end
  end
  prof.stop()
  log({"", TAG, string.format("scale: spawned %d rts-walker (200 per side) at tick %d in ", n, game.tick), prof})
  prof.reset() -- resets and restarts
  local issued = 0
  for _, rec in pairs(storage.units) do
    if attack_move(rec, 30, true) then issued = issued + 1 end
  end
  prof.stop()
  log({"", TAG, string.format("scale: attack_area issued to %d units in ", issued), prof})
  storage.scale = {t0 = game.tick, last_tick = game.tick}
  wall_clock = helpers.create_profiler()
  script_clock = helpers.create_profiler(true)
end

local function report_scale(final)
  local sc = storage.scale
  local st = stats()
  local moving, stuck, with_cmd, in_group = 0, 0, 0, 0
  for _, rec in pairs(storage.units) do
    if rec.e.valid then
      local c = rec.e.commandable
      if c.has_command then with_cmd = with_cmd + 1 end
      if c.parent_group then in_group = in_group + 1 end
      local ms = c.moving_state
      if ms == defines.moving_state.moving then moving = moving + 1 end
      if ms == defines.moving_state.stuck then stuck = stuck + 1 end
    end
  end
  local msg = string.format("%s t=%.1fs tick=%d game_ticks_since_last=%d alive red=%d blue=%d hits=%d deaths=%s "
    .. "reissued=%d has_command=%d moving=%d stuck=%d in_group=%d groups_created=%d | wall-clock since last report: ",
    final and "scale FINAL" or "scale", (game.tick - sc.t0) / 60, game.tick, game.tick - sc.last_tick,
    alive(RED), alive(BLUE), st.hits, serpent.line(st.deaths), st.reissues, with_cmd, moving, stuck, in_group,
    st.groups_created)
  if wall_clock and script_clock then
    wall_clock.stop()
    log({"", TAG, msg, wall_clock, " | mod event-handler time: ", script_clock})
    wall_clock.reset()
    script_clock.reset()
    script_clock.stop()
  else
    log(TAG .. msg .. "n/a (profiler lost after load)")
  end
  sc.last_tick = game.tick
end

-------------------------------------------------------------------------------
-- Idle test: do idle units of a non-AI force get pulled into engine-made unit groups?
-------------------------------------------------------------------------------
local function start_idle()
  storage.phase = "idle"
  storage.idle_t0 = game.tick
  local stopped = 0
  for _, rec in pairs(storage.units) do
    if rec.e.valid and rec.team == RED then
      local c = rec.e.commandable
      if c.parent_group then c.parent_group.destroy() end
      c.set_command({type = defines.command.stop})
      stopped = stopped + 1
    end
  end
  logf("idle: red: %d units given `stop`; blue: %d units left without new orders (attack-move loop off)",
    stopped, alive(BLUE))
end

local function report_idle(final)
  local st = stats()
  local parts = {}
  for _, team in pairs(TEAMS) do
    local n, in_group, cmds = 0, 0, {}
    for _, rec in pairs(storage.units) do
      if rec.e.valid and rec.team == team.force then
        n = n + 1
        local c = rec.e.commandable
        if c.parent_group then in_group = in_group + 1 end
        local cn = command_name(c)
        cmds[cn] = (cmds[cn] or 0) + 1
      end
    end
    parts[#parts + 1] = string.format("%s alive=%d in_group=%d groups_created=%d commands=%s", team.short, n, in_group,
      st.groups_by_force[team.force] or 0, serpent.line(cmds))
  end
  logf("%s t=%.1fs | %s | hits=%d", final and "idle FINAL" or "idle", (game.tick - storage.idle_t0) / 60,
    table.concat(parts, " | "), st.hits)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local function on_ai_command_completed(ev)
  if not storage.phase or not storage.stats then return end
  clock_start()
  local st = stats()
  local result = define_name(defines.behavior_result, ev.result)
  local rkey = result .. (ev.was_distracted and "+distracted" or "")

  local gr = storage.groups[ev.unit_number]
  if gr then
    st.events["group:" .. rkey] = (st.events["group:" .. rkey] or 0) + 1
    on_group_completed(gr, ev, result)
    clock_stop()
    return
  end

  local rec = storage.units[ev.unit_number]
  if not rec then
    st.unknown = st.unknown + 1
    if st.unknown <= 5 then
      logf("event: on_ai_command_completed for unknown unit_number=%d result=%s phase=%s", ev.unit_number,
        result, storage.phase)
    end
    clock_stop()
    return
  end
  local ekey = rec.kind .. ":" .. rkey
  st.events[ekey] = (st.events[ekey] or 0) + 1
  rec.last_result, rec.last_done_tick = rkey, ev.tick
  if not rec.e.valid then clock_stop() return end

  if storage.phase == "orders" then
    if not rec.done_tick then
      rec.done_tick = ev.tick
      rec.result = result
      rec.distracted = ev.was_distracted
      rec.done_err = dist(rec.e.position, rec.dest)
      logf("move done: %s %s #%d result=%s was_distracted=%s ticks=%d dist_to_dest=%.2f -> hold=%s",
        rec.team, rec.kind, ev.unit_number, result, tostring(ev.was_distracted), ev.tick - rec.order_tick,
        rec.done_err, rec.hold)
      apply_hold(rec)
    elseif rec.hold == "stop_renew" then
      rec.renews = (rec.renews or 0) + 1
      rec.e.commandable.set_command({type = defines.command.stop, ticks_to_wait = 300})
      if rec.renews == 1 then
        logf("hold: stop(ticks_to_wait=300) completed for %s #%d result=%s after %d ticks; renewed",
          rec.kind, ev.unit_number, result, ev.tick - rec.hold_tick)
      end
    else
      rec.extra = (rec.extra or 0) + 1
      if rec.extra == 1 then
        logf("hold: unexpected completion for %s #%d hold=%s result=%s %d ticks after hold order", rec.kind,
          ev.unit_number, rec.hold, result, ev.tick - (rec.hold_tick or ev.tick))
      end
    end
  elseif storage.phase == "combat" or storage.phase == "scale" then
    -- Attack-move loop: units outside groups re-target the nearest enemy when their order completes.
    if not rec.e.commandable.parent_group and attack_move(rec, 15, false) then
      st.reissues = st.reissues + 1
    end
  end
  clock_stop()
end

local function on_entity_damaged(ev)
  if not storage.phase or not storage.stats then return end
  clock_start()
  local st = stats()
  local victim = ev.entity.force.name
  local attacker = ev.force and ev.force.name or "nil"
  st.hits = st.hits + 1
  local key = attacker .. "->" .. victim
  st.dmg[key] = (st.dmg[key] or 0) + ev.final_damage_amount
  st.dtypes[ev.damage_type.name] = true
  if attacker == victim then st.ff = st.ff + 1 end
  if not st.first_hit_logged then
    st.first_hit_logged = true
    logf("damage: first hit in phase %s at t=%.1fs: victim=%s(%s) attacker_force=%s cause=%s source=%s type=%s "
      .. "original=%.1f final=%.1f final_health=%.1f", storage.phase, secs(), ev.entity.name, victim, attacker,
      ev.cause and ev.cause.valid and ev.cause.name or "nil", ev.source and ev.source.valid and ev.source.name or "nil",
      ev.damage_type.name, ev.original_damage_amount, ev.final_damage_amount, ev.final_health)
  end
  clock_stop()
end

local function on_entity_died(ev)
  if not storage.phase or not storage.stats then return end
  local st = stats()
  local key = ev.entity.force.name .. "/" .. ev.entity.name
  st.deaths[key] = (st.deaths[key] or 0) + 1
  if st.deaths_logged < 3 then
    st.deaths_logged = st.deaths_logged + 1
    logf("death: phase=%s t=%.1fs %s(%s) killed by cause=%s force=%s damage_type=%s", storage.phase, secs(),
      ev.entity.name, ev.entity.force.name, ev.cause and ev.cause.valid and ev.cause.name or "nil",
      ev.force and ev.force.name or "nil", ev.damage_type and ev.damage_type.name or "nil")
  end
end

local function on_unit_group_created(ev)
  if not storage.phase or not storage.stats then return end
  local st = stats()
  st.groups_created = st.groups_created + 1
  local g = ev.group
  st.groups_by_force[g.force.name] = (st.groups_by_force[g.force.name] or 0) + 1
  if st.groups_created <= 5 then
    logf("event: on_unit_group_created phase=%s t=%.1fs group=#%d force=%s is_script_driven=%s members=%d "
      .. "position=%s", storage.phase, storage.t0 and secs() or 0, g.unique_id, g.force.name,
      tostring(g.is_script_driven), #g.members, pos_str(g.position))
  end
end

local function log_group_event(label)
  return function(ev)
    if not storage.phase or storage.phase == "scale" then return end
    local g = ev.group
    storage.group_events = (storage.group_events or 0) + 1
    if storage.group_events <= 30 then
      logf("event: %s group=#%s unit=%s t=%.1fs", label, g and g.valid and tostring(g.unique_id) or "?",
        ev.unit and ev.unit.valid and tostring(ev.unit.unit_number) or "-", storage.t0 and secs() or 0)
    end
  end
end

local UNIT_FILTER = {{filter = "type", type = "spider-unit"}, {filter = "type", type = "unit"}}

script.on_event(defines.events.on_ai_command_completed, on_ai_command_completed)
script.on_event(defines.events.on_entity_damaged, on_entity_damaged, UNIT_FILTER)
script.on_event(defines.events.on_entity_died, on_entity_died, UNIT_FILTER)
script.on_event(defines.events.on_unit_group_created, on_unit_group_created)
script.on_event(defines.events.on_unit_group_finished_gathering, log_group_event("on_unit_group_finished_gathering"))
local log_added_small = log_group_event("on_unit_added_to_group")
script.on_event(defines.events.on_unit_added_to_group, function(ev)
  if storage.phase ~= "scale" and storage.phase ~= "idle" then return log_added_small(ev) end
  -- Large phases: describe the first units the engine pulls into its own (non-script) groups.
  local st = stats()
  local g = ev.group
  if st.adds_logged >= 10 or not (g and g.valid) or g.is_script_driven then return end
  st.adds_logged = st.adds_logged + 1
  local u = ev.unit
  local rec = u and u.valid and u.unit_number and storage.units[u.unit_number]
  logf("event: engine group #%d (%s) took unit #%s kind=%s; unit's last completed command: %s, %s ticks ago",
    g.unique_id, g.force.name, u and u.valid and tostring(u.unit_number) or "?", rec and rec.kind or "?",
    rec and tostring(rec.last_result) or "none", rec and rec.last_done_tick and tostring(ev.tick - rec.last_done_tick)
    or "-")
end)
script.on_event(defines.events.on_unit_removed_from_group, log_group_event("on_unit_removed_from_group"))

script.on_init(function()
  storage.units = {}
  storage.stats = {}
  storage.groups = {}
  storage.phase = nil -- setup runs on the first scheduler tick so that it lands in the server log
  log(TAG .. "on_init at tick " .. game.tick)
end)

-- Scheduler: phase transitions.
script.on_nth_tick(SCHED, function()
  if not storage.t0 then
    setup()
    return
  end
  local s = secs()
  local phase = storage.phase
  if phase == "setup" and s >= AT.spawn then
    spawn_and_move()
  elseif phase == "orders" then
    if s >= AT.hold_fallback and not storage.hold_fallback_done then hold_fallback() end
    if s >= AT.group then group_test() end
  elseif phase == "group" then
    watch_groups()
    if s >= AT.multi then
      multi_test()
      start_combat()
    end
  elseif phase == "combat" then
    watch_groups()
    if combat_over() or s >= AT.combat_timeout then
      end_combat()
      start_scale()
    end
  elseif phase == "scale" then
    if game.tick - storage.scale.t0 >= AT.scale_duration * 60 then
      report_scale(true)
      start_idle()
    end
  elseif phase == "idle" then
    if game.tick - storage.idle_t0 >= AT.idle_duration * 60 then
      report_idle(true)
      storage.phase = "done"
      logf("DONE at tick %d (t=%.1fs)", game.tick, secs())
    end
  end
end)

-- Periodic reports (every 5 s).
script.on_nth_tick(REPORT, function()
  local phase = storage.phase
  if phase == "orders" then
    report_hold()
  elseif phase == "group" or phase == "combat" then
    report_combat(false)
  elseif phase == "scale" then
    report_scale(false)
  elseif phase == "idle" then
    report_idle(false)
  end
end)
