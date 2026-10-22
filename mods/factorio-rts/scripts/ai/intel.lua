-- Phase 5 M3 ai (docs/PHASE5-M3.md D7, §3 "ai/intel.lua"; study docs/research/scale/war-ai-performance.md §4.1): what an
-- AI nation knows about the others. scout.lua generalised to the nation scale: every difficulty intel_age ticks per AI
-- nation (60 / 30 / 10 s: how old the information a nation acts on may be; staggered by force), a sight check per object of the other forces: their cities (rivals and
-- city-states), divisions, rail depots, planes and unit clusters (cells of intel.cell tiles). An object is seen while an
-- own entity stands within intel.sight tiles of it (an own scout plane within intel.plane_sight) - the same rule as
-- scout.sees and trainswar.KNOWN, never chart state (charts are empty for AI forces and differ between a headless server
-- and a GUI peer: m3-perf's determinism rule). Nation mode only.
--
--   intel.known(force) -> {cities = {[id] = rec}, divisions = {[id] = rec}, rails = {[depot un] = rec},
--                          planes = {[unit number] = rec}, age_ticks}      (age_ticks = the difficulty's intel_age)
--   intel.fresh(force, rec) -> true when rec was seen within two of the force's scans (2 x intel_age)
--   intel.strength_near(force, enemy, position, radius, max_age?) -> supply of `enemy`'s (any hostile force's when nil)
--                          units known within radius (clusters seen within max_age, default intel.forget)
--   intel.city(force, city_id) -> rec | nil;  intel.enemy_planes_seen(force) -> tick | nil
--   intel.step(C)          ai/commander.lua (slice 3); work every intel.period
--   intel.describe(force)  "intel: cities 5 (2 fresh), divisions 3, depots 2, planes 0, clusters 7"
--
-- Records: city {id, force, position, tier, capital, defenders, turrets, seen}; division {id, force, position, n,
-- seen}; depot {un, force, position, seen}; plane {un, force, kind, position, seen}; cluster {x, y, n, supply, seen}
-- (storage.nations[force].intel.clusters[enemy][cell key]). Divisions, planes and clusters not seen for intel.forget
-- ticks are dropped; a city or depot is dropped when its spot is seen and it is gone (or changed hands: a city is
-- re-recorded under its new owner).
--
-- fronts.STRENGTH is replaced (install, from on_init and on_load, i.e. after every module loaded, on every peer alike):
-- for an AI nation the enemy strength near a front segment comes from intel; for a human nation fronts.lua's own rule.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local divisions = require("scripts.divisions")
local diplomacy = require("scripts.diplomacy")
local difficulty = require("scripts.ai.difficulty")
local sched = require("scripts.sched")
local balance = require("balance")

local intel = {}

local IB = balance.nation.ai3.intel

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function supply_of(name)
  local u = balance.units[name]
  return u and u.supply or 1
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  return out
end

--- The nation's intelligence table (storage.nations[force].intel), created on demand; nil outside a Nation match.
local function I_of(force_name, create)
  local N = storage.nations and storage.nations[force_name]
  if not N then return nil end
  local I = N.intel
  if not I and create then
    I = {next = 0, scans = 0, cities = {}, divisions = {}, rails = {}, planes = {}, clusters = {}}
    N.intel = I
  end
  return I
end
intel.state = function(force_name) return I_of(force_name, false) end

--- Is `pos` in sight of the force: an own entity within IB.sight, or an own scout plane within IB.plane_sight
--- (`scouts`: positions of the force's scout planes this scan).
local checks = 0 -- sight checks of the running scan step (its work units; reset by the step)
local function sees(surface, force_name, pos, scouts)
  checks = checks + 1
  if surface.count_entities_filtered({position = pos, radius = IB.sight, force = force_name, limit = 1}) > 0 then
    return true
  end
  if scouts then
    local r2 = IB.plane_sight * IB.plane_sight
    for _, p in ipairs(scouts) do
      local dx, dy = p.x - pos.x, p.y - pos.y
      if dx * dx + dy * dy <= r2 then return true end
    end
  end
  return false
end
intel.sees = sees

local function others(force_name)
  local out = {}
  for _, f in ipairs(storage.match and storage.match.forces or {}) do
    if f ~= force_name then out[#out + 1] = f end
  end
  return out
end

local function cell_key(cx, cy) return cx * 65536 + cy end

---------------------------------------------------------------------------
-- The scan
---------------------------------------------------------------------------
local function scan_cities(I, surface, force_name, scouts, tick)
  local garrison = mod("garrison")
  for _, id in ipairs(sorted_keys(storage.cities or {})) do
    local c = storage.cities[id]
    if c.force ~= force_name and c.position then
      if sees(surface, force_name, c.position, scouts) then
        local alive = c.entity and c.entity.valid
        if alive then
          local r = I.cities[id] or {id = id}
          I.cities[id] = r
          r.force, r.position, r.tier, r.capital = c.force, {x = c.position.x, y = c.position.y}, c.tier or 1, c.capital
          r.archetype = c.archetype
          local n = 0
          for _, e in ipairs(surface.find_entities_filtered({position = c.position, radius = 40, force = c.force,
                                                             type = {"unit", "spider-unit"}})) do
            if e.unit_number and storage.units and storage.units[e.unit_number] then n = n + 1 end
          end
          local g = garrison and garrison.of and garrison.of(id)
          r.turrets = surface.count_entities_filtered({position = c.position, radius = 30, force = c.force,
                                                       type = {"ammo-turret", "electric-turret"}})
          r.defenders = n + (g and g.points or 0)
          r.seen = tick
        else
          I.cities[id] = nil
        end
      end
    end
  end
  -- known cities that no longer exist (or are ours now): forgotten when their spot is seen
  for _, id in ipairs(sorted_keys(I.cities)) do
    local r = I.cities[id]
    local c = storage.cities and storage.cities[id]
    if (not c or c.force == force_name) and sees(surface, force_name, r.position, scouts) then I.cities[id] = nil end
  end
end

local function scan_divisions(I, surface, force_name, scouts, tick)
  for _, f in ipairs(others(force_name)) do
    for _, D in ipairs(divisions.for_force(f)) do
      local n = divisions.strength(D)
      local pos = D.pos
      if n and n > 0 and pos and sees(surface, force_name, pos, scouts) then
        local r = I.divisions[D.id] or {id = D.id}
        I.divisions[D.id] = r
        r.force, r.position, r.n, r.seen = f, {x = pos.x, y = pos.y}, n, tick
      end
    end
  end
  for _, id in ipairs(sorted_keys(I.divisions)) do
    local r = I.divisions[id]
    if tick - r.seen > IB.forget or (not divisions.get(id) and sees(surface, force_name, r.position, scouts)) then
      I.divisions[id] = nil
    end
  end
end

local function scan_depots(I, surface, force_name, scouts, tick)
  local R = storage.rails
  for _, un in ipairs(sorted_keys(R and R.depots or {})) do
    local d = R.depots[un]
    local e = d.entity
    if d.force ~= force_name and e and e.valid and sees(surface, force_name, e.position, scouts) then
      local r = I.rails[un] or {un = un}
      I.rails[un] = r
      r.force, r.position, r.line, r.seen = d.force, {x = e.position.x, y = e.position.y}, d.line, tick
    end
  end
  for _, un in ipairs(sorted_keys(I.rails)) do
    local r = I.rails[un]
    local d = R and R.depots[un]
    if not (d and d.entity and d.entity.valid and d.force == r.force) and sees(surface, force_name, r.position, scouts) then
      I.rails[un] = nil
    end
  end
end

local function scan_planes(I, surface, force_name, scouts, tick)
  local air = mod("air")
  if not (air and air.planes) then return end
  for _, f in ipairs(others(force_name)) do
    local planes = air.planes(f)
    for _, un in ipairs(sorted_keys(planes)) do
      local rec = units.get(un)
      if rec and rec.entity.valid and sees(surface, force_name, rec.entity.position, scouts) then
        local r = I.planes[un] or {un = un}
        I.planes[un] = r
        local p = rec.entity.position
        r.force, r.kind, r.position, r.seen = f, rec.kind, {x = p.x, y = p.y}, tick
        if diplomacy.hostile(force_name, f) then I.enemy_planes = tick end
      end
    end
  end
  for _, un in ipairs(sorted_keys(I.planes)) do
    local r = I.planes[un]
    if tick - r.seen > IB.forget or not units.get(un) then I.planes[un] = nil end
  end
end

-- Unit clusters: each other force's combat units bucketed by cell; a cell is checked at its units' centroid (at most
-- cluster_checks cells per force and scan, the fullest first); recorded cells not checked this scan whose spot is seen
-- empty are dropped.
local function scan_clusters(I, surface, force_name, scouts, tick, only)
  local C = IB.cell
  for _, f in ipairs(only and {only} or others(force_name)) do
    local cells, order = {}, {}
    for _, rec in units.for_force(f) do
      if rec.kind ~= "hauler" and rec.kind ~= "commander" then
        local p = rec.entity.position
        local k = cell_key(math.floor(p.x / C), math.floor(p.y / C))
        local b = cells[k]
        if not b then
          b = {k = k, sx = 0, sy = 0, n = 0, supply = 0}
          cells[k] = b
          order[#order + 1] = b
        end
        b.sx, b.sy, b.n = b.sx + p.x, b.sy + p.y, b.n + 1
        b.supply = b.supply + supply_of(rec.entity.name)
      end
    end
    table.sort(order, function(a, b)
      if a.n ~= b.n then return a.n > b.n end
      return a.k < b.k
    end)
    local known = I.clusters[f] or {}
    I.clusters[f] = known
    local checked = {}
    for i = 1, math.min(#order, IB.cluster_checks) do
      local b = order[i]
      local pos = {x = b.sx / b.n, y = b.sy / b.n}
      checked[b.k] = true
      if sees(surface, force_name, pos, scouts) then
        known[b.k] = {x = pos.x, y = pos.y, n = b.n, supply = b.supply, seen = tick}
      end
    end
    for _, k in ipairs(sorted_keys(known)) do
      local r = known[k]
      if tick - r.seen > IB.forget then
        known[k] = nil
      elseif not checked[k] and r.seen < tick and sees(surface, force_name, r, scouts) then
        known[k] = nil -- the spot is in sight and nothing of that force is in the cell any more
      end
    end
    if next(known) == nil then I.clusters[f] = nil end
  end
end

--- One intelligence pass for commander C (ai/commander.lua, slice 3, every run): a scan every intel_age ticks.
function intel.step(C)
  if not nation_mode() then return end
  local m = storage.match
  if not (m and m.phase == "running") then return end
  local I = I_of(C.force, true)
  if not I then return end
  local tick = game.tick
  if tick < I.next then return end
  if I.next == 0 then
    -- first pass: stagger the nations' scans by force name
    local slot = 0
    for f in pairs(storage.ai or {}) do
      if f < C.force then slot = slot + 1 end
    end
    I.next = tick + (slot * 71) % difficulty.knobs(C.force).intel_age
    return
  end
  I.next = tick + difficulty.knobs(C.force).intel_age
  if I.job and sched.status(I.job) and sched.status(I.job) ~= "done" and sched.status(I.job) ~= "cancelled"
     and sched.status(I.job) ~= "failed" then
    return -- the last scan is still running
  end
  local state = {force = C.force, i = 1}
  local id = sched.submit(C.force, "ai3_intel", state, sched.NORMAL)
  if id then
    I.job = id
  else
    sched.run_sync("ai3_intel", state, C.force)
  end
end

-- The scan as a scheduler job: one part per step (cities, divisions, depots, planes, then the unit clusters of each
-- other force), a sight check counting UNITS_PER_CHECK work units.
intel.UNITS_PER_CHECK = 15
local PARTS = {"cities", "divisions", "depots", "planes"}
sched.register("ai3_intel", function(job, units)
  local st = job.state
  local I = I_of(st.force, true)
  local surface = util.surface()
  if not (I and surface and nation_mode()) then return 1, true end
  local tick = game.tick
  if not st.scouts then
    -- the scan's eyes in the air: own scout planes (positions now)
    local scouts = {}
    local air = mod("air")
    if air and air.planes then
      local planes = air.planes(st.force)
      for _, un in ipairs(sorted_keys(planes)) do
        local rec = units.get(un)
        if rec and rec.kind == "scout-plane" and rec.entity.valid then
          local p = rec.entity.position
          scouts[#scouts + 1] = {x = p.x, y = p.y}
        end
      end
    end
    st.scouts = scouts
    st.forces = others(st.force)
  end
  checks = 0
  local part = PARTS[st.i]
  if part == "cities" then
    scan_cities(I, surface, st.force, st.scouts, tick)
  elseif part == "divisions" then
    scan_divisions(I, surface, st.force, st.scouts, tick)
  elseif part == "depots" then
    scan_depots(I, surface, st.force, st.scouts, tick)
  elseif part == "planes" then
    scan_planes(I, surface, st.force, st.scouts, tick)
  else
    local f = st.forces[st.i - #PARTS]
    if f then scan_clusters(I, surface, st.force, st.scouts, tick, f) end
  end
  st.i = st.i + 1
  local done = st.i > #PARTS + #st.forces
  if done then I.scans = I.scans + 1 end
  return 10 + checks * intel.UNITS_PER_CHECK, done
end)

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
local EMPTY = {cities = {}, divisions = {}, rails = {}, planes = {}}

function intel.known(force_name)
  local I = I_of(force_name, false) or EMPTY
  return {cities = I.cities, divisions = I.divisions, rails = I.rails, planes = I.planes,
          age_ticks = difficulty.knobs(force_name).intel_age}
end

function intel.fresh(force_name, rec)
  return rec ~= nil and rec.seen ~= nil and game.tick - rec.seen <= 2 * difficulty.knobs(force_name).intel_age
end

function intel.city(force_name, city_id)
  local I = I_of(force_name, false)
  return I and I.cities[city_id] or nil
end

function intel.enemy_planes_seen(force_name)
  local I = I_of(force_name, false)
  return I and I.enemy_planes or nil
end

--- Supply of `enemy`'s known units (clusters) within `radius` of `position`; enemy nil = every hostile force.
function intel.strength_near(force_name, enemy, position, radius, max_age)
  local I = I_of(force_name, false)
  if not I then return 0 end
  local age = max_age or IB.forget
  local r2 = radius * radius
  local tick = game.tick
  local n = 0
  for _, f in ipairs(sorted_keys(I.clusters)) do
    if (enemy and f == enemy) or (not enemy and diplomacy.hostile(force_name, f)) then
      for _, k in ipairs(sorted_keys(I.clusters[f])) do
        local r = I.clusters[f][k]
        local dx, dy = r.x - position.x, r.y - position.y
        if tick - r.seen <= age and dx * dx + dy * dy <= r2 then n = n + r.supply end
      end
    end
  end
  return n
end

function intel.describe(force_name)
  local I = I_of(force_name, false)
  if not I then return "intel: -" end
  local fresh, nc = 0, 0
  for _, r in pairs(I.cities) do
    nc = nc + 1
    if intel.fresh(force_name, r) then fresh = fresh + 1 end
  end
  local clusters = 0
  for _, t in pairs(I.clusters) do clusters = clusters + table_size(t) end
  return string.format("intel: scans %d, cities %d (%d fresh), divisions %d, depots %d, planes %d, clusters %d%s",
    I.scans, nc, fresh, table_size(I.divisions), table_size(I.rails), table_size(I.planes), clusters,
    I.enemy_planes and string.format(", enemy planes seen %ds ago", (game.tick - I.enemy_planes) / 60) or "")
end

---------------------------------------------------------------------------
-- fronts.STRENGTH for AI nations (installed after every module loaded, identically on every peer)
---------------------------------------------------------------------------
local installed = false
local function install()
  if installed then return end
  local fronts = mod("fronts")
  if not (fronts and fronts.STRENGTH) then return end
  installed = true
  local base = fronts.STRENGTH
  fronts.STRENGTH = function(force_name, enemy, position, radius)
    if storage.ai and storage.ai[force_name] and nation_mode() and storage.nations and storage.nations[force_name] then
      return intel.strength_near(force_name, enemy, position, radius)
    end
    return base(force_name, enemy, position, radius)
  end
end
events.on_init(install)
events.on_load(install)
events.on_configuration_changed(install)

return intel
