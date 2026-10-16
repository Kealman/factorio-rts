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
--   {kind = "hub", id = N, ore, extractors, slots, solar, haulers}            Phase 4 expansion (ai/hubs.lua): an
--       rts-hub next to the nearest unclaimed patch outside the main (preferring `ore`), a mining line into the hub's
--       stockpiles, `solar` solar arrays at the hub, export policy, `haulers` auto haulers bringing plates home
-- `when` (all optional, all must hold): iron, copper, stone, steel = network counts; units = own units;
-- time = seconds since the commander started; unlocked = a name research must have unlocked (research.is_unlocked).
-- Phase 4: the build order of a commander is data.order(difficulty, doctrine): the difficulty's opening, the army
-- step, then the doctrine's steps (DOCTRINE_STEPS) with their time gates scaled by TIME_SCALE.
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
  -- coal for explosives (artillery kits): a direct slot into a CC stockpile, like stone
  coal = {ore = "coal", rank = 1, side = "south", slots = {"direct"}},
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
data.BUILD_ORDERS = B -- Phase 3 orders (reference; Phase 4 commanders use data.order)

---------------------------------------------------------------------------
-- Phase 4 build orders: opening + army step + doctrine steps
---------------------------------------------------------------------------
data.TIME_SCALE = {easy = 1.5, normal = 1.0, hard = 0.7}
local RANK = {easy = 1, normal = 2, hard = 3}

-- Openings (Phase 3: economy first). Easy keeps one iron and one copper smelter from the starting stock. Phase 4:
-- after stone, a lab and the second factory (the workshop: science kits), then the iron core (a third extractor,
-- smelters 3 and 4, the steel chain for heavies), copper (two smelters: walkers, science, circuits and heavies all
-- take copper), a second lab and a third factory (the feeder: gears for the workshop), in order and without time
-- gates, so research starts in the second minute. Later steps never got the steel chain or the second copper smelter
-- built by minute 8 on normal. The recipe step (unit production) is placed by the
-- doctrine (UNITS_AFTER): the aggressive doctrine makes units at once, the others once the third iron smelter runs
-- (the 200 starting plates pay for the lab, the workshop and the core first; plates are the bottleneck of every
-- early step).
local OPENING = {
  easy = {
    {kind = "build", name = "rts-factory", anchor = "cc"},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 1},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 1},
    {kind = "build", name = "rts-barracks", anchor = "cc", count = 1, tag = "barracks"},
    {kind = "build", name = "rts-extractor", anchor = "copper", count = 1},
    {kind = "build", name = "rts-smelter", anchor = "copper", count = 1, tag = "core"},
    {kind = "build", name = "rts-extractor", anchor = "stone", count = 1, when = {time = 120}},
    {kind = "build", name = "slot", anchor = "stone", count = 1},
    {kind = "build", name = "rts-lab", anchor = "cc", count = 1, when = {time = 40}},
    {kind = "build", name = "rts-factory", anchor = "cc", count = 2, when = {time = 80}},
  },
  normal = {
    {kind = "build", name = "rts-factory", anchor = "cc"},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 2},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 2},
    {kind = "build", name = "rts-barracks", anchor = "cc", count = 1, tag = "barracks"},
    {kind = "build", name = "rts-extractor", anchor = "stone", count = 1},
    {kind = "build", name = "slot", anchor = "stone", count = 1},
    {kind = "build", name = "rts-lab", anchor = "cc", count = 1},
    {kind = "build", name = "rts-factory", anchor = "cc", count = 2},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 3},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 3, when = {stone = 10}, tag = "core"},
    {kind = "build", name = "rts-extractor", anchor = "copper", count = 1},
    {kind = "build", name = "rts-smelter", anchor = "copper", count = 1, when = {stone = 10}},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 4, when = {stone = 10}},
    {kind = "build", name = "rts-lab", anchor = "cc", count = 2},
    {kind = "build", name = "rts-factory", anchor = "cc", count = 3}, -- the feeder workshop (gears, circuits)
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 5, when = {stone = 20}, tag = "steel"}, -- heavies
    {kind = "build", name = "rts-extractor", anchor = "copper", count = 2},
    {kind = "build", name = "rts-smelter", anchor = "copper", count = 2, when = {stone = 10}},
  },
}
OPENING.hard = OPENING.normal
-- The recipe step (unit production) goes after the opening step with this tag.
data.UNITS_AFTER = {economic = "core", aggressive = "barracks", turtle = "core"}
data.UNITS_STEP = {kind = "recipe", building = "rts-barracks", recipe = "rts-walker-kit"}
-- Doctrine steps placed inside the opening, after the opening step with the given tag: the economic doctrine's first
-- hub (stage 1) right after the steel chain. Queued after the whole opening, it stood at 5-6 minutes on normal and
-- its first hauler delivered after minute 8.
data.OPENING_EXTRA = {
  economic = {steel = {
    {kind = "hub", id = 1, ore = "iron-ore", extractors = 2, slots = 1, solar = 1, haulers = 1, plan_slots = 2,
     plan_solar = 2},
  }},
}


-- Doctrine steps, time gates in normal seconds (scaled per difficulty). min_difficulty drops a step below it.
data.DOCTRINE_STEPS = {
  -- economic: the first hub at 2 minutes and a second one at 4.5, one hauler each, a late push
  economic = {
    -- the first hub in two steps: stage 1 (one smelter slot, one solar array, planned for two of each, its queue
    -- entries to the front) sits in the opening after the steel chain (OPENING_EXTRA); the rest here
    {kind = "hub", id = 1, ore = "iron-ore", extractors = 2, slots = 2, solar = 2, haulers = 1, when = {time = 200}},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 4, when = {time = 150}},
    {kind = "build", name = "rts-turret", anchor = "front", count = 2, when = {time = 200}},
    {kind = "build", name = "rts-barracks", anchor = "cc", count = 2, when = {time = 240}, min_difficulty = "hard"},
    {kind = "hub", id = 2, ore = "copper-ore", extractors = 2, slots = 2, solar = 2, haulers = 1, when = {time = 270}},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 6, when = {stone = 10, time = 300}},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 5, when = {time = 300}},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 7, when = {stone = 10, time = 330}},
  },
  -- aggressive: units from the start, a second barracks at 4 minutes (earlier, its plates never left room for
  -- science), drones and raiders (Unlock Raider right after the cheap Supply I), one turret, a hub late
  aggressive = {
    {kind = "build", name = "rts-barracks", anchor = "cc", count = 2, when = {time = 240}},
    {kind = "build", name = "rts-turret", anchor = "front", count = 1, when = {time = 180}},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 4, when = {time = 200}},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 6, when = {stone = 10, time = 300}},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 5, when = {time = 300}},
    {kind = "hub", id = 1, ore = "iron-ore", extractors = 2, slots = 2, solar = 2, haulers = 1, when = {time = 330}},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 7, when = {stone = 10, time = 360}},
  },
  -- turtle: turrets early (4-6), coal for explosives (artillery), solar power and two laser turrets once researched,
  -- a hub late
  turtle = {
    {kind = "build", name = "rts-turret", anchor = "front", count = 2, when = {time = 75}},
    {kind = "build", name = "rts-extractor", anchor = "iron", count = 4, when = {time = 140}},
    {kind = "build", name = "rts-turret", anchor = "front", count = 4, when = {time = 150}},
    {kind = "build", name = "rts-extractor", anchor = "coal", count = 1, when = {time = 240}},
    {kind = "build", name = "slot", anchor = "coal", count = 1, when = {time = 240}},
    {kind = "build", name = "rts-barracks", anchor = "cc", count = 2, when = {time = 240}, min_difficulty = "hard"},
    {kind = "build", name = "rts-turret", anchor = "front", count = 6, when = {time = 270}},
    {kind = "build", name = "rts-solar-array", anchor = "cc", count = 2, when = {time = 270}},
    {kind = "build", name = "rts-laser-turret", anchor = "front", count = 2, when = {unlocked = "rts-laser-turret"}},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 6, when = {stone = 10, time = 300}},
    {kind = "hub", id = 1, ore = "iron-ore", extractors = 2, slots = 2, solar = 2, haulers = 1, when = {time = 330}},
    {kind = "build", name = "rts-smelter", anchor = "iron", count = 7, when = {stone = 10, time = 360}},
  },
}
-- aggressive builds its second barracks at every difficulty; the others only on hard (min_difficulty above)

local order_cache = {} -- derived from static data, identical on every load

local function copy_step(st, scale)
  local c = {}
  for k, v in pairs(st) do c[k] = v end
  if st.when then
    c.when = {}
    for k, v in pairs(st.when) do c.when[k] = v end
    if c.when.time then c.when.time = math.floor(c.when.time * scale + 0.5) end
  end
  return c
end

--- The build order of a commander: opening (with the recipe step where the doctrine wants it), army step
--- (difficulty attack size x doctrine factor), doctrine steps.
function data.order(difficulty, doctrine_name)
  difficulty = data.DIFFICULTY[difficulty] and difficulty or data.DEFAULT_DIFFICULTY
  local D = data.DOCTRINE_STEPS[doctrine_name] and doctrine_name or "economic"
  local key = difficulty .. "/" .. D
  if order_cache[key] then return order_cache[key] end
  local scale = data.TIME_SCALE[difficulty] or 1
  local o = {}
  local after = data.UNITS_AFTER[D] or "barracks"
  local extra = data.OPENING_EXTRA[D] or {}
  for _, st in ipairs(OPENING[difficulty]) do
    o[#o + 1] = copy_step(st, scale)
    if st.tag == after then o[#o + 1] = copy_step(data.UNITS_STEP, scale) end
    for _, x in ipairs(st.tag and extra[st.tag] or {}) do o[#o + 1] = copy_step(x, scale) end
  end
  local factor = data.ATTACK_SIZE_FACTOR[D] or 1
  o[#o + 1] = {kind = "army", min = math.max(4, math.floor(data.DIFFICULTY[difficulty].attack_min * factor + 0.5)),
               action = "attack"}
  for _, st in ipairs(data.DOCTRINE_STEPS[D]) do
    if not (st.min_difficulty and RANK[difficulty] < RANK[st.min_difficulty]) then o[#o + 1] = copy_step(st, scale) end
  end
  order_cache[key] = o
  return o
end
-- attack size factor per doctrine (mirrors ai/doctrine.lua DEF[*].attack_size; kept here so data.order is pure data)
data.ATTACK_SIZE_FACTOR = {economic = 1.0, aggressive = 0.8, turtle = 1.1}

-- Factory recipe that makes each item the AI builds with (rts-* building items and the vanilla logistics items,
-- docs/qa/phase2-prototypes-notes.md "Recipes"). Phase 4: hub, lab, laser turret.
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
  ["rts-hub"] = "rts-hub",
  ["rts-lab"] = "rts-lab",
  ["rts-laser-turret"] = "rts-laser-turret",
}
-- Workshop items (Phase 4): the factory recipe of each (science kits, hauler kits; intermediates come from
-- balance.intermediates in ai/commander.lua)
data.WORKSHOP_RECIPE = {
  ["rts-science-basic"] = "rts-science-basic",
  ["rts-science-advanced"] = "rts-science-advanced",
  ["rts-hauler-kit"] = "rts-hauler-kit",
}
data.SCIENCE_PER_LAB = 4   -- science kits kept in the network per lab while research runs
data.CIRCUIT_STOCK = 20    -- circuits kept while raiders, lasers, hauler kits or advanced science need them
data.EXPLOSIVE_STOCK = 20  -- explosives kept while artillery is wanted
data.GEAR_STOCK = 6        -- gears kept ahead of basic science kits

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
  barracks = 0, factory = 0, lab = 15, hub = 20, turret = 10, ["laser-turret"] = 12, extractor = 25, smelter = 25,
  solar = 35, ["steam-plant"] = 30, radar = 30, accumulator = 40, cc = 45, stockpile = 60, spawn = 80, unit = 70,
  wall = 90, -- every wall segment is a registered building: attack what the wall protects, not the wall
}

return data
