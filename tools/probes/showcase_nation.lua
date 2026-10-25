-- Showcase (release media), Nation launch: tools/showcase.sh runs it twice.
--   cfg.phase = "bake":  the lobby (Nation, 3 nations, 2048, Survey, seed cfg.seed), then the AI plays the player's own
--                        nation too (ai.init_force rts-player, cfg.ai_difficulty, doctrine cfg.doctrine) at game speed
--                        cfg.bake_speed until match minute cfg.bake_minutes, so the capital, its districts, haulers, a
--                        town and its rail line are real play; then game.auto_save("showcase-nation") and the marker.
--   cfg.phase = "shoot": loads that save (tools/showcase.sh --load-game) and stages the Nation scenes (below) with the
--                        QA shortcuts' module calls, each ending in a window capture docs/media/<scene>.png.
-- Log lines "[rts] showcase: ...", the end marker "SHOWCASE_DONE nation <phase>".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local lobby = require("scripts.lobby")
local camera = require("scripts.camera")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local cities = require("scripts.cities")
local ages = require("scripts.ages")
local treasury = require("scripts.treasury")
local rails = require("scripts.rails")
local population = require("scripts.population")
local ai = require("scripts.ai.init")
local lib = require("scripts.showcase_lib")

local cfg = lib.cfg
local F = "rts-player"
local step, scene, capture = lib.step, lib.scene, lib.capture

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

local function count_names(surface, force, prefix)
  local n = 0
  for _, e in ipairs(surface.find_entities_filtered({force = force})) do
    if string.sub(e.name, 1, #prefix) == prefix then n = n + 1 end
  end
  return n
end

local function status(tag)
  local surface = match.surface()
  local parts = {}
  for _, f in ipairs(match.forces()) do
    local lines_open = 0
    for _, l in ipairs(rails.lines_of(f)) do if l.state == "open" then lines_open = lines_open + 1 end end
    local trains = #rails.trains_of(f)
    local ok, res = pcall(population.total, f)
    parts[#parts + 1] = string.format("%s age %d cities %d residents %s cr %d lines %d/%d trains %d haulers %d army %d "
      .. "districts %d", f, ages.of(f), #cities.for_force(f), ok and tostring(res) or "?",
      math.floor(treasury.balance(f) or 0), lines_open, #rails.lines_of(f), trains, units.count(f, "hauler"),
      units.count(f) - units.count(f, "hauler"), surface and count_names(surface, f, "rts-district-") or -1)
  end
  lib.log("status %s minute %.1f speed %.1f: %s", tag, (game.tick - (storage.match.tick_started or 0)) / 3600, game.speed,
    table.concat(parts, " | "))
end

---------------------------------------------------------------------------
-- Bake
---------------------------------------------------------------------------
if cfg.phase == "bake" then
  step(function(player, P)
    -- a fixed world: the arena seed is nauvis' seed + the match number (match.lua arena_seed)
    local nauvis = game.surfaces.nauvis
    local mgs = nauvis.map_gen_settings
    mgs.seed = cfg.seed or 4242
    nauvis.map_gen_settings = mgs
    local p = storage.lobby.pending
    p.mode, p.opponents, p.difficulty = "nation", cfg.nations - 1, cfg.difficulty or "normal"
    p.world_size, p.survey, p.victory, p.time_limit = cfg.world_size or 2048, true, "conquest_space", 0
    lib.no_objectives(player)
    lobby.show_lobby(player)
    lib.log("lobby: seed %d, %d nations, %d, survey", nauvis.map_gen_settings.seed, cfg.nations, p.world_size)
    gui_click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
    return 120
  end)
  lib.wait_until("match", function() return not match.in_lobby() and buildings.main_cc(F) ~= nil end, 30, 3600)
  step(function(player, P)
    P.home = buildings.main_cc(F).entity.position
    ai.set_doctrine(F, cfg.doctrine or "economic")
    local C = ai.init_force(F, cfg.ai_difficulty or "hard")
    lib.log("bake: capital %s, AI for %s: %s %s; seed %d", util.pos_str(P.home), F, C and C.difficulty or "-",
      C and C.doctrine or "-", match.surface().map_gen_settings.seed)
    lib.view(player, P.home, 0.5)
    game.speed = cfg.bake_speed or 20
    status("start")
    return 60
  end)
  step(function(player, P)
    local minute = (game.tick - (storage.match.tick_started or 0)) / 3600
    if minute >= (cfg.bake_minutes or 35) then return 1 end
    if (P.last_status or -1) < math.floor(minute) then
      P.last_status = math.floor(minute)
      status("bake")
      lib.view(player, P.home)
    end
    P.i = P.i - 1
    return 600
  end)
  step(function(player, P)
    game.speed = 1
    status("baked")
    game.auto_save("showcase-nation")
    lib.log("bake: auto-save showcase-nation requested at tick %d", game.tick)
    return 600
  end)
  step(function(player, P)
    util.log("SHOWCASE_BAKED nation tick %d", game.tick)
    return nil
  end)
  lib.start()
  return
end

---------------------------------------------------------------------------
-- Shoot (scenes)
---------------------------------------------------------------------------
require("scripts.showcase_nation_scenes")
lib.start()
