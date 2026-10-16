-- Phase 5 M2 diplomacy GUI probe (tools/gui-run.sh): drives the F4 panel and the offers through their click paths in a
-- real client and takes screenshots. A Nation 1v2 starts by script; then: the lobby's Victory / Time limit rows (dialog
-- screenshot first), F4 (hud.lua's key table), War on rts-ai-1 (goal: nearest city), a ceasefire proposal (the AI answers
-- in 10-20 s), an AI's alliance proposal to the player (offers under the alert lines, Accept), the results window after a
-- Score victory. Log "[rts] dpgui ...", marker "DPGUI done", screenshots dpgui-*.png.
local events = require("scripts.events")
local util = require("scripts.util")
local match = require("scripts.match")
local diplomacy = require("scripts.diplomacy")
local wars = require("scripts.wars")
local lobby = require("scripts.lobby")
local diplomacygui = require("scripts.diplomacygui")

local function shot(player, name)
  game.take_screenshot({player = player, by_player = player, path = "dpgui-" .. name .. ".png", show_gui = true,
                        resolution = {1280, 800}})
  util.log("dpgui: screenshot %s", name)
end

local function click(player, name)
  local function find(el)
    if el.name == name then return el end
    for _, c in pairs(el.children) do
      local f = find(c)
      if f then return f end
    end
  end
  local el = find(player.gui.screen)
  if not el then
    util.log("dpgui: element %s not found", name)
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index, button = defines.mouse_button_type.left,
    alt = false, control = false, shift = false, name = defines.events.on_gui_click, tick = game.tick})
  util.log("dpgui: clicked %s (enabled %s)", name, tostring(el.valid and el.enabled))
  return true
end

-- Steps run one per 30-tick pass when due (a screenshot renders at the end of its tick, so nothing in the same pass may
-- change the GUI after it). `at` = game tick (lobby) or seconds of match time.
local STEPS = {
  {tick = 120, run = function(player)
    local p = storage.lobby.pending
    p.mode, p.opponents, p.victory, p.time_limit = "nation", 2, "territory", 90
    lobby.show_lobby(player)
  end},
  {tick = 180, run = function(player) shot(player, "lobby") end},
  {tick = 240, run = function(player)
    lobby.start_match({opponents = 2, difficulty = "normal", mode = "nation", world_size = 1536, enemy_brain = "ai",
                       victory = "score", time_limit = 60}, "dpgui")
  end},
  {at = 8, run = function(player)
    events.dispatch("rts-diplomacy", {player_index = player.index, name = "rts-diplomacy", tick = game.tick})
    util.log("dpgui: panel open after F4: %s", tostring(diplomacygui.is_open(player)))
  end},
  {at = 9, run = function(player) shot(player, "panel-peace") end},
  {at = 10, run = function(player) click(player, "rts_diplo_war_rts-ai-1") end},
  {at = 11, run = function(player)
    util.log("dpgui: after War: state %s, wars %s", diplomacy.state("rts-player", "rts-ai-1"),
      serpent.line(wars.active("rts-player")))
    click(player, "rts_diplo_ceasefire_rts-ai-1")
  end},
  {at = 12, run = function(player)
    wars.declare("rts-ai-2", "rts-ai-1", {kind = "conquest"})
    local id, why = diplomacy.propose("rts-ai-2", "rts-player", "alliance", {})
    storage.dpgui.offer = id
    util.log("dpgui: rts-ai-2 proposes an alliance: %s %s", tostring(id), tostring(why))
  end},
  {at = 14, run = function(player) shot(player, "offers") end},
  {at = 15, run = function(player) click(player, "rts_diplo_accept_o" .. tostring(storage.dpgui.offer)) end},
  {at = 34, run = function(player)
    local P = diplomacy.get_proposal(storage.dpgui.offer)
    util.log("dpgui: alliance offer %s, state with rts-ai-2 %s, with rts-ai-1 %s", P and P.status or "missing",
      diplomacy.state("rts-player", "rts-ai-2"), diplomacy.state("rts-player", "rts-ai-1"))
    diplomacygui.refresh(player)
    shot(player, "panel-answers")
  end},
  {at = 36, run = function(player)
    local m = storage.match
    -- the player's alliance leads the score: a shared Score victory at the time limit
    storage.dpgui.bonus = true
    m.tick_started = game.tick - 3600 * 60 - 60
  end},
  {at = 3600 + 80, run = function(player)
    local m = storage.match
    util.log("dpgui: match %s, victory %s, result %s", m.phase, serpent.line(m.victory), tostring(match.result("rts-player")))
    shot(player, "results")
  end},
  {at = 3600 + 82, run = function() log("[rts] DPGUI done") end},
}

-- the player's alliance gets a higher score than the rest (so the Score victory has winners)
do
  local real = wars.nation_score
  wars.nation_score = function(f)
    local n, parts = real(f)
    if storage.dpgui and storage.dpgui.bonus and (f == "rts-player" or f == "rts-ai-2") then n = n + 100 end
    return n, parts
  end
end

events.on_nth_tick(30, function(e)
  local player = game.get_player(1)
  if not player then return end
  local s = storage.dpgui or {step = 0}
  storage.dpgui = s
  local step = STEPS[s.step + 1]
  if not step then return end
  local m = storage.match
  local age = m and m.tick_started and m.phase ~= "lobby" and (e.tick - m.tick_started) / 60 or nil
  if (step.tick and e.tick >= step.tick) or (step.at and age and age >= step.at) then
    s.step = s.step + 1
    step.run(player)
  end
end)
