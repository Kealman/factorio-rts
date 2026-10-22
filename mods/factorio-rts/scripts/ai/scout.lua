-- AI scouting (docs/PHASE3.md "ai/scout.lua"): what an AI force knows about its enemies.
--
-- C.known[unit_number] = {position, kind, name, force, seen}: enemy buildings (buildings.lua registry) the force has
-- seen. Honest vision ("honest", easy and normal): a spot is seen while any entity of the force (unit, building,
-- belt, pole) is within SIGHT tiles of it, or its chunk is visible to the force. Chunk visibility alone does not work:
-- in headless runs LuaForce.is_chunk_visible (and is_chunk_charted) stayed false everywhere for both forces, with
-- RTS units (radar_range = 1) standing in the chunks. Full vision (hard) sees everything. A known building is forgotten once it is gone and its spot is visible again, so the army
-- walks up to a ruin before it learns it is gone.
-- C.guesses[force] = {position}: the other forces' spawn points (storage.match.spawns), the usual start-location
-- knowledge of a skirmish map. A guess is dropped once its chunk has been seen.
-- Enemy units are not remembered; scout.visible_enemy_unit finds the nearest visible one on demand.
--
-- The match charts the whole arena for rts-player at start (match.lua chart_arena), so is_chunk_charted would be
-- true everywhere for that force; visibility is what makes the two AI forces equal.
-- Phase 4: each scan also counts the enemy units it sees by kind, C.seen[kind] = {n, tick} (ai/mix.lua counters
-- read the last minute), and remembers seen enemy haulers, C.enemy_haulers[unit_number] = tick. Honest vision checks
-- at most UNIT_CHECKS enemy units per scan. scout.harass_target picks raider targets.
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local units = require("scripts.units")
local data = require("scripts.ai.orders_data")
-- Phase 5 M3 ai (wave B.2): Nation-only paths (the target cache, the recorded patches)
local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end
local function loaded(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end
local layout = require("scripts.ai.layout")
local diplomacy = require("scripts.diplomacy") -- Phase 5 M2 diplomacy: every target test asks diplomacy.hostile

local scout = {}

scout.PERIOD = 300 -- ticks between scans
scout.SIGHT = 30   -- tiles; the units' vision_distance (prototypes/units.lua)
scout.UNIT_CHECKS = 150 -- enemy units checked for sight per scan (honest vision)
scout.WALL_CHECKS = 50  -- enemy wall segments (registered buildings) checked for sight per scan
scout.HAULER_MEMORY = 60 * 60 -- a seen enemy hauler stays a harass target this long
scout.ENEMY_ARMY_TICKS = 3 * 60 * 60 -- the largest enemy army seen is remembered this long

--- True when commander C sees `pos` now.
-- Phase 5 M3 perf (determinism): sight only, no chart state. LuaForce.is_chunk_visible is false everywhere on a headless
-- server (it charts nothing) but true on a GUI peer for a charted force (rts-player, which the autotest's AI also
-- commands, and the allies of a human force share its chart), so the old shortcut made an AI decision differ between
-- the server and a client: a desync. Headless runs never took it, so their results are unchanged.
function scout.sees(C, force, surface, pos)
  if C.cfg.vision == "full" then return true end
  return surface.count_entities_filtered({position = pos, radius = scout.SIGHT, force = force, limit = 1}) > 0
end

local function is_enemy(force, other_name)
  return diplomacy.hostile(force.name, other_name) -- Phase 5 M2 diplomacy (was LuaForce.is_enemy)
end

--- Seed the spawn guesses (once per commander).
function scout.seed(C)
  C.guesses = C.guesses or {}
  local m = storage.match
  for force_name, pos in pairs(m and m.spawns or {}) do
    if force_name ~= C.force then C.guesses[force_name] = {position = {x = pos.x, y = pos.y}} end
  end
end

-- Phase 5 M2 world: a match force (the rivals; rts-neutral is not one). True outside a match (tests).
local function rival(f)
  local m = storage.match
  if not m then return true end
  for _, name in ipairs(m.forces or {}) do
    if name == f then return true end
  end
  return false
end

--- Scan: add seen enemy buildings, forget the ones seen to be gone, drop seen guesses.
function scout.step(C, surface)
  local force = game.forces[C.force]
  if not force then return end
  local tick = game.tick
  local enemies = {}
  local walls = 0
  for _, rec in buildings.all() do
    local f = rec.force
    if f ~= C.force and rec.surface == surface.index then
      -- Phase 5 M2 world: only the match forces' buildings become known targets. rts-neutral (city-states, trade
      -- posts) stays hostile (diplomacy), but attacking or capturing it is m2-war's army targeting and the M2 AI's
      -- decision, never the scan's finish, harass and best-target paths.
      if enemies[f] == nil then enemies[f] = is_enemy(force, f) and rival(f) end
      local check = enemies[f]
      if check and rec.kind == "wall" and C.cfg.vision ~= "full" then
        walls = walls + 1
        check = walls <= scout.WALL_CHECKS -- a long wall must not make every scan expensive
      end
      -- Phase 5 M2 treasury: an indestructible building (a trade port) is never a target
      if check and rec.entity.destructible and scout.sees(C, force, surface, rec.position) then
        local un = rec.entity.unit_number
        local k = C.known[un]
        if not k then
          k = {position = rec.position, kind = rec.kind, name = rec.entity.name, force = f}
          C.known[un] = k
          C.stats.seen = C.stats.seen + 1
        end
        k.seen = tick
      end
    end
  end
  for un, k in pairs(C.known) do
    local rec = storage.buildings[un]
    if not (rec and rec.entity.valid) and scout.sees(C, force, surface, k.position) then C.known[un] = nil end
  end
  for f, g in pairs(C.guesses) do
    if scout.sees(C, force, surface, g.position) then C.guesses[f] = nil end
  end
  -- enemy units in sight, by kind (counters) and haulers (harass)
  C.seen = C.seen or {}
  C.enemy_haulers = C.enemy_haulers or {}
  local counts, checks = {}, 0
  for un, rec in pairs(storage.units) do
    local f = rec.force
    if f ~= C.force and rec.entity.valid then
      if enemies[f] == nil then enemies[f] = is_enemy(force, f) end
      if enemies[f] then
        local visible = C.cfg.vision == "full"
        if not visible and checks < scout.UNIT_CHECKS then
          checks = checks + 1
          visible = scout.sees(C, force, surface, rec.entity.position)
        end
        if visible then
          counts[rec.kind] = (counts[rec.kind] or 0) + 1
          if rec.kind == "hauler" then C.enemy_haulers[un] = tick end
        end
      end
    end
  end
  for kind, n in pairs(counts) do C.seen[kind] = {n = n, tick = tick} end
  -- the largest enemy army seen in one scan, remembered ENEMY_ARMY_TICKS (army.lua's attack parity)
  local army_n = 0
  for kind, n in pairs(counts) do
    if kind ~= "hauler" and kind ~= "commander" then army_n = army_n + n end
  end
  local best = C.enemy_army
  if army_n > 0 and (not best or army_n >= best.n or tick - best.tick > scout.ENEMY_ARMY_TICKS) then
    C.enemy_army = {n = army_n, tick = tick}
  end
  for un, t in pairs(C.enemy_haulers) do
    if tick - t > scout.HAULER_MEMORY or not (storage.units[un] and storage.units[un].entity.valid) then
      C.enemy_haulers[un] = nil
    end
  end
end

-- Enemy CC positions (known or spawn guesses) of commander C, for "outlying" tests.
local function enemy_bases(C)
  local list = {}
  for _, k in pairs(C.known) do
    if k.kind == "cc" then list[#list + 1] = k.position end
  end
  for _, g in pairs(C.guesses) do list[#list + 1] = g.position end
  local m = storage.match
  for f, pos in pairs(m and m.spawns or {}) do
    if f ~= C.force then list[#list + 1] = pos end
  end
  return list
end

local function near_any(pos, list, r)
  for _, p in ipairs(list) do
    if util.distance(pos, p) < r then return true end
  end
  return false
end

--- Ore patches of the whole arena {cx, cy, name, count, id}, cached per commander for PATCH_CACHE ticks.
scout.PATCH_CACHE = 60 * 60
function scout.patch_list(C, surface)
  local cache = C.patch_cache
  if cache and game.tick - cache.tick < scout.PATCH_CACHE then return cache.list end
  local list = {}
  -- Phase 5 M3 ai (wave B.2, perf; Nation only): the world plan's recorded patches (scripts/mapgen.lua
  -- record_patch), not a scan of the whole arena (25 ms in one tick on a 2048 world, 4-nation bench)
  local mapgen = nation_mode() and loaded("mapgen") or nil
  local recs = mapgen and mapgen.patches and mapgen.patches() or nil
  if recs and #recs > 0 then
    for _, r in ipairs(recs) do
      if r.center and (r.remaining or 1) > 0 then
        list[#list + 1] = {cx = r.center.x, cy = r.center.y, name = r.name, count = r.tiles or 0, id = r.id}
      end
    end
  else
    local half = layout.arena_half()
    for _, p in ipairs(layout.resource_patches(surface, {x = 0, y = 0}, half)) do
      list[#list + 1] = {cx = p.cx, cy = p.cy, name = p.name, count = p.count, id = p.id}
    end
  end
  C.patch_cache = {tick = game.tick, list = list}
  return list
end

scout.HARASS_SAFE = 26 -- extractors and poles this close to an enemy CC or a known turret are not harass targets
--- A raider target for a group at `from` (within `max_dist` when given): {position, kind, entity?}, or nil.
--- Seen enemy haulers first, then known hubs, then outlying extractors, smelters and solar arrays (away from enemy
--- CCs and known turrets), then the poles next to them; with nothing known (and no max_dist) the ore patch
--- nearest to an enemy spawn outside its main, where its expansion would be.
function scout.harass_target(C, surface, from, max_dist)
  local best, best_score
  local function consider(pos, score, kind, entity)
    local d = util.distance(from, pos)
    if max_dist and d > max_dist then return end
    score = score + d
    if not best_score or score < best_score then best, best_score = {position = pos, kind = kind, entity = entity}, score end
  end
  local bases = enemy_bases(C)
  local turrets = {}
  for _, k in pairs(C.known) do
    if k.kind == "turret" or k.kind == "laser-turret" then turrets[#turrets + 1] = k.position end
  end
  -- Phase 5 M3 ai (determinism, m3-perf's audit): ties under the strict < above go to the first one considered, so in
  -- Nation mode the candidates come in unit-number order (Skirmish keeps the tables' order: byte-identical results)
  local function keys_of(t)
    local m = storage.match
    if not (m and m.config and m.config.mode == "nation") then return nil end
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
  end
  local function each(t)
    local ks = keys_of(t)
    if not ks then return pairs(t) end
    local i = 0
    return function()
      i = i + 1
      local k = ks[i]
      if k ~= nil then return k, t[k] end
    end
  end
  for un in each(C.enemy_haulers or {}) do
    local rec = storage.units[un]
    if rec and rec.entity.valid and diplomacy.hostile(C.force, rec.force) -- Phase 5 M2 diplomacy: a peace since
       and not near_any(rec.entity.position, turrets, scout.HARASS_SAFE) then
      consider(rec.entity.position, 0, "hauler", rec.entity)
    end
  end
  for un, k in each(C.known) do
    local rec = storage.buildings[un]
    if rec and rec.entity.valid and diplomacy.hostile(C.force, k.force) -- Phase 5 M2 diplomacy
       and not near_any(k.position, turrets, scout.HARASS_SAFE) then
      if k.kind == "hub" then
        consider(k.position, 15, "hub", rec.entity)
      elseif (k.kind == "extractor" or k.kind == "smelter" or k.kind == "solar")
             and not near_any(k.position, bases, scout.HARASS_SAFE) then
        consider(k.position, 30, k.kind, rec.entity)
      end
    end
  end
  if best then return best end
  -- poles next to known outlying extractors
  for _, k in pairs(C.known) do
    if k.kind == "extractor" and diplomacy.hostile(C.force, k.force) -- Phase 5 M2 diplomacy
       and not near_any(k.position, bases, scout.HARASS_SAFE)
       and not near_any(k.position, turrets, scout.HARASS_SAFE) then
      for _, p in pairs(surface.find_entities_filtered({position = k.position, radius = 8,
                                                         name = "medium-electric-pole", limit = 3})) do
        if diplomacy.hostile(C.force, p.force.name) then -- Phase 5 M2 diplomacy
          consider(p.position, 40, "pole", p)
        end
      end
    end
  end
  if best or max_dist then return best end
  -- nothing known: look where an enemy expansion would be (a patch 45..110 tiles from an enemy spawn, nearest to it)
  local m = storage.match
  for f, pos in pairs(m and m.spawns or {}) do
    if diplomacy.hostile(C.force, f) then -- Phase 5 M2 diplomacy
      for _, p in ipairs(scout.patch_list(C, surface)) do
        local d = util.distance({p.cx, p.cy}, pos)
        if d >= 45 and d <= 110 then consider({x = p.cx, y = p.cy}, d, "patch") end
      end
    end
  end
  return best
end

--- Nearest visible enemy unit to `pos` within `range`, or nil.
function scout.visible_enemy_unit(C, surface, pos, range)
  local force = game.forces[C.force]
  local list = {}
  for _, rec in pairs(storage.units) do
    if rec.force ~= C.force and rec.entity.valid then
      local d = util.distance(rec.entity, pos)
      if d <= range and is_enemy(force, rec.force) then list[#list + 1] = {rec.entity, d} end
    end
  end
  table.sort(list, function(a, b)
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1].unit_number < b[1].unit_number
  end)
  for i = 1, math.min(#list, 8) do
    if scout.sees(C, force, surface, list[i][1].position) then return list[i][1] end
  end
  return nil
end

--- An enemy force that still has buildings but no CC and no barracks (it can no longer produce units), or nil. Its
--- remaining buildings are all targets (the lead's rule: finish a beaten side, so a lone factory or stockpile does
--- not keep it in the match).
function scout.beaten_enemy(C)
  local force = game.forces[C.force]
  if not force then return nil end
  local state = {}
  -- Phase 5 M2 treasury / world: only match forces are rivals here. rts-neutral (city-states, trade posts) has
  -- buildings but no CC or barracks, so it would count as a beaten side and every AI would rush it.
  local players = {}
  for _, f in ipairs(storage.match and storage.match.forces or {}) do players[f] = true end
  for _, rec in buildings.all() do
    local f = rec.force
    if f ~= C.force and (players[f] or not storage.match) then
      local st = state[f]
      if not st then
        st = {enemy = is_enemy(force, f), alive = false, any = false}
        state[f] = st
      end
      st.any = true
      if rec.kind == "cc" or rec.kind == "barracks" then st.alive = true end
    end
  end
  local names = {}
  for f, st in pairs(state) do
    if st.enemy and st.any and not st.alive then names[#names + 1] = f end
  end
  table.sort(names)
  return names[1]
end

--- Best attack target for a group at `from`: the known enemy building with the lowest distance + priority penalty
--- (orders_data.TARGET_PENALTY: barracks/factory first), else the nearest visible enemy unit, else a spawn guess.
--- Against a beaten enemy (scout.beaten_enemy) the target is its nearest factory, else stockpile, else building,
--- known or not.
--- Returns {position, kind, un?} or nil.
scout.FINISH_ORDER = {"factory", "hub", "stockpile"} -- a factory keeps a side in the match (buildings.is_alive_force)
-- Phase 5 M3 ai (wave B.2, perf; Nation only): the scan over every known enemy building runs at most every
-- scout.TARGET_CACHE ticks per commander; in between the last result stands while its building still stands
-- (army.step asked every run while a group attacked: up to 3.8 ms in a 4-nation bench)
scout.TARGET_CACHE = 300
local scan_target

function scout.best_target(C, surface, from)
  if not nation_mode() then return scan_target(C, surface, from) end
  local fx, fy = from.x or from[1], from.y or from[2]
  local T = C.target_cache
  if T and game.tick - T.tick < scout.TARGET_CACHE and math.abs(T.from.x - fx) < 1 and math.abs(T.from.y - fy) < 1 then
    local r = T.result
    if r == nil then return nil end
    -- (a unit target is scanned again: it moves)
    if r.kind == "spawn" or (r.kind ~= "unit" and r.un and buildings.get(r.un) ~= nil) then
      return {position = r.position, kind = r.kind, un = r.un, force = r.force, finishing = r.finishing}
    end
  end
  local r = scan_target(C, surface, from)
  C.target_cache = {tick = game.tick, from = {x = fx, y = fy}, result = r}
  return r
end

scan_target = function(C, surface, from)
  local best, best_score
  local penalty = C.cfg.target_penalty or data.TARGET_PENALTY
  local beaten = scout.beaten_enemy(C)
  if beaten then
    -- finishing: the nearest factory of the beaten side, else its nearest stockpile, else its nearest building
    for pass = 1, #scout.FINISH_ORDER + 1 do
      local kind = scout.FINISH_ORDER[pass]
      for un, rec in buildings.for_force(beaten, kind) do
        local d = util.distance(from, rec.position)
        if not best_score or d < best_score then
          best, best_score = {position = rec.position, kind = rec.kind, un = un, finishing = true, force = beaten}, d
        end
      end
      if best then return best end
    end
  end
  -- Phase 5 M2 diplomacy: known buildings and spawn guesses of nations at peace are no targets; a target names its force
  -- (ai/army.lua re-targets a group whose target's nation made peace)
  for un, k in pairs(C.known) do
    if diplomacy.hostile(C.force, k.force) then
      local score = util.distance(from, k.position) + (penalty[k.kind] or 50)
      if not best_score or score < best_score then
        best, best_score = {position = k.position, kind = k.kind, un = un, force = k.force}, score
      end
    end
  end
  if best then return best end
  local u = scout.visible_enemy_unit(C, surface, from, 200)
  if u then return {position = u.position, kind = "unit", un = u.unit_number, force = u.force.name} end
  for f, g in pairs(C.guesses) do
    if diplomacy.hostile(C.force, f) then
      local score = util.distance(from, g.position)
      if not best_score or score < best_score then
        best, best_score = {position = g.position, kind = "spawn", force = f}, score
      end
    end
  end
  return best
end

--- Number of visible chunks of the force within the arena (for the dump and the autotest).
function scout.visible_chunks(C, surface, half)
  local force = game.forces[C.force]
  if not force then return 0 end
  local n, c = 0, math.ceil(half / 32)
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      if force.is_chunk_visible(surface, {cx, cy}) then n = n + 1 end
    end
  end
  return n
end

--- Known enemy buildings by kind: {[kind] = n}.
function scout.known_by_kind(C)
  local out = {}
  for _, k in pairs(C.known) do out[k.kind] = (out[k.kind] or 0) + 1 end
  return out
end

return scout
