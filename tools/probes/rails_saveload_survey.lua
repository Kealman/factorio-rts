-- Test-only (tools/saveload-check.sh EXTRA_LUA): the rails autotest's main stage with a slowed-down survey that
-- spans the save at AI minute 3 (tick 10920), so the server saves and reloads in the middle of the survey.
local rails = require("scripts.rails")
local events = require("scripts.events")
rails.AUTOTEST_DEFAULT = true
rails.AUTOTEST_STAGES = {"main"}
rails.AUTOTEST_START = 10200
rails.SURVEY_CELLS = 2
rails.SURVEY_COARSE = 5
rails.SURVEY_EXPANSIONS = 2
rails.AUTOTEST_CONFIG.survey_limit = 60 * 60 -- the survey is throttled on purpose here
events.on_nth_tick(600, function(e)
  local R = storage.rails
  if not R or e.tick < 10200 or e.tick > 13800 then return end
  local parts = {}
  for id, job in pairs(R.jobs) do parts[#parts + 1] = string.format("job %d %s (expanded %d)", id, job.phase, job.expanded) end
  for id, line in pairs(R.lines) do parts[#parts + 1] = string.format("line %d %s", id, line.state) end
  log("[rts] rails saveload probe tick " .. e.tick .. ": " .. table.concat(parts, ", "))
end)
