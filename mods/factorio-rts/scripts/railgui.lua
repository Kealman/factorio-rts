-- Phase 5 M1 rail panels (docs/PHASE5-M1.md section 3 "rails.lua / railgui.lua"; docs/qa/phase5-rails-notes.md).
--
-- Train panel: shown while a train (any locomotive or wagon, buildings kind "train") is selected, where the hub panel
-- sits (right side, below the HUD minimap): kind and number, health and fuel, state, cargo, deliveries, the line, a
-- "Resume" button. 0.1.2 (#31 part B): instead of pickup -> drop-off, the ordered stop list of scripts/railroutes.lua
-- (right-click a depot adds a stop, Shift inserts after the selected one; a loop checkbox), the editor of the selected
-- stop (up / down / remove / clear; unload and load policies with item lists from scripts/itempicker.lua; troops,
-- bombard; the wait condition) and the line "Stop 3 of 4: Depot 2, loading iron 120 / 400". The stop rows are rebuilt
-- only when the list's structure changes (railgui sig), so a count being typed keeps its focus.
-- Depot panel: shown left of the hub panel while a depot is selected: platform (tiles and carriages it holds) and the
-- platform length of new depots, rails / coal in its network, its line (state, length, bill, missing pieces), the
-- force's line list and the hint for laying a line (right-click another depot). 0.1.2 (#32): the train builder: a
-- preset / template drop-down, the composition (click: select, right click: remove; Left / Right / Remove / Reverse
-- for the selected carriage; a carriage whose kit the network lacks shows red), the palette of carriage kinds with the
-- network's kit counts (click: add at the end, Shift: after the selected one), the rule lines and Deploy, a template
-- name with Save / Delete. The train panel of a train standing on an own depot platform gets a carriage row: couple a
-- carriage at the rear, Remove rear.
-- Follows the selection by polling every POLL_PERIOD ticks, refreshes every REFRESH_PERIOD ticks, like hubgui.lua.
-- Owns storage.players[i].railgui = {key, frame, el = {...}, closed = key?}. Element names start with "rts_railgui_".
local util = require("scripts.util")
local events = require("scripts.events")
local selection = require("scripts.selection")
local logistics = require("scripts.logistics")
local rails = require("scripts.rails")
local railroutes = require("scripts.railroutes") -- 0.1.2 (#31 part B)
local itempicker = require("scripts.itempicker") -- 0.1.2 (#31 part B): items of a stop's policy

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
-- Phase 5 M3 war2: artillery trains, stances and armoured stock (scripts/trainswar.lua loads later)
local function trainswar()
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/trainswar.lua"] or l["scripts.trainswar"]
end

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
  -- 0.1.3 (#34): the panel stops above the Build menu (the right column below it), not over it
  local build = player.gui.screen["rts_hud_build"]
  if build and build.valid and build.visible then
    frame.style.maximal_height = math.max(200, math.floor((build.location.y - frame.location.y) / s) - MARGIN)
  end
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
local build_carriages, refresh_carriages -- 0.1.2 (#32): the train panel's carriage row (below)

-- 0.1.2 (#31 part B): the stop list and the selected stop's editor
local STOP_LIST_HEIGHT = 150
local DROP_WIDTH = 170
local UNLOAD_KEYS = {"none", "keep", "all", "items"}
local LOAD_KEYS = {"none", "exports", "items"}
local TROOP_KEYS = {"none", "board", "unload"}
local WAIT_KEYS = {"inactivity", "full", "empty", "time", "item_count"}

local function index_of(list, v)
  for i, k in ipairs(list) do
    if k == v then return i end
  end
  return 1
end

-- The stop list's structure (what the rows and the editor show apart from typed numbers): the panel is rebuilt when it
-- changes.
local function stops_sig(rec, train, sel)
  local caps = railroutes.caps(train)
  local parts = {tostring(sel or 0), rec.loop == false and "n" or "l", caps.cargo > 0 and "c" or "", caps.troop > 0
                 and "t" or "", caps.artillery > 0 and "a" or ""}
  for _, st in ipairs(rec.stops or {}) do
    local items = {}
    for _, field in ipairs({"unload_items", "load_items"}) do
      local keys = {}
      for item in pairs(st[field] or {}) do keys[#keys + 1] = item end
      table.sort(keys)
      items[#items + 1] = table.concat(keys, ",")
    end
    local w = st.wait or railroutes.DEFAULT_WAIT
    parts[#parts + 1] = table.concat({tostring(st.target or "r"), st.unload or "", st.load or "", st.troops or "",
      st.bombard and "b" or "", w.type, w.item or "", w.cmp or "", items[1], items[2]}, "/")
  end
  return table.concat(parts, "|")
end

local function stop_name(stop)
  if stop.target then
    if rails.depot(stop.target) then return logistics.hub_name(stop.target) end
    return {"rts.route-stop-gone"}
  end
  return {"rts.route-stop-rail", math.floor(stop.x or 0), math.floor(stop.y or 0)}
end

local function wait_text(w)
  w = w or railroutes.DEFAULT_WAIT
  if w.type == "full" or w.type == "empty" then return {"rts.route-wait-" .. w.type .. "-short"} end
  if w.type == "item_count" then
    return {"rts.route-wait-item-short", w.item and ("[item=" .. w.item .. "]") or "?",
            {w.cmp == "<=" and "rts.route-cmp-le-short" or "rts.route-cmp-ge-short"}, w.count or 0}
  end
  return {"rts.route-wait-" .. w.type .. "-short", w.seconds or (w.type == "time" and 60 or 10)}
end

-- "unload to Keep, load exports; idle 10 s"
local function stop_summary(stop)
  local parts = {""}
  local function add(x)
    if #parts > 1 then parts[#parts + 1] = ", " end
    parts[#parts + 1] = x
  end
  if stop.unload then add({"rts.route-unload-" .. stop.unload .. "-short"}) end
  if stop.load then add({"rts.route-load-" .. stop.load .. "-short"}) end
  if stop.troops then add({"rts.route-troops-" .. stop.troops .. "-short"}) end
  if stop.bombard then add({"rts.route-bombard-short"}) end
  if #parts == 1 then add({"rts.route-pass-short"}) end
  parts[#parts + 1] = "; "
  parts[#parts + 1] = wait_text(stop.wait)
  return parts
end

local function row_caption(i, stop, current)
  return {"", current and "→ " or "", {"rts.route-row", i, stop_name(stop)}}
end

local function items_rows(parent, g, rec, i, field, items)
  local keys = {}
  for item in pairs(items or {}) do keys[#keys + 1] = item end
  table.sort(keys)
  for _, item in ipairs(keys) do
    local row = parent.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    row.add({type = "sprite-button", sprite = "item/" .. item, style = "rts_hud_card_button",
      tooltip = prototypes.item[item] and prototypes.item[item].localised_name or item, ignored_by_interaction = true})
    local tf = row.add({type = "textfield", name = PREFIX .. "count_" .. field .. "_" .. item,
      text = tostring(items[item] or 0), numeric = true, allow_decimal = false, allow_negative = false,
      lose_focus_on_confirm = true, style = "short_number_textfield",
      tooltip = {field == "load_items" and "rts.route-load-count-tooltip" or "rts.route-unload-count-tooltip"},
      tags = {rts_railgui = "stop_count", train = rec.id, stop = i, field = field, item = item}})
    tf.style.width = 64
    row.add({type = "button", name = PREFIX .. "item_del_" .. field .. "_" .. item, caption = {"rts.route-item-remove"},
      style = "rts_hud_button", tooltip = {"rts.route-item-remove-tooltip"},
      tags = {rts_railgui = "stop_item_del", train = rec.id, stop = i, field = field, item = item}})
  end
  parent.add({type = "button", name = PREFIX .. "item_add_" .. field, caption = {"rts.route-item-add"},
    style = "rts_hud_button", tooltip = {"rts.route-item-add-tooltip"},
    tags = {rts_railgui = "stop_item_add", train = rec.id, stop = i, field = field}})
end

local function drop(parent, name, keys, prefix, value, tags, tooltip)
  local items = {}
  for k, key in ipairs(keys) do items[k] = {prefix .. key} end
  local dd = parent.add({type = "drop-down", name = PREFIX .. name, items = items,
    selected_index = index_of(keys, value), tags = tags, tooltip = tooltip})
  dd.style.width = DROP_WIDTH
  return dd
end

local function editor(parent, g, rec, train, i)
  local stop = rec.stops[i]
  local caps = railroutes.caps(train)
  local box = parent.add({type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding"})
  box.style.horizontally_stretchable = true
  local row = box.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local function button(name, caption, tip, action, enabled)
    local b = row.add({type = "button", name = PREFIX .. name, caption = {caption}, style = "rts_hud_button",
      tooltip = {tip}, tags = {rts_railgui = action, train = rec.id, stop = i}})
    b.enabled = enabled ~= false
    return b
  end
  button("stop_up", "rts.route-up", "rts.route-up-tooltip", "stop_up", i > 1)
  button("stop_down", "rts.route-down", "rts.route-down-tooltip", "stop_down", i < #rec.stops)
  button("stop_remove", "rts.route-remove", "rts.route-remove-tooltip", "stop_remove")
  if stop.target then
    if caps.cargo > 0 then
      local r1 = box.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
      r1.add({type = "label", style = "rts_hud_label", caption = {"rts.route-unload"}})
      r1.add({type = "empty-widget", style = "rts_hud_filler"})
      drop(r1, "stop_unload", UNLOAD_KEYS, "rts.route-unload-", stop.unload or "none",
        {rts_railgui = "stop_unload", train = rec.id, stop = i}, {"rts.route-unload-tooltip"})
      if stop.unload == "items" then items_rows(box, g, rec, i, "unload_items", stop.unload_items or {}) end
      local r2 = box.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
      r2.add({type = "label", style = "rts_hud_label", caption = {"rts.route-load"}})
      r2.add({type = "empty-widget", style = "rts_hud_filler"})
      drop(r2, "stop_load", LOAD_KEYS, "rts.route-load-", stop.load or "none",
        {rts_railgui = "stop_load", train = rec.id, stop = i}, {"rts.route-load-tooltip"})
      if stop.load == "items" then items_rows(box, g, rec, i, "load_items", stop.load_items or {}) end
    end
  end
  if caps.troop > 0 then
    local r3 = box.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    r3.add({type = "label", style = "rts_hud_label", caption = {"rts.route-troops"}})
    r3.add({type = "empty-widget", style = "rts_hud_filler"})
    local keys = stop.target and TROOP_KEYS or {"none", "unload"} -- troops board at depots only
    drop(r3, "stop_troops", keys, "rts.route-troops-", stop.troops or "none",
      {rts_railgui = "stop_troops", train = rec.id, stop = i}, {"rts.route-troops-tooltip"})
  end
  if caps.artillery > 0 then
    box.add({type = "checkbox", name = PREFIX .. "stop_bombard", caption = {"rts.route-bombard"},
      state = stop.bombard == true, tooltip = {"rts.route-bombard-tooltip"},
      tags = {rts_railgui = "stop_bombard", train = rec.id, stop = i}})
  end
  local w = stop.wait or railroutes.DEFAULT_WAIT
  local r4 = box.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  r4.add({type = "label", style = "rts_hud_label", caption = {"rts.route-wait"}})
  r4.add({type = "empty-widget", style = "rts_hud_filler"})
  drop(r4, "stop_wait", WAIT_KEYS, "rts.route-wait-", w.type, {rts_railgui = "stop_wait", train = rec.id, stop = i},
    {"rts.route-wait-tooltip"})
  if w.type == "inactivity" or w.type == "time" or w.type == "item_count" then
    local r5 = box.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    if w.type == "item_count" then
      r5.add({type = "sprite-button", name = PREFIX .. "wait_item", sprite = w.item and ("item/" .. w.item) or nil,
        style = "rts_hud_card_button", tooltip = {"rts.route-wait-item-tooltip"},
        tags = {rts_railgui = "stop_wait_item", train = rec.id, stop = i}})
      local cmp = r5.add({type = "drop-down", name = PREFIX .. "wait_cmp", items = {{"rts.route-cmp-ge"},
        {"rts.route-cmp-le"}}, selected_index = w.cmp == "<=" and 2 or 1,
        tags = {rts_railgui = "stop_wait_cmp", train = rec.id, stop = i}})
      cmp.style.width = 110
    else
      r5.add({type = "label", style = "rts_hud_label", caption = {"rts.route-wait-seconds"}})
    end
    local value = w.type == "item_count" and (w.count or 0) or (w.seconds or (w.type == "time" and 60 or 10))
    local tf = r5.add({type = "textfield", name = PREFIX .. "wait_value", text = tostring(value), numeric = true,
      allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true, style = "short_number_textfield",
      tags = {rts_railgui = "stop_wait_value", train = rec.id, stop = i}})
    tf.style.width = 64
  end
  return box
end

-- 0.1.3 (#33 items 1 and 2): what the stop list warns about, as a string that changes when the warnings do
local UNREACH_TICKS = 300
local function warnings_sig(unreach, shared)
  local parts = {tostring(shared or "-")}
  for i, j in pairs(unreach) do parts[#parts + 1] = i .. "<" .. j end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function build_stops(frame, g, rec, train)
  local el = g.el
  local head = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  head.add({type = "label", style = "rts_hud_heading_label", caption = {"rts.route-stops"}})
  head.add({type = "empty-widget", style = "rts_hud_filler"})
  head.add({type = "checkbox", name = PREFIX .. "loop", caption = {"rts.route-loop"}, state = rec.loop ~= false,
    tooltip = {"rts.route-loop-tooltip"}, tags = {rts_railgui = "loop", train = rec.id}})
  head.add({type = "button", name = PREFIX .. "stops_clear", caption = {"rts.route-clear"}, style = "rts_hud_button",
    tooltip = {"rts.route-clear-tooltip"}, tags = {rts_railgui = "stops_clear", train = rec.id}})
  local stops = rec.stops or {}
  local sel = g.sel and g.sel[rec.id]
  if sel and not stops[sel] then
    sel = nil
    g.sel[rec.id] = nil
  end
  el.rows = {}
  local unreach = railroutes.unreachable(rec) -- 0.1.3 (#33 item 2)
  local shared = railroutes.shared_with(rec)  -- 0.1.3 (#33 item 1)
  g.warn_sig, g.warn_tick = warnings_sig(unreach, shared), game.tick
  if #stops == 0 then
    label(frame, "rts_hud_dim_label", {"rts.route-empty"})
  else
    local scroll = frame.add({type = "scroll-pane", vertical_scroll_policy = "auto",
      horizontal_scroll_policy = "never"})
    scroll.style.maximal_height = STOP_LIST_HEIGHT
    scroll.style.horizontally_stretchable = true
    for i, stop in ipairs(stops) do
      local b = scroll.add({type = "button", name = PREFIX .. "stop_" .. i, caption = row_caption(i, stop, false),
        style = "rts_hud_tab_button", tooltip = {"", stop_summary(stop), "\n", {"rts.route-row-tooltip"}},
        tags = {rts_railgui = "stop_select", train = rec.id, stop = i}})
      b.style.horizontally_stretchable = true
      b.style.horizontal_align = "left"
      b.toggled = sel == i
      local sum = scroll.add({type = "label", style = "rts_hud_dim_label", caption = stop_summary(stop)})
      sum.style.left_padding = 16
      if unreach[i] then
        local w = scroll.add({type = "label", style = "rts_hud_label", caption = {"rts.route-unreachable", unreach[i]}})
        w.style.left_padding = 16
        w.style.single_line = false
        w.style.maximal_width = WIDTH - 40
        w.style.font_color = COLOR.red
      end
      el.rows[i] = b
    end
  end
  if shared then
    local w = label(frame, "rts_hud_label", {"rts.route-shared", shared})
    w.style.single_line = false
    w.style.font_color = COLOR.yellow
  end
  if sel then editor(frame, g, rec, train, sel) end
  el.status = label(frame)
  label(frame, "rts_hud_dim_label", {"rts.route-hint"})
  g.sig = stops_sig(rec, train, sel)
end

local function status_caption(rec, train)
  local st = railroutes.status(rec, train)
  if st.count == 0 then return {"rts.route-status-empty"} end
  if not st.index then return {"rts.route-status-none", st.count} end
  local name = st.stop and stop_name(st.stop) or "-"
  if rec.dwell and rec.dwell.native then
    if st.item and st.phase then
      return {"rts.route-status-" .. st.phase, st.index, st.count, name, "[item=" .. st.item .. "]", st.done or 0,
              st.want or 0}
    end
    return {"rts.route-status-at", st.index, st.count, name}
  end
  return {"rts.route-status-to", st.index, st.count, name}
end

local function build_train(player, g, id)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el = frame, {}
  local rec = rails.train_record(id)
  local train = rec and rails.train_of(rec)
  g.el.title = header(frame, {"", {rec and rec.kind == "construction" and "rts.railgui-construction-title"
                              or (rec and rec.kind == "troop" and "rts-war.troop-train-title") -- Phase 5 M2 war
                              -- Phase 5 M3 war2: the artillery train
                              or (rec and rec.kind == "artillery" and "rts-war3.artillery-train-title")
                              or "rts.railgui-train-title", id},
                              rec and rec.armoured and {"rts-war3.armoured-suffix"} or ""}) -- Phase 5 M3 war2
  g.el.hp = label(frame, "rts_hud_mono_label")
  g.el.route = label(frame)
  g.el.state = label(frame)
  g.el.cargo = label(frame)
  g.el.delivered = label(frame, "rts_hud_dim_label")
  g.el.line = label(frame, "rts_hud_dim_label")
  local tw = trainswar() -- Phase 5 M3 war2: stance buttons and the gun line of a train with an artillery wagon
  g.el.war = rec and tw and tw.panel_train(frame, rec, WIDTH) or nil
  -- 0.1.2 (#31 part B): every train but a construction crew runs a stop list
  local listed = rec and train and rec.kind ~= "construction"
  if listed then
    g.el.route.visible = false
    build_stops(frame, g, rec, train)
    -- 0.1.2 (#32): on an own depot platform, carriages are coupled at the rear or taken off
    local why = rails.edit_check(train, "remove")
    g.cmode = why ~= "not-on-platform" and why ~= "moving" and why ~= "no-train"
    if g.cmode then build_carriages(frame, g, rec, train) end
  end
  local buttons = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  g.el.resume = buttons.add({type = "button", name = PREFIX .. "resume", caption = {"rts.railgui-resume"},
    style = "rts_hud_button", tooltip = {"rts.railgui-resume-tooltip"}, tags = {rts_railgui = "resume"}})
  -- Phase 5 M2 war: rolling stock back into kits (rails.disband_train)
  g.el.disband = buttons.add({type = "button", name = PREFIX .. "disband", caption = {"rts-war.train-disband"},
    style = "rts_hud_button", tooltip = {"rts-war.train-disband-tooltip"}, tags = {rts_railgui = "disband"}})
  if not listed then
    label(frame, "rts_hud_dim_label", {rec and rec.kind == "artillery" and "rts-war3.artillery-hint" -- Phase 5 M3 war2
                                       or "rts.railgui-train-hint"})
  end
  place(player, frame, "train")
end

local STATE_KEYS = {idle = "rts.rails-train-idle", stopped = "rts.rails-train-stopped",
                    to_pickup = "rts.rails-train-to-pickup", to_dropoff = "rts.rails-train-to-dropoff",
                    loading = "rts.rails-train-loading", unloading = "rts.rails-train-unloading",
                    waiting = "rts.rails-train-waiting", no_path = "rts.rails-train-no-path",
                    to_head = "rts.rails-train-to-head", building = "rts.rails-train-building",
                    returning = "rts.rails-train-returning",
                    -- 0.1.2 (#31 part B): trains on a stop list
                    to_stop = "rts.rails-train-to-stop", at_stop = "rts.rails-train-at-stop",
                    wait_signal = "rts.rails-train-wait-signal", destination_full = "rts.rails-train-destination-full"}

local function refresh_train(player, g)
  local rec = rails.train_record(g.id)
  local train = rec and rails.train_of(rec)
  if not (rec and train) then return false end
  local el = g.el
  -- 0.1.2 (#31 part B): the stop list's structure changed (a stop added by a right click, a policy): rebuild
  if el.rows and stops_sig(rec, train, g.sel and g.sel[rec.id]) ~= g.sig then return "rebuild" end
  -- 0.1.3 (#33): track built or taken up since, another train's list changed: the warnings follow
  if el.rows and game.tick - (g.warn_tick or 0) >= UNREACH_TICKS then
    g.warn_tick = game.tick
    if warnings_sig(railroutes.unreachable(rec), railroutes.shared_with(rec)) ~= g.warn_sig then return "rebuild" end
  end
  -- 0.1.2 (#32): the train came to or left a depot platform, or a carriage was coupled or taken off
  if el.rows then
    local why = rails.edit_check(train, "remove")
    local mode = why ~= "not-on-platform" and why ~= "moving" and why ~= "no-train"
    if mode ~= g.cmode then return "rebuild" end
    if mode and refresh_carriages(g, rec, train) == "rebuild" then return "rebuild" end
  end
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
    local first = rec.stops and rec.stops[1]
    local d = rails.depot(rec.pickup or (first and first.target) or rec.home)
    local line = d and d.line and rails.lines[d.line]
    el.line.caption = line_caption(line)
    el.delivered.caption = {"rts.railgui-delivered", rec.trips or 0, items_text(rec.delivered) or "-"}
  end
  local tw = trainswar() -- Phase 5 M3 war2: the artillery train's states
  local key = STATE_KEYS[rec.state] or (tw and tw.STATE_KEYS[rec.state])
  local state = key and {key} or (rec.state or "-")
  local why = rec.reason or (rec.dwell and rec.dwell.native and rec.dwell.reason)
  if why == "platform-held" then -- 0.1.2 (#31 part A): single track, the hint says it all
    el.state.caption = {"rts.rails-why-platform-held"}
    el.state.style.font_color = COLOR.yellow
  elseif why then
    el.state.caption = {"rts.railgui-state-why", state, {"rts.rails-why-" .. why}}
    el.state.style.font_color = COLOR.yellow
  else
    el.state.caption = {"rts.railgui-state", state}
    el.state.style.font_color = rec.state == "no_path" and COLOR.red or COLOR.white
  end
  local cargo = items_text(rails.cargo_of(train))
  el.cargo.caption = cargo and {"rts.railgui-cargo", cargo} or {"rts.railgui-cargo-empty"}
  if rec.kind == "troop" and rails.troop_text then el.cargo.caption = rails.troop_text(rec) or "" end -- Phase 5 M2 war
  if el.rows then
    local st = railroutes.status(rec, train)
    for i, b in pairs(el.rows) do
      if b.valid and rec.stops[i] then b.caption = row_caption(i, rec.stops[i], st.index == i) end
    end
    if el.status and el.status.valid then el.status.caption = status_caption(rec, train) end
    el.resume.enabled = rec.stops ~= nil and #rec.stops > 0
  else
    el.resume.enabled = (rec.kind == "cargo" or rec.kind == "troop") and rec.pickup ~= nil and rec.dropoff ~= nil
  end
  if el.disband and el.disband.valid then el.disband.enabled = math.abs(train.speed) < 0.001 end -- Phase 5 M2 war
  if tw then tw.panel_train_update(el, el.war, rec, train) end -- Phase 5 M3 war2
  return true
end

---------------------------------------------------------------------------
-- Depot panel
---------------------------------------------------------------------------
-- 0.1.2 (#32): the train builder in the depot panel. The composition being built is per player and depot
-- (g.compose[depot] = {cars, sel, preset}); it starts as the Freight preset.
local SLOT = 28
local function kit_of(name)
  for kit, stock in pairs(rails.KITS) do
    if stock == name then return kit end
  end
  return nil
end

local function compose_state(g, un)
  g.compose = g.compose or {}
  local c = g.compose[un]
  if not c then
    c = {cars = {}, preset = "freight"}
    for i, car in ipairs(rails.PRESETS[1].cars) do c.cars[i] = {name = car.name, reversed = car.reversed} end
    g.compose[un] = c
  end
  return c
end

local function compose_sig(c)
  local parts = {tostring(c.sel or 0)}
  for _, car in ipairs(c.cars) do parts[#parts + 1] = car.name .. (car.reversed and "r" or "") end
  return table.concat(parts, ",")
end

local function car_tooltip(car)
  local proto = prototypes.entity[car.name]
  return {"", proto and proto.localised_name or car.name, car.reversed and {"", " ", {"rts.builder-reversed"}} or "",
          "\n", {"rts.builder-slot-tooltip"}}
end

local function preset_items(force_name)
  local items, keys = {{"rts.builder-preset-choose"}}, {false}
  for _, p in ipairs(rails.PRESETS) do
    items[#items + 1] = {"rts.builder-preset-" .. p.key}
    keys[#keys + 1] = "preset:" .. p.key
  end
  for i, t in ipairs(rails.templates(force_name)) do
    items[#items + 1] = {"rts.builder-template", t.name}
    keys[#keys + 1] = "template:" .. i
  end
  return items, keys
end

local function build_composer(frame, g, un, player)
  local el = g.el
  local c = compose_state(g, un)
  local head = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  head.add({type = "label", style = "rts_hud_heading_label", caption = {"rts.builder-title"}})
  head.add({type = "empty-widget", style = "rts_hud_filler"})
  local items, keys = preset_items(player.force.name)
  g.preset_keys = keys
  local dd = head.add({type = "drop-down", name = PREFIX .. "builder_preset", items = items, selected_index = 1,
    tooltip = {"rts.builder-preset-tooltip"}, tags = {rts_railgui = "builder_preset", depot = un}})
  dd.style.width = 200
  -- the composition
  local row = frame.add({type = "flow", direction = "horizontal"})
  row.style.horizontal_spacing = 2
  el.cars = {}
  for i, car in ipairs(c.cars) do
    local kit = kit_of(car.name)
    local b = row.add({type = "sprite-button", name = PREFIX .. "car_" .. i, sprite = "item/" .. (kit or "rail"),
      style = c.sel == i and "yellow_slot_button" or "slot_button", tooltip = car_tooltip(car),
      tags = {rts_railgui = "builder_car", depot = un, index = i}})
    b.style.size = SLOT
    el.cars[i] = b
  end
  if #c.cars == 0 then label(row, "rts_hud_dim_label", {"rts.builder-empty"}) end
  -- which way each carriage faces (locomotives facing back make the train double-headed)
  if #c.cars > 0 then
    local arrows = {}
    for i, car in ipairs(c.cars) do
      arrows[i] = rails.LOCOS[car.name] and (car.reversed and "←" or "→") or "·"
    end
    label(frame, "rts_hud_dim_label", {"rts.builder-facing", table.concat(arrows, " ")})
  end
  -- the selected carriage
  if c.sel and c.cars[c.sel] then
    local ed = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
    local function button(name, caption, tip, enabled)
      local b = ed.add({type = "button", name = PREFIX .. name, caption = {caption}, style = "rts_hud_button",
        tooltip = {tip}, tags = {rts_railgui = name, depot = un, index = c.sel}})
      b.enabled = enabled ~= false
    end
    button("builder_left", "rts.builder-left", "rts.builder-left-tooltip", c.sel > 1)
    button("builder_right", "rts.builder-right", "rts.builder-right-tooltip", c.sel < #c.cars)
    button("builder_remove", "rts.builder-remove", "rts.builder-remove-tooltip")
    if rails.LOCOS[c.cars[c.sel].name] then
      button("builder_reverse", "rts.builder-reverse", "rts.builder-reverse-tooltip")
    end
  end
  -- the palette: one button per carriage kind, the kit count of the depot network on it
  local pal = frame.add({type = "flow", direction = "horizontal"})
  pal.style.horizontal_spacing = 2
  el.palette = {}
  for _, name in ipairs(rails.CARRIAGES) do
    local kit = kit_of(name)
    local proto = prototypes.entity[name]
    if kit and proto and prototypes.item[kit] then
      local b = pal.add({type = "sprite-button", name = PREFIX .. "pal_" .. name, sprite = "item/" .. kit,
        style = "slot_button", tooltip = {"rts.builder-palette-tooltip", proto.localised_name,
        prototypes.item[kit].localised_name}, tags = {rts_railgui = "builder_add", depot = un, car = name}})
      b.style.size = SLOT + 4
      el.palette[name] = {button = b, kit = kit}
    end
  end
  el.builder_info = label(frame, "rts_hud_dim_label")
  el.builder_why = label(frame)
  local brow = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  el.deploy = brow.add({type = "button", name = PREFIX .. "deploy", caption = {"rts.builder-deploy"},
    style = "rts_hud_button", tooltip = {"rts.builder-deploy-tooltip"}, tags = {rts_railgui = "deploy", depot = un}})
  local trow = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  local tf = trow.add({type = "textfield", name = PREFIX .. "builder_name", text = g.tname or "",
    tooltip = {"rts.builder-name-tooltip"}, tags = {rts_railgui = "builder_name"}, lose_focus_on_confirm = true})
  tf.style.width = 110
  trow.add({type = "button", name = PREFIX .. "builder_save", caption = {"rts.builder-save"}, style = "rts_hud_button",
    tooltip = {"rts.builder-save-tooltip", rails.MAX_TEMPLATES}, tags = {rts_railgui = "builder_save", depot = un}})
  local del = trow.add({type = "button", name = PREFIX .. "builder_delete", caption = {"rts.builder-delete"},
    style = "rts_hud_button", tooltip = {"rts.builder-delete-tooltip"},
    tags = {rts_railgui = "builder_delete", depot = un}})
  del.enabled = g.template_pick ~= nil
  label(frame, "rts_hud_dim_label", {"rts.builder-hint"})
  g.csig = compose_sig(c)
end

local function refresh_composer(player, g)
  local el = g.el
  local c = compose_state(g, g.id)
  if compose_sig(c) ~= g.csig then return "rebuild" end
  local net = logistics.hub_network(g.id)
  local why, info = rails.compose_check(g.id, c.cars)
  for name, p in pairs(el.palette or {}) do
    if p.button.valid then p.button.number = net and net.get_item_count(p.kit) or 0 end
  end
  -- a carriage whose kit the network lacks shows red
  local need = {}
  for i, car in ipairs(c.cars) do
    local kit = kit_of(car.name)
    need[kit] = (need[kit] or 0) + 1
    local b = el.cars[i]
    if b and b.valid and c.sel ~= i then
      b.style = (net and kit and net.get_item_count(kit) >= need[kit]) and "slot_button" or "red_slot_button"
      b.style.size = SLOT
    end
  end
  local tiles = info.tiles
  local text = {"", {"rts.builder-info", #c.cars, info.max, tiles, info.locos, info.coal}}
  if info.troop_capacity and info.troop_capacity > 0 then
    text[#text + 1] = {"", "  ", {"rts.builder-troops", info.troop_capacity}}
  end
  el.builder_info.caption = text
  local lines = {""}
  if why then
    local reason = {"rts.rails-why-" .. why}
    if why == "no-kits" then
      local parts = {""}
      local kits = {}
      for kit in pairs(info.missing) do kits[#kits + 1] = kit end
      table.sort(kits)
      for _, kit in ipairs(kits) do
        if #parts > 1 then parts[#parts + 1] = ", " end
        parts[#parts + 1] = {"rts.builder-missing", info.missing[kit], prototypes.item[kit].localised_name}
      end
      reason = {"rts.builder-why-no-kits", parts}
    elseif why == "too-long" then
      reason = {"rts.builder-why-too-long", #c.cars, info.max, tiles}
    elseif why == "no-front-loco" or why == "empty" or why == "no-fuel" then
      reason = {"rts.builder-why-" .. why, info.coal}
    end
    lines[#lines + 1] = reason
  end
  if info.forwards_only and #c.cars > 0 then
    if #lines > 1 then lines[#lines + 1] = "\n" end
    lines[#lines + 1] = {"rts.builder-forwards-only"}
  end
  el.builder_why.caption = lines
  el.builder_why.style.font_color = why and COLOR.red or COLOR.yellow
  el.builder_why.visible = #lines > 1
  el.deploy.enabled = why == nil
  return true
end

local function build_depot(player, g, un)
  local frame = player.gui.screen.add({type = "frame", name = FRAME, direction = "vertical", style = "rts_hud_frame"})
  frame.style.width = WIDTH
  g.frame, g.el = frame, {}
  header(frame, {"rts.railgui-depot-title", depot_name(un)})
  local dd = rails.depot(un)
  if dd and dd.station then -- 0.1.2 (#31 part A): a Station: its stops and what it is for
    g.el.platform = label(frame)
    g.el.station = true
    label(frame, "rts_hud_dim_label", {"rts.station-hint"})
    place(player, frame, "depot")
    return
  end
  g.el.platform = label(frame)
  local prow = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  prow.add({type = "label", style = "rts_hud_dim_label", caption = {"rts.builder-new-depots"},
    tooltip = {"rts.builder-platform-length-tooltip"}})
  prow.add({type = "empty-widget", style = "rts_hud_filler"})
  local lens = {}
  local cur = 2 * rails.platform_pieces(player.force.name)
  local sel = 1
  for i, t in ipairs(rails.PLATFORM_LENGTHS) do
    lens[i] = {"rts.builder-platform-length", t}
    if t == cur then sel = i end
  end
  local pl = prow.add({type = "drop-down", name = PREFIX .. "platform_len", items = lens, selected_index = sel,
    tooltip = {"rts.builder-platform-length-tooltip"}, tags = {rts_railgui = "platform_len"}})
  pl.style.width = 120
  g.el.stock = label(frame, "rts_hud_dim_label")
  g.el.line = label(frame)
  g.el.detail = label(frame, "rts_hud_dim_label")
  build_composer(frame, g, un, player)
  label(frame, "rts_hud_dim_label", {"rts.railgui-depot-hint"})
  label(frame, "rts_hud_heading_label", {"rts.railgui-lines"})
  g.el.lines = frame.add({type = "flow", direction = "vertical"})
  place(player, frame, "depot")
end

local function refresh_depot(player, g)
  local d = rails.depot(g.id)
  if not d then return false end
  local el = g.el
  if el.station then -- 0.1.2 (#31 part A)
    el.platform.caption = d.platform and {"rts.station-stops", #d.platform.stops} or {"rts.station-no-track",
      rails.STATION_REACH}
    el.platform.style.font_color = d.platform and COLOR.white or COLOR.yellow
    return true
  end
  if d.platform then
    local tiles = rails.platform_tiles(d)
    el.platform.caption = {"rts.builder-platform", tiles, rails.max_carriages(tiles), #d.platform.stops}
    el.platform.style.font_color = COLOR.white
  else
    el.platform.caption = {"rts.railgui-no-platform"}
    el.platform.style.font_color = COLOR.red
  end
  local st = rails.depot_stock(g.id) or {rails = 0, coal = 0}
  el.stock.caption = {"rts.builder-stock", st.rails or 0, st.coal or 0}
  local line = d.line and rails.lines[d.line]
  el.line.caption = line_caption(line)
  el.line.style.font_color = line and LINE_COLOR[line.state] or COLOR.white
  if line and line.pieces then
    el.detail.caption = {"rts.railgui-line-detail", #line.pieces, line.missing or 0, line.bill and line.bill.supports or 0,
                         line.bill and line.bill.signals or 0, line.wait and {"rts.rails-why-" .. line.wait} or ""}
  else
    el.detail.caption = ""
  end
  local r = refresh_composer(player, g)
  if r == "rebuild" then return r end
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
  if ok == "rebuild" then -- 0.1.2 (#31 part B, #32): the stop list or the composition changed its structure
    destroy(g)
    if kind == "train" then build_train(player, g, id) else build_depot(player, g, id) end
    if not g.frame then return end
    g.key, g.kind, g.id = key, kind, id
    ok = (kind == "train") and refresh_train(player, g) or refresh_depot(player, g)
  end
  if not ok or ok == "rebuild" then destroy(g) end
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
  elseif player and railgui.builder_click(player, g, action, element, e) then -- 0.1.2 (#32): the train builder
    -- (show below)
  elseif railgui.route_click(player, g, action, element) then -- 0.1.2 (#31 part B): the stop list
    -- (show below)
  elseif action == "disband" then -- Phase 5 M2 war
    local rec = g.id and rails.train_record(g.id)
    local train = rec and rails.train_of(rec)
    local res, why = nil, "no-train"
    if train then res, why = rails.disband_train(train) end
    util.log("railgui click disband train=%s ok=%s (%s) player=%d", tostring(g.id), tostring(res ~= nil),
      tostring(why), e.player_index)
    if not res and player then player.print({"rts-war.train-disband-failed", {"rts-war.disband-why-" .. tostring(why)}}) end
  else
    return
  end
  if player then show(player) end
end)

---------------------------------------------------------------------------
-- 0.1.2 (#31 part B): stop list events
---------------------------------------------------------------------------
-- The train of an element's tags when it is the player's own (record, LuaTrain), or nil.
local function own_train(player, tags)
  local rec = tags and tags.train and rails.train_record(tags.train)
  local train = rec and rails.train_of(rec)
  if not (player and train and train.valid and rec.force == player.force.name) then return nil end
  return rec, train
end

local function stop_items(rec, i, field)
  local st = rec.stops and rec.stops[i]
  local out = {}
  for k, v in pairs(st and st[field] or {}) do out[k] = v end
  return out
end

-- Items a stop's item list offers: the depot network's contents, the hub panel's policy items, raw resources, then
-- the goods cities make.
local function picker_items(rec, i)
  local seen, list = {}, {}
  local function add(name)
    if not seen[name] and prototypes.item[name] and name ~= util.CURSOR_ITEM then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  local st = rec.stops and rec.stops[i]
  local net = st and st.target and logistics.hub_network(st.target)
  if net then
    local names = {}
    for _, item in pairs(net.get_contents()) do names[#names + 1] = item.name end
    table.sort(names)
    for _, name in ipairs(names) do add(name) end
  end
  for _, name in ipairs(logistics.POLICY_ITEMS) do add(name) end
  for _, name in ipairs({"iron-ore", "copper-ore", "stone", "coal", "uranium-ore", "wood"}) do add(name) end
  for _, name in ipairs(itempicker.list()) do add(name) end
  return list
end

--- Shift + right click inserts after this stop (scripts/railroutes.lua asks).
railroutes.selected_stop = function(player_index, train_id)
  local g = storage.players and storage.players[player_index] and storage.players[player_index].railgui
  return g and g.sel and g.sel[train_id] or nil
end

--- Clicks of the stop list and its editor. Returns true when the action was one of them.
function railgui.route_click(player, g, action, element)
  if type(action) ~= "string" or (string.sub(action, 1, 4) ~= "stop" and action ~= "loop") then return false end
  local tags = element.tags
  local rec, train = own_train(player, tags)
  if not rec then return true end
  local i = tags.stop
  g.sel = g.sel or {}
  local ok
  if action == "stop_select" then
    g.sel[rec.id] = (g.sel[rec.id] ~= i) and i or nil
    ok = true
  elseif action == "stop_up" or action == "stop_down" then
    local j = railroutes.move(train, i, action == "stop_up" and -1 or 1)
    if j then g.sel[rec.id] = j end
    ok = j ~= nil
  elseif action == "stop_remove" then
    ok = railroutes.remove(train, i)
    g.sel[rec.id] = nil
  elseif action == "stops_clear" then
    ok = railroutes.clear(train)
    g.sel[rec.id] = nil
  elseif action == "stop_item_add" or action == "stop_wait_item" then
    local loc
    if g.frame and g.frame.valid then
      local sc = player.display_scale
      loc = {math.max(0, g.frame.location.x - math.floor((itempicker.WIDTH + MARGIN) * sc + 0.5)), g.frame.location.y}
    end
    itempicker.open(player, "railgui", {train = rec.id, stop = i, field = tags.field or "wait"}, loc,
      {items = picker_items(rec, i), title = {"rts.route-picker-title"}})
    ok = true
  elseif action == "stop_item_del" then
    local items = stop_items(rec, i, tags.field)
    items[tags.item] = nil
    ok = railroutes.update(train, i, {[tags.field] = items})
  else
    return false
  end
  util.log("railgui click %s train=%d stop=%s ok=%s player=%d", action, rec.id, tostring(i), tostring(ok), player.index)
  return "show"
end

itempicker.on_pick("railgui", function(player, item, ctx)
  local rec, train = own_train(player, ctx)
  if not (rec and ctx.stop and rec.stops and rec.stops[ctx.stop]) then return end
  local ok
  if ctx.field == "wait" then
    local w = {}
    for k, v in pairs(rec.stops[ctx.stop].wait or {}) do w[k] = v end
    w.type, w.item = "item_count", item
    ok = railroutes.update(train, ctx.stop, {wait = w})
  else
    local items = stop_items(rec, ctx.stop, ctx.field)
    if items[item] == nil then
      local proto = prototypes.item[item]
      items[item] = ctx.field == "load_items" and (proto and proto.stack_size or 50) * 10 or 0
    end
    ok = railroutes.update(train, ctx.stop, {[ctx.field] = items})
  end
  util.log("railgui pick %s train=%d stop=%d field=%s ok=%s player=%d", item, rec.id, ctx.stop, tostring(ctx.field),
    tostring(ok), player.index)
  railgui.refresh(player.index)
end)

local DROP_FIELDS = {stop_unload = {"unload", {"none", "keep", "all", "items"}},
                     stop_load = {"load", {"none", "exports", "items"}},
                     stop_troops = {"troops", {"none", "board", "unload"}}}

events.on(defines.events.on_gui_selection_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = element.tags
  local player = game.get_player(e.player_index)
  local rec, train = own_train(player, tags)
  if not rec then return end
  local action, i, ok = tags.rts_railgui, tags.stop, false
  local st = rec.stops and rec.stops[i]
  if not st then return end
  local df = DROP_FIELDS[action]
  if df then
    local keys = df[2]
    if df[1] == "troops" and not st.target then keys = {"none", "unload"} end
    local v = keys[element.selected_index] or "none"
    ok = railroutes.update(train, i, {[df[1]] = v == "none" and railroutes.NONE or v})
  elseif action == "stop_wait" then
    local keys = {"inactivity", "full", "empty", "time", "item_count"}
    local w = {type = keys[element.selected_index] or "inactivity"}
    local old = st.wait or {}
    if w.type == old.type then return end
    if w.type == "inactivity" then w.seconds = 10 elseif w.type == "time" then w.seconds = 60 end
    if w.type == "item_count" then
      w.item = old.item or next(st.load_items or {}) or next(st.unload_items or {})
      w.cmp = st.load and ">=" or "<="
      w.count = old.count or 0
    end
    ok = railroutes.update(train, i, {wait = w})
  elseif action == "stop_wait_cmp" then
    local w = {}
    for k, v in pairs(st.wait or {}) do w[k] = v end
    w.cmp = element.selected_index == 2 and "<=" or ">="
    ok = railroutes.update(train, i, {wait = w})
  else
    return
  end
  util.log("railgui select %s=%d train=%d stop=%d ok=%s player=%d", tostring(action), element.selected_index, rec.id, i,
    tostring(ok), e.player_index)
  railgui.refresh(player.index)
end)

events.on(defines.events.on_gui_text_changed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = element.tags
  local action = tags.rts_railgui
  if action ~= "stop_count" and action ~= "stop_wait_value" then return end
  local player = game.get_player(e.player_index)
  local rec, train = own_train(player, tags)
  local st = rec and rec.stops and rec.stops[tags.stop]
  if not st then return end
  local n = math.max(0, math.floor(tonumber(element.text) or 0))
  local ok
  if action == "stop_count" then
    local items = stop_items(rec, tags.stop, tags.field)
    if items[tags.item] == nil then return end
    items[tags.item] = n
    ok = railroutes.update(train, tags.stop, {[tags.field] = items})
  else
    local w = {}
    for k, v in pairs(st.wait or {}) do w[k] = v end
    if w.type == "item_count" then w.count = n else w.seconds = math.max(1, n) end
    ok = railroutes.update(train, tags.stop, {wait = w})
  end
  util.log("railgui text %s=%d train=%d stop=%d ok=%s player=%d", action, n, rec.id, tags.stop, tostring(ok),
    e.player_index)
end)

events.on(defines.events.on_gui_checked_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = element.tags
  local player = game.get_player(e.player_index)
  local rec, train = own_train(player, tags)
  if not rec then return end
  local ok
  if tags.rts_railgui == "loop" then
    ok = railroutes.set_loop(train, element.state)
  elseif tags.rts_railgui == "stop_bombard" then
    ok = railroutes.update(train, tags.stop, {bombard = element.state})
  else
    return
  end
  util.log("railgui check %s=%s train=%d ok=%s player=%d", tags.rts_railgui, tostring(element.state), rec.id,
    tostring(ok), e.player_index)
  railgui.refresh(player.index)
end)

---------------------------------------------------------------------------
-- 0.1.2 (#32): train builder events (depot panel) and carriage edits (train panel)
---------------------------------------------------------------------------
local function own_depot(player, un)
  local d = un and rails.depot(un)
  return d ~= nil and d.force == player.force.name
end

--- Clicks of the train builder and the train panel's carriage row. Returns true when the action was one of them.
function railgui.builder_click(player, g, action, element, e)
  if type(action) ~= "string" then return false end
  local tags = element.tags
  if string.sub(action, 1, 8) == "builder_" or action == "deploy" then
    local un = tags.depot
    if not own_depot(player, un) then return true end
    local c = compose_state(g, un)
    local i = tags.index
    local note
    if action == "builder_car" then
      if e.button == defines.mouse_button_type.right then
        table.remove(c.cars, i)
        c.sel = nil
        note = "removed " .. i
      else
        c.sel = (c.sel ~= i) and i or nil
      end
    elseif action == "builder_add" then
      local car = {name = tags.car}
      local at = (e.shift and c.sel) and c.sel + 1 or #c.cars + 1
      -- a locomotive added at the end of a train that has one already faces back (double-headed)
      if rails.LOCOS[car.name] and at == #c.cars + 1 and #c.cars > 0 then car.reversed = true end
      if at == #c.cars + 1 and #c.cars > 0 then
        local last = c.cars[#c.cars]
        if rails.LOCOS[last.name] and last.reversed and not rails.LOCOS[car.name] then
          at = #c.cars -- a wagon goes in front of the rear locomotive
        end
      end
      table.insert(c.cars, at, car)
      if e.shift and c.sel then c.sel = at end
      note = "added " .. car.name .. " at " .. at
    elseif action == "builder_left" or action == "builder_right" then
      local j = i + (action == "builder_left" and -1 or 1)
      if c.cars[i] and c.cars[j] then
        c.cars[i], c.cars[j] = c.cars[j], c.cars[i]
        c.sel = j
      end
    elseif action == "builder_remove" then
      if c.cars[i] then table.remove(c.cars, i) end
      c.sel = nil
    elseif action == "builder_reverse" then
      local car = c.cars[i]
      if car and rails.LOCOS[car.name] then car.reversed = (not car.reversed) or nil end
    elseif action == "builder_save" then
      local idx, why = rails.save_template(player.force.name, g.tname, c.cars)
      if not idx then
        player.create_local_flying_text({text = {"rts.builder-save-refused-" .. tostring(why), rails.MAX_TEMPLATES},
          create_at_cursor = true})
      end
      note = "template " .. tostring(idx) .. " " .. tostring(why or "")
      g.csig = nil -- the preset drop-down lists the templates: rebuild
    elseif action == "builder_delete" then
      if g.template_pick then rails.delete_template(player.force.name, g.template_pick) end
      g.template_pick = nil
      g.csig = nil
    elseif action == "deploy" then
      local train, why = rails.create_composed(un, c.cars, {preset = c.preset})
      util.log("railgui click deploy depot=#%d cars=%d train=%s (%s) player=%d", un, #c.cars,
        tostring(train and train.id), tostring(why), player.index)
      if not train then player.print({"rts.railgui-deploy-failed", {"rts.rails-why-" .. tostring(why)}}) end
      return true
    else
      return false
    end
    if action ~= "builder_car" or note then c.preset = nil end
    util.log("railgui click %s depot=#%d index=%s %s player=%d", action, un, tostring(i), note or "", player.index)
    return true
  end
  if action == "train_add" or action == "train_remove" then
    local rec = g.id and rails.train_record(g.id)
    local train = rec and rails.train_of(rec)
    if not (train and rec.force == player.force.name) then return true end
    local ok, why
    if action == "train_add" then ok, why = rails.add_carriage(train, tags.car, rails.LOCOS[tags.car] and true or nil)
    else ok, why = rails.remove_carriage(train) end
    util.log("railgui click %s train=%d car=%s ok=%s (%s) player=%d", action, rec.id, tostring(tags.car), tostring(ok),
      tostring(why), player.index)
    if not ok then
      player.create_local_flying_text({text = {"rts.builder-edit-refused", {"rts.builder-edit-why-" .. tostring(why)}},
        create_at_cursor = true})
    end
    return true
  end
  return false
end

events.on(defines.events.on_gui_selection_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) or string.sub(element.name, 1, #PREFIX) ~= PREFIX then return end
  local tags = element.tags
  local player = game.get_player(e.player_index)
  if not player then return end
  local g = pstate(e.player_index)
  if tags.rts_railgui == "platform_len" then
    local t = rails.PLATFORM_LENGTHS[element.selected_index]
    local ok = t and rails.set_platform_length(player.force.name, t)
    util.log("railgui select platform_len=%s ok=%s player=%d", tostring(t), tostring(ok), e.player_index)
  elseif tags.rts_railgui == "builder_preset" then
    if not own_depot(player, tags.depot) then return end
    local key = g.preset_keys and g.preset_keys[element.selected_index]
    if not key then return end
    local c = compose_state(g, tags.depot)
    local kind, which = string.match(key, "^(%a+):(.+)$")
    local src
    g.template_pick = nil
    if kind == "preset" then
      for _, p in ipairs(rails.PRESETS) do
        if p.key == which then src = p.cars end
      end
    else
      local t = rails.templates(player.force.name)[tonumber(which)]
      src = t and t.cars
      if t then
        g.template_pick = tonumber(which)
        g.tname = t.name
      end
    end
    if not src then return end
    c.cars, c.sel, c.preset = {}, nil, which
    for i, car in ipairs(src) do c.cars[i] = {name = car.name, reversed = car.reversed} end
    util.log("railgui select %s depot=#%d (%d carriages) player=%d", key, tags.depot, #c.cars, e.player_index)
  else
    return
  end
  railgui.refresh(player.index, true)
end)

events.on(defines.events.on_gui_text_changed, function(e)
  local element = e.element
  if not (element and element.valid) or element.name ~= PREFIX .. "builder_name" then return end
  pstate(e.player_index).tname = element.text
end)

-- The train panel's carriage row: the carriages front to back, the palette to couple one at the rear (on an own
-- depot platform), Remove rear.
build_carriages = function(frame, g, rec, train)
  local el = g.el
  local head = frame.add({type = "flow", direction = "horizontal", style = "rts_hud_row"})
  head.add({type = "label", style = "rts_hud_heading_label", caption = {"rts.builder-carriages"}})
  head.add({type = "empty-widget", style = "rts_hud_filler"})
  el.train_remove = head.add({type = "button", name = PREFIX .. "train_remove", caption = {"rts.builder-remove-rear"},
    style = "rts_hud_button", tooltip = {"rts.builder-remove-rear-tooltip"}, tags = {rts_railgui = "train_remove"}})
  local row = frame.add({type = "flow", direction = "horizontal"})
  row.style.horizontal_spacing = 2
  for _, c in ipairs(train.carriages) do
    local kit = kit_of(c.name)
    local b = row.add({type = "sprite-button", sprite = "item/" .. (kit or "rail"), style = "slot_button",
      tooltip = c.localised_name, ignored_by_interaction = true})
    b.style.size = SLOT - 4
  end
  local pal = frame.add({type = "flow", direction = "horizontal"})
  pal.style.horizontal_spacing = 2
  el.train_palette = {}
  for _, name in ipairs(rails.CARRIAGES) do
    local kit = kit_of(name)
    local proto = prototypes.entity[name]
    if kit and proto and prototypes.item[kit] then
      local b = pal.add({type = "sprite-button", name = PREFIX .. "tpal_" .. name, sprite = "item/" .. kit,
        style = "slot_button", tooltip = {"rts.builder-couple-tooltip", proto.localised_name},
        tags = {rts_railgui = "train_add", car = name}})
      b.style.size = SLOT - 4
      el.train_palette[name] = b
    end
  end
  el.edit_why = label(frame, "rts_hud_dim_label")
  g.ncars = #train.carriages
end

refresh_carriages = function(g, rec, train)
  local el = g.el
  if not el.edit_why then return true end
  if #train.carriages ~= g.ncars then return "rebuild" end
  local why = rails.edit_check(train, "remove")
  if el.train_remove.valid then el.train_remove.enabled = why == nil end
  local add_why = rails.edit_check(train, "add", rails.WAGON)
  local base = (add_why == "no-kits") and nil or add_why
  for _, b in pairs(el.train_palette) do
    if b.valid then b.enabled = base == nil end
  end
  if el.edit_why.valid then
    el.edit_why.caption = base and {"rts.builder-edit-why", {"rts.builder-edit-why-" .. base}} or {"rts.builder-edit-hint"}
  end
  return true
end

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
