-- Phase 5 M3 perf: test copy only (tools/perf-bench.sh EXTRA_LUA): Nation AI runs unsliced (the Phase 4 stagger), the
-- rail survey still on the scheduler, so the M3 tree plays the base game up to its first survey and the survey's own
-- duration can be compared with the base's (docs/qa/phase5-perf-notes.md, the 473-tile survey of seed 701).
local ai = require("scripts.ai.init")
ai.NATION_SLICES = false
return {}
