-- AI commander (docs/PHASE3.md "ai/commander.lua"): one per AI force, state in storage.ai[force_name]. A run is
-- economy (build order) -> construction -> production -> army -> scouting.
--
-- storage.ai[force_name] = C = {
--   force, difficulty, cfg (orders_data.DIFFICULTY copy), started, next_tick, runs,
--   frame       layout frame of the main CC {cx, cy, fx}
--   reserved    {[tile key] = owner}   tiles the plan uses ("hub", a line name, "building")
--   avoid       {[tile key] = true}    tiles in front of a line's last belt: no belt may ever go there
--   belt_tiles  {[tile key] = true}    planned belt tiles
--   hub         {[slot] = "free" | "dead" | line name}
--   claimed     {[patch id] = line name}
--   lines       {[name] = line}        build_order.lua
--   plan, queue, pending, need, need_list, next_build      construction.lua
--   steps       {[i] = {done?, started?, skipped?, retry_at?}}, current_step     build_order.lua
--   unit_recipe nil until the build order enables unit production; heavy_barracks = unit number on heavy kits
--   army        army.lua;  known, guesses   scout.lua
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

--- New commander state (not started). difficulty: "easy" | "normal" | "hard".
function commander.new(force_name, difficulty)
  difficulty = data.DIFFICULTY[difficulty] and difficulty or data.DEFAULT_DIFFICULTY
  return {
    force = force_name, difficulty = difficulty, cfg = copy(data.DIFFICULTY[difficulty]),
    started = game.tick, next_tick = game.tick + 1, runs = 0,
    reserved = {}, avoid = {}, belt_tiles = {}, claimed = {}, lines = {},
    plan = {}, queue = {}, pending = {}, need = {}, need_list = {}, next_build = 0,
    steps = {}, known = {}, guesses = {},
    stats = {ghosts = 0, revived = 0, jobs = 0, bad = 0, seen = 0, attacks = 0, reinforcements = 0, retreats = 0,
             defends = 0, recalls = 0, bonus_units = 0, bots_removed = 0},
  }
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
    for _, name in ipairs(data.START_LINES) do build_order.plan_line(C, ctx, name) end
    prof.stop()
    log({"", string.format("[rts] ai %s: start lines planned (%d reserved tiles) in ", C.force,
      table_size(C.reserved)), prof})
  end
  util.log("ai %s: commander started, difficulty %s, CC %s facing %+d, rally %s", C.force, C.difficulty,
    util.pos_str(home), C.frame.fx, util.pos_str(C.army.rally))
end

---------------------------------------------------------------------------
-- Production: barracks recipes and rally points, the factory recipe
---------------------------------------------------------------------------
local function recipe_name(entity)
  local r = entity.get_recipe()
  return r and r.name or nil
end

local function manage_barracks(C)
  local heavy_ok = C.cfg.heavy and construction.have(C, "steel-plate") >= data.HEAVY_STEEL
    and construction.have(C, "iron-plate") >= data.HEAVY_IRON
  local hb = C.heavy_barracks and buildings.get(C.heavy_barracks)
  if not hb then C.heavy_barracks = nil end
  for un, rec in buildings.for_force(C.force, "barracks") do
    local rally = C.army.rally
    if rally and not (rec.rally and util.distance(rec.rally, rally) < 1) then buildings.set_rally(un, rally) end
    local want = C.unit_recipe
    if want then
      if C.heavy_barracks == un then
        if heavy_ok then want = data.HEAVY_KIT end
      elseif heavy_ok and not C.heavy_barracks then
        C.heavy_barracks = un
        want = data.HEAVY_KIT
      end
    end
    local cur = recipe_name(rec.entity)
    if cur ~= want and (cur == nil or not rec.entity.is_crafting()) then
      production.set_recipe(rec.entity, want)
      if want ~= data.HEAVY_KIT and C.heavy_barracks == un then C.heavy_barracks = nil end
    end
  end
end

-- The factory makes whatever the construction queue lacks first; ammo while turrets run low; else it idles so the
-- iron goes to units.
local function manage_factory(C)
  local factory
  for un, rec in buildings.for_force(C.force, "factory") do
    if not factory or un < factory.entity.unit_number then factory = rec end
  end
  if not factory then return end
  local function short(item) return construction.have(C, item) < (C.need[item] or 0) end
  local want
  for _, item in ipairs(C.need_list) do
    local recipe = data.FACTORY_RECIPE[item]
    if recipe and short(item) then
      want = recipe
      break
    end
  end
  if not want and buildings.count(C.force, "turret") > 0
     and construction.have(C, "firearm-magazine") < data.TURRET_MAGAZINES then
    want = data.FACTORY_RECIPE["firearm-magazine"]
  end
  local e = factory.entity
  local cur = recipe_name(e)
  if cur == want then return end
  -- keep a recipe that still makes something short, so two shortages do not make it flip every second
  if cur then
    for item, recipe in pairs(data.FACTORY_RECIPE) do
      if recipe == cur and (short(item) or (recipe == "rts-ammo" and want == recipe)) then return end
    end
    if e.is_crafting() and want == nil then return end
    if game.tick - (C.factory_set or 0) < commander.FACTORY_DWELL and want ~= nil and e.is_crafting() then return end
  end
  if production.set_recipe(e, want) then C.factory_set = game.tick end
end

local function manage_production(C)
  manage_barracks(C)
  manage_factory(C)
end

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------
-- Per-subsystem profilers (optional, set by init.lua for the performance log; not game state).
local prof
function commander.set_profilers(p) prof = p end
local function start(name) if prof then prof[name].restart() end end
local function stop(name) if prof then prof[name].stop() end end
commander.PARTS = {"build_order", "construction", "production", "army", "scout"}

--- One commander run (init.lua schedules it every THINK ticks).
function commander.run(C)
  local surface = util.surface()
  local tick = game.tick
  C.runs = C.runs + 1
  local m = storage.match
  if m and m.phase == "ended" then return end
  local cc = buildings.main_cc(C.force)
  if cc then
    local ctx
    local function get_ctx()
      if not ctx then ctx = layout.context(C, surface) end
      return ctx
    end
    start("build_order")
    build_order.step(C, surface, get_ctx)
    stop("build_order")
    start("construction")
    construction.step(C, surface)
    if tick >= (C.next_repair or 0) then
      C.next_repair = tick + commander.REPAIR_TICKS
      construction.repair(C)
    end
    stop("construction")
    start("production")
    manage_production(C)
    stop("production")
  end
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
  local order = data.BUILD_ORDERS[C.difficulty]
  local cur = C.current_step and order[C.current_step]
  local done = 0
  for i = 1, #order do
    if C.steps[i] and C.steps[i].done then done = done + 1 end
  end
  local pend = {}
  for name, n in pairs(C.pending) do pend[#pend + 1] = name .. "=" .. n end
  table.sort(pend)
  lines[#lines + 1] = string.format("ai %s (%s): t=%ds runs=%d steps done %d/%d, next: %s | queue %d [%s]",
    C.force, C.difficulty, (game.tick - C.started) / 60, C.runs, done, #order,
    cur and build_order.describe(cur) or "-", #C.queue, table.concat(pend, " "))
  local lp = {}
  for _, name in ipairs({"iron", "copper", "stone", "iron2"}) do
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
  for _, kind in ipairs({"cc", "extractor", "smelter", "barracks", "factory", "turret", "solar", "stockpile"}) do
    kinds[#kinds + 1] = kind .. "=" .. buildings.count(C.force, kind)
  end
  local st = C.stats
  lines[#lines + 1] = string.format("ai %s buildings [%s] | ghosts=%d revived=%d jobs=%d bad=%d | recipe=%s heavy=%s",
    C.force, table.concat(kinds, " "), st.ghosts, st.revived, st.jobs, st.bad, tostring(C.unit_recipe),
    tostring(C.heavy_barracks))
  lines[#lines + 1] = string.format("ai %s army: %s | attacks=%d reinforcements=%d retreats=%d defends=%d recalls=%d",
    C.force, army.describe(C), st.attacks, st.reinforcements, st.retreats, st.defends, st.recalls)
  local kk = {}
  for k, n in pairs(scout.known_by_kind(C)) do kk[#kk + 1] = k .. "=" .. n end
  table.sort(kk)
  local guesses = {}
  for f in pairs(C.guesses) do guesses[#guesses + 1] = f end
  table.sort(guesses)
  lines[#lines + 1] = string.format("ai %s scout: vision=%s visible chunks=%d known enemy buildings %d [%s] seen=%d "
    .. "guesses [%s]", C.force, C.cfg.vision, scout.visible_chunks(C, util.surface(), 80), table_size(C.known),
    table.concat(kk, " "), st.seen, table.concat(guesses, " "))
  return lines
end

return commander
