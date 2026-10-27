-- Release 0.1.3 r4-hud GUI probe (#35 factory page rows, #38 top strip), EN and RU (RTS_LOCALE=ru).
-- A Nation match is started (both AIs stopped), a factory is placed and selected: the buildings and logistics tabs
-- are photographed with the panel height the recipe count asks for, a queued order shows "N / M" in the status line.
-- Log lines "[rts] r4 gui <check>: PASS|FAIL ..." and the stop marker RTS_R4_HUD_GUI_DONE. Test copy, one GUI slot
-- (plan rule 1):
--   R=build/r4hud-en; rm -rf $R; mkdir -p $R; cp -R mods/factorio-rts mods/mod-list.json $R/
--   cp tools/probes/r4_hud_gui.lua $R/factorio-rts/scripts/; printf '\nrequire("scripts.r4_hud_gui")\n' >> $R/factorio-rts/control.lua
--   RTS_LOCALE=en tools/gui-run.sh $R 400 RTS_R4_HUD_GUI_DONE '\[rts\] r4 gui|rror'
-- Screenshots land in build/shots-r4hud-en/ (rename to build/shots-r4-hud-en).
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local selection = require("scripts.selection")
local lobby = require("scripts.lobby")
local match = require("scripts.match")
local economy = require("scripts.economy")
local production = require("scripts.production")
local hud = require("scripts.hud")
local ages = require("scripts.ages")
local stripgui = require("scripts.stripgui")
local FR = 2 -- the HUD's P4.FACTORY_ROWS (the run script lowers both to test the growth)

local function check(name, ok, fmt, ...)
  util.log("r4 gui %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function click(player, name, mods)
  mods = mods or {}
  local el = find(player.gui.screen, name)
  if not el then
    util.log("r4 gui: button %s missing", name)
    return false
  end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left,
    shift = mods.shift or false, control = false, alt = false})
  return true
end

local pending_shot
local function shot(tag) pending_shot = {tag = tag, tick = game.tick + 40} end
local function take_shot(player, tag)
  hud.refresh(player.index)
  game.take_screenshot({player = player, by_player = player, path = "rts-r4hud-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}})
end

local function count_buttons(player)
  local root = find(player.gui.screen, "rts_hud_panel")
  local n = 0
  local function walk(el)
    for _, c in pairs(el.children) do
      if c.type == "sprite-button" and c.tags and c.tags.rts_hud == "recipe" and c.tags.recipe ~= ""
        and not c.tags.recipe:find("^%*") then n = n + 1 end
      walk(c)
    end
  end
  if root then walk(root) end
  return n
end

local function panel_state(player, tag)
  local panel = find(player.gui.screen, "rts_hud_panel")
  local f1 = find(player.gui.screen, "rts_hud_f_line1")
  local ctl_ok = find(player.gui.screen, "rts_hud_recipe_pause") and find(player.gui.screen, "rts_hud_recipe_endless")
  local n = count_buttons(player)
  local rows = math.ceil(n / 14)
  local want = 126 + math.max(0, rows - FR) * 36
  local res, sc = player.display_resolution, player.display_scale
  local want_y = res.height - math.floor(want * sc + 0.5) - math.floor(8 * sc + 0.5)
  local y = panel and panel.location.y or -1
  check(tag, y == want_y and ctl_ok ~= nil,
    "%d recipes, %d rows, panel top y=%s (want %d for height %d), status visible=%s, Pause/Endless present=%s",
    n, rows, tostring(y), want_y, want, tostring(f1 and f1.visible), tostring(ctl_ok ~= nil))
  return f1
end

local S = {step = 0}
local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(s, player)
  lobby.start_match({opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai", mode = "nation"},
    "r4 gui probe")
  s.wait = 240
  return true
end)

step(function(s, player)
  local F = player.force.name
  ai.stop_force(F)
  ai.stop_force(util.ENEMY_FORCE)
  storage.match.waves_off, storage.match.enemy_next_wave = true, nil
  game.forces[F].technologies["rts-industrialisation"].researched = true
  ages.set_age(F, 2, "r4 gui probe")
  local home, surface = match.home(F), match.surface()
  for _, item in ipairs({"iron-plate", "copper-plate", "stone-brick", "steel-plate", "plastic-bar", "coal", "rts-rations", "rts-grain"}) do
    economy.give(F, item, 4000)
  end
  local pos = surface.find_non_colliding_position("rts-factory", {x = home.x - 12.5, y = home.y - 10.5}, 12, 1, true)
  s.factory = surface.create_entity({name = "rts-factory", position = pos, force = F, raise_built = true})
  selection.select_building(player.index, s.factory.unit_number)
  s.wait = 90
  return true
end)

step(function(s, player)
  panel_state(player, "nation_buildings")
  shot("01-nation-buildings")
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hud_factory_tab_logistics")
  s.wait = 60
  return true
end)

step(function(s, player)
  panel_state(player, "nation_logistics")
  shot("02-nation-logistics")
  click(player, "rts_hud_factory_tab_buildings")
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hud_recipe_rts-extractor", {shift = true})
  s.wait = 90
  return true
end)

step(function(s, player)
  local st = production.status(s.factory.unit_number)
  local f1 = panel_state(player, "queue_line")
  check("queue", st.queue ~= nil and st.queue.total == 5, "queue %s / %s, line: %s",
    st.queue and st.queue.remaining or "-", st.queue and st.queue.total or "-",
    f1 and serpent.line(f1.caption) or "-")
  shot("03-nation-queue")
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hud_recipe_pause")
  selection.clear(player.index)
  s.wait = 90
  return true
end)

local function strip_entries(player)
  local row = find(player.gui.screen, "rts_hud_strip")
  local out = {}
  local function walk(el)
    for _, c in pairs(el.children) do
      if c.type == "sprite" and c.sprite:find("^item/") then out[#out + 1] = c.sprite:sub(6) end
      walk(c)
    end
  end
  if row then walk(row) end
  return out
end

step(function(s, player)
  local keys = stripgui.keys(player.index, true)
  check("strip_default_nation", #keys == 9 and keys[2] == "item:iron-plate" and keys[7] == "item:rts-rations",
    "keys %s; shown items %s", table.concat(keys, ","), table.concat(strip_entries(player), ","))
  local rations = find(player.gui.screen, "rts_hud_strip")
  shot("04-strip-nation-default")
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hud_strip_gear")
  s.wait = 40
  return true
end)

step(function(s, player)
  check("chooser_open", find(player.gui.screen, "rts_strip_chooser") ~= nil, "chooser frame present")
  shot("05-chooser")
  local keys = stripgui.keys(player.index, true)
  local at
  for i, k in ipairs(keys) do if k == "item:stone" then at = i end end
  click(player, "rts_strip_remove_" .. tostring(at))
  s.wait = 40
  return true
end)

step(function(s, player)
  local keys = stripgui.keys(player.index, true)
  local has = false
  for _, k in ipairs(keys) do if k == "item:stone" then has = true end end
  check("remove_stone", not has and #keys == 8, "keys %s", table.concat(keys, ","))
  click(player, "rts_strip_add_item")
  s.wait = 40
  return true
end)

step(function(s, player)
  shot("06-picker")
  check("picker_open", find(player.gui.screen, "rts_itempicker") ~= nil, "item picker present")
  click(player, "rts_itempicker_pick_steel-plate")
  s.wait = 40
  return true
end)

step(function(s, player)
  local keys = stripgui.keys(player.index, true)
  check("add_steel", keys[#keys] == "item:steel-plate", "keys %s", table.concat(keys, ","))
  click(player, "rts_strip_up_" .. tostring(#keys))
  click(player, "rts_strip_up_" .. tostring(#keys - 1))
  s.wait = 40
  return true
end)

step(function(s, player)
  local keys = stripgui.keys(player.index, true)
  check("order", keys[#keys - 2] == "item:steel-plate", "keys %s", table.concat(keys, ","))
  -- persistence: the list is plain storage data, survives a serialise round trip
  local copy = load("return " .. serpent.block(storage.players[player.index].hud_prefs.strip, {comment = false}))()
  check("persist", copy.nation ~= nil and #copy.nation == #keys, "stored %s", serpent.line(copy))
  shot("07-strip-edited")
  s.wait = 60
  return true
end)

step(function(s, player)
  -- hover details of the rations entry (minutes left) and the iron entry (per network split)
  local tip, minutes = stripgui.item_tooltip(player, "rts-rations", 0)
  check("rations_minutes", minutes ~= nil, "minutes left %s; tooltip %s", tostring(minutes), serpent.line(tip))
  click(player, "rts_strip_reset")
  s.wait = 40
  return true
end)

step(function(s, player)
  local keys, is_default = stripgui.keys(player.index, true)
  check("reset", is_default and #keys == 9, "keys %s", table.concat(keys, ","))
  shot("08-strip-reset")
  click(player, "rts_strip_close")
  s.wait = 60
  return true
end)

step(function(s, player)
  util.log("RTS_R4_HUD_GUI_DONE")
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
