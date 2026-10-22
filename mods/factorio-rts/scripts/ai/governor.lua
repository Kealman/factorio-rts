-- Phase 5 M2 ai (docs/PHASE5-M2.md §3 "ai/nation.lua / ai/governor.lua", D9): the city governor of an AI nation.
-- Nation mode only; ai/commander.lua calls governor.step(C, surface) on every run and each own city gets a pass every
-- PERIOD ticks (staggered by city id). It takes over the people rules of population.ai_step (m2-people's first
-- governor, docs/qa/phase5-people-notes.md §3.5) and generalises them per city and archetype:
--
--   every city   needs keeps (rations and goods for keep_minutes of need), the doctrine's draft (once), a house while
--                its housing is short (free housing before start_after, then the residents its jobs need plus a margin)
--   capital      labor priorities, pins (builder, workshop and works factories, the first lab), goods and
--                brick make targets for the whole nation (its own keep, every other city's keep and a margin it ships),
--                the first farm when the rations run out within food_minutes and then one per farm_per residents (a
--                bakery per bakery_farms farms), the goods works when the goods run out within goods_minutes, a second
--                goods works when a town stalls at its goods need, a supply hauler to every other city
--   town         extraction first (its extractors and smelters are pinned), defence (town_turrets gun turrets towards
--                the nearest rival, magazines kept), an export route for its surplus: a hauler takes the town's ore and
--                plates to the nation's port while the trains do not keep up; crates are warsupply.lua's
--   relief       damage on a town's land is reported to ai/army.lua (army.town_threat): a relief group goes there
--
-- Iron for the steel chain first: until the capital's steel flows (or Age II) the town's houses and turrets wait, the
-- goods works waits unless the goods are nearly out, and the towns' supply haulers wait unless a town runs short of
-- rations (ai/towns.lua holds the town's mining line back the same way). Nothing that costs copper (bakery, goods
-- works, turrets) is queued while the start copper line does not run (ai/build_order.lua bootstrap; the wave A
-- regression of seeds 402-404 and 611).
--
-- State: C.gov = {cities = {[city_id] = {next, houses = {keys}, turrets = {keys}, pins = {[un] = true}, stall_since,
--   route}}, farms = {keys}, bakeries = {keys}, goods = {keys}, haulers = {[city_id] = un}, pins = {[un] = true},
--   draft = {[city_id] = true}, priorities, house_at}. Log lines "[rts] ai <force>: governor ...".
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local layout = require("scripts.ai.layout")
local construction = require("scripts.ai.construction")
local build_order = require("scripts.ai.build_order")
local data = require("scripts.ai.orders_data")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local governor = {}

local PB = balance.nation.people
local AI = PB.ai
local WAI = balance.nation.war.ai

governor.PERIOD = AI.period or 300

-- Modules that load after the AI (control.lua order): looked up at run time.
local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function nation()
  return deps.ages ~= nil and deps.ages.is_nation()
end

-- The governor's people buildings are made by the builder factory for the construction queue.
for name in pairs(PB.buildings or {}) do data.FACTORY_RECIPE[name] = name end
construction.SMALL["rts-house"] = true -- houses are small jobs (batched like belts)

local RATIONS, GOODS = "rts-rations", "rts-goods"
local NEEDS = {{item = RATIONS, keep = PB.needs and PB.needs[RATIONS] and PB.needs[RATIONS].keep or 50},
               {item = GOODS, keep = PB.needs and PB.needs[GOODS] and PB.needs[GOODS].keep or 20}}

---------------------------------------------------------------------------
-- Plan helpers
---------------------------------------------------------------------------
local function plan_state(C, key)
  local e = key and C.plan[key]
  if not e then return "gone" end
  if e.status == "built" then return (e.entity and e.entity.valid) and "built" or "gone" end
  if e.status == "bad" then return "gone" end
  return "pending"
end
governor.plan_state = plan_state

-- Built and pending entries of a key list (the gone ones dropped from the returned list).
local function count_keys(C, keys)
  local built, pending, keep = 0, 0, {}
  for _, key in ipairs(keys or {}) do
    local st = plan_state(C, key)
    if st == "built" then built = built + 1 elseif st == "pending" then pending = pending + 1 end
    if st ~= "gone" then keep[#keep + 1] = key end
  end
  return built, pending, keep
end

-- Queue a plan entry at the front of the construction queue (cheap people buildings: nothing grows without them).
local function queue_first(C, key)
  if not construction.queue(C, key) then return end
  local q = C.queue
  if q[#q] == key then
    table.remove(q)
    table.insert(q, 1, key)
  end
end

local function queue_near_cc(C, surface, name)
  local pos, pole = layout.find_spot(C, surface, name, "cc")
  if not pos then return nil end
  if pole then queue_first(C, construction.add(C, {name = layout.POLE, x = pole.x, y = pole.y})) end
  local key = construction.add(C, {name = name, x = pos.x, y = pos.y})
  queue_first(C, key)
  return key, pos
end

-- A spot for an unpowered building on city c's land within `radii` tiles (growing rings) near `pref`.
local function queue_near(C, surface, name, c, pref, radii, front)
  local population, territory = mod("population"), deps.territory
  local cx, cy = math.floor(c.position.x), math.floor(c.position.y)
  for _, r in ipairs(radii) do
    local pos, _, wait = layout.find_spot_in(C, surface, name, cx - r, cy - r, cx + r, cy + r, pref)
    if wait then return nil end -- Phase 5 M3 ai (perf): a planning job looks (this ring is asked again next pass)
    if pos then
      local own = (not population) or population.city_at(pos) == c.id
      if own and (not territory or territory.can_build(C.force, name, pos)) then
        local key = construction.add(C, {name = name, x = pos.x, y = pos.y})
        if front then queue_first(C, key) else construction.queue(C, key) end
        return key, pos
      end
    end
  end
  return nil
end

local function set_target(city_id, item, n)
  local districts = deps.districts
  if not districts then return end
  local cur = districts.make_targets(city_id)
  if cur[item] ~= n then districts.set_make_target(city_id, item, n) end
end

local function net_count(c, item)
  local e = c.entity
  local net = e and e.valid and e.logistic_network
  return (net and net.valid) and net.get_item_count(item) or 0
end
governor.net_count = net_count

-- The copper line runs (or the force has none): copper-costing people and defence buildings may be queued.
local function copper_ok(C)
  return build_order.line_running(C, "copper")
end

-- The capital's steel flows (or Age II): until then the town's houses and turrets, the goods works (unless the goods
-- are nearly out) and the towns' supply haulers wait, like the town's mining line (ai/towns.lua). On seed 402 they took
-- some 300 iron in minutes 6-10 from the aggressive AI's iron smelters and its steel came 7 minutes late.
local function steel_ready(C)
  return (deps.ages and deps.ages.of(C.force) >= 2) or construction.flowing(C, "steel-plate")
end

-- The rail line is being built and stone runs low: houses (15 stone each) wait (seed 703: the houses took the stone the
-- rails needed, 1 steel + 1 stone per 2 rails, and a line stood at 143 of 166 pieces for 30 minutes).
local function rails_need_stone(C)
  local R = deps.rails
  local st = R and R.ai_program_state and R.ai_program_state(C.force)
  return (st == "building" or st == "depots") and construction.have(C, "stone") < (AI.rail_stone or 150)
end

-- In Age I while Industrialisation is researched or the Railway Charter is built.
local CHARTER_TECH = balance.nation.economy.charter.tech
local function age2_road(C)
  local ages = deps.ages
  if not ages or ages.of(C.force) >= 2 then return false end
  if ages.project and ages.project(C.force) then return true end
  local force = game.forces[C.force]
  local cur = force and force.current_research
  return cur ~= nil and cur.name == CHARTER_TECH
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function G_of(C)
  local G = C.gov
  if not G then
    G = {cities = {}, farms = {}, bakeries = {}, goods = {}, haulers = {}, pins = {}, draft = {}, house_at = 0}
    C.gov = G
  end
  return G
end

local function city_state(G, c)
  local S = G.cities[c.id]
  if not S then
    S = {next = game.tick + (c.id * 37) % governor.PERIOD, houses = {}, turrets = {}, pins = {}}
    G.cities[c.id] = S
  end
  return S
end

local function match_age()
  local m = storage.match
  return (m and m.tick_started) and (game.tick - m.tick_started) or 0
end

---------------------------------------------------------------------------
-- Nation-wide parts (run with the capital's pass)
---------------------------------------------------------------------------
-- Labor priorities and pins: the builder and workshop factories (the two lowest fixed ones), the age-up works factory
-- (Auto), the first pin_labs labs. The goods works are not pinned (services: after research and the army).
local function capital_labor(C, G, labor)
  if not G.priorities then
    labor.set_priorities(C.force, AI.priorities)
    G.priorities = true
  end
  -- Phase 5 M3 ai: from Age II the Age III road's families (electronics, chemistry: the advanced circuits, plastic and
  -- sulfur of the industrial kits and the Space Program) come before the army and services (last in the M2 order, their
  -- districts stood idle without workers while crude oil piled up)
  if AI.priorities_age2 and G.priorities ~= "age2" and deps.ages and deps.ages.of(C.force) >= 2 then
    labor.set_priorities(C.force, AI.priorities_age2)
    G.priorities = "age2"
    util.log("ai %s: governor: Age II labor priorities [%s]", C.force, table.concat(AI.priorities_age2, " "))
  end
  local want, factories, labs = {}, {}, {}
  for un, rec in buildings.for_force(C.force, "factory") do factories[#factories + 1] = {un, rec} end
  table.sort(factories, function(a, b) return a[1] < b[1] end)
  local fixed = 0
  local works = C.nation and C.nation.works_un
  for _, f in ipairs(factories) do
    if f[2].recipe_mode == "auto" then
      if f[1] == works then want[f[1]] = f[2] end
    elseif fixed < 2 then
      fixed = fixed + 1
      want[f[1]] = f[2]
    end
  end
  for un, rec in buildings.for_force(C.force, "lab") do labs[#labs + 1] = {un, rec} end
  table.sort(labs, function(a, b) return a[1] < b[1] end)
  for i = 1, math.min(AI.pin_labs, #labs) do want[labs[i][1]] = labs[i][2] end
  for un in pairs(G.pins) do
    if not want[un] then
      local rec = buildings.get(un)
      if rec then labor.pin(rec.entity, false) end
      G.pins[un] = nil
    end
  end
  for un, rec in pairs(want) do
    if not G.pins[un] then
      labor.pin(rec.entity, true)
      G.pins[un] = true
    end
  end
end

-- Farms and bakeries at the capital, by forecast: when the nation's rations run out within food_minutes.
local function food(C, G, surface, capital, total, rations_need)
  local queued = false
  local farms_built, farms_pending, bakeries_built, bakeries_pending
  farms_built, farms_pending, G.farms = count_keys(C, G.farms)
  bakeries_built, bakeries_pending, G.bakeries = count_keys(C, G.bakeries)
  local slots = PB.farm_slots[capital.tier] or PB.farm_slots[1]
  local farms_want = math.min(slots, math.max(1, math.ceil(total / AI.farm_per)))
  local bakeries_want = math.max(1, math.ceil(farms_want / AI.bakery_farms))
  local stock = net_count(capital, RATIONS)
  -- the first farm only when the rations run out within food_minutes (the start stock lasts 12-15 minutes, a farm and a
  -- bakery feed about 225 residents: iron for farms in minutes 5-8 delayed the AI's Age II), then one per farm_per
  -- residents of the nation (by forecast alone the capital's stock hovered at its keep and a town starved for 4 minutes)
  local due = farms_built + farms_pending > 0 or stock < (AI.food_minutes or 8) * rations_need
  if due and farms_built + farms_pending < farms_want and farms_pending == 0 then
    local key = queue_near_cc(C, surface, "rts-farm")
    if key then
      G.farms[#G.farms + 1] = key
      queued = true
      util.log("ai %s: governor: farm %d of %d queued (%d residents, %d rations at the capital)", C.force,
        farms_built + farms_pending + 1, farms_want, math.floor(total), stock)
    end
  end
  -- (the first bakery goes with the first farm: grain without a bakery fed nobody)
  if (not queued or bakeries_built + bakeries_pending == 0) and bakeries_built + bakeries_pending < bakeries_want
     and bakeries_pending == 0 and farms_built + farms_pending > 0 and copper_ok(C) then
    local key = queue_near_cc(C, surface, "rts-bakery")
    if key then
      G.bakeries[#G.bakeries + 1] = key
      queued = true
      util.log("ai %s: governor: bakery %d of %d queued", C.force, bakeries_built + 1, bakeries_want)
    end
  end
  -- food first: while no bakery stands and the rations last less than food_urgent minutes, the capital's goods and the
  -- age-up make targets pause (ai/age_up.lua reads C.gov.food_emergency) so that copper and iron reach the bakery (seed
  -- 704: the Auto factories took every copper plate, the bakery never came and the capital starved for 11 minutes)
  local emergency = bakeries_built == 0 and stock < (AI.food_urgent or 3) * rations_need
  if emergency ~= (G.food_emergency == true) then
    G.food_emergency = emergency or nil
    util.log("ai %s: governor: food emergency %s (%d rations, no bakery)", C.force, emergency and "on" or "off", stock)
  end
  return queued
end

-- Goods works at the capital: Auto factories for the goods and brick targets. The first one when the goods run out
-- within goods_minutes; one more (at most AI.goods_works_max) when a town stalls at its goods need while the capital
-- has none to ship.
local function goods_works(C, G, surface, capital, goods_need, want_more)
  local built, pending
  built, pending, G.goods = count_keys(C, G.goods)
  for i, key in ipairs(G.goods) do
    if plan_state(C, key) == "built" then
      local e = C.plan[key].entity
      local rec = e and buildings.get(e.unit_number)
      -- Phase 5 M3 ai: a skilled governor's second and further works make goods only (in auto mode they made the
      -- capital's other targets and its goods stayed at 0 % with three works)
      if rec and C.cfg and C.cfg.goods_per_works and i > 1 then
        local r = e.get_recipe()
        if rec.recipe_mode ~= "fixed" or not r or r.name ~= GOODS then
          production.set_auto(rec, false)
          production.set_recipe(e, GOODS)
        end
      elseif rec and rec.recipe_mode ~= "auto" then
        production.set_auto(rec, true)
      end
    end
  end
  if pending > 0 or not copper_ok(C) then return false end
  local stock = net_count(capital, GOODS)
  if not steel_ready(C) and stock >= (AI.goods_urgent or 2) * goods_need then return false end
  local want = 0
  if goods_need > 0 and (built > 0 or stock < (AI.goods_minutes or 8) * goods_need) then want = 1 end
  if want_more then want = math.min(AI.goods_works_max or 2, built + 1) end
  -- Phase 5 M3 ai: a skilled governor (balance.nation.ai3.difficulty[level].goods_per_works, set on C.cfg) plans one
  -- works per that much goods need a minute, up to goods_works_cap (1v1 runs: hard's capital at 0 % goods and 70 %
  -- happiness stopped growing at 800 residents while the normal AI imported its goods)
  local per = C.cfg and C.cfg.goods_per_works
  if per and goods_need > 0 then
    want = math.max(want, math.min(C.cfg.goods_works_cap or 4, math.ceil(goods_need / per)))
  end
  if built >= want then return false end
  local pos, pole = layout.find_spot(C, surface, "rts-factory", "cc")
  if not pos then return false end
  if pole then construction.queue(C, construction.add(C, {name = layout.POLE, x = pole.x, y = pole.y})) end
  local key = construction.add(C, {name = "rts-factory", x = pos.x, y = pos.y})
  construction.queue(C, key) -- in queue order: goods only feed growth, the build order's iron comes first
  G.goods[#G.goods + 1] = key
  util.log("ai %s: governor: goods works %d queued (%s)", C.force, built + 1,
    want_more and "a town stalls at its goods need" or "goods run low")
  return true
end

-- A supply hauler from the capital to every other city (an auto hauler switched to the route).
local function supply_haulers(C, G, capital, list)
  local L = deps.logistics
  if not L then return end
  if not steel_ready(C) then
    local population = mod("population")
    local short = false
    for _, c in ipairs(list) do
      if c.id ~= capital.id and population then
        local need = (population.needs(c.id)[RATIONS] or 0)
        if net_count(c, RATIONS) < (AI.town_rations_minutes or 4) * need then short = true end
      end
    end
    if not short then
      C.people_haulers = 0
      return
    end
  end
  C.people_haulers = math.max(0, #list - 1)
  local cc_un = capital.center
  local taken = {}
  for _, un in pairs(G.haulers) do taken[un] = true end
  for _, S in pairs(G.cities) do if S.route then taken[S.route] = true end end
  for _, c in ipairs(list) do
    if c.id ~= capital.id then
      local hun = G.haulers[c.id]
      local h = hun and L.hauler(hun)
      if not (h and h.mode == "manual" and h.pickup == cc_un and h.dropoff == c.center) then
        G.haulers[c.id] = nil
        if hun then taken[hun] = nil end
        for un, hh in L.haulers_of(C.force) do
          if hh.mode == "auto" and not taken[un] then
            L.set_pickup(un, cc_un)
            L.set_dropoff(un, c.center)
            G.haulers[c.id] = un
            taken[un] = true
            util.log("ai %s: governor: hauler #%d supplies city %d from the capital", C.force, un, c.id)
            break
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Town parts
---------------------------------------------------------------------------
-- The nearest rival capital (for the side the defence faces).
local function threat_side(C, c)
  local best, bd
  for _, f in ipairs(storage.match and storage.match.forces or {}) do
    if f ~= C.force then
      local nat = storage.nations and storage.nations[f]
      local cap = nat and storage.cities and storage.cities[nat.capital]
      local pos = cap and cap.position or (storage.match.spawns and storage.match.spawns[f])
      if pos then
        local d = util.distance(pos, c.position)
        if not bd or d < bd then best, bd = pos, d end
      end
    end
  end
  return best
end

-- Gun turrets at a town, towards the nearest rival, as soon as its City Center stands; magazines kept there.
local function town_defence(C, S, surface, c)
  local want = WAI.town_turrets or 0
  if want <= 0 then return false end
  local built, pending
  built, pending, S.turrets = count_keys(C, S.turrets)
  local L = deps.logistics
  if built > 0 and L then
    local pol = L.policy(c.center)
    if pol and pol.keep["firearm-magazine"] ~= WAI.town_magazines then
      L.set_policy(c.center, "keep", "firearm-magazine", WAI.town_magazines)
    end
  end
  if built + pending >= want or not copper_ok(C) or not steel_ready(C) then return false end
  local toward = threat_side(C, c) or {x = c.position.x + 30, y = c.position.y}
  local dx, dy = toward.x - c.position.x, toward.y - c.position.y
  local len = math.max(1, math.sqrt(dx * dx + dy * dy))
  local side = (built + pending) % 2 == 0 and 1 or -1
  -- inside the City Center's logistic area (radius 16): production.lua feeds the turrets from the town's network
  local pref = {x = c.position.x + 11 * dx / len - side * 5 * dy / len,
                y = c.position.y + 11 * dy / len + side * 5 * dx / len}
  local key = queue_near(C, surface, "rts-turret", c, pref, {AI.town_area or 13}, false)
  if not key then return false end
  S.turrets[#S.turrets + 1] = key
  util.log("ai %s: governor: town %d turret %d of %d queued at %s", C.force, c.id, built + pending + 1, want,
    util.pos_str({C.plan[key].x, C.plan[key].y}))
  return true
end

-- Storage: a town or captured city whose City Center lost its stockpiles (razed in the fight for it) can store nothing:
-- the bakery's rations and the supply hauler's load had nowhere to go and a captured city-state stood at 0 % rations
-- for 8 minutes (seed 703). Its two stockpiles are queued again at the hub offsets (logistics.HUB_STOCKPILES).
local function town_storage(C, S, surface, c)
  local e = c.entity
  if not (e and e.valid) or game.tick < (S.storage_at or 0) then return false end
  S.storage_at = game.tick + 30 * 60
  local n = surface.count_entities_filtered({name = "rts-stockpile", position = e.position, radius = 7, force = C.force})
  if n >= 2 then return false end
  local L = deps.logistics
  local queued = false
  for _, off in ipairs(L and L.HUB_STOCKPILES or {}) do
    local x, y = e.position.x + off.x, e.position.y + off.y
    if surface.count_entities_filtered({name = "rts-stockpile", position = {x, y}, radius = 0.6}) == 0 then
      local key = construction.add(C, {name = "rts-stockpile", x = x, y = y})
      queue_first(C, key)
      queued = true
    end
  end
  if queued then util.log("ai %s: governor: city %d has %d stockpiles: rebuilt", C.force, c.id, n) end
  return queued
end

-- Food of its own: a farm and a bakery inside the town's logistic area once it has town_farm_pop residents or its
-- rations run short (the supply hauler alone left towns below half rations for minutes when the capital held only its
-- keep, during a war, or right after a capture).
local function town_food(C, S, surface, c, P, population)
  if not copper_ok(C) then return false end
  local fb, fp, bb, bp
  fb, fp, S.farms = count_keys(C, S.farms or {})
  bb, bp, S.bakeries = count_keys(C, S.bakeries or {})
  if fp > 0 or bp > 0 then return false end
  local need = population.needs(c.id)[RATIONS] or 0
  local stock = net_count(c, RATIONS)
  local short = stock < (AI.town_rations_minutes or 4) * need
  -- (Phase 5 M3 ai, wave B.2: a city the planner founded gets its farm at once: it lies hundreds of tiles out and its
  -- ration hauler is its only food until then)
  local planned = deps.planner and deps.planner.role_of and deps.planner.role_of(C.force, c.id) ~= nil
  if P.pop < (AI.town_farm_pop or 60) and not short and not planned then return false end
  if not steel_ready(C) and not short then return false end
  local fx = (C.frame and C.frame.fx) or 1
  local pref = {x = c.position.x - fx * 8, y = c.position.y + 8}
  -- both at once when the town runs short (a captured town or city-state has no food at all)
  local queued = false
  for _, name in ipairs({"rts-farm", "rts-bakery"}) do
    local have = name == "rts-farm" and fb or bb
    if have == 0 and (not queued or short) then
      local key = queue_near(C, surface, name, c, pref, {AI.town_area or 13, AI.town_area_far or AI.town_area or 13},
        true) -- (Phase 5 M3 ai, wave B.2: a wider ring inside the City Center's logistic area)
      if key then
        if name == "rts-farm" then S.farms[#S.farms + 1] = key else S.bakeries[#S.bakeries + 1] = key end
        queued = true
        util.log("ai %s: governor: town %d %s queued (%d residents, %d rations there)", C.force, c.id, name,
          math.floor(P.pop), stock)
      end
    end
  end
  return queued
end

-- Extraction first in a mining town: its extractors and smelters are pinned (staffed before anything else there).
local function town_pins(C, S, c, labor, population)
  -- Phase 5 M3 ai (determinism, m3-perf's audit): by unit number, not in the set's insertion order
  local members = {}
  for un in pairs(population.members(c.id)) do members[#members + 1] = un end
  table.sort(members)
  for _, un in ipairs(members) do
    local rec = buildings.get(un)
    if rec and (rec.kind == "extractor" or rec.kind == "smelter") and not S.pins[un] then
      labor.pin(rec.entity, true)
      S.pins[un] = true
    end
  end
  for un in pairs(S.pins) do
    if not buildings.get(un) then S.pins[un] = nil end
  end
end

-- The town's export route: a manual hauler from the town to the nation's port (the port keeps what the market sells,
-- market.lua ai_route; ai/nation.lua's sale pass sells it), only for the surplus the trains and the capital's haulers
-- do not take: it starts while the town holds more than town_export_start of its ore and plate together and ends
-- below town_export_stop (the M1 freight goal counts what the trains carry). C.route_haulers asks for its kit.
local MAI = balance.nation.market.ai
local PLATE_OF = {["iron-ore"] = "iron-plate", ["copper-ore"] = "copper-plate"}

local function town_stock(C, c)
  local T = C.town
  local ore = (T and T.ore) or "iron-ore"
  return net_count(c, ore) + net_count(c, PLATE_OF[ore] or "iron-plate")
end

local function release_route(C, S, why)
  local L = deps.logistics
  local un = S.route
  S.route, S.exporting = nil, nil
  if not (L and un and L.hauler(un)) then return end
  L.set_mode(un, "auto")
  local cc = buildings.main_cc(C.force)
  if cc then L.set_home(un, cc.entity.unit_number) end
  util.log("ai %s: governor: export hauler #%d back to the capital (%s)", C.force, un, why)
end

local function town_export(C, S, c)
  local market, L = deps.market, deps.logistics
  if not (market and L) then return end
  local port = market.ports(C.force)[1]
  local stock = town_stock(C, c)
  if not port then
    if S.route then release_route(C, S, "no port") end
    return
  end
  if S.exporting and stock < (MAI.town_export_stop or 300) then
    release_route(C, S, string.format("town stock %d", stock))
    return
  end
  if not S.exporting and stock <= (MAI.town_export_start or 1500) then return end
  S.exporting = true
  local h = S.route and L.hauler(S.route)
  if h and h.mode == "manual" and h.pickup == c.center and h.dropoff == port then return end
  S.route = nil
  local G = C.gov
  local taken = {}
  for _, un in pairs(G.haulers) do taken[un] = true end
  for _, T in pairs(G.cities) do if T.route then taken[T.route] = true end end
  local MA = market.state and market.state() and market.state().ai and market.state().ai[C.force]
  if MA and MA.hauler then taken[MA.hauler] = true end
  for un, hh in L.haulers_of(C.force) do
    if hh.mode == "auto" and not taken[un] then
      L.set_pickup(un, c.center)
      L.set_dropoff(un, port)
      S.route = un
      util.log("ai %s: governor: hauler #%d exports town %d's surplus (%d) to port #%d", C.force, un, c.id, stock, port)
      break
    end
  end
end

---------------------------------------------------------------------------
-- The pass
---------------------------------------------------------------------------
local function capital_of(C)
  local nat = storage.nations and storage.nations[C.force]
  local cities = deps.cities
  return nat and cities and cities.get(nat.capital) or nil
end

-- Houses where the housing runs short and the city is fed (one city per pass, the shortest first).
local function houses(C, G, surface, c, P, labor, population, age)
  local S = city_state(G, c)
  local built, pending
  built, pending, S.houses = count_keys(C, S.houses)
  local total_pending = 0
  for _, T in pairs(G.cities) do
    local _, p = count_keys(C, T.houses)
    total_pending = total_pending + p
  end
  if total_pending >= AI.max_queued or game.tick < G.house_at or rails_need_stone(C) then return false end
  local r = P.needs[RATIONS]
  if not (r and r.met >= PB.hold_at) then return false end
  local housing = population.housing(c.id)
  local free = housing - P.pop
  local short
  if labor and age >= AI.start_after * 60 then
    local st = labor.city_stats(c.id) or {}
    short = (st.jobs or 0) / PB.workforce + AI.job_margin - housing
  else
    short = AI.free_housing - free
  end
  if short <= 0 then return false end
  local fx = (C.frame and C.frame.fx) or 1
  local pref = {x = c.position.x - fx * 16, y = c.position.y + 12}
  local radii = AI.house_radius
  -- Phase 5 M3 ai (Nation): the capital's houses go outside its Command Center's logistic area (the 50x50 square the
  -- districts need: thirty houses there left the Age III road's Electronics and Petrochemical works without a spot)
  if c.capital and AI.capital_house_pref then
    local o = AI.capital_house_pref
    pref = {x = c.position.x - fx * o[1], y = c.position.y + o[2]}
    radii = AI.capital_house_radius or radii
  end
  local key = queue_near(C, surface, "rts-house", c, pref, radii, true)
  if not key then return false end
  S.houses[#S.houses + 1] = key
  G.house_at = game.tick + AI.house_gap * 60
  util.log("ai %s: governor: house queued in city %d (%d free housing, %d houses built there)", C.force, c.id,
    math.floor(free), built)
  return true
end

local function city_pass(C, G, surface, c, capital, list, age)
  local population, labor = mod("population"), mod("labor")
  if not population then return end
  local P = population.get(c.id)
  if not P then return end
  local S = city_state(G, c)
  local L = deps.logistics
  local start = age >= AI.start_after * 60
  local is_capital = c.id == capital.id
  -- the doctrine's draft (once per city) and the needs keeps
  if start then
    if not G.draft[c.id] then
      G.draft[c.id] = true
      population.set_draft(c.id, PB.draft.doctrine[C.doctrine or ""] or PB.draft.default)
    end
    local pol = L and L.policy(c.center)
    if pol then
      local needs = population.needs(c.id)
      for _, spec in ipairs(NEEDS) do
        local per = needs[spec.item]
        if per then
          local keep = math.max(spec.keep, math.ceil(per * AI.keep_minutes))
          if pol.keep[spec.item] ~= keep then L.set_policy(c.center, "keep", spec.item, keep) end
        end
      end
    end
  end
  local queued = false
  if is_capital then
    if start and labor then capital_labor(C, G, labor) end
    -- the nation's needs
    local total, rations_need, goods_need, towns_goods_keep, stalled = 0, 0, 0, 0, false
    for _, o in ipairs(list) do
      local Po = population.get(o.id)
      if Po then
        local n = population.needs(o.id)
        -- a town with a farm of its own feeds itself: the capital's farms count the others only
        local So = G.cities[o.id]
        local own = o.id ~= capital.id and So and So.farms and (count_keys(C, So.farms)) > 0
        if not own then
          total = total + Po.pop
          rations_need = rations_need + (n[RATIONS] or 0)
        end
        goods_need = goods_need + (n[GOODS] or 0)
        if o.id ~= capital.id then
          if n[GOODS] then
            towns_goods_keep = towns_goods_keep + math.max(NEEDS[2].keep, math.ceil(n[GOODS] * AI.keep_minutes))
          end
          local So = G.cities[o.id]
          if So and So.stall_since and game.tick - So.stall_since >= (AI.stall_ticks or 3 * 3600) then
            stalled = true
          end
        end
      end
    end
    if start then
      if goods_need > 0 then
        local own = math.max(NEEDS[2].keep, math.ceil((population.needs(c.id)[GOODS] or 0) * AI.keep_minutes))
        local hold = G.food_emergency or C.boot
        local want = own + towns_goods_keep + (AI.export_extra or 0)
        -- the road to Age II first: while Industrialisation is researched or the Charter is built, the goods works
        -- keep only age2_focus_minutes of the nation's need (their copper cable went into circuits for the 20 advanced
        -- kits; seed 404's aggressive AI took 9 minutes for Industrialisation)
        if AI.age2_focus_minutes and age2_road(C) then
          want = math.min(want, math.ceil(goods_need * AI.age2_focus_minutes))
        end
        set_target(c.id, GOODS, hold and 0 or want)
        set_target(c.id, "stone-brick", AI.brick_target)
        -- Phase 5 M3 ai (wave B.2): the goods chain's copper cable for the fixed goods works (C.cfg.goods_per_works)
        if C.cfg and C.cfg.goods_per_works and AI.goods_cable then set_target(c.id, "copper-cable", AI.goods_cable) end
      end
      if AI.house_stock and AI.house_stock > 0 then
        set_target(c.id, "rts-house", rails_need_stone(C) and 0 or AI.house_stock)
      end
      -- the capital ships food and goods above its own keep when there is another city to feed
      local pol = L and L.policy(c.center)
      if pol and #list > 1 then
        for _, spec in ipairs(NEEDS) do
          local want = (pol.keep[spec.item] or spec.keep) + (AI.export_extra or 0)
          if pol.export_above[spec.item] ~= want then L.set_policy(c.center, "export_above", spec.item, want) end
        end
      end
      -- magazines for the towns' turrets (the supply haulers carry them; the builder keeps TURRET_MAGAZINES at home)
      local turrets = 0
      for _, T in pairs(G.cities) do turrets = turrets + #T.turrets end
      if pol and turrets > 0 and pol.export_above["firearm-magazine"] ~= data.TURRET_MAGAZINES then
        L.set_policy(c.center, "export_above", "firearm-magazine", data.TURRET_MAGAZINES)
      end
      -- more stone and copper when they run short: houses, farms, bricks and the rails take stone (the build order
      -- stops at one stone extractor), goods, circuits and the advanced kits take copper (seed 404: one copper slot at
      -- 37 plates a minute until minute 18, Industrialisation at 19:02)
      for _, R in ipairs({{line = "stone", item = "stone", low = AI.stone_low or 100, steel = true},
                          {line = "copper", item = "copper-plate", low = AI.copper_low}}) do -- Phase 5 M3 ai: a balance key
        local RL = C.lines and C.lines[R.line]
        local key = R.line .. "_at"
        if RL and RL.status == "ok" and (steel_ready(C) or not R.steel) and construction.have(C, R.item) < R.low
           and game.tick >= (G[key] or 0) and build_order.line_running(C, R.line) and not build_order.line_busy(C, RL) then
          local drills, slots = build_order.line_drills_built(C, RL), build_order.line_slots_built(C, RL)
          if drills < #RL.drills then
            build_order.want_drills(C, RL, drills + 1)
            if slots < #RL.slots and drills + 1 > 2 * slots then build_order.want_slots(C, RL, slots + 1) end
            G[key] = game.tick + (AI.stone_gap or 2 * 3600)
            util.log("ai %s: governor: %s runs short (%d): %s extractor %d of %d", C.force, R.item,
              construction.have(C, R.item), R.line, drills + 1, #RL.drills)
          end
        end
      end
      queued = food(C, G, surface, c, total, rations_need)
      if not queued and AI.goods_works then
        queued = goods_works(C, G, surface, c, goods_need, stalled and net_count(c, GOODS) < NEEDS[2].keep)
      end
      supply_haulers(C, G, c, list)
    end
  else
    -- a town: extraction first, defence, the export route, the goods stall watch
    if labor and start then town_pins(C, S, c, labor, population) end
    if start then town_export(C, S, c) end
    queued = town_storage(C, S, surface, c)
    queued = town_food(C, S, surface, c, P, population) or town_defence(C, S, surface, c) or queued
    local g = P.needs[GOODS]
    local tier = c.tier or 1
    if tier >= 2 and g and g.met < PB.grow_at and P.pop < PB.tiers[2] * 1.15 then
      S.stall_since = S.stall_since or game.tick
    else
      S.stall_since = nil
    end
  end
  if not queued and (is_capital or steel_ready(C)) then
    houses(C, G, surface, c, P, start and labor or nil, population, age)
  end
end

--- One governor run for commander C (ai/commander.lua, every run): each own city whose pass is due.
function governor.step(C, surface)
  if not nation() then return end
  local m = storage.match
  if not (m and m.tick_started) then return end
  local age = match_age()
  if age < math.min(AI.start_after, AI.house_after) * 60 then return end
  local capital = capital_of(C)
  if not capital then return end
  local G = G_of(C)
  local list = deps.cities.for_force(C.force)
  local routes = 0
  local port = deps.market and deps.market.ports(C.force)[1]
  for _, c in ipairs(list) do
    local S = city_state(G, c)
    if c.id ~= capital.id and port and S.exporting then routes = routes + 1 end
    if game.tick >= S.next and c.entity and c.entity.valid then
      S.next = game.tick + governor.PERIOD
      city_pass(C, G, surface, c, capital, list, age)
    end
  end
  C.route_haulers = routes
  -- forget the cities the nation lost
  local own = {}
  for _, c in ipairs(list) do own[c.id] = true end
  for id in pairs(G.cities) do if not own[id] then G.cities[id] = nil end end
end

--- "governor: 3 farms, 2 bakeries, 1 goods works, 7 houses, 2 town turrets, 1 export route, 1 supply hauler".
function governor.describe(C)
  local G = C.gov
  if not G then return "governor: -" end
  local houses_n, turrets, routes = 0, 0, 0
  for _, S in pairs(G.cities) do
    houses_n = houses_n + (count_keys(C, S.houses))
    turrets = turrets + (count_keys(C, S.turrets))
    if S.route then routes = routes + 1 end
  end
  return string.format("governor: farms %d, bakeries %d, goods works %d, houses %d, town turrets %d, export routes %d, "
    .. "supply haulers %d", (count_keys(C, G.farms)), (count_keys(C, G.bakeries)), (count_keys(C, G.goods)), houses_n,
    turrets, routes, table_size(G.haulers))
end

deps.governor = governor
return governor
