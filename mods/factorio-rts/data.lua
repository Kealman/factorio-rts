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
