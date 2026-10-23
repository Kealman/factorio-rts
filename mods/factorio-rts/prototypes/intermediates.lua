-- Phase 4 intermediates (docs/PHASE4.md 2.5 "Chains"). The vanilla iron-gear-wheel, copper-cable,
-- electronic-circuit, steel-plate and stone-brick items are reused; rts-explosives is new (coal + iron).
-- The rts-factory crafts the recipes below (category rts-intermediates); its output goes to the logistic network
-- like any factory product (scripts/production.lua). Steel and stone bricks are vanilla smelting recipes in the
-- rts-smelter (prototypes/recipes.lua enables steel and applies balance.smelting).
-- Costs: balance.intermediates.
local balance = require("balance")

local explosives = table.deepcopy(data.raw.item["explosives"])
assert(explosives, "factorio-rts: missing vanilla item explosives")
explosives.name = "rts-explosives"
explosives.localised_name = nil
explosives.localised_description = nil
explosives.subgroup = "rts-intermediates"
explosives.order = "e[explosives]"
explosives.stack_size = 100
explosives.auto_recycle = false
explosives.icons = {{icon = explosives.icon, icon_size = explosives.icon_size,
                     tint = {r = 1, g = 0.8, b = 0.55, a = 1}}}
explosives.icon = nil
explosives.icon_size = nil
data:extend({explosives})

local ORDER = {["rts-gear"] = "a", ["rts-cable"] = "b", ["rts-circuit"] = "c", ["rts-explosives"] = "e"}

for name, spec in pairs(balance.intermediates) do
  local ingredients = {}
  for item, amount in pairs(spec.cost) do
    ingredients[#ingredients + 1] = {type = "item", name = item, amount = amount}
  end
  table.sort(ingredients, function(a, b) return a.name < b.name end)
  data:extend({{
    type = "recipe",
    name = name,
    categories = {"rts-intermediates"}, -- 2.1: RecipePrototype::category -> categories
    subgroup = "rts-intermediates",
    order = ORDER[name] or "z",
    enabled = true,
    hide_from_player_crafting = true,
    auto_recycle = false, -- quality mod: never generate (or overwrite vanilla) recycling recipes from these
    energy_required = spec.time,
    ingredients = ingredients,
    results = {{type = "item", name = spec.result, amount = spec.count}},
  }})
end
