-- Engine probe for the M3 air package (test copy only, tools/autotest-run.sh EXTRA_LUA; docs/qa/phase5-air-notes.md
-- section 2). Runs on its own lab surface beside any match, with the non-participating forces rts-ai-2 (planes) and
-- rts-ai-3 (ground). Questions:
--   A. planes (`unit`, empty collision mask) cross a 40-tile water band and a wall line by go_to_location; speed
--   B. a unit group of planes crosses the same band
--   C. the AA turret (attack_target_mask air) fires at a plane; a gun turret (ignore_target_mask air) does not, but
--      still fires at a ground drone
--   D. walkers and drones damage a plane
--   E. LuaEntity.speed of a plane: read, write
--   F. bomber hit on a factory (structure) vs on a walker; interceptor hit on a plane (air) vs on a drone
--   G. create_entity / find_non_colliding_position over water
--   H. an artillery shell's area damage reaches a plane
-- Log lines "[rts] air probe ..." and "[rts] air probe done".
local events = require("scripts.events")
local util = require("scripts.util")

local SURF = "air-probe"
local P, G = "rts-ai-2", "rts-ai-3"

local function S()
  storage.air_probe = storage.air_probe or {phase = "wait", dmg = {}}
  return storage.air_probe
end

local function surface()
  local s = game.surfaces[SURF]
  if s then return s end
  s = game.create_surface(SURF, {width = 1200, height = 800, peaceful_mode = true, no_enemies_mode = true})
  s.always_day = true
  for cx = -8, 7 do for cy = -6, 5 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = -256, 255 do
    for y = -192, 191 do
      local water = x >= -20 and x < 20 and y < 0
      tiles[#tiles + 1] = {name = water and "water" or "lab-dark-1", position = {x, y}}
    end
  end
  s.set_tiles(tiles, true, false, false, false)
  for _, e in ipairs(s.find_entities_filtered({area = {{-256, -192}, {256, 192}}})) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  -- a wall line at x = 60 from y = -190 to -2
  for y = -190, -2 do s.create_entity({name = "rts-wall", position = {60.5, y + 0.5}, force = G}) end
  return s
end

events.on(defines.events.on_entity_damaged, function(e)
  local st = storage.air_probe
  if not (st and st.dmg) then return end
  local ent, cause = e.entity, e.cause
  if not (ent and ent.valid) then return end
  local key = string.format("%s<-%s", ent.name, (cause and cause.valid) and cause.name or "?")
  local d = st.dmg[key]
  if not d then
    d = {n = 0, sum = 0, max = 0}
    st.dmg[key] = d
  end
  d.n = d.n + 1
  d.sum = d.sum + e.final_damage_amount
  d.max = math.max(d.max, e.final_damage_amount)
  if st.immortal and st.immortal[ent.unit_number or 0] then ent.health = ent.max_health end
end)

local function spawn(s, name, pos, force)
  local e = s.create_entity({name = name, position = pos, force = force})
  if e and e.commandable then e.commandable.set_command({type = defines.command.stop}) end
  return e
end

local function report_damage(tag)
  local keys = {}
  for k in pairs(S().dmg) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local d = S().dmg[k]
    util.log("air probe %s damage %s: %d hits, sum %.1f, max %.1f", tag, k, d.n, d.sum, d.max)
  end
  S().dmg = {}
end

events.on_nth_tick(1, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local st = S()
  local tick = game.tick
  if st.phase == "wait" then
    if tick - m.tick_started < 60 then return end
    for _, f in ipairs({P, G}) do if not game.forces[f] then game.create_force(f) end end
    game.forces[P].set_cease_fire(G, false)
    game.forces[G].set_cease_fire(P, false)
    local s = surface()
    -- A: five scouts west of the water, ordered east across water and wall to x = 120
    st.a = {}
    for i = 1, 5 do
      local p = spawn(s, "rts-scout-plane", {-80, -150 + i * 20}, P)
      st.a[i] = p
      p.commandable.set_command({type = defines.command.go_to_location, destination = {120, -150 + i * 20},
                                 radius = 2, distraction = defines.distraction.none})
    end
    -- B: a group of five interceptors
    local g = s.create_unit_group({position = {-80, -40}, force = P})
    st.b = {}
    for i = 1, 5 do
      local p = spawn(s, "rts-interceptor", {-80 + i, -40}, P)
      st.b[i] = p
      g.add_member(p)
    end
    g.set_command({type = defines.command.go_to_location, destination = {120, -40}, radius = 4,
                   distraction = defines.distraction.none})
    g.start_moving()
    st.group = g
    -- G: over water
    local fp = s.find_non_colliding_position("rts-bomber", {0, -100}, 8, 0.5)
    local over = s.create_entity({name = "rts-bomber", position = {0, -100}, force = P})
    util.log("air probe G: find_non_colliding_position over water %s, create_entity over water %s at %s",
      util.pos_str(fp), tostring(over ~= nil), over and util.pos_str(over.position) or "-")
    if over then over.destroy() end
    -- E: speed
    local sp = st.a[1].speed
    local ok, err = pcall(function() st.a[5].speed = sp * 0.5 end)
    util.log("air probe E: scout speed %.3f, write x0.5 ok=%s %s, now %.3f", sp, tostring(ok), ok and "" or tostring(err),
      st.a[5].speed)
    st.t0 = tick
    st.phase = "fly"
  elseif st.phase == "fly" then
    local s = game.surfaces[SURF]
    if tick - st.t0 == 300 then
      local x = st.a[1].valid and st.a[1].position.x or 0
      util.log("air probe A: scout #1 after 5 s at x=%.1f (from -80): %.2f tiles/s", x, (x + 80) / 5)
    end
    if tick - st.t0 >= 900 then
      local crossed, line = 0, {}
      for i, p in ipairs(st.a) do
        if p.valid then
          if p.position.x > 100 then crossed = crossed + 1 end
          line[#line + 1] = util.pos_str(p.position)
        end
      end
      util.log("air probe A: %d of 5 scouts crossed water and wall within 15 s: %s", crossed, table.concat(line, " "))
      local gc, gl = 0, {}
      for _, p in ipairs(st.b) do
        if p.valid then
          if p.position.x > 100 then gc = gc + 1 end
          gl[#gl + 1] = util.pos_str(p.position)
        end
      end
      util.log("air probe B: group of 5 interceptors: %d crossed within 15 s, state %s: %s", gc,
        st.group.valid and util.define_name(defines.group_state, st.group.state) or "invalid", table.concat(gl, " "))
      for _, p in ipairs(st.a) do if p.valid then p.destroy() end end
      for _, p in ipairs(st.b) do if p.valid then p.destroy() end end
      -- C: turrets on the east side, a plane hovering between them, a drone near the gun turret
      local aa = s.create_entity({name = "rts-aa-turret", position = {150, 50}, force = G})
      aa.insert({name = "firearm-magazine", count = 20})
      local gun = s.create_entity({name = "rts-turret", position = {150, 80}, force = G})
      gun.insert({name = "firearm-magazine", count = 20})
      st.c = {aa = aa, gun = gun, plane = spawn(s, "rts-bomber", {150, 65}, P)}
      st.c.plane.commandable.set_command({type = defines.command.stop, distraction = defines.distraction.none})
      st.c.plane_hp = st.c.plane.health
      st.t1 = tick
      st.dmg = {}
      st.phase = "turrets"
    end
  elseif st.phase == "turrets" then
    local c = st.c
    if tick - st.t1 == 600 then
      local aa_mag = c.aa.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine")
      local gun_mag = c.gun.get_inventory(defines.inventory.turret_ammo).get_item_count("firearm-magazine")
      util.log("air probe C: after 10 s: plane %s health %.0f/%.0f; AA magazines %d/20; gun magazines %d/20",
        c.plane.valid and "alive" or "dead", c.plane.valid and c.plane.health or 0, c.plane_hp, aa_mag, gun_mag)
      report_damage("C")
      -- control: a drone beside the gun turret
      local s = game.surfaces[SURF]
      c.drone = spawn(s, "rts-drone", {150, 90}, P)
      c.drone.commandable.set_command({type = defines.command.stop, distraction = defines.distraction.none})
      c.drone_hp = c.drone.health
    elseif tick - st.t1 == 900 then
      util.log("air probe C: control drone near the gun turret after 5 s: %s health %.0f/%.0f",
        c.drone.valid and "alive" or "dead", c.drone.valid and c.drone.health or 0, c.drone_hp)
      report_damage("C2")
      for _, e in pairs({c.aa, c.gun, c.plane, c.drone}) do if e.valid then e.destroy() end end
      -- D: two walkers and two drones of G next to an interceptor of P (it hovers, fights back)
      local s = game.surfaces[SURF]
      st.d = {plane = spawn(s, "rts-interceptor", {-150, 100}, P)}
      st.d.plane.health = st.d.plane.max_health
      st.d.ground = {spawn(s, "rts-walker", {-160, 100}, G), spawn(s, "rts-walker", {-160, 104}, G),
                     spawn(s, "rts-drone", {-155, 96}, G), spawn(s, "rts-drone", {-155, 104}, G)}
      st.t2 = tick
      st.phase = "ground"
    end
  elseif st.phase == "ground" then
    if tick - st.t2 == 600 then
      local d = st.d
      util.log("air probe D: interceptor vs 2 walkers + 2 drones after 10 s: plane %s health %.0f",
        d.plane.valid and "alive" or "dead", d.plane.valid and d.plane.health or 0)
      report_damage("D")
      for _, e in pairs(d.ground) do if e.valid then e.destroy() end end
      if d.plane.valid then d.plane.destroy() end
      -- F: a bomber attacks a factory, another a walker; an interceptor attacks a scout, another a drone
      local s = game.surfaces[SURF]
      local fac = s.create_entity({name = "rts-factory", position = {-150, 150}, force = G})
      local wk = spawn(s, "rts-walker-heavy", {-100, 150}, G)
      local sc = spawn(s, "rts-scout-plane", {-50, 150}, G)
      local dr = spawn(s, "rts-drone", {0, 150}, G)
      st.immortal = {}
      for _, e in pairs({fac, wk, sc, dr}) do st.immortal[e.unit_number] = true end
      local function attacker(name, x, target)
        local a = spawn(s, name, {x, 130}, P)
        a.commandable.set_command({type = defines.command.attack, target = target, distraction = defines.distraction.none})
        return a
      end
      st.f = {fac, wk, sc, dr, attacker("rts-bomber", -150, fac), attacker("rts-bomber", -100, wk),
              attacker("rts-interceptor", -50, sc), attacker("rts-interceptor", 0, dr)}
      st.t3 = tick
      st.dmg = {}
      st.phase = "bonus"
    end
  elseif st.phase == "bonus" then
    if tick - st.t3 == 900 then
      report_damage("F")
      for _, e in pairs(st.f) do if e.valid then e.destroy() end end
      -- H: an artillery shell on a hovering plane
      local s = game.surfaces[SURF]
      local pl = spawn(s, "rts-interceptor", {100, 150}, P)
      st.h = pl
      st.h_hp = pl.health
      s.create_entity({name = "rts-artillery-shell", position = {100, 120}, force = G, target = {100, 150},
                       source = {100, 120}, speed = 1})
      st.t4 = tick
      st.dmg = {}
      st.phase = "shell"
    end
  elseif st.phase == "shell" then
    if tick - st.t4 == 180 then
      util.log("air probe H: artillery shell on a plane: %s health %.0f/%.0f", st.h.valid and "alive" or "dead",
        st.h.valid and st.h.health or 0, st.h_hp)
      report_damage("H")
      st.phase = "done"
      util.log("air probe done")
    end
  end
end)
