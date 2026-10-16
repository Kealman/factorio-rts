-- Production (docs/PHASE2.md "Economic model"): consumers pull from the logistic network, barracks turn kits
-- into units, factories hand finished items to the network, turrets are kept fed.
--
-- Owns storage.production:
--   stats[force_name] = {kits, walkers, heavies, buildings, items, magazines, first_kit_tick, first_walker_tick}
--     kits       crafts finished by the force's barracks (products_finished deltas)
--     walkers    units spawned from kits (walkers + heavies), heavies = the heavy part of it
--     buildings  crafts finished by the force's factories (one recipe run, e.g. 1 extractor or 10 belts)
--     items      items moved from factory outputs into the logistic network
--     magazines  firearm magazines moved from the network into turrets
--   schedule[tick] = {unit_number, ...}   predicted barracks completion checks (spike decision 7)
-- and these fields of storage.buildings records (barracks / factory / turret):
--   last_pf     products_finished at the last look
--   made, moved crafts finished / items moved to the network by this factory (the HUD's factory line; Wave C)
--   next_check  tick of the pending predicted check (barracks)
--   pull_state  "idle" | "supplied" | "starved: <items>" | "no network"   (logged on change only)
--   starved_since  tick the consumer first lacked ingredients the network could not give (nil when supplied)
--   feed_state  "fed" | "network empty" | "no network"                    (turrets, logged on change only)
--   spawned     units spawned by this barracks
--
-- Cadence: network pull and factory hand-off every PULL_PERIOD ticks; barracks are checked at their predicted
-- completion tick plus a SWEEP_PERIOD fallback sweep; turrets every FEED_PERIOD ticks.
--
-- Phase 5 E1 (docs/PHASE5-M1.md section 3, docs/qa/phase5-economy-notes.md):
--   * Districts (kind "district", scripts/districts.lua registers the names) are fed and emptied like factories.
--   * Recipe mode, rec.recipe_mode: "fixed" (a player or the AI chose the recipe, or paused the machine: it behaves as
--     before), "auto" (the auto-recipe pass picks it), nil = "auto" for factories and districts while
--     production.auto_active() (Nation mode), else "fixed". production.set_recipe marks the machine "fixed";
--     production.set_auto switches. Every AUTO_PERIOD ticks an auto machine makes the largest shortfall (target minus
--     the stock of its logistic network, as a share of the target) among its city's make targets
--     (production.targets_of) that it can make with what the network holds; a met target switches it on the next
--     pass. See auto_choose for the rules.
--   * production.on_flow(rec, item, count, "made" | "used") is called for items a producer hands to the network and
--     ingredients it takes from it (the city ledger, scripts/districts.lua).
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")

local production = {}

-- Phase 5 E1: producers with a recipe (barracks, factory, district) and the network-fed crafters among them.
local PRODUCER = {barracks = true, factory = true, district = true}
local CRAFTER = {factory = true, district = true}
production.AUTO_PERIOD = 60
production.AUTO_DWELL = 30 * 60   -- a still-short auto recipe is kept this long ...
production.AUTO_MARGIN = 0.25     -- ... before a shortfall larger by this share of its target takes over
production.AUTO_RESUME = 0.1      -- a recipe that is not running starts only below (1 - this) of its target (hysteresis)
production.AUTO_FINISH = 3        -- seconds: a craft this close to done finishes before its met recipe is switched
-- Hooks (scripts/districts.lua sets them; nil = no auto recipes and no flow counting):
production.auto_active = nil      -- fn() -> true while factories and districts default to auto (Nation mode)
production.targets_of = nil       -- fn(entity) -> {[item] = n} make targets of the entity's city, or nil
production.on_flow = nil          -- fn(rec, item, count, "made" | "used")

production.PULL_PERIOD = 30
production.SWEEP_PERIOD = 60
production.FEED_PERIOD = 120
production.PULL_CRAFTS = 2           -- top consumers up to this many crafts' worth
production.TURRET_MIN = 5            -- feed a turret holding fewer magazines than this
production.TURRET_FEED = 10          -- magazines moved per feed
production.AMMO = "firearm-magazine"
production.RALLY_SPREAD = 2.5        -- tiles between units sent to the same rally point

-- Kit item -> unit prototype and units.lua kind.
production.KITS = {
  ["rts-walker-kit"] = {unit = "rts-walker", kind = "walker"},
  ["rts-walker-heavy-kit"] = {unit = "rts-walker-heavy", kind = "heavy"},
  -- Phase 4 (balance.lua units[*].kit; mk2 tiers keep the kind of their base unit)
  ["rts-drone-kit"] = {unit = "rts-drone", kind = "drone"},
  ["rts-raider-kit"] = {unit = "rts-raider", kind = "raider"},
  ["rts-artillery-kit"] = {unit = "rts-artillery", kind = "artillery"},
  ["rts-walker-mk2-kit"] = {unit = "rts-walker-mk2", kind = "walker"},
  ["rts-heavy-mk2-kit"] = {unit = "rts-heavy-mk2", kind = "heavy"},
}

-- Phase 4: fn(barracks_record, kit_name, KITS entry) -> {unit, kind} to spawn, or nil to keep the kit in the output.
-- Set by scripts/research.lua (research.gate); nil = every kit becomes its KITS unit.
production.kit_gate = nil

local spawned_callbacks = {}

--- fn(unit_entity, barracks_record, kit_name) after a barracks spawned a unit. Load time only.
function production.on_spawned(fn) spawned_callbacks[#spawned_callbacks + 1] = fn end

local function pstate()
  local p = storage.production
  if not p then
    p = {stats = {}, schedule = {}}
    storage.production = p
  end
  return p
end

function production.init()
  local p = pstate()
  p.stats = p.stats or {}
  p.schedule = p.schedule or {}
end

--- A new match starts its counters at zero (match.teardown calls it; before, the HUD and the AI autotest saw the old
--- match's totals after Ctrl+Shift+R or a new match from the lobby).
function production.reset_match()
  local p = pstate()
  p.stats, p.schedule = {}, {}
end

--- Counters of a force (created on first use). See the header for the fields.
function production.stats(force_name)
  local stats = pstate().stats
  local s = stats[force_name]
  if not s then
    s = {kits = 0, walkers = 0, heavies = 0, buildings = 0, items = 0, magazines = 0}
    stats[force_name] = s
  end
  return s
end

--- The logistic network of `force_name` that covers the entity's position, or nil.
function production.network_for(entity)
  return entity.surface.find_logistic_network_by_position(entity.position, entity.force)
end

---------------------------------------------------------------------------
-- Recipes
---------------------------------------------------------------------------
--- Set (recipe name) or clear (nil) the recipe of a barracks / factory, given an entity or a unit number.
--- set_recipe with a recipe from another crafting category silently does nothing (prototype notes gotcha 1),
--- so the result is read back. Returns true when the machine now has the requested recipe (or none).
function production.set_recipe(target, recipe_name, opts)
  local rec = type(target) == "number" and buildings.get(target)
    or (target and target.valid and buildings.get(target.unit_number))
  if not rec or not PRODUCER[rec.kind] then return false end
  local e = rec.entity
  -- Phase 4: LuaEntity.set_recipe accepts a recipe the force has disabled (research locks, scripts/research.lua)
  local force_recipe = recipe_name and e.force.recipes[recipe_name]
  if force_recipe and not force_recipe.enabled then
    util.log("production: %s #%d (%s) rejected recipe %s (locked for the force)", rec.kind, e.unit_number, rec.force,
      recipe_name)
    return false
  end
  local ok, removed = pcall(e.set_recipe, recipe_name)
  if ok and removed and #removed > 0 then
    -- ingredients / products taken out of the machine by the recipe change go back to the pool
    local network = production.network_for(e)
    for _, item in pairs(removed) do
      local back = network and network.insert({name = item.name, count = item.count, quality = item.quality}) or 0
      if back < item.count then
        e.surface.spill_item_stack({position = e.position, stack = {name = item.name, count = item.count - back,
          quality = item.quality}, force = e.force, allow_belts = false})
      end
    end
  end
  local now = e.get_recipe()
  local got = now and now.name or nil
  if ok and got == recipe_name then
    rec.pull_state = nil
    if not (opts and opts.auto) then rec.recipe_mode = "fixed" end -- Phase 5: a chosen (or paused) recipe stays
    if rec.kind == "barracks" and recipe_name then production.schedule_check(rec, game.tick + 1) end
    util.log("production: %s #%d (%s) recipe -> %s", rec.kind, e.unit_number, rec.force, tostring(recipe_name))
    return true
  end
  util.log("production: %s #%d (%s) rejected recipe %s (now %s)", rec.kind, e.unit_number, rec.force,
    tostring(recipe_name), tostring(got))
  return false
end

--- HUD-facing state of a barracks / factory / district: {recipe, progress (0..1), crafting, state, rally, spawned,
--- auto (Phase 5: the auto-recipe pass picks the recipe)}.
function production.status(unit_number)
  local rec = buildings.get(unit_number)
  if not rec then return nil end
  local e = rec.entity
  local recipe = PRODUCER[rec.kind] and e.get_recipe() or nil
  return {
    recipe = recipe and recipe.name or nil,
    progress = recipe and e.crafting_progress or 0,
    crafting = recipe ~= nil and e.is_crafting(),
    state = rec.pull_state or (recipe and "supplied" or "idle"),
    rally = rec.kind == "barracks" and buildings.rally_point(unit_number) or nil,
    spawned = rec.spawned or 0,
    auto = production.is_auto(rec),
  }
end

---------------------------------------------------------------------------
-- Phase 5 E1: recipe modes
---------------------------------------------------------------------------
--- True when the auto-recipe pass picks the recipe of this factory / district record (see the header).
function production.is_auto(rec)
  if not (rec and CRAFTER[rec.kind]) then return false end
  if rec.recipe_mode then return rec.recipe_mode == "auto" end
  return production.auto_active ~= nil and production.auto_active() == true
end

--- Switch a factory or district (entity, unit number or record) to auto (true) or fixed (false: keeps its recipe).
--- Returns true when the record exists.
function production.set_auto(target, on)
  local rec = type(target) == "number" and buildings.get(target)
    or (type(target) == "table" and target.entity and target)
    or (target and target.valid and buildings.get(target.unit_number))
  if not (rec and CRAFTER[rec.kind]) then return false end
  local mode = on and "auto" or "fixed"
  if rec.recipe_mode ~= mode then
    rec.recipe_mode = mode
    rec.auto_set = nil
    util.log("production: %s #%d (%s) recipe mode -> %s", rec.kind, rec.entity.unit_number, rec.force, mode)
  end
  return true
end

---------------------------------------------------------------------------
-- Network pull (consumers)
---------------------------------------------------------------------------
local function set_pull_state(rec, state)
  if rec.pull_state == state then return end
  rec.pull_state = state
  util.log("production: %s #%d (%s) %s", rec.kind, rec.entity.unit_number, rec.force, state)
end

-- Ingredients for one craft are missing and the network can cover all of them: top the machine up to
-- PULL_CRAFTS crafts' worth. Nothing is taken when any missing ingredient is short in the network, so a
-- starved machine never hoards a partial set. Returns true when something was inserted.
--
-- Fairness: consumers are visited oldest-starved first (rec.starved_since), and a starved consumer whose only
-- shortage is a single item reserves that item for the rest of the pass (reserved[network_id][item]), so a
-- factory that needs 20 iron is not starved forever by a barracks that grabs every 10 iron as it arrives.
-- A consumer short of several items reserves nothing, so e.g. a heavy-kit barracks waiting for steel does not
-- block iron for everyone else.
local function pull(rec, reserved)
  local e = rec.entity
  local recipe = e.get_recipe()
  if not recipe then
    rec.starved_since = nil
    set_pull_state(rec, "idle")
    return false
  end
  local input = e.get_inventory(defines.inventory.crafter_input)
  local missing, have = false, {}
  for i, ing in ipairs(recipe.ingredients) do
    have[i] = input.get_item_count(ing.name)
    if have[i] < ing.amount then missing = true end
  end
  if not missing then
    rec.starved_since = nil
    set_pull_state(rec, "supplied")
    return false
  end
  local network = production.network_for(e)
  if not network then
    set_pull_state(rec, "no network")
    return false
  end
  local res = reserved[network.network_id]
  if not res then
    res = {}
    reserved[network.network_id] = res
  end
  local short = {}
  for i, ing in ipairs(recipe.ingredients) do
    local need = ing.amount - have[i]
    if need > 0 and (res[ing.name] or network.get_item_count(ing.name) < need) then short[#short + 1] = ing.name end
  end
  if #short > 0 then
    rec.starved_since = rec.starved_since or game.tick
    if #short == 1 then res[short[1]] = true end
    set_pull_state(rec, "starved: " .. table.concat(short, ","))
    return false
  end
  for i, ing in ipairs(recipe.ingredients) do
    local want = ing.amount * production.PULL_CRAFTS - have[i]
    if want > 0 then
      local got = network.remove_item({name = ing.name, count = want})
      if got > 0 then
        local put = input.insert({name = ing.name, count = got})
        if put < got then network.insert({name = ing.name, count = got - put}) end
        if put > 0 and production.on_flow then production.on_flow(rec, ing.name, put, "used") end
      end
    end
  end
  rec.starved_since = nil
  set_pull_state(rec, "supplied")
  return true
end

---------------------------------------------------------------------------
-- Barracks: kits -> units
---------------------------------------------------------------------------
function production.schedule_check(rec, tick)
  local sched = pstate().schedule
  if tick <= game.tick then tick = game.tick + 1 end
  local list = sched[tick]
  if not list then
    list = {}
    sched[tick] = list
  end
  list[#list + 1] = rec.entity.unit_number
  rec.next_check = tick
end

-- Ticks until the current craft completes (spike #4): remaining progress * recipe time / crafting speed.
local function predict(e, recipe)
  local speed = e.crafting_speed
  if not speed or speed <= 0 then return nil end
  return math.ceil((1 - e.crafting_progress) * recipe.energy / speed * 60)
end

local function rally_destination(rec)
  local rally = rec.rally
  if not rally then return nil end
  local k = (rec.spawned or 0) % 12
  if k == 0 then return {x = rally.x, y = rally.y} end
  local angle = k * 2.39996 -- golden angle: a spiral of slots around the rally point
  local r = production.RALLY_SPREAD * math.sqrt(k)
  return {x = rally.x + r * math.cos(angle), y = rally.y + r * math.sin(angle)}
end

local function spawn_from_kit(rec, kit, def)
  local e = rec.entity
  local exit = buildings.default_exit(rec)
  local unit = units.spawn(def.unit, exit, rec.force, def.kind, e.surface)
  if not unit then return nil end
  local stats = production.stats(rec.force)
  stats.walkers = stats.walkers + 1
  if def.kind == "heavy" then stats.heavies = stats.heavies + 1 end
  stats.first_walker_tick = stats.first_walker_tick or game.tick
  rec.spawned = (rec.spawned or 0) + 1
  local dest = rally_destination(rec)
  if dest and unit.commandable then
    -- order stays "idle": units.lua issues stop when the walk completes (claim rule, units.lua header)
    unit.commandable.set_command({type = defines.command.go_to_location, destination = dest, radius = 1,
                                  distraction = defines.distraction.none})
  end
  util.log("production: barracks #%d (%s) spawned %s #%d at %s%s [unit %d of this barracks]", e.unit_number,
    rec.force, def.unit, unit.unit_number, util.pos_str(unit.position),
    dest and (" -> rally " .. util.pos_str(dest)) or "", rec.spawned)
  for i = 1, #spawned_callbacks do spawned_callbacks[i](unit, rec, kit) end
  return unit
end

-- Look at one barracks: count finished crafts, turn finished kits into units, schedule the next check.
local function check_barracks(rec)
  local e = rec.entity
  if not e.valid then return end
  local pf = e.products_finished
  local last = rec.last_pf or pf
  if pf > last then
    local stats = production.stats(rec.force)
    stats.kits = stats.kits + (pf - last)
    stats.first_kit_tick = stats.first_kit_tick or game.tick
  end
  rec.last_pf = pf
  local out = e.get_output_inventory()
  if not out.is_empty() then
    for kit, def in pairs(production.KITS) do
      local n = out.get_item_count(kit)
      for _ = 1, n do
        -- Phase 4 gate (research.lua): unit locked by research, mk2 swap after Armor I, supply cap; nil = keep the kit
        local spawn = def
        if production.kit_gate then spawn = production.kit_gate(rec, kit, def) end
        if not (spawn and spawn_from_kit(rec, kit, spawn)) then break end -- no room / gated: the kit waits
        out.remove({name = kit, count = 1})
      end
    end
  end
  local recipe = e.get_recipe()
  if recipe and e.is_crafting() then
    local ticks = predict(e, recipe)
    if ticks then production.schedule_check(rec, game.tick + ticks) end
  else
    rec.next_check = nil -- idle: the pull or the sweep picks it up again
  end
end

---------------------------------------------------------------------------
-- Factory: finished items -> network
---------------------------------------------------------------------------
local function hand_off(rec)
  local e = rec.entity
  local stats = production.stats(rec.force)
  local pf = e.products_finished
  local last = rec.last_pf or pf
  if pf > last then
    stats.buildings = stats.buildings + (pf - last)
    rec.made = (rec.made or 0) + (pf - last)
  end
  rec.last_pf = pf
  local out = e.get_output_inventory()
  if out.is_empty() then return end
  local network = production.network_for(e)
  if not network then return end -- stays in the output until a network covers the factory
  for _, item in pairs(out.get_contents()) do
    local stack = {name = item.name, count = item.count, quality = item.quality}
    local moved = item.name ~= "rts-hauler-kit" and network.insert(stack) or 0 -- Phase 4: logistics.lua deploys these
    if moved > 0 then
      out.remove({name = item.name, count = moved, quality = item.quality})
      stats.items = stats.items + moved
      rec.moved = (rec.moved or 0) + moved
      if production.on_flow then production.on_flow(rec, item.name, moved, "made") end
      util.log("production: %s #%d (%s) moved %d %s into the network", rec.kind, e.unit_number, rec.force, moved,
        item.name)
    end
  end
end

---------------------------------------------------------------------------
-- Turrets
---------------------------------------------------------------------------
local function set_feed_state(rec, state)
  if rec.feed_state == state then return end
  rec.feed_state = state
  util.log("production: turret #%d (%s) %s", rec.entity.unit_number, rec.force, state)
end

local function feed_turret(rec)
  local e = rec.entity
  local ammo = e.get_inventory(defines.inventory.turret_ammo)
  if not ammo or ammo.get_item_count(production.AMMO) >= production.TURRET_MIN then return end
  local network = production.network_for(e)
  if not network then
    set_feed_state(rec, "no network")
    return
  end
  local got = network.remove_item({name = production.AMMO, count = production.TURRET_FEED})
  if got == 0 then
    set_feed_state(rec, "network empty")
    return
  end
  local put = ammo.insert({name = production.AMMO, count = got})
  if put < got then network.insert({name = production.AMMO, count = got - put}) end
  local stats = production.stats(rec.force)
  stats.magazines = stats.magazines + put
  set_feed_state(rec, "fed")
end

---------------------------------------------------------------------------
-- Tick handlers
---------------------------------------------------------------------------
events.on(defines.events.on_tick, function(e)
  local p = storage.production
  local list = p and p.schedule[e.tick]
  if not list then return end
  p.schedule[e.tick] = nil
  for _, un in ipairs(list) do
    local rec = storage.buildings[un]
    if rec and rec.next_check == e.tick and rec.entity.valid then check_barracks(rec) end
  end
end)

local NEVER = math.huge
local function by_starvation(a, b)
  local sa, sb = a.starved_since or NEVER, b.starved_since or NEVER
  if sa ~= sb then return sa < sb end
  return a.entity.unit_number < b.entity.unit_number
end

events.on_nth_tick(production.PULL_PERIOD, function(e)
  if not storage.buildings then return end
  local consumers = {}
  for _, rec in buildings.all() do
    if PRODUCER[rec.kind] then consumers[#consumers + 1] = rec end
  end
  table.sort(consumers, by_starvation)
  local reserved = {}
  for _, rec in ipairs(consumers) do
    if rec.kind == "barracks" then
      if pull(rec, reserved) and not (rec.next_check and rec.next_check > e.tick) then
        local recipe = rec.entity.get_recipe()
        local ticks = recipe and predict(rec.entity, recipe)
        if ticks then production.schedule_check(rec, e.tick + ticks + 1) end
      end
    else
      pull(rec, reserved)
      hand_off(rec)
    end
  end
end)

-- Fallback sweep: catches anything the prediction missed (brownouts slow crafting down).
events.on_nth_tick(production.SWEEP_PERIOD, function()
  if not storage.buildings then return end
  for _, rec in buildings.all("barracks") do check_barracks(rec) end
end)

events.on_nth_tick(production.FEED_PERIOD, function()
  if not storage.buildings then return end
  for _, rec in buildings.all("turret") do feed_turret(rec) end
end)

---------------------------------------------------------------------------
-- Phase 5 E1: auto-recipe from make targets
---------------------------------------------------------------------------
-- Recipes each crafter prototype can run: {name, products = {item...}, ingredients = {{name, amount}...}} (static
-- prototype data, identical on every client; not saved).
local machine_recipes = {}
local machine_recipes_flat -- see below
local function recipes_of(entity)
  local list = machine_recipes[entity.name]
  if list then return list end
  list = {}
  local cats = entity.prototype.crafting_categories or {}
  for name, r in pairs(prototypes.recipe) do
    if cats[r.category] and not r.parameter and not r.hidden then
      local entry = {name = name, products = {}, ingredients = {}, order = r.order or ""}
      for _, p in ipairs(r.products) do
        if p.type == "item" then entry.products[#entry.products + 1] = p.name end
      end
      for _, ing in ipairs(r.ingredients) do
        entry.ingredients[#entry.ingredients + 1] = {name = ing.name, amount = ing.amount}
      end
      if #entry.products > 0 then list[#list + 1] = entry end
    end
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  machine_recipes[entity.name] = list
  return list
end
production.recipes_of = recipes_of

-- [recipe name] = {product item, ...} (static; the auto log line)
machine_recipes_flat = setmetatable({}, {__index = function(t, name)
  local r = prototypes.recipe[name]
  local list = {}
  for _, p in ipairs(r and r.products or {}) do list[#list + 1] = p.name end
  t[name] = list
  return list
end})

-- {[item] = count} of a network, read once per pass.
local function stock_of(cache, network)
  local c = cache[network.network_id]
  if c then return c end
  c = {}
  for _, item in pairs(network.get_contents()) do c[item.name] = (c[item.name] or 0) + item.count end
  cache[network.network_id] = c
  return c
end

-- Shortfall of a recipe: the largest (target - stock) / target over its products that have a target; nil when none
-- of its products has a target, 0 when every such target is met.
local function shortfall(entry, targets, stock)
  local best
  for _, item in ipairs(entry.products) do
    local t = targets[item]
    if t and t > 0 then
      local f = math.max(0, (t - (stock[item] or 0)) / t)
      if not best or f > best then best = f end
    end
  end
  return best
end

-- The network (plus the machine's input, for its current recipe) holds one craft's worth of every ingredient.
local function feasible(entry, stock, input)
  for _, ing in ipairs(entry.ingredients) do
    if (stock[ing.name] or 0) + (input and input.get_item_count(ing.name) or 0) < ing.amount then return false end
  end
  return true
end

-- The recipe an auto machine should run, or false to idle (nil = leave it as it is). Rules:
--   0. a met recipe whose craft ends within AUTO_FINISH seconds finishes it (set_recipe would drop the progress), once;
--   1. keep a recipe whose product is still short while it can run (or is crafting), unless it ran AUTO_DWELL and
--      another feasible recipe is short by AUTO_MARGIN more;
--   2. else the feasible recipe with the largest shortfall (ties: recipe order);
--   3. else (nothing short is feasible) a feasible recipe for a missing ingredient of the most short recipe;
--   4. else a district none of whose products has any target runs its first feasible recipe (a district built for
--      its goods works without targets); everything else idles (the current recipe stays while it is still short).
local function auto_choose(rec, cache)
  local e = rec.entity
  local network = production.network_for(e)
  if not network then return nil end
  local targets = (production.targets_of and production.targets_of(e)) or {}
  local stock = stock_of(cache, network)
  local list = recipes_of(e)
  local fr = e.force.recipes
  local cur = e.get_recipe()
  local cur_name = cur and cur.name
  local input = e.get_inventory(defines.inventory.crafter_input)
  local by_name, cands, any_target = {}, {}, false
  for _, entry in ipairs(list) do
    local r = fr[entry.name]
    if r and r.enabled then
      by_name[entry.name] = entry
      local f = shortfall(entry, targets, stock)
      if f ~= nil then any_target = true end
      if f and f > 0 and (entry.name == cur_name or f >= production.AUTO_RESUME) then
        cands[#cands + 1] = {entry = entry, f = f}
      end
    end
  end
  table.sort(cands, function(a, b)
    if a.f ~= b.f then return a.f > b.f end
    return a.entry.order < b.entry.order or (a.entry.order == b.entry.order and a.entry.name < b.entry.name)
  end)
  local cur_entry = cur_name and by_name[cur_name]
  local cur_f = cur_entry and shortfall(cur_entry, targets, stock)
  if cur_entry and not (cur_f and cur_f > 0) and rec.auto_defer ~= cur_name and e.is_crafting()
     and e.crafting_speed > 0 and (1 - e.crafting_progress) * cur.energy / e.crafting_speed <= production.AUTO_FINISH then
    rec.auto_defer = cur_name -- once per met recipe: the next pass switches
    return cur_name
  end
  if cur_entry and cur_f and cur_f > 0 and (e.is_crafting() or feasible(cur_entry, stock, input)) then
    local young = game.tick - (rec.auto_set or 0) < production.AUTO_DWELL
    if young then return cur_name end
    for _, c in ipairs(cands) do
      if c.entry ~= cur_entry and c.f >= cur_f + production.AUTO_MARGIN and feasible(c.entry, stock) then
        return c.entry.name
      end
    end
    return cur_name
  end
  for _, c in ipairs(cands) do
    if feasible(c.entry, stock, c.entry == cur_entry and input or nil) then return c.entry.name end
  end
  -- 3. a missing ingredient this machine can make
  local top = cands[1]
  if top then
    for _, ing in ipairs(top.entry.ingredients) do
      if (stock[ing.name] or 0) < ing.amount then
        for _, entry in ipairs(list) do
          local r = fr[entry.name]
          if r and r.enabled and entry ~= top.entry and feasible(entry, stock) then
            for _, p in ipairs(entry.products) do
              if p == ing.name then return entry.name end
            end
          end
        end
      end
    end
    if cur_entry and cur_f and cur_f > 0 then return cur_name end -- still short: wait for its inputs
    return false
  end
  if rec.kind == "district" and not any_target then
    if cur_entry and feasible(cur_entry, stock, input) then return cur_name end
    for _, entry in ipairs(list) do
      local r = fr[entry.name]
      if r and r.enabled and feasible(entry, stock) then return entry.name end
    end
    return cur_name or false
  end
  return false
end

-- "iron-gear-wheel 30/30" for the products of a recipe that have a target (the switch log line)
local function target_text(name, targets, stock)
  local parts = {}
  for _, entry in ipairs(name and machine_recipes_flat[name] or {}) do
    if targets[entry] then parts[#parts + 1] = string.format("%s %d/%d", entry, stock[entry] or 0, targets[entry]) end
  end
  return table.concat(parts, " ")
end

local function auto_pass()
  if not storage.buildings then return end
  local cache = {}
  for _, rec in buildings.all() do
    if CRAFTER[rec.kind] and production.is_auto(rec) then
      local want = auto_choose(rec, cache)
      if want ~= nil then
        local e = rec.entity
        local cur = e.get_recipe()
        local cur_name = cur and cur.name or false
        if want ~= cur_name then
          local name = want or nil
          if production.set_recipe(e, name, {auto = true}) then
            rec.auto_set, rec.auto_defer = game.tick, nil
            local targets = (production.targets_of and production.targets_of(e)) or {}
            local net = production.network_for(e)
            local stock = net and stock_of(cache, net) or {}
            util.log("production: auto %s #%d (%s) recipe %s -> %s [%s | %s]", rec.kind, e.unit_number, rec.force,
              tostring(cur_name or "none"), tostring(name or "none"), target_text(cur_name or nil, targets, stock),
              target_text(name, targets, stock))
          end
        end
      end
    end
  end
end

events.on_nth_tick(production.AUTO_PERIOD, function()
  if production.auto_active and production.auto_active() then auto_pass() end
end)

return production
