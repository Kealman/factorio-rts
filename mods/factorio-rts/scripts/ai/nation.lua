-- Phase 5 M2 ai (docs/PHASE5-M2.md D9, §3 "ai/nation.lua / ai/governor.lua"): the nation strategist of an AI force.
-- Nation mode only; ai/commander.lua calls nation.step(C, surface) on every run, the strategist works every PERIOD
-- ticks (10 s), staggered per force. It coordinates the M2 modules' own AI parts instead of repeating them:
--
--   taxes       market.ai_taxes (low below happiness 40, high at war or while losing money below the deficit floor);
--               market.lua's own pass leaves taxes to the strategist (market.AI.taxes = false)
--   trade       sales at the ports with a price floor (normal / hard hold a good while its price is below
--               sell_floor x p0, easy sells at any price and dumps from lower thresholds: it trades at a loss), the
--               contracted goods kept back at the seller's port; market.lua keeps the capital's port route, the
--               "wanted" hauls and the purchases of shortfalls it cannot fill in 3 minutes (market.AI.sell = false)
--   contracts   for an ore the nation lacks (world.scarcity), a contract with the exporter it likes best (relation >= 0,
--               at peace, holding a port and the goods), proposed through diplomacy (the seller's AI answers)
--   war, peace  diplomacy.ai_step (the doctrine table) once a minute (diplomacy.AI_SELF_SCHEDULE = false); easy AIs
--               never declare war (diplomacy.lua)
--   garrison    when a war starts, part of the home guard enters the capital's garrison (hidden turrets); at peace it
--               sorties and rejoins the army
--   capture     army.capture_ok: a war with city goals, or Age II at peace with a supplied pool and no rival division
--               near home (city-state operations, ai/army.lua army.city_state_target picks the target)
--   found, age  unchanged: cities.ai_step / ai/towns.lua and ai/age_up.lua
--
-- Difficulty (§3): easy never declares war and trades at a loss; hard gets +20 % tax income from treasury.lua
-- (balance.nation.treasury.tax.hard_bonus) and, in Nation mode, none of Skirmish's hard cheats (ai/commander.lua).
--
-- State: C.strategist = {next, pass, wars = {[war_id] = true}, garrison = {city, n}, contract = {id, item, seller, at},
--   tried = {[seller .. item] = tick}, stats = {sold, held, contracts, garrisons, sorties}}.
-- Log lines "[rts] ai <force>: nation ...".
local util = require("scripts.util")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")
local army = require("scripts.ai.army")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local nation = {}

local NA = balance.nation.diplomacy.ai
nation.PERIOD = NA.period

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function is_nation()
  return deps.ages ~= nil and deps.ages.is_nation()
end

-- The strategist runs the doctrine table itself (once a minute per AI, from its own pass).
diplomacy.AI_SELF_SCHEDULE = false

local function S_of(C)
  local S = C.strategist
  if not S then
    local slot = 0
    for f in pairs(storage.ai or {}) do
      if f < C.force then slot = slot + 1 end
    end
    S = {next = game.tick + (slot * 151) % nation.PERIOD, pass = slot, wars = {}, tried = {},
         stats = {sold = 0, held = 0, contracts = 0, garrisons = 0, sorties = 0}}
    C.strategist = S
  end
  return S
end

local function capital_city(C)
  local nat = storage.nations and storage.nations[C.force]
  local cities = deps.cities
  return nat and cities and cities.get(nat.capital) or nil
end

---------------------------------------------------------------------------
-- Trade
---------------------------------------------------------------------------
-- Goods kept back at the force's ports for the deliveries it owes (contracts where it sells).
-- Goods bought by contract are not sold again (coal stays as the haulers' fuel, ore for the capital's "wanted" haul).
local function owed(C, market)
  local out, bought = {}, {}
  for _, c in ipairs(market.contracts(C.force)) do
    if c.seller == C.force and c.state == "active" then out[c.item] = (out[c.item] or 0) + c.n end
    if c.buyer == C.force and (c.state == "active" or game.tick - (c.created or 0) < NA.contract_keep) then
      bought[c.item] = true
    end
  end
  return out, bought
end

local function sell(C, S, market)
  local ports = market.ports(C.force)
  if #ports == 0 then return end
  local easy = C.difficulty == "easy"
  local floor = easy and 0 or NA.sell_floor
  local keep, bought = owed(C, market)
  local MA = market.state and market.state() and market.state().ai and market.state().ai[C.force]
  local imports = MA and MA.imports or {}
  for _, un in ipairs(ports) do
    local contents = market.port_contents(un)
    local items = {}
    for item, n in pairs(contents) do
      if market.p0(item) and not imports[item] and not bought[item] and n > 0 then items[#items + 1] = item end
    end
    table.sort(items, function(a, b)
      local pa, pb = market.p0(a) or 0, market.p0(b) or 0
      if pa ~= pb then return pa > pb end
      return a < b
    end)
    for _, item in ipairs(items) do
      local n = contents[item] - (keep[item] or 0) - (item == "coal" and NA.coal_reserve or 0)
      if keep[item] then keep[item] = math.max(0, keep[item] - contents[item]) end
      if n > 0 then
        local p, p0 = market.price(item), market.p0(item)
        if p0 and p < floor * p0 then
          S.stats.held = S.stats.held + 1
        else
          local cr, why = market.sell(C.force, un, item, n)
          if cr > 0 then S.stats.sold = S.stats.sold + cr end
          if cr <= 0 and why == "cap" then return end
        end
      end
    end
  end
end

-- Easy: the capital ships its goods to the port from a share of the surplus thresholds (it dumps).
local function easy_dump(C, S, market)
  if C.difficulty ~= "easy" or S.dumping then return end
  local MA = market.state and market.state() and market.state().ai and market.state().ai[C.force]
  local L = deps.logistics
  local home = capital_city(C)
  if not (MA and MA.cc_exports and next(MA.cc_exports) and L and home) then return end
  for item, thr in pairs(MA.cc_exports) do
    L.set_policy(home.center, "export_above", item, math.floor(thr * NA.easy_dump))
  end
  S.dumping = true
  util.log("ai %s: nation: easy: the capital ships from %d %% of the surplus thresholds", C.force,
    math.floor(NA.easy_dump * 100))
end

-- A contract for an ore the nation lacks, with the exporter it likes best.
local function contracts(C, S, market)
  local world = mod("world")
  if not (world and world.scarcity) or #market.ports(C.force) == 0 then return end
  local cur = S.contract and S.contract.id
  if cur then
    local live = false
    for _, c in ipairs(market.contracts(C.force)) do
      if c.id == cur and c.state == "active" then
        live = true
        -- a seller that missed a delivery will miss the next ones too (every miss costs relation): the buyer ends it
        if (c.missed or 0) >= 1 and market.cancel_contract then
          market.cancel_contract(c.id, "missed delivery")
          live = false
          util.log("ai %s: nation: contract #%d cancelled after a missed delivery", C.force, c.id)
        end
      end
    end
    if live then return end
    S.contract = nil
  end
  -- a proposal of ours still waits for its answer
  for _, P in pairs(storage.diplomacy and storage.diplomacy.proposals or {}) do
    if P.kind == "contract" and P.from == C.force and P.status == "pending" then return end
  end
  -- the contract our last accepted proposal created
  for _, c in ipairs(market.contracts(C.force)) do
    if c.buyer == C.force and c.state == "active" then
      S.contract = {id = c.id, item = c.item, seller = c.seller, at = game.tick}
      return
    end
  end
  local m = storage.match
  if game.tick < (S.next_contract or 0) or game.tick - m.tick_started < NA.contract_from then return end
  S.next_contract = game.tick + NA.contract_gap
  local sc = world.scarcity()
  local mine = sc[C.force]
  if not (mine and mine.lacks) then return end
  local best
  for _, item in ipairs(mine.lacks) do
    if market.p0(item) then
      for _, y in ipairs(diplomacy.nations()) do
        local theirs = sc[y]
        local lacks = false
        for _, l in ipairs(theirs and theirs.lacks or {}) do if l == item then lacks = true end end
        local port = market.ports(y)[1]
        local r = diplomacy.relation(C.force, y)
        if y ~= C.force and not lacks and port and diplomacy.state(C.force, y) == "peace" and r >= NA.contract_min_r
           and game.tick - (S.tried[y .. "/" .. item] or -NA.contract_retry) >= NA.contract_retry then
          -- only a seller that holds the goods at its port or mines them in a town (a delivery it cannot make costs
          -- both sides relation)
          -- (only goods already at the seller's port: a town that mines the ore rarely ships it there in time, and
          -- 34 of 50 deliveries were missed in the 60-minute runs)
          local stock = (market.port_contents(port)[item] or 0)
          if stock >= 2 * NA.contract_n then
            local score = r + (stock >= NA.contract_n and 20 or 0)
            if not best or score > best.score then best = {y = y, item = item, score = score, stock = stock} end
          end
        end
      end
    end
  end
  if not best then return end
  S.tried[best.y .. "/" .. best.item] = game.tick
  local price = math.floor(market.price(best.item) * NA.contract_price * 1000 + 0.5) / 1000
  local id, why = diplomacy.propose(C.force, best.y, "contract", {item = best.item, n_per = NA.contract_n,
    deliveries = NA.contract_deliveries, interval = NA.contract_interval, price = price, seller = best.y,
    buyer = C.force})
  util.log("ai %s: nation: contract for %d x %d %s from %s at %.3f cr proposed (%s; relation %.0f, their port holds %d)",
    C.force, NA.contract_deliveries, NA.contract_n, best.item, best.y, price, id and ("#" .. id) or tostring(why),
    diplomacy.relation(C.force, best.y), best.stock)
  if id then S.stats.contracts = S.stats.contracts + 1 end
end

---------------------------------------------------------------------------
-- War: the capital's garrison
---------------------------------------------------------------------------
local GARRISON_KINDS = {walker = true, heavy = true, drone = true, raider = true, car = true}

local function garrison_enter(C, S, capital)
  local garrison = mod("garrison")
  if not (garrison and garrison.enter_units) then return end
  local a = C.army
  if not a then return end
  local home = capital.position
  local list = {}
  for un, rec in units.for_force(C.force) do
    if not a.member[un] and GARRISON_KINDS[rec.kind] and rec.order == units.IDLE and rec.issuer ~= "market"
       and not divisions.of_unit(un) then
      list[#list + 1] = {e = rec.entity, d = util.distance(rec.entity.position, home)}
    end
  end
  table.sort(list, function(x, y)
    if x.d ~= y.d then return x.d < y.d end
    return x.e.unit_number < y.e.unit_number
  end)
  local n = math.min(NA.garrison_max, math.max(NA.garrison_min, math.ceil(#list * NA.garrison_share)))
  if #list < NA.garrison_min then return end
  local pick = {}
  for i = 1, math.min(n, #list) do pick[#pick + 1] = list[i].e end
  local got = garrison.enter_units(pick, capital.id)
  if got > 0 then
    S.garrison = {city = capital.id, n = got, tick = game.tick}
    S.stats.garrisons = S.stats.garrisons + 1
    util.log("ai %s: nation: war: %d units garrison the capital (city %d)", C.force, got, capital.id)
  end
end

local function garrison_leave(C, S)
  local garrison = mod("garrison")
  local G = S.garrison
  S.garrison = nil
  if not (garrison and G) then return end
  local id = garrison.sortie(G.city, "peace")
  if id then
    divisions.disband(id, "AI garrison back in the army")
    S.stats.sorties = S.stats.sorties + 1
    util.log("ai %s: nation: peace: the capital's garrison (city %d) rejoins the army", C.force, G.city)
  end
end

local function war_watch(C, S)
  local wars = mod("wars")
  if not (wars and wars.active) then return end
  local active = wars.active(C.force)
  local fresh = false
  local now = {}
  for _, id in ipairs(active) do
    now[id] = true
    if not S.wars[id] then
      fresh = true
      local W = wars.get(id)
      util.log("ai %s: nation: war #%d with %s (%s) starts", C.force, id, W and (W.a == C.force and W.b or W.a) or "?",
        W and W.a == C.force and "declared" or "declared on us")
    end
  end
  S.wars = now
  local capital = capital_city(C)
  if fresh and capital and not S.garrison then garrison_enter(C, S, capital) end
  if #active == 0 and S.garrison then garrison_leave(C, S) end
end

---------------------------------------------------------------------------
-- Capture operations (ai/army.lua asks army.capture_ok)
---------------------------------------------------------------------------
--- True when commander C may start a capture operation now: a war with goal cities, or (Age II, at peace) a supplied
--- army and no rival division within capture_safe tiles of the capital.
function nation.capture_ok(C)
  if not is_nation() then return false end
  local wars = mod("wars")
  if wars and wars.targets and #wars.targets(C.force) > 0 then return true end
  if C.difficulty == "easy" then return false end
  local ages = deps.ages
  if not (ages and ages.of(C.force) >= 2) then return false end
  local m = storage.match
  if not (m and m.tick_started) or game.tick - m.tick_started < NA.city_state_from then return false end
  if diplomacy.at_war(C.force) then return false end
  local capital = capital_city(C)
  if not capital then return false end
  for _, f in ipairs(diplomacy.nations()) do
    if f ~= C.force then
      for _, D in ipairs(divisions.for_force(f)) do
        local recs = divisions.members(D.id)
        local rec = recs[1] and units.get(recs[1])
        if rec and util.distance(rec.entity.position, capital.position) <= NA.capture_safe then return false end
      end
    end
  end
  return true
end
army.capture_ok = function(C) return nation.capture_ok(C) end

---------------------------------------------------------------------------
-- Opportunity wars: a rival's weakly held town within reach (Age II, at peace with everyone, no truce, an army at home)
---------------------------------------------------------------------------
-- Defence points of a city: units within the war AI's defenders_radius, garrison points, turret_points per own gun
-- turret within opportunity_turret_radius of its centre.
local function town_defence_points(surface, c)
  local WAI = balance.nation.war.ai
  local n = 0
  for _, e in ipairs(surface.find_entities_filtered({position = c.position, radius = WAI.defenders_radius,
                                                     force = c.force, type = {"unit", "spider-unit"}})) do
    if e.unit_number and storage.units and storage.units[e.unit_number] then n = n + 1 end
  end
  local garrison = mod("garrison")
  local g = garrison and garrison.of and garrison.of(c.id)
  n = n + (g and g.points or 0)
  n = n + WAI.turret_points * surface.count_entities_filtered({position = c.position,
    radius = NA.opportunity_turret_radius, force = c.force, type = {"ammo-turret", "electric-turret"}})
  return n
end

local function truce_with(x, y)
  local D = storage.diplomacy
  local t = D and D.truce and D.truce[x] and D.truce[x][y]
  return t ~= nil and game.tick < t
end

local function opportunity(C, S)
  local O = NA.opportunity and NA.opportunity[C.doctrine]
  if not O or C.difficulty == "easy" or #diplomacy.nations() < (NA.opportunity_nations or 3) then return end
  local m = storage.match
  if game.tick - m.tick_started < NA.opportunity_from or game.tick < (S.next_opportunity or 0) then return end
  S.next_opportunity = game.tick + NA.opportunity_period
  if diplomacy.at_war(C.force) or not (deps.ages and deps.ages.of(C.force) >= 2) then return end
  if S.last_opportunity and game.tick - S.last_opportunity < NA.opportunity_gap then return end
  if (C.army and C.army.pool_size or 0) < O.pool then return end
  local capital = capital_city(C)
  if not capital then return end
  local surface = util.surface()
  local best
  for _, y in ipairs(diplomacy.nations()) do
    if y ~= C.force and diplomacy.state(C.force, y) == "peace" and not truce_with(C.force, y)
       and diplomacy.relation(C.force, y) < O.r and diplomacy.ratio(C.force, y) > O.ratio then
      for _, c in ipairs(deps.cities.for_force(y)) do
        if not c.capital and c.entity and c.entity.valid then
          local d = util.distance(capital.position, c.position)
          if d <= NA.opportunity_reach then
            local def = town_defence_points(surface, c)
            if def <= O.defenders and (not best or d < best.d) then best = {y = y, c = c, d = d, def = def} end
          end
        end
      end
    end
  end
  if not best then return end
  S.last_opportunity = game.tick
  util.log("ai %s: nation: opportunity: %s's town %d at %s holds %d defence points (%.0f tiles; relation %.0f, ratio "
    .. "%.2f): war", C.force, best.y, best.c.id, util.pos_str(best.c.position), best.def, best.d,
    diplomacy.relation(C.force, best.y), diplomacy.ratio(C.force, best.y))
  diplomacy.propose(C.force, best.y, "war", {goals = {kind = "conquest", cities = {best.c.id}}})
end

---------------------------------------------------------------------------
-- The pass
---------------------------------------------------------------------------
function nation.step(C, surface)
  if not is_nation() then return end
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local S = S_of(C)
  if game.tick < S.next then return end
  S.next = game.tick + nation.PERIOD
  S.pass = S.pass + 1
  local market = deps.market
  if market then
    market.AI.taxes, market.AI.sell = false, false -- the strategist runs these parts (see the header)
    market.ai_taxes(C)
    sell(C, S, market)
    easy_dump(C, S, market)
    contracts(C, S, market)
  end
  war_watch(C, S)
  if S.pass % NA.diplomacy_every == 0 then
    diplomacy.ai_step(C.force)
    opportunity(C, S)
  end
end

--- "nation: tax normal, 2 wars, garrison 6, contract #3 coal from rts-ai-2, sold 1,234 cr (held 3)".
function nation.describe(C)
  local S = C.strategist
  if not S then return "nation: -" end
  local treasury = mod("treasury")
  local n = 0
  for _ in pairs(S.wars) do n = n + 1 end
  return string.format("nation: tax %s, balance %.0f, wars %d, garrison %s, contract %s, sold %.0f cr (held %d), "
    .. "contracts proposed %d", treasury and treasury.tax_of(C.force) or "-",
    treasury and treasury.balance(C.force) or 0, n, S.garrison and tostring(S.garrison.n) or "-",
    S.contract and string.format("#%d %s from %s", S.contract.id, S.contract.item, S.contract.seller) or "-",
    S.stats.sold, S.stats.held, S.stats.contracts)
end

deps.nation = nation
return nation
