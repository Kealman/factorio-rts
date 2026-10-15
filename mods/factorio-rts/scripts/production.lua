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
--   next_check  tick of the pending predicted check (barracks)
--   pull_state  "idle" | "supplied" | "starved: <items>" | "no network"   (logged on change only)
--   starved_since  tick the consumer first lacked ingredients the network could not give (nil when supplied)
--   feed_state  "fed" | "network empty" | "no network"                    (turrets, logged on change only)
--   spawned     units spawned by this barracks
--
-- Cadence: network pull and factory hand-off every PULL_PERIOD ticks; barracks are checked at their predicted
-- completion tick plus a SWEEP_PERIOD fallback sweep; turrets every FEED_PERIOD ticks.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")

local production = {}

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
function production.set_recipe(target, recipe_name)
  local rec = type(target) == "number" and buildings.get(target)
    or (target and target.valid and buildings.get(target.unit_number))
  if not rec or (rec.kind ~= "barracks" and rec.kind ~= "factory") then return false end
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
    if rec.kind == "barracks" and recipe_name then production.schedule_check(rec, game.tick + 1) end
    util.log("production: %s #%d (%s) recipe -> %s", rec.kind, e.unit_number, rec.force, tostring(recipe_name))
    return true
  end
  util.log("production: %s #%d (%s) rejected recipe %s (now %s)", rec.kind, e.unit_number, rec.force,
    tostring(recipe_name), tostring(got))
  return false
end

--- HUD-facing state of a barracks / factory: {recipe, progress (0..1), crafting, state, rally, spawned}.
function production.status(unit_number)
  local rec = buildings.get(unit_number)
  if not rec then return nil end
  local e = rec.entity
  local recipe = (rec.kind == "barracks" or rec.kind == "factory") and e.get_recipe() or nil
  return {
    recipe = recipe and recipe.name or nil,
    progress = recipe and e.crafting_progress or 0,
    crafting = recipe ~= nil and e.is_crafting(),
    state = rec.pull_state or (recipe and "supplied" or "idle"),
    rally = rec.kind == "barracks" and buildings.rally_point(unit_number) or nil,
    spawned = rec.spawned or 0,
  }
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
  if pf > last then stats.buildings = stats.buildings + (pf - last) end
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
      util.log("production: factory #%d (%s) moved %d %s into the network", e.unit_number, rec.force, moved,
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
    if rec.kind == "barracks" or rec.kind == "factory" then consumers[#consumers + 1] = rec end
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

return production
