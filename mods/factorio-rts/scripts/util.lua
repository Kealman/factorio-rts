-- Shared helpers: logging, per-player storage, position math, force names.
local util = {}

util.PLAYER_FORCE = "rts-player"
-- Phase 3: AI opponents are rts-ai-1 .. rts-ai-3 (match.lua); the first one is the "enemy" of 1v1 code paths.
util.ENEMY_FORCE = "rts-ai-1"
util.LOBBY_SURFACE = "rts-lobby"
util.CURSOR_ITEM = "rts-cursor"

--- log() with the "[rts]" prefix. Arguments are passed to string.format when present.
function util.log(fmt, ...)
  if select("#", ...) > 0 then fmt = string.format(fmt, ...) end
  log("[rts] " .. fmt)
end

--- storage.players[player_index], created on first use. Each module owns its own fields (docs/PHASE1.md).
function util.pstorage(player_index)
  local players = storage.players
  if not players then
    players = {}
    storage.players = players
  end
  local p = players[player_index]
  if not p then
    p = {}
    players[player_index] = p
  end
  return p
end

--- The surface the RTS match is played on: the current match arena (storage.match.surface, created per match by
--- match.lua), else the lobby surface, else nauvis (only before match.init ran).
function util.surface()
  local m = storage.match
  local name = m and m.surface
  return (name and game.surfaces[name]) or game.surfaces[util.LOBBY_SURFACE] or game.surfaces.nauvis
    or game.surfaces[1]
end

--- Name of a defines value, for logs: util.define_name(defines.controllers, player.controller_type).
function util.define_name(tbl, value)
  for k, v in pairs(tbl) do
    if v == value then return k end
  end
  return tostring(value)
end

local function xy(p)
  if p.position then p = p.position end -- entities and anything else with a position
  return p.x or p[1], p.y or p[2]
end
util.xy = xy

function util.pos_str(p)
  if not p then return "nil" end
  local x, y = xy(p)
  return string.format("(%.1f, %.1f)", x, y)
end

function util.distance_sq(a, b)
  local ax, ay = xy(a)
  local bx, by = xy(b)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

function util.distance(a, b)
  return math.sqrt(util.distance_sq(a, b))
end

--- Average position of a list of positions or entities (invalid entities are skipped). nil when empty.
function util.centroid(list)
  local sx, sy, n = 0, 0, 0
  for _, item in pairs(list) do
    if item.valid ~= false then
      local x, y = xy(item)
      sx, sy, n = sx + x, sy + y, n + 1
    end
  end
  if n == 0 then return nil end
  return {x = sx / n, y = sy / n}
end

--- True if the entity is a live unit registered by units.lua.
function util.is_rts_unit(entity)
  if not (entity and entity.valid) then return false end
  local un = entity.unit_number
  return un ~= nil and storage.units ~= nil and storage.units[un] ~= nil
end

return util
