-- Hub and hauler panels (docs/PHASE4.md 2.1, 2.2 and 7): one frame in player.gui.screen on the right side,
-- below the HUD minimap and above the build menu, shown while a hub / Command Center or only haulers are selected.
--
-- Hub panel: name, network line, then one row per item: icon, count in the hub's network, "Keep" and "Export above"
-- text fields (empty = off; logistics.set_policy on every edit), and a hauler line. Items: logistics.POLICY_ITEMS
-- that exist, the items of logistics.POLICY_SUBGROUPS (intermediates, science kits, unit kits), then anything else in
-- the network or in a policy.
-- Hauler panel (the lowest-numbered selected hauler; the buttons act on every selected hauler): mode buttons Auto /
-- Manual, home or route, state, cargo, deliveries, "Return home" and "Resume" (after a move order parked it).
--
-- The panel follows the selection by polling every POLL_PERIOD ticks (no hook in selection.lua); counts and states
-- refresh every REFRESH_PERIOD ticks. The close button hides the panel until the selection changes.
-- Owns storage.players[i].hubgui = {key, frame, el = {...}, rows = {[item] = count label}, closed = key?}.
-- Element names start with "rts_hubgui_"; hud.lua ignores them. Texts: [rts] keys "hubgui-*", "hauler-*".
local util = require("scripts.util")
local events = require("scripts.events")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local camera = require("scripts.camera")
local logistics = require("scripts.logistics")
local demolish = require("scripts.demolish")

local hubgui = {}

local FRAME = "rts_hubgui_frame"
local PREFIX = "rts_hubgui_"
local WIDTH = 340            -- GUI units
local MARGIN = 8
local TOP = 8 + 228 + 8      -- below the HUD minimap frame (margin + 220 + 2 x 4 rim) and a margin
local LIST_HEIGHT = 250      -- item list scroll height
local FIELD_WIDTH = 64
local COUNT_WIDTH = 64
local POLL_PERIOD = 10
local REFRESH_PERIOD = 30
local COLOR = {white = {1, 1, 1}, dim = {0.72, 0.72, 0.72}, yellow = {1, 0.85, 0.3}, red = {1, 0.42, 0.36},
               green = {0.5, 1, 0.5}}

local function pstate(player_index)
  local p = util.pstorage(player_index)
  p.hubgui = p.hubgui or {}
  return p.hubgui
end

---------------------------------------------------------------------------
-- What to show
---------------------------------------------------------------------------
-- "hub:<un>", "hauler:<un>" or nil, plus the unit number and the list of selected haulers.
local function wanted(player)
  local un, rec = selection.get_building(player.index)
  if rec then
    if rec.kind == "hub" or rec.kind == "cc" then return "hub:" .. un, "hub", un end
    return nil
  end
  local list = selection.get(player.index)
  if #list == 0 then return nil end
  local haulers = {}
  for _, e in pairs(list) do
    if not logistics.hauler(e.unit_number) then return nil end
    haulers[#haulers + 1] = e.unit_number
  end
  table.sort(haulers)
  return "hauler:" .. haulers[1], "hauler", haulers[1], haulers
end

local function destroy(g)
  if g.frame and g.frame.valid then g.frame.destroy() end
  g.frame, g.el, g.rows, g.key, g.kind, g.un, g.haulers = nil, nil, nil, nil, nil, nil, nil
end

local function place(player, frame)
  local s = player.display_scale
  local res = player.display_resolution
  frame.location = {res.width - math.floor((WIDTH + MARGIN) * s + 0.5), math.floor(TOP * s + 0.5)}
end

local function header(frame, caption, tooltip)
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local title = row.add({type = "label", caption = caption, style = "rts_hud_heading_label", tooltip = tooltip})
  title.style.maximal_width = WIDTH - 60
  row.add({type = "empty-widget", style = "rts_hud_filler"})
  row.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
           tooltip = {"rts.hubgui-close"}, tags = {rts_hubgui = "close"}})
  return row, title
end

local function label(parent, style, caption, width)
  local l = parent.add({type = "label", style = style or "rts_hud_label", caption = caption or ""})
  l.style.maximal_width = width or (WIDTH - 20)
  l.style.single_line = false
  return l
end

---------------------------------------------------------------------------
-- Hub panel
---------------------------------------------------------------------------
local function item_list(un)
  local p = logistics.policy(un) or {keep = {}, export_above = {}}
  local entry = logistics.entry_for_hub(un)
  local seen, list = {}, {}
  local function add(name)
    if not seen[name] and prototypes.item[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  for _, name in ipairs(logistics.POLICY_ITEMS) do add(name) end
  for _, group in ipairs(logistics.POLICY_SUBGROUPS) do
    local items = {}
    for name, proto in pairs(prototypes.item) do
      if proto.subgroup and proto.subgroup.name == group and not proto.hidden then items[#items + 1] = proto end
    end
    table.sort(items, function(a, b)
      if a.order ~= b.order then return a.order < b.order end
      return a.name < b.name
    end)
    for _, proto in ipairs(items) do add(proto.name) end
  end
  local rest = {}
  for name in pairs(entry and entry.contents or {}) do rest[#rest + 1] = name end
  for name in pairs(p.keep) do rest[#rest + 1] = name end
  for name in pairs(p.export_above) do rest[#rest + 1] = name end
  table.sort(rest)
  for _, name in ipairs(rest) do add(name) end
  return list
end

local function field(parent, un, item, which, value)
  local tf = parent.add({type = "textfield", name = PREFIX .. which .. "_" .. item, text = value and tostring(value) or "",
    numeric = true, allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true,
    style = "short_number_textfield",
    tooltip = {which == "keep" and "rts.hubgui-keep-tooltip" or "rts.hubgui-export-tooltip"},
    tags = {rts_hubgui = "policy", hub = un, item = item, field = which}})
  tf.style.width = FIELD_WIDTH
  return tf
end

local function build_hub(player, g, un)
  local rec = logistics.hub_rec(un)
  local p = logistics.policy(un)
  if not (rec and p) then return end
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el, g.rows = frame, {}, {}
  header(frame, {"rts.hubgui-title", logistics.hub_name(un)}, {"rts.hubgui-title-tooltip"})
  g.el.network = label(frame, "rts_hud_label")
  g.el.haulers = label(frame, "rts_hud_label")
  label(frame, "rts_hud_dim_label", {"rts.hubgui-hint"})
  if rec.kind == "hub" then
    -- Demolish (two presses, scripts/demolish.lua); never for the Command Center
    g.el.demolish = frame.add({type = "button", name = PREFIX .. "demolish", style = "rts_hud_button",
                               caption = {"rts.demolish"}, tags = {rts_hubgui = "demolish"}})
  end
  local scroll = frame.add({type = "scroll-pane", horizontal_scroll_policy = "never", vertical_scroll_policy = "auto"})
  scroll.style.maximal_height = LIST_HEIGHT
  scroll.style.horizontally_stretchable = true
  local tbl = scroll.add({type = "table", column_count = 4})
  tbl.style.horizontal_spacing = 8
  tbl.style.vertical_spacing = 2
  tbl.add({type = "label", caption = "", style = "rts_hud_dim_label"})
  local h1 = tbl.add({type = "label", caption = {"rts.hubgui-col-count"}, style = "rts_hud_dim_label"})
  h1.style.width = COUNT_WIDTH
  tbl.add({type = "label", caption = {"rts.hubgui-col-keep"}, style = "rts_hud_dim_label",
           tooltip = {"rts.hubgui-keep-tooltip"}})
  tbl.add({type = "label", caption = {"rts.hubgui-col-export"}, style = "rts_hud_dim_label",
           tooltip = {"rts.hubgui-export-tooltip"}})
  for _, item in ipairs(item_list(un)) do
    local proto = prototypes.item[item]
    tbl.add({type = "sprite", sprite = "item/" .. item, tooltip = proto.localised_name})
    local count = tbl.add({type = "label", caption = "0", style = "rts_hud_mono_label"})
    count.style.width = COUNT_WIDTH
    count.style.horizontal_align = "right"
    g.rows[item] = count
    field(tbl, un, item, "keep", p.keep[item])
    field(tbl, un, item, "export", p.export_above[item])
  end
  place(player, frame)
end

local function refresh_hub(player, g)
  local un = g.un
  local rec = logistics.hub_rec(un)
  if not rec then return false end
  local entry = logistics.entry_for_hub(un)
  local el = g.el
  if el.demolish and el.demolish.valid then
    local armed = demolish.is_armed(player.index, {un})
    if armed ~= (el.demolish.style.name == "rts_hud_button_armed") then
      el.demolish.style = armed and "rts_hud_button_armed" or "rts_hud_button"
    end
    el.demolish.caption = armed and {"rts.demolish-confirm"} or {"rts.demolish"}
    el.demolish.tooltip = {"rts.demolish-tooltip", math.floor(buildings.REFUND_RATIO * 100)}
  end
  if entry then
    el.network.caption = {"rts.hubgui-network", entry.id, #entry.hubs}
    el.network.style.font_color = COLOR.white
  else
    el.network.caption = {"rts.hubgui-no-network"}
    el.network.style.font_color = COLOR.red
  end
  local net = entry and entry.network
  for item, count in pairs(g.rows) do
    if count.valid then
      local n = (net and net.valid) and net.get_item_count(item) or 0
      count.caption = tostring(n)
      local keep = entry and entry.keep[item]
      local export = entry and entry.export[item]
      count.style.font_color = (keep and n < keep) and COLOR.yellow or ((export and n > export) and COLOR.green or COLOR.white)
    end
  end
  local home, inbound = 0, 0
  for _, h in logistics.haulers_of(rec.force) do
    if h.mode == "auto" and h.home == un then home = home + 1 end
    local dest = h.mode == "auto" and h.home or h.dropoff
    if dest == un and (h.state == "to_dropoff" or h.state == "to_home") and next(h.cargo or {}) then inbound = inbound + 1 end
  end
  el.haulers.caption = {"rts.hubgui-haulers", home, inbound}
  return true
end

---------------------------------------------------------------------------
-- Hauler panel
---------------------------------------------------------------------------
local STATE_KEYS = {idle = "rts.hauler-state-idle", to_pickup = "rts.hauler-state-to-pickup",
                    to_dropoff = "rts.hauler-state-to-dropoff", to_home = "rts.hauler-state-to-home",
                    waiting = "rts.hauler-state-waiting", parked = "rts.hauler-state-parked"}
local REASON_KEYS = {["no-route"] = "rts.hauler-reason-no-route", nothing = "rts.hauler-reason-nothing",
                     full = "rts.hauler-reason-full", ["no-home"] = "rts.hauler-reason-no-home",
                     ["same-network"] = "rts.hauler-reason-same-network"}

local function items_text(items)
  local names = {}
  for name, n in pairs(items or {}) do
    if n > 0 then names[#names + 1] = name end
  end
  table.sort(names)
  if #names == 0 then return nil end
  local parts = {}
  for _, name in ipairs(names) do parts[#parts + 1] = string.format("[item=%s] %d", name, items[name]) end
  return table.concat(parts, "  ")
end

local function hub_or_none(un)
  return (un and logistics.hub_rec(un)) and logistics.hub_name(un) or {"rts.hub-none"}
end

local function build_hauler(player, g, un, haulers)
  local h = logistics.hauler(un)
  if not h then return end
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el, g.haulers = frame, {}, haulers
  local title = #haulers > 1 and {"rts.hauler-title-more", un, #haulers - 1} or {"rts.hauler-title", un}
  local _, title_label = header(frame, title, {"rts.hauler-title-tooltip"})
  g.el.title = title_label
  local mode = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  mode.add({type = "label", caption = {"rts.hauler-mode"}, style = "rts_hud_label"})
  g.el.auto = mode.add({type = "button", name = PREFIX .. "mode_auto", caption = {"rts.hauler-mode-auto"},
    style = "rts_hud_button", tooltip = {"rts.hauler-mode-auto-tooltip"}, tags = {rts_hubgui = "mode", mode = "auto"}})
  g.el.manual = mode.add({type = "button", name = PREFIX .. "mode_manual", caption = {"rts.hauler-mode-manual"},
    style = "rts_hud_button", tooltip = {"rts.hauler-mode-manual-tooltip"},
    tags = {rts_hubgui = "mode", mode = "manual"}})
  mode.add({type = "empty-widget", style = "rts_hud_filler"})
  g.el.hp = mode.add({type = "label", caption = "", style = "rts_hud_mono_label"})
  g.el.route = label(frame, "rts_hud_label")
  g.el.state = label(frame, "rts_hud_label")
  g.el.cargo = label(frame, "rts_hud_label")
  g.el.delivered = label(frame, "rts_hud_dim_label")
  local buttons = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  g.el.home = buttons.add({type = "button", name = PREFIX .. "return_home", caption = {"rts.hauler-return-home"},
    style = "rts_hud_button", tooltip = {"rts.hauler-return-home-tooltip"}, tags = {rts_hubgui = "return_home"}})
  g.el.resume = buttons.add({type = "button", name = PREFIX .. "resume", caption = {"rts.hauler-resume"},
    style = "rts_hud_button", tooltip = {"rts.hauler-resume-tooltip"}, tags = {rts_hubgui = "resume"}})
  label(frame, "rts_hud_dim_label", {"rts.hauler-hint"})
  place(player, frame)
end

local function refresh_hauler(player, g)
  local h = logistics.hauler(g.un)
  if not h then return false end
  local el = g.el
  el.auto.toggled = h.mode == "auto"
  el.manual.toggled = h.mode == "manual"
  local hp, max = h.entity.health or 0, h.entity.max_health or 0
  el.hp.caption = max > 0 and {"rts.hp-value", math.floor(hp + 0.5), math.floor(max + 0.5)} or ""
  if h.mode == "auto" then
    el.route.caption = {"rts.hauler-home", hub_or_none(h.home)}
  else
    el.route.caption = {"rts.hauler-route", hub_or_none(h.pickup), hub_or_none(h.dropoff)}
  end
  local state = STATE_KEYS[h.state] and {STATE_KEYS[h.state]} or h.state
  local target = h.target and logistics.hub_rec(h.target) and logistics.hub_name(h.target)
  local dist = h.dest and string.format("%.0f", util.distance(h.entity.position, h.dest)) or "0"
  if h.state == "waiting" then
    el.state.caption = {"rts.hauler-state-wait", state, REASON_KEYS[h.reason] and {REASON_KEYS[h.reason]} or (h.reason or "")}
    el.state.style.font_color = COLOR.yellow
  elseif (h.state == "to_pickup" or h.state == "to_dropoff" or h.state == "to_home") and target then
    el.state.caption = {"rts.hauler-state-travel", state, target, dist}
    el.state.style.font_color = COLOR.white
  else
    el.state.caption = {"rts.hauler-state-line", state}
    el.state.style.font_color = h.state == "parked" and COLOR.yellow or COLOR.white
  end
  local cargo = items_text(h.cargo)
  el.cargo.caption = cargo and {"rts.hauler-cargo", cargo} or {"rts.hauler-cargo-empty"}
  local delivered = items_text(h.delivered)
  el.delivered.caption = {"rts.hauler-delivered", h.trips or 0, delivered or "-"}
  el.resume.enabled = h.state == "parked"
  return true
end

---------------------------------------------------------------------------
-- Show / refresh
---------------------------------------------------------------------------
local function show(player, force_rebuild)
  local g = pstate(player.index)
  local key, kind, un, haulers = wanted(player)
  if g.closed and g.closed ~= key then g.closed = nil end
  if not key or g.closed == key then
    if g.frame then destroy(g) end
    return
  end
  local same_haulers = kind ~= "hauler" or (g.haulers and #g.haulers == #haulers)
  if force_rebuild or g.key ~= key or not (g.frame and g.frame.valid) or not same_haulers then
    destroy(g)
    if kind == "hub" then build_hub(player, g, un) else build_hauler(player, g, un, haulers) end
    if not g.frame then return end
    g.key, g.kind, g.un = key, kind, un
    util.log("hubgui: %s panel for #%d player=%d", kind, un, player.index)
  end
  local ok = (kind == "hub") and refresh_hub(player, g) or refresh_hauler(player, g)
  if not ok then destroy(g) end
end

--- Rebuild / refresh the panel of a player now (other modules may call it after changing a policy or a route).
function hubgui.refresh(player_index, force_rebuild)
  local player = game.get_player(player_index)
  if player and player.connected then show(player, force_rebuild) end
end

events.on_nth_tick(POLL_PERIOD, function(e)
  for _, player in pairs(game.connected_players) do
    local g = storage.players and storage.players[player.index] and storage.players[player.index].hubgui
    local key = wanted(player)
    -- The × hides the panel until the selection changes. destroy() clears g.key, so a deselect (key nil) did not
    -- count as a change and the same hub stayed closed when it was selected again (Phase 4 QA step 28).
    if g and g.closed and key ~= g.closed then g.closed = nil end
    if (g and g.key) ~= key or (key and e.tick % REFRESH_PERIOD == 0) or (g and g.frame and not g.frame.valid) then
      show(player)
    end
  end
end)

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local function selected_haulers(g)
  local list = {}
  for _, un in ipairs(g.haulers or {}) do
    if logistics.hauler(un) then list[#list + 1] = un end
  end
  return list
end

events.on(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local action = element.tags.rts_hubgui
  local player = game.get_player(e.player_index)
  local g = pstate(e.player_index)
  if action == "close" then
    g.closed = g.key
    util.log("hubgui click close %s player=%d", tostring(g.key), e.player_index)
    destroy(g)
    return
  end
  if action == "demolish" then
    local result = demolish.click(player, {g.un})
    util.log("hubgui click demolish hub=#%s result=%s player=%d", tostring(g.un), result, e.player_index)
    show(player)
    return
  end
  local list = selected_haulers(g)
  if action == "mode" then
    for _, un in ipairs(list) do logistics.set_mode(un, element.tags.mode) end
  elseif action == "return_home" then
    for _, un in ipairs(list) do logistics.return_home(un) end
  elseif action == "resume" then
    for _, un in ipairs(list) do logistics.resume(un) end
  else
    return
  end
  util.log("hubgui click %s%s haulers=%d player=%d", action, element.tags.mode and (" " .. element.tags.mode) or "",
    #list, e.player_index)
  show(player)
end)

events.on(defines.events.on_gui_text_changed, function(e)
  local element = e.element
  if not (element and element.valid) or element.tags.rts_hubgui ~= "policy" then return end
  local tags = element.tags
  local text = element.text or ""
  local value = text ~= "" and tonumber(text) or nil
  local field = tags.field == "keep" and "keep" or "export_above"
  local ok = logistics.set_policy(tags.hub, field, tags.item, value)
  util.log("hubgui policy hub=#%d %s %s=%s ok=%s player=%d", tags.hub, tags.item, field, tostring(value),
    tostring(ok), e.player_index)
end)

local function reposition(e)
  local player = game.get_player(e.player_index)
  local g = player and pstate(player.index)
  if g and g.frame and g.frame.valid then place(player, g.frame) end
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

function hubgui.init()
  for index, p in pairs(storage.players or {}) do
    if p.hubgui then
      if p.hubgui.frame and p.hubgui.frame.valid then p.hubgui.frame.destroy() end
      p.hubgui = {}
    end
  end
end

---------------------------------------------------------------------------
-- GUI self-test steps (camera.lua runs them while the self-test is on). After the HUD steps (up to 960) and before
-- the match-flow steps (1200+): a hub 45 tiles south of the CC with an auto hauler, the hub panel, then the hauler
-- on a manual route given through the right-click path, the hauler panel.
---------------------------------------------------------------------------
local ST_HUB_OFFSET = {x = 0, y = 45}

local function st_state(player)
  local p = util.pstorage(player.index)
  p.hubgui_selftest = p.hubgui_selftest or {}
  return p.hubgui_selftest
end

local function area_at(pos)
  return {left_top = {x = pos.x - 0.01, y = pos.y - 0.01}, right_bottom = {x = pos.x + 0.01, y = pos.y + 0.01}}
end

camera.add_selftest_step(1000, "logistics_setup", function(player)
  local force = player.force.name
  local cc, cc_un = buildings.main_cc(force)
  if not cc then
    util.log("hubgui selftest: no CC for %s", force)
    return
  end
  local surface = cc.entity.surface
  local want = {x = cc.entity.position.x + ST_HUB_OFFSET.x, y = cc.entity.position.y + ST_HUB_OFFSET.y}
  local pos = surface.find_non_colliding_position(logistics.HUB, want, 12, 1, true) or want
  local hub = surface.create_entity({name = logistics.HUB, position = pos, force = force, raise_built = true})
  if not hub then
    util.log("hubgui selftest: could not create a hub at %s", util.pos_str(pos))
    return
  end
  local st = st_state(player)
  st.hub, st.cc = hub.unit_number, cc_un
  logistics.set_policy(hub.unit_number, "keep", "stone", 30)
  logistics.set_policy(hub.unit_number, "export_above", "coal", 10)
  cc.entity.logistic_network.insert({name = "iron-plate", count = 200})
  local entity = logistics.spawn_hauler(surface, logistics.approach_point(hub.unit_number), force, hub.unit_number)
  st.hauler = entity and entity.unit_number
  camera.jump_to(player, {x = hub.position.x - 6, y = hub.position.y - 4})
  selection.select_building(player.index, hub.unit_number)
  hubgui.refresh(player.index)
  util.log("hubgui selftest: hub #%d at %s, hauler #%s, hub selected", hub.unit_number, util.pos_str(hub.position),
    tostring(st.hauler))
end)

camera.add_selftest_step(1050, "logistics_screenshot_hub", function(player) camera.screenshot(player) end)

camera.add_selftest_step(1080, "logistics_hauler_route", function(player)
  local st = st_state(player)
  local h = logistics.hauler(st.hauler)
  local hub, cc = buildings.get(st.hub or -1), buildings.get(st.cc or -1)
  if not (h and hub and cc) then
    util.log("hubgui selftest: hauler, hub or CC missing")
    return
  end
  selection.set(player.index, {h.entity})
  local o1 = orders.handle_reverse_area(player.index, {hub.entity}, area_at(hub.entity.position), true)
  local o2 = orders.handle_reverse_area(player.index, {cc.entity}, area_at(cc.entity.position), false)
  hubgui.refresh(player.index)
  util.log("hubgui selftest: hauler #%d route orders %s, %s -> mode=%s pickup=#%s dropoff=#%s", st.hauler,
    tostring(o1), tostring(o2), h.mode, tostring(h.pickup), tostring(h.dropoff))
end)

camera.add_selftest_step(1140, "logistics_screenshot_hauler", function(player)
  local st = st_state(player)
  local h = logistics.hauler(st.hauler)
  if h then camera.jump_to(player, {x = h.entity.position.x - 6, y = h.entity.position.y - 4}) end
  camera.screenshot(player)
end)

camera.add_selftest_step(1170, "logistics_gui_done", function(player)
  selection.clear(player.index)
  camera.home(player)
  util.log("RTS_LOGISTICS_GUI_DONE player %d", player.index)
end)

return hubgui
