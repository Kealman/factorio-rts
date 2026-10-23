-- Phase 5 M2 world market and trade ports (docs/PHASE5-M2.md section 3 "treasury.lua / market.lua", decision D5;
-- studies docs/research/scale/deep-economy.md sections 4.3-4.4 and rails-trade.md sections 4.2-4.6;
-- docs/qa/phase5-treasury-notes.md). Nation mode only.
--
--   market.price(item) -> cr             current unit price p = p0 x (S0 / S) ^ 0.6, clamped to 0.4-3 x p0
--   market.quote(item, n, side) -> cr    what selling ("sell") or buying ("buy") n would pay / cost now (curve, 0.9 / 1.1)
--   market.sell(force, port_un, item, n) -> cr, reason      goods leave the port's network now, S += n, paid 0.9 x curve
--   market.buy(force, port_un, item, n) -> ok, cr | reason   charged 1.1 x curve now, goods appear in the port's network
--                                                           after 30 s (and nowhere else); blocked in deficit (stage >= 1)
--   market.contract(seller, buyer, item, n_per, deliveries, interval_s, price) -> id | nil, reason
--   market.cancel_contract(id, why); market.contracts(force?) -> {contract, ...}
--   market.on_contract_event(fn)          fn{kind = "created"|"delivered"|"late"|"missed"|"completed"|"cancelled", id,
--                                         seller, buyer, item, n, delivery, deliveries, fault = "seller"|"buyer", value}
--   market.ports(force) -> {port_un, ...}; market.port(un) -> record; market.all_ports() -> {record, ...}
--   market.cap(force) -> cr per minute;  market.cap_used(force) -> cr in the last minute
--   market.history(item) -> {price, ...} (oldest first, one sample per minute, the last 10 minutes, then the current)
--   market.volume(force) -> {sold, bought, contract_sold, contract_bought, total, sales, purchases}
--   market.items() -> tradeable goods in display order;  market.p0(item), market.stock(item) -> S, S0
--   market.place_port(surface, position) -> port   (world.lua calls it for every port site once its chunks exist)
--   market.set_owner(port_un, force) / market.capture_step(dt)
--   market.ai_step(C)                     normal AI (ai/commander.lua, every run; throttled to ai.period)
--
-- Prices. p0 anchors in balance.nation.market.p0; every other good is derived at match start from its recipe
-- (markup 1.1 x (ingredients + 0.1 x seconds) / products; district recipes only when nothing else makes it). Goods that
-- are placeable, unit kits or have no recipe and no anchor are not traded. A sale or purchase is priced along the
-- curve (dumping lowers the price as it goes). Every minute S drifts 5 % back towards S0 and the price is sampled.
--
-- Commerce cap (rolling 60 s): cr sold + bought per minute <= (300 + 150 x ports held) x (1 + 0.25 x Commerce level).
-- A sale or purchase is cut to what still fits; with nothing left it is refused ("cap"). Contracts do not count.
--
-- Trade ports. A rts-trade-post (prototypes/trade.lua, a hub subtype: scripts/logistics.lua builds its composite and
-- network) is placed on every world port site under force rts-neutral, with port_stock as loot in its stockpiles. It
-- and its parts are indestructible and never demolished. A port is captured like the ruin: a force with military units
-- (registered units, haulers excluded) within capture.range tiles of the post or its stockpiles (a 7.5-tile circle
-- around its centre) for capture.ticks, while no unit of the owner is there and no other force contests it. The
-- composite then changes force (entities, building records, the hub policy), the old owner's haulers routed to it go
-- home, and the alerts "port-captured" / "port-lost" are raised. Signal "rts_port_captured" {port, force, previous}.
--
-- Contracts (D5): a fixed-price scheduled sale settled at the two nations' ports. At each due time `n` goods leave a
-- seller's port network, the buyer pays price x n (treasury.charge) and the seller is paid; the goods appear at the
-- buyer's port after import_delay. A delivery that cannot settle (no goods at a seller port, no buyer port, the buyer
-- cannot pay) is "late" (event once); after contract.late_grace it is "missed" (event; scripts/diplomacy.lua takes
-- the reputation) and the next delivery is due one interval after the missed one.
--
-- Owns storage.market = {match_id, p0 = {[item] = p0}, S0 = {[item] = S0}, stock = {[item] = S}, items = {...},
--   history = {[item] = {p, ...}}, ports = {[un] = port}, parts = {[stockpile un] = port un}, pending = {import, ...},
--   contracts = {[id] = c}, next_id, trades = {[force] = {{tick, cr}, ...}}, volume = {[force] = {...}},
--   ai = {[force] = A}, next_drift}
-- port = {un, entity, position, region, name, owner, capturing, progress, label, chart, created, captured_at}
-- import = {id, due, force, port, item, n, cost, contract?, bought}
-- Log lines "[rts] market: ...". Console: /rts-market [prices | ports | sell <item> <n> | buy <item> <n> |
-- capture <port un> | contract <buyer> <item> <n> <deliveries> <interval s> <price>] [force=<name>].
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local supply = require("scripts.supply")
local logistics = require("scripts.logistics")
local orders = require("scripts.orders")
local match = require("scripts.match")
local world = require("scripts.world")
local treasury = require("scripts.treasury")
local deps = require("scripts.ai.deps")
local balance = require("balance")
local research
do
  local ok, mod = pcall(require, "scripts.research")
  if ok and type(mod) == "table" then research = mod end
end

local market = {}

local MB = balance.nation.market
local AI = MB.ai
market.POST = "rts-trade-post"
market.NEUTRAL = "rts-neutral"
market.ENVOY_ORDER = "port"
market.ISSUER = "market"
market.CAPTURE_RADIUS = MB.capture.range + 3.5 -- post half size 2 + stockpile offset 3.5 - ... see the header
market.PENDING_PERIOD = 10
market.CONTRACT_PERIOD = 10
market.UNIT_TYPES = {"spider-unit", "spider-vehicle", "unit"}
market.LABEL_COLOR = {1, 0.82, 0.35}

-- The trade post is a hub subtype (logistics.lua builds the composite and keeps its policy).
buildings.KIND_BY_NAME[market.POST] = "hub"
logistics.NAME_HOOKS[market.POST] = function(un)
  local S = storage.market
  local p = S and S.ports and S.ports[un]
  return p and p.name or {"entity-name." .. market.POST}
end

-- Commerce I / II: Nation-only technologies; their level raises the cap (market.cap reads research.has).
if research then
  for _, t in ipairs(MB.commerce) do
    research.EFFECTS[t.name] = research.EFFECTS[t.name] or {flag = t.name}
    if research.NATION_ONLY then research.NATION_ONLY[t.name] = true end
  end
end

local contract_hooks = {}
--- fn(event) for every contract event (see the header). Load time only (scripts/diplomacy.lua).
function market.on_contract_event(fn) contract_hooks[#contract_hooks + 1] = fn end

local EXP = MB.exponent
local LO, HI = MB.clamp[1], MB.clamp[2]

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function loaded(module_name)
  local l = package and package.loaded
  if not l then return nil end
  return l["__" .. script.mod_name .. "__/" .. string.gsub(module_name, "%.", "/") .. ".lua"] or l[module_name]
end

local function nation()
  local m = storage.match
  return m ~= nil and m.surface ~= nil and m.config ~= nil and m.config.mode == "nation"
end
market.nation = nation

local function label_of(force_name)
  return force_name and match.label(force_name) or {"rts-treasury.port-neutral"}
end

local function item_name(item)
  local p = prototypes.item[item]
  return p and p.localised_name or item
end

local function neutral_force()
  local f = game.forces[market.NEUTRAL] or game.create_force(market.NEUTRAL) -- idempotent; diplomacy sets relations
  return f
end

---------------------------------------------------------------------------
-- Prices: derivation (static prototype data, computed once per match)
---------------------------------------------------------------------------
local SKIP_SUBGROUPS = {["rts-units"] = true}

local function tradeable_item(name)
  local p = prototypes.item[name]
  if not p then return false end
  if p.place_result then return false end -- buildings and rails; tile items (bricks, concrete) are goods
  if p.hidden then return false end
  if p.subgroup and SKIP_SUBGROUPS[p.subgroup.name] then return false end
  if p.type ~= "item" and p.type ~= "tool" and p.type ~= "ammo" then return false end
  return true
end

local function usable_recipe(r, district_ok)
  local cat = util.recipe_category(r) or "" -- 2.1: LuaRecipePrototype::category -> categories
  if cat == "recycling" or string.find(cat, "recycling", 1, true) then return false end
  local district = string.sub(cat, 1, 13) == "rts-district-"
  if district and not district_ok then return false end
  return string.sub(cat, 1, 4) == "rts-" or cat == "smelting" or string.sub(r.name, 1, 4) == "rts-"
end

local function derive_prices()
  local p0 = {}
  for item, v in pairs(MB.p0) do
    if prototypes.item[item] then p0[item] = v end
  end
  -- candidate recipes per item product: normal first, district recipes as the fallback
  local by_product, by_product_d = {}, {}
  for name, r in pairs(prototypes.recipe) do
    local normal, dist = usable_recipe(r, false), usable_recipe(r, true)
    if normal or dist then
      for _, prod in ipairs(r.products or {}) do
        if prod.type == "item" then
          local t = normal and by_product or by_product_d
          t[prod.name] = t[prod.name] or {}
          table.insert(t[prod.name], name)
        end
      end
    end
  end
  for _, t in pairs(by_product) do table.sort(t) end
  for _, t in pairs(by_product_d) do table.sort(t) end
  local visiting = {}
  local function price_of(item, depth)
    if p0[item] then return p0[item] end
    if visiting[item] or depth > MB.derive.depth then return nil end
    visiting[item] = true
    local best
    for _, list in ipairs({by_product[item] or {}, by_product_d[item] or {}}) do
      for _, rname in ipairs(list) do
        local r = prototypes.recipe[rname]
        local cost, ok = 0, true
        for _, ing in ipairs(r.ingredients or {}) do
          if ing.type == "item" then
            local ip = price_of(ing.name, depth + 1)
            if not ip then ok = false break end
            cost = cost + ip * ing.amount
          end
        end
        local amount = 0
        for _, prod in ipairs(r.products or {}) do
          if prod.name == item and prod.type == "item" then
            local a = prod.amount or ((prod.amount_min or 0) + (prod.amount_max or 0)) / 2
            amount = amount + a * (prod.independent_probability or prod.probability or 1) -- 2.1: Product::probability -> independent_probability
          end
        end
        if ok and amount > 0 then
          local v = MB.derive.markup * (cost + MB.derive.per_second * (r.energy or 0)) / amount
          if v > 0 and (not best or v < best) then best = v end
        end
      end
      if best then break end
    end
    visiting[item] = nil
    if best then p0[item] = best end
    return best
  end
  local names = {}
  for name in pairs(prototypes.item) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if tradeable_item(name) and (by_product[name] or by_product_d[name]) then price_of(name, 0) end
  end
  local out, items = {}, {}
  for item, v in pairs(p0) do
    if tradeable_item(item) then
      out[item] = math.floor(v * 1000 + 0.5) / 1000
      items[#items + 1] = item
    end
  end
  -- display order: item group, subgroup, item order
  table.sort(items, function(a, b)
    local pa, pb = prototypes.item[a], prototypes.item[b]
    local ga, gb = pa.group and pa.group.order or "", pb.group and pb.group.order or ""
    if ga ~= gb then return ga < gb end
    local sa, sb = pa.subgroup and pa.subgroup.order or "", pb.subgroup and pb.subgroup.order or ""
    if sa ~= sb then return sa < sb end
    if pa.order ~= pb.order then return pa.order < pb.order end
    return a < b
  end)
  return out, items
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function new_state()
  local m = storage.match
  local p0, items = derive_prices()
  local S = {match_id = m.match_id, p0 = p0, S0 = {}, stock = {}, items = items, history = {}, ports = {}, parts = {},
             pending = {}, contracts = {}, next_id = 1, trades = {}, volume = {}, ai = {},
             next_drift = game.tick + MB.drift_period}
  local so = MB.s0
  for _, item in ipairs(items) do
    local s0 = so.override[item] or math.max(so.min, math.min(so.max, so.value / p0[item]))
    S.S0[item] = math.floor(s0 + 0.5)
    S.stock[item] = S.S0[item]
    S.history[item] = {}
  end
  local parts = {}
  for _, item in ipairs(items) do parts[#parts + 1] = string.format("%s %.2f/%d", item, p0[item], S.S0[item]) end
  util.log("market: opens for match %s with %d goods (p0/S0): %s", tostring(m.match_id), #items, table.concat(parts, ", "))
  return S
end

--- storage.market for the running Nation match (created on first use), or nil.
local function M()
  if not nation() then return nil end
  local S = storage.market
  local m = storage.match
  if not S or S.match_id ~= m.match_id then
    S = new_state()
    storage.market = S
  end
  return S
end
market.state = M

function market.init()
  storage.market = storage.market or nil
end

match.on_teardown(function()
  storage.market = nil
end)

---------------------------------------------------------------------------
-- The price curve
---------------------------------------------------------------------------
-- Integral of the clamped price from 0 to s: constant HI x p0 below a, the power curve between, LO x p0 above b.
local function F(p0, S0, s)
  local a = S0 * HI ^ (-1 / EXP)
  local b = S0 * LO ^ (-1 / EXP)
  if s <= a then return HI * p0 * s end
  local k = p0 * S0 ^ EXP / (1 - EXP)
  local Fa = HI * p0 * a
  if s <= b then return Fa + k * (s ^ (1 - EXP) - a ^ (1 - EXP)) end
  return Fa + k * (b ^ (1 - EXP) - a ^ (1 - EXP)) + LO * p0 * (s - b)
end
market.integral = F

local function price_at(p0, S0, s)
  local r = (S0 / math.max(s, 1e-6)) ^ EXP
  return p0 * math.max(LO, math.min(HI, r))
end
market.price_at = price_at

--- Current unit price of a good (nil when it is not traded).
function market.price(item)
  local S = M()
  local p0 = S and S.p0[item]
  if not p0 then return nil end
  return price_at(p0, S.S0[item], S.stock[item])
end

function market.p0(item)
  local S = M()
  return S and S.p0[item] or nil
end

--- World stock S and its reference S0 of a good.
function market.stock(item)
  local S = M()
  if not (S and S.p0[item]) then return nil end
  return S.stock[item], S.S0[item]
end

function market.items()
  local S = M()
  return S and S.items or {}
end

--- What selling (side "sell") or buying ("buy") n now pays / costs, along the curve. nil when not traded.
function market.quote(item, n, side)
  local S = M()
  local p0 = S and S.p0[item]
  if not p0 or not n or n <= 0 then return nil end
  local s, s0 = S.stock[item], S.S0[item]
  if side == "buy" then
    if n > s then return nil end
    return MB.buy_factor * (F(p0, s0, s) - F(p0, s0, s - n))
  end
  return MB.sell_factor * (F(p0, s0, s + n) - F(p0, s0, s))
end

function market.history(item)
  local S = M()
  if not (S and S.p0[item]) then return {} end
  local out = {}
  for i, v in ipairs(S.history[item]) do out[i] = v end
  out[#out + 1] = market.price(item)
  return out
end

---------------------------------------------------------------------------
-- Ports
---------------------------------------------------------------------------
--- The port record of a trade post unit number, or nil.
function market.port(un)
  local S = storage.market
  local p = S and S.ports and S.ports[un]
  if p and p.entity.valid then return p end
  return nil
end

--- Every live port record, by unit number.
function market.all_ports()
  local S = M()
  local out = {}
  for _, p in pairs(S and S.ports or {}) do
    if p.entity.valid then out[#out + 1] = p end
  end
  table.sort(out, function(a, b) return a.un < b.un end)
  return out
end

--- Unit numbers of the ports a force holds, nearest to its capital first.
function market.ports(force_name)
  local S = storage.market
  local out = {}
  if not (S and S.ports and nation()) then return out end
  for un, p in pairs(S.ports) do
    if p.owner == force_name and p.entity.valid then out[#out + 1] = un end
  end
  local cc = buildings.main_cc(force_name)
  local home = cc and cc.position
  table.sort(out, function(a, b)
    if home then
      local da, db = util.distance_sq(S.ports[a].position, home), util.distance_sq(S.ports[b].position, home)
      if da ~= db then return da < db end
    end
    return a < b
  end)
  return out
end

local function port_stockpiles(p)
  local pol = logistics.policy(p.un)
  local out = {}
  for _, s in ipairs(pol and pol.parts and pol.parts.stockpiles or {}) do
    if s.valid then out[#out + 1] = s end
  end
  return out
end

local function port_entities(p)
  local pol = logistics.policy(p.un)
  local list = {p.entity}
  local parts = pol and pol.parts or {}
  if parts.power and parts.power.valid then list[#list + 1] = parts.power end
  if parts.pole and parts.pole.valid then list[#list + 1] = parts.pole end
  for _, s in ipairs(port_stockpiles(p)) do list[#list + 1] = s end
  return list
end

--- Count of `item` at a port: its logistic network, else its stockpiles.
local function port_count(p, item)
  local net = logistics.hub_network(p.un)
  if net then return net.get_item_count(item) end
  local n = 0
  for _, s in ipairs(port_stockpiles(p)) do n = n + s.get_item_count(item) end
  return n
end

--- {[item] = n} at a port.
function market.port_contents(un)
  local p = market.port(un)
  local out = {}
  if not p then return out end
  local net = logistics.hub_network(un)
  if net then
    for _, it in pairs(net.get_contents()) do out[it.name] = (out[it.name] or 0) + it.count end
  else
    for _, s in ipairs(port_stockpiles(p)) do
      for _, it in pairs(s.get_inventory(defines.inventory.chest).get_contents()) do
        out[it.name] = (out[it.name] or 0) + it.count
      end
    end
  end
  return out
end

local function port_remove(p, item, n)
  local net = logistics.hub_network(p.un)
  if net then return net.remove_item({name = item, count = n}) end
  local got = 0
  for _, s in ipairs(port_stockpiles(p)) do
    if got >= n then break end
    got = got + s.remove_item({name = item, count = n - got})
  end
  return got
end

local function port_insert(p, item, n)
  local put = 0
  for _, s in ipairs(port_stockpiles(p)) do
    if put >= n then break end
    put = put + s.insert({name = item, count = n - put})
  end
  return put
end

local function set_label(p)
  local text
  if p.capturing then
    text = {"rts-treasury.port-capturing", p.name, label_of(p.capturing),
            math.floor(100 * (p.progress or 0) / MB.capture.ticks)}
  elseif p.owner then
    text = {"rts-treasury.port-owned", p.name, label_of(p.owner)}
  else
    text = {"rts-treasury.port-label", p.name}
  end
  if p.label and p.label.valid then p.label.text = text end
  if p.chart and p.chart.valid then p.chart.text = text end
end

--- Place a trade post (and its composite) at a world port site under rts-neutral. Returns the port record or nil.
function market.place_port(surface, pos)
  local S = M()
  if not S then return nil end
  local nf = neutral_force()
  local at = {x = pos.x, y = pos.y}
  if not surface.can_place_entity({name = market.POST, position = at, force = nf}) then
    at = surface.find_non_colliding_position(market.POST, at, 12, 1, true)
  end
  local post = at and surface.create_entity({name = market.POST, position = at, force = nf,
                                             create_build_effect_smoke = false})
  if not post then
    util.log("market: no room for a trade post near %s", util.pos_str(pos))
    return nil
  end
  post.destructible = false
  post.operable = false
  local un = post.unit_number
  local region = world.region_at(post.position)
  local index = table_size(S.ports) + 1
  local p = {un = un, entity = post, position = {x = post.position.x, y = post.position.y},
             region = region and region.id, index = index, owner = nil, progress = 0, created = game.tick,
             name = region and {"rts-treasury.port-name", region.name} or {"rts-treasury.port-name-n", index}}
  S.ports[un] = p
  buildings.register(post) -- logistics.lua: hidden power and pole, two stockpiles, robots
  local pol = logistics.policy(un)
  if pol then
    for item in pairs(pol.keep) do logistics.set_policy(un, "keep", item, nil) end
    for item in pairs(pol.export_above) do logistics.set_policy(un, "export_above", item, nil) end
  end
  for _, e in ipairs(port_entities(p)) do
    e.destructible = false
    e.minable_flag = false -- 2.1: LuaEntity::minable is read-only, minable_flag
    if e ~= post then S.parts[e.unit_number or -1] = un end
  end
  local stock = {}
  for _, it in ipairs(MB.port_stock) do
    if prototypes.item[it[1]] then
      local put = port_insert(p, it[1], it[2])
      stock[#stock + 1] = string.format("%s %d", it[1], put)
    end
  end
  p.label = rendering.draw_text({text = "", surface = surface, target = {p.position.x, p.position.y - 3.4},
                                 color = market.LABEL_COLOR, scale = 1.6, alignment = "center",
                                 vertical_alignment = "middle"})
  p.chart = rendering.draw_text({text = "", surface = surface, target = {p.position.x, p.position.y - 12},
                                 color = market.LABEL_COLOR, scale = 16, alignment = "center",
                                 vertical_alignment = "middle", render_mode = "chart"})
  set_label(p)
  util.log("market: port #%d placed at %s (%s), %d stockpiles, stock [%s]", un, util.pos_str(p.position),
    region and region.label or "no region", #port_stockpiles(p), table.concat(stock, ", "))
  return p
end
world.place_port = market.place_port -- Phase 5 M2: world.lua places port sites through this hook

local function alert(force_name, kind, text, params, position)
  if force_name and match.is_participant(force_name) then supply.alert(force_name, kind, text, params, position) end
end

--- Hand a port (the whole composite) to `force_name` (nil = rts-neutral). Returns true when it changed hands.
function market.set_owner(port_un, force_name)
  local S = M()
  local p = S and market.port(port_un)
  if not p then return false end
  local old = p.owner
  if old == force_name then return false end
  local target = force_name or market.NEUTRAL
  if not force_name then neutral_force() end
  for _, e in ipairs(port_entities(p)) do
    e.force = target
    e.destructible = false
    local rec = e.unit_number and storage.buildings[e.unit_number]
    if rec then rec.force = target end
  end
  logistics.change_owner(port_un, target)
  p.owner, p.capturing, p.progress, p.last, p.captured_at = force_name, nil, 0, nil, game.tick
  set_label(p)
  -- the old owner's haulers that serve this port go home
  if old then
    for hun, h in logistics.haulers_of(old) do
      if h.pickup == port_un or h.dropoff == port_un or h.home == port_un then logistics.return_home(hun) end
    end
  end
  util.log("market: port #%d (%s) captured by %s (from %s) at tick %d", port_un, util.pos_str(p.position),
    tostring(force_name or market.NEUTRAL), tostring(old or market.NEUTRAL), game.tick)
  if force_name then alert(force_name, "port-captured", "rts-treasury.alert-port-captured", {p.name}, p.position) end
  if old then alert(old, "port-lost", "rts-treasury.alert-port-lost", {p.name, label_of(force_name)}, p.position) end
  events.emit("rts_port_captured", {port = port_un, force = force_name, previous = old})
  return true
end

-- Capture (like mapgen's ruin): see the header.
local function present_forces(p)
  local present, any = {}, false
  local participant = {}
  for _, f in ipairs(match.forces()) do participant[f] = true end
  for _, e in pairs(p.entity.surface.find_entities_filtered({position = p.position, radius = market.CAPTURE_RADIUS,
                                                             type = market.UNIT_TYPES})) do
    local f = e.force.name
    if participant[f] and e.unit_number then
      local rec = units.get(e.unit_number)
      if rec and rec.kind ~= "hauler" then
        present[f] = true
        any = true
      end
    end
  end
  return present, any
end

local function capture_one(p)
  local present, any = present_forces(p)
  if not any then
    if p.capturing then
      p.capturing, p.progress, p.last = nil, 0, nil
      set_label(p)
    end
    return
  end
  local challengers = {}
  for f in pairs(present) do
    if f ~= p.owner then challengers[#challengers + 1] = f end
  end
  if #challengers ~= 1 or (p.owner and present[p.owner]) then -- contested or defended: hold
    p.last = nil
    return
  end
  local f = challengers[1]
  -- an owned port changes hands only between nations at war (scripts/diplomacy.lua; a neutral port is open to all)
  local diplomacy = p.owner and loaded("scripts.diplomacy")
  if diplomacy and diplomacy.hostile and not diplomacy.hostile(f, p.owner) then
    p.last = nil
    return
  end
  local now = game.tick
  if p.capturing ~= f then p.capturing, p.progress, p.last = f, 0, nil end
  -- presence counts from the first step that saw it: capture.ticks of it takes the port (10.0-10.5 s after arrival)
  if p.last then p.progress = p.progress + (now - p.last) end
  p.last = now
  if p.progress >= MB.capture.ticks then
    market.set_owner(p.un, f)
  else
    set_label(p)
  end
end

function market.capture_step(dt)
  local S = storage.market
  if not (S and S.ports and next(S.ports) and nation()) then return end
  local m = storage.match
  if m.phase ~= "running" then return end
  for un, p in pairs(S.ports) do
    if p.entity.valid then capture_one(p) else S.ports[un] = nil end
  end
end

events.on_nth_tick(MB.capture.period, function() market.capture_step(MB.capture.period) end)

-- Trade posts and their stockpiles are world sites: never demolished.
buildings.on_demolish_check(function(rec)
  local e = rec.entity
  if not e.valid then return nil end
  if e.name == market.POST then return "protected" end
  local S = storage.market
  if S and S.parts and e.unit_number and S.parts[e.unit_number] then return "protected" end
  return nil
end)

-- A held trade post adds no supply (supply.lua counts every hub; the post is one).
supply.on_cap(function(force_name)
  if not nation() then return 0 end
  local S = storage.market
  if not (S and S.ports) then return 0 end
  local n = 0
  for _, p in pairs(S.ports) do
    if p.owner == force_name and p.entity.valid then n = n + 1 end
  end
  return -n * supply.HUB_CAP
end)

---------------------------------------------------------------------------
-- Commerce cap and volume
---------------------------------------------------------------------------
local function commerce_level(force_name)
  local n = 0
  if research and research.has then
    for _, t in ipairs(MB.commerce) do
      if research.has(force_name, t.name) then n = n + 1 end
    end
  end
  return n
end
market.commerce_level = commerce_level

--- Tests and the console only: a fixed cap for a force (nil = the rule).
function market.set_cap_override(force_name, cr)
  local S = M()
  if not S then return end
  S.cap_override = S.cap_override or {}
  S.cap_override[force_name] = cr
end

function market.cap(force_name)
  local S = storage.market
  local o = S and S.cap_override and S.cap_override[force_name]
  if o then return o end
  local n = #market.ports(force_name)
  return (MB.cap.base + MB.cap.per_port * n) * (1 + MB.cap.per_level * commerce_level(force_name))
end

function market.cap_used(force_name)
  local S = M()
  if not S then return 0 end
  local list = S.trades[force_name]
  if not list then return 0 end
  local cut = game.tick - MB.cap.window
  while list[1] and list[1].tick <= cut do table.remove(list, 1) end
  local used = 0
  for _, t in ipairs(list) do used = used + t.cr end
  return used
end

local function vol(S, force_name)
  local v = S.volume[force_name]
  if not v then
    v = {sold = 0, bought = 0, contract_sold = 0, contract_bought = 0, total = 0, sales = 0, purchases = 0,
         first_tick = nil}
    S.volume[force_name] = v
  end
  return v
end

local function record_trade(S, force_name, cr, field)
  S.trades[force_name] = S.trades[force_name] or {}
  if field == "sold" or field == "bought" then
    table.insert(S.trades[force_name], {tick = game.tick, cr = cr})
  end
  local v = vol(S, force_name)
  v[field] = v[field] + cr
  v.total = v.total + cr
  if field == "sold" then v.sales = v.sales + 1 elseif field == "bought" then v.purchases = v.purchases + 1 end
  v.first_tick = v.first_tick or game.tick
end

function market.volume(force_name)
  local S = M()
  if not S then return {sold = 0, bought = 0, contract_sold = 0, contract_bought = 0, total = 0, sales = 0, purchases = 0} end
  return vol(S, force_name)
end

---------------------------------------------------------------------------
-- Sell and buy
---------------------------------------------------------------------------
-- Largest n in [0, max_n] whose value(n) <= limit (value is increasing in n).
local function fit(max_n, limit, value)
  if max_n <= 0 or limit <= 0 then return 0 end
  if value(max_n) <= limit then return max_n end
  local lo, hi = 0, max_n
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if value(mid) <= limit then lo = mid else hi = mid end
  end
  return lo
end

local function owned_port(S, force_name, port_un)
  local p = market.port(port_un)
  if p and p.owner == force_name then return p end
  return nil
end

--- Sell up to n of item at an own port. Returns cr earned (0 when nothing was sold) and the reason when 0.
function market.sell(force_name, port_un, item, n)
  local S = M()
  if not S then return 0, "inactive" end
  local p = owned_port(S, force_name, port_un)
  if not p then return 0, "no-port" end
  local p0 = S.p0[item]
  if not p0 then return 0, "item" end
  n = math.floor(n or 0)
  local have = port_count(p, item)
  n = math.min(n, have)
  if n <= 0 then return 0, "none" end
  local s, s0 = S.stock[item], S.S0[item]
  local function value(k) return MB.sell_factor * (F(p0, s0, s + k) - F(p0, s0, s)) end
  local room = market.cap(force_name) - market.cap_used(force_name)
  local k = fit(n, room, value)
  if k <= 0 then return 0, "cap" end
  local removed = port_remove(p, item, k)
  if removed <= 0 then return 0, "none" end
  local cr = value(removed)
  local before = price_at(p0, s0, s)
  S.stock[item] = s + removed
  treasury.add(force_name, cr, "exports")
  record_trade(S, force_name, cr, "sold")
  util.log("market: %s sold %d %s at port #%d for %.1f cr (price %.3f -> %.3f, S %d -> %d)%s", force_name, removed,
    item, port_un, cr, before, price_at(p0, s0, S.stock[item]), s, S.stock[item],
    k < n and string.format(", cut from %d by the commerce cap", n) or "")
  return cr
end

--- Buy n of item at an own port. Charged now; the goods appear in the port's network after import_delay.
--- Returns true, cr or false, reason ("inactive", "no-port", "item", "deficit", "funds", "cap", "stock").
function market.buy(force_name, port_un, item, n)
  local S = M()
  if not S then return false, "inactive" end
  local p = owned_port(S, force_name, port_un)
  if not p then return false, "no-port" end
  local p0 = S.p0[item]
  if not p0 then return false, "item" end
  if treasury.stage(force_name) >= 1 then return false, "deficit" end
  n = math.floor(n or 0)
  if n <= 0 then return false, "none" end
  local s, s0 = S.stock[item], S.S0[item]
  n = math.min(n, math.floor(s) - 1)
  if n <= 0 then return false, "stock" end
  local function cost(k) return MB.buy_factor * (F(p0, s0, s) - F(p0, s0, s - k)) end
  local room = market.cap(force_name) - market.cap_used(force_name)
  local k = fit(n, room, cost)
  if k <= 0 then return false, "cap" end
  local bal = treasury.balance(force_name)
  k = fit(k, bal, cost)
  if k <= 0 then return false, "funds" end
  local cr = cost(k)
  if not treasury.charge(force_name, cr, "imports") then return false, "funds" end
  local before = price_at(p0, s0, s)
  S.stock[item] = s - k
  record_trade(S, force_name, cr, "bought")
  local id = S.next_id
  S.next_id = id + 1
  S.pending[#S.pending + 1] = {id = id, due = game.tick + MB.import_delay, force = force_name, port = port_un,
                               item = item, n = k, total = k, cost = cr, bought = game.tick}
  util.log("market: %s bought %d %s at port #%d for %.1f cr (price %.3f -> %.3f, S %d -> %d), import #%d due at tick %d%s",
    force_name, k, item, port_un, cr, before, price_at(p0, s0, S.stock[item]), s, S.stock[item], id,
    game.tick + MB.import_delay, k < n and string.format(", cut from %d", n) or "")
  return true, cr
end

--- Imports (purchases and contract deliveries) that have not arrived yet: {import, ...}.
function market.pending(force_name)
  local S = M()
  local out = {}
  for _, imp in ipairs(S and S.pending or {}) do
    if not force_name or imp.force == force_name then out[#out + 1] = imp end
  end
  return out
end

-- Arrivals: due imports go into their port's stockpiles; a port lost meanwhile sends them to another own port, else
-- they are refunded at the price paid.
local function arrivals()
  local S = storage.market
  if not (S and S.pending and #S.pending > 0 and nation()) then return end
  local now = game.tick
  local keep = {}
  for _, imp in ipairs(S.pending) do
    if imp.due > now then
      keep[#keep + 1] = imp
    else
      local p = owned_port(S, imp.force, imp.port)
      if not p then
        local other = market.ports(imp.force)[1]
        if other then
          util.log("market: import #%d of %s redirected from port #%d (lost) to port #%d", imp.id, imp.force, imp.port,
            other)
          imp.port = other
          keep[#keep + 1] = imp
        else
          local refund = imp.cost * imp.n / math.max(1, imp.total)
          if refund > 0 then treasury.add(imp.force, refund, "refund") end
          util.log("market: import #%d of %s (%d %s) lost with its port: %.1f cr refunded", imp.id, imp.force, imp.n,
            imp.item, refund)
          alert(imp.force, "import-lost", "rts-treasury.alert-import-lost", {imp.n, "[item=" .. imp.item .. "]"}, nil)
        end
      else
        local put = port_insert(p, imp.item, imp.n)
        if put > 0 then
          util.log("market: import #%d: %d %s arrived at port #%d for %s, %.1f s after the %s", imp.id, put, imp.item,
            imp.port, imp.force, (now - imp.bought) / 60, imp.contract and ("contract #" .. imp.contract) or "purchase")
          if imp.n == imp.total then
            alert(imp.force, "import-arrived", "rts-treasury.alert-import-arrived",
              {put, "[item=" .. imp.item .. "]", p.name}, p.position)
          end
        end
        imp.n = imp.n - put
        if imp.n > 0 then
          if not imp.full_logged then
            imp.full_logged = true
            util.log("market: import #%d: port #%d is full, %d %s wait", imp.id, imp.port, imp.n, imp.item)
          end
          imp.due = now + 60
          keep[#keep + 1] = imp
        end
      end
    end
  end
  S.pending = keep
end

events.on_nth_tick(market.PENDING_PERIOD, arrivals)

---------------------------------------------------------------------------
-- Contracts
---------------------------------------------------------------------------
local function fire(kind, c, extra)
  local ev = {kind = kind, id = c.id, seller = c.seller, buyer = c.buyer, item = c.item, n = c.n,
              delivery = c.done + c.missed, deliveries = c.deliveries, price = c.price, contract = c}
  for k, v in pairs(extra or {}) do ev[k] = v end
  util.log("market: contract #%d %s (%s -> %s, %d %s at %.2f, delivery %d/%d%s)", c.id, kind, c.seller, c.buyer, c.n,
    c.item, c.price, ev.delivery, c.deliveries, ev.fault and (", fault: " .. ev.fault) or "")
  for i = 1, #contract_hooks do contract_hooks[i](ev) end
  events.emit("rts_contract_event", ev)
end

--- A fixed-price scheduled sale (see the header). interval in seconds. Returns the contract id, or nil and a reason.
function market.contract(seller, buyer, item, n_per, deliveries, interval, price)
  local S = M()
  if not S then return nil, "inactive" end
  if not (seller and buyer and seller ~= buyer and match.is_participant(seller) and match.is_participant(buyer)) then
    return nil, "forces"
  end
  if not S.p0[item] then return nil, "item" end
  n_per, deliveries, interval, price = math.floor(tonumber(n_per) or 0), math.floor(tonumber(deliveries) or 0),
    tonumber(interval) or 0, tonumber(price) or -1
  if n_per <= 0 or deliveries <= 0 or deliveries > MB.contract.max_deliveries then return nil, "terms" end
  if interval < MB.contract.min_interval or price < 0 then return nil, "terms" end
  local id = S.next_id
  S.next_id = id + 1
  local c = {id = id, seller = seller, buyer = buyer, item = item, n = n_per, deliveries = deliveries,
             interval = math.floor(interval * 60), price = price, done = 0, missed = 0, value = 0,
             created = game.tick, next_due = game.tick + math.floor(interval * 60), state = "active"}
  S.contracts[id] = c
  fire("created", c)
  return id
end

function market.cancel_contract(id, why)
  local S = M()
  local c = S and S.contracts[id]
  if not (c and c.state == "active") then return false end
  c.state = "cancelled"
  fire("cancelled", c, {why = why})
  return true
end

function market.contracts(force_name)
  local S = M()
  local out = {}
  for _, c in pairs(S and S.contracts or {}) do
    if not force_name or c.seller == force_name or c.buyer == force_name then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

local function finish_slot(c)
  if c.done + c.missed >= c.deliveries then
    c.state = (c.done > 0) and "completed" or "failed"
    fire("completed", c)
  end
end

local function settle(S, c, now)
  local seller_port
  for _, un in ipairs(market.ports(c.seller)) do
    local p = S.ports[un]
    if port_count(p, c.item) >= c.n then seller_port = p break end
  end
  local buyer_port = market.ports(c.buyer)[1]
  local fault
  if not seller_port then fault = "seller" elseif not buyer_port then fault = "buyer" end
  local value = c.n * c.price
  if not fault and not treasury.charge(c.buyer, value, "contract-buy") then fault = "buyer" end
  if fault then
    if not c.late_since then
      c.late_since = c.next_due
      fire("late", c, {fault = fault})
    elseif now - c.late_since >= MB.contract.late_grace then
      c.missed = c.missed + 1
      c.late_since = nil
      c.next_due = c.next_due + c.interval
      fire("missed", c, {fault = fault})
      finish_slot(c)
    end
    return
  end
  local removed = port_remove(seller_port, c.item, c.n)
  if removed < c.n then -- never expected (counted above); pay back the shortfall
    treasury.add(c.buyer, (c.n - removed) * c.price, "refund")
    value = removed * c.price
  end
  treasury.add(c.seller, value, "contract-sale")
  record_trade(S, c.seller, value, "contract_sold")
  record_trade(S, c.buyer, value, "contract_bought")
  local id = S.next_id
  S.next_id = id + 1
  S.pending[#S.pending + 1] = {id = id, due = now + MB.import_delay, force = c.buyer, port = buyer_port,
                               item = c.item, n = removed, total = removed, cost = value, bought = now,
                               contract = c.id}
  c.done = c.done + 1
  c.value = c.value + value
  c.late_since = nil
  c.next_due = c.next_due + c.interval
  fire("delivered", c, {value = value, from_port = seller_port.un, to_port = buyer_port, import = id})
  finish_slot(c)
end

events.on_nth_tick(market.CONTRACT_PERIOD, function()
  local S = storage.market
  if not (S and S.contracts and next(S.contracts) and nation()) then return end
  local now = game.tick
  for _, c in pairs(S.contracts) do
    if c.state == "active" and now >= c.next_due then settle(S, c, now) end
  end
end)

---------------------------------------------------------------------------
-- Drift and history (every drift_period)
---------------------------------------------------------------------------
function market.drift_step()
  local S = M()
  if not S then return end
  for _, item in ipairs(S.items) do
    local s, s0 = S.stock[item], S.S0[item]
    S.stock[item] = s + MB.drift * (s0 - s)
    local h = S.history[item]
    h[#h + 1] = price_at(S.p0[item], s0, S.stock[item])
    while #h > MB.history do table.remove(h, 1) end
  end
end

events.on_nth_tick(MB.drift_period, function(e)
  if not nation() then return end
  local m = storage.match
  if m.phase ~= "running" then return end
  local S = M()
  market.drift_step()
  S.next_drift = e.tick + MB.drift_period
  -- QA minute line per force
  local minute = m.tick_started and math.floor((e.tick - m.tick_started) / 3600 + 0.5) or 0
  for _, f in ipairs(match.forces()) do
    local v = vol(S, f)
    util.log("market: minute %d %s: ports [%s], cap %.0f/%.0f, volume %.0f (sold %.0f in %d, bought %.0f in %d, "
      .. "contracts %.0f/%.0f)", minute, f, table.concat(market.ports(f), " "), market.cap_used(f), market.cap(f),
      v.total, v.sold, v.sales, v.bought, v.purchases, v.contract_sold, v.contract_bought)
  end
  local parts = {}
  for _, item in ipairs({"iron-plate", "copper-plate", "steel-plate", "stone", "coal", "electronic-circuit"}) do
    if S.p0[item] then parts[#parts + 1] = string.format("%s %.2f", item, market.price(item)) end
  end
  util.log("market: minute %d prices: %s", minute, table.concat(parts, ", "))
end)

---------------------------------------------------------------------------
-- Normal AI (docs/PHASE5-M2.md §3: sell surplus at its ports, buy shortfalls it cannot fill in 3 minutes, taxes)
---------------------------------------------------------------------------
local function ai_state(S, force_name)
  local A = S.ai[force_name]
  if not A then
    A = {next = 0, short = {}, keeps = {}, imports = {}, cc_exports = {}, setup = {}, envoys = 0, captures = 0}
    S.ai[force_name] = A
  end
  return A
end

local function capital_city(force_name)
  local nat = storage.nations and storage.nations[force_name]
  local id = nat and nat.capital
  return id and storage.cities and storage.cities[id] or nil
end

local function capital_hub(force_name)
  local city = capital_city(force_name)
  if city and city.center and logistics.hub_rec(city.center) then return city.center end
  local cc, un = buildings.main_cc(force_name)
  return cc and un or nil
end

local function at_war(C)
  local wars = loaded("scripts.wars")
  if wars and type(wars.active) == "function" then
    local ok, list = pcall(wars.active, C.force)
    if ok and type(list) == "table" then return next(list) ~= nil end
  end
  local a = C.army
  if not a then return false end
  for _, G in pairs(a.groups or {}) do
    if G.state == "attack" or G.state == "defend" then return true end
  end
  if a.threat and game.tick - (a.threat.tick or 0) <= AI.war_window then return true end
  return false
end

-- Phase 5 M2 integration: the AI's deficit with hysteresis (see balance.nation.market.ai.deficit_band)
local function in_deficit(A, t)
  local H = AI.hysteresis -- Phase 5 M3 age3: enter below `enter` while losing money, leave only at `leave`
  if H then
    if A.deficit_flag then
      if t.balance >= H.leave then A.deficit_flag = nil end
    elseif t.balance < H.enter and t.net < 0 then
      A.deficit_flag = true
    end
    return A.deficit_flag == true
  end
  if A.deficit_flag then
    if t.balance >= AI.deficit_floor + (AI.deficit_band or 0) or t.net > (AI.deficit_net or 0) then A.deficit_flag = nil end
  elseif t.balance < AI.deficit_floor and t.net < 0 then
    A.deficit_flag = true
  end
  return A.deficit_flag == true
end

-- Phase 5 M3 age3 (D10, docs/qa/phase5-ai-notes.md §6 item 3): tax with a hysteresis band. Low below happy_low until
-- happiness is happy_band above it; high at war (and on a war footing for war_footing ticks after the last war) or in
-- deficit, and after either until the balance is back at `leave`; a war start and a happiness drop switch at once,
-- every other change waits tax_hold after the last one.
local function ai_taxes_banded(C, A, H)
  local t = treasury.get(C.force)
  local cur = treasury.tax_of(C.force)
  local happy = t.happiness or 70
  local now_war = at_war(C)
  if now_war then A.war_until = game.tick + (H.war_footing or 0) end
  local war = A.war_until ~= nil and game.tick <= A.war_until
  local deficit = in_deficit(A, t)
  local level, why, urgent
  -- Phase 5 M3 integration (balance pass): in debt an unhappy nation keeps the normal tax; low tax in debt deepened
  -- it until the credit line (4-nation runs: unrest -25 happiness -> low tax -> a third of the income)
  local in_debt = treasury.stage(C.force) >= 1
  if happy < AI.happy_low or (cur == "low" and happy < AI.happy_low + H.happy_band) then
    level, why = in_debt and "normal" or "low", string.format("happiness %.0f%s", happy, in_debt and ", in debt" or "")
    urgent = happy < AI.happy_low and cur ~= "low" and not in_debt
  elseif war or deficit then
    level, why = "high", war and (now_war and "at war" or "war footing")
      or string.format("balance %.0f, net %.0f/min", t.balance, t.net)
    urgent = war and not A.tax_war
  elseif cur == "high" and t.balance < H.leave then
    level, why = "high", string.format("balance %.0f below %.0f", t.balance, H.leave)
  else
    level, why = "normal", "default"
  end
  A.tax_war = war or nil
  if level == cur then return end
  if not urgent and A.tax_tick and game.tick - A.tax_tick < H.tax_hold then return end
  -- Phase 5 M3 integration: at most max_per_hour switches in any hour (the contract's <= 2 per nation-hour; 4 of ten
  -- 4-nation runs had a nation at 3: high, back to normal when the money was in, high again at the next war or
  -- deficit); only unrest (happiness below happy_low) and debt pass the cap
  if H.max_per_hour then
    local kept = {}
    for _, t0 in ipairs(A.tax_ticks or {}) do
      if game.tick - t0 < 60 * 60 * 60 then kept[#kept + 1] = t0 end
    end
    A.tax_ticks = kept
    if #kept >= H.max_per_hour and not (happy < AI.happy_low or in_debt) then return end
    kept[#kept + 1] = game.tick
  end
  A.tax_tick = game.tick
  A.tax_switches = (A.tax_switches or 0) + 1
  util.log("market: AI %s sets tax %s (%s; switch %d)", C.force, level, why, A.tax_switches)
  treasury.set_tax(C.force, level)
end

local function ai_taxes(C, A)
  if AI.hysteresis then return ai_taxes_banded(C, A, AI.hysteresis) end -- Phase 5 M3 age3
  local t = treasury.get(C.force)
  local level, why, urgent = "normal", "default", false
  local war = at_war(C)
  if (t.happiness or 70) < AI.happy_low then
    level, why, urgent = "low", string.format("happiness %.0f", t.happiness), true
  elseif war then
    level, why = "high", "at war"
  elseif in_deficit(A, t) then
    level, why = "high", string.format("balance %.0f, net %.0f/min", t.balance, t.net)
  end
  -- Phase 5 M2 integration: a level holds tax_hold unless a war starts or ends or happiness is low
  if war ~= (A.tax_war == true) then urgent = true end
  A.tax_war = war or nil
  if level ~= treasury.tax_of(C.force) then
    if not urgent and A.tax_tick and game.tick - A.tax_tick < (AI.tax_hold or 0) then return end
    A.tax_tick = game.tick
    util.log("market: AI %s sets tax %s (%s)", C.force, level, why)
    treasury.set_tax(C.force, level)
  end
end

local function release_envoy(A, why)
  local E = A.envoy
  A.envoy = nil
  local rec = E and units.get(E.un)
  if rec then why = string.format("%s, at %s", why, util.pos_str(rec.entity.position)) end
  if rec and rec.issuer == market.ISSUER then
    rec.order, rec.issuer = units.IDLE, nil
    units.stop(rec.entity)
  end
  if E then util.log("market: AI envoy #%d released (%s)", E.un, why) end
end

local ENVOY_RANK = {raider = 0, drone = 1, walker = 2}
market.ENVOY_RETRIES = 3 -- failed paths re-issued before the envoy is released

local function send_envoy(e, target, home_pos)
  local dir_x, dir_y = home_pos.x - target.position.x, home_pos.y - target.position.y
  local len = math.max(1, math.sqrt(dir_x * dir_x + dir_y * dir_y))
  local dest = {x = target.position.x + 5 * dir_x / len, y = target.position.y + 5 * dir_y / len}
  dest = e.surface.find_non_colliding_position(e.name, dest, 6, 0.5) or dest
  orders.queue_command(e, {type = defines.command.go_to_location, destination = dest, radius = 2,
                           distraction = defines.distraction.none})
end

local function ai_envoy(C, A, S)
  local f = C.force
  local E = A.envoy
  if E then
    local rec = units.get(E.un)
    local p = S.ports[E.port]
    if not rec then
      release_envoy(A, "lost")
    elseif not p or not p.entity.valid then
      release_envoy(A, "port gone")
    elseif p.owner == f then
      A.captures = A.captures + 1
      release_envoy(A, string.format("port #%d taken in %.0f s", E.port, (game.tick - E.tick) / 60))
    elseif p.owner then
      release_envoy(A, string.format("port #%d went to %s first", E.port, p.owner))
    elseif game.tick - E.tick > AI.capture_timeout then
      release_envoy(A, "timeout")
    elseif (E.failed or 0) > (E.resent or 0) then
      if E.failed > market.ENVOY_RETRIES then
        release_envoy(A, "no path")
      else
        E.resent = E.failed
        local hrec = buildings.get(capital_hub(f) or -1)
        send_envoy(rec.entity, p, hrec and hrec.position or rec.entity.position)
        util.log("market: AI %s sends envoy #%d on again (failed path %d)", f, E.un, E.failed)
        return
      end
    else
      return
    end
    A.last_envoy = game.tick
  end
  if #market.ports(f) > 0 then return end
  if game.tick - (A.last_envoy or -AI.capture_retry) < AI.capture_retry then return end
  -- every port site is placed once the world's background fill is done (world.lua); before that a far port may be
  -- the only one placed
  local m = storage.match
  if not (world.ready and world.ready()) and game.tick - (m.tick_started or 0) < AI.ports_wait then return end
  local home = capital_hub(f)
  local hrec = home and buildings.get(home)
  if not hrec then return end
  -- the nearest port nobody holds and no other AI's envoy is walking to
  local taken = {}
  for other, OA in pairs(S.ai) do
    if other ~= f and OA.envoy then taken[OA.envoy.port] = true end
  end
  local target, td
  for un, p in pairs(S.ports) do
    if p.entity.valid and not p.owner and not taken[un] then
      local d = util.distance(p.position, hrec.position)
      if not td or d < td then target, td = p, d end
    end
  end
  if not target then return end
  -- an idle army unit outside every group, fastest kind first, nearest to home
  local a = C.army or {}
  local member = a.member or {}
  local best, bk, bd
  for un, rec in units.for_force(f) do
    local rank = ENVOY_RANK[rec.kind]
    if rank and not member[un] and rec.order == units.IDLE and not (A.tried and A.tried[un]) then
      local d = util.distance(rec.entity.position, hrec.position)
      if not bk or rank < bk or (rank == bk and d < bd) then best, bk, bd = rec, rank, d end
    end
  end
  if not best then return end
  local e = best.entity
  A.tried = A.tried or {}
  A.tried[e.unit_number] = true -- a unit that did not make it is not sent again
  best.order, best.issuer = market.ENVOY_ORDER, market.ISSUER
  send_envoy(e, target, hrec.position)
  A.envoy = {un = e.unit_number, port = target.un, tick = game.tick}
  A.envoys = A.envoys + 1
  util.log("market: AI %s sends %s #%d to port #%d at %s (%.0f tiles)", f, best.kind, e.unit_number, target.un,
    util.pos_str(target.position), td)
end

-- The envoy's command ended: stand still when it arrived (the claim stays until the capture or the timeout).
events.on(defines.events.on_ai_command_completed, function(e)
  local rec = storage.units and storage.units[e.unit_number]
  if not (rec and rec.issuer == market.ISSUER and rec.entity.valid) then return end
  util.log("market: envoy #%d command %s at %s", e.unit_number, util.define_name(defines.behavior_result, e.result),
    util.pos_str(rec.entity.position))
  units.stop(rec.entity)
  if e.result ~= defines.behavior_result.success then
    -- a failed path (long paths fail now and then): the next AI pass sends it on again (ai_envoy)
    local S = storage.market
    for _, A in pairs(S and S.ai or {}) do
      if A.envoy and A.envoy.un == e.unit_number then A.envoy.failed = (A.envoy.failed or 0) + 1 end
    end
  end
end)

local function cc_has_export(pol, item)
  return pol.export_above[item] ~= nil
end

local function ai_route(C, A, S, port_un)
  local f = C.force
  local home = capital_hub(f)
  if not home then return end
  local key = port_un .. "@" .. home
  if A.setup[port_un] ~= key then
    local hp = logistics.policy(home)
    for item, thr in pairs(AI.surplus) do
      if prototypes.item[item] and S.p0[item] then
        if hp and not cc_has_export(hp, item) then
          logistics.set_policy(home, "export_above", item, thr)
          A.cc_exports[item] = thr
        end
        logistics.set_policy(port_un, "keep", item, AI.port_keep)
      end
    end
    logistics.set_policy(port_un, "keep", "coal", math.max(AI.coal_keep, AI.port_keep))
    A.setup[port_un] = key
    A.deficit_mode = nil
    util.log("market: AI %s routes surplus from #%d to port #%d (keep %d each, coal reserve %d)", f, home, port_un,
      AI.port_keep, AI.coal_keep)
  end
  -- in deficit (balance below deficit_floor and losing money) the capital exports from lower thresholds
  local t = treasury.get(f)
  local deficit = in_deficit(A, t) -- Phase 5 M2 integration: with hysteresis
  if deficit ~= (A.deficit_mode == true) then
    A.deficit_mode = deficit
    local share = deficit and AI.deficit_surplus or 1
    for item, thr in pairs(A.cc_exports) do
      logistics.set_policy(home, "export_above", item, math.floor(thr * share))
    end
    util.log("market: AI %s %s deficit mode: capital exports from %d %% of the surplus thresholds", f,
      deficit and "enters" or "leaves", math.floor(share * 100))
  end
  -- one hauler on a manual route home -> port
  local h = A.hauler and logistics.hauler(A.hauler)
  if h and h.mode == "manual" and h.dropoff == port_un then return end
  A.hauler = nil
  -- only a spare hauler: every hauler the force wants (its hubs' plus this route's, market.ai_step) is out
  local pick, n = nil, 0
  for un, hh in logistics.haulers_of(f) do
    n = n + 1
    if hh.mode == "auto" and (not pick or un < pick) then pick = un end
  end
  if not pick or n < (C.want_haulers or 0) then return end
  logistics.set_pickup(pick, home)
  logistics.set_dropoff(pick, port_un)
  A.hauler = pick
  A.route_port = port_un
  util.log("market: AI %s hauler #%d on the route #%d -> port #%d", f, pick, home, port_un)
end

local function by_value(S)
  return function(a, b)
    local pa, pb = S.p0[a] or 0, S.p0[b] or 0
    if pa ~= pb then return pa > pb end
    return a < b
  end
end

local function ai_sell(C, A, S, ports)
  local f = C.force
  for _, un in ipairs(ports) do
    local contents = market.port_contents(un)
    local items = {}
    for item in pairs(contents) do
      if S.p0[item] and not A.imports[item] then items[#items + 1] = item end
    end
    table.sort(items, by_value(S))
    for _, item in ipairs(items) do
      local n = contents[item] - (item == "coal" and AI.coal_keep or 0)
      if n > 0 then
        local cr, why = market.sell(f, un, item, n)
        if cr <= 0 and why == "cap" then return end
      end
    end
  end
end

local function raise_keep(A, home, item, want)
  local hp = logistics.policy(home)
  if not hp then return end
  local cur = hp.keep[item]
  if not A.keeps[item] then A.keeps[item] = {prev = cur} end
  A.keeps[item].till = game.tick + AI.keep_minutes * 3600
  if not cur or cur < want then logistics.set_policy(home, "keep", item, want) end
end

-- The capital's ledger rows (scripts/districts.lua), or nil.
local function capital_rows(force_name)
  local districts = loaded("scripts.districts")
  local city = capital_city(force_name)
  if not (districts and city and type(districts.ledger) == "function") then return nil end
  local ok, rows = pcall(districts.ledger, city.id)
  if not ok or type(rows) ~= "table" then return nil end
  return rows
end

local function home_count(home, item)
  local net = logistics.hub_network(home)
  return net and net.get_item_count(item) or 0
end

local function ai_buy(C, A, S, port_un, rows)
  local f = C.force
  if not rows or treasury.stage(f) > 0 then return end
  local t = treasury.get(f)
  -- no imports while losing money below the deficit floor (the 60-minute run bought 1,000 cr on a falling treasury)
  if t.net < 0 and t.balance < AI.deficit_floor then return end
  local budget = math.min(t.balance - AI.reserve, t.balance * AI.spend_share)
  local home = capital_hub(f)
  local now = game.tick
  local seen = {}
  for _, row in ipairs(rows) do
    if row.target and row.short > 0 and (row.made == 0 or row.short > row.made * AI.buy_horizon)
       and not (row.hint and row.hint.city)
       -- Phase 5 M3 ai (H5, applied by m3-integ): plates and ores the nation makes are never bought (balance no_buy)
       and not (AI.no_buy and AI.no_buy[(row.hint and row.hint.item) or row.item]) then
      local item = (row.hint and row.hint.item) or row.item
      seen[item] = true
      A.short[item] = A.short[item] or now
      if S.p0[item] and now - A.short[item] >= AI.buy_after and budget > 0 and home then
        local n = row.short
        local price = market.quote(item, 1, "buy") or 1e9
        n = math.min(n, math.floor(budget / price))
        if n > 0 then
          local done, cr = market.buy(f, port_un, item, n)
          if done then
            budget = budget - cr
            A.imports[item] = now
            logistics.set_policy(port_un, "keep", item, nil)
            logistics.set_policy(port_un, "export_above", item, 0)
            raise_keep(A, home, item, home_count(home, item) + n)
            util.log("market: AI %s imports %d %s for %s (short %d, made %d/min, short for %.0f s)", f, n, item,
              row.item, row.short, row.made, (now - A.short[item]) / 60)
          end
          A.short[item] = now -- another purchase only after buy_after more
        end
      end
    end
  end
  for item in pairs(A.short) do
    if not seen[item] then A.short[item] = nil end
  end
end

-- Goods at the port the capital is short of are hauled home instead of sold (the loot, a late import).
local function ai_wanted(C, A, S, port_un, rows)
  local home = capital_hub(C.force)
  if not (rows and home) then return end
  -- Phase 5 M3 integration: only while a hauler serves the route (else the goods wait for one at the port and the
  -- strategist's sale of a captured port's loot came too late: the player slot sold its 100 circuits in 6 of 20 runs,
  -- rts-ai-1 in 20 of 20, ai/nation.lua staggers the AIs in force-name order)
  local h = A.hauler and logistics.hauler(A.hauler)
  if not (h and h.mode == "manual" and h.dropoff == port_un) then return end
  local contents = market.port_contents(port_un)
  for _, row in ipairs(rows) do
    local item = row.item
    if row.target and row.short > 0 and (contents[item] or 0) > 0 and not A.imports[item] then
      A.imports[item] = game.tick
      logistics.set_policy(port_un, "keep", item, nil)
      logistics.set_policy(port_un, "export_above", item, 0)
      raise_keep(A, home, item, home_count(home, item) + math.min(row.short, contents[item]))
      util.log("market: AI %s hauls %d %s home from port #%d (short %d)", C.force, contents[item], item, port_un,
        row.short)
    end
  end
end

local function ai_restore(C, A, S, port_un)
  local home = capital_hub(C.force)
  local now = game.tick
  for item, k in pairs(A.keeps) do
    if now >= (k.till or 0) then
      if home then logistics.set_policy(home, "keep", item, k.prev) end
      A.keeps[item] = nil
      A.imports[item] = nil
      if port_un then
        logistics.set_policy(port_un, "export_above", item, nil)
        if AI.surplus[item] then logistics.set_policy(port_un, "keep", item, AI.port_keep) end
      end
    end
  end
end

-- Parts of the AI pass; scripts/ai/nation.lua or ai/governor.lua (m2-ai, wave B) may switch a part off and call the
-- function itself (market.ai_taxes / ai_envoy / ai_route / ai_sell / ai_buy below take (C)).
market.AI = {taxes = true, envoy = true, route = true, sell = true, buy = true}

--- AI commander hook (ai/commander.lua, every run). Nation mode only.
function market.ai_step(C)
  local S = M()
  if not S then return end
  local A = ai_state(S, C.force)
  -- the port route's hauler counts on top of the hubs' (ai/hubs.lua resets C.want_haulers every run), once the force
  -- wants haulers anyway or after hauler_after: an early hauler kit's circuits took the copper an AI's copper line
  -- still needed (seed 504: the line never got built)
  if A.route_port and S.ports[A.route_port] and S.ports[A.route_port].owner == C.force
     and ((C.want_haulers or 0) > 0 or game.tick - (C.started or 0) >= AI.hauler_after) then
    C.want_haulers = (C.want_haulers or 0) + 1
  end
  -- Phase 5 M3 integration: the pass runs in four slices on consecutive AI runs (taxes and envoy; route and haul home;
  -- sales; purchases and restores): in one run it cost 2.3-3.2 ms (m3-ai's 4-nation bench). The capital's ledger rows
  -- are read once a pass and kept in A.rows until the purchases.
  if not A.slice then
    if game.tick < A.next then return end
    A.next = game.tick + AI.period
    A.slice = 1
  end
  local k = A.slice
  A.slice = k < 4 and k + 1 or nil
  local m = storage.match
  if m.phase ~= "running" then
    A.slice, A.rows = nil, nil
    return
  end
  local on = market.AI
  if k == 1 then
    if on.taxes then ai_taxes(C, A) end
    if on.envoy then ai_envoy(C, A, S) end
    return
  end
  local ports = market.ports(C.force)
  if #ports == 0 then
    A.route_port = nil
    A.slice, A.rows = nil, nil
    return
  end
  local home_port = ports[1]
  if k == 2 then
    local rows = (on.route or on.buy) and capital_rows(C.force) or nil
    A.rows = rows
    if on.route then
      A.route_port = home_port -- from now on the force wants one more hauler (the port route's)
      ai_route(C, A, S, home_port)
      ai_wanted(C, A, S, home_port, rows)
    end
  elseif k == 3 then
    if on.sell then ai_sell(C, A, S, ports) end
  else
    if on.buy then ai_buy(C, A, S, home_port, A.rows) end
    A.rows = nil
    ai_restore(C, A, S, home_port)
  end
end

-- Entry points for a strategist that runs the parts itself (see market.AI).
function market.ai_taxes(C)
  local S = M()
  if S then ai_taxes(C, ai_state(S, C.force)) end
end
function market.ai_envoy(C)
  local S = M()
  if S then ai_envoy(C, ai_state(S, C.force), S) end
end
function market.ai_sell(C)
  local S = M()
  if S then ai_sell(C, ai_state(S, C.force), S, market.ports(C.force)) end
end
function market.ai_buy(C)
  local S = M()
  local port = market.ports(C.force)[1]
  if S and port then ai_buy(C, ai_state(S, C.force), S, port, capital_rows(C.force)) end
end

--- One line for the AI minute report.
function market.describe(force_name)
  local S = M()
  if not S then return "-" end
  local v = vol(S, force_name)
  local A = S.ai[force_name]
  return string.format("ports [%s] cap %.0f/%.0f volume %.0f (sold %.0f bought %.0f contracts %.0f/%.0f)%s%s",
    table.concat(market.ports(force_name), " "), market.cap_used(force_name), market.cap(force_name), v.total, v.sold,
    v.bought, v.contract_sold, v.contract_bought, A and A.envoy and (" envoy #" .. A.envoy.un) or "",
    A and A.hauler and (" hauler #" .. A.hauler) or "")
end

deps.market = market -- the AI reads it at run time (scripts/ai/deps.lua)

---------------------------------------------------------------------------
-- Console (QA)
---------------------------------------------------------------------------
commands.add_command("rts-market", "[prices | ports | sell <item> <n> | buy <item> <n> | capture <port> | contract "
  .. "<buyer> <item> <n> <deliveries> <interval s> <price>] [force=<name>] - world market (QA)", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  local words, f = {}, nil
  for w in string.gmatch(cmd.parameter or "", "%S+") do
    local ff = string.match(w, "^force=(.+)$")
    if ff then f = ff else words[#words + 1] = w end
  end
  f = f or (player and player.force.name) or util.PLAYER_FORCE
  local lines = {}
  local verb = words[1] or "ports"
  local S = M()
  if not S then
    lines[1] = "market: not a Nation match"
  elseif verb == "prices" then
    for _, item in ipairs(S.items) do
      lines[#lines + 1] = string.format("market: %s p0 %.3f price %.3f S %.0f S0 %d", item, S.p0[item],
        market.price(item), S.stock[item], S.S0[item])
    end
  elseif verb == "sell" or verb == "buy" then
    local port = market.ports(f)[1]
    local n = tonumber(words[3]) or 0
    if verb == "sell" then
      local cr, why = market.sell(f, port, words[2], n)
      lines[1] = string.format("market: sell -> %.1f cr %s", cr, tostring(why or ""))
    else
      local ok, r = market.buy(f, port, words[2], n)
      lines[1] = string.format("market: buy -> %s %s", tostring(ok), tostring(r))
    end
  elseif verb == "capture" then
    lines[1] = string.format("market: capture -> %s", tostring(market.set_owner(tonumber(words[2]) or -1, f)))
  elseif verb == "contract" then
    local id, why = market.contract(f, words[2], words[3], words[4], words[5], words[6], words[7])
    lines[1] = string.format("market: contract -> %s %s", tostring(id), tostring(why or ""))
  else
    for _, p in ipairs(market.all_ports()) do
      lines[#lines + 1] = string.format("market: port #%d at %s owner %s capturing %s (%d ticks)", p.un,
        util.pos_str(p.position), tostring(p.owner), tostring(p.capturing), p.progress or 0)
    end
    for _, ff in ipairs(match.forces()) do lines[#lines + 1] = "market: " .. ff .. ": " .. market.describe(ff) end
  end
  for _, l in ipairs(lines) do
    util.log("%s", l)
    if player then player.print(l) end
  end
end)

return market
