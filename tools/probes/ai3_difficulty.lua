-- Phase 5 M3 ai: difficulty without cheats (docs/PHASE5-M3.md D7 and section 4 "Difficulty"). Test-only module for
-- tools/autotest-run.sh (EXTRA_LUA) on a 1v1 Nation match at 2048: both nations economic; the match config's
-- `difficulty` is rts-ai-1's, rts-player's commander gets the other one of hard / normal, so a seed series alternates
-- which side is hard:
--   EXTRA_LUA=tools/probes/ai3_difficulty.lua DURATION_MIN=60 SEED=901 SPEED=10 tools/autotest-run.sh ai3dif-901 \
--     '{opponents = 1, difficulty = "hard", mode = "nation", world_size = 2048, enemy_brain = "ai"}' 4000
-- At the end of the autotest (its summary) the D6 score of both nations (wars.nation_score: population + treasury / 10
-- + land cells + army supply) is logged:
--   [rts] ai3 difficulty: hard rts-ai-1 <score> (pop, treasury, land, supply) | normal rts-player <score> (...) | winner
--   hard|normal (by <n>)
local events = require("scripts.events")
local util = require("scripts.util")
local autotest = require("scripts.ai.autotest")

autotest.DOCTRINES = {["rts-player"] = "economic", ["rts-ai-1"] = "economic"}

local start = autotest.start
autotest.start = function(...)
  local cfg = storage.match and storage.match.config or {}
  autotest.PLAYER_DIFFICULTY = (cfg.enemy_difficulty == "hard") and "normal" or "hard"
  return start(...)
end

local summary = autotest.ai3_summary
autotest.ai3_summary = function(s, ...)
  local wars = package.loaded["__" .. script.mod_name .. "__/scripts/wars.lua"] or package.loaded["scripts.wars"]
  local out, by = {}, {}
  for _, f in ipairs({"rts-player", "rts-ai-1"}) do
    local C = storage.ai and storage.ai[f]
    local score, parts = 0, {pop = 0, treasury = 0, land = 0, supply = 0}
    if wars and wars.nation_score then score, parts = wars.nation_score(f) end
    local level = C and C.difficulty or "?"
    by[level] = score
    out[#out + 1] = string.format("%s %s %d (pop %.0f, treasury %.0f, land %d, supply %d)", level, f, score,
      parts.pop or 0, parts.treasury or 0, parts.land or 0, parts.supply or 0)
  end
  local h, n = by.hard or 0, by.normal or 0
  util.log("ai3 difficulty: %s | winner %s (by %d)", table.concat(out, " | "), h > n and "hard" or (n > h and "normal"
    or "tie"), math.abs(h - n))
  return summary(s, ...)
end
