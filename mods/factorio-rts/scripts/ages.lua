-- Phase 5 E1: ages and national projects (docs/PHASE5-M1.md section 3, docs/research/scale/deep-economy.md section 2,
-- docs/qa/phase5-economy-notes.md). Nation mode only: in Skirmish every force stays in Age I and nothing here runs.
--
--   ages.is_nation()                      storage.match.config.mode == "nation"
--   ages.of(force) -> 1 | 2 | 3           the force's age (1 for unknown forces and in Skirmish)
--   ages.project(force) -> project | nil  {name = "railway-charter", site (entity), required = {[item] = n},
--                                          delivered = {[item] = n}, state, ...} (see below)
--   ages.can_start(force) -> ok, reason   Industrialisation researched, Age I, no running site
--   ages.start_project(force, position)   places rts-project-site (nil position: next to the capital) and starts or
--                                          resumes the Railway Charter; returns project or nil, reason
--   ages.set_age(force, age, why)         the age changes: recipes, alert, chat line, callbacks (tests may call it)
--   ages.on_age_changed(fn)               fn(force_name, age) after a change (load time only)
--   ages.capital(force) -> {position, entity?}  the capital's centre (cities.lua when loaded, else the main CC)
--
-- Railway Charter: research Industrialisation (advanced kits, balance.nation.economy.charter.tech) lets the force start
-- it. The site is a 6x6 building (kind "project") in the capital; every PERIOD ticks it takes up to pull_per_second of
-- each item it still needs from the logistic network it stands in (trains, haulers and robots fill that network).
-- When everything is delivered a build_seconds countdown runs, then the force enters Age II: every recipe of
-- balance.nation.economy.recipes and .buildings is enabled for that force only (the Armoured car kit, the Bunker,
-- districts, oil), research.status lets the Age II technologies and Armor I through, every unit of the force gets the
-- Mk2 line (research.AGE2_BONUS: +25 % damage, +40 % effective health), an alert and a chat line go out, and the HUD
-- badge (scripts/ledgergui.lua) changes. A site
-- that is destroyed loses raze_loss of the delivered goods; starting it again resumes with the rest. Progress is drawn
-- over the site (rendering) for every force.
--
-- Owns storage.ages[force_name] = {age, project} (contract), project = {name, site, site_un, position, required,
-- delivered, state = "building" | "countdown" | "done" | "razed", started, countdown_until, done_tick, render}.
-- Cleared by match.on_teardown, which also disables the Age II recipes of every rts-* force again.
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local research = require("scripts.research")
local supply = require("scripts.supply")
local match = require("scripts.match")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local E = balance.nation.economy
local C = E.charter

local ages = {}

ages.SITE = "rts-project-site"
ages.PROJECT = "railway-charter"
ages.PERIOD = 60
ages.MAX_AGE = 3 -- Phase 5 M3 age3: stage 1 of the Space Program (scripts/age3.lua) brings Age III
ages.rush_factor = nil -- Phase 5 M3 age3: fn(force_name) -> 1 | speed (scripts/sinks.lua Rush: pull and countdown)
ages.SITE_DISTANCES = {12, 16, 20}

buildings.KIND_BY_NAME[ages.SITE] = "project"

-- The age technologies: effects, Nation-only, required age (scripts/research.lua reads these tables at run time).
for _, t in ipairs(E.techs) do
  research.EFFECTS[t.name] = t.effect
  research.NATION_ONLY[t.name] = true
  if t.age and t.age > 1 then research.AGE_REQUIRED[t.name] = t.age end
end
-- Age II military (Nation mode; owner's constraint 2026-10-16): the Mk2 line for every unit comes with Age II
-- (research.AGE2_BONUS), so Armor I (Mk2 walkers and heavies) waits for Age II too; Age II units need Age II.
research.AGE2_BONUS = E.age2_bonus
research.AGE_REQUIRED["rts-armor-1"] = 2
for name, u in pairs(balance.units) do
  if u.nation_only then
    research.AGE_REQUIRED[name] = 2
    if u.kit then research.AGE_REQUIRED[u.kit] = 2 end
  end
end

-- Recipes a force gets at Age II (static: balance data).
ages.AGE2_RECIPES = {}
-- Phase 5 M2 integration: the Rail works and its rail recipe unlock with Railways in Age I (scripts/rails.lua), so lines
-- can open before minute 20; they are no Age II recipes
ages.RAILWAYS_EARLY = {["rts-district-rails"] = true, ["rts-dra-rail"] = true}
for name in pairs(E.recipes) do
  if not ages.RAILWAYS_EARLY[name] then ages.AGE2_RECIPES[#ages.AGE2_RECIPES + 1] = name end
end
for name in pairs(E.buildings) do
  if not ages.RAILWAYS_EARLY[name] then ages.AGE2_RECIPES[#ages.AGE2_RECIPES + 1] = name end
end
table.sort(ages.AGE2_RECIPES)
for _, name in ipairs(ages.AGE2_RECIPES) do research.AGE_LOCKS[name] = "rts-age-2" end -- HUD: "locked: Age II"

local changed_callbacks = {}
--- fn(force_name, age) after a force changed its age. Load time only.
function ages.on_age_changed(fn) changed_callbacks[#changed_callbacks + 1] = fn end

-- m1-cities' scripts/cities.lua, when control.lua loaded it (before this module); nil until that package lands.
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end
local cities_mod
--- scripts/cities.lua (with make_targets) or nil.
function ages.cities()
  if cities_mod == nil then
    local m = loaded("scripts.cities")
    cities_mod = (type(m) == "table" and m.make_targets) and m or false
  end
  return cities_mod or nil
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
function ages.init()
  storage.ages = storage.ages or {}
end

function ages.is_nation()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function state(force_name)
  local all = storage.ages
  if not all then
    all = {}
    storage.ages = all
  end
  local s = all[force_name]
  if not s then
    s = {age = 1}
    all[force_name] = s
  end
  return s
end

function ages.of(force_name)
  local s = storage.ages and storage.ages[force_name]
  return s and s.age or 1
end

--- The Railway Charter's deliveries {[item] = n} (balance.nation.economy.charter.required; read-only).
function ages.required() return C.required end

function ages.project(force_name)
  local s = storage.ages and storage.ages[force_name]
  return s and s.project
end

research.age_of = ages.of
research.is_nation = ages.is_nation
deps.ages = ages

local function set_recipes(force, age)
  if not (force and force.valid) then return end
  local on = age >= 2
  local recipes = force.recipes
  for _, name in ipairs(ages.AGE2_RECIPES) do
    local r = recipes[name]
    if r and r.enabled ~= on then r.enabled = on end
  end
end

--- Change a force's age (Age II recipes, research gate, alert, chat line, callbacks). Returns true when it changed.
function ages.set_age(force_name, age, why)
  age = math.max(1, math.min(ages.MAX_AGE, math.floor(age)))
  local s = state(force_name)
  if s.age == age then return false end
  local old = s.age
  s.age = age
  local nations = storage.nations
  if nations and nations[force_name] then nations[force_name].age = age end
  local force = game.forces[force_name]
  set_recipes(force, age)
  if force then research.apply(force) end -- the Age II Mk2 line (unit damage, armor share)
  local secs = storage.match and storage.match.tick_started and (game.tick - storage.match.tick_started) / 60 or 0
  util.log("ages: %s age %d -> %d (%s) at %d:%02d match time, tick %d", force_name, old, age, why or "-",
    math.floor(secs / 60), math.floor(secs % 60), game.tick)
  if age > old then
    local params = {{"rts.age-name-" .. age}}
    supply.alert(force_name, "age-up", "rts.alert-age-up", params)
    if force then force.print({"rts.alert-age-up", params[1]}) end
    for _, f in pairs(game.forces) do
      if f.name ~= force_name and match.is_participant(f.name) then
        f.print({"rts.alert-age-up-other", match.label(force_name), params[1]})
      end
    end
  end
  for _, fn in ipairs(changed_callbacks) do fn(force_name, age) end
  return true
end

---------------------------------------------------------------------------
-- Capital and site
---------------------------------------------------------------------------
--- The capital of a force: {position, entity?} (cities.lua's capital City Center when it exists, else the main CC).
function ages.capital(force_name)
  local nations = storage.nations
  local n = nations and nations[force_name]
  local cities = ages.cities()
  if cities and n and n.capital and cities.get then
    local c = cities.get(n.capital)
    if c and c.position then
      local center = c.center and buildings.get(c.center)
      return {position = c.position, entity = center and center.entity}
    end
  end
  local cc = buildings.main_cc(force_name)
  if cc then return {position = cc.entity.position, entity = cc.entity} end
  return nil
end

--- A free spot for the site next to the capital, inside a logistic network of the force, or nil.
function ages.site_position(force_name)
  local cap = ages.capital(force_name)
  local surface = match.surface()
  if not (cap and surface) then return nil end
  local force = game.forces[force_name]
  local front = match.front and match.front(force_name) or {x = 1, y = 0}
  -- behind the capital first (away from the enemy), then the sides, then the front
  local dirs = {{-front.x, -front.y}, {-front.y, front.x}, {front.y, -front.x}, {front.x, front.y}}
  for _, d in ipairs(ages.SITE_DISTANCES) do
    for _, v in ipairs(dirs) do
      local want = {x = math.floor(cap.position.x + v[1] * d) + 0.0, y = math.floor(cap.position.y + v[2] * d) + 0.0}
      local pos = surface.find_non_colliding_position(ages.SITE, want, 6, 1, true)
      if pos and surface.find_logistic_network_by_position(pos, force) then return pos end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Rendering (visible to every force: the map shows every nation's project)
---------------------------------------------------------------------------
local BAR_W, BAR_Y = 6, -3.6

local function destroy_render(p)
  for _, obj in pairs(p.render or {}) do
    if obj.valid then obj.destroy() end
  end
  p.render = nil
end

local function progress(p)
  local need, have = 0, 0
  for item, n in pairs(p.required) do
    need = need + n
    have = have + math.min(n, p.delivered[item] or 0)
  end
  return need > 0 and have / need or 1
end
ages.progress = progress

local function draw(p)
  destroy_render(p)
  local site = p.site
  if not (site and site.valid) then return end
  local surface = site.surface
  p.render = {
    bg = rendering.draw_rectangle({color = {0, 0, 0, 0.7}, filled = true, surface = surface,
      left_top = {entity = site, offset = {-BAR_W / 2 - 0.1, BAR_Y - 0.1}},
      right_bottom = {entity = site, offset = {BAR_W / 2 + 0.1, BAR_Y + 0.5}}}),
    fg = rendering.draw_rectangle({color = {0.9, 0.7, 0.2, 0.9}, filled = true, surface = surface,
      left_top = {entity = site, offset = {-BAR_W / 2, BAR_Y}},
      right_bottom = {entity = site, offset = {-BAR_W / 2, BAR_Y + 0.4}}}),
    text = rendering.draw_text({text = {"rts.project-label", {"rts.project-" .. p.name}, 0}, surface = surface,
      target = {entity = site, offset = {0, BAR_Y - 0.9}}, color = {1, 0.9, 0.6}, scale = 1.4,
      alignment = "center", vertical_alignment = "middle"}),
  }
end

local function update_render(p)
  local r = p.render
  if not (r and r.fg and r.fg.valid) then
    draw(p)
    r = p.render
    if not r then return end
  end
  local f = progress(p)
  r.fg.right_bottom = {entity = p.site, offset = {-BAR_W / 2 + BAR_W * f, BAR_Y + 0.4}}
  if p.state == "countdown" then
    local left = math.max(0, math.ceil((p.countdown_until - game.tick) / 60))
    r.text.text = {"rts.project-countdown", {"rts.project-" .. p.name}, left}
    r.fg.color = {0.3, 0.9, 0.3, 0.9}
  else
    r.text.text = {"rts.project-label", {"rts.project-" .. p.name}, math.floor(f * 100)}
  end
end

---------------------------------------------------------------------------
-- Projects
---------------------------------------------------------------------------
--- Whether the force may start (or resume) its Railway Charter now: ok, reason ("mode" | "age" | "research" |
--- "running").
function ages.can_start(force_name)
  if not ages.is_nation() then return false, "mode" end
  if ages.of(force_name) >= 2 then return false, "age" end
  if not research.has(force_name, C.tech) then return false, "research" end
  local p = ages.project(force_name)
  if p and p.site and p.site.valid and p.state ~= "razed" then return false, "running" end
  return true
end

function ages.start_project(force_name, position)
  local ok, why = ages.can_start(force_name)
  if not ok then
    if why == "running" then return ages.project(force_name), why end
    return nil, why
  end
  local surface = match.surface()
  local pos = position or ages.site_position(force_name)
  if not (surface and pos) then return nil, "no spot" end
  local site = surface.create_entity({name = ages.SITE, position = pos, force = force_name})
  if not site then return nil, "blocked" end
  buildings.register(site)
  local s = state(force_name)
  local p = s.project
  if not p then
    p = {name = ages.PROJECT, required = {}, delivered = {}, started = game.tick}
    for item, n in pairs(C.required) do p.required[item] = n end
    s.project = p
  end
  p.site, p.site_un, p.state = site, site.unit_number, "building"
  p.position = {x = site.position.x, y = site.position.y}
  draw(p)
  update_render(p)
  local has_net = surface.find_logistic_network_by_position(site.position, site.force) ~= nil
  util.log("ages: %s started %s at %s (%s, delivered so far %.0f%%)", force_name, p.name, util.pos_str(site.position),
    has_net and "in a logistic network" or "NO logistic network", progress(p) * 100)
  supply.alert(force_name, "project-started", "rts.alert-project-started", {{"rts.project-" .. p.name}},
    site.position)
  return p
end

local function step_project(force_name, p)
  local site = p.site
  if p.state ~= "done" and ages.of(force_name) >= 2 then -- the age came another way (console, tests): the site stays
    p.state, p.done_tick = "done", game.tick
    destroy_render(p)
    return
  end
  local rush = ages.rush_factor and ages.rush_factor(force_name) or 1 -- Phase 5 M3 age3: sinks.rush
  if p.state == "building" and site and site.valid then
    local net = site.surface.find_logistic_network_by_position(site.position, site.force)
    local rec = buildings.get(site.unit_number)
    if net then
      for item, need in pairs(p.required) do
        local left = need - (p.delivered[item] or 0)
        if left > 0 then
          local got = net.remove_item({name = item, count = math.min(left, C.pull_per_second * ages.PERIOD / 60 * rush)})
          if got > 0 then
            p.delivered[item] = (p.delivered[item] or 0) + got
            if rec and production.on_flow then production.on_flow(rec, item, got, "used") end
          end
        end
      end
    end
    if progress(p) >= 1 then
      p.state = "countdown"
      p.countdown_until = game.tick + C.build_seconds * 60
      util.log("ages: %s %s: everything delivered at tick %d, %d s to Age II", force_name, p.name, game.tick,
        C.build_seconds)
    end
    update_render(p)
  elseif p.state == "countdown" and site and site.valid then
    if rush > 1 then p.countdown_until = p.countdown_until - math.floor(ages.PERIOD * (rush - 1)) end -- Phase 5 M3 age3
    update_render(p)
    if game.tick >= p.countdown_until then
      p.state = "done"
      p.done_tick = game.tick
      ages.set_age(force_name, 2, p.name)
      destroy_render(p)
    end
  end
end

-- The site is gone (died, mined, destroyed): it loses raze_loss of the delivered goods.
buildings.on_removed(function(un, rec)
  if rec.kind ~= "project" then return end
  local s = storage.ages and storage.ages[rec.force]
  local p = s and s.project
  if not (p and p.site_un == un) or p.state == "done" then return end
  for item, n in pairs(p.delivered) do p.delivered[item] = math.floor(n * (1 - C.raze_loss)) end
  destroy_render(p)
  p.site, p.state, p.razed_tick = nil, "razed", game.tick
  util.log("ages: %s %s site razed at %s; %.0f%% of the deliveries kept", rec.force, p.name, util.pos_str(rec.position),
    progress(p) * 100)
  supply.alert(rec.force, "project-razed", "rts.alert-project-razed", {{"rts.project-" .. p.name}}, rec.position)
end)

events.on_nth_tick(ages.PERIOD, function()
  local all = storage.ages
  if not all or not ages.is_nation() then return end
  for force_name, s in pairs(all) do
    if s.project then step_project(force_name, s.project) end
  end
end)

-- A new match starts in Age I with the Age II recipes locked again (forces outlive matches).
match.on_teardown(function()
  for _, s in pairs(storage.ages or {}) do
    if s.project then destroy_render(s.project) end
  end
  storage.ages = {}
  for _, force in pairs(game.forces) do
    if string.sub(force.name, 1, 4) == "rts-" then set_recipes(force, 1) end
  end
end)

--- One line per force for logs and the console: "rts-player: age 1, railway-charter building 45% (steel 50/100 ...)".
function ages.describe(force_name)
  local p = ages.project(force_name)
  local parts = {}
  if p then
    local items = {}
    for item in pairs(p.required) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
      parts[#parts + 1] = string.format("%s %d/%d", item, p.delivered[item] or 0, p.required[item])
    end
  end
  return string.format("%s: age %d%s", force_name, ages.of(force_name),
    p and string.format(", %s %s %.0f%% (%s)", p.name, p.state, progress(p) * 100, table.concat(parts, " ")) or "")
end

commands.add_command("rts-age", "[force] [age] - show a force's age and project, or set its age (admin, tests)",
  function(cmd)
    local args = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = w end
    local player = cmd.player_index and game.get_player(cmd.player_index)
    local force_name = args[1] or (player and player.force.name) or util.PLAYER_FORCE
    if args[2] then
      if player and not player.admin then
        player.print("rts-age: admins only")
        return
      end
      ages.set_age(force_name, tonumber(args[2]) or 1, "console")
    end
    local line = ages.describe(force_name)
    if player then player.print(line) else log("[rts] " .. line) end
  end)

return ages
