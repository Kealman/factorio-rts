-- AI commander (docs/PHASE3.md "ai/commander.lua"): one per AI force, state in storage.ai[force_name]. A run is
-- economy (build order) -> construction -> hubs -> research -> production -> army -> scouting.
-- Phase 4: each commander has a doctrine (ai/doctrine.lua), researches (ai/tech.lua), expands with hubs and haulers
-- (ai/hubs.lua), rotates its barracks through a counter-aware unit mix (ai/mix.lua) and runs two factories: the
-- builder (construction items, ammo) and the workshop (science kits, hauler kits, circuits, explosives).
--
-- storage.ai[force_name] = C = {
--   force, difficulty, doctrine, doctrine_seed, cfg (orders_data.DIFFICULTY copy, first_attack scaled by the
--   doctrine), started, next_tick, runs,
--   frame       layout frame of the main CC {cx, cy, fx}
--   reserved    {[tile key] = owner}   tiles the plan uses ("hub", a line name, "building")
--   avoid       {[tile key] = true}    tiles in front of a line's last belt: no belt may ever go there
--   belt_tiles  {[tile key] = true}    planned belt tiles
--   hub         {[slot] = "free" | "dead" | line name}
--   claimed     {[patch id] = line name}
--   lines       {[name] = line}        build_order.lua
--   plan, queue, pending, need, need_list, next_build      construction.lua
--   steps       {[i] = {done?, started?, skipped?, retry_at?}}, current_step     build_order.lua
--   unit_recipe nil until the build order enables unit production; last_kit[barracks] = kit it made last
--   bk, kind_rest, mix_weights, mix_counts, capped, supply_used, supply_cap   mix.lua
--   expansions, want_haulers   hubs.lua;  tech, science   tech.lua;  ws_fill, ws_set   workshop factory
--   army        army.lua;  known, guesses, seen, enemy_haulers   scout.lua;  raid, next_harass   raids.lua
--   stats       {ghosts, revived, jobs, bad, seen, attacks, reinforcements, retreats, defends, recalls, bonus_units,
--                bots_removed}
-- }
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local economy = require("scripts.economy")
local match = require("scripts.match")
local data = require("scripts.ai.orders_data")
local layout = require("scripts.ai.layout")
local construction = require("scripts.ai.construction")
local build_order = require("scripts.ai.build_order")
local army = require("scripts.ai.army")
local scout = require("scripts.ai.scout")
local doctrine = require("scripts.ai.doctrine")
local hubs = require("scripts.ai.hubs")
local mix = require("scripts.ai.mix")
local tech = require("scripts.ai.tech")
local age_up = require("scripts.ai.age_up") -- Phase 5 E1: Nation mode age-up and make targets
local towns = require("scripts.ai.towns") -- Phase 5 M1 integration: the second city as a mining town (Nation mode)
local governor = require("scripts.ai.governor") -- Phase 5 M2 ai: city governors (people, defence, export routes)
local nation_ai = require("scripts.ai.nation") -- Phase 5 M2 ai: the nation strategist (taxes, trade, war and peace)
local deps = require("scripts.ai.deps")
local balance = require("balance")

local commander = {}

commander.THINK = 60          -- ticks between runs
commander.REPAIR_TICKS = 600  -- destroyed parts are re-queued this often
commander.FACTORY_DWELL = 300 -- a factory keeps a recipe at least this long unless nothing needs it

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- Facing of a CC: towards the nearest other spawn along x (the arena is horizontal), else towards x = 0.
local function facing(C, home)
  local best, fx
  local m = storage.match
  for force_name, pos in pairs(m and m.spawns or {}) do
    if force_name ~= C.force then
      local d = util.distance(home, pos)
      if not best or d < best then best, fx = d, (pos.x >= home.x) and 1 or -1 end
    end
  end
  return fx or (home.x <= 0 and 1 or -1)
end

--- Take the robots out of the force's Command Centers: the AI builds by paced revive, not with bots.
function commander.remove_bots(C)
  local n = 0
  for _, rec in buildings.for_force(C.force, "cc") do
    local inv = rec.entity.get_inventory(defines.inventory.roboport_robot)
    if inv and not inv.is_empty() then
      n = n + inv.get_item_count()
      inv.clear()
    end
  end
  if n > 0 then
    C.stats.bots_removed = C.stats.bots_removed + n
    util.log("ai %s: removed %d robots from its command centers", C.force, n)
  end
  return n
end

-- Phase 5 M2 ai: in Nation mode the hard AI's only cheat is +20 % tax income (docs/PHASE5-M2.md §3, treasury.lua):
-- no extra stock, mining bonus, free units or full vision there.
commander.NATION_NO_CHEATS = {stock_bonus = 0, mining_bonus = 0, kit_bonus_every = false, vision = "honest"}
local function nation_match()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

-- Settings of a difficulty under a doctrine.
local function settings(difficulty, doctrine_name)
  local cfg = copy(data.DIFFICULTY[difficulty])
  if nation_match() then
    for k, v in pairs(commander.NATION_NO_CHEATS) do
      if v == false then cfg[k] = nil else cfg[k] = v end
    end
  end
  local D = doctrine.get(doctrine_name)
  cfg.first_attack = math.floor(cfg.first_attack * D.first_attack + 0.5)
  cfg.max_in_progress = cfg.max_in_progress + (D.in_flight or 0)
  if D.retreat then cfg.retreat_ratio = D.retreat end
  if D.targets then
    cfg.target_penalty = copy(data.TARGET_PENALTY)
    for kind, v in pairs(D.targets) do cfg.target_penalty[kind] = v end
  end
  return cfg
end

--- New commander state (not started). difficulty: "easy" | "normal" | "hard". The doctrine is drawn here
--- (doctrine.pick: override or seeded draw) and logged.
function commander.new(force_name, difficulty)
  difficulty = data.DIFFICULTY[difficulty] and difficulty or data.DEFAULT_DIFFICULTY
  local doc, seed = doctrine.pick(force_name)
  util.log("ai %s: doctrine %s (seed %s)", force_name, doc, tostring(seed))
  return {
    force = force_name, difficulty = difficulty, doctrine = doc, doctrine_seed = seed, cfg = settings(difficulty, doc),
    started = game.tick, next_tick = game.tick + 1, runs = 0,
    reserved = {}, avoid = {}, belt_tiles = {}, tiles_v = 2, claimed = {}, lines = {}, -- tiles_v: Phase 5 M3 perf
    plan = {}, queue = {}, pending = {}, need = {}, need_list = {}, next_build = 0,
    steps = {}, known = {}, guesses = {}, expansions = {},
    stats = {ghosts = 0, revived = 0, jobs = 0, bad = 0, seen = 0, attacks = 0, reinforcements = 0, retreats = 0,
             defends = 0, recalls = 0, bonus_units = 0, bots_removed = 0, harass = 0, guards = 0, patrols = 0,
             priority = 0},
  }
end

--- Switch a running commander to another difficulty: new settings and build order (step progress is re-derived
--- from what exists), same plan, base and army.
function commander.set_difficulty(C, difficulty)
  difficulty = data.DIFFICULTY[difficulty] and difficulty or data.DEFAULT_DIFFICULTY
  C.difficulty, C.cfg, C.steps, C.current_step = difficulty, settings(difficulty, C.doctrine), {}, nil
  util.log("ai %s: difficulty is now %s", C.force, difficulty)
end

--- Switch a running commander to another doctrine (the autotest and /rts-ai-doctrine): new build order, research
--- order, mix and pacing; plan, base and army stay.
function commander.set_doctrine(C, name)
  if not doctrine.DEF[name] then return false end
  C.doctrine, C.cfg, C.steps, C.current_step = name, settings(C.difficulty, name), {}, nil
  util.log("ai %s: doctrine is now %s", C.force, name)
  return true
end

-- Hard: the extra starting stock and the mining bonus (orders_data.DIFFICULTY).
local function apply_cheats(C)
  local cfg = C.cfg
  local force = game.forces[C.force]
  if cfg.mining_bonus and cfg.mining_bonus > 0 and force then
    force.mining_drill_productivity_bonus = force.mining_drill_productivity_bonus + cfg.mining_bonus
  end
  if cfg.stock_bonus and cfg.stock_bonus > 0 then
    local parts = {}
    for _, entry in ipairs(match.STARTING_STOCK) do
      local n = math.floor(entry[2] * cfg.stock_bonus)
      if n > 0 then
        local given = economy.give(C.force, entry[1], n)
        parts[#parts + 1] = string.format("%s=%d", entry[1], given)
      end
    end
    util.log("ai %s: extra starting stock (x%.2f): %s", C.force, 1 + cfg.stock_bonus, table.concat(parts, " "))
  end
end

-- Phase 5 M1 integration: the planning state before the start lines (restored for a second planning pass).
local PLAN_TABLES = {"reserved", "avoid", "belt_tiles", "claimed", "hub", "plan", "lines"}
local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end
local function planning_snapshot(C)
  local snap = {}
  for _, name in ipairs(PLAN_TABLES) do snap[name] = deep_copy(C[name] or {}) end
  return snap
end
-- (Phase 5 M3 perf: the tile sets' buckets are tables, so a restore copies them: a snapshot is restored more than once)
local TILE_SET = {reserved = true, avoid = true, belt_tiles = true}
local function planning_restore(C, snap)
  for _, name in ipairs(PLAN_TABLES) do
    local t = C[name]
    if not t then
      t = {}
      C[name] = t
    end
    for k in pairs(t) do t[k] = nil end
    for k, v in pairs(snap[name]) do t[k] = TILE_SET[name] and deep_copy(v) or v end
  end
end

--- First-time setup: robots out, frame, hub reservation, start lines, army rally, scouting guesses, cheats.
function commander.start(C)
  local surface = util.surface()
  local cc = buildings.main_cc(C.force)
  commander.remove_bots(C)
  local home = cc and cc.position or match.home(C.force)
  C.frame = layout.frame(home, facing(C, home))
  army.init(C, home)
  scout.seed(C)
  apply_cheats(C)
  if cc then
    layout.probe_inserter(surface, {x = home.x, y = home.y + 30})
    layout.reserve_hub(C, C.frame)
    local prof = helpers.create_profiler()
    local ctx = layout.context(C, surface)
    -- Phase 5 M1 integration: Nation mode plans the coal line at the start too (orders_data.NATION_START_LINES)
    local nation = deps.ages and deps.ages.is_nation()
    local snap = nation and planning_snapshot(C) or nil
    local start_lines = nation and data.NATION_START_LINES or data.START_LINES
    for _, name in ipairs(start_lines) do build_order.plan_line(C, ctx, name) end
    -- the other lines' belts closed W2d's feed tile in: plan again with coal first (same slots, its belt routed
    -- before the others), then, if that fails too, coal first into any direct slot it reaches (the line it takes the
    -- slot from loses one smelter)
    -- A pass is kept only when copper and stone keep all their slots and iron loses at most one: an AI without copper
    -- researched nothing for 25 minutes (seed 404), one without coal only waits with its haulers.
    local function slots(name)
      local L = C.lines[name]
      return (L and L.status == "ok") and #L.slots or 0
    end
    -- "X" when the first slot of a line is a satellite, "hub" otherwise, nil without a planned line
    local function lead_slot(name)
      local L = C.lines[name]
      local sl = L and L.status == "ok" and L.slots[1]
      if not sl then return nil end
      return string.sub(sl.name, 1, 1) == "X" and "X" or "hub"
    end
    local function names(name)
      local L, out = C.lines[name], {}
      for _, sl in ipairs((L and L.status == "ok") and L.slots or {}) do out[#out + 1] = sl.name end
      table.sort(out)
      return table.concat(out, " ")
    end
    -- belts and drill spots of a line (a pass that routes the other lines around coal makes them longer)
    local function belts(name)
      local L, n = C.lines[name], 0
      for _, seg in pairs((L and L.status == "ok") and L.belts or {}) do n = n + #seg end
      return n
    end
    local function drills(name)
      local L = C.lines[name]
      return (L and L.status == "ok") and #L.drills or 0
    end
    -- the line's steel chain slot (N2c / S2c: its smelter pair makes steel), or nil
    local function chain_of(name)
      local L = C.lines[name]
      for _, sl in ipairs((L and L.status == "ok") and L.slots or {}) do
        if string.sub(sl.name, -1) == "c" then return sl.name end
      end
      return nil
    end
    local chain0 -- the first plan's chain slot: another one (S1c on seed 701) made no steel in 60 minutes
    local function has_chain(name)
      local c = chain_of(name)
      return c ~= nil and (chain0 == nil or c == chain0)
    end
    -- Phase 5 M2 ai: no copper line at all (seed 704: "no hub slot reachable for copper"): plan again with copper
    -- first, then iron or stone next; kept when copper gets its slots and iron keeps its slots but one and its steel
    -- chain (without copper that nation made no circuit, no bakery and starved)
    chain0 = chain_of("iron")
    if nation and slots("copper") == 0 then
      local base = {iron = slots("iron"), chain = has_chain("iron"), stone = slots("stone")}
      local kept = false
      for pass, order in ipairs({{"copper", "iron", "stone", "coal"}, {"copper", "stone", "iron", "coal"}}) do
        planning_restore(C, snap)
        ctx = layout.context(C, surface)
        for _, name in ipairs(order) do build_order.plan_line(C, ctx, name) end
        local ok = slots("copper") > 0 and slots("iron") >= base.iron - 1 and (has_chain("iron") or not base.chain)
          and slots("stone") >= base.stone
        util.log("ai %s: copper line unavailable: copper first (pass %d): copper %d slots, iron %d (was %d), stone %d"
          .. "%s", C.force, pass, slots("copper"), slots("iron"), base.iron, slots("stone"), ok and ": kept" or "")
        if ok then
          start_lines, kept = order, true -- the coal passes below plan the other lines in this order too
          break
        end
      end
      if not kept then
        planning_restore(C, snap)
        ctx = layout.context(C, surface)
        for _, name in ipairs(start_lines) do build_order.plan_line(C, ctx, name) end
      end
    end
    local first = nation and {iron = slots("iron"), copper = names("copper"), stone = names("stone"),
                              chain = has_chain("iron"),
                              ncopper = slots("copper"), nstone = slots("stone"), lead = lead_slot("copper"),
                              belts = belts("iron") + belts("copper") + belts("stone"), stone_drills = drills("stone")}
                  or nil
    local first_plan = (nation and slots("coal") == 0) and planning_snapshot(C) or nil
    -- (Phase 5 M2 ai: the iron line also keeps its steel chain slot: seed 403's fourth pass dropped it, and that AI made
    -- no steel, so no Industrialisation, in 21 minutes)
    local function strict_ok()
      return names("copper") == first.copper and names("stone") == first.stone and slots("iron") >= first.iron - 1
        and (has_chain("iron") or not first.chain)
    end
    -- Phase 5 M2 ai: on M2's 4-nation worlds the strict rule above left about one force in three without coal (no
    -- hauler trip, no train all match) when the coal hub failed too. A relaxed pass (copper and stone in other slots of
    -- the same kind, iron loses at most one) is the last resort, after the coal hub, and only when the other lines'
    -- belts grow by at most RELAXED_BELTS and stone keeps its drill spots but one (seeds 403-404: a relaxed pass with
    -- an 84-belt stone line and 2 drill spots slowed the whole opening by two minutes).
    local RELAXED_BELTS = 40
    local function relaxed_ok()
      local lead = lead_slot("copper")
      return slots("iron") >= first.iron - 1 and slots("copper") >= first.ncopper and slots("stone") >= first.nstone
        and (lead ~= "X" or first.lead == "X") and (has_chain("iron") or not first.chain)
        and belts("iron") + belts("copper") + belts("stone") <= first.belts + RELAXED_BELTS
        and drills("stone") >= first.stone_drills - 1
    end
    local relaxed -- {snapshot, extra belts} of the cheapest relaxed pass
    -- (Phase 5 M2 ai: a fourth pass routes stone and copper before iron: on seed 702 the two coal-first passes left
    -- stone without a slot)
    local passes = {{data.line_spec("coal", true), start_lines}, {data.NATION_COAL_FALLBACK, start_lines},
                    {data.NATION_COAL_FALLBACK, {"stone", "copper", "iron"}}}
    for pass, P in ipairs(passes) do
      local coal_spec, order = P[1], P[2]
      if not nation or slots("coal") > 0 then break end
      util.log("ai %s: coal line unavailable (%s), planning again with coal first (pass %d)", C.force,
        tostring(C.lines.coal and C.lines.coal.reason), pass + 1)
      planning_restore(C, snap)
      ctx = layout.context(C, surface)
      build_order.plan_line(C, ctx, "coal", coal_spec)
      for _, name in ipairs(order) do
        if name ~= "coal" then build_order.plan_line(C, ctx, name) end
      end
      if slots("coal") > 0 and not strict_ok() then
        local extra = belts("iron") + belts("copper") + belts("stone") - first.belts
        if relaxed_ok() and (not relaxed or extra < relaxed.extra) then
          relaxed = {snap = planning_snapshot(C), extra = extra, pass = pass + 1}
        end
        util.log("ai %s: pass %d gave coal but changed other lines (iron %d of %d slots, copper [%s] was [%s], stone "
          .. "[%s] was [%s], %+d belts, stone drill spots %d of %d)%s", C.force, pass + 1, slots("iron"), first.iron,
          names("copper"), first.copper, names("stone"), first.stone, extra, drills("stone"), first.stone_drills,
          relaxed and relaxed.pass == pass + 1 and ": kept as the last resort" or ": not kept")
        planning_restore(C, first_plan)
        ctx = layout.context(C, surface)
      end
    end
    -- then a coal hub next to the coal patch whose network joins the CC's (towns.coal_hub), then the relaxed pass
    if nation and slots("coal") == 0 and not towns.coal_hub(C, surface) then
      if relaxed then
        planning_restore(C, relaxed.snap)
        util.log("ai %s: no coal hub either: pass %d's plan is kept (%+d belts on the other lines)", C.force,
          relaxed.pass, relaxed.extra)
      else
        towns.coal_pit(C, surface) -- Phase 5 M2 ai: drills straight into stockpiles, the last resort
      end
    end
    prof.stop()
    log({"", string.format("[rts] ai %s: start lines planned (%d reserved tiles) in ", C.force,
      layout.tcount(C.reserved)), prof})
  end
  util.log("ai %s: commander started, difficulty %s, CC %s facing %+d, rally %s", C.force, C.difficulty,
    util.pos_str(home), C.frame.fx, util.pos_str(C.army.rally))
end

---------------------------------------------------------------------------
-- Production: barracks (ai/mix.lua), the builder factory and the workshop factory
---------------------------------------------------------------------------
local function recipe_name(entity)
  local r = entity.get_recipe()
  return r and r.name or nil
end

commander.AMMO_PER_TURRET = 10  -- magazines per turret per minute the factory may make (gun turrets burn about one
                                 -- a second on a walker that soaks hits; uncapped this took ~200 iron a minute)
commander.AMMO_MAX = 30         -- ... and at most this many a minute in all (a turtle's six turrets under fire took
                                 -- every plate in a 1v3 and its barracks made nothing for three minutes)

-- Intermediates the factory makes (balance.intermediates): item -> recipe.
local INTERMEDIATE = {}
for recipe, def in pairs(balance.intermediates or {}) do INTERMEDIATE[def.result] = recipe end

local function factory_recipe_of(item)
  return data.FACTORY_RECIPE[item] or data.WORKSHOP_RECIPE[item] or INTERMEDIATE[item]
end

local flowing = construction.flowing

-- A factory recipe can run: every ingredient is in the network or being produced.
local function recipe_feasible(C, recipe_name_)
  local r = prototypes.recipe[recipe_name_]
  if not r then return false end
  for _, ing in pairs(r.ingredients) do
    if construction.have(C, ing.name) < ing.amount and not flowing(C, ing.name) then return false end
  end
  return true
end

--- The recipe to run now for `item`: its own when every ingredient is at hand (raw plates may be on their way),
--- else the recipe of a missing intermediate (gear, cable, circuit, explosives; depth first). nil when the force
--- cannot make it (a locked recipe, or a raw ingredient that is neither in the network nor produced).
function commander.recipe_for(C, item, depth)
  depth = depth or 0
  local recipe = factory_recipe_of(item)
  local r = recipe and prototypes.recipe[recipe]
  if not r then return nil end
  local fr = game.forces[C.force].recipes[recipe]
  if not (fr and fr.enabled) then return nil end
  for _, ing in pairs(r.ingredients) do
    if construction.have(C, ing.name) < ing.amount then
      if INTERMEDIATE[ing.name] then
        if depth >= 3 then return nil end
        return commander.recipe_for(C, ing.name, depth + 1)
      elseif not flowing(C, ing.name) then
        return nil
      end
    end
  end
  return recipe
end

-- The workshop's demands: {item, want, low, group}. A demand is active while the network holds fewer than `low` of
-- the item, and then stays active until it holds `want` (C.ws_fill, one flag per demand): batches.
--   group "science": the gears (basic kits) or circuits (advanced kits), then the kits, SCIENCE_PER_LAB per lab;
--   group "circuits": circuits while raiders are wanted (also laser turrets and hauler kits);
--   group "explosives": explosives while artillery is wanted.
-- Groups take turns of at most WS_TURN ticks each (round robin in that order) while more than one is active. With a
-- strict priority the always-short science stock kept the aggressive doctrine's workshop from ever making a circuit,
-- so no raider came after Unlock Raider.
commander.WS_TURN = 20 * 60
local function workshop_demands(C)
  local list = {}
  local sci = C.science
  if sci then
    if sci.kit == "rts-science-basic" then
      list[#list + 1] = {item = "iron-gear-wheel", want = data.GEAR_STOCK, low = 2, group = "science"}
    else
      list[#list + 1] = {item = "electronic-circuit", want = data.CIRCUIT_STOCK, low = 4, group = "science"}
    end
    list[#list + 1] = {item = sci.kit, want = sci.want, low = math.max(1, math.floor(sci.want / 2)),
                       group = "science"}
  end
  local lasers = C.unit_recipe ~= nil and deps.research and deps.research.is_unlocked(C.force, "rts-laser-turret")
    and (C.pending["rts-laser-turret"] or 0) > 0
  -- (circuits ahead of Unlock Raider took the workshop's turns and pushed the unlock from 5:15 to 7:45)
  if mix.wanted(C, "raider") or lasers or (C.want_haulers or 0) > 0 then
    list[#list + 1] = {item = "electronic-circuit", want = data.CIRCUIT_STOCK, low = math.floor(data.CIRCUIT_STOCK / 2),
                       group = "circuits"}
  end
  if mix.wanted(C, "artillery") then
    list[#list + 1] = {item = "rts-explosives", want = data.EXPLOSIVE_STOCK, low = math.floor(data.EXPLOSIVE_STOCK / 2),
                       group = "explosives"}
  end
  return list
end

-- The workshop's recipe now (or nil): the active demand of the group whose turn it is.
local function workshop_want(C)
  C.ws_fill = C.ws_fill or {}
  local groups, order = {}, {}
  for _, d in ipairs(workshop_demands(C)) do
    local key = d.item .. "#" .. d.group
    local have = construction.have(C, d.item)
    if have >= d.want then
      C.ws_fill[key] = nil
    elseif C.ws_fill[key] or have < d.low then
      local recipe = commander.recipe_for(C, d.item)
      if recipe and not groups[d.group] then
        groups[d.group] = {recipe = recipe, key = key}
        order[#order + 1] = d.group
      end
    end
  end
  if #order == 0 then
    C.ws_turn = nil
    return nil
  end
  local turn = C.ws_turn
  local pick
  if turn and groups[turn.group] and game.tick - turn.since < commander.WS_TURN then
    pick = turn.group
  else
    -- the next active group after the current one (round robin in priority order)
    local idx = 0
    for i, g in ipairs(order) do
      if turn and g == turn.group then idx = i end
    end
    pick = order[(idx % #order) + 1]
    C.ws_turn = {group = pick, since = game.tick}
  end
  C.ws_fill[groups[pick].key] = true
  return groups[pick].recipe
end

-- True while the force wants another hauler (hubs.lua) and none is on its way.
local function hauler_due(C)
  return (C.want_haulers or 0) > hubs.hauler_count(C)
end

-- The first item the construction queue lacks that the factory can make now (intermediates first when one is
-- missing), else the first lacking item's own recipe; `skip` = a recipe another factory already runs. A due hauler
-- kit comes first: it is built like a building (the builder keeps the recipe until the kit is out), because the
-- workshop switching between science and a 30-plate kit never gathered the plates.
local function construction_want(C, skip)
  local function short(item) return construction.have(C, item) < (C.need[item] or 0) end
  if hauler_due(C) and skip ~= "rts-hauler-kit" then
    local now = commander.recipe_for(C, "rts-hauler-kit")
    if now then return now end
  end
  local fallback
  for _, item in ipairs(C.need_list) do
    local recipe = data.FACTORY_RECIPE[item]
    if recipe and short(item) and recipe ~= skip then
      fallback = fallback or recipe
      local now = commander.recipe_for(C, item)
      if now then return now end
    end
  end
  return fallback
end

-- Builder factory (the force's first): the first item the construction queue lacks whose recipe can run (so a
-- recipe that needs a resource the force has run out of does not block the one that would bring it back); ammo
-- while turrets run low, at most AMMO_PER_TURRET magazines per turret per minute; with nothing to build and no
-- workshop, the workshop's work; else it idles, so the iron goes to units.
local function manage_builder(C, factory, has_workshop)
  local e = factory.entity
  local cur = recipe_name(e)
  local ammo = data.FACTORY_RECIPE["firearm-magazine"]
  local turrets = buildings.count(C.force, "turret")
  if cur == ammo and (not C.ammo_pf or e.products_finished > C.ammo_pf) then
    -- one craft (10 magazines) done: the next one waits its share of the per-minute budget
    C.ammo_block = game.tick + math.floor(60 * 60 * 10 / math.min(commander.AMMO_MAX,
      commander.AMMO_PER_TURRET * math.max(1, turrets)))
    C.ammo_pf = nil
  end
  local function short(item) return construction.have(C, item) < (C.need[item] or 0) end
  local want = construction_want(C)
  if cur == ammo and C.ammo_pf and not want then return cur end -- the budgeted ammo craft is still running
  if not want and turrets > 0 and construction.have(C, "firearm-magazine") < data.TURRET_MAGAZINES
     and game.tick >= (C.ammo_block or 0) and cur ~= ammo then
    want = ammo
  end
  local ws = false
  if not want and not has_workshop then
    want = workshop_want(C)
    ws = want ~= nil
  end
  if cur == want then return cur end
  -- keep a recipe that still makes something short and can run, so two shortages do not make it flip every second
  if cur and cur ~= ammo and recipe_feasible(C, cur) then
    for item, recipe in pairs(data.FACTORY_RECIPE) do
      if recipe == cur and short(item) then return cur end
    end
    if cur == "rts-hauler-kit" and hauler_due(C) then return cur end
    if ws and e.is_crafting() and game.tick - (C.factory_set or 0) < commander.FACTORY_DWELL then return cur end
  end
  -- let a building craft finish (the factory pulls ingredients for two crafts, so it is nearly always crafting);
  -- ammo is cut off at once when its budget is spent (its ingredients go back to the network)
  if cur and cur ~= ammo and e.is_crafting()
     and (want == nil or game.tick - (C.factory_set or 0) < commander.FACTORY_DWELL) then
    return cur
  end
  if production.set_recipe(e, want) then
    C.factory_set = game.tick
    if want == ammo then C.ammo_pf = e.products_finished end
  end
  return want
end

-- Workshop factory (the force's second and later): science kits for the running research, circuits for raiders,
-- lasers and hauler kits, explosives for artillery (workshop_demands); with none of those it idles.
-- A feeder workshop (the third factory and later) makes the intermediates the first workshop's work needs ahead of
-- time: gears for basic kits (or circuits for advanced ones) up to FEEDER_STOCK crafts' worth, else whatever the
-- workshop demands that the first workshop is not making. One workshop spent half its time on gears (~6 kits a
-- minute); with a feeder the first one makes kits back to back.
commander.FEEDER_STOCK = 2
local function feeder_want(C, taken)
  local sci = C.science
  if sci then
    local basic = sci.kit == "rts-science-basic"
    local item = basic and "iron-gear-wheel" or "electronic-circuit"
    local stock = commander.FEEDER_STOCK * (basic and data.GEAR_STOCK or data.CIRCUIT_STOCK)
    if construction.have(C, item) < stock then
      local r = commander.recipe_for(C, item)
      if r and not taken[r] then return r end
    end
  end
  local r = workshop_want(C)
  if r and not taken[r] then return r end
  return nil
end

-- Phase 5 M2 ai: recipes that use copper (plates, cable, circuits) wait while the copper bootstrap is on (C.boot)
local function uses_copper(recipe)
  local r = recipe and prototypes.recipe[recipe]
  if not r then return false end
  for _, ing in pairs(r.ingredients) do
    if ing.name == "copper-plate" or ing.name == "copper-cable" or ing.name == "electronic-circuit" then return true end
  end
  return false
end

local function manage_workshop(C, factory, builder_recipe, taken)
  local e = factory.entity
  local cur = recipe_name(e)
  local want
  if taken then want = feeder_want(C, taken) else want = workshop_want(C) end
  -- (science kits go on above BOOT_CRITICAL plates: stopping them cost the aggressive AI its 6-minute technologies)
  if C.boot and C.boot["copper-plate"] and construction.have(C, "copper-plate") < build_order.BOOT_CRITICAL
     and uses_copper(want) then want = nil end
  -- no construction help: with plates short, a second and third factory crafting buildings in parallel only split
  -- the plates (a lab took three minutes while all three factories took turns on it)
  if cur == want then return end
  -- batches: a running recipe stays at least FACTORY_DWELL while it is still useful
  C.ws_set = C.ws_set or {}
  local un = e.unit_number
  if cur and e.is_crafting() and game.tick - (C.ws_set[un] or 0) < commander.FACTORY_DWELL
     and recipe_feasible(C, cur) and want ~= nil then
    return
  end
  if production.set_recipe(e, want) then C.ws_set[un] = game.tick end
end

-- True when the workshop has starved on workshop work (science, hauler kits, their intermediates) for
-- BUILDER_YIELD: the builder then pauses too (production.lua serves the oldest-starved consumer and lets a consumer
-- short of one item reserve it, so the builder's 20-40 plate bites came first and a gear took ~20 s). The builder
-- pauses at most BUILDER_SHARE of each BUILDER_WINDOW: uncapped, the always-hungry workshop kept it from finishing
-- a smelter for over a minute.
commander.BUILDER_YIELD = 4 * 60
commander.BUILDER_WINDOW = 60 * 60
commander.BUILDER_SHARE = 0.35
local function workshop_starved(C, rec)
  local r = recipe_name(rec.entity)
  local st = rec.pull_state
  return r ~= nil and mix.WORKSHOP_RECIPES[r] and rec.starved_since ~= nil and st ~= nil
    and string.sub(st, 1, 7) == "starved" and game.tick - rec.starved_since >= commander.BUILDER_YIELD
end

local function manage_factories(C)
  local list = {}
  for un, rec in buildings.for_force(C.force, "factory") do
    -- Phase 5 E1: a factory on Auto (the Nation-mode works factory, ai/age_up.lua) follows the make targets
    if rec.recipe_mode ~= "auto" then list[#list + 1] = {un, rec} end
  end
  if #list == 0 then return end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  local hungry = false
  for i = 2, #list do
    if workshop_starved(C, list[i][2]) then hungry = true end
  end
  local builder = list[1][2]
  local brecipe = recipe_name(builder.entity)
  local tick = game.tick
  local win = C.builder_win
  if not win or tick - win.start >= commander.BUILDER_WINDOW then
    win = {start = tick, used = 0}
    C.builder_win = win
  end
  if hungry and win.used >= commander.BUILDER_SHARE * commander.BUILDER_WINDOW then hungry = false end
  if hungry then win.used = win.used + commander.THINK end
  if hungry and not builder.entity.is_crafting() and brecipe ~= nil and not mix.WORKSHOP_RECIPES[brecipe] then
    -- the builder steps aside for one pass: its partial ingredients go back to the network for the workshop
    production.set_recipe(builder.entity, nil)
    C.stats.builder_yields = (C.stats.builder_yields or 0) + 1
  elseif not hungry then
    manage_builder(C, builder, #list > 1)
  end
  local builder_recipe = recipe_name(builder.entity)
  local taken = {}
  for i = 2, #list do
    manage_workshop(C, list[i][2], builder_recipe, i > 2 and taken or nil)
    local r = recipe_name(list[i][2].entity)
    if r then taken[r] = true end
  end
end

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------
-- Per-subsystem profilers (optional, set by init.lua for the performance log; not game state).
local prof
function commander.set_profilers(p) prof = p end
local function start(name) if prof then prof[name].restart() end end
local function stop(name) if prof then prof[name].stop() end end
-- (Phase 5 M2 ai: "production" is the factories only; tech, age_up, barracks, governor and nation are their own parts)
commander.PARTS = {"build_order", "construction", "production", "army", "scout", "tech", "age_up", "barracks", "governor",
                   "nation"}

--- One commander run (init.lua schedules it every THINK ticks).
-- Phase 5 M3 perf: a run in slices. commander.run(C) runs every part at once (Skirmish, exactly as before);
-- commander.run(C, k) only slice k of commander.SLICES (Nation mode: ai/init.lua runs slice 1 when the commander is due
-- and slices 2 and 3 on its next two ai.TICK ticks, so no tick holds a whole run): 1 economy and planning (build order,
-- construction, hubs, rails, cities, towns, market), 2 research, age-up, barracks and factories, 3 governor, strategist,
-- army and scouting.
commander.SLICES = 3
function commander.run(C, slice)
  local surface = util.surface()
  local tick = game.tick
  layout.tmigrate(C) -- Phase 5 M3 perf: tile sets of a commander from an older save
  if slice == nil or slice == 1 then C.runs = C.runs + 1 end
  local m = storage.match
  if m and m.phase == "ended" then return end
  local s1, s2, s3 = slice == nil or slice == 1, slice == nil or slice == 2, slice == nil or slice == 3
  local cc = buildings.main_cc(C.force)
  if cc and s1 then
    local ctx
    local function get_ctx()
      if not ctx then ctx = layout.context(C, surface) end
      return ctx
    end
    start("build_order")
    build_order.step(C, surface, get_ctx)
    build_order.bootstrap(C) -- Phase 5 M2 ai: a start line that does not run yet comes first when its plate runs low
    stop("build_order")
    start("construction")
    construction.step(C, surface)
    if tick >= (C.next_repair or 0) then
      C.next_repair = tick + commander.REPAIR_TICKS
      construction.repair(C)
    end
    hubs.step(C)
    if deps.rails then deps.rails.ai_step(C) end -- Phase 5 M1 (m1-rails): a line to a far hub/city, Nation mode only
    if deps.cities then deps.cities.ai_step(C, surface) end -- Phase 5 M1: Nation mode second city (no-op in Skirmish)
    towns.step(C, surface) -- Phase 5 M1 integration: the town's mining line (Nation mode only)
    if deps.market then -- Phase 5 M2 treasury: ports, sales, imports, taxes (Nation only)
      deps.market.AI.taxes, deps.market.AI.sell = false, false -- Phase 5 M2 ai: the strategist (ai/nation.lua) runs them
      deps.market.ai_step(C)
    end
    stop("construction")
  end
  if cc and s2 then
    start("tech")
    if tick >= (C.next_tech or 0) then
      C.next_tech = tick + tech.PERIOD
      tech.step(C)
    end
    stop("tech")
    start("age_up")
    if deps.ages and deps.ages.is_nation() then age_up.step(C, surface) end -- Phase 5 E1
    stop("age_up")
    start("barracks")
    mix.manage_barracks(C)
    stop("barracks")
    start("production")
    manage_factories(C)
    stop("production")
  end
  if cc and s3 then
    start("governor")
    governor.step(C, surface) -- Phase 5 M2 ai: city governors (takes over population.ai_step; Nation mode only)
    stop("governor")
    start("nation")
    nation_ai.step(C, surface) -- Phase 5 M2 ai: the nation strategist (Nation mode only)
    stop("nation")
  end
  if not s3 then return end
  start("army")
  army.step(C, surface)
  stop("army")
  if tick >= (C.next_scout or 0) then
    C.next_scout = tick + scout.PERIOD
    start("scout")
    scout.step(C, surface)
    stop("scout")
  end
end

--- Lines describing commander C (for /rts-ai-dump and the autotest).
function commander.dump_lines(C)
  local lines = {}
  local order = data.order(C.difficulty, C.doctrine, deps.ages ~= nil and deps.ages.is_nation()) -- Phase 5 M1
  local cur = C.current_step and order[C.current_step]
  local done = 0
  for i = 1, #order do
    if C.steps[i] and C.steps[i].done then done = done + 1 end
  end
  local pend = {}
  for name, n in pairs(C.pending) do pend[#pend + 1] = name .. "=" .. n end
  table.sort(pend)
  lines[#lines + 1] = string.format("ai %s (%s, %s): t=%ds runs=%d steps done %d/%d, next: %s | queue %d [%s]",
    C.force, C.difficulty, C.doctrine, (game.tick - C.started) / 60, C.runs, done, #order,
    cur and build_order.describe(cur) or "-", #C.queue, table.concat(pend, " "))
  local lp = {}
  for _, name in ipairs({"iron", "copper", "stone", "coal", "iron2"}) do
    local L = C.lines[name]
    if L then
      if L.status == "ok" then
        lp[#lp + 1] = string.format("%s drills %d/%d slots %d/%d%s", name, build_order.line_drills_built(C, L),
          #L.drills, build_order.line_slots_built(C, L), #L.slots, L.chained and "" or " UNPOWERED")
      else
        lp[#lp + 1] = string.format("%s unavailable (%s)", name, tostring(L.reason))
      end
    end
  end
  lines[#lines + 1] = string.format("ai %s lines: %s", C.force, table.concat(lp, "; "))
  local kinds = {}
  for _, kind in ipairs({"cc", "extractor", "smelter", "barracks", "factory", "turret", "solar", "stockpile", "lab",
                         "hub"}) do
    kinds[#kinds + 1] = kind .. "=" .. buildings.count(C.force, kind)
  end
  kinds[#kinds + 1] = "laser=" .. build_order.base_count(C, "rts-laser-turret")
  local st = C.stats
  lines[#lines + 1] = string.format("ai %s buildings [%s] | ghosts=%d revived=%d jobs=%d bad=%d | recipe=%s",
    C.force, table.concat(kinds, " "), st.ghosts, st.revived, st.jobs, st.bad, tostring(C.unit_recipe))
  lines[#lines + 1] = string.format("ai %s army: %s | attacks=%d reinforcements=%d retreats=%d defends=%d recalls=%d"
    .. " harass=%d guards=%d patrols=%d priority=%d", C.force, army.describe(C), st.attacks, st.reinforcements,
    st.retreats, st.defends, st.recalls, st.harass or 0, st.guards or 0, st.patrols or 0, st.priority or 0)
  lines[#lines + 1] = string.format("ai %s mix: units [%s] desired [%s] supply %s/%s%s", C.force,
    mix.describe(C.mix_counts), mix.describe(C.mix_weights), tostring(C.supply_used), tostring(C.supply_cap),
    C.capped and " CAPPED" or "")
  local done_t = {}
  for name, t in pairs(C.tech and C.tech.done or {}) do done_t[#done_t + 1] = {name, t} end
  table.sort(done_t, function(x, y) return x[2] < y[2] or (x[2] == y[2] and x[1] < y[1]) end)
  for i, p in ipairs(done_t) do done_t[i] = string.format("%s@%ds", p[1], (p[2] - C.started) / 60) end
  local labs, working = 0, 0
  if deps.research then labs, working = deps.research.lab_counts(C.force) end
  lines[#lines + 1] = string.format("ai %s research: labs %d (working %d), current %s, done %d [%s]", C.force, labs,
    working, C.science and C.science.tech or "-", #done_t, table.concat(done_t, " "))
  lines[#lines + 1] = string.format("ai %s hubs: %s", C.force, hubs.describe(C))
  local kk = {}
  for k, n in pairs(scout.known_by_kind(C)) do kk[#kk + 1] = k .. "=" .. n end
  table.sort(kk)
  local guesses = {}
  for f in pairs(C.guesses) do guesses[#guesses + 1] = f end
  table.sort(guesses)
  lines[#lines + 1] = string.format("ai %s scout: vision=%s visible chunks=%d known enemy buildings %d [%s] seen=%d "
    .. "guesses [%s]", C.force, C.cfg.vision, scout.visible_chunks(C, util.surface(), layout.arena_half()), table_size(C.known),
    table.concat(kk, " "), st.seen, table.concat(guesses, " "))
  return lines
end

return commander
