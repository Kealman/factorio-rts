-- Phase 5 M2 world GUI probe (test copy for tools/gui-run.sh, self-test off): copy into the copy's scripts/ and append
-- require("scripts.world2_gui") to its control.lua. It starts a 4-nation Nation match on a 2048 world, stops the AIs,
-- generates and charts the whole map for rts-player, then shows the strategic layer: the map view at strategic zoom
-- (region names with resources, choke markers, city and city-state names, ports), a closer chart view of a region and
-- of a city-state, the HUD minimap in regional mode (following the camera) and in world mode (N), and an alert with
-- its region name. Every view logs "W2GUI_CAPTURE <tag>" so an outside script can grab the window (screencapture:
-- game.take_screenshot cannot render the map view), and game.take_screenshot writes rts-w2-<tag>.png (game view and
-- GUI). Log lines "[rts] w2gui ...", checks "[rts] w2gui check <name>: PASS|FAIL", stop marker RTS_W2GUI_DONE.
local events = require("scripts.events")
local util = require("scripts.util")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local camera = require("scripts.camera")
local world = require("scripts.world")
local strategic = require("scripts.strategic")
local logistics = require("scripts.logistics")
local ai = require("scripts.ai.init")

local function check(name, ok, fmt, ...)
  util.log("w2gui check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function view(player)
  return string.format("pos %s zoom %.3f render_mode %s", util.pos_str(player.position), player.zoom,
    util.define_name(defines.render_mode, player.render_mode))
end

local function capture(player, tag)
  game.take_screenshot({player = player, by_player = player, path = "rts-w2-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}, position = player.position,
                        zoom = math.max(0.03125, player.zoom)}) -- take_screenshot refuses zoom below 1/32
  util.log("w2gui: %s: %s", tag, view(player))
  util.log("W2GUI_CAPTURE %s", tag)
end

local function go(player, position, zoom)
  camera.jump_to(player, position)
  player.zoom = zoom
end

local function minimap(player) return player.gui.screen[strategic.MINIMAP_NAME] end

local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(player)
  lobby.start_match({opponents = 3, difficulty = "normal", mode = "nation", world_size = 2048, enemy_brain = "ai"},
    "world2 gui probe")
  for _, f in ipairs(match.ai_forces()) do ai.stop_force(f) end -- a calm map for the views
  return 120
end)

step(function(player)
  local W = storage.world
  local surface = game.surfaces[W.surface]
  surface.request_to_generate_chunks({0, 0}, math.ceil(W.size / 64))
  surface.force_generate_chunk_requests()
  local h = W.size / 2
  player.force.chart(surface, {{-h, -h}, {h, h}})
  util.log("w2gui: map generated (fill %d/%d, done %s), charting %d chunks", W.fill.generated, W.fill.total,
    tostring(W.fill.done), (W.size / 32) ^ 2)
  return 600
end)

step(function(player)
  local cnt = strategic.counts(player.force.name)
  check("labels", cnt.regions == #world.regions() and cnt.chokes > 0 and cnt.cities > 0,
    "rts-player objects %s, %d regions, %d chokes, %d city-states", serpent.line(cnt), #world.regions(),
    #world.chokes(), #world.city_states())
  local zl = player.zoom_limits
  check("zoom_limits", zl and zl.furthest and zl.furthest.distance ~= nil and zl.furthest.distance >= storage.world.size,
    "furthest %s, furthest game view %s", serpent.line(zl and zl.furthest), serpent.line(zl and zl.furthest_game_view))
  go(player, {x = 0, y = 0}, 0.028)
  return 90
end)

step(function(player)
  check("strategic_view", player.render_mode == defines.render_mode.chart and player.zoom < 0.05, "%s", view(player))
  capture(player, "strategic")
  return 300
end)

step(function(player)
  local reg = world.region_at(match.home(player.force.name))
  go(player, reg.center, 0.07)
  return 90
end)

step(function(player)
  capture(player, "home-region")
  return 300
end)

step(function(player)
  local cs = world.city_states()[1]
  if cs then go(player, cs.position, 0.1) end
  return 90
end)

step(function(player)
  capture(player, "city-state")
  return 300
end)

step(function(player)
  local c = world.chokes()[1]
  if c then go(player, c.position, 0.1) end
  return 90
end)

step(function(player)
  capture(player, "choke")
  return 300
end)

step(function(player)
  go(player, match.home(player.force.name), 0.3)
  return 60
end)

step(function(player)
  local mm = minimap(player)
  local home = match.home(player.force.name)
  -- the regional window follows the camera but stays inside the map
  local lim = storage.world.size / 2 - strategic.MINIMAP_TILES / 2
  local want = {x = math.max(-lim, math.min(lim, player.position.x)), y = math.max(-lim, math.min(lim, player.position.y))}
  check("minimap_regional", mm and strategic.minimap_mode(player) == "regional"
    and math.abs(mm.zoom - strategic.MINIMAP_SIZE / strategic.MINIMAP_TILES) < 1e-3
    and util.distance(mm.position, want) < 8,
    "mode %s, minimap zoom %.4f at %s (camera %s)", strategic.minimap_mode(player), mm and mm.zoom or -1,
    mm and util.pos_str(mm.position) or "-", util.pos_str(player.position))
  -- an alert with a position: its line names the region
  logistics.alert(player.force.name, "hauler-lost", {x = home.x + 20, y = home.y + 20}, "rts.alert-hauler-lost")
  return 60
end)

step(function(player)
  capture(player, "minimap-regional")
  return 300
end)

step(function(player)
  strategic.toggle_minimap(player)
  return 60
end)

step(function(player)
  local mm = minimap(player)
  check("minimap_world", mm and strategic.minimap_mode(player) == "world"
    and math.abs(mm.zoom - strategic.MINIMAP_SIZE / (storage.world.size + 16)) < 1e-3,
    "mode %s, minimap zoom %.4f at %s", strategic.minimap_mode(player), mm and mm.zoom or -1,
    mm and util.pos_str(mm.position) or "-")
  capture(player, "minimap-world")
  return 300
end)

step(function(player)
  strategic.toggle_minimap(player)
  go(player, {x = 0, y = 0}, 0.028)
  return 90
end)

step(function(player)
  capture(player, "strategic-regional-minimap")
  return 300
end)

step(function(player)
  util.log("RTS_W2GUI_DONE")
  return nil
end)

events.on_nth_tick(30, function(e)
  local player = game.connected_players[1]
  if not player or e.tick < 180 then return end
  local st = storage.w2gui
  if not st then
    st = {i = 1, at = e.tick}
    storage.w2gui = st
  end
  if st.done or e.tick < st.at then return end
  local fn = STEPS[st.i]
  if not fn then
    st.done = true
    return
  end
  local wait = fn(player)
  st.i = st.i + 1
  if wait == nil then st.done = true else st.at = e.tick + wait end
end)
