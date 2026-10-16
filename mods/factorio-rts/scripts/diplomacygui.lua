-- Phase 5 M2 diplomacy panel (docs/PHASE5-M2.md §3 "Diplomacy panel (F4)"; study rails-trade.md §5.4). Nation mode only.
--
-- Panel (F4 through hud.lua's key table, or diplomacygui.toggle): a centred frame. Header: the victory mode and time
-- limit, and the goal the War buttons declare (nearest city | capital | tribute). One row per other nation: name, state,
-- their opinion of us (bar and number; the tooltip has both directions and the last reason), trade volume, the war's
-- score and weariness, and the buttons War / Ceasefire / Peace / Alliance (Leave while allied) / Gift (100 cr, needs the
-- treasury) / Contract (opens the market's contract dialog when scripts/marketgui.lua offers one). One row per
-- city-state (always at war in M2). Below: our wars (goals, score, weariness) and the proposals waiting for our answer.
-- Offers: a small frame centred under the HUD alert lines lists the proposals to the player's force with Accept and
-- Decline (the alert line itself comes from diplomacy.lua; F3 jumps to the proposer's capital).
--
-- Values refresh every REFRESH ticks while the panel is open (captions in place; rows rebuilt when the set of
-- nations or city-states changes) and at once on every state change. Owns storage.players[i].diplomacygui = {frame,
-- rows = {[force] = {...}}, key, goal, offers = frame, offer_key}. Element names start with "rts_diplo_"; clicks
-- carry tags.rts_diplo. Texts: [rts] keys "diplomacy-*" and "war-*" (locale/*/diplomacy.cfg).
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local diplomacy = require("scripts.diplomacy")
local wars = require("scripts.wars")
local balance = require("balance")

local diplomacygui = {}

local FRAME, OFFERS = "rts_diplo_frame", "rts_diplo_offers"
local PREFIX = "rts_diplo_"
local REFRESH = 60
local OFFERS_PERIOD = 30
local WIDTH = 960 -- the inner frame's minimal width; it grows with the action buttons (Russian captions are longer)
local OFFERS_WIDTH = 520
local OFFERS_SHOWN = 3
local GIFT_CR = 100
local GOALS = {"nearest", "capital", "tribute"}
-- Offers sit under the HUD alert lines: hud.lua MARGIN 8 + STRIP_HEIGHT 96 + 4, then 3 alert lines (about 70).
local OFFERS_TOP = 8 + 96 + 4 + 74
local COLOR = {war = {1, 0.42, 0.36}, ceasefire = {1, 0.85, 0.3}, peace = {0.85, 0.85, 0.85}, alliance = {0.5, 1, 0.5},
               dim = {0.72, 0.72, 0.72}, green = {0.5, 1, 0.5}, red = {1, 0.42, 0.36}}

local function loaded(name) return diplomacy.loaded(name) end

local function gstate(player)
  local p = util.pstorage(player.index)
  p.diplomacygui = p.diplomacygui or {}
  return p.diplomacygui
end

local function nation_running()
  local m = storage.match
  return diplomacy.nation() and m ~= nil and (m.phase == "running" or m.phase == "ended")
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

function diplomacygui.is_open(player)
  local f = player.gui.screen[FRAME]
  return f ~= nil and f.valid
end

function diplomacygui.close(player)
  local f = player.gui.screen[FRAME]
  if f then f.destroy() end
  local g = gstate(player)
  g.frame, g.rows, g.key, g.el = nil, nil, nil, nil
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function force_color(f)
  local c = match.FORCE_COLORS and match.FORCE_COLORS[f]
  return c and {c.r, c.g, c.b} or {0.75, 0.75, 0.75}
end

local function city_states()
  local cities = loaded("scripts.cities")
  if not (cities and game.forces[diplomacy.NEUTRAL]) then return {} end
  return cities.for_force(diplomacy.NEUTRAL)
end

local function row_key(me)
  local parts = {}
  for _, f in ipairs(diplomacy.nations()) do
    if f ~= me then parts[#parts + 1] = f end
  end
  for _, c in ipairs(city_states()) do parts[#parts + 1] = "c" .. c.id end
  return table.concat(parts, ",")
end

local function button(parent, name, caption, tooltip, tags, width)
  local b = parent.add({type = "button", name = PREFIX .. name, caption = caption, tooltip = tooltip, tags = tags})
  b.style.height = 24
  b.style.minimal_width = width or 0
  b.style.padding = {0, 4}
  b.style.font = "default-semibold"
  return b
end

local ACTIONS = {"war", "ceasefire", "peace", "alliance", "gift", "contract"}

local function add_nation_row(tbl, me, f)
  local r = {}
  local name = tbl.add({type = "label", caption = diplomacy.label(f)})
  name.style.font = "default-bold"
  name.style.font_color = force_color(f)
  name.style.width = 150 -- Phase 5 M2 integration: "Free City of X" was cut at 90
  r.state = tbl.add({type = "label", caption = ""})
  r.state.style.width = 80
  local rel = tbl.add({type = "flow", direction = "horizontal"})
  rel.style.vertical_align = "center"
  r.bar = rel.add({type = "progressbar", value = 0.5})
  r.bar.style.width = 60
  r.rel = rel.add({type = "label", caption = ""})
  r.rel.style.width = 32
  r.trade = tbl.add({type = "label", caption = ""})
  r.trade.style.width = 50
  r.war = tbl.add({type = "label", caption = ""})
  r.war.style.width = 120
  r.war.style.single_line = false
  local buttons = tbl.add({type = "flow", direction = "horizontal"})
  buttons.style.horizontal_spacing = 2
  r.buttons = {}
  for _, a in ipairs(ACTIONS) do
    r.buttons[a] = button(buttons, a .. "_" .. f, {"rts.diplomacy-button-" .. a}, {"rts.diplomacy-button-" .. a .. "-tooltip"},
      {rts_diplo = a, force = f})
  end
  r.buttons.gift.caption = {"rts.diplomacy-button-gift", GIFT_CR}
  return r
end

local function add_city_state_row(tbl, c)
  local cities = loaded("scripts.cities")
  local name = tbl.add({type = "label", caption = {"", "[img=utility/warning_icon] ",
    cities and cities.display_name(c) or tostring(c.id)}, tooltip = {"rts.diplomacy-city-state-tooltip"}})
  name.style.width = 150 -- Phase 5 M2 integration
  name.style.font_color = force_color(diplomacy.NEUTRAL)
  local st = tbl.add({type = "label", caption = {"rts.diplomacy-state-war"}, tooltip = {"rts.diplomacy-city-state-tooltip"}})
  st.style.font_color = COLOR.war
  tbl.add({type = "label", caption = "-"})
  tbl.add({type = "label", caption = "-"})
  tbl.add({type = "label", caption = {"rts.diplomacy-city-state-note"}})
  tbl.add({type = "label", caption = ""})
end

local function goal_terms(goal, me, f)
  if goal == "capital" then return {kind = "capital"} end
  if goal == "tribute" then return {kind = "tribute"} end
  return diplomacy.ai_goals(me, f) -- the nearest city of f
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
local function build(player)
  local g = gstate(player)
  local old = player.gui.screen[FRAME]
  if old then old.destroy() end
  local me = player.force.name
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical"})
  frame.auto_center = true
  local title = frame.add({type = "flow", direction = "horizontal"})
  title.drag_target = frame
  title.add({type = "label", caption = {"rts.diplomacy-title"}, style = "frame_title"}).ignored_by_interaction = true
  local drag = title.add({type = "empty-widget", style = "draggable_space_header"})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  title.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
             tooltip = {"rts.diplomacy-close"}, tags = {rts_diplo = "close"}})
  local inner = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  inner.style.minimal_width = WIDTH
  local el = {}
  el.header = inner.add({type = "label", caption = ""})
  el.header.style.single_line = false
  el.header.style.maximal_width = WIDTH - 30
  local grow = inner.add({type = "flow", direction = "horizontal"})
  grow.style.vertical_align = "center"
  grow.add({type = "label", caption = {"rts.diplomacy-goal-label"}, tooltip = {"rts.diplomacy-goal-tooltip"}})
  local items = {}
  for i, goal in ipairs(GOALS) do items[i] = {"rts.diplomacy-goal-" .. goal} end
  local sel = 1
  for i, goal in ipairs(GOALS) do if goal == g.goal then sel = i end end
  grow.add({type = "drop-down", name = PREFIX .. "goal", items = items, selected_index = sel,
            tags = {rts_diplo = "goal"}, tooltip = {"rts.diplomacy-goal-tooltip"}})
  local tbl = inner.add({type = "table", column_count = 6, style = "bordered_table"})
  tbl.style.top_margin = 6
  for _, key in ipairs({"nation", "state", "relation", "trade", "war", "actions"}) do
    local l = tbl.add({type = "label", caption = {"rts.diplomacy-col-" .. key}, tooltip = {"rts.diplomacy-col-" .. key .. "-tooltip"}})
    l.style.font = "default-bold"
  end
  local rows = {}
  for _, f in ipairs(diplomacy.nations()) do
    if f ~= me then rows[f] = add_nation_row(tbl, me, f) end
  end
  for _, c in ipairs(city_states()) do add_city_state_row(tbl, c) end
  el.wars_title = inner.add({type = "label", caption = {"rts.diplomacy-wars-title"}})
  el.wars_title.style.font = "default-bold"
  el.wars_title.style.top_margin = 6
  el.wars = inner.add({type = "flow", direction = "vertical"})
  el.offers_title = inner.add({type = "label", caption = {"rts.diplomacy-offers-title"}})
  el.offers_title.style.font = "default-bold"
  el.offers_title.style.top_margin = 6
  el.offers = inner.add({type = "flow", direction = "vertical"})
  g.frame, g.rows, g.el, g.key = frame, rows, el, row_key(me)
  return frame
end

local function offer_text(P)
  local t = P.terms or {}
  if P.kind == "peace" and t.kind and t.kind ~= "white" then
    return {"rts.diplomacy-offer-peace-terms", diplomacy.label(P.from), wars.treaty_text(t)}
  end
  if P.kind == "gift" then return {"rts.diplomacy-offer-gift", diplomacy.label(P.from), t.cr or 0} end
  return {"rts.diplomacy-offer-" .. P.kind, diplomacy.label(P.from)}
end

local function fill_offers(flow, me, limit)
  flow.clear()
  local list = diplomacy.pending_for(me)
  for i, P in ipairs(list) do
    if limit and i > limit then break end
    local r = flow.add({type = "flow", direction = "horizontal"})
    r.style.vertical_align = "center"
    local l = r.add({type = "label", caption = offer_text(P)})
    l.style.single_line = false
    l.style.maximal_width = (limit and OFFERS_WIDTH or WIDTH) - 200
    local left = P.expires and (P.expires - game.tick) / 60 or nil
    if left then r.add({type = "label", caption = {"rts.diplomacy-offer-left", math.max(0, math.floor(left))}}).style.font_color = COLOR.dim end
    local fill = r.add({type = "empty-widget"})
    fill.style.horizontally_stretchable = true
    local suffix = (limit and "o" or "p") .. P.id
    button(r, "accept_" .. suffix, {"rts.diplomacy-accept"}, {"rts.diplomacy-accept-tooltip"}, {rts_diplo = "accept", id = P.id}, 70)
    button(r, "decline_" .. suffix, {"rts.diplomacy-decline"}, {"rts.diplomacy-decline-tooltip"}, {rts_diplo = "decline", id = P.id}, 70)
  end
  return #list
end

local function war_line(W, me)
  local them = W.a == me and W.b or W.a
  local s = wars.score(W)
  local mine = W.a == me and s.a or s.b
  local weary_me = W.a == me and s.weariness.a or s.weariness.b
  local weary_them = W.a == me and s.weariness.b or s.weariness.a
  local status = W.status == "ceasefire" and {"rts.diplomacy-war-in-ceasefire",
    clock(balance.nation.diplomacy.ceasefire_minutes * 60 - (game.tick - (W.cf_tick or game.tick)) / 60)} or ""
  return {"", {"rts.diplomacy-war-line", diplomacy.label(them), W.a == me and {"rts.diplomacy-war-attacker"}
    or {"rts.diplomacy-war-defender"}, clock(wars.minutes(W) * 60), wars.goal_text(W),
    string.format("%+d", math.floor(mine + 0.5)), math.floor(weary_me + 0.5), math.floor(weary_them + 0.5)}, " ", status}
end

local function header_text(me)
  local m = storage.match
  local c = m and m.config or {}
  local limit = c.time_limit or 0
  local left = limit > 0 and clock(limit * 60 - match.elapsed_seconds()) or nil
  local score = wars.nation_score(me)
  return {"", {"rts.diplomacy-header", {"rts.victory-" .. (c.victory or "conquest")},
    left and {"rts.diplomacy-time-left", left} or {"rts.time-limit-none"}, score}}
end

--- Refresh the open panel's values (rebuilds it when the set of rows changed).
function diplomacygui.refresh(player)
  if not diplomacygui.is_open(player) then return end
  if not nation_running() then
    diplomacygui.close(player)
    return
  end
  local g = gstate(player)
  local me = player.force.name
  if not (g.rows and g.el and g.key == row_key(me)) then build(player) end
  local el = g.el
  el.header.caption = header_text(me)
  local treasury = loaded("scripts.treasury")
  local marketgui = loaded("scripts.marketgui")
  local m = storage.match
  local running = m and m.phase == "running" and not (m.out and m.out[me])
  for f, r in pairs(g.rows) do
    local st = diplomacy.state(me, f)
    local out = m and m.out and m.out[f]
    r.state.caption = out and {"rts.diplomacy-state-out"} or {"rts.diplomacy-state-" .. st}
    r.state.style.font_color = COLOR[st] or COLOR.dim
    local theirs, mine = diplomacy.relation(f, me), diplomacy.relation(me, f)
    r.bar.value = (theirs + 100) / 200
    r.bar.style.color = theirs >= 20 and COLOR.green or (theirs <= -20 and COLOR.red or {1, 0.85, 0.3})
    r.rel.caption = string.format("%+d", math.floor(theirs + 0.5))
    local why = storage.diplomacy.why[f] and storage.diplomacy.why[f][me]
    local tip = {"rts.diplomacy-relation-tooltip", math.floor(theirs + 0.5), math.floor(mine + 0.5),
      why and {"rts.diplomacy-why-" .. tostring(why.key)} or {"rts.diplomacy-why-none"}}
    r.bar.tooltip, r.rel.tooltip = tip, tip
    r.trade.caption = string.format("%d", math.floor(diplomacy.trade_volume(me, f)))
    local W = wars.between(me, f)
    r.war.caption = W and {"rts.diplomacy-war-cell", string.format("%+d", math.floor(wars.net_score(W, me) + 0.5)),
      math.floor(wars.weariness(W, me) + 0.5)} or ""
    local ok = running and not out
    local b = r.buttons
    b.war.enabled = ok and (st == "peace" or st == "ceasefire")
    b.ceasefire.enabled = ok and st == "war" and not diplomacy.pending_between(me, f, "ceasefire")
    b.peace.enabled = ok and (st == "war" or st == "ceasefire") and not diplomacy.pending_between(me, f, "peace")
    b.alliance.enabled = ok and (st == "peace" or st == "alliance") and not diplomacy.pending_between(me, f, "alliance")
    b.alliance.caption = st == "alliance" and {"rts.diplomacy-button-leave"} or {"rts.diplomacy-button-alliance"}
    b.alliance.tags = {rts_diplo = st == "alliance" and "leave" or "alliance", force = f}
    b.alliance.tooltip = st == "alliance" and {"rts.diplomacy-button-leave-tooltip"} or {"rts.diplomacy-button-alliance-tooltip"}
    b.gift.enabled = ok and treasury ~= nil and st ~= "war"
    if not treasury then b.gift.tooltip = {"rts.diplomacy-needs-treasury"} end
    b.contract.enabled = ok and marketgui ~= nil and marketgui.open_contract ~= nil and st ~= "war"
    if not (marketgui and marketgui.open_contract) then b.contract.tooltip = {"rts.diplomacy-needs-market"} end
  end
  el.wars.clear()
  local n = 0
  for _, id in ipairs(wars.active(me)) do
    local W = wars.get(id)
    local l = el.wars.add({type = "label", caption = war_line(W, me)})
    l.style.single_line = false
    l.style.maximal_width = WIDTH - 30
    n = n + 1
  end
  if n == 0 then el.wars.add({type = "label", caption = {"rts.diplomacy-wars-none"}}).style.font_color = COLOR.dim end
  if fill_offers(el.offers, me) == 0 then
    el.offers.add({type = "label", caption = {"rts.diplomacy-offers-none"}}).style.font_color = COLOR.dim
  end
end

--- Open or close the panel (F4). Nation mode only: elsewhere a flying text says so.
function diplomacygui.toggle(player)
  if diplomacygui.is_open(player) then
    diplomacygui.close(player)
    util.log("diplomacygui: closed by player %d (F4)", player.index)
    return false
  end
  if not nation_running() then
    player.create_local_flying_text({text = {"rts.diplomacy-nation-only"}, create_at_cursor = true})
    util.log("diplomacygui: F4 outside a Nation match player=%d", player.index)
    return false
  end
  local frame = build(player)
  diplomacygui.refresh(player)
  player.opened = frame
  util.log("diplomacygui: opened by player %d", player.index)
  return true
end

---------------------------------------------------------------------------
-- Offers under the alert lines
---------------------------------------------------------------------------
local function place_offers(player, frame)
  local s, res = player.display_scale, player.display_resolution
  local w = math.floor(OFFERS_WIDTH * s + 0.5)
  frame.location = {math.floor((res.width - w) / 2 + 0.5), math.floor(OFFERS_TOP * s + 0.5)}
end

--- Show the proposals waiting for the player's force under the alert lines (hidden when there are none).
function diplomacygui.update_offers(player)
  local g = gstate(player)
  local frame = player.gui.screen[OFFERS]
  local list = nation_running() and diplomacy.pending_for(player.force.name) or {}
  local key = {}
  for _, P in ipairs(list) do key[#key + 1] = P.id end
  key = table.concat(key, ",")
  if #list == 0 then
    if frame then frame.destroy() end
    g.offer_key = nil
    return
  end
  if frame and g.offer_key == key then
    return
  end
  if frame then frame.destroy() end
  frame = player.gui.screen.add({type = "frame", name = OFFERS, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = OFFERS_WIDTH
  local flow = frame.add({type = "flow", direction = "vertical"})
  fill_offers(flow, player.force.name, OFFERS_SHOWN)
  place_offers(player, frame)
  g.offer_key = key
  util.log("diplomacygui: offers shown to player %d: %s", player.index, key)
end

local function refresh_all()
  for _, player in pairs(game.connected_players) do
    diplomacygui.update_offers(player)
    if diplomacygui.is_open(player) then diplomacygui.refresh(player) end
  end
end
diplomacygui.refresh_all = refresh_all

---------------------------------------------------------------------------
-- Clicks
---------------------------------------------------------------------------
local function say(player, text)
  player.create_local_flying_text({text = text, create_at_cursor = true})
end

local function propose(player, f, kind, terms)
  local id, why = diplomacy.propose(player.force.name, f, kind, terms)
  if not id then
    say(player, {"rts.diplomacy-invalid", {"rts.diplomacy-invalid-" .. tostring(why)}})
  else
    local P = diplomacy.get_proposal(id)
    if P and P.status == "declined" then
      say(player, {"rts.diplomacy-invalid", {"rts.diplomacy-invalid-" .. tostring(P.reason)}})
    elseif kind ~= "war" then
      say(player, {"rts.diplomacy-sent", {"rts.diplomacy-kind-" .. kind}, diplomacy.label(f)})
    end
  end
  util.log("diplomacygui: player %d %s -> %s: %s", player.index, kind, f, id and ("proposal #" .. id) or tostring(why))
  return id
end

local function on_click(e)
  local el = e.element
  if not (el and el.valid) or string.sub(el.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = el.tags or {}
  local action = tags.rts_diplo
  local player = game.get_player(e.player_index)
  if not (action and player) then return end
  local me = player.force.name
  local f = tags.force
  if action == "close" then
    diplomacygui.close(player)
    return
  elseif action == "war" then
    local g = gstate(player)
    propose(player, f, "war", {goals = goal_terms(g.goal or "nearest", me, f)})
  elseif action == "ceasefire" or action == "peace" or action == "alliance" then
    propose(player, f, action, action == "peace" and {kind = "white"} or {})
  elseif action == "leave" then
    if diplomacy.set_state(me, f, "peace", "alliance left by " .. me) then
      diplomacy.adjust(f, me, balance.nation.diplomacy.relation.alliance_left, "alliance-left")
    end
  elseif action == "gift" then
    propose(player, f, "gift", {cr = GIFT_CR})
  elseif action == "contract" then
    local marketgui = loaded("scripts.marketgui")
    if marketgui and marketgui.open_contract then marketgui.open_contract(player, f) end
  elseif action == "accept" or action == "decline" then
    local ok = diplomacy.answer(tags.id, action == "accept")
    util.log("diplomacygui: player %d %s proposal #%s: %s", player.index, action, tostring(tags.id), tostring(ok))
  else
    return
  end
  refresh_all()
end
diplomacygui.on_click = on_click -- probes click through this path

events.on(defines.events.on_gui_click, on_click)

events.on(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if not (el and el.valid) or el.name ~= PREFIX .. "goal" then return end
  local player = game.get_player(e.player_index)
  gstate(player).goal = GOALS[el.selected_index] or "nearest"
  util.log("diplomacygui: player %d war goal %s", player.index, gstate(player).goal)
end)

events.on(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and el.name == FRAME then
    diplomacygui.close(game.get_player(e.player_index))
    util.log("diplomacygui: closed by player %d (Escape)", e.player_index)
  end
end)

events.on_nth_tick(OFFERS_PERIOD, function(e)
  if not diplomacy.nation() then return end
  for _, player in pairs(game.connected_players) do
    diplomacygui.update_offers(player)
    if e.tick % REFRESH == 0 and diplomacygui.is_open(player) then diplomacygui.refresh(player) end
  end
end)

events.on_signal("rts_diplomacy_changed", function() refresh_all() end)

local function on_resolution(e)
  local player = game.get_player(e.player_index)
  local frame = player and player.gui.screen[OFFERS]
  if frame then place_offers(player, frame) end
end
events.on(defines.events.on_player_display_resolution_changed, on_resolution)
events.on(defines.events.on_player_display_scale_changed, on_resolution)

match.on_teardown(function()
  for _, player in pairs(game.players) do
    diplomacygui.close(player)
    local f = player.gui.screen[OFFERS]
    if f then f.destroy() end
    gstate(player).offer_key = nil
  end
end)

function diplomacygui.init()
  for _, player in pairs(game.players) do
    if diplomacygui.is_open(player) and not nation_running() then diplomacygui.close(player) end
  end
end

return diplomacygui
