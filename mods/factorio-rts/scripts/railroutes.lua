-- 0.1.2 (#31 part B; docs/qa/release-0-1-2-r3-rails-notes.md): multi-stop train schedules. Nation mode only (trains
-- exist in Nation mode only).
--
-- A train on a stop list (rec.stops on its rails.lua record) runs a native engine schedule: one record per stop (the
-- depot's stop name, or a rail for a rail stop) with the vanilla wait conditions of that stop, so A -> B -> C -> B
-- loops by itself, several trains share the track and vanilla path finding picks the way through junctions. The script
-- does what the engine cannot do with our depots: at a depot stop it moves goods between the depot's logistic network
-- and the cargo wagons by the stop's policies (unload first, then load; balance.nation.rails.transfer_rate items per
-- second per wagon through logistics.transfer) and writes LuaSchedule.tick_of_last_activity whenever goods move, so
-- "cargo idle for N s" counts the script's transfers like inserters; troops board or get off (scripts/garrison.lua);
-- an artillery wagon bombards at a stop marked so (scripts/trainswar.lua). Locomotives refuel at every depot stop.
-- The AI keeps rails.set_route (two script-driven records, rails.lua's dwell_step): its trains have no rec.stops.
--
-- Stop = {target = depot unit number | nil, rail = LuaEntity | nil (a rail stop: trains with troop or artillery
--         wagons), x, y (where the stop is, for the panel),
--         unload = nil | "keep" | "all" | "items", unload_items = {[item] = n (0 = all of it)},
--         load = nil | "exports" | "items", load_items = {[item] = n (wanted aboard; 0 = as much as fits)},
--         troops = nil | "board" | "unload", bombard = true | nil,
--         wait = {type = "inactivity" | "full" | "empty" | "time" | "item_count", seconds, item, count, cmp}}
-- Policies at a depot stop:
--   unload "keep"    the network takes what its Keep still lacks; a network without any Keep takes everything (the
--                    0.1.1 drop-off rule)
--   unload "all"     everything aboard;  unload "items": the listed items, up to n each per visit (0 = all of it)
--   load "exports"   what the network exports above its threshold; when the next unloading stop is "keep" with Keep
--                    thresholds, only what that network still lacks (minus the cargo aboard and on its way: the 0.1.1
--                    pickup rule); when it is "items", only those items
--   load "items"     the listed items until the train holds n of each (0 = as much as fits), from what the network
--                    holds above its own Keep
-- Default wait: "cargo idle for 10 s" (vanilla inactivity); a bombard stop waits 60 s.
--
-- Record fields (storage.rails.trains[id]): stops, loop (false: the train halts after the last stop), rmap =
-- {[schedule record index] = stop index}, written (the train id the schedule was written for), writes (how often the
-- script wrote it: the engine runs the loop by itself, so it changes only on edits), halted, dwell =
-- {native = true, stop, depot, since, phase = "unload" | "load", uplan / lplan (what is left to move), uwant / lwant
-- and udone / ldone ({[item] = n}: planned and moved this visit), unext / lnext (ticks), unloaded_pass, unloaded,
-- loaded, reason ("full", "no-network"), boarded}. storage.rails.routes_v = migration version.
--
-- API:
--   railroutes.set(train, stops, loop) -> true | false, reason
--   railroutes.add(train, target, after) -> index | nil, reason   target = depot unit number or a rail entity; after =
--                                        insert after that stop index (nil: append)
--   railroutes.remove(train, i), railroutes.move(train, i, delta), railroutes.clear(train), railroutes.set_loop(train,
--   on), railroutes.update(train, i, fields) -> true | false   (fields: unload, load, troops, bombard, wait,
--   unload_items, load_items; a nil-valued key clears it through railroutes.NONE)
--   railroutes.stops(rec) -> the stop list ({} when none);  railroutes.caps(train) -> {cargo, troop, artillery, ...}
--   railroutes.status(rec, train) -> {index, count, stop, phase, item, done, want, state}
--   railroutes.targets(rec) -> {[depot un] = stop index}  (garrison.lua: troop trains coming to a depot)
--   railroutes.bombard_here(rec, train) -> bool  (trainswar.lua)
--   railroutes.selected_stop = fn(player_index, train_id) -> stop index | nil (railgui.lua: Shift + right click)
-- Log lines "[rts] rails: route ...".
local util = require("scripts.util")
local events = require("scripts.events")
local selection = require("scripts.selection")
local logistics = require("scripts.logistics")
local balance = require("balance")
local rails = require("scripts.rails")

local railroutes = {}
local CFG = balance.nation.rails
local TS = defines.train_state
local floor, min, max = math.floor, math.min, math.max

railroutes.PERIOD = rails.TRANSFER_PERIOD   -- transfer period, ticks
railroutes.MAX_STOPS = 16
railroutes.DEFAULT_WAIT = {type = "inactivity", seconds = 10}
railroutes.BOMBARD_WAIT = {type = "time", seconds = 60}
railroutes.REPLAN = 60                      -- a stop with nothing (more) to move looks again this often, ticks
railroutes.NONE = "none"                    -- update(): a field set to this is cleared
railroutes.UNLOAD = {"keep", "all", "items"}
railroutes.LOAD = {"exports", "items"}
railroutes.TROOPS = {"board", "unload"}
railroutes.WAITS = {"inactivity", "full", "empty", "time", "item_count"}
local ITEM_WAGONS = {[rails.WAGON] = true}
local TROOP_WAGONS = {[rails.TWAGON] = true, [rails.AWAGON] = true}
local RAIL_TYPES = {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail"}
local VALID = {unload = {}, load = {}, troops = {}, wait = {}}
for _, k in ipairs(railroutes.UNLOAD) do VALID.unload[k] = true end
for _, k in ipairs(railroutes.LOAD) do VALID.load[k] = true end
for _, k in ipairs(railroutes.TROOPS) do VALID.troops[k] = true end
for _, k in ipairs(railroutes.WAITS) do VALID.wait[k] = true end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

local function loaded(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

---------------------------------------------------------------------------
-- Stops
---------------------------------------------------------------------------
--- What the train's carriages can do: {cargo, troop, artillery, construction, loco} counts.
function railroutes.caps(train)
  local c = {cargo = 0, troop = 0, artillery = 0, construction = 0, loco = 0}
  if not (train and train.valid) then return c end
  for _, e in ipairs(train.carriages) do
    local n = e.name
    if ITEM_WAGONS[n] then c.cargo = c.cargo + 1
    elseif TROOP_WAGONS[n] then c.troop = c.troop + 1
    elseif n == rails.ARTY then c.artillery = c.artillery + 1
    elseif n == rails.CWAGON then c.construction = c.construction + 1
    elseif e.type == "locomotive" then c.loco = c.loco + 1 end
  end
  return c
end

function railroutes.stops(rec) return rec and rec.stops or {} end

-- The depot record of a stop when it is the train's force's and has a stop entity, else nil.
local function stop_depot(rec, stop)
  local d = stop.target and rails.depot(stop.target)
  if not (d and d.force == rec.force and d.platform) then return nil end
  for _, st in pairs(d.platform.stops or {}) do
    if st.valid then return d end
  end
  return nil
end
railroutes.stop_depot = stop_depot

local function secs(w, default)
  local n = tonumber(w and w.seconds) or default or 10
  return max(1, min(3600, floor(n)))
end

local function wait_conditions(stop)
  local w = stop.wait or railroutes.DEFAULT_WAIT
  local t = w.type
  if t == "full" then return {{type = "full"}} end
  if t == "empty" then return {{type = "empty"}} end
  if t == "time" then return {{type = "time", ticks = secs(w, 60) * 60}} end
  if t == "item_count" and w.item and prototypes.item[w.item] then
    return {{type = "item_count", condition = {first_signal = {type = "item", name = w.item},
      comparator = w.cmp == "<=" and "<=" or ">=", constant = max(0, floor(tonumber(w.count) or 0))}}}
  end
  return {{type = "inactivity", ticks = secs(w, 10) * 60}}
end
railroutes.wait_conditions = wait_conditions

-- The engine record of a stop ({station} or {rail}), or nil when the stop cannot be reached now.
local function record_spec(rec, stop)
  if stop.target then
    local d = stop_depot(rec, stop)
    if d then return {station = d.stop_name} end
    return nil
  end
  if stop.rail and stop.rail.valid then return {rail = stop.rail, temporary = false} end
  return nil
end

-- Write the engine schedule from the stop list and send the train on to the stop it was heading to (or the next one
-- that can be reached). Returns the number of records.
local function write(rec, train, why)
  local sch = train.get_schedule()
  local was = rec.rmap and rec.rmap[sch.current] or rec.next_stop
  sch.clear_records()
  local rmap, n, first_at = {}, 0, {}
  for i, stop in ipairs(rec.stops) do
    local spec = record_spec(rec, stop)
    if spec then
      spec.wait_conditions = wait_conditions(stop)
      local ok, idx = pcall(sch.add_record, spec)
      if ok and idx then
        n = n + 1
        rmap[idx] = i
        first_at[i] = idx
      else
        util.log("rails: route train %d: stop %d could not be written (%s)", train.id, i, tostring(idx))
      end
    end
  end
  rec.rmap, rec.written = rmap, train.id
  rec.writes = (rec.writes or 0) + 1
  rec.next_stop = nil
  if n == 0 then
    if not train.manual_mode then train.manual_mode = true end
    util.log("rails: route train %d (%s): %d stops, none reachable now (%s): stopped", train.id, rec.force, #rec.stops,
      why or "-")
    return 0
  end
  if rec.halted then
    train.manual_mode = true
    return n
  end
  -- the record of stop `was` or of the first reachable stop after it
  local go = 1
  if was then
    for k = 0, #rec.stops - 1 do
      local i = (was - 1 + k) % #rec.stops + 1
      if first_at[i] then
        go = first_at[i]
        break
      end
    end
  end
  -- (a train standing at that stop keeps standing there: its dwell goes on)
  local standing = train.state == TS.wait_station and rec.dwell and rec.dwell.stop == rmap[go] and sch.current == go
  if not standing then sch.go_to_station(go) end
  if train.manual_mode then train.manual_mode = false end
  util.log("rails: route train %d (%s): %d stops written (%d reachable), heading to stop %d (%s)", train.id, rec.force,
    #rec.stops, n, rmap[go] or 0, why or "-")
  return n
end
railroutes.write = write

local function start(rec)
  rec.loop = rec.loop ~= false
  rec.pickup, rec.dropoff, rec.lost_pickup, rec.lost_dropoff = nil, nil, nil, nil
  rec.position_rail, rec.war_state = nil, nil -- trainswar.lua's single orders
  rec.reason = nil
  local R = storage.rails
  if R and R.dwelling then R.dwelling[rec.id] = nil end
  if rec.dwell and not rec.dwell.native then rec.dwell = nil end
end

local function train_rec(train)
  local rec = rails.train_record(train)
  if not (rec and train and train.valid) then return nil end
  if rec.kind == "construction" then return nil end
  return rec
end

local function default_wait(stop)
  return copy(stop.bombard and railroutes.BOMBARD_WAIT or railroutes.DEFAULT_WAIT)
end

-- A new stop with the defaults for the train's carriages: the first stop of a list loads (cargo) and boards (troops),
-- the later ones unload to Keep and let troops out; a rail stop is a firing position for an artillery wagon.
local function new_stop(rec, train, target, rail, first)
  local caps = railroutes.caps(train)
  local stop = {target = target, rail = rail}
  if target then
    local d = rails.depot(target)
    local p = d and d.entity.valid and d.entity.position
    if p then stop.x, stop.y = p.x, p.y end
    if caps.cargo > 0 then
      if first then stop.load = "exports" else stop.unload = "keep" end
    end
    if caps.troop > 0 then stop.troops = first and "board" or "unload" end
  else
    stop.x, stop.y = rail.position.x, rail.position.y
    if caps.troop > 0 then stop.troops = "unload" end
    if caps.artillery > 0 then stop.bombard = true end
  end
  stop.wait = default_wait(stop)
  return stop
end

local function valid_stop(rec, stop)
  if type(stop) ~= "table" then return false end
  if stop.target then
    local d = rails.depot(stop.target)
    return d ~= nil and d.force == rec.force
  end
  return stop.rail ~= nil and stop.rail.valid
end

--- Replace the train's stop list. Returns true, or false and a reason ("no-train", "bad-stop", "too-many").
function railroutes.set(train, stops, loop)
  local rec = train_rec(train)
  if not rec then return false, "no-train" end
  if #stops > railroutes.MAX_STOPS then return false, "too-many" end
  local list = {}
  for i, st in ipairs(stops) do
    if not valid_stop(rec, st) then return false, "bad-stop" end
    local s = copy(st)
    s.rail = st.rail -- (entities are not copied)
    if s.target and not s.x then
      local d = rails.depot(s.target)
      if d and d.entity.valid then s.x, s.y = d.entity.position.x, d.entity.position.y end
    end
    if s.rail and not s.x then s.x, s.y = s.rail.position.x, s.rail.position.y end
    s.wait = s.wait or default_wait(s)
    list[i] = s
  end
  start(rec)
  rec.stops = list
  if loop ~= nil then rec.loop = loop and true or false end
  rec.halted = nil
  rec.rmap, rec.next_stop = nil, 1
  if rec.dwell and rec.dwell.native then rec.dwell = nil end
  write(rec, train, "set")
  util.log("rails: route train %d (%s) set: %d stops%s", train.id, rec.force, #list, rec.loop and "" or ", no loop")
  return true
end

--- Add a stop (a depot unit number or a rail entity) after stop `after` (nil: at the end). Returns its index or nil,
--- reason ("no-train", "bad-stop", "too-many", "no-rail-stops", "same-stop").
function railroutes.add(train, target, after)
  local rec = train_rec(train)
  if not rec then return nil, "no-train" end
  local stops = rec.stops or {}
  if #stops >= railroutes.MAX_STOPS then return nil, "too-many" end
  local dun, rail
  if type(target) == "number" then
    dun = target
    local d = rails.depot(dun)
    if not (d and d.force == rec.force) then return nil, "bad-stop" end
  elseif type(target) ~= "number" and target and target.valid and target.object_name == "LuaEntity" then
    rail = target
    local caps = railroutes.caps(train)
    if caps.troop == 0 and caps.artillery == 0 then return nil, "no-rail-stops" end
  else
    return nil, "bad-stop"
  end
  local at = (after and after >= 0 and after <= #stops) and after + 1 or #stops + 1
  -- the same depot twice in a row is no route
  local prev, nxt = stops[at - 1], stops[at]
  if dun and ((prev and prev.target == dun) or (nxt and nxt.target == dun and #stops > 1)) then
    return nil, "same-stop"
  end
  local stop = new_stop(rec, train, dun, rail, #stops == 0)
  local cur = rec.rmap and rec.rmap[train.get_schedule().current]
  start(rec)
  rec.stops = stops
  table.insert(stops, at, stop)
  rec.halted = nil
  -- the train keeps heading to the stop it was heading to (a new list starts at its first stop)
  if #stops == 1 or not cur then
    rec.next_stop = 1
  else
    rec.next_stop = (cur >= at) and cur + 1 or cur
  end
  local d = rec.dwell
  if d and d.native and (d.stop or 0) >= at then d.stop = d.stop + 1 end
  rec.rmap = nil
  write(rec, train, "stop added")
  util.log("rails: route train %d (%s): stop %d of %d added: %s", train.id, rec.force, at, #stops,
    dun and string.format("depot #%d", dun) or ("rail at " .. util.pos_str(rail.position)))
  return at
end

local function edited(rec, train, why)
  local R = storage.rails
  if not (R and rec.stops) then return end
  if #rec.stops == 0 then
    local sch = train.get_schedule()
    sch.clear_records()
    train.manual_mode = true
    rec.rmap, rec.written = {}, train.id
    if rec.dwell and rec.dwell.native then rec.dwell = nil end
    util.log("rails: route train %d (%s): no stops left: stopped", train.id, rec.force)
    return
  end
  write(rec, train, why)
end

--- Remove stop i. Returns true when removed.
function railroutes.remove(train, i)
  local rec = train_rec(train)
  if not (rec and rec.stops and rec.stops[i]) then return false end
  table.remove(rec.stops, i)
  local d = rec.dwell
  if d and d.native then
    if d.stop == i then d.stop = nil elseif (d.stop or 0) > i then d.stop = d.stop - 1 end
  end
  -- the train heads on to the stop it was heading to, or to the one that followed the removed one
  local sch = train.get_schedule()
  local cur = rec.rmap and rec.rmap[sch.current]
  if cur then rec.next_stop = (cur > i) and cur - 1 or cur end
  if rec.next_stop and rec.next_stop > #rec.stops then rec.next_stop = 1 end
  rec.rmap = nil
  edited(rec, train, "stop removed")
  util.log("rails: route train %d (%s): stop %d removed, %d left", train.id, rec.force, i, #rec.stops)
  return true
end

--- Move stop i by delta (-1 up, +1 down). Returns the new index or nil.
function railroutes.move(train, i, delta)
  local rec = train_rec(train)
  local stops = rec and rec.stops
  local j = i + delta
  if not (stops and stops[i] and stops[j]) then return nil end
  local sch = train.get_schedule()
  local cur = rec.rmap and rec.rmap[sch.current]
  stops[i], stops[j] = stops[j], stops[i]
  if cur == i then rec.next_stop = j elseif cur == j then rec.next_stop = i else rec.next_stop = cur end
  if rec.dwell and rec.dwell.native then
    if rec.dwell.stop == i then rec.dwell.stop = j elseif rec.dwell.stop == j then rec.dwell.stop = i end
  end
  rec.rmap = nil
  edited(rec, train, "stop moved")
  util.log("rails: route train %d (%s): stop %d moved to %d", train.id, rec.force, i, j)
  return j
end

--- Remove every stop (the train stops).
function railroutes.clear(train)
  local rec = train_rec(train)
  if not (rec and rec.stops) then return false end
  rec.stops = {}
  rec.next_stop = nil
  edited(rec, train, "cleared")
  return true
end

--- Loop on (default) or off (the train halts after its last stop).
function railroutes.set_loop(train, on)
  local rec = train_rec(train)
  if not (rec and rec.stops) then return false end
  rec.loop = on and true or false
  if on and rec.halted then
    rec.halted = nil
    rec.next_stop = 1
    edited(rec, train, "loop on")
  end
  util.log("rails: route train %d (%s): loop %s", train.id, rec.force, tostring(rec.loop))
  return true
end

local function clean_items(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for item, n in pairs(t) do
    if type(item) == "string" and prototypes.item[item] then out[item] = max(0, floor(tonumber(n) or 0)) end
  end
  return out
end

--- Change fields of stop i: unload, load, troops (a value or railroutes.NONE), bombard (bool), wait = {type, seconds,
--- item, count, cmp}, unload_items / load_items = {[item] = n}. Returns true when changed.
function railroutes.update(train, i, fields)
  local rec = train_rec(train)
  local stop = rec and rec.stops and rec.stops[i]
  if not (stop and type(fields) == "table") then return false end
  local sched = false -- the wait changed: the engine record is written again
  for _, key in ipairs({"unload", "load", "troops"}) do
    local v = fields[key]
    if v == railroutes.NONE then
      stop[key] = nil
    elseif v ~= nil then
      if not VALID[key][v] then return false end
      if key ~= "troops" and not stop.target then return false end -- goods move at depots only
      stop[key] = v
    end
  end
  if fields.bombard ~= nil then stop.bombard = fields.bombard and true or nil end
  if fields.unload_items then stop.unload_items = clean_items(fields.unload_items) end
  if fields.load_items then stop.load_items = clean_items(fields.load_items) end
  if fields.wait then
    local w = fields.wait
    if not VALID.wait[w.type] then return false end
    local nw = {type = w.type, seconds = w.seconds, item = w.item, count = w.count, cmp = w.cmp}
    if nw.type == "item_count" and not (nw.item and prototypes.item[nw.item]) then
      nw.item = (stop.wait and stop.wait.item) or next(stop.load_items or {}) or next(stop.unload_items or {})
    end
    stop.wait = nw
    sched = true
  end
  if sched then edited(rec, train, "wait changed") end
  util.log("rails: route train %d (%s): stop %d now %s", train.id, rec.force, i, railroutes.describe(stop))
  return true
end

--- One line for logs: "depot #12 unload=keep load=exports wait=inactivity 10".
function railroutes.describe(stop)
  local parts = {stop.target and ("depot #" .. stop.target) or ("rail " .. util.pos_str({x = stop.x or 0,
    y = stop.y or 0}))}
  if stop.unload then
    local items = stop.unload == "items" and serpent.line(stop.unload_items or {}) or ""
    parts[#parts + 1] = "unload=" .. stop.unload .. items
  end
  if stop.load then
    parts[#parts + 1] = "load=" .. stop.load .. (stop.load == "items" and serpent.line(stop.load_items or {}) or "")
  end
  if stop.troops then parts[#parts + 1] = "troops=" .. stop.troops end
  if stop.bombard then parts[#parts + 1] = "bombard" end
  local w = stop.wait or railroutes.DEFAULT_WAIT
  parts[#parts + 1] = "wait=" .. w.type .. (w.seconds and (" " .. w.seconds) or "")
    .. (w.item and (" " .. w.item .. (w.cmp or ">=") .. tostring(w.count or 0)) or "")
  return table.concat(parts, " ")
end

--- Depots on the train's stop list: {[depot un] = first stop index}.
function railroutes.targets(rec)
  local out = {}
  for i, st in ipairs(rec and rec.stops or {}) do
    if st.target and not out[st.target] then out[st.target] = i end
  end
  return out
end

---------------------------------------------------------------------------
-- Goods at a stop
---------------------------------------------------------------------------
local function item_wagons(train)
  local list = {}
  for _, w in ipairs(train.cargo_wagons) do
    if ITEM_WAGONS[w.name] then list[#list + 1] = w end
  end
  return list
end

local function cargo_in(wagons)
  local out = {}
  for _, w in ipairs(wagons) do
    local inv = w.get_inventory(defines.inventory.cargo_wagon)
    for _, item in pairs(inv and inv.get_contents() or {}) do out[item.name] = (out[item.name] or 0) + item.count end
  end
  return out
end

-- The next stop after stop i (cyclic) that unloads at a depot, and its index.
local function next_unload(rec, i)
  local n = #rec.stops
  for k = 1, n do
    local j = (i - 1 + k) % n + 1
    local st = rec.stops[j]
    if st.unload and st.target then return st, j end
  end
  return nil
end

-- The next stop that unloads, counted from where the train heads now (its dwell stop or its schedule's current one).
local function heading_unload(rec, train)
  local i
  if rec.dwell and rec.dwell.native then i = rec.dwell.stop end
  if not i then
    local sch = train.get_schedule()
    i = rec.rmap and rec.rmap[sch.current]
    if i then i = i - 1 end
  end
  if not i or #rec.stops == 0 then return nil end
  if i < 1 then i = #rec.stops end
  return next_unload(rec, i)
end

-- Cargo on its way to network `net_id`: the 0.1.1 route trains (rails.inbound) and trains on stop lists whose next
-- unloading stop is in that network.
local function inbound(force_name, net_id, except_id)
  local out = rails.inbound(force_name, net_id, except_id)
  local R = storage.rails
  for _, id in ipairs(sorted_keys(R and R.trains)) do
    local rec = R.trains[id]
    if id ~= except_id and rec.force == force_name and rec.stops and #rec.stops > 0 then
      local train = rails.train_of(rec)
      if train and train.valid then
        local st = heading_unload(rec, train)
        local entry = st and logistics.entry_for_hub(st.target)
        if entry and entry.id == net_id then
          for item, n in pairs(cargo_in(item_wagons(train))) do out[item] = (out[item] or 0) + n end
        end
      end
    end
  end
  return out
end

local function unload_plan(stop, entry, aboard)
  local plan = {}
  local kind = stop.unload
  if kind == "all" then
    for item, n in pairs(aboard) do plan[item] = n end
  elseif kind == "items" then
    for item, want in pairs(stop.unload_items or {}) do
      local n = aboard[item] or 0
      if n > 0 then plan[item] = (want > 0) and min(n, want) or n end
    end
  elseif kind == "keep" then
    local any_keep = next(entry.keep) ~= nil
    for item, n in pairs(aboard) do
      if not any_keep then
        plan[item] = n
      else
        local keep = entry.keep[item]
        local lack = keep and (keep - entry.network.get_item_count(item)) or 0
        if lack > 0 then plan[item] = min(n, lack) end
      end
    end
  end
  return plan
end

local function load_plan(rec, train, stop, entry, aboard)
  local plan = {}
  if stop.load == "items" then
    for item, want in pairs(stop.load_items or {}) do
      local keep = entry.keep[item] or 0
      local avail = entry.network.get_item_count(item) - keep
      local n = (want > 0) and min(avail, want - (aboard[item] or 0)) or avail
      if n > 0 then plan[item] = n end
    end
  elseif stop.load == "exports" then
    local nxt = next_unload(rec, rec.dwell.stop)
    local dst = nxt and logistics.entry_for_hub(nxt.target)
    local keep_limit = dst and nxt.unload == "keep" and next(dst.keep) ~= nil
    if keep_limit and dst.id == entry.id then return plan end -- the same network: nothing to carry
    local inb = keep_limit and inbound(rec.force, dst.id, train.id) or {}
    for item, threshold in pairs(entry.export) do
      local avail = entry.network.get_item_count(item) - threshold
      if avail > 0 then
        local want = avail
        if keep_limit then
          local keep = dst.keep[item]
          want = keep and (keep - dst.network.get_item_count(item) - (inb[item] or 0) - (aboard[item] or 0)) or 0
        elseif nxt and nxt.unload == "items" then
          local n = (nxt.unload_items or {})[item]
          want = n and ((n > 0) and (n - (aboard[item] or 0)) or avail) or 0
        end
        local n = min(avail, want)
        if n > 0 then plan[item] = n end
      end
    end
  end
  return plan
end

-- Move up to `plan` between the wagons and the network at transfer_rate per wagon; `done` counts what moved. Returns
-- moved, left.
local function run_plan(plan, done, wagons, net, unloading, stats, rec, d)
  local budget0 = floor(CFG.transfer_rate * railroutes.PERIOD / 60)
  local items = sorted_keys(plan)
  local moved = 0
  for _, wagon in ipairs(wagons) do
    local inv = wagon.get_inventory(defines.inventory.cargo_wagon)
    local budget = budget0
    for _, item in ipairs(items) do
      local want = plan[item]
      if inv and want > 0 and budget > 0 then
        local n
        if unloading then
          local here = inv.get_item_count(item)
          n = here > 0 and logistics.transfer(inv, net, item, min(want, budget, here)) or 0
        else
          n = logistics.transfer(net, inv, item, min(want, budget))
        end
        if n > 0 then
          plan[item] = want - n
          done[item] = (done[item] or 0) + n
          budget = budget - n
          moved = moved + n
          if unloading then
            rec.delivered[item] = (rec.delivered[item] or 0) + n
            stats.delivered[item] = (stats.delivered[item] or 0) + n
            stats.items = stats.items + n
            d.unloaded = (d.unloaded or 0) + n
          else
            d.loaded = (d.loaded or 0) + n
          end
        end
      end
    end
  end
  local left = 0
  for _, n in pairs(plan) do left = left + max(0, n) end
  return moved, left
end

local function moved_text(t)
  local parts = {}
  for _, item in ipairs(sorted_keys(t)) do
    if t[item] > 0 then parts[#parts + 1] = string.format("%d %s", t[item], item) end
  end
  return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

-- Every PERIOD ticks while a train on a stop list stands at a stop. Goods: the unload plan is made once on arrival
-- (what the train brings), tried again every REPLAN ticks while the network has no room; loading starts after the
-- first unload pass and plans again every REPLAN ticks once its plan is done (new exports keep coming while the train
-- waits, as inserters would load them).
local function dwell(rec, train)
  local d = rec.dwell
  local stop = d.stop and rec.stops[d.stop]
  if not stop then return end
  local active = false
  -- troops: keep the train while divisions walk to it or board (garrison.lua boards them every POLL ticks)
  if stop.troops == "board" and d.depot then
    local garrison = loaded("garrison")
    local walking = garrison and garrison.embarking_count and garrison.embarking_count(rec.force, d.depot) or 0
    if walking > 0 or (rec.boarded_tick or 0) > (d.boarded or d.since) then
      d.boarded = rec.boarded_tick or d.boarded
      active = true
    end
  end
  if d.depot and (stop.unload or stop.load) then
    local net = logistics.hub_network(d.depot)
    local entry = net and logistics.entry_for_hub(d.depot)
    local wagons = entry and item_wagons(train) or {}
    if not entry then
      d.reason = "no-network"
    elseif #wagons > 0 then
      local stats = rails.stats(rec.force)
      local tick = game.tick
      if stop.unload then
        if not d.uplan then
          d.uplan = unload_plan(stop, entry, cargo_in(wagons))
          d.uwant, d.udone = copy(d.uplan), {}
        end
        if next(d.uplan) and tick >= (d.unext or 0) then
          d.phase = "unload"
          local moved, left = run_plan(d.uplan, d.udone, wagons, net, true, stats, rec, d)
          if moved > 0 then active = true end
          if left > 0 and moved == 0 then
            d.unext, d.reason = tick + railroutes.REPLAN, "full"
          elseif left <= 0 then
            d.reason = nil
            d.uplan = {}
            util.log("rails: route train %d unloaded %s at depot #%d (stop %d of %d)", train.id, moved_text(d.udone),
              d.depot, d.stop, #rec.stops)
          end
          if left <= 0 or moved == 0 then d.unloaded_pass = true end
        elseif not next(d.uplan) then
          d.unloaded_pass = true
        end
      end
      if stop.load and (not stop.unload or d.unloaded_pass) and tick >= (d.lnext or 0) then
        if not d.lplan then
          d.lplan = load_plan(rec, train, stop, entry, cargo_in(wagons))
          d.lwant, d.ldone = d.lwant or {}, d.ldone or {}
          for item, n in pairs(d.lplan) do d.lwant[item] = (d.ldone[item] or 0) + n end
        end
        local moved, left = 0, 0
        if next(d.lplan) then
          d.phase = "load"
          moved, left = run_plan(d.lplan, d.ldone, wagons, net, false, stats, rec, d)
        end
        if moved > 0 then active = true end
        if left <= 0 or moved == 0 then
          if (d.loaded or 0) > (d.logged or 0) then
            util.log("rails: route train %d loaded %s at depot #%d (stop %d of %d)", train.id, moved_text(d.ldone),
              d.depot, d.stop, #rec.stops)
            d.logged = d.loaded
          end
          d.lplan, d.lnext = nil, tick + railroutes.REPLAN
        end
      end
    end
  end
  if active then
    local sch = train.get_schedule()
    sch.tick_of_last_activity = game.tick
  end
end

---------------------------------------------------------------------------
-- Arrive, leave, step
---------------------------------------------------------------------------
local function arrive(rec, train)
  local sch = train.get_schedule()
  local i = rec.rmap and rec.rmap[sch.current]
  local stop = i and rec.stops[i]
  if not stop then return end
  local R = storage.rails
  local dun
  local st = train.station
  if stop.target and st and st.valid and R.stops[st.unit_number] == stop.target then dun = stop.target end
  rec.dwell = {native = true, stop = i, depot = dun, since = game.tick, phase = "unload"}
  rec.state = "at_stop"
  rec.reason = nil
  if dun then rails.refuel(train, logistics.hub_network(dun)) end
  if stop.troops == "unload" then
    local garrison = loaded("garrison")
    if garrison and garrison.disembark then
      local n = garrison.disembark(train, string.format("stop %d of %d", i, #rec.stops))
      if n > 0 then
        rec.trips = (rec.trips or 0) + 1
        rec.dwell.troops_out = n
      end
    end
  end
  util.log("rails: route train %d (%s) at stop %d of %d (%s) after %.1f s", train.id, rec.force, i, #rec.stops,
    dun and string.format("depot #%d", dun) or (stop.target and "depot (other stop)" or "rail"),
    (game.tick - (rec.leg or game.tick)) / 60)
end

local function leave(rec, train)
  local d = rec.dwell
  rec.dwell = nil
  rec.leg = game.tick
  if not (d and d.native) then return end
  if (d.unloaded or 0) > 0 then
    rec.trips = (rec.trips or 0) + 1
    local stats = rails.stats(rec.force)
    stats.trips = stats.trips + 1
  end
  util.log("rails: route train %d (%s) leaves stop %d of %d after %.1f s (unloaded %d, loaded %d)", train.id, rec.force,
    d.stop or 0, #rec.stops, (game.tick - d.since) / 60, d.unloaded or 0, d.loaded or 0)
  if rec.loop == false and d.stop == #rec.stops then
    rec.halted = true
    train.manual_mode = true
    util.log("rails: route train %d (%s) halts after its last stop (no loop)", train.id, rec.force)
  end
end

events.on(defines.events.on_train_changed_state, function(e)
  local R = storage.rails
  if not R then return end
  local train = e.train
  local rec = R.trains[train.id]
  if not (rec and rec.stops) then return end
  if e.old_state == TS.wait_station and rec.dwell then leave(rec, train) end
  if train.state == TS.wait_station then arrive(rec, train) end
end)

events.on_nth_tick(railroutes.PERIOD, function()
  local R = storage.rails
  if not (R and next(R.trains)) then return end
  for _, id in ipairs(sorted_keys(R.trains)) do
    local rec = R.trains[id]
    if rec.stops and rec.dwell and rec.dwell.native then
      local train = rails.train_of(rec)
      if not (train and train.valid and train.state == TS.wait_station) then
        rec.dwell = nil
      else
        dwell(rec, train)
      end
    end
  end
end)

-- rails.lua's train step for a train on a stop list (every rails.STEP ticks).
local function step(rec, train)
  if rec.written ~= train.id then write(rec, train, "new train id") end
  local st = train.state
  if #rec.stops == 0 then
    rec.state = "idle"
  elseif rec.halted or train.manual_mode then
    rec.state = "stopped"
  elseif st == TS.wait_station then
    rec.state = "at_stop"
  elseif st == TS.no_path or st == TS.path_lost then
    if rec.state ~= "no_path" then util.log("rails: route train %d (%s) has no path", train.id, rec.force) end
    rec.state = "no_path"
  elseif st == TS.wait_signal then
    rec.state = "wait_signal"
  elseif st == TS.destination_full then
    rec.state = "destination_full"
  else
    rec.state = "to_stop"
  end
  if train.speed == 0 and rails.fuel_left(train) == 0 and st == TS.on_the_path then
    if rec.reason ~= "no-fuel" then
      util.log("rails: route train %d (%s) is out of fuel", train.id, rec.force)
    end
    rec.reason = "no-fuel"
  elseif rec.reason == "no-fuel" or rec.reason == "depot-lost" then
    rec.reason = nil
  end
end

-- rails.lua: a depot was removed or changed hands: stop lists that name it are written again (it is skipped while it
-- is gone or foreign; a depot back with the owner is taken up again).
local function refresh(un)
  local R = storage.rails
  if not R then return end
  for _, id in ipairs(sorted_keys(R.trains)) do
    local rec = R.trains[id]
    if rec.stops and railroutes.targets(rec)[un] then
      local train = rails.train_of(rec)
      if train and train.valid then write(rec, train, "depot #" .. un .. " changed") end
    end
  end
end

--- Resume: write the schedule again and send the train on (a halted no-loop train starts over at stop 1).
function railroutes.resume(rec, train)
  if not (rec and rec.stops and train and train.valid) then return false end
  if rec.halted then
    rec.halted = nil
    rec.next_stop = 1
  end
  return write(rec, train, "resume") > 0
end

-- logistics.served_by_train: a cargo train on a stop list that loads in network src and unloads in network home.
local function serves(rec, src_id, home_id)
  local loads, unloads = false, false
  for _, st in ipairs(rec.stops or {}) do
    local net = st.target and logistics.hub_network(st.target)
    if net then
      if st.load and net.network_id == src_id then loads = true end
      if st.unload and net.network_id == home_id then unloads = true end
    end
  end
  return loads and unloads
end

--- An artillery wagon of the train bombards here: it stands at a stop marked bombard.
function railroutes.bombard_here(rec, train)
  local d = rec and rec.stops and rec.dwell
  local stop = d and d.native and d.stop and rec.stops[d.stop]
  return stop ~= nil and stop.bombard == true and train ~= nil and train.valid and train.state == TS.wait_station
end

--- The panel line: {index, count, stop, phase = "unload" | "load" | nil, item, done, want, state}.
function railroutes.status(rec, train)
  local out = {count = rec.stops and #rec.stops or 0, state = rec.state}
  if not (rec.stops and train and train.valid) then return out end
  local d = rec.dwell
  if d and d.native then
    out.index = d.stop
    out.phase = d.phase
    out.reason = d.reason
    local want, done = d.lwant, d.ldone
    if d.phase == "unload" then want, done = d.uwant, d.udone end
    for _, item in ipairs(sorted_keys(want)) do
      local w = want[item]
      local got = done and done[item] or 0
      if w > 0 and (not out.item or got < w) then
        out.item, out.done, out.want = item, got, w
        if got < w then break end
      end
    end
  else
    local sch = train.get_schedule()
    out.index = rec.rmap and rec.rmap[sch.current]
  end
  out.stop = out.index and rec.stops[out.index]
  return out
end

---------------------------------------------------------------------------
-- Right click (rails.right_click calls this for a selected train)
---------------------------------------------------------------------------
local function rail_at(train, position, entities)
  for _, e in pairs(entities or {}) do
    if e.valid and (e.type == "straight-rail" or e.type == "curved-rail-a" or e.type == "curved-rail-b"
                    or e.type == "half-diagonal-rail") then
      return e
    end
  end
  local surface = train.front_stock.surface
  local found = surface.find_entities_filtered({position = position, radius = 2, type = RAIL_TYPES})
  local best, bd
  for _, e in ipairs(found) do
    local d = util.distance_sq(e.position, position)
    if not bd or d < bd then best, bd = e, d end
  end
  return best
end

local function mark(player_index, target, surface, color)
  if not selection.real_player(player_index) then return end
  rendering.draw_circle({color = color, radius = 3, width = 4, filled = false, target = target, surface = surface,
                         time_to_live = 30, players = {player_index}})
end

railroutes.selected_stop = nil -- railgui.lua: fn(player_index, train_id) -> stop index | nil

local function click(player_index, position, entities, alt, trec, train, depot_un)
  if trec.kind == "construction" then return nil end
  if train.front_stock and train.front_stock.force.name ~= selection.force_name(player_index) then return nil end
  local target = depot_un
  local caps = railroutes.caps(train)
  local rail
  if not target and (caps.troop > 0 or caps.artillery > 0) then rail = rail_at(train, position, entities) end
  if not (target or rail) then
    util.log("order train-none train=%d (no depot%s at %s) player=%d", train.id,
      (caps.troop > 0 or caps.artillery > 0) and " or rail" or "", util.pos_str(position), player_index)
    return "train-none", 0
  end
  local after = nil
  if alt and railroutes.selected_stop then after = railroutes.selected_stop(player_index, trec.id) end
  local i, why = railroutes.add(train, target or rail, after)
  local d = target and rails.depot(target)
  if i then
    if d then mark(player_index, d.entity, d.entity.surface, {r = 0.3, g = 0.7, b = 1, a = 1})
    else mark(player_index, rail.position, rail.surface, {r = 1, g = 0.55, b = 0.2, a = 1}) end
  else
    local player = selection.real_player(player_index)
    if player then
      player.create_local_flying_text({text = {"rts.route-add-refused", {"rts.route-why-" .. tostring(why)}},
        create_at_cursor = true})
    end
  end
  util.log("order train-stop train=%d %s index=%s (%s) player=%d", train.id,
    target and ("depot=#" .. target) or ("rail=" .. util.pos_str(rail.position)), tostring(i), tostring(why),
    player_index)
  return "train-stop", i and 1 or 0
end

rails.routes = {step = step, click = click, refresh = refresh, resume = railroutes.resume, serves = serves}

---------------------------------------------------------------------------
-- Init: 0.1.1 routes of human players' trains become two-stop lists
---------------------------------------------------------------------------
function railroutes.init()
  local R = storage.rails
  if not R or (R.routes_v or 0) >= 1 then return end
  R.routes_v = 1
  local n = 0
  for _, id in ipairs(sorted_keys(R.trains)) do
    local rec = R.trains[id]
    local f = game.forces[rec.force]
    local human = f and #f.players > 0
    if human and rails.FREIGHT[rec.kind] and rec.pickup and rec.dropoff and not rec.ai_line and not rec.stops then
      local a, b = rec.pickup, rec.dropoff
      local first = {target = a, wait = copy(railroutes.DEFAULT_WAIT)}
      local second = {target = b, wait = copy(railroutes.DEFAULT_WAIT)}
      if rec.kind == "cargo" then first.load, second.unload = "exports", "keep" end
      if rec.kind == "troop" then first.troops, second.troops = "board", "unload" end
      for _, st in ipairs({first, second}) do
        local d = rails.depot(st.target)
        if d and d.entity.valid then st.x, st.y = d.entity.position.x, d.entity.position.y end
      end
      start(rec)
      rec.stops = {first, second}
      rec.written = nil -- rails.lua's next train step writes the schedule
      rec.dwell = nil
      n = n + 1
      util.log("rails: route train %d (%s): the 0.1.1 route depot #%d -> depot #%d is now a two-stop list", id,
        rec.force, a, b)
    end
  end
  if n > 0 then util.log("rails: %d train route(s) of 0.1.1 became stop lists", n) end
end

return railroutes
