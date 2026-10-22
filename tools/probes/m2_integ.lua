-- Phase 5 M2 integration fixture (docs/qa/phase5-m2-integration-notes.md): the integration's own rules, checked on a
-- 1v1 Nation match with victory = "territory" (tools/autotest-run.sh EXTRA_LUA, STOP_ON=RTS_M2_INTEG_DONE):
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m2_integ.lua STOP_ON=RTS_M2_INTEG_DONE SEED=501 tools/autotest-run.sh \
--     m2i-fx '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai",
--     victory = "territory"}' 1200
-- Checks ("[rts] m2 integ check <name>: PASS|FAIL ..."; then "[rts] m2 integ summary P/T" and RTS_M2_INTEG_DONE):
--   upkeep_free      a house and a farm add nothing to the building upkeep, a factory adds 1 cr/min
--   cs_garrison      every city-state starts with 6 garrison turrets
--   cs_armor         a city-state's City Center loses half of a 100-damage hit
--   cs_granary       a captured city-state's network gets its granary (rations)
--   rail_recipe      rts-rail is 1 steel + 1 stone -> 2 rails; the Rail works district is locked before Railways and
--                    unlocked by it in Age I, together with the depot recipe (research.apply reads research.LOCKS)
--   under_attack     a hit on a capital building by the rival marks the capital under attack (cities.under_attack)
--   disband          three walkers with one recruit each: the first press arms, the second removes them and returns
--                    3 residents to the capital
--   qa_commands      /rts-supply sets a division's SP; /rts-diplomacy propose makes a proposal
--   rail_explicit    at war, a stray hit on an enemy rail is undone (it turns indestructible for a while), and an
--                    explicit attack order on that rail destroys it
--   territory_floor  2.5 % against 1 % (a 2.5x lead below the 3 % floor) starts no territory count
--   territory_lead   3.5 % against 1.5 % starts the count, and the match ends in a Territory victory after 3 minutes
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local units = require("scripts.units")
local match = require("scripts.match")
local buildings = require("scripts.buildings")
local cities = require("scripts.cities")
local selection = require("scripts.selection")
local demolish = require("scripts.demolish")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")
local territory = require("scripts.territory")
local world = require("scripts.world")
local treasury = require("scripts.treasury")
local population = require("scripts.population")
local debug_tools = require("scripts.debug")
local orders = require("scripts.orders")
local capture = require("scripts.capture")

local F, E = "rts-player", "rts-ai-1"
local function S()
  storage.m2fx = storage.m2fx or {step = 0, pass = 0, fail = 0, t = 0}
  return storage.m2fx
end

local function check(name, ok, fmt, ...)
  local s = S()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("m2 integ check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

local function finish()
  local s = S()
  util.log("m2 integ summary %d/%d%s", s.pass, s.pass + s.fail, s.fail == 0 and " (all passed)" or " (FAILED)")
  log("RTS_M2_INTEG_DONE")
  s.step = 99
end

local function place(name, near, force)
  local surface = match.surface()
  local pos = surface.find_non_colliding_position(name, near, 40, 1, true) or near
  return surface.create_entity({name = name, position = pos, force = force, raise_built = true})
end

local real_share
local function patch_share(values)
  real_share = real_share or territory.share
  territory.share = function(f)
    if values[f] then return values[f] end
    return 0
  end
end

-- Phase 5 M3 integration: the treasury census runs in 6 slices (m3-age3, treasury.lua): a new building counts in the
-- step after the next full census, up to 1,200 ticks later (the M2 fixture waited 610)
local CENSUS_WAIT = 1210

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

-- 1. start: AI stopped, a factory, a house and a farm placed after a treasury census
step(function(s)
  ai.stop_force(F) ai.stop_force(E)
  s.cap = storage.nations[F].capital
  s.home = cities.get(s.cap).position
  local N = treasury.get(F)
  s.up0 = N.rates and N.rates.buildings or 0
  return CENSUS_WAIT
end)
step(function(s)
  local N = treasury.get(F)
  s.up0 = N.rates.buildings or 0
  local h = s.home
  s.house = place("rts-house", {x = h.x - 30, y = h.y + 20}, F)
  s.farm = place("rts-farm", {x = h.x - 30, y = h.y - 20}, F)
  return CENSUS_WAIT
end)
step(function(s)
  local up1 = treasury.get(F).rates.buildings or 0
  s.factory = place("rts-factory", {x = s.home.x + 30, y = s.home.y + 20}, F)
  s.up1 = up1
  return CENSUS_WAIT
end)
step(function(s)
  local up2 = treasury.get(F).rates.buildings or 0
  local factory_cost = 0.5 -- a factory without a recipe pays the paused share of 1 cr/min
  check("upkeep_free", s.house and s.farm and s.factory and math.abs(s.up1 - s.up0) < 0.01
    and math.abs(up2 - s.up1 - factory_cost) < 0.01,
    "upkeep %.2f -> %.2f after a house and a farm (want +0) -> %.2f after a factory (want +%.2f)", s.up0, s.up1, up2,
    factory_cost)
  -- city-states
  local n, six, live_list = 0, 0, {}
  for _, rec in ipairs(world.city_states()) do
    n = n + 1
    local live = 0
    for _, t in ipairs(rec.turrets or {}) do if t.valid then live = live + 1 end end
    live_list[#live_list + 1] = tostring(live)
    if live >= 6 then six = six + 1 end
  end
  check("cs_garrison", n > 0 and six == n, "%d city-states, live turrets [%s] (want 6 each)", n,
    table.concat(live_list, " "))
  local rec = world.city_states()[1]
  local c = rec and cities.get(rec.city_id)
  local e = c and c.entity
  if e and e.valid then
    local before = e.health
    e.damage(100, E, "physical")
    local lost = before - e.health
    check("cs_armor", lost > 40 and lost < 60, "%s centre lost %.1f of a 100-damage hit (want about 50)",
      rec.label or "-", lost)
  else
    check("cs_armor", false, "no city-state centre")
  end
  -- a city-state captured: its granary goes into its network (capture.flip, then the signal)
  local cs2 = world.city_states()[2]
  s.cs2 = cs2 and cs2.city_id
  if s.cs2 then capture.flip(s.cs2, F, "m2 integ fixture") end
  -- rails
  local force = game.forces[F]
  local r = force.recipes["rts-rail"]
  local steel, stone, rails = 0, 0, 0
  for _, i in pairs(r and r.ingredients or {}) do
    if i.name == "steel-plate" then steel = i.amount elseif i.name == "stone" then stone = i.amount end
  end
  for _, p in pairs(r and r.products or {}) do if p.name == "rail" then rails = p.amount end end
  local works_before = force.recipes["rts-district-rails"] and force.recipes["rts-district-rails"].enabled
  force.technologies["rts-railways"].researched = true
  s.rail = {steel = steel, stone = stone, rails = rails, before = works_before}
  return 60
end)
step(function(s)
  local c2 = s.cs2 and cities.get(s.cs2)
  local net = c2 and c2.entity and c2.entity.valid and c2.entity.logistic_network
  local rations = net and net.valid and net.get_item_count("rts-rations") or -1
  check("cs_granary", c2 ~= nil and c2.force == F and rations >= 150, "city-state city %s captured: owner %s, rations in "
    .. "its network %d (want >= 150)", tostring(s.cs2), c2 and c2.force or "-", rations)
  local force = game.forces[F]
  local works = force.recipes["rts-district-rails"]
  local dra = force.recipes["rts-dra-rail"]
  local depot = force.recipes["rts-depot"]
  local ages = package.loaded["__factorio-rts__/scripts/ages.lua"]
  local age = ages and ages.of(F) or -1
  check("rail_recipe", s.rail.steel == 1 and s.rail.stone == 1 and s.rail.rails == 2 and s.rail.before == false
    and works and works.enabled and dra and dra.enabled and depot and depot.enabled and age == 1,
    "rts-rail %d steel + %d stone -> %d rails; Rail works before Railways %s, after %s (rail recipe %s, depot %s), age %d",
    s.rail.steel, s.rail.stone, s.rail.rails, tostring(s.rail.before), tostring(works and works.enabled),
    tostring(dra and dra.enabled), tostring(depot and depot.enabled), age)
  -- under attack: a hit by the rival on a capital building
  local target
  for _, rec in pairs(storage.buildings) do
    local e = rec.entity
    if e.valid and rec.force == F and rec.kind == "barracks" and territory.city_at(e.position) == s.cap then
      target = e
      break
    end
  end
  local before = cities.under_attack(s.cap) ~= nil
  if target then target.damage(10, E, "physical") end
  local a = cities.under_attack(s.cap)
  check("under_attack", target ~= nil and not before and a ~= nil and a.by == E and a.owner == F,
    "capital %d: under attack before %s, after a hit on %s: %s", s.cap, tostring(before),
    target and target.name or "-", a and string.format("by %s, owner %s", a.by, a.owner) or "nil")
  -- disband: three walkers with one recruit each
  population.remove(s.cap, 10, "m2 integ fixture")
  s.pop0 = population.of(s.cap).pop
  s.walkers = {}
  for i = 1, 3 do
    local e = units.spawn("rts-walker", {x = s.home.x + 10 + i * 2, y = s.home.y + 12}, F)
    if e then
      s.walkers[#s.walkers + 1] = e
      storage.labor.soldiers[e.unit_number] = {city = s.cap, n = 1}
    end
  end
  selection.set(0, s.walkers)
  s.r1 = {demolish.disband(0)}
  return 30
end)
step(function(s)
  local r2 = {demolish.disband(0)}
  local alive = 0
  for _, e in ipairs(s.walkers) do if e.valid then alive = alive + 1 end end
  local pop1 = population.of(s.cap).pop
  check("disband", s.r1[1] == "armed" and r2[1] == "done" and r2[2] == 3 and alive == 0 and math.abs(pop1 - s.pop0 - 3) < 0.01,
    "first press %s %s, second %s %s, %d walkers left, capital residents %.2f -> %.2f (want +3)", tostring(s.r1[1]),
    tostring(s.r1[2]), tostring(r2[1]), tostring(r2[2]), alive, s.pop0, pop1)
  -- QA commands
  local list = {}
  for i = 1, 4 do
    local e = units.spawn("rts-walker", {x = s.home.x - 10 - i * 2, y = s.home.y + 12}, F)
    if e then list[#list + 1] = e end
  end
  local id = divisions.create(F, list)
  debug_tools.run_command("rts-supply", "30")
  local D = id and divisions.get(id)
  diplomacy.set_state(F, E, "war", "m2 integ fixture")
  local before = 0
  for _ in pairs(storage.diplomacy.proposals or {}) do before = before + 1 end
  debug_tools.run_command("rts-diplomacy", "propose rts-ai-1 rts-player peace")
  local found
  for _, P in pairs(storage.diplomacy.proposals or {}) do
    if P.from == E and P.to == F and P.kind == "peace" then found = P end
  end
  check("qa_commands", D ~= nil and D.sp == 30 and found ~= nil, "division %s SP %s (want 30); peace proposal %s",
    tostring(id), tostring(D and D.sp), found and ("#" .. found.id .. " " .. found.status) or "missing")
  -- rails: a stray hit is undone, an explicit attack destroys
  local surface = match.surface()
  local rp = {x = math.floor(s.home.x) + 60, y = math.floor(s.home.y) + 40}
  for _, e in pairs(surface.find_entities_filtered({position = rp, radius = 8, type = {"tree", "simple-entity", "cliff"}})) do
    e.destroy()
  end
  s.rail = surface.create_entity({name = "straight-rail", position = rp, direction = defines.direction.north, force = E})
  if s.rail then
    s.rail.damage(50, F, "physical")
    s.rail_after_stray = s.rail.health
    s.rail_indestructible = not s.rail.destructible
    s.rail_walkers = {}
    for i = 1, 3 do
      local e = units.spawn("rts-walker", {x = rp.x - 6 + i * 2, y = rp.y + 8}, F)
      if e then s.rail_walkers[#s.rail_walkers + 1] = e end
    end
    s.rail_ordered = orders.attack(s.rail_walkers, s.rail)
  end
  return 20 * 60
end)
step(function(s)
  check("rail_explicit", s.rail ~= nil and s.rail_after_stray == 200 and s.rail_indestructible and s.rail_ordered == 3
    and not s.rail.valid,
    "stray hit: health %s, indestructible %s; explicit attack by %s walkers: rail %s after 20 s",
    tostring(s.rail_after_stray), tostring(s.rail_indestructible), tostring(s.rail_ordered),
    s.rail and (s.rail.valid and "standing" or "destroyed") or "missing")
  diplomacy.set_state(F, E, "peace", "m2 integ fixture")
  -- territory: below the floor
  patch_share({[F] = 0.025, [E] = 0.01})
  return 25 * 60
end)
step(function(s)
  local M = storage.war_meta
  check("territory_floor", not (M and M.territory), "2.5 %% against 1 %% for 25 s: territory count %s (want none)",
    M and M.territory and M.territory.key or "none")
  patch_share({[F] = 0.035, [E] = 0.015})
  s.lead_tick = game.tick
  return 20 * 60
end)
step(function(s)
  local M = storage.war_meta
  s.lead_seen = M and M.territory and M.territory.key
  return 60
end)
-- wait for the end (3 minutes after the count started, checked every 10 s)
step(function(s)
  local m = storage.match
  if m.phase ~= "ended" and game.tick - s.lead_tick < 220 * 60 then return 60 end
  local dt = (game.tick - s.lead_tick) / 60
  check("territory_lead", s.lead_seen == F and m.phase == "ended" and m.victory and m.victory.how == "territory"
    and dt >= 180 and dt <= 205,
    "3.5 %% against 1.5 %%: count %s, match %s by %s after %.0f s (want territory after 180-200 s)", tostring(s.lead_seen),
    tostring(m.phase), tostring(m.victory and m.victory.how), dt)
  if real_share then territory.share = real_share end
  finish()
  return nil
end)

events.on_nth_tick(30, function(ev)
  local m = storage.match
  if not (m and m.tick_started) then return end
  local s = S()
  if s.step == 99 then return end
  if s.step == 0 then
    if m.phase ~= "running" or ev.tick - m.tick_started < 60 * 60 then return end
    s.step, s.t = 1, ev.tick
  end
  if ev.tick < s.t then return end
  local fn = STEPS[s.step]
  if not fn then return finish() end
  local wait = fn(s)
  if wait then
    if s.step == #STEPS and wait then
      s.t = ev.tick + wait -- the last step repeats until it finishes
    else
      s.step = s.step + 1
      s.t = ev.tick + wait
    end
  end
end)
