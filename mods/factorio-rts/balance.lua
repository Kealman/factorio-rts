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
  ["rts-dra-rail"] = {category = "rts-district-rails", cost = {["steel-plate"] = 4, stone = 2},
                      results = {rail = 8}, time = 4, order = "a"}, -- vanilla rail (m1-rails' item)
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
  rail = {cost = {["steel-plate"] = 2, ["stone"] = 1}, count = 2, time = 2},  -- recipe rts-rail -> 2 "rail"
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
    keep_minutes = 2, farm_per = 150, bakery_farms = 2.5, free_housing = 20, start_after = 300, house_after = 150,
    period = 5 * 60, house_gap = 10, max_queued = 3, export_extra = 50, brick_target = 20,
    -- from start_after, houses while the housing is below the city's jobs / workforce share + job_margin residents
    -- (the margin keeps recruits for the army; houses beyond it only fed goods demand)
    job_margin = 80, house_radius = {24, 40, 56},
    -- a second factory on Auto at the capital from start_after: goods and their bricks took the works factory's time
    -- from the circuits of the Industrialisation kits (the economic AI researched it in 7.5 minutes instead of 3.5)
    goods_works = true,
    -- houses in stock at the capital from start_after (a make target: the Auto factories make them, so the builder
    -- factory keeps to the build order)
    house_stock = 3,
    priorities = {"power", "food", "extraction", "metallurgy", "research", "military", "services", "electronics",
                  "chemistry"},
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
    territory_share = 0.60, territory_minutes = 3,
    modes = {"conquest", "territory", "score"}, default_mode = "conquest",
    time_limits = {60, 90, 120, 0}, default_time_limit = 0, score_default_limit = 60, -- minutes; 0 = unlimited
  },
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
    skip_names = {["rts-city-center"] = true, ["rts-trade-post"] = true},
    crafter_kinds = {factory = true, barracks = true, district = true},
  },
  army = {per_supply = 1, free = 0}, -- cr per supply point of military units per minute (haulers excluded)
  transport = {locomotive = 2, rail_tiles = 100}, -- cr per locomotive per minute, 1 cr per this many tiles of line
  interest = {rate = 0.05, period = 5 * 60 * 60}, -- 5 % of the debt every 5 minutes
  credit = {minutes = 10, min = 500}, -- credit line: 10 minutes of gross income (tax + exports), at least `min`
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
    coal_keep = 60,            -- coal the port keeps for the haulers' return trips (never sold)
    buy_after = 3 * 60 * 60,   -- a shortfall the AI cannot fill within this long is bought
    buy_horizon = 3,           -- minutes: a shortfall short > made per minute x horizon cannot be filled in time
    reserve = 500,             -- the AI never buys below this balance
    spend_share = 0.25,        -- share of the balance one purchase may cost
    keep_minutes = 10,         -- a raised Command Center keep for an import is restored after this long
    deficit_floor = 1500,      -- below this balance with a negative net: tax high, no imports, deficit mode
    deficit_surplus = 0.5,     -- deficit mode: the capital exports from this share of the surplus thresholds
    happy_low = 40,            -- tax low below this happiness
    war_window = 2 * 60 * 60,  -- without diplomacy: "at war" while an own group attacked or defended this recently
  },
}
balance.buildings["rts-trade-post"] = {kind = "hub", supply_cap = 0}

return balance
