-- Release 0.1.3 r4-hud (#34) GUI probe: the help card of a selected unit type (the "?" of the unit page) and the card of
-- the five abilities (the "?" of the ability bar), EN and RU. Skirmish match, AIs stopped. Log lines
-- "[rts] r4 cards <check>: PASS|FAIL ..." and the stop marker RTS_R4_CARDS_DONE. Run:
--   bash <scratchpad>/r4-hud/run-gui.sh en r4_hud_cards_gui RTS_R4_CARDS_DONE 200
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local hud = require("scripts.hud")

local function check(name, ok, fmt, ...)
  util.log("r4 cards %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function click(player, name)
  local el = find(player.gui.screen, name)
  if not el then
    util.log("r4 cards: button %s missing", name)
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
  return true
end

local pending_shot
local function shot(tag) pending_shot = {tag = tag, tick = game.tick + 40} end
local function take_shot(player, tag)
  hud.refresh(player.index)
  game.take_screenshot({player = player, by_player = player, path = "rts-r4hud-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}})
end

local S = {step = 0}
local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(s, player)
  lobby.start_match({opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai"}, "r4 cards probe")
  s.wait = 240
  return true
end)

step(function(s, player)
  ai.stop_force(player.force.name)
  ai.stop_force(util.ENEMY_FORCE)
  storage.match.waves_off, storage.match.enemy_next_wave = true, nil
  local walkers = player.surface.find_entities_filtered({name = "rts-walker", force = player.force, limit = 8})
  selection.set(player.index, walkers)
  s.wait = 60
  return true
end)

step(function(s, player)
  local b = find(player.gui.screen, "rts_hud_help_card_unit")
  check("unit_help_button", b ~= nil and b.visible, "unit page ? visible=%s tag=%s", tostring(b and b.visible),
    tostring(b and b.tags and b.tags.rts_help))
  click(player, "rts_hud_help_card_unit")
  s.wait = 30
  return true
end)

step(function(s, player)
  check("unit_card", find(player.gui.screen, "rts_helpcard") ~= nil, "unit help card open")
  shot("c1-unit-card")
  s.wait = 150
  return true
end)

step(function(s, player)
  click(player, "rts_helpcard_close")
  click(player, "rts_ability_help")
  s.wait = 30
  return true
end)

step(function(s, player)
  check("abilities_card", find(player.gui.screen, "rts_helpcard") ~= nil, "abilities help card open")
  shot("c2-abilities-card")
  s.wait = 60
  return true
end)

step(function(s, player)
  util.log("RTS_R4_CARDS_DONE")
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
