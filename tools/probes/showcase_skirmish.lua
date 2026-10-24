-- Showcase (release media), launch 3: Skirmish (tools/showcase.sh skirmish). The lobby is set to Skirmish, 1 normal
-- AI, a large Chokepoints arena (seed cfg.seed); the AI also plays the player's side (ai.init_force rts-player, hard,
-- economic) at game speed cfg.bake_speed for cfg.bake_minutes, so the base, its hubs, haulers and barracks are real
-- play; then the player's AI stops and the scenes are staged:
--   14-skirmish-base         the base between the CC and its natural hub, a barracks selected (its kit in production),
--                            haulers on the route
--   13-commander-abilities   the Commander and an army meet an enemy force in the middle; Shield (C) and an Artillery
--                            strike (G) are cast through the ability code (abilities.activate / abilities.cast); the
--                            capture is taken as the strike's shells land, the ability bar shows both cooldowns
-- Log lines "[rts] showcase: ...", the end marker "SHOWCASE_DONE skirmish shoot".
local util = require("scripts.util")
local events = require("scripts.events")
local match = require("scripts.match")
local lobby = require("scripts.lobby")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local selection = require("scripts.selection")
local orders = require("scripts.orders")
local divisions = require("scripts.divisions")
local abilities = require("scripts.abilities")
local commander = require("scripts.commander")
local supply = require("scripts.supply")
local ai = require("scripts.ai.init")
local lib = require("scripts.showcase_lib")

local cfg = lib.cfg
local F, E = "rts-player", "rts-ai-1"
local step, scene, capture = lib.step, lib.scene, lib.capture
local W, H = lib.W, lib.H

local function find(el, name)
  if not (el and el.valid) then return nil end
  if el.name == name then return el end
  for _, c in pairs(el.children) do
    local f = find(c, name)
    if f then return f end
  end
end

local function gui_click(player, el)
  if not (el and el.valid) then return false end
  events.dispatch(defines.events.on_gui_click, {element = el, player_index = player.index,
    name = defines.events.on_gui_click, button = defines.mouse_button_type.left, shift = false, control = false,
    alt = false})
  return true
end

local function norm(v)
  local l = math.sqrt(v.x * v.x + v.y * v.y)
  if l < 1e-6 then return {x = 1, y = 0} end
  return {x = v.x / l, y = v.y / l}
end
local function add(a, v, k) return {x = a.x + v.x * k, y = a.y + v.y * k} end
local function mid(a, b) return {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2} end

local function status(tag)
  local parts = {}
  for _, f in ipairs(match.forces()) do
    parts[#parts + 1] = string.format("%s army %d haulers %d hubs %d barracks %d factories %d smelters %d", f,
      units.count(f) - units.count(f, "hauler"), units.count(f, "hauler"), buildings.count(f, "hub"),
      buildings.count(f, "barracks"), buildings.count(f, "factory"), buildings.count(f, "smelter"))
  end
  lib.log("status %s minute %.1f speed %.1f: %s", tag, (game.tick - (storage.match.tick_started or 0)) / 3600, game.speed,
    table.concat(parts, " | "))
end

---------------------------------------------------------------------------
-- Lobby and the build-up
---------------------------------------------------------------------------
step(function(player, P)
  local nauvis = game.surfaces.nauvis
  local mgs = nauvis.map_gen_settings
  mgs.seed = cfg.seed or 777
  nauvis.map_gen_settings = mgs
  local p = storage.lobby.pending
  p.mode, p.opponents, p.difficulty, p.size, p.map = "skirmish", 1, "normal", "large", "chokes"
  lobby.show_lobby(player)
  lib.park_mouse()
  gui_click(player, find(player.gui.screen.rts_lobby, "rts_lobby_start"))
  return 120
end)
lib.wait_until("match", function() return not match.in_lobby() and buildings.main_cc(F) ~= nil end, 30, 3600)
step(function(player, P)
  P.home = buildings.main_cc(F).entity.position
  P.enemy_home = match.home(E)
  lib.quiet_alerts(player)
  ai.set_doctrine(F, "economic")
  local C = ai.init_force(F, "hard")
  -- the player's AI builds and defends but never attacks: a won match would end the staging (the Skirmish victory)
  if C then C.cfg.first_attack = 1e9 end
  local cmdr = commander.entity(F)
  if cmdr and cmdr.valid then cmdr.destructible = false end
  lib.log("skirmish: CC %s, enemy %s, AI for %s: %s %s", util.pos_str(P.home), util.pos_str(P.enemy_home), F,
    C and C.difficulty or "-", C and C.doctrine or "-")
  lib.view(player, P.home, 0.5)
  game.speed = cfg.bake_speed or 32
  return 60
end)
step(function(player, P)
  local minute = (game.tick - (storage.match.tick_started or 0)) / 3600
  if minute >= (cfg.bake_minutes or 12) then return 1 end
  if (P.last_status or -1) < math.floor(minute) then
    P.last_status = math.floor(minute)
    status("bake")
  end
  P.i = P.i - 1
  return 300
end)
step(function(player, P)
  game.speed = 1
  ai.stop_force(F)
  status("baked")
  lib.close_panels(player)
  return 60
end)

---------------------------------------------------------------------------
-- 14: the base: CC, factories, barracks making units, the natural hub and haulers on its route
---------------------------------------------------------------------------
scene("14-skirmish-base", function()
  step(function(player, P)
    -- supply for the barracks (/rts-research): at the cap its page would read "Supply cap: Walker waits"
    lib.research(F, {"rts-supply-1", "rts-supply-2"})
    -- the own hub nearest to the CC that has its own network (the natural), else the CC alone
    local hub, hd
    for un, rec in buildings.for_force(F, "hub") do
      local e = rec and rec.entity or (type(un) == "table" and un.entity)
      if e and e.valid then
        local d = lib.dist(e.position, P.home)
        if d > 30 and (not hd or d < hd) then hub, hd = e, d end
      end
    end
    P.hub = hub
    -- the base's bounding box (production buildings, hubs, stockpiles within 100 tiles of the CC) fills the frame
    local x1, y1, x2, y2 = P.home.x - 20, P.home.y - 20, P.home.x + 20, P.home.y + 20
    for _, e in ipairs(match.surface().find_entities_filtered({position = P.home, radius = 100, force = F,
        type = {"assembling-machine", "furnace", "roboport", "mining-drill", "lab", "solar-panel", "ammo-turret"}})) do
      local p = e.position
      x1, y1, x2, y2 = math.min(x1, p.x), math.min(y1, p.y), math.max(x2, p.x), math.max(y2, p.y)
    end
    -- the base's box fills the free part of the screen (x 40-1560, y 130-930: left of the hub policy panel, between
    -- the strip and the bottom panels)
    local zoom = math.max(0.3, math.min(0.62, 1520 / (x2 - x1 + 14) / 32, 800 / (y2 - y1 + 10) / 32))
    local k = 32 * zoom
    local c = {x = (x1 + x2) / 2 - (800 - W / 2) / k, y = (y1 + y2) / 2 - (530 - H / 2) / k}
    P.base_view, P.base_zoom = c, zoom
    -- the raids' damage is repaired (the hub at half health looked broken)
    for _, e in ipairs(match.surface().find_entities_filtered({position = P.home, radius = 120, force = F})) do
      if e.valid and e.health and e.max_health and e.health < e.max_health and e.type ~= "spider-unit"
          and e.type ~= "unit" then
        e.health = e.max_health
      end
    end
    lib.log("14: hub %s (%s tiles), view %s zoom %.2f", hub and util.pos_str(hub.position) or "-", tostring(hd and
      math.floor(hd)), util.pos_str(c), P.base_zoom)
    lib.view(player, c, P.base_zoom)
    -- a barracks with a kit in production, selected (its page shows the kit)
    local best
    for un, rec in buildings.for_force(F, "barracks") do
      local e = rec and rec.entity
      local busy = false
      if e and e.valid then
        local ok, v = pcall(function() return e.is_crafting() end)
        busy = ok and v
      end
      if e and e.valid and (not best or busy) then best = e end
    end
    -- staging: the AI's raid on the base is over (its units within 160 tiles of our CC go), our idle army stands in a
    -- block at the rally point between the CC and the natural hub
    local s = match.surface()
    local gone = 0
    for _, e in ipairs(s.find_entities_filtered({position = P.home, radius = 160, force = E,
        type = {"spider-unit", "unit", "spider-vehicle"}})) do
      if e.valid then
        e.destroy()
        gone = gone + 1
      end
    end
    local army = {}
    for _, rec in units.for_force(F) do
      local e = rec.entity
      if e.valid and rec.kind ~= "hauler" and rec.kind ~= "commander" then army[#army + 1] = e end
    end
    table.sort(army, function(a, b) return a.name < b.name end)
    -- the remains of the raids go (corpses over the base)
    lib.clear(s, c, 90, {"corpse"})
    local rally = hub and {x = (P.home.x + hub.position.x) / 2 + 10, y = P.home.y + 16} or {x = P.home.x + 40, y = P.home.y + 16}
    -- 12 units stand in a 4 x 3 block at the rally point; the rest waits 70 tiles north, outside the frame
    for i, e in ipairs(army) do
      local p
      if i <= 12 then
        p = {x = rally.x + ((i - 1) % 4 - 1.5) * 3.6, y = rally.y + (math.floor((i - 1) / 4) - 1) * 3.6}
      else
        p = {x = rally.x + ((i - 13) % 12 - 5.5) * 3.2, y = P.home.y - 70 - math.floor((i - 13) / 12) * 3.2}
      end
      e.teleport(s.find_non_colliding_position(e.name, p, 6, 0.5) or p)
    end
    orders.hold(army)
    lib.log("14: %d raiders removed, %d army units in a block at %s", gone, #army, util.pos_str(rally))
    -- the natural hub selected: its stockpile policy (Keep / Export above) is the haulers' route
    if hub then selection.select_building(player.index, hub.unit_number)
    elseif best then selection.select_building(player.index, best.unit_number) end
    P.hpos = {}
    return 120
  end)
  lib.wait_until("hauler on the route", function(player, P)
    local hx, hy = W / 2 / (32 * P.base_zoom) - 6, H / 2 / (32 * P.base_zoom) - 8
    local found = false
    for _, rec in units.for_force(F) do
      local e = rec.entity
      if rec.kind == "hauler" and e.valid then
        local p = e.position
        local last = P.hpos[e.unit_number]
        if last and lib.dist(last, p) > 1 and math.abs(p.x - P.base_view.x) < hx and math.abs(p.y - P.base_view.y) < hy then
          found = true
        end
        P.hpos[e.unit_number] = {x = p.x, y = p.y}
      end
    end
    return found
  end, 30, 60 * 90)
  step(function(player, P)
    lib.clean_hud(player, true)
    return 2
  end)
  capture("14-skirmish-base", 60)
  step(function(player, P) lib.close_panels(player) return 30 end)
end)

---------------------------------------------------------------------------
-- 13: the Commander in a fight: Shield and an Artillery strike, the ability bar
---------------------------------------------------------------------------
scene("13-commander-abilities", function()
  step(function(player, P)
    local s = match.surface()
    local dir = norm({x = P.enemy_home.x - P.home.x, y = P.enemy_home.y - P.home.y})
    local side0 = {x = -dir.y, y = dir.x}
    -- the staged fighters (about 40 supply) fit under the cap: parked units (70 tiles north) are disbanded
    local need = 44
    local parked = {}
    for _, rec in units.for_force(F) do
      local e = rec.entity
      if e.valid and rec.kind ~= "hauler" and rec.kind ~= "commander" and e.position.y < P.home.y - 50 then
        parked[#parked + 1] = e
      end
    end
    local gone = 0
    for _, e in ipairs(parked) do
      if supply.cap(F) - supply.used(F) >= need then break end
      e.destroy({raise_destroy = true})
      gone = gone + 1
    end
    lib.log("13: %d parked units disbanded, supply %s / %s", gone, tostring(supply.used(F)), tostring(supply.cap(F)))
    -- open dry ground in the middle of the arena (past our moat, short of the ruin)
    local best, bs
    for _, k in ipairs({140, 155, 170, 185}) do
      for j = -4, 4 do
        local p = add(add(P.home, dir, k), side0, j * 10)
        local area = {{p.x - 26, p.y - 18}, {p.x + 26, p.y + 18}}
        local sc = s.count_tiles_filtered({area = area, collision_mask = "water_tile"}) * 4
          + s.count_entities_filtered({area = area, type = {"tree", "simple-entity", "cliff"}})
          + s.count_entities_filtered({area = area, force = {F, E}}) * 10 + math.abs(j) * 3
        if not bs or sc < bs then best, bs = p, sc end
      end
    end
    local spot = best
    lib.log("13: fight at %s (clutter %s)", util.pos_str(spot), tostring(bs))
    lib.clear(s, spot, 40)
    P.fight = spot
    local c = commander.entity(F)
    if c and c.valid then c.teleport(s.find_non_colliding_position(c.name, add(spot, dir, -10), 10, 1) or spot) end
    P.cmdr = c
    local mine, foe = {}, {}
    local function spawn(list, name, n, at, force, cols, gap)
      for _, e in ipairs(lib.spawn(units, name, n, at, force, cols, gap)) do list[#list + 1] = e end
    end
    local side = {x = -dir.y, y = dir.x}
    spawn(mine, "rts-walker-mk2", 10, add(spot, dir, -12), F, 5, 4)
    spawn(mine, "rts-walker-heavy", 3, add(add(spot, dir, -18), side, 10), F, 3, 6)
    spawn(mine, "rts-artillery", 3, add(spot, dir, -24), F, 3, 6)
    spawn(foe, "rts-walker", 12, add(spot, dir, 18), E, 4, 4)
    spawn(foe, "rts-drone", 10, add(spot, dir, 12), E, 5, 3)
    spawn(foe, "rts-walker-heavy", 2, add(spot, dir, 26), E, 2, 6)
    P.mine, P.foe = mine, foe
    orders.attack_move(foe, add(spot, dir, -14))
    local army = {}
    for _, e in ipairs(mine) do army[#army + 1] = e end
    orders.hold(army)
    if c and c.valid then army[#army + 1] = c end
    P.army = army
    lib.clean_hud(player, true)
    lib.view(player, add(spot, dir, 0), 0.62)
    lib.reveal(F, s, spot, 70)
    selection.set(player.index, {c})
    P.dir = dir
    P.t0 = game.tick
    return 60 * 3
  end)
  step(function(player, P)
    abilities.reset_cooldowns(F)
    local ok = abilities.activate(player.index, "shield")
    lib.log("13: shield %s", tostring(ok))
    return 30
  end)
  step(function(player, P)
    local c = lib.centroid(P.foe) or add(P.fight, P.dir, 8)
    P.strike = c
    local ok = abilities.cast(player.index, "artillery", c)
    lib.log("13: artillery strike at %s: %s", util.pos_str(c), tostring(ok))
    P.t1 = game.tick
    return 1
  end)
  -- the shells land: a big explosion near the strike point, at least 40 ticks after the cast (the target circle lasts 120)
  lib.wait_until("strike lands", function(player, P)
    if game.tick - P.t1 < 40 then return false end
    local n = match.surface().count_entities_filtered({position = P.strike, radius = 8, name = "big-explosion"})
    return n >= 1 or game.tick - P.t1 > 100
  end, 1, 60 * 3)
  step(function(player, P)
    lib.freeze_capture(player, P, "13-commander-abilities")
    return 10
  end)
  step(function(player, P) lib.unfreeze(P) return 60 * 2 end)
  step(function(player, P)
    lib.freeze_capture(player, P, "alt-13-commander-abilities-b")
    return 10
  end)
  step(function(player, P) lib.unfreeze(P) return 60 end)
end)

step(function(player, P)
  status("end")
  return nil
end)
lib.start()
