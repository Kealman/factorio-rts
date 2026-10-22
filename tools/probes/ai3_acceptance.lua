-- Phase 5 M3 ai acceptance helper (docs/PHASE5-M3.md section 4 "AI (wave B)"; docs/qa/phase5-ai3-notes.md). Test-only
-- module for tools/autotest-run.sh (EXTRA_LUA) on a 4-nation Nation match of normal AIs:
--   PERF=1 EXTRA_LUA=tools/probes/ai3_acceptance.lua DURATION_MIN=60 SEED=801 SPEED=10 \
--     tools/autotest-run.sh ai3acc-801 '{opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048,
--     enemy_brain = "ai"}' 9000
-- It turns on the autotest's M3 AI checks (scripts/ai/autotest.lua autotest.AI3_CHECKS): per nation three cities
-- linked by open rail lines by 35:00 and at least one operation with phases; air patrols and a built fort belt in the
-- match. The per-seed metrics (Age III time, wars, peaces, captures) are in the "ai autotest ai3 summary" and
-- "ai autotest m2ai summary" lines; the AI cost per tick in the PERF lines ("ai perf minute N parts").
local autotest = require("scripts.ai.autotest")
autotest.AI3_CHECKS = true
