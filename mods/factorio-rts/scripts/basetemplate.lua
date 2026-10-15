-- Starter base template (docs/PHASE2.md "Enemy force in Phase 2"; spike decision 8: clone_area for identical
-- match-start bases). The template is built once, from the data in basetemplate.ENTITIES, on the scratch
-- surface "rts-scratch" by the "rts-template" force, in two variants: facing +x (a base west of the arena centre,
-- e.g. the player at x = -60) and facing -x (mirrored in x, e.g. the enemy at x = +60). basetemplate.clone_to
-- copies a variant with LuaSurface.clone_area into the arena for any force; the clone keeps inventories,
-- wires and the ore under its extractors, and its production is real.
--
-- The scratch copies are disabled by script (disabled_by_script), so they do not mine or smelt while waiting;
-- buildings.lua re-enables every clone in on_entity_cloned. The CC (a roboport) ignores that flag, but with no
-- ghosts and no requests on the scratch surface its robots stay docked.
--
-- Owns storage.basetemplate = {built = true, variants = {[1] = V, [-1] = V}} with
--   V = {origin = MapPosition (CC centre on the scratch surface), area = BoundingBox (absolute, tile-aligned),
--        entities = number, ore_tiles = number, failed = number}
local util = require("scripts.util")
local buildings = require("scripts.buildings")

local basetemplate = {}

basetemplate.FORCE = "rts-template"
basetemplate.SURFACE = buildings.SCRATCH_SURFACE
basetemplate.ORIGINS = {[1] = {x = -40, y = 0}, [-1] = {x = 40, y = 0}} -- CC centres on the scratch surface
basetemplate.CLEAR_RADIUS = 24       -- scratch area cleared and paved around each origin
basetemplate.ORE_AMOUNT = 3000       -- per ore tile under the template's extractors
basetemplate.STOCK = {["iron-plate"] = 200, ["copper-plate"] = 100} -- into the template CC's stockpiles

-- Layout relative to the CC centre for the variant facing +x (+x points at the arena centre). Mirroring flips
-- x and swaps east/west. Entries:
--   {cc = true, position}                      CC composite (buildings.place_cc: CC, core power and pole,
--                                              4 stockpiles at buildings.CC_STOCKPILES, robots)
--   {name, position, direction?, ore?}         one entity; `ore` puts that resource under a mining drill's area
--   {name, position, pickup}                   inserter, rotated so that it picks up from `pickup`
--   {belt = name, from, to}                    straight belt run, direction from `from` towards `to`
-- Iron: 2 extractors -> belt -> 2 inserters -> 2 smelters -> 2 inserters -> 2 stockpiles (north of the CC).
-- Copper: 1 extractor -> belt -> 2 smelters -> 2 stockpiles (south, mirrored in y). Power: the core pole under
-- the CC already covers 36x36 tiles; the 6 medium poles are wired to it and to each other. 2 solar arrays west
-- of the CC, the barracks east of it, next to a CC stockpile. Everything is inside the CC's logistic area (25).
basetemplate.ENTITIES = {
  {cc = true, position = {0, 0}},
  -- iron line
  {name = "rts-extractor", position = {-8.5, -6.5}, direction = "north", ore = "iron-ore"},
  {name = "rts-extractor", position = {-5.5, -6.5}, direction = "north", ore = "iron-ore"},
  {belt = "transport-belt", from = {-9.5, -8.5}, to = {2.5, -8.5}},
  {name = "fast-inserter", position = {-1.5, -9.5}, pickup = {-1.5, -8.5}},
  {name = "fast-inserter", position = {1.5, -9.5}, pickup = {1.5, -8.5}},
  {name = "rts-smelter", position = {-1.5, -11.5}},
  {name = "rts-smelter", position = {1.5, -11.5}},
  {name = "fast-inserter", position = {-1.5, -13.5}, pickup = {-1.5, -12.5}},
  {name = "fast-inserter", position = {1.5, -13.5}, pickup = {1.5, -12.5}},
  {name = "rts-stockpile", position = {-1.5, -14.5}},
  {name = "rts-stockpile", position = {1.5, -14.5}},
  -- copper line
  {name = "rts-extractor", position = {-6.5, 6.5}, direction = "south", ore = "copper-ore"},
  {belt = "transport-belt", from = {-7.5, 8.5}, to = {2.5, 8.5}},
  {name = "fast-inserter", position = {-1.5, 9.5}, pickup = {-1.5, 8.5}},
  {name = "fast-inserter", position = {1.5, 9.5}, pickup = {1.5, 8.5}},
  {name = "rts-smelter", position = {-1.5, 11.5}},
  {name = "rts-smelter", position = {1.5, 11.5}},
  {name = "fast-inserter", position = {-1.5, 13.5}, pickup = {-1.5, 12.5}},
  {name = "fast-inserter", position = {1.5, 13.5}, pickup = {1.5, 12.5}},
  {name = "rts-stockpile", position = {-1.5, 14.5}},
  {name = "rts-stockpile", position = {1.5, 14.5}},
  -- power
  {name = "medium-electric-pole", position = {0.5, -4.5}},
  {name = "medium-electric-pole", position = {0.5, -9.5}},
  {name = "medium-electric-pole", position = {0.5, 4.5}},
  {name = "medium-electric-pole", position = {0.5, 9.5}},
  {name = "medium-electric-pole", position = {-5.5, 0.5}},
  {name = "medium-electric-pole", position = {5.5, 1.5}},
  {name = "rts-solar-array", position = {-7.5, -1.5}},
  {name = "rts-solar-array", position = {-7.5, 1.5}},
  -- military
  {name = "rts-barracks", position = {5.5, -1.5}},
}

local DIRS = {north = defines.direction.north, east = defines.direction.east, south = defines.direction.south,
              west = defines.direction.west}

function basetemplate.init()
  storage.basetemplate = storage.basetemplate or {}
end

local function mirror_dir(dir, facing)
  if facing == 1 or dir == nil then return dir end
  return (16 - dir) % 16 -- 16-way directions in 2.0: east (4) <-> west (12), north/south unchanged
end

local function bbox_union(acc, bb)
  if not acc then
    return {left_top = {x = bb.left_top.x, y = bb.left_top.y}, right_bottom = {x = bb.right_bottom.x, y = bb.right_bottom.y}}
  end
  acc.left_top.x = math.min(acc.left_top.x, bb.left_top.x)
  acc.left_top.y = math.min(acc.left_top.y, bb.left_top.y)
  acc.right_bottom.x = math.max(acc.right_bottom.x, bb.right_bottom.x)
  acc.right_bottom.y = math.max(acc.right_bottom.y, bb.right_bottom.y)
  return acc
end

---------------------------------------------------------------------------
-- Ore
---------------------------------------------------------------------------
--- Place a resource blob: every tile of the w x h rectangle centred on `center` (round = true: the inscribed
--- ellipse, slightly widened) that has no resource yet gets `name` with `amount`. Returns the tiles placed.
function basetemplate.place_ore(surface, name, center, w, h, amount, round)
  local cx, cy = util.xy(center)
  local x0, y0 = math.floor(cx - w / 2 + 0.5), math.floor(cy - h / 2 + 0.5)
  local placed = 0
  for tx = x0, x0 + w - 1 do
    for ty = y0, y0 + h - 1 do
      local px, py = tx + 0.5, ty + 0.5
      local inside = true
      if round then
        local nx, ny = (px - cx) / (w / 2), (py - cy) / (h / 2)
        inside = nx * nx + ny * ny <= 1.15
      end
      if inside and surface.count_entities_filtered({position = {px, py}, type = "resource"}) == 0 then
        if surface.create_entity({name = name, position = {px, py}, amount = amount}) then placed = placed + 1 end
      end
    end
  end
  return placed
end

-- Ore under a mining drill's whole mining area (a square of 2 * radius around its centre).
local function ore_under_drill(surface, drill_name, position, ore)
  local r = prototypes.entity[drill_name].mining_drill_radius
  local x0, x1 = math.floor(position.x - r), math.ceil(position.x + r) - 1
  local y0, y1 = math.floor(position.y - r), math.ceil(position.y + r) - 1
  return basetemplate.place_ore(surface, ore, {(x0 + x1 + 1) / 2, (y0 + y1 + 1) / 2}, x1 - x0 + 1, y1 - y0 + 1,
    basetemplate.ORE_AMOUNT, false)
end

---------------------------------------------------------------------------
-- Building one variant on the scratch surface
---------------------------------------------------------------------------
local function create(surface, spec)
  spec.force = basetemplate.FORCE
  spec.create_build_effect_smoke = false
  return surface.create_entity(spec)
end

local function place_inserter(surface, name, pos, pickup)
  for _, d in ipairs({"north", "east", "south", "west"}) do
    local e = create(surface, {name = name, position = pos, direction = DIRS[d]})
    if e then
      local pp = e.pickup_position
      if math.abs(pp.x - pickup.x) < 0.3 and math.abs(pp.y - pickup.y) < 0.3 then return e end
      e.destroy()
    end
  end
  return nil
end

local function build_variant(surface, facing)
  local origin = basetemplate.ORIGINS[facing]
  local function abs(p) return {x = origin.x + facing * p[1], y = origin.y + p[2]} end
  local R = basetemplate.CLEAR_RADIUS
  local clear = {{origin.x - R, origin.y - R}, {origin.x + R, origin.y + R}}
  for _, e in pairs(surface.find_entities_filtered({area = clear})) do e.destroy() end

  local ore, made, failed = 0, {}, 0
  local function keep(e, what)
    if e then made[#made + 1] = e else
      failed = failed + 1
      util.log("basetemplate: FAILED to create %s (variant %+d)", what, facing)
    end
  end
  for _, spec in ipairs(basetemplate.ENTITIES) do
    if spec.ore then ore = ore + ore_under_drill(surface, spec.name, abs(spec.position), spec.ore) end
  end
  local cc_parts
  for _, spec in ipairs(basetemplate.ENTITIES) do
    if spec.cc then
      local cc, parts = buildings.place_cc(surface, abs(spec.position), basetemplate.FORCE)
      keep(cc, "command center")
      if cc then
        cc_parts = parts
        for _, s in ipairs(parts.stockpiles) do made[#made + 1] = s end
      end
    elseif spec.belt then
      local a, b = abs(spec.from), abs(spec.to)
      local dx, dy = b.x - a.x, b.y - a.y
      local dir = math.abs(dx) >= math.abs(dy) and (dx >= 0 and DIRS.east or DIRS.west)
        or (dy >= 0 and DIRS.south or DIRS.north)
      local steps = math.floor(math.max(math.abs(dx), math.abs(dy)) + 0.5)
      local sx, sy = dx == 0 and 0 or dx / math.abs(dx), dy == 0 and 0 or dy / math.abs(dy)
      for i = 0, steps do
        local p = {x = a.x + sx * i, y = a.y + sy * i}
        keep(create(surface, {name = spec.belt, position = p, direction = dir}), spec.belt .. " " .. util.pos_str(p))
      end
    elseif spec.pickup then
      local p = abs(spec.position)
      keep(place_inserter(surface, spec.name, p, abs(spec.pickup)), spec.name .. " " .. util.pos_str(p))
    else
      local p = abs(spec.position)
      local dir = spec.direction and mirror_dir(DIRS[spec.direction], facing) or nil
      keep(create(surface, {name = spec.name, position = p, direction = dir}), spec.name .. " " .. util.pos_str(p))
    end
  end

  -- Starting stock of the template base, in the CC's stockpiles.
  if cc_parts then
    for item, count in pairs(basetemplate.STOCK) do
      local left = count
      for _, s in ipairs(cc_parts.stockpiles) do
        left = left - s.insert({name = item, count = left})
        if left <= 0 then break end
      end
    end
  end

  -- Freeze the scratch copy and measure its tile-aligned bounds (entities and ore).
  local bounds, by_name = nil, {}
  for _, e in pairs(surface.find_entities_filtered({area = clear, force = basetemplate.FORCE})) do
    if e.disabled_by_script ~= nil then e.disabled_by_script = true end
    bounds = bbox_union(bounds, e.bounding_box)
    by_name[e.name] = (by_name[e.name] or 0) + 1
  end
  for _, e in pairs(surface.find_entities_filtered({area = clear, type = "resource"})) do
    bounds = bbox_union(bounds, e.bounding_box)
  end
  local area = {left_top = {x = math.floor(bounds.left_top.x) - 1, y = math.floor(bounds.left_top.y) - 1},
                right_bottom = {x = math.ceil(bounds.right_bottom.x) + 1, y = math.ceil(bounds.right_bottom.y) + 1}}
  local names = {}
  for k, v in pairs(by_name) do names[#names + 1] = k .. "=" .. v end
  table.sort(names)
  util.log("basetemplate: variant %+d at %s: %d entities [%s], %d ore tiles, %d failed, area (%d,%d)-(%d,%d) "
    .. "relative to the CC", facing, util.pos_str(origin), #made, table.concat(names, " "), ore, failed,
    area.left_top.x - origin.x, area.left_top.y - origin.y, area.right_bottom.x - origin.x,
    area.right_bottom.y - origin.y)
  return {origin = {x = origin.x, y = origin.y}, area = area, entities = #made, ore_tiles = ore, failed = failed}
end

local function scratch_surface()
  local surface = game.surfaces[basetemplate.SURFACE]
  if surface then return surface end
  surface = game.create_surface(basetemplate.SURFACE, {
    no_enemies_mode = true,
    peaceful_mode = true,
    default_enable_all_autoplace_controls = false,
    autoplace_settings = {
      entity = {treat_missing_as_default = false, settings = {}},
      decorative = {treat_missing_as_default = false, settings = {}},
    },
  })
  surface.request_to_generate_chunks({0, 0}, 3)
  surface.force_generate_chunk_requests()
  -- Pave both template sites (map gen may have placed water or cliffs there).
  local tiles = {}
  for _, origin in pairs(basetemplate.ORIGINS) do
    local R = basetemplate.CLEAR_RADIUS
    for x = origin.x - R, origin.x + R - 1 do
      for y = origin.y - R, origin.y + R - 1 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
    end
  end
  surface.set_tiles(tiles, true, true, true, false)
  -- Players never need to see it.
  for _, force in pairs(game.forces) do
    pcall(force.set_surface_hidden, surface, true)
  end
  return surface
end

--- Build the scratch surface and both template variants once (idempotent).
function basetemplate.ensure()
  local st = storage.basetemplate
  if st.built and game.surfaces[basetemplate.SURFACE] then return end
  if not game.forces[basetemplate.FORCE] then
    local f = game.create_force(basetemplate.FORCE)
    f.ai_controllable = false
  end
  local surface = scratch_surface()
  st.variants = {[1] = build_variant(surface, 1), [-1] = build_variant(surface, -1)}
  st.built = true
end

--- Facing of a base at `position`: +1 when the arena centre is to its east (x < 0), else -1.
function basetemplate.facing_for(position)
  local x = util.xy(position)
  return x <= buildings.ARENA_CENTRE.x and 1 or -1
end

--- Clone the template into `surface` for `force_name` with its CC centre at `cc_position` (rounded to a tile
--- corner). facing defaults to basetemplate.facing_for(cc_position). Everything inside the destination area is
--- cleared first (clear_destination_entities), including an existing CC composite there. The clones are
--- registered with buildings.lua and enabled; the CC buffer is filled.
--- Returns {cc = LuaEntity?, area = BoundingBox, entities = number, kinds = {[kind] = count}}.
function basetemplate.clone_to(surface, force_name, cc_position, facing)
  basetemplate.ensure()
  local px, py = util.xy(cc_position)
  local cx, cy = math.floor(px + 0.5), math.floor(py + 0.5)
  facing = facing or basetemplate.facing_for({cx, cy})
  local v = storage.basetemplate.variants[facing]
  local dx, dy = cx - v.origin.x, cy - v.origin.y
  local src = v.area
  local dst = {left_top = {x = src.left_top.x + dx, y = src.left_top.y + dy},
               right_bottom = {x = src.right_bottom.x + dx, y = src.right_bottom.y + dy}}
  local scratch = game.surfaces[basetemplate.SURFACE]
  scratch.clone_area({source_area = src, destination_area = dst, destination_surface = surface,
                      destination_force = force_name, clone_tiles = false, clone_entities = true,
                      clone_decoratives = false, clear_destination_entities = true,
                      clear_destination_decoratives = true, expand_map = false, create_build_effect_smoke = false})
  local result = {area = dst, entities = 0, kinds = {}}
  local others = {}
  for _, e in pairs(surface.find_entities_filtered({area = dst, force = force_name})) do
    if e.disabled_by_script then e.disabled_by_script = false end
    result.entities = result.entities + 1
    local rec = buildings.register(e)
    if not rec then others[e.name] = (others[e.name] or 0) + 1 end
    if rec then
      result.kinds[rec.kind] = (result.kinds[rec.kind] or 0) + 1
      if rec.kind == "cc" then
        rec.parts = nil
        buildings.core_parts(rec)
        e.energy = e.electric_buffer_size or 0
        result.cc = e
      end
    end
  end
  local kinds = {}
  for k, n in pairs(result.kinds) do kinds[#kinds + 1] = k .. "=" .. n end
  for k, n in pairs(others) do kinds[#kinds + 1] = k .. "=" .. n end
  table.sort(kinds)
  util.log("basetemplate: cloned variant %+d for %s, CC at (%d, %d): %d entities [%s]", facing, force_name, cx, cy,
    result.entities, table.concat(kinds, " "))
  return result
end

return basetemplate
