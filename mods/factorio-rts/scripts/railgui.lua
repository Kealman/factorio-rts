-- Phase 5 M1 rail panels (docs/PHASE5-M1.md section 3 "rails.lua / railgui.lua"; docs/qa/phase5-rails-notes.md).
--
-- Train panel: shown while a train (any locomotive or wagon, buildings kind "train") is selected, where the hub panel
-- sits (right side, below the HUD minimap): kind and number, health and fuel, route (pickup -> drop-off depot), state,
-- cargo, deliveries, the line, a "Resume" button and the route hint (right-click a depot = pickup, Shift = drop-off).
-- Depot panel: shown left of the hub panel while a depot is selected: platform, kits / rails / coal in its network,
-- its line (state, length, bill, missing pieces), a "Deploy freight train" button, the force's line list and the
-- hint for laying a line (right-click another depot).
-- Follows the selection by polling every POLL_PERIOD ticks, refreshes every REFRESH_PERIOD ticks, like hubgui.lua.
-- Owns storage.players[i].railgui = {key, frame, el = {...}, closed = key?}. Element names start with "rts_railgui_".
local util = require("scripts.util")
local events = require("scripts.events")
local selection = require("scripts.selection")
local logistics = require("scripts.logistics")
local rails = require("scripts.rails")

local railgui = {}

local FRAME = "rts_railgui_frame"
local PREFIX = "rts_railgui_"
local WIDTH = 330
local HUB_WIDTH = 340       -- hubgui.lua panel width (the depot panel sits left of it)
local MARGIN = 8
local TOP = 8 + 228 + 8
local POLL_PERIOD = 10
local REFRESH_PERIOD = 30
local COLOR = {white = {1, 1, 1}, dim = {0.72, 0.72, 0.72}, yellow = {1, 0.85, 0.3}, red = {1, 0.42, 0.36},
               green = {0.5, 1, 0.5}}
local LINE_COLOR = {surveying = COLOR.yellow, building = COLOR.yellow, open = COLOR.green, cut = COLOR.red,
                    failed = COLOR.red}

local function pstate(player_index)
  local p = util.pstorage(player_index)
  p.railgui = p.railgui or {}
  return p.railgui
end

-- "train:<id>" / "depot:<un>" or nil, plus kind and id.
local function wanted(player)
  local un, rec = selection.get_building(player.index)
  if not rec then return nil end
  if rec.kind == rails.KIND then
    local trec = rails.train_record(rec.entity)
    if trec then return "train:" .. trec.id, "train", trec.id end
    return nil
  end
  if rails.depot(un) then return "depot:" .. un, "depot", un end
  return nil
end

local function destroy(g)
  if g.frame and g.frame.valid then g.frame.destroy() end
  g.frame, g.el, g.key, g.kind, g.id = nil, nil, nil, nil, nil
end

local function place(player, frame, kind)
  local s = player.display_scale
  local res = player.display_resolution
  local right = (WIDTH + MARGIN) + (kind == "depot" and (HUB_WIDTH + MARGIN) or 0)
  frame.location = {res.width - math.floor(right * s + 0.5), math.floor(TOP * s + 0.5)}
end

local function label(parent, style, caption)
  local l = parent.add({type = "label", style = style or "rts_hud_label", caption = caption or ""})
  l.style.maximal_width = WIDTH - 20
  l.style.single_line = false
  return l
end

local function header(frame, caption)
  local row = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local title = row.add({type = "label", caption = caption, style = "rts_hud_heading_label"})
  title.style.maximal_width = WIDTH - 60
  row.add({type = "empty-widget", style = "rts_hud_filler"})
  row.add({type = "sprite-button", name = PREFIX .. "close", sprite = "utility/close", style = "frame_action_button",
           tooltip = {"rts.railgui-close"}, tags = {rts_railgui = "close"}})
  return title
end

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

local function depot_name(un)
  return (un and rails.depot(un)) and logistics.hub_name(un) or {"rts.railgui-none"}
end

local function line_caption(line)
  if not line then return {"rts.railgui-no-line"} end
  return {"rts.railgui-line", depot_name(line.a), depot_name(line.b), {"rts.rails-state-" .. line.state},
          math.floor((line.length or 0) + 0.5), line.rails or 0}
end

---------------------------------------------------------------------------
-- Train panel
---------------------------------------------------------------------------
local function build_train(player, g, id)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el = frame, {}
  local rec = rails.train_record(id)
  g.el.title = header(frame, {rec and rec.kind == "construction" and "rts.railgui-construction-title"
                              or "rts.railgui-train-title", id})
  g.el.hp = label(frame, "rts_hud_mono_label")
  g.el.route = label(frame)
  g.el.state = label(frame)
  g.el.cargo = label(frame)
  g.el.delivered = label(frame, "rts_hud_dim_label")
  g.el.line = label(frame, "rts_hud_dim_label")
  local buttons = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  g.el.resume = buttons.add({type = "button", name = PREFIX .. "resume", caption = {"rts.railgui-resume"},
    style = "rts_hud_button", tooltip = {"rts.railgui-resume-tooltip"}, tags = {rts_railgui = "resume"}})
  label(frame, "rts_hud_dim_label", {"rts.railgui-train-hint"})
  place(player, frame, "train")
end

local STATE_KEYS = {idle = "rts.rails-train-idle", stopped = "rts.rails-train-stopped",
                    to_pickup = "rts.rails-train-to-pickup", to_dropoff = "rts.rails-train-to-dropoff",
                    loading = "rts.rails-train-loading", unloading = "rts.rails-train-unloading",
                    waiting = "rts.rails-train-waiting", no_path = "rts.rails-train-no-path",
                    to_head = "rts.rails-train-to-head", building = "rts.rails-train-building",
                    returning = "rts.rails-train-returning"}

local function refresh_train(player, g)
  local rec = rails.train_record(g.id)
  local train = rec and rails.train_of(rec)
  if not (rec and train) then return false end
  local el = g.el
  local loco = train.front_stock
  local hp, max = loco and loco.health or 0, loco and loco.max_health or 0
  el.hp.caption = {"rts.railgui-hp-fuel", math.floor(hp + 0.5), math.floor(max + 0.5), rails.fuel_left(train)}
  if rec.kind == "construction" then
    local line = rec.line and rails.lines[rec.line]
    el.route.caption = {"rts.railgui-crew-home", depot_name(rec.home)}
    el.line.caption = line_caption(line)
    el.delivered.caption = {"rts.railgui-built", rec.built or 0, line and line.missing or 0}
  else
    if rec.pickup and rec.dropoff then
      el.route.caption = {"rts.railgui-route", depot_name(rec.pickup), depot_name(rec.dropoff)}
    else
      el.route.caption = {"rts.railgui-route-unset"}
    end
    local d = rails.depot(rec.pickup or rec.home)
    local line = d and d.line and rails.lines[d.line]
    el.line.caption = line_caption(line)
    el.delivered.caption = {"rts.railgui-delivered", rec.trips or 0, items_text(rec.delivered) or "-"}
  end
  local key = STATE_KEYS[rec.state]
  local state = key and {key} or (rec.state or "-")
  if rec.reason then
    el.state.caption = {"rts.railgui-state-why", state, {"rts.rails-why-" .. rec.reason}}
    el.state.style.font_color = COLOR.yellow
  else
    el.state.caption = {"rts.railgui-state", state}
    el.state.style.font_color = rec.state == "no_path" and COLOR.red or COLOR.white
  end
  local cargo = items_text(rails.cargo_of(train))
  el.cargo.caption = cargo and {"rts.railgui-cargo", cargo} or {"rts.railgui-cargo-empty"}
  el.resume.enabled = rec.kind == "cargo" and rec.pickup ~= nil and rec.dropoff ~= nil
  return true
end

---------------------------------------------------------------------------
-- Depot panel
---------------------------------------------------------------------------
local function build_depot(player, g, un)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el = frame, {}
  header(frame, {"rts.railgui-depot-title", depot_name(un)})
  g.el.platform = label(frame)
  g.el.stock = label(frame)
  g.el.line = label(frame)
  g.el.detail = label(frame, "rts_hud_dim_label")
  local buttons = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  g.el.deploy = buttons.add({type = "button", name = PREFIX .. "deploy", caption = {"rts.railgui-deploy"},
    style = "rts_hud_button", tooltip = {"rts.railgui-deploy-tooltip"}, tags = {rts_railgui = "deploy", depot = un}})
  label(frame, "rts_hud_dim_label", {"rts.railgui-depot-hint"})
  label(frame, "rts_hud_heading_label", {"rts.railgui-lines"})
  g.el.lines = frame.add({type = "flow", direction = "vertical"})
  place(player, frame, "depot")
end

local function refresh_depot(player, g)
  local d = rails.depot(g.id)
  if not d then return false end
  local el = g.el
  if d.platform then
    el.platform.caption = {"rts.railgui-platform", #d.platform.rails * 2, #d.platform.stops}
    el.platform.style.font_color = COLOR.white
  else
    el.platform.caption = {"rts.railgui-no-platform"}
    el.platform.style.font_color = COLOR.red
  end
  local st = rails.depot_stock(g.id) or {loco = 0, wagon = 0, cwagon = 0, rails = 0, coal = 0}
  el.stock.caption = {"rts.railgui-stock", st.loco, st.wagon, st.cwagon, st.rails, st.coal}
  local line = d.line and rails.lines[d.line]
  el.line.caption = line_caption(line)
  el.line.style.font_color = line and LINE_COLOR[line.state] or COLOR.white
  if line and line.pieces then
    el.detail.caption = {"rts.railgui-line-detail", #line.pieces, line.missing or 0, line.bill and line.bill.supports or 0,
                         line.bill and line.bill.signals or 0, line.wait and {"rts.rails-why-" .. line.wait} or ""}
  else
    el.detail.caption = ""
  end
  local need = rails.kit_list("cargo")
  el.deploy.enabled = d.platform ~= nil and st.loco >= need[1][2] and st.wagon >= need[2][2]
  local lines = rails.lines_of(d.force)
  el.lines.clear()
  if #lines == 0 then
    label(el.lines, "rts_hud_dim_label", {"rts.railgui-no-lines"})
  end
  for i = 1, math.min(#lines, 6) do
    local l = label(el.lines, "rts_hud_label", line_caption(lines[i]))
    l.style.font_color = LINE_COLOR[lines[i].state] or COLOR.white
  end
  return true
end

---------------------------------------------------------------------------
-- Show / refresh
---------------------------------------------------------------------------
local function show(player, force_rebuild)
  local g = pstate(player.index)
  local key, kind, id = wanted(player)
  if g.closed and g.closed ~= key then g.closed = nil end
  if not key or g.closed == key then
    if g.frame then destroy(g) end
    return
  end
  if force_rebuild or g.key ~= key or not (g.frame and g.frame.valid) then
    destroy(g)
    if kind == "train" then build_train(player, g, id) else build_depot(player, g, id) end
    if not g.frame then return end
    g.key, g.kind, g.id = key, kind, id
    util.log("railgui: %s panel for %d player=%d", kind, id, player.index)
  end
  local ok = (kind == "train") and refresh_train(player, g) or refresh_depot(player, g)
  if not ok then destroy(g) end
end

function railgui.refresh(player_index, force_rebuild)
  local player = game.get_player(player_index)
  if player and player.connected then show(player, force_rebuild) end
end

events.on_nth_tick(POLL_PERIOD, function(e)
  if not storage.rails then return end
  for _, player in pairs(game.connected_players) do
    local g = storage.players and storage.players[player.index] and storage.players[player.index].railgui
    local key = wanted(player)
    if g and g.closed and key ~= g.closed then g.closed = nil end
    if (g and g.key) ~= key or (key and e.tick % REFRESH_PERIOD == 0) or (g and g.frame and not g.frame.valid) then
      show(player)
    end
  end
end)

events.on(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local action = element.tags.rts_railgui
  local player = game.get_player(e.player_index)
  local g = pstate(e.player_index)
  if action == "close" then
    g.closed = g.key
    destroy(g)
    return
  end
  if action == "resume" then
    local rec = g.id and rails.train_record(g.id)
    local train = rec and rails.train_of(rec)
    local ok = train and rails.resume(train)
    util.log("railgui click resume train=%s ok=%s player=%d", tostring(g.id), tostring(ok), e.player_index)
  elseif action == "deploy" then
    local train, why = rails.create_train(element.tags.depot, "cargo")
    util.log("railgui click deploy depot=#%s train=%s (%s) player=%d", tostring(element.tags.depot),
      tostring(train and train.id), tostring(why), e.player_index)
    if not train and player then player.print({"rts.railgui-deploy-failed", {"rts.rails-why-" .. tostring(why)}}) end
  else
    return
  end
  if player then show(player) end
end)

local function reposition(e)
  local player = game.get_player(e.player_index)
  local g = player and pstate(player.index)
  if g and g.frame and g.frame.valid then place(player, g.frame, g.kind) end
end
events.on(defines.events.on_player_display_resolution_changed, reposition)
events.on(defines.events.on_player_display_scale_changed, reposition)

function railgui.init()
  for _, p in pairs(storage.players or {}) do
    if p.railgui then
      if p.railgui.frame and p.railgui.frame.valid then p.railgui.frame.destroy() end
      p.railgui = {}
    end
  end
end

return railgui
