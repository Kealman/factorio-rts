-- Phase 5 M2 people (docs/PHASE5-M2.md section 3 "population.lua / labor.lua"; docs/qa/phase5-people-notes.md).
-- Loaded from data-updates.lua after prototypes/districts.lua: every building that gets a labor slot exists by then.
--
--   * Hidden labor modules rts-labor-80 / -60 / -40 / -20 (module category rts-labor, speed and consumption -0.2 ..
--     -0.8, no recipe). scripts/labor.lua puts one into a building's single labor slot when its staffing step drops;
--     0 % is disabled_by_script with the custom status "No workers" (the engine floor is -80 %).
--   * One module slot restricted to rts-labor on every staffed machine: the factory, barracks, smelter, extractor, lab,
--     oil well, refinery, chemical plant, the ten districts, the farm, the bakery and the fishing hut. Speed and
--     consumption are added to their allowed effects (nothing else changes: no other module fits, no beacon exists).
--     The steam plant (a burner generator) has no module slot: it is either on or off (0 %).
--   * Items: rts-grain, rts-rations (spoil in balance.nation.people.spoil_minutes only with the "spoiling" feature
--     flag, i.e. Space Age), rts-goods (household goods).
--   * Buildings: rts-house (3x3, 20 residents) and rts-apartment (5x5, 80, Age II) as simple entities with an owner;
--     rts-farm (5x5, fixed recipe: 1 grain / 4 s, no input), rts-bakery (3x3, fixed recipe: 2 grain -> 3 rations, 3 s),
--     rts-fishing-hut (3x3, fixed recipe: 6 rations a minute, no input, no power; scripts/population.lua refuses it
--     away from water). rts-city-demand: a hidden 1 kW consumer under every city centre (its buffer tells whether the
--     city has power).
--   * Factory recipes (rts-intermediates): rts-goods (1 iron + 2 cable + 1 brick -> 2 goods, 4 s) and rts-brick
--     (2 stone -> 1 brick, 2 s). Building recipes (rts-buildings): every building above; the apartment's starts
--     disabled and scripts/population.lua enables it for a force at Age II. In Skirmish the HUD hides all of them.
-- Numbers: balance.nation.people. Names: locale/*/people.cfg.
local balance = require("balance")
local age2 = require("prototypes.age2") -- helpers (rescale, clean_machine, building_item, icon_layers)
local PB = balance.nation.people

local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}
local RAID_MASK = {"common", balance.raid_target_type}

local function ingredients(list)
  local r = {}
  for item, amount in pairs(list) do r[#r + 1] = {type = "item", name = item, amount = amount} end
  table.sort(r, function(a, b) return a.name < b.name end)
  return r
end

local function icons_of(proto, tint)
  return age2.icon_layers(proto, tint)
end

data:extend({
  {type = "module-category", name = "rts-labor"},
  {type = "recipe-category", name = "rts-farm"},
  {type = "recipe-category", name = "rts-bakery"},
  {type = "recipe-category", name = "rts-fishing"},
  {type = "item-subgroup", name = "rts-people", group = "rts", order = "a3"},
})

-------------------------------------------------------------------------------
-- Labor modules
-------------------------------------------------------------------------------
local MODULE_ICON = data.raw.module["speed-module"]
local modules = {}
for i = 1, PB.steps - 1 do
  local pct = math.floor(i * 100 / PB.steps + 0.5) -- staffing step: 20, 40, 60, 80
  local cut = 1 - i / PB.steps
  modules[#modules + 1] = {
    type = "module",
    name = "rts-labor-" .. pct,
    localised_name = {"item-name.rts-labor", tostring(pct)},
    localised_description = {"item-description.rts-labor", tostring(pct)},
    icons = icons_of(MODULE_ICON, {r = 0.65, g = 0.45, b = 0.4, a = 1}),
    subgroup = "rts-people",
    order = "z[labor]-" .. pct,
    category = "rts-labor",
    tier = 1,
    stack_size = 50,
    hidden = true,
    hidden_in_factoriopedia = true,
    auto_recycle = false,
    requires_beacon_alt_mode = false,
    effect = {speed = -cut, consumption = -cut},
  }
end
data:extend(modules)

-------------------------------------------------------------------------------
-- Items
-------------------------------------------------------------------------------
local function good(name, src, tint, order, stack)
  return {
    type = "item",
    name = name,
    localised_name = {"item-name." .. name},
    localised_description = {"item-description." .. name},
    icons = icons_of(src, tint),
    subgroup = "rts-people",
    order = order,
    stack_size = stack or 100,
    auto_recycle = false,
  }
end
local grain = good("rts-grain", data.raw.item.wood, {r = 1, g = 0.85, b = 0.35, a = 1}, "a[grain]")
local rations = good("rts-rations", data.raw.capsule["raw-fish"], {r = 1, g = 0.78, b = 0.5, a = 1}, "b[rations]")
local goods = good("rts-goods", data.raw.item["wooden-chest"], {r = 0.75, g = 0.85, b = 1, a = 1}, "c[goods]")
-- Rations spoil only where spoiling exists (Space Age); the base game keeps them (feature_flags is a data-stage global)
if feature_flags and feature_flags["spoiling"] then
  rations.spoil_ticks = PB.spoil_minutes * 60 * 60
end
data:extend({grain, rations, goods})

-------------------------------------------------------------------------------
-- Buildings
-------------------------------------------------------------------------------
-- A sprite of the vanilla market (a 3x3 stall) scaled to `tiles` and tinted.
local MARKET = data.raw.market and data.raw.market.market
local function market_picture(tiles, tint)
  local pic = MARKET and table.deepcopy(MARKET.picture) or {filename = "__base__/graphics/entity/market/market.png",
    width = 156, height = 127, shift = {0.95, 0.2}}
  age2.rescale(pic, tiles / 3, tint)
  return pic
end

local function box(size)
  local h = size / 2
  return {{-h + 0.1, -h + 0.1}, {h - 0.1, h - 0.1}}, {{-h, -h}, {h, h}}
end

-- Houses: simple entities with an owner (no GUI, no power, no status), a market stall picture.
local function house(name, tint, map_color)
  local b = PB.buildings[name]
  local collision, selection = box(b.size)
  return {
    type = "simple-entity-with-owner",
    name = name,
    icons = icons_of(MARKET or data.raw.item["wooden-chest"], tint),
    flags = {"placeable-neutral", "placeable-player", "player-creation"},
    minable = {mining_time = 0.5, result = name},
    max_health = b.health,
    corpse = b.size >= 5 and "big-remnants" or "medium-remnants",
    dying_explosion = "medium-explosion",
    collision_box = collision,
    selection_box = selection,
    map_color = map_color,
    enemy_map_color = ENEMY_MAP_COLOR,
    trigger_target_mask = table.deepcopy(RAID_MASK),
    render_layer = "object",
    picture = market_picture(b.size, tint),
  }
end

local HOUSE_TINT = {r = 1, g = 0.9, b = 0.75, a = 1}
local APARTMENT_TINT = {r = 0.8, g = 0.85, b = 1, a = 1}
local house_e = house("rts-house", HOUSE_TINT, {r = 0.85, g = 0.75, b = 0.55})
local apartment_e = house("rts-apartment", APARTMENT_TINT, {r = 0.65, g = 0.7, b = 0.85})

-- A crafting machine shell (assembling machine) with the graphics of a vanilla source scaled from `tiles` to `size`.
local function machine(name, sources, categories, tint, map_color, fixed)
  local b = PB.buildings[name]
  local src, tiles
  for _, s in ipairs(sources) do
    local proto = data.raw[s[1]] and data.raw[s[1]][s[2]]
    if proto then
      src, tiles = proto, s[3]
      break
    end
  end
  local base = data.raw["assembling-machine"]["assembling-machine-2"]
  local e
  if src and (src.type == "assembling-machine" or src.type == "furnace") then
    e = table.deepcopy(src)
    e.type = "assembling-machine"
    e.source_inventory_size = nil
    e.result_inventory_size = nil
    e.cant_insert_at_source_message_key = nil
    e.custom_input_slot_tooltip_key = nil
    e.show_recipe_icon = nil
  else
    e = table.deepcopy(base)
    if src and src.graphics_set then
      e.graphics_set = table.deepcopy(src.graphics_set) -- the agricultural tower's CraftingMachineGraphicsSet
      e.working_sound = table.deepcopy(src.working_sound)
    elseif not src then
      src, tiles = base, 3
    end
  end
  age2.clean_machine(e, name, categories, b.health, b.power)
  if not b.power then
    e.energy_source = {type = "void"}
    e.energy_usage = "1kW"
  end
  local k = b.size / tiles
  local gs = e.graphics_set or {}
  e.graphics_set = gs
  if fixed == "market" then
    gs.animation = {layers = {market_picture(b.size, tint)}}
    gs.idle_animation = nil
    gs.working_visualisations = nil
    gs.status_colors = nil
  else
    age2.rescale(gs.animation, k, tint)
    age2.rescale(gs.idle_animation, k, tint)
    for key, v in pairs(gs) do
      if key ~= "animation" and key ~= "idle_animation" then age2.rescale(v, k) end
    end
  end
  if e.water_reflection then age2.rescale(e.water_reflection, k) end
  local collision, selection = box(b.size)
  e.collision_box = collision
  e.selection_box = selection
  e.drawing_box_vertical_extension = (e.drawing_box_vertical_extension or 0) * k
  e.icon_draw_specification = {shift = {0, -0.3}, scale = b.size >= 5 and 1.5 or 1}
  e.icons_positioning = nil
  e.alert_icon_shift = nil
  e.map_color = map_color
  e.icons = icons_of(src, tint)
  e.icon = nil
  e.icon_size = nil
  e.corpse = b.size >= 5 and "big-remnants" or "medium-remnants"
  e.crafting_speed = 1
  return e
end

local farm_e = machine("rts-farm", {{"agricultural-tower", "agricultural-tower", 3},
                                    {"assembling-machine", "assembling-machine-1", 3}},
  {"rts-farm"}, {r = 0.85, g = 1, b = 0.6, a = 1}, {r = 0.55, g = 0.75, b = 0.3})
farm_e.fixed_recipe = "rts-grain"
local bakery_e = machine("rts-bakery", {{"furnace", "stone-furnace", 2}}, {"rts-bakery"},
  {r = 1, g = 0.85, b = 0.7, a = 1}, {r = 0.85, g = 0.6, b = 0.4})
bakery_e.fixed_recipe = "rts-rations"
local fishing_e = machine("rts-fishing-hut", {{"assembling-machine", "assembling-machine-1", 3}}, {"rts-fishing"},
  {r = 0.7, g = 0.85, b = 1, a = 1}, {r = 0.35, g = 0.55, b = 0.8}, "market")
fishing_e.fixed_recipe = "rts-fish-rations"
fishing_e.icons = icons_of(data.raw.capsule["raw-fish"], {r = 0.7, g = 0.85, b = 1, a = 1})

data:extend({house_e, apartment_e, farm_e, bakery_e, fishing_e})

-- Building items (factory-made, placed like every RTS building)
local ITEM_ORDER = {["rts-house"] = "a", ["rts-apartment"] = "b", ["rts-farm"] = "c", ["rts-bakery"] = "d",
                    ["rts-fishing-hut"] = "e"}
local items = {}
for _, e in ipairs({house_e, apartment_e, farm_e, bakery_e, fishing_e}) do
  items[#items + 1] = age2.building_item(e, "assembling-machine-1", "rts-people", "p[" .. ITEM_ORDER[e.name] .. "]", 10)
end
data:extend(items)

-- Hidden 1 kW consumer under every city centre. It may draw twice its use, so its 2 kJ buffer stays full while the
-- network satisfies at least half of the demand and empties within about 10 s below that ("no power").
local demand = table.deepcopy(data.raw["electric-energy-interface"]["rts-city-power"])
demand.name = "rts-city-demand"
demand.energy_source = {
  type = "electric",
  usage_priority = "secondary-input",
  buffer_capacity = "2kJ",
  input_flow_limit = "2kW",
  output_flow_limit = "0W",
}
demand.energy_production = "0W"
demand.energy_usage = "1kW"
data:extend({demand})

-------------------------------------------------------------------------------
-- Recipes
-------------------------------------------------------------------------------
local function recipe(spec)
  local r = {
    type = "recipe",
    name = spec.name,
    localised_name = spec.localised_name,
    categories = {spec.category}, -- 2.1: RecipePrototype::category -> categories
    subgroup = spec.subgroup or "rts-people",
    order = spec.order,
    enabled = spec.enabled ~= false,
    hide_from_player_crafting = true,
    auto_recycle = false,
    allow_productivity = false,
    energy_required = spec.time,
    ingredients = ingredients(spec.cost or {}),
    results = {{type = "item", name = spec.result, amount = spec.count or 1}},
    crafting_machine_tint = spec.tint,
  }
  return r
end

local recipes = {
  recipe({name = "rts-grain", category = "rts-farm", time = PB.farm_time, result = "rts-grain", order = "a",
          tint = {primary = {r = 0.75, g = 0.85, b = 0.3, a = 1}, secondary = {r = 1, g = 0.9, b = 0.5, a = 1}}}),
  recipe({name = "rts-rations", category = "rts-bakery", time = PB.bakery.time,
          cost = {["rts-grain"] = PB.bakery.grain}, result = "rts-rations", count = PB.bakery.rations, order = "b"}),
  recipe({name = "rts-fish-rations", category = "rts-fishing", time = 60 / PB.fishing_per_minute,
          result = "rts-rations", order = "c", localised_name = {"recipe-name.rts-fish-rations"}}),
  recipe({name = "rts-goods", category = "rts-intermediates", subgroup = "rts-intermediates", time = PB.goods.time,
          cost = PB.goods.cost, result = "rts-goods", count = PB.goods.count, order = "p[goods]"}),
  recipe({name = "rts-brick", category = "rts-intermediates", subgroup = "rts-intermediates", time = PB.brick.time,
          cost = PB.brick.cost, result = "stone-brick", count = PB.brick.count, order = "p[brick]",
          localised_name = {"recipe-name.rts-brick"}}),
}
for name, b in pairs(PB.buildings) do
  recipes[#recipes + 1] = recipe({name = name, category = "rts-buildings", time = b.time, cost = b.cost, result = name,
                                  order = "p[" .. ITEM_ORDER[name] .. "]", enabled = not b.age})
end
data:extend(recipes)

-------------------------------------------------------------------------------
-- Labor slots on the staffed machines
-------------------------------------------------------------------------------
local LABOR_SLOT = {
  ["assembling-machine"] = {"rts-factory", "rts-barracks", "rts-refinery", "rts-chemical-plant", "rts-farm",
                            "rts-bakery", "rts-fishing-hut"},
  furnace = {"rts-smelter"},
  ["mining-drill"] = {"rts-extractor", "rts-pumpjack"},
  lab = {"rts-lab"},
}
for name, b in pairs(balance.nation.economy.buildings) do
  if b.kind == "district" and string.sub(name, 1, 13) == "rts-district-" then
    table.insert(LABOR_SLOT["assembling-machine"], name)
  end
end
local function allow(e, effect)
  local list = e.allowed_effects
  if type(list) == "string" then list = {list} end
  list = list or {}
  for _, x in ipairs(list) do if x == effect then
    e.allowed_effects = list
    return
  end end
  list[#list + 1] = effect
  e.allowed_effects = list
end
for ptype, names in pairs(LABOR_SLOT) do
  for _, name in ipairs(names) do
    local e = data.raw[ptype][name]
    assert(e, "factorio-rts: prototypes/people.lua: missing " .. ptype .. " " .. name)
    e.module_slots = 1
    e.allowed_module_categories = {"rts-labor"}
    e.quality_affects_module_slots = false
    allow(e, "speed")
    allow(e, "consumption")
    local recv = e.effect_receiver or {}
    recv.uses_module_effects = true
    e.effect_receiver = recv
  end
end
