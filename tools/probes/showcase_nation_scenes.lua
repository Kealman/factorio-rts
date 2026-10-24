-- Showcase (release media), Nation scenes: the shoot phase of tools/probes/showcase_nation.lua, played on the baked
-- save (tools/showcase.sh nation). The AI built the capital, its towns, lines and haulers during the bake; this file
-- stops the AI of the player's nation and stages the rest with the module calls behind the QA shortcuts (/rts-give,
-- /rts-spawn, /rts-research, /rts-age, /rts-front, /rts-market). Scene order matters: the war and the front town come
-- before the military scenes, the Space Program (Age III) before the air scene, and the diplomacy panel's peace offer
-- last. Staging beyond the shortcuts (all logged "[rts] showcase: ..."): the army that idles around the capital is
-- moved out of the capital's frame, every network of the nation gets 200 coal (the baked haulers ran dry), a standing
-- freight train is sent on, the front town of AI 1 gets a few buildings, and calm shots drop stale alerts.
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local cities = require("scripts.cities")
local ages = require("scripts.ages")
local rails = require("scripts.rails")
local economy = require("scripts.economy")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local logistics = require("scripts.logistics")
local territory = require("scripts.territory")
local market = require("scripts.market")
local marketgui = require("scripts.marketgui")
local ledgergui = require("scripts.ledgergui")
local diplomacy = require("scripts.diplomacy")
local diplomacygui = require("scripts.diplomacygui")
local wars = require("scripts.wars")
local age3 = require("scripts.age3")
local air = require("scripts.air")
local fronts = require("scripts.fronts")
local belts = require("scripts.belts")
local trainswar = require("scripts.trainswar")
local ai = require("scripts.ai.init")
local production = require("scripts.production")
local commander = require("scripts.commander")
local balance = require("balance")
local lib = require("scripts.showcase_lib")

local F, E1 = "rts-player", "rts-ai-1"
local step, scene, capture = lib.step, lib.scene, lib.capture
local W, H = lib.W, lib.H

local function surface() return match.surface() end
local function px_per_tile(zoom) return 32 * zoom end
local function norm(v)
  local l = math.sqrt(v.x * v.x + v.y * v.y)
  if l < 1e-6 then return {x = 1, y = 0} end
  return {x = v.x / l, y = v.y / l}
end
local function add(a, v, k) return {x = a.x + v.x * k, y = a.y + v.y * k} end
local function mid(a, b) return {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2} end
local function chunk_ok(s, p) return s.is_chunk_generated({math.floor(p.x / 32), math.floor(p.y / 32)}) end

--- Camera so that world point `pos` appears at game-area pixel (sx, sy).
local function view_at(player, pos, sx, sy, zoom)
  local k = px_per_tile(zoom)
  lib.view(player, {x = pos.x - (sx - W / 2) / k, y = pos.y - (sy - H / 2) / k}, zoom)
end

--- Camera and zoom that fit world points a and b inside the screen rectangle r = {x1, y1, x2, y2} (game pixels).
local function fit(player, a, b, r, max_zoom)
  local dx, dy = math.abs(a.x - b.x) + 16, math.abs(a.y - b.y) + 16
  local zoom = math.min((r[3] - r[1]) / dx, (r[4] - r[2]) / dy) / 32
  zoom = math.min(zoom, max_zoom or 0.6)
  view_at(player, mid(a, b), (r[1] + r[3]) / 2, (r[2] + r[4]) / 2, zoom)
  return zoom
end

local function give(list)
  for item, n in pairs(list) do economy.give(F, item, n) end
end

local function net_insert(net, list)
  if not net then return end
  for item, n in pairs(list) do
    local got = net.insert({name = item, count = n})
    if got < n then lib.log("net_insert %s: %d of %d", item, got, n) end
  end
end

local BLOCKERS = {"assembling-machine", "furnace", "container", "roboport", "turret", "ammo-turret", "electric-turret",
  "lab", "mining-drill", "wall", "radar", "rail-signal", "straight-rail", "curved-rail-a", "curved-rail-b",
  "half-diagonal-rail", "solar-panel", "accumulator", "electric-pole", "inserter", "transport-belt", "simple-entity",
  "cliff", "logistic-container", "generator", "boiler", "reactor", "train-stop", "locomotive", "cargo-wagon",
  "artillery-turret", "spider-unit", "unit", "spider-vehicle", "tree"}
--- Bare land around `p`: water, rock and marsh tiles plus blocking entities (trees count) within r; lower is better.
local function clutter(s, p, r)
  local area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}}
  local water = s.count_tiles_filtered({area = area, collision_mask = "water_tile"})
  local rock = s.count_tiles_filtered({area = area, name = {"rts-mountain", "rts-marsh"}})
  local trees = s.count_entities_filtered({area = area, type = "tree"})
  local blocked = s.count_entities_filtered({area = area, type = BLOCKERS}) - trees
  return water + rock + blocked * 6 + trees
end

local function status(tag)
  local parts = {}
  for _, f in ipairs(match.forces()) do
    local open = 0
    for _, l in ipairs(rails.lines_of(f)) do if l.state == "open" then open = open + 1 end end
    parts[#parts + 1] = string.format("%s age %d cities %d lines %d trains %d haulers %d army %d war %s", f, ages.of(f),
      #cities.for_force(f), open, #rails.trains_of(f), units.count(f, "hauler"), units.count(f) - units.count(f, "hauler"),
      f ~= F and tostring(diplomacy.state(F, f)) or "-")
  end
  lib.log("status %s tick %d minute %.1f: %s", tag, game.tick, (game.tick - (storage.match.tick_started or 0)) / 3600,
    table.concat(parts, " | "))
end

--- A calm capture: stale alerts and the kill feed go, then the window grab.
local function calm(name, wait)
  step(function(player, P)
    lib.clean_hud(player, true)
    return 2
  end)
  capture(name, wait)
end

--- The site of the front town: AI 1's land must touch ours (a town claims 72 tiles: a front of about 80 tiles), its
--- centre 46-66 tiles beyond our border (out of reach of a division holding the line), east or west of the city (the wide screen frames the train and the town), on bare
--- land; the capital's border first. Pure search: nothing is placed.
local function front_site(P)
  local s = surface()
  local fail = {chunk = 0, land = 0, place = 0, limit = 0}
  local best, bs, bcity
  for _, city in ipairs(cities.for_force(F)) do
    local R = cities.radius_of(city.tier, city.capital)
    local c = city.position
    for _, extra in ipairs({46, 52, 58, 66}) do
      local d = R + extra
      for k = 0, 23 do
        local a = k * math.pi / 12
        local p = {x = math.floor(c.x + math.cos(a) * d) + 0.0, y = math.floor(c.y + math.sin(a) * d) + 0.0}
        -- AI 1 may already have its 4 cities (the per-nation limit): the staged town is founded anyway (cities.found
        -- has no limit; only the land and the 96-tile spacing must hold)
        local land_ok, why = territory.can_build(E1, cities.CENTER, p)
        if why == "limit" then
          land_ok = true
          fail.limit = fail.limit + 1
        end
        if not chunk_ok(s, p) then
          fail.chunk = fail.chunk + 1
        elseif not land_ok then
          fail.land = fail.land + 1
        elseif not s.can_place_entity({name = cities.CENTER, position = p, force = E1,
                                       build_check_type = defines.build_check_type.manual_ghost, forced = true}) then
          fail.place = fail.place + 1
        else
          local back = norm({x = c.x - p.x, y = c.y - p.y})
          local score = clutter(s, p, 20) + clutter(s, add(p, back, 60), 28) + extra
            + math.floor(80 * math.abs(math.sin(a))) + (city.capital and 0 or 150) + math.floor(lib.dist(p, P.home) / 4)
          if not bs or score < bs then best, bs, bcity = p, score, city end
        end
      end
    end
  end
  lib.log("front site search: %s; best %s near %s (score %s)", serpent.line(fail), best and util.pos_str(best) or "-",
    bcity and tostring(bcity.id) or "-", tostring(bs))
  return best, bcity
end

local function front_town(P)
  if not P.site then return nil end
  local s = surface()
  lib.clear(s, P.site, 30)
  local id = cities.found(E1, P.site, {why = "(showcase /rts-front)", tier = 2})
  territory.flush()
  if fronts.flush then fronts.flush() end
  lib.log("front town %s of %s at %s (%.0f tiles from the capital)", tostring(id), E1, util.pos_str(P.site),
    lib.dist(P.site, P.home))
  return id and {id = id, pos = P.site, near = P.site_city.position} or nil
end

local function dress_town(P)
  local s = surface()
  local c = P.town.pos
  local toward = norm({x = P.town.near.x - c.x, y = P.town.near.y - c.y}) -- towards our city
  local side = {x = -toward.y, y = toward.x}
  local made = 0
  local function put(name, at)
    local e = lib.place(s, name, at, E1, 6)
    if e then
      made = made + 1
      if e.type == "ammo-turret" then e.insert({name = "firearm-magazine", count = 30}) end
    end
    return e
  end
  -- a compact town around its centre; the turrets 30+ tiles from the border, out of a holding division's reach
  for _, k in ipairs({-9, 9}) do put("rts-turret", add(add(c, toward, 6), side, k)) end
  put("rts-turret", add(c, toward, -9))
  for _, k in ipairs({-12, -7, 7, 12}) do put("rts-house", add(add(c, toward, 0), side, k)) end
  for _, k in ipairs({-5, 5}) do put("rts-house", add(add(c, toward, -6), side, k)) end
  put("rts-barracks", add(add(c, toward, -14), side, -6))
  put("rts-farm", add(add(c, toward, -14), side, 8))
  put("rts-radar", add(add(c, toward, 6), side, 15))
  lib.log("front town dressed: %d buildings", made)
end

---------------------------------------------------------------------------
-- Setup (always)
---------------------------------------------------------------------------
step(function(player, P)
  game.speed = 1
  local s = surface()
  local cc = buildings.main_cc(F)
  P.home = {x = cc.entity.position.x, y = cc.entity.position.y}
  P.cap = storage.nations[F].capital
  ai.stop_force(F) -- the staging takes over; haulers and trains keep their routes, buildings keep working
  lib.quiet_alerts(player)
  -- the Commander sits the staged fights out at the capital (an enemy bomber killed it in an early run: "Down" on the bar)
  local cmdr = commander.entity(F)
  if cmdr and cmdr.valid then cmdr.destructible = false end
  lib.close_panels(player)
  lib.park_mouse()
  -- coal for every network of the nation: the baked haulers waited for it ("no fuel at ...")
  local n = 0
  for _, net in pairs(game.forces[F].logistic_networks[s.name] or {}) do
    if net.valid and #net.storages > 0 then
      net.insert({name = "coal", count = 200})
      n = n + 1
    end
  end
  -- ghosts the AI planned and never built (60 game minutes old) go: the map showed their construction alerts
  local ghosts = 0
  for _, g in ipairs(s.find_entities_filtered({force = F, type = {"entity-ghost", "tile-ghost"}})) do
    if g.valid then
      g.destroy()
      ghosts = ghosts + 1
    end
  end
  lib.log("%d stale ghosts of %s removed", ghosts, F)
  -- AI 2's war on AI 1 ends (white peace and its truce): its armies would march across our land to the front town
  local W2 = wars.between("rts-ai-2", E1)
  if W2 and W2.status ~= "ended" then lib.log("AI 2 - AI 1 war #%d ended: %s", W2.id, tostring(wars.end_war(W2.id))) end
  P.site, P.site_city = front_site(P)
  -- the army idling around the capital leaves the capital's frame (a parking field 160-200 tiles out, away from the
  -- front site)
  local army = {}
  for _, rec in units.for_force(F) do
    local e = rec.entity
    if e.valid and rec.kind ~= "hauler" and rec.kind ~= "commander" and not air.is_plane(e)
        and lib.dist(e.position, P.home) < 110 then
      army[#army + 1] = e
    end
  end
  local best, bs
  for _, d in ipairs({165, 195}) do
    for k = 0, 11 do
      local a = k * math.pi / 6
      local p = {x = math.floor(P.home.x + math.cos(a) * d), y = math.floor(P.home.y + math.sin(a) * d)}
      local owner = territory.owner_at(p)
      if chunk_ok(s, p) and (owner == nil or owner == F) and (not P.site or lib.dist(p, P.site) > 220) then
        local sc = clutter(s, p, 24)
        if not bs or sc < bs then best, bs = p, sc end
      end
    end
  end
  P.park = best
  -- the nation's barracks pause (Auto off, no recipe): new units would walk to the rally points in the capital's frame
  local paused = 0
  for un, rec in buildings.for_force(F, "barracks") do
    local id = type(un) == "number" and un or (rec and rec.entity and rec.entity.unit_number)
    if id then
      production.set_auto(id, false)
      if production.set_recipe(id, nil) then paused = paused + 1 end
    end
  end
  lib.log("%d barracks paused", paused)
  if best then
    for i, e in ipairs(army) do
      local p = {x = best.x + ((i - 1) % 12 - 5.5) * 4, y = best.y + (math.floor((i - 1) / 12) - 3) * 4}
      local q = s.find_non_colliding_position(e.name, p, 12, 0.5) or p
      e.teleport(q)
    end
  end
  lib.view(player, P.home, 0.5)
  status("shoot")
  local c = cities.get(P.cap)
  lib.log("capital %s tier %s; coal into %d networks; %d army units parked at %s", util.pos_str(P.home),
    tostring(c and c.tier), n, #army, best and util.pos_str(best) or "-")
  for _, city in ipairs(cities.for_force(F)) do
    lib.log("city %s tier %s at %s (%.0f tiles)", tostring(city.id), tostring(city.tier), util.pos_str(city.position),
      lib.dist(city.position, P.home))
  end
  return 120
end)

---------------------------------------------------------------------------
-- 02: the capital (a city) with its districts, hub and haulers on the move
---------------------------------------------------------------------------
scene("02-capital", function()
  step(function(player, P)
    local s = surface()
    local list = {}
    for _, e in ipairs(s.find_entities_filtered({position = P.home, radius = 100, force = F})) do
      if string.sub(e.name, 1, 13) == "rts-district-" or e.name == "rts-hub" or e.name == "rts-depot" then
        list[#list + 1] = e
      end
    end
    local c = lib.centroid(list)
    P.cap_view = c and {x = (P.home.x * 2 + c.x) / 3, y = (P.home.y * 2 + c.y) / 3} or P.home
    lib.log("02: %d districts/hubs/depots around the capital, view %s", #list, util.pos_str(P.cap_view))
    lib.view(player, P.cap_view, 0.52)
    P.hpos = {}
    return 120
  end)
  -- a hauler that moved in the last half second, inside the frame
  lib.wait_until("hauler moving in view", function(player, P)
    local hx, hy = W / 2 / px_per_tile(0.52) - 6, H / 2 / px_per_tile(0.52) - 8
    local found = false
    for _, rec in units.for_force(F) do
      local e = rec.entity
      if rec.kind == "hauler" and e.valid then
        local un, p = e.unit_number, e.position
        local last = P.hpos[un]
        if last and lib.dist(last, p) > 1 and math.abs(p.x - P.cap_view.x) < hx and math.abs(p.y - P.cap_view.y) < hy then
          found = true
        end
        P.hpos[un] = {x = p.x, y = p.y}
      end
    end
    return found
  end, 30, 60 * 75)
  calm("02-capital", 60)
end)

---------------------------------------------------------------------------
-- 03: a depot and a freight train leaving on an open line between the capital and a town
---------------------------------------------------------------------------
scene("03-rail-line", function()
  step(function(player, P)
    -- the open line with the depot nearest to the capital
    local best, bd, other
    for _, l in ipairs(rails.lines_of(F)) do
      if l.state == "open" then
        for _, pair in ipairs({{l.a, l.b}, {l.b, l.a}}) do
          local d = rails.depot(pair[1])
          if d and d.entity and d.entity.valid and rails.depot(pair[2]) then
            local dist = lib.dist(d.entity.position, P.home)
            if not bd or dist < bd then best, bd, other = d, dist, pair[2] end
          end
        end
      end
    end
    if not best then lib.log("03: no open line") return 1 end
    P.rdepot, P.rother = best.entity, other
    local here = best.entity.unit_number
    -- a cargo train standing near that depot is sent to the line's other end; else a new one is deployed there
    local train
    for _, rec in ipairs(rails.trains_of(F)) do
      local t = rec.kind == "cargo" and rails.train_of(rec)
      if t and t.valid and math.abs(t.speed) < 0.01 and lib.dist(t.front_stock.position, best.entity.position) < 40 then
        train = t
      end
    end
    if not train then
      net_insert(logistics.hub_network(here), {[rails.LOCO_KIT] = 2, [rails.WAGON_KIT] = 2, coal = 60})
      local why
      train, why = rails.create_train(here, "cargo")
      lib.log("03: deployed a freight train: %s %s", tostring(train and train.id), tostring(why))
    end
    if train and train.valid then
      local loaded = next(rails.cargo_of(train)) ~= nil
      local ok = loaded and rails.set_route(train, here, other) or rails.set_route(train, other, here)
      lib.log("03: train %d (%s) leaves depot #%d for depot #%d: %s", train.id, loaded and "loaded" or "empty", here,
        other, tostring(ok))
      P.rtrain = train
    end
    lib.view(player, best.entity.position, 0.45)
    return 30
  end)
  lib.wait_until("freight train leaving the depot", function(player, P)
    local t = P.rtrain
    if not (t and t.valid and P.rdepot and P.rdepot.valid) then return true end
    local d = math.min(lib.dist(t.front_stock.position, P.rdepot.position), lib.dist(t.back_stock.position,
      P.rdepot.position))
    return math.abs(t.speed) > 0.15 and d > 22 and d < 40
  end, 2, 60 * 120)
  step(function(player, P)
    local t = P.rtrain
    if not (t and t.valid and P.rdepot and P.rdepot.valid) then return 1 end
    P.speed_before = game.speed
    game.speed = lib.cfg.freeze_speed or 0.1
    lib.clean_hud(player, true)
    -- the whole consist in the middle of the frame (below the strip), the depot beside it
    local tm = mid(t.front_stock.position, t.back_stock.position)
    lib.view(player, {x = tm.x * 0.8 + P.rdepot.position.x * 0.2, y = tm.y * 0.8 + P.rdepot.position.y * 0.2 - 2}, 0.58)
    return 6
  end)
  step(function(player, P)
    if not P.speed_before then return 1 end
    lib.capture_now(player, "03-rail-line")
    return 8
  end)
  step(function(player, P)
    if P.speed_before then lib.unfreeze(P) end
    return 30
  end)
end)

---------------------------------------------------------------------------
-- 15: the city panel of the capital (people, workforce, make targets), districts around it
---------------------------------------------------------------------------
scene("15-city-panel", function()
  step(function(player, P)
    -- five make targets (the AI's governor left a dozen; the panel would run off the screen)
    local cur = cities.make_targets(P.cap) or {}
    local keep = {["steel-plate"] = 200, ["engine-unit"] = 40, ["rts-rations"] = 150, ["advanced-circuit"] = 60,
                  ["concrete"] = 100}
    for item in pairs(cur) do
      if not keep[item] then cities.set_make_target(P.cap, item, nil) end
    end
    for item, n in pairs(keep) do cities.set_make_target(P.cap, item, n) end
    -- the city in the left-middle of the frame, the two panels on the right
    local c = P.cap_view or P.home
    lib.view(player, {x = c.x + 9, y = c.y + 2}, 0.5)
    selection.select_building(player.index, buildings.main_cc(F).entity.unit_number)
    return 150
  end)
  calm("15-city-panel", 60)
  step(function(player, P) lib.close_panels(player) return 30 end)
end)

---------------------------------------------------------------------------
-- 11: the market: prices with sparklines, an own port and a city-state as trade partner
---------------------------------------------------------------------------
scene("11-market", function()
  step(function(player, P)
    if #market.ports(F) == 0 then
      local best, bd
      for _, p in ipairs(market.all_ports()) do
        local d = lib.dist(p.entity.position, P.home)
        if not bd or d < bd then best, bd = p, d end
      end
      if best then
        market.set_owner(best.un, F) -- the QA shortcut /rts-market capture N
        lib.log("11: port %d at %s taken (%d tiles)", best.un, util.pos_str(best.entity.position), bd)
      end
    end
    -- the contract list: finished contracts of the baked match go, an active one with AI 2 (at peace) comes in
    local MS = storage.market
    if MS and MS.contracts then
      for id, c in pairs(MS.contracts) do
        if (c.seller == F or c.buyer == F) and c.state ~= "active" then MS.contracts[id] = nil end
      end
    end
    local cid, why = market.contract(F, "rts-ai-2", "steel-plate", 100, 6, 120, 3.4)
    lib.log("11: contract with rts-ai-2: %s %s", tostring(cid), tostring(why))
    lib.view(player, P.cap_view or P.home, 0.5)
    marketgui.open(player)
    return 60
  end)
  calm("alt-11-market-port", 40)
  step(function(player, P)
    local ps = util.pstorage(player.index).market_gui
    local g = ps and ps.gui
    if g and g.port_dd and g.port_dd.valid then
      local n_ports = #(g.ports or {})
      if #g.port_dd.items > n_ports then
        g.port_dd.selected_index = n_ports + 1
        events.dispatch(defines.events.on_gui_selection_state_changed, {element = g.port_dd,
          player_index = player.index, name = defines.events.on_gui_selection_state_changed})
      end
    end
    return 60
  end)
  calm("11-market", 60)
  step(function(player, P) lib.close_panels(player) return 30 end)
end)

---------------------------------------------------------------------------
-- 08: the Space Program: stage 1 delivered (Age III), stage 2 in progress, the ledger open
---------------------------------------------------------------------------
scene("08-space-program", function()
  step(function(player, P)
    if ages.of(F) < 2 then ages.set_age(F, 2, "showcase /rts-age") end
    lib.research(F, {"rts-industrialisation", "rts-electrification"})
    local Pj = age3.project(F)
    if not (Pj and Pj.site and Pj.site.valid) then
      local res, why = age3.start(F, age3.site_position(F))
      lib.log("08: start: %s %s", tostring(res ~= nil), tostring(why))
    end
    if ages.of(F) < 3 then give({["steel-plate"] = 200, concrete = 100, ["advanced-circuit"] = 60}) end
    return 60
  end)
  lib.wait_until("age 3", function() return ages.of(F) >= 3 end, 60, 60 * 150)
  step(function(player, P)
    local Pj = age3.project(F)
    -- stage 2 about two thirds delivered
    if Pj and Pj.stage == 2 then
      local want = {["processing-unit"] = 24, battery = 62, ["engine-unit"] = 50}
      for item, n in pairs(want) do
        local have = (Pj.delivered[item] or 0)
        if have < n then economy.give(F, item, n - have) end
      end
    end
    return 60 * 10
  end)
  step(function(player, P)
    local Pj = age3.project(F)
    P.complex = Pj and Pj.position
    lib.log("08: %s", age3.describe(F))
    -- the complex right of the ledger, left of the minimap column
    view_at(player, P.complex or P.home, 1590, 610, 0.9)
    ledgergui.open(player)
    return 120
  end)
  calm("08-space-program", 60)
  step(function(player, P) lib.close_panels(player) return 30 end)
end)

---------------------------------------------------------------------------
-- War on AI 1 and a town of AI 1 next to our land (/rts-front), dressed as a small town
---------------------------------------------------------------------------
local MILITARY = {"04-division-battle", "05-front-fort-belt", "06-air", "07-artillery-train", "09-strategic-map",
                  "10-diplomacy"}
step(function(player, P)
  local need = false
  for _, n in ipairs(MILITARY) do if lib.wanted(n) then need = true end end
  if not need then return 1 end
  if diplomacy.state(F, E1) ~= "war" then
    local id, why = wars.declare(F, E1)
    lib.log("war on %s: %s %s", E1, tostring(id), tostring(why))
  end
  P.town = front_town(P)
  if P.town then dress_town(P) end
  return 300
end)
step(function(player, P)
  if not P.town then return 1 end
  if fronts.flush then fronts.flush() end
  P.seg = fronts.nearest(F, P.town.pos, 400)
  lib.log("front: %s; nearest %s", fronts.describe(F), P.seg and string.format("#%d mid %s chord %.0f back (%.2f, %.2f)",
    P.seg.id, util.pos_str(P.seg.mid), P.seg.chord or -1, P.seg.back.x, P.seg.back.y) or "none")
  return 30
end)

---------------------------------------------------------------------------
-- 07: an artillery train in Bombard, shells landing on the enemy town
---------------------------------------------------------------------------
scene("07-artillery-train", function()
  step(function(player, P)
    if not (P.seg and P.town) then lib.log("07: no front") return 1 end
    local s = surface()
    lib.research(F, {"rts-railways", "rts-military-railways"})
    local want = add(P.seg.mid, P.seg.back, 12)
    P.adepot = lib.place(s, "rts-depot", want, F, 16)
    lib.log("07: depot %s", P.adepot and util.pos_str(P.adepot.position) or "FAILED")
    return 120
  end)
  lib.wait_until("depot platform", function(player, P)
    local d = P.adepot and P.adepot.valid and rails.depot(P.adepot.unit_number)
    return not P.adepot or (d and d.platform ~= nil)
  end, 30, 60 * 30)
  step(function(player, P)
    if not (P.adepot and P.adepot.valid) then return 1 end
    local s = surface()
    local un = P.adepot.unit_number
    net_insert(logistics.hub_network(un), {[rails.ALOCO_KIT] = 2, [rails.ARTY_KIT] = 1, [trainswar.SHELL] = 40,
                                           coal = 100})
    local toward = norm({x = P.town.pos.x - P.adepot.position.x, y = P.town.pos.y - P.adepot.position.y})
    lib.place(s, "rts-radar", add(P.adepot.position, {x = -toward.y, y = toward.x}, 7), F, 5)
    local train, why = trainswar.deploy(un, "artillery", true)
    local rec = train and rails.train_record(train)
    P.atrain = train
    P.atrain_id = rec and rec.id
    local ok, why2 = false, nil
    if P.atrain_id then ok, why2 = trainswar.set_stance(P.atrain_id, "bombard") end
    lib.log("07: artillery train %s (%s), bombard %s %s", tostring(P.atrain_id), tostring(why), tostring(ok),
      tostring(why2))
    lib.clean_hud(player, true)
    if train and train.valid then
      selection.select_building(player.index, train.front_stock.unit_number)
      -- the train and the town inside the free part of the screen (the train panel sits at the top right)
      fit(player, mid(train.front_stock.position, train.back_stock.position), P.town.pos, {330, 170, 1500, 920}, 0.75)
    end
    lib.reveal(F, s, P.town.pos, 60)
    P.shells_live, P.impacts = 0, 0
    P.a_t0 = game.tick
    return 1
  end)
  -- watch the shells: capture the tick after the second impact
  step(function(player, P)
    if not P.atrain_id then return 1 end
    local s = surface()
    local live = s.count_entities_filtered({name = trainswar.PROJECTILE})
    if live < (P.shells_live or 0) then
      P.impacts = P.impacts + (P.shells_live - live)
      lib.log("07: impact %d at tick %d", P.impacts, game.tick)
      if P.impacts >= 2 then
        P.shells_live = live
        lib.reveal(F, s, P.town.pos, 60)
        -- the next shell leaves now (the Bombard shot, fired early) and is in the air while this one bursts
        local fired = trainswar.fire(P.atrain_id)
        P.speed_before = game.speed
        game.speed = lib.cfg.freeze_speed or 0.1
        lib.log("07: extra shell %s", tostring(fired))
        return 12
      end
    end
    P.shells_live = live
    if game.tick - P.a_t0 > 60 * 70 then
      lib.log("07: TIMEOUT, %d impacts; %s", P.impacts, trainswar.describe(F))
      return 1
    end
    P.i = P.i - 1
    return 1
  end)
  step(function(player, P)
    if P.speed_before then lib.capture_now(player, "07-artillery-train") end
    return 10
  end)
  step(function(player, P)
    if P.speed_before then lib.unfreeze(P) end
    lib.log("07: %s", trainswar.describe(F))
    -- the train goes back into kits (Disband): it would stand in the fort belt shot
    if P.atrain and P.atrain.valid then
      selection.clear(player.index)
      lib.log("07: disband %s", tostring(rails.disband_train(P.atrain)))
    end
    return 60
  end)
  step(function(player, P) lib.close_panels(player) return 30 end)
end)

---------------------------------------------------------------------------
-- 06: an airfield with scout planes and bombers in the air, an AA turret firing at enemy bombers
---------------------------------------------------------------------------
scene("06-air", function()
  step(function(player, P)
    local s = surface()
    lib.research(F, {"rts-aviation", "rts-air-force"})
    give({["firearm-magazine"] = 300})
    -- the enemy comes from the east or the west (the screen is wide); the airfield stands on the other side
    local east = P.town and P.town.pos.x > P.home.x
    local away = {x = east and -1 or 1, y = 0}
    local field
    for _, f in ipairs(air.airfields(F)) do
      if f.valid and lib.dist(f.position, P.home) < 140 then field = f end
    end
    if not field then
      local best, bs
      for _, d in ipairs({28, 36, 44, 52}) do
        for k = -3, 3 do
          local p = {x = math.floor(P.home.x + away.x * d), y = math.floor(P.home.y + k * 10)}
          if territory.owner_at(p) == F then
            local sc = clutter(s, p, 10) + clutter(s, add(p, away, -24), 14) + d
            if not bs or sc < bs then best, bs = p, sc end
          end
        end
      end
      field = best and lib.place(s, "rts-airfield", best, F, 14)
    end
    P.field = field
    if not field then lib.log("06: no airfield") return 1 end
    local toward = {x = -away.x, y = 0}
    P.aa = lib.place(s, "rts-aa-turret", add(field.position, toward, 8), F, 6)
    if P.aa then P.aa.insert({name = "firearm-magazine", count = 50}) end
    local planes, plane_entities = {}, {}
    for _, spec in ipairs({{"rts-scout-plane", 4}, {"rts-bomber", 3}, {"rts-interceptor", 3}}) do
      for _, e in ipairs(lib.spawn(units, spec[1], spec[2], add(field.position, away, 4), F, 4, 4)) do
        planes[#planes + 1] = e.unit_number
        plane_entities[#plane_entities + 1] = e
      end
    end
    P.planes, P.plane_entities = planes, plane_entities
    local n = air.patrol_units(planes, add(field.position, toward, 2), 7)
    P.toward = toward
    lib.log("06: airfield %s, AA %s, %d planes, %d on patrol", util.pos_str(field.position),
      P.aa and util.pos_str(P.aa.position) or "-", #planes, n)
    -- the airfield on one side, the AA turret near the middle, the bombers come in from the other side (the AA turret
    -- opens fire at 30 tiles: the frame reaches 34 tiles past it)
    view_at(player, P.aa and P.aa.position or field.position, W / 2 + toward.x * 60, H / 2 + 30, 1.6)
    lib.clean_hud(player, true)
    selection.set(player.index, P.plane_entities)
    return 60 * 8
  end)
  step(function(player, P)
    if not (P.field and P.aa) then return 1 end
    local list = lib.spawn(units, "rts-bomber", 3, add(P.aa.position, P.toward, 17), E1, 2, 5)
    local ids = {}
    for _, e in ipairs(list) do ids[#ids + 1] = e end
    orders.attack_move(ids, P.field.position)
    P.enemy_planes = list
    lib.reveal(F, surface(), P.field.position, 70)
    return 30
  end)
  lib.wait_until("AA turret firing", function(player, P)
    if not (P.aa and P.aa.valid) then return true end
    local t = P.aa.shooting_target
    if t and t.valid and air.is_plane(t) and lib.dist(t.position, P.aa.position) < 12 then return true end
  end, 1, 60 * 20)
  step(function(player, P)
    lib.freeze_capture(player, P, "06-air")
    return 10
  end)
  step(function(player, P) lib.unfreeze(P) return 50 end)
  step(function(player, P)
    lib.freeze_capture(player, P, "alt-06-air-b")
    return 10
  end)
  step(function(player, P) lib.unfreeze(P) return 60 end)
end)

---------------------------------------------------------------------------
-- 05: a front segment with a built fort belt and a division holding the line
---------------------------------------------------------------------------
scene("05-front-fort-belt", function()
  step(function(player, P)
    if not P.seg then lib.log("05: no front segment") return 1 end
    lib.research(F, {"rts-fortification"})
    give({["rts-wall"] = 800, ["rts-gate"] = 20, ["rts-turret"] = 40, ["rts-field-depot"] = 3, ["rts-aa-turret"] = 8,
          ["firearm-magazine"] = 800})
    local id, why = belts.plan_front(F, P.seg.id, {behind = 1})
    P.belt = id
    lib.log("05: belt plan %s %s on segment %d", tostring(id), tostring(why), P.seg.id)
    lib.view(player, add(P.seg.mid, P.seg.back, 10), 0.4)
    return 60
  end)
  lib.wait_until("belt built", function(player, P)
    local b = P.belt and belts.get(P.belt)
    return not b or b.state == "built" or b.state == "cancelled"
  end, 60, 60 * 300)
  step(function(player, P)
    if not P.seg then return 1 end
    lib.log("05: %s", belts.describe(F))
    local at = add(P.seg.mid, P.seg.back, 40)
    local list = {}
    for _, spec in ipairs({{"rts-walker-mk2", 14}, {"rts-heavy-mk2", 4}, {"rts-armoured-car", 4}}) do
      for _, e in ipairs(lib.spawn(units, spec[1], spec[2], at, F, 6, 4)) do list[#list + 1] = e end
    end
    P.hold_units = list
    P.hold_div = divisions.create(F, list, nil, {owner = "player"})
    -- staging: the line stands 11 tiles behind the chord (balance 4), behind the wall and its turrets
    local FH = balance.nation.fronts.hold
    local behind = FH.behind
    FH.behind = 11
    local ok, why = divisions.order(P.hold_div, "hold_line", P.seg.id)
    FH.behind = behind
    lib.log("05: division %s (%d units) hold_line: %s %s", tostring(P.hold_div), #list, tostring(ok), tostring(why))
    return 60 * 35
  end)
  step(function(player, P)
    if not P.seg then return 1 end
    local c = add(P.seg.mid, P.seg.back, 7)
    lib.view(player, c, 0.72)
    lib.reveal(F, surface(), c, 110)
    selection.set(player.index, P.hold_units)
    return 120
  end)
  calm("05-front-fort-belt", 60)
  step(function(player, P) lib.close_panels(player) return 30 end)
end)

---------------------------------------------------------------------------
-- 04: a mixed division (walkers, heavies, armoured cars, artillery) against an enemy force, with explosions
---------------------------------------------------------------------------
scene("04-division-battle", function()
  step(function(player, P)
    local s = surface()
    -- open ground 70-120 tiles from the capital, away from the front town and the parked army; armies east-west
    local best, bs
    for _, d in ipairs({70, 85, 100, 120}) do
      for k = 0, 15 do
        local a = k * math.pi / 8
        local p = {x = math.floor(P.home.x + math.cos(a) * d), y = math.floor(P.home.y + math.sin(a) * d)}
        if chunk_ok(s, p) and (not P.town or lib.dist(p, P.town.pos) > 100)
            and (not P.park or lib.dist(p, P.park) > 90) then
          local sc = clutter(s, p, 30)
          if not bs or sc < bs then best, bs = p, sc end
        end
      end
    end
    P.bat = best or add(P.home, {x = 0, y = 1}, 80)
    local dir = {x = P.bat.x >= P.home.x and 1 or -1, y = 0} -- the enemy on the far side
    local side = {x = 0, y = 1}
    lib.clear(s, P.bat, 44)
    local mine, foe = {}, {}
    local function spawn(list, name, n, at, force, cols, gap)
      for _, e in ipairs(lib.spawn(units, name, n, at, force, cols, gap)) do list[#list + 1] = e end
    end
    -- two lines facing each other (rows run north-south, the armies east-west), artillery behind each
    spawn(mine, "rts-walker-mk2", 16, add(P.bat, dir, -17), F, 2, 4.5)
    spawn(mine, "rts-heavy-mk2", 4, add(P.bat, dir, -25), F, 1, 10)
    spawn(mine, "rts-armoured-car", 2, add(add(P.bat, dir, -22), side, 20), F, 2, 6)
    spawn(mine, "rts-armoured-car", 2, add(add(P.bat, dir, -22), side, -14), F, 2, 6)
    spawn(mine, "rts-artillery", 3, add(P.bat, dir, -36), F, 1, 11)
    spawn(foe, "rts-walker-mk2", 16, add(P.bat, dir, 17), E1, 2, 4.5)
    spawn(foe, "rts-drone", 12, add(P.bat, dir, 11), E1, 2, 4)
    spawn(foe, "rts-heavy-mk2", 3, add(P.bat, dir, 26), E1, 1, 8)
    spawn(foe, "rts-artillery", 2, add(P.bat, dir, 36), E1, 1, 10)
    P.bat_mine, P.bat_foe = mine, foe
    P.bat_div = divisions.create(F, mine, nil, {owner = "player"})
    divisions.set_stance(P.bat_div, "advance")
    divisions.order(P.bat_div, "attack_move", add(P.bat, dir, 22))
    orders.attack_move(foe, add(P.bat, dir, -22))
    lib.log("04: battle at %s (clutter %s): %d vs %d, division %s", util.pos_str(P.bat), tostring(bs), #mine, #foe,
      tostring(P.bat_div))
    lib.clean_hud(player, true)
    lib.view(player, {x = P.bat.x, y = P.bat.y - 5}, 0.48)
    lib.reveal(F, s, P.bat, 80)
    P.bat_t0 = game.tick
    return 30
  end)
  -- a shell's big explosion on screen, the lines engaged
  lib.wait_until("explosions", function(player, P)
    local s = surface()
    local big = s.count_entities_filtered({position = P.bat, radius = 45, name = {"big-explosion",
      "spidertron-explosion"}})
    local n = s.count_entities_filtered({position = P.bat, radius = 45, type = "explosion"})
    local hurt = 0
    for _, e in ipairs(P.bat_mine) do if e.valid and e.health < e.max_health then hurt = hurt + 1 end end
    for _, e in ipairs(P.bat_foe) do if e.valid and e.health < e.max_health then hurt = hurt + 1 end end
    if game.tick - P.bat_t0 > 60 * 4 and big >= 1 and n >= 5 and hurt >= 10 then
      P.bat_expl = n
      return true
    end
  end, 2, 60 * 40)
  step(function(player, P)
    lib.reveal(F, surface(), P.bat, 80)
    lib.freeze_capture(player, P, "alt-04-division-battle-plain")
    lib.log("04: %d explosions on screen", P.bat_expl or -1)
    return 4
  end)
  step(function(player, P)
    -- the same moment with the division selected (selection boxes, the division card's stances, the unit cards)
    selection.set(player.index, P.bat_mine)
    return 4
  end)
  step(function(player, P)
    lib.capture_now(player, "04-division-battle")
    return 10
  end)
  step(function(player, P)
    lib.unfreeze(P)
    selection.clear(player.index)
    return 60 * 2
  end)
  step(function(player, P)
    lib.freeze_capture(player, P, "alt-04-division-battle-b")
    return 10
  end)
  step(function(player, P)
    lib.unfreeze(P)
    lib.close_panels(player)
    return 30
  end)
end)

--- The engine draws a hauler's autopilot path on the map (a straight line to its next stop, up to 1000 tiles long):
--- for a map capture the haulers lose their destinations; the logistics module gives them back within seconds.
local function clear_hauler_paths()
  local n = 0
  for _, rec in units.for_force(F) do
    local e = rec.entity
    if rec.kind == "hauler" and e.valid and e.type == "spider-vehicle" and e.autopilot_destination then
      e.autopilot_destination = nil
      n = n + 1
    end
  end
  return n
end

local function map_capture(name)
  step(function(player, P)
    lib.clean_hud(player, true)
    local n = clear_hauler_paths()
    lib.freeze_capture(player, P, name)
    lib.log("%s: %d hauler paths cleared for the capture", name, n)
    return 2
  end)
  step(function(player, P)
    lib.unfreeze(P)
    return 60
  end)
end

---------------------------------------------------------------------------
-- 09: the map view: regions, city-states, the front, depot labels, division markers
---------------------------------------------------------------------------
scene("09-strategic-map", function()
  step(function(player, P)
    lib.close_panels(player)
    -- the engine's own train stop names ("rts-player depot 7196") would sit next to the mod's "Depot N" labels
    player.map_view_settings = {["show-train-station-names"] = false}

    local c = P.town and {x = (P.home.x * 2 + P.town.pos.x) / 3, y = (P.home.y * 2 + P.town.pos.y) / 3} or P.home
    lib.view(player, c, 0.07)
    return 240
  end)
  map_capture("alt-09-strategic-map-close")
  step(function(player, P)
    -- the wide view: regions, city-states, the rivals' towns; the world's edge kept off screen
    local zoom = 0.058
    local half = (storage.world and storage.world.size or 2048) / 2
    local hx, hy = W / 2 / (32 * zoom), H / 2 / (32 * zoom)
    local c = P.town and {x = (P.home.x + P.town.pos.x) / 2, y = (P.home.y + P.town.pos.y) / 2 + 20} or P.home
    c = {x = math.max(-half + hx - 40, math.min(half - hx + 40, c.x)), y = math.max(-half + hy - 60, math.min(half - hy, c.y))}
    lib.view(player, c, zoom)
    return 240
  end)
  map_capture("09-strategic-map")
  step(function(player, P)
    lib.view(player, P.home, 0.5)
    return 60
  end)
end)

---------------------------------------------------------------------------
-- 10: the diplomacy panel: three nations, our war on AI 1 and its peace offer
---------------------------------------------------------------------------
scene("10-diplomacy", function()
  step(function(player, P)
    lib.clean_hud(player, true)
    local id, why = diplomacy.propose(E1, F, "peace", {kind = "white"})
    lib.log("10: peace offer %s %s", tostring(id), tostring(why))
    lib.view(player, P.cap_view or P.home, 0.5)
    diplomacygui.toggle(player)
    return 120
  end)
  step(function(player, P)
    lib.clean_hud(player, true)
    return 2
  end)
  capture("10-diplomacy", 60)
  step(function(player, P) lib.close_panels(player) return 30 end)
end)

step(function(player, P)
  status("end")
  return nil
end)
