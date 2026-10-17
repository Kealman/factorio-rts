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
-- Phase 5 M3 air (docs/qa/phase5-air-notes.md): planes, the airfield, the AA turret, Aviation and Air Force, and the
-- air / structure masks of every RTS turret and building (last: it edits the prototypes defined before it).
require("prototypes.air")
