-- Data stage entry point. Every prototype lives in prototypes/*.
require("balance") -- Phase 4 balance table (mod root), shared with the control stage; prototypes/* read it
require("prototypes.map-settings")
require("prototypes.units")
require("prototypes.categories") -- Phase 2: crafting categories and the RTS item group
require("prototypes.buildings")  -- Phase 2: CC composite and buildings (before items)
require("prototypes.items")
require("prototypes.recipes")
require("prototypes.intermediates") -- Phase 4: rts-explosives and the factory's gear / cable / circuit recipes
require("prototypes.cursor")
require("prototypes.inputs")
require("prototypes.styles")
require("prototypes.controller") -- RTS-paced remote view panning
require("prototypes.logistics") -- Phase 4: hub composite, hauler, their items and recipes (after cursor)
require("prototypes.rails") -- Phase 5 M1: rail depot, train stop, rolling stock, kits, Railways / Bridges technologies
require("prototypes.abilities") -- Phase 4: Commander grid equipment and the stim sticker
require("prototypes.cities") -- Phase 5 M1: City Center, City charter, fort, rts-attrition damage type (Nation mode)
require("prototypes.world") -- Phase 5 M1: Nation-mode world tiles (mountain, ford, marsh) and noise (scripts/world.lua)
require("prototypes.world2") -- Phase 5 M2 world: uranium, rare deposits, Geology, the N key (scripts/world.lua, strategic.lua)
require("prototypes.trade") -- Phase 5 M2 treasury: trade post (hub subtype at world ports), Commerce I/II, market key M
