-- Phase 5 M3 war2: artillery trains, armoured stock and train stances (docs/PHASE5-M3.md D6, section 3
-- "fronts.lua / belts.lua / trainswar.lua"; study docs/research/scale/rails-trade.md R2 and war-ai-performance.md 2.6;
-- notes docs/qa/phase5-war2-notes.md). Nation mode only (trains exist in Nation mode only).
--
--   trainswar.set_stance(train_id, "bombard" | "none") -> ok, reason   stance of a train with an artillery wagon
--   trainswar.targets(train_id) -> {entity}   hostile buildings (diplomacy.hostile) within range of its artillery wagon
--                                             that the force sees (trainswar.KNOWN: an own entity within 48 tiles of it
--                                             or an own radar within 96), turrets first, then barracks, centres, the rest
--   trainswar.fire(train_id) -> shells, target   1 shell from every artillery wagon at the first target
--   trainswar.deploy(depot_un, kind, armoured) -> LuaTrain | nil, reason   rails.create_train plus the starting shells
--
-- Artillery train ("artillery", rails.create_train): 2 locomotives (armoured ones when asked) + 1 rts-artillery-wagon,
-- kits from the depot network. The wagon never fires by itself (disable_automatic_firing); in stance Bombard (key B,
-- the train panel) this module fires one rts-rail-shell every balance.nation.trains_war.period ticks (10 s) at the best
-- target within range (120 tiles): one shell leaves the wagon's ammo slot and an rts-rail-shell-projectile is thrown at
-- the target's position like the Artillery strike's shells (abilities.lua: create_entity with source, cause, force,
-- speed, max_range). The blast hurts hostile forces only and never rails (prototypes/war3.lua). Moving or standing, the
-- train fires; at a depot of its force it refuels and tops its shells up to shells_keep from the depot network.
-- Orders (rails.KIND_HOOKS.artillery): with the train selected, a right click on an own depot sends it there, a right
-- click on a rail stops it on that rail (temporary stop); it then waits there.
-- Armoured stock: rts-armoured-locomotive and rts-armoured-wagon (an armoured troop wagon: scripts/garrison.lua takes
-- its troops like the M2 troop wagon's) from their kits, through the depot panel's Armoured checkbox. Kits and shells
-- come with the Military railways technology (Age II).
--
-- Per-train fields on the rails record (storage.rails.trains[id], kept across train id changes by rails.lua):
--   stance = "bombard" | nil, next_shot (tick), shots, last_target = {name, force, distance}, war_reason, war_state,
--   position_rail = MapPosition (the rail it was sent to)
-- Owns storage.trainswar = {prefs = {[player_index] = {armoured}}, stats = {[force] = {shots, rearmed, deployed}},
--   alerted = {[train_id] = tick}}. Log lines "[rts] train: ...".
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local logistics = require("scripts.logistics")
local match = require("scripts.match")
local rails = require("scripts.rails")
local supply = require("scripts.supply")
local diplomacy = require("scripts.diplomacy")
local balance = require("balance")
local research
do
  local ok, mod = pcall(require, "scripts.research")
  if ok and type(mod) == "table" then research = mod end
end

local trainswar = {}
local TW = balance.nation.trains_war

trainswar.SHELL = "rts-rail-shell"
trainswar.PROJECTILE = "rts-rail-shell-projectile"
trainswar.KIND = "artillery"
trainswar.STEP = 60                 -- stance and rearm pass, ticks
trainswar.RETRY = 60                -- a shot without a target or shell is tried again this soon
trainswar.ALERT_TICKS = 60 * 60     -- "out of shells" at most once a minute per train
trainswar.PREFIX = "rts_trainswar_"

-- Research: Military railways (Age II) unlocks the kits and the shell (prototypes/war3.lua); Nation-only.
local UNLOCKS = {rails.ARTY_KIT, rails.ALOCO_KIT, rails.AWAGON_KIT, trainswar.SHELL}
if research then
  research.EFFECTS[TW.tech] = {unlock = UNLOCKS}
  for _, name in ipairs(UNLOCKS) do research.LOCKS[name] = TW.tech end
  if research.NATION_ONLY then research.NATION_ONLY[TW.tech] = true end
  if research.AGE_REQUIRED then research.AGE_REQUIRED[TW.tech] = TW.techs.military_railways.age end
end

-- The armoured troop wagon carries troops like the troop wagon (scripts/garrison.lua loads before this module).
do
  local l = package.loaded
  local garrison = l["__" .. script.mod_name .. "__/scripts/garrison.lua"] or l["scripts.garrison"]
  if garrison and garrison.TWAGONS then garrison.TWAGONS[rails.AWAGON] = true end
end

local floor, sqrt = math.floor, math.sqrt
local TS = defines.train_state

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function S()
  local s = storage.trainswar
  if not s then
    s = {}
    storage.trainswar = s
  end
  s.prefs = s.prefs or {}
  s.stats = s.stats or {}
  s.alerted = s.alerted or {}
  return s
end

function trainswar.init() S() end

local function fstats(force_name)
  local st = S().stats
  local f = st[force_name]
  if not f then
    f = {shots = 0, rearmed = 0, deployed = 0}
    st[force_name] = f
  end
  return f
end

--- Counters per force: {shots, rearmed, deployed}.
function trainswar.stats(force_name) return fstats(force_name) end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Trains
---------------------------------------------------------------------------
local function train_of(rec) return rec and rails.train_of(rec) or nil end

local function record(train_id) return rails.train_record(train_id) end

local function arty_wagons(train)
  local out = {}
  if not (train and train.valid) then return out end
  for _, c in ipairs(train.carriages) do
    if c.valid and c.name == rails.ARTY then out[#out + 1] = c end
  end
  return out
end
trainswar.arty_wagons = arty_wagons

local function ammo_inv(wagon) return wagon.get_inventory(defines.inventory.artillery_wagon_ammo) end

--- Shells in the train's artillery wagons.
function trainswar.shells(train)
  local n = 0
  for _, w in ipairs(arty_wagons(train)) do
    local inv = ammo_inv(w)
    n = n + (inv and inv.get_item_count(trainswar.SHELL) or 0)
  end
  return n
end

--- True when the train (LuaTrain, record or id) has an artillery wagon.
function trainswar.has_artillery(x)
  local rec = type(x) == "table" and x.kind and x or record(x)
  return #arty_wagons(train_of(rec)) > 0
end

local function refuel(train, net)
  if not (net and net.valid) then return 0 end
  local put = 0
  for _, group in pairs({train.locomotives.front_movers, train.locomotives.back_movers}) do
    for _, loco in ipairs(group) do
      local inv = loco.get_fuel_inventory()
      if inv then
        local want = balance.nation.rails.fuel_target - inv.get_item_count(rails.FUEL)
        if want > 0 then put = put + logistics.transfer(net, inv, rails.FUEL, want) end
      end
    end
  end
  return put
end

--- Top the artillery wagons up to shells_keep from a network. Returns the shells moved.
local function rearm(train, net)
  if not (net and net.valid) then return 0 end
  local moved = 0
  for _, w in ipairs(arty_wagons(train)) do
    local inv = ammo_inv(w)
    if inv then
      local want = TW.shells_keep - inv.get_item_count(trainswar.SHELL)
      if want > 0 then moved = moved + logistics.transfer(net, inv, trainswar.SHELL, want) end
    end
  end
  return moved
end

-- The own depot the standing train is at: its station's depot, else a depot whose platform it stands on.
local function depot_here(rec, train)
  local R = storage.rails
  if not R then return nil end
  if train.state == TS.wait_station and train.station and train.station.valid then
    local dun = R.stops[train.station.unit_number]
    local d = dun and R.depots[dun]
    if d and d.force == rec.force then return dun end
  end
  if math.abs(train.speed) > 0.001 then return nil end
  local front = train.front_stock
  local pos = front and front.valid and front.position
  if not pos then return nil end
  for _, un in ipairs(sorted_keys(R.depots)) do
    local d = R.depots[un]
    local a = d.force == rec.force and d.entity.valid and d.platform and d.platform.area
    if a and pos.x >= a[1][1] - 4 and pos.x <= a[2][1] + 4 and pos.y >= a[1][2] - 4 and pos.y <= a[2][2] + 4 then
      return un
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Targets and fire
---------------------------------------------------------------------------
local SKIP_KINDS = {wall = true, train = true}
local target_names
local function names()
  if not target_names then
    target_names = {}
    for name, kind in pairs(buildings.KIND_BY_NAME) do
      if not SKIP_KINDS[kind] and prototypes.entity[name] then target_names[#target_names + 1] = name end
    end
    table.sort(target_names)
  end
  return target_names
end

local function hostile_forces(force_name)
  local out = {}
  for _, f in pairs(game.forces) do
    if diplomacy.hostile(force_name, f.name) then out[#out + 1] = f.name end
  end
  table.sort(out)
  return out
end

--- Does the force see a target at `pos`? A spotter: any entity of the force within spot_radius tiles of it (a unit, a
--- building, a train), or one of its radars within radar_radius. The same rule for players and AIs, and no chart state:
--- charting is not the same on a headless server and a GUI peer (m3-perf, LAN determinism), and AI forces are never
--- charted. Replaceable (m3-ai's intel): fn(force, surface, position) -> bool.
trainswar.KNOWN = function(force, surface, pos)
  if surface.count_entities_filtered({position = pos, radius = TW.spot_radius, force = force, limit = 1}) > 0 then
    return true
  end
  return surface.count_entities_filtered({position = pos, radius = TW.radar_radius, force = force, type = "radar",
                                           limit = 1}) > 0
end

-- Hostile buildings within range of `from` that the force knows, best first.
local function targets_from(force_name, from)
  local hostile = hostile_forces(force_name)
  if #hostile == 0 then return {} end
  local force = game.forces[force_name]
  local surface = from.surface
  local p = from.position
  local min2 = TW.min_range * TW.min_range
  local list = {}
  local found = surface.find_entities_filtered({position = p, radius = TW.range, name = names(), force = hostile})
  for _, e in pairs(found) do
    local un = e.valid and e.destructible and e.unit_number
    local brec = un and buildings.get(un)
    if brec then
      local ep = e.position
      local dx, dy = ep.x - p.x, ep.y - p.y
      local d2 = dx * dx + dy * dy
      if d2 >= min2 and trainswar.KNOWN(force, surface, ep) then
        list[#list + 1] = {e = e, un = un, d2 = d2, rank = TW.target_rank[brec.kind] or 5}
      end
    end
  end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.d2 ~= b.d2 then return a.d2 < b.d2 end
    return a.un < b.un
  end)
  local out = {}
  for i, t in ipairs(list) do out[i] = t.e end
  return out
end

--- Hostile buildings within range of the train's (first) artillery wagon, best first.
function trainswar.targets(train_id)
  local rec = record(train_id)
  local wagons = arty_wagons(train_of(rec))
  if not (rec and wagons[1]) then return {} end
  return targets_from(rec.force, wagons[1])
end

--- One shot: every artillery wagon of the train throws one shell at the best target. Returns the shells fired and the
--- target (nil and a reason: "no-train", "no-artillery", "no-target", "no-shells").
function trainswar.fire(train_id)
  local rec = record(train_id)
  local train = train_of(rec)
  if not (train and train.valid) then return 0, nil, "no-train" end
  local wagons = arty_wagons(train)
  if #wagons == 0 then return 0, nil, "no-artillery" end
  local list = targets_from(rec.force, wagons[1])
  local target = list[1]
  if not target then return 0, nil, "no-target" end
  local fired = 0
  local force = game.forces[rec.force]
  for _, w in ipairs(wagons) do
    local inv = ammo_inv(w)
    if inv and inv.get_item_count(trainswar.SHELL) > 0 then
      local p = w.surface.create_entity({name = trainswar.PROJECTILE, position = w.position, target = target.position,
        source = w, cause = w, force = force, speed = TW.shell_speed, max_range = TW.range + 10})
      if p then
        inv.remove({name = trainswar.SHELL, count = 1})
        fired = fired + 1
      end
    end
  end
  if fired == 0 then return 0, target, "no-shells" end
  rec.shots = (rec.shots or 0) + fired
  local d = util.distance(wagons[1], target)
  rec.last_target = {name = target.name, force = target.force.name, distance = d}
  fstats(rec.force).shots = fstats(rec.force).shots + fired
  util.log("train: %d (%s) fires %d shell(s) at %s #%d of %s, %.0f tiles, %d shells left", train.id, rec.force, fired,
    target.name, target.unit_number, target.force.name, d, trainswar.shells(train))
  return fired, target
end

--- Stance of a train: "bombard" (fire every period at hostile buildings in range) or "none". Returns ok, reason.
function trainswar.set_stance(train_id, stance)
  local rec = record(train_id)
  if not rec then return false, "no-train" end
  if stance ~= "bombard" then stance = "none" end
  if stance == "bombard" and not trainswar.has_artillery(rec) then return false, "no-artillery" end
  local new = stance == "bombard" and "bombard" or nil
  if rec.stance == new then return true end
  rec.stance = new
  rec.next_shot = new and game.tick or nil
  rec.war_reason = nil
  util.log("train: %d (%s) stance %s", rec.id, rec.force, stance)
  return true
end

--- The stance of a train ("bombard" | "none").
function trainswar.stance(train_id)
  local rec = record(train_id)
  return rec and rec.stance or "none"
end

---------------------------------------------------------------------------
-- Deploy, move
---------------------------------------------------------------------------
--- Deploy a train of `kind` from a depot's kits (rails.create_train), armoured stock when `armoured`; an artillery
--- train takes its starting shells from the depot network. Returns the LuaTrain or nil and a reason.
function trainswar.deploy(depot_un, kind, armoured)
  local train, why = rails.create_train(depot_un, kind, {armoured = armoured})
  if not train then return nil, why end
  local rec = rails.train_record(train)
  if rec then
    local net = logistics.hub_network(depot_un)
    local shells = rearm(train, net)
    fstats(rec.force).deployed = fstats(rec.force).deployed + 1
    if kind == trainswar.KIND then
      util.log("train: artillery train %d (%s) deployed at depot #%d%s with %d shells", train.id, rec.force, depot_un,
        armoured and " (armoured)" or "", shells)
    end
  end
  return train
end

local function go(train, record_spec)
  local sch = train.get_schedule()
  sch.clear_records()
  record_spec.wait_conditions = {{type = "time", ticks = rails.LONG_WAIT}}
  sch.add_record(record_spec)
  train.manual_mode = false
  sch.go_to_station(1)
end

--- Send an artillery train to an own depot (stays there). Returns true when sent.
function trainswar.send_to_depot(train_id, depot_un)
  local rec = record(train_id)
  local train = train_of(rec)
  local d = rails.depot(depot_un)
  if not (train and d and d.force == rec.force) then return false end
  go(train, {station = d.stop_name, temporary = true})
  rec.pickup, rec.position_rail, rec.war_state = depot_un, nil, "to_position"
  rec.state = "to_position"
  util.log("train: %d (%s) goes to depot #%d", train.id, rec.force, depot_un)
  return true
end

local RAIL_TYPES = {"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail"}

--- Send an artillery train to a rail (a temporary stop on it). Returns true when sent.
function trainswar.send_to_rail(train_id, rail)
  local rec = record(train_id)
  local train = train_of(rec)
  if not (train and rail and rail.valid) then return false end
  go(train, {rail = rail, temporary = true})
  rec.pickup, rec.position_rail, rec.war_state = nil, {x = rail.position.x, y = rail.position.y}, "to_position"
  rec.state = "to_position"
  util.log("train: %d (%s) goes to the rail at %s", train.id, rec.force, util.pos_str(rail.position))
  return true
end

local function mark(player_index, target, surface)
  if not selection.real_player(player_index) then return end
  rendering.draw_circle({color = {r = 1, g = 0.55, b = 0.2, a = 1}, radius = 3, width = 4, filled = false,
                         target = target, surface = surface, time_to_live = 30, players = {player_index}})
end

-- rails.KIND_HOOKS.artillery.right_click: a depot sends the train there, a rail stops it on that rail.
local function right_click(player_index, position, entities, alt, trec, train, depot_un)
  if depot_un then
    local ok = trainswar.send_to_depot(trec.id, depot_un)
    local d = rails.depot(depot_un)
    if d and ok then mark(player_index, d.entity, d.entity.surface) end
    util.log("order train-artillery-depot train=%d depot=#%d ok=%s player=%d", train.id, depot_un, tostring(ok),
      player_index)
    return "train-artillery-depot", ok and 1 or 0
  end
  local rail
  for _, e in pairs(entities or {}) do
    if e.valid and (e.type == "straight-rail" or e.type == "curved-rail-a" or e.type == "curved-rail-b"
                    or e.type == "half-diagonal-rail") then
      rail = e
      break
    end
  end
  if not rail then
    local surface = train.front_stock.surface
    local found = surface.find_entities_filtered({position = position, radius = 2, type = RAIL_TYPES})
    local bd
    for _, e in ipairs(found) do
      local d = util.distance_sq(e.position, position)
      if not bd or d < bd then rail, bd = e, d end
    end
  end
  if not rail then
    util.log("order train-none train=%d (artillery: no depot or rail at %s) player=%d", train.id,
      util.pos_str(position), player_index)
    return "train-none", 0
  end
  local ok = trainswar.send_to_rail(trec.id, rail)
  if ok then mark(player_index, rail.position, rail.surface) end
  util.log("order train-artillery-rail train=%d at %s ok=%s player=%d", train.id, util.pos_str(rail.position),
    tostring(ok), player_index)
  return "train-artillery-rail", ok and 1 or 0
end
rails.KIND_HOOKS[trainswar.KIND] = {right_click = right_click}

---------------------------------------------------------------------------
-- Step: stances, rearm, state
---------------------------------------------------------------------------
local function alert_empty(rec, train)
  local s = S()
  local last = s.alerted[rec.id]
  if last and game.tick - last < trainswar.ALERT_TICKS then return end
  s.alerted[rec.id] = game.tick
  supply.alert(rec.force, "train-no-shells", "rts-war3.alert-no-shells", {rec.id}, train.front_stock.position)
end

local function step_train(rec, train, tick)
  -- at a depot of its force: refuel and rearm
  local dun = depot_here(rec, train)
  if dun and #arty_wagons(train) > 0 then
    local net = logistics.hub_network(dun)
    local moved = rearm(train, net)
    if moved > 0 then
      refuel(train, net)
      fstats(rec.force).rearmed = fstats(rec.force).rearmed + moved
      util.log("train: %d (%s) took %d shells at depot #%d (%d aboard)", train.id, rec.force, moved, dun,
        trainswar.shells(train))
    end
  end
  if rec.kind == trainswar.KIND then
    local st = train.state
    if st == TS.wait_station then
      rec.state = "in_position"
    elseif train.manual_mode and math.abs(train.speed) < 0.001 then
      rec.state = (rec.pickup or rec.position_rail) and "in_position" or "idle"
    elseif st ~= TS.no_path and st ~= TS.path_lost then
      rec.state = "to_position"
    end
  end
  if rec.stance ~= "bombard" then return end
  if tick < (rec.next_shot or 0) then return end
  local fired, _, why = trainswar.fire(rec.id)
  if fired > 0 then
    rec.next_shot = tick + TW.period
    rec.war_reason = nil
  else
    rec.next_shot = tick + trainswar.RETRY
    if rec.war_reason ~= why then
      rec.war_reason = why
      util.log("train: %d (%s) bombard: %s", train.id, rec.force, why)
    end
    if why == "no-shells" then alert_empty(rec, train) end
  end
end

events.on_nth_tick(trainswar.STEP, function(e)
  local R = storage.rails
  if not (R and next(R.trains)) then return end
  for _, id in ipairs(sorted_keys(R.trains)) do
    local rec = R.trains[id]
    if rec and (rec.stance or rec.kind == trainswar.KIND) then
      local train = train_of(rec)
      if train and train.valid then step_train(rec, train, e.tick) end
    end
  end
end)

-- An artillery train that arrives at a depot of its force refuels and rearms at once.
events.on(defines.events.on_train_changed_state, function(e)
  local R = storage.rails
  local rec = R and R.trains[e.train.id]
  if not (rec and e.train.state == TS.wait_station and #arty_wagons(e.train) > 0) then return end
  local dun = depot_here(rec, e.train)
  if not dun then return end
  local net = logistics.hub_network(dun)
  refuel(e.train, net)
  local moved = rearm(e.train, net)
  if moved > 0 then fstats(rec.force).rearmed = fstats(rec.force).rearmed + moved end
  util.log("train: %d (%s) at depot #%d: %d shells taken (%d aboard)", e.train.id, rec.force, dun, moved,
    trainswar.shells(e.train))
end)

-- Disband (rails.disband_train): the shells go back into the depot network with the cargo (chained after garrison's
-- hook, which lets the troops out first).
do
  local prev = rails.on_disband
  rails.on_disband = function(rec, train)
    if prev then prev(rec, train) end
    local wagons = arty_wagons(train)
    if #wagons == 0 then return end
    local dun = depot_here(rec, train) or rec.home
    local net = dun and logistics.hub_network(dun)
    if not net then return end
    local n = 0
    for _, w in ipairs(wagons) do
      local inv = ammo_inv(w)
      local c = inv and inv.get_item_count(trainswar.SHELL) or 0
      if c > 0 then n = n + logistics.transfer(inv, net, trainswar.SHELL, c) end
    end
    if n > 0 then util.log("train: %d (%s) disbanded: %d shells back to depot #%d", train.id, rec.force, n, dun) end
  end
end

---------------------------------------------------------------------------
-- Key B and the rail panels (scripts/railgui.lua calls these)
---------------------------------------------------------------------------
local function selected_train(player_index)
  local _, brec = selection.get_building(player_index)
  if not (brec and brec.kind == rails.KIND and brec.force == selection.force_name(player_index)) then return nil end
  return rails.train_record(brec.entity)
end

--- True when B belongs to the train stance (an own train is selected): hud.lua's build-menu handler then stays out.
function trainswar.claims_b(player_index)
  return selected_train(player_index) ~= nil
end

local function railgui_refresh(player_index)
  local l = package.loaded
  local railgui = l["__" .. script.mod_name .. "__/scripts/railgui.lua"] or l["scripts.railgui"]
  if railgui and railgui.refresh then railgui.refresh(player_index) end
end

--- B (hud.lua P4.KEYS): toggle Bombard on the selected train.
function trainswar.key_b(player)
  local rec = selected_train(player.index)
  if not rec then return false end
  local want = rec.stance == "bombard" and "none" or "bombard"
  local ok, why = trainswar.set_stance(rec.id, want)
  util.log("train: key B train=%d -> %s ok=%s (%s) player=%d", rec.id, want, tostring(ok), tostring(why), player.index)
  if not ok then
    player.create_local_flying_text({text = {"rts-war3.stance-refused-" .. tostring(why)}, create_at_cursor = true})
  end
  railgui_refresh(player.index)
  return ok
end

--- Deploy options of a player's depot panel (railgui.lua's Deploy buttons): {armoured = bool}.
function trainswar.deploy_opts(player_index)
  local p = S().prefs[player_index]
  return {armoured = p and p.armoured or false}
end

local P = trainswar.PREFIX
local STATE_KEYS = {to_position = "rts-war3.train-to-position", in_position = "rts-war3.train-in-position"}
trainswar.STATE_KEYS = STATE_KEYS

--- Rows for the train panel of a train with an artillery wagon: stance buttons and the gun line. Returns the elements
--- (nil for other trains).
function trainswar.panel_train(frame, rec, width)
  if not trainswar.has_artillery(rec) then return nil end
  local el = {}
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  row.add({type = "label", style = "rts_hud_label", caption = {"rts-war3.stance"},
           tooltip = {"rts-war3.stance-tooltip"}})
  el.none = row.add({type = "button", name = P .. "stance_none", style = "rts_hud_tab_button",
    caption = {"rts-war3.stance-none"}, tooltip = {"rts-war3.stance-none-tooltip"},
    tags = {rts_trainswar = "stance", stance = "none", train = rec.id}})
  el.bombard = row.add({type = "button", name = P .. "stance_bombard", style = "rts_hud_tab_button",
    caption = {"rts-war3.stance-bombard"}, tooltip = {"rts-war3.stance-bombard-tooltip", TW.range, TW.period / 60},
    tags = {rts_trainswar = "stance", stance = "bombard", train = rec.id}})
  el.gun = frame.add({type = "label", style = "rts_hud_label", caption = ""})
  el.gun.style.maximal_width = (width or 330) - 20
  el.gun.style.single_line = false
  return el
end

--- Update the train panel: the stance buttons and gun line, and the artillery train's route line (railgui's el).
function trainswar.panel_train_update(gel, el, rec, train)
  if rec.kind == trainswar.KIND and gel then
    -- the freight lines (cargo: its shells, deliveries, the depot's line) say nothing about an artillery train
    for _, key in ipairs({"cargo", "delivered", "line"}) do
      if gel[key] and gel[key].valid then gel[key].visible = false end
    end
  end
  if rec.kind == trainswar.KIND and gel and gel.route and gel.route.valid then
    if rec.pickup and rails.depot(rec.pickup) then
      gel.route.caption = {"rts-war3.train-position-depot", logistics.hub_name(rec.pickup)}
    elseif rec.position_rail then
      gel.route.caption = {"rts-war3.train-position-rail", floor(rec.position_rail.x), floor(rec.position_rail.y)}
    else
      gel.route.caption = {"rts-war3.train-position-unset"}
    end
  end
  if not (el and el.gun and el.gun.valid) then return end
  local bombard = rec.stance == "bombard"
  el.none.toggled = not bombard
  el.bombard.toggled = bombard
  local shells = trainswar.shells(train)
  local parts
  if bombard then
    local wait = math.max(0, math.ceil(((rec.next_shot or game.tick) - game.tick) / 60))
    if rec.war_reason == "no-shells" then
      parts = {"rts-war3.gun-no-shells", shells}
    elseif rec.war_reason == "no-target" then
      parts = {"rts-war3.gun-no-target", shells, TW.range}
    else
      local t = rec.last_target
      parts = {"rts-war3.gun-bombard", shells, wait, t and {"entity-name." .. t.name} or {"rts-war3.gun-none"},
               t and floor(t.distance + 0.5) or 0}
    end
  else
    parts = {"rts-war3.gun-idle", shells, rec.shots or 0}
  end
  el.gun.caption = parts
end

--- Rows for the depot panel: artillery and armoured kits, Deploy artillery train, the Armoured checkbox.
function trainswar.panel_depot(frame, un, player_index, width)
  local el = {}
  el.kits = frame.add({type = "label", style = "rts_hud_dim_label", caption = ""})
  el.kits.style.single_line = false
  el.kits.style.maximal_width = (width or 330) - 20
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.deploy = row.add({type = "button", name = P .. "deploy_artillery", style = "rts_hud_button",
    caption = {"rts-war3.deploy-artillery"}, tooltip = {"rts-war3.deploy-artillery-tooltip"},
    tags = {rts_trainswar = "deploy", depot = un}})
  local row2 = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"}) -- its own row (Russian)
  el.armoured = row2.add({type = "checkbox", name = P .. "armoured", caption = {"rts-war3.armoured"},
    state = trainswar.deploy_opts(player_index).armoured, tooltip = {"rts-war3.armoured-tooltip", TW.health_factor,
    TW.resist}, tags = {rts_trainswar = "armoured"}})
  return el
end

function trainswar.panel_depot_update(el, un, player_index)
  if not (el and el.kits and el.kits.valid) then return end
  local net = logistics.hub_network(un)
  local function n(item) return net and net.get_item_count(item) or 0 end
  el.kits.caption = {"rts-war3.depot-kits", n(rails.ARTY_KIT), n(rails.ALOCO_KIT), n(rails.AWAGON_KIT),
                     n(trainswar.SHELL)}
  local armoured = trainswar.deploy_opts(player_index).armoured
  local why
  if rails.deploy_check then
    why = rails.deploy_check(un, trainswar.KIND, {armoured = armoured}) -- kits, coal, a free and whole platform
  else
    local d = rails.depot(un)
    if not (d and d.platform and net) then why = "no-platform" end
    for _, k in ipairs(rails.kit_list(trainswar.KIND, nil, armoured)) do
      if not why and n(k[1]) < k[2] then why = "no-kits" end
    end
  end
  el.deploy.enabled = why == nil
  el.deploy.tooltip = why and {"", {"rts-war3.deploy-artillery-tooltip"}, "\n",
    {"rts-war3.deploy-artillery-why", {"rts.rails-why-" .. why}}} or {"rts-war3.deploy-artillery-tooltip"}
  el.armoured.state = armoured
end

events.on(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #P) ~= P then return end
  local tags = element.tags
  local player = game.get_player(e.player_index)
  if not (player and tags) then return end
  if tags.rts_trainswar == "stance" then
    local rec = record(tags.train)
    if rec and rec.force == player.force.name then
      local ok, why = trainswar.set_stance(tags.train, tags.stance)
      util.log("train: click stance %s train=%s ok=%s (%s) player=%d", tostring(tags.stance), tostring(tags.train),
        tostring(ok), tostring(why), player.index)
      if not ok then
        player.create_local_flying_text({text = {"rts-war3.stance-refused-" .. tostring(why)}, create_at_cursor = true})
      end
    end
  elseif tags.rts_trainswar == "deploy" then
    local d = rails.depot(tags.depot)
    if d and d.force == player.force.name then
      local armoured = trainswar.deploy_opts(player.index).armoured
      local train, why = trainswar.deploy(tags.depot, trainswar.KIND, armoured)
      util.log("train: click deploy artillery depot=#%s armoured=%s train=%s (%s) player=%d", tostring(tags.depot),
        tostring(armoured), tostring(train and train.id), tostring(why), player.index)
      if not train then player.print({"rts.railgui-deploy-failed", {"rts.rails-why-" .. tostring(why)}}) end
    end
  else
    return
  end
  railgui_refresh(player.index)
end)

events.on(defines.events.on_gui_checked_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or element.name ~= P .. "armoured" then return end
  local prefs = S().prefs
  prefs[e.player_index] = prefs[e.player_index] or {}
  prefs[e.player_index].armoured = element.state
  util.log("train: armoured stock %s player=%d", tostring(element.state), e.player_index)
  railgui_refresh(e.player_index)
end)

match.on_teardown(function()
  storage.trainswar = nil
  S()
end)

--- One line for logs: "rts-player: 2 shots, 20 shells rearmed, 1 deployed".
function trainswar.describe(force_name)
  local f = fstats(force_name)
  return string.format("%s: %d shots, %d shells rearmed, %d deployed", force_name, f.shots, f.rearmed, f.deployed)
end

return trainswar
