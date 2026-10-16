-- Phase 5 M2 treasury (docs/PHASE5-M2.md section 3 "treasury.lua / market.lua", decision D1; study
-- docs/research/scale/deep-economy.md sections 4.2 and 4.5; docs/qa/phase5-treasury-notes.md). Nation mode only: in
-- Skirmish nothing here does any work and every query answers as for an empty treasury.
--
-- The treasury is a script number per nation (crowns, cr). Nothing is built with money: it pays upkeep, soldiers and
-- imports, and comes from taxes and exports (scripts/market.lua).
--
--   treasury.get(force) -> {balance, income = {tax, exports, other}, expenses = {buildings, army, transport, imports,
--                           interest, other}, stage = 0..3, tax = "low"|"normal"|"high", net, credit, rates}
--                          income / expenses are cr over the last minute (a rolling window of 6 x 10 s)
--   treasury.add(force, cr, why) / treasury.charge(force, cr, why) -> ok   (charge never goes below the credit line)
--   treasury.set_tax(force, level), treasury.tax_of(force)
--   treasury.score(force) -> net cr per minute;  treasury.stage(force) -> 0..3;  treasury.balance(force)
--   treasury.on_stage(fn)   fn(force_name, stage, old_stage), load time only. This module itself calls M2 people when
--                           loaded: labor.set_penalty(force, 1, "unpaid") at stage 2+, population.set_mood(force,
--                           "debt", -25) at stage 3, population.set_mood(force, "tax", n) on a tax change
--
-- Flows (balance.nation.treasury, every STEP ticks one tenth-of-a-minute... a sixth of the per-minute rate):
--   tax       residents x 0.2 x tax level (0.6 / 1.0 / 1.4) x happiness factor (0.5 at 0 .. 1.2 at 100); residents and
--             happiness per city from scripts/population.lua when it is loaded (population.of(city).pop / .happiness,
--             or storage.population[city]), else a fallback by city tier; hard AI +20 %
--   buildings 1 per Age I building, 4 per Age II building (balance.nation.economy.buildings), half for a crafting
--             machine without a recipe or switched off by script; walls, stockpiles, solar, accumulators, rolling
--             stock, project sites, the Command Center, City Centers and trade posts pay nothing
--   army      1 per supply point of the force's military units (haulers and the Commander excluded)
--   transport 2 per locomotive + 1 per 100 tiles of the force's rail lines (storage.rails.lines)
--   interest  5 % of the debt every 5 minutes
-- Upkeep and interest are paid down to the credit line (10 minutes of gross income, at least `credit.min`); a nation
-- that hits it is in stage 3 at once.
--
-- Debt stages (checked every STAGE_PERIOD ticks and after every change of the balance):
--   0  balance >= 0
--   1  deficit: balance < 0. Imports are blocked (market.buy), the HUD balance turns red, interest accrues
--   2  unpaid wages: below 0 for 60 s. Barracks refuse kits (production kit gate, reason "unpaid"); on_stage hooks
--      (labor: every building one staffing step lower)
--   3  unrest: below 0 for 180 s or at the credit line. on_stage hooks (people: happiness -25)
-- Every stage clears as soon as the balance is back at 0 or more. Signal "rts_treasury_stage" {force, stage, old}.
--
-- Owns storage.treasury = {[force] = N}: N = {match_id, balance, tax, stage, below_since, rates = {tax, buildings,
--   army, transport}, counts, buckets = {{id, income = {}, expenses = {}} x 6}, totals = {income, expenses},
--   next_interest, credit, pop, happiness, stage_log = {{tick, stage}}}. Cleared at match teardown.
-- Log lines "[rts] treasury: ...". Console: /rts-treasury [force] [set <cr> | add <cr> | tax <level>].
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local supply = require("scripts.supply")
local match = require("scripts.match")
local balance = require("balance")

local treasury = {}

local TB = balance.nation.treasury
treasury.STEP = TB.step
treasury.STAGE_PERIOD = 60
treasury.BUCKET = 600           -- ticks per bucket of the rolling minute
treasury.BUCKETS = 6
treasury.MINUTE = 60 * 60
treasury.LOCO = "rts-locomotive"
treasury.LEVELS = {"low", "normal", "high"}
treasury.INCOME = {"tax", "exports", "other"}
treasury.EXPENSES = {"buildings", "army", "transport", "imports", "interest", "other"}
-- why -> category (anything else is "other")
treasury.CATEGORY = {
  tax = "tax", exports = "exports", sale = "exports", ["contract-sale"] = "exports",
  imports = "imports", purchase = "imports", ["contract-buy"] = "imports", refund = "imports",
  buildings = "buildings", army = "army", transport = "transport", interest = "interest",
}
-- whys that are not logged one by one (the per-minute line sums them)
local QUIET = {tax = true, buildings = true, army = true, transport = true}

-- Age II buildings pay age2 (balance.nation.economy.buildings: districts, refinery, chemical plant, pumpjack, bunker)
local AGE2 = {}
for name in pairs(balance.nation.economy and balance.nation.economy.buildings or {}) do AGE2[name] = true end
treasury.AGE2 = AGE2

local stage_hooks = {}
--- fn(force_name, stage, old_stage) whenever a nation's debt stage changes. Load time only.
function treasury.on_stage(fn) stage_hooks[#stage_hooks + 1] = fn end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

--- True while a Nation-mode match runs (the treasury works).
function treasury.active()
  local m = storage.match
  return m ~= nil and m.surface ~= nil and m.config ~= nil and m.config.mode == "nation"
    and (m.phase == "running" or m.phase == "ended")
end

local function is_nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

--- "1,240" (thousands separators, rounded to whole crowns).
function treasury.fmt(cr)
  local n = math.floor(math.abs(cr or 0) + 0.5)
  local s = tostring(n)
  local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
  if string.sub(out, 1, 1) == "," then out = string.sub(out, 2) end
  if (cr or 0) < 0 and n > 0 then out = "-" .. out end
  return out
end

local function zero(keys)
  local t = {}
  for _, k in ipairs(keys) do t[k] = 0 end
  return t
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function fresh(force_name)
  local m = storage.match
  local N = {match_id = m and m.match_id, force = force_name, balance = TB.start, tax = "normal", stage = 0,
             rates = {tax = 0, buildings = 0, army = 0, transport = 0}, counts = {}, buckets = {},
             totals = {income = zero(treasury.INCOME), expenses = zero(treasury.EXPENSES)},
             next_interest = game.tick + TB.interest.period, credit = TB.credit.min, pop = 0, happiness = 70,
             stage_log = {}}
  for i = 1, treasury.BUCKETS do N.buckets[i] = {id = -1, income = {}, expenses = {}} end
  return N
end

--- The record of a nation (created on first use while a Nation match runs), or nil.
local function N_of(force_name)
  if not (force_name and is_nation_mode()) then return nil end
  storage.treasury = storage.treasury or {}
  local N = storage.treasury[force_name]
  local m = storage.match
  if N and N.match_id ~= (m and m.match_id) then N = nil end
  if not N then
    if not match.is_participant(force_name) then return nil end
    N = fresh(force_name)
    storage.treasury[force_name] = N
    util.log("treasury: %s opens with %s cr (match %s)", force_name, treasury.fmt(N.balance), tostring(N.match_id))
  end
  return N
end
treasury.record = N_of

function treasury.init()
  storage.treasury = storage.treasury or {}
end

match.on_teardown(function() storage.treasury = {} end)

---------------------------------------------------------------------------
-- Rolling minute
---------------------------------------------------------------------------
local function bucket(N)
  local id = math.floor(game.tick / treasury.BUCKET)
  local B = N.buckets[id % treasury.BUCKETS + 1]
  if B.id ~= id then
    B.id, B.income, B.expenses = id, {}, {}
  end
  return B
end

local function window(N)
  local cur = math.floor(game.tick / treasury.BUCKET)
  local income, expenses = zero(treasury.INCOME), zero(treasury.EXPENSES)
  for _, B in ipairs(N.buckets) do
    if B.id > cur - treasury.BUCKETS then
      for k, v in pairs(B.income) do income[k] = (income[k] or 0) + v end
      for k, v in pairs(B.expenses) do expenses[k] = (expenses[k] or 0) + v end
    end
  end
  return income, expenses
end

local function sum(t)
  local n = 0
  for _, v in pairs(t) do n = n + v end
  return n
end

---------------------------------------------------------------------------
-- Stages
---------------------------------------------------------------------------
local STAGE_KEYS = {[0] = "rts-treasury.alert-stage-0", "rts-treasury.alert-stage-1", "rts-treasury.alert-stage-2",
                    "rts-treasury.alert-stage-3"}

local function home_position(force_name)
  local cc = buildings.main_cc(force_name)
  return cc and cc.position or nil
end

local function alert(force_name, kind, text, params)
  supply.alert(force_name, kind, text, params, home_position(force_name))
end

local function update_stage(force_name, N)
  local now = game.tick
  local s
  if N.balance >= 0 then
    N.below_since = nil
    s = 0
  else
    N.below_since = N.below_since or now
    local below = now - N.below_since
    s = 1
    if below >= TB.stages.unpaid * 60 then s = 2 end
    if below >= TB.stages.unrest * 60 or N.balance <= -(N.credit or TB.credit.min) then s = 3 end
  end
  if s == N.stage then return s end
  local old = N.stage
  N.stage = s
  N.stage_log[#N.stage_log + 1] = {tick = now, stage = s}
  while #N.stage_log > 20 do table.remove(N.stage_log, 1) end
  util.log("treasury: %s stage %d -> %d at tick %d (balance %s, below 0 for %.1f s, credit line %s)", force_name, old,
    s, now, treasury.fmt(N.balance), N.below_since and (now - N.below_since) / 60 or 0, treasury.fmt(N.credit))
  if s > old or s == 0 then
    alert(force_name, s == 0 and "treasury-recovered" or "treasury-stage", STAGE_KEYS[s], {treasury.fmt(N.balance)})
  end
  for i = 1, #stage_hooks do stage_hooks[i](force_name, s, old) end
  events.emit("rts_treasury_stage", {force = force_name, stage = s, old = old})
  return s
end

---------------------------------------------------------------------------
-- Money in and out
---------------------------------------------------------------------------
local function book(N, side, why, cr)
  local cat = treasury.CATEGORY[why] or "other"
  if side == "income" and cat ~= "tax" and cat ~= "exports" then cat = "other" end
  if side == "expenses" and (cat == "tax" or cat == "exports") then cat = "other" end
  local B = bucket(N)
  B[side][cat] = (B[side][cat] or 0) + cr
  N.totals[side][cat] = (N.totals[side][cat] or 0) + cr
end

--- Credit `cr` (>= 0) to a nation. Returns the new balance, or nil outside a Nation match.
function treasury.add(force_name, cr, why)
  local N = N_of(force_name)
  if not N or not cr or cr ~= cr then return nil end
  if cr < 0 then return treasury.pay(force_name, -cr, why) end
  N.balance = N.balance + cr
  book(N, "income", why or "other", cr)
  if not QUIET[why] then
    util.log("treasury: %s +%.1f cr (%s) -> %s", force_name, cr, tostring(why), treasury.fmt(N.balance))
  end
  update_stage(force_name, N)
  return N.balance
end

--- Mandatory payment (upkeep, interest): paid down to the credit line; what does not fit is not paid. Returns paid.
function treasury.pay(force_name, cr, why)
  local N = N_of(force_name)
  if not N or not cr or cr <= 0 then return 0 end
  local floor_ = -(N.credit or TB.credit.min)
  local paid = math.max(0, math.min(cr, N.balance - floor_))
  N.balance = N.balance - paid
  book(N, "expenses", why or "other", paid)
  if not QUIET[why] then
    util.log("treasury: %s -%.1f cr (%s%s) -> %s", force_name, paid, tostring(why),
      paid < cr and string.format(", %.1f unpaid at the credit line", cr - paid) or "", treasury.fmt(N.balance))
  end
  update_stage(force_name, N)
  return paid
end

--- Charge `cr` (imports, contracts, gifts). Refused (false) when it would take the balance below the credit line.
function treasury.charge(force_name, cr, why)
  local N = N_of(force_name)
  if not N or not cr or cr < 0 or cr ~= cr then return false end
  if N.balance - cr < -(N.credit or TB.credit.min) then
    util.log("treasury: %s charge of %.1f cr (%s) refused: balance %s, credit line %s", force_name, cr, tostring(why),
      treasury.fmt(N.balance), treasury.fmt(N.credit))
    return false
  end
  N.balance = N.balance - cr
  book(N, "expenses", why or "other", cr)
  util.log("treasury: %s -%.1f cr (%s) -> %s", force_name, cr, tostring(why), treasury.fmt(N.balance))
  update_stage(force_name, N)
  return true
end

--- Set the balance (tests and the console only).
function treasury.set_balance(force_name, cr, why)
  local N = N_of(force_name)
  if not N then return nil end
  N.balance = cr
  util.log("treasury: %s balance set to %s (%s)", force_name, treasury.fmt(cr), tostring(why or "script"))
  update_stage(force_name, N)
  return N.balance
end

--- Tax level "low" | "normal" | "high". Returns true when set.
function treasury.set_tax(force_name, level)
  local N = N_of(force_name)
  if not (N and TB.tax.levels[level]) then return false end
  if N.tax ~= level then
    util.log("treasury: %s tax %s -> %s", force_name, N.tax, level)
    N.tax = level
    -- M2 people: the tax level moves happiness (scripts/population.lua; absent in some test copies)
    local population = loaded("scripts.population")
    if population and population.set_mood then population.set_mood(force_name, "tax", TB.tax.mood[level]) end
    events.emit("rts_treasury_tax", {force = force_name, tax = level})
  end
  return true
end

function treasury.tax_of(force_name)
  local N = N_of(force_name)
  return N and N.tax or "normal"
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
function treasury.balance(force_name)
  local N = N_of(force_name)
  return N and N.balance or 0
end

function treasury.stage(force_name)
  local N = force_name and storage.treasury and storage.treasury[force_name]
  if not (N and is_nation_mode()) then return 0 end
  local m = storage.match
  if N.match_id ~= (m and m.match_id) then return 0 end
  return N.stage or 0
end

--- See the header.
function treasury.get(force_name)
  local N = N_of(force_name)
  if not N then
    return {balance = 0, income = zero(treasury.INCOME), expenses = zero(treasury.EXPENSES), stage = 0, tax = "normal",
            net = 0, credit = 0, rates = {}}
  end
  local income, expenses = window(N)
  return {balance = N.balance, income = income, expenses = expenses, stage = N.stage, tax = N.tax,
          net = sum(income) - sum(expenses), credit = N.credit, rates = N.rates, counts = N.counts, pop = N.pop,
          happiness = N.happiness, totals = N.totals, below_since = N.below_since}
end

--- Net cr per minute over the last minute (the Score victory and the AI).
function treasury.score(force_name)
  local N = N_of(force_name)
  if not N then return 0 end
  local income, expenses = window(N)
  return sum(income) - sum(expenses)
end

--- HUD strip: caption, font colour, tooltip ("₡ 1,240 (+35/min)"; red in deficit, yellow while the net is negative).
function treasury.strip(force_name)
  local N = N_of(force_name)
  if not N then return nil end
  local income, expenses = window(N)
  local net = sum(income) - sum(expenses)
  local color = N.balance < 0 and {r = 1, g = 0.35, b = 0.3} or (net < 0 and {r = 1, g = 0.85, b = 0.3})
    or {r = 1, g = 1, b = 1}
  local caption = {"rts-treasury.strip", treasury.fmt(N.balance), (net >= 0 and "+" or "-") .. treasury.fmt(math.abs(net))}
  local tooltip = {"", {"rts-treasury.strip-tooltip", treasury.fmt(income.tax), treasury.fmt(income.exports),
    treasury.fmt(expenses.buildings), treasury.fmt(expenses.army), treasury.fmt(expenses.transport),
    treasury.fmt(expenses.imports), treasury.fmt(expenses.interest), {"rts-treasury.tax-" .. N.tax}},
    "\n", {"rts-treasury.stage-" .. N.stage}}
  return caption, color, tooltip
end

---------------------------------------------------------------------------
-- Census: residents, happiness, upkeep counts (one pass every STEP ticks for every nation)
---------------------------------------------------------------------------
local function city_people(city)
  local pop_mod = loaded("scripts.population")
  if pop_mod and type(pop_mod.of) == "function" then
    local ok, r = pcall(pop_mod.of, city.id)
    if ok and type(r) == "table" and type(r.pop) == "number" then return r.pop, r.happiness end
  end
  local P = storage.population and storage.population[city.id]
  if type(P) == "table" and type(P.pop) == "number" then return P.pop, P.happiness end
  local fb = TB.fallback_pop
  local n = fb.tier[city.tier or 1] or fb.tier[1]
  if city.capital then n = math.max(n, fb.capital) end
  return n, nil
end

local function happiness_factor(h)
  local hb = TB.tax.happiness
  h = math.max(0, math.min(100, h))
  return hb.at0 + (hb.at100 - hb.at0) * h / 100
end

local function is_hard_ai(force_name)
  local C = storage.ai and storage.ai[force_name]
  return C ~= nil and C.difficulty == "hard"
end

local function census(forces)
  local counts = {}
  for _, f in ipairs(forces) do
    counts[f] = {age1 = 0, age2 = 0, paused = 0, locos = 0, rail_tiles = 0, supply = 0, pop = 0, happy_w = 0,
                 cities = 0}
  end
  local U = TB.upkeep
  local crafters = U.crafter_kinds
  for _, rec in pairs(storage.buildings or {}) do
    local c = counts[rec.force]
    if c then
      local e = rec.entity
      if e.valid then
        local kind = rec.kind
        if kind == "train" then
          if e.name == treasury.LOCO then c.locos = c.locos + 1 end
        elseif not U.skip_kinds[kind] and not U.skip_names[e.name] then
          local cost = AGE2[e.name] and U.age2 or U.age1
          local paused = e.disabled_by_script or (crafters[kind] and e.type == "assembling-machine" and not e.get_recipe())
          if paused then
            cost = cost * U.paused
            c.paused = c.paused + 1
          end
          if AGE2[e.name] then c.age2 = c.age2 + 1 else c.age1 = c.age1 + 1 end
          c.upkeep = (c.upkeep or 0) + cost
        end
      end
    end
  end
  for _, rec in pairs(storage.units or {}) do
    local c = counts[rec.force]
    if c and rec.kind ~= "hauler" and rec.kind ~= "commander" and rec.entity.valid then
      c.supply = c.supply + supply.cost(rec.entity.name)
    end
  end
  local R = storage.rails
  for _, line in pairs(R and R.lines or {}) do
    local c = counts[line.force]
    if c and (line.state == "open" or line.state == "cut" or line.state == "building") then
      c.rail_tiles = c.rail_tiles + (line.length or 0)
    end
  end
  for _, city in pairs(storage.cities or {}) do
    local c = counts[city.force]
    if c and city.entity and city.entity.valid then
      local pop, happy = city_people(city)
      c.pop = c.pop + pop
      c.happy_w = c.happy_w + pop * (happy or TB.tax.default_happiness)
      c.cities = c.cities + 1
    end
  end
  return counts
end

-- Apply one step (1/6 of a minute) of tax and upkeep to every nation, then interest when due.
local function step()
  if not treasury.active() then return end
  local m = storage.match
  if m.phase ~= "running" then return end
  local forces = {}
  for _, f in ipairs(match.forces()) do
    if N_of(f) then forces[#forces + 1] = f end
  end
  if #forces == 0 then return end
  local counts = census(forces)
  local share = treasury.STEP / treasury.MINUTE
  for _, f in ipairs(forces) do
    local N = N_of(f)
    local c = counts[f]
    local happy = c.pop > 0 and c.happy_w / c.pop or TB.tax.default_happiness
    N.pop, N.happiness, N.counts = c.pop, happy, c
    local tax = c.pop * TB.tax.per_resident * (TB.tax.levels[N.tax] or 1) * happiness_factor(happy)
    if is_hard_ai(f) then tax = tax * (1 + TB.tax.hard_bonus) end
    local army = math.max(0, c.supply - TB.army.free) * TB.army.per_supply
    local transport = c.locos * TB.transport.locomotive + c.rail_tiles / TB.transport.rail_tiles
    N.rates = {tax = tax, buildings = c.upkeep or 0, army = army, transport = transport}
    treasury.add(f, tax * share, "tax")
    treasury.pay(f, (c.upkeep or 0) * share, "buildings")
    treasury.pay(f, army * share, "army")
    treasury.pay(f, transport * share, "transport")
    if game.tick >= N.next_interest then
      N.next_interest = game.tick + TB.interest.period
      if N.balance < 0 then treasury.pay(f, -N.balance * TB.interest.rate, "interest") end
    end
    local income = window(N)
    local gross = (income.tax or 0) + (income.exports or 0)
    N.credit = math.max(TB.credit.min, TB.credit.minutes * gross)
    update_stage(f, N)
  end
end

events.on_nth_tick(treasury.STEP, step)

-- Stage timers (60 s / 180 s below zero) between two flow steps.
events.on_nth_tick(treasury.STAGE_PERIOD, function()
  local T = storage.treasury
  if not (T and next(T) and treasury.active()) then return end
  local m = storage.match
  for f, N in pairs(T) do
    if N.match_id == m.match_id and N.balance < 0 then update_stage(f, N) end
  end
end)

-- Per-minute QA line per nation.
function treasury.describe(force_name)
  local N = N_of(force_name)
  if not N then return string.format("%s: no treasury", tostring(force_name)) end
  local i, e = window(N)
  local c = N.counts or {}
  return string.format("%s: balance %s, net %+.0f/min (tax %.0f exports %.0f other %.0f | buildings %.0f army %.0f "
    .. "transport %.0f imports %.0f interest %.0f other %.0f), stage %d, tax %s, pop %d happiness %.0f, buildings %d+%d "
    .. "(paused %d), supply %d, locos %d, rail %d tiles, credit line %s", force_name, treasury.fmt(N.balance),
    sum(i) - sum(e), i.tax, i.exports, i.other, e.buildings, e.army, e.transport, e.imports, e.interest, e.other,
    N.stage, N.tax, N.pop or 0, N.happiness or 0, c.age1 or 0, c.age2 or 0, c.paused or 0, c.supply or 0, c.locos or 0,
    c.rail_tiles or 0, treasury.fmt(N.credit))
end

events.on_nth_tick(treasury.MINUTE, function(e)
  if not treasury.active() then return end
  local m = storage.match
  if not m.tick_started then return end
  local minute = math.floor((e.tick - m.tick_started) / treasury.MINUTE + 0.5)
  for _, f in ipairs(match.forces()) do
    if storage.treasury and storage.treasury[f] then
      util.log("treasury: minute %d %s", minute, treasury.describe(f))
    end
  end
end)

-- M2 people (scripts/labor.lua, scripts/population.lua; each absent in some test copies): unpaid wages take one
-- staffing step off every building of the force, unrest takes unrest_happiness; both clear with the stage.
treasury.on_stage(function(force_name, stage)
  local labor = loaded("scripts.labor")
  if labor and labor.set_penalty then labor.set_penalty(force_name, stage >= 2 and 1 or 0, "unpaid") end
  local population = loaded("scripts.population")
  if population and population.set_mood then
    population.set_mood(force_name, "debt", stage >= 3 and TB.unrest_happiness or nil)
  end
end)

---------------------------------------------------------------------------
-- Barracks: no kits while wages are unpaid (stage 2 and 3). Wraps the kit gate research.lua set (scripts/research.lua
-- loads earlier in control.lua); scripts/labor.lua may wrap it again for "no recruits".
---------------------------------------------------------------------------
local inner_gate = production.kit_gate
production.kit_gate = function(rec, kit, def)
  if treasury.stage(rec.force) >= 2 then
    local old = rec.research_block
    if not (old and old.reason == "unpaid") then
      util.log("treasury: barracks #%d (%s) holds a %s: unpaid wages (stage %d)", rec.entity.unit_number, rec.force,
        kit, treasury.stage(rec.force))
    end
    rec.research_block = {reason = "unpaid", unit = def.unit, kit = kit, tick = game.tick}
    return nil
  end
  if inner_gate then return inner_gate(rec, kit, def) end
  if rec.research_block and rec.research_block.reason == "unpaid" then rec.research_block = nil end
  return def
end
treasury.kit_gate = production.kit_gate

---------------------------------------------------------------------------
-- Console
---------------------------------------------------------------------------
commands.add_command("rts-treasury", "[force] [set <cr> | add <cr> | tax low|normal|high] - Nation treasury (QA)",
  function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    local words = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do words[#words + 1] = w end
    local f = (words[1] and game.forces[words[1]]) and table.remove(words, 1)
      or (player and player.force.name) or util.PLAYER_FORCE
    local verb, arg = words[1], words[2]
    if verb == "set" and tonumber(arg) then treasury.set_balance(f, tonumber(arg), "console")
    elseif verb == "add" and tonumber(arg) then treasury.add(f, tonumber(arg), "console")
    elseif verb == "tax" and arg then treasury.set_tax(f, arg) end
    local line = treasury.describe(f)
    util.log("treasury: %s", line)
    if player then player.print(line) end
  end)

return treasury
