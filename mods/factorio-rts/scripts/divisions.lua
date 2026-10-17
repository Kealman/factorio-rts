-- Divisions (docs/PHASE5-M1.md section 3 "divisions.lua / orders.lua"; study: docs/research/scale/war-ai-performance.md
-- section 2.1; notes and measurements: docs/qa/phase5-divisions-notes.md). Available in Skirmish and Nation mode.
--
-- A division is a formation commanded as one object: an engine unit group (LuaSurface.create_unit_group), so a move
-- asks the pathfinder for one path instead of one per unit. Verdict of the M1 probes (spider-units, 4 forces x 12
-- divisions x 16 units, 512-tile arena with rivers): groups of spider-units (and mixed with `unit` drones) gather,
-- march (walkers 9.1 tiles/s straight-line, at the slowest member's speed when mixed), fight distractions and stay
-- cohesive (at most 8 of 768 units farther than 25 tiles from their division); force.ai_controllable is not needed.
-- The leader-follower fallback was measured and rejected: 2x the per-tick cost (3.2 ms vs 1.5 ms, pathFinder 1.9 ms
-- mean) and 575 of 768 units strung out behind their leaders. So every division order is one group command, issued
-- through orders.queue_command (at most orders.QUEUE.group_budget group paths per tick and group_inflight at once).
--
-- Engine facts the code relies on (probes, 2.0.77): a direct command to a member takes it out of its group;
-- add_member moves a unit from another group; group.destroy() fires on_ai_command_completed (fail) for the group and
-- leaves its members wandering; a group finishes go_to_location with a completion event (success), but attack_area
-- only switches the group to state "finished" without an event (so the controller polls the state); members of a
-- finished group keep the command "group", stand and fire back; deaths raise no on_unit_removed_from_group; a group
-- whose members all died becomes invalid without an event. A group command ends (success) as soon as the group stands
-- within its own size of the destination, whatever the command's radius (QA round 1, protocol step 33, probe: 30
-- walkers, go_to_location radius 2, 12.5 tiles away, completed in 0 ticks without a step; attack_area ended 18 tiles
-- short), so every order ends with the members walking to formation slots around the point ("settling").
--
-- Owns storage.divisions = {[id] = D} (the contract's table) with
--   D = {id, force, name (string or LocalisedString), default_name, units = {[unit_number] = true},
--        template = {name, composition = {[unit prototype] = n}, stance}, stance = "hold" | "advance" | "screen",
--        group (LuaCommandable?), group_id, rally (MapPosition?), reinforce (bool), owner = "player" | "ai",
--        state = "idle" | "moving" | "settling" |
--        "holding" (settling: after a move the members walk to formation slots around the target, then stop),
--        order = {kind, target, tick, auto?}?, detached = {[un] = true} (members ordered without their division; the
--        next division order takes them back), joining = {[un] = true} (reinforcements walking to the division),
--        settling = {[un] = true} (members still walking to their slot), settle_tick,
--        n, hp, max_hp, pos, n_tick (cached strength and centroid), created, checked, rejoin_tick, settle_check,
--        last_retarget, last_stance, fails}
-- and storage.division_meta = {next_id, member = {[unit_number] = id}, by_group = {[group unique_id] = id},
--   barracks = {[barracks unit_number] = id} (barracks set to reinforce a division), counter = {[force] = n}, stats}.
-- While a division drives a member, its storage.units record carries issuer = "divisions" and order = "move" |
-- "attack_move" | "hold" (units.lua claim rule); an idle division's members are idle (order "idle", issuer nil) and
-- stand in their finished group.
--
-- Orders (divisions.order): move (go_to_location, distraction none), attack_move (a compound: go_to_location within
-- ATTACK_GOTO_RADIUS, then attack_area, both distraction by_anything; at the end the division re-targets the nearest
-- enemy within RETARGET_RANGE of it at most once per RETARGET_TICKS, else its members walk to formation slots around
-- the point, fighting what they meet, and it is idle there), attack (attack_move at an entity's position), retreat (move to the rally point or
-- home), hold (members stop and are re-stopped whenever a command ends), stop (members stop, idle).
-- Stances act only while the division is idle: hold (stand, return fire), advance (attack-move enemies within
-- ADVANCE_RANGE), screen (fall back SCREEN_STEP tiles from enemies within SCREEN_RANGE).
-- Reinforcement: a barracks set to reinforce division N (divisions.set_barracks, the division panel) sends every new
-- unit to N while N accepts reinforcements and is below its template strength (production.on_spawned).
-- QA log lines start with "divisions: ".
-- Phase 5 M2 war (docs/PHASE5-M2.md section 3; scripts/warsupply.lua, scripts/garrison.lua) adds to D: sp (supply
-- points 0..100) and sp_credit (scripts/warsupply.lua), aboard (members travelling as records in a troop wagon: the
-- division stays while it has some), embark = {depot, tick} (members board a troop train at that depot) and no_train =
-- {depot, why, tick} (Phase 5 M2 QA round 1: a refused embark, shown on the card) (scripts/garrison.lua). Hooks:
-- divisions.ORDER_HOOKS[kind] = fn(id, target, opts) -> ok for the extra order kinds "embark" and "garrison";
-- divisions.order_lock = fn(D, kind) -> reason refuses attack orders (out of supply).
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local orders = require("scripts.orders")
local selection = require("scripts.selection")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local match = require("scripts.match")
local targeting = require("scripts.targeting") -- Phase 5 M2 integration: Nation attack-moves spare rails and poles

local divisions = {}

divisions.ISSUER = "divisions"
divisions.STANCES = {"hold", "advance", "screen"}
divisions.KINDS = {move = true, attack_move = true, attack = true, retreat = true, hold = true, stop = true}
divisions.SKIP_KINDS = {hauler = true, commander = true} -- never members: logistics and the hero have their own drivers
divisions.ORDER_HOOKS = {} -- Phase 5 M2 war: [kind] = fn(id, target, opts) -> ok ("embark", "garrison")
divisions.order_lock = nil -- Phase 5 M2 war: fn(D, kind) -> reason when an attack order is refused, else nil

local CHECK_PERIOD = 15      -- controller tick
local CHECK_EVERY = 60       -- each division is looked at this often
local RETARGET_TICKS = 60    -- a division re-targets (attack-move end, advance stance) at most once a second
local RETARGET_RANGE = 40    -- tiles around the division searched for the next enemy at the end of an attack-move
local ADVANCE_RANGE = 40     -- stance advance: idle divisions attack enemies this close
local SCREEN_RANGE = 25      -- stance screen: idle divisions fall back from enemies this close
local SCREEN_STEP = 20
local SCREEN_TICKS = 180
local REGROUP_TICKS = 300    -- a moving division whose group vanished is ordered again at most this often
local MAX_GROUP_FAILS = 3
local SETTLE_TICKS = 20 * 60 -- members still walking to their slots this long after the group arrived are stopped
local STRENGTH_TICKS = 30     -- the cached strength / health / centroid of a division is this fresh at worst
local REJOIN_TICKS = 300      -- a moving division looks for members that dropped out of its group this often

local CMD, DIS = defines.command, defines.distraction
local STANCE_OK = {hold = true, advance = true, screen = true}
-- Phase 5 M2 war: a division whose members all ride a troop train has no live member but must not disband
local function aboard(D) return (D.aboard or 0) > 0 end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function new_stats()
  return {created = 0, disbanded = 0, orders = {}, arrivals = 0, retargets = 0, joins = 0, reinforced = 0,
          reinforce_full = 0, detached = 0, rejoined = 0, regroups = 0, group_fails = 0, stance_moves = 0,
          max_divisions = 0}
end

local function meta()
  local m = storage.division_meta
  if not m then
    m = {}
    storage.division_meta = m
  end
  m.next_id = m.next_id or 1
  m.member = m.member or {}
  m.by_group = m.by_group or {}
  m.barracks = m.barracks or {}
  m.counter = m.counter or {}
  m.stats = m.stats or new_stats()
  return m
end

local function list()
  local l = storage.divisions
  if not l then
    l = {}
    storage.divisions = l
  end
  return l
end

function divisions.init()
  list()
  meta()
end

local changed_callbacks = {}
--- fn(D, what) after a division changed: "created" | "disbanded" | "order" | "members" | "stance" | "name" |
--- "reinforce" | "state". Load time only (scripts/divisiongui.lua).
function divisions.on_changed(fn) changed_callbacks[#changed_callbacks + 1] = fn end

local function changed(D, what)
  for i = 1, #changed_callbacks do changed_callbacks[i](D, what) end
end

--- Counters: created, by_force[force] (created), disbanded, orders[kind], arrivals, retargets, joins, reinforced,
--- reinforce_full, detached, rejoined, regroups, group_fails, stance_moves, max_divisions.
function divisions.stats() return meta().stats end

local function bump(key, n)
  local st = meta().stats
  st[key] = (st[key] or 0) + (n or 1)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function force_name(force)
  if type(force) == "string" then return force end
  return force and force.name
end

local function pos_of(p)
  if type(p) == "table" and p.object_name == "LuaEntity" then p = p.position end
  local x, y = util.xy(p)
  return {x = x, y = y}
end

--- The division's display name as a plain string for logs.
function divisions.label(D)
  if type(D.name) == "string" then return '"' .. D.name .. '"' end
  return "Division " .. tostring(type(D.name) == "table" and D.name[2] or D.id)
end

local function claim(rec, order, dest)
  rec.order, rec.dest, rec.target, rec.issuer, rec.fails = order, dest, nil, divisions.ISSUER, nil
end

local function unclaim(rec)
  if rec.issuer == divisions.ISSUER then
    rec.order, rec.dest, rec.target, rec.issuer, rec.fails = units.IDLE, nil, nil, nil, nil
  end
end

-- Live members as records, sorted by unit number (dead ones leave the registry and, through units.on_removed, D).
-- Sorted by the keys, not by entity reads: a comparator that reads unit_number makes ~130 API calls per division.
local function live_members(D)
  local keys = {}
  for un in pairs(D.units) do keys[#keys + 1] = un end
  table.sort(keys)
  local out = {}
  for _, un in ipairs(keys) do
    local rec = units.get(un)
    if rec then out[#out + 1] = rec end
  end
  return out
end
divisions.live_members = live_members

local function centroid(recs)
  local sx, sy, n = 0, 0, 0
  for _, rec in ipairs(recs) do
    local p = rec.entity.position
    sx, sy, n = sx + p.x, sy + p.y, n + 1
  end
  if n == 0 then return nil end
  return {x = sx / n, y = sy / n}
end

local function move_radius(n) return 3 + math.sqrt(n) end
local function attack_radius(n) return math.min(24, 10 + 1.5 * math.sqrt(n)) end
local ATTACK_GOTO_RADIUS = 2  -- an attack-move's march leg ends this close to the point (then attack_area)

local function home_of(force)
  local cc = buildings.main_cc(force)
  if cc then return {x = cc.position.x, y = cc.position.y} end
  return match.home(force)
end

-- A unit record that may become a member of a division of `force`: a live registered unit of that force, not a
-- hauler or the Commander, not claimed by another module (logistics, commander, the legacy enemy brain).
local function eligible(rec, force)
  if not (rec and rec.entity.valid and rec.force == force) then return false end
  if divisions.SKIP_KINDS[rec.kind] then return false end
  if rec.order ~= units.IDLE and rec.issuer ~= orders.ISSUER and rec.issuer ~= divisions.ISSUER then return false end
  return rec.entity.commandable ~= nil
end

local function records_of(items, force)
  local keys, seen = {}, {}
  for _, item in pairs(items or {}) do
    local un = type(item) == "number" and item or (item.valid and item.unit_number)
    if un and not seen[un] then
      seen[un] = true
      keys[#keys + 1] = un
    end
  end
  table.sort(keys)
  local out = {}
  for _, un in ipairs(keys) do
    local rec = units.get(un)
    if eligible(rec, force) then out[#out + 1] = rec end
  end
  return out
end

local function composition_of(recs)
  local comp = {}
  for _, rec in ipairs(recs) do
    local name = rec.entity.name
    comp[name] = (comp[name] or 0) + 1
  end
  return comp
end

--- Strength target of a division: the sum of its template composition.
function divisions.target_size(D)
  local n = 0
  for _, k in pairs(D.template and D.template.composition or {}) do n = n + k end
  return n
end

---------------------------------------------------------------------------
-- Groups
---------------------------------------------------------------------------
local function unmap_group(D)
  if D.group_id then meta().by_group[D.group_id] = nil end
  D.group_id = nil
end

-- Destroy the division's group. Its members are unlinked and start to wander: callers command them at once.
local function drop_group(D)
  local g = D.group
  unmap_group(D)
  D.group = nil
  if g and g.valid then g.destroy() end
end

-- A new group at `at` with every record in it. The old group (empty by then: add_member moved its members) goes.
local function make_group(D, recs, at)
  local old = D.group
  unmap_group(D)
  local g = recs[1].entity.surface.create_unit_group({position = at, force = D.force})
  for _, rec in ipairs(recs) do g.add_member(rec.entity) end
  D.group, D.group_id = g, g.unique_id
  meta().by_group[g.unique_id] = D.id
  if old and old.valid then old.destroy() end
  return g
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
--- The division record, or nil.
function divisions.get(id) return id and list()[id] or nil end

--- Division id of a unit, or nil.
function divisions.of_unit(unit_number)
  local m = storage.division_meta
  local id = m and m.member[unit_number]
  if id and list()[id] then return id end
  return nil
end

--- The divisions of a force, sorted by id.
function divisions.for_force(force)
  local f = force_name(force)
  local out = {}
  for _, D in pairs(list()) do
    if D.force == f then out[#out + 1] = D end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

--- Live member unit numbers of a division, sorted.
function divisions.members(id)
  local D = list()[id]
  if not D then return {} end
  local out = {}
  for _, rec in ipairs(live_members(D)) do out[#out + 1] = rec.entity.unit_number end
  return out
end

--- Live members, strength target and health share of a division (cached for STRENGTH_TICKS; `fresh` recounts).
function divisions.strength(D, fresh)
  if fresh or not D.n or game.tick - (D.n_tick or 0) >= STRENGTH_TICKS then
    D.n_tick = game.tick
    local hp, max = 0, 0
    local recs = live_members(D)
    for _, rec in ipairs(recs) do
      local e = rec.entity
      hp = hp + (e.health or 0)
      max = max + (e.max_health or 0)
    end
    D.n, D.hp, D.max_hp = #recs, hp, max
    D.pos = centroid(recs) or D.pos
  end
  local ratio = (D.max_hp or 0) > 0 and D.hp / D.max_hp or 0
  return D.n, divisions.target_size(D), ratio
end

--- True while the division has no order running (it stands where its last order ended).
function divisions.is_idle(id)
  local D = list()[id]
  return D ~= nil and D.state == "idle"
end

-- Move one record into D (out of its previous division). Returns true when it joined.
local function take(D, rec)
  local m = meta()
  local un = rec.entity.unit_number
  local old_id = m.member[un]
  if old_id == D.id then return false end
  if old_id then
    local old = list()[old_id]
    if old then
      old.units[un], old.detached[un], old.joining[un] = nil, nil, nil
      if old.settling then old.settling[un] = nil end
      if next(old.units) == nil and not aboard(old) then -- Phase 5 M2 war: not while members ride a train
        divisions.disband(old_id, "its units joined division #" .. D.id)
      else
        old.n = nil
        changed(old, "members")
      end
    end
  end
  D.units[un] = true
  m.member[un] = D.id
  return true
end

--- Form a division of `force` from `items` (LuaEntity or unit numbers; units of other forces, haulers, the Commander
--- and units another module drives are skipped; members of other divisions change division). template = {name?,
--- composition?, stance?}; opts = {owner = "player" | "ai"}. The units keep their current command; the division is
--- idle until its first order. Returns the id, or nil when no unit qualified.
function divisions.create(force, items, template, opts)
  local f = force_name(force)
  local recs = records_of(items, f)
  if #recs == 0 then return nil end
  local m = meta()
  local id = m.next_id
  m.next_id = id + 1
  m.counter[f] = (m.counter[f] or 0) + 1
  template = template or {}
  local stance = STANCE_OK[template.stance] and template.stance or "hold"
  local D = {
    id = id, force = f, name = template.name or {"rts-div.default-name", m.counter[f]},
    default_name = {"rts-div.default-name", m.counter[f]},
    units = {}, detached = {}, joining = {}, settling = {},
    template = {name = template.name, composition = template.composition or composition_of(recs), stance = stance},
    stance = stance, reinforce = template.reinforce ~= false, owner = opts and opts.owner or "player",
    state = "idle", created = game.tick, checked = game.tick + id % CHECK_EVERY - CHECK_EVERY,
  }
  list()[id] = D
  for _, rec in ipairs(recs) do take(D, rec) end
  divisions.strength(D, true)
  local st = m.stats
  st.created = st.created + 1
  st.by_force = st.by_force or {}
  st.by_force[f] = (st.by_force[f] or 0) + 1
  st.max_divisions = math.max(st.max_divisions, table_size(list()))
  local comp = {}
  for name, n in pairs(D.template.composition) do comp[#comp + 1] = string.format("%s=%d", name, n) end
  table.sort(comp)
  util.log("divisions: created #%d %s (%s, %s) with %d units [%s] stance %s at %s", id, divisions.label(D), f, D.owner,
    D.n, table.concat(comp, " "), stance, util.pos_str(D.pos))
  changed(D, "created")
  return id
end

--- Add units to a division. Moving divisions take them into their group; otherwise they walk to the division. Returns
--- the number of units that joined. `why` goes to the log ("reinforce", "player", "ai").
function divisions.add_units(id, items, why)
  local D = list()[id]
  if not D then return 0 end
  local recs = records_of(items, D.force)
  local n = 0
  local g = D.group
  local moving = D.state == "moving" and g and g.valid and D.order
  local at = D.pos or centroid(live_members(D))
  for _, rec in ipairs(recs) do
    if take(D, rec) then
      n = n + 1
      local e = rec.entity
      orders.cancel_queued(e)
      if moving then
        claim(rec, D.order.kind == "retreat" and "move" or (D.order.kind == "attack" and "attack_move" or D.order.kind),
          D.order.target)
        g.add_member(e)
      elseif at then
        claim(rec, "move", at)
        D.joining[e.unit_number] = true
        orders.queue_command(e, {type = CMD.go_to_location, destination = at, radius = 4, distraction = DIS.by_enemy})
      end
      selection.division_joined(id, e.unit_number)
    end
  end
  if n > 0 then
    bump("joins", n)
    D.n = nil
    util.log("divisions: #%d %s: %d unit(s) joined (%s), %d of %d", id, divisions.label(D), n, why or "-",
      table_size(D.units), divisions.target_size(D))
    changed(D, "members")
  end
  return n
end

--- Take units out of their division for good (they keep their current command). Returns how many left.
function divisions.remove_units(items)
  local m = meta()
  local n = 0
  for _, item in pairs(items or {}) do
    local un = type(item) == "number" and item or (item.valid and item.unit_number)
    local id = un and m.member[un]
    local D = id and list()[id]
    if D then
      D.units[un], D.detached[un], D.joining[un] = nil, nil, nil
      m.member[un] = nil
      local rec = units.get(un)
      if rec then unclaim(rec) end
      n = n + 1
      D.n = nil
      if next(D.units) == nil and not aboard(D) then -- Phase 5 M2 war: not while members ride a train
        divisions.disband(id, "its last unit left")
      else
        changed(D, "members")
      end
    end
  end
  return n
end

--- Phase 5 M2 war: put units into division `id` without an order (troop train disembark, scripts/garrison.lua).
--- Returns the number of units that joined.
function divisions.attach(id, items, why)
  local D = list()[id]
  if not D then return 0 end
  local n = 0
  for _, rec in ipairs(records_of(items, D.force)) do
    if take(D, rec) then n = n + 1 end
  end
  if n > 0 then
    D.n = nil
    util.log("divisions: #%d %s: %d unit(s) attached (%s), %d of %d", id, divisions.label(D), n, why or "-",
      table_size(D.units), divisions.target_size(D))
    changed(D, "members")
  end
  return n
end

--- Disband a division: its units stay where they are as loose, idle units. Returns true when it existed.
function divisions.disband(id, why)
  local l = list()
  local D = l[id]
  if not D then return false end
  l[id] = nil
  local m = meta()
  local g = D.group
  unmap_group(D)
  D.group = nil
  local recs = {}
  for un in pairs(D.units) do
    m.member[un] = nil
    local rec = storage.units and storage.units[un]
    if rec and rec.entity.valid then
      unclaim(rec)
      recs[#recs + 1] = rec
    end
  end
  if g and g.valid then g.destroy() end
  for _, rec in ipairs(recs) do
    if rec.order == units.IDLE then units.stop(rec.entity) end -- unlinked group members would wander
  end
  for b, bid in pairs(m.barracks) do
    if bid == id then m.barracks[b] = nil end
  end
  bump("disbanded")
  util.log("divisions: #%d %s (%s) disbanded (%s), %d units released", id, divisions.label(D), D.force, why or "-",
    #recs)
  changed(D, "disbanded")
  return true
end

--- Order a division: kind = "move" | "attack_move" | "attack" | "retreat" | "hold" | "stop"; target = MapPosition or
--- LuaEntity (retreat: optional, default the rally point or home). One unit-group command through the order queue;
--- every member (detached ones too) takes part. opts.auto marks orders the division gave itself (stance, re-target).
--- Returns true when the order was given.
function divisions.order(id, kind, target, opts)
  local hook = divisions.ORDER_HOOKS[kind] -- Phase 5 M2 war: embark, garrison
  if hook then return hook(id, target, opts) end
  local D = list()[id]
  if not (D and divisions.KINDS[kind]) then return false end
  -- Phase 5 M2 war: a division out of supply takes no attack order (scripts/warsupply.lua)
  if divisions.order_lock and (kind == "attack_move" or kind == "attack") then
    local why = divisions.order_lock(D, kind)
    if why then
      if not (opts and opts.auto) then
        util.log("divisions: #%d %s order %s refused (%s)", id, divisions.label(D), kind, why)
      end
      return false, why
    end
  end
  local recs = live_members(D)
  if #recs == 0 then
    if aboard(D) then return false end -- Phase 5 M2 war: every member rides a troop train
    divisions.disband(id, "no members left")
    return false
  end
  D.embark = nil -- Phase 5 M2 war: any order cancels boarding (the embark hook sets it again after its move)
  D.no_train = nil -- Phase 5 M2 QA round 1: and the card's "No troop train"
  local pos = target and pos_of(target) or nil
  D.detached, D.joining, D.settling = {}, {}, {}
  local m = meta()
  if kind == "hold" or kind == "stop" then
    drop_group(D)
    for _, rec in ipairs(recs) do
      orders.cancel_queued(rec.entity)
      if kind == "hold" then
        claim(rec, "hold", pos_of(rec.entity.position))
      else
        rec.order, rec.dest, rec.target, rec.issuer, rec.fails = units.IDLE, nil, nil, nil, nil
      end
      units.stop(rec.entity)
    end
    D.state = kind == "hold" and "holding" or "idle"
  else
    if kind == "retreat" and not pos then pos = D.rally or home_of(D.force) end
    if not pos then return false end
    local n = #recs
    local cmd
    if kind == "move" or kind == "retreat" then
      cmd = {type = CMD.go_to_location, destination = pos, radius = move_radius(n), distraction = DIS.none}
    elseif targeting.careful_group(recs) then
      -- Phase 5 M2 integration (scripts/targeting.lua): in Nation mode a division marches fighting military targets
      -- only and never clears an area, so rails, signals and poles on the way and at the point survive; when an enemy
      -- building stands at the point (an AI target, or arrive()'s re-target) it strikes that building alone. arrive()
      -- re-targets as before. All-raider divisions keep the compound below.
      local surface = recs[1].entity.surface
      local bld = targeting.nearest_building(surface, pos, D.force, targeting.ATTACK_RADIUS + 1)
      local go = {type = CMD.go_to_location, destination = pos, radius = ATTACK_GOTO_RADIUS, distraction = DIS.by_enemy}
      cmd = bld and {type = CMD.compound, structure_type = defines.compound_command.return_last, commands = {go,
        {type = CMD.attack_area, destination = bld.position, radius = targeting.ATTACK_RADIUS, distraction = DIS.by_enemy},
      }} or go
    else
      -- QA round 1 (protocol step 33): march to the point first (fighting what it meets), then clear the area
      cmd = {type = CMD.compound, structure_type = defines.compound_command.return_last, commands = {
        {type = CMD.go_to_location, destination = pos, radius = ATTACK_GOTO_RADIUS, distraction = DIS.by_anything},
        {type = CMD.attack_area, destination = pos, radius = attack_radius(n), distraction = DIS.by_anything},
      }}
    end
    local rec_order = kind == "retreat" and "move" or (kind == "attack" and "attack_move" or kind)
    for _, rec in ipairs(recs) do
      orders.cancel_queued(rec.entity)
      claim(rec, rec_order, pos)
    end
    local g = make_group(D, recs, centroid(recs))
    orders.queue_command(g, cmd, {start_moving = true})
    D.state = "moving"
  end
  D.order = {kind = kind, target = pos, tick = game.tick, auto = opts and opts.auto or nil}
  D.fails = opts and opts.keep_fails and D.fails or nil
  local st = m.stats
  st.orders[kind] = (st.orders[kind] or 0) + 1
  util.log("divisions: #%d %s order %s%s n=%d%s%s", id, divisions.label(D), kind,
    pos and (" -> " .. util.pos_str(pos)) or "", #recs, D.group_id and (" group #" .. D.group_id) or "",
    opts and opts.auto and (" (" .. opts.auto .. ")") or "")
  changed(D, "order")
  return true
end

--- Set the stance ("hold" | "advance" | "screen"). Returns true when it changed.
function divisions.set_stance(id, stance)
  local D = list()[id]
  if not (D and STANCE_OK[stance]) or D.stance == stance then return false end
  D.stance = stance
  D.template.stance = stance
  util.log("divisions: #%d %s stance -> %s", id, divisions.label(D), stance)
  changed(D, "stance")
  return true
end

--- Rename (a plain string, at most 40 characters; empty restores the default name). Returns true when it changed.
function divisions.rename(id, text)
  local D = list()[id]
  if not D then return false end
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > 40 then text = string.sub(text, 1, 40) end
  if text == "" then
    D.name = D.default_name or {"rts-div.default-name", D.id}
  else
    D.name = text
  end
  D.template.name = type(D.name) == "string" and D.name or nil
  util.log("divisions: #%d renamed to %s", id, divisions.label(D))
  changed(D, "name")
  return true
end

--- Accept reinforcements (true) or keep the losses (false).
function divisions.set_reinforce(id, on)
  local D = list()[id]
  if not D then return false end
  D.reinforce = on == true
  util.log("divisions: #%d %s reinforce %s", id, divisions.label(D), tostring(D.reinforce))
  changed(D, "reinforce")
  return true
end

--- Rally point of a division (the default target of a retreat).
function divisions.set_rally(id, position)
  local D = list()[id]
  if not D then return false end
  D.rally = position and pos_of(position) or nil
  return true
end

--- Barracks `barracks_un` sends its new units to division `id` (nil: to its rally point as before).
function divisions.set_barracks(barracks_un, id)
  local m = meta()
  local rec = buildings.get(barracks_un)
  if not (rec and rec.kind == "barracks") then return false end
  if id ~= nil then
    local D = list()[id]
    if not (D and D.force == rec.force) then return false end
  end
  m.barracks[barracks_un] = id
  util.log("divisions: barracks #%d (%s) reinforces %s", barracks_un, rec.force,
    id and string.format("division #%d %s", id, divisions.label(list()[id])) or "no division (rally point)")
  local D = id and list()[id]
  if D then changed(D, "reinforce") end
  return true
end

--- The division a barracks reinforces, or nil.
function divisions.barracks_division(barracks_un)
  local m = storage.division_meta
  local id = m and m.barracks[barracks_un]
  if id and list()[id] then return id end
  return nil
end

---------------------------------------------------------------------------
-- Arrival, controller, stances
---------------------------------------------------------------------------
-- The members of an idle division must not wander: those that lost their group (or never had one) get `stop`.
local function settle(D, recs)
  local gid = D.group and D.group.valid and D.group_id or nil
  for _, rec in ipairs(recs) do
    if rec.order == units.IDLE then
      local c = rec.entity.commandable
      local pg = c and c.parent_group
      if not (gid and pg and pg.unique_id == gid) then
        local cmd = c and c.has_command and c.command
        if not (cmd and cmd.type == CMD.stop) then units.stop(rec.entity) end
      end
    end
  end
end

-- The order is over: every member idle (stopped, or standing in the finished group), the division idle.
local function finish_arrival(D, why)
  local order = D.order
  local recs = live_members(D)
  for _, rec in ipairs(recs) do unclaim(rec) end
  D.state = "idle"
  D.settling = {}
  if order then order.done = game.tick end
  bump("arrivals")
  D.n = nil
  util.log("divisions: #%d %s arrived (%s %s, %s) after %.1f s at %s", D.id, divisions.label(D),
    order and order.kind or "-", order and util.pos_str(order.target) or "-", why,
    order and (game.tick - order.tick) / 60 or 0, util.pos_str(centroid(recs)))
  settle(D, recs)
  changed(D, "state")
end

-- The group finished its command (event or polled state). A group finishes when its expected position arrives, and
-- slow members can trail 15-20 tiles behind (functional test: heavies and drones in a walker division); a group also
-- finishes as soon as it stands within its own size of the point (header). So after every order the members walk to
-- formation slots around the target (short paths through the queue) and stop there ("settling", at most
-- SETTLE_TICKS): moves and retreats ignoring enemies, attack-moves fighting what they meet (distraction by_enemy).
-- Attack-moves first re-target the nearest enemy.
local function arrive(D, why)
  local order = D.order
  local attack = order and (order.kind == "attack_move" or order.kind == "attack")
  if attack then
    if game.tick - (D.last_retarget or -RETARGET_TICKS) < RETARGET_TICKS then return end -- throttled: next pass
    local recs = live_members(D)
    local at = (D.group and D.group.valid and D.group.position) or centroid(recs)
    -- Phase 5 M2 integration: in Nation mode an enemy building close by when no military target is left
    local enemy = at and recs[1] and targeting.next_enemy(recs[1].entity.surface, at, D.force, RETARGET_RANGE,
      targeting.careful_group(recs))
    if enemy then
      D.last_retarget = game.tick
      bump("retargets")
      -- Phase 5 M2 war: refused while out of supply; the attack-move then ends here
      if divisions.order(D.id, "attack_move", enemy.position, {auto = "re-target"}) then return end
    end
  end
  if order and order.target and (attack or order.kind == "move" or order.kind == "retreat") then
    local recs = live_members(D)
    if #recs > 0 then
      drop_group(D) -- the members get their slot commands right away
      local slots = orders.formation(recs, order.target)
      D.settling = {}
      for i, rec in ipairs(recs) do
        claim(rec, attack and "attack_move" or "move", slots[i])
        D.settling[rec.entity.unit_number] = true
        orders.queue_command(rec.entity, {type = CMD.go_to_location, destination = slots[i], radius = 1,
                                          distraction = attack and DIS.by_enemy or DIS.none})
      end
      D.state, D.settle_tick = "settling", game.tick
      return
    end
  end
  finish_arrival(D, why)
end

local function group_failed(D)
  D.fails = (D.fails or 0) + 1
  bump("group_fails")
  local order = D.order
  util.log("divisions: #%d %s: group command failed (%s, %d in a row)", D.id, divisions.label(D),
    order and order.kind or "-", D.fails)
  if order and order.target and D.fails < MAX_GROUP_FAILS and order.kind ~= "hold" and order.kind ~= "stop" then
    order.tick = game.tick -- the controller orders again after REGROUP_TICKS
    drop_group(D)
    D.state = "moving"
    return
  end
  drop_group(D)
  local recs = live_members(D)
  for _, rec in ipairs(recs) do unclaim(rec) end
  D.state = "idle"
  settle(D, recs)
  changed(D, "state")
end

local function stance_step(D, recs)
  local stance = D.stance
  if stance == "hold" or not D.pos then return end
  local tick = game.tick
  local surface = recs[1].entity.surface
  if stance == "advance" then
    if tick - (D.last_retarget or -RETARGET_TICKS) < RETARGET_TICKS then return end
    local enemy = surface.find_nearest_enemy({position = D.pos, max_distance = ADVANCE_RANGE, force = D.force})
    if enemy then
      D.last_retarget = tick
      bump("stance_moves")
      divisions.order(D.id, "attack_move", enemy.position, {auto = "stance advance"})
    end
  elseif stance == "screen" then
    if tick - (D.last_stance or -SCREEN_TICKS) < SCREEN_TICKS then return end
    local enemy = surface.find_nearest_enemy({position = D.pos, max_distance = SCREEN_RANGE, force = D.force})
    if enemy then
      local dx, dy = D.pos.x - enemy.position.x, D.pos.y - enemy.position.y
      local len = math.sqrt(dx * dx + dy * dy)
      if len < 0.5 then dx, dy, len = 1, 0, 1 end
      D.last_stance = tick
      bump("stance_moves")
      divisions.order(D.id, "move", {x = D.pos.x + dx / len * SCREEN_STEP, y = D.pos.y + dy / len * SCREEN_STEP},
        {auto = "stance screen"})
    end
  end
end

local function check(D)
  local recs = live_members(D)
  if #recs == 0 then
    if aboard(D) then return end -- Phase 5 M2 war: every member rides a troop train
    divisions.disband(D.id, "no members left")
    return
  end
  local tick = game.tick
  if D.state == "moving" then
    local g = D.group
    if not (g and g.valid) then
      if g then unmap_group(D) D.group = nil end -- no invalid LuaObject stays in storage
      if D.order and D.order.target and tick - D.order.tick >= REGROUP_TICKS then
        bump("regroups")
        divisions.order(D.id, D.order.kind, D.order.target, {auto = "regroup", keep_fails = true})
      end
    elseif g.state == defines.group_state.finished then
      arrive(D, "group finished")
    else
      D.pos = g.position
      if tick - (D.rejoin_tick or D.order.tick) < REJOIN_TICKS then return end
      D.rejoin_tick = tick
      -- members that dropped out of the group (disowned stragglers, a direct command) rejoin it; detached ones do not
      local gid = D.group_id
      for _, rec in ipairs(recs) do
        local un = rec.entity.unit_number
        if not D.detached[un] and rec.issuer == divisions.ISSUER then
          local pg = rec.entity.commandable.parent_group
          if not (pg and pg.unique_id == gid) then
            g.add_member(rec.entity)
            bump("rejoined")
          end
        end
      end
    end
  elseif D.state == "settling" then
    if next(D.settling) == nil or tick - (D.settle_tick or 0) >= SETTLE_TICKS then
      finish_arrival(D, next(D.settling) and "settle timeout" or "in formation")
    end
  elseif D.state == "idle" then
    if D.stance ~= "hold" then divisions.strength(D) end -- the stances need the centroid
    if tick - (D.settle_check or 0) >= REJOIN_TICKS then -- safety net; arrivals and group drops stop members at once
      D.settle_check = tick
      settle(D, recs)
    end
    stance_step(D, recs)
  end
end

events.on_nth_tick(CHECK_PERIOD, function(e)
  local l = storage.divisions
  if not l or next(l) == nil then return end
  local due = {}
  for id, D in pairs(l) do
    if e.tick - (D.checked or 0) >= CHECK_EVERY then due[#due + 1] = id end
  end
  table.sort(due)
  for _, id in ipairs(due) do
    local D = l[id]
    if D then
      D.checked = e.tick
      check(D)
    end
  end
end)

---------------------------------------------------------------------------
-- Events and hooks
---------------------------------------------------------------------------
events.on(defines.events.on_ai_command_completed, function(e)
  local m = storage.division_meta
  if not m then return end
  local id = m.by_group[e.unit_number]
  if id then
    local D = list()[id]
    if D and D.group_id == e.unit_number and D.state == "moving" then
      if e.result == defines.behavior_result.success then arrive(D, "completed") else group_failed(D) end
    end
    return
  end
  local rec = storage.units and storage.units[e.unit_number]
  if not (rec and rec.issuer == divisions.ISSUER and rec.entity.valid) then return end
  if rec.order == "hold" then
    units.stop(rec.entity)
    return
  end
  local did = m.member[e.unit_number]
  local D = did and list()[did]
  if D and D.settling and D.settling[e.unit_number] then
    -- a member reached its formation slot after the march
    D.settling[e.unit_number] = nil
    unclaim(rec)
    units.stop(rec.entity)
    if next(D.settling) == nil and D.state == "settling" then finish_arrival(D, "in formation") end
    return
  end
  if D and D.joining[e.unit_number] then
    -- a reinforcement reached its division
    D.joining[e.unit_number] = nil
    if D.state == "moving" and D.group and D.group.valid and D.order then
      local kind = D.order.kind
      claim(rec, kind == "retreat" and "move" or (kind == "attack" and "attack_move" or kind), D.order.target)
      D.group.add_member(rec.entity)
      return
    elseif D.state == "holding" then
      claim(rec, "hold", pos_of(rec.entity.position))
      units.stop(rec.entity)
      return
    end
  end
  unclaim(rec)
  units.stop(rec.entity)
end)

-- A member died or left the registry.
units.on_removed(function(unit_number)
  local m = storage.division_meta
  local id = m and m.member[unit_number]
  if not id then return end
  m.member[unit_number] = nil
  local D = list()[id]
  if not D then return end
  D.units[unit_number], D.detached[unit_number], D.joining[unit_number] = nil, nil, nil
  if D.settling then D.settling[unit_number] = nil end
  D.n = nil
  if next(D.units) == nil and not aboard(D) then -- Phase 5 M2 war: not while members ride a train
    divisions.disband(id, "no members left")
  else
    changed(D, "members")
  end
end)

buildings.on_removed(function(unit_number)
  local m = storage.division_meta
  if m and m.barracks[unit_number] then m.barracks[unit_number] = nil end
end)

-- Reinforcement: a new unit of a barracks set to reinforce a division joins it (production.lua spawn hook).
production.on_spawned(function(unit, brec)
  local m = storage.division_meta
  local id = m and brec.entity.valid and m.barracks[brec.entity.unit_number]
  if not id then return end
  local D = list()[id]
  if not D then
    m.barracks[brec.entity.unit_number] = nil
    return
  end
  if not D.reinforce or D.force ~= brec.force then return end
  if table_size(D.units) >= divisions.target_size(D) then
    bump("reinforce_full")
    return
  end
  if divisions.add_units(id, {unit}, "reinforce from barracks #" .. brec.entity.unit_number) > 0 then
    bump("reinforced")
  end
end)

-- Orders for units of divisions (orders.lua): whole divisions take one division order, partly ordered ones detach the
-- ordered members, which then take the order as loose units.
orders.set_division_router(function(entities, kind, target)
  local m = storage.division_meta
  if not (m and next(m.member)) then return entities, 0, nil end
  local l = list()
  local by_div, rest, ids = {}, {}, {}
  for _, e in pairs(entities) do
    local id = e.valid and e.unit_number and m.member[e.unit_number]
    if id and l[id] then
      local t = by_div[id]
      if not t then
        t = {}
        by_div[id] = t
        ids[#ids + 1] = id
      end
      t[#t + 1] = e
    else
      rest[#rest + 1] = e
    end
  end
  if #ids == 0 then return entities, 0, nil end
  table.sort(ids)
  local handled, surface = 0, nil
  for _, id in ipairs(ids) do
    local D = l[id]
    local ordered = by_div[id]
    local live = live_members(D)
    if #ordered >= #live then
      if divisions.order(id, kind, target) then
        handled = handled + #live
        surface = surface or (live[1] and live[1].entity.surface)
      end
    else
      for _, e in ipairs(ordered) do
        local rec = storage.units[e.unit_number]
        if rec then unclaim(rec) end
        D.detached[e.unit_number] = true
        rest[#rest + 1] = e
      end
      bump("detached", #ordered)
      util.log("divisions: #%d %s: %d of %d members detached by a %s order", id, divisions.label(D), #ordered, #live,
        kind)
    end
  end
  return rest, handled, surface
end)

selection.set_division_hooks({of = divisions.of_unit, members = divisions.members})

-- A torn-down match takes its divisions with it (units.despawn_all already emptied them).
match.on_teardown(function()
  for _, D in pairs(storage.divisions or {}) do
    if D.group and D.group.valid then D.group.destroy() end
  end
  storage.divisions = {}
  local stats = storage.division_meta and storage.division_meta.stats
  storage.division_meta = nil
  meta().stats = stats or new_stats()
end)

--- One line per force for logs: "rts-ai-1: 2 divisions [#3 moving 14/16, #5 idle 8/8]".
function divisions.describe(force)
  local parts = {}
  local ds = divisions.for_force(force)
  for _, D in ipairs(ds) do
    local n, N = divisions.strength(D)
    parts[#parts + 1] = string.format("#%d %s %d/%d", D.id, D.state, n, N)
  end
  return string.format("%s: %d divisions [%s]", force_name(force), #ds, table.concat(parts, ", "))
end

return divisions
