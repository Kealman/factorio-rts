-- Items: one placeable item per RTS building, the unit kits made by the barracks and the commander item.
-- Phase 4 adds the laser turret, wall, steam plant, accumulator and radar items, the drone / raider / artillery /
-- mk2 kits and rts-commander (docs/qa/phase4-content-notes.md). The explosives item is in intermediates.lua.
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

-- Kit icons: the Space Age pentapods when available, else the base spidertron icon tinted per kit. `icon` overrides
-- both (the drone uses the medium biter in either variant). mk2 kits add a gold tint to the whole icon.
local function icon_layers(proto)
  return proto.icons and table.deepcopy(proto.icons) or {{icon = proto.icon, icon_size = proto.icon_size}}
end

local function kit_icons(spec)
  local icons
  if spec.icon then
    icons = {{icon = spec.icon, tint = spec.tint}}
  elseif mods["space-age"] and data.raw["spider-unit"][spec.pentapod] then
    icons = icon_layers(data.raw["spider-unit"][spec.pentapod])
  else
    icons = {{icon = "__base__/graphics/icons/spidertron.png", tint = spec.tint}}
  end
  if spec.mk2 then
    for _, layer in pairs(icons) do layer.tint = {r = 1.0, g = 0.85, b = 0.35, a = 1} end
  end
  return icons
end

local function kit_item(spec)
  return {
    type = "item",
    name = spec.name,
    icons = kit_icons(spec),
    subgroup = "rts-units",
    order = spec.order,
    stack_size = 10,
    auto_recycle = false,
  }
end

-- The commander is spawned by script (one per player): its item exists for icons and the editor, no recipe.
local function commander_item()
  local item = table.deepcopy(data.raw["item-with-entity-data"]["spidertron"])
  assert(item, "factorio-rts: missing vanilla item spidertron")
  item.name = "rts-commander"
  item.localised_name = nil
  item.localised_description = nil
  item.place_result = "rts-commander"
  item.subgroup = "rts-units"
  item.order = "z[commander]"
  item.stack_size = 1
  item.auto_recycle = false
  return item
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

  -- Phase 4 buildings
  building_item({type = "electric-turret", name = "rts-laser-turret", source = "laser-turret",
                 subgroup = "rts-defense", order = "c[laser-turret]", stack_size = 50}),
  building_item({type = "wall", name = "rts-wall", source = "stone-wall",
                 subgroup = "rts-defense", order = "d[wall]", stack_size = 100}),
  building_item({type = "radar", name = "rts-radar", source = "radar",
                 subgroup = "rts-defense", order = "e[radar]", stack_size = 50}),
  building_item({type = "burner-generator", name = "rts-steam-plant", source = "steam-engine",
                 subgroup = "rts-economy", order = "g[steam-plant]", stack_size = 10}),
  building_item({type = "accumulator", name = "rts-accumulator", source = "accumulator",
                 subgroup = "rts-economy", order = "h[accumulator]", stack_size = 50}),

  kit_item({name = "rts-walker-kit", order = "a[walker-kit]",
            pentapod = "small-strafer-pentapod", tint = {r = 0.6, g = 0.85, b = 1.0, a = 1}}),
  kit_item({name = "rts-walker-heavy-kit", order = "b[walker-heavy-kit]",
            pentapod = "small-stomper-pentapod", tint = {r = 1.0, g = 0.6, b = 0.4, a = 1}}),
  kit_item({name = "rts-drone-kit", order = "c[drone-kit]",
            icon = "__base__/graphics/icons/medium-biter.png", tint = {r = 0.52, g = 0.58, b = 0.64, a = 1}}),
  kit_item({name = "rts-raider-kit", order = "d[raider-kit]",
            pentapod = "medium-strafer-pentapod", tint = {r = 0.6, g = 1.0, b = 0.6, a = 1}}),
  kit_item({name = "rts-artillery-kit", order = "e[artillery-kit]",
            pentapod = "medium-stomper-pentapod", tint = {r = 1.0, g = 0.45, b = 0.45, a = 1}}),
  kit_item({name = "rts-walker-mk2-kit", order = "f[walker-mk2-kit]", mk2 = true,
            pentapod = "small-strafer-pentapod"}),
  kit_item({name = "rts-heavy-mk2-kit", order = "g[heavy-mk2-kit]", mk2 = true,
            pentapod = "small-stomper-pentapod"}),

  commander_item(),
})
