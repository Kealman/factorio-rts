-- Logistics pieces and ghosts: the own entities that are not buildings (docs/qa/release-0-1-2-r3-build-notes.md).
-- Belts, undergrounds, splitters, inserters and poles are the vanilla entities and are NOT in storage.buildings (no
-- on_object_destroyed registration per piece, no "base attacked" alerts, no AI build-order steps); an entity ghost of
-- the player's force is never registered either. This module finds them by position, describes them for the HUD page
-- and removes them with the recipe-based refund. Selection state (storage.players[i].pieces) lives in selection.lua,
-- the two-press confirmation in demolish.lua; this module holds no state.
--
-- Refund: 50 % of the recipe cost per piece (rts-belt: 10 iron per 10 belts, so one belt refunds 0.5 iron). The
-- fractions are carried across one batch (10 belts refund 5 iron plates; one lone belt refunds nothing, which the
-- HUD message says). Items on a belt or in an inserter's hand go the way a stockpile's contents do (the network, else
-- spilled). A ghost has nothing to refund.
--
-- 0.1.4 (#41 item 3, #33 item 6): own ground rails and rail / chain signals are pieces too (kind "track"). rails.lua
-- fills pieces.track = {describe, remove, partners} at load time: what the HUD says about them, their removal as one
-- batch (rails.remove_track: lines split, refunds, rails under trains kept) and a signal's partner on the other side
-- of the track, which a click or a box selects with it (pieces.expand).
local util = require("scripts.util")
local buildings = require("scripts.buildings")

local pieces = {}

-- Entity name -> the factory recipe that makes its item (the refund reads that recipe; the vanilla item recipes cost
-- something else).
pieces.RECIPE = {
  ["transport-belt"] = "rts-belt",
  ["underground-belt"] = "rts-underground-belt",
  ["splitter"] = "rts-splitter",
  ["fast-inserter"] = "rts-inserter",
  ["long-handed-inserter"] = "rts-long-inserter",
  ["medium-electric-pole"] = "rts-pole",
}
pieces.TYPES = {"transport-belt", "underground-belt", "splitter", "inserter", "electric-pole", "entity-ghost",
                "straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b", "rail-signal",
                "rail-chain-signal"}
-- 0.1.4 (#41): own ground rails and signals (the hooks come from rails.lua; without them, nothing of this kind counts)
pieces.TRACK = {["straight-rail"] = true, ["half-diagonal-rail"] = true, ["curved-rail-a"] = true,
                ["curved-rail-b"] = true, ["rail-signal"] = true, ["rail-chain-signal"] = true}
pieces.track = nil

local PICK_RADIUS = 0.35 -- tiles outside a piece's selection box that a click still picks (belts are thin)

--- "ghost" for an entity ghost, "piece" for a logistics piece, nil for anything else. Names, not types: only the three
--- vanilla pieces the factory crafts count, so a hub's hidden pole or an enemy-mod entity never does.
function pieces.kind(entity)
  if not (entity and entity.valid) then return nil end
  if entity.type == "entity-ghost" then return "ghost" end
  if pieces.RECIPE[entity.name] then return "piece" end
  if pieces.TRACK[entity.name] and pieces.track then return "track" end
  return nil
end

--- Name an entity is known by: the ghost's prototype for a ghost.
function pieces.name(entity)
  return entity.type == "entity-ghost" and entity.ghost_name or entity.name
end

-- Distance from a map position to an entity's selection box (0 inside it).
local function box_distance(entity, position)
  local box = entity.selection_box
  local lt, rb = box.left_top, box.right_bottom
  local dx = math.max(lt.x - position.x, 0, position.x - rb.x)
  local dy = math.max(lt.y - position.y, 0, position.y - rb.y)
  return math.sqrt(dx * dx + dy * dy)
end

--- The own piece or ghost nearest to a map position, within PICK_RADIUS of its selection box. Returns entity, distance.
function pieces.at(force_name, surface, position)
  local best, best_d
  for _, e in pairs(surface.find_entities_filtered({position = position, radius = 2, force = force_name,
                                                     type = pieces.TYPES})) do
    if pieces.kind(e) then
      local d = box_distance(e, position)
      if d <= PICK_RADIUS and (not best_d or d < best_d) then best, best_d = e, d end
    end
  end
  return best, best_d
end

--- Every own piece and ghost whose position lies in `area` (BoundingBox), in a stable order (y, x, name).
function pieces.in_area(force_name, surface, area)
  local out = {}
  for _, e in pairs(surface.find_entities_filtered({area = area, force = force_name, type = pieces.TYPES})) do
    if pieces.kind(e) then out[#out + 1] = e end
  end
  table.sort(out, function(a, b)
    local pa, pb = a.position, b.position
    if pa.y ~= pb.y then return pa.y < pb.y end
    if pa.x ~= pb.x then return pa.x < pb.x end
    return pieces.name(a) < pieces.name(b)
  end)
  return out
end

--- 0.1.4 (#41): `list` with the partner of every signal in it (the signal on the other side of the track at the same
--- joint), in the order given, each entity once.
function pieces.expand(list)
  if not pieces.track then return list end
  local out, seen = {}, {}
  local function take(e)
    local k = e.unit_number or 0
    if k == 0 or not seen[k] then
      seen[k] = true
      out[#out + 1] = e
    end
  end
  for _, e in ipairs(list) do
    if e.valid then
      take(e)
      if e.type == "rail-signal" or e.type == "rail-chain-signal" then
        for _, o in ipairs(pieces.track.partners(e)) do take(o) end
      end
    end
  end
  return out
end

--- Stable identity of a list of entities for the two-press confirmation: "name@x,y" sorted.
function pieces.key(list)
  local keys = {}
  for _, e in ipairs(list) do
    local p = e.position
    keys[#keys + 1] = string.format("%s@%.1f,%.1f", pieces.name(e), p.x, p.y)
  end
  table.sort(keys)
  return table.concat(keys, ";")
end

---------------------------------------------------------------------------
-- HUD description
---------------------------------------------------------------------------
local DIRECTIONS = {north = true, east = true, south = true, west = true}

-- LocalisedString of what an inserter takes from or drops to: the entity there, else the tile.
local function endpoint(entity, target, pos)
  if target and target.valid then return target.localised_name end
  return string.format("(%.1f, %.1f)", pos.x, pos.y)
end

--- What the HUD page shows for one selected entity: {title, lines = {LocalisedString...}, rotatable, ghost}.
function pieces.describe(entity)
  local ghost = entity.type == "entity-ghost"
  local name = pieces.name(entity)
  local proto = ghost and entity.ghost_prototype or entity.prototype
  local title = ghost and {"rts.piece-ghost-title", proto.localised_name} or {"rts.piece-title", proto.localised_name}
  local lines = {}
  local dir = util.define_name(defines.direction, entity.direction)
  if not DIRECTIONS[dir] then dir = nil end
  if not ghost and pieces.TRACK[name] and pieces.track then -- 0.1.4 (#41): own rail or signal
    return {title = title, lines = pieces.track.describe(entity), ghost = false, rotatable = false, name = name}
  end
  if ghost then
    lines[1] = {"rts.piece-ghost-line"}
    lines[2] = {"rts.piece-ghost-hint"}
  elseif entity.type == "inserter" then
    lines[1] = {"rts.piece-inserter", endpoint(entity, entity.pickup_target, entity.pickup_position),
                endpoint(entity, entity.drop_target, entity.drop_position)}
    lines[2] = dir and {"rts.piece-direction", {"rts.piece-dir-" .. dir}} or ""
  elseif entity.type == "electric-pole" then
    local n = 0
    local ok, nb = pcall(function() return entity.neighbours end)
    if ok and nb and nb.copper then n = #nb.copper end
    lines[1] = {"rts.piece-pole", n}
    lines[2] = ""
  else
    local items = 0
    for i = 1, entity.get_max_transport_line_index() do
      for _, c in pairs(entity.get_transport_line(i).get_contents()) do items = items + c.count end
    end
    lines[1] = dir and {"rts.piece-direction", {"rts.piece-dir-" .. dir}} or ""
    lines[2] = {"rts.piece-belt-items", items}
  end
  local rot_ok, rot = pcall(function() return entity.rotatable and entity.supports_direction end)
  return {title = title, lines = lines, ghost = ghost, rotatable = rot_ok and rot == true, name = name}
end

---------------------------------------------------------------------------
-- Removal
---------------------------------------------------------------------------
-- Items on a belt, a splitter, an underground's lines or in an inserter's hand, taken out: array of {name, count, quality}.
local function take_contents(entity)
  local out = {}
  if entity.type == "inserter" then
    local hand = entity.held_stack
    if hand and hand.valid_for_read then
      out[1] = {name = hand.name, count = hand.count, quality = hand.quality.name}
      hand.clear()
    end
  elseif entity.type ~= "electric-pole" and entity.type ~= "entity-ghost" then
    for i = 1, entity.get_max_transport_line_index() do
      local line = entity.get_transport_line(i)
      for _, c in pairs(line.get_contents()) do
        out[#out + 1] = {name = c.name, count = c.count, quality = c.quality}
      end
      line.clear()
    end
  end
  return out
end

--- Refund of one piece: {[item] = n}; `carry` keeps the fractions between the pieces of one batch (see header).
local function refund_of(name, carry)
  local recipe = prototypes.recipe[pieces.RECIPE[name] or ""]
  if not recipe then return {} end
  local made = 1
  for _, prod in pairs(recipe.products) do
    if prod.type == "item" then made = prod.amount or 1 end
  end
  local out = {}
  for _, ing in pairs(recipe.ingredients) do
    if ing.type == "item" then
      local exact = ing.amount / made * buildings.REFUND_RATIO + (carry[ing.name] or 0)
      local whole = math.floor(exact + 1e-9)
      carry[ing.name] = exact - whole
      if whole > 0 then out[ing.name] = whole end
    end
  end
  return out
end

--- Remove one own piece or ghost. A piece refunds its recipe share and moves its contents (buildings.deliver_items);
--- a ghost just disappears. opts: force = force name that must own it, carry = batch table of fractional refunds.
--- Returns true, info {name, ghost, position, surface, force, refund = {[item] = n}, spilled = n} or false, reason.
--- The refund is returned undelivered (the caller delivers a batch at once, demolish.lua).
function pieces.remove(entity, opts)
  opts = opts or {}
  if not (entity and entity.valid) then return false, "invalid" end
  if opts.force and entity.force.name ~= opts.force then return false, "foreign" end
  local kind = pieces.kind(entity)
  if not kind then return false, "not-piece" end
  if kind == "track" then return false, "track" end -- (rails and signals: pieces.track.remove, as one batch)
  local name, pos, surface = pieces.name(entity), entity.position, entity.surface
  local force_name = entity.force.name
  local info = {name = name, ghost = kind == "ghost", position = {x = pos.x, y = pos.y}, refund = {},
                spilled = 0, surface = surface, force = force_name}
  if kind == "piece" then
    local contents = take_contents(entity)
    info.refund = refund_of(name, opts.carry or {})
    if #contents > 0 then
      local _, spilled = buildings.deliver_items(surface, force_name, pos, contents)
      info.spilled = spilled
    end
  end
  entity.destroy()
  return true, info
end

return pieces
