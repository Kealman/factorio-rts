-- Phase 5 M3 age3 (docs/PHASE5-M3.md D1-D3, §3 "age3.lua / rare.lua / sinks.lua"; docs/qa/phase5-age3-notes.md): Age III
-- content on base-game items. Loaded from data-updates.lua after prototypes/people.lua (the labor slot exists on every
-- district by then and is widened here).
--
--   * Items: rts-automation-kit (a module of category rts-automation without effects: it cuts a district's jobs, see
--     scripts/age3.lua), rts-fuel-rod (nuclear fuel, 2.4 GJ). Processing units, batteries, rocket fuel, light oil in
--     barrels, concrete and uranium ore are the vanilla items.
--   * Buildings: three Age III districts (Chemistry district, Electronics II, Concrete works: 5x5 network-fed machines
--     like the Age II ones), the Nuclear plant (one 5x5 burner generator, 40 MW from fuel rods), the Rare extractor (a 3x3
--     drill that mines only the rts-rare deposits, 1 item / 10 s, no mining productivity, no power) and the Launch
--     complex (the 8x8 Space Program site, a simple entity placed by script).
--   * Module slots: every district (Age II and III, the refinery and the chemical plant) gets 1 + kit.per_building slots
--     for the categories rts-labor and rts-automation (slot 1 holds the labor module, the others automation kits).
--   * Recipe category rts-age3 (added to the factory); one rts-district-<id> per Age III district.
--   * Recipes from balance.nation.age3.recipes and .buildings start disabled: scripts/age3.lua enables them at Age III,
--     scripts/research.lua those a technology unlocks.
--   * Technologies Electrification (Age II), Chemistry and Nuclear power (Age III), industrial kits, no engine effects.
local balance = require("balance")
local age2 = require("prototypes.age2")
local A3 = balance.nation.age3
local E = balance.nation.economy

local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}
local RAID_MASK = {"common", balance.raid_target_type}

for _, name in ipairs({"processing-unit", "battery", "rocket-fuel", "light-oil-barrel", "uranium-ore", "concrete"}) do
  assert(data.raw.item[name], "factorio-rts: prototypes/age3.lua: missing vanilla item " .. name)
end

local function ingredients(list)
  local r = {}
  for item, amount in pairs(list) do r[#r + 1] = {type = "item", name = item, amount = amount} end
  table.sort(r, function(a, b) return a.name < b.name end)
  return r
end

local function building_recipe(name, order)
  local b = A3.buildings[name]
  return {
    type = "recipe",
    name = name,
    categories = {"rts-buildings"}, -- 2.1: RecipePrototype::category -> categories
    subgroup = "rts-districts",
    order = order,
    enabled = false,
    hide_from_player_crafting = true,
    auto_recycle = false,
    energy_required = b.time,
    ingredients = ingredients(b.cost),
    results = {{type = "item", name = name, amount = 1}},
  }
end

-------------------------------------------------------------------------------
-- Categories and groups
-------------------------------------------------------------------------------
data:extend({
  {type = "recipe-category", name = "rts-age3"},
  {type = "module-category", name = "rts-automation"},
  {type = "item-subgroup", name = "rts-age3-goods", group = "rts", order = "f3"},
})
local factory = data.raw["assembling-machine"]["rts-factory"]
assert(factory, "factorio-rts: rts-factory must exist before prototypes/age3.lua")
table.insert(factory.crafting_categories, "rts-age3")

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
local speed = data.raw.module["speed-module-2"] or data.raw.module["speed-module"]
local kit = {
  type = "module",
  name = A3.kit.item,
  localised_name = {"item-name." .. A3.kit.item},
  localised_description = {"item-description." .. A3.kit.item, tostring(math.floor(A3.kit.job_cut * 100 + 0.5))},
  icons = age2.icon_layers(speed, {r = 0.55, g = 0.85, b = 1, a = 1}),
  subgroup = "rts-age3-goods",
  order = "a[automation-kit]",
  category = "rts-automation",
  tier = 1,
  stack_size = 50,
  auto_recycle = false,
  requires_beacon_alt_mode = false,
  effect = {},
}
local cell = data.raw.item["uranium-fuel-cell"]
local rod = {
  type = "item",
  name = A3.nuclear.fuel,
  localised_name = {"item-name." .. A3.nuclear.fuel},
  localised_description = {"item-description." .. A3.nuclear.fuel},
  icons = age2.icon_layers(cell or data.raw.item["uranium-ore"], {r = 0.75, g = 1, b = 0.6, a = 1}),
  subgroup = "rts-age3-goods",
  order = "b[fuel-rod]",
  fuel_categories = {"nuclear"}, -- 2.1.20: ItemPrototype::fuel_category -> fuel_categories
  fuel_value = A3.nuclear.fuel_value,
  stack_size = 50,
  auto_recycle = false,
}
data:extend({kit, rod})

-------------------------------------------------------------------------------
-- Age III districts (5x5 network-fed machines, the Age II district pattern of prototypes/districts.lua)
-------------------------------------------------------------------------------
local SIZE, HALF = 5, 2.5
local LOOKS = {
  ["rts-district-chemistry"] = {source = {"assembling-machine", "chemical-plant", 3}, tint = {r = 0.7, g = 1, b = 0.8},
                                map = {r = 0.35, g = 0.65, b = 0.5}, order = "f[11]"},
  ["rts-district-electronics2"] = {source = {"assembling-machine", "assembling-machine-3", 3},
                                   tint = {r = 0.7, g = 0.8, b = 1}, map = {r = 0.35, g = 0.45, b = 0.8},
                                   order = "f[12]"},
  ["rts-district-concrete"] = {source = {"assembling-machine", "assembling-machine-2", 3},
                               tint = {r = 1, g = 0.9, b = 0.7}, map = {r = 0.65, g = 0.6, b = 0.45}, order = "f[13]"},
}

local function district(name)
  local look = LOOKS[name]
  local b = A3.buildings[name]
  local src = data.raw[look.source[1]][look.source[2]]
  assert(src, "factorio-rts: prototypes/age3.lua: missing vanilla " .. look.source[2])
  local e = age2.clean_machine(table.deepcopy(src), name, b.categories, b.health, b.power)
  local k = SIZE / look.source[3]
  local gs = e.graphics_set or {}
  e.graphics_set = gs
  age2.rescale(gs.animation, k, look.tint)
  age2.rescale(gs.idle_animation, k, look.tint)
  for key, v in pairs(gs) do
    if key ~= "animation" and key ~= "idle_animation" then age2.rescale(v, k) end
  end
  if e.water_reflection then age2.rescale(e.water_reflection, k) end
  e.collision_box = {{-HALF + 0.1, -HALF + 0.1}, {HALF - 0.1, HALF - 0.1}}
  e.selection_box = {{-HALF, -HALF}, {HALF, HALF}}
  e.drawing_box_vertical_extension = (e.drawing_box_vertical_extension or 0) * k
  e.icon_draw_specification = {shift = {0, -0.3}, scale = 1.5}
  e.icons_positioning = nil
  e.alert_icon_shift = nil
  e.map_color = look.map
  e.icons = age2.icon_layers(src, look.tint)
  e.icon = nil
  e.icon_size = nil
  e.corpse = "big-remnants"
  local item = age2.building_item(e, "assembling-machine-3", "rts-districts", look.order, 5)
  return e, item, building_recipe(name, look.order)
end

local list = {}
for _, name in ipairs({"rts-district-chemistry", "rts-district-electronics2", "rts-district-concrete"}) do
  local e, item, recipe = district(name)
  list[#list + 1] = {type = "recipe-category", name = A3.buildings[name].categories[1]}
  list[#list + 1] = e
  list[#list + 1] = item
  list[#list + 1] = recipe
end
data:extend(list)

-------------------------------------------------------------------------------
-- Nuclear plant: the RTS steam plant's burner generator with the reactor's picture, 5x5, 40 MW on fuel rods
-------------------------------------------------------------------------------
local NB = A3.buildings["rts-nuclear-plant"]
local steam = data.raw["burner-generator"]["rts-steam-plant"]
local reactor = data.raw.reactor["nuclear-reactor"]
assert(steam and reactor, "factorio-rts: prototypes/age3.lua: missing rts-steam-plant or the vanilla nuclear-reactor")
local plant = table.deepcopy(steam)
plant.name = "rts-nuclear-plant"
plant.localised_name = nil
plant.localised_description = nil
plant.minable = {mining_time = 1, result = "rts-nuclear-plant"}
plant.max_health = NB.health
plant.max_power_output = NB.power
plant.burner.fuel_categories = {"nuclear"}
plant.burner.fuel_inventory_size = 2
plant.burner.burnt_inventory_size = 0
plant.collision_box = {{-HALF + 0.1, -HALF + 0.1}, {HALF - 0.1, HALF - 0.1}}
plant.selection_box = {{-HALF, -HALF}, {HALF, HALF}}
local pic = table.deepcopy(reactor.picture)
plant.animation = pic
plant.idle_animation = nil
plant.icons = age2.icon_layers(reactor, {r = 1, g = 0.8, b = 0.55, a = 1})
plant.icon = nil
plant.icon_size = nil
plant.map_color = {r = 0.45, g = 0.75, b = 0.4}
plant.corpse = reactor.corpse
plant.dying_explosion = reactor.dying_explosion
plant.working_sound = table.deepcopy(reactor.working_sound)
plant.water_reflection = nil
plant.perceived_performance = nil
plant.next_upgrade = nil
plant.fast_replaceable_group = nil
local plant_item = age2.building_item(plant, "nuclear-reactor", "rts-districts", "f[14]", 5)
data:extend({plant, plant_item, building_recipe("rts-nuclear-plant", "f[14]")})

-------------------------------------------------------------------------------
-- Rare extractor: the RTS extractor on the rts-rare category only, slow and without power
-------------------------------------------------------------------------------
local RB = A3.buildings["rts-rare-extractor"]
local ext = data.raw["mining-drill"]["rts-extractor"]
assert(ext, "factorio-rts: prototypes/age3.lua: missing rts-extractor")
local rare = table.deepcopy(ext)
local RARE_TINT = {r = 0.95, g = 0.7, b = 1, a = 1}
rare.name = "rts-rare-extractor"
rare.localised_name = nil
rare.localised_description = nil
rare.minable = {mining_time = 0.5, result = "rts-rare-extractor"}
rare.max_health = RB.health
rare.resource_categories = {"rts-rare"}
-- a rare deposit mines in 2 s: 0.2 makes one item every 10 s (balance.nation.rare.item_seconds)
rare.mining_speed = 2 / balance.nation.rare.item_seconds
rare.uses_force_mining_productivity_bonus = false
rare.energy_source = {type = "void"}
rare.energy_usage = "1kW"
rare.icons = age2.icon_layers(ext, RARE_TINT)
rare.icon = nil
rare.icon_size = nil
rare.map_color = {r = 0.8, g = 0.5, b = 0.85}
rare.enemy_map_color = ENEMY_MAP_COLOR
rare.trigger_target_mask = table.deepcopy(RAID_MASK)
rare.surface_conditions = nil
rare.heating_energy = nil
local function tint_sprites(t, tint, seen)
  seen = seen or {}
  if type(t) ~= "table" or seen[t] then return end
  seen[t] = true
  if (t.filename or t.filenames or t.stripes) and not (t.draw_as_shadow or t.draw_as_glow or t.draw_as_light) then
    t.tint = tint
  end
  for key, v in pairs(t) do
    if type(v) == "table" and key ~= "tint" and key ~= "shift" then tint_sprites(v, tint, seen) end
  end
end
tint_sprites(rare.graphics_set, RARE_TINT)
tint_sprites(rare.wet_mining_graphics_set, RARE_TINT)
local rare_item = age2.building_item(rare, "electric-mining-drill", "rts-districts", "f[15]", 10)
data:extend({rare, rare_item, building_recipe("rts-rare-extractor", "f[15]")})

-------------------------------------------------------------------------------
-- Module slots: labor (slot 1) and automation kits (the others) on every district
-------------------------------------------------------------------------------
local function allow(e, effect)
  local l = e.allowed_effects
  if type(l) == "string" then l = {l} end
  l = l or {}
  for _, x in ipairs(l) do if x == effect then
    e.allowed_effects = l
    return
  end end
  l[#l + 1] = effect
  e.allowed_effects = l
end
local slotted = {}
for name, b in pairs(E.buildings) do
  if b.kind == "district" then slotted[#slotted + 1] = name end
end
for name, b in pairs(A3.buildings) do
  if b.kind == "district" then slotted[#slotted + 1] = name end
end
table.sort(slotted)
for _, name in ipairs(slotted) do
  local e = data.raw["assembling-machine"][name]
  assert(e, "factorio-rts: prototypes/age3.lua: missing district " .. name)
  e.module_slots = 1 + A3.kit.per_building
  e.allowed_module_categories = {"rts-labor", "rts-automation"}
  e.quality_affects_module_slots = false
  allow(e, "speed")
  allow(e, "consumption")
  local recv = e.effect_receiver or {}
  recv.uses_module_effects = true
  e.effect_receiver = recv
end
-- the rare extractor: the labor slot only (its jobs are balance.nation.people.jobs.kind["rare-extractor"])
rare.module_slots = 1
rare.allowed_module_categories = {"rts-labor"}
rare.quality_affects_module_slots = false
allow(rare, "speed")
allow(rare, "consumption")
rare.effect_receiver = {uses_module_effects = true}

-------------------------------------------------------------------------------
-- Launch complex (Space Program site): the rocket silo's platform at 8x8
-------------------------------------------------------------------------------
local function by_pixel(x, y) return {x / 32, y / 32} end
local S = 0.5 * 8 / 9.5
data:extend({{
  type = "simple-entity-with-owner",
  name = A3.site.name,
  icons = {{icon = "__base__/graphics/icons/rocket-silo.png", icon_size = 64, tint = {r = 0.75, g = 0.9, b = 1, a = 1}}},
  flags = {"placeable-neutral", "placeable-player", "player-creation", "not-deconstructable", "not-upgradable",
           "not-blueprintable"},
  max_health = A3.site.health,
  is_military_target = true,
  collision_box = {{-3.9, -3.9}, {3.9, 3.9}},
  selection_box = {{-4, -4}, {4, 4}},
  render_layer = "object",
  map_color = {r = 0.55, g = 0.85, b = 1},
  enemy_map_color = ENEMY_MAP_COLOR,
  trigger_target_mask = table.deepcopy(RAID_MASK),
  corpse = "big-remnants",
  dying_explosion = "big-explosion",
  picture = {layers = {
    {filename = "__base__/graphics/entity/rocket-silo/06-rocket-silo.png", width = 608, height = 596,
     shift = by_pixel(3 * S * 2, -1 * S * 2), scale = S},
    {filename = "__base__/graphics/entity/rocket-silo/14-rocket-silo-front.png", width = 580, height = 262,
     shift = by_pixel(-1 * S * 2, 78 * S * 2), scale = S},
    {filename = "__base__/graphics/entity/rocket-silo/00-rocket-silo-shadow.png", width = 612, height = 578,
     shift = by_pixel(7 * S * 2, 2 * S * 2), scale = S, draw_as_shadow = true},
  }},
}})

-------------------------------------------------------------------------------
-- Recipes
-------------------------------------------------------------------------------
local recipes = {}
for name, spec in pairs(A3.recipes) do
  local district_recipe = string.sub(spec.category, 1, 13) == "rts-district-"
  local r = age2.recipe(name, spec, district_recipe and "rts-districts" or "rts-age3-goods")
  if district_recipe then
    r.localised_name = {"recipe-name." .. name}
    r.order = "z" .. spec.category .. spec.order
  end
  recipes[#recipes + 1] = r
end
table.sort(recipes, function(a, b) return a.name < b.name end)
data:extend(recipes)

-------------------------------------------------------------------------------
-- Technologies (Nation mode only: scripts/research.lua hides and disables them in Skirmish)
-------------------------------------------------------------------------------
local TECH_ICON = "__base__/graphics/technology/"
local techs = {}
for i, t in ipairs(A3.techs) do
  techs[#techs + 1] = {
    type = "technology",
    name = t.name,
    localised_name = {"technology-name." .. t.name},
    localised_description = {"technology-description." .. t.name},
    icons = {{icon = TECH_ICON .. t.icon .. ".png", icon_size = 256}},
    prerequisites = t.prerequisites,
    unit = {count = t.count, ingredients = {{t.kit, 1}}, time = 10},
    order = string.format("z[rts]-3-%02d", 60 + i),
  }
end
data:extend(techs)
