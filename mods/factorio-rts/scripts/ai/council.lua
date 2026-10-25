-- Phase 5 M3 ai (docs/PHASE5-M3.md D7, §3 "ai/council.lua"; study docs/research/scale/war-ai-performance.md §4.4): the
-- war council of an AI nation. Nation mode only; ai/commander.lua calls council.step(C, surface) in slice 3 after the
-- army pass, the council works every difficulty `council` ticks (staggered per nation).
--
--   council.step(C, surface)        the pass below
--   council.operations(force) -> {{id, kind = "capture"|"siege"|"relief"|"defend"|"raid"|"bomb", target, phase, since,
--                                   divisions, group}}                      the operations not finished yet
--   council.may_launch(C, target) -> bool   army.lua asks before a new offensive (the difficulty's concurrent `ops`)
--   council.research_want(C) -> {tech, ...} Fortification at war, Aviation in Age II, Air Force in Age III
--   council.air_want(C) -> {[kit] = n}      plane kits the barracks should make (ai/mix.lua)
--   council.rail_programs(C), artillery_want(C)   (0.1.1) the siege railways' rail programs and their artillery train's
--                                           kits (ai/planner.lua makes their depots, crew kits, artillery kits, shells)
--   council.describe(force)
--
-- Fronts (fronts.lua): every own segment whose enemy strength near it (fronts.STRENGTH, i.e. ai/intel.lua for an AI
-- nation) is at least hold_strength gets a holding division (divisions.order(id, "hold_line", segment)) sized to the
-- strength x 1.5, within hold_min..hold_max units, from the idle army; at most hold_units (1 - reserve: the 25 %
-- reserve) of the idle units hold lines. Holding units are kept out of the army pool (army.lua C.army.held). A segment
-- that is gone (peace) or quiet for hold_quiet ticks releases its division. A segment whose threat stays at or above
-- belt_threat for belt_after ticks gets a fort belt (belts.plan_front: Fortification first), at most `belts` belts.
-- Operations: every attack, defence and relief group of ai/army.lua and every harass group of ai/raids.lua is an
-- operation with phases: capture (assemble -> advance -> siege -> capture -> consolidate), raid (assemble -> advance ->
-- strike), relief and defend (move -> engage); any phase ends in "return" when the group heads home and "done" when it
-- is gone. A phase that outlasts its timeout recalls the group (army.recall). A siege with an own depot within
-- artillery_range of the target deploys an artillery train there (Military railways) in bombard stance. Bombers fly a
-- "bomb" operation at the target of a capture in its advance phase.
-- Air: Aviation in Age II (at war or from air_from), an airfield at the capital, `scouts` scout planes in an all-plane
-- division that patrols the most threatened segment (else the way to the nearest rival); interceptors (Air Force) when
-- enemy planes were seen.
-- (0.1.1) Siege railways: a forward depot and a line from the capital towards a capture's target, a war goal or the
-- nearest enemy city at war, for an artillery train (council.siege_step).
-- Money: a city under attack hires garrison points (sinks.hire_garrison, balance above hire_at); mercenaries when the
-- capital is attacked and the idle army is small; (0.1.1) in debt stage 2+ idle units retire (council.debt_step).
--
-- State: storage.nations[force].council = K = {next, ops = {[id] = op}, next_op, by_group = {[gid] = op id}, holds =
--   {[segment id] = {div, since, quiet}}, held = (units are in C.army.held), belts = {[segment id] = plan id},
--   threat_since = {[segment id] = tick}, air = {airfield_key, patrol, interceptors, bombers}, hired = {[city] = tick},
--   stats = {ops, aborted, holds, belts, patrols, artillery, bombs, hires, mercs}}.
-- Log lines "[rts] council: <force> ...".
local util = require("scripts.util")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")
local layout = require("scripts.ai.layout")
local construction = require("scripts.ai.construction")
local data = require("scripts.ai.orders_data")
local deps = require("scripts.ai.deps")
local difficulty = require("scripts.ai.difficulty")
local intel = require("scripts.ai.intel")
local army = require("scripts.ai.army")
local balance = require("balance")

local council = {}

local CB = balance.nation.ai3.council
local FORTIFICATION = "rts-fortification"
local MILITARY_RAILWAYS = "rts-military-railways"
local AVIATION = "rts-aviation"
local AIR_FORCE = "rts-air-force"
local AIRFIELD = "rts-airfield"
local ELECTRIFICATION = "rts-electrification"
local SCOUT_KIT, INTERCEPTOR_KIT, BOMBER_KIT = "rts-scout-plane-kit", "rts-interceptor-kit", "rts-bomber-kit"
data.FACTORY_RECIPE[AIRFIELD] = AIRFIELD

local OFFENSIVE = {capture = true, siege = true, raid = true, bomb = true}
local FIRST_PHASE = {capture = "assemble", siege = "assemble", raid = "assemble", relief = "move", defend = "move",
                     bomb = "fly"}

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  -- (numbers before strings: K.belts holds front segment ids and "c<city id>" sector keys)
  table.sort(out, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  return out
end

local function K_of(force_name, create)
  local N = storage.nations and storage.nations[force_name]
  if not N then return nil end
  local K = N.council
  if not K and create then
    K = {next = 0, ops = {}, next_op = 1, by_group = {}, holds = {}, belts = {}, threat_since = {}, air = {},
         hired = {}, stats = {ops = 0, aborted = 0, holds = 0, belts = 0, patrols = 0, artillery = 0, bombs = 0,
                              hires = 0, mercs = 0, interceptors = 0}}
    N.council = K
  end
  return K
end
council.state = function(force_name) return K_of(force_name, false) end

local function capital_of(force_name)
  local N = storage.nations and storage.nations[force_name]
  local cities = deps.cities
  return N and cities and cities.get(N.capital) or nil
end

local function has_tech(force_name, name)
  return deps.research ~= nil and deps.research.has(force_name, name)
end

local function age_of(force_name)
  return deps.ages and deps.ages.of(force_name) or 1
end

local function at_war(force_name)
  return diplomacy.at_war and diplomacy.at_war(force_name)
end

local function rails_depot(un)
  local rails = deps.rails
  return un and rails and rails.depot and rails.depot(un) or nil
end

local function balance_of(force_name)
  local t = mod("treasury")
  return t and t.balance and t.balance(force_name) or 0
end

local function clock()
  local m = storage.match
  local s = (m and m.tick_started) and (game.tick - m.tick_started) / 60 or 0
  return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
end

---------------------------------------------------------------------------
-- Operations
---------------------------------------------------------------------------
-- A front segment's name for the log (fronts.lua names are localised tables: they logged as "table")
local function seg_name(seg)
  return type(seg.name) == "string" and seg.name or ("#" .. tostring(seg.id))
end

local function group_list(G)
  local list = {}
  for un in pairs(G.members) do
    local rec = units.get(un)
    if rec and rec.entity.valid then list[#list + 1] = rec.entity end
  end
  return list
end

local function set_phase(C, op, phase, why)
  if op.phase == phase then return end
  op.history[#op.history + 1] = phase .. "@" .. clock()
  local K = K_of(C.force, false)
  if K and #op.history == 2 then K.stats.phased = (K.stats.phased or 0) + 1 end -- an operation with phases
  util.log("council: %s operation #%d %s: %s -> %s%s", C.force, op.id, op.kind, op.phase, phase,
    why and (" (" .. why .. ")") or "")
  op.phase, op.since = phase, game.tick
end

local function new_op(C, K, kind, target, gid, division)
  local id = K.next_op
  K.next_op = id + 1
  local op = {id = id, kind = kind, target = target, group = gid, groups = {gid}, divisions = division and {division} or {},
              phase = FIRST_PHASE[kind] or "advance", since = game.tick, started = game.tick, history = {}}
  op.history[1] = op.phase .. "@" .. clock()
  K.ops[id] = op
  if gid then K.by_group[gid] = id end
  K.stats.ops = K.stats.ops + 1
  util.log("council: %s operation #%d %s -> %s %s%s (group #%s, division #%s): phase %s", C.force, id, kind,
    target and target.kind or "-", target and target.position and util.pos_str(target.position) or "-",
    target and target.city and (" city " .. target.city) or "", tostring(gid), tostring(division), op.phase)
  return op
end

local function end_op(C, K, op, how)
  if op.phase ~= "done" then set_phase(C, op, "done", how) end
  op.ended, op.result = game.tick, how
  if op.group then K.by_group[op.group] = nil end
  for _, g in ipairs(op.groups or {}) do K.by_group[g] = nil end
  util.log("council: %s operation #%d %s ended: %s after %.0f s [%s]", C.force, op.id, op.kind, how,
    (game.tick - op.started) / 60, table.concat(op.history, " "))
  K.ops[op.id] = nil
  K.done = (K.done or 0) + 1
  K.last_done = {id = op.id, kind = op.kind, how = how, history = table.concat(op.history, " ")}
end

-- The kind of a new army group.
local function kind_of(G)
  if G.relief then return "relief" end
  if G.state == "defend" then return "defend" end
  if G.state == "harass" then return "raid" end
  if G.state == "attack" then
    if G.target and G.target.kind == "city" then return "capture" end
    return "raid"
  end
  return nil
end

-- Deploy an artillery train for a siege: at the own depot nearest the target within artillery_range; else (0.1.1,
-- issue #4) at the capital end of the siege railway to that target (council.siege_step) once it is open, sent along it
-- to its forward depot. Tried every 30 s while the operation advances or besieges, until a train is out.
local function siege_artillery(C, K, op)
  if op.artillery_train or not (op.target and op.target.position) then return end
  if game.tick < (op.art_next or 0) then return end
  op.art_next = game.tick + 30 * 60
  local tw = mod("trainswar")
  local R = storage.rails
  if not (tw and tw.deploy and R and has_tech(C.force, MILITARY_RAILWAYS)) then return end
  local best, bd
  for _, un in ipairs(sorted_keys(R.depots or {})) do
    local d = R.depots[un]
    if d.force == C.force and d.entity and d.entity.valid then
      local dd = dist(d.entity.position, op.target.position)
      if dd <= CB.artillery_range and (not bd or dd < bd) then best, bd = un, dd end
    end
  end
  local S = K.siege and op.target.city and K.siege[op.target.city]
  if S and S.train then
    -- the siege railway's train is out already (council.siege_step)
    op.artillery, op.artillery_train = S.train, S.train
    op.kind = "siege"
    return
  end
  local via -- the siege railway's forward depot (the train goes there after its deploy at the capital end)
  local from = best
  if S and S.state == "open" and S.A and S.A.depot_a and S.A.depot_b and rails_depot(S.A.depot_b) then
    -- (the forward depot's own network holds no kits: the train comes from the line's capital end)
    from, via, bd = S.A.depot_a, S.A.depot_b, dist(rails_depot(S.A.depot_b).entity.position, op.target.position)
  end
  if not from then return end
  local train, why = tw.deploy(from, tw.KIND or "artillery", false)
  if train then
    tw.set_stance(train.id, "bombard")
    if via and tw.send_to_depot then tw.send_to_depot(train.id, via) end
    op.artillery, op.artillery_train = train.id, train.id
    op.kind = "siege"
    if S then S.train = train.id end
    K.stats.artillery = K.stats.artillery + 1
    util.log("council: %s operation #%d: artillery train %d at depot #%d%s (%.0f tiles from the target) bombards",
      C.force, op.id, train.id, from, via and string.format(", sent along the siege railway to depot #%d", via) or "",
      bd or -1)
  elseif op.art_why ~= why then
    op.art_why = why
    util.log("council: %s operation #%d: no artillery train at depot #%d (%s)", C.force, op.id, from, tostring(why))
  end
end

local function ops_step(C, K)
  local a = C.army
  if not a then return end
  local tick = game.tick
  -- new groups: a reinforcement (a group with the target of an operation under way) joins that operation
  for _, gid in ipairs(sorted_keys(a.groups)) do
    local G = a.groups[gid]
    if not K.by_group[gid] then
      local kind = kind_of(G)
      if kind then
        local t = G.target
        local joined
        if t and t.position then
          for _, id in ipairs(sorted_keys(K.ops)) do
            local op = K.ops[id]
            -- (a capture whose artillery train deployed is a "siege" now; its reinforcements still join it: they
            -- started a second operation on the same city, wave B.2 war probe)
            local same = op.kind == kind or (kind == "capture" and op.kind == "siege")
            if not joined and same and op.phase ~= "return" and op.target and op.target.position
               and dist(op.target.position, t.position) <= 12 and (t.city == nil or t.city == op.target.city) then
              joined = op
            end
          end
        end
        if joined then
          joined.groups[#joined.groups + 1] = gid
          K.by_group[gid] = joined.id
          if G.division then joined.divisions[#joined.divisions + 1] = G.division end
          util.log("council: %s operation #%d %s: group #%d (%d units) joins (phase %s)", C.force, joined.id, kind, gid,
            table_size(G.members), joined.phase)
        else
          local op = new_op(C, K, kind, t and {kind = t.kind, position = t.position and {x = t.position.x, y = t.position.y},
                                               city = t.city, force = t.force} or nil, gid, G.division)
          if G.state == "harass" then op.harass = true end -- raids.lua's raider harass: outside the offensive limit
        end
      end
    end
  end
  -- phases (the operation's primary group: the first of its groups still alive)
  for _, id in ipairs(sorted_keys(K.ops)) do
    local op = K.ops[id]
    if op.group and not a.groups[op.group] then
      for _, g in ipairs(op.groups or {}) do
        if a.groups[g] then
          op.group = g
          break
        end
      end
    end
    local G = op.group and a.groups[op.group]
    if op.group and not G then
      local captured = op.target and op.target.city and storage.cities and storage.cities[op.target.city]
        and storage.cities[op.target.city].force == C.force
      end_op(C, K, op, captured and "captured" or (op.phase == "return" and "back home" or "group disbanded"))
    elseif G then
      local list = group_list(G)
      local c = util.centroid(list)
      local tpos = G.target and G.target.position or (op.target and op.target.position)
      if G.target and G.target.position then
        op.target = op.target or {}
        op.target.position = {x = G.target.position.x, y = G.target.position.y}
        op.target.city = G.target.city or op.target.city
      end
      if G.state == "retreat" or G.state == "return" then
        set_phase(C, op, "return", G.state == "retreat" and "retreat" or "heading home")
      elseif op.kind == "capture" or op.kind == "siege" or op.kind == "raid" then
        local d = (c and tpos) and dist(c, tpos) or math.huge
        -- (half the group within siege_range counts as there: far mercenaries pooled into it held its centre out of
        -- range until the city fell, and the siege phase and its artillery train never came, wave B.2 war probe)
        if tpos and d > CB.siege_range then
          local near = 0
          for _, e in ipairs(list) do
            if e.valid and dist(e.position, tpos) <= CB.siege_range then near = near + 1 end
          end
          if #list > 0 and near * 2 >= #list then d = CB.siege_range end
        end
        if op.phase == "assemble" then
          set_phase(C, op, "advance", string.format("%d units on the way, %.0f tiles", #list, d))
        elseif op.phase == "advance" and d <= CB.siege_range then
          set_phase(C, op, (op.kind == "raid") and "strike" or "siege", string.format("%.0f tiles from the target", d))
          if op.kind ~= "raid" then siege_artillery(C, K, op) end
        elseif op.phase == "siege" then
          siege_artillery(C, K, op) -- (0.1.1: again while the siege lasts, e.g. once its siege railway opens)
          local cap = op.target and op.target.city and storage.capture and storage.capture.cities
            and storage.capture.cities[op.target.city]
          local city = op.target and op.target.city and storage.cities and storage.cities[op.target.city]
          if city and city.force == C.force then
            set_phase(C, op, "consolidate", "the city is ours")
          elseif cap and (cap.capturing == C.force or (cap.subdued and (cap.attackers or 0) > 0)) then
            set_phase(C, op, "capture", cap.capturing == C.force and "taking the subdued centre" or "centre subdued")
          end
        elseif op.phase == "capture" then
          local city = op.target and op.target.city and storage.cities and storage.cities[op.target.city]
          if city and city.force == C.force then set_phase(C, op, "consolidate", "the city is ours") end
        end
      elseif op.kind == "relief" or op.kind == "defend" then
        local d = (c and tpos) and dist(c, tpos) or math.huge
        if op.phase == "move" and d <= 40 then set_phase(C, op, "engage", string.format("%.0f tiles", d)) end
      end
      -- timeouts: the group is recalled
      local limit = CB.timeouts[op.phase]
      if limit and tick - op.since > limit and op.phase ~= "return" then
        if op.phase == "consolidate" then
          end_op(C, K, op, "consolidated")
          if army.recall then army.recall(C, op.group, "operation consolidated") end
        else
          K.stats.aborted = K.stats.aborted + 1
          util.log("council: %s operation #%d %s: phase %s timed out after %.0f s, recalled", C.force, op.id,
            op.kind, op.phase, (tick - op.since) / 60)
          for _, g in ipairs(op.groups or {op.group}) do
            if a.groups[g] and army.recall then army.recall(C, g, "operation timeout") end
          end
          set_phase(C, op, "return", "timeout")
        end
      end
    else
      -- operations without an army group (bomb): their division
      local div = op.divisions[1]
      local D = div and divisions.get(div)
      if not D then
        end_op(C, K, op, "division gone")
      else
        local limit = CB.timeouts[op.phase]
        if op.kind == "bomb" then
          local n = divisions.strength(D)
          local c = D.pos
          if op.phase == "fly" and c and op.target and dist(c, op.target.position) <= 40 then
            set_phase(C, op, "strike", "over the target")
          elseif (op.phase == "strike" and tick - op.since > (CB.timeouts.strike or 3600)) or n == 0 then
            local air = mod("air")
            if air and air.order_return then air.order_return(div) end
            set_phase(C, op, "return", "strike over")
          elseif op.phase == "return" and tick - op.since > (CB.timeouts["return"] or 3600) then
            end_op(C, K, op, "back at the airfield")
          end
        elseif limit and tick - op.since > limit then
          end_op(C, K, op, "timeout")
        end
      end
    end
  end
end

--- Offensive operations under way (capture, siege, raid, bomb) and the difficulty's limit.
-- True when the nation holds a city captured from the city-states
local function holds_city_state(force_name)
  for _, id in ipairs(sorted_keys(storage.cities or {})) do
    local c = storage.cities[id]
    if c.force == force_name and c.archetype == "city_state" then return true end
  end
  return false
end

-- (0.1.1, issue #3) How many former city-states the nation holds.
local function city_states_held(force_name)
  local n = 0
  for _, id in ipairs(sorted_keys(storage.cities or {})) do
    local c = storage.cities[id]
    if c.force == force_name and c.archetype == "city_state" then n = n + 1 end
  end
  return n
end

local function offensive_count(K)
  local n = 0
  for _, op in pairs(K.ops) do
    if OFFENSIVE[op.kind] and not op.harass and op.phase ~= "return" and op.phase ~= "done" then n = n + 1 end
  end
  return n
end

--- army.lua: may commander C launch a new offensive now?
function council.may_launch(C, target)
  if not nation_mode() then return true end
  local K = K_of(C.force, false)
  if not K then return true end
  local k = difficulty.knobs(C.force)
  if offensive_count(K) >= k.ops then
    if not K.capped_logged or game.tick - K.capped_logged > 5 * 3600 then
      K.capped_logged = game.tick
      util.log("council: %s holds a new offensive: %d operations under way (limit %d)", C.force, offensive_count(K),
        k.ops)
    end
    return false
  end
  return true
end

--- army.lua (Nation): the nearest known hostile division in the field within field_reach of `from`, seen within two
--- intelligence scans, as an attack target; nil when none.
function council.field_target(C, from)
  if not (nation_mode() and from) then return nil end
  local known = intel.known(C.force)
  local best, bd
  for _, id in ipairs(sorted_keys(known.divisions)) do
    local r = known.divisions[id]
    if r.position and diplomacy.hostile(C.force, r.force) and intel.fresh(C.force, r) then
      local d = dist(from, r.position)
      if d <= CB.field_reach and (not bd or d < bd) then best, bd = r, d end
    end
  end
  if not best then return nil end
  return {position = {x = best.position.x, y = best.position.y}, kind = "division", force = best.force,
          division = best.id}
end

army.launch_ok = function(C, target) return council.may_launch(C, target) end
army.field_target = function(C, from) return council.field_target(C, from) end

function council.operations(force_name)
  local K = K_of(force_name, false)
  local out = {}
  if not K then return out end
  for _, id in ipairs(sorted_keys(K.ops)) do
    local op = K.ops[id]
    out[#out + 1] = {id = op.id, kind = op.kind, target = op.target, phase = op.phase, since = op.since,
                     divisions = op.divisions, group = op.group}
  end
  return out
end

---------------------------------------------------------------------------
-- Fronts: holding divisions, fort belts
---------------------------------------------------------------------------
local AIR_KIND = {["scout-plane"] = true, bomber = true, interceptor = true}

-- Idle own units outside every army group and division (the pool the council may draw from), nearest to `pos` first.
local function free_units(C, pos)
  local a = C.army
  local held = a.held or {}
  local list = {}
  for un, rec in units.for_force(C.force) do
    if not a.member[un] and not held[un] and not army.POOL_SKIP[rec.kind] and not AIR_KIND[rec.kind]
       and rec.issuer ~= "market" and rec.order == units.IDLE and not divisions.of_unit(un) and rec.entity.valid then
      local p = rec.entity.position
      local dx, dy = p.x - pos.x, p.y - pos.y
      list[#list + 1] = {e = rec.entity, d = dx * dx + dy * dy, un = un}
    end
  end
  table.sort(list, function(x, y)
    if x.d ~= y.d then return x.d < y.d end
    return x.un < y.un
  end)
  return list
end

local function release_hold(C, K, seg_id, why)
  local H = K.holds[seg_id]
  if not H then return end
  K.holds[seg_id] = nil
  local held = C.army.held or {}
  for un, d in pairs(held) do
    if d == H.div then held[un] = nil end
  end
  if divisions.get(H.div) then divisions.disband(H.div, "AI hold released: " .. why) end
  util.log("council: %s releases the hold on front segment %d (division #%d): %s", C.force, seg_id, H.div, why)
end

local function holds_step(C, K)
  local fronts = mod("fronts")
  local a = C.army
  if not (fronts and fronts.segments and a) then return end
  a.held = a.held or {}
  local segs = fronts.segments(C.force)
  local by_id = {}
  for _, s in ipairs(segs) do by_id[s.id] = s end
  -- releases: segment gone, division gone, or quiet for hold_quiet
  for _, id in ipairs(sorted_keys(K.holds)) do
    local H = K.holds[id]
    local seg = by_id[id]
    if not seg then
      release_hold(C, K, id, "the segment is gone")
    elseif not divisions.get(H.div) then
      K.holds[id] = nil
      for un, d in pairs(a.held) do if d == H.div then a.held[un] = nil end end
    elseif (seg.strength or 0) < (CB.hold_strength or 4) * 0.5 then
      H.quiet = H.quiet or game.tick
      if game.tick - H.quiet >= (CB.hold_quiet or 5 * 3600) then release_hold(C, K, id, "quiet") end
    else
      H.quiet = nil
    end
  end
  -- held units that died or left their division
  for _, un in ipairs(sorted_keys(a.held)) do
    local d = a.held[un]
    if not units.get(un) or divisions.of_unit(un) ~= d then a.held[un] = nil end
  end
  -- new holds: the threatened segments, strongest enemy first
  local want = {}
  for _, s in ipairs(segs) do
    if (s.strength or 0) >= (CB.hold_strength or 4) and not K.holds[s.id] then want[#want + 1] = s end
  end
  if #want == 0 then return end
  table.sort(want, function(x, y)
    if (x.strength or 0) ~= (y.strength or 0) then return (x.strength or 0) > (y.strength or 0) end
    return x.id < y.id
  end)
  local held_n = table_size(a.held)
  local capital = capital_of(C.force)
  local pool = free_units(C, capital and capital.position or a.rally)
  local budget = math.floor((#pool + held_n) * CB.hold_units) - held_n
  for _, s in ipairs(want) do
    local n = math.min(CB.hold_max, math.max(CB.hold_min, math.ceil((s.strength or 0) * 1.5)))
    if budget < CB.hold_min then break end
    n = math.min(n, budget)
    local near = free_units(C, s.mid or s.a)
    if #near < n then n = #near end
    if n < CB.hold_min then break end
    local pick = {}
    for i = 1, n do pick[i] = near[i].e end
    local id = divisions.create(C.force, pick, {name = "Front " .. s.id, stance = "hold"}, {owner = "ai"})
    if id then
      local ok, why = divisions.order(id, "hold_line", s.id)
      if ok then
        K.holds[s.id] = {div = id, since = game.tick}
        for _, un in ipairs(divisions.members(id)) do a.held[un] = id end
        K.stats.holds = K.stats.holds + 1
        budget = budget - n
        util.log("council: %s division #%d (%d units) holds front segment %d (%s, threat %.0f, enemy strength %.0f)",
          C.force, id, n, s.id, seg_name(s), fronts.threat(s), s.strength or 0)
      else
        divisions.disband(id, "hold_line refused: " .. tostring(why))
      end
    end
  end
end

local function belts_step(C, K)
  local fronts, belts = mod("fronts"), mod("belts")
  if not (fronts and fronts.segments and belts and belts.plan_front) then return end
  local tick = game.tick
  local segs = fronts.segments(C.force)
  local live = {}
  for _, s in ipairs(segs) do
    live[s.id] = true
    if fronts.threat(s) >= CB.belt_threat then
      K.threat_since[s.id] = K.threat_since[s.id] or tick
    else
      K.threat_since[s.id] = nil
    end
  end
  for _, id in ipairs(sorted_keys(K.threat_since)) do
    if not live[id] then K.threat_since[id] = nil end
  end
  if not has_tech(C.force, FORTIFICATION) then return end
  local count = 0
  for _, id in pairs(K.belts) do if id then count = count + 1 end end
  if count >= CB.belts then return end
  local best, bt
  for _, s in ipairs(segs) do
    local since = K.threat_since[s.id]
    if since and tick - since >= CB.belt_after and not K.belts[s.id] then
      local t = fronts.threat(s)
      if not bt or t > bt then best, bt = s, t end
    end
  end
  if not best then return council.sector_belt(C, K, belts) end
  local id, why = belts.plan_front(C.force, best.id, {aa = false, depot = true, why = "AI front"})
  if id then
    K.belts[best.id] = id
    K.stats.belts = K.stats.belts + 1
    util.log("council: %s plans fort belt #%d on front segment %d (%s, threat %.0f for %.0f s)", C.force, id, best.id,
      seg_name(best), bt, (tick - K.threat_since[best.id]) / 60)
  else
    K.belts[best.id] = false
    util.log("council: %s cannot plan a fort belt on segment %d: %s", C.force, best.id, tostring(why))
  end
end

-- A nation at war for sector_after with no strength seen near its cities: its own city nearest to what it knows of a
-- nation it is at war with (a city, else a unit cluster), and that point (raids of 2-4 units never made a sustained
-- sector_strength: 0-2 belts in five 4-nation seeds).
local function war_approach(C, K, I)
  local tick = game.tick
  K.war_since = K.war_since or tick
  if tick - K.war_since < CB.sector_after or not I then return nil end
  local points = {}
  for _, id in ipairs(sorted_keys(I.cities or {})) do
    local r = I.cities[id]
    if r.force ~= diplomacy.NEUTRAL and diplomacy.state(C.force, r.force) == "war" then
      points[#points + 1] = {x = r.position.x, y = r.position.y}
    end
  end
  if #points == 0 then
    for _, f in ipairs(sorted_keys(I.clusters or {})) do
      if f ~= diplomacy.NEUTRAL and diplomacy.state(C.force, f) == "war" then
        for _, k in ipairs(sorted_keys(I.clusters[f])) do
          local r = I.clusters[f][k]
          points[#points + 1] = {x = r.x, y = r.y}
        end
      end
    end
  end
  local best, tp, bd
  for _, c in ipairs(deps.cities.for_force(C.force)) do
    if not K.belts["c" .. c.id] then
      for _, p in ipairs(points) do
        local d = dist(c.position, p)
        if not bd or d < bd then best, tp, bd = c, p, d end
      end
    end
  end
  return best, tp, bd
end

-- Sectors (a nation at war whose land does not touch the enemy's has no front segment): an own city with hostile
-- strength of at least sector_strength known within sector_radius tiles for belt_after ticks gets a fort belt across
-- the approach: sector_length tiles long, perpendicular to the way from the city to that strength, inside its land.
-- Without such a city, the city nearest to the enemy (war_approach) gets it.
function council.sector_belt(C, K, belts)
  if not at_war(C.force) then
    K.sector_since, K.war_since = nil, nil
    return
  end
  K.sector_since = K.sector_since or {}
  K.sector_last = K.sector_last or {}
  local tick = game.tick
  local territory = deps.territory
  local best, bs
  for _, c in ipairs(deps.cities.for_force(C.force)) do
    local n = intel.strength_near(C.force, nil, c.position, CB.sector_radius, 2 * difficulty.knobs(C.force).intel_age)
    -- (sustained: the strength may drop out of sight for up to sector_grace ticks between two readings)
    if n >= CB.sector_strength then
      K.sector_since[c.id] = K.sector_since[c.id] or tick
      K.sector_last[c.id] = tick
    elseif K.sector_last[c.id] and tick - K.sector_last[c.id] > CB.sector_grace then
      K.sector_since[c.id], K.sector_last[c.id] = nil, nil
    end
    local since = K.sector_since[c.id]
    if since and tick - since >= CB.sector_after and not K.belts["c" .. c.id] and (not bs or n > bs) then
      best, bs = c, n
    end
  end
  local planned = 0
  for _, id in pairs(K.belts) do if id then planned = planned + 1 end end
  if planned >= CB.belts then return end
  local I = intel.state(C.force)
  local tp, tn, why_here
  if best then
    -- the direction of the threat: the strongest known hostile cluster near the city
    for _, f in ipairs(sorted_keys(I and I.clusters or {})) do
      if diplomacy.hostile(C.force, f) then
        for _, k in ipairs(sorted_keys(I.clusters[f])) do
          local r = I.clusters[f][k]
          if dist(r, best.position) <= CB.sector_radius and (not tn or r.supply > tn) then tp, tn = r, r.supply end
        end
      end
    end
    if not tp then return end
    why_here = string.format("hostile strength %.0f near it for %.0f s", bs, (tick - K.sector_since[best.id]) / 60)
  else
    local d
    best, tp, d = war_approach(C, K, I)
    if not best then return end
    why_here = string.format("nearest to the enemy, %.0f tiles, at war for %.0f s", d, (tick - K.war_since) / 60)
  end
  local dx, dy = tp.x - best.position.x, tp.y - best.position.y
  local len = math.max(1, math.sqrt(dx * dx + dy * dy))
  dx, dy = dx / len, dy / len
  local nx, ny = -dy, dx
  local half = CB.sector_length / 2
  local radius = best.radius or 48
  local id, why
  for back = 16, radius - 8, 8 do
    local r = radius - back
    local cx, cy = best.position.x + dx * r, best.position.y + dy * r
    local p1, p2 = {x = cx + nx * half, y = cy + ny * half}, {x = cx - nx * half, y = cy - ny * half}
    if territory and territory.owner_at(p1) == C.force and territory.owner_at(p2) == C.force
       and territory.owner_at({x = cx, y = cy}) == C.force then
      -- (no AA turrets, no field depot: every entry must be paid from the city's network, and the AI makes walls and
      -- turrets only as make targets; a plan with AA turrets waited for ever)
      id, why = belts.plan(C.force, {p1, p2}, {aa = false, depot = false, why = "AI sector of city " .. best.id})
      if id then break end
    end
  end
  K.belts["c" .. best.id] = id or false
  if id then
    K.stats.belts = K.stats.belts + 1
    util.log("council: %s plans fort belt #%d across the approach to city %d (%s)", C.force, id, best.id, why_here)
  else
    util.log("council: %s cannot plan a fort belt at city %d: %s", C.force, best.id, tostring(why or "no own line"))
  end
end

---------------------------------------------------------------------------
-- Siege railways (0.1.1, issue #4): an artillery train bombards from a depot within artillery_range of its target,
-- but the 2.1 acceptance's sieges lay 170-850 tiles from the besieger's nearest depot and 170-800 from its nearest
-- line, so no train ever fired. With Military railways, a capture operation whose target has no own depot in reach
-- gets a siege railway: a depot of its own (the builder factory makes it) at the first spot outside every other
-- force's land on the way from the nearest own city (the capital when it is within siege_rail.reach), siege_rail.near..
-- far tiles from the target, then a rail program from that city to it (rails.ai_program, paid by the capital; its
-- crew and rails as for a trunk edge). Once the line is open, siege_artillery deploys the train at the line's capital
-- end and sends it to the forward depot. At most siege_rail.max at a time; one that stops mattering (operation over,
-- city taken) is dropped after siege_rail.keep.
---------------------------------------------------------------------------
data.FACTORY_RECIPE["rts-depot"] = data.FACTORY_RECIPE["rts-depot"] or "rts-depot"
data.FACTORY_RECIPE["rts-radar"] = data.FACTORY_RECIPE["rts-radar"] or "rts-radar"
local SIEGE_DEPOT, SIEGE_RADAR = "rts-depot", "rts-radar"

-- Put a plan entry at the front of the construction queue (the forward depot is the siege's first job).
local function queue_front(C, key)
  if not construction.queue(C, key) then return end
  local q = C.queue
  if q[#q] == key then
    table.remove(q)
    table.insert(q, 1, key)
  end
end

local function own_depot_near(C, pos, range)
  local R = storage.rails
  for _, un in ipairs(sorted_keys(R and R.depots or {})) do
    local d = R.depots[un]
    if d.force == C.force and d.entity and d.entity.valid and dist(d.entity.position, pos) <= range then return un end
  end
  return nil
end

-- The forward depot's spot: on the way from `from` to the target, outside every other force's land, a depot and its
-- platform fit (rails.platform_fits), as near the target as the land allows.
local function siege_site(C, surface, target, from)
  local rails, territory = deps.rails, deps.territory
  if not (rails and rails.platform_fits) then return nil end
  local SR = CB.siege_rail
  local dx, dy = from.x - target.x, from.y - target.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < SR.near then return nil end
  dx, dy = dx / len, dy / len
  local nx, ny = -dy, dx
  for d = SR.near, math.min(SR.far, len - 20), 6 do
    for _, off in ipairs({0, 8, -8, 16, -16, 24, -24}) do
      local p = {x = math.floor(target.x + dx * d + nx * off + 0.5), y = math.floor(target.y + dy * d + ny * off + 0.5)}
      if dist(p, target) <= CB.artillery_range - 4
         and (not territory or territory.can_build(C.force, SIEGE_DEPOT, p))
         and surface.can_place_entity({name = SIEGE_DEPOT, position = p, force = C.force,
                                       build_check_type = defines.build_check_type.manual})
         and rails.platform_fits(surface, C.force, p) ~= nil then
        return p
      end
    end
  end
  return nil
end

-- Deploy the artillery train of an open siege railway: at its capital end (the forward depot's own network holds no
-- kits), stance bombard, sent along the line to the forward depot; it fires at the hostile buildings it sees within
-- range from there, whatever operation comes. Returns the train id or nil.
local function siege_deploy(C, K, S)
  local tw = mod("trainswar")
  if not (tw and tw.deploy and S.A and S.A.depot_a and S.A.depot_b) then return nil end
  local train, why = tw.deploy(S.A.depot_a, tw.KIND or "artillery", false)
  if not train then
    if S.deploy_why ~= why then
      S.deploy_why = why
      util.log("council: %s siege railway to city %d: no artillery train at depot #%d yet (%s)", C.force, S.city,
        S.A.depot_a, tostring(why))
    end
    return nil
  end
  tw.set_stance(train.id, "bombard")
  if tw.send_to_depot then tw.send_to_depot(train.id, S.A.depot_b) end
  K.stats.artillery = K.stats.artillery + 1
  local d = rails_depot(S.A.depot_b)
  util.log("council: %s artillery train %d at depot #%d, sent along the siege railway to depot #%d (%.0f tiles from "
    .. "city %d) in bombard stance", C.force, train.id, S.A.depot_a, S.A.depot_b,
    d and dist(d.entity.position, S.target) or -1, S.city)
  return train.id
end

-- The targets of siege railways, first first: the cities of live capture operations, the goal cities of the wars the
-- nation declared, and at war the known enemy city nearest an own city.
local function siege_targets(C, K)
  local out, seen = {}, {}
  local function add(cid, pos, why)
    local city = cid and deps.cities.get(cid)
    if city and city.force == C.force then return end -- ours already (a war goal taken: "0 tiles from city 6")
    if cid and pos and not seen[cid] then
      seen[cid] = true
      out[#out + 1] = {city = cid, position = {x = pos.x, y = pos.y}, why = why}
    end
  end
  for _, id in ipairs(sorted_keys(K.ops)) do
    local op = K.ops[id]
    if (op.kind == "capture" or op.kind == "siege") and op.phase ~= "return" and op.phase ~= "done" and op.target then
      add(op.target.city, op.target.position, "operation")
    end
  end
  if not at_war(C.force) then return out end
  local wars = mod("wars")
  for _, t in ipairs(wars and wars.targets and wars.targets(C.force) or {}) do
    add(t.city_id, t.position, "war goal")
  end
  local I = intel.state(C.force)
  local best, bd
  for _, id in ipairs(sorted_keys(I and I.cities or {})) do
    local r = I.cities[id]
    if r.position and r.force ~= diplomacy.NEUTRAL and diplomacy.state(C.force, r.force) == "war" then
      for _, c in ipairs(deps.cities.for_force(C.force)) do
        local d = c.position and dist(c.position, r.position)
        if d and (not bd or d < bd) then best, bd = r, d end
      end
    end
  end
  if best then add(best.id, best.position, "at war") end
  return out
end

function council.siege_step(C, K, surface)
  local SR = CB.siege_rail
  local rails = deps.rails
  if not (SR and rails and rails.ai_program and rails.depot) or not has_tech(C.force, MILITARY_RAILWAYS) then return end
  local tick = game.tick
  if tick < (K.siege_next or 0) then return end
  K.siege_next = tick + SR.period
  K.siege = K.siege or {}
  local capital = capital_of(C.force)
  if not (capital and capital.center) then return end
  local targets = siege_targets(C, K)
  local wanted = {}
  for _, t in ipairs(targets) do wanted[t.city] = t end
  local active = 0
  for _, cid in ipairs(sorted_keys(K.siege)) do
    local S = K.siege[cid]
    if not S.failed and not S.over then active = active + 1 end
  end
  for _, t in ipairs(targets) do
    local cid, T = t.city, t.position
    if not K.siege[cid] and active < SR.max and not own_depot_near(C, T, CB.artillery_range) then
      -- the origin: the capital when within reach (its depot shares the capital's network: crew kits and the
      -- artillery train come from there), else the own city nearest the target
      local O = capital
      if dist(capital.position, T) > SR.reach then
        local bd
        for _, c in ipairs(deps.cities.for_force(C.force)) do
          if c.center and c.position and buildings.get(c.center) then
            local d = dist(c.position, T)
            if not bd or d < bd then O, bd = c, d end
          end
        end
      end
      local p = dist(O.position, T) <= SR.reach and siege_site(C, surface, T, O.position) or nil
      if p then
        local key = construction.add(C, {name = SIEGE_DEPOT, x = p.x, y = p.y, line = "siege"})
        queue_front(C, key)
        K.siege[cid] = {city = cid, target = {x = T.x, y = T.y}, key = key, origin = O.id, origin_center = O.center,
                        site = p, since = tick, state = "depot", why = t.why}
        active = active + 1
        K.stats.siege_rails = (K.stats.siege_rails or 0) + 1
        util.log("council: %s plans a siege railway to city %d (%s): forward depot at %s (%.0f tiles from it), line "
          .. "from city %d (%.0f tiles)", C.force, cid, t.why, util.pos_str(p), dist(p, T), O.id, dist(O.position, p))
      elseif dist(O.position, T) <= SR.reach then
        K.siege[cid] = {city = cid, failed = true, since = tick, target = {x = T.x, y = T.y}}
        util.log("council: %s finds no siege railway spot towards city %d (%.0f tiles from city %d)", C.force, cid,
          dist(O.position, T), O.id)
      end
    end
  end
  for _, cid in ipairs(sorted_keys(K.siege)) do
    local S = K.siege[cid]
    local city = storage.cities and storage.cities[cid]
    if not wanted[cid] or (city and city.force == C.force) then
      S.over = S.over or tick
      if tick - S.over >= SR.keep then
        K.siege[cid] = nil
        if not S.failed then util.log("council: %s drops its siege railway to city %d", C.force, cid) end
      end
    else
      S.over = nil
    end
    if not S.failed and not S.over then
      if S.state == "depot" then
        local st = construction.status(C, S.key)
        if st == "built" then
          local e = C.plan[S.key].entity
          if e and e.valid and rails.depot(e.unit_number) and buildings.get(S.origin_center) then
            S.depot = e.unit_number
            S.A = {anchor = S.origin_center, far = S.depot, depot_b = S.depot, pay = capital.center, policies = true,
                   siege = true}
            S.state = "line"
            -- a radar beside it (powered by the depot's hub core): the train only fires at what the nation sees, and
            -- a radar sees 96 tiles where the depot itself sees 48 (trainswar.KNOWN)
            local rp = surface.find_non_colliding_position(SIEGE_RADAR, {x = e.position.x + 6, y = e.position.y + 6}, 8,
              1, true)
            if rp and (not deps.territory or deps.territory.can_build(C.force, SIEGE_RADAR, rp)) then
              S.radar = construction.add(C, {name = SIEGE_RADAR, x = math.floor(rp.x) + 0.5, y = math.floor(rp.y) + 0.5,
                                             line = "siege"})
              queue_front(C, S.radar)
            end
            util.log("council: %s siege railway to city %d: forward depot #%d built%s", C.force, cid, S.depot,
              S.radar and ", a radar beside it" or "")
          end
        elseif st == "bad" or st == nil then
          S.failed, S.state = true, "failed"
          util.log("council: %s siege railway to city %d: the forward depot could not be built", C.force, cid)
        elseif st == "planned" then
          queue_front(C, S.key)
        end
      end
      if S.state == "line" then
        local R = storage.rails
        local line = S.A.line and R and R.lines[S.A.line]
        if not rails.depot(S.depot) then
          S.failed, S.state = true, "failed"
          util.log("council: %s siege railway to city %d: its forward depot is gone", C.force, cid)
        elseif line and line.state == "open" then
          S.state, S.opened = "open", tick
          util.log("council: %s siege railway to city %d open after %.0f s", C.force, cid, (tick - S.since) / 60)
        else
          rails.ai_program(C.force, S.A) -- (never once open: its freight train would take kits for nothing)
        end
      end
      if S.state == "open" then
        local tr = S.train and game.train_manager.get_train_by_id(S.train)
        if S.train and not (tr and tr.valid) then S.train = nil end
        if not S.train and rails.depot(S.depot) and tick >= (S.deploy_next or 0) then
          S.deploy_next = tick + 30 * 60
          S.train = siege_deploy(C, K, S)
        end
      end
    end
  end
end

--- The council's rail programs (ai/planner.lua: the works factory makes their depots and crew kits).
function council.rail_programs(C)
  local K = K_of(C.force, false)
  local out = {}
  for _, cid in ipairs(sorted_keys(K and K.siege or {})) do
    local S = K.siege[cid]
    if S.A and S.state == "line" then out[#out + 1] = S.A end
  end
  return out
end

--- True while a siege railway is under way or open for an operation without its artillery train (ai/planner.lua: the
--- works factory makes the train's kits and shells at the capital).
function council.artillery_want(C)
  local K = K_of(C.force, false)
  if not (K and K.siege) then return false end
  for _, cid in ipairs(sorted_keys(K.siege)) do
    local S = K.siege[cid]
    if (S.state == "line" or S.state == "open") and not S.train and not S.over and not S.failed and S.origin_center then
      local cap = capital_of(C.force)
      if cap and S.origin_center == cap.center then return true end
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Air
---------------------------------------------------------------------------
--- Retire up to n idle walkers of commander C that are in no group, hold and division (lowest unit numbers first): room
--- under the supply cap. Returns how many went.
function council.retire_walkers(C, n)
  local a = C.army or {member = {}}
  local list = {}
  for un, rec in units.for_force(C.force) do
    if rec.kind == "walker" and rec.order == units.IDLE and not a.member[un] and not (a.held and a.held[un])
       and not divisions.of_unit(un) and rec.entity.valid then
      list[#list + 1] = un
    end
  end
  table.sort(list)
  local done = 0
  for i = 1, math.min(n, #list) do
    local rec = units.get(list[i])
    if rec and rec.entity.valid then
      rec.entity.die()
      done = done + 1
    end
  end
  return done
end

local function plane_list(C, kind)
  local out = {}
  for un, rec in units.for_force(C.force) do
    if rec.kind == kind and rec.entity.valid then out[#out + 1] = {un = un, e = rec.entity} end
  end
  table.sort(out, function(x, y) return x.un < y.un end)
  return out
end

local function air_wanted(C)
  if age_of(C.force) < 2 then return false end
  local m = storage.match
  return at_war(C.force) or (m and m.tick_started and game.tick - m.tick_started >= CB.air_from)
end

-- Where the scouts patrol: the most threatened own front segment, else 40 % of the way to the nearest rival capital.
local function patrol_point(C)
  local fronts = mod("fronts")
  local best, bt
  for _, s in ipairs(fronts and fronts.segments and fronts.segments(C.force) or {}) do
    local t = fronts.threat(s)
    if not bt or t > bt then best, bt = s, t end
  end
  if best and best.mid then return {x = best.mid.x, y = best.mid.y}, "front segment " .. best.id end
  local cap = capital_of(C.force)
  if not cap then return nil end
  local near, nd
  for _, f in ipairs(storage.match and storage.match.forces or {}) do
    if f ~= C.force then
      local p = diplomacy.capital_position(f)
      if p then
        local d = dist(p, cap.position)
        if not nd or d < nd then near, nd = p, d end
      end
    end
  end
  if not near then return {x = cap.position.x, y = cap.position.y}, "the capital" end
  return {x = cap.position.x + (near.x - cap.position.x) * 0.4, y = cap.position.y + (near.y - cap.position.y) * 0.4},
    "the way to the nearest rival"
end

local function air_step(C, K, surface)
  local air = mod("air")
  if not (air and air.airfields) then return end
  local Kair = K.air
  if not has_tech(C.force, AVIATION) then return end
  local capital = capital_of(C.force)
  if not capital then return end
  -- the airfield at the capital
  local field = air.airfield_of_city and air.airfield_of_city(C.force, capital.id)
  if not field then
    local st = Kair.key and construction.status(C, Kair.key)
    if st == "bad" or (Kair.key and st == nil) then Kair.key, Kair.retry = nil, game.tick + 2 * 3600 end
    if not Kair.key and game.tick >= (Kair.retry or 0) then
      local pos, _, wait = layout.find_spot(C, surface, AIRFIELD, "cc")
      local ok, why = false, "no spot"
      if pos then ok, why = air.can_build_airfield(C.force, pos) end
      -- a full Command Center area: anywhere on the capital's land (an airfield needs no power), behind the capital
      if not ok and not wait and layout.find_spot_in then
        local cx, cy = math.floor(capital.position.x), math.floor(capital.position.y)
        local fx = (C.frame and C.frame.fx) or 1
        local pref = {x = cx - fx * 30, y = cy - 20}
        for _, r in ipairs({40, 64}) do
          local p2, _, w2 = layout.find_spot_in(C, surface, AIRFIELD, cx - r, cy - r, cx + r, cy + r, pref)
          if w2 then
            wait = true
            break
          end
          if p2 then
            local ok2, why2 = air.can_build_airfield(C.force, p2)
            if ok2 then
              pos, ok, why = p2, true, nil
              break
            end
            why = why2
          end
        end
      end
      if wait then
        -- a planning job looks for the spot (ai/planjob.lua): ask again on a later pass
      elseif ok then
        Kair.key = construction.add(C, {name = AIRFIELD, x = pos.x, y = pos.y})
        construction.queue(C, Kair.key)
        util.log("council: %s airfield queued at %s", C.force, util.pos_str(pos))
      else
        Kair.retry = game.tick + 2 * 3600
        util.log("council: %s finds no airfield spot at the capital (%s)", C.force, tostring(why))
      end
    elseif Kair.key and st == "planned" then
      construction.queue(C, Kair.key)
    end
    return
  end
  Kair.ready = Kair.ready or game.tick
  -- the scout patrol division
  local scouts = plane_list(C, "scout-plane")
  -- a nation at its supply cap retires idle walkers to make room for its scouts (a capped barracks makes nothing)
  local supply = deps.supply
  if #scouts < CB.scouts and C.capped and supply and game.tick >= (Kair.retire_at or 0) then
    Kair.retire_at = game.tick + 60 * 60
    local n = council.retire_walkers(C, CB.scouts - #scouts)
    if n > 0 then
      util.log("council: %s retires %d idle walker(s) to make room for its scout planes (supply capped)", C.force, n)
    end
  end
  local div = Kair.patrol and divisions.get(Kair.patrol) and Kair.patrol or nil
  if not div then Kair.patrol = nil end
  local loose = {}
  for _, s in ipairs(scouts) do
    if not divisions.of_unit(s.un) then loose[#loose + 1] = s.e end
  end
  if #loose > 0 then
    if div then
      divisions.add_units(div, loose, "AI air patrol")
    else
      div = divisions.create(C.force, loose, {name = "Air patrol", stance = "hold"}, {owner = "ai"})
      Kair.patrol = div
    end
  end
  if div then
    local D = divisions.get(div)
    if D and D.state ~= "patrolling" and game.tick - (Kair.patrol_tick or 0) >= 60 * 60 then
      local pos, why = patrol_point(C)
      if pos then
        local n = air.order_patrol(div, pos, CB.patrol_radius)
        Kair.patrol_tick = game.tick
        if n > 0 then
          K.stats.patrols = K.stats.patrols + 1
          util.log("council: %s air patrol division #%d (%d planes) over %s (%s)", C.force, div, n, util.pos_str(pos),
            why)
        end
      end
    end
  end
  -- interceptors over the capital when enemy planes were seen (0.1.1, issue #4: or while at war: a standing air
  -- defence; they flew in no nation of the 2.1 acceptance)
  local seen = intel.enemy_planes_seen(C.force)
  if ((seen and game.tick - seen <= 5 * 3600) or at_war(C.force)) and has_tech(C.force, AIR_FORCE) then
    local list = plane_list(C, "interceptor")
    local idiv = Kair.interceptors and divisions.get(Kair.interceptors) and Kair.interceptors or nil
    local free = {}
    for _, s in ipairs(list) do
      if not divisions.of_unit(s.un) then free[#free + 1] = s.e end
    end
    if #free > 0 then
      if idiv then divisions.add_units(idiv, free, "AI interceptors") else
        idiv = divisions.create(C.force, free, {name = "Interceptors", stance = "hold"}, {owner = "ai"})
        Kair.interceptors = idiv
      end
    end
    local D = idiv and divisions.get(idiv)
    if D and D.state ~= "patrolling" then
      local n = air.order_patrol(idiv, capital.position, CB.patrol_radius)
      if n > 0 then
        K.stats.interceptors = K.stats.interceptors + 1
        util.log("council: %s interceptors (division #%d, %d planes) patrol the capital: %s", C.force, idiv, n,
          seen and string.format("enemy planes seen %.0f s ago", (game.tick - seen) / 60) or "at war")
      end
    end
  end
  -- bombers: a bomb run at the target of a capture in its advance or siege phase
  if has_tech(C.force, AIR_FORCE) then
    local list = plane_list(C, "bomber")
    local bombing = false
    for _, op in pairs(K.ops) do if op.kind == "bomb" then bombing = true end end
    if #list > 0 and not bombing then
      local target
      for _, id in ipairs(sorted_keys(K.ops)) do
        local op = K.ops[id]
        if (op.kind == "capture" or op.kind == "siege") and (op.phase == "advance" or op.phase == "siege")
           and op.target and op.target.position then
          target = op.target
          break
        end
      end
      -- (0.1.1, issue #4) at war without such an operation: the nearest known city of a nation at war with us within
      -- bomb_reach of the capital (bombers only waited for a capture's advance; none flew in the 2.1 acceptance)
      if not target and at_war(C.force) and game.tick >= (Kair.bomb_next or 0) then
        Kair.bomb_next = game.tick + (CB.bomb_gap or 3 * 3600)
        local I = intel.known(C.force)
        local bd
        for _, id in ipairs(sorted_keys(I.cities or {})) do
          local r = I.cities[id]
          if r.position and r.force ~= diplomacy.NEUTRAL and diplomacy.state(C.force, r.force) == "war" then
            local d = dist(r.position, capital.position)
            if d <= (CB.bomb_reach or 600) and (not bd or d < bd) then
              target, bd = {kind = "city", position = {x = r.position.x, y = r.position.y}, city = id}, d
            end
          end
        end
      end
      if target then
        local free = {}
        for _, s in ipairs(list) do
          if not divisions.of_unit(s.un) then free[#free + 1] = s.e end
        end
        local bdiv = Kair.bombers and divisions.get(Kair.bombers) and Kair.bombers or nil
        if #free > 0 then
          if bdiv then divisions.add_units(bdiv, free, "AI bombers") else
            bdiv = divisions.create(C.force, free, {name = "Bombers", stance = "advance"}, {owner = "ai"})
            Kair.bombers = bdiv
          end
        end
        if bdiv and divisions.order(bdiv, "attack_move", target.position) then
          K.stats.bombs = K.stats.bombs + 1
          new_op(C, K, "bomb", {kind = target.kind, position = target.position, city = target.city}, nil, bdiv)
        end
      end
    end
  end
end

--- True while the capital's airfield is queued and not built yet (ai/planner.lua holds the later Space Program stages).
function council.air_pending(C)
  if air_wanted(C) and not has_tech(C.force, AVIATION) then return true end -- (and while Aviation waits for kits)
  local K = K_of(C.force, false)
  local key = K and K.air and K.air.key
  if not key then return false end
  local st = construction.status(C, key)
  return st == "queued" or st == "ghost" or st == "planned"
end

--- Capital make targets the council wants (ai/age_up.lua merges them): the airfield's concrete while it is queued, and
--- the items a fort belt under way still waits for (walls, turrets, its field depot: its crew pays them from a city
--- network, so they must be made).
council.BELT_CAP = {["rts-wall"] = 100, ["rts-turret"] = 8, ["rts-aa-turret"] = 4, ["rts-field-depot"] = 1,
                    ["rts-gate"] = 6, ["firearm-magazine"] = 40}
function council.targets(C)
  local K = K_of(C.force, false)
  if not K then return nil end
  local out = {}
  if K.air and K.air.key then
    local st = construction.status(C, K.air.key)
    if st == "queued" or st == "ghost" or st == "planned" then out.concrete, out["steel-plate"] = 40, 20 end
  end
  local belts = mod("belts")
  for _, key in ipairs(sorted_keys(K.belts)) do
    local id = K.belts[key]
    local plan = id and belts and belts.get and belts.get(id)
    if plan and (plan.state == "laying" or plan.state == "building") then
      for item, n in pairs(plan.need or {}) do
        local left = n - ((plan.debited or {})[item] or 0)
        local cap = council.BELT_CAP[item] or 20
        if left > 0 then out[item] = math.max(out[item] or 0, math.min(left, cap)) end
      end
    end
  end
  return next(out) and out or nil
end

--- Plane kits the barracks should make now (ai/mix.lua): scouts once an airfield stands, interceptors when enemy
--- planes were seen, bombers in Age III at war.
function council.air_want(C)
  local K = K_of(C.force, false)
  if not (K and K.air and K.air.ready) then return nil end
  local out = {}
  local function short(kind, kit, n)
    local have = #plane_list(C, kind)
    if have < n then out[kit] = n - have end
  end
  short("scout-plane", SCOUT_KIT, CB.scouts)
  if has_tech(C.force, AIR_FORCE) then
    local seen = intel.enemy_planes_seen(C.force)
    if (seen and game.tick - seen <= 10 * 3600) or at_war(C.force) then
      short("interceptor", INTERCEPTOR_KIT, CB.interceptors)
    end
    if at_war(C.force) then short("bomber", BOMBER_KIT, CB.bombers) end
  end
  return next(out) and out or nil
end

---------------------------------------------------------------------------
-- Money: hire garrison points at attacked cities, mercenaries for the capital
---------------------------------------------------------------------------
local function money_step(C, K)
  local sinks = deps.sinks or mod("sinks")
  if not sinks then return end
  local a = C.army
  local tick = game.tick
  local capital = capital_of(C.force)
  local attacked = {}
  if a and a.threat and tick - a.threat.tick <= 5 * 60 and capital
     and dist(a.threat.position, capital.position) <= 90 then
    attacked[#attacked + 1] = capital.id
  end
  for _, id in ipairs(sorted_keys(a and a.town_threat or {})) do
    if army.town_threat_fresh(C, id) then attacked[#attacked + 1] = id end
  end
  for _, id in ipairs(attacked) do
    if balance_of(C.force) >= CB.hire_at and tick - (K.hired[id] or -1e9) >= 2 * 3600 then
      local ok, why = sinks.hire_garrison(C.force, id, CB.hire_points)
      K.hired[id] = tick
      if ok then
        K.stats.hires = K.stats.hires + 1
        util.log("council: %s hires %d garrison points at attacked city %d", C.force, CB.hire_points, id)
      elseif why ~= "max" then
        util.log("council: %s cannot hire a garrison at city %d: %s", C.force, id, tostring(why))
      end
    end
  end
  if capital and attacked[1] == capital.id and (a.pool_size or 0) < CB.merc_army
     and balance_of(C.force) >= CB.merc_at and tick >= (K.merc_next or 0) then
    local market = deps.market
    -- (wave B.2 war probe: the nearest own port within the planner's port_reach of the capital: mercenaries hired at a
    -- port 790-1,160 tiles out walked into an attack group and held its centre out of siege range)
    local port, pd
    local reach = balance.nation.ai3.planner.port_reach or 450
    for _, un in ipairs(market and market.ports(C.force) or {}) do
      local p = market.port and market.port(un)
      local d = p and p.entity and p.entity.valid and dist(p.entity.position, capital.position) or math.huge
      if d <= reach and (not pd or d < pd) then port, pd = un, d end
    end
    K.merc_next = tick + 2 * 3600
    if port then
      local id, why = sinks.mercenaries(C.force, port)
      if id then
        K.stats.mercs = K.stats.mercs + 1
        util.log("council: %s hires mercenaries (division #%s) at port #%d: the capital is attacked, %d idle units",
          C.force, tostring(id), port, a.pool_size or 0)
      elseif why == "supply" then
        -- (at the supply cap the barracks keep it full: idle walkers make room and the hire comes again in 10 s)
        local n = council.retire_walkers(C, CB.merc_retire or 8)
        if n > 0 then K.merc_next = tick + 10 * 60 end
        util.log("council: %s cannot hire mercenaries: supply (%d idle walker(s) retired)", C.force, n)
      elseif why ~= "cooldown" then
        util.log("council: %s cannot hire mercenaries: %s", C.force, tostring(why))
      end
    end
  end
end

---------------------------------------------------------------------------
-- Debt (0.1.1, issue #5): a nation at the credit line kept 160-280 supply of army and its upkeep deepened the debt.
-- From debt stage `debt.stage` (2: unpaid wages, the barracks refuse kits already) the council retires idle units
-- (no army group, hold, division or plane; the largest supply first, at most per_pass a pass) until the army's supply
-- (as the treasury's upkeep counts it: every unit but haulers and the Commander) is down to keep_supply. Retiring is
-- labor.disband: the recruits go home to their city (they pay tax again). The barracks then make no unit beyond the
-- army left for `hold` ticks after the debt (ai/mix.lua C.debt_cap), so the upkeep does not come straight back.
---------------------------------------------------------------------------
function council.debt_step(C, K)
  local D = CB.debt
  local treasury, labor = mod("treasury"), mod("labor")
  local supply = deps.supply
  if not (D and treasury and treasury.stage and labor and labor.disband and supply) then return end
  local stage = treasury.stage(C.force)
  local Dk = K.debt
  if stage < D.stage then
    if Dk and Dk.active then
      util.log("council: %s out of debt stage %d (stage %d): %d unit(s) retired since %s", C.force, D.stage, stage,
        Dk.retired, Dk.since_clock or "-")
      Dk.active = nil
    end
    return
  end
  local a = C.army or {member = {}}
  local total, n_units = 0, 0
  local cand = {}
  for un, rec in units.for_force(C.force) do
    if rec.kind ~= "hauler" and rec.kind ~= "commander" and rec.entity.valid then
      local s = supply.cost(rec.entity.name)
      total = total + s
      n_units = n_units + 1
      if rec.order == units.IDLE and not a.member[un] and not (a.held and a.held[un]) and not army.POOL_SKIP[rec.kind]
         and not AIR_KIND[rec.kind] and rec.issuer ~= "market" and not divisions.of_unit(un) then
        cand[#cand + 1] = {un = un, s = s}
      end
    end
  end
  if not (Dk and Dk.active) then
    Dk = {active = game.tick, since_clock = clock(), from = total, retired = 0}
    K.debt = Dk
    util.log("council: %s in debt stage %d (balance %.0f): army supply %d (%d units, %d idle), retiring idle units "
      .. "down to %d supply", C.force, stage, balance_of(C.force), total, n_units, #cand, D.keep_supply)
  end
  table.sort(cand, function(x, y)
    if x.s ~= y.s then return x.s > y.s end
    return x.un < y.un
  end)
  local n, freed = 0, 0
  for _, c in ipairs(cand) do
    if total <= D.keep_supply or n >= D.per_pass then break end
    if labor.disband(c.un) then
      total, freed, n = total - c.s, freed + c.s, n + 1
    end
  end
  n_units = n_units - n
  -- the barracks make nothing beyond what is left (ai/mix.lua) until `hold` after the debt
  C.debt_cap = {units = n_units, until_tick = game.tick + D.hold}
  if n > 0 then
    Dk.retired = Dk.retired + n
    K.stats.retired = (K.stats.retired or 0) + n
    util.log("council: %s retires %d idle unit(s) in debt (%d supply): army supply %d (from %d at %s), %d units left",
      C.force, n, freed, total, Dk.from, Dk.since_clock, n_units)
  end
end

---------------------------------------------------------------------------
-- Research the council wants
---------------------------------------------------------------------------
--- The council's urgent research (ai/tech.lua tries it before the planner's): Fortification at war (cheap basic kits;
--- it waited behind Electrification's industrial kits for a whole war).
--- Aviation too for a military character (aggressive, turtle) once air is wanted: it goes for planes before the
--- Space Program (an economic nation the other way round), so the two compete for industrial kits in neither.
council.AIR_FIRST = {aggressive = true, turtle = true}
function council.research_urgent(C)
  if not nation_mode() then return nil end
  local out = {}
  if at_war(C.force) and not has_tech(C.force, FORTIFICATION) then out[#out + 1] = FORTIFICATION end
  -- (0.1.1, issue #4) Military railways at war once Electrification is done, before the air techs: an artillery train
  -- needs only it (25 industrial kits; Air Force alone takes 50), and Air Force put it back in every nation that
  -- wanted both
  if at_war(C.force) and has_tech(C.force, ELECTRIFICATION) and not has_tech(C.force, MILITARY_RAILWAYS) then
    out[#out + 1] = MILITARY_RAILWAYS
  end
  if council.AIR_FIRST[C.doctrine or ""] and air_wanted(C) and not has_tech(C.force, AVIATION) then
    out[#out + 1] = AVIATION
  elseif at_war(C.force) and has_tech(C.force, ELECTRIFICATION) and not has_tech(C.force, AVIATION) then
    -- (0.1.1, issue #4) every doctrine at war once Electrification is done (the Age III road first): an economic nation
    -- at war researched Geology and Nuclear power before Aviation, and Air Force never came
    out[#out + 1] = AVIATION
  end
  -- (0.1.1, issue #4) Air Force at war in Age III, before the planner's Geology and Nuclear power: behind them it came
  -- in 1 of 20 nations by 60:00 and no interceptor or bomber flew in the 2.1 acceptance
  if age_of(C.force) >= 3 and at_war(C.force) and has_tech(C.force, AVIATION) and not has_tech(C.force, AIR_FORCE) then
    out[#out + 1] = AIR_FORCE
  end
  return next(out) and out or nil
end

function council.research_want(C)
  if not nation_mode() then return nil end
  local out = {}
  if at_war(C.force) then out[#out + 1] = FORTIFICATION end
  -- (0.1.1, issue #4) Military railways at war in Age II: artillery trains for sieges (never researched in the 2.1
  -- acceptance)
  if at_war(C.force) and age_of(C.force) >= 2 then out[#out + 1] = MILITARY_RAILWAYS end
  if air_wanted(C) then out[#out + 1] = AVIATION end
  if age_of(C.force) >= 3 and at_war(C.force) then out[#out + 1] = AIR_FORCE end
  return out
end

---------------------------------------------------------------------------
-- The pass
---------------------------------------------------------------------------
function council.step(C, surface)
  if not nation_mode() then return end
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local K = K_of(C.force, true)
  if not K then return end
  local tick = game.tick
  if tick < K.next then return end
  local period = difficulty.knobs(C.force).council
  if K.next == 0 then
    local slot = 0
    for f in pairs(storage.ai or {}) do
      if f < C.force then slot = slot + 1 end
    end
    K.next = tick + (slot * 29) % period
    return
  end
  K.next = tick + period
  ops_step(C, K)
  council.cs_plan_step(C, K)
  -- a nation that holds no city-state and runs no offensive by push_after (at peace, Age II) goes for a city-state
  -- (army.lua relaxes its reach and margin while C.army.cs_push is fresh). (Phase 5 M3 ai, wave B.2: was "has run no
  -- operation yet": the loser of a city-state race never tried again and stayed at 4 cities, 1v1 seeds 902-910.)
  local m2 = storage.match
  -- (0.1.1, issue #3: up to the difficulty's cs_max city-states; hard goes on to a second one: land is the largest part
  -- of the score, and the side that took more city-states won 9 of 10 uneven matches)
  if city_states_held(C.force) < (difficulty.knobs(C.force).cs_max or 1) and offensive_count(K) == 0 and C.army
     and age_of(C.force) >= 2
     and not at_war(C.force)
     and tick - m2.tick_started >= CB.push_after * difficulty.knobs(C.force).cs_from
     and tick - (K.push_at or -1e9) >= 10 * 3600 then
    K.push_at = tick
    C.army.cs_push = tick
    -- every push reaches further (army.lua: the reach and the clear-of-rivals rule relax with cs_push_level; a
    -- 100-unit army pushed four times and found no city-state on its side of the map in seed 802)
    C.army.cs_push_level = (C.army.cs_push_level or 0) + 1
    util.log("council: %s holds %d city-state(s): pushes a city-state operation (idle army %d, push %d)", C.force,
      city_states_held(C.force), C.army.pool_size or 0, C.army.cs_push_level)
  end
  holds_step(C, K)
  belts_step(C, K)
  air_step(C, K, surface)
  council.siege_step(C, K, surface)
  money_step(C, K)
  council.debt_step(C, K)
end

--- The hard AI's first city-state (difficulty knob cs_plan; Phase 5 M3 ai, wave B.2): from Age II at peace, before any
--- operation, the council sizes the army for the nearest city-state (cs_ratio x its turret and garrison points, as
--- army.city_state_target counts them), the barracks favour artillery against its turrets (ai/mix.lua reads C.army.cs_plan), and the push
--- goes out as soon as the idle army's supply reaches that size, not at push_after.
function council.cs_plan_step(C, K)
  local a = C.army
  if not a then return end
  local k = difficulty.knobs(C.force)
  if not k.cs_plan or city_states_held(C.force) >= (k.cs_max or 1) or offensive_count(K) > 0 or at_war(C.force)
     or age_of(C.force) < 2 then
    a.cs_plan = nil
    return
  end
  local home = deps.cities and deps.cities.get and storage.nations and storage.nations[C.force]
    and deps.cities.get(storage.nations[C.force].capital)
  if not (home and home.position) then return end
  -- (the city-states of the world plan, as army.city_state_target sees them: their turrets and garrison are public; a
  -- sight-only intel record of a city-state 600 tiles out did not exist yet when the plan should start)
  local world, garrison = mod("world"), mod("garrison")
  local WAI = balance.nation.war and balance.nation.war.ai or {}
  local best, bd, points
  for _, rec in ipairs(world and world.city_states and world.city_states() or {}) do
    local c = rec.city_id and storage.cities and storage.cities[rec.city_id]
    if c and c.archetype == "city_state" and c.force == diplomacy.NEUTRAL and c.entity and c.entity.valid then
      local d = dist(c.position, home.position)
      if not bd or d < bd then
        local pts = 0
        for _, t in ipairs(rec.turrets or {}) do
          if t.valid and t.force.name == c.force then pts = pts + (WAI.turret_points or 4) end
        end
        local gar = garrison and garrison.of and garrison.of(c.id)
        best, bd, points = {id = c.id}, d, pts + (gar and gar.points or 0)
      end
    end
  end
  if not best then
    a.cs_plan = nil
    return
  end
  -- (the push's margin, as army.city_state_target applies it under a push: min(1.2, cs_ratio); at cs_ratio 1.6 the
  -- idle pool of 40-49 supply never reached 51 and the plan never fired, batch K)
  local need = math.min(1.2, k.cs_ratio) * points
  local first = not (a.cs_plan and a.cs_plan.city == best.id)
  a.cs_plan = {city = best.id, need = need, points = points}
  if first then
    util.log("council: %s sizes its army for city-state city %d (%.0f points, %.0f supply wanted, %.0f tiles)", C.force,
      best.id, points, need, bd)
  end
  if (a.pool_supply or 0) >= need and game.tick - (K.push_at or -1e9) >= 10 * 3600 then
    K.push_at = game.tick
    a.cs_push = game.tick
    a.cs_push_level = (a.cs_push_level or 0) + 1
    util.log("council: %s army ready for city-state city %d (supply %.0f of %.0f): pushes", C.force, best.id,
      a.pool_supply or 0, need)
  end
end

--- "council: ops 2 [#3 capture siege, #4 relief move], holds 1, belts 1, patrols 3, artillery 0, ...".
function council.describe(force_name)
  local K = K_of(force_name, false)
  if not K then return "council: -" end
  local parts = {}
  for _, id in ipairs(sorted_keys(K.ops)) do
    local op = K.ops[id]
    parts[#parts + 1] = string.format("#%d %s %s", op.id, op.kind, op.phase)
  end
  local st = K.stats
  return string.format("council: ops %d [%s] (started %d, done %d, aborted %d), holds %d (%d in all), belts %d, air "
    .. "patrols %d, interceptors %d, bombs %d, artillery %d, hires %d, mercs %d, retired %d", table_size(K.ops),
    table.concat(parts, ", "), st.ops, K.done or 0, st.aborted, table_size(K.holds), st.holds, st.belts, st.patrols,
    st.interceptors, st.bombs, st.artillery, st.hires, st.mercs, st.retired or 0)
end

deps.council = council
return council
