-- Phase 5 M2 diplomacy smoke (test-only, tools/autotest-run.sh EXTRA_LUA). At 20 s of the match: Skirmish: every pair of
-- match forces is hostile and at "war" (the engine agrees), no rts-neutral force; Nation: every pair at peace, rts-neutral
-- at war with all. Log "[rts] dprobe check ...", marker "dprobe done".
local events = require("scripts.events")
local util = require("scripts.util")
local diplomacy = require("scripts.diplomacy")

events.on_nth_tick(60, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) or storage.dsmoke_done then return end
  if e.tick - m.tick_started < 20 * 60 then return end
  storage.dsmoke_done = true
  local nation = m.config.mode == "nation"
  local ok, parts = true, {}
  for _, a in ipairs(m.forces) do
    for _, b in ipairs(m.forces) do
      if a ~= b then
        local st, h, en = diplomacy.state(a, b), diplomacy.hostile(a, b), game.forces[a].is_enemy(game.forces[b])
        if nation then
          if st ~= "peace" or h or en then ok = false end
        elseif st ~= "war" or not h or not en then
          ok = false
        end
        parts[#parts + 1] = string.format("%s/%s %s %s %s", a, b, st, tostring(h), tostring(en))
      end
    end
  end
  util.log("dprobe check %s: %s %s", nation and "nation_start_peace" or "skirmish_all_hostile", ok and "PASS" or "FAIL",
    table.concat(parts, "; "))
  local n = game.forces["rts-neutral"]
  util.log("dprobe check neutral_force: %s rts-neutral %s in a %s match", ((n ~= nil) == nation) and "PASS" or "FAIL",
    n and "exists" or "does not exist", m.config.mode)
  log("[rts] dprobe done")
end)
