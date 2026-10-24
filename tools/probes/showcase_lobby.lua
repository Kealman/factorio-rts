-- Showcase (release media), launch 1: the Nation lobby and a 6-nation 4096 world (tools/showcase.sh lobby).
--   01-lobby          the lobby in Nation mode: 6 nations, World 4096x4096, Survey, the Victory list opened by a real
--                     click (tools/gui-drive.sh; a drop-down list cannot be opened from Lua)
--   12-world-4096     Start match, then the whole world in the map view once the background generation is done (the
--                     game runs at cfg.gen_speed meanwhile); alt-12-world-progress at about half, with the
--                     "World: N % generated" line under the minimap
-- Log lines "[rts] showcase: ...", the end marker "SHOWCASE_DONE lobby shoot".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local lobby = require("scripts.lobby")
local worldgen = require("scripts.worldgen")
local lib = require("scripts.showcase_lib")

local cfg = lib.cfg
local step, scene, capture = lib.step, lib.scene, lib.capture
local W, H = lib.W, lib.H

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function gui_click(player, el)
  if not (el and el.valid) then return false end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
  return true
end

-- The Victory drop-down relative to the dialog's top-left corner at UI scale 1 (measured in a 1920x1080 capture;
-- docs/qa/phase5-m3-protocol.md has (607, 402) for a dialog at (482, 191) at scale 0.75)
local VICTORY_DD = cfg.victory_dd or {167, 281}

step(function(player, P)
  local nauvis = game.surfaces.nauvis
  local mgs = nauvis.map_gen_settings
  mgs.seed = cfg.seed or 4242
  nauvis.map_gen_settings = mgs
  local p = storage.lobby.pending
  p.mode, p.opponents, p.difficulty = "nation", 5, "normal"
  p.world_size, p.survey, p.victory, p.time_limit = 4096, true, "conquest_space", 0
  lobby.show_lobby(player)
  lib.park_mouse()
  return 90
end)

scene("01-lobby", function()
  step(function(player, P)
    local f = player.gui.screen.rts_lobby
    P.dlg = f and f.location and {x = f.location.x, y = f.location.y} or {x = 750, y = 263}
    lib.log("lobby dialog at (%d, %d), scale %.2f", P.dlg.x, P.dlg.y, player.display_scale)
    return 30
  end)
  capture("alt-01-lobby-closed", 60)
  step(function(player, P)
    local s = player.display_scale
    lib.click(P.dlg.x + VICTORY_DD[1] * s, P.dlg.y + VICTORY_DD[2] * s)
    -- the pointer leaves the window (the open list stays): the game draws the RTS cursor's icon at the pointer
    lib.park_mouse()
    return 60
  end)
  step(function(player, P)
    lib.capture_now(player, "01-lobby")
    return 90
  end)
  step(function(player, P)
    -- the list closes again (a second click on the drop-down), the pointer leaves the window
    local s = player.display_scale
    lib.click(P.dlg.x + VICTORY_DD[1] * s, P.dlg.y + VICTORY_DD[2] * s)
    lib.park_mouse()
    return 60
  end)
end)

scene("12-world-4096", function()
  step(function(player, P)
    gui_click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
    return 120
  end)
  lib.wait_until("match", function() return not match.in_lobby() end, 30, 3600)
  step(function(player, P)
    local c = match.config()
    lib.log("match: %s %s nations %s survey %s", tostring(c.mode), tostring(c.world_size), tostring(c.nations),
      tostring(c.survey))
    -- the whole world between the strip and the ability bar
    local zoom = (H - 200) / (4096 * 32)
    P.wzoom = zoom
    lib.view(player, {x = 0, y = -((135 + H - 70) / 2 - H / 2) / (32 * zoom)}, zoom)
    game.speed = cfg.gen_speed or 4
    return 60
  end)
  step(function(player, P)
    local pr = worldgen.progress()
    if (P.last_share or -1) + 0.1 <= pr.share then
      P.last_share = pr.share
      lib.log("world %d/%d (%.0f %%), done %s, speed %.1f", pr.generated, pr.planned, pr.share * 100, tostring(pr.done),
        game.speed)
    end
    if not P.half and pr.share >= 0.45 then
      P.half = true
      lib.capture_now(player, "alt-12-world-progress")
    end
    if pr.done then
      game.speed = 1
      return 300
    end
    P.i = P.i - 1
    return 60
  end)
  step(function(player, P)
    lib.clean_hud(player, true)
    return 30
  end)
  capture("alt-12-world-4096-limit", 90)
  step(function(player, P)
    -- every capital between the HUD bands (strip and minimap above, panels and ability bar below): the map view's
    -- furthest zoom (1.1 world widths, scripts/strategic.lua) is widened for this capture only; the game runs at 0.01
    -- meanwhile, so the strategic module's next check (it restores the limit) comes after the window grab
    local x1, y1, x2, y2
    for _, c in pairs(storage.cities or {}) do
      if c.capital then
        local p = c.position
        x1, y1 = math.min(x1 or p.x, p.x), math.min(y1 or p.y, p.y)
        x2, y2 = math.max(x2 or p.x, p.x), math.max(y2 or p.y, p.y)
      end
    end
    if not x1 then return 1 end
    -- a capital's marker (circle about 35 px) must stay between the strip (bottom y 103) and the ability bar / unit
    -- panel (top y 946-985): marker centres within y 138-950; 8 px slack each side. The square world cannot fill the
    -- 16:9 width at this zoom (black bands remain); alt-12-world-4096-wide fills the width with four capitals.
    local top, bottom = 138 + 8, 950 - 8
    local zoom = math.min((W - 120) / (x2 - x1), (bottom - top) / (y2 - y1)) / 32
    local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    lib.log("capitals span (%d, %d)-(%d, %d): zoom %.4f (%.3f px per tile)", x1, y1, x2, y2, zoom, zoom * 32)
    game.speed = 0.01
    player.set_zoom_limits(defines.controllers.remote, {closest = {zoom = 2},
      furthest = {distance = 20000, max_distance = 20000}, furthest_game_view = {zoom = 0.15}})
    lib.view(player, {x = cx, y = cy - ((top + bottom) / 2 - H / 2) / (32 * zoom)}, zoom)
    P.cap_c, P.cap_zoom = {x = cx, y = cy}, zoom
    return 1
  end)
  step(function(player, P)
    lib.capture_now(player, "12-world-4096")
    return 2
  end)
  step(function(player, P)
    -- the alternate: the world fills the width (four of the six capitals between the bands)
    local zoom = W / (4096 * 32)
    lib.view(player, {x = 0, y = P.cap_c and P.cap_c.y or 0}, zoom)
    return 2
  end)
  step(function(player, P)
    lib.capture_now(player, "alt-12-world-4096-wide")
    return 1
  end)
  step(function(player, P)
    game.speed = 1
    return 120
  end)
end)

step(function(player, P) return nil end)
lib.start()
