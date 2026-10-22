-- Balance data shared by the data stage (prototypes/*.lua) and the control stage (scripts/*.lua).
--
--   local balance = require("balance")   -- works in both stages (mod root is on the require path)
--
-- Pure data: no data.raw, no game / prototypes access; the returned table holds no functions (a local helper derives
-- the mk2 entries). `require` caches the table per stage, so treat it as read-only. The prototypes read costs, times,
-- health and combat numbers from here, so changing a number here changes the game (after a restart).
-- See docs/qa/phase4-content-notes.md ("Balance table API") and docs/qa/phase4-balance-notes.md.
--
-- Units: balance.units[unit prototype name] = {
--   kind           units.lua kind ("walker", "heavy", "drone", "raider", "artillery", "commander"). mk2 tiers share the
--                  kind of their base unit, so counts and AI logic treat them alike; `tier` tells them apart.
--   tier           1 or 2 (mk2)          base   tier-1 unit an mk2 replaces (mk2 only)
--   role           short role tag for AI / HUD
--   supply         command capacity the unit uses (docs/PHASE4.md section 1)
--   kit            kit item the unit comes from (nil = no kit). Made by the barracks unless `made_by` says otherwise:
--                  the hauler's kit comes from the factory (made_by = "factory"), so lists of barracks kits must
--                  skip entries whose made_by is set.
--   cost, time     kit recipe ingredients {item = amount} and seconds
--   unlock         technology that unlocks the unit (informational, mirrors scripts/research.lua EFFECTS / LOCKS).
--                  Kit recipes of tier-1 units are always enabled: the barracks gate in scripts/research.lua refuses
--                  locked units. mk2 kit recipes start disabled (research deploys mk2 units from tier-1 kits).
--   health         max health
--   speed          relative to the walker (11.5 tiles/s), as measured in both variants: drone 1.45, raider 1.35,
--                  artillery 0.65, heavy 0.55; the commander's is relative to the vanilla spidertron. Informational:
--                  prototypes/units.lua sets the leg speeds that produce these (docs/qa/phase4-balance-notes.md).
--   size           collision box half-size in tiles, the same in both variants (the drone keeps the medium biter's)
--   range, min_range, cooldown (ticks), damage (per hit), damage_type, splash (radius, tiles), splash_damage (heavy:
--                  extra damage to every enemy within `splash` of the target, the target included)
--   attack_from    artillery: it fires from between attack_from and range (min_attack_distance)
--   resist         {damage type = percent}: armour of the torso and the legs
--   tags           target types the unit carries (keys of balance.target_types): heavy "armored", raider "light",
--                  artillery "siege"
--   bonus          {[target type key] = multiplier}: total damage against entities carrying that type (raider x2.5 vs
--                  raid targets and x1.65 vs siege, artillery x9 vs armored, drone x3 vs light)
--   bonus_radius   artillery: the bonus applies within this radius of the impact (the plain damage within `splash`)
--   ammo_category  the attack's ammo category: force.set_ammo_damage_modifier(category, x) scales it
--   strong, weak   counter wheel (docs/PHASE4.md section 3): kinds plus "building", "turret", "laser-turret",
--                  "hauler", "wall"
--   counters       unit kinds this unit beats in an open-field fight between equal-cost armies (iron-equivalent:
--                  copper x1, steel x3, circuit x4, explosives x2), keeping 40-70 % of its army. Verified by the
--                  balance simulator (tools/balance-sim, docs/qa/phase4-balance-notes.md).
-- }
-- Buildings: balance.buildings[entity name] = {kind, cost, time, count (items per craft, default 1), health,
--   unlock?, supply_cap?, power?} -- `kind` is the scripts/buildings.lua registry kind (new ones are proposals:
--   scripts/buildings.lua KIND_BY_NAME does not list them yet). No cost = not made by the factory. `unlock` names the
--   technology; such recipes start disabled and scripts/research.lua enables them per force. `supply_cap` is the
--   command capacity a live building of that name adds (docs/PHASE4.md section 1: CC 40, hub 10); scripts/supply.lua
--   reads it. Entries for buildings other agents define (rts-hub) carry only what this table is the source of.
-- Intermediates: balance.intermediates[recipe name] = {result, count, cost, time} (rts-factory, category
--   rts-intermediates). balance.smelting[vanilla recipe] = {cost, time}: overrides of vanilla smelting recipes.

local balance = {}

-- Trigger target types (prototypes/categories.lua defines them). An entity carries one through its
-- trigger_target_mask, e.g. {"common", balance.target_types.raid}; an attack with bonus[key] = m deals m x damage
-- to it (an "area" trigger with that mask nested in the hit, prototypes/units.lua).
--   raid     economy buildings, poles, hubs, haulers (raiders)
--   armored  heavies (artillery)
--   light    raiders (drones)
--   siege    artillery (raiders)
balance.target_types = {raid = "rts-raid-target", armored = "rts-armored", light = "rts-light", siege = "rts-siege"}
balance.raid_target_type = balance.target_types.raid -- prototypes/buildings.lua and prototypes/logistics.lua

balance.units = {
  ["rts-walker"] = {
    kind = "walker", tier = 1, role = "line", supply = 1,
    kit = "rts-walker-kit", cost = {["iron-plate"] = 10, ["copper-plate"] = 2}, time = 3,
    health = 200, speed = 1.0, size = 0.7,
    range = 20, cooldown = 60, damage = 20, damage_type = "physical",
    ammo_category = "rts-walker",
    counters = {"drone", "raider"},
    strong = {"drone"}, weak = {"heavy", "artillery"},
  },
  ["rts-walker-heavy"] = {
    kind = "heavy", tier = 1, role = "tank", supply = 3,
    kit = "rts-walker-heavy-kit", cost = {["iron-plate"] = 30, ["copper-plate"] = 10, ["steel-plate"] = 5}, time = 8,
    unlock = "rts-unlock-heavy",
    health = 800, speed = 0.55, size = 1.1,
    range = 16, cooldown = 60, damage = 50, damage_type = "explosion", splash = 2.5, splash_damage = 12,
    resist = {physical = 60}, tags = {"armored"},
    ammo_category = "rts-heavy",
    counters = {"walker", "drone"},
    strong = {"walker", "drone"}, weak = {"artillery", "laser-turret"},
  },
  ["rts-drone"] = {
    kind = "drone", tier = 1, role = "swarm", supply = 1,
    kit = "rts-drone-kit", cost = {["iron-plate"] = 6}, time = 2,
    health = 85, speed = 1.45,
    range = 1, cooldown = 30, damage = 11, damage_type = "impact", -- heavy armour (physical) does not stop bites
    bonus = {light = 3},
    ammo_category = "rts-drone",
    counters = {"artillery", "raider"},
    strong = {"artillery", "hauler", "raider"}, weak = {"turret", "walker"},
  },
  ["rts-raider"] = {
    kind = "raider", tier = 1, role = "raid", supply = 2,
    kit = "rts-raider-kit", cost = {["iron-plate"] = 8, ["electronic-circuit"] = 2}, time = 5,
    unlock = "rts-unlock-raider",
    health = 220, speed = 1.35, size = 0.8,
    range = 18, cooldown = 30, damage = 12, damage_type = "physical", bonus = {raid = 2.5, siege = 1.65},
    tags = {"light"},
    ammo_category = "rts-raider",
    counters = {"artillery"},
    strong = {"hauler", "building", "artillery"}, weak = {"walker", "turret", "drone"},
  },
  ["rts-artillery"] = {
    kind = "artillery", tier = 1, role = "siege", supply = 4,
    kit = "rts-artillery-kit", cost = {["iron-plate"] = 40, ["steel-plate"] = 5, ["rts-explosives"] = 10},
    time = 12, unlock = "rts-unlock-artillery",
    health = 450, speed = 0.65, size = 1.2,
    range = 44, min_range = 8, attack_from = 32, cooldown = 180, damage = 120, damage_type = "explosion", splash = 3.5,
    bonus = {armored = 9}, bonus_radius = 2, tags = {"siege"},
    resist = {impact = 25}, -- plated against drone bites (drones are the only impact damage)
    ammo_category = "rts-artillery",
    counters = {"heavy"},
    strong = {"turret", "laser-turret", "heavy", "wall"}, weak = {"drone", "raider"},
  },
  -- Logistics agent's hauler (prototypes/logistics.lua): listed so supply never charges for it.
  ["rts-hauler"] = {
    kind = "hauler", role = "hauler", supply = 0, kit = "rts-hauler-kit", made_by = "factory",
    strong = {}, weak = {"raider", "drone"},
  },
  ["rts-commander"] = {
    kind = "commander", tier = 1, role = "hero", supply = 0, -- spawned by script, one per player, no kit
    health = 2000, speed = 1.2, -- relative to the vanilla spidertron
    range = 30, cooldown = 30, damage = 40, damage_type = "explosion", -- per rocket, two launchers
    ammo_category = "rts-commander", ammo = "rts-commander-rocket",
    strong = {}, weak = {},
  },
}

-- mk2 tiers (Armor I): the base unit with +40 % health and +25 % damage, a kit that costs 5 more steel.
local function mk2(base_name, name, kit, extra_cost)
  local u = {}
  for k, v in pairs(balance.units[base_name]) do u[k] = v end
  u.tier, u.base, u.kit, u.unlock = 2, base_name, kit, "rts-armor-1"
  u.cost = {}
  for item, n in pairs(balance.units[base_name].cost) do u.cost[item] = n end
  for item, n in pairs(extra_cost) do u.cost[item] = (u.cost[item] or 0) + n end
  u.health = math.floor(u.health * 1.4 + 0.5)
  u.damage = u.damage * 1.25
  if u.splash_damage then u.splash_damage = u.splash_damage * 1.25 end
  balance.units[name] = u
end
mk2("rts-walker", "rts-walker-mk2", "rts-walker-mk2-kit", {["steel-plate"] = 5})
mk2("rts-walker-heavy", "rts-heavy-mk2", "rts-heavy-mk2-kit", {["steel-plate"] = 5})

-- Phase 5 E1 (Nation mode, Age II; docs/qa/phase5-economy-notes.md): the Armoured car, a motorised unit built from
-- engines and steel beams (the Age II goods districts make cheaply). Fast, tough against bullets, strong against walkers
-- and raiders; artillery (armored bonus) and heavies are its answer. nation_only: never in Skirmish (its kit recipe
-- unlocks at Age II, scripts/ages.lua; the HUD hides it outside Nation mode; balance-sim's Phase 4 counter scenarios
-- leave it out).
balance.units["rts-armoured-car"] = {
  kind = "car", tier = 1, role = "assault", supply = 3, nation_only = true,
  kit = "rts-armoured-car-kit", cost = {["engine-unit"] = 2, ["rts-steel-beam"] = 2, ["iron-plate"] = 10}, time = 8,
  unlock = "age 2",
  health = 800, speed = 1.6, size = 0.9,
  range = 18, cooldown = 12, damage = 12, damage_type = "physical",
  resist = {physical = 30, impact = 30}, tags = {"armored"},
  ammo_category = "rts-car",
  counters = {"walker", "raider"},
  strong = {"walker", "raider", "drone"}, weak = {"heavy", "artillery"},
}

balance.buildings = {
  -- Phase 2 buildings (values unchanged; prototypes/buildings.lua and recipes.lua read them from here)
  ["rts-command-center"] = {kind = "cc", health = 3000, supply_cap = 40}, -- match start only
  ["rts-hub"] = {kind = "hub", supply_cap = 10}, -- logistics agent's prototype (cost, health in logistics.lua)
  ["rts-stockpile"] = {kind = "stockpile", cost = {["iron-plate"] = 20, ["copper-plate"] = 5}, time = 4, health = 800},
  ["rts-extractor"] = {kind = "extractor", cost = {["iron-plate"] = 20, ["copper-plate"] = 5}, time = 5, health = 500},
  ["rts-smelter"] = {kind = "smelter", cost = {["iron-plate"] = 20, ["stone"] = 10}, time = 5, health = 600},
  ["rts-solar-array"] = {kind = "solar", cost = {["copper-plate"] = 15, ["iron-plate"] = 10}, time = 4, health = 300,
                         power = "400kW"},
  ["rts-factory"] = {kind = "factory", cost = {["iron-plate"] = 60, ["copper-plate"] = 20}, time = 10, health = 1000},
  ["rts-barracks"] = {kind = "barracks", cost = {["iron-plate"] = 60, ["copper-plate"] = 20}, time = 10, health = 1500},
  ["rts-turret"] = {kind = "turret", cost = {["iron-plate"] = 40, ["copper-plate"] = 10}, time = 6, health = 1200,
                   range = 21},
  -- Phase 4 defence and power
  ["rts-laser-turret"] = {kind = "laser-turret", cost = {["iron-plate"] = 20, ["electronic-circuit"] = 10}, time = 8,
                          health = 1000, unlock = "rts-unlock-laser", power = "2MW", -- peak input; 800 kJ per shot
                          range = 22, cooldown = 40, damage = 50},
  ["rts-wall"] = {kind = "wall", cost = {["stone-brick"] = 5}, count = 5, time = 2, health = 500},
  ["rts-steam-plant"] = {kind = "steam-plant", cost = {["iron-plate"] = 40, ["steel-plate"] = 10}, time = 10,
                         health = 800, unlock = "rts-steam-power", power = "1.8MW", fuel = "coal"},
  ["rts-accumulator"] = {kind = "accumulator", cost = {["iron-plate"] = 10, ["copper-plate"] = 10}, time = 4,
                         health = 300},
  ["rts-radar"] = {kind = "radar", cost = {["iron-plate"] = 20, ["electronic-circuit"] = 10}, time = 6, health = 400,
                   reveal_chunks = 2}, -- radius: a 5x5-chunk square (160x160 tiles) stays visible
  -- Phase 5 M1, Nation mode only (prototypes/cities.lua, scripts/cities.lua, scripts/territory.lua). The City Center is
  -- a hub subtype (kind "hub": logistics.lua builds its composite); its item is the City charter (factory recipe).
  ["rts-city-center"] = {kind = "hub", health = 1800, power = "1MW"},
  ["rts-fort"] = {kind = "fort", cost = {["iron-plate"] = 30, ["stone"] = 20}, time = 6, health = 600, range = 18},
}

-- Phase 5 M1 Nation mode (docs/PHASE5-M1.md section 1): modules read balance.nation.<key> only when
-- storage.match.config.mode == "nation". Territory and cities (scripts/territory.lua, scripts/cities.lua):
balance.nation = balance.nation or {}
balance.nation.territory = {
  cell = 8,                                   -- tiles per grid cell side
  radius = {city = {48, 72, 96}, fort = 24, hub = 16, radar = 16},      -- land radius in tiles (city: by tier)
  capital_bonus = 24,                         -- tiles the capital claims beyond its tier's radius (study: +3 cells)
  strength = {city = {3, 4, 5}, capital = 1, fort = 2, hub = 1.5, radar = 1}, -- capital: added to its tier's
  sticky = 1.15,                              -- a challenger must beat the current owner's score by 15 %
  attrition = {period = 300, share = 0.015, depth_cells = 2, supply_radius = 24, commander = 0.5}, -- ~18 %/min
  fort_ammo = 20,                             -- free magazines a new fort gets
}
balance.nation.cities = {
  capital_tier = 2,                           -- the starting CC registers as the capital at this tier
  supply = {10, 20, 30},                      -- supply cap per tier (the capital adds tier supply minus the tier-2 20)
  charter = {cost = {["iron-plate"] = 80, ["copper-plate"] = 30, ["stone"] = 40}, time = 20},
  spacing = 96,                               -- tiles between City Centers (any force)
  limit = 4,                                  -- cities per nation, capital included
  tier_up = {[2] = {buildings = 10, delivered = 400}, [3] = {buildings = 25, delivered = 2000}},
  ai_found_at = 300,                          -- seconds: the AI plans its second city from then on
  -- Phase 5 M1 integration: a capital's centre heals back this share of every hit (scripts/cities.lua), so it takes
  -- about twice the damage to fall; a 1-3 hour match should not end in a base race in minute 12
  capital_armor = 0.5,
  -- Phase 5 M1 integration: inserters of a nation move this many more items per swing (LuaForce
  -- inserter_stack_size_bonus): a direct slot (belt -> inserter -> stockpile) carried only 2.3 ore/s, so a town's six
  -- extractors could not fill a train
  inserter_bonus = 2,
  ai_site_distance = 110,                     -- tiles from its capital when no world city site is known
}

balance.intermediates = {
  ["rts-gear"] = {result = "iron-gear-wheel", count = 1, cost = {["iron-plate"] = 2}, time = 1},
  ["rts-cable"] = {result = "copper-cable", count = 2, cost = {["copper-plate"] = 1}, time = 0.5},
  ["rts-circuit"] = {result = "electronic-circuit", count = 1, cost = {["iron-plate"] = 1, ["copper-cable"] = 3},
                     time = 1.5},
  ["rts-explosives"] = {result = "rts-explosives", count = 1, cost = {["coal"] = 2, ["iron-plate"] = 1}, time = 2},
}

-- Vanilla smelting recipes the rts-smelter runs (iron, copper, stone brick, steel). Only the overrides are listed:
-- steel follows docs/PHASE4.md 2.5 ("steel: 2 plates, slow") instead of vanilla 5 plates in 16 s.
balance.smelting = {
  ["steel-plate"] = {cost = {["iron-plate"] = 2}, time = 6.4},
}

---------------------------------------------------------------------------
-- Phase 5 Nation mode (docs/PHASE5-M1.md section 1). Every work package adds its own keys to balance.nation; never
-- replace the table. Modules read these numbers only in Nation mode.
---------------------------------------------------------------------------
balance.nation = balance.nation or {}

-- E1 economy (m1-economy, docs/qa/phase5-economy-notes.md): ages, Age II goods and buildings, districts, the Railway
-- Charter, make targets. Prototypes (prototypes/age2.lua, prototypes/districts.lua) read costs, times and health from
-- here; scripts/ages.lua, scripts/districts.lua and scripts/ai/age_up.lua read the rest.
--
-- recipes[name] = {category, cost = {item = n}, results = {item = n}, time (s), order}. Every recipe here starts
--   disabled and is enabled for a force when it reaches Age II (scripts/ages.lua), like the building recipes below.
--   Categories: rts-age2 (factory), rts-oil (refinery), rts-chemistry (chemical plant), rts-science (factory, the
--   industrial kit) and one rts-district-<id> per district.
-- buildings[name] = {kind, family, cost, time, health, power?, size?, categories?, mining_speed?}: Age II buildings,
--   made by the factory (rts-buildings), placed like any building. kind "district" (network-fed crafting machine,
--   scripts/districts.lua) or "pumpjack" (crude oil into the network as rts-crude-oil items). They are copied into
--   balance.buildings at the end of this file (registry kinds, health, the on_entity_damaged filter).
local E = {}
balance.nation.economy = E

E.crude_per_item = 10        -- crude oil (fluid units) per rts-crude-oil item drained from a pumpjack
E.pumpjack_period = 60       -- ticks between pumpjack drains
E.auto_period = 60           -- ticks between auto-recipe passes (production.lua): a met target switches within ~1 s
E.auto_dwell = 30 * 60       -- an auto machine keeps a still-short recipe this long before a much larger shortfall
E.auto_margin = 0.25         --   (by at least this share of its target) takes over
E.default_targets = {}       -- make targets a new city starts with (the player sets the rest in the ledger, L)

-- Owner's design constraint (2026-10-16): the economy is the road to victory, walker spam is not.
-- Age II "Mk2 line": every unit of a force in Age II deals +attack damage (its ammo category) and takes (1 - armor) of
-- the damage it is hit by (scripts/research.lua heals the share back, as Armor II/III): mk2 numbers (+25 % damage,
-- +40 % health) for every unit kind. Nation mode only.
E.age2_bonus = {attack = 0.25, armor = 0.2857}
-- Army soft cap (scripts/production.lua): every `step` army units beyond `free` raise the cost of an Age I kit by
-- `raise` (+10 % per 10 units beyond 20). The surcharge (that share of every kit ingredient, rounded up) is taken
-- from the barracks' logistic network when the kit becomes a unit; a kit waits while the network cannot pay it.
-- Age II kits (nation_only units) pay none. Nation mode only.
E.army_softcap = {free = 20, step = 10, raise = 0.10}
-- Efficiency floor for Age II goods made in districts versus hand-built machines (raw plates, stone, coal and crude
-- per item; checked by tools/probes/economy_e1.lua, district_efficiency).
E.district_efficiency = 1.5

-- Industrialisation (advanced kits) unlocks the Railway Charter; the Charter (deliveries to a site in the capital)
-- brings Age II. Age I goods only: Age II recipes stay locked until the Charter is done.
E.charter = {
  tech = "rts-industrialisation",
  required = {["steel-plate"] = 100, ["electronic-circuit"] = 100, ["iron-gear-wheel"] = 100, ["stone"] = 150},
  pull_per_second = 10,      -- per item and second, from the site's logistic network
  build_seconds = 20,        -- countdown once everything is delivered
  raze_loss = 0.5,           -- share of the delivered goods lost when the site is destroyed
  site_health = 4000,
}

-- Technologies (prototypes/age2.lua; effects applied by scripts/research.lua through research.EFFECTS). Nation mode
-- only. age = the age the force must have reached before it can research the technology.
E.techs = {
  {name = "rts-industrialisation", kit = "rts-science-advanced", count = 20, icon = "railway", age = 1,
   effect = {flag = "industrialisation"}},
  {name = "rts-supply-3", kit = "rts-science-industrial", count = 15, icon = "toolbelt", age = 2,
   prerequisites = {"rts-industrialisation"}, effect = {supply = 15}},
  {name = "rts-mining-3", kit = "rts-science-industrial", count = 15, icon = "mining-productivity", age = 2,
   prerequisites = {"rts-industrialisation"}, effect = {mining = 0.25}},
  {name = "rts-hauler-capacity-2", kit = "rts-science-industrial", count = 15, icon = "logistics-3", age = 2,
   prerequisites = {"rts-industrialisation"}, effect = {hauler_slots = 10}},
  {name = "rts-attack-4", kit = "rts-science-industrial", count = 25, icon = "stronger-explosives-3", age = 2,
   prerequisites = {"rts-industrialisation"}, effect = {attack = 1}},
}

-- No steel: an Age I economy makes little of it and research kits take it; stone piles up (the AI held 900)
local DISTRICT_COST = {["iron-plate"] = 80, stone = 40, ["electronic-circuit"] = 15}
E.buildings = {
  ["rts-pumpjack"] = {kind = "pumpjack", family = "oil", cost = {["iron-plate"] = 30, ["steel-plate"] = 5,
                      ["electronic-circuit"] = 5}, time = 6, health = 600, mining_speed = 0.5},
  ["rts-refinery"] = {kind = "district", family = "oil", cost = {["iron-plate"] = 60, ["steel-plate"] = 15,
                      ["electronic-circuit"] = 10}, time = 10, health = 1500, power = "300kW", categories = {"rts-oil"}},
  ["rts-chemical-plant"] = {kind = "district", family = "chemistry", cost = {["iron-plate"] = 30, ["steel-plate"] = 5,
                            ["electronic-circuit"] = 5}, time = 6, health = 800, power = "200kW",
                            categories = {"rts-chemistry"}},
  -- Age II turret: a 3x3 gun emplacement on magazines (fed like the turret), outranges walkers (20) and heavies.
  ["rts-bunker"] = {kind = "turret", family = "military", cost = {["rts-steel-beam"] = 8, concrete = 20,
                    ["iron-plate"] = 20}, time = 10, health = 3000, range = 26, cooldown = 30, damage_modifier = 12},
}
-- The ten districts: 5x5 assembling machines with compressed multi-stage recipes (one category each).
E.districts = {
  {id = "smelting", family = "metallurgy"}, {id = "steel", family = "metallurgy"},
  {id = "circuits", family = "electronics"}, {id = "electronics", family = "electronics"},
  {id = "petrochem", family = "chemistry"}, {id = "engines", family = "machinery"},
  {id = "munitions", family = "military"}, {id = "rails", family = "machinery"},
  {id = "construction", family = "construction"}, {id = "science", family = "science"},
}
for _, d in ipairs(E.districts) do
  local cost = {}
  for item, n in pairs(DISTRICT_COST) do cost[item] = n end
  if d.id == "science" then cost["copper-plate"], cost["electronic-circuit"] = 40, 25 end
  E.buildings["rts-district-" .. d.id] = {kind = "district", family = d.family, cost = cost, time = 12, health = 2500,
                                          power = "400kW", size = 5, categories = {"rts-district-" .. d.id}}
end

E.recipes = {
  -- Age II intermediates (factory, refinery, chemical plant). Vanilla items, ingredient structure kept, amounts and
  -- times scaled down as balance.smelting does for steel.
  ["rts-oil-processing"] = {category = "rts-oil", cost = {["rts-crude-oil"] = 4}, results = {["rts-petroleum"] = 3},
                            time = 3, order = "a"},
  ["rts-plastic"] = {category = "rts-chemistry", cost = {["rts-petroleum"] = 1, coal = 1},
                     results = {["plastic-bar"] = 2}, time = 2, order = "b"},
  ["rts-sulfur"] = {category = "rts-chemistry", cost = {["rts-petroleum"] = 1}, results = {sulfur = 2}, time = 2,
                    order = "c"},
  ["rts-engine"] = {category = "rts-age2", cost = {["steel-plate"] = 1, ["iron-gear-wheel"] = 1, ["iron-plate"] = 2},
                    results = {["engine-unit"] = 1}, time = 6, order = "d"},
  ["rts-advanced-circuit"] = {category = "rts-age2", cost = {["electronic-circuit"] = 2, ["plastic-bar"] = 2,
                              ["copper-cable"] = 3}, results = {["advanced-circuit"] = 1}, time = 6, order = "e"},
  ["rts-steel-beam"] = {category = "rts-age2", cost = {["steel-plate"] = 3}, results = {["rts-steel-beam"] = 2},
                        time = 4, order = "f"},
  ["rts-concrete"] = {category = "rts-age2", cost = {["stone-brick"] = 4, stone = 2}, results = {concrete = 4},
                      time = 4, order = "g"},
  -- Age II science kit: an engine (steel, gear), an advanced circuit (plastic from oil, circuits from copper and iron)
  -- and sulfur (oil): goods from at least three production stages.
  ["rts-science-industrial"] = {category = "rts-science", cost = {["engine-unit"] = 1, ["advanced-circuit"] = 1,
                                sulfur = 1}, results = {["rts-science-industrial"] = 2}, time = 12, order = "c"},
  -- Age II unit kit (barracks): balance.units["rts-armoured-car"]
  ["rts-armoured-car-kit"] = {category = "rts-units", cost = balance.units["rts-armoured-car"].cost,
                              results = {["rts-armoured-car-kit"] = 1}, time = balance.units["rts-armoured-car"].time,
                              order = "h"},

  -- Districts (compressed recipes, intermediate steps skipped): about twice the throughput of the machines they
  -- replace and more output per input (Age II goods at least E.district_efficiency x per raw plate; Age I goods
  -- 1.2-1.5x), so the industrial chain is the efficient road to an Age II army.
  ["rts-dsm-iron"] = {category = "rts-district-smelting", cost = {["iron-ore"] = 10},
                      results = {["iron-plate"] = 12}, time = 8, order = "a"},
  ["rts-dsm-copper"] = {category = "rts-district-smelting", cost = {["copper-ore"] = 10},
                        results = {["copper-plate"] = 12}, time = 8, order = "b"},
  ["rts-dsm-brick"] = {category = "rts-district-smelting", cost = {stone = 10}, results = {["stone-brick"] = 6},
                       time = 6, order = "c"},
  ["rts-dst-steel"] = {category = "rts-district-steel", cost = {["iron-plate"] = 6},
                       results = {["steel-plate"] = 4}, time = 8, order = "a"},
  ["rts-dst-steel-ore"] = {category = "rts-district-steel", cost = {["iron-ore"] = 6, coal = 1},
                           results = {["steel-plate"] = 4}, time = 10, order = "b"},
  ["rts-dci-circuit"] = {category = "rts-district-circuits", cost = {["iron-plate"] = 2, ["copper-plate"] = 3},
                         results = {["electronic-circuit"] = 3}, time = 3, order = "a"},
  ["rts-dci-cable"] = {category = "rts-district-circuits", cost = {["copper-plate"] = 5},
                       results = {["copper-cable"] = 15}, time = 2, order = "b"},
  ["rts-del-advanced-circuit"] = {category = "rts-district-electronics", cost = {["electronic-circuit"] = 2,
                                  ["plastic-bar"] = 2, ["copper-plate"] = 1}, results = {["advanced-circuit"] = 2},
                                  time = 4, order = "a"},
  ["rts-dpe-plastic"] = {category = "rts-district-petrochem", cost = {["rts-crude-oil"] = 3, coal = 1},
                         results = {["plastic-bar"] = 8, sulfur = 2}, time = 4, order = "a"},
  ["rts-dpe-sulfur"] = {category = "rts-district-petrochem", cost = {["rts-crude-oil"] = 2}, results = {sulfur = 10},
                        time = 3, order = "b"},
  ["rts-den-engine"] = {category = "rts-district-engines", cost = {["steel-plate"] = 2, ["iron-plate"] = 3},
                        results = {["engine-unit"] = 2}, time = 8, order = "a"},
  ["rts-dmu-magazine"] = {category = "rts-district-munitions", cost = {["iron-plate"] = 10},
                          results = {["firearm-magazine"] = 15}, time = 4, order = "a"},
  ["rts-dmu-explosives"] = {category = "rts-district-munitions", cost = {coal = 4, ["iron-plate"] = 2},
                            results = {["rts-explosives"] = 4}, time = 4, order = "b"},
  -- vanilla rail (m1-rails' item). Phase 5 M2 integration: 3 rails per steel (the factory makes 2) and unlocked by
  -- Railways in Age I (scripts/ages.lua RAILWAYS_EARLY)
  ["rts-dra-rail"] = {category = "rts-district-rails", cost = {["steel-plate"] = 4, stone = 4},
                      results = {rail = 12}, time = 4, order = "a"},
  ["rts-dra-beam"] = {category = "rts-district-rails", cost = {["steel-plate"] = 3},
                      results = {["rts-steel-beam"] = 4}, time = 3, order = "b"},
  ["rts-dco-concrete"] = {category = "rts-district-construction", cost = {["stone-brick"] = 5, stone = 2},
                          results = {concrete = 10}, time = 4, order = "a"},
  ["rts-dco-wall"] = {category = "rts-district-construction", cost = {["stone-brick"] = 8},
                      results = {["rts-wall"] = 10}, time = 4, order = "b"},
  ["rts-dsc-basic"] = {category = "rts-district-science", cost = {["iron-plate"] = 4, ["copper-plate"] = 2},
                       results = {["rts-science-basic"] = 3}, time = 8, order = "a"},
  ["rts-dsc-advanced"] = {category = "rts-district-science", cost = {["electronic-circuit"] = 4, ["steel-plate"] = 2},
                          results = {["rts-science-advanced"] = 3}, time = 12, order = "b"},
  ["rts-dsc-industrial"] = {category = "rts-district-science", cost = {["engine-unit"] = 2, ["advanced-circuit"] = 2,
                            sulfur = 2}, results = {["rts-science-industrial"] = 6}, time = 18, order = "c"},
}

-- The normal AI (scripts/ai/age_up.lua): make targets of its capital per age (an archetype template), the districts
-- it builds once it reaches Age II, and when its "works" factory (an auto-recipe factory for those targets) goes up.
E.ai = {
  works_after = 5 * 60,      -- seconds after the commander started
  district_gap = 60,         -- seconds between two district orders
  capital = {
    [1] = {["iron-gear-wheel"] = 20, ["electronic-circuit"] = 30},
    -- Age II: the Armoured car's engines and steel beams first
    [2] = {["iron-gear-wheel"] = 20, ["electronic-circuit"] = 40, ["steel-plate"] = 40, ["engine-unit"] = 10,
           ["rts-steel-beam"] = 10},
  },
  districts = {"rts-district-steel", "rts-district-engines", "rts-district-rails"},
  -- Phase 5 M1 integration: with a mining town (scripts/ai/towns.lua) shipping ore by train, a Smelting works second
  -- (four Smelting works take about 300 ore a minute: what the town's direct slots load)
  town_districts = {"rts-district-steel", "rts-district-smelting", "rts-district-smelting", "rts-district-engines",
                    "rts-district-smelting", "rts-district-rails", "rts-district-smelting"},
  car_weight = 3,            -- Age II: Armoured car weight in the barracks mix (ai/mix.lua; walkers are 1-2)
  age1_army = 40,            -- no Age I units beyond this army size (the soft cap makes them dear) unless threatened
  -- Phase 5 M1 integration: below this army size the AI does not save for districts, its barracks never yield plates
  -- to factories and its mining town waits (the aggressive AI lost its capital while the Charter, its town and its
  -- districts took every plate)
  min_army = 20,
}

for name, b in pairs(E.buildings) do balance.buildings[name] = b end
balance.buildings["rts-project-site"] = {kind = "project", health = E.charter.site_health}

-- m1-rails (docs/qa/phase5-rails-notes.md): haulers cost fuel and carry less at nation scale, trains carry a lot.
balance.nation = balance.nation or {}
balance.nation.hauler_slots = 10          -- base cargo slots of a hauler (research adds its bonus on top)
balance.nation.hauler_tiles_per_coal = 40 -- a hauler takes 1 coal per this many tiles from the hub it departs
balance.nation.rails = {
  -- factory recipes (category rts-buildings), unlocked by the Railways technology
  depot = {cost = {["iron-plate"] = 40, ["steel-plate"] = 10, ["copper-plate"] = 10}, time = 10, health = 1500,
           supply_cap = 10},
  -- recipe rts-rail -> 2 "rail" (Phase 5 M2 integration: 1 steel, was 2; steel was what kept AI lines closed until
  -- minute 24-27)
  rail = {cost = {["steel-plate"] = 1, ["stone"] = 1}, count = 2, time = 2},
  locomotive_kit = {cost = {["iron-plate"] = 40, ["steel-plate"] = 10, ["electronic-circuit"] = 10}, time = 10},
  cargo_wagon_kit = {cost = {["iron-plate"] = 20, ["steel-plate"] = 5}, time = 6},
  construction_wagon_kit = {cost = {["iron-plate"] = 30, ["steel-plate"] = 10}, time = 8},
  -- bill of a line, in rail items: track pieces cost their vanilla rail count (straight 1, half-diagonal 2,
  -- curves 3); bridges and signals are paid in rails too, so a construction wagon only ever carries rails
  support_rails = 10, ramp_rails = 20, signal_rails = 2,
  build_rate = 10,         -- pieces a construction train lays per second
  build_reach = 48,        -- tiles from the nearest locomotive to the piece being laid (the crew works ahead)
  transfer_rate = 200,     -- items per second per wagon between a depot network and a wagon
  fuel_target = 20,        -- coal per locomotive after a refuel at a depot
  starter_fuel = 10,       -- coal a new locomotive takes from the depot network
  cargo_wagons = 2,        -- a cargo train is locomotive + 2 wagons + locomotive (double-headed, single track)
  signal_spacing = 80,     -- tiles of ground track between bidirectional signal pairs
  ai_min_distance = 150,   -- AI: a hub or city this far from the capital gets a line (lead, 2026-10-16)
}
-- The depot is a hub subtype (kind "hub"), so scripts/supply.lua already counts it like a hub (+10). Listed here so the
-- on_entity_damaged filter (scripts/research.lua) covers it: the AI defends its depots like its hubs.
balance.buildings["rts-depot"] = {kind = "hub", supply_cap = balance.nation.rails.depot.supply_cap}

-- Phase 5 M2 people (m2-people, docs/PHASE5-M2.md section 3 "population.lua / labor.lua", docs/qa/phase5-people-notes.md):
-- residents, needs, growth, tiers by population, housing, the food chain, goods, staffing through hidden labor modules,
-- recruits. Nation mode only: scripts/population.lua and scripts/labor.lua do nothing in Skirmish.
balance.nation.people = {
  -- Residents. A city's population is a script number (storage.population[city_id].pop).
  -- Residents at founding (a new city: the settlers it receives). The capital starts with 200 in a 200-resident centre
  -- instead of the contract's 120: with 120 (72 workers) the AI's opening (3-4 factories, 2 labs, 11 extractors and
  -- smelters: 108 jobs at 5:00) left its labs and factories empty, and it researched nothing by 6:00 and missed Age II.
  start = {capital = 200, city = 40, city_state = 120},
  settlers = 40,           -- residents a founding moves out of the source city (the charter stands for them)
  -- Food and goods a city starts with in its market network (a new city's settlers bring 10 minutes of rations), so
  -- nobody starves before the first farm and bakery stand
  start_stock = {capital = {["rts-rations"] = 300, ["rts-goods"] = 100}, city = {["rts-rations"] = 40}},
  min_pop = 20,            -- founding and the draft never take a city below this many residents
  workforce = 0.6,         -- share of the residents who work
  housing = {capital = 200, city = 40}, -- the capital's centre and a City Center house this many by themselves
  -- Tiers by population: village from 20, town from 100, city from 400. A higher tier is reached at the next growth
  -- pass; a city drops a tier only after `down_ticks` below `down_share` of its tier's threshold (study 3.4).
  tiers = {20, 100, 400},
  down_share = 0.8,
  down_ticks = 2 * 60 * 60,
  -- Growth per minute while every need is met at grow_at or more and housing has room: `growth` of the housing
  -- capacity (a city with room fills in 25 minutes; a full one grows as fast as it builds houses), scaled by the mood
  -- (happiness / mood_base, clamped to mood_max). Between hold_at and grow_at nothing changes. Below hold_at rations:
  -- -starve of the residents per minute; without power at town tier and above: -dark per minute; residents beyond
  -- the housing leave at `homeless` of the excess per minute.
  growth = 0.04, grow_at = 0.9, hold_at = 0.5, starve = 0.03, dark = 0.01, homeless = 0.1,
  mood_base = 75, mood_max = 1.25,
  -- Below hold_at rations only this share of the workforce works (hungry workers: the lowest-priority buildings stop
  -- at once, not after the residents have left).
  starving_work = 0.5,
  -- Needs: per[n] residents use 1 item per minute, from tier `from` on; keep = the default keep policy of the city's
  -- market network (the City Center's or the capital CC's hub policy). Consumed every needs_period ticks.
  needs = {
    {item = "rts-rations", per = 10, from = 1, keep = 50},
    {item = "rts-goods", per = 25, from = 2, keep = 20},
  },
  needs_period = 60 * 60,
  growth_period = 10 * 60,   -- one growth / tier pass per city this often (staggered by city id)
  -- Happiness 0..100: base, + rations (-1..+1 around hold_at..1 met) x rations, + goods x goods (town tier and above),
  -- + power (town tier and above, -power without), + crowded when residents exceed the housing. External moods
  -- (population.set_mood: taxes, debt, unrest) are added. It drives growth (mood) and taxes (treasury.lua) only.
  happiness = {base = 50, rations = 25, goods = 15, power = 10, crowded = -10},
  -- Power: a 1 kW hidden consumer (rts-city-demand, 2 kW input) under every centre; its 2 kJ buffer below `power_ok`
  -- = no power, which happens only while the network meets less than half of its demand.
  power_ok = 0.5,
  -- Housing buildings: residents each houses (only on its city's land); apartments need Age II and a town.
  houses = {["rts-house"] = 20, ["rts-apartment"] = 80},
  apartment_tier = 2,
  -- Food chain (base game): the farm makes 1 grain every farm_time s (no input), limited per city by tier farm slots;
  -- the bakery turns 2 grain into 3 rations in 3 s; the fishing hut makes fishing_per_minute rations with water within
  -- fishing_water tiles of its edge. Factory recipes: goods (household goods) and bricks from stone (the AI never
  -- smelts bricks, and the goods need one).
  farm_time = 4,
  farm_slots = {3, 6, 10},
  bakery = {grain = 2, rations = 3, time = 3},
  fishing_per_minute = 6,
  fishing_water = 3,
  goods = {cost = {["iron-plate"] = 1, ["copper-cable"] = 2, ["stone-brick"] = 1}, count = 2, time = 4},
  brick = {cost = {stone = 2}, count = 1, time = 2},
  spoil_minutes = 15,       -- rations spoil (into nothing) only with the "spoiling" feature flag (Space Age)
  buildings = {
    -- Small house: stone + iron instead of the contract's stone brick (the AI mines stone but makes no bricks in Age I,
    -- as for the City charter); apartment: Age II, bricks + steel + goods.
    ["rts-house"] = {kind = "house", cost = {stone = 15, ["iron-plate"] = 5}, time = 4, health = 400, size = 3},
    ["rts-apartment"] = {kind = "house", cost = {["stone-brick"] = 30, ["steel-plate"] = 10, ["rts-goods"] = 10},
                         time = 8, health = 1200, size = 5, age = 2},
    -- farms and bakeries need no electricity (their cost is labor): 150 + 200 kW per pair pushed the AI capitals into
    -- brownouts, and a brownout stops city growth (-1 %/min at town tier and above)
    -- (iron is what every early build order lacks; stone piles up)
    ["rts-farm"] = {kind = "farm", cost = {["iron-plate"] = 20, stone = 30}, time = 6, health = 600, size = 5},
    ["rts-bakery"] = {kind = "bakery", cost = {["iron-plate"] = 20, ["copper-plate"] = 10, stone = 15}, time = 6,
                      health = 500, size = 3},
    ["rts-fishing-hut"] = {kind = "fishing", cost = {["iron-plate"] = 20, stone = 10}, time = 4, health = 300, size = 3},
  },
  -- Labor. Jobs per building (by registry kind, entity names override); 0 = no workers (turrets, walls, poles,
  -- stockpiles, rails, hubs, depots, houses, City Centers).
  jobs = {
    kind = {extractor = 4, smelter = 4, factory = 12, barracks = 12, lab = 8, farm = 6, bakery = 6, fishing = 4,
            district = 16, ["steam-plant"] = 4, pumpjack = 4},
    name = {["rts-refinery"] = 8, ["rts-chemical-plant"] = 8},
  },
  -- Labor families (the priority list) by kind, entity names override.
  families = {
    kind = {barracks = "military", ["steam-plant"] = "power", farm = "food", bakery = "food", fishing = "food",
            extractor = "extraction", pumpjack = "extraction", smelter = "metallurgy", lab = "research",
            factory = "services", district = "services"},
    name = {["rts-refinery"] = "chemistry", ["rts-chemical-plant"] = "chemistry",
            ["rts-district-smelting"] = "metallurgy", ["rts-district-steel"] = "metallurgy",
            ["rts-district-engines"] = "metallurgy", ["rts-district-rails"] = "metallurgy",
            ["rts-district-circuits"] = "electronics", ["rts-district-electronics"] = "electronics",
            ["rts-district-petrochem"] = "chemistry", ["rts-district-munitions"] = "military",
            ["rts-district-construction"] = "services", ["rts-district-science"] = "research"},
  },
  priorities = {"military", "power", "food", "extraction", "metallurgy", "chemistry", "electronics", "research",
                "services"},
  staffing_period = 5 * 60,   -- every city's staffing is recomputed this often (staggered)
  steps = 5,                  -- staffing steps of 1 / steps (20 %): hidden modules rts-labor-20 .. rts-labor-80
  -- Draft: recruits = unemployed workers + `draft` of the employed ones. Levels the panel offers; AI by doctrine.
  draft = {default = 0.2, levels = {0, 0.1, 0.2, 0.3, 0.5},
           doctrine = {economic = 0.1, turtle = 0.2, aggressive = 0.3}},
  -- AI governor (scripts/population.lua people_ai): keep rations / goods for keep_minutes of need, one farm per
  -- farm_per residents of the nation (a bakery per bakery_farms farms), a house when free housing < free_housing,
  -- labor priorities, a supply hauler from the capital to every other city.
  ai = {
    -- start_after: the start stock (300 rations, 15 minutes for 200 residents) carries the capital through the AI's
    -- opening; a farm, bakery and houses at 2:00 cost it a minute of its first iron and delayed its Age II
    -- houses from house_after (10 iron + 10 stone each; residents need housing ahead of them to grow)
    -- (Phase 5 M2 ai: farm_per 200, was 150: a farm and its share of a bakery feed about 225 residents, and from the
    -- second farm on the governor adds them by residents, not by stock)
    keep_minutes = 2, farm_per = 200, bakery_farms = 2.5, free_housing = 20, start_after = 300, house_after = 150,
    -- Phase 5 M2 ai (scripts/ai/governor.lua): the capital ships rations and goods above its keep + export_extra (50
    -- left the towns at 100 residents without goods: the capital rarely held that much more)
    period = 5 * 60, house_gap = 10, max_queued = 3, export_extra = 10, brick_target = 20,
    -- Phase 5 M2 ai: a farm when the capital's rations run out within food_minutes, the first goods works when its
    -- goods run out within goods_minutes (the start stock lasts 12-15 minutes); a town at the goods need for
    -- stall_ticks while the capital has none to ship gets a second goods works (at most goods_works_max)
    -- (houses stay from 2:30: growth is 4 % of the housing a minute, and from 5:00 only cost seed 501's aggressive AI 30
    -- workers in minutes 8-16 and Industrialisation 4 minutes)
    food_minutes = 6, food_urgent = 3, goods_minutes = 6, stall_ticks = 3 * 60 * 60, goods_works_max = 2,
    -- before the capital's steel flows: the goods works only below goods_urgent minutes of goods, the towns' supply
    -- haulers only while a town holds less than town_rations_minutes of rations
    goods_urgent = 2, town_rations_minutes = 4,
    -- while Industrialisation is researched or the Charter is built: goods for this many minutes of need only
    age2_focus_minutes = 1,
    -- a town gets its own farm and bakery from town_farm_pop residents (or when its rations run short), inside its
    -- City Center's logistic area (town_area tiles around it; the turrets go there too)
    town_farm_pop = 60, town_area = 13,
    -- Phase 5 M3 ai (wave B.2): then a ring this wide (still inside the City Center's 16-tile logistic area); the planner
    -- founds a city only with a farm spot within it
    town_area_far = 15,
    -- (wave B.2) copper cable the capital keeps for its fixed goods works (2 per 2 goods)
    goods_cable = 40,
    -- while the AI's rail line is built, houses wait below this much stone (its rails take 1 stone per 2)
    rail_stone = 150,
    -- below stone_low stone (once the steel flows) one more stone extractor of the start line, at most every stone_gap
    stone_low = 100, stone_gap = 2 * 60 * 60,
    -- Phase 5 M3 ai: and one more copper extractor (and slot) below copper_low copper plates (was a code default)
    copper_low = 30,
    -- from start_after, houses while the housing is below the city's jobs / workforce share + job_margin residents
    -- (the margin keeps recruits for the army; houses beyond it only fed goods demand)
    job_margin = 80, house_radius = {24, 40, 56},
    -- Phase 5 M3 ai: capital_house_pref = {x towards the back, y} and capital_house_radius = {rings} move the capital's
    -- houses out of the CC's logistic area (nil: as in M2; tried at {38, 30} / {56, 72}: the houses then blocked the
    -- exits of the rail depots, which stand 26-74 tiles out, and a trunk line's survey failed for 40 minutes)
    capital_house_pref = nil,
    -- a second factory on Auto at the capital from start_after: goods and their bricks took the works factory's time
    -- from the circuits of the Industrialisation kits (the economic AI researched it in 7.5 minutes instead of 3.5)
    goods_works = true,
    -- houses in stock at the capital from start_after (a make target: the Auto factories make them, so the builder
    -- factory keeps to the build order)
    house_stock = 3,
    priorities = {"power", "food", "extraction", "metallurgy", "research", "military", "services", "electronics",
                  "chemistry"},
    -- Phase 5 M3 ai: the order from Age II on (ai/governor.lua)
    priorities_age2 = {"power", "food", "extraction", "metallurgy", "electronics", "chemistry", "research", "machinery",
                       "military", "services", "construction"},
    -- pinned first: the builder and workshop factories (the two lowest fixed ones), the works factory (Auto) and the
    -- first `pin_labs` labs; nothing else gets built or researched without them
    pin_labs = 1,
  },
}
for name, b in pairs(balance.nation.people.buildings) do balance.buildings[name] = b end
-- Phase 5 M2 diplomacy (docs/PHASE5-M2.md §3 "diplomacy.lua / wars.lua"; scripts/diplomacy.lua, scripts/wars.lua). Pure
-- data, read in Nation mode only. Relation events and the AI decision table follow docs/research/scale/rails-trade.md
-- §5.2-5.3; war score, weariness and victory war-ai-performance.md §2.8 and decision D6.
balance.nation = balance.nation or {}
balance.nation.diplomacy = {
  start_state = "peace",       -- every pair of nations at match start ("war" = the M1 free-for-all)
  ceasefire_minutes = 3,       -- a ceasefire becomes peace (white treaty) after this long unless the war resumes
  truce_minutes = 10,          -- after a treaty the AI declares no war on the same nation for this long
  alliance_lock_minutes = 10,  -- no betrayal: the AI leaves no alliance younger than this
  answer_ticks = {600, 1200},  -- an AI answers a proposal after 10-20 s
  proposal_ttl = 120 * 60,     -- a proposal to a player expires (declined) after this long
  relation = {
    trade_per_1000 = 1, trade_cap_per_min = 10,
    contract_delivered = 3, contract_missed = -8,
    common_enemy_per_min = 2,
    border_per_10_supply = -5,     -- per minute: their units on my land (not allies, not at war with me)
    attacked_first = -20, attacked_per_1000 = -1,
    gift_per_1000 = 4,             -- halved for every gift of the last 10 minutes
    declared_on = -30,             -- the victim's opinion of the aggressor
    declared_others = -5,          -- every other nation (not at war with the victim) about the aggressor
    ceasefire_broken = -20,        -- a war declared during a ceasefire, on top of declared_on
    alliance_left = -20,           -- the left ally's opinion
    decay_per_min = 1,             -- towards the doctrine baseline
    -- rivalry (war-ai-performance.md §4.5 "border friction"): per minute towards the nearest neighbour by capital
    -- distance (nearest), half towards any other within near_factor times that distance (near), times the doctrine
    -- weaker: towards any nation it out-powers (ratio above its war_ratio) and can reach (opportunism)
    friction = {nearest = 1, near = 0.5, near_factor = 1.5, weaker = 1},
    friction_doctrine = {economic = 0.5, aggressive = 2, turtle = 0.5, human = 0},
  },
  baseline = {economic = 10, aggressive = -10, turtle = 5, human = 0},
  -- the AI decision table: declare war when relation < war_r and power ratio > war_ratio; offer or accept a ceasefire
  -- when ratio < cf_ratio or weariness > cf_weary (%); offer an alliance when relation > ally_r with a common enemy
  doctrine = {
    economic = {war_r = -50, war_ratio = 1.4, cf_ratio = 0.8, cf_weary = 30, ally_r = 40},
    aggressive = {war_r = -20, war_ratio = 1.0, cf_ratio = 0.5, cf_weary = 50, ally_r = 60},
    turtle = {war_r = -60, war_ratio = 1.6, cf_ratio = 0.9, cf_weary = 25, ally_r = 30},
  },
  min_war_minutes = 5,           -- the AI offers no ceasefire before its war is this old
  offer_cooldown_minutes = 2,    -- the AI repeats a declined offer to the same nation no sooner than this
  long_war_minutes = 30,         -- a war this old: the AI accepts a white peace unless its war score is above
  long_war_score = 20,           --   this
  peace_from_ceasefire_r = -60,  -- during a ceasefire the AI accepts a white peace above this relation
  terms_weary_factor = 1.5,      -- the AI pays tribute / accepts paying terms past this times its cf_weary
  tribute_offer = {cr_per_min = 40, minutes = 10}, -- what a weary AI offers after two declined ceasefires
  break_alliance_r = -10,        -- the AI leaves an alliance (after the lock) below this relation
  ally_accept_slack = 10,        -- the AI accepts an alliance from ally_r - this
  contract_min_r = 0,            -- the AI accepts contracts from this relation
  border_decline_supply = 10,    -- "you have N units inside our border": declines alliances and contracts
  power = {
    turret = 2, production_divisor = 500, cache_ticks = 300,
    turret_kinds = {turret = true, ["laser-turret"] = true}, -- registry kinds (the Bunker is "turret")
    skip_kinds = {hauler = true, commander = true},
    values = {["iron-plate"] = 1, ["copper-plate"] = 1, ["steel-plate"] = 5, ["electronic-circuit"] = 4,
              ["rts-explosives"] = 3, ["plastic-bar"] = 3},
  },
  -- wars (scripts/wars.lua): war score per event, weariness, goals
  wars = {
    unit_supply = 1,             -- per supply point of enemy units destroyed
    building = {default = 1, wall = 0, extractor = 2, smelter = 2, factory = 4, barracks = 4, district = 6, lab = 3,
                hub = 3, cc = 10, turret = 2},
    city = 20, city_per_pop = 0.1, -- per captured city, plus per resident
    city_pop_fallback = {40, 150, 400}, -- residents by tier while scripts/population.lua is absent
    capital_per_min = 5,         -- holding the other side's original capital
    weariness = {window_minutes = 5, grace_minutes = 10, per_minute = 1, per_city = 15, capital = 20},
    capital_hold_minutes = 10,   -- goal "capital": hold the capital this long
    tribute = {cr_per_min = 50, minutes = 10, score = 30}, -- goal "tribute": war score needed and the treaty's terms
    border_score = 25,           -- goal "border" without cities in it: war score needed
    max_minutes = 45,            -- a war this old ends in a white peace
  },
  victory = {
    step_ticks = 600,            -- wars.victory_step every 10 s
    -- Phase 5 M2 integration: 45 % of the claimable cells (60 % is about 53 % of a 2048 world, out of reach), or twice
    -- the land of the next coalition with at least 3 % of the claimable cells (a capital and five towns), for 3 minutes
    territory_share = 0.45, territory_lead = 2, territory_lead_min = 0.03, territory_minutes = 3,
    -- Phase 5 M3 age3: Conquest+Space (the default: Conquest, or the third stage of the Space Program) and Any (every
    -- rule: Conquest, Territory, Space, Score at the time limit)
    modes = {"conquest_space", "conquest", "territory", "score", "any"}, default_mode = "conquest_space",
    time_limits = {60, 90, 120, 0}, default_time_limit = 0, score_default_limit = 60, -- minutes; 0 = unlimited
  },
}

-- Phase 5 M2 ai: the nation strategist (scripts/ai/nation.lua, docs/qa/phase5-ai-notes.md). Every `period` ticks per AI
-- nation; the doctrine table above once every diplomacy_every passes. Sales hold a good while its price is below
-- sell_floor x p0 (easy: any price, and its capital ships from easy_dump x the surplus thresholds); coal_reserve stays
-- at the port for the haulers. Contracts: n x deliveries of a lacking ore every interval seconds at contract_price x
-- the market price, from a nation at peace with relation >= contract_min_r, one at a time, a new proposal at most every
-- contract_gap ticks and the same seller and good again after contract_retry. Garrison: when a war starts,
-- garrison_share of the idle army (garrison_min..garrison_max units) enters the capital. City-state operations from
-- city_state_from of match time, with no rival division within capture_safe tiles of the capital.
balance.nation.diplomacy.ai = {
  period = 600, diplomacy_every = 6,
  sell_floor = 0.75, easy_dump = 0.5, coal_reserve = 300, -- (coal at the port is the haulers' fuel home: not sold)
  contract_n = 100, contract_deliveries = 5, contract_interval = 120, contract_price = 1.0, contract_min_r = 0,
  contract_gap = 3 * 60 * 60, contract_retry = 10 * 60 * 60, contract_from = 10 * 60 * 60,
  contract_keep = 20 * 60 * 60, -- goods bought by contract are not sold at the port for this long after it was made
  garrison_share = 0.25, garrison_min = 4, garrison_max = 8,
  city_state_from = 20 * 60 * 60, capture_safe = 400,
  -- opportunity wars (on top of the doctrine table, matches of opportunity_nations or more): a rival's town within
  -- opportunity_reach tiles of the capital with at most `defenders` defence points (units, garrison, 4 per gun turret
  -- within opportunity_turret_radius), relation below r and power ratio above `ratio`, an idle army of `pool`; from
  -- opportunity_from, checked every opportunity_period, at most one per opportunity_gap. nil = off.
  -- (Phase 5 M3 ai: `strong` = above that power ratio the relation limit and the defence points rise to its r and
  -- defenders: economic and turtle nations go for a rival's town too when they far outclass it)
  opportunity = {
    aggressive = {r = 0, ratio = 0.8, defenders = 8, pool = 12},
    economic = {r = -25, ratio = 1.2, defenders = 4, pool = 16, strong = {ratio = 1.5, r = 0, defenders = 12}},
    turtle = {r = -30, ratio = 1.3, defenders = 4, pool = 20, strong = {ratio = 1.6, r = -10, defenders = 12}},
  },
  opportunity_nations = 3,
  opportunity_from = 20 * 60 * 60, opportunity_period = 60 * 60, opportunity_gap = 20 * 60 * 60,
  opportunity_reach = 1400, opportunity_turret_radius = 30,
}

-- Phase 5 M2 treasury (m2-treasury, docs/PHASE5-M2.md section 3 "treasury.lua / market.lua", decisions D1 and D5;
-- docs/qa/phase5-treasury-notes.md). The treasury is a script number per nation (crowns, cr); nothing is built with
-- money. Nation mode only. Read by scripts/treasury.lua, scripts/market.lua, scripts/marketgui.lua and
-- prototypes/trade.lua.
balance.nation = balance.nation or {}
balance.nation.treasury = {
  start = 1500,                -- cr every nation starts with
  step = 600,                  -- ticks between two flow applications (tax and upkeep are per-minute rates / 6)
  tax = {
    per_resident = 0.2,        -- cr per resident per minute (workers)
    levels = {low = 0.6, normal = 1.0, high = 1.4},
    happiness = {at0 = 0.5, at100 = 1.2}, -- tax multiplier at happiness 0 and 100 (linear between)
    default_happiness = 70,    -- without scripts/population.lua
    hard_bonus = 0.2,          -- hard AI: +20 % tax income (the only M2 cheat)
    mood = {low = 8, normal = 0, high = -8}, -- happiness from the tax level (population.set_mood(force, "tax", n))
  },
  -- Residents per city when scripts/population.lua is not loaded (M2 people): by city tier, the capital at least
  -- `capital`. population.of(city_id).pop wins when that module exists.
  fallback_pop = {capital = 200, tier = {40, 120, 400}},
  upkeep = {
    age1 = 1, age2 = 4,        -- cr per building per minute (Age II: the names in balance.nation.economy.buildings)
    paused = 0.5,              -- a crafting machine without a recipe or switched off by script pays this share
    -- kinds and names that pay nothing: walls, stockpiles, power and rolling stock (transport pays for trains), the
    -- capital Command Center, City Centers and trade posts (the state's own buildings), project sites
    skip_kinds = {wall = true, stockpile = true, solar = true, accumulator = true, train = true, project = true,
                  cc = true},
    skip_names = {["rts-city-center"] = true, ["rts-trade-post"] = true,
                  -- Phase 5 M2 integration: homes and food pay no upkeep (residents already cost needs; a farm is
                  -- labor, and the treasury curve must not punish feeding a city)
                  ["rts-house"] = true, ["rts-apartment"] = true, ["rts-farm"] = true, ["rts-bakery"] = true,
                  ["rts-fishing-hut"] = true},
    crafter_kinds = {factory = true, barracks = true, district = true},
  },
  -- Phase 5 M3 integration (balance pass): 1.2 (was 1): with m3-ai's AI keeping a reserve no nation went into debt
  army = {per_supply = 1.2, free = 0}, -- cr per supply point of military units per minute (haulers excluded)
  transport = {locomotive = 2, rail_tiles = 100}, -- cr per locomotive per minute, 1 cr per this many tiles of line
  interest = {rate = 0.05, period = 5 * 60 * 60}, -- 5 % of the debt every 5 minutes
  credit = {minutes = 10, min = 500, -- credit line: 10 minutes of gross income (tax + exports), at least `min`
            decay = 0.99},     -- Phase 5 M3 integration: it falls at most 1 % per step (about 6 % a minute) when income falls
  stages = {unpaid = 60, unrest = 180}, -- seconds below 0 before stage 2 (unpaid wages) and stage 3 (unrest)
  unrest_happiness = -25,      -- stage 3: population.set_mood(force, "debt", -25) (scripts/population.lua)
}
balance.nation.market = {
  -- Anchors (deep-economy.md section 4.2); every other tradeable good is derived at match start:
  -- p0 = markup x (sum of the ingredients' p0 + per_second x recipe seconds) / products.
  p0 = {
    ["iron-ore"] = 0.4, ["copper-ore"] = 0.4, coal = 0.5, stone = 0.3, ["iron-plate"] = 1, ["copper-plate"] = 1,
    ["steel-plate"] = 3.3, ["electronic-circuit"] = 4, ["plastic-bar"] = 3, sulfur = 2, ["engine-unit"] = 14,
    ["advanced-circuit"] = 18, ["processing-unit"] = 70, ["low-density-structure"] = 40, ["rts-explosives"] = 2,
    ["rts-crude-oil"] = 0.5, ["stone-brick"] = 0.7,
    -- M2 people goods (prototypes/people.lua), when they exist
    ["rts-rations"] = 1.5, ["rts-goods"] = 15, ["rts-grain"] = 0.4,
  },
  derive = {markup = 1.1, per_second = 0.1, depth = 8},
  -- World stock S0 per good: about an hour of world trade, S0 = value / p0 clamped (steel 3,000 by override).
  s0 = {value = 10000, min = 200, max = 20000, override = {["steel-plate"] = 3000}},
  exponent = 0.6,              -- p = p0 x (S0 / S) ^ exponent
  clamp = {0.4, 3},            -- ... clamped to this range of p0
  drift = 0.05,                -- every drift_period, S moves this share back towards S0
  drift_period = 60 * 60,
  history = 10,                -- price samples kept (one per drift_period: the last 10 minutes)
  sell_factor = 0.9,           -- exports pay 0.9 x the curve price
  buy_factor = 1.1,            -- imports cost 1.1 x
  import_delay = 30 * 60,      -- ticks until bought goods appear at the port
  -- commerce cap: cr traded (sold + bought) per minute, rolling 60 s
  cap = {base = 300, per_port = 150, per_level = 0.25, window = 60 * 60},
  capture = {range = 4, ticks = 600, period = 30}, -- like the ruin: a unit within 4 tiles for 10 s
  port_stock = {{"steel-plate", 300}, {"electronic-circuit", 100}, {"coal", 100}}, -- loot in a new trade post
  contract = {late_grace = 2 * 60 * 60, min_interval = 30, max_deliveries = 100},
  -- Commerce I / II (prototypes/trade.lua; Nation-only technologies): +per_level of the cap each
  commerce = {
    {name = "rts-commerce-1", kit = "rts-science-basic", count = 20, icon = "logistics-2"},
    {name = "rts-commerce-2", kit = "rts-science-advanced", count = 30, icon = "logistics-3",
     prerequisites = {"rts-commerce-1"}},
  },
  -- Normal AI (scripts/market.lua market.ai_step)
  ai = {
    period = 600,              -- ticks between two trade passes of one AI
    capture_timeout = 5 * 60 * 60, -- an envoy that has not taken its port in this long is released
    capture_retry = 60 * 60,   -- ticks between two envoys
    ports_wait = 3 * 60 * 60,  -- the first envoy waits for the world fill (every port placed) or this long
    surplus = {stone = 300, coal = 500, ["iron-ore"] = 800, ["copper-ore"] = 800, ["stone-brick"] = 200,
               ["iron-plate"] = 700, ["copper-plate"] = 600, ["steel-plate"] = 400},
    hauler_after = 12 * 60 * 60, -- the port route asks for its own hauler kit from then on (earlier only when the AI
                               -- wants haulers for its hubs anyway)
    port_keep = 400,           -- the port asks the hauler for this much of every surplus good
    -- Phase 5 M3 ai: goods the market AI never buys for a ledger shortfall (the nation makes them; a plate target of
    -- ai/age_up.lua only keeps the Smelting works on the town's ore)
    no_buy = {["iron-plate"] = true, ["copper-plate"] = true, ["iron-ore"] = true, ["copper-ore"] = true},
    coal_keep = 60,            -- coal the port keeps for the haulers' return trips (never sold)
    buy_after = 3 * 60 * 60,   -- a shortfall the AI cannot fill within this long is bought
    buy_horizon = 3,           -- minutes: a shortfall short > made per minute x horizon cannot be filled in time
    reserve = 500,             -- the AI never buys below this balance
    spend_share = 0.25,        -- share of the balance one purchase may cost
    keep_minutes = 10,         -- a raised Command Center keep for an import is restored after this long
    deficit_floor = 1500,      -- below this balance with a negative net: tax high, no imports, deficit mode
    -- Phase 5 M2 integration: hysteresis (the tax switched 17 and the deficit mode 22 times per nation-hour): deficit
    -- lasts until the balance is deficit_band above the floor or the net above deficit_net; a tax level holds tax_hold
    -- ticks unless a war starts or ends or happiness falls below happy_low
    deficit_band = 300, deficit_net = 10, tax_hold = 2 * 60 * 60,
    -- Phase 5 M3 age3 (D10; docs/qa/phase5-ai-notes.md section 6 item 3): the deficit mode starts below `enter` while
    -- the balance falls and ends only at `leave` (no exit on a positive minute any more); a tax level the AI chose holds
    -- tax_hold unless happiness drops below happy_low (low) or a war starts (high); a nation stays on a war footing
    -- (high) for war_footing ticks after its last war ended and then until the balance is back at `leave`; a low tax
    -- holds until happiness is happy_band above happy_low (the first 60-minute 4-nation run without the war footing:
    -- 3.5 switches per nation-hour, all of them around wars); Phase 5 M3 integration: at most max_per_hour switches in
    -- any hour unless happiness is below happy_low or the treasury in debt
    hysteresis = {enter = 1500, leave = 1500 * 1.4, tax_hold = 10 * 60 * 60, happy_band = 12,
                  war_footing = 15 * 60 * 60, max_per_hour = 2},
    deficit_surplus = 0.5,     -- deficit mode: the capital exports from this share of the surplus thresholds
    happy_low = 40,            -- tax low below this happiness
    -- Phase 5 M2 ai (scripts/ai/governor.lua): a town's export hauler takes its surplus to the port while the town holds
    -- more than town_export_start of its ore and plate together, until it holds less than town_export_stop
    town_export_start = 1500, town_export_stop = 300,
    war_window = 2 * 60 * 60,  -- without diplomacy: "at war" while an own group attacked or defended this recently
  },
}
balance.buildings["rts-trade-post"] = {kind = "hub", supply_cap = 0}
-- Phase 5 M2 war (docs/PHASE5-M2.md section 3 "warsupply.lua / capture.lua / garrison.lua"; docs/qa/phase5-war-notes.md):
-- supply points, supply crates and field depots, city capture, garrisons and troop trains. Nation mode only.
balance.nation.war = {
  -- Supply points (SP) per division, 0..sp_max. States: supplied (>= low), low (1 .. low - 1), out (0).
  sp_max = 100, sp_start = 100, low = 50,
  use = {idle = 0, moving = 2, engaged = 8, enemy_land = 2}, -- SP per minute (idle in own or neutral land: 0)
  engaged_ticks = 300,       -- a member that hit or was hit this recently makes its division "engaged"
  refill = {per_minute = 20, range = 64, sp_per_crate = 10}, -- within range (2 chunks) of a depot holding crates
  out = {share = 0.015, period = 600},  -- out of supply: 1.5 % of max health every 10 s
  loose_radius = 24,         -- a unit outside any division takes the state of the nearest division this close
  crate = {cost = {["iron-plate"] = 4, ["coal"] = 2}, time = 2},                            -- Age I recipe
  crate2 = {cost = {["iron-plate"] = 4, ["coal"] = 2, ["rts-explosives"] = 1}, time = 2},   -- Age II recipe
  field_depot = {cost = {["iron-plate"] = 30, ["stone"] = 20, ["copper-plate"] = 10}, time = 6, health = 600,
                 keep = 20},  -- a Commander-built hub subtype that keeps 20 crates; it adds no supply cap
  -- Troop trains (rails-trade.md section 3): a troop wagon holds 16 supply of units as records
  troop_wagon_kit = {cost = {["iron-plate"] = 30, ["steel-plate"] = 10}, time = 6},
  troop_wagon = {health = 800, capacity = 16, max_wagons = 3},
  embark_radius = 14,        -- tiles from a troop wagon at which a unit ordered to embark boards
  embark_wait = 30 * 60,     -- a loaded troop train leaves this long after the last boarding at the latest
  disembark_ring = 6,        -- tiles from the wagons where disembarked units appear
  disband_share = 0.5,       -- kits a disbanded train returns
  -- Capture (D4)
  capture = {subdue = 0.10, radius = 24, ticks = 20 * 60, period = 60, slice = 500, unrest_ticks = 60 * 60,
             pop_keep = 0.7, restart_health = 0.25, release_health = 0.5, siege_timeout = 60 * 60},
  -- Garrison: units inside a city as records; hidden turrets around the City Center, one per 4 points
  garrison = {points_per_turret = 4, max_turrets = 8, ring = 5, enter_radius = 14, sortie_health = 0.5,
              ammo = 20, ammo_period = 300},
  -- AI (ai/army.lua): crate keep at its hubs and depots, a crate make target at its capital, city targets
  ai = {crate_keep = 20, crate_target = 60, crates_from_age = 2, defenders_ratio = 0.6, defenders_radius = 40,
        period = 600,
        -- without a strategist hook (army.capture_ok, M2 wave B) a Nation AI starts capture operations from minute 45
        -- of the match, at most one per 15 minutes (a town lost earlier ends the rail economy of M1's 1v1 acceptance)
        capture_from = 45 * 60 * 60, capture_cooldown = 15 * 60 * 60,
        -- city-states: deliberate capture operations only (army.city_state_target): from Age II, at peace with every
        -- nation, a group of at least city_state_ratio x the garrison points (turret_points per live turret)
        city_state_ratio = 1.5, turret_points = 4,
        -- Phase 5 M2 ai (scripts/ai/governor.lua, ai/army.lua): gun turrets at a town as soon as its City Center
        -- stands (magazines kept there); a relief group (relief_share of the idle pool, at least relief_min) goes to a
        -- town attacked within relief_window ticks; city-state operations only on a city-state at most
        -- city_state_reach x as far from the capital as from the nearest rival capital, with no rival division within
        -- city_state_clear tiles of it
        town_turrets = 2, town_magazines = 20, relief_share = 0.5, relief_min = 6, relief_window = 20 * 60,
        city_state_reach = 0.8, city_state_clear = 150},
}
balance.buildings["rts-field-depot"] = {kind = "hub", cost = balance.nation.war.field_depot.cost,
                                        time = balance.nation.war.field_depot.time,
                                        health = balance.nation.war.field_depot.health}

-- Phase 5 M2 world (docs/PHASE5-M2.md §3 "world.lua additions / strategic.lua", docs/qa/phase5-world2-notes.md): the
-- scarcity portfolio, city-states, ruins, ports, chokes and the strategic layer of Nation worlds (scripts/world.lua,
-- scripts/strategic.lua). Pure data; the M1 world keys (main_totals, natural, specialties, contested, oil_*) stay
-- in scripts/world.lua.
balance.nation.world = {
  city_states = {[2] = 4, [3] = 5, [4] = 6},  -- per nation count: copper, the oil swamp, the coast, passes and fords
  city_state = {
    tier = 1,                                 -- village: 48 tiles of land (a town's 72 would reach the marching lines)
    -- turrets: 6 + 1 per 8 minutes, at most 10 (Phase 5 M2 integration: 4 + 1 per 10 minutes fell to 2-3 passing units)
    garrison = 6, garrison_every = 8 * 3600, garrison_max = 10,
    armor = 0.5,                              -- its City Center heals back this share of every hit (2x effective HP)
    -- Phase 5 M2 integration: its granary, put into its network when a nation captures it (scripts/world.lua; 84
    -- residents after the capture eat 8-9 rations a minute and, as a town, 3-4 goods: about 20 minutes for the captor's
    -- food line)
    food = {{"rts-rations", 180}, {"rts-goods", 40}},
    turret = "rts-turret", ring = 10,         -- around the City Center, fed from its network
    ammo_keep = 200,                          -- magazines kept in its network
    spawn_gap = 300, spacing = 200, port_gap = 150, -- tiles to spawns, other city-states, ports
    choke_offset = {60, 90},                  -- tiles beside a pass or ford (out of turret reach of the path)
    route_gap = 90,                           -- the oil swamp's city-state: tiles off the spawn-to-centre lines
    stock = {                                 -- goods in its stockpiles at founding, by what it sits on
      copper = {{"copper-plate", 400}, {"copper-cable", 400}},
      iron = {{"iron-plate", 400}, {"steel-plate", 100}},
      oil = {{"plastic-bar", 150}, {"sulfur", 100}},
      coast = {{"raw-fish", 100}, {"stone-brick", 200}},
      pass = {{"stone-brick", 300}, {"iron-gear-wheel", 150}},
      ford = {{"stone", 300}, {"coal", 200}},
    },
  },
  uranium = {count = {[2] = 1, [3] = 1, [4] = 2}, amount = 20000, offset = 0.45, tech = "rts-geology"},
  rare = {count = {[1536] = 4, [2048] = 6, [3072] = 8}, amount = 3000, side = 6, city_state_share = 0.6,
          kinds = {"saltpetre", "quartz", "tungsten", "diamonds", "rare-earths", "gold"}},
  ruins = {count = {[1536] = 8, [2048] = 10, [3072] = 12}, min_spawn = 300, spacing = 220},
  ports = {spread_max = 0.15, min_spawn = 300, spacing = 500}, -- nearest-port path spread across nations
  chokes = {max_width = 80, min_width = 16, window = 24, min_side = 40, spacing = 12, spawn_clear = 140, max_tests = 120},
  scarce_fair = 0.15,                         -- the two nearest nations of a scarce deposit within this path share
  need_bonus = 0.5,                           -- specialty search: ores a nation lacks at home count 1.5x
  minimap = {regional_tiles = 1000},          -- HUD minimap in regional mode (N switches to the whole world)
  zoom = {furthest = 1.1},                    -- strategic zoom: the map view shows this many world widths
}


-- Phase 5 M3 age3 (docs/PHASE5-M3.md D1-D3 and D10, §3 "age3.lua / rare.lua / sinks.lua"; docs/qa/phase5-age3-notes.md):
-- Age III and the Space Program, the Age III districts, the nuclear plant and automation kits (scripts/age3.lua,
-- prototypes/age3.lua), rare extractors and their nation-wide bonuses (scripts/rare.lua), money sinks and city-state
-- trade (scripts/sinks.lua). Pure data, Nation mode only.
--
-- recipes[name] = {category, cost, results, time, order, tech?}: Age III recipes. Without `tech` a recipe is enabled for
--   a force when it reaches Age III (stage 1 of the Space Program); with `tech` when that technology is researched.
--   Categories: rts-age3 (the factory), rts-chemistry (the Age II chemical plant) and one rts-district-<id> per district.
-- buildings[name] = {kind, family, cost, time, health, power?, size?, categories?, tech?, age?}: made by the factory
--   (rts-buildings); Age III unless `tech` names the technology that unlocks it.
balance.nation = balance.nation or {}
local A3 = {}
balance.nation.age3 = A3

-- Research Electrification (Age II, industrial kits) lets a nation in Age II start the Space Program: a 8x8 Launch
-- complex next to its capital that pulls each stage's goods from the logistic network it stands in (pull_per_second
-- per good), then counts down build_seconds. Stage 1 done = Age III; stage 3 done = Space victory in the victory modes
-- listed in `modes` (balance.nation.diplomacy.victory). A destroyed complex loses raze_loss of the running stage's
-- deliveries; finished stages stay finished.
A3.tech = "rts-electrification"
A3.site = {name = "rts-launch-complex", health = 8000, distances = {16, 20, 24, 28}}
A3.pull_per_second = 10
A3.period = 60
A3.raze_loss = 0.5
A3.stages = {
  -- Phase 5 M3 integration (balance pass): 150 concrete and 60 advanced circuits (was 200 and 100): the AIs took 10-24
  -- minutes for stage 1, the advanced circuits last (21 of 100 after 9 minutes)
  {id = "structure", required = {["steel-plate"] = 200, concrete = 150, ["advanced-circuit"] = 60}, build_seconds = 20},
  {id = "systems", required = {["processing-unit"] = 40, battery = 100, ["engine-unit"] = 80}, build_seconds = 30},
  {id = "fuel", required = {["rocket-fuel"] = 40, sulfur = 200, ["light-oil-barrel"] = 50}, build_seconds = 120},
}
A3.modes = {conquest_space = true, any = true}

-- Technologies (Nation mode only; scripts/age3.lua registers their effects with scripts/research.lua)
A3.techs = {
  -- Phase 5 M3 integration (balance pass): 25 kits (was 40): labs waited for industrial kits 12-30 minutes after Age II
  {name = "rts-electrification", kit = "rts-science-industrial", count = 25, icon = "electric-energy-distribution-1",
   age = 2, prerequisites = {"rts-industrialisation"}, effect = {flag = "electrification"}},
  {name = "rts-chemistry", kit = "rts-science-industrial", count = 30, icon = "battery", age = 3,
   prerequisites = {"rts-electrification"}, effect = {flag = "chemistry"}},
  {name = "rts-nuclear-power", kit = "rts-science-industrial", count = 40, icon = "nuclear-power", age = 3,
   prerequisites = {"rts-electrification", "rts-geology"}, effect = {flag = "nuclear"}},
}

A3.buildings = {
  -- Chemistry district: oil into plastic, sulfur, batteries, rocket fuel, light oil in barrels, fuel rods
  ["rts-district-chemistry"] = {kind = "district", family = "chemistry", size = 5, health = 2800, power = "600kW",
    cost = {["steel-plate"] = 20, ["iron-plate"] = 60, ["advanced-circuit"] = 10, concrete = 20}, time = 12,
    categories = {"rts-district-chemistry"}},
  -- Electronics II: advanced circuits, processing units, automation kits
  ["rts-district-electronics2"] = {kind = "district", family = "electronics", size = 5, health = 2800, power = "600kW",
    cost = {["steel-plate"] = 20, ["iron-plate"] = 40, ["advanced-circuit"] = 20, concrete = 20}, time = 12,
    categories = {"rts-district-electronics2"}},
  -- Concrete works
  ["rts-district-concrete"] = {kind = "district", family = "services", size = 5, health = 2800, power = "400kW",
    cost = {["steel-plate"] = 10, ["iron-plate"] = 60, ["stone-brick"] = 40}, time = 10,
    categories = {"rts-district-concrete"}},
  -- Nuclear plant composite: one 5x5 burner generator on fuel rods (uranium), 40 MW; scripts/age3.lua keeps `keep`
  -- rods in it from the logistic network it stands in. Registry kind "steam-plant" (power figures, upkeep, labor)
  ["rts-nuclear-plant"] = {kind = "steam-plant", family = "power", size = 5, health = 5000, power = "40MW",
    cost = {["steel-plate"] = 60, concrete = 80, ["advanced-circuit"] = 30, ["iron-plate"] = 100}, time = 20,
    tech = "rts-nuclear-power"},
  -- Rare extractor: a 3x3 drill that mines only rare deposits, one item every rare.item_seconds (no mining
  -- productivity); its items go into the logistic network it stands in (scripts/rare.lua). Geology unlocks it in any
  -- age; it may stand on own or neutral land (an outpost)
  ["rts-rare-extractor"] = {kind = "rare-extractor", family = "extraction", size = 3, health = 900,
    cost = {["iron-plate"] = 30, ["steel-plate"] = 10, ["electronic-circuit"] = 10}, time = 6, tech = "rts-geology"},
}

A3.recipes = {
  -- factory (rts-age3): the automation kit is the vanilla module recipe
  ["rts-automation-kit"] = {category = "rts-age3", cost = {["advanced-circuit"] = 5, ["electronic-circuit"] = 5},
                            results = {["rts-automation-kit"] = 1}, time = 15, order = "a"},
  ["rts-processing-unit"] = {category = "rts-age3", cost = {["electronic-circuit"] = 10, ["advanced-circuit"] = 2,
                             sulfur = 2}, results = {["processing-unit"] = 1}, time = 10, order = "b"},
  -- chemical plant (Age II building, Age III recipes)
  ["rts-battery"] = {category = "rts-chemistry", cost = {["iron-plate"] = 1, ["copper-plate"] = 1, sulfur = 2},
                     results = {battery = 1}, time = 4, order = "d", tech = "rts-chemistry"},
  ["rts-rocket-fuel"] = {category = "rts-chemistry", cost = {["rts-petroleum"] = 5, coal = 2},
                         results = {["rocket-fuel"] = 1}, time = 10, order = "e", tech = "rts-chemistry"},
  ["rts-light-oil-barrel"] = {category = "rts-chemistry", cost = {["rts-petroleum"] = 3, ["steel-plate"] = 1},
                              results = {["light-oil-barrel"] = 1}, time = 3, order = "f"},
  -- Chemistry district
  ["rts-dch-plastic"] = {category = "rts-district-chemistry", cost = {["rts-crude-oil"] = 3, coal = 1},
                         results = {["plastic-bar"] = 10, sulfur = 2}, time = 4, order = "a"},
  ["rts-dch-sulfur"] = {category = "rts-district-chemistry", cost = {["rts-crude-oil"] = 2}, results = {sulfur = 12},
                        time = 3, order = "b"},
  ["rts-dch-battery"] = {category = "rts-district-chemistry", cost = {["iron-plate"] = 2, ["copper-plate"] = 2,
                         ["rts-crude-oil"] = 2}, results = {battery = 4}, time = 6, order = "c", tech = "rts-chemistry"},
  ["rts-dch-rocket-fuel"] = {category = "rts-district-chemistry", cost = {["rts-crude-oil"] = 6, coal = 2},
                             results = {["rocket-fuel"] = 2}, time = 10, order = "d", tech = "rts-chemistry"},
  ["rts-dch-light-oil-barrel"] = {category = "rts-district-chemistry", cost = {["rts-crude-oil"] = 6,
                                  ["steel-plate"] = 2}, results = {["light-oil-barrel"] = 2}, time = 4, order = "e"},
  ["rts-dch-fuel-rod"] = {category = "rts-district-chemistry", cost = {["uranium-ore"] = 4, ["steel-plate"] = 1},
                          results = {["rts-fuel-rod"] = 1}, time = 10, order = "f", tech = "rts-nuclear-power"},
  -- Electronics II
  ["rts-de2-advanced-circuit"] = {category = "rts-district-electronics2", cost = {["electronic-circuit"] = 2,
                                  ["plastic-bar"] = 2, ["copper-plate"] = 1}, results = {["advanced-circuit"] = 3},
                                  time = 4, order = "a"},
  ["rts-de2-processing-unit"] = {category = "rts-district-electronics2", cost = {["electronic-circuit"] = 8,
                                 ["advanced-circuit"] = 2, sulfur = 1}, results = {["processing-unit"] = 2}, time = 10,
                                 order = "b"},
  ["rts-de2-automation-kit"] = {category = "rts-district-electronics2", cost = {["advanced-circuit"] = 4,
                                ["electronic-circuit"] = 4}, results = {["rts-automation-kit"] = 1}, time = 12,
                                order = "c"},
  -- Concrete works
  ["rts-dcw-concrete"] = {category = "rts-district-concrete", cost = {["stone-brick"] = 5, stone = 2},
                          results = {concrete = 14}, time = 4, order = "a"},
  ["rts-dcw-concrete-stone"] = {category = "rts-district-concrete", cost = {stone = 10, ["iron-plate"] = 1},
                                results = {concrete = 10}, time = 5, order = "b"},
  -- Munitions works: uranium rounds for heavy walkers (balance.nation.rare.uranium_rounds)
  ["rts-dmu-uranium-rounds"] = {category = "rts-district-munitions", cost = {["uranium-ore"] = 1,
                                ["firearm-magazine"] = 5, ["steel-plate"] = 1},
                                results = {["uranium-rounds-magazine"] = 5}, time = 6, order = "c",
                                tech = "rts-nuclear-power"},
}

-- Automation kits (deep-economy.md §5.6): a city policy "automate <family>" puts up to per_building kits from the
-- city's network into every district of that family (slots 2 and 3; slot 1 is the labor slot); each kit cuts the
-- building's jobs by job_cut (2 kits: x0.49). The policy pass runs every `period` ticks per city (staggered).
A3.kit = {item = "rts-automation-kit", job_cut = 0.3, per_building = 2, period = 300,
          families = {"metallurgy", "chemistry", "electronics", "military", "services", "research"}}
-- Nuclear plant: fuel rods (2.4 GJ: one a minute at 40 MW), `keep` of them in its burner
A3.nuclear = {fuel = "rts-fuel-rod", fuel_value = "2.4GJ", keep = 2, period = 300}

-- Labor (balance.nation.people): jobs and families of the Age III buildings
balance.nation.people.jobs.name["rts-nuclear-plant"] = 12
balance.nation.people.jobs.kind["rare-extractor"] = 4
for name, b in pairs(A3.buildings) do
  if b.family then balance.nation.people.families.name[name] = b.family end
end
for name, b in pairs(A3.buildings) do balance.buildings[name] = b end
balance.buildings[A3.site.name] = {kind = "project", health = A3.site.health}
-- prices of the Age III goods without a cheap recipe path (the rest is derived at match start)
balance.nation.market.p0.battery = 6
balance.nation.market.p0["rocket-fuel"] = 30

-- Rare resources (deep-economy.md §3.7, D3; scripts/rare.lua). A rare extractor on a deposit mines one item every
-- item_seconds into the logistic network it stands in (an extractor without a network keeps up to `buffer` items).
-- Every check_period ticks the capital's network gives up the rare items that reached it: each arrival keeps the
-- bonus of its kind for `grace` seconds (a steady trickle keeps it on; it ends at most `grace` after the last item).
-- Bonuses: recipe productivity (LuaRecipe.productivity_bonus) of every recipe that makes one of `items`, mining
-- productivity, lab speed and productivity, tax income; applied as deltas against what rare.lua applied before.
balance.nation.rare = {
  extractor = "rts-rare-extractor",
  item_seconds = 10, grace = 90, check_period = 60, pickup_period = 60, buffer = 20,
  order = {"saltpetre", "quartz", "tungsten", "diamonds", "rare-earths", "gold"},
  kinds = {
    saltpetre = {items = {"rts-explosives", "firearm-magazine"}, productivity = 0.25},
    quartz = {items = {"electronic-circuit", "advanced-circuit", "processing-unit"}, productivity = 0.20},
    tungsten = {items = {"steel-plate"}, productivity = 0.20},
    diamonds = {mining = 0.15},
    ["rare-earths"] = {lab_speed = 0.10, lab_productivity = 0.10},
    gold = {tax = 0.15},
  },
  -- Uranium rounds (D3): while the capital's network can pay per_unit_minute magazines a minute for every heavy walker
  -- of the nation, the heavies' ammo category deals +damage (checked every check_period ticks; no heavy: one magazine
  -- in the network is enough)
  uranium_rounds = {item = "uranium-rounds-magazine", kind = "heavy", category = "rts-heavy", damage = 0.3,
                    per_unit_minute = 1},
}

-- Money sinks (D10; scripts/sinks.lua)
balance.nation.sinks = {
  -- Rush: the national project pulls `speed` x faster and counts down `speed` x faster; a research runs at `speed` x
  -- lab speed. Charged every period ticks: project_cr per missing item and second (a countdown: countdown_cr per
  -- second), research_cr per missing research unit and second. Stops when the treasury refuses the charge.
  -- (the fixture: stage 2 of the Space Program from stock, rushed, costs about 130 cr; stage 3 about 500)
  rush = {speed = 2, period = 60, project_cr = 0.01, countdown_cr = 8, research_cr = 0.1},
  -- Hire garrison: cr_per_point crowns per garrison point at a city (hidden turrets, 1 per 4 points with the units'
  -- points); hired points decay by decay_per_min a minute (a share every decay_period ticks); at most max_points hired
  -- per city
  hire = {cr_per_point = 40, decay_per_min = 1, decay_period = 600, max_points = 32, step = 4},
  -- Mercenaries at an own trade port: a small division by the port's region kind, `cost` crowns, one per `cooldown`
  -- seconds per nation; they need free supply like any unit
  mercenaries = {cost = 600, cooldown = 600, radius = 12,
    templates = {
      default = {["rts-walker"] = 6, ["rts-drone"] = 2},
      highland = {["rts-walker"] = 4, ["rts-walker-heavy"] = 2},
      mountain = {["rts-walker"] = 4, ["rts-walker-heavy"] = 2},
      plain = {["rts-walker"] = 4, ["rts-raider"] = 3},
      desert = {["rts-raider"] = 4, ["rts-drone"] = 2},
      coast = {["rts-walker"] = 6, ["rts-drone"] = 2},
      swamp = {["rts-drone"] = 6},
      forest = {["rts-walker"] = 6, ["rts-drone"] = 2},
      lakeland = {["rts-walker"] = 5, ["rts-drone"] = 3},
    }},
  -- City-state trade: a city-state's City Center is a port for its region's goods (its network stock). A nation buys at
  -- markup x the market price (markup_best at relation 100) and sells at sell_factor x it (no world-market outlet:
  -- below the ports' 0.9, and outside the commerce cap only up to cap_per_min per city-state); the goods arrive
  -- in (or leave) the network of the buyer's city nearest to the city-state after `delay` ticks. Every relation_cr
  -- crowns traded raise the city-state's relation with the nation by 1 (-100..100); below min_relation it refuses to
  -- trade. A city-state trades at most cap_per_min crowns a minute (rolling) and restocks restock_share of its starting
  -- goods every restock_period ticks. Capturing a city-state while at peace with every nation costs capture_penalty
  -- relation with every other nation.
  city_state = {markup = 1.3, markup_best = 1.1, sell_factor = 0.7, relation_cr = 100, min_relation = -50,
                cap_per_min = 400, delay = 30 * 60, restock_period = 5 * 60 * 60, restock_share = 0.25,
                capture_penalty = -10, capture_relation = -30},
}

-- Phase 5 M3 air (docs/PHASE5-M3.md D4, section 3 "air.lua"; docs/qa/phase5-air-notes.md): planes, the airfield and the
-- anti-air turret. Nation mode only (nation_only units: Skirmish never gets a plane, a kit or an AA turret). Planes are
-- `unit`s with an empty collision mask (they fly over water, cliffs and walls) drawn on the air-object layer; they carry
-- the "air" trigger target type (prototypes/categories.lua makes one per balance.target_types entry): the AA turret
-- targets only it, gun, laser, bunker, fort and garrison turrets ignore it (prototypes/air.lua). Every RTS building
-- carries "structure", which the bomber's x2 bonus uses. Speeds are relative to the walker (11.5 tiles/s); `vision`
-- is the tiles fog.lua charts around the plane (scout: its reveal).
balance.target_types.air = "rts-air"
balance.target_types.structure = "rts-structure"
balance.units["rts-scout-plane"] = {
  kind = "scout-plane", tier = 1, role = "air-scout", supply = 1, nation_only = true, air = true,
  kit = "rts-scout-plane-kit", cost = {["engine-unit"] = 1, ["electronic-circuit"] = 4, ["iron-plate"] = 10}, time = 6,
  unlock = "rts-aviation",
  health = 150, speed = 2.4, size = 0.5, range = 0, vision = 64,
  resist = {physical = 60}, tags = {"air"},
  strong = {}, weak = {"interceptor"},
}
balance.units["rts-bomber"] = {
  kind = "bomber", tier = 1, role = "air-bomber", supply = 3, nation_only = true, air = true,
  kit = "rts-bomber-kit", cost = {["engine-unit"] = 2, ["steel-plate"] = 6, ["rts-explosives"] = 8,
                                  ["electronic-circuit"] = 4}, time = 10,
  unlock = "rts-air-force",
  health = 600, speed = 1.2, size = 0.9, range = 6, cooldown = 90, damage = 180, damage_type = "explosion",
  splash = 2, splash_damage = 30, bonus = {structure = 2},
  resist = {physical = 60}, tags = {"air"},
  ammo_category = "rts-bomber",
  strong = {"building", "turret", "wall"}, weak = {"interceptor"},
}
balance.units["rts-interceptor"] = {
  kind = "interceptor", tier = 1, role = "air-superiority", supply = 2, nation_only = true, air = true,
  kit = "rts-interceptor-kit", cost = {["engine-unit"] = 2, ["steel-plate"] = 4, ["advanced-circuit"] = 2}, time = 8,
  unlock = "rts-air-force",
  health = 300, speed = 2.0, size = 0.7, range = 16, cooldown = 10, damage = 10, damage_type = "physical",
  bonus = {air = 3},
  resist = {physical = 60}, tags = {"air"},
  ammo_category = "rts-interceptor",
  strong = {"scout-plane", "bomber"}, weak = {}, -- the AA turret (not a unit kind) is its counter
}
balance.nation.air = {
  planes = {"rts-scout-plane", "rts-bomber", "rts-interceptor"},
  -- Plane supply (fuel and ammunition), 0..max: -drain per second in flight farther than range tiles from every own
  -- airfield, +refill per second within it; at return_at the plane flies home on its own, at 0 it crashes (dies, alert).
  -- A plane far from home turns back earlier, at what the flight home needs x bingo_factor + bingo_margin (a slow bomber
  -- 200 tiles out needs 20 supply for the trip alone)
  supply = {max = 100, drain = 1, refill = 10, range = 24, return_at = 20, bingo_factor = 1.25, bingo_margin = 5},
  period = 60,                  -- ticks between supply steps (all planes in one pass)
  return_radius = 6,            -- a returning plane's go_to radius around its airfield
  crash_keep = 5 * 60 * 60,     -- ticks a crashed plane's record answers air.state(un) = "crashed"
  patrol = {radius = 40, points = 6}, -- default patrol circle and its waypoints
  -- Airfield: 6x6, one per city (the city whose land it stands on); a plane kit needs one in the barracks' city and the
  -- plane appears there
  airfield = {kind = "airfield", cost = {["steel-plate"] = 20, concrete = 40, ["electronic-circuit"] = 10}, time = 12,
              health = 2500, size = 6, unlock = "rts-aviation"},
  -- Anti-air turret: magazines from the network it stands in (fed like turrets, scripts/air.lua), only planes
  aa_turret = {kind = "aa-turret", cost = {["iron-plate"] = 30, ["steel-plate"] = 10, ["electronic-circuit"] = 5},
               time = 8, health = 1000, range = 30, cooldown = 6, damage_modifier = 6, unlock = "rts-aviation",
               feed_min = 5, feed = 10, feed_period = 120},
  techs = {
    {name = "rts-aviation", kit = "rts-science-industrial", count = 30, age = 2, icon = "defender",
     unlock = {"rts-scout-plane", "rts-scout-plane-kit", "rts-airfield", "rts-aa-turret"}},
    {name = "rts-air-force", kit = "rts-science-industrial", count = 50, age = 3, icon = "destroyer",
     prerequisites = {"rts-aviation"}, unlock = {"rts-bomber", "rts-bomber-kit", "rts-interceptor", "rts-interceptor-kit"}},
  },
}
balance.buildings["rts-airfield"] = {kind = "airfield", cost = balance.nation.air.airfield.cost,
                                     time = balance.nation.air.airfield.time, health = balance.nation.air.airfield.health,
                                     unlock = "rts-aviation"}
balance.buildings["rts-aa-turret"] = {kind = "aa-turret", cost = balance.nation.air.aa_turret.cost,
                                      time = balance.nation.air.aa_turret.time,
                                      health = balance.nation.air.aa_turret.health, range = balance.nation.air.aa_turret.range,
                                      unlock = "rts-aviation"}
-- Phase 5 M3 war2 (docs/PHASE5-M3.md D5, D6, section 3 "fronts.lua / belts.lua / trainswar.lua";
-- docs/qa/phase5-war2-notes.md): fronts per war, the hold_line order, fort belts, artillery and armoured trains.
-- Nation mode only. Pure data.
balance.nation.fronts = {
  segment_min = 128, segment_max = 192, -- tiles of border per segment (a shorter border stays one segment)
  min_cells = 4,             -- border pieces shorter than this many cells (8 tiles each) are no front
  refresh = 1800,            -- ticks between recomputations (with the territory: every 30 s)
  rows_per_tick = 24,        -- territory rows scanned per tick by the refresh job
  cell_budget = 600,         -- ... and at most about this many owned cells visited per tick
  match_radius = 96,         -- a new segment keeps the id and holder of an old one whose middle is this close
  near_radius = 160,         -- tiles around a segment's middle where enemy strength counts
  value_radius = 400,        -- own cities this close to the middle count as "value behind", falling off to 0
  depot_radius = 200,        -- own depots and hubs this close count too
  value = {tier = 10, per_residents = 10, capital = 20, depot = 8}, -- value of a city: tier x 10 + residents / 10 (+20)
  strength_unit = 16,        -- threat = value x (1 + enemy supply near / strength_unit)
  hold = {behind = 4,        -- hold_line slots stand this many tiles behind the chord, inside own land
          far = 96,          -- a division farther than this from the chord marches to it as a group first
          pick = 64,         -- H with divisions selected: the segment whose chord is this close to the cursor
          maintain = 600,    -- ticks between line checks (members back to their slots)
          drift = 10,        -- a member farther than this from its slot walks back (no enemy within enemy_clear)
          enemy_clear = 30},
}
balance.nation.belts = {
  tech = "rts-fortification",            -- Fortification (Age I) unlocks the gate and the fort belt tool
  wall = "rts-wall", gate = "rts-gate", turret = "rts-turret", aa_turret = "rts-aa-turret", depot = "rts-field-depot",
  min_points = 2, max_points = 6, max_length = 640, -- tiles of polyline
  turret_every = 12, turret_behind = 3,  -- a turret every 12 tiles of wall, 3 tiles behind it
  aa_every = 36, aa_behind = 7, aa_age = 2, -- an AA turret every 36 tiles from Age II (when m3-air's prototype exists)
  depot_behind = 12,                     -- the field depot behind the middle of the belt
  build_rate = 4,                        -- belt crew: ghosts built per second, items debited from the city network
  ghosts_per_tick = 40,                  -- ghosts placed per tick while a plan is laid out
  magazines = 10,                        -- magazines a new belt turret gets from the same network
  feed = {period = 600, min = 5, top = 10}, -- the field depot tops up its belt's turrets (magazines) every 10 s
  priority = {"rts-artillery", "rts-walker-heavy", "rts-heavy-mk2", "rts-armoured-car"}, -- shot first by belt turrets
}
balance.nation.trains_war = {
  tech = "rts-military-railways",        -- Age II: the artillery wagon, rail shells, armoured stock
  range = 120, min_range = 16,           -- tiles from the artillery wagon to a target building
  spot_radius = 48, radar_radius = 96,   -- a target is seen with an own entity / an own radar this close to it
  period = 600,                          -- ticks between shots in stance bombard (1 shell per shot)
  shell_speed = 0.6, shell_damage = 420, shell_radius = 3.5, -- explosion damage in the radius, hostile forces only
  shells_keep = 20,                      -- shells a wagon tops up to at a depot of its force
  health_factor = 3, resist = 40,        -- armoured stock: 3x health, 40 % physical and explosion resistance
  locomotive_health = 1000, troop_wagon_health = 800, artillery_wagon_health = 1500,
  artillery_wagon_kit = {cost = {["iron-plate"] = 40, ["steel-plate"] = 20, ["rts-explosives"] = 10}, time = 8},
  armoured_locomotive_kit = {cost = {["iron-plate"] = 80, ["steel-plate"] = 30, ["electronic-circuit"] = 10}, time = 10},
  armoured_wagon_kit = {cost = {["iron-plate"] = 40, ["steel-plate"] = 20}, time = 8},
  rail_shell = {cost = {["rts-explosives"] = 2, ["steel-plate"] = 1}, time = 4},
  gate = {cost = {["rts-wall"] = 1, ["iron-plate"] = 5, ["electronic-circuit"] = 2}, time = 3, health = 700},
  techs = {
    fortification = {count = 15, kit = "rts-science-basic", age = 1},
    military_railways = {count = 25, kit = "rts-science-industrial", age = 2,
                         prerequisites = {"rts-railways", "rts-industrialisation"}},
  },
  -- target order in stance bombard (lower first), then the nearest
  target_rank = {turret = 1, ["laser-turret"] = 1, fort = 1, bunker = 1, barracks = 2, hub = 3, cc = 3, factory = 4},
}
balance.buildings["rts-gate"] = {kind = "wall", cost = balance.nation.trains_war.gate.cost,
                                 time = balance.nation.trains_war.gate.time, health = balance.nation.trains_war.gate.health}
-- Phase 5 M3 perf: the work-unit scheduler (scripts/sched.lua). budget = work units per tick per nation (one unit is
-- about 1 microsecond of script time on the dev Mac, docs/qa/phase5-perf-notes.md); the difficulty levels of m3-ai
-- (balance.nation.ai3.difficulty[level]) may scale it with budget_factor (default 1).
balance.nation.ai3 = balance.nation.ai3 or {}
balance.nation.ai3.budget = balance.nation.ai3.budget or 400
balance.nation.ai3.tick_cap = balance.nation.ai3.tick_cap or 2000 -- all nations together, once each had its budget

-- Phase 5 M3 ai (docs/PHASE5-M3.md D7, §3 "ai/planner.lua, council.lua, controller.lua, intel.lua, difficulty.lua";
-- study docs/research/scale/war-ai-performance.md §4; notes docs/qa/phase5-ai3-notes.md): the full nation AI. Pure data,
-- Nation mode only (the Skirmish AI never reads it). budget and tick_cap above are m3-perf's (scripts/sched.lua).
do
  local AI3 = balance.nation.ai3
  -- Difficulty without cheats (§4.7). Every level sees honestly and pays what a player pays; the levels differ in skill:
  -- how fresh intelligence must be before the council acts on it (intel_age, ticks), offensive operations at once (ops),
  -- city-site candidates the planner scores (sites), the A* state cap of its planners (astar), build pace (ticks per
  -- construction job, build_period, and buildings in flight), micro (off | basic | full: retreat by force ratio,
  -- resupply, focus), orders per minute per division (opm), the scheduler budget factor, how early the planner founds
  -- its cities (expand: x on the city times) and how many it founds (cities), how often the council thinks (council,
  -- ticks), when the first offensive may start (first_attack, x on the doctrine's), and how early and with what margin
  -- over its defence a city-state operation starts (cs_from x balance.nation.diplomacy.ai.city_state_from; cs_ratio x
  -- the city-state's points), and the goods works the capital's governor plans (goods_per_works: one per that much
  -- goods need a minute, at most goods_works_cap; unset: the people.ai rule of one, a second when a town stalls). Every
  -- AI's capital ran short of goods from tier 3 (0-40 % met, 62-70 % happy, no growth) and the market AI imported them
  -- at 15-17 cr until the tax hysteresis held a high tax (wave B.2: the goods chain at every level), and hard's first
  -- city-state plan (cs_plan: the army sized for the nearest city-state, artillery favoured, the push when it is ready;
  -- ai/council.lua council.cs_plan_step).
  AI3.difficulty = {
    easy = {intel_age = 60 * 60, ops = 1, sites = 8, astar = 20000, build_period = 360, in_flight = 2, micro = "off",
            opm = 2, budget_factor = 0.75, expand = 1.3, cities = 3, council = 240, first_attack = 1.5,
            cs_from = 1.3, cs_ratio = 1.8, goods_per_works = 20, goods_works_cap = 2},
    normal = {intel_age = 30 * 60, ops = 2, sites = 16, astar = 40000, build_period = 180, in_flight = 3,
              micro = "basic", opm = 6, budget_factor = 1, expand = 1, cities = 4, council = 120, first_attack = 1,
              cs_from = 1, cs_ratio = 1.5, goods_per_works = 12, goods_works_cap = 4},
    hard = {intel_age = 10 * 60, ops = 4, sites = 32, astar = 60000, build_period = 120, in_flight = 4, micro = "full",
            opm = 12, budget_factor = 1.5, expand = 0.8, cities = 4, council = 60, first_attack = 0.8,
            cs_from = 0.75, cs_ratio = 1.6, goods_per_works = 12, goods_works_cap = 4, cs_plan = true},
  }
  -- Intelligence (ai/intel.lua): every difficulty intel_age ticks per nation, what any own entity sees within `sight` tiles (an own
  -- scout plane within `plane_sight`): rival and city-state cities, divisions, depots, planes and unit clusters (cells of
  -- `cell` tiles). Divisions, clusters and planes not seen for `forget` ticks are dropped; cities and depots stay until
  -- their spot is seen empty.
  AI3.intel = {sight = 30, plane_sight = 64, cell = 64, forget = 10 * 60 * 60, cluster_checks = 40}
  -- Economic planner (ai/planner.lua), every `period` ticks per nation (staggered).
  --   Sites: candidates (world city sites, oil fields, rare deposits, region ore patches, chokes) scored as a scheduler
  --   job (units per candidate) every `rescore` ticks: need-weighted ore within ore_radius (amount capped at ore_cap),
  --   oil and rare value, choke value (fortress), minus rail cost (tiles from the nearest own city x rail_terrain for
  --   water and mountain cells on the way), exposure (rival capitals and land within exposure_radius) and overlap with
  --   any city closer than min_city. Roles: oil (an oil field), rare, fortress (a choke between us and a rival),
  --   mining (ore), trade (a port nearby).
  --   Cities: the second city is ai/towns.lua's mining town; the third from third_at seconds (or Industrialisation
  --   researched), the fourth from fourth_at (or Age II), more every more_gap until the difficulty's `cities` (at most
  --   balance.nation.cities.limit, capital included); the times x the difficulty's expand, x territory_expand when the
  --   lobby's victory mode includes Territory.
  --   Trunk: a minimum spanning tree over own cities rooted at the capital (edge cost = tiles x rival-land factor); one
  --   rails.ai_program per edge not served by rails.lua's own program, at most `lines` building at once.
  AI3.planner = {
    period = 300, rescore = 3 * 60 * 60, units = {candidate = 40, check = 8},
    -- (wave B.2: the third city within third_link tiles of an own city when such a site is left, no city but the oil
    -- town beyond far_city tiles of the capital)
    third_link = 250, far_city = 450,
    -- (wave B.2, a minimal plan: in Age III an outpost on the nearest uranium deposit within reach tiles of an own city,
    -- the capital keeps `keep` ore; one nuclear plant and fuel_rods rods in stock once Nuclear power is researched)
    uranium = {reach = 260, keep = 40, fuel_rods = 2},
    third_at = 9 * 60, fourth_at = 18 * 60, more_gap = 7 * 60, territory_expand = 0.7, city_tries = 6,
    min_capital = 180, max_capital = 700, min_city = 150, ore_radius = 70, ore_cap = 60000,
    exposure_radius = 700, rail_terrain = 2.5,
    weights = {ore = 1.0, oil = 1.6, rare = 0.8, choke = 0.5, port = 0.4, rail = 1.0, exposure = 0.8, need = 1.0},
    role_order = {"oil", "mining", "rare", "fortress", "trade"},
    oil = {reach = 14, pumpjacks = 3, export = {"rts-crude-oil", "plastic-bar", "sulfur"}, keep_crude = 400},
    trunk = {period = 600, lines = 3, rival_factor = 3, max_surveys = 2, max_edge = 480, age1_circuits = 40},
    -- the oil chain at the capital once crude comes in (Age II): districts appended to the age-up list
    -- (and a second Steel works: steel is what engines, kits, rails, depots and the Space Program's first stage all wait
    -- for; it makes steel of the town's plates)
    oil_districts = {"rts-district-electronics", "rts-district-petrochem", "rts-district-construction",
                     "rts-district-steel"},
    -- once three cities are linked by rail (the lines' steel comes first): an Engines works (it takes steel)
    linked_districts = {"rts-district-engines"},
    -- Age III road: Electrification first in Age II; make targets for the industrial kit's parts and then the running
    -- Space Program stage's goods (capped at stage_cap per good); purchases of what the nation cannot make in time (the
    -- market AI's ai_buy covers ledger shortfalls) at most buy_share of the balance above buy_reserve per buy_period
    research_first = {"rts-electrification"}, kit_targets = {["engine-unit"] = 20, ["advanced-circuit"] = 20, sulfur = 20},
    stage_cap = 200, buy_reserve = 1500, buy_share = 0.25, buy_period = 60 * 60, buy_max = 100,
    -- a port farther than port_reach tiles from the capital is not used for purchases (a hauler takes minutes each way);
    -- city-states first. Every non-capital city exports export_goods (they reach the capital by haulers and trains)
    port_reach = 450,
    -- rails kept at the capital while a line is under way (the Rail works make them; a make target)
    rail_stock = 150,
    -- Age II on: stone_buy stone when the capital holds less than stone_low (a ford city-state sells it)
    stone_low = 150, stone_buy = 300,
    -- and steel_buy steel when the capital holds less than steel_low (an iron city-state sells it)
    steel_low = 40, steel_buy = 80,
    export_goods = {"plastic-bar", "sulfur", "advanced-circuit", "engine-unit", "concrete", "rts-crude-oil",
                    "processing-unit", "battery", "rocket-fuel", "light-oil-barrel"},
    -- rush the running project (the Railway Charter, a Space Program stage) or a wanted research (Electrification) when
    -- the balance is above rush_at and a project's goods are mostly there (rush_share)
    rush_at = 2200, rush_share = 0.6,
    -- Geology and rare extractors: deposits inside own land within reach of a city network
    rare = {from_age = 2, reach = 15, max = 3},
    -- automation (Age III): families automated once the capital holds kits_at automation kits
    automate = {families = {"metallurgy", "electronics", "chemistry"}, kits_at = 4},
  }
  -- War council (ai/council.lua), every difficulty `council` ticks per nation.
  --   Fronts: a segment with at least hold_strength enemy supply near it (fronts.STRENGTH: intel) gets a holding division
  --   of 1.5 x that strength (hold_min..hold_max units) from the idle army, at most hold_units (1 - reserve) of it on
  --   lines; a hold is released when its segment is gone or quiet for hold_quiet ticks. A segment above belt_threat for
  --   belt_after ticks gets a fort belt (belts.plan_front; Fortification first), at most `belts` per nation.
  --   Operations: kinds capture, siege, relief, raid, bomb; phases with timeouts (ticks); `abort_ratio` force ratio.
  --   Air: an airfield at the capital from Age II (Aviation first) once a war ran or air_from has passed; scout planes
  --   (scouts) patrol the most threatened segment (else the capital), interceptors when enemy planes were seen,
  --   bombers before an offensive (Air Force).
  --   Money: hire garrison points at a city under attack (hire_points, balance above hire_at), mercenaries when the
  --   capital is attacked and the idle army is below merc_army (balance above merc_at).
  AI3.council = {
    reserve = 0.25, hold_strength = 4, hold_quiet = 5 * 60 * 60, hold_min = 6, hold_max = 16, hold_units = 0.75,
    belt_threat = 30, belt_after = 3 * 60 * 60, belts = 2,
    -- without a front (the lands do not touch): a city with hostile strength >= sector_strength known within
    -- sector_radius for belt_after gets a sector_length belt across the approach
    cs_plan_artillery = 3, -- (wave B.2) the artillery weight factor of the barracks while hard's city-state plan runs
    sector_strength = 4, sector_radius = 250, sector_length = 40, sector_after = 2 * 60 * 60, sector_grace = 2 * 60 * 60,
    timeouts = {assemble = 2 * 60 * 60, advance = 8 * 60 * 60, siege = 6 * 60 * 60, capture = 4 * 60 * 60,
                consolidate = 60 * 60, move = 4 * 60 * 60, engage = 3 * 60 * 60, strike = 3 * 60 * 60,
                fly = 3 * 60 * 60, ["return"] = 3 * 60 * 60},
    siege_range = 90, abort_ratio = 1, field_reach = 220,
    -- a nation without any operation by push_after ticks (at peace, Age II) is pushed into a city-state operation
    push_after = 25 * 60 * 60,
    air_from = 25 * 60 * 60, scouts = 2, interceptors = 3, bombers = 3, patrol_radius = 48,
    artillery_range = 110,
    hire_at = 2500, hire_points = 8, merc_at = 2500, merc_army = 12,
  }
  -- Division controllers (ai/controller.lua): each AI division every `period` ticks (round robin), at most per_tick
  -- divisions per tick; retreat below the force ratio retreat_ratio (micro basic/full), resupply below `low` supply
  -- state, planes back below plane_supply.
  AI3.controller = {period = 60, per_tick = 6, retreat_ratio = 1, enemy_radius = 50, plane_supply = 35}
  -- Money (ai/nation.lua): contracts for a lacking good from a port holding contract_stock of it (was 2 x n = 200)
  AI3.money = {contract_stock = 100}
end

-- Phase 5 M3 world3 (docs/PHASE5-M3.md D8, §3 "worldgen.lua"; docs/qa/phase5-world3-notes.md): huge worlds (3072,
-- 4096), up to six nations, background generation (scripts/worldgen.lua). Pure data. Counts here only cover what the
-- M2 tables above do not (5-6 nations, 4096 maps); a 2048 or 3072 world of 2-4 nations is planned exactly as in M2.
balance.nation.world3 = {
  sizes = {2048, 3072, 4096},                 -- lobby world sizes (2048 the default up to 4 nations)
  max_nations = {[2048] = 4, [3072] = 6, [4096] = 6},
  spawn_ring = {[5] = 0.32, [6] = 0.33},      -- spawn ring radius x map size (2-4 nations: scripts/world.lua)
  -- contested majors on the bisectors (one per neighbour pair): with 5-6 nations still one copper region per 2 nations
  contested_order = {[5] = {"copper", "iron", "copper", "iron", "coal"},
                     [6] = {"copper", "iron", "copper", "iron", "copper", "iron"}},
  specialty_angle = {[5] = 50, [6] = 50},     -- degrees off the outward direction (2-4 nations: 72; 60 deg neighbours
                                              -- put a 72 deg specialty on the barrier between them)
  home_scale_max = 1.5,                       -- specialty, home oil: distances scale with the map up to 3072's
  center_oil_wells = {[5] = 9, [6] = 10},
  city_states = {[5] = 7, [6] = 8},
  uranium = {[5] = 2, [6] = 3},
  ports = {[5] = 5, [6] = 6},                 -- one per nation, as 4 for 4 (6 nations x 5 ports: path spread 0.151)
  rare = {[4096] = 10},
  ruins = {[4096] = 16},
  regions = {[4096] = 44},                    -- region slots (frontier regions by Poisson disc)
  region_spacing_max = 1.5,                   -- frontier region spacing 300 tiles x min(map scale, this)
  city_sites = {[4096] = 64},
  massifs = {[4096] = 4},
  -- generation (scripts/worldgen.lua): the core (the spawns' squares) is forced before the match starts, the rest is
  -- requested in the background (the city-state and port squares, feature and label chunks, then ring by ring from
  -- the spawns), `window` chunks in flight
  core = {spawn = 5, disc = 5, site = 3, port = 1}, -- chunk radius around every spawn (forced: chunk centres within
                                              -- `disc` chunks; the square's corners first in the background), around
                                              -- every city-state and port
  window = 160,                               -- requested chunks in flight (the engine fills about 39 chunks/s)
  period = 15,                                -- ticks between requester steps
  watchdog = 3600,                            -- ticks without a generated chunk before the requests are repeated
  area_max = 400,                             -- chunks per worldgen.request_area call
  hud_period = 60,                            -- ticks between HUD progress line updates
}

return balance
