-- Phase 5 M2 world (docs/PHASE5-M2.md §2 and §3 "world.lua additions / strategic.lua"): prototypes of the strategic
-- resources and the strategic layer. Nation mode places and uses them (scripts/world.lua, scripts/strategic.lua);
-- nothing autoplaces them, so Skirmish maps never hold them.
--
--   rts-uranium-ore        uranium for contested ground: a copy of the vanilla resource without the sulfuric acid, so
--                          the ordinary RTS extractor mines it into vanilla uranium ore; scripts/world.lua refuses an
--                          extractor that reaches it until the force has researched Geology
--   rts-rare-<kind>        rare deposits (deep-economy.md §3.7: saltpetre, quartz, tungsten, industrial diamonds, rare
--                          earths, gold): tinted copies of stone in their own resource category "rts-rare", which no
--                          drill mines yet (the rare extractor and the nation-wide bonuses are M3); one item each
--   rts-geology            technology (advanced kits, Nation mode only: research.lua NATION_ONLY): extractors may mine
--                          uranium
--   rts-minimap-mode       custom input N: the HUD minimap switches between the region around the camera and the
--                          whole world (scripts/strategic.lua, registered in scripts/hud.lua's key table)

local RARE = {
  saltpetre = {r = 0.92, g = 0.92, b = 0.86},
  quartz = {r = 0.85, g = 0.75, b = 0.95},
  tungsten = {r = 0.45, g = 0.5, b = 0.62},
  diamonds = {r = 0.62, g = 0.92, b = 0.98},
  ["rare-earths"] = {r = 0.75, g = 0.42, b = 0.5},
  gold = {r = 1.0, g = 0.82, b = 0.25},
}
local RARE_ORDER = {"saltpetre", "quartz", "tungsten", "diamonds", "rare-earths", "gold"}

local list = {}
local function add(p) list[#list + 1] = p end

-------------------------------------------------------------------------------
-- Uranium
-------------------------------------------------------------------------------
local vu = data.raw.resource["uranium-ore"]
assert(vu, "factorio-rts: missing vanilla uranium-ore")
local u = table.deepcopy(vu)
u.name = "rts-uranium-ore"
u.localised_name = {"entity-name.rts-uranium-ore"}
u.localised_description = {"entity-description.rts-uranium-ore"}
u.autoplace = nil
u.category = "basic-solid"
u.minable = {mining_particle = vu.minable and vu.minable.mining_particle, mining_time = (vu.minable and vu.minable.mining_time) or 2,
             result = "uranium-ore"}
u.order = "z[rts]-a[uranium]"
u.factoriopedia_simulation = nil
add(u)

-------------------------------------------------------------------------------
-- Rare deposits
-------------------------------------------------------------------------------
add({type = "resource-category", name = "rts-rare"})
local stone = data.raw.resource.stone
local stone_item = data.raw.item.stone
assert(stone and stone_item, "factorio-rts: missing vanilla stone")
local function tint_layer(layer, tint)
  if type(layer) ~= "table" then return end
  if layer.filename or layer.filenames then layer.tint = tint end
  if layer.sheet then tint_layer(layer.sheet, tint) end
  if layer.layers then for _, l in pairs(layer.layers) do tint_layer(l, tint) end end
end
for i, kind in ipairs(RARE_ORDER) do
  local tint = RARE[kind]
  local name = "rts-rare-" .. kind
  local r = table.deepcopy(stone)
  r.name = name
  r.localised_name = {"entity-name." .. name}
  r.localised_description = {"entity-description.rts-rare"}
  r.autoplace = nil
  r.category = "rts-rare"
  r.minable = {mining_particle = stone.minable and stone.minable.mining_particle, mining_time = 2, result = name}
  r.map_color = tint
  r.mining_visualisation_tint = tint
  r.order = string.format("z[rts]-b[rare]-%d", i)
  r.factoriopedia_simulation = nil
  tint_layer(r.stages, tint)
  r.icons = {{icon = stone_item.icon, icon_size = stone_item.icon_size or 64, tint = tint}}
  r.icon = nil
  add(r)
  add({
    type = "item",
    name = name,
    localised_name = {"item-name." .. name},
    localised_description = {"item-description.rts-rare"},
    icons = {{icon = stone_item.icon, icon_size = stone_item.icon_size or 64, tint = tint}},
    subgroup = "raw-resource",
    order = string.format("z[rts]-rare-%d", i),
    stack_size = 50,
    auto_recycle = false,
  })
end

-------------------------------------------------------------------------------
-- Geology (Nation mode; scripts/research.lua lists it in NATION_ONLY and its flag "geology")
-------------------------------------------------------------------------------
add({
  type = "technology",
  name = "rts-geology",
  localised_name = {"technology-name.rts-geology"},
  localised_description = {"technology-description.rts-geology"},
  icons = {{icon = "__base__/graphics/technology/uranium-processing.png", icon_size = 256}},
  unit = {count = 30, ingredients = {{"rts-science-advanced", 1}}, time = 10},
  order = "z[rts]-9-geology", -- last in tree order: the AI researches it after everything else
})

-------------------------------------------------------------------------------
-- N: regional / world minimap
-------------------------------------------------------------------------------
add({type = "custom-input", name = "rts-minimap-mode", key_sequence = "N", consuming = "game-only",
     order = "z[rts]-90"})

data:extend(list)
