-- Phase 5 M3 age3: money sinks and city-state trade (docs/PHASE5-M3.md D10, §3 "age3.lua / rare.lua / sinks.lua";
-- open issues docs/qa/phase5-m2-integration-notes.md §6 item 6 "money is not yet tight"; notes
-- docs/qa/phase5-age3-notes.md). Nation mode only.
--
--   sinks.rush(force, what) -> ok, reason      what = "project" (the running national project: the Railway Charter in
--                                              Age I, the Space Program after) | a technology name (the current
--                                              research). Reasons: "mode", "no-project", "not-researching", "deficit",
--                                              "funds"
--   sinks.cancel_rush(force, why); sinks.rush_state(force) -> {kind, what, since, spent, per_minute} | nil
--   sinks.rush_target(force, what) -> {kind, what, project?} | nil   what a rush would act on now
--   sinks.hire_garrison(force, city_id, points) -> ok, reason   ("mode" | "city" | "max" | "funds")
--   sinks.mercenaries(force, port_un) -> division_id | nil, reason   ("mode" | "port" | "cooldown" | "supply" | "funds")
--   market.trade_with_city_state(force, city_id, item, count, buy) -> ok, reason | cr
--                                              (installed by this module; "mode" | "city" | "relation" | "item" |
--                                              "stock" | "cap" | "deficit" | "funds" | "no-city")
--   sinks.city_states(force) -> {{city_id, name, relation, markup, goods = {{item, stock, price}}}}
--
-- Rush (balance.nation.sinks.rush): a rushed project pulls `speed` x its goods per second and counts down `speed` x as
-- fast (ages.rush_factor, age3.rush_factor); a rushed research gets laboratory_speed_modifier + (speed - 1) as a delta.
-- Every period ticks the nation pays project_cr per missing item and second (countdown_cr per second while it counts
-- down) or research_cr per missing research unit and second. The rush ends when the project's stage (the Charter, one
-- stage of the Space Program) or the research is done, when another research takes over, or when the balance cannot
-- pay the next charge (no rush into debt).
--
-- Hire garrison: cr_per_point crowns per garrison point at an own city (garrison.add_hired: one hidden turret per 4
-- points together with the units' points; hired points need no supply); they decay by decay_per_min every minute; at
-- most max_points per city. The city panel's Hire button buys `step` points.
--
-- Mercenaries: at an own trade port, `cost` crowns buy a small division by the port's region kind (templates); one per
-- `cooldown` seconds per nation; the units need free supply like any unit and pay army upkeep; no recruits are drafted.
--
-- City-state trade: a city-state's City Center is a port for its region's goods (world.CS.stock by anchor: what lies in
-- its network). Buying costs markup x the market price per unit (markup_best at relation 100), the goods leave the
-- city-state's network now and arrive after `delay` in the network of the buyer's city nearest to it. Selling takes the
-- goods from that city's network and pays sell_factor x the market price. Every relation_cr crowns raise the city-state's
-- relation with the nation by 1 (-100..100); below min_relation it refuses; it trades at most cap_per_min crowns a
-- minute and restocks restock_share of its starting goods every restock_period. Capturing a city-state while at peace
-- with every nation costs capture_penalty relation with every other nation (and capture_relation with the remaining
-- city-states). The market panel lists the city-states next to the nation's ports.
--
-- State: storage.nations[force].sinks = {rush = {kind, what, since, spent, per_minute, last}, merc_ready, mercs, hired}
-- and storage.sinks = {applied = {[force] = lab speed delta}, cs = {[city_id] = {relation = {[force] = r}, trades =
-- {{tick, cr}}, initial = {[item] = n}, next_restock}}, pending = {{due, force, city, item, n, cs}}, stats}.
-- Log lines "[rts] sinks: ...". Console: /rts-sinks [force] [rush project|<tech> | hire <city> <points> | merc <port> |
-- cs <city> buy|sell <item> <n>].
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local supply = require("scripts.supply")
local match = require("scripts.match")
local ages = require("scripts.ages")
local research = require("scripts.research") -- Phase 5 M3 integration: a research rush pays while a lab works
local cities = require("scripts.cities")
local divisions = require("scripts.divisions")
local garrison = require("scripts.garrison")
local treasury = require("scripts.treasury")
local market = require("scripts.market")
local marketgui = require("scripts.marketgui")
local citygui = require("scripts.citygui")
local techgui = require("scripts.techgui")
local diplomacy = require("scripts.diplomacy")
local world = require("scripts.world")
local hud = require("scripts.hud")
local age3 = require("scripts.age3")
local deps = require("scripts.ai.deps")
local balance = require("balance")

local SB = balance.nation.sinks
local RUSH, HIRE, MERC, CS = SB.rush, SB.hire, SB.mercenaries, SB.city_state
local NEUTRAL = "rts-neutral"

local sinks = {}
age3.sinks = sinks

local P4 = hud.P4
if P4 then
  P4.ALERT_STYLE["rush-ended"] = {icons = {"utility/warning_icon"}, color = "yellow"}
  P4.ALERT_STYLE["mercenaries"] = {icons = {"entity/rts-walker", "utility/check_mark_green"}, color = "green"}
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.sinks
  if not s then
    s = {}
    storage.sinks = s
  end
  s.applied = s.applied or {}
  s.cs = s.cs or {}
  s.pending = s.pending or {}
  s.stats = s.stats or {rush = 0, hire = 0, mercs = 0, cs_buy = 0, cs_sell = 0}
  return s
end

function sinks.init() S() end

local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function N(force_name, create)
  local nations = storage.nations
  local n = nations and nations[force_name]
  if not n then return nil end
  local s = n.sinks
  if not s and create then
    s = {mercs = 0}
    n.sinks = s
  end
  return s
end

local function sorted_keys(t)
  local list = {}
  for k in pairs(t or {}) do list[#list + 1] = k end
  table.sort(list)
  return list
end

---------------------------------------------------------------------------
-- Rush
---------------------------------------------------------------------------
local function running(p)
  return p and (p.state == "building" or p.state == "countdown") and p.site and p.site.valid
end

function sinks.rush_target(force_name, what)
  if not nation_mode() then return nil end
  if what == "project" then
    if ages.of(force_name) < 2 then
      local p = ages.project(force_name)
      if running(p) then return {kind = "project", what = p.name or "railway-charter", project = p} end
    else
      local P = age3.project(force_name)
      if running(P) then return {kind = "project", what = "space-program", project = P} end
    end
    return nil
  end
  local force = game.forces[force_name]
  local cur = force and force.current_research
  if cur and cur.name == what then return {kind = "research", what = what} end
  return nil
end

function sinks.rush_state(force_name)
  local s = N(force_name)
  return s and s.rush or nil
end

local function set_lab(force_name, delta)
  local force = game.forces[force_name]
  if not force then return end
  local s = S()
  local old = s.applied[force_name] or 0
  if math.abs(old - delta) < 1e-9 then return end
  force.laboratory_speed_modifier = force.laboratory_speed_modifier - old + delta
  s.applied[force_name] = delta ~= 0 and delta or nil
end

function sinks.cancel_rush(force_name, why)
  local s = N(force_name)
  local st = s and s.rush
  if not st then return false end
  s.rush = nil
  if st.kind == "research" then set_lab(force_name, 0) end
  util.log("sinks: %s rush of %s ended (%s), %.1f cr spent", force_name, st.what, tostring(why), st.spent or 0)
  if why == "funds" then supply.alert(force_name, "rush-ended", "rts-age3.alert-rush-funds", {}) end
  return true
end

function sinks.rush(force_name, what)
  if not nation_mode() then return false, "mode" end
  local t = sinks.rush_target(force_name, what)
  if not t then return false, what == "project" and "no-project" or "not-researching" end
  if treasury.stage(force_name) >= 1 or treasury.balance(force_name) <= 0 then return false, "deficit" end
  local s = N(force_name, true)
  if not s then return false, "mode" end
  if s.rush then sinks.cancel_rush(force_name, "replaced") end
  s.rush = {kind = t.kind, what = t.what, since = game.tick, spent = 0, per_minute = 0,
            stage = t.project and (t.project.stage or 1) or nil}
  if t.kind == "research" then set_lab(force_name, RUSH.speed - 1) end
  S().stats.rush = S().stats.rush + 1
  util.log("sinks: %s rushes %s %s (x%d)", force_name, t.kind, t.what, RUSH.speed)
  return true
end

-- the project rush makes the Charter and the Space Program pull and count down faster
local function rush_factor(force_name)
  local st = sinks.rush_state(force_name)
  if st and st.kind == "project" then return RUSH.speed end
  return 1
end
ages.rush_factor = rush_factor
age3.rush_factor = rush_factor

local function missing_items(p)
  local n = 0
  for item, need in pairs(p.required) do n = n + math.max(0, need - (p.delivered[item] or 0)) end
  return n
end

local function rush_step(force_name, st)
  local t = sinks.rush_target(force_name, st.kind == "project" and "project" or st.what)
  if not t or (st.kind == "project" and (t.what ~= st.what or (t.project.stage or 1) ~= st.stage)) then
    sinks.cancel_rush(force_name, "done")
    return
  end
  local dt = RUSH.period / 60
  local cost
  -- Phase 5 M3 integration (age3 notes open issue 6): a rush pays only while it speeds something up: a stage whose
  -- goods came in during the last two periods (or its countdown), a research while a lab works
  if t.kind == "project" then
    local p = t.project
    if p.state == "countdown" then
      cost = RUSH.countdown_cr * dt
    elseif p.pulled_at and game.tick - p.pulled_at <= 2 * RUSH.period + 60 then
      cost = RUSH.project_cr * missing_items(p) * dt
    else
      cost = 0
    end
  else
    local force = game.forces[force_name]
    local cur = force.current_research
    local _, working = research.lab_counts(force_name)
    cost = working > 0 and RUSH.research_cr * (1 - force.research_progress) * cur.research_unit_count * dt or 0
  end
  if cost > 0 then
    if treasury.balance(force_name) - cost < 0 or not treasury.charge(force_name, cost, "rush") then
      sinks.cancel_rush(force_name, "funds")
      return
    end
  end
  st.spent = (st.spent or 0) + cost
  st.per_minute = cost * 60 / dt
  st.last = game.tick
end

events.on_nth_tick(RUSH.period, function()
  if not nation_mode() then return end
  local m = storage.match
  if not (m and m.phase == "running") then return end
  for _, f in ipairs(match.forces()) do
    local st = sinks.rush_state(f)
    if st then rush_step(f, st) end
  end
end)

---------------------------------------------------------------------------
-- Hire garrison
---------------------------------------------------------------------------
function sinks.hire_garrison(force_name, city_id, points)
  if not nation_mode() then return false, "mode" end
  local c = cities.get(city_id)
  if not (c and c.force == force_name and c.entity and c.entity.valid) then return false, "city" end
  points = math.floor(tonumber(points) or 0)
  local now = garrison.of(city_id).hired or 0
  local n = math.min(points, math.floor(HIRE.max_points - now))
  if n <= 0 then return false, "max" end
  local cost = n * HIRE.cr_per_point
  if treasury.balance(force_name) < cost or not treasury.charge(force_name, cost, "hire") then return false, "funds" end
  local total = garrison.add_hired(city_id, n)
  S().stats.hire = S().stats.hire + n
  local s = N(force_name, true)
  if s then s.hired = (s.hired or 0) + n end
  util.log("sinks: %s hires %d garrison points at city %d for %d cr (%.1f hired there)", force_name, n, city_id, cost,
    total)
  return true
end

-- Hired points decay (one pass every decay_period ticks over every garrisoned city, by city id)
events.on_nth_tick(HIRE.decay_period, function()
  if not nation_mode() then return end
  local G = storage.garrison
  if not (G and G.cities) then return end
  for _, id in ipairs(sorted_keys(G.cities)) do
    local c = G.cities[id]
    if c and (c.hired or 0) > 0 then
      local before = c.hired
      local left = garrison.add_hired(id, -HIRE.decay_per_min * HIRE.decay_period / 3600)
      if math.floor(before) ~= math.floor(left) then
        util.log("sinks: city %d hired garrison decays to %.1f points", id, left)
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Mercenaries
---------------------------------------------------------------------------
function sinks.mercenaries(force_name, port_un)
  if not nation_mode() then return nil, "mode" end
  local port = market.port(port_un)
  if not (port and port.owner == force_name) then return nil, "port" end
  local s = N(force_name, true)
  if not s then return nil, "mode" end
  if s.merc_ready and game.tick < s.merc_ready then return nil, "cooldown" end
  local region = world.region_at(port.position)
  local kind = region and region.kind or "default"
  local template = MERC.templates[kind] or MERC.templates.default
  local need = 0
  for _, name in ipairs(sorted_keys(template)) do need = need + supply.cost(name) * template[name] end
  local used, cap = supply.used(force_name), supply.cap(force_name)
  if used + need > cap then return nil, "supply" end
  if treasury.balance(force_name) < MERC.cost or not treasury.charge(force_name, MERC.cost, "mercenaries") then
    return nil, "funds"
  end
  local surface = match.surface()
  local list = {}
  local total = 0
  for _, name in ipairs(sorted_keys(template)) do total = total + template[name] end
  local i = 0
  for _, name in ipairs(sorted_keys(template)) do
    local u = balance.units[name]
    for _ = 1, template[name] do
      i = i + 1
      local a = 2 * math.pi * i / total
      local pos = {x = port.position.x + math.cos(a) * MERC.radius, y = port.position.y + math.sin(a) * MERC.radius}
      local e = units.spawn(name, pos, force_name, u and u.kind, surface)
      if e then list[#list + 1] = e end
    end
  end
  -- Phase 5 M3 integration: "ai" whenever an AI commander decides for the force (an AI-driven rts-player too)
  local owner = diplomacy.is_ai(force_name) and "ai" or "player"
  -- Phase 5 M3 integration (GUI audit): named after the region's proper name ("Mercenaries (Karvis)"): the port's full
  -- name was cut on the division card in Russian
  local short = region and region.pname and region.pname.loc or port.name
  local id = #list > 0 and divisions.create(force_name, list, {name = {"rts-age3.mercenary-name", short},
                                                               stance = "hold"}, {owner = owner}) or nil
  s.merc_ready = game.tick + MERC.cooldown * 60
  s.mercs = (s.mercs or 0) + 1
  S().stats.mercs = S().stats.mercs + 1
  util.log("sinks: %s hires mercenaries at port #%d (%s, region %s): %d units, division #%s, %d cr", force_name,
    port_un, util.pos_str(port.position), kind, #list, tostring(id), MERC.cost)
  supply.alert(force_name, "mercenaries", "rts-age3.alert-mercenaries", {#list, port.name}, port.position)
  return id
end

---------------------------------------------------------------------------
-- City-state trade
---------------------------------------------------------------------------
local function cs_city(city_id)
  local c = cities.get(city_id)
  if c and c.force == NEUTRAL and c.archetype == "city_state" and c.entity and c.entity.valid then return c end
  return nil
end

local function cs_record(city_id)
  local s = S()
  local r = s.cs[city_id]
  if not r then
    r = {relation = {}, trades = {}}
    s.cs[city_id] = r
  end
  return r
end

local function cs_site(city_id)
  for _, rec in ipairs(world.city_states()) do
    if rec.city_id == city_id then return rec end
  end
  return nil
end

--- The region's goods a city-state sells: {item = starting stock}.
local function cs_goods(city_id)
  local rec = cs_site(city_id)
  local out = {}
  local list = rec and (world.CS.stock[rec.anchor] or world.CS.stock.pass) or {}
  for _, g in ipairs(list) do
    if prototypes.item[g[1]] and market.p0(g[1]) then out[g[1]] = g[2] end
  end
  return out
end

local function relation_of(city_id, force_name)
  local r = S().cs[city_id]
  return r and r.relation[force_name] or 0
end
sinks.relation = relation_of

local function markup(r)
  local share = math.max(0, math.min(100, r)) / 100
  return CS.markup + (CS.markup_best - CS.markup) * share
end

local function cs_used(r)
  local from = game.tick - 60 * 60
  local n, keep = 0, {}
  for _, t in ipairs(r.trades) do
    if t.tick > from then
      n = n + t.cr
      keep[#keep + 1] = t
    end
  end
  r.trades = keep
  return n
end

-- The nation's city nearest to a position (its centre must stand), or nil.
local function nearest_city(force_name, pos)
  local best, bd
  for _, c in ipairs(cities.for_force(force_name)) do
    if c.entity and c.entity.valid then
      local d = util.distance(c.position, pos)
      if not bd or d < bd then best, bd = c, d end
    end
  end
  return best
end

local function net_of(c)
  local e = c and c.entity
  local net = e and e.valid and e.logistic_network
  return (net and net.valid) and net or nil
end

--- Unit price of a good at a city-state for a nation: buy (markup) or sell (sell_factor), nil = not traded.
function sinks.cs_price(force_name, city_id, item, side)
  if not market.p0(item) then return nil end
  if side == "buy" then
    if not cs_goods(city_id)[item] then return nil end
    return market.price(item) * markup(relation_of(city_id, force_name))
  end
  return market.price(item) * CS.sell_factor
end

local function adjust_relation(city_id, force_name, delta)
  local r = cs_record(city_id)
  local old = r.relation[force_name] or 0
  r.relation[force_name] = math.max(-100, math.min(100, old + delta))
  return r.relation[force_name]
end

function sinks.trade_with_city_state(force_name, city_id, item, count, buy)
  if not (nation_mode() and match.is_participant(force_name)) then return false, "mode" end
  local c = cs_city(city_id)
  if not c then return false, "city" end
  count = math.floor(tonumber(count) or 0)
  if count <= 0 or not prototypes.item[item] then return false, "item" end
  local rel = relation_of(city_id, force_name)
  if rel < CS.min_relation then return false, "relation" end
  local price = sinks.cs_price(force_name, city_id, item, buy and "buy" or "sell")
  if not price then return false, "item" end
  local r = cs_record(city_id)
  local room = CS.cap_per_min - cs_used(r)
  local n = math.min(count, math.floor(room / math.max(price, 0.01)))
  if n <= 0 then return false, "cap" end
  local home = nearest_city(force_name, c.position)
  local hnet = net_of(home)
  if not hnet then return false, "no-city" end
  local cnet = net_of(c)
  local cr
  if buy then
    if treasury.stage(force_name) >= 1 then return false, "deficit" end
    local stock = cnet and cnet.get_item_count(item) or 0
    n = math.min(n, stock)
    if n <= 0 then return false, "stock" end
    cr = price * n
    if not treasury.charge(force_name, cr, "purchase") then return false, "funds" end
    local got = cnet.remove_item({name = item, count = n})
    if got < n then
      treasury.add(force_name, price * (n - got), "refund")
      n = got
      cr = price * n
    end
    local s = S()
    s.pending[#s.pending + 1] = {due = game.tick + CS.delay, force = force_name, city = home.id, item = item, n = n,
                                 cs = city_id}
    s.stats.cs_buy = s.stats.cs_buy + cr
  else
    local have = hnet.get_item_count(item)
    n = math.min(n, have)
    if n <= 0 then return false, "stock" end
    n = hnet.remove_item({name = item, count = n})
    if cnet then cnet.insert({name = item, count = n}) end
    cr = price * n
    treasury.add(force_name, cr, "sale")
    S().stats.cs_sell = S().stats.cs_sell + cr
  end
  r.trades[#r.trades + 1] = {tick = game.tick, cr = cr}
  local new = adjust_relation(city_id, force_name, cr / CS.relation_cr)
  util.log("sinks: %s %s %d %s %s city-state %d at %.2f cr each (%.1f cr), relation %.1f -> %.1f", force_name,
    buy and "buys" or "sells", n, item, buy and "from" or "to", city_id, price, cr, rel, new)
  return true, cr
end
market.trade_with_city_state = sinks.trade_with_city_state

--- City-states a nation can trade with: {{city_id, name, relation, markup, goods = {{item, stock, price}}}}.
function sinks.city_states(force_name)
  local out = {}
  for _, rec in ipairs(world.city_states()) do
    local c = rec.city_id and cs_city(rec.city_id)
    if c then
      local rel = relation_of(c.id, force_name)
      local goods = {}
      local net = net_of(c)
      for _, item in ipairs(sorted_keys(cs_goods(c.id))) do
        goods[#goods + 1] = {item = item, stock = net and net.get_item_count(item) or 0,
                             price = sinks.cs_price(force_name, c.id, item, "buy")}
      end
      out[#out + 1] = {city_id = c.id, name = cities.display_name(c), relation = rel, markup = markup(rel),
                       goods = goods}
    end
  end
  return out
end

-- deliveries and restocking
events.on_nth_tick(60, function(e)
  local s = storage.sinks
  if not (s and nation_mode()) then return end
  if #s.pending > 0 then
    local keep = {}
    for _, d in ipairs(s.pending) do
      if e.tick >= d.due then
        local c = cities.get(d.city)
        if not (c and c.force == d.force) then c = nearest_city(d.force, c and c.position or {x = 0, y = 0}) end
        local net = net_of(c)
        local put = net and net.insert({name = d.item, count = d.n}) or 0
        util.log("sinks: %s city-state delivery of %d %s arrived at city %s (%d in its network)", d.force, d.n, d.item,
          tostring(c and c.id), put)
      else
        keep[#keep + 1] = d
      end
    end
    s.pending = keep
  end
  if e.tick % CS.restock_period ~= 0 then return end
  for _, rec in ipairs(world.city_states()) do
    local c = rec.city_id and cs_city(rec.city_id)
    local net = net_of(c)
    if net then
      for item, n in pairs(cs_goods(c.id)) do
        local have = net.get_item_count(item)
        if have < n then net.insert({name = item, count = math.min(n - have, math.ceil(n * CS.restock_share))}) end
      end
    end
  end
end)

-- A city-state taken in peacetime: every other nation thinks less of the captor
events.on_signal("rts_city_captured", function(d)
  if not (d and d.from == NEUTRAL and d.to and nation_mode()) then return end
  if diplomacy.at_war(d.to) then
    util.log("sinks: %s captured city-state city %d at war: no relation penalty", d.to, d.city_id or -1)
    return
  end
  for _, f in ipairs(diplomacy.nations()) do
    if f ~= d.to then diplomacy.adjust(f, d.to, CS.capture_penalty, "city-state") end
  end
  for _, rec in ipairs(world.city_states()) do
    if rec.city_id and rec.city_id ~= d.city_id then adjust_relation(rec.city_id, d.to, CS.capture_relation) end
  end
  util.log("sinks: %s captured city-state city %d at peace: relation %d with every nation, %d with the city-states",
    d.to, d.city_id or -1, CS.capture_penalty, CS.capture_relation)
end)

---------------------------------------------------------------------------
-- GUI: the city panel's Hire button, the market panel's city-states
---------------------------------------------------------------------------
citygui.foot_hook = function(foot, el, c)
  el.a3_hire = foot.add({type = "button", style = "rts_hud_button", caption = "", tags = {rts_age3 = "hire",
                                                                                          city = c.id}})
  el.a3_hire.style.height = 24
end

citygui.refresh_hook = function(player, el, c)
  local b = el.a3_hire
  if not (b and b.valid) then return end
  local own = c.force == player.force.name
  b.visible = own
  if not own then return end
  local hired = garrison.of(c.id).hired or 0
  b.caption = {"rts-age3.hire", HIRE.step, treasury.fmt(HIRE.step * HIRE.cr_per_point)}
  b.tooltip = {"rts-age3.hire-tooltip", string.format("%.1f", hired), HIRE.max_points, HIRE.decay_per_min,
               HIRE.cr_per_point}
  b.enabled = hired + 1 <= HIRE.max_points and treasury.balance(c.force) >= HIRE.step * HIRE.cr_per_point
end

marketgui.partners = {
  extra = function(force_name)
    local list = {}
    for _, cs in ipairs(sinks.city_states(force_name)) do
      list[#list + 1] = {key = cs.city_id, name = {"rts-age3.market-city-state", cs.name,
        string.format("%.2f", cs.markup), string.format("%+.0f", cs.relation)}}
    end
    return list
  end,
  contents = function(force_name, key)
    local out = {}
    for _, cs in ipairs(sinks.city_states(force_name)) do
      if cs.city_id == key then
        for _, g in ipairs(cs.goods) do out[g.item] = g.stock end
      end
    end
    return out
  end,
  price = function(force_name, key, item, side) return sinks.cs_price(force_name, key, item, side) end,
  hint = function(force_name, key)
    local c = cities.get(key)
    local rel = relation_of(key, force_name)
    return {"rts-age3.market-city-state-hint", c and cities.display_name(c) or tostring(key),
            string.format("%+.0f", rel), string.format("%.2f", markup(rel))}
  end,
  trade = function(force_name, key, item, n, buy) return sinks.trade_with_city_state(force_name, key, item, n, buy) end,
}

marketgui.extend = function(player, g, top)
  local row = top.add({type = "flow", direction = "horizontal"})
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 10
  g.a3_merc_row = row
  g.a3_merc = row.add({type = "button", caption = {"rts-age3.merc", treasury.fmt(MERC.cost)}, tags = {rts_age3 = "merc"},
                       tooltip = ""})
  g.a3_merc_text = row.add({type = "label", caption = ""})
  g.a3_merc_text.style.font_color = {r = 0.7, g = 0.7, b = 0.7}
end

marketgui.extend_refresh = function(player, g, port_un)
  local b = g.a3_merc
  if not (b and b.valid) then return end
  local f = player.force.name
  local s = N(f)
  local wait = s and s.merc_ready and math.max(0, math.ceil((s.merc_ready - game.tick) / 60)) or 0
  local port = port_un and market.port(port_un)
  local region = port and world.region_at(port.position)
  local template = MERC.templates[region and region.kind or "default"] or MERC.templates.default
  local parts = {""}
  for _, name in ipairs(sorted_keys(template)) do
    parts[#parts + 1] = string.format("%d [entity=%s] ", template[name], name)
  end
  local own = port ~= nil and port.owner == f
  if g.a3_merc_row and g.a3_merc_row.valid then g.a3_merc_row.visible = own end
  b.enabled = wait == 0 and treasury.balance(f) >= MERC.cost
  b.tooltip = {"rts-age3.merc-tooltip", table.concat(parts), treasury.fmt(MERC.cost), math.floor(MERC.cooldown / 60)}
  b.tags = {rts_age3 = "merc", port = port_un}
  if g.a3_merc_text and g.a3_merc_text.valid then
    g.a3_merc_text.caption = wait > 0 and {"rts-age3.merc-wait", wait} or table.concat(parts)
  end
end

techgui.extend = function(player, g, row)
  g.a3_rush = row.add({type = "button", caption = {"rts-age3.rush"}, tags = {rts_age3 = "rush_research"}})
  g.a3_rush.style.left_margin = 8
end

techgui.extend_refresh = function(player, g)
  local b = g.a3_rush
  if not (b and b.valid) then return end
  local f = player.force.name
  local force = player.force
  local cur = force.current_research
  local st = sinks.rush_state(f)
  local rushing = st ~= nil and st.kind == "research"
  b.visible = nation_mode() and (cur ~= nil or rushing)
  if rushing then
    b.caption = {"rts-age3.rush-stop", treasury.fmt(st.per_minute or 0)}
    b.tooltip = {"rts-age3.rush-research-stop-tooltip", treasury.fmt(st.spent or 0)}
  else
    b.caption = {"rts-age3.rush"}
    b.tooltip = {"rts-age3.rush-research-tooltip", RUSH.speed, string.format("%.2f", RUSH.research_cr)}
  end
end

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  local action = el and el.valid and el.tags and el.tags.rts_age3
  if action ~= "hire" and action ~= "merc" and action ~= "rush_research" then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  if action == "rush_research" then
    local f = player.force.name
    local st = sinks.rush_state(f)
    if st and st.kind == "research" then
      sinks.cancel_rush(f, "player")
    else
      local cur = player.force.current_research
      local ok, why = sinks.rush(f, cur and cur.name or "")
      if not ok then player.print({"rts-age3.rush-refused", {"rts-age3.reason-" .. tostring(why)}}) end
    end
    techgui.refresh(player)
  elseif action == "hire" then
    local ok, why = sinks.hire_garrison(player.force.name, el.tags.city, HIRE.step)
    if not ok then player.print({"rts-age3.hire-refused", {"rts-age3.reason-" .. tostring(why)}}) end
  else
    local id, why = sinks.mercenaries(player.force.name, el.tags.port)
    if not id then player.print({"rts-age3.merc-refused", {"rts-age3.reason-" .. tostring(why)}}) end
  end
end)

---------------------------------------------------------------------------
-- Teardown, describe, console
---------------------------------------------------------------------------
match.on_teardown(function()
  local s = storage.sinks
  for force_name in pairs(s and s.applied or {}) do set_lab(force_name, 0) end
  for _, n in pairs(storage.nations or {}) do n.sinks = nil end
  storage.sinks = nil
  S()
end)

function sinks.describe(force_name)
  local s = N(force_name)
  local st = s and s.rush
  return string.format("%s: rush %s, hired %d points, mercenaries %d (ready %s)", force_name,
    st and string.format("%s %s (%.0f cr spent)", st.kind, st.what, st.spent or 0) or "none", s and s.hired or 0,
    s and s.mercs or 0, s and s.merc_ready and tostring(s.merc_ready) or "now")
end

commands.add_command("rts-sinks", "[force] [rush project|<tech> | hire <city> <n> | merc <port> | cs <city> buy|sell "
  .. "<item> <n>] - money sinks (QA)", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  local w = {}
  for x in string.gmatch(cmd.parameter or "", "%S+") do w[#w + 1] = x end
  local f = (w[1] and game.forces[w[1]]) and table.remove(w, 1) or (player and player.force.name) or util.PLAYER_FORCE
  if w[1] and player and not player.admin then
    player.print("rts-sinks: admins only")
    return
  end
  local r1, r2
  if w[1] == "rush" and w[2] then r1, r2 = sinks.rush(f, w[2])
  elseif w[1] == "hire" and tonumber(w[2]) then r1, r2 = sinks.hire_garrison(f, tonumber(w[2]), tonumber(w[3]) or 4)
  elseif w[1] == "merc" and tonumber(w[2]) then r1, r2 = sinks.mercenaries(f, tonumber(w[2]))
  elseif w[1] == "cs" and tonumber(w[2]) and w[4] then
    r1, r2 = sinks.trade_with_city_state(f, tonumber(w[2]), w[4], tonumber(w[5]) or 10, w[3] == "buy")
  end
  local line = sinks.describe(f) .. (w[1] and string.format(" | %s: %s %s", w[1], tostring(r1), tostring(r2)) or "")
  if player then player.print(line) else log("[rts] " .. line) end
end)

deps.sinks = sinks
return sinks
