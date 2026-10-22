-- Phase 5 M3 age3 fixture (test copy only; docs/PHASE5-M3.md §4 "Age III / rare / sinks", docs/qa/phase5-age3-notes.md):
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/age3_fixture.lua STOP_ON='RTS_AGE3_DONE' SPEED=4 \
--     tools/autotest-run.sh p5m3-age3-fx '{opponents = 1, difficulty = "normal", enemy_brain = "ai", mode = "nation"}' 900
-- Two seconds into a 1v1 Nation match both AI commanders stop and the probe drives the nations by script. Log lines
-- "[rts] age3 fx <check>: PASS|FAIL ...", then "[rts] age3 fx summary <passed>/<total>" and the marker RTS_AGE3_DONE.
--   stage1      Electrification researched, Age II set, the Space Program started next to the capital, stage 1 goods
--               put into the capital network: the complex pulls 10 per good and second, counts down, the nation enters
--               Age III (signal rts_age_up), the Age III recipes unlock for it and not for the rival
--   automation  a Steel works (metallurgy) with the policy "automate metallurgy" gets 2 kits from the network: jobs
--               x0.49, the city's jobs drop by 16 x 0.51, crafting speed and staffing unchanged; policy off: the kits
--               go back into the network
--   rush        stage 2 goods in the network, Rush: 20 per good and second and charges project_cr per missing item and
--               second (expenses "other" == the rush's spent), countdown twice as fast
--   space_mode  stage 3 under victory mode "conquest": the program completes and the match goes on
--   rare        a rare extractor on a rim deposit with a hub next to it: its items reach the hub's network; every rare
--               kind put into the capital network every 10 s: every bonus is on within 90 s (explosives productivity
--               +0.25, circuits +0.2, steel +0.2, mining +0.15, lab speed and productivity +0.1, tax bonus 0.15), the
--               flow stops: every bonus is still on at 80 s and gone (deltas back to the start values) at 92 s
--   nuclear     a Chemistry district makes a fuel rod from uranium ore; a Nuclear plant on its own grid with a 40 MW+
--               sink takes rods from its network and delivers 40 MW
--   rounds      2 heavy walkers and uranium rounds magazines in the capital network: the heavies' damage modifier +0.3;
--               the magazines gone: the bonus is off within 40 s
--   rush_research  the current research rushed: lab speed +1 as a delta, charged per missing unit and second;
--               cancelled: the lab speed is back
--   hire        8 hired garrison points at the capital cost 8 x 40 cr, man 2 hidden turrets and decay to 7 after a
--               minute
--   mercenaries an own port: a division spawns within 20 tiles of it; a second hire is refused ("cooldown")
--   city_state  buying a city-state's good raises its relation by cr / 100 and the goods arrive in the capital network
--               after 30 s; a peacetime capture costs -10 relation with the rival
--   space_win   the rival completes its program under "conquest_space": the match ends with a Space victory for it
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local research = require("scripts.research")
local match = require("scripts.match")
local ages = require("scripts.ages")
local cities = require("scripts.cities")
local labor = require("scripts.labor")
local garrison = require("scripts.garrison")
local treasury = require("scripts.treasury")
local market = require("scripts.market")
local world = require("scripts.world")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")
local age3 = require("scripts.age3")
local rare = require("scripts.rare")
local sinks = require("scripts.sinks")
local balance = require("balance")

local F, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
local A3 = balance.nation.age3
local RB = balance.nation.rare
local SB = balance.nation.sinks

local function P()
  storage.a3fx = storage.a3fx or {pass = 0, fail = 0, step = "wait", t = 0, age_up = {}}
  return storage.a3fx
end

local function check(name, ok, fmt, ...)
  local s = P()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("age3 fx %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

events.on_signal("rts_age_up", function(d)
  local s = P()
  s.age_up[#s.age_up + 1] = d.force .. ":" .. tostring(d.age)
end)

local function cap_net(force) return rare.capital_network(force) end

local function capital(force)
  local n = storage.nations and storage.nations[force]
  return n and n.capital and cities.get(n.capital)
end

local function clear(surface, area)
  for _, e in pairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "fish"}})) do
    e.destroy()
  end
end

local function place(name, want, force, radius)
  local surface = match.surface()
  local pos = surface.find_non_colliding_position(name, want, radius or 20, 1, true)
  if not pos then
    util.log("age3 fx: no spot for %s near %s", name, util.pos_str(want))
    return nil
  end
  local e = surface.create_entity({name = name, position = pos, force = force or F, raise_built = true})
  if not e then util.log("age3 fx: could not place %s at %s", name, util.pos_str(pos)) end
  return e
end

local function research_now(force, tech)
  local t = game.forces[force].technologies[tech]
  if t and not t.researched then t.researched = true end
  research.apply(game.forces[force])
end

local function other_expenses(force)
  local N = treasury.record(force)
  return N and N.totals.expenses.other or 0
end

local function insert_all(net, list)
  local ok = true
  for item, n in pairs(list) do
    if net.insert({name = item, count = n}) < n then ok = false end
  end
  return ok
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local function setup(s)
  ai.stop_force(F)
  ai.stop_force(ENEMY)
  for _, rec in buildings.for_force(F, "factory") do production.set_recipe(rec.entity.unit_number, nil) end
  storage.research.supply_bonus[F] = 200
  for _, f in ipairs({F, ENEMY}) do
    research_now(f, "rts-industrialisation")
    ages.set_age(f, 2, "fixture")
    research_now(f, A3.tech)
    research_now(f, "rts-geology")
  end
  treasury.set_balance(F, 20000, "fixture")
  local P0, why = age3.start(F)
  check("start", P0 ~= nil and P0.stage == 1 and P0.site and P0.site.valid,
    "Space Program started: %s (%s), site %s", P0 and P0.state or "nil", tostring(why),
    P0 and P0.site and util.pos_str(P0.site.position) or "-")
  local ok, why2 = age3.can_start(F)
  check("start_once", not ok and why2 == "running", "a second start: %s (%s)", tostring(ok), tostring(why2))
  s.cap_city = capital(F).id
  s.enemy_cap = capital(ENEMY) and capital(ENEMY).id
  -- stage 1 goods
  insert_all(cap_net(F), A3.stages[1].required)
  s.step, s.t = "stage1_pull", game.tick
end

local function stage1_pull(s, tick)
  if tick - s.t < 5 * 60 + 30 then return end
  local P0 = age3.project(F)
  local steel = P0 and P0.delivered["steel-plate"] or 0
  -- 5 or 6 passes of 10 per good since the goods went in
  check("pull_rate", steel >= 50 and steel <= 60, "steel delivered after 5.5 s: %d (10 per good and second)", steel)
  s.step, s.t = "stage1_done", tick
end

local function stage1_done(s, tick)
  local P0 = age3.project(F)
  if ages.of(F) < 3 and tick - s.t < 90 * 60 then return end
  local fr, er = game.forces[F].recipes, game.forces[ENEMY].recipes
  check("stage1_age3", ages.of(F) == 3 and ages.of(ENEMY) == 2 and P0.stage == 2 and P0.state == "building",
    "age %d (rival %d), program stage %d %s, signals [%s]", ages.of(F), ages.of(ENEMY), P0.stage, P0.state,
    table.concat(s.age_up, " "))
  check("age3_recipes", fr["rts-district-chemistry"].enabled and fr["rts-automation-kit"].enabled
    and fr["rts-de2-processing-unit"].enabled and not er["rts-district-chemistry"].enabled
    and not fr["rts-dch-battery"].enabled and not fr["rts-nuclear-plant"].enabled,
    "Age III recipes for %s, not for %s; Chemistry and Nuclear recipes wait for research", F, ENEMY)
  check("age3_signal", #s.age_up == 1 and s.age_up[1] == F .. ":3", "rts_age_up: [%s]", table.concat(s.age_up, " "))
  -- automation setup: a Steel works next to the capital, pinned (full staff), 4 kits in the network
  local cap = capital(F)
  local d = place("rts-district-steel", {x = cap.position.x - 14, y = cap.position.y + 14}, F, 24)
  s.dist_un = d and d.unit_number
  if d then
    production.set_recipe(d.unit_number, "rts-dst-steel")
    labor.pin(d, true)
  end
  cap_net(F).insert({name = A3.kit.item, count = 4})
  s.step, s.t = "auto_base", tick
end

local function auto_base(s, tick)
  if tick - s.t < 12 * 60 then return end -- two staffing passes
  local rec = s.dist_un and buildings.get(s.dist_un)
  if not rec then
    check("automation", false, "no Steel works")
    s.step = "stage2"
    return
  end
  s.speed0 = rec.entity.crafting_speed
  s.jobs0 = labor.city_stats(s.cap_city).jobs or 0
  s.staff0 = labor.staffing(rec.entity)
  s.kits_net0 = cap_net(F).get_item_count(A3.kit.item)
  local ok = age3.automate(s.cap_city, "metallurgy", true)
  check("automate_policy", ok, "automate metallurgy at city %d: %s", s.cap_city, tostring(ok))
  s.step, s.t = "auto_on", tick
end

local function auto_on(s, tick)
  if tick - s.t < 12 * 60 then return end
  local rec = buildings.get(s.dist_un)
  local e = rec.entity
  local kits = e.get_module_inventory().get_item_count(A3.kit.item)
  local factor = labor.job_factor(e)
  local jobs = labor.city_stats(s.cap_city).jobs or 0
  local info = age3.automation(s.cap_city).metallurgy or {}
  check("automation_jobs", kits == 2 and math.abs(factor - 0.49) < 1e-6 and math.abs((s.jobs0 - jobs) - 16 * 0.51) < 0.01,
    "kits %d, job factor %.3f, city jobs %.2f -> %.2f (cut %.2f, want %.2f), family info kits %d cut %.2f", kits, factor,
    s.jobs0, jobs, s.jobs0 - jobs, 16 * 0.51, info.kits or -1, info.jobs_cut or -1)
  check("automation_output", math.abs(e.crafting_speed - s.speed0) < 1e-6 and labor.staffing(e) == 1 and s.staff0 == 1,
    "crafting speed %.3f -> %.3f, staffing %.1f -> %.1f", s.speed0, e.crafting_speed, s.staff0, labor.staffing(e))
  age3.automate(s.cap_city, "metallurgy", false)
  s.step, s.t = "auto_off", tick
end

local function auto_off(s, tick)
  if tick - s.t < 6 * 60 then return end
  local rec = buildings.get(s.dist_un)
  local kits = rec.entity.get_module_inventory().get_item_count(A3.kit.item)
  local back = cap_net(F).get_item_count(A3.kit.item)
  check("automation_off", kits == 0 and back == s.kits_net0 and labor.job_factor(rec.entity) == 1,
    "policy off: kits in the works %d, in the network %d (before %d)", kits, back, s.kits_net0)
  -- stage 2 with Rush
  insert_all(cap_net(F), A3.stages[2].required)
  s.other0 = other_expenses(F)
  local ok, why = sinks.rush(F, "project")
  check("rush_start", ok, "rush the Space Program: %s (%s)", tostring(ok), tostring(why))
  s.step, s.t = "rush_pull", tick
end

local function rush_pull(s, tick)
  if tick - s.t < 3 * 60 + 30 then return end
  local P0 = age3.project(F)
  local bat = P0.delivered.battery or 0
  check("rush_pull", bat >= 60 and bat <= 80, "batteries delivered after 3.5 s of Rush: %d (20 per good and second)", bat)
  s.step, s.t = "rush_count", tick
end

local function rush_count(s, tick)
  local P0 = age3.project(F)
  if P0.state == "countdown" and not s.cd_start then
    s.cd_start = tick
    s.cd_until = P0.countdown_until
  end
  if P0.stage == 2 and tick - s.t < 60 * 60 then return end
  local st = sinks.rush_state(F)
  local spent = s.rush_spent or (st and st.spent) or 0
  local paid = other_expenses(F) - s.other0
  local cd = s.cd_start and (tick - s.cd_start) / 60 or -1
  check("rush_stage2", P0.stage == 3 and cd > 0 and cd <= A3.stages[2].build_seconds / 2 + 2,
    "stage 2 done: stage now %d, countdown took %.1f s (%d s unrushed)", P0.stage, cd, A3.stages[2].build_seconds)
  check("rush_charge", spent > 0 and math.abs(paid - spent) < 0.01,
    "rush spent %.2f cr, expenses 'other' rose %.2f cr (project_cr %.3f per missing item and second)", spent, paid,
    SB.rush.project_cr)
  -- stage 3 under "conquest": completes, the match goes on
  storage.match.config.victory = "conquest"
  insert_all(cap_net(F), A3.stages[3].required)
  sinks.rush(F, "project") -- the rush of stage 2 ended with it; stage 3 counts down 60 s instead of 120
  s.step, s.t = "stage3", tick
end

local function stage3(s, tick)
  local P0 = age3.project(F)
  if P0.state ~= "complete" and tick - s.t < 150 * 60 then return end
  check("space_mode", P0.state == "complete" and storage.match.phase == "running",
    "stage 3 under victory mode conquest: program %s, match %s", P0.state, storage.match.phase)
  check("rush_ended", sinks.rush_state(F) == nil, "the rush ended with the program: %s",
    tostring(sinks.rush_state(F) and sinks.rush_state(F).what))
  s.step, s.t = "rare_setup", tick
end

-- the extractor: a rim deposit (city-state land is foreign), a hub next to it
local function rare_setup(s, tick)
  local surface = match.surface()
  local site
  for _, st in ipairs(world.sites("rare")) do
    if st.where ~= "city_state" and surface.count_entities_filtered({type = "resource", position = st.position,
                                                                     radius = 4}) > 0 then
      site = st
      break
    end
  end
  if site then
    clear(surface, {{site.position.x - 12, site.position.y - 12}, {site.position.x + 12, site.position.y + 12}})
    local ex = surface.create_entity({name = rare.EXTRACTOR, position = site.position, force = F, raise_built = true})
    local hub = ex and place("rts-hub", {x = site.position.x + 7, y = site.position.y}, F, 10)
    s.ex_un, s.ex_kind = ex and ex.valid and ex.unit_number, site.rare
    s.hub_un = hub and hub.unit_number
    util.log("age3 fx: rare extractor %s on %s at %s, hub %s", tostring(s.ex_un), tostring(site.rare),
      util.pos_str(site.position), tostring(s.hub_un))
  else
    util.log("age3 fx: no rim rare deposit generated")
  end
  -- the flow to the capital: every kind every 10 s
  local force = game.forces[F]
  s.base = {mining = force.mining_drill_productivity_bonus, lab = force.laboratory_speed_modifier,
            labp = force.laboratory_productivity_bonus, expl = force.recipes["rts-explosives"].productivity_bonus,
            steel = force.recipes["steel-plate"].productivity_bonus,
            circ = force.recipes["rts-dci-circuit"].productivity_bonus}
  s.feed_until = tick + 60 * 60
  s.step, s.t = "rare_feed", tick
end

local function feed(s, tick)
  if tick < s.feed_until and (tick - s.t) % 600 == 0 then
    for _, kind in ipairs(RB.order) do cap_net(F).insert({name = rare.PREFIX .. kind, count = 1}) end
    s.last_feed = tick
  end
end

local function rare_feed(s, tick)
  feed(s, tick)
  if tick - s.t < 30 * 60 then return end
  local force = game.forces[F]
  local b = rare.bonuses(F)
  local all = true
  for _, kind in ipairs(RB.order) do all = all and b[kind].active end
  local d_expl = force.recipes["rts-explosives"].productivity_bonus - s.base.expl
  local d_steel = force.recipes["steel-plate"].productivity_bonus - s.base.steel
  local d_circ = force.recipes["rts-dci-circuit"].productivity_bonus - s.base.circ
  local d_mine = force.mining_drill_productivity_bonus - s.base.mining
  local d_lab = force.laboratory_speed_modifier - s.base.lab
  local d_labp = force.laboratory_productivity_bonus - s.base.labp
  local tax = treasury.tax_bonus(F)
  check("rare_on", all and math.abs(d_expl - 0.25) < 1e-6 and math.abs(d_steel - 0.2) < 1e-6
    and math.abs(d_circ - 0.2) < 1e-6 and math.abs(d_mine - 0.15) < 1e-6 and math.abs(d_lab - 0.1) < 1e-6
    and math.abs(d_labp - 0.1) < 1e-6 and math.abs(tax - 0.15) < 1e-6,
    "all six on: explosives +%.2f, steel +%.2f, circuits +%.2f, mining +%.2f, lab speed +%.2f, lab prod +%.2f, tax %.2f",
    d_expl, d_steel, d_circ, d_mine, d_lab, d_labp, tax)
  local ex = s.ex_un and buildings.get(s.ex_un)
  local hub = s.hub_un and buildings.get(s.hub_un)
  local net = hub and hub.entity.logistic_network
  local item = rare.PREFIX .. tostring(s.ex_kind)
  local n = (net and net.get_item_count(item) or 0) + (storage.rare.buffers[s.ex_un or 0] and
    storage.rare.buffers[s.ex_un].n or 0)
  check("rare_extractor", ex ~= nil and n >= 2, "extractor %s on %s: %d items in the hub network after %.0f s "
    .. "(1 per %d s)", tostring(s.ex_un), tostring(s.ex_kind), n, (tick - s.t) / 60, RB.item_seconds)
  s.step = "rare_hold"
end

local function rare_hold(s, tick)
  feed(s, tick)
  if tick < s.feed_until or tick < s.last_feed + 80 * 60 then return end
  if not s.held then
    s.held = true
    local b = rare.bonuses(F)
    check("rare_grace", b.saltpetre.active and b.gold.active, "80 s after the last arrival: saltpetre %s, gold %s",
      tostring(b.saltpetre.active), tostring(b.gold.active))
  end
  if tick < s.last_feed + 92 * 60 then return end
  local force = game.forces[F]
  local b = rare.bonuses(F)
  local any = false
  for _, kind in ipairs(RB.order) do any = any or b[kind].active end
  check("rare_off", not any and math.abs(force.recipes["rts-explosives"].productivity_bonus - s.base.expl) < 1e-9
    and math.abs(force.mining_drill_productivity_bonus - s.base.mining) < 1e-9
    and math.abs(force.laboratory_speed_modifier - s.base.lab) < 1e-9 and treasury.tax_bonus(F) == 0,
    "92 s after the last arrival: any bonus on %s, explosives %.3f (start %.3f), mining %.3f (start %.3f), tax %.2f",
    tostring(any), force.recipes["rts-explosives"].productivity_bonus, s.base.expl,
    force.mining_drill_productivity_bonus, s.base.mining, treasury.tax_bonus(F))
  s.step, s.t = "nuclear_setup", tick
end

local function nuclear_setup(s, tick)
  research_now(F, "rts-chemistry")
  research_now(F, "rts-nuclear-power")
  local cap = capital(F)
  -- a Chemistry district on fuel rods in the capital
  local chem = place("rts-district-chemistry", {x = cap.position.x + 14, y = cap.position.y - 14}, F, 24)
  if chem then
    production.set_recipe(chem.unit_number, "rts-dch-fuel-rod")
    labor.pin(chem, true)
  end
  s.chem_un = chem and chem.unit_number
  cap_net(F).insert({name = "uranium-ore", count = 20})
  cap_net(F).insert({name = "steel-plate", count = 10})
  s.rods0 = cap_net(F).get_item_count(A3.nuclear.fuel)
  -- the plant on its own grid: a pole and a sink, 60 tiles from the capital, a hub for its network
  local surface = match.surface()
  local want = {x = cap.position.x + 48, y = cap.position.y}
  clear(surface, {{want.x - 16, want.y - 16}, {want.x + 16, want.y + 16}})
  local plant = place("rts-nuclear-plant", want, F, 16)
  local hub = plant and place("rts-hub", {x = plant.position.x, y = plant.position.y - 9}, F, 6)
  local sink = plant and surface.create_entity({name = "electric-energy-interface",
    position = {plant.position.x + 5, plant.position.y + 0.5}, force = F})
  local pole = plant and surface.create_entity({name = "medium-electric-pole",
    position = {plant.position.x + 3, plant.position.y - 1.5}, force = F})
  if sink then
    sink.power_production = 0
    sink.power_usage = 0
    sink.electric_buffer_size = 1e12
    sink.energy = 0
  end
  s.plant_un, s.sink = plant and plant.unit_number, sink
  s.hub2_un = hub and hub.unit_number
  util.log("age3 fx: nuclear plant %s at %s, hub %s, sink %s, pole %s", tostring(s.plant_un),
    plant and util.pos_str(plant.position) or "-", tostring(s.hub2_un), tostring(sink and sink.valid),
    tostring(pole and pole.valid))
  s.step, s.t = "nuclear_rod", tick
end

local function nuclear_rod(s, tick)
  if tick - s.t < 25 * 60 then return end
  local made = cap_net(F).get_item_count(A3.nuclear.fuel) - s.rods0
  check("fuel_rod", made >= 1, "the Chemistry district made %d fuel rod(s) from uranium ore in 25 s", made)
  -- the plant's network gets 3 rods
  local hub = s.hub2_un and buildings.get(s.hub2_un)
  local net = hub and hub.entity.logistic_network
  if net then net.insert({name = A3.nuclear.fuel, count = 3}) end
  s.step, s.t = "nuclear_warm", tick
end

local function nuclear_warm(s, tick)
  if tick - s.t < 15 * 60 then return end
  if s.sink and s.sink.valid then
    s.e0 = s.sink.energy
    s.t0 = tick
  end
  s.step = "nuclear_measure"
end

local function nuclear_measure(s, tick)
  if tick - s.t0 < 10 * 60 then return end
  local rec = s.plant_un and buildings.get(s.plant_un)
  local mw = s.sink and s.sink.valid and (s.sink.energy - s.e0) / ((tick - s.t0) / 60) / 1e6 or -1
  local fuel = rec and rec.entity.get_fuel_inventory().get_item_count(A3.nuclear.fuel) or -1
  check("nuclear_40mw", math.abs(mw - 40) < 1, "nuclear plant output %.2f MW into the sink over %.0f s, rods in it %d",
    mw, (tick - s.t0) / 60, fuel)
  -- uranium rounds: two heavies, ten magazines in the capital network
  local cap = capital(F)
  for i = 1, 2 do
    units.spawn("rts-walker-heavy", {x = cap.position.x + 20 + i * 3, y = cap.position.y + 20}, F, "heavy",
      match.surface())
  end
  s.heavy_dmg0 = game.forces[F].get_ammo_damage_modifier(RB.uranium_rounds.category)
  cap_net(F).insert({name = RB.uranium_rounds.item, count = 10})
  s.step, s.t = "rounds_on", tick
end

local function rounds_on(s, tick)
  if tick - s.t < 3 * 60 then return end
  local U = RB.uranium_rounds
  local d = game.forces[F].get_ammo_damage_modifier(U.category) - s.heavy_dmg0
  local r = storage.nations[F].rare
  check("rounds_on", r.rounds_on == true and math.abs(d - U.damage) < 1e-6,
    "10 uranium rounds magazines in the capital network, 2 heavies: bonus %s, heavy damage modifier +%.2f",
    tostring(r.rounds_on), d)
  s.step, s.t = "rounds_use", tick
end

local function rounds_use(s, tick)
  if tick - s.t < 35 * 60 then return end
  local U = RB.uranium_rounds
  local r = storage.nations[F].rare
  local left = cap_net(F).get_item_count(U.item)
  check("rounds_use", (r.rounds_used or 0) >= 1 and left == 10 - (r.rounds_used or 0) and r.rounds_on == true,
    "38 s later: %d magazine(s) used by 2 heavies (1 per heavy a minute), %d left", r.rounds_used or 0, left)
  cap_net(F).remove_item({name = U.item, count = 100})
  s.step, s.t = "rounds_off", tick
end

local function rounds_off(s, tick)
  if tick - s.t < 40 * 60 then return end
  local U = RB.uranium_rounds
  local d = game.forces[F].get_ammo_damage_modifier(U.category) - s.heavy_dmg0
  local r = storage.nations[F].rare
  check("rounds_off", not r.rounds_on and math.abs(d) < 1e-6,
    "40 s without magazines: bonus %s, modifier +%.2f, magazines used %d",
    tostring(r.rounds_on), d, r.rounds_used or 0)
  -- research rush: the current research at twice the lab speed
  research.queue(F, "rts-supply-3")
  s.lab0 = game.forces[F].laboratory_speed_modifier
  local ok, why = sinks.rush(F, "rts-supply-3")
  check("rush_research", ok and math.abs(game.forces[F].laboratory_speed_modifier - s.lab0 - (SB.rush.speed - 1)) < 1e-9,
    "rush Supply III: %s (%s), lab speed %+.2f", tostring(ok), tostring(why),
    game.forces[F].laboratory_speed_modifier - s.lab0)
  s.step, s.t = "rush_research", tick
end

local function rush_research(s, tick)
  if tick - s.t < 3 * 60 + 30 then return end
  local st = sinks.rush_state(F)
  local spent = st and st.spent or 0
  -- Phase 5 M3 integration: a research rush pays only while a lab works (nothing without one)
  local _, working = research.lab_counts(F)
  sinks.cancel_rush(F, "fixture")
  check("rush_research_charge", (working > 0) == (spent > 0)
    and math.abs(game.forces[F].laboratory_speed_modifier - s.lab0) < 1e-9,
    "3.5 s of research rush with %d working lab(s) cost %.2f cr (%.2f per missing unit and second while a lab works); "
    .. "cancelled: lab speed back %+.2f", working, spent, SB.rush.research_cr,
    game.forces[F].laboratory_speed_modifier - s.lab0)
  s.step, s.t = "hire", tick
end

local function hire(s, tick)
  local bal0 = treasury.balance(F)
  local other0 = other_expenses(F)
  local ok, why = sinks.hire_garrison(F, s.cap_city, 8)
  local g = garrison.of(s.cap_city)
  local paid = other_expenses(F) - other0
  check("hire", ok and g.hired == 8 and math.abs(paid - 8 * SB.hire.cr_per_point) < 1e-6 and g.turrets >= 2,
    "hire 8 points: %s (%s), hired %.1f, turrets %d, paid %.1f cr (balance %.0f)", tostring(ok), tostring(why),
    g.hired or 0, g.turrets or 0, paid, bal0)
  s.step, s.t = "hire_decay", tick
end

local function hire_decay(s, tick)
  if tick - s.t < 62 * 60 then return end
  local g = garrison.of(s.cap_city)
  check("hire_decay", g.hired >= 6.8 and g.hired <= 7.01, "62 s later: %.2f hired points (decay %d a minute)",
    g.hired, SB.hire.decay_per_min)
  s.step, s.t = "merc", tick
end

local function merc(s, tick)
  local ports = market.all_ports()
  local port = ports[1]
  if not port then
    if tick - s.t < 120 * 60 then return end
    check("mercenaries", false, "no trade port on the map")
    s.step, s.t = "cs", tick
    return
  end
  market.set_owner(port.un, F)
  storage.research.supply_bonus[F] = 200 -- research.apply (the techs above) reset it: room for the division
  local id, why = sinks.mercenaries(F, port.un)
  local D = id and divisions.get(id)
  local near = 0
  for _, rec in pairs(storage.units) do
    if rec.force == F and rec.entity.valid and util.distance(rec.entity.position, port.position) <= 20 then
      near = near + 1
    end
  end
  local id2, why2 = sinks.mercenaries(F, port.un)
  check("mercenaries", id ~= nil and D ~= nil and near >= 6 and id2 == nil and why2 == "cooldown",
    "port #%d: division %s (%s) with %d units within 20 tiles; a second hire: %s (%s)", port.un, tostring(id),
    tostring(why), near, tostring(id2), tostring(why2))
  s.step, s.t = "cs", tick
end

local function cs(s, tick)
  local target, good
  for _, cs_ in ipairs(sinks.city_states(F)) do
    for _, g in ipairs(cs_.goods) do
      if g.stock >= 20 then target, good = cs_, g break end
    end
    if target then break end
  end
  if not target then
    if tick - s.t < 120 * 60 then return end
    check("city_state", false, "no city-state with goods")
    s.step = "space_win"
    return
  end
  s.cs_id, s.cs_item = target.city_id, good.item
  s.cs_have0 = cap_net(F).get_item_count(good.item)
  local r0 = sinks.relation(target.city_id, F)
  local ok, cr = sinks.trade_with_city_state(F, target.city_id, good.item, 20, true)
  local r1 = sinks.relation(target.city_id, F)
  local want_price = market.price(good.item) * SB.city_state.markup
  check("city_state_buy", ok and math.abs((r1 - r0) - cr / SB.city_state.relation_cr) < 1e-6
    and math.abs(cr - 20 * want_price) < 0.01,
    "bought 20 %s from city-state %d: %s cr (%.2f each, markup %.2f), relation %.2f -> %.2f", good.item,
    target.city_id, tostring(cr), want_price, SB.city_state.markup, r0, r1)
  s.step, s.t = "cs_arrive", tick
end

local function cs_arrive(s, tick)
  if tick - s.t < 32 * 60 then return end
  local have = cap_net(F).get_item_count(s.cs_item)
  check("city_state_arrival", have - s.cs_have0 >= 20, "%s in the capital network %d -> %d 32 s after the purchase",
    s.cs_item, s.cs_have0, have)
  -- a peacetime capture of a city-state: the rival thinks 10 worse of the captor
  local r0 = diplomacy.relation(ENEMY, F)
  events.emit("rts_city_captured", {city_id = s.cs_id, from = "rts-neutral", to = F})
  local r1 = diplomacy.relation(ENEMY, F)
  check("city_state_capture", math.abs((r1 - r0) - SB.city_state.capture_penalty) < 1e-6,
    "a peacetime city-state capture by %s: %s's relation %.1f -> %.1f", F, ENEMY, r0, r1)
  s.step, s.t = "space_win", tick
end

local function space_win(s, tick)
  storage.match.config.victory = "conquest_space"
  local P0, why = age3.start(ENEMY)
  util.log("age3 fx: rival program %s (%s)", P0 and P0.state or "nil", tostring(why))
  for stage = 1, #A3.stages do age3.stage_done(ENEMY, stage) end
  local m = storage.match
  check("space_victory", m.phase == "ended" and m.victory and m.victory.how == "space" and m.winners
    and m.winners[ENEMY] == true and match.result(F) == "defeat",
    "rival completed stage 3 under conquest_space: match %s, how %s, winners %s, %s result %s", m.phase,
    tostring(m.victory and m.victory.how), m.victory and table.concat(m.victory.winners or {}, ",") or "-", F,
    tostring(match.result(F)))
  s.step = "done"
end

local function finish(s)
  s.step = "finished"
  util.log("age3 fx summary %d/%d%s", s.pass, s.pass + s.fail, s.fail == 0 and " (all passed)"
    or string.format(" (%d FAILED)", s.fail))
  for _, f in ipairs({F, ENEMY}) do
    util.log("age3 fx: %s", age3.describe(f))
    util.log("age3 fx: %s", rare.describe(f))
    util.log("age3 fx: %s", sinks.describe(f))
  end
  log("RTS_AGE3_DONE")
end

local STEPS = {stage1_pull = stage1_pull, stage1_done = stage1_done, auto_base = auto_base, auto_on = auto_on,
               auto_off = auto_off, rush_pull = rush_pull, rush_count = rush_count, stage3 = stage3,
               rare_setup = rare_setup, rare_feed = rare_feed, rare_hold = rare_hold, nuclear_setup = nuclear_setup,
               nuclear_rod = nuclear_rod, nuclear_warm = nuclear_warm, nuclear_measure = nuclear_measure,
               rounds_on = rounds_on, rounds_use = rounds_use, rounds_off = rounds_off, rush_research = rush_research,
               hire = hire, hire_decay = hire_decay, merc = merc, cs = cs, cs_arrive = cs_arrive,
               space_win = space_win}

-- the rush's spent total is read before the program completes (the rush state goes with it)
events.on_nth_tick(60, function()
  local s = storage.a3fx
  local st = s and sinks.rush_state(F)
  if st then s.rush_spent = st.spent end
end)

events.on_nth_tick(10, function(e)
  local m = storage.match
  if not (m and m.tick_started) then return end
  local s = P()
  local tick = e.tick
  if s.step == "wait" then
    if m.phase ~= "running" or tick - m.tick_started < 120 then return end
    util.log("age3 fx: started at tick %d, mode %s, victory %s", tick, tostring(m.config.mode), tostring(m.config.victory))
    check("nation_mode", ages.is_nation() and m.config.victory == "conquest_space", "mode %s, victory %s",
      tostring(m.config.mode), tostring(m.config.victory))
    setup(s)
  elseif s.step == "done" then
    finish(s)
  elseif STEPS[s.step] then
    STEPS[s.step](s, tick)
  end
end)
