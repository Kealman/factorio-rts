-- Phase 5 E1 economy fixture (test copy only):
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/economy_e1.lua STOP_ON='RTS_ECONOMY_E1_DONE' \
--     tools/autotest-run.sh p5e-fixture '{opponents = 1, difficulty = "normal", size = "large", enemy_brain = "ai",
--     mode = "nation"}' 900
-- Two seconds into a Nation-mode match both AI commanders are stopped and the probe drives rts-player by script.
-- Log lines "[rts] economy e1 <check>: PASS|FAIL ...", then "[rts] economy e1 summary <passed>/<total>" and the stop
-- marker RTS_ECONOMY_E1_DONE.
--   efficiency  (static, prototypes) raw plates, stone, coal and crude per Age II good: the district chain needs at least
--             balance.nation.economy.district_efficiency x less than the hand-built chain, for every Age II good
--   softcap   army of 42 (36 walkers spawned by script, supply raised): an Age I kit becoming a unit takes the +20 %
--             surcharge (2 iron, 1 copper for a walker kit) from the network; with no iron the kit waits ("surcharge"),
--             with iron back it deploys. An Armoured car kit in Age I is held ("age").
--   charter   Industrialisation researched by script, the Railway Charter started next to the capital, its goods put
--             into the capital's network: the site takes them, counts down and the force enters Age II; the enemy
--             force stays in Age I (age, district recipe, Age II technology status); age2_military: the held car kit
--             deploys an Armoured car without surcharge, and the force carries the Age II Mk2 line (unit damage +25 %,
--             armor share 0.29), the enemy none
--   switch    an auto factory with make targets gears 20 and explosives 30 makes gears first; once the gear stock
--             reaches its target the factory switches to explosives within 5 s
--   oil       city B (a hub 100 tiles away, or a second city when scripts/cities.lua is loaded) has an oil field with
--             two pumpjacks and a Petrochemical works; the capital (city A) has an auto factory with targets advanced
--             circuits 20, circuits and cable but no plastic. A makes no advanced circuit for 60 s (B makes plastic);
--             then a hauler route B -> A starts and A must make an advanced circuit within 3 minutes. With
--             scripts/cities.lua, A's ledger row for advanced circuits must say "needs plastic: made in city B".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local logistics = require("scripts.logistics")
local research = require("scripts.research")
local units = require("scripts.units")
local match = require("scripts.match")
local ages = require("scripts.ages")
local districts = require("scripts.districts")
local balance = require("balance")

local F, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
local NO_CIRCUIT_WINDOW = 60 * 60
local ROUTE_DEADLINE = 180 * 60
local SWITCH_LIMIT = 5 * 60

local function P()
  storage.e1 = storage.e1 or {pass = 0, fail = 0, step = "wait"}
  return storage.e1
end

local function check(name, ok, fmt, ...)
  local s = P()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("economy e1 %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function clear(surface, area)
  for _, e in pairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "fish"}})) do
    e.destroy()
  end
  local tiles = {}
  for x = math.floor(area[1][1]), math.ceil(area[2][1]) - 1 do
    for y = math.floor(area[1][2]), math.ceil(area[2][2]) - 1 do
      local t = surface.get_tile(x, y)
      if t.valid and (t.collides_with("water_tile") or t.collides_with("player") or t.name:find("water")) then
        tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
      end
    end
  end
  if #tiles > 0 then surface.set_tiles(tiles, true, true, true, false) end
end

local function place(surface, name, pos, force)
  local e = surface.create_entity({name = name, position = pos, force = force or F, raise_built = true})
  if not e then util.log("economy e1: could not place %s at %s", name, util.pos_str(pos)) end
  return e
end

local function near_free(surface, name, want)
  return surface.find_non_colliding_position(name, want, 12, 1, true)
end

-- the same measure as production.lua's auto pass (network contents, all qualities)
local function stock(net, item)
  if not (net and net.valid) then return 0 end
  local n = 0
  for _, it in pairs(net.get_contents()) do
    if it.name == item then n = n + it.count end
  end
  return n
end

local function set_targets(city, t)
  for item, n in pairs(t) do districts.set_make_target(city, item, n) end
end

local function recipe_of(e)
  local r = e and e.valid and e.get_recipe()
  return r and r.name or "none"
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local start_charter -- below (the soft cap steps start it)

---------------------------------------------------------------------------
-- Static check: district efficiency (raw input per Age II good, hand-built chain vs district chain)
---------------------------------------------------------------------------
local RAW = {["iron-plate"] = true, ["copper-plate"] = true, stone = true, coal = true, ["rts-crude-oil"] = true,
             ["iron-ore"] = true, ["copper-ore"] = true}
local HAND = {["engine-unit"] = "rts-engine", ["rts-steel-beam"] = "rts-steel-beam",
              ["advanced-circuit"] = "rts-advanced-circuit", ["plastic-bar"] = "rts-plastic", sulfur = "rts-sulfur",
              concrete = "rts-concrete", ["rts-petroleum"] = "rts-oil-processing", ["iron-gear-wheel"] = "rts-gear",
              ["copper-cable"] = "rts-cable", ["electronic-circuit"] = "rts-circuit", ["steel-plate"] = "steel-plate",
              ["stone-brick"] = "stone-brick", ["rts-science-industrial"] = "rts-science-industrial", rail = "rts-rail"}
local DISTRICT = {["engine-unit"] = "rts-den-engine", ["rts-steel-beam"] = "rts-dra-beam",
                  ["advanced-circuit"] = "rts-del-advanced-circuit", ["plastic-bar"] = "rts-dpe-plastic",
                  sulfur = "rts-dpe-sulfur", concrete = "rts-dco-concrete", ["electronic-circuit"] = "rts-dci-circuit",
                  ["copper-cable"] = "rts-dci-cable", ["steel-plate"] = "rts-dst-steel", ["stone-brick"] = "rts-dsm-brick",
                  ["rts-science-industrial"] = "rts-dsc-industrial", rail = "rts-dra-rail"}
local GOODS = {"engine-unit", "rts-steel-beam", "advanced-circuit", "plastic-bar", "sulfur", "concrete",
               "rts-science-industrial", "rail"}

-- Raw units per item through the recipes of `path` (a district recipe where it has one, else the hand-built one).
-- A by-product is free (the petrochemical works' sulfur).
local function raw_cost(item, path, depth)
  if RAW[item] then return 1 end
  if (depth or 0) > 8 then return math.huge end
  local r = prototypes.recipe[path[item] or HAND[item] or ""]
  if not r then return nil end
  local out = 0
  for _, p in ipairs(r.products) do if p.name == item then out = out + (p.amount or 1) end end
  local total = 0
  for _, ing in ipairs(r.ingredients) do
    local c = raw_cost(ing.name, path, (depth or 0) + 1)
    if not c then return nil end
    total = total + ing.amount * c
  end
  return total / out
end

local function check_efficiency()
  local floor = balance.nation.economy.district_efficiency
  local parts, ok = {}, true
  for _, item in ipairs(GOODS) do
    local hand, dist = raw_cost(item, {}), raw_cost(item, DISTRICT)
    if hand and dist then
      local ratio = hand / dist
      if ratio < floor then ok = false end
      parts[#parts + 1] = string.format("%s %.2f/%.2f=%.2fx", item, hand, dist, ratio)
    else
      parts[#parts + 1] = item .. " n/a"
    end
  end
  local car = balance.units["rts-armoured-car"].cost
  local function kit(path)
    local t = 0
    for item, n in pairs(car) do t = t + n * (raw_cost(item, path) or 0) end
    return t
  end
  check("district_efficiency", ok, "raw per item hand/district (floor %.1fx): %s; Armoured car kit %.1f hand, %.1f "
    .. "district", floor, table.concat(parts, ", "), kit({}), kit(DISTRICT))
end

---------------------------------------------------------------------------
-- Army soft cap (Age I) and the Armoured car gate
---------------------------------------------------------------------------
local function cc_network()
  local cc = buildings.main_cc(F)
  return cc and cc.entity.logistic_network
end

local function setup_softcap(s)
  local surface = match.surface()
  local home = match.home(F)
  storage.research.supply_bonus[F] = 200 -- room for the test army (supply.cap reads it)
  for i = 1, 36 do
    units.spawn("rts-walker", {x = home.x + 25 + (i % 6) * 3, y = home.y - 30 + math.floor(i / 6) * 3}, F, nil, surface)
  end
  -- barracks A makes walker kits, B Armoured car kits (set on the entity: the force has not unlocked it); both paused,
  -- so only the kits put into their outputs deploy
  local function barracks(want, recipe)
    local pos = near_free(surface, "rts-barracks", want)
    clear(surface, {{pos.x - 3, pos.y - 3}, {pos.x + 3, pos.y + 3}})
    local b = place(surface, "rts-barracks", pos)
    b.set_recipe(recipe)
    b.disabled_by_script = true
    return b
  end
  local a = barracks({x = home.x + 10.5, y = home.y + 12.5}, "rts-walker-kit")
  local b = barracks({x = home.x + 18.5, y = home.y + 12.5}, "rts-armoured-car-kit")
  s.bar_un, s.car_bar_un = a.unit_number, b.unit_number
  s.army0 = production.army_size(F)
  s.mult = production.army_multiplier(F)
  s.step, s.t = "softcap_prime", game.tick
  util.log("economy e1: soft cap: army %d, multiplier %.2f, barracks #%d (walker kits) #%d (car kits)", s.army0,
    s.mult, s.bar_un, s.car_bar_un)
end

local function softcap_prime(s, tick)
  if tick - s.t < 2 * 60 then return end -- the pull has filled their inputs by now
  local net = cc_network()
  s.iron0, s.copper0 = stock(net, "iron-plate"), stock(net, "copper-plate")
  buildings.get(s.bar_un).entity.get_output_inventory().insert({name = "rts-walker-kit", count = 1})
  s.step, s.t = "softcap_pay", tick
end

local function softcap_pay(s, tick)
  local rec = buildings.get(s.bar_un)
  local spawned = rec and rec.spawned or 0
  if spawned < 1 and tick - s.t < 10 * 60 then return end
  local net = cc_network()
  local di, dc = s.iron0 - stock(net, "iron-plate"), s.copper0 - stock(net, "copper-plate")
  check("softcap_surcharge", spawned == 1 and math.abs(s.mult - 1.2) < 1e-6 and di == 2 and dc == 1,
    "army %d -> multiplier %.2f; the walker kit deployed (%d) and took %d iron, %d copper from the network", s.army0,
    s.mult, spawned, di, dc)
  -- now an empty network: the next kit waits
  s.held_iron = net.remove_item({name = "iron-plate", count = 100000})
  rec.entity.get_output_inventory().insert({name = "rts-walker-kit", count = 1})
  buildings.get(s.car_bar_un).entity.get_output_inventory().insert({name = "rts-armoured-car-kit", count = 1})
  s.step, s.t = "softcap_wait", tick
end

local function softcap_wait(s, tick)
  if tick - s.t < 3 * 60 then return end
  local rec = buildings.get(s.bar_un)
  local b = rec and research.block_of(s.bar_un)
  local held = rec and rec.entity.get_output_inventory().get_item_count("rts-walker-kit") or 0
  check("softcap_wait", held == 1 and b ~= nil and b.reason == "surcharge" and (rec.spawned or 0) == 1,
    "no iron in the network: kit held %d, block %s, spawned %d", held, b and b.reason or "none", rec and rec.spawned or -1)
  cc_network().insert({name = "iron-plate", count = s.held_iron})
  s.step, s.t = "softcap_resume", tick
end

local function softcap_resume(s, tick)
  if tick - s.t < 3 * 60 then return end
  local rec = buildings.get(s.bar_un)
  local inv = rec.entity.get_output_inventory()
  check("softcap_resume", (rec.spawned or 0) == 2 and inv.get_item_count("rts-walker-kit") == 0,
    "iron back: the waiting walker kit deployed (spawned %d)", rec.spawned or 0)
  local car = buildings.get(s.car_bar_un)
  local cinv = car.entity.get_output_inventory()
  local b = research.block_of(s.car_bar_un)
  check("car_needs_age2", cinv.get_item_count("rts-armoured-car-kit") == 1 and b ~= nil and b.reason == "age",
    "Age I: the Armoured car kit is held (%d in the output, block %s)", cinv.get_item_count("rts-armoured-car-kit"),
    b and b.reason or "none")
  start_charter(s)
end

local function check_age2_military(s)
  local rec = buildings.get(s.car_bar_un)
  local cars = 0
  for _, u in pairs(storage.units) do
    if u.force == F and u.kind == "car" and u.entity.valid then cars = cars + 1 end
  end
  local force, enemy = game.forces[F], game.forces[ENEMY]
  local dmg, edmg = force.get_ammo_damage_modifier("rts-walker"), enemy.get_ammo_damage_modifier("rts-walker")
  local armor, earmor = storage.research.armor[F] or 0, storage.research.armor[ENEMY] or 0
  check("age2_military", cars == 1 and rec and rec.entity.get_output_inventory().get_item_count("rts-armoured-car-kit") == 0
    and math.abs(dmg - 0.25) < 1e-6 and edmg == 0 and math.abs(armor - 0.2857) < 1e-3 and earmor == 0,
    "Armoured cars %d (the held kit deployed), walker damage modifier %.2f (enemy %.2f), armor share %.3f (enemy %.3f)",
    cars, dmg, edmg, armor, earmor)
end

function start_charter(s)
  local force = game.forces[F]
  force.technologies["rts-industrialisation"].researched = true
  check("charter_can_start", ages.can_start(F) == true, "can_start %s after Industrialisation; enemy %s",
    tostring(ages.can_start(F)), tostring(select(2, ages.can_start(ENEMY))))
  local p, why = ages.start_project(F)
  check("charter_site", p ~= nil and p.site ~= nil and p.site.valid, "site %s (%s) at %s", tostring(p and p.state),
    tostring(why), p and util.pos_str(p.position) or "-")
  for item, n in pairs(ages.required()) do economy.give(F, item, n) end
  s.charter_tick = game.tick
  s.step = "charter"
end

local function check_charter(s)
  local age = ages.of(F)
  if age < 2 and game.tick - s.charter_tick < 120 * 60 then return end
  local force, enemy = game.forces[F], game.forces[ENEMY]
  local p = ages.project(F)
  check("charter_age2", age == 2, "%s after %.0f s (%s)", ages.describe(F), (game.tick - s.charter_tick) / 60,
    p and p.state or "-")
  check("charter_force_only", ages.of(ENEMY) == 1 and force.recipes["rts-district-petrochem"].enabled
    and not enemy.recipes["rts-district-petrochem"].enabled and force.recipes["rts-advanced-circuit"].enabled
    and not enemy.recipes["rts-advanced-circuit"].enabled,
    "enemy age %d; petrochem recipe %s / enemy %s; advanced circuit %s / enemy %s", ages.of(ENEMY),
    tostring(force.recipes["rts-district-petrochem"].enabled), tostring(enemy.recipes["rts-district-petrochem"].enabled),
    tostring(force.recipes["rts-advanced-circuit"].enabled), tostring(enemy.recipes["rts-advanced-circuit"].enabled))
  local st, est = research.status(F, "rts-supply-3"), research.status(ENEMY, "rts-supply-3")
  check("charter_age_tech", st ~= "age" and est == "age", "Supply III: %s, enemy %s", st, est)
  storage.research.supply_bonus[F] = 200 -- the age-up re-applied research effects: room for the test army again
  s.step, s.t = "age2_military", game.tick
end

local function setup_switch(s)
  local surface = match.surface()
  local home = match.home(F)
  local pos = near_free(surface, "rts-factory", {x = home.x - 10.5, y = home.y + 10.5})
  clear(surface, {{pos.x - 3, pos.y - 3}, {pos.x + 3, pos.y + 3}})
  local f = place(surface, "rts-factory", pos)
  s.switch_un = f and f.unit_number
  local city = districts.city_of(f)
  s.city_a = city
  -- clear what the stopped commander's age-up hook set, then gears first, explosives next (nothing else makes them)
  for item in pairs(districts.make_targets(city)) do districts.set_make_target(city, item, nil) end
  set_targets(city, {["iron-gear-wheel"] = 20, ["rts-explosives"] = 30}) -- gears met within AUTO_DWELL
  economy.give(F, "iron-plate", 400)
  economy.give(F, "coal", 200)
  util.log("economy e1: switch factory #%s at %s (auto %s), city %s", tostring(s.switch_un), util.pos_str(pos),
    tostring(production.is_auto(buildings.get(s.switch_un))), tostring(city))
  s.step = "switch"
  s.switch_from = game.tick
end

local function check_switch(s, tick)
  local rec = buildings.get(s.switch_un)
  if not rec then
    check("switch", false, "factory gone")
    s.step = "oil_setup"
    return
  end
  local net = production.network_for(rec.entity)
  local gears = stock(net, "iron-gear-wheel")
  local r = recipe_of(rec.entity)
  if not s.first_recipe and r ~= "none" then s.first_recipe = r end
  if not s.met_tick and gears >= 20 then
    s.met_tick = tick
    util.log("economy e1: gear target met at tick %d (recipe %s)", tick, r)
  end
  if s.met_tick and r == "rts-explosives" then
    local dt = tick - s.met_tick
    check("switch_first", s.first_recipe == "rts-gear", "first recipe %s", tostring(s.first_recipe))
    check("switch_5s", dt <= SWITCH_LIMIT, "switched to %s %.1f s after the gear target was met (%d gears)", r, dt / 60,
      gears)
    districts.set_make_target(s.city_a, "iron-gear-wheel", nil)
    districts.set_make_target(s.city_a, "rts-explosives", nil)
    rec.entity.destroy({raise_destroy = true})
    s.step = "oil_setup"
  elseif tick - s.switch_from > 120 * 60 then
    check("switch_5s", false, "no switch: recipe %s, gears %d, met at %s", r, gears, tostring(s.met_tick))
    districts.set_make_target(s.city_a, "iron-gear-wheel", nil)
    districts.set_make_target(s.city_a, "rts-explosives", nil)
    rec.entity.destroy({raise_destroy = true})
    s.step = "oil_setup"
  end
end

local function setup_oil(s)
  local surface = match.surface()
  local home = match.home(F)
  local front = match.front(F)
  local side = {x = -front.y, y = front.x}
  local B = {x = math.floor(home.x + side.x * 100) + 0.0, y = math.floor(home.y + side.y * 100) + 0.0}
  -- a clear site and a clear corridor between the cities (fixture terrain only)
  clear(surface, {{B.x - 20, B.y - 20}, {B.x + 20, B.y + 20}})
  local lo = {x = math.min(home.x, B.x) - 5, y = math.min(home.y, B.y) - 5}
  local hi = {x = math.max(home.x, B.x) + 5, y = math.max(home.y, B.y) + 5}
  clear(surface, {{lo.x, lo.y}, {hi.x, hi.y}})
  local cities = ages.cities()
  local hubB
  if cities and cities.found then
    local id = cities.found(F, B, {})
    local c = cities.get(id)
    hubB = c and c.center and buildings.get(c.center) and buildings.get(c.center).entity
    s.city_b = id
  else
    hubB = place(surface, "rts-hub", B)
  end
  s.hub_b = hubB and hubB.unit_number
  for _, off in ipairs({{-7.5, 7.5}, {7.5, 7.5}}) do
    local p = {x = B.x + off[1], y = B.y + off[2]}
    surface.create_entity({name = "crude-oil", position = p, amount = 300000})
    place(surface, "rts-pumpjack", p)
  end
  for _, off in ipairs({{-6.5, -6.5}, {7.5, -6.5}}) do place(surface, "rts-solar-array", {x = B.x + off[1], y = B.y + off[2]}) end
  local pc = place(surface, "rts-district-petrochem", {x = B.x + 0.5, y = B.y - 6.5})
  s.petro_un = pc and pc.unit_number
  local netB = hubB and hubB.logistic_network
  if netB then netB.insert({name = "coal", count = 200}) end
  s.city_b = s.city_b or districts.city_of(pc)
  -- city A: an auto factory with circuits and cable, no plastic
  local fpos = near_free(surface, "rts-factory", {x = home.x - 10.5, y = home.y - 10.5})
  clear(surface, {{fpos.x - 3, fpos.y - 3}, {fpos.x + 3, fpos.y + 3}})
  local fa = place(surface, "rts-factory", fpos)
  s.fa_un = fa and fa.unit_number
  s.city_a = districts.city_of(fa)
  economy.give(F, "electronic-circuit", 100)
  economy.give(F, "copper-cable", 200)
  set_targets(s.city_a, {["advanced-circuit"] = 20})
  set_targets(s.city_b, {["plastic-bar"] = 40})
  s.oil_tick = game.tick
  s.step = "oil_wait"
  util.log("economy e1: city B %s at %s (hub #%s, petrochem #%s, network %s), city A %s factory #%s at %s",
    tostring(s.city_b), util.pos_str(B), tostring(s.hub_b), tostring(s.petro_un), tostring(netB ~= nil),
    tostring(s.city_a), tostring(s.fa_un), util.pos_str(fpos))
end

local function a_network(s)
  local cc = buildings.main_cc(F)
  return cc and cc.entity.logistic_network
end

local function b_network(s)
  local rec = s.hub_b and buildings.get(s.hub_b)
  return rec and rec.entity.logistic_network
end

local function check_oil_wait(s, tick)
  local netA, netB = a_network(s), b_network(s)
  local fa = buildings.get(s.fa_un)
  if fa and recipe_of(fa.entity) == "rts-advanced-circuit" then s.fa_tried = true end
  if stock(netA, "advanced-circuit") > 0 then s.early_circuit = true end
  if tick - s.oil_tick < NO_CIRCUIT_WINDOW then return end
  local rows = districts.ledger(s.city_a)
  local hint
  for _, row in ipairs(rows) do
    if row.item == "advanced-circuit" and row.hint then hint = row.hint end
  end
  check("oil_no_plastic_no_circuit", not s.early_circuit and not s.fa_tried and stock(netA, "plastic-bar") == 0,
    "city A: advanced circuits %d, factory recipe %s, plastic %d; ledger hint %s", stock(netA, "advanced-circuit"),
    fa and recipe_of(fa.entity) or "-", stock(netA, "plastic-bar"),
    hint and (hint.item .. " from " .. tostring(hint.city)) or "none")
  if ages.cities() then -- one city per force under the shim: no other city to name
    check("oil_ledger_hint", hint ~= nil and hint.item == "plastic-bar" and hint.city == s.city_b,
      "city A's ledger row for advanced circuits: %s", hint and ("needs " .. hint.item .. ", made in city "
      .. tostring(hint.city)) or "no hint")
  end
  check("oil_b_makes_plastic", stock(netB, "plastic-bar") > 0, "city B: crude %d, plastic %d, sulfur %d, coal %d; %s",
    stock(netB, "rts-crude-oil"), stock(netB, "plastic-bar"), stock(netB, "sulfur"), stock(netB, "coal"),
    districts.describe(s.city_b))
  -- the route: B exports plastic, A keeps it, a manual hauler B -> A
  local cc = buildings.main_cc(F)
  logistics.set_policy(s.hub_b, "export_above", "plastic-bar", 0)
  logistics.set_policy(cc.entity.unit_number, "keep", "plastic-bar", 30)
  local hb = buildings.get(s.hub_b)
  local h = logistics.spawn_hauler(match.surface(), {x = hb.entity.position.x, y = hb.entity.position.y + 6}, F, s.hub_b)
  if h then
    logistics.set_pickup(h.unit_number, s.hub_b)
    logistics.set_dropoff(h.unit_number, cc.entity.unit_number)
  end
  s.route_tick = tick
  s.step = "oil_route"
  util.log("economy e1: route B -> A started at tick %d with hauler %s", tick, h and ("#" .. h.unit_number) or "none")
end

local function check_oil_route(s, tick)
  local netA = a_network(s)
  local n = stock(netA, "advanced-circuit")
  if not s.plastic_at and stock(netA, "plastic-bar") > 0 then
    s.plastic_at = tick
    util.log("economy e1: plastic reached city A %.1f s after the route started", (tick - s.route_tick) / 60)
  end
  if n > 0 or tick - s.route_tick > ROUTE_DEADLINE then
    local fa = buildings.get(s.fa_un)
    check("oil_route_circuit_3min", n > 0 and tick - s.route_tick <= ROUTE_DEADLINE,
      "city A advanced circuits %d at %.1f s after the route started (plastic arrived at %s); factory recipe %s; %s",
      n, (tick - s.route_tick) / 60, s.plastic_at and string.format("%.1f s", (s.plastic_at - s.route_tick) / 60) or "never",
      fa and recipe_of(fa.entity) or "-", districts.describe(s.city_a))
    s.step = "done"
  end
end

local function finish(s)
  s.step = "finished"
  util.log("economy e1 summary %d/%d%s", s.pass, s.pass + s.fail, s.fail == 0 and " (all passed)"
    or string.format(" (%d FAILED)", s.fail))
  for _, f in ipairs(match.forces()) do util.log("economy e1: %s", ages.describe(f)) end
  log("RTS_ECONOMY_E1_DONE")
end

-- the switch test samples the gear stock every tick, so "met" is the first tick the network held the target
events.on(defines.events.on_tick, function(e)
  local s = storage.e1
  if not (s and s.step == "switch" and not s.met_tick and s.switch_un) then return end
  local rec = buildings.get(s.switch_un)
  if rec and stock(production.network_for(rec.entity), "iron-gear-wheel") >= 20 then
    s.met_tick = e.tick
    util.log("economy e1: gear target met at tick %d (per-tick sample)", e.tick)
  end
end)

events.on_nth_tick(10, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = P()
  local tick = e.tick
  if s.step == "wait" then
    if tick - m.tick_started < 120 then return end
    ai.stop_force(F)
    ai.stop_force(ENEMY)
    -- the commander may have set a recipe in its first seconds: pause the force's factories (fixed, no recipe)
    for un, rec in buildings.for_force(F, "factory") do production.set_recipe(un, nil) end
    util.log("economy e1: started at tick %d, mode %s", tick, tostring(m.config.mode))
    check("nation_mode", ages.is_nation(), "mode %s", tostring(m.config.mode))
    check_efficiency()
    setup_softcap(s)
  elseif s.step == "softcap_prime" then
    softcap_prime(s, tick)
  elseif s.step == "softcap_pay" then
    softcap_pay(s, tick)
  elseif s.step == "softcap_wait" then
    softcap_wait(s, tick)
  elseif s.step == "softcap_resume" then
    softcap_resume(s, tick)
  elseif s.step == "charter" then
    check_charter(s)
  elseif s.step == "age2_military" then
    if tick - s.t >= 3 * 60 then
      check_age2_military(s)
      s.step = "switch_setup"
    end
  elseif s.step == "switch_setup" then
    setup_switch(s)
  elseif s.step == "switch" then
    check_switch(s, tick)
  elseif s.step == "oil_setup" then
    setup_oil(s)
  elseif s.step == "oil_wait" then
    check_oil_wait(s, tick)
  elseif s.step == "oil_route" then
    check_oil_route(s, tick)
  elseif s.step == "done" then
    finish(s)
  end
end)
