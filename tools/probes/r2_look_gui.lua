-- 0.1.1 (r2-ux, issue #11): the look of every RTS building on Factorio 2.1, GUI probe (screenshots only, no input).
-- Starts a Nation match (2048, 1 AI, Survey), lays a grass yard next to the capital and places one of every RTS
-- building prototype (an rts-* entity of a building type that is not hidden), each beside nothing but grass, then takes
-- per building a close-up at zoom 1 (rts-r2l-<name>.png) and a few line-ups at the play zooms 0.5 and 0.25 (the
-- districts, the Age I production row, the factory and barracks next to their vanilla source, the Age II machines next
-- to theirs). Vanilla sources stand next to their copies in the line-ups so a changed 2.1 sprite shows.
-- Test copy (self-test off):
--   rm -rf build/r2l && mkdir -p build/r2l && cp -R mods/factorio-rts mods/mod-list.json build/r2l/
--   cp tools/probes/r2_look_gui.lua build/r2l/factorio-rts/scripts/
--   printf '\nrequire("scripts.r2_look_gui")\n' >> build/r2l/factorio-rts/control.lua
--   RTS_LOCALE=en tools/gui-run.sh build/r2l 600 RTS_R2L_DONE '\[rts\] r2l|rror'
-- Screenshots: build/shots-r2l/rts-r2l-*.png. Log lines "[rts] r2l ...", the stop marker RTS_R2L_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local buildings = require("scripts.buildings")

local function note(fmt, ...) util.log("r2l probe: " .. fmt, ...) end

-- Entity types that are buildings (RTS copies keep the vanilla type of their source)
local BUILDING_TYPES = {
  ["assembling-machine"] = true, furnace = true, ["mining-drill"] = true, roboport = true, ["logistic-container"] = true,
  container = true, ["ammo-turret"] = true, ["electric-turret"] = true, ["fluid-turret"] = true, lab = true,
  radar = true, ["solar-panel"] = true, accumulator = true, ["burner-generator"] = true, generator = true,
  reactor = true, wall = true, gate = true, ["simple-entity-with-owner"] = true, ["simple-entity-with-force"] = true,
  ["train-stop"] = true, market = true, ["artillery-turret"] = true, ["rocket-silo"] = true, boiler = true,
  lamp = true, turret = true, ["electric-pole"] = true, ["cargo-landing-pad"] = true, ["agricultural-tower"] = true,
}
-- Vanilla sources shown next to their RTS copies in the line-ups (only those that exist are placed)
local VANILLA = {"assembling-machine-1", "assembling-machine-2", "assembling-machine-3", "oil-refinery", "chemical-plant",
                 "electric-furnace", "foundry", "electromagnetic-plant", "cryogenic-plant", "centrifuge", "lab",
                 "electric-mining-drill", "roboport", "gun-turret", "pumpjack"}

local function rts_buildings()
  local list = {}
  for name, proto in pairs(prototypes.entity) do
    if string.sub(name, 1, 4) == "rts-" and BUILDING_TYPES[proto.type] and not proto.hidden
       and proto.selectable_in_game then
      list[#list + 1] = name
    end
  end
  table.sort(list)
  return list
end

local function size_of(name)
  local b = prototypes.entity[name].collision_box
  return math.ceil(b.right_bottom.x - b.left_top.x), math.ceil(b.right_bottom.y - b.left_top.y)
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player, P)
  storage.lobby.pending.mode = "nation"
  storage.lobby.pending.opponents = 1
  storage.lobby.pending.survey = true
  lobby.start_match({opponents = 1, difficulty = "normal", enemy_brain = "ai", mode = "nation", world_size = 2048,
                     survey = true, victory = "conquest_space", time_limit = 0}, "r2l probe")
  return 600
end)

-- The yard: a grass rectangle 40 tiles south-east of the capital, everything on it removed, charted every step
local CELL = 12
step(function(player, P)
  P.F = player.force.name
  local cc = buildings.main_cc(P.F).entity
  P.home = cc.position
  P.list = rts_buildings()
  P.vanilla = {}
  for _, v in ipairs(VANILLA) do if prototypes.entity[v] then P.vanilla[#P.vanilla + 1] = v end end
  local n = #P.list + #P.vanilla
  P.cols = 10
  P.rows = math.ceil(n / P.cols)
  P.origin = {x = math.floor(P.home.x) + 30, y = math.floor(P.home.y) + 30}
  local surface = match.surface()
  P.area = {{P.origin.x - 4, P.origin.y - 4}, {P.origin.x + P.cols * CELL + 4, P.origin.y + P.rows * CELL + 4}}
  for _, e in ipairs(surface.find_entities_filtered({area = P.area})) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = P.area[1][1], P.area[2][1] do
    for y = P.area[1][2], P.area[2][2] do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, false, true, false)
  surface.destroy_decoratives({area = P.area})
  player.force.chart(surface, P.area)
  note("%d RTS buildings, %d vanilla references, yard %s-%s", #P.list, #P.vanilla, util.pos_str({x = P.area[1][1],
    y = P.area[1][2]}), util.pos_str({x = P.area[2][1], y = P.area[2][2]}))
  note("buildings: %s", table.concat(P.list, " "))
  return 60
end)

local function cell_pos(P, i)
  local c = (i - 1) % P.cols
  local r = math.floor((i - 1) / P.cols)
  return {x = P.origin.x + c * CELL + CELL / 2, y = P.origin.y + r * CELL + CELL / 2}
end

-- Place everything (no raise_built: no module registers them, nothing works or consumes)
step(function(player, P)
  local surface = match.surface()
  P.placed = {}
  local all = {}
  for _, name in ipairs(P.list) do all[#all + 1] = name end
  for _, name in ipairs(P.vanilla) do all[#all + 1] = name end
  for i, name in ipairs(all) do
    local pos = cell_pos(P, i)
    local w, h = size_of(name)
    -- whole-tile sizes sit on the tile grid like a placed building
    pos = {x = (w % 2 == 0) and math.floor(pos.x) or math.floor(pos.x) + 0.5,
           y = (h % 2 == 0) and math.floor(pos.y) or math.floor(pos.y) + 0.5}
    local ok, e = pcall(surface.create_entity, {name = name, position = pos, force = P.F, create_build_effect_smoke = false})
    if ok and e then
      P.placed[name] = e
    else
      note("could not place %s: %s", name, tostring(e))
    end
  end
  player.force.chart(surface, P.area)
  return 120
end)

local function shot(player, tag, pos, zoom, w, h)
  game.take_screenshot({player = player, by_player = player, surface = match.surface(), position = pos, zoom = zoom,
                        resolution = {w, h}, path = "rts-r2l-" .. tag .. ".png", show_gui = false,
                        show_entity_info = false, daytime = 0, hide_clouds = true, hide_fog = true, force_render = true,
                        anti_alias = true})
end

-- One close-up per building at zoom 1: the building plus 2 tiles of grass around it. The mod's render objects (land
-- borders, labels) are hidden for the shots.
step(function(player, P)
  camera.jump_to(player, cell_pos(P, 1))
  P.k = 0
  P.hidden = {}
  for _, o in ipairs(rendering.get_all_objects(script.mod_name)) do
    if o.valid and o.visible then
      o.visible = false
      P.hidden[#P.hidden + 1] = o
    end
  end
  note("%d render objects hidden for the shots", #P.hidden)
  return 30
end)
step(function(player, P)
  for name, e in pairs(P.placed) do
    if e.valid then
      local w, h = size_of(name)
      local px = math.min(1024, (math.max(w, h) + 4) * 32)
      shot(player, "z1-" .. name, e.position, 1, px, px)
      P.k = P.k + 1
    end
  end
  note("%d close-ups", P.k)
  return 60
end)

-- Line-ups at play zooms: groups of names placed side by side on a second yard row south of the grid
local LINEUPS = {
  {"age1", {"rts-extractor", "rts-smelter", "rts-stockpile", "rts-factory", "rts-barracks", "rts-lab", "rts-hub",
            "rts-command-center"}},
  {"factory-barracks-vanilla", {"rts-factory", "rts-barracks", "assembling-machine-2", "rts-lab", "lab"}},
  {"districts", {"rts-district-smelting", "rts-district-steel", "rts-district-circuits", "rts-district-electronics",
                 "rts-district-petrochem", "rts-district-engines", "rts-district-munitions", "rts-district-rails",
                 "rts-district-construction", "rts-district-science"}},
  {"age2-machines", {"rts-refinery", "oil-refinery", "rts-chemical-plant", "chemical-plant", "rts-pumpjack", "pumpjack",
                     "rts-district-petrochem"}},
  {"age3", {"rts-district-chemistry", "rts-district-electronics2", "rts-district-concrete", "rts-nuclear-plant",
            "rts-launch-complex", "rts-rare-extractor"}},
  {"nation", {"rts-city-center", "rts-depot", "rts-house", "rts-apartment", "rts-farm", "rts-bakery", "rts-fishing-hut",
              "rts-fort", "rts-field-depot", "rts-airfield"}},
  {"defence", {"rts-turret", "rts-laser-turret", "rts-bunker", "rts-aa-turret", "rts-wall", "rts-gate", "rts-radar",
               "rts-solar-array", "rts-accumulator", "rts-steam-plant"}},
}
step(function(player, P)
  local surface = match.surface()
  local y0 = P.origin.y + P.rows * CELL + 12
  P.lineups = {}
  for li, L in ipairs(LINEUPS) do
    local x = P.origin.x
    local y = y0 + (li - 1) * 14
    local area = {{P.origin.x - 4, y - 7}, {P.origin.x + 160, y + 7}}
    for _, e in ipairs(surface.find_entities_filtered({area = area})) do if e.valid then e.destroy() end end
    local tiles = {}
    for tx = area[1][1], area[2][1] do
      for ty = area[1][2], area[2][2] do tiles[#tiles + 1] = {name = "grass-1", position = {tx, ty}} end
    end
    surface.set_tiles(tiles, true, false, true, false)
    surface.destroy_decoratives({area = area})
    local names = {}
    for _, name in ipairs(L[2]) do
      if prototypes.entity[name] then
        local w, h = size_of(name)
        local pos = {x = x + w / 2, y = y + ((h % 2 == 0) and 0 or 0.5)}
        local ok, e = pcall(surface.create_entity, {name = name, position = pos, force = P.F,
                                                    create_build_effect_smoke = false})
        if ok and e then names[#names + 1] = name end
        x = x + w + 2
      end
    end
    P.lineups[li] = {tag = L[1], center = {x = (P.origin.x + x) / 2, y = y}, width = x - P.origin.x}
    note("line-up %s: %s", L[1], table.concat(names, " "))
    player.force.chart(surface, area)
  end
  return 120
end)
step(function(player, P)
  for _, L in ipairs(P.lineups) do
    local w = math.min(2048, math.floor((L.width + 6) * 16))
    shot(player, "lineup-z05-" .. L.tag, L.center, 0.5, w, 16 * 14)
    shot(player, "lineup-z025-" .. L.tag, L.center, 0.25, math.floor(w / 2), 8 * 14)
  end
  return 60
end)
step(function(player, P)
  for _, o in ipairs(P.hidden or {}) do if o.valid then o.visible = true end end
  util.log("RTS_R2L_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(15, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.r2l_probe
  if not P then
    P = {i = 1, at = game.tick + 120}
    storage.r2l_probe = P
  end
  if P.done or game.tick < P.at then return end
  local idx = P.i
  P.i = P.i + 1
  local ok, wait = pcall(STEPS[idx], player, P)
  if not ok then
    util.log("r2l probe step %d error: %s", idx, tostring(wait))
    wait = 30
  end
  if not wait or P.i > #STEPS then
    P.done = true
    if P.i > #STEPS and wait then util.log("RTS_R2L_DONE player %d (steps ran out)", player.index) end
    return
  end
  P.at = game.tick + wait
end)
