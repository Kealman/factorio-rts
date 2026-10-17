-- Phase 5 M3 air: Skirmish gets no plane and no AA turret (test copy only, tools/autotest-run.sh EXTRA_LUA beside a
-- Skirmish AI match; docs/qa/phase5-air-notes.md). Only reads state. Every 60 s for 3 minutes, for every match force:
-- Aviation and Air Force are disabled and unresearched, the plane kit, airfield and AA turret recipes are disabled, no
-- plane, airfield or AA turret exists, storage.air holds no plane. Log lines "[rts] air skirmish check ...".
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local balance = require("balance")

local A = balance.nation.air
local NAMES = {"rts-scout-plane", "rts-bomber", "rts-interceptor", "rts-airfield", "rts-aa-turret"}
local RECIPES = {"rts-scout-plane-kit", "rts-bomber-kit", "rts-interceptor-kit", "rts-airfield", "rts-aa-turret"}

events.on_nth_tick(3600, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = storage.air_skirmish or {n = 0, pass = 0, fail = 0}
  storage.air_skirmish = s
  if s.n >= 3 then return end
  s.n = s.n + 1
  local bad = {}
  for _, f in ipairs(match.forces()) do
    local force = game.forces[f]
    for _, t in ipairs(A.techs) do
      local tech = force.technologies[t.name]
      if tech and (tech.enabled or tech.researched) then bad[#bad + 1] = f .. " tech " .. t.name end
    end
    for _, r in ipairs(RECIPES) do
      if force.recipes[r] and force.recipes[r].enabled then bad[#bad + 1] = f .. " recipe " .. r end
    end
  end
  local surface = game.surfaces[m.surface]
  local n = surface and surface.count_entities_filtered({name = NAMES}) or 0
  if n > 0 then bad[#bad + 1] = n .. " planes / airfields / AA turrets on the map" end
  local planes = storage.air and storage.air.planes and table_size(storage.air.planes) or 0
  if planes > 0 then bad[#bad + 1] = planes .. " plane records" end
  local ok = #bad == 0
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("air skirmish check minute %d: %s (mode %s, forces %s)%s", s.n, ok and "PASS" or "FAIL",
    tostring(m.config.mode), table.concat(match.forces(), " "), ok and "" or (": " .. table.concat(bad, "; ")))
  if s.n == 3 then util.log("air skirmish summary %d/%d", s.pass, s.pass + s.fail) end
end)
