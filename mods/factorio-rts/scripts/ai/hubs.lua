-- AI forward hubs (Phase 4: docs/PHASE4.md 2.1, 2.2 and 6). The build-order step
--   {kind = "hub", id = N, ore = "iron-ore", extractors = 2, slots = 2, solar = 2, haulers = 2}
-- picks the nearest unclaimed iron or copper patch outside the main base (preferring `ore`; the map generator's
-- "natural" patches 60-80 tiles out are found like any other patch, nothing assumes positions), places an rts-hub
-- next to it on the side towards the CC, and plans a mining line into the hub's two stockpiles (layout.lua hub
-- sink: smelter slots E1/W1/N1/N2 of the hub frame), extra poles for slot machines outside the hub's hidden pole,
-- and `solar` solar arrays south of the hub (the hub's own 300 kW covers itself and about two extractors).
-- Once the hub stands, hubs.step sets its policy (keep thresholds off, export_above <plate> = EXPORT), takes its
-- construction robots out (the AI builds by paced revive) and makes the CC keep CC_KEEP of that plate, so the auto
-- haulers based at the CC bring the plates home. `haulers` adds to the force's hauler target (C.want_haulers);
-- the workshop factory makes the kits (ai/commander.lua) and every auto hauler of the force is homed at the CC.
--
-- A step may plan more than it builds (plan_slots, plan_solar): a later step with the same id builds the rest.
-- front = true moves the hub's queue entries to the front of the construction queue (behind labs and factories).
--
-- C.expansions[id] = X = {id, ore, plate, status = "ok" | "unavailable", reason?, patch_id, pos (hub centre),
--   frame, hub (slot states), line (C.lines key "hub<id>"), hub_key, solar = {keys}, poles = {keys}, haulers,
--   hub_un (the live hub), setup_un (the hub the policy was set for)}
-- storage.ai_meta.patch_claims[patch id] = force: patches an AI commander took (two AIs never plan one patch).
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local layout = require("scripts.ai.layout")
local construction = require("scripts.ai.construction")
local build_order = require("scripts.ai.build_order")
local deps = require("scripts.ai.deps")

local hubs = {}

hubs.PLATE = {["iron-ore"] = "iron-plate", ["copper-ore"] = "copper-plate"}
hubs.MAX_PATCH = 150      -- patches farther than this from the CC are not considered
hubs.MAIN_RADIUS = 45     -- patches closer than this to the CC are the main base's
hubs.HOSTILE_RADIUS = 50  -- patches closer than this to another force's spawn, CC or hub are theirs
hubs.CONTEST_SLACK = 15   -- a patch may be at most this much farther from us than from the nearest other base
hubs.MIN_TILES = 30
hubs.MIN_HOME = 42        -- hub centre this far from the own CC along x or y at least (the CC's 50x50 logistic
                          -- square and the hub's 28x28 one must not touch: a hub at 45 tiles straight, 36 along x,
                          -- joined the CC network and its hauler never had anything to fetch)
hubs.MIN_APART = 24       -- ... and this far from any other hub (a natural pair gets two hubs; their networks may join)
hubs.CONTEXT_RADIUS = 42
hubs.MAX_TRIES = 5        -- candidate patches tried per plan
hubs.PLAN_TRIES = 3       -- plans per step before it is skipped for good
hubs.EXPORT = 20          -- the hub exports its plate above this many
hubs.CC_KEEP = 400        -- the CC requests the plate up to this many (auto haulers serve it)
hubs.BUILDING_TYPES = {"entity-ghost", "mining-drill", "roboport", "furnace", "transport-belt", "electric-pole",
                       "container", "logistic-container", "assembling-machine", "inserter", "solar-panel"}

local function other_forces(C)
  local list = {}
  for _, f in ipairs(storage.match and storage.match.forces or {}) do
    if f ~= C.force and game.forces[f] then list[#list + 1] = f end
  end
  return list
end

local function snapshot(C)
  local s = {reserved = {}, avoid = {}, belt_tiles = {}, claimed = {}}
  for k, v in pairs(C.reserved) do s.reserved[k] = v end
  for k, v in pairs(C.avoid) do s.avoid[k] = v end
  for k, v in pairs(C.belt_tiles) do s.belt_tiles[k] = v end
  for k, v in pairs(C.claimed) do s.claimed[k] = v end
  return s
end

local function restore(C, s)
  for _, name in ipairs({"reserved", "avoid", "belt_tiles", "claimed"}) do
    local t = C[name]
    for k in pairs(t) do t[k] = nil end
    for k, v in pairs(s[name]) do t[k] = v end
  end
end

-- Candidate patches for an expansion of commander C, best first: {p, d}.
local function candidates(C, surface, step)
  local meta = storage.ai_meta
  local home = {x = C.frame.cx, y = C.frame.cy}
  local hostile = {}
  for f, pos in pairs(storage.match and storage.match.spawns or {}) do
    if f ~= C.force then hostile[#hostile + 1] = pos end
  end
  for _, rec in buildings.all("cc") do
    if rec.force ~= C.force then hostile[#hostile + 1] = rec.position end
  end
  for _, rec in buildings.all("hub") do
    if rec.force ~= C.force then hostile[#hostile + 1] = rec.position end
  end
  local cands = {}
  for _, p in ipairs(layout.resource_patches(surface, home, hubs.MAX_PATCH)) do
    local c = {x = p.cx, y = p.cy}
    local d = util.distance(c, home)
    local claim = meta.patch_claims[p.id]
    if hubs.PLATE[p.name] and p.count >= hubs.MIN_TILES and d >= hubs.MAIN_RADIUS and not C.claimed[p.id]
       and (claim == nil or claim == C.force) then
      local d_other = math.huge
      for _, h in ipairs(hostile) do
        local dh = util.distance(c, h)
        if dh < d_other then d_other = dh end
      end
      if d_other >= hubs.HOSTILE_RADIUS and d <= d_other + hubs.CONTEST_SLACK then
        cands[#cands + 1] = {p = p, d = d, pref = (p.name == step.ore) and 0 or 1}
      end
    end
  end
  table.sort(cands, function(a, b)
    if a.pref ~= b.pref then return a.pref < b.pref end
    if a.d ~= b.d then return a.d < b.d end
    return a.p.id < b.p.id
  end)
  return cands
end

--- Plan expansion step.id of commander C (see the header). Returns X (status "ok" or "unavailable").
function hubs.plan(C, surface, step)
  C.expansions = C.expansions or {}
  local meta = storage.ai_meta
  meta.patch_claims = meta.patch_claims or {}
  local X = {id = step.id, ore = step.ore, status = "unavailable", line = "hub" .. step.id, reason = "no patch"}
  C.expansions[step.id] = X
  local home = {x = C.frame.cx, y = C.frame.cy}
  local keep_away = {}
  for _, rec in buildings.all("hub") do keep_away[#keep_away + 1] = rec.position end
  for _, other in pairs(C.expansions) do
    if other.pos then keep_away[#keep_away + 1] = other.pos end
  end
  local others = other_forces(C)
  local prof = helpers.create_profiler()
  local tried = 0
  for _, cand in ipairs(candidates(C, surface, step)) do
    if tried >= hubs.MAX_TRIES then break end
    tried = tried + 1
    local p = cand.p
    local x0, y0, x1, y1 = layout.patch_box(p)
    local taken = #others > 0 and surface.count_entities_filtered({area = {{x0 - 8, y0 - 8}, {x1 + 9, y1 + 9}},
      force = others, type = hubs.BUILDING_TYPES, limit = 1}) > 0
    if taken then
      util.log("ai %s: hub %d: patch %s is taken by another force", C.force, step.id, p.id)
      X.reason = "patches taken"
    else
      local ctx = layout.context_at(C, surface, {cx = math.floor(p.cx), cy = math.floor(p.cy), fx = 1},
        hubs.CONTEXT_RADIUS)
      local cp
      for _, q in ipairs(layout.patches(ctx)) do
        if q.id == p.id then cp = q break end
      end
      local site = cp and layout.hub_site(C, ctx, cp, home, hubs.MIN_HOME, keep_away, hubs.MIN_APART)
      if not site then
        util.log("ai %s: hub %d: no hub site next to %s", C.force, step.id, p.id)
        X.reason = "no hub site"
      else
        local snap = snapshot(C)
        local frame = layout.hub_frame(site.x, site.y)
        layout.reserve_hub_body(C, site.x, site.y, X.line)
        -- haulers stop just south of the hub (logistics.approach_point): keep that column free of solar arrays
        for ty = site.y + 2, site.y + 7 do
          C.reserved[layout.tkey(site.x - 1, ty)] = "approach"
          C.reserved[layout.tkey(site.x, ty)] = "approach"
        end
        local slot_states = {}
        layout.reserve_hub(C, frame, slot_states, layout.HUB_SINK_ORDER)
        local solar_pos = {}
        local P = layout.HUB_SOLAR
        for i = 1, step.plan_solar or step.solar or 0 do
          local pos = layout.find_spot_in(C, surface, "rts-solar-array", site.x + P[1], site.y + P[3], site.x + P[2],
            site.y + P[4], {x = site.x + (i % 2 == 1 and -5 or 5), y = site.y + 5})
          if pos then solar_pos[#solar_pos + 1] = pos end
        end
        local slots = {}
        for i = 1, step.plan_slots or step.slots or 2 do slots[i] = "smelter" end
        local sink = {frame = frame, hub = slot_states, order = layout.HUB_SINK_ORDER, target = {x = site.x, y = site.y},
                      wire = layout.HUB_WIRE, satellites = false}
        local L = build_order.plan_line(C, ctx, X.line, {ore = p.name, patch_id = p.id, slots = slots}, sink)
        if L.status == "ok" and L.chained then
          X.status, X.reason, X.patch_id, X.ore, X.plate = "ok", nil, p.id, p.name, hubs.PLATE[p.name]
          X.pos, X.frame, X.hub, X.haulers = site, frame, slot_states, step.haulers or 1
          meta.patch_claims[p.id] = C.force
          -- the stockpile spots must be free of units when the hub is revived: logistics.lua moves a blocked
          -- stockpile up to 4 tiles, and the west one (the side the army and the patrol come from) kept moving
          local clear = {}
          for _, off in ipairs(deps.logistics and deps.logistics.HUB_STOCKPILES or {}) do
            local x, y = site.x + off.x, site.y + off.y
            clear[#clear + 1] = {{x - 0.7, y - 0.7}, {x + 0.7, y + 0.7}}
          end
          X.hub_key = construction.add(C, {name = "rts-hub", x = site.x, y = site.y, line = X.line, clear = clear})
          X.solar = {}
          local specs = {}
          for _, pos in ipairs(solar_pos) do
            X.solar[#X.solar + 1] = construction.add(C, {name = "rts-solar-array", x = pos.x, y = pos.y, line = X.line})
            specs[#specs + 1] = {name = "rts-solar-array", x = pos.x, y = pos.y}
          end
          for _, s in ipairs(L.slots) do
            for _, key in ipairs(s.keys) do
              local e = C.plan[key]
              specs[#specs + 1] = {name = e.name, x = e.x, y = e.y}
            end
          end
          local poles = {}
          for _, key in pairs(L.gap_poles) do poles[#poles + 1] = {x = C.plan[key].x, y = C.plan[key].y} end
          for _, key in ipairs(L.chain) do poles[#poles + 1] = {x = C.plan[key].x, y = C.plan[key].y} end
          X.poles = {}
          for _, q in ipairs(layout.cover_power(C, ctx, site, specs, poles, X.line)) do
            X.poles[#X.poles + 1] = construction.add(C, {name = layout.POLE, x = q.x, y = q.y, line = X.line})
          end
          prof.stop()
          log({"", string.format("[rts] ai %s: hub %d planned at %s next to %s (%d ore tiles, %.0f tiles from the CC): "
            .. "%d drill spots, slots [%s], %d solar, %d extra poles, %d hauler(s) wanted; planned in ", C.force,
            step.id, util.pos_str(site), p.id, p.count, cand.d, #L.drills, (function()
              local n = {}
              for i, s in ipairs(L.slots) do n[i] = s.name end
              return table.concat(n, " ")
            end)(), #X.solar, #X.poles, X.haulers), prof})
          return X
        end
        util.log("ai %s: hub %d: line into a hub at %s next to %s failed: %s", C.force, step.id, util.pos_str(site),
          p.id, L.status == "ok" and "pole chain does not reach the hub" or tostring(L.reason))
        X.reason = "line failed"
        C.lines[X.line] = nil
        -- drop the plan entries the failed line added, then the reservations
        for key, e in pairs(C.plan) do
          if e.line == X.line and e.status == "planned" then C.plan[key] = nil end
        end
        restore(C, snap)
      end
    end
  end
  prof.stop()
  log({"", string.format("[rts] ai %s: hub %d unavailable (%s) after %d patch(es) in ", C.force, step.id,
    X.reason, tried), prof})
  return X
end

---------------------------------------------------------------------------
-- The "hub" build-order step kind
---------------------------------------------------------------------------
local function expansion(C, step)
  return C.expansions and C.expansions[step.id]
end

local function satisfied(C, step, st)
  local X = expansion(C, step)
  if not X or X.status ~= "ok" then return false end
  if not construction.is_built(C, X.hub_key) then return false end
  local L = C.lines[X.line]
  if build_order.line_drills_built(C, L) < math.min(step.extractors or 2, #L.drills) then return false end
  if build_order.line_slots_built(C, L) < math.min(step.slots or 2, #L.slots) then return false end
  for i = 1, math.min(step.solar or 0, #X.solar) do
    if not construction.is_built(C, X.solar[i]) then return false end
  end
  return true
end

local function in_progress(C, step)
  local X = expansion(C, step)
  return X ~= nil and X.status == "ok" and build_order.line_busy(C, {name = X.line})
end

-- Trees, rocks and items on the hub's two stockpile tiles: logistics.lua places the stockpiles when the hub is built
-- and moves one up to 4 tiles when its spot is taken, and then the smelters' output inserters drop plates on the
-- ground (planning treats trees and rocks as free; construction clears only the footprints of what it builds).
local function clear_stockpile_spots(surface, X)
  for _, off in ipairs(deps.logistics and deps.logistics.HUB_STOCKPILES or {}) do
    local x, y = X.pos.x + off.x, X.pos.y + off.y
    for _, e in pairs(surface.find_entities_filtered({area = {{x - 0.5, y - 0.5}, {x + 0.5, y + 0.5}},
                                                       type = {"tree", "simple-entity", "item-entity"}})) do
      if e.valid then e.destroy() end
    end
  end
end

local function execute(C, step, st, surface)
  local X = expansion(C, step)
  if not X or (X.status ~= "ok" and (st.hub_tries or 0) < hubs.PLAN_TRIES) then
    st.hub_tries = (st.hub_tries or 0) + 1
    X = hubs.plan(C, surface, step)
  end
  if X.status ~= "ok" then
    if st.hub_tries >= hubs.PLAN_TRIES then
      st.skipped = X.reason
    else
      st.retry_at = game.tick + 30 * 60
    end
    return 0
  end
  local n = 0
  if construction.queue(C, X.hub_key) then n = n + 1 end
  clear_stockpile_spots(surface, X)
  local L = C.lines[X.line]
  n = n + build_order.want_drills(C, L, step.extractors or 2)
  n = n + build_order.want_slots(C, L, step.slots or 2)
  build_order.queue_list(C, X.poles)
  for i = 1, math.min(step.solar or 0, #X.solar) do
    if construction.queue(C, X.solar[i]) then n = n + 1 end
  end
  if step.front then
    -- the hub's entries go to the front of the construction queue (the factory makes their items next), behind
    -- queued labs and factories only: those carry the research
    local first, front, rest = {}, {}, {}
    for _, key in ipairs(C.queue) do
      local e = C.plan[key]
      if e and (e.name == "rts-lab" or e.name == "rts-factory") then
        first[#first + 1] = key
      elseif e and e.line == X.line then
        front[#front + 1] = key
      else
        rest[#rest + 1] = key
      end
    end
    for _, key in ipairs(front) do first[#first + 1] = key end
    for _, key in ipairs(rest) do first[#first + 1] = key end
    C.queue = first
  end
  return n
end

local function describe(step)
  return string.format("hub %d (%s, %d extractors, %d slots, %d solar, %d haulers)", step.id, step.ore or "-",
    step.extractors or 2, step.slots or 2, step.solar or 0, step.haulers or 1)
end

build_order.KINDS.hub = {satisfied = satisfied, in_progress = in_progress, execute = execute, describe = describe}

---------------------------------------------------------------------------
-- Upkeep: policies, robots, haulers
---------------------------------------------------------------------------
--- Haulers of the force plus hauler kits waiting in its factories or CC network.
function hubs.hauler_count(C)
  local L = deps.logistics
  local n = 0
  if L then
    for _ in L.haulers_of(C.force) do n = n + 1 end
  end
  for _, rec in buildings.for_force(C.force, "factory") do
    local out = rec.entity.get_output_inventory()
    if out then n = n + out.get_item_count("rts-hauler-kit") end
  end
  return n + construction.have(C, "rts-hauler-kit")
end

--- Once per run: set up new hubs, home every auto hauler at the CC, update C.want_haulers.
function hubs.step(C)
  local L = deps.logistics
  if not (L and C.expansions) then
    C.want_haulers = (C.people_haulers or 0) + (C.route_haulers or 0) -- Phase 5 M2 people / ai (governor routes)
    return
  end
  local cc = buildings.main_cc(C.force)
  local cc_un = cc and cc.entity.unit_number
  local want = 0
  for _, X in pairs(C.expansions) do
    if X.status == "ok" then
      local e = C.plan[X.hub_key]
      local hub = e and e.status == "built" and e.entity and e.entity.valid and e.entity or nil
      X.hub_un = hub and hub.unit_number or nil
      local Lx = C.lines[X.line]
      if hub and build_order.line_drills_built(C, Lx) > 0 and build_order.line_slots_built(C, Lx) > 0 then
        -- haulers once the line runs: a kit made earlier would take the plates the hub's own parts need
        want = want + (X.haulers or 1)
      end
      if hub then
        if X.setup_un ~= hub.unit_number then
          local un = hub.unit_number
          L.set_policy(un, "keep", "iron-plate", nil)
          L.set_policy(un, "keep", "copper-plate", nil)
          L.set_policy(un, "export_above", X.plate, hubs.EXPORT)
          if cc_un then L.set_policy(cc_un, "keep", X.plate, hubs.CC_KEEP) end
          local robots = hub.get_inventory(defines.inventory.roboport_robot)
          local bots = robots and robots.get_item_count("construction-robot") or 0
          if bots > 0 then robots.remove({name = "construction-robot", count = bots}) end
          X.setup_un = un
          -- where logistics.lua put the stockpiles (the slots' output inserters expect HUB_STOCKPILES)
          local p = L.policy(un)
          local spots = {}
          for _, s in ipairs(p and p.parts and p.parts.stockpiles or {}) do
            if s.valid then spots[#spots + 1] = util.pos_str({s.position.x - X.pos.x, s.position.y - X.pos.y}) end
          end
          util.log("ai %s: hub %d (#%d) at %s set up: export %s above %d, CC keeps %d, %d construction robots out, "
            .. "stockpiles at offsets [%s]", C.force, X.id, un, util.pos_str(X.pos), X.plate, hubs.EXPORT, hubs.CC_KEEP,
            bots, table.concat(spots, " "))
        end
      end
    end
  end
  -- Phase 5 M2 people: a supply hauler per other city; Phase 5 M2 ai: an export route per town (ai/governor.lua)
  C.want_haulers = want + (C.people_haulers or 0) + (C.route_haulers or 0)
  if cc_un then
    for un, h in L.haulers_of(C.force) do
      if h.mode == "auto" and h.home ~= cc_un then L.set_home(un, cc_un) end
    end
  end
end

--- The route of the first live hub: {from = CC position, to = hub position, hub_un}, or nil.
function hubs.route(C)
  local cc = buildings.main_cc(C.force)
  if not (cc and C.expansions) then return nil end
  local ids = {}
  for id in pairs(C.expansions) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local X = C.expansions[id]
    if X.hub_un and X.pos then return {from = cc.position, to = X.pos, hub_un = X.hub_un} end
  end
  return nil
end

local STATUS_NAME = {}
for name, v in pairs(defines.entity_status) do STATUS_NAME[v] = name end

--- Diagnostic lines: per expansion, the built machines of its line by name and entity status.
function hubs.diagnose(C)
  local lines = {}
  local ids = {}
  for id in pairs(C.expansions or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local X = C.expansions[id]
    if X.status == "ok" then
      local counts = {}
      for _, e in pairs(C.plan) do
        if e.line == X.line and e.status == "built" and e.entity and e.entity.valid
           and e.name ~= "transport-belt" and e.name ~= layout.POLE then
          local st = e.entity.status
          local key = e.name .. ":" .. (st and STATUS_NAME[st] or "-")
          counts[key] = (counts[key] or 0) + 1
        end
      end
      local parts = {}
      for k, n in pairs(counts) do parts[#parts + 1] = k .. "=" .. n end
      table.sort(parts)
      lines[#lines + 1] = string.format("ai %s hub%d diagnose: %s", C.force, id, table.concat(parts, " "))
    end
  end
  return lines
end

--- One line per expansion for the dump.
function hubs.describe(C)
  local parts = {}
  local ids = {}
  for id in pairs(C.expansions or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local X = C.expansions[id]
    if X.status == "ok" then
      local L = C.lines[X.line]
      local entry = X.hub_un and deps.logistics and deps.logistics.entry_for_hub(X.hub_un)
      parts[#parts + 1] = string.format("hub%d %s at %s: hub %s drills %d/%d slots %d/%d solar %d, network %s %s",
        id, X.plate, util.pos_str(X.pos), X.hub_un and ("#" .. X.hub_un) or "not built",
        build_order.line_drills_built(C, L), #L.drills, build_order.line_slots_built(C, L), #L.slots, #X.solar,
        X.plate, entry and tostring(entry.contents[X.plate] or 0) or "-")
    else
      parts[#parts + 1] = string.format("hub%d unavailable (%s)", id, tostring(X.reason))
    end
  end
  local stats = deps.logistics and deps.logistics.stats(C.force)
  local delivered = {}
  for item, n in pairs(stats and stats.delivered or {}) do delivered[#delivered + 1] = item .. "=" .. n end
  table.sort(delivered)
  return string.format("%s | haulers %d (want %d), trips %d, delivered [%s], lost %d",
    #parts > 0 and table.concat(parts, "; ") or "no hubs", hubs.hauler_count(C), C.want_haulers or 0,
    stats and stats.trips or 0, table.concat(delivered, " "), stats and stats.lost or 0)
end

return hubs
