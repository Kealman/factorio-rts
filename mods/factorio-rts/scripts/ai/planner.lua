-- Phase 5 M3 ai (docs/PHASE5-M3.md D7, §3 "ai/planner.lua"; study docs/research/scale/war-ai-performance.md §4.2-4.3):
-- the economic planner of an AI nation. Nation mode only; ai/commander.lua calls planner.step(C, surface) in slice 1 of
-- every run, the planner works every balance.nation.ai3.planner.period ticks (staggered per nation).
--
--   planner.sites(force) -> {{id, kind, position, score, role = "oil"|"mining"|"rare"|"fortress"|"trade", parts,
--                            claimed}}          the scored candidate list (a scheduler job, kind "ai3_sites")
--   planner.next_city(force) -> site | nil   the next city site: the nation's home oil field first (the oil town),
--                                            then the best score (need-weighted ore, oil, rare, chokes, ports, minus
--                                            rail cost and exposure)
--   planner.trunk(force) -> {{from_city, to_city, state}}   minimum spanning tree over own cities rooted at the
--                                            capital; every edge rails.lua's own program does not serve runs a
--                                            rails.ai_program of its own (A.pay = the capital when rails.AI_PAY)
--   planner.targets(C) -> {[item] = n}       capital make targets the planner wants (ai/age_up.lua merges them):
--                                            the industrial kit's parts in Age II, the running Space Program stage's
--                                            goods, plastic and sulfur once crude oil comes in
--   planner.research_want(C) -> {tech, ...}  technologies first in line (ai/tech.lua): Electrification in Age II,
--                                            Geology for a rare deposit in reach
--   planner.districts(C) -> {district, ...}  extra districts for the age-up list (the oil chain, Age III districts)
--   planner.step(C, surface)                 cities, the oil town's pumpjacks, the trunk, the Space Program, rushes,
--                                            automation, rare extractors, the concrete chain, the works factory's jobs
--   planner.describe(force)                  one line for the autotest minute report
--   (0.1.1) planner.urgent_districts(C)      districts ai/age_up.lua moves to the front once (the Petrochemical works)
--           planner.engine_focus(C)          the Age III road's research waits for engines (new trunk edges wait)
--           planner.science_hold(C)          stage 1 waits for advanced circuits or engines (industrial research waits)
--           planner.pins(C), holds_works(C)  factories ai/governor.lua pins; the works factory held on a recipe
--
-- Cities. The second city stays ai/towns.lua's mining town (cities.ai_step). From the third on the planner founds
-- them: a City Center ghost in the commander's construction plan (the builder factory makes the charter), the third
-- from third_at (or once Industrialisation is researched) and the fourth from fourth_at (or Age II), times the
-- difficulty's expand (x territory_expand when the victory mode includes Territory), up to the difficulty's `cities`
-- and the nation's city limit. A site on ungenerated ground is skipped and its chunks requested (worldgen).
-- Oil town: the City Center stands where its logistic area covers the most wells of the nation's home oil field
-- (else the contested centre field); from Age II pumpjacks on the covered wells put crude oil into its network; it
-- exports crude, plastic and sulfur (auto haulers and later its train bring them to the capital, which keeps crude).
-- Age III road: Electrification first in Age II (the industrial kit's parts are make targets; what the nation cannot
-- make, market.lua's AI buys at its port), the Space Program started as soon as age3.can_start, the running stage's
-- goods as make targets, a rush when the treasury is rich and the stage mostly delivered.
--
-- State: storage.nations[force].planner = P = {next, job, sites, scored_at, city = {key, site, role, since, tries} (the
--   pending founding), tries, retry_at, roles = {[city id] = role}, oil = {city, site, deposit, pumps = {keys}, wells,
--   set}, trunk = {[city id] = {to, from, A, opened}}, space = {started, rushes}, rare = {keys = {[deposit key] =
--   plan key}}, automated = {[family] = true}, stats = {founded, given_up, edges, opened}}.
-- Log lines "[rts] planner: <force> ...".
local util = require("scripts.util")
local buildings = require("scripts.buildings")
local production = require("scripts.production")
local construction = require("scripts.ai.construction")
local mix = require("scripts.ai.mix")
local layout = require("scripts.ai.layout")
local data = require("scripts.ai.orders_data")
local deps = require("scripts.ai.deps")
local difficulty = require("scripts.ai.difficulty")
local sched = require("scripts.sched")
local mapgen = require("scripts.mapgen")
local balance = require("balance")

local planner = {}

local PB = balance.nation.ai3.planner
local CENTER = "rts-city-center"
local STEEL_WORKS = "rts-district-steel"
local SMELTING_WORKS = "rts-district-smelting"
local PETROCHEM = "rts-district-petrochem"
local ELECTRONICS_WORKS = "rts-district-electronics"
local OIL_EXPORT = {}
for _, item in ipairs(PB.oil.export) do OIL_EXPORT[item] = true end
local PUMPJACK = "rts-pumpjack"
local RARE_EXTRACTOR = balance.nation.rare and balance.nation.rare.extractor or "rts-rare-extractor"
local ELECTRIFICATION = balance.nation.age3 and balance.nation.age3.tech or "rts-electrification"
local GEOLOGY = "rts-geology"
local NUCLEAR_TECH = "rts-nuclear-power"
local NUCLEAR_PLANT = "rts-nuclear-plant"
local URANIUM = "uranium-ore"
local FUEL_ROD = "rts-fuel-rod"
local uranium_step, nuclear_ready -- the uranium outpost (defined below planner.districts and planner.targets)
local INDUSTRIALISATION = "rts-industrialisation"

-- The builder factory makes these for the construction queue (orders_data.FACTORY_RECIPE: building = recipe name).
data.FACTORY_RECIPE[PUMPJACK] = PUMPJACK
-- the workshop factory makes industrial kits for an Age II research (the factory crafts rts-science; only a Nation force
-- ever researches with them)
data.WORKSHOP_RECIPE["rts-science-industrial"] = data.WORKSHOP_RECIPE["rts-science-industrial"] or "rts-science-industrial"
data.FACTORY_RECIPE[RARE_EXTRACTOR] = RARE_EXTRACTOR
for _, name in ipairs(PB.oil_districts or {}) do data.FACTORY_RECIPE[name] = name end
planner.AGE3_DISTRICTS = {"rts-district-concrete", "rts-district-electronics2", "rts-district-chemistry"}
for _, name in ipairs(planner.AGE3_DISTRICTS) do data.FACTORY_RECIPE[name] = name end

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. name .. ".lua"] or l["scripts." .. name]
end

local function nation_mode()
  local m = storage.match
  return m ~= nil and m.config ~= nil and m.config.mode == "nation"
end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function P_of(force_name, create)
  local N = storage.nations and storage.nations[force_name]
  if not N then return nil end
  local P = N.planner
  if not P and create then
    P = {next = 0, tries = 0, roles = {}, trunk = {}, space = {rushes = 0}, rare = {keys = {}}, automated = {},
         stats = {founded = 0, given_up = 0, edges = 0, opened = 0, pumps = 0, buys = 0}}
    N.planner = P
  end
  return P
end
planner.state = function(force_name) return P_of(force_name, false) end

local function capital_of(force_name)
  local N = storage.nations and storage.nations[force_name]
  local cities = deps.cities
  return N and cities and cities.get(N.capital) or nil
end

local function match_seconds()
  local m = storage.match
  return (m and m.tick_started) and (game.tick - m.tick_started) / 60 or 0
end

local function territory_mode()
  local c = storage.match and storage.match.config
  return c ~= nil and (c.victory == "territory" or c.victory == "any")
end

local function age_of(force_name)
  return deps.ages and deps.ages.of(force_name) or 1
end

local function has_tech(force_name, name)
  return deps.research ~= nil and deps.research.has(force_name, name)
end

local function recipe_on(force_name, name)
  local f = game.forces[force_name]
  local r = f and f.recipes[name]
  return r ~= nil and r.enabled
end

---------------------------------------------------------------------------
-- Site scoring (a scheduler job: one candidate per PB.units.candidate units)
---------------------------------------------------------------------------
-- The context of a scoring run: plain data, so the job state survives a save.
local function scoring_context(force_name)
  local cap = capital_of(force_name)
  if not cap then return nil end
  local world = mod("world")
  local ctx = {force = force_name, home = {x = cap.position.x, y = cap.position.y}, cities = {}, own = {}, rivals = {},
               lacks = {}, patches = {}, oil = {}, rare = {}, chokes = {}, ports = {}}
  for _, id in ipairs((function()
    local ids = {}
    for k in pairs(storage.cities or {}) do ids[#ids + 1] = k end
    table.sort(ids)
    return ids
  end)()) do
    local c = storage.cities[id]
    if c.position then
      ctx.cities[#ctx.cities + 1] = {x = c.position.x, y = c.position.y}
      if c.force == force_name then ctx.own[#ctx.own + 1] = {x = c.position.x, y = c.position.y} end
    end
  end
  local dip = mod("diplomacy")
  for _, f in ipairs(storage.match and storage.match.forces or {}) do
    if f ~= force_name and dip and dip.capital_position then
      local p = dip.capital_position(f)
      if p then ctx.rivals[#ctx.rivals + 1] = {x = p.x, y = p.y} end
    end
  end
  local sc = world and world.scarcity and world.scarcity()
  for _, ore in ipairs(sc and sc[force_name] and sc[force_name].lacks or {}) do ctx.lacks[ore] = true end
  for _, p in ipairs(mapgen.patches(nil, "region")) do
    local left = p.remaining or p.total or 0
    if left > 0 and p.center then
      ctx.patches[#ctx.patches + 1] = {x = p.center.x, y = p.center.y, name = p.name, left = left}
    end
  end
  for _, s in ipairs(world and world.sites and world.sites("oil") or {}) do
    if s.role == "center_oil" or s.force == force_name then
      ctx.oil[#ctx.oil + 1] = {x = s.position.x, y = s.position.y, wells = s.wells or 1, home = s.force == force_name}
    end
  end
  for _, s in ipairs(world and world.sites and world.sites("rare") or {}) do
    ctx.rare[#ctx.rare + 1] = {x = s.position.x, y = s.position.y}
  end
  for _, ch in ipairs(world and world.chokes and world.chokes() or {}) do
    if ch.position then ctx.chokes[#ctx.chokes + 1] = {x = ch.position.x, y = ch.position.y} end
  end
  local market = deps.market
  for _, port in ipairs(market and market.all_ports and market.all_ports() or {}) do
    ctx.ports[#ctx.ports + 1] = {x = port.position.x, y = port.position.y}
  end
  return ctx
end

-- Candidates: the world's city sites, every oil field the nation may use, rare deposits.
local function candidates(force_name)
  local world = mod("world")
  local out = {}
  for i, s in ipairs(world and world.sites and world.sites("city_site") or {}) do
    out[#out + 1] = {id = "s" .. i, kind = "city_site", x = s.position.x, y = s.position.y}
  end
  for i, s in ipairs(world and world.sites and world.sites("oil") or {}) do
    if s.role == "center_oil" or s.force == force_name then
      out[#out + 1] = {id = "o" .. i, kind = "oil", x = s.position.x, y = s.position.y, home = s.force == force_name}
    end
  end
  for i, s in ipairs(world and world.sites and world.sites("rare") or {}) do
    out[#out + 1] = {id = "r" .. i, kind = "rare", x = s.position.x, y = s.position.y}
  end
  return out
end

-- Score of one candidate (nil when it cannot take a city), its role and the parts.
local function score(ctx, cand)
  local W = PB.weights
  local p = {x = cand.x, y = cand.y}
  local dh = dist(p, ctx.home)
  if dh < PB.min_capital or dh > PB.max_capital then return nil end
  for _, c in ipairs(ctx.cities) do
    if dist(p, c) < PB.min_city then return nil end
  end
  local ore = 0
  for _, q in ipairs(ctx.patches) do
    local d = dist(p, q)
    if d <= PB.ore_radius then
      local need = ctx.lacks[q.name] and 2 or ((q.name == "coal" and 0.8) or (q.name == "stone" and 0.5) or 1)
      ore = ore + need * math.min(q.left, PB.ore_cap) / PB.ore_cap * (1 - 0.5 * d / PB.ore_radius)
    end
  end
  local oil = 0
  for _, q in ipairs(ctx.oil) do
    if dist(p, q) <= 45 then oil = oil + (q.home and 1.5 or 1) * math.min(3, q.wells) end
  end
  local rare = 0
  for _, q in ipairs(ctx.rare) do
    if dist(p, q) <= 40 then rare = rare + 1 end
  end
  -- a choke between us and a rival (closer to the rival's capital than this site is, and on our half of the way)
  local choke = 0
  for _, q in ipairs(ctx.chokes) do
    local d = dist(p, q)
    if d <= 120 then
      for _, r in ipairs(ctx.rivals) do
        if dist(q, r) < dist(p, r) and dist(q, ctx.home) < dist(q, r) then
          choke = choke + (1 - d / 120)
          break
        end
      end
    end
  end
  local port = 0
  for _, q in ipairs(ctx.ports) do
    if dist(p, q) <= 150 then port = port + 1 end
  end
  local link = dh
  for _, c in ipairs(ctx.own) do link = math.min(link, dist(p, c)) end
  local exposure = 0
  for _, r in ipairs(ctx.rivals) do
    local d = dist(p, r)
    if d < PB.exposure_radius then exposure = exposure + (1 - d / PB.exposure_radius) end
  end
  local parts = {ore = W.need * W.ore * ore, oil = W.oil * oil, rare = W.rare * rare, choke = W.choke * choke,
                 port = W.port * port}
  local value = parts.ore + parts.oil + parts.rare + parts.choke + parts.port
  local s = value - W.rail * link / 100 - W.exposure * exposure * 3
  local role, best = "mining", -1
  for _, r in ipairs({"oil", "rare", "choke", "port", "ore"}) do
    if parts[r] > best then role, best = r, parts[r] end
  end
  role = ({oil = "oil", rare = "rare", choke = "fortress", port = "trade", ore = "mining"})[role]
  return s, role, {ore = ore, oil = oil, rare = rare, choke = choke, port = port, link = link, exposure = exposure}
end

sched.register("ai3_sites", function(job, units)
  local st = job.state
  if not st.ctx then
    st.ctx = scoring_context(st.force)
    if not st.ctx then return 1, true end
    st.cands = candidates(st.force)
    st.i = 1
    st.out = {}
    return 20 + #st.cands, false
  end
  local used = 0
  local cap = st.cap or #st.cands
  while st.i <= #st.cands and used < units do
    local cand = st.cands[st.i]
    st.i = st.i + 1
    used = used + PB.units.candidate
    local s, role, parts = score(st.ctx, cand)
    if s then
      st.out[#st.out + 1] = {id = cand.id, kind = cand.kind, position = {x = cand.x, y = cand.y}, score = s,
                             role = role, parts = parts, home = cand.home}
    end
  end
  if st.i > #st.cands then
    table.sort(st.out, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.id < b.id
    end)
    while #st.out > cap do table.remove(st.out) end
    return used, true
  end
  return used, false
end, function(job, status)
  if status ~= "done" then return end
  local P = P_of(job.state.force, false)
  if not P then return end
  P.sites = job.state.out or {}
  P.scored_at = game.tick
  P.job = nil
  local parts = {}
  for i = 1, math.min(4, #P.sites) do
    local s = P.sites[i]
    parts[#parts + 1] = string.format("%s %s %s %.1f", s.id, s.role, util.pos_str(s.position), s.score)
  end
  util.log("planner: %s scored %d sites [%s]", job.state.force, #P.sites, table.concat(parts, "; "))
end)

local function rescore(C, P)
  if P.job and sched.status(P.job) ~= nil and sched.status(P.job) ~= "done" and sched.status(P.job) ~= "cancelled"
     and sched.status(P.job) ~= "failed" then
    return
  end
  local k = difficulty.knobs(C.force)
  local state = {force = C.force, cap = k.caps.sites}
  local id = sched.submit(C.force, "ai3_sites", state, sched.BACKGROUND)
  if id then
    P.job = id
  else
    -- outside the scheduler (tests): the same step function at once
    local job = sched.run_sync("ai3_sites", state, C.force)
    P.sites = job.state.out or {}
    P.scored_at = game.tick
  end
end

function planner.sites(force_name)
  local P = P_of(force_name, false)
  return P and P.sites or {}
end

---------------------------------------------------------------------------
-- Founding
---------------------------------------------------------------------------
local function free_box(surface, force_name, pos, wells, reach)
  local proto = prototypes.entity[CENTER]
  local cb = proto and proto.collision_box
  local hw = cb and math.ceil(cb.right_bottom.x) or 3
  -- not on a well's pumpjack footprint
  for _, w in ipairs(wells or {}) do
    if math.abs(w.x - pos.x) < hw + 2 and math.abs(w.y - pos.y) < hw + 2 then return false end
  end
  if not surface.can_place_entity({name = CENTER, position = pos, force = force_name}) then return false end
  local territory = deps.territory
  if territory and not territory.can_build(force_name, CENTER, pos) then return false end
  return true
end

-- The City Center spot of an oil town near `center`: the logistic area (reach, Chebyshev) covering the most wells,
-- off every well's pumpjack footprint. Returns pos, covered wells or nil.
local function oil_spot(surface, force_name, center)
  local reach = PB.oil.reach
  local found = surface.find_entities_filtered({position = center, radius = 50, name = "crude-oil"})
  local wells = {}
  for _, e in pairs(found) do wells[#wells + 1] = {x = e.position.x, y = e.position.y} end
  table.sort(wells, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  if #wells == 0 then return nil end
  local function covered(c)
    local list = {}
    for _, w in ipairs(wells) do
      if math.max(math.abs(w.x - c.x), math.abs(w.y - c.y)) <= reach then list[#list + 1] = w end
    end
    return list
  end
  local seeds = {}
  for i, a in ipairs(wells) do
    seeds[#seeds + 1] = a
    for j = i + 1, #wells do
      local b = wells[j]
      seeds[#seeds + 1] = {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}
    end
  end
  local best, bn, bd
  for _, s in ipairs(seeds) do
    -- spots around the seed, nearest first
    for r = 0, 8 do
      local done = false
      for dx = -r, r do
        for dy = -r, r do
          if math.max(math.abs(dx), math.abs(dy)) == r then
            local pos = {x = math.floor(s.x + dx) + 0.0, y = math.floor(s.y + dy) + 0.0}
            local cov = covered(pos)
            local n = #cov
            if n > 0 and (not bn or n > bn or (n == bn and r < bd)) and free_box(surface, force_name, pos, wells) then
              best, bn, bd = pos, n, r
              done = true
            end
          end
        end
      end
      if done then break end
    end
  end
  if not best then return nil end
  return best, covered(best)
end

local function plain_spot(surface, force_name, site)
  local p = surface.find_non_colliding_position(CENTER, site, 24, 1, true)
  if not p then return nil end
  p = {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5)}
  local territory = deps.territory
  if territory and not territory.can_build(force_name, CENTER, p) then return nil end
  return p
end

local function generated(force_name, pos)
  local wg = mod("worldgen")
  if not (wg and wg.generated) then return true end
  if wg.generated(pos) then return true end
  if wg.request_area then wg.request_area(force_name, {{pos.x - 64, pos.y - 64}, {pos.x + 64, pos.y + 64}}) end
  return false
end

--- The next city site (scored list order, the home oil field first while the nation has no oil town).
function planner.next_city(force_name)
  local P = P_of(force_name, false)
  if not (P and P.sites) then return nil end
  local list = {}
  for _, s in ipairs(P.sites) do
    if not (P.tried and P.tried[s.id]) then list[#list + 1] = s end
  end
  if not P.oil then
    table.sort(list, function(a, b)
      local ao = a.kind == "oil" and (a.home and 2 or 1) or 0
      local bo = b.kind == "oil" and (b.home and 2 or 1) or 0
      if ao ~= bo then return ao > bo end
      if a.score ~= b.score then return a.score > b.score end
      return a.id < b.id
    end)
  end
  -- Phase 5 M3 ai (wave B.2): the third city within third_link tiles of an own city when such a site is left (a short
  -- trunk edge: three cities linked by rail by 35:00 in 8 of 20 nations with 300-tile edges), and no city but the oil
  -- town farther than far_city from the capital (a trade city 543 tiles out starved, M2 seed 702)
  local own = deps.cities and deps.cities.for_force(force_name) or {}
  local capital = capital_of(force_name)
  -- (0.1.1, issue #1: while the nation has no oil town, no other city within min_city of its home oil field: the
  -- 250-tile rule put a trade city 80 tiles from it, the oil field then lay inside that city's spacing and the nation
  -- never got its crude oil, seed 801 rts-ai-2 and rts-ai-3)
  local oil_site
  if not P.oil then
    for _, s in ipairs(list) do
      if s.kind == "oil" and s.home then
        oil_site = s
        break
      end
    end
  end
  local function link_of(s)
    local d = math.huge
    for _, c in ipairs(own) do
      if c.position then d = math.min(d, dist(c.position, s.position)) end
    end
    return d
  end
  for pass = 1, 2 do
    for _, s in ipairs(list) do
      -- still free: no city came within min_city since the scoring
      local ok = true
      for _, c in pairs(storage.cities or {}) do
        if c.position and dist(c.position, s.position) < PB.min_city then ok = false end
      end
      local oil_town = s.kind == "oil" and not P.oil
      if ok and not oil_town and PB.far_city and capital and capital.position
         and dist(capital.position, s.position) > PB.far_city then
        ok = false
      end
      if ok and pass == 1 and #own == 2 and PB.third_link and link_of(s) > PB.third_link then ok = false end
      if ok and oil_site and s ~= oil_site and dist(s.position, oil_site.position) < PB.min_city then ok = false end
      if ok then return s end
    end
  end
  return nil
end

-- How many cities the nation wants now (capital included).
local function wanted_cities(C)
  local k = difficulty.knobs(C.force)
  local cap = math.min(k.cities, balance.nation.cities.limit or 4)
  local f = k.expand * (territory_mode() and PB.territory_expand or 1)
  local t = match_seconds()
  local want = 2
  if t >= PB.third_at * f or has_tech(C.force, INDUSTRIALISATION) then want = 3 end
  if t >= PB.fourth_at * f or (age_of(C.force) >= 2 and t >= PB.third_at * f) then want = 4 end
  local extra = math.floor(math.max(0, t - PB.fourth_at * f) / PB.more_gap)
  return math.min(cap, want + extra)
end

-- Room for a farm inside the future City Center's logistic area (ai/governor.lua town_food looks within
-- town_area_far tiles): a site without one starved on its hauler (M2 seeds 701 and 702).
local FARM = "rts-farm"
local function farm_room(surface, force_name, pos)
  local PA = balance.nation.people.ai
  local r = PA.town_area_far or PA.town_area or 13
  for dy = -r, r, 3 do
    for dx = -r, r, 3 do
      if math.max(math.abs(dx), math.abs(dy)) >= 6 then
        local p = {x = pos.x + dx + 0.5, y = pos.y + dy + 0.5}
        if surface.can_place_entity({name = FARM, position = p, force = force_name}) then return true end
      end
    end
  end
  return false
end

local function found_step(C, P, surface, own)
  local cs = storage.city_state and storage.city_state.ai and storage.city_state.ai[C.force]
  -- the second city is cities.ai_step's (ai/towns.lua): wait for it unless that program gave up
  if #own < 2 and not (cs and cs.done) then return end
  local pending = P.city
  if pending then
    local st = construction.status(C, pending.key)
    if st == "built" then
      local e = C.plan[pending.key].entity
      local city = e and e.valid and deps.cities.of_center(e.unit_number)
      if city then
        P.roles[city.id] = pending.role
        P.stats.founded = P.stats.founded + 1
        if pending.role == "oil" then
          P.oil = {city = city.id, site = pending.site, wells = pending.wells, pumps = {}}
        end
        util.log("planner: %s founded city %d (%s) at %s, %.0f tiles from the capital, at %s", C.force, city.id,
          pending.role, util.pos_str(city.position), dist(city.position, own[1].position), util.clock and
          util.clock(game.tick) or string.format("%ds", match_seconds()))
        P.city = nil
      end
      return
    elseif st == "bad" or st == nil then
      P.stats.given_up = P.stats.given_up + 1
      util.log("planner: %s city site %s (%s) given up", C.force, util.pos_str(pending.site), pending.role)
      P.city, P.retry_at = nil, game.tick + 60 * 60
      return
    end
    if st == "planned" then construction.queue(C, pending.key) end
    return
  end
  if #own >= wanted_cities(C) or game.tick < (P.retry_at or 0) then return end
  if (P.tries or 0) >= PB.city_tries * 4 then return end
  local s = planner.next_city(C.force)
  if not s then
    P.retry_at = game.tick + 60 * 60
    return
  end
  P.tried = P.tried or {}
  if not generated(C.force, s.position) then
    P.retry_at = game.tick + 10 * 60
    return
  end
  P.tries = (P.tries or 0) + 1
  local pos, wells, role = nil, nil, s.role
  if s.kind == "oil" and not P.oil then
    pos, wells = oil_spot(surface, C.force, s.position)
    role = "oil"
  else
    pos = plain_spot(surface, C.force, s.position)
    if role == "oil" then role = "trade" end
  end
  if not pos then
    P.tried[s.id] = true
    util.log("planner: %s site %s %s refused (no City Center spot)", C.force, s.id, util.pos_str(s.position))
    P.retry_at = game.tick + 5 * 60
    return
  end
  if not farm_room(surface, C.force, pos) then
    P.tried[s.id] = true
    util.log("planner: %s site %s %s refused (no farm spot near its City Center)", C.force, s.id, util.pos_str(pos))
    P.retry_at = game.tick + 5 * 60
    return
  end
  P.tried[s.id] = true
  local key = construction.add(C, {name = CENTER, x = pos.x, y = pos.y, line = "city"})
  construction.queue(C, key)
  P.city = {key = key, site = pos, role = role, since = game.tick, wells = wells, id = s.id}
  util.log("planner: %s plans city %d of %d: %s at %s (site %s, score %.1f: ore %.2f oil %.1f rare %d choke %.2f port %d, "
    .. "%.0f tiles from the nearest own city%s)", C.force, #own + 1, wanted_cities(C), role, util.pos_str(pos), s.id,
    s.score, s.parts.ore, s.parts.oil, s.parts.rare, s.parts.choke, s.parts.port, s.parts.link,
    wells and string.format(", %d wells covered", #wells) or "")
end

---------------------------------------------------------------------------
-- The oil town: pumpjacks on the covered wells (Age II), export policies
---------------------------------------------------------------------------
local function oil_step(C, P, surface)
  local O = P.oil
  if not O then return end
  local city = deps.cities.get(O.city)
  if not (city and city.force == C.force and city.entity and city.entity.valid) then
    if not O.lost then
      O.lost = true
      util.log("planner: %s lost its oil town (city %d)", C.force, O.city)
    end
    P.oil = nil
    return
  end
  local L = deps.logistics
  if L and not O.set then
    for _, item in ipairs(PB.oil.export) do L.set_policy(city.center, "export_above", item, 0) end
    local cap = capital_of(C.force)
    if cap and cap.center then L.set_policy(cap.center, "keep", "rts-crude-oil", PB.oil.keep_crude) end
    O.set = true
    util.log("planner: %s oil town %d exports %s; the capital keeps %d crude oil", C.force, O.city,
      table.concat(PB.oil.export, ", "), PB.oil.keep_crude)
  end
  if not recipe_on(C.force, PUMPJACK) then return end
  -- pumpjacks on the wells inside the City Center's logistic area
  local reach = PB.oil.reach + 1
  local p = city.position
  local wells = surface.find_entities_filtered({area = {{p.x - reach, p.y - reach}, {p.x + reach, p.y + reach}},
                                                name = "crude-oil"})
  table.sort(wells, function(a, b)
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.position.y < b.position.y
  end)
  O.pumps = O.pumps or {}
  local n = 0
  for _, w in ipairs(wells) do
    if n >= PB.oil.pumpjacks then break end
    n = n + 1
    local key = construction.add(C, {name = PUMPJACK, x = w.position.x, y = w.position.y, line = "oil"})
    if not O.pumps[key] then
      O.pumps[key] = true
      P.stats.pumps = P.stats.pumps + 1
      util.log("planner: %s pumpjack queued on the well at %s (oil town %d)", C.force, util.pos_str(w.position), O.city)
    end
    local st = construction.status(C, key)
    if st == "planned" then construction.queue(C, key) end
  end
end

--- True when crude oil reached the capital's network (the oil chain districts make sense).
local LIVE = {depots = true, survey = true, building = true, cut = true} -- rail program states of a line under way
local function crude_flows(C)
  return construction.have(C, "rts-crude-oil") > 0 or construction.flowing(C, "rts-crude-oil")
end

-- An own city with an open rail line and no supply hauler exports the goods of the Age III road (bought from a
-- city-state, made from the oil town's crude): the trains bring them to the capital, which keeps the planner's targets
-- of them. (Phase 5 M3 ai, wave B.2: on every city, a town's ration hauler carried batteries 725 tiles instead and the
-- town starved, M2 seed 701.)
local function line_open(C, P, c)
  local E = P.trunk[c.id]
  if E and E.opened then return true end
  local R = storage.rails
  local main = R and R.ai and R.ai[C.force]
  return main ~= nil and main.far == c.center and main.state == "open"
end

local function goods_policies(C, P, own, capital)
  local L = deps.logistics
  if not L then return end
  P.exports = P.exports or {}
  for _, c in ipairs(own) do
    if c.id ~= capital.id and c.center then
      local hauled = C.gov and C.gov.haulers and C.gov.haulers[c.id] ~= nil
      local on = line_open(C, P, c) and not hauled
      if on and P.exports[c.id] ~= c.center then
        P.exports[c.id] = c.center
        for _, item in ipairs(PB.export_goods) do L.set_policy(c.center, "export_above", item, 0) end
      elseif not on and P.exports[c.id] == c.center then
        P.exports[c.id] = nil
        for _, item in ipairs(PB.export_goods) do L.set_policy(c.center, "export_above", item, nil) end
      end
    end
  end
  -- (0.1.1, issue #1) A city-state purchase arrives in the own city nearest the city-state (scripts/sinks.lua). In a
  -- town without an open line it waited for that line: the 801 leader's plastic and sulfur, bought at minutes 19-25,
  -- reached its capital at 32 and its Electrification started 13 minutes after Age II. Such a town (not one with a
  -- supply hauler: a ration hauler that carried exports starved its town, M2 seed 701) exports the goods the planner
  -- bought from a city-state in the last forward_ticks, so the auto haulers bring them home.
  P.fwd = P.fwd or {}
  local recent = {}
  for item, t in pairs(P.cs_bought or {}) do
    if game.tick - t <= (PB.forward_ticks or 10 * 3600) then recent[item] = true end
  end
  for _, c in ipairs(own) do
    if c.id ~= capital.id and c.center then
      local F = P.fwd[c.id]
      if not F or F.center ~= c.center then
        F = {center = c.center, items = {}}
        P.fwd[c.id] = F
      end
      if P.exports[c.id] == c.center then
        F.items = {} -- the line's export policies cover every good (above)
      else
        local hauled = C.gov and C.gov.haulers and C.gov.haulers[c.id] ~= nil
        local oil_town = P.oil and P.oil.city == c.id
        for _, item in ipairs(PB.export_goods) do
          local on = (not hauled and recent[item]) or false
          if on ~= (F.items[item] or false) then
            F.items[item] = on or nil
            -- (the oil town keeps its own crude, plastic and sulfur exports: oil_step)
            local base = (oil_town and OIL_EXPORT[item]) and 0 or nil
            L.set_policy(c.center, "export_above", item, on and 0 or base)
            if on then util.log("planner: %s city %d forwards bought %s to the capital", C.force, c.id, item) end
          end
        end
      end
    end
  end
  local want = planner.targets(C) or {}
  P.keeps = P.keeps or {}
  for _, item in ipairs(PB.export_goods) do
    local n = want[item]
    if n and n > 0 and P.keeps[item] ~= n and capital.center then
      local pol = L.policy(capital.center)
      if pol and (pol.keep[item] or 0) < n then L.set_policy(capital.center, "keep", item, n) end
      P.keeps[item] = n
    end
  end
end

---------------------------------------------------------------------------
-- The trunk: an MST over own cities, one rails program per edge rails.lua does not serve itself
---------------------------------------------------------------------------
local function mst(cities_list, root_id)
  -- Prim from the capital; ties by city id
  local inside = {[root_id] = true}
  local parent = {}
  local by_id = {}
  for _, c in ipairs(cities_list) do by_id[c.id] = c end
  local n_in = 1
  while n_in < #cities_list do
    local best, bp, bd
    for _, c in ipairs(cities_list) do
      if not inside[c.id] then
        for _, o in ipairs(cities_list) do
          if inside[o.id] then
            local d = dist(c.position, o.position)
            if not bd or d < bd or (d == bd and (c.id < best.id or (c.id == best.id and o.id < bp.id))) then
              best, bp, bd = c, o, d
            end
          end
        end
      end
    end
    if not best then break end
    inside[best.id] = true
    parent[best.id] = bp.id
    n_in = n_in + 1
  end
  return parent, by_id
end

--- {{from_city, to_city, state}} of the nation's trunk (the edges this planner runs and rails.lua's own program).
function planner.trunk(force_name)
  local P = P_of(force_name, false)
  local out = {}
  local R = storage.rails
  local main = R and R.ai and R.ai[force_name]
  local cities = deps.cities
  if main and main.far and cities then
    local fc = cities.of_center(main.far)
    local ac = main.anchor and cities.of_center(main.anchor)
    out[#out + 1] = {from_city = ac and ac.id, to_city = fc and fc.id, state = main.state, main = true}
  end
  if P then
    local ids = {}
    for id in pairs(P.trunk) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local E = P.trunk[id]
      out[#out + 1] = {from_city = E.from, to_city = E.to, state = E.A and E.A.state or "queued"}
    end
  end
  return out
end

local function edge_policies(C, P, E)
  local L = deps.logistics
  local A = E.A
  if not (L and A.depot_a and A.depot_b) or E.policies then return end
  E.policies = true
  local role = P.roles[E.to]
  local items = {}
  if role ~= "oil" then items = {"iron-plate", "copper-plate", "steel-plate"} end
  for _, item in ipairs(PB.oil.export) do items[#items + 1] = item end
  for _, item in ipairs(PB.export_goods) do
    local dup = false
    for _, x in ipairs(items) do if x == item then dup = true end end
    if not dup then items[#items + 1] = item end
  end
  -- (0.1.1, issue #1) the keep only where the edge ends at the capital: a network exports only above max(export_above,
  -- keep), so a keep of 3,000 at a town between the oil town and the capital held the crude there and none went on
  -- (seed 801 rts-ai-3: stage 1 stood at 93 % for 25 minutes without plastic); a drop-off without a keep takes every
  -- export (scripts/logistics.lua), and the town's own line to the capital exports it onwards
  local N = storage.nations and storage.nations[C.force]
  local at_capital = N ~= nil and E.from == N.capital
  for _, item in ipairs(items) do
    L.set_policy(A.depot_b, "export_above", item, item:find("plate") and (deps.rails.AI_EXPORT or 100) or 0)
    if at_capital then L.set_policy(A.depot_a, "keep", item, deps.rails.AI_KEEP or 3000) end
  end
  util.log("planner: %s trunk edge %s -> %s carries %s", C.force, tostring(E.to), tostring(E.from),
    table.concat(items, ", "))
end

local function trunk_step(C, P, own, capital)
  local rails = deps.rails
  if not (rails and rails.ai_program and rails.nation and rails.nation()) then return end
  if game.tick < (P.trunk_next or 0) then return end
  P.trunk_next = game.tick + PB.trunk.period
  local R = storage.rails
  local main = R and R.ai and R.ai[C.force]
  local served = {}
  if main and main.far then served[main.far] = true end
  for _, Pm in ipairs(R and R.ai_more and R.ai_more[C.force] or {}) do served[Pm.far] = true end
  -- rails.lua's own line (capital - town) carries the Age III goods too (a city-state purchase may arrive in the town)
  if main and main.depot_a and main.depot_b and P.main_policies ~= main.depot_b and deps.logistics then
    P.main_policies = main.depot_b
    for _, item in ipairs(PB.export_goods) do
      deps.logistics.set_policy(main.depot_b, "export_above", item, 0)
      deps.logistics.set_policy(main.depot_a, "keep", item, deps.rails.AI_KEEP or 3000)
    end
  end
  if not P.linked_at then
    local open = 0
    for _, E in pairs(P.trunk) do if E.opened then open = open + 1 end end
    if main and main.state == "open" then open = open + 1 end
    if open >= 2 then
      P.linked_at = game.tick
      util.log("planner: %s has three cities linked by rail", C.force)
    end
  end
  local parent, by_id = mst(own, capital.id)
  local live = (main and LIVE[main.state]) and 1 or 0
  for _, id in ipairs((function()
    local ids = {}
    for k in pairs(P.trunk) do ids[#ids + 1] = k end
    table.sort(ids)
    return ids
  end)()) do
    local E = P.trunk[id]
    if E.A and LIVE[E.A.state] then live = live + 1 end
  end
  for _, c in ipairs(own) do
    if c.id ~= capital.id and c.center and not served[c.center] then
      local E = P.trunk[c.id]
      if E and not (buildings.get(E.A.far) and buildings.get(E.A.anchor)) then
        util.log("planner: %s trunk edge to city %d dropped (an end is gone)", C.force, c.id)
        P.trunk[c.id], E = nil, nil
      end
      local from0 = by_id[parent[c.id] or capital.id] or capital
      if not E and live < PB.trunk.lines and match_seconds() >= 60
         and dist(c.position, from0.position) <= (PB.trunk.max_edge or math.huge) then
        local from = from0
        local pay = rails.AI_PAY and capital.center or nil
        local anchor = (pay and from.center) or capital.center
        E = {to = c.id, from = rails.AI_PAY and from.id or capital.id, A = {anchor = anchor, far = c.center, pay = pay},
             since = game.tick}
        -- the edge's policies are this planner's (edge_policies), not the program's defaults
        E.A.policies = true
        P.trunk[c.id] = E
        P.stats.edges = P.stats.edges + 1
        live = live + 1
        util.log("planner: %s trunk edge city %d -> city %d (%.0f tiles, %s pays)", C.force, c.id, E.from,
          dist(c.position, (by_id[E.from] or capital).position), pay and "the capital" or "the anchor")
      end
      -- an edge whose survey keeps failing (a depot exit boxed in) is anchored at the nearest other own city whose line
      -- to the capital is open instead (its depots there are new ones); at most twice
      if E and E.A.line ~= E.last_line then
        E.last_line = E.A.line
        E.surveys = (E.surveys or 0) + 1
      end
      if E and not E.opened and (E.surveys or 0) > PB.trunk.max_surveys and (E.moves or 0) < 2 then
        local alt, ad
        for _, o in ipairs(own) do
          if o.id ~= c.id and o.id ~= E.from and o.center and o.position and (o.id == capital.id or P.trunk[o.id] and
             P.trunk[o.id].opened or (main and main.far == o.center and main.state == "open")) then
            local d = dist(o.position, c.position)
            if not ad or d < ad then alt, ad = o, d end
          end
        end
        if alt and rails.AI_PAY then
          util.log("planner: %s trunk edge city %d -> city %d: %d surveys failed, anchored at city %d instead (%.0f tiles)",
            C.force, c.id, E.from, E.surveys, alt.id, ad)
          E = {to = c.id, from = alt.id, A = {anchor = alt.center, far = c.center, pay = capital.center, policies = true},
               since = game.tick, moves = (E.moves or 0) + 1}
          P.trunk[c.id] = E
        end
      end
      -- (Age I: the edge's kits and depots wait while the capital holds fewer than age1_circuits circuits: they took
      -- the aggressive AI's raider circuits in the M1 acceptance)
      local hold = age_of(C.force) < 2 and construction.have(C, "electronic-circuit") < (PB.trunk.age1_circuits or 0)
      -- (and while rails.lua's own line waits for its depots, their plates come first: an edge crafting depots from the
      -- same capital network kept the aggressive AI's town line at one depot for 53 minutes, M1 seed 501)
      if main and main.state == "depots" and not (E and E.A.depot_a and E.A.depot_b) then hold = true end
      -- (0.1.1, issue #2) and while that line waits for its crew's kits, an edge without a crew of its own waits too:
      -- both crews' kits (220 iron) were paid in turns and both lines opened late (804 rts-ai-1: 34 and 34)
      local mline = main and main.line and storage.rails and storage.rails.lines[main.line]
      if mline and main.state == "building" and not mline.builder and mline.wait == "no-kits" and E then
        local el = E.A.line and storage.rails.lines[E.A.line]
        if not (el and el.builder) then hold = true end
      end
      -- (0.1.1, issue #1: and while the research waits for engines, planner.engine_focus, an edge not open yet whose
      -- crew has not left: an open edge's program tops up its depots' coal, runs its freight train and repairs)
      if E and planner.engine_focus(C) and E.A.state ~= "open" then
        local el = E.A.line and storage.rails and storage.rails.lines[E.A.line]
        if not (el and el.builder) then hold = true end
      end
      if E then E.held = hold or nil end -- (0.1.1: rail_wants skips a held edge)
      if E and not hold then
        rails.ai_program(C.force, E.A)
        if E.A.depot_a and E.A.depot_b then edge_policies(C, P, E) end
        if E.A.state == "open" and not E.opened then
          E.opened = game.tick
          P.stats.opened = P.stats.opened + 1
          util.log("planner: %s trunk edge city %d -> city %d open after %.0f s", C.force, c.id, E.from,
            (game.tick - E.since) / 60)
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Age III road: research, make targets, the Space Program, rushes, automation
---------------------------------------------------------------------------
--- Technologies the planner wants first (ai/tech.lua tries these before the doctrine's order).
function planner.research_want(C)
  if not nation_mode() then return nil end
  local out = {}
  local P = P_of(C.force, false)
  if age_of(C.force) >= 2 then
    for _, name in ipairs(PB.research_first) do out[#out + 1] = name end
  end
  if P and P.want_geology then out[#out + 1] = GEOLOGY end
  -- (wave B.2: the uranium outpost wants Geology, then Nuclear power)
  if P and P.uranium and not P.uranium.none then
    out[#out + 1] = GEOLOGY
    out[#out + 1] = NUCLEAR_TECH
  end
  return out
end

-- The industrial kit's parts are wanted from Industrialisation on (they are bought during the Charter, so Electrification
-- starts the minute Age II comes) until Electrification is researched.
-- (Phase 5 M3 ai: and after it while a technology the council wants needs industrial kits: Aviation, Air Force)
local KIT_TECHS = {"rts-aviation", "rts-air-force", "rts-military-railways"}
local function kit_phase(C)
  if not has_tech(C.force, ELECTRIFICATION) then
    return age_of(C.force) >= 2 or has_tech(C.force, INDUSTRIALISATION)
  end
  local want = deps.council and deps.council.research_want and deps.council.research_want(C) or {}
  for _, name in ipairs(want) do
    for _, k in ipairs(KIT_TECHS) do
      if name == k and not has_tech(C.force, name) then return true end
    end
  end
  return false
end

--- Make targets the planner wants at the capital (ai/age_up.lua merges them with its own, the larger wins).
function planner.targets(C)
  local P = P_of(C.force, false)
  if not (P and nation_mode()) then return nil end
  local out = {}
  if kit_phase(C) then
    for item, n in pairs(PB.kit_targets) do out[item] = n end
    -- the advanced circuits' plastic (2 per circuit in the factory)
    out["plastic-bar"] = math.max(out["plastic-bar"] or 0, 2 * (PB.kit_targets["advanced-circuit"] or 0))
  end
  if P.oil and crude_flows(C) then
    out["plastic-bar"] = math.max(out["plastic-bar"] or 0, 40)
    out.sulfur = math.max(out.sulfur or 0, 20)
  end
  -- (0.1.1, issue #1) stage 1's advanced circuits and their plastic in stock from the start of Electrification, as its
  -- concrete (concrete_step): with targets of 20 and 40 the Electronics and Petrochemical works stopped while the
  -- research ran, and stage 1 then waited 10-15 minutes for 60 circuits (seed 805, crude at 3,000)
  if P.concrete and P.concrete.started and age_of(C.force) < 3 and PB.stage1_prestock then
    for item, n in pairs(PB.stage1_prestock) do out[item] = math.max(out[item] or 0, n) end
  end
  -- rails in stock while a line is built: the Rail works make 3 rails per steel plate, the rail programs' own crafts 2
  -- (rails.lua takes the rails a depot's network holds before it crafts any)
  local building = false
  local R = storage.rails
  local main = R and R.ai and R.ai[C.force]
  if main and LIVE[main.state] then building = true end
  for _, E in pairs(P.trunk) do
    if E.A and LIVE[E.A.state] then building = true end
  end
  if building then out.rail = math.max(out.rail or 0, PB.rail_stock) end
  -- (wave B.2: the nuclear plant's fuel rods, made by the Chemistry works of the outpost's uranium)
  if nuclear_ready(C, P) then out[FUEL_ROD] = math.max(out[FUEL_ROD] or 0, PB.uranium.fuel_rods or 2) end
  local age3 = mod("age3")
  local missing = age3 and age3.missing and age3.missing(C.force)
  -- (in Age III the later stages wait while the airfield is queued: their engines took every steel plate it needed)
  if missing and age_of(C.force) >= 3 and deps.council and deps.council.air_pending and deps.council.air_pending(C) then
    missing = nil
  end
  if missing then
    for item, n in pairs(missing) do out[item] = math.max(out[item] or 0, math.min(n, PB.stage_cap)) end
    if missing["advanced-circuit"] then
      out["plastic-bar"] = math.max(out["plastic-bar"] or 0, math.min(2 * missing["advanced-circuit"], PB.stage_cap))
    end
  end
  return out
end

local function treasury_balance(force_name)
  local treasury = mod("treasury")
  return treasury and treasury.balance and treasury.balance(force_name) or 0
end

-- What the planner buys at the nation's port (the market AI hauls it home: it is a make target the capital lacks):
-- the industrial kit's sulfur and plastic in Age II before Electrification, the running stage's concrete and the
-- plastic of its advanced circuits, half its steel when rich. Amounts are what the capital still lacks after the goods
-- on their way (market.pending), at most buy_max per good and a buy_share of the balance above buy_reserve per pass.
local function buy_step(C, P)
  if game.tick < (P.buy_next or 0) then return end
  P.buy_next = game.tick + PB.buy_period
  local market = deps.market
  if not (market and market.buy and market.ports) then return end
  local port = market.ports(C.force)[1]
  local capital = capital_of(C.force)
  if port and capital then
    local rec = market.port and market.port(port)
    if rec and rec.position and dist(rec.position, capital.position) > PB.port_reach then port = nil end
  end
  local want = {}
  local rich = treasury_balance(C.force) >= PB.rush_at
  if kit_phase(C) then
    -- the kit's parts themselves (the factory recipes of engines and advanced circuits are Age II ones) and the
    -- plastic of its advanced circuits (an oil city-state sells it)
    for item, n in pairs(PB.kit_targets) do want[item] = n end
    want["plastic-bar"] = 2 * (PB.kit_targets["advanced-circuit"] or 10)
  end
  local age3 = mod("age3")
  local missing = age3 and age3.missing and age3.missing(C.force)
  if missing then
    if missing.concrete then want.concrete = math.min(missing.concrete, PB.stage_cap) end
    local adv = missing["advanced-circuit"]
    if adv then
      -- rich: the circuits themselves (half of them), else the plastic the factory makes them of
      if rich then want["advanced-circuit"] = math.ceil(math.min(adv, PB.stage_cap) / 2) end
      want["plastic-bar"] = math.max(want["plastic-bar"] or 0, math.min(2 * adv, PB.stage_cap))
    end
    if missing["steel-plate"] and rich then
      want["steel-plate"] = math.floor(math.min(missing["steel-plate"], PB.stage_cap) / 2)
    end
    for _, item in ipairs({"processing-unit", "battery", "engine-unit", "sulfur", "rocket-fuel", "light-oil-barrel"}) do
      if missing[item] then want[item] = math.min(missing[item], PB.stage_cap) end
    end
  end
  -- stone for the Construction works, bricks and concrete (houses and rails take it: capitals ran out at 40-55 min) and
  -- the airfield's concrete (ai/council.lua's targets)
  if age_of(C.force) >= 2 and construction.have(C, "stone") < PB.stone_low then want.stone = PB.stone_buy end
  if age_of(C.force) >= 2 and construction.have(C, "steel-plate") < PB.steel_low then
    want["steel-plate"] = math.max(want["steel-plate"] or 0, PB.steel_buy)
  end
  local ct = deps.council and deps.council.targets and deps.council.targets(C)
  for item, n in pairs(ct or {}) do want[item] = math.max(want[item] or 0, n) end -- the airfield's, a belt's goods
  if next(want) == nil then return end
  local coming = {}
  for _, imp in ipairs(market.pending and market.pending(C.force) or {}) do
    coming[imp.item] = (coming[imp.item] or 0) + (imp.n or 0)
  end
  for _, imp in ipairs(storage.sinks and storage.sinks.pending or {}) do
    if imp.force == C.force then coming[imp.item] = (coming[imp.item] or 0) + (imp.n or 0) end
  end
  local port_has = port and market.port_contents and market.port_contents(port) or {}
  local budget = math.max(0, (treasury_balance(C.force) - PB.buy_reserve) * PB.buy_share)
  -- no purchases while the treasury loses money (they put the nation on high taxes: happiness and growth fell)
  local treasury = mod("treasury")
  local t = treasury and treasury.get and treasury.get(C.force)
  if t and (t.net or 0) < 0 and treasury_balance(C.force) < PB.buy_reserve * 2 then budget = 0 end
  -- (0.1.1, issue #1) except stage 1's last goods: down to stage1_reserve (a nation with 1,100 cr bought nothing and
  -- stood at 93 % of stage 1 for 25 minutes, seed 801 rts-ai-3)
  local stage1 = missing and age3.project and (age3.project(C.force) or {}).stage == 1
  -- (0.1.1, issue #4) and a war technology's kit parts at war (ai/council.lua war_research; kit_phase wants them)
  local war = deps.council and deps.council.war_research and deps.council.war_research(C)
  if (stage1 or war) and PB.stage1_reserve then
    budget = math.max(budget, (treasury_balance(C.force) - PB.stage1_reserve) * PB.buy_share)
  end
  local items = {}
  for item in pairs(want) do items[#items + 1] = item end
  table.sort(items)
  -- city-states at peace that sell a good (their region's: an oil region sells plastic and sulfur), nearest first;
  -- the goods arrive in our city nearest to the city-state, whose network exports them to the capital (goods_policies)
  local sinks = deps.sinks or mod("sinks")
  local cs_list = {}
  if sinks and sinks.city_states and sinks.trade_with_city_state and capital then
    for _, cs in ipairs(sinks.city_states(C.force)) do
      local c = deps.cities.get(cs.city_id)
      if c and c.position then cs_list[#cs_list + 1] = {cs = cs, d = dist(c.position, capital.position)} end
    end
    table.sort(cs_list, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      return a.cs.city_id < b.cs.city_id
    end)
  end
  for _, item in ipairs(items) do
    local short = want[item] - construction.have(C, item) - (coming[item] or 0) - (port_has[item] or 0)
    for _, e in ipairs(cs_list) do
      if short <= 0 or budget <= 0 then break end
      for _, g in ipairs(e.cs.goods or {}) do
        if g.item == item and (g.stock or 0) > 0 and g.price and g.price > 0 and budget > g.price then
          local n = math.min(short, g.stock, PB.buy_max, math.floor(budget / g.price))
          local ok, cr = sinks.trade_with_city_state(C.force, e.cs.city_id, item, n, true)
          if ok then
            budget = budget - (cr or 0)
            short = short - n
            P.stats.buys = P.stats.buys + 1
            P.stats.bought_cr = (P.stats.bought_cr or 0) + (cr or 0)
            P.stats.cs_buys = (P.stats.cs_buys or 0) + 1
            P.cs_bought = P.cs_bought or {}
            P.cs_bought[item] = game.tick -- goods_policies forwards it from a town without a line
            util.log("planner: %s buys %d %s from city-state %d for %.0f cr", C.force, n, item, e.cs.city_id, cr or 0)
          end
        end
      end
    end
    local price = port and market.p0(item) and market.quote(item, 1, "buy")
    if short > 0 and price and price > 0 and budget > price then
      local n = math.min(short, PB.buy_max, math.floor(budget / price))
      if n > 0 then
        local ok, cr = market.buy(C.force, port, item, n)
        if ok then
          budget = budget - (cr or 0)
          P.bought = P.bought or {}
          P.bought[item] = game.tick -- ai/nation.lua does not sell it back at the port
          P.stats.buys = P.stats.buys + 1
          P.stats.bought_cr = (P.stats.bought_cr or 0) + (cr or 0)
          util.log("planner: %s buys %d %s at port #%d for %.0f cr (short %d)", C.force, n, item, port, cr or 0, short)
        elseif P.buy_why ~= cr then
          P.buy_why = cr
          util.log("planner: %s cannot buy %s: %s", C.force, item, tostring(cr))
        end
      end
    end
  end
end

--- (0.1.1, issue #1) True while Space Program stage 1 still lacks advanced circuits or engines the nation does not
--- hold: research with industrial kits (each takes an engine and an advanced circuit) waits meanwhile (ai/tech.lua).
--- After Electrification the labs went on to Aviation and the like, their kits took the advanced circuits the market
--- AI bought for the stage, and a nation stood at 93 % of stage 1 from minute 37 to the end (seed 801 rts-ai-3).
function planner.science_hold(C)
  if not nation_mode() then return false end
  -- (0.1.1, issue #4) not for a war technology at war (ai/council.lua war_research): its kits come first
  if deps.council and deps.council.war_research and deps.council.war_research(C) then return false end
  local age3 = mod("age3")
  local proj = age3 and age3.project and age3.project(C.force)
  if not (proj and proj.stage == 1) then return false end
  local missing = age3.missing and age3.missing(C.force)
  for _, item in ipairs({"advanced-circuit", "engine-unit"}) do
    if missing and (missing[item] or 0) > construction.have(C, item) then return true end
  end
  return false
end

--- True while one of the planner's trunk lines waits for its depots or is built and three cities are not linked yet
--- (ai/age_up.lua: the barracks save for the rails then, like for rails.lua's own line).
function planner.saving_rail(C)
  local P = P_of(C.force, false)
  if not P or P.linked_at then return false end
  for _, E in pairs(P.trunk) do
    local st = E.A and E.A.state
    if st == "depots" or st == "building" then return true end
  end
  return false
end

--- The planner's role of an own city ("oil", "trade", ...; nil for the capital and the towns of ai/towns.lua).
function planner.role_of(force_name, city_id)
  local P = P_of(force_name, false)
  return P and P.roles and P.roles[city_id] or nil
end

--- Extra districts for the age-up list: the oil chain once crude comes in, the Age III districts in Age III.
function planner.districts(C)
  local out = {}
  local P = P_of(C.force, false)
  if not P then return out end
  -- (the oil chain is queued from Age II on: the Electronics works make the kit's advanced circuits of bought plastic,
  -- the Petrochemical works the oil town's crude into plastic and sulfur; crude oil comes by haulers before the town's
  -- line opens, and the districts take minutes to build)
  if age_of(C.force) >= 2 then
    -- (0.1.1, issue #1) The capital fits four to eight districts (801-805 on 2.1; two in one seed), so the Age III
    -- road's come first: the Electronics works (the industrial kits' and stage 1's advanced circuits; no capital of
    -- seeds 801 and 804 built one, stage 1 then stood at 90 % for want of them), the Smelting works when a town's ore
    -- comes to the capital (QA fix: behind the Age III road's districts it found no spot, the town's ore filled the
    -- capital's keep and its freight train stood idle from minute 38, M1 seed 501), the Petrochemical works with an
    -- oil town, then the second Steel works (it came first while three cities were not linked and took the
    -- Electronics works' spot). No Construction works: the concrete chain's two factories make the concrete.
    out[#out + 1] = ELECTRONICS_WORKS
    if C.town and C.town.ore then out[#out + 1] = SMELTING_WORKS end
    -- (0.1.1, issue #1: the Petrochemical works only with an oil town or crude oil at home: without crude it took one
    -- of the capital's district spots for nothing)
    if P.oil or crude_flows(C) then out[#out + 1] = PETROCHEM end
    out[#out + 1] = STEEL_WORKS
    if P.linked_at then
      for _, name in ipairs(PB.linked_districts or {}) do out[#out + 1] = name end
    end
  elseif has_tech(C.force, ELECTRIFICATION) then
    -- the Space Program's advanced circuits and concrete: the Electronics and Construction works first
    for _, name in ipairs(PB.oil_districts) do
      if name ~= "rts-district-petrochem" then out[#out + 1] = name end
    end
  end
  if age_of(C.force) >= 3 then
    for _, name in ipairs(planner.AGE3_DISTRICTS) do out[#out + 1] = name end
    if nuclear_ready(C, P) then out[#out + 1] = NUCLEAR_PLANT end
  end
  return out
end

--- Districts ai/age_up.lua moves to the front of its list once (0.1.1, issue #1): the Petrochemical works as soon as
--- the nation has an oil town (crude piled up to 1,700-3,000 in capitals whose district spots had gone to later
--- districts, and their plastic and sulfur stayed at 0, seeds 803-805; moved only once the crude came, it found no spot
--- either, seed 801 rts-ai-3 with 2,620 crude and stage 1 at 96 % for want of plastic).
function planner.urgent_districts(C)
  local P = P_of(C.force, false)
  if not (P and age_of(C.force) >= 2) then return nil end
  if P.oil or crude_flows(C) then return {PETROCHEM} end
  return nil
end


local function space_step(C, P, surface)
  local age3 = mod("age3")
  if not (age3 and age3.can_start) then return end
  -- (0.1.1, issue #1) the Launch complex's spot is reserved from Age II on (layout.find_spot keeps its tiles from every
  -- later building): the capital's area was full when Electrification came and the Space Program could not start
  -- ("no-spot", seed 802 rts-player on the 0.1.1 tree with the concrete chain's two factories)
  local proj0 = age3.project and age3.project(C.force)
  if age_of(C.force) >= 2 and age3.SITE and not P.space.site and not (proj0 and proj0.site and proj0.site.valid)
     and game.tick >= (P.space.site_retry or 0) then
    local pos, _, wait = layout.find_spot(C, surface, age3.SITE, "cc")
    if pos then
      P.space.site = {x = pos.x, y = pos.y}
      util.log("planner: %s reserves the Launch complex's spot at %s", C.force, util.pos_str(pos))
    elseif not wait then
      P.space.site_retry = game.tick + 60 * 60
    end
  end
  local ok = age3.can_start(C.force)
  if ok then
    local proj, why = age3.start(C.force, P.space.site)
    if not proj and P.space.site and why == "blocked" then
      util.log("planner: %s Launch complex spot %s blocked: the program looks for one itself", C.force,
        util.pos_str(P.space.site))
      P.space.site = nil
      proj, why = age3.start(C.force)
    end
    if proj then
      P.space.started = P.space.started or game.tick
      util.log("planner: %s starts the Space Program (stage %d) at %s", C.force, proj.stage,
        string.format("%d:%02d", math.floor(match_seconds() / 60), math.floor(match_seconds() % 60)))
    else
      if P.space.why ~= why then util.log("planner: %s cannot start the Space Program: %s", C.force, tostring(why)) end
      P.space.why = why
    end
  end
end

-- Rush the running national project (the Railway Charter or a Space Program stage) when rich and mostly delivered.
local function rush_step(C, P)
  local sinks = deps.sinks or mod("sinks")
  if not (sinks and sinks.rush and sinks.rush_state) then return end
  if sinks.rush_state(C.force) then return end
  if treasury_balance(C.force) < PB.rush_at then return end
  -- a research the planner wants (Electrification) runs: rush it (lab speed x2)
  local force = game.forces[C.force]
  local cur = force and force.current_research
  if cur then
    for _, name in ipairs(PB.research_first) do -- (only the Age III road's research: Geology is not worth a rush)
      if name == cur.name then
        local ok, why = sinks.rush(C.force, name)
        if ok then
          P.space.rushes = P.space.rushes + 1
          util.log("planner: %s rushes research %s (balance %.0f)", C.force, name, treasury_balance(C.force))
          return
        elseif P.space.rush_why ~= why then
          P.space.rush_why = why
          util.log("planner: %s research rush refused: %s", C.force, tostring(why))
        end
      end
    end
  end
  local share
  local age3 = mod("age3")
  local proj = age3 and age3.project and age3.project(C.force)
  if proj and (proj.state == "building" or proj.state == "countdown") and age3.progress then
    share = proj.state == "countdown" and 1 or age3.progress(proj)
  else
    local ages = deps.ages
    local p = ages and ages.project and ages.project(C.force)
    if p and p.delivered and ages.required then
      local need, have = 0, 0
      for item, n in pairs(ages.required()) do
        need = need + n
        have = have + math.min(n, p.delivered[item] or 0)
      end
      share = need > 0 and have / need or nil
    end
  end
  if not share or share < PB.rush_share then return end
  local ok, why = sinks.rush(C.force, "project")
  if ok then
    P.space.rushes = P.space.rushes + 1
    util.log("planner: %s rushes its national project (%.0f %% delivered, balance %.0f)", C.force, share * 100,
      treasury_balance(C.force))
  elseif P.space.rush_why ~= why then
    P.space.rush_why = why
    util.log("planner: %s rush refused: %s", C.force, tostring(why))
  end
end

local function automate_step(C, P, capital)
  local age3 = mod("age3")
  if not (age3 and age3.automate) or age_of(C.force) < 3 then return end
  if construction.have(C, "rts-automation-kit") < PB.automate.kits_at then return end
  for _, family in ipairs(PB.automate.families) do
    if not P.automated[family] then
      local ok = age3.automate(capital.id, family, true)
      if ok then
        P.automated[family] = true
        util.log("planner: %s automates %s in its capital", C.force, family)
        return
      end
    end
  end
end

-- Rare deposits inside own land and within reach of an own city's network: Geology, then an extractor on each.
local function rare_step(C, P, surface, own)
  local rare = deps.rare or mod("rare")
  if not (rare and rare.deposits) or age_of(C.force) < PB.rare.from_age then return end
  local territory = deps.territory
  local spots = {}
  for _, d in ipairs(rare.deposits(C.force)) do
    if d.position and not d.extractor then
      local owner = territory and territory.owner_at and territory.owner_at(d.position)
      if owner == C.force then
        for _, c in ipairs(own) do
          if math.max(math.abs(c.position.x - d.position.x), math.abs(c.position.y - d.position.y)) <= PB.rare.reach then
            spots[#spots + 1] = d
            break
          end
        end
      end
    end
  end
  P.want_geology = #spots > 0 and not has_tech(C.force, GEOLOGY) or nil
  if #spots == 0 or not recipe_on(C.force, RARE_EXTRACTOR) then return end
  local n = 0
  for _, k in pairs(P.rare.keys) do if k then n = n + 1 end end
  for _, d in ipairs(spots) do
    if n >= PB.rare.max then break end
    local dk = string.format("%.0f,%.0f", d.position.x, d.position.y)
    if not P.rare.keys[dk] then
      local pos = surface.find_non_colliding_position(RARE_EXTRACTOR, d.position, 4, 0.5, true)
      if pos then
        local key = construction.add(C, {name = RARE_EXTRACTOR, x = math.floor(pos.x) + 0.5, y = math.floor(pos.y) + 0.5,
                                         line = "rare"})
        construction.queue(C, key)
        P.rare.keys[dk] = key
        n = n + 1
        util.log("planner: %s rare extractor (%s) queued at %s", C.force, tostring(d.kind), util.pos_str(pos))
      end
    end
  end
end

---------------------------------------------------------------------------
-- Uranium and the nuclear plant (Phase 5 M3 ai, wave B.2; a minimal plan): in Age III, the nearest uranium deposit of
-- the world plan within uranium.reach tiles of an own city gets an outpost once Geology is researched: an rts-hub next
-- to it (its network and power), one extractor on the ore and a stockpile at the extractor's output; the hub exports
-- the ore and the capital keeps uranium.keep of it (the auto haulers bring it). With Nuclear power researched and
-- ore at home, the capital builds one nuclear plant (planner.districts) and the Chemistry works makes its fuel rods
-- (planner.targets).
---------------------------------------------------------------------------
local OUTPOST = {"rts-hub", "rts-extractor", "rts-stockpile"}
uranium_step = function(C, P, surface, own, capital)
  local U = PB.uranium
  if not U or age_of(C.force) < 3 then return end
  P.uranium = P.uranium or {}
  local S = P.uranium
  if S.none then return end
  if not S.site then
    local world = mod("world")
    local best, bd
    for _, site in ipairs(world and world.sites and world.sites("uranium") or {}) do
      local owner = deps.territory and deps.territory.owner_at and deps.territory.owner_at(site.position)
      if not owner or owner == C.force then
        for _, c in ipairs(own) do
          local d = dist(c.position, site.position)
          if d <= U.reach and (not bd or d < bd) then best, bd = site, d end
        end
      end
    end
    if not best then
      S.none = true
      util.log("planner: %s knows no uranium deposit within %d tiles of its cities", C.force, U.reach)
      return
    end
    S.site = {x = best.position.x, y = best.position.y}
    util.log("planner: %s plans a uranium outpost at %s (%.0f tiles from its nearest city)", C.force,
      util.pos_str(S.site), bd)
  end
  if not has_tech(C.force, GEOLOGY) then return end
  if not S.keys then
    local ext = surface.find_non_colliding_position("rts-extractor", S.site, 8, 1, true)
    local proto = prototypes.entity["rts-extractor"]
    local v = proto and proto.vector_to_place_result
    if not (ext and v) then
      S.none = true
      util.log("planner: %s finds no extractor spot on the uranium at %s", C.force, util.pos_str(S.site))
      return
    end
    ext = {x = math.floor(ext.x) + 0.5, y = math.floor(ext.y) + 0.5}
    local drop = {x = math.floor(ext.x + v[1]) + 0.5, y = math.floor(ext.y + v[2]) + 0.5}
    local hub = surface.find_non_colliding_position("rts-hub", {x = ext.x, y = ext.y + 10}, 12, 1, true)
    if not hub then
      S.none = true
      util.log("planner: %s finds no hub spot next to the uranium at %s", C.force, util.pos_str(S.site))
      return
    end
    S.keys = {construction.add(C, {name = "rts-hub", x = math.floor(hub.x), y = math.floor(hub.y), line = "uranium"}),
              construction.add(C, {name = "rts-extractor", x = ext.x, y = ext.y, dir = defines.direction.north,
                                   line = "uranium"}),
              construction.add(C, {name = "rts-stockpile", x = drop.x, y = drop.y, line = "uranium"})}
    for _, key in ipairs(S.keys) do construction.queue(C, key) end
    util.log("planner: %s uranium outpost queued: hub %s, extractor %s, stockpile %s", C.force, util.pos_str(hub),
      util.pos_str(ext), util.pos_str(drop))
    return
  end
  local hub_e = C.plan[S.keys[1]] and C.plan[S.keys[1]].entity
  if not S.set and hub_e and hub_e.valid and construction.status(C, S.keys[2]) == "built"
     and construction.status(C, S.keys[3]) == "built" and deps.logistics and capital.center then
    deps.logistics.set_policy(hub_e.unit_number, "export_above", URANIUM, 0)
    deps.logistics.set_policy(capital.center, "keep", URANIUM, U.keep)
    S.set = game.tick
    util.log("planner: %s uranium outpost running (hub #%d exports %s)", C.force, hub_e.unit_number, URANIUM)
  end
end

--- True once the uranium outpost runs and Nuclear power is researched (planner.districts adds the nuclear plant).
nuclear_ready = function(C, P)
  return P.uranium ~= nil and P.uranium.set ~= nil and has_tech(C.force, NUCLEAR_TECH)
end

---------------------------------------------------------------------------
-- The concrete chain (0.1.1, issue #1): concrete was the last good of Space Program stage 1 in 14 of 16 stage
-- snapshots of the 2.1 acceptance (801-805, at 2-4 concrete a minute; two nations stood at 81 % and 91 % for 30
-- minutes). The Construction works rarely found a district spot, and the works factory on Auto lost every tie to the
-- engines, advanced circuits and beams (recipe order "g"). From Age II the capital gets two factories of its own: on
-- Auto at first (more capacity for the industrial kit's parts), from the start of Electrification fixed on bricks
-- (stone) and on concrete (bricks and stone), about 30 concrete a minute, so stage 1's 100 and the airfield's 40 are
-- in stock when the Space Program starts. Each is fixed only while its good is below its keep (else back on Auto) and
-- is pinned for workers meanwhile (factories are "services", tenth of eleven in the Age II labor order). The brick
-- factory leaves stone_floor stone for the rails.
---------------------------------------------------------------------------
local CHAIN = {{recipe = "rts-brick", item = "stone-brick"}, {recipe = "rts-concrete", item = "concrete"}}

-- (ai/governor.lua governor.hold_factory: the commander's factory pass leaves a held factory alone)
local function hold_factory(C, un, on)
  if deps.governor and deps.governor.hold_factory then deps.governor.hold_factory(C, un, on) end
end

local function electrification_started(C)
  if has_tech(C.force, ELECTRIFICATION) then return true end
  local f = game.forces[C.force]
  local cur = f and f.current_research
  return cur ~= nil and cur.name == ELECTRIFICATION
end

-- Concrete the capital keeps: stage 1's and the airfield's in Age II, the Age III districts' later.
local function concrete_keep(C)
  local K = PB.concrete
  if not K then return 0 end
  return age_of(C.force) >= 3 and K.keep_age3 or K.keep
end

local function concrete_step(C, P, surface)
  local K = PB.concrete
  if not K or age_of(C.force) < 2 then return end
  local Q = P.concrete
  if not Q then
    -- (the factories from Age II: on Auto, more capacity for the industrial kit's parts, until Electrification starts;
    -- queued at its start they stood a quarter of an hour later, after the research)
    Q = {keys = {}, on = {}, since = game.tick}
    P.concrete = Q
    util.log("planner: %s builds its concrete chain's factories (Age II; on Auto until Electrification)", C.force)
  end
  if not Q.started and electrification_started(C) then
    Q.started = game.tick
    util.log("planner: %s starts its concrete chain (Electrification under way, concrete %d, bricks %d)", C.force,
      construction.have(C, "concrete"), construction.have(C, "stone-brick"))
  end
  local keep = concrete_keep(C)
  P.pins = P.pins or {}
  for i, spec in ipairs(CHAIN) do
    local key = Q.keys[i]
    local st = key and construction.status(C, key)
    if key and (st == nil or st == "bad") then
      Q.keys[i], key, st = nil, nil, nil
    end
    if not key and game.tick >= (Q.retry or 0) then
      local pos, pole, wait = layout.find_spot(C, surface, "rts-factory", "cc")
      if pos then
        if pole then construction.queue(C, construction.add(C, {name = layout.POLE, x = pole.x, y = pole.y})) end
        key = construction.add(C, {name = "rts-factory", x = pos.x, y = pos.y})
        construction.queue(C, key)
        Q.keys[i] = key
        util.log("planner: %s %s works queued at %s (concrete chain)", C.force, spec.recipe, util.pos_str(pos))
      elseif not wait then
        Q.retry = game.tick + 60 * 60
      end
    elseif key and st == "planned" then
      construction.queue(C, key)
    end
    local e = key and st == "built" and C.plan[key].entity
    local rec = e and e.valid and buildings.get(e.unit_number)
    if rec then
      -- bricks while concrete is short and they are below their keep, above the stone floor; concrete while short.
      -- A factory that is on stays on up to `margin` more (one brick at a time switched it every 2-3 s around the keep)
      local margin = Q.on[i] and (K.margin or 20) or 0
      local on = Q.started ~= nil and construction.have(C, "concrete") < keep + margin
      if spec.item == "stone-brick" then
        on = on and construction.have(C, "stone-brick") < K.brick_keep + margin
          and construction.have(C, "stone") >= K.stone_floor
      end
      local r = e.get_recipe()
      if on then
        if rec.recipe_mode ~= "fixed" or not r or r.name ~= spec.recipe then
          production.set_auto(rec, false)
          production.set_recipe(e, spec.recipe)
        end
        P.pins[e.unit_number] = rec
        hold_factory(C, e.unit_number, true)
      elseif rec.recipe_mode ~= "auto" then
        production.set_auto(rec, true)
        hold_factory(C, e.unit_number, false)
      end
      if (Q.on[i] or false) ~= on then
        Q.on[i] = on
        util.log("planner: %s %s works #%d %s (concrete %d of %d, bricks %d, stone %d)", C.force, spec.recipe,
          e.unit_number, on and "on" or "back on Auto", construction.have(C, "concrete"), keep,
          construction.have(C, "stone-brick"), construction.have(C, "stone"))
      end
    end
  end
end

---------------------------------------------------------------------------
-- The works factory's own jobs (0.1.1): while one of these is wanted and one craft's ingredients are in stock, the
-- planner fixes the capital's works factory on it and pins it for workers, then gives it back to Auto. Only with the
-- ingredients in stock: held on a depot it could not make, its goods stopped, the capital's goods fell to 0 %, its
-- growth stopped and its smelters lost their workers (seed 801 rts-ai-2 on the first 0.1.1 tree).
---------------------------------------------------------------------------
local ENGINE, ENGINE_RECIPE = "engine-unit", "rts-engine"

--- (0.1.1, issue #1) True while the Age III road's research (Electrification) waits for engines: its remaining
--- industrial kits need more engines than the capital holds (ai/mix.lua mix.research_engines). Steel went to the rail
--- programs' rails, depots and kits meanwhile (engines at 0-6 for 12 minutes while the research waited, seed 802
--- rts-ai-2), so the works factory makes engines and trunk edges not open yet wait (trunk_step) until the engines are
--- there: about 13 engines, a minute or two of steel. At most engine_focus.max ticks at a stretch, then
--- engine_focus.rest ticks without. (rails.lua's own programs run on: paused, their depots got no coal and an open
--- line's freight train ran dry, M1 seed 501 rts-ai-1 from 51:00.)
function planner.engine_focus(C)
  local P = P_of(C.force, false)
  if not (nation_mode() and P) then return false end
  if P.focus_tick == game.tick then return P.focus_on end
  local need = mix.research_engines(C)
  local on = need > 0 and need > construction.have(C, ENGINE)
  local F = PB.engine_focus or {max = 3 * 3600, rest = 2 * 3600}
  if on then
    P.focus_since = P.focus_since or game.tick
    local t = game.tick - P.focus_since
    if t > F.max + F.rest then
      P.focus_since = game.tick
    elseif t > F.max then
      on = false
    end
  else
    P.focus_since = nil
  end
  P.focus_tick, P.focus_on = game.tick, on
  return on
end

-- Rail items (0.1.1, issue #2): the rail programs pay depots and construction kits from the capital through an
-- escrow that only takes iron above 100 plates (rails.AI_RESERVE + AI_ESCROW_FLOOR). Lines waited 8-25 minutes for
-- their crew's kits ("no-kits": two locomotive kits and a construction wagon kit, 110 iron) while the capital held
-- 0-60 iron, and opened 1-3 minutes after the crew left (801-805 on 2.1: the aggressive AI's first line at 38, 51 and
-- never). A depot or kit already in the capital's network is used as it is, so while a line anchored at the capital
-- waits for one, the works factory makes it.
local RAIL_DEPOT, LOCO_KIT, CWAGON_KIT = "rts-depot", "rts-locomotive-kit", "rts-construction-wagon-kit"

local function net_of(un)
  local rec = un and buildings.get(un)
  local net = rec and rec.entity.valid and rec.entity.logistic_network
  return (net and net.valid) and net or nil
end

-- What the capital-paid rail programs wait for now: depots (count), a crew's kits (true), its coal (true) and the open
-- lines without their freight train ({program, ...}).
local function rail_wants(C, P, capital)
  local R = storage.rails
  if not R then return 0, false, false, {} end
  local capnet = net_of(capital.center)
  local list = {}
  local main = R.ai and R.ai[C.force]
  if main then list[#list + 1] = main end
  for _, A in ipairs(R.ai_more and R.ai_more[C.force] or {}) do list[#list + 1] = A end
  for _, id in ipairs((function()
    local ids = {}
    for k in pairs(P.trunk) do ids[#ids + 1] = k end
    table.sort(ids)
    return ids
  end)()) do
    local E = P.trunk[id]
    if E.A and not E.held then list[#list + 1] = E.A end
  end
  -- (0.1.1, issue #4: the council's siege railways)
  for _, A in ipairs(deps.council and deps.council.rail_programs and deps.council.rail_programs(C) or {}) do
    list[#list + 1] = A
  end
  local depots, kits, fuel, freight = 0, false, false, {}
  for _, A in ipairs(list) do
    local paid_here = (A.pay or A.anchor) == capital.center
    if A.state == "depots" and paid_here then
      depots = depots + (A.depot_a and 0 or 1) + (A.depot_b and 0 or 1)
    elseif A.state == "open" and paid_here and A.line and A.depot_b then
      local has = false -- (an existence test: the order of R.trains does not matter)
      for _, rec in pairs(R.trains or {}) do
        if rec.kind == "cargo" and rec.force == C.force and rec.ai_line == A.line then
          has = true
          break
        end
      end
      if not has then freight[#freight + 1] = A end
    elseif (A.state == "building" or A.state == "cut") and A.line then
      local line = R.lines[A.line]
      local dnet = A.depot_a and deps.logistics and deps.logistics.hub_network(A.depot_a)
      if line and not line.builder and dnet and capnet and dnet.network_id == capnet.network_id then
        if line.wait == "no-kits" then kits = true end
        if line.wait == "no-fuel" then fuel = true end
      end
    end
  end
  return depots, kits, fuel, freight
end

-- (0.1.1, issue #7) An open line's freight train is made at its town depot from kits in the town's network, which
-- rails.lua's escrow pays from the capital's iron above its floor: M1 seed 501's player opened its line at 26:32 and
-- ran its first freight train at 49:00 (the capital held 0-60 iron). Kits the works factory made at the capital are
-- moved to the town depot's network (as rails.lua moves the depots' coal), all of one train at once.
local function freight_kits(C, capital, freight)
  local rails, L = deps.rails, deps.logistics
  if not (rails and rails.kit_list and L and L.transfer and L.hub_network) then return {} end
  local list = rails.kit_list("cargo")
  local capnet = net_of(capital.center)
  if not capnet then return {} end
  for _, A in ipairs(freight) do
    local dnet = L.hub_network(A.depot_b)
    if dnet and dnet.network_id ~= capnet.network_id then
      local ok = true
      for _, k in ipairs(list) do
        if dnet.get_item_count(k[1]) + capnet.get_item_count(k[1]) < k[2] then ok = false end
      end
      if ok then
        for _, k in ipairs(list) do
          local miss = k[2] - dnet.get_item_count(k[1])
          if miss > 0 then L.transfer(capnet, dnet, k[1], miss) end
        end
        util.log("planner: %s sends a freight train's kits to depot #%d (line #%d)", C.force, A.depot_b, A.line)
      end
    end
  end
  local out = {}
  if #freight > 0 then
    for _, k in ipairs(list) do
      if capnet.get_item_count(k[1]) < k[2] then out[#out + 1] = {k[1], "a rail line's freight train"} end
    end
  end
  return out
end

-- The rail items wanted now: {{recipe, why}, ...}.
local function rail_items(C, P, capital)
  local out = {}
  local depots, kits, fuel, freight = rail_wants(C, P, capital)
  P.kits_wait = kits and (construction.have(C, LOCO_KIT) < 2 or construction.have(C, CWAGON_KIT) < 1) or nil
  P.fuel_wait = fuel or nil -- (ai/governor.lua imports coal then, planner.fuel_wait)
  if depots > 0 and construction.have(C, RAIL_DEPOT) < depots then
    out[#out + 1] = {RAIL_DEPOT, "a rail line's depot"}
  end
  if kits and construction.have(C, LOCO_KIT) < 2 then out[#out + 1] = {LOCO_KIT, "a rail line's crew"} end
  if kits and construction.have(C, CWAGON_KIT) < 1 then out[#out + 1] = {CWAGON_KIT, "a rail line's crew"} end
  for _, w in ipairs(freight_kits(C, capital, freight)) do out[#out + 1] = w end
  return out
end

--- (0.1.1, issue #2) True while a rail line anchored at the capital waits for its crew's coal ("no-fuel": two lines
--- never opened in seed 801 on 2.1, the capital's coal went to the haulers): ai/governor.lua imports coal as for a
--- supply hauler waiting for fuel.
function planner.fuel_wait(C)
  local P = P_of(C.force, false)
  return P ~= nil and P.fuel_wait == true
end

--- (0.1.1, issue #2) True while a rail line anchored at the capital waits for its crew's kits: ai/age_up.lua queues
--- no new district meanwhile (a district takes 80 iron and 15 circuits, the kits 110 iron, 30 steel and 20 circuits;
--- one district a minute in early Age II kept crews waiting 7-20 minutes), at most rail_hold.max ticks at a stretch,
--- then rail_hold.rest ticks without.
function planner.rail_hold(C)
  local P = P_of(C.force, false)
  if not (P and P.kits_wait) then
    if P then P.hold_since = nil end
    return false
  end
  local H = PB.rail_hold or {max = 3 * 3600, rest = 2 * 3600}
  P.hold_since = P.hold_since or game.tick
  local t = game.tick - P.hold_since
  if t > H.max + H.rest then
    P.hold_since = game.tick
    return true
  end
  return t <= H.max
end

-- (0.1.1, issue #4) The artillery train of a siege railway: its wagon kit, two locomotive kits and shells, deployed at
-- the line's capital end (ai/council.lua); explosives first when they are short.
local ARTY_KIT, SHELL, EXPLOSIVES = "rts-artillery-wagon-kit", "rts-rail-shell", "rts-explosives"
local function artillery_items(C)
  local out = {}
  if not (deps.council and deps.council.artillery_want and deps.council.artillery_want(C)) then return out end
  local AR = PB.artillery or {}
  local why = "a siege railway's artillery train"
  local need_x = 0
  if construction.have(C, ARTY_KIT) < 1 then need_x = 10 end
  if construction.have(C, SHELL) < (AR.shells or 10) then need_x = math.max(need_x, 2) end
  if need_x > 0 and construction.have(C, EXPLOSIVES) < need_x then out[#out + 1] = {EXPLOSIVES, why} end
  if construction.have(C, ARTY_KIT) < 1 then out[#out + 1] = {ARTY_KIT, why} end
  if construction.have(C, "rts-locomotive-kit") < 2 then out[#out + 1] = {"rts-locomotive-kit", why} end
  if construction.have(C, SHELL) < (AR.shells or 10) then out[#out + 1] = {SHELL, why} end
  return out
end

-- One craft's ingredients of a recipe are in the nation's networks.
local function craftable(C, recipe)
  local r = prototypes.recipe[recipe]
  if not r then return false end
  for _, ing in ipairs(r.ingredients) do
    if construction.have(C, ing.name) < ing.amount then return false end
  end
  return true
end

-- What the works factory should make now, first first: {{recipe, why}, ...}.
local function works_wants(C, P, capital)
  local out = {}
  if planner.engine_focus(C) then out[#out + 1] = {ENGINE_RECIPE, "the research's engines"} end
  for _, w in ipairs(rail_items(C, P, capital)) do out[#out + 1] = w end
  for _, w in ipairs(artillery_items(C)) do out[#out + 1] = w end
  return out
end

local function works_step(C, P, capital)
  local N = C.nation
  local rec = N and N.works_un and buildings.get(N.works_un)
  if not (rec and rec.entity.valid and capital.center) then return end
  local e = rec.entity
  local cur = e.get_recipe()
  -- a craft of the planner's under way finishes first
  if P.rail_mode and cur and cur.name == P.rail_mode and e.is_crafting() then
    P.pins = P.pins or {}
    P.pins[e.unit_number] = rec
    return
  end
  local frec = game.forces[C.force].recipes
  local want, why
  for _, w in ipairs(works_wants(C, P, capital)) do
    if frec[w[1]] and frec[w[1]].enabled and craftable(C, w[1]) then
      want, why = w[1], w[2]
      break
    end
  end
  if want then
    if rec.recipe_mode ~= "fixed" or not cur or cur.name ~= want then
      production.set_auto(rec, false)
      local ok = production.set_recipe(e, want)
      if P.rail_mode ~= want then
        util.log("planner: %s works factory #%d makes %s (%s; iron %d, steel %d)%s", C.force, e.unit_number, want, why,
          construction.have(C, "iron-plate"), construction.have(C, "steel-plate"), ok and "" or " - recipe refused")
      end
    end
    P.rail_mode = want
    P.pins = P.pins or {}
    P.pins[e.unit_number] = rec
    hold_factory(C, e.unit_number, true)
  elseif P.rail_mode then
    P.rail_mode = nil
    production.set_auto(rec, true)
    hold_factory(C, e.unit_number, false)
  end
end

--- True while the planner holds the works factory on a recipe of its own (ai/age_up.lua leaves it fixed then).
function planner.holds_works(C)
  local P = P_of(C.force, false)
  return P ~= nil and P.rail_mode ~= nil
end

--- Buildings of the planner's that the capital's governor pins for workers ({[unit number] = building record}): the
--- concrete chain's factories while they run, the works factory while it makes a recipe of the planner's.
function planner.pins(C)
  local P = P_of(C.force, false)
  return P and P.pins or nil
end

---------------------------------------------------------------------------
-- The pass
---------------------------------------------------------------------------
function planner.step(C, surface)
  if not nation_mode() then return end
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local P = P_of(C.force, true)
  if not P then return end
  local tick = game.tick
  if tick < P.next then return end
  if P.next == 0 then
    local slot = 0
    for f in pairs(storage.ai or {}) do
      if f < C.force then slot = slot + 1 end
    end
    P.next = tick + 60 + (slot * 37) % PB.period
    return
  end
  P.next = tick + PB.period
  local capital = capital_of(C.force)
  if not capital then return end
  local own = deps.cities.for_force(C.force)
  -- the capital first in `own` (MST root, distances)
  table.sort(own, function(a, b)
    if (a.id == capital.id) ~= (b.id == capital.id) then return a.id == capital.id end
    return a.id < b.id
  end)
  if not P.scored_at or tick - P.scored_at >= PB.rescore then rescore(C, P) end
  found_step(C, P, surface, own)
  oil_step(C, P, surface)
  goods_policies(C, P, own, capital)
  trunk_step(C, P, own, capital)
  space_step(C, P, surface)
  buy_step(C, P)
  rush_step(C, P)
  automate_step(C, P, capital)
  rare_step(C, P, surface, own)
  uranium_step(C, P, surface, own, capital)
  P.pins = {} -- (rebuilt every pass: ai/governor.lua pins these for workers)
  concrete_step(C, P, surface)
  works_step(C, P, capital)
end

--- "planner: cities 3/4 (oil town 12, 2 pumps), trunk 2 edges (1 open), sites 14, space stage 1".
function planner.describe(force_name)
  local P = P_of(force_name, false)
  if not P then return "planner: -" end
  local open, n = 0, 0
  for _, E in pairs(P.trunk) do
    n = n + 1
    if E.opened then open = open + 1 end
  end
  local age3 = mod("age3")
  local proj = age3 and age3.project and age3.project(force_name)
  -- the goods of the Age III road in the nation's networks
  local C = storage.ai and storage.ai[force_name]
  local goods = {}
  if C then
    for _, g in ipairs({{"rts-crude-oil", "crude"}, {"plastic-bar", "plastic"}, {"sulfur", "sulfur"},
                        {"advanced-circuit", "adv"}, {"engine-unit", "engine"}, {"rts-science-industrial", "kits"},
                        {"concrete", "concrete"}, {"steel-plate", "steel"}}) do
      goods[#goods + 1] = g[2] .. " " .. construction.have(C, g[1])
    end
  end
  local chain = "-"
  if P.concrete then
    local on = P.concrete.on or {}
    chain = string.format("%s/%s", on[1] and "on" or "off", on[2] and "on" or "off")
  end
  return string.format("planner: cities %d (founded %d, given up %d)%s, oil town %s (%d pumpjacks), trunk %d edges "
    .. "(%d open), sites %d, space %s, rushes %d, buys %d (%.0f cr), concrete chain %s | goods [%s]",
    #deps.cities.for_force(force_name),
    P.stats.founded, P.stats.given_up,
    P.city and string.format(", planning %s at %s", P.city.role, util.pos_str(P.city.site)) or "",
    P.oil and tostring(P.oil.city) or "-", P.stats.pumps, n, open, P.sites and #P.sites or 0,
    proj and string.format("stage %d %s %.0f%%", proj.stage, proj.state, (age3.progress(proj) or 0) * 100) or "-",
    P.space.rushes, P.stats.buys, P.stats.bought_cr or 0, chain, table.concat(goods, ", "))
end

deps.planner = planner
return planner
