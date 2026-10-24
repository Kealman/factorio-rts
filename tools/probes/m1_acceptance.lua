-- M1 end-to-end acceptance helper (docs/qa/phase5-m1-integration-notes.md). Test-only module for tools/autotest-run.sh
-- (EXTRA_LUA): the AI autotest runs the match at the copy's SPEED, and FINAL_MINUTES before its end this switches the
-- game to speed 1, so the "ai perf minute N ... wall clock" lines of the last minutes measure UPS at speed 1
-- (60 s of wall clock per game minute = 60 UPS). Log: "[rts] m1 acceptance: game speed 1 from minute N".
local events = require("scripts.events")
local util = require("scripts.util")
local autotest = require("scripts.ai.autotest")
-- Factorio 2.1 re-baseline (QA fix round): Industrialisation finishes ~16 s later on the 2.1 engine (rts-ai-1 Age II at
-- 20:16 on every 2.1 tree, 2.0: before 20:00); the M1 acceptance's Age II deadline is 20:30
autotest.AGE_DEADLINE = (20 * 60 + 30) * 60

local FINAL_MINUTES = 5

events.on_nth_tick(60, function(e)
  local s = storage.ai_autotest
  if not s or s.done or storage.m1_final_speed then return end
  local age = e.tick - s.started
  if age >= autotest.DURATION - FINAL_MINUTES * autotest.MINUTE then
    storage.m1_final_speed = true
    util.log("m1 acceptance: game speed %s -> 1 from minute %d (tick %d)", tostring(game.speed),
      math.floor(age / autotest.MINUTE), e.tick)
    game.speed = 1
  end
end)
