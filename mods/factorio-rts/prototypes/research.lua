-- Phase 4 research prototypes (docs/PHASE4.md sections 2.5 and 4; docs/qa/phase4-research-notes.md).
-- Loaded from data-updates.lua, so every other data.lua prototype (the rts-factory, the item group, vanilla items)
-- already exists:
--   * rts-lab: lab clone that accepts only the two RTS science kits (speed 1, 60 kW), built by the factory.
--   * rts-science-basic / rts-science-advanced: science kits (tool items), crafted by the factory in the new
--     crafting category rts-science (data-updates.lua appends it to the factory's crafting_categories).
--   * Technologies rts-*: tier 1 costs basic kits, tier 2 advanced kits; 10 s per unit and lab. They have no engine
--     effects: scripts/research.lua applies every effect from on_research_finished, so a new match can reset research
--     without touching modifiers that other modules set (the hard AI's mining bonus).
-- Names come from locale/*/research.cfg (entity-name, item-name, recipe-name, technology-name, technology-description).

local ICON_TINT = {r = 1.0, g = 0.8, b = 0.55, a = 1} -- the building tint of prototypes/buildings.lua
local ENEMY_MAP_COLOR = {r = 0.9, g = 0.2, b = 0.15}

local BASIC, ADVANCED = "rts-science-basic", "rts-science-advanced"

-------------------------------------------------------------------------------
-- Lab
-------------------------------------------------------------------------------
local src = data.raw.lab.lab
assert(src, "factorio-rts: missing vanilla lab")
local lab = table.deepcopy(src)
lab.name = "rts-lab"
lab.localised_name = nil
lab.localised_description = nil
if src.icons then
  lab.icons = table.deepcopy(src.icons)
  for _, layer in pairs(lab.icons) do layer.tint = ICON_TINT end
else
  lab.icons = {{icon = src.icon, icon_size = src.icon_size, tint = ICON_TINT}}
end
lab.icon = nil
lab.icon_size = nil
lab.minable = {mining_time = 0.5, result = "rts-lab"}
lab.max_health = 600
lab.inputs = {BASIC, ADVANCED}
lab.researching_speed = 1
lab.energy_usage = "60kW"
lab.module_slots = 0
lab.icons_positioning = nil -- Space Age sizes it for its 12 packs
lab.map_color = {r = 0.75, g = 0.45, b = 0.85}
lab.enemy_map_color = ENEMY_MAP_COLOR
lab.next_upgrade = nil
lab.fast_replaceable_group = nil
lab.factoriopedia_simulation = nil
lab.surface_conditions = nil

local lab_item = table.deepcopy(data.raw.item.lab)
lab_item.name = "rts-lab"
lab_item.localised_name = nil
lab_item.localised_description = {"entity-description.rts-lab"}
lab_item.icons = table.deepcopy(lab.icons)
lab_item.icon = nil
lab_item.icon_size = nil
lab_item.place_result = "rts-lab"
lab_item.subgroup = "rts-economy"
lab_item.order = "j[lab]"
lab_item.stack_size = 10
lab_item.auto_recycle = false

-------------------------------------------------------------------------------
-- Science kits
-------------------------------------------------------------------------------
local function kit(name, source, order)
  local item = table.deepcopy(data.raw.tool[source])
  assert(item, "factorio-rts: missing vanilla tool " .. source)
  item.name = name
  item.localised_name = nil
  item.localised_description = {"item-description." .. name}
  item.subgroup = "rts-science"
  item.order = order
  item.auto_recycle = false
  item.spoil_result = nil
  item.spoil_ticks = nil
  return item
end

local function recipe(spec)
  local ingredients = {}
  for _, ing in ipairs(spec.cost) do ingredients[#ingredients + 1] = {type = "item", name = ing[1], amount = ing[2]} end
  return {
    type = "recipe",
    name = spec.name,
    category = spec.category,
    subgroup = spec.subgroup,
    order = spec.order,
    enabled = true,
    hide_from_player_crafting = true,
    auto_recycle = false,
    energy_required = spec.time,
    ingredients = ingredients,
    results = {{type = "item", name = spec.name, amount = 1}},
  }
end

data:extend({
  {type = "recipe-category", name = "rts-science"},
  {type = "item-subgroup", name = "rts-science", group = "rts", order = "e"},
  lab, lab_item,
  kit(BASIC, "automation-science-pack", "a[basic]"),
  kit(ADVANCED, "logistic-science-pack", "b[advanced]"),
  recipe({name = "rts-lab", category = "rts-buildings", subgroup = "rts-economy", order = "j", time = 6,
          cost = {{"iron-plate", 30}, {"copper-plate", 10}}}),
  -- docs/PHASE4.md 2.5: basic kit = 1 gear + 1 copper (5 s), advanced kit = 2 circuits + 1 steel (10 s).
  -- The gear and circuit come from the content agent's rts-intermediates recipes.
  recipe({name = BASIC, category = "rts-science", subgroup = "rts-science", order = "a", time = 5,
          cost = {{"iron-gear-wheel", 1}, {"copper-plate", 1}}}),
  recipe({name = ADVANCED, category = "rts-science", subgroup = "rts-science", order = "b", time = 10,
          cost = {{"electronic-circuit", 2}, {"steel-plate", 1}}}),
})

-------------------------------------------------------------------------------
-- Technologies. Tier 1: basic kits. Tier 2: advanced kits. Effects live in scripts/research.lua (EFFECTS).
-------------------------------------------------------------------------------
local TECH_ICON = "__base__/graphics/technology/"
local TECHS = {
  -- name, tier, count, icon, prerequisites
  {"rts-attack-1", 1, 20, "physical-projectile-damage-1"},
  {"rts-armor-1", 1, 20, "heavy-armor"},
  {"rts-mining-1", 1, 15, "mining-productivity"},
  {"rts-logistics-1", 1, 15, "worker-robots-speed"},
  {"rts-supply-1", 1, 10, "toolbelt"},
  {"rts-unlock-heavy", 1, 15, "tank"},
  {"rts-unlock-raider", 1, 20, "automobilism"},
  {"rts-hauler-capacity-1", 1, 15, "spidertron"},
  {"rts-attack-2", 2, 25, "physical-projectile-damage-2", {"rts-attack-1"}},
  {"rts-attack-3", 2, 40, "stronger-explosives-3", {"rts-attack-2"}},
  {"rts-armor-2", 2, 25, "power-armor", {"rts-armor-1"}},
  {"rts-armor-3", 2, 40, "power-armor-mk2", {"rts-armor-2"}},
  {"rts-unlock-artillery", 2, 30, "artillery", {"rts-unlock-heavy"}},
  {"rts-unlock-laser", 2, 25, "laser-turret"},
  {"rts-steam-power", 2, 20, "steam-power"},
  {"rts-overcharge", 2, 25, "laser-shooting-speed", {"rts-unlock-laser"}},
  {"rts-scanner", 2, 20, "radar"},
  {"rts-supply-2", 2, 20, "robotics", {"rts-supply-1"}},
  {"rts-mining-2", 2, 25, "electric-mining-drill", {"rts-mining-1"}},
}

local technologies = {}
for i, t in ipairs(TECHS) do
  local name, tier, count, icon, prerequisites = t[1], t[2], t[3], t[4], t[5]
  technologies[#technologies + 1] = {
    type = "technology",
    name = name,
    -- explicit keys: without them the engine strips the "-1" level suffix and looks up technology-name.rts-attack
    localised_name = {"technology-name." .. name},
    localised_description = {"technology-description." .. name},
    icons = {{icon = TECH_ICON .. icon .. ".png", icon_size = 256}},
    prerequisites = prerequisites,
    unit = {count = count, ingredients = {{tier == 1 and BASIC or ADVANCED, 1}}, time = 10},
    order = string.format("z[rts]-%d-%02d", tier, i),
  }
end
data:extend(technologies)
