-- Phase 5 M2 war autotest (test copy only, tools/autotest-run.sh EXTRA_LUA; docs/PHASE5-M2.md section 4 "War";
-- docs/qa/phase5-war-notes.md). Runs beside a Nation-mode AI match, with the non-participating forces rts-ai-3 (the
-- defending test nation) and rts-ai-2 (the attacker):
--   capture  on the match surface, in the corner farthest from the spawns: a capital city of rts-ai-3 with ~3,000
--            entities on its land (stockpiles, belts, inserters, poles, walls, ghosts), a powered factory making gears
--            and a second city; 24 walkers of rts-ai-2 attack the centre: subdue at 10 %, 20 s contest, flip in slices
--            of 500 (at most 8 ticks), no entity of rts-ai-3 left on the land, unrest 60 s then the factory produces
--            again, population x0.7 (stand-in storage.population), the capital moves to the second city
--   supply   on a lab surface outside the territory grid: a division at 0 SP loses 1.5 % of max health per 10 s and
--            takes no attack order (division order and orders.attack_move), a loose unit next to it is out too, a hub
--            with crates refills it and its network loses the crates; low SP takes back the Armor II/III heal
--   troops   on the same lab surface: two depots 600 tiles apart on one track; 12 walkers (some wounded) embark on a
--            troop train deployed from kits, ride 600 tiles and disembark within 10 s of the arrival with health within
--            1 %; a second train is destroyed in transit (manifest and units gone, alert); a cargo train disbanded at a
--            depot returns 50 % of its kits
-- Log lines "[rts] war autotest check <name>: PASS|FAIL ..." and "[rts] war autotest summary <pass>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local units = require("scripts.units")
local orders = require("scripts.orders")
local buildings = require("scripts.buildings")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local production = require("scripts.production")
local territory = require("scripts.territory")
local cities = require("scripts.cities")
local rails = require("scripts.rails")
local warsupply = require("scripts.warsupply")
local capture = require("scripts.capture")
local garrison = require("scripts.garrison")
local selection = require("scripts.selection")
local supply = require("scripts.supply")

local DEF, ATT = "rts-ai-3", "rts-ai-2"
local LAB = "war-test"
local START = 300            -- ticks after the match start
local TIMEOUT = 20 * 60 * 60 -- the whole test
local CRATE = "rts-supply-crate"

local T -- storage.war_at

local function check(name, ok, fmt, ...)
  T.checks[#T.checks + 1] = {name = name, ok = ok}
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("war autotest check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

local function lab()
  local s = game.surfaces[LAB]
  if s then return s end
  s = game.create_surface(LAB, {width = 4000, height = 1000, peaceful_mode = true, no_enemies_mode = true})
  s.always_day = true
  for cx = 30, 56 do for cy = -3, 12 do s.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end end
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = 980, 1780 do for y = -80, 400 do tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}} end end
  s.set_tiles(tiles, true, false, false, false)
  for _, e in ipairs(s.find_entities_filtered({area = {{960, -100}, {1800, 420}}})) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  return s
end

local function spawn_n(surface, name, n, force, at, cols)
  local list = {}
  cols = cols or 4
  for k = 1, n do
    local e = units.spawn(name, {x = at.x + ((k - 1) % cols) * 3, y = at.y + math.floor((k - 1) / cols) * 3}, force,
      nil, surface)
    if e then list[#list + 1] = e end
  end
  return list
end

local function place(surface, name, pos, force, raise)
  return surface.create_entity({name = name, position = pos, force = force, raise_built = raise})
end

---------------------------------------------------------------------------
-- Capture rig
---------------------------------------------------------------------------
local function test_corner()
  local half = (storage.world and storage.world.size or 1536) / 2
  local spawns = storage.match.spawns or {}
  local best, bd
  local r = half - 200
  for _, c in ipairs({{r, r}, {-r, r}, {r, -r}, {-r, -r}, {0, r}, {0, -r}, {r, 0}, {-r, 0}}) do
    local md
    for _, p in pairs(spawns) do
      local d = util.distance(p, {x = c[1], y = c[2]})
      if not md or d < md then md = d end
    end
    md = md or 0
    if not bd or md > bd then best, bd = {x = c[1], y = c[2]}, md end
  end
  return best, bd
end

local function flatten(surface, area)
  local tiles = {}
  for x = area[1][1], area[2][1] - 1 do
    for y = area[1][2], area[2][2] - 1 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, true, true, false)
  for _, e in ipairs(surface.find_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff", "resource",
                                                                          "fish", "corpse"}})) do
    if e.valid then e.destroy({do_cliff_correction = e.type == "cliff"}) end
  end
end

local function capture_setup()
  local C = T.cap
  local surface = game.surfaces[storage.match.surface]
  local corner, md = test_corner()
  -- the second city lies towards the world centre
  local dx = corner.x == 0 and 0 or (corner.x > 0 and -1 or 1)
  local dy = corner.y == 0 and 0 or (corner.y > 0 and -1 or 1)
  if dx == 0 and dy == 0 then dx = 1 end
  local c1 = {x = math.floor(corner.x) + 0.0, y = math.floor(corner.y) + 0.0}
  local c2 = {x = c1.x + dx * 150 / math.sqrt(dx * dx + dy * dy), y = c1.y + dy * 150 / math.sqrt(dx * dx + dy * dy)}
  c2 = {x = math.floor(c2.x), y = math.floor(c2.y)}
  local x0, x1 = math.min(c1.x, c2.x) - 110, math.max(c1.x, c2.x) + 110
  local y0, y1 = math.min(c1.y, c2.y) - 110, math.max(c1.y, c2.y) + 110
  for cx = math.floor(x0 / 32), math.floor(x1 / 32) do
    for cy = math.floor(y0 / 32), math.floor(y1 / 32) do surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0) end
  end
  surface.force_generate_chunk_requests()
  flatten(surface, {{x0, y0}, {x1, y1}})
  util.log("war autotest: capture rig at %s (nearest spawn %.0f tiles), second city at %s", util.pos_str(c1), md,
    util.pos_str(c2))
  local id1 = cities.found(DEF, c1, {why = "(war autotest)"})
  local id2 = cities.found(DEF, c2, {why = "(war autotest)"})
  C.city, C.city2 = id1, id2
  local city = cities.get(id1)
  if not (city and cities.get(id2)) then
    check("capture_setup", false, "cities %s %s", tostring(id1), tostring(id2))
    C.phase = "done"
    return
  end
  territory.flush()
  local center = city.entity
  local p = center.position
  -- ~3,000 entities on the city's land: a block east (or west) of the centre
  local side = dx ~= 0 and -dx or 1 -- away from the second city
  local n = 0
  local kinds = {{"rts-stockpile", 600}, {"transport-belt", 1300}, {"fast-inserter", 600}, {"medium-electric-pole", 300},
                 {"rts-wall", 300}}
  local positions = {}
  for i = 0, 61 do
    for j = 0, 49 do positions[#positions + 1] = {x = p.x + side * (20 + i) + 0.5, y = p.y - 25 + j + 0.5} end
  end
  local k = 1
  for _, kd in ipairs(kinds) do
    for _ = 1, kd[2] do
      local pos = positions[k]
      k = k + 1
      local e = pos and place(surface, kd[1], pos, DEF, kd[1] == "rts-stockpile" or kd[1] == "rts-wall")
      if e then n = n + 1 end
    end
  end
  -- ghosts and an item-request-proxy-free set of turret ghosts on the land
  local ghosts = 0
  for i = 1, 20 do
    local g = surface.create_entity({name = "entity-ghost", inner_name = "rts-turret", position = {p.x - side * 30,
      p.y - 40 + i * 4}, force = DEF})
    if g then ghosts = ghosts + 1 end
  end
  -- a powered factory making gears next to the centre, inside its hub pole's area
  local fpos = surface.find_non_colliding_position("rts-factory", {p.x, p.y + 7}, 6, 1, true)
  local factory = fpos and place(surface, "rts-factory", fpos, DEF, true)
  if factory then
    production.set_recipe(factory, "rts-gear")
    local inv = factory.get_inventory(defines.inventory.crafter_input)
    if inv then inv.insert({name = "iron-plate", count = 100}) end
    C.factory = factory
  end
  -- a rail depot of the defender on the land: it changes owner with the city (stops renamed)
  local dpos = {x = p.x - side * 50, y = p.y - 50}
  local depot = place(surface, "rts-depot", dpos, DEF, true)
  C.depot = depot and depot.unit_number
  -- 100 residents: scripts/population.lua's record when it exists, else a stand-in record
  storage.population = storage.population or {}
  if storage.population[id1] then storage.population[id1].pop = 100 else storage.population[id1] = {pop = 100} end
  territory.flush()
  local box = territory.city_box(id1)
  local on_land = 0
  for _, e in ipairs(surface.find_entities_filtered({area = {{box.x0, box.y0}, {box.x1, box.y1}}, force = DEF})) do
    if e.valid and territory.city_at(e.position) == id1 then on_land = on_land + 1 end
  end
  C.entities, C.ghosts, C.on_land = n, ghosts, on_land
  check("capture_setup", on_land >= 3000 and factory ~= nil and storage.nations[DEF].capital == id1,
    "capital city %d of %s at %s: %d entities placed, %d ghosts, %d entities of %s on its land, factory %s, second "
    .. "city %d", id1, DEF, util.pos_str(p), n, ghosts, on_land, DEF, tostring(factory and factory.unit_number), id2)
  -- the attackers wait 40 tiles out
  local ap = {x = p.x - side * 40, y = p.y + 30}
  C.attackers = spawn_n(surface, "rts-walker", 24, ATT, ap, 6)
  C.phase = "wait_factory"
  C.t = game.tick
end

local function on_land_count(C)
  local surface = game.surfaces[storage.match.surface]
  local box = territory.city_box(C.city)
  if not box then return -1 end
  local n = 0
  for _, e in ipairs(surface.find_entities_filtered({area = {{box.x0, box.y0}, {box.x1, box.y1}}, force = DEF})) do
    if e.valid and not capture.KEEP_TYPES[e.type] and e.name ~= "rts-garrison-turret"
       and territory.city_at(e.position) == C.city then
      n = n + 1
    end
  end
  return n
end

local function capture_tick()
  local C = T.cap
  local tick = game.tick
  if C.phase == "setup" then
    capture_setup()
  elseif C.phase == "wait_factory" then
    -- the factory runs before the attack (power, recipe, ingredients)
    if C.factory and C.factory.valid and C.factory.products_finished > 0 then
      C.made0 = C.factory.products_finished
      local city = cities.get(C.city)
      local list = {}
      for _, e in ipairs(C.attackers) do if e.valid then list[#list + 1] = e end end
      orders.attack(list, city.entity) -- loose units at the centre (an attack-move would also hit the block)
      C.phase, C.t = "attack", tick
      util.log("war autotest: capture: factory made %d gears; %d attackers ordered at the centre", C.made0, #list)
    elseif tick - C.t > 30 * 60 then
      check("capture_factory_runs", false, "the test factory made nothing in 30 s")
      C.phase = "done"
    end
  elseif C.phase == "attack" then
    local P = storage.population and storage.population[C.city]
    local city0 = cities.get(C.city)
    if P and city0 and city0.force == DEF then C.pop_last = P.pop end -- residents just before the flip (they grow)
    local s = storage.capture
    local cc = s and s.cities[C.city]
    if cc and cc.subdued and not C.subdued_tick then
      C.subdued_tick = tick
      local city = cities.get(C.city)
      check("capture_subdue", city.entity.valid and city.entity.health >= city.entity.max_health * 0.099,
        "centre clamped at %.0f of %.0f HP (%.1f %%) %.1f s after the attack order", city.entity.health,
        city.entity.max_health, 100 * city.entity.health / city.entity.max_health, (tick - C.t) / 60)
    end
    if cc and cc.capturing then C.contest_seen = true end
    local city = cities.get(C.city)
    if city and city.force == ATT then
      C.flip_tick = tick
      C.phase = "flipping"
      check("capture_contest", C.subdued_tick ~= nil and (tick - C.subdued_tick) >= 20 * 60,
        "flipped %.1f s after the subdue (contest 20 s of uncontested presence)", (tick - (C.subdued_tick or tick)) / 60)
    elseif tick - C.t > 4 * 60 * 60 then
      check("capture_contest", false, "no capture within 4 minutes (subdued %s)", tostring(C.subdued_tick))
      C.phase = "done"
    end
  elseif C.phase == "flipping" then
    local s = storage.capture
    if s.last and s.last.city == C.city and s.last.tick >= C.flip_tick then
      local L = s.last
      check("capture_slices", L.slices <= 8 and L.flipped >= 3000,
        "%d entities flipped in %d slices over %d ticks (contract: 3,000 within 8 ticks of slices of %d), %d ghosts "
        .. "destroyed", L.flipped, L.slices, L.ticks, capture.SLICE, L.ghosts)
      local left = on_land_count(C)
      check("capture_no_old_force", left == 0, "%d entities of %s left on the city's land", left, DEF)
      local city = cities.get(C.city)
      check("capture_land", territory.owner_at(city.position) == ATT and city.force == ATT,
        "land at the centre owned by %s, city record force %s", tostring(territory.owner_at(city.position)), city.force)
      local pop = storage.population[C.city] and storage.population[C.city].pop
      local want = math.floor((C.pop_last or 100) * 0.7 + 0.5)
      check("capture_population", pop ~= nil and math.abs(pop - want) <= 1, "population %s at the flip -> %s (x0.7 = %d)",
        tostring(C.pop_last), tostring(pop), want)
      local nat = storage.nations[DEF]
      check("capture_capital_moves", nat and nat.capital == C.city2 and cities.get(C.city2).capital == true,
        "%s capital: city %s (second city %d)", DEF, tostring(nat and nat.capital), C.city2)
      check("capture_signal", (T.signals or 0) >= 1, "rts_city_captured signals: %d", T.signals or 0)
      check("capture_health", math.abs(city.entity.health / city.entity.max_health - 0.25) < 0.05,
        "the centre restarts at %.0f %% health", 100 * city.entity.health / city.entity.max_health)
      local d = C.depot and rails.depot(C.depot)
      local st = d and d.platform and d.platform.stops and d.platform.stops[1]
      check("capture_depot", d ~= nil and d.force == ATT and st ~= nil and st.valid and st.force.name == ATT
        and string.find(st.backer_name, ATT, 1, true) ~= nil and buildings.get(C.depot).force == ATT,
        "depot #%s: record force %s, stop %s of %s named '%s'", tostring(C.depot), d and d.force or "-",
        st and st.valid and st.unit_number or "-", st and st.valid and st.force.name or "-",
        st and st.valid and st.backer_name or "-")
      local f = C.factory
      C.made_flip = f.valid and f.products_finished or -1
      C.phase, C.t = "unrest", tick
    elseif tick - C.flip_tick > 600 then
      check("capture_slices", false, "the flip job did not finish within 600 ticks")
      C.phase = "done"
    end
  elseif C.phase == "unrest" then
    local f = C.factory
    if tick - C.t == 30 * 60 then
      C.made_mid = f.valid and f.products_finished or -1
      C.disabled_mid = f.valid and f.disabled_by_script
    elseif tick - C.t >= 75 * 60 then
      local made = f.valid and f.products_finished or -1
      check("capture_unrest", C.disabled_mid == true and C.made_mid == C.made_flip and made > C.made_mid
        and f.force.name == ATT and not f.disabled_by_script,
        "factory of %s: disabled at 30 s = %s, crafts %d -> %d during unrest, %d at 75 s (production resumes after 60 s)",
        f.valid and f.force.name or "-", tostring(C.disabled_mid), C.made_flip, C.made_mid, made)
      C.phase = "done"
    end
  end
end

---------------------------------------------------------------------------
-- Garrison rig (match surface, the defender's second city, its capital after the capture)
---------------------------------------------------------------------------
local function surface_count(surface, pos, force)
  return surface.count_entities_filtered({position = pos, radius = 16, force = force, type = {"unit", "spider-unit"}})
end

local function garrison_tick()
  local G = T.gar
  local C = T.cap
  local tick = game.tick
  if G.phase == "wait" then
    if C.phase == "done" and C.city2 then G.phase = "setup" end
  elseif G.phase == "setup" then
    local city = cities.get(C.city2)
    if not (city and city.entity and city.entity.valid) then
      check("garrison_enter", false, "no second city")
      G.phase = "done"
      return
    end
    local surface = city.entity.surface
    local p = city.entity.position
    local list = spawn_n(surface, "rts-walker", 12, DEF, {x = p.x - 30, y = p.y + 20}, 4)
    G.city, G.div = city.id, divisions.create(DEF, list, {name = "Home Guard", stance = "hold"}, {owner = "ai"})
    divisions.get(G.div).sp = 70 -- a garrison neither refills nor drains it
    G.used0 = supply.used(DEF)
    divisions.order(G.div, "garrison", city.id)
    G.phase, G.t = "entering", tick
  elseif G.phase == "entering" then
    local gar = garrison.of(G.city)
    if #gar.records == 12 then
      check("garrison_enter", divisions.get(G.div) == nil and gar.points == 12 and gar.turrets == 3
        and supply.used(DEF) == G.used0,
        "12 walkers inside after %.1f s: %d points, %d hidden guns manned (1 per 4 points), division gone %s, supply "
        .. "used %d -> %d (kept)", (tick - G.t) / 60, gar.points, gar.turrets, tostring(divisions.get(G.div) == nil),
        G.used0, supply.used(DEF))
      local city = cities.get(G.city)
      local p = city.entity.position
      G.raiders = spawn_n(city.entity.surface, "rts-walker", 2, ATT, {x = p.x + 14, y = p.y - 2}, 2)
      for _, e in ipairs(G.raiders) do e.health = e.max_health * 0.5 end
      G.phase, G.t = "guns", tick
    elseif tick - G.t > 60 * 60 then
      check("garrison_enter", false, "%d records after 60 s", #gar.records)
      G.phase = "done"
    end
  elseif G.phase == "guns" then
    local alive = 0
    for _, e in ipairs(G.raiders) do if e.valid then alive = alive + 1 end end
    if alive == 0 or tick - G.t > 30 * 60 then
      check("garrison_guns", alive == 0, "%d of 2 enemy walkers 14 tiles from the centre still alive after %.1f s", alive,
        (tick - G.t) / 60)
      local id = garrison.sortie(G.city, "autotest")
      local D = id and divisions.get(id)
      local gar = garrison.of(G.city)
      check("garrison_sortie", D ~= nil and #divisions.live_members(D) == 12 and #gar.records == 0 and gar.turrets == 0
        and math.abs(D.sp - 70) < 1,
        "sortie: division #%s with %d units named %s at %.1f SP (70 before), %d records and %d guns left", tostring(id),
        D and #divisions.live_members(D) or 0, D and divisions.label(D) or "-", D and D.sp or -1, #gar.records,
        gar.turrets)
      G.div2 = id
      if id then divisions.order(id, "garrison", G.city) end
      G.phase, G.t = "again", tick
    end
  elseif G.phase == "again" then
    local gar = garrison.of(G.city)
    if #gar.records == 12 then
      local city = cities.get(G.city)
      local e = city.entity
      e.health = e.max_health * 0.4
      e.damage(1, "neutral", "physical")
      local gar2 = garrison.of(G.city)
      check("garrison_auto_sortie", #gar2.records == 0, "the centre at 40 %% health: %d records left inside, %d units of "
        .. "%s on the map near it", #gar2.records, surface_count(e.surface, e.position, DEF), DEF)
      e.health = e.max_health
      -- the right-click path (orders hook) with the autotest's player 0 (rts-player) at its capital
      local nat = storage.nations["rts-player"]
      local cap = nat and cities.get(nat.capital)
      if cap and cap.entity and cap.entity.valid then
        local q = cap.entity.position
        local list = spawn_n(cap.entity.surface, "rts-walker", 4, "rts-player", {x = q.x + 6, y = q.y + 6}, 2)
        selection.set(0, list)
        local order, n = garrison.right_click(0, q, {cap.entity}, false)
        local g3 = garrison.of(cap.id)
        check("garrison_right_click", order == "garrison" and n == 4 and #g3.records >= 4,
          "right-click on the own City Center with 4 units selected: order %s, %s units, %d records inside the capital",
          tostring(order), tostring(n), #g3.records)
        garrison.sortie(cap.id, "autotest")
      else
        check("garrison_right_click", false, "rts-player has no capital")
      end
      G.phase = "done"
    elseif tick - G.t > 60 * 60 then
      check("garrison_auto_sortie", false, "the division did not go back in (%d records)", #gar.records)
      G.phase = "done"
    end
  end
end

---------------------------------------------------------------------------
-- Supply rig (lab surface)
---------------------------------------------------------------------------
local function supply_tick()
  local Su = T.sup
  local s = lab()
  local tick = game.tick
  if Su.phase == "setup" then
    local list = spawn_n(s, "rts-walker", 8, ATT, {x = 1100, y = 0})
    Su.div = divisions.create(ATT, list, {stance = "hold"}, {owner = "ai"})
    local D = divisions.get(Su.div)
    D.sp = 0
    Su.loose = spawn_n(s, "rts-walker", 1, ATT, {x = 1100, y = 14})[1]
    Su.far = spawn_n(s, "rts-walker", 1, ATT, {x = 1300, y = 0})[1]
    Su.hp0 = {}
    for _, rec in ipairs(divisions.live_members(D)) do Su.hp0[rec.entity.unit_number] = rec.entity.health end
    Su.phase, Su.t = "out", tick
  elseif Su.phase == "out" then
    local D = divisions.get(Su.div)
    if tick - Su.t == 120 then
      -- attack orders refused
      local ok = divisions.order(Su.div, "attack_move", {x = 1150, y = 0})
      local ents = {}
      for _, rec in ipairs(divisions.live_members(D)) do ents[#ents + 1] = rec.entity end
      local n = orders.attack_move(ents, {x = 1150, y = 0})
      local n_loose = orders.attack_move({Su.loose}, {x = 1150, y = 0})
      local n_far = orders.attack_move({Su.far}, {x = 1350, y = 0})
      orders.stop({Su.far})
      check("supply_out_refuses_attack", ok == false and n == 0 and n_loose == 0 and n_far == 1,
        "division order %s, attack-move to its %d members ordered %d, loose unit 14 tiles away ordered %d (state %s), "
        .. "loose unit 200 tiles away ordered %d", tostring(ok), #ents, n, n_loose, warsupply.unit_state(Su.loose), n_far)
    elseif tick - Su.t == 21 * 60 then
      local worst, best, cnt = 1, 0, 0
      for _, rec in ipairs(divisions.live_members(D)) do
        local e = rec.entity
        local lost = (Su.hp0[e.unit_number] - e.health) / e.max_health
        worst, best = math.min(worst, lost), math.max(best, lost)
        cnt = cnt + 1
      end
      -- 21 s: two attrition passes (every 10 s) -> 3.0 % of max health each
      check("supply_out_attrition", cnt == 8 and worst >= 0.0299 and best <= 0.0301,
        "%d members lost %.2f-%.2f %% of max health in 21 s (1.5 %% per 10 s); loose unit next to it at %.1f %%", cnt,
        worst * 100, best * 100, Su.loose.valid and 100 * Su.loose.health / Su.loose.max_health or -1)
      -- a hub with crates 40 tiles away
      local hub = place(s, "rts-hub", {x = 1100, y = 40}, ATT, true)
      Su.hub = hub
      local net = hub and logistics.hub_network(hub.unit_number)
      Su.crates0 = 0
      if net then
        net.insert({name = CRATE, count = 20})
        Su.crates0 = net.get_item_count(CRATE)
      end
      Su.sp0 = D.sp
      Su.phase, Su.t = "refill", tick
    end
  elseif Su.phase == "refill" then
    local D = divisions.get(Su.div)
    if tick - Su.t >= 61 * 60 then
      local net = Su.hub and Su.hub.valid and logistics.hub_network(Su.hub.unit_number)
      local crates = net and net.get_item_count(CRATE) or -1
      local paid = math.ceil((D.sp - Su.sp0) / 10 - 1e-9)
      check("supply_refill", D.sp >= 18 and D.sp <= 22 and crates == Su.crates0 - paid,
        "SP %.1f -> %.1f in 61 s next to a hub with crates (20 per minute), crates in its network %d -> %d (1 crate per "
        .. "10 SP started: %d)", Su.sp0, D.sp, Su.crates0, crates, paid)
      -- low: Armor II/III heals nothing
      local rec = divisions.live_members(D)[1]
      local e = rec.entity
      storage.research.armor[ATT] = 0.2
      e.health = e.max_health
      e.damage(50, "neutral", "physical")
      local lost_low = e.max_health - e.health
      D.sp = 80
      e.health = e.max_health
      e.damage(50, "neutral", "physical")
      local lost_ok = e.max_health - e.health
      storage.research.armor[ATT] = nil
      check("supply_low_no_armor_heal", math.abs(lost_low - 50) < 0.01 and math.abs(lost_ok - 40) < 0.01,
        "a 50-damage hit with Armor 20 %%: %.1f lost while low (%.0f SP), %.1f while supplied", lost_low, 20, lost_ok)
      Su.phase = "done"
    end
  end
end

---------------------------------------------------------------------------
-- Troop rig (lab surface)
---------------------------------------------------------------------------
local TY = 300
local function troop_setup()
  local Tr = T.troop
  local s = lab()
  local A = place(s, "rts-depot", {x = 1050, y = TY}, ATT, true)
  local B = place(s, "rts-depot", {x = 1650, y = TY}, ATT, true)
  local dA, dB = A and rails.depot(A.unit_number), B and rails.depot(B.unit_number)
  if not (dA and dB and dA.platform and dB.platform and dA.platform.track == dB.platform.track) then
    check("troop_setup", false, "depots %s %s, platforms %s %s", tostring(A), tostring(B),
      tostring(dA and dA.platform), tostring(dB and dB.platform))
    Tr.phase = "done"
    return
  end
  -- straight track between the platforms
  local ty = dA.platform.track
  local laid = 0
  local ax = dA.platform.ends[2].x
  local bx = dB.platform.ends[1].x
  for x = ax + 1, bx - 1, 2 do
    if s.create_entity({name = "straight-rail", position = {x, ty}, direction = defines.direction.east, force = ATT}) then
      laid = laid + 1
    end
  end
  Tr.A, Tr.B = A.unit_number, B.unit_number
  for _, un in ipairs({Tr.A, Tr.B}) do
    local net = logistics.hub_network(un)
    net.insert({name = "coal", count = 200})
  end
  local netA = logistics.hub_network(Tr.A)
  netA.insert({name = "rts-locomotive-kit", count = 4})
  netA.insert({name = "rts-troop-wagon-kit", count = 2})
  local list = spawn_n(s, "rts-walker", 12, ATT, {x = 1040, y = TY + 30}, 6)
  Tr.div = divisions.create(ATT, list, {name = "Rail Guard", stance = "hold"}, {owner = "ai"})
  divisions.get(Tr.div).sp = 60 -- the ride must neither refill nor drain it
  Tr.hp = {}
  for i, e in ipairs(list) do
    if i % 3 == 0 then e.health = e.max_health * 0.6 elseif i % 3 == 1 then e.health = e.max_health * 0.83 end
    Tr.hp[#Tr.hp + 1] = e.health / e.max_health
  end
  table.sort(Tr.hp)
  check("troop_setup", laid > 250 and #list == 12, "depots #%d and #%d %.0f tiles apart on track y=%d, %d rails laid, "
    .. "division #%d of %d walkers", Tr.A, Tr.B, util.distance(A.position, B.position), ty, laid, Tr.div, #list)
  local ok = divisions.order(Tr.div, "embark", Tr.A)
  local rec = garrison.troop_train_at(ATT, Tr.A)
  Tr.train = rec and rails.train_of(rec)
  check("troop_embark_order", ok and Tr.train ~= nil, "embark order %s, troop train %s deployed at depot #%d",
    tostring(ok), tostring(Tr.train and Tr.train.id), Tr.A)
  if not Tr.train then
    Tr.phase = "done"
    return
  end
  rails.set_route(Tr.train, Tr.A, Tr.B)
  Tr.phase, Tr.t = "boarding", game.tick
end

local function hp_list(D)
  local hp = {}
  for _, rec in ipairs(divisions.live_members(D)) do hp[#hp + 1] = rec.entity.health / rec.entity.max_health end
  table.sort(hp)
  return hp
end

local function troop_tick()
  local Tr = T.troop
  local tick = game.tick
  if Tr.phase == "setup" then
    troop_setup()
  elseif Tr.phase == "boarding" then
    local D = divisions.get(Tr.div)
    local train = Tr.train
    if D and (D.aboard or 0) == 12 and train.valid and math.abs(train.speed) > 0 then
      Tr.depart_tick = tick
      Tr.start_x = train.front_stock.position.x
      Tr.phase = "travel"
      util.log("war autotest: troop train %d left with 12 aboard after %.1f s", train.id, (tick - Tr.t) / 60)
      local n, sup, cap = garrison.train_load(train)
      check("troop_boarded", n == 12 and sup == 12 and next(D.units) == nil and divisions.get(Tr.div) ~= nil,
        "%d units aboard (%d / %d supply), division #%d kept with %d units on the map", n, sup, cap, Tr.div,
        table_size(D.units))
    elseif tick - Tr.t > 3 * 60 * 60 then
      check("troop_boarded", false, "aboard %s after 3 minutes", tostring(D and D.aboard))
      Tr.phase = "done"
    end
  elseif Tr.phase == "travel" then
    local D = divisions.get(Tr.div)
    if Tr.arrive_tick and D and #divisions.live_members(D) == 12 then
      local hp = hp_list(D)
      local worst = 0
      for i = 1, 12 do worst = math.max(worst, math.abs((hp[i] or 0) - (Tr.hp[i] or 1))) end
      local c = util.centroid((function()
        local l = {}
        for _, rec in ipairs(divisions.live_members(D)) do l[#l + 1] = rec.entity end
        return l
      end)())
      check("troop_ride", Tr.arrive_x - Tr.start_x >= 560 and (tick - Tr.arrive_tick) <= 600 and worst <= 0.01
        and math.abs(D.sp - 60) < 2,
        "12 walkers rode %.0f tiles in %.1f s and were back on the map %.1f s after the arrival (at most 10 s), "
        .. "worst health difference %.2f %% (at most 1 %%), division #%d centroid %s, SP 60 -> %.1f",
        Tr.arrive_x - Tr.start_x, (Tr.arrive_tick - Tr.depart_tick) / 60, (tick - Tr.arrive_tick) / 60, worst * 100,
        Tr.div, util.pos_str(c), D.sp)
      Tr.phase, Tr.t = "second", tick
    elseif tick - Tr.depart_tick > 3 * 60 * 60 then
      check("troop_ride", false, "no arrival within 3 minutes (arrive %s)", tostring(Tr.arrive_tick))
      Tr.phase = "done"
    end
  elseif Tr.phase == "second" then
    -- the train comes back to A empty; a second division boards it and its wagon is destroyed in transit
    local rec = garrison.troop_train_at(ATT, Tr.A)
    if rec and not Tr.div2 then
      local list = spawn_n(lab(), "rts-walker", 6, ATT, {x = 1040, y = TY + 30}, 6)
      Tr.div2 = divisions.create(ATT, list, {stance = "hold"}, {owner = "ai"})
      divisions.order(Tr.div2, "embark", Tr.A)
      Tr.train = rails.train_of(rec)
      Tr.t = tick
    elseif Tr.div2 then
      local D2 = divisions.get(Tr.div2)
      local train = Tr.train
      if train and train.valid and math.abs(train.speed) > 0.1 and D2 and (D2.aboard or 0) == 6
         and train.front_stock.position.x > 1200 then
        -- Phase 5 M3 war2: every loaded wagon (the six may board two wagons of the train, as on the M3 copy, where the
        -- boarding order shifted; one destroyed wagon then leaves the other's manifest and the division)
        local wagons = {}
        local M0 = storage.rails.manifests or {}
        for _, w in ipairs(train.cargo_wagons) do
          if M0[w.unit_number] and #M0[w.unit_number].records > 0 then wagons[#wagons + 1] = w end
        end
        local alerts0 = #(storage.alerts or {})
        local lost0 = garrison.describe()
        for _, w in ipairs(wagons) do
          if w.valid then w.die("neutral") end
        end
        local found = false
        for i = alerts0 + 1, #(storage.alerts or {}) do
          if storage.alerts[i].kind == "troop-wagon-lost" then found = true end
        end
        local M = storage.rails.manifests or {}
        check("troop_wagon_destroyed", divisions.get(Tr.div2) == nil and table_size(M) == 0 and found,
          "wagon destroyed at x=%.0f with 6 aboard: division #%d %s, manifests %d, alert %s (%s)",
          train.valid and train.front_stock.position.x or -1, Tr.div2,
          divisions.get(Tr.div2) and "still exists" or "gone", table_size(M), tostring(found), lost0)
        Tr.phase, Tr.t = "disband", tick
      elseif tick - Tr.t > 3 * 60 * 60 then
        check("troop_wagon_destroyed", false, "the second ride did not start (aboard %s)", tostring(D2 and D2.aboard))
        Tr.phase = "disband"
      end
    elseif tick - Tr.t > 3 * 60 * 60 then
      check("troop_wagon_destroyed", false, "the troop train did not come back to depot A")
      Tr.phase = "disband"
    end
  elseif Tr.phase == "disband" then
    local net = logistics.hub_network(Tr.B)
    net.insert({name = "rts-locomotive-kit", count = 2})
    net.insert({name = "rts-cargo-wagon-kit", count = 2})
    -- a platform may still hold the rest of the troop train: clear B's platform first
    local train, why = rails.create_train(Tr.B, "cargo")
    if not train then
      for _, rec in ipairs(rails.trains_of(ATT)) do
        local t = rails.train_of(rec)
        if t and t.valid then
          storage.rails.trains[t.id] = nil
          for _, c in ipairs(t.carriages) do c.destroy() end
        end
      end
      train, why = rails.create_train(Tr.B, "cargo")
    end
    if not train then
      check("disband_half_kits", false, "no cargo train at depot B: %s", tostring(why))
      Tr.phase = "done"
      return
    end
    local l0, w0 = net.get_item_count("rts-locomotive-kit"), net.get_item_count("rts-cargo-wagon-kit")
    local res, why2 = rails.disband_train(train)
    local l1, w1 = net.get_item_count("rts-locomotive-kit"), net.get_item_count("rts-cargo-wagon-kit")
    check("disband_half_kits", res ~= nil and (l1 - l0) == 1 and (w1 - w0) == 1 and not train.valid,
      "a cargo train of 2 locomotives and 2 wagons disbanded at depot #%d: +%d locomotive kits, +%d wagon kits (%s)",
      Tr.B, l1 - l0, w1 - w0, tostring(why2))
    Tr.phase = "done"
  end
end

events.on(defines.events.on_train_changed_state, function(e)
  local Tr = T and T.troop
  if not (Tr and Tr.phase == "travel" and Tr.train and Tr.train.valid and e.train.id == Tr.train.id) then return end
  if e.train.state == defines.train_state.wait_station and e.train.station then
    local dun = storage.rails.stops[e.train.station.unit_number]
    if dun == Tr.B and not Tr.arrive_tick then
      Tr.arrive_tick = game.tick
      Tr.arrive_x = e.train.front_stock.position.x
      util.log("war autotest: troop train %d at depot B after %.1f s", e.train.id, (game.tick - Tr.depart_tick) / 60)
    end
  end
end)

events.on_signal("rts_city_captured", function(d)
  if T then T.signals = (T.signals or 0) + 1 end
  util.log("war autotest: signal rts_city_captured city %s %s -> %s", tostring(d.city_id), tostring(d.from),
    tostring(d.to))
end)

events.on_nth_tick(1, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  if not storage.war_at then
    if game.tick - m.tick_started < START then return end
    storage.war_at = {pass = 0, fail = 0, checks = {}, started = game.tick, cap = {phase = "setup"},
                      sup = {phase = "setup"}, troop = {phase = "setup"}, gar = {phase = "wait"}}
    T = storage.war_at
    for _, f in ipairs({DEF, ATT}) do
      if not game.forces[f] then game.create_force(f) end
    end
    game.forces[DEF].set_cease_fire(ATT, false)
    game.forces[ATT].set_cease_fire(DEF, false)
    util.log("war autotest: started at tick %d (mode %s)", game.tick, tostring(m.config.mode))
  end
  T = storage.war_at
  if T.done then return end
  if T.cap.phase ~= "done" then capture_tick() end
  if T.sup.phase ~= "done" then supply_tick() end
  if T.troop.phase ~= "done" then troop_tick() end
  if T.gar.phase ~= "done" then garrison_tick() end
  if (T.cap.phase == "done" and T.sup.phase == "done" and T.troop.phase == "done" and T.gar.phase == "done")
     or game.tick - T.started > TIMEOUT then
    T.done = true
    util.log("war autotest: %s; %s; %s", warsupply.describe(ATT), capture.describe(), garrison.describe())
    util.log("war autotest summary %d/%d (%s)", T.pass, T.pass + T.fail, T.fail == 0 and "all passed" or "FAILED")
  end
end)

events.on_load(function() T = storage.war_at end)
