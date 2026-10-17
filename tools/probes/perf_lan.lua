-- Phase 5 M3 perf: multiplayer and save/load state checksums (test copy only: tools/lan-check.sh, tools/heavy-mode.sh,
-- tools/determinism-compare.sh SAVELOAD_AT). Every peer runs it, so the server and each GUI client log the same lines
-- while they are in sync:
--   [rts] lan check t36000: players 2 [rts-lan-1, rts-lan-2], units 412 sum 1234567, cities 18, buildings 3301 sum 7654,
--         jobs 3, state 123456789
-- once every CHECK_TICKS. The sums are integer and order-independent (positions in 1/256 tiles, mod 2^31), so a peer that
-- loaded a save, whose pairs() order may differ, still computes the same numbers; a mismatch between two logs at the
-- same tick is a desync the engine may not have reported yet. Config: scripts/perf_lan_cfg.lua = {period = ticks,
-- save_at = tick, speed = n}: the server saves "perf-lan-<tick>" at that tick (game.server_save) for a save/load
-- comparison (tools/heavy-mode.sh SAVELOAD=1); speed is the game speed of a new save.
local events = require("scripts.events")
local util = require("scripts.util")

local ok_cfg, CFG = pcall(require, "scripts.perf_lan_cfg")
CFG = ok_cfg and type(CFG) == "table" and CFG or {}
local CHECK_TICKS = CFG.period or 3600
local MOD = 2147483648
if CFG.speed then events.on_init(function() game.speed = CFG.speed end) end

local function psum(acc, p)
  local x, y = math.floor(p.x * 256 + 0.5), math.floor(p.y * 256 + 0.5)
  return (acc + (x * 3 + y * 7) % MOD) % MOD
end

local function check(tick)
  local nunits, usum = 0, 0
  for _, rec in pairs(storage.units or {}) do
    local e = rec.entity
    if e and e.valid then
      nunits = nunits + 1
      usum = psum(usum, e.position)
      usum = (usum + math.floor((e.health or 0) * 16)) % MOD
    end
  end
  local nbuild, bsum = 0, 0
  for _, rec in pairs(storage.buildings or {}) do
    local e = rec.entity
    if e and e.valid then
      nbuild = nbuild + 1
      bsum = psum(bsum, e.position)
    end
  end
  local ncities = 0
  for _ in pairs(storage.cities or {}) do ncities = ncities + 1 end
  local jobs = storage.sched and storage.sched.live or 0
  local players = {}
  for _, p in pairs(game.connected_players) do players[#players + 1] = p.name end
  table.sort(players)
  local state = (usum * 31 + bsum * 17 + nunits * 7 + nbuild * 5 + ncities * 3 + jobs) % MOD
  -- the player list differs only in who is connected; everything else must match on every peer
  util.log("lan check t%d: players %d [%s], units %d sum %d, cities %d, buildings %d sum %d, jobs %d, state %d", tick,
    #players, table.concat(players, ", "), nunits, usum, ncities, nbuild, bsum, jobs, state)
end

events.on_nth_tick(CHECK_TICKS, function(e)
  if e.tick > 0 then check(e.tick) end
end)

-- (save_at must be a multiple of 60)
events.on_nth_tick(60, function(e)
  if CFG.save_at and e.tick == CFG.save_at then
    util.log("lan check: saving perf-lan-%d at tick %d", e.tick, e.tick)
    game.server_save("perf-lan-" .. e.tick)
  end
end)

events.on(defines.events.on_player_joined_game, function(e)
  local p = game.get_player(e.player_index)
  util.log("lan check: player %s joined at tick %d", p and p.name or "?", e.tick)
end)

return {}
