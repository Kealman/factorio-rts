-- 0.1.2 (issue #30): the help card. What an entity is, how it works, what it takes and makes, its ranges and needs, one
-- tip: the text comes from locale [rts-help] (scripts/help.lua), the numbers from balance.lua and the prototypes.
--
-- Three ways to open it:
--   * Shift over a building, unit or ghost (custom input rts-help-hover, consuming "none", so Shift+click selection and
--     Shift+right-click routes work as before). The engine reports only the press of a key, never its release, so the
--     card appears HOVER_DELAY ticks after the press unless a mouse click came first (a Shift+click is a click, not a
--     question). A hover card goes away with the next click, after CARD_SECONDS, or with the next Shift press that finds
--     nothing under the cursor.
--   * Shift+F11 or Shift+/ (custom input rts-help-card): the same card, for players whose Shift is taken.
--   * The "?" button of a building page and of the hub, city and depot panels (tags.rts_help = entity name): the card,
--     pinned, until its × is pressed. "Open in F11" opens the how-to-play window.
-- The card sits next to the cursor (hover) or at the top centre (pinned).
--
-- Owns storage.players[i].helpcard = {frame, name, pinned, shown = tick, press = {tick, name, pos, cancel}}.
-- Element names start with "rts_helpcard". QA log lines: "helpgui: card <entity> (hover|pinned|key) player=N".
local util = require("scripts.util")
local events = require("scripts.events")
local help = require("scripts.help")
local hud = require("scripts.hud")
local abilitygui = require("scripts.abilitygui")

local helpgui = {}

local FRAME = "rts_helpcard"
local PREFIX = "rts_helpcard_"
local WIDTH = 330            -- GUI units
local TEXT_WIDTH = WIDTH - 28
local HOVER_DELAY = 18       -- ticks between the Shift press and the card
local CARD_SECONDS = 20
local PICK_RADIUS = 1.6
local COLOR = {dim = {0.72, 0.72, 0.72}, yellow = {1, 0.85, 0.3}}

local function pstate(player_index)
  local p = util.pstorage(player_index)
  p.helpcard = p.helpcard or {}
  return p.helpcard
end

---------------------------------------------------------------------------
-- What is under the cursor
---------------------------------------------------------------------------
local function name_of(e)
  if not e.valid then return nil end
  if e.type == "entity-ghost" then return e.ghost_name end
  return e.name
end

local function inside(e, pos)
  local box = e.selection_box
  return pos.x >= box.left_top.x and pos.x <= box.right_bottom.x and pos.y >= box.left_top.y
    and pos.y <= box.right_bottom.y
end

--- The entity name with a help entry nearest to the map position (smallest selection box containing it), or nil.
--- Legs of walkers map to their body (the nearest spider of the leg's force).
function helpgui.name_at(surface, pos)
  local best, best_area, leg
  for _, e in pairs(surface.find_entities_filtered({position = pos, radius = PICK_RADIUS})) do
    if e.valid then
      if e.type == "spider-leg" then
        leg = leg or e
      elseif inside(e, pos) then
        local name = name_of(e)
        if name and help.family(name) then
          local box = e.selection_box
          local area = (box.right_bottom.x - box.left_top.x) * (box.right_bottom.y - box.left_top.y)
          if not best_area or area < best_area then best, best_area = name, area end
        end
      end
    end
  end
  if not best and leg then
    local nearest, nd
    for _, s in ipairs(surface.find_entities_filtered({position = leg.position, radius = 12, type = {"spider-unit",
        "spider-vehicle"}, force = leg.force})) do
      local d = util.distance_sq(s, leg)
      if not nd or d < nd then nearest, nd = s, d end
    end
    if nearest and help.family(nearest.name) then best = nearest.name end
  end
  return best
end

---------------------------------------------------------------------------
-- The card
---------------------------------------------------------------------------
local function destroy(g)
  if g.frame and g.frame.valid then g.frame.destroy() end
  g.frame, g.name, g.pinned, g.shown = nil, nil, nil, nil
end

local function bold(key) return {"", "[font=default-bold]", {key}, "[/font]"} end

local function text(parent, caption, style, tooltip)
  local l = parent.add({type = "label", style = style or "rts_hud_label", caption = caption, tooltip = tooltip})
  l.style.maximal_width = TEXT_WIDTH
  l.style.single_line = false
  return l
end

local function add_lines(frame, heading_key, lines)
  local any = false
  for _, line in ipairs(lines) do
    if line ~= "" then any = true end
  end
  if not any then return end
  local row = frame.add({type = "flow", direction = "vertical"})
  row.style.vertical_spacing = 0
  text(row, bold(heading_key))
  for _, line in ipairs(lines) do
    if line ~= "" then text(row, line) end
  end
end

local function place(player, frame, at)
  local s = player.display_scale
  local res = player.display_resolution
  local w = math.floor(WIDTH * s + 0.5)
  local x, y
  if at then
    x, y = at.x + math.floor(24 * s), at.y + math.floor(24 * s)
    if x + w > res.width - 4 then x = at.x - w - math.floor(12 * s) end
  else
    x, y = math.floor((res.width - w) / 2), math.floor(70 * s)
  end
  frame.location = {math.max(4, x), math.max(4, math.min(y, res.height - math.floor(300 * s)))}
end

--- Screen point (physical pixels) of a map position in the player's remote view.
local function screen_point(player, pos)
  local res = player.display_resolution
  local k = 32 * player.zoom
  return {x = math.floor(res.width / 2 + (pos.x - player.position.x) * k + 0.5),
          y = math.floor(res.height / 2 + (pos.y - player.position.y) * k + 0.5)}
end

function helpgui.close(player)
  destroy(pstate(player.index))
end

--- Open the card of `name` for the player. mode: "hover" | "key" | "pinned"; at = screen point for hover cards.
function helpgui.open(player, name, mode, at)
  local family = help.family(name)
  if not family then return false end
  local g = pstate(player.index)
  destroy(g)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.name, g.pinned, g.shown = frame, name, mode == "pinned" or mode == "key", game.tick
  local proto = prototypes.entity[name]
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local title = row.add({type = "label", style = "rts_hud_heading_label",
    caption = proto and proto.localised_name or name})
  title.style.maximal_width = WIDTH - 60
  row.add({type = "empty-widget", style = "rts_hud_filler"})
  row.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
           tooltip = {"rts-help.card-close"}, tags = {rts_helpcard = "close"}})
  text(frame, {"?", {"entity-description." .. name}, ""}, "rts_hud_dim_label")
  local f = help.facts(name)
  if family ~= "part" then
    local how = frame.add({type = "flow", direction = "vertical"})
    how.style.vertical_spacing = 0
    text(how, bold("rts-help.card-how"))
    text(how, {"rts-help." .. name .. "-how"})
  end
  for _, s in ipairs(f.stats) do text(frame, s) end
  add_lines(frame, "rts-help.card-takes", f.takes)
  add_lines(frame, "rts-help.card-makes", f.makes)
  add_lines(frame, "rts-help.card-ranges", f.ranges)
  add_lines(frame, "rts-help.card-needs", f.needs)
  local tip = frame.add({type = "flow", direction = "vertical"})
  tip.style.vertical_spacing = 0
  text(tip, bold("rts-help.card-tip"))
  text(tip, {"rts-help." .. name .. "-tip"})
  local foot = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local v = text(foot, {"rts-help.card-vanilla"}, "rts_hud_dim_label")
  v.style.maximal_width = WIDTH - 120
  foot.add({type = "empty-widget", style = "rts_hud_filler"})
  foot.add({type = "button", name = PREFIX .. "f11", style = "rts_hud_button", caption = {"rts-help.card-open-f11"},
            tags = {rts_helpcard = "f11"}})
  place(player, frame, mode == "hover" and at or nil)
  util.log("helpgui: card %s (%s) player=%d", name, mode, player.index)
  return true
end

--- 0.1.3 (#34): the card of the five abilities (the "?" of the ability bar): what each does, its hotkey, cooldown and
--- research, and how the bar reads. Pinned until its x is pressed.
function helpgui.open_abilities(player)
  local g = pstate(player.index)
  destroy(g)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.name, g.pinned, g.shown = frame, "*abilities*", true, game.tick
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  row.add({type = "label", style = "rts_hud_heading_label", caption = {"rts-help.abilities-card-title"}})
  row.add({type = "empty-widget", style = "rts_hud_filler"})
  row.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
           tooltip = {"rts-help.card-close"}, tags = {rts_helpcard = "close"}})
  text(frame, {"rts-help.abilities-card-intro"}, "rts_hud_dim_label")
  for _, a in ipairs(abilitygui.card_lines()) do
    local block = frame.add({type = "flow", direction = "vertical"})
    block.style.vertical_spacing = 0
    text(block, {"", "[font=default-bold]", a.title, "[/font]  ",
                 a.key and {"rts.ability-tooltip-hotkey", a.key} or {"rts.ability-tooltip-button-only"}, ", ",
                 {"rts.ability-tooltip-cooldown-total", a.cooldown}})
    text(block, a.description)
    if a.tech then text(block, {"rts.ability-tooltip-needs", {"technology-name." .. a.tech}}, "rts_hud_dim_label") end
  end
  local tip = frame.add({type = "flow", direction = "vertical"})
  tip.style.vertical_spacing = 0
  text(tip, bold("rts-help.card-tip"))
  text(tip, {"rts-help.abilities-card-hint"})
  place(player, frame, nil)
  util.log("helpgui: card *abilities* (pinned) player=%d", player.index)
end

---------------------------------------------------------------------------
-- Inputs
---------------------------------------------------------------------------
local function cursor_target(player, position)
  local surface = util.surface and util.surface() or player.surface
  if not (position and surface) then return nil end
  return helpgui.name_at(surface, position)
end

-- Shift pressed: remember what is under the cursor; the poll below shows the card when no click follows.
events.on("rts-help-hover", function(e)
  local player = game.get_player(e.player_index)
  if not (player and e.cursor_position) then return end
  local g = pstate(player.index)
  local name = cursor_target(player, e.cursor_position)
  util.log("helpgui: shift press at %s over %s player=%d", util.pos_str(e.cursor_position), tostring(name), player.index)
  if g.frame and g.frame.valid and not g.pinned and not name then
    destroy(g)
    return
  end
  g.press = name and {tick = game.tick, name = name, pos = e.cursor_position} or nil
end)

-- Shift+F11 / Shift+/: the same card at once, pinned
events.on("rts-help-card", function(e)
  local player = game.get_player(e.player_index)
  if not (player and e.cursor_position) then return end
  local name = cursor_target(player, e.cursor_position)
  if name then
    helpgui.open(player, name, "key")
  else
    helpgui.close(player)
  end
end)

local function on_click_input(e)
  local g = pstate(e.player_index)
  if g.press then g.press = nil end                       -- a Shift+click is a click, not a question
  if g.frame and g.frame.valid and not g.pinned then destroy(g) end
end
events.on("rts-lclick", on_click_input)
events.on("rts-rclick", on_click_input)

events.on_nth_tick(6, function()
  for _, player in pairs(game.connected_players) do
    local g = pstate(player.index)
    local press = g.press
    if press and game.tick - press.tick >= HOVER_DELAY then
      g.press = nil
      helpgui.open(player, press.name, "hover", screen_point(player, press.pos))
    elseif g.frame and g.frame.valid and not g.pinned and g.shown and game.tick - g.shown > CARD_SECONDS * 60 then
      destroy(g)
    end
  end
end)

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local player = game.get_player(e.player_index)
  local tags = el.tags
  if not (player and tags) then return end
  if tags.rts_helpcard == "close" then
    helpgui.close(player)
  elseif tags.rts_helpcard == "f11" then
    helpgui.close(player)
    hud.toggle_help(player, "helpcard")
  elseif tags.rts_help == "*abilities*" then
    local g = pstate(player.index)
    if g.frame and g.frame.valid and g.name == "*abilities*" then destroy(g) else helpgui.open_abilities(player) end
  elseif tags.rts_help then
    local g = pstate(player.index)
    if g.frame and g.frame.valid and g.name == tags.rts_help and g.pinned then
      destroy(g)
    else
      helpgui.open(player, tags.rts_help, "pinned")
    end
  end
end)

-- the headless check: every visible rts-* entity has a help entry (also after a mod update)
function helpgui.init() help.check() end -- control.lua runs every module's init on init and on configuration change

return helpgui
