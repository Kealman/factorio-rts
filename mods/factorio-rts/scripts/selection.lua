-- Per-player unit selection, selection boxes and control groups (docs/PHASE1.md).
--
-- Owns these storage.players[i] fields:
--   selection     {[unit_number] = true}                  the selected units
--   groups        {[1..5] = {[unit_number] = true}}       control groups
--   boxes         {[unit_number] = LuaRenderObject}       one rectangle per selected unit, shown to that player
--   group_recall  {n = group, tick = tick}                last recall (double tap = jump the camera)
--   building      unit_number?                            Phase 2: the selected own building (storage.buildings);
--                                                         exclusive with `selection` (selecting units clears it)
--   building_render {LuaRenderObject}                     its outline and, for a barracks, the rally line, ring,
--                                                         flag and "Rally" label (rts.rally-label)
-- and storage.selection = {dirty = {[player_index] = true}} (HUD refreshes deferred to the next tick).
--
-- Input model (spike decision 10): the rts-cursor selection tool raises on_player_selected_area for a left
-- drag or click (replace the selection) and on_player_alt_selected_area for shift + left (add to it). Only
-- live units from storage.units on the player's own force are taken; anything else in the event's entity
-- list is ignored. A click (an area under CLICK_SIZE) takes the one own unit nearest to the click.
-- Phase 2: a plain click that finds no own unit selects the own registered building under the cursor
-- (any kind in buildings.KIND_BY_NAME). Box selection still takes units only.
--
-- The player index does not have to belong to a real player: the headless autotest drives index 0, whose
-- force is rts-player, whose boxes are created invisible and whose changes never reach the HUD.
--
-- Phase 5 divisions (scripts/divisions.lua registers selection.set_division_hooks at load time; this module cannot
-- require it): a plain click or drag (select) that hits any member of a division selects the whole division; Shift +
-- click or drag (alt_select, "add") adds exactly the units hit, so Shift is how a single member is picked (deselect,
-- then Shift + click it). Control groups also remember the divisions that were whole in the selection when the group
-- was set (storage.players[i].group_divisions[n] = {[division id] = true}): a recall selects those divisions' current
-- members, and a unit that joins such a division joins the group (selection.division_joined).
local util = require("scripts.util")
local events = require("scripts.events")
local units = require("scripts.units")
local camera = require("scripts.camera")
local buildings = require("scripts.buildings")

local selection = {}

selection.MAX_GROUPS = 5

local DOUBLE_TAP_TICKS = 20  -- two recalls of the same group within this many ticks jump the camera to it
local CLICK_SIZE = 0.1       -- tiles; a smaller area is a click, not a drag
local BOX_PAD = 0            -- tiles added around the selection box (0: walker boxes stay apart on a 3-tile grid)
local BOX_WIDTH = 2          -- pixels
local BOX_LIGHTEN = 0.35     -- mix the force colour with white so the box stands out on tinted units
local DEFAULT_COLOR = {r = 0.3, g = 1, b = 0.3, a = 1}
local BUILDING_PICK_RADIUS = 1.0 -- tiles; a click this close to a building's edge still selects it
-- Phase 5 M1 QA round 1: rolling stock and depots are picked only inside their selection box (rails.lua fills these
-- at load time: building kind "train", entity name "rts-depot"). A wagon's box is oriented (BoundingBox.orientation):
-- read as axis-aligned, a horizontal wagon answered clicks up to 4 tiles below the track.
selection.EXACT_PICK_KINDS = {}
selection.EXACT_PICK_NAMES = {}
-- Phase 4 QA step 8: a click on a pentapod's body selected nothing, because the engine's selection box (centred one
-- torso height above the feet) and the drawn body (in the remote view about two torso heights up) do not agree, and a
-- click between them hits no box. A click therefore picks the own unit nearest to it by position: its feet, or for
-- spider units one or two torso heights (prototype height) above them, within CLICK_PICK_RADIUS; units win over
-- buildings, and the engine's hits are only the fallback.
local CLICK_PICK_RADIUS = 1.5
-- Rally marker of a selected barracks (docs/qa/phase2-qa-results.md steps 28 and 30: the old 0.6-scale flag and
-- 0.3-tile ring were lost under walking units). The flag is the vanilla 64 px spawn flag (red, pole at the
-- lower left), drawn at 1.5 scale (3 tiles) with its pole foot on the point; render objects that are not on the
-- ground are drawn above entities, so units walking over the point do not hide it. While no rally point is set,
-- the same marker sits greyed out at the default exit, without the label.
local RALLY_FLAG = "utility/spawn_flag"
local RALLY_FLAG_SCALE = 1.5
local RALLY_FLAG_OFFSET = {x = 0.47, y = -0.81} -- sprite centre relative to the pole foot, at scale 1
local RALLY_RING_RADIUS = 1.0
local RALLY_LABEL_OFFSET = -2.6 -- tiles above the point (over the flag); the label grows upward from there
local RALLY_COLOR = {r = 0.3, g = 1, b = 0.3, a = 0.9}
local RALLY_FILL = {r = 0.15, g = 0.5, b = 0.15, a = 0.35}
local EXIT_COLOR = {r = 0.7, g = 0.7, b = 0.7, a = 0.6}
local EXIT_FILL = {r = 0.3, g = 0.3, b = 0.3, a = 0.25}

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

---------------------------------------------------------------------------
-- Building selection (Phase 2)
---------------------------------------------------------------------------

-- The live registry record of a building, without side effects (buildings.get drops stale records).
local function building_rec(unit_number)
  local rec = unit_number and storage.buildings and storage.buildings[unit_number]
  if rec and rec.entity and rec.entity.valid then return rec end
  return nil
end

local function clear_building_render(p)
  for _, obj in pairs(p.building_render or {}) do
    if obj.valid then obj.destroy() end
  end
  p.building_render = nil
end

-- Distance from a map position to an entity's selection box (0 inside it). Rolling stock has an oriented box
-- (orientation 0 = north, 0.25 = east, clockwise; it turns about the box centre): the point is turned into the box's
-- own frame first.
local function box_distance(entity, position)
  local box = entity.selection_box
  local lt, rb = box.left_top, box.right_bottom
  local px, py = position.x, position.y
  local o = box.orientation
  if o and o ~= 0 then
    local cx, cy = (lt.x + rb.x) / 2, (lt.y + rb.y) / 2
    local a = o * 2 * math.pi
    local cos, sin = math.cos(a), math.sin(a)
    local dx, dy = px - cx, py - cy
    px, py = cx + dx * cos + dy * sin, cy - dx * sin + dy * cos
  end
  local dx = math.max(lt.x - px, 0, px - rb.x)
  local dy = math.max(lt.y - py, 0, py - rb.y)
  return math.sqrt(dx * dx + dy * dy)
end
selection.box_distance = box_distance

-- The four corners (world positions, clockwise from the top left) of an entity's selection box, turned by its
-- orientation (rolling stock).
local function box_corners(box)
  local lt, rb = box.left_top, box.right_bottom
  local cx, cy = (lt.x + rb.x) / 2, (lt.y + rb.y) / 2
  local a = (box.orientation or 0) * 2 * math.pi
  local cos, sin = math.cos(a), math.sin(a)
  local out = {}
  for i, c in ipairs({{lt.x, lt.y}, {rb.x, lt.y}, {rb.x, rb.y}, {lt.x, rb.y}}) do
    local dx, dy = c[1] - cx, c[2] - cy
    out[i] = {x = cx + dx * cos - dy * sin, y = cy + dx * sin + dy * cos}
  end
  return out
end

-- How far outside its selection box a click may land and still pick this building.
local function pick_radius(entity, rec)
  if selection.EXACT_PICK_NAMES[entity.name] or (rec and selection.EXACT_PICK_KINDS[rec.kind]) then return 0 end
  return BUILDING_PICK_RADIUS
end

-- Outline of the selected building and, for a barracks, a dashed line to its rally point with a flag there
-- (grey at the default exit while no rally point is set). Shown to that player only.
local function draw_building(player_index, p)
  clear_building_render(p)
  local rec = building_rec(p.building)
  if not rec then return end
  local e = rec.entity
  local player = real_player(player_index)
  local players, visible = player and {player_index} or nil, player ~= nil
  local box = e.selection_box
  local objs = {}
  if box.orientation and box.orientation ~= 0 then
    -- rolling stock (QA round 1): the turned box, attached to the carriage
    local corners, pos = box_corners(box), e.position
    for i = 1, 4 do
      local a, b = corners[i], corners[i % 4 + 1]
      objs[#objs + 1] = rendering.draw_line({color = box_color(rec.force), width = BOX_WIDTH,
        from = {entity = e, offset = {a.x - pos.x, a.y - pos.y}}, to = {entity = e, offset = {b.x - pos.x, b.y - pos.y}},
        surface = e.surface, players = players, visible = visible})
    end
  else
    objs[#objs + 1] = rendering.draw_rectangle({color = box_color(rec.force), width = BOX_WIDTH, filled = false,
      left_top = box.left_top, right_bottom = box.right_bottom, surface = e.surface, players = players,
      visible = visible})
  end
  if rec.kind == "barracks" then
    local point = rec.rally or buildings.default_exit(rec)
    local set = rec.rally ~= nil
    local color = set and RALLY_COLOR or EXIT_COLOR
    local function add(obj) objs[#objs + 1] = obj end
    add(rendering.draw_line({color = color, width = 3, dash_length = 0.6, gap_length = 0.4,
      from = e, to = point, surface = e.surface, players = players, visible = visible}))
    add(rendering.draw_circle({color = set and RALLY_FILL or EXIT_FILL, radius = RALLY_RING_RADIUS, filled = true,
      target = point, draw_on_ground = true, surface = e.surface, players = players, visible = visible}))
    add(rendering.draw_circle({color = color, radius = RALLY_RING_RADIUS, width = 3, filled = false, target = point,
      surface = e.surface, players = players, visible = visible}))
    add(rendering.draw_sprite({sprite = RALLY_FLAG, x_scale = RALLY_FLAG_SCALE, y_scale = RALLY_FLAG_SCALE,
      target = {x = point.x + RALLY_FLAG_OFFSET.x * RALLY_FLAG_SCALE, y = point.y + RALLY_FLAG_OFFSET.y * RALLY_FLAG_SCALE},
      tint = set and {1, 1, 1, 1} or {0.6, 0.6, 0.6, 0.6}, surface = e.surface, players = players,
      visible = visible}))
    if set then
      add(rendering.draw_text({text = {"rts.rally-label"}, target = {x = point.x, y = point.y + RALLY_LABEL_OFFSET},
        color = RALLY_COLOR, scale = 1.3, font = "default-bold", alignment = "center", vertical_alignment = "bottom",
        scale_with_zoom = true, surface = e.surface, players = players, visible = visible}))
    end
  end
  p.building_render = objs
end

local function drop_building(p)
  if p.building == nil and p.building_render == nil then return false end
  p.building = nil
  clear_building_render(p)
  return true
end

-- Common tail of every selection change: drop dead units, redraw boxes, refresh the HUD. Any change of the unit
-- selection also deselects the building, unless keep_building is set.
local function changed(player_index, keep_building)
  local p = state(player_index)
  prune(p.selection)
  if not keep_building then drop_building(p) end
  sync_boxes(player_index, p)
  selection.notify_hud(player_index)
end

--- Select one own building (by unit number) instead of units. Returns true when it was selected.
--- QA log line: "select building <kind> unit=<unit_number> player=N at (x, y)".
function selection.select_building(player_index, unit_number)
  local rec = building_rec(unit_number)
  if not rec or rec.force ~= selection.force_name(player_index) then return false end
  local p = state(player_index)
  p.selection = {}
  p.building = unit_number
  sync_boxes(player_index, p)
  draw_building(player_index, p)
  selection.notify_hud(player_index)
  util.log("select building %s unit=%d player=%d at %s", rec.kind, unit_number, player_index,
    util.pos_str(rec.entity.position))
  return true
end

--- The selected building: unit_number, record (both nil when none is selected or it is gone).
function selection.get_building(player_index)
  local p = state(player_index)
  local rec = building_rec(p.building)
  if not rec then
    if p.building then drop_building(p) end
    return nil, nil
  end
  return p.building, rec
end

--- Redraw the selected building's outline and rally flag (after its rally point changed).
function selection.refresh_building(player_index)
  local p = state(player_index)
  if p.building then draw_building(player_index, p) end
  selection.notify_hud(player_index)
end

--- The own registered building at a map position: the one whose selection box is nearest to the point, within
--- BUILDING_PICK_RADIUS (0 = inside it; rolling stock and depots: inside only). Returns unit_number, record or nil.
--- Phase 5 M1 QA round 1: hover selection is off (camera.lua: update_entity_selection), so player.selected is never
--- the entity under the cursor (at best a stale one) and is no longer consulted.
function selection.building_at(player_index, position, surface)
  local force = selection.force_name(player_index)
  surface = surface or util.surface()
  local best_un, best_rec, best_d
  -- rolling stock is up to 7 tiles long: its centre can lie that far from a click inside its box
  for _, e in pairs(surface.find_entities_filtered({position = position, radius = BUILDING_PICK_RADIUS + 5,
                                                     force = force})) do
    local rec = e.unit_number and building_rec(e.unit_number)
    if rec then
      local d = box_distance(e, position)
      if d <= pick_radius(e, rec) and (not best_d or d < best_d) then best_un, best_rec, best_d = e.unit_number, rec, d end
    end
  end
  return best_un, best_rec
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
-- Phase 5: divisions (see the header)
---------------------------------------------------------------------------
-- {of = fn(unit_number) -> division id | nil, members = fn(id) -> {unit_number, ...} (live members)}; nil until
-- scripts/divisions.lua registers them.
local division_hooks = nil
function selection.set_division_hooks(hooks) division_hooks = hooks end

-- The unit numbers plus every live member of each division any of them belongs to. Returns the list and the number
-- of divisions expanded.
local function expand_divisions(list)
  if not division_hooks then return list, 0 end
  local seen, out, n = {}, {}, 0
  for _, un in ipairs(list) do
    if not seen[un] then
      local id = division_hooks.of(un)
      if id and not seen["d" .. id] then
        seen["d" .. id] = true
        n = n + 1
        for _, m in ipairs(division_hooks.members(id)) do
          if not seen[m] then
            seen[m] = true
            out[#out + 1] = m
          end
        end
      end
      if not seen[un] then
        seen[un] = true
        out[#out + 1] = un
      end
    end
  end
  return out, n
end

-- Divisions whose every live member is in `set`.
local function whole_divisions(set)
  local out = {}
  if not division_hooks then return out end
  for un in pairs(set) do
    local id = division_hooks.of(un)
    if id and out[id] == nil then
      local whole = true
      for _, m in ipairs(division_hooks.members(id)) do
        if not set[m] then
          whole = false
          break
        end
      end
      out[id] = whole
    end
  end
  for id, whole in pairs(out) do
    if not whole then out[id] = nil end
  end
  return out
end
selection.whole_divisions = whole_divisions

--- A unit joined division `id` (reinforcement): it joins every control group that holds the division and every
--- selection that holds the whole division.
function selection.division_joined(id, unit_number)
  if not division_hooks then return end
  for index, p in pairs(storage.players or {}) do
    local touched = false
    for n, divs in pairs(p.group_divisions or {}) do
      if divs[id] and p.groups and p.groups[n] then
        p.groups[n][unit_number] = true
        touched = true
      end
    end
    if p.selection and next(p.selection) and not p.selection[unit_number] then
      local whole, any = true, false
      for _, m in ipairs(division_hooks.members(id)) do
        if m ~= unit_number then
          if p.selection[m] then any = true else whole = false end
        end
      end
      if any and whole then
        p.selection[unit_number] = true
        sync_boxes(index, p)
        touched = true
      end
    end
    if touched then mark_dirty(index) end
  end
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
  p.group_divisions = nil
  p.group_recall = nil
  selection.clear(player_index)
end

--- Select every living unit of the player's force. Returns the count.
-- Ctrl+A is the army: haulers stay out (Wave C), so a right click on the ground after Ctrl+A does not park every
-- hauler route. Box and click selection still pick haulers.
selection.SELECT_ALL_SKIP = {hauler = true}

function selection.select_all(player_index)
  local p = state(player_index)
  local set = {}
  for un, rec in units.for_force(selection.force_name(player_index)) do
    if not selection.SELECT_ALL_SKIP[rec.kind] then set[un] = true end
  end
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
  -- Phase 5 M3 integration (perf notes open issue 9): a Nation match hands the units out in unit-number order (the
  -- order decides formation ties and the command queue); Skirmish keeps the insertion order its autotests compare
  local m = storage.match
  if m and m.config and m.config.mode == "nation" then
    local uns = {}
    for un in pairs(p.selection) do uns[#uns + 1] = un end
    table.sort(uns)
    for i, un in ipairs(uns) do out[i] = storage.units[un].entity end
    return out
  end
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
  -- Phase 5: the whole divisions in it, so later reinforcements belong to the group too
  local divs = whole_divisions(p.selection)
  if next(divs) then
    p.group_divisions = p.group_divisions or {}
    p.group_divisions[n] = divs
  elseif p.group_divisions then
    p.group_divisions[n] = nil
  end
  util.log("group set %d n=%d player=%d%s", n, table_size(p.groups[n]), player_index,
    next(divs) and string.format(" divisions=%d", table_size(divs)) or "")
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
  -- Phase 5: the current members of the group's divisions (reinforcements included)
  local divs = p.group_divisions and p.group_divisions[n]
  if g and divs and division_hooks then
    for id in pairs(divs) do
      local members = division_hooks.members(id)
      if #members == 0 then divs[id] = nil end
      for _, m in ipairs(members) do g[m] = true end
    end
  end
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

local spider_height = {} -- [prototype name] = torso height in tiles (0 when the prototype has none); derived data

local function torso_height(entity)
  local name = entity.name
  local hgt = spider_height[name]
  if hgt == nil then
    local ok, value = pcall(function() return entity.prototype.height end)
    hgt = (ok and type(value) == "number") and value or 0
    spider_height[name] = hgt
  end
  return hgt
end

--- The own unit a click at `center` means: the nearest one whose feet or torso lie within CLICK_PICK_RADIUS.
--- Returns its unit_number or nil.
function selection.unit_at(player_index, center, surface)
  surface = surface or util.surface()
  if not surface then return nil end
  local force = selection.force_name(player_index)
  local side, down = CLICK_PICK_RADIUS + 2, CLICK_PICK_RADIUS + 7 -- feet lie below the click: torso heights up to 3
  local best, best_d
  for _, e in pairs(surface.find_entities_filtered({area = {{center.x - side, center.y - CLICK_PICK_RADIUS - 1},
                                                            {center.x + side, center.y + down}},
                                                     force = force, type = {"spider-unit", "unit", "spider-vehicle"}})) do
    local rec = e.unit_number and units.get(e.unit_number)
    if rec and rec.force == force then
      local p = e.position
      local dx2 = (p.x - center.x) ^ 2
      local h = torso_height(e)
      local d = math.sqrt(dx2 + (p.y - center.y) ^ 2)
      for k = 1, (h > 0) and 2 or 0 do d = math.min(d, math.sqrt(dx2 + (p.y - k * h - center.y) ^ 2)) end
      if d <= CLICK_PICK_RADIUS and (not best_d or d < best_d) then best, best_d = e.unit_number, d end
    end
  end
  return best
end

--- Apply a selection-tool area: replace (add = false) or add (add = true). `area` is the event's
--- BoundingBox; a click-sized area keeps only the own unit nearest to its centre. A plain click with no own
--- unit selects the own building there (selection.building_at); `surface` defaults to the arena surface.
--- Returns the selection size (units; 0 when a building was selected).
function selection.handle_area(player_index, entities, area, add, surface)
  local lt, rb = area.left_top, area.right_bottom
  local own = own_unit_numbers(player_index, entities)
  local own_in_area = #own
  local is_click = rb.x - lt.x < CLICK_SIZE and rb.y - lt.y < CLICK_SIZE
  if is_click then
    local center = {x = (lt.x + rb.x) / 2, y = (lt.y + rb.y) / 2}
    local picked = selection.unit_at(player_index, center, surface)
    if picked then own = {picked} end
  end
  if #own == 0 and is_click and not add then
    local center = {x = (lt.x + rb.x) / 2, y = (lt.y + rb.y) / 2}
    local un = selection.building_at(player_index, center, surface)
    if un and selection.select_building(player_index, un) then return 0 end
  end
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
  local n_div = 0
  if add then
    for _, un in pairs(own) do p.selection[un] = true end
  else
    own, n_div = expand_divisions(own) -- Phase 5: a plain select takes whole divisions
    p.selection = set_from_list(own)
  end
  changed(player_index)
  -- QA log line: "select mode=replace|add drag|click n=<selection size> ..." (Phase 5: "divisions=N" when expanded)
  util.log("select mode=%s %s n=%d own_in_area=%d player=%d area=%s-%s%s", add and "add" or "replace",
    is_click and "click" or "drag", table_size(p.selection), own_in_area, player_index, util.pos_str(lt),
    util.pos_str(rb), n_div > 0 and string.format(" divisions=%d", n_div) or "")
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
    if p.building then
      if building_rec(p.building) then draw_building(index, p) else drop_building(p) end
    end
  end
end

-- A selected building left the registry (died, mined, replaced by a template clone): deselect it.
buildings.on_removed(function(unit_number)
  for index, p in pairs(storage.players or {}) do
    if p.building == unit_number then
      drop_building(p)
      mark_dirty(index)
      util.log("select building cleared unit=%d player=%d (building gone)", unit_number, index)
    end
  end
end)

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

-- R / Shift + R (rts-rotate, rts-reverse-rotate follow the vanilla controls): rotate the own rotatable entity or ghost
-- under the cursor. Hover selection is off in the RTS view (camera.lua), so the vanilla rotate finds nothing on the
-- map; while a build ghost is on the cursor the vanilla control rotates that and this handler stays out of it.
local cursor = require("scripts.cursor")
function selection.rotate_at(player_index, position, reverse)
  local player = game.get_player(player_index)
  if not (player and position) or cursor.ghost_name(player) then return nil end
  local surface = util.surface()
  if not surface then return nil end
  local best, best_area
  local function can_rotate(e)
    local ok, yes = pcall(function() return e.rotatable and e.supports_direction end)
    return ok and yes
  end
  for _, e in pairs(surface.find_entities_filtered({position = position, radius = 1, force = player.force})) do
    if e.valid and can_rotate(e) then
      local box = e.selection_box
      local inside = position.x >= box.left_top.x and position.x <= box.right_bottom.x
        and position.y >= box.left_top.y and position.y <= box.right_bottom.y
      local area = (box.right_bottom.x - box.left_top.x) * (box.right_bottom.y - box.left_top.y)
      if inside and (not best_area or area < best_area) then best, best_area = e, area end
    end
  end
  if not best then return nil end
  local ok = best.rotate({reverse = reverse == true, by_player = player})
  util.log("rotate %s %s at %s ok=%s now %s player=%d", reverse and "reverse" or "forward",
    best.type == "entity-ghost" and ("ghost of " .. best.ghost_name) or best.name, util.pos_str(best.position),
    tostring(ok), util.define_name(defines.direction, best.direction), player_index)
  return best
end
events.on("rts-rotate", function(e) selection.rotate_at(e.player_index, e.cursor_position, false) end)
events.on("rts-reverse-rotate", function(e) selection.rotate_at(e.player_index, e.cursor_position, true) end)

events.on(defines.events.on_player_selected_area, function(e)
  if e.item ~= util.CURSOR_ITEM then return end
  selection.handle_area(e.player_index, e.entities, e.area, false, e.surface)
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
