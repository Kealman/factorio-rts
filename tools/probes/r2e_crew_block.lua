-- r2-econ (0.1.1 follow-up) test-only check of the stuck-crew rule (rails.CREW_STUCK_TICKS): the first construction
-- train that drives along its line, 60 tiles out of its depot, is held still (manual mode, speed 0 on every tick), as
-- a crew jammed at a crossing is. (Rolling stock placed on its track does not do: the moving crew couples to it and
-- drives on.) Expected: "stuck at ... it goes home" after CREW_STUCK_TICKS, then "stuck on its way home ... recalled"
-- after as long again (its kits, rails and coal back in its depot's network, line.builder free); then the hold ends
-- and the line gets a new crew. Nation 1v1:
--   EXTRA_LUA=tools/probes/r2e_crew_block.lua STOP_ON='r2e crew block summary' DURATION_MIN=60 SEED=501 SPEED=8 \
--     tools/autotest-run.sh r2e-crew-block '{opponents = 1, difficulty = "normal", mode = "nation",
--     world_size = 2048, enemy_brain = "ai"}' 1800
-- Log: "[rts] r2e crew block check <name>: PASS|FAIL ..." and "[rts] r2e crew block summary ...".
local events = require("scripts.events")
local util = require("scripts.util")
local rails = require("scripts.rails")

local function check(name, ok, fmt, ...)
  util.log("r2e crew block check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
  local P = storage.r2e_crew_block
  P.pass, P.fail = P.pass + (ok and 1 or 0), P.fail + (ok and 0 or 1)
end

local function train_of(rec)
  if rec.loco and rec.loco.valid then return rec.loco.train end
end

-- hold the crew still while the check runs
events.on(defines.events.on_tick, function()
  local P = storage.r2e_crew_block
  if not (P and (P.stage == "blocked" or P.stage == "returning") and P.rec) then return end
  local train = train_of(P.rec)
  if train and train.valid then
    train.manual_mode = true
    train.speed = 0
  end
end)

events.on_nth_tick(60, function(e)
  local P = storage.r2e_crew_block
  if not P then
    P = {pass = 0, fail = 0, stage = "wait"}
    storage.r2e_crew_block = P
  end
  if P.stage == "done" then return end
  local R = storage.rails
  if not (R and R.trains) then return end
  if P.stage == "wait" then
    for id, rec in pairs(R.trains) do
      local train = rec.kind == "construction" and rec.state == "building" and train_of(rec)
      local line = train and rec.line and R.lines[rec.line]
      local depot = train and rails.depot(rec.home)
      if train and line and rec.target and math.abs(train.speed) > 0.05 and depot and depot.entity
         and util.distance(train.front_stock.position, depot.entity.position) > 60 then
        P.stage, P.id, P.line, P.home, P.t0, P.rec = "blocked", id, line.id, rec.home, e.tick, rec
        util.log("r2e crew block: construction train %d of line #%d (piece target %d) held at %s", id, line.id,
          rec.target, util.pos_str(train.front_stock.position))
        return
      end
    end
    return
  end
  -- the crew's record (its train id changes when rolling stock touches it: follow the record, not the id)
  local rec
  for id, r in pairs(R.trains) do
    if r == P.rec then rec, P.id = r, id end
  end
  if P.stage == "blocked" then
    if rec and rec.state == "returning" then
      check("goes_home", e.tick - P.t0 >= rails.CREW_STUCK_TICKS * 0.9, "train %d returning %.0f s after the block",
        P.id, (e.tick - P.t0) / 60)
      P.stage, P.t1 = "returning", e.tick
    elseif not rec then
      check("goes_home", false, "train %d gone before it went home (%.0f s)", P.id, (e.tick - P.t0) / 60)
      P.stage = "cleanup"
    elseif e.tick - P.t0 > rails.CREW_STUCK_TICKS + 1800 then
      check("goes_home", false, "train %d still %s after %.0f s", P.id, tostring(rec.state), (e.tick - P.t0) / 60)
      P.stage = "cleanup"
    end
    return
  end
  if P.stage == "returning" then
    if not rec then
      local line = R.lines[P.line]
      check("recalled", e.tick - P.t1 >= rails.CREW_STUCK_TICKS * 0.9 and line and line.builder ~= P.id,
        "train %d recalled %.0f s after it turned home; line #%d builder %s", P.id, (e.tick - P.t1) / 60, P.line,
        tostring(line and line.builder))
      P.stage = "cleanup"
    elseif e.tick - P.t1 > rails.CREW_STUCK_TICKS + 1800 then
      check("recalled", false, "train %d still %s %.0f s after it turned home", P.id, tostring(rec.state),
        (e.tick - P.t1) / 60)
      P.stage = "cleanup"
    end
    return
  end
  if P.stage == "cleanup" then
    P.stage, P.t2 = "after", e.tick
    return
  end
  if P.stage == "after" then
    local line = R.lines[P.line]
    local crew = line and line.builder and R.trains[line.builder]
    if crew or (line and line.state == "open") or e.tick - P.t2 > 3 * 3600 then
      check("new_crew", crew ~= nil or (line and line.state == "open"), "line #%d %s, builder %s, %.0f s after cleanup",
        P.line, line and line.state or "-", tostring(line and line.builder), (e.tick - P.t2) / 60)
      util.log("r2e crew block summary %d/%d", P.pass, P.pass + P.fail)
      P.stage = "done"
    end
  end
end)
