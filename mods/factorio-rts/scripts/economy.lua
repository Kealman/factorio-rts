-- Economy summaries per force for the HUD and the console (docs/PHASE2.md "Resource HUD").
--
-- economy.snapshot(force_name) returns a table that is recomputed at most every CACHE_TICKS ticks and kept in
-- storage.economy.cache[force_name] (the HUD reads it from GUI code, so the cache must be game state):
--   iron, copper, steel, stone, magazines   item counts in the force's CC logistic networks
--   items              {[item name] = count} for everything in those networks (all qualities summed)
--   bots_total, bots_idle                   construction + logistic robots, all / available for a job
--   construction_total, construction_idle, logistic_total, logistic_idle
--   power_demand       W actually drawn from the CC electric networks (5 s average, network statistics)
--   power_production   W actually produced (5 s average)
--   power_capacity     W available: 4 MW per CC core + the maximum output of every solar array on those networks
--                      (the arena is always_day, so a solar array always gives its maximum)
--   power_satisfaction 0..1: average fill of the electric buffers of the force's working consumers
--                      (extractor, smelter, barracks, factory) on those networks; 1 when there are none
--   networks           number of distinct logistic networks counted
--   tick               game tick the snapshot was computed at
-- Everything is 0 for a force without a CC.
local buildings = require("scripts.buildings")

local economy = {}

economy.CACHE_TICKS = 30
economy.ITEMS = {iron = "iron-plate", copper = "copper-plate", steel = "steel-plate", stone = "stone",
                 magazines = "firearm-magazine"}
local CONSUMERS = {extractor = true, smelter = true, barracks = true, factory = true}

function economy.init()
  storage.economy = storage.economy or {}
  storage.economy.cache = storage.economy.cache or {}
end

--- Distinct logistic networks of the force's CCs: array of LuaLogisticNetwork.
function economy.networks(force_name)
  local list, seen = {}, {}
  for _, rec in buildings.for_force(force_name, "cc") do
    local net = rec.entity.logistic_network
    if net and net.valid and not seen[net.network_id] then
      seen[net.network_id] = true
      list[#list + 1] = net
    end
  end
  return list
end

--- The logistic network of the force's main (first) CC, or nil.
function economy.network(force_name)
  local cc = buildings.main_cc(force_name)
  local net = cc and cc.entity.logistic_network
  return (net and net.valid) and net or nil
end

--- Put items into the force's resource pool (the main CC's network storage, else its stockpiles).
--- Returns the number inserted.
function economy.give(force_name, item, count)
  local net = economy.network(force_name)
  local done = 0
  if net then done = net.insert({name = item, count = count}) end
  if done < count then
    for _, rec in buildings.for_force(force_name, "stockpile") do
      done = done + rec.entity.insert({name = item, count = count - done})
      if done >= count then break end
    end
  end
  return done
end

--- Take up to `count` items from the force's resource pool. Returns the number removed.
function economy.take(force_name, item, count)
  local done = 0
  for _, net in ipairs(economy.networks(force_name)) do
    done = done + net.remove_item({name = item, count = count - done})
    if done >= count then break end
  end
  return done
end

local function sum_flows(stats, counts, category)
  local total = 0
  for name in pairs(counts) do
    total = total + stats.get_flow_count({name = name, category = category,
                                          precision_index = defines.flow_precision_index.five_seconds})
  end
  return total * 60 -- electric flows are per tick (J/tick) -> W
end

local function compute(force_name)
  local snap = {iron = 0, copper = 0, steel = 0, stone = 0, magazines = 0, items = {},
                bots_total = 0, bots_idle = 0, construction_total = 0, construction_idle = 0,
                logistic_total = 0, logistic_idle = 0,
                power_demand = 0, power_production = 0, power_capacity = 0, power_satisfaction = 1,
                networks = 0, tick = game.tick}
  local nets = economy.networks(force_name)
  snap.networks = #nets
  for _, net in ipairs(nets) do
    for _, item in pairs(net.get_contents()) do
      snap.items[item.name] = (snap.items[item.name] or 0) + item.count
    end
    snap.construction_total = snap.construction_total + net.all_construction_robots
    snap.construction_idle = snap.construction_idle + net.available_construction_robots
    snap.logistic_total = snap.logistic_total + net.all_logistic_robots
    snap.logistic_idle = snap.logistic_idle + net.available_logistic_robots
  end
  for key, name in pairs(economy.ITEMS) do snap[key] = snap.items[name] or 0 end
  snap.bots_total = snap.construction_total + snap.logistic_total
  snap.bots_idle = snap.construction_idle + snap.logistic_idle

  -- Power: one sample per distinct electric network that carries a CC core.
  local grids = {}
  for _, rec in buildings.for_force(force_name, "cc") do
    local parts = buildings.core_parts(rec)
    local pole, power = parts.pole, parts.power
    if pole and pole.valid then
      local id = pole.electric_network_id
      if id and not grids[id] then
        grids[id] = true
        local stats = pole.electric_network_statistics
        snap.power_demand = snap.power_demand + sum_flows(stats, stats.input_counts, "input")
        snap.power_production = snap.power_production + sum_flows(stats, stats.output_counts, "output")
      end
      if power and power.valid then snap.power_capacity = snap.power_capacity + power.power_production * 60 end
    end
  end
  local fill, n = 0, 0
  for _, rec in buildings.for_force(force_name) do
    local e = rec.entity
    local id = e.electric_network_id
    if id and grids[id] then
      if rec.kind == "solar" then
        snap.power_capacity = snap.power_capacity + e.prototype.get_max_energy_production(e.quality) * 60
      elseif CONSUMERS[rec.kind] then
        local size = e.electric_buffer_size
        local status = e.status
        if size and size > 0 and (status == defines.entity_status.working
                                  or status == defines.entity_status.low_power) then
          fill = fill + math.min(1, e.energy / size)
          n = n + 1
        end
      end
    end
  end
  if n > 0 then snap.power_satisfaction = fill / n end
  return snap
end

--- Cached economy summary of a force (see the header for the fields).
function economy.snapshot(force_name)
  local cache = storage.economy.cache
  local snap = cache[force_name]
  if snap and game.tick - snap.tick < economy.CACHE_TICKS and game.tick >= snap.tick then return snap end
  snap = compute(force_name)
  cache[force_name] = snap
  return snap
end

local function mw(w) return w / 1e6 end

--- One-line summary for game.print / the HUD.
function economy.describe(force_name)
  local s = economy.snapshot(force_name)
  if s.networks == 0 then return string.format("%s: no command center network", force_name) end
  return string.format("%s: iron %d, copper %d, steel %d, stone %d, magazines %d | bots %d idle / %d | "
    .. "power %.2f / %.2f MW, satisfaction %.0f%%", force_name, s.iron, s.copper, s.steel, s.stone, s.magazines,
    s.bots_idle, s.bots_total, mw(s.power_demand), mw(s.power_capacity), s.power_satisfaction * 100)
end

--- Debug: the raw electric flows of the force's first CC network, by prototype name (W).
function economy.power_lines(force_name)
  local cc = buildings.main_cc(force_name)
  local pole = cc and buildings.core_parts(cc).pole
  if not (pole and pole.valid) then return {} end
  local stats = pole.electric_network_statistics
  local lines = {}
  for _, cat in ipairs({"input", "output"}) do
    local parts = {}
    for name in pairs(cat == "input" and stats.input_counts or stats.output_counts) do
      local w = stats.get_flow_count({name = name, category = cat,
                                      precision_index = defines.flow_precision_index.five_seconds}) * 60
      parts[#parts + 1] = string.format("%s=%.0fkW", name, w / 1000)
    end
    table.sort(parts)
    lines[#lines + 1] = string.format("%s %s: %s", force_name, cat, table.concat(parts, " "))
  end
  return lines
end

return economy
