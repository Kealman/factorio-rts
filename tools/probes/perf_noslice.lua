-- Phase 5 M3 perf: test copy only (tools/perf-bench.sh EXTRA_LUA): Nation AI runs unsliced and with the Phase 4 stagger,
-- and rail surveys on the old per-tick driver, as before M3, so a run of the M3 tree plays the same game as the tree
-- before it (exactness checks of the M3 hunks).
local ai = require("scripts.ai.init")
ai.NATION_SLICES = false
local ok, rails = pcall(require, "scripts.rails")
if ok and type(rails) == "table" then rails.SURVEY_SCHED = false end -- surveys on the M2 per-tick driver
return {}
