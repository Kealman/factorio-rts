-- r2-ai 0.1.1 (issue #8): tick marks inside army.step for tools/perf-bench.sh (EXTRA_LUA; test copy only). Times the
-- module functions army.step calls, in the format of tools/probes/perf_marks.lua ("[rts] perf call t<tick> d<depth>
-- <name>: Duration: <ms>"), so the bench's worst ticks name the part of army.step that ran in them:
--   EXTRA_LUA=tools/probes/r2a_army_marks.lua tools/perf-bench.sh scene r2a-army 5
-- The wrappers only time and log; arguments, results and state are untouched.
local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. string.gsub(name, "%.", "/") .. ".lua"] or l["scripts." .. name]
end

local WRAP = {
  {"ai.scout", "scout", {"best_target", "visible_enemy_unit", "beaten_enemy"}},
  {"ai.army", "army", {"city_target", "city_state_target", "field_target", "relief", "defenders", "launch_ok"}},
  {"ai.raids", "raids", {"step", "reserved_raiders"}},
  {"warsupply", "warsupply", {"ai_step"}},
}

local depth, laps = 100, {}
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
          log({"", string.format("[rts] perf call t%d d%d %s: ", game.tick, d, name), lap})
          depth = d - 1
          return table.unpack(r, 1, r.n)
        end
      end
    end
  end
end

return {}
