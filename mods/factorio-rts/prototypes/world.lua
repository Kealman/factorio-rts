-- Phase 5 M1 world (docs/PHASE5-M1.md §3 world.lua; study docs/research/scale/world-map.md §3.3): the tiles and the
-- noise program of Nation-mode maps. scripts/world.lua plans a skeleton in Lua (ranges with passes, rivers with fords,
-- coasts, lakes, climate anchors, protected sites) and writes it into MapGenSettings.property_expression_names as
-- numeric constants; the named noise expressions below read those constants and the engine paints the terrain.
--
-- Tiles
--   rts-mountain  impassable rock: collides with the player layer (units, spider legs, haulers, characters), with
--                 item / object / floor (no building, no belt, no rail) and doodad / resource (no decoratives, no ore).
--                 No water_tile layer, so landfill cannot fill it.
--   rts-ford      walkable shallow water (a water-shallow copy): no player layer, so every unit walks through it;
--                 water_tile blocks buildings and ground rails. The crossings of rivers.
--   rts-marsh     swamp pools (a water-mud copy): walkable, not buildable.
--
-- Constant slots (default values make a slot inert). The counts must match scripts/world.lua world.SLOTS; the script
-- checks that the last slot of each kind exists. Coordinates are tiles, (0, 0) is the map centre.
--   rts_w_rg<i>_{ax,ay,bx,by,w}   mountain range segment i, half thickness w             (SLOTS.range)
--   rts_w_ps<i>_{x,y,r}           pass i: a disc cut out of the ranges                   (SLOTS.pass)
--   rts_w_rv<i>_{ax,ay,bx,by,w}   river segment i, half width w                          (SLOTS.river)
--   rts_w_fd<i>_{x,y,r}           ford i: a disc of rts-ford across a river              (SLOTS.ford)
--   rts_w_st<i>_{x,y,r}           protected site i: land, no range, no river, no marsh   (SLOTS.site)
--   rts_w_lk<i>_{x,y,r}           lake i                                                 (SLOTS.lake)
--   rts_w_cl<i>_{x,y,r,m,a,s}     climate anchor i: moisture, aux and swamp deltas, full within r/2, gone at r
--   rts_w_sea_{n,s,e,w}           sea depth in tiles along each map edge (negative = no sea)
--   rts_w_half                    map half size; rts_w_warp: domain warp amplitude in tiles
-- Ranges, passes, rivers, fords and lakes are evaluated in warped coordinates (rts_w_wx, rts_w_wy), so straight
-- segments come out organic and a pass or ford stays exactly on its barrier. Sites use plain coordinates.
local SLOTS = {range = 16, pass = 12, river = 12, ford = 16, site = 24, lake = 12, climate = 24}

local function const(name, value)
  return {type = "noise-expression", name = name, expression = tostring(value)}
end

local list = {}
local function add(t) list[#list + 1] = t end

for i = 1, SLOTS.range do
  for _, k in ipairs({"ax", "ay", "bx", "by"}) do add(const("rts_w_rg" .. i .. "_" .. k, 0)) end
  add(const("rts_w_rg" .. i .. "_w", -10000))
end
for i = 1, SLOTS.pass do
  add(const("rts_w_ps" .. i .. "_x", 0)); add(const("rts_w_ps" .. i .. "_y", 0)); add(const("rts_w_ps" .. i .. "_r", -10000))
end
for i = 1, SLOTS.river do
  for _, k in ipairs({"ax", "ay", "bx", "by"}) do add(const("rts_w_rv" .. i .. "_" .. k, 0)) end
  add(const("rts_w_rv" .. i .. "_w", -10000))
end
for i = 1, SLOTS.ford do
  add(const("rts_w_fd" .. i .. "_x", 0)); add(const("rts_w_fd" .. i .. "_y", 0)); add(const("rts_w_fd" .. i .. "_r", -10000))
end
for i = 1, SLOTS.site do
  add(const("rts_w_st" .. i .. "_x", 0)); add(const("rts_w_st" .. i .. "_y", 0)); add(const("rts_w_st" .. i .. "_r", -10000))
end
for i = 1, SLOTS.lake do
  add(const("rts_w_lk" .. i .. "_x", 0)); add(const("rts_w_lk" .. i .. "_y", 0)); add(const("rts_w_lk" .. i .. "_r", -10000))
end
for i = 1, SLOTS.climate do
  add(const("rts_w_cl" .. i .. "_x", 0)); add(const("rts_w_cl" .. i .. "_y", 0)); add(const("rts_w_cl" .. i .. "_r", 1))
  for _, k in ipairs({"m", "a", "s"}) do add(const("rts_w_cl" .. i .. "_" .. k, 0)) end
end
for _, e in ipairs({"n", "s", "e", "w"}) do add(const("rts_w_sea_" .. e, -1000)) end
add(const("rts_w_half", 1024))
add(const("rts_w_warp", 0))

-- Distance helpers. seg: w minus the distance from (px, py) to the segment a-b (> 0 inside the band).
add({type = "noise-function", name = "rts_w_seg", parameters = {"px", "py", "ax", "ay", "bx", "by", "w"},
     expression = "w - sqrt((px - ax - t * (bx - ax))^2 + (py - ay - t * (by - ay))^2)",
     local_expressions = {
       t = "clamp(((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / max((bx - ax)^2 + (by - ay)^2, 1), 0, 1)",
     }})
add({type = "noise-function", name = "rts_w_disc", parameters = {"px", "py", "cx", "cy", "r"},
     expression = "r - sqrt((px - cx)^2 + (py - cy)^2)"})
-- climate cone: 1 within r/2, 0 beyond r
add({type = "noise-function", name = "rts_w_cone", parameters = {"px", "py", "cx", "cy", "r"},
     expression = "clamp(2 - 2 * sqrt((px - cx)^2 + (py - cy)^2) / max(r, 1), 0, 1)"})

local function join(parts) return table.concat(parts, ", ") end
local function seg_terms(prefix, n)
  local t = {}
  for i = 1, n do
    local p = prefix .. i .. "_"
    t[i] = string.format("rts_w_seg(rts_w_wx, rts_w_wy, %sax, %say, %sbx, %sby, %sw)", p, p, p, p, p)
  end
  return t
end
local function disc_terms(prefix, n, px, py)
  local t = {}
  for i = 1, n do
    local p = prefix .. i .. "_"
    t[i] = string.format("rts_w_disc(%s, %s, %sx, %sy, %sr)", px, py, p, p, p)
  end
  return t
end
local function cone_sum(field, n)
  local t = {}
  for i = 1, n do
    local p = "rts_w_cl" .. i .. "_"
    t[i] = string.format("%s%s * rts_w_cone(x, y, %sx, %sy, %sr)", p, field, p, p, p)
  end
  return table.concat(t, " + ")
end

-- Warped coordinates: two octaves of basis noise, amplitude rts_w_warp tiles (scripts/world.lua samples
-- rts_w_dx / rts_w_dy to place chokes in plain coordinates).
-- The second octave is weak on purpose: a steep warp squeezes a band (measured: a 0.35 octave at 1/70 thinned
-- 30-tile barriers to 18 tiles, and the artillery spider bridged them).
add({type = "noise-expression", name = "rts_w_dx",
     expression = "rts_w_warp * (basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1301, input_scale = 1/260}\z
                   + 0.12 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1302, input_scale = 1/90})"})
add({type = "noise-expression", name = "rts_w_dy",
     expression = "rts_w_warp * (basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1303, input_scale = 1/260}\z
                   + 0.12 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1304, input_scale = 1/90})"})
add({type = "noise-expression", name = "rts_w_wx", expression = "x + rts_w_dx"})
add({type = "noise-expression", name = "rts_w_wy", expression = "y + rts_w_dy"})

-- Protected sites (> 0 inside a site disc), passes, fords.
add({type = "noise-expression", name = "rts_w_site", expression = "max(" .. join(disc_terms("rts_w_st", SLOTS.site, "x", "y")) .. ")"})
add({type = "noise-expression", name = "rts_w_pass",
     expression = "max(" .. join(disc_terms("rts_w_ps", SLOTS.pass, "rts_w_wx", "rts_w_wy")) .. ")"})
add({type = "noise-expression", name = "rts_w_ford_zone",
     expression = "max(" .. join(disc_terms("rts_w_fd", SLOTS.ford, "rts_w_wx", "rts_w_wy")) .. ")"})

-- Mountains: > 0 on rts-mountain. Rough edges (about 3 tiles), cut by passes and protected sites.
add({type = "noise-expression", name = "rts_w_mountain",
     expression = "min(raw, -rts_w_pass, -rts_w_site)",
     local_expressions = {
       raw = "max(" .. join(seg_terms("rts_w_rg", SLOTS.range)) .. ")\z
              + 3 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1311, input_scale = 1/22}",
     }})
-- Rivers: > 0 inside the channel.
add({type = "noise-expression", name = "rts_w_river",
     expression = "max(" .. join(seg_terms("rts_w_rv", SLOTS.river)) .. ")\z
                   + 1.5 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1312, input_scale = 1/26}"})
-- Fords: > 0 inside a ford disc and within 3 tiles of a river channel.
add({type = "noise-expression", name = "rts_w_ford", expression = "min(rts_w_ford_zone, rts_w_river + 3)"})
-- Lakes: > 0 inside.
add({type = "noise-expression", name = "rts_w_lake",
     expression = "max(" .. join(disc_terms("rts_w_lk", SLOTS.lake, "rts_w_wx", "rts_w_wy")) .. ")\z
                   + 2.5 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1313, input_scale = 1/14}"})
-- Sea: < 0 within rts_w_sea_<edge> tiles of an edge, with a noisy coast line.
add({type = "noise-expression", name = "rts_w_coast",
     expression = "min(rts_w_half + y + cn - rts_w_sea_n, rts_w_half - y + cn - rts_w_sea_s,\z
                       rts_w_half - x + cn - rts_w_sea_e, rts_w_half + x + cn - rts_w_sea_w)",
     local_expressions = {
       cn = "40 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1314, input_scale = 1/260}\z
             + 10 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1315, input_scale = 1/60}",
     }})

-- Elevation (property "elevation"): land is at least 4; rivers, lakes and the sea go below 0 (water_base: water at
-- elevation < 0, deepwater below -2). Protected sites are lifted above 0; planned lakes override that.
add({type = "noise-expression", name = "rts_w_elevation",
     expression = "min(max(min(land, -0.6 * rts_w_river, 0.3 * rts_w_coast), min(8, 0.2 * rts_w_site)), -0.6 * rts_w_lake)",
     local_expressions = {
       land = "max(4, 14 + 6 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1321, input_scale = 1/350}\z
                       + 3 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1322, input_scale = 1/110})",
     }})

-- Climate: moisture and aux of Nauvis plus the anchors (deserts, forests, swamps, highlands).
add({type = "noise-expression", name = "rts_w_moisture", expression = "clamp(moisture_nauvis + " .. cone_sum("m", SLOTS.climate) .. ", 0, 1)"})
add({type = "noise-expression", name = "rts_w_aux", expression = "clamp(aux_nauvis + " .. cone_sum("a", SLOTS.climate) .. ", 0, 1)"})
add({type = "noise-expression", name = "rts_w_swamp", expression = cone_sum("s", SLOTS.climate)})
-- Marsh pools: > 0 where the swamp field is strong, on land, outside protected sites and mountains.
add({type = "noise-expression", name = "rts_w_marsh",
     expression = "min(rts_w_swamp * (0.75 + 0.6 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1333, input_scale = 1/70}) - 0.3,\z
                       pool - 0.3, -rts_w_site, rts_w_elevation - 1, -rts_w_mountain, -rts_w_ford)",
     local_expressions = {
       pool = "basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1331, input_scale = 1/16}\z
               + 0.5 * basis_noise{x = x, y = y, seed0 = map_seed, seed1 = 1332, input_scale = 1/6}",
     }})

-- Cliffs only on mountain rims: one contour at rts_w_mountain = -2.5 (cliff_elevation_0 = 20, interval 40 in the
-- runtime cliff_settings); the next contours lie on mountain tiles (cliffs cannot be placed there) or where
-- cliffiness is 0.
add({type = "noise-expression", name = "rts_w_cliff_elevation", expression = "30 + 4 * rts_w_mountain"})
add({type = "noise-expression", name = "rts_w_cliffiness", expression = "if(rts_w_mountain > -8, 1, 0)"})

data:extend(list)

---------------------------------------------------------------------------
-- Tiles
---------------------------------------------------------------------------
-- Grey rock: Gleba's highland-dark-rock when Space Age is on (its sprites are then loaded on every surface), else a
-- darkened dirt-7. Cliffs line the rims either way, and the map colour is a light grey.
local rock = data.raw.tile["highland-dark-rock"] and "highland-dark-rock" or "dirt-7"
local mountain = table.deepcopy(data.raw.tile[rock])
mountain.name = "rts-mountain"
mountain.localised_name = {"tile-name.rts-mountain"}
mountain.order = "z[rts]-a[mountain]"
mountain.sprite_usage_surface = nil
mountain.absorptions_per_second = nil
if rock == "dirt-7" then mountain.tint = {0.62, 0.59, 0.56} end
mountain.map_color = {r = 196, g = 192, b = 188}
mountain.collision_mask = {layers = {item = true, object = true, player = true, doodad = true, resource = true, floor = true}}
mountain.autoplace = {probability_expression = "if(rts_w_mountain > 0, 300, -inf)"}
mountain.minable = nil
mountain.walking_speed_modifier = 1

local ford = table.deepcopy(data.raw.tile["water-shallow"])
ford.name = "rts-ford"
ford.localised_name = {"tile-name.rts-ford"}
ford.order = "z[rts]-b[ford]"
ford.map_color = {r = 92, g = 150, b = 156}
ford.autoplace = {probability_expression = "if(rts_w_ford > 0, 400, -inf)"}

local marsh = table.deepcopy(data.raw.tile["water-mud"])
marsh.name = "rts-marsh"
marsh.localised_name = {"tile-name.rts-marsh"}
marsh.order = "z[rts]-c[marsh]"
marsh.map_color = {r = 70, g = 82, b = 52}
marsh.autoplace = {probability_expression = "if(rts_w_marsh > 0, 250, -inf)"}

data:extend({mountain, ford, marsh})
