-- Phase 5 M1 city GUI (docs/PHASE5-M1.md "cities.lua / citygui.lua"): Nation mode only.
--
-- City panel: one frame in player.gui.screen, left of the hub panel (scripts/hubgui.lua shows the stockpile policy of
-- the same City Center or CC on the right edge). It opens while an own City Center or the capital CC is the selected
-- building, or from the city list (pinned until closed). Content: name and tier, a rename field, land (radius, cells,
-- share of the nation's land), supply, the next tier's requirements (buildings on its land, goods delivered to its
-- market), the logistic networks on its land, and the make targets (one row per item: icon, target field, remove;
-- a choose-item button adds a row). Fields write cities.rename / cities.set_make_target.
--
-- City list: a small frame in the top-left corner under the kill feed, one row per own city: a jump button (name, the
-- camera goes there), tier and land cells, an "open panel" button. hud.lua's strip has the territory share and a
-- "Cities" button that shows or hides it (citygui.toggle_list).
--
-- Polling every POLL_PERIOD ticks, values every REFRESH_PERIOD. Owns storage.players[i].citygui = {frame, el, city,
-- key, pinned, closed, list = frame, list_rows, list_key, list_hidden}. Element names start with "rts_citygui_".
-- Texts: [rts] keys "citygui-*" (locale/*/cities.cfg).
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local camera = require("scripts.camera")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local demolish = require("scripts.demolish") -- Phase 5 M1 integration: the panel's Demolish button

local citygui = {}

local FRAME, LIST = "rts_citygui_frame", "rts_citygui_list"
local PREFIX = "rts_citygui_"
local WIDTH = 300
local LIST_WIDTH = 260
local MARGIN = 8
local TOP = 8 + 228 + 8        -- as the hub panel: below the HUD minimap
local HUB_WIDTH = 340          -- hubgui.lua WIDTH: the city panel sits left of it
local LIST_TOP = 8 + 120       -- under the kill feed (5 lines)
local POLL_PERIOD = 10
local REFRESH_PERIOD = 30
local FIELD_WIDTH = 72
local COLOR = {white = {1, 1, 1}, dim = {0.72, 0.72, 0.72}, yellow = {1, 0.85, 0.3}, green = {0.5, 1, 0.5}}

local function pstate(player_index)
  local p = util.pstorage(player_index)
  p.citygui = p.citygui or {}
  return p.citygui
end

local function nation_running()
  local m = storage.match
  return territory.nation() and m.phase ~= "lobby"
end

local function tier_name(tier) return {cities.TIER_KEYS[tier] or "rts.city-tier-1"} end

---------------------------------------------------------------------------
-- City panel
---------------------------------------------------------------------------
-- The city of the selected building (own City Center or CC), or nil.
local function selected_city(player)
  local un, rec = selection.get_building(player.index)
  if not rec or rec.force ~= player.force.name then return nil end
  local c = cities.of_center(un)
  return c
end

local function destroy_panel(g)
  if g.frame and g.frame.valid then g.frame.destroy() end
  g.frame, g.el, g.city, g.key, g.targets = nil, nil, nil, nil, nil
end

local function place_panel(player, frame)
  local s, res = player.display_scale, player.display_resolution
  local x = res.width - math.floor((HUB_WIDTH + MARGIN + WIDTH + MARGIN) * s + 0.5)
  frame.location = {math.max(0, x), math.floor(TOP * s + 0.5)}
end

local function label(parent, style, caption, width)
  local l = parent.add({type = "label", style = style or "rts_hud_label", caption = caption or ""})
  l.style.maximal_width = width or (WIDTH - 20)
  l.style.single_line = false
  return l
end

local function add_target_row(g, item, n)
  local tbl = g.el.targets
  local proto = prototypes.item[item]
  if not (tbl and tbl.valid and proto) or g.targets[item] then return end
  tbl.add({type = "sprite", sprite = "item/" .. item, tooltip = proto.localised_name})
  local tf = tbl.add({type = "textfield", name = PREFIX .. "target_" .. item, text = n and tostring(n) or "",
    numeric = true, allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true,
    style = "short_number_textfield", tooltip = {"rts.citygui-target-tooltip"},
    tags = {rts_citygui = "target", city = g.city, item = item}})
  tf.style.width = FIELD_WIDTH
  tbl.add({type = "sprite-button", name = PREFIX .. "remove_" .. item, sprite = "utility/close",
    style = "frame_action_button", tooltip = {"rts.citygui-target-remove"},
    tags = {rts_citygui = "remove", city = g.city, item = item}})
  g.targets[item] = tf
end

local function build_panel(player, g, c)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el, g.city, g.targets = frame, {}, c.id, {}
  local el = g.el
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.title = row.add({type = "label", style = "rts_hud_heading_label", caption = "",
                      tooltip = {"rts.citygui-title-tooltip"}})
  el.title.style.maximal_width = WIDTH - 60
  row.add({type = "empty-widget", style = "rts_hud_filler"})
  row.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
           tooltip = {"rts.citygui-close"}, tags = {rts_citygui = "close"}})
  local rename = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.name = rename.add({type = "textfield", name = PREFIX .. "name", text = c.name or "", lose_focus_on_confirm = true,
    tooltip = {"rts.citygui-rename-tooltip"}, tags = {rts_citygui = "name", city = c.id}})
  el.name.style.width = WIDTH - 60
  rename.add({type = "sprite-button", name = PREFIX .. "rename", sprite = "utility/rename_icon",
              style = "tool_button", tooltip = {"rts.citygui-rename"}, tags = {rts_citygui = "rename", city = c.id}})
  el.tier = label(frame, "rts_hud_label")
  el.age = label(frame, "rts_hud_label")
  el.land = label(frame, "rts_hud_label")
  el.supply = label(frame, "rts_hud_label")
  el.next = label(frame, "rts_hud_label")
  el.networks = label(frame, "rts_hud_dim_label")
  label(frame, "rts_hud_heading_label", {"rts.citygui-targets"})
  local tbl = frame.add({type = "table", column_count = 3})
  tbl.style.horizontal_spacing = 8
  tbl.style.vertical_spacing = 2
  el.targets = tbl
  local items = {}
  for item in pairs(c.make) do items[#items + 1] = item end
  table.sort(items)
  for _, item in ipairs(items) do add_target_row(g, item, c.make[item]) end
  local add = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  add.add({type = "choose-elem-button", name = PREFIX .. "add", elem_type = "item", style = "slot_button",
           tooltip = {"rts.citygui-target-add"}, tags = {rts_citygui = "add", city = c.id}})
  label(add, "rts_hud_dim_label", {"rts.citygui-target-hint"}, WIDTH - 60)
  -- Demolish the City Center (two presses, scripts/demolish.lua); the capital cannot be demolished (greyed)
  local foot = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  foot.add({type = "empty-widget", style = "rts_hud_filler"})
  el.demolish = foot.add({type = "button", name = PREFIX .. "demolish", style = "rts_hud_button",
    caption = {"rts.demolish"}, tags = {rts_citygui = "demolish", city = c.id}})
  el.demolish.style.height = 24
  place_panel(player, frame)
end

local function refresh_panel(player, g)
  local c = cities.get(g.city)
  if not c then return false end
  local el = g.el
  el.title.caption = {"rts.citygui-title", cities.display_name(c), tier_name(c.tier)}
  el.tier.caption = {"rts.citygui-tier", tier_name(c.tier), c.radius, c.capital and {"rts.citygui-capital"} or ""}
  -- the nation's age: storage.ages (scripts/ages.lua, m1-economy), else storage.nations[force].age
  local ages = storage.ages and storage.ages[c.force]
  local nation = storage.nations and storage.nations[c.force]
  local age = (type(ages) == "table" and ages.age) or (nation and nation.age) or 1
  el.age.caption = {"rts.citygui-age", age}
  local cells = territory.city_cells(c.id)
  local own = math.max(1, territory.cells(c.force))
  el.land.caption = {"rts.citygui-land", cells, string.format("%d", math.floor(cells * 100 / own + 0.5))}
  el.supply.caption = {"rts.citygui-supply", cities.supply_total(c)}
  local req = cities.next_tier(c)
  if req then
    el.next.caption = {"rts.citygui-next", tier_name(c.tier + 1), c.buildings or 0, req.buildings,
                       math.floor(c.delivered or 0), req.delivered}
    el.next.style.font_color = COLOR.white
  else
    el.next.caption = {"rts.citygui-top"}
    el.next.style.font_color = COLOR.green
  end
  local ids = {}
  for _, id in ipairs(c.networks or {}) do ids[#ids + 1] = "#" .. id end
  el.networks.caption = {"rts.citygui-networks", #ids, #ids > 0 and table.concat(ids, " ") or "-"}
  local b = el.demolish
  if b and b.valid then
    local rec = c.force == player.force.name and buildings.get(c.center) or nil
    local blocked = not rec or buildings.demolish_blocked(rec) ~= nil
    local armed = not blocked and demolish.is_armed(player.index, {c.center})
    b.enabled = not blocked
    b.style = armed and "rts_hud_button_armed" or "rts_hud_button"
    b.style.height = 24
    b.caption = armed and {"rts.demolish-confirm"} or {"rts.demolish"}
    b.tooltip = blocked and {"rts.demolish-tooltip-blocked"}
      or {"rts.demolish-tooltip", math.floor(buildings.REFUND_RATIO * 100)}
  end
  return true
end

local function show_panel(player, force_rebuild)
  local g = pstate(player.index)
  if not nation_running() then
    if g.frame then destroy_panel(g) end
    return
  end
  local c = selected_city(player)
  local key = c and ("sel:" .. c.id) or nil
  if not c and g.pinned then
    c = cities.get(g.pinned)
    key = c and ("pin:" .. c.id) or nil
    if not c then g.pinned = nil end
  end
  if g.closed and g.closed ~= key then g.closed = nil end
  if not c or g.closed == key then
    if g.frame then destroy_panel(g) end
    return
  end
  if force_rebuild or g.key ~= key or not (g.frame and g.frame.valid) then
    destroy_panel(g)
    build_panel(player, g, c)
    g.key = key
    util.log("citygui: city panel %d (%s) player=%d", c.id, key, player.index)
  end
  if not refresh_panel(player, g) then destroy_panel(g) end
end

---------------------------------------------------------------------------
-- City list
---------------------------------------------------------------------------
local function destroy_list(g)
  if g.list and g.list.valid then g.list.destroy() end
  g.list, g.list_rows, g.list_key = nil, nil, nil
end

local function place_list(player, frame)
  local s = player.display_scale
  frame.location = {math.floor(MARGIN * s + 0.5), math.floor(LIST_TOP * s + 0.5)}
end

local function build_list(player, g, list)
  local frame = player.gui.screen.add({type = "frame", name = LIST, direction = "vertical", style = "rts_hud_feed_frame"})
  frame.style.width = LIST_WIDTH
  g.list, g.list_rows = frame, {}
  local head = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  head.add({type = "label", style = "rts_hud_heading_label", caption = {"rts.citygui-list-title"},
            tooltip = {"rts.citygui-list-tooltip"}})
  g.list_share = head.add({type = "label", style = "rts_hud_dim_label", caption = ""})
  for _, c in ipairs(list) do
    local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    local jump = row.add({type = "button", name = PREFIX .. "jump_" .. c.id, caption = cities.display_name(c),
      style = "rts_hud_button", tooltip = {"rts.citygui-jump-tooltip"}, tags = {rts_citygui = "jump", city = c.id}})
    jump.style.maximal_width = 130
    jump.style.height = 24
    jump.style.padding = {0, 4}
    local info = row.add({type = "label", style = "rts_hud_mono_label", caption = ""})
    row.add({type = "empty-widget", style = "rts_hud_filler"})
    row.add({type = "sprite-button", name = PREFIX .. "open_" .. c.id, sprite = "utility/search",
      style = "frame_action_button", tooltip = {"rts.citygui-open-tooltip"}, tags = {rts_citygui = "open", city = c.id}})
    g.list_rows[c.id] = {jump = jump, info = info}
  end
  place_list(player, frame)
end

local function show_list(player)
  local g = pstate(player.index)
  if not nation_running() or g.list_hidden then
    if g.list then destroy_list(g) end
    return
  end
  local list = cities.for_force(player.force.name)
  local ids = {}
  for _, c in ipairs(list) do ids[#ids + 1] = c.id .. ":" .. (c.name or "") end
  local key = table.concat(ids, ",")
  if g.list_key ~= key or not (g.list and g.list.valid) then
    destroy_list(g)
    build_list(player, g, list)
    g.list_key = key
  end
  for _, c in ipairs(list) do
    local r = g.list_rows[c.id]
    if r and r.info.valid then
      r.info.caption = {"rts.citygui-list-row", tier_name(c.tier), territory.city_cells(c.id)}
    end
  end
  if g.list_share and g.list_share.valid then
    g.list_share.caption = {"rts.territory-share-short",
                            string.format("%.1f", territory.share(player.force.name) * 100)}
  end
end

--- Show or hide the city list (the HUD strip's Cities button).
function citygui.toggle_list(player)
  local g = pstate(player.index)
  g.list_hidden = not g.list_hidden or nil
  util.log("citygui: city list %s player=%d", g.list_hidden and "hidden" or "shown", player.index)
  show_list(player)
end

--- Open the city panel of a city (pinned until closed).
function citygui.open(player, city_id)
  local g = pstate(player.index)
  g.pinned, g.closed = city_id, nil
  show_panel(player, true)
end

function citygui.refresh(player_index, force_rebuild)
  local player = game.get_player(player_index)
  if player and player.connected then
    show_panel(player, force_rebuild)
    show_list(player)
  end
end

events.on_nth_tick(POLL_PERIOD, function(e)
  local refresh = e.tick % REFRESH_PERIOD == 0
  for _, player in pairs(game.connected_players) do
    local p = storage.players and storage.players[player.index]
    local g = p and p.citygui
    if nation_running() or (g and (g.frame or g.list)) then
      local c = nation_running() and selected_city(player)
      local key = c and ("sel:" .. c.id) or (g and g.pinned and ("pin:" .. g.pinned)) or nil
      if refresh or (g and g.key) ~= key then
        show_panel(player)
        if refresh then show_list(player) end
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local function rename(player, g, city_id)
  local el = g.el
  if not (el and el.name and el.name.valid) then return end
  cities.rename(city_id, el.name.text)
  util.log("citygui click rename city=%d name=%s player=%d", city_id, el.name.text, player.index)
  show_panel(player)
  show_list(player)
end

events.on(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = element.tags
  local action = tags.rts_citygui
  local player = game.get_player(e.player_index)
  local g = pstate(e.player_index)
  if action == "close" then
    g.closed, g.pinned = g.key, nil
    destroy_panel(g)
  elseif action == "rename" then
    rename(player, g, tags.city)
  elseif action == "remove" then
    cities.set_make_target(tags.city, tags.item, nil)
    show_panel(player, true)
  elseif action == "jump" then
    local c = cities.get(tags.city)
    if c then camera.jump_to(player, c.position) end
  elseif action == "open" then
    citygui.open(player, tags.city)
  elseif action == "demolish" then
    local c = cities.get(tags.city)
    local result = c and demolish.click(player, {c.center}) or "none"
    util.log("citygui click demolish city=%s result=%s player=%d", tostring(tags.city), tostring(result), e.player_index)
    show_panel(player)
    show_list(player)
    return
  else
    return
  end
  util.log("citygui click %s city=%s player=%d", tostring(action), tostring(tags.city), e.player_index)
end)

events.on(defines.events.on_gui_confirmed, function(e)
  local element = e.element
  if not (element and element.valid) or element.tags.rts_citygui ~= "name" then return end
  rename(game.get_player(e.player_index), pstate(e.player_index), element.tags.city)
end)

events.on(defines.events.on_gui_text_changed, function(e)
  local element = e.element
  if not (element and element.valid) or element.tags.rts_citygui ~= "target" then return end
  local text = element.text or ""
  local ok = cities.set_make_target(element.tags.city, element.tags.item, text ~= "" and tonumber(text) or nil)
  util.log("citygui target city=%d %s=%s ok=%s player=%d", element.tags.city, element.tags.item, text, tostring(ok),
    e.player_index)
end)

events.on(defines.events.on_gui_elem_changed, function(e)
  local element = e.element
  if not (element and element.valid) or element.tags.rts_citygui ~= "add" then return end
  local item = element.elem_value
  if not item then return end
  local g = pstate(e.player_index)
  local c = cities.get(element.tags.city)
  if c and not c.make[item] then add_target_row(g, item, nil) end
  element.elem_value = nil
  util.log("citygui add target city=%d item=%s player=%d", element.tags.city, tostring(item), e.player_index)
end)

local function reposition(e)
  local player = game.get_player(e.player_index)
  local g = player and pstate(player.index)
  if not g then return end
  if g.frame and g.frame.valid then place_panel(player, g.frame) end
  if g.list and g.list.valid then place_list(player, g.list) end
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

function citygui.init()
  for _, p in pairs(storage.players or {}) do
    local g = p.citygui
    if g then
      if g.frame and g.frame.valid then g.frame.destroy() end
      if g.list and g.list.valid then g.list.destroy() end
      p.citygui = {list_hidden = g.list_hidden}
    end
  end
end

return citygui
