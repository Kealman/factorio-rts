-- Phase 5 M3 perf: tick marks for spike attribution (test copy only: tools/perf-bench.sh adds it unless MARKS=0).
-- Wraps a curated list of module functions and logs every call with its game tick, nesting depth and duration:
--   [rts] perf call t5192 d1 commander.run rts-ai-2: Duration: 29.5ms
--   [rts] perf call t5192 d2 army.step: Duration: 27.9ms
-- (COUNT functions are only counted per tick: "[rts] perf mark t120: layout.route x412"). tools/perf-bench.sh joins
-- these lines with the benchmark's per-tick scriptUpdate column, so the worst ticks name the work that ran in them and
-- its share. The wrappers only time, count and log: arguments, results and state are untouched (profilers never decide
-- anything; they only reach the log).
local events = require("scripts.events")

local function mod(name)
  local l = package.loaded
  return l["__" .. script.mod_name .. "__/scripts/" .. string.gsub(name, "%.", "/") .. ".lua"] or l["scripts." .. name]
end

-- {module, short name, timed functions, counted functions}
-- PERF_MARKS_ROUTE (a test copy's scripts/perf_marks_cfg.lua returning {route = true}) times every layout.route
-- call too (hundreds per tick at a match start); otherwise route calls are only counted.
local ok_cfg, cfg = pcall(require, "scripts.perf_marks_cfg")
cfg = ok_cfg and type(cfg) == "table" and cfg or {}

local WRAP = {
  {"ai.commander", "commander", {"start", "run"}},
  {"ai.layout", "layout", {"plan_line", "context_at", "find_spot", "find_spot_in", "hub_site", "plan_satellite",
                           "patches", "plan_spine", "chain_poles"}},
  {"ai.build_order", "build_order", {"step", "bootstrap"}},
  {"ai.construction", "construction", {"step", "repair"}},
  {"ai.towns", "towns", {"pick_site", "coal_hub", "coal_pit", "step"}},
  {"ai.hubs", "hubs", {"plan", "step"}},
  {"ai.tech", "tech", {"step"}},
  {"ai.age_up", "age_up", {"step"}},
  {"ai.mix", "mix", {"manage_barracks"}},
  {"ai.governor", "governor", {"step"}},
  {"ai.nation", "nation", {"step"}},
  {"ai.army", "army", {"step"}},
  {"ai.scout", "scout", {"step"}},
  {"rails", "rails", {"plan_line", "create_train", "ai_step"}},
  {"cities", "cities", {"found", "change_owner", "ai_step"}},
  {"market", "market", {"ai_step"}},
  {"world", "world", {"plan", "apply", "found_city_state"}},
  {"territory", "territory", {"flush", "attrition_pass"}},
  {"capture", "capture", {"flip"}},
  {"mapgen", "mapgen", {"plan", "build"}},
  {"strategic", "strategic", {"refresh_all"}},
  {"lobby", "lobby", {"start_match"}},
  {"sched", "sched", {}, {"submit"}},
}
table.insert(WRAP, 3, {"ai.layout", "layout", cfg.route and {"route"} or {}, cfg.route and {} or {"route"}})

local cur_tick, counts, order = -1, {}, {}
local depth, laps = 0, {}

local function flush()
  if #order == 0 then return end
  local parts = {}
  for _, name in ipairs(order) do parts[#parts + 1] = string.format("%s x%d", name, counts[name]) end
  log(string.format("[rts] perf mark t%d: %s", cur_tick, table.concat(parts, ", ")))
  counts, order = {}, {}
end

local function note(name)
  local t = game and game.tick or -1
  if t ~= cur_tick then
    flush()
    cur_tick = t
  end
  if not counts[name] then
    counts[name] = 0
    order[#order + 1] = name
  end
  counts[name] = counts[name] + 1
end

local function label_of(name, first)
  -- commander.run and the AI parts name their force
  if type(first) == "table" and type(first.force) == "string" then return name .. " " .. first.force end
  return name
end

for _, spec in ipairs(WRAP) do
  local m = mod(spec[1])
  if type(m) == "table" then
    for _, fn in ipairs(spec[3] or {}) do
      local orig = m[fn]
      if type(orig) == "function" then
        local name = spec[2] .. "." .. fn
        m[fn] = function(...)
          note(name)
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
          log({"", string.format("[rts] perf call t%d d%d %s: ", game.tick, d, label_of(name, (...))), lap})
          depth = d - 1
          return table.unpack(r, 1, r.n)
        end
      end
    end
    for _, fn in ipairs(spec[4] or {}) do
      local orig = m[fn]
      if type(orig) == "function" then
        local name = spec[2] .. "." .. fn
        m[fn] = function(...)
          note(name)
          return orig(...)
        end
      end
    end
  end
end

local origin_logged = false
events.on(defines.events.on_tick, function(e)
  if e.tick ~= cur_tick then flush() end
  if not origin_logged then
    -- the first tick this process runs (0 or 1 on a fresh save, the save's tick after a load): tools/perf-bench.sh maps
    -- the benchmark's tick rows (t0 = the first tick run) to game ticks with it
    origin_logged = true
    log(string.format("[rts] perf mark origin t%d", e.tick))
  end
end)

-- every on_nth_tick handler with a period of a second or more logs its time per call too (scripts/events.lua)
if events.trace_nth then events.trace_nth(60) end

return {}
