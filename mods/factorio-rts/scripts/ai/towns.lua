-- Phase 5 M1 integration: the AI's second city is a mining town (Nation mode only; the governor of M2 replaces it).
--
-- Site. Instead of the nearest world city site (cities.lua), the AI founds its second city right next to an iron (or
-- copper) region patch TOWN_MIN..TOWN_MAX tiles from its capital: the City Center stands where a forward hub would
-- (layout.hub_site, the patch side that faces the capital), so the patch lies inside the village's 48-tile land.
--
-- Mining line. Once the City Center stands, a mining line runs from the patch into the City Center's two stockpiles
-- (it is a hub subtype with the hub's stockpile layout and 1 MW of power): DRILLS extractors, two direct slots (ore)
-- and two smelter slots (plates). The town's network exports what it mines; the AI's rail line (rails.lua) takes
-- it to the capital by train, and the capital keeps ORE_KEEP ore for its Smelting works district (ai/age_up.lua).
--
-- Rails. A depot site next to the City Center, close enough that the depot's logistic area touches the City Center's
-- (so the train loads what the town mines), is reserved before the line is planned and handed to rails.lua
-- (rails.ai_set_far_site).
--
-- State: C.town = {site = {x, y}, ore, patch = {cx, cy, id}, status = nil | "ok" | "failed", line = "town1",
-- depot_site, policies}. Log lines "[rts] ai <force>: town ...".
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local layout = require("scripts.ai.layout")
local construction = require("scripts.ai.construction")
local build_order = require("scripts.ai.build_order")
local deps = require("scripts.ai.deps")
local mapgen = require("scripts.mapgen")
local production = require("scripts.production")
local AI_BALANCE = require("balance").nation.economy.ai

local towns = {}

towns.TOWN_MIN = 170          -- tiles from the capital (the AI's rail line starts at 150, balance.nation.rails)
towns.TOWN_MAX = 560
towns.ORE_PENALTY = {["iron-ore"] = 0, ["copper-ore"] = 400} -- tiles added to a patch's distance (iron: the capital
                                                                -- uses all it gets; copper piles up)
towns.CANDIDATES = 8          -- patches tried per site search
towns.CONTEXT_RADIUS = 48     -- planning context around the patch centre
towns.LINE = "town1"
towns.DRILLS = 6
towns.SLOTS = {"direct", "direct", "smelter", "smelter"} -- ore first: the capital's Smelting works take it
towns.DEPOT_REACH = 27        -- Chebyshev distance depot -> City Center: their logistic areas (14 + 16) touch
towns.ORE_KEEP = 3000         -- the capital keeps this much of the town's ore (trains bring it)
towns.PERIOD = 5 * 60         -- ticks between two town passes of a commander
towns.OTHER_CITY_GAP = 140    -- Phase 5 M2 ai: a town's patch lies at least this far from another force's city
towns.STEEL_WAIT = 4 * 60 * 60 -- Phase 5 M2 ai: Age I: the town's line waits this long at most for the capital's steel

local function nation()
  return deps.ages ~= nil and deps.ages.is_nation()
end

-- Live region patches of the world (mapgen records), iron and copper only.
local function region_patches()
  local out = {}
  for _, p in ipairs(mapgen.patches(nil, "region")) do
    if towns.ORE_PENALTY[p.name] and (p.remaining or p.total or 0) > 0 and p.box then out[#out + 1] = p end
  end
  return out
end

-- The layout patch (ctx) of the recorded patch p: same resource, nearest centre.
local function layout_patch(ctx, p)
  local best, bd
  for _, q in ipairs(layout.patches(ctx)) do
    if q.name == p.name then
      local d = util.distance({q.cx, q.cy}, p.center)
      if not bd or d < bd then best, bd = q, d end
    end
  end
  return best
end

local function city_centers()
  local list = {}
  for _, c in pairs(storage.cities or {}) do list[#list + 1] = c.position end
  return list
end

--- A town site for commander C (capital at `home`): {x, y} next to an iron or copper region patch, or nil. Records
--- C.town. Called by cities.ai_step instead of its world-site search.
function towns.pick_site(C, surface, home)
  if not nation() then return nil end
  local territory = deps.territory
  -- Phase 5 M2 ai: not next to another force's city (a city-state or a rival town): seed 702's town line ran onto a
  -- rival's land and 220 of its parts were given up
  local others = {}
  for _, c in pairs(storage.cities or {}) do
    if c.force ~= C.force and c.position then others[#others + 1] = c.position end
  end
  local function near_other(pos)
    for _, q in ipairs(others) do
      if util.distance(q, pos) < towns.OTHER_CITY_GAP then return true end
    end
    return false
  end
  local cands = {}
  for _, p in ipairs(region_patches()) do
    local d = util.distance(p.center, home)
    if d >= towns.TOWN_MIN and d <= towns.TOWN_MAX and not near_other(p.center)
       and not (territory and territory.owner_at(p.center) and territory.owner_at(p.center) ~= C.force) then
      cands[#cands + 1] = {p = p, s = d + towns.ORE_PENALTY[p.name]}
    end
  end
  table.sort(cands, function(a, b)
    if a.s ~= b.s then return a.s < b.s end
    return a.p.id < b.p.id
  end)
  local half = layout.arena_half()
  for i, c in ipairs(cands) do
    if i > towns.CANDIDATES then break end
    local p = c.p
    local ctx = layout.context_at(C, surface, {cx = math.floor(p.center.x), cy = math.floor(p.center.y), fx = 1},
      towns.CONTEXT_RADIUS)
    local cp = layout_patch(ctx, p)
    local site = cp and layout.hub_site(C, ctx, cp, home, 0, city_centers(), 96)
    local ok, why = false, cp and "no site next to the patch" or "patch not generated"
    if site then
      local inside = math.abs(site.x) < half - 12 and math.abs(site.y) < half - 12
      local can, reason = true, nil
      if territory then can, reason = territory.can_build(C.force, "rts-city-center", site) end
      ok = inside and can
      why = not inside and "outside the map" or reason
    end
    if ok then
      layout.reserve_hub_body(C, site.x, site.y, "town")
      C.town = {site = {x = site.x, y = site.y}, ore = p.name, patch = {cx = p.center.x, cy = p.center.y, id = p.id}}
      util.log("ai %s: town site %s next to %s (%s, %.0f tiles from the capital)", C.force, util.pos_str(site), p.id,
        p.name, util.distance(site, home))
      return {x = site.x, y = site.y}, "mining town at " .. p.id
    end
    util.log("ai %s: town patch %s rejected: %s", C.force, p.id, tostring(why))
  end
  return nil
end

-- The town's city record (the City Center on T.site), or nil.
local function town_city(C, T)
  local cities = deps.cities
  if not cities then return nil end
  for _, c in ipairs(cities.for_force(C.force)) do
    if not c.capital and util.distance(c.position, T.site) <= 3 and c.entity and c.entity.valid then return c end
  end
  return nil
end

-- A depot site next to the City Center whose logistic area touches it and whose platform fits; reserved.
local function reserve_depot_site(C, ctx, surface, site)
  local rails = deps.rails
  if not (rails and rails.platform_fits) then return nil end
  local best
  for r = 8, towns.DEPOT_REACH do
    for _, off in ipairs({{r, 0}, {-r, 0}, {0, r}, {0, -r}, {r, r}, {-r, r}, {r, -r}, {-r, -r}}) do
      local p = {x = site.x + off[1], y = site.y + off[2]}
      if not best then
        local free = true
        for tx = p.x - 3, p.x + 2 do
          for ty = p.y - 3, p.y + 2 do
            if not layout.free(ctx, tx, ty) or ctx.ore[layout.tkey(tx, ty)] then free = false end
          end
        end
        local spec = free and surface.can_place_entity({name = "rts-depot", position = p, force = C.force})
          and rails.platform_fits(surface, C.force, p)
        if spec then
          local a = spec.area
          for tx = math.floor(a[1][1]), math.ceil(a[2][1]) - 1 do
            for ty = math.floor(a[1][2]), math.ceil(a[2][2]) - 1 do
              if not layout.free(ctx, tx, ty) or ctx.ore[layout.tkey(tx, ty)] then free = false end
            end
          end
          if free then best = {p = p, area = a} end
        end
      end
    end
    if best then break end
  end
  if not best then return nil end
  local function res(x0, y0, x1, y1)
    for tx = x0, x1 do
      for ty = y0, y1 do layout.tset(C.reserved, tx, ty, "town-depot") end -- Phase 5 M3 perf: tile sets
    end
  end
  res(best.p.x - 3, best.p.y - 3, best.p.x + 2, best.p.y + 2)
  local a = best.area
  res(math.floor(a[1][1]), math.floor(a[1][2]), math.ceil(a[2][1]) - 1, math.ceil(a[2][2]) - 1)
  return best.p
end

-- Plan the town's mining line into the City Center (once).
local function plan(C, surface, T)
  local ctx = layout.context_at(C, surface, {cx = math.floor(T.patch.cx), cy = math.floor(T.patch.cy), fx = 1},
    towns.CONTEXT_RADIUS)
  local cp = layout_patch(ctx, {name = T.ore, center = {x = T.patch.cx, y = T.patch.cy}})
  if not cp then
    T.status = "failed"
    util.log("ai %s: town: the patch at %s is gone", C.force, util.pos_str({T.patch.cx, T.patch.cy}))
    return
  end
  T.depot_site = reserve_depot_site(C, ctx, surface, T.site)
  if T.depot_site and deps.rails and deps.rails.ai_set_far_site then deps.rails.ai_set_far_site(C.force, T.depot_site) end
  local frame = layout.hub_frame(T.site.x, T.site.y)
  local slot_states = {}
  layout.reserve_hub(C, frame, slot_states, layout.HUB_SINK_ORDER)
  local sink = {frame = frame, hub = slot_states, order = layout.HUB_SINK_ORDER, target = {x = T.site.x, y = T.site.y},
                wire = layout.HUB_WIRE, satellites = false}
  local slots = {}
  for i, s in ipairs(towns.SLOTS) do slots[i] = s end
  local L = build_order.plan_line(C, ctx, towns.LINE, {ore = T.ore, patch_id = cp.id, slots = slots}, sink)
  if L.status ~= "ok" then
    T.status = "failed"
    util.log("ai %s: town line failed: %s", C.force, tostring(L.reason))
    return
  end
  local specs, poles = {}, {}
  for _, s in ipairs(L.slots) do
    for _, key in ipairs(s.keys) do
      local e = C.plan[key]
      specs[#specs + 1] = {name = e.name, x = e.x, y = e.y}
    end
  end
  for _, key in pairs(L.gap_poles) do poles[#poles + 1] = {x = C.plan[key].x, y = C.plan[key].y} end
  for _, key in ipairs(L.chain) do poles[#poles + 1] = {x = C.plan[key].x, y = C.plan[key].y} end
  T.poles = {}
  for _, q in ipairs(layout.cover_power(C, ctx, T.site, specs, poles, towns.LINE)) do
    T.poles[#T.poles + 1] = construction.add(C, {name = layout.POLE, x = q.x, y = q.y, line = towns.LINE})
  end
  T.status = "ok"
  local names = {}
  for i, s in ipairs(L.slots) do names[i] = s.name end
  util.log("ai %s: town line planned on %s: %d drill spots, slots [%s], chained %s, %d extra poles, depot site %s",
    C.force, cp.id, #L.drills, table.concat(names, " "), tostring(L.chained), #T.poles,
    T.depot_site and util.pos_str(T.depot_site) or "none")
end

-- Policies: the town keeps nothing (its plates and ore leave by train), the capital keeps the town's ore.
local function policies(C, T, city)
  local L = deps.logistics
  if not L or T.policies == city.center then return end
  for _, item in ipairs({"iron-plate", "copper-plate"}) do L.set_policy(city.center, "keep", item, nil) end
  local ore = T.ore
  L.set_policy(city.center, "export_above", ore, 0)
  local plate = ore == "copper-ore" and "copper-plate" or "iron-plate"
  L.set_policy(city.center, "export_above", plate, 0)
  local cc = buildings.main_cc(C.force)
  if cc then L.set_policy(cc.entity.unit_number, "keep", ore, towns.ORE_KEEP) end
  T.policies = city.center
  util.log("ai %s: town #%d exports %s and %s, the capital keeps %d %s", C.force, city.center, ore, plate,
    towns.ORE_KEEP, ore)
end

--- One pass (ai/commander.lua, every run; work every PERIOD): plan the town's line once its City Center stands, then
--- keep its drills, slots and poles queued until they are built.
function towns.step(C, surface)
  towns.coal_hub_step(C)
  local T = C.town
  if not (T and nation()) or game.tick < (T.next or 0) then return end
  T.next = game.tick + towns.PERIOD
  local city = town_city(C, T)
  if not city then return end
  if not T.status then plan(C, surface, T) end
  if T.status ~= "ok" then return end
  policies(C, T, city)
  local L = C.lines[towns.LINE]
  if not L then return end
  -- the town's parts wait while the army is below the floor in Age I (its plates defend the capital first)
  if deps.ages.of(C.force) < 2 and production.army_size(C.force) < (AI_BALANCE.min_army or 0) then return end
  -- Phase 5 M2 ai: in Age I they also wait for the capital's steel (at most STEEL_WAIT): a town founded half a minute
  -- earlier put its 90 parts ahead of the iron line's steel chain, and steel (Industrialisation's kits, the Charter)
  -- came 3-4 minutes later (seed 501: Age II 17:26 against M1's 13:19)
  if deps.ages.of(C.force) < 2 and not construction.flowing(C, "steel-plate") then
    T.steel_wait = T.steel_wait or game.tick
    if game.tick - T.steel_wait < towns.STEEL_WAIT then return end
  end
  if build_order.line_drills_built(C, L) < math.min(towns.DRILLS, #L.drills) then
    build_order.want_drills(C, L, towns.DRILLS)
  end
  if build_order.line_slots_built(C, L) < #L.slots then build_order.want_slots(C, L, #L.slots) end
  build_order.queue_list(C, T.poles)
end

--- "town: <ore> line drills 4/6 slots 2/4" (autotest minute line), or "-".
function towns.describe(C)
  local T = C.town
  if not T then return "no town" end
  local L = C.lines[towns.LINE]
  if not L or L.status ~= "ok" then return string.format("town %s at %s: %s", T.ore, util.pos_str(T.site),
    tostring(T.status or "not planned")) end
  return string.format("town %s at %s: drills %d/%d slots %d/%d", T.ore, util.pos_str(T.site),
    build_order.line_drills_built(C, L), math.min(towns.DRILLS, #L.drills), build_order.line_slots_built(C, L), #L.slots)
end

---------------------------------------------------------------------------
-- Coal hub: when no CC direct slot can take a coal line (ai/commander.lua start), a hub next to the start kit's coal
-- patch, close enough to the CC that their logistic networks join (CC 25 + hub 14 tiles, Chebyshev), takes it.
---------------------------------------------------------------------------
towns.COAL_HUB_REACH = 36   -- Chebyshev distance hub -> CC centre (the areas touch up to 39)
towns.COAL_SEARCH = 90      -- coal patches within this many tiles of the CC

-- Phase 5 M2 ai: every coal patch within COAL_SEARCH is tried, nearest first (seed 702: the nearest one's line found no
-- slot while another patch was free); a failed try leaves no reservation behind.
-- (Phase 5 M3 perf: reserved, avoid and belt_tiles are tile sets: copied bucket by bucket, layout.tcopy / tassign)
local PLAN_KEYS = {"reserved", "avoid", "belt_tiles", "claimed"}
local function plan_snapshot(C)
  local snap = {}
  for _, name in ipairs(PLAN_KEYS) do
    if name == "claimed" then
      local t = {}
      for k, v in pairs(C[name]) do t[k] = v end
      snap[name] = t
    else
      snap[name] = layout.tcopy(C[name])
    end
  end
  return snap
end
local function plan_restore(C, snap)
  for _, name in ipairs(PLAN_KEYS) do
    local t = C[name]
    if name == "claimed" then
      for k in pairs(t) do t[k] = nil end
      for k, v in pairs(snap[name]) do t[k] = v end
    else
      layout.tassign(t, snap[name])
    end
  end
end

function towns.coal_hub(C, surface)
  local home = {x = C.frame.cx, y = C.frame.cy}
  local ctx = layout.context_at(C, surface, C.frame, towns.COAL_SEARCH)
  local cands = {}
  for _, q in ipairs(layout.patches(ctx)) do
    local d = util.distance({q.cx, q.cy}, home)
    if q.name == "coal" and d <= towns.COAL_SEARCH then cands[#cands + 1] = {q = q, d = d} end
  end
  table.sort(cands, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.q.id < b.q.id
  end)
  if #cands == 0 then
    util.log("ai %s: coal hub: no coal patch within %d tiles", C.force, towns.COAL_SEARCH)
    return false
  end
  -- forget what the failed CC coal line left: its claim on the patch and its reserved tiles
  C.lines.coal = nil
  for k, v in pairs(C.claimed) do if v == "coal" then C.claimed[k] = nil end end
  local coal_tiles = {} -- Phase 5 M3 perf: tile sets
  for k, v in layout.tpairs(C.reserved) do
    if v == "coal" then coal_tiles[#coal_tiles + 1] = k end
  end
  for _, k in ipairs(coal_tiles) do
    layout.tset_k(C.reserved, k, nil)
    layout.tset_k(C.belt_tiles, k, nil)
    layout.tset_k(C.avoid, k, nil)
  end
  for k, e in pairs(C.plan) do if e.line == "coal" and e.status == "planned" then C.plan[k] = nil end end
  -- not next to the army's rally point: idle units standing on the spot kept the hub's revive failing
  local rally = C.army and C.army.rally
  for i, cand in ipairs(cands) do
    if i > 3 then break end
    local cp = cand.q
    local site = layout.hub_site(C, ctx, cp, home, 0, rally and {rally} or {}, 24, towns.COAL_HUB_REACH)
    if not site then
      util.log("ai %s: coal hub: no hub site next to %s within %d tiles of the CC", C.force, cp.id, towns.COAL_HUB_REACH)
    else
      local snap = plan_snapshot(C)
      layout.reserve_hub_body(C, site.x, site.y, "coal-hub")
      local frame = layout.hub_frame(site.x, site.y)
      local slot_states = {}
      layout.reserve_hub(C, frame, slot_states, layout.HUB_SINK_ORDER)
      local sink = {frame = frame, hub = slot_states, order = layout.HUB_SINK_ORDER, target = {x = site.x, y = site.y},
                    wire = layout.HUB_WIRE, satellites = false}
      local L = build_order.plan_line(C, ctx, "coal", {ore = "coal", patch_id = cp.id, slots = {"direct"}}, sink)
      if L.status == "ok" then
        -- the hub goes with the line's first drill (want_drills queues the chain list)
        L.chain[#L.chain + 1] = construction.add(C, {name = "rts-hub", x = site.x, y = site.y, line = "coal"})
        C.coal_hub = {x = site.x, y = site.y}
        util.log("ai %s: coal hub at %s next to %s (%.0f tiles from the CC), slots [%s]", C.force, util.pos_str(site),
          cp.id, util.distance(site, home), L.slots[1] and L.slots[1].name or "-")
        return true
      end
      util.log("ai %s: coal hub line failed: %s", C.force, tostring(L.reason))
      C.lines.coal = nil
      for k, e in pairs(C.plan) do if e.line == "coal" and e.status == "planned" then C.plan[k] = nil end end
      plan_restore(C, snap)
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Phase 5 M2 ai: coal pit, the last resort when neither a coal line nor a coal hub line fits (seed 702: one force in
-- four had no coal all match, so no hauler trip and no train): a hub next to the coal patch whose network joins the
-- CC's, and up to PIT_DRILLS extractors on the patch that drop straight into stockpiles inside the hub's logistic area
-- (no belt to route). Queued from PIT_AFTER on. C.coal_pit = {x, y, keys = {plan keys}, queued}.
---------------------------------------------------------------------------
towns.PIT_DRILLS = 2
towns.PIT_REACH = 12          -- a stockpile at most this far (Chebyshev) from the hub centre (logistic radius 14)
towns.PIT_POLES = 4           -- at most this many medium poles from the hub's hidden pole to a pit drill
towns.PIT_AFTER = 150 * 60    -- ticks of the commander's life before the pit is queued (after the opening)
local DIRS = {{0, -1}, {1, 0}, {0, 1}, {-1, 0}}

local function tiles_free(ctx, name, x, y)
  local tx0, ty0, w, h = layout.footprint(name, x, y)
  for tx = tx0, tx0 + w - 1 do
    for ty = ty0, ty0 + h - 1 do
      if not layout.free(ctx, tx, ty) then return false end
    end
  end
  return true
end

local function reserve_tiles(C, name, x, y, owner)
  local tx0, ty0, w, h = layout.footprint(name, x, y)
  for tx = tx0, tx0 + w - 1 do
    for ty = ty0, ty0 + h - 1 do layout.tset(C.reserved, tx, ty, owner) end -- Phase 5 M3 perf: tile sets
  end
end

-- Medium poles from the hub's hidden pole (supply 7.5 tiles around the hub, wire HUB_WIRE) to a drill at (x, y), on
-- free tiles; nil when no chain of PIT_POLES fits. Reserves nothing.
local function pole_chain(ctx, site, x, y, taken)
  local function covers(cx, cy, half)
    return x - 1.5 < cx + half and x + 1.5 > cx - half and y - 1.5 < cy + half and y + 1.5 > cy - half
  end
  if covers(site.x, site.y, layout.HUB_POLE_HALF) then return {} end
  local poles, from, reach = {}, {x = site.x, y = site.y}, layout.HUB_WIRE
  for _ = 1, towns.PIT_POLES do
    local dx, dy = x - from.x, y - from.y
    local d = math.sqrt(dx * dx + dy * dy)
    local t = math.min(1, (reach - 0.8) / math.max(d, 0.001))
    local ix, iy = math.floor(from.x + dx * t), math.floor(from.y + dy * t)
    local best, bd
    for ox = -1, 1 do
      for oy = -1, 1 do
        local tx, ty = ix + ox, iy + oy
        local q = {x = tx + 0.5, y = ty + 0.5}
        if layout.free(ctx, tx, ty) and not taken[layout.tkey(tx, ty)] and util.distance(q, from) <= reach then
          local dq = util.distance(q, {x = x, y = y})
          if not bd or dq < bd then best, bd = q, dq end
        end
      end
    end
    if not best then return nil end
    poles[#poles + 1] = best
    if covers(best.x, best.y, 3.5) then return poles end
    from, reach = best, layout.CC_WIRE
  end
  return nil
end

function towns.coal_pit(C, surface)
  local home = {x = C.frame.cx, y = C.frame.cy}
  local ctx = layout.context_at(C, surface, C.frame, towns.COAL_SEARCH)
  local cands = {}
  for _, q in ipairs(layout.patches(ctx)) do
    local d = util.distance({q.cx, q.cy}, home)
    if q.name == "coal" and d <= towns.COAL_SEARCH then cands[#cands + 1] = {q = q, d = d} end
  end
  table.sort(cands, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.q.id < b.q.id
  end)
  local rally = C.army and C.army.rally
  for i, cand in ipairs(cands) do
    if i > 3 then break end
    local cp = cand.q
    local site = layout.hub_site(C, ctx, cp, home, 0, rally and {rally} or {}, 24, towns.COAL_HUB_REACH)
    if site then
      local snap = plan_snapshot(C)
      layout.reserve_hub_body(C, site.x, site.y, "coal-pit")
      -- drill spots on the patch: the 5x5 mining area's coal tiles, the drop tile inside the hub's logistic area
      local spots = {}
      for _, cell in ipairs(cp.cells) do
        local x, y = cell[1] + 0.5, cell[2] + 0.5
        local ore = 0
        for tx = cell[1] - 2, cell[1] + 2 do
          for ty = cell[2] - 2, cell[2] + 2 do
            if cp.tiles[layout.tkey(tx, ty)] then ore = ore + 1 end
          end
        end
        if ore >= 8 then
          for _, d in ipairs(DIRS) do
            local sx, sy = x + 2 * d[1], y + 2 * d[2]
            -- the stockpile inside the hub's logistic area
            if math.max(math.abs(sx - site.x), math.abs(sy - site.y)) <= towns.PIT_REACH then
              spots[#spots + 1] = {x = x, y = y, sx = sx, sy = sy, dir = layout.dir_of(d[1], d[2]), ore = ore,
                                   dist = util.distance({sx, sy}, site)}
            end
          end
        end
      end
      table.sort(spots, function(a, b)
        if a.ore ~= b.ore then return a.ore > b.ore end
        if a.dist ~= b.dist then return a.dist < b.dist end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
      end)
      local keys, specs = {}, {}
      local n = 0
      for _, sp in ipairs(spots) do
        if n >= towns.PIT_DRILLS then break end
        if tiles_free(ctx, layout.DRILL, sp.x, sp.y) and tiles_free(ctx, "rts-stockpile", sp.sx, sp.sy) then
          -- the pole chain must not stand on the drill or its stockpile
          local taken = {}
          local tx0, ty0, w, h = layout.footprint(layout.DRILL, sp.x, sp.y)
          for tx = tx0, tx0 + w - 1 do
            for ty = ty0, ty0 + h - 1 do taken[layout.tkey(tx, ty)] = true end
          end
          taken[layout.tkey(math.floor(sp.sx), math.floor(sp.sy))] = true
          local chain = pole_chain(ctx, site, sp.x, sp.y, taken)
          if chain then
            reserve_tiles(C, layout.DRILL, sp.x, sp.y, "coal-pit")
            reserve_tiles(C, "rts-stockpile", sp.sx, sp.sy, "coal-pit")
            keys[#keys + 1] = construction.add(C, {name = layout.DRILL, x = sp.x, y = sp.y, dir = sp.dir,
                                                   line = "coal-pit"})
            keys[#keys + 1] = construction.add(C, {name = "rts-stockpile", x = sp.sx, y = sp.sy, line = "coal-pit"})
            for _, q in ipairs(chain) do
              layout.tset(C.reserved, math.floor(q.x), math.floor(q.y), "coal-pit") -- Phase 5 M3 perf
              keys[#keys + 1] = construction.add(C, {name = layout.POLE, x = q.x, y = q.y, line = "coal-pit"})
            end
            specs[#specs + 1] = {name = layout.DRILL, x = sp.x, y = sp.y}
            n = n + 1
          end
        end
      end
      if n > 0 then
        local hub_key = construction.add(C, {name = "rts-hub", x = site.x, y = site.y, line = "coal-pit"})
        table.insert(keys, 1, hub_key)
        C.coal_pit = {x = site.x, y = site.y, keys = keys}
        C.coal_hub = {x = site.x, y = site.y} -- its policy is the coal hub's (towns.coal_hub_step)
        util.log("ai %s: coal pit at %s next to %s (%.0f tiles from the CC): %d drills dropping into stockpiles",
          C.force, util.pos_str(site), cp.id, util.distance(site, home), n)
        return true
      end
      plan_restore(C, snap)
    end
  end
  util.log("ai %s: no coal pit either: the force has no coal of its own", C.force)
  return false
end

--- The coal hub's policy: it keeps nothing (its default plate keeps would pull plates into the joined network).
function towns.coal_hub_step(C)
  local P = C.coal_pit
  if P and not P.queued and game.tick - (C.started or 0) >= towns.PIT_AFTER then
    P.queued = true
    build_order.queue_list(C, P.keys)
    util.log("ai %s: coal pit queued (%d parts)", C.force, #P.keys)
  end
  local H = C.coal_hub
  if not H or H.set then return end
  local key = string.format("rts-hub@%.1f,%.1f", H.x, H.y)
  local e = C.plan[key]
  local hub = e and e.status == "built" and e.entity and e.entity.valid and e.entity
  if not (hub and deps.logistics) then return end
  deps.logistics.set_policy(hub.unit_number, "keep", "iron-plate", nil)
  deps.logistics.set_policy(hub.unit_number, "keep", "copper-plate", nil)
  H.set = true
end

deps.towns = towns
return towns
