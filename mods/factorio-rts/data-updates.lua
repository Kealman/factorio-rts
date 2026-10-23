-- Data-updates stage: runs after every mod's data.lua.
-- Phase 4 research (docs/qa/phase4-research-notes.md): the lab, the science kits and the technologies, then the
-- factory learns the rts-science crafting category so it can make the kits. Appending here keeps
-- prototypes/buildings.lua untouched.
require("prototypes.research")

local factory = data.raw["assembling-machine"]["rts-factory"]
assert(factory, "factorio-rts: rts-factory must exist before data-updates")
factory.crafting_categories = factory.crafting_categories or {}
table.insert(factory.crafting_categories, "rts-science")

-- Phase 5 E1 (docs/qa/phase5-economy-notes.md): Age II goods, buildings, technologies and the ten districts. After the
-- research prototypes (rts-lab, kits, the factory's rts-science category) and after every data.lua (m1-rails' rts-rail).
require("prototypes.age2")
require("prototypes.districts")
-- Phase 5 M2 people (docs/qa/phase5-people-notes.md): houses, the food chain, goods, hidden labor modules and the labor
-- slot on every staffed machine (after the districts: they get the slot too).
require("prototypes.people")
-- Phase 5 M3 age3 (docs/qa/phase5-age3-notes.md): Age III districts, the nuclear plant, automation kits, the rare
-- extractor, the Launch complex and the Age III technologies (after the people prototypes: the districts' labor slot is
-- widened for the kits).
require("prototypes.age3")
-- Phase 5 M3 air (docs/qa/phase5-air-notes.md): planes, the airfield, the AA turret, Aviation and Air Force, and the
-- air / structure masks of every RTS turret and building (last: it edits the prototypes defined before it).
require("prototypes.air")

-- Factorio 2.1 removed MapSettings::steering and gave every unit / spider-unit prototype its own steering. In 2.0 every
-- RTS unit used the map defaults below (data.raw["map-settings"] of 2.0.77); in 2.1 they inherit the steering of the
-- vanilla pentapod / biter they are copied from (spider-units: stay radius 3.6 with separation force 0.1, about 20x the
-- 2.0 push). Restore the 2.0 values on every RTS unit (after prototypes.air: the planes are units too).
local STEERING_2_0 = {move = {radius = 3, separation_force = 0.01, separation_factor = 3},
                      stay = {radius = 1.2, separation_force = 0.005, separation_factor = 1.2}}
for _, type_name in ipairs({"unit", "spider-unit"}) do
  for name, proto in pairs(data.raw[type_name] or {}) do
    if string.sub(name, 1, 4) == "rts-" then proto.steering = table.deepcopy(STEERING_2_0) end
  end
end
