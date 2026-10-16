-- Test copy only (tools/autotest-run.sh EXTRA_LUA): a 2048x2048-tile territory grid (256x256 cells) on whatever
-- arena the match has, to measure the territory handlers at world size before scripts/world.lua exists. Every job-queue
-- tick logs its time ("[rts] territory: step ...").
local territory = require("scripts.territory")
territory.SIZE_OVERRIDE = 2048
territory.PROFILE_STEPS = true
