-- Phase 5 E1 (docs/PHASE5-M1.md section 3; docs/qa/phase5-economy-notes.md): Age II content and the age technologies.
-- Loaded from data-updates.lua after prototypes/research.lua (the rts-lab, the science kits and the factory's
-- rts-science category exist by then; so does every data.lua item of base, Space Age and the other M1 packages).
--
--   * Items: rts-crude-oil and rts-petroleum (fluids carried as items: a pumpjack's crude oil enters the logistic
--     network as rts-crude-oil, so oil travels by hauler and train like any good, and no pipe is ever needed),
--     rts-steel-beam, rts-science-industrial (the Age II science kit, a tinted chemical science pack). Plastic, sulfur,
--     engines, advanced circuits, concrete and rails (m1-rails' item) are the vanilla items.
--   * Buildings: rts-pumpjack (vanilla pumpjack on vanilla crude-oil, no power), rts-refinery and rts-chemical-plant
--     (vanilla graphics, no fluid boxes, item recipes only). The ten districts are in prototypes/districts.lua.
--   * Recipe categories: rts-age2 (added to the factory), rts-oil (refinery), rts-chemistry (chemical plant).
--   * Recipes from balance.nation.economy.recipes and .buildings: all start disabled; scripts/ages.lua enables them for
--     a force when it reaches Age II.
--   * Technologies from balance.nation.economy.techs: Industrialisation (advanced kits) and the Age II technologies
--     (industrial kits). No engine effects: scripts/research.lua applies them (research.EFFECTS, filled by ages.lua).
--     The lab learns the industrial kit.
--   * Custom input rts-ledger (L): the city ledger (scripts/ledgergui.lua).
--
-- Returns helpers for prototypes/districts.lua: tinted_icons, rescale, clean_machine, recipe, building_item.
local balance = require("balance")
local E = balance.nation.economy

local ICON_TINT = {r = 1.0, g = 0.8, b = 0.55, a = 1} -- the building tint of prototypes/buildings.lua
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}
local RAID_MASK = {"common", balance.raid_target_type}

local M = {}

local function icon_layers(src, tint)
  local icons
  if src.icons then
    icons = table.deepcopy(src.icons)
  else
    icons = {{icon = src.icon, icon_size = src.icon_size}}
  end
  if tint then
    for _, layer in pairs(icons) do layer.tint = tint end
  end
  return icons
end
M.icon_layers = icon_layers
function M.tinted_icons(src) return icon_layers(src, ICON_TINT) end

--- Scale every sprite under `t` by k (scale and shift), and every *_position vector (working visualisations).
--- `tint` (optional) is applied to the sprites that are not shadows, glows or lights.
local function rescale(t, k, tint, seen)
  seen = seen or {}
  if type(t) ~= "table" or seen[t] then return end
  seen[t] = true
  if t.filename or t.filenames or t.stripes then
    t.scale = (t.scale or 1) * k
    local s = t.shift
    if s then t.shift = {(s[1] or s.x or 0) * k, (s[2] or s.y or 0) * k} end
    if tint and not (t.draw_as_shadow or t.draw_as_glow or t.draw_as_light) then t.tint = tint end
  end
  for key, v in pairs(t) do
    if type(v) == "table" and key ~= "shift" and key ~= "tint" then
      if type(key) == "string" and key:find("_position$") and (v[1] or v.x) then
        t[key] = {(v[1] or v.x) * k, (v[2] or v.y) * k}
      elseif type(key) == "string" and key:find("_positions$") then
        for i, p in pairs(v) do v[i] = {(p[1] or p.x) * k, (p[2] or p.y) * k} end
      else
        rescale(v, k, tint, seen)
      end
    end
  end
end
M.rescale = rescale

--- Strip a deep-copied crafting machine of everything an RTS building must not inherit (Space Age base effects,
--- freezing, surface conditions, fluid boxes, modules, circuit wires, upgrade chains).
function M.clean_machine(e, name, categories, health, power)
  e.name = name
  e.localised_name = nil
  e.localised_description = nil
  e.minable = {mining_time = 0.5, result = name}
  e.max_health = health or e.max_health
  e.crafting_categories = categories
  e.crafting_speed = 1
  e.module_slots = 0
  e.allowed_effects = nil
  e.allowed_module_categories = nil
  e.effect_receiver = nil
  e.heating_energy = nil
  e.surface_conditions = nil
  e.fluid_boxes = nil
  e.fluid_boxes_off_when_no_fluid_recipe = nil
  e.fixed_recipe = nil
  e.circuit_connector = nil
  e.circuit_wire_max_distance = nil
  e.next_upgrade = nil
  e.fast_replaceable_group = nil
  e.factoriopedia_simulation = nil
  e.graphics_set_flipped = nil
  e.forced_symmetry = nil
  e.perceived_performance = nil
  e.enemy_map_color = ENEMY_MAP_COLOR
  e.trigger_target_mask = table.deepcopy(RAID_MASK)
  e.flags = {"placeable-neutral", "placeable-player", "player-creation"}
  e.energy_usage = power or e.energy_usage
  e.energy_source = {type = "electric", usage_priority = "secondary-input"}
  return e
end

local function ingredients(list)
  local r = {}
  for item, amount in pairs(list) do r[#r + 1] = {type = "item", name = item, amount = amount} end
  table.sort(r, function(a, b) return a.name < b.name end)
  return r
end

--- A disabled, hidden-from-hand-crafting recipe from a balance spec {category, cost, results, time, order}.
function M.recipe(name, spec, subgroup)
  local results = ingredients(spec.results)
  local r = {
    type = "recipe",
    name = name,
    localised_name = (#results > 1 or spec.named) and {"recipe-name." .. name} or nil,
    category = spec.category,
    subgroup = subgroup or spec.subgroup,
    order = spec.order,
    enabled = false,
    hide_from_player_crafting = true,
    auto_recycle = false,
    allow_productivity = false,
    energy_required = spec.time,
    ingredients = ingredients(spec.cost),
    results = results,
  }
  if #results > 1 then r.main_product = spec.main or results[1].name end -- icon of the main product
  return r
end

--- Placeable item of an RTS building entity (icon from the entity, name and description from its locale keys).
function M.building_item(entity, source_item, subgroup, order, stack_size)
  local item = table.deepcopy(data.raw.item[source_item] or data.raw.item["assembling-machine-2"])
  item.name = entity.name
  item.localised_name = {"entity-name." .. entity.name}
  item.localised_description = {"entity-description." .. entity.name}
  item.icons = table.deepcopy(entity.icons)
  item.icon = nil
  item.icon_size = nil
  item.place_result = entity.name
  item.subgroup = subgroup
  item.order = order
  item.stack_size = stack_size or 10
  item.auto_recycle = false
  item.spoil_result = nil
  item.spoil_ticks = nil
  return item
end

--- A building recipe (factory, rts-buildings) from balance.nation.economy.buildings[name]; disabled until Age II.
function M.building_recipe(name, subgroup, order)
  local b = E.buildings[name]
  return {
    type = "recipe",
    name = name,
    category = "rts-buildings",
    subgroup = subgroup,
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
-- Groups and categories
-------------------------------------------------------------------------------
data:extend({
  {type = "recipe-category", name = "rts-age2"},
  {type = "recipe-category", name = "rts-oil"},
  {type = "recipe-category", name = "rts-chemistry"},
  {type = "item-subgroup", name = "rts-age2-goods", group = "rts", order = "f2"},
  {type = "item-subgroup", name = "rts-districts", group = "rts", order = "a2"},
})

local factory = data.raw["assembling-machine"]["rts-factory"]
assert(factory, "factorio-rts: rts-factory must exist before prototypes/age2.lua")
table.insert(factory.crafting_categories, "rts-age2")

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
local function fluid_item(name, fluid_name, order)
  local fluid = data.raw.fluid[fluid_name]
  assert(fluid, "factorio-rts: missing vanilla fluid " .. fluid_name)
  return {
    type = "item",
    name = name,
    localised_name = {"item-name." .. name},
    localised_description = {"item-description." .. name},
    icons = icon_layers(fluid),
    subgroup = "rts-age2-goods",
    order = order,
    stack_size = 100,
    auto_recycle = false,
  }
end

local beam = {
  type = "item",
  name = "rts-steel-beam",
  localised_name = {"item-name.rts-steel-beam"},
  localised_description = {"item-description.rts-steel-beam"},
  icons = icon_layers(data.raw.item["iron-stick"], {r = 0.75, g = 0.8, b = 0.95, a = 1}),
  subgroup = "rts-age2-goods",
  order = "f[steel-beam]",
  stack_size = 100,
  auto_recycle = false,
}

local kit = table.deepcopy(data.raw.tool["chemical-science-pack"])
assert(kit, "factorio-rts: missing vanilla tool chemical-science-pack")
kit.name = "rts-science-industrial"
kit.localised_name = {"item-name.rts-science-industrial"}
kit.localised_description = {"item-description.rts-science-industrial"}
kit.subgroup = "rts-science"
kit.order = "c[industrial]"
kit.auto_recycle = false
kit.spoil_result = nil
kit.spoil_ticks = nil

data:extend({fluid_item("rts-crude-oil", "crude-oil", "a[crude-oil]"),
             fluid_item("rts-petroleum", "petroleum-gas", "b[petroleum]"), beam, kit})

local lab = data.raw.lab["rts-lab"]
assert(lab, "factorio-rts: rts-lab must exist before prototypes/age2.lua")
table.insert(lab.inputs, "rts-science-industrial")

-------------------------------------------------------------------------------
-- Buildings: pumpjack, refinery, chemical plant
-------------------------------------------------------------------------------
local pj_src = data.raw["mining-drill"]["pumpjack"]
assert(pj_src, "factorio-rts: missing vanilla pumpjack")
local pumpjack = table.deepcopy(pj_src)
pumpjack.name = "rts-pumpjack"
pumpjack.localised_name = nil
pumpjack.localised_description = nil
pumpjack.icons = M.tinted_icons(pj_src)
pumpjack.icon = nil
pumpjack.icon_size = nil
pumpjack.minable = {mining_time = 0.5, result = "rts-pumpjack"}
pumpjack.max_health = E.buildings["rts-pumpjack"].health
pumpjack.mining_speed = E.buildings["rts-pumpjack"].mining_speed
pumpjack.energy_source = {type = "void"} -- an oil derrick: no power line to a far oil field
pumpjack.energy_usage = "1kW"
pumpjack.module_slots = 0
pumpjack.allowed_effects = nil
pumpjack.effect_receiver = nil
pumpjack.surface_conditions = nil
pumpjack.heating_energy = nil
pumpjack.next_upgrade = nil
pumpjack.fast_replaceable_group = nil
pumpjack.factoriopedia_simulation = nil
pumpjack.circuit_connector = nil
pumpjack.circuit_wire_max_distance = nil
pumpjack.map_color = {r = 0.55, g = 0.4, b = 0.75}
pumpjack.enemy_map_color = ENEMY_MAP_COLOR
pumpjack.trigger_target_mask = table.deepcopy(RAID_MASK)
pumpjack.flags = {"placeable-neutral", "placeable-player", "player-creation"}

local function plant(source, name, color)
  local src = data.raw["assembling-machine"][source]
  assert(src, "factorio-rts: missing vanilla " .. source)
  local b = E.buildings[name]
  local e = M.clean_machine(table.deepcopy(src), name, b.categories, b.health, b.power)
  e.icons = M.tinted_icons(src)
  e.icon = nil
  e.icon_size = nil
  e.map_color = color
  return e
end
local refinery = plant("oil-refinery", "rts-refinery", {r = 0.6, g = 0.45, b = 0.7})
local chem = plant("chemical-plant", "rts-chemical-plant", {r = 0.5, g = 0.6, b = 0.7})

data:extend({
  pumpjack, refinery, chem,
  M.building_item(pumpjack, "pumpjack", "rts-districts", "a[pumpjack]", 20),
  M.building_item(refinery, "oil-refinery", "rts-districts", "b[refinery]", 10),
  M.building_item(chem, "chemical-plant", "rts-districts", "c[chemical-plant]", 10),
  M.building_recipe("rts-pumpjack", "rts-districts", "a"),
  M.building_recipe("rts-refinery", "rts-districts", "b"),
  M.building_recipe("rts-chemical-plant", "rts-districts", "c"),
})

-------------------------------------------------------------------------------
-- Age II recipes (factory, refinery, chemical plant; district recipes are in prototypes/districts.lua)
-------------------------------------------------------------------------------
local SUBGROUP = {["rts-age2"] = "rts-age2-goods", ["rts-oil"] = "rts-age2-goods",
                  ["rts-chemistry"] = "rts-age2-goods", ["rts-science"] = "rts-science"}
local list = {}
for name, spec in pairs(E.recipes) do
  if SUBGROUP[spec.category] then list[#list + 1] = M.recipe(name, spec, SUBGROUP[spec.category]) end
end
table.sort(list, function(a, b) return a.name < b.name end)
data:extend(list)

-------------------------------------------------------------------------------
-- Technologies (Nation mode only: scripts/research.lua hides and disables them in Skirmish)
-------------------------------------------------------------------------------
local TECH_ICON = "__base__/graphics/technology/"
local techs = {}
for i, t in ipairs(E.techs) do
  techs[#techs + 1] = {
    type = "technology",
    name = t.name,
    localised_name = {"technology-name." .. t.name},
    localised_description = {"technology-description." .. t.name},
    icons = {{icon = TECH_ICON .. t.icon .. ".png", icon_size = 256}},
    prerequisites = t.prerequisites,
    unit = {count = t.count, ingredients = {{t.kit, 1}}, time = 10},
    order = string.format("z[rts]-%d-%02d", t.kit == "rts-science-industrial" and 3 or 2, 50 + i),
  }
end
data:extend(techs)

-------------------------------------------------------------------------------
-- Ledger key
-------------------------------------------------------------------------------
data:extend({{type = "custom-input", name = "rts-ledger", key_sequence = "L", consuming = "game-only",
              order = "z[rts]-e1-ledger"}})

return M
