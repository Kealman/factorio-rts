-- Fog of war (docs/PHASE3.md "Match flow"): every RTS force charts only what it sees; uncharted is black.
--
-- Measured on 2.0.77 (GUI probe, docs/qa/phase3-matchflow-notes.md): LuaForce.chart(surface, area) makes the
-- chunks charted and visible for about 600 ticks; spider units with radar_range = 1 (prototypes/units.lua) keep
-- the 3x3 chunks around them charted and visible by themselves. Buildings have no radar, so this module re-charts
-- the chunks around the force's own buildings (and, as a margin, its units) every PERIOD ticks: own bases stay
-- live, everything else falls back to the last chart (the remote view shows the chart there, not entities).
-- Charts are not shared (share_chart = false on every RTS force, set by match.lua; forces are not friends).
--
-- Only forces that people look at are charted by script: rts-player, plus any force that has players. AI forces
-- need no chart: their scouting is sight-based (ai/scout.lua), and hard AI sees the whole map by itself.
-- At the end of a match the whole arena is charted for the human forces, so the players can look around.
--
-- Owns storage.fog = {last = {[force] = {chunks, units, buildings, tick}}, next_stats = tick}.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local match = require("scripts.match")

local fog = {}

fog.PERIOD = 300            -- ticks between re-charts (a chart stays visible ~600 ticks)
fog.START_RADIUS = 64       -- tiles charted around each CC at match start
fog.BUILDING_RADIUS = 40    -- tiles around each own building
fog.UNIT_RADIUS = 24        -- tiles around each own unit (radar_range already covers 3x3 chunks)
fog.STATS_PERIOD = 60 * 60  -- a "fog:" stats line per minute

function fog.init()
  storage.fog = storage.fog or {last = {}}
end

--- Forces whose chart is kept by this module: rts-player and every match force that has players.
function fog.charted_forces()
  local out = {util.PLAYER_FORCE}
  for _, f in ipairs(match.forces()) do
    if f ~= util.PLAYER_FORCE then
      local force = game.forces[f]
      if force and #force.players > 0 then out[#out + 1] = f end
    end
  end
  return out
end

local function chunk_range(v, r, half)
  local lo = math.floor((math.max(v - r, -half)) / 32)
  local hi = math.floor((math.min(v + r, half - 1)) / 32)
  return lo, hi
end

local function add_square(set, pos, r, half)
  local x, y = util.xy(pos)
  local x0, x1 = chunk_range(x, r, half)
  local y0, y1 = chunk_range(y, r, half)
  for cx = x0, x1 do
    for cy = y0, y1 do set[cx * 4096 + cy] = true end
  end
end

-- Chart a set of chunk keys (inset by one tile, so a chunk-sized box does not touch the neighbours).
local function chart_set(force, surface, set)
  local n = 0
  for key in pairs(set) do
    local cx = math.floor((key + 2048) / 4096)
    local cy = key - cx * 4096
    force.chart(surface, {{cx * 32 + 1, cy * 32 + 1}, {cx * 32 + 31, cy * 32 + 31}})
    n = n + 1
  end
  return n
end

--- Re-chart what one force sees now: squares around its units and buildings on the arena. Returns the counts.
function fog.update_force(force_name)
  local surface = match.surface()
  local force = game.forces[force_name]
  if not (surface and force) then return 0, 0, 0 end
  local half = match.arena_half()
  local set, nu, nb = {}, 0, 0
  for _, rec in units.for_force(force_name) do
    if rec.entity.surface.index == surface.index then
      add_square(set, rec.entity.position, fog.UNIT_RADIUS, half)
      nu = nu + 1
    end
  end
  for _, rec in buildings.for_force(force_name) do
    if rec.surface == surface.index then
      add_square(set, rec.position, fog.BUILDING_RADIUS, half)
      nb = nb + 1
    end
  end
  local n = chart_set(force, surface, set)
  storage.fog.last[force_name] = {chunks = n, units = nu, buildings = nb, tick = game.tick}
  return n, nu, nb
end

--- Match start: no shared charts, and the area around every force's CC is charted for the charted forces.
function fog.start()
  local surface = match.surface()
  if not surface then return end
  for _, f in ipairs(match.forces()) do
    local force = game.forces[f]
    if force then force.share_chart = false end
  end
  local parts = {}
  for _, f in ipairs(fog.charted_forces()) do
    local force = game.forces[f]
    local set = {}
    add_square(set, match.home(f), fog.START_RADIUS, match.arena_half())
    parts[#parts + 1] = string.format("%s %d chunks around %s", f, chart_set(force, surface, set),
      util.pos_str(match.home(f)))
  end
  storage.fog.next_stats = game.tick + fog.STATS_PERIOD
  util.log("fog: match start on %s, charted %s; arena %d chunks, nothing shared", surface.name,
    table.concat(parts, ", "), (2 * match.arena_half() / 32) ^ 2)
end

--- Number of charted and of visible chunks of a force inside the arena.
function fog.counts(force_name)
  local surface = match.surface()
  local force = game.forces[force_name]
  if not (surface and force) then return 0, 0, 0 end
  local c = match.arena_half() / 32
  local charted, visible, total = 0, 0, 0
  for cx = -c, c - 1 do
    for cy = -c, c - 1 do
      total = total + 1
      if force.is_chunk_charted(surface, {cx, cy}) then charted = charted + 1 end
      if force.is_chunk_visible(surface, {cx, cy}) then visible = visible + 1 end
    end
  end
  return charted, visible, total
end

local function stats_line()
  local parts = {}
  for _, f in ipairs(match.forces()) do
    local charted, visible, total = fog.counts(f)
    local last = storage.fog.last[f]
    parts[#parts + 1] = string.format("%s charted %d visible %d of %d%s", f, charted, visible, total,
      last and string.format(" (last re-chart %d chunks for %d units, %d buildings)", last.chunks, last.units,
      last.buildings) or "")
  end
  util.log("fog: t=%.0fs %s", match.elapsed_seconds(), table.concat(parts, " | "))
end
fog.stats_line = stats_line

events.on_nth_tick(fog.PERIOD, function()
  local m = storage.match
  if not (m and m.surface and m.phase == "running") then return end
  for _, f in ipairs(fog.charted_forces()) do fog.update_force(f) end
  local st = storage.fog
  if st.next_stats and game.tick >= st.next_stats then
    st.next_stats = game.tick + fog.STATS_PERIOD
    stats_line()
  end
end)

-- The match is over: reveal the whole arena to the human forces.
match.on_ended(function(m)
  local surface = match.surface()
  if not surface then return end
  local h = match.arena_half()
  for _, f in ipairs(fog.charted_forces()) do
    game.forces[f].chart(surface, {{-h, -h}, {h, h}})
  end
  util.log("fog: match over, arena charted for %s", table.concat(fog.charted_forces(), ", "))
end)

return fog
