-- Phase 5 M3 ai (docs/PHASE5-M3.md D7, §3 "ai/difficulty.lua"; study docs/research/scale/war-ai-performance.md §4.7):
-- difficulty without cheats in Nation mode. Every level sees honestly (ai/intel.lua, ai/scout.lua sight rules) and pays
-- what a player pays; the levels differ in skill only, read from balance.nation.ai3.difficulty[level]:
--
--   difficulty.of_level(level) -> the same for a level
--   difficulty.knobs(force) -> {level, intel_age, ops, caps = {sites, astar}, pace, in_flight, micro, opm,
--                               budget_factor, expand, cities, council, first_attack, cs_from, cs_ratio,
--                               goods_per_works, goods_works_cap, cs_plan}
--   difficulty.apply(C)        Nation mode: the commander's build pace and first attack from the knobs (called by
--                              ai/commander.lua after its settings; Skirmish keeps orders_data.DIFFICULTY untouched)
--   difficulty.micro(force, need) -> true when the level's micro is at least `need` ("basic" | "full")
--
-- Skirmish keeps its Phase 4 table (orders_data.DIFFICULTY, including hard's bonuses) and never calls apply.
local balance = require("balance")
local data = require("scripts.ai.orders_data")

local difficulty = {}

local LEVELS = {"easy", "normal", "hard"}
difficulty.HUB_PENALTY = 150 -- Nation: attack groups go for a hub or depot only when nothing else is known near
local MICRO_RANK = {off = 0, basic = 1, full = 2}

local function table_of(level)
  local D = balance.nation.ai3 and balance.nation.ai3.difficulty or {}
  return D[level] or D.normal or {}
end

--- The level of a force's AI commander ("normal" for a human nation or an unknown force).
function difficulty.level(force_name)
  local C = storage.ai and storage.ai[force_name]
  local level = C and C.difficulty
  for _, l in ipairs(LEVELS) do
    if l == level then return l end
  end
  return "normal"
end

--- The knob table of a level (contract shape plus the extra knobs of balance.nation.ai3.difficulty).
function difficulty.of_level(level)
  local d = table_of(level)
  return {
    level = level,
    intel_age = d.intel_age or 30 * 60,
    ops = d.ops or 2,
    caps = {sites = d.sites or 16, astar = d.astar or 40000},
    pace = d.build_period or 180,
    in_flight = d.in_flight or 3,
    micro = d.micro or "basic",
    opm = d.opm or 6,
    budget_factor = d.budget_factor or 1,
    expand = d.expand or 1,
    cities = d.cities or 4,
    council = d.council or 120,
    first_attack = d.first_attack or 1,
    cs_from = d.cs_from or 1,
    cs_ratio = d.cs_ratio or 1.5,
    goods_per_works = d.goods_per_works,
    goods_works_cap = d.goods_works_cap,
    cs_plan = d.cs_plan == true,
    goods_chain = d.goods_chain == true,
  }
end

--- The knob table of a force's AI.
function difficulty.knobs(force_name)
  return difficulty.of_level(difficulty.level(force_name))
end

--- True when the force's micro level is at least `need`.
function difficulty.micro(force_name, need)
  local k = difficulty.knobs(force_name)
  return (MICRO_RANK[k.micro] or 0) >= (MICRO_RANK[need] or 0)
end

--- Nation mode: build pace, buildings in flight and the first attack of commander C from its knobs. The settings
--- (ai/commander.lua) already dropped Skirmish's cheats in Nation mode; this only sets skill values.
function difficulty.apply(C)
  local cfg = C.cfg
  if not cfg then return end
  local k = difficulty.of_level(C.difficulty)
  cfg.build_period = k.pace
  cfg.max_in_progress = math.max(cfg.max_in_progress or 0, k.in_flight)
  cfg.goods_per_works, cfg.goods_works_cap = k.goods_per_works, k.goods_works_cap -- ai/governor.lua goods works
  cfg.goods_chain = k.goods_chain or nil -- ai/governor.lua goods_inputs (hard's economic plan)
  if cfg.first_attack then cfg.first_attack = math.floor(cfg.first_attack * k.first_attack + 0.5) end
  -- capture, do not raze: hubs and rail depots (kind "hub") are last among the buildings an attack group goes for
  -- (an AI razed the player's capital depot in M1 seed 501 and its rail line was lost)
  local pen = {}
  for kind, v in pairs(cfg.target_penalty or data.TARGET_PENALTY) do pen[kind] = v end
  pen.hub = math.max(pen.hub or 0, difficulty.HUB_PENALTY)
  cfg.target_penalty = pen
  C.knobs_level = k.level
end

require("scripts.ai.deps").difficulty = difficulty
return difficulty
