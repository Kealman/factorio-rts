-- Phase 5 M2 world (docs/PHASE5-M2.md §3 "world.lua additions / strategic.lua"; study world-map.md §2.5 and §6): the
-- strategic layer of Nation worlds. Nation mode only: in Skirmish nothing is drawn and the HUD minimap and the zoom
-- limits stay as the HUD and the camera set them.
--
--   strategic.refresh(force)            (re)draw the force's chart-mode objects: region names with their resources,
--                                       choke markers with names, city names (every city: borders are public), ports;
--                                       logs "strategic: refresh <force>: N objects (...)"
--   strategic.refresh_all()             every match force
--   strategic.label(kind, position, text, opts) -> key
--                                       a chart label for other modules (trade routes, war fronts): opts.forces (force
--                                       names; nil = everyone), opts.color, opts.scale, opts.to (a dashed line from
--                                       position to here, the text at its middle), opts.key (replaces the label of that
--                                       key), opts.ttl (ticks)
--   strategic.remove(key)
--   strategic.counts(force) -> {regions, chokes, cities, ports, divisions, labels, total}
--   strategic.minimap_mode(player) -> "regional" | "world"; strategic.toggle_minimap(player) (key N, hud.lua's key
--                                       table). Regional: the HUD minimap shows about MINIMAP_TILES around the camera
--                                       and follows it; world: the whole map (the Phase 4 view).
--
-- Phase 5 M3 world3: region names, choke markers and port names are drawn once the chunk under them exists (the plan
-- assigns each to a chunk, scripts/worldgen.lua); the rest arrive with the signal "rts_world_labels" as the world fills.
-- Every PERIOD ticks: a new Nation match refreshes every match force once its world exists; city changes (signals
-- rts_city_founded / _lost / _tier, renames, captures) redraw the city names; division markers (own divisions, own
-- force only) follow their divisions. Every MINIMAP_PERIOD ticks the minimap follows the camera, and the remote view's
-- zoom limits reach the map view (strategic zoom: furthest = world size x balance.nation.world.zoom.furthest; the
-- game view still stops at the camera's 0.15).
--
-- Chart text keeps a fixed world size (scale_with_zoom off): with it on, names sized for the screen covered the whole
-- HUD minimap (docs/qa/phase5-world-notes.md gotcha 4).
--
-- Owns storage.strategic = {match_id, forces = {[force] = {regions, chokes, cities, ports = {LuaRenderObject},
--   divisions = {[division id] = LuaRenderObject}}}, city_key, labels = {[key] = {objs, forces}}, next_key,
--   players = {[player index] = {mode, x, y, zoom, touched}}, dirty_cities}.
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local world = require("scripts.world")
local worldgen = require("scripts.worldgen") -- Phase 5 M3 world3: a label is drawn once its chunk exists
local cities = require("scripts.cities")
local balance = require("balance")

local strategic = {}

local NW = (balance.nation and balance.nation.world) or {}
strategic.PERIOD = 60
strategic.MINIMAP_PERIOD = 15
strategic.MINIMAP_SIZE = 220             -- GUI units: scripts/hud.lua MINIMAP_SIZE (1 GUI px per tile at zoom 1)
strategic.MINIMAP_NAME = "rts_hud_minimap" -- scripts/hud.lua NAMES.minimap (a direct child of player.gui.screen)
strategic.MINIMAP_TILES = (NW.minimap and NW.minimap.regional_tiles) or 1000
strategic.ZOOM_FURTHEST = (NW.zoom and NW.zoom.furthest) or 1.1
strategic.CAMERA_LIMITS = {closest = {zoom = 2}, furthest = {zoom = 0.15}, furthest_game_view = {zoom = 0.15}} -- camera.lua
strategic.CITY_CHECK_PERIOD = 600        -- ticks between rename / capture checks of the city names
strategic.DIVISION_PERIOD = 120          -- ticks between division marker moves
-- Fixed world sizes at a 2048 map (scaled with the map): a region name is about 16 tiles tall.
strategic.SCALE = {region = 28, resources = 18, choke = 14, city = 16, port = 14, division = 12, label = 14}
strategic.KIND_COLORS = {
  highland = {0.95, 0.85, 0.7}, plain = {0.9, 0.95, 0.8}, lakeland = {0.75, 0.9, 1}, coast = {0.7, 0.92, 0.95},
  swamp = {0.75, 0.85, 0.6}, desert = {1, 0.9, 0.6}, forest = {0.7, 0.95, 0.7}, mountain = {0.85, 0.85, 0.92},
}
-- Zoom tiers of the chart text (the force's furthest-zoomed player): fixed world sizes read small at full zoom-out.
strategic.TIERS = {{zoom = 0.045, factor = 1.7}, {zoom = 0.09, factor = 1.3}} -- below this zoom: this factor; else 1
strategic.CHOKE_COLORS = {pass = {0.85, 0.85, 0.9}, ford = {0.55, 0.85, 1}, gap = {1, 0.7, 0.45}}
strategic.PORT_COLOR = {0.4, 0.95, 1}

local function S()
  local s = storage.strategic
  if not s then
    s = {}
    storage.strategic = s
  end
  s.forces = s.forces or {}
  s.labels = s.labels or {}
  s.players = s.players or {}
  s.next_key = s.next_key or 1
  return s
end

function strategic.init() S() end

local function nation()
  local m = storage.match
  return m ~= nil and m.phase == "running" and m.config ~= nil and m.config.mode == "nation" and storage.world ~= nil
    and storage.world.plan ~= nil and storage.world.surface ~= nil
end
strategic.nation = nation

local function surface() return storage.world and game.surfaces[storage.world.surface] end
local function k() return ((storage.world and storage.world.size) or 2048) / 2048 end

local function destroy_all(list)
  for _, o in pairs(list or {}) do
    if o.valid then o.destroy() end
  end
end

-- Sprite of a resource for rich text.
local function resource_sprite(name)
  if name == "crude-oil" then return "fluid/crude-oil" end
  if name == world.URANIUM.name then return "item/uranium-ore" end
  if prototypes.item[name] then return "item/" .. name end
  return nil
end

local function resources_text(reg)
  local list = {}
  for name, n in pairs(reg.resources or {}) do list[#list + 1] = {name = name, n = n} end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.name < b.name
  end)
  local parts = {}
  for _, r in ipairs(list) do
    local sprite = resource_sprite(r.name)
    if sprite and #parts < 5 then parts[#parts + 1] = "[img=" .. sprite .. "]" end
  end
  return #parts > 0 and table.concat(parts, " ") or nil
end

local function color3(c, a)
  a = a or 1
  return {r = (c[1] or c.r) * a, g = (c[2] or c.g) * a, b = (c[3] or c.b) * a, a = a}
end

local function text(surf, force, target, txt, color, scale, rich)
  return rendering.draw_text({text = txt, surface = surf, target = target, color = color, scale = scale,
    alignment = "center", vertical_alignment = "middle", render_mode = "chart", forces = {force},
    use_rich_text = rich or nil})
end

-- A chart text at anchor + (0, dy), dy and scale given at tier 1; the force's zoom tier (F.tier) multiplies both, and
-- F.meta remembers them so a tier change rescales the text in place (retier).
local function placed(F, surf, force, anchor, dy, txt, color, scale, rich)
  local t = F.tier or 1
  local o = text(surf, force, {x = anchor.x, y = anchor.y + dy * t}, txt, color, scale * t, rich)
  F.meta[#F.meta + 1] = {o = o, x = anchor.x, y = anchor.y, dy = dy, scale = scale}
  return o
end

local function retier(F, t)
  F.tier = t
  local keep = {}
  for _, m in ipairs(F.meta) do
    if m.o.valid then
      m.o.scale = m.scale * t
      m.o.target = {x = m.x, y = m.y + m.dy * t}
      keep[#keep + 1] = m
    end
  end
  F.meta = keep
end

-- Radius of a choke marker: half its width, at least 10 tiles.
local function max_radius(c) return math.max(10, (c.width or 20) / 2) end

local function force_color(force_name)
  if force_name == world.NEUTRAL then return world.NEUTRAL_COLOR end
  return match.FORCE_COLORS[force_name] or {r = 0.7, g = 0.7, b = 0.7}
end

local function draw_cities(F, surf, force)
  destroy_all(F.cities)
  F.cities = {}
  local keep = {}
  for _, m in ipairs(F.meta) do if m.o.valid then keep[#keep + 1] = m end end
  F.meta = keep
  local sk = k()
  for _, c in pairs(storage.cities or {}) do
    if c.entity and c.entity.valid then
      local col = force_color(c.force)
      local name = cities.display_name(c)
      local txt = c.archetype == "city_state" and {"rts-world.chart-city-state", name}
        or (c.capital and {"rts-world.chart-capital", name} or name)
      F.cities[#F.cities + 1] = placed(F, surf, force, c.position, -10 * sk, txt, color3(col), strategic.SCALE.city * sk,
        true)
    end
  end
end

-- A key of the city list (ids, forces, names, tiers): the city names are redrawn when it changes.
local function city_key()
  local parts = {}
  for id, c in pairs(storage.cities or {}) do
    parts[#parts + 1] = id .. ":" .. tostring(c.force) .. ":" .. tostring(type(c.name) == "string" and c.name or "")
      .. ":" .. tostring(c.tier) .. ":" .. tostring(c.entity and c.entity.valid)
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

--- Count of the force's strategic objects: {regions, chokes, cities, ports, divisions, labels, total}.
function strategic.counts(force_name)
  local F = S().forces[force_name]
  if not F then return {regions = 0, chokes = 0, cities = 0, ports = 0, divisions = 0, labels = 0, total = 0} end
  local function live(list)
    local n = 0
    for _, o in pairs(list or {}) do if o.valid then n = n + 1 end end
    return n
  end
  local out = {regions = live(F.region_names), chokes = live(F.choke_names), cities = live(F.cities), ports = live(F.ports),
               divisions = live(F.divisions)}
  local labels = 0
  for _, L in pairs(S().labels) do
    if not L.forces or L.forces[force_name] then labels = labels + live(L.objs) end
  end
  out.labels = labels
  out.total = live(F.regions) + live(F.chokes) + out.cities + out.ports + out.divisions + labels
  return out
end

-- Phase 5 M3 world3: one region name (and its resource line), one choke marker, one port name for a force.
local function draw_region(F, surf, force_name, reg)
  local sk = k()
  local col = strategic.KIND_COLORS[reg.kind] or {0.95, 0.92, 0.8}
  local o = placed(F, surf, force_name, reg.center, 0, reg.name, color3(col, 0.95), strategic.SCALE.region * sk)
  F.regions[#F.regions + 1] = o
  F.region_names[#F.region_names + 1] = o
  local res = resources_text(reg)
  if res then
    F.regions[#F.regions + 1] = placed(F, surf, force_name, reg.center, 16 * sk, res, color3(col, 0.9),
      strategic.SCALE.resources * sk, true)
  end
end

local function draw_choke(F, surf, force_name, c)
  local sk = k()
  local col = strategic.CHOKE_COLORS[c.kind] or {1, 1, 1}
  F.chokes[#F.chokes + 1] = rendering.draw_circle({color = color3(col, 0.9), radius = max_radius(c), width = 3,
    filled = false, target = c.position, surface = surf, render_mode = "chart", forces = {force_name}})
  local o = placed(F, surf, force_name, {x = c.position.x, y = c.position.y + max_radius(c)}, 7 * sk, c.name,
    color3(col), strategic.SCALE.choke * sk)
  F.chokes[#F.chokes + 1] = o
  F.choke_names[#F.choke_names + 1] = o
end

local function draw_port(F, surf, force_name, p)
  local sk = k()
  F.ports[#F.ports + 1] = placed(F, surf, force_name, p.position, -8 * sk,
    {"rts-world.chart-port", p.name or {"rts-world.port-label"}}, color3(strategic.PORT_COLOR), strategic.SCALE.port * sk,
    true)
end

--- (Re)draw every chart-mode object of `force`: region names (and a resource line), choke markers (circle and name),
--- city names, ports. Logs the object count.
function strategic.refresh(force)
  local force_name = type(force) == "string" and force or force.name
  if not nation() or not game.forces[force_name] then return 0 end
  local surf = surface()
  if not surf then return 0 end
  local s = S()
  local F = s.forces[force_name]
  if F then
    for _, key in ipairs({"regions", "chokes", "cities", "ports"}) do destroy_all(F[key]) end
    destroy_all(F.divisions)
  end
  F = {regions = {}, region_names = {}, chokes = {}, choke_names = {}, cities = {}, ports = {}, divisions = {}, meta = {},
       tier = F and F.tier or 1}
  s.forces[force_name] = F
  local prof = helpers.create_profiler()
  -- Phase 5 M3 world3: only labels whose chunk exists; the others come with "rts_world_labels"
  for _, reg in ipairs(world.regions()) do
    if worldgen.generated(reg.center) then draw_region(F, surf, force_name, reg) end
  end
  for _, c in ipairs(world.chokes()) do
    if worldgen.generated(c.position) then draw_choke(F, surf, force_name, c) end
  end
  for _, p in ipairs(world.sites("port")) do
    if worldgen.generated(p.position) then draw_port(F, surf, force_name, p) end
  end
  draw_cities(F, surf, force_name)
  prof.stop()
  local cnt = strategic.counts(force_name)
  log({"", string.format("[rts] strategic: refresh %s: %d objects (region names %d, region objects %d, chokes %d, "
    .. "cities %d, ports %d, divisions %d, labels %d) in ", force_name, cnt.total, cnt.regions, #F.regions, cnt.chokes,
    cnt.cities, cnt.ports, cnt.divisions, cnt.labels), prof})
  return cnt.total
end

function strategic.refresh_all()
  local m = storage.match
  local n = 0
  for _, f in ipairs((m and m.forces) or {}) do n = n + strategic.refresh(f) end
  return n
end

--- A chart label for other modules (trade routes, war fronts). Returns its key.
function strategic.label(kind, position, txt, opts)
  opts = opts or {}
  local surf = surface()
  if not (nation() and surf and position) then return nil end
  local s = S()
  local key = opts.key or (kind .. ":" .. s.next_key)
  if not opts.key then s.next_key = s.next_key + 1 end
  strategic.remove(key)
  local forces
  if opts.forces then
    forces = {}
    for _, f in ipairs(opts.forces) do forces[f] = true end
  end
  local list = opts.forces
  local col = opts.color and color3(opts.color) or {r = 1, g = 1, b = 1, a = 1}
  local scale = (opts.scale or strategic.SCALE.label) * k()
  local objs = {}
  local at = position
  if opts.to then
    objs[#objs + 1] = rendering.draw_line({surface = surf, color = col, width = 3, from = position, to = opts.to,
      dash_length = 8, gap_length = 6, render_mode = "chart", forces = list, time_to_live = opts.ttl})
    local ax, ay = util.xy(position)
    local bx, by = util.xy(opts.to)
    at = {x = (ax + bx) / 2, y = (ay + by) / 2}
  end
  if txt then
    objs[#objs + 1] = rendering.draw_text({text = txt, surface = surf, target = at, color = col, scale = scale,
      alignment = "center", vertical_alignment = "middle", render_mode = "chart", forces = list, time_to_live = opts.ttl,
      use_rich_text = true})
  end
  s.labels[key] = {kind = kind, objs = objs, forces = forces}
  return key
end

function strategic.remove(key)
  local s = S()
  local L = key and s.labels[key]
  if not L then return end
  destroy_all(L.objs)
  s.labels[key] = nil
end

---------------------------------------------------------------------------
-- Division markers (own divisions, own force only)
---------------------------------------------------------------------------
local function divisions_mod()
  local l = package and package.loaded
  return l and (l["__" .. script.mod_name .. "__/scripts/divisions.lua"] or l["scripts.divisions"])
end

local function update_divisions(force_name, F, surf)
  local div = divisions_mod()
  if not (div and div.for_force) then return end
  local seen = {}
  local sk = k()
  for _, D in ipairs(div.for_force(force_name)) do
    local sx, sy, n = 0, 0, 0
    for _, un in ipairs(div.members and div.members(D.id) or {}) do
      local rec = storage.units and storage.units[un]
      if rec and rec.entity and rec.entity.valid then
        local p = rec.entity.position
        sx, sy, n = sx + p.x, sy + p.y, n + 1
      end
    end
    if n > 0 then
      seen[D.id] = true
      local at = {x = sx / n, y = sy / n}
      local o = F.divisions[D.id]
      if o and o.valid then
        o.target = at
      else
        F.divisions[D.id] = text(surf, force_name, at, {"rts-world.chart-division", D.name or D.id},
          color3(force_color(force_name)), strategic.SCALE.division * sk * (F.tier or 1), true)
      end
    end
  end
  for id, o in pairs(F.divisions) do
    if not seen[id] then
      if o.valid then o.destroy() end
      F.divisions[id] = nil
    end
  end
end

---------------------------------------------------------------------------
-- Minimap mode and strategic zoom
---------------------------------------------------------------------------
local function pstate(index)
  local s = S()
  local p = s.players[index]
  if not p then
    p = {mode = "regional"}
    s.players[index] = p
  end
  return p
end

--- "regional" (the region around the camera) or "world" (the whole map).
function strategic.minimap_mode(player)
  return pstate(player.index).mode
end

local function apply_minimap(player, force_now)
  local el = player.gui.screen[strategic.MINIMAP_NAME]
  if not (el and el.valid) then return end
  local p = pstate(player.index)
  local W = storage.world
  local zoom, x, y
  if nation() then
    local H = W.size / 2
    if p.mode == "world" then
      zoom, x, y = strategic.MINIMAP_SIZE / (W.size + 16), 0, 0
    else
      local half = strategic.MINIMAP_TILES / 2
      zoom = strategic.MINIMAP_SIZE / strategic.MINIMAP_TILES
      local pos = player.position
      local lim = math.max(0, H - half)
      x = math.max(-lim, math.min(lim, pos.x))
      y = math.max(-lim, math.min(lim, pos.y))
    end
    p.touched = true
  elseif p.touched then
    -- back to the HUD's view of the arena (scripts/hud.lua minimap_zoom)
    p.touched = nil
    zoom, x, y = strategic.MINIMAP_SIZE / (2 * match.arena_half() + 16), 0, 0
    force_now = true
  else
    return
  end
  if force_now or not p.zoom or math.abs(p.zoom - zoom) > 1e-6 or math.abs((p.x or 0) - x) > 4 or math.abs((p.y or 0) - y) > 4 then
    el.zoom = zoom
    el.position = {x = x, y = y}
    p.zoom, p.x, p.y = zoom, x, y
  end
end

--- Switch the player's HUD minimap between regional and world (key N). Returns the new mode.
function strategic.toggle_minimap(player)
  if not nation() then return nil end
  local p = pstate(player.index)
  p.mode = p.mode == "world" and "regional" or "world"
  apply_minimap(player, true)
  player.print({"rts-world.minimap-" .. p.mode})
  util.log("strategic: minimap of player %d -> %s", player.index, p.mode)
  return p.mode
end

local function apply_zoom_limits(player)
  if player.controller_type ~= defines.controllers.remote then return end
  local zl = player.zoom_limits
  local far = zl and zl.furthest
  if nation() then
    local want = storage.world.size * strategic.ZOOM_FURTHEST
    if far and far.distance and math.abs(far.distance - want) < 1 then return end
    -- max_distance: without it the engine caps the distance at 500 tiles (measured: zoom 0.08 at 1280 px)
    player.set_zoom_limits(defines.controllers.remote, {closest = {zoom = 2},
      furthest = {distance = want, max_distance = want}, furthest_game_view = {zoom = 0.15}})
    util.log("strategic: zoom limits of player %d: map view out to %d tiles", player.index, want)
  elseif far and far.distance then
    player.set_zoom_limits(defines.controllers.remote, strategic.CAMERA_LIMITS)
    util.log("strategic: zoom limits of player %d back to the camera's", player.index)
  end
end

---------------------------------------------------------------------------
-- Ticks, signals, teardown
---------------------------------------------------------------------------
local function mark_cities() S().dirty_cities = true end

-- Phase 5 M3 world3: labels whose chunk was just generated (scripts/worldgen.lua), drawn for every refreshed force
events.on_signal("rts_world_labels", function(d)
  if not (d and d.labels and nation()) then return end
  local s = S()
  if s.match_id ~= storage.match.match_id then return end -- the first refresh of this match draws them
  local surf = surface()
  if not surf then return end
  local P = storage.world.plan
  for force_name, F in pairs(s.forces) do
    if game.forces[force_name] then
      for _, L in ipairs(d.labels) do
        if L.kind == "region" and P.regions[L.id] then draw_region(F, surf, force_name, P.regions[L.id])
        elseif L.kind == "choke" and P.chokes[L.id] then draw_choke(F, surf, force_name, P.chokes[L.id])
        elseif L.kind == "port" and P.sites[L.id] then draw_port(F, surf, force_name, P.sites[L.id]) end
      end
    end
  end
end)
events.on_signal("rts_city_founded", mark_cities)
events.on_signal("rts_city_lost", mark_cities)
events.on_signal("rts_city_tier", mark_cities)

events.on_nth_tick(strategic.PERIOD, function(e)
  if not nation() then return end
  local s = S()
  local m = storage.match
  if s.match_id ~= m.match_id then
    s.match_id = m.match_id
    s.forces, s.labels = {}, {}
    strategic.refresh_all()
    s.city_key = city_key()
    s.dirty_cities = nil
    return
  end
  local surf = surface()
  if not surf then return end
  local check = e.tick % strategic.CITY_CHECK_PERIOD == 0
  if s.dirty_cities or check then
    local key = city_key()
    if s.dirty_cities or key ~= s.city_key then
      s.city_key = key
      for force_name, F in pairs(s.forces) do draw_cities(F, surf, force_name) end
    end
    s.dirty_cities = nil
  end
  if e.tick % strategic.DIVISION_PERIOD == 0 then
    for force_name, F in pairs(s.forces) do update_divisions(force_name, F, surf) end
  end
end)

local function tier_of(zoom)
  for _, t in ipairs(strategic.TIERS) do
    if zoom < t.zoom then return t.factor end
  end
  return 1
end

events.on_nth_tick(strategic.MINIMAP_PERIOD, function(e)
  local s = storage.strategic
  local nat = nation()
  if not nat and not (s and next(s.players or {})) then return end
  local zooms = {}
  for _, player in pairs(game.connected_players) do
    apply_minimap(player)
    if e.tick % 60 == 0 then apply_zoom_limits(player) end
    if nat and player.controller_type == defines.controllers.remote then
      local f = player.force.name
      zooms[f] = math.min(zooms[f] or math.huge, player.zoom)
    end
  end
  for f, z in pairs(zooms) do
    local F = s.forces[f]
    local t = tier_of(z)
    if F and F.meta and (F.tier or 1) ~= t then retier(F, t) end
  end
end)

match.on_teardown(function()
  local s = storage.strategic
  if not s then return end
  for _, F in pairs(s.forces or {}) do
    for _, key in ipairs({"regions", "chokes", "cities", "ports", "divisions"}) do destroy_all(F[key]) end
  end
  for _, L in pairs(s.labels or {}) do destroy_all(L.objs) end
  s.forces, s.labels, s.match_id, s.city_key, s.dirty_cities = {}, {}, nil, nil, nil
end)

commands.add_command("rts-strategic", "- Nation strategic layer: object counts per force, minimap modes", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  local m = storage.match
  local lines = {}
  for _, f in ipairs((m and m.forces) or {}) do
    lines[#lines + 1] = string.format("[rts] strategic: %s %s", f, serpent.line(strategic.counts(f)))
  end
  for index, p in pairs(S().players) do
    lines[#lines + 1] = string.format("[rts] strategic: player %d minimap %s", index, p.mode)
  end
  for _, line in ipairs(lines) do
    log(line)
    if player then player.print(line) end
  end
end)

return strategic
