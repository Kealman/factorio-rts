-- Per-player unit selection, selection boxes and control groups (docs/PHASE1.md).
--
-- Owns these storage.players[i] fields:
--   selection     {[unit_number] = true}                  the selected units
--   groups        {[1..5] = {[unit_number] = true}}       control groups
--   boxes         {[unit_number] = LuaRenderObject}       one rectangle per selected unit, shown to that player
--   group_recall  {n = group, tick = tick}                last recall (double tap = jump the camera)
-- and storage.selection = {dirty = {[player_index] = true}} (HUD refreshes deferred to the next tick).
--
-- Input model (spike decision 10): the rts-cursor selection tool raises on_player_selected_area for a left
-- drag or click (replace the selection) and on_player_alt_selected_area for shift + left (add to it). Only
-- live units from storage.units on the player's own force are taken; anything else in the event's entity
-- list is ignored. A click (an area under CLICK_SIZE) takes the one own unit nearest to the click.
--
-- The player index does not have to belong to a real player: the headless autotest drives index 0, whose
-- force is rts-player, whose boxes are created invisible and whose changes never reach the HUD.
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local camera = require("scripts.camera")

local selection = {}

selection.MAX_GROUPS = 5

local DOUBLE_TAP_TICKS = 20  -- two recalls of the same group within this many ticks jump the camera to it
local CLICK_SIZE = 0.1       -- tiles; a smaller area is a click, not a drag
local BOX_PAD = 0            -- tiles added around the selection box (0: walker boxes stay apart on a 3-tile grid)
local BOX_WIDTH = 2          -- pixels
local BOX_LIGHTEN = 0.35     -- mix the force colour with white so the box stands out on tinted units
local DEFAULT_COLOR = {r = 0.3, g = 1, b = 0.3, a = 1}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- The LuaPlayer behind an index, or nil for the autotest's fake index 0 (and unknown indices).
local function real_player(player_index)
  if not player_index or player_index < 1 then return nil end
  return game.get_player(player_index)
end
selection.real_player = real_player

--- Force whose units this player index may select. The fake autotest index plays rts-player.
function selection.force_name(player_index)
  local player = real_player(player_index)
  return player and player.force.name or util.PLAYER_FORCE
end

local function state(player_index)
  local p = util.pstorage(player_index)
  p.selection = p.selection or {}
  p.groups = p.groups or {}
  p.boxes = p.boxes or {}
  return p
end

-- hud.lua requires this module, so it cannot be required from here (and require() is not allowed inside
-- event handlers). It is loaded by the time any event runs. Factorio keys package.loaded by the resolved
-- file path, "__factorio-rts__/scripts/hud.lua", not by the require() argument (checked in a headless run).
local HUD_KEY = "__" .. script.mod_name .. "__/scripts/hud.lua"
local function hud_module()
  local loaded = package and package.loaded
  return loaded and (loaded[HUD_KEY] or loaded["scripts.hud"])
end

--- Ask the HUD to redraw a real player's panel now (no-op for the fake index or a HUD without refresh).
function selection.notify_hud(player_index)
  if not real_player(player_index) then return end
  local s = storage.selection
  if s and s.dirty then s.dirty[player_index] = nil end
  local hud = hud_module()
  if hud and hud.refresh then hud.refresh(player_index) end
end

-- storage.selection, created on first use (a save made with an older build of this module has none).
local function sstate()
  local s = storage.selection
  if not s then
    s = {}
    storage.selection = s
  end
  s.dirty = s.dirty or {}
  return s
end

-- Deaths can remove many units in one tick; their HUD refreshes are batched into the next tick.
local function mark_dirty(player_index)
  if real_player(player_index) then sstate().dirty[player_index] = true end
end

-- Drop units that died or left the registry from a set. Returns true if anything was removed.
local function prune(set)
  local removed = false
  for un in pairs(set) do
    if not units.get(un) then
      set[un] = nil
      removed = true
    end
  end
  return removed
end

-- The force colour lightened towards white (no module-level cache: render objects are game state, so the
-- colour must come from game state every time).
local function box_color(force_name)
  local force = game.forces[force_name]
  local base = (force and force.custom_color) or (force and force.color) or DEFAULT_COLOR
  local k = BOX_LIGHTEN
  return {r = base.r + (1 - base.r) * k, g = base.g + (1 - base.g) * k, b = base.b + (1 - base.b) * k, a = 1}
end

--- Offsets (relative to the entity position) of the rectangle drawn around a selected unit. Taken from
--- the entity's current world selection box, which for spider-units sits around the raised torso (walker
--- about 1.5 tiles above its position, heavy about 0.7), so the box matches the vanilla hover highlight.
function selection.box_offsets(entity)
  local box, pos = entity.selection_box, entity.position
  local lt, rb = box.left_top, box.right_bottom
  return {lt.x - pos.x - BOX_PAD, lt.y - pos.y - BOX_PAD}, {rb.x - pos.x + BOX_PAD, rb.y - pos.y + BOX_PAD}
end

local function draw_box(player_index, rec)
  local entity = rec.entity
  local lt, rb = selection.box_offsets(entity)
  local player = real_player(player_index)
  return rendering.draw_rectangle({
    color = box_color(rec.force),
    width = BOX_WIDTH,
    filled = false,
    left_top = {entity = entity, offset = lt},
    right_bottom = {entity = entity, offset = rb},
    surface = entity.surface,
    players = player and {player_index} or nil,
    visible = player ~= nil, -- the fake autotest index still exercises the call, but nobody sees it
  })
end

-- Make the boxes match the selection: destroy boxes of deselected units, draw missing ones.
local function sync_boxes(player_index, p)
  local boxes, sel = p.boxes, p.selection
  for un, obj in pairs(boxes) do
    if not sel[un] or not obj.valid then
      if obj.valid then obj.destroy() end
      boxes[un] = nil
    end
  end
  for un in pairs(sel) do
    if not boxes[un] then
      local rec = units.get(un)
      if rec then boxes[un] = draw_box(player_index, rec) end
    end
  end
end

-- Common tail of every selection change: drop dead units, redraw boxes, refresh the HUD.
local function changed(player_index)
  local p = state(player_index)
  prune(p.selection)
  sync_boxes(player_index, p)
  selection.notify_hud(player_index)
end

-- Unit numbers of the live, registered units in `entities` that belong to the player's force.
local function own_unit_numbers(player_index, entities)
  local force = selection.force_name(player_index)
  local out = {}
  for _, entity in pairs(entities) do
    if entity.valid then
      local un = entity.unit_number
      local rec = un and units.get(un)
      if rec and rec.force == force then out[#out + 1] = un end
    end
  end
  return out
end

local function set_from_list(list)
  local set = {}
  for _, un in pairs(list) do set[un] = true end
  return set
end

local function copy_set(set)
  local out = {}
  for k in pairs(set) do out[k] = true end
  return out
end

---------------------------------------------------------------------------
-- Public API (also used by hud.lua, orders.lua and the autotest)
---------------------------------------------------------------------------

--- Replace the selection with the player's own RTS units among `entities` (array of LuaEntity).
--- Returns the new selection size.
function selection.set(player_index, entities)
  local p = state(player_index)
  p.selection = set_from_list(own_unit_numbers(player_index, entities))
  changed(player_index)
  return table_size(p.selection)
end

--- Add the player's own RTS units among `entities` to the selection. Returns the new selection size.
function selection.add(player_index, entities)
  local p = state(player_index)
  for _, un in pairs(own_unit_numbers(player_index, entities)) do p.selection[un] = true end
  changed(player_index)
  return table_size(p.selection)
end

--- Deselect everything.
function selection.clear(player_index)
  local p = state(player_index)
  p.selection = {}
  changed(player_index)
  util.log("select clear player=%d", player_index)
end

--- Clear the selection and every control group (used by /rts-qa-reset).
function selection.reset(player_index)
  local p = state(player_index)
  p.groups = {}
  p.group_recall = nil
  selection.clear(player_index)
end

--- Select every living unit of the player's force. Returns the count.
function selection.select_all(player_index)
  local p = state(player_index)
  local set = {}
  for un in units.for_force(selection.force_name(player_index)) do set[un] = true end
  p.selection = set
  changed(player_index)
  util.log("select all n=%d player=%d", table_size(set), player_index)
  return table_size(set)
end

--- Selected units as an array of valid LuaEntity (dead units are dropped on the way).
function selection.get(player_index)
  local p = state(player_index)
  if prune(p.selection) then sync_boxes(player_index, p) end
  local out = {}
  for un in pairs(p.selection) do out[#out + 1] = storage.units[un].entity end
  return out
end

--- Number of selected units.
function selection.count(player_index)
  local p = state(player_index)
  if prune(p.selection) then sync_boxes(player_index, p) end
  return table_size(p.selection)
end

--- Selected units per kind: returns {walker = n, heavy = m, ...}, total.
function selection.count_by_kind(player_index)
  local by_kind, total = {}, 0
  for _, entity in pairs(selection.get(player_index)) do
    local kind = storage.units[entity.unit_number].kind
    by_kind[kind] = (by_kind[kind] or 0) + 1
    total = total + 1
  end
  return by_kind, total
end

--- True if the unit is in the player's selection.
function selection.is_selected(player_index, unit_number)
  local p = state(player_index)
  return p.selection[unit_number] == true
end

--- Store the current selection as control group n (1..MAX_GROUPS). Returns the group size.
function selection.group_set(player_index, n)
  local p = state(player_index)
  prune(p.selection)
  p.groups[n] = copy_set(p.selection)
  util.log("group set %d n=%d player=%d", n, table_size(p.groups[n]), player_index)
  selection.notify_hud(player_index)
  return table_size(p.groups[n])
end

--- Number of living units in control group n.
function selection.group_count(player_index, n)
  local p = state(player_index)
  local g = p.groups[n]
  if not g then return 0 end
  prune(g)
  return table_size(g)
end

--- Replace the selection with control group n. An empty group leaves the selection alone. Recalling the
--- same group twice within DOUBLE_TAP_TICKS also jumps a real player's camera to the group.
--- Returns the number of units selected (0 if the group is empty).
function selection.group_recall(player_index, n)
  local p = state(player_index)
  local g = p.groups[n]
  if g then prune(g) end
  if not g or next(g) == nil then
    util.log("group recall %d empty player=%d (selection kept)", n, player_index)
    return 0
  end
  p.selection = copy_set(g)
  changed(player_index)

  local last = p.group_recall
  local tick = game.tick
  local player = real_player(player_index)
  local jumped
  if player and last and last.n == n and tick - last.tick <= DOUBLE_TAP_TICKS then
    jumped = util.centroid(selection.get(player_index))
    if jumped then camera.jump_to(player, jumped) end
  end
  p.group_recall = {n = n, tick = tick}
  util.log("group recall %d n=%d player=%d%s", n, table_size(p.selection), player_index,
    jumped and (" double-tap camera -> " .. util.pos_str(jumped)) or "")
  return table_size(p.selection)
end

--- Apply a selection-tool area: replace (add = false) or add (add = true). `area` is the event's
--- BoundingBox; a click-sized area keeps only the own unit nearest to its centre. Returns the selection size.
function selection.handle_area(player_index, entities, area, add)
  local lt, rb = area.left_top, area.right_bottom
  local own = own_unit_numbers(player_index, entities)
  local own_in_area = #own
  local is_click = rb.x - lt.x < CLICK_SIZE and rb.y - lt.y < CLICK_SIZE
  if #own > 1 and is_click then
    local center = {x = (lt.x + rb.x) / 2, y = (lt.y + rb.y) / 2}
    local best, best_d
    for _, un in pairs(own) do
      local d = util.distance_sq(storage.units[un].entity, center)
      if not best_d or d < best_d then best, best_d = un, d end
    end
    own = {best}
  end
  local p = state(player_index)
  if add then
    for _, un in pairs(own) do p.selection[un] = true end
  else
    p.selection = set_from_list(own)
  end
  changed(player_index)
  -- QA log line: "select mode=replace|add drag|click n=<selection size> ..."
  util.log("select mode=%s %s n=%d own_in_area=%d player=%d area=%s-%s", add and "add" or "replace",
    is_click and "click" or "drag", table_size(p.selection), own_in_area, player_index, util.pos_str(lt),
    util.pos_str(rb))
  return table_size(p.selection)
end

--- Number of valid selection boxes the player currently has (autotest / debugging).
function selection.box_count(player_index)
  local n = 0
  for _, obj in pairs(state(player_index).boxes) do
    if obj.valid then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function selection.init()
  sstate()
  -- Every module is loaded by now: confirm the package.loaded lookup that HUD refreshes depend on.
  local hud = hud_module()
  util.log("selection: hud lookup key=%s found=%s refresh=%s", HUD_KEY, tostring(hud ~= nil),
    tostring(hud ~= nil and type(hud.refresh) == "function"))
  -- After a mod update the boxes may refer to destroyed render objects; redraw what is missing.
  for index, p in pairs(storage.players or {}) do
    if p.selection then
      prune(p.selection)
      sync_boxes(index, state(index))
    end
  end
end

-- A unit left the registry (death or destruction): take it out of every selection and group. Its box is
-- destroyed by the engine together with the entity; the stale handle is dropped here.
units.on_removed(function(unit_number)
  for index, p in pairs(storage.players or {}) do
    local touched = false
    if p.selection and p.selection[unit_number] then
      p.selection[unit_number] = nil
      touched = true
    end
    local obj = p.boxes and p.boxes[unit_number]
    if obj then
      if obj.valid then obj.destroy() end
      p.boxes[unit_number] = nil
    end
    for _, g in pairs(p.groups or {}) do
      if g[unit_number] then
        g[unit_number] = nil
        touched = true
      end
    end
    if touched then mark_dirty(index) end
  end
end)

events.on(defines.events.on_tick, function()
  local s = storage.selection
  local dirty = s and s.dirty
  if not dirty or next(dirty) == nil then return end
  for index in pairs(dirty) do selection.notify_hud(index) end
end)

events.on(defines.events.on_player_selected_area, function(e)
  if e.item ~= util.CURSOR_ITEM then return end
  selection.handle_area(e.player_index, e.entities, e.area, false)
end)

events.on(defines.events.on_player_alt_selected_area, function(e)
  if e.item ~= util.CURSOR_ITEM then return end
  selection.handle_area(e.player_index, e.entities, e.area, true)
end)

for n = 1, selection.MAX_GROUPS do
  events.on("rts-group-set-" .. n, function(e) selection.group_set(e.player_index, n) end)
  events.on("rts-group-" .. n, function(e) selection.group_recall(e.player_index, n) end)
end

events.on("rts-select-all", function(e) selection.select_all(e.player_index) end)

return selection
