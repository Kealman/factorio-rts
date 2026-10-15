-- Phase 2 crafting categories and the "RTS" item group.
-- rts-units is crafted only by rts-barracks, rts-buildings only by rts-factory. No vanilla machine and no
-- character or god controller has these categories, so RTS recipes cannot be hand-crafted, and vanilla
-- recipes cannot be set in the RTS machines. See docs/PHASE2.md ("Data stage additions").
-- Names use the {"?", key, fallback} form: the English fallback shows until a locale entry is added.

local function label(key, text)
  return {"?", {key}, text}
end

data:extend({
  {type = "recipe-category", name = "rts-units"},
  {type = "recipe-category", name = "rts-buildings"},

  -- One item group for every RTS item and recipe; the subgroups match the HUD build-menu tabs.
  {
    type = "item-group",
    name = "rts",
    localised_name = label("item-group-name.rts", "RTS"),
    order = "z[rts]",
    icon = "__base__/graphics/icons/roboport.png",
    icon_size = 64,
  },
  {type = "item-subgroup", name = "rts-economy", group = "rts", order = "a"},
  {type = "item-subgroup", name = "rts-military", group = "rts", order = "b"},
  {type = "item-subgroup", name = "rts-units", group = "rts", order = "c"},
  {type = "item-subgroup", name = "rts-defense", group = "rts", order = "d"},
})
