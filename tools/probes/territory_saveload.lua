-- Territory save/load check (Phase 5 M1). Test copy only, with tools/saveload-check.sh:
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/territory_saveload.lua tools/saveload-check.sh <name> \
--     '{opponents = 1, difficulty = "normal", size = "large", enemy_brain = "ai", mode = "nation"}'
-- Every 10 s of a Nation match it logs the grid checksum, the border object count (and how many are valid), the cities
-- and the queued jobs; after a load it logs the same once on the first tick ("after load"). The last line before the
-- server quit and the "after load" line must agree (the save happens on quit, between them nothing runs).
local events = require("scripts.events")
local util = require("scripts.util")
local territory = require("scripts.territory")

local cities = require("scripts.cities")
local match = require("scripts.match")

local loaded = false -- module-local, logging only

-- Richer state for the save: 5 s into the match the player gets a second city 150 tiles out, a fort and a hub.
events.on_nth_tick(60, function()
  local m = storage.match
  if storage.territory_saveload_setup or not (m and m.phase == "running" and m.tick_started) then return end
  if game.tick - m.tick_started < 300 or not territory.nation() then return end
  storage.territory_saveload_setup = true
  local F = "rts-player"
  local cap = cities.get(storage.nations[F].capital)
  local surface = match.surface()
  local site = surface.find_non_colliding_position("rts-city-center", {cap.position.x + 150, cap.position.y + 40}, 20, 1,
    true)
  local id = site and cities.found(F, site)
  local fort = surface.find_non_colliding_position("rts-fort", {cap.position.x + 40, cap.position.y - 85}, 10, 1, true)
  local hub = surface.find_non_colliding_position("rts-hub", {cap.position.x - 10, cap.position.y + 88}, 10, 1, true)
  local e1 = fort and surface.create_entity({name = "rts-fort", position = fort, force = F, raise_built = true})
  local e2 = hub and surface.create_entity({name = "rts-hub", position = hub, force = F, raise_built = true})
  util.log("territory save check setup: city %s, fort %s, hub %s", tostring(id), tostring(e1 ~= nil), tostring(e2 ~= nil))
end)

local function line(tag)
  local T = storage.territory
  if not (T and T.active) then return end
  local n, valid = territory.object_count()
  local ids = {}
  for id, c in pairs(storage.cities or {}) do ids[#ids + 1] = string.format("%d:%s:t%d", id, c.force, c.tier) end
  table.sort(ids)
  util.log("territory save check %s tick %d: checksum %d objects %d valid %d jobs %d sources %d cities [%s] cells %s",
    tag, game.tick, territory.checksum(), n, valid, #T.jobs, table_size(T.sources), table.concat(ids, " "),
    serpent.line(T.counts))
end

events.on_load(function() loaded = true end)

events.on_nth_tick(600, function() line("periodic") end)
events.on_signal(territory.SIGNAL, function() line("change") end)

events.on(defines.events.on_tick, function()
  if loaded then
    loaded = false
    line("after load")
  end
end)
