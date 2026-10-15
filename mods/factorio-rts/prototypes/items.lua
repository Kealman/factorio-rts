-- Phase 2 items: one placeable item per RTS building and the two unit kits made by the barracks.
-- Building items copy the vanilla item (sounds, weight) and take the tinted icon from their rts entity,
-- so prototypes/buildings.lua must be loaded first. The core power and core pole have no item.
-- Names come from the locale: item-name.<name>; building items reuse entity-description.<name>, kits have
-- item-description.<name> (locale/*/factorio-rts.cfg).
-- Belts, inserters, poles and ammo use the vanilla items (transport-belt, fast-inserter,
-- medium-electric-pole, firearm-magazine); see prototypes/recipes.lua.

local function building_item(spec)
  local entity = data.raw[spec.type][spec.name]
  assert(entity, "factorio-rts: building " .. spec.name .. " must be defined before its item")
  local item = table.deepcopy(data.raw.item[spec.source])
  assert(item, "factorio-rts: missing vanilla item " .. spec.source)
  item.name = spec.name
  item.localised_name = nil -- item-name.<name>
  item.localised_description = {"entity-description." .. spec.name}
  item.icons = table.deepcopy(entity.icons)
  item.icon = nil
  item.icon_size = nil
  item.place_result = spec.name
  item.subgroup = spec.subgroup
  item.order = spec.order
  item.stack_size = spec.stack_size
  item.auto_recycle = false -- quality mod: no self-recycling recipe for RTS items
  return item
end

-- Kit icons: the Space Age pentapods when available, else the base spidertron icon in two tints.
local function kit_icons(pentapod, tint)
  if mods["space-age"] then
    local unit = data.raw["spider-unit"][pentapod]
    if unit then
      return unit.icons and table.deepcopy(unit.icons) or {{icon = unit.icon, icon_size = unit.icon_size}}
    end
  end
  return {{icon = "__base__/graphics/icons/spidertron.png", tint = tint}}
end

local function kit_item(spec)
  return {
    type = "item",
    name = spec.name,
    icons = kit_icons(spec.pentapod, spec.tint),
    subgroup = "rts-units",
    order = spec.order,
    stack_size = 10,
    auto_recycle = false,
  }
end

data:extend({
  building_item({type = "roboport", name = "rts-command-center", source = "roboport",
                 subgroup = "rts-economy", order = "a[command-center]", stack_size = 1}),
  building_item({type = "logistic-container", name = "rts-stockpile", source = "storage-chest",
                 subgroup = "rts-economy", order = "b[stockpile]", stack_size = 50}),
  building_item({type = "mining-drill", name = "rts-extractor", source = "electric-mining-drill",
                 subgroup = "rts-economy", order = "c[extractor]", stack_size = 50}),
  building_item({type = "furnace", name = "rts-smelter", source = "electric-furnace",
                 subgroup = "rts-economy", order = "d[smelter]", stack_size = 50}),
  building_item({type = "solar-panel", name = "rts-solar-array", source = "solar-panel",
                 subgroup = "rts-economy", order = "e[solar-array]", stack_size = 50}),
  building_item({type = "assembling-machine", name = "rts-factory", source = "assembling-machine-2",
                 subgroup = "rts-economy", order = "f[factory]", stack_size = 10}),
  building_item({type = "assembling-machine", name = "rts-barracks", source = "assembling-machine-2",
                 subgroup = "rts-military", order = "a[barracks]", stack_size = 10}),
  building_item({type = "ammo-turret", name = "rts-turret", source = "gun-turret",
                 subgroup = "rts-defense", order = "a[turret]", stack_size = 50}),

  kit_item({name = "rts-walker-kit", order = "a[walker-kit]",
            pentapod = "small-strafer-pentapod", tint = {r = 0.6, g = 0.85, b = 1.0, a = 1}}),
  kit_item({name = "rts-walker-heavy-kit", order = "b[walker-heavy-kit]",
            pentapod = "small-stomper-pentapod", tint = {r = 1.0, g = 0.6, b = 0.4, a = 1}}),
})
