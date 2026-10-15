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
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local units = require("scripts.units")
local data = require("scripts.ai.orders_data")

local scout = {}

scout.PERIOD = 300 -- ticks between scans
scout.SIGHT = 30   -- tiles; the units' vision_distance (prototypes/units.lua)

local function chunk_of(pos)
  local x, y = util.xy(pos)
  return {math.floor(x / 32), math.floor(y / 32)}
end

--- True when commander C sees `pos` now.
function scout.sees(C, force, surface, pos)
  if C.cfg.vision == "full" then return true end
  if force.is_chunk_visible(surface, chunk_of(pos)) then return true end
  return surface.count_entities_filtered({position = pos, radius = scout.SIGHT, force = force, limit = 1}) > 0
end

local function is_enemy(force, other_name)
  local other = game.forces[other_name]
  return other ~= nil and force.is_enemy(other)
end

--- Seed the spawn guesses (once per commander).
function scout.seed(C)
  C.guesses = C.guesses or {}
  local m = storage.match
  for force_name, pos in pairs(m and m.spawns or {}) do
    if force_name ~= C.force then C.guesses[force_name] = {position = {x = pos.x, y = pos.y}} end
  end
end

--- Scan: add seen enemy buildings, forget the ones seen to be gone, drop seen guesses.
function scout.step(C, surface)
  local force = game.forces[C.force]
  if not force then return end
  local tick = game.tick
  local enemies = {}
  for _, rec in buildings.all() do
    local f = rec.force
    if f ~= C.force and rec.surface == surface.index then
      if enemies[f] == nil then enemies[f] = is_enemy(force, f) end
      if enemies[f] and scout.sees(C, force, surface, rec.position) then
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
  for _, rec in buildings.all() do
    local f = rec.force
    if f ~= C.force then
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
scout.FINISH_ORDER = {"factory", "stockpile"} -- a factory keeps a side in the match (buildings.is_alive_force)
function scout.best_target(C, surface, from)
  local best, best_score
  local penalty = data.TARGET_PENALTY
  local beaten = scout.beaten_enemy(C)
  if beaten then
    -- finishing: the nearest factory of the beaten side, else its nearest stockpile, else its nearest building
    for pass = 1, #scout.FINISH_ORDER + 1 do
      local kind = scout.FINISH_ORDER[pass]
      for un, rec in buildings.for_force(beaten, kind) do
        local d = util.distance(from, rec.position)
        if not best_score or d < best_score then
          best, best_score = {position = rec.position, kind = rec.kind, un = un, finishing = true}, d
        end
      end
      if best then return best end
    end
  end
  for un, k in pairs(C.known) do
    local score = util.distance(from, k.position) + (penalty[k.kind] or 50)
    if not best_score or score < best_score then
      best, best_score = {position = k.position, kind = k.kind, un = un}, score
    end
  end
  if best then return best end
  local u = scout.visible_enemy_unit(C, surface, from, 200)
  if u then return {position = u.position, kind = "unit", un = u.unit_number} end
  for _, g in pairs(C.guesses) do
    local score = util.distance(from, g.position)
    if not best_score or score < best_score then
      best, best_score = {position = g.position, kind = "spawn"}, score
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
