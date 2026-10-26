-- 0.1.1 (issue #16): guided objectives for a player's first Skirmish and Nation match.
--
-- An objective strip at the top edge, between the match strip and the minimap (hud.top_gap): "Objectives 2/7", the
-- current step in bold with a hint under it, and on demand the whole list. Seven steps per mode tick off from game
-- events and are shown in order; the current step is the first one not done (a later step done early is ticked
-- already). A switch at the left of the lobby's button row ("Guided objectives") turns it on or off; until a player
-- touches it, it is on for that player's first match of each mode and off afterwards. The × hides the strip for the
-- rest of the match; the arrow shows or hides the list (remembered).
--
--   Skirmish: select units, an extractor, the barracks, a unit from it, a technology, a hub, an enemy destroyed.
--   Nation:   the city panel, food (a farm and a bakery, or a fishing hut), a house, a town, an open rail line,
--             Age II (the Railway Charter), a treaty or a war (any change of a diplomatic state of the nation, or a
--             contract).
--
-- Owns storage.objectives = {
--   players = {[player_index] = {pref = nil|true|false (the lobby switch; nil = auto), played = {skirmish = n,
--              nation = n} (matches started), match = match id the state belongs to, mode, on, done = {[step] = true},
--              expanded, finished = tick}},
--   forces = {[force] = {match = id, flags = {[step] = true}, seen = {[entity name] = true}}},  (event-driven steps)
--   active = {[force] = true}}  (forces with a player whose strip is on: the event handlers ignore the others)
-- Determinism: it only reads game state and writes its own storage and GUI; every decision comes from game events
-- (buildings, spawns, research, deaths, script signals) or from synchronised GUI state (the selection, an open city
-- panel), so every peer computes the same strip. Nothing else reads its storage, so Skirmish stays byte-identical.
-- QA log lines: "objectives: player N ... on|off", "objectives: player N step <id> done (k/7)".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local selection = require("scripts.selection")
local hud = require("scripts.hud")
local lobby = require("scripts.lobby")
local ages = require("scripts.ages")
local rails = require("scripts.rails")

local objectives = {}

objectives.FRAME = "rts_objectives"
local PREFIX = "rts_objectives_"
local POLL = 30                  -- ticks between the checks of the polled steps
local AUTO_CLOSE_TICKS = 45 * 60 -- the strip says "all done" this long, then goes
local MIN_WIDTH = 200            -- GUI units: a narrower gap puts the strip under the minimap instead
local FALLBACK_TOP = 8 + 228 + 8 + 36 -- GUI units: under the minimap frame and the world generation line

objectives.STEPS = {
  skirmish = {"select", "extractor", "barracks", "unit", "research", "hub", "attack"},
  nation = {"city", "food", "house", "town", "rail", "age2", "diplomacy"},
}
-- Buildings whose placement ticks a step (buildings.on_added); food needs a farm and a bakery, or a fishing hut
local BUILT = {
  ["rts-extractor"] = "extractor", ["rts-barracks"] = "barracks", ["rts-hub"] = "hub",
  ["rts-house"] = "house", ["rts-apartment"] = "house",
}
local FOOD = {["rts-farm"] = true, ["rts-bakery"] = true, ["rts-fishing-hut"] = true}

local function state()
  local S = storage.objectives
  if not S then
    S = {players = {}, forces = {}, active = {}}
    storage.objectives = S
  end
  return S
end

local function pstate(player_index)
  local S = state()
  local ps = S.players[player_index]
  if not ps then
    ps = {played = {}, done = {}}
    S.players[player_index] = ps
  end
  return ps
end

local function mode_of(config)
  return (config and config.mode == "nation") and "nation" or "skirmish"
end

--- On or off for `player`'s next match of `mode`: the lobby switch once touched, else only the first match of the mode.
function objectives.wanted(player_index, mode)
  local ps = pstate(player_index)
  if ps.pref ~= nil then return ps.pref end
  return (ps.played[mode] or 0) == 0
end

local function fstate(force_name)
  local S = state()
  local m = storage.match
  local fs = S.forces[force_name]
  if not fs or fs.match ~= (m and m.match_id) then
    fs = {match = m and m.match_id, flags = {}, seen = {}}
    S.forces[force_name] = fs
  end
  return fs
end

local function flag(force_name, step)
  if not state().active[force_name] then return end
  local m = storage.match
  if not (m and m.phase == "running" and not m.placing) then return end
  fstate(force_name).flags[step] = true
end

---------------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------------
local SPRITE_OK = {}
local function sprite(path, fallback)
  if SPRITE_OK[path] == nil then SPRITE_OK[path] = helpers.is_valid_sprite_path(path) end
  return SPRITE_OK[path] and ("[img=" .. path .. "]") or fallback
end

local function destroy(player)
  local f = player.gui.screen[objectives.FRAME]
  if f then f.destroy() end
end

local function count_done(ps)
  local n = 0
  for _, id in ipairs(objectives.STEPS[ps.mode] or {}) do if ps.done[id] then n = n + 1 end end
  return n
end

local function current_step(ps)
  for _, id in ipairs(objectives.STEPS[ps.mode] or {}) do
    if not ps.done[id] then return id end
  end
  return nil
end

local function place(player, frame)
  local s = player.display_scale
  local x, w, m = hud.top_gap(player)
  local width = math.floor(w / s)
  if width >= MIN_WIDTH then
    frame.location = {x, m}
    frame.style.width = math.min(width, 360)
  else -- a narrow window: under the minimap on the right
    width = 228
    frame.location = {player.display_resolution.width - math.floor((width + 8) * s + 0.5), math.floor(FALLBACK_TOP * s)}
    frame.style.width = width
  end
  return math.min(width, 360)
end

local function render(player)
  local ps = pstate(player.index)
  destroy(player)
  if not (ps.on and ps.mode) then return end
  local steps = objectives.STEPS[ps.mode]
  local frame = player.gui.screen.add({type = "frame", name = objectives.FRAME, style = "rts_hud_frame",
                                       direction = "vertical"})
  local width = place(player, frame)
  local text_w = width - 16
  local head = frame.add({type = "flow", direction = "horizontal"})
  head.style.vertical_align = "center"
  local n = count_done(ps)
  local title = head.add({type = "label", style = "rts_hud_heading_label",
                          caption = {"rts-objectives.title", n, #steps}})
  title.tooltip = {"rts-objectives.title-tooltip"}
  local fill = head.add({type = "empty-widget", style = "rts_hud_filler"})
  fill.style.horizontally_stretchable = true
  head.add({type = "sprite-button", name = PREFIX .. "list", style = "frame_action_button",
            sprite = ps.expanded and "utility/collapse" or "utility/expand",
            tooltip = {ps.expanded and "rts-objectives.list-hide" or "rts-objectives.list-show"},
            tags = {rts_objectives = "list"}})
  head.add({type = "sprite-button", name = PREFIX .. "close", style = "frame_action_button", sprite = "utility/close",
            tooltip = {"rts-objectives.close-tooltip"}, tags = {rts_objectives = "close"}})
  local cur = current_step(ps)
  local key = cur and ("rts-objectives." .. ps.mode .. "-" .. cur) or ("rts-objectives." .. ps.mode .. "-done")
  local step_l = frame.add({type = "label", name = PREFIX .. "step", style = "rts_hud_message_label", caption = {key}})
  step_l.style.single_line = false
  step_l.style.maximal_width = text_w
  local hint = frame.add({type = "label", name = PREFIX .. "hint", style = "rts_hud_dim_label", caption = {key .. "-hint"}})
  hint.style.single_line = false
  hint.style.maximal_width = text_w
  if ps.expanded then
    local list = frame.add({type = "flow", name = PREFIX .. "steps", direction = "vertical"})
    list.style.vertical_spacing = 0
    list.style.top_margin = 2
    for i, id in ipairs(steps) do
      local mark = ps.done[id] and sprite("utility/check_mark_green", "+") or (id == cur and "›" or "·")
      local l = list.add({type = "label", style = ps.done[id] and "rts_hud_small_label" or "rts_hud_dim_label",
                          caption = {"", mark, " ", i, ". ", {"rts-objectives." .. ps.mode .. "-" .. id .. "-short"}}})
      l.style.maximal_width = text_w
      if ps.done[id] then l.style.font_color = {0.55, 0.95, 0.55}
      elseif id == cur then l.style.font_color = {1, 0.85, 0.3} end
    end
  end
end

--- Rebuild every connected player's strip (the HUD layout changed, e.g. the display resolution).
local function render_all()
  for _, player in pairs(game.connected_players) do render(player) end
end
objectives.render = render

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------
local function mark(player, ps, id)
  if ps.done[id] then return false end
  ps.done[id] = true
  util.log("objectives: player %d step %s done (%d/%d, %s)", player.index, id, count_done(ps),
    #objectives.STEPS[ps.mode], ps.mode)
  return true
end

-- The polled steps (selection, the open city panel, rail lines, the age) and the force's event flags.
local function check(player, ps)
  local F = player.force.name
  local fs = fstate(F)
  local changed = false
  local mine = {} -- 0.1.2 (#19): only this mode's steps are marked (the other mode's flags made log noise)
  for _, id in ipairs(objectives.STEPS[ps.mode] or {}) do mine[id] = true end
  for id in pairs(fs.flags) do
    if mine[id] and mark(player, ps, id) then changed = true end
  end
  if ps.mode == "skirmish" then
    if not ps.done.select and selection.count(player.index) > 0 and mark(player, ps, "select") then changed = true end
  else
    if not ps.done.city and player.gui.screen.rts_citygui_frame and mark(player, ps, "city") then changed = true end
    if not ps.done.rail then
      for _, line in ipairs(rails.lines_of(F)) do
        if line.state == "open" then
          if mark(player, ps, "rail") then changed = true end
          break
        end
      end
    end
    if not ps.done.age2 and ages.of(F) >= 2 and mark(player, ps, "age2") then changed = true end
  end
  if changed and not current_step(ps) and not ps.finished then
    ps.finished = game.tick
    util.log("objectives: player %d finished the %s objectives at %.0fs", player.index, ps.mode,
      match.elapsed_seconds())
  end
  return changed
end

local function refresh_active()
  local S = state()
  S.active = {}
  for _, player in pairs(game.connected_players) do
    local ps = S.players[player.index]
    if ps and ps.on then S.active[player.force.name] = true end
  end
end

-- A new match for the player: on or off by objectives.wanted, the steps cleared, the match counted.
local function start_for(player)
  local m = storage.match
  local ps = pstate(player.index)
  local mode = mode_of(m.config)
  ps.on = objectives.wanted(player.index, mode)
  ps.played[mode] = (ps.played[mode] or 0) + 1
  ps.match, ps.mode, ps.done, ps.finished = m.match_id, mode, {}, nil
  util.log("objectives: player %d match %d (%s, number %d of the mode): %s%s", player.index, m.match_id, mode,
    ps.played[mode], ps.on and "on" or "off", ps.pref == nil and " (auto)" or " (lobby switch)")
  refresh_active()
  if ps.on then check(player, ps) end
  render(player)
end

events.on_nth_tick(POLL, function(e)
  local m = storage.match
  if not (m and m.phase == "running" and m.match_id) then return end
  for _, player in pairs(game.connected_players) do
    local ps = pstate(player.index)
    if ps.match ~= m.match_id then
      start_for(player)
    elseif ps.on then
      if ps.finished and e.tick - ps.finished >= AUTO_CLOSE_TICKS then
        ps.on = false
        util.log("objectives: player %d strip closed after the last step", player.index)
        refresh_active()
        destroy(player)
      elseif not ps.finished and check(player, ps) then
        render(player)
      end
    end
  end
end)

buildings.on_added(function(_, rec)
  local step = BUILT[rec.entity.name]
  if step then flag(rec.force, step) end
  if FOOD[rec.entity.name] and state().active[rec.force] then
    local fs = fstate(rec.force)
    fs.seen[rec.entity.name] = true
    if fs.seen["rts-fishing-hut"] or (fs.seen["rts-farm"] and fs.seen["rts-bakery"]) then flag(rec.force, "food") end
  end
end)

production.on_spawned(function(_, rec) flag(rec.force, "unit") end)

events.on(defines.events.on_research_finished, function(e)
  local force = e.research and e.research.force
  if force then flag(force.name, "research") end
end)

-- An enemy unit or building destroyed by the player's force (Skirmish "attack"). The registries may already have
-- dropped the entity (their handlers run first), so the entity's type and its force's place in the match decide.
local UNIT_TYPES = {["spider-unit"] = true, unit = true, ["spider-vehicle"] = true}
events.on(defines.events.on_entity_died, function(e)
  local killer = e.force
  if not (killer and state().active[killer.name]) then return end
  local ent = e.entity
  if not (ent and ent.valid) or ent.force == killer or not match.is_participant(ent.force.name) then return end
  if not (UNIT_TYPES[ent.type] or buildings.kind_of(ent.name)) then return end
  flag(killer.name, "attack")
end)

events.on_signal("rts_city_founded", function(d)
  local c = storage.cities and storage.cities[d.city]
  if c and not c.capital then flag(c.force, "town") end
end)

events.on_signal("rts_diplomacy_changed", function(d)
  if d.old == nil or d.old == d.state then return end
  flag(d.a, "diplomacy")
  flag(d.b, "diplomacy")
end)

events.on_signal("rts_contract_event", function(ev)
  if ev.kind ~= "created" then return end
  if ev.seller then flag(ev.seller, "diplomacy") end
  if ev.buyer then flag(ev.buyer, "diplomacy") end
end)

match.on_teardown(function()
  for _, player in pairs(game.connected_players) do destroy(player) end
  state().active = {}
end)

---------------------------------------------------------------------------
-- The lobby switch and the strip's buttons
---------------------------------------------------------------------------
lobby.on_dialog(function(player, row, pending)
  local mode = pending.mode == "nation" and "nation" or "skirmish"
  local on = objectives.wanted(player.index, mode)
  local cb = row.add({type = "checkbox", name = PREFIX .. "lobby", state = on, caption = {"rts-objectives.lobby-toggle"},
                      tooltip = {"rts-objectives.lobby-toggle-tooltip"}, tags = {rts_objectives = "lobby"}})
  cb.style.left_margin = 4
  cb.style.top_margin = 6
end)

events.on(defines.events.on_gui_checked_state_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.name == PREFIX .. "lobby") then return end
  local ps = pstate(e.player_index)
  ps.pref = el.state
  util.log("objectives: player %d lobby switch %s", e.player_index, el.state and "on" or "off")
end)

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local action = el.tags and el.tags.rts_objectives
  local player = game.get_player(e.player_index)
  local ps = pstate(e.player_index)
  if action == "close" then
    ps.on = false
    util.log("objectives: player %d closed the strip (until the next match)", e.player_index)
    refresh_active()
    destroy(player)
  elseif action == "list" then
    ps.expanded = not ps.expanded
    util.log("objectives: player %d list %s", e.player_index, ps.expanded and "shown" or "hidden")
    render(player)
  end
end)

events.on(defines.events.on_player_display_resolution_changed, function(e)
  local player = game.get_player(e.player_index)
  if player and player.gui.screen[objectives.FRAME] then render(player) end
end)
events.on(defines.events.on_player_display_scale_changed, function(e)
  local player = game.get_player(e.player_index)
  if player and player.gui.screen[objectives.FRAME] then render(player) end
end)

--- Set a player's lobby switch from script (tests and the showcase: set_pref(i, false) before a match keeps the strip
--- off; nil = auto). Hides a running strip when switched off.
function objectives.set_pref(player_index, value)
  local ps = pstate(player_index)
  ps.pref = value
  local player = game.get_player(player_index)
  if value == false and ps.on and player then
    ps.on = false
    refresh_active()
    destroy(player)
  end
end

function objectives.init()
  state()
  render_all()
end

return objectives
