-- Engine probe for the M2 war package (test copy only, EXTRA_LUA). Questions:
--  A. Does a health clamp in on_entity_damaged keep an rts-city-center / rts-command-center alive when one hit would
--     kill it (final_health 0)?
--  B. Cost of LuaEntity.force writes for ~3,000 mixed entities in slices of 500 per tick.
--  C. Does a train of force B run on rails of force A (and to a stop of force A)?
-- Log lines "[rts] war probe ...".
local events = require("scripts.events")
local util = require("scripts.util")

local SURF = "war-probe"
local A, B = "rts-ai-3", "rts-ai-2"

local function S() storage.war_probe = storage.war_probe or {phase = "wait"} return storage.war_probe end

local function surface()
  local s = game.surfaces[SURF]
  if s then return s end
  s = game.create_surface(SURF, {width = 2000, height = 2000, peaceful_mode = true, no_enemies_mode = true})
  s.always_day = true
  for cx = -10, 9 do for cy = -6, 5 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -320, 319 do for y = -192, 191 do tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}} end end
  s.set_tiles(tiles, true, false, false, false)
  for _, e in ipairs(s.find_entities_filtered({area = {{-320, -192}, {320, 192}}})) do if e.valid then e.destroy() end end
  return s
end

events.on(defines.events.on_entity_damaged, function(e)
  local st = storage.war_probe
  if not (st and st.clamp) then return end
  local ent = e.entity
  if not (ent and ent.valid) then return end
  if ent.name ~= "rts-city-center" and ent.name ~= "rts-command-center" then return end
  local floor_hp = ent.max_health * 0.1
  st.events = (st.events or 0) + 1
  st.last_final = e.final_health
  if ent.health < floor_hp then ent.health = floor_hp end
end)

local function test_clamp(s)
  local st = S()
  st.clamp = true
  local out = {}
  for i, name in ipairs({"rts-city-center", "rts-command-center"}) do
    local e = s.create_entity({name = name, position = {-200 + i * 20, -150}, force = A})
    local un = e.unit_number
    local dealt = e.damage(1000000, B, "physical")
    local alive = e.valid
    out[#out + 1] = string.format("%s: one 1e6 hit dealt %.0f, final_health in event %s, alive=%s health=%s/%s",
      name, dealt, tostring(st.last_final), tostring(alive), alive and string.format("%.0f", e.health) or "-",
      alive and string.format("%.0f", e.max_health) or "-")
    if alive then
      -- a second big hit at the clamp
      e.damage(1000000, B, "explosion")
      out[#out + 1] = string.format("  second hit: alive=%s health=%.0f", tostring(e.valid), e.valid and e.health or -1)
      e.destroy()
    end
  end
  st.clamp = false
  for _, line in ipairs(out) do util.log("war probe A: %s", line) end
end

local function build_field(s)
  local list = {}
  local x0, y0 = -300, -100
  local function add(name, x, y, dir)
    local e = s.create_entity({name = name, position = {x, y}, direction = dir, force = A})
    if e then list[#list + 1] = e end
  end
  -- 300 factories (3x3) in rows
  for i = 0, 299 do add("rts-factory", x0 + (i % 30) * 4, y0 + math.floor(i / 30) * 4) end
  -- 1000 belts, 500 inserters, 300 stockpiles, 300 poles, 100 turrets, 500 walls
  for i = 0, 999 do add("transport-belt", x0 + 130 + (i % 50), y0 + math.floor(i / 50)) end
  for i = 0, 499 do add("fast-inserter", x0 + 190 + (i % 50), y0 + math.floor(i / 50)) end
  for i = 0, 299 do add("rts-stockpile", x0 + 250 + (i % 30) * 2, y0 + math.floor(i / 30) * 2) end
  for i = 0, 299 do add("medium-electric-pole", x0 + 320 + (i % 30) * 2, y0 + math.floor(i / 30) * 2) end
  for i = 0, 99 do add("rts-turret", x0 + 390 + (i % 20) * 3, y0 + math.floor(i / 20) * 3) end
  for i = 0, 499 do add("rts-wall", x0 + 460 + (i % 50), y0 + math.floor(i / 50)) end
  return list
end

local function setup_train(s)
  -- 120 straight rails along y = 151 from x = -240 to x = 0; the east half is force A, the west half force B
  local rails = {}
  for i = 0, 119 do
    local x = -240 + 1 + 2 * i
    local r = s.create_entity({name = "straight-rail", position = {x, 151}, direction = defines.direction.east,
                               force = (x > -120) and A or B})
    rails[#rails + 1] = r
  end
  local stop = s.create_entity({name = "rts-depot-stop", position = {-6, 153}, direction = defines.direction.east,
                                force = A})
  if stop then stop.backer_name = "probe-stop-A" end
  local stopB = s.create_entity({name = "rts-depot-stop", position = {-20, 153}, direction = defines.direction.east,
                                 force = B})
  if stopB then stopB.backer_name = "probe-stop-B" end
  util.log("war probe C: stops connected: A %s, B %s", tostring(stop and stop.connected_rail ~= nil),
    tostring(stopB and stopB.connected_rail ~= nil))
  -- control: a track of force B only, y = 171, with a stop of B at its east end
  for i = 0, 119 do
    s.create_entity({name = "straight-rail", position = {-240 + 1 + 2 * i, 171}, direction = defines.direction.east,
                     force = B})
  end
  local stopC = s.create_entity({name = "rts-depot-stop", position = {-20, 173}, direction = defines.direction.east,
                                 force = B})
  if stopC then stopC.backer_name = "probe-stop-C" end
  local locoC = s.create_entity({name = "rts-locomotive", position = {-225, 171}, direction = defines.direction.east,
                                 force = B})
  locoC.get_fuel_inventory().insert({name = "coal", count = 20})
  local sc = locoC.train.get_schedule()
  sc.add_record({station = "probe-stop-C", wait_conditions = {{type = "time", ticks = 600}}})
  locoC.train.manual_mode = false
  sc.go_to_station(1)
  storage.war_probe.locoC = locoC
  local loco = s.create_entity({name = "rts-locomotive", position = {-225, 151}, direction = defines.direction.east,
                                force = B})
  local inv = loco and loco.get_fuel_inventory()
  if inv then inv.insert({name = "coal", count = 20}) end
  return rails, stop, loco
end

events.on_nth_tick(1, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local st = S()
  if st.phase == "wait" then
    if game.tick - m.tick_started < 120 then return end
    for _, f in ipairs({A, B}) do if not game.forces[f] then game.create_force(f) end end
    local s = surface()
    test_clamp(s)
    local prof = helpers.create_profiler()
    st.field = build_field(s)
    prof.stop()
    log({"", string.format("[rts] war probe B: %d entities built in ", #st.field), prof})
    st.i, st.slices, st.phase = 1, 0, "flip"
    st.flip_start = game.tick
  elseif st.phase == "flip" then
    local prof = helpers.create_profiler()
    local n = 0
    while n < 500 and st.i <= #st.field do
      local ent = st.field[st.i]
      if ent.valid then ent.force = B end
      st.i = st.i + 1
      n = n + 1
    end
    prof.stop()
    st.slices = st.slices + 1
    log({"", string.format("[rts] war probe B: slice %d flipped %d entities in ", st.slices, n), prof})
    if st.i > #st.field then
      local s = surface()
      local left = s.count_entities_filtered({area = {{-310, -110}, {320, 0}}, force = A})
      util.log("war probe B: %d slices over %d ticks, %d entities of the old force left", st.slices,
        game.tick - st.flip_start, left)
      local rails, stop, loco = setup_train(s)
      st.loco = loco
      st.phase = "train"
      st.train_tick = game.tick
      local train = loco.train
      local sch = train.get_schedule()
      sch.add_record({station = "probe-stop-A", wait_conditions = {{type = "time", ticks = 600}}})
      train.manual_mode = false
      sch.go_to_station(1)
      util.log("war probe C: train of %s scheduled to stop of %s: state %s", B, A, tostring(train.state))
    end
  elseif st.phase == "train" then
    local loco = st.loco
    if game.tick - st.train_tick == 60 then
      local t = loco.train
      util.log("war probe C: after 1 s: state %d (no_path=%d on_the_path=%d), speed %.3f, x %.1f", t.state,
        defines.train_state.no_path, defines.train_state.on_the_path, t.speed, loco.position.x)
      if t.state == defines.train_state.no_path then
        local sch = t.get_schedule()
        sch.clear_records()
        sch.add_record({station = "probe-stop-B", wait_conditions = {{type = "time", ticks = 600}}})
        sch.go_to_station(1)
        util.log("war probe C: re-scheduled to the stop of its own force %s (across rails of %s): state %d", B, A,
          t.state)
      end
    elseif game.tick - st.train_tick == 900 then
      local t = loco.train
      util.log("war probe C: after 15 s: state %d, x %.1f, station %s", t.state, loco.position.x,
        t.station and t.station.backer_name or "-")
      local c = st.locoC
      util.log("war probe C: control train (own rails, own stop): state %d, x %.1f, station %s", c.train.state,
        c.position.x, c.train.station and c.train.station.backer_name or "-")
      st.phase = "done"
      util.log("war probe done")
    end
  end
end)
