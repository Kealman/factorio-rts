-- Crafting categories, the "RTS" item group, ammo categories and the raid trigger target type.
-- rts-units is crafted only by rts-barracks; rts-buildings and rts-intermediates only by rts-factory. No vanilla
-- machine and no character or god controller has these categories, so RTS recipes cannot be hand-crafted, and
-- vanilla recipes cannot be set in the RTS machines. See docs/PHASE2.md ("Data stage additions").
-- The item group's name is item-group-name.rts in locale/*/factorio-rts.cfg.
local balance = require("balance")

data:extend({
  {type = "recipe-category", name = "rts-units"},
  {type = "recipe-category", name = "rts-buildings"},
  {type = "recipe-category", name = "rts-intermediates"}, -- Phase 4: gears, cable, circuits, explosives

  -- One item group for every RTS item and recipe; the subgroups match the HUD build-menu tabs.
  {
    type = "item-group",
    name = "rts",
    order = "z[rts]",
    icon = "__base__/graphics/icons/roboport.png",
    icon_size = 64,
  },
  {type = "item-subgroup", name = "rts-economy", group = "rts", order = "a"},
  {type = "item-subgroup", name = "rts-military", group = "rts", order = "b"},
  {type = "item-subgroup", name = "rts-units", group = "rts", order = "c"},
  {type = "item-subgroup", name = "rts-defense", group = "rts", order = "d"},
  {type = "item-subgroup", name = "rts-intermediates", group = "rts", order = "f"},

  -- Raiders deal bonus damage to entities whose trigger_target_mask contains this type
  -- (docs/qa/phase4-content-notes.md).
  {type = "trigger-target-type", name = balance.raid_target_type},
})

-- One ammo category per unit role, so research can scale each role with force.set_ammo_damage_modifier(category, x)
-- (docs/PHASE4.md section 3). Unit attacks use no ammo items; the commander's rockets are the exception.
local AMMO_ICONS = {
  ["rts-walker"] = "__base__/graphics/icons/ammo-category/bullet.png",
  ["rts-heavy"] = "__base__/graphics/icons/ammo-category/cannon-shell.png",
  ["rts-drone"] = "__base__/graphics/icons/medium-biter.png",
  ["rts-raider"] = "__base__/graphics/icons/ammo-category/shotgun-shell.png",
  ["rts-artillery"] = "__base__/graphics/icons/ammo-category/artillery-shell.png",
  ["rts-commander"] = "__base__/graphics/icons/ammo-category/rocket.png",
}
local seen = {}
for _, unit in pairs(balance.units) do
  local category = unit.ammo_category
  if category and not seen[category] then
    seen[category] = true
    data:extend({{
      type = "ammo-category",
      name = category,
      icon = AMMO_ICONS[category] or "__base__/graphics/icons/ammo-category/bullet.png",
      subgroup = "ammo-category",
      bonus_gui_order = "z[rts]-" .. category,
    }})
  end
end
