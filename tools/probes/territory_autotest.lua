-- Territory and cities autotest (Phase 5 M1, docs/PHASE5-M1.md section 4 "Territory/cities"). Test copy only:
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/territory_autotest.lua STOP_ON='territory autotest summary' \
--     tools/autotest-run.sh <name> '{opponents = 1, difficulty = "normal", size = "large", enemy_brain = "ai",
--     mode = "nation"}' 400
-- Two seconds into a Nation match the probe stops both AI commanders (a controlled board), then checks:
--   grid_ready          both capitals are cities (tier 2, radius 72 + 24 capital bonus), own their spot, the grid has
--                       border objects
--   place_<class>_<land> ghost placement through the on_built_entity path (player ghost) for every building class
--                       (economic rts-smelter, outpost rts-fort / rts-hub / rts-turret, infra transport-belt /
--                       medium-electric-pole / rts-wall, city rts-city-center) on own, neutral and enemy land; the
--                       expected table is territory.lua's header (city on own land: refused by the 96-tile spacing)
--   robot_refused       a smelter "built by a robot" on neutral land is removed and its item goes back to the pool
--   attrition_deep      6 walkers 40 tiles inside AI land (cease-fire both ways) lose 15-25 % HP in 60 s
--   attrition_supplied  6 walkers as deep but next to an own hub lose 0 %
--   found_far           a City Center ghost 300 tiles from the capital, a charter in the pool, the Commander walks
--                       there: within 120 s the city is registered (tier 1), owns its land, has its own logistic
--                       network (not the capital's), its power part, +10 supply, a "city-founded" alert
--   make_targets        set / read / clear a make target of the new city (and the signal)
--   tier_up             10 solar arrays on the new city's land and 500 plates into its market: town (tier 2,
--                       radius 72) within 25 s, its land grows
--   city_lost           the new City Center dies: the city is gone, its land is neutral again, "city-lost" and
--                       "territory-lost" alerts, the supply cap is back
--   territory_perf      the grid work so far: jobs, cells, segments, objects (informational) and the checksum
-- Log lines "[rts] territory autotest ..."; the last is "[rts] territory autotest summary <pass>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local commander = require("scripts.commander")
local economy = require("scripts.economy")
local buildings = require("scripts.buildings")
local units = require("scripts.units")
local match = require("scripts.match")
local supply = require("scripts.supply")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local cities = require("scripts.cities")

local F, E = "rts-player", "rts-ai-1"
local signals = {} -- module-local: make-target signals seen in this tick (logging only)
events.on_signal("rts_make_targets_changed", function(d) signals[#signals + 1] = d end)
local FAR = 300

local function P()
  storage.territory_probe = storage.territory_probe or {checks = {}, pass = 0, fail = 0}
  return storage.territory_probe
end

local function check(name, ok, fmt, ...)
  local S = P()
  S.checks[#S.checks + 1] = name
  if ok then S.pass = S.pass + 1 else S.fail = S.fail + 1 end
  util.log("territory autotest check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end

local function surface() return match.surface() end

local function spot(name, near, radius)
  local p = surface().find_non_colliding_position(name, near, radius or 16, 1, true)
  if not p then return nil end
  local proto = prototypes.entity[name]
  if proto.tile_width % 2 == 0 then
    return {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5)}
  end
  return {x = math.floor(p.x) + 0.5, y = math.floor(p.y) + 0.5}
end

local function capital(force)
  local n = storage.nations and storage.nations[force]
  return n and cities.get(n.capital)
end

-- Expected placement: [class][land] = allowed
local EXPECT = {
  economic = {own = true, neutral = false, enemy = false},
  outpost = {own = true, neutral = true, enemy = false},
  infra = {own = true, neutral = true, enemy = false},
  city = {own = false, neutral = true, enemy = false},
}
local NAMES = {
  {"rts-smelter", "economic"}, {"rts-fort", "outpost"}, {"rts-hub", "outpost"}, {"rts-turret", "outpost"},
  {"transport-belt", "infra"}, {"medium-electric-pole", "infra"}, {"rts-wall", "infra"}, {"rts-city-center", "city"},
}

local function place_table(S)
  local own_c, enemy_c = capital(F), capital(E)
  local lands = {
    own = {x = own_c.position.x + 30, y = own_c.position.y + 34},
    neutral = {x = (own_c.position.x + enemy_c.position.x) / 2, y = 60},
    enemy = {x = enemy_c.position.x - 30, y = enemy_c.position.y + 34},
  }
  for land, near in pairs(lands) do
    local owner = territory.owner_at(near)
    util.log("territory autotest: %s land probe at %s owner %s", land, util.pos_str(near), tostring(owner))
  end
  for _, pair in ipairs(NAMES) do
    local name, class = pair[1], pair[2]
    for _, land in ipairs({"own", "neutral", "enemy"}) do
      local pos = spot(name, lands[land], 20)
      local want = EXPECT[class][land]
      if not pos then
        check("place_" .. class .. "_" .. land .. "_" .. name, false, "no free spot for %s near %s", name,
          util.pos_str(lands[land]))
      else
        local owner = territory.owner_at(pos)
        local ok_rule, reason = territory.can_build(F, name, pos)
        local ghost = surface().create_entity({name = "entity-ghost", inner_name = name, position = pos, force = F})
        local kept = false
        if ghost then
          events.dispatch(defines.events.on_built_entity, {name = defines.events.on_built_entity, entity = ghost, player_index = 0,
                                                           tick = game.tick})
          kept = ghost.valid
          if ghost.valid then ghost.destroy() end
        end
        check("place_" .. class .. "_" .. land .. "_" .. name, ghost ~= nil and kept == want and ok_rule == want,
          "%s at %s (land %s, owner %s): can_build=%s (%s), ghost kept=%s, expected %s", name, util.pos_str(pos),
          land, tostring(owner), tostring(ok_rule), tostring(reason), tostring(kept), tostring(want))
      end
    end
  end
  -- a robot-built smelter on neutral land is removed and paid back
  local pos = spot("rts-smelter", lands.neutral, 20)
  local before = economy.network(F).get_item_count("rts-smelter")
  local e = surface().create_entity({name = "rts-smelter", position = pos, force = F})
  events.dispatch(defines.events.on_robot_built_entity, {name = defines.events.on_robot_built_entity, entity = e,
                                                         tick = game.tick})
  local after = economy.network(F).get_item_count("rts-smelter")
  check("robot_refused", e ~= nil and not e.valid and after == before + 1,
    "smelter at %s: removed=%s, pool %d -> %d", util.pos_str(pos), tostring(e and not e.valid), before, after)
end

local function spawn_group(near, n)
  local list = {}
  for i = 1, n do
    local p = surface().find_non_colliding_position("rts-walker", {near.x + (i % 3) * 3, near.y + math.floor(i / 3) * 3},
      12, 0.5)
    local e = p and units.spawn("rts-walker", p, F, "walker", surface())
    if e then list[#list + 1] = e.unit_number end
  end
  return list
end

local function group_loss(list)
  local losses, dealt = {}, {}
  local A = storage.territory.attrition
  for _, un in ipairs(list) do
    local rec = units.get(un)
    if rec then
      local e = rec.entity
      losses[#losses + 1] = (e.max_health - e.health) / e.max_health
      dealt[#dealt + 1] = (A.dealt[un] or 0) / e.max_health
    else
      losses[#losses + 1] = 1
      dealt[#dealt + 1] = (A.dealt[un] or 0) / 200
    end
  end
  return losses, dealt
end

local function fmt(list)
  local t = {}
  for i, v in ipairs(list) do t[i] = string.format("%.1f%%", v * 100) end
  return table.concat(t, " ")
end

events.on_nth_tick(30, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started and territory.nation()) then return end
  local S = P()
  if S.done then return end
  local age = game.tick - m.tick_started
  if not S.setup and age >= 120 then
    S.setup = game.tick
    ai.stop_force(F)
    ai.stop_force(E)
    territory.flush()
    local own_c, enemy_c = capital(F), capital(E)
    local n, valid = territory.object_count()
    check("grid_ready", own_c ~= nil and enemy_c ~= nil and own_c.tier == 2 and enemy_c.tier == 2
      and own_c.radius == 96 and enemy_c.radius == 96
      and territory.owner_at(own_c.position) == F and territory.owner_at(enemy_c.position) == E and valid > 0,
      "capitals %s / %s, owners %s / %s, cells %d / %d, share %.3f / %.3f, objects %d (valid %d)",
      own_c and ("#" .. own_c.id .. " tier " .. own_c.tier) or "-", enemy_c and ("#" .. enemy_c.id) or "-",
      tostring(own_c and territory.owner_at(own_c.position)), tostring(enemy_c and territory.owner_at(enemy_c.position)),
      territory.cells(F), territory.cells(E), territory.share(F), territory.share(E), n, valid)
    place_table(S)
    -- attrition groups (cease-fire: no combat, only attrition)
    game.forces[F].set_cease_fire(E, true)
    game.forces[E].set_cease_fire(F, true)
    local inside = enemy_c.radius - 40 -- 40 tiles inside the AI's land
    local deep = {x = enemy_c.position.x, y = enemy_c.position.y - inside}
    local near_hub = {x = enemy_c.position.x, y = enemy_c.position.y + inside}
    local hub_pos = spot("rts-hub", {x = near_hub.x + 8, y = near_hub.y}, 10)
    local hub = surface().create_entity({name = "rts-hub", position = hub_pos, force = F, raise_built = true})
    S.group_a = spawn_group(deep, 6)
    S.group_b = spawn_group(near_hub, 6)
    S.att_start = game.tick
    util.log("territory autotest: attrition groups A %d at %s (owner %s, %.0f tiles from the AI capital), B %d at %s "
      .. "next to hub %s (owner %s)", #S.group_a, util.pos_str(deep), tostring(territory.owner_at(deep)),
      util.distance(deep, enemy_c.position), #S.group_b, util.pos_str(near_hub), hub and ("#" .. hub.unit_number) or "-",
      tostring(territory.owner_at(near_hub)))
    -- founding 300 tiles out
    local dir = {x = enemy_c.position.x - own_c.position.x, y = enemy_c.position.y - own_c.position.y}
    local len = math.sqrt(dir.x * dir.x + dir.y * dir.y)
    local want = {x = own_c.position.x + dir.x / len * FAR, y = own_c.position.y + dir.y / len * FAR}
    local site = spot("rts-city-center", want, 20)
    S.site = site
    S.supply_before = supply.cap(F)
    commander.enable(F)
    local cmd = commander.spawn_now(F)
    local ghost = site and surface().create_entity({name = "entity-ghost", inner_name = "rts-city-center",
                                                    position = site, force = F})
    if ghost then
      events.dispatch(defines.events.on_built_entity, {name = defines.events.on_built_entity, entity = ghost, player_index = 0,
                                                       tick = game.tick})
    end
    economy.give(F, "rts-city-charter", 1)
    if cmd and site then cmd.autopilot_destination = {x = site.x - 6, y = site.y} end
    S.found_start = game.tick
    util.log("territory autotest: city site %s (%.0f tiles from the capital, owner %s), ghost kept %s, Commander %s",
      util.pos_str(site), site and util.distance(site, own_c.position) or -1, tostring(site and territory.owner_at(site)),
      tostring(ghost and ghost.valid), cmd and ("#" .. cmd.unit_number) or "missing")
    return
  end
  if not S.setup then return end
  if S.att_start and not S.att_done and game.tick - S.att_start >= 3600 then
    S.att_done = true
    local la, da = group_loss(S.group_a)
    local lb, db = group_loss(S.group_b)
    local ok_a = #la == 6
    for i, v in ipairs(la) do ok_a = ok_a and v >= 0.15 and v <= 0.25 and math.abs(v - da[i]) < 0.02 end
    local ok_b = #lb == 6
    for _, v in ipairs(lb) do ok_b = ok_b and v == 0 end
    check("attrition_deep", ok_a, "group A HP lost in 60 s [%s], attrition dealt [%s]", fmt(la), fmt(da))
    check("attrition_supplied", ok_b, "group B (next to an own hub) HP lost [%s], attrition dealt [%s]", fmt(lb), fmt(db))
    game.forces[F].set_cease_fire(E, false)
    game.forces[E].set_cease_fire(F, false)
  end
  if S.found_start and not S.found_done then
    local list = cities.for_force(F)
    local waited = (game.tick - S.found_start) / 60
    if #list >= 2 and not S.found_tick then
      S.found_tick = game.tick
      util.log("territory autotest: city founded %.0f s after the start", waited)
    end
    if S.found_tick and territory.pending() == 0 and game.tick - S.found_tick >= 120 then
      S.found_done = true
      local c = list[2]
      local center = c.entity
      local net = center.valid and center.logistic_network
      local cap_net = capital(F).entity.logistic_network
      local entry = logistics.entry_for_hub(c.center)
      local alerts = 0
      for _, a in ipairs(storage.alerts or {}) do
        if a.force == F and a.kind == "city-founded" then alerts = alerts + 1 end
      end
      local ok = c.tier == 1 and c.radius == 48 and territory.owner_at(c.position) == F
        and territory.city_at(c.position) == c.id and territory.city_cells(c.id) > 0
        and net ~= nil and cap_net ~= nil and net.network_id ~= cap_net.network_id and entry ~= nil
        and c.power and c.power.valid and supply.cap(F) == S.supply_before + 10 and alerts >= 1
      check("found_far", ok, "city %d %s at %s (%.0f tiles from the capital) after %.0f s: tier %d radius %d owner %s "
        .. "city_at %s cells %d network %s (capital %s, entry %s) power %s supply %d -> %d alerts %d, name %s",
        c.id, c.entity.name, util.pos_str(c.position), util.distance(c.position, capital(F).position),
        (S.found_tick - S.found_start) / 60, c.tier, c.radius, tostring(territory.owner_at(c.position)),
        tostring(territory.city_at(c.position)), territory.city_cells(c.id), net and net.network_id or "-",
        cap_net and cap_net.network_id or "-", entry and #entry.hubs or "-", tostring(c.power and c.power.valid),
        S.supply_before, supply.cap(F), alerts, logistics.hub_name(c.center)[1] or "?")
      -- make targets
      for i = #signals, 1, -1 do signals[i] = nil end
      local set_ok = cities.set_make_target(c.id, "iron-gear-wheel", 50)
      local read = cities.make_targets(c.id)["iron-gear-wheel"]
      cities.set_make_target(c.id, "iron-gear-wheel", 0)
      local cleared = cities.make_targets(c.id)["iron-gear-wheel"] == nil
      check("make_targets", set_ok and read == 50 and cleared and #signals == 2 and signals[1].n == 50,
        "set %s, read %s, cleared %s, signals %d", tostring(set_ok), tostring(read), tostring(cleared), #signals)
      -- tier-up: buildings on its land and goods into its market
      S.city = c.id
      S.city_cells0 = territory.city_cells(c.id)
      local placed = 0
      for i = 1, 10 do
        local a = (i - 1) * math.pi / 5
        local pos = spot("rts-solar-array", {x = c.position.x + math.cos(a) * 24, y = c.position.y + math.sin(a) * 24}, 8)
        if pos and surface().create_entity({name = "rts-solar-array", position = pos, force = F, raise_built = true}) then
          placed = placed + 1
        end
      end
      local net = c.entity.logistic_network
      S.tier_start = game.tick
      S.tier_inserted = 0
      S.tier_placed = placed
      util.log("territory autotest: tier-up setup: %d solar arrays placed, market total now %s", placed,
        tostring(c.last_total))
    elseif waited >= 120 and not S.found_tick then
      S.found_done = true
      local cmd = commander.entity(F)
      check("found_far", false, "no second city after %.0f s; Commander at %s, ghosts near the site %d", waited,
        cmd and util.pos_str(cmd.position) or "-",
        S.site and surface().count_entities_filtered({position = S.site, radius = 4, type = "entity-ghost"}) or -1)
    end
  end
  if S.tier_start and not S.tier_done then
    local c = cities.get(S.city)
    -- the market's first sample must exist before the delivery counts (cities.check every 600 ticks)
    if c and c.last_total and S.tier_inserted == 0 then
      local net = c.entity.logistic_network
      S.tier_inserted = net and net.insert({name = "iron-plate", count = 500}) or 0
      util.log("territory autotest: tier-up: %d iron inserted into the market (sampled total %d)", S.tier_inserted,
        c.last_total)
    end
    if c and c.tier >= 2 and territory.pending() == 0 then
      S.tier_done = true
      check("tier_up", c.radius == 72 and territory.city_cells(c.id) > S.city_cells0, "city %d tier %d radius %d after %.0f s "
        .. "(%d buildings, %d delivered), cells %d -> %d", c.id, c.tier, c.radius, (game.tick - S.tier_start) / 60,
        c.buildings, c.delivered, S.city_cells0, territory.city_cells(c.id))
    elseif game.tick - S.tier_start > 40 * 60 then
      S.tier_done = true
      check("tier_up", false, "city %s tier %s after 40 s: buildings %s delivered %s (placed %d, inserted %d)",
        tostring(S.city), c and c.tier or "-", c and c.buildings or "-", c and c.delivered or "-", S.tier_placed,
        S.tier_inserted)
    end
  end
  if S.tier_done and not S.lost_start then
    local c = cities.get(S.city)
    S.lost_start = game.tick
    S.lost_pos = c and c.position
    S.alerts_before = #(storage.alerts or {})
    S.supply_lost_before = supply.cap(F)
    if c and c.entity.valid then c.entity.die() end
  end
  if S.lost_start and not S.lost_done and territory.pending() == 0 and game.tick - S.lost_start >= 60 then
    S.lost_done = true
    local kinds = {}
    for i = S.alerts_before + 1, #(storage.alerts or {}) do
      local a = storage.alerts[i]
      if a.force == F then kinds[a.kind] = (kinds[a.kind] or 0) + 1 end
    end
    local gone = cities.get(S.city) == nil
    local owner = S.lost_pos and territory.owner_at(S.lost_pos)
    check("city_lost", gone and owner == nil and (kinds["city-lost"] or 0) == 1 and (kinds["territory-lost"] or 0) == 1
      and supply.cap(F) == S.supply_before, "city %d gone %s, land at its centre owned by %s, alerts %s, supply %d -> %d "
      .. "(before founding %d)", S.city or -1, tostring(gone), tostring(owner), serpent.line(kinds), S.supply_lost_before,
      supply.cap(F), S.supply_before)
  end
  if S.att_done and S.found_done and (S.lost_done or not S.tier_start) then
    S.done = true
    local T = storage.territory
    local n, valid = territory.object_count()
    util.log("territory autotest: grid %dx%d, jobs %d, cells %d, segments %d, objects %d (valid %d), checksum %d, "
      .. "attrition passes %d hits %d", T.w, T.h, T.stats.jobs, T.stats.cells, T.stats.segments, n, valid,
      territory.checksum(), T.attrition.passes, T.attrition.hits)
    util.log("territory autotest summary %d/%d (%s)", S.pass, S.pass + S.fail, S.fail == 0 and "all passed" or "FAILED")
  end
end)
