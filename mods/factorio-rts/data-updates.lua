-- Data-updates stage: runs after every mod's data.lua.
-- Phase 4 research (docs/qa/phase4-research-notes.md): the lab, the science kits and the technologies, then the
-- factory learns the rts-science crafting category so it can make the kits. Appending here keeps
-- prototypes/buildings.lua untouched.
require("prototypes.research")

local factory = data.raw["assembling-machine"]["rts-factory"]
assert(factory, "factorio-rts: rts-factory must exist before data-updates")
factory.crafting_categories = factory.crafting_categories or {}
table.insert(factory.crafting_categories, "rts-science")
