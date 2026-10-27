-- Release 0.1.3 r4-hud Skirmish GUI probe (#35 two-row factory page with the long-handed inserter, #38 strip defaults of
-- Skirmish and a 12-entry strip at 1280x800), EN and RU (RTS_LOCALE=ru). Log lines "[rts] r4 sk <check>: PASS|FAIL ..."
-- and the stop marker RTS_R4_SK_GUI_DONE. Test copy, one GUI slot:
--   bash <scratchpad>/r4-hud/run-gui.sh en r4_hud_skirmish_gui RTS_R4_SK_GUI_DONE 200
-- Screenshots land in build/shots-r4hud-<lang>/.
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local economy = require("scripts.economy")
local hud = require("scripts.hud")
local stripgui = require("scripts.stripgui")

local function check(name, ok, fmt, ...)
  util.log("r4 sk %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local pending_shot
local function shot(tag) pending_shot = {tag = tag, tick = game.tick + 40} end
local function take_shot(player, tag)
  hud.refresh(player.index)
  game.take_screenshot({player = player, by_player = player, path = "rts-r4hud-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}})
end

local function count_recipes(player)
  local root = find(player.gui.screen, "rts_hud_panel")
  local names = {}
  local function walk(el)
    for _, c in pairs(el.children) do
      if c.type == "sprite-button" and c.tags and c.tags.rts_hud == "recipe" and c.tags.recipe ~= ""
        and not c.tags.recipe:find("^%*") then names[#names + 1] = c.tags.recipe end
      walk(c)
    end
  end
  if root then walk(root) end
  return names
end

local S = {step = 0}
local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(s, player)
  lobby.start_match({opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}, "r4 sk probe")
  s.wait = 240
  return true
end)

step(function(s, player)
  local F = player.force.name
  ai.stop_force(F)
  ai.stop_force(util.ENEMY_FORCE)
  storage.match.waves_off, storage.match.enemy_next_wave = true, nil
  local home, surface = match.home(F), match.surface()
  for _, item in ipairs({"iron-plate", "copper-plate", "stone-brick", "steel-plate", "coal", "stone"}) do
    economy.give(F, item, 4000)
  end
  local pos = surface.find_non_colliding_position("rts-factory", {x = home.x - 12.5, y = home.y - 10.5}, 12, 1, true)
  s.factory = surface.create_entity({name = "rts-factory", position = pos, force = F, raise_built = true})
  selection.select_building(player.index, s.factory.unit_number)
  s.wait = 90
  return true
end)

step(function(s, player)
  local names = count_recipes(player)
  local has = false
  for _, n in ipairs(names) do if n == "long-handed-inserter" then has = true end end
  check("factory_rows", #names <= 28, "%d recipes (two rows of 14 hold 28), long-handed inserter present=%s (Nation only, #25)",
    #names, tostring(has))
  shot("s1-skirmish-factory")
  s.wait = 60
  return true
end)

step(function(s, player)
  local keys = stripgui.keys(player.index, false)
  check("strip_default_skirmish", keys[1] == "timer" and keys[2] == "army" and keys[3] == "supply" and #keys == 9,
    "keys %s", table.concat(keys, ","))
  shot("s2-skirmish-strip")
  -- 12 entries: everything the chooser offers, to see that 1280x800 / 0.75 still fits
  local more = {"supply", "bots", "item:steel-plate", "item:stone-brick", "item:electronic-circuit"}
  for _, k in ipairs(more) do
    local have = false
    for _, e in ipairs(keys) do if e == k then have = true end end
    if not have and #keys < stripgui.MAX_KEYS then keys[#keys + 1] = k end
  end
  stripgui.set(player.index, false, keys)
  s.wait = 60
  return true
end)

step(function(s, player)
  shot("s3-skirmish-strip-full")
  s.wait = 60
  return true
end)

step(function(s, player)
  stripgui.set(player.index, false, nil)
  util.log("RTS_R4_SK_GUI_DONE")
  return true
end)

events.on_nth_tick(30, function()
  local player = game.connected_players[1]
  if not player or S.done then return end
  if pending_shot and game.tick >= pending_shot.tick then
    take_shot(player, pending_shot.tag)
    pending_shot = nil
  end
  S.at = S.at or game.tick + 180
  if game.tick < S.at then return end
  local fn = STEPS[S.step + 1]
  if not fn then
    S.done = true
    return
  end
  S.wait = 0
  if fn(S, player) then
    S.step = S.step + 1
    S.at = game.tick + (S.wait or 0)
  end
end)
