-- Phase 5 M3 ai (wave B.2): extra perf marks inside the Nation AI for spike attribution (test copy only; pass it as
-- EXTRA_LUA to tools/perf-bench.sh, after tools/probes/perf_marks.lua). Same log line as perf_marks.lua, so the bench's
-- tick join names these calls too:
--   [rts] perf call t59211 d3 commander.manage_workshop rts-player: Duration: 21.7ms
-- The wrappers only time and log; arguments, results and state are untouched.

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. string.gsub(name, "%.", "/") .. ".lua"] or l["scripts." .. name]
end

-- {module, short name, timed functions}
local WRAP = {
  {"ai.commander", "commander", {"manage_factories", "manage_builder", "manage_workshop"}},
  {"production", "production", {"set_recipe", "set_auto"}},
  {"ai.tech", "tech", {"next", "wants"}},
  {"ai.army", "army", {"city_target", "city_state_target", "relief", "defenders", "recall", "field_target",
                       "launch_ok"}},
  {"ai.scout", "scout", {"target", "next_target", "known_targets"}},
  {"ai.council", "council", {"step", "sector_belt"}},
  {"ai.planner", "planner", {"step", "targets", "districts"}},
  {"ai.intel", "intel", {"step"}},
  {"ai.controller", "controller", {"run", "step"}},
}

local depth, laps = 0, {}

local function label_of(name, first)
  if type(first) == "table" and type(first.force) == "string" then return name .. " " .. first.force end
  return name
end

for _, spec in ipairs(WRAP) do
  local m = mod(spec[1])
  if type(m) == "table" then
    for _, fn in ipairs(spec[3]) do
      local orig = m[fn]
      if type(orig) == "function" then
        local name = spec[2] .. "." .. fn
        m[fn] = function(...)
          depth = depth + 1
          local d = depth
          local lap = laps[d]
          if not lap then
            lap = helpers.create_profiler(true)
            laps[d] = lap
          end
          lap.reset()
          local r = table.pack(orig(...))
          lap.stop()
          log({"", string.format("[rts] perf call t%d d%d %s: ", game.tick, d + 10, label_of(name, (...))), lap})
          depth = d - 1
          return table.unpack(r, 1, r.n)
        end
      end
    end
  end
end

return {}
