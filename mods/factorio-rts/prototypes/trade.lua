-- Phase 5 M2 treasury and market prototypes (docs/PHASE5-M2.md section 3 "treasury.lua / market.lua", decision D5;
-- docs/qa/phase5-treasury-notes.md). Nation mode only.
--
--   rts-trade-post   roboport clone, a hub subtype (scripts/logistics.lua builds the hub composite: hidden power and
--                    pole, 2 stockpiles, robots; its own logistic network). scripts/market.lua places one on every world
--                    port site under force rts-neutral and flips the composite to the force that captures it. It is
--                    indestructible and cannot be built, mined or demolished, so units never shoot at it (probe:
--                    units do not target an indestructible entity of a hostile force).
--   rts-commerce-1/2 Nation-only technologies: +25 % commerce cap each (effects in scripts/market.lua)
-- The market key (custom input rts-market, M) is in prototypes/inputs.lua (hud.lua's key table P4.KEYS calls
-- marketgui.toggle).
local balance = require("balance")
local MB = balance.nation and balance.nation.market
assert(MB, "factorio-rts: balance.nation.market is missing")

local POST_TINT = {r = 1.0, g = 0.78, b = 0.25, a = 1}   -- gold: reads apart from the hub, depot and City Center
local ICON_TINT = {r = 1.0, g = 0.8, b = 0.3, a = 1}

local function tinted_icons(src, tint)
  if src.icons then
    local icons = table.deepcopy(src.icons)
    for _, layer in pairs(icons) do layer.tint = tint end
    return icons
  end
  return {{icon = src.icon, icon_size = src.icon_size or 64, tint = tint}}
end

local function tint_layers(t, tint)
  if type(t) ~= "table" then return end
  if (t.filename or t.filenames or t.stripes) and not t.draw_as_shadow then t.tint = tint end
  for _, v in pairs(t) do
    if type(v) == "table" then tint_layers(v, tint) end
  end
end

local post = table.deepcopy(data.raw.roboport.roboport)
post.name = "rts-trade-post"
post.localised_name = nil
post.localised_description = nil
post.icons = tinted_icons(data.raw.roboport.roboport, ICON_TINT)
post.icon = nil
post.icon_size = nil
post.max_health = 5000
post.map_color = {r = 1, g = 0.8, b = 0.2}
post.enemy_map_color = {r = 1, g = 0.8, b = 0.2}
post.friendly_map_color = {r = 1, g = 0.8, b = 0.2}
post.next_upgrade = nil
post.fast_replaceable_group = nil
post.factoriopedia_simulation = nil
post.surface_conditions = nil
post.minable = nil
post.flags = {"placeable-neutral", "player-creation", "not-deconstructable", "not-upgradable", "not-blueprintable"}
post.is_military_target = false
post.logistics_radius = 14
post.logistics_connection_distance = nil
post.construction_radius = 22
post.radar_range = 1
post.energy_source = {type = "electric", usage_priority = "secondary-input", input_flow_limit = "200kW",
                      buffer_capacity = "20MJ"}
post.recharge_minimum = "4MJ"
post.energy_usage = "20kW"
post.charging_energy = "50kW"
for _, key in pairs({"base", "base_patch", "base_animation", "door_animation_up", "door_animation_down"}) do
  tint_layers(post[key], POST_TINT)
end

data:extend({post})

-------------------------------------------------------------------------------
-- Commerce I / II (Nation only; scripts/market.lua adds them to research.NATION_ONLY and reads the levels)
-------------------------------------------------------------------------------
local TECH_ICON = "__base__/graphics/technology/"
local techs = {}
for i, t in ipairs(MB.commerce) do
  techs[#techs + 1] = {
    type = "technology",
    name = t.name,
    localised_name = {"technology-name." .. t.name},
    localised_description = {"technology-description." .. t.name},
    icons = {{icon = TECH_ICON .. t.icon .. ".png", icon_size = 256, tint = ICON_TINT}},
    prerequisites = t.prerequisites,
    unit = {count = t.count, ingredients = {{t.kit, 1}}, time = 10},
    order = string.format("z[rts]-%d-%02d", t.kit == "rts-science-advanced" and 2 or 1, 60 + i),
  }
end
data:extend(techs)
