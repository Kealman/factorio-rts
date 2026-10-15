-- Spike #4 data stage: a "barracks" crafting category, a unit item and the barracks entity.
-- Graphics are vanilla. The barracks uses a void energy source so power is not a variable
-- in this spike; the real mod will use an electric energy source.

data:extend({
  {
    type = "recipe-category",
    name = "rts-barracks",
  },
  {
    type = "item",
    name = "rts-marine-kit",
    icon = "__base__/graphics/icons/submachine-gun.png",
    subgroup = "intermediate-product",
    order = "z[rts]-a[rts-marine-kit]",
    stack_size = 10,
  },
  {
    type = "recipe",
    name = "rts-marine-kit",
    category = "rts-barracks",
    enabled = true,
    energy_required = 3,
    ingredients = {
      { type = "item", name = "iron-plate", amount = 2 },
      { type = "item", name = "copper-plate", amount = 1 },
    },
    results = {
      { type = "item", name = "rts-marine-kit", amount = 1 },
    },
  },
})

local barracks = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-1"])
barracks.name = "rts-barracks"
barracks.minable = { mining_time = 0.2, result = "rts-barracks" }
barracks.crafting_categories = { "rts-barracks" }
barracks.crafting_speed = 1
barracks.energy_source = { type = "void" }
barracks.next_upgrade = nil
barracks.fast_replaceable_group = nil

local barracks_item = table.deepcopy(data.raw["item"]["assembling-machine-1"])
barracks_item.name = "rts-barracks"
barracks_item.place_result = "rts-barracks"
barracks_item.order = "z[rts]-b[rts-barracks]"

data:extend({
  barracks,
  barracks_item,
  {
    type = "recipe",
    name = "rts-barracks",
    enabled = true,
    energy_required = 2,
    ingredients = {
      { type = "item", name = "iron-plate", amount = 20 },
      { type = "item", name = "iron-gear-wheel", amount = 5 },
    },
    results = {
      { type = "item", name = "rts-barracks", amount = 1 },
    },
  },
})
