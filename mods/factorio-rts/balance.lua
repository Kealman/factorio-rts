-- Balance data shared by the data stage (prototypes/*.lua) and the control stage (scripts/*.lua).
--
--   local balance = require("balance")   -- works in both stages (mod root is on the require path)
--
-- Pure data: no data.raw, no game / prototypes access, no functions. `require` caches the table per stage, so treat it
-- as read-only. The prototypes read costs, times, health and combat numbers from here, so changing a number here
-- changes the game (after a restart). See docs/qa/phase4-content-notes.md ("Balance table API").
--
-- Units: balance.units[unit prototype name] = {
--   kind           units.lua kind ("walker", "heavy", "drone", "raider", "artillery", "commander"). mk2 tiers share the
--                  kind of their base unit, so counts and AI logic treat them alike; `tier` tells them apart.
--   tier           1 or 2 (mk2)          base   tier-1 unit an mk2 replaces (mk2 only)
--   role           short role tag for AI / HUD
--   supply         command capacity the unit uses (docs/PHASE4.md section 1)
--   kit            kit item the barracks makes (nil = not produced by barracks)
--   cost, time     kit recipe ingredients {item = amount} and seconds
--   unlock         technology that unlocks the unit (informational, mirrors scripts/research.lua EFFECTS / LOCKS).
--                  Kit recipes of tier-1 units are always enabled: the barracks gate in scripts/research.lua refuses
--                  locked units. mk2 kit recipes start disabled (research deploys mk2 units from tier-1 kits).
--   health         max health
--   speed          design target, relative to the walker (drone >= 1.4, raider 1.3, artillery 0.6); the commander's
--                  is relative to the vanilla spidertron. Measured speeds are in the notes.
--   range, min_range, cooldown (ticks), damage (per hit), damage_type, splash (radius, tiles)
--   raid_multiplier  raider only: total damage multiplier against `balance.raid_target_type` entities
--   ammo_category  the attack's ammo category: force.set_ammo_damage_modifier(category, x) scales it
--   strong, weak   counter wheel (docs/PHASE4.md section 3): kinds plus "building", "turret", "laser-turret",
--                  "hauler", "wall"
-- }
-- Buildings: balance.buildings[entity name] = {kind, cost, time, count (items per craft, default 1), health,
--   unlock?, supply_provided?, power?} -- `kind` is the scripts/buildings.lua registry kind (new ones are proposals:
--   scripts/buildings.lua KIND_BY_NAME does not list them yet). No cost = not made by the factory. `unlock` names the
--   technology; such recipes start disabled and scripts/research.lua enables them per force.
-- Intermediates: balance.intermediates[recipe name] = {result, count, cost, time} (rts-factory, category
--   rts-intermediates). balance.smelting[vanilla recipe] = {cost, time}: overrides of vanilla smelting recipes.

local balance = {}

-- Trigger target type of everything raiders deal bonus damage to (economy buildings, poles, haulers, hubs).
-- An entity prototype opts in with trigger_target_mask = {"common", balance.raid_target_type}.
balance.raid_target_type = "rts-raid-target"

balance.units = {
  ["rts-walker"] = {
    kind = "walker", tier = 1, role = "line", supply = 1,
    kit = "rts-walker-kit", cost = {["iron-plate"] = 10, ["copper-plate"] = 2}, time = 3,
    health = 200, speed = 1.0,
    range = 20, cooldown = 60, damage = 20,
    ammo_category = "rts-walker",
    strong = {"drone"}, weak = {"heavy", "artillery"},
  },
  ["rts-walker-heavy"] = {
    kind = "heavy", tier = 1, role = "tank", supply = 3,
    kit = "rts-walker-heavy-kit", cost = {["iron-plate"] = 30, ["copper-plate"] = 10, ["steel-plate"] = 5}, time = 8,
    unlock = "rts-unlock-heavy",
    -- Base-game variant: hitscan 60 explosion every 90 ticks, range 12. Space Age variant: the small stomper's acid
    -- stream with damage_modifier 2, range 10 (prototypes/units.lua).
    health = 600, speed = 0.75,
    range = 12, cooldown = 90, damage = 60, damage_modifier = 2,
    ammo_category = "rts-heavy",
    strong = {"walker", "drone"}, weak = {"artillery", "laser-turret"},
  },
  ["rts-drone"] = {
    kind = "drone", tier = 1, role = "swarm", supply = 1,
    kit = "rts-drone-kit", cost = {["iron-plate"] = 6}, time = 2,
    health = 60, speed = 1.5,
    range = 1, cooldown = 30, damage = 10, damage_type = "physical",
    ammo_category = "rts-drone",
    strong = {"artillery", "hauler", "raider"}, weak = {"turret", "walker"},
  },
  ["rts-raider"] = {
    kind = "raider", tier = 1, role = "raid", supply = 2,
    kit = "rts-raider-kit", cost = {["iron-plate"] = 15, ["electronic-circuit"] = 8}, time = 5,
    unlock = "rts-unlock-raider",
    health = 120, speed = 1.3,
    range = 12, cooldown = 30, damage = 8, raid_multiplier = 3,
    ammo_category = "rts-raider",
    strong = {"hauler", "building"}, weak = {"walker", "turret"},
  },
  ["rts-artillery"] = {
    kind = "artillery", tier = 1, role = "siege", supply = 4,
    kit = "rts-artillery-kit", cost = {["iron-plate"] = 40, ["steel-plate"] = 10, ["rts-explosives"] = 10},
    time = 12, unlock = "rts-unlock-artillery",
    health = 250, speed = 0.6,
    range = 40, min_range = 8, cooldown = 240, damage = 100, damage_type = "explosion", splash = 4,
    ammo_category = "rts-artillery",
    strong = {"turret", "laser-turret", "heavy", "wall"}, weak = {"drone", "raider"},
  },
  ["rts-walker-mk2"] = {
    kind = "walker", tier = 2, base = "rts-walker", role = "line", supply = 1,
    kit = "rts-walker-mk2-kit", cost = {["iron-plate"] = 10, ["copper-plate"] = 2, ["steel-plate"] = 5}, time = 3,
    unlock = "rts-armor-1",
    health = 280, speed = 1.0, -- +40 % health
    range = 20, cooldown = 60, damage = 25, -- +25 % damage
    ammo_category = "rts-walker",
    strong = {"drone"}, weak = {"heavy", "artillery"},
  },
  ["rts-heavy-mk2"] = {
    kind = "heavy", tier = 2, base = "rts-walker-heavy", role = "tank", supply = 3,
    kit = "rts-heavy-mk2-kit", cost = {["iron-plate"] = 30, ["copper-plate"] = 10, ["steel-plate"] = 10}, time = 8,
    unlock = "rts-armor-1",
    health = 840, speed = 0.75,
    range = 12, cooldown = 90, damage = 75, damage_modifier = 2.5,
    ammo_category = "rts-heavy",
    strong = {"walker", "drone"}, weak = {"artillery", "laser-turret"},
  },
  ["rts-commander"] = {
    kind = "commander", tier = 1, role = "hero", supply = 0, -- spawned by script, one per player, no kit
    health = 2000, speed = 1.2, -- relative to the vanilla spidertron
    range = 30, cooldown = 30, damage = 40, damage_type = "explosion", -- per rocket, two launchers
    ammo_category = "rts-commander", ammo = "rts-commander-rocket",
    strong = {}, weak = {},
  },
}

balance.buildings = {
  -- Phase 2 buildings (values unchanged; prototypes/buildings.lua and recipes.lua read them from here)
  ["rts-command-center"] = {kind = "cc", health = 3000, supply_provided = 40}, -- match start only
  ["rts-stockpile"] = {kind = "stockpile", cost = {["iron-plate"] = 20, ["copper-plate"] = 5}, time = 4, health = 800},
  ["rts-extractor"] = {kind = "extractor", cost = {["iron-plate"] = 20, ["copper-plate"] = 5}, time = 5, health = 500},
  ["rts-smelter"] = {kind = "smelter", cost = {["iron-plate"] = 20, ["stone"] = 10}, time = 5, health = 600},
  ["rts-solar-array"] = {kind = "solar", cost = {["copper-plate"] = 15, ["iron-plate"] = 10}, time = 4, health = 300,
                         power = "400kW"},
  ["rts-factory"] = {kind = "factory", cost = {["iron-plate"] = 60, ["copper-plate"] = 20}, time = 10, health = 1000},
  ["rts-barracks"] = {kind = "barracks", cost = {["iron-plate"] = 60, ["copper-plate"] = 20}, time = 10, health = 1500},
  ["rts-turret"] = {kind = "turret", cost = {["iron-plate"] = 40, ["copper-plate"] = 10}, time = 6, health = 1200},
  -- Phase 4 defence and power
  ["rts-laser-turret"] = {kind = "laser-turret", cost = {["iron-plate"] = 20, ["electronic-circuit"] = 10}, time = 8,
                          health = 1000, unlock = "rts-unlock-laser", power = "2MW", -- peak input; 800 kJ per shot
                          range = 22, cooldown = 40, damage = 30},
  ["rts-wall"] = {kind = "wall", cost = {["stone-brick"] = 5}, count = 5, time = 2, health = 500},
  ["rts-steam-plant"] = {kind = "steam-plant", cost = {["iron-plate"] = 40, ["steel-plate"] = 10}, time = 10,
                         health = 800, unlock = "rts-steam-power", power = "1.8MW", fuel = "coal"},
  ["rts-accumulator"] = {kind = "accumulator", cost = {["iron-plate"] = 10, ["copper-plate"] = 10}, time = 4,
                         health = 300},
  ["rts-radar"] = {kind = "radar", cost = {["iron-plate"] = 20, ["electronic-circuit"] = 10}, time = 6, health = 400,
                   reveal_chunks = 2}, -- radius: a 5x5-chunk square (160x160 tiles) stays visible
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
