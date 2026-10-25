-- Showcase (release media): the shared part of the staged-screenshot probes tools/probes/showcase_*.lua. Test-only:
-- tools/showcase.sh copies this file, one scene probe and a generated scripts/showcase_cfg.lua into a test copy of the
-- mod (build/showcase-<launch>/factorio-rts) and appends require("scripts.showcase_<launch>") to its control.lua.
--
-- A probe is a list of steps run on on_tick: step(fn) with fn(player, P) -> ticks to wait (nil ends the probe). Steps
-- are grouped into scenes (lib.scene(name, fn)); scenes not listed in cfg.only are skipped. A capture logs
-- "RTS_DRIVE <n> capture <name>" (tools/gui-drive.sh grabs the client window into the raw directory; tools/showcase.sh
-- crops the 28 px title bar to docs/media/<name>.png) and, with cfg.screenshots, also takes an engine screenshot
-- (game.take_screenshot, script-output/showcase-<name>.png). Action shots slow the game to cfg.freeze_speed while the
-- window is grabbed, so the explosion on screen is the one of the tick that triggered the capture.
--
-- Real clicks (lobby drop-downs) go through tools/gui-input/fdrive.swift, which takes the title bar as window height -
-- 800: in a window of height H the probe passes y - (H - 800) so the click lands on game-area pixel y.
local util = require("scripts.util")
local events = require("scripts.events")
local camera = require("scripts.camera")
local cfg = require("scripts.showcase_cfg")

local lib = {}
lib.cfg = cfg
lib.W = cfg.width or 1920
lib.H = cfg.height or 1080
lib.KEY = {F = 3, H = 4, X = 7, B = 11, Q = 12, Y = 16, C = 8, G = 5, Z = 6, SPACE = 49, ESC = 53}

local KEY_STATE = "showcase_" .. (cfg.launch or "probe") .. "_" .. (cfg.phase or "shoot")

function lib.log(fmt, ...) util.log("showcase: " .. fmt, ...) end

function lib.state()
  storage[KEY_STATE] = storage[KEY_STATE] or {i = 1, seq = 0}
  return storage[KEY_STATE]
end

function lib.drive(fmt, ...)
  local S = lib.state()
  S.seq = S.seq + 1
  util.log("RTS_DRIVE %d " .. fmt, S.seq, ...)
end
-- game-area pixel -> fdrive argument (see the header)
function lib.click(x, y, right)
  lib.drive("%s %d %d", right and "rclick" or "click", math.floor(x), math.floor(y - (lib.H - 800)))
end
-- the pointer leaves the window (no hover tooltip in a capture)
function lib.park_mouse()
  lib.drive("move %d %d", lib.W + 60, math.floor(lib.H / 2 - (lib.H - 800)))
end

---------------------------------------------------------------------------
-- Steps and scenes
---------------------------------------------------------------------------
local STEPS = {}
local SCENES = {}
lib.STEPS = STEPS

function lib.step(fn) STEPS[#STEPS + 1] = fn end

local function wanted(name)
  if not cfg.only then return true end
  for _, n in ipairs(cfg.only) do
    if n == name then return true end
  end
  return false
end
lib.wanted = wanted

--- Register a scene: its steps run only when cfg.only is nil or names it. `always` steps (setup another scene needs)
--- are plain lib.step calls outside scenes.
function lib.scene(name, register)
  local guard = #STEPS + 1
  STEPS[guard] = false -- placeholder, set below
  register()
  local last = #STEPS
  SCENES[#SCENES + 1] = {name = name, first = guard, last = last}
  STEPS[guard] = function(player, P)
    if wanted(name) then
      lib.log("scene %s: start (tick %d)", name, game.tick)
      P.scene = name
      return 1
    end
    lib.log("scene %s: skipped", name)
    P.i = last + 1
    return 1
  end
end

--- Poll `cond(player, P)` every `every` ticks until true or `max` ticks passed.
function lib.wait_until(label, cond, every, max)
  lib.step(function(player, P)
    P.wn = (P.wn or 0) + every
    local ok = cond(player, P)
    if ok or P.wn >= max then
      lib.log("wait %s: %s after %d ticks", label, ok and "done" or "TIMEOUT", P.wn)
      P.wn = nil
      return 1
    end
    P.i = P.i - 1
    return every
  end)
end

function lib.wait(ticks) lib.step(function() return ticks end) end

---------------------------------------------------------------------------
-- Camera, panels, captures
---------------------------------------------------------------------------
function lib.view(player, pos, zoom)
  camera.jump_to(player, pos)
  if zoom then player.zoom = zoom end
end

local function close_named(player, name)
  local f = player.gui.screen[name]
  if f and f.valid then f.destroy() end
end

--- Close every RTS panel a scene may have opened and clear the selection (the HUD stays).
--- 0.1.1 (issue #16): the guided objective strip stays out of the release shots: the player's lobby switch off (it would
--- show in a fresh save's first match of each mode). Before every Start, and in close_panels for the loaded bake.
function lib.no_objectives(player)
  local mods = package.loaded
  local o = mods["__" .. script.mod_name .. "__/scripts/objectives.lua"] or mods["scripts.objectives"]
  if o and o.set_pref then o.set_pref(player.index, false) end
end

function lib.close_panels(player)
  lib.no_objectives(player)
  local mods = package.loaded
  local function m(name) return mods["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or mods["scripts." .. name] end
  local ok, err = pcall(function()
    local sel = m("selection")
    if sel then sel.clear(player.index) end
    for _, name in ipairs({"ledgergui", "marketgui", "techgui"}) do
      local g = m(name)
      if g and g.close then g.close(player) end
    end
    local d = m("diplomacygui")
    if d and d.is_open and d.is_open(player) then d.close(player) end
    local b = m("belts")
    if b and b.FRAME and player.gui.screen[b.FRAME] then b.close_tool(player, "showcase") end
  end)
  if not ok then lib.log("close_panels: %s", tostring(err)) end
  close_named(player, "rts_airfield_panel")
  close_named(player, "rts_hud_help")
end

--- Calm shots: drop the player's force alerts (and, with `kills`, the kill feed) so stale lines of the baked match
--- ("Hauler N: no fuel ...") do not sit over the scene; alerts whose kind contains `keep_kind` stay; the vanilla map
--- alert icons go too. The HUD redraws at once.
function lib.clean_hud(player, kills, keep_kind)
  local f = player.force.name
  local keep = {}
  for _, a in ipairs(storage.alerts or {}) do
    if a.force ~= f or (keep_kind and string.find(a.kind or "", keep_kind, 1, true)) then keep[#keep + 1] = a end
  end
  storage.alerts = keep
  if kills and storage.hud then storage.hud.kills = {} end
  player.remove_alert({})
  local hud = package.loaded["__" .. script.mod_name .. "__/scripts/hud.lua"] or package.loaded["scripts.hud"]
  if hud and hud.refresh then hud.refresh(player.index) end
end

--- The engine's own alert icons (construction, repair, train fuel ...) stay off the map for the probe player: the
--- mod's HUD shows its own alert lines, the vanilla alert GUI is hidden anyway (scripts/camera.lua).
function lib.quiet_alerts(player)
  for _, t in pairs(defines.alert_type) do pcall(function() player.disable_alert(t) end) end
  player.remove_alert({})
end

--- Grab the client window now (and an engine screenshot with cfg.screenshots).
function lib.capture_now(player, name)
  player.clear_console()
  lib.drive("capture %s", name)
  if cfg.screenshots then
    game.take_screenshot({player = player, by_player = player, path = "showcase-" .. name .. ".png", show_gui = true,
                          resolution = {lib.W, lib.H}, position = player.position, zoom = player.zoom,
                          force_render = true, anti_alias = true})
  end
  lib.log("capture %s at %s zoom %.3f tick %d", name, util.pos_str(player.position), player.zoom, game.tick)
end

--- A capture step: grab, then wait `wait` ticks (the window grab takes ~0.5 s of wall clock).
function lib.capture(name, wait)
  lib.step(function(player, P)
    lib.capture_now(player, name)
    return wait or 90
  end)
end

--- Slow the game down, grab, and restore the speed a few seconds later (action shots).
function lib.freeze_capture(player, P, name)
  P.speed_before = game.speed
  game.speed = cfg.freeze_speed or 0.1
  lib.clean_hud(player, false) -- alerts that came in since the scene's set-up (the kill feed stays: it is the fight)
  lib.capture_now(player, name)
end
function lib.unfreeze(P)
  game.speed = P.speed_before or 1
  P.speed_before = nil
end

--- Make an area visible to the force now (a scanner-sweep-like chart: visible ~10 s).
function lib.reveal(force_name, surface, center, half)
  game.forces[force_name].chart(surface, {{center.x - half, center.y - half}, {center.x + half, center.y + half}})
end

---------------------------------------------------------------------------
-- Staging helpers
---------------------------------------------------------------------------
function lib.clear(surface, center, r, types)
  for _, e in ipairs(surface.find_entities_filtered({area = {{center.x - r, center.y - r}, {center.x + r, center.y + r}},
      type = types or {"tree", "simple-entity", "cliff", "fish", "corpse"}})) do
    if e.valid then
      if e.type == "cliff" then e.destroy({do_cliff_correction = true}) else e.destroy() end
    end
  end
end

--- Place a building of `force` near `pos` through the build pipeline (raise_built), clearing trees and rocks first.
function lib.place(surface, name, pos, force, radius, dir)
  lib.clear(surface, pos, 8)
  local p = surface.find_non_colliding_position(name, pos, radius or 12, 0.5, true) or pos
  local e = surface.create_entity({name = name, position = p, force = force, raise_built = true, direction = dir})
  if not e then lib.log("place %s at %s failed", name, util.pos_str(pos)) end
  return e
end

function lib.research(force_name, list)
  local force = game.forces[force_name]
  for _, t in ipairs(list) do
    local tech = force.technologies[t]
    if tech and tech.enabled then tech.researched = true else lib.log("research %s: not available", t) end
  end
end

--- Spawn `n` units of `name` for `force` in a block centred on `pos`, facing nothing in particular.
function lib.spawn(units_mod, name, n, pos, force, cols, gap)
  cols = cols or 5
  gap = gap or 3
  local list = {}
  local rows = math.ceil(n / cols)
  for i = 0, n - 1 do
    local cx = (i % cols) - (math.min(n, cols) - 1) / 2
    local cy = math.floor(i / cols) - (rows - 1) / 2
    local e = units_mod.spawn(name, {x = pos.x + cx * gap, y = pos.y + cy * gap}, force)
    if e then list[#list + 1] = e end
  end
  return list
end

function lib.centroid(list)
  local x, y, n = 0, 0, 0
  for _, e in ipairs(list) do
    if e.valid then x, y, n = x + e.position.x, y + e.position.y, n + 1 end
  end
  if n == 0 then return nil end
  return {x = x / n, y = y / n}, n
end

function lib.dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

---------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------
function lib.done_marker() return "SHOWCASE_DONE " .. (cfg.launch or "?") .. " " .. (cfg.phase or "shoot") end

local function run(e)
  local player = game.connected_players[1]
  if not player then return end
  local S = lib.state()
  if S.done then return end
  if not S.at then S.at = e.tick + (cfg.start_delay or 180) end
  if e.tick < S.at then return end
  local idx = S.i
  local fn = STEPS[idx]
  if not fn then
    S.done = true
    util.log("%s (steps ran out)", lib.done_marker())
    return
  end
  S.i = S.i + 1
  local ok, wait = pcall(fn, player, S)
  if not ok then
    util.log("showcase: step %d (%s) error: %s", idx, tostring(S.scene), tostring(wait))
    wait = 30
  end
  if not wait then
    S.done = true
    util.log("%s", lib.done_marker())
    return
  end
  S.at = e.tick + math.max(1, wait)
end

function lib.start()
  events.on(defines.events.on_tick, run)
end

return lib
