-- Phase 5 M3 integration probe: a train routed by hand comes back to its route when a depot it lost returns
-- (scripts/rails.lua, M2 integration open issue 12). 1v1 Nation, seed 501 (rts-player's AI opens its line by minute 20):
--   KEEP_TREE=<tree> EXTRA_LUA=tools/probes/m3_reroute.lua STOP_ON=RTS_REROUTE_DONE SEED=501 SPEED=8 DURATION_MIN=45 \
--     tools/autotest-run.sh m3i-reroute '{opponents = 1, difficulty = "normal", mode = "nation", world_size = 2048,
--     enemy_brain = "ai"}' 3000
-- From minute 22 the freight train of rts-player's line is handed over to "the player" (its ai_line mark removed, so the
-- AI rail program no longer routes it), and the line's far city goes to rts-ai-1 (capture.flip), 60 s later back.
-- Checks ("[rts] reroute check <name>: PASS|FAIL ..."): lost (the route's lost half remembered and cleared), routed (the
-- train has its pickup and drop-off again within 10 s of the city's return and is under way).
local events = require("scripts.events")
local util = require("scripts.util")
local cities = require("scripts.cities")
local capture = require("scripts.capture")

local F, E = "rts-player", "rts-ai-1"
local function S()
  storage.reroute = storage.reroute or {step = "wait", pass = 0, fail = 0}
  return storage.reroute
end
local function check(name, ok, fmt, ...)
  local s = S()
  if ok then s.pass = s.pass + 1 else s.fail = s.fail + 1 end
  util.log("reroute check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
end
local function done()
  local s = S()
  util.log("reroute summary %d/%d", s.pass, s.pass + s.fail)
  s.step = "done"
  log("RTS_REROUTE_DONE")
end

events.on_nth_tick(60, function(ev)
  local m = storage.match
  if not (m and m.phase == "running" and m.tick_started) then return end
  local s = S()
  local R = storage.rails
  local age = ev.tick - m.tick_started
  if s.step == "wait" then
    if age < 22 * 3600 then return end
    local A = R and R.ai and R.ai[F]
    local line = A and A.line and R.lines[A.line]
    local city = A and A.far and cities.of_center(A.far)
    local train
    for id, rec in pairs(R and R.trains or {}) do
      if line and rec.kind == "cargo" and rec.force == F and rec.ai_line == line.id and rec.pickup and rec.dropoff then
        train = id
      end
    end
    if not (line and line.state == "open" and city and train) then
      if age > 40 * 3600 then
        check("setup", false, "no open line with a routed freight train and a far city by minute 40")
        done()
      end
      return
    end
    local rec = R.trains[train]
    rec.ai_line = nil -- from now on a train the player routed by hand
    s.train, s.city, s.pickup, s.dropoff = train, city.id, rec.pickup, rec.dropoff
    util.log("reroute: train %d (route #%d -> #%d) handed to the player; city %d flips to %s", train, rec.pickup,
      rec.dropoff, city.id, E)
    capture.flip(city.id, E, "reroute probe")
    s.t = ev.tick
    s.step = "lost"
  elseif s.step == "lost" then
    if ev.tick - s.t < 3600 then return end
    local rec = R.trains[s.train]
    check("lost", rec ~= nil and (rec.lost_pickup ~= nil or rec.lost_dropoff ~= nil)
      and (rec.pickup == nil or rec.dropoff == nil),
      "train %d state %s, pickup %s dropoff %s, lost %s/%s", s.train, rec and rec.state or "-", tostring(rec and rec.pickup),
      tostring(rec and rec.dropoff), tostring(rec and rec.lost_pickup), tostring(rec and rec.lost_dropoff))
    capture.flip(s.city, F, "reroute probe")
    s.t = ev.tick
    s.step = "routed"
  elseif s.step == "routed" then
    if ev.tick - s.t < 600 then return end
    local rec = R.trains[s.train]
    check("routed", rec ~= nil and rec.pickup == s.pickup and rec.dropoff == s.dropoff and rec.lost_pickup == nil
      and rec.lost_dropoff == nil and (rec.state == "to_pickup" or rec.state == "to_dropoff" or rec.dwell ~= nil),
      "train %d route #%s -> #%s (was #%d -> #%d), state %s", s.train, tostring(rec and rec.pickup),
      tostring(rec and rec.dropoff), s.pickup, s.dropoff, rec and rec.state or "-")
    done()
  end
end)
