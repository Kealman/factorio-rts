-- Phase 4 logistics (docs/PHASE4.md 2.1-2.2): hubs, stockpile policies, haulers, alerts.
--
-- Hubs. An rts-hub is a building of kind "hub" in buildings.lua (KIND_BY_NAME is extended below). When one is
-- registered (built by robots or a player, raise_built, buildings.register), this module places the rest of the
-- composite: rts-hub-power (300 kW) and rts-hub-pole under it, two rts-stockpile next to it (HUB_STOCKPILES),
-- 10 construction + 6 logistic robots in it, and a full buffer. The parts are destroyed with the hub; the
-- stockpiles stay. Every hub and every Command Center ("the root hub") has a policy.
--
-- Policies: storage.logistics.hubs[unit_number] = {
--   kind = "hub" | "cc", force = force name, index = n (hubs: "Hub n", per force),
--   keep = {[item] = n},          import until the hub's network holds n (haulers bring the difference)
--   export_above = {[item] = n},  offer what the network holds above n to haulers
--   parts = {power, pole, stockpiles = {...}}, setup_done = true   (hubs only)
-- }
-- Defaults: a CC exports plates above 100 (DEFAULT_CC); a hub keeps 50 iron and 20 copper (DEFAULT_HUB).
-- Hubs whose roboport areas touch share one logistic network (vanilla); policies are then combined per network:
-- keep = the largest keep of its hubs, export threshold = max(largest export_above, keep). A network without any
-- export_above for an item never exports it.
--
-- Haulers: rts-hauler spider-vehicles, also registered in storage.units (kind "hauler", order "haul", issuer
-- "logistics"), so selection.lua selects them like units and orders.lua / the AI army never command them
-- (claim rule in units.lua). storage.logistics.haulers[unit_number] = {
--   entity, force, mode = "auto" | "manual",
--   home = hub un (auto: the hub it serves), pickup = hub un, dropoff = hub un (manual route),
--   state = "idle" | "to_pickup" | "to_dropoff" | "to_home" | "waiting" | "parked",
--   reason = why it waits (locale key suffix: "no-route", "nothing", "full", "no-home", "same-network"),
--   target = hub un it travels to, dest = MapPosition, plan = {[item] = n} (auto trip to a source hub),
--   plan_src = hub un, cargo = {[item] = n} (trunk contents at the last step), delivered = {[item] = n},
--   trips, created, leg = {tick, x, y} (start of the current leg, for the speed log)
-- }
-- Manual: travel to the pickup hub, load what it exports and the drop-off wants (a drop-off with no keep
-- thresholds at all takes every export), travel to the drop-off, unload into its network, repeat; waits at the
-- pickup while there is nothing to carry. Auto: serve the home hub's requests (keep) from the nearest hub of
-- another network that exports the item (nearest to home first), else wait at home. Arrival = within
-- ARRIVE_RADIUS of the hub's approach point (just below it). The state machine runs every STEP_PERIOD ticks and
-- on on_spider_command_completed. Trips in flight are reserved, so two haulers do not fetch the same surplus.
--
-- Orders (orders.on_right_click hook): with haulers selected, right click on an own hub or CC = pickup, Shift +
-- right click = drop-off (both switch to manual; switching from auto fills the missing end with the home hub),
-- right click on the ground = move there and park (route suspended until a new route order or "Resume").
-- Other units in the same selection get their normal order.
--
-- Hauler kits: when a factory finishes an rts-hauler-kit (production.lua leaves it in the factory output), the
-- DEPLOY_PERIOD sweep spawns a hauler at the factory's exit, in auto mode, home = the hub of the factory's network.
-- Kits found in a hub network (console /rts-give, saves) are deployed at that network's hub.
--
-- Alerts: storage.alerts = {{tick, force, kind, position, text}, ...} (newest last, at most MAX_ALERTS);
-- logistics.alert() appends. A hauler death logs "[rts] logistics: hauler lost ..." and adds kind "hauler-lost".
-- Stats: storage.logistics.stats[force] = {trips, delivered = {[item] = n}, lost, deployed}.
--
-- Autotest (headless, storage.debug.autotest): off unless AUTOTEST_DEFAULT is true or storage.debug.logistics_autotest
-- is set; see the end of this file. Log lines "[rts] logistics autotest ...".
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local match = require("scripts.match") -- on_teardown only (match.lua does not require this module)
local balance = require("balance") -- Phase 5 M1 (m1-rails): balance.nation hauler fuel and slots
-- Research bonuses (scripts/research.lua: hauler_slots, robots_per_hub_bonus). Optional, loaded earlier by control.lua.
local research
do
  local ok, mod = pcall(require, "scripts.research")
  if ok and type(mod) == "table" then research = mod end
end

local logistics = {}

logistics.HUB = "rts-hub"
logistics.HUB_POWER = "rts-hub-power"
logistics.HUB_POLE = "rts-hub-pole"
logistics.HAULER = "rts-hauler"
logistics.HAULER_KIT = "rts-hauler-kit"
logistics.STOCKPILE = "rts-stockpile"
logistics.KIND = "hauler"          -- storage.units kind
logistics.ORDER = "haul"           -- storage.units order (a claim: orders.lua and the AI army leave haulers alone)
logistics.ISSUER = "logistics"
-- The hub is 4x4 with its centre on a tile corner; the stockpiles sit one tile left and right of it.
logistics.HUB_STOCKPILES = {{x = -3.5, y = 0.5}, {x = 3.5, y = 0.5}}
logistics.HUB_BOTS = {["construction-robot"] = 10, ["logistic-robot"] = 6}
logistics.BONUS_BOT = "logistic-robot" -- research robots_per_hub_bonus (Logistics I) adds these to every hub
logistics.BASE_SLOTS = 20          -- cargo slots a hauler uses; research hauler_slots adds more (trunk has 40)
logistics.DEFAULT_CC = {keep = {}, export_above = {["iron-plate"] = 100, ["copper-plate"] = 100, ["steel-plate"] = 100}}
logistics.DEFAULT_HUB = {keep = {["iron-plate"] = 50, ["copper-plate"] = 20}, export_above = {}}
logistics.STEP_PERIOD = 30         -- ticks between hauler state-machine steps
logistics.DEPLOY_PERIOD = 60       -- ticks between hauler-kit sweeps
logistics.CACHE_TICKS = 30         -- network cache lifetime
logistics.ARRIVE_RADIUS = 4        -- tiles from the approach point that count as arrived
logistics.APPROACH_GAP = 2.5       -- tiles between a hub's selection box and its approach point
logistics.STUCK_REISSUES = 3       -- autopilot re-issues before a "may be stuck" log line
logistics.MAX_ALERTS = 100
logistics.MAX_THRESHOLD = 100000
-- Land routes (spider autopilot walks straight lines and stops at water wider than ~10 tiles): every trip asks the
-- pathfinder for a route that avoids water and out-of-map tiles only (spider legs step over buildings and cliffs),
-- keeps only its turns (Douglas-Peucker, PATH_EPSILON tiles: every queued waypoint costs the spider speed), then
-- drops every turn whose straight shortcut is clear of blocking tiles (the engine's long-range search bends paths through
-- chunk-level waypoints even on open ground), and caches hub-to-hub routes for PATH_CACHE_TICKS.
logistics.PATH_BOX = {{-1.5, -1.5}, {1.5, 1.5}} -- the route keeps the spider's centre 1.5 tiles from water
logistics.PATH_CLEARANCE = 1.5     -- tiles around a straight shortcut that must be free of blocking tiles
logistics.PATH_SAMPLE = 0.5        -- tiles between the clearance checks along a shortcut
-- "doodad": water, deep water and out-of-map tiles carry it, shallow water does not. Cliffs, trees and buildings
-- carry "water_tile" but not "doodad", so this mask cannot route haulers around things their legs step over.
logistics.PATH_MASK = {layers = {doodad = true}, colliding_with_tiles_only = true}
logistics.PATH_EPSILON = 0.75      -- tiles a simplified route may cut a corner of the pathfinder's route by
logistics.PATH_CACHE_TICKS = 60 * 60
logistics.PATH_TIMEOUT = 180       -- ticks to wait for a route before walking the straight line
logistics.PATH_RETRY_TICKS = 60    -- pathfinder busy (try_again_later): ask again this much later, at most 3 times
logistics.STALL_TICKS = 180        -- travelling without moving STALL_DIST for this long: route again (max 3 times)
logistics.STALL_DIST = 1
-- Items the hub panel always lists (when the prototype exists), in this order. hubgui.lua appends the items of
-- POLICY_SUBGROUPS (intermediates, science kits, unit kits), then anything else in the network or in a policy.
logistics.POLICY_ITEMS = {
  "iron-plate", "copper-plate", "steel-plate", "stone", "coal", "stone-brick", "iron-gear-wheel", "copper-cable",
  "electronic-circuit", "rts-explosives", "firearm-magazine",
}
logistics.POLICY_SUBGROUPS = {"rts-intermediates", "rts-science", "rts-units"}

-- Hubs are buildings (selection, HUD building page, removal events); the registry learns the name here.
buildings.KIND_BY_NAME[logistics.HUB] = "hub"

-- Phase 5 M1 (m1-rails): Nation mode (storage.match.config.mode; in the rails autotest only its own test forces)
-- changes hauler fuel and cargo slots (balance.nation).
logistics.FUEL_ALERT_TICKS = 2 * 60 * 60 -- a hauler waiting for coal raises its "no fuel" alert at most this often
logistics.FUEL_RESCUE_TICKS = 30 * 60 -- Economy 0.1.1 (#6): a dry hauler's destination pays its leg after this long
local function nation_mode(force_name)
  local m = storage.match
  local c = m and m.config
  if c ~= nil and c.mode == "nation" then return true end
  local R = storage.rails
  return R ~= nil and R.test_forces ~= nil and R.test_forces[force_name] == true
end
-- Phase 5 M1: hub subtypes (a City Center is a hub, buildings.KIND_BY_NAME) with their own display name:
-- [entity name] = fn(unit_number) -> LocalisedString. They get no "Hub n" number. Load time only (scripts/cities.lua).
logistics.NAME_HOOKS = {}
-- Phase 5 M1 integration: fn(force_name, source_network_id, home_network_id) -> true when a freight train carries
-- from that network to that home (scripts/rails.lua sets it); auto haulers then leave the source to the train.
logistics.served_by_train = nil

local HUB_KINDS = {hub = true, cc = true}
local TRAVEL = {to_pickup = true, to_dropoff = true, to_home = true}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function lstate()
  local L = storage.logistics
  if not L then
    L = {}
    storage.logistics = L
  end
  L.hubs = L.hubs or {}
  L.haulers = L.haulers or {}
  L.net_cache = L.net_cache or {}
  L.stats = L.stats or {}
  L.hub_counter = L.hub_counter or {}
  L.path_requests = L.path_requests or {}
  L.path_cache = L.path_cache or {}
  return L
end

local function alerts()
  storage.alerts = storage.alerts or {}
  return storage.alerts
end

-- A new match starts clean (Wave C): before this, the alert list, the hauler counters and the "Hub n" numbering
-- survived match.teardown, so after Ctrl+Shift+R or a new match from the lobby F3 jumped to positions of the old arena,
-- the hauler panel and the AI autotest counted the old match's trips, and the first new hub was "Hub 3".
match.on_teardown(function()
  storage.alerts = {}
  local L = lstate()
  L.stats, L.hub_counter, L.net_cache, L.path_cache, L.path_requests = {}, {}, {}, {}, {}
end)

--- Counters of a force: {trips, delivered = {[item] = n}, lost, deployed}.
function logistics.stats(force_name)
  local L = lstate()
  local s = L.stats[force_name]
  if not s then
    s = {trips = 0, delivered = {}, lost = 0, deployed = 0}
    L.stats[force_name] = s
  end
  return s
end

local function copy(t)
  local r = {}
  for k, v in pairs(t or {}) do r[k] = v end
  return r
end

local function invalidate(force_name)
  local L = lstate()
  if force_name then L.net_cache[force_name] = nil else L.net_cache = {} end
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------
--- Append an alert for the HUD: {tick, force, kind, position, text = locale key}. Returns the entry.
function logistics.alert(force, kind, position, text_key)
  local list = alerts()
  local force_name = type(force) == "string" and force or force.name
  local x, y = util.xy(position)
  local entry = {tick = game.tick, force = force_name, kind = kind, position = {x = x, y = y}, text = text_key}
  list[#list + 1] = entry
  while #list > logistics.MAX_ALERTS do table.remove(list, 1) end
  util.log("logistics: alert %s for %s at %s (%s)", kind, force_name, util.pos_str(entry.position), tostring(text_key))
  return entry
end

---------------------------------------------------------------------------
-- Hubs and policies
---------------------------------------------------------------------------
--- Live building record of a hub or a CC, or nil.
function logistics.hub_rec(unit_number)
  local rec = unit_number and buildings.get(unit_number)
  if rec and HUB_KINDS[rec.kind] then return rec end
  return nil
end

local function ensure_policy(un, rec)
  local L = lstate()
  local p = L.hubs[un]
  if p then return p end
  local defaults = rec.kind == "cc" and logistics.DEFAULT_CC or logistics.DEFAULT_HUB
  p = {kind = rec.kind, force = rec.force, keep = copy(defaults.keep), export_above = copy(defaults.export_above)}
  if rec.kind == "hub" and not logistics.NAME_HOOKS[rec.entity.name] then -- Phase 5 M1: subtypes are not "Hub n"
    L.hub_counter[rec.force] = (L.hub_counter[rec.force] or 0) + 1
    p.index = L.hub_counter[rec.force]
  end
  L.hubs[un] = p
  invalidate(rec.force)
  return p
end

--- Policy of a hub or CC ({keep, export_above, ...}), created with the defaults on first use. nil for others.
function logistics.policy(unit_number)
  local rec = logistics.hub_rec(unit_number)
  if not rec then return nil end
  return ensure_policy(unit_number, rec)
end

--- Set one threshold: field "keep" or "export_above", value a number >= 0 or nil (off). Returns true when set.
function logistics.set_policy(unit_number, field, item, value)
  if field ~= "keep" and field ~= "export_above" then return false end
  local p = logistics.policy(unit_number)
  if not (p and item and prototypes.item[item]) then return false end
  if value ~= nil then
    value = math.floor(tonumber(value) or 0)
    value = math.max(0, math.min(logistics.MAX_THRESHOLD, value))
  end
  if p[field][item] == value then return true end
  p[field][item] = value
  invalidate(p.force)
  util.log("logistics: policy %s #%d %s %s = %s", p.kind, unit_number, field, item, tostring(value))
  return true
end

-- Phase 5 M2 treasury: a hub subtype changes hands (a captured trade post, scripts/market.lua). The caller has written
-- the entities' force and the building records; the policy follows the new force with empty thresholds, and the
-- network caches of both forces are rebuilt. Returns true when the hub had a policy.
function logistics.change_owner(unit_number, new_force)
  local L = lstate()
  local p = L.hubs[unit_number]
  local old = p and p.force
  if p then
    p.force = new_force
    p.keep, p.export_above = {}, {}
  end
  if old then invalidate(old) end
  invalidate(new_force)
  return p ~= nil
end

--- Localised display name: "Command Center" or "Hub 3".
function logistics.hub_name(unit_number)
  local p = lstate().hubs[unit_number]
  local named = p and p.kind == "hub" and buildings.get(unit_number) -- Phase 5 M1: hub subtypes name themselves
  local hook = named and logistics.NAME_HOOKS[named.entity.name]
  if hook then return hook(unit_number) end
  if p and p.kind == "hub" then return {"rts.hub-name", p.index or unit_number} end
  if p and p.kind == "cc" then return {"entity-name.rts-command-center"} end
  local rec = buildings.get(unit_number)
  return rec and rec.entity.localised_name or {"rts.hub-none"}
end

--- The logistic network of a hub or CC, or nil.
function logistics.hub_network(unit_number)
  local rec = logistics.hub_rec(unit_number)
  local net = rec and rec.entity.logistic_network
  return (net and net.valid) and net or nil
end

-- The hidden parts sitting under a hub (clones bring their own).
local function find_parts(surface, position, force)
  local parts = {}
  for _, e in pairs(surface.find_entities_filtered({position = position, radius = 1, force = force,
                                                     name = {logistics.HUB_POWER, logistics.HUB_POLE}})) do
    if e.name == logistics.HUB_POWER then parts.power = e else parts.pole = e end
  end
  return parts
end

local function place_stockpile(surface, force, at)
  local pos = at
  if not surface.can_place_entity({name = logistics.STOCKPILE, position = at, force = force}) then
    pos = surface.find_non_colliding_position(logistics.STOCKPILE, at, 4, 1, true)
  end
  if not pos then return nil end
  local s = surface.create_entity({name = logistics.STOCKPILE, position = pos, force = force})
  if s then buildings.register(s) end
  return s
end

-- Complete a freshly registered hub: hidden power and pole, two stockpiles, robots, a full buffer.
local function setup_hub(un, rec)
  local p = ensure_policy(un, rec)
  local e = rec.entity
  local surface, force, pos = e.surface, e.force, e.position
  p.parts = p.parts or {}
  local parts = p.parts
  local found = find_parts(surface, pos, force)
  parts.power = (parts.power and parts.power.valid and parts.power) or found.power
    or surface.create_entity({name = logistics.HUB_POWER, position = pos, force = force})
  parts.pole = (parts.pole and parts.pole.valid and parts.pole) or found.pole
    or surface.create_entity({name = logistics.HUB_POLE, position = pos, force = force})
  if p.setup_done then return p end
  parts.stockpiles = {}
  for _, off in ipairs(logistics.HUB_STOCKPILES) do
    local s = place_stockpile(surface, force, {x = pos.x + off.x, y = pos.y + off.y})
    if s then parts.stockpiles[#parts.stockpiles + 1] = s end
  end
  local robots = e.get_inventory(defines.inventory.roboport_robot)
  if robots and robots.is_empty() then
    for name, count in pairs(logistics.HUB_BOTS) do robots.insert({name = name, count = count}) end
  end
  p.bonus_bots = 0
  e.energy = e.electric_buffer_size or 0
  p.setup_done = true
  invalidate(rec.force)
  util.log("logistics: hub #%d (Hub %d) of %s at %s: power=%s pole=%s stockpiles=%d robots=%d buffer %.1f MJ",
    un, p.index or 0, rec.force, util.pos_str(pos), tostring(parts.power ~= nil), tostring(parts.pole ~= nil),
    #parts.stockpiles, robots and robots.get_item_count() or 0, e.energy / 1e6)
  return p
end

buildings.on_added(function(un, rec)
  if rec.kind == "hub" then
    setup_hub(un, rec)
  elseif rec.kind == "cc" then
    ensure_policy(un, rec)
  end
end)

buildings.on_removed(function(un, rec)
  local L = lstate()
  local p = L.hubs[un]
  if not p then return end
  L.hubs[un] = nil
  local destroyed = 0
  for _, key in pairs({"power", "pole"}) do
    local part = p.parts and p.parts[key]
    if part and part.valid then
      part.destroy()
      destroyed = destroyed + 1
    end
  end
  invalidate(rec.force)
  if p.kind == "hub" then
    util.log("logistics: hub #%d of %s at %s removed, %d parts destroyed", un, rec.force, util.pos_str(rec.position),
      destroyed)
  end
end)

-- Demolishing a hub takes its attached stockpiles with it (buildings.demolish).
buildings.on_demolish_parts(function(rec)
  local p = rec.kind == "hub" and rec.entity.valid and lstate().hubs[rec.entity.unit_number]
  local out = {}
  for _, s in ipairs(p and p.parts and p.parts.stockpiles or {}) do
    if s.valid then out[#out + 1] = s end
  end
  return out
end)

---------------------------------------------------------------------------
-- Network graph
---------------------------------------------------------------------------
local function compute_networks(force_name)
  local L = lstate()
  local list, index = {}, {}
  local hub_list = {}
  for un, rec in buildings.for_force(force_name) do
    if HUB_KINDS[rec.kind] then hub_list[#hub_list + 1] = {un, rec} end
  end
  table.sort(hub_list, function(a, b) return a[1] < b[1] end)
  for _, pair in ipairs(hub_list) do
    local un, rec = pair[1], pair[2]
    ensure_policy(un, rec)
    local net = rec.entity.logistic_network
    if net and net.valid then
      local i = index[net.network_id]
      local entry = i and list[i]
      if not entry then
        entry = {network = net, id = net.network_id, hubs = {}, contents = {}, keep = {}, export = {},
                 position = {x = rec.position.x, y = rec.position.y}}
        for _, item in pairs(net.get_contents()) do
          entry.contents[item.name] = (entry.contents[item.name] or 0) + item.count
        end
        list[#list + 1] = entry
        index[net.network_id] = #list
      end
      entry.hubs[#entry.hubs + 1] = un
      if rec.kind == "cc" and not entry.cc then entry.cc = un end
      local p = L.hubs[un]
      for item, n in pairs(p.keep) do entry.keep[item] = math.max(entry.keep[item] or 0, n) end
      for item, n in pairs(p.export_above) do entry.export[item] = math.max(entry.export[item] or 0, n) end
    end
  end
  local by_hub = {}
  for i, entry in ipairs(list) do
    for item, n in pairs(entry.export) do entry.export[item] = math.max(n, entry.keep[item] or 0) end
    for _, un in ipairs(entry.hubs) do by_hub[un] = i end
  end
  return {tick = game.tick, list = list, by_id = index, by_hub = by_hub}
end

local function cache(force_name)
  local L = lstate()
  local c = L.net_cache[force_name]
  local fresh = c and game.tick >= c.tick and game.tick - c.tick < logistics.CACHE_TICKS
  if fresh then
    for _, entry in ipairs(c.list) do
      if not entry.network.valid then
        fresh = false
        break
      end
    end
  end
  if not fresh then
    c = compute_networks(force_name)
    L.net_cache[force_name] = c
  end
  return c
end

--- The force's logistic networks that contain a hub or a CC: array of
--- {network, id, hubs = {unit numbers}, cc = unit number?, contents = {[item] = n}, keep = {[item] = n},
---  export = {[item] = threshold}, position}. Cached for CACHE_TICKS (contents may be that old).
function logistics.networks(force_name)
  return cache(force_name).list
end

--- The network entry (see logistics.networks) a hub or CC belongs to, or nil.
function logistics.entry_for_hub(unit_number)
  local p = lstate().hubs[unit_number]
  local rec = logistics.hub_rec(unit_number)
  if not (p and rec) then return nil end
  local c = cache(rec.force)
  local i = c.by_hub[unit_number]
  return i and c.list[i] or nil
end

--- Entry of a network id of a force, or nil.
function logistics.entry_by_id(force_name, network_id)
  local c = cache(force_name)
  local i = c.by_id[network_id]
  return i and c.list[i] or nil
end

--- What the entry's network offers: {[item] = count above its export threshold}.
function logistics.exports(entry)
  local out = {}
  for item, threshold in pairs(entry.export) do
    local n = (entry.contents[item] or 0) - threshold
    if n > 0 then out[item] = n end
  end
  return out
end

--- What the entry's network asks for: {[item] = keep - count}.
function logistics.requests(entry)
  local out = {}
  for item, keep in pairs(entry.keep) do
    local n = keep - (entry.contents[item] or 0)
    if n > 0 then out[item] = n end
  end
  return out
end

local function remove_from(source, item, count)
  if source.object_name == "LuaLogisticNetwork" then return source.remove_item({name = item, count = count}) end
  if source.object_name == "LuaInventory" then return source.remove({name = item, count = count}) end
  return source.remove_item({name = item, count = count}) -- LuaEntity
end

--- Move up to `count` of `item` from one holder to another. Holders: LuaLogisticNetwork, LuaInventory or LuaEntity.
--- What the destination cannot take goes back to the source. Returns the number moved.
function logistics.transfer(from, to, item, count)
  if not (from and to and from.valid and to.valid) or count <= 0 then return 0 end
  local removed = remove_from(from, item, count)
  if removed <= 0 then return 0 end
  local put = to.insert({name = item, count = removed})
  if put < removed then
    local back = from.insert({name = item, count = removed - put})
    if back < removed - put then
      util.log("logistics: transfer lost %d %s (neither side had room)", removed - put - back, item)
    end
  end
  return put
end

---------------------------------------------------------------------------
-- Haulers: helpers
---------------------------------------------------------------------------
local function trunk(h)
  return h.entity.get_inventory(defines.inventory.spider_trunk)
end

local function read_cargo(h)
  local cargo = {}
  local inv = trunk(h)
  if inv then
    for _, item in pairs(inv.get_contents()) do cargo[item.name] = (cargo[item.name] or 0) + item.count end
  end
  h.cargo = cargo
  return cargo
end

--- The live hauler record of a unit number, or nil.
function logistics.hauler(unit_number)
  local h = unit_number and lstate().haulers[unit_number]
  if h and h.entity.valid then return h end
  return nil
end

--- Iterator over (unit_number, record) of a force's live haulers.
function logistics.haulers_of(force_name)
  local list = lstate().haulers
  local key
  return function()
    while true do
      local h
      key, h = next(list, key)
      if key == nil then return nil end
      if h.force == force_name and h.entity.valid then return key, h end
    end
  end
end

--- Where a hauler stops at a hub: APPROACH_GAP tiles below its selection box.
function logistics.approach_point(unit_number)
  local rec = logistics.hub_rec(unit_number)
  if not rec then return nil end
  local e = rec.entity
  local box = e.prototype.selection_box
  local p = e.position
  return {x = p.x, y = p.y + box.right_bottom.y + logistics.APPROACH_GAP}
end

local function near_hub(h, un)
  local point = logistics.approach_point(un)
  if not point then return false end
  if util.distance(h.entity.position, point) <= logistics.ARRIVE_RADIUS + 1 then return true end
  local rec = logistics.hub_rec(un)
  return rec ~= nil and util.distance(h.entity.position, rec.entity.position) <= 6
end

local function set_state(h, state, reason)
  h.state, h.reason = state, reason
  if reason ~= "no-fuel" then h.dry_since = nil end -- Economy 0.1.1 (#6): the dry wait's start (go(), FUEL_RESCUE_TICKS)
  if h.logged_state ~= state .. (reason or "") then
    h.logged_state = state .. (reason or "")
    util.log("logistics: hauler #%d (%s, %s) %s%s", h.entity.unit_number, h.force, h.mode, state,
      reason and (" (" .. reason .. ")") or "")
  end
end

---------------------------------------------------------------------------
-- Haulers: land routes
---------------------------------------------------------------------------
local function route_length(from, waypoints)
  local len, prev = 0, from
  for _, w in ipairs(waypoints) do
    len = len + util.distance(prev, w)
    prev = w
  end
  return len
end

-- Hand a route to the autopilot. `source`: "path", "cache" or "straight".
local function apply_route(h, waypoints, source)
  local e = h.entity
  e.autopilot_destination = nil
  for _, w in ipairs(waypoints) do e.add_autopilot_destination(w) end
  h.route = {n = #waypoints, length = route_length(e.position, waypoints), source = source}
  h.progress = nil
end

-- Douglas-Peucker: the subset of `points` (array of {x, y}) whose polyline stays within `eps` of the original.
local function simplify(points, eps)
  local n = #points
  if n <= 2 then return points end
  local keep = {[1] = true, [n] = true}
  local stack = {{1, n}}
  while #stack > 0 do
    local seg = table.remove(stack)
    local a, b = seg[1], seg[2]
    local ax, ay = points[a].x, points[a].y
    local dx, dy = points[b].x - ax, points[b].y - ay
    local len2 = dx * dx + dy * dy
    local best, best_d = nil, eps
    for i = a + 1, b - 1 do
      local px, py = points[i].x - ax, points[i].y - ay
      local t = len2 > 1e-9 and math.max(0, math.min(1, (px * dx + py * dy) / len2)) or 0
      local qx, qy = px - t * dx, py - t * dy
      local d = math.sqrt(qx * qx + qy * qy)
      if d > best_d then best, best_d = i, d end
    end
    if best then
      keep[best] = true
      stack[#stack + 1] = {a, best}
      stack[#stack + 1] = {best, b}
    end
  end
  local out = {}
  for i = 1, n do
    if keep[i] then out[#out + 1] = points[i] end
  end
  return out
end

-- True when a PATH_CLEARANCE-wide corridor from a to b holds no tile of the route mask's layer (water, out-of-map).
local function segment_clear(surface, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / logistics.PATH_SAMPLE))
  local r = logistics.PATH_CLEARANCE
  for i = 0, steps do
    local x, y = a.x + dx * i / steps, a.y + dy * i / steps
    if surface.count_tiles_filtered({area = {{x - r, y - r}, {x + r, y + r}}, collision_mask = "doodad", limit = 1}) > 0 then
      return false
    end
  end
  return true
end

-- String pulling: from each kept point jump to the farthest later point that is in clear straight line.
local function shortcut(surface, start, points)
  local out, cur, i = {}, start, 1
  while i <= #points do
    local j = #points
    while j > i and not segment_clear(surface, cur, points[j]) do j = j - 1 end
    out[#out + 1] = points[j]
    cur, i = points[j], j + 1
  end
  return out
end

local function straight(h)
  if not h.dest then return end
  apply_route(h, {{x = h.dest.x, y = h.dest.y}}, "straight")
end

-- Cache key of a hub-to-hub trip: only when the hauler stands at the hub it last arrived at.
local function path_key(h, hub_un)
  local from = h.at_hub
  if from and hub_un and from ~= hub_un and near_hub(h, from) then return from .. ">" .. hub_un end
  return nil
end

-- Route to h.dest: from the cache when `key` has a fresh entry, else ask the pathfinder (the hauler waits for the
-- answer, at most PATH_TIMEOUT ticks; on_script_path_request_finished applies it).
local function request_route(h, key, retries)
  local L = lstate()
  local dest = h.dest
  if not dest then return end
  local cached = key and L.path_cache[key]
  if cached and game.tick - cached.tick < logistics.PATH_CACHE_TICKS then
    apply_route(h, cached.waypoints, "cache")
    return
  end
  local e = h.entity
  local ok, id = pcall(e.surface.request_path, {
    bounding_box = logistics.PATH_BOX, collision_mask = logistics.PATH_MASK, start = e.position, goal = dest,
    force = e.force, radius = 2, path_resolution_modifier = 0,
    pathfind_flags = {allow_paths_through_own_entities = true, prefer_straight_paths = true, cache = false},
  })
  if not ok or not id then
    util.log("hauler no path #%d: request failed (%s), straight line", e.unit_number, tostring(id))
    straight(h)
    return
  end
  L.path_requests[id] = {un = e.unit_number, dest = {x = dest.x, y = dest.y}, key = key, tick = game.tick,
                         from = {x = e.position.x, y = e.position.y}, retries = retries or 0}
  h.path_req = id
  e.autopilot_destination = nil
end

local function go(h, hub_un, state)
  local point = logistics.approach_point(hub_un)
  if not point then return false end
  -- Phase 5 M1 (m1-rails): in Nation mode a hauler leaving a hub burns 1 coal per hauler_tiles_per_coal tiles of the
  -- trip, taken from that hub's network; without it the hauler waits there ("no-fuel").
  -- Phase 5 M1 integration: a hauler leaving for a pickup or a drop-off also tanks the coal of the way back (h.fuel,
  -- the coal it carries in its tank), so one end of a route with coal is enough: outposts and far hubs need none.
  -- The tank is used first; a leg the tank and the network cannot pay waits as before.
  local per = nation_mode(h.force) and balance.nation and balance.nation.hauler_tiles_per_coal
  -- the departure network: the hub the hauler stands at, or the network of its last hub when it stands inside it (a
  -- new hauler walks out of a factory in its home's network)
  local net
  local field = false -- Economy 0.1.1 (#6): between hubs (a new route given on the way), not inside a network
  if per and h.at_hub then
    if near_hub(h, h.at_hub) then
      net = logistics.hub_network(h.at_hub)
    else
      local hn = logistics.hub_network(h.at_hub)
      local here = h.entity.surface.find_logistic_network_by_position(h.entity.position, h.force)
      if hn and here and here.valid and here.network_id == hn.network_id then net = hn end
    end
    field = net == nil
    -- a walk inside one network (a new hauler from its factory to its home hub) burns nothing
    local dest = net and logistics.hub_network(hub_un)
    if dest and dest.valid and dest.network_id == net.network_id then net = nil end
  end
  -- Economy 0.1.1 (#6): a leg started between hubs is free as before, but its way back is not: a route hauler sent to
  -- a drop-off or an auto hauler sent to a source on the way (the AI's town supply and export routes re-route haulers
  -- that are driving: M1 501, the player's #2900 and #3411 and rts-ai-1's #2951 stood dry at the stop for 26-31 game
  -- minutes) takes its way back from the destination's network when its tank is short, else refuels first: a route
  -- hauler at its pickup, an auto hauler at home (both then leave by the rule below).
  if per and field then
    local manual = h.mode == "manual"
    local base = manual and state == "to_dropoff" and h.pickup or (not manual and state == "to_pickup" and h.home)
    local bp = base and logistics.approach_point(base)
    if bp then
      local back = math.ceil(util.distance(point, bp) * 1.1 / per)
      local tank = h.fuel or 0
      if tank < back then
        local dnet = logistics.hub_network(hub_un)
        local got = (dnet and dnet.valid and dnet.get_item_count("coal") >= back - tank)
          and dnet.remove_item({name = "coal", count = back - tank}) or 0
        if got > 0 then
          h.fuel = tank + got
          util.log("logistics: hauler #%d takes %d coal for the way back from the network of hub #%d (on the way)",
            h.entity.unit_number, got, hub_un)
        elseif base ~= hub_un and logistics.hub_rec(base) then
          util.log("logistics: hauler #%d has %d of %d coal for the way back from hub #%d: refuels at hub #%d first",
            h.entity.unit_number, tank, back, hub_un, base)
          return go(h, base, manual and "to_pickup" or "to_home")
        end
      end
    end
  end
  if per and net then
    local need = math.ceil(util.distance(h.entity.position, point) * 1.1 / per)
    local tank = h.fuel or 0
    local from_tank = math.min(tank, need)
    local need_net = need - from_tank
    local left = tank - from_tank -- the tank once this leg is paid
    -- the way back is tanked when leaving for a pickup and for a drop-off alike, so a route from the capital to an
    -- outpost without coal runs too (the docs agent's GUI check)
    local back = (state == "to_pickup" or state == "to_dropoff") and need or 0
    -- Phase 5 M3 ai (QA fix 3, in m3-integ's QA fix round): a route hauler must not stand out of fuel at its drop-off
    -- (M2 703 on f37d073: three supply haulers of rts-ai-2's town 12 in turn, the town starving).
    -- Economy 0.1.1 (#6): the way back is checked against the coal the hauler can count on when it gets there, not the
    -- drop-off's coal at departure (rts-ai-1's #2951 left town 1662 while port 674 held its way back, found it spent
    -- 61 s later and stood dry there for 22 game minutes). A leg to a stop without a sure refill requires its way back:
    -- a manual route hauler leaving for its drop-off (the way back to its pickup) and an auto hauler leaving for a
    -- source (the way home: in M1 501 the player's auto haulers stood dry at outposts and towns for 140 game minutes,
    -- one of them for 40). That way back is paid now: from the tank, then this hub's network, then the destination's
    -- network (taken now, so nothing there spends it before the hauler arrives); what none of them covers keeps the
    -- hauler waiting where it stands. The other legs tank whatever this network spares for the way back, as before.
    local required = false
    if h.mode == "manual" and state == "to_dropoff" then
      required = true
      if h.at_hub ~= h.pickup then
        local pp = logistics.approach_point(h.pickup)
        if pp then back = math.ceil(util.distance(point, pp) * 1.1 / per) end
      end
    elseif h.mode ~= "manual" and state == "to_pickup" then
      required = true
      local hp = logistics.approach_point(h.home)
      if hp then back = math.ceil(util.distance(point, hp) * 1.1 / per) end
    end
    local back_net = math.max(0, back - left)
    local want = need_net + back_net
    local got = (want > 0 and net) and net.remove_item({name = "coal", count = want}) or 0
    local dnet = logistics.hub_network(hub_un)
    if dnet and not (dnet.valid and dnet.network_id ~= net.network_id) then dnet = nil end
    -- Economy 0.1.1 (#6): one end of a route with coal is enough, also for a hauler that stands dry at the other end
    -- (a route given to a hauler at a coal-less town or outpost, or its first trip from there: rts-player's #2481,
    -- M1 501, stood 18-24 minutes at its town): after FUEL_RESCUE_TICKS of waiting the stop it drives to pays the leg
    -- (and a required way back) when its network holds the coal.
    local rescued = 0
    if got < need_net and dnet and h.dry_since and game.tick - h.dry_since >= logistics.FUEL_RESCUE_TICKS then
      local miss = need_net - got
      if dnet.get_item_count("coal") >= miss + (required and back_net or 0) then
        rescued = dnet.remove_item({name = "coal", count = miss})
      end
    end
    local paid = got + rescued
    local short = math.max(0, want - paid) -- the part of the way back nothing paid yet (when paid covers this leg)
    local reserved = 0
    if required and paid >= need_net and short > 0 and dnet and dnet.get_item_count("coal") >= short then
      reserved = dnet.remove_item({name = "coal", count = short})
    end
    if paid >= need_net and (not required or reserved >= short) then
      h.fuel = left + (paid - need_net) + reserved
      h.fuel_back, h.dry_since = nil, nil
      if rescued > 0 then
        util.log("logistics: hauler #%d stood out of fuel at hub #%d: hub #%d's network pays the %d coal of the trip",
          h.entity.unit_number, h.at_hub, hub_un, rescued)
      end
      if reserved > 0 then
        util.log("logistics: hauler #%d takes %d coal for the way back from the network of hub #%d (%d from hub #%d)",
          h.entity.unit_number, reserved, hub_un, paid - need_net, h.at_hub)
      end
    else
      if got > 0 then net.insert({name = "coal", count = got}) end
      if rescued + reserved > 0 then dnet.insert({name = "coal", count = rescued + reserved}) end
      -- (it waits where it stands, never at a stop without coal; h.fuel_back: the hub panel says it waits for the way
      -- back's coal too; the reason stays "no-fuel" for the AI's fuel rules)
      h.fuel_back = (paid >= need_net and required) or nil
      h.dry_since = h.dry_since or game.tick
      set_state(h, "waiting", "no-fuel")
      -- one alert per hauler per FUEL_ALERT_TICKS: "Hauler N: no fuel at <hub>"
      if not h.fuel_alert or game.tick - h.fuel_alert >= logistics.FUEL_ALERT_TICKS then
        h.fuel_alert = game.tick
        local entry = logistics.alert(h.force, "hauler-no-fuel", h.entity.position, "rts.alert-hauler-no-fuel")
        entry.params = {h.entity.unit_number, logistics.hub_name(h.at_hub)}
      end
      return false
    end
    local stats = logistics.stats(h.force)
    stats.fuel = (stats.fuel or 0) + need
  end
  local key = path_key(h, hub_un)
  h.target, h.dest = hub_un, point
  local p = h.entity.position
  h.leg = {tick = game.tick, x = p.x, y = p.y}
  h.reissues, h.stalls, h.progress, h.repath_at, h.path_req, h.route = 0, 0, nil, nil, nil, nil
  set_state(h, state)
  request_route(h, key)
  return true
end

-- Nearest live hub or CC of a force to a position (any network), or nil.
local function nearest_hub(force_name, position)
  local best, best_d
  for un, rec in buildings.for_force(force_name) do
    if HUB_KINDS[rec.kind] then
      local d = util.distance(rec.entity.position, position)
      if not best_d or d < best_d then best, best_d = un, d end
    end
  end
  return best
end

-- Home for something at `entity`'s position: the nearest hub of the network covering it, else the nearest hub.
local function home_for(entity, force_name)
  local net = production.network_for(entity)
  if net then
    local entry = logistics.entry_by_id(force_name, net.network_id)
    if entry then
      local best, best_d
      for _, un in ipairs(entry.hubs) do
        local rec = logistics.hub_rec(un)
        local d = rec and util.distance(rec.entity.position, entity.position)
        if d and (not best_d or d < best_d) then best, best_d = un, d end
      end
      if best then return best end
    end
  end
  return nearest_hub(force_name, entity.position)
end

-- Reservations of every other hauler of the force, by network id:
--   inbound[id][item]  on the way to that network (cargo to a drop-off / home, or the plan of a trip to a source)
--   outbound[id][item] promised from that network (plans of haulers on their way to it)
local function reservations(force_name, except_un)
  local inbound, outbound = {}, {}
  local function add(tbl, id, items)
    if not (id and items) then return end
    local t = tbl[id]
    if not t then
      t = {}
      tbl[id] = t
    end
    for item, n in pairs(items) do t[item] = (t[item] or 0) + n end
  end
  local function net_id(un)
    local entry = un and logistics.entry_for_hub(un)
    return entry and entry.id
  end
  for un, h in logistics.haulers_of(force_name) do
    if un ~= except_un then
      if h.state == "to_pickup" and h.plan then
        add(outbound, net_id(h.plan_src or h.target), h.plan)
        add(inbound, net_id(h.mode == "auto" and h.home or h.dropoff), h.plan)
      elseif h.state == "to_dropoff" or h.state == "to_home" or h.state == "waiting" then
        local dest = h.mode == "auto" and h.home or h.dropoff
        if h.cargo and next(h.cargo) then add(inbound, net_id(dest), h.cargo) end
      end
    end
  end
  return inbound, outbound
end

local function stack_size(item)
  local proto = prototypes.item[item]
  return proto and proto.stack_size or 50
end

--- Cargo slots a hauler of this force may fill: BASE_SLOTS plus research (Hauler capacity), at most the trunk size.
function logistics.capacity(force_name)
  local bonus = research and research.hauler_slots and research.hauler_slots(force_name) or 0
  -- Phase 5 M1 (m1-rails): smaller trucks at nation scale (balance.nation.hauler_slots)
  local base = nation_mode(force_name) and balance.nation and balance.nation.hauler_slots or logistics.BASE_SLOTS
  return base + bonus
end

-- Cap a {item = n} plan to the trunk's free capacity (free slots plus room in partial stacks). Returns the capped
-- plan (items in name order, so the result is deterministic) or nil when nothing fits.
local function fit_plan(h, want)
  local inv = trunk(h)
  if not inv then return nil end
  local names = {}
  for item, n in pairs(want) do
    if n > 0 then names[#names + 1] = item end
  end
  table.sort(names)
  local empty_slots = inv.count_empty_stacks()
  local free_slots = math.max(0, math.min(empty_slots, logistics.capacity(h.force) - (#inv - empty_slots)))
  local plan, any = {}, false
  for _, item in ipairs(names) do
    local size = stack_size(item)
    local held = inv.get_item_count(item)
    local partial_room = (held % size == 0) and 0 or (size - held % size)
    local n = math.min(want[item], partial_room)
    local rest = want[item] - n
    if rest > 0 and free_slots > 0 then
      local slots = math.min(free_slots, math.ceil(rest / size))
      free_slots = free_slots - slots
      n = n + math.min(rest, slots * size)
    end
    if n > 0 then
      plan[item] = n
      any = true
    end
  end
  return any and plan or nil
end

-- Load `plan` from the network of hub `src_un` into the trunk. Returns the number of items loaded.
local function load_cargo(h, src_un, plan)
  local net = logistics.hub_network(src_un)
  local inv = trunk(h)
  if not (net and inv) then return 0 end
  local total, parts = 0, {}
  local names = {}
  for item in pairs(plan) do names[#names + 1] = item end
  table.sort(names)
  for _, item in ipairs(names) do
    local n = logistics.transfer(net, inv, item, plan[item])
    if n > 0 then
      total = total + n
      parts[#parts + 1] = string.format("%d %s", n, item)
    end
  end
  read_cargo(h)
  if total > 0 then
    util.log("logistics: hauler #%d loaded %s at hub #%d", h.entity.unit_number, table.concat(parts, ", "), src_un)
  end
  return total
end

-- Unload the whole trunk into the network of hub `dst_un`. Returns moved, left.
local function unload(h, dst_un)
  local net = logistics.hub_network(dst_un)
  local inv = trunk(h)
  if not (net and inv) then return 0, 1 end
  local moved, parts = 0, {}
  local stats = logistics.stats(h.force)
  h.delivered = h.delivered or {}
  for item, count in pairs(read_cargo(h)) do
    local n = logistics.transfer(inv, net, item, count)
    if n > 0 then
      moved = moved + n
      parts[#parts + 1] = string.format("%d %s", n, item)
      stats.delivered[item] = (stats.delivered[item] or 0) + n
      h.delivered[item] = (h.delivered[item] or 0) + n
    end
  end
  local left = 0
  for _, n in pairs(read_cargo(h)) do left = left + n end
  if moved > 0 then
    stats.trips = stats.trips + 1
    h.trips = (h.trips or 0) + 1
    invalidate(h.force)
    util.log("logistics: hauler #%d delivered %s to hub #%d (trip %d)%s", h.entity.unit_number,
      table.concat(parts, ", "), dst_un, h.trips, left > 0 and string.format(", %d left: network full", left) or "")
  end
  return moved, left
end

local function empty(cargo)
  return next(cargo) == nil
end

---------------------------------------------------------------------------
-- Haulers: planning
---------------------------------------------------------------------------
-- Manual: what to load at the pickup for the drop-off. Returns a plan or nil, reason.
local function manual_plan(h)
  local src = logistics.entry_for_hub(h.pickup)
  local dst = logistics.entry_for_hub(h.dropoff)
  if not (src and dst) then return nil, "no-route" end
  if src.id == dst.id then return nil, "same-network" end
  local inbound, outbound = reservations(h.force, h.entity.unit_number)
  local out_res, in_res = outbound[src.id] or {}, inbound[dst.id] or {}
  local feeder = next(dst.keep) == nil -- a drop-off without keep thresholds takes every export
  local want = {}
  -- live counts: the hauler stands at the pickup
  for item, threshold in pairs(src.export) do
    local avail = src.network.get_item_count(item) - threshold - (out_res[item] or 0)
    if avail > 0 then
      local wanted
      if feeder then
        wanted = avail
      else
        local keep = dst.keep[item]
        wanted = keep and (keep - dst.network.get_item_count(item) - (in_res[item] or 0)) or 0
      end
      local n = math.min(avail, wanted)
      if n > 0 then want[item] = n end
    end
  end
  local plan = fit_plan(h, want)
  if not plan then return nil, "nothing" end
  return plan
end

-- Auto: a source hub and a plan for the home hub's requests, or nil, reason.
local function auto_plan(h)
  local home = logistics.entry_for_hub(h.home)
  if not home then return nil, nil, "no-home" end
  local inbound, outbound = reservations(h.force, h.entity.unit_number)
  local in_res = inbound[home.id] or {}
  local needs, any = {}, false
  for item, keep in pairs(home.keep) do
    local n = keep - (home.contents[item] or 0) - (in_res[item] or 0)
    if n > 0 then
      needs[item] = n
      any = true
    end
  end
  if not any then return nil, nil, "nothing" end
  local home_rec = logistics.hub_rec(h.home)
  local best, best_d, best_plan
  for _, entry in ipairs(logistics.networks(h.force)) do
    -- Phase 5 M1 integration: a network a freight train already serves for this home is left to the train
    if entry.id ~= home.id and not (logistics.served_by_train and logistics.served_by_train(h.force, entry.id, home.id)) then
      local out_res = outbound[entry.id] or {}
      local want, ok = {}, false
      for item, need in pairs(needs) do
        local threshold = entry.export[item]
        if threshold then
          local avail = (entry.contents[item] or 0) - threshold - (out_res[item] or 0)
          if avail > 0 then
            want[item] = math.min(need, avail)
            ok = true
          end
        end
      end
      if ok then
        -- the entry's hub nearest to home is the pickup
        for _, un in ipairs(entry.hubs) do
          local rec = logistics.hub_rec(un)
          local d = rec and util.distance(rec.entity.position, home_rec.entity.position)
          if d and (not best_d or d < best_d) then best, best_d, best_plan = un, d, want end
        end
      end
    end
  end
  if not best then return nil, nil, "nothing" end
  local plan = fit_plan(h, best_plan)
  if not plan then return nil, nil, "full" end
  return best, plan
end

-- Economy 0.1.1 (#6, #7): Nation-mode trips worth their coal. An auto hauler went for whatever a source offered above its
-- export level: in M1 501 288 of the player's 301 auto trips carried under 20 items (median 8 plates, 4 coal a round
-- trip to an outpost 56 tiles away), and once haulers stopped standing dry at outposts (the way back rule above) those
-- trips burnt the capitals' coal the trains needed (the player's first freight train left a town depot with 2 coal and
-- stood there out of fuel). A trip now waits at home until its load is worth the round trip's coal
-- (balance.nation.hauler_items_per_coal items per coal) or for at most hauler_batch_wait ticks since the first small
-- load was offered, then takes what there is. True while it should wait (h.batch_since: when the wait began).
local function small_load(h, plan, from_un, to_un)
  local per = nation_mode(h.force) and balance.nation and balance.nation.hauler_tiles_per_coal
  if not (per and plan) then return false end
  local a, b = logistics.approach_point(from_un), logistics.approach_point(to_un)
  if not (a and b) then return false end
  local total = 0
  for _, n in pairs(plan) do total = total + n end
  local coal = 2 * math.ceil(util.distance(a, b) * 1.1 / per)
  local want = (balance.nation.hauler_items_per_coal or 25) * coal
  if total >= want then return false end
  local now = game.tick
  if not h.batch_since then h.batch_since = now end
  return now - h.batch_since < (balance.nation.hauler_batch_wait or 3600)
end

-- One decision for a hauler that is not travelling (idle / waiting).
local function plan_next(h)
  local cargo = read_cargo(h)
  if h.mode == "manual" then
    if not (logistics.hub_rec(h.pickup) and logistics.hub_rec(h.dropoff)) then
      if not empty(cargo) and logistics.hub_rec(h.dropoff) then
        if near_hub(h, h.dropoff) then
          local _, left = unload(h, h.dropoff)
          if left > 0 then set_state(h, "waiting", "full") end
          return
        end
        go(h, h.dropoff, "to_dropoff")
        return
      end
      set_state(h, "waiting", "no-route")
      return
    end
    if not empty(cargo) then
      if near_hub(h, h.dropoff) then
        local _, left = unload(h, h.dropoff)
        if left > 0 then set_state(h, "waiting", "full") else set_state(h, "idle") end
        return
      end
      go(h, h.dropoff, "to_dropoff")
      return
    end
    if near_hub(h, h.pickup) then
      local plan, reason = manual_plan(h)
      if plan and load_cargo(h, h.pickup, plan) > 0 then
        go(h, h.dropoff, "to_dropoff")
      else
        set_state(h, "waiting", reason or "nothing")
      end
      return
    end
    go(h, h.pickup, "to_pickup")
    return
  end

  -- auto
  if not logistics.hub_rec(h.home) then
    h.home = nearest_hub(h.force, h.entity.position)
    if not h.home then
      set_state(h, "waiting", "no-home")
      return
    end
    util.log("logistics: hauler #%d re-homed to hub #%d", h.entity.unit_number, h.home)
  end
  if not empty(cargo) then
    if near_hub(h, h.home) then
      local _, left = unload(h, h.home)
      if left > 0 then set_state(h, "waiting", "full") else set_state(h, "idle") end
      return
    end
    go(h, h.home, "to_home")
    return
  end
  if h.plan and h.plan_src and logistics.hub_rec(h.plan_src) and near_hub(h, h.plan_src) then
    -- at the source: load what is still offered and still needed
    local src, home = logistics.entry_for_hub(h.plan_src), logistics.entry_for_hub(h.home)
    local want = {}
    if src and home and src.id ~= home.id then
      local inbound, outbound = reservations(h.force, h.entity.unit_number)
      local out_res, in_res = outbound[src.id] or {}, inbound[home.id] or {}
      for item, n in pairs(h.plan) do
        local threshold = src.export[item]
        local avail = threshold and (src.network.get_item_count(item) - threshold - (out_res[item] or 0)) or 0
        local keep = home.keep[item] or 0
        local need = keep - home.network.get_item_count(item) - (in_res[item] or 0)
        local k = math.min(n, avail, need)
        if k > 0 then want[item] = k end
      end
    end
    local src_un = h.plan_src
    h.plan, h.plan_src = nil, nil
    local plan = fit_plan(h, want)
    if plan and load_cargo(h, src_un, plan) > 0 then
      go(h, h.home, "to_dropoff")
      return
    end
  end
  local src_un, plan, reason = auto_plan(h)
  -- Economy 0.1.1 (#6, #7): in Nation mode an auto trip waits at home (up to batch_wait) for a load worth its coal
  if src_un and near_hub(h, h.home) and small_load(h, plan, h.home, src_un) then
    h.plan, h.plan_src = nil, nil
    set_state(h, "waiting", "small-load")
    return
  end
  h.batch_since = nil
  if src_un then
    h.plan, h.plan_src = plan, src_un
    go(h, src_un, "to_pickup")
    return
  end
  h.plan, h.plan_src = nil, nil
  if near_hub(h, h.home) then
    set_state(h, "waiting", reason or "nothing")
  else
    go(h, h.home, "to_home")
  end
end

local function arrived(h)
  return h.dest ~= nil and util.distance(h.entity.position, h.dest) <= logistics.ARRIVE_RADIUS
end

-- One state-machine step.
local function step(h)
  local state = h.state
  if state == "parked" then return end
  if TRAVEL[state] then
    if not logistics.hub_rec(h.target) then
      set_state(h, "idle")
    elseif arrived(h) then
      local leg = h.leg
      if leg then
        local secs = (game.tick - leg.tick) / 60
        local dist = util.distance(leg, h.dest)
        local r = h.route
        util.log("logistics: hauler #%d arrived at hub #%d (%s): %.1f tiles in %.1f s = %.1f tiles/s; route %s, "
          .. "%d waypoints, %.1f tiles", h.entity.unit_number, h.target, state, dist, secs,
          secs > 0 and dist / secs or 0, r and r.source or "-", r and r.n or 0, r and r.length or 0)
        h.leg = nil
      end
      h.at_hub = h.target
      if state == "to_pickup" and h.mode == "manual" then h.plan = nil end
      set_state(h, "idle")
    else
      local e = h.entity
      local L = lstate()
      if h.path_req then
        -- waiting for the pathfinder
        local req = L.path_requests[h.path_req]
        if not req or game.tick - req.tick > logistics.PATH_TIMEOUT then
          util.log("hauler no path #%d to hub #%d: no answer in %d ticks, straight line", e.unit_number, h.target,
            logistics.PATH_TIMEOUT)
          if req then L.path_requests[h.path_req] = nil end
          h.path_req = nil
          straight(h)
        end
        return
      end
      if h.repath_at then
        if game.tick >= h.repath_at then
          local retries = h.repath_retries
          h.repath_at, h.repath_retries = nil, nil
          request_route(h, nil, retries)
        end
        return
      end
      if not e.autopilot_destination then
        -- the route ran out (or was cleared) short of the destination: route again from here
        h.reissues = (h.reissues or 0) + 1
        if h.reissues == logistics.STUCK_REISSUES then
          util.log("logistics: hauler #%d may be stuck at %s on its way to hub #%d", e.unit_number,
            util.pos_str(e.position), h.target)
        end
        if h.reissues <= logistics.STUCK_REISSUES then request_route(h, nil) else straight(h) end
        return
      end
      -- stalled with a destination (e.g. stopped at water on a straight line): route again, at most 3 times
      local p, pr = e.position, h.progress
      if not pr or util.distance(pr, p) > logistics.STALL_DIST then
        h.progress = {tick = game.tick, x = p.x, y = p.y}
      elseif game.tick - pr.tick >= logistics.STALL_TICKS then
        h.progress = {tick = game.tick, x = p.x, y = p.y}
        h.stalls = (h.stalls or 0) + 1
        util.log("logistics: hauler #%d stalled at %s on its way to hub #%d (%s route), re-routing (%d)",
          e.unit_number, util.pos_str(p), h.target, h.route and h.route.source or "-", h.stalls)
        if h.stalls <= 3 then request_route(h, nil) end
      end
      return
    end
  end
  plan_next(h)
end

---------------------------------------------------------------------------
-- Haulers: public API
---------------------------------------------------------------------------
--- Spawn a hauler near `position` for a force, in auto mode with the given home hub (default: nearest hub).
--- Registers it in storage.units (kind "hauler", claimed by this module). Returns entity, record or nil.
function logistics.spawn_hauler(surface, position, force_name, home_un)
  local entity, urec = units.spawn(logistics.HAULER, position, force_name, logistics.KIND, surface)
  if not entity then
    util.log("logistics: could not place a hauler for %s near %s", force_name, util.pos_str(position))
    return nil
  end
  urec.order, urec.issuer = logistics.ORDER, logistics.ISSUER
  local force = game.forces[force_name]
  local color = force and (force.custom_color or force.color)
  if color then entity.color = color end
  local h = {entity = entity, force = force_name, mode = "auto", home = home_un or nearest_hub(force_name, entity.position),
             state = "idle", cargo = {}, delivered = {}, trips = 0, created = game.tick}
  h.at_hub = h.home
  lstate().haulers[entity.unit_number] = h
  local stats = logistics.stats(force_name)
  stats.deployed = stats.deployed + 1
  util.log("logistics: hauler #%d of %s spawned at %s, auto, home hub #%s", entity.unit_number, force_name,
    util.pos_str(entity.position), tostring(h.home))
  return entity, h
end

local function reset_trip(h)
  h.plan, h.plan_src, h.target, h.dest, h.leg = nil, nil, nil, nil, nil
  h.path_req, h.repath_at, h.route, h.progress = nil, nil, nil, nil
  if h.entity.valid then h.entity.autopilot_destination = nil end
  set_state(h, "idle")
  step(h)
end

--- Manual route: pickup hub. Switching from auto fills a missing drop-off with the home hub.
function logistics.set_pickup(unit_number, hub_un)
  local h = logistics.hauler(unit_number)
  if not (h and logistics.hub_rec(hub_un)) then return false end
  if h.mode == "auto" and not h.dropoff and h.home ~= hub_un then h.dropoff = h.home end
  h.mode, h.pickup = "manual", hub_un
  util.log("logistics: hauler #%d route pickup hub #%d -> drop-off hub #%s", unit_number, hub_un, tostring(h.dropoff))
  reset_trip(h)
  return true
end

--- Manual route: drop-off hub. Switching from auto fills a missing pickup with the home hub.
function logistics.set_dropoff(unit_number, hub_un)
  local h = logistics.hauler(unit_number)
  if not (h and logistics.hub_rec(hub_un)) then return false end
  if h.mode == "auto" and not h.pickup and h.home ~= hub_un then h.pickup = h.home end
  h.mode, h.dropoff = "manual", hub_un
  util.log("logistics: hauler #%d route pickup hub #%s -> drop-off hub #%d", unit_number, tostring(h.pickup), hub_un)
  reset_trip(h)
  return true
end

--- Auto mode: the hub the hauler serves.
function logistics.set_home(unit_number, hub_un)
  local h = logistics.hauler(unit_number)
  if not (h and logistics.hub_rec(hub_un)) then return false end
  h.home = hub_un
  util.log("logistics: hauler #%d home hub #%d", unit_number, hub_un)
  if h.mode == "auto" then reset_trip(h) end
  return true
end

--- "auto" (serve the home hub; the drop-off becomes home when set) or "manual" (the pickup -> drop-off route).
function logistics.set_mode(unit_number, mode)
  local h = logistics.hauler(unit_number)
  if not h or (mode ~= "auto" and mode ~= "manual") then return false end
  if mode == "auto" and h.dropoff and logistics.hub_rec(h.dropoff) then h.home = h.dropoff end
  h.mode = mode
  util.log("logistics: hauler #%d mode %s (home #%s, pickup #%s, drop-off #%s)", unit_number, mode, tostring(h.home),
    tostring(h.pickup), tostring(h.dropoff))
  reset_trip(h)
  return true
end

--- Go home, unload there and serve it as an auto hauler.
function logistics.return_home(unit_number)
  local h = logistics.hauler(unit_number)
  if not h then return false end
  if not logistics.hub_rec(h.home) then h.home = nearest_hub(h.force, h.entity.position) end
  h.mode = "auto"
  h.plan, h.plan_src = nil, nil
  util.log("logistics: hauler #%d returns home to hub #%s", unit_number, tostring(h.home))
  if h.home and not near_hub(h, h.home) then go(h, h.home, "to_home") else reset_trip(h) end
  return true
end

--- Walk to a position and park there (route suspended until a route order or resume).
function logistics.move_hauler(unit_number, position)
  local h = logistics.hauler(unit_number)
  if not h then return false end
  local x, y = util.xy(position)
  h.plan, h.plan_src, h.target, h.leg, h.repath_at = nil, nil, nil, nil, nil
  h.dest = {x = x, y = y}
  set_state(h, "parked")
  request_route(h, nil)
  return true
end

--- Leave the parked state and continue the route / auto service.
function logistics.resume(unit_number)
  local h = logistics.hauler(unit_number)
  if not h then return false end
  util.log("logistics: hauler #%d resumes (%s)", unit_number, h.mode)
  reset_trip(h)
  return true
end

---------------------------------------------------------------------------
-- Right click with haulers selected (orders.lua hook)
---------------------------------------------------------------------------
local ROUTE_COLORS = {pickup = {r = 0.3, g = 0.7, b = 1, a = 1}, dropoff = {r = 0.3, g = 1, b = 0.4, a = 1},
                      move = {r = 0.2, g = 1, b = 0.2, a = 1}}

local function marker(player_index, target, color, surface)
  local player = selection.real_player(player_index)
  if not player then return end
  rendering.draw_circle({color = color, radius = 2.5, width = 4, filled = false, target = target, surface = surface,
    time_to_live = 30, players = {player_index}})
end

-- The own hub or CC a right click meant: one in the event's entities, else the building under the point.
local function pick_hub(player_index, force_name, position, entities)
  for _, e in pairs(entities or {}) do
    if e.valid and e.force.name == force_name and e.unit_number then
      local rec = logistics.hub_rec(e.unit_number)
      if rec then return e.unit_number, rec end
    end
  end
  local un, rec = selection.building_at(player_index, position)
  if rec and HUB_KINDS[rec.kind] then return un, rec end
  return nil
end

--- orders.on_right_click hook. Returns an order name and a count when only haulers were selected (the click is
--- consumed), nil otherwise (the other units get the normal order; haulers are claimed, so orders.lua skips them).
function logistics.right_click(player_index, position, entities, alt)
  local haulers, others = {}, 0
  for _, entity in pairs(selection.get(player_index)) do
    if logistics.hauler(entity.unit_number) then haulers[#haulers + 1] = entity.unit_number else others = others + 1 end
  end
  if #haulers == 0 then return nil end
  table.sort(haulers)
  local force_name = selection.force_name(player_index)
  local hub_un, hub = pick_hub(player_index, force_name, position, entities)
  local order
  if hub_un then
    for _, un in ipairs(haulers) do
      if alt then logistics.set_dropoff(un, hub_un) else logistics.set_pickup(un, hub_un) end
    end
    order = alt and "route-dropoff" or "route-pickup"
    util.log("order %s n=%d hub=#%d (%s) player=%d", order, #haulers, hub_un, hub.kind, player_index)
    marker(player_index, hub.entity, alt and ROUTE_COLORS.dropoff or ROUTE_COLORS.pickup, hub.entity.surface)
  else
    local x, y = util.xy(position)
    for i, un in ipairs(haulers) do
      local k = i - 1
      local r, angle = 2.5 * math.sqrt(k), k * 2.39996 -- golden-angle spiral, so haulers do not stack
      logistics.move_hauler(un, {x = x + r * math.cos(angle), y = y + r * math.sin(angle)})
    end
    order = "hauler-move"
    util.log("order hauler-move n=%d dest=%s player=%d", #haulers, util.pos_str(position), player_index)
    local h = logistics.hauler(haulers[1])
    marker(player_index, {x = x, y = y}, ROUTE_COLORS.move, h and h.entity.surface)
  end
  if others > 0 then return nil end
  return order, #haulers
end

orders.on_right_click(logistics.right_click)

---------------------------------------------------------------------------
-- Hauler kits
---------------------------------------------------------------------------
local function deploy_from_factories()
  for _, rec in buildings.all("factory") do
    local out = rec.entity.get_output_inventory()
    local n = out and out.get_item_count(logistics.HAULER_KIT) or 0
    for _ = 1, n do
      local home = home_for(rec.entity, rec.force)
      local entity = logistics.spawn_hauler(rec.entity.surface, buildings.default_exit(rec), rec.force, home)
      if not entity then break end
      out.remove({name = logistics.HAULER_KIT, count = 1})
      util.log("logistics: factory #%d (%s) deployed hauler #%d, home hub #%s", rec.entity.unit_number, rec.force,
        entity.unit_number, tostring(home))
    end
  end
end

-- Research (Logistics I) adds robots to every hub: top up hubs that got fewer bonus robots than the force has now.
local function top_up_hub_robots()
  if not (research and research.robots_per_hub_bonus) then return end
  for un, p in pairs(lstate().hubs) do
    if p.kind == "hub" and p.setup_done then
      local want = research.robots_per_hub_bonus(p.force)
      local rec = want > (p.bonus_bots or 0) and logistics.hub_rec(un)
      if rec then
        local robots = rec.entity.get_inventory(defines.inventory.roboport_robot)
        local put = robots and robots.insert({name = logistics.BONUS_BOT, count = want - (p.bonus_bots or 0)}) or 0
        p.bonus_bots = (p.bonus_bots or 0) + put
        if put > 0 then util.log("logistics: hub #%d got %d research bonus robots", un, put) end
      end
    end
  end
end

local function deploy_from_networks()
  local forces = {}
  for _, p in pairs(lstate().hubs) do forces[p.force] = true end
  local names = {}
  for f in pairs(forces) do names[#names + 1] = f end
  table.sort(names)
  for _, force_name in ipairs(names) do
    for _, entry in ipairs(logistics.networks(force_name)) do
      if entry.network.valid and entry.network.get_item_count(logistics.HAULER_KIT) > 0 then
        local un = entry.hubs[1]
        local point = logistics.approach_point(un)
        local rec = logistics.hub_rec(un)
        if point and rec and entry.network.remove_item({name = logistics.HAULER_KIT, count = 1}) > 0 then
          local entity = logistics.spawn_hauler(rec.entity.surface, point, force_name, un)
          if not entity then entry.network.insert({name = logistics.HAULER_KIT, count = 1}) end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
events.on_nth_tick(logistics.STEP_PERIOD, function()
  local L = storage.logistics
  if not (L and L.haulers and next(L.haulers)) then return end
  local list = {}
  for un, h in pairs(L.haulers) do
    if h.entity.valid then list[#list + 1] = un else L.haulers[un] = nil end
  end
  table.sort(list)
  for _, un in ipairs(list) do
    local h = L.haulers[un]
    if h and h.entity.valid then step(h) end
  end
end)

events.on_nth_tick(logistics.DEPLOY_PERIOD, function()
  if not storage.buildings then return end
  deploy_from_factories()
  if storage.logistics and next(storage.logistics.hubs) then
    deploy_from_networks()
    top_up_hub_robots()
  end
end)

events.on(defines.events.on_spider_command_completed, function(e)
  local vehicle = e.vehicle
  local h = vehicle and vehicle.valid and storage.logistics and storage.logistics.haulers[vehicle.unit_number]
  if h and h.state ~= "parked" then step(h) end
end)

events.on(defines.events.on_script_path_request_finished, function(e)
  local L = storage.logistics
  local req = L and L.path_requests and L.path_requests[e.id]
  if not req then return end
  L.path_requests[e.id] = nil
  local h = logistics.hauler(req.un)
  if not (h and h.path_req == e.id) then return end
  h.path_req = nil
  if not (h.dest and util.distance(h.dest, req.dest) < 0.01) then return end -- the destination changed meanwhile
  local un = h.entity.unit_number
  if e.path and #e.path > 0 then
    local raw = {{x = req.from.x, y = req.from.y}}
    for _, w in ipairs(e.path) do raw[#raw + 1] = {x = w.position.x, y = w.position.y} end
    raw[#raw + 1] = {x = req.dest.x, y = req.dest.y}
    local waypoints = simplify(raw, logistics.PATH_EPSILON)
    table.remove(waypoints, 1) -- the start
    waypoints = shortcut(h.entity.surface, req.from, waypoints)
    if req.key then L.path_cache[req.key] = {tick = e.tick, waypoints = waypoints} end
    apply_route(h, waypoints, "path")
    util.log("logistics: hauler #%d route to %s: %d of %d waypoints, %.1f tiles (pathfinder %.1f, straight %.1f), "
      .. "found in %d ticks%s", un, util.pos_str(req.dest), #waypoints, #e.path, h.route.length,
      route_length(req.from, raw), util.distance(req.from, req.dest), e.tick - req.tick,
      req.key and (" [cached as " .. req.key .. "]") or "")
    if #waypoints > 1 and #waypoints <= 8 then
      local parts = {}
      for _, w in ipairs(waypoints) do parts[#parts + 1] = util.pos_str(w) end
      util.log("logistics: hauler #%d route via %s", un, table.concat(parts, " "))
    end
  elseif e.try_again_later and req.retries < 3 then
    h.repath_at, h.repath_retries = e.tick + logistics.PATH_RETRY_TICKS, req.retries + 1
    util.log("logistics: hauler #%d pathfinder busy, retry %d", un, req.retries + 1)
  else
    util.log("hauler no path #%d from %s to %s, straight line", un, util.pos_str(req.from), util.pos_str(req.dest))
    straight(h)
  end
end)

events.on(defines.events.on_entity_died, function(e)
  local entity = e.entity
  if not (entity and entity.valid and entity.name == logistics.HAULER) then return end
  local L = storage.logistics
  local un = entity.unit_number
  local h = L and L.haulers[un]
  if not h then return end
  local cargo = {}
  for item, n in pairs(read_cargo(h)) do cargo[#cargo + 1] = string.format("%d %s", n, item) end
  table.sort(cargo)
  local cause = e.cause and e.cause.valid and string.format("%s (%s)", e.cause.name, e.cause.force.name) or "unknown"
  util.log("logistics: hauler lost #%d of %s at %s (%s, %s), cargo [%s], killed by %s", un, h.force,
    util.pos_str(entity.position), h.mode, h.state, table.concat(cargo, ", "), cause)
  local stats = logistics.stats(h.force)
  stats.lost = stats.lost + 1
  logistics.alert(h.force, "hauler-lost", entity.position, "rts.alert-hauler-lost")
  L.haulers[un] = nil
end)

events.on(defines.events.on_object_destroyed, function(e)
  local L = storage.logistics
  if e.type == defines.target_type.entity and L and L.haulers and L.haulers[e.useful_id] then
    L.haulers[e.useful_id] = nil
  end
end)

function logistics.init()
  lstate()
  alerts()
  -- policies for buildings registered before this module existed (saves, on_configuration_changed)
  if storage.buildings then
    -- Phase 5 M3 integration (perf notes open issue 9): setup_hub registers composite parts, so the walk goes over a
    -- sorted snapshot of the records instead of inserting into the table it traverses
    local list = {}
    for un, rec in buildings.all() do
      if rec.kind == "hub" or rec.kind == "cc" then list[#list + 1] = un end
    end
    table.sort(list)
    for _, un in ipairs(list) do
      local rec = storage.buildings[un]
      if rec and rec.kind == "hub" then setup_hub(un, rec) elseif rec and rec.kind == "cc" then ensure_policy(un, rec) end
    end
  end
  invalidate()
  -- prototypes/logistics.lua adds spider-vehicle to the RTS cursor's select filters (haulers are box-selected)
  local cursor = prototypes.item[util.CURSOR_ITEM]
  local ok, filters = pcall(function() return cursor.get_entity_type_filters(defines.selection_mode.select) end)
  local types = {}
  for t in pairs(ok and filters or {}) do types[#types + 1] = t end
  table.sort(types)
  util.log("logistics: rts-cursor select type filters: %s", table.concat(types, " "))
  -- prototypes/logistics.lua opts the hub and the hauler into the raiders' bonus damage (balance.raid_target_type)
  local masks = {}
  for _, name in ipairs({logistics.HUB, logistics.HAULER}) do
    local proto = prototypes.entity[name]
    local list = {}
    for t in pairs(proto and proto.trigger_target_mask or {}) do list[#list + 1] = t end
    table.sort(list)
    masks[#masks + 1] = string.format("%s=[%s]", name, table.concat(list, " "))
  end
  util.log("logistics: trigger target masks %s", table.concat(masks, " "))
end

---------------------------------------------------------------------------
-- Headless autotest (dev). Runs in a headless autotest game (storage.debug.autotest) when AUTOTEST_DEFAULT is
-- true or storage.debug.logistics_autotest is set. With rts-player's CC: a hub HUB_OFFSET away, an auto hauler
-- at the hub, 300 iron into the CC network, a factory in the hub network making a hauler kit; then right-click
-- route orders through orders.lua (fake player index 0), a hauler death, a manual CC -> hub copper route.
---------------------------------------------------------------------------
logistics.AUTOTEST_DEFAULT = false
local AT = {
  player = 0,                           -- the fake commander index selection/orders use in the autotest
  hub_offset = {x = 0, y = 60},
  factory_offset = {x = 6.5, y = -6.5},
  give_iron = 300,
  deliver_iron = 50,
  deliver_window = 90 * 60,
  kit_window = 60 * 60,
  manual_copper = 20,
  manual_window = 90 * 60,
  -- speed probe: a walker and a fresh hauler each go SPEED_TILES east from the hub, measured start to arrival
  speed_from = {x = -20, y = 14},
  speed_tiles = 60,
  speed_window = 40 * 60,
  -- land route stage: a 16-row water band between a source hub and a target hub, with a 14-tile land gap off the
  -- straight line; offsets from the player CC
  moat_src = {x = 0, y = -50},
  moat_dst = {x = 0, y = -108},
  moat_rows = {-86, -70},               -- y range [from, to) of the band
  moat_cols = {-200, 60},               -- x range [from, to), clipped to the arena
  moat_gap = {20, 34},                  -- x range [from, to) of the land gap: 14 tiles
  moat_iron = 200,
  moat_deliver = 50,
  moat_window = 90 * 60,
}

local function at_enabled()
  local d = storage.debug
  if not (d and d.autotest) then return false end
  if d.logistics_autotest ~= nil then return d.logistics_autotest end
  return logistics.AUTOTEST_DEFAULT
end

local function at_check(T, name, ok, fmt, ...)
  T.checks = T.checks or {pass = 0, fail = 0}
  if ok then T.checks.pass = T.checks.pass + 1 else T.checks.fail = T.checks.fail + 1 end
  util.log("logistics autotest check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function count_near(surface, name, position, radius, force)
  return #surface.find_entities_filtered({name = name, position = position, radius = radius, force = force})
end

local function at_setup(T)
  local force = util.PLAYER_FORCE
  local cc_rec, cc_un = buildings.main_cc(force)
  local surface = cc_rec.entity.surface
  local cp = cc_rec.entity.position
  local want = {x = cp.x + AT.hub_offset.x, y = cp.y + AT.hub_offset.y}
  local pos = surface.find_non_colliding_position(logistics.HUB, want, 16, 1, true) or want
  local hub = surface.create_entity({name = logistics.HUB, position = pos, force = force, raise_built = true})
  if not hub then
    at_check(T, "logistics_hub_composite", false, "could not create a hub at %s", util.pos_str(pos))
    T.stage = "done"
    return
  end
  local hub_un = hub.unit_number
  T.hub, T.cc = hub_un, cc_un
  local p = lstate().hubs[hub_un]
  local parts = p and p.parts or {}
  local robots = hub.get_inventory(defines.inventory.roboport_robot)
  local piles = count_near(surface, logistics.STOCKPILE, hub.position, 5, force)
  at_check(T, "logistics_hub_composite", buildings.get(hub_un) ~= nil and buildings.get(hub_un).kind == "hub"
    and parts.power and parts.power.valid and parts.pole and parts.pole.valid and piles == 2
    and robots.get_item_count("construction-robot") == 10 and robots.get_item_count("logistic-robot") == 6
    and hub.energy > 0,
    "hub #%d at %s (%.0f tiles from the CC): kind=%s power=%s pole=%s stockpiles=%d robots=%d+%d buffer %.1f MJ",
    hub_un, util.pos_str(hub.position), util.distance(hub.position, cp), tostring(buildings.get(hub_un) and buildings.get(hub_un).kind),
    tostring(parts.power and parts.power.valid), tostring(parts.pole and parts.pole.valid), piles,
    robots.get_item_count("construction-robot"), robots.get_item_count("logistic-robot"), hub.energy / 1e6)
  invalidate(force)
  local nets = logistics.networks(force)
  local he, ce = logistics.entry_for_hub(hub_un), logistics.entry_for_hub(cc_un)
  at_check(T, "logistics_networks", he ~= nil and ce ~= nil and he.id ~= ce.id and #nets >= 2,
    "%d networks; hub network %s, CC network %s", #nets, he and he.id or "nil", ce and ce.id or "nil")
  local hp, cp_ = logistics.policy(hub_un), logistics.policy(cc_un)
  at_check(T, "logistics_policy_defaults", hp.keep["iron-plate"] == 50 and hp.keep["copper-plate"] == 20
    and cp_.export_above["iron-plate"] == 100 and cp_.export_above["copper-plate"] == 100,
    "hub keep iron=%s copper=%s; CC export_above iron=%s copper=%s steel=%s", tostring(hp.keep["iron-plate"]),
    tostring(hp.keep["copper-plate"]), tostring(cp_.export_above["iron-plate"]),
    tostring(cp_.export_above["copper-plate"]), tostring(cp_.export_above["steel-plate"]))
  -- the hub keeps iron only during the auto stage (copper is the manual stage's item)
  logistics.set_policy(hub_un, "keep", "copper-plate", nil)
  local net = cc_rec.entity.logistic_network
  local before = net.get_item_count("iron-plate")
  local given = net.insert({name = "iron-plate", count = AT.give_iron})
  T.iron_hub_before = he and he.network.get_item_count("iron-plate") or 0
  util.log("logistics autotest: CC #%d iron %d -> %d (+%d)", cc_un, before, net.get_item_count("iron-plate"), given)
  local entity = logistics.spawn_hauler(surface, logistics.approach_point(hub_un), force, hub_un)
  T.h1 = entity and entity.unit_number
  -- a factory in the hub network makes a hauler kit
  local fpos = {x = hub.position.x + AT.factory_offset.x, y = hub.position.y + AT.factory_offset.y}
  fpos = surface.find_non_colliding_position("rts-factory", fpos, 6, 1, true) or fpos
  local factory = surface.create_entity({name = "rts-factory", position = fpos, force = force, raise_built = true})
  if factory then
    T.factory = factory.unit_number
    local ok = production.set_recipe(factory, logistics.HAULER_KIT)
    local input = factory.get_inventory(defines.inventory.crafter_input)
    local put = input.insert({name = "iron-plate", count = 30}) + input.insert({name = "electronic-circuit", count = 10})
    util.log("logistics autotest: factory #%d at %s recipe %s ok=%s, %d ingredients inserted, powered by the hub: %s",
      factory.unit_number, util.pos_str(factory.position), logistics.HAULER_KIT, tostring(ok), put,
      tostring(factory.electric_network_id ~= nil and factory.electric_network_id == (parts.pole and parts.pole.electric_network_id)))
  end
  -- speed probe: a claimed walker (the AI army leaves non-idle units alone) and a parked hauler
  local from = {x = hub.position.x + AT.speed_from.x, y = hub.position.y + AT.speed_from.y}
  local walker, wrec = units.spawn("rts-walker", from, force, "walker", surface)
  local probe = logistics.spawn_hauler(surface, {x = from.x, y = from.y + 6}, force, hub_un)
  if walker and probe then
    wrec.order = "autotest-speed"
    T.speed = {walker = walker.unit_number, hauler = probe.unit_number, tick = game.tick,
               walker_from = walker.position, hauler_from = probe.position}
    walker.commandable.set_command({type = defines.command.go_to_location, radius = 1,
      destination = {x = walker.position.x + AT.speed_tiles, y = walker.position.y},
      distraction = defines.distraction.none})
    logistics.move_hauler(probe.unit_number, {x = probe.position.x + AT.speed_tiles, y = probe.position.y})
  end
  T.t0 = game.tick
  T.stage = "auto"
end

-- Speed probe: arrival ticks of the walker (on_ai_command_completed) and the parked hauler (on_spider_command_completed).
local function at_speed(T, tick)
  local S = T.speed
  if not S or S.done then return end
  local probe = logistics.hauler(S.hauler)
  if probe and not S.hauler_tick and probe.state == "parked" and probe.entity.autopilot_destination == nil
     and util.distance(probe.entity.position, S.hauler_from) >= AT.speed_tiles - 2 then
    S.hauler_tick = tick
  end
  local walker = storage.units[S.walker] and storage.units[S.walker].entity
  if walker and walker.valid and not S.walker_tick and util.distance(walker.position, S.walker_from) >= AT.speed_tiles - 2 then
    S.walker_tick = tick
  end
  if (S.walker_tick and S.hauler_tick) or tick - S.tick > AT.speed_window then
    S.done = true
    local ws = S.walker_tick and AT.speed_tiles / ((S.walker_tick - S.tick) / 60) or 0
    local hs = S.hauler_tick and AT.speed_tiles / ((S.hauler_tick - S.tick) / 60) or 0
    at_check(T, "logistics_hauler_speed", ws > 0 and hs >= 1.8 * ws,
      "%d tiles from a standing start: walker %.2f s = %.1f tiles/s, hauler %.2f s = %.1f tiles/s, ratio %.2f",
      AT.speed_tiles, S.walker_tick and (S.walker_tick - S.tick) / 60 or -1, ws,
      S.hauler_tick and (S.hauler_tick - S.tick) / 60 or -1, hs, ws > 0 and hs / ws or 0)
    if walker and walker.valid then walker.destroy() end
    if probe then probe.entity.destroy() end
  end
end

events.on(defines.events.on_ai_command_completed, function(e)
  local L = storage.logistics
  local S = L and L.autotest and L.autotest.speed
  if S and e.unit_number == S.walker and not S.walker_tick then S.walker_tick = e.tick end
end)

events.on(defines.events.on_spider_command_completed, function(e)
  local L = storage.logistics
  local S = L and L.autotest and L.autotest.speed
  if S and e.vehicle and e.vehicle.valid and e.vehicle.unit_number == S.hauler and not S.hauler_tick
     and util.distance(e.vehicle.position, S.hauler_from) >= AT.speed_tiles - 2 then
    S.hauler_tick = e.tick -- the last waypoint (routes have several)
  end
end)

local function at_auto(T, tick)
  local h1 = logistics.hauler(T.h1)
  local delivered = h1 and h1.delivered and h1.delivered["iron-plate"] or 0
  local he = logistics.entry_for_hub(T.hub)
  local hub_iron = he and he.network.get_item_count("iron-plate") or 0
  if (tick - T.t0) % 600 < 60 then
    util.log("logistics autotest: %.0fs h1 %s state=%s cargo=%s delivered iron=%d, hub iron=%d", (tick - T.t0) / 60,
      tostring(T.h1), h1 and h1.state or "gone", h1 and serpent.line(h1.cargo or {}) or "-", delivered, hub_iron)
  end
  if not T.delivered_done and delivered >= AT.deliver_iron then
    T.delivered_done = true
    at_check(T, "logistics_auto_delivery", hub_iron >= AT.deliver_iron,
      "hauler #%d delivered %d iron to hub #%d after %.1f s, hub network iron %d", T.h1, delivered, T.hub,
      (tick - T.t0) / 60, hub_iron)
  elseif not T.delivered_done and tick - T.t0 > AT.deliver_window then
    T.delivered_done = true
    at_check(T, "logistics_auto_delivery", false, "only %d iron delivered in %.0f s (state %s)", delivered,
      AT.deliver_window / 60, h1 and h1.state or "gone")
  end
  if not T.kit_done then
    for un, h in logistics.haulers_of(util.PLAYER_FORCE) do
      if un ~= T.h1 and un ~= (T.speed and T.speed.hauler) and h.created >= T.t0 then
        T.kit_done, T.h2 = true, un
        local f = buildings.get(T.factory)
        local out = f and f.entity.get_output_inventory()
        local net = f and production.network_for(f.entity)
        at_check(T, "logistics_kit_deploy", f ~= nil and util.distance(h.entity.position, f.entity.position) < 12
          and out.get_item_count(logistics.HAULER_KIT) == 0 and (not net or net.get_item_count(logistics.HAULER_KIT) == 0),
          "hauler #%d deployed %.1f tiles from factory #%s after %.1f s, home hub #%s, kits left in output %d",
          un, f and util.distance(h.entity.position, f.entity.position) or -1, tostring(T.factory), (tick - T.t0) / 60,
          tostring(h.home), out and out.get_item_count(logistics.HAULER_KIT) or -1)
        if f then production.set_recipe(f.entity, nil) end
        break
      end
    end
    if not T.kit_done and tick - T.t0 > AT.kit_window then
      T.kit_done = true
      at_check(T, "logistics_kit_deploy", false, "no hauler from the factory after %.0f s", AT.kit_window / 60)
    end
  end
  if T.delivered_done and T.kit_done then T.stage = "orders" end
end

local function area_at(pos, r)
  r = r or 0.01
  return {left_top = {x = pos.x - r, y = pos.y - r}, right_bottom = {x = pos.x + r, y = pos.y + r}}
end

local function at_orders(T)
  local h2 = logistics.hauler(T.h2)
  local hub, cc = buildings.get(T.hub), buildings.get(T.cc)
  if not (h2 and hub and cc) then
    at_check(T, "logistics_route_orders", false, "missing hauler 2 (%s), hub or CC", tostring(T.h2))
    T.stage = "done"
    return
  end
  local P = AT.player
  -- move: right click on the ground with only a hauler selected
  selection.set(P, {h2.entity})
  local ground = {x = hub.entity.position.x + 10, y = hub.entity.position.y + 8}
  local order, n = orders.handle_reverse_area(P, {}, area_at(ground), false)
  local dest = h2.dest
  at_check(T, "logistics_move_order", order == "hauler-move" and n == 1 and h2.state == "parked" and dest ~= nil
    and util.distance(dest, ground) < 0.5 and (h2.path_req ~= nil or h2.entity.autopilot_destination ~= nil),
    "order=%s n=%s state=%s dest=%s route %s", tostring(order), tostring(n), h2.state, util.pos_str(dest),
    h2.path_req and "requested" or "set")
  -- route: Shift + right click on the hub (drop-off), right click on the CC (pickup)
  local o1 = orders.handle_reverse_area(P, {hub.entity}, area_at(hub.entity.position), true)
  local o2 = orders.handle_reverse_area(P, {cc.entity}, area_at(cc.entity.position), false)
  at_check(T, "logistics_route_orders", o1 == "route-dropoff" and o2 == "route-pickup" and h2.mode == "manual"
    and h2.pickup == T.cc and h2.dropoff == T.hub and h2.state == "to_pickup",
    "orders %s, %s -> mode=%s pickup=#%s dropoff=#%s state=%s", tostring(o1), tostring(o2), h2.mode,
    tostring(h2.pickup), tostring(h2.dropoff), h2.state)
  selection.clear(P)
  -- a hauler death raises the alert
  local h1 = logistics.hauler(T.h1)
  local before = #alerts()
  if h1 then h1.entity.die() end
  local last = alerts()[#alerts()]
  at_check(T, "logistics_hauler_lost", h1 ~= nil and #alerts() == before + 1 and last.kind == "hauler-lost"
    and last.tick == game.tick and storage.logistics.haulers[T.h1] == nil and storage.units[T.h1] == nil
    and logistics.stats(util.PLAYER_FORCE).lost >= 1,
    "alerts %d -> %d, last kind=%s force=%s at %s; hauler record gone=%s, unit record gone=%s", before, #alerts(),
    last and last.kind or "-", last and last.force or "-", last and util.pos_str(last.position) or "-",
    tostring(storage.logistics.haulers[T.h1] == nil), tostring(storage.units[T.h1] == nil))
  -- manual route item: copper from the CC (export everything above 0) to the hub (keep 60)
  logistics.set_policy(T.cc, "export_above", "copper-plate", 0)
  logistics.set_policy(T.hub, "keep", "copper-plate", 60)
  local net = cc.entity.logistic_network
  net.insert({name = "copper-plate", count = 100})
  T.t1 = game.tick
  T.stage = "manual"
end

local function at_manual(T, tick)
  local h2 = logistics.hauler(T.h2)
  local copper = h2 and h2.delivered and h2.delivered["copper-plate"] or 0
  if (tick - T.t1) % 600 < 60 then
    util.log("logistics autotest: manual %.0fs h2 state=%s cargo=%s delivered copper=%d", (tick - T.t1) / 60,
      h2 and h2.state or "gone", h2 and serpent.line(h2.cargo or {}) or "-", copper)
  end
  if copper >= AT.manual_copper then
    local he = logistics.entry_for_hub(T.hub)
    at_check(T, "logistics_manual_route", true, "hauler #%d carried %d copper CC -> hub in %.1f s (hub copper %d)",
      T.h2, copper, (tick - T.t1) / 60, he and he.network.get_item_count("copper-plate") or -1)
    T.stage = "moat_setup"
  elseif tick - T.t1 > AT.manual_window or not h2 then
    at_check(T, "logistics_manual_route", false, "%d copper after %.0f s (state %s)", copper, (tick - T.t1) / 60,
      h2 and h2.state or "gone")
    T.stage = "moat_setup"
  end
end

-- Land route stage: water band with a gap between hub S (exports iron) and hub T (keeps iron), an auto hauler at T.
local function at_moat_setup(T)
  local force = util.PLAYER_FORCE
  local cc = buildings.main_cc(force)
  local surface = cc.entity.surface
  local c = cc.entity.position
  local half = (storage.match and storage.match.arena_half) or 128
  local x0, x1 = math.max(-half, math.floor(c.x + AT.moat_cols[1])), math.min(half, math.floor(c.x + AT.moat_cols[2]))
  local y0, y1 = math.floor(c.y + AT.moat_rows[1]), math.floor(c.y + AT.moat_rows[2])
  local g0, g1 = math.floor(c.x + AT.moat_gap[1]), math.floor(c.x + AT.moat_gap[2])
  for cx = math.floor(x0 / 32), math.floor((x1 - 1) / 32) do
    for cy = math.floor(y0 / 32), math.floor((y1 - 1) / 32) do surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end
  end
  surface.force_generate_chunk_requests()
  local tiles = {}
  for x = x0, x1 - 1 do
    if x < g0 or x >= g1 then
      for y = y0, y1 - 1 do tiles[#tiles + 1] = {name = "water", position = {x, y}} end
    end
  end
  surface.set_tiles(tiles, true, true)
  T.moat = {x0 = x0, x1 = x1, y0 = y0, y1 = y1, g0 = g0, g1 = g1, inside = 0, outside = 0, min_x = nil, max_x = nil}
  local function hub_at(off)
    local want = {x = c.x + off.x, y = c.y + off.y}
    local pos = surface.find_non_colliding_position(logistics.HUB, want, 8, 1, true) or want
    return surface.create_entity({name = logistics.HUB, position = pos, force = force, raise_built = true})
  end
  local src, dst = hub_at(AT.moat_src), hub_at(AT.moat_dst)
  if not (src and dst) then
    at_check(T, "logistics_moat_route", false, "could not place the moat hubs")
    T.stage = "done"
    return
  end
  T.moat.src, T.moat.dst = src.unit_number, dst.unit_number
  for _, item in ipairs({"iron-plate", "copper-plate"}) do
    logistics.set_policy(src.unit_number, "keep", item, nil)
    logistics.set_policy(dst.unit_number, "keep", item, nil)
  end
  logistics.set_policy(src.unit_number, "export_above", "iron-plate", 0)
  logistics.set_policy(dst.unit_number, "keep", "iron-plate", AT.moat_deliver)
  local put = src.logistic_network and src.logistic_network.insert({name = "iron-plate", count = AT.moat_iron}) or 0
  local entity = logistics.spawn_hauler(surface, logistics.approach_point(dst.unit_number), force, dst.unit_number)
  T.moat.hauler = entity and entity.unit_number
  local straight_len = util.distance(logistics.approach_point(src.unit_number), logistics.approach_point(dst.unit_number))
  T.moat.straight = straight_len
  util.log("logistics autotest: moat %d water tiles x [%d, %d) y [%d, %d), land gap x [%d, %d); source hub #%d at %s "
    .. "(%d iron), target hub #%d at %s, hauler #%s; straight line %.1f tiles", #tiles, x0, x1, y0, y1, g0, g1,
    src.unit_number, util.pos_str(src.position), put, dst.unit_number, util.pos_str(dst.position),
    tostring(T.moat.hauler), straight_len)
  T.t2 = game.tick
  T.stage = "moat"
end

local function at_moat(T, tick)
  local M = T.moat
  local h = logistics.hauler(M.hauler)
  if h and not M.route and h.state == "to_pickup" and h.route and h.route.source ~= "straight" then
    M.route = {n = h.route.n, length = h.route.length, source = h.route.source, tick = tick}
  end
  local iron = h and h.delivered and h.delivered["iron-plate"] or 0
  if iron >= AT.moat_deliver or not h or tick - T.t2 > AT.moat_window then
    local r = M.route
    at_check(T, "logistics_moat_route", r ~= nil and r.length > M.straight + 5,
      "route to the source: %s, %d waypoints, %.1f tiles against %.1f straight", r and r.source or "none", r and r.n or 0,
      r and r.length or 0, M.straight)
    at_check(T, "logistics_moat_gap", M.inside > 0 and M.outside == 0,
      "%d ticks in the band's interior rows, all within x [%d, %d): %s (x %.1f to %.1f)", M.inside, M.g0, M.g1,
      tostring(M.outside == 0), M.min_x or 0, M.max_x or 0)
    at_check(T, "logistics_moat_delivery", iron >= AT.moat_deliver,
      "hauler #%s delivered %d iron across the moat in %.1f s (trips %d)", tostring(M.hauler), iron, (tick - T.t2) / 60,
      h and h.trips or 0)
    T.stage = "done"
  end
end

-- Every tick of the moat stage: where the hauler crosses the band rows.
events.on(defines.events.on_tick, function()
  local L = storage.logistics
  local T = L and L.autotest
  if not (T and T.stage == "moat" and T.moat) then return end
  local M = T.moat
  local h = L.haulers[M.hauler]
  if not (h and h.entity.valid) then return end
  local p = h.entity.position
  if p.y >= M.y0 + 2 and p.y < M.y1 - 2 then -- the band's interior: walking along its edge is not a crossing
    M.inside = M.inside + 1
    M.min_x = math.min(M.min_x or p.x, p.x)
    M.max_x = math.max(M.max_x or p.x, p.x)
    if p.x < M.g0 or p.x >= M.g1 then M.outside = M.outside + 1 end
  end
end)

events.on_nth_tick(60, function(e)
  if not at_enabled() then return end
  local L = lstate()
  local T = L.autotest
  if not T then
    if not (storage.match and storage.match.phase == "running" and buildings.main_cc(util.PLAYER_FORCE)) then return end
    T = {stage = "setup", checks = {pass = 0, fail = 0}}
    L.autotest = T
    util.log("logistics autotest: start at tick %d", e.tick)
  end
  at_speed(T, e.tick)
  if T.stage == "setup" then
    at_setup(T)
  elseif T.stage == "auto" then
    at_auto(T, e.tick)
  elseif T.stage == "orders" then
    at_orders(T)
  elseif T.stage == "manual" then
    at_manual(T, e.tick)
  elseif T.stage == "moat_setup" then
    at_moat_setup(T)
  elseif T.stage == "moat" then
    at_moat(T, e.tick)
  elseif T.stage == "done" and not T.summary and (not T.speed or T.speed.done) then
    T.summary = true
    local s = logistics.stats(util.PLAYER_FORCE)
    util.log("logistics autotest: stats trips=%d deployed=%d lost=%d delivered %s", s.trips, s.deployed, s.lost,
      serpent.line(s.delivered))
    util.log("logistics autotest summary %d/%d%s", T.checks.pass, T.checks.pass + T.checks.fail,
      T.checks.fail == 0 and " (all passed)" or string.format(" (%d FAILED)", T.checks.fail))
  end
end)

return logistics
