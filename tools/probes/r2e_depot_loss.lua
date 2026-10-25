-- r2-econ (0.1.1, Refs #7 #2) test-only check of the lost-depot recovery (scripts/rails.lua ai_depot, ai_program): two
-- game minutes after rts-player's first AI rail line opens, its capital-side depot dies (entity.die()). Expected: the
-- line goes "lost"; the program rebuilds the depot on the old site ("rebuilds depot #N of line #L on its old site"),
-- binds the line to it ("binds line #L to its new depot"), the line opens again and its freight train runs again.
-- Nation 1v1:
--   EXTRA_LUA=tools/probes/r2e_depot_loss.lua STOP_ON='r2e depot loss summary' DURATION_MIN=60 SEED=501 SPEED=8 \
--     tools/autotest-run.sh r2e-depot-loss '{opponents = 1, difficulty = "normal", mode = "nation",
--     world_size = 2048, enemy_brain = "ai"}' 2400
-- Log: "[rts] r2e depot loss check <name>: PASS|FAIL ..." and "[rts] r2e depot loss summary ...".
local events = require("scripts.events")
local util = require("scripts.util")
local rails = require("scripts.rails")

local F = "rts-player"

local function check(name, ok, fmt, ...)
  util.log("r2e depot loss check %s: %s " .. fmt, name, ok and "PASS" or "FAIL", ...)
  local P = storage.r2e_depot_loss
  P.pass, P.fail = P.pass + (ok and 1 or 0), P.fail + (ok and 0 or 1)
end

local function done(P)
  util.log("r2e depot loss summary %d/%d", P.pass, P.pass + P.fail)
  P.stage = "done"
end

events.on_nth_tick(60, function(e)
  local P = storage.r2e_depot_loss
  if not P then
    P = {pass = 0, fail = 0, stage = "wait"}
    storage.r2e_depot_loss = P
  end
  if P.stage == "done" then return end
  local R = storage.rails
  if not (R and R.lines) then return end
  if P.stage == "wait" then
    for _, id in ipairs((function() local k = {} for i in pairs(R.lines) do k[#k + 1] = i end table.sort(k) return k end)()) do
      local line = R.lines[id]
      if line.force == F and line.state == "open" and line.opened then
        P.line, P.opened = id, e.tick
        P.stage = "open"
        util.log("r2e depot loss: line #%d of %s open, depots #%s (a) and #%s (b)", id, F, tostring(line.a), tostring(line.b))
        return
      end
    end
    if e.tick > 55 * 3600 then
      check("line_opens", false, "no open line of %s by 55:00", F)
      done(P)
    end
    return
  end
  local line = R.lines[P.line]
  if not line then
    check("line_kept", false, "line #%d is gone", P.line)
    done(P)
    return
  end
  if P.stage == "open" then
    if e.tick - P.opened < 2 * 3600 then return end
    local d = rails.depot(line.a)
    if not d then
      check("kill", false, "line #%d has no depot a", P.line)
      done(P)
      return
    end
    P.old, P.pos = line.a, {x = d.entity.position.x, y = d.entity.position.y}
    d.entity.die()
    P.stage, P.killed = "killed", e.tick
    check("lost", line.state == "lost", "depot #%d of line #%d died at %s: line %s", P.old, P.line, util.pos_str(P.pos),
      line.state)
    return
  end
  if P.stage == "killed" then
    if line.a ~= P.old and line.state ~= "lost" then
      local d = rails.depot(line.a)
      local same = d and math.abs(d.entity.position.x - P.pos.x) < 0.5 and math.abs(d.entity.position.y - P.pos.y) < 0.5
      check("rebuilt_bound", same, "line #%d bound to depot #%d at %s (old site %s) %.0f s after the loss, state %s",
        P.line, line.a, d and util.pos_str(d.entity.position) or "-", util.pos_str(P.pos), (e.tick - P.killed) / 60,
        line.state)
      P.stage, P.bound = "bound", e.tick
    elseif e.tick - P.killed > 15 * 3600 then
      check("rebuilt_bound", false, "line #%d still %s with depot a #%s 15 min after the loss", P.line, line.state,
        tostring(line.a))
      done(P)
    end
    return
  end
  if P.stage == "bound" then
    local running
    for _, rec in pairs(R.trains) do
      if rec.kind == "cargo" and rec.force == F and rec.ai_line == P.line and rec.pickup and rec.dropoff
         and (rec.trips or 0) > (P.trips0 or -1) then running = rec end
    end
    P.trips0 = P.trips0 or (running and running.trips) or 0
    if line.state == "open" and running and (running.trips or 0) > P.trips0 then
      check("reopened", true, "line #%d open again, freight train %d at trip %d, %.0f s after the rebind", P.line,
        running.id, running.trips, (e.tick - P.bound) / 60)
      done(P)
    elseif e.tick - P.bound > 10 * 3600 then
      check("reopened", false, "line #%d %s, freight train %s, 10 min after the rebind", P.line, line.state,
        running and running.id or "none")
      done(P)
    end
  end
end)
