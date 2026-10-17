-- Phase 5 E1: the city ledger panel and the age badge (docs/PHASE5-M1.md section 3, docs/qa/phase5-economy-notes.md).
-- Nation mode only.
--
-- Age badge: a small screen frame left of the HUD's top strip: "Age I" / "Age II" and the national project's state.
-- A click opens the ledger.
--
-- Ledger (L, custom input rts-ledger; or the badge): a draggable screen frame for one city of the player's force
--   * city drop-down (districts.cities), the age and the Railway Charter: state, progress, delivered / required per
--     good, and a Start button once Industrialisation is researched (ages.start_project);
--   * one row per good (districts.ledger): stock in the city's networks, made and used over the last minute, the make
--     target (a numeric field: typing sets it, empty clears it), the shortfall, and a hint for a short good the city
--     cannot make: "needs X: made in <city>" or "needs X: made nowhere";
--   * an item button + number + Set button for a new target (QA round 1: the button opens the scripted item picker,
--     scripts/itempicker.lua, instead of a choose-elem-button, which took the rts-cursor from the player's cursor; a
--     click on a number field selects its text, so typing replaces the value); a footer with the city's auto / fixed
--     machines.
-- Refreshed every REFRESH ticks while open; rows are rebuilt only when the set of goods changes (so a field being
-- typed in keeps its focus). Owns util.pstorage(i).ledger = {city, items_key, rows = {[item] = elements}} and
-- util.pstorage(i).age_badge.
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local match = require("scripts.match")
local ages = require("scripts.ages")
local districts = require("scripts.districts")
local itempicker = require("scripts.itempicker")

local ledgergui = {}
-- Phase 5 M3 age3 (scripts/age3.lua sets these): project_text_hook(force) -> text | nil, project_hook(player, g) -> true
-- when it drew the project row, extend(player, g, top, row2) adds elements, extend_refresh(player, g, city) updates them
ledgergui.project_text_hook, ledgergui.project_hook, ledgergui.extend, ledgergui.extend_refresh = nil, nil, nil, nil

ledgergui.REFRESH = 60
ledgergui.FRAME = "rts_ledger"
ledgergui.BADGE = "rts_age_badge"
ledgergui.WIDTH = 760
ledgergui.HEIGHT = 520
ledgergui.BADGE_WIDTH = 150
local STRIP_WIDTH, MARGIN = 720, 8 -- scripts/hud.lua's top strip (the badge sits left of it)
local AGE_NUMERAL = {"I", "II", "III"}
local GREY = {r = 0.7, g = 0.7, b = 0.7}
local RED = {r = 1, g = 0.45, b = 0.4}
local GREEN = {r = 0.5, g = 1, b = 0.5}

local function pstate(player_index)
  local ps = util.pstorage(player_index)
  ps.ledger = ps.ledger or {}
  return ps.ledger
end

local function visible_for(player)
  return ages.is_nation() and not match.in_lobby() and player.force and match.is_participant(player.force.name)
end

---------------------------------------------------------------------------
-- Age badge
---------------------------------------------------------------------------
local function badge_caption(force_name)
  local age = ages.of(force_name)
  return {"rts.age-badge", AGE_NUMERAL[age] or tostring(age)}
end

local function project_text(force_name)
  -- Phase 5 M3 age3: the Space Program from Age II on (scripts/age3.lua sets the hook)
  local hooked = ledgergui.project_text_hook and ledgergui.project_text_hook(force_name)
  if hooked then return hooked end
  local age = ages.of(force_name)
  local p = ages.project(force_name)
  if age >= 2 then return {"rts.project-state-done"} end
  if p and p.state == "countdown" then
    return {"rts.project-state-countdown", math.max(0, math.ceil((p.countdown_until - game.tick) / 60))}
  end
  if p and p.state == "razed" then return {"rts.project-state-razed"} end
  if p and p.state == "building" then return {"rts.project-state-building", math.floor(ages.progress(p) * 100)} end
  local ok, why = ages.can_start(force_name)
  if ok then return {"rts.project-state-ready"} end
  if why == "research" then return {"rts.project-state-research"} end
  return {"rts.project-state-research"}
end

local function place_badge(player, frame)
  local res, s = player.display_resolution, player.display_scale
  local m = math.floor(MARGIN * s + 0.5)
  local sw = math.floor(STRIP_WIDTH * s + 0.5)
  local sx = math.floor((res.width - sw) / 2 + 0.5)
  local bw = math.floor(ledgergui.BADGE_WIDTH * s + 0.5)
  frame.location = {math.max(m, sx - bw - m), m}
end

function ledgergui.update_badge(player)
  local screen = player.gui.screen
  local frame = screen[ledgergui.BADGE]
  if not visible_for(player) then
    if frame then frame.visible = false end
    return
  end
  if not frame then
    frame = screen.add({type = "frame", name = ledgergui.BADGE, direction = "vertical", style = "rts_hud_frame"})
    frame.style.width = ledgergui.BADGE_WIDTH
    local button = frame.add({type = "button", name = "rts_age_badge_button", caption = "",
                              tags = {rts_ledger = "open"}, style = "rts_hud_button"})
    button.style.horizontally_stretchable = true
    button.style.font = "default-bold"
    local sub = frame.add({type = "label", name = "rts_age_badge_sub", caption = ""})
    sub.style.font = "default-small"
    sub.style.single_line = false
    sub.style.maximal_width = ledgergui.BADGE_WIDTH - 16
    place_badge(player, frame)
    util.pstorage(player.index).age_badge = {res = player.display_resolution.width, scale = player.display_scale}
  end
  frame.visible = true
  local f = player.force.name
  frame.rts_age_badge_button.caption = badge_caption(f)
  frame.rts_age_badge_button.tooltip = {"rts.age-badge-tooltip"}
  frame.rts_age_badge_sub.caption = project_text(f)
  local b = util.pstorage(player.index).age_badge
  if not b or b.res ~= player.display_resolution.width or b.scale ~= player.display_scale then
    place_badge(player, frame)
    util.pstorage(player.index).age_badge = {res = player.display_resolution.width, scale = player.display_scale}
  end
end

---------------------------------------------------------------------------
-- Ledger frame
---------------------------------------------------------------------------
local function city_name(force_name, city_id)
  for _, c in ipairs(districts.cities(force_name)) do
    if c.id == city_id then return c.name end
  end
  return {"rts.city-unnamed", tostring(city_id)}
end

local function machine_counts(force_name, city_id)
  local auto, fixed = 0, 0
  for _, rec in buildings.for_force(force_name) do
    if (rec.kind == "factory" or rec.kind == "district") and districts.city_of(rec.entity) == city_id then
      if production.is_auto(rec) then auto = auto + 1 else fixed = fixed + 1 end
    end
  end
  return auto, fixed
end

local function item_label(item)
  return {"", "[item=" .. item .. "] ", prototypes.item[item].localised_name}
end

local function hint_caption(force_name, hint)
  if not hint then return "" end
  if hint.city then
    return {"rts.ledger-hint-from", "[item=" .. hint.item .. "]", city_name(force_name, hint.city)}
  end
  return {"rts.ledger-hint-nowhere", "[item=" .. hint.item .. "]"}
end

local COLUMNS = {"good", "stock", "made", "used", "target", "short", "hint"}

local function build_rows(player, g, rows)
  local tbl = g.table
  tbl.clear()
  g.rows = {}
  for _, key in ipairs(COLUMNS) do
    local head = tbl.add({type = "label", caption = {"rts.ledger-col-" .. key}, style = "caption_label"})
    head.style.font_color = GREY
  end
  local keys = {}
  for _, row in ipairs(rows) do
    local item = row.item
    keys[#keys + 1] = item
    local el = {}
    el.good = tbl.add({type = "label", caption = item_label(item)})
    el.good.style.width = 190
    el.stock = tbl.add({type = "label", caption = ""})
    el.stock.style.width = 60
    el.stock.style.horizontal_align = "right"
    el.made = tbl.add({type = "label", caption = ""})
    el.made.style.width = 60
    el.made.style.horizontal_align = "right"
    el.used = tbl.add({type = "label", caption = ""})
    el.used.style.width = 60
    el.used.style.horizontal_align = "right"
    el.target = tbl.add({type = "textfield", text = row.target and tostring(row.target) or "", numeric = true,
                         allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true,
                         tags = {rts_ledger = "target", item = item}, tooltip = {"rts.ledger-target-tooltip"}})
    el.target.style.width = 60
    el.target_value = row.target
    el.short = tbl.add({type = "label", caption = ""})
    el.short.style.width = 50
    el.short.style.horizontal_align = "right"
    el.hint = tbl.add({type = "label", caption = ""})
    el.hint.style.maximal_width = 220
    g.rows[item] = el
  end
  g.items_key = table.concat(keys, ",")
end

local function update_project(player, g)
  if ledgergui.project_hook and ledgergui.project_hook(player, g) then return end -- Phase 5 M3 age3
  local f = player.force.name
  local age = ages.of(f)
  g.age.caption = {"rts.ledger-age", {"rts.age-name-" .. age}}
  g.project.caption = project_text(f)
  local p = ages.project(f)
  g.bar.visible = p ~= nil and age < 2
  g.bar.value = p and ages.progress(p) or 0
  local ok, why = ages.can_start(f)
  g.start.visible = age < 2 and why ~= "running" -- QA round 1: no greyed (and clipped) Start while the site stands
  g.start.enabled = ok
  local parts = {""}
  if p and age < 2 then
    local items = {}
    for item in pairs(p.required) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
      parts[#parts + 1] = string.format("[item=%s] %d/%d   ", item, math.min(p.required[item], p.delivered[item] or 0),
        p.required[item])
    end
  elseif age < 2 then
    local items = {}
    for item in pairs(ages.required()) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do parts[#parts + 1] = string.format("[item=%s] %d   ", item, ages.required()[item]) end
  end
  g.goods.caption = table.concat(parts)
end

function ledgergui.refresh(player)
  local ps = pstate(player.index)
  local g = ps.gui
  if not (g and g.frame and g.frame.valid) then return end
  local f = player.force.name
  local list = districts.cities(f)
  -- city drop-down
  local names, index = {}, 1
  for i, c in ipairs(list) do
    names[i] = c.name
    if c.id == ps.city then index = i end
  end
  if not ps.city or not list[index] or list[index].id ~= ps.city then
    ps.city = list[1] and list[1].id
    index = 1
  end
  if g.city_count ~= #list then
    g.city.items = names
    g.city_count = #list
  end
  if #list > 0 then g.city.selected_index = index end
  update_project(player, g)
  if ledgergui.extend_refresh then ledgergui.extend_refresh(player, g, ps.city) end -- Phase 5 M3 age3
  if not ps.city then return end
  local rows = districts.ledger(ps.city)
  local keys = {}
  for i, row in ipairs(rows) do keys[i] = row.item end
  if table.concat(keys, ",") ~= g.items_key then build_rows(player, g, rows) end
  for _, row in ipairs(rows) do
    local el = g.rows[row.item]
    if el and el.stock.valid then
      el.stock.caption = tostring(row.stock)
      el.made.caption = tostring(row.made)
      el.used.caption = tostring(row.used)
      el.short.caption = row.short > 0 and tostring(row.short) or ""
      el.short.style.font_color = row.short > 0 and RED or GREEN
      el.hint.caption = hint_caption(f, row.hint)
      if el.target_value ~= row.target then
        el.target.text = row.target and tostring(row.target) or ""
        el.target_value = row.target
      end
    end
  end
  local auto, fixed = machine_counts(f, ps.city)
  g.footer.caption = {"rts.ledger-footer", auto, fixed}
end

function ledgergui.open(player)
  if not visible_for(player) then return nil end
  local screen = player.gui.screen
  if screen[ledgergui.FRAME] then screen[ledgergui.FRAME].destroy() end
  local ps = pstate(player.index)
  local frame = screen.add({type = "frame", name = ledgergui.FRAME, direction = "vertical"})
  frame.style.width = ledgergui.WIDTH
  frame.style.maximal_height = ledgergui.HEIGHT
  local bar = frame.add({type = "flow", direction = "horizontal"})
  bar.drag_target = frame
  bar.add({type = "label", caption = {"rts.ledger-title"}, style = "frame_title", ignored_by_interaction = true})
  local drag = bar.add({type = "empty-widget", style = "draggable_space_header"})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  bar.add({type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
           tooltip = {"rts.ledger-close-tooltip"}, tags = {rts_ledger = "close"}})

  local top = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  top.style.horizontally_stretchable = true
  local row1 = top.add({type = "flow", direction = "horizontal"})
  row1.style.vertical_align = "center"
  row1.add({type = "label", caption = {"rts.ledger-city"}})
  local city = row1.add({type = "drop-down", items = {}, tags = {rts_ledger = "city"}})
  city.style.width = 180
  local age = row1.add({type = "label", caption = ""})
  age.style.left_margin = 16
  age.style.font = "default-bold"
  local row2 = top.add({type = "flow", direction = "horizontal"})
  row2.style.vertical_align = "center"
  local project = row2.add({type = "label", caption = ""})
  project.style.width = 330 -- QA round 1: leaves the Start button its whole caption (en and ru)
  project.style.single_line = false
  local pbar = row2.add({type = "progressbar", value = 0})
  pbar.style.width = 110
  local start = row2.add({type = "button", caption = {"rts.project-start"}, tooltip = {"rts.project-start-tooltip"},
                          tags = {rts_ledger = "start"}})
  local goods = top.add({type = "label", caption = ""})
  goods.style.single_line = false
  goods.style.maximal_width = ledgergui.WIDTH - 40

  local body = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  body.style.top_margin = 8
  local scroll = body.add({type = "scroll-pane", vertical_scroll_policy = "auto", horizontal_scroll_policy = "never"})
  scroll.style.maximal_height = 280
  local tbl = scroll.add({type = "table", column_count = #COLUMNS})
  tbl.style.horizontal_spacing = 10
  tbl.style.vertical_spacing = 2
  local add = body.add({type = "flow", direction = "horizontal"})
  add.style.top_margin = 6
  add.style.vertical_align = "center"
  add.add({type = "label", caption = {"rts.ledger-add"}})
  local chooser = add.add({type = "sprite-button", style = "slot_button", tooltip = {"rts.ledger-choose-tooltip"},
                           tags = {rts_ledger = "choose"}})
  local amount = add.add({type = "textfield", text = "50", numeric = true, allow_decimal = false,
                          allow_negative = false, tags = {rts_ledger = "amount"}})
  amount.style.width = 60
  add.add({type = "button", caption = {"rts.ledger-add-button"}, tooltip = {"rts.ledger-add-tooltip"},
           tags = {rts_ledger = "add"}})
  local footer = frame.add({type = "label", caption = ""})
  footer.style.font_color = GREY
  footer.style.single_line = false
  footer.style.maximal_width = ledgergui.WIDTH - 24

  ps.gui = {frame = frame, city = city, age = age, project = project, bar = pbar, start = start, goods = goods,
            table = tbl, chooser = chooser, amount = amount, footer = footer, rows = {}, items_key = nil,
            city_count = -1}
  if ledgergui.extend then ledgergui.extend(player, ps.gui, top, row2) end -- Phase 5 M3 age3: Rush, rare, automation
  frame.auto_center = true
  player.opened = frame
  ledgergui.refresh(player)
  util.log("ledger: opened by player %d (%s), city %s", player.index, player.force.name, tostring(ps.city))
  return frame
end

function ledgergui.close(player)
  local frame = player.gui.screen[ledgergui.FRAME]
  if frame then frame.destroy() end
  local ps = pstate(player.index)
  ps.gui = nil
  itempicker.close(player, "ledger")
end

function ledgergui.toggle(player)
  if player.gui.screen[ledgergui.FRAME] then
    ledgergui.close(player)
  else
    ledgergui.open(player)
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
events.on("rts-ledger", function(e)
  local player = game.get_player(e.player_index)
  if player then ledgergui.toggle(player) end
end)

events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local action = el.tags and el.tags.rts_ledger
  if not action then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  local ps = pstate(player.index)
  if action == "open" then
    ledgergui.toggle(player)
  elseif action == "close" then
    ledgergui.close(player)
  elseif action == "start" then
    local p, why = ages.start_project(player.force.name)
    util.log("ledger: player %d start project: %s (%s)", player.index, p and p.state or "refused", tostring(why))
    if not p then player.print({"rts.project-refused", tostring(why)}) end
    ledgergui.refresh(player)
  elseif action == "choose" then
    itempicker.open(player, "ledger", {city = ps.city})
  elseif action == "target" or action == "amount" then
    el.select_all() -- QA round 1: typing replaces the value (Ctrl+A did not select it in the QA run)
  elseif action == "add" then
    local g = ps.gui
    local item = g and g.chosen
    local n = g and g.amount.valid and tonumber(g.amount.text)
    if item and n and ps.city and itempicker.allowed(item) then
      districts.set_make_target(ps.city, item, n)
      util.log("ledger: player %d target %s %s = %d", player.index, tostring(ps.city), item, n)
      ledgergui.refresh(player)
    end
  end
end)

-- The picker's choice goes on the item button; the amount field takes the focus with its text selected.
itempicker.on_pick("ledger", function(player, item, ctx)
  local g = pstate(player.index).gui
  if not (g and g.frame and g.frame.valid and g.chooser.valid) then return end
  g.chosen = item
  g.chooser.sprite = "item/" .. item
  g.chooser.tooltip = {"rts.ledger-chosen-tooltip", prototypes.item[item].localised_name}
  if g.amount.valid then
    g.amount.focus()
    g.amount.select_all()
  end
  util.log("ledger: player %d picked %s for city %s", player.index, item, tostring(ctx.city))
end)

events.on(defines.events.on_gui_text_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.rts_ledger == "target") then return end
  local ps = pstate(e.player_index)
  if not ps.city then return end
  local item = el.tags.item
  local n = tonumber(el.text)
  districts.set_make_target(ps.city, item, (n and n > 0) and n or nil)
  local g = ps.gui
  local row = g and g.rows and g.rows[item]
  if row then row.target_value = (n and n > 0) and math.floor(n) or nil end
end)

events.on(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.rts_ledger == "city") then return end
  local player = game.get_player(e.player_index)
  local ps = pstate(e.player_index)
  local list = districts.cities(player.force.name)
  local c = list[el.selected_index]
  if c then ps.city = c.id end
  if ps.gui then ps.gui.items_key = nil end
  ledgergui.refresh(player)
end)

events.on(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and el.name == ledgergui.FRAME then
    local player = game.get_player(e.player_index)
    if player then ledgergui.close(player) end
  end
end)

events.on_nth_tick(ledgergui.REFRESH, function()
  for _, player in pairs(game.connected_players) do
    ledgergui.update_badge(player)
    local ps = util.pstorage(player.index).ledger
    if ps and ps.gui then
      if visible_for(player) then ledgergui.refresh(player) else ledgergui.close(player) end
    end
  end
end)

return ledgergui
