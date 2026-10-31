-- Release 0.1.4 r5-hud (#43) GUI probe: the top strip chooser offers every item (stock in any network, city needs,
-- enabled recipes, vanilla pieces), grouped, zero stock allowed. A match of MODE ("nation" or "skirmish", the run script
-- rewrites the next line) is started with both AIs stopped, the chooser is opened with three alert lines up, items with
-- no stock anywhere are picked and the strip and its hover are checked. Log lines "[rts] r5 strip <check>: PASS|FAIL ..."
-- and the stop marker RTS_R5_STRIP_DONE. Test copy, one GUI slot:
--   R=build/r5strip-en; rm -rf $R; mkdir -p $R; cp -R mods/factorio-rts mods/mod-list.json $R/
--   cp tools/probes/r5_strip_gui.lua $R/factorio-rts/scripts/; printf '\nrequire("scripts.r5_strip_gui")\n' >> $R/factorio-rts/control.lua
--   RTS_LOCALE=en tools/gui-run.sh $R 300 RTS_R5_STRIP_DONE '\[rts\] (r5 strip|strip:)|rror'
local MODE = "nation"
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local lobby = require("scripts.lobby")
local hud = require("scripts.hud")
local stripgui = require("scripts.stripgui")

local nation = MODE == "nation"

local function check(name, ok, fmt, ...)
  util.log("r5 strip %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
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
    util.log("r5 strip: button %s missing", name)
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
  game.take_screenshot({player = player, by_player = player, path = "rts-r5strip-" .. tag .. ".png", show_gui = true,
                        force_render = true, resolution = {1280, 800}})
end

local function fake_alerts(force)
  storage.alerts = storage.alerts or {}
  for i = 1, 3 do
    storage.alerts[#storage.alerts + 1] = {force = force, tick = game.tick, kind = "probe", text = "rts.alert-generic",
                                           params = {"probe notification " .. i}}
  end
end

local function offered(player)
  local set, groups = {}, {}
  for _, sec in ipairs(stripgui.pickable_sections(player, nation)) do
    groups[#groups + 1] = #sec.items
    for _, item in ipairs(sec.items) do set[item] = true end
  end
  return set, groups
end

local WANT = nation and {"rts-goods", "stone-brick", "rts-hauler-kit", "rts-wall"} or
  {"firearm-magazine", "rts-walker-kit", "rts-science-basic"}
local DROP = {"item:coal", "item:stone", "item:copper-plate", "item:iron-plate"}

local S = {step = 0}
local STEPS = {}
local function step(fn) STEPS[#STEPS + 1] = fn end

step(function(s, player)
  lobby.start_match({opponents = 1, difficulty = "normal", size = "small", enemy_brain = "ai",
                     mode = nation and "nation" or nil}, "r5 strip probe")
  s.wait = 240
  return true
end)

step(function(s, player)
  ai.stop_force(player.force.name)
  ai.stop_force(util.ENEMY_FORCE)
  storage.match.waves_off, storage.match.enemy_next_wave = true, nil
  -- make room: the default has 9 entries (Nation) and the limit is 12
  local keys = stripgui.keys(player.index, nation)
  local out = {}
  for _, k in ipairs(keys) do
    local drop = false
    for _, d in ipairs(DROP) do if k == d then drop = true end end
    if k == "item:firearm-magazine" then drop = true end
    if not drop then out[#out + 1] = k end
  end
  stripgui.set(player.index, nation, out)
  fake_alerts(player.force.name)
  s.wait = 60
  return true
end)

step(function(s, player)
  click(player, "rts_hud_strip_gear")
  s.wait = 40
  return true
end)

step(function(s, player)
  local set, groups = offered(player)
  local missing = {}
  for _, item in ipairs(WANT) do if not set[item] then missing[#missing + 1] = item end end
  check("offered", #missing == 0, "groups %s; missing %s", table.concat(groups, "/"), table.concat(missing, ","))
  check("no_hidden", not set[util.CURSOR_ITEM], "cursor tool not offered")
  click(player, "rts_strip_add_item")
  s.wait = 90
  return true
end)

step(function(s, player)
  shot("01-picker")
  check("picker_open", find(player.gui.screen, "rts_itempicker") ~= nil, "item picker present")
  s.wait = 90
  return true
end)

for i = 1, 4 do
  step(function(s, player)
    local item = WANT[i]
    if not item then return true end
    local ok = click(player, "rts_itempicker_pick_" .. item)
    if not ok then check("pick_" .. i, false, "no picker button for %s", item) end
    s.wait = 40
    return true
  end)
  step(function(s, player)
    local item = WANT[i]
    if not item then return true end
    local keys = stripgui.keys(player.index, nation)
    local has = false
    for _, k in ipairs(keys) do if k == "item:" .. item then has = true end end
    check("picked_" .. item, has, "keys %s", table.concat(keys, ","))
    if i < #WANT or true then click(player, "rts_strip_add_item") end
    s.wait = 40
    return true
  end)
end

step(function(s, player)
  click(player, "rts_itempicker_close")
  hud.refresh(player.index)
  local tips = {}
  for _, item in ipairs(WANT) do
    local tip, minutes, total = stripgui.item_tooltip(player, item, 0)
    tips[#tips + 1] = string.format("%s=%s min=%s", item, tostring(total), tostring(minutes))
    check("hover_" .. item, tip ~= nil and total ~= nil, "total %s, minutes left %s", tostring(total), tostring(minutes))
  end
  shot("02-strip-with-zero-items")
  s.wait = 90
  return true
end)

step(function(s, player)
  util.log("RTS_R5_STRIP_DONE")
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
