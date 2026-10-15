-- Recipes. All are hidden from the player's crafting screen: rts-units recipes run only in rts-barracks,
-- rts-buildings (and rts-intermediates, see intermediates.lua) only in rts-factory.
-- Unit kit and building costs come from balance.lua (balance.units[*].kit/cost/time, balance.buildings[*].cost/time).
-- Research gating (scripts/research.lua): building recipes with a balance `unlock` (laser turret, steam plant) start
-- disabled and research enables them per force. Tier-1 kit recipes stay enabled (the barracks gate refuses locked
-- units); mk2 kit recipes start disabled because research deploys mk2 units from tier-1 kits after Armor I.
-- Belts, inserters, poles and ammo produce the vanilla items.
-- The rts-smelter uses the vanilla "smelting" recipes (iron, copper, stone brick, steel); balance.smelting
-- overrides some of them (steel: 2 iron plates).
local balance = require("balance")

local function ingredients(list)
  local r = {}
  for name, amount in pairs(list) do
    r[#r + 1] = {type = "item", name = name, amount = amount}
  end
  table.sort(r, function(a, b) return a.name < b.name end) -- stable order for the tooltip
  return r
end

-- spec: name, category, subgroup, order, time (s), cost {item = amount}, result (default name), count, enabled.
local function recipe(spec)
  return {
    type = "recipe",
    name = spec.name,
    category = spec.category,
    subgroup = spec.subgroup,
    order = spec.order,
    enabled = spec.enabled ~= false,
    hide_from_player_crafting = true,
    auto_recycle = false, -- quality mod: do not generate (or overwrite vanilla) recycling recipes
    energy_required = spec.time,
    ingredients = ingredients(spec.cost),
    results = {{type = "item", name = spec.result or spec.name, amount = spec.count or 1}},
  }
end

local U, B = "rts-units", "rts-buildings"

-- Barracks: one recipe per kit, named like the kit. order: kit order in the barracks recipe grid.
local KIT_ORDER = {
  ["rts-walker"] = "a", ["rts-walker-heavy"] = "b", ["rts-drone"] = "c", ["rts-raider"] = "d",
  ["rts-artillery"] = "e", ["rts-walker-mk2"] = "f", ["rts-heavy-mk2"] = "g",
}
for unit, order in pairs(KIT_ORDER) do
  local u = balance.units[unit]
  data:extend({recipe({name = u.kit, category = U, subgroup = "rts-units", order = order, time = u.time,
                       cost = u.cost, enabled = u.tier ~= 2})})
end

-- Factory: buildings. {name, subgroup, order}
local BUILDING_RECIPES = {
  {"rts-stockpile", "rts-economy", "b"},
  {"rts-extractor", "rts-economy", "c"},
  {"rts-smelter", "rts-economy", "d"},
  {"rts-solar-array", "rts-economy", "e"},
  {"rts-factory", "rts-economy", "f"},
  {"rts-steam-plant", "rts-economy", "j"},
  {"rts-accumulator", "rts-economy", "k"},
  {"rts-barracks", "rts-military", "a"},
  {"rts-turret", "rts-defense", "a"},
  {"rts-laser-turret", "rts-defense", "c"},
  {"rts-wall", "rts-defense", "d"},
  {"rts-radar", "rts-defense", "e"},
}
for _, r in ipairs(BUILDING_RECIPES) do
  local b = balance.buildings[r[1]]
  data:extend({recipe({name = r[1], category = B, subgroup = r[2], order = r[3], time = b.time, cost = b.cost,
                       count = b.count, enabled = not b.unlock})})
end

data:extend({
  -- Factory: vanilla logistics items and ammo
  recipe({name = "rts-belt", category = B, subgroup = "rts-economy", order = "g", time = 2,
          cost = {["iron-plate"] = 10}, result = "transport-belt", count = 10}),
  recipe({name = "rts-inserter", category = B, subgroup = "rts-economy", order = "h", time = 2,
          cost = {["iron-plate"] = 10, ["copper-plate"] = 5}, result = "fast-inserter", count = 5}),
  recipe({name = "rts-pole", category = B, subgroup = "rts-economy", order = "i", time = 2,
          cost = {["copper-plate"] = 5, ["iron-plate"] = 5}, result = "medium-electric-pole", count = 5}),
  recipe({name = "rts-ammo", category = B, subgroup = "rts-defense", order = "b", time = 3,
          cost = {["iron-plate"] = 10}, result = "firearm-magazine", count = 10}),
})

-- The heavy kit needs steel. Furnaces only pick recipes that are enabled for the force, and vanilla
-- steel-plate waits for the steel-processing research, so enable it from the start. Vanilla stone-brick is
-- enabled from the start already (walls).
data.raw.recipe["steel-plate"].enabled = true

-- Smelting overrides (balance.smelting): the rts-smelter runs the vanilla recipes, so change them in place.
for name, s in pairs(balance.smelting) do
  local r = data.raw.recipe[name]
  r.ingredients = ingredients(s.cost)
  r.energy_required = s.time
end
