-- Phase 5 M3 age3: Age III and the Space Program, automation kits, the nuclear plant (docs/PHASE5-M3.md D1, D2, §3
-- "age3.lua / rare.lua / sinks.lua"; study docs/research/scale/deep-economy.md §2.5, §5.6, §9.3; notes
-- docs/qa/phase5-age3-notes.md). Nation mode only: in Skirmish nothing here runs and every Age III recipe stays off.
--
--   age3.project(force) -> {stage = 1|2|3, required = {[item] = n}, delivered = {...}, site, state, ...} | nil
--   age3.can_start(force) -> ok, reason      ("mode" | "age" | "research" | "running" | "complete")
--   age3.start(force, position?) -> project | nil, reason   ("no-spot" | "blocked" | a can_start reason)
--   age3.stage_done(force, stage)            internal: stage 1 -> Age III (ages.set_age) and signal "rts_age_up"
--                                            {force, age = 3}; stage 3 -> signal "rts_space_victory" {force, winners}
--                                            (scripts/match.lua ends the match when the victory mode allows it)
--   age3.automate(city_id, family, on) -> ok, reason   policy "automate <family>" of a city
--   age3.automation(city_id) -> {[family] = {on, kits, buildings, jobs_cut}}
--   age3.progress(project) -> 0..1;  age3.missing(force) -> {[item] = n} | nil (the running stage's missing goods)
--   age3.describe(force) -> one log line
--
-- Space Program. Research Electrification (Age II, industrial kits) lets a nation in Age II place the 8x8 Launch complex
-- next to its capital (the ledger's Start button, or age3.start). Every PERIOD ticks the complex takes up to
-- pull_per_second of each good of the running stage from the logistic network it stands in; when the stage's list is
-- delivered its countdown runs (build_seconds), then the stage is done and the next stage's list starts at the same
-- site. Stage 1 (structure: steel, concrete, advanced circuits) brings Age III; stage 2 (systems: processing units,
-- batteries, engines); stage 3 (fuel: rocket fuel, sulfur, light oil in barrels) is the launch. A destroyed complex
-- loses raze_loss of the running stage's deliveries (finished stages stay); a new complex resumes. Progress is drawn
-- over the complex for every force. sinks.lua's Rush doubles the pull and the countdown (age3.rush_factor).
--
-- Age III. Every recipe of balance.nation.age3.recipes / .buildings without a `tech` is enabled for a force when it
-- reaches Age III (scripts/ages.lua MAX_AGE is 3); Chemistry (batteries, rocket fuel), Nuclear power (the nuclear
-- plant, fuel rods) and Geology (the rare extractor, any age) unlock theirs through scripts/research.lua.
--
-- Automation kits (D2). A city's policy "automate <family>" (the ledger's Automation buttons) makes the kit pass (every
-- kit.period ticks per city, staggered) put up to kit.per_building kits from the city's network into every district of
-- that family on its land (module slots 2 and 3), and take them back out when the policy is off, the nation is below
-- Age III or the city changed hands. Each kit cuts the building's jobs by kit.job_cut (scripts/labor.lua reads
-- labor.job_factor), so 2 kits make 0.49 of the jobs and the same output.
--
-- Nuclear plant: every nuclear.period ticks its burner gets up to nuclear.keep fuel rods from its network (one rod a
-- minute at 40 MW).
--
-- State: storage.nations[force].age3 = {program = P, automate = {[city_id] = {[family] = true}}} (contract key), P =
-- {stage, required, delivered, state = "building"|"countdown"|"razed"|"complete", site, site_un, position, started,
-- stage_started, countdown_until, done = {[stage] = tick}, razed}; storage.age3 = {kits = {[unit_number] = n},
-- kit_city = {[unit_number] = city_id}, render = {[force] = {bg, fg, text}}, stats}. Cleared at match teardown.
-- Log lines "[rts] age3: ...". Console: /rts-age3 [force] [start | stage <n> | automate <city> <family> on|off].
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local research = require("scripts.research")
local supply = require("scripts.supply")
local match = require("scripts.match")
local ages = require("scripts.ages")
local cities = require("scripts.cities")
local population = require("scripts.population")
local labor = require("scripts.labor")
local treasury = require("scripts.treasury")
local ledgergui = require("scripts.ledgergui")
local hud = require("scripts.hud")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local A3 = balance.nation.age3
local KIT = A3.kit

local age3 = {}

age3.SITE = A3.site.name
age3.PERIOD = A3.period
age3.NUCLEAR = "rts-nuclear-plant"
age3.KIT = KIT.item
age3.FUEL = A3.nuclear.fuel
age3.STAGES = A3.stages
age3.FAMILIES = KIT.families
age3.rush_factor = nil -- fn(force_name) -> 1 | speed; scripts/sinks.lua sets it
age3.sinks = nil       -- scripts/sinks.lua sets itself here (ledger Rush button)
age3.ledger_lines = {} -- fn(force_name) -> LocalisedString | nil; extra ledger lines (scripts/rare.lua)
local FAMILY_OK = {}
for _, f in ipairs(KIT.families) do FAMILY_OK[f] = true end

---------------------------------------------------------------------------
-- Registry, technologies, recipes (load time; static data)
---------------------------------------------------------------------------
for name, b in pairs(A3.buildings) do buildings.KIND_BY_NAME[name] = b.kind end
buildings.KIND_BY_NAME[age3.SITE] = "project"
for name in pairs(A3.buildings) do treasury.AGE2[name] = true end -- upkeep at the Age II rate

for _, t in ipairs(A3.techs) do
  research.EFFECTS[t.name] = {flag = t.effect.flag}
  research.NATION_ONLY[t.name] = true
  if t.age and t.age > 1 then research.AGE_REQUIRED[t.name] = t.age end
end

local function sorted_keys(t)
  local list = {}
  for k in pairs(t) do list[#list + 1] = k end
  table.sort(list)
  return list
end

-- A recipe a technology unlocks: research.apply enables it per force (prototype disabled + research.LOCKS).
local function lock(name, tech)
  local eff = research.EFFECTS[tech]
  if not eff then
    eff = {}
    research.EFFECTS[tech] = eff
  end
  eff.unlock = eff.unlock or {}
  eff.unlock[#eff.unlock + 1] = name
  research.LOCKS[name] = tech
end

age3.AGE3_RECIPES = {}
for _, name in ipairs(sorted_keys(A3.recipes)) do
  local tech = A3.recipes[name].tech
  if tech then lock(name, tech) else age3.AGE3_RECIPES[#age3.AGE3_RECIPES + 1] = name end
end
for _, name in ipairs(sorted_keys(A3.buildings)) do
  local tech = A3.buildings[name].tech
  if tech then lock(name, tech) else age3.AGE3_RECIPES[#age3.AGE3_RECIPES + 1] = name end
end
table.sort(age3.AGE3_RECIPES)
for _, name in ipairs(age3.AGE3_RECIPES) do research.AGE_LOCKS[name] = "rts-age-3" end -- HUD: "locked: Age III"

-- HUD (scripts/hud.lua exports P4): the Age III items are Nation-only, the rts-age3 factory recipes sit on the
-- intermediates tab, the alert styles of this package
local P4 = hud.P4
if P4 then
  for _, name in ipairs({age3.KIT, age3.FUEL, "rts-rare-extractor", age3.NUCLEAR}) do P4.NATION_ONLY[name] = true end
  local base_tab = P4.recipe_tab
  P4.recipe_tab = function(r)
    if r.category == "rts-age3" then return "intermediates" end
    return base_tab(r)
  end
  P4.ALERT_STYLE["space-started"] = {icons = {"item/rocket-fuel", "utility/check_mark_green"}, color = "green"}
  P4.ALERT_STYLE["space-stage"] = {icons = {"item/processing-unit", "utility/check_mark_green"}, color = "green"}
  P4.ALERT_STYLE["space-razed"] = {icons = {"item/rocket-fuel", "utility/danger_icon"}, color = "red",
                                   sound = "utility/alert_destroyed"}
  P4.ALERT_STYLE["space-launch"] = {icons = {"item/rocket-fuel", "utility/warning_icon"}, color = "yellow"}
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.age3
  if not s then
    s = {}
    storage.age3 = s
  end
  s.kits = s.kits or {}
  s.kit_city = s.kit_city or {}
  s.render = s.render or {}
  s.stats = s.stats or {kits_in = 0, kits_out = 0, rods = 0}
  return s
end

function age3.init() S() end

local function nation_mode() return ages.is_nation() end

--- storage.nations[force].age3 (created when `create` and the nation exists), or nil.
local function N(force_name, create)
  local nations = storage.nations
  local n = nations and nations[force_name]
  if not n then
    if not (create and nations and match.is_participant(force_name)) then return nil end
    n = {age = ages.of(force_name)}
    nations[force_name] = n
  end
  local s = n.age3
  if not s and create then
    s = {automate = {}}
    n.age3 = s
  end
  return s
end
age3.state = N

function age3.project(force_name)
  local s = N(force_name)
  return s and s.program or nil
end

local function progress(P)
  local need, have = 0, 0
  for item, n in pairs(P.required) do
    need = need + n
    have = have + math.min(n, P.delivered[item] or 0)
  end
  return need > 0 and have / need or 1
end
age3.progress = progress

--- The running stage's goods still missing {[item] = n} (an AI's make targets), or nil when no stage is running.
function age3.missing(force_name)
  local P = age3.project(force_name)
  if not (P and (P.state == "building" or P.state == "razed")) then return nil end
  local out = {}
  for item, n in pairs(P.required) do
    local left = n - (P.delivered[item] or 0)
    if left > 0 then out[item] = left end
  end
  return out
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function clock(ticks)
  local m = storage.match
  local secs = (m and m.tick_started) and (ticks - m.tick_started) / 60 or ticks / 60
  return string.format("%d:%02d", math.floor(secs / 60), math.floor(secs % 60))
end

---------------------------------------------------------------------------
-- Age III recipes
---------------------------------------------------------------------------
local function set_recipes(force, on)
  if not (force and force.valid) then return end
  local recipes = force.recipes
  for _, name in ipairs(age3.AGE3_RECIPES) do
    local r = recipes[name]
    if r and r.enabled ~= on then r.enabled = on end
  end
end

ages.on_age_changed(function(force_name, age)
  set_recipes(game.forces[force_name], age >= 3)
end)

---------------------------------------------------------------------------
-- Rendering (every force sees every nation's complex)
---------------------------------------------------------------------------
local BAR_W, BAR_Y = 8, -4.6

local function destroy_render(force_name)
  local s = S()
  for _, obj in pairs(s.render[force_name] or {}) do
    if obj.valid then obj.destroy() end
  end
  s.render[force_name] = nil
end

local function label_of(P)
  local n = #A3.stages
  if P.state == "countdown" then
    local left = math.max(0, math.ceil((P.countdown_until - game.tick) / 60))
    if P.stage >= n then return {"rts-age3.site-launch", left} end
    return {"rts-age3.site-countdown", P.stage, n, left}
  end
  if P.state == "complete" then return {"rts-age3.site-complete"} end
  return {"rts-age3.site-label", P.stage, n, math.floor(progress(P) * 100)}
end

local function update_render(force_name, P)
  local site = P.site
  if not (site and site.valid) then return end
  local s = S()
  local r = s.render[force_name]
  if not (r and r.fg and r.fg.valid and r.text and r.text.valid) then
    destroy_render(force_name)
    local surface = site.surface
    r = {
      bg = rendering.draw_rectangle({color = {0, 0, 0, 0.7}, filled = true, surface = surface,
        left_top = {entity = site, offset = {-BAR_W / 2 - 0.1, BAR_Y - 0.1}},
        right_bottom = {entity = site, offset = {BAR_W / 2 + 0.1, BAR_Y + 0.5}}}),
      fg = rendering.draw_rectangle({color = {0.3, 0.75, 1, 0.9}, filled = true, surface = surface,
        left_top = {entity = site, offset = {-BAR_W / 2, BAR_Y}},
        right_bottom = {entity = site, offset = {-BAR_W / 2, BAR_Y + 0.4}}}),
      text = rendering.draw_text({text = "", surface = surface, target = {entity = site, offset = {0, BAR_Y - 0.9}},
        color = {0.7, 0.9, 1}, scale = 1.5, alignment = "center", vertical_alignment = "middle"}),
    }
    s.render[force_name] = r
  end
  local f = P.state == "building" and progress(P) or 1
  r.fg.right_bottom = {entity = site, offset = {-BAR_W / 2 + BAR_W * f, BAR_Y + 0.4}}
  r.fg.color = P.state == "countdown" and {0.3, 0.9, 0.3, 0.9} or {0.3, 0.75, 1, 0.9}
  r.text.text = label_of(P)
end

---------------------------------------------------------------------------
-- Space Program
---------------------------------------------------------------------------
--- Whether the force may start (or resume) the Space Program now: ok, reason.
function age3.can_start(force_name)
  if not nation_mode() then return false, "mode" end
  if ages.of(force_name) < 2 then return false, "age" end
  if not research.has(force_name, A3.tech) then return false, "research" end
  local P = age3.project(force_name)
  if P and P.state == "complete" then return false, "complete" end
  if P and P.site and P.site.valid and P.state ~= "razed" then return false, "running" end
  return true
end

--- A free spot for the Launch complex near the capital, inside a logistic network of the force, or nil.
function age3.site_position(force_name)
  local cap = ages.capital(force_name)
  local surface = match.surface()
  if not (cap and surface) then return nil end
  local force = game.forces[force_name]
  local front = match.front and match.front(force_name) or {x = 1, y = 0}
  local dirs = {{-front.x, -front.y}, {-front.y, front.x}, {front.y, -front.x}, {front.x, front.y}}
  for _, d in ipairs(A3.site.distances) do
    for _, v in ipairs(dirs) do
      local want = {x = math.floor(cap.position.x + v[1] * d) + 0.0, y = math.floor(cap.position.y + v[2] * d) + 0.0}
      local pos = surface.find_non_colliding_position(age3.SITE, want, 8, 1, true)
      if pos and surface.find_logistic_network_by_position(pos, force) then return pos end
    end
  end
  return nil
end

local function alert_others(force_name, key, ...)
  for _, f in pairs(game.forces) do
    if f.name ~= force_name and match.is_participant(f.name) then
      f.print({key, match.label(force_name), ...})
    end
  end
end

function age3.start(force_name, position)
  local ok, why = age3.can_start(force_name)
  if not ok then
    if why == "running" then return age3.project(force_name), why end
    return nil, why
  end
  local surface = match.surface()
  local pos = position or age3.site_position(force_name)
  if not (surface and pos) then return nil, "no-spot" end
  local site = surface.create_entity({name = age3.SITE, position = pos, force = force_name})
  if not site then return nil, "blocked" end
  buildings.register(site)
  local s = N(force_name, true)
  local P = s.program
  if not P then
    P = {stage = 1, required = copy(A3.stages[1].required), delivered = {}, started = game.tick,
         stage_started = game.tick, done = {}}
    s.program = P
  end
  P.site, P.site_un, P.state = site, site.unit_number, "building"
  P.position = {x = site.position.x, y = site.position.y}
  update_render(force_name, P)
  local has_net = surface.find_logistic_network_by_position(site.position, site.force) ~= nil
  util.log("age3: %s started the Space Program (stage %d) at %s at %s (%s, %.0f%% of the stage delivered)", force_name,
    P.stage, util.pos_str(site.position), clock(game.tick), has_net and "in a logistic network" or "NO logistic network",
    progress(P) * 100)
  supply.alert(force_name, "space-started", "rts-age3.alert-started", {P.stage}, site.position)
  alert_others(force_name, "rts-age3.alert-started-other")
  return P
end

local function winners_of(force_name)
  local list = {force_name}
  local dip = package.loaded["__" .. script.mod_name .. "__/scripts/diplomacy.lua"]
  if dip and dip.allied then
    for _, f in ipairs(match.forces()) do
      if f ~= force_name and dip.allied(force_name, f) then list[#list + 1] = f end
    end
  end
  return list
end

--- A stage of the force's Space Program is done (internal; tests may call it to skip a stage).
function age3.stage_done(force_name, stage)
  local P = age3.project(force_name)
  if not P or P.stage ~= stage or P.state == "complete" then return false end
  P.done[stage] = game.tick
  local n = #A3.stages
  util.log("age3: %s Space Program stage %d (%s) complete at %s, tick %d", force_name, stage, A3.stages[stage].id,
    clock(game.tick), game.tick)
  if stage == 1 then
    ages.set_age(force_name, 3, "space-program")
    events.emit("rts_age_up", {force = force_name, age = 3})
  end
  if stage >= n then
    P.state = "complete"
    P.complete_tick = game.tick
    if P.site and P.site.valid then update_render(force_name, P) end
    supply.alert(force_name, "space-stage", "rts-age3.alert-launched", {}, P.position)
    alert_others(force_name, "rts-age3.alert-launched-other")
    local winners = winners_of(force_name)
    util.log("age3: %s launched: Space Program complete (winners %s)", force_name, table.concat(winners, ", "))
    events.emit("rts_space_victory", {force = force_name, winners = winners})
  else
    P.stage = stage + 1
    P.required = copy(A3.stages[stage + 1].required)
    P.delivered = {}
    P.state = "building"
    P.stage_started = game.tick
    supply.alert(force_name, "space-stage", "rts-age3.alert-stage", {stage, n}, P.position)
    alert_others(force_name, "rts-age3.alert-stage-other", stage, n)
    if P.site and P.site.valid then update_render(force_name, P) end
  end
  return true
end

local function step_program(force_name, P)
  local site = P.site
  if not (site and site.valid) then return end
  local rush = age3.rush_factor and age3.rush_factor(force_name) or 1
  if P.state == "building" then
    local net = site.surface.find_logistic_network_by_position(site.position, site.force)
    if net then
      local rec = buildings.get(site.unit_number)
      local per = math.floor(A3.pull_per_second * age3.PERIOD / 60 * rush + 0.5)
      for _, item in ipairs(sorted_keys(P.required)) do
        local left = P.required[item] - (P.delivered[item] or 0)
        if left > 0 then
          local got = net.remove_item({name = item, count = math.min(left, per)})
          if got > 0 then
            P.delivered[item] = (P.delivered[item] or 0) + got
            P.pulled_at = game.tick -- Phase 5 M3 integration: a rush pays only while goods come in (sinks.lua)
            if rec and production.on_flow then production.on_flow(rec, item, got, "used") end
          end
        end
      end
    end
    if progress(P) >= 1 then
      P.state = "countdown"
      P.countdown_until = game.tick + A3.stages[P.stage].build_seconds * 60
      util.log("age3: %s Space Program stage %d: everything delivered at %s, %d s countdown", force_name, P.stage,
        clock(game.tick), A3.stages[P.stage].build_seconds)
      if P.stage >= #A3.stages then
        supply.alert(force_name, "space-launch", "rts-age3.alert-countdown", {A3.stages[P.stage].build_seconds},
          P.position)
        alert_others(force_name, "rts-age3.alert-countdown-other", A3.stages[P.stage].build_seconds)
      end
    end
    update_render(force_name, P)
  elseif P.state == "countdown" then
    if rush > 1 then P.countdown_until = P.countdown_until - math.floor(age3.PERIOD * (rush - 1)) end
    update_render(force_name, P)
    if game.tick >= P.countdown_until then age3.stage_done(force_name, P.stage) end
  end
end

-- The complex is gone: the running stage loses raze_loss of its deliveries.
buildings.on_removed(function(un, rec)
  if rec.kind ~= "project" then return end
  local P = age3.project(rec.force)
  if not (P and P.site_un == un) or P.state == "complete" then return end
  for item, n in pairs(P.delivered) do P.delivered[item] = math.floor(n * (1 - A3.raze_loss)) end
  destroy_render(rec.force)
  P.site, P.state, P.razed = nil, "razed", game.tick
  util.log("age3: %s Launch complex razed at %s (stage %d); %.0f%% of the stage's deliveries kept", rec.force,
    util.pos_str(rec.position), P.stage, progress(P) * 100)
  supply.alert(rec.force, "space-razed", "rts-age3.alert-razed", {P.stage}, rec.position)
end)

events.on_nth_tick(age3.PERIOD, function()
  if not nation_mode() then return end
  local m = storage.match
  if not (m and m.phase == "running") then return end
  for _, force_name in ipairs(match.forces()) do
    local P = age3.project(force_name)
    if P then step_program(force_name, P) end
  end
end)

---------------------------------------------------------------------------
-- Automation kits
---------------------------------------------------------------------------
local CUT = 1 - KIT.job_cut

--- Job factor of a building from its automation kits (scripts/labor.lua: jobs x this).
local function job_factor(entity)
  local s = storage.age3
  local n = s and s.kits[entity.unit_number]
  if not n or n <= 0 then return 1 end
  return CUT ^ n
end
labor.job_factor = job_factor
age3.job_factor = job_factor

local function kit_count(e)
  local inv = e.get_module_inventory()
  return inv and inv.get_item_count(age3.KIT) or 0
end

local function set_kits(rec, want, city_id)
  local e = rec.entity
  local inv = e.get_module_inventory()
  if not inv then return 0 end
  local s = S()
  local have = inv.get_item_count(age3.KIT)
  local net = production.network_for(e)
  if want > have and net then
    local got = net.remove_item({name = age3.KIT, count = want - have})
    if got > 0 then
      local put = inv.insert({name = age3.KIT, count = got})
      if put < got then net.insert({name = age3.KIT, count = got - put}) end
      s.stats.kits_in = s.stats.kits_in + put
    end
  elseif want < have then
    local back = inv.remove({name = age3.KIT, count = have - want})
    if back > 0 then
      local put = net and net.insert({name = age3.KIT, count = back}) or 0
      if put < back then
        e.surface.spill_item_stack({position = e.position, stack = {name = age3.KIT, count = back - put},
                                    enable_looted = true, force = e.force, allow_belts = false})
      end
      s.stats.kits_out = s.stats.kits_out + back
    end
  end
  local n = inv.get_item_count(age3.KIT)
  local un = e.unit_number
  if n > 0 then
    s.kits[un], s.kit_city[un] = n, city_id
  else
    s.kits[un], s.kit_city[un] = nil, nil
  end
  if n ~= have then
    util.log("age3: %s #%d (%s, city %s): automation kits %d -> %d (want %d)", e.name, un, rec.force,
      tostring(city_id), have, n, want)
  end
  return n
end

local function city_has_kits(city_id)
  for _, c in pairs(S().kit_city) do
    if c == city_id then return true end
  end
  return false
end

--- One kit pass for a city: districts of an automated family get kits, the others give theirs back.
function age3.kit_pass(city_id)
  local c = cities.get(city_id)
  if not c then return end
  local s = N(c.force)
  local policy = s and s.automate[city_id] or nil
  if not policy and not city_has_kits(city_id) then return end
  local allowed = ages.of(c.force) >= 3
  for _, un in ipairs(sorted_keys(population.members(city_id))) do
    local rec = storage.buildings[un]
    if rec and rec.kind == "district" and rec.entity.valid and rec.force == c.force then
      local fam = labor.family(rec.entity.name, rec.kind)
      local want = (allowed and policy and policy[fam]) and KIT.per_building or 0
      local have = S().kits[un] or 0
      if have ~= want then set_kits(rec, want, city_id) end
    end
  end
end

--- City policy "automate <family>" on or off. Returns ok, reason ("no-city" | "family" | "mode").
function age3.automate(city_id, family, on)
  local c = cities.get(city_id)
  if not c then return false, "no-city" end
  if not FAMILY_OK[family] then return false, "family" end
  local s = N(c.force, true)
  if not s then return false, "mode" end
  local p = s.automate[city_id] or {}
  p[family] = on and true or nil
  s.automate[city_id] = next(p) and p or nil
  util.log("age3: %s city %d automate %s %s", c.force, city_id, family, on and "on" or "off")
  age3.kit_pass(city_id)
  return true
end

--- {[family] = {on, kits, buildings, jobs_cut}} for a city (families with a district or a policy).
function age3.automation(city_id)
  local out = {}
  local c = cities.get(city_id)
  if not c then return out end
  local s = N(c.force)
  local policy = s and s.automate[city_id] or {}
  local K = S().kits
  for _, fam in ipairs(KIT.families) do
    if policy[fam] then out[fam] = {on = true, kits = 0, buildings = 0, jobs_cut = 0} end
  end
  for un in pairs(population.members(city_id)) do
    local rec = storage.buildings[un]
    if rec and rec.kind == "district" and rec.entity.valid then
      local fam = labor.family(rec.entity.name, rec.kind)
      local o = out[fam] or {on = policy[fam] == true, kits = 0, buildings = 0, jobs_cut = 0}
      out[fam] = o
      o.buildings = o.buildings + 1
      o.kits = o.kits + (K[un] or 0)
    end
  end
  for _, o in pairs(out) do
    if o.buildings > 0 then o.jobs_cut = 1 - CUT ^ (o.kits / o.buildings) end
  end
  return out
end

events.on_nth_tick(15, function(e)
  local all = storage.population
  if not (all and next(all) and nation_mode()) then return end
  local slots = KIT.period / 15
  local slot = (e.tick / 15) % slots
  for id in pairs(all) do
    if id % slots == slot then age3.kit_pass(id) end
  end
end)

buildings.on_removed(function(un)
  local s = storage.age3
  if s then s.kits[un], s.kit_city[un] = nil, nil end
end)

---------------------------------------------------------------------------
-- Nuclear plant fuel
---------------------------------------------------------------------------
events.on_nth_tick(A3.nuclear.period, function()
  if not (storage.buildings and nation_mode()) then return end
  for _, rec in buildings.all("steam-plant") do
    local e = rec.entity
    if e.name == age3.NUCLEAR then
      local inv = e.get_fuel_inventory()
      local have = inv and inv.get_item_count(age3.FUEL) or 0
      if inv and have < A3.nuclear.keep then
        local net = production.network_for(e)
        local got = net and net.remove_item({name = age3.FUEL, count = A3.nuclear.keep - have}) or 0
        if got > 0 then
          local put = inv.insert({name = age3.FUEL, count = got})
          if put < got then net.insert({name = age3.FUEL, count = got - put}) end
          S().stats.rods = S().stats.rods + put
          if production.on_flow then production.on_flow(rec, age3.FUEL, put, "used") end
        end
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Ledger (scripts/ledgergui.lua hooks): the Space Program in Age II and III, Rush, automation, extra lines
---------------------------------------------------------------------------
--- The badge / ledger line of the Space Program for a nation in Age II or III, or nil (Age I: the Charter's).
function age3.project_text(force_name)
  if ages.of(force_name) < 2 then return nil end
  local P = age3.project(force_name)
  local n = #A3.stages
  if P and P.state == "complete" then return {"rts-age3.state-complete"} end
  if P and P.state == "countdown" then
    local left = math.max(0, math.ceil((P.countdown_until - game.tick) / 60))
    return {"rts-age3.state-countdown", P.stage, n, left}
  end
  if P and P.state == "razed" then return {"rts-age3.state-razed", P.stage, n} end
  if P and P.state == "building" then return {"rts-age3.state-building", P.stage, n, math.floor(progress(P) * 100)} end
  local ok, why = age3.can_start(force_name)
  if ok then return {"rts-age3.state-ready"} end
  if why == "research" then return {"rts-age3.state-research"} end
  return {"rts-age3.state-research"}
end
ledgergui.project_text_hook = age3.project_text

local function goods_line(required, delivered)
  local parts = {""}
  for _, item in ipairs(sorted_keys(required)) do
    if delivered then
      parts[#parts + 1] = string.format("[item=%s] %d/%d   ", item, math.min(required[item], delivered[item] or 0),
        required[item])
    else
      parts[#parts + 1] = string.format("[item=%s] %d   ", item, required[item])
    end
  end
  return table.concat(parts)
end

-- The ledger's project row for a nation in Age II or III (true = handled).
ledgergui.project_hook = function(player, g)
  local f = player.force.name
  local age = ages.of(f)
  if age < 2 then return false end
  g.age.caption = {"rts.ledger-age", {"rts.age-name-" .. age}}
  g.project.caption = age3.project_text(f)
  local P = age3.project(f)
  local running = P ~= nil and (P.state == "building" or P.state == "countdown" or P.state == "razed")
  g.bar.visible = running
  g.bar.value = P and (P.state == "building" and progress(P) or (P.state == "countdown" and 1 or progress(P))) or 0
  local ok, why = age3.can_start(f)
  g.start.visible = ok or why == "research"
  g.start.enabled = ok
  g.start.caption = {"rts-age3.start"}
  g.start.tooltip = {"rts-age3.start-tooltip"}
  if not (g.start.tags and g.start.tags.rts_age3) then g.start.tags = {rts_age3 = "start"} end
  if P and P.state ~= "complete" then
    g.goods.caption = {"", {"rts-age3.stage-goods", P.stage, #A3.stages}, "  ", goods_line(P.required, P.delivered)}
  elseif not P then
    g.goods.caption = {"", {"rts-age3.stage-goods", 1, #A3.stages}, "  ", goods_line(A3.stages[1].required)}
  else
    g.goods.caption = ""
  end
  return true
end

-- Extra ledger elements: the Rush button next to Start, rare-resource lines and the city's automation buttons.
ledgergui.extend = function(player, g, top, row2)
  g.a3_rush = row2.add({type = "button", caption = {"rts-age3.rush"}, tooltip = {"rts-age3.rush-tooltip"},
                        tags = {rts_age3 = "rush"}})
  g.a3_lines = top.add({type = "label", caption = ""})
  g.a3_lines.style.single_line = false
  g.a3_lines.style.maximal_width = ledgergui.WIDTH - 40
  local row = top.add({type = "flow", direction = "horizontal"})
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 4
  g.a3_auto_row = row
  local head = row.add({type = "label", caption = {"rts-age3.automation"}, tooltip = {"rts-age3.automation-tooltip",
    math.floor(KIT.job_cut * 100 + 0.5), KIT.per_building}})
  head.style.font = "default-bold"
  g.a3_auto = {}
  for _, fam in ipairs(KIT.families) do
    local b = row.add({type = "button", caption = "", tags = {rts_age3 = "automate", family = fam},
                       style = "rts_hud_button"})
    b.style.minimal_width = 40
    b.style.height = 24
    b.style.font = "default-small"
    g.a3_auto[fam] = b
  end
end

ledgergui.extend_refresh = function(player, g, city_id)
  local f = player.force.name
  if g.a3_rush and g.a3_rush.valid then
    local sinks = age3.sinks
    local st = sinks and sinks.rush_state and sinks.rush_state(f)
    local can = sinks and sinks.rush_target and sinks.rush_target(f, "project")
    g.a3_rush.visible = (can ~= nil) or (st ~= nil and st.kind == "project")
    if st and st.kind == "project" then
      g.a3_rush.caption = {"rts-age3.rush-stop", treasury.fmt(st.per_minute or 0)}
      g.a3_rush.tooltip = {"rts-age3.rush-stop-tooltip", treasury.fmt(st.spent or 0)}
    else
      g.a3_rush.caption = {"rts-age3.rush"}
      g.a3_rush.tooltip = {"rts-age3.rush-tooltip", balance.nation.sinks.rush.speed,
        string.format("%.3f", balance.nation.sinks.rush.project_cr), balance.nation.sinks.rush.countdown_cr}
    end
  end
  if g.a3_lines and g.a3_lines.valid then
    local parts = {""}
    for _, fn in ipairs(age3.ledger_lines) do
      local line = fn(f, city_id)
      if line then
        if #parts > 1 then parts[#parts + 1] = "\n" end
        parts[#parts + 1] = line
      end
    end
    g.a3_lines.caption = #parts > 1 and parts or ""
    g.a3_lines.visible = #parts > 1
  end
  if g.a3_auto_row and g.a3_auto_row.valid then
    local age = ages.of(f)
    local info = city_id and age3.automation(city_id) or {}
    for _, fam in ipairs(KIT.families) do
      local b = g.a3_auto[fam]
      if b and b.valid then
        local o = info[fam]
        local on = o and o.on or false
        b.caption = {"", on and "[img=utility/check_mark_green] " or "", {"rts-people.family-" .. fam}}
        b.enabled = age >= 3
        b.tooltip = age < 3 and {"rts-age3.automation-age"}
          or {"rts-age3.automation-family-tooltip", {"rts-people.family-" .. fam}, o and o.buildings or 0,
              o and o.kits or 0, math.floor((o and o.jobs_cut or 0) * 100 + 0.5)}
      end
    end
  end
end

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local action = el.tags and el.tags.rts_age3
  if not action then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  local f = player.force.name
  if action == "start" then
    if ages.of(f) < 2 then
      local p, why = ages.start_project(f) -- the button kept its tag from a newer age (a restarted match)
      if not p then player.print({"rts.project-refused", tostring(why)}) end
    else
      local P, why = age3.start(f)
      util.log("age3: player %d start Space Program: %s (%s)", player.index, P and P.state or "refused", tostring(why))
      if not P then player.print({"rts-age3.start-refused", {"rts-age3.reason-" .. tostring(why)}}) end
    end
    ledgergui.refresh(player)
  elseif action == "rush" then
    local sinks = age3.sinks
    if not sinks then return end
    local st = sinks.rush_state(f)
    if st and st.kind == "project" then
      sinks.cancel_rush(f, "player")
    else
      local ok, why = sinks.rush(f, "project")
      if not ok then player.print({"rts-age3.rush-refused", {"rts-age3.reason-" .. tostring(why)}}) end
    end
    ledgergui.refresh(player)
  elseif action == "automate" then
    local ps = util.pstorage(player.index).ledger
    local city = ps and ps.city
    local fam = el.tags.family
    if city and fam and ages.of(f) >= 3 then
      local info = age3.automation(city)
      local on = not (info[fam] and info[fam].on)
      age3.automate(city, fam, on)
      ledgergui.refresh(player)
    end
  end
end)

---------------------------------------------------------------------------
-- Teardown, describe, console
---------------------------------------------------------------------------
match.on_teardown(function()
  local s = storage.age3
  for f in pairs(s and s.render or {}) do destroy_render(f) end
  for _, n in pairs(storage.nations or {}) do n.age3 = nil end
  storage.age3 = nil
  S()
  for _, force in pairs(game.forces) do
    if string.sub(force.name, 1, 4) == "rts-" then set_recipes(force, false) end
  end
end)

--- "rts-player: Space Program stage 2/3 building 45% (battery 50/100 ...), automated cities 1, kits 4".
function age3.describe(force_name)
  local P = age3.project(force_name)
  local parts = {}
  if P then
    for _, item in ipairs(sorted_keys(P.required)) do
      parts[#parts + 1] = string.format("%s %d/%d", item, P.delivered[item] or 0, P.required[item])
    end
  end
  local s = N(force_name)
  local kits, n = 0, 0
  for _, c in pairs(storage.age3 and storage.age3.kit_city or {}) do
    local city = cities.get(c)
    if city and city.force == force_name then n = n + 1 end
  end
  for un, k in pairs(storage.age3 and storage.age3.kits or {}) do
    local rec = storage.buildings and storage.buildings[un]
    if rec and rec.force == force_name then kits = kits + k end
  end
  return string.format("%s: age %d, %s, automated cities %d, kits %d in %d buildings", force_name, ages.of(force_name),
    P and string.format("Space Program stage %d/%d %s %.0f%% (%s)", P.stage, #A3.stages, P.state, progress(P) * 100,
      table.concat(parts, " ")) or "no Space Program", s and table_size(s.automate) or 0, kits, n)
end

commands.add_command("rts-age3", "[force] [start | stage <n> | automate <city> <family> on|off] - Space Program (QA)",
  function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    local words = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do words[#words + 1] = w end
    local f = (words[1] and game.forces[words[1]]) and table.remove(words, 1)
      or (player and player.force.name) or util.PLAYER_FORCE
    if words[1] and player and not player.admin then
      player.print("rts-age3: admins only")
      return
    end
    if words[1] == "start" then
      local P, why = age3.start(f)
      util.log("age3: console start for %s: %s", f, P and "ok" or tostring(why))
    elseif words[1] == "stage" and tonumber(words[2]) then
      age3.stage_done(f, tonumber(words[2]))
    elseif words[1] == "automate" and tonumber(words[2]) and words[3] then
      age3.automate(tonumber(words[2]), words[3], words[4] ~= "off")
    end
    local line = age3.describe(f)
    if player then player.print(line) else log("[rts] " .. line) end
  end)

deps.age3 = age3
return age3
