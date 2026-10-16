-- Phase 5 E1 GUI probe (test copy for tools/gui-run.sh with the self-test off; append require("scripts.economy_gui")
-- to control.lua). Starts a Nation-mode match from script, stops both AI commanders, then: the Railway Charter site at
-- half progress, every Age II building next to the capital with inputs, the age badge, the ledger panel, the build
-- menu's Age II tab and a district's building panel with its Auto button. Screenshots rts-e1-*.png; log lines
-- "[rts] e1 gui probe ..." and the stop marker RTS_E1_GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local hud = require("scripts.hud")
local ages = require("scripts.ages")
local districts = require("scripts.districts")
local ledgergui = require("scripts.ledgergui")
local production = require("scripts.production")

local function check(name, ok, fmt, ...)
  util.log("e1 gui probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function shot(player, tag, position, zoom)
  local path = string.format("rts-e1-%s.png", tag)
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = position or player.position, zoom = zoom or player.zoom})
  util.log("e1 gui probe: screenshot %s", path)
end

local NAMES = {"rts-district-smelting", "rts-district-steel", "rts-district-circuits", "rts-district-electronics",
               "rts-district-petrochem", "rts-district-engines", "rts-district-munitions", "rts-district-rails",
               "rts-district-construction", "rts-district-science", "rts-refinery", "rts-chemical-plant"}

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player, P)
  lobby.start_match({opponents = 1, difficulty = "normal", size = "large", enemy_brain = "ai", mode = "nation"},
    "e1 gui probe")
  return 180
end)

step(function(player, P)
  local F = player.force.name
  ai.stop_force(F)
  ai.stop_force(util.ENEMY_FORCE)
  local force = game.forces[F]
  force.technologies["rts-industrialisation"].researched = true
  P.project = ages.start_project(F)
  for item, n in pairs(ages.required()) do economy.give(F, item, math.floor(n / 2)) end
  check("project", P.project ~= nil, "%s", ages.describe(F))
  return 300
end)

step(function(player, P)
  local p = P.project
  if p and p.site and p.site.valid then
    camera.jump_to(player, p.site.position)
    shot(player, "site", p.site.position, 1.0)
  end
  shot(player, "badge-age1")
  return 30
end)

step(function(player, P)
  local F = player.force.name
  ages.set_age(F, 2, "gui probe")
  local surface = match.surface()
  local home = match.home(F)
  for _, e in pairs(surface.find_entities_filtered({area = {{home.x - 30, home.y + 5}, {home.x + 30, home.y + 35}},
                                                     type = {"tree", "simple-entity", "cliff"}})) do e.destroy() end
  P.placed = {}
  for i, name in ipairs(NAMES) do
    local col, row = (i - 1) % 6, math.floor((i - 1) / 6)
    local want = {x = home.x - 15.5 + col * 6, y = home.y + 10.5 + row * 7}
    local pos = surface.find_non_colliding_position(name, want, 8, 1, true) or want
    local e = surface.create_entity({name = name, position = pos, force = F, raise_built = true})
    if e then P.placed[#P.placed + 1] = e end
  end
  local oil = {x = home.x + 22.5, y = home.y + 24.5}
  surface.create_entity({name = "crude-oil", position = oil, amount = 300000})
  local pj = surface.create_entity({name = "rts-pumpjack", position = oil, force = F, raise_built = true})
  for item, n in pairs({["iron-ore"] = 200, ["copper-ore"] = 200, stone = 200, coal = 200, ["iron-plate"] = 400,
                        ["copper-plate"] = 300, ["steel-plate"] = 100, ["rts-crude-oil"] = 100,
                        ["electronic-circuit"] = 100, ["plastic-bar"] = 50, sulfur = 20, ["engine-unit"] = 10,
                        ["advanced-circuit"] = 10, ["stone-brick"] = 100}) do
    economy.give(F, item, n)
  end
  local city = districts.city_of(buildings.main_cc(F).entity)
  for item, n in pairs({["electronic-circuit"] = 120, ["steel-plate"] = 80, ["advanced-circuit"] = 20,
                        ["plastic-bar"] = 60, ["engine-unit"] = 10}) do
    districts.set_make_target(city, item, n)
  end
  check("placed", #P.placed == #NAMES and pj ~= nil, "%d of %d Age II buildings, pumpjack %s", #P.placed, #NAMES,
    tostring(pj ~= nil))
  return 600
end)

step(function(player, P)
  local F = player.force.name
  local home = match.home(F)
  local center = {x = home.x, y = home.y + 15}
  camera.jump_to(player, center)
  shot(player, "districts-z05", center, 0.5)
  shot(player, "districts-z1", center, 1.0)
  local running = 0
  for _, e in ipairs(P.placed) do
    if e.valid and e.get_recipe() then running = running + 1 end
  end
  check("districts_auto", running >= 6, "%d of %d Age II buildings have an auto recipe", running, #P.placed)
  return 30
end)

step(function(player, P)
  local frame = ledgergui.open(player)
  check("ledger_open", frame ~= nil and frame.valid, "ledger frame %s", tostring(frame ~= nil))
  return 120
end)

step(function(player, P)
  shot(player, "ledger") -- screenshots render at the end of the tick: no GUI change in a shot's step
  return 30
end)

step(function(player, P)
  ledgergui.close(player)
  hud.set_build_tab(player, "age2")
  return 30
end)

step(function(player, P)
  shot(player, "build-age2")
  return 30
end)

step(function(player, P)
  local e = P.placed[5]
  if e and e.valid then selection.select_building(player.index, e.unit_number) end
  return 60
end)

step(function(player, P)
  shot(player, "district-panel")
  return 30
end)

step(function(player, P)
  local e = P.placed[5]
  local auto = e and e.valid and production.is_auto(buildings.get(e.unit_number))
  hud.recipe_click(player, "*auto*")
  local after = e and e.valid and production.is_auto(buildings.get(e.unit_number))
  check("auto_toggle", auto == true and after == false, "auto %s -> %s after the Auto button", tostring(auto),
    tostring(after))
  return 60
end)

step(function(player, P)
  shot(player, "district-panel-fixed")
  return 30
end)

step(function(player, P)
  util.log("RTS_E1_GUI_DONE player %d", player.index)
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local P = storage.e1_gui_probe
  if not P then
    P = {i = 1, at = game.tick + 180}
    storage.e1_gui_probe = P
  end
  if P.done or game.tick < P.at then return end
  local ok, wait = pcall(STEPS[P.i], player, P)
  if not ok then
    util.log("e1 gui probe step %d error: %s", P.i, tostring(wait))
    wait = 30
  end
  P.i = P.i + 1
  if not wait or P.i > #STEPS then P.done = true return end
  P.at = game.tick + wait
end)
