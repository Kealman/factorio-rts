-- Territory GUI probe (Phase 5 M1). Test copy for tools/gui-run.sh, self-test off: append
-- require("scripts.territory_gui") to the copy's control.lua and copy this file into its scripts/. It starts a Nation
-- match (1 AI, large map), adds a second city, a fort and a hub for the player, then shows the borders at zoom 1, at
-- zoom 0.15 and in the map (chart) view, opens the city panel and the city list, and switches every border object off
-- and on again for the frame-cost comparison. Each view logs "TERRGUI_CAPTURE <tag>" so an outside script can grab the
-- window (screencapture), and game.take_screenshot writes rts-terr-<tag>.png (game view and GUI only).
-- Log lines "[rts] terrgui ...", the last one RTS_TERRGUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local selection = require("scripts.selection")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local citygui = require("scripts.citygui")

local REMOTE = defines.controllers.remote
local LIMITS = {closest = {zoom = 2}, furthest = {zoom = 0.15}, furthest_game_view = {zoom = 0.15}} -- camera.lua
local CHART_LIMITS = {closest = {zoom = 2}, furthest = {zoom = 0.02}, furthest_game_view = {zoom = 0.15}}

local function view(player)
  return string.format("pos %s zoom %.3f render_mode %s", util.pos_str(player.position), player.zoom,
    util.define_name(defines.render_mode, player.render_mode))
end

local function capture(player, tag)
  local path = "rts-terr-" .. tag .. ".png"
  game.take_screenshot({player = player, by_player = player, path = path, show_gui = true, force_render = true,
                        resolution = {1280, 800}, position = player.position, zoom = player.zoom})
  util.log("terrgui: screenshot %s, %s", path, view(player))
  util.log("TERRGUI_CAPTURE %s", tag)
end

local function go(player, position, zoom)
  camera.jump_to(player, position)
  player.zoom = zoom
end

local function set_visible(on)
  local n = 0
  for _, list in pairs(storage.territory.objs or {}) do
    for _, o in ipairs(list) do
      if o.valid then
        o.visible = on
        n = n + 1
      end
    end
  end
  return n
end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function()
  lobby.start_match({opponents = 1, difficulty = "normal", size = "large", map = "chokes", enemy_brain = "ai",
                     mode = "nation"}, "territory gui probe")
  return 240
end)

step(function(player, S)
  local F = player.force.name
  territory.flush()
  local cap = cities.get(storage.nations[F].capital)
  S.capital = cap.position
  local surface = match.surface()
  local site = surface.find_non_colliding_position("rts-city-center", {cap.position.x + 150, cap.position.y + 60}, 20, 1,
    true)
  local id = site and cities.found(F, site)
  local fort_pos = surface.find_non_colliding_position("rts-fort", {cap.position.x + 30, cap.position.y - 80}, 10, 1, true)
  local fort = fort_pos and surface.create_entity({name = "rts-fort", position = fort_pos, force = F, raise_built = true})
  local hub_pos = surface.find_non_colliding_position("rts-hub", {cap.position.x - 20, cap.position.y + 85}, 10, 1, true)
  local hub = hub_pos and surface.create_entity({name = "rts-hub", position = hub_pos, force = F, raise_built = true})
  territory.flush()
  local n, valid = territory.object_count()
  util.log("terrgui: second city %s at %s, fort %s, hub %s; land %d cells, share %.3f, objects %d (valid %d)",
    tostring(id), util.pos_str(site), tostring(fort ~= nil), tostring(hub ~= nil), territory.cells(F),
    territory.share(F), n, valid)
  S.radius = cap.radius
  go(player, {x = cap.position.x + cap.radius - 2, y = cap.position.y + 12}, 1)
  return 90
end)

step(function(player) capture(player, "zoom1") return 120 end)

step(function(player, S)
  go(player, {x = S.capital.x + S.radius - 20, y = S.capital.y + 20}, 0.15)
  return 90
end)

step(function(player) capture(player, "zoom015") return 120 end)

step(function(player)
  player.set_zoom_limits(REMOTE, CHART_LIMITS)
  go(player, {x = 0, y = 0}, 0.06)
  return 90
end)

step(function(player) capture(player, "chart") return 120 end)

step(function(player, S)
  player.set_zoom_limits(REMOTE, LIMITS)
  go(player, {x = S.capital.x + 10, y = S.capital.y + 5}, 0.5)
  local nation = storage.nations[player.force.name]
  local cap = cities.get(nation.capital)
  selection.select_building(player.index, cap.center)
  return 90
end)

step(function(player) capture(player, "citypanel") return 60 end)

step(function(player, S)
  local list = cities.for_force(player.force.name)
  local second = list[2]
  if second then
    selection.clear(player.index)
    citygui.open(player, second.id)
    go(player, {x = second.position.x, y = second.position.y}, 0.5)
  end
  return 90
end)

step(function(player) capture(player, "secondcity") return 60 end)

-- frame cost: borders on, off, on at zoom 0.15 over the capital's border (the outside script samples the client's CPU)
step(function(player, S)
  selection.clear(player.index)
  local g = storage.players[player.index].citygui
  if g then g.pinned = nil end
  go(player, {x = S.capital.x + S.radius - 20, y = S.capital.y}, 0.15)
  util.log("TERRGUI_PHASE on1 objects %d", set_visible(true))
  return 900
end)

step(function()
  util.log("TERRGUI_PHASE off objects %d", set_visible(false))
  return 900
end)

step(function()
  util.log("TERRGUI_PHASE on2 objects %d", set_visible(true))
  return 900
end)

step(function()
  util.log("TERRGUI_PHASE end")
  util.log("RTS_TERRGUI_DONE")
  return nil
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player then return end
  local S = storage.terrgui_probe
  if not S then
    S = {i = 1, at = game.tick + 180}
    storage.terrgui_probe = S
  end
  if S.done or game.tick < S.at then return end
  local wait = STEPS[S.i](player, S)
  S.i = S.i + 1
  if not wait or S.i > #STEPS then
    S.done = true
    return
  end
  S.at = game.tick + wait
end)
