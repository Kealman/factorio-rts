-- Test-only (tools/saveload-check.sh EXTRA_LUA): the rails autotest's main stage on a 300-tile line started at minute
-- 1, so the freight train is on its rounds when the server saves and reloads at AI minute 3 (tick 10920).
local rails = require("scripts.rails")
local events = require("scripts.events")
rails.AUTOTEST_DEFAULT = true
rails.AUTOTEST_STAGES = {"main"}
rails.AUTOTEST_START = 3600
rails.AUTOTEST_CONFIG.b = {x = 300, y = 0}
rails.AUTOTEST_CONFIG.lake = {{200, 60}, {260, 140}}
events.on_nth_tick(300, function(e)
  local R = storage.rails
  if not R or e.tick < 9000 or e.tick > 16000 then return end
  local parts = {}
  for id, rec in pairs(R.trains) do
    local train = rails.train_of(rec)
    parts[#parts + 1] = string.format("train %d %s %s speed %.2f cargo %d", id, rec.kind, tostring(rec.state),
      train and train.speed or 0, train and table_size(rails.cargo_of(train)) or 0)
  end
  for id, line in pairs(R.lines) do parts[#parts + 1] = string.format("line %d %s", id, line.state) end
  log("[rts] rails saveload probe tick " .. e.tick .. ": " .. table.concat(parts, ", "))
end)
