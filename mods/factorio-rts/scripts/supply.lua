-- Supply cap (docs/PHASE4.md section 1 "Supply cap"; docs/qa/phase4-research-notes.md "Supply").
--
--   cap  = CC_CAP when the force has a live Command Center
--        + HUB_CAP per live hub (buildings kind "hub", registered by the logistics module)
--        + research bonus (storage.research.supply_bonus[force], written by scripts/research.lua: Supply I/II)
--   used = sum of supply.cost(name) over the force's live registered units (storage.units)
--
-- Unit cost: balance.lua at the mod root (content agent) units[name].supply when it exists, else FALLBACK; a "-mk2"
-- variant costs what its base unit costs; any other registered unit costs DEFAULT_COST.
-- production.lua asks before it turns a kit into a unit (research.gate -> supply.can_spawn); a refused kit stays in
-- the barracks output and is retried by production's 60-tick sweep, so a freed slot is used within a second.
--
-- Owns storage.supply = {last_alert = {[force] = tick}}. Alerts go to the shared storage.alerts list in the format of
-- scripts/logistics.lua (logistics.alert): {tick, force, kind, position?, text = locale key} plus `params` = the
-- key's parameters, oldest first, at most ALERTS_MAX. Kinds written here: "supply-blocked", "unit-locked",
-- "research-complete". Display: {entry.text, table.unpack(entry.params or {})}.
local util = require("scripts.util")
local units = require("scripts.units")
local buildings = require("scripts.buildings")

local supply = {}

supply.CC_CAP = 40 -- balance.buildings["rts-command-center"].supply_provided when present
supply.HUB_CAP = 10
supply.DEFAULT_COST = 1
supply.ALERTS_MAX = 100 -- logistics.MAX_ALERTS
supply.ALERT_PERIOD = 30 * 60 -- at most one "supply blocked" alert per force in this many ticks

-- Used until balance.lua exists (docs/PHASE4.md section 3: walker 1, drone 1, heavy 3, raider 2, artillery 4).
supply.FALLBACK = {
  ["rts-walker"] = 1,
  ["rts-drone"] = 1,
  ["rts-walker-heavy"] = 3,
  ["rts-raider"] = 2,
  ["rts-artillery"] = 4,
  ["rts-hauler"] = 1,
  ["rts-commander"] = 0,
}

local balance
do
  local ok, mod = pcall(require, "balance")
  if ok and type(mod) == "table" then balance = mod end
end
supply.has_balance = balance ~= nil
do
  local cc = balance and balance.buildings and balance.buildings["rts-command-center"]
  if cc and type(cc.supply_provided) == "number" then supply.CC_CAP = cc.supply_provided end
end

local cost_cache = {} -- derived from static data only, identical on every client

--- Supply cost of one unit of this prototype name.
function supply.cost(name)
  local c = cost_cache[name]
  if c then return c end
  local function lookup(n)
    local b = balance and balance.units and balance.units[n]
    if type(b) == "table" and type(b.supply) == "number" then return b.supply end
    return supply.FALLBACK[n]
  end
  c = lookup(name)
  if not c then
    local base = string.match(name, "^(.*)%-mk%d+$")
    c = base and lookup(base)
  end
  c = c or supply.DEFAULT_COST
  cost_cache[name] = c
  return c
end

function supply.init()
  storage.supply = storage.supply or {}
  storage.supply.last_alert = storage.supply.last_alert or {}
  storage.alerts = storage.alerts or {}
end

--- Supply used by the force's live units.
function supply.used(force_name)
  local n = 0
  for _, rec in units.for_force(force_name) do n = n + supply.cost(rec.entity.name) end
  return n
end

--- Supply cap of the force (see the header).
function supply.cap(force_name)
  local cap = 0
  if buildings.main_cc(force_name) then cap = supply.CC_CAP end
  cap = cap + supply.HUB_CAP * buildings.count(force_name, "hub")
  local r = storage.research
  local bonus = r and r.supply_bonus and r.supply_bonus[force_name]
  return cap + (bonus or 0)
end

--- {used = n, cap = n} for the HUD strip ("40/60").
function supply.get(force_name)
  return {used = supply.used(force_name), cap = supply.cap(force_name)}
end

--- True when one more `unit_name` fits under the cap. Also returns used and cap.
function supply.can_spawn(force_name, unit_name)
  local used, cap = supply.used(force_name), supply.cap(force_name)
  local cost = supply.cost(unit_name)
  return cost <= 0 or used + cost <= cap, used, cap
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------
--- Append an alert to storage.alerts (logistics.alert format plus params). `text` is a locale key.
function supply.alert(force_name, kind, text, params, position)
  local list = storage.alerts
  if not list then
    list = {}
    storage.alerts = list
  end
  list[#list + 1] = {tick = game.tick, force = force_name, kind = kind, text = text, params = params,
                     position = position and {x = position.x, y = position.y} or nil}
  while #list > supply.ALERTS_MAX do table.remove(list, 1) end
end

--- A kit could not become a unit because of the cap: alert + chat line, at most once per ALERT_PERIOD per force.
function supply.blocked(force_name, unit_name, position, used, cap)
  local s = storage.supply
  local last = s.last_alert[force_name]
  if last and game.tick - last < supply.ALERT_PERIOD then return false end
  s.last_alert[force_name] = game.tick
  local params = {used, cap, {"entity-name." .. unit_name}}
  supply.alert(force_name, "supply-blocked", "rts.alert-supply-blocked", params, position)
  local force = game.forces[force_name]
  if force then force.print({"rts.alert-supply-blocked", used, cap, {"entity-name." .. unit_name}}) end
  util.log("supply: %s blocked: %s needs %d, %d/%d used", force_name, unit_name, supply.cost(unit_name), used, cap)
  return true
end

return supply
