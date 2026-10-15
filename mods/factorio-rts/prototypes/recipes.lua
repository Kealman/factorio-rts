-- Phase 2 recipes. All are enabled from the start (no research in Phase 2) and hidden from the player's
-- crafting screen: rts-units recipes run only in rts-barracks, rts-buildings recipes only in rts-factory.
-- Costs follow docs/PHASE2.md. Belts, inserters, poles and ammo produce the vanilla items.
-- The rts-smelter uses the vanilla "smelting" recipes (iron, copper, stone brick, steel).

local function ingredients(list)
  local r = {}
  for name, amount in pairs(list) do
    r[#r + 1] = {type = "item", name = name, amount = amount}
  end
  table.sort(r, function(a, b) return a.name < b.name end) -- stable order for the tooltip
  return r
end

-- spec: name, category, subgroup, order, time (s), cost {item = amount}, result (default name), count.
local function recipe(spec)
  return {
    type = "recipe",
    name = spec.name,
    category = spec.category,
    subgroup = spec.subgroup,
    order = spec.order,
    enabled = true,
    hide_from_player_crafting = true,
    auto_recycle = false, -- quality mod: do not generate (or overwrite vanilla) recycling recipes
    energy_required = spec.time,
    ingredients = ingredients(spec.cost),
    results = {{type = "item", name = spec.result or spec.name, amount = spec.count or 1}},
  }
end

local U, B = "rts-units", "rts-buildings"

data:extend({
  -- Barracks
  recipe({name = "rts-walker-kit", category = U, subgroup = "rts-units", order = "a", time = 3,
          cost = {["iron-plate"] = 10, ["copper-plate"] = 2}}),
  recipe({name = "rts-walker-heavy-kit", category = U, subgroup = "rts-units", order = "b", time = 8,
          cost = {["iron-plate"] = 30, ["copper-plate"] = 10, ["steel-plate"] = 5}}),

  -- Factory: economy
  recipe({name = "rts-extractor", category = B, subgroup = "rts-economy", order = "c", time = 5,
          cost = {["iron-plate"] = 20, ["copper-plate"] = 5}}),
  recipe({name = "rts-smelter", category = B, subgroup = "rts-economy", order = "d", time = 5,
          cost = {["iron-plate"] = 20, ["stone"] = 10}}),
  recipe({name = "rts-solar-array", category = B, subgroup = "rts-economy", order = "e", time = 4,
          cost = {["copper-plate"] = 15, ["iron-plate"] = 10}}),
  recipe({name = "rts-factory", category = B, subgroup = "rts-economy", order = "f", time = 10,
          cost = {["iron-plate"] = 60, ["copper-plate"] = 20}}),
  recipe({name = "rts-belt", category = B, subgroup = "rts-economy", order = "g", time = 2,
          cost = {["iron-plate"] = 10}, result = "transport-belt", count = 10}),
  recipe({name = "rts-inserter", category = B, subgroup = "rts-economy", order = "h", time = 2,
          cost = {["iron-plate"] = 10, ["copper-plate"] = 5}, result = "fast-inserter", count = 5}),
  recipe({name = "rts-pole", category = B, subgroup = "rts-economy", order = "i", time = 2,
          cost = {["copper-plate"] = 5, ["iron-plate"] = 5}, result = "medium-electric-pole", count = 5}),

  -- Factory: military and defense
  recipe({name = "rts-barracks", category = B, subgroup = "rts-military", order = "a", time = 10,
          cost = {["iron-plate"] = 60, ["copper-plate"] = 20}}),
  recipe({name = "rts-turret", category = B, subgroup = "rts-defense", order = "a", time = 6,
          cost = {["iron-plate"] = 40, ["copper-plate"] = 10}}),
  recipe({name = "rts-ammo", category = B, subgroup = "rts-defense", order = "b", time = 3,
          cost = {["iron-plate"] = 10}, result = "firearm-magazine", count = 10}),
})

-- The heavy kit needs steel. Furnaces only pick recipes that are enabled for the force, and vanilla
-- steel-plate waits for the steel-processing research, so enable it from the start.
data.raw.recipe["steel-plate"].enabled = true
