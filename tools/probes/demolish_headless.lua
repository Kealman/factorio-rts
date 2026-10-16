-- Demolish headless probe (test copy only: tools/autotest-run.sh EXTRA_LUA=tools/probes/demolish_headless.lua,
-- STOP_ON='demolish probe done'). The AI of rts-player is stopped, then on the running match:
--  1. barracks + turret: demolished through the two-press request path (selection index 0): armed first, entity gone,
--     refund = 50 % of the cost lands in the CC network's stockpiles (iron/copper totals), force entity count back.
--  2. a hub next to the CC with 50 copper in one of its stockpiles: demolished; hub, hidden parts and both stockpiles
--     gone (entity count of the force back to the value before the hub), registry and policy dropped, the copper moved
--     to another stockpile, refund 16/2 -> 16 iron 5 copper.
--  3. a loaded stockpile in the network: contents moved, refund 10 iron 2 copper; one far from every stockpile:
--     contents spilled as items on the ground; two walls in one batch: 1 stone brick refunded (5 walls cost 5).
--     A lone hub refunds into a stockpile 40 tiles away; with no sink and no pool the refund spills with an alert.
--  4. the Command Center is refused ("blocked", still standing); a ghost is cancelled; an armed request expires
--     after CONFIRM_TICKS; hub teardown leaves no other-force damage. Log lines "[rts] demolish probe ...".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local buildings = require("scripts.buildings")
local match = require("scripts.match")
local selection = require("scripts.selection")
local demolish = require("scripts.demolish")
local logistics = require("scripts.logistics")

local F = util.PLAYER_FORCE
local fails = 0

local function check(name, ok, fmt, ...)
  if not ok then fails = fails + 1 end
  util.log("demolish probe %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt or "", ...))
end

local function stock(item)
  local n = 0
  for _, rec in buildings.for_force(F, "stockpile") do n = n + rec.entity.get_item_count(item) end
  return n
end

local function count(surface) return surface.count_entities_filtered({force = F}) end

local function spot(surface, name, near)
  return surface.find_non_colliding_position(name, near, 30, 1, true)
end

-- two presses on one building through the selection (fake index 0); returns the second result
local function demolish_selected(un)
  selection.select_building(0, un)
  local r1 = demolish.request(0)
  local r2 = demolish.request(0)
  return r1, r2
end

local function run()
  local cc = buildings.main_cc(F)
  local surface = cc.entity.surface
  local home = cc.entity.position
  storage.demolish_probe_blds = nil

  -- 1. barracks and turret
  local e0 = count(surface)
  local b_pos = spot(surface, "rts-barracks", {x = home.x + 14, y = home.y})
  local barracks = surface.create_entity({name = "rts-barracks", position = b_pos, force = F, raise_built = true})
  local turret = surface.create_entity({name = "rts-turret", position = spot(surface, "rts-turret", {x = home.x - 12, y = home.y + 8}),
                                        force = F, raise_built = true})
  check("built", barracks and turret and buildings.get(barracks.unit_number) and buildings.get(turret.unit_number),
    "barracks %s turret %s", tostring(barracks and barracks.unit_number), tostring(turret and turret.unit_number))
  local iron, copper = stock("iron-plate"), stock("copper-plate")
  local bun = barracks.unit_number
  local r1, r2 = demolish_selected(bun)
  check("barracks two presses", r1 == "armed" and r2 == "done", "%s then %s", r1, r2)
  check("barracks gone", not barracks.valid and buildings.get(bun) == nil, "")
  check("barracks refund", stock("iron-plate") - iron == 30 and stock("copper-plate") - copper == 10,
    "iron %+d (want 30) copper %+d (want 10)", stock("iron-plate") - iron, stock("copper-plate") - copper)
  iron, copper = stock("iron-plate"), stock("copper-plate")
  r1, r2 = demolish_selected(turret.unit_number)
  check("turret", r1 == "armed" and r2 == "done" and not turret.valid, "%s %s", r1, r2)
  check("turret refund", stock("iron-plate") - iron == 20 and stock("copper-plate") - copper == 5,
    "iron %+d (want 20) copper %+d (want 5)", stock("iron-plate") - iron, stock("copper-plate") - copper)
  check("entities back", count(surface) == e0, "%d before, %d after", e0, count(surface))

  -- 2. hub with stockpiles
  local registry0 = buildings.count(F)
  local e1 = count(surface)
  local hpos = spot(surface, "rts-hub", {x = home.x, y = home.y + 14})
  local hub = surface.create_entity({name = "rts-hub", position = hpos, force = F, raise_built = true})
  local hun = hub.unit_number
  local pol = logistics.policy(hun)
  local sp = pol.parts.stockpiles
  check("hub built", #sp == 2 and count(surface) > e1 + 3, "stockpiles %d, entities %d -> %d", #sp, e1, count(surface))
  sp[1].insert({name = "copper-plate", count = 50})
  local hub_net = hub.logistic_network
  local cc_net = cc.entity.logistic_network
  util.log("demolish probe: hub network %s, CC network %s", tostring(hub_net and hub_net.network_id), tostring(cc_net and cc_net.network_id))
  iron, copper = stock("iron-plate"), stock("copper-plate")
  local part_uns = {sp[1].unit_number, sp[2].unit_number}
  r1, r2 = demolish_selected(hun)
  check("hub two presses", r1 == "armed" and r2 == "done", "%s then %s", r1, r2)
  check("hub gone", not hub.valid and not sp[1].valid and not sp[2].valid, "")
  check("hub entities back", count(surface) == e1, "%d before the hub, %d after", e1, count(surface))
  check("hub registry", buildings.count(F) == registry0 and not storage.buildings[part_uns[1]]
        and not storage.buildings[part_uns[2]] and storage.logistics.hubs[hun] == nil,
    "buildings %d vs %d", buildings.count(F), registry0)
  check("hub refund", stock("iron-plate") - iron == 16 and stock("copper-plate") - copper == 5,
    "iron %+d (want 16) copper %+d (want 5; the 50 plates moved)", stock("iron-plate") - iron,
    stock("copper-plate") - copper)

  -- 3. stockpile with contents, far stockpile, walls
  local s = surface.create_entity({name = "rts-stockpile", position = spot(surface, "rts-stockpile", {x = home.x + 10, y = home.y + 10}),
                                   force = F, raise_built = true})
  s.insert({name = "iron-plate", count = 100})
  iron, copper = stock("iron-plate"), stock("copper-plate")
  local sun = s.unit_number
  r1, r2 = demolish_selected(sun)
  check("stockpile", r1 == "armed" and r2 == "done" and not s.valid, "%s %s", r1, r2)
  check("stockpile contents moved + refund", stock("iron-plate") - iron == -100 + 100 + 10
        and stock("copper-plate") - copper == 2, "iron %+d (want +10) copper %+d (want +2)",
    stock("iron-plate") - iron, stock("copper-plate") - copper)

  local far = surface.create_entity({name = "rts-stockpile", position = spot(surface, "rts-stockpile", {x = home.x + 90, y = home.y + 90}),
                                     force = F, raise_built = true})
  local fp = far and far.position
  if far then
    far.insert({name = "stone", count = 30})
    local fun = far.unit_number
    r1, r2 = demolish_selected(fun)
    local ground = surface.count_entities_filtered({name = "item-on-ground", position = fp, radius = 8})
    check("far stockpile spill", r2 == "done" and not far.valid and ground > 0, "%s %s, %d item(s) on the ground", r1, r2,
      ground)
  else
    check("far stockpile spill", false, "no spot")
  end

  -- 3b. Phase 5 M1: a lone hub refunds into another own stockpile within REFUND_RANGE; with no sink and no pool the
  -- refund spills and the player gets the "refund spilled" alert
  local lpos = spot(surface, "rts-hub", {x = home.x + 90, y = home.y + 90})
  local lone = lpos and surface.create_entity({name = "rts-hub", position = lpos, force = F, raise_built = true})
  local rpos = lone and spot(surface, "rts-stockpile", {x = lone.position.x - 40, y = lone.position.y})
  local recv = rpos and surface.create_entity({name = "rts-stockpile", position = rpos, force = F, raise_built = true})
  if lone and recv then
    local d = util.distance(lone.position, recv.position)
    r1, r2 = demolish_selected(lone.unit_number)
    local gi, gc = recv.get_item_count("iron-plate"), recv.get_item_count("copper-plate")
    check("lone hub refund nearby", r2 == "done" and not lone.valid and gi == 16 and gc == 5,
      "%s %s, receiver %.0f tiles away got iron %d copper %d (want 16, 5)", r1, r2, d, gi, gc)
    local alerts0 = #(storage.alerts or {})
    local rp = recv.position
    selection.select_building(0, recv.unit_number)
    local s1 = demolish.request(0)
    local main_cc = buildings.main_cc
    buildings.main_cc = function() return nil end -- no pool: nowhere for the refund to go
    local ok, s2 = pcall(demolish.request, 0)
    buildings.main_cc = main_cc
    local alert
    for i = alerts0 + 1, #(storage.alerts or {}) do
      local a = storage.alerts[i]
      if a.text == "rts.alert-demolish-refund-spilled" then alert = a end
    end
    local ground = surface.count_entities_filtered({name = "item-on-ground", position = rp, radius = 8})
    check("refund spill alert", ok and s1 == "armed" and s2 == "done" and alert ~= nil and alert.params[1] == 12
          and ground > 0, "%s %s, alert %s, %d item(s) on the ground", tostring(s1), tostring(s2),
      alert and tostring(alert.params[1]) or "none", ground)
  else
    check("lone hub refund nearby", false, "no spot (hub %s, receiver %s)", tostring(lone), tostring(recv))
  end

  local w1 = surface.create_entity({name = "rts-wall", position = spot(surface, "rts-wall", {x = home.x + 20, y = home.y - 14}), force = F, raise_built = true})
  local w2 = surface.create_entity({name = "rts-wall", position = spot(surface, "rts-wall", {x = home.x + 22, y = home.y - 14}), force = F, raise_built = true})
  local bricks = stock("stone-brick")
  local walls = {w1.unit_number, w2.unit_number}
  local a1 = demolish.request(0, walls)
  local a2 = demolish.request(0, walls)
  check("walls batch", a1 == "armed" and a2 == "done" and not w1.valid and not w2.valid, "%s %s", a1, a2)
  check("walls refund", stock("stone-brick") - bricks == 1, "bricks %+d (want 1: 2 walls = 2 bricks, 50 %%)",
    stock("stone-brick") - bricks)

  -- 4. protection, ghost, expiry
  local ccun = cc.entity.unit_number
  selection.select_building(0, ccun)
  local c1 = demolish.request(0)
  local c2 = demolish.request(0)
  check("cc protected", c1 == "blocked" and c2 == "blocked" and cc.entity.valid and buildings.get(ccun) ~= nil,
    "%s %s", c1, c2)
  local ghost = surface.create_entity({name = "entity-ghost", inner_name = "rts-turret", force = F,
                                       position = spot(surface, "rts-turret", {x = home.x - 16, y = home.y - 12})})
  local gok = buildings.demolish(ghost, {force = F})
  check("ghost cancelled", gok and not ghost.valid, "")
  local t = surface.create_entity({name = "rts-turret", position = spot(surface, "rts-turret", {x = home.x - 12, y = home.y + 8}),
                                   force = F, raise_built = true})
  selection.select_building(0, t.unit_number)
  local x1 = demolish.request(0)
  storage.players[0].demolish.tick = game.tick - demolish.CONFIRM_TICKS - 5
  local x2 = demolish.request(0)
  check("armed press expires", x1 == "armed" and x2 == "armed" and t.valid and demolish.is_armed(0),
    "%s %s", x1, x2)
  buildings.demolish(t)
  local foreign, why = buildings.demolish(surface.create_entity({name = "rts-turret", position = spot(surface, "rts-turret", {x = home.x - 20, y = home.y + 20}),
    force = util.ENEMY_FORCE, raise_built = true}), {force = F})
  check("foreign refused", foreign == false and why == "foreign", "%s", tostring(why))
  util.log("demolish probe done: %d failure(s)", fails)
end

events.on_nth_tick(60, function()
  local m = storage.match
  if not (m and m.tick_started) then return end
  local P = storage.demolish_probe
  if not P then
    P = {}
    storage.demolish_probe = P
  end
  if P.done then return end
  if not P.started then
    if m.phase ~= "running" or game.tick - m.tick_started < 120 then return end
    P.started = game.tick
    ai.stop_force(F)
    local ok, err = pcall(run)
    if not ok then
      fails = fails + 1
      util.log("demolish probe ERROR: %s", tostring(err))
      util.log("demolish probe done: %d failure(s)", fails)
    end
    P.finish_at = game.tick + 600
    return
  end
  -- let on_object_destroyed of the demolished entities fire: no error expected
  if game.tick >= P.finish_at then
    P.done = true
    util.log("demolish probe: after 10 s %d failure(s); registry %d buildings of %s", fails, buildings.count(F), F)
  end
end)
