-- Phase 5 M2 people fixture (test copy only; docs/qa/phase5-people-notes.md):
--   KEEP_TREE=build/p5m2-people/factorio-rts EXTRA_LUA=tools/probes/people_m2.lua STOP_ON=RTS_PEOPLE_M2_DONE \
--     DURATION_MIN=30 SEED=501 SPEED=8 tools/autotest-run.sh p5p-fixture '{opponents = 1, difficulty = "normal",
--     mode = "nation", world_size = 2048, enemy_brain = "ai"}' 2400
-- Two seconds into a Nation match both AI commanders are stopped and the probe drives rts-player by script.
-- Log lines "[rts] people m2 <check>: PASS|FAIL ...", then "[rts] people m2 summary <passed>/<total>" and the stop marker
-- RTS_PEOPLE_M2_DONE. Checks:
--   founding_40     a City Center 260+ tiles from the capital: the capital loses 40 residents, the new city has 40
--   clamp_80        a vanilla assembling machine with two rts-labor-20 modules (-1.6 speed) runs at the engine floor:
--                   speed bonus -0.8 (the probe of deep-economy.md 8.2, group C)
--   steps           a pinned Circuit works at each step (the capital's workforce set by script): crafting speed and the
--                   module in its slot follow 0.8 / 0.6 / 0.4 / 0.2
--   staffing_60     two Circuit works on cable (2 s, fed from the network), A at 100 %, B at 60 %: B makes 0.60 +- 0.02 of
--                   A's output over 60 s (products_finished + crafting_progress)
--   no_workers_0    a lab left without workers is disabled by script with the custom status "No workers"
--   no_recruits     draft 0 and no unemployed worker: a walker kit stays in a barracks with reason "recruits"
--   recruit_ok      draft 50 %: the kit deploys and the city has one resident less
--   disband_release labor.disband on that walker: its recruit returns to the city (one resident more)
--   starve_residents rations stop (the network emptied, no more top-ups): the capital loses residents within 2 minutes
--   starve_stop     ... and the lowest-priority building that ran stops ("No workers") within 2 minutes
--   starve_recover  rations come back: within 150 s that building runs again and the residents grow
--   growth_town     the new city (24 houses, rations and goods topped up) reaches town by 10:00 match time
--   growth_city     ... and city by 25:00
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local match = require("scripts.match")
local ages = require("scripts.ages")
local cities = require("scripts.cities")
local territory = require("scripts.territory")
local population = require("scripts.population")
local labor = require("scripts.labor")

local F, ENEMY = util.PLAYER_FORCE, util.ENEMY_FORCE
local WF = require("balance").nation.people.workforce
local TOWN_DEADLINE = 10 * 60 * 60
local CITY_DEADLINE = 25 * 60 * 60

local function P()
  storage.pm2 = storage.pm2 or {pass = 0, fail = 0, step = "wait", done = {}}
  return storage.pm2
end

local function check(name, ok, fmt, ...)
  local s = P()
  if s.done[name] then return end
  s.done[name] = true
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("people m2 %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function clear(surface, area)
  for _, e in pairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "fish"}})) do
    e.destroy()
  end
end

local function place(surface, name, want, radius, force)
  local pos = surface.find_non_colliding_position(name, want, radius or 20, 1, true)
  if not pos then
    util.log("people m2: no room for %s near %s", name, util.pos_str(want))
    return nil
  end
  local e = surface.create_entity({name = name, position = pos, force = force or F, raise_built = true})
  if not e then util.log("people m2: could not place %s at %s", name, util.pos_str(pos)) end
  return e
end

local function capital()
  local n = storage.nations and storage.nations[F]
  return n and cities.get(n.capital)
end

local function net_of(c)
  local e = c and c.entity
  local net = e and e.valid and e.logistic_network
  return (net and net.valid) and net or nil
end

local function top_up(c, item, n)
  local net = net_of(c)
  if not net then return 0 end
  local have = net.get_item_count(item)
  if have < n then return net.insert({name = item, count = n - have}) end
  return 0
end

local function crafts(e)
  return e.products_finished + (e.is_crafting() and e.crafting_progress or 0)
end

local function minute_str(tick)
  local m = storage.match
  local t = (tick - (m.tick_started or 0)) / 60
  return string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60))
end

---------------------------------------------------------------------------
-- Founding and the growth city
---------------------------------------------------------------------------
local function found_city(s)
  local c = capital()
  local surface = match.surface()
  local cp = population.get(c.id)
  cp.pop = 120
  local before = cp.pop
  -- a spot 260+ tiles out, away from the enemy, on land the City Center may take
  local enemy = storage.nations[ENEMY] and cities.get(storage.nations[ENEMY].capital)
  local dx, dy = 0, 1
  if enemy then
    dx, dy = c.position.x - enemy.position.x, c.position.y - enemy.position.y
    local len = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / len, dy / len
  end
  local site
  for _, deg in ipairs({90, -90, 60, -60, 120, -120, 30, -30, 0, 150, -150}) do
    local a = math.rad(deg)
    local rx, ry = dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a)
    for _, d in ipairs({260, 300, 340, 220}) do
      local want = {x = c.position.x + rx * d, y = c.position.y + ry * d}
      local p = surface.find_non_colliding_position("rts-city-center", want, 30, 1, true)
      if p and territory.can_build(F, "rts-city-center", p) then
        local half = (storage.world and storage.world.size or 2048) / 2 - 80
        if math.abs(p.x) < half and math.abs(p.y) < half then
          site = p
          break
        end
      end
    end
    if site then break end
  end
  if not site then
    check("founding_40", false, "no site for a second city")
    return nil
  end
  clear(surface, {{site.x - 40, site.y - 40}, {site.x + 40, site.y + 40}})
  local id = cities.found(F, site, {why = "(people fixture)"})
  local nc = id and cities.get(id)
  local np = id and population.get(id)
  check("founding_40", np ~= nil and math.abs(np.pop - 40) < 0.01 and math.abs(cp.pop - (before - 40)) < 0.01,
    "capital %d -> %d, new city %s with %s residents at %s, %.0f tiles out", before, math.floor(cp.pop), tostring(id),
    np and tostring(math.floor(np.pop)) or "-", util.pos_str(site), util.distance(site, c.position))
  if not nc then return nil end
  territory.flush()
  -- 24 houses on its land
  local n = 0
  for i = 0, 5 do
    for j = 0, 3 do
      local want = {x = site.x - 22 + i * 7, y = site.y + 8 + j * 5}
      local e = place(surface, "rts-house", want, 6)
      if e and territory.city_at(e.position) == id then n = n + 1 elseif e then e.destroy() end
    end
  end
  s.growth = {city = id, houses = n, founded = game.tick}
  util.log("people m2: growth city %d with %d houses, housing %d", id, n, population.housing(id))
  return id
end

local function growth_tick(s, tick)
  local g = s.growth
  if not g or g.over then return end
  local c = cities.get(g.city)
  if not c then
    check("growth_town", false, "the growth city is gone")
    check("growth_city", false, "the growth city is gone")
    g.over = true
    return
  end
  top_up(c, "rts-rations", 400)
  top_up(c, "rts-goods", 200)
  local age = tick - storage.match.tick_started
  if c.tier >= 2 and not g.town then
    g.town = tick
    check("growth_town", age <= TOWN_DEADLINE, "town at %s match time (deadline 10:00); %s", minute_str(tick),
      population.describe(c.id))
  end
  if c.tier >= 3 and not g.city_at then
    g.city_at = tick
    check("growth_city", age <= CITY_DEADLINE, "city at %s match time (deadline 25:00); %s", minute_str(tick),
      population.describe(c.id))
    g.over = true
  end
  if age > CITY_DEADLINE + 60 and not g.city_at then
    if not g.town then check("growth_town", false, "no town by 25:00; %s", population.describe(c.id)) end
    check("growth_city", false, "no city by 25:00; %s", population.describe(c.id))
    g.over = true
  end
end

---------------------------------------------------------------------------
-- Labor at the capital
---------------------------------------------------------------------------
local function setup_labor(s)
  local c = capital()
  local surface = match.surface()
  local cx, cy = c.position.x, c.position.y
  ages.set_age(F, 2, "people fixture") -- the district recipes
  clear(surface, {{cx - 30, cy - 30}, {cx + 30, cy + 30}})
  -- power island: substation + an energy interface
  local sub = place(surface, "substation", {x = cx + 12, y = cy - 12}, 10)
  local eei = sub and place(surface, "electric-energy-interface", {x = sub.position.x + 2, y = sub.position.y}, 6)
  if eei then
    eei.power_production = 20e6 / 60
    eei.electric_buffer_size = 20e6
  end
  local a = place(surface, "rts-district-circuits", {x = cx + 12, y = cy - 4}, 10)
  local b = place(surface, "rts-district-circuits", {x = cx + 18, y = cy - 4}, 10)
  local lab = place(surface, "rts-lab", {x = cx - 12, y = cy - 12}, 10)
  if not (a and b and lab) then
    check("steps", false, "could not place the districts and the lab")
    return false
  end
  for _, e in ipairs({a, b}) do production.set_recipe(e, "rts-dci-cable") end
  labor.pin(a, true)
  labor.pin(b, true)
  local net = net_of(c)
  if net then net.insert({name = "copper-plate", count = 5000}) end
  s.a, s.b, s.lab = a.unit_number, b.unit_number, lab.unit_number
  -- the clamp: a vanilla machine with two -0.8 labor modules
  local vm = place(surface, "assembling-machine-2", {x = cx - 12, y = cy + 12}, 10)
  if vm then
    vm.set_recipe("iron-gear-wheel")
    local inv = vm.get_module_inventory()
    local put = inv and inv.insert({name = "rts-labor-20", count = 2}) or 0
    s.vm = vm
    s.vm_put = put
  end
  return true
end

-- Set the capital's residents so its workforce is exactly w (fed, so all of it works), then restaff.
local function set_workforce(c, w)
  local cp = population.get(c.id)
  cp.pop = (w + 0.5) / WF
  for _, N in pairs(cp.needs) do N.met = 1 end
  labor.step_city(c.id)
end

local function hold_capital(s)
  local c = capital()
  if not c then return end
  top_up(c, "rts-rations", 300)
  top_up(c, "rts-goods", 200)
  top_up(c, "copper-plate", 3000)
  if s.hold_w then
    local cp = population.get(c.id)
    cp.pop = (s.hold_w + 0.5) / WF
    for _, N in pairs(cp.needs) do N.met = 1 end
  end
end

local STEP_W = {{w = 29, step = 0.8}, {w = 26, step = 0.6}, {w = 23, step = 0.4}, {w = 20, step = 0.2}}

local function steps_tick(s, tick)
  local c = capital()
  s.si = s.si or 0
  if s.si == 0 then
    s.si, s.st = 1, tick
    s.hold_w = STEP_W[1].w
    set_workforce(c, s.hold_w)
    s.step_log = {}
    return
  end
  if tick - s.st < 120 then return end
  local b = buildings.get(s.b)
  local want = STEP_W[s.si]
  local e = b and b.entity
  local inv = e and e.get_module_inventory()
  local module = inv and not inv.is_empty() and inv[1].name or "none"
  local ok = e ~= nil and math.abs(labor.staffing(e) - want.step) < 1e-6 and math.abs(e.crafting_speed - want.step) < 0.005
    and module == ("rts-labor-" .. math.floor(want.step * 100 + 0.5))
  s.step_log[#s.step_log + 1] = string.format("%d%%: staffing %.2f speed %.3f module %s consumption %+.2f", want.step * 100,
    e and labor.staffing(e) or -1, e and e.crafting_speed or -1, module, e and e.consumption_bonus or 0)
  s.steps_ok = (s.steps_ok ~= false) and ok
  s.si = s.si + 1
  if s.si > #STEP_W then
    check("steps", s.steps_ok, "%s", table.concat(s.step_log, "; "))
    -- clamp of the vanilla machine
    local vm = s.vm
    check("clamp_80", vm and vm.valid and s.vm_put == 2 and math.abs(vm.speed_bonus + 0.8) < 1e-6,
      "vanilla assembling-machine-2 with %d x rts-labor-20 (-1.6): speed bonus %.3f, crafting speed %.3f "
      .. "(0.75 x 0.2 = 0.150 at the -80 %% floor)", s.vm_put or 0, vm and vm.valid and vm.speed_bonus or 0,
      vm and vm.valid and vm.crafting_speed or 0)
    -- the 60 % measurement
    s.hold_w = 26
    set_workforce(c, s.hold_w)
    s.step = "measure"
    s.m0 = nil
    s.st = tick
    return
  end
  s.st = tick
  s.hold_w = STEP_W[s.si].w
  set_workforce(c, s.hold_w)
end

local function measure_tick(s, tick)
  local a, b = buildings.get(s.a), buildings.get(s.b)
  if not (a and b) then
    check("staffing_60", false, "a district is gone")
    s.step = "recruits"
    return
  end
  if not s.m0 then
    if tick - s.st < 300 then return end -- let both settle (inputs pulled, crafts running)
    s.m0 = {a = crafts(a.entity), b = crafts(b.entity), tick = tick}
    return
  end
  if tick - s.m0.tick < 3600 then return end
  local da, db = crafts(a.entity) - s.m0.a, crafts(b.entity) - s.m0.b
  local ratio = da > 0 and db / da or 0
  check("staffing_60", math.abs(ratio - 0.6) <= 0.02 and labor.staffing(b.entity) == 0.6 and labor.staffing(a.entity) == 1,
    "60 s: A (100 %%) %.2f crafts, B (60 %%) %.2f crafts, ratio %.3f; B speed %.3f consumption %+.2f, A speed %.3f",
    da, db, ratio, b.entity.crafting_speed, b.entity.consumption_bonus, a.entity.crafting_speed)
  local lab = buildings.get(s.lab)
  local e = lab and lab.entity
  local cs = e and e.custom_status
  check("no_workers_0", e ~= nil and labor.staffing(e) == 0 and e.disabled_by_script == true and cs ~= nil
    and cs.label[1] == "rts-people.status-no-workers" and e.status == defines.entity_status.disabled_by_script,
    "lab #%s staffing %s, disabled_by_script %s, custom status %s, status %s", tostring(s.lab),
    e and tostring(labor.staffing(e)) or "-", e and tostring(e.disabled_by_script) or "-",
    cs and serpent.line(cs.label) or "nil", e and tostring(util.define_name(defines.entity_status, e.status)) or "-")
  s.step = "recruits"
end

---------------------------------------------------------------------------
-- Recruits
---------------------------------------------------------------------------
local function recruits_tick(s, tick)
  local c = capital()
  local surface = match.surface()
  if not s.rb then
    -- the districts take every worker: workforce 26 = 16 + 9.6 + 0.4 left, no unemployed; draft 0
    s.hold_w = 26
    set_workforce(c, 26)
    population.set_draft(c.id, 0)
    local bar = place(surface, "rts-barracks", {x = c.position.x - 14, y = c.position.y + 2}, 12)
    if not bar then
      check("no_recruits", false, "no barracks")
      s.step = "starve_prep"
      return
    end
    -- the kit recipe gives the barracks its output slot; with no worker (the districts take them all) it makes no
    -- more kits, and the one put into its output waits for a recruit
    production.set_recipe(bar, "rts-walker-kit")
    local put = bar.get_output_inventory().insert({name = "rts-walker-kit", count = 1})
    util.log("people m2: barracks #%d with %d walker kit in its output", bar.unit_number, put)
    s.rb, s.rt = bar.unit_number, tick
    labor.step_city(c.id)
    return
  end
  local rec = buildings.get(s.rb)
  if not rec then
    s.step = "starve_prep"
    return
  end
  local out = rec.entity.get_output_inventory()
  if not s.refused then
    if tick - s.rt < 240 then return end
    local block = rec.surcharge_block
    local kits = out.get_item_count("rts-walker-kit")
    check("no_recruits", kits == 1 and block ~= nil and block.reason == "recruits",
      "kit in the output %d, block %s, recruits %d (%s)", kits, block and block.reason or "none",
      labor.recruits(c.id), labor.describe(c.id))
    s.refused = true
    s.pop_before = population.get(c.id).pop
    s.hold_w = nil -- the next kit may change the residents
    population.set_draft(c.id, 0.5)
    labor.step_city(c.id)
    s.rt = tick
    return
  end
  if tick - s.rt < 240 then return end
  local kits = out.get_item_count("rts-walker-kit")
  local cp = population.get(c.id)
  check("recruit_ok", kits == 0 and rec.surcharge_block == nil and math.abs((s.pop_before - cp.pop) - 1) < 0.05,
    "draft 50 %%: kit left the output (%d left), residents %.2f -> %.2f, drafted %d", kits, s.pop_before, cp.pop,
    cp.drafted)
  -- the new walker remembers its home city; disbanding it gives the recruit back
  local soldier
  for un, r in pairs(storage.labor.soldiers) do
    if r.city == c.id and (not soldier or un > soldier) then soldier = un end
  end
  local before = cp.pop
  local home, n = labor.home_of(soldier or 0)
  local ok = soldier and labor.disband(soldier)
  check("disband_release", ok and home == c.id and n == 1 and math.abs(cp.pop - before - 1) < 0.05,
    "walker #%s home city %s (%s recruit), disbanded: residents %.2f -> %.2f", tostring(soldier), tostring(home),
    tostring(n), before, cp.pop)
  s.step = "starve_prep"
end

---------------------------------------------------------------------------
-- Starvation at the capital
---------------------------------------------------------------------------
-- The building ranked last among those that run (step > 0), and the steps of every staffed one.
local function lowest_running(c)
  local st = labor.city_stats(c.id)
  local order = st.order or {}
  for i = #order, 1, -1 do
    local rec = buildings.get(order[i])
    if rec and labor.staffing(rec.entity) > 0 then return order[i], rec end
  end
  return nil
end

local function starve_tick(s, tick)
  local c = capital()
  local cp = population.get(c.id)
  if s.step == "starve_prep" then
    -- districts out (they took the workforce in the tests above); residents 120, fed for a while
    for _, un in ipairs({s.a, s.b}) do
      local rec = buildings.get(un)
      if rec then rec.entity.destroy({raise_destroy = true}) end
    end
    s.hold_w = nil
    cp.pop = 120
    population.set_draft(c.id, 0.2)
    -- enough jobs that half the workforce cannot staff them all: factories (services, ranked last) until 80 jobs
    local surface = match.surface()
    local st = labor.step_city(c.id) or {}
    local k = 0
    while (st.jobs or 0) < 80 and k < 8 do
      k = k + 1
      place(surface, "rts-factory", {x = c.position.x - 18 + k * 4, y = c.position.y + 14}, 12)
      st = labor.step_city(c.id) or {}
    end
    util.log("people m2: starvation set-up: %d factories added, %s", k, labor.describe(c.id))
    s.st = tick
    s.step = "starve_fed"
    return
  end
  if s.step == "starve_fed" then
    top_up(c, "rts-rations", 300)
    if tick - s.st < 150 * 60 then return end -- two needs ticks fed
    labor.step_city(c.id)
    local un = lowest_running(c)
    s.low_un = un
    s.pop0 = cp.pop
    s.stopped0 = labor.city_stats(c.id).stopped or 0
    -- the cut: no more top-ups, the network's rations gone
    local net = net_of(c)
    local gone = net and net.remove_item({name = "rts-rations", count = 100000}) or 0
    util.log("people m2: rations cut at %s: %d removed, residents %.1f, lowest running building #%s, %s",
      minute_str(tick), gone, cp.pop, tostring(un), labor.describe(c.id))
    s.cut = tick
    s.step = "starve_cut"
    return
  end
  if s.step == "starve_cut" then
    local net = net_of(c)
    if net then net.remove_item({name = "rts-rations", count = 100000}) end -- haulers or the bakery may bring some
    local rec = s.low_un and buildings.get(s.low_un)
    local stopped = rec and labor.staffing(rec.entity) == 0
    if not s.pop_lost_at and cp.pop < s.pop0 - 0.5 then s.pop_lost_at = tick end
    if not s.stop_at and stopped then s.stop_at = tick end
    if tick - s.cut >= 120 * 60 then
      check("starve_residents", s.pop_lost_at ~= nil and s.pop_lost_at - s.cut <= 120 * 60,
        "residents %.1f -> %.1f, first one lost %s s after the cut", s.pop0, cp.pop,
        s.pop_lost_at and string.format("%.0f", (s.pop_lost_at - s.cut) / 60) or "never")
      check("starve_stop", s.stop_at ~= nil,
        "lowest running building #%s (%s) stopped %s s after the cut; stopped buildings %d -> %d; %s",
        tostring(s.low_un), rec and rec.entity.name or "-",
        s.stop_at and string.format("%.0f", (s.stop_at - s.cut) / 60) or "never", s.stopped0,
        labor.city_stats(c.id).stopped or 0, population.describe(c.id))
      s.step = "starve_back"
      s.back = tick
      s.pop_back = cp.pop
    end
    return
  end
  if s.step == "starve_back" then
    top_up(c, "rts-rations", 300)
    local rec = s.low_un and buildings.get(s.low_un)
    local runs = rec and labor.staffing(rec.entity) > 0
    if runs and not s.run_at then s.run_at = tick end
    if tick - s.back >= 150 * 60 then
      check("starve_recover", s.run_at ~= nil and cp.pop > s.pop_back,
        "food back: building #%s runs again %s s later, residents %.1f -> %.1f; %s", tostring(s.low_un),
        s.run_at and string.format("%.0f", (s.run_at - s.back) / 60) or "never", s.pop_back, cp.pop,
        population.describe(c.id))
      s.step = "wait_growth"
    end
  end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------
local function finish(s)
  s.step = "finished"
  util.log("people m2 summary %d/%d%s", s.pass, s.pass + s.fail, s.fail == 0 and " (all passed)"
    or string.format(" (%d FAILED)", s.fail))
  for id in pairs(storage.population or {}) do util.log("people m2: %s", population.describe(id)) end
  log("RTS_PEOPLE_M2_DONE")
end

events.on_nth_tick(10, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = P()
  local tick = e.tick
  if s.step == "finished" then return end
  if s.step == "wait" then
    if tick - m.tick_started < 120 then return end
    ai.stop_force(F)
    ai.stop_force(ENEMY)
    util.log("people m2: started at tick %d, mode %s", tick, tostring(m.config.mode))
    check("nation_mode", territory.nation(), "mode %s", tostring(m.config.mode))
    found_city(s)
    if setup_labor(s) then s.step = "steps" else s.step = "recruits" end
    return
  end
  growth_tick(s, tick)
  hold_capital(s)
  if s.step == "steps" then
    steps_tick(s, tick)
  elseif s.step == "measure" then
    measure_tick(s, tick)
  elseif s.step == "recruits" then
    recruits_tick(s, tick)
  elseif string.sub(s.step, 1, 7) == "starve_" then
    starve_tick(s, tick)
  elseif s.step == "wait_growth" then
    if not s.growth or s.growth.over then finish(s) end
  end
end)
