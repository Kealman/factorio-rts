-- Phase 5 M2 war elimination probe (test copy only, tools/autotest-run.sh EXTRA_LUA; docs/PHASE5-M2.md D4 "a nation with
-- no city left is eliminated"). In a 1v1 Nation-mode AI match, at minute 2 every city of rts-ai-1 (its capital only at
-- that point) goes to rts-player: by a treaty that cedes them (scripts/wars.lua: a war declared if none runs, then
-- wars.end_war with {kind = "cede"}, whose on_cede hook is capture.flip) when m2-diplomacy is there, else by
-- capture.flip directly. rts-ai-1 has no city left, so its remaining units and producers die and match.lua's out check
-- ends the match for rts-player. Also checks that rts-player's main Command Center stays
-- its own (buildings.main_cc prefers it to the captured one). Log: "[rts] war eliminate: ..." and
-- "[rts] war eliminate summary PASS|FAIL".
local events = require("scripts.events")
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local cities = require("scripts.cities")
local capture = require("scripts.capture")

local LOSER, WINNER = "rts-ai-1", "rts-player"

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.tick_started) then return end
  local S = storage.war_elim
  if not S then
    if m.phase ~= "running" or e.tick - m.tick_started < 2 * 3600 then return end
    S = {cc = buildings.main_cc(WINNER) and buildings.main_cc(WINNER).entity.unit_number}
    storage.war_elim = S
    local list = cities.for_force(LOSER)
    local wars = package.loaded["__" .. script.mod_name .. "__/scripts/wars.lua"]
    if wars and wars.end_war then
      local W = wars.between(WINNER, LOSER)
      local id = W and W.id
      if not id then id = wars.declare(WINNER, LOSER, {kind = "conquest", cities = {list[1] and list[1].id}}) end
      local ids = {}
      for _, c in ipairs(list) do ids[#ids + 1] = c.id end
      local ok = id and wars.end_war(id, {kind = "cede", city_ids = ids, to = WINNER, from = LOSER})
      S.treaty = true
      util.log("war eliminate: war %s ended with a treaty ceding %d cities of %s to %s: %s", tostring(id), #ids, LOSER,
        WINNER, tostring(ok))
    else
      for _, c in ipairs(list) do
        local job = capture.flip(c.id, WINNER, "war eliminate probe")
        util.log("war eliminate: city %d of %s -> %s, job %s", c.id, LOSER, WINNER, tostring(job))
      end
    end
    S.flipped, S.t = #list, e.tick
    return
  end
  if S.done then return end
  if m.phase == "ended" or e.tick - S.t > 60 * 60 then
    S.done = true
    local cc, un = buildings.main_cc(WINNER)
    local n_cc = buildings.count(WINNER, "cc")
    local ok = m.phase == "ended" and (m.winner == WINNER or (type(m.winner) == "table" and m.winner[1] == WINNER))
      and un == S.cc and n_cc == 2 and #cities.for_force(LOSER) == 0
      and (storage.capture and storage.capture.stats.captures or 0) >= S.flipped
    util.log("war eliminate: %d cities flipped%s; match phase %s, winner %s, %s out at %s; %s main CC #%s (own #%s), %d "
      .. "Command Centers", S.flipped, S.treaty and " by a treaty" or "", m.phase, serpent.line(m.winner), LOSER,
      tostring(m.out[LOSER]), WINNER, tostring(un), tostring(S.cc), n_cc)
    util.log("war eliminate summary %s", ok and "PASS" or "FAIL")
  end
end)
