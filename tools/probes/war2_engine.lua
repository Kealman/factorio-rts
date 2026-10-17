-- Engine probe for the M3 war2 package (test copy only, tools/autotest-run.sh EXTRA_LUA; docs/qa/phase5-war2-notes.md).
-- Runs beside a Nation match on a lab surface, forces rts-ai-2 (attacker) and rts-ai-3 (defender), at war (cease fire
-- off). Questions:
--   A. Which gate direction can stand on a horizontal / vertical straight rail (can_place manual_ghost + forced), and
--      does a ghost placed there revive?
--   B. Does a rts-rail-shell-projectile thrown 100 tiles hurt an enemy rts-turret and leave the rails beside it alone
--      (the blast's collision mask object + player)? Damage per shell on the turret.
--   C. LuaEntity.set_priority_target on rts-turret: accepted, read back?
--   D. Armoured stock: health and damage taken per 100 physical / explosion vs the plain stock.
--   E. Artillery wagon: ammo inventory accepts rts-rail-shell; train of loco + arty wagon + loco forms.
-- Log lines "[rts] war2 probe ..." and "[rts] war2 probe summary".
local events = require("scripts.events")
local util = require("scripts.util")

local SURF = "war2-probe"
local A, B = "rts-ai-2", "rts-ai-3"
local D = defines.direction

local function S()
  storage.war2_probe = storage.war2_probe or {phase = "wait", rail_hits = 0, turret_hits = 0}
  return storage.war2_probe
end

local function log(fmt, ...) util.log("war2 probe " .. fmt, ...) end

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
  local st = storage.war2_probe
  if not (st and st.watch) then return end
  local ent = e.entity
  if not (ent and ent.valid) then return end
  if ent.type == "straight-rail" then
    st.rail_hits = st.rail_hits + 1
  elseif ent.name == "rts-turret" then
    st.turret_hits = st.turret_hits + 1
    st.turret_damage = (st.turret_damage or 0) + e.final_damage_amount
  end
end)

local function probe_gates(s)
  local out = {}
  for _, spec in ipairs({{"h", D.east, {x = 0, y = -100}}, {"v", D.north, {x = 40, y = -100}}}) do
    local rail = s.create_entity({name = "straight-rail", position = spec[3], direction = spec[2], force = A})
    local box = rail and rail.bounding_box
    local tiles = {}
    if box then
      for x = math.floor(box.left_top.x), math.ceil(box.right_bottom.x) - 1 do
        for y = math.floor(box.left_top.y), math.ceil(box.right_bottom.y) - 1 do tiles[#tiles + 1] = {x + 0.5, y + 0.5} end
      end
    end
    local res = {}
    for _, t in ipairs(tiles) do
      local ok_n = s.can_place_entity({name = "rts-gate", position = t, direction = D.north, force = A,
        build_check_type = defines.build_check_type.manual_ghost, forced = true})
      local ok_e = s.can_place_entity({name = "rts-gate", position = t, direction = D.east, force = A,
        build_check_type = defines.build_check_type.manual_ghost, forced = true})
      res[#res + 1] = string.format("(%.1f,%.1f) N=%s E=%s", t[1], t[2], tostring(ok_n), tostring(ok_e))
    end
    -- ghost + revive with the direction that worked on the first tile; other checks on the second
    local revived = "-"
    local t = tiles[1]
    local dir = spec[1] == "h" and D.north or D.east
    if t then
      local g = s.create_entity({name = "entity-ghost", inner_name = "rts-gate", position = t, direction = dir, force = A})
      local items, ent = nil, nil
      if g then items, ent = g.revive({raise_revive = true}) end
      local items2, ent2 = nil, nil
      if g and g.valid then items2, ent2 = g.revive() end
      local manual = s.can_place_entity({name = "rts-gate", position = tiles[2], direction = dir, force = A,
        build_check_type = defines.build_check_type.manual})
      local script = s.can_place_entity({name = "rts-gate", position = tiles[2], direction = dir, force = A})
      local revive_chk = s.can_place_entity({name = "rts-gate", position = tiles[2], direction = dir, force = A,
        build_check_type = defines.build_check_type.ghost_revive})
      local direct = s.create_entity({name = "rts-gate", position = tiles[2], direction = dir, force = A})
      local wall = s.create_entity({name = "rts-wall", position = {t[1], t[2] - 1}, force = A})
      local g3 = s.create_entity({name = "entity-ghost", inner_name = "rts-gate", position = tiles[3], direction = dir,
                                  force = A})
      local _, ent3 = nil, nil
      if g3 then _, ent3 = g3.revive({raise_revive = true}) end
      revived = string.format("dir %d ghost %s revived %s/%s; manual %s script %s ghost_revive %s; direct create %s; "
        .. "next to a wall: revived %s", dir, tostring(g ~= nil), tostring(ent ~= nil), tostring(ent2 ~= nil),
        tostring(manual), tostring(script), tostring(revive_chk), tostring(direct ~= nil), tostring(ent3 ~= nil))
    end
    out[#out + 1] = string.format("%s rail dir %d box %s: %s; %s", spec[1], spec[2],
      box and util.pos_str(box.left_top) .. "-" .. util.pos_str(box.right_bottom) or "nil", table.concat(res, " "), revived)
  end
  return out
end

local function setup()
  local st = S()
  local s = surface()
  for _, f in ipairs({A, B}) do if not game.forces[f] then game.create_force(f) end end
  game.forces[A].set_cease_fire(B, false)
  game.forces[B].set_cease_fire(A, false)
  -- A. gates
  for _, line in ipairs(probe_gates(s)) do log("A gate: %s", line) end
  -- E. artillery train on a track, wagon at (0, 0)
  for x = -40, 40, 2 do s.create_entity({name = "straight-rail", position = {x + 1, 1}, direction = D.east, force = A}) end
  local made = {}
  for i, name in ipairs({"rts-locomotive", "rts-artillery-wagon", "rts-locomotive"}) do
    made[i] = s.create_entity({name = name, position = {7 - (i - 1) * 7, 1}, direction = i == 3 and D.west or D.east,
                               force = A})
  end
  local wagon = made[2]
  local inv = wagon and wagon.get_inventory(defines.inventory.artillery_wagon_ammo)
  local put = inv and inv.insert({name = "rts-rail-shell", count = 30}) or 0
  log("E artillery: carriages %s %s %s, one train %s, ammo slots %s, inserted %d shells, gun range %s",
    tostring(made[1] ~= nil), tostring(made[2] ~= nil), tostring(made[3] ~= nil),
    tostring(made[1] and made[3] and made[1].train == made[3].train), inv and #inv or "nil", put,
    tostring(prototypes.item["rts-rail-cannon"] and prototypes.item["rts-rail-cannon"].attack_parameters and
      prototypes.item["rts-rail-cannon"].attack_parameters.range))
  st.wagon = wagon
  -- B. turret 100 tiles south of the wagon, enemy rails next to it
  local tp = {x = wagon.position.x, y = wagon.position.y + 100}
  st.turret = s.create_entity({name = "rts-turret", position = tp, force = B})
  for dx = -6, 6, 2 do s.create_entity({name = "straight-rail", position = {tp.x + dx + 1, tp.y + 3}, direction = D.east,
                                        force = B}) end
  game.forces[A].chart(s, {{tp.x - 32, tp.y - 32}, {tp.x + 32, tp.y + 32}})
  -- C. priority list
  local ok1 = pcall(st.turret.set_priority_target, 1, "rts-artillery")
  local ok2 = pcall(st.turret.set_priority_target, 2, "rts-walker-heavy")
  local p1 = st.turret.get_priority_target(1)
  local p2 = st.turret.get_priority_target(2)
  log("C priority: set %s %s, read %s %s, ignore_unprioritised %s", tostring(ok1), tostring(ok2),
    p1 and p1.name or "nil", p2 and p2.name or "nil", tostring(st.turret.ignore_unprioritised_targets))
  -- D. armoured vs plain locomotive and troop wagon
  local pairs_ = {{"rts-locomotive", "rts-armoured-locomotive"}, {"rts-troop-wagon", "rts-armoured-wagon"}}
  for i, pr in ipairs(pairs_) do
    for j, name in ipairs(pr) do
      local y = -60 + i * 20 + j * 8
      for x = -20, 20, 2 do s.create_entity({name = "straight-rail", position = {x + 1, y}, direction = D.east, force = A}) end
      local e = s.create_entity({name = name, position = {0, y}, direction = D.east, force = A})
      if e then
        local h0 = e.health
        e.damage(100, B, "physical")
        local h1 = e.health
        e.damage(100, B, "explosion")
        local h2 = e.health
        log("D %s: max %d, 100 physical took %.1f, 100 explosion took %.1f", name, e.max_health, h0 - h1, h1 - h2)
      else
        log("D %s: not placed", name)
      end
    end
  end
  st.phase = "fire"
  st.t = game.tick
end

local function fire()
  local st = S()
  local s = surface()
  st.watch = true
  st.h0 = st.turret.health
  local w = st.wagon
  local p = s.create_entity({name = "rts-rail-shell-projectile", position = w.position, target = st.turret.position,
    source = w, cause = w, force = A, speed = 0.6, max_range = 130})
  log("B fired: projectile %s from %s to %s (%.0f tiles)", tostring(p ~= nil), util.pos_str(w.position),
    util.pos_str(st.turret.position), util.distance(w, st.turret))
  st.phase = "wait_hit"
  st.t = game.tick
end

events.on_nth_tick(1, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local st = S()
  if st.phase == "wait" then
    if game.tick - m.tick_started >= 120 then setup() end
  elseif st.phase == "fire" then
    if game.tick - st.t >= 30 then fire() end
  elseif st.phase == "wait_hit" then
    if game.tick - st.t >= 600 then
      local tur = st.turret
      log("B result: turret %s health %.0f -> %s (%d hit events, %.0f damage), rail hit events %d, after %.1f s",
        tostring(tur.valid), st.h0, tur.valid and string.format("%.0f", tur.health) or "dead", st.turret_hits,
        st.turret_damage or 0, st.rail_hits, (game.tick - st.t) / 60)
      st.phase = "done"
      log("summary done")
    end
  end
end)

events.on_load(function() end)
