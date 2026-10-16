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

return balance
