-- 0.1.3 (#38): the configurable top strip. This module owns the list of entries the strip shows, its per-player
-- storage, the chooser panel behind the gear button and the hover details; scripts/hud.lua draws the entries.
--
-- An entry is a key: "timer", "army" (own / enemy unit counts), "supply", "power", "bots", "treasury" (Nation only), or
-- "item:<item name>" (the stock of that item in the player's own networks). The timer, the army counters and the supply
-- sit in the strip's first row; every other entry in its second row, in list order, then the gear button.
--
-- Defaults per mode (stripgui.defaults): Nation shows the timer, iron plate, copper plate, stone, coal, grain ("Food"),
-- rations, power and the treasury; Skirmish (supply caps the army, no food chain) the timer, army, supply, iron, copper,
-- stone, coal, magazines and power. Everything else is off until the player adds it.
--
-- Storage (lazy, nothing exists until the first change): util.pstorage(i).hud_prefs.strip = {nation = {keys},
-- skirmish = {keys}}, one list per mode; a missing list means the mode's default. A save keeps it. Stock history for the
-- "last minute" figure: util.pstorage(i).strip_hist = {tick, [item] = {{tick, count}, ...}}, sampled every
-- SAMPLE_TICKS while the entry is shown.
--
-- API: stripgui.keys(player_index, nation) -> the validated list; stripgui.defaults(nation); stripgui.set(i, nation,
-- keys); stripgui.toggle(player, nation) opens / closes the chooser; stripgui.item_stock(force, item); the
-- hover texts: stripgui.item_tooltip(player, item), stripgui.food_stock(force, item).
-- Chooser frame "rts_strip_chooser", element names "rts_strip_*" with tags.rts_strip = action. QA log lines
-- "strip: ..." (change, reset, open).
local util = require("scripts.util")
local events = require("scripts.events")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local logistics = require("scripts.logistics")
local cities = require("scripts.cities")
local population = require("scripts.population")
local itempicker = require("scripts.itempicker")
local balance = require("balance")

local stripgui = {}

stripgui.FRAME = "rts_strip_chooser"
stripgui.MAX_KEYS = 12
stripgui.SAMPLE_TICKS = 300
stripgui.HISTORY_TICKS = 3600
local PREFIX = "rts_strip_"
local RATIONS, GRAIN = "rts-rations", "rts-grain"
local SPECIALS = {"timer", "army", "supply", "power", "bots", "treasury"}
local SPECIAL_SET = {}
for _, k in ipairs(SPECIALS) do SPECIAL_SET[k] = true end
stripgui.SPECIALS = SPECIALS

local DEFAULT_NATION = {"timer", "item:iron-plate", "item:copper-plate", "item:stone", "item:coal", "item:" .. GRAIN,
                        "item:" .. RATIONS, "power", "treasury"}
local DEFAULT_SKIRMISH = {"timer", "army", "supply", "item:iron-plate", "item:copper-plate", "item:stone",
                          "item:coal", "item:firearm-magazine", "power"}

local function mode_key(nation) return nation and "nation" or "skirmish" end

function stripgui.defaults(nation)
  local out = {}
  for _, k in ipairs(nation and DEFAULT_NATION or DEFAULT_SKIRMISH) do out[#out + 1] = k end
  return out
end

--- The item name of an "item:<name>" key, or nil.
function stripgui.item_of(key) return string.match(key, "^item:(.+)$") end

local function valid_key(key, nation)
  if type(key) ~= "string" then return false end
  if SPECIAL_SET[key] then return key ~= "treasury" or nation end
  local item = stripgui.item_of(key)
  return item ~= nil and prototypes.item[item] ~= nil
end

local function prefs_of(player_index)
  local p = util.pstorage(player_index)
  p.hud_prefs = p.hud_prefs or {}
  return p.hud_prefs
end

--- The player's entries in order, validated (unknown items and duplicates dropped, at most MAX_KEYS).
function stripgui.keys(player_index, nation)
  local saved = prefs_of(player_index).strip
  local list = saved and saved[mode_key(nation)]
  if type(list) ~= "table" then return stripgui.defaults(nation), true end
  local out, seen = {}, {}
  for _, key in ipairs(list) do
    if valid_key(key, nation) and not seen[key] and #out < stripgui.MAX_KEYS then
      seen[key] = true
      out[#out + 1] = key
    end
  end
  return out, false
end

--- Store a list for the mode (nil resets to the default).
function stripgui.set(player_index, nation, keys)
  local prefs = prefs_of(player_index)
  if keys == nil then
    if prefs.strip then prefs.strip[mode_key(nation)] = nil end
    if prefs.strip and next(prefs.strip) == nil then prefs.strip = nil end
    return
  end
  prefs.strip = prefs.strip or {}
  prefs.strip[mode_key(nation)] = keys
end

---------------------------------------------------------------------------
-- Numbers: stock per network, consumption, history
---------------------------------------------------------------------------
local function net_count(net, item)
  local n = 0
  for _, c in pairs(net.get_contents()) do
    if c.name == item then n = n + c.count end
  end
  return n
end

--- The networks the strip counts for `force`: {name (localised), net, city (record or nil)}, one per distinct
--- logistic network of a Command Center, then the City Centers' own networks (their market, where the people eat).
function stripgui.networks(force_name, with_cities)
  local list, seen = {}, {}
  for un, rec in buildings.for_force(force_name, "cc") do
    local net = rec.entity.logistic_network
    if net and net.valid and not seen[net.network_id] then
      list[#list + 1] = {name = logistics.hub_name(un), net = net}
      seen[net.network_id] = #list
    end
  end
  if with_cities then
    for _, c in ipairs(cities.for_force(force_name)) do
      local e = c.entity
      local net = e and e.valid and e.logistic_network
      if net and net.valid then
        local at = seen[net.network_id]
        if at == nil then
          seen[net.network_id] = #list + 1
          list[#list + 1] = {name = cities.display_name(c), net = net, city = c, cities = {c}}
        else
          local row = list[at]
          if row then
            row.cities = row.cities or {}
            row.cities[#row.cities + 1] = c
            row.city = row.city or c
          end
        end
      end
    end
  end
  return list
end

--- Rations the force's cities eat per minute, in total and per network row (stripgui.networks(..., true)).
local function ration_use(rows)
  local total = 0
  for _, row in ipairs(rows) do
    row.use = 0
    for _, c in ipairs(row.cities or {}) do
      row.use = row.use + (population.needs(c.id)[RATIONS] or 0)
    end
    total = total + row.use
  end
  return total
end

--- {total, rows = {{name, stock, use, minutes}}, minutes} of rations or grain across the force's cities' networks.
--- minutes = stock / use (grain: counted as the rations it bakes into), nil without any use.
function stripgui.food_detail(force_name, item)
  local rows = stripgui.networks(force_name, true)
  local use = ration_use(rows)
  local bakery = balance.nation.people.bakery
  local k = item == GRAIN and (bakery.rations / bakery.grain) or 1 -- rations per unit of the item
  local total = 0
  for _, row in ipairs(rows) do
    row.stock = net_count(row.net, item)
    total = total + row.stock
    row.minutes = row.use > 0 and row.stock * k / row.use or nil
  end
  return {total = total, rows = rows, minutes = use > 0 and total * k / use or nil, use = use}
end

--- The stock of `item` for the strip: the Command Center networks (the snapshot) or, for food, every network that
--- feeds a city too.
function stripgui.food_stock(force_name, item)
  return stripgui.food_detail(force_name, item).total
end

local function history(player_index)
  local p = util.pstorage(player_index)
  p.strip_hist = p.strip_hist or {}
  return p.strip_hist
end

--- Record the stock of the shown items (every SAMPLE_TICKS) and drop samples older than HISTORY_TICKS + one period.
function stripgui.sample(player_index, stocks)
  local hist = history(player_index)
  if hist.tick and game.tick - hist.tick < stripgui.SAMPLE_TICKS then return end
  hist.tick = game.tick
  for item in pairs(hist) do
    if item ~= "tick" and stocks[item] == nil then hist[item] = nil end
  end
  for item, count in pairs(stocks) do
    local list = hist[item] or {}
    hist[item] = list
    list[#list + 1] = {game.tick, count}
    while #list > 2 and game.tick - list[2][1] > stripgui.HISTORY_TICKS do table.remove(list, 1) end
  end
end

--- Change per minute over the last minute (or the time there is), nil without two samples.
function stripgui.delta(player_index, item, now_count)
  local list = history(player_index)[item]
  if not list or #list < 1 then return nil end
  local first = list[1]
  local elapsed = game.tick - first[1]
  if elapsed < stripgui.SAMPLE_TICKS then return nil end
  return (now_count - first[2]) * 3600 / elapsed
end

local function signed(n)
  n = math.floor(n + (n >= 0 and 0.5 or -0.5))
  return n > 0 and ("+" .. n) or tostring(n)
end

local function minutes_text(m)
  if m >= 100 then return tostring(math.floor(m / 10 + 0.5) * 10) end
  return tostring(math.floor(m + 0.5))
end
stripgui.minutes_text = minutes_text

--- The hover text of an item entry: total, split per network, change over the last minute, minutes left (food).
function stripgui.item_tooltip(player, item, snap_count)
  local proto = prototypes.item[item]
  local force = player.force.name
  local out = {"", {"rts-strip.tip-head", proto.localised_name, snap_count}}
  local food = item == RATIONS or item == GRAIN
  local detail
  if food then
    detail = stripgui.food_detail(force, item)
    out[2] = {"rts-strip.tip-head", proto.localised_name, detail.total}
    for _, row in ipairs(detail.rows) do
      out[#out + 1] = "\n"
      if row.minutes then
        out[#out + 1] = {"rts-strip.tip-row-left", row.name, row.stock, minutes_text(row.minutes)}
      else
        out[#out + 1] = {"rts-strip.tip-row", row.name, row.stock}
      end
    end
    if detail.minutes then
      out[#out + 1] = "\n"
      out[#out + 1] = {item == GRAIN and "rts-strip.tip-left-grain" or "rts-strip.tip-left", minutes_text(detail.minutes),
                       string.format("%.1f", detail.use)}
    end
  else
    local rows = stripgui.networks(force, false)
    if #rows > 1 then
      for _, row in ipairs(rows) do
        out[#out + 1] = "\n"
        out[#out + 1] = {"rts-strip.tip-row", row.name, net_count(row.net, item)}
      end
    end
  end
  local d = stripgui.delta(player.index, item, detail and detail.total or snap_count)
  if d then
    out[#out + 1] = "\n"
    out[#out + 1] = {"rts-strip.tip-delta", signed(d)}
  end
  return out, detail and detail.minutes or nil, detail and detail.total or snap_count
end

---------------------------------------------------------------------------
-- Chooser
---------------------------------------------------------------------------
local function nation_now()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function key_caption(key)
  local item = stripgui.item_of(key)
  if item then return prototypes.item[item].localised_name end
  return {"rts-strip.key-" .. key}
end

local function key_sprite(key)
  local item = stripgui.item_of(key)
  if item then return "item/" .. item end
  return ({timer = "utility/clock", army = "item/rts-walker-kit", supply = "item/rts-supply-crate",
           power = "tooltip-category-electricity", bots = "item/construction-robot", treasury = "item/coin"})[key]
end

local function valid_sprite(path)
  return path ~= nil and helpers.is_valid_sprite_path(path)
end

local build_chooser

local function changed(player, nation, keys, why)
  stripgui.set(player.index, nation, keys)
  util.log("strip: %s player=%d mode=%s keys=%s", why, player.index, mode_key(nation),
    table.concat(keys or stripgui.defaults(nation), ","))
  build_chooser(player, nation)
  if stripgui.refresh then stripgui.refresh(player.index) end
end

build_chooser = function(player, nation)
  local screen = player.gui.screen
  local old = screen[stripgui.FRAME]
  local location = old and old.valid and old.location or nil
  if old and old.valid then old.destroy() end
  local keys, is_default = stripgui.keys(player.index, nation)
  local frame = screen.add({type = "frame", name = stripgui.FRAME, direction = "vertical"})
  frame.style.width = 340
  local bar = frame.add({type = "flow", direction = "horizontal"})
  bar.drag_target = frame
  bar.add({type = "label", caption = {"rts-strip.title"}, style = "frame_title", ignored_by_interaction = true})
  local drag = bar.add({type = "empty-widget", style = "draggable_space_header"})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  bar.add({type = "sprite-button", name = PREFIX .. "close", style = "frame_action_button", sprite = "utility/close",
           tooltip = {"rts-strip.close"}, tags = {rts_strip = "close"}})
  local hint = frame.add({type = "label", caption = {"rts-strip.hint", stripgui.MAX_KEYS}})
  hint.style.single_line = false
  hint.style.maximal_width = 320
  local list = frame.add({type = "flow", direction = "vertical"})
  list.style.vertical_spacing = 2
  for i, key in ipairs(keys) do
    local row = list.add({type = "flow", direction = "horizontal"})
    row.style.vertical_align = "center"
    local sprite = key_sprite(key)
    if valid_sprite(sprite) then row.add({type = "sprite", sprite = sprite, style = "rts_hud_icon"}) end
    local name = row.add({type = "label", caption = key_caption(key)})
    name.style.horizontally_stretchable = true
    local function btn(action, caption, tooltip, enabled)
      local b = row.add({type = "button", name = PREFIX .. action .. "_" .. i, style = "tool_button",
                         caption = caption, tooltip = tooltip, tags = {rts_strip = action, index = i}})
      b.enabled = enabled
      b.style.size = 24
      b.style.padding = 0
      b.style.font = "default-bold"
    end
    btn("up", "<", {"rts-strip.up"}, i > 1)
    btn("down", ">", {"rts-strip.down"}, i < #keys)
    btn("remove", "x", {"rts-strip.remove"}, true)
  end
  -- specials that are off
  local present = {}
  for _, key in ipairs(keys) do present[key] = true end
  local off = {}
  for _, key in ipairs(SPECIALS) do
    if not present[key] and (key ~= "treasury" or nation) then off[#off + 1] = key end
  end
  if #off > 0 then
    local label = frame.add({type = "label", caption = {"rts-strip.add-special"}, style = "caption_label"})
    label.style.top_margin = 4
    local flow = frame.add({type = "flow", direction = "horizontal"})
    for _, key in ipairs(off) do
      local b = flow.add({type = "button", name = PREFIX .. "special_" .. key, style = "tool_button",
                          caption = {"rts-strip.key-" .. key}, tags = {rts_strip = "special", key = key}})
      b.style.minimal_width = 0
      b.style.padding = {0, 6}
      b.style.height = 24
      b.enabled = #keys < stripgui.MAX_KEYS
    end
  end
  local foot = frame.add({type = "flow", direction = "horizontal"})
  foot.style.top_margin = 6
  local add = foot.add({type = "button", name = PREFIX .. "add_item", caption = {"rts-strip.add-item"},
                        tooltip = {"rts-strip.add-item-tooltip"}, tags = {rts_strip = "add_item"}})
  add.enabled = #keys < stripgui.MAX_KEYS
  local filler = foot.add({type = "empty-widget"})
  filler.style.horizontally_stretchable = true
  local reset = foot.add({type = "button", name = PREFIX .. "reset", caption = {"rts-strip.reset"},
                          tooltip = {"rts-strip.reset-tooltip"}, tags = {rts_strip = "reset"}})
  reset.enabled = not is_default
  if location then
    frame.location = location
  else
    local res, s = player.display_resolution, player.display_scale
    frame.location = {math.max(0, math.floor((res.width - 340 * s) / 2)), math.floor(110 * s)}
  end
end

function stripgui.is_open(player)
  local f = player.gui.screen[stripgui.FRAME]
  return f ~= nil and f.valid
end

function stripgui.close(player)
  local f = player.gui.screen[stripgui.FRAME]
  if f and f.valid then f.destroy() end
  itempicker.close(player, "strip")
end

--- The gear button: open or close the chooser.
function stripgui.toggle(player)
  if stripgui.is_open(player) then
    stripgui.close(player)
    return
  end
  local nation = nation_now()
  build_chooser(player, nation)
  util.log("strip: chooser opened player=%d mode=%s", player.index, mode_key(nation))
end

--- Items the picker offers: everything with stock in the force's networks that the strip does not show yet.
local function pickable(player, nation)
  local snap = economy.snapshot(player.force.name)
  local shown = {}
  for _, key in ipairs((stripgui.keys(player.index, nation))) do shown[key] = true end
  local out = {}
  for item, count in pairs(snap and snap.items or {}) do
    local proto = prototypes.item[item]
    if count > 0 and proto and not proto.hidden and item ~= util.CURSOR_ITEM and not shown["item:" .. item] then
      out[#out + 1] = item
    end
  end
  local function order(item)
    local p = prototypes.item[item]
    local g, sg = p.group, p.subgroup
    return (g and g.order or "") .. "|" .. (sg and sg.order or "") .. "|" .. (p.order or "") .. "|" .. item
  end
  table.sort(out, function(a, b) return order(a) < order(b) end)
  -- the food chain is always on offer (an empty stock still shows the entry)
  for _, item in ipairs({RATIONS, GRAIN}) do
    local have = false
    for _, name in ipairs(out) do if name == item then have = true end end
    if not have and nation and not shown["item:" .. item] and prototypes.item[item] then out[#out + 1] = item end
  end
  return out
end

itempicker.on_pick("strip", function(player, item, ctx)
  local nation = nation_now()
  local keys = stripgui.keys(player.index, nation)
  if #keys >= stripgui.MAX_KEYS then return end
  for _, k in ipairs(keys) do
    if k == "item:" .. item then return end
  end
  keys[#keys + 1] = "item:" .. item
  changed(player, nation, keys, "added " .. item)
end)

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local action = el.tags and el.tags.rts_strip
  local player = game.get_player(e.player_index)
  if not (player and action) then return end
  local nation = nation_now()
  local keys = stripgui.keys(player.index, nation)
  if action == "close" then
    stripgui.close(player)
  elseif action == "up" or action == "down" then
    local i = el.tags.index
    local j = action == "up" and i - 1 or i + 1
    if keys[i] and keys[j] then
      keys[i], keys[j] = keys[j], keys[i]
      changed(player, nation, keys, "moved " .. action)
    end
  elseif action == "remove" then
    local removed = table.remove(keys, el.tags.index)
    if removed then changed(player, nation, keys, "removed " .. removed) end
  elseif action == "special" then
    if #keys < stripgui.MAX_KEYS then
      keys[#keys + 1] = el.tags.key
      changed(player, nation, keys, "added " .. el.tags.key)
    end
  elseif action == "reset" then
    changed(player, nation, nil, "reset")
  elseif action == "add_item" then
    local f = player.gui.screen[stripgui.FRAME]
    local s = player.display_scale
    local loc = f and f.valid and {f.location.x + math.floor(350 * s), f.location.y} or nil
    itempicker.open(player, "strip", {}, loc, {items = pickable(player, nation), title = {"rts-strip.picker-title"}})
  end
end)

events.on(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and el.name == stripgui.FRAME then el.destroy() end
end)

function stripgui.init() end

return stripgui
