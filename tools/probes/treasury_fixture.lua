-- Phase 5 M2 treasury and market fixture (test copy only; docs/qa/phase5-treasury-notes.md):
--   KEEP_TREE=<tree> EXTRA_LUA=<this file> STOP_ON='RTS_TREASURY_DONE' SPEED=4 \
--     tools/autotest-run.sh p5m2t-fixture '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048,
--     enemy_brain = "ai"}' 1200
-- Two seconds into a Nation match both AI commanders stop and the probe drives the market by script. Log lines
-- "[rts] treasury fixture <check>: PASS|FAIL ...", then "[rts] treasury fixture summary <passed>/<total>" and the stop
-- marker RTS_TREASURY_DONE. Checks:
--   ports       a trade post next to each capital and one neutral: composite (post, 2 stockpiles, network), loot,
--               indestructible, rts-neutral force, kind hub, no supply
--   capture     a walker within 4 tiles of the neutral port takes it in 10-11 s; the composite and its building records
--               change force
--   price       selling 1,000 steel pays the curve integral (checked numerically) and leaves p = p0 (S0 / S) ^ 0.6
--   drift       at the next two minute ticks S moves 5 % back towards S0 (and the price with it)
--   stages      balance below 0: stage 1 at once (imports refused "deficit"), 2 after 60 s (barracks refuse "unpaid"),
--               3 after 180 s, 0 at once on recovery; the on_stage hook saw 1, 2, 3, 0
--   import      100 plastic bought: charged at once at the quote, at the port after 30 s (not at 29 s), nowhere else
--   cap         sales stop at the commerce cap ("cap"), the next sale and a purchase are refused, a minute later a sale
--               goes through again
--   contract    2 deliveries of 50 steel: each settles at its due time (seller port -50, buyer -value, seller +value),
--               the goods reach the buyer's port 30 s later; a contract whose seller has no goods is "late" at its due
--               time and "missed" 2 minutes later (hook), then "failed"
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local logistics = require("scripts.logistics")
local supply = require("scripts.supply")
local treasury = require("scripts.treasury")
local market = require("scripts.market")

local F, E = util.PLAYER_FORCE, util.ENEMY_FORCE
local SEC = 60

local function P()
  storage.tf = storage.tf or {pass = 0, fail = 0, step = "wait", stages = {}, cev = {}}
  return storage.tf
end

local function check(name, ok, fmt, ...)
  local s = P()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("treasury fixture %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

treasury.on_stage(function(force_name, stage, old)
  local s = P()
  if force_name == F then s.stages[#s.stages + 1] = {tick = game.tick, stage = stage, old = old} end
end)

market.on_contract_event(function(ev)
  local s = P()
  s.cev[#s.cev + 1] = {tick = game.tick, kind = ev.kind, id = ev.id, fault = ev.fault, value = ev.value}
end)

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) * math.max(1, math.abs(b)) end

local function clear(surface, center, r)
  for _, e in pairs(surface.find_entities_filtered({position = center, radius = r,
                                                    type = {"tree", "simple-entity", "cliff", "fish"}})) do
    e.destroy()
  end
end

local function make_port(surface, home, dx, dy)
  local want = {x = home.x + dx, y = home.y + dy}
  clear(surface, want, 30)
  local at = surface.find_non_colliding_position(market.POST, want, 40, 1, true) or want
  clear(surface, at, 10)
  return market.place_port(surface, at)
end

local function count_at(un, item) return market.port_contents(un)[item] or 0 end

local function force_total(force_name, item)
  local n = 0
  for _, entry in ipairs(logistics.networks(force_name)) do n = n + (entry.network.get_item_count(item) or 0) end
  return n
end

local function stock_into(un, item, n)
  local p = market.port(un)
  local put = 0
  local pol = logistics.policy(un)
  for _, st in ipairs(pol.parts.stockpiles) do
    if st.valid and put < n then put = put + st.insert({name = item, count = n - put}) end
  end
  return put
end

local function events_of(s, id, kind)
  local out = {}
  for _, ev in ipairs(s.cev) do
    if ev.id == id and (not kind or ev.kind == kind) then out[#out + 1] = ev end
  end
  return out
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local steps = {}

function steps.setup(s, tick)
  ai.stop_force(F)
  ai.stop_force(E)
  local m = storage.match
  local surface = game.surfaces[m.surface]
  local hf, he = buildings.main_cc(F), buildings.main_cc(E)
  -- a barracks of our own for the "unpaid" gate (the commander stopped before it built one)
  local bpos = surface.find_non_colliding_position("rts-barracks", {x = hf.position.x - 20, y = hf.position.y + 20}, 30,
    1, true)
  local b = bpos and surface.create_entity({name = "rts-barracks", position = bpos, force = F, raise_built = true})
  if b then buildings.register(b) end
  local pa = make_port(surface, hf.position, 0, -75)
  local pb = make_port(surface, he.position, 0, -75)
  local pc = make_port(surface, hf.position, 75, 0)
  s.pa, s.pb, s.pc = pa and pa.un, pb and pb.un, pc and pc.un
  local ok = pa and pb and pc
  local parts = {}
  for _, p in ipairs({pa, pb, pc}) do
    if p then
      local pol = logistics.policy(p.un)
      local rec = buildings.get(p.un)
      local net = logistics.hub_network(p.un)
      local stockpiles = pol and pol.parts and #pol.parts.stockpiles or 0
      ok = ok and rec ~= nil and rec.kind == "hub" and stockpiles == 2 and net ~= nil and not p.entity.destructible
        and p.entity.force.name == market.NEUTRAL and count_at(p.un, "steel-plate") == 300
      parts[#parts + 1] = string.format("#%d at %s kind %s stockpiles %d network %s force %s destructible %s steel %d "
        .. "circuits %d coal %d", p.un, util.pos_str(p.position), rec and rec.kind or "-", stockpiles,
        tostring(net ~= nil), p.entity.force.name, tostring(p.entity.destructible), count_at(p.un, "steel-plate"),
        count_at(p.un, "electronic-circuit"), count_at(p.un, "coal"))
    end
  end
  local cap0 = supply.cap(F)
  market.set_owner(s.pa, F)
  market.set_owner(s.pb, E)
  local cap1 = supply.cap(F)
  check("ports", ok and cap0 == cap1 and #market.ports(F) == 1 and #market.ports(E) == 1,
    "%s; supply cap %d -> %d with a port; ports F [%s] E [%s]", table.concat(parts, "; "), cap0, cap1,
    table.concat(market.ports(F), " "), table.concat(market.ports(E), " "))
  -- capture: a walker next to the neutral port
  local pcr = market.port(s.pc)
  local w = units.spawn("rts-walker", {x = pcr.position.x, y = pcr.position.y + 5}, F, nil, surface)
  s.walker = w and w.unit_number
  s.t = tick
  s.step = "capture"
end

function steps.capture(s, tick)
  local p = market.port(s.pc)
  if p.owner == F then
    local dt = (tick - s.t) / SEC
    local pol = logistics.policy(s.pc)
    local flipped = p.entity.force.name == F and buildings.get(s.pc).force == F and pol.force == F
    for _, st in ipairs(pol.parts.stockpiles) do
      flipped = flipped and st.force.name == F and buildings.get(st.unit_number).force == F and not st.destructible
    end
    check("capture", dt >= 10 and dt <= 11.2 and flipped, "taken in %.2f s (10-11 s), composite and records %s", dt,
      flipped and "flipped" or "NOT flipped")
    local wr = s.walker and units.get(s.walker)
    if wr then wr.entity.destroy() end
    s.step = "price"
  elseif tick - s.t > 30 * SEC then
    check("capture", false, "not taken in 30 s (capturing %s, progress %d)", tostring(p.capturing), p.progress or 0)
    s.step = "price"
  end
end

function steps.price(s, tick)
  market.set_cap_override(F, 1e9)
  stock_into(s.pa, "steel-plate", 1000)
  local item = "steel-plate"
  local p0 = market.p0(item)
  local S0, Sb = select(2, market.stock(item)), market.stock(item)
  local quote = market.quote(item, 1000, "sell")
  -- numeric integral of the clamped price (midpoint rule, 2000 steps) x 0.9
  local num = 0
  for i = 0, 1999 do num = num + market.price_at(p0, S0, Sb + (i + 0.5) * 0.5) * 0.5 end
  num = num * 0.9
  local bal = treasury.balance(F)
  local cr = market.sell(F, s.pa, item, 1000)
  local Sa = market.stock(item)
  local pa = market.price(item)
  local expect = p0 * (S0 / Sa) ^ 0.6
  local paid = treasury.balance(F) - bal
  check("price", near(cr, quote, 1e-9) and near(cr, num, 1e-4) and near(paid, cr, 1e-9) and Sa == Sb + 1000
    and near(pa, expect, 1e-9), "sold 1000 steel for %.3f cr (quote %.3f, numeric %.3f), balance +%.3f; S %d -> %d "
    .. "(S0 %d); price %.4f -> %.4f = p0 (S0/S)^0.6 = %.4f; p0 %.2f", cr, quote, num, paid, Sb, Sa, S0,
    market.price_at(p0, S0, Sb), pa, expect, p0)
  market.set_cap_override(F, nil)
  s.drift = {S = Sa, n = 0}
  s.step = "drift"
end

function steps.drift(s, tick)
  local item = "steel-plate"
  local Sn, S0 = market.stock(item)
  if Sn == s.drift.S then return end
  local want = S0 + 0.95 * (s.drift.S - S0)
  s.drift.n = s.drift.n + 1
  local p = market.price(item)
  check("drift_" .. s.drift.n, near(Sn, want, 1e-9), "minute tick %d: S %.1f -> %.1f (expected %.1f: 5 %% of the %.1f "
    .. "gap), price %.4f", tick, s.drift.S, Sn, want, s.drift.S - S0, p)
  s.drift.S = Sn
  if s.drift.n >= 2 then
    s.step = "stages"
    s.stages = {}
    treasury.set_balance(F, -200, "fixture")
    s.t = tick
    local ok, why = market.buy(F, s.pa, "iron-plate", 10)
    s.buy_refused = (not ok) and why
  end
end

function steps.stages(s, tick)
  local age = tick - s.t
  if not s.gate_checked and treasury.stage(F) >= 2 then
    s.gate_checked = true
    local rec
    for _, r in buildings.for_force(F, "barracks") do rec = r break end
    local def = production.KITS["rts-walker-kit"]
    local spawn = rec and production.kit_gate(rec, "rts-walker-kit", def)
    s.gate = rec and (spawn == nil and rec.research_block and rec.research_block.reason) or "no barracks"
  end
  if age >= 185 * SEC and not s.recovered then
    s.recovered = tick
    treasury.set_balance(F, 5000, "fixture")
  end
  if s.recovered and tick - s.recovered >= SEC then
    local seq, at = {}, {}
    for _, st in ipairs(s.stages) do
      seq[#seq + 1] = tostring(st.stage)
      at[#at + 1] = string.format("%d@%.2fs", st.stage, (st.tick - s.t) / SEC)
    end
    local function t_of(n)
      for _, st in ipairs(s.stages) do if st.stage == n then return (st.tick - s.t) / SEC end end
      return -1
    end
    local t1, t2, t3, t0 = t_of(1), t_of(2), t_of(3), t_of(0)
    check("stages", table.concat(seq, ",") == "1,2,3,0" and t1 == 0 and t2 >= 60 and t2 <= 61 and t3 >= 180
      and t3 <= 181 and near(t0, (s.recovered - s.t) / SEC, 1e-9), "hook sequence [%s] (expected 1 at 0 s, 2 at "
      .. "60 s, 3 at 180 s, 0 on recovery at %.2f s)", table.concat(at, " "), (s.recovered - s.t) / SEC)
    check("stage_effects", s.buy_refused == "deficit" and s.gate == "unpaid" and treasury.stage(F) == 0,
      "stage 1 purchase refused: %s; stage 2 barracks: %s; stage now %d", tostring(s.buy_refused), tostring(s.gate),
      treasury.stage(F))
    -- the import
    local item = "plastic-bar"
    s.imp = {item = item, before_port = count_at(s.pa, item), before_total = force_total(F, item),
             bal = treasury.balance(F), quote = market.quote(item, 100, "buy")}
    local ok, cr = market.buy(F, s.pa, item, 100)
    s.imp.ok, s.imp.cr, s.imp.paid = ok, cr, s.imp.bal - treasury.balance(F)
    s.t = tick
    s.step = "import"
  end
end

function steps.import(s, tick)
  local age = tick - s.t
  local I = s.imp
  if age >= 29 * SEC and not I.at29 then
    I.at29 = {port = count_at(s.pa, I.item), total = force_total(F, I.item)}
  end
  if age >= 31 * SEC then
    local port, total = count_at(s.pa, I.item), force_total(F, I.item)
    check("import", I.ok and near(I.cr, I.quote, 1e-9) and near(I.paid, I.cr, 1e-9) and I.at29.port == I.before_port
      and port == I.before_port + 100 and total == I.before_total + 100 and #market.pending(F) == 0,
      "bought 100 %s for %.2f cr (quote %.2f, charged %.2f at once); at the port: %d before, %d at 29 s, %d at 31 s; "
      .. "all networks of the force: %d before, %d at 31 s", I.item, I.cr or -1, I.quote or -1, I.paid,
      I.before_port, I.at29.port, port, I.before_total, total)
    s.t = tick
    s.step = "cap_wait"
  end
end

function steps.cap_wait(s, tick)
  if tick - s.t < 61 * SEC then return end
  stock_into(s.pa, "steel-plate", 2000)
  local cap = market.cap(F)
  local sold, n, last = 0, 0, nil
  while n < 100 do
    n = n + 1
    local cr, why = market.sell(F, s.pa, "steel-plate", 50)
    if cr <= 0 then last = why break end
    sold = sold + cr
  end
  local used = market.cap_used(F)
  local ok_b, why_b = market.buy(F, s.pa, "steel-plate", 10) -- one steel costs more than the room left
  s.cap = {cap = cap, sold = sold, used = used, last = last, buy = why_b, n = n}
  check("cap_blocks", last == "cap" and used <= cap + 1e-6 and used >= cap - 4 and not ok_b and why_b == "cap",
    "cap %.0f cr/min (2 ports); %d sales took %.1f cr (used %.1f), the next sale: %s, a purchase: %s", cap, n - 1,
    sold, used, tostring(last), tostring(why_b))
  s.t = tick
  s.step = "cap_free"
end

function steps.cap_free(s, tick)
  if tick - s.t < 61 * SEC then return end
  local cr, why = market.sell(F, s.pa, "steel-plate", 50)
  check("cap_frees", cr > 0, "61 s later a sale of 50 steel pays %.1f cr (%s), used %.1f / %.0f", cr, tostring(why or "ok"),
    market.cap_used(F), market.cap(F))
  -- contract 1: 2 x 50 steel, every 30 s, at 2.5
  stock_into(s.pa, "steel-plate", 200)
  s.c1 = {id = market.contract(F, E, "steel-plate", 50, 2, 30, 2.5), d = {}}
  -- contract 2: the seller (E) has no engines
  s.c2 = market.contract(E, F, "engine-unit", 10, 1, 30, 10)
  s.t = tick
  s.step = "contract"
end

function steps.contract(s, tick)
  local c1 = s.c1
  local evs = events_of(s, c1.id, "delivered")
  if #evs > #c1.d then
    local k = #c1.d + 1
    c1.d[k] = {tick = tick, due_age = (evs[k].tick - s.t) / SEC, pa = count_at(s.pa, "steel-plate"),
               pb = count_at(s.pb, "steel-plate"), fb = treasury.balance(F), eb = treasury.balance(E),
               value = evs[k].value}
  end
  for k, d in ipairs(c1.d) do
    if not d.arrived and tick - d.tick >= 31 * SEC then
      d.arrived = count_at(s.pb, "steel-plate")
    end
  end
  local miss = events_of(s, s.c2, "missed")
  local done1 = #c1.d == 2 and c1.d[2].arrived
  if done1 and #miss > 0 and #events_of(s, s.c2, "completed") > 0 then
    local d1, d2 = c1.d[1], c1.d[2]
    check("contract_settles", near(d1.due_age, 30, 0.04) and near(d2.due_age, 60, 0.03) and d1.value == 125
      and d2.value == 125 and d1.arrived >= d1.pb + 50 and d2.arrived >= d2.pb + 50
      and #events_of(s, c1.id, "completed") == 1, "deliveries at %.1f s and %.1f s (due 30 / 60), value %s / %s cr; "
      .. "buyer port steel %d -> %d and %d -> %d 31 s after each; completed events %d", d1.due_age, d2.due_age,
      tostring(d1.value), tostring(d2.value), d1.pb, d1.arrived, d2.pb, d2.arrived, #events_of(s, c1.id, "completed"))
    local late = events_of(s, s.c2, "late")
    local c2 = market.contracts(E)
    local state
    for _, c in ipairs(c2) do if c.id == s.c2 then state = c.state end end
    local t_late = late[1] and (late[1].tick - s.t) / SEC or -1
    local t_miss = (miss[1].tick - s.t) / SEC
    check("contract_missed", #late == 1 and late[1].fault == "seller" and miss[1].fault == "seller"
      and t_late >= 30 and t_late <= 31.1 and t_miss >= 150 and t_miss <= 151.1 and state == "failed",
      "late at %.1f s (due 30 s), missed at %.1f s (due + 120 s), fault %s, contract %s", t_late, t_miss,
      tostring(miss[1].fault), tostring(state))
    s.step = "done"
  elseif tick - s.t > 300 * SEC then
    check("contract_settles", false, "timeout: %d deliveries, %d missed events", #c1.d, #miss)
    s.step = "done"
  end
end

function steps.done(s)
  util.log("treasury fixture summary %d/%d", s.pass, s.pass + s.fail)
  log("RTS_TREASURY_DONE")
  s.step = "end"
end

events.on_nth_tick(10, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = P()
  if s.step == "wait" then
    if e.tick - m.tick_started < 120 then return end
    s.step = "setup"
  end
  local fn = steps[s.step]
  if fn then fn(s, e.tick) end
end)
