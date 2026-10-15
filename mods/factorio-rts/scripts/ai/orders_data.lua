-- AI commander data (docs/PHASE3.md "AI architecture", "Difficulty"): difficulty levels, mining lines and the
-- build order of each difficulty. Pure data, no game access; ai/build_order.lua interprets it.
--
-- Build-order step kinds (evaluated in order, see build_order.lua for the exact rules):
--   {kind = "build", name = <rts building>, anchor = "cc" | "front" | <line name>, count = N, when = {...}}
--       anchor "cc"/"front": N buildings of that kind placed on a free spot near the CC (front = towards the enemy).
--       anchor <line name> ("iron", "copper", "stone", "iron2"): name "rts-extractor" = N extractors on that line,
--       "rts-smelter" (or "slot") = N hub slots of that line (a smelter with its two inserters, the single inserter
--       of a direct slot such as stone, or a steel chain). The line's belts and poles are queued with them.
--   {kind = "recipe", building = "rts-barracks", recipe = "rts-walker-kit"}   enables unit production
--   {kind = "army", min = N, action = "attack"}                                attack once N idle units gathered
--   {kind = "expand", anchor = <line name>, extractors = N, slots = M}        a line to the next free patch of its ore
-- `when` (all optional, all must hold): iron, copper, stone, steel = network counts; units = own units;
-- time = seconds since the commander started.
local data = {}

-- Difficulty levels (lead's pacing for human opponents, 2026-10-15: a human needs minutes to set up).
--   build_period     ticks between construction jobs per commander; a job revives one building, or up to small_batch
--                    belts / inserters / poles in one pass
--   max_in_progress  build-order steps worked on at once
--   first_attack     no attack before this many ticks after the commander started
--   attack_min       army strength that triggers an attack (the build order's "army" step sets it; this is its
--                    default); attack_interval = minimum ticks between attacks
--   defend_share     at most this share of the idle units defends (nil: the nearest half, at least DEFEND_MIN)
--   vision           "honest" (what own entities see) or "full"
--   stock_bonus      extra share of the starting stock; kit_bonus_every: every Nth spawned unit comes with a free one
--   mining_bonus     force.mining_drill_productivity_bonus; heavy: alternate walker and heavy kits once steel exists
data.DIFFICULTY = {
  easy = {
    build_period = 360, small_batch = 3, max_in_progress = 2,
    first_attack = 5 * 60 * 60, attack_min = 6, attack_interval = 4 * 60 * 60, retreat_ratio = 0.4,
    defend_share = 0.5,
    vision = "honest", stock_bonus = 0, kit_bonus_every = nil, mining_bonus = 0, heavy = false,
  },
  normal = {
    build_period = 180, small_batch = 5, max_in_progress = 3,
    first_attack = 3 * 60 * 60, attack_min = 10, attack_interval = 0, retreat_ratio = 0.4,
    vision = "honest", stock_bonus = 0, kit_bonus_every = nil, mining_bonus = 0, heavy = true,
  },
  hard = {
    build_period = 120, small_batch = 6, max_in_progress = 4,
    first_attack = 90 * 60, attack_min = 12, attack_interval = 0, retreat_ratio = 0.4,
    vision = "full", stock_bonus = 0.5, kit_bonus_every = 4, mining_bonus = 0.25, heavy = true,
  },
}
data.DEFAULT_DIFFICULTY = "normal"

-- Mining lines: an ore patch, a belt to the CC hub and the hub slots it feeds, in order (ai/layout.lua HUB). Slot
-- names are for a patch on `side` of the CC (or level with it); for a patch on the other side N <-> S and 1 <-> 2
-- swap, so mirrored maps work too.
-- `rank` = which patch of that ore (1 = the nearest free one, 2 = the next one, used by expansions).
data.LINES = {
  -- iron (match.ORE_PATCHES: 17 tiles forward, 10 to the south): four smelters around the south and west
  -- stockpiles, a steel chain in the north-west (N2c: smelter A makes plates, smelter B turns them into steel), then
  -- two satellite slots
  -- "X" = a satellite slot: an extra rts-stockpile with a smelter slot on each side, placed by layout.lua wherever
  -- the belt can reach it inside the core pole's supply area (the four CC stockpiles cap the hub at four iron
  -- smelters)
  iron = {ore = "iron-ore", rank = 1, side = "south", slots = {"S1", "S2", "W2", "W1", "N2c", "X", "X"}},
  copper = {ore = "copper-ore", rank = 1, side = "north", slots = {"N1", "E1"}},
  -- stone needs no smelter: a direct slot puts it into the east-south stockpile
  stone = {ore = "stone", rank = 1, side = "south", slots = {"E2d"}},
  -- expansion: the hub is full once iron, copper and stone have their slots, so a second iron patch feeds a
  -- satellite of its own
  iron2 = {ore = "iron-ore", rank = 2, side = "south", slots = {"X", "X"}},
}
-- Lines planned when the commander starts (their tiles are reserved before anything else is placed). Expansion
-- lines are planned when their step runs.
data.START_LINES = {"iron", "stone", "copper"}

local B = {} -- build orders
-- Gates use stone and time, not iron: once the barracks run, they take iron as it arrives, so the network rarely
-- holds more than one kit's worth. A queued step gets its iron through production.lua's fairness rule instead (the
-- starved factory reserves iron ahead of the barracks).

-- Easy: one iron and one copper smelter from the starting stock (copper runs out after about 35 kits otherwise),
-- one barracks, stone, then a second iron smelter, a second extractor and one turret late. Attacks every 4 minutes.
B.easy = {
  {kind = "build", name = "rts-factory", anchor = "cc"},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 1},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 1},
  {kind = "build", name = "rts-barracks", anchor = "cc", count = 1},
  {kind = "recipe", building = "rts-barracks", recipe = "rts-walker-kit"},
  {kind = "build", name = "rts-extractor", anchor = "copper", count = 1},
  {kind = "build", name = "rts-smelter", anchor = "copper", count = 1},
  {kind = "build", name = "rts-extractor", anchor = "stone", count = 1, when = {time = 120}},
  {kind = "build", name = "slot", anchor = "stone", count = 1},
  {kind = "army", min = 6, action = "attack"},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 2, when = {stone = 10}},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 2, when = {time = 240}},
  {kind = "build", name = "rts-turret", anchor = "front", count = 1, when = {time = 300}},
}

-- Normal: the standard order. Economy first (iron, then the barracks, then stone and copper, then the third iron
-- smelter), then two turrets, the fourth iron smelter, the steel chain and the two satellite smelters. production.lua shares iron between the factory and the
-- barracks craft by craft, so every building in this list costs units: there is no solar array (the CC's 4 MW
-- covers a full base) and no second barracks (one barracks out-produces the iron of a full line).
B.normal = {
  {kind = "build", name = "rts-factory", anchor = "cc"},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 2},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 2},
  {kind = "build", name = "rts-barracks", anchor = "cc", count = 1},
  {kind = "recipe", building = "rts-barracks", recipe = "rts-walker-kit"},
  {kind = "build", name = "rts-extractor", anchor = "stone", count = 1},
  {kind = "build", name = "slot", anchor = "stone", count = 1},
  {kind = "build", name = "rts-extractor", anchor = "copper", count = 1},
  {kind = "build", name = "rts-smelter", anchor = "copper", count = 1, when = {stone = 10}},
  {kind = "army", min = 10, action = "attack"},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 3},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 3, when = {stone = 10}},
  {kind = "build", name = "rts-turret", anchor = "front", count = 2, when = {time = 150}},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 4, when = {stone = 10, time = 210}},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 4, when = {time = 240}},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 5, when = {stone = 20, time = 240}}, -- steel
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 6, when = {stone = 10, time = 300}}, -- satellite
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 5, when = {time = 300}},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 7, when = {stone = 10, time = 330}}, -- satellite
  -- last: a contested patch is far (the small map's centre is 88 tiles from a CC), its belt alone is 80-130 tiles
  {kind = "expand", anchor = "iron2", extractors = 2, slots = 1, when = {time = 360}},
}

-- Hard: the same shape with earlier gates, three turrets, the steel chain at 2.5 minutes and the satellites at 3. Its edge is the cheats
-- (orders_data.DIFFICULTY.hard), the faster construction pace and full vision.
B.hard = {
  {kind = "build", name = "rts-factory", anchor = "cc"},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 2},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 2},
  {kind = "build", name = "rts-barracks", anchor = "cc", count = 1},
  {kind = "recipe", building = "rts-barracks", recipe = "rts-walker-kit"},
  {kind = "build", name = "rts-extractor", anchor = "stone", count = 1},
  {kind = "build", name = "slot", anchor = "stone", count = 1},
  {kind = "build", name = "rts-extractor", anchor = "copper", count = 1},
  {kind = "build", name = "rts-smelter", anchor = "copper", count = 1, when = {stone = 10}},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 3},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 3, when = {stone = 10}},
  {kind = "army", min = 12, action = "attack"},
  {kind = "build", name = "rts-turret", anchor = "front", count = 3, when = {time = 120}},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 4, when = {stone = 10}},
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 4, when = {time = 150}},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 5, when = {stone = 20, time = 150}}, -- steel
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 6, when = {stone = 10, time = 180}}, -- satellite
  {kind = "build", name = "rts-extractor", anchor = "iron", count = 5, when = {time = 180}},
  {kind = "build", name = "rts-smelter", anchor = "iron", count = 7, when = {stone = 10, time = 210}}, -- satellite
  {kind = "build", name = "rts-barracks", anchor = "cc", count = 2, when = {time = 240}},
  {kind = "expand", anchor = "iron2", extractors = 3, slots = 2, when = {time = 300}},
}
data.BUILD_ORDERS = B

-- Factory recipe that makes each item the AI builds with (rts-* building items and the vanilla logistics items,
-- docs/qa/phase2-prototypes-notes.md "Recipes").
data.FACTORY_RECIPE = {
  ["rts-stockpile"] = "rts-stockpile",
  ["rts-extractor"] = "rts-extractor",
  ["rts-smelter"] = "rts-smelter",
  ["rts-solar-array"] = "rts-solar-array",
  ["rts-factory"] = "rts-factory",
  ["rts-barracks"] = "rts-barracks",
  ["rts-turret"] = "rts-turret",
  ["transport-belt"] = "rts-belt",
  ["fast-inserter"] = "rts-inserter",
  ["medium-electric-pole"] = "rts-pole",
  ["firearm-magazine"] = "rts-ammo",
}

-- Unit production. Once the network holds HEAVY_STEEL steel, each barracks alternates walker and heavy kits: a heavy
-- is due after a walker, and it starts when the network holds HEAVY_IRON iron (the barracks pauses for a moment to
-- let iron gather when it does not).
data.WALKER_KIT = "rts-walker-kit"
data.HEAVY_KIT = "rts-walker-heavy-kit"
data.HEAVY_IRON = 40
data.HEAVY_STEEL = 5
data.TURRET_MAGAZINES = 20 -- keep this many magazines in the network while turrets exist

-- Army target priority: penalty in tiles added to the distance (lower = preferred). Factories are targets too,
-- so a lone factory cannot keep a beaten side alive (docs/qa/phase2-economy-notes.md open items).
data.TARGET_PENALTY = {
  barracks = 0, factory = 0, turret = 10, extractor = 25, smelter = 25, solar = 35, cc = 45, stockpile = 60,
  spawn = 80, unit = 70,
}

return data
