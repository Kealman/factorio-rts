-- Phase 5 M3 QA fix round probe (test copy only, tools/autotest-run.sh EXTRA_LUA): the Codex QA's steps 12-13 and 19-21
-- headless. 1v1 Nation at 2048:
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m3_qa_fix.lua STOP_ON=RTS_QAFIX_DONE SEED=501 SPEED=4 \
--     tools/autotest-run.sh m3i-qafix '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048,
--     enemy_brain = "ai"}' 900
-- Artillery (F1): war on rts-ai-1, /rts-front (a rival town 110-130 tiles from the capital), a depot 20-30 tiles from
-- the capital towards it, an artillery train in Bombard: it must fire within 45 s at the town ~93 tiles away with no
-- unit near the town. AA (F2): an AA turret with magazines; an enemy bomber spawned 11 tiles from it, then one 70 tiles
-- away sent at it (/rts-spawn's distance argument): the AA engages each ("aa: ... fires at" log lines) and a kill by the
-- AA is attributed to it. Log: "[rts] qafix check <name>: PASS|FAIL ...", "qafix summary P/N", RTS_QAFIX_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local cities = require("scripts.cities")
local diplomacy = require("scripts.diplomacy")
local rails = require("scripts.rails")
local logistics = require("scripts.logistics")
local trainswar = require("scripts.trainswar")
local buildings = require("scripts.buildings")
local units = require("scripts.units")
local territory = require("scripts.territory")
local dbg = require("scripts.debug")
local balance = require("balance")

local F, E = "rts-player", "rts-ai-1"
local T0 = 20 * 60
local function S()
  storage.qafix = storage.qafix or {step = "start", pass = 0, fail = 0, kills = {}, engaged = {}}
  return storage.qafix
end
local function check(name, ok, fmt, ...)
  local s = S()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("qafix check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

local function capital()
  local nat = storage.nations and storage.nations[F]
  return nat and nat.capital and cities.get(nat.capital)
end

local function nearest_own(surface, pos, filter, r)
  local best
  local f = {position = pos, radius = r, force = F}
  for k, v in pairs(filter or {}) do f[k] = v end
  for _, e in ipairs(surface.find_entities_filtered(f)) do
    local d = util.distance(e.position, pos)
    if not best or d < best.d then best = {d = d, name = e.name} end
  end
  return best
end

local function land_distance(pos)
  local best
  for r = 0, 128, 8 do
    for a = 0, 15 do
      local ang = a * math.pi / 8
      local p = {x = pos.x + r * math.cos(ang), y = pos.y + r * math.sin(ang)}
      if territory.owner_at(p) == F then return r end
      if r == 0 then break end
    end
  end
  return best
end

events.on(defines.events.on_entity_died, function(e)
  local ent = e.entity
  if not (ent and ent.valid and ent.name == "rts-bomber") then return end
  local c = e.cause
  S().kills[#S().kills + 1] = {un = ent.unit_number, cause = c and c.valid and c.name or "none",
                               cause_un = c and c.valid and c.unit_number or nil}
  util.log("qafix: bomber #%d died, cause %s", ent.unit_number, c and c.valid and c.name or "none")
end)

events.on_nth_tick(30, function()
  local s = S()
  local tick = game.tick
  if s.step == "done" then return end
  if s.aa and s.aa.valid then
    local t = s.aa.shooting_target
    if t and t.valid and t.name == "rts-bomber" and not s.engaged[t.unit_number] then
      s.engaged[t.unit_number] = tick
      util.log("qafix: AA #%d targets bomber #%d at %.0f tiles", s.aa.unit_number, t.unit_number,
        util.distance(s.aa.position, t.position))
    end
  end
  -- no own unit near the town while the train looks for it: the town must be seen through land (the QA case: Division
  -- 1 had died)
  if s.step == "watch" and s.town then
    local surface = game.surfaces[s.surface]
    for _, e in ipairs(surface.find_entities_filtered({position = s.town, radius = 64, force = F,
                                                        type = {"unit", "spider-unit", "spider-vehicle", "car"}})) do
      if e.valid and e.name ~= "rts-commander" then e.destroy({raise_destroy = true}) end
    end
  end
  if s.step == "start" and tick >= T0 then
    local cap = capital()
    if not cap then return end
    diplomacy.set_state(F, E, "war", "qafix probe")
    dbg.run_command("rts-front", E)
    local town
    for _, c in pairs(cities.for_force(E)) do
      if c.why and string.find(tostring(c.why), "rts%-front") then town = c end
      if not town or c.id > town.id then town = c end
    end
    local force = game.forces[F]
    for _, t in ipairs({"rts-railways", balance.nation.trains_war.tech}) do
      if force.technologies[t] then force.technologies[t].researched = true end
    end
    s.cap, s.town = {x = cap.position.x, y = cap.position.y}, town and {x = town.position.x, y = town.position.y}
    s.town_id = town and town.id
    util.log("qafix: capital %s, town %s #%s, %.0f tiles", util.pos_str(s.cap), s.town and util.pos_str(s.town) or "-",
      tostring(s.town_id), s.town and util.distance(s.cap, s.town) or -1)
    if not s.town then
      check("arty", false, "no town from /rts-front")
      s.step = "aa"
      return
    end
    -- a depot 20-30 tiles from the capital towards the town
    local surface = game.surfaces[cap.entity and cap.entity.surface.index or 1] or game.surfaces.nauvis
    local dx, dy = s.town.x - s.cap.x, s.town.y - s.cap.y
    local len = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / len, dy / len
    local site
    for _, d in ipairs({22, 26, 30, 34, 18}) do
      for _, o in ipairs({0, 8, -8, 16, -16}) do
        local p = {x = math.floor(s.cap.x + dx * d - dy * o) + 0.5, y = math.floor(s.cap.y + dy * d + dx * o) + 0.5}
        if not site and surface.can_place_entity({name = rails.DEPOT, position = p, force = F,
            build_check_type = defines.build_check_type.manual_ghost, forced = true})
            and rails.platform_fits(surface, F, p) then site = p end
      end
    end
    if not site then
      check("arty", false, "no depot site towards the town")
      s.step = "aa"
      return
    end
    local d = surface.create_entity({name = rails.DEPOT, position = site, force = F, raise_built = true})
    s.depot = d and d.unit_number
    s.surface = surface.index
    util.log("qafix: depot #%s at %s, %.0f tiles from the town", tostring(s.depot), util.pos_str(site),
      util.distance(site, s.town))
    s.step = "stock"
    s.t = tick + 120
  elseif s.step == "stock" and tick >= s.t then
    local net = s.depot and logistics.hub_network(s.depot)
    if net then
      net.insert({name = rails.LOCO_KIT, count = 2})
      net.insert({name = rails.ARTY_KIT, count = 1})
      net.insert({name = trainswar.SHELL, count = 40})
      net.insert({name = rails.FUEL, count = 100})
    end
    s.step = "deploy"
    s.t = tick + 60
  elseif s.step == "deploy" and tick >= s.t then
    local train, why = trainswar.deploy(s.depot, trainswar.KIND)
    if not train then
      check("arty", false, "deploy failed: %s", tostring(why))
      s.step = "aa"
      return
    end
    s.train = train.id
    trainswar.set_stance(train.id, "bombard")
    s.step = "watch"
    s.t = tick + 45 * 60
  elseif s.step == "watch" and tick >= s.t then
    local rec = rails.train_record(s.train) or (storage.rails and storage.rails.trains[s.train])
    local surface = game.surfaces[s.surface]
    local found = surface.find_entities_filtered({position = s.town, radius = 40, force = E})
    local blds = 0
    for _, e in ipairs(found) do if e.unit_number and buildings.get(e.unit_number) then blds = blds + 1 end end
    local own = nearest_own(surface, s.town, nil, 200)
    local ownb = nearest_own(surface, s.town, {type = {"assembling-machine", "furnace", "roboport", "container",
                                                         "wall", "gate", "ammo-turret", "radar", "lab"}}, 200)
    local old = surface.count_entities_filtered({position = s.town, radius = 48, force = F, limit = 1}) > 0
      or surface.count_entities_filtered({position = s.town, radius = 96, force = F, type = "radar", limit = 1}) > 0
    util.log("qafix: the old rule (own entity within 48, radar within 96) sees the town: %s", tostring(old))
    s.old_rule = old
    util.log("qafix: town #%s: %d entities of %s within 40 (%d registered buildings); nearest own entity %s %.0f tiles, "
      .. "nearest own building %s %.0f; own land %s tiles away; train: shots %s, reason %s", tostring(s.town_id), #found,
      E, blds, own and own.name or "-", own and own.d or -1, ownb and ownb.name or "-", ownb and ownb.d or -1,
      tostring(land_distance(s.town)), tostring(rec and rec.shots), tostring(rec and rec.war_reason))
    check("arty", rec ~= nil and (rec.shots or 0) > 0 and not s.old_rule,
      "shots %s in 45 s, reason %s, the old rule would see it: %s, town %.0f tiles from the depot",
      tostring(rec and rec.shots), tostring(rec and rec.war_reason), tostring(s.old_rule),
      util.distance(rails.depot(s.depot).entity.position, s.town))
    s.step = "aa"
  elseif s.step == "aa" then
    local cap = s.cap or (capital() and capital().position)
    local surface = game.surfaces[s.surface or 1]
    local p
    local ux, uy = 0, 0
    if s.town then
      local dx, dy = s.town.x - cap.x, s.town.y - cap.y
      local l = math.sqrt(dx * dx + dy * dy)
      ux, uy = dx / l, dy / l
    end
    -- away from the base and its units, with open ground east of it (the far bomber comes from the east): 90 tiles
    -- north or south of the capital, 40 west
    for _, o in ipairs({{-40, -90}, {-40, 90}, {-60, -110}, {-60, 110}, {-80 * ux, -80 * uy}}) do
      local q = {x = math.floor(cap.x + o[1]) + 0.5, y = math.floor(cap.y + o[2]) + 0.5}
      if not p and surface.can_place_entity({name = "rts-aa-turret", position = q, force = F,
          build_check_type = defines.build_check_type.manual_ghost, forced = true}) then p = q end
    end
    local aa = p and surface.create_entity({name = "rts-aa-turret", position = p, force = F, raise_built = true})
    if not aa then
      check("aa_near", false, "no AA site")
      s.step = "end"
      return
    end
    aa.insert({name = "firearm-magazine", count = 20})
    s.aa, s.aa_pos = aa, {x = p.x, y = p.y}
    -- a bomber 11 tiles from the AA
    local b = units.spawn("rts-bomber", {x = p.x + 11, y = p.y}, E)
    s.b1 = b and b.unit_number
    util.log("qafix: AA #%d at %s, bomber #%s spawned 11 tiles away", aa.unit_number, util.pos_str(p), tostring(s.b1))
    s.step = "aa_near"
    s.t = tick + 40 * 60
  elseif s.step == "aa_near" and (tick >= s.t or not s.b1 or s.kills[1]) then
    check("aa_near", s.b1 ~= nil and s.engaged[s.b1] ~= nil, "AA targeted the bomber spawned 11 tiles away: %s; deaths %s",
      tostring(s.b1 and s.engaged[s.b1] and "yes" or "no"), serpent.line(s.kills))
    -- the near bomber goes (alive it would keep the turret busy and its death would count for the far one)
    local nr = s.b1 and units.get(s.b1)
    if nr and nr.entity and nr.entity.valid then nr.entity.destroy() end
    if not (s.aa and s.aa.valid) then -- bombed: a new turret at the same spot
      local surface = game.surfaces[s.surface or 1]
      s.aa = surface.create_entity({name = "rts-aa-turret", position = s.aa_pos, force = F, raise_built = true})
      if not s.aa then
        check("aa_far", false, "no AA turret for the far bomber")
        s.step = "end"
        return
      end
    end
    s.aa.insert({name = "firearm-magazine", count = 20})
    s.aa.health = s.aa.max_health
    -- a bomber 70 tiles away, sent at the AA (the /rts-spawn distance argument)
    local before = {}
    for _, r in units.for_force(E) do before[r.entity.unit_number] = true end
    dbg.run_command("rts-spawn", string.format("rts-bomber 1 %s 70 %.1f %.1f", E, s.aa_pos.x, s.aa_pos.y))
    for _, r in units.for_force(E) do
      if not before[r.entity.unit_number] and r.entity.name == "rts-bomber" then s.b2 = r.entity.unit_number end
    end
    util.log("qafix: bomber #%s spawned 70 tiles from the AA and sent at it", tostring(s.b2))
    s.nk = #s.kills
    s.step = "aa_far"
    s.t = tick + 60 * 60
  elseif s.step == "aa_far" and (tick >= s.t or (s.b2 and not (units.get(s.b2) and units.get(s.b2).entity.valid))) then
    local k
    for _, kk in ipairs(s.kills) do if kk.un == s.b2 then k = kk end end
    check("aa_far", s.b2 ~= nil and s.engaged[s.b2] ~= nil, "AA targeted the far bomber: %s; last death %s",
      tostring(s.b2 and s.engaged[s.b2] and "yes" or "no"), serpent.line(k))
    check("aa_kill", k ~= nil and k.cause == "rts-aa-turret", "the far bomber's death cause: %s",
      tostring(k and k.cause))
    s.step = "end"
  elseif s.step == "end" then
    util.log("qafix summary %d/%d", s.pass, s.pass + s.fail)
    util.log("RTS_QAFIX_DONE")
    s.step = "done"
  end
end)
