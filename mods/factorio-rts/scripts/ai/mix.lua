-- AI unit mix (Phase 4: docs/PHASE4.md section 3 and 6). Each commander keeps a desired composition: the doctrine's
-- base weights (ai/doctrine.lua) plus counters to what scouting saw. For every enemy unit kind seen in the last
-- SEEN_TICKS (scout.lua C.seen) and every known enemy defence (turret, laser turret, wall), each own kind whose
-- balance.units entry lists it under `counters` or `strong` gains COUNTER_GAIN times its share of what was seen:
-- drones against artillery and raiders, heavies against walkers and drones, artillery against turrets, lasers,
-- walls and heavies, raiders against haulers.
--
-- Barracks recipes rotate to match the mix (mix.manage_barracks): each barracks makes the available kind furthest
-- below its desired share, and keeps it until a unit of it spawned or, for the expensive kinds (heavy, raider,
-- artillery), it starved for KIND_WAIT (that kind then rests for KIND_REST; walkers and drones never rest, plates
-- are always short while barracks run). "Available" = research unlocked it (research.is_unlocked; the AI obeys the locks)
-- and every kit ingredient is in the network or was produced in the last minute
-- (heavies need steel, raiders circuits, artillery steel and explosives). Supply (supply.get): a kind that does not
-- fit under the cap is not chosen; with no room at all the barracks stop (recipe cleared once their output is empty)
-- and C.capped asks ai/tech.lua to research supply.
-- Phase 5 E1 (Nation mode): no Age I kind beyond AGE1_ARMY army units unless a base threat is fresh (the army soft
-- cap, production.lua), nothing while the commander saves for a district item (C.nation.saving, ai/age_up.lua), and
-- the Armoured car joins the mix in Age II (CAR_WEIGHT).
-- Workshop first: plates are always short while barracks run, and production.lua serves the oldest-starved consumer
-- with up to two crafts' worth, so the workshop's 2-plate gears and 1-plate circuits came one every ~20 s and science
-- kits barely came at all. The barracks therefore yield (pause, recipe cleared) while the workshop has been starved
-- of plates for YIELD_WORKSHOP ticks on workshop work (science kits, hauler kits and their intermediates), as long as
-- the army holds the doctrine's yield_army units, no base threat is fresh, a unit spawned within YIELD_SPAWN_GAP and
-- the barracks yielded less than YIELD_SHARE of the last YIELD_WINDOW. The returned ingredients feed the workshop at
-- once; the barracks resume as soon as it is supplied. (The builder factory steps aside the same way,
-- ai/commander.lua.) Construction does not make the barracks yield: production.lua's fairness already serves it, as
-- in Phase 3. A hauler kit counts as workshop work wherever it is made.
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local units = require("scripts.units")
local production = require("scripts.production")
local construction = require("scripts.ai.construction")
local build_order = require("scripts.ai.build_order") -- Phase 5 M2 ai: the copper bootstrap's critical stock
local doctrine = require("scripts.ai.doctrine")
local scout = require("scripts.ai.scout")
local deps = require("scripts.ai.deps")
local AI3_COUNCIL = require("balance").nation.ai3.council -- Phase 5 M3 ai (wave B.2): cs_plan_artillery

local mix = {}

mix.SEEN_TICKS = 60 * 60
mix.COUNTER_GAIN = 8
mix.KIND_WAIT = 20 * 60
mix.KIND_REST = 30 * 60
mix.CHEAP = {walker = true, drone = true} -- never rest: plates are always short while barracks run
mix.NATION_KIND_STALL = 3 * 60 * 60 -- Phase 5 M2 ai: Nation mode, a kind without a unit for this long rests
mix.RESERVE_BOOST = 3 -- raider weight factor while a harassing doctrine's raider reserve is not full
mix.FIRST_BOOST = 3   -- weight factor of a non-cheap kind the force has no unit of
mix.YIELD_WORKSHOP = 2 * 60
mix.YIELD_WINDOW = 60 * 60
mix.YIELD_SHARE = 0.6
mix.YIELD_SPAWN_GAP = 40 * 60 -- no yield when no unit spawned for this long (a unit at least every 40 s)
mix.WORKSHOP_RECIPES = {["rts-science-basic"] = true, ["rts-science-advanced"] = true, ["rts-hauler-kit"] = true,
                        ["rts-gear"] = true, ["rts-cable"] = true, ["rts-circuit"] = true, ["rts-explosives"] = true}
mix.SWITCH_PROGRESS = 0.15 -- a busy barracks changes recipe only this early in a craft (its ingredients return)
mix.ORDER = {"walker", "drone", "heavy", "raider", "artillery", "car"}
mix.ARMY_KINDS = {walker = true, drone = true, heavy = true, raider = true, artillery = true, car = true}
-- Phase 5 E1: a Nation-mode force in Age II adds the Armoured car with this weight (balance.nation.economy.ai)
mix.CAR_WEIGHT = require("balance").nation.economy.ai.car_weight
-- Phase 5 E1: a Nation-mode AI makes no Age I unit beyond this army size (the army soft cap makes them dearer, the
-- plates go to districts, the Charter and Armoured cars) unless a base threat is fresh
mix.AGE1_ARMY = require("balance").nation.economy.ai.age1_army
-- Phase 5 M1 integration: the Nation-mode army floor (balance.nation.economy.ai.min_army)
mix.NATION_MIN_ARMY = require("balance").nation.economy.ai.min_army or 0
mix.THREAT_TICKS = 5 * 60
mix.HEARTBEAT = 4 * 60 * 60 -- Phase 5 M3 ai (Nation): see mix.available

-- Barracks kinds from balance.lua: tier-1 units with a barracks kit (mk2 come from research, haulers from the
-- factory). {[kind] = {unit, kit, supply, cost, counters}}
mix.KINDS = {}
do
  local balance = require("balance")
  for name, def in pairs(balance.units) do
    if def.kit and not def.made_by and (def.tier or 1) == 1 and production.KITS[def.kit] then
      -- counters (open-field fights) and strong (also buildings, haulers, turrets, walls), without duplicates
      local list, seen = {}, {}
      for _, src in ipairs({def.counters or {}, def.strong or {}}) do
        for _, k in ipairs(src) do
          if not seen[k] then
            seen[k] = true
            list[#list + 1] = k
          end
        end
      end
      mix.KINDS[def.kind] = {unit = name, kit = def.kit, supply = def.supply or 1, cost = def.cost or {},
                             counters = list, nation_only = def.nation_only}
    end
  end
end
mix.KIT_KIND = {}
for kind, def in pairs(mix.KINDS) do mix.KIT_KIND[def.kit] = kind end

--- Own army units by kind (haulers and the commander excluded): {[kind] = n}, total.
function mix.counts(C)
  local out, total = {}, 0
  for _, rec in units.for_force(C.force) do
    if mix.ARMY_KINDS[rec.kind] then
      out[rec.kind] = (out[rec.kind] or 0) + 1
      total = total + 1
    end
  end
  return out, total
end

--- Desired weights {[kind] = w} and what was counted {[enemy kind] = n} (see the header).
function mix.desired(C)
  local w = {}
  for kind, v in pairs(doctrine.get(C.doctrine).mix) do w[kind] = v end
  local seen, total = {}, 0
  local tick = game.tick
  for kind, s in pairs(C.seen or {}) do
    if tick - s.tick <= mix.SEEN_TICKS and s.n > 0 then
      seen[kind] = s.n
      total = total + s.n
    end
  end
  local known = scout.known_by_kind(C)
  for _, kind in ipairs({"turret", "laser-turret", "wall"}) do
    if known[kind] then
      seen[kind] = (seen[kind] or 0) + known[kind]
      total = total + known[kind]
    end
  end
  local ages = deps.ages -- Phase 5 E1: Age II kinds (the Armoured car) only for a Nation-mode force in Age II
  local age2 = ages ~= nil and ages.is_nation() and ages.of(C.force) >= 2
  if total > 0 then
    for _, kind in ipairs(mix.ORDER) do
      local def = mix.KINDS[kind]
      if def and (age2 or not def.nation_only) then
        for _, target in ipairs(def.counters) do
          if seen[target] then w[kind] = (w[kind] or 0) + mix.COUNTER_GAIN * seen[target] / total end
        end
      end
    end
  end
  if not C.cfg.heavy then w.heavy = nil end
  if age2 then w.car = (w.car or 0) + mix.CAR_WEIGHT end -- Phase 5 E1: Age II armies are built around the car
  return w, seen
end

--- True when the force may and can make `kind` now (see the header), else false, reason.
function mix.available(C, kind)
  local def = mix.KINDS[kind]
  if not def then return false, "no kit" end
  if kind == "heavy" and not C.cfg.heavy then return false, "difficulty" end
  local research = deps.research
  if research and not research.is_unlocked(C.force, def.unit) then return false, "locked" end
  local ages = deps.ages
  if ages and ages.is_nation() then
    local threat = C.army and C.army.threat and game.tick - C.army.threat.tick <= mix.THREAT_TICKS
    -- Phase 5 M3 ai: a heartbeat: after HEARTBEAT ticks without a new unit the barracks make one despite the saving and
    -- the Age I cap (the Age III road's districts kept the economic AI saving, and its barracks idle, for 24 minutes)
    if mix.HEARTBEAT and game.tick - (C.last_spawn_tick or C.started or 0) >= mix.HEARTBEAT then threat = true end
    if C.nation and (C.nation.saving or C.nation.saving_rail) and not threat
       and production.army_size(C.force) >= mix.NATION_MIN_ARMY then
      return false, "saving" -- ai/age_up.lua; never below the army floor (Phase 5 M1 integration)
    end
    -- (Phase 5 M3 ai: a harassing doctrine's raider reserve is exempt: with retreats by force ratio its army stayed at
    -- the cap and the aggressive AI built its first raider in minute 54 of the M1 acceptance)
    local D = doctrine.get(C.doctrine)
    local reserve = kind == "raider" and D.harass and units.count(C.force, "raider") < (D.reserve_raiders or 0)
    if not def.nation_only and not threat and not reserve and production.army_size(C.force) >= mix.AGE1_ARMY then
      return false, "army cap"
    end
  end
  for item, n in pairs(def.cost) do
    if construction.have(C, item) < n and not construction.flowing(C, item) then return false, "no " .. item end
  end
  return true
end

--- True when the doctrine mix wants `kind` and research unlocked it (the workshop then makes its intermediates).
function mix.wanted(C, kind)
  local w = (C.mix_weights or {})[kind]
  if not w or w <= 0 then return false end
  if kind == "heavy" and not C.cfg.heavy then return false end
  local def = mix.KINDS[kind]
  local research = deps.research
  return def ~= nil and not (research and not research.is_unlocked(C.force, def.unit))
end

-- The available kind with the largest gap between desired and current share that fits in `room` supply.
local function choose(C, weights, counts, total, room, resting)
  local wsum = 0
  local avail = {}
  for _, kind in ipairs(mix.ORDER) do
    local w = weights[kind]
    if w and w > 0 and mix.KINDS[kind] and mix.KINDS[kind].supply <= room and not resting[kind]
       and mix.available(C, kind) then
      avail[#avail + 1] = kind
      wsum = wsum + w
    end
  end
  if #avail == 0 then
    -- nothing the doctrine likes is possible: walkers (always unlocked), if they fit
    if mix.KINDS.walker and mix.KINDS.walker.supply <= room and mix.available(C, "walker") then return "walker" end
    return nil
  end
  local best, best_gap
  for _, kind in ipairs(avail) do
    local gap = weights[kind] / wsum - (counts[kind] or 0) / math.max(1, total)
    if not best_gap or gap > best_gap + 1e-9 then best, best_gap = kind, gap end
  end
  return best
end

local function recipe_name(entity)
  local r = entity.get_recipe()
  return r and r.name or nil
end

--- True when a factory of commander C has starved on workshop work long enough that the barracks should yield
--- (see the header). Also returns the recipe it starves on.
function mix.economy_hungry(C)
  local tick = game.tick
  for _, rec in buildings.for_force(C.force, "factory") do
    local since = rec.starved_since
    local st = rec.pull_state
    local r = recipe_name(rec.entity)
    -- only plates the barracks also take: a factory short of stone or gears gains nothing from a pause
    if since and r and mix.WORKSHOP_RECIPES[r] and st and string.sub(st, 1, 7) == "starved"
       and (string.find(st, "iron-plate", 1, true) or string.find(st, "copper-plate", 1, true)
            or string.find(st, "steel-plate", 1, true))
       and tick - since >= mix.YIELD_WORKSHOP then
      return true, r
    end
  end
  return false
end

--- Barracks recipes and rally points of commander C (once per run).
function mix.manage_barracks(C)
  local tick = game.tick
  local weights = mix.desired(C)
  local counts, total = mix.counts(C)
  -- a harassing doctrine fills its raider reserve first (raids.lua needs 3 at once; at a third of the mix the first
  -- harass sometimes missed minute 8)
  local D = doctrine.get(C.doctrine)
  if D.harass and weights.raider and (counts.raider or 0) < (D.reserve_raiders or 0) then
    weights.raider = weights.raider * mix.RESERVE_BOOST
  end
  -- a kind the force has none of yet (a fresh unlock) comes sooner: the first heavy of the economic doctrine came
  -- 2-3 minutes after Unlock Heavy behind walkers and drones that grab plates in smaller bites
  for kind, w in pairs(weights) do
    if (counts[kind] or 0) == 0 and not mix.CHEAP[kind] then weights[kind] = w * mix.FIRST_BOOST end
  end
  -- Phase 5 M3 ai (wave B.2): the hard council's city-state plan wants artillery against the city-state's turrets
  if C.army and C.army.cs_plan and weights.artillery then
    weights.artillery = weights.artillery * (AI3_COUNCIL.cs_plan_artillery or 1)
  end
  C.mix_weights = weights
  C.mix_counts = counts
  local room = math.huge
  local supply = deps.supply
  if supply then
    local s = supply.get(C.force)
    room = s.cap - s.used
    C.supply_used, C.supply_cap = s.used, s.cap
  end
  local min_cost = math.huge
  for _, def in pairs(mix.KINDS) do min_cost = math.min(min_cost, def.supply) end
  local capped = room < min_cost
  if capped and not C.capped then
    util.log("ai %s: supply capped at %d/%d, barracks stop", C.force, C.supply_used or -1, C.supply_cap or -1)
  elseif C.capped and not capped then
    util.log("ai %s: supply room again (%d/%d)", C.force, C.supply_used or -1, C.supply_cap or -1)
  end
  C.capped = capped
  -- economy first (see the header)
  local yield = false
  local threat = C.army.threat and tick - C.army.threat.tick <= 5 * 60
  local win = C.yield_win
  if not win or tick - win.start >= mix.YIELD_WINDOW then
    win = {start = tick, used = 0}
    C.yield_win = win
  end
  -- Phase 5 M1 integration: a Nation-mode barracks never yields below the army floor
  local floor = deps.ages and deps.ages.is_nation() and production.army_size(C.force) < mix.NATION_MIN_ARMY
  if C.unit_recipe and total >= (D.yield_army or 0) and not threat and not floor
     and win.used < mix.YIELD_SHARE * mix.YIELD_WINDOW and tick - (C.last_spawn_tick or 0) < mix.YIELD_SPAWN_GAP then
    yield = mix.economy_hungry(C)
  end
  if yield then
    if not C.yielding then C.stats.yields = (C.stats.yields or 0) + 1 end
    win.used = win.used + (C.yielding and (tick - C.yielding) or 0)
    C.yielding = tick
  else
    C.yielding = nil
  end
  C.bk = C.bk or {}
  C.kind_rest = C.kind_rest or {}
  local resting = {}
  for kind, until_tick in pairs(C.kind_rest) do
    if tick < until_tick then resting[kind] = true else C.kind_rest[kind] = nil end
  end
  local list = {}
  for un, rec in buildings.for_force(C.force, "barracks") do list[#list + 1] = {un, rec} end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  -- Phase 5 M3 ai (Nation): the council's plane kits go to the first barracks (the capital's: its airfield) while the
  -- kit's recipe is on and its parts are at hand
  local plane_kit
  local aw = deps.council and deps.council.air_want and C.unit_recipe and not capped and deps.council.air_want(C)
  if aw then
    local frec = game.forces[C.force].recipes
    local kits = {}
    for kit in pairs(aw) do kits[#kits + 1] = kit end
    table.sort(kits)
    for _, kit in ipairs(kits) do
      local r = frec[kit]
      local ok = r ~= nil and r.enabled
      for _, ing in ipairs(ok and r.prototype.ingredients or {}) do
        if construction.have(C, ing.name) < ing.amount and not construction.flowing(C, ing.name) then ok = false end
      end
      if ok then
        plane_kit = kit
        break
      end
    end
  end
  for i, pair in ipairs(list) do
    local un, rec = pair[1], pair[2]
    local rally = C.army.rally
    if rally and not (rec.rally and util.distance(rec.rally, rally) < 1) then buildings.set_rally(un, rally) end
    local e = rec.entity
    local cur = recipe_name(e)
    local want
    if i == 1 and plane_kit then
      want = plane_kit
    elseif C.unit_recipe and not capped and not yield then
      local st = C.bk[un]
      if not st then
        st = {}
        C.bk[un] = st
      end
      local spawned = rec.spawned or 0
      if st.kind then
        local def = mix.KINDS[st.kind]
        local starved = not mix.CHEAP[st.kind] and rec.starved_since
          and tick - math.max(rec.starved_since, st.since or 0) >= mix.KIND_WAIT
        -- Phase 5 M2 ai (Nation): a kind that made no unit for NATION_KIND_STALL rests too, even when its ingredients
        -- trickle in (seed 501: an Armoured car kit waited 8 minutes for its engines while "supplied" and "starved"
        -- alternated, and the barracks made nothing with an army of 16)
        if not starved and not mix.CHEAP[st.kind] and deps.ages and deps.ages.is_nation()
           and tick - (st.since or tick) >= mix.NATION_KIND_STALL then
          starved = true
        end
        if spawned > (st.spawned or 0) or def.supply > room or not mix.available(C, st.kind) then
          st.kind = nil
        elseif starved then
          C.kind_rest[st.kind] = tick + mix.KIND_REST
          resting[st.kind] = true
          util.log("ai %s: barracks #%d starved on %s kits for %ds, %s rests", C.force, un, st.kind,
            mix.KIND_WAIT / 60, st.kind)
          st.kind = nil
        end
      end
      if not st.kind then
        st.kind = choose(C, weights, counts, total, room, resting)
        st.spawned, st.since = spawned, tick
      end
      if st.kind then
        want = mix.KINDS[st.kind].kit
        counts[st.kind] = (counts[st.kind] or 0) + 1 -- in production: the next barracks diversifies
        total = total + 1
        room = room - mix.KINDS[st.kind].supply
      end
    end
    -- Phase 5 M2 ai: no kit that takes copper while the copper bootstrap holds the last plates (ai/build_order.lua)
    if want and C.boot and C.boot["copper-plate"] and not threat
       and construction.have(C, "copper-plate") < build_order.BOOT_CRITICAL then
      local r = prototypes.recipe[want]
      for _, ing in pairs(r and r.ingredients or {}) do
        if ing.name == "copper-plate" or ing.name == "electronic-circuit" then want = nil break end
      end
    end
    local out = e.get_output_inventory()
    if want == nil and cur ~= nil and out and not out.is_empty() then
      want = cur -- a held kit would go back to the network as a useless item: keep the recipe until it spawns
    end
    if cur ~= want and (cur == nil or not e.is_crafting() or e.crafting_progress < mix.SWITCH_PROGRESS) then
      production.set_recipe(e, want)
    end
  end
end

--- "walker=5 drone=2 ..." of a counts table (deterministic order).
function mix.describe(t)
  local parts = {}
  for _, kind in ipairs(mix.ORDER) do
    if t and t[kind] then
      parts[#parts + 1] = string.format(type(t[kind]) == "number" and math.floor(t[kind]) ~= t[kind] and "%s=%.1f"
        or "%s=%s", kind, t[kind])
    end
  end
  return table.concat(parts, " ")
end

return mix
