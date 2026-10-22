-- Phase 5 M3 air panel (docs/PHASE5-M3.md section 1 "GUI": Y; docs/qa/phase5-air-notes.md). Nation mode only. Y (custom
-- input rts-airfield-panel through hud.lua's key table P4.KEYS) toggles it.
--
--   airfields  one row per airfield of the player's force: its city, the planes on its apron, a Show button (camera)
--   planes     one row per plane kind: total, flying, returning, rearming, mean supply
--   selection  the selected planes and their supply range, and two buttons: Patrol (arms it: the next right click is
--              the centre of a patrol circle, scripts/air.lua air.order_patrol / patrol_units) and Return (they fly to
--              the nearest airfield and rearm)
--   hint       the supply rule
-- 500 GUI units wide at the right edge under the minimap. Refreshed every REFRESH ticks while open. Owns util.pstorage(i).air_gui = {gui = {...}, armed = tick?}.
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local camera = require("scripts.camera")
local air = require("scripts.air")
local balance = require("balance")

local airgui = {}

airgui.FRAME = "rts_airfield_panel"
airgui.REFRESH = 60
airgui.WIDTH = 500
airgui.ARM_TICKS = 30 * 60 -- an armed patrol is forgotten after this long
airgui.TOP = 282 -- Phase 5 M3 integration: GUI units from the top (minimap 244 + the world generation line)
local A = balance.nation.air
local GREY = {r = 0.7, g = 0.7, b = 0.7}
local YELLOW = {r = 1, g = 0.85, b = 0.3}
local WHITE = {r = 1, g = 1, b = 1}
local COLS = {"kind", "total", "flying", "returning", "rearming", "supply"}

local function pstate(player_index)
  local ps = util.pstorage(player_index)
  ps.air_gui = ps.air_gui or {}
  return ps.air_gui
end

local function visible_for(player)
  return air.nation() and not match.in_lobby() and player.force ~= nil and match.is_participant(player.force.name)
end

-- The selected planes of a player: unit records, sorted.
local function selected_planes(player_index)
  local out = {}
  for _, e in ipairs(selection.get(player_index)) do
    if air.is_plane(e) then
      local rec = storage.units[e.unit_number]
      if rec then out[#out + 1] = rec end
    end
  end
  table.sort(out, function(a, b) return a.entity.unit_number < b.entity.unit_number end)
  return out
end

local function city_name(force, position)
  local id = territory.city_at(position)
  local c = id and cities.get(id)
  if c and c.force == force then return cities.display_name(c) end
  return {"rts-air.no-city"}
end

---------------------------------------------------------------------------
-- Build and refresh
---------------------------------------------------------------------------
function airgui.close(player)
  local f = player.gui.screen[airgui.FRAME]
  if f then f.destroy() end
  local ps = pstate(player.index)
  ps.gui, ps.armed = nil, nil
end

function airgui.open(player)
  if not visible_for(player) then return nil end
  local screen = player.gui.screen
  if screen[airgui.FRAME] then screen[airgui.FRAME].destroy() end
  local ps = pstate(player.index)
  local frame = screen.add({type = "frame", name = airgui.FRAME, direction = "vertical"})
  frame.style.width = airgui.WIDTH
  local bar = frame.add({type = "flow", direction = "horizontal"})
  bar.drag_target = frame
  bar.add({type = "label", caption = {"rts-air.title"}, style = "frame_title", ignored_by_interaction = true})
  local drag = bar.add({type = "empty-widget", style = "draggable_space_header"})
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  bar.add({type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
           tooltip = {"rts-air.close"}, tags = {rts_air = "close"}})
  local box = frame.add({type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"})
  box.style.horizontally_stretchable = true
  local inner = box.add({type = "flow", direction = "vertical"}) -- a frame style has no vertical_spacing
  inner.style.vertical_spacing = 6
  local g = {}
  g.fields_head = inner.add({type = "label", caption = "", style = "caption_label"})
  g.fields = inner.add({type = "table", column_count = 3})
  g.fields.style.horizontal_spacing = 12
  g.planes_head = inner.add({type = "label", caption = {"rts-air.planes"}, style = "caption_label"})
  g.planes = inner.add({type = "table", column_count = #COLS})
  g.planes.style.horizontal_spacing = 10
  g.sel = inner.add({type = "label", caption = ""})
  g.sel.style.single_line = false
  g.sel.style.maximal_width = airgui.WIDTH - 40
  local row = inner.add({type = "flow", direction = "horizontal"})
  row.style.horizontal_spacing = 8
  g.patrol = row.add({type = "button", caption = {"rts-air.patrol"}, tags = {rts_air = "patrol"},
                      tooltip = {"rts-air.patrol-tooltip", A.patrol.radius}})
  g.ret = row.add({type = "button", caption = {"rts-air.return"}, tags = {rts_air = "return"},
                   tooltip = {"rts-air.return-tooltip"}})
  local hint = inner.add({type = "label", caption = {"rts-air.hint", A.supply.max, A.supply.drain, A.supply.refill,
                                                     A.supply.range, A.supply.return_at}})
  hint.style.single_line = false
  hint.style.maximal_width = airgui.WIDTH - 40
  hint.style.font_color = GREY
  ps.gui = g
  -- right edge, under the HUD's minimap (8 + 228 + 8 GUI units from the top): the map centre stays visible
  -- Phase 5 M3 integration: and under the "World: N % generated" line (rts_worldgen_progress, about 36 units more)
  local res, scale = player.display_resolution, player.display_scale
  frame.location = {math.max(0, math.floor(res.width - (airgui.WIDTH + 8) * scale)), math.floor(airgui.TOP * scale)}
  airgui.refresh(player)
  util.log("air: panel opened player=%d", player.index)
  return frame
end

function airgui.toggle(player)
  if player.gui.screen[airgui.FRAME] then
    airgui.close(player)
    return false
  end
  if not visible_for(player) then
    player.print({"rts-air.panel-nation-only"})
    return false
  end
  return airgui.open(player) ~= nil
end

local function fmt_supply(v) return string.format("%.0f", v) end

function airgui.refresh(player)
  local ps = pstate(player.index)
  local g = ps.gui
  if not (g and g.fields and g.fields.valid) then return end
  local f = player.force.name
  local planes = air.planes(f)
  -- airfields
  local fields = air.airfields(f)
  g.fields_head.caption = {"rts-air.airfields", #fields}
  g.fields.clear()
  if #fields == 0 then
    local l = g.fields.add({type = "label", caption = {"rts-air.no-airfield"}})
    l.style.single_line = false
    l.style.maximal_width = airgui.WIDTH - 40
    l.style.font_color = YELLOW
  else
    for _, e in ipairs(fields) do
      local n = 0
      for un, p in pairs(planes) do
        local rec = storage.units[un]
        if rec and rec.entity.valid and util.distance_sq(rec.entity.position, e.position) <= A.supply.range ^ 2 then
          n = n + 1
        end
      end
      g.fields.add({type = "label", caption = {"", "[entity=rts-airfield] ", city_name(f, e.position)}})
      g.fields.add({type = "label", caption = {"rts-air.apron", n}})
      g.fields.add({type = "button", caption = {"rts-air.show"}, tags = {rts_air = "show", un = e.unit_number},
                    style = "rts_hud_button"})
    end
  end
  -- planes by kind
  g.planes.clear()
  for _, key in ipairs(COLS) do
    local head = g.planes.add({type = "label", caption = {"rts-air.col-" .. key}})
    head.style.font_color = GREY
  end
  for _, name in ipairs(A.planes) do
    local n, sum = 0, 0
    local st = {flying = 0, returning = 0, rearming = 0}
    for _, p in pairs(planes) do
      if p.name == name then
        n, sum = n + 1, sum + p.supply
        st[p.state] = (st[p.state] or 0) + 1
      end
    end
    g.planes.add({type = "label", caption = {"", "[entity=" .. name .. "] ", {"entity-name." .. name}}})
    g.planes.add({type = "label", caption = tostring(n)})
    g.planes.add({type = "label", caption = tostring(st.flying)})
    g.planes.add({type = "label", caption = tostring(st.returning)})
    g.planes.add({type = "label", caption = tostring(st.rearming)})
    g.planes.add({type = "label", caption = n > 0 and fmt_supply(sum / n) or "-"})
  end
  -- selection
  local sel = selected_planes(player.index)
  if #sel == 0 then
    g.sel.caption = {"rts-air.selected-none"}
  else
    local lo, hi = math.huge, -math.huge
    for _, rec in ipairs(sel) do
      local v = air.supply(rec.entity.unit_number) or A.supply.max
      lo, hi = math.min(lo, v), math.max(hi, v)
    end
    g.sel.caption = {"rts-air.selected", #sel, fmt_supply(lo), fmt_supply(hi)}
  end
  g.patrol.enabled = #sel > 0
  g.ret.enabled = #sel > 0
  local armed = ps.armed and game.tick - ps.armed < airgui.ARM_TICKS
  if not armed then ps.armed = nil end
  g.patrol.caption = armed and {"rts-air.patrol-armed"} or {"rts-air.patrol"}
  g.patrol.style.font_color = armed and YELLOW or WHITE
end

--- The HUD's building page lines of an airfield or an AA turret (scripts/hud.lua update_other): el.b_line1..3.
function airgui.building_lines(el, rec)
  local e = rec.entity
  if rec.kind == A.airfield.kind then
    local n, rearming = 0, 0
    for un, p in pairs(air.planes(rec.force)) do
      local urec = storage.units[un]
      if urec and urec.entity.valid and util.distance_sq(urec.entity.position, e.position) <= A.supply.range ^ 2 then
        n = n + 1
        if p.state == "rearming" then rearming = rearming + 1 end
      end
    end
    el.b_line1.caption = {"rts-air.airfield-line", city_name(rec.force, e.position)}
    el.b_line2.caption = {"rts-air.airfield-planes", n, rearming, A.supply.range}
    el.b_line3.caption = {"rts-air.airfield-hint"}
  else
    local ammo = e.get_inventory(defines.inventory.turret_ammo)
    local n = ammo and ammo.get_item_count("firearm-magazine") or 0
    el.b_line1.caption = {"rts-air.aa-ammo", n}
    el.b_line2.caption = {"rts-air.aa-hint"}
  end
end

---------------------------------------------------------------------------
-- Patrol and return for a player's selection
---------------------------------------------------------------------------
--- The selected planes patrol `position`: an air division whose every member is selected patrols as a division
--- (air.order_patrol), the rest as loose planes. Returns the number of planes.
function airgui.patrol_selection(player_index, position, radius)
  local sel = selected_planes(player_index)
  if #sel == 0 then return 0 end
  local by_div, loose, ids = {}, {}, {}
  for _, rec in ipairs(sel) do
    local id = divisions.of_unit(rec.entity.unit_number)
    if id then
      if not by_div[id] then
        by_div[id] = {}
        ids[#ids + 1] = id
      end
      local t = by_div[id]
      t[#t + 1] = rec
    else
      loose[#loose + 1] = rec
    end
  end
  table.sort(ids)
  local n = 0
  for _, id in ipairs(ids) do
    local D = divisions.get(id)
    if D and #by_div[id] >= table_size(D.units) then
      n = n + air.order_patrol(id, position, radius)
    else
      for _, rec in ipairs(by_div[id]) do loose[#loose + 1] = rec end
    end
  end
  if #loose > 0 then n = n + air.patrol_units(loose, position, radius) end
  util.log("order patrol n=%d dest=%s player=%d", n, util.pos_str(position), player_index)
  return n
end

function airgui.return_selection(player_index)
  local n = air.return_units(selected_planes(player_index))
  util.log("order return-to-airfield n=%d player=%d", n, player_index)
  return n
end

-- An armed patrol takes the player's next right click (ahead of the hauler and Commander hooks).
orders.on_right_click(function(player_index, position)
  local ps = storage.players and storage.players[player_index] and storage.players[player_index].air_gui
  if not (ps and ps.armed) then return nil end
  ps.armed = nil
  if game.tick - (ps.armed_tick or 0) > airgui.ARM_TICKS then return nil end
  local n = airgui.patrol_selection(player_index, position)
  if n == 0 then return nil end
  local player = player_index > 0 and game.get_player(player_index) -- 0: the autotest's fake player
  if player then airgui.refresh(player) end
  return "patrol", n
end, true)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
events.on(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.rts_air) then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  local action = el.tags.rts_air
  local ps = pstate(player.index)
  if action == "close" then
    airgui.close(player)
    return
  elseif action == "show" then
    local rec = storage.buildings and storage.buildings[el.tags.un]
    if rec and rec.entity.valid then camera.jump_to(player, rec.entity.position) end
  elseif action == "patrol" then
    if ps.armed then
      ps.armed = nil
    elseif #selected_planes(player.index) > 0 then
      ps.armed, ps.armed_tick = game.tick, game.tick
      player.create_local_flying_text({text = {"rts-air.patrol-armed"}, create_at_cursor = true})
      util.log("air: patrol armed player=%d", player.index)
    end
  elseif action == "return" then
    airgui.return_selection(player.index)
  end
  airgui.refresh(player)
end)

events.on_nth_tick(airgui.REFRESH, function()
  for _, player in pairs(game.connected_players) do
    local ps = util.pstorage(player.index).air_gui
    if ps and ps.gui then
      if visible_for(player) then airgui.refresh(player) else airgui.close(player) end
    end
  end
end)

return airgui
