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
-- Refresh: every REFRESH ticks for connected players, and at once when an ability is armed or used.
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
local WIDTH, HEIGHT = 478, 86  -- GUI units (x player.display_scale on screen): 359x65 px at 0.75, 478x86 at 1.0
local MARGIN = 8               -- GUI units above the bottom edge
local INFO_WIDTH = 150         -- card text column; the health bar has the same width
local REFRESH = 15

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

local function place(player, frame)
  local res, s = player.display_resolution, player.display_scale
  local w, h = px(WIDTH, s), px(HEIGHT, s)
  frame.location = {math.floor((res.width - w) / 2 + 0.5), res.height - h - px(MARGIN, s)}
end

local function description(name)
  local d = abilities.DEF[name]
  if name == "stim" then return {"rts.ability-stim-desc", d.cost, math.floor(d.heal * 100 + 0.5)} end
  if name == "shield" then return {"rts.ability-shield-desc", d.radius, d.duration / 60} end
  if name == "scanner" then return {"rts.ability-scanner-desc", d.size, d.duration / 60} end
  if name == "artillery" then return {"rts.ability-artillery-desc", d.range, d.shells} end
  if name == "overcharge" then return {"rts.ability-overcharge-desc", d.duration / 60, d.drain / 1e6} end
  return ""
end

local function build(player)
  local screen = player.gui.screen
  if screen[abilitygui.FRAME] then screen[abilitygui.FRAME].destroy() end
  local frame = screen.add({type = "frame", name = abilitygui.FRAME, style = "rts_hud_frame", direction = "horizontal"})
  frame.style.width = WIDTH
  frame.style.height = HEIGHT -- rts_hud_frame's horizontal flow style puts 8 between the card and the buttons

  local card = frame.add({type = "flow", name = "card", direction = "horizontal"})
  card.style.vertical_align = "center"
  card.style.horizontal_spacing = 6
  card.add({type = "sprite-button", name = PREFIX .. "commander", style = "rts_ability_button",
            sprite = sprite_or("entity/rts-commander", "item/spidertron"), tags = {rts_ability = "commander"}})
  local info = card.add({type = "flow", name = "info", direction = "vertical"})
  info.style.vertical_spacing = 2
  info.style.width = INFO_WIDTH
  local title = info.add({type = "label", name = "title", style = "rts_hud_heading_label", caption = ""})
  title.style.maximal_width = INFO_WIDTH
  local hp = info.add({type = "progressbar", name = "hp", style = "rts_ability_hp_bar", value = 1})
  hp.style.width = INFO_WIDTH
  local line = info.add({type = "label", name = "line", style = "rts_hud_dim_label", caption = ""})
  line.style.maximal_width = INFO_WIDTH

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
  place(player, frame)
  util.log("abilitygui: built for player %d at (%d, %d), %dx%d px (scale %.2f)", player.index,
    frame.location.x, frame.location.y, px(WIDTH, player.display_scale), px(HEIGHT, player.display_scale),
    player.display_scale)
  return frame
end

local function refresh_card(player, frame)
  local info = frame.card.info
  local icon = frame.card[PREFIX .. "commander"]
  local c = commander.card(player.force.name)
  local armed = abilities.armed(player.index)
  if not c then
    info.title.caption = {"rts.commander-card-title", 1}
    info.hp.value = 0
    info.line.caption = {"rts.commander-none"}
    icon.enabled = false
    icon.tooltip = {"rts.commander-none"}
  else
    info.title.caption = {"rts.commander-card-title", c.level}
    icon.enabled = c.alive
    if c.alive then
      info.hp.value = c.max_health > 0 and c.health / c.max_health or 0
      icon.tooltip = {"rts.commander-card-tooltip", math.floor(c.health + 0.5), math.floor(c.max_health + 0.5),
                      math.floor(c.shield + 0.5), math.floor(c.max_shield + 0.5), c.kills}
    else
      info.hp.value = 0
      icon.tooltip = c.waiting and {"rts.commander-waiting"} or {"rts.commander-respawn", c.respawn_in or 0}
    end
    if not c.alive then
      info.line.caption = c.waiting and {"rts.commander-waiting"} or {"rts.commander-respawn", c.respawn_in or 0}
    elseif c.next_kills then
      info.line.caption = {"rts.commander-kills", c.kills, c.next_kills}
    else
      info.line.caption = {"rts.commander-kills-max", c.kills}
    end
  end
  if armed then
    info.line.caption = {"rts.ability-armed-hint", TEXT[armed]}
    info.line.style.font_color = {1, 0.85, 0.3}
  else
    info.line.style.font_color = {0.72, 0.72, 0.72}
  end
end

local function refresh_buttons(player, frame)
  local armed = abilities.armed(player.index)
  local force_name = player.force.name
  for _, name in ipairs(abilities.LIST) do
    local def = abilities.DEF[name]
    local col = frame.buttons[name]
    local button = col[PREFIX .. name]
    local ok, reason = abilities.available(player.index, name)
    local left = abilities.cooldown_left(force_name, name)
    local is_armed = armed == name
    button.enabled = ok or is_armed
    local style = is_armed and "rts_ability_button_armed" or "rts_ability_button"
    if button.style.name ~= style then button.style = style end
    col.bar.value = left > 0 and (1 - left / def.cooldown) or 1
    col.key.caption = left > 0 and {"rts.ability-cooldown", math.ceil(left / 60)} or (def.key or "–")
    local tip = {"", "[font=default-bold]", TEXT[name], "[/font]  ",
                 def.key and {"rts.ability-tooltip-hotkey", def.key} or {"rts.ability-tooltip-button-only"},
                 "\n", description(name),
                 "\n", {"rts.ability-tooltip-cooldown-total", def.cooldown / 60}}
    if def.tech then tip[#tip + 1] = "\n" tip[#tip + 1] = {"rts.ability-tooltip-needs", {"technology-name." .. def.tech}} end
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

--- Build, refresh or remove a player's ability bar.
function abilitygui.refresh(player)
  if not (player and player.valid) then return end
  local frame = player.gui.screen[abilitygui.FRAME]
  if not wanted(player) then
    if frame then frame.destroy() end
    return
  end
  if not (frame and frame.valid and frame.card and frame.buttons) then frame = build(player) end
  refresh_card(player, frame)
  refresh_buttons(player, frame)
end

--- True while the player sees the bar.
function abilitygui.is_shown(player)
  local frame = player.gui.screen[abilitygui.FRAME]
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
  local player = game.get_player(e.player_index)
  if player then abilitygui.refresh(player) end
end)

local function reposition(e)
  local player = game.get_player(e.player_index)
  local frame = player and player.gui.screen[abilitygui.FRAME]
  if frame and frame.valid then place(player, frame) end
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

function abilitygui.init()
  -- the frame layout may have changed with a mod update: rebuild on the next refresh
  for _, player in pairs(game.players) do
    local frame = player.gui.screen[abilitygui.FRAME]
    if frame then frame.destroy() end
  end
end

return abilitygui
