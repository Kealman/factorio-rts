-- Phase 5 M2 QA round 1 (docs/qa/phase5-m2-integration-notes.md section 7), headless, tools/autotest-run.sh EXTRA_LUA
-- on a 1v1 Nation match: the QA run's troop train geometry. Two depots 22 tiles left and right of the player's CC (one
-- track 8 tiles below it, a 4-tile line between the platforms), the kits of protocol step 17, a 36-walker division
-- parked across the platform track where the troop train's head goes. Deploy must place the train (the walkers step
-- aside; before the fix: "the train does not fit on the platform"); an embark at a depot without a train, kits or a
-- train on the way is refused and the division stays idle (before: "Boarding a train" for good); a missing platform
-- rail and enemy walkers on the track are named by rails.deploy_check.
--   EXTRA_LUA=tools/probes/m2_qafix_deploy.lua STOP_ON='qfd summary' SEED=501 SPEED=4 tools/autotest-run.sh qfd \
--     '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 1536, enemy_brain = "ai"}' 600
-- Log lines "[rts] qfd check <name>: PASS|FAIL ..." and "[rts] qfd summary <pass>/<total>".
local events = require("scripts.events")
local util = require("scripts.util")
local ai = require("scripts.ai.init")
local units = require("scripts.units")
local buildings = require("scripts.buildings")
local economy = require("scripts.economy")
local divisions = require("scripts.divisions")
local rails = require("scripts.rails")
local logistics = require("scripts.logistics")
local match = require("scripts.match")

local F, E = "rts-player", "rts-ai-1"
local T

local function check(name, ok, fmt, ...)
  if ok then T.pass = T.pass + 1 else T.fail = T.fail + 1 end
  util.log("qfd check %s: %s %s", name, ok and "PASS" or "FAIL", string.format(fmt, ...))
end

-- Own unit bodies within 1.6 tiles of a platform's track.
local function on_track(d)
  local p = d.platform
  local n = 0
  for _, e in ipairs(match.surface().find_entities_filtered({area = p.area, force = F,
                                                             type = {"unit", "spider-unit", "spider-vehicle"}})) do
    local across = p.axis == "x" and e.position.y or e.position.x
    if math.abs(across - p.track) < 1.6 then n = n + 1 end
  end
  return n
end

local function spawn(force, n, x0, y0)
  local list = {}
  for k = 1, n do
    local e = units.spawn("rts-walker", {x = x0 + ((k - 1) % 6) * 3, y = y0 + math.floor((k - 1) / 6) * 2}, force, nil,
      match.surface())
    if e then list[#list + 1] = e end
  end
  return list
end

local PH = {}
PH.setup = function()
  ai.stop_force(F)
  ai.stop_force(E)
  local s = match.surface()
  T.home = buildings.main_cc(F).entity.position
  local h = T.home
  for _, e in ipairs(s.find_entities_filtered({area = {{h.x - 60, h.y - 4}, {h.x + 60, h.y + 20}},
                                              type = {"tree", "simple-entity", "cliff"}})) do
    if e.valid then e.destroy() end
  end
  -- both platforms on one track 8 tiles below the CC: the economic AI's first ghosts and belts there go
  for _, e in ipairs(s.find_entities_filtered({area = {{h.x - 46, h.y + 2}, {h.x + 46, h.y + 14}},
                                              type = {"entity-ghost", "transport-belt", "inserter", "electric-pole"}})) do
    if e.valid then e.destroy() end
  end
  local A = s.create_entity({name = "rts-depot", position = {h.x - 22, h.y}, force = F, raise_built = true})
  local B = s.create_entity({name = "rts-depot", position = {h.x + 22, h.y}, force = F, raise_built = true})
  T.A, T.B = A and A.unit_number, B and B.unit_number
  local dA, dB = T.A and rails.depot(T.A), T.B and rails.depot(T.B)
  local ok = dA and dB and dA.platform and dB.platform and dA.platform.track == dB.platform.track or false
  check("setup", ok, "depots #%s #%s, platform tracks %s %s", tostring(T.A), tostring(T.B),
    tostring(dA and dA.platform and dA.platform.track), tostring(dB and dB.platform and dB.platform.track))
  if not ok then return "done" end
  for item, n in pairs({["rts-locomotive-kit"] = 4, ["rts-troop-wagon-kit"] = 2, ["rts-construction-wagon-kit"] = 1,
                        rail = 300, coal = 200}) do
    economy.give(F, item, n)
  end
  T.line = rails.plan_line(F, T.A, T.B)
  T.t = game.tick
  return "line"
end
PH.line = function()
  local line = rails.lines[T.line]
  if line and line.state == "open" then
    check("line_open", line.wait == nil, "line #%d open after %.1f s: %d pieces, wait reason %s (none expected)",
      T.line, (game.tick - T.t) / 60, #line.pieces, tostring(line.wait))
    T.div = divisions.create(F, spawn(F, 36, T.home.x - 8, T.home.y + 14), {stance = "hold"}, {owner = "player"})
    -- across the platform track where the troop train's head goes
    local dA = rails.depot(T.A)
    local e = dA.platform.ends[line.a_end or 2]
    local dx = (e.d == defines.direction.east and -1) or (e.d == defines.direction.west and 1) or 0
    divisions.order(T.div, "move", {x = e.x + dx * 12, y = dA.platform.track})
    T.t = game.tick
    return "park"
  end
  if game.tick - T.t > 150 * 60 then
    check("line_open", false, "line #%s state %s after 150 s", tostring(T.line), line and line.state or "-")
    return "done"
  end
end
PH.park = function()
  if game.tick - T.t < 20 * 60 then return end
  local dA = rails.depot(T.A)
  local before = on_track(dA)
  local why = rails.deploy_check(T.A, "troop")
  check("deploy_check", why == nil, "troop train deployable with %d walkers on the track: %s", before, tostring(why))
  local train, why2 = rails.create_train(T.A, "troop")
  check("deploy", train ~= nil and on_track(dA) == 0, "troop train %s (%s); walkers on the track %d -> %d",
    tostring(train and train.id), tostring(why2), before, on_track(dA))
  check("deploy_busy", rails.deploy_check(T.A, "troop") == "busy", "a second train: %s",
    tostring(rails.deploy_check(T.A, "troop")))
  return "embark"
end
PH.embark = function()
  local ok = divisions.order(T.div, "embark", T.A)
  local D = divisions.get(T.div)
  check("embark_with_train", ok and D.embark ~= nil, "order %s, embark %s", tostring(ok), serpent.line(D.embark))
  divisions.order(T.div, "stop")
  -- depot B: the kits are gone and no troop train comes there
  local net = logistics.hub_network(T.B)
  for _, k in ipairs({"rts-locomotive-kit", "rts-troop-wagon-kit"}) do
    local n = net.get_item_count(k)
    if n > 0 then net.remove_item({name = k, count = n}) end
  end
  local ok2, why2 = divisions.order(T.div, "embark", T.B)
  D = divisions.get(T.div)
  check("embark_no_train", not ok2 and not D.embark and D.no_train ~= nil and D.state ~= "moving",
    "order %s (%s), embark %s, no_train %s, state %s", tostring(ok2), tostring(why2), serpent.line(D.embark),
    serpent.line(D.no_train), tostring(D.state))
  -- kits back; a platform rail of B gone: "no-track"; then enemy walkers across B's track: "enemy-on-track"
  economy.give(F, "rts-locomotive-kit", 2)
  economy.give(F, "rts-troop-wagon-kit", 1)
  local dB = rails.depot(T.B)
  T.cut = nil
  for _, r in ipairs(dB.platform.rails) do
    if r.valid and math.abs(r.position.x - (dB.platform.ends[1].x + 8)) < 1.5 then
      T.cut = {x = r.position.x, y = r.position.y}
      r.destroy()
      break
    end
  end
  check("no_track", rails.deploy_check(T.B, "troop") == "no-track", "rail cut at %s: %s", util.pos_str(T.cut),
    tostring(rails.deploy_check(T.B, "troop")))
  match.surface().create_entity({name = "straight-rail", position = T.cut, direction = defines.direction.east,
                                 force = F})
  local foes = spawn(E, 6, dB.platform.ends[1].x + 4, dB.platform.track)
  T.foes = foes
  T.t = game.tick
  return "enemy"
end
PH.enemy = function()
  if game.tick - T.t < 60 then return end
  local why = rails.deploy_check(T.B, "troop")
  check("enemy_on_track", why == "enemy-on-track", "%d enemy walkers on B's track: %s", #T.foes, tostring(why))
  return "done"
end

events.on_nth_tick(30, function()
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  if not storage.qfd then
    if game.tick - m.tick_started < 300 then return end
    storage.qfd = {pass = 0, fail = 0, phase = "setup"}
  end
  T = storage.qfd
  if T.phase == "done" then return end
  local ok, nxt = pcall(PH[T.phase])
  if not ok then
    check("error", false, "phase %s: %s", T.phase, tostring(nxt))
    nxt = "done"
  end
  if nxt then T.phase = nxt end
  if T.phase == "done" then
    util.log("qfd summary %d/%d (%s)", T.pass, T.pass + T.fail, T.fail == 0 and "all passed" or "FAILED")
  end
end)
