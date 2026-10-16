-- AI doctrines (docs/PHASE4.md section 6): economic, aggressive, turtle. A doctrine sets the build order's middle
-- part (ai/orders_data.lua data.order), the research order, the army's pacing and the unit mix.
--
-- Choice: each AI force gets one at start, at random with a seed (map seed, match id, force number), logged as
--   [rts] ai <force>: doctrine <name> (seed N)
-- storage.ai_meta.doctrines[force] (set by /rts-ai-doctrine or the autotest) overrides the draw.
local util = require("scripts.util")

local doctrine = {}

doctrine.NAMES = {"economic", "aggressive", "turtle"}

-- first_attack  factor on the difficulty's first attack time
-- (the attack size factor lives in ai/orders_data.lua ATTACK_SIZE_FACTOR, next to the build orders)
-- mix           base weights of the unit kinds (ai/mix.lua adds the counters)
-- research      technology order (ai/tech.lua; anything left over follows in tree order)
-- harass        raiders harass enemy haulers and outlying buildings every 2 minutes (ai/raids.lua)
-- patrol        2 units patrol the route between the CC and the first hub (ai/raids.lua)
-- reserve_raiders  raiders kept out of attack groups for the harass
-- yield_army    army units the force keeps before its barracks yield plates to a starved factory (ai/mix.lua)
-- retreat       attack groups retreat below this share of their starting hit points (default: the difficulty's)
-- targets       attack target penalties that replace orders_data.TARGET_PENALTY entries (lower = preferred)
-- in_flight     extra build-order steps worked on at once (none uses it: one more step in flight for the economic
--               doctrine started its hub a minute earlier but pushed its second technology past 7 minutes)
doctrine.DEF = {
  economic = {
    first_attack = 1.7,
    mix = {walker = 4, heavy = 3, drone = 1, raider = 1, artillery = 1},
    research = {"rts-supply-1", "rts-unlock-heavy", "rts-mining-1", "rts-logistics-1", "rts-hauler-capacity-1",
                "rts-attack-1", "rts-armor-1", "rts-unlock-raider", "rts-supply-2", "rts-mining-2", "rts-attack-2",
                "rts-armor-2", "rts-unlock-artillery", "rts-attack-3", "rts-armor-3"},
    patrol = true, yield_army = 6,
  },
  aggressive = {
    first_attack = 1.0, retreat = 0.6,
    -- raids the economy: extractors, smelters and hubs before the barracks
    targets = {extractor = 0, smelter = 5, hub = 0, solar = 10, barracks = 15, factory = 15},
    mix = {drone = 4, walker = 3, raider = 4, heavy = 1},
    research = {"rts-supply-1", "rts-unlock-raider", "rts-attack-1", "rts-armor-1", "rts-unlock-heavy",
                "rts-attack-2", "rts-supply-2", "rts-armor-2", "rts-mining-1", "rts-attack-3"},
    harass = true, reserve_raiders = 4, yield_army = 6,
  },
  turtle = {
    first_attack = 2.2,
    mix = {walker = 3, heavy = 3, artillery = 2, drone = 1},
    research = {"rts-supply-1", "rts-unlock-heavy", "rts-armor-1", "rts-unlock-laser", "rts-unlock-artillery",
                "rts-attack-1", "rts-mining-1", "rts-armor-2", "rts-overcharge", "rts-supply-2", "rts-attack-2"},
    yield_army = 6,
  },
}

local function force_number(force_name)
  return tonumber(string.match(force_name, "(%d+)$")) or 0
end

--- The doctrine of a new commander for `force_name`: the override, else a seeded draw. Returns name, seed.
function doctrine.pick(force_name)
  local meta = storage.ai_meta or {}
  local over = meta.doctrines and meta.doctrines[force_name]
  if over and doctrine.DEF[over] then return over, "override" end
  local m = storage.match
  local surface = util.surface()
  local map_seed = surface and surface.map_gen_settings.seed or 0
  local seed = (map_seed + (m and m.match_id or 0) * 7919 + force_number(force_name) * 104729) % 4294967296
  local rng = game.create_random_generator(seed)
  -- a few draws first: neighbouring seeds give correlated first numbers
  rng()
  rng()
  return doctrine.NAMES[rng(1, #doctrine.NAMES)], seed
end

--- The definition table of a doctrine name (economic when unknown).
function doctrine.get(name)
  return doctrine.DEF[name] or doctrine.DEF.economic
end

return doctrine
