-- Phase 5 E1 (docs/PHASE5-M1.md section 3; docs/qa/phase5-economy-notes.md): the ten Age II districts and the
-- national project site. Loaded from data-updates.lua after prototypes/age2.lua (its helpers are reused).
--
-- A district is one 5x5 assembling machine with its own recipe category (rts-district-<id>) and compressed
-- multi-stage recipes (balance.nation.economy.recipes). It has no fluid boxes and no modules: scripts/production.lua
-- feeds it from the logistic network it stands in and hands its products back, like the factory. Graphics are vanilla
-- machines scaled to 5x5 and tinted per district (Space Age machines where they exist, base ones otherwise).
-- Building recipes (factory, rts-buildings) start disabled; scripts/ages.lua enables them at Age II.
--
-- rts-project-site: a 6x6 simple-entity-with-owner (the rocket silo's platform, scaled), placed by script
-- (scripts/ages.lua) for the Railway Charter. Raiders deal bonus damage to it.
local balance = require("balance")
local age2 = require("prototypes.age2")
local E = balance.nation.economy

local SIZE = 5
local function by_pixel(x, y) return {x / 32, y / 32} end
local HALF = SIZE / 2

-- Graphics source per district: {type, name, tile size} in preference order (the first that exists wins), the tint
-- of its non-shadow layers and its map colour.
local LOOKS = {
  smelting = {sources = {{"furnace", "electric-furnace", 3}}, tint = {r = 1, g = 0.85, b = 0.7},
              map = {r = 0.8, g = 0.55, b = 0.3}},
  steel = {sources = {{"assembling-machine", "foundry", 5}, {"furnace", "steel-furnace", 2}},
           tint = {r = 0.85, g = 0.85, b = 1}, map = {r = 0.6, g = 0.6, b = 0.7}},
  circuits = {sources = {{"assembling-machine", "electromagnetic-plant", 4}, {"assembling-machine", "assembling-machine-2", 3}},
              tint = {r = 0.75, g = 1, b = 0.75}, map = {r = 0.35, g = 0.7, b = 0.35}},
  electronics = {sources = {{"assembling-machine", "assembling-machine-3", 3}}, tint = {r = 1, g = 0.75, b = 0.75},
                 map = {r = 0.75, g = 0.3, b = 0.3}},
  petrochem = {sources = {{"assembling-machine", "oil-refinery", 5}}, tint = {r = 0.85, g = 0.75, b = 1},
               map = {r = 0.55, g = 0.4, b = 0.75}},
  engines = {sources = {{"assembling-machine", "centrifuge", 3}}, tint = {r = 1, g = 0.9, b = 0.6},
             map = {r = 0.75, g = 0.65, b = 0.3}},
  munitions = {sources = {{"assembling-machine", "assembling-machine-2", 3}}, tint = {r = 1, g = 0.6, b = 0.45},
               map = {r = 0.85, g = 0.4, b = 0.25}},
  rails = {sources = {{"assembling-machine", "assembling-machine-1", 3}}, tint = {r = 0.8, g = 0.8, b = 0.8},
           map = {r = 0.5, g = 0.5, b = 0.5}},
  construction = {sources = {{"assembling-machine", "cryogenic-plant", 5}, {"assembling-machine", "chemical-plant", 3}},
                  tint = {r = 0.9, g = 0.9, b = 0.8}, map = {r = 0.6, g = 0.6, b = 0.5}},
  science = {sources = {{"lab", "lab", 3}}, tint = {r = 0.8, g = 0.9, b = 1}, map = {r = 0.75, g = 0.45, b = 0.85}},
}

local function pick_source(look)
  for _, s in ipairs(look.sources) do
    local proto = data.raw[s[1]][s[2]]
    if proto then return proto, s[3] end
  end
  return data.raw["assembling-machine"]["assembling-machine-2"], 3
end

-- An assembling machine shell carrying the graphics of `src` scaled from `tiles` to SIZE tiles.
local function district(d, order)
  local look = LOOKS[d.id]
  local name = "rts-district-" .. d.id
  local b = E.buildings[name]
  local src, tiles = pick_source(look)
  local base = data.raw["assembling-machine"]["assembling-machine-2"]
  local e
  if src.type == "assembling-machine" or src.type == "furnace" then
    e = table.deepcopy(src)
    e.type = "assembling-machine"
    -- furnace-only keys
    e.source_inventory_size = nil
    e.result_inventory_size = nil
    e.cant_insert_at_source_message_key = nil
    e.custom_input_slot_tooltip_key = nil
    e.show_recipe_icon = nil
  else
    -- lab: its on_animation becomes the machine animation
    e = table.deepcopy(base)
    e.graphics_set = {animation = table.deepcopy(src.on_animation)}
    e.working_sound = table.deepcopy(src.working_sound)
    e.corpse = src.corpse
    e.dying_explosion = src.dying_explosion
  end
  age2.clean_machine(e, name, b.categories, b.health, b.power)
  local k = SIZE / tiles
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
  local item = age2.building_item(e, "assembling-machine-3", "rts-districts", string.format("d[%02d]", order), 5)
  return e, item, age2.building_recipe(name, "rts-districts", string.format("d%02d", order))
end

local list = {}
for i, d in ipairs(E.districts) do
  local e, item, recipe = district(d, i)
  list[#list + 1] = {type = "recipe-category", name = "rts-district-" .. d.id}
  list[#list + 1] = e
  list[#list + 1] = item
  list[#list + 1] = recipe
end
data:extend(list)

-- District recipes
local recipes = {}
for name, spec in pairs(E.recipes) do
  if string.sub(spec.category, 1, 13) == "rts-district-" then
    local r = age2.recipe(name, spec, "rts-districts")
    r.localised_name = {"recipe-name." .. name}
    r.order = "z" .. spec.category .. spec.order
    recipes[#recipes + 1] = r
  end
end
table.sort(recipes, function(a, b) return a.name < b.name end)
data:extend(recipes)

-------------------------------------------------------------------------------
-- National project site (Railway Charter)
-------------------------------------------------------------------------------
local SITE_SCALE = 0.5 * 6 / 9.5
local site = {
  type = "simple-entity-with-owner",
  name = "rts-project-site",
  icons = {{icon = "__base__/graphics/icons/rocket-silo.png", icon_size = 64, tint = {r = 1, g = 0.85, b = 0.6, a = 1}}},
  flags = {"placeable-neutral", "placeable-player", "player-creation", "not-deconstructable", "not-upgradable",
           "not-blueprintable"},
  max_health = E.charter.site_health,
  is_military_target = true,
  collision_box = {{-2.9, -2.9}, {2.9, 2.9}},
  selection_box = {{-3, -3}, {3, 3}},
  render_layer = "object",
  map_color = {r = 1, g = 0.85, b = 0.4},
  enemy_map_color = {r = 0.9, g = 0.2, b = 0.15},
  trigger_target_mask = {"common", balance.raid_target_type},
  corpse = "big-remnants",
  dying_explosion = "big-explosion",
  picture = {layers = {
    {filename = "__base__/graphics/entity/rocket-silo/06-rocket-silo.png", width = 608, height = 596,
     shift = by_pixel(3 * SITE_SCALE * 2, -1 * SITE_SCALE * 2), scale = SITE_SCALE},
    {filename = "__base__/graphics/entity/rocket-silo/14-rocket-silo-front.png", width = 580, height = 262,
     shift = by_pixel(-1 * SITE_SCALE * 2, 78 * SITE_SCALE * 2), scale = SITE_SCALE},
    {filename = "__base__/graphics/entity/rocket-silo/00-rocket-silo-shadow.png", width = 612, height = 578,
     shift = by_pixel(7 * SITE_SCALE * 2, 2 * SITE_SCALE * 2), scale = SITE_SCALE, draw_as_shadow = true},
  }},
}
data:extend({site})
