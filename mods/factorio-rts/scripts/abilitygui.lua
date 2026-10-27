-- Ability bar (docs/PHASE4.md section 7 "ability buttons with cooldowns"): a `screen` frame at the bottom centre, shown
-- to the players of a running match only (the HUD leaves x 400-880, y 700-800 free at 1280x800).
--
--   [Commander icon] Commander - Lv 2     [Stim] [Shield] [Scan] [Artillery] [Overcharge]
--                    ======== health        ===     ===     ===     ===         ===   cooldown bars
--                    Kills 7 / 15            Z       C       V       G          -     hotkey, or "12 s" while cooling
--
-- The card: the Commander's level, health bar and kills (or "Down: back in N s", or the armed ability's right-click
-- hint). A click on its icon selects the Commander, a second click jumps the camera to it (commander.select).
-- Ability buttons: a click is the hotkey (abilities.activate). Greyed (disabled) while unavailable: no research, nothing
-- selected for Stim, no Commander for Shield, no artillery walker, on cooldown. The armed targeted ability's button is
-- green. The tooltip names the ability, its hotkey, what it does and why it is unavailable.
-- Placement: centred between the HUD's selection panel (left) and build menu (right), bottom aligned. When the full bar
-- does not fit between them (UI scale 1.0 on a 1280-wide window), the compact layout drops the card's text column: the
-- icon then carries the level as its number and the rest in its tooltip.
-- Refresh: every REFRESH ticks for connected players, and at once when an ability is armed or used. Every element is
-- looked up and checked before use; anything missing or invalid makes the bar rebuild itself instead of raising.
-- Element names start with "rts_ability_"; clicks carry tags.rts_ability = ability name or "commander".
-- Owns no storage: the frame is rebuilt from abilities.lua / commander.lua state.
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local abilities = require("scripts.abilities")
local commander = require("scripts.commander")

local abilitygui = {}

abilitygui.FRAME = "rts_ability_bar"
local PREFIX = "rts_ability_"
-- GUI units (x player.display_scale on screen). Full: 359x65 px at 0.75. Compact (no card text): 320 wide.
-- 0.1.3 (#34): +30 for the "?" column (the help card of the five abilities)
local WIDTH, COMPACT_WIDTH, HEIGHT = 508, 350, 86
local MARGIN = 8               -- GUI units above the bottom edge
local INFO_WIDTH = 150         -- card text column; the health bar has the same width
local REFRESH = 15
-- Space the HUD (scripts/hud.lua) uses at the bottom corners, in GUI units: its MARGIN (8) + PANEL_WIDTH (520) + a gap
-- on the left, and MARGIN + BUILD_WIDTH (308) + a gap on the right.
local HUD_LEFT = 8 + 520 + 8
local HUD_RIGHT = 8 + 308 + 8

local TEXT = {  -- short button captions are icons; the tooltip names them
  stim = {"rts.ability-stim"}, shield = {"rts.ability-shield"}, scanner = {"rts.ability-scanner"},
  artillery = {"rts.ability-artillery"}, overcharge = {"rts.ability-overcharge"},
}

local function px(units, s) return math.floor(units * s + 0.5) end

local function sprite_or(path, fallback)
  if helpers.is_valid_sprite_path(path) then return path end
  return fallback
end

local function wanted(player)
  local m = storage.match
  return player.connected and m ~= nil and m.surface ~= nil and m.phase == "running"
    and match.is_participant(player.force.name)
end

--- Layout for a player's screen: mode ("full" | "compact"), x, y, width in pixels.
local function layout(player)
  local res, s = player.display_resolution, player.display_scale
  local lo, hi = px(HUD_LEFT, s), res.width - px(HUD_RIGHT, s)
  local mode = px(WIDTH, s) <= hi - lo and "full" or "compact"
  local w = px(mode == "full" and WIDTH or COMPACT_WIDTH, s)
  local x = math.floor((res.width - w) / 2 + 0.5)
  x = math.max(0, math.max(lo, math.min(x, hi - w)))
  return mode, x, res.height - px(HEIGHT, s) - px(MARGIN, s), w
end
abilitygui.layout = layout

local function description(name)
  local d = abilities.DEF[name]
  if name == "stim" then return {"rts.ability-stim-desc", d.cost, math.floor(d.heal * 100 + 0.5)} end
  if name == "shield" then return {"rts.ability-shield-desc", d.radius, d.duration / 60} end
  if name == "scanner" then return {"rts.ability-scanner-desc", d.size, d.duration / 60} end
  if name == "artillery" then return {"rts.ability-artillery-desc", d.range, d.shells} end
  if name == "overcharge" then return {"rts.ability-overcharge-desc", d.duration / 60, d.drain / 1e6} end
  return ""
end

local function valid(el) return el ~= nil and el.valid end

--- 0.1.3 (#34): what the help card prints per ability: {name, title, hotkey, cooldown seconds, description, tech}.
function abilitygui.card_lines()
  local out = {}
  for _, name in ipairs(abilities.LIST) do
    local def = abilities.DEF[name]
    out[#out + 1] = {name = name, title = TEXT[name], key = def.key, cooldown = def.cooldown / 60,
                     description = description(name), tech = def.tech}
  end
  return out
end

-- The bar's elements as a flat table, or nil when anything is missing or invalid (or the layout changed): the caller
-- rebuilds then.
local function collect(frame, mode)
  if not valid(frame) then return nil end
  local tags = frame.tags
  if not (tags and tags.rts_ability_layout == mode) then return nil end
  local card, row = frame.card, frame.buttons
  if not (valid(card) and valid(row)) then return nil end
  local parts = {mode = mode, icon = card[PREFIX .. "commander"], cols = {}}
  if not valid(parts.icon) then return nil end
  if mode == "full" then
    local info = card.info
    if not valid(info) then return nil end
    parts.title, parts.hp, parts.line = info.title, info.hp, info.line
    if not (valid(parts.title) and valid(parts.hp) and valid(parts.line)) then return nil end
  end
  for _, name in ipairs(abilities.LIST) do
    local col = row[name]
    if not valid(col) then return nil end
    local c = {button = col[PREFIX .. name], bar = col.bar, key = col.key}
    if not (valid(c.button) and valid(c.bar) and valid(c.key)) then return nil end
    parts.cols[name] = c
  end
  return parts
end

local function build(player, screen, mode)
  local old = screen[abilitygui.FRAME]
  if old and old.valid then old.destroy() end
  local _, x, y, w = layout(player)
  local frame = screen.add({type = "frame", name = abilitygui.FRAME, style = "rts_hud_frame", direction = "horizontal",
                            tags = {rts_ability_layout = mode}})
  frame.style.width = mode == "full" and WIDTH or COMPACT_WIDTH
  frame.style.height = HEIGHT -- rts_hud_frame's horizontal flow style puts 8 between the card and the buttons

  local card = frame.add({type = "flow", name = "card", direction = "horizontal"})
  card.style.vertical_align = "center"
  card.style.horizontal_spacing = 6
  card.add({type = "sprite-button", name = PREFIX .. "commander", style = "rts_ability_button",
            sprite = sprite_or("entity/rts-commander", "item/spidertron"), tags = {rts_ability = "commander"}})
  if mode == "full" then
    local info = card.add({type = "flow", name = "info", direction = "vertical"})
    info.style.vertical_spacing = 2
    info.style.width = INFO_WIDTH
    local title = info.add({type = "label", name = "title", style = "rts_hud_heading_label", caption = ""})
    title.style.maximal_width = INFO_WIDTH
    local hp = info.add({type = "progressbar", name = "hp", style = "rts_ability_hp_bar", value = 1})
    hp.style.width = INFO_WIDTH
    local line = info.add({type = "label", name = "line", style = "rts_hud_dim_label", caption = ""})
    line.style.maximal_width = INFO_WIDTH
  end

  local row = frame.add({type = "flow", name = "buttons", direction = "horizontal"})
  row.style.horizontal_spacing = 6
  for _, name in ipairs(abilities.LIST) do
    local def = abilities.DEF[name]
    local col = row.add({type = "flow", name = name, direction = "vertical"})
    col.style.vertical_spacing = 2
    col.add({type = "sprite-button", name = PREFIX .. name, style = "rts_ability_button",
             sprite = sprite_or(def.sprite, "utility/questionmark"), tags = {rts_ability = name}})
    col.add({type = "progressbar", name = "bar", style = "rts_ability_cooldown_bar", value = 1})
    col.add({type = "label", name = "key", style = "rts_ability_key_label", caption = def.key or "–"})
  end
  -- 0.1.3 (#34): "?" opens the card that explains the five abilities (scripts/helpgui.lua, tags.rts_help = "*abilities*")
  local help = frame.add({type = "flow", name = "help", direction = "vertical"})
  help.style.vertical_align = "center"
  help.style.height = HEIGHT - 16
  local hb = help.add({type = "button", name = PREFIX .. "help", style = "rts_hud_button", caption = "?",
                       tooltip = {"rts-help.abilities-card-tooltip"}, tags = {rts_help = "*abilities*"}})
  hb.style.height = 24
  hb.style.minimal_width = 24
  hb.style.padding = 0
  frame.location = {x, y}
  util.log("abilitygui: built for player %d (%s) at (%d, %d), %dx%d px (display %dx%d, scale %.2f)", player.index, mode,
    x, y, w, px(HEIGHT, player.display_scale), player.display_resolution.width, player.display_resolution.height,
    player.display_scale)
  return frame
end

local function refresh_card(player, parts)
  local icon = parts.icon
  local c = commander.card(player.force.name)
  local armed = abilities.armed(player.index)
  local title, value, line, tip
  if not c then
    title, value, line, tip = {"rts.commander-card-title", 1}, 0, {"rts.commander-none"}, {"rts.commander-none"}
    icon.enabled = false
  else
    title = {"rts.commander-card-title", c.level}
    icon.enabled = c.alive
    if not c.alive then
      value = 0
      line = c.waiting and {"rts.commander-waiting"} or {"rts.commander-respawn", c.respawn_in or 0}
      tip = line
    else
      value = c.max_health > 0 and c.health / c.max_health or 0
      line = c.next_kills and {"rts.commander-kills", c.kills, c.next_kills} or {"rts.commander-kills-max", c.kills}
      tip = {"rts.commander-card-tooltip", math.floor(c.health + 0.5), math.floor(c.max_health + 0.5),
             math.floor(c.shield + 0.5), math.floor(c.max_shield + 0.5), c.kills}
    end
  end
  if armed then line = {"rts.ability-armed-hint", TEXT[armed]} end
  if parts.mode == "full" then
    parts.title.caption = title
    parts.hp.value = value
    parts.line.caption = line
    parts.line.style.font_color = armed and {1, 0.85, 0.3} or {0.72, 0.72, 0.72}
    icon.tooltip = tip
  else
    -- compact: the level is the icon's number, everything else is in its tooltip
    icon.number = c and c.level or nil
    icon.tooltip = {"", "[font=default-bold]", title, "[/font]\n", line, tip ~= line and "\n" or "",
                    tip ~= line and tip or ""}
  end
end

local function refresh_buttons(player, parts)
  local armed = abilities.armed(player.index)
  local force_name = player.force.name
  for _, name in ipairs(abilities.LIST) do
    local def = abilities.DEF[name]
    local c = parts.cols[name]
    local button = c.button
    local ok, reason = abilities.available(player.index, name)
    local left = abilities.cooldown_left(force_name, name)
    local is_armed = armed == name
    button.enabled = ok or is_armed
    local style = is_armed and "rts_ability_button_armed" or "rts_ability_button"
    if button.style.name ~= style then button.style = style end
    c.bar.value = left > 0 and (1 - left / def.cooldown) or 1
    c.key.caption = left > 0 and {"rts.ability-cooldown", math.ceil(left / 60)} or (def.key or "–")
    local tip = {"", "[font=default-bold]", TEXT[name], "[/font]  ",
                 def.key and {"rts.ability-tooltip-hotkey", def.key} or {"rts.ability-tooltip-button-only"},
                 "\n", description(name),
                 "\n", {"rts.ability-tooltip-cooldown-total", def.cooldown / 60}}
    if def.tech then
      tip[#tip + 1] = "\n"
      tip[#tip + 1] = {"rts.ability-tooltip-needs", {"technology-name." .. def.tech}}
    end
    if is_armed then
      tip[#tip + 1] = "\n"
      tip[#tip + 1] = {"rts.ability-armed-hint", TEXT[name]}
    elseif not ok and reason then
      tip[#tip + 1] = "\n[color=1,0.5,0.4]"
      tip[#tip + 1] = reason
      tip[#tip + 1] = "[/color]"
    end
    button.tooltip = tip
  end
end

local function screen_of(player)
  if not (player and player.valid and player.connected) then return nil end
  local gui = player.gui
  local screen = gui and gui.screen
  if screen and screen.valid then return screen end
  return nil
end

--- Build, refresh or remove a player's ability bar. Never raises on a missing or invalid element: it rebuilds instead.
function abilitygui.refresh(player)
  local screen = screen_of(player)
  if not screen then return end
  local frame = screen[abilitygui.FRAME]
  if frame and not frame.valid then frame = nil end
  if not wanted(player) then
    if frame then frame.destroy() end
    return
  end
  local mode = layout(player)
  local parts = frame and collect(frame, mode)
  if not parts then
    parts = collect(build(player, screen, mode), mode)
    if not parts then return end
  end
  refresh_card(player, parts)
  refresh_buttons(player, parts)
end

--- True while the player sees the bar.
function abilitygui.is_shown(player)
  local screen = screen_of(player)
  local frame = screen and screen[abilitygui.FRAME]
  return frame ~= nil and frame.valid
end

abilities.on_changed(function(player_index)
  local player = player_index and player_index > 0 and game.get_player(player_index)
  if player then abilitygui.refresh(player) end
end)

events.on_nth_tick(REFRESH, function()
  for _, player in pairs(game.connected_players) do abilitygui.refresh(player) end
end)

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local what = el.tags and el.tags.rts_ability
  if not what then return end
  if what == "commander" then
    commander.select(e.player_index)
  else
    util.log("abilitygui: click %s player=%d", what, e.player_index)
    abilities.activate(e.player_index, what)
  end
  abilitygui.refresh(game.get_player(e.player_index))
end)

-- A new resolution or UI scale may change the layout: rebuild (refresh builds the right one).
local function reposition(e)
  local player = game.get_player(e.player_index)
  local screen = screen_of(player)
  local frame = screen and screen[abilitygui.FRAME]
  if frame and frame.valid then
    frame.destroy()
    abilitygui.refresh(player)
  end
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

function abilitygui.init()
  -- the frame layout may have changed with a mod update: rebuild on the next refresh
  for _, player in pairs(game.players) do
    local screen = player.valid and player.gui and player.gui.screen
    local frame = screen and screen.valid and screen[abilitygui.FRAME]
    if frame and frame.valid then frame.destroy() end
  end
end

return abilitygui
