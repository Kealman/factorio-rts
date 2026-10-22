-- Phase 5 E1: the AI's age-up and make targets in Nation mode (docs/PHASE5-M1.md section 2; the full economy planner
-- is M3). ai/commander.lua calls age_up.step(C, surface) on every run while deps.ages.is_nation(); ai/tech.lua puts
-- Industrialisation first in Nation mode. Numbers: balance.nation.economy.ai.
--
--   1. Factories: the commander's own factories (builder, workshops) are "fixed" (it sets their recipes,
--      production.lua); one extra "works" factory, queued works_after seconds in, runs on Auto for the make targets.
--   2. Make targets (every PERIOD): the capital template of the force's age (ai.capital[age]); from the start of the
--      Industrialisation research until Age II, also what the Railway Charter still needs of the goods a factory makes
--      (gears, circuits; steel and stone come from the lines). Other cities of the force (cities.lua) get ai.town.
--   3. The Railway Charter: started on a spot layout.find_spot reserves near the CC once Industrialisation is done,
--      started again when razed.
--   4. Age II: the districts of ai.districts, one every district_gap seconds, near the CC (districts run on Auto).
--      While the next district's item is not made yet, C.nation.saving names it: the barracks make nothing (ai/mix.lua,
--      unless a base threat is fresh) and the works factory has no targets, so the plates gather for it.
-- State: C.nation = {works_key, works_un, districts = {plan keys}, district_at, targets = {[item] = n}, next}.
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local data = require("scripts.ai.orders_data")
local layout = require("scripts.ai.layout")
local construction = require("scripts.ai.construction")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local A = balance.nation.economy.ai
local CHARTER_TECH = balance.nation.economy.charter.tech

local age_up = {}

age_up.PERIOD = 5 * 60
age_up.FACTORY_GOODS = {["iron-gear-wheel"] = true, ["electronic-circuit"] = true}
age_up.CHARTER_CAP = 50 -- at most this much of a Charter good is a make target at once
age_up.DISTRICT_FIRST = {["engine-unit"] = true, ["rts-steel-beam"] = true} -- held back until the first district
age_up.SAVE_MAX = 3 * 60 * 60  -- ticks the AI may save for one district item at a stretch ...
age_up.SAVE_REST = 60 * 60     -- ... then this long without saving
age_up.DISTRICT_RETRY = 60 * 60 -- Phase 5 M2 ai: a district or Bunker without a spot is looked for again after this

-- The builder factory makes the district items for the construction queue (orders_data.FACTORY_RECIPE).
for _, name in ipairs(A.districts) do data.FACTORY_RECIPE[name] = name end
for _, name in ipairs(A.town_districts or {}) do data.FACTORY_RECIPE[name] = name end
-- Phase 5 M1 integration: Age II defence. Once a Smelting works stands (it makes the bricks concrete needs), the AI
-- builds BUNKERS Bunkers towards the enemy; their inputs are make targets until they stand.
age_up.BUNKERS = 2
age_up.BUNKER_TARGETS = {["stone-brick"] = 20, concrete = 40, ["rts-steel-beam"] = 16}
data.FACTORY_RECIPE["rts-bunker"] = "rts-bunker"
-- the plate a mining town's ore becomes in the capital's Smelting works (a target keeps the works on that recipe);
-- once the capital's warehouse stands (WAREHOUSE stockpiles, from WAREHOUSE_AFTER districts on) the target and the
-- capital's ore keep rise to the stored values: the Smelting works then run while ore comes (the capital of a copper
-- town held more copper plates than its target, so its trains stopped), and the town's ore is stored as plates
age_up.TOWN_PLATE = {["iron-ore"] = {"iron-plate", 2000, 20000}, ["copper-ore"] = {"copper-plate", 2000, 20000}}
age_up.WAREHOUSE, age_up.WAREHOUSE_AFTER = 6, 3
age_up.ORE_KEEP_STORED = 6000

local function plan_entity(C, key)
  local e = key and C.plan[key]
  if e and e.status == "built" and e.entity and e.entity.valid then return e.entity end
  return nil
end

local function queue_building(C, surface, name)
  local pos, pole, wait = layout.find_spot(C, surface, name, "cc")
  if not pos then return nil, wait end -- (wait: Phase 5 M3 ai (perf), a planning job looks for the spot)
  if pole then construction.queue(C, construction.add(C, {name = layout.POLE, x = pole.x, y = pole.y})) end
  local key = construction.add(C, {name = name, x = pos.x, y = pos.y})
  construction.queue(C, key)
  util.log("ai %s: age-up: %s queued at %s (t=%ds)", C.force, name, util.pos_str(pos), (game.tick - C.started) / 60)
  return key
end

-- Factory modes: own factories fixed, the works factory on Auto.
local function factory_modes(C, N)
  if N.works_un and not buildings.get(N.works_un) then N.works_un = nil end
  if N.works_key and not N.works_un then
    local e = plan_entity(C, N.works_key)
    if e then N.works_un = e.unit_number end
  end
  for un, rec in buildings.for_force(C.force, "factory") do
    if un == N.works_un then
      if rec.recipe_mode ~= "auto" then production.set_auto(rec, true) end
    elseif rec.recipe_mode == nil then
      rec.recipe_mode = "fixed"
    end
  end
end

local function set_targets(C, N, city, want)
  local districts = deps.districts
  N.targets = N.targets or {}
  local cur = districts.make_targets(city)
  for item, n in pairs(want) do
    if cur[item] ~= n then districts.set_make_target(city, item, n) end
  end
  for item in pairs(N.targets) do
    if not want[item] and cur[item] then districts.set_make_target(city, item, nil) end
  end
  N.targets = want
end

local function capital_city(C)
  local cc = buildings.main_cc(C.force)
  return cc and deps.districts.city_of(cc.entity)
end

--- One pass (ai/commander.lua, every commander run in Nation mode).
function age_up.step(C, surface)
  local ages, districts = deps.ages, deps.districts
  if not (ages and districts and ages.is_nation()) then return end
  local N = C.nation
  if not N then
    N = {districts = {}}
    C.nation = N
  end
  factory_modes(C, N)
  if game.tick < (N.next or 0) then return end
  N.next = game.tick + age_up.PERIOD
  local secs = (game.tick - C.started) / 60
  local age = ages.of(C.force)

  -- 0. saving for the next district: while its item is not made, the barracks (ai/mix.lua) and the works factory
  --    pause, so its 80 plates, steel and circuits gather in the network (they never did between unit kits)
  --    Safety valve: at most SAVE_MAX at a time, then SAVE_REST without (a stuck item must not stop the army for good)
  N.saving = nil
  -- Phase 5 M1 integration: while the rail line to the mining town waits for its depots, kits and rails (paid from the
  -- capital's plates, which an aggressive AI's barracks never left: its line waited 20 minutes for kits), the barracks
  -- save too (C.nation.saving_rail, ai/mix.lua); make targets go on (the Charter needs them)
  N.saving_rail = nil
  local rail_state = deps.rails and deps.rails.ai_program_state and deps.rails.ai_program_state(C.force)
  if C.town and (rail_state == "depots" or rail_state == "building") then
    N.rail_save_since = N.rail_save_since or game.tick
    if game.tick - N.rail_save_since <= age_up.SAVE_MAX then
      N.saving_rail, N.saving_tick = true, game.tick
    elseif game.tick - N.rail_save_since > age_up.SAVE_MAX + age_up.SAVE_REST then
      N.rail_save_since = game.tick
    end
  else
    N.rail_save_since = nil
  end
  for _, key in ipairs(N.districts) do
    local e = C.plan[key]
    if e and e.status ~= "built" and e.status ~= "bad" then
      if construction.have(C, e.item) < 1 then
        N.save_since = N.save_since or game.tick
        if game.tick - N.save_since <= age_up.SAVE_MAX then
          N.saving, N.saving_tick = e.item, game.tick
        elseif game.tick - N.save_since > age_up.SAVE_MAX + age_up.SAVE_REST then
          N.save_since = game.tick
        end
      else
        N.save_since = nil
      end
      break
    end
  end

  -- 1. the works factory
  if not N.works_key and secs >= A.works_after then N.works_key = queue_building(C, surface, "rts-factory") end

  -- 2. make targets
  local city = capital_city(C)
  if city then
    local want = {}
    for item, n in pairs(A.capital[age] or {}) do want[item] = n end
    -- Age II: the first district before the car's engines and beams (their steel would starve the district item);
    -- nothing while saving for a district item
    if age >= 2 and #N.districts > 0 and not plan_entity(C, N.districts[1]) then
      for item in pairs(age_up.DISTRICT_FIRST) do want[item] = nil end
    end
    -- Phase 5 M1 integration: the town's ore is smelted in the capital (the plate target keeps the Smelting works on
    -- it) and the Bunkers' inputs while they are due
    if age >= 2 then
      local tp = C.town and C.town.status == "ok" and age_up.TOWN_PLATE[C.town.ore]
      if tp then want[tp[1]] = math.max(want[tp[1]] or 0, N.warehouse_ready and tp[3] or tp[2]) end
      if N.bunker_due then
        for item, n in pairs(age_up.BUNKER_TARGETS) do want[item] = math.max(want[item] or 0, n) end
      end
    end
    -- Phase 5 M3 ai: the planner's targets (the industrial kit's parts in Age II, the Space Program stage's goods, plastic
    -- and sulfur once crude oil comes in); the larger number wins
    local P = deps.planner and deps.planner.targets and deps.planner.targets(C)
    for item, n in pairs(P or {}) do want[item] = math.max(want[item] or 0, n) end
    local K = deps.council and deps.council.targets and deps.council.targets(C) -- the airfield's concrete
    for item, n in pairs(K or {}) do want[item] = math.max(want[item] or 0, n) end
    if N.saving then want = {} end
    -- Phase 5 M2 ai: the bakery first (ai/governor.lua), the copper line's own parts first (ai/build_order.lua)
    if (C.gov and C.gov.food_emergency) or C.boot then want = {} end
    local p = ages.project(C.force)
    -- the Charter's goods once Industrialisation is under way (earlier, the stockpile took plates from the army)
    local force = game.forces[C.force]
    local cur = force and force.current_research
    local soon = p ~= nil or (deps.research and deps.research.has(C.force, CHARTER_TECH))
      or (cur ~= nil and cur.name == CHARTER_TECH)
    if age < 2 and soon then
      for item, n in pairs(ages.required()) do
        local left = n - ((p and p.delivered[item]) or 0)
        if left > 0 and age_up.FACTORY_GOODS[item] then
          want[item] = math.max(want[item] or 0, math.min(left, age_up.CHARTER_CAP))
        end
      end
    end
    set_targets(C, N, city, want)
    if A.town then
      for _, c in ipairs(districts.cities(C.force)) do
        if c.id ~= city then
          local cur = districts.make_targets(c.id)
          for item, n in pairs(A.town) do
            if cur[item] ~= n then districts.set_make_target(c.id, item, n) end
          end
        end
      end
    end
  end

  -- 3. the Railway Charter
  if age < 2 and ages.can_start(C.force) then
    local pos, _, wait = layout.find_spot(C, surface, ages.SITE, "cc")
    if not wait then -- Phase 5 M3 ai (perf): a planning job looks for the site: a later pass starts the project
      local p, why = ages.start_project(C.force, pos)
      util.log("ai %s: age-up: Railway Charter %s at %s (t=%ds)", C.force, p and "started" or ("refused: " .. tostring(why)),
        util.pos_str(pos), secs)
    end
  end

  -- 6. The warehouse (Phase 5 M1 integration): with a mining town, WAREHOUSE stockpiles in the capital's network
  if age >= 2 and C.town and C.town.status == "ok" then
    N.warehouse = N.warehouse or {}
    local built = 0
    for _, key in ipairs(N.warehouse) do
      if plan_entity(C, key) then built = built + 1 end
    end
    local districts_built = 0
    for _, key in ipairs(N.districts) do
      if plan_entity(C, key) then districts_built = districts_built + 1 end
    end
    if #N.warehouse < age_up.WAREHOUSE and districts_built >= age_up.WAREHOUSE_AFTER
       and game.tick >= (N.warehouse_retry or 0) then
      local key, wait = queue_building(C, surface, "rts-stockpile")
      if key then
        N.warehouse[#N.warehouse + 1] = key
      elseif not wait then -- (Phase 5 M3 ai (perf): a planning job looks for the spot: no retry delay)
        N.warehouse_retry = game.tick + age_up.DISTRICT_RETRY
      end
    end
    if not N.warehouse_ready and built >= math.ceil(age_up.WAREHOUSE * 2 / 3) then
      N.warehouse_ready = true
      local cc = buildings.main_cc(C.force)
      local tp = age_up.TOWN_PLATE[C.town.ore]
      if cc and deps.logistics then
        deps.logistics.set_policy(cc.entity.unit_number, "keep", C.town.ore, age_up.ORE_KEEP_STORED)
        -- the town's plates too (copper piles up in the capital, so its train stopped at the depot's 3000)
        if tp then deps.logistics.set_policy(cc.entity.unit_number, "keep", tp[1], tp[3]) end
      end
      util.log("ai %s: age-up: warehouse ready (%d stockpiles): the capital keeps %d %s", C.force, built,
        age_up.ORE_KEEP_STORED, C.town.ore)
    end
  end

  -- 5. Bunkers (Phase 5 M1 integration): once a Smelting works stands, BUNKERS at the front, one at a time
  if age >= 2 then
    local smelting = false
    for _, rec in buildings.for_force(C.force, "district") do
      if rec.entity.valid and rec.entity.name == "rts-district-smelting" then smelting = true end
    end
    N.bunkers = N.bunkers or {}
    local built, pending = 0, false
    for _, key in ipairs(N.bunkers) do
      local e = C.plan[key]
      if plan_entity(C, key) then built = built + 1 elseif e and e.status ~= "bad" then pending = true end
    end
    N.bunker_due = smelting and built < age_up.BUNKERS or nil
    if N.bunker_due and not pending and #N.bunkers < age_up.BUNKERS + 2 and game.tick >= (N.bunker_retry or 0) then
      local pos, pole, wait = layout.find_spot(C, surface, "rts-bunker", "front") -- (wait: Phase 5 M3 ai perf)
      if not pos and not wait then N.bunker_retry = game.tick + age_up.DISTRICT_RETRY end -- Phase 5 M2 ai: no search every 5 s
      if pos then
        if pole then construction.queue(C, construction.add(C, {name = layout.POLE, x = pole.x, y = pole.y})) end
        local key = construction.add(C, {name = "rts-bunker", x = pos.x, y = pos.y})
        construction.queue(C, key)
        N.bunkers[#N.bunkers + 1] = key
        util.log("ai %s: age-up: rts-bunker queued at %s (t=%ds)", C.force, util.pos_str(pos), secs)
      end
    end
  end

  -- 4. districts in Age II
  if age >= 2 then
    -- Phase 5 M1 integration: a force whose mining town ships ore builds a Smelting works too (balance town_districts)
    local list = (C.town and C.town.status == "ok" and A.town_districts) or A.districts
    -- the names still to queue (built from the list once; a town that comes later appends its extra districts)
    N.district_todo = N.district_todo or {}
    N.district_seen = N.district_seen or 0
    if #list > N.district_seen then
      for i = N.district_seen + 1, #list do N.district_todo[#N.district_todo + 1] = list[i] end
      N.district_seen = #list
    end
    -- Phase 5 M3 ai: the planner's districts (the oil chain once crude comes in, the Age III districts), each once
    N.planner_districts = N.planner_districts or {}
    local seen = {}
    for _, name in ipairs(deps.planner and deps.planner.districts and deps.planner.districts(C) or {}) do
      seen[name] = (seen[name] or 0) + 1
      local k = name .. "#" .. seen[name]
      if not N.planner_districts[k] then
        N.planner_districts[k] = true
        -- right after the first district (the Steel works): the Age III road's districts come before the town's
        -- Smelting works and the Rail works (8 minutes later at the list's end)
        N.planner_insert = math.max(N.planner_insert or 0, (#N.districts == 0) and 2 or 1)
        local at = math.min(N.planner_insert, #N.district_todo + 1)
        table.insert(N.district_todo, at, name)
        N.planner_insert = at + 1
        util.log("ai %s: age-up: %s added to the district list at %d (planner)", C.force, name, at)
      end
    end
    -- the Rail works first while the rail line still waits for rails (2 rails per steel instead of 1)
    if rail_state == "building" or rail_state == "depots" then
      for i, n in ipairs(N.district_todo) do
        if n == "rts-district-rails" and i > 1 then
          table.remove(N.district_todo, i)
          table.insert(N.district_todo, 1, n)
          break
        end
      end
    end
    -- Phase 5 M2 ai: the first district whose recipe the force has (the Rail works now unlocks with Railways, an Age I
    -- technology: a locked one stayed first and the builder asked for its item 600 times); a district without a spot
    -- is looked for again after DISTRICT_RETRY (the full search every 5 s cost up to 0.15 ms per tick)
    local idx, name
    local frec = game.forces[C.force].recipes
    for i, n in ipairs(N.district_todo) do
      if not frec[n] or frec[n].enabled then idx, name = i, n break end
    end
    if name and game.tick >= (N.district_at or 0) then
      local key, wait = queue_building(C, surface, name)
      if key then
        table.remove(N.district_todo, idx)
        N.districts[#N.districts + 1] = key
        N.district_at = game.tick + A.district_gap * 60
      elseif not wait then -- (Phase 5 M3 ai (perf): a planning job looks for the spot: no retry delay)
        N.district_at = game.tick + age_up.DISTRICT_RETRY
      end
    end
  end
end

--- "works #N auto, districts 2/3 built, targets [...]" (ai dump, autotest minute line).
function age_up.describe(C)
  local N = C.nation
  if not N then return "-" end
  local built = 0
  for _, key in ipairs(N.districts) do
    if plan_entity(C, key) then built = built + 1 end
  end
  local t = {}
  for item, n in pairs(N.targets or {}) do t[#t + 1] = string.format("%s=%d", item, n) end
  table.sort(t)
  local bunkers = 0
  for _, key in ipairs(N.bunkers or {}) do
    if plan_entity(C, key) then bunkers = bunkers + 1 end
  end
  return string.format("works %s, districts %d/%d built, bunkers %d, targets [%s]", N.works_un and ("#" .. N.works_un)
    or "-", built, #N.districts, bunkers, table.concat(t, " "))
end

return age_up
