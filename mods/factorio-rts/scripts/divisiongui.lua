-- Division panel (docs/PHASE5-M1.md section 3, scripts/divisions.lua): a `screen` frame on the left edge under the kill
-- feed, shown to the players of a running match while their force has divisions, two or more combat units are
-- selected, or an own barracks is selected.
--
--   Divisions (3)                        [Form division]     Form: the selected combat units become a division
--   Reinforces: [ Division 2      v]                         only while a barracks is selected
--   +--------------------------------------------------+
--   | [Division 1]                              12/16  |     name button: click selects the division, Shift + click
--   | ======================------------- (HP bar)     |     adds it, right click jumps the camera to it
--   | Moving                                    Hold   |     order / state ................ stance
--   | [Hold] [Advance] [Screen]                        |     detail rows: only for a division whose every member is
--   | [x] Reinforce          [Rename] [Disband]        |     selected
--   +--------------------------------------------------+
--
-- Refresh: hud.lua calls divisiongui.refresh after every HUD refresh (selection changes and every 30 ticks). The panel
-- is rebuilt when its signature (division ids, names, stances, reinforce flags, which divisions are selected, whether
-- Form applies, the selected barracks and its target, the rename field) changes; otherwise only the numbers, health
-- bars and order lines are updated. divisions.on_changed refreshes the panels of the division's force at once for
-- structural changes. Element names start with "rts_div_"; clicks carry tags.rts_div = action.
-- Owns storage.players[i].divgui = {sig, top, el = {frame, title, form, list, cards = {[id] = {n, bar, state}}},
-- rename = id?}.
-- QA log lines start with "divisiongui: ".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local camera = require("scripts.camera")
local selection = require("scripts.selection")
local divisions = require("scripts.divisions")
local hud = require("scripts.hud")

-- Phase 5 M2 war (scripts/warsupply.lua, scripts/garrison.lua; they load later): a supply bar per card in Nation mode
-- (blue supplied, amber low, red out), troop train and garrison states, and a garrison row with Sortie while an own
-- City Center (or the capital's Command Center) is selected.
local function war_mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end
local SP_COLORS = {supplied = {0.35, 0.65, 0.95}, low = {0.95, 0.75, 0.2}, out = {0.95, 0.3, 0.25}}
local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end
local function selected_city(player_index)
  if not nation_mode() then return nil end
  local un = selection.get_building(player_index)
  local cs = storage.city_state
  local id = un and cs and cs.by_center and cs.by_center[un]
  local c = id and storage.cities and storage.cities[id]
  if c and c.force == selection.force_name(player_index) then return id end
  return nil
end

local divisiongui = {}

-- Phase 5 M3 war2: the front row of a selected division's card (Nation mode, while its force has a front)
local function fronts_mod() return war_mod("fronts") end
local function front_count(force)
  local fm = fronts_mod()
  return fm and fm.segments and #fm.segments(force) or 0
end

divisiongui.FRAME = "rts_div_panel"
local PREFIX = "rts_div_"
local WIDTH = 300              -- GUI units (x player.display_scale on screen); fits the Russian stance captions
local LEFT, TOP = 8, 140       -- under the HUD kill feed (top-left corner, 5 lines)
-- The Nation-mode city list (scripts/citygui.lua, frame rts_citygui_list at 8, 128) shares the corner: while it is open
-- the panel stacks under it. GUI elements report no height, so it is estimated from the list's rows.
local CITY_LIST, CITY_LIST_TOP, CITY_ROW = "rts_citygui_list", 128, 26
local BOTTOM_RESERVE = 330     -- kept free above the bottom edge: selection panel (126 + 8) and the console above it
local LIST_MIN, LIST_MAX = 96, 420
local BAR_WIDTH = WIDTH - 16 - 12 - 4
local NAME_WIDTH = 180
local STANCE_WIDTH = math.floor((BAR_WIDTH - 2 * 4) / 3) -- three stance buttons share the card width
local STANCE_TIPS = {hold = {"rts-div.stance-hold-tooltip"}, advance = {"rts-div.stance-advance-tooltip", 40},
                     screen = {"rts-div.stance-screen-tooltip", 20, 25}}
local ORDER_KEYS = {move = "rts-div.order-move", attack_move = "rts-div.order-attack-move",
                    attack = "rts-div.order-attack", retreat = "rts-div.order-retreat", hold = "rts-div.order-hold",
                    stop = "rts-div.state-idle"}
ORDER_KEYS.patrol = "rts-air.order-patrol" -- Phase 5 M3 air: planes on patrol (scripts/air.lua air.order_patrol)

local function px(units_, s) return math.floor(units_ * s + 0.5) end

local function gstate(player_index)
  local p = util.pstorage(player_index)
  p.divgui = p.divgui or {}
  return p.divgui
end

local function wanted_match(player)
  local m = storage.match
  return player.connected and m ~= nil and m.surface ~= nil and m.phase == "running"
    and match.is_participant(player.force.name)
end

-- The player's selected combat units (haulers and the Commander never join a division).
local function combat_selection(player_index)
  local out = {}
  for _, e in pairs(selection.get(player_index)) do
    local rec = storage.units[e.unit_number]
    if rec and not divisions.SKIP_KINDS[rec.kind] then out[#out + 1] = e end
  end
  return out
end

-- Form applies to 2+ selected combat units unless they are exactly one whole division.
local function can_form(player_index, combat)
  if #combat < 2 then return false end
  local first = divisions.of_unit(combat[1].unit_number)
  if not first then return true end
  for _, e in ipairs(combat) do
    if divisions.of_unit(e.unit_number) ~= first then return true end
  end
  return #combat < #divisions.members(first)
end

local function whole_selected(player_index)
  local p = util.pstorage(player_index)
  return selection.whole_divisions(p.selection or {})
end

local function selected_barracks(player_index)
  local un, rec = selection.get_building(player_index)
  if rec and rec.kind == "barracks" then return un, rec end
  return nil
end

local function name_sig(D)
  return type(D.name) == "string" and D.name or ("#" .. D.id)
end

local function signature(player, ds, whole, form, bun, g, city)
  local parts = {form and "F" or "-", tostring(bun or "-"), tostring(bun and divisions.barracks_division(bun) or "-"),
                 tostring(g.rename or "-"), tostring(city or "-"), -- Phase 5 M2 war: the selected city
                 nation_mode() and tostring(front_count(player.force.name) > 0) or "-"} -- Phase 5 M3 war2: fronts
  for _, D in ipairs(ds) do
    parts[#parts + 1] = string.format("%d:%s:%s:%s:%s", D.id, name_sig(D), D.stance, D.reinforce and "r" or "-",
      whole[D.id] and "S" or "-")
  end
  return table.concat(parts, "|")
end

local function destroy(player, g)
  local f = player.gui.screen[divisiongui.FRAME]
  if f then f.destroy() end
  g.el, g.sig = nil, nil
end

local function top_of(player)
  local cl = player.gui.screen[CITY_LIST]
  if cl and cl.valid and cl.visible then
    return math.max(TOP, CITY_LIST_TOP + 12 + #cl.children * CITY_ROW + 8)
  end
  return TOP
end

local function place(player, frame, list)
  local s = player.display_scale
  local res = player.display_resolution
  local top = top_of(player)
  frame.location = {px(LEFT, s), px(top, s)}
  if list and list.valid then
    local h = math.floor(res.height / s) - top - BOTTOM_RESERVE
    list.style.maximal_height = math.max(LIST_MIN, math.min(LIST_MAX, h))
  end
end

local function health_color(ratio)
  if ratio >= 0.6 then return {0.35, 0.85, 0.35} end
  if ratio >= 0.3 then return {0.95, 0.75, 0.2} end
  return {0.95, 0.3, 0.25}
end

-- Phase 5 M2 QA round 1: how long a refused embark shows "No troop train" on the card (ticks)
local NO_TRAIN_TICKS = 10 * 60

local function no_train(D)
  return D.no_train and not D.embark and game.tick - D.no_train.tick < NO_TRAIN_TICKS
end

local function order_caption(D)
  -- Phase 5 M2 war: on a troop train, boarding, going into a garrison
  if (D.aboard or 0) > 0 and next(D.units) == nil then return {"rts-war.state-aboard", D.aboard} end
  if D.embark then return {"rts-war.state-embarking"} end
  if no_train(D) then return {"rts-war.state-no-train"} end -- Phase 5 M2 QA round 1
  local gs = storage.garrison
  if gs and gs.pending and gs.pending[D.id] then return {"rts-war.state-garrisoning"} end
  -- Phase 5 M3 war2: holding a front segment (scripts/fronts.lua), also once the members stand in their slots
  if D.order and D.order.kind == "hold_line" then return {"rts-war3.order-hold-line", D.order.segment or "?"} end
  if D.state == "idle" or not D.order then return {"rts-div.state-idle"} end
  if D.state == "holding" then return {"rts-div.order-hold"} end
  return {ORDER_KEYS[D.order.kind] or "rts-div.state-idle"}
end

local function add_filler(parent)
  return parent.add({type = "empty-widget", style = "rts_hud_filler"})
end

-- A small icon button (vanilla tool_button) with the sprite, or a text button when the sprite does not exist.
local function icon_button(parent, name, sprite, caption, tooltip, tags)
  if helpers.is_valid_sprite_path(sprite) then
    return parent.add({type = "sprite-button", name = name, style = "tool_button", sprite = sprite, tooltip = tooltip,
                       tags = tags})
  end
  return parent.add({type = "button", name = name, style = "rts_hud_button", caption = caption, tooltip = tooltip,
                     tags = tags})
end

local function build_card(scroll, D, selected, g)
  local id = D.id
  local box = scroll.add({type = "frame", style = "inside_shallow_frame", direction = "vertical"})
  box.style.padding = 4
  box.style.horizontally_stretchable = true
  local card = box.add({type = "flow", direction = "vertical"})
  card.style.vertical_spacing = 2
  local row = card.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local name = row.add({type = "button", name = PREFIX .. "select_" .. id, style = "rts_hud_button", caption = D.name,
                        tooltip = {"rts-div.select-tooltip"}, tags = {rts_div = "select", id = id}})
  name.style.maximal_width = NAME_WIDTH
  name.toggled = selected
  add_filler(row)
  local n = row.add({type = "label", style = "rts_hud_mono_label", tooltip = {"rts-div.strength-tooltip"}})
  local bar = card.add({type = "progressbar", style = "rts_hud_progressbar", value = 1})
  bar.style.width = BAR_WIDTH
  local sp_bar -- Phase 5 M2 war: supply points (Nation mode)
  if nation_mode() then
    sp_bar = card.add({type = "progressbar", style = "rts_hud_progressbar", value = 1})
    sp_bar.style.width = BAR_WIDTH
  end
  local row2 = card.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local state = row2.add({type = "label", style = "rts_hud_dim_label"})
  add_filler(row2)
  row2.add({type = "label", style = "rts_hud_dim_label", caption = {"rts-div.stance-" .. D.stance},
            tooltip = STANCE_TIPS[D.stance]})
  if selected then
    local row3 = card.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    row3.style.horizontal_spacing = 4
    for _, st in ipairs(divisions.STANCES) do
      local b = row3.add({type = "button", name = PREFIX .. "stance_" .. id .. "_" .. st, style = "rts_hud_tab_button",
                          caption = {"rts-div.stance-" .. st}, tooltip = STANCE_TIPS[st],
                          tags = {rts_div = "stance", id = id, stance = st}})
      b.style.width = STANCE_WIDTH
      b.style.left_padding, b.style.right_padding = 2, 2
      b.toggled = D.stance == st
    end
    local row4 = card.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    row4.add({type = "checkbox", name = PREFIX .. "reinforce_" .. id, caption = {"rts-div.reinforce"},
              state = D.reinforce == true, tooltip = {"rts-div.reinforce-tooltip"},
              tags = {rts_div = "reinforce", id = id}})
    add_filler(row4)
    if g.rename == id then
      local tf = row4.add({type = "textfield", name = PREFIX .. "rename_field_" .. id,
                           text = type(D.name) == "string" and D.name or "", tooltip = {"rts-div.rename-tooltip"},
                           tags = {rts_div = "rename_field", id = id}})
      tf.style.width = 120
      tf.focus()
    else
      icon_button(row4, PREFIX .. "rename_" .. id, "utility/rename_icon", {"rts-div.rename"},
        {"rts-div.rename-tooltip"}, {rts_div = "rename", id = id})
    end
    icon_button(row4, PREFIX .. "disband_" .. id, "utility/trash", {"rts-div.disband"}, {"rts-div.disband-tooltip"},
      {rts_div = "disband", id = id})
  end
  local front -- Phase 5 M3 war2: the nearest front segment and Hold line
  if selected and nation_mode() and front_count(D.force) > 0 then
    local row5 = card.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    front = row5.add({type = "label", style = "rts_hud_dim_label", caption = ""})
    front.style.maximal_width = BAR_WIDTH - 100
    front.style.single_line = false
    add_filler(row5)
    row5.add({type = "button", name = PREFIX .. "hold_line_" .. id, style = "rts_hud_button",
              caption = {"rts-war3.hold-line"}, tooltip = {"rts-war3.hold-line-tooltip"},
              tags = {rts_div = "hold_line", id = id}})
  end
  return {n = n, bar = bar, state = state, sp = sp_bar, front = front}
end

local function build(player, g, ds, whole, form, bun, city)
  destroy(player, g)
  local screen = player.gui.screen
  local frame = screen.add({type = "frame", name = divisiongui.FRAME, style = "rts_hud_frame", direction = "vertical"})
  frame.style.width = WIDTH
  local el = {frame = frame, cards = {}}
  local head = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.title = head.add({type = "label", style = "rts_hud_heading_label", caption = {"rts-div.title", #ds}})
  add_filler(head)
  el.form = head.add({type = "button", name = PREFIX .. "form", style = "rts_hud_button", caption = {"rts-div.form"},
                      tooltip = form and {"rts-div.form-tooltip"} or {"rts-div.form-need"}, tags = {rts_div = "form"}})
  el.form.enabled = form
  if bun then
    local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    row.add({type = "label", style = "rts_hud_label", caption = {"rts-div.barracks-reinforce"},
             tooltip = {"rts-div.barracks-tooltip"}})
    local items, ids, sel = {{"rts-div.barracks-none"}}, {0}, 1
    local current = divisions.barracks_division(bun)
    for _, D in ipairs(ds) do
      items[#items + 1] = D.name
      ids[#ids + 1] = D.id
      if D.id == current then sel = #ids end
    end
    local dd = row.add({type = "drop-down", name = PREFIX .. "barracks", items = items, selected_index = sel,
                        tooltip = {"rts-div.barracks-tooltip"}, tags = {rts_div = "barracks", un = bun, ids = ids}})
    dd.style.width = 150
  end
  if city then -- Phase 5 M2 war: the garrison of the selected own city
    local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    el.garrison = row.add({type = "label", style = "rts_hud_label", caption = "", tooltip = {"rts-war.garrison-tooltip"}})
    add_filler(row)
    el.sortie = row.add({type = "button", name = PREFIX .. "sortie", style = "rts_hud_button", caption = {"rts-war.sortie"},
                         tooltip = {"rts-war.sortie-tooltip"}, tags = {rts_div = "sortie", city = city}})
    el.city = city
  end
  if #ds > 0 then
    local scroll = frame.add({type = "scroll-pane", name = PREFIX .. "list", direction = "vertical",
                              horizontal_scroll_policy = "never", vertical_scroll_policy = "auto"})
    el.list = scroll
    local cards = scroll.add({type = "flow", direction = "vertical"})
    cards.style.vertical_spacing = 4
    for _, D in ipairs(ds) do el.cards[D.id] = build_card(cards, D, whole[D.id] == true, g) end
  end
  g.el = el
  place(player, frame, el.list)
end

-- Phase 5 M2 integration: the card's state line in low (amber) and out of supply (red)
local STATE_COLOR = {normal = {0.72, 0.72, 0.72}, low = {1, 0.75, 0.3}, out = {1, 0.42, 0.36}}

local function update(g, ds)
  local el = g.el
  local ws = war_mod("warsupply") -- Phase 5 M2 war
  if el.garrison and el.garrison.valid then
    local gm = war_mod("garrison")
    local gar = gm and gm.of(el.city) or {records = {}, points = 0, turrets = 0}
    el.garrison.caption = {"rts-war.garrison-line", #gar.records, gar.points, gar.turrets}
    el.sortie.enabled = #gar.records > 0
  end
  for _, D in ipairs(ds) do
    local c = el.cards[D.id]
    if c and c.n.valid then
      local n, N, ratio = divisions.strength(D)
      c.n.caption = string.format("%d/%d", n, N)
      c.bar.value = ratio
      c.bar.style.color = health_color(ratio)
      c.bar.tooltip = {"rts-div.hp-tooltip", math.floor(ratio * 100 + 0.5)}
      c.state.caption = order_caption(D)
      c.state.style.font_color = STATE_COLOR.normal
      -- Phase 5 M2 QA round 1: a refused embark says why (amber, the reason in the tooltip)
      if no_train(D) then
        c.state.style.font_color = STATE_COLOR.low
        c.state.tooltip = {"rts-war.embark-no-train", {"rts.rails-why-" .. tostring(D.no_train.why)}}
      else
        c.state.tooltip = ""
      end
      if c.front and c.front.valid then -- Phase 5 M3 war2: the segment Hold line would take
        local fm = fronts_mod()
        local seg, dist
        if fm and D.pos then seg, dist = fm.nearest(D.force, D.pos) end
        c.front.caption = seg and {"rts-war3.front-nearest", seg.id, seg.threat, math.floor((dist or 0) + 0.5)}
          or {"rts-war3.front-none"}
      end
      if c.sp and c.sp.valid and ws then -- Phase 5 M2 war
        local sp = ws.sp(D.id)
        local st = ws.state(D.id)
        c.sp.value = sp / 100
        c.sp.style.color = SP_COLORS[st] or SP_COLORS.supplied
        c.sp.tooltip = {"rts-war.sp-tooltip", math.floor(sp + 0.5), {"rts-war.sp-state-" .. st}}
        -- Phase 5 M2 integration: low / out of supply is written on the card (a tester cannot hover the bar)
        if st ~= "supplied" then
          c.state.caption = {"", order_caption(D), " · ", {"rts-war.sp-short-" .. st, math.floor(sp + 0.5)}}
          c.state.style.font_color = STATE_COLOR[st] or STATE_COLOR.normal
        end
      end
    end
  end
end

--- Bring the player's division panel up to date (rebuild on a structural change, else update the numbers).
function divisiongui.refresh(player)
  local g = gstate(player.index)
  if not wanted_match(player) then
    if g.el then destroy(player, g) end
    return
  end
  local ds = divisions.for_force(player.force.name)
  local combat = combat_selection(player.index)
  local form = can_form(player.index, combat)
  local bun = selected_barracks(player.index)
  local city = selected_city(player.index) -- Phase 5 M2 war
  if #ds == 0 and not form and not bun and #combat < 2 and not city then
    if g.el then destroy(player, g) end
    return
  end
  local whole = whole_selected(player.index)
  local sig = signature(player, ds, whole, form, bun, g, city)
  local frame = g.el and g.el.frame
  if sig ~= g.sig or not (frame and frame.valid) then
    build(player, g, ds, whole, form, bun, city)
    g.sig = sig
  elseif g.top ~= top_of(player) then
    place(player, frame, g.el.list) -- the city list opened or closed
  end
  g.top = top_of(player)
  update(g, ds)
end

local function refresh_force(force)
  local f = game.forces[force]
  if not f then return end
  for _, player in pairs(f.connected_players) do divisiongui.refresh(player) end
end

hud.on_refresh(function(player) divisiongui.refresh(player) end)

local STRUCTURAL = {created = true, disbanded = true, stance = true, name = true, reinforce = true, members = true}
divisions.on_changed(function(D, what)
  if STRUCTURAL[what] then refresh_force(D.force) end
end)

---------------------------------------------------------------------------
-- Actions (also used by the autotest and the GUI protocol)
---------------------------------------------------------------------------
--- Form a division of the player's selected combat units. Returns the id or nil.
function divisiongui.form(player)
  local combat = combat_selection(player.index)
  if not can_form(player.index, combat) then return nil end
  local id = divisions.create(player.force.name, combat, {stance = "hold"}, {owner = "player"})
  util.log("divisiongui: player %d formed division #%s from %d selected units", player.index, tostring(id), #combat)
  return id
end

--- Select division `id` (add = Shift: add it to the selection).
function divisiongui.select(player, id, add)
  local D = divisions.get(id)
  if not (D and D.force == player.force.name) then return 0 end
  local list = {}
  for _, rec in ipairs(divisions.live_members(D)) do list[#list + 1] = rec.entity end
  local n = add and selection.add(player.index, list) or selection.set(player.index, list)
  util.log("divisiongui: player %d %s division #%d (%d units, selection %d)", player.index,
    add and "added" or "selected", id, #list, n)
  return n
end

local function own_division(player, id)
  local D = divisions.get(id)
  if D and D.force == player.force.name then return D end
  return nil
end

events.on(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = element.tags
  local action = tags and tags.rts_div
  local player = game.get_player(e.player_index)
  if not (action and player) then return end
  local g = gstate(player.index)
  if action == "form" then
    divisiongui.form(player)
  elseif action == "select" then
    local D = own_division(player, tags.id)
    if D and e.button == defines.mouse_button_type.right then
      local pos = D.pos or (divisions.strength(D, true) and D.pos)
      if pos then camera.jump_to(player, pos) end
    elseif D then
      divisiongui.select(player, D.id, e.shift)
    end
  elseif action == "stance" then
    if own_division(player, tags.id) then divisions.set_stance(tags.id, tags.stance) end
  elseif action == "rename" then
    if own_division(player, tags.id) then g.rename = tags.id end
  elseif action == "disband" then
    if own_division(player, tags.id) then divisions.disband(tags.id, "disbanded by player " .. player.index) end
  elseif action == "hold_line" then -- Phase 5 M3 war2: hold the nearest front segment
    local fm = fronts_mod()
    if fm and own_division(player, tags.id) then
      local ok, why = fm.hold_nearest(tags.id)
      util.log("divisiongui: player %d hold line division #%d ok=%s (%s)", player.index, tags.id, tostring(ok),
        tostring(why))
    end
  elseif action == "sortie" then -- Phase 5 M2 war
    local gm = war_mod("garrison")
    local c = storage.cities and storage.cities[tags.city]
    if gm and c and c.force == player.force.name then
      local id = gm.sortie(tags.city, "player " .. player.index)
      util.log("divisiongui: player %d sortie from city %d -> division #%s", player.index, tags.city, tostring(id))
    end
  end
  divisiongui.refresh(player)
end)

events.on(defines.events.on_gui_checked_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local player = game.get_player(e.player_index)
  local tags = element.tags
  if player and tags.rts_div == "reinforce" and own_division(player, tags.id) then
    divisions.set_reinforce(tags.id, element.state)
    divisiongui.refresh(player)
  end
end)

events.on(defines.events.on_gui_confirmed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local player = game.get_player(e.player_index)
  local tags = element.tags
  if player and tags.rts_div == "rename_field" then
    if own_division(player, tags.id) then divisions.rename(tags.id, element.text) end
    gstate(player.index).rename = nil
    divisiongui.refresh(player)
  end
end)

events.on(defines.events.on_gui_selection_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local player = game.get_player(e.player_index)
  local tags = element.tags
  if player and tags.rts_div == "barracks" then
    local id = tags.ids[element.selected_index]
    divisions.set_barracks(tags.un, (id and id > 0) and id or nil)
    divisiongui.refresh(player)
  end
end)

local function reposition(e)
  local player = game.get_player(e.player_index)
  local g = player and gstate(player.index)
  if g and g.el and g.el.frame and g.el.frame.valid then place(player, g.el.frame, g.el.list) end
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

function divisiongui.init()
  for _, player in pairs(game.players) do
    local g = gstate(player.index)
    g.sig = nil -- rebuild on the next refresh (element references may be stale after a mod update)
  end
end

return divisiongui
